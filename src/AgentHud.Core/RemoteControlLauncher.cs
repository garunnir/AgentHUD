using System.Diagnostics;
using System.Net.NetworkInformation;
using AgentHud.Models;

namespace AgentHud;

public enum RemoteControlOutcome { NoSession, NoCli, Continued, Forked, Failed }
public sealed record RemoteControlResult(RemoteControlOutcome Outcome, AgentSession? Session = null);

// 깨어 있을 때 WoL 매직패킷을 받으면 가장 최근 Claude 세션을 Remote Control로 연다.
// 1) claude remote-control -c : 그 폴더에서 remote-control이 마지막으로 기록한 세션에 다시 붙음(약 4시간 이내 기록만, 없으면 에러로 종료)
// 2) 실패하면 claude --resume <id> --fork-session --remote-control
//    세션 파일은 살아 있는 프로세스에만 있어 최근 세션은 대개 VS Code에 열려 있으므로, 같은 대화 기록에 두 프로세스가 쓰지 않게 새 세션 ID로 갈라서 이어간다
// (Claude Code 2.1.318 --help 기준)
public sealed class RemoteControlLauncher
{
    public static readonly TimeSpan Cooldown = TimeSpan.FromMinutes(1);
    // -c가 이 시간 안에 끝나면 이어 붙일 기록이 없는 것으로 보고 fork로 넘어감
    public static readonly TimeSpan ContinueProbe = TimeSpan.FromSeconds(8);
    private readonly string _home;
    private readonly string _logDirectory;
    private readonly TimeProvider _time;
    private readonly object _gate = new();
    private Process? _process;
    private DateTimeOffset _lastTrigger = DateTimeOffset.MinValue;
    public bool Enabled { get; set; }
    /// <summary>띄운 Remote Control 프로세스가 끝났을 때(절전 방지 해제용)</summary>
    public event Action? Exited;

    public RemoteControlLauncher(string home, string logDirectory, TimeProvider? time = null)
    {
        _home = home; _logDirectory = logDirectory; _time = time ?? TimeProvider.System;
    }

    public bool IsRunning { get { lock (_gate) return IsAlive(_process); } }

    /// <summary>꺼져 있거나, 이미 띄운 프로세스가 살아 있거나, 직전 실행 후 Cooldown이 안 지났으면 false(LAN 브로드캐스트·재전송 중복 방지)</summary>
    public bool TryBegin()
    {
        lock (_gate)
        {
            var now = _time.GetUtcNow();
            if (!Enabled || IsAlive(_process) || now - _lastTrigger < Cooldown) return false;
            _lastTrigger = now;
            return true;
        }
    }

    public static AgentSession? PickTarget(IEnumerable<AgentSession> sessions) => sessions
        .Where(s => s.AgentType == AgentType.ClaudeCode && s.ParentSessionId is null && SessionGuid(s) is not null
            && !string.IsNullOrWhiteSpace(s.ProjectPath) && Directory.Exists(s.ProjectPath))
        .MaxBy(s => s.LastActivityAt);

    public ProcessStartInfo? CreateStartInfo(AgentSession session, bool fork)
    {
        // 명령줄에 들어가는 값은 GUID 형식 세션 ID와 고정 옵션뿐
        if (SessionGuid(session) is not { } id || string.IsNullOrWhiteSpace(session.ProjectPath)) return null;
        if (AutoResumer.FindClaude(_home) is not { } executable) return null;
        // 대화형으로 실행해야 하므로 콘솔 창을 띄움(GUI 앱의 자식이라 새 콘솔이 생김)
        var info = new ProcessStartInfo { WorkingDirectory = session.ProjectPath, UseShellExecute = false, CreateNoWindow = false };
        AutoResumer.SetExecutable(info, executable);
        // --remote-control은 선택적 이름 인자를 받으므로 맨 뒤에 둠
        string[] args = fork ? ["--resume", id, "--fork-session", "--remote-control"] : ["remote-control", "-c"];
        foreach (var arg in args) info.ArgumentList.Add(arg);
        return info;
    }

    /// <summary>TryBegin이 true일 때만 호출</summary>
    public async Task<RemoteControlResult> LaunchAsync(IEnumerable<AgentSession> sessions, string reason)
    {
        if (PickTarget(sessions) is not { } target) { Log($"{reason}: no Claude session"); return new(RemoteControlOutcome.NoSession); }
        if (CreateStartInfo(target, false) is not { } continueInfo || CreateStartInfo(target, true) is not { } forkInfo)
        {
            Log($"{reason}: claude CLI not found"); return new(RemoteControlOutcome.NoCli, target);
        }
        if (await StartAsync(continueInfo, target, reason)) return new(RemoteControlOutcome.Continued, target);
        if (await StartAsync(forkInfo, target, reason)) return new(RemoteControlOutcome.Forked, target);
        return new(RemoteControlOutcome.Failed, target);
    }

    // ContinueProbe 동안 살아 있으면 성공으로 보고 프로세스를 기억
    private async Task<bool> StartAsync(ProcessStartInfo info, AgentSession target, string reason)
    {
        var command = $"{info.FileName} {string.Join(' ', info.ArgumentList)} (cwd {info.WorkingDirectory})";
        Process? process;
        int quickExit;
        try { (process, quickExit) = StartInNewConsole(info); }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.ComponentModel.Win32Exception or InvalidOperationException)
        {
            Log($"{reason} {target.Id}: start failed: {exception.Message}: {command}"); return false;
        }
        if (process is null) { Log($"{reason} {target.Id}: exited with {quickExit}: {command}"); return false; }
        using var probe = new CancellationTokenSource(ContinueProbe);
        try { await process.WaitForExitAsync(probe.Token); }
        catch (OperationCanceledException)
        {
            process.EnableRaisingEvents = true;
            process.Exited += (_, _) => { Log($"{target.Id} pid {process.Id}: exited"); Exited?.Invoke(); };
            lock (_gate) { _process?.Dispose(); _process = process; }
            Log($"{reason} {target.Id} pid {process.Id}: {command}");
            return true;
        }
        Log($"{reason} {target.Id}: exited with {process.ExitCode}: {command}");
        process.Dispose();
        return false;
    }

    // Process.Start는 창 설정과 무관하게 부모의 표준 핸들을 넘겨서, HUD를 디버거(dotnet.exe)로 띄우면 claude가 파이프를 받고
    // TTY가 없어 바로 종료된다. CreateProcess로 새 콘솔을 만들고 표준 핸들은 넘기지 않는다(대화형 TUI가 필요)
    private static (Process? Process, int ExitCode) StartInNewConsole(ProcessStartInfo info)
    {
        if (!OperatingSystem.IsWindows()) { var started = Process.Start(info); return (started, 0); }
        var commandLine = string.Join(' ', new[] { info.FileName }.Concat(info.ArgumentList).Select(Quote));
        var startup = new StartupInfo { cb = System.Runtime.InteropServices.Marshal.SizeOf<StartupInfo>(), lpTitle = "Agent HUD · Claude Remote Control" };
        if (!CreateProcessW(null, new System.Text.StringBuilder(commandLine), 0, 0, false, CreateNewConsole, 0,
            string.IsNullOrEmpty(info.WorkingDirectory) ? null : info.WorkingDirectory, ref startup, out var pi))
            throw new System.ComponentModel.Win32Exception();
        try
        {
            try { return (Process.GetProcessById(pi.dwProcessId), 0); }
            // 이미 끝남: 우리가 가진 핸들로 종료 코드를 읽음
            catch (ArgumentException) { GetExitCodeProcess(pi.hProcess, out var code); return (null, (int)code); }
        }
        finally { CloseHandle(pi.hThread); CloseHandle(pi.hProcess); }
    }

    // 인자는 GUID·고정 옵션·CLI 경로뿐이라 큰따옴표가 들어가지 않음. 공백이 있으면 감싼다
    private static string Quote(string arg) => arg.Length > 0 && !arg.Any(char.IsWhiteSpace) ? arg : $"\"{arg}\"";

    private const uint CreateNewConsole = 0x00000010;
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
    private struct StartupInfo
    {
        public int cb; public string? lpReserved; public string? lpDesktop; public string? lpTitle;
        public int dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
        public short wShowWindow, cbReserved2; public nint lpReserved2, hStdInput, hStdOutput, hStdError;
    }
    [System.Runtime.InteropServices.StructLayout(System.Runtime.InteropServices.LayoutKind.Sequential)]
    private struct ProcessInformation { public nint hProcess, hThread; public int dwProcessId, dwThreadId; }
    [System.Runtime.InteropServices.DllImport("kernel32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
    private static extern bool CreateProcessW(string? applicationName, System.Text.StringBuilder commandLine, nint processAttributes, nint threadAttributes,
        bool inheritHandles, uint creationFlags, nint environment, string? currentDirectory, ref StartupInfo startupInfo, out ProcessInformation processInformation);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern bool GetExitCodeProcess(nint process, out uint exitCode);
    [System.Runtime.InteropServices.DllImport("kernel32.dll")] private static extern bool CloseHandle(nint handle);

    private static bool IsAlive(Process? process)
    {
        try { return process is { HasExited: false }; }
        catch (InvalidOperationException) { return false; }
    }

    private static string? SessionGuid(AgentSession session)
    {
        var separator = session.Id.IndexOf(':');
        return separator >= 0 && Guid.TryParse(session.Id[(separator + 1)..], out var guid) ? guid.ToString() : null;
    }

    public static IReadOnlyList<NetworkInterface> PhysicalAdapters()
    {
        try
        {
            return NetworkInterface.GetAllNetworkInterfaces()
                .Where(n => n.NetworkInterfaceType is NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet or NetworkInterfaceType.Wireless80211
                    && n.GetPhysicalAddress().GetAddressBytes() is { Length: 6 } mac && mac.Any(b => b != 0))
                .ToList();
        }
        catch (NetworkInformationException) { return []; }
    }

    private void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(_logDirectory);
            lock (_gate) File.AppendAllText(Path.Combine(_logDirectory, "remote-control.log"), $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }
}
