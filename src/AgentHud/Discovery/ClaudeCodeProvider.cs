using System.Text.Json;
using AgentHud.Models;

namespace AgentHud.Discovery;

public sealed class ClaudeCodeProvider : IAgentProvider
{
    private readonly string _sessionsRoot;
    private readonly string _projectsRoot;
    private readonly Dictionary<string, (long Length, DateTime Modified, TranscriptInfo Info)> _transcripts = [];
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
                var state = !alive ? AgentState.Stopped : MapState(data.Status, activity);
                // VS Code can keep an unused conversation process ready before any messages exist.
                if (data.Entrypoint == "claude-vscode" && state == AgentState.Idle
                    && Guid.TryParse(data.SessionId, out _) && !HasTranscript(data.SessionId)) continue;
                var transcript = await ReadTranscriptAsync(data.SessionId, token);
                if (alive && transcript.HasPendingQuestion
                    && state is not (AgentState.Error or AgentState.Stopped or AgentState.WaitingForApproval))
                    state = AgentState.WaitingForInput;
                if (alive && transcript.RateLimitResetAt > DateTime.UtcNow && state is not (AgentState.Stopped or AgentState.WaitingForApproval))
                    state = AgentState.RateLimited;
                result.Add(new AgentSession
                {
                    Id = $"claude:{data.SessionId}", AgentType = AgentType, ProcessId = data.Pid,
                    ProjectPath = data.Cwd, WorktreePath = GitRoot.Find(data.Cwd), SessionTitle = transcript.Title ?? data.Name,
                    StartedAt = ParseDate(data.StartedAt) ?? File.GetCreationTimeUtc(file), LastActivityAt = activity,
                    State = state, IsActive = alive, RateLimitResetAt = transcript.RateLimitResetAt,
                    Tokens5h = transcript.Usage?.Where(x => DateTime.UtcNow - x.At <= ShortWindow).Sum(x => x.Tokens) ?? 0,
                    TokensWeek = transcript.Usage?.Sum(x => x.Tokens) ?? 0
                });
            }
            catch (JsonException) { }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        return result;
    }

    private bool HasTranscript(string sessionId)
    {
        if (!Directory.Exists(_projectsRoot)) return false;
        return Directory.EnumerateDirectories(_projectsRoot)
            .Any(project => File.Exists(Path.Combine(project, sessionId + ".jsonl")));
    }

    private sealed record TranscriptInfo(string? Title = null, bool HasPendingQuestion = false, DateTime? RateLimitResetAt = null, IReadOnlyList<(DateTime At, long Tokens)>? Usage = null);
    private static readonly TimeSpan UsageWindow = TimeSpan.FromDays(7);
    private static readonly TimeSpan ShortWindow = TimeSpan.FromHours(5);
    // 같은 message.id가 여러 줄에 기록되므로 마지막 값만 사용. 7일보다 오래된 항목은 버림
    private static void AddUsage(Dictionary<string, (DateTime At, long Tokens)> usage, string line)
    {
        try
        {
            using var json = JsonDocument.Parse(line);
            var root = json.RootElement;
            if (!root.TryGetProperty("message", out var message) || message.ValueKind != JsonValueKind.Object
                || !message.TryGetProperty("usage", out var u) || u.ValueKind != JsonValueKind.Object
                || GetString(message, "id") is not { } id
                || GetString(root, "timestamp") is not { } stamp
                || !DateTime.TryParse(stamp, null, System.Globalization.DateTimeStyles.RoundtripKind, out var at)) return;
            at = at.ToUniversalTime();
            if (DateTime.UtcNow - at > UsageWindow) return;
            long Get(string name) => u.TryGetProperty(name, out var v) && v.TryGetInt64(out var n) ? n : 0;
            usage[id] = (at, Get("input_tokens") + Get("output_tokens") + Get("cache_creation_input_tokens"));
        }
        catch (JsonException) { }
    }
    private async Task<TranscriptInfo> ReadTranscriptAsync(string sessionId, CancellationToken token)
    {
        // Session IDs are filenames, never paths supplied by metadata.
        if (!Guid.TryParse(sessionId, out _) || !Directory.Exists(_projectsRoot)) return new();
        try
        {
            foreach (var project in Directory.EnumerateDirectories(_projectsRoot))
            {
                var path = Path.Combine(project, sessionId + ".jsonl");
                var info = new FileInfo(path);
                if (!info.Exists) continue;
                if (_transcripts.TryGetValue(path, out var cached) && cached.Length == info.Length && cached.Modified == info.LastWriteTimeUtc)
                    return cached.Info;
                string? aiTitle = null, customTitle = null;
                DateTime? rateLimitReset = null;
                var pendingQuestions = new HashSet<string>();
                var usage = new Dictionary<string, (DateTime At, long Tokens)>();
                await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, true);
                using var reader = new StreamReader(stream);
                while (await reader.ReadLineAsync(token) is { } line)
                {
                    // 마지막 대화 기록이 사용량 한도 오류면 리셋 시각을 기억하고, 이후 대화가 이어지면 지움
                    if (line.Contains("\"isApiErrorMessage\":true", StringComparison.Ordinal))
                    {
                        rateLimitReset = ParseRateLimit(line, sessionId);
                        continue;
                    }
                    if (line.Contains("\"type\":\"user\"", StringComparison.Ordinal) || line.Contains("\"type\":\"assistant\"", StringComparison.Ordinal))
                        rateLimitReset = null;
                    if (line.Contains("\"usage\":{", StringComparison.Ordinal) && line.Contains("\"type\":\"assistant\"", StringComparison.Ordinal))
                        AddUsage(usage, line);
                    // Only parse records relevant to titles or question lifecycle.
                    if (!line.Contains("\"aiTitle\"", StringComparison.Ordinal) && !line.Contains("\"customTitle\"", StringComparison.Ordinal)
                        && !line.Contains("\"tool_use\"", StringComparison.Ordinal) && !line.Contains("\"tool_result\"", StringComparison.Ordinal)) continue;
                    try
                    {
                        using var json = JsonDocument.Parse(line);
                        var root = json.RootElement;
                        if (!root.TryGetProperty("sessionId", out var id) || id.GetString() != sessionId) continue;
                        if (!root.TryGetProperty("type", out var type)) continue;
                        if (root.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.Object
                            && message.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array)
                        {
                            foreach (var block in content.EnumerateArray())
                            {
                                if (type.GetString() == "assistant" && GetString(block, "type") == "tool_use"
                                    && GetString(block, "name") == "AskUserQuestion" && GetString(block, "id") is { } questionId)
                                    pendingQuestions.Add(questionId);
                                else if (type.GetString() == "user" && GetString(block, "type") == "tool_result"
                                    && GetString(block, "tool_use_id") is { } answeredId)
                                    pendingQuestions.Remove(answeredId);
                            }
                        }
                        if (type.GetString() == "ai-title" && root.TryGetProperty("aiTitle", out var title) && title.ValueKind == JsonValueKind.String) aiTitle = title.GetString();
                        if (type.GetString() == "custom-title" && root.TryGetProperty("customTitle", out title) && title.ValueKind == JsonValueKind.String) customTitle = title.GetString();
                    }
                    catch (JsonException) { }
                }
                var result = new TranscriptInfo(!string.IsNullOrWhiteSpace(customTitle) ? customTitle : aiTitle, pendingQuestions.Count > 0, rateLimitReset, usage.Values.ToArray());
                _transcripts[path] = (info.Length, info.LastWriteTimeUtc, result);
                return result;
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return new();
    }

    private static DateTime? ParseRateLimit(string line, string sessionId)
    {
        try
        {
            using var json = JsonDocument.Parse(line);
            var root = json.RootElement;
            if (GetString(root, "sessionId") != sessionId) return null;
            var text = root.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.Object
                && message.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array
                ? string.Join('\n', content.EnumerateArray().Select(block => GetString(block, "text")).OfType<string>()) : "";
            if (GetString(root, "error") != "rate_limit" && !RateLimitParser.LooksLikeUsageLimit(text)) return null;
            var at = GetString(root, "timestamp") is { } stamp && DateTime.TryParse(stamp, null, System.Globalization.DateTimeStyles.RoundtripKind, out var parsed)
                ? parsed.ToUniversalTime() : DateTime.UtcNow;
            return RateLimitParser.ParseReset(text, at) ?? at + RateLimitParser.FallbackDelay;
        }
        catch (JsonException) { return null; }
    }
    private static string? GetString(JsonElement element, string name) => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static AgentState MapState(string? status, DateTime activity) => status?.ToLowerInvariant() switch
    {
        // Claude Code writes "busy" while a turn is in progress.
        "busy" or "working" or "running" => AgentState.Working,
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
    private sealed record ClaudeMetadata(int Pid, string? SessionId, string? Cwd, JsonElement StartedAt, JsonElement UpdatedAt, string? Status, string? Name, string? Entrypoint);
}
