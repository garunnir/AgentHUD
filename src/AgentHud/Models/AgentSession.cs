namespace AgentHud.Models;

public sealed record LimitWindow(double UsedPercent, DateTime ResetsAt)
{
    // 리셋 시각이 지났으면 새 창이 시작된 것이므로 0%
    public double PercentAt(DateTime nowUtc) => nowUtc >= ResetsAt ? 0 : UsedPercent;
}

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
    public string DisplayTitle => string.IsNullOrWhiteSpace(SessionTitle) ? Loc.T("Session.Untitled") : SessionTitle;
    public string? CurrentTask { get; init; }
    public DateTime StartedAt { get; init; }
    public DateTime LastActivityAt { get; init; }
    public bool IsActive { get; init; }
    public string? ParentSessionId { get; init; }
    // 사용량 한도로 끊긴 마지막 턴의 리셋 시각(UTC). 이후 새 턴이 시작되면 null
    public DateTime? RateLimitResetAt { get; init; }
    // Claude: 최근 5시간 토큰(입력+출력+캐시 생성). 캐시 읽기는 제외
    public long Tokens5h { get; init; }
    public long TokensWeek { get; init; }
    // Codex: token_count.rate_limits의 5시간(primary)·주간(secondary) 창
    public LimitWindow? PrimaryLimit { get; init; }
    public LimitWindow? SecondaryLimit { get; init; }
    public string StatusTip => RateLimitResetAt is { } reset && DisplayState == AgentState.RateLimited
        ? Loc.F("Session.RateLimitedReset", reset.ToLocalTime()) : DisplayState.ToString();
    public string DisplayName => AgentType == AgentType.ClaudeCode ? "Claude" : "Codex";
    public string ProjectName => string.IsNullOrWhiteSpace(ProjectPath) ? Loc.T("Session.UnknownProject") : Path.GetFileName(ProjectPath.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar));
}
