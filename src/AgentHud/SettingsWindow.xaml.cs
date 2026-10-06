using System.Windows;
using System.Windows.Input;

namespace AgentHud;

public partial class SettingsWindow : Window
{
    public SettingsWindow() => InitializeComponent();
    private void Header_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e) => DragMove();
    private void Close_OnClick(object sender, RoutedEventArgs e) => Close();
    private void BrowseSound_OnClick(object sender, RoutedEventArgs e)
    {
        if (DataContext is not MainWindow main || sender is not FrameworkElement { Tag: string slot }) return;
        var dialog = new Microsoft.Win32.OpenFileDialog { Filter = "오디오 파일|*.wav;*.mp3;*.wma;*.m4a|모든 파일|*.*", Title = "사운드 파일 선택" };
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
    private void SaveKey_OnClick(object sender, RoutedEventArgs e)
    {
        if (DataContext is MainWindow main && !string.IsNullOrWhiteSpace(KeyBox.Password)) main.SetClaudeSessionKey(KeyBox.Password);
        KeyBox.Clear();
    }
    private void DeleteKey_OnClick(object sender, RoutedEventArgs e) { if (DataContext is MainWindow main) main.SetClaudeSessionKey(null); }
}
