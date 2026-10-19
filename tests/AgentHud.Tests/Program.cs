using AgentHud;
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
var wakeClock = new TestTimeProvider();
var wakeRegistry = new AgentSessionRegistry(wakeClock);
wakeRegistry.Replace([a]);
wakeRegistry.Replace([a with { State = AgentState.Idle, WakeupAt = wakeClock.Now.UtcDateTime.AddMinutes(2) }]);
Assert(!wakeRegistry.FindSession(a.Id)!.HasUnreadCompletion, "idle before a scheduled wakeup is not a completion");
wakeRegistry.Replace([a]);
wakeClock.Now = wakeClock.Now.AddMinutes(3);
wakeRegistry.Replace([a with { State = AgentState.Idle, WakeupAt = wakeClock.Now.UtcDateTime.AddMinutes(-1) }]);
Assert(wakeRegistry.FindSession(a.Id)!.HasUnreadCompletion, "idle after the wakeup time passed is a completion again");
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
    var midTurnId = Guid.NewGuid().ToString();
    var midTurnTranscript = Path.Combine(projectLogs, midTurnId + ".jsonl");
    string Line(string type, string stopReason, object block, bool sidechain = false) => System.Text.Json.JsonSerializer.Serialize(new {
        type, sessionId = midTurnId, isSidechain = sidechain, message = new { stop_reason = stopReason, content = new[] { block } } }) + "\n";
    await File.WriteAllTextAsync(metadataPath, System.Text.Json.JsonSerializer.Serialize(new {
        pid = Environment.ProcessId, sessionId = midTurnId, status = "idle" }));
    await File.WriteAllTextAsync(midTurnTranscript, Line("assistant", "tool_use", new { type = "tool_use", name = "Task", id = "t1" }));
    Assert((await provider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Working,
        "idle status with an open turn (tool_use) stays Working");
    await File.AppendAllTextAsync(midTurnTranscript, Line("user", "", new { type = "tool_result", tool_use_id = "t1", content = "x" }));
    Assert((await provider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Working,
        "idle status after tool_result stays Working until the turn ends");
    await File.AppendAllTextAsync(midTurnTranscript, Line("assistant", "end_turn", new { type = "text", text = "done" }));
    Assert((await provider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Idle,
        "end_turn closes the turn so idle is a real completion");
    await File.AppendAllTextAsync(midTurnTranscript, Line("assistant", "tool_use", new { type = "tool_use", name = "Read", id = "s1" }, sidechain: true));
    Assert((await provider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Idle,
        "sidechain records do not reopen the turn");
    var wakeId = Guid.NewGuid().ToString();
    var wakeTranscript = Path.Combine(projectLogs, wakeId + ".jsonl");
    string Stamped(string type, string stopReason, object block, DateTime at) => System.Text.Json.JsonSerializer.Serialize(new {
        type, sessionId = wakeId, timestamp = at.ToString("O"), message = new { stop_reason = stopReason, content = new[] { block } } }) + "\n";
    await File.WriteAllTextAsync(metadataPath, System.Text.Json.JsonSerializer.Serialize(new {
        pid = Environment.ProcessId, sessionId = wakeId, status = "idle" }));
    await File.WriteAllTextAsync(wakeTranscript,
        Stamped("assistant", "tool_use", new { type = "tool_use", name = "ScheduleWakeup", id = "w1", input = new { delaySeconds = 120 } }, DateTime.UtcNow)
        + Stamped("assistant", "end_turn", new { type = "text", text = "waiting" }, DateTime.UtcNow));
    var wakeFound = (await provider.DiscoverAsync(CancellationToken.None)).Single();
    Assert(wakeFound.WakeupAt > DateTime.UtcNow.AddMinutes(1), "ScheduleWakeup delay is read from the transcript");
    Assert(wakeFound.State == AgentState.Working, "idle before a scheduled wakeup is shown as Working");
    await File.AppendAllTextAsync(wakeTranscript, System.Text.Json.JsonSerializer.Serialize(new {
        type = "user", sessionId = wakeId, message = new { content = "wake up" } }) + "\n");
    Assert((await provider.DiscoverAsync(CancellationToken.None)).Single().WakeupAt is null, "wakeup prompt ends the scheduled wait");
    var bgId = Guid.NewGuid().ToString();
    var bgTranscript = Path.Combine(projectLogs, bgId + ".jsonl");
    string BgLine(string type, object content, bool sidechain = false) => System.Text.Json.JsonSerializer.Serialize(new {
        type, sessionId = bgId, isSidechain = sidechain, timestamp = DateTime.UtcNow.ToString("O"), message = new { content } }) + "\n";
    await File.WriteAllTextAsync(metadataPath, System.Text.Json.JsonSerializer.Serialize(new {
        pid = Environment.ProcessId, sessionId = bgId, status = "idle" }));
    await File.WriteAllTextAsync(bgTranscript,
        BgLine("user", new[] { new { type = "tool_result", tool_use_id = "plain", content = "Command running in background with ID: quoted1 (just quoted text)" } })
        + BgLine("assistant", new object[] {
            new { type = "tool_use", id = "b1", name = "Bash", input = new { command = "sleep 75", run_in_background = true } },
            new { type = "tool_use", id = "b2", name = "Agent", input = new { prompt = "x" } } })
        + BgLine("user", new[] { new { type = "tool_result", tool_use_id = "b1", content = "Command running in background with ID: bash1. Output is being written to: x" } })
        + BgLine("user", new[] { new { type = "tool_result", tool_use_id = "b2", content = new[] { new { type = "text", text = "Async agent launched successfully.\nagentId: agent1 (internal)" } } } }));
    var bgFound = (await provider.DiscoverAsync(CancellationToken.None)).Single();
    Assert(bgFound.HasBackgroundTasks && bgFound.State == AgentState.Working, "background Bash and Agent launches are tracked and shown as Working");
    await File.AppendAllTextAsync(bgTranscript, BgLine("user", "<task-notification>\n<task-id>bash1</task-id>\n<status>completed</status>\n</task-notification>"));
    Assert((await provider.DiscoverAsync(CancellationToken.None)).Single().HasBackgroundTasks, "one finished task leaves the other pending");
    await File.AppendAllTextAsync(bgTranscript, BgLine("user", "<task-notification>\n<task-id>agent1</task-id>\n<status>completed</status>\n</task-notification>"));
    Assert(!(await provider.DiscoverAsync(CancellationToken.None)).Single().HasBackgroundTasks, "task-notification clears finished background tasks");
    await File.AppendAllTextAsync(bgTranscript, BgLine("user", new[] { new { type = "tool_result", tool_use_id = "b3", content = "Command running in background with ID: bash2" } }, sidechain: true));
    Assert(!(await provider.DiscoverAsync(CancellationToken.None)).Single().HasBackgroundTasks, "sidechain background tasks are ignored");
    const string queuedNotice = "<task-notification>\n<task-id>bash3</task-id>\n<status>completed</status>\n</task-notification>";
    string BgStart(string callId, string taskId) =>
        BgLine("assistant", new object[] { new { type = "tool_use", id = callId, name = "Bash", input = new { command = "sleep 75", run_in_background = true } } })
        + BgLine("user", new[] { new { type = "tool_result", tool_use_id = callId, content = $"Command running in background with ID: {taskId}. Output is being written to: x" } });
    await File.AppendAllTextAsync(bgTranscript, BgStart("b4", "bash3"));
    Assert((await provider.DiscoverAsync(CancellationToken.None)).Single().HasBackgroundTasks, "second background Bash is tracked");
    await File.AppendAllTextAsync(bgTranscript, System.Text.Json.JsonSerializer.Serialize(new {
        type = "queue-operation", operation = "enqueue", sessionId = bgId, content = queuedNotice }) + "\n");
    Assert(!(await provider.DiscoverAsync(CancellationToken.None)).Single().HasBackgroundTasks, "queued mid-turn task-notification clears the background task");
    await File.AppendAllTextAsync(bgTranscript, BgStart("b5", "bash4") + System.Text.Json.JsonSerializer.Serialize(new {
        type = "attachment", sessionId = bgId, isSidechain = false,
        attachment = new { type = "queued_command", prompt = queuedNotice.Replace("bash3", "bash4") } }) + "\n");
    Assert(!(await provider.DiscoverAsync(CancellationToken.None)).Single().HasBackgroundTasks, "queued_command attachment clears the background task");
    await File.AppendAllTextAsync(bgTranscript,
        BgLine("assistant", new[] { new { type = "tool_use", id = "m1", name = "Monitor", input = new { command = "watch", description = "delegated work" } } })
        + BgLine("user", new[] { new { type = "tool_result", tool_use_id = "m1", content = "Monitor started (task monitor1, expires in 5m unless the source ends first)." } })
        + BgLine("assistant", new[] { new { type = "text", text = "Waiting for the delegated task." } }));
    var monitorWaiting = (await provider.DiscoverAsync(CancellationToken.None)).Single();
    Assert(monitorWaiting.HasBackgroundTasks && monitorWaiting.State == AgentState.Working,
        "idle while Monitor waits for delegated work is shown as Working");
    await File.AppendAllTextAsync(bgTranscript, BgLine("user", "<task-notification>\n<task-id>monitor1</task-id>\n<status>completed</status>\n</task-notification>"));
    Assert(!(await provider.DiscoverAsync(CancellationToken.None)).Single().HasBackgroundTasks,
        "Monitor task notification clears the delegated wait");
    var bgRegistry = new AgentSessionRegistry(new TestTimeProvider());
    bgRegistry.Replace([a]);
    bgRegistry.Replace([a with { State = AgentState.Idle, HasBackgroundTasks = true }]);
    Assert(!bgRegistry.FindSession(a.Id)!.HasUnreadCompletion, "idle with background tasks running is not a completion");
    bgRegistry.Replace([a]);
    bgRegistry.Replace([a with { State = AgentState.Idle }]);
    Assert(bgRegistry.FindSession(a.Id)!.HasUnreadCompletion, "idle after the notification-driven turn finishes is a completion");
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
    foreach (var approval in new object[] {
        new { type = "function_call", name = "exec_command", call_id = "approval", arguments = "{\"sandbox_permissions\":\"require_escalated\"}" },
        new { type = "custom_tool_call", name = "exec", call_id = "approval", input = "text(await tools.exec_command({cmd:\"Get-Location\",sandbox_permissions:\"require_escalated\"}));" },
        new { type = "custom_tool_call", name = "functions.exec", call_id = "approval", input = "await tools.exec_command({sandbox_permissions: \"require_escalated\"});" }
    })
    {
        await AppendResponse(approval);
        live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
        Assert(live.State == AgentState.WaitingForApproval, "escalated command waits for approval");
        await AppendResponse(new { type = "reasoning" });
        live = (await new CodexProvider(testHome).DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
        Assert(live.State == AgentState.WaitingForApproval, "approval survives reasoning and provider restart");
        await AppendResponse(new { type = "function_call_output", call_id = "unrelated", output = "done" });
        live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
        Assert(live.State == AgentState.WaitingForApproval, "unrelated output keeps approval pending");
        await AppendResponse(new { type = "function_call_output", call_id = "approval", output = "rejected by user" });
        live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
        Assert(live.State == AgentState.Working, "approval result clears wait");
    }
    // Code-mode exec may yield before the user approves; only its cell's final result ends the wait.
    await AppendResponse(new { type = "custom_tool_call", name = "exec", call_id = "yielded-approval", input = "await tools.exec_command({sandbox_permissions: 'require_escalated'});" });
    await AppendResponse(new { type = "custom_tool_call_output", call_id = "yielded-approval", output = new[] { new { type = "input_text", text = "Script running with cell ID 42\nWall time 30 seconds" } } });
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.State == AgentState.WaitingForApproval, "yielded exec preserves approval wait");
    codex = new CodexProvider(testHome);
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.State == AgentState.WaitingForApproval, "yielded approval survives restart");
    await AppendResponse(new { type = "function_call", name = "wait", call_id = "other-wait", arguments = "{\"cell_id\":\"99\"}" });
    await AppendResponse(new { type = "function_call_output", call_id = "other-wait", output = "Script completed" });
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.State == AgentState.WaitingForApproval, "unrelated cell completion preserves approval wait");
    await AppendResponse(new { type = "function_call", name = "functions.wait", call_id = "approval-wait", arguments = "{\"cell_id\":\"42\"}" });
    await AppendResponse(new { type = "function_call_output", call_id = "approval-wait", output = "Script running with cell ID 42\nWall time 10 seconds" });
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.State == AgentState.WaitingForApproval, "repeated yield preserves approval wait");
    await AppendResponse(new { type = "function_call", name = "wait", call_id = "approval-final", arguments = "{\"cell_id\":\"42\"}" });
    codex = new CodexProvider(testHome);
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.State == AgentState.WaitingForApproval, "pending wait call survives restart");
    await AppendResponse(new { type = "function_call_output", call_id = "approval-final", output = new[] { new { type = "input_text", text = "Script completed" } } });
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.State == AgentState.Working, "final cell result clears approval wait");
    await AppendResponse(new { type = "custom_tool_call", name = "exec", call_id = "aborted-approval", input = "await tools.exec_command({sandbox_permissions: 'require_escalated'});" });
    await AppendResponse(new { type = "custom_tool_call_output", call_id = "aborted-approval", output = "Script running with cell ID 43" });
    await AppendEvent("turn_aborted");
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(live.State == AgentState.Stopped, "abort clears yielded approval");
    await AppendEvent("task_started");
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
    await File.AppendAllTextAsync(claudeLog, System.Text.Json.JsonSerializer.Serialize(new {
        type = "assistant", sessionId = claudeId, message = new { content = new[] { new { type = "tool_use", name = "AskUserQuestion", id = "limited-question" } } }
    }) + "\n" + ClaudeLine("assistant", "try again in 1 hours", true, "rate_limit"));
    claude = (await new ClaudeCodeProvider(limitHome).DiscoverAsync(CancellationToken.None)).Single();
    Assert(claude.State == AgentState.WaitingForInput && claude.RateLimitResetAt > DateTime.UtcNow,
        "Claude pending question stays yellow despite usage limit");
    await File.AppendAllTextAsync(claudeLog, System.Text.Json.JsonSerializer.Serialize(new {
        type = "user", sessionId = claudeId, message = new { content = new[] { new { type = "tool_result", tool_use_id = "limited-question", content = "answer" } } }
    }) + "\n" + ClaudeLine("assistant", "try again in 1 hours", true, "rate_limit"));
    Assert((await new ClaudeCodeProvider(limitHome).DiscoverAsync(CancellationToken.None)).Single().State == AgentState.RateLimited,
        "Claude usage limit is visible once question is answered");
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
    Assert(launches[0].Info.ArgumentList.SkipWhile(x => x != "exec").SequenceEqual(new[] { "exec", "resume", "--skip-git-repo-check", "-c", "sandbox_mode=workspace-write", threadId, "-" })
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
// OpenCode discovery uses an isolated SQLite fixture, never the user's database.
var openHome = Path.Combine(Path.GetTempPath(), "agenthud-opencode-" + Guid.NewGuid());
try
{
    var openClock = new TestTimeProvider();
    var openProvider = new OpenCodeProvider(openHome, openClock);
    Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Count == 0, "missing OpenCode database is empty");
    var openRoot = Path.Combine(openHome, ".local", "share", "opencode");
    Directory.CreateDirectory(openRoot);
    using (var db = new Microsoft.Data.Sqlite.SqliteConnection(new Microsoft.Data.Sqlite.SqliteConnectionStringBuilder
        { DataSource = Path.Combine(openRoot, "opencode.db"), Pooling = false }.ToString()))
    {
        await db.OpenAsync();
        async Task Execute(string sql)
        {
            using var cmd = db.CreateCommand(); cmd.CommandText = sql;
            cmd.Parameters.AddWithValue("$now", openClock.Now.ToUnixTimeMilliseconds());
            await cmd.ExecuteNonQueryAsync();
        }
        await Execute("""
            PRAGMA journal_mode=WAL;
            CREATE TABLE session(id TEXT PRIMARY KEY, directory TEXT, title TEXT, time_created INTEGER, time_updated INTEGER, time_archived INTEGER);
            CREATE TABLE message(id TEXT PRIMARY KEY, session_id TEXT, time_created INTEGER, data TEXT);
            INSERT INTO session VALUES ('ses_live', '/project', 'Build feature', $now, $now, NULL),
                ('ses_old', '/project', 'Old', $now-7200000, $now-7200000, NULL),
                ('ses_archived', '/project', 'Archived', $now, $now, $now),
                ('ses_bad', '/project', 'Bad message', $now, $now, NULL),
                ('ses_empty', '', 'No project', $now, $now, NULL);
            INSERT INTO message VALUES ('msg_1', 'ses_live', $now, '{"role":"user"}'),
                ('msg_bad', 'ses_bad', $now, '{broken');
            """);
        var found = await openProvider.DiscoverAsync(CancellationToken.None);
        Assert(found.Count == 3, "OpenCode excludes stale and pathless sessions, reads WAL");
        var liveOpen = found.Single(x => x.Id == "opencode:ses_live");
        Assert(liveOpen.AgentType == AgentType.OpenCode && liveOpen.DisplayName == "OpenCode" && liveOpen.State == AgentState.Working
            && liveOpen.SessionTitle == "Build feature" && liveOpen.WorktreePath == "/project", "OpenCode maps identity, title, project and working state");
        Assert(found.Single(x => x.Id == "opencode:ses_archived") is { IsActive: false, State: AgentState.Completed }, "OpenCode archived session is completed");
        Assert(found.Single(x => x.Id == "opencode:ses_bad").State == AgentState.Idle, "malformed OpenCode message is isolated");
        await Execute("""INSERT INTO message VALUES ('msg_2', 'ses_live', $now+1, '{"role":"assistant","finish":"stop","time":{"completed":1}}');""");
        var completed = (await openProvider.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == liveOpen.Id);
        Assert(completed.State == AgentState.Completed, "OpenCode assistant final response completes turn");
        var openRegistry = new AgentSessionRegistry(openClock);
        openRegistry.Replace([liveOpen]); openRegistry.Replace([completed]);
        Assert(openRegistry.GetAllAgents().Single().HasUnreadCompletion, "OpenCode completion uses existing registry notification");
        await Execute("""UPDATE message SET data = '{"role":"assistant","finish":"tool-calls"}' WHERE id='msg_2';""");
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == liveOpen.Id).State == AgentState.Working, "OpenCode tool call is not completion");
        await Execute("""
            CREATE TABLE part(id TEXT PRIMARY KEY, session_id TEXT, message_id TEXT, data TEXT);
            INSERT INTO part VALUES ('question', 'ses_live', 'msg_2', '{"type":"tool","tool":"question","state":{"status":"running"}}'),
                ('bad-part', 'ses_live', 'msg_2', '{broken');
            """);
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == liveOpen.Id).State == AgentState.WaitingForInput,
            "OpenCode running question waits for input despite malformed sibling part");
        foreach (var status in new[] { "completed", "error", "pending" })
        {
            await Execute($"UPDATE part SET data = '{{\"type\":\"tool\",\"tool\":\"question\",\"state\":{{\"status\":\"{status}\"}}}}' WHERE id='question';");
            Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == liveOpen.Id).State == AgentState.Working,
                "OpenCode answered, cancelled or queued question is not an input wait");
        }
        await Execute("""UPDATE part SET data = '{"type":"tool","tool":"bash","state":{"status":"running"}}' WHERE id='question';""");
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == liveOpen.Id).State == AgentState.Working,
            "OpenCode running command does not imply permission wait");
        await Execute("""UPDATE part SET data = '{"type":"tool","tool":"question","state":{"status":"running"}}', message_id='msg_1' WHERE id='question';""");
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == liveOpen.Id).State == AgentState.Working,
            "OpenCode question from older message does not revive input wait");
        await Execute("""UPDATE part SET message_id='msg_2' WHERE id='question';""");
        await Execute("""UPDATE message SET data = '{"error":{"name":"MessageAbortedError"}}' WHERE id='msg_2';""");
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == liveOpen.Id).State == AgentState.Stopped, "OpenCode abort stops turn");
        await Execute("""UPDATE message SET data = '{"error":{"name":"APIError"}}' WHERE id='msg_2';""");
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == liveOpen.Id).State == AgentState.Error, "OpenCode API error state");
        await Execute("""UPDATE message SET data = '{"role":"user"}' WHERE id='msg_2';""");
        openClock.Now = openClock.Now.AddMinutes(3);
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == liveOpen.Id).State == AgentState.Idle, "OpenCode stale unfinished turn is not working forever");
        await Execute("""
            CREATE TABLE session_v2 AS SELECT * FROM session WHERE id='ses_live';
            UPDATE session_v2 SET title='V2 conversation';
            """);
        var v2 = (await openProvider.DiscoverAsync(CancellationToken.None)).Single();
        Assert(v2.SessionTitle == "V2 conversation" && v2.State == AgentState.Idle, "OpenCode prefers V2 and does not interpret legacy messages as V2 state");
        // OpenCode v2.0.30 keeps the turn in session_message; the session row alone cannot show progress.
        await Execute("""
            CREATE TABLE session_message(id TEXT PRIMARY KEY, session_id TEXT, type TEXT, seq INTEGER, time_created INTEGER, time_updated INTEGER, data TEXT);
            UPDATE session_v2 SET time_updated=$now;
            INSERT INTO session_message VALUES ('msg_v2', 'ses_live', 'assistant', 1, $now, $now,
                '{"content":[{"type":"tool","name":"shell","state":{"status":"running"}}]}');
            """);
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Working,
            "OpenCode V2 running turn is working");
        await Execute("""
            UPDATE session_message SET data='{"content":[{"type":"tool","name":"question","state":{"status":"running"}}]}' WHERE id='msg_v2';
            """);
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.WaitingForInput,
            "OpenCode V2 running question waits for input");
        await Execute("""
            UPDATE session_message SET data='{"content":[{"type":"tool","name":"shell","state":{"status":"completed"}}],"finish":"stop"}' WHERE id='msg_v2';
            """);
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Completed,
            "OpenCode V2 final response completes turn");
        await Execute("""
            UPDATE session_message SET data='{"content":[{"type":"tool","name":"shell","state":{"status":"completed"}}]}' WHERE id='msg_v2';
            INSERT INTO session_message VALUES ('msg_v2_idle', 'ses_live', 'idle', 2, $now, $now, '{"outcome":"succeeded"}');
            """);
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Completed,
            "OpenCode V2 idle message completes turn");
        await Execute("""UPDATE session_message SET data='{"outcome":"interrupted"}' WHERE id='msg_v2_idle';""");
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Stopped,
            "OpenCode V2 interrupted turn stops");
        await Execute("""UPDATE session_message SET data='{"outcome":"failed"}' WHERE id='msg_v2_idle';""");
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Error,
            "OpenCode V2 failed turn is an error");
        await Execute("""UPDATE session_message SET data='{"error":{"name":"MessageAbortedError"}}', type='assistant' WHERE id='msg_v2_idle';""");
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Stopped,
            "OpenCode V2 aborted assistant message stops turn");
        await Execute("""UPDATE session_message SET data='{broken' WHERE id='msg_v2_idle';""");
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Working,
            "malformed OpenCode V2 message is isolated");
        // 실행 중인 도구가 있으면 오래 걸려도 작업 중이다. 그 밖의 미완료 턴은 멈춘 것으로 본다
        await Execute("""UPDATE session_message SET data='{"content":[{"type":"tool","name":"shell","state":{"status":"running"}}]}' WHERE id='msg_v2_idle';""");
        openClock.Now = openClock.Now.AddMinutes(10);
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Working,
            "OpenCode V2 long running tool stays working");
        await Execute("""UPDATE session_message SET data='{"content":[{"type":"text","text":"hi"}]}' WHERE id='msg_v2_idle';""");
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Single().State == AgentState.Idle,
            "OpenCode V2 stale unfinished turn is not working forever");
        Assert(new AgentHud.AutoResumer(openHome, openHome).CreateStartInfo(v2 with { Id = "opencode:" + Guid.NewGuid(), ProjectPath = openHome }) is null,
            "OpenCode never uses the Codex resume command");
        using var cancelled = new CancellationTokenSource(); cancelled.Cancel();
        try { await openProvider.DiscoverAsync(cancelled.Token); Assert(false, "OpenCode cancellation throws"); }
        catch (OperationCanceledException) { }
        openClock.Now = openClock.Now.AddHours(2);
        Assert((await openProvider.DiscoverAsync(CancellationToken.None)).Count == 0, "OpenCode sessions age out using injected clock");
    }
}
finally { if (Directory.Exists(openHome)) Directory.Delete(openHome, true); }

// OpenCode Go response fixtures contain no real account data.
var goFetched = new DateTime(2026, 10, 16, 0, 0, 0, DateTimeKind.Utc);
string GoMeter(string used, string limit = "100") => "{\"limitMicroCents\":\"" + limit + "\",\"usedMicroCents\":\"" + used + "\",\"resetsAt\":\"2026-10-17T09:00:00+09:00\"}";
string GoResponse(string five, string week, string month) => "{\"product\":\"go-plus\",\"access\":{\"meters\":{\"fiveHour\":" + five + ",\"week\":" + week + ",\"month\":" + month + "}}}";
var goJson = GoResponse(GoMeter("25"), GoMeter("50"), GoMeter("150"));
var goUsage = AgentHud.OpenCodeGoUsage.Parse(goJson, goFetched);
Assert(goUsage.FiveHour.UsedPercent == 25 && goUsage.Week.UsedPercent == 50 && goUsage.Month.UsedPercent == 100,
    "Go maps all three meters and clamps exhausted allowance");
Assert(goUsage.FiveHour.ResetsAt == new DateTime(2026, 10, 17, 0, 0, 0, DateTimeKind.Utc)
    && goUsage.FetchedAt == goFetched, "Go preserves fetched time and converts offset resets to UTC");
Assert(goUsage.FiveHour.PercentAt(goUsage.FiveHour.ResetsAt) == 0, "Go allowance resets at server time");
var previousCulture = System.Globalization.CultureInfo.CurrentCulture;
try
{
    System.Globalization.CultureInfo.CurrentCulture = System.Globalization.CultureInfo.GetCultureInfo("fr-FR");
    var fractional = AgentHud.OpenCodeGoUsage.Parse(GoResponse(GoMeter("1.5", "10"), GoMeter("0"), GoMeter("1")), goFetched);
    Assert(fractional.FiveHour.UsedPercent == 15 && fractional.Week.UsedPercent == 0, "Go currency amounts use invariant culture");
}
finally { System.Globalization.CultureInfo.CurrentCulture = previousCulture; }
foreach (var invalid in new[]
{
    goJson.Replace("go-plus", "zen"), "{}", "{broken",
    GoResponse(GoMeter("1", "0"), GoMeter("1"), GoMeter("1")),
    GoResponse(GoMeter("-1"), GoMeter("1"), GoMeter("1")),
    GoResponse(GoMeter("NaN"), GoMeter("1"), GoMeter("1")),
    goJson.Replace("2026-10-17T09:00:00+09:00", "not-a-date")
})
{
    var rejected = false;
    try { AgentHud.OpenCodeGoUsage.Parse(invalid, goFetched); }
    catch (Exception e) when (e is FormatException or System.Text.Json.JsonException or KeyNotFoundException or InvalidOperationException) { rejected = true; }
    Assert(rejected, "Go rejects invalid or unsupported response instead of showing a false allowance");
}
// Claude limit fixtures contain no real account data.
{
    var now = new DateTime(2026, 10, 18, 12, 0, 0, DateTimeKind.Utc);
    string StatusJson(double five, DateTime fiveReset, double seven, DateTime sevenReset) =>
        $"{{\"rate_limits\":{{\"five_hour\":{{\"used_percentage\":{five},\"resets_at\":{new DateTimeOffset(fiveReset).ToUnixTimeSeconds()}}}," +
        $"\"seven_day\":{{\"used_percentage\":{seven},\"resets_at\":{new DateTimeOffset(sevenReset).ToUnixTimeSeconds()}}}}}}}";
    AgentHud.ClaudeLimitSnapshot StatusLineAt(DateTime age, double five = 40, double seven = 20, DateTime? fiveReset = null, DateTime? sevenReset = null) =>
        AgentHud.ClaudeLimitSnapshot.ParseStatusLine(StatusJson(five, fiveReset ?? now.AddHours(2), seven, sevenReset ?? now.AddDays(3)), age);
    AgentHud.ClaudeLimitSnapshot ApiAt(DateTime age, double five = 40, double seven = 20) =>
        new(AgentHud.ClaudeLimitSource.UsageApi, new LimitWindow(five, now.AddHours(2)), new LimitWindow(seven, now.AddDays(3)), age);

    var parsed = AgentHud.ClaudeLimitSnapshot.ParseStatusLine(StatusJson(40, now.AddHours(2), 20, now.AddDays(3)), now);
    Assert(parsed.FiveHour is { UsedPercent: 40 } && parsed.FiveHour.ResetsAt == now.AddHours(2).ToUniversalTime()
        && parsed.SevenDay is { UsedPercent: 20 }, "ParseStatusLine maps both windows in UTC");

    Assert(AgentHud.ClaudeLimitSnapshot.ParseStatusLine("{broken", now) == AgentHud.ClaudeLimitSnapshot.None, "ParseStatusLine rejects malformed JSON");
    Assert(AgentHud.ClaudeLimitSnapshot.ParseStatusLine("{}", now) == AgentHud.ClaudeLimitSnapshot.None, "ParseStatusLine rejects JSON without rate_limits");
    var missingReset = AgentHud.ClaudeLimitSnapshot.ParseStatusLine("{\"rate_limits\":{\"five_hour\":{\"used_percentage\":40},\"seven_day\":{\"used_percentage\":20,\"resets_at\":" + new DateTimeOffset(now.AddDays(3)).ToUnixTimeSeconds() + "}}}", now);
    Assert(missingReset.FiveHour is null && missingReset.SevenDay is not null, "ParseStatusLine never reports a false 0% for a window missing resets_at");

    var fresh = ClaudeLimitPolicy.Pick(StatusLineAt(now), AgentHud.ClaudeLimitSnapshot.None, now, null);
    Assert(fresh.Source == AgentHud.ClaudeLimitSource.StatusLine && !fresh.FiveHourStale && !fresh.SevenDayStale, "Fresh statusLine with no API picks StatusLine without stale flags");

    var apiFresher = ClaudeLimitPolicy.Pick(StatusLineAt(now.AddHours(-3)), ApiAt(now.AddMinutes(-10)), now, null);
    Assert(apiFresher.Source == AgentHud.ClaudeLimitSource.UsageApi, "Fresher non-stale API beats an older statusLine");

    var statusLineFresher = ClaudeLimitPolicy.Pick(StatusLineAt(now.AddMinutes(-10)), ApiAt(now.AddHours(-3)), now, null);
    Assert(statusLineFresher.Source == AgentHud.ClaudeLimitSource.StatusLine, "A stale API falls back to the fresher statusLine");

    var tie = ClaudeLimitPolicy.Pick(StatusLineAt(now), ApiAt(now), now, null);
    Assert(tie.Source == AgentHud.ClaudeLimitSource.StatusLine, "Equal UpdatedAt ties in favor of the official statusLine");

    var apiEmpty = ClaudeLimitPolicy.Pick(StatusLineAt(now), AgentHud.ClaudeLimitSnapshot.None, now, null);
    Assert(apiEmpty.Source == AgentHud.ClaudeLimitSource.StatusLine && apiEmpty.FiveHour is not null && apiEmpty.SevenDay is not null,
        "An empty/failed API does not hide the Claude rows when statusLine has data");

    var oldNoActivity = ClaudeLimitPolicy.Pick(StatusLineAt(now.AddHours(-13)), AgentHud.ClaudeLimitSnapshot.None, now, null);
    Assert(oldNoActivity.FiveHourStale && oldNoActivity.SevenDayStale && oldNoActivity.FiveHour is not null && oldNoActivity.SevenDay is not null,
        "A statusLine over 12h old is stale but still shows the last known numbers");

    var vsCodeCase = ClaudeLimitPolicy.Pick(StatusLineAt(now.AddDays(-2)), AgentHud.ClaudeLimitSnapshot.None, now, now.AddMinutes(-1));
    Assert(vsCodeCase.FiveHourStale, "Claude activity newer than the statusLine snapshot marks it stale (VS Code extension case)");

    var normalTerminalUse = ClaudeLimitPolicy.Pick(StatusLineAt(now.AddMinutes(-5)), AgentHud.ClaudeLimitSnapshot.None, now, now.AddMinutes(-3));
    Assert(!normalTerminalUse.FiveHourStale, "Activity within the grace window of a fresh statusLine snapshot is not stale");

    var perWindow = ClaudeLimitPolicy.Pick(StatusLineAt(now, fiveReset: now.AddMinutes(-1), sevenReset: now.AddDays(4)), AgentHud.ClaudeLimitSnapshot.None, now, null);
    Assert(perWindow.FiveHourStale && !perWindow.SevenDayStale, "A window whose resets_at has passed is stale independently of the other window");

    var apiOld = ClaudeLimitPolicy.Pick(AgentHud.ClaudeLimitSnapshot.None, ApiAt(now.AddMinutes(-45)), now, now.AddMinutes(-1));
    Assert(apiOld.FiveHourStale, "API values older than 30 minutes are stale");

    var apiFreshWithActivity = ClaudeLimitPolicy.Pick(AgentHud.ClaudeLimitSnapshot.None, ApiAt(now.AddMinutes(-5)), now, now.AddSeconds(-1));
    Assert(!apiFreshWithActivity.FiveHourStale, "The activity rule only applies to statusLine, not the API source");

    var neither = ClaudeLimitPolicy.Pick(AgentHud.ClaudeLimitSnapshot.None, AgentHud.ClaudeLimitSnapshot.None, now, null);
    Assert(neither.Source == AgentHud.ClaudeLimitSource.None && neither.FiveHour is null && neither.SevenDay is null,
        "No data from either source falls back to None so the caller can use the token-budget estimate");
}
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
