using System.Text;
using System.Text.Json;

namespace Nativune;

internal enum ObsOverlayState { None, Playing, Paused, Ended, Ad }

// Immutable sample of one successful read. CaptureTicks = Environment.TickCount64 at read completion.
// For Ad and None every field except State and CaptureTicks is null/0/false, so they compare equal by
// value and the broadcast rule stays quiet for the whole ad or gap.
internal sealed record ObsOverlaySnapshot(
    ObsOverlayState State,
    string? Id,
    string? Title,
    string? Artist,
    string? Artwork,
    double? Duration,
    double Position,
    double Rate,
    bool Clock,
    long CaptureTicks)
{
    private const int MaxText = 300;

    internal static ObsOverlaySnapshot None(long captureTicks) =>
        new(ObsOverlayState.None, null, null, null, null, null, 0, 0, false, captureTicks);

    internal static ObsOverlaySnapshot FromState(CompactPlaybackState state, long captureTicks)
    {
        if (state.IsAd)
            return new(ObsOverlayState.Ad, null, null, null, null, null, 0, 0, false, captureTicks);

        var title = Truncate(state.Title?.Trim());
        if (title is null) return None(captureTicks);
        var artist = Truncate(state.Artist?.Trim());
        var kind = state.Ended ? ObsOverlayState.Ended
            : state.Paused ? ObsOverlayState.Paused
            : ObsOverlayState.Playing;
        double? duration = double.IsFinite(state.Duration) && state.Duration > 0 ? state.Duration : null;
        var position = double.IsFinite(state.Position) ? Math.Max(0, state.Position) : 0;
        if (duration is { } d && position > d) position = d;
        var rate = state.PlaybackRate is { } r && double.IsFinite(r) ? Math.Clamp(r, 0.25, 4) : 1;
        var artwork = CompactArtwork.IsAllowedUrl(state.ArtworkUrl) ? state.ArtworkUrl : null;
        var id = !string.IsNullOrEmpty(state.VideoId) ? state.VideoId : "t:" + title + "\u0001" + artist;
        var clock = state.ClockConfirmed && !state.ClockMismatch && !state.Seeking;
        return new(kind, id, title, artist, artwork, duration, position, rate, clock, captureTicks);
    }

    private static string? Truncate(string? value) =>
        string.IsNullOrEmpty(value) ? null : value.Length > MaxText ? value[..MaxText] : value;

    internal bool HasMetadata => State is ObsOverlayState.Playing or ObsOverlayState.Paused or ObsOverlayState.Ended;

    internal static bool ShouldBroadcast(ObsOverlaySnapshot anchor, ObsOverlaySnapshot sample, long nowTicks)
    {
        if (!string.Equals(anchor.Id, sample.Id, StringComparison.Ordinal)
            || !string.Equals(anchor.Title, sample.Title, StringComparison.Ordinal)
            || !string.Equals(anchor.Artist, sample.Artist, StringComparison.Ordinal)
            || !string.Equals(anchor.Artwork, sample.Artwork, StringComparison.Ordinal)
            || anchor.State != sample.State
            || anchor.Duration != sample.Duration
            || anchor.Rate != sample.Rate
            || anchor.Clock != sample.Clock)
            return true;
        if (sample.State == ObsOverlayState.Playing && sample.Clock && sample.Duration is not null
            && Math.Abs(sample.Position - Projected(anchor, nowTicks)) > 1.5)
            return true;
        if (sample.State == ObsOverlayState.Paused && Math.Abs(sample.Position - anchor.Position) > 0.5)
            return true;
        return false;
    }

    internal static double Projected(ObsOverlaySnapshot anchor, long nowTicks)
    {
        var p = anchor.Position + (nowTicks - anchor.CaptureTicks) / 1000.0 * anchor.Rate;
        return Math.Clamp(p, 0, anchor.Duration ?? double.PositiveInfinity);
    }

    internal string ToJson(long nowTicks, bool hidePaused)
    {
        using var buffer = new MemoryStream(256);
        using (var w = new Utf8JsonWriter(buffer))
        {
            w.WriteStartObject();
            w.WriteNumber("v", 1);
            w.WriteString("state", State switch
            {
                ObsOverlayState.Playing => "playing",
                ObsOverlayState.Paused => "paused",
                ObsOverlayState.Ended => "ended",
                ObsOverlayState.Ad => "ad",
                _ => "none",
            });
            if (HasMetadata)
            {
                w.WriteString("id", Id);
                w.WriteString("title", Title);
                w.WriteString("artist", Artist);
                w.WriteString("artwork", Artwork);
                if (Duration is { } d) w.WriteNumber("duration", d);
                else w.WriteNull("duration");
                w.WriteNumber("position", Position);
                w.WriteNumber("rate", Rate);
                w.WriteBoolean("clock", Clock);
                w.WriteNumber("ageMs", Math.Max(0, nowTicks - CaptureTicks));
                w.WriteBoolean("hidePaused", hidePaused);
            }
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(buffer.GetBuffer(), 0, (int)buffer.Length);
    }
}
