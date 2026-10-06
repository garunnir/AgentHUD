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
    // 숨긴 세션 ID → 마지막으로 본 표시 상태
    private readonly Dictionary<string, AgentState> _dismissed = [];
    public int HiddenCount => _dismissed.Count;
    public ObservableCollection<AgentSession> Sessions { get; } = [];
    private bool _showWaitingSymbols;
    public bool ShowWaitingSymbols
    {
        get => _showWaitingSymbols;
        set
        {
            if (_showWaitingSymbols == value) return;
            _showWaitingSymbols = value;
            PropertyChanged?.Invoke(this, new(nameof(ShowWaitingSymbols)));
        }
    }
    private readonly CodexProvider _codex;
    public int CodexActiveMinutes
    {
        get => (int)_codex.ActiveWindow.TotalMinutes;
        set
        {
            value = Math.Clamp(value, 1, 1440);
            if (value == CodexActiveMinutes) return;
            _codex.ActiveWindow = TimeSpan.FromMinutes(value);
            PropertyChanged?.Invoke(this, new(nameof(CodexActiveMinutes)));
            _ = _discovery.RefreshAsync(CancellationToken.None);
        }
    }
    private readonly AutoResumer _resumer = new(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentHud"));
    public bool AutoResume
    {
        get => _resumer.Enabled;
        set
        {
            if (_resumer.Enabled == value) return;
            _resumer.Enabled = value;
            PropertyChanged?.Invoke(this, new(nameof(AutoResume)));
        }
    }
    public string ResumePrompt
    {
        get => _resumer.Prompt;
        set
        {
            if (_resumer.Prompt == value) return;
            _resumer.Prompt = value;
            PropertyChanged?.Invoke(this, new(nameof(ResumePrompt)));
        }
    }
    private readonly RateLimitNotifier _limitNotifier = new();
    public bool NotifyLimitReset
    {
        get => _limitNotifier.Enabled;
        set
        {
            if (_limitNotifier.Enabled == value) return;
            _limitNotifier.Enabled = value;
            PropertyChanged?.Invoke(this, new(nameof(NotifyLimitReset)));
        }
    }
    // 켜면 숨긴 세션이나 HUD 목록에서 빠진 세션(종료된 Claude 프로세스 등)은 알리지 않음
    private bool _notifyVisibleOnly = true;
    public bool NotifyVisibleOnly
    {
        get => _notifyVisibleOnly;
        set
        {
            if (_notifyVisibleOnly == value) return;
            _notifyVisibleOnly = value;
            PropertyChanged?.Invoke(this, new(nameof(NotifyVisibleOnly)));
        }
    }
    // 완료·질문 사운드. 키는 SoundSetting.Options, 파일 경로는 키가 File일 때만 사용
    private string _completeSound = "Asterisk", _askSound = "Exclamation", _completeSoundFile = "", _askSoundFile = "";
    public string CompleteSound { get => _completeSound; set => SetField(ref _completeSound, value, nameof(CompleteSound)); }
    public string CompleteSoundFile { get => _completeSoundFile; set => SetField(ref _completeSoundFile, value ?? "", nameof(CompleteSoundFile)); }
    public string AskSound { get => _askSound; set => SetField(ref _askSound, value, nameof(AskSound)); }
    public string AskSoundFile { get => _askSoundFile; set => SetField(ref _askSoundFile, value ?? "", nameof(AskSoundFile)); }
    private bool _completeSoundEnabled = true, _askSoundEnabled = true;
    public bool CompleteSoundEnabled { get => _completeSoundEnabled; set => SetField(ref _completeSoundEnabled, value, nameof(CompleteSoundEnabled)); }
    public bool AskSoundEnabled { get => _askSoundEnabled; set => SetField(ref _askSoundEnabled, value, nameof(AskSoundEnabled)); }
    private void SetField<T>(ref T field, T value, string name)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value;
        PropertyChanged?.Invoke(this, new(name));
    }
    // 세션별 직전 표시 상태. 상태가 바뀌는 순간에만 소리를 낸다
    private readonly Dictionary<string, AgentState> _lastStates = [];
    private bool _soundsPrimed;
    private void PlayStateSounds(IReadOnlyCollection<AgentSession> all)
    {
        bool complete = false, ask = false;
        var seen = new HashSet<string>();
        foreach (var s in all)
        {
            seen.Add(s.Id);
            var state = s.DisplayState;
            var known = _lastStates.TryGetValue(s.Id, out var prev);
            _lastStates[s.Id] = state;
            // 첫 스캔이나 오래된 세션이 뒤늦게 발견된 경우는 알리지 않음
            if (!_soundsPrimed || (known && prev == state) || s.ParentSessionId is not null
                || DateTime.UtcNow - s.LastActivityAt.ToUniversalTime() > TimeSpan.FromSeconds(60)) continue;
            if (state == AgentState.Completed) complete = true;
            else if (state is AgentState.WaitingForInput or AgentState.WaitingForApproval) ask = true;
        }
        foreach (var id in _lastStates.Keys.Where(id => !seen.Contains(id)).ToArray()) _lastStates.Remove(id);
        _soundsPrimed = true;
        if (ask && AskSoundEnabled) SoundSetting.Play(AskSound, AskSoundFile);
        else if (complete && CompleteSoundEnabled) SoundSetting.Play(CompleteSound, CompleteSoundFile);
    }
    private readonly List<NotificationWindow> _notifications = [];
    private void ShowLimitReset(AgentSession session)
    {
        var body = $"{session.DisplayTitle}\n{session.RateLimitResetAt!.Value.ToLocalTime():HH:mm}에 한도가 풀렸습니다. "
            + (AutoResume ? "잠시 뒤 자동으로 이어서 진행합니다." : "클릭하면 대화를 엽니다.");
        var w = new NotificationWindow($"{session.DisplayName} 한도 해제 · {session.ProjectName}", body, () => { _registry.AcknowledgeCompletion(session.Id); OpenInVsCode(session); });
        w.Loaded += (_, _) => LayoutNotifications();
        w.Closed += (_, _) => { _notifications.Remove(w); LayoutNotifications(); };
        _notifications.Add(w);
        w.Show();
        System.Media.SystemSounds.Asterisk.Play();
    }
    // 작업 영역 오른쪽 아래부터 위로 쌓음
    private void LayoutNotifications()
    {
        var area = SystemParameters.WorkArea;
        var bottom = area.Bottom - 12;
        foreach (var w in _notifications)
        {
            w.Left = area.Right - w.Width - 12;
            bottom -= w.ActualHeight;
            w.Top = bottom;
            bottom -= 8;
        }
    }
    private SettingsWindow? _settingsWindow;
    private void Settings_OnClick(object sender, RoutedEventArgs e)
    {
        if (_settingsWindow is not null) { _settingsWindow.Activate(); return; }
        _settingsWindow = new SettingsWindow { Owner = this, DataContext = this };
        _settingsWindow.Left = Math.Max(SystemParameters.VirtualScreenLeft, Left - _settingsWindow.Width - 8);
        _settingsWindow.Top = Top;
        _settingsWindow.Closed += (_, _) => { _settingsWindow = null; SavePlacement(); };
        _settingsWindow.Show();
    }
    public int ActiveCount => Sessions.Count(x => x.IsActive);
    public MemoStore Memos { get; } = new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentHud", "memos.json"));
    // 메모 아이콘 MultiBinding 갱신용 카운터
    public int MemoVersion { get; private set; }
    private readonly Dictionary<string, MemoWindow> _memoWindows = [];
    public event PropertyChangedEventHandler? PropertyChanged;

    public MainWindow()
    {
        InitializeComponent(); DataContext = this;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        _codex = new CodexProvider(home);
        _claudeLink.ExtraSource = () => _claudeApi.Latest;
        _claudeApi.Updated += () => Dispatcher.BeginInvoke(() => { PropertyChanged?.Invoke(this, new(nameof(ClaudeApiStatus))); UpdateUsage(_registry.GetAllAgents()); });
        Closed += (_, _) => _claudeApi.Dispose();
        _discovery = new AgentDiscoveryService([new ClaudeCodeProvider(home), _codex], _registry);
        _registry.Changed += (_, _) => Dispatcher.Invoke(UpdateSessions);
        ContentRendered += (_, _) => _desktopFollower ??= new VirtualDesktopFollower(new WindowInteropHelper(this).Handle);
        Closed += (_, _) => _desktopFollower?.Dispose();
        Loaded += (_, _) => { RestorePlacement(); _discovery.Start(); _claudeApi.Start(); };
        Closing += OnClosing;
        // 최소화 중 세션 수가 바뀌어 폭이 변해도 오른쪽 끝을 고정
        SizeChanged += (_, _) => { if (_minimized) Left = _anchorRight - ActualWidth; };
        Memos.Changed += (_, _) => { MemoVersion++; PropertyChanged?.Invoke(this, new(nameof(MemoVersion))); };
    }
    private void UpdateSessions()
    {
        var all = _registry.GetAllAgents();
        _resumer.Check(all);
        PlayStateSounds(all);
        // 숨긴 세션은 초기화 전까지 숨기되, 새로 대기·완료 상태가 되면 다시 표시
        foreach (var (id, seen) in _dismissed.ToArray())
        {
            if (all.FirstOrDefault(x => x.Id == id) is not { } s) _dismissed.Remove(id);
            else if (s.DisplayState != seen && NeedsAttention(s.DisplayState)) _dismissed.Remove(id);
            else _dismissed[id] = s.DisplayState;
        }
        var next = all.Where(x => !_dismissed.ContainsKey(x.Id) && (x.HasUnreadCompletion || x.IsActive || DateTime.UtcNow - x.LastActivityAt.ToUniversalTime() < TimeSpan.FromSeconds(30))).ToArray();
        foreach (var session in _limitNotifier.TakeDue(NotifyVisibleOnly ? next : all)) ShowLimitReset(session);
        for (var i = 0; i < next.Length; i++)
        {
            if (i >= Sessions.Count) Sessions.Add(next[i]);
            else if (Sessions[i] != next[i]) Sessions[i] = next[i];
        }
        while (Sessions.Count > next.Length) Sessions.RemoveAt(Sessions.Count - 1);
        UpdateUsage(all);
        PropertyChanged?.Invoke(this, new(nameof(ActiveCount)));
        PropertyChanged?.Invoke(this, new(nameof(HiddenCount)));
    }
    // 하단 사용량 막대. 감지된 LLM이 없으면 비어 있음
    public ObservableCollection<UsageRow> UsageRows { get; } = [];
    // Claude는 서버 한도를 로컬에서 알 수 없어, 사용자가 정한 토큰 예산(백만 단위, 0이면 막대 없이 합계만)을 기준으로 함
    private readonly ClaudeLimitLink _claudeLink = new(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentHud"));
    // 켜면 Claude Code 상태줄 스크립트를 등록해 서버 기준 한도를 받아옴(~/.claude/settings.json 수정)
    public bool ClaudeLimitLinked
    {
        get => _claudeLink.IsLinked;
        set
        {
            if (_claudeLink.IsLinked == value) return;
            try { if (value) _claudeLink.Link(); else _claudeLink.Unlink(); }
            catch (Exception e) { MessageBox.Show(this, e.Message, "Claude 한도 연동 실패"); }
            PropertyChanged?.Invoke(this, new(nameof(ClaudeLimitLinked)));
            UpdateUsage(_registry.GetAllAgents());
        }
    }
    // claude.ai 사용량 API 연동(sessionKey는 DPAPI로 암호화 저장). 5분마다 조회
    private readonly ClaudeUsageApi _claudeApi = new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentHud"));
    public string ClaudeOrgId { get => _claudeApi.OrgId ?? ""; set { _claudeApi.OrgId = value; PropertyChanged?.Invoke(this, new(nameof(ClaudeOrgId))); } }
    public string ClaudeApiStatus => _claudeApi.Status;
    public bool ClaudeApiHasKey => _claudeApi.HasKey;
    public void SetClaudeSessionKey(string? key)
    {
        try { _claudeApi.SetKey(key); }
        catch (Exception e) when (e is IOException or System.Security.Cryptography.CryptographicException or UnauthorizedAccessException) { MessageBox.Show(this, e.Message, "키 저장 실패"); }
        PropertyChanged?.Invoke(this, new(nameof(ClaudeApiHasKey)));
    }
    private double _claudeBudget5h, _claudeBudgetWeek;
    public double ClaudeBudget5h { get => _claudeBudget5h; set { value = Math.Max(0, value); if (_claudeBudget5h == value) return; _claudeBudget5h = value; PropertyChanged?.Invoke(this, new(nameof(ClaudeBudget5h))); UpdateUsage(_registry.GetAllAgents()); } }
    public double ClaudeBudgetWeek { get => _claudeBudgetWeek; set { value = Math.Max(0, value); if (_claudeBudgetWeek == value) return; _claudeBudgetWeek = value; PropertyChanged?.Invoke(this, new(nameof(ClaudeBudgetWeek))); UpdateUsage(_registry.GetAllAgents()); } }
    private void UpdateUsage(IReadOnlyCollection<AgentSession> all)
    {
        var now = DateTime.UtcNow;
        var rows = new List<UsageRow>();
        var claude = all.Where(x => x.AgentType == AgentType.ClaudeCode).ToArray();
        if (claude.Length > 0)
        {
            // 상태줄 연동으로 받은 서버 한도가 있으면 그 값, 없으면 토큰 합계(와 예산)
            var (fiveHour, sevenDay) = _claudeLink.ReadLimits();
            rows.Add(fiveHour is { } five ? CodexRow(AgentType.ClaudeCode, "5h", five, now) : ClaudeRow("5h", claude.Sum(x => x.Tokens5h), _claudeBudget5h));
            rows.Add(sevenDay is { } seven ? CodexRow(AgentType.ClaudeCode, "주간", seven, now) : ClaudeRow("주간", claude.Sum(x => x.TokensWeek), _claudeBudgetWeek));
        }
        // 한도는 계정 단위라 가장 최근 활동한 세션의 값을 사용
        if (all.Any(x => x.AgentType == AgentType.Codex))
        {
            var codex = all.Where(x => x.AgentType == AgentType.Codex && x.PrimaryLimit is not null).MaxBy(x => x.LastActivityAt);
            if (codex is null) rows.Add(new(AgentType.Codex, "", null, "한도 정보 없음"));
            else
            {
                rows.Add(CodexRow(AgentType.Codex, "5h", codex.PrimaryLimit!, now));
                if (codex.SecondaryLimit is { } week) rows.Add(CodexRow(AgentType.Codex, "주간", week, now));
            }
        }
        for (var i = 0; i < rows.Count; i++)
        {
            if (i >= UsageRows.Count) UsageRows.Add(rows[i]);
            else if (UsageRows[i] != rows[i]) UsageRows[i] = rows[i];
        }
        while (UsageRows.Count > rows.Count) UsageRows.RemoveAt(UsageRows.Count - 1);
    }
    private static UsageRow ClaudeRow(string label, long tokens, double budgetM) =>
        budgetM <= 0 ? new(AgentType.ClaudeCode, label, null, $"{FormatTokens(tokens)} 토큰")
        : new(AgentType.ClaudeCode, label, Math.Min(100, tokens / (budgetM * 1_000_000) * 100), $"{FormatTokens(tokens)}/{budgetM:0.#}M");
    private static UsageRow CodexRow(AgentType agent, string label, LimitWindow window, DateTime now)
    {
        var used = window.PercentAt(now);
        var left = window.ResetsAt - now;
        var reset = left <= TimeSpan.Zero || left > TimeSpan.FromDays(8) ? "" : left.TotalHours >= 24 ? $"{left.TotalDays:0.#}일" : $"{(int)left.TotalHours}시간 {left.Minutes}분";
        // 균등하게 쓴다고 가정한 권장 잔량 = 창에서 남은 시간의 비율
        var length = label == "5h" ? TimeSpan.FromHours(5) : TimeSpan.FromDays(7);
        double? pace = left <= TimeSpan.Zero || left > length ? null : left / length * 100;
        return new(agent, label, used, reset, pace);
    }
    private static string FormatTokens(long n) => n >= 1_000_000 ? $"{n / 1_000_000.0:0.0}M" : n >= 1_000 ? $"{n / 1_000.0:0.0}K" : n.ToString();
    private static bool NeedsAttention(AgentState state) => state is AgentState.WaitingForInput or AgentState.WaitingForApproval or AgentState.Completed;
    private void Header_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e) { if (e.ClickCount == 2) ToggleMinimized(); else DragMove(); }
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
            Frame.Padding = new Thickness(4, 2, 4, 2);
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
    private void Memo_OnClick(object sender, RoutedEventArgs e) => ShowMemo("", "메모장", Memos.Global, Memos.SetGlobal);
    private void ProjectMemo_OnClick(object sender, RoutedEventArgs e)
    {
        if (sender is FrameworkElement { DataContext: AgentSession session }) ShowProjectMemo(session);
    }
    private void MemoIcon_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: AgentSession session }) return;
        e.Handled = true;
        ShowProjectMemo(session);
    }
    private void ShowProjectMemo(AgentSession session)
    {
        if (session.ProjectPath is not { } path || string.IsNullOrWhiteSpace(path)) return;
        ShowMemo("project:" + path.ToUpperInvariant(), "메모 · " + session.ProjectName, Memos.GetProject(path) ?? "", text => Memos.SetProject(path, text));
    }
    // 같은 대상의 메모 창이 이미 열려 있으면 앞으로 가져오고, 없으면 HUD 왼쪽에 새로 연다
    private void ShowMemo(string key, string header, string text, Action<string> save)
    {
        if (_memoWindows.TryGetValue(key, out var open)) { open.Activate(); return; }
        var w = new MemoWindow(header, text, save) { Owner = this };
        w.Left = Math.Max(SystemParameters.VirtualScreenLeft, Left - w.Width - 8 - _memoWindows.Count * 24);
        w.Top = Top + _memoWindows.Count * 24;
        w.Closed += (_, _) => _memoWindows.Remove(key);
        _memoWindows[key] = w;
        w.Show();
    }
    private void Dismiss_OnClick(object sender, RoutedEventArgs e)
    {
        if (sender is not FrameworkElement { DataContext: AgentSession session }) return;
        // 완료 표시는 확인 처리해 숨긴 직후 다시 나타나지 않게 함
        _dismissed[session.Id] = session.HasUnreadCompletion ? AgentState.Idle : session.DisplayState;
        if (session.HasUnreadCompletion) _registry.AcknowledgeCompletion(session.Id);
        UpdateSessions();
    }
    private void ResetHidden_OnClick(object sender, RoutedEventArgs e) { _dismissed.Clear(); UpdateSessions(); }
    private void Close_OnClick(object sender, RoutedEventArgs e) => Close();
    private async void OnClosing(object? sender, CancelEventArgs e)
    {
        foreach (var w in _memoWindows.Values.ToArray()) w.Close();
        foreach (var w in _notifications.ToArray()) w.Close();
        SavePlacement();
        await _discovery.DisposeAsync();
    }
    private static string PlacementPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentHud", "placement.json");
    private void RestorePlacement()
    {
        try { if (File.Exists(PlacementPath)) { var p = JsonSerializer.Deserialize<Placement>(File.ReadAllText(PlacementPath)); if (p is not null) { ShowWaitingSymbols = p.ShowWaitingSymbols; CodexActiveMinutes = p.CodexActiveMinutes; AutoResume = p.AutoResume; NotifyLimitReset = p.NotifyLimitReset; NotifyVisibleOnly = p.NotifyVisibleOnly; ClaudeOrgId = p.ClaudeOrgId ?? ""; ClaudeBudget5h = p.ClaudeBudget5h; ClaudeBudgetWeek = p.ClaudeBudgetWeek; if (p.ResumePrompt is { } prompt) ResumePrompt = prompt; CompleteSoundEnabled = p.CompleteSoundEnabled && p.CompleteSound != SoundSetting.Off; CompleteSound = p.CompleteSound == SoundSetting.Off ? "Asterisk" : p.CompleteSound; CompleteSoundFile = p.CompleteSoundFile ?? ""; AskSoundEnabled = p.AskSoundEnabled && p.AskSound != SoundSetting.Off; AskSound = p.AskSound == SoundSetting.Off ? "Exclamation" : p.AskSound; AskSoundFile = p.AskSoundFile ?? ""; Left = p.Left; Top = p.Top; if (double.IsFinite(p.Width) && p.Width >= MinWidth) Width = p.Width; if (double.IsFinite(p.Height) && p.Height >= MinHeight) Height = p.Height; } } else { Left = SystemParameters.WorkArea.Right - Width - 20; Top = 20; } } catch { Left = SystemParameters.WorkArea.Right - Width - 20; Top = 20; }
    }
    private void SavePlacement()
    {
        try { Directory.CreateDirectory(Path.GetDirectoryName(PlacementPath)!); var p = _minimized ? new Placement(_anchorRight - _restoreSize.Width, Top, _restoreSize.Width, _restoreSize.Height) : new Placement(Left, Top, ActualWidth, ActualHeight); File.WriteAllText(PlacementPath, JsonSerializer.Serialize(p with { ShowWaitingSymbols = ShowWaitingSymbols, CodexActiveMinutes = CodexActiveMinutes, AutoResume = AutoResume, ResumePrompt = ResumePrompt, NotifyLimitReset = NotifyLimitReset, NotifyVisibleOnly = NotifyVisibleOnly, ClaudeOrgId = ClaudeOrgId, ClaudeBudget5h = ClaudeBudget5h, ClaudeBudgetWeek = ClaudeBudgetWeek, CompleteSound = CompleteSound, CompleteSoundFile = CompleteSoundFile, AskSound = AskSound, AskSoundFile = AskSoundFile, CompleteSoundEnabled = CompleteSoundEnabled, AskSoundEnabled = AskSoundEnabled })); } catch { }
    }
    private sealed record Placement(double Left, double Top, double Width = 280, double Height = 220, bool ShowWaitingSymbols = false, int CodexActiveMinutes = 5, bool AutoResume = false, string? ResumePrompt = null, bool NotifyLimitReset = true, bool NotifyVisibleOnly = true, double ClaudeBudget5h = 0, double ClaudeBudgetWeek = 0, string? ClaudeOrgId = null, string CompleteSound = "Asterisk", string? CompleteSoundFile = null, string AskSound = "Exclamation", string? AskSoundFile = null, bool CompleteSoundEnabled = true, bool AskSoundEnabled = true);
}


// 하단 사용량 한 줄. UsedPercent가 null이면 막대 없이 텍스트만
public sealed record UsageRow(AgentType AgentType, string Label, double? UsedPercent, string Text, double? PacePercent = null)
{
    // 권장 잔량 눈금 위치(막대를 PaceLeft:PaceRight로 분할). 값이 없으면 눈금을 숨김
    public System.Windows.GridLength PaceLeft => new(PacePercent ?? 0, System.Windows.GridUnitType.Star);
    public System.Windows.GridLength PaceRight => new(100 - (PacePercent ?? 0), System.Windows.GridUnitType.Star);
    public System.Windows.Visibility PaceVisibility => PacePercent is null ? System.Windows.Visibility.Collapsed : System.Windows.Visibility.Visible;
    public string? BarToolTip => PacePercent is { } p ? $"권장 잔량 {p:0}% (균등 소비 기준)" : null;
    public string AgentName => AgentType == AgentType.ClaudeCode ? "Claude" : "Codex";
    // 게이지는 남은 비율을 채움
    public double Value => 100 - (UsedPercent ?? 0);
    public string BarText => $"{Value:0}%";
    public System.Windows.Visibility BarVisibility => UsedPercent is null ? System.Windows.Visibility.Collapsed : System.Windows.Visibility.Visible;
    public System.Windows.Media.Brush Fill => UsedPercent switch
    {
        >= 90 => System.Windows.Media.Brushes.IndianRed,
        >= 70 => System.Windows.Media.Brushes.Goldenrod,
        _ => System.Windows.Media.Brushes.SteelBlue
    };
}
