using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using System.Windows.Media;
using AgentHud.Cleanup;
using AgentHud.Models;

namespace AgentHud;

/// <summary>정리 창의 한 줄(체크 상태 + 표시 문구). 판단은 모두 CleanupRow(Core)에서 끝난 값이다</summary>
public sealed class CleanupItem : INotifyPropertyChanged
{
    public CleanupItem(CleanupRow row) => Row = row;
    public CleanupRow Row { get; }
    public event PropertyChangedEventHandler? PropertyChanged;
    private bool _selected;
    // 종료 금지 트리는 체크되지 않는다(UI와 별개로 한 번 더 막음)
    public bool Selected
    {
        get => _selected;
        set
        {
            value = value && Row.CanTerminate;
            if (_selected == value) return;
            _selected = value;
            PropertyChanged?.Invoke(this, new(nameof(Selected)));
        }
    }
    public bool CanTerminate => Row.CanTerminate;
    public string AgentName => Row.AgentType switch { AgentType.ClaudeCode => "Claude", AgentType.OpenCode => "OpenCode", _ => "Codex" };
    public int Pid => Row.Pid;
    public string Title => Row.Session?.DisplayTitle ?? Loc.T(Row.Ambiguous ? "Cleanup.Unknown" : "Cleanup.Orphan");
    public string Project => Row.Session?.ProjectName ?? Row.Tree.Root.ExecutablePath ?? "";
    public string StateText => Row.Guard != CleanupGuard.None ? Row.GuardText
        : Row.Session is { } s ? s.DisplayState.ToString() : Row.Ambiguous ? Row.GuardText : "—";
    public Brush StateBrush => Row.Guard != CleanupGuard.None ? Brushes.SlateGray
        : Row.Session is { } s ? (Brush)new StateBrushConverter().Convert(s.DisplayState, typeof(Brush), null!, System.Globalization.CultureInfo.CurrentCulture) : Brushes.SlateGray;
    public string ActivityText => CleanupWindow.FormatTime(Row.LastActivityAt);
    public string StartedText => CleanupWindow.FormatTime(Row.StartedAt);
    public int ProcessCount => Row.Tree.Count;
    public string MemoryText => CleanupWindow.FormatBytes(Row.Tree.WorkingSet);
    public string RowToolTip => string.Join('\n', new[]
    {
        Row.Session?.DisplayTitle, Row.Session?.ProjectPath, Row.Tree.Root.CommandLine,
        Row.GuardText.Length > 0 ? Row.GuardText : null,
        Loc.F("Cleanup.TreeTip", Row.Tree.Count, string.Join(", ", Row.Tree.Processes.Skip(1).Take(12).Select(x => x.Name).Distinct()))
    }.Where(x => !string.IsNullOrWhiteSpace(x)));
}

/// <summary>
/// 오래된 에이전트 프로세스 트리 정리 창. 목록만 보면 dry-run이고, 종료는 선택 + 확인 창을 지나야 한다.
/// 안전 규칙(공유·보호 프로세스 제외, 활성 세션 제외, 최근 N개 유지, PID 재사용 확인)은 모두 ProcessCleanup(Core)에 있다.
/// </summary>
public partial class CleanupWindow : Window, INotifyPropertyChanged
{
    private readonly Func<IReadOnlyList<AgentSession>> _sessions;
    private readonly Action<int> _keepChanged;
    private readonly WindowsProcessLister _lister = new();
    private static readonly string LogPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentHud", "cleanup.log");
    public ObservableCollection<CleanupItem> Items { get; } = [];
    public event PropertyChangedEventHandler? PropertyChanged;

    public CleanupWindow(Func<IReadOnlyList<AgentSession>> sessions, int keepLatest, Action<int> keepChanged)
    {
        _sessions = sessions;
        _keepChanged = keepChanged;
        _keepLatest = Math.Clamp(keepLatest, 0, 99);
        InitializeComponent();
        DataContext = this;
        Loaded += async (_, _) => await RefreshAsync();
    }

    private int _keepLatest = 3;
    public int KeepLatest
    {
        get => _keepLatest;
        set
        {
            value = Math.Clamp(value, 0, 99);
            if (_keepLatest == value) return;
            _keepLatest = value;
            _keepChanged(value);
            Raise(nameof(KeepLatest));
        }
    }
    private bool _includeActive;
    public bool IncludeActive { get => _includeActive; set { if (_includeActive == value) return; _includeActive = value; Raise(nameof(IncludeActive)); } }
    private bool _idle = true;
    /// <summary>수집·종료 중이 아닌지(버튼 활성 상태)</summary>
    public bool Idle { get => _idle; private set { if (_idle == value) return; _idle = value; Raise(nameof(Idle)); } }
    private string _status = "";
    public string Status { get => _status; private set { _status = value; Raise(nameof(Status)); } }
    public string TotalText
    {
        get
        {
            var rows = Items.Select(x => x.Row).ToArray();
            var chosen = Items.Where(x => x.Selected).Select(x => x.Row).ToArray();
            return rows.Length == 0 ? Loc.T("Cleanup.Empty")
                : Loc.F("Cleanup.Total", rows.Length, ProcessCleanup.TotalProcesses(rows), FormatBytes(ProcessCleanup.TotalWorkingSet(rows)))
                  + (chosen.Length > 0 ? "   " + Loc.F("Cleanup.Selected", chosen.Length, ProcessCleanup.TotalProcesses(chosen), FormatBytes(ProcessCleanup.TotalWorkingSet(chosen))) : "");
        }
    }

    private async Task RefreshAsync()
    {
        Idle = false;
        try
        {
            var sessions = _sessions();
            var self = Environment.ProcessId;
            // WMI 질의는 수백 ms가 걸릴 수 있어 UI 스레드를 비워 둔다
            var rows = await Task.Run(() =>
            {
                try { return ProcessCleanup.Build(_lister, sessions, self); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException or InvalidOperationException) { return null; }
            });
            Items.Clear();
            if (rows is null) { Status = Loc.T("Cleanup.ListFailed"); }
            else
            {
                foreach (var row in rows) Items.Add(Track(new CleanupItem(row)));
                if (_lister.CommandLinesMissing) Status = Loc.T("Cleanup.NoCommandLines");
            }
            Raise(nameof(TotalText));
        }
        finally { Idle = true; }
    }
    private CleanupItem Track(CleanupItem item)
    {
        item.PropertyChanged += (_, e) => { if (e.PropertyName == nameof(CleanupItem.Selected)) Raise(nameof(TotalText)); };
        return item;
    }

    private async void Refresh_OnClick(object sender, RoutedEventArgs e) => await RefreshAsync();
    private void SelectAllButLatest_OnClick(object sender, RoutedEventArgs e)
    {
        var chosen = ProcessCleanup.SelectAllButLatest(Items.Select(x => x.Row).ToArray(), KeepLatest, IncludeActive).ToHashSet();
        foreach (var item in Items) item.Selected = chosen.Contains(item.Row);
        Status = Loc.F("Cleanup.SelectedCount", Items.Count(x => x.Selected), KeepLatest);
    }

    private async void Terminate_OnClick(object sender, RoutedEventArgs e)
    {
        var chosen = Items.Where(x => x.Selected && x.CanTerminate).Select(x => x.Row).ToArray();
        if (chosen.Length == 0) { Status = Loc.T("Cleanup.NothingSelected"); return; }
        var question = Loc.F("Cleanup.Confirm", chosen.Length, ProcessCleanup.TotalProcesses(chosen), FormatBytes(ProcessCleanup.TotalWorkingSet(chosen)));
        if (MessageBox.Show(this, question, "Agent HUD", MessageBoxButton.OKCancel, MessageBoxImage.Warning) != MessageBoxResult.OK) return;
        Idle = false;
        var done = 0;
        var problems = new List<string>();
        try
        {
            foreach (var row in chosen)
            {
                // PID 재사용 확인: 같은 PID가 다른 프로세스로 바뀌었으면 건너뛴다
                if (!ProcessCleanup.StillMatches(row.Tree.Root, WindowsProcessLister.Read(row.Pid)))
                {
                    problems.Add(Loc.F("Cleanup.SkipChanged", row.Pid, row.Tree.Root.Name));
                    continue;
                }
                try
                {
                    using var process = Process.GetProcessById(row.Pid);
                    process.Kill(entireProcessTree: true);
                    done++;
                    Log($"killed {row.AgentType} pid {row.Pid} ({row.Tree.Root.Name}) tree={row.Tree.Count} ws={row.Tree.WorkingSet}");
                }
                catch (Exception ex) when (ex is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception or AggregateException or NotSupportedException)
                {
                    problems.Add(Loc.F("Cleanup.KillFailed", row.Pid, ex.Message));
                    Log($"failed pid {row.Pid}: {ex.Message}");
                }
            }
        }
        finally { Idle = true; }
        foreach (var skipped in problems) Log(skipped);
        Status = Loc.F("Cleanup.Result", done, problems.Count) + (problems.Count > 0 ? "\n" + string.Join('\n', problems) : "");
        await Task.Delay(400);
        await RefreshAsync();
    }

    private static void Log(string line)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(LogPath)!);
            File.AppendAllText(LogPath, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {line}{Environment.NewLine}");
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
    internal static string FormatBytes(long bytes) => bytes >= 1L << 30 ? $"{bytes / (double)(1L << 30):0.0} GB" : $"{bytes / (1L << 20)} MB";
    internal static string FormatTime(DateTime utc) => utc <= DateTime.UnixEpoch ? "-" : utc.ToLocalTime().ToString("MM-dd HH:mm");
    private void Raise(string name) => PropertyChanged?.Invoke(this, new(name));
    private void Header_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e) => DragMove();
    private void Close_OnClick(object sender, RoutedEventArgs e) => Close();
}
