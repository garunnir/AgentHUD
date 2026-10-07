using AgentHud.Models;

namespace AgentHud.Discovery;

public sealed class AgentSessionRegistry
{
    private readonly TimeProvider _timeProvider;
    public AgentSessionRegistry(TimeProvider? timeProvider = null) => _timeProvider = timeProvider ?? TimeProvider.System;
    private readonly object _gate = new();
    private Dictionary<string, AgentSession> _sessions = [];
    public event EventHandler? Changed;
    public IReadOnlyList<AgentSession> GetAllAgents() { lock (_gate) return _sessions.Values.OrderByDescending(x => x.LastActivityAt.ToUniversalTime()).ThenByDescending(x => x.StartedAt).ToArray(); }
    public IReadOnlyList<AgentSession> GetActiveAgents() => GetAllAgents().Where(x => x.IsActive).ToArray();
    public IReadOnlyList<AgentSession> GetByProject(string path) => GetAllAgents().Where(x => string.Equals(x.ProjectPath, path, StringComparison.OrdinalIgnoreCase)).ToArray();
    public IReadOnlyList<AgentSession> GetByAgentType(AgentType type) => GetAllAgents().Where(x => x.AgentType == type).ToArray();
    public AgentSession? GetByProcessId(int pid) => GetAllAgents().FirstOrDefault(x => x.ProcessId == pid);
    public AgentSession? FindSession(string id) => GetAllAgents().FirstOrDefault(x => x.Id == id);
    public void Register(AgentSession session) => Update(session);
    public void Update(AgentSession session) { lock (_gate) _sessions[session.Id] = TrackCompletion(session); Changed?.Invoke(this, EventArgs.Empty); }
    private AgentSession TrackCompletion(AgentSession session)
    {
        _sessions.TryGetValue(session.Id, out var previous);
        if (session.State is AgentState.Starting or AgentState.Working or AgentState.Thinking or AgentState.WaitingForInput or AgentState.WaitingForApproval)
            return session with { HasUnreadCompletion = false, CompletionDetectedAt = null };
        if (session.State == AgentState.Idle && (session.HasBackgroundTasks || session.WakeupAt > _timeProvider.GetUtcNow().UtcDateTime))
            return session with { HasUnreadCompletion = false, CompletionDetectedAt = null };
        var completed = session.State is AgentState.Idle or AgentState.Completed
            && previous?.State is AgentState.Working or AgentState.Thinking or AgentState.WaitingForApproval;
        var detectedAt = completed || (session.State == AgentState.Completed && previous?.State != AgentState.Completed)
            ? _timeProvider.GetUtcNow() : previous?.CompletionDetectedAt;
        var unread = (previous?.HasUnreadCompletion == true || completed
            || (session.State == AgentState.Completed && previous?.State != AgentState.Completed))
            && detectedAt is { } time && _timeProvider.GetUtcNow() - time < TimeSpan.FromMinutes(5);
        return session with { HasUnreadCompletion = unread, CompletionDetectedAt = unread ? detectedAt : null };
    }
    public void AcknowledgeCompletion(string id)
    {
        lock (_gate)
        {
            if (!_sessions.TryGetValue(id, out var session) || !session.HasUnreadCompletion) return;
            _sessions[id] = session with { HasUnreadCompletion = false, CompletionDetectedAt = null };
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }
    public bool Remove(string id) { bool removed; lock (_gate) removed = _sessions.Remove(id); if (removed) Changed?.Invoke(this, EventArgs.Empty); return removed; }
    public void Replace(IEnumerable<AgentSession> sessions)
    {
        var latest = sessions.GroupBy(x => x.Id).ToDictionary(g => g.Key, g => g.OrderByDescending(x => x.LastActivityAt).First());
        lock (_gate)
        {
            var tracked = latest.ToDictionary(x => x.Key, x => TrackCompletion(x.Value));
            foreach (var previous in _sessions.Values.Where(x => x.HasUnreadCompletion && !tracked.ContainsKey(x.Id)))
            {
                var retained = TrackCompletion(previous with { IsActive = false });
                if (retained.HasUnreadCompletion) tracked[previous.Id] = retained;
            }
            _sessions = tracked;
        }
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
