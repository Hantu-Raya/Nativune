namespace OAuthProbe;

// Ephemeral public-page display state, never serialized into settings or diagnostics.
internal sealed record CompactPlaybackState(
    string Title, string? ArtworkUrl, bool Paused, double Position, double Duration,
    double Volume, bool Muted, bool? Liked, bool? Disliked, string? Repeat,
    bool CanSeek, bool CanVolume, bool CanLike, bool CanDislike, bool CanRepeat, bool CanShuffle);
