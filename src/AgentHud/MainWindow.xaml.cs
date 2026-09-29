using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using AgentHud.Discovery;
using AgentHud.Models;
using AgentHud.Windows;

namespace AgentHud;

public partial class MainWindow : Window, INotifyPropertyChanged
{
    private readonly AgentSessionRegistry _registry = new();
    private readonly AgentDiscoveryService _discovery;
    private bool _expanded;
    private VirtualDesktopFollower? _desktopFollower;
    public ObservableCollection<AgentSession> Sessions { get; } = [];
    public int ActiveCount => Sessions.Count(x => x.IsActive);
    public event PropertyChangedEventHandler? PropertyChanged;

    public MainWindow()
    {
        InitializeComponent(); DataContext = this;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _discovery = new AgentDiscoveryService([new ClaudeCodeProvider(home), new CodexProvider(home)], _registry);
        _registry.Changed += (_, _) => Dispatcher.Invoke(UpdateSessions);
        ContentRendered += (_, _) => _desktopFollower ??= new VirtualDesktopFollower(new WindowInteropHelper(this).Handle);
        Closed += (_, _) => _desktopFollower?.Dispose();
        Loaded += (_, _) => { RestorePlacement(); _discovery.Start(); };
        Closing += OnClosing;
    }
    private void UpdateSessions()
    {
        Sessions.Clear();
        foreach (var session in _registry.GetAllAgents().Where(x => x.IsActive || DateTime.UtcNow - x.LastActivityAt.ToUniversalTime() < TimeSpan.FromSeconds(30))) Sessions.Add(session);
        PropertyChanged?.Invoke(this, new(nameof(ActiveCount)));
        if (!_expanded) Height = Math.Clamp(62 + Sessions.Count * 30, 100, 220);
    }
    private void Header_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e) { if (e.ClickCount == 2) ToggleExpanded(); else DragMove(); }
    private void List_OnMouseDoubleClick(object sender, MouseButtonEventArgs e) => ToggleExpanded();
    private void ToggleExpanded() { _expanded = !_expanded; Width = _expanded ? 430 : 280; Height = _expanded ? Math.Clamp(70 + Sessions.Count * 52, 180, 620) : Math.Clamp(62 + Sessions.Count * 30, 100, 220); }
    private void Close_OnClick(object sender, RoutedEventArgs e) => Close();
    private async void OnClosing(object? sender, CancelEventArgs e) { SavePlacement(); await _discovery.DisposeAsync(); }
    private static string PlacementPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentHud", "placement.json");
    private void RestorePlacement()
    {
        try { if (File.Exists(PlacementPath)) { var p = JsonSerializer.Deserialize<Placement>(File.ReadAllText(PlacementPath)); if (p is not null) { Left = p.Left; Top = p.Top; } } else { Left = SystemParameters.WorkArea.Right - Width - 20; Top = 20; } } catch { Left = SystemParameters.WorkArea.Right - Width - 20; Top = 20; }
    }
    private void SavePlacement()
    {
        try { Directory.CreateDirectory(Path.GetDirectoryName(PlacementPath)!); File.WriteAllText(PlacementPath, JsonSerializer.Serialize(new Placement(Left, Top))); } catch { }
    }
    private sealed record Placement(double Left, double Top);
}
