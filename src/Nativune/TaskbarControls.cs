using System.Drawing;
using System.Runtime.InteropServices;

namespace Nativune;

internal sealed class TaskbarControls : IDisposable
{
    private const uint ThumbnailButtonClicked = 0x1800;
    private const string UnavailableMessage =
        "Taskbar playback buttons unavailable; menu and tray controls remain available.";

    internal const int PreviousId = 1;
    internal const int ToggleId = 2;
    internal const int NextId = 3;

    private readonly nint _window;
    private readonly Action<string> _onUnavailable;
    private readonly NativeIconCache _icons;
    private List<nint> _iconHandles = new();
    private ThumbButton[] _buttons = Array.Empty<ThumbButton>();
    private ITaskbarList3? _taskbar;
    private bool _registered;
    private bool _enabled;
    private bool _sentEnabled;
    private bool _taskbarUnavailable;
    private bool _reportedUnavailable;
    private bool _disposed;

    internal TaskbarControls(
        nint window,
        Action<string> onUnavailable,
        NativeIconCache icons,
        int dpi,
        Color iconColor)
    {
        ArgumentNullException.ThrowIfNull(onUnavailable);
        ArgumentNullException.ThrowIfNull(icons);
        _window = window;
        _onUnavailable = onUnavailable;
        _icons = icons;

        if (_window == 0 || !IsWindow(_window))
        {
            ReportUnavailable(new ArgumentException("The taskbar owner window is not valid.", nameof(window)));
            return;
        }

        try
        {
            _buttons = CreateButtons(dpi, iconColor, out var handles);
            _iconHandles = handles;
            EnsureRegistered();
        }
        catch (Exception ex)
        {
            ReleaseTaskbar();
            DisposeIconHandles();
            _buttons = Array.Empty<ThumbButton>();
            MarkUnavailable(ex);
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
            ApplyFlags(_buttons, enabled);
            _taskbar!.ThumbBarUpdateButtons(_window, (uint)_buttons.Length, _buttons);
            _sentEnabled = enabled;
        }
        catch (Exception ex)
        {
            MarkUnavailable(ex);
        }
    }

    internal void UpdateAppearance(int dpi, Color iconColor)
    {
        if (_disposed || _buttons.Length == 0)
            return;

        List<nint>? replacementHandles = null;
        try
        {
            var replacement = CreateButtons(dpi, iconColor, out var createdHandles);
            replacementHandles = createdHandles;
            ApplyFlags(replacement, _enabled);
            if (_registered)
            {
                try
                {
                    _taskbar!.ThumbBarUpdateButtons(_window, (uint)replacement.Length, replacement);
                }
                catch (Exception ex)
                {
                    DisposeIconHandles(replacementHandles);
                    replacementHandles = null;
                    MarkUnavailable(ex);
                    return;
                }
            }

            var previousHandles = _iconHandles;
            _buttons = replacement;
            _iconHandles = replacementHandles!;
            replacementHandles = null;
            DisposeIconHandles(previousHandles);
        }
        catch (Exception ex)
        {
            if (replacementHandles is not null)
                DisposeIconHandles(replacementHandles);
            MarkUnavailable(ex);
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

    internal static bool TryGetCommand(nint wParam, out string command)
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
        if (_disposed || _registered || _taskbarUnavailable || _buttons.Length == 0)
            return;
        if (_window == 0 || !IsWindow(_window))
        {
            MarkUnavailable(new InvalidOperationException("The taskbar owner window is no longer valid."));
            return;
        }

        try
        {
            _taskbar = (ITaskbarList3)(object)new TaskbarList();
            _taskbar.HrInit();
            ApplyFlags(_buttons, _enabled);
            _taskbar.ThumbBarAddButtons(_window, (uint)_buttons.Length, _buttons);
            _registered = true;
            _sentEnabled = _enabled;
        }
        catch (Exception ex)
        {
            MarkUnavailable(ex);
        }
    }

    private static void ApplyFlags(ThumbButton[] buttons, bool enabled)
    {
        var flags = enabled ? ThumbButtonFlags.Enabled : ThumbButtonFlags.Disabled;
        for (var index = 0; index < buttons.Length; index++)
        {
            var button = buttons[index];
            button.dwFlags = flags;
            buttons[index] = button;
        }
    }

    private ThumbButton[] CreateButtons(int dpi, Color iconColor, out List<nint> handles)
    {
        handles = new List<nint>(3);
        try
        {
            var previous = CreateIcon("previous", dpi, iconColor, handles);
            var toggle = CreateIcon("play-pause", dpi, iconColor, handles);
            var next = CreateIcon("next", dpi, iconColor, handles);
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
            DisposeIconHandles(handles);
            throw;
        }
    }

    private nint CreateIcon(string name, int dpi, Color iconColor, List<nint> handles)
    {
        if (dpi is < 48 or > 768)
            throw new ArgumentOutOfRangeException(nameof(dpi), "DPI must be between 48 and 768.");
        if (iconColor.IsEmpty)
            throw new ArgumentException("A concrete tint color is required.", nameof(iconColor));

        var pixelSize = Math.Clamp(
            (int)Math.Round(16d * dpi / 96d, MidpointRounding.AwayFromZero), 16, 256);
        var handle = _icons.CreateOwnedIcon(name, pixelSize, iconColor);
        if (handle == 0)
            throw new InvalidOperationException($"Native taskbar icon creation failed: {name}.");
        try
        {
            handles.Add(handle);
            return handle;
        }
        catch
        {
            DestroyOwnedIcon(handle);
            throw;
        }
    }

    private void MarkUnavailable(Exception? reason = null)
    {
        _registered = false;
        _taskbarUnavailable = true;
        ReleaseTaskbar();
        ReportUnavailable(reason);
    }

    private void ReportUnavailable(Exception? reason = null)
    {
        if (_reportedUnavailable || _disposed)
            return;
        _reportedUnavailable = true;
        var detail = reason?.Message;
        _onUnavailable(string.IsNullOrWhiteSpace(detail)
            ? UnavailableMessage
            : $"{UnavailableMessage} ({detail})");
    }

    private void ReleaseTaskbar()
    {
        if (_taskbar is null)
            return;
        var taskbar = _taskbar;
        _taskbar = null;
        try
        {
            Marshal.FinalReleaseComObject(taskbar);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Taskbar COM cleanup failed: {ex.Message}");
        }
    }

    private void DisposeIconHandles()
    {
        DisposeIconHandles(_iconHandles);
    }

    private static void DisposeIconHandles(List<nint> handles)
    {
        Exception? failure = null;
        foreach (var handle in handles)
        {
            if (handle == 0)
                continue;
            try
            {
                DestroyOwnedIcon(handle);
            }
            catch (Exception ex)
            {
                failure ??= ex;
                Console.Error.WriteLine($"Taskbar icon cleanup failed: {ex.Message}");
            }
        }
        handles.Clear();
        if (failure is not null)
            Console.Error.WriteLine($"One or more taskbar icons could not be released: {failure.Message}");
    }

    private static void DestroyOwnedIcon(nint icon)
    {
        if (icon == 0)
            return;
        try
        {
            NativeIconCache.DestroyIcon(icon);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine($"Taskbar icon cleanup failed: {ex.Message}");
        }
    }
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindow(nint window);

    [ComImport]
    [Guid("56FDF344-FD6D-11d0-958A-006097C9A090")]
    private sealed class TaskbarList
    {
    }

    [ComImport]
    [Guid("EA1AFB91-9E28-4B86-90E9-9E9F8A5EEFAF")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ITaskbarList3
    {
        void HrInit();
        void AddTab(nint hwnd);
        void DeleteTab(nint hwnd);
        void ActivateTab(nint hwnd);
        void SetActiveAlt(nint hwnd);
        void MarkFullscreenWindow(nint hwnd, [MarshalAs(UnmanagedType.Bool)] bool fullscreen);
        void SetProgressValue(nint hwnd, ulong completed, ulong total);
        void SetProgressState(nint hwnd, TaskbarProgressState state);
        void RegisterTab(nint hwndTab, nint hwndMdi);
        void UnregisterTab(nint hwndTab);
        void SetTabOrder(nint hwndTab, nint hwndInsertBefore);
        void SetTabActive(nint hwndTab, nint hwndInsertBefore, uint reserved);
        void ThumbBarAddButtons(nint hwnd, uint count,
            [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] ThumbButton[] buttons);
        void ThumbBarUpdateButtons(nint hwnd, uint count,
            [In, MarshalAs(UnmanagedType.LPArray, SizeParamIndex = 1)] ThumbButton[] buttons);
        void ThumbBarSetImageList(nint hwnd, nint imageList);
        void SetOverlayIcon(nint hwnd, nint icon, [MarshalAs(UnmanagedType.LPWStr)] string description);
        void SetThumbnailTooltip(nint hwnd, [MarshalAs(UnmanagedType.LPWStr)] string tooltip);
        void SetThumbnailClip(nint hwnd, ref ThumbnailClip clip);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ThumbButton
    {
        public ThumbButtonMask dwMask;
        public uint iId;
        public uint iBitmap;
        public nint hIcon;
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
