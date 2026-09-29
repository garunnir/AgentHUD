namespace AgentHud.Models;

public sealed record AgentSession
{
    public required string Id { get; init; }
    public required AgentType AgentType { get; init; }
    public AgentState State { get; init; }
    public bool HasUnreadCompletion { get; init; }
    public DateTimeOffset? CompletionDetectedAt { get; init; }
    public AgentState DisplayState => HasUnreadCompletion ? AgentState.Completed : State == AgentState.Completed ? AgentState.Idle : State;
    public int? ProcessId { get; init; }
    public string? ProjectPath { get; init; }
    public string? WorktreePath { get; init; }
    public string? TerminalTitle { get; init; }
    public string? SessionTitle { get; init; }
    public string DisplayTitle => string.IsNullOrWhiteSpace(SessionTitle) ? "제목 없음" : SessionTitle;
    public string? CurrentTask { get; init; }
    public DateTime StartedAt { get; init; }
    public DateTime LastActivityAt { get; init; }
    public bool IsActive { get; init; }
    public string? ParentSessionId { get; init; }
    // 사용량 한도로 끊긴 마지막 턴의 리셋 시각(UTC). 이후 새 턴이 시작되면 null
    public DateTime? RateLimitResetAt { get; init; }
    public string StatusTip => RateLimitResetAt is { } reset && DisplayState == AgentState.RateLimited
        ? $"RateLimited · 리셋 {reset.ToLocalTime():M/d HH:mm}" : DisplayState.ToString();
    public string DisplayName => AgentType == AgentType.ClaudeCode ? "Claude" : "Codex";
    public string ProjectName => string.IsNullOrWhiteSpace(ProjectPath) ? "Unknown project" : Path.GetFileName(ProjectPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
}
