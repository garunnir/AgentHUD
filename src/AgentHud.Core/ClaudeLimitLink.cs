using System.Text.Json;
using System.Text.Json.Nodes;
using AgentHud.Models;

namespace AgentHud;

// Claude Code의 statusLine 스크립트가 stdin으로 받는 rate_limits(서버 기준 5시간·주간 한도)를
// 파일로 떨궈 HUD가 읽게 한다. 기존 statusLine이 있으면 그대로 이어서 실행(체이닝)하고, 해제하면 복원한다.
// 설정 루트(~/.claude, CLAUDE_CONFIG_DIR, aisw 프로필) 하나당 인스턴스 하나 - 스크립트가 자기 폴더에 한도를 쓰므로
// 루트마다 출력 폴더를 따로 둬 계정끼리 값이 섞이지 않는다. 비공식 claude.ai API 없이 공식 CLI 값만 쓰는 경로.
public sealed class ClaudeLimitLink
{
    private const string ScriptName = "claude-statusline.ps1";
    private const string LimitsName = "claude-limits.json";
    private const string InnerName = "claude-statusline-inner.txt";
    private readonly string _dir;
    private readonly string _settingsPath;
    private (long Length, DateTime Modified, ClaudeLimitSnapshot Snapshot)? _cached;

    public ClaudeLimitLink(string home, string dataDirectory) : this(ClaudeConfigRoot.Default(home), dataDirectory) { }
    public ClaudeLimitLink(ClaudeConfigRoot root, string dataDirectory)
    {
        ConfigDir = Path.GetFullPath(root.ConfigDir);
        _dir = DataDirectoryFor(root, dataDirectory);
        _settingsPath = Path.Combine(root.ConfigDir, "settings.json");
    }

    public string ConfigDir { get; }
    // 기본 루트는 기존 위치(%LOCALAPPDATA%\AgentHud) 그대로, 다른 루트는 claude-roots\<이름>-<경로 해시>
    public static string DataDirectoryFor(ClaudeConfigRoot root, string dataDirectory)
    {
        if (root.IsDefault) return dataDirectory;
        var full = Path.GetFullPath(root.ConfigDir).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var hash = Convert.ToHexString(System.Security.Cryptography.SHA256.HashData(System.Text.Encoding.UTF8.GetBytes(full.ToLowerInvariant())))[..8].ToLowerInvariant();
        var name = new string(Path.GetFileName(full).Select(c => char.IsLetterOrDigit(c) || c is '-' or '_' ? c : '_').ToArray()).Trim('_');
        return Path.Combine(dataDirectory, "claude-roots", $"{(name.Length == 0 ? "root" : name)}-{hash}");
    }

    private string ScriptPath => Path.Combine(_dir, ScriptName);
    private string Command => $"powershell -NoProfile -ExecutionPolicy Bypass -File \"{ScriptPath}\"";

    public bool IsLinked
    {
        get
        {
            try { return ReadSettings()["statusLine"]?["command"]?.GetValue<string>() == Command; }
            catch { return false; }
        }
    }

    public void Link()
    {
        Directory.CreateDirectory(_dir);
        var settings = ReadSettings();
        var inner = Path.Combine(_dir, InnerName);
        // 이미 우리 것이면 기존 체인을 유지하고, 다른 statusLine이면 그 명령을 이어 실행하도록 저장
        if (settings["statusLine"] is JsonObject existing && existing["command"]?.GetValue<string>() is { } old && old != Command)
            File.WriteAllText(inner, old);
        else if (settings["statusLine"] is null && File.Exists(inner)) File.Delete(inner);
        File.WriteAllText(ScriptPath, Script);
        settings["statusLine"] = new JsonObject { ["type"] = "command", ["command"] = Command };
        WriteSettings(settings);
    }

    // 첫 실행 시 조용히 한 번 시도하는 용도 - 실패해도 오류창을 띄우지 않고, 다음 실행에서 다시 시도한다
    public bool LinkQuietly()
    {
        try { Link(); return true; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return false; }
    }

    public void Unlink()
    {
        var settings = ReadSettings();
        if (settings["statusLine"]?["command"]?.GetValue<string>() != Command) return;
        var inner = Path.Combine(_dir, InnerName);
        if (File.Exists(inner))
        {
            settings["statusLine"] = new JsonObject { ["type"] = "command", ["command"] = File.ReadAllText(inner) };
            File.Delete(inner);
        }
        else settings.Remove("statusLine");
        WriteSettings(settings);
    }

    public ClaudeLimitSnapshot ReadSnapshot()
    {
        try
        {
            var info = new FileInfo(Path.Combine(_dir, LimitsName));
            if (!info.Exists) return ClaudeLimitSnapshot.None;
            if (_cached is { } c && c.Length == info.Length && c.Modified == info.LastWriteTimeUtc) return c.Snapshot;
            using var stream = new FileStream(info.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var reader = new StreamReader(stream);
            var snapshot = ClaudeLimitSnapshot.ParseStatusLine(reader.ReadToEnd(), info.LastWriteTimeUtc);
            _cached = (info.Length, info.LastWriteTimeUtc, snapshot);
            return snapshot;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return ClaudeLimitSnapshot.None; }
    }

    private JsonObject ReadSettings() =>
        File.Exists(_settingsPath) ? JsonNode.Parse(File.ReadAllText(_settingsPath), documentOptions: new JsonDocumentOptions { CommentHandling = JsonCommentHandling.Skip, AllowTrailingCommas = true }) as JsonObject ?? new() : new();

    private void WriteSettings(JsonObject settings)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(_settingsPath)!);
        File.WriteAllText(_settingsPath, settings.ToJsonString(new JsonSerializerOptions { WriteIndented = true, Encoder = System.Text.Encodings.Web.JavaScriptEncoder.UnsafeRelaxedJsonEscaping }));
    }

    private const string Script = """
        $dir = Split-Path -Parent $MyInvocation.MyCommand.Path
        $raw = [Console]::In.ReadToEnd()
        try {
            $data = $raw | ConvertFrom-Json
            if ($data.rate_limits) {
                $tmp = Join-Path $dir 'claude-limits.json.tmp'
                @{ rate_limits = $data.rate_limits } | ConvertTo-Json -Depth 6 | Set-Content -Path $tmp -Encoding UTF8
                Move-Item -Force $tmp (Join-Path $dir 'claude-limits.json')
            }
        } catch {}
        $inner = Join-Path $dir 'claude-statusline-inner.txt'
        if (Test-Path $inner) {
            $raw | cmd /c (Get-Content -Raw $inner)
        }
        """;
}

// 발견된 모든 설정 루트의 statusLine 연동을 함께 관리. 켜져 있으면 새로 생긴 루트(새 CLAUDE_CONFIG_DIR 등)도 Sync에서 연동한다.
public sealed class ClaudeLimitLinks
{
    private static readonly TimeSpan SyncInterval = TimeSpan.FromMinutes(1);
    private readonly string _home, _dataDirectory;
    private readonly TimeProvider _time;
    private readonly Dictionary<string, ClaudeLimitLink> _links = new(StringComparer.OrdinalIgnoreCase);
    private readonly ClaudeLimitLink _default;
    private DateTimeOffset _lastSync;

    public ClaudeLimitLinks(string home, string dataDirectory, TimeProvider? time = null)
    {
        _home = home; _dataDirectory = dataDirectory; _time = time ?? TimeProvider.System;
        _default = new ClaudeLimitLink(ClaudeConfigRoot.Default(home), dataDirectory);
        _links[_default.ConfigDir] = _default;
        Discover();
    }

    public IReadOnlyCollection<ClaudeLimitLink> Links => _links.Values;
    // 설정 화면 체크 상태는 기본 루트 기준(기존 동작 유지)
    public bool IsLinked => _default.IsLinked;
    private IEnumerable<ClaudeLimitLink> Others => _links.Values.Where(x => x != _default);

    private void Discover()
    {
        foreach (var root in ClaudeConfigRoot.Discover(_home))
        {
            var link = new ClaudeLimitLink(root, _dataDirectory);
            _links.TryAdd(link.ConfigDir, link);
        }
        _lastSync = _time.GetUtcNow();
    }

    // 다른 루트는 권한·형식 문제여도 건너뛰고, 기본 루트 실패만 예외로 올린다
    public void Link()
    {
        Discover();
        foreach (var link in Others) link.LinkQuietly();
        _default.Link();
    }

    public bool LinkQuietly()
    {
        try { Link(); return true; }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return false; }
    }

    public void Unlink()
    {
        foreach (var link in Others)
            try { link.Unlink(); }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { }
        _default.Unlink();
    }

    // 주기 호출용(실제 탐색은 1분 간격). 연동이 켜져 있으면 새로 발견된 루트를 조용히 연동한다
    public void Sync(bool enabled)
    {
        if (_time.GetUtcNow() - _lastSync < SyncInterval) return;
        var before = _links.Count;
        Discover();
        if (enabled && _links.Count != before)
            foreach (var link in Others.Where(x => !x.IsLinked)) link.LinkQuietly();
    }

    // 세션의 설정 루트(null이면 기본)에 해당하는 statusLine 값. 모르는 루트면 None(다른 계정 값을 쓰지 않음)
    public ClaudeLimitSnapshot ReadSnapshot(string? configDir)
    {
        if (string.IsNullOrWhiteSpace(configDir)) return _default.ReadSnapshot();
        string key;
        try { key = Path.GetFullPath(configDir); }
        catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return ClaudeLimitSnapshot.None; }
        return _links.TryGetValue(key, out var link) ? link.ReadSnapshot() : ClaudeLimitSnapshot.None;
    }
}
