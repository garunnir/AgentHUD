using System.Text.Json;
using AgentHud.Models;

namespace AgentHud.Discovery;

public sealed class ClaudeCodeProvider : IAgentProvider
{
    private readonly string _sessionsRoot;
    private readonly string _projectsRoot;
    private readonly Dictionary<string, (long Length, DateTime Modified, string? Title)> _titles = [];
    private static readonly JsonSerializerOptions MetadataOptions = new() { PropertyNameCaseInsensitive = true };
    public AgentType AgentType => AgentType.ClaudeCode;
    public IEnumerable<string> WatchRoots => [_sessionsRoot, _projectsRoot];

    public ClaudeCodeProvider(string home)
    {
        _sessionsRoot = Path.Combine(home, ".claude", "sessions");
        _projectsRoot = Path.Combine(home, ".claude", "projects");
    }

    public async Task<IReadOnlyList<AgentSession>> DiscoverAsync(CancellationToken token)
    {
        if (!Directory.Exists(_sessionsRoot)) return [];
        var processes = ProcessSnapshot.Capture();
        var result = new List<AgentSession>();
        foreach (var file in Directory.EnumerateFiles(_sessionsRoot, "*.json", SearchOption.TopDirectoryOnly))
        {
            token.ThrowIfCancellationRequested();
            try
            {
                await using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, true);
                var data = await JsonSerializer.DeserializeAsync<ClaudeMetadata>(stream, MetadataOptions, token);
                if (data?.SessionId is null || data.Pid <= 0) continue;
                var alive = processes.Contains(data.Pid);
                var activity = ParseDate(data.UpdatedAt) ?? File.GetLastWriteTimeUtc(file);
                result.Add(new AgentSession
                {
                    Id = $"claude:{data.SessionId}", AgentType = AgentType, ProcessId = data.Pid,
                    ProjectPath = data.Cwd, WorktreePath = GitRoot.Find(data.Cwd), SessionTitle = await ReadTitleAsync(data.SessionId, token) ?? data.Name,
                    StartedAt = ParseDate(data.StartedAt) ?? File.GetCreationTimeUtc(file), LastActivityAt = activity,
                    State = !alive ? AgentState.Stopped : MapState(data.Status, activity), IsActive = alive
                });
            }
            catch (JsonException) { }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return result;
    }

    private async Task<string?> ReadTitleAsync(string sessionId, CancellationToken token)
    {
        // Session IDs are filenames, never paths supplied by metadata.
        if (!Guid.TryParse(sessionId, out _) || !Directory.Exists(_projectsRoot)) return null;
        try
        {
            foreach (var project in Directory.EnumerateDirectories(_projectsRoot))
            {
                var path = Path.Combine(project, sessionId + ".jsonl");
                var info = new FileInfo(path);
                if (!info.Exists) continue;
                if (_titles.TryGetValue(path, out var cached) && cached.Length == info.Length && cached.Modified == info.LastWriteTimeUtc)
                    return cached.Title;
                string? aiTitle = null, customTitle = null;
                await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, true);
                using var reader = new StreamReader(stream);
                while (await reader.ReadLineAsync(token) is { } line)
                {
                    // Avoid parsing message/tool payloads; titles are small standalone records.
                    if (!line.Contains("\"aiTitle\"", StringComparison.Ordinal) && !line.Contains("\"customTitle\"", StringComparison.Ordinal)) continue;
                    try
                    {
                        using var json = JsonDocument.Parse(line);
                        var root = json.RootElement;
                        if (!root.TryGetProperty("sessionId", out var id) || id.GetString() != sessionId) continue;
                        if (!root.TryGetProperty("type", out var type)) continue;
                        if (type.GetString() == "ai-title" && root.TryGetProperty("aiTitle", out var title) && title.ValueKind == JsonValueKind.String) aiTitle = title.GetString();
                        if (type.GetString() == "custom-title" && root.TryGetProperty("customTitle", out title) && title.ValueKind == JsonValueKind.String) customTitle = title.GetString();
                    }
                    catch (JsonException) { }
                }
                var result = !string.IsNullOrWhiteSpace(customTitle) ? customTitle : aiTitle;
                _titles[path] = (info.Length, info.LastWriteTimeUtc, result);
                return result;
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return null;
    }

    private static AgentState MapState(string? status, DateTime activity) => status?.ToLowerInvariant() switch
    {
        "working" or "running" => AgentState.Working,
        "thinking" => AgentState.Thinking,
        "waiting" or "waiting_for_input" => AgentState.WaitingForInput,
        "waiting_for_approval" => AgentState.WaitingForApproval,
        "error" => AgentState.Error,
        "idle" => AgentState.Idle,
        _ => AgentState.Unknown
    };
    private static DateTime? ParseDate(JsonElement value)
    {
        if (value.ValueKind == JsonValueKind.Number && value.TryGetInt64(out var milliseconds))
        {
            try { return DateTimeOffset.FromUnixTimeMilliseconds(milliseconds).UtcDateTime; }
            catch (ArgumentOutOfRangeException) { return null; }
        }
        return value.ValueKind == JsonValueKind.String &&
            DateTime.TryParse(value.GetString(), null, System.Globalization.DateTimeStyles.RoundtripKind, out var parsed)
            ? parsed.ToUniversalTime() : null;
    }
    private sealed record ClaudeMetadata(int Pid, string? SessionId, string? Cwd, JsonElement StartedAt, JsonElement UpdatedAt, string? Status, string? Name);
}
