using System.Windows;
using System.Windows.Input;

namespace AgentHud;

public partial class SettingsWindow : Window
{
    public SettingsWindow() { InitializeComponent(); MaxHeight = Math.Max(200, SystemParameters.WorkArea.Height - 40); }
    private void Header_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e) => DragMove();
    private void Close_OnClick(object sender, RoutedEventArgs e) => Close();
    private void BrowseSound_OnClick(object sender, RoutedEventArgs e)
    {
        if (DataContext is not MainWindow main || sender is not FrameworkElement { Tag: string slot }) return;
        var dialog = new Microsoft.Win32.OpenFileDialog { Filter = Loc.T("Sound.FileFilter"), Title = Loc.T("Sound.PickTitle") };
        if (dialog.ShowDialog(this) != true) return;
        if (slot == "Complete") { main.CompleteSoundFile = dialog.FileName; main.CompleteSound = SoundSetting.File; }
        else { main.AskSoundFile = dialog.FileName; main.AskSound = SoundSetting.File; }
    }
    private void TestSound_OnClick(object sender, RoutedEventArgs e)
    {
        if (DataContext is not MainWindow main || sender is not FrameworkElement { Tag: string slot }) return;
        if (slot == "Complete") SoundSetting.Play(main.CompleteSound, main.CompleteSoundFile);
        else SoundSetting.Play(main.AskSound, main.AskSoundFile);
    }
    private void ClaudeLogin_OnClick(object sender, RoutedEventArgs e) { if (DataContext is MainWindow main) main.LoginClaude(this); }
    private async void ClaudeRefresh_OnClick(object sender, RoutedEventArgs e)
    {
        if (DataContext is not MainWindow main || sender is not System.Windows.Controls.Button button) return;
        button.IsEnabled = false;
        try { await main.RefreshClaudeAsync(); } finally { button.IsEnabled = true; }
    }
    private void ClaudeLogout_OnClick(object sender, RoutedEventArgs e) { if (DataContext is MainWindow main) main.LogoutClaude(); }
    private void DiscordSave_OnClick(object sender, RoutedEventArgs e)
    {
        if (DataContext is not MainWindow main) return;
        main.SetDiscordWebhook(DiscordBox.Password);
        if (DiscordNotifier.IsValidWebhookUrl(DiscordBox.Password.Trim()) || string.IsNullOrWhiteSpace(DiscordBox.Password)) DiscordBox.Clear();
    }
    private async void DiscordTest_OnClick(object sender, RoutedEventArgs e) { if (DataContext is MainWindow main) await main.TestDiscordAsync(); }
    private void OpenCodeLogin_OnClick(object sender, RoutedEventArgs e) { if (DataContext is MainWindow main) main.LoginOpenCode(this); }
    private async void OpenCodeRefresh_OnClick(object sender, RoutedEventArgs e)
    {
        if (DataContext is not MainWindow main || sender is not System.Windows.Controls.Button button) return;
        button.IsEnabled = false;
        try { await main.RefreshOpenCodeAsync(); } finally { button.IsEnabled = true; }
    }
    private void OpenCodeLogout_OnClick(object sender, RoutedEventArgs e) { if (DataContext is MainWindow main) main.LogoutOpenCode(); }
    private void CursorLogin_OnClick(object sender, RoutedEventArgs e) { if (DataContext is MainWindow main) main.LoginCursor(this); }
    private async void CursorRefresh_OnClick(object sender, RoutedEventArgs e)
    {
        if (DataContext is not MainWindow main || sender is not System.Windows.Controls.Button button) return;
        button.IsEnabled = false;
        try { await main.RefreshCursorAsync(); } finally { button.IsEnabled = true; }
    }
    private void CursorLogout_OnClick(object sender, RoutedEventArgs e) { if (DataContext is MainWindow main) main.LogoutCursor(); }
    private async void CheckUpdate_OnClick(object sender, RoutedEventArgs e)
    {
        if (DataContext is not MainWindow main || sender is not System.Windows.Controls.Button button) return;
        button.IsEnabled = false;
        try { await main.CheckForUpdateAsync(true); } finally { button.IsEnabled = true; }
    }
}
