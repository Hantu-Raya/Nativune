using Microsoft.Win32;

namespace Nativune;

internal enum StartupEntryState { Off, On, DisabledByUser, Stale }

internal enum AutostartMode { Full, Compact, Tray }

// Per-user "start when I sign in" entry. HKCU only; the app never writes StartupApproved
// (Windows owns the user's Task Manager / Settings choice).
internal static class StartupRegistration
{
    internal const string ValueName = "Nativune";
    internal const string DefaultRunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    internal const string DefaultApprovedKey = @"Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run";

    internal static string Command(string root)
    {
        var full = Path.GetFullPath(root).TrimEnd('\\', '/');
        return $"\"{ExePath(full)}\" web --root \"{full}\" --autostart";
    }

    internal static StartupEntryState Read(string root, string? runKey = null, string? approvedKey = null)
    {
        var value = ReadValue(runKey ?? RunKey());
        if (value is null)
            return StartupEntryState.Off;
        if (!PointsToRoot(value, root))
            return StartupEntryState.Stale;
        return IsDisabledByUser(approvedKey ?? ApprovedKey())
            ? StartupEntryState.DisabledByUser : StartupEntryState.On;
    }

    internal static void Enable(string root, string? runKey = null)
    {
        using var key = Registry.CurrentUser.CreateSubKey(runKey ?? RunKey(), writable: true);
        key.SetValue(ValueName, Command(root), RegistryValueKind.String);
    }

    internal static void Disable(string root, string? runKey = null)
    {
        var path = runKey ?? RunKey();
        var value = ReadValue(path);
        if (value is null || !PointsToRoot(value, root))
            return;
        DeleteValue(path);
    }

    internal static void RemoveStale(string? runKey = null)
    {
        var path = runKey ?? RunKey();
        if (ReadValue(path) is not null)
            DeleteValue(path);
    }

    // Owner decision (26 September 2026): Start with Windows is on by default. Applied once per install
    // root (marker in data\): only an Off entry is enabled, never one the user turned off in Task Manager
    // or one owned by another copy, and later choices stand. Hook (fixture) builds apply it only under a
    // test key, so they can never write the real Run value shared with the owner's install.
    internal static bool ApplyDefaultOnce(string root)
    {
        var marker = Path.Combine(Path.GetFullPath(root), "data", "startup-default-applied");
        if (File.Exists(marker))
            return false;
#if NATIVUNE_UPDATER_TEST_HOOKS
        if (TestBase() is null)
            return false;
#endif
        var enable = Read(root) == StartupEntryState.Off;
        if (enable)
            Enable(root);
        Directory.CreateDirectory(Path.GetDirectoryName(marker)!);
        File.WriteAllText(marker, string.Empty);
        return enable;
    }

    // Parses the leading quoted (or first unquoted token) executable path of a Run command.
    internal static string? ExecutableOf(string command)
    {
        var text = command.Trim();
        if (text.Length == 0)
            return null;
        if (text[0] == '"')
        {
            var end = text.IndexOf('"', 1);
            return end > 1 ? text[1..end] : null;
        }
        var space = text.IndexOf(' ');
        return space < 0 ? text : text[..space];
    }

    private static bool PointsToRoot(string value, string root)
    {
        var exe = ExecutableOf(value);
        if (exe is null)
            return false;
        try
        {
            var expected = ExePath(Path.GetFullPath(root).TrimEnd('\\', '/'));
            return string.Equals(Path.GetFullPath(exe), expected, StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception ex) when (ex is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    private static string ExePath(string fullRoot) => Path.Combine(fullRoot, "app", "Nativune.exe");

    private static string? ReadValue(string keyPath)
    {
        using var key = Registry.CurrentUser.OpenSubKey(keyPath, writable: false);
        return key?.GetValue(ValueName, null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
    }

    private static void DeleteValue(string keyPath)
    {
        using var key = Registry.CurrentUser.OpenSubKey(keyPath, writable: true);
        key?.DeleteValue(ValueName, throwOnMissingValue: false);
    }

    // First byte 0x02/0x06 (even) = enabled; an odd first byte (0x03, ...) = turned off by the user.
    private static bool IsDisabledByUser(string keyPath)
    {
        using var key = Registry.CurrentUser.OpenSubKey(keyPath, writable: false);
        return key?.GetValue(ValueName) is byte[] { Length: > 0 } data
            && data[0] is not (0x02 or 0x06) && (data[0] & 1) == 1;
    }

    private static string RunKey() => TestBase() is { } b ? b + @"\Run" : DefaultRunKey;

    private static string ApprovedKey() => TestBase() is { } b ? b + @"\StartupApproved\Run" : DefaultApprovedKey;

    private static string? TestBase()
    {
#if NATIVUNE_UPDATER_TEST_HOOKS
        var value = Environment.GetEnvironmentVariable("NATIVUNE_TEST_STARTUP_KEY")?.Trim().TrimEnd('\\');
        if (!string.IsNullOrEmpty(value))
        {
            if (!value.StartsWith(@"Software\Nativune\Test\", StringComparison.OrdinalIgnoreCase)
                || value.Length <= @"Software\Nativune\Test\".Length || value.Contains(".."))
                throw new InvalidOperationException("NATIVUNE_TEST_STARTUP_KEY must be under Software\\Nativune\\Test\\.");
            return value;
        }
#endif
        return null;
    }
}
