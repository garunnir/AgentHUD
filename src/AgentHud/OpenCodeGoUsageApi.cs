using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text.Json;

namespace AgentHud;

// Windows-only credentials and polling. The macOS Keychain implementation stays independent.
public sealed class OpenCodeGoUsageApi : IDisposable
{
    private static readonly Uri Endpoint = new("https://opencode.ai/console/api/go/status");
    private readonly string _cookiePath;
    private readonly CancellationTokenSource _stop = new();
    private readonly SemaphoreSlim _gate = new(1, 1);
    private string _workspaceId = "";
    private int _revision;
    private (string Key, object?[] Args) _status = ("Go.NotConfigured", []);
    public OpenCodeGoUsage? Latest { get; private set; }
    public string Status => Loc.F(_status.Key, _status.Args);
    public event Action? Updated;
    public OpenCodeGoUsageApi(string directory) => _cookiePath = Path.Combine(directory, "opencode-console.bin");
    public string WorkspaceId
    {
        get => _workspaceId;
        set
        {
            value = value.Trim();
            if (_workspaceId == value) return;
            _workspaceId = value; Interlocked.Increment(ref _revision); Latest = null;
            _ = RefreshAsync(); Updated?.Invoke();
        }
    }
    public sealed record ConsoleCookie(string Name, string Value, string Domain, string Path, bool Secure, DateTime? Expires);
    public void SaveCookies(IEnumerable<ConsoleCookie> cookies)
    {
        var selected = cookies.Where(c => c.Domain.TrimStart('.').Equals("opencode.ai", StringComparison.OrdinalIgnoreCase)
            || c.Domain.EndsWith(".opencode.ai", StringComparison.OrdinalIgnoreCase)).ToArray();
        if (selected.Length == 0) throw new InvalidOperationException("No Console cookies");
        Directory.CreateDirectory(Path.GetDirectoryName(_cookiePath)!);
        File.WriteAllBytes(_cookiePath, ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(selected), null, DataProtectionScope.CurrentUser));
        Interlocked.Increment(ref _revision); Latest = null; _ = RefreshAsync(); Updated?.Invoke();
    }
    public void ClearCookies()
    {
        File.Delete(_cookiePath); Interlocked.Increment(ref _revision); Latest = null;
        _status = ("Go.NotConfigured", []); Updated?.Invoke();
    }
    public void Start() => _ = Task.Run(async () =>
    {
        using var timer = new PeriodicTimer(TimeSpan.FromMinutes(5));
        try { do { await RefreshAsync(); } while (await timer.WaitForNextTickAsync(_stop.Token)); }
        catch (OperationCanceledException) when (_stop.IsCancellationRequested) { }
    });
    public async Task RefreshAsync()
    {
        if (_stop.IsCancellationRequested) return;
        await _gate.WaitAsync();
        var revision = Volatile.Read(ref _revision);
        var workspace = _workspaceId;
        var status = (Key: "Go.NotConfigured", Args: Array.Empty<object?>());
        OpenCodeGoUsage? latest = null;
        try
        {
            if (string.IsNullOrWhiteSpace(workspace)) { status.Key = "Go.WorkspaceRequired"; return; }
            if (workspace.Length > 200 || workspace.Any(c => !char.IsAsciiLetterOrDigit(c) && c is not ('_' or '-')))
            { status.Key = "Go.WorkspaceInvalid"; return; }
            if (!File.Exists(_cookiePath)) return;
            var cookies = JsonSerializer.Deserialize<ConsoleCookie[]>(ProtectedData.Unprotect(File.ReadAllBytes(_cookiePath), null, DataProtectionScope.CurrentUser));
            var jar = new CookieContainer();
            foreach (var cookie in cookies ?? [])
            {
                if (cookie.Expires is { } expiry && expiry <= DateTime.UtcNow) continue;
                jar.Add(new Cookie(cookie.Name, cookie.Value, cookie.Path, cookie.Domain) { Secure = cookie.Secure, Expires = cookie.Expires ?? DateTime.MinValue });
            }
            if (jar.GetCookies(Endpoint).Count == 0) { status.Key = "Go.LoginRequired"; return; }
            using var handler = new HttpClientHandler { CookieContainer = jar, AllowAutoRedirect = false };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) };
            using var request = new HttpRequestMessage(HttpMethod.Get, Endpoint);
            request.Headers.Add("x-org-id", workspace); request.Headers.Accept.ParseAdd("application/json");
            using var response = await client.SendAsync(request, _stop.Token);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden || (int)response.StatusCode is >= 300 and < 400)
            { status.Key = "Go.LoginRequired"; return; }
            if (!response.IsSuccessStatusCode) { status = ("Go.HttpError", [(int)response.StatusCode]); return; }
            latest = OpenCodeGoUsage.Parse(await response.Content.ReadAsStringAsync(_stop.Token), DateTime.UtcNow);
            status = ("Api.Connected", [DateTime.Now]);
        }
        catch (Exception e) when (e is JsonException or FormatException or KeyNotFoundException or InvalidOperationException)
        { status.Key = "Go.BadResponse"; }
        catch (Exception e) when (e is CryptographicException or IOException or UnauthorizedAccessException or CookieException)
        { status.Key = "Go.LoginRequired"; }
        catch (Exception e) when (e is HttpRequestException or OperationCanceledException)
        { status.Key = "Api.ConnectFailed"; }
        finally
        {
            if (revision == Volatile.Read(ref _revision) && !_stop.IsCancellationRequested)
            { Latest = latest; _status = status; Updated?.Invoke(); }
            _gate.Release();
        }
    }
    public void Dispose() => _stop.Cancel();
}
