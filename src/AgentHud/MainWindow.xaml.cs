using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
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
    private Size _compactSize = new(280, 220);
    private bool _minimized;
    private Size _restoreSize;
    private double _anchorRight;
    private VirtualDesktopFollower? _desktopFollower;
    private readonly Dictionary<string, DateTime> _dismissed = [];
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
        // 최소화 중 세션 수가 바뀌어 폭이 변해도 오른쪽 끝을 고정
        SizeChanged += (_, _) => { if (_minimized) Left = _anchorRight - ActualWidth; };
    }
    private void UpdateSessions()
    {
        var all = _registry.GetAllAgents();
        // 숨긴 idle 세션은 새 활동이 생기거나 idle을 벗어나면 다시 표시
        foreach (var id in _dismissed.Keys.ToArray())
            if (all.FirstOrDefault(x => x.Id == id) is not { State: AgentState.Idle } s || s.LastActivityAt > _dismissed[id]) _dismissed.Remove(id);
        var next = all.Where(x => x.HasUnreadCompletion || (!_dismissed.ContainsKey(x.Id) && (x.IsActive || DateTime.UtcNow - x.LastActivityAt.ToUniversalTime() < TimeSpan.FromSeconds(30)))).ToArray();
        for (var i = 0; i < next.Length; i++)
        {
            if (i >= Sessions.Count) Sessions.Add(next[i]);
            else if (Sessions[i] != next[i]) Sessions[i] = next[i];
        }
        while (Sessions.Count > next.Length) Sessions.RemoveAt(Sessions.Count - 1);
        PropertyChanged?.Invoke(this, new(nameof(ActiveCount)));
    }
    private void Header_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e) { if (e.ClickCount == 2) ToggleExpanded(); else DragMove(); }
    private void List_OnMouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (ItemsControl.ContainerFromElement((ListBox)sender, (DependencyObject)e.OriginalSource) is ListBoxItem { DataContext: AgentSession session })
        {
            _registry.AcknowledgeCompletion(session.Id);
            OpenInVsCode(session);
        }
        else ToggleExpanded();
    }
    private static async void OpenInVsCode(AgentSession session)
    {
        var path = session.WorktreePath ?? session.ProjectPath;
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path)) return;
        // 프로젝트 창을 먼저 활성화해야 vscode:// URI가 그 창으로 전달됨
        try { using var code = Process.Start(new ProcessStartInfo("cmd.exe") { ArgumentList = { "/c", "code", path }, CreateNoWindow = true, UseShellExecute = false }); if (code is not null) await code.WaitForExitAsync(); }
        catch { ShellOpen("vscode://file/" + path.Replace('\\', '/')); }
        if (ConversationUri(session) is { } uri) { await Task.Delay(700); ShellOpen(uri); }
    }
    private static string? ConversationUri(AgentSession session)
    {
        var sep = session.Id.IndexOf(':');
        if (sep < 0) return null;
        var id = Uri.EscapeDataString(session.Id[(sep + 1)..]);
        return session.AgentType == AgentType.ClaudeCode ? $"vscode://anthropic.claude-code/open?session={id}" : $"vscode://openai.chatgpt/local/{id}";
    }
    private static void ShellOpen(string target) { try { Process.Start(new ProcessStartInfo(target) { UseShellExecute = true }); } catch { } }
    private void ToggleExpanded()
    {
        if (!_expanded)
        {
            _compactSize = new Size(ActualWidth, ActualHeight);
            Width = Math.Max(430, ActualWidth);
            Height = Math.Max(ActualHeight, Math.Clamp(70 + Sessions.Count * 30, 180, 620));
        }
        else { Width = _compactSize.Width; Height = _compactSize.Height; }
        _expanded = !_expanded;
    }
    private void Minimize_OnClick(object sender, RoutedEventArgs e) => ToggleMinimized();
    private void Mini_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (e.ClickCount == 2) { ToggleMinimized(); return; }
        DragMove();
        _anchorRight = Left + ActualWidth;
    }
    private void ToggleMinimized()
    {
        _minimized = !_minimized;
        FullView.Visibility = _minimized ? Visibility.Collapsed : Visibility.Visible;
        MiniView.Visibility = _minimized ? Visibility.Visible : Visibility.Collapsed;
        if (_minimized)
        {
            _restoreSize = new Size(ActualWidth, ActualHeight);
            _anchorRight = Left + ActualWidth;
            MinWidth = MinHeight = 0;
            Frame.Padding = new Thickness(8, 6, 8, 6);
            ResizeMode = ResizeMode.NoResize;
            SizeToContent = SizeToContent.WidthAndHeight;
        }
        else
        {
            SizeToContent = SizeToContent.Manual;
            ResizeMode = ResizeMode.CanResizeWithGrip;
            Frame.Padding = new Thickness(14);
            MinWidth = 240; MinHeight = 100;
            Left = _anchorRight - _restoreSize.Width;
            Width = _restoreSize.Width; Height = _restoreSize.Height;
        }
    }
    private void Dismiss_OnClick(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: AgentSession { State: AgentState.Idle } session }) return;
        _dismissed[session.Id] = session.LastActivityAt;
        UpdateSessions();
    }
    private void Close_OnClick(object sender, RoutedEventArgs e) => Close();
    private async void OnClosing(object? sender, CancelEventArgs e) { SavePlacement(); await _discovery.DisposeAsync(); }
    private static string PlacementPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentHud", "placement.json");
    private void RestorePlacement()
    {
        try { if (File.Exists(PlacementPath)) { var p = JsonSerializer.Deserialize<Placement>(File.ReadAllText(PlacementPath)); if (p is not null) { Left = p.Left; Top = p.Top; if (double.IsFinite(p.Width) && p.Width >= MinWidth) Width = p.Width; if (double.IsFinite(p.Height) && p.Height >= MinHeight) Height = p.Height; } } else { Left = SystemParameters.WorkArea.Right - Width - 20; Top = 20; } } catch { Left = SystemParameters.WorkArea.Right - Width - 20; Top = 20; }
    }
    private void SavePlacement()
    {
        try { Directory.CreateDirectory(Path.GetDirectoryName(PlacementPath)!); var p = _minimized ? new Placement(_anchorRight - _restoreSize.Width, Top, _restoreSize.Width, _restoreSize.Height) : new Placement(Left, Top, ActualWidth, ActualHeight); File.WriteAllText(PlacementPath, JsonSerializer.Serialize(p)); } catch { }
    }
    private sealed record Placement(double Left, double Top, double Width = 280, double Height = 220);
}

