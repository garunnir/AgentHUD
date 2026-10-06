using System.ComponentModel;
using System.Globalization;
using System.Windows.Data;
using System.Windows.Markup;

namespace AgentHud;

public sealed record LanguageOption(string Code, string Name);

/// <summary>
/// Strings.tsv(키 + 언어 코드별 열) 로컬라이징 테이블. 선택한 언어(자동이면 시스템 UI 언어) → 영어 → 키 순으로 찾는다.
/// 언어가 바뀌면 인덱서 바인딩({local:Tr})이 갱신된다.
/// </summary>
public sealed class Loc : INotifyPropertyChanged
{
    public const string English = "en";
    /// <summary>언어 목록에서 "시스템 언어 따르기"를 뜻하는 코드</summary>
    public const string Auto = "";
    public static Loc Instance { get; } = new(CultureInfo.CurrentUICulture);
    public static string T(string key) => Instance[key];
    public static string F(string key, params object?[] args) => string.Format(CultureInfo.CurrentCulture, Instance[key], args);

    private readonly Dictionary<string, Dictionary<string, string>> _table;
    private readonly string? _systemLanguage;
    private readonly CultureInfo _systemCulture;
    private string _language = Auto;
    private IReadOnlyList<LanguageOption>? _choices;
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
    /// <summary>설정 목록: 맨 앞이 "시스템 언어", 그 뒤로 테이블의 언어</summary>
    public IReadOnlyList<LanguageOption> LanguageChoices => _choices ??= [new(Auto, F("Settings.LanguageAuto", _systemLanguage is null ? T("Settings.LanguageMissing") : LanguageName(_systemLanguage))), .. Languages];
    /// <summary>사용자가 고른 언어 코드. Auto면 시스템 언어(테이블에 없으면 영어)</summary>
    public string Language
    {
        get => _language;
        set
        {
            value = Languages.FirstOrDefault(x => x.Code.Equals(value, StringComparison.OrdinalIgnoreCase))?.Code ?? Auto;
            if (_language == value) return;
            _language = value;
            PropertyChanged?.Invoke(this, new(nameof(Language)));
            PropertyChanged?.Invoke(this, new(Binding.IndexerName));
        }
    }
    private string Effective => _language.Length > 0 ? _language : _systemLanguage ?? English;
    private string LanguageName(string code) => _table.GetValueOrDefault("Language.Name")?.GetValueOrDefault(code) ?? code;

    public string this[string key]
    {
        get
        {
            if (!_table.TryGetValue(key, out var row)) return key;
            return row.TryGetValue(Effective, out var text) || row.TryGetValue(English, out text) ? text : key;
        }
    }

    /// <summary>text가 key의 어느 언어 번역과 같은지(저장된 기본 문구를 언어와 무관하게 알아보기 위함)</summary>
    public bool IsTranslationOf(string key, string text) => _table.TryGetValue(key, out var row) && row.Values.Any(x => x == text.Trim());

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
