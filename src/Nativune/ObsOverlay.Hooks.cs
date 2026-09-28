#if NATIVUNE_DISCORD_TEST_HOOKS
using System.Buffers.Binary;
using System.IO.Compression;
using System.Net;
using System.Text.RegularExpressions;

namespace Nativune;

// Hook state reported in the bench "overlay" object (design.md §2.8). Wire state names are lower case.
internal readonly record struct ObsOverlayHookState(string LatestState, bool LatestStale, double LatestPosition,
    double? LatestDuration, int FixtureArtServed, bool PendingWrite, string? LastStreamEndReason, bool HidePaused);

// Test-hook half of ObsOverlayServer (design.md §2.8, §4); compiled only with -p:DiscordPresenceTestHooks=true.
// It is the only code that names /fixture-art, delayMs, the -d<ms> suffix, 'self' in img-src or the hooks script.
internal sealed partial class ObsOverlayServer
{
    private const string FixtureArtPrefix = "/fixture-art/";
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

    partial void HookTryRoute(HttpListenerRequest request, ref ObsOverlayResponse? response)
    {
        var path = request.Url!.AbsolutePath;
        if (path is not ("/fixture-art/a.png" or "/fixture-art/b.png" or "/fixture-art/c.png")) return;
        var query = request.Url.Query;
        var delayMs = 0;
        if (query.Length != 0)
        {
            const string head = "?delayMs=";
            var digits = query.StartsWith(head, StringComparison.Ordinal) ? query.AsSpan(head.Length) : default;
            if (digits.Length is < 1 or > 4 || !IsAsciiDigits(digits)
                || (delayMs = int.Parse(digits, provider: System.Globalization.CultureInfo.InvariantCulture)) > FixtureArtMaxDelayMs)
            {
                response = new ObsOverlayResponse(400, null, null);
                return;
            }
        }
        if (delayMs > 0) Thread.Sleep(delayMs); // pool-thread request handler
        Interlocked.Increment(ref _hookFixtureArtServed);
        response = new ObsOverlayResponse(200, "image/png", s_fixtureArt[path[FixtureArtPrefix.Length] - 'a'].Value);
    }

    partial void HookExtendImageSources(ref string imgSrc) => imgSrc += " 'self'";

    partial void HookAppendScript(ref byte[] overlayJs)
    {
        var hooks = s_hooksScript.Value;
        var combined = new byte[overlayJs.Length + 1 + hooks.Length];
        overlayJs.CopyTo(combined, 0);
        combined[overlayJs.Length] = (byte)'\n';
        hooks.CopyTo(combined, overlayJs.Length + 1);
        overlayJs = combined;
    }

    partial void HookRewriteArtwork(ref string? artwork)
    {
        if (artwork is null || !Uri.TryCreate(artwork, UriKind.Absolute, out var uri)
            || uri.Scheme != Uri.UriSchemeHttps || !uri.Host.Equals("lh3.googleusercontent.com", StringComparison.OrdinalIgnoreCase)
            || uri.Query.Length != 0)
            return;
        var match = s_fixtureArtwork.Match(uri.AbsolutePath);
        if (!match.Success) return;
        var delay = match.Groups[2].Success ? int.Parse(match.Groups[2].Value, System.Globalization.CultureInfo.InvariantCulture) : 0;
        artwork = Prefix + "fixture-art/" + match.Groups[1].Value + ".png?delayMs=" + Math.Min(delay, FixtureArtMaxDelayMs);
    }

    partial void HookStreamOpened() => Interlocked.Exchange(ref _hookFixtureArtServed, 0);

    partial void HookStreamEnded(ObsOverlayStreamEnd reason) => Volatile.Write(ref _hookLastStreamEnd, reason.ToString());

    partial void HookWriteStarted(bool pending)
    {
        if (pending) Interlocked.Increment(ref _hookPendingWrites);
        else Interlocked.Decrement(ref _hookPendingWrites);
    }

    // command-obs-burst: one 8 MiB comment queued to the first registered stream. No-op once stopped.
    internal void HookBurst()
    {
        lock (_gate)
        {
            if (_stopping || _streams.Count == 0) return;
            _streams[0].Messages.Writer.TryWrite(": " + new string('x', 8 * 1024 * 1024) + "\n\n");
        }
    }

    internal ObsOverlayHookState HookState()
    {
        lock (_gate)
        {
            var latest = _latest;
            return new ObsOverlayHookState(latest.State.ToString().ToLowerInvariant(), _latestStale, latest.Position,
                latest.Duration, Volatile.Read(ref _hookFixtureArtServed), Volatile.Read(ref _hookPendingWrites) > 0,
                Volatile.Read(ref _hookLastStreamEnd), _hidePaused);
        }
    }

    private static bool IsAsciiDigits(ReadOnlySpan<char> value)
    {
        foreach (var c in value)
            if (c is < '0' or > '9') return false;
        return true;
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
