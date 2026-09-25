using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Input;
using VirtualKey = Windows.System.VirtualKey;

namespace Nativune;

public sealed partial class WebHostWindow
{
    private static readonly TimeSpan OutputAudioCommandLifetime = TimeSpan.FromSeconds(2);
    private static readonly TimeSpan OutputAudioStateLifetime = TimeSpan.FromSeconds(4);
    private const int MaximumOutputPreferenceAttempts = 2;

    private readonly object _outputAudioGate = new();
    private WebViewAudioVolume? _outputAudio;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _outputAudioTimer;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _outputFlyoutCloseTimer;
    private string? _outputAudioExecutablePath;
    private HashSet<int> _outputAudioProcessIds = [];
    private bool _outputAudioPathVerified;
    private PendingOutputVolume? _pendingOutputVolume;
    private PendingOutputMute? _pendingOutputMute;
    private OutputAudioState _outputAudioState = OutputAudioState.Unavailable;
    private DateTime _outputAudioStateConfirmedAt;
    private double _desiredOutputVolume = WebViewAudioVolume.DefaultVolume;
    private bool? _desiredOutputMute;
    private bool _outputAudioRefreshPending;
    private bool _outputAudioWorkerRunning;
    private bool _outputAudioClosed;
    private bool _outputAudioBackendDisposed;
    private bool _updatingOutputAudio;
    private double? _pendingOutputDisplayVolume;
    private DateTime _pendingOutputDisplayUntil;
    private DateTime _pendingOutputMuteDisplayUntil;
    private bool _outputButtonPointerOver;
    private bool _outputFlyoutPointerOver;
    private bool _outputFlyoutPinned;
    private bool _outputFlyoutFocusSlider;
    private bool? _outputIconMuted;
    private long _outputAudioGeneration;
    private long _outputPreferenceRevision;
    private long _lastAppliedOutputPreferenceRevision;
    private long _outputPreferenceAttemptRevision;
    private int _outputPreferenceAttemptCount;
    private long _outputAudioResultSequence;
    private long _lastAppliedOutputAudioResultSequence;

    private readonly record struct OutputAudioState(
        double Volume,
        bool Muted,
        bool Available,
        bool HasOwnedSessions)
    {
        public static OutputAudioState Unavailable =>
            new(WebViewAudioVolume.DefaultVolume, false, false, false);
    }

    private sealed record PendingOutputVolume(double Value, DateTime ExpiresAt);
    private sealed record PendingOutputMute(bool Value, DateTime ExpiresAt);

    private void InitializeOutputAudio()
    {
        // Restore the saved app volume (and mute, if it was ever set). Revision 1 makes the worker apply
        // it to the first verified WebView-owned audio session after startup.
        lock (_outputAudioGate)
        {
            _desiredOutputVolume = _settings.OutputVolume;
            _desiredOutputMute = _settings.OutputMuted;
            _outputPreferenceRevision = 1;
        }
        _outputAudioTimer = _dispatcherQueue.CreateTimer();
        _outputAudioTimer.Interval = TimeSpan.FromSeconds(1);
        _outputAudioTimer.IsRepeating = true;
        _outputAudioTimer.Tick += (_, _) => RefreshOutputAudio();
        _outputFlyoutCloseTimer = _dispatcherQueue.CreateTimer();
        _outputFlyoutCloseTimer.Interval = TimeSpan.FromMilliseconds(550);
        _outputFlyoutCloseTimer.IsRepeating = false;
        _outputFlyoutCloseTimer.Tick += (_, _) => CloseHoverOutputFlyout();
        OutputMuteButton.Click += (_, _) =>
        {
            OutputVolumeFlyout.Hide();
            ToggleOutputMute();
        };
        OutputMuteButton.ContextRequested += (_, e) =>
        {
            if (!OutputMuteButton.IsEnabled || _compact) return;
            e.Handled = true;
            OpenOutputFlyoutForInteraction();
        };
        OutputMuteButton.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Down || !OutputMuteButton.IsEnabled || _compact) return;
            e.Handled = true;
            OpenOutputFlyoutForInteraction();
        };
        OutputMuteButton.PointerEntered += (_, e) =>
        {
            if (!IsOutputHoverPointer(e, OutputMuteButton) || _compact) return;
            _outputButtonPointerOver = true;
            _outputFlyoutCloseTimer.Stop();
            if (!OutputVolumeFlyout.IsOpen) ShowOutputFlyout(fromHover: true);
        };
        OutputMuteButton.PointerExited += (_, e) =>
        {
            if (!IsOutputHoverPointer(e, OutputMuteButton)) return;
            _outputButtonPointerOver = false;
            ScheduleOutputFlyoutClose();
        };
        OutputVolumeFlyoutSurface.PointerEntered += (_, e) =>
        {
            if (!IsOutputHoverPointer(e, OutputVolumeFlyoutSurface)) return;
            _outputFlyoutPointerOver = true;
            _outputFlyoutCloseTimer.Stop();
        };
        OutputVolumeFlyoutSurface.PointerExited += (_, e) =>
        {
            if (!IsOutputHoverPointer(e, OutputVolumeFlyoutSurface)) return;
            _outputFlyoutPointerOver = false;
            ScheduleOutputFlyoutClose();
        };
        OutputVolumeFlyoutSurface.AddHandler(UIElement.PointerPressedEvent,
            new PointerEventHandler((_, _) => PinOutputFlyout()), true);
        OutputVolumeSlider.GotFocus += (_, _) => PinOutputFlyout();
        OutputVolumeFlyout.Opened += (_, _) =>
        {
            if (_outputFlyoutFocusSlider && OutputVolumeSlider.IsEnabled)
                OutputVolumeSlider.Focus(FocusState.Programmatic);
            _outputFlyoutFocusSlider = false;
        };
        OutputVolumeFlyout.Closed += (_, _) =>
        {
            _outputFlyoutCloseTimer?.Stop();
            _outputButtonPointerOver = false;
            _outputFlyoutPointerOver = false;
            _outputFlyoutPinned = false;
            _outputFlyoutFocusSlider = false;
        };
        OutputVolumeSlider.ValueChanged += OutputVolumeChanged;
        OutputVolumeSlider.Committed += SetOutputVolume;
        UpdateOutputAudioControls();
    }

    private static bool IsOutputHoverPointer(PointerRoutedEventArgs e, UIElement element)
        => e.GetCurrentPoint(element).PointerDeviceType is PointerDeviceType.Mouse or PointerDeviceType.Pen;

    private void ShowOutputFlyout(bool fromHover)
    {
        if (_closing || _disposed || _compact || !OutputMuteButton.IsEnabled || !OutputVolumeSlider.IsEnabled)
            return;
        _outputFlyoutPinned = !fromHover;
        _outputFlyoutFocusSlider = !fromHover;
        OutputVolumeFlyout.ShowMode = fromHover ? FlyoutShowMode.Transient : FlyoutShowMode.Standard;
        OutputVolumeFlyout.ShowAt(OutputMuteButton);
    }

    private void OpenOutputFlyoutForInteraction()
    {
        _outputFlyoutCloseTimer?.Stop();
        if (!OutputVolumeFlyout.IsOpen)
            ShowOutputFlyout(fromHover: false);
        else
        {
            PinOutputFlyout();
            OutputVolumeSlider.Focus(FocusState.Programmatic);
        }
    }

    private void PinOutputFlyout()
    {
        if (!OutputVolumeFlyout.IsOpen) return;
        _outputFlyoutCloseTimer?.Stop();
        _outputFlyoutPinned = true;
    }

    private void ScheduleOutputFlyoutClose()
    {
        if (_disposed || !OutputVolumeFlyout.IsOpen || _outputFlyoutPinned) return;
        _outputFlyoutCloseTimer?.Stop();
        _outputFlyoutCloseTimer?.Start();
    }

    private void CloseHoverOutputFlyout()
    {
        _outputFlyoutCloseTimer?.Stop();
        if (!_disposed && !_outputFlyoutPinned && !_outputButtonPointerOver
            && !_outputFlyoutPointerOver && OutputVolumeFlyout.IsOpen)
            OutputVolumeFlyout.Hide();
    }

    private void CloseOutputVolumeFlyout()
    {
        _outputFlyoutCloseTimer?.Stop();
        if (OutputVolumeFlyout.IsOpen) OutputVolumeFlyout.Hide();
    }

    private void StartOutputAudio()
    {
        if (!_dispatcherQueue.HasThreadAccess)
        {
            _dispatcherQueue.TryEnqueue(StartOutputAudio);
            return;
        }

        if (_closing || _disposed) return;
        UpdateOutputAudioControls();
        _outputAudioTimer?.Start();
        RefreshOutputAudio();
    }

    private void RefreshOutputAudio()
    {
        if (!_dispatcherQueue.HasThreadAccess)
        {
            _dispatcherQueue.TryEnqueue(RefreshOutputAudio);
            return;
        }

        if (_closing || _disposed || _outputAudioClosed) return;
        ExpireOutputAudioStateIfStale();
        QueueOutputAudioRequest(CaptureOutputAudioProcesses());
    }

    private HashSet<int> CaptureOutputAudioProcesses()
    {
        HashSet<int> FailClosed()
        {
            _outputAudioPathVerified = false;
            UpdateOutputAudioControls();
            return [];
        }

        if (_closing || _disposed || _outputAudioClosed || _environment is null)
            return FailClosed();

        try
        {
            var processes = _environment.GetProcessInfos();
            if (processes is null || processes.Count == 0)
                return FailClosed();

            var processIds = new HashSet<int>();
            string? verifiedExecutablePath = null;
            foreach (var process in processes)
            {
                var processId = process.ProcessId;
                if (processId <= 0)
                    return FailClosed();
                if (!processIds.Add(processId))
                    continue;
                if (!WebViewAudioVolume.TryGetWebViewProcessExecutablePath(processId, out var executablePath))
                    return FailClosed();
                if (verifiedExecutablePath is null)
                    verifiedExecutablePath = executablePath;
                else if (!verifiedExecutablePath.Equals(executablePath, StringComparison.OrdinalIgnoreCase))
                    return FailClosed();
            }

            if (verifiedExecutablePath is null
                || (_outputAudioExecutablePath is not null
                    && !_outputAudioExecutablePath.Equals(verifiedExecutablePath, StringComparison.OrdinalIgnoreCase)))
                return FailClosed();

            _outputAudioExecutablePath ??= verifiedExecutablePath;
            _outputAudioPathVerified = true;
            UpdateOutputAudioControls();
            return processIds;
        }
        catch (Exception)
        {
            return FailClosed();
        }
    }

    private void OutputVolumeChanged(object sender, RangeBaseValueChangedEventArgs args)
    {
        if (_updatingOutputAudio) return;
        OutputVolumeValue.Text = $"{args.NewValue / 10:0.0}%";
    }

    private void SetOutputVolume(double value)
    {
        if (!_dispatcherQueue.HasThreadAccess)
        {
            _dispatcherQueue.TryEnqueue(() => SetOutputVolume(value));
            return;
        }
        if (_closing || _disposed || _outputAudioClosed || !_outputAudioPathVerified
            || _outputAudioExecutablePath is null
            || !double.IsFinite(value) || value < 0 || value > 1)
            return;
        _pendingOutputDisplayVolume = value;
        _pendingOutputDisplayUntil = DateTime.UtcNow.Add(OutputAudioCommandLifetime);
        QueueOutputAudioRequest(CaptureOutputAudioProcesses(), volume: value);
        RememberOutputPreference(_settings with { OutputVolume = value });
        UpdateOutputAudioControls();
    }

    private void ToggleOutputMute()
    {
        if (!_dispatcherQueue.HasThreadAccess)
        {
            _dispatcherQueue.TryEnqueue(ToggleOutputMute);
            return;
        }
        if (_closing || _disposed || _outputAudioClosed || !_outputAudioPathVerified
            || _outputAudioExecutablePath is null) return;

        var currentMute = _outputAudioState.Available
            && DateTime.UtcNow >= _pendingOutputMuteDisplayUntil
            ? _outputAudioState.Muted
            : _desiredOutputMute ?? false;
        var requested = !currentMute;
        _pendingOutputMuteDisplayUntil = DateTime.UtcNow.Add(OutputAudioCommandLifetime);
        QueueOutputAudioRequest(CaptureOutputAudioProcesses(), mute: requested);
        RememberOutputPreference(_settings with { OutputMuted = requested });
        UpdateOutputAudioControls();
    }

    // Saved straight away (coalesced with other pending writes), including in fullscreen or Compact.
    private void RememberOutputPreference(ShellSettings updated)
    {
        _settings = updated;
        _pendingSettings = _settings;
        if (_saveTask.IsCompleted) _saveTask = SaveSettingsAsync();
    }

    private void QueueOutputAudioRequest(HashSet<int> processIds, double? volume = null, bool? mute = null)
    {
        var startWorker = false;
        var now = DateTime.UtcNow;
        lock (_outputAudioGate)
        {
            if (_outputAudioClosed || _outputAudioExecutablePath is null) return;

            if (!_outputAudioProcessIds.SetEquals(processIds))
                _outputAudioGeneration++;
            _outputAudioProcessIds = processIds;
            _outputAudioRefreshPending = true;

            if (volume is { } requestedVolume)
            {
                _outputAudioGeneration++;
                _outputPreferenceRevision++;
                _outputPreferenceAttemptRevision = _outputPreferenceRevision;
                _outputPreferenceAttemptCount = 0;
                _desiredOutputVolume = requestedVolume;
                _pendingOutputVolume = new PendingOutputVolume(
                    requestedVolume, now + OutputAudioCommandLifetime);
            }

            if (mute is { } requestedMute)
            {
                _outputAudioGeneration++;
                _outputPreferenceRevision++;
                _outputPreferenceAttemptRevision = _outputPreferenceRevision;
                _outputPreferenceAttemptCount = 0;
                _desiredOutputMute = requestedMute;
                _pendingOutputMute = new PendingOutputMute(requestedMute, now + OutputAudioCommandLifetime);
            }

            if (!_outputAudioWorkerRunning)
            {
                _outputAudioWorkerRunning = true;
                startWorker = true;
            }
        }

        if (startWorker) StartOutputAudioWorker();
    }

    private void StartOutputAudioWorker()
    {
        try
        {
            _ = Task.Run(ProcessOutputAudioWorker);
        }
        catch (Exception)
        {
            lock (_outputAudioGate) _outputAudioWorkerRunning = false;
        }
    }

    private void ProcessOutputAudioWorker()
    {
        while (true)
        {
            long generation;
            HashSet<int> processIds;
            double desiredVolume = WebViewAudioVolume.DefaultVolume;
            bool? desiredMute = null;
            long preferenceRevision = 0;
            var dispose = false;
            lock (_outputAudioGate)
            {
                if (_outputAudioClosed)
                {
                    _pendingOutputVolume = null;
                    _pendingOutputMute = null;
                    _outputAudioRefreshPending = false;
                    if (_outputAudioBackendDisposed)
                    {
                        _outputAudioWorkerRunning = false;
                        return;
                    }
                    generation = _outputAudioGeneration;
                    processIds = [];
                    dispose = true;
                }
                else if (_outputAudioRefreshPending)
                {
                    generation = _outputAudioGeneration;
                    processIds = _outputAudioProcessIds;
                    desiredVolume = _desiredOutputVolume;
                    desiredMute = _desiredOutputMute;
                    preferenceRevision = _outputPreferenceRevision;
                    _outputAudioRefreshPending = false;
                }
                else
                {
                    _outputAudioWorkerRunning = false;
                    return;
                }
            }

            if (dispose)
            {
                try { _outputAudio?.Dispose(); }
                catch (Exception) { }
                _outputAudio = null;
                lock (_outputAudioGate)
                {
                    _outputAudioBackendDisposed = true;
                    _outputAudioWorkerRunning = false;
                }
                return;
            }

            var state = OutputAudioState.Unavailable;
            var refreshSucceeded = false;
            try
            {
                _outputAudio ??= new WebViewAudioVolume(_outputAudioExecutablePath!);
                _outputAudio.SetPreferredOutput(desiredVolume, desiredMute);
                _outputAudio.Refresh(processIds, () => IsCurrentOutputAudioGeneration(generation));
                state = ReadOutputAudioState(_outputAudio);
                refreshSucceeded = true;
            }
            catch (Exception)
            {
                state = OutputAudioState.Unavailable;
            }

            PendingOutputVolume? volume = null;
            PendingOutputMute? mute = null;
            var hasOwnedSession = refreshSucceeded && _outputAudio?.HasVerifiedOwnedSessions == true;
            lock (_outputAudioGate)
            {
                if (_outputAudioClosed) continue;
                if (_outputAudioGeneration != generation) continue;

                var now = DateTime.UtcNow;
                if (_pendingOutputVolume is { } pendingVolume)
                {
                    _pendingOutputVolume = null;
                    if (pendingVolume.ExpiresAt > now)
                        volume = pendingVolume;
                }
                if (_pendingOutputMute is { } pendingMute)
                {
                    _pendingOutputMute = null;
                    if (pendingMute.ExpiresAt > now)
                        mute = pendingMute;
                }
                if (hasOwnedSession && CanAttemptOutputPreferenceRevision(
                    preferenceRevision,
                    _lastAppliedOutputPreferenceRevision,
                    _outputPreferenceAttemptRevision,
                    _outputPreferenceAttemptCount,
                    MaximumOutputPreferenceAttempts))
                {
                    if (_outputPreferenceAttemptRevision != preferenceRevision)
                    {
                        _outputPreferenceAttemptRevision = preferenceRevision;
                        _outputPreferenceAttemptCount = 0;
                    }
                    _outputPreferenceAttemptCount++;
                    volume ??= new PendingOutputVolume(desiredVolume, now + OutputAudioCommandLifetime);
                    if (desiredMute is { } requestedMute)
                        mute ??= new PendingOutputMute(requestedMute, now + OutputAudioCommandLifetime);
                }
            }

            var volumeFailed = false;
            var muteFailed = false;
            if ((volume is not null || mute is not null) && hasOwnedSession)
            {
                // The requested preference is retained when no session exists; only a complete,
                // verified WebView-owned inventory may receive a write.
                if (!IsCurrentOutputAudioGeneration(generation))
                {
                    RestorePendingOutputCommands(volume, mute);
                    continue;
                }

                if (volume is not null)
                {
                    try { volumeFailed = !_outputAudio!.TrySetVolume(
                        volume.Value, () => IsCurrentOutputAudioGeneration(generation)); }
                    catch (Exception) { volumeFailed = true; }
                    state = ReadOutputAudioStateSafely();
                }

                if (mute is not null)
                {
                    if (!IsCurrentOutputAudioGeneration(generation))
                    {
                        RestorePendingOutputCommands(null, mute);
                        continue;
                    }
                    if (_outputAudio?.HasVerifiedOwnedSessions != true)
                    {
                        muteFailed = true;
                    }
                    else
                    {
                        try { muteFailed = !_outputAudio.TrySetMute(
                            mute.Value, () => IsCurrentOutputAudioGeneration(generation)); }
                        catch (Exception) { muteFailed = true; }
                        state = ReadOutputAudioStateSafely();
                    }
                }
            }

            lock (_outputAudioGate)
            {
                if (_outputAudioClosed || _outputAudioGeneration != generation) continue;
                if (hasOwnedSession && (volume is not null || mute is not null)
                    && !volumeFailed && !muteFailed)
                    _lastAppliedOutputPreferenceRevision =
                        Math.Max(_lastAppliedOutputPreferenceRevision, preferenceRevision);
            }
            DeliverOutputAudioResult(generation, state, volumeFailed, muteFailed);
        }
    }

    internal static bool CanAttemptOutputPreferenceRevision(
        long revision,
        long appliedRevision,
        long attemptRevision,
        int attemptCount,
        int maximumAttempts) =>
        revision > appliedRevision
        && maximumAttempts > 0
        && (attemptRevision != revision || attemptCount < maximumAttempts);

    private static OutputAudioState ReadOutputAudioState(WebViewAudioVolume audio)
    {
        var volume = audio.Volume;
        var hasOwnedSessions = audio.HasVerifiedOwnedSessions;
        var available = audio.Available && double.IsFinite(volume) && volume >= 0 && volume <= 1;
        return new OutputAudioState(
            available ? volume : WebViewAudioVolume.DefaultVolume,
            available && audio.Muted,
            available,
            hasOwnedSessions);
    }

    private OutputAudioState ReadOutputAudioStateSafely()
    {
        try
        {
            return _outputAudio is null
                ? OutputAudioState.Unavailable
                : ReadOutputAudioState(_outputAudio);
        }
        catch (Exception)
        {
            return OutputAudioState.Unavailable;
        }
    }

    private bool IsCurrentOutputAudioGeneration(long generation)
    {
        lock (_outputAudioGate)
            return !_outputAudioClosed && _outputAudioGeneration == generation;
    }

    private void RestorePendingOutputCommands(PendingOutputVolume? volume, PendingOutputMute? mute)
    {
        var now = DateTime.UtcNow;
        lock (_outputAudioGate)
        {
            if (_outputAudioClosed) return;
            if (volume is not null && volume.ExpiresAt > now && _pendingOutputVolume is null)
                _pendingOutputVolume = volume;
            if (mute is not null && mute.ExpiresAt > now && _pendingOutputMute is null)
                _pendingOutputMute = mute;
        }
    }

    private void DeliverOutputAudioResult(
        long generation,
        OutputAudioState state,
        bool volumeFailed,
        bool muteFailed)
    {
        var sequence = Interlocked.Increment(ref _outputAudioResultSequence);
        _dispatcherQueue.TryEnqueue(() =>
        {
            lock (_outputAudioGate)
            {
                if (_outputAudioClosed || _outputAudioGeneration != generation
                    || sequence <= _lastAppliedOutputAudioResultSequence)
                    return;
                _lastAppliedOutputAudioResultSequence = sequence;
            }

            _outputAudioState = state;
            _outputAudioStateConfirmedAt = state.Available ? DateTime.UtcNow : default;
            UpdateOutputAudioControls();
            if (volumeFailed)
                SetStatus("WebView audio volume could not be confirmed; check output state before retrying.", isError: true);
            else if (muteFailed)
                SetStatus("WebView audio mute could not be confirmed; check output state before retrying.", isError: true);
        });
    }

    private void ExpireOutputAudioStateIfStale()
    {
        if (!_outputAudioState.Available
            || DateTime.UtcNow - _outputAudioStateConfirmedAt <= OutputAudioStateLifetime)
            return;

        _outputAudioState = OutputAudioState.Unavailable;
        _outputAudioStateConfirmedAt = default;
        UpdateOutputAudioControls();
    }

    private void UpdateOutputAudioControls()
    {
        var audio = _outputAudioState;
        var sessionActive = audio.Available;
        var ready = _outputAudioExecutablePath is not null && _outputAudioPathVerified
            && !_closing && !_disposed && !_outputAudioClosed;
        var value = sessionActive ? audio.Volume : _desiredOutputVolume;
        var unavailableHelp = _outputAudioExecutablePath is null
            ? "WebView audio is not initialized."
            : "WebView audio process identity could not be verified.";
        if (!sessionActive || _pendingOutputDisplayVolume is { } pending
            && (Math.Abs(value - pending) <= 0.0005 || DateTime.UtcNow >= _pendingOutputDisplayUntil))
            _pendingOutputDisplayVolume = null;
        if (sessionActive && _pendingOutputDisplayVolume is { } requested)
            value = requested;
        var muted = sessionActive && DateTime.UtcNow >= _pendingOutputMuteDisplayUntil
            ? audio.Muted : _desiredOutputMute ?? (sessionActive && audio.Muted);
        _updatingOutputAudio = true;
        try
        {
            OutputVolumeSlider.IsEnabled = ready;
            OutputMuteButton.IsEnabled = ready;
            if (!ready)
            {
                OutputVolumeSlider.CancelDrag();
                CloseOutputVolumeFlyout();
            }
            if (!OutputVolumeSlider.Dragging
                && Math.Abs(OutputVolumeSlider.Value - value * 1000d) > 0.05)
                OutputVolumeSlider.Value = Math.Round(value * 1000d);
            OutputVolumeValue.Text = $"{OutputVolumeSlider.Value / 10:0.0}%";
            AutomationProperties.SetName(OutputMuteButton,
                muted ? "Unmute WebView audio" : "Mute WebView audio");
            AutomationProperties.SetHelpText(OutputMuteButton,
                !ready ? unavailableHelp
                    : sessionActive
                        ? $"Click to {(muted ? "unmute" : "mute")} app output. Hover, right-click, or press Down for the volume slider. App output {value:P1}; independent of YouTube Music volume."
                        : audio.HasOwnedSessions
                            ? "Verified WebView audio sessions are present but report inconsistent output states. Explicit volume and mute requests are applied transactionally across those owned sessions."
                            : $"Click to {(muted ? "unmute" : "mute")} WebView output; hover, right-click, or press Down for its slider. {value:P1} is a pending preference until an owned audio session starts.");
            AutomationProperties.SetHelpText(OutputVolumeSlider,
                !ready ? unavailableHelp
                    : sessionActive
                        ? $"WebView audio output {value:P1}; independent of YouTube Music volume. Arrow keys change by 0.1 percent, Page keys by 1 percent."
                        : audio.HasOwnedSessions
                            ? "Verified WebView audio sessions report inconsistent output states. A committed gain request is applied transactionally to every verified owned session; the combined state remains unavailable until consistent."
                            : $"WebView output preference {value:P1}; applies when a verified audio session starts. Arrow keys change by 0.1 percent, Page keys by 1 percent.");
            if (_outputIconMuted != muted)
            {
                OutputMuteButton.Content = _iconCache.CreateElement(muted ? "volume-muted" : "volume", 20);
                _outputIconMuted = muted;
            }
            CompactView.SetOutputVolume(value, muted, ready, audio.HasOwnedSessions);
        }
        finally { _updatingOutputAudio = false; }
    }

    private void DisposeOutputAudio()
    {
        _outputAudioTimer?.Stop();
        _outputAudioTimer = null;
        _outputFlyoutCloseTimer?.Stop();
        _outputFlyoutCloseTimer = null;
        CloseOutputVolumeFlyout();
        _outputAudioState = OutputAudioState.Unavailable;
        _outputAudioStateConfirmedAt = default;
        UpdateOutputAudioControls();

        var startWorker = false;
        lock (_outputAudioGate)
        {
            if (_outputAudioClosed) return;
            _outputAudioClosed = true;
            _outputAudioGeneration++;
            _pendingOutputVolume = null;
            _pendingOutputMute = null;
            _outputAudioRefreshPending = false;
            if (!_outputAudioWorkerRunning)
            {
                _outputAudioWorkerRunning = true;
                startWorker = true;
            }
        }
        if (startWorker) StartOutputAudioWorker();
    }
}
