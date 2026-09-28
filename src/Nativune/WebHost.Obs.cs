using System.Diagnostics;

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

    private bool OverlayReadActive => _obsOverlay is { IsRunning: true, OpenStreams: > 0 }
        && !_closing && !_disposed && !_playerSuspended;

    private void InitializeObsOverlay()
    {
        if (_settings.ObsOverlay) _ = ApplyObsOverlayAsync(true);
    }

    private async Task ApplyObsOverlayAsync(bool enabled)
    {
        if (enabled)
        {
            if (_closing || _disposed || _obsOverlay is { IsRunning: true }) return;
            await StopObsOverlayAsync();
            if (_closing || _disposed) return;
            _overlayGeneration++;
            var server = new ObsOverlayServer(_settings.ObsHidePaused);
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
    private void OnOverlayStreamsChanged(int streams)
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
                return server.OpenStreams > 0 ? ObsOverlayStatus.Connected : ObsOverlayStatus.Waiting;
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
        _settingsDialog?.SetObsStatus(CurrentObsStatus, _obsOverlay?.OpenStreams ?? 0);
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
