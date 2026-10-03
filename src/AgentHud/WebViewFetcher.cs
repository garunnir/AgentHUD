using System.Text.Json;
using System.Text.RegularExpressions;
using System.Windows;
using System.Windows.Interop;
using Microsoft.Web.WebView2.Core;

namespace AgentHud;

// 화면에 띄우지 않는 WebView2(Chromium)로 URL을 열어 본문을 읽는다. Cloudflare가 보는 TLS·HTTP/2 지문이 실제 브라우저와 같아 통과한다.
// sessionKey는 요청 동안만 쿠키로 넣고 끝나면 지운다. UI 스레드에서만 호출해야 한다.
internal sealed partial class WebViewFetcher : IDisposable
{
    private readonly string _userDataFolder;
    // 화면에 한 번도 띄우지 않는 창. 핸들(HWND)만 만들어 WebView2의 부모로 쓴다
    private Window? _host;
    private CoreWebView2Controller? _controller;

    public WebViewFetcher(string userDataFolder) => _userDataFolder = userDataFolder;

    public async Task<(int Status, string Body)> GetAsync(string url, string sessionKey, CancellationToken token)
    {
        await EnsureAsync();
        var core = _controller!.CoreWebView2;
        var cookie = core.CookieManager.CreateCookie("sessionKey", sessionKey, ".claude.ai", "/");
        cookie.IsSecure = true;
        cookie.IsHttpOnly = true;
        core.CookieManager.AddOrUpdateCookie(cookie);
        var done = new TaskCompletionSource<int>(TaskCreationOptions.RunContinuationsAsynchronously);
        void OnCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e) => done.TrySetResult(e.IsSuccess ? e.HttpStatusCode : -1);
        core.NavigationCompleted += OnCompleted;
        try
        {
            core.Navigate(url);
            var status = await done.Task.WaitAsync(TimeSpan.FromSeconds(20), token);
            var body = await ReadBodyAsync(core);
            // Cloudflare 챌린지는 JS가 풀고 나면 스스로 이동하므로 잠깐 기다려 본문이 바뀌는지 본다
            for (var i = 0; i < 16 && ChallengePattern().IsMatch(body); i++)
            {
                await Task.Delay(500, token);
                body = await ReadBodyAsync(core);
                if (!ChallengePattern().IsMatch(body)) status = 200;
            }
            return (status, body);
        }
        finally
        {
            core.NavigationCompleted -= OnCompleted;
            core.CookieManager.DeleteAllCookies();
            core.Navigate("about:blank");
        }
    }

    public static bool LooksLikeChallenge(string body) => ChallengePattern().IsMatch(body);

    private static async Task<string> ReadBodyAsync(CoreWebView2 core) =>
        JsonSerializer.Deserialize<string>(await core.ExecuteScriptAsync("document.documentElement.innerText")) ?? "";

    private async Task EnsureAsync()
    {
        if (_controller is not null) return;
        _host = new Window { Width = 1, Height = 1, WindowStyle = WindowStyle.None, ShowInTaskbar = false };
        var handle = new WindowInteropHelper(_host).EnsureHandle();
        var environment = await CoreWebView2Environment.CreateAsync(userDataFolder: _userDataFolder);
        _controller = await environment.CreateCoreWebView2ControllerAsync(handle);
        _controller.IsVisible = true;
    }

    public void Dispose()
    {
        _controller?.Close();
        _host?.Close();
    }

    [GeneratedRegex("just a moment|challenge-platform|cf-chl|cdn-cgi/challenge|_cf_chl|checking your browser", RegexOptions.IgnoreCase)]
    private static partial Regex ChallengePattern();
}
