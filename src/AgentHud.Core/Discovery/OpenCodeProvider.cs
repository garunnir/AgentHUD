using System.Text.Json;
using AgentHud.Models;
using Microsoft.Data.Sqlite;

namespace AgentHud.Discovery;

// Legacy schema verified against OpenCode v1.2.0 session.sql.ts/message-v2.ts.
// session_v2 metadata follows the macOS provider; live permission requests are not persisted.
public sealed class OpenCodeProvider : IAgentProvider
{
    private readonly string _database;
    private readonly TimeProvider _time;
    public AgentType AgentType => AgentType.OpenCode;
    public IEnumerable<string> WatchRoots { get; }
    public TimeSpan ActiveWindow { get; set; } = TimeSpan.FromHours(1);

    public OpenCodeProvider(string home, TimeProvider? time = null, string? dataHome = null)
    {
        var root = Path.Combine(dataHome ?? Path.Combine(home, ".local", "share"), "opencode");
        WatchRoots = [root]; _database = Path.Combine(root, "opencode.db"); _time = time ?? TimeProvider.System;
    }

    public async Task<IReadOnlyList<AgentSession>> DiscoverAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!File.Exists(_database)) return [];
        using var db = new SqliteConnection(new SqliteConnectionStringBuilder
        { DataSource = _database, Mode = SqliteOpenMode.ReadOnly, Pooling = false, DefaultTimeout = 1 }.ToString());
        await db.OpenAsync(cancellationToken);
        var tables = new HashSet<string>();
        using (var schema = db.CreateCommand())
        {
            schema.CommandText = "SELECT name FROM sqlite_master WHERE type = 'table'";
            using var names = await schema.ExecuteReaderAsync(cancellationToken);
            while (await names.ReadAsync(cancellationToken)) tables.Add(names.GetString(0));
        }
        var table = tables.Contains("session_v2") ? "session_v2" : tables.Contains("session") ? "session" : null;
        if (table is null) return [];
        var now = _time.GetUtcNow();
        using var command = db.CreateCommand();
        command.CommandText = $"SELECT id, directory, title, time_created, time_updated, time_archived FROM {table} WHERE time_updated >= $since ORDER BY time_updated DESC LIMIT 100";
        command.Parameters.AddWithValue("$since", (now - ActiveWindow).ToUnixTimeMilliseconds());
        var rows = new List<AgentSession>();
        using (var reader = await command.ExecuteReaderAsync(cancellationToken))
        {
            while (await reader.ReadAsync(cancellationToken))
            {
                var directory = reader.GetString(1);
                if (string.IsNullOrWhiteSpace(directory)) continue;
                var updated = DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(4)).UtcDateTime;
                rows.Add(new AgentSession
                {
                    Id = "opencode:" + reader.GetString(0), AgentType = AgentType.OpenCode,
                    ProjectPath = GitRoot.Find(directory) ?? directory, WorktreePath = directory,
                    SessionTitle = reader.GetString(2), StartedAt = DateTimeOffset.FromUnixTimeMilliseconds(reader.GetInt64(3)).UtcDateTime,
                    LastActivityAt = updated, IsActive = reader.IsDBNull(5),
                    State = reader.IsDBNull(5) ? AgentState.Idle : AgentState.Completed
                });
            }
        }
        // V2 messages use a different schema. Metadata alone cannot establish a running turn.
        if (table == "session" && tables.Contains("message"))
        {
            for (var i = 0; i < rows.Count; i++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!rows[i].IsActive) continue;
                using var message = db.CreateCommand();
                message.CommandText = "SELECT id, data FROM message WHERE session_id = $id ORDER BY time_created DESC, id DESC LIMIT 1";
                message.Parameters.AddWithValue("$id", rows[i].Id[9..]);
                string messageId, json;
                using (var reader = await message.ExecuteReaderAsync(cancellationToken))
                {
                    if (!await reader.ReadAsync(cancellationToken)) continue;
                    messageId = reader.GetString(0); json = reader.GetString(1);
                }
                try
                {
                    var state = MapState(json, now.UtcDateTime - rows[i].LastActivityAt < TimeSpan.FromMinutes(2));
                    using var info = JsonDocument.Parse(json);
                    if (tables.Contains("part") && state is AgentState.Working or AgentState.Idle
                        && GetString(info.RootElement, "role") == "assistant")
                    {
                        // OpenCode v1.2.0: question waits inside a running tool part (message-v2.ts).
                        // Only the latest message counts; old unanswered parts must not revive a finished turn.
                        using var parts = db.CreateCommand();
                        parts.CommandText = "SELECT data FROM part WHERE session_id = $session AND message_id = $message";
                        parts.Parameters.AddWithValue("$session", rows[i].Id[9..]);
                        parts.Parameters.AddWithValue("$message", messageId);
                        using var reader = await parts.ExecuteReaderAsync(cancellationToken);
                        while (await reader.ReadAsync(cancellationToken))
                        {
                            try
                            {
                                using var part = JsonDocument.Parse(reader.GetString(0));
                                var body = part.RootElement;
                                if (GetString(body, "type") == "tool" && GetString(body, "tool") == "question"
                                    && body.TryGetProperty("state", out var toolState) && GetString(toolState, "status") == "running")
                                    state = AgentState.WaitingForInput;
                            }
                            catch (JsonException) { }
                        }
                    }
                    rows[i] = rows[i] with { State = state };
                }
                catch (JsonException) { } // A malformed message must not hide other conversations.
            }
        }
        return rows;
    }

    private static string? GetString(JsonElement value, string name) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var field) && field.ValueKind == JsonValueKind.String ? field.GetString() : null;

    private static AgentState MapState(string json, bool recent)
    {
        using var doc = JsonDocument.Parse(json);
        var data = doc.RootElement;
        if (data.ValueKind != JsonValueKind.Object) return AgentState.Unknown;
        if (data.TryGetProperty("error", out var error) && error.ValueKind == JsonValueKind.Object)
            return error.TryGetProperty("name", out var name) && name.ValueKind == JsonValueKind.String && name.GetString() == "MessageAbortedError" ? AgentState.Stopped : AgentState.Error;
        if (data.TryGetProperty("role", out var role) && role.ValueKind == JsonValueKind.String && role.GetString() == "assistant"
            && data.TryGetProperty("finish", out var finish) && finish.ValueKind == JsonValueKind.String
            && finish.GetString() is "stop" or "length" or "content-filter") return AgentState.Completed;
        return recent ? AgentState.Working : AgentState.Idle;
    }
}
