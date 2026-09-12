using System.Drawing;
using System.Runtime.InteropServices;

namespace OAuthProbe;

internal sealed class TaskbarControls : IDisposable
{
    private const uint ThumbnailButtonClicked = 0x1800;
    private const string UnavailableMessage = "Taskbar playback buttons unavailable; menu and tray controls remain available.";

    internal const int PreviousId = 1;
    internal const int ToggleId = 2;
    internal const int NextId = 3;

    private readonly IntPtr _window;
    private readonly Action<string> _onUnavailable;
    private readonly List<IntPtr> _iconHandles = new();
    private readonly ThumbButton[] _buttons;
    private ITaskbarList3? _taskbar;
    private bool _registered;
    private bool _enabled;
    private bool _sentEnabled;
    private bool _taskbarUnavailable;
    private bool _reportedUnavailable;
    private bool _disposed;

    internal TaskbarControls(IntPtr window, Action<string> onUnavailable)
    {
        _window = window;
        _onUnavailable = onUnavailable;
        try
        {
            _buttons = CreateButtons();
            EnsureRegistered();
        }
        catch (Exception)
        {
            _buttons = Array.Empty<ThumbButton>();
            ReleaseTaskbar();
            DisposeIconHandles();
            ReportUnavailable();
        }
    }

    internal void SetEnabled(bool enabled)
    {
        if (_disposed)
            return;
        _enabled = enabled;
        EnsureRegistered();
        if (!_registered || _sentEnabled == enabled)
            return;
        try
        {
            ApplyFlags(enabled);
            _taskbar!.ThumbBarUpdateButtons(_window, (uint)_buttons.Length, _buttons);
            _sentEnabled = enabled;
        }
        catch (Exception)
        {
            MarkUnavailable();
        }
    }

    internal void Recreate()
    {
        if (_disposed)
            return;
        ReleaseTaskbar();
        _registered = false;
        _taskbarUnavailable = false;
        _reportedUnavailable = false;
        EnsureRegistered();
    }

    internal static bool TryGetCommand(IntPtr wParam, out string command)
    {
        var value = unchecked((uint)wParam.ToInt64());
        if ((value >> 16) != ThumbnailButtonClicked)
        {
            command = string.Empty;
            return false;
        }

        command = (value & 0xffff) switch
        {
            PreviousId => "previous",
            ToggleId => "toggle",
            NextId => "next",
            _ => string.Empty
        };
        return command.Length != 0;
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        _disposed = true;
        ReleaseTaskbar();
        DisposeIconHandles();
    }

    private void EnsureRegistered()
    {
        if (_disposed || _registered || _taskbarUnavailable || _buttons.Length == 0 || _window == IntPtr.Zero)
            return;
        try
        {
            _taskbar = (ITaskbarList3)(object)new TaskbarList();
            _taskbar.HrInit();
            ApplyFlags(_enabled);
            _taskbar.ThumbBarAddButtons(_window, (uint)_buttons.Length, _buttons);
            _registered = true;
            _sentEnabled = _enabled;
        }
        catch (Exception)
        {
            MarkUnavailable();
        }
    }

    private void ApplyFlags(bool enabled)
    {
        var flags = enabled ? ThumbButtonFlags.Enabled : ThumbButtonFlags.Disabled;
        for (var index = 0; index < _buttons.Length; index++)
        {
            var button = _buttons[index];
            button.dwFlags = flags;
            _buttons[index] = button;
        }
    }

    private ThumbButton[] CreateButtons()
    {
        try
        {
            var previous = CreateIcon((graphics, pen, brush) =>
            {
                graphics.DrawLine(pen, 12, 2, 4, 8);
                graphics.DrawLine(pen, 4, 8, 12, 14);
            });
            var toggle = CreateIcon((graphics, pen, brush) =>
            {
                graphics.FillPolygon(brush, [new Point(3, 2), new Point(10, 8), new Point(3, 14)]);
                graphics.FillRectangle(brush, 11, 3, 2, 10);
            });
            var next = CreateIcon((graphics, pen, brush) =>
            {
                graphics.DrawLine(pen, 4, 2, 12, 8);
                graphics.DrawLine(pen, 12, 8, 4, 14);
            });
            const ThumbButtonMask mask = ThumbButtonMask.Icon | ThumbButtonMask.Tooltip | ThumbButtonMask.Flags;
            return
            [
                new ThumbButton { dwMask = mask, iId = PreviousId, hIcon = previous, szTip = "Previous" },
                new ThumbButton { dwMask = mask, iId = ToggleId, hIcon = toggle, szTip = "Play or pause" },
                new ThumbButton { dwMask = mask, iId = NextId, hIcon = next, szTip = "Next" }
            ];
        }
        catch
        {
            DisposeIconHandles();
            throw;
        }
    }

    private IntPtr CreateIcon(Action<Graphics, Pen, Brush> draw)
    {
        using var bitmap = new Bitmap(16, 16);
        using var graphics = Graphics.FromImage(bitmap);
        using var pen = new Pen(SystemColors.ControlText, 2.2f);
        using var brush = new SolidBrush(SystemColors.ControlText);
        graphics.Clear(Color.Transparent);
        draw(graphics, pen, brush);
        var handle = bitmap.GetHicon();
        _iconHandles.Add(handle);
        return handle;
    }

    private void MarkUnavailable()
    {
        _registered = false;
        _taskbarUnavailable = true;
        ReleaseTaskbar();
        ReportUnavailable();
    }

    private void ReportUnavailable()
    {
        if (_reportedUnavailable || _disposed)
            return;
        _reportedUnavailable = true;
        _onUnavailable(UnavailableMessage);
    }


    private void ReleaseTaskbar()
    {
        if (_taskbar is null)
            return;
        try { Marshal.FinalReleaseComObject(_taskbar); }
        catch (Exception) { }
        _taskbar = null;
    }

    private void DisposeIconHandles()
    {
        foreach (var handle in _iconHandles)
            if (handle != IntPtr.Zero)
                DestroyIcon(handle);
        _iconHandles.Clear();
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyIcon(IntPtr icon);

    [ComImport]
    [Guid("56FDF344-FD6D-11d0-958A-006097C9A090")]
    private sealed class TaskbarList
    {
    }

    [ComImport]
    [Guid("EA1AFB91-9E28-4B86-90E9-9E9F8A5EECC9")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITaskbarList3
    {
        void HrInit();
        void AddTab(IntPtr hwnd);
        void DeleteTab(IntPtr hwnd);
        void ActivateTab(IntPtr hwnd);
        void SetActiveAlt(IntPtr hwnd);
        void MarkFullscreenWindow(IntPtr hwnd, [MarshalAs(UnmanagedType.Bool)] bool fullscreen);
        void SetProgressValue(IntPtr hwnd, ulong completed, ulong total);
        void SetProgressState(IntPtr hwnd, TaskbarProgressState state);
        void RegisterTab(IntPtr hwndTab, IntPtr hwndMdi);
        void UnregisterTab(IntPtr hwndTab);
        void SetTabOrder(IntPtr hwndTab, IntPtr hwndInsertBefore);
        void SetTabActive(IntPtr hwndTab, IntPtr hwndInsertBefore, uint reserved);
        void ThumbBarAddButtons(IntPtr hwnd, uint count,
            [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] ThumbButton[] buttons);
        void ThumbBarUpdateButtons(IntPtr hwnd, uint count,
            [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] ThumbButton[] buttons);
        void ThumbBarSetImageList(IntPtr hwnd, IntPtr imageList);
        void SetOverlayIcon(IntPtr hwnd, IntPtr icon, [MarshalAs(UnmanagedType.LPWStr)] string description);
        void SetThumbnailTooltip(IntPtr hwnd, [MarshalAs(UnmanagedType.LPWStr)] string tooltip);
        void SetThumbnailClip(IntPtr hwnd, ref ThumbnailClip clip);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ThumbButton
    {
        public ThumbButtonMask dwMask;
        public uint iId;
        public uint iBitmap;
        public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string szTip;
        public ThumbButtonFlags dwFlags;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct ThumbnailClip
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [Flags]
    private enum ThumbButtonMask : uint
    {
        Bitmap = 0x0001,
        Icon = 0x0002,
        Tooltip = 0x0004,
        Flags = 0x0008
    }

    [Flags]
    private enum ThumbButtonFlags : uint
    {
        Enabled = 0x0000,
        Disabled = 0x0001
    }

    private enum TaskbarProgressState : uint
    {
        NoProgress = 0x00000000,
        Indeterminate = 0x00000001,
        Normal = 0x00000002,
        Error = 0x00000004,
        Paused = 0x00000008
    }
}
