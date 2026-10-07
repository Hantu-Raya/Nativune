using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32.SafeHandles;
using UiDispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;

namespace Nativune;

// One renderer, one original snapshot. This limits residency, not allocation; Full is capped only while idle.
public sealed partial class WebHostWindow
{
    private enum RendererCapPolicy { None, Tray, FullIdle }
    private const nint TrayRendererCapBytes = 60 << 20;
    private const uint QuotaMinDisable = 0x2, QuotaMaxEnable = 0x4;
    private SafeProcessHandle? _rendererCapHandle;
    private nint _rendererCapOriginalMin, _rendererCapOriginalMax;
    private uint _rendererCapOriginalFlags;
    private int _rendererCapGeneration, _rendererCapPid;
    private RendererCapPolicy _rendererCapPolicy;
#if NATIVUNE_PERF_BENCH_HOOKS
    private bool _fullIdlePollOnlyApplied;
    private static bool FullIdlePollOnly =>
        Environment.GetEnvironmentVariable("NATIVUNE_BENCH_FULLIDLE_POLL_ONLY") == "1";
    private object? _fullIdleReleaseClassification;
#endif
    private bool RendererCapActive
    {
        get
        {
#if NATIVUNE_PERF_BENCH_HOOKS
            return _rendererCapHandle is not null || _fullIdlePollOnlyApplied;
#else
            return _rendererCapHandle is not null;
#endif
        }
    }
    private UiDispatcherQueueTimer _trayCapTimer = null!;
    private bool _wasInTray;
    private int _trayCapRetries, _fullIdleRevalidationRetries;
    private bool _fullIdleRevalidationRequested;
    private UiDispatcherQueueTimer? _fullIdleTimer;
    private long _lastAppActivity = Stopwatch.GetTimestamp();
    private uint? _lastInputTick;
    private PointI? _lastInputCursor;
    // The applied cap is also an idle-eligible baseline: older startup/scheduled commands cannot own the next track.
    private bool _appInputSinceSource = true;
    // Carry automatic document navigation through its lifecycle without shortening user navigation.
    private bool _automaticDocumentChange;
    private double _fullIdleWaitSeconds = 60;
    private bool _fullIdleDocumentLoaded, _fullIdleNavigationInProgress, _rendererCapPending;
    private long _rendererCapRetryAfter;

    private bool IsInTray => _appWindow?.IsVisible == false;
    private static nint FullIdleCapBytes
    {
        get
        {
#if NATIVUNE_PERF_BENCH_HOOKS
            if (int.TryParse(Environment.GetEnvironmentVariable("NATIVUNE_BENCH_FULLIDLE_CAP_MIB"), out var mib)
                && mib is >= 0 and <= 1024) return (nint)mib << 20;
#endif
            return 60 << 20;
        }
    }
    private static double FullIdleSeconds
    {
        get
        {
#if NATIVUNE_PERF_BENCH_HOOKS
            if (double.TryParse(Environment.GetEnvironmentVariable("NATIVUNE_BENCH_FULLIDLE_SECONDS"),
                System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var seconds)
                && double.IsFinite(seconds) && seconds is >= 0 and <= 3600) return seconds;
#endif
            return 60;
        }
    }
    private static int FullIdleWatchdogMilliseconds
    {
        get
        {
#if NATIVUNE_PERF_BENCH_HOOKS
            if (int.TryParse(Environment.GetEnvironmentVariable("NATIVUNE_BENCH_FULLIDLE_WATCHDOG_MS"), out var milliseconds)
                && milliseconds is >= 10 and <= 1000) return milliseconds;
#endif
            return 50;
        }
    }
    private static int FullIdlePendingMilliseconds
    {
        get
        {
#if NATIVUNE_PERF_BENCH_HOOKS
            if (int.TryParse(Environment.GetEnvironmentVariable("NATIVUNE_BENCH_FULLIDLE_PENDING_MS"), out var milliseconds)
                && milliseconds is >= 50 and <= 10000) return milliseconds;
#endif
            return 1000;
        }
    }
    private static double FullIdleRearmSeconds
    {
        get
        {
#if NATIVUNE_PERF_BENCH_HOOKS
            if (int.TryParse(Environment.GetEnvironmentVariable("NATIVUNE_BENCH_FULLIDLE_REARM_SECONDS"), out var seconds)
                && seconds is >= 0 and <= 60) return seconds;
#endif
            return 10;
        }
    }

    private static int FullIdleResumeReadMilliseconds
    {
        get
        {
#if NATIVUNE_PERF_BENCH_HOOKS
            if (int.TryParse(Environment.GetEnvironmentVariable("NATIVUNE_BENCH_FULLIDLE_RESUME_READ_MS"), out var milliseconds)
                && (milliseconds == 0 || milliseconds is >= 1000 and <= 30000))
                return milliseconds == 0 ? 1000 : milliseconds;
#endif
            return 5000;
        }
    }

    private bool FullIdleCanWait => WindowIsVisible && !_compact
        && _fullIdleDocumentLoaded && !_fullIdleNavigationInProgress && !_navigationFailed && !_browserFailed
        && !_configuringPrivacy && !_awaitingFirstPage && !_playerBusy && !_settingsDialogOpen && !_timerDialogOpen
        && _ownedDialogs.Count == 0 && !_resumeShutdownStarted && !_closing && !_disposed;
    private bool FullIdleEligible => FullIdleCanWait && FullIdleCapBytes > 0
        && Stopwatch.GetElapsedTime(_lastAppActivity).TotalSeconds >= _fullIdleWaitSeconds;

    private void RegisterFullIdleButtons(Microsoft.UI.Xaml.DependencyObject root)
    {
        if (root is Microsoft.UI.Xaml.Controls.Primitives.ButtonBase button)
            button.Click += (_, _) => RecordAppActivity("shell-command");
        for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root); i++)
            RegisterFullIdleButtons(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, i));
    }

    private void InitializeFullIdlePolicy()
    {
        _fullIdleWaitSeconds = FullIdleSeconds;
#if NATIVUNE_PERF_BENCH_HOOKS
        BenchHooks.Event("fullidle-policy", ("idleSeconds", FullIdleSeconds),
            ("watchdogMs", FullIdleWatchdogMilliseconds), ("pendingMs", FullIdlePendingMilliseconds),
            ("rearmSeconds", FullIdleRearmSeconds), ("pollOnly", FullIdlePollOnly));
#endif
        _fullIdleTimer = _dispatcherQueue.CreateTimer();
        _fullIdleTimer.IsRepeating = true;
        _fullIdleTimer.Tick += (_, _) =>
        {
            if (!PollAppInput()) return;
            UpdateFullIdlePolling();
            if (FullIdleEligible && (!RendererCapActive || _fullIdleRevalidationRequested) && !_rendererCapPending
                && Stopwatch.GetTimestamp() >= _rendererCapRetryAfter)
                _ = CapOrRevalidateRendererAsync(RendererCapPolicy.FullIdle);
        };
        Activated += (_, args) =>
        {
            if (args.WindowActivationState != Microsoft.UI.Xaml.WindowActivationState.Deactivated)
                RecordAppActivity("activation");
        };
    }

    private void RecordAppActivity(string reason, bool appInput = true, double? idleWaitSeconds = null)
    {
        var detected = Stopwatch.GetTimestamp();
        _lastAppActivity = detected;
        _fullIdleWaitSeconds = idleWaitSeconds ?? FullIdleSeconds;
        if (appInput)
        {
            _appInputSinceSource = true;
            _automaticDocumentChange = false;
        }
        // Tray discovery is independent of activity; only invalidate pending Full-idle discovery.
        if (!IsInTray) _rendererCapGeneration++;
        if (_rendererCapPolicy == RendererCapPolicy.FullIdle) ReleaseRendererCap(reason, detected);
        UpdateFullIdlePolling();
    }

    private void RecordSourceChange(bool newDocument, string? source)
    {
        // Poll now, before attributing the change: the pending timer may not have seen the user's click yet.
        var cappedBeforePoll = _rendererCapPolicy == RendererCapPolicy.FullIdle;
        var inputAvailable = PollAppInput();
        var cappedAfterPoll = _rendererCapPolicy == RendererCapPolicy.FullIdle;
        var musicSource = PlayerControls.IsMusicUri(source);
        var automatic = inputAvailable && musicSource && !_appInputSinceSource
            && (_automaticDocumentChange || _fullIdleDocumentLoaded
                && (!newDocument || cappedBeforePoll && cappedAfterPoll));
#if NATIVUNE_PERF_BENCH_HOOKS
        _fullIdleReleaseClassification = new {
            newDocument, inputAvailable, musicSource, cappedBeforePoll, cappedAfterPoll,
            documentLoaded = _fullIdleDocumentLoaded, navigationInProgress = _fullIdleNavigationInProgress,
            inputSinceBaseline = _appInputSinceSource, automaticDocument = _automaticDocumentChange, automatic
        };
        BenchHooks.Event("fullidle-source-classification", ("classification", _fullIdleReleaseClassification));
#endif
        if (newDocument || !musicSource) _automaticDocumentChange = automatic;
        RecordAppActivity(automatic ? "track-change" : "source-changed", appInput: false,
            idleWaitSeconds: automatic ? FullIdleRearmSeconds : FullIdleSeconds);
        if (automatic) _appInputSinceSource = false;
#if NATIVUNE_PERF_BENCH_HOOKS
        _fullIdleReleaseClassification = null;
#endif
    }

    // Count foreground input, or pointer movement over the window; no global hooks or input content recording.
    // Wheel-only input over an unfocused window with a stationary pointer intentionally does not count.
    private bool PollAppInput()
    {
        var cursorAvailable = GetCursorPos(out var cursor);
        var cursorMoved = cursorAvailable && _lastInputCursor is { } lastCursor
            && (cursor.X != lastCursor.X || cursor.Y != lastCursor.Y);
        _lastInputCursor = cursorAvailable ? cursor : null;
        var input = new LastInputInfo { Size = (uint)Marshal.SizeOf<LastInputInfo>() };
        if (!GetLastInputInfo(ref input))
        {
            RecordAppActivity("input-query-failed");
            return false;
        }
        var changed = _lastInputTick is { } previous && previous != input.Tick;
        _lastInputTick = input.Tick;
        if (changed && (GetForegroundWindow() == NativeHandle
            || cursorMoved && GetAncestor(WindowFromPoint(cursor), 2) == NativeHandle))
            RecordAppActivity("app-input");
        return true;
    }

    private void UpdateFullIdlePolling()
    {
        if (_fullIdleTimer is null) return;
        if (!FullIdleCanWait || FullIdleCapBytes == 0)
        {
            _fullIdleTimer.Stop();
            _lastInputCursor = null;
            if (_rendererCapPolicy == RendererCapPolicy.FullIdle) ReleaseRendererCap("ineligible");
            return;
        }
        var interval = TimeSpan.FromMilliseconds(_rendererCapPolicy == RendererCapPolicy.FullIdle
            ? FullIdleWatchdogMilliseconds : FullIdlePendingMilliseconds);
        // Do not restart an already running timer on every geometry/state notification.
        if (_fullIdleTimer.IsRunning && _fullIdleTimer.Interval == interval) return;
        // Seed at restart, not the first tick, so movement during the first interval still counts.
        if (!_fullIdleTimer.IsRunning) _lastInputCursor = GetCursorPos(out var cursor) ? cursor : null;
        _fullIdleTimer.Stop();
        _fullIdleTimer.Interval = interval;
        _fullIdleTimer.Start();
    }

    private void ArmFullIdleRevalidation()
    {
        if (_rendererCapPolicy != RendererCapPolicy.FullIdle) return;
        _fullIdleRevalidationRetries = 0;
        _fullIdleRevalidationRequested = true;
        _rendererCapRetryAfter = 0;
    }

    private async Task CapOrRevalidateRendererAsync(RendererCapPolicy policy)
    {
        if (_rendererCapPending) return;
        if (RendererCapActive)
        {
            var generation = _rendererCapGeneration;
            var capped = _rendererCapPid;
            _rendererCapPending = true;
            if (policy == RendererCapPolicy.FullIdle) _fullIdleRevalidationRequested = false;
            try
            {
                var (current, _) = await FindMainRendererAsync();
                if (_closing || _disposed || _resumeShutdownStarted || !RendererCapActive
                    || _rendererCapPolicy != policy
                    || !(policy == RendererCapPolicy.Tray ? IsInTray && !_compact : PollAppInput() && FullIdleEligible)
                    || generation != _rendererCapGeneration) return;
                // An inconclusive lookup is not evidence of replacement; retain the original pinned snapshot.
                if (current == 0)
                {
                    if (policy == RendererCapPolicy.Tray) RetryTrayCap();
                    else if (_fullIdleRevalidationRetries++ < 3)
                    {
                        _fullIdleRevalidationRequested = true;
                        _rendererCapRetryAfter = Stopwatch.GetTimestamp() + 5 * Stopwatch.Frequency;
                    }
                    return;
                }
                if (current == capped) return;
                ReleaseRendererCap("renderer-changed");
                if (RendererCapActive) return; // Failed restore retains the original snapshot.
            }
            finally { _rendererCapPending = false; }
        }
        await CapRendererAsync(policy);
    }

    private async Task CapRendererAsync(RendererCapPolicy policy)
    {
        var generation = ++_rendererCapGeneration;
        bool Current() => !_closing && !_disposed && !_resumeShutdownStarted && !RendererCapActive
            && (policy == RendererCapPolicy.Tray ? IsInTray && !_compact : PollAppInput() && FullIdleEligible)
            && generation == _rendererCapGeneration;
        if (!Current()) return;
        _rendererCapPending = true;
        try
        {
            var (processId, outcome) = await FindMainRendererAsync();
            if (!Current()) return;
            if (processId == 0) { RendererCapLog(policy, outcome, 0); if (policy == RendererCapPolicy.Tray) RetryTrayCap(); return; }
#if NATIVUNE_PERF_BENCH_HOOKS
            if (policy == RendererCapPolicy.FullIdle && FullIdlePollOnly)
            {
                var (pollRecheckId, _) = await FindMainRendererAsync();
                if (!Current() || pollRecheckId != processId)
                {
                    if (Current()) RendererCapLog(policy, "renderer-changed", processId);
                    return;
                }
                _fullIdlePollOnlyApplied = true;
                _rendererCapPid = processId;
                _rendererCapPolicy = policy;
                _appInputSinceSource = false;
                (_rendererCapOriginalMin, _rendererCapOriginalMax, _rendererCapOriginalFlags) = (0, 0, 0);
                RendererCapLog(policy, "applied-poll-only", processId, reason: "idle");
                return;
            }
#endif
            const uint processSetQuota = 0x0100, processQueryLimitedInformation = 0x1000;
            var handle = OpenProcess(processSetQuota | processQueryLimitedInformation, false, processId);
            if (handle.IsInvalid) { handle.Dispose(); RendererCapLog(policy, "open-failed", processId); if (policy == RendererCapPolicy.Tray) RetryTrayCap(); return; }
            // The handle pins the PID; recheck that it still owns only our main frame.
            var (recheckId, _) = await FindMainRendererAsync();
            if (!Current() || recheckId != processId)
            {
                handle.Dispose();
                if (Current()) { RendererCapLog(policy, "renderer-changed", processId); if (policy == RendererCapPolicy.Tray) RetryTrayCap(); }
                return;
            }
            var cap = policy == RendererCapPolicy.Tray ? TrayRendererCapBytes : FullIdleCapBytes;
            // Raising the process's minimum fails from a standard token (ERROR_PRIVILEGE_NOT_HELD).
            if (!GetProcessWorkingSetSizeEx(handle.DangerousGetHandle(), out var min, out var max, out var flags)
                || min >= cap || !SetProcessWorkingSetSizeEx(handle.DangerousGetHandle(), min, cap, QuotaMinDisable | QuotaMaxEnable))
            {
                RendererCapLog(policy, $"apply-failed {new Win32Exception(Marshal.GetLastWin32Error()).Message}", processId);
                handle.Dispose();
                return;
            }
            _rendererCapHandle = handle;
            (_rendererCapOriginalMin, _rendererCapOriginalMax, _rendererCapOriginalFlags) = (min, max, flags);
            _rendererCapPid = processId;
            _rendererCapPolicy = policy;
            if (policy == RendererCapPolicy.FullIdle) _appInputSinceSource = false;
            RendererCapLog(policy, "applied", processId, min, cap, QuotaMinDisable | QuotaMaxEnable,
                reason: policy == RendererCapPolicy.FullIdle ? "idle" : "tray");
            if (policy == RendererCapPolicy.FullIdle) RefreshSharedReader();
        }
        finally
        {
            _rendererCapPending = false;
            if (!RendererCapActive) _rendererCapRetryAfter = Stopwatch.GetTimestamp() + 30 * Stopwatch.Frequency;
            UpdateFullIdlePolling();
        }

    }

    // Discovery can be inconclusive while a page or renderer is still settling; try again a few times.
    private void RetryTrayCap()
    {
        if (_trayCapRetries >= 3 || !IsInTray || _compact || _closing || _disposed || _resumeShutdownStarted) return;
        _trayCapRetries++;
        _trayCapTimer.Stop();
        _trayCapTimer.Start();
    }

    private void ArmTrayCap()
    {
        _trayCapRetries = 0;
        _trayCapTimer.Stop();
        _trayCapTimer.Start();
    }

    // Exactly one renderer must host this view's main frame and no other view's main frame; no fallback.
    private async Task<(int ProcessId, string Outcome)> FindMainRendererAsync()
    {
        var core = _browserHost?.Core;
        if (_environment is null || core is null) return (0, "no-view");
        try
        {
            var frameId = core.FrameId;
            if (frameId == 0) return (0, "no-frame-id");
            var infos = await _environment.GetProcessExtendedInfosAsync();
            int processId = 0, matches = 0;
            foreach (var info in infos)
            {
                if (info.ProcessInfo.Kind != CoreWebView2ProcessKind.Renderer) continue;
                bool ours = false, foreign = false;
                foreach (var frame in info.AssociatedFrameInfos)
                {
                    if (frame.FrameKind != CoreWebView2FrameKind.MainFrame) continue;
                    if (frame.FrameId == frameId) ours = true;
                    else foreign = true;
                }
                if (!ours) continue;
                matches++;
                processId = foreign ? 0 : info.ProcessInfo.ProcessId;
            }
            return matches == 1 && processId != 0 ? (processId, "found")
                : (0, matches == 0 ? "renderer-not-found" : "renderer-ambiguous");
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException) { return (0, "discovery-failed"); }
    }

    private void ReleaseRendererCap(string reason, long detected = 0)
    {
        _rendererCapGeneration++;
#if NATIVUNE_PERF_BENCH_HOOKS
        if (_fullIdlePollOnlyApplied)
        {
            if (detected == 0) detected = Stopwatch.GetTimestamp();
            _fullIdlePollOnlyApplied = false;
            _rendererCapPolicy = RendererCapPolicy.None;
            _fullIdleRevalidationRequested = false;
            _fullIdleRevalidationRetries = 0;
            RendererCapLog(RendererCapPolicy.FullIdle, "released-poll-only", _rendererCapPid,
                reason: reason, detected: detected, completed: Stopwatch.GetTimestamp());
            return;
        }
#endif
        var handle = _rendererCapHandle;
        if (handle is null) return;
        if (detected == 0) detected = Stopwatch.GetTimestamp();
        // Restore the exact saved limits/flags, never (-1,-1) or an already-capped snapshot.
        var restored = SetProcessWorkingSetSizeEx(handle.DangerousGetHandle(), _rendererCapOriginalMin,
            _rendererCapOriginalMax, _rendererCapOriginalFlags);
        var completed = Stopwatch.GetTimestamp();
        var error = restored ? 0 : Marshal.GetLastWin32Error();
#if NATIVUNE_PERF_BENCH_HOOKS
        if (restored && GetProcessWorkingSetSizeEx(handle.DangerousGetHandle(), out var restoredMin, out var restoredMax, out var restoredFlags))
            BenchHooks.Event("renderer-cap-restored", ("pid", _rendererCapPid), ("min", (long)restoredMin),
                ("max", (long)restoredMax), ("flags", restoredFlags),
                ("exact", restoredMin == _rendererCapOriginalMin && restoredMax == _rendererCapOriginalMax && restoredFlags == _rendererCapOriginalFlags));
#endif
        const uint stillActive = 259;
        if (restored || (GetExitCodeProcess(handle, out var exitCode) && exitCode != stillActive))
        {
            var policy = _rendererCapPolicy;
            _rendererCapPolicy = RendererCapPolicy.None;
            _fullIdleRevalidationRequested = false;
            _fullIdleRevalidationRetries = 0;
            handle.Dispose();
            _rendererCapHandle = null;
            RendererCapLog(policy, restored ? "released" : "released-exited", _rendererCapPid,
                _rendererCapOriginalMin, _rendererCapOriginalMax, _rendererCapOriginalFlags, reason, detected, completed);
            if (policy == RendererCapPolicy.FullIdle) RefreshSharedReader();
            return;
        }
        // Retain the original snapshot and handle so the next lifecycle/input notification retries exactly.
        RendererCapLog(_rendererCapPolicy, $"release-failed {new Win32Exception(error).Message}", _rendererCapPid,
            reason: reason, detected: detected, completed: completed);
    }

    private void RendererCapLog(RendererCapPolicy policy, string outcome, int processId,
        nint min = 0, nint max = 0, uint flags = 0, string? reason = null, long detected = 0, long completed = 0)
    {
        if (!outcome.StartsWith("applied", StringComparison.Ordinal) && !outcome.StartsWith("released", StringComparison.Ordinal))
            AppLog.Write("memory", $"{policy} renderer cap: {outcome}");
#if NATIVUNE_PERF_BENCH_HOOKS
        BenchHooks.Event(policy == RendererCapPolicy.FullIdle ? "fullidle-cap" : "tray-cap", ("outcome", outcome),
            ("reason", reason), ("pid", processId), ("min", (long)min), ("max", (long)max), ("flags", flags),
            ("originalMin", (long)_rendererCapOriginalMin), ("originalMax", (long)_rendererCapOriginalMax), ("originalFlags", _rendererCapOriginalFlags),
            ("detectedQpc", detected), ("completedQpc", completed), ("qpcFrequency", Stopwatch.Frequency),
            ("releaseLatencyMs", detected == 0 ? null : (double?)(1000d * (completed - detected) / Stopwatch.Frequency)),
            ("classification", policy == RendererCapPolicy.FullIdle && reason is not null ? _fullIdleReleaseClassification : null));
#endif
    }

    [StructLayout(LayoutKind.Sequential)] private struct LastInputInfo { public uint Size, Tick; }
    [DllImport("user32.dll")] private static extern bool GetLastInputInfo(ref LastInputInfo info);
    [DllImport("user32.dll")] private static extern nint GetForegroundWindow();
    [DllImport("user32.dll")] private static extern bool GetCursorPos(out PointI point);
    [DllImport("user32.dll")] private static extern nint WindowFromPoint(PointI point);
    [DllImport("user32.dll")] private static extern nint GetAncestor(nint window, uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessWorkingSetSizeEx(nint process, out nint minimumWorkingSetSize, out nint maximumWorkingSetSize, out uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(SafeProcessHandle process, out uint exitCode);
}
