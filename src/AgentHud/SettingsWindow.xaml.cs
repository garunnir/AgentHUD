using System.Windows;
using System.Windows.Input;

namespace AgentHud;

public partial class SettingsWindow : Window
{
    public SettingsWindow() => InitializeComponent();
    private void Header_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e) => DragMove();
    private void Close_OnClick(object sender, RoutedEventArgs e) => Close();
    private void SaveKey_OnClick(object sender, RoutedEventArgs e)
    {
        if (DataContext is MainWindow main && !string.IsNullOrWhiteSpace(KeyBox.Password)) main.SetClaudeSessionKey(KeyBox.Password);
        KeyBox.Clear();
    }
    private void DeleteKey_OnClick(object sender, RoutedEventArgs e) { if (DataContext is MainWindow main) main.SetClaudeSessionKey(null); }
}
