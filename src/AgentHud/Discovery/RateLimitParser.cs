using System.Globalization;
using System.Text.RegularExpressions;

namespace AgentHud.Discovery;

// 사용량 한도 오류 문구에서 리셋 시각을 읽는다.
// Codex: "... or try again at 4:34 PM." (로컬 시각)
// Claude: "... resets 3pm (Asia/Seoul)", "... limit will reset at 3:30pm", "...|1751234567"
public static partial class RateLimitParser
{
    // 문구를 해석하지 못했을 때 다시 시도할 간격
    public static readonly TimeSpan FallbackDelay = TimeSpan.FromHours(1);

    public static bool LooksLikeUsageLimit(string? text) => text is not null && LimitText().IsMatch(text);

    public static DateTime? ParseReset(string? text, DateTime eventUtc, TimeZoneInfo? defaultZone = null)
    {
        if (string.IsNullOrWhiteSpace(text)) return null;
        if (UnixSuffix().Match(text) is { Success: true } unix && long.TryParse(unix.Groups[1].Value, out var seconds))
            return DateTimeOffset.FromUnixTimeSeconds(seconds).UtcDateTime;
        if (Relative().Match(text) is { Success: true } relative)
        {
            var delay = TimeSpan.Zero;
            for (var i = 0; i < relative.Groups["n"].Captures.Count; i++)
            {
                var n = int.Parse(relative.Groups["n"].Captures[i].Value, CultureInfo.InvariantCulture);
                delay += char.ToLowerInvariant(relative.Groups["u"].Captures[i].Value[0]) switch
                {
                    'd' => TimeSpan.FromDays(n), 'h' => TimeSpan.FromHours(n), _ => TimeSpan.FromMinutes(n)
                };
            }
            return eventUtc + delay;
        }
        if (Clock().Match(text) is not { Success: true } clock) return null;
        var zone = FindZone(clock.Groups["tz"].Value) ?? defaultZone ?? TimeZoneInfo.Local;
        var hour = int.Parse(clock.Groups["h"].Value, CultureInfo.InvariantCulture);
        var minute = clock.Groups["m"].Success ? int.Parse(clock.Groups["m"].Value, CultureInfo.InvariantCulture) : 0;
        if (clock.Groups["ampm"].Success)
        {
            if (hour is < 1 or > 12) return null;
            hour = hour % 12 + (char.ToLowerInvariant(clock.Groups["ampm"].Value[0]) == 'p' ? 12 : 0);
        }
        // "try again at 4" 같은 숫자만 있는 문구는 시각으로 보지 않음
        else if (!clock.Groups["m"].Success || hour > 23) return null;
        if (minute > 59) return null;
        var local = TimeZoneInfo.ConvertTimeFromUtc(DateTime.SpecifyKind(eventUtc, DateTimeKind.Utc), zone);
        var date = local.Date;
        var hasDate = clock.Groups["mon"].Success;
        if (hasDate)
        {
            if (!DateTime.TryParseExact(clock.Groups["mon"].Value[..3], "MMM", CultureInfo.InvariantCulture, DateTimeStyles.None, out var month)) return null;
            var year = clock.Groups["y"].Success ? int.Parse(clock.Groups["y"].Value, CultureInfo.InvariantCulture) : local.Year;
            var day = int.Parse(clock.Groups["d"].Value, CultureInfo.InvariantCulture);
            if (day > DateTime.DaysInMonth(year, month.Month)) return null;
            date = new DateTime(year, month.Month, day);
        }
        try
        {
            var reset = TimeZoneInfo.ConvertTimeToUtc(date.AddHours(hour).AddMinutes(minute), zone);
            // 날짜 없이 시각만 있으면 이벤트 이후 가장 가까운 그 시각
            if (!hasDate && reset < eventUtc.AddMinutes(-1)) reset = reset.AddDays(1);
            else if (hasDate && !clock.Groups["y"].Success && reset < eventUtc.AddDays(-1)) reset = reset.AddYears(1);
            return reset;
        }
        catch (ArgumentException) { return null; }
    }

    private static TimeZoneInfo? FindZone(string id)
    {
        if (string.IsNullOrWhiteSpace(id)) return null;
        try { return TimeZoneInfo.FindSystemTimeZoneById(id.Trim()); }
        catch (Exception exception) when (exception is TimeZoneNotFoundException or InvalidTimeZoneException) { return null; }
    }

    [GeneratedRegex(@"usage limit|limit reached|limit will reset|hit your (?:\w+ )?limit", RegexOptions.IgnoreCase)]
    private static partial Regex LimitText();
    [GeneratedRegex(@"\|(\d{10})\b")]
    private static partial Regex UnixSuffix();
    [GeneratedRegex(@"(?:resets?|try again)\s+in\s+(?:(?<n>\d+)\s*(?<u>days?|hours?|hrs?|h\b|minutes?|mins?|m\b)[\s,]*(?:and\s+)?)+", RegexOptions.IgnoreCase)]
    private static partial Regex Relative();
    [GeneratedRegex(@"(?:resets?|try again)\s+(?:(?:at|on)\s+)?(?:(?<mon>Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec)[a-z]*\.?\s+(?<d>\d{1,2})(?:st|nd|rd|th)?,?\s+(?:(?<y>\d{4}),?\s+)?(?:at\s+)?)?(?<h>\d{1,2})(?::(?<m>\d{2}))?\s*(?<ampm>[ap]\.?m\b\.?)?(?:\s*\((?<tz>[^)]+)\))?", RegexOptions.IgnoreCase)]
    private static partial Regex Clock();
}
