using System.Windows.Data;
using System.Windows.Markup;

namespace AgentHud;

/// <summary>WPF markup extension backed by the shared localization table.</summary>
[MarkupExtensionReturnType(typeof(object))]
public sealed class TrExtension : MarkupExtension
{
    public TrExtension() { }
    public TrExtension(string key) => Key = key;

    [ConstructorArgument("key")]
    public string Key { get; set; } = "";

    public override object ProvideValue(IServiceProvider serviceProvider)
    {
        return new Binding
        {
            Source = Loc.Instance,
            Path = new PropertyPath($"[{Key}]"),
            Mode = BindingMode.OneWay
        }.ProvideValue(serviceProvider);
    }
}
