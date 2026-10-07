using System.Text.Json;
using System.Text.RegularExpressions;
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
                var wakeupAt = alive ? transcript.WakeupAt : null;
                var hasBackground = alive && transcript.BackgroundSince > DateTime.UtcNow - BackgroundWindow;
                // Status can read idle while work is still coming (open turn, background task, scheduled wakeup); that is progress, not a completion.
                if (state == AgentState.Idle && (transcript.MidTurn || hasBackground || wakeupAt > DateTime.UtcNow)) state = AgentState.Working;
                if (alive && transcript.RateLimitResetAt > DateTime.UtcNow && state is not (AgentState.Stopped or AgentState.WaitingForApproval))
                    state = AgentState.RateLimited;
                result.Add(new AgentSession
                {
                    Id = $"claude:{data.SessionId}", AgentType = AgentType, ProcessId = data.Pid,
                    ProjectPath = data.Cwd, WorktreePath = GitRoot.Find(data.Cwd), SessionTitle = transcript.Title ?? data.Name,
                    StartedAt = ParseDate(data.StartedAt) ?? File.GetCreationTimeUtc(file), LastActivityAt = activity,
                    State = state, IsActive = alive, WakeupAt = wakeupAt,
                    HasBackgroundTasks = hasBackground, RateLimitResetAt = transcript.RateLimitResetAt,
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

    private sealed record TranscriptInfo(string? Title = null, bool HasPendingQuestion = false, DateTime? RateLimitResetAt = null, IReadOnlyList<(DateTime At, long Tokens)>? Usage = null, bool MidTurn = false, DateTime? WakeupAt = null, DateTime? BackgroundSince = null);
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
                var midTurn = false;
                DateTime? wakeupAt = null;
                var background = new Dictionary<string, DateTime>();
                var backgroundCalls = new HashSet<string>();
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
                    if (!line.Contains("\"isSidechain\":true", StringComparison.Ordinal))
                    {
                        // The last main-thread record tells whether the turn is still open: end_turn / turn_duration close it.
                        if (line.Contains("\"type\":\"assistant\"", StringComparison.Ordinal))
                            midTurn = !line.Contains("\"stop_reason\":\"end_turn\"", StringComparison.Ordinal);
                        else if (line.Contains("\"type\":\"user\"", StringComparison.Ordinal))
                        {
                            midTurn = line.Contains("\"tool_result\"", StringComparison.Ordinal);
                            // A wakeup firing (or the user typing) arrives as a prompt and ends the scheduled wait.
                            if (!midTurn) wakeupAt = null;
                        }
                        else if (line.Contains("\"subtype\":\"turn_duration\"", StringComparison.Ordinal))
                            midTurn = false;
                    }
                    if (line.Contains("\"usage\":{", StringComparison.Ordinal) && line.Contains("\"type\":\"assistant\"", StringComparison.Ordinal))
                        AddUsage(usage, line);
                    // Only parse records relevant to titles or question lifecycle.
                    if (!line.Contains("\"aiTitle\"", StringComparison.Ordinal) && !line.Contains("\"customTitle\"", StringComparison.Ordinal)
                        && !line.Contains("\"tool_use\"", StringComparison.Ordinal) && !line.Contains("\"tool_result\"", StringComparison.Ordinal)
                        && !line.Contains("task-notification", StringComparison.Ordinal)) continue;
                    try
                    {
                        using var json = JsonDocument.Parse(line);
                        var root = json.RootElement;
                        if (!root.TryGetProperty("sessionId", out var id) || id.GetString() != sessionId) continue;
                        if (!root.TryGetProperty("type", out var type)) continue;
                        var sidechain = root.TryGetProperty("isSidechain", out var sc) && sc.ValueKind == JsonValueKind.True;
                        if (!sidechain && type.GetString() == "user" && root.TryGetProperty("message", out var userMessage)
                            && userMessage.ValueKind == JsonValueKind.Object && userMessage.TryGetProperty("content", out var userContent))
                            TrackBackground(background, backgroundCalls, root, userContent);
                        if (root.TryGetProperty("message", out var message) && message.ValueKind == JsonValueKind.Object
                            && message.TryGetProperty("content", out var content) && content.ValueKind == JsonValueKind.Array)
                        {
                            foreach (var block in content.EnumerateArray())
                            {
                                if (!sidechain && type.GetString() == "assistant" && GetString(block, "type") == "tool_use"
                                    && IsBackgroundCall(block) && GetString(block, "id") is { } callId) backgroundCalls.Add(callId);
                                if (type.GetString() == "assistant" && GetString(block, "type") == "tool_use"
                                    && GetString(block, "name") == "AskUserQuestion" && GetString(block, "id") is { } questionId)
                                    pendingQuestions.Add(questionId);
                                else if (type.GetString() == "assistant" && GetString(block, "type") == "tool_use"
                                    && GetString(block, "name") == "ScheduleWakeup")
                                    wakeupAt = ParseWakeup(root, block);
                                else if (!sidechain && type.GetString() == "assistant" && GetString(block, "type") == "tool_use"
                                    && GetString(block, "name") == "TaskStop" && block.TryGetProperty("input", out var stopInput) && stopInput.ValueKind == JsonValueKind.Object)
                                {
                                    foreach (var arg in stopInput.EnumerateObject())
                                        if (arg.Value.ValueKind == JsonValueKind.String) background.Remove(arg.Value.GetString()!);
                                }
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
                var result = new TranscriptInfo(!string.IsNullOrWhiteSpace(customTitle) ? customTitle : aiTitle, pendingQuestions.Count > 0, rateLimitReset, usage.Values.ToArray(), midTurn, wakeupAt, background.Count > 0 ? background.Values.Max() : null);
                _transcripts[path] = (info.Length, info.LastWriteTimeUtc, result);
                return result;
            }
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
        return new();
    }

    // Background Bash / Agent tasks keep the session busy after the turn ends; a task-notification for the same id marks them finished.
    private static readonly Regex BackgroundStarted = new(@"running in background with ID: (\w+)|Async agent launched[\s\S]*?agentId: (\w+)", RegexOptions.Compiled);
    private static readonly Regex TaskFinished = new(@"<task-id>\s*([^<\s]+)\s*</task-id>", RegexOptions.Compiled);
    private static readonly TimeSpan BackgroundWindow = TimeSpan.FromHours(1);
    // Only results of calls that really started a background task count; text that merely quotes the launch message (logs, pasted output) must not.
    private static bool IsBackgroundCall(JsonElement block) => GetString(block, "name") switch
    {
        "Agent" or "Task" => true,
        "Bash" or "PowerShell" => block.TryGetProperty("input", out var input) && input.ValueKind == JsonValueKind.Object
            && input.TryGetProperty("run_in_background", out var flag) && flag.ValueKind == JsonValueKind.True,
        _ => false
    };
    private static void TrackBackground(Dictionary<string, DateTime> tasks, HashSet<string> calls, JsonElement root, JsonElement content)
    {
        var at = GetString(root, "timestamp") is { } stamp && DateTime.TryParse(stamp, null, System.Globalization.DateTimeStyles.RoundtripKind, out var parsed)
            ? parsed.ToUniversalTime() : DateTime.UtcNow;
        void Finished(string? text)
        {
            if (text is null || !text.Contains("<task-notification>", StringComparison.Ordinal)) return;
            foreach (Match done in TaskFinished.Matches(text)) tasks.Remove(done.Groups[1].Value);
        }
        if (content.ValueKind == JsonValueKind.String) { Finished(content.GetString()); return; }
        if (content.ValueKind != JsonValueKind.Array) return;
        foreach (var block in content.EnumerateArray())
        {
            if (GetString(block, "type") != "tool_result") { Finished(BlockText(block)); continue; }
            if (GetString(block, "tool_use_id") is { } callId && calls.Contains(callId) && BlockText(block) is { } text
                && BackgroundStarted.Match(text) is { Success: true } started)
                tasks[started.Groups[1].Success ? started.Groups[1].Value : started.Groups[2].Value] = at;
        }
    }
    private static string? BlockText(JsonElement block)
    {
        if (GetString(block, "type") == "text") return GetString(block, "text");
        if (!block.TryGetProperty("content", out var inner)) return null;
        return inner.ValueKind == JsonValueKind.String ? inner.GetString()
            : inner.ValueKind == JsonValueKind.Array ? string.Join('\n', inner.EnumerateArray().Select(x => GetString(x, "text")).OfType<string>()) : null;
    }
    // ScheduleWakeup clamps delaySeconds to [60, 3600]; a call without delaySeconds (stop) cancels the loop. A short grace covers scheduling latency.
    private static DateTime? ParseWakeup(JsonElement root, JsonElement block)
    {
        if (!block.TryGetProperty("input", out var input) || input.ValueKind != JsonValueKind.Object
            || !input.TryGetProperty("delaySeconds", out var delay) || !delay.TryGetDouble(out var seconds)
            || GetString(root, "timestamp") is not { } stamp
            || !DateTime.TryParse(stamp, null, System.Globalization.DateTimeStyles.RoundtripKind, out var at)) return null;
        return at.ToUniversalTime().AddSeconds(Math.Clamp(seconds, 60, 3600) + 30);
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
