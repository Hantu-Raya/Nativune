#if NATIVUNE_DISCORD_TEST_HOOKS
using System.Buffers.Binary;
using System.IO.Compression;
using System.Text.RegularExpressions;

namespace Nativune;

// Hook state reported in the bench "overlay" object (design.md §2.8). Wire state names are lower case.
internal readonly record struct ObsOverlayHookState(string LatestState, bool LatestStale, double LatestPosition,
    double? LatestDuration, int FixtureArtServed, bool PendingWrite, string? LastStreamEndReason, bool HidePaused,
    ObsOverlayHookDiagnostics Diagnostics);

// Test-hook half of ObsOverlayServer (design.md §2.8, §4); compiled only with -p:DiscordPresenceTestHooks=true.
// It is the only code that names the fixture artwork URLs, delayMs/-d<ms> delays or the hooks script.
internal sealed partial class ObsOverlayServer
{
    private const int FixtureArtMaxDelayMs = 5000;
    private static readonly Regex s_fixtureArtwork = new("^/fixture-([abc])=w544-h544(?:-d([0-9]{1,4}))?$",
        RegexOptions.CultureInvariant);
    private static readonly Lazy<byte[]> s_hooksScript = new(() =>
    {
        using var stream = typeof(ObsOverlayServer).Assembly.GetManifestResourceStream("Nativune.ObsOverlayPage.hooks.js")
            ?? throw new InvalidOperationException("The OBS overlay hook script resource is missing.");
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return buffer.ToArray();
    });
    private static readonly Lazy<byte[]>[] s_fixtureArt =
    [
        new(() => FixtureArtPng(0)), new(() => FixtureArtPng(1)), new(() => FixtureArtPng(2))
    ];

    private int _hookFixtureArtServed;
    private int _hookPendingWrites;
    private string? _hookLastStreamEnd;

    partial void HookAppendScript(ref byte[] overlayJs)
    {
        var hooks = s_hooksScript.Value;
        var combined = new byte[overlayJs.Length + 1 + hooks.Length];
        overlayJs.CopyTo(combined, 0);
        combined[overlayJs.Length] = (byte)'\n';
        hooks.CopyTo(combined, overlayJs.Length + 1);
        overlayJs = combined;
    }

    // The fixture artwork URLs never leave the machine: the fetcher seam answers them with the fixture PNG, after
    // the -d<ms> delay, so the E2E runs through the real /art/ route, cache and single-flight.
    partial void HookFetchArtwork(string url, CancellationToken cancellation, ref Task<ArtworkPayload?>? fetch)
    {
        if (TryFixtureArtwork(url, out var letter, out var delay))
            fetch = FixtureFetchAsync(letter, delay, cancellation);
        else if (Uri.TryCreate(url, UriKind.Absolute, out var uri)
            && uri.Host.Equals("lh3.googleusercontent.com", StringComparison.OrdinalIgnoreCase)
            && uri.AbsolutePath.StartsWith("/fixture-", StringComparison.Ordinal))
            fetch = Task.FromResult<ArtworkPayload?>(null); // the fixture's "missing" art: a failed fetch, never a real request
    }

    partial void HookArtServed(string url)
    {
        if (TryFixtureArtwork(url, out _, out _)) Interlocked.Increment(ref _hookFixtureArtServed);
    }

    private static async Task<ArtworkPayload?> FixtureFetchAsync(int letter, int delay, CancellationToken cancellation)
    {
        if (delay > 0) await Task.Delay(delay, cancellation).ConfigureAwait(false);
        return new ArtworkPayload(s_fixtureArt[letter].Value, "image/png", 128, 128);
    }

    private static bool TryFixtureArtwork(string url, out int letter, out int delay)
    {
        letter = 0;
        delay = 0;
        if (!Uri.TryCreate(url, UriKind.Absolute, out var uri) || uri.Scheme != Uri.UriSchemeHttps
            || !uri.Host.Equals("lh3.googleusercontent.com", StringComparison.OrdinalIgnoreCase) || uri.Query.Length != 0)
            return false;
        var match = s_fixtureArtwork.Match(uri.AbsolutePath);
        if (!match.Success) return false;
        letter = match.Groups[1].Value[0] - 'a';
        if (match.Groups[2].Success)
            delay = Math.Min(int.Parse(match.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture), FixtureArtMaxDelayMs);
        return true;
    }

    partial void HookStreamOpened() => Interlocked.Exchange(ref _hookFixtureArtServed, 0);

    partial void HookStreamEnded(ObsOverlayStreamEnd reason) => Volatile.Write(ref _hookLastStreamEnd, reason.ToString());

    partial void HookWriteStarted(bool pending)
    {
        if (pending) Interlocked.Increment(ref _hookPendingWrites);
        else Interlocked.Decrement(ref _hookPendingWrites);
    }

    // command-obs-burst: one 8 MiB comment queued to the first registered stream (its pump writes it after any look or
    // data it already took out of the slots). No-op once stopped.
    internal void HookBurst()
    {
        StreamEntry target;
        lock (_gate)
        {
            if (_stopping || _streams.Count == 0) return;
            target = _streams[0];
            target.PendingComment = ": " + new string('x', 8 * 1024 * 1024) + "\n\n";
        }
        target.Wake();
    }

    internal ObsOverlayHookState HookState()
    {
        var diagnostics = HookDiagnostics();
        lock (_gate)
        {
            var latest = _latest;
            return new ObsOverlayHookState(latest.State.ToString().ToLowerInvariant(), _latestStale, latest.Position,
                latest.Duration, Volatile.Read(ref _hookFixtureArtServed), Volatile.Read(ref _hookPendingWrites) > 0,
                Volatile.Read(ref _hookLastStreamEnd), _hidePaused, diagnostics);
        }
    }

    // 128x128 RGB: a diagonal gradient whose hue differs per letter, plus a bright top-left 48x48 quadrant
    // so a mirrored or cropped rendering is detectable.
    private static byte[] FixtureArtPng(int letter)
    {
        const int size = 128, bright = 48;
        var raw = new byte[size * (1 + size * 3)];
        for (var y = 0; y < size; y++)
        {
            var row = y * (1 + size * 3);
            for (var x = 0; x < size; x++)
            {
                var t = (byte)((x + y) * 255 / (2 * (size - 1)));
                var low = (byte)(t / 4);
                var (r, g, b) = letter switch { 0 => (t, low, low), 1 => (low, low, t), _ => (low, t, low) };
                if (x < bright && y < bright) (r, g, b) = ((byte)(r / 2 + 128), (byte)(g / 2 + 128), (byte)(b / 2 + 128));
                raw[row + 1 + x * 3] = r;
                raw[row + 2 + x * 3] = g;
                raw[row + 3 + x * 3] = b;
            }
        }
        byte[] compressed;
        using (var buffer = new MemoryStream())
        {
            using (var zlib = new ZLibStream(buffer, CompressionLevel.Optimal, leaveOpen: true)) zlib.Write(raw);
            compressed = buffer.ToArray();
        }
        var header = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(0), size);
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), size);
        header[8] = 8; // bit depth
        header[9] = 2; // truecolour
        using var png = new MemoryStream();
        png.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        WebHostWindow.WriteDiscordFixtureChunk(png, "IHDR", header);
        WebHostWindow.WriteDiscordFixtureChunk(png, "IDAT", compressed);
        WebHostWindow.WriteDiscordFixtureChunk(png, "IEND", []);
        return png.ToArray();
    }
}
#endif
