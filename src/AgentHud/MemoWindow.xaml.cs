using System.Windows;
using System.Windows.Input;

namespace AgentHud;

public partial class MemoWindow : Window
{
    private readonly Action<string> _save;

    public MemoWindow(string header, string text, Action<string> save)
    {
        InitializeComponent();
        _save = save;
        HeaderText.Text = header;
        Editor.Text = text;
        // 포커스를 잃거나 닫힐 때 저장
        Deactivated += (_, _) => _save(Editor.Text);
        Closing += (_, _) => _save(Editor.Text);
        Loaded += (_, _) => { Editor.Focus(); Editor.CaretIndex = Editor.Text.Length; };
    }
    private void Header_OnMouseLeftButtonDown(object sender, MouseButtonEventArgs e) => DragMove();
    private void Close_OnClick(object sender, RoutedEventArgs e) => Close();
}
