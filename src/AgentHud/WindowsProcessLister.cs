using System.Diagnostics;
using System.Runtime.InteropServices;
using AgentHud.Cleanup;

namespace AgentHud;

/// <summary>
/// Windows 프로세스 수집기. 기본 경로는 WMI(Win32_Process)를 늦은 바인딩 COM(WbemScripting.SWbemLocator)으로 질의해
/// PID·부모 PID·이름·경로·명령줄·시작 시각·작업 집합을 한 번에 받는다(패키지 추가 없음).
/// WMI가 막혀 있거나 실패하면 Toolhelp32(부모 PID) + System.Diagnostics(시작 시각·메모리)로 떨어진다.
/// 이때는 명령줄이 없어 Codex 트리는 세션과 이어지지 않고 "알 수 없음"으로 남는다(보수적 동작).
/// </summary>
public sealed class WindowsProcessLister : IProcessLister
{
    /// <summary>마지막 수집에 WMI를 쓰지 못했는지(명령줄 없음). 창에서 안내 문구로 쓴다</summary>
    public bool CommandLinesMissing { get; private set; }

    public IReadOnlyList<ProcessRecord> List()
    {
        try
        {
            var wmi = FromWmi();
            if (wmi.Count > 0) { CommandLinesMissing = false; return wmi; }
        }
        catch (Exception e) when (e is COMException or InvalidOperationException or NotSupportedException or UnauthorizedAccessException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException) { }
        CommandLinesMissing = true;
        return FromToolhelp();
    }

    private static List<ProcessRecord> FromWmi()
    {
        var result = new List<ProcessRecord>();
        if (Type.GetTypeFromProgID("WbemScripting.SWbemLocator") is not { } locatorType) return result;
        dynamic? locator = Activator.CreateInstance(locatorType);
        if (locator is null) return result;
        dynamic services = locator.ConnectServer(".", "root\\cimv2");
        // ExecQuery 기본값(forward-only 아님)이면 전체를 한 번에 받는다. 필요한 열만 고른다
        dynamic processes = services.ExecQuery("SELECT ProcessId, ParentProcessId, Name, ExecutablePath, CommandLine, CreationDate, WorkingSetSize FROM Win32_Process");
        foreach (dynamic p in processes)
        {
            try
            {
                // p.ProcessId 같은 직접 IDispatch 접근은 .NET dynamic에서 두 번째 개체부터 COMException(지정되지 않은 오류)이 나서
                // Properties_.Item(...).Value로 읽는다(Windows 11, .NET 9에서 확인)
                dynamic props = p.Properties_;
                object? Prop(string name) => props.Item(name).Value;
                var pid = ToInt(Prop("ProcessId"));
                if (pid <= 0) continue;
                // WMI 스크립팅 API는 uint64를 문자열로 주므로 Convert로 받는다
                result.Add(new ProcessRecord(pid, ToInt(Prop("ParentProcessId")), Prop("Name") as string ?? "",
                    CimDateTime.Parse(Prop("CreationDate") as string) ?? DateTime.MinValue, ToLong(Prop("WorkingSetSize")),
                    Prop("CommandLine") as string, Prop("ExecutablePath") as string));
            }
            catch (Exception e) when (e is COMException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException or InvalidCastException or FormatException) { }
        }
        return result;
    }
    private static int ToInt(object? value) { try { return value is null ? 0 : Convert.ToInt32(value); } catch (Exception e) when (e is FormatException or InvalidCastException or OverflowException) { return 0; } }
    private static long ToLong(object? value) { try { return value is null ? 0 : Convert.ToInt64(value); } catch (Exception e) when (e is FormatException or InvalidCastException or OverflowException) { return 0; } }

    private static List<ProcessRecord> FromToolhelp()
    {
        var times = new Dictionary<int, (DateTime Started, long WorkingSet)>();
        foreach (var process in Process.GetProcesses())
        {
            try { times[process.Id] = (process.StartTime.ToUniversalTime(), process.WorkingSet64); }
            catch (Exception e) when (e is InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException) { }
            finally { process.Dispose(); }
        }
        var result = new List<ProcessRecord>();
        var snapshot = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0);
        if (snapshot == IntPtr.Zero || snapshot == new IntPtr(-1)) return result;
        try
        {
            var entry = new PROCESSENTRY32 { dwSize = Marshal.SizeOf<PROCESSENTRY32>() };
            for (var ok = Process32First(snapshot, ref entry); ok; ok = Process32Next(snapshot, ref entry))
            {
                var pid = (int)entry.th32ProcessID;
                if (pid <= 0) continue;
                var info = times.GetValueOrDefault(pid);
                result.Add(new ProcessRecord(pid, (int)entry.th32ParentProcessID, entry.szExeFile ?? "", info.Started, info.WorkingSet));
            }
        }
        finally { CloseHandle(snapshot); }
        return result;
    }

    /// <summary>PID 하나만 다시 읽는다(종료 직전 PID 재사용 확인용). 명령줄은 필요 없다</summary>
    public static ProcessRecord? Read(int pid)
    {
        try
        {
            using var process = Process.GetProcessById(pid);
            return new ProcessRecord(pid, 0, process.ProcessName, process.StartTime.ToUniversalTime(), process.WorkingSet64);
        }
        catch (Exception e) when (e is ArgumentException or InvalidOperationException or System.ComponentModel.Win32Exception or NotSupportedException) { return null; }
    }

    private const uint TH32CS_SNAPPROCESS = 0x00000002;
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct PROCESSENTRY32
    {
        public int dwSize;
        public uint cntUsage, th32ProcessID;
        public IntPtr th32DefaultHeapID;
        public uint th32ModuleID, cntThreads, th32ParentProcessID;
        public int pcPriClassBase;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile;
    }
    [DllImport("kernel32.dll", SetLastError = true)] private static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Process32First(IntPtr snapshot, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern bool Process32Next(IntPtr snapshot, ref PROCESSENTRY32 entry);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool CloseHandle(IntPtr handle);
}
