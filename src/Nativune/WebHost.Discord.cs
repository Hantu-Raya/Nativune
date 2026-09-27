using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

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
        RefreshDiscordSurfaces();
        RefreshSharedReader();
    }

    private void ApplyDiscordOptions(DiscordPresenceOptions options)
    {
        _discord?.ApplyOptions(options);
        RefreshDiscordSurfaces();
        RefreshSharedReader();
    }

    private void RefreshDiscordSurfaces()
    {
        if (_disposed) return;
        var enabled = _settings.Discord.Enabled;
        var status = _discord?.Status ?? DiscordPresenceStatus.Off;
        var connection = status switch
        {
            DiscordPresenceStatus.Connected => "connected",
            DiscordPresenceStatus.DiscordAbsent => "waiting for the Discord app",
            DiscordPresenceStatus.Connecting => "connecting to Discord",
            DiscordPresenceStatus.Error => "connection error",
            DiscordPresenceStatus.Unavailable => "unavailable in this build",
            _ => "waiting for the Discord app"
        };
        var state = enabled ? $"on, {connection}" : "off";
        var name = $"Discord: {state}";
        var description = enabled
            ? $"Discord Rich Presence is on; {connection}. Right-click for Discord settings."
            : "Discord Rich Presence is off. Right-click for Discord settings.";
        AutomationProperties.SetName(DiscordButton, name);
        AutomationProperties.SetHelpText(DiscordButton, description);
        ToolTipService.SetToolTip(DiscordButton, description);
        _discordPresenceItem.IsChecked = enabled;

        if (DiscordButton.Content is BitmapIcon icon)
            icon.Foreground = enabled && !ShellTheme.IsHighContrast
                ? new SolidColorBrush(Windows.UI.Color.FromArgb(0xFF, 0x58, 0x65, 0xF2))
                : null;
        _settingsDialog?.SetDiscordStatus(status);
    }
    private void ObserveDiscord(CompactPlaybackState? state, int epoch)
    {
        var discord = _discord;
        if (discord is null) return;
        if (state is null)
        {
            discord.Observe(null, epoch);
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
            DateTimeOffset.UtcNow,
            state.VideoId), epoch);
    }

    // keepItem (system suspend): clear the card but keep the song's pause deadline and art history.
    private void InvalidateDiscord(bool keepItem = false)
    {
        _presenceGeneration++;
        _presenceUnavailableSince = -1;
        _presenceHasState = false;
        if (keepItem) _discord?.ForgetObservation();
        else _discord?.Observe(null);
    }

    private async Task StopDiscordAsync()
    {
        var discord = _discord;
        if (discord is null) return;
        try { await discord.StopAsync(); }
        catch (Exception) { }
    }
}
