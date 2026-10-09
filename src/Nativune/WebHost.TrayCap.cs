using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32.SafeHandles;
using UiDispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;

namespace Nativune;

// One renderer, one original snapshot. This limits residency, not allocation; Full is capped only while idle.
public sealed partial class WebHostWindow
{
    // Numeric policy codes are also used in the privacy-safe fuse log.
    private enum RendererCapPolicy { None = 0, Tray = 1, FullIdle = 2, Compact = 3 }
    private const nint TrayRendererCapBytes = 60 << 20;
    private const uint QuotaMinDisable = 0x2, QuotaMaxEnable = 0x4;
    private SafeProcessHandle? _rendererCapHandle;
    private nint _rendererCapOriginalMin, _rendererCapOriginalMax;
    private uint _rendererCapOriginalFlags;
    private int _rendererCapGeneration, _rendererCapPid;
    private RendererCapPolicy _rendererCapPolicy;
    private UiDispatcherQueueTimer? _rendererCapGuardTimer, _compactCapTimer, _rendererCapReturnTimer;
    private RendererCapPolicy _rendererCapEpisode;
    private int _rendererCapSuppressedEpisodes, _rendererCapGuardStrikes, _rendererCapGuardSlowStrikes, _rendererCapRestoreError;
    private readonly long[] _rendererCapCooldownUntil = new long[4]; // Indexed by policy; None is unused.
    private long _rendererCapGuardTimestamp, _rendererCapGuardCpu;
    private long _trayCapSettleUntil, _compactCapSettleUntil;
    private uint _rendererCapGuardFaults;
    private bool _rendererCapRestorePending, _compactCapDeferred;
    private int _compactCapRetries;
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
    private bool _trayCapDeferred;
    private UiDispatcherQueueTimer? _fullIdleTimer;
    private long _lastAppActivity = Stopwatch.GetTimestamp();
    private uint? _lastInputTick, _lastNativeCommandInputTick;
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

    private static double RendererCapCooldownSeconds
    {
        get
        {
#if NATIVUNE_PERF_BENCH_HOOKS
            if (BenchHooks.Enabled && double.TryParse(Environment.GetEnvironmentVariable("NATIVUNE_BENCH_CAP_COOLDOWN_SECONDS"),
                System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var seconds)
                && double.IsFinite(seconds) && seconds is >= 0 and <= 3600) return seconds;
#endif
            return 600;
        }
    }

    private static double CompactCapSeconds
    {
        get
        {
#if NATIVUNE_PERF_BENCH_HOOKS
            if (BenchHooks.Enabled && double.TryParse(Environment.GetEnvironmentVariable("NATIVUNE_BENCH_COMPACT_CAP_SECONDS"),
                System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var seconds)
                && double.IsFinite(seconds) && seconds is > 0 and <= 3600) return seconds;
#endif
            return 5;
        }
    }

    private bool RendererCapAllowed(RendererCapPolicy policy)
    {
#if NATIVUNE_PERF_BENCH_HOOKS
        if (BenchHooks.Enabled && Environment.GetEnvironmentVariable("NATIVUNE_BENCH_CAP_DISABLED") == "1") return false;
#endif
        return (_rendererCapSuppressedEpisodes & (1 << (int)policy)) == 0
            && Stopwatch.GetTimestamp() >= _rendererCapCooldownUntil[(int)policy] && !_rendererCapRestorePending;
    }

    private bool RendererCapEligible(RendererCapPolicy policy, bool settled = true) => !_closing && !_disposed
        && !_resumeShutdownStarted && !_browserFailed && RendererCapAllowed(policy) && (policy switch
        {
            // A hidden render pulse lays out the whole page; under the cap it thrashes and trips the fuse.
            RendererCapPolicy.Tray => IsInTray && _hiddenRenderPulseHost is null
                && (!settled || Stopwatch.GetTimestamp() >= _trayCapSettleUntil),
            RendererCapPolicy.Compact => CompactActive && _hiddenRenderPulseHost is null
                && (!settled || Stopwatch.GetTimestamp() >= _compactCapSettleUntil)
                && _fullIdleDocumentLoaded && !_fullIdleNavigationInProgress
                && !_navigationFailed && !_configuringPrivacy && !_awaitingFirstPage,
            RendererCapPolicy.FullIdle => PollAppInput() && FullIdleEligible,
            _ => false
        });

    private void UpdateRendererCapEpisode()
    {
        // A hidden Compact window belongs to Tray, not Compact. Restore before handing over.
        var episode = IsInTray ? RendererCapPolicy.Tray
            : WindowIsVisible ? (_compact ? RendererCapPolicy.Compact : RendererCapPolicy.FullIdle)
            : RendererCapPolicy.None;
        if (episode == _rendererCapEpisode) return;
        _rendererCapGeneration++; // Invalidate discovery even when no cap has been applied yet.
        // Full's fuse is latched across mode changes until genuine input; hidden episodes reset on departure.
        if (_rendererCapEpisode != RendererCapPolicy.FullIdle)
            _rendererCapSuppressedEpisodes &= ~(1 << (int)_rendererCapEpisode);
        _rendererCapEpisode = episode;
        if (_rendererCapPolicy != RendererCapPolicy.None && _rendererCapPolicy != episode)
            ReleaseRendererCap("mode-change");
        _compactCapTimer?.Stop();
        if (episode == RendererCapPolicy.Compact) ArmCompactCap();
    }

    private void ArmCompactCap()
    {
        if (_compactCapTimer is null || !RendererCapEligible(RendererCapPolicy.Compact, settled: false)) return;
        _compactCapRetries = 0;
        _rendererCapGeneration++;
        _compactCapSettleUntil = Stopwatch.GetTimestamp() + (long)(_compactCapTimer.Interval.TotalSeconds * Stopwatch.Frequency);
        _compactCapTimer.Stop();
        _compactCapTimer.Start();
    }

    private void RetryCompactCap()
    {
        if (_compactCapTimer is null || _compactCapRetries >= 3 || !RendererCapEligible(RendererCapPolicy.Compact, settled: false)) return;
        _compactCapRetries++;
        _rendererCapGeneration++;
        _compactCapSettleUntil = Stopwatch.GetTimestamp() + (long)(_compactCapTimer.Interval.TotalSeconds * Stopwatch.Frequency);
        _compactCapTimer.Stop();
        _compactCapTimer.Start();
    }

    private void RetryRendererCap(RendererCapPolicy policy)
    {
        if (policy == RendererCapPolicy.Tray) RetryTrayCap();
        else if (policy == RendererCapPolicy.Compact) RetryCompactCap();
    }

    private static bool TryReadRendererCapCounters(SafeProcessHandle handle,
        out MemoryTrailProcessCounters memory, out long cpu)
    {
        cpu = 0;
        if (!TryReadMemoryTrailProcess(handle, out memory)
            || !GetProcessTimes(handle, out _, out _, out var kernel, out var user)) return false;
        cpu = kernel + user;
        return true;
    }

    private void SampleRendererCapGuard()
    {
        var handle = _rendererCapHandle;
        if (handle is null) { _rendererCapGuardTimer?.Stop(); return; }
        if (_rendererCapRestorePending) { ReleaseRendererCap("restore-retry"); return; }
        var now = Stopwatch.GetTimestamp();
        var elapsed = (double)(now - _rendererCapGuardTimestamp) / Stopwatch.Frequency;
        if (!TryReadRendererCapCounters(handle, out var memory, out var cpu)
            || elapsed <= 0 || cpu < _rendererCapGuardCpu)
        {
            TripRendererCapGuard(3, 0, 0, 0, 0, Math.Max(0, elapsed) * 1000); // 3 = monitoring failed
            return;
        }
        var cores = (cpu - _rendererCapGuardCpu) / 10_000_000d / elapsed;
        var faults = unchecked(memory.PageFaultCount - _rendererCapGuardFaults) / elapsed;
        _rendererCapGuardTimestamp = now;
        _rendererCapGuardCpu = cpu;
        _rendererCapGuardFaults = memory.PageFaultCount;
        _rendererCapGuardStrikes = faults >= 10_000 && cores >= 0.15 ? _rendererCapGuardStrikes + 1 : 0;
        _rendererCapGuardSlowStrikes = faults >= 10_000 && cores >= 0.05 ? _rendererCapGuardSlowStrikes + 1 : 0;
        var ws = (double)memory.WorkingSetSize / MemoryTrailMiB;
        var allocation = (double)memory.PrivateUsage / MemoryTrailMiB;
#if NATIVUNE_PERF_BENCH_HOOKS
        BenchHooks.Event("cap-guard-sample", ("policy", (int)_rendererCapPolicy), ("cpu_cores", cores),
            ("faults_s", faults), ("ws_mib", ws), ("private_mib", allocation),
            ("strikes", _rendererCapGuardStrikes), ("fast_strikes", _rendererCapGuardStrikes),
            ("slow_strikes", _rendererCapGuardSlowStrikes), ("sample_ms", elapsed * 1000));
        if (BenchHooks.Enabled && Environment.GetEnvironmentVariable("NATIVUNE_BENCH_CAP_NO_FUSE") == "1") return;
#endif
        // 1 = three fast windows; 4 = ten slow windows; 2 is unused; 3 = monitoring failure.
        if (_rendererCapGuardStrikes >= 3 || _rendererCapGuardSlowStrikes >= 10)
            TripRendererCapGuard(_rendererCapGuardStrikes >= 3 ? 1 : 4, cores, faults, ws, allocation, elapsed * 1000);
    }

    private void TripRendererCapGuard(int reason, double cores, double faults, double ws, double allocation, double sampleMs)
    {
        var policy = _rendererCapPolicy;
        var pid = _rendererCapPid;
#if NATIVUNE_PERF_BENCH_HOOKS
        var strikes = _rendererCapGuardStrikes;
        var slowStrikes = _rendererCapGuardSlowStrikes;
#endif
        var cooldown = RendererCapCooldownSeconds;
        _rendererCapCooldownUntil[(int)policy] = Stopwatch.GetTimestamp() + (long)(cooldown * Stopwatch.Frequency);
        // Full stays latched until genuine input. Hidden caps return once the cooldown ends: YouTube Music's
        // periodic bursts trip them about once per session, and an episode-long latch left the renderer
        // uncapped (about 200 MB instead of 60) for the rest of a multi-hour tray session.
        if (policy == RendererCapPolicy.FullIdle) _rendererCapSuppressedEpisodes |= 1 << (int)policy;
        else if (policy is RendererCapPolicy.Tray or RendererCapPolicy.Compact) ScheduleRendererCapReturn();
        if (policy == RendererCapPolicy.FullIdle)
        {
            // Only input newer than this trip can release Full's latch.
            var input = new LastInputInfo { Size = (uint)Marshal.SizeOf<LastInputInfo>() };
            _lastInputTick = _lastNativeCommandInputTick = GetLastInputInfo(ref input) ? input.Tick : null;
            _lastInputCursor = GetCursorPos(out var cursor) ? cursor : null;
        }
        ReleaseRendererCap("fuse");
        var restored = _rendererCapHandle is null && _rendererCapRestoreError == 0 ? 1 : 0;
        AppLog.Write("memory", FormattableString.Invariant(
            $"renderer cap fuse: policy={(int)policy} reason={reason} pid={pid} cpu_cores={cores:F3} faults_s={faults:F0} ws_mib={ws:F1} private_mib={allocation:F1} sample_ms={sampleMs:F0} cooldown_s={cooldown:F0} restored={restored} error={_rendererCapRestoreError}"));
#if NATIVUNE_PERF_BENCH_HOOKS
        BenchHooks.Event("cap-guard-trip", ("policy", (int)policy), ("reason", reason), ("pid", pid),
            ("cpu_cores", cores), ("faults_s", faults), ("ws_mib", ws), ("private_mib", allocation),
            ("sample_ms", sampleMs), ("strikes", strikes), ("fast_strikes", strikes),
            ("slow_strikes", slowStrikes), ("cooldown_s", cooldown),
            ("restored", restored), ("error", _rendererCapRestoreError));
#endif
    }

    // Fires at the earliest pending Tray/Compact cooldown end, then reschedules for any later one,
    // so a second policy's trip never postpones the first policy's return.
    private void ScheduleRendererCapReturn()
    {
        var now = Stopwatch.GetTimestamp();
        long due = 0;
        foreach (var until in (ReadOnlySpan<long>)[_rendererCapCooldownUntil[(int)RendererCapPolicy.Tray],
                     _rendererCapCooldownUntil[(int)RendererCapPolicy.Compact]])
            if (until > now && (due == 0 || until < due)) due = until;
        _rendererCapReturnTimer?.Stop();
        if (due == 0) return;
        if (_rendererCapReturnTimer is null)
        {
            _rendererCapReturnTimer = _dispatcherQueue.CreateTimer();
            _rendererCapReturnTimer.IsRepeating = false;
            // The arm gates recheck the episode, cooldown and restore state; a stale tick is a no-op.
            _rendererCapReturnTimer.Tick += (_, _) =>
            {
                if (IsInTray) ArmTrayCap();
                else if (CompactActive) ArmCompactCap();
                ScheduleRendererCapReturn();
            };
        }
        // One second past the Stopwatch gate, so the arm sees the cooldown as over.
        _rendererCapReturnTimer.Interval = TimeSpan.FromSeconds((double)(due - now) / Stopwatch.Frequency + 1);
        _rendererCapReturnTimer.Start();
    }

    private void RegisterFullIdleButtons(Microsoft.UI.Xaml.DependencyObject root)
    {
        if (root is Microsoft.UI.Xaml.Controls.Primitives.ButtonBase button)
            button.Click += (_, _) => RecordAppActivity("shell-command", appInput: true);
        for (var i = 0; i < Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChildrenCount(root); i++)
            RegisterFullIdleButtons(Microsoft.UI.Xaml.Media.VisualTreeHelper.GetChild(root, i));
    }

    private void InitializeFullIdlePolicy()
    {
        _fullIdleWaitSeconds = FullIdleSeconds;
        _rendererCapGuardTimer = _dispatcherQueue.CreateTimer();
        _rendererCapGuardTimer.Interval = TimeSpan.FromSeconds(2);
        _rendererCapGuardTimer.IsRepeating = true;
        _rendererCapGuardTimer.Tick += (_, _) => SampleRendererCapGuard();
        _compactCapTimer = _dispatcherQueue.CreateTimer();
        _compactCapTimer.Interval = TimeSpan.FromSeconds(CompactCapSeconds);
        _compactCapTimer.IsRepeating = false;
        _compactCapTimer.Tick += (_, _) =>
        {
            if (RendererCapEligible(RendererCapPolicy.Compact)) _ = CapOrRevalidateRendererAsync(RendererCapPolicy.Compact);
            else if (RendererCapEligible(RendererCapPolicy.Compact, settled: false)) _compactCapTimer?.Start();
        };
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
            if (RendererCapEligible(RendererCapPolicy.FullIdle) && (!RendererCapActive || _fullIdleRevalidationRequested) && !_rendererCapPending
                && Stopwatch.GetTimestamp() >= _rendererCapRetryAfter)
                _ = CapOrRevalidateRendererAsync(RendererCapPolicy.FullIdle);
        };
        Activated += (_, args) =>
        {
            if (args.WindowActivationState != Microsoft.UI.Xaml.WindowActivationState.Deactivated)
                RecordAppActivity("activation", appInput: false);
        };
    }

    private void RecordAppActivity(string reason, bool appInput = false, double? idleWaitSeconds = null)
    {
        var detected = Stopwatch.GetTimestamp();
        _lastAppActivity = detected;
        _fullIdleWaitSeconds = idleWaitSeconds ?? FullIdleSeconds;
        if (appInput)
        {
            _appInputSinceSource = true;
            _automaticDocumentChange = false;
            _rendererCapSuppressedEpisodes &= ~(1 << (int)RendererCapPolicy.FullIdle);
        }
        // Tray discovery is independent of activity; only invalidate pending Full-idle discovery.
        if (!IsInTray && !_compact) _rendererCapGeneration++;
        if (_rendererCapPolicy == RendererCapPolicy.FullIdle) ReleaseRendererCap(reason, detected);
        UpdateFullIdlePolling();
    }

    private void RecordSourceChange(bool newDocument, string? source)
    {
        _rendererCapGeneration++; // A same-renderer SPA change must also retire stale pending discovery.
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
        if (IsInTray) ArmTrayCap();
        else if (CompactActive) ArmCompactCap();
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
            RecordAppActivity("input-query-failed", appInput: false);
            return false;
        }
        var changed = _lastInputTick is { } previous && previous != input.Tick;
        _lastInputTick = input.Tick;
        _lastNativeCommandInputTick ??= input.Tick; // Seed only; foreground polling must not consume command input.
        if (changed && (GetForegroundWindow() == NativeHandle
            || cursorMoved && GetAncestor(WindowFromPoint(cursor), 2) == NativeHandle))
            RecordAppActivity("app-input", appInput: true);
        return true;
    }

    private void RecordNativeCommandInput(string reason)
    {
        // Native command messages alone are not input: programmatic commands must not clear Full's fuse.
        var input = new LastInputInfo { Size = (uint)Marshal.SizeOf<LastInputInfo>() };
        if (!GetLastInputInfo(ref input)) return;
        var changed = _lastNativeCommandInputTick is { } previous && previous != input.Tick;
        _lastNativeCommandInputTick = input.Tick;
        if (changed) RecordAppActivity(reason, appInput: true);
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
        if (!RendererCapEligible(policy)) return;
        if (_rendererCapPending)
        {
            if (policy == RendererCapPolicy.Tray) _trayCapDeferred = true;
            if (policy == RendererCapPolicy.Compact) _compactCapDeferred = true;
            return;
        }
        if (RendererCapActive)
        {
            var generation = _rendererCapGeneration;
            var capped = _rendererCapPid;
            _rendererCapPending = true;
            if (policy == RendererCapPolicy.FullIdle) _fullIdleRevalidationRequested = false;
            try
            {
                var (current, _) = await FindMainRendererAsync();
                if (!RendererCapActive || _rendererCapPolicy != policy
                    || !RendererCapEligible(policy) || generation != _rendererCapGeneration) return;
                // An inconclusive lookup is not evidence of replacement; retain the original pinned snapshot.
                if (current == 0)
                {
                    if (policy != RendererCapPolicy.FullIdle) RetryRendererCap(policy);
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
            finally { FinishRendererCapLookup(); }
        }
        await CapRendererAsync(policy);
    }

    private async Task CapRendererAsync(RendererCapPolicy policy)
    {
        var generation = ++_rendererCapGeneration;
        bool Current() => !RendererCapActive && RendererCapEligible(policy) && generation == _rendererCapGeneration;
        if (!Current()) return;
        _rendererCapPending = true;
        try
        {
            var (processId, outcome) = await FindMainRendererAsync();
            if (!Current()) return;
            if (processId == 0) { RendererCapLog(policy, outcome, 0); RetryRendererCap(policy); return; }
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
            if (handle.IsInvalid) { handle.Dispose(); RendererCapLog(policy, "open-failed", processId); RetryRendererCap(policy); return; }
            // The handle pins the PID; recheck that it still owns only our main frame.
            var (recheckId, _) = await FindMainRendererAsync();
            if (!Current() || recheckId != processId)
            {
                handle.Dispose();
                if (Current()) { RendererCapLog(policy, "renderer-changed", processId); RetryRendererCap(policy); }
                return;
            }
            var cap = policy == RendererCapPolicy.FullIdle ? FullIdleCapBytes : TrayRendererCapBytes;
            // Never apply a cap whose pinned process cannot be monitored.
            if (!TryReadRendererCapCounters(handle, out var seedMemory, out var seedCpu))
            {
                handle.Dispose();
                RendererCapLog(policy, "monitor-seed-failed", processId);
                RetryRendererCap(policy);
                return;
            }
            var seedTimestamp = Stopwatch.GetTimestamp();
            // Raising the process's minimum fails from a standard token (ERROR_PRIVILEGE_NOT_HELD).
            var limitsRead = GetProcessWorkingSetSizeEx(handle.DangerousGetHandle(), out var min, out var max, out var flags);
            if (!limitsRead || min >= cap
                || !SetProcessWorkingSetSizeEx(handle.DangerousGetHandle(), min, cap, QuotaMinDisable | QuotaMaxEnable))
            {
                RendererCapLog(policy, "apply-failed", processId);
                handle.Dispose();
                // API failure may be an exiting renderer; a successfully read excessive minimum is permanent.
                if (!limitsRead || min < cap) RetryRendererCap(policy);
                return;
            }
            _rendererCapHandle = handle;
            (_rendererCapOriginalMin, _rendererCapOriginalMax, _rendererCapOriginalFlags) = (min, max, flags);
            _rendererCapPid = processId;
            _rendererCapPolicy = policy;
            if (policy == RendererCapPolicy.FullIdle) _appInputSinceSource = false;
            _rendererCapGuardTimestamp = seedTimestamp;
            _rendererCapGuardCpu = seedCpu;
            _rendererCapGuardFaults = seedMemory.PageFaultCount;
            _rendererCapGuardStrikes = _rendererCapGuardSlowStrikes = 0;
            _rendererCapRestorePending = false;
            _rendererCapRestoreError = 0;
            _rendererCapGuardTimer?.Start();
            RendererCapLog(policy, "applied", processId, min, cap, QuotaMinDisable | QuotaMaxEnable,
                reason: policy == RendererCapPolicy.FullIdle ? "idle" : policy == RendererCapPolicy.Compact ? "compact" : "tray");
#if NATIVUNE_PERF_BENCH_HOOKS
            BenchCapApplied();
#endif
            if (policy == RendererCapPolicy.FullIdle) RefreshSharedReader();
        }
        finally
        {
            FinishRendererCapLookup();
            if (!RendererCapActive) _rendererCapRetryAfter = Stopwatch.GetTimestamp() + 30 * Stopwatch.Frequency;
            UpdateFullIdlePolling();
        }

    }

    private void FinishRendererCapLookup()
    {
        _rendererCapPending = false;
        if (_trayCapDeferred)
        {
            _trayCapDeferred = false;
            // A deferred lookup must still honor episode suppression and cooldown.
            ArmTrayCap();
        }
        if (_compactCapDeferred)
        {
            _compactCapDeferred = false;
            ArmCompactCap();
        }
    }

    // Discovery can be inconclusive while a page or renderer is still settling; try again a few times.
    private void RetryTrayCap()
    {
        if (_trayCapRetries >= 3 || !RendererCapEligible(RendererCapPolicy.Tray, settled: false)) return;
        _trayCapRetries++;
        _rendererCapGeneration++;
        _trayCapSettleUntil = Stopwatch.GetTimestamp() + (long)(_trayCapTimer.Interval.TotalSeconds * Stopwatch.Frequency);
        _trayCapTimer.Stop();
        _trayCapTimer.Start();
    }

    private void ArmTrayCap()
    {
        if (!RendererCapEligible(RendererCapPolicy.Tray, settled: false)) return;
        _trayCapRetries = 0;
        _rendererCapGeneration++;
        _trayCapSettleUntil = Stopwatch.GetTimestamp() + (long)(_trayCapTimer.Interval.TotalSeconds * Stopwatch.Frequency);
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
        var injectRestoreFailure = false;
#if NATIVUNE_PERF_BENCH_HOOKS
        if (BenchHooks.Enabled && !_benchCapRestoreFailureInjected
            && Environment.GetEnvironmentVariable("NATIVUNE_BENCH_CAP_RESTORE_FAIL_ONCE") == "1")
        {
            _benchCapRestoreFailureInjected = true;
            injectRestoreFailure = true;
        }
#endif
        var restored = !injectRestoreFailure && SetProcessWorkingSetSizeEx(handle.DangerousGetHandle(), _rendererCapOriginalMin,
            _rendererCapOriginalMax, _rendererCapOriginalFlags);
        var completed = Stopwatch.GetTimestamp();
        var error = restored ? 0 : injectRestoreFailure ? 5 : Marshal.GetLastWin32Error();
        var reportRestoreFailure = !_rendererCapRestorePending || _rendererCapRestoreError != error;
        var wasRestorePending = _rendererCapRestorePending;
        _rendererCapRestoreError = error;
#if NATIVUNE_PERF_BENCH_HOOKS
        if (restored && GetProcessWorkingSetSizeEx(handle.DangerousGetHandle(), out var restoredMin, out var restoredMax, out var restoredFlags))
            BenchHooks.Event("renderer-cap-restored", ("pid", _rendererCapPid), ("min", (long)restoredMin),
                ("max", (long)restoredMax), ("flags", restoredFlags),
                ("exact", restoredMin == _rendererCapOriginalMin && restoredMax == _rendererCapOriginalMax && restoredFlags == _rendererCapOriginalFlags));
#endif
        const uint stillActive = 259;
        if (restored || (GetExitCodeProcess(handle, out var exitCode) && exitCode != stillActive))
        {
            _rendererCapGuardTimer?.Stop();
            _rendererCapGuardStrikes = _rendererCapGuardSlowStrikes = 0;
            _rendererCapGuardTimestamp = _rendererCapGuardCpu = 0;
            _rendererCapGuardFaults = 0;
            _rendererCapRestorePending = false;
            var policy = _rendererCapPolicy;
            _rendererCapPolicy = RendererCapPolicy.None;
            _fullIdleRevalidationRequested = false;
            _fullIdleRevalidationRetries = 0;
            handle.Dispose();
            _rendererCapHandle = null;
            RendererCapLog(policy, restored ? "released" : "released-exited", _rendererCapPid,
                _rendererCapOriginalMin, _rendererCapOriginalMax, _rendererCapOriginalFlags, reason, detected, completed);
            if (policy == RendererCapPolicy.FullIdle) RefreshSharedReader();
            if (wasRestorePending)
            {
                // A failed handoff must resume its new owner after restoration, not lose the one-shot arm.
                // The arm gates still enforce episode suppression and that policy's cooldown.
                if (_rendererCapEpisode == RendererCapPolicy.Tray) ArmTrayCap();
                else if (_rendererCapEpisode == RendererCapPolicy.Compact) ArmCompactCap();
                else if (_rendererCapEpisode == RendererCapPolicy.FullIdle) UpdateFullIdlePolling();
            }
            return;
        }
        // Keep sampling/retrying with this snapshot; never treat a failed restore as uncapped.
        if (reportRestoreFailure)
            AppLog.Write("memory", $"renderer cap restore: policy={(int)_rendererCapPolicy} pid={_rendererCapPid} restored=0 error={error}");
        _rendererCapRestorePending = true;
        _rendererCapGuardTimer?.Start();
#if NATIVUNE_PERF_BENCH_HOOKS
        BenchHooks.Event("renderer-cap-restore-failed", ("policy", (int)_rendererCapPolicy),
            ("pid", _rendererCapPid), ("error", error));
#endif
    }

    private void RendererCapLog(RendererCapPolicy policy, string outcome, int processId,
        nint min = 0, nint max = 0, uint flags = 0, string? reason = null, long detected = 0, long completed = 0)
    {
        if (!outcome.StartsWith("applied", StringComparison.Ordinal) && !outcome.StartsWith("released", StringComparison.Ordinal))
        {
            // Numeric outcome codes: 1=open, 2=apply, 3=monitor seed, 4=identity, 5=discovery.
            var code = outcome switch { "open-failed" => 1, "apply-failed" => 2,
                "monitor-seed-failed" => 3, "renderer-changed" => 4, _ => 5 };
            AppLog.Write("memory", $"renderer cap: policy={(int)policy} outcome={code} pid={processId} error={Marshal.GetLastWin32Error()}");
        }
#if NATIVUNE_PERF_BENCH_HOOKS
        BenchHooks.Event(policy == RendererCapPolicy.FullIdle ? "fullidle-cap"
            : policy == RendererCapPolicy.Compact ? "compact-cap" : "tray-cap", ("outcome", outcome),
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
