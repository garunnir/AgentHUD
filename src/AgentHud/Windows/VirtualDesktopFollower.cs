using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Windows.Threading;

namespace AgentHud.Windows;

// Runs on the window's STA dispatcher, after the window has been shown.
internal sealed class VirtualDesktopFollower : IDisposable
{
    private readonly nint _window;
    private readonly DispatcherTimer _timer;
    private IVirtualDesktopManager? _manager;
    private long _nextPinAttempt;
    private bool _pinned;

    public VirtualDesktopFollower(nint window)
    {
        _window = window;
        _timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
        _timer.Tick += OnTick;
        _timer.Start();
        OnTick(this, EventArgs.Empty);
    }

    private void OnTick(object? sender, EventArgs e)
    {
        if (Environment.TickCount64 >= _nextPinAttempt)
        {
            _pinned = VirtualDesktopPin.TryPin(_window);
            _nextPinAttempt = Environment.TickCount64 + 5000;
        }
        if (_pinned) return;

        try
        {
            _manager ??= (IVirtualDesktopManager)Activator.CreateInstance(
                Type.GetTypeFromCLSID(new Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A"), true)!)!;
            if (_manager.IsWindowOnCurrentVirtualDesktop(_window, out var current) < 0 || current) return;

            var foreground = GetForegroundWindow();
            if (foreground == 0 || foreground == _window) return;
            // Ignore stale foreground handles during a desktop-switch animation.
            if (_manager.IsWindowOnCurrentVirtualDesktop(foreground, out current) < 0 || !current) return;
            if (_manager.GetWindowDesktopId(foreground, out var desktop) < 0 || desktop == Guid.Empty) return;
            var result = _manager.MoveWindowToDesktop(_window, ref desktop);
            if (result < 0) Debug.WriteLine($"HUD desktop follow failed: 0x{result:X8}");
        }
        catch (COMException exception)
        {
            Debug.WriteLine($"HUD desktop manager unavailable: {exception.Message}");
            ReleaseManager();
        }
    }

    public void Dispose()
    {
        _timer.Stop();
        _timer.Tick -= OnTick;
        ReleaseManager();
    }

    private void ReleaseManager()
    {
        if (_manager is not null) Marshal.ReleaseComObject(_manager);
        _manager = null;
    }

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();

    [ComImport, Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IVirtualDesktopManager
    {
        [PreserveSig] int IsWindowOnCurrentVirtualDesktop(nint window, [MarshalAs(UnmanagedType.Bool)] out bool current);
        [PreserveSig] int GetWindowDesktopId(nint window, out Guid desktop);
        [PreserveSig] int MoveWindowToDesktop(nint window, ref Guid desktop);
    }
}
