using System.Text.Json;
using AgentHud.Models;

namespace AgentHud.Discovery;

public sealed class ClaudeCodeProvider : IAgentProvider
{
    private readonly string _sessionsRoot;
    private static readonly JsonSerializerOptions MetadataOptions = new() { PropertyNameCaseInsensitive = true };
    public AgentType AgentType => AgentType.ClaudeCode;
    public IEnumerable<string> WatchRoots => [_sessionsRoot];

    public ClaudeCodeProvider(string home) => _sessionsRoot = Path.Combine(home, ".claude", "sessions");

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
                    ProjectPath = data.Cwd, WorktreePath = GitRoot.Find(data.Cwd),
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

    private static AgentState MapState(string? status, DateTime activity) => status?.ToLowerInvariant() switch
    {
        "working" or "running" => AgentState.Working,
        "thinking" => AgentState.Thinking,
        "waiting" or "waiting_for_input" => AgentState.WaitingForInput,
        "waiting_for_approval" => AgentState.WaitingForApproval,
        "error" => AgentState.Error,
        "idle" => DateTime.UtcNow - activity.ToUniversalTime() < TimeSpan.FromSeconds(8) ? AgentState.Working : AgentState.WaitingForInput,
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
    private sealed record ClaudeMetadata(int Pid, string? SessionId, string? Cwd, JsonElement StartedAt, JsonElement UpdatedAt, string? Status);
}
