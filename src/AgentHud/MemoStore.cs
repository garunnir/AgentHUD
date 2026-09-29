using System.Text.Json;

namespace AgentHud;

/// <summary>전역 메모 하나와 프로젝트(Git 루트 또는 cwd)별 메모를 JSON 파일 하나에 보관</summary>
public sealed class MemoStore(string path)
{
    private MemoData _data = Load(path);
    public string Global => _data.Global;
    public event EventHandler? Changed;

    public string? GetProject(string? projectPath) => Key(projectPath) is { } key && _data.Projects.TryGetValue(key, out var text) ? text : null;
    public bool HasProject(string? projectPath) => GetProject(projectPath) is not null;

    public void SetGlobal(string text)
    {
        if (_data.Global == text) return;
        _data = _data with { Global = text };
        Save();
    }

    public void SetProject(string projectPath, string text)
    {
        if (Key(projectPath) is not { } key || GetProject(projectPath) == NullIfBlank(text)) return;
        if (NullIfBlank(text) is null) _data.Projects.Remove(key); else _data.Projects[key] = text;
        Save();
    }

    private static string? Key(string? projectPath)
    {
        if (string.IsNullOrWhiteSpace(projectPath)) return null;
        try { return Path.GetFullPath(projectPath).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar); }
        catch { return null; }
    }
    private static string? NullIfBlank(string text) => string.IsNullOrWhiteSpace(text) ? null : text;

    private static MemoData Load(string path)
    {
        try
        {
            if (File.Exists(path) && JsonSerializer.Deserialize<MemoData>(File.ReadAllText(path)) is { } d)
                return new(d.Global ?? "", new(d.Projects ?? [], StringComparer.OrdinalIgnoreCase));
        }
        catch { }
        return new("", new(StringComparer.OrdinalIgnoreCase));
    }
    private void Save()
    {
        try { Directory.CreateDirectory(Path.GetDirectoryName(path)!); File.WriteAllText(path, JsonSerializer.Serialize(_data, new JsonSerializerOptions { WriteIndented = true })); } catch { }
        Changed?.Invoke(this, EventArgs.Empty);
    }
    private sealed record MemoData(string Global, Dictionary<string, string> Projects);
}
