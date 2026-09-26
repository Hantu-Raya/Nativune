#if NATIVUNE_PERF_BENCH_HOOKS
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using System.Diagnostics;
using System.Text.Json;
using UiDispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;

namespace Nativune;

// Perf bench seam (contract: .cache/perf/bench-contract.md), compiled only with -p:PerfBenchHooks=true.
// WebHost.cs declares the Bench* partial methods without a body; release builds therefore drop them
// and their call sites, so no bench code or NATIVUNE_BENCH_ names ship.
public sealed partial class WebHostWindow
{
    private const string BenchMediaScript =
        "(()=>{const v=document.querySelector('video');if(!v)return {playing:false,paused:null,currentTime:null,duration:null};return {playing:!v.paused&&!v.ended,paused:v.paused,currentTime:Number.isFinite(v.currentTime)?v.currentTime:null,duration:Number.isFinite(v.duration)?v.duration:null};})()";
    private static readonly TimeSpan BenchMediaDetectTimeout = TimeSpan.FromSeconds(120);
    private readonly record struct BenchMediaState(bool? Paused, double? CurrentTime, double? Duration, bool Playing);

    private bool _benchWindowShown;
    private bool _benchNavigationLogged;
    private bool _benchMediaResolved;
    private bool _benchMediaPollPending;
    private bool _benchAnchorStarted;
    private bool _benchSchedulePending;
    private int _benchScheduleIndex;
    private long _benchMediaStartedAt;
    private long _benchAnchorTimestamp;
    private bool? _benchPendingCompactPresentation;
    private UiDispatcherQueueTimer? _benchMediaPollTimer;
    private UiDispatcherQueueTimer? _benchScheduleTimer;
    private UiDispatcherQueueTimer? _benchPresentationTimer;

    partial void BenchInitialize()
    {
        if (!BenchHooks.Enabled) return;
        _benchPresentationTimer = _dispatcherQueue.CreateTimer();
        _benchPresentationTimer.Interval = TimeSpan.FromMilliseconds(50);
        _benchPresentationTimer.IsRepeating = true;
        _benchPresentationTimer.Tick += OnBenchPresentationTick;
    }

    partial void BenchStart(ref string browserArguments)
    {
        browserArguments = BenchHooks.BuildBrowserArguments(browserArguments);
        BenchHooks.Start(browserArguments);
    }

    partial void BenchEnvironmentCreated() => BenchHooks.EnvironmentCreated();

    partial void BenchControllerCreated() => BenchHooks.ControllerCreated();

    partial void BenchMuteOutput()
    {
        if (!BenchHooks.MuteOutput) return;
        _desiredOutputVolume = 0;
        QueueOutputAudioRequest(CaptureOutputAudioProcesses(), volume: 0);
    }

    partial void BenchStartUri(ref string uri)
    {
        if (BenchHooks.StartUri is { } startUri) uri = startUri.AbsoluteUri;
    }

    partial void BenchWindowShown()
    {
        if (!BenchHooks.Enabled || _benchWindowShown || _appWindow?.IsVisible != true) return;
        _benchWindowShown = true;
        BenchHooks.WindowShown();
    }

    partial void BenchNavigationCompleted()
    {
        if (!BenchHooks.Enabled || _benchNavigationLogged) return;
        _benchNavigationLogged = true;
        var path = "/";
        if (Uri.TryCreate(_browserHost?.Core.Source, UriKind.Absolute, out var navigationUri))
            path = navigationUri.AbsolutePath;
        BenchHooks.NavigationCompleted(ok: true, path: path);
        StartBenchMediaDetector();
    }

    partial void BenchCompactRequested(bool compact)
    {
        if (compact == (_compact || _compactWhenReady)) return;
        if (compact) BenchHooks.CompactRequested();
        else BenchHooks.FullRequested();
    }

    partial void BenchPresentationChanged()
    {
        if (_benchPresentationTimer is null) return;
        _benchPendingCompactPresentation = _compact;
        _benchPresentationTimer.Start();
    }

    partial void BenchStopTimers()
    {
        try
        {
            _benchMediaPollTimer?.Stop();
            _benchScheduleTimer?.Stop();
            _benchPresentationTimer?.Stop();
        }
        catch (Exception) { }
    }

    // H14: process kinds for the harness on every ProcessInfosChanged.
    partial void BenchProcessInfos()
    {
        if (!BenchHooks.Enabled || _environment is null) return;
        try
        {
            var processes = new List<Dictionary<string, object?>>();
            foreach (var info in _environment.GetProcessInfos())
                processes.Add(new() { ["pid"] = info.ProcessId, ["kind"] = info.Kind.ToString() });
            BenchHooks.Event("process-infos", ("processes", processes));
        }
        catch (Exception) { }
    }

    private void StartBenchMediaDetector()
    {
        if (_benchMediaResolved || _closing || _disposed) return;
        _benchMediaStartedAt = Stopwatch.GetTimestamp();
        if (_benchMediaPollTimer is null)
        {
            _benchMediaPollTimer = _dispatcherQueue.CreateTimer();
            _benchMediaPollTimer.Interval = TimeSpan.FromMilliseconds(500);
            _benchMediaPollTimer.IsRepeating = true;
            _benchMediaPollTimer.Tick += OnBenchMediaPollTick;
        }
        _benchMediaPollTimer.Start();
    }

    private bool BenchMediaDetectExpired
        => Stopwatch.GetElapsedTime(_benchMediaStartedAt) >= BenchMediaDetectTimeout;

    private async void OnBenchMediaPollTick(object? sender, object args)
    {
        if (_closing || _disposed)
        {
            _benchMediaPollTimer?.Stop();
            return;
        }
        if (_benchMediaResolved || _benchMediaStartedAt == 0) return;
        if (BenchMediaDetectExpired)
        {
            CompleteBenchMediaTimeout();
            return;
        }
        if (_benchMediaPollPending || _browserHost is null) return;
        _benchMediaPollPending = true;
        try
        {
            var sample = await CaptureBenchMediaSampleAsync();
            if (_closing || _disposed || _benchMediaResolved) return;
            if (BenchMediaDetectExpired)
            {
                CompleteBenchMediaTimeout();
                return;
            }
            if (!sample.Playing) return;

            _benchMediaResolved = true;
            _benchMediaPollTimer?.Stop();
            BenchHooks.MediaPlaying(sample.CurrentTime ?? 0);
            StartBenchSchedule("media-playing");
        }
        catch (Exception)
        {
        }
        finally
        {
            _benchMediaPollPending = false;
        }
    }

    private void CompleteBenchMediaTimeout()
    {
        if (_closing || _disposed || _benchMediaResolved) return;
        _benchMediaResolved = true;
        _benchMediaPollTimer?.Stop();
        BenchHooks.MediaTimeout();
        StartBenchSchedule("media-timeout");
    }

    private void StartBenchSchedule(string source)
    {
        if (_closing || _disposed || _benchAnchorStarted) return;
        _benchAnchorStarted = true;
        _benchAnchorTimestamp = Stopwatch.GetTimestamp();
        BenchHooks.Anchor(source);
        if (BenchHooks.Schedule.Count == 0) return;

        _benchScheduleTimer = _dispatcherQueue.CreateTimer();
        _benchScheduleTimer.Interval = TimeSpan.FromMilliseconds(50);
        _benchScheduleTimer.IsRepeating = true;
        _benchScheduleTimer.Tick += OnBenchScheduleTick;
        _benchScheduleTimer.Start();
    }

    private async void OnBenchScheduleTick(object? sender, object args)
    {
        if (_closing || _disposed || _benchSchedulePending || !_benchAnchorStarted) return;
        var schedule = BenchHooks.Schedule;
        if (_benchScheduleIndex >= schedule.Count)
        {
            _benchScheduleTimer?.Stop();
            return;
        }
        var scheduled = schedule[_benchScheduleIndex];
        if (Stopwatch.GetElapsedTime(_benchAnchorTimestamp).TotalSeconds < scheduled.Seconds) return;

        _benchScheduleIndex++;
        _benchSchedulePending = true;
        try
        {
            var sample = await CaptureBenchMediaSampleAsync();
            if (_closing || _disposed) return;
            BenchHooks.MediaSample(sample.Paused, sample.CurrentTime, sample.Duration);
            // Same code paths as the user commands: SetCompact, tray hide/minimize, activation, explicit quit.
            switch (scheduled.Action)
            {
                case "compact":
                    SetCompact(true);
                    break;
                case "full":
                    SetCompact(false);
                    break;
                case "hide":
                    BenchHooks.HideRequested();
                    if (!TryHideToTray())
                    {
                        _presenter?.Minimize();
                        UpdateWindowVisibilityPolicy();
                    }
                    if (await WaitForBenchVisibilityAsync(visible: false))
                        BenchHooks.HideDone();
                    break;
                case "show":
                    BenchHooks.ShowRequested();
                    if (_presenter?.State == OverlappedPresenterState.Minimized)
                        _presenter.Restore();
                    if (_appWindow?.IsVisible == false)
                        RequestActivation();
                    else
                    {
                        _appWindow?.Show();
                        Activate();
                        UpdateBrowserVisibility();
                    }
                    if (await WaitForBenchVisibilityAsync(visible: true))
                        BenchHooks.ShowDone();
                    break;
                case "quit":
                    BenchHooks.QuitRequested();
                    _benchScheduleTimer?.Stop();
                    _ = ShutdownAsync();
                    break;
            }
        }
        catch (Exception)
        {
        }
        finally
        {
            _benchSchedulePending = false;
        }
    }

    private async Task<bool> WaitForBenchVisibilityAsync(bool visible)
    {
        for (var attempt = 0; attempt < 40; attempt++)
        {
            if (_closing || _disposed) return false;
            if (WindowIsVisible == visible) return true;
            await Task.Delay(TimeSpan.FromMilliseconds(50));
        }
        return false;
    }

    private async Task<BenchMediaState> CaptureBenchMediaSampleAsync()
    {
        if (_browserHost is null) return new(null, null, null, false);
        try
        {
            var result = await _browserHost.Core.ExecuteScriptAsync(BenchMediaScript);
            return ParseBenchMediaState(result);
        }
        catch (Exception)
        {
            return new(null, null, null, false);
        }
    }

    private static BenchMediaState ParseBenchMediaState(string json)
    {
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        bool? paused = root.TryGetProperty("paused", out var pausedValue)
            ? pausedValue.ValueKind switch
            {
                JsonValueKind.True => true,
                JsonValueKind.False => false,
                _ => null
            }
            : null;
        double? ReadNumber(string name)
        {
            if (!root.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number
                || !value.TryGetDouble(out var number) || !double.IsFinite(number))
                return null;
            return number;
        }
        var playing = root.TryGetProperty("playing", out var playingValue)
            && playingValue.ValueKind == JsonValueKind.True;
        return new(paused, ReadNumber("currentTime"), ReadNumber("duration"), playing);
    }

    private void OnBenchPresentationTick(object? sender, object args)
    {
        if (_closing || _disposed || !_benchPendingCompactPresentation.HasValue)
        {
            _benchPresentationTimer?.Stop();
            return;
        }
        if (!WindowIsVisible) return;

        var compact = _benchPendingCompactPresentation.Value;
        if (_compact != compact
            || CompactView.Visibility != (compact ? Visibility.Visible : Visibility.Collapsed)
            || WebViewSlot.Visibility != (compact ? Visibility.Collapsed : Visibility.Visible))
            return;
        _benchPendingCompactPresentation = null;
        _benchPresentationTimer?.Stop();
        if (compact) BenchHooks.CompactShown();
        else BenchHooks.FullShown();
    }
}
#endif
