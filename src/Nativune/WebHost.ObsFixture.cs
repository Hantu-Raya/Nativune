#if NATIVUNE_DISCORD_TEST_HOOKS
using System.Diagnostics;

namespace Nativune;

// OBS overlay E2E seam (notes/research/obs-overlay-2026-09-28/design.md §2.8), compiled only with
// -p:DiscordPresenceTestHooks=true. Command files live in <root>/data/discord-bench beside the Discord
// bench commands and are taken by the same tick (ProcessDiscordBenchCommandsAsync):
//   command-obs-on / -off                      the Settings Save path for the overlay toggle
//   command-obs-hide-paused-on / -off          the Save path for "Hide the overlay when paused"
//   command-obs-hold-read / -release-read      hold the next completed read before delivery / release it
//   command-obs-burst                          one 8 MiB comment queued to the first stream (backpressure)
//   command-clock-mismatch-on / -off           window.__nativuneFixture.setClockMismatch on the fixture page
//   command-navigate                           a real main-frame reload (hard overlay invalidation)
//   command-controls-unavailable-on / -off     PlayerControls.HookForceUnavailable
public sealed partial class WebHostWindow
{
    private TaskCompletionSource? _obsReadHold;

    private async Task ProcessObsBenchCommandsAsync()
    {
        if (TakeDiscordBenchCommand("command-obs-off"))
        {
            _settings = _settings with { ObsOverlay = false };
            await ApplyObsOverlayAsync(false);
        }
        if (TakeDiscordBenchCommand("command-obs-on"))
        {
            _settings = _settings with { ObsOverlay = true };
            await ApplyObsOverlayAsync(true);
        }
        if (TakeDiscordBenchCommand("command-obs-hide-paused-off"))
        {
            _settings = _settings with { ObsHidePaused = false };
            ApplyObsHidePaused(false);
        }
        if (TakeDiscordBenchCommand("command-obs-hide-paused-on"))
        {
            _settings = _settings with { ObsHidePaused = true };
            ApplyObsHidePaused(true);
        }
        if (TakeDiscordBenchCommand("command-obs-hold-read"))
            _obsReadHold ??= new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (TakeDiscordBenchCommand("command-obs-release-read"))
        {
            _obsReadHold?.TrySetResult();
            _obsReadHold = null;
        }
        if (TakeDiscordBenchCommand("command-obs-burst")) _obsOverlay?.HookBurst();
        if (TakeDiscordBenchCommand("command-controls-unavailable-on")) PlayerControls.HookForceUnavailable = true;
        if (TakeDiscordBenchCommand("command-controls-unavailable-off")) PlayerControls.HookForceUnavailable = false;
        if (TakeDiscordBenchCommand("command-clock-mismatch-on") && _browserHost is { } on)
            await on.Core.ExecuteScriptAsync("window.__nativuneFixture.setClockMismatch(true)");
        if (TakeDiscordBenchCommand("command-clock-mismatch-off") && _browserHost is { } off)
            await off.Core.ExecuteScriptAsync("window.__nativuneFixture.setClockMismatch(false)");
        if (TakeDiscordBenchCommand("command-navigate") && _browserHost is { } nav && !_closing && !_disposed)
            nav.Core.Reload();
    }

    private DiscordBenchRawJson ObsBenchStateJson()
    {
        var server = _obsOverlay;
        var hook = server?.HookState();
        var timer = _playbackReadTimer;
        return new DiscordBenchRawJson(DiscordBenchJson(
            ("enabled", _settings.ObsOverlay), ("running", server?.IsRunning ?? false),
            ("bindResult", _obsStartResult?.ToString()), ("streams", server?.OpenStreams ?? 0),
            ("generation", _overlayGeneration), ("demand", CurrentReaderDemand.ToString()),
            ("timerRunning", timer?.IsRunning ?? false),
            ("intervalMs", timer is null ? null : (long?)timer.Interval.TotalMilliseconds),
            ("lastStreamEndReason", hook?.LastStreamEndReason),
            ("gapStartQpc", _overlayGapSince >= 0 ? (long?)_overlayGapSinceQpc : null),
            ("noneSent", _overlayNoneSent), ("latestState", hook?.LatestState), ("latestStale", hook?.LatestStale ?? true),
            ("latestPosition", hook?.LatestPosition), ("latestDuration", hook?.LatestDuration),
            ("fixtureArtServed", hook?.FixtureArtServed ?? 0), ("pendingWrite", hook?.PendingWrite ?? false),
            ("hidePaused", hook?.HidePaused ?? _settings.ObsHidePaused)));
    }

    // Hook builds record the guide URI instead of launching it, but only in bench runs; otherwise the
    // real launcher runs even here.
    partial void ObsRecordLaunchedUri(Uri uri, ref bool recorded)
    {
        if (_discordBenchDirectory is null) return;
        DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(_discordBenchDirectory, "launched-uri.json"),
            DiscordBenchJson(("uri", uri.AbsoluteUri), ("qpc", Stopwatch.GetTimestamp()),
                ("utc", DateTime.UtcNow.ToString("o"))));
        recorded = true;
    }
}
#endif
