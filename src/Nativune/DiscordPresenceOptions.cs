namespace Nativune;

// Settings > Discord. Persisted in settings.json v7 as DiscordPresence / DiscordStatusLine / DiscordOpenButton.
internal enum DiscordStatusLine
{
    Artist = 0,   // status_display_type 1 (state); falls back to the app name when the artist is unknown
    Title = 1,    // status_display_type 2 (details)
    AppName = 2   // status_display_type 0 (name)
}

internal readonly record struct DiscordPresenceOptions(bool Enabled, DiscordStatusLine StatusLine, bool ShowOpenButton)
{
    internal static DiscordPresenceOptions Default => new(false, DiscordStatusLine.Artist, true);
}

internal enum DiscordPresenceStatus
{
    Off,            // feature disabled
    Unavailable,    // this build has no Discord application id
    Connecting,
    Connected,      // IPC handshake READY
    DiscordAbsent,  // no discord-ipc pipe; retrying with backoff
    Error           // protocol or payload error; playback unaffected
}

// One validated observation of the playing item, built by the host from the shared page snapshot.
// Never logged or persisted.
internal sealed record DiscordTrackObservation(
    string Title,
    string? Artist,
    string? ArtworkUrl,
    string? TrackUrl,
    string? ArtistUrl,
    bool Paused,
    bool RepeatOne,
    double? PositionSeconds,
    double? DurationSeconds,
    bool ClockConfirmed,
    bool Ended,
    bool Seeking,
    double? PlaybackRate,
    long SampleMonotonicMs,
    DateTimeOffset SampleUtc,
    string? VideoId = null);
