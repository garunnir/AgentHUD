using System.Windows;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using AgentHud.Models;

namespace AgentHud;

// claude.ai 사용량 API(비공식). sessionKey(+org)는 Windows DPAPI로 암호화 저장하고, 로그·화면에는 남기지 않는다.
// 설정은 Cursor/OpenCode와 같이 WebView 로그인으로 받고, 주기 조회는 화면 밖 WebView2로 Cloudflare를 통과한다.
public sealed class ClaudeUsageApi : IDisposable
{
    private static readonly TimeSpan Interval = TimeSpan.FromMinutes(5);
    private readonly string _keyPath;
    private readonly WebViewFetcher _web;
    private readonly CancellationTokenSource _stop = new();
    private readonly SemaphoreSlim _gate = new(1, 1);
    private string? _orgId;
    private int _credentialsVersion;
    private (LimitWindow? FiveHour, LimitWindow? SevenDay, DateTime At) _latest;
    // 언어가 바뀌어도 다시 그릴 수 있게 테이블 키와 인자로 보관
    private (string Key, object?[] Args) _status = ("Api.NotConfigured", []);
    public string Status => Loc.F(_status.Key, _status.Args);
    private void SetStatus(string key, params object?[] args) => _status = (key, args);
    public event Action? Updated;

    public ClaudeUsageApi(string dataDirectory)
    {
        _keyPath = Path.Combine(dataDirectory, "claude-session.bin");
        _web = new WebViewFetcher(Path.Combine(dataDirectory, "webview2"));
    }

    public bool HasKey => File.Exists(_keyPath);
    public bool IsConfigured => Enabled && HasKey && _orgId is not null;
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
            if (!value) { _latest = default; SetStatus("Api.Disabled"); Updated?.Invoke(); }
            else _ = RefreshAsync();
        }
    }
    public string? OrgId
    {
        get => _orgId;
        set
        {
            value = string.IsNullOrWhiteSpace(value) ? null : value.Trim();
            if (_orgId == value) return;
            _orgId = value;
            Interlocked.Increment(ref _credentialsVersion);
            _latest = default;
            if (HasKey && TryReadCredentials() is { Key: { Length: > 0 } key })
                TryWriteCredentials(key, _orgId);
            Updated?.Invoke();
            _ = RefreshAsync();
        }
    }
    public (LimitWindow? FiveHour, LimitWindow? SevenDay, DateTime At) Latest => _latest;
    public ClaudeLimitSnapshot Snapshot => _latest.FiveHour is null && _latest.SevenDay is null
        ? ClaudeLimitSnapshot.None : new(ClaudeLimitSource.UsageApi, _latest.FiveHour, _latest.SevenDay, _latest.At);

    public void SaveLogin(string sessionKey, string orgId)
    {
        sessionKey = Clean(sessionKey) ?? throw new InvalidOperationException("No sessionKey");
        orgId = orgId.Trim();
        if (!Guid.TryParse(orgId, out _)) throw new InvalidOperationException("Invalid org");
        Interlocked.Increment(ref _credentialsVersion);
        TryWriteCredentials(sessionKey, orgId);
        _orgId = orgId;
        _latest = default;
        Updated?.Invoke();
        _ = RefreshAsync();
    }

    public void ClearLogin()
    {
        Interlocked.Increment(ref _credentialsVersion);
        try { File.Delete(_keyPath); } catch (IOException) { }
        _orgId = null; _latest = default; SetStatus("Api.NotConfigured"); Updated?.Invoke();
    }

    // 구버전: 평문 sessionKey만 저장된 파일 / 수동 붙여넣기 호환
    public void SetKey(string? key)
    {
        key = Clean(key);
        Interlocked.Increment(ref _credentialsVersion);
        if (string.IsNullOrEmpty(key)) { try { File.Delete(_keyPath); } catch (IOException) { } _latest = default; SetStatus("Api.NotConfigured"); Updated?.Invoke(); return; }
        TryWriteCredentials(key, _orgId);
        _latest = default;
        Updated?.Invoke();
        _ = RefreshAsync();
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
            if (!Enabled) { if (IsCurrent()) { _latest = default; SetStatus("Api.Disabled"); } return; }
            if (TryReadCredentials() is not { Key: { Length: > 0 } key } creds)
            { if (IsCurrent()) { _latest = default; SetStatus("Api.NotConfigured"); } return; }
            var orgId = _orgId ?? creds.OrgId;
            if (orgId is null || !Guid.TryParse(orgId, out var org))
            {
                orgId = await ResolveOrgIdAsync(key, _stop.Token);
                if (!IsCurrent()) return;
                if (orgId is null || !Guid.TryParse(orgId, out org))
                { _latest = default; SetStatus(HasKey ? "Api.OrgIdRequired" : "Api.NotConfigured"); return; }
                _orgId = orgId;
                TryWriteCredentials(key, orgId);
            }
            else _orgId ??= orgId;
            // Cloudflare 때문에 일반 HTTP 클라이언트로는 막혀서, 화면 밖 WebView2(Chromium)로 조회한다(UI 스레드 필요)
            var url = $"https://claude.ai/api/organizations/{org}/usage";
            var (code, body) = await Application.Current.Dispatcher.InvokeAsync(() => _web.GetAsync(url, key, _stop.Token)).Task.Unwrap();
            if (code != 200)
            {
                if (!IsCurrent()) return;
                var (blocked, reason) = ErrorReason(body);
                if (blocked) SetStatus("Api.Blocked");
                else if (code is 401 or 403) { _latest = default; SetStatus("Api.AuthFailed", code, reason); }
                else if (code < 0) SetStatus("Api.ConnectFailed");
                else SetStatus("Api.RequestFailed", code, reason);
                return;
            }
            if (!IsCurrent()) return;
            if (WebViewFetcher.LooksLikeChallenge(body)) { SetStatus("Api.Blocked"); return; }
            using var json = JsonDocument.Parse(body);
            var five = Window(json.RootElement, "five_hour");
            var seven = Window(json.RootElement, "seven_day");
            if (five is null && seven is null) { _latest = default; SetStatus("Api.NoLimits"); return; }
            _latest = (five, seven, DateTime.UtcNow);
            SetStatus("Api.Connected", DateTime.Now);
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

    private (string Key, string? OrgId)? TryReadCredentials()
    {
        try
        {
            var raw = Encoding.UTF8.GetString(ProtectedData.Unprotect(File.ReadAllBytes(_keyPath), null, DataProtectionScope.CurrentUser));
            if (raw.Length > 0 && raw[0] == '{')
            {
                using var doc = JsonDocument.Parse(raw);
                var key = doc.RootElement.TryGetProperty("sessionKey", out var sk) ? Clean(sk.GetString()) : null;
                var org = doc.RootElement.TryGetProperty("orgId", out var oid) && oid.ValueKind == JsonValueKind.String ? oid.GetString() : null;
                return string.IsNullOrEmpty(key) ? null : (key, string.IsNullOrWhiteSpace(org) ? null : org.Trim());
            }
            var legacy = Clean(raw);
            return string.IsNullOrEmpty(legacy) ? null : (legacy, null);
        }
        catch (Exception e) when (e is CryptographicException or IOException or JsonException or UnauthorizedAccessException)
        { return null; }
    }

    private void TryWriteCredentials(string sessionKey, string? orgId)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_keyPath)!);
        var json = JsonSerializer.Serialize(new Dictionary<string, string?> { ["sessionKey"] = sessionKey, ["orgId"] = orgId });
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
}
