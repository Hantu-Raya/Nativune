using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;

namespace Nativune;

public sealed partial class WebHostWindow
{
    private const int CompactReadinessProbeLimit = 8;
    private const string CompactReadinessFallbackStatus =
        "Website playback controls are not ready. Compact controls will stay unavailable until they load; use Return to full to continue browsing.";
    private const string CompactReadinessCheckingStatus =
        "Checking the website playback controls before opening Compact.";
    private DispatcherQueueTimer _playbackReadTimer = null!;
    private bool _compactActivity;
    private bool _playbackReadPending;
    private int _compactGeneration;
    // Last shared playback read (Compact or presence). Name kept for WebHost.cs, which zeroes it
    // after a user command so the next tick reads the command's result.
    private long _lastCompactReadAt = -1000;
    private CompactPlaybackState? _compactState;
    private bool _compactReadinessProbePending;
    private CancellationTokenSource? _compactArtworkCancellation;
    private string? _compactArtworkUrl;
    // Song changes briefly leave the website without a coherent player (title, clock or buttons
    // missing). Keep showing the last confirmed item for this long before reporting it unavailable;
    // item-bound actions stay safe meanwhile because the page script re-checks the item identity.
    private const long CompactHoldMs = 8000;
    private long _compactUnavailableSince = -1;
    // Discord presence shares the Compact read path; its hold is tracked separately so Compact
    // invalidation (deactivate, hide) does not clear presence.
    private const long PresenceReadIntervalMs = 5000;
    private long _presenceUnavailableSince = -1;
    private bool _presenceHasState;
    private int _presenceGeneration;

    private bool CompactActive => _compact && _appWindow?.IsVisible == true
        && _presenter?.State != Microsoft.UI.Windowing.OverlappedPresenterState.Minimized
        && !_closing && !_disposed && !_playerSuspended;

    private bool PresenceReadActive => _discord?.NeedsSnapshot == true
        && !_closing && !_disposed && !_playerSuspended;

    // Which consumer needs the shared playback reader (sets cadence and delivery; every demand runs
    // the same full read). Compact takes precedence and also feeds presence and the overlay: one read per tick.
    private enum ReaderDemand { None, Presence, Overlay, Resume, Compact }

    private ReaderDemand CurrentReaderDemand => CompactActive ? ReaderDemand.Compact
        : OverlayReadActive ? ReaderDemand.Overlay : ResumeReadActive ? ReaderDemand.Resume
        : PresenceReadActive ? ReaderDemand.Presence : ReaderDemand.None;

    private long ReadIntervalMs(ReaderDemand demand)
        => demand == ReaderDemand.Presence ? PresenceReadIntervalMs
            : demand == ReaderDemand.Resume && _rendererCapPolicy == RendererCapPolicy.FullIdle
                && _rendererCapHandle is not null && !ResumeInProgress && !_resumeSafetyMuted
                && !CompactActive && !OverlayReadActive ? FullIdleResumeReadMilliseconds : 1000;

    private static ReadReason ReasonFor(ReaderDemand demand) => demand switch
    {
        ReaderDemand.Compact => ReadReason.Compact,
        ReaderDemand.Overlay => ReadReason.Overlay,
        ReaderDemand.Resume => ReadReason.Resume,
        _ => ReadReason.Presence
    };

    // Starts/stops the shared reader: 1 s for Compact, overlay or active restore; 5 s for
    // presence or steady Continue while the Full idle renderer cap is applied.
    private void RefreshSharedReader()
    {
        if (_playbackReadTimer is null) return;
        var demand = CurrentReaderDemand;
        if (!PresenceReadActive && (_presenceHasState || _presenceUnavailableSince >= 0))
        {
            _presenceUnavailableSince = -1;
            _presenceHasState = false;
        }
        if (!PresenceReadActive) SetPresenceUnsupportedLocale(false);
        // Overlay demand ended during a read gap: the held sample must not greet a later stream.
        if (!OverlayReadActive && _overlayGapSince >= 0)
        {
            _overlayGapSince = -1;
            _overlayNoneSent = false;
            _obsOverlay?.MarkStale();
        }
        if (demand == ReaderDemand.None)
        {
            _playbackReadTimer.Stop();
            return;
        }
        var interval = TimeSpan.FromMilliseconds(ReadIntervalMs(demand));
        if (!_playbackReadTimer.IsRunning)
        {
            if (_playbackReadTimer.Interval != interval) _playbackReadTimer.Interval = interval;
            _playbackReadTimer.Start();
            if (demand is ReaderDemand.Presence or ReaderDemand.Overlay or ReaderDemand.Resume) _ = ReadPlaybackStateAsync();
        }
        else if (_playbackReadTimer.Interval != interval)
        {
            // Setting Interval on a running timer does not restart its period; restart it and let
            // the read's own eligibility gate decide whether a read starts now or on the next tick.
            _playbackReadTimer.Stop();
            _playbackReadTimer.Interval = interval;
            _playbackReadTimer.Start();
            _ = ReadPlaybackStateAsync();
        }
    }

    private void InitializeCompactSurface()
    {
        _playbackReadTimer = _dispatcherQueue.CreateTimer();
        _playbackReadTimer.Interval = TimeSpan.FromSeconds(1);
        _playbackReadTimer.IsRepeating = true;
        _playbackReadTimer.Tick += async (_, _) =>
        {
            UpdateCompactTimer();
            await ReadPlaybackStateAsync();
        };

        CompactView.CommandRequested += (command, value) => _ = ExecuteCompactCommandAsync(command, value);
        CompactView.ReturnToFullRequested += () => SetCompact(false);
        CompactView.UpdateRequested += OnUpdateButtonClick;
        CompactView.SettingsRequested += () => ShowSettings();
        CompactView.EqualizerSettingsRequested += OpenEqualizerSettings;
        CompactView.WhatsNewRequested += () =>
        {
            if (_pendingWhatsNewVersion is { } version)
                _ = ShowWhatsNewAsync(version, _pendingWhatsNewFromVersion);
        };
        CompactView.TimerRequested += SetPauseTimer;
        CompactView.CancelTimerRequested += CancelPauseTimer;
        CompactView.StatusRequested += ShowStatusDetails;
        CompactView.MinimizeRequested += () => _presenter?.Minimize();
        CompactView.CloseRequested += CloseOrHideToTray;
        CompactView.ToggleTopmostRequested += () => SetTopmost(!(_presenter?.IsAlwaysOnTop == true));
        CompactView.DonateRequested += () => _ = OpenDonationPageAsync();
        CompactView.PlaylistsRequested += () => _ = ShowCompactPlaylistsAsync();
        CompactView.PlaylistChosen += (index, title) => _ = PlayCompactPlaylistAsync(index, title);
        CompactView.SetPreferences(_settings.ReduceMotion, _presenter?.IsAlwaysOnTop == true);
    }

    private async Task ProbeForCompactTransportAsync()
    {
        if (!_initializeBrowser || !_compactWhenReady || _compactReadinessProbePending) return;
        _compactReadinessProbePending = true;
        var cancellation = _lifetime.Token;
        try
        {
            for (var attempt = 0; attempt < CompactReadinessProbeLimit; attempt++)
            {
                if (!_compactWhenReady || _closing || _disposed) return;
                var controls = _playerControls;
                if (controls?.IsAvailable == true
                    && await controls.AreCompactTransportControlsReadyAsync())
                {
                    if (_compactWhenReady && !_closing && !_disposed
                        && ReferenceEquals(controls, _playerControls) && !_compact)
                    {
                        if (_statusDetailsText.StartsWith(CompactReadinessCheckingStatus,
                                StringComparison.Ordinal))
                            SetStatus(string.Empty);
                        _compactWhenReady = false;
                        ToggleCompactCore();
                    }
                    return;
                }

                if (attempt + 1 < CompactReadinessProbeLimit && _compactWhenReady)
                    await Task.Delay(TimeSpan.FromSeconds(1), cancellation);
            }

            EnterCompactWithUnavailableControls();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested || _closing || _disposed)
        {
        }
        catch (Exception)
        {
            EnterCompactWithUnavailableControls();
        }
        finally
        {
            _compactReadinessProbePending = false;
        }
    }

    private void EnterCompactWithUnavailableControls()
    {
        if (!_compactWhenReady || _closing || _disposed || _compact) return;
        _compactWhenReady = false;
        SetStatus(CompactReadinessFallbackStatus, isError: true);
        ToggleCompactCore();
    }


    private void ApplyCompactSurface()
    {
        if (_compact) CloseOutputVolumeFlyout();
        CompactView.Visibility = _compact ? Visibility.Visible : Visibility.Collapsed;
        ToolbarHost.Visibility = _compact ? Visibility.Collapsed : Visibility.Visible;
        ToolbarRow.Height = _compact ? new GridLength(0) : GridLength.Auto;
        UpdateInfoBar.Visibility = _compact || _fullscreen ? Visibility.Collapsed : Visibility.Visible;
        UpdateInfoRow.Height = _compact || _fullscreen ? new GridLength(0) : GridLength.Auto;
        WebViewSlot.Visibility = _compact ? Visibility.Collapsed : Visibility.Visible;
        UpdateBrowserVisibility();
        CompactView.SetPreferences(_settings.ReduceMotion, _presenter?.IsAlwaysOnTop == true);
        CompactView.SetStatus(_statusDetailsText, _statusIsError);
        UpdateCompactTimer();
        RefreshCompactActivity();
    }

    private void RefreshCompactActivity()
    {
        var active = CompactActive;
        if (_compactActivity == active)
        {
            RefreshSharedReader();
            return;
        }
        _compactActivity = active;
        _playbackReadTimer?.Stop();
        InvalidateCompactState();
        CompactView.SetActive(active);
        RefreshSharedReader();
        if (active) _ = ReadPlaybackStateAsync();
    }

    private void InvalidateCompactState()
    {
        _compactGeneration++;
        _compactState = null;
        _compactUnavailableSince = -1;
        _compactArtworkUrl = null;
        _compactArtworkCancellation?.Cancel();
        _compactArtworkCancellation?.Dispose();
        _compactArtworkCancellation = null;
        if (!_disposed)
        {
            CompactView.SetPlayback(null);
            CompactView.SetArtwork(null);
        }
    }

    private void HoldOrDropCompactState()
    {
        if (_compactState is null) return;
        var now = Environment.TickCount64;
        if (_compactUnavailableSince < 0) _compactUnavailableSince = now;
        else if (now - _compactUnavailableSince >= CompactHoldMs) InvalidateCompactState();
    }

    private void HoldOrDropPresenceState()
    {
        if (!_presenceHasState) return;
        var now = Environment.TickCount64;
        if (_presenceUnavailableSince < 0) _presenceUnavailableSince = now;
        // A read gap (no coherent player for the hold window) clears the card but keeps the song's pause deadline,
        // so intermittent read failures cannot restart an expired pause. Navigation and crashes still forget fully.
        else if (now - _presenceUnavailableSince >= CompactHoldMs) InvalidateDiscord(keepItem: true);
    }

    // One shared full read per tick. The captured demand decides whether the result also
    // reaches Compact UI; presence and the overlay take it when their own gates still hold.
    private async Task ReadPlaybackStateAsync()
    {
        if (_resumeShutdownStarted) return;
        var demand = CurrentReaderDemand;
        if (demand == ReaderDemand.None) return;
        await PollResumeAsync();
        var compact = demand == ReaderDemand.Compact;
        // A user command owns the page; the next tick reads its result.
        if (_playbackReadPending || _playerBusy
            || Environment.TickCount64 - _lastCompactReadAt < ReadIntervalMs(demand)) return;
        var controls = _playerControls;
        if (controls?.IsAvailable != true)
        {
            if (compact) HoldOrDropCompactState();
            if (PresenceReadActive) HoldOrDropPresenceState();
            if (OverlayReadActive) HoldOrDropOverlayState();
            return;
        }
        _playbackReadPending = true;
        _lastCompactReadAt = Environment.TickCount64;
        var generation = _compactGeneration;
        var presenceGeneration = _presenceGeneration;
        var presenceEpoch = _discord?.ConnectionEpoch ?? 0;
        var overlayGeneration = _overlayGeneration;
        var resumeGeneration = _resumeGeneration;
        try
        {
            CompactPlaybackState? state;
            bool? unsupportedLocale;
            try
            {
                var read = await controls.ReadPlaybackStateAsync(ReasonFor(demand));
                state = read.State;
                unsupportedLocale = read.Sampled ? read.UnsupportedLocale : null;
            }
            catch (Exception)
            {
                state = null;
                unsupportedLocale = null;
            }
            var capturedAt = Environment.TickCount64;
            ObserveResumeSnapshot(state, resumeGeneration, capturedAt);
#if NATIVUNE_DISCORD_TEST_HOOKS
            if (_obsReadHold is { } hold) await hold.Task;   // command-obs-hold-read barrier; _playbackReadPending stays true
#endif
            try
            {
                DeliverPlaybackSnapshot(state, demand, generation, presenceGeneration, presenceEpoch,
                    overlayGeneration, capturedAt, unsupportedLocale);
            }
            catch (Exception)
            {
                if (state is not null)
                {
                    try
                    {
                        DeliverPlaybackSnapshot(null, demand, generation, presenceGeneration, presenceEpoch,
                            overlayGeneration, capturedAt);
                    }
                    catch (Exception)
                    {
                    }
                }
            }
        }
        finally
        {
            _playbackReadPending = false;
        }
    }

    // Each consumer accepts the result only if its own generation is still current. Reads made
    // without Compact demand never reach Compact UI. Presence also rejects a read that started on an
    // earlier Discord connection (checked atomically inside Observe). Gates are checked now, at delivery.
    // unsupportedLocale is null when no read ran, so the Discord note keeps what it last showed.
    private void DeliverPlaybackSnapshot(CompactPlaybackState? state, ReaderDemand demand,
        int generation, int presenceGeneration, int presenceEpoch, int overlayGeneration, long capturedAt,
        bool? unsupportedLocale = null)
    {
        if (PresenceReadActive && presenceGeneration == _presenceGeneration
            && presenceEpoch == _discord?.ConnectionEpoch)
        {
            if (unsupportedLocale is { } locale) SetPresenceUnsupportedLocale(locale);
            ApplyPresenceSnapshot(state, presenceEpoch);
        }
        if (demand == ReaderDemand.Compact && CompactActive && generation == _compactGeneration)
            ApplyCompactSnapshot(state);
        if (OverlayReadActive && overlayGeneration == _overlayGeneration)
            ApplyOverlaySnapshot(state, capturedAt);
    }

    // Null means no coherent player (or a failed read): hold briefly, then drop.
    private void ApplyPresenceSnapshot(CompactPlaybackState? state, int epoch)
    {
        if (state is null)
        {
            HoldOrDropPresenceState();
            return;
        }
        _presenceUnavailableSince = -1;
        _presenceHasState = true;
        ObserveDiscord(state, epoch);
    }

    private void ApplyCompactSnapshot(CompactPlaybackState? state)
    {
        if (state is null)
        {
            HoldOrDropCompactState();
            return;
        }
        _compactUnavailableSince = -1;
        _compactState = state;
        _compactStartupPending = false;
        _compactResumeAfterAccount = false;
        CompactView.SetPlayback(state);
        UpdateCompactArtwork(state.ArtworkUrl);
        if (_statusDetailsText.StartsWith("[!] Error: " + CompactReadinessFallbackStatus,
                StringComparison.Ordinal))
            SetStatus(string.Empty);
    }


    private void UpdateCompactArtwork(string? url)
    {
        if (string.Equals(url, _compactArtworkUrl, StringComparison.Ordinal)) return;
        _compactArtworkUrl = url;
        _compactArtworkCancellation?.Cancel();
        _compactArtworkCancellation?.Dispose();
        _compactArtworkCancellation = null;
        CompactView.SetArtwork(null);
        if (url is null) return;
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        _compactArtworkCancellation = cancellation;
        _ = LoadCompactArtworkAsync(url, _compactGeneration, cancellation.Token);
    }

    private async Task LoadCompactArtworkAsync(string url, int generation, CancellationToken cancellation)
    {
        try
        {
            var artwork = await CompactArtwork.LoadAsync(url, cancellation);
            if (!cancellation.IsCancellationRequested && CompactActive && generation == _compactGeneration
                && string.Equals(url, _compactArtworkUrl, StringComparison.Ordinal))
                CompactView.SetArtwork(artwork);
        }
        catch (Exception)
        {
            // Leave the neutral disc; never log URLs or retry automatically.
        }
    }

    private async Task ExecuteCompactCommandAsync(string command, double? value)
    {
        // App output volume is host-owned audio, not page state; a drag rollback arrives while Compact is deactivating
        // or after output became unavailable, so it restores the stored preference and applies only through the gate.
        if (command == "output-volume")
        {
            if (value is { } volume && double.IsFinite(volume) && volume >= 0 && volume <= 1)
                SetOutputVolume(volume);
            return;
        }
        if (command == "output-volume-live")
        {
            if (value is { } volume && double.IsFinite(volume) && volume >= 0 && volume <= 1)
                PreviewOutputVolume(volume);
            return;
        }
        if (command == "output-volume-restore")
        {
            if (value is { } volume && double.IsFinite(volume) && volume >= 0 && volume <= 1)
                RestoreOutputVolumePreference(volume);
            return;
        }
        if (command == "seek" && !await CancelResumeAsync("seek")) return;
        if (!CompactActive) return;
        if (command == "output-mute")
        {
            ToggleOutputMute();
            return;
        }
        if (command is "toggle" or "previous" or "next")
        {
            await ExecutePlayerCommandAsync(command);
            return;
        }
        // One website command at a time. A click arriving meanwhile is dropped, never queued,
        // so repeated clicks cannot land on whatever the website shows next.
        if (_playerBusy)
        {
            CompactView.CommandFinished(command, PlayerCommandOutcome.NotSent);
            return;
        }
        var shown = _compactState;
        var controls = _playerControls;
        if (shown is null || controls?.IsAvailable != true)
        {
            SetStatus("Playback controls unavailable; no action was sent.", isError: true);
            CompactView.CommandFinished(command, PlayerCommandOutcome.NotSent);
            return;
        }
        _playerBusy = true;
        var result = new PlayerCommandResult(PlayerCommandOutcome.Unknown, "Player action outcome unknown; no retry.");
        try
        {
            // Ratings and seek are bound to the item the user saw, not to whatever plays by dispatch time.
            var item = command is "like" or "dislike" or "seek" ? CompactPlayback.ComputeSignature(shown) : null;
            result = await controls.ExecuteCompactAsync(command, value, item);
        }
        catch (OperationCanceledException) when (_closing || _disposed || _lifetime.IsCancellationRequested) { return; }
        catch (Exception) { }
        finally { _playerBusy = false; UpdateFullIdlePolling(); }
        if (_closing || _disposed) return;
        if (command == "seek" && result.Outcome == PlayerCommandOutcome.Sent && value is { } target)
        {
            _resumeCompletedSeekSignature = CompactPlayback.ComputeSignature(shown);
            _resumeCompletedSeekTarget = target;
            _resumeCompletedSeekAt = Environment.TickCount64;
        }
        _lastCompactReadAt = 0;
        CompactView.CommandFinished(command, result.Outcome);
        ReportPlayerResult(result);
    }

    // Reads the playlists the website lists in its own sidebar and opens the Compact menu.
    private async Task ShowCompactPlaylistsAsync()
    {
        if (!CompactActive || _playerBusy) return;
        var controls = _playerControls;
        if (controls?.IsAvailable != true)
        {
            SetStatus("Playback controls unavailable; playlists can't be read.", isError: true);
            return;
        }
        _playerBusy = true;
        IReadOnlyList<CompactPlayback.PlaylistEntry>? playlists = null;
        try { playlists = await controls.ReadPlaylistsAsync(); }
        catch (Exception) { }
        finally { _playerBusy = false; UpdateFullIdlePolling(); }
        if (CompactActive) CompactView.ShowPlaylists(playlists);
    }

    // Presses the chosen sidebar playlist's own Play button once. Status text never names the
    // playlist, so library contents stay out of the error log; the view's notice shows the name.
    private async Task PlayCompactPlaylistAsync(int index, string title)
    {
        if (!await CancelResumeAsync("navigation")) return;
        if (!CompactActive) return;
        var controls = _playerControls;
        if (_playerBusy || controls?.IsAvailable != true)
        {
            if (!_playerBusy) SetStatus("Playback controls unavailable; no action was sent.", isError: true);
            CompactView.CommandFinished("play-playlist", PlayerCommandOutcome.NotSent);
            return;
        }
        _playerBusy = true;
        var result = new PlayerCommandResult(PlayerCommandOutcome.Unknown, "Player action outcome unknown; no retry.");
        try { result = await controls.ExecuteCompactAsync("play-playlist", index, title); }
        catch (OperationCanceledException) when (_closing || _disposed || _lifetime.IsCancellationRequested) { return; }
        catch (Exception) { }
        finally { _playerBusy = false; UpdateFullIdlePolling(); }
        if (_closing || _disposed) return;
        result = result.Outcome switch
        {
            PlayerCommandOutcome.Sent => result with { Message = "Playlist play sent." },
            PlayerCommandOutcome.Changed => result with { Message = "Your playlists changed; nothing was played. Open Playlists again." },
            _ => result
        };
        _lastCompactReadAt = 0;
        CompactView.CommandFinished("play-playlist", result.Outcome);
        ReportPlayerResult(result);
    }

    private void ReportPlayerResult(PlayerCommandResult result)
        => SetStatus(result.Message, isError: result.Outcome is PlayerCommandOutcome.NotSent or PlayerCommandOutcome.Unknown);

    private void UpdateCompactTimer()
    {
        if (!_disposed) CompactView.SetTimer(_sleep?.TimeRemaining);
    }

    private void DisposeCompactSurface()
    {
        _playbackReadTimer?.Stop();
        _compactArtworkCancellation?.Cancel();
        _compactArtworkCancellation?.Dispose();
        _compactArtworkCancellation = null;
        InvalidateCompactState();
        CompactView.SetActive(false);
        CompactView.Dispose();
    }
}
