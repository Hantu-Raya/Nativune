using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;

namespace Nativune;

// The Nativune app icon (assets/app-icon/nativune.ico, rendered from nativune-icon.svg). The same
// file is the exe's ApplicationIcon (Explorer, Start, shortcuts) and is copied next to the app so
// windows and the tray can load it: unpackaged WinUI windows otherwise show a generic icon.
internal static class AppIcon
{
    private const uint ImageIcon = 1;
    private const uint LoadFromFile = 0x00000010;
    private const int SmallIconWidth = 49, SmallIconHeight = 50;

    internal static string FilePath => Path.Combine(AppContext.BaseDirectory, "Assets", "nativune.ico");

    internal static void Apply(AppWindow? window)
    {
        if (window is null || !File.Exists(FilePath)) return;
        try { window.SetIcon(FilePath); }
        catch (Exception ex) when (ex is COMException or ArgumentException or InvalidOperationException) { }
    }

    // A caller-owned small HICON (destroy with DestroyIcon), or 0 when the file is unavailable.
    internal static nint LoadSmallIcon()
    {
        if (!File.Exists(FilePath)) return 0;
        return LoadImage(0, FilePath, ImageIcon, GetSystemMetrics(SmallIconWidth),
            GetSystemMetrics(SmallIconHeight), LoadFromFile);
    }

    [DllImport("user32.dll", EntryPoint = "LoadImageW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint LoadImage(nint instance, string name, uint type, int width, int height, uint load);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);
}
