namespace Nativune;

public sealed partial class WebHostWindow
{
    private DiscordPresence? _discord;

    private void InitializeDiscordPresence()
    {
        if (_discord is not null) return;
        _discord = new DiscordPresence(DiscordPresenceEnvironment.FromProcess());
        _discord.StatusChanged += (_, _) => OnDiscordStatusChanged();
        _discord.ApplyOptions(_settings.Discord);
    }

    private void OnDiscordStatusChanged()
    {
        if (!_dispatcherQueue.HasThreadAccess)
        {
            _dispatcherQueue.TryEnqueue(OnDiscordStatusChanged);
            return;
        }
        if (_disposed || _discord is null) return;
        _settingsDialog?.SetDiscordStatus(_discord.Status);
        RefreshSharedReader();
    }

    private void ApplyDiscordOptions(DiscordPresenceOptions options)
    {
        _discord?.ApplyOptions(options);
        RefreshSharedReader();
    }

    private void ObserveDiscord(CompactPlaybackState? state)
    {
        var discord = _discord;
        if (discord is null) return;
        if (state is null)
        {
            discord.Observe(null);
            return;
        }
        discord.Observe(new DiscordTrackObservation(
            state.Title,
            state.Artist,
            state.ArtworkUrl,
            state.TrackUrl,
            state.ArtistUrl,
            state.Paused,
            string.Equals(state.Repeat, "one", StringComparison.Ordinal),
            state.Position,
            state.Duration > 0 ? state.Duration : null,
            state.ClockConfirmed && !state.ClockMismatch,
            state.Ended,
            state.Seeking,
            state.PlaybackRate,
            Environment.TickCount64,
            DateTimeOffset.UtcNow));
    }

    private void InvalidateDiscord()
    {
        _presenceGeneration++;
        _presenceUnavailableSince = -1;
        _presenceHasState = false;
        _discord?.Observe(null);
    }

    private async Task StopDiscordAsync()
    {
        var discord = _discord;
        if (discord is null) return;
        try { await discord.StopAsync(); }
        catch (Exception) { }
    }
}
