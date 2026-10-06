using System.ComponentModel;
using System.Globalization;
using System.Windows.Data;
using System.Windows.Markup;

namespace AgentHud;

public sealed record LanguageOption(string Code, string Name);

/// <summary>
/// Strings.tsv(키 + 언어 코드별 열) 로컬라이징 테이블. 시스템 UI 언어 → 대체 언어 → 영어 → 키 순으로 찾는다.
/// 대체 언어가 바뀌면 인덱서 바인딩({local:Tr})이 갱신된다.
/// </summary>
public sealed class Loc : INotifyPropertyChanged
{
    public const string English = "en";
    public static Loc Instance { get; } = new(CultureInfo.CurrentUICulture);
    public static string T(string key) => Instance[key];
    public static string F(string key, params object?[] args) => string.Format(CultureInfo.CurrentCulture, Instance[key], args);

    private readonly Dictionary<string, Dictionary<string, string>> _table;
    private readonly string? _systemLanguage;
    private readonly CultureInfo _systemCulture;
    private string _fallback = English;
    public event PropertyChangedEventHandler? PropertyChanged;

    public Loc(CultureInfo systemCulture, TextReader? table = null)
    {
        _systemCulture = systemCulture;
        if (table is null)
        {
            using var stream = typeof(Loc).Assembly.GetManifestResourceStream("AgentHud.Strings.tsv")!;
            using var reader = new StreamReader(stream);
            (Languages, _table) = Parse(reader);
        }
        else (Languages, _table) = Parse(table);
        // ko-KR → ko 처럼 상위 문화권으로 올라가며 테이블에 있는 언어를 찾음
        for (var c = systemCulture; !string.IsNullOrEmpty(c.Name); c = c.Parent)
            if (Languages.FirstOrDefault(x => x.Code.Equals(c.Name, StringComparison.OrdinalIgnoreCase)) is { } match) { _systemLanguage = match.Code; break; }
    }

    public IReadOnlyList<LanguageOption> Languages { get; }
    /// <summary>시스템 언어가 테이블에 없을 때, 또는 해당 언어에 빠진 문구가 있을 때 쓰는 언어</summary>
    public string Fallback
    {
        get => _fallback;
        set
        {
            value = Languages.FirstOrDefault(x => x.Code.Equals(value, StringComparison.OrdinalIgnoreCase))?.Code ?? English;
            if (_fallback == value) return;
            _fallback = value;
            PropertyChanged?.Invoke(this, new(nameof(Fallback)));
            PropertyChanged?.Invoke(this, new(nameof(LanguageHint)));
            PropertyChanged?.Invoke(this, new(Binding.IndexerName));
        }
    }
    public string LanguageHint => F("Settings.LanguageHint", _systemCulture.NativeName, _systemLanguage is null ? T("Settings.LanguageMissing") : _table["Language.Name"][_systemLanguage]);

    public string this[string key]
    {
        get
        {
            if (!_table.TryGetValue(key, out var row)) return key;
            return (_systemLanguage is not null && row.TryGetValue(_systemLanguage, out var text)) || row.TryGetValue(_fallback, out text) || row.TryGetValue(English, out text) ? text : key;
        }
    }

    // 첫 줄(# 주석·빈 줄 제외)이 헤더: key<TAB>en<TAB>ko...  빈 칸은 번역 없음. \n \t \\ 이스케이프 지원
    private static (IReadOnlyList<LanguageOption>, Dictionary<string, Dictionary<string, string>>) Parse(TextReader reader)
    {
        string[]? header = null;
        var table = new Dictionary<string, Dictionary<string, string>>(StringComparer.Ordinal);
        while (reader.ReadLine() is { } line)
        {
            if (string.IsNullOrWhiteSpace(line) || line.StartsWith('#')) continue;
            var cells = line.Split('\t');
            if (header is null) { header = cells; continue; }
            var row = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            for (var i = 1; i < cells.Length && i < header.Length; i++)
                if (cells[i].Length > 0) row[header[i]] = Unescape(cells[i]);
            table[cells[0]] = row;
        }
        var codes = header?.Skip(1).ToArray() ?? [];
        var names = table.GetValueOrDefault("Language.Name");
        return (codes.Select(c => new LanguageOption(c, names?.GetValueOrDefault(c) ?? c)).ToArray(), table);
    }
    private static string Unescape(string s) => s.Contains('\\') ? s.Replace("\\\\", "\0").Replace("\\n", "\n").Replace("\\t", "\t").Replace("\0", "\\") : s;
}

/// <summary>XAML용: Text="{local:Tr Settings.Title}" — 언어가 바뀌면 자동 갱신</summary>
[MarkupExtensionReturnType(typeof(object))]
public sealed class TrExtension : MarkupExtension
{
    public TrExtension() { }
    public TrExtension(string key) => Key = key;
    [ConstructorArgument("key")] public string Key { get; set; } = "";
    public override object ProvideValue(IServiceProvider serviceProvider) =>
        new Binding($"[{Key}]") { Source = Loc.Instance, Mode = BindingMode.OneWay }.ProvideValue(serviceProvider);
}
