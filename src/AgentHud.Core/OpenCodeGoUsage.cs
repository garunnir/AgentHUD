using System.Globalization;
using System.Text.Json;
using AgentHud.Models;

namespace AgentHud;

public sealed record OpenCodeGoUsage(LimitWindow FiveHour, LimitWindow Week, LimitWindow Month, DateTime FetchedAt)
{
    // Console endpoint contract follows the existing macOS OpenCodeGoUsageApi.
    public static OpenCodeGoUsage Parse(string json, DateTime fetchedAt)
    {
        using var doc = JsonDocument.Parse(json);
        var root = doc.RootElement;
        if (!root.TryGetProperty("product", out var product) || product.ValueKind != JsonValueKind.String
            || product.GetString()?.StartsWith("go", StringComparison.Ordinal) != true) throw new FormatException("Not a Go subscription");
        var meters = root.GetProperty("access").GetProperty("meters");
        return new(Window(meters.GetProperty("fiveHour")), Window(meters.GetProperty("week")), Window(meters.GetProperty("month")), fetchedAt);
    }

    private static LimitWindow Window(JsonElement meter)
    {
        static decimal Amount(JsonElement meter, string key)
        {
            var value = meter.GetProperty(key);
            var text = value.ValueKind == JsonValueKind.String ? value.GetString() : value.GetRawText();
            if (!decimal.TryParse(text, NumberStyles.Float, CultureInfo.InvariantCulture, out var result) || result < 0)
                throw new FormatException("Invalid Go meter amount");
            return result;
        }
        var limit = Amount(meter, "limitMicroCents");
        var used = Amount(meter, "usedMicroCents");
        if (limit <= 0) throw new FormatException("Missing Go meter limit");
        // Clamp before multiplying to avoid overflowing large micro-cent values.
        var percent = used >= limit ? 100 : (double)(used / limit * 100);
        var reset = meter.GetProperty("resetsAt").GetDateTimeOffset().UtcDateTime;
        return new(percent, reset);
    }
}
