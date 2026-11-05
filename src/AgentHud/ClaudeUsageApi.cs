using System.Windows;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AgentHud.Models;

namespace AgentHud;

public sealed record ClaudeApiAccount(string OrgId, string? Email, string? Name)
{
    public string Label => !string.IsNullOrWhiteSpace(Email) ? Email!
        : !string.IsNullOrWhiteSpace(Name) ? Name!
        : OrgId.Length > 8 ? OrgId[..8] : OrgId;
}

// claude.ai 사용량 API(비공식). 계정별 sessionKey(+org)는 Windows DPAPI로 암호화 저장하고, 로그·화면에는 남기지 않는다.
// 설정은 Cursor/OpenCode와 같이 WebView 로그인으로 받고, 주기 조회는 화면 밖 WebView2로 Cloudflare를 통과한다.
// Claude Code oauthAccount.organizationUuid와 orgId가 같으면 그 계정의 사용량을 게이지에 쓴다.
public sealed class ClaudeUsageApi : IDisposable
{
    private static readonly TimeSpan Interval = TimeSpan.FromMinutes(5);
    private readonly string _keyPath;
    private readonly WebViewFetcher _web;
    private readonly CancellationTokenSource _stop = new();
    private readonly SemaphoreSlim _gate = new(1, 1);
    private readonly object _lock = new();
    private readonly List<StoredAccount> _accounts = [];
    private readonly Dictionary<string, (LimitWindow? FiveHour, LimitWindow? SevenDay, DateTime At)> _latest = new(StringComparer.OrdinalIgnoreCase);
    private int _credentialsVersion;
    // 언어가 바뀌어도 다시 그릴 수 있게 테이블 키와 인자로 보관
    private (string Key, object?[] Args) _status = ("Api.NotConfigured", []);
    public string Status => Loc.F(_status.Key, _status.Args);
    private void SetStatus(string key, params object?[] args) => _status = (key, args);
    public event Action? Updated;

    public ClaudeUsageApi(string dataDirectory)
    {
        _keyPath = Path.Combine(dataDirectory, "claude-session.bin");
        _web = new WebViewFetcher(Path.Combine(dataDirectory, "webview2"));
        LoadAccounts();
    }

    public bool HasKey { get { lock (_lock) return _accounts.Count > 0; } }
    public bool IsConfigured => Enabled && HasKey;
    public IReadOnlyList<ClaudeApiAccount> Accounts
    {
        get { lock (_lock) return _accounts.Select(x => new ClaudeApiAccount(x.OrgId, x.Email, x.Name)).ToArray(); }
    }
    private bool _enabled;
    // 고급/비공식 옵션 - 사용자가 명시적으로 켜야 함(opt-in). 꺼져 있으면 저장된 키가 있어도 WebView2를 띄우거나 조회하지 않는다
    public bool Enabled
    {
        get => _enabled;
        set
        {
            if (_enabled == value) return;
            _enabled = value;
            Interlocked.Increment(ref _credentialsVersion);
            if (!value) { lock (_lock) _latest.Clear(); SetStatus("Api.Disabled"); Updated?.Invoke(); }
            else _ = RefreshAsync();
        }
    }
    // 구 UI/배치 호환: 첫 계정의 org. 설정해도 해당 계정이 있을 때만 갱신
    public string? OrgId
    {
        get { lock (_lock) return _accounts.FirstOrDefault()?.OrgId; }
        set
        {
            value = string.IsNullOrWhiteSpace(value) ? null : value.Trim();
            if (value is null || !Guid.TryParse(value, out _)) return;
            lock (_lock)
            {
                if (_accounts.Count == 0) return;
                if (string.Equals(_accounts[0].OrgId, value, StringComparison.OrdinalIgnoreCase)) return;
                _accounts[0] = _accounts[0] with { OrgId = value };
                PersistUnlocked();
            }
            Interlocked.Increment(ref _credentialsVersion);
            _ = RefreshAsync();
            Updated?.Invoke();
        }
    }
    public (LimitWindow? FiveHour, LimitWindow? SevenDay, DateTime At) Latest =>
        Snapshot is { HasData: true } snap ? (snap.FiveHour, snap.SevenDay, snap.UpdatedAt) : default;
    public ClaudeLimitSnapshot Snapshot => SnapshotFor(OrgId);
    public ClaudeLimitSnapshot SnapshotFor(string? orgId)
    {
        if (string.IsNullOrWhiteSpace(orgId)) return ClaudeLimitSnapshot.None;
        lock (_lock)
        {
            if (!_latest.TryGetValue(orgId, out var latest) || (latest.FiveHour is null && latest.SevenDay is null))
                return ClaudeLimitSnapshot.None;
            return new(ClaudeLimitSource.UsageApi, latest.FiveHour, latest.SevenDay, latest.At);
        }
    }

    public void SaveLogin(string sessionKey, string orgId, string? email = null, string? name = null)
    {
        sessionKey = Clean(sessionKey) ?? throw new InvalidOperationException("No sessionKey");
        orgId = orgId.Trim();
        if (!Guid.TryParse(orgId, out _)) throw new InvalidOperationException("Invalid org");
        email = string.IsNullOrWhiteSpace(email) ? null : email.Trim();
        name = string.IsNullOrWhiteSpace(name) ? null : name.Trim();
        lock (_lock)
        {
            var index = _accounts.FindIndex(x => string.Equals(x.OrgId, orgId, StringComparison.OrdinalIgnoreCase));
            var next = new StoredAccount(orgId, sessionKey, email, name);
            if (index >= 0)
            {
                var prev = _accounts[index];
                _accounts[index] = next with
                {
                    Email = email ?? prev.Email,
                    Name = name ?? prev.Name
                };
            }
            else _accounts.Add(next);
            PersistUnlocked();
            _latest.Remove(orgId);
        }
        Interlocked.Increment(ref _credentialsVersion);
        Updated?.Invoke();
        _ = RefreshAsync();
    }

    public void RemoveAccount(string orgId)
    {
        lock (_lock)
        {
            var removed = _accounts.RemoveAll(x => string.Equals(x.OrgId, orgId, StringComparison.OrdinalIgnoreCase));
            if (removed == 0) return;
            _latest.Remove(orgId);
            PersistUnlocked();
            if (_accounts.Count == 0) SetStatus("Api.NotConfigured");
        }
        Interlocked.Increment(ref _credentialsVersion);
        Updated?.Invoke();
        _ = RefreshAsync();
    }

    public void ClearLogin()
    {
        lock (_lock)
        {
            _accounts.Clear();
            _latest.Clear();
            try { File.Delete(_keyPath); } catch (IOException) { }
            SetStatus("Api.NotConfigured");
        }
        Interlocked.Increment(ref _credentialsVersion);
        Updated?.Invoke();
    }

    // 구버전: 평문 sessionKey만 저장된 파일 / 수동 붙여넣기 호환
    public void SetKey(string? key)
    {
        key = Clean(key);
        if (string.IsNullOrEmpty(key)) { ClearLogin(); return; }
        string? org;
        lock (_lock) org = _accounts.FirstOrDefault()?.OrgId;
        if (org is null) throw new InvalidOperationException("Organization ID required");
        SaveLogin(key, org);
    }

    // 복사하다 딸려 오는 "sessionKey=" 접두사, 따옴표, 세미콜론, 공백·줄바꿈, URL 인코딩을 정리
    private static string? Clean(string? raw)
    {
        if (raw is null) return null;
        var value = raw.Trim().Trim('"', '\'', ';').Trim();
        if (value.StartsWith("sessionKey=", StringComparison.OrdinalIgnoreCase)) value = value["sessionKey=".Length..];
        value = value.Split(';')[0].Trim().Trim('"', '\'');
        return Uri.UnescapeDataString(string.Concat(value.Where(c => !char.IsWhiteSpace(c))));
    }

    public void Start() => _ = Task.Run(async () =>
    {
        using var timer = new PeriodicTimer(Interval);
        try { do { await RefreshAsync(); } while (await timer.WaitForNextTickAsync(_stop.Token)); }
        catch (OperationCanceledException) { }
    });

    public async Task RefreshAsync()
    {
        if (!await _gate.WaitAsync(0)) return;
        var credentialsVersion = Volatile.Read(ref _credentialsVersion);
        bool IsCurrent() => credentialsVersion == Volatile.Read(ref _credentialsVersion);
        try
        {
            if (!Enabled) { if (IsCurrent()) { lock (_lock) _latest.Clear(); SetStatus("Api.Disabled"); } return; }
            StoredAccount[] accounts;
            lock (_lock) accounts = _accounts.ToArray();
            if (accounts.Length == 0)
            { if (IsCurrent()) { lock (_lock) _latest.Clear(); SetStatus("Api.NotConfigured"); } return; }

            var ok = 0;
            string? lastErrorKey = null;
            object?[] lastErrorArgs = [];
            foreach (var account in accounts)
            {
                if (!IsCurrent()) return;
                var (five, seven, errorKey, errorArgs) = await FetchUsageAsync(account, _stop.Token);
                if (!IsCurrent()) return;
                if (five is null && seven is null)
                {
                    lastErrorKey = errorKey; lastErrorArgs = errorArgs;
                    continue;
                }
                lock (_lock) _latest[account.OrgId] = (five, seven, DateTime.UtcNow);
                ok++;
            }
            if (!IsCurrent()) return;
            if (ok == 0)
            {
                lock (_lock) _latest.Clear();
                SetStatus(lastErrorKey ?? "Api.ConnectFailed", lastErrorArgs);
            }
            else if (ok == accounts.Length) SetStatus("Api.Connected", DateTime.Now);
            else SetStatus("Api.ConnectedPartial", ok, accounts.Length, DateTime.Now);
        }
        catch (Exception e) when (e is TimeoutException or TaskCanceledException or JsonException or InvalidOperationException or System.Runtime.InteropServices.COMException or Microsoft.Web.WebView2.Core.WebView2RuntimeNotFoundException)
        {
            if (!_stop.IsCancellationRequested && IsCurrent()) SetStatus("Api.ConnectError", e.GetType().Name);
        }
        finally
        {
            var credentialsChanged = !IsCurrent();
            _gate.Release();
            Updated?.Invoke();
            if (credentialsChanged && !_stop.IsCancellationRequested) _ = RefreshAsync();
        }
    }

    private async Task<(LimitWindow? Five, LimitWindow? Seven, string? ErrorKey, object?[] ErrorArgs)> FetchUsageAsync(StoredAccount account, CancellationToken token)
    {
        var orgId = account.OrgId;
        if (!Guid.TryParse(orgId, out var org))
        {
            var resolved = await ResolveOrgIdAsync(account.SessionKey, token);
            if (resolved is null || !Guid.TryParse(resolved, out org))
                return (null, null, "Api.OrgIdRequired", []);
            orgId = resolved;
            lock (_lock)
            {
                var index = _accounts.FindIndex(x => string.Equals(x.SessionKey, account.SessionKey, StringComparison.Ordinal));
                if (index >= 0)
                {
                    _accounts[index] = _accounts[index] with { OrgId = orgId };
                    PersistUnlocked();
                }
            }
        }
        // Cloudflare 때문에 일반 HTTP 클라이언트로는 막혀서, 화면 밖 WebView2(Chromium)로 조회한다(UI 스레드 필요)
        var url = $"https://claude.ai/api/organizations/{org}/usage";
        var (code, body) = await Application.Current.Dispatcher.InvokeAsync(() => _web.GetAsync(url, account.SessionKey, token)).Task.Unwrap();
        if (code != 200)
        {
            var (blocked, reason) = ErrorReason(body);
            if (blocked) return (null, null, "Api.Blocked", []);
            if (code is 401 or 403) return (null, null, "Api.AuthFailed", [code, reason]);
            if (code < 0) return (null, null, "Api.ConnectFailed", []);
            return (null, null, "Api.RequestFailed", [code, reason]);
        }
        if (WebViewFetcher.LooksLikeChallenge(body)) return (null, null, "Api.Blocked", []);
        using var json = JsonDocument.Parse(body);
        var five = Window(json.RootElement, "five_hour");
        var seven = Window(json.RootElement, "seven_day");
        if (five is null && seven is null) return (null, null, "Api.NoLimits", []);
        return (five, seven, null, []);
    }

    private async Task<string?> ResolveOrgIdAsync(string key, CancellationToken token)
    {
        var (code, body) = await Application.Current.Dispatcher.InvokeAsync(() => _web.GetAsync("https://claude.ai/api/organizations", key, token)).Task.Unwrap();
        if (code != 200 || WebViewFetcher.LooksLikeChallenge(body)) return null;
        using var json = JsonDocument.Parse(body);
        if (json.RootElement.ValueKind != JsonValueKind.Array) return null;
        foreach (var org in json.RootElement.EnumerateArray())
            if (org.TryGetProperty("uuid", out var uuid) && uuid.ValueKind == JsonValueKind.String && Guid.TryParse(uuid.GetString(), out _))
                return uuid.GetString();
        return null;
    }

    private void LoadAccounts()
    {
        try
        {
            if (!File.Exists(_keyPath)) return;
            var raw = Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(_keyPath), null, DataProtectionScope.CurrentUser));
            if (raw.Length == 0) return;
            if (raw[0] != '{')
            {
                var legacy = Clean(raw);
                if (!string.IsNullOrEmpty(legacy)) _accounts.Add(new StoredAccount("", legacy, null, null));
                return;
            }
            using var doc = JsonDocument.Parse(raw);
            var root = doc.RootElement;
            if (root.TryGetProperty("accounts", out var accounts) && accounts.ValueKind == JsonValueKind.Array)
            {
                foreach (var item in accounts.EnumerateArray())
                {
                    var key = item.TryGetProperty("sessionKey", out var sk) ? Clean(sk.GetString()) : null;
                    var org = item.TryGetProperty("orgId", out var oid) && oid.ValueKind == JsonValueKind.String ? oid.GetString() : null;
                    if (string.IsNullOrEmpty(key) || string.IsNullOrWhiteSpace(org) || !Guid.TryParse(org, out _)) continue;
                    var email = item.TryGetProperty("email", out var em) && em.ValueKind == JsonValueKind.String ? em.GetString() : null;
                    var name = item.TryGetProperty("name", out var nm) && nm.ValueKind == JsonValueKind.String ? nm.GetString() : null;
                    _accounts.Add(new StoredAccount(org!.Trim(), key, string.IsNullOrWhiteSpace(email) ? null : email.Trim(),
                        string.IsNullOrWhiteSpace(name) ? null : name.Trim()));
                }
                return;
            }
            // 구버전 단일 {sessionKey, orgId}
            var singleKey = root.TryGetProperty("sessionKey", out var singleSk) ? Clean(singleSk.GetString()) : null;
            var singleOrg = root.TryGetProperty("orgId", out var singleOid) && singleOid.ValueKind == JsonValueKind.String ? singleOid.GetString() : null;
            if (!string.IsNullOrEmpty(singleKey))
                _accounts.Add(new StoredAccount(string.IsNullOrWhiteSpace(singleOrg) ? "" : singleOrg!.Trim(), singleKey, null, null));
        }
        catch (Exception e) when (e is CryptographicException or IOException or JsonException or UnauthorizedAccessException) { }
    }

    private void PersistUnlocked()
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_keyPath)!);
        if (_accounts.Count == 0) { try { File.Delete(_keyPath); } catch (IOException) { } return; }
        var payload = new Dictionary<string, object>
        {
            ["accounts"] = _accounts.Select(x => new Dictionary<string, string?>
            {
                ["sessionKey"] = x.SessionKey,
                ["orgId"] = x.OrgId,
                ["email"] = x.Email,
                ["name"] = x.Name
            }).ToArray()
        };
        var json = JsonSerializer.Serialize(payload);
        File.WriteAllBytes(_keyPath, ProtectedData.Protect(Encoding.UTF8.GetBytes(json), null, DataProtectionScope.CurrentUser));
    }

    // Cloudflare 챌린지인지와, JSON 오류면 error_code(없으면 message)만 돌려줌. 응답의 다른 내용은 쓰지 않음
    private static (bool Blocked, string Reason) ErrorReason(string body)
    {
        if (WebViewFetcher.LooksLikeChallenge(body)) return (true, "");
        try
        {
            using var json = JsonDocument.Parse(body);
            if (!json.RootElement.TryGetProperty("error", out var error) || error.ValueKind != JsonValueKind.Object) return (false, "");
            var code = error.TryGetProperty("details", out var d) && d.ValueKind == JsonValueKind.Object && d.TryGetProperty("error_code", out var c) ? c.GetString()
                : error.TryGetProperty("message", out var m) ? m.GetString() : null;
            return (false, string.IsNullOrEmpty(code) ? "" : ", " + code);
        }
        catch (JsonException) { return (false, ""); }
    }

    // resets_at이 null이면 진행 중인 창이 없다는 뜻이므로 사용률만 쓰고 리셋 시각은 알 수 없음
    private static LimitWindow? Window(JsonElement root, string name) =>
        root.TryGetProperty(name, out var w) && w.ValueKind == JsonValueKind.Object
        && w.TryGetProperty("utilization", out var used) && used.ValueKind == JsonValueKind.Number
            ? new LimitWindow(used.GetDouble(), w.TryGetProperty("resets_at", out var at) && at.ValueKind == JsonValueKind.String
                && DateTime.TryParse(at.GetString(), System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out var parsed)
                ? parsed.ToUniversalTime() : DateTime.MaxValue) : null;

    public void Dispose() { _stop.Cancel(); _web.Dispose(); }

    private sealed record StoredAccount(string OrgId, string SessionKey, string? Email, string? Name);
}
