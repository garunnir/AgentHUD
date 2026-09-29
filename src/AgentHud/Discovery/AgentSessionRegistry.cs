using AgentHud.Models;

namespace AgentHud.Discovery;

public sealed class AgentSessionRegistry
{
    private readonly object _gate = new();
    private Dictionary<string, AgentSession> _sessions = [];
    public event EventHandler? Changed;
    public IReadOnlyList<AgentSession> GetAllAgents() { lock (_gate) return _sessions.Values.OrderByDescending(x => x.IsActive).ThenBy(x => x.AgentType).ThenBy(x => x.StartedAt).ToArray(); }
    public IReadOnlyList<AgentSession> GetActiveAgents() => GetAllAgents().Where(x => x.IsActive).ToArray();
    public IReadOnlyList<AgentSession> GetByProject(string path) => GetAllAgents().Where(x => string.Equals(x.ProjectPath, path, StringComparison.OrdinalIgnoreCase)).ToArray();
    public IReadOnlyList<AgentSession> GetByAgentType(AgentType type) => GetAllAgents().Where(x => x.AgentType == type).ToArray();
    public AgentSession? GetByProcessId(int pid) => GetAllAgents().FirstOrDefault(x => x.ProcessId == pid);
    public AgentSession? FindSession(string id) => GetAllAgents().FirstOrDefault(x => x.Id == id);
    public void Register(AgentSession session) => Update(session);
    public void Update(AgentSession session) { lock (_gate) _sessions[session.Id] = session; Changed?.Invoke(this, EventArgs.Empty); }
    public bool Remove(string id) { bool removed; lock (_gate) removed = _sessions.Remove(id); if (removed) Changed?.Invoke(this, EventArgs.Empty); return removed; }
    public void Replace(IEnumerable<AgentSession> sessions)
    {
        var latest = sessions.GroupBy(x => x.Id).ToDictionary(g => g.Key, g => g.OrderByDescending(x => x.LastActivityAt).First());
        lock (_gate) _sessions = latest;
        Changed?.Invoke(this, EventArgs.Empty);
    }
}
