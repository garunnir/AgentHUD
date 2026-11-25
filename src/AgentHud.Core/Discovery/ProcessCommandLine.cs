using System.Management;

namespace AgentHud.Discovery;

// 프로세스 명령줄 조회(WMI). 명령줄은 프로세스 수명 동안 바뀌지 않으므로 (pid, 시작 시각)으로 캐시한다.
public static class ProcessCommandLine
{
    private static readonly Dictionary<(int Pid, DateTime Started), string?> Cache = [];

    public static string? Get(int pid, DateTime startedAt)
    {
        if (!OperatingSystem.IsWindows() || pid <= 0) return null;
        lock (Cache)
        {
            if (Cache.TryGetValue((pid, startedAt), out var cached)) return cached;
            if (Cache.Count > 256) Cache.Clear();
        }
        string? value = null;
        try
        {
            using var searcher = new ManagementObjectSearcher($"SELECT CommandLine FROM Win32_Process WHERE ProcessId = {pid}");
            using var results = searcher.Get();
            foreach (var item in results) using (item) value ??= item["CommandLine"] as string;
        }
        catch (ManagementException) { }
        catch (System.Runtime.InteropServices.COMException) { }
        catch (UnauthorizedAccessException) { }
        lock (Cache) Cache[(pid, startedAt)] = value;
        return value;
    }

    // `claude -p` / `--print`: 따옴표로 묶인 인자(프롬프트 문자열 등) 안의 "-p"는 무시
    public static bool IsClaudeHeadless(string? commandLine)
        => commandLine is not null && Tokens(commandLine).Skip(1).Any(x => x is "-p" or "--print" || x.StartsWith("--print=", StringComparison.Ordinal));

    private static IEnumerable<string> Tokens(string commandLine)
    {
        var current = new System.Text.StringBuilder();
        bool quoted = false, any = false;
        foreach (var c in commandLine)
        {
            if (c == '"') { quoted = !quoted; any = true; continue; }
            if (char.IsWhiteSpace(c) && !quoted)
            {
                if (any) yield return current.ToString();
                current.Clear(); any = false; continue;
            }
            current.Append(c); any = true;
        }
        if (any) yield return current.ToString();
    }
}
