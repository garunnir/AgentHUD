using System.Text.Json;
using AgentHud.Models;
using Microsoft.Data.Sqlite;

namespace AgentHud.Discovery;

// Verified against Cursor 3.27.22 on Windows: composers live in %APPDATA%\Cursor\User\globalStorage\state.vscdb
// (composerHeaders + cursorDiskKV composerData:<id>). Transcripts under ~/.cursor/projects are secondary.
public sealed class CursorProvider : IAgentProvider
{
    private readonly string _database;
    private readonly TimeProvider _time;
    public AgentType AgentType => AgentType.Cursor;
    public IEnumerable<string> WatchRoots { get; }
    public TimeSpan ActiveWindow { get; set; } = TimeSpan.FromHours(1);

    public CursorProvider(string? appData = null, TimeProvider? time = null)
    {
        var root = Path.Combine(appData ?? Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "Cursor", "User", "globalStorage");
        WatchRoots = [root];
        _database = Path.Combine(root, "state.vscdb");
        _time = time ?? TimeProvider.System;
    }

    public async Task<IReadOnlyList<AgentSession>> DiscoverAsync(CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        if (!File.Exists(_database)) return [];
        using var db = new SqliteConnection(new SqliteConnectionStringBuilder
        { DataSource = _database, Mode = SqliteOpenMode.ReadOnly, Pooling = false, DefaultTimeout = 1 }.ToString());
        await db.OpenAsync(cancellationToken);
        var tables = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        using (var schema = db.CreateCommand())
        {
            schema.CommandText = "SELECT name FROM sqlite_master WHERE type = 'table'";
            using var names = await schema.ExecuteReaderAsync(cancellationToken);
            while (await names.ReadAsync(cancellationToken)) tables.Add(names.GetString(0));
        }
        if (!tables.Contains("composerHeaders")) return [];
        var hasKv = tables.Contains("cursorDiskKV");
        var now = _time.GetUtcNow();
        var since = (now - ActiveWindow).ToUnixTimeMilliseconds();
        var headers = new List<(string Id, long Created, long Updated, bool Archived, string? HeadJson)>();
        using (var command = db.CreateCommand())
        {
            command.CommandText = """
                SELECT composerId, createdAt, lastUpdatedAt, isArchived, value
                FROM composerHeaders
                WHERE lastUpdatedAt >= $since
                ORDER BY lastUpdatedAt DESC
                LIMIT 100
                """;
            command.Parameters.AddWithValue("$since", since);
            using var reader = await command.ExecuteReaderAsync(cancellationToken);
            while (await reader.ReadAsync(cancellationToken))
            {
                var id = reader.GetString(0);
                if (string.IsNullOrWhiteSpace(id) || id == "empty-state-draft") continue;
                headers.Add((id, reader.GetInt64(1), reader.GetInt64(2), !reader.IsDBNull(3) && reader.GetInt64(3) != 0,
                    reader.IsDBNull(4) ? null : reader.GetString(4)));
            }
        }
        var rows = new List<AgentSession>();
        foreach (var header in headers)
        {
            cancellationToken.ThrowIfCancellationRequested();
            string? title = null, project = null, parent = null;
            var skip = false;
            if (!string.IsNullOrWhiteSpace(header.HeadJson))
            {
                try
                {
                    using var head = JsonDocument.Parse(header.HeadJson);
                    var root = head.RootElement;
                    if (GetBool(root, "isDraft") || GetBool(root, "isEphemeral") || GetBool(root, "isArchived")) skip = true;
                    title = GetString(root, "name");
                    project = ProjectPath(root);
                    if (root.TryGetProperty("subagentInfo", out var sub) && sub.ValueKind == JsonValueKind.Object
                        && GetString(sub, "parentComposerId") is { Length: > 0 } parentId)
                        parent = "cursor:" + parentId;
                }
                catch (JsonException) { }
            }
            if (skip) continue;
            var state = AgentState.Idle;
            if (hasKv)
            {
                using var data = db.CreateCommand();
                data.CommandText = "SELECT value FROM cursorDiskKV WHERE key = $key LIMIT 1";
                data.Parameters.AddWithValue("$key", "composerData:" + header.Id);
                if (await data.ExecuteScalarAsync(cancellationToken) is string dataJson && !string.IsNullOrWhiteSpace(dataJson))
                {
                    try
                    {
                        using var doc = JsonDocument.Parse(dataJson);
                        var root = doc.RootElement;
                        if (GetBool(root, "isDraft") || GetBool(root, "isEphemeral")) continue;
                        title ??= GetString(root, "name");
                        project ??= ProjectPath(root);
                        state = MapState(root, now.UtcDateTime);
                    }
                    catch (JsonException) { }
                }
            }
            if (string.IsNullOrWhiteSpace(project)) continue;
            if (header.Archived && state is AgentState.Idle or AgentState.Unknown) state = AgentState.Completed;
            rows.Add(new AgentSession
            {
                Id = "cursor:" + header.Id, AgentType = AgentType, State = state,
                ProjectPath = GitRoot.Find(project) ?? project,
                WorktreePath = project, SessionTitle = title,
                StartedAt = FromMs(header.Created), LastActivityAt = FromMs(header.Updated), IsActive = !header.Archived,
                ParentSessionId = parent
            });
        }
        return rows;
    }

    // Workbench treats generating as status==generating || generatingBubbleIds || isContinuationInProgress.
    // Disk often keeps status=aborted with unfinishedRunAt while a turn is still live.
    public static AgentState MapState(JsonElement data, DateTime nowUtc)
    {
        if (GetBool(data, "hasBlockingPendingActions")) return AgentState.WaitingForApproval;
        if (IsGenerating(data)) return AgentState.Working;
        if (GetString(data, "status") is { } status)
        {
            if (status == "completed") return AgentState.Completed;
            if (status == "aborted")
            {
                if (data.TryGetProperty("unfinishedRunAt", out var unfinished) && TryUnixMs(unfinished, out var at)
                    && nowUtc - at < TimeSpan.FromMinutes(30)) return AgentState.Working;
                return AgentState.Stopped;
            }
            if (status == "generating") return AgentState.Working;
            if (status == "none") return AgentState.Idle;
        }
        return AgentState.Idle;
    }

    private static bool IsGenerating(JsonElement data)
    {
        if (GetString(data, "status") == "generating") return true;
        if (GetBool(data, "isContinuationInProgress")) return true;
        return data.TryGetProperty("generatingBubbleIds", out var bubbles) && bubbles.ValueKind == JsonValueKind.Array && bubbles.GetArrayLength() > 0;
    }

    private static string? ProjectPath(JsonElement root)
    {
        if (!root.TryGetProperty("workspaceIdentifier", out var id) || id.ValueKind != JsonValueKind.Object) return null;
        if (id.TryGetProperty("uri", out var uri) && uri.ValueKind == JsonValueKind.Object && GetString(uri, "fsPath") is { Length: > 0 } path)
            return path;
        return GetString(id, "fsPath");
    }

    private static DateTime FromMs(long ms) => DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime;
    private static bool TryUnixMs(JsonElement value, out DateTime utc)
    {
        utc = default;
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var ms)) { utc = FromMs(ms); return true; }
        if (value.ValueKind == JsonValueKind.String && long.TryParse(value.GetString(), out ms)) { utc = FromMs(ms); return true; }
        return false;
    }
    private static string? GetString(JsonElement value, string name) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var field) && field.ValueKind == JsonValueKind.String ? field.GetString() : null;
    private static bool GetBool(JsonElement value, string name) => value.ValueKind == JsonValueKind.Object && value.TryGetProperty(name, out var field) && field.ValueKind == JsonValueKind.True;
}
