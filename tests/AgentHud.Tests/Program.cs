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
var testHome = Path.Combine(Path.GetTempPath(), "AgentHud-tests-" + Guid.NewGuid().ToString("N"));
var sessionsRoot = Path.Combine(testHome, ".claude", "sessions");
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
    var titleId = Guid.NewGuid().ToString();
    var projectLogs = Path.Combine(testHome, ".claude", "projects", "test-project");
    Directory.CreateDirectory(projectLogs);
    var transcript = Path.Combine(projectLogs, titleId + ".jsonl");
    await File.WriteAllTextAsync(metadataPath, System.Text.Json.JsonSerializer.Serialize(new {
        pid = Environment.ProcessId, sessionId = titleId, name = "derived-88", status = "idle" }));
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

    var codexRoot = Path.Combine(testHome, ".codex", "sessions");
    Directory.CreateDirectory(codexRoot);
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
    await AppendEvent("turn_aborted");
    live = (await codex.DiscoverAsync(CancellationToken.None)).Single(x => x.Id == "codex:live");
    Assert(!live.IsActive && live.State == AgentState.Stopped, "aborted turn stops");
}
finally { Directory.Delete(testHome, recursive: true); }
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
