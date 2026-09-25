#if NATIVUNE_PERF_BENCH_HOOKS
using System.Diagnostics;
using System.Globalization;
using System.Text;
using System.Text.Json;

namespace Nativune;

internal readonly record struct BenchScheduledAction(string Action, double Seconds);

internal static class BenchHooks
{
    private static readonly object LogGate = new();
    private static readonly string? LogPath = ReadValue("NATIVUNE_BENCH_LOG");
    internal static bool Enabled { get; } = !string.IsNullOrWhiteSpace(LogPath) && Path.IsPathRooted(LogPath);
    private static readonly string? StartUriText = ReadValue("NATIVUNE_BENCH_START_URI");
    private static readonly Uri? ValidStartUri = ParseStartUri(StartUriText);
    private static readonly bool Autoplay = ReadValue("NATIVUNE_BENCH_AUTOPLAY") == "1";
    private static readonly bool Mute = ReadValue("NATIVUNE_BENCH_MUTE") == "1";
    private static readonly string ExtraArguments = ReadValue("NATIVUNE_BENCH_EXTRA_ARGS") ?? string.Empty;
    private static readonly string[] EnableFeatureOverrides = ParseFeatureList(ReadValue("NATIVUNE_BENCH_ENABLE_FEATURES"));
    private static readonly string[] DisableFeatureOverrides = ParseFeatureList(ReadValue("NATIVUNE_BENCH_DISABLE_FEATURES"));
    private static readonly IReadOnlyList<BenchScheduledAction> ScheduledActions = ParseSchedule(ReadValue("NATIVUNE_BENCH_SCHEDULE"));

    private static StreamWriter? _writer;
    private static int _startWritten;

    static BenchHooks()
    {
        if (Enabled && !string.IsNullOrWhiteSpace(StartUriText) && ValidStartUri is null)
            Write("bench-config-error", ("variable", "NATIVUNE_BENCH_START_URI"), ("message", "Expected an HTTPS music.youtube.com URI."));
    }

    internal static bool MuteOutput => Enabled && Mute;
    internal static Uri? StartUri => Enabled ? ValidStartUri : null;
    internal static IReadOnlyList<BenchScheduledAction> Schedule => Enabled ? ScheduledActions : Array.Empty<BenchScheduledAction>();

    internal static void Start(string browserArguments)
    {
        if (!Enabled || Interlocked.Exchange(ref _startWritten, 1) != 0) return;
        Write("bench-start",
            ("pid", Environment.ProcessId),
            ("browserArgs", browserArguments),
            ("processStart", ProcessStartMilliseconds()));
    }

    internal static string BuildBrowserArguments(string appArguments)
    {
        if (!Enabled) return appArguments;

        var arguments = new List<string>();
        var enabledFeatures = new List<string>();
        var disabledFeatures = new List<string>();
        var enabledSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var disabledSet = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        CollectArguments(Tokenize(appArguments), arguments, enabledFeatures, enabledSet, disabledFeatures, disabledSet);
        CollectArguments(Tokenize(ExtraArguments), arguments, enabledFeatures, enabledSet, disabledFeatures, disabledSet);
        AddFeatures(EnableFeatureOverrides, enabledFeatures, enabledSet);
        AddFeatures(DisableFeatureOverrides, disabledFeatures, disabledSet);
        if (Autoplay) arguments.Add("--autoplay-policy=no-user-gesture-required");
        if (enabledFeatures.Count > 0) arguments.Add("--enable-features=" + string.Join(',', enabledFeatures));
        if (disabledFeatures.Count > 0) arguments.Add("--disable-features=" + string.Join(',', disabledFeatures));
        return string.Join(' ', arguments);
    }

    internal static void EnvironmentCreated() => Write("environment-created");
    internal static void ControllerCreated() => Write("controller-created");
    internal static void WindowShown() => Write("window-shown");
    internal static void NavigationCompleted(bool ok, string path) => Write("navigation-completed", ("ok", ok), ("path", path));
    internal static void MediaPlaying(double currentTime) => Write("media-playing", ("currentTime", currentTime));
    internal static void MediaTimeout() => Write("media-timeout");
    internal static void Anchor(string source) => Write("anchor", ("source", source));
    internal static void CompactRequested() => Write("compact-requested");
    internal static void CompactShown() => Write("compact-shown");
    internal static void FullRequested() => Write("full-requested");
    internal static void FullShown() => Write("full-shown");
    internal static void HideRequested() => Write("hide-requested");
    internal static void HideDone() => Write("hide-done");
    internal static void ShowRequested() => Write("show-requested");
    internal static void ShowDone() => Write("show-done");
    internal static void QuitRequested() => Write("quit-requested");
    internal static void MediaSample(bool? paused, double? currentTime, double? duration)
        => Write("media-sample", ("paused", paused), ("currentTime", currentTime), ("duration", duration));

    private static string? ReadValue(string name) => Environment.GetEnvironmentVariable(name);

    private static Uri? ParseStartUri(string? value)
    {
        if (string.IsNullOrWhiteSpace(value)
            || !Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || uri.Scheme != Uri.UriSchemeHttps
            || !uri.IsDefaultPort
            || uri.UserInfo.Length != 0
            || !uri.Host.Equals("music.youtube.com", StringComparison.OrdinalIgnoreCase))
            return null;
        return uri;
    }

    private static string[] ParseFeatureList(string? value)
        => (value ?? string.Empty).Split(',', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries);

    private static IReadOnlyList<BenchScheduledAction> ParseSchedule(string? value)
    {
        var actions = new List<(BenchScheduledAction Action, int Order)>();
        var order = 0;
        foreach (var entry in (value ?? string.Empty).Split(';', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            var separator = entry.LastIndexOf('@');
            if (separator <= 0 || separator == entry.Length - 1) continue;
            var action = entry[..separator].Trim().ToLowerInvariant();
            if (action is not ("compact" or "full" or "hide" or "show" or "quit")
                || !double.TryParse(entry[(separator + 1)..].Trim(), NumberStyles.Float, CultureInfo.InvariantCulture, out var seconds)
                || !double.IsFinite(seconds) || seconds < 0)
                continue;
            actions.Add((new BenchScheduledAction(action, seconds), order++));
        }
        return actions.OrderBy(item => item.Action.Seconds).ThenBy(item => item.Order)
            .Select(item => item.Action).ToArray();
    }

    private static List<string> Tokenize(string value)
    {
        var tokens = new List<string>();
        var start = -1;
        var quoted = false;
        for (var index = 0; index < value.Length; index++)
        {
            var character = value[index];
            if (start < 0)
            {
                if (char.IsWhiteSpace(character)) continue;
                start = index;
            }
            if (character == '"') quoted = !quoted;
            else if (char.IsWhiteSpace(character) && !quoted)
            {
                tokens.Add(value[start..index]);
                start = -1;
            }
        }
        if (start >= 0) tokens.Add(value[start..]);
        return tokens;
    }

    private static void CollectArguments(
        IReadOnlyList<string> tokens,
        List<string> arguments,
        List<string> enabledFeatures,
        HashSet<string> enabledSet,
        List<string> disabledFeatures,
        HashSet<string> disabledSet)
    {
        for (var index = 0; index < tokens.Count; index++)
        {
            if (!TryReadFeatureSwitch(tokens[index], out var enabled, out var features, out var needsNext))
            {
                arguments.Add(tokens[index]);
                continue;
            }

            if (features is null && needsNext && index + 1 < tokens.Count
                && !tokens[index + 1].TrimStart('"').StartsWith("--", StringComparison.Ordinal))
                features = tokens[++index];
            if (features is null) continue;
            AddFeatures(ParseFeatureList(features.Trim('"')), enabled ? enabledFeatures : disabledFeatures,
                enabled ? enabledSet : disabledSet);
        }
    }

    private static bool TryReadFeatureSwitch(string token, out bool enabled, out string? features, out bool needsNext)
    {
        var normalized = token.Trim().Trim('"');
        var separator = normalized.IndexOf('=');
        var name = separator < 0 ? normalized : normalized[..separator];
        enabled = name.Equals("--enable-features", StringComparison.OrdinalIgnoreCase);
        var disabled = name.Equals("--disable-features", StringComparison.OrdinalIgnoreCase);
        features = separator >= 0 ? normalized[(separator + 1)..].Trim('"') : null;
        needsNext = separator < 0;
        return enabled || disabled;
    }

    private static void AddFeatures(IEnumerable<string> features, List<string> destination, HashSet<string> seen)
    {
        foreach (var feature in features)
        {
            var value = feature.Trim();
            if (value.Length > 0 && seen.Add(value)) destination.Add(value);
        }
    }

    private static long ProcessStartMilliseconds()
    {
        try
        {
            using var process = Process.GetCurrentProcess();
            return new DateTimeOffset(process.StartTime.ToUniversalTime()).ToUnixTimeMilliseconds();
        }
        catch (Exception)
        {
            return DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
        }
    }

    private static void Write(string eventName, params (string Name, object? Value)[] properties)
    {
        if (!Enabled) return;
        try
        {
            var record = new Dictionary<string, object?>(properties.Length + 2)
            {
                ["t"] = (DateTimeOffset.UtcNow - DateTimeOffset.UnixEpoch).TotalMilliseconds,
                ["event"] = eventName
            };
            foreach (var property in properties) record[property.Name] = property.Value;
            var line = JsonSerializer.Serialize(record);
            lock (LogGate)
            {
                try
                {
                    if (_writer is null)
                    {
                        var directory = Path.GetDirectoryName(LogPath!);
                        if (!string.IsNullOrEmpty(directory)) Directory.CreateDirectory(directory);
                        _writer = new StreamWriter(
                            new FileStream(LogPath!, FileMode.Append, FileAccess.Write, FileShare.ReadWrite),
                            new UTF8Encoding(encoderShouldEmitUTF8Identifier: false));
                    }
                    _writer.WriteLine(line);
                    _writer.Flush();
                }
                catch (Exception)
                {
                    try { _writer?.Dispose(); } catch (Exception) { }
                    _writer = null;
                }
            }
        }
        catch (Exception)
        {
        }
    }
}
#endif
