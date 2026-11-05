using System.Text.Json;
using System.Windows;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Wpf;

namespace AgentHud;

internal sealed class ClaudeLoginWindow : Window
{
    private readonly WebView2 _web;
    private readonly TextBlock _status;
    private readonly Button _save;
    private readonly ClaudeUsageApi _api;
    private bool _closed;
    public ClaudeLoginWindow(ClaudeUsageApi api, string dataDirectory)
    {
        _api = api; Title = Loc.T("Claude.LoginTitle"); Width = 800; Height = 650; Topmost = true;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        _web = new WebView2 { CreationProperties = new CoreWebView2CreationProperties
        { UserDataFolder = Path.Combine(dataDirectory, "claude-login-webview2"), IsInPrivateModeEnabled = true } };
        _status = new TextBlock { Text = Loc.T("Claude.LoginHint"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(8), MaxWidth = 570 };
        _save = new Button { Content = Loc.T("Settings.Save"), Margin = new Thickness(8), Padding = new Thickness(12, 4, 12, 4), IsEnabled = false };
        _save.Click += Save_OnClick;
        var footer = new DockPanel(); DockPanel.SetDock(_save, Dock.Right); footer.Children.Add(_save); footer.Children.Add(_status);
        var panel = new DockPanel(); DockPanel.SetDock(footer, Dock.Bottom); panel.Children.Add(footer); panel.Children.Add(_web); Content = panel;
        Loaded += Initialize;
        Closed += (_, _) => { _closed = true; _web.Dispose(); };
    }
    private async void Initialize(object sender, RoutedEventArgs e)
    {
        try
        {
            await _web.EnsureCoreWebView2Async();
            if (_closed) return;
            _web.CoreWebView2.Navigate("https://claude.ai/"); _save.IsEnabled = true;
        }
        catch (Exception e2) when (e2 is InvalidOperationException or System.Runtime.InteropServices.COMException or Microsoft.Web.WebView2.Core.WebView2RuntimeNotFoundException)
        { if (!_closed) _status.Text = Loc.T("Api.ConnectFailed"); }
    }
    private async void Save_OnClick(object sender, RoutedEventArgs e)
    {
        _save.IsEnabled = false;
        try
        {
            var cookies = await _web.CoreWebView2.CookieManager.GetCookiesAsync("https://claude.ai/");
            if (_closed) return;
            var sessionKey = cookies.FirstOrDefault(c => c.Name.Equals("sessionKey", StringComparison.OrdinalIgnoreCase))?.Value;
            if (string.IsNullOrWhiteSpace(sessionKey)) throw new InvalidOperationException("No sessionKey");
            var orgId = cookies.FirstOrDefault(c => c.Name.Equals("lastActiveOrg", StringComparison.OrdinalIgnoreCase))?.Value;
            var (resolvedOrg, email, name) = await FetchAccountAsync(orgId);
            if (_closed) return;
            orgId = resolvedOrg ?? orgId;
            if (!Guid.TryParse(orgId, out _)) throw new InvalidOperationException("No organization");
            _api.SaveLogin(sessionKey, orgId, email, name);
            Close();
        }
        catch (Exception e2) when (e2 is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException or InvalidOperationException or System.Runtime.InteropServices.COMException or JsonException or TimeoutException or TaskCanceledException)
        { if (!_closed) { _status.Text = Loc.T("Claude.LoginRequired"); _save.IsEnabled = true; } }
    }
    // Cookie jar already has the session; same-origin fetch picks the active org + display fields without DevTools copy-paste.
    private async Task<(string? OrgId, string? Email, string? Name)> FetchAccountAsync(string? preferredOrg)
    {
        var raw = await _web.CoreWebView2.ExecuteScriptAsync(
            "(async()=>{try{const [o,a]=await Promise.all([fetch('/api/organizations',{credentials:'include'}),fetch('/api/account',{credentials:'include'}).catch(()=>null)]);const orgs=o.ok?await o.text():'';const acc=a&&a.ok?await a.text():'';return JSON.stringify({orgs,acc})}catch{return ''}})()");
        var wrapped = JsonSerializer.Deserialize<string>(raw) ?? "";
        if (string.IsNullOrWhiteSpace(wrapped)) return (null, null, null);
        using var outer = JsonDocument.Parse(wrapped);
        string? orgId = null, email = null, name = null;
        if (outer.RootElement.TryGetProperty("orgs", out var orgsText) && orgsText.ValueKind == JsonValueKind.String
            && !string.IsNullOrWhiteSpace(orgsText.GetString()))
        {
            using var orgs = JsonDocument.Parse(orgsText.GetString()!);
            if (orgs.RootElement.ValueKind == JsonValueKind.Array)
            {
                foreach (var org in orgs.RootElement.EnumerateArray())
                {
                    if (!org.TryGetProperty("uuid", out var uuid) || uuid.ValueKind != JsonValueKind.String
                        || !Guid.TryParse(uuid.GetString(), out _)) continue;
                    var id = uuid.GetString();
                    if (orgId is null || (preferredOrg is not null && string.Equals(id, preferredOrg, StringComparison.OrdinalIgnoreCase)))
                    {
                        orgId = id;
                        if (org.TryGetProperty("name", out var orgName) && orgName.ValueKind == JsonValueKind.String)
                            name = orgName.GetString();
                        if (preferredOrg is not null && string.Equals(id, preferredOrg, StringComparison.OrdinalIgnoreCase))
                            break;
                    }
                }
            }
        }
        if (outer.RootElement.TryGetProperty("acc", out var accText) && accText.ValueKind == JsonValueKind.String
            && !string.IsNullOrWhiteSpace(accText.GetString()))
        {
            try
            {
                using var acc = JsonDocument.Parse(accText.GetString()!);
                var root = acc.RootElement;
                if (root.TryGetProperty("email", out var em) && em.ValueKind == JsonValueKind.String) email = em.GetString();
                else if (root.TryGetProperty("email_address", out em) && em.ValueKind == JsonValueKind.String) email = em.GetString();
                if (root.TryGetProperty("display_name", out var dn) && dn.ValueKind == JsonValueKind.String) name ??= dn.GetString();
                else if (root.TryGetProperty("name", out dn) && dn.ValueKind == JsonValueKind.String) name ??= dn.GetString();
            }
            catch (JsonException) { }
        }
        return (orgId ?? (Guid.TryParse(preferredOrg, out _) ? preferredOrg : null), email, name);
    }
}
