using Microsoft.UI.Windowing;
using System.Runtime.InteropServices;
using UiDispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;

namespace Nativune;

public sealed partial class WebHostWindow
{
    private UiDispatcherQueueTimer? _hiddenRenderTimer, _hiddenRenderEndTimer;
    private NativeBrowserHost? _hiddenRenderPulseHost;
    private bool _hiddenRenderDirty;
    private long _hiddenRenderRevision, _hiddenRenderPulseRevision;
#if NATIVUNE_PERF_BENCH_HOOKS
    private int _hiddenRenderPulseMilliseconds;
    private static bool HiddenRenderMaintenanceDisabled
        => Environment.GetEnvironmentVariable("NATIVUNE_BENCH_NO_HIDDEN_RENDER") == "1";
#endif

    private bool HiddenRenderAllowed
    {
        get
        {
            if (_closing || _disposed || _resumeShutdownStarted || _browserFailed || _navigationFailed
                || _configuringPrivacy || _awaitingFirstPage || _playerSuspended || _browserHost is null
                || BrowserShouldBeVisible
                || !(_compact || IsInTray || _presenter?.State == OverlappedPresenterState.Minimized))
                return false;
            try { return PlayerControls.IsMusicUri(_browserHost.Core.Source); }
            catch (Exception ex) when (ex is COMException or InvalidOperationException) { return false; }
        }
    }

    private bool HiddenRenderReady
        => HiddenRenderAllowed && _fullIdleDocumentLoaded && !_fullIdleNavigationInProgress;

    private bool HiddenPagePlayingAudio
    {
        get
        {
            try { return _browserHost?.Core.IsDocumentPlayingAudio == true; }
            catch (Exception ex) when (ex is COMException or InvalidOperationException) { return false; }
        }
    }

    private void MarkHiddenRenderDirty()
    {
        if (HiddenRenderAllowed)
        {
            _hiddenRenderDirty = true;
            _hiddenRenderRevision++;
        }
        UpdateHiddenRenderMaintenance();
    }

    private void UpdateHiddenRenderMaintenance()
    {
        if (!HiddenRenderAllowed)
        {
            StopHiddenRenderMaintenance();
            return;
        }
        if (!HiddenRenderReady)
        {
            EndHiddenRenderPulse(completed: false);
            return;
        }
#if NATIVUNE_PERF_BENCH_HOOKS
        if (HiddenRenderMaintenanceDisabled)
        {
            _hiddenRenderTimer?.Stop();
            return; // Explicit bench pulse actions still use the production start/end path.
        }
#endif
        if (_hiddenRenderTimer is null)
        {
            _hiddenRenderTimer = _dispatcherQueue.CreateTimer();
            // Hidden WebView2 pages retain discarded YouTube Music queue DOM until they render;
            // a 1 s controller-only render releases it without showing the container HWND.
            // Route changes alone miss song changes made off the player page (Home, Library, a playlist),
            // where the URL stays put while the queue advances, so audible playback also counts as dirty.
            _hiddenRenderTimer.Interval = TimeSpan.FromSeconds(120);
            _hiddenRenderTimer.IsRepeating = true;
            _hiddenRenderTimer.Tick += (_, _) =>
            {
                if (_hiddenRenderDirty || HiddenPagePlayingAudio) StartHiddenRenderPulse();
            };
        }
        if (!_hiddenRenderTimer.IsRunning) _hiddenRenderTimer.Start();
    }

    private bool StartHiddenRenderPulse(int milliseconds = 1000)
    {
        if (milliseconds <= 0 || !HiddenRenderReady || _hiddenRenderPulseHost is not null)
            return false;
        var host = _browserHost!;
        var endTimer = _dispatcherQueue.CreateTimer();
        _hiddenRenderEndTimer = endTimer;
        endTimer.IsRepeating = false;
        endTimer.Tick += (_, _) =>
        {
            if (ReferenceEquals(_hiddenRenderEndTimer, endTimer))
                EndHiddenRenderPulse(completed: true);
        };
        _hiddenRenderPulseHost = host;
        _hiddenRenderPulseRevision = _hiddenRenderRevision;
        try
        {
            host.SetVisible(false); // Keep the HWND hidden; retain the last nonzero controller bounds.
            host.PulseControllerVisible(true);
            endTimer.Interval = TimeSpan.FromMilliseconds(milliseconds);
            endTimer.Start();
#if NATIVUNE_PERF_BENCH_HOOKS
            _hiddenRenderPulseMilliseconds = milliseconds;
            BenchHooks.Event("pulse-start", ("duration_ms", milliseconds));
#endif
            return true;
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException)
        {
            EndHiddenRenderPulse(completed: false);
            return false;
        }
    }

    private void EndHiddenRenderPulse(bool completed)
    {
        _hiddenRenderEndTimer?.Stop();
        _hiddenRenderEndTimer = null;
        var host = _hiddenRenderPulseHost;
        if (host is null) return;
        _hiddenRenderPulseHost = null;
        // A route change during the render remains dirty for the next cadence.
        if (completed && _hiddenRenderRevision == _hiddenRenderPulseRevision)
            _hiddenRenderDirty = false;
        try { host.PulseControllerVisible(false); }
        catch (Exception ex) when (ex is COMException or InvalidOperationException) { }
        try { UpdateBrowserVisibility(); } // Restore today's logical state, not the pulse's starting state.
        catch (Exception ex) when (ex is COMException or InvalidOperationException) { }
#if NATIVUNE_PERF_BENCH_HOOKS
        if (_hiddenRenderPulseMilliseconds > 0)
            BenchHooks.Event("pulse-end", ("duration_ms", _hiddenRenderPulseMilliseconds), ("completed", completed));
        _hiddenRenderPulseMilliseconds = 0;
#endif
    }

    private void StopHiddenRenderMaintenance()
    {
        _hiddenRenderDirty = false;
        EndHiddenRenderPulse(completed: false);
        _hiddenRenderTimer?.Stop();
    }
}
