using System.Runtime.InteropServices;

namespace AgentHud.Windows;

// 세션이 작업 중일 때 시스템 절전 진입과 화면 꺼짐을 막음. 호출한 스레드(UI)에서만 해제 가능
public static class SleepInhibitor
{
    private const uint Continuous = 0x80000000, SystemRequired = 0x00000001, DisplayRequired = 0x00000002;
    [DllImport("kernel32.dll")] private static extern uint SetThreadExecutionState(uint flags);
    private static bool _on;
    public static void Set(bool on)
    {
        if (on == _on) return;
        SetThreadExecutionState(on ? Continuous | SystemRequired | DisplayRequired : Continuous);
        _on = on;
    }
}
