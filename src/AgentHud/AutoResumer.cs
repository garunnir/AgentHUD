using System.Diagnostics;
using System.Text;
using AgentHud.Discovery;
using AgentHud.Models;

namespace AgentHud;

// 사용량 한도로 끊긴 세션을 리셋 시각 이후 CLI로 한 번 이어서 실행한다.
// Claude: claude --resume <id> -p --permission-mode acceptEdits
// Codex:  codex exec resume --skip-git-repo-check -c sandbox_mode=workspace-write <id> -
// 프롬프트는 셸 인용 문제를 피하려고 stdin으로 전달한다.
public sealed class AutoResumer
{
    public static string DefaultPrompt => Loc.T("Resume.DefaultPrompt");
    // 한도 리셋 직후엔 아직 거절될 수 있어 조금 기다림
    public static readonly TimeSpan StartDelay = TimeSpan.FromMinutes(1);
    private readonly TimeProvider _time;
    private readonly string _home;
    private readonly string _logDirectory;
    private readonly Func<AgentSession, ProcessStartInfo, string, bool> _start;
    private readonly object _gate = new();
    // (세션, 리셋 시각)마다 한 번만 시도. 다시 한도에 걸리면 리셋 시각이 바뀌어 새로 시도됨
    private readonly HashSet<(string Id, DateTime Reset)> _attempted = [];
    public bool Enabled { get; set; }
    private string _prompt = DefaultPrompt;
    public string Prompt { get => _prompt; set => _prompt = string.IsNullOrWhiteSpace(value) ? DefaultPrompt : value; }

    public AutoResumer(string home, string logDirectory, TimeProvider? time = null, Func<AgentSession, ProcessStartInfo, string, bool>? start = null)
    {
        _home = home; _logDirectory = logDirectory; _time = time ?? TimeProvider.System; _start = start ?? StartProcess;
    }

    public bool IsDue(AgentSession session)
    {
        if (session.RateLimitResetAt is not { } reset || session.ParentSessionId is not null) return false;
        var now = _time.GetUtcNow().UtcDateTime;
        // HUD가 꺼져 있어 한참 지난 한도는 사용자가 이미 처리했을 수 있으므로 건드리지 않음
        return now >= reset + StartDelay && now < reset + CodexProvider.LimitGrace;
    }

    public void Check(IEnumerable<AgentSession> sessions)
    {
        if (!Enabled) return;
        foreach (var session in sessions)
        {
            if (!IsDue(session)) continue;
            lock (_gate)
            {
                if (!_attempted.Add((session.Id, session.RateLimitResetAt!.Value))) continue;
            }
            if (CreateStartInfo(session) is not { } info) continue;
            _start(session, info, Prompt);
        }
    }

    public ProcessStartInfo? CreateStartInfo(AgentSession session)
    {
        var separator = session.Id.IndexOf(':');
        // 명령줄에 들어가는 값은 GUID 형식 세션 ID와 고정 옵션뿐
        if (separator < 0 || !Guid.TryParse(session.Id[(separator + 1)..], out var guid)) return null;
        if (string.IsNullOrWhiteSpace(session.ProjectPath) || !Directory.Exists(session.ProjectPath)) return null;
        var id = guid.ToString();
        string[] args = session.AgentType == AgentType.ClaudeCode
            ? ["--resume", id, "-p", "--permission-mode", "acceptEdits"]
            : ["exec", "resume", "--skip-git-repo-check", "-c", "sandbox_mode=workspace-write", id, "-"];
        var executable = session.AgentType == AgentType.ClaudeCode
            ? FindOnPath("claude") ?? NewestExtensionBinary("anthropic.claude-code-*", Path.Combine("resources", "native-binary", "claude.exe"))
            : FindOnPath("codex") ?? NewestExtensionBinary("openai.chatgpt-*", Path.Combine("bin", "windows-x86_64", "codex.exe"));
        if (executable is null) return null;
        var info = new ProcessStartInfo
        {
            WorkingDirectory = session.ProjectPath, UseShellExecute = false, CreateNoWindow = true,
            // 출력은 대화 기록에 남으므로 받지 않음. 파이프를 물고 있으면 HUD 종료 시 재개 작업이 깨질 수 있음
            RedirectStandardInput = true, StandardInputEncoding = new UTF8Encoding(false)
        };
        // npm 설치본은 .cmd 셸 스크립트라 cmd.exe로 실행
        if (executable.EndsWith(".cmd", StringComparison.OrdinalIgnoreCase)) { info.FileName = "cmd.exe"; info.ArgumentList.Add("/c"); info.ArgumentList.Add(executable); }
        else info.FileName = executable;
        foreach (var arg in args) info.ArgumentList.Add(arg);
        return info;
    }

    private bool StartProcess(AgentSession session, ProcessStartInfo info, string prompt)
    {
        try
        {
            using var process = Process.Start(info);
            if (process is null) return false;
            process.StandardInput.Write(prompt);
            process.StandardInput.Close();
            Log($"{session.Id} pid {process.Id}: {info.FileName} {string.Join(' ', info.ArgumentList)} (cwd {info.WorkingDirectory})");
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            Log($"{session.Id}: start failed: {exception.Message}");
            return false;
        }
    }

    private void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(_logDirectory);
            lock (_gate) File.AppendAllText(Path.Combine(_logDirectory, "auto-resume.log"), $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    private static string? FindOnPath(string name)
    {
        foreach (var directory in (Environment.GetEnvironmentVariable("PATH") ?? "").Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries))
        {
            foreach (var extension in new[] { ".exe", ".cmd" })
            {
                try
                {
                    var candidate = Path.Combine(directory.Trim('"'), name + extension);
                    if (File.Exists(candidate)) return candidate;
                }
                catch (ArgumentException) { }
            }
        }
        return null;
    }

    // PATH에 없으면 VS Code 확장에 들어 있는 CLI를 사용
    private string? NewestExtensionBinary(string pattern, string relative)
    {
        var root = Path.Combine(_home, ".vscode", "extensions");
        if (!Directory.Exists(root)) return null;
        return Directory.EnumerateDirectories(root, pattern)
            .Select(directory => Path.Combine(directory, relative))
            .Where(File.Exists)
            .OrderByDescending(File.GetLastWriteTimeUtc)
            .FirstOrDefault();
    }
}
