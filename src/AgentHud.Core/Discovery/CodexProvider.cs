using System.Text;
using System.Text.Json;
using AgentHud.Models;

namespace AgentHud.Discovery;

public sealed class CodexProvider : IAgentProvider
{
    private readonly string _sessionsRoot;
    private readonly string _indexPath;
    private Dictionary<string, string> _titles = [];
    private (long Length, DateTime Modified)? _indexStamp;
    private readonly Dictionary<string, CachedSession> _cache = new(StringComparer.OrdinalIgnoreCase);
    private long _activeWindowTicks = TimeSpan.FromMinutes(5).Ticks;
    // 마지막 이벤트 후 이 시간 안이면 활성으로 추정 (UI 스레드에서 변경, 탐색 스레드에서 읽음)
    public TimeSpan ActiveWindow
    {
        get => TimeSpan.FromTicks(Interlocked.Read(ref _activeWindowTicks));
        set => Interlocked.Exchange(ref _activeWindowTicks, value.Ticks);
    }
    public AgentType AgentType => AgentType.Codex;
    public IEnumerable<string> WatchRoots => [_sessionsRoot];
    public CodexProvider(string home)
    {
        _sessionsRoot = Path.Combine(home, ".codex", "sessions");
        _indexPath = Path.Combine(home, ".codex", "session_index.jsonl");
    }

    public async Task<IReadOnlyList<AgentSession>> DiscoverAsync(CancellationToken token)
    {
        if (!Directory.Exists(_sessionsRoot)) return [];
        await RefreshTitlesAsync(token);
        var result = new List<AgentSession>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in Directory.EnumerateFiles(_sessionsRoot, "*.jsonl", SearchOption.AllDirectories))
        {
            token.ThrowIfCancellationRequested();
            seen.Add(path);
            try
            {
                var file = new FileInfo(path);
                if (!_cache.TryGetValue(path, out var cached) || cached.Length != file.Length || cached.Modified != file.LastWriteTimeUtc)
                {
                    var first = await SessionFileReader.ReadFirstLineAsync(path, token);
                    if (first is null) continue;
                    using var json = JsonDocument.Parse(first);
                    var root = json.RootElement;
                    if (GetString(root, "type") != "session_meta" || !root.TryGetProperty("payload", out var payload)) continue;
                    // Internal approval guardian is not a user conversation or a task agent.
                    if (payload.TryGetProperty("source", out var source) && source.ValueKind == JsonValueKind.Object
                        && source.TryGetProperty("subagent", out var subagent)
                        && GetString(subagent, "other") == "guardian") continue;
                    // Child threads can share session_id, but have their own id.
                    var id = GetString(payload, "id") ?? GetString(payload, "session_id");
                    if (id is null) continue;
                    var cwd = GetString(payload, "cwd");
                    var session = cached is not null && file.Length >= cached.Length ? cached.Session : new AgentSession
                    {
                        Id = $"codex:{id}", AgentType = AgentType, ProjectPath = cwd, WorktreePath = GitRoot.Find(cwd),
                        ParentSessionId = GetString(payload, "parent_thread_id") is { } parent ? $"codex:{parent}" : null,
                        StartedAt = ParseDate(GetString(payload, "timestamp")) ?? file.CreationTimeUtc,
                        LastActivityAt = ParseDate(GetString(root, "timestamp")) ?? ParseDate(GetString(payload, "timestamp")) ?? DateTime.MinValue, State = AgentState.Unknown
                    };
                    var pendingQuestion = cached is not null && file.Length >= cached.Length ? cached.PendingQuestion : null;
                    var pendingApprovals = cached is not null && file.Length >= cached.Length ? new HashSet<string>(cached.PendingApprovals) : new HashSet<string>();
                    var pendingApprovalWaits = cached is not null && file.Length >= cached.Length ? new Dictionary<string, string>(cached.PendingApprovalWaits) : new Dictionary<string, string>();
                    var pendingAsyncQuestion = cached is not null && file.Length >= cached.Length && cached.PendingAsyncQuestion;
                    var rateLimitReset = cached is not null && file.Length >= cached.Length ? cached.Session.RateLimitResetAt : null;
                    var limitWindowReset = cached is not null && file.Length >= cached.Length ? cached.LimitWindowReset : null;
                    var userApproves = cached is null || file.Length < cached.Length || cached.UserApproves;
                    // Windows may retain LastWriteTime while the writer keeps its handle open.
                    // Inspect a bounded tail when length changes, and use event timestamps.
                    await using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, true);
                    var offset = Math.Max(0, stream.Length - 262144);
                    stream.Seek(offset, SeekOrigin.Begin);
                    using var reader = new StreamReader(stream, Encoding.UTF8);
                    if (offset > 0) await reader.ReadLineAsync(token);
                    var tail = await reader.ReadToEndAsync(token);
                    foreach (var line in tail.Split('\n').SkipLast(1))
                    {
                        try
                        {
                            using var entry = JsonDocument.Parse(line);
                            var item = entry.RootElement;
                            var timestamp = ParseDate(GetString(item, "timestamp"));
                            if (timestamp is { } time && time >= session.LastActivityAt)
                            {
                                session = session with { LastActivityAt = time };
                                if (!item.TryGetProperty("payload", out var body)) continue;
                                var kind = (GetString(item, "type"), GetString(body, "type"));
                                if (ApprovalSettings(item, body) is { } settings) userApproves = UserApproves(settings);
                                if (kind is ("event_msg", "token_count"))
                                {
                                    limitWindowReset = ExhaustedWindowReset(body) ?? limitWindowReset;
                                    if (ParseWindow(body, "primary") is { } primary)
                                        session = session with { PrimaryLimit = primary, SecondaryLimit = ParseWindow(body, "secondary") ?? session.SecondaryLimit };
                                }
                                if (kind is ("event_msg", "task_started" or "user_message")) rateLimitReset = null;
                                if (kind.Item1 == "event_msg" && UsageLimitMessage(body) is { } limitMessage)
                                    rateLimitReset = RateLimitParser.ParseReset(limitMessage, time)
                                        ?? (limitWindowReset > time ? limitWindowReset : null) ?? time + RateLimitParser.FallbackDelay;
                                var isQuestion = kind is ("response_item", "function_call" or "custom_tool_call")
                                    && GetString(body, "name") is "request_user_input" or "functions.request_user_input";
                                var isAsyncQuestion = kind is ("response_item", "function_call" or "custom_tool_call")
                                    && GetString(body, "name") is "request_user_input_async" or "functions.request_user_input_async";
                                var isApproval = userApproves && kind is ("response_item", "function_call" or "custom_tool_call") && RequestsApproval(body);
                                var isAnswer = kind is ("response_item", "function_call_output" or "custom_tool_call_output")
                                    && pendingQuestion is not null && GetString(body, "call_id") == pendingQuestion;
                                var state = kind switch
                                {
                                    ("event_msg", "task_started" or "user_message") => AgentState.Working,
                                    ("event_msg", "task_complete") => AgentState.Idle,
                                    ("event_msg", "turn_aborted") => AgentState.Stopped,
                                    ("response_item", "reasoning") => AgentState.Thinking,
                                    ("response_item", "function_call" or "custom_tool_call") => AgentState.Working,
                                    _ => session.State
                                };
                                if (isQuestion)
                                {
                                    pendingQuestion = GetString(body, "call_id");
                                    state = AgentState.WaitingForInput;
                                }
                                else if (isAnswer)
                                {
                                    pendingQuestion = null;
                                    state = AgentState.Working;
                                }
                                else if (kind is ("event_msg", "task_started" or "user_message" or "task_complete" or "turn_aborted"))
                                    pendingQuestion = null;
                                if (kind is ("event_msg", "task_started" or "user_message" or "task_complete" or "turn_aborted"))
                                {
                                    pendingApprovals.Clear();
                                    pendingApprovalWaits.Clear();
                                }
                                if (isApproval && GetString(body, "call_id") is { } approvalId)
                                    pendingApprovals.Add(approvalId);
                                if (kind is ("response_item", "function_call" or "custom_tool_call")
                                    && ApprovalWaitCell(body) is { } cell && pendingApprovals.Contains(cell)
                                    && GetString(body, "call_id") is { } waitId)
                                    pendingApprovalWaits[waitId] = cell;
                                if (kind is ("response_item", "function_call_output" or "custom_tool_call_output")
                                    && GetString(body, "call_id") is { } outputId)
                                {
                                    var resolvesApproval = pendingApprovals.Remove(outputId);
                                    if (pendingApprovalWaits.Remove(outputId, out var waitedCell))
                                        resolvesApproval |= pendingApprovals.Remove(waitedCell);
                                    if (resolvesApproval)
                                    {
                                        // Codex Work (2026-10-16): exec can yield while approval is still pending.
                                        // Track its cell until wait returns the final result, including after restart.
                                        if (RunningApprovalCell(body) is { } runningCell) pendingApprovals.Add(runningCell);
                                        state = AgentState.Working;
                                    }
                                }
                                if (isAsyncQuestion) pendingAsyncQuestion = true;
                                // Async tool output acknowledges delivery, not a user answer.
                                // Any subsequent user message ends this inferred waiting state.
                                if (kind is ("event_msg", "user_message" or "turn_aborted"))
                                    pendingAsyncQuestion = false;
                                if (pendingAsyncQuestion) state = AgentState.WaitingForInput;
                                if (pendingApprovals.Count > 0) state = AgentState.WaitingForApproval;
                                session = session with { State = state, RateLimitResetAt = rateLimitReset };
                            }
                        }
                        catch (JsonException) { }
                    }
                    if (session.LastActivityAt == DateTime.MinValue) session = session with { LastActivityAt = file.LastWriteTimeUtc };
                    cached = new(file.Length, file.LastWriteTimeUtc, session, pendingQuestion, pendingAsyncQuestion, limitWindowReset, pendingApprovals, pendingApprovalWaits, userApproves);
                    _cache[path] = cached;
                }
                var now = DateTime.UtcNow;
                var age = now - cached.Session.LastActivityAt;
                var activeWindow = ActiveWindow;
                // 한도 대기 세션은 리셋 후 자동 재개가 가능할 때까지 활성으로 유지
                var limitPending = cached.Session.RateLimitResetAt is { } reset && now < reset + LimitGrace;
                var limited = cached.Session.RateLimitResetAt > now;
                // Without a per-thread PID, recent event activity is evidence, not proof of liveness.
                if (age <= TimeSpan.FromMinutes(30) || age <= activeWindow || limitPending)
                    result.Add(cached.Session with
                    {
                        SessionTitle = _titles.GetValueOrDefault(cached.Session.Id),
                        State = limited ? AgentState.RateLimited : cached.Session.State,
                        IsActive = limitPending || (cached.Session.State != AgentState.Stopped && age <= activeWindow)
                    });
            }
            catch (JsonException) { }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        foreach (var path in _cache.Keys.Where(path => !seen.Contains(path)).ToArray()) _cache.Remove(path);
        return result;
    }
    // turn_context payload 또는 thread_settings_applied.thread_settings (Codex Work 2026-10-19 확인)
    private static JsonElement? ApprovalSettings(JsonElement item, JsonElement body)
    {
        var settings = GetString(item, "type") == "turn_context" ? body
            : GetString(body, "type") == "thread_settings_applied" && body.TryGetProperty("thread_settings", out var nested) ? nested : default;
        return GetString(settings, "approval_policy") is not null || GetString(settings, "approvals_reviewer") is not null ? settings : null;
    }
    // approvals_reviewer=auto_review면 가디언이 자동 심사하고, approval_policy=never면 묻지 않음 → 사용자 승인 대기 아님
    private static bool UserApproves(JsonElement settings)
        => GetString(settings, "approval_policy") != "never" && GetString(settings, "approvals_reviewer") is null or "user";
    // Approval is inferred from the requested sandbox mode until the matching tool output.
    private static bool RequestsApproval(JsonElement body)
    {
        if (GetString(body, "arguments") is { } arguments)
        {
            try
            {
                using var json = JsonDocument.Parse(arguments);
                return GetString(json.RootElement, "sandbox_permissions") == "require_escalated";
            }
            catch (JsonException) { }
        }
        // Code-mode wrapper observed in Codex Work (2026-10-16); input is JavaScript, not JSON.
        return GetString(body, "name") is "exec" or "functions.exec"
            && GetString(body, "input") is { } input
            && System.Text.RegularExpressions.Regex.IsMatch(input,
                """\bsandbox_permissions\s*["']?\s*:\s*["']require_escalated["']""");
    }
    private static string? ApprovalWaitCell(JsonElement body)
    {
        if (GetString(body, "name") is not ("wait" or "functions.wait") || GetString(body, "arguments") is not { } arguments) return null;
        try
        {
            using var json = JsonDocument.Parse(arguments);
            return GetString(json.RootElement, "cell_id") is { } cell ? "cell:" + cell : null;
        }
        catch (JsonException) { return null; }
    }
    private static string? RunningApprovalCell(JsonElement body)
    {
        if (!body.TryGetProperty("output", out var output)) return null;
        var text = output.ValueKind == JsonValueKind.String ? output.GetString() ?? ""
            : output.ValueKind == JsonValueKind.Array ? string.Join("\n", output.EnumerateArray().Select(x => GetString(x, "text"))) : "";
        var match = System.Text.RegularExpressions.Regex.Match(text, @"(?:^|\n)Script running with cell ID ([^\s]+)");
        return match.Success ? "cell:" + match.Groups[1].Value : null;
    }
    private sealed record CachedSession(long Length, DateTime Modified, AgentSession Session, string? PendingQuestion, bool PendingAsyncQuestion, DateTime? LimitWindowReset, HashSet<string> PendingApprovals, Dictionary<string, string> PendingApprovalWaits, bool UserApproves);
    // 리셋 후 이 시간 동안은 재개를 기다리는 세션으로 표시
    public static readonly TimeSpan LimitGrace = TimeSpan.FromMinutes(30);
    // task_complete 등의 error.codex_error_info가 usage_limit_exceeded면 그 문구
    private static string? UsageLimitMessage(JsonElement body)
    {
        var error = body.TryGetProperty("error", out var nested) && nested.ValueKind == JsonValueKind.Object ? nested : body;
        return GetString(error, "codex_error_info") == "usage_limit_exceeded" ? GetString(error, "message") ?? "" : null;
    }
    // token_count.rate_limits에서 100% 소진된 창의 가장 늦은 리셋 시각
    private static DateTime? ExhaustedWindowReset(JsonElement body)
    {
        if (!body.TryGetProperty("rate_limits", out var limits) || limits.ValueKind != JsonValueKind.Object) return null;
        DateTime? latest = null;
        foreach (var name in new[] { "primary", "secondary" })
        {
            if (!limits.TryGetProperty(name, out var window) || window.ValueKind != JsonValueKind.Object) continue;
            if (!window.TryGetProperty("used_percent", out var used) || used.ValueKind != JsonValueKind.Number || used.GetDouble() < 100) continue;
            if (!window.TryGetProperty("resets_at", out var resets) || !resets.TryGetInt64(out var seconds)) continue;
            var time = DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime;
            if (latest is null || time > latest) latest = time;
        }
        return latest;
    }
    private static LimitWindow? ParseWindow(JsonElement body, string name)
    {
        if (!body.TryGetProperty("rate_limits", out var limits) || limits.ValueKind != JsonValueKind.Object
            || !limits.TryGetProperty(name, out var window) || window.ValueKind != JsonValueKind.Object
            || !window.TryGetProperty("used_percent", out var used) || used.ValueKind != JsonValueKind.Number
            || !window.TryGetProperty("resets_at", out var resets) || !resets.TryGetInt64(out var seconds)) return null;
        return new LimitWindow(used.GetDouble(), DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime);
    }
    private async Task RefreshTitlesAsync(CancellationToken token)
    {
        try
        {
            var info = new FileInfo(_indexPath);
            if (!info.Exists) { _titles.Clear(); _indexStamp = null; return; }
            var stamp = (info.Length, info.LastWriteTimeUtc);
            if (_indexStamp == stamp) return;
            var titles = new Dictionary<string, string>();
            await using var stream = new FileStream(_indexPath, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 4096, true);
            using var reader = new StreamReader(stream);
            while (await reader.ReadLineAsync(token) is { } line)
            {
                try
                {
                    using var json = JsonDocument.Parse(line);
                    if (GetString(json.RootElement, "id") is { } id && GetString(json.RootElement, "thread_name") is { } title)
                        titles[$"codex:{id}"] = title;
                }
                catch (JsonException) { }
            }
            _titles = titles;
            _indexStamp = stamp;
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }
    private static string? GetString(JsonElement element, string name) => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() : null;
    private static DateTime? ParseDate(string? value) => DateTime.TryParse(value, null, System.Globalization.DateTimeStyles.RoundtripKind, out var parsed) ? parsed.ToUniversalTime() : null;
}
