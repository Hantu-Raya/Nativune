using Microsoft.UI.Xaml;
using Microsoft.Web.WebView2.Core;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text;
using Windows.Foundation;

namespace Nativune;

/// <summary>
/// Owns the supported windowed WebView2 controller used by the WinUI shell.
/// The WinUI WebView2 control does not project its controller or host zoom API,
/// so this adapter hosts one CoreWebView2Controller in a native child HWND that
/// is kept above the XAML island only within the browser slot.
/// </summary>
internal sealed class NativeBrowserHost : IDisposable
{
    private const uint WsChild = 0x40000000;
    private const uint WsClipSiblings = 0x04000000;
    private const uint WsClipChildren = 0x02000000;
    private const uint SsNotify = 0x0100;
    private const uint SwpNoActivate = 0x0010;
    private const uint SwpShowWindow = 0x0040;
    private const uint SwpHideWindow = 0x0080;
    private const uint SwpNoSize = 0x0001;
    private const uint SwpNoMove = 0x0002;
    private static readonly nint HwndTop = nint.Zero;

    private readonly CoreWebView2Controller _controller;
    private readonly FrameworkElement _slot;
    private readonly nint _containerWindow;
    private XamlRoot? _xamlRoot;
    private TypedEventHandler<XamlRoot, XamlRootChangedEventArgs>? _xamlRootChanged;
    private bool _containerVisible;
    private bool _disposed;
    private (int X, int Y, int Width, int Height)? _lastBounds;

    private NativeBrowserHost(CoreWebView2Controller controller, FrameworkElement slot, nint containerWindow)
    {
        _controller = controller ?? throw new ArgumentNullException(nameof(controller));
        _slot = slot ?? throw new ArgumentNullException(nameof(slot));
        _containerWindow = containerWindow;
        try
        {
            _slot.SizeChanged += OnSlotChanged;
            _slot.LayoutUpdated += OnSlotLayoutUpdated;
            _slot.Loaded += OnSlotLoaded;
            _slot.Unloaded += OnSlotUnloaded;
            AttachXamlRoot();
            Core.NavigationCompleted += OnNavigationCompleted;
            UpdateBounds();
        }
        catch
        {
            _slot.SizeChanged -= OnSlotChanged;
            _slot.LayoutUpdated -= OnSlotLayoutUpdated;
            _slot.Loaded -= OnSlotLoaded;
            _slot.Unloaded -= OnSlotUnloaded;
            DetachXamlRoot();
            Core.NavigationCompleted -= OnNavigationCompleted;
            throw;
        }
    }

    internal CoreWebView2 Core => _controller.CoreWebView2
        ?? throw new InvalidOperationException("WebView2 controller did not expose its CoreWebView2.");

    internal double ZoomFactor
    {
        get => _controller.ZoomFactor;
        set => _controller.ZoomFactor = value;
    }

    internal bool IsVisible => !_disposed && _controller.IsVisible;

    internal Windows.UI.Color DefaultBackgroundColor
    {
        set => _controller.DefaultBackgroundColor = value;
    }

    internal event TypedEventHandler<CoreWebView2Controller, CoreWebView2AcceleratorKeyPressedEventArgs> AcceleratorKeyPressed
    {
        add => _controller.AcceleratorKeyPressed += value;
        remove => _controller.AcceleratorKeyPressed -= value;
    }

    internal event TypedEventHandler<CoreWebView2Controller, CoreWebView2MoveFocusRequestedEventArgs> MoveFocusRequested
    {
        add => _controller.MoveFocusRequested += value;
        remove => _controller.MoveFocusRequested -= value;
    }

    internal static async Task<NativeBrowserHost> CreateAsync(
        CoreWebView2Environment environment,
        nint parentWindow,
        FrameworkElement slot,
        CancellationToken cancellationToken,
        Action<Task> registerLateCleanup)
    {
        ArgumentNullException.ThrowIfNull(environment);
        ArgumentNullException.ThrowIfNull(slot);
        ArgumentNullException.ThrowIfNull(registerLateCleanup);
        if (parentWindow == 0)
            throw new ArgumentException("A live parent HWND is required.", nameof(parentWindow));
        var container = CreateContainerWindow(parentWindow);
        Task<CoreWebView2Controller>? creation = null;
        var lateCleanupScheduled = false;
        try
        {
            var parent = CoreWebView2ControllerWindowReference.CreateFromWindowHandle((ulong)container.ToInt64());
            creation = environment.CreateCoreWebView2ControllerAsync(parent).AsTask();
            CoreWebView2Controller controller;
            try
            {
                controller = await creation.WaitAsync(TimeSpan.FromSeconds(30), cancellationToken);
            }
            catch
            {
                lateCleanupScheduled = true;
                var cleanup = CloseWhenCreatedAsync(creation!, container);
                registerLateCleanup(cleanup);
                throw;
            }

            try
            {
                cancellationToken.ThrowIfCancellationRequested();
                return new NativeBrowserHost(controller, slot, container);
            }
            catch
            {
                controller.Close();
                throw;
            }
        }
        catch
        {
            if (!lateCleanupScheduled)
                DestroyContainerWindow(container);
            throw;
        }
    }

    private static async Task CloseWhenCreatedAsync(Task<CoreWebView2Controller> creation, nint container)
    {
        try
        {
            // CreateAsync is called from the WebView UI STA. Keep this await
            // on its captured context so controller.Close runs on that STA.
            (await creation).Close();
        }
        catch (Exception) { }
        finally
        {
            DestroyContainerWindow(container);
        }
    }

    internal void SetVisible(bool visible)
    {
        ThrowIfDisposed();
        if (visible)
        {
            _containerVisible = true;
            _lastBounds = null;
            UpdateBounds();
            _controller.IsVisible = true;
        }
        else
        {
            _controller.IsVisible = false;
            _containerVisible = false;
            _lastBounds = null;
            SetContainerVisibility(false);
        }
    }

    internal void Focus()
    {
        ThrowIfDisposed();
        _controller.MoveFocus(CoreWebView2MoveFocusReason.Programmatic);
    }

    internal void MoveFocus(CoreWebView2MoveFocusReason reason)
    {
        ThrowIfDisposed();
        _controller.MoveFocus(reason);
    }

    internal void NotifyParentWindowPositionChanged()
    {
        ThrowIfDisposed();
        _controller.NotifyParentWindowPositionChanged();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _slot.SizeChanged -= OnSlotChanged;
        _slot.LayoutUpdated -= OnSlotLayoutUpdated;
        _slot.Loaded -= OnSlotLoaded;
        _slot.Unloaded -= OnSlotUnloaded;
        Core.NavigationCompleted -= OnNavigationCompleted;
        DetachXamlRoot();
        try { _controller.IsVisible = false; }
        catch (Exception) { }
        try { _controller.Close(); }
        catch (Exception) { }
        DestroyContainerWindow(_containerWindow);
    }

    private void OnSlotLoaded(object sender, RoutedEventArgs args)
    {
        AttachXamlRoot();
        UpdateBounds();
    }

    private void OnSlotUnloaded(object sender, RoutedEventArgs args)
    {
        DetachXamlRoot();
    }

    private void OnSlotChanged(object sender, SizeChangedEventArgs args)
    {
        UpdateBounds();
    }
    private void OnSlotLayoutUpdated(object? sender, object args)
    {
        // Compact/full mode moves this slot even when its size is unchanged.
        UpdateBounds();
    }

    private void AttachXamlRoot()
    {
        var root = _slot.XamlRoot;
        if (ReferenceEquals(root, _xamlRoot)) return;
        DetachXamlRoot();
        _xamlRoot = root;
        if (root is null) return;
        _xamlRootChanged = (_, _) => UpdateBounds();
        root.Changed += _xamlRootChanged;
    }

    private void DetachXamlRoot()
    {
        if (_xamlRoot is not null && _xamlRootChanged is not null)
            _xamlRoot.Changed -= _xamlRootChanged;
        _xamlRoot = null;
        _xamlRootChanged = null;
    }

    private void UpdateBounds()
    {
        if (_disposed || _xamlRoot is null || _slot.ActualWidth <= 0 || _slot.ActualHeight <= 0)
            return;
        try
        {
            var scale = _xamlRoot.RasterizationScale;
            var origin = _slot.TransformToVisual(null).TransformPoint(new Windows.Foundation.Point(0, 0));
            var width = Math.Max(1, ToPixels(_slot.ActualWidth, scale));
            var height = Math.Max(1, ToPixels(_slot.ActualHeight, scale));
            var x = ToPixels(origin.X, scale);
            var y = ToPixels(origin.Y, scale);
            if (_lastBounds == (x, y, width, height)) return;
            _controller.Bounds = new Windows.Foundation.Rect(0, 0, width, height);
            SetWindowPosition(x, y, width, height, _containerVisible);
            _controller.NotifyParentWindowPositionChanged();
            _lastBounds = (x, y, width, height);
            RepairWindows11Input();
        }
        catch (Exception) when (_disposed) { }
    }

    private void OnNavigationCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        RepairWindows11Input();
    }

    private void RepairWindows11Input()
    {
        if (_disposed || !OperatingSystem.IsWindowsVersionAtLeast(10, 0, 22000)) return;
        // Runtime compatibility workaround verified against microsoft-ui-xaml#10826.
        // Chromium owns these child windows: never cache their handles or alter
        // other windows/styles. Recheck after navigation and geometry/visibility changes.
        EnumChildWindows(_containerWindow, (window, _) =>
        {
            var className = new StringBuilder(64);
            if (GetClassName(window, className, className.Capacity) == 0
                || className.ToString() != "Intermediate D3D Window") return true;
            className.Clear();
            if (GetClassName(GetParent(window), className, className.Capacity) == 0
                || className.ToString() != "Chrome_WidgetWin_1"
                || !IsChild(_containerWindow, window)) return true;
            const int extendedStyle = -20;
            const long transparent = 0x20;
            var style = GetWindowLongPtr(window, extendedStyle).ToInt64();
            if ((style & transparent) == 0) return true;
            SetWindowLongPtr(window, extendedStyle, (nint)(style & ~transparent));
            if (IsChild(_containerWindow, window)
                && (GetWindowLongPtr(window, extendedStyle).ToInt64() & transparent) != 0)
                Console.Error.WriteLine("WebView2 input compatibility workaround could not be applied.");
            return true;
        }, 0);
    }

    private void SetContainerVisibility(bool visible)
    {
        if (_containerWindow == 0) return;
        SetWindowPosition(0, 0, 0, 0, visible, noSize: true, noMove: true);
    }

    private void SetWindowPosition(int x, int y, int width, int height, bool visible, bool noSize = false, bool noMove = false)
    {
        var flags = SwpNoActivate | (visible ? SwpShowWindow : SwpHideWindow);
        if (noSize) flags |= SwpNoSize;
        if (noMove) flags |= SwpNoMove;
        if (!SetWindowPos(_containerWindow, HwndTop, x, y, width, height, flags))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not position the native WebView2 slot window.");
    }

    private static int ToPixels(double value, double scale)
    {
        if (!double.IsFinite(value) || !double.IsFinite(scale) || scale <= 0)
            return 0;
        var result = Math.Round(value * scale, MidpointRounding.AwayFromZero);
        return result <= int.MinValue ? int.MinValue : result >= int.MaxValue ? int.MaxValue : (int)result;
    }

    private static nint CreateContainerWindow(nint parent)
    {
        var handle = CreateWindowEx(
            0, "Static", string.Empty, WsChild | WsClipSiblings | WsClipChildren | SsNotify,
            0, 0, 1, 1, parent, 0, 0, 0);
        if (handle == 0)
            throw new Win32Exception(Marshal.GetLastWin32Error(), "Could not create the native WebView2 slot window.");
        return handle;
    }

    private static void DestroyContainerWindow(nint window)
    {
        if (window == 0) return;
        DestroyWindow(window);
    }

    private void ThrowIfDisposed()
    {
        if (_disposed)
            throw new ObjectDisposedException(nameof(NativeBrowserHost));
    }

    private delegate bool EnumWindowCallback(nint window, nint parameter);

    [DllImport("user32.dll")]
    private static extern bool EnumChildWindows(nint parent, EnumWindowCallback callback, nint parameter);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int GetClassName(nint window, StringBuilder className, int capacity);

    [DllImport("user32.dll")]
    private static extern nint GetParent(nint window);

    [DllImport("user32.dll")]
    private static extern bool IsChild(nint parent, nint window);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint GetWindowLongPtr(nint window, int index);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetWindowLongPtr(nint window, int index, nint value);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateWindowEx(
        uint extendedStyle,
        string className,
        string windowName,
        uint style,
        int x,
        int y,
        int width,
        int height,
        nint parent,
        nint menu,
        nint instance,
        nint parameter);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool DestroyWindow(nint window);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool SetWindowPos(
        nint window,
        nint insertAfter,
        int x,
        int y,
        int width,
        int height,
        uint flags);
}
