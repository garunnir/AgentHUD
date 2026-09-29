using System.Windows;
using System.Windows.Input;

namespace AgentHud;

// 포커스를 빼앗지 않는 HUD 스타일 알림. 본문 클릭 시 동작 실행 후 닫힘
public partial class NotificationWindow : Window
{
    private readonly Action? _open;

    public NotificationWindow(string header, string body, Action? open)
    {
        InitializeComponent();
        HeaderText.Text = header;
        BodyText.Text = body;
        _open = open;
    }
    private void Body_OnMouseLeftButtonUp(object sender, MouseButtonEventArgs e) { _open?.Invoke(); Close(); }
    private void Close_OnClick(object sender, RoutedEventArgs e) { e.Handled = true; Close(); }
}
