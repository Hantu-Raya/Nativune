using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Input;
using Windows.Graphics;


namespace Nativune;

internal delegate bool NativeMessageHandler(
    uint message,
    nint wParam,
    nint lParam,
    out nint result);

internal sealed class NativeWindowServices : IDisposable
{
    private const uint WmNcCalcSize = 0x0083;
    private const uint WmNcHitTest = 0x0084;
    private const int HtLeft = 10;
    private const int HtRight = 11;
    private const int HtTop = 12;
    private const int HtTopLeft = 13;
    private const int HtTopRight = 14;
    private const int HtBottom = 15;
    private const int HtBottomLeft = 16;
    private const int HtBottomRight = 17;
    private const int SmCxSizeFrame = 32;
    private const int SmCySizeFrame = 33;
    private const int SmCxPaddedBorder = 92;
    private const uint WmSize = 0x0005;
    private const uint WmDpiChanged = 0x02E0;

    private static long _nextSubclassId;
    private static readonly NonClientRegionKind[] CaptionlessFrameRegions =
    [
        NonClientRegionKind.TopBorder,
        NonClientRegionKind.LeftBorder,
        NonClientRegionKind.BottomBorder,
        NonClientRegionKind.RightBorder,
        NonClientRegionKind.Caption
    ];

    private readonly nint _window;
    private readonly NativeMessageHandler _handler;
    private readonly nuint _subclassId;
    private SubclassProc? _subclassProc;
    private bool _installed;
    private bool _disposed;
    private InputNonClientPointerSource? _nonClientPointerSource;
    private bool _captionlessResizeFrame;
    private bool _compactUpdateVisible;


    internal NativeWindowServices(nint window, NativeMessageHandler handler)
    {
        ArgumentNullException.ThrowIfNull(handler);
        if (window == 0 || !IsWindow(window))
            throw new ArgumentException("A live HWND is required for native message routing.", nameof(window));

        _window = window;
        _handler = handler;
        var id = Interlocked.Increment(ref _nextSubclassId);
        if (id <= 0)
            throw new InvalidOperationException("The native HWND subclass identifier is exhausted.");
        _subclassId = unchecked((nuint)id);
        _subclassProc = Dispatch;

        if (!SetWindowSubclass(_window, _subclassProc, _subclassId, 0))
        {
            var error = Marshal.GetLastWin32Error();
            _subclassProc = null;
            throw error == 0
                ? new InvalidOperationException("Windows rejected the native HWND subclass.")
                : new Win32Exception(error, "Windows rejected the native HWND subclass.");
        }
        _installed = true;
    }

    internal void SetCaptionlessResizeFrame(bool enabled)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);

        if (!enabled)
        {
            _captionlessResizeFrame = false;
            ClearCaptionlessResizeRegions();
            return;
        }

        var source = _nonClientPointerSource ??= InputNonClientPointerSource.GetForWindowId(
            Win32Interop.GetWindowIdFromWindow(_window));
        try
        {
            ApplyCaptionlessResizeRegions(source);
            _captionlessResizeFrame = true;
        }
        catch
        {
            _captionlessResizeFrame = false;
            try
            {
                ClearCaptionlessResizeRegions(source);
            }
            catch (Exception cleanupFailure)
            {
                Console.Error.WriteLine(
                    $"Captionless resize region rollback failed ({cleanupFailure.GetType().Name}).");
            }
            throw;
        }
    }

    /// <summary>
    /// Tells the drag-region planner whether Compact shows its Update button, so the caption never
    /// covers it; regions are re-applied at once while the captionless frame is active.
    /// </summary>
    internal void SetCompactUpdateVisible(bool visible)
    {
        if (_disposed || _compactUpdateVisible == visible) return;
        _compactUpdateVisible = visible;
        if (_captionlessResizeFrame && _nonClientPointerSource is not null)
            RefreshCaptionlessResizeRegions(WmSize);
    }

    private void ApplyCaptionlessResizeRegions(InputNonClientPointerSource source)
    {
        var client = default(NativeRect);
        if (!GetClientRect(_window, ref client))
            throw LastWin32Failure("Windows did not provide the captionless client bounds.");

        var width = Math.Max(0, client.Right - client.Left);
        var height = Math.Max(0, client.Bottom - client.Top);
        if (width == 0 || height == 0)
        {
            ClearCaptionlessResizeRegions(source);
            return;
        }

        var dpi = GetDpiForWindow(_window);
        if (dpi == 0)
            dpi = 96;
        var horizontalBorder = Math.Clamp(
            GetSystemMetricsForDpi(SmCxSizeFrame, dpi)
                + GetSystemMetricsForDpi(SmCxPaddedBorder, dpi),
            1,
            width);
        var verticalBorder = Math.Clamp(
            GetSystemMetricsForDpi(SmCySizeFrame, dpi)
                + GetSystemMetricsForDpi(SmCxPaddedBorder, dpi),
            1,
            height);

        source.SetRegionRects(NonClientRegionKind.TopBorder,
            [new RectInt32(0, 0, width, verticalBorder)]);
        source.SetRegionRects(NonClientRegionKind.LeftBorder,
            [new RectInt32(0, 0, horizontalBorder, height)]);
        source.SetRegionRects(NonClientRegionKind.BottomBorder,
            [new RectInt32(0, height - verticalBorder, width, verticalBorder)]);
        source.SetRegionRects(NonClientRegionKind.RightBorder,
            [new RectInt32(width - horizontalBorder, 0, horizontalBorder, height)]);

        var clientRight = Math.Max(horizontalBorder, width - horizontalBorder);
        var clientBottom = Math.Max(verticalBorder, height - verticalBorder);
        var captionRects = new List<RectInt32>(4);
        foreach (var region in CompactCaptionRegions(width, height, dpi, _compactUpdateVisible))
        {
            var left = Math.Clamp(region.X, horizontalBorder, clientRight);
            var top = Math.Clamp(region.Y, verticalBorder, clientBottom);
            var right = Math.Clamp(region.X + region.Width, horizontalBorder, clientRight);
            var bottom = Math.Clamp(region.Y + region.Height, verticalBorder, clientBottom);
            if (right > left && bottom > top)
                captionRects.Add(new RectInt32(left, top, right - left, bottom - top));
        }

        if (captionRects.Count == 0)
            source.ClearRegionRects(NonClientRegionKind.Caption);
        else
            source.SetRegionRects(NonClientRegionKind.Caption, captionRects.ToArray());
    }

    /// <summary>
    /// Drag (caption) rectangles in client pixels for a Compact client of the given pixel size. The
    /// rectangles come from the same planner that positions the Compact controls, so every interactive
    /// control stays outside them at every size class and DPI.
    /// </summary>
    internal static IReadOnlyList<RectInt32> CompactCaptionRegions(int width, int height, uint dpi,
        bool updateVisible = false)
    {
        var scale = dpi / 96d;
        var plan = CompactPlayerView.PlanLayout(width / scale, height / scale, scale, statusVisible: false,
            updateVisible);
        var regions = new List<RectInt32>(plan.CaptionRegions.Count);
        foreach (var region in plan.CaptionRegions)
        {
            var left = DipToPixels(region.X, scale);
            var top = DipToPixels(region.Y, scale);
            var right = DipToPixels(region.Right, scale);
            var bottom = DipToPixels(region.Bottom, scale);
            if (right > left && bottom > top)
                regions.Add(new RectInt32(left, top, right - left, bottom - top));
        }
        return regions;
    }

    private static int DipToPixels(double dip, double scale)
        => (int)Math.Clamp(Math.Round(dip * scale, MidpointRounding.AwayFromZero), 0d, int.MaxValue);

    private void ClearCaptionlessResizeRegions()
    {
        var source = _nonClientPointerSource;
        if (source is null)
            return;
        ClearCaptionlessResizeRegions(source);
        _nonClientPointerSource = null;
    }

    private static void ClearCaptionlessResizeRegions(InputNonClientPointerSource source)
    {
        Exception? failure = null;
        foreach (var region in CaptionlessFrameRegions)
        {
            try
            {
                source.ClearRegionRects(region);
            }
            catch (Exception ex)
            {
                failure ??= ex;
            }
        }

        if (failure is not null)
            throw failure;
    }

    private void RefreshCaptionlessResizeRegions(uint message)
    {
        if (!_captionlessResizeFrame
            || message is not (WmSize or WmDpiChanged)
            || _nonClientPointerSource is not { } source)
            return;
        try
        {
            ApplyCaptionlessResizeRegions(source);
        }
        catch (Exception ex)
        {
            _captionlessResizeFrame = false;
            try { ClearCaptionlessResizeRegions(source); }
            catch (Exception cleanupFailure)
            {
                Console.Error.WriteLine(
                    $"Captionless region refresh rollback failed ({cleanupFailure.GetType().Name}).");
            }
            Console.Error.WriteLine(
                $"Captionless resize regions could not be refreshed ({ex.GetType().Name}).");
        }
    }

    internal static bool TryHandleCaptionlessResizeFrame(
        nint window,
        uint message,
        nint wParam,
        nint lParam,
        out nint result)
    {
        result = 0;
        if (window == 0 || !IsWindow(window))
            return false;

        if (message == WmNcCalcSize && wParam != 0)
            return true;
        if (message != WmNcHitTest)
            return false;

        var nativeRect = default(NativeRect);
        if (!GetWindowRect(window, ref nativeRect))
            return false;

        var dpi = GetDpiForWindow(window);
        var edgeX = Math.Max(4, GetSystemMetricsForDpi(SmCxSizeFrame, dpi)
            + GetSystemMetricsForDpi(SmCxPaddedBorder, dpi));
        var edgeY = Math.Max(4, GetSystemMetricsForDpi(SmCySizeFrame, dpi)
            + GetSystemMetricsForDpi(SmCxPaddedBorder, dpi));
        var x = unchecked((short)(lParam.ToInt64() & 0xffff));
        var y = unchecked((short)((lParam.ToInt64() >> 16) & 0xffff));
        var left = x < nativeRect.Left + edgeX;
        var right = x >= nativeRect.Right - edgeX;
        var top = y < nativeRect.Top + edgeY;
        var bottom = y >= nativeRect.Bottom - edgeY;
        if (!left && !right && !top && !bottom)
            return false;

        result = left
            ? top ? HtTopLeft : bottom ? HtBottomLeft : HtLeft
            : right
                ? top ? HtTopRight : bottom ? HtBottomRight : HtRight
                : top ? HtTop : HtBottom;
        return true;
    }




    public void Dispose()
    {
        if (_disposed)
            return;

        _captionlessResizeFrame = false;
        try
        {
            ClearCaptionlessResizeRegions();
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(
                $"Captionless resize region cleanup failed ({ex.GetType().Name}).");
        }

        if (!_installed)
        {
            _disposed = true;
            _subclassProc = null;
            return;
        }

        var callback = _subclassProc;
        if (callback is null)
        {
            _installed = false;
            _disposed = true;
            return;
        }

        var removed = RemoveWindowSubclass(_window, callback, _subclassId);
        if (!removed && IsWindow(_window))
        {
            var error = Marshal.GetLastWin32Error();
            throw error == 0
                ? new InvalidOperationException("Windows did not remove the native HWND subclass.")
                : new Win32Exception(error, "Windows did not remove the native HWND subclass.");
        }

        // Destroyed windows release their subclass list themselves. In either case the
        // managed delegate must no longer be retained once this adapter is disposed.
        _installed = false;
        _disposed = true;
        _subclassProc = null;
    }

    private nint Dispatch(
        nint window,
        uint message,
        nint wParam,
        nint lParam,
        nuint subclassId,
        nuint referenceData)
    {
        if (!_disposed && _installed && window == _window && subclassId == _subclassId)
        {
            var handled = false;
            nint handlerResult = 0;
            try
            {
                handled = _handler(message, wParam, lParam, out handlerResult);
            }
            catch (Exception ex)
            {
                // Never allow a managed exception to cross the reverse P/Invoke
                // boundary. Keep diagnostics type-only; message payloads can be
                // remote/private data, and the native default path is fail-closed.
                Console.Error.WriteLine(
                    $"Native message handler failed ({ex.GetType().Name}); forwarding to DefSubclassProc.");
            }

            if (handled)
            {
                RefreshCaptionlessResizeRegions(message);
                return handlerResult;
            }

            var result = DefSubclassProc(window, message, wParam, lParam);
            RefreshCaptionlessResizeRegions(message);
            return result;
        }

        return DefSubclassProc(window, message, wParam, lParam);
    }


    private static Exception LastWin32Failure(string message)
    {
        var error = Marshal.GetLastWin32Error();
        return error == 0
            ? new InvalidOperationException(message)
            : new Win32Exception(error, message);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate nint SubclassProc(
        nint window,
        uint message,
        nint wParam,
        nint lParam,
        nuint subclassId,
        nuint referenceData);

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetWindowSubclass(
        nint window,
        SubclassProc subclassProc,
        nuint subclassId,
        nuint referenceData);

    [DllImport("comctl32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveWindowSubclass(
        nint window,
        SubclassProc subclassProc,
        nuint subclassId);

    [DllImport("comctl32.dll")]
    private static extern nint DefSubclassProc(
        nint window,
        uint message,
        nint wParam,
        nint lParam);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetClientRect(nint window, ref NativeRect rect);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(nint window, ref NativeRect rect);
    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll")]
    private static extern int GetSystemMetricsForDpi(int index, uint dpi);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool IsWindow(nint window);
}
