using Microsoft.Web.WebView2.Core;
using System.Text.Json;

namespace Nativune;

public sealed partial class WebHostWindow
{
    private static readonly TimeSpan ResumeCallDeadline = TimeSpan.FromSeconds(2);
    private ResumeCheckpointStore? _resumeStore;
    private ResumeCheckpointStore ResumeStore => _resumeStore ??= new(_root);
    private ResumeCheckpoint? _startupCheckpoint;
    private string? _resumeRegistration, _resumeOwnedUri, _resumeStartupMessage;
    private int? _resumeContext;
    private CoreWebView2DevToolsProtocolEventReceiver? _resumeWorldReceiver;
    private string? _resumeFrameId;
    private Task<string>? _resumeRegistrationAdd, _resumeRegistrationRemoval;
    private bool _resumeSetupFailed;
    private bool _resumeOtherDocumentConfirmed;
    private double? _resumeInitialPosition;
    private int _resumeGeneration;
    private string _resumeState = "Absent";
    private bool _resumeSafetyMuted, _resumePriorMute, _resumePolling, _resumeOwnedNavigation;
    private bool _resumeCaptureBlocked, _resumeHomeGuard;
    private CompactPlaybackState? _resumeCandidate, _resumeLastSaved;
    private long _resumeCandidateAt, _resumeSavedAt;
    private long _resumeDeadlineAt;
    private Task _resumeWriteTask = Task.CompletedTask;
    private bool _resumeShutdownStarted;
    private string? _resumeCompletedSeekSignature;
    private double _resumeCompletedSeekTarget;
    private long _resumeCompletedSeekAt;
    private bool ResumeInProgress => (_startupCheckpoint is not null || _resumeHomeGuard)
        && _resumeState is not ("Done" or "Cancelled" or "Absent");
    // Polling also continues while a restore or its safety mute is still active after the destination changed.
    private bool ResumeReadActive => (_settings.StartupDestination == StartupDestination.Continue || ResumeInProgress || _resumeSafetyMuted)
        && !_closing && !_disposed && !_playerSuspended;

    private async Task<string> PrepareResumeStartupAsync(CoreWebView2 core, string fallback)
    {
        if (_settings.StartupDestination != StartupDestination.Continue)
        {
            // Cleanup only; a locked or read-only checkpoint must never stop Home or Library from loading.
            try { await ResumeStore.DeleteAsync(_lifetime.Token); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { AppLog.Write("resume", "delete-failed"); }
            return fallback;
        }
        _startupCheckpoint = ResumeStore.Load(out var invalid);
        if (invalid)
        {
            _resumeCaptureBlocked = true; // do not replace a corrupt saved song with unrelated startup content
            _resumeStartupMessage = "Saved song could not be restored.";
        }
        var checkpoint = _startupCheckpoint;
        if (checkpoint is null && !invalid) return fallback;
        _resumeHomeGuard = invalid;
        var generation = ++_resumeGeneration;
        _resumeState = "Armed";
        _resumeOwnedUri = checkpoint?.StartupUri ?? "https://music.youtube.com/";
        var waitPaused = invalid || checkpoint?.MustPause == true || _settings.ResumeLaunch == ResumeLaunch.WaitPaused;
        _resumeDeadlineAt = long.MaxValue; // armed when the script first reports or the document completes
        if (waitPaused)
        {
            _resumePriorMute = core.IsMuted;
            core.IsMuted = true;
            _resumeSafetyMuted = true;
        }
        using var stream = typeof(WebHostWindow).Assembly.GetManifestResourceStream("Nativune.ResumeStartup.js")
            ?? throw new InvalidOperationException("Resume startup resource missing.");
        using var reader = new StreamReader(stream);
        var script = "const request = " + JsonSerializer.Serialize(new {
            generation, waitPaused, homeGuard = invalid,
            checkpoint = new { videoId = checkpoint?.VideoId ?? "",
                positionSeconds = checkpoint?.PositionSeconds ?? 0, durationSeconds = checkpoint?.DurationSeconds ?? 0 }
        }) + ";\n" + await reader.ReadToEndAsync(_lifetime.Token);
        try
        {
            await core.CallDevToolsProtocolMethodAsync("Page.enable", "{}").AsTask().WaitAsync(ResumeCallDeadline, _lifetime.Token);
            var frameJson = await core.CallDevToolsProtocolMethodAsync("Page.getFrameTree", "{}").AsTask().WaitAsync(ResumeCallDeadline, _lifetime.Token);
            using (var frameTree = JsonDocument.Parse(frameJson))
                _resumeFrameId = frameTree.RootElement.GetProperty("frameTree").GetProperty("frame").GetProperty("id").GetString();
            _resumeWorldReceiver = core.GetDevToolsProtocolEventReceiver("Runtime.executionContextCreated");
            _resumeWorldReceiver.DevToolsProtocolEventReceived += OnResumeWorldCreated;
            await core.CallDevToolsProtocolMethodAsync("Runtime.enable", "{}").AsTask().WaitAsync(ResumeCallDeadline, _lifetime.Token);
            _resumeRegistrationAdd = core.CallDevToolsProtocolMethodAsync("Page.addScriptToEvaluateOnNewDocument",
                JsonSerializer.Serialize(new { source = script, worldName = "nativune-resume" })).AsTask();
            var json = await _resumeRegistrationAdd.WaitAsync(ResumeCallDeadline, _lifetime.Token);
            using var registration = JsonDocument.Parse(json);
            _resumeRegistration = registration.RootElement.GetProperty("identifier").GetString();
            if (string.IsNullOrEmpty(_resumeRegistration)) throw new InvalidDataException("resume-registration");
            if (_settings.StartupDestination != StartupDestination.Continue)
            {
                // Home or Library was saved while setup awaited: retire this restore before navigating. If the
                // registration cannot be removed, its script still ignores any page but the saved song's.
                if (!await RemoveResumeRegistrationAsync()) AppLog.Write("resume", "late-cancel-remove-failed");
                RestoreResumeMute();
                ++_resumeGeneration;
                _resumeState = "Cancelled";
                _startupCheckpoint = null;
                _resumeHomeGuard = false;
                _resumeCaptureBlocked = false;
                _resumeStartupMessage = null;
                _resumeOwnedUri = _settings.StartupUri;
                _resumeOwnedNavigation = true;
                return _resumeOwnedUri;
            }
            _resumeOwnedNavigation = true;
            return _resumeOwnedUri;
        }
        catch (Exception) when (!_lifetime.IsCancellationRequested)
        {
            _resumeSetupFailed = true;
            _resumeOwnedUri = "https://music.youtube.com/";
            _resumeOwnedNavigation = true;
            _resumeState = "Failed";
            _resumeCaptureBlocked = true;
            _resumeStartupMessage = "Saved song could not be restored.";
            return "https://music.youtube.com/";
        }
    }

    private void OnResumeWorldCreated(object? sender, CoreWebView2DevToolsProtocolEventReceivedEventArgs args)
    {
        try
        {
            using var json = JsonDocument.Parse(args.ParameterObjectAsJson);
            var context = json.RootElement.GetProperty("context");
            if (context.GetProperty("name").GetString() == "nativune-resume"
                && context.TryGetProperty("auxData", out var aux)
                && aux.GetProperty("frameId").GetString() == _resumeFrameId)
                _resumeContext = context.GetProperty("id").GetInt32();
        }
        catch (Exception) { }
    }

    private bool ObserveResumeNavigation(CoreWebView2NavigationStartingEventArgs args)
    {
        if (_resumeOwnedNavigation && args.Uri == _resumeOwnedUri) { _resumeOwnedNavigation = false; return true; }
        if (args.IsRedirected) return true;
        _resumeCandidate = null;
        if (!ResumeInProgress && !_resumeSafetyMuted)
        {
            // A finished restore never holds navigation; a leftover registration is removed in the background
            // (its script only acts on the saved song's page).
            if (_resumeRegistration is not null || _resumeRegistrationAdd is not null) _ = RemoveResumeRegistrationAsync();
            return true;
        }
        if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) || !WebHostPolicy.IsAllowedMainFrameNavigation(uri))
        {
            _ = CancelResumeAsync("navigation");
            return true; // Preserve the existing blocked-origin validation and truthful status path.
        }
        var target = args.Uri;
        _ = NavigateAfterResumeAsync(() => _browserHost?.Core.Navigate(target));
        return false;
    }

    private async Task NavigateAfterResumeAsync(Action navigate)
    {
        if (await CancelResumeAsync("navigation") && CanNavigate) navigate();
    }

    private void ObserveResumeSource()
    {
        if (!ResumeInProgress || _browserHost is not { } host
            || !Uri.TryCreate(host.Core.Source, UriKind.Absolute, out var uri) || !IsEqualizerMusicOrigin(uri.ToString())) return;
        var values = uri.Query.TrimStart('?').Split('&').Where(p => p.StartsWith("v=", StringComparison.Ordinal)).ToArray();
        var same = _resumeHomeGuard ? uri.AbsolutePath == "/"
            : uri.AbsolutePath == "/watch" && values.Length == 1
                && Uri.UnescapeDataString(values[0][2..]) == _startupCheckpoint?.VideoId;
        if (!same) _ = CancelResumeAsync("navigation");
    }

    // A slow first load must not fail the restore: the deadline starts at document completion at the latest.
    private void ArmResumeDeadline()
    {
        if (_resumeState == "Armed" && _resumeDeadlineAt == long.MaxValue) _resumeDeadlineAt = Environment.TickCount64 + 10000;
    }

    private async Task FinalizeResumeOtherDocumentAsync()
    {
        if (_browserHost is not { } host || IsEqualizerMusicOrigin(host.Core.Source) || !ResumeInProgress) return;
        // NavigationCompleted confirms the old exact-origin controller cannot act in this new document.
        _resumeOtherDocumentConfirmed = true;
        if (await CancelResumeAsync("navigation")) SetStatus("Saved song could not be restored.", isError: true);
    }

    // A failed navigation or an exited renderer leaves no controller to acknowledge cancellation, so retire
    // the restore directly; Retry, Home and the crash reload then navigate normally. The caller owns the status.
    private async Task RetireResumeDocumentAsync()
    {
        if (!ResumeInProgress && !_resumeSafetyMuted) return;
        _resumeOtherDocumentConfirmed = true;
        await CancelResumeAsync("navigation");
    }

    private async Task<JsonElement?> EvaluateResumeAsync(string expression)
    {
        var core = _browserHost?.Core;
        if (core is null || !IsEqualizerMusicOrigin(core.Source)) return null;
        var generation = _resumeGeneration;
        if (_resumeContext is null) return null;
        var json = await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new {
            expression, contextId = _resumeContext, returnByValue = true, timeout = 1000
        })).AsTask().WaitAsync(ResumeCallDeadline);
        if (generation != _resumeGeneration) return null;
        using var result = JsonDocument.Parse(json);
        return result.RootElement.GetProperty("result").TryGetProperty("value", out var value) ? value.Clone() : null;
    }

    private async Task PollResumeAsync()
    {
        if (_resumePolling || !ResumeInProgress || _browserHost is null || _configuringPrivacy) return;
        _resumePolling = true;
        var generation = _resumeGeneration;
        try
        {
            var result = await EvaluateResumeAsync("globalThis.__nativuneResume?.status()");
            if (generation != _resumeGeneration) return;
            if (result is not { ValueKind: JsonValueKind.Object } status
                || status.GetProperty("generation").GetInt32() != generation)
            {
                if (Environment.TickCount64 >= _resumeDeadlineAt) FailResume("timeout");
                return;
            }
            var state = status.GetProperty("state").GetString();
            if (state is not ("Armed" or "AwaitMedia" or "Pause/Seek" or "Verify" or "Done" or "AdPaused" or "AwaitMusic" or "Failed" or "Cancelled")) return;
            if (status.TryGetProperty("initialPosition", out var initial) && initial.ValueKind == JsonValueKind.Number
                && initial.TryGetDouble(out var first) && double.IsFinite(first)
                && first is >= 0 and <= ResumeCheckpoint.MaximumSeconds)
                _resumeInitialPosition = first;
            var changed = state != _resumeState;
            if (changed && _resumeState is "AdPaused" or "AwaitMusic" && state is not ("AdPaused" or "AwaitMusic"))
                _resumeDeadlineAt = Environment.TickCount64 + 10000;
            // The script's own 10 s starts in the new document; page load time before it does not count.
            if (changed && _resumeState == "Armed") _resumeDeadlineAt = Environment.TickCount64 + 10000;
            // A never-shown or hidden window (tray autostart, minimized) has no media yet, so its time does not
            // count. Visible Compact hides only the WebView: the host enforces the deadline the script suspends.
            if (status.TryGetProperty("hidden", out var hidden) && hidden.ValueKind == JsonValueKind.True && !WindowIsVisible)
                _resumeDeadlineAt = Environment.TickCount64 + 10000;
            if (state is "Armed" or "AwaitMedia" or "Pause/Seek" or "Verify" && Environment.TickCount64 >= _resumeDeadlineAt)
            {
                await EvaluateResumeAsync("globalThis.__nativuneResume?.fail()");
                if (generation == _resumeGeneration) FailResume("timeout");
                return;
            }
            _resumeState = state;
            if (state is "Done" or "Cancelled")
            {
                // The controller is terminal and has dropped its recovery handlers, so release the guard now;
                // a registration that could not be removed is retried by the next navigation.
                var removed = await RemoveResumeRegistrationAsync();
                RestoreResumeMute();
                if (!removed) AppLog.Write("resume", "cleanup-failed");
                if (state == "Cancelled")
                {
                    ++_resumeGeneration;
                    _resumeCaptureBlocked = false;
                    _resumeStartupMessage = null;
                    _resumeCandidate = null;
                }
                else if (!_resumeHomeGuard) _resumeCaptureBlocked = false;
                if (_resumeHomeGuard)
                {
                    // The guarded Home load is over: drop the unreadable file so it cannot fail every launch,
                    // then follow the user's own listening again (Home has no song to capture).
                    _resumeHomeGuard = false;
                    try { await ResumeStore.DeleteAsync(_lifetime.Token); }
                    catch (Exception ex) when (ex is IOException or UnauthorizedAccessException) { AppLog.Write("resume", "delete-failed"); }
                    _resumeCaptureBlocked = false;
                }
                if (state == "Done")
                {
                    SetStatus(_resumeStartupMessage ?? (status.GetProperty("reason").GetString() == "paused"
                        ? "Saved song is paused. Press Play to start." : "Continued where you left off."),
                        isError: _resumeStartupMessage is not null);
                    _resumeStartupMessage = null; // shown once; later navigations report normally
                }
            }
            else if (state == "AdPaused" && changed)
                SetStatus("Ad paused. Press Play; your song position will resume after the ad.");
            else if (state == "Failed" && changed)
            {
                FailResume(status.GetProperty("reason").GetString());
                await RemoveResumeRegistrationAsync();
            }
        }
        catch (Exception)
        {
            if (generation == _resumeGeneration && Environment.TickCount64 >= _resumeDeadlineAt
                && _resumeState is not ("AdPaused" or "AwaitMusic")) FailResume("timeout");
        }
        finally { _resumePolling = false; }
    }

    private void FailResume(string? reason)
    {
        _resumeState = "Failed";
        _resumeCaptureBlocked = true;
        SetStatus(_resumeStartupMessage ?? (reason switch {
            "track" => "Saved track could not resume",
            "position" => "Saved track did not start at the saved position.",
            _ => _resumeSafetyMuted ? "Resume failed. Playback is muted; press Play to cancel restoration."
                : "Saved song did not start. Press Play to continue."
        }), isError: true);
        _ = RemoveResumeRegistrationAsync();
    }

    private async Task<bool> CancelResumeAsync(string reason)
    {
        if (!ResumeInProgress && !_resumeSafetyMuted)
        {
            if (!await RemoveResumeRegistrationAsync()) AppLog.Write("resume", "cleanup-failed");
            _resumeCaptureBlocked = false;
            _resumeStartupMessage = null;
            return true;
        }
        var generation = _resumeGeneration;
        var adRecovery = false;
        // After a setup failure the fallback Home has no controller even if a late registration created the
        // named world (the script returns early there), so retire without waiting for a receipt.
        if ((_resumeSetupFailed && _playerControls?.IsAvailable == true) || _resumeOtherDocumentConfirmed)
        {
            if (!await RemoveResumeRegistrationAsync()) AppLog.Write("resume", "cleanup-failed");
            ++_resumeGeneration;
            _resumeState = "Cancelled";
            RestoreResumeMute();
            _resumeCaptureBlocked = false;
            _resumeStartupMessage = null;
            return true;
        }
        try
        {
            var result = await EvaluateResumeAsync(reason == "play"
                ? "globalThis.__nativuneResume?.recover()" : "globalThis.__nativuneResume?.cancel()");
            if (generation != _resumeGeneration) return !ResumeInProgress;
            if (result is not { ValueKind: JsonValueKind.Object } receipt
                || receipt.GetProperty("generation").GetInt32() != generation
                || !(receipt.TryGetProperty("cancelled", out var cancelled) && cancelled.GetBoolean())
                    && !(receipt.TryGetProperty("adRecovery", out var ad) && ad.GetBoolean()))
            {
                FailResume("timeout");
                return false;
            }
            adRecovery = receipt.TryGetProperty("adRecovery", out var recovery) && recovery.GetBoolean();
        }
        catch (Exception) { FailResume("timeout"); return false; }
        if (adRecovery)
        {
            RestoreResumeMute();
            _resumeState = "AwaitMusic";
            return true;
        }
        // The controller has cancelled itself; a failed registration removal must not keep the view muted.
        if (!await RemoveResumeRegistrationAsync()) AppLog.Write("resume", "cleanup-failed");
        RestoreResumeMute();
        _resumeCaptureBlocked = false;
        _resumeCandidate = null;
        _resumeStartupMessage = null;
        ++_resumeGeneration;
        _resumeState = "Cancelled";
        return true;
    }

    private void RestoreResumeMute()
    {
        if (!_resumeSafetyMuted) return;
        if (_browserHost is { } host) host.Core.IsMuted = _resumePriorMute;
        _resumeSafetyMuted = false;
    }

    private async Task<bool> RemoveResumeRegistrationAsync()
    {
        // A rejected or empty registration never existed; only a pending or ambiguous one must be confirmed.
        if (_resumeRegistration is { Length: 0 }) _resumeRegistration = null;
        if (_resumeRegistration is null && _resumeRegistrationAdd is { IsFaulted: true } or { IsCanceled: true })
            _resumeRegistrationAdd = null;
        if (_browserHost is not { } host) return _resumeRegistration is null && _resumeRegistrationAdd is null;
        try
        {
            if (_resumeRegistration is null && _resumeRegistrationAdd is { } add)
            {
                using var result = JsonDocument.Parse(await add.WaitAsync(ResumeCallDeadline));
                _resumeRegistration = result.RootElement.GetProperty("identifier").GetString();
                if (string.IsNullOrEmpty(_resumeRegistration)) { _resumeRegistration = null; _resumeRegistrationAdd = null; }
            }
            if (_resumeRegistration is { } registration)
            {
                if (_resumeRegistrationRemoval?.IsFaulted == true) _resumeRegistrationRemoval = null;
                _resumeRegistrationRemoval ??= host.Core.CallDevToolsProtocolMethodAsync("Page.removeScriptToEvaluateOnNewDocument",
                    JsonSerializer.Serialize(new { identifier = registration })).AsTask();
                await _resumeRegistrationRemoval.WaitAsync(ResumeCallDeadline);
            }
            _resumeRegistration = null;
            _resumeRegistrationAdd = null;
            _resumeRegistrationRemoval = null;
            return true;
        }
        catch (Exception) { AppLog.Write("resume", "remove-failed"); return false; }
    }

    // Position is the authoritative per-track clock (signed-in playback can put several items on one
    // media timeline). Media time adds sub-second precision only when it agrees with that track clock.
    private static double ResumePosition(CompactPlaybackState state)
        => state.MediaPosition is { } media && state.MediaDuration is { } duration
            && Math.Abs(duration - state.Duration) <= 2 && Math.Abs(media - state.Position) <= 1.5
            ? media : state.Position;

    private void ObserveResumeSnapshot(CompactPlaybackState? state, int generation, long capturedAt, bool final = false)
    {
        if (generation != _resumeGeneration || _settings.StartupDestination != StartupDestination.Continue
            || ResumeInProgress || _resumeCaptureBlocked) return;
        if (state is null || state.IsAd || state.Seeking || !state.ClockConfirmed || state.ClockMismatch
            || !ResumeCheckpoint.ValidId(state.VideoId) || state.MediaDuration is not > 0)
        { _resumeCandidate = null; return; }
        var position = ResumePosition(state);
        if (!double.IsFinite(position) || position < 0 || position > state.Duration)
        { _resumeCandidate = null; return; }
        if (state.TrackLinkPresent && state.TrackUrl != "https://music.youtube.com/watch?v=" + state.VideoId)
        { _resumeCandidate = null; return; }
        var prior = _resumeCandidate;
        var elapsed = (capturedAt - _resumeCandidateAt) / 1000d;
        var completedSeek = state.TrackLinkPresent && _resumeCompletedSeekSignature is not null
            && CompactPlayback.ComputeSignature(state) == _resumeCompletedSeekSignature
            && capturedAt >= _resumeCompletedSeekAt && capturedAt - _resumeCompletedSeekAt <= 2500
            && Math.Abs(position - _resumeCompletedSeekTarget) <= 1;
        var same = prior is not null && prior.VideoId == state.VideoId && prior.Title == state.Title
            && prior.Artist == state.Artist && Math.Abs(prior.Duration - state.Duration) <= 1
            && Math.Abs(position - ResumePosition(prior)
                - (prior.Paused ? 0 : elapsed * (prior.PlaybackRate ?? 1))) <= 1.5;
        var minimum = state.TrackLinkPresent ? 1d : 2d;
        // At shutdown a strongly identified sample of the item already being followed is saved even right
        // after a website seek; a just-switched item (different prior id) still needs a second sample.
        var finalStrong = final && state.TrackLinkPresent && prior?.VideoId == state.VideoId;
        if (!same && !completedSeek && !finalStrong || !state.TrackLinkPresent && string.IsNullOrWhiteSpace(state.Artist))
        { _resumeCandidate = state; _resumeCandidateAt = capturedAt; return; }
        if (!completedSeek && !finalStrong && elapsed < minimum) return;
        var old = _resumeLastSaved;
        var changed = old?.VideoId != state.VideoId;
        var paused = state.Paused && (old?.Paused != true || Math.Abs(ResumePosition(old) - position) > 0.1);
        var seek = old is not null && old.VideoId == state.VideoId
            && Math.Abs(position - ResumePosition(old)
                - (old.Paused ? 0 : (capturedAt - _resumeSavedAt) / 1000d * (old.PlaybackRate ?? 1))) > 2;
        if (!final && !completedSeek && !changed && !paused && !seek && (state.Paused || capturedAt - _resumeSavedAt < 5000)) return;
        var checkpoint = new ResumeCheckpoint(1, state.VideoId!, ResumeCheckpoint.SafeList(state.ListId),
            position, state.Duration, state.Ended);
        if (!checkpoint.Valid) return;
        _resumeCompletedSeekSignature = null;
        _resumeLastSaved = state;
        _resumeSavedAt = capturedAt;
        _resumeWriteTask = SaveResumeAsync(checkpoint, _resumeWriteTask);
        _resumeCandidate = state;
        _resumeCandidateAt = capturedAt;
    }

    private async Task SaveResumeAsync(ResumeCheckpoint checkpoint, Task previous)
    {
        try
        {
            await previous;
            if (_settings.StartupDestination != StartupDestination.Continue || ResumeInProgress) return;
            await ResumeStore.SaveAsync(checkpoint, _saveCancellation.Token);
        }
        catch (Exception) { AppLog.Write("resume", "save-failed"); }
    }

    private async Task CaptureFinalResumeAsync()
    {
        if (!ResumeReadActive || ResumeInProgress || _playerControls?.IsAvailable != true) return;
        try
        {
            var generation = _resumeGeneration;
            var deadline = Environment.TickCount64 + 2000;
            while ((_playbackReadPending || _playerBusy) && Environment.TickCount64 < deadline)
                await Task.Delay(25);
            if (_playbackReadPending || _playerBusy) throw new TimeoutException();
            // Closing invalidates PlayerControls' host-ready gate, so take this fresh bounded sample first.
            var read = await _playerControls.ReadPlaybackStateAsync(ReadReason.Resume)
                .WaitAsync(TimeSpan.FromMilliseconds(Math.Max(1, deadline - Environment.TickCount64)));
            if (read.Sampled) ObserveResumeSnapshot(read.State, generation, Environment.TickCount64, final: true);
            await _resumeWriteTask.WaitAsync(ResumeCallDeadline);
        }
        catch (Exception) { AppLog.Write("resume", "final-read-failed"); }
    }

    private async Task<string?> ApplyResumePreferencesAsync()
    {
        string? error = null;
        if (_settings.StartupDestination != StartupDestination.Continue)
        {
            var cancelled = await CancelResumeAsync("setting");
            await _resumeWriteTask;
            try { await ResumeStore.DeleteAsync(_lifetime.Token); }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                error = "Startup choice saved, but saved song data could not be removed.";
                AppLog.Write("resume", "delete-failed");
            }
            if (!cancelled) error = "Resume failed. Playback is muted; press Play to cancel restoration.";
        }
        else if (_resumeState == "Failed" && _resumeSafetyMuted)
            error = "Resume failed. Playback is muted; press Play to cancel restoration.";
        RefreshSharedReader();
        return error;
    }
}
