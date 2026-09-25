using System.Drawing;
using System.Text.Json;

namespace Nativune;

internal sealed record ShellSettings(int X, int Y, int Width, int Height, int Dpi, bool Maximized, double Zoom)
{
    public bool TrayEnabled { get; init; }
    public bool RestoreSection { get; init; }
    public string LastSection { get; init; } = "home";
    public bool ReduceMotion { get; init; }
    public ShortcutBindings Shortcuts { get; init; } = ShortcutBindings.Default;
    public bool SleepInBackground { get; init; } = true;
    public bool AutoCheckUpdates { get; init; } = true;
    public bool StartCompact { get; init; }
    public int CompactX { get; init; } = 100;
    public int CompactY { get; init; } = 100;
    public int CompactWidth { get; init; } = 800;
    public int CompactHeight { get; init; } = 180;
    public int CompactDpi { get; init; } = 96;
    // App output (WebView audio) level and mute, restored on the next start. Null mute = never set,
    // so Nativune leaves the session's own mute state alone.
    public double OutputVolume { get; init; } = 1;
    public bool? OutputMuted { get; init; }
    // Opt-in uBO Lite ad filters on music.youtube.com (owner decision, 25 September 2026). Off by default.
    public bool BlockAds { get; init; }

    internal static string? SectionFromUri(Uri uri)
    {
        if (!uri.IsAbsoluteUri || uri.Scheme != Uri.UriSchemeHttps || !uri.IsDefaultPort
            || uri.UserInfo.Length != 0 || !uri.Host.Equals("music.youtube.com", StringComparison.OrdinalIgnoreCase))
            return null;
        return uri.AbsolutePath switch { "/" => "home", "/library" or "/library/" => "library", _ => null };
    }

    internal string StartupUri => RestoreSection && LastSection == "library"
        ? "https://music.youtube.com/library" : "https://music.youtube.com/";

    private const int CurrentVersion = 5;
    private const int MaxBytes = 16 * 1024;
    private const int DefaultDpi = 96;
    private const int MinDpi = 48;
    private const int MaxDpi = 768;
    private const int MinWidth = 320;
    private const int MinHeight = 240;
    private const int MinCompactWidth = 320;
    private const int MinCompactHeight = 56;
    private const int MaxDimension = 16_384;
    private const double MinZoom = 0.75;
    private const double MaxZoom = 1.5;

    private static readonly ShellSettings Defaults = new(100, 100, 1280, 800, DefaultDpi, false, 1.0)
    {
        TrayEnabled = true
    };
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = null,
        WriteIndented = true,
        AllowTrailingCommas = false,
        ReadCommentHandling = JsonCommentHandling.Disallow
    };

    internal static ShellSettings Default => Defaults;

    public static ShellSettings Load(string root, out string? warning)
    {
        warning = null;
        try
        {
            var path = SettingsPath(root);
            if (!File.Exists(path))
                return Defaults;

            var bytes = ReadBounded(path);
            if (bytes is null)
            {
                warning = "Saved window settings are too large; defaults are being used.";
                return Defaults;
            }

            var persisted = JsonSerializer.Deserialize<PersistedSettings>(bytes, JsonOptions);
            if (persisted is null || persisted.Version is not (1 or 2 or 3 or 4 or CurrentVersion) || !IsCoreValid(persisted))
            {
                warning = "Saved window settings are invalid; defaults are being used.";
                return Defaults;
            }

            // Earlier versions migrate with background sleeping enabled because that matches
            // Chromium's existing default behavior. Nullable/defaulted fields retain the
            // existing window and preference values after partial writes.
            return Normalize(persisted.ToSettings());
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or JsonException)
        {
            // Keep filesystem and parser details out of the UI; paths can contain private data.
            warning = "Saved window settings could not be read; defaults are being used.";
            return Defaults;
        }
    }

    public static Rectangle RestoreBounds(ShellSettings settings, Rectangle workArea, int dpi)
    {
        var safe = Normalize(settings);
        return RestoreBounds(safe.X, safe.Y, safe.Width, safe.Height, safe.Dpi, workArea, dpi);
    }

    public static Rectangle RestoreCompactBounds(ShellSettings settings, Rectangle workArea, int dpi)
    {
        var safe = Normalize(settings);
        return RestoreBounds(safe.CompactX, safe.CompactY, safe.CompactWidth, safe.CompactHeight,
            safe.CompactDpi, workArea, dpi);
    }

    public static async Task SaveAsync(string root, ShellSettings settings, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        var path = SettingsPath(root);
        var directory = Path.GetDirectoryName(path)!;
        Directory.CreateDirectory(directory);
        token.ThrowIfCancellationRequested();

        var temporary = path + ".tmp";
        try
        {
            var persisted = PersistedSettings.FromSettings(Normalize(settings));
            await using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write,
                FileShare.None, 4096, FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
                await JsonSerializer.SerializeAsync(stream, persisted, JsonOptions, token).ConfigureAwait(false);
                await stream.FlushAsync(token).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }

            // Keep this check directly adjacent to the rename: a cancelled close must not
            // replace a settings file written by a later process instance.
            token.ThrowIfCancellationRequested();
            File.Move(temporary, path, overwrite: true);
        }
        finally
        {
            try { File.Delete(temporary); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static byte[]? ReadBounded(string path)
    {
        var buffer = new byte[MaxBytes + 1];
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read,
            4096, FileOptions.SequentialScan);
        var length = 0;
        while (length < buffer.Length)
        {
            var count = stream.Read(buffer, length, buffer.Length - length);
            if (count == 0)
                break;
            length += count;
        }

        if (length > MaxBytes)
            return null;
        Array.Resize(ref buffer, length);
        return buffer;
    }

    private static string SettingsPath(string root)
        => Path.Combine(Path.GetFullPath(root), "data", "settings.json");

    private static bool IsCoreValid(PersistedSettings settings)
        => IsDpi(settings.Dpi)
            && settings.Width is >= MinWidth and <= MaxDimension
            && settings.Height is >= MinHeight and <= MaxDimension
            && double.IsFinite(settings.Zoom)
            && settings.Zoom is >= MinZoom and <= MaxZoom;

    private static ShellSettings Normalize(ShellSettings settings)
    {
        var shortcuts = settings.Shortcuts is not null && settings.Shortcuts.Validate(out _)
            ? settings.Shortcuts : ShortcutBindings.Default;
        return new(
            settings.X,
            settings.Y,
            settings.Width is >= MinWidth and <= MaxDimension ? settings.Width : Defaults.Width,
            settings.Height is >= MinHeight and <= MaxDimension ? settings.Height : Defaults.Height,
            IsDpi(settings.Dpi) ? settings.Dpi : DefaultDpi,
            settings.Maximized,
            double.IsFinite(settings.Zoom) && settings.Zoom is >= MinZoom and <= MaxZoom ? settings.Zoom : Defaults.Zoom)
        {
            TrayEnabled = settings.TrayEnabled,
            RestoreSection = settings.RestoreSection,
            LastSection = settings.RestoreSection && settings.LastSection == "library" ? "library" : "home",
            ReduceMotion = settings.ReduceMotion,
            Shortcuts = shortcuts,
            SleepInBackground = settings.SleepInBackground,
            StartCompact = settings.StartCompact,
            AutoCheckUpdates = settings.AutoCheckUpdates,
            CompactX = settings.CompactX,
            CompactY = settings.CompactY,
            CompactWidth = settings.CompactWidth is >= MinCompactWidth and <= MaxDimension
                ? settings.CompactWidth : Defaults.CompactWidth,
            CompactHeight = settings.CompactHeight is >= MinCompactHeight and <= MaxDimension
                ? settings.CompactHeight : Defaults.CompactHeight,
            CompactDpi = IsDpi(settings.CompactDpi) ? settings.CompactDpi : DefaultDpi,
            OutputVolume = double.IsFinite(settings.OutputVolume) && settings.OutputVolume is >= 0 and <= 1
                ? settings.OutputVolume : 1,
            OutputMuted = settings.OutputMuted,
            BlockAds = settings.BlockAds
        };
    }

    private static bool IsDpi(int dpi) => dpi is >= MinDpi and <= MaxDpi;

    private static Rectangle RestoreBounds(int x, int y, int width, int height, int sourceDpi,
        Rectangle workArea, int targetDpi)
    {
        if (workArea.Width <= 0 || workArea.Height <= 0)
            workArea = new Rectangle(0, 0, Defaults.Width, Defaults.Height);

        var safeSourceDpi = IsDpi(sourceDpi) ? sourceDpi : DefaultDpi;
        var safeTargetDpi = IsDpi(targetDpi) ? targetDpi : DefaultDpi;
        var scale = (double)safeTargetDpi / safeSourceDpi;
        var scaledWidth = ScaleDimension(width, scale);
        var scaledHeight = ScaleDimension(height, scale);
        scaledWidth = Math.Min(scaledWidth, workArea.Width);
        scaledHeight = Math.Min(scaledHeight, workArea.Height);
        scaledWidth = Math.Max(scaledWidth, 1);
        scaledHeight = Math.Max(scaledHeight, 1);

        var scaledX = ScaleCoordinate(x, scale);
        var scaledY = ScaleCoordinate(y, scale);
        var areaRight = (long)workArea.X + workArea.Width;
        var areaBottom = (long)workArea.Y + workArea.Height;
        var maxX = areaRight - scaledWidth;
        var maxY = areaBottom - scaledHeight;
        var restoredX = (int)Math.Clamp((long)scaledX, (long)workArea.X, Math.Max((long)workArea.X, maxX));
        var restoredY = (int)Math.Clamp((long)scaledY, (long)workArea.Y, Math.Max((long)workArea.Y, maxY));
        return new Rectangle(restoredX, restoredY, scaledWidth, scaledHeight);
    }

    private static int ScaleDimension(int value, double scale)
    {
        var scaled = Math.Round(value * scale, MidpointRounding.AwayFromZero);
        if (scaled <= 1)
            return 1;
        if (scaled >= MaxDimension)
            return MaxDimension;
        return (int)scaled;
    }

    private static int ScaleCoordinate(int value, double scale)
    {
        var scaled = value * scale;
        if (scaled <= int.MinValue)
            return int.MinValue;
        if (scaled >= int.MaxValue)
            return int.MaxValue;
        return (int)Math.Round(scaled, MidpointRounding.AwayFromZero);
    }

    private sealed record PersistedSettings(int Version, int X, int Y, int Width, int Height, int Dpi, bool Maximized,
        double Zoom, bool TrayEnabled = false, bool RestoreSection = false, string LastSection = "home",
        bool ReduceMotion = false, ShortcutBindings? Shortcuts = null, int CompactX = 100, int CompactY = 100,
        int CompactWidth = 800, int CompactHeight = 180, int CompactDpi = DefaultDpi,
        bool SleepInBackground = true, bool StartCompact = false, bool? AutoCheckUpdates = null,
        double OutputVolume = 1, bool? OutputMuted = null, bool BlockAds = false)
    {
        public ShellSettings ToSettings() => new(X, Y, Width, Height, Dpi, Maximized, Zoom)
        {
            TrayEnabled = TrayEnabled,
            RestoreSection = RestoreSection,
            LastSection = LastSection,
            ReduceMotion = ReduceMotion,
            Shortcuts = Shortcuts ?? ShortcutBindings.Default,
            SleepInBackground = SleepInBackground,
            StartCompact = StartCompact,
            AutoCheckUpdates = AutoCheckUpdates ?? true,
            CompactX = CompactX,
            CompactY = CompactY,
            CompactWidth = CompactWidth,
            CompactHeight = CompactHeight,
            CompactDpi = CompactDpi,
            OutputVolume = OutputVolume,
            OutputMuted = OutputMuted,
            BlockAds = BlockAds
        };

        public static PersistedSettings FromSettings(ShellSettings settings)
            => new(CurrentVersion, settings.X, settings.Y, settings.Width, settings.Height,
                settings.Dpi, settings.Maximized, settings.Zoom, settings.TrayEnabled, settings.RestoreSection,
                settings.LastSection, settings.ReduceMotion, settings.Shortcuts, settings.CompactX,
                settings.CompactY, settings.CompactWidth, settings.CompactHeight, settings.CompactDpi,
                settings.SleepInBackground, settings.StartCompact, settings.AutoCheckUpdates,
                settings.OutputVolume, settings.OutputMuted, settings.BlockAds);
    }
}
