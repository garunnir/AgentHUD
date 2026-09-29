namespace AgentHud.Models;

public sealed record AgentSession
{
    public required string Id { get; init; }
    public required AgentType AgentType { get; init; }
    public AgentState State { get; init; }
    public int? ProcessId { get; init; }
    public string? ProjectPath { get; init; }
    public string? WorktreePath { get; init; }
    public string? TerminalTitle { get; init; }
    public string? CurrentTask { get; init; }
    public DateTime StartedAt { get; init; }
    public DateTime LastActivityAt { get; init; }
    public bool IsActive { get; init; }
    public string? ParentSessionId { get; init; }
    public string DisplayName => AgentType == AgentType.ClaudeCode ? "Claude" : "Codex";
    public string ProjectName => string.IsNullOrWhiteSpace(ProjectPath) ? "Unknown project" : Path.GetFileName(ProjectPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
}
