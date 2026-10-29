using System.Windows;
using System.Windows.Controls;
using Microsoft.Web.WebView2.Wpf;

namespace AgentHud;

internal sealed class CursorLoginWindow : Window
{
    private readonly WebView2 _web;
    private readonly TextBlock _status;
    private readonly Button _save;
    private readonly CursorUsageApi _api;
    private bool _closed;
    public CursorLoginWindow(CursorUsageApi api, string dataDirectory)
    {
        _api = api; Title = Loc.T("Cursor.LoginTitle"); Width = 800; Height = 650; Topmost = true;
        WindowStartupLocation = WindowStartupLocation.CenterOwner;
        _web = new WebView2 { CreationProperties = new CoreWebView2CreationProperties
        { UserDataFolder = Path.Combine(dataDirectory, "cursor-webview2"), IsInPrivateModeEnabled = true } };
        _status = new TextBlock { Text = Loc.T("Cursor.LoginHint"), TextWrapping = TextWrapping.Wrap, Margin = new Thickness(8), MaxWidth = 570 };
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
            _web.CoreWebView2.Navigate("https://cursor.com/dashboard/spending"); _save.IsEnabled = true;
        }
        catch (Exception e2) when (e2 is InvalidOperationException or System.Runtime.InteropServices.COMException or Microsoft.Web.WebView2.Core.WebView2RuntimeNotFoundException)
        { if (!_closed) _status.Text = Loc.T("Api.ConnectFailed"); }
    }
    private async void Save_OnClick(object sender, RoutedEventArgs e)
    {
        _save.IsEnabled = false;
        try
        {
            var cookies = await _web.CoreWebView2.CookieManager.GetCookiesAsync("https://cursor.com/dashboard/spending");
            if (_closed) return;
            _api.SaveCookies(cookies.Select(c => new CursorUsageApi.ConsoleCookie(c.Name, c.Value, c.Domain, c.Path, c.IsSecure, c.IsSession ? null : c.Expires.ToUniversalTime())));
            Close();
        }
        catch (Exception e2) when (e2 is IOException or UnauthorizedAccessException or System.Security.Cryptography.CryptographicException or InvalidOperationException or System.Runtime.InteropServices.COMException)
        { if (!_closed) { _status.Text = Loc.T("Cursor.LoginRequired"); _save.IsEnabled = true; } }
    }
}
