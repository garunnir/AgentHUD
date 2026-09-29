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

    await File.WriteAllTextAsync(metadataPath, "{\"pid\":2147483647,\"sessionId\":\"stopped\",\"updatedAt\":9223372036854775807}");
    found = await provider.DiscoverAsync(CancellationToken.None);
    Assert(!found.Single().IsActive && found[0].State == AgentState.Stopped, "dead process and invalid timestamp fallback");
}
finally { Directory.Delete(testHome, recursive: true); }
Console.WriteLine("All registry and discovery checks passed.");

if (args.Contains("--discover"))
{
    var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
    foreach (var provider in new IAgentProvider[] { new ClaudeCodeProvider(home), new CodexProvider(home) })
    {
        var found = await provider.DiscoverAsync(CancellationToken.None);
        Console.WriteLine($"{provider.AgentType}: {found.Count} detected, {found.Count(x => x.IsActive)} active");
    }
}
static void Assert(bool condition, string name) { if (!condition) throw new Exception($"Assertion failed: {name}"); }
