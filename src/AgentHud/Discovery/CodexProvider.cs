using System.Text.Json;
using AgentHud.Models;

namespace AgentHud.Discovery;

public sealed class CodexProvider : IAgentProvider
{
    private readonly string _sessionsRoot;
    private static readonly TimeSpan ActiveWindow = TimeSpan.FromSeconds(15);
    public AgentType AgentType => AgentType.Codex;
    public IEnumerable<string> WatchRoots => [_sessionsRoot];
    public CodexProvider(string home) => _sessionsRoot = Path.Combine(home, ".codex", "sessions");

    public async Task<IReadOnlyList<AgentSession>> DiscoverAsync(CancellationToken token)
    {
        if (!Directory.Exists(_sessionsRoot)) return [];
        var result = new List<AgentSession>();
        var cutoff = DateTime.UtcNow - TimeSpan.FromMinutes(5);
        foreach (var file in Directory.EnumerateFiles(_sessionsRoot, "*.jsonl", SearchOption.AllDirectories).Select(p => new FileInfo(p)).Where(f => f.LastWriteTimeUtc >= cutoff))
        {
            token.ThrowIfCancellationRequested();
            var first = await SessionFileReader.ReadFirstLineAsync(file.FullName, token);
            if (first is null) continue;
            try
            {
                using var json = JsonDocument.Parse(first);
                var root = json.RootElement;
                if (!root.TryGetProperty("type", out var type) || type.GetString() != "session_meta") continue;
                var payload = root.GetProperty("payload");
                // Sub-agents share session_id with their parent; id identifies the thread.
                var id = GetString(payload, "id") ?? GetString(payload, "session_id");
                if (id is null) continue;
                var cwd = GetString(payload, "cwd");
                var started = ParseDate(GetString(payload, "timestamp")) ?? file.CreationTimeUtc;
                var age = DateTime.UtcNow - file.LastWriteTimeUtc;
                result.Add(new AgentSession
                {
                    Id = $"codex:{id}", AgentType = AgentType, ProjectPath = cwd, WorktreePath = GitRoot.Find(cwd),
                    ParentSessionId = GetString(payload, "parent_thread_id") is { } parentId ? $"codex:{parentId}" : null,
                    StartedAt = started, LastActivityAt = file.LastWriteTimeUtc,
                    State = age <= ActiveWindow ? AgentState.Working : AgentState.WaitingForInput,
                    IsActive = age <= TimeSpan.FromMinutes(2)
                });
            }
            catch (JsonException) { }
        }
        return result;
    }
    private static string? GetString(JsonElement element, string name) => element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static DateTime? ParseDate(string? value) => DateTime.TryParse(value, null, System.Globalization.DateTimeStyles.RoundtripKind, out var parsed) ? parsed : null;
}
