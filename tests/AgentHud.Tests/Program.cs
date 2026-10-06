using AgentHud.Discovery;
using AgentHud.Models;

var registry = new AgentSessionRegistry();
var a = new AgentSession { Id="claude:a", AgentType=AgentType.ClaudeCode, State=AgentState.Working, ProcessId=42, ProjectPath="C:\\repo", StartedAt=DateTime.UtcNow, LastActivityAt=DateTime.UtcNow, IsActive=true };
registry.Register(a);
Assert(registry.GetActiveAgents().Count == 1, "active lookup");
Assert(registry.GetByProcessId(42)?.Id == a.Id, "pid lookup");
registry.Update(a with { State=AgentState.Stopped, IsActive=false });
Assert(registry.GetActiveAgents().Count == 0, "update");
Assert(registry.Remove(a.Id), "remove");
registry.Replace([a with { LastActivityAt = a.LastActivityAt.AddMinutes(-1) }, a]);
Assert(registry.GetAllAgents().Count == 1 && registry.FindSession(a.Id) == a, "duplicate observations keep newest session");
var older = a with { Id = "codex:older", AgentType = AgentType.Codex, LastActivityAt = a.LastActivityAt.AddMinutes(-5) };
var recentIdle = a with { Id = "claude:recent", IsActive = false, LastActivityAt = a.LastActivityAt.AddMinutes(1) };
registry.Replace([older, a, recentIdle]);
Assert(registry.GetAllAgents().Select(x => x.Id).SequenceEqual(["claude:recent", a.Id, "codex:older"]), "most recently active sessions are listed first");
var testHome = Path.Combine(Path.GetTempPath(), "AgentHud-tests-" + Guid.NewGuid().ToString("N"));
var completionRegistry = new AgentSessionRegistry();
completionRegistry.Replace([a with { State = AgentState.Idle }]);
Assert(!completionRegistry.FindSession(a.Id)!.HasUnreadCompletion, "existing idle sessions do not notify on startup");
completionRegistry.Replace([a]);
completionRegistry.Replace([a with { State = AgentState.Idle }]);
Assert(completionRegistry.FindSession(a.Id)!.HasUnreadCompletion, "work ending creates unread completion");
completionRegistry.Replace([a with { State = AgentState.Idle, IsActive = false }]);
Assert(completionRegistry.FindSession(a.Id)!.DisplayState == AgentState.Completed, "completion persists through refresh and inactivity");
completionRegistry.Replace([]);
Assert(completionRegistry.FindSession(a.Id)!.HasUnreadCompletion, "missing session retained until acknowledged");
completionRegistry.AcknowledgeCompletion(a.Id);
completionRegistry.Replace([a with { State = AgentState.Idle }]);
Assert(!completionRegistry.FindSession(a.Id)!.HasUnreadCompletion, "refresh does not re-notify acknowledged completion");
completionRegistry.Replace([a]);
completionRegistry.Replace([a with { State = AgentState.Idle }]);
Assert(completionRegistry.FindSession(a.Id)!.HasUnreadCompletion, "next completion notifies again");
foreach (var resumedState in new[] { AgentState.Starting, AgentState.Working, AgentState.Thinking, AgentState.WaitingForInput, AgentState.WaitingForApproval })
{
    completionRegistry.Replace([a with { State = resumedState }]);
    Assert(!completionRegistry.FindSession(a.Id)!.HasUnreadCompletion
        && completionRegistry.FindSession(a.Id)!.DisplayState == resumedState,
        $"new work clears unread completion and displays {resumedState}");
    completionRegistry.Update(a);
    completionRegistry.Update(a with { State = AgentState.Idle });
    Assert(completionRegistry.FindSession(a.Id)!.HasUnreadCompletion, "completion after resumed work notifies again");
}
completionRegistry.Update(a);
Assert(!completionRegistry.FindSession(a.Id)!.HasUnreadCompletion, "direct update also clears completion on new work");
completionRegistry.Update(a with { State = AgentState.Idle });
completionRegistry.AcknowledgeCompletion(a.Id);
completionRegistry.Replace([a with { State = AgentState.Completed }]);
completionRegistry.AcknowledgeCompletion(a.Id);
completionRegistry.Replace([a with { State = AgentState.Completed }]);
Assert(!completionRegistry.FindSession(a.Id)!.HasUnreadCompletion, "explicit completion stays acknowledged");
var sessionsRoot = Path.Combine(testHome, ".claude", "sessions");
var clock = new TestTimeProvider();
var expiring = new AgentSessionRegistry(clock);
expiring.Replace([a]);
expiring.Replace([a with { State = AgentState.Idle }]);
clock.Now = clock.Now.AddMinutes(4).AddSeconds(59);
expiring.Replace([a with { State = AgentState.Idle, LastActivityAt = a.LastActivityAt.AddMinutes(4) }]);
Assert(expiring.FindSession(a.Id)!.HasUnreadCompletion, "completion remains blue before five minutes despite refresh");
clock.Now = clock.Now.AddSeconds(1);
expiring.Replace([a with { State = AgentState.Idle }]);
Assert(!expiring.FindSession(a.Id)!.HasUnreadCompletion && expiring.FindSession(a.Id)!.DisplayState == AgentState.Idle,
    "completion expires to idle at five minutes");
expiring.Replace([a with { State = AgentState.Idle }]);
Assert(!expiring.FindSession(a.Id)!.HasUnreadCompletion, "expired notification does not return on refresh");
expiring.Update(a);
expiring.Update(a with { State = AgentState.Completed });
Assert(expiring.FindSession(a.Id)!.HasUnreadCompletion, "next task gets a fresh completion timer");
clock.Now = clock.Now.AddMinutes(5);
expiring.Update(a with { State = AgentState.Completed });
Assert(expiring.FindSession(a.Id)!.DisplayState == AgentState.Idle, "explicit completed state displays idle after timeout");
expiring.Update(a);
expiring.Update(a with { State = AgentState.Idle });
expiring.Replace([]);
Assert(expiring.FindSession(a.Id)!.HasUnreadCompletion, "missing completion retained before timeout");
clock.Now = clock.Now.AddMinutes(5);
expiring.Replace([]);
Assert(expiring.FindSession(a.Id) is null, "missing completion removed after timeout");
Directory.CreateDirectory(sessionsRoot);
try
{
    var now = DateTimeOffset.UtcNow;
    var metadata = new { pid = Environment.ProcessId, sessionId = "vscode-session", cwd = testHome,
        startedAt = now.AddMinutes(-10).ToUnixTimeMilliseconds(), updatedAt = now.ToUnixTimeMilliseconds(), status = "working" };
    var metadataPath = Path.Combine(sessionsRoot, "session.json");
    await File.WriteAllTextAsync(metadataPath, System.Text.Json.JsonSerializer.Serialize(metadata));
    var provider = new ClaudeCodeProvider(testHome);
    var found = await provider.DiscoverAsync(CancellationToken.None);
    Assert(found.Count == 1, "camelCase metadata with numeric timestamps is discovered");
    Assert(found[0].IsActive && found[0].State == AgentState.Working, "live VS Code session remains active");
    Assert(found[0].ProcessId == Environment.ProcessId && found[0].Id == "claude:vscode-session", "session identity");
    Assert(found[0].LastActivityAt == DateTimeOffset.FromUnixTimeMilliseconds(metadata.updatedAt).UtcDateTime, "Unix millisecond timestamp");

    await File.WriteAllTextAsync(metadataPath, System.Text.Json.JsonSerializer.Serialize(new {
        pid = Environment.ProcessId, sessionId = "iso-session", startedAt = now.ToString("O"), updatedAt = now.ToString("O"), status = "waiting" }));
    found = await provider.DiscoverAsync(CancellationToken.None);
    Assert(found.Single().State == AgentState.WaitingForInput, "ISO timestamp compatibility");
    await File.WriteAllTextAsync(metadataPath, System.Text.Json.JsonSerializer.Serialize(new {
        pid = Environment.ProcessId, sessionId = "busy-session", updatedAt = now.ToUnixTimeMilliseconds(), status = "busy" }));
    found = await provider.DiscoverAsync(CancellationToken.None);
    Assert(found.Single().State == AgentState.Working, "Claude busy status maps to Working");
    var titleId = Guid.NewGuid().ToString();
    var emptyVsCodeId = Guid.NewGuid().ToString();
    await File.WriteAllTextAsync(metadataPath, System.Text.Json.JsonSerializer.Serialize(new {
        pid = Environment.ProcessId, sessionId = emptyVsCodeId, entrypoint = "claude-vscode", status = "idle" }));
    Assert((await provider.DiscoverAsync(CancellationToken.None)).Count == 0, "unused VS Code idle process is hidden");
    await File.WriteAllTextAsync(metadataPath, System.Text.Json.JsonSerializer.Serialize(new {
        pid = Environment.ProcessId, sessionId = emptyVsCodeId, entrypoint = "claude-vscode", status = "busy" }));
    Assert((await provider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Working,
        "VS Code working session is visible even before transcript is created");
    var projectLogs = Path.Combine(testHome, ".claude", "projects", "test-project");
    Directory.CreateDirectory(projectLogs);
    var transcript = Path.Combine(projectLogs, titleId + ".jsonl");
    await File.WriteAllTextAsync(metadataPath, System.Text.Json.JsonSerializer.Serialize(new {
        pid = Environment.ProcessId, sessionId = titleId, name = "derived-88", status = "idle", entrypoint = "claude-vscode" }));
    await File.WriteAllTextAsync(transcript, System.Text.Json.JsonSerializer.Serialize(new {
        type = "ai-title", aiTitle = "실제 대화 제목", sessionId = titleId }) + "\n");
    found = await provider.DiscoverAsync(CancellationToken.None);
    Assert(found.Single().SessionTitle == "실제 대화 제목", "Claude conversation title overrides derived name");
    await File.AppendAllTextAsync(transcript, System.Text.Json.JsonSerializer.Serialize(new {
        type = "ai-title", aiTitle = "변경된 대화 제목", sessionId = titleId }) + "\n");
    found = await provider.DiscoverAsync(CancellationToken.None);
    Assert(found.Single().SessionTitle == "변경된 대화 제목", "Claude title refreshes on transcript growth");

    await File.WriteAllTextAsync(metadataPath, "{\"pid\":2147483647,\"sessionId\":\"stopped\",\"updatedAt\":9223372036854775807}");
    found = await provider.DiscoverAsync(CancellationToken.None);
    Assert(!found.Single().IsActive && found[0].State == AgentState.Stopped, "dead process and invalid timestamp fallback");

    async Task AppendClaudeBlock(string type, object block, string? sessionId = null)
    {
        await File.AppendAllTextAsync(transcript, System.Text.Json.JsonSerializer.Serialize(new {
            type, sessionId = sessionId ?? titleId, message = new { content = new[] { block } }
        }) + "\n");
    }
    await File.WriteAllTextAsync(metadataPath, System.Text.Json.JsonSerializer.Serialize(new {
        pid = Environment.ProcessId, sessionId = titleId, status = "busy" }));
    await AppendClaudeBlock("assistant", new { type = "tool_use", name = "AskUserQuestion", id = "ask-1" });
    found = await provider.DiscoverAsync(CancellationToken.None);
    Assert(found.Single().State == AgentState.WaitingForInput, "Claude question overrides busy metadata");
    Assert(found.Single().SessionTitle == "변경된 대화 제목", "question scanning preserves title");
    Assert((await new ClaudeCodeProvider(testHome).DiscoverAsync(CancellationToken.None)).Single().State == AgentState.WaitingForInput,
        "Claude question detected after provider restart");
    await AppendClaudeBlock("user", new { type = "tool_result", tool_use_id = "other", content = "done" });
    await AppendClaudeBlock("user", new { type = "tool_result", tool_use_id = "ask-1", content = "answer" }, "other-session");
    Assert((await provider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.WaitingForInput,
        "unrelated Claude tool results and sessions do not clear question");
    await AppendClaudeBlock("user", new { type = "tool_result", tool_use_id = "ask-1", content = "answer" });
    Assert((await provider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Working,
        "Claude answer restores metadata state");
    await AppendClaudeBlock("assistant", new { type = "tool_use", name = "AskUserQuestion", id = "ask-2" });
    await AppendClaudeBlock("user", new { type = "tool_result", tool_use_id = "ask-2", is_error = true, content = "cancelled" });
    Assert((await provider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Working,
        "Claude cancelled question clears wait");
    await AppendClaudeBlock("assistant", new { type = "tool_use", name = "AskUserQuestion", id = "ask-3" });
    await File.WriteAllTextAsync(metadataPath, System.Text.Json.JsonSerializer.Serialize(new {
        pid = 2147483647, sessionId = titleId, status = "busy" }));
    Assert((await provider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Stopped,
        "pending Claude question does not override dead process");
    var codexRoot = Path.Combine(testHome, ".codex", "sessions");
    Directory.CreateDirectory(codexRoot);
    await File.WriteAllTextAsync(Path.Combine(codexRoot, "guardian.jsonl"),
        System.Text.Json.JsonSerializer.Serialize(new { type = "session_meta", payload = new {
            id = "guardian", session_id = "parent", parent_thread_id = "parent",
            source = new { subagent = new { other = "guardian" } }
        } }) + "\n");
    await File.WriteAllTextAsync(Path.Combine(codexRoot, "parent.jsonl"),
        "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"parent\",\"id\":\"parent\"}}\n");
    await File.WriteAllTextAsync(Path.Combine(codexRoot, "child.jsonl"),
        "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"parent\",\"id\":\"child\",\"parent_thread_id\":\"parent\"}}\n");
    await File.WriteAllTextAsync(Path.Combine(codexRoot, "legacy.jsonl"),
        "{\"type\":\"session_meta\",\"payload\":{\"session_id\":\"legacy\"}}\n");
    var combined = new AgentSessionRegistry();
    var notifications = 0;
    combined.Changed += (_, _) => notifications++;
    await using var discovery = new AgentDiscoveryService([provider, new CodexProvider(testHome)], combined);
    await discovery.RefreshAsync(CancellationToken.None);
    Assert(combined.GetAllAgents().Count == 4, "parent, child, legacy and Claude reach HUD registry together");
    Assert(combined.FindSession("codex:child")?.ParentSessionId == "codex:parent", "child thread identity and parent link");
    Assert(combined.FindSession("codex:guardian") is null, "internal guardian is excluded while task subagents remain visible");
    await discovery.RefreshAsync(CancellationToken.None);
    Assert(notifications == 2, "HUD notifications continue after repeated refresh");
    var livePath = Path.Combine(codexRoot, "live.jsonl");
    var old = DateTime.UtcNow.AddHours(-1);
    await File.WriteAllTextAsync(livePath, "{\"type\":\"session_meta\",\"payload\":{\"id\":\"live\"}}\n");
    async Task AppendEvent(string eventType)
    {
        await File.AppendAllTextAsync(livePath, System.Text.Json.JsonSerializer.Serialize(new {
            timestamp = DateTime.UtcNow.ToString("O"), type = "event_msg", payload = new { type = eventType }
        }) + "\n");
        File.SetLastWriteTimeUtc(livePath, old);
    }
    var codex = new CodexProvider(testHome);
    await AppendEvent("task_started");
    var live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.IsActive && live.State == AgentState.Working, "recent event in file with stale mtime is active");
    await AppendEvent("task_complete");
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.IsActive && live.State == AgentState.Idle, "size change updates completion to idle despite unchanged mtime");
    await AppendEvent("task_started");
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.State == AgentState.Working, "next turn resumes working");
    async Task AppendResponse(object payload)
    {
        await File.AppendAllTextAsync(livePath, System.Text.Json.JsonSerializer.Serialize(new {
            timestamp = DateTime.UtcNow.ToString("O"), type = "response_item", payload
        }) + "\n");
    }
    foreach (var name in new[] { "request_user_input", "functions.request_user_input" })
    {
        await AppendResponse(new { type = "function_call", name, call_id = "question" });
        live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
        Assert(live.State == AgentState.WaitingForInput, "question tool enters input wait");
        live = (await new CodexProvider(testHome).DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
        Assert(live.State == AgentState.WaitingForInput, "question wait discovered on startup");
        await AppendResponse(new { type = "function_call_output", call_id = "unrelated", output = "done" });
        live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
        Assert(live.State == AgentState.WaitingForInput, "unrelated output does not answer question");
        await AppendResponse(new { type = "function_call_output", call_id = "question", output = "answer" });
        live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
        Assert(live.State == AgentState.Working, "question response resumes work");
    }
    await AppendResponse(new { type = "function_call", name = "request_user_input_async", call_id = "async-question" });
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.State == AgentState.WaitingForInput, "async question waits for user");
    await AppendResponse(new { type = "function_call_output", call_id = "async-question", output = "{\"accepted\":true}" });
    await AppendResponse(new { type = "reasoning" });
    await AppendEvent("task_complete");
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.State == AgentState.WaitingForInput, "async acceptance and turn completion do not answer question");
    live = (await new CodexProvider(testHome).DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.State == AgentState.WaitingForInput, "async wait survives provider restart");
    await AppendEvent("user_message");
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.State == AgentState.Working, "user message clears inferred async wait");
    codex.ActiveWindow = TimeSpan.Zero;
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(!live.IsActive, "configured active window expires recent session");
    codex.ActiveWindow = TimeSpan.FromHours(2);
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.IsActive, "longer active window keeps session active");
    await AppendEvent("turn_aborted");
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(!live.IsActive && live.State == AgentState.Stopped, "aborted turn stops");
}
finally { Directory.Delete(testHome, recursive: true); }
var memoPath = Path.Combine(Path.GetTempPath(), "AgentHud-memos-" + Guid.NewGuid().ToString("N") + ".json");
try
{
    var memos = new AgentHud.MemoStore(memoPath);
    var changes = 0;
    memos.Changed += (_, _) => changes++;
    memos.SetGlobal("todo");
    memos.SetProject("C:\\Repo\\", "project note");
    Assert(memos.HasProject("c:\\repo") && memos.GetProject("C:\\Repo") == "project note", "project memo lookup ignores case and trailing separator");
    Assert(!memos.HasProject("C:\\other") && !memos.HasProject(null), "missing project memo");
    memos.SetGlobal("todo");
    Assert(changes == 2, "unchanged memo does not save");
    var reloaded = new AgentHud.MemoStore(memoPath);
    Assert(reloaded.Global == "todo" && reloaded.GetProject("c:\\REPO") == "project note", "memos persist across reload");
    reloaded.SetProject("C:\\Repo", "  ");
    Assert(!new AgentHud.MemoStore(memoPath).HasProject("C:\\Repo"), "blank project memo removes it");
}
finally { File.Delete(memoPath); }
var seoul = TimeZoneInfo.FindSystemTimeZoneById("Asia/Seoul");
var limitEvent = new DateTime(2026, 9, 29, 5, 29, 3, DateTimeKind.Utc); // 14:29 KST
Assert(RateLimitParser.ParseReset("You've hit your usage limit. ... or try again at 4:34 PM.", limitEvent, seoul) == new DateTime(2026, 9, 29, 7, 34, 0, DateTimeKind.Utc),
    "Codex reset clock time in local zone");
Assert(RateLimitParser.ParseReset("try again at 1:05 PM.", limitEvent, seoul) == new DateTime(2026, 9, 30, 4, 5, 0, DateTimeKind.Utc),
    "reset clock earlier than event rolls to next day");
Assert(RateLimitParser.ParseReset("You've hit your limit · resets 3pm (Asia/Seoul)", limitEvent) == new DateTime(2026, 9, 29, 6, 0, 0, DateTimeKind.Utc),
    "Claude reset with IANA time zone");
Assert(RateLimitParser.ParseReset("Weekly limit reached ∙ resets Oct 3, 4:30pm", limitEvent, seoul) == new DateTime(2026, 10, 3, 7, 30, 0, DateTimeKind.Utc),
    "reset with month and day");
Assert(RateLimitParser.ParseReset("Claude AI usage limit reached|1790686347", limitEvent) == DateTimeOffset.FromUnixTimeSeconds(1790686347).UtcDateTime,
    "legacy unix reset suffix");
Assert(RateLimitParser.ParseReset("try again in 2 hours 15 minutes", limitEvent) == limitEvent.AddMinutes(135), "relative reset");
Assert(RateLimitParser.ParseReset("Credit balance is too low", limitEvent) is null && !RateLimitParser.LooksLikeUsageLimit("Credit balance is too low"),
    "billing error is not a usage limit");
var limitHome = Path.Combine(Path.GetTempPath(), "AgentHud-limit-" + Guid.NewGuid().ToString("N"));
try
{
    var codexDir = Path.Combine(limitHome, ".codex", "sessions");
    Directory.CreateDirectory(codexDir);
    var threadId = Guid.NewGuid().ToString();
    var rollout = Path.Combine(codexDir, "rollout-limit.jsonl");
    var stamp = DateTime.UtcNow.AddMinutes(-2);
    string Line(DateTime time, string type, object payload) => System.Text.Json.JsonSerializer.Serialize(new { timestamp = time.ToString("O"), type, payload }) + "\n";
    var resetAt = DateTimeOffset.UtcNow.AddHours(2).ToUnixTimeSeconds();
    await File.WriteAllTextAsync(rollout,
        Line(stamp, "session_meta", new { id = threadId, cwd = limitHome, timestamp = stamp.ToString("O") })
        + Line(stamp, "event_msg", new { type = "task_started" })
        + Line(stamp, "event_msg", new { type = "token_count", rate_limits = new { primary = new { used_percent = 100.0, window_minutes = 300, resets_at = resetAt } } })
        + Line(stamp, "event_msg", new { type = "task_complete", error = new { message = "You've hit your usage limit. Upgrade to Pro.", codex_error_info = "usage_limit_exceeded" } }));
    var limitedCodex = new CodexProvider(limitHome) { ActiveWindow = TimeSpan.Zero };
    var limited = (await limitedCodex.DiscoverAsync(CancellationToken.None)).Single();
    Assert(limited.State == AgentState.RateLimited && limited.IsActive, "Codex usage limit is rate limited and kept active");
    Assert(limited.RateLimitResetAt == DateTimeOffset.FromUnixTimeSeconds(resetAt).UtcDateTime, "Codex reset falls back to exhausted window");
    await File.AppendAllTextAsync(rollout, Line(DateTime.UtcNow, "event_msg", new { type = "user_message" }));
    limited = (await limitedCodex.DiscoverAsync(CancellationToken.None)).Single();
    Assert(limited.RateLimitResetAt is null && limited.State == AgentState.Working, "new Codex turn clears usage limit");
    var oldStamp = DateTime.UtcNow.AddHours(-3);
    await File.WriteAllTextAsync(rollout,
        Line(oldStamp, "session_meta", new { id = threadId, cwd = limitHome, timestamp = oldStamp.ToString("O") })
        + Line(oldStamp, "event_msg", new { type = "task_complete", error = new { message = "try again in 1 hours", codex_error_info = "usage_limit_exceeded" } }));
    Assert((await new CodexProvider(limitHome) { ActiveWindow = TimeSpan.Zero }.DiscoverAsync(CancellationToken.None)).Count == 0,
        "long-expired Codex limit does not keep session visible");

    var claudeSessions = Path.Combine(limitHome, ".claude", "sessions");
    var claudeProject = Path.Combine(limitHome, ".claude", "projects", "p");
    Directory.CreateDirectory(claudeSessions);
    Directory.CreateDirectory(claudeProject);
    var claudeId = Guid.NewGuid().ToString();
    await File.WriteAllTextAsync(Path.Combine(claudeSessions, "s.json"), System.Text.Json.JsonSerializer.Serialize(new {
        pid = Environment.ProcessId, sessionId = claudeId, cwd = limitHome, status = "idle" }));
    var claudeLog = Path.Combine(claudeProject, claudeId + ".jsonl");
    string ClaudeLine(string type, string text, bool apiError = false, string? error = null) => System.Text.Json.JsonSerializer.Serialize(new {
        type, sessionId = claudeId, timestamp = DateTime.UtcNow.ToString("O"), isApiErrorMessage = apiError, error,
        message = new { content = new[] { new { type = "text", text } } } }) + "\n";
    var resetLocal = DateTime.Now.AddHours(1);
    await File.WriteAllTextAsync(claudeLog, ClaudeLine("user", "작업해줘")
        + ClaudeLine("assistant", $"You've hit your limit · resets {resetLocal.ToString("h:mmtt", System.Globalization.CultureInfo.InvariantCulture)}", true, "rate_limit"));
    var claude = (await new ClaudeCodeProvider(limitHome).DiscoverAsync(CancellationToken.None)).Single();
    Assert(claude.State == AgentState.RateLimited && claude.RateLimitResetAt is { } claudeReset
        && Math.Abs((claudeReset - resetLocal.ToUniversalTime()).TotalMinutes) < 1, "Claude usage limit detected with reset time");
    await File.AppendAllTextAsync(claudeLog, ClaudeLine("user", "계속"));
    claude = (await new ClaudeCodeProvider(limitHome).DiscoverAsync(CancellationToken.None)).Single();
    Assert(claude.RateLimitResetAt is null && claude.State == AgentState.Idle, "new Claude message clears usage limit");
    await File.AppendAllTextAsync(claudeLog, ClaudeLine("assistant", "Credit balance is too low", true, "billing_error"));
    Assert((await new ClaudeCodeProvider(limitHome).DiscoverAsync(CancellationToken.None)).Single().RateLimitResetAt is null,
        "Claude billing error is not auto-resumable");

    // PATH에 codex가 없으면 VS Code 확장에 들어 있는 CLI를 찾음
    var fakeCodex = Path.Combine(limitHome, ".vscode", "extensions", "openai.chatgpt-1.0.0-win32-x64", "bin", "windows-x86_64", "codex.exe");
    Directory.CreateDirectory(Path.GetDirectoryName(fakeCodex)!);
    await File.WriteAllTextAsync(fakeCodex, "");
    var resumeClock = new TestTimeProvider();
    var launches = new List<(string Id, System.Diagnostics.ProcessStartInfo Info, string Prompt)>();
    var resumer = new AgentHud.AutoResumer(limitHome, limitHome, resumeClock, (session, info, prompt) => { launches.Add((session.Id, info, prompt)); return true; });
    var due = new AgentSession { Id = $"codex:{threadId}", AgentType = AgentType.Codex, ProjectPath = limitHome,
        RateLimitResetAt = resumeClock.Now.UtcDateTime.AddMinutes(-2) };
    resumer.Check([due]);
    Assert(launches.Count == 0, "auto resume is off by default");
    resumer.Enabled = true;
    resumer.Check([due with { RateLimitResetAt = resumeClock.Now.UtcDateTime.AddSeconds(-30) }]);
    Assert(launches.Count == 0, "auto resume waits after reset");
    resumer.Check([due, due with { Id = "codex:child", ParentSessionId = due.Id }, due with { Id = "codex:old", RateLimitResetAt = resumeClock.Now.UtcDateTime.AddHours(-2) }]);
    resumer.Check([due]);
    Assert(launches.Count == 1 && launches[0].Id == due.Id, "resume once per reset, skipping children and stale limits");
    Assert(launches[0].Info.ArgumentList.SequenceEqual(new[] { "exec", "resume", "--skip-git-repo-check", "-c", "sandbox_mode=workspace-write", threadId, "-" })
        && launches[0].Info.WorkingDirectory == limitHome && launches[0].Prompt == AgentHud.AutoResumer.DefaultPrompt, "Codex resume command");
    resumer.Check([due with { RateLimitResetAt = resumeClock.Now.UtcDateTime.AddMinutes(-3) }]);
    Assert(launches.Count == 2, "a new limit on the same session resumes again");
    var notifier = new AgentHud.RateLimitNotifier(resumeClock);
    Assert(notifier.TakeDue([due with { RateLimitResetAt = resumeClock.Now.UtcDateTime.AddMinutes(1) }]).Count == 0, "no reset notification before reset");
    Assert(notifier.TakeDue([due, due with { Id = "codex:child", ParentSessionId = due.Id }, due with { Id = "codex:old", RateLimitResetAt = resumeClock.Now.UtcDateTime.AddHours(-2) }])
        .Select(x => x.Id).SequenceEqual([due.Id]), "reset notification for due top-level session only");
    Assert(notifier.TakeDue([due]).Count == 0, "reset notified once");
    notifier.Enabled = false;
    Assert(notifier.TakeDue([due with { RateLimitResetAt = resumeClock.Now.UtcDateTime.AddMinutes(-5) }]).Count == 0, "reset notification can be turned off");
    var claudeInfo = resumer.CreateStartInfo(new AgentSession { Id = $"claude:{claudeId}", AgentType = AgentType.ClaudeCode, ProjectPath = limitHome });
    if (claudeInfo is not null)
        Assert(claudeInfo.ArgumentList.SkipWhile(x => x != "--resume").SequenceEqual(new[] { "--resume", claudeId, "-p", "--permission-mode", "acceptEdits" }), "Claude resume command");
    Assert(resumer.CreateStartInfo(due with { Id = "codex:not-a-guid & calc" }) is null, "non-GUID session ids are never passed to a command line");
}
finally { Directory.Delete(limitHome, recursive: true); }
var locTable = "# comment\nkey\ten\tko\tja\nLanguage.Name\tEnglish\t한국어\t日本語\nA\tHello\t안녕\t\nB\tOnly English\t\t\nC\tLine\\nBreak\t\t\n";
var korean = new AgentHud.Loc(new System.Globalization.CultureInfo("ko-KR"), new StringReader(locTable));
Assert(korean["A"] == "안녕", "system language (ko-KR → ko) is used");
Assert(korean["B"] == "Only English" && korean["Missing"] == "Missing", "missing strings fall back to English, then the key");
Assert(korean["C"] == "Line\nBreak", "table cells unescape \\n");
var french = new AgentHud.Loc(new System.Globalization.CultureInfo("fr-FR"), new StringReader(locTable));
Assert(french["A"] == "Hello", "untranslated system language uses English");
french.Language = "ko";
Assert(french["A"] == "안녕" && french["B"] == "Only English", "chosen language is used, then English");
korean.Language = "en";
Assert(korean["A"] == "Hello", "chosen language overrides the system language");
korean.Language = "xx";
Assert(korean.Language == AgentHud.Loc.Auto && korean["A"] == "안녕", "unknown language resets to the system language");
Assert(french.Languages.Select(x => x.Name).SequenceEqual(["English", "한국어", "日本語"]), "languages come from table header");
Assert(AgentHud.Loc.Instance["Settings.Title"] != "Settings.Title" && AgentHud.Loc.Instance["Language.Name"] != "Language.Name", "embedded Strings.tsv loads");
var promptResumer = new AgentHud.AutoResumer(Path.GetTempPath(), Path.GetTempPath());
promptResumer.Prompt = "사용량 한도로 중단됐던 작업을 이어서 진행해 주세요.";
Assert(promptResumer.CustomPrompt is null && promptResumer.Prompt == AgentHud.AutoResumer.DefaultPrompt, "a saved default prompt in any language follows the current language");
promptResumer.Prompt = "keep going";
Assert(promptResumer.CustomPrompt == "keep going", "a custom resume prompt is kept");
Console.WriteLine("All registry and discovery checks passed.");

if (args.Contains("--discover"))
{
    var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    var liveRegistry = new AgentSessionRegistry();
    foreach (var provider in new IAgentProvider[] { new ClaudeCodeProvider(home), new CodexProvider(home) })
    {
        var found = await provider.DiscoverAsync(CancellationToken.None);
        Console.WriteLine($"{provider.AgentType}: {found.Count} detected, {found.Count(x => x.IsActive)} active");
    }
    await using var discovery = new AgentDiscoveryService([new ClaudeCodeProvider(home), new CodexProvider(home)], liveRegistry);
    await discovery.RefreshAsync(CancellationToken.None);
    Console.WriteLine($"HUD registry: {liveRegistry.GetAllAgents().Count} sessions, {liveRegistry.GetActiveAgents().Count} active");
}
static void Assert(bool condition, string name) { if (!condition) throw new Exception($"Assertion failed: {name}"); }

sealed class TestTimeProvider : TimeProvider
{
    public DateTimeOffset Now { get; set; } = DateTimeOffset.UtcNow;
    public override DateTimeOffset GetUtcNow() => Now;
}
