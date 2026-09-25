namespace Nativune;

// Decides when Compact's Like/Dislike may act. YouTube Music skips a track once it is disliked, so a
// rating is bound to the item the user could see: a newly shown item must stay on screen briefly
// before it can be rated, and after one rating is sent the buttons wait until the website shows
// its result (a new rating or a new item) instead of accepting clicks that would reach the next song.
internal sealed class CompactRatingGate
{
    internal const long ArmDelayMs = 1200;
    internal const long ResultWaitMs = 4000;

    private string? _item;
    private long _itemShownAt;
    private string? _pendingItem;
    private bool? _pendingLiked, _pendingDisliked;
    private long _pendingSince;

    // Called with every confirmed website snapshot (or null when none is shown).
    internal void Observe(string? item, bool? liked, bool? disliked, long now)
    {
        if (!string.Equals(item, _item, StringComparison.Ordinal))
        {
            _item = item;
            _itemShownAt = now;
        }
        if (_pendingItem is null) return;
        if (!string.Equals(item, _pendingItem, StringComparison.Ordinal)
            || liked != _pendingLiked || disliked != _pendingDisliked
            || now - _pendingSince >= ResultWaitMs)
            _pendingItem = null;
    }

    internal bool Allows(long now)
        => _item is not null && _pendingItem is null && now - _itemShownAt >= ArmDelayMs;

    // The item and rating the click was based on; cleared by the website's next differing snapshot.
    internal void Sent(bool? liked, bool? disliked, long now)
    {
        _pendingItem = _item;
        _pendingLiked = liked;
        _pendingDisliked = disliked;
        _pendingSince = now;
    }

    // Nothing reached the website, so the item may be rated again.
    internal void NotSent() => _pendingItem = null;

    internal long? ReadyAt(long now)
        => _item is null || _pendingItem is not null ? null
            : now - _itemShownAt >= ArmDelayMs ? now : _itemShownAt + ArmDelayMs;
}
