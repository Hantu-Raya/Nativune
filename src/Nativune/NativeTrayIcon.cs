using System.ComponentModel;
using System.Drawing;
using System.Runtime.InteropServices;

namespace Nativune;

internal sealed class NativeTrayIcon : IDisposable
{
    // WM_APP is private to the owning window. The value is intentionally not a shell
    // notification so remote page content can never trigger tray commands directly.
    internal const uint CallbackMessage = 0x8042;

    private const uint IconId = 1;
    private const uint NimAdd = 0x00000000;
    private const uint NimDelete = 0x00000002;
    private const uint NimModify = 0x00000001;
    private const uint NimSetVersion = 0x00000004;
    private const uint NifMessage = 0x00000001;
    private const uint NifIcon = 0x00000002;
    private const uint NifTip = 0x00000004;
    private const uint NifInfo = 0x00000010;
    private const uint NiifError = 0x00000003;
    private const uint NotifyIconVersion4 = 4;

    private const uint WmContextMenu = 0x007B;
    private const uint WmLButtonDblClk = 0x0203;
    private const uint WmRButtonUp = 0x0205;
    private const uint NinSelect = 0x0400;
    private const uint NinKeySelect = 0x0401;
    private const uint WmNull = 0x0000;

    private const uint MfString = 0x00000000;
    private const uint MfSeparator = 0x00000800;
    private const uint MfDisabled = 0x00000002;
    private const uint MfGrayed = 0x00000001;
    private const uint TpmReturnCmd = 0x00000100;
    private const uint TpmNonotify = 0x00000080;
    private const uint TpmRightButton = 0x00000002;

    private const uint ShowId = 0x5101;
    private const uint ToggleId = 0x5103;
    private const uint PreviousId = 0x5104;
    private const uint NextId = 0x5105;
    private const uint TimerId = 0x5106;
    private const uint QuitId = 0x5107;

    private const int ErrorFileNotFound = 2;
    private const int ErrorNotFound = 1168;

    private readonly nint _window;
    private readonly NativeIconCache _icons;
    private readonly Action<string> _onCommand;
    private nint _icon;
    private bool _visible;
    private bool _playbackEnabled;
    private string _tooltip = "Nativune";
    private bool _disposed;
    private bool _menuShowing;

    internal NativeTrayIcon(nint window, NativeIconCache icons, Action<string> onCommand)
    {
        ArgumentNullException.ThrowIfNull(icons);
        ArgumentNullException.ThrowIfNull(onCommand);
        if (window == 0 || !IsWindow(window))
            throw new ArgumentException("A live HWND is required for a native tray icon.", nameof(window));

        _window = window;
        _icons = icons;
        _onCommand = onCommand;
    }
    internal bool IsVisible => !_disposed && _visible;

    internal void SetVisible(bool visible)
    {
        ThrowIfDisposed();
        if (visible == _visible)
            return;

        if (visible)
            AddIcon();
        else
            RemoveIcon(tolerateMissing: false);
    }

    internal void SetPlaybackEnabled(bool enabled)
    {
        ThrowIfDisposed();
        _playbackEnabled = enabled;
    }
    public bool SetTooltip(string text)
    {
        if (_disposed || text is null) return false;
        _tooltip = text.Length > 127 ? text[..127] : text;
        if (!_visible) return true;
        try
        {
            var data = CreateData(NifTip);
            return Shell_NotifyIcon(NimModify, ref data);
        }
        catch (Exception) { return false; }
    }

    public bool ShowBalloon(string title, string text)
    {
        if (_disposed || title is null || text is null) return false;
        if (!_visible) return false;
        try
        {
            var data = CreateData(NifInfo);
            data.szInfoTitle = Truncate(title, 63);
            data.szInfo = Truncate(text, 255);
            data.dwInfoFlags = NiifError;
            return Shell_NotifyIcon(NimModify, ref data);
        }
        catch (Exception) { return false; }
    }

    private static string Truncate(string value, int length)
        => value.Length <= length ? value : value[..length];

    internal void Recreate()
    {
        ThrowIfDisposed();
        if (!_visible)
            return;

        RemoveIcon(tolerateMissing: true);
        AddIcon();
    }

    internal bool HandleMessage(uint message, nint wParam, nint lParam, out nint result)
    {
        result = 0;
        if (_disposed || !_visible || message != CallbackMessage)
            return false;

        // NOTIFYICON_VERSION_4 packs the icon ID into HIWORD(lParam), the
        // notification into LOWORD(lParam), and signed screen-anchor
        // coordinates into wParam.
        var packedNotification = unchecked((uint)lParam.ToInt64());
        if ((packedNotification >> 16) != IconId)
            return false;
        var notification = packedNotification & 0xffff;
        switch (notification)
        {
            // Version 4 can deliver WM_RBUTTONUP before WM_CONTEXTMENU. Consume the
            // legacy notification so it cannot open a second tracked popup.
            case WmRButtonUp:
                return true;
            case WmContextMenu:
                // TrackPopupMenuEx runs a nested message loop; ignore reentrant
                // context-menu callbacks while the first popup is still active.
                if (_menuShowing)
                    return true;
                _menuShowing = true;
                try
                {
                    ShowContextMenu(wParam);
                }
                finally
                {
                    _menuShowing = false;
                }
                return true;
            case WmLButtonDblClk:
            case NinSelect:
            case NinKeySelect:
                _onCommand("show");
                return true;
            default:
                return false;
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;

        Exception? failure = null;
        try
        {
            if (_visible)
                RemoveIcon(tolerateMissing: true);
        }
        catch (Exception ex)
        {
            failure = ex;
        }

        try
        {
            if (_icon != 0)
                NativeIconCache.DestroyIcon(_icon);
        }
        catch (Exception ex)
        {
            failure ??= ex;
        }
        finally
        {
            _icon = 0;
            _visible = false;
            _disposed = true;
        }
        if (failure is not null)
            throw failure;
    }


    private void AddIcon()
    {
        EnsureIcon();
        var data = CreateData(NifMessage | NifIcon | NifTip);
        if (!Shell_NotifyIcon(NimAdd, ref data))
            throw LastWin32Failure("Windows rejected the native tray icon.");
        _visible = true;

        data.uVersionOrTimeout = NotifyIconVersion4;
        if (!Shell_NotifyIcon(NimSetVersion, ref data))
        {
            var versionFailure = LastWin32Failure("Windows rejected the native tray icon protocol version.");
            try
            {
                RemoveIcon(tolerateMissing: true);
            }
            catch (Exception cleanupFailure)
            {
                Console.Error.WriteLine(
                    $"Tray icon rollback failed ({cleanupFailure.GetType().Name}).");
            }
            throw versionFailure;
        }
    }

    private void RemoveIcon(bool tolerateMissing)
    {
        var data = CreateData(NifMessage | NifIcon | NifTip);
        if (Shell_NotifyIcon(NimDelete, ref data))
        {
            _visible = false;
            return;
        }

        var error = Marshal.GetLastWin32Error();
        if (tolerateMissing && (error == 0 || error == ErrorFileNotFound || error == ErrorNotFound))
        {
            _visible = false;
            return;
        }

        throw error == 0
            ? new InvalidOperationException("Windows did not remove the native tray icon.")
            : new Win32Exception(error, "Windows did not remove the native tray icon.");
    }

    private void EnsureIcon()
    {
        if (_icon != 0)
            return;
        // The colour app icon; the white glyph remains a fallback if the icon file is missing.
        _icon = AppIcon.LoadSmallIcon();
        if (_icon == 0)
            _icon = _icons.CreateOwnedIcon("app-mark", 32, Color.White);
        if (_icon == 0)
            throw new InvalidOperationException("Native tray icon creation failed.");
    }

    private void ShowContextMenu(nint packedAnchor)
    {
        var packed = unchecked((uint)packedAnchor.ToInt64());
        var x = (short)(packed & 0xffff);
        var y = (short)(packed >> 16);
        Point point;
        if (x == -1 && y == -1)
        {
            if (!GetCursorPos(out point))
                throw LastWin32Failure("Windows did not provide a tray-menu position.");
        }
        else
        {
            point = new Point(x, y);
        }

        var menu = CreatePopupMenu();
        if (menu == 0)
            throw LastWin32Failure("Windows did not create the native tray menu.");

        try
        {
            AddMenuItem(menu, ShowId, "Show");
            AddSeparator(menu);
            var playbackFlags = _playbackEnabled ? MfString : MfString | MfDisabled | MfGrayed;
            AddMenuItem(menu, ToggleId, "Play or pause", playbackFlags);
            AddMenuItem(menu, PreviousId, "Previous", playbackFlags);
            AddMenuItem(menu, NextId, "Next", playbackFlags);
            AddSeparator(menu);
            AddMenuItem(menu, TimerId, "Pause timer");
            AddMenuItem(menu, QuitId, "Quit");
            if (!SetForegroundWindow(_window))
                Console.Error.WriteLine(
                    $"Tray menu owner could not be foregrounded: {Marshal.GetLastWin32Error()}.");
            var selected = TrackPopupMenuEx(
                menu,
                TpmReturnCmd | TpmNonotify | TpmRightButton,
                point.X,
                point.Y,
                _window,
                0);
            if (selected != 0)
                DispatchMenuCommand(selected);
            if (!PostMessage(_window, WmNull, 0, 0) && IsWindow(_window))
                Console.Error.WriteLine(
                    $"Tray menu dismissal message failed: {Marshal.GetLastWin32Error()}.");
        }
        finally
        {
            if (!DestroyMenu(menu))
                Console.Error.WriteLine($"Tray menu cleanup failed: {Marshal.GetLastWin32Error()}.");
        }
    }

    private void DispatchMenuCommand(uint command)
    {
        var name = command switch
        {
            ShowId => "show",
            ToggleId when _playbackEnabled => "toggle",
            PreviousId when _playbackEnabled => "previous",
            NextId when _playbackEnabled => "next",
            TimerId => "timer",
            QuitId => "quit",
            _ => null
        };
        if (name is not null)
            _onCommand(name);
    }

    private static void AddMenuItem(nint menu, uint id, string text, uint flags = MfString)
    {
        if (!AppendMenu(menu, flags, id, text))
            throw LastWin32Failure($"Windows did not add the tray menu item '{text}'.");
    }

    private static void AddSeparator(nint menu)
    {
        if (!AppendMenu(menu, MfSeparator, 0, string.Empty))
            throw LastWin32Failure("Windows did not add the tray menu separator.");
    }

    private NotifyIconData CreateData(uint flags) => new()
    {
        cbSize = (uint)Marshal.SizeOf<NotifyIconData>(),
        hWnd = _window,
        uID = IconId,
        uFlags = flags,
        uCallbackMessage = CallbackMessage,
        hIcon = _icon,
        szTip = _tooltip,
        szInfo = string.Empty,
        szInfoTitle = string.Empty,
        guidItem = Guid.Empty
    };

    private static Exception LastWin32Failure(string message)
    {
        var error = Marshal.GetLastWin32Error();
        return error == 0 ? new InvalidOperationException(message) : new Win32Exception(error, message);
    }

    private void ThrowIfDisposed() => ObjectDisposedException.ThrowIf(_disposed, this);

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool Shell_NotifyIcon(uint message, ref NotifyIconData data);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreatePopupMenu")]
    private static extern nint CreatePopupMenu();

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "DestroyMenu")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyMenu(nint menu);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "AppendMenuW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AppendMenu(nint menu, uint flags, nuint itemId, string text);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint TrackPopupMenuEx(
        nint menu,
        uint flags,
        int x,
        int y,
        nint owner,
        nint parameters);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetCursorPos(out Point point);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetForegroundWindow(nint window);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(nint window, uint message, nint wParam, nint lParam);

    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindow(nint window);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct NotifyIconData
    {
        public uint cbSize;
        public nint hWnd;
        public uint uID;
        public uint uFlags;
        public uint uCallbackMessage;
        public nint hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string szTip;
        public uint dwState;
        public uint dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)]
        public string szInfo;
        public uint uVersionOrTimeout;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)]
        public string szInfoTitle;
        public uint dwInfoFlags;
        public Guid guidItem;
        public nint hBalloonIcon;
    }
}
