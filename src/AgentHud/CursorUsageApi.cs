using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace AgentHud;

// Windows-only credentials and polling. Unofficial dashboard API; needs Origin/Referer + WorkosCursorSessionToken.
public sealed class CursorUsageApi : IDisposable
{
    private static readonly Uri Endpoint = new("https://cursor.com/api/dashboard/get-current-period-usage");
    private readonly string _cookiePath;
    private readonly CancellationTokenSource _stop = new();
    private readonly SemaphoreSlim _gate = new(1, 1);
    private int _revision;
    private (string Key, object?[] Args) _status = ("Cursor.NotConfigured", []);
    public CursorUsage? Latest { get; private set; }
    public bool HasCookies => File.Exists(_cookiePath);
    public string Status => Loc.F(_status.Key, _status.Args);
    public event Action? Updated;
    public CursorUsageApi(string directory) => _cookiePath = Path.Combine(directory, "cursor-session.bin");
    public sealed record ConsoleCookie(string Name, string Value, string Domain, string Path, bool Secure, DateTime? Expires);
    public void SaveCookies(IEnumerable<ConsoleCookie> cookies)
    {
        var selected = cookies.Where(c =>
        {
            var domain = c.Domain.TrimStart('.');
            return domain.Equals("cursor.com", StringComparison.OrdinalIgnoreCase)
                || domain.EndsWith(".cursor.com", StringComparison.OrdinalIgnoreCase);
        }).ToArray();
        if (selected.Length == 0 || selected.All(c => !c.Name.Equals("WorkosCursorSessionToken", StringComparison.OrdinalIgnoreCase)))
            throw new InvalidOperationException("No Cursor session cookie");
        Directory.CreateDirectory(Path.GetDirectoryName(_cookiePath)!);
        File.WriteAllBytes(_cookiePath, ProtectedData.Protect(JsonSerializer.SerializeToUtf8Bytes(selected), null, DataProtectionScope.CurrentUser));
        Interlocked.Increment(ref _revision); Latest = null; _ = RefreshAsync(); Updated?.Invoke();
    }
    public void ClearCookies()
    {
        File.Delete(_cookiePath); Interlocked.Increment(ref _revision); Latest = null;
        _status = ("Cursor.NotConfigured", []); Updated?.Invoke();
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
        var status = (Key: "Cursor.NotConfigured", Args: Array.Empty<object?>());
        CursorUsage? latest = null;
        try
        {
            if (!File.Exists(_cookiePath)) return;
            var cookies = JsonSerializer.Deserialize<ConsoleCookie[]>(ProtectedData.Unprotect(File.ReadAllBytes(_cookiePath), null, DataProtectionScope.CurrentUser));
            var jar = new CookieContainer();
            foreach (var cookie in cookies ?? [])
            {
                if (cookie.Expires is { } expiry && expiry <= DateTime.UtcNow) continue;
                jar.Add(new Cookie(cookie.Name, cookie.Value, cookie.Path, cookie.Domain) { Secure = cookie.Secure, Expires = cookie.Expires ?? DateTime.MinValue });
            }
            if (jar.GetCookies(Endpoint).Cast<Cookie>().All(c => c.Name != "WorkosCursorSessionToken"))
            { status.Key = "Cursor.LoginRequired"; return; }
            using var handler = new HttpClientHandler { CookieContainer = jar, AllowAutoRedirect = false };
            using var client = new HttpClient(handler) { Timeout = TimeSpan.FromSeconds(15) };
            using var request = new HttpRequestMessage(HttpMethod.Post, Endpoint)
            { Content = new StringContent("{}", Encoding.UTF8, "application/json") };
            request.Headers.TryAddWithoutValidation("Origin", "https://cursor.com");
            request.Headers.TryAddWithoutValidation("Referer", "https://cursor.com/dashboard/spending");
            request.Headers.Accept.ParseAdd("application/json");
            using var response = await client.SendAsync(request, _stop.Token);
            if (response.StatusCode is HttpStatusCode.Unauthorized or HttpStatusCode.Forbidden || (int)response.StatusCode is >= 300 and < 400)
            { status.Key = "Cursor.LoginRequired"; return; }
            if (!response.IsSuccessStatusCode) { status = ("Cursor.HttpError", [(int)response.StatusCode]); return; }
            latest = CursorUsage.Parse(await response.Content.ReadAsStringAsync(_stop.Token), DateTime.UtcNow);
            status = ("Api.Connected", [DateTime.Now]);
        }
        catch (Exception e) when (e is JsonException or FormatException or KeyNotFoundException or InvalidOperationException)
        { status.Key = "Cursor.BadResponse"; }
        catch (Exception e) when (e is CryptographicException or IOException or UnauthorizedAccessException or CookieException)
        { status.Key = "Cursor.LoginRequired"; }
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
