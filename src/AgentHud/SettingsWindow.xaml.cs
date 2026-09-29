using System.Windows;
using System.Windows.Input;

namespace AgentHud;

public partial class SettingsWindow : Window
{
    public SettingsWindow() => InitializeComponent();
    private void Header_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e) => DragMove();
    private void Close_OnClick(object sender, RoutedEventArgs e) => Close();
}
