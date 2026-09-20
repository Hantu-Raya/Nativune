using System.Text.Json;

namespace Nativune;

internal static class CompactPlaybackChecks
{
    internal static void Run()
    {
        var payload = new Dictionary<string, object?>
        {
            ["code"] = "state", ["title"] = "Synthetic title", ["artworkUrl"] = null,
            ["paused"] = true, ["position"] = 10d, ["duration"] = 120d, ["volume"] = .5,
            ["muted"] = false, ["liked"] = false, ["disliked"] = null, ["repeat"] = "off",
            ["canSeek"] = true, ["canVolume"] = true, ["canLike"] = true,
            ["canDislike"] = false, ["canRepeat"] = true, ["canShuffle"] = true
        };
        string Json() => JsonSerializer.Serialize(payload);
        Require(CompactPlayback.TryParseState(Json(), out var state) && state is { CanSeek: true, Duration: 120 },
            "Valid bounded playback snapshot was rejected.");
        foreach (var malformed in new[] { "null", "[]", "true", "12", "\"text\"", "{}", "{broken", new string(' ', 8193) })
            Require(!CompactPlayback.TryParseState(malformed, out _), "Malformed compact state was accepted.");
        payload["duration"] = 0d;
        payload["canSeek"] = false;
        Require(CompactPlayback.TryParseState(Json(), out state) && state is { CanSeek: false, Duration: 0 },
            "Unknown duration discarded otherwise known playback controls.");
        payload["duration"] = 120d;
        payload["position"] = 121d;
        Require(!CompactPlayback.TryParseState(Json(), out _), "Out-of-range playback position was accepted.");
        payload["position"] = 10d;
        payload["volume"] = 1.1;
        Require(!CompactPlayback.TryParseState(Json(), out _), "Out-of-range volume was accepted.");
        payload["volume"] = .5;
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
        Console.WriteLine("Compact playback checks passed: malformed/bounded state, unknown seeking and artwork origin restrictions.");
    }

    private static void Require(bool value, string message)
    {
        if (!value) throw new SelfCheckException(message);
    }
}
