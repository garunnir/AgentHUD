using System.Diagnostics;
using System.Runtime.InteropServices;

namespace AgentHud.Windows;

internal static class VirtualDesktopPin
{
    [DllImport("VirtualDesktopAccessor.dll", EntryPoint = "PinWindow", CallingConvention = CallingConvention.Cdecl)]
    private static extern int PinWindow(nint window);

    [DllImport("VirtualDesktopAccessor.dll", EntryPoint = "IsPinnedWindow", CallingConvention = CallingConvention.Cdecl)]
    private static extern int IsPinnedWindow(nint window);

    public static bool TryPin(nint window)
    {
        if (window == 0) return false;
        try
        {
            if (IsPinnedWindow(window) == 1) return true;
            if (PinWindow(window) < 0)
            {
                Debug.WriteLine("HUD pinning unavailable; using virtual desktop following.");
                return false;
            }
            return IsPinnedWindow(window) == 1;
        }
        catch (Exception exception) when (exception is DllNotFoundException or EntryPointNotFoundException or BadImageFormatException)
        {
            Debug.WriteLine($"HUD pinning unavailable: {exception.Message}");
            return false;
        }
    }
}
