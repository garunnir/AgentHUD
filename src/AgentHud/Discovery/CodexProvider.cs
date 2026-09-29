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
                    var pendingAsyncQuestion = cached is not null && file.Length >= cached.Length && cached.PendingAsyncQuestion;
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
                                var isQuestion = kind is ("response_item", "function_call" or "custom_tool_call")
                                    && GetString(body, "name") is "request_user_input" or "functions.request_user_input";
                                var isAsyncQuestion = kind is ("response_item", "function_call" or "custom_tool_call")
                                    && GetString(body, "name") is "request_user_input_async" or "functions.request_user_input_async";
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
                                if (isAsyncQuestion) pendingAsyncQuestion = true;
                                // Async tool output acknowledges delivery, not a user answer.
                                // Any subsequent user message ends this inferred waiting state.
                                if (kind is ("event_msg", "user_message" or "turn_aborted"))
                                    pendingAsyncQuestion = false;
                                if (pendingAsyncQuestion) state = AgentState.WaitingForInput;
                                session = session with { State = state };
                            }
                        }
                        catch (JsonException) { }
                    }
                    if (session.LastActivityAt == DateTime.MinValue) session = session with { LastActivityAt = file.LastWriteTimeUtc };
                    cached = new(file.Length, file.LastWriteTimeUtc, session, pendingQuestion, pendingAsyncQuestion);
                    _cache[path] = cached;
                }
                var age = DateTime.UtcNow - cached.Session.LastActivityAt;
                var activeWindow = ActiveWindow;
                // Without a per-thread PID, recent event activity is evidence, not proof of liveness.
                if (age <= TimeSpan.FromMinutes(30) || age <= activeWindow)
                    result.Add(cached.Session with { SessionTitle = _titles.GetValueOrDefault(cached.Session.Id), IsActive = cached.Session.State != AgentState.Stopped && age <= activeWindow });
            }
            catch (JsonException) { }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
        foreach (var path in _cache.Keys.Where(path => !seen.Contains(path)).ToArray()) _cache.Remove(path);
        return result;
    }
    private sealed record CachedSession(long Length, DateTime Modified, AgentSession Session, string? PendingQuestion, bool PendingAsyncQuestion);
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
