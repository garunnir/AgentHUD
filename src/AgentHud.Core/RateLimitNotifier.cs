using AgentHud.Discovery;
using AgentHud.Models;

namespace AgentHud;

// 사용량 한도 리셋 시각이 지난 세션을 (세션, 리셋 시각)마다 한 번 알린다.
public sealed class RateLimitNotifier
{
    private readonly TimeProvider _time;
    private readonly HashSet<(string Id, DateTime Reset)> _notified = [];
    public bool Enabled { get; set; } = true;
    public RateLimitNotifier(TimeProvider? time = null) => _time = time ?? TimeProvider.System;

    public IReadOnlyList<AgentSession> TakeDue(IEnumerable<AgentSession> sessions)
    {
        if (!Enabled) return [];
        var now = _time.GetUtcNow().UtcDateTime;
        // 리셋 후 한참 지난 한도(HUD가 꺼져 있던 경우)는 알리지 않음
        return sessions.Where(x => x.RateLimitResetAt is { } reset && x.ParentSessionId is null
                && now >= reset && now < reset + CodexProvider.LimitGrace
                && _notified.Add((x.Id, reset)))
            .ToArray();
    }
}
