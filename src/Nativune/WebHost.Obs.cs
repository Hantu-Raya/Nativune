using System.Diagnostics;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;

namespace Nativune;

// Opt-in OBS now-playing overlay: owns the loopback server and feeds it from the shared reader.
// Every member runs on the UI thread; the server's StreamsChanged is marshalled here.
public sealed partial class WebHostWindow
{
    private ObsOverlayServer? _obsOverlay;
    private ObsOverlayStartResult? _obsStartResult;   // last Start() outcome while the setting is on
    private int _overlayGeneration;                   // bumped by off/on and InvalidateOverlay
    private long _overlayGapSince = -1;               // TickCount64 of the first failed/unavailable read in a gap
    private long _overlayGapSinceQpc;                 // Stopwatch.GetTimestamp() of the same moment (bench state)
    private bool _overlayNoneSent;                    // 'none' already broadcast for the current gap
    private bool _obsApplyRunning;                    // the single apply loop is in flight
    private Task _obsApplyTask = Task.CompletedTask;  // that loop; callers await it instead of starting a second
    private readonly SemaphoreSlim _looksSaveLock = new(1, 1);
    private readonly CancellationTokenSource _looksShutdownCts = new();
    private CancellationTokenSource? _activeLooksCommit;
    private ObsLookState _looks = ObsLookState.Empty;
    private bool _looksLoaded;
    private long _looksRevision;
    private ObsLook? _draftLook;
    private string _draftBackdrop = "checker";
    private string? _previewNonce;

    private bool OverlayReadActive => _obsOverlay is { IsRunning: true, RealStreams: > 0 }
        && !_closing && !_disposed && !_playerSuspended;

    private void InitializeObsOverlay()
    {
        EnsureObsLooksLoaded();
        if (_settings.ObsOverlay) _ = ReconcileObsOverlayAsync();
    }

    private void EnsureObsLooksLoaded()
    {
        if (_looksLoaded) return;
        _looks = ObsLookStore.Load(_root);
        _looksLoaded = true;
    }

    private async Task ReloadObsLooksAsync()
    {
        await _looksSaveLock.WaitAsync();
        try
        {
            _looks = ObsLookStore.Load(_root);
            _looksLoaded = true;
            _looksRevision++;
            _obsOverlay?.SetLooks(_looks);
        }
        finally
        {
            _looksSaveLock.Release();
        }
    }

    // The toolbar button and More item: same shape as SetDiscordEnabled. The setting is persisted at once and the
    // server follows through the serialized apply loop.
    private void SetObsOverlayEnabled(bool enabled)
    {
        if (_closing || _disposed) return;
        if (_settings.ObsOverlay != enabled)
        {
            _settings = _settings with { ObsOverlay = enabled };
            CaptureSettings();
            _ = ReconcileObsOverlayAsync();
        }
        RefreshObsSurfaces();
    }

    // Every start/stop goes through here (toolbar, More, Settings save, startup). One loop runs at a time and
    // re-reads _settings.ObsOverlay after each apply, so rapid toggles or a Settings save racing a click can never
    // leave two servers or a server that disagrees with the setting. A caller that arrives mid-loop has already
    // changed _settings on this thread, so the loop's next re-read sees it; awaiting the returned task waits for that.
    private Task ReconcileObsOverlayAsync()
    {
        if (_obsApplyRunning) return _obsApplyTask;
        _obsApplyRunning = true;
        _obsApplyTask = RunObsApplyLoopAsync();
        return _obsApplyTask;
    }

    private async Task RunObsApplyLoopAsync()
    {
        try
        {
            bool applied;
            do
            {
                applied = _settings.ObsOverlay;
                await ApplyObsOverlayAsync(applied);
            }
            while (applied != _settings.ObsOverlay && !_closing && !_disposed);
        }
        catch (Exception)
        {
            // A failed stop/start must not surface as an unobserved task fault; the surfaces show the failure.
            if (_settings.ObsOverlay) _obsStartResult = ObsOverlayStartResult.Failed;
        }
        finally
        {
            _obsApplyRunning = false;
            RefreshObsSurfaces();
        }
    }

    private async Task ApplyObsOverlayAsync(bool enabled)
    {
        if (enabled)
        {
            if (_closing || _disposed || _obsOverlay is { IsRunning: true }) return;
            await StopObsOverlayAsync();
            if (_closing || _disposed) return;
            await _looksSaveLock.WaitAsync();
            ObsLookState looks;
            try
            {
                EnsureObsLooksLoaded();
                looks = _looks;
            }
            finally
            {
                _looksSaveLock.Release();
            }
            var server = new ObsOverlayServer(new ObsOverlayOptions(_settings.ObsHidePaused, _settings.ReduceMotion, looks));
            server.StreamsChanged += OnOverlayStreamsChanged;
            _obsStartResult = server.Start();
            if (_obsStartResult == ObsOverlayStartResult.Started)
                _obsOverlay = server;
            else
            {
                // The setting stays on; turning it off and on retries with a fresh listener.
                server.StreamsChanged -= OnOverlayStreamsChanged;
                try { await server.StopAsync(); } catch (Exception) { }
            }
        }
        else
        {
            _obsStartResult = null;
            await StopObsOverlayAsync();
            _overlayGeneration++;
            _overlayGapSince = -1;
            _overlayNoneSent = false;
        }
        RefreshSharedReader();
        RefreshObsStatus();
    }

    private void ApplyObsHidePaused(bool hidePaused) => _obsOverlay?.SetHidePaused(hidePaused);

    private void ApplyObsReduceMotion(bool reduceMotion) => _obsOverlay?.SetReduceMotion(reduceMotion);

    private void ApplyObsDraft(ObsLook? look, string backdrop, string? nonce)
    {
        _draftLook = look;
        _draftBackdrop = ObsLookValidation.NormalizeBackdrop(backdrop);
        _previewNonce = nonce;
        _obsOverlay?.SetDraftLook(look, _draftBackdrop, nonce);
    }

    private readonly record struct ObsLookCommitOutcome(bool Ok, string? Reason, string[] Ids, long Revision);

    private async Task<ObsLookCommitOutcome> CommitLooksAsync(
        Func<ObsLookState, (ObsLookState? State, string[] Ids, string? Error)> prepare)
    {
        await _looksSaveLock.WaitAsync();
        try
        {
            EnsureObsLooksLoaded();
            if (_looks.IsReadOnly)
                return new(false, _looks.ReadOnlyReason ?? "The looks file is read-only", [], _looksRevision);

            var mutation = prepare(_looks);
            if (mutation.Error is not null)
                return new(false, mutation.Error, mutation.Ids, _looksRevision);
            if (mutation.State is null)
                return new(false, "No look changes were produced", mutation.Ids, _looksRevision);

            using var commit = CancellationTokenSource.CreateLinkedTokenSource(_looksShutdownCts.Token);
            _activeLooksCommit = commit;
            var saved = await ObsLookStore.SaveAsync(_root, mutation.State, commit.Token);
            if (!saved.Committed)
                return new(false, saved.Reason, mutation.Ids, _looksRevision);

            _looks = mutation.State;
            _looksRevision++;
            _obsOverlay?.SetLooks(_looks);
            return new(true, null, mutation.Ids, _looksRevision);
        }
        catch (OperationCanceledException)
        {
            return new(false, "The looks save was cancelled", [], _looksRevision);
        }
        catch (Exception ex)
        {
            return new(false, $"Could not save: {ex.GetType().Name}", [], _looksRevision);
        }
        finally
        {
            _activeLooksCommit = null;
            _looksSaveLock.Release();
        }
    }
    private async Task StopObsLookCommitsAsync()
    {
        var acquired = false;
        try
        {
            await _looksSaveLock.WaitAsync().WaitAsync(TimeSpan.FromSeconds(2));
            acquired = true;
        }
        catch (TimeoutException)
        {
            try { _activeLooksCommit?.Cancel(); } catch (ObjectDisposedException) { }
        }
        finally
        {
            if (acquired) _looksSaveLock.Release();
            _looksShutdownCts.Cancel();
        }
    }

    // Hard invalidation (navigation, browser failure, power suspend): 'none' now, latest stale.
    private void InvalidateOverlay()
    {
        _overlayGeneration++;
        _overlayGapSince = -1;
        _overlayNoneSent = false;
        _obsOverlay?.PublishNone();
    }

    private void ApplyOverlaySnapshot(CompactPlaybackState? state, long capturedAt)
    {
        if (state is null)
        {
            HoldOrDropOverlayState();
            return;
        }
        _overlayGapSince = -1;
        _overlayNoneSent = false;
        _obsOverlay?.Publish(ObsOverlaySnapshot.FromState(state, capturedAt));
    }

    // Read gap: keep the anchor until CompactHoldMs after the first failure, then send 'none' once.
    private void HoldOrDropOverlayState()
    {
        var now = Environment.TickCount64;
        if (_overlayGapSince < 0)
        {
            _overlayGapSince = now;
            _overlayGapSinceQpc = Stopwatch.GetTimestamp();
            return;
        }
        if (!_overlayNoneSent && now - _overlayGapSince >= CompactHoldMs)
        {
            _overlayNoneSent = true;
            _obsOverlay?.PublishNone();
        }
    }

    // Raised on a server thread; the count is re-read on the UI thread.
    private void OnOverlayStreamsChanged(ObsOverlayStreamCounts streams)
    {
        _dispatcherQueue.TryEnqueue(() =>
        {
            if (_closing || _disposed) return;
            RefreshSharedReader();
            RefreshObsStatus();
        });
    }

    private ObsOverlayStatus CurrentObsStatus
    {
        get
        {
            if (!_settings.ObsOverlay) return ObsOverlayStatus.Off;
            if (_obsOverlay is { IsRunning: true } server)
                return server.StatusSourceCount > 0 ? ObsOverlayStatus.Connected : ObsOverlayStatus.Waiting;
            return _obsStartResult switch
            {
                ObsOverlayStartResult.PrefixInUse => ObsOverlayStatus.PrefixInUse,
                ObsOverlayStartResult.AccessDenied => ObsOverlayStatus.AccessDenied,
                ObsOverlayStartResult.Failed => ObsOverlayStatus.Failed,
                _ => ObsOverlayStatus.Off
            };
        }
    }

    private void RefreshObsStatus()
    {
        if (_closing || _disposed) return;
        _settingsDialog?.SetObsStatus(CurrentObsStatus, _obsOverlay?.StatusSourceCount ?? 0);
        RefreshObsSurfaces();
    }

    // Toolbar button, its recording dot and the More toggle all follow the persisted setting plus the live server state.
    private void RefreshObsSurfaces()
    {
        if (_closing || _disposed) return;
        var enabled = _settings.ObsOverlay;
        var streams = _obsOverlay?.StatusSourceCount ?? 0;
        var state = !enabled
            ? "off"
            : CurrentObsStatus switch
            {
                ObsOverlayStatus.Connected => $"on, connected to {streams} {(streams == 1 ? "source" : "sources")}",
                ObsOverlayStatus.PrefixInUse or ObsOverlayStatus.AccessDenied or ObsOverlayStatus.Failed
                    => "on, couldn't start",
                // Waiting, and the moment between the click and the listener being up.
                _ => "on, waiting for OBS"
            };
        var name = $"OBS overlay: {state}";
        var description = $"{name}. Right-click for OBS overlay settings.";
        AutomationProperties.SetName(ObsButton, name);
        AutomationProperties.SetHelpText(ObsButton, description);
        ToolTipService.SetToolTip(ObsButton, description);
        _obsOverlayItem.IsChecked = enabled;

        // The dot is the only cue that the overlay is on; the button's name carries the state for screen readers.
        var highContrast = ShellTheme.IsHighContrast;
        ObsRecordingDot.Fill = new SolidColorBrush(highContrast
            ? ShellTheme.HighlightColor
            : Windows.UI.Color.FromArgb(0xFF, 0xE8, 0x11, 0x23));
        ObsRecordingDot.StrokeThickness = highContrast ? 0 : 1;
        ObsRecordingDot.Visibility = enabled ? Visibility.Visible : Visibility.Collapsed;
    }

    // Replaces the mask icon (theme/DPI rebuilds) while keeping the recording dot that shares the 20 DIP host.
    private void SetObsButtonIcon()
    {
        for (var i = ObsIconHost.Children.Count - 1; i >= 0; i--)
            if (ObsIconHost.Children[i] is IconElement) ObsIconHost.Children.RemoveAt(i);
        ObsIconHost.Children.Insert(0, _iconCache.CreateElement("obs", 20));
    }

    private async Task OpenObsGuideAsync()
    {
        if (_closing || _disposed) return;
        var recorded = false;
        ObsRecordLaunchedUri(AppVersion.ObsGuideUri, ref recorded);
        if (recorded) return;
        if (!await AppVersion.TryOpenUriAsync(AppVersion.ObsGuideUri) && !_closing && !_disposed)
            _settingsDialog?.SetObsGuideResult(AppVersion.ObsGuideFailedMessage);
    }

    private async Task StopObsOverlayAsync()
    {
        var server = _obsOverlay;
        if (server is null) return;
        server.StreamsChanged -= OnOverlayStreamsChanged;
        _obsOverlay = null;
        await server.StopAsync();
    }

    partial void ObsRecordLaunchedUri(Uri uri, ref bool recorded);
}
