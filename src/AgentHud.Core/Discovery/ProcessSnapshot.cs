using System.Diagnostics;

namespace AgentHud.Discovery;

public sealed class ProcessSnapshot
{
    private readonly HashSet<int> _ids;
    private ProcessSnapshot(HashSet<int> ids) => _ids = ids;
    public bool Contains(int pid) => _ids.Contains(pid);

    public static ProcessSnapshot Capture()
    {
        var ids = new HashSet<int>();
        foreach (var process in Process.GetProcesses())
        {
            try { ids.Add(process.Id); }
            finally { process.Dispose(); }
        }
        return new(ids);
    }
}
