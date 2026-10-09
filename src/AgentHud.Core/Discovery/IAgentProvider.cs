using AgentHud.Models;

namespace AgentHud.Discovery;

public interface IAgentProvider
{
    AgentType AgentType { get; }
    IEnumerable<string> WatchRoots { get; }
    Task<IReadOnlyList<AgentSession>> DiscoverAsync(CancellationToken cancellationToken);
}
