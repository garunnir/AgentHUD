using System.Text.Json;
using AgentHud.Models;

namespace AgentHud;

public enum ClaudeLimitSource { None, StatusLine, UsageApi }

// Claude 한도 스냅샷 하나. UpdatedAt은 이 값이 기록된 시각(UTC) - statusLine은 claude-limits.json의
// 수정 시각, API는 응답을 받은 시각
public sealed record ClaudeLimitSnapshot(ClaudeLimitSource Source, LimitWindow? FiveHour, LimitWindow? SevenDay, DateTime UpdatedAt)
{
    public static readonly ClaudeLimitSnapshot None = new(ClaudeLimitSource.None, null, null, DateTime.MinValue);
    public bool HasData => FiveHour is not null || SevenDay is not null;
    // 모델별 주간 한도(Claude Fable). 응답에 있을 때만 값이 있고, 없으면 게이지 줄을 만들지 않는다
    public LimitWindow? Fable { get; init; }

    // Claude Code statusLine 스크립트가 stdin으로 받는 JSON:
    // {"rate_limits":{"five_hour":{"used_percentage":..,"resets_at":<epoch s>},"seven_day":{..}}}
    public static ClaudeLimitSnapshot ParseStatusLine(string json, DateTime updatedAtUtc)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var five = Window(doc.RootElement, "five_hour");
            var seven = Window(doc.RootElement, "seven_day");
            if (five is null && seven is null) return None;
            var fable = doc.RootElement.TryGetProperty("rate_limits", out var limits) && limits.ValueKind == JsonValueKind.Object
                && FableName(limits) is { } name ? StatusWindow(limits, name) : null;
            return new(ClaudeLimitSource.StatusLine, five, seven, updatedAtUtc) { Fable = fable };
        }
        catch (JsonException) { return None; }
    }

    // claude.ai /api/organizations/{org}/usage 응답(비공식):
    // {"five_hour":{"utilization":..,"resets_at":"ISO"|null},"seven_day":{..},"seven_day_opus":{..}|null,...}
    // 모델별 주간 창은 seven_day_<모델> 형태라 Fable도 seven_day_fable(또는 이름에 fable이 든 seven_day_* 키)로 찾는다
    public static ClaudeLimitSnapshot ParseUsageApi(string json, DateTime updatedAtUtc)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var root = doc.RootElement;
            if (root.ValueKind != JsonValueKind.Object) return None;
            var five = ApiWindow(root, "five_hour");
            var seven = ApiWindow(root, "seven_day");
            if (five is null && seven is null) return None;
            return new(ClaudeLimitSource.UsageApi, five, seven, updatedAtUtc) { Fable = FableWindow(root) };
        }
        catch (JsonException) { return None; }
    }

    private static string? FableName(JsonElement obj)
    {
        if (obj.TryGetProperty("seven_day_fable", out _)) return "seven_day_fable";
        foreach (var p in obj.EnumerateObject())
            if (p.Name.StartsWith("seven_day_", StringComparison.OrdinalIgnoreCase) && p.Name.Contains("fable", StringComparison.OrdinalIgnoreCase)) return p.Name;
        return null;
    }

    private static LimitWindow? FableWindow(JsonElement root)
    {
        // Claude Code 2.1.212는 Fable을 seven_day_overage_included로 부른다.
        // https://github.com/d-mato/claude-usage-bar/issues/2 (limits의 weekly_scoped 형식도 기록됨)
        foreach (var p in root.EnumerateObject())
            if (p.Name.StartsWith("seven_day_", StringComparison.OrdinalIgnoreCase)
                && p.Name.Contains("fable", StringComparison.OrdinalIgnoreCase) && ApiWindow(root, p.Name) is { } named) return named;
        if (ApiWindow(root, "seven_day_overage_included") is { } included) return included;
        if (!root.TryGetProperty("limits", out var limits) || limits.ValueKind != JsonValueKind.Array) return null;
        foreach (var limit in limits.EnumerateArray())
        {
            if (limit.ValueKind != JsonValueKind.Object
                || !limit.TryGetProperty("kind", out var kind) || kind.ValueKind != JsonValueKind.String || kind.GetString() != "weekly_scoped"
                || !limit.TryGetProperty("scope", out var scope) || scope.ValueKind != JsonValueKind.Object
                || !scope.TryGetProperty("model", out var model) || model.ValueKind != JsonValueKind.Object
                || !model.TryGetProperty("display_name", out var name) || name.ValueKind != JsonValueKind.String
                || name.GetString()?.Contains("fable", StringComparison.OrdinalIgnoreCase) != true
                || !limit.TryGetProperty("percent", out var percent) || percent.ValueKind != JsonValueKind.Number) continue;
            var reset = limit.TryGetProperty("resets_at", out var at) && at.ValueKind == JsonValueKind.String
                && DateTime.TryParse(at.GetString(), System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out var parsed)
                ? parsed.ToUniversalTime() : DateTime.MaxValue;
            return new(percent.GetDouble(), reset);
        }
        return null;
    }

    private static LimitWindow? Window(JsonElement root, string name) =>
        root.TryGetProperty("rate_limits", out var limits) && limits.ValueKind == JsonValueKind.Object ? StatusWindow(limits, name) : null;

    private static LimitWindow? StatusWindow(JsonElement limits, string name) =>
        limits.TryGetProperty(name, out var w) && w.ValueKind == JsonValueKind.Object
        && w.TryGetProperty("used_percentage", out var used) && used.ValueKind == JsonValueKind.Number
        && w.TryGetProperty("resets_at", out var resets) && resets.TryGetInt64(out var seconds)
            ? new LimitWindow(used.GetDouble(), DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime) : null;

    // resets_at이 null이면 진행 중인 창이 없다는 뜻이므로 사용률만 쓰고 리셋 시각은 알 수 없음
    private static LimitWindow? ApiWindow(JsonElement root, string name) =>
        root.TryGetProperty(name, out var w) && w.ValueKind == JsonValueKind.Object
        && w.TryGetProperty("utilization", out var used) && used.ValueKind == JsonValueKind.Number
            ? new LimitWindow(used.GetDouble(), w.TryGetProperty("resets_at", out var at) && at.ValueKind == JsonValueKind.String
                && DateTime.TryParse(at.GetString(), System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.RoundtripKind, out var parsed)
                ? parsed.ToUniversalTime() : DateTime.MaxValue) : null;
}

// statusLine과 sessionKey API 중 고른 값. UI는 *Stale이 true면 마지막 값에 "stale" 표시를 덧붙이고,
// 그 창의 ResetsAt마저 지났으면(값이 무의미해짐) 숫자 없이 "Stale"만 보여준다. UpdatedAt은 그 설명(tooltip)에 쓴다
public sealed record ClaudeLimitPick(ClaudeLimitSource Source, LimitWindow? FiveHour, LimitWindow? SevenDay, bool FiveHourStale, bool SevenDayStale, DateTime UpdatedAt)
{
    public LimitWindow? Fable { get; init; }
    public bool FableStale { get; init; }
}

// statusLine(기본, 공식 CLI 값)과 sessionKey API(선택, 비공식) 중 "더 신선하고 유효한" 쪽을 고른다.
// 이전에는 API를 설정하면 무조건 그 값만 썼지만, 그 값은 같은 계정(HUD가 세션을 읽고 있는 그 CLI 로그인)을
// 가리키는 로컬 statusLine과 경쟁할 뿐 다른 사람의 계정을 보여줄 위험이 없으므로, API 인증이 끊기면
// 자동으로 statusLine(또는 토큰 추정치)로 넘어가도 안전하다.
public static class ClaudeLimitPolicy
{
    // statusLine 파일이 갱신되지 않을 만큼 오래됐다고 보는 기준 (API는 5분마다 스스로 갱신하므로 더 짧다)
    public static readonly TimeSpan StatusLineMaxAge = TimeSpan.FromHours(12);
    public static readonly TimeSpan ApiMaxAge = TimeSpan.FromMinutes(30);
    // statusLine 기록 이후 Claude 세션이 더 움직였다면, 그 활동은 statusLine이 실행되지 않는 곳
    // (예: VS Code 확장) 에서 일어난 것이므로 값을 신뢰하지 않는다. 터미널에서 정상적으로 쓰는 동안의
    // 짧은 지연은 허용하기 위한 여유 시간
    public static readonly TimeSpan ActivityGrace = TimeSpan.FromMinutes(15);

    public static bool IsStale(ClaudeLimitSnapshot snapshot, DateTime nowUtc, DateTime? lastClaudeActivityUtc)
    {
        if (!snapshot.HasData) return true;
        var maxAge = snapshot.Source == ClaudeLimitSource.StatusLine ? StatusLineMaxAge : ApiMaxAge;
        if (nowUtc - snapshot.UpdatedAt > maxAge) return true;
        if (snapshot.Source == ClaudeLimitSource.StatusLine && lastClaudeActivityUtc is { } activity
            && activity > snapshot.UpdatedAt + ActivityGrace) return true;
        return false;
    }

    // 두 소스의 창을 섞지 않는다(5h는 statusLine, 주간은 API처럼) - 서로 다른 계정일 수 있기 때문.
    // 선택한 스냅샷 안에서 창별 유효기간(ResetsAt)은 따로 확인한다.
    public static ClaudeLimitPick Pick(ClaudeLimitSnapshot statusLine, ClaudeLimitSnapshot api, DateTime nowUtc, DateTime? lastClaudeActivityUtc)
    {
        var slCandidate = statusLine.HasData;
        var apiCandidate = api.HasData;
        if (!slCandidate && !apiCandidate) return new(ClaudeLimitSource.None, null, null, false, false, DateTime.MinValue);

        var slStale = slCandidate && IsStale(statusLine, nowUtc, lastClaudeActivityUtc);
        var apiStale = apiCandidate && IsStale(api, nowUtc, lastClaudeActivityUtc);

        ClaudeLimitSnapshot chosen;
        bool stale;
        if (slCandidate && apiCandidate)
        {
            if (!slStale && !apiStale) { chosen = statusLine.UpdatedAt >= api.UpdatedAt ? statusLine : api; stale = false; }
            else if (!slStale) { chosen = statusLine; stale = false; }
            else if (!apiStale) { chosen = api; stale = false; }
            else { chosen = statusLine.UpdatedAt >= api.UpdatedAt ? statusLine : api; stale = true; }
        }
        else if (slCandidate) { chosen = statusLine; stale = slStale; }
        else { chosen = api; stale = apiStale; }

        var fiveStale = stale || (chosen.FiveHour is { } five && five.ResetsAt <= nowUtc);
        var sevenStale = stale || (chosen.SevenDay is { } seven && seven.ResetsAt <= nowUtc);
        // statusLine은 아직 Fable 창을 주지 않으므로, 고른 쪽에 없으면 같은 계정(orgId로 고른)의 신선한 API 값을 쓴다
        var (fable, fableStale) = chosen.Fable is { } f ? (f, stale)
            : apiCandidate && !apiStale && api.Fable is { } af ? (af, false) : (null, false);
        fableStale = fableStale || (fable is not null && fable.ResetsAt <= nowUtc);
        return new(chosen.Source, chosen.FiveHour, chosen.SevenDay, fiveStale, sevenStale, chosen.UpdatedAt) { Fable = fable, FableStale = fableStale };
    }
}
