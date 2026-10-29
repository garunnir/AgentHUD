using System.Globalization;
using System.Text.Json;
using AgentHud.Models;

namespace AgentHud;

// Unofficial cursor.com/api/dashboard/get-current-period-usage shape (verified 2026-05 via OmniRoute/quotas).
public sealed record CursorUsage(LimitWindow? Auto, LimitWindow? Api, LimitWindow? Plan, DateTime FetchedAt)
{
    public static CursorUsage Parse(string json, DateTime fetchedAt)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        var reset = ParseReset(root) ?? DateTime.MaxValue;
        LimitWindow? auto = null, api = null, plan = null;
        if (root.TryGetProperty("planUsage", out var usage) && usage.ValueKind == JsonValueKind.Object)
        {
            // Auto/API are internal pool percents. Plan is included spend vs limit (matches dashboard
            // "You've used N% of your included usage"). totalPercentUsed is a weighted Auto+API blend
            // and often equals Auto when API spend is tiny — do not use it as Plan.
            auto = PercentWindow(usage, "autoPercentUsed", reset);
            api = PercentWindow(usage, "apiPercentUsed", reset);
            plan = SpendWindow(usage, reset);
        }
        if (auto is null && api is null && plan is null) throw new FormatException("No Cursor plan usage");
        return new(auto, api, plan, fetchedAt);
    }

    private static LimitWindow? PercentWindow(JsonElement usage, string name, DateTime reset)
    {
        if (!usage.TryGetProperty(name, out var field) || field.ValueKind is not (JsonValueKind.Number or JsonValueKind.String)) return null;
        var text = field.ValueKind == JsonValueKind.String ? field.GetString() : field.GetRawText();
        if (!double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var percent) || percent < 0) return null;
        return new(Math.Min(100, percent), reset);
    }

    private static LimitWindow? SpendWindow(JsonElement usage, DateTime reset)
    {
        var limit = Amount(usage, "limit");
        var used = Amount(usage, "includedSpend") ?? Amount(usage, "totalSpend");
        if (limit is not > 0 || used is null) return null;
        var percent = used >= limit ? 100 : used.Value / limit.Value * 100;
        return new(percent, reset);
    }

    private static double? Amount(JsonElement usage, string name)
    {
        if (!usage.TryGetProperty(name, out var field) || field.ValueKind is not (JsonValueKind.Number or JsonValueKind.String)) return null;
        var text = field.ValueKind == JsonValueKind.String ? field.GetString() : field.GetRawText();
        return double.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var value) && value >= 0 ? value : null;
    }

    // billingCycleEnd is either unix ms (number/string) or an ISO timestamp.
    private static DateTime? ParseReset(JsonElement root)
    {
        if (!root.TryGetProperty("billingCycleEnd", out var end)) return null;
        if (end.ValueKind == JsonValueKind.Number && end.TryGetInt64(out var ms))
            return DateTimeOffset.FromUnixTimeMilliseconds(ms).UtcDateTime;
        if (end.ValueKind != JsonValueKind.String || end.GetString() is not { Length: > 0 } text) return null;
        if (long.TryParse(text, NumberStyles.Integer, CultureInfo.InvariantCulture, out ms))
            return DateTimeOffset.FromUnixTimeMilliseconds(ms > 1_000_000_000_000 ? ms : ms * 1000).UtcDateTime;
        return DateTimeOffset.TryParse(text, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var dto) ? dto.UtcDateTime : null;
    }
}
