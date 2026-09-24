namespace Nativune;

// Ephemeral public-page display state, never serialized into settings or diagnostics.
internal sealed record CompactPlaybackState(
    string Title, string? ArtworkUrl, bool Paused, double Position, double Duration,
    bool? Liked, bool? Disliked, string? Repeat,
    bool CanSeek, bool CanLike, bool CanDislike, bool CanRepeat, bool CanShuffle,
    bool? Shuffle = null, bool ClockMismatch = false, string? VideoId = null,
    bool ClockConfirmed = false, double? MediaDuration = null, bool WebsiteClock = false,
    double? MediaPosition = null);
