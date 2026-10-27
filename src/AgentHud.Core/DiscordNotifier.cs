using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using AgentHud.Models;

namespace AgentHud;

// Discord 웹훅으로 세션 상태 변화를 보낸다. 웹훅 URL이 곧 비밀이므로 본문에는 에이전트·프로젝트명·상태만 담고 대화 내용은 보내지 않는다.
// 웹훅은 5회/2초 제한이 있어 한 번에 발생한 이벤트는 한 메시지로 묶는다. (웹훅 실행 API: POST /api/webhooks/{id}/{token}, content + allowed_mentions, 2026 기준 확인)
public sealed partial class DiscordNotifier
{
    private static readonly HttpClient SharedHttp = new() { Timeout = TimeSpan.FromSeconds(5) };
    private readonly HttpClient _http;
    private readonly TimeProvider _time;
    private readonly object _logGate = new();
    // 설정되면 전송 결과·건너뛴 이유를 discord.log에 남긴다. 알림이 안 왔을 때 원인을 구분하기 위한 진단용
    public string? LogDirectory { get; set; }
    public bool Enabled { get; set; }
    public string? WebhookUrl { get; set; }
    public bool NotifyAsk { get; set; } = true;
    public bool NotifyComplete { get; set; } = true;
    public DiscordNotifier(HttpClient? http = null, TimeProvider? time = null) { _http = http ?? SharedHttp; _time = time ?? TimeProvider.System; }

    [GeneratedRegex(@"^https://(?:(?:ptb|canary)\.)?discord(?:app)?\.com/api/webhooks/\d+/[\w-]+/?$")]
    private static partial Regex WebhookPattern();
    public static bool IsValidWebhookUrl(string? url) => url is not null && WebhookPattern().IsMatch(url);

    // 켜진 이벤트에 해당하지 않으면 null. 완료에는 작업에 걸린 시간과 완료 시각을 붙인다
    public string? BuildLine(AgentSession s, AgentState state, TimeSpan? elapsed = null)
    {
        var key = state switch
        {
            AgentState.Completed when NotifyComplete => "Discord.Completed",
            AgentState.WaitingForInput when NotifyAsk => "Discord.WaitingInput",
            AgentState.WaitingForApproval when NotifyAsk => "Discord.WaitingApproval",
            _ => null,
        };
        if (key is null) return null;
        var line = Loc.F(key, Escape(s.DisplayName), Escape(s.ProjectName));
        return state == AgentState.Completed && elapsed is { } e ? line + " " + Loc.F("Discord.Elapsed", FormatDuration(e), _time.GetLocalNow().DateTime) : line;
    }

    public static string FormatDuration(TimeSpan d) => d.TotalHours >= 1 ? Loc.F("Usage.ResetHoursMinutes", (int)d.TotalHours, d.Minutes)
        : d.TotalMinutes >= 1 ? Loc.F("Duration.MinutesSeconds", d.Minutes, d.Seconds) : Loc.F("Duration.Seconds", Math.Max(0, d.Seconds));

    public string LimitResetLine(AgentSession s) => Loc.F("Discord.LimitReset", Escape(s.DisplayName), Escape(s.ProjectName));

    public Task<bool> NotifyAsync(IEnumerable<(AgentSession Session, AgentState State, TimeSpan? Elapsed)> events)
    {
        if (!Enabled || !IsValidWebhookUrl(WebhookUrl)) return Task.FromResult(false);
        var lines = events.Select(e => BuildLine(e.Session, e.State, e.Elapsed)).OfType<string>().ToArray();
        return lines.Length == 0 ? Task.FromResult(false) : SendAsync(string.Join('\n', lines));
    }

    public Task<bool> NotifyLimitResetAsync(AgentSession s) => Enabled && IsValidWebhookUrl(WebhookUrl) ? SendAsync(LimitResetLine(s)) : Task.FromResult(false);

    // 실패(네트워크, 429, 잘못된 URL)는 알림 기능이 앱을 방해하지 않도록 false만 돌려준다
    public async Task<bool> SendAsync(string content)
    {
        if (!IsValidWebhookUrl(WebhookUrl)) { Log("skip (no valid webhook): " + OneLine(content)); return false; }
        try
        {
            // 알림 문구의 @everyone·@here·역할 멘션이 실제로 호출되지 않게 막는다
            var body = JsonSerializer.Serialize(new { content = Truncate(content), allowed_mentions = new { parse = Array.Empty<string>() } });
            using var res = await _http.PostAsync(WebhookUrl, new StringContent(body, Encoding.UTF8, "application/json"));
            Log($"{(res.IsSuccessStatusCode ? "sent" : "FAILED")} {(int)res.StatusCode}: {OneLine(content)}");
            return res.IsSuccessStatusCode;
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or InvalidOperationException) { Log($"FAILED {e.GetType().Name} {e.Message}: {OneLine(content)}"); return false; }
    }

    // 로그가 무한히 커지지 않게 256KB를 넘으면 .old로 한 번 돌린다. 로그 실패는 무시
    public void Log(string message)
    {
        if (LogDirectory is null) return;
        try
        {
            Directory.CreateDirectory(LogDirectory);
            var path = Path.Combine(LogDirectory, "discord.log");
            lock (_logGate)
            {
                if (File.Exists(path) && new FileInfo(path).Length > 256 * 1024) File.Move(path, path + ".old", true);
                File.AppendAllText(path, $"{_time.GetLocalNow():yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
    private static string OneLine(string s) => s.Replace("\n", " / ");

    private static string Truncate(string s) => s.Length <= 1900 ? s : s[..1900];
    // 프로젝트 폴더명의 _ * ~ 등이 마크다운으로 해석되지 않게 이스케이프
    private static string Escape(string s) => MarkdownChars().Replace(s, @"\$0");
    [GeneratedRegex(@"[\\*_~`>|#\[\]()@]")]
    private static partial Regex MarkdownChars();
}
