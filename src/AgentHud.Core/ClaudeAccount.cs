using System.Text.Json;

namespace AgentHud;

// Claude Code가 ~/.claude.json(또는 CLAUDE_CONFIG_DIR/.claude.json)에 남기는 로그인 메타.
// 토큰·키가 아니라 표시용 신원만 읽는다(organizationUuid로 사용량 API 계정과 매칭).
public sealed record ClaudeAccountIdentity(string? OrganizationUuid, string? Email, string? DisplayName)
{
    public static readonly ClaudeAccountIdentity None = new(null, null, null);
    public bool HasOrg => !string.IsNullOrWhiteSpace(OrganizationUuid);
    public string Label => !string.IsNullOrWhiteSpace(Email) ? Email!
        : !string.IsNullOrWhiteSpace(DisplayName) ? DisplayName!
        : OrganizationUuid is { Length: > 8 } org ? org[..8] : OrganizationUuid ?? "";

    public static ClaudeAccountIdentity Read(string claudeJsonPath)
    {
        try
        {
            if (!File.Exists(claudeJsonPath)) return None;
            using var stream = File.OpenRead(claudeJsonPath);
            using var doc = JsonDocument.Parse(stream);
            if (!doc.RootElement.TryGetProperty("oauthAccount", out var account) || account.ValueKind != JsonValueKind.Object)
                return None;
            string? Get(params string[] names)
            {
                foreach (var name in names)
                    if (account.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
                        && !string.IsNullOrWhiteSpace(value.GetString()))
                        return value.GetString()!.Trim();
                return null;
            }
            var org = Get("organizationUuid", "organization_uuid");
            if (org is not null && !Guid.TryParse(org, out _)) org = null;
            return new(org, Get("emailAddress", "primaryEmailAddress", "email"), Get("displayName", "fullName", "name"));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException or JsonException) { return None; }
    }
}

// Claude Code 설정 루트 하나. 기본은 ~/.claude + 형제 ~/.claude.json,
// CLAUDE_CONFIG_DIR / aisw 프로필은 디렉터리 안에 sessions·.claude.json이 같이 있다.
public sealed record ClaudeConfigRoot(string ConfigDir, bool IsDefault, string Home)
{
    public string SessionsRoot => Path.Combine(ConfigDir, "sessions");
    public string ProjectsRoot => Path.Combine(ConfigDir, "projects");
    public string ClaudeJsonPath => IsDefault
        ? Path.Combine(Home, ".claude.json")
        : Path.Combine(ConfigDir, ".claude.json");
    public ClaudeAccountIdentity Identity => ClaudeAccountIdentity.Read(ClaudeJsonPath);
    public IEnumerable<string> WatchRoots => [SessionsRoot, ProjectsRoot];

    public static ClaudeConfigRoot Default(string home) =>
        new(Path.Combine(home, ".claude"), true, home);

    public static IReadOnlyList<ClaudeConfigRoot> Discover(string home)
    {
        var list = new List<ClaudeConfigRoot>();
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        void Add(string configDir, bool isDefault)
        {
            try { configDir = Path.GetFullPath(configDir); }
            catch (Exception e) when (e is ArgumentException or NotSupportedException or PathTooLongException) { return; }
            if (!seen.Add(configDir)) return;
            if (!isDefault && !Directory.Exists(Path.Combine(configDir, "sessions"))
                && !Directory.Exists(Path.Combine(configDir, "projects"))
                && !File.Exists(Path.Combine(configDir, ".claude.json")))
                return;
            list.Add(new(configDir, isDefault, home));
        }

        Add(Path.Combine(home, ".claude"), true);
        try
        {
            foreach (var dir in Directory.EnumerateDirectories(home, ".claude*"))
            {
                var name = Path.GetFileName(dir);
                if (name.Equals(".claude", StringComparison.OrdinalIgnoreCase)) continue;
                Add(dir, false);
            }
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }

        var aisw = Path.Combine(home, ".aisw", "profiles", "claude");
        if (Directory.Exists(aisw))
        {
            try
            {
                foreach (var dir in Directory.EnumerateDirectories(aisw))
                    Add(dir, false);
            }
            catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
        }

        var env = Environment.GetEnvironmentVariable("CLAUDE_CONFIG_DIR");
        if (!string.IsNullOrWhiteSpace(env)) Add(env.Trim(), false);
        return list;
    }
}
