namespace AgentHud.Discovery;

public sealed class AgentDiscoveryService : IAsyncDisposable
{
    private readonly IReadOnlyList<IAgentProvider> _providers;
    private readonly AgentSessionRegistry _registry;
    private readonly SemaphoreSlim _refreshGate = new(1, 1);
    private readonly CancellationTokenSource _stop = new();
    private readonly List<FileSystemWatcher> _watchers = [];
    private Task? _loop;
    public AgentDiscoveryService(IEnumerable<IAgentProvider> providers, AgentSessionRegistry registry) { _providers = providers.ToArray(); _registry = registry; }
    public void Start()
    {
        foreach (var root in _providers.SelectMany(x => x.WatchRoots).Distinct(StringComparer.OrdinalIgnoreCase).Where(Directory.Exists))
        {
            var watcher = new FileSystemWatcher(root) { IncludeSubdirectories = true, NotifyFilter = NotifyFilters.FileName | NotifyFilters.LastWrite | NotifyFilters.Size, EnableRaisingEvents = true };
            watcher.Changed += OnChange; watcher.Created += OnChange; watcher.Deleted += OnChange; watcher.Renamed += OnChange;
            _watchers.Add(watcher);
        }
        _loop = RunAsync(_stop.Token);
    }
    private void OnChange(object sender, FileSystemEventArgs args) => _ = RefreshAsync(_stop.Token);
    private async Task RunAsync(CancellationToken token)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(3));
        try { do { await RefreshAsync(token); } while (await timer.WaitForNextTickAsync(token)); }
        catch (OperationCanceledException) when (token.IsCancellationRequested) { }
    }
    public async Task RefreshAsync(CancellationToken token)
    {
        if (!await _refreshGate.WaitAsync(0, token)) return;
        try
        {
            var all = new List<Models.AgentSession>();
            foreach (var provider in _providers) all.AddRange(await provider.DiscoverAsync(token));
            _registry.Replace(all);
        }
        finally { _refreshGate.Release(); }
    }
    public async ValueTask DisposeAsync()
    {
        await _stop.CancelAsync();
        if (_loop is not null) await _loop;
        foreach (var watcher in _watchers) watcher.Dispose();
        _refreshGate.Dispose(); _stop.Dispose();
    }
}
