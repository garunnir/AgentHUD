using System.Globalization;
using System.Windows;
using System.Windows.Data;

namespace AgentHud;

/// <summary>[ProjectPath, MemoStore, 변경 카운터] → 메모 아이콘 Visibility (ConverterParameter="Text"면 메모 본문)</summary>
public sealed class ProjectMemoConverter : IMultiValueConverter
{
    public object? Convert(object[] values, Type targetType, object parameter, CultureInfo culture)
    {
        var memo = values is [string path, MemoStore store, ..] ? store.GetProject(path) : null;
        return parameter as string == "Text" ? memo : memo is null ? Visibility.Collapsed : Visibility.Visible;
    }
    public object[] ConvertBack(object value, Type[] targetTypes, object parameter, CultureInfo culture) => throw new NotSupportedException();
}
