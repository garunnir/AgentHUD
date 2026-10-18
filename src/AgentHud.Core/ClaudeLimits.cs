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

    // Claude Code statusLine 스크립트가 stdin으로 받는 JSON:
    // {"rate_limits":{"five_hour":{"used_percentage":..,"resets_at":<epoch s>},"seven_day":{..}}}
    public static ClaudeLimitSnapshot ParseStatusLine(string json, DateTime updatedAtUtc)
    {
        try
        {
            using var doc = JsonDocument.Parse(json);
            var five = Window(doc.RootElement, "five_hour");
            var seven = Window(doc.RootElement, "seven_day");
            return five is null && seven is null ? None : new(ClaudeLimitSource.StatusLine, five, seven, updatedAtUtc);
        }
        catch (JsonException) { return None; }
    }

    private static LimitWindow? Window(JsonElement root, string name) =>
        root.TryGetProperty("rate_limits", out var limits) && limits.ValueKind == JsonValueKind.Object
        && limits.TryGetProperty(name, out var w) && w.ValueKind == JsonValueKind.Object
        && w.TryGetProperty("used_percentage", out var used) && used.ValueKind == JsonValueKind.Number
        && w.TryGetProperty("resets_at", out var resets) && resets.TryGetInt64(out var seconds)
            ? new LimitWindow(used.GetDouble(), DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime) : null;
}

// statusLine과 sessionKey API 중 고른 값. UI는 *Stale이 true면 마지막 값에 "stale" 표시를 덧붙이고,
// 그 창의 ResetsAt마저 지났으면(값이 무의미해짐) 숫자 없이 "Stale"만 보여준다. UpdatedAt은 그 설명(tooltip)에 쓴다
public sealed record ClaudeLimitPick(ClaudeLimitSource Source, LimitWindow? FiveHour, LimitWindow? SevenDay, bool FiveHourStale, bool SevenDayStale, DateTime UpdatedAt);

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
        return new(chosen.Source, chosen.FiveHour, chosen.SevenDay, fiveStale, sevenStale, chosen.UpdatedAt);
    }
}
