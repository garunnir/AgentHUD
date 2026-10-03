using System.Text.Json;
using System.Text.Json.Nodes;
using AgentHud.Models;

namespace AgentHud;

// Claude Code의 statusLine 스크립트가 stdin으로 받는 rate_limits(서버 기준 5시간·주간 한도)를
// 파일로 떨궈 HUD가 읽게 한다. 기존 statusLine이 있으면 그대로 이어서 실행(체이닝)하고, 해제하면 복원한다.
public sealed class ClaudeLimitLink
{
    private const string ScriptName = "claude-statusline.ps1";
    private const string LimitsName = "claude-limits.json";
    private const string InnerName = "claude-statusline-inner.txt";
    private readonly string _dir;
    private readonly string _settingsPath;
    private (long Length, DateTime Modified, (LimitWindow? FiveHour, LimitWindow? SevenDay) Limits)? _cached;
    // API로 조회한 한도 등 추가 소스. 상태줄 파일보다 최근이면 이쪽을 씀
    public Func<(LimitWindow? FiveHour, LimitWindow? SevenDay, DateTime At)>? ExtraSource { get; set; }

    public ClaudeLimitLink(string home, string dataDirectory)
    {
        _dir = dataDirectory;
        _settingsPath = Path.Combine(home, ".claude", "settings.json");
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

    // 상태줄 스크립트 파일과 추가 소스(API) 중 더 최근에 갱신된 쪽의 한도. 둘 다 없으면 null
    public (LimitWindow? FiveHour, LimitWindow? SevenDay) ReadLimits()
    {
        var script = ReadScriptLimits();
        var extra = ExtraSource?.Invoke() ?? default;
        return extra.At > script.At && (extra.FiveHour is not null || extra.SevenDay is not null) ? (extra.FiveHour, extra.SevenDay) : (script.Limits.FiveHour, script.Limits.SevenDay);
    }

    private ((LimitWindow? FiveHour, LimitWindow? SevenDay) Limits, DateTime At) ReadScriptLimits()
    {
        try
        {
            var info = new FileInfo(Path.Combine(_dir, LimitsName));
            if (!info.Exists) return ((null, null), DateTime.MinValue);
            if (_cached is { } c && c.Length == info.Length && c.Modified == info.LastWriteTimeUtc) return (c.Limits, c.Modified);
            using var stream = new FileStream(info.FullName, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            using var json = JsonDocument.Parse(stream);
            var limits = (Window(json.RootElement, "five_hour"), Window(json.RootElement, "seven_day"));
            _cached = (info.Length, info.LastWriteTimeUtc, limits);
            return (limits, info.LastWriteTimeUtc);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return ((null, null), DateTime.MinValue); }
    }

    private static LimitWindow? Window(JsonElement root, string name) =>
        root.TryGetProperty("rate_limits", out var limits) && limits.ValueKind == JsonValueKind.Object
        && limits.TryGetProperty(name, out var w) && w.ValueKind == JsonValueKind.Object
        && w.TryGetProperty("used_percentage", out var used) && used.ValueKind == JsonValueKind.Number
        && w.TryGetProperty("resets_at", out var resets) && resets.TryGetInt64(out var seconds)
            ? new LimitWindow(used.GetDouble(), DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime) : null;

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
