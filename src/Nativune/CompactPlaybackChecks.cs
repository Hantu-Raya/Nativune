using System.Text.Json;

namespace Nativune;

internal static class CompactPlaybackChecks
{
    internal static void Run()
    {
        var payload = new Dictionary<string, object?>
        {
            ["code"] = "state", ["title"] = "Synthetic title", ["artworkUrl"] = null,
            ["videoId"] = "AbCdEfGhI01",
            ["paused"] = true, ["position"] = 10d, ["duration"] = 120d,
            ["mediaDuration"] = 120d, ["mediaPosition"] = 10d,
            ["websiteClock"] = false,
            ["liked"] = false, ["disliked"] = null, ["repeat"] = "off",
            ["canSeek"] = true, ["canLike"] = true, ["canDislike"] = false,
            ["canRepeat"] = true, ["canShuffle"] = true, ["shuffle"] = false,
            ["clockMismatch"] = false, ["clockConfirmed"] = true
        };
        string Json() => JsonSerializer.Serialize(payload);
        Require(CompactPlayback.TryParseState(Json(), out var state) && state is { CanSeek: true, Duration: 120 },
            "Valid bounded playback snapshot was rejected.");
        payload["position"] = -1d;
        Require(!CompactPlayback.TryParseState(Json(), out _),
            "A negative seekable playback position escaped the state boundary.");
        payload["position"] = 10d;
        payload["mediaPosition"] = 121d;
        payload["canSeek"] = true;
        Require(!CompactPlayback.TryParseState(Json(), out _),
            "A media position beyond duration was presented as seekable.");
        payload["mediaPosition"] = 10d;
        payload["canSeek"] = true;
        payload["mediaPosition"] = "10";
        Require(!CompactPlayback.TryParseState(Json(), out _),
            "Untrusted nonnumeric media clock escaped the state boundary.");
        payload["mediaPosition"] = 10d;
        payload["shuffle"] = true;
        Require(CompactPlayback.TryParseState(Json(), out state) && state is { Shuffle: true },
            "Confirmed Shuffle-on state was lost from the bounded public snapshot.");
        payload["shuffle"] = null;
        Require(CompactPlayback.TryParseState(Json(), out state) && state is { Shuffle: null, CanShuffle: true },
            "Unknown Shuffle state was falsely treated as off or disabled.");
        payload["shuffle"] = "on";
        Require(!CompactPlayback.TryParseState(Json(), out _), "Untrusted Shuffle state escaped boolean validation.");
        payload["shuffle"] = false;
        payload["canSeek"] = false;
        Require(CompactPlayback.TryParseState(Json(), out state)
            && state is { CanSeek: false, ClockConfirmed: true, CanLike: true, Duration: 120 },
            "A coherent public clock was discarded merely because seeking is unavailable.");
        payload["clockConfirmed"] = false;
        payload["clockMismatch"] = true;
        Require(CompactPlayback.TryParseState(Json(), out state)
            && state is { ClockMismatch: true, CanSeek: false },
            "Observed website/media clock disagreement was not represented without enabling seeking.");
        payload["clockConfirmed"] = true;
        Require(!CompactPlayback.TryParseState(Json(), out _),
            "Contradictory confirmed and mismatched clocks were accepted.");
        payload["clockMismatch"] = false;
        payload["clockConfirmed"] = true;
        payload["canSeek"] = true;
        // Signed-in playback can place several items on one growing media timeline.
        // A coherent website clock and slider stay authoritative for display and seeking.
        payload["paused"] = false;
        payload["websiteClock"] = true;
        payload["position"] = 94d;
        payload["duration"] = 193d;
        payload["mediaDuration"] = 389.2d;
        payload["mediaPosition"] = 364.1d;
        Require(CompactPlayback.TryParseState(Json(), out state)
            && state is { WebsiteClock: true, Position: 94, Duration: 193, MediaDuration: 389.2,
                ClockMismatch: false, ClockConfirmed: true, CanSeek: true }
            && CompactPlayback.ComputeSignature(state) == "[\"Synthetic title\",null,193,\"AbCdEfGhI01\"]",
            "A coherent website clock over a cumulative media timeline lost interactive seek or item identity.");
        Require(CompactPlayback.ComputeSignature(state! with { MediaDuration = 462.4, MediaPosition = 441.2 })
                == CompactPlayback.ComputeSignature(state!)
            && CompactPlayback.ComputeSignature(state! with { VideoId = "abcdefghijk" })
                != CompactPlayback.ComputeSignature(state!)
            && CompactPlayback.ComputeSignature(state! with { Duration = 194 })
                != CompactPlayback.ComputeSignature(state!),
            "Growing media duration invalidated a same-item seek, or an item change kept its signature.");
        payload["mediaPosition"] = 400d;
        Require(CompactPlayback.TryParseState(Json(), out state) && state is { CanSeek: true },
            "A display-only media overrun disabled the website-clock seek route.");
        payload["mediaPosition"] = 364.1d;
        payload["clockMismatch"] = true;
        Require(!CompactPlayback.TryParseState(Json(), out _),
            "A mismatched website clock was allowed to seek.");
        payload["clockMismatch"] = false;
        payload["clockConfirmed"] = false;
        Require(!CompactPlayback.TryParseState(Json(), out _),
            "An unconfirmed website clock was allowed to seek.");
        payload["clockConfirmed"] = true;
        payload["paused"] = true;
        payload["mediaDuration"] = null;
        Require(!CompactPlayback.TryParseState(Json(), out _),
            "Missing media duration escaped the website-clock boundary.");
        payload["mediaDuration"] = 378d;
        payload["websiteClock"] = "true";
        Require(!CompactPlayback.TryParseState(Json(), out _),
            "Nonboolean website-clock proof escaped the state boundary.");
        payload["websiteClock"] = false;
        payload["mediaDuration"] = 120d;
        payload["mediaPosition"] = 10d;
        payload["position"] = 10d;
        payload["duration"] = 120d;
        payload["canSeek"] = true;
        payload["clockMismatch"] = false;
        payload["clockConfirmed"] = true;
        foreach (var malformed in new[] { "null", "[]", "true", "12", "\"text\"", "{}", "{broken", new string(' ', 8193) })
            Require(!CompactPlayback.TryParseState(malformed, out _), "Malformed compact state was accepted.");
        payload["clockConfirmed"] = false;
        payload["duration"] = 0d;
        payload["mediaDuration"] = 0d;
        payload["canSeek"] = false;
        Require(CompactPlayback.TryParseState(Json(), out state) && state is { CanSeek: false, Duration: 0 },
            "Unknown duration discarded otherwise known playback controls.");
        payload["duration"] = 120d;
        payload["mediaDuration"] = 120d;
        payload["position"] = 121d;
        Require(CompactPlayback.TryParseState(Json(), out state)
            && state is { CanSeek: false, Position: 121, Duration: 120 },
            "A bounded transition clock skew discarded otherwise current playback controls.");
        payload["canSeek"] = true;
        Require(!CompactPlayback.TryParseState(Json(), out _),
            "Seeking was enabled without a confirmed public clock.");
        payload["clockConfirmed"] = true;
        Require(!CompactPlayback.TryParseState(Json(), out _),
            "A clock-skewed snapshot with seeking enabled was accepted.");
        payload["position"] = 10d;
        payload["title"] = new string('x', 513);
        Require(!CompactPlayback.TryParseState(Json(), out _), "Oversized playback title was accepted.");
        payload["title"] = "Synthetic title";
        payload["videoId"] = "not-an-id";
        Require(!CompactPlayback.TryParseState(Json(), out _),
            "Malformed public video identity passed the state boundary.");
        payload["videoId"] = null;
        Require(CompactPlayback.TryParseState(Json(), out state) && state is { VideoId: null },
            "Unidentified public playback was rejected instead of failing closed on fallback.");
        payload["videoId"] = "AbCdEfGhI01";
        payload["artworkUrl"] = "https://i.ytimg.com.evil.example/image.jpg";
        Require(!CompactPlayback.TryParseState(Json(), out _), "Untrusted artwork escaped the state parser.");
        foreach (var host in new[] { "lh3.googleusercontent.com", "i.ytimg.com", "yt3.ggpht.com", "yt3.googleusercontent.com" })
            Require(CompactArtwork.IsAllowedUrl("https://" + host + "/synthetic.jpg"), "Approved artwork host was rejected.");
        foreach (var url in new[] { "http://i.ytimg.com/a", "https://i.ytimg.com:444/a", "https://user@i.ytimg.com/a",
            "https://i.ytimg.com.evil.example/a", "file:///a", "https://localhost/a", "data:image/png,aaa" })
            Require(!CompactArtwork.IsAllowedUrl(url), "Artwork origin or credential boundary was bypassed.");
        Require(CompactPlayback.TryParseOutcome("{\"code\":\"script-error\",\"dispatched\":true}", out var result)
            && result.Dispatched, "Dispatched failure lost its uncertain-action status.");
        Require(CompactPlayback.TryParseOutcome("{\"code\":\"unavailable\",\"dispatched\":true}", out var dispatchedUnavailable)
            && PlayerControls.FormatCompactOutcome(dispatchedUnavailable) == "Player action outcome unknown; no retry."
            && CompactPlayback.TryParseOutcome("{\"code\":\"requested\",\"dispatched\":true}", out var requestedOutcome)
            && PlayerControls.FormatCompactOutcome(requestedOutcome) == PlayerControls.CompactRequestedStatus
            && CompactPlayback.TryParseOutcome("{\"code\":\"unavailable\"}", out var unavailable)
            && PlayerControls.FormatCompactOutcome(unavailable).Contains("no action was sent", StringComparison.Ordinal)
            && !CompactPlayback.TryParseOutcome("{\"code\":\"unseekable-target\"}", out _),
            "Compact dispatch status confused an uncertain side effect with a confirmed no-op.");
        Require(CompactPlayback.IsTransportReadyResponse("{\"code\":\"ready\"}")
            && !CompactPlayback.IsTransportReadyResponse("{\"code\":\"unavailable\"}")
            && !CompactPlayback.IsTransportReadyResponse("{broken")
            && !CompactPlayback.IsTransportReadyResponse(new string(' ', CompactPlayback.MaxScriptResultLength + 1)),
            "Compact transport readiness parser accepted a malformed or unconfirmed result.");
        Console.WriteLine("Compact playback checks passed: bounded state without audio volume controls, seek recovery, transport readiness, and artwork-origin restrictions.");
    }

    private static void Require(bool value, string message)
    {
        if (!value) throw new SelfCheckException(message);
    }
}
