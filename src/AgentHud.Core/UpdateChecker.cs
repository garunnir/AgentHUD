using System.Text.Json;

namespace AgentHud;

public sealed record UpdateRelease(Version Version, string Tag, string PageUrl, string AssetName, string AssetUrl, string? Sha256);

/// <summary>
/// GitHub Releases의 latest 응답(JSON)에서 현재 빌드보다 새 버전과 같은 배포 형태(zip 접미사)의 파일을 고른다.
/// 형식은 GitHub REST API 2022-11-28 기준(assets[].digest = "sha256:...")
/// </summary>
public static class UpdateChecker
{
    public const string LatestUrl = "https://api.github.com/repos/garunnir/AgentHUD/releases/latest";

    // "v0.14.1" → 0.14.1.0. 프리릴리스 태그(v1.0.0-beta)는 자동 업데이트 대상이 아님
    public static Version? ParseTag(string? tag) =>
        tag is null || tag.Contains('-') || !Version.TryParse(tag.TrimStart('v', 'V'), out var v) ? null : Normalize(v);

    // 0.14.1과 0.14.1.0이 같게 비교되도록 빠진 자리를 0으로 채움
    public static Version Normalize(Version v) => new(v.Major, v.Minor, Math.Max(0, v.Build), Math.Max(0, v.Revision));

    public static UpdateRelease? Pick(string json, Version current, string assetSuffix)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (root.TryGetProperty("draft", out var draft) && draft.ValueKind == JsonValueKind.True) return null;
        if (root.TryGetProperty("prerelease", out var pre) && pre.ValueKind == JsonValueKind.True) return null;
        var tag = root.TryGetProperty("tag_name", out var t) ? t.GetString() : null;
        if (ParseTag(tag) is not { } version || version <= Normalize(current)) return null;
        if (!root.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array) return null;
        foreach (var asset in assets.EnumerateArray())
        {
            var name = asset.TryGetProperty("name", out var n) ? n.GetString() : null;
            var url = asset.TryGetProperty("browser_download_url", out var u) ? u.GetString() : null;
            if (name is null || url is null || !name.EndsWith(assetSuffix, StringComparison.OrdinalIgnoreCase)) continue;
            var digest = asset.TryGetProperty("digest", out var d) ? d.GetString() : null;
            var sha = digest is not null && digest.StartsWith("sha256:", StringComparison.OrdinalIgnoreCase) ? digest[7..].ToLowerInvariant() : null;
            var page = root.TryGetProperty("html_url", out var h) ? h.GetString() ?? "" : "";
            return new(version, tag!, page, name, url, sha);
        }
        return null;
    }
}
