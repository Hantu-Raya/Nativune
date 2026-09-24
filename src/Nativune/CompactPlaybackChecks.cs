using System.Text.Json;

namespace Nativune;

internal static class CompactPlaybackChecks
{
    internal static void Run()
    {
        var payload = new Dictionary<string, object?>
        {
            ["code"] = "state", ["title"] = "Synthetic title", ["artworkUrl"] = null,
            ["paused"] = true, ["position"] = 10d, ["duration"] = 120d,
            ["liked"] = false, ["disliked"] = null, ["repeat"] = "off",
            ["canSeek"] = true, ["canLike"] = true, ["canDislike"] = false,
            ["canRepeat"] = true, ["canShuffle"] = true
        };
        string Json() => JsonSerializer.Serialize(payload);
        Require(CompactPlayback.TryParseState(Json(), out var state) && state is { CanSeek: true, Duration: 120 },
            "Valid bounded playback snapshot was rejected.");
        payload["canSeek"] = false;
        Require(CompactPlayback.TryParseState(Json(), out state)
            && state is { CanSeek: false, CanLike: true, Duration: 120 },
            "A transient seek-clock mismatch discarded otherwise current playback controls.");
        payload["canSeek"] = true;
        foreach (var malformed in new[] { "null", "[]", "true", "12", "\"text\"", "{}", "{broken", new string(' ', 8193) })
            Require(!CompactPlayback.TryParseState(malformed, out _), "Malformed compact state was accepted.");
        payload["duration"] = 0d;
        payload["canSeek"] = false;
        Require(CompactPlayback.TryParseState(Json(), out state) && state is { CanSeek: false, Duration: 0 },
            "Unknown duration discarded otherwise known playback controls.");
        payload["duration"] = 120d;
        payload["position"] = 121d;
        Require(CompactPlayback.TryParseState(Json(), out state)
            && state is { CanSeek: false, Position: 121, Duration: 120 },
            "A bounded transition clock skew discarded otherwise current playback controls.");
        payload["canSeek"] = true;
        Require(!CompactPlayback.TryParseState(Json(), out _),
            "A clock-skewed snapshot with seeking enabled was accepted.");
        payload["position"] = 10d;
        payload["title"] = new string('x', 513);
        Require(!CompactPlayback.TryParseState(Json(), out _), "Oversized playback title was accepted.");
        payload["title"] = "Synthetic title";
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
            && PlayerControls.FormatCompactOutcome(unavailable).Contains("no action was sent", StringComparison.Ordinal),
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
