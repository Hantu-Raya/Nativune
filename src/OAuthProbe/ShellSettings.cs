using System.Drawing;
using System.Text.Json;

namespace OAuthProbe;

internal sealed record ShellSettings(int X, int Y, int Width, int Height, int Dpi, bool Maximized, double Zoom)
{
    public bool TrayEnabled { get; init; }
    public bool RestoreSection { get; init; }
    public string LastSection { get; init; } = "home";

    internal static string? SectionFromUri(Uri uri)
    {
        if (!uri.IsAbsoluteUri || uri.Scheme != Uri.UriSchemeHttps || !uri.IsDefaultPort
            || uri.UserInfo.Length != 0 || !uri.Host.Equals("music.youtube.com", StringComparison.OrdinalIgnoreCase))
            return null;
        return uri.AbsolutePath switch { "/" => "home", "/library" or "/library/" => "library", _ => null };
    }

    internal string StartupUri => RestoreSection && LastSection == "library"
        ? "https://music.youtube.com/library" : "https://music.youtube.com/";

    private const int CurrentVersion = 1;
    private const int MaxBytes = 16 * 1024;
    private const int DefaultDpi = 96;
    private const int MinDpi = 48;
    private const int MaxDpi = 768;
    private const int MinWidth = 320;
    private const int MinHeight = 240;
    private const int MaxDimension = 16_384;
    private const double MinZoom = 0.75;
    private const double MaxZoom = 1.5;

    private static readonly ShellSettings Defaults = new(100, 100, 1280, 800, DefaultDpi, false, 1.0);
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = null,
        WriteIndented = true,
        AllowTrailingCommas = false,
        ReadCommentHandling = JsonCommentHandling.Disallow
    };

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
            if (persisted is null || persisted.Version != CurrentVersion || !IsValid(persisted))
            {
                warning = "Saved window settings are invalid; defaults are being used.";
                return Defaults;
            }

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
        if (workArea.Width <= 0 || workArea.Height <= 0)
            workArea = new Rectangle(0, 0, Defaults.Width, Defaults.Height);

        var safe = Normalize(settings);
        var sourceDpi = IsDpi(safe.Dpi) ? safe.Dpi : DefaultDpi;
        var targetDpi = IsDpi(dpi) ? dpi : DefaultDpi;
        var scale = (double)targetDpi / sourceDpi;

        var width = ScaleDimension(safe.Width, scale);
        var height = ScaleDimension(safe.Height, scale);
        width = Math.Min(width, workArea.Width);
        height = Math.Min(height, workArea.Height);
        width = Math.Max(width, 1);
        height = Math.Max(height, 1);

        var x = ScaleCoordinate(safe.X, scale);
        var y = ScaleCoordinate(safe.Y, scale);
        var areaRight = (long)workArea.X + workArea.Width;
        var areaBottom = (long)workArea.Y + workArea.Height;
        var maxX = areaRight - width;
        var maxY = areaBottom - height;
        x = (int)Math.Clamp((long)x, (long)workArea.X, Math.Max((long)workArea.X, maxX));
        y = (int)Math.Clamp((long)y, (long)workArea.Y, Math.Max((long)workArea.Y, maxY));
        return new Rectangle(x, y, width, height);
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

    private static bool IsValid(PersistedSettings settings)
        => IsDpi(settings.Dpi)
            && settings.Width is >= MinWidth and <= MaxDimension
            && settings.Height is >= MinHeight and <= MaxDimension
            && double.IsFinite(settings.Zoom)
            && settings.Zoom is >= MinZoom and <= MaxZoom;

    private static ShellSettings Normalize(ShellSettings settings)
        => new(
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
            LastSection = settings.RestoreSection && settings.LastSection == "library" ? "library" : "home"
        };

    private static bool IsDpi(int dpi) => dpi is >= MinDpi and <= MaxDpi;

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

    private sealed record PersistedSettings(int Version, int X, int Y, int Width, int Height, int Dpi, bool Maximized, double Zoom,
        bool TrayEnabled = false, bool RestoreSection = false, string LastSection = "home")
    {
        public ShellSettings ToSettings() => new(X, Y, Width, Height, Dpi, Maximized, Zoom)
            { TrayEnabled = TrayEnabled, RestoreSection = RestoreSection, LastSection = LastSection };

        public static PersistedSettings FromSettings(ShellSettings settings)
            => new(CurrentVersion, settings.X, settings.Y, settings.Width, settings.Height,
                settings.Dpi, settings.Maximized, settings.Zoom, settings.TrayEnabled, settings.RestoreSection, settings.LastSection);
    }
}
