using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media;
using Windows.UI.ViewManagement;
using WinRT.Interop;
using UiColor = Windows.UI.Color;

namespace Nativune;

/// <summary>
/// Shared resources and state policy for the native shell.
/// </summary>
/// <remarks>
/// The visual resources live in <c>ShellTheme.xaml</c>, which is merged by the
/// application resource dictionary. This class only selects the active theme,
/// applies the system high-contrast policy, and keeps the title bar in step with
/// the client surface. It intentionally leaves the backdrop opaque.
/// </remarks>
internal static class ShellTheme
{
    private static readonly UiColor CanvasColor = ColorHelper.FromArgb(0xFF, 0x03, 0x03, 0x03);
    private static readonly UiColor SurfaceColor = ColorHelper.FromArgb(0xFF, 0x12, 0x12, 0x12);
    private static readonly UiColor RaisedColor = ColorHelper.FromArgb(0xFF, 0x21, 0x21, 0x21);
    private static readonly UiColor PrimaryTextColor = ColorHelper.FromArgb(0xFF, 0xFF, 0xFF, 0xFF);
    private static readonly UiColor SecondaryTextColor = ColorHelper.FromArgb(0xFF, 0xAA, 0xAA, 0xAA);
    private static readonly UiColor AccentColor = ColorHelper.FromArgb(0xFF, 0xFF, 0x00, 0x33);
    private const int ColorWindow = 5;
    private const int ColorWindowText = 8;
    private const int ColorHighlight = 13;
    private const int ColorHighlightText = 14;
    private const int ColorGrayText = 17;

    /// <summary>
    /// Reads the current system accessibility setting. The WinRT query is kept
    /// behind a safe fallback because theme helpers are also used by account-free
    /// command-line self-check setup before a XAML window exists.
    /// </summary>
    internal static bool IsHighContrast
    {
        get
        {
            try
            {
                return new AccessibilitySettings().HighContrast;
            }
            catch (COMException)
            {
                return false;
            }
            catch (InvalidOperationException)
            {
                return false;
            }
        }
    }

    /// <summary>
    /// Current primary foreground color. In high contrast mode this resolves to
    /// the system window-text color rather than the dark-palette white.
    /// </summary>
    internal static UiColor ForegroundColor => IsHighContrast
        ? ResourceColor("SystemColorWindowTextColor", SystemColor(ColorWindowText, PrimaryTextColor))
        : PrimaryTextColor;

    /// <summary>
    /// Applies the resource-selected theme and accessibility policy to a native
    /// visual tree. Every call is idempotent and safe to make after a theme change.
    /// </summary>
    internal static void Apply(FrameworkElement element)
    {
        ArgumentNullException.ThrowIfNull(element);

        var highContrast = IsHighContrast;
        // Do not force a dark palette over a system high-contrast scheme. The
        // HighContrast dictionary in ShellTheme.xaml maps every owned state to
        // system colors, while Default/Dark provide the settled app palette.
        element.RequestedTheme = highContrast ? ElementTheme.Default : ElementTheme.Dark;
        element.HighContrastAdjustment = ElementHighContrastAdjustment.Auto;
        ApplyResourceOverrides(highContrast);
    }

    /// <summary>
    /// Applies the client theme and explicit, opaque AppWindow title-bar colors.
    /// The method leaves system caption behavior and drag/resize ownership intact.
    /// </summary>
    internal static void ApplyToWindow(Window window)
    {
        ArgumentNullException.ThrowIfNull(window);

        if (window.Content is FrameworkElement root)
            Apply(root);

        try
        {
            var hwnd = WindowNative.GetWindowHandle(window);
            if (hwnd == 0)
                return;

            var appWindow = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(hwnd));
            if (!AppWindowTitleBar.IsCustomizationSupported())
                return;

            var highContrast = IsHighContrast;
            var background = highContrast
                ? ResourceColor("SystemColorWindowColor", SystemColor(ColorWindow, CanvasColor))
                : CanvasColor;
            var foreground = highContrast
                ? ResourceColor("SystemColorWindowTextColor", SystemColor(ColorWindowText, PrimaryTextColor))
                : PrimaryTextColor;
            var buttonHoverBackground = highContrast
                ? ResourceColor("SystemColorHighlightColor", SystemColor(ColorHighlight, RaisedColor))
                : RaisedColor;
            var buttonHoverForeground = highContrast
                ? ResourceColor("SystemColorHighlightTextColor", SystemColor(ColorHighlightText, PrimaryTextColor))
                : PrimaryTextColor;
            var buttonPressedBackground = highContrast
                ? ResourceColor("SystemColorHighlightColor", SystemColor(ColorHighlight, SurfaceColor))
                : SurfaceColor;
            var buttonPressedForeground = highContrast
                ? ResourceColor("SystemColorHighlightTextColor", SystemColor(ColorHighlightText, PrimaryTextColor))
                : PrimaryTextColor;
            var titleBar = appWindow.TitleBar;
            titleBar.ForegroundColor = foreground;
            titleBar.BackgroundColor = background;
            titleBar.ButtonForegroundColor = foreground;
            titleBar.ButtonBackgroundColor = background;
            titleBar.ButtonHoverForegroundColor = buttonHoverForeground;
            titleBar.ButtonHoverBackgroundColor = buttonHoverBackground;
            titleBar.ButtonPressedForegroundColor = buttonPressedForeground;
            titleBar.ButtonPressedBackgroundColor = buttonPressedBackground;
            titleBar.InactiveForegroundColor = highContrast
                ? ResourceColor("SystemColorGrayTextColor", SystemColor(ColorGrayText, foreground))
                : SecondaryTextColor;
            titleBar.InactiveBackgroundColor = background;
            titleBar.ButtonInactiveForegroundColor = highContrast
                ? ResourceColor("SystemColorGrayTextColor", SystemColor(ColorGrayText, foreground))
                : SecondaryTextColor;
            titleBar.ButtonInactiveBackgroundColor = background;
        }
        catch (COMException)
        {
            // A window can be themed before its HWND is connected to AppWindow.
            // The later activation path calls this method again.
        }
        catch (InvalidOperationException)
        {
            // AppWindow title-bar customization is unavailable during early
            // construction on some Windows versions; client resources still apply.
        }
        catch (ArgumentException)
        {
            // A transient/invalid WindowId is equivalent to an unconnected HWND.
        }
    }

    private static void ApplyResourceOverrides(bool highContrast)
    {
        if (Application.Current?.Resources is not { } resources)
            return;

        // These raw Color resources are consumed by WinUI's focus and accent
        // templates. Keep the normal palette red, but hand control back to the
        // OS highlight colors whenever high contrast is active.
        resources["SystemAccentColor"] = highContrast
            ? ResourceColor("SystemColorHighlightColor", SystemColor(ColorHighlight, PrimaryTextColor))
            : AccentColor;
        resources["FocusStrokeColorOuter"] = highContrast
            ? ResourceColor("SystemColorWindowTextColor", SystemColor(ColorWindowText, PrimaryTextColor))
            : AccentColor;
        resources["FocusStrokeColorInner"] = highContrast
            ? ResourceColor("SystemColorWindowColor", SystemColor(ColorWindow, CanvasColor))
            : PrimaryTextColor;

    }
    /// <summary>Gets a shared theme brush when the application dictionary is ready.</summary>
    internal static Brush Brush(string key, UiColor fallback)
    {
        if (IsHighContrast && key is "PrimaryTextBrush" or "ForegroundBrush" or "SelectedForegroundBrush")
            return new SolidColorBrush(ForegroundColor);

        if (Application.Current?.Resources is { } resources && resources.ContainsKey(key))
        {
            var value = resources[key];
            if (value is Brush brush)
                return brush;
        }

        return new SolidColorBrush(fallback);
    }

    private static UiColor SystemColor(int index, UiColor fallback)
    {
        try
        {
            var colorRef = GetSystemColorNative(index);
            if (colorRef != 0xFFFFFFFF)
            {
                return ColorHelper.FromArgb(
                    0xFF,
                    (byte)(colorRef & 0xFF),
                    (byte)((colorRef >> 8) & 0xFF),
                    (byte)((colorRef >> 16) & 0xFF));
            }
        }
        catch (DllNotFoundException)
        {
            // The native shell always runs on Windows; retain a safe fallback
            // for account-free source/self-check setup without a user32 surface.
        }
        catch (EntryPointNotFoundException)
        {
            // Same fallback for an unexpectedly old user32 implementation.
        }

        return fallback;
    }

    private static UiColor ResourceColor(string key, UiColor fallback)
    {
        try
        {
            if (Application.Current?.Resources is { } resources && resources.ContainsKey(key))
            {
                var value = resources[key];
                if (value is UiColor color)
                    return color;
                if (value is SolidColorBrush brush)
                    return brush.Color;
            }
        }
        catch (InvalidOperationException)
        {
            // Resource lookup may race application construction; use the safe
            // palette fallback until the next ApplyToWindow call.
        }
        catch (COMException)
        {
            // Same fallback for an unavailable WinRT resource manager.
        }

        return fallback;
    }
    [DllImport("user32.dll", EntryPoint = "GetSysColor")]
    private static extern uint GetSystemColorNative(int index);
}
