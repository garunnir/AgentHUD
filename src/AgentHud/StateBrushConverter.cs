using System.Globalization;
using System.Windows.Data;
using System.Windows.Media;
using AgentHud.Models;

namespace AgentHud;

public sealed class StateBrushConverter : IValueConverter
{
    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) => value is AgentState state ? state switch
    {
        AgentState.Working or AgentState.Thinking => Brushes.LimeGreen,
        AgentState.WaitingForInput or AgentState.WaitingForApproval => Brushes.Gold,
        AgentState.Error => Brushes.OrangeRed,
        AgentState.Completed => Brushes.DeepSkyBlue,
        AgentState.Idle or AgentState.Stopped => Brushes.SlateGray,
        AgentState.Starting => Brushes.LimeGreen,
        _ => Brushes.MediumPurple
    } : Brushes.MediumPurple;
    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) => throw new NotSupportedException();
}
