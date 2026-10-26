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
    // 사용량 막대의 균등 소비(권장 잔량) 눈금 표시
    private bool _showPaceMarker = true;
    public bool ShowPaceMarker { get => _showPaceMarker; set { if (_showPaceMarker == value) return; SetField(ref _showPaceMarker, value, nameof(ShowPaceMarker)); UpdateUsage(_registry.GetAllAgents()); } }
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
        var body = Loc.F("Notify.LimitResetBody", session.DisplayTitle, session.RateLimitResetAt!.Value.ToLocalTime())
            + " " + Loc.T(AutoResume ? "Notify.AutoResumeSoon" : "Notify.ClickToOpen");
        var w = new NotificationWindow(Loc.F("Notify.LimitResetTitle", session.DisplayName, session.ProjectName), body, () => { _registry.AcknowledgeCompletion(session.Id); OpenInVsCode(session); });
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
    // 표시 언어(빈 문자열이면 시스템 언어)
    public string UiLanguage
    {
        get => Loc.Instance.Language;
        set
        {
            if (Loc.Instance.Language == (value ?? Loc.Auto)) return;
            Loc.Instance.Language = value ?? Loc.Auto;
            PropertyChanged?.Invoke(this, new(nameof(UiLanguage)));
            PropertyChanged?.Invoke(this, new(nameof(ResumePrompt)));
            // 세션 항목의 문구(제목 없음, 한도 툴팁 등)는 항목을 다시 넣어야 갱신됨
            Sessions.Clear();
            UpdateSessions();
            PropertyChanged?.Invoke(this, new(nameof(ClaudeApiStatus)));
            PropertyChanged?.Invoke(this, new(nameof(OpenCodeGoStatus)));
            PropertyChanged?.Invoke(this, new(nameof(UpdateStatus)));
            PropertyChanged?.Invoke(this, new(nameof(UpdateMenuText)));
            PropertyChanged?.Invoke(this, new(nameof(UpdateDotToolTip)));
            UpdateUsage(_registry.GetAllAgents());
        }
    }
    // 자동 업데이트: 시작 시와 6시간마다 GitHub 최신 릴리스를 확인. 팝업으로 재촉하지 않고 헤더 점 + 우클릭 메뉴 문구만 바꾸며,
    // 설치는 사용자가 메뉴(또는 설정의 "지금 확인")에서 고르고 확인 창에 동의할 때만 진행
    private readonly AppUpdater _updater = new(DataDirectory);
    private bool _autoUpdateCheck = true;
    public bool AutoUpdateCheck { get => _autoUpdateCheck; set { SetField(ref _autoUpdateCheck, value, nameof(AutoUpdateCheck)); if (value) _ = CheckForUpdateAsync(false); } }
    public bool UpdateSupported => _updater.Supported;
    private string? _updateStatus;
    public string UpdateStatus { get => _updateStatus ?? (_updater.Supported ? Loc.F("Update.Current", _updater.CurrentText) : Loc.T("Update.DevBuild")); private set => SetField(ref _updateStatus, value, nameof(UpdateStatus)); }
    private UpdateRelease? _pendingUpdate;
    private UpdateRelease? PendingUpdate
    {
        get => _pendingUpdate;
        set
        {
            _pendingUpdate = value;
            PropertyChanged?.Invoke(this, new(nameof(UpdateMenuText)));
            PropertyChanged?.Invoke(this, new(nameof(UpdateDotVisibility)));
            PropertyChanged?.Invoke(this, new(nameof(UpdateDotToolTip)));
        }
    }
    // 개발 빌드(UpdateAsset 메타데이터 없음)에서도 메뉴는 보이되 비활성 + 이유 표시
    public string UpdateMenuText => !_updater.Supported ? Loc.T("Main.CheckUpdateDev") : PendingUpdate is { } r ? Loc.F("Main.InstallUpdate", r.Tag) : Loc.T("Main.CheckUpdate");
    public Visibility UpdateDotVisibility => PendingUpdate is null ? Visibility.Collapsed : Visibility.Visible;
    public string? UpdateDotToolTip => PendingUpdate is { } r ? Loc.F("Main.UpdateDotTip", r.Tag) : null;
    private bool _updateBusy;
    private async void StartUpdateTimer()
    {
        if (!_updater.Supported) return;
        await Task.Delay(TimeSpan.FromSeconds(15));
        using var timer = new PeriodicTimer(TimeSpan.FromHours(6));
        do { if (AutoUpdateCheck) await CheckForUpdateAsync(false); } while (await timer.WaitForNextTickAsync());
    }
    // manual이면 결과를 대화상자로 알리고, 새 버전이 있으면 바로 설치 여부를 묻는다
    public async Task CheckForUpdateAsync(bool manual)
    {
        if (!_updater.Supported || _updateBusy) return;
        _updateBusy = true;
        if (manual) UpdateStatus = Loc.T("Update.Checking");
        try
        {
            PendingUpdate = await _updater.CheckAsync();
            UpdateStatus = PendingUpdate is { } r ? Loc.F("Update.Available", r.Tag) : Loc.F("Update.UpToDate", _updater.CurrentText);
        }
        catch (Exception e) when (e is System.Net.Http.HttpRequestException or TaskCanceledException or System.Text.Json.JsonException)
        {
            if (manual) { UpdateStatus = Loc.F("Update.Failed", e.Message); MessageBox.Show(UpdateStatus, "Agent HUD"); }
            return;
        }
        finally { _updateBusy = false; }
        if (!manual) return;
        if (PendingUpdate is null) MessageBox.Show(UpdateStatus, "Agent HUD");
        else await InstallUpdateAsync();
    }
    public async Task InstallUpdateAsync()
    {
        if (PendingUpdate is not { } release || _updateBusy) return;
        if (MessageBox.Show(Loc.F("Update.Confirm", release.Tag, _updater.CurrentText), "Agent HUD", MessageBoxButton.OKCancel, MessageBoxImage.Question) != MessageBoxResult.OK) return;
        // 설치 폴더에 쓸 수 없으면 직접 받도록 릴리스 페이지를 연다
        if (!AppUpdater.CanWriteInstallDir()) { ShellOpen(release.PageUrl); UpdateStatus = Loc.T("Update.NotWritable"); return; }
        _updateBusy = true;
        UpdateStatus = Loc.F("Update.Downloading", release.Tag);
        try { await _updater.PrepareAsync(release); }
        catch (Exception e) { UpdateStatus = Loc.F("Update.Failed", e.Message); _updateBusy = false; MessageBox.Show(UpdateStatus, "Agent HUD"); return; }
        Close();
    }
    private void UpdateMenu_OnClick(object sender, RoutedEventArgs e) => _ = PendingUpdate is null ? CheckForUpdateAsync(true) : InstallUpdateAsync();
    // 오래된 세션 정리 창에서 "최근 N개만 남기고 선택"에 쓰는 N
    private int _cleanupKeepLatest = 3;
    public int CleanupKeepLatest { get => _cleanupKeepLatest; set => SetField(ref _cleanupKeepLatest, Math.Clamp(value, 0, 99), nameof(CleanupKeepLatest)); }
    private CleanupWindow? _cleanupWindow;
    /// <summary>프로세스 트리 정리 창. 열려 있으면 앞으로 가져온다(설정 창에서 열어도 소유자는 HUD)</summary>
    public void ShowCleanup()
    {
        if (_cleanupWindow is not null) { _cleanupWindow.Activate(); return; }
        _cleanupWindow = new CleanupWindow(() => _registry.GetAllAgents(), CleanupKeepLatest, n => CleanupKeepLatest = n) { Owner = this };
        _cleanupWindow.Left = Math.Max(SystemParameters.VirtualScreenLeft, Left + ActualWidth - _cleanupWindow.Width);
        _cleanupWindow.Top = Math.Max(SystemParameters.VirtualScreenTop, Top + 28);
        _cleanupWindow.Closed += (_, _) => { _cleanupWindow = null; SavePlacement(); };
        _cleanupWindow.Show();
    }
    private void Cleanup_OnClick(object sender, RoutedEventArgs e) => ShowCleanup();
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
        _claudeApi.Updated += () => Dispatcher.BeginInvoke(() => { PropertyChanged?.Invoke(this, new(nameof(ClaudeApiStatus))); UpdateUsage(_registry.GetAllAgents()); });
        Closed += (_, _) => { _claudeApi.Dispose(); _openCodeGo.Dispose(); _updater.Dispose(); };
        _openCodeGo.Updated += () => Dispatcher.BeginInvoke(() => { PropertyChanged?.Invoke(this, new(nameof(OpenCodeGoStatus))); UpdateUsage(_registry.GetAllAgents()); });
        _discovery = new AgentDiscoveryService([new ClaudeCodeProvider(home), _codex, new OpenCodeProvider(home, dataHome: Environment.GetEnvironmentVariable("XDG_DATA_HOME"))], _registry);
        _registry.Changed += (_, _) => Dispatcher.Invoke(UpdateSessions);
        ContentRendered += (_, _) => _desktopFollower ??= new VirtualDesktopFollower(new WindowInteropHelper(this).Handle);
        Closed += (_, _) => { _desktopFollower?.Dispose(); SleepInhibitor.Set(false); };
        Loaded += (_, _) => { RestorePlacement(); _discovery.Start(); _claudeApi.Start(); _openCodeGo.Start(); StartUpdateTimer(); };
        Closing += OnClosing;
        // 최소화 중 세션 수가 바뀌어 폭이 변해도 오른쪽 끝을 고정
        SizeChanged += (_, _) => { if (_minimized) Left = _anchorRight - ActualWidth; };
        Memos.Changed += (_, _) => { MemoVersion++; PropertyChanged?.Invoke(this, new(nameof(MemoVersion))); };
    }
    private void UpdateSessions()
    {
        var all = _registry.GetAllAgents();
        _resumer.Check(all);
        SleepInhibitor.Set(all.Any(x => x.DisplayState is AgentState.Working or AgentState.Thinking));
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
    // 켜면 Claude Code 상태줄 스크립트를 등록해 서버 기준 한도를 받아옴(~/.claude/settings.json 수정). 기본값(default)
    // 사용자가 명시적으로 끈 것(false)과 "아직 물어본 적 없음"(null)을 구분해야 해서 선택 여부는 placement.json에 별도 저장
    private bool? _claudeLinkChoice;
    public bool ClaudeLimitLinked
    {
        get => _claudeLink.IsLinked;
        set
        {
            if (_claudeLink.IsLinked == value) { _claudeLinkChoice = value; return; }
            try { if (value) _claudeLink.Link(); else _claudeLink.Unlink(); _claudeLinkChoice = value; }
            catch (Exception e) { MessageBox.Show(this, e.Message, Loc.T("Error.ClaudeLinkFailed")); }
            PropertyChanged?.Invoke(this, new(nameof(ClaudeLimitLinked)));
            UpdateUsage(_registry.GetAllAgents());
        }
    }
    // claude.ai 사용량 API 연동(sessionKey는 DPAPI로 암호화 저장). 고급/비공식 옵션이라 명시적으로 켜야 하고(opt-in),
    // 5분마다 조회. VS Code 확장처럼 statusLine이 실행되지 않는 환경을 쓰는 사람을 위한 보조 경로
    private readonly ClaudeUsageApi _claudeApi = new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentHud"));
    public string ClaudeOrgId { get => _claudeApi.OrgId ?? ""; set { _claudeApi.OrgId = value; PropertyChanged?.Invoke(this, new(nameof(ClaudeOrgId))); } }
    public string ClaudeApiStatus => _claudeApi.Status;
    public bool ClaudeApiHasKey => _claudeApi.HasKey;
    public bool ClaudeApiEnabled
    {
        get => _claudeApi.Enabled;
        set
        {
            if (_claudeApi.Enabled == value) return;
            _claudeApi.Enabled = value;
            PropertyChanged?.Invoke(this, new(nameof(ClaudeApiEnabled)));
            PropertyChanged?.Invoke(this, new(nameof(ClaudeApiStatus)));
            UpdateUsage(_registry.GetAllAgents());
        }
    }
    public void SetClaudeSessionKey(string? key)
    {
        try { _claudeApi.SetKey(key); }
        catch (Exception e) when (e is IOException or System.Security.Cryptography.CryptographicException or UnauthorizedAccessException) { MessageBox.Show(this, e.Message, Loc.T("Error.KeySaveFailed")); }
        PropertyChanged?.Invoke(this, new(nameof(ClaudeApiHasKey)));
    }
    private static readonly string DataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentHud");
    private readonly OpenCodeGoUsageApi _openCodeGo = new(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentHud"));
    public string OpenCodeWorkspaceId { get => _openCodeGo.WorkspaceId; set { _openCodeGo.WorkspaceId = value; PropertyChanged?.Invoke(this, new(nameof(OpenCodeWorkspaceId))); } }
    public string OpenCodeGoStatus => _openCodeGo.Status;
    public void LoginOpenCode(Window owner) => new OpenCodeLoginWindow(_openCodeGo, DataDirectory) { Owner = owner }.ShowDialog();
    public Task RefreshOpenCodeAsync() => _openCodeGo.RefreshAsync();
    public void LogoutOpenCode()
    {
        try { _openCodeGo.ClearCookies(); }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { MessageBox.Show(this, Loc.T("Go.LogoutFailed")); }
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
            // statusLine(기본, 공식 CLI 값)과 sessionKey API(선택, 비공식) 중 더 신선하고 유효한 쪽을 쓴다.
            // 정책은 ClaudeLimitPolicy.Pick에 있다(두 소스를 섞지 않고, 창별 resets_at도 따로 확인).
            var lastActivity = claude.Max(x => x.LastActivityAt).ToUniversalTime();
            var pick = ClaudeLimitPolicy.Pick(_claudeLink.ReadSnapshot(), _claudeApi.Snapshot, now, lastActivity);
            rows.Add(ClaudeLimitRow("5h", pick.FiveHour, pick.FiveHourStale, pick.UpdatedAt, claude.Sum(x => x.Tokens5h), _claudeBudget5h, now));
            rows.Add(ClaudeLimitRow(UsageRow.Week, pick.SevenDay, pick.SevenDayStale, pick.UpdatedAt, claude.Sum(x => x.TokensWeek), _claudeBudgetWeek, now));
        }
        // 한도는 계정 단위라 가장 최근 활동한 세션의 값을 사용
        if (all.Any(x => x.AgentType == AgentType.Codex))
        {
            var codex = all.Where(x => x.AgentType == AgentType.Codex && x.PrimaryLimit is not null).MaxBy(x => x.LastActivityAt);
            if (codex is null) rows.Add(new(AgentType.Codex, "", null, Loc.T("Usage.NoLimitInfo")));
            else
            {
                rows.Add(CodexRow(AgentType.Codex, "5h", codex.PrimaryLimit!, now));
                if (codex.SecondaryLimit is { } week) rows.Add(CodexRow(AgentType.Codex, UsageRow.Week, week, now));
            }
        }
        if (_openCodeGo.Latest is { } go)
        {
            rows.Add(CodexRow(AgentType.OpenCode, "5h", go.FiveHour, now) with { PacePercent = null });
            rows.Add(CodexRow(AgentType.OpenCode, UsageRow.Week, go.Week, now) with { PacePercent = null });
            rows.Add(CodexRow(AgentType.OpenCode, UsageRow.Month, go.Month, now) with { PacePercent = null });
        }
        else if (!string.IsNullOrEmpty(OpenCodeWorkspaceId)) rows.Add(new(AgentType.OpenCode, "Go", null, OpenCodeGoStatus));
        if (!ShowPaceMarker) for (var i = 0; i < rows.Count; i++) rows[i] = rows[i] with { PacePercent = null };
        for (var i = 0; i < rows.Count; i++)
        {
            if (i >= UsageRows.Count) UsageRows.Add(rows[i]);
            else if (UsageRows[i] != rows[i]) UsageRows[i] = rows[i];
        }
        while (UsageRows.Count > rows.Count) UsageRows.RemoveAt(UsageRows.Count - 1);
    }
    private static UsageRow ClaudeRow(string label, long tokens, double budgetM) =>
        budgetM <= 0 ? new(AgentType.ClaudeCode, label, null, Loc.F("Usage.Tokens", FormatTokens(tokens)))
        : new(AgentType.ClaudeCode, label, Math.Min(100, tokens / (budgetM * 1_000_000) * 100), $"{FormatTokens(tokens)}/{budgetM:0.#}M");
    // 한도 창이 없으면(두 소스 모두 값 없음) 토큰 예산 추정치로, 있지만 오래됐으면 "Stale"로(창의 ResetsAt마저
    // 지났으면 숫자 없이 "Stale"만), 아니면 실제 게이지로
    private static UsageRow ClaudeLimitRow(string label, LimitWindow? window, bool stale, DateTime updatedAtUtc, long tokens, double budgetM, DateTime now) =>
        window is null ? ClaudeRow(label, tokens, budgetM)
        : !stale ? CodexRow(AgentType.ClaudeCode, label, window, now)
        : new(AgentType.ClaudeCode, label, null, window.ResetsAt <= now ? Loc.T("Usage.Stale") : Loc.F("Usage.StaleValue", window.UsedPercent))
            { TextToolTip = Loc.F("Usage.StaleTip", updatedAtUtc.ToLocalTime()) };
    private static UsageRow CodexRow(AgentType agent, string label, LimitWindow window, DateTime now)
    {
        var used = window.PercentAt(now);
        var left = window.ResetsAt - now;
        var reset = left <= TimeSpan.Zero || left > TimeSpan.FromDays(label == UsageRow.Month ? 32 : 8) ? "" : left.TotalHours >= 24 ? Loc.F("Usage.ResetDays", left.TotalDays) : Loc.F("Usage.ResetHoursMinutes", (int)left.TotalHours, left.Minutes);
        // 균등하게 쓴다고 가정한 권장 잔량 = 창에서 남은 시간의 비율
        var length = label == "5h" ? TimeSpan.FromHours(5) : TimeSpan.FromDays(7);
        double? pace = left <= TimeSpan.Zero || left > length ? null : left / length * 100;        return new(agent, label, used, reset, pace);
    }
    private static string FormatTokens(long n) => n >= 1_000_000 ? $"{n / 1_000_000.0:0.0}M" : n >= 1_000 ? $"{n / 1_000.0:0.0}K" : n.ToString();
    private static bool NeedsAttention(AgentState state) => state is AgentState.WaitingForInput or AgentState.WaitingForApproval or AgentState.Completed;
    private void Header_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e) { if (e.ClickCount == 2) ToggleMinimized(); else DragMove(); }
    // 숨기기(×)를 연타하면 아래 행이 올라와 두 번째 클릭이 그 행의 더블클릭으로 인식되므로, 직전 숨기기 직후의 더블클릭은 무시
    private long _lastDismissTick = long.MinValue / 2;
    private void List_OnMouseDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (Environment.TickCount64 - _lastDismissTick < 600) return;
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
        if (session.AgentType == AgentType.OpenCode) return null; // No verified OpenCode conversation URI; open the project only.
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
    private void Memo_OnClick(object sender, RoutedEventArgs e) => ShowMemo("", Loc.T("Main.Memo"), Memos.Global, Memos.SetGlobal);
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
        ShowMemo("project:" + path.ToUpperInvariant(), Loc.F("Memo.ProjectHeader", session.ProjectName), Memos.GetProject(path) ?? "", text => Memos.SetProject(path, text));
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
        _lastDismissTick = Environment.TickCount64;
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
        _cleanupWindow?.Close();
        foreach (var w in _notifications.ToArray()) w.Close();
        SavePlacement();
        await _discovery.DisposeAsync();
    }
    private static string PlacementPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "AgentHud", "placement.json");
    private void RestorePlacement()
    {
        try { if (File.Exists(PlacementPath)) { var p = JsonSerializer.Deserialize<Placement>(File.ReadAllText(PlacementPath)); if (p is not null) { UiLanguage = p.Language ?? Loc.Auto; ShowWaitingSymbols = p.ShowWaitingSymbols; ShowPaceMarker = p.ShowPaceMarker; CodexActiveMinutes = p.CodexActiveMinutes; AutoResume = p.AutoResume; NotifyLimitReset = p.NotifyLimitReset; NotifyVisibleOnly = p.NotifyVisibleOnly; ClaudeOrgId = p.ClaudeOrgId ?? ""; OpenCodeWorkspaceId = p.OpenCodeWorkspaceId ?? ""; ClaudeBudget5h = p.ClaudeBudget5h; ClaudeBudgetWeek = p.ClaudeBudgetWeek; _autoUpdateCheck = p.AutoUpdateCheck; CleanupKeepLatest = p.CleanupKeepLatest; if (p.ResumePrompt is { } prompt) ResumePrompt = prompt; CompleteSoundEnabled = p.CompleteSoundEnabled && p.CompleteSound != SoundSetting.Off; CompleteSound = p.CompleteSound == SoundSetting.Off ? "Asterisk" : p.CompleteSound; CompleteSoundFile = p.CompleteSoundFile ?? ""; AskSoundEnabled = p.AskSoundEnabled && p.AskSound != SoundSetting.Off; AskSound = p.AskSound == SoundSetting.Off ? "Exclamation" : p.AskSound; AskSoundFile = p.AskSoundFile ?? ""; Left = p.Left; Top = p.Top; if (double.IsFinite(p.Width) && p.Width >= MinWidth) Width = p.Width; if (double.IsFinite(p.Height) && p.Height >= MinHeight) Height = p.Height; ApplyClaudeLimitDefaults(p); } } else { Left = SystemParameters.WorkArea.Right - Width - 20; Top = 20; ApplyClaudeLimitDefaults(null); } } catch { Left = SystemParameters.WorkArea.Right - Width - 20; Top = 20; ApplyClaudeLimitDefaults(null); }
    }
    // 기존 사용자 마이그레이션: placement.json에 선택 기록이 없으면(처음 실행 또는 이전 버전 업그레이드) statusLine을
    // 조용히 한 번 연동(기본값, 실패해도 다음 실행에서 재시도). sessionKey API는 이미 키+Org ID를 설정해 둔
    // 사용자만 자동으로 opt-in 상태로 넘어가고, 그 외에는 꺼진 채로 시작한다(새로운 고급 옵션이므로)
    private void ApplyClaudeLimitDefaults(Placement? p)
    {
        _claudeApi.Enabled = p?.ClaudeApiEnabled ?? (_claudeApi.HasKey && !string.IsNullOrWhiteSpace(ClaudeOrgId));
        if (p?.ClaudeLinkEnabled is { } linked) { if (linked && !_claudeLink.IsLinked) _claudeLink.LinkQuietly(); }
        else if (!_claudeLink.IsLinked && _claudeLink.LinkQuietly()) _claudeLinkChoice = true;
    }
    private void SavePlacement()
    {
        try { Directory.CreateDirectory(Path.GetDirectoryName(PlacementPath)!); var p = _minimized ? new Placement(_anchorRight - _restoreSize.Width, Top, _restoreSize.Width, _restoreSize.Height) : new Placement(Left, Top, ActualWidth, ActualHeight); File.WriteAllText(PlacementPath, JsonSerializer.Serialize(p with { Language = UiLanguage, ShowWaitingSymbols = ShowWaitingSymbols, ShowPaceMarker = ShowPaceMarker, CodexActiveMinutes = CodexActiveMinutes, AutoResume = AutoResume, ResumePrompt = _resumer.CustomPrompt, NotifyLimitReset = NotifyLimitReset, NotifyVisibleOnly = NotifyVisibleOnly, ClaudeOrgId = ClaudeOrgId, OpenCodeWorkspaceId = OpenCodeWorkspaceId, ClaudeBudget5h = ClaudeBudget5h, ClaudeBudgetWeek = ClaudeBudgetWeek, CompleteSound = CompleteSound, CompleteSoundFile = CompleteSoundFile, AskSound = AskSound, AskSoundFile = AskSoundFile, CompleteSoundEnabled = CompleteSoundEnabled, AskSoundEnabled = AskSoundEnabled, ClaudeLinkEnabled = _claudeLinkChoice ?? ClaudeLimitLinked, ClaudeApiEnabled = ClaudeApiEnabled, AutoUpdateCheck = AutoUpdateCheck, CleanupKeepLatest = CleanupKeepLatest })); } catch { }
    }
    private sealed record Placement(double Left, double Top, double Width = 280, double Height = 220, bool ShowWaitingSymbols = false, int CodexActiveMinutes = 5, bool AutoResume = false, string? ResumePrompt = null, bool NotifyLimitReset = true, bool NotifyVisibleOnly = true, double ClaudeBudget5h = 0, double ClaudeBudgetWeek = 0, string? ClaudeOrgId = null, string CompleteSound = "Asterisk", string? CompleteSoundFile = null, string AskSound = "Exclamation", string? AskSoundFile = null, bool CompleteSoundEnabled = true, bool AskSoundEnabled = true, string? Language = null, string? OpenCodeWorkspaceId = null, bool? ClaudeLinkEnabled = null, bool? ClaudeApiEnabled = null, bool AutoUpdateCheck = true, bool ShowPaceMarker = true, int CleanupKeepLatest = 3);
}


// 하단 사용량 한 줄. UsedPercent가 null이면 막대 없이 텍스트만
public sealed record UsageRow(AgentType AgentType, string Label, double? UsedPercent, string Text, double? PacePercent = null)
{
    // "Stale"(오래됨) 표시에 왜 그런지 설명하는 말풍선. null이면 기본 BarToolTip만 보임
    public string? TextToolTip { get; init; }
    // 권장 잔량 눈금 위치(막대를 PaceLeft:PaceRight로 분할). 값이 없으면 눈금을 숨김
    public System.Windows.GridLength PaceLeft => new(PacePercent ?? 0, System.Windows.GridUnitType.Star);
    public System.Windows.GridLength PaceRight => new(100 - (PacePercent ?? 0), System.Windows.GridUnitType.Star);
    public System.Windows.Visibility PaceVisibility => PacePercent is null ? System.Windows.Visibility.Collapsed : System.Windows.Visibility.Visible;
    public const string Week = "week";
    public const string Month = "month";
    public string DisplayLabel => Label == Week ? Loc.T("Usage.Week") : Label == Month ? Loc.T("Usage.Month") : Label;
    public string? BarToolTip => PacePercent is { } p ? Loc.F("Usage.PaceTip", p) : null;
    public string AgentName => AgentType switch { AgentType.ClaudeCode => "Claude", AgentType.OpenCode => "OpenCode", _ => "Codex" };
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
