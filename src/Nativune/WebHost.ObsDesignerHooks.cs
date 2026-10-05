#if NATIVUNE_DISCORD_TEST_HOOKS
using Microsoft.Web.WebView2.Core;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Nativune;

// File commands are accepted only in the disposable bench profile, never from a web page.
public sealed partial class WebHostWindow
{
    private static readonly TimeSpan ObsDesignerBenchCommandTimeout = TimeSpan.FromSeconds(10);
    private readonly Queue<object> _obsDesignerBenchCommandHistory = new();
    private long _obsDesignerBenchCommandId;
    private object? _obsDesignerBenchLastCommand;
    private long _obsDesignerCalibrationRevision;
    private OverlayDesignerWindow? _obsDesignerCalibrationWindow;

    private Task ProcessObsDesignerBenchCommandsAsync()
    {
        if (_discordBenchDirectory is not { } directory) return Task.CompletedTask;

        var forcedFailure = TakeObsCommandPayload("command-obs-font-enumeration-fail");
        if (forcedFailure is not null)
            RunObsDesignerBenchCommand("command-obs-font-enumeration-fail",
                () => SystemFonts.HookForceEnumerationFailure = forcedFailure.Trim() == "on");

        if (TakeDiscordBenchCommand("command-obs-fonts-dump"))
            RunObsDesignerBenchCommand("command-obs-fonts-dump", () =>
            {
                var result = SystemFonts.Enumerate();
                var body = JsonSerializer.Serialize(new
                {
                    families = result.Families.Select(f => new
                    {
                        canonical = f.Canonical, display = f.Display, aliases = f.Aliases
                    }),
                    truncated = result.Truncated,
                    error = result.Failed ? "Could not enumerate installed fonts" : null
                });
                DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(directory, "fonts.json"), body);
            });

        if (TakeDiscordBenchCommand("command-obs-designer-open"))
            StartObsDesignerBenchCommand("command-obs-designer-open", () => OpenOverlayDesignerAsync(ObsButton));
        if (TakeDiscordBenchCommand("command-obs-designer-close"))
            StartObsDesignerBenchCommand("command-obs-designer-close",
                () => _overlayDesignerWindow?.RequestCloseAsync() ?? Task.CompletedTask);
        if (TakeDiscordBenchCommand("command-lyrics-open"))
            StartObsDesignerBenchCommand("command-lyrics-open", OpenLyricsSettingsAsync);
        if (TakeDiscordBenchCommand("command-lyrics-close"))
            RunObsDesignerBenchCommand("command-lyrics-close", CloseLyricsSettingsWindow);
        var navigation = TakeObsCommandPayload("command-obs-designer-navigate");
        if (navigation is not null)
            RunObsDesignerBenchCommand("command-obs-designer-navigate",
                () => _overlayDesignerWindow?.NavigateForHook(navigation.Trim()));
        var securityProbe = TakeObsCommandPayload("command-obs-designer-security-probe");
        if (securityProbe is not null)
            StartObsDesignerBenchCommand("command-obs-designer-security-probe",
                () => RunObsDesignerSecurityProbeAsync(directory, securityProbe.Trim()));
        if (TakeDiscordBenchCommand("command-obs-designer-process-failed"))
            StartObsDesignerBenchCommand("command-obs-designer-process-failed", async () =>
            {
                if (_overlayDesignerWindow?.Core is { } previewCore)
                    await previewCore.CallDevToolsProtocolMethodAsync("Page.crash", "{}");
                else
                    throw new InvalidOperationException("Preview unavailable");
            });

        var calibrationLoad = TakeObsCommandPayload("command-obs-designer-calibration-load");
        if (calibrationLoad is not null)
            StartObsDesignerBenchCommand("command-obs-designer-calibration-load",
                () => RunObsDesignerCalibrationLoadAsync(directory, calibrationLoad));

        if (TakeDiscordBenchCommand("command-obs-preview-fonts-dump"))
            StartObsDesignerBenchCommand("command-obs-preview-fonts-dump", async () =>
            {
                var result = "{\"fonts\":[]}";
                try
                {
                    if (_overlayDesignerWindow?.Core is { } core)
                    {
                        await core.CallDevToolsProtocolMethodAsync("DOM.enable", "{}");
                        await core.CallDevToolsProtocolMethodAsync("CSS.enable", "{}");
                        var document = await core.CallDevToolsProtocolMethodAsync("DOM.getDocument", "{\"depth\":1}");
                        var rootNode = JsonDocument.Parse(document).RootElement.GetProperty("root").GetProperty("nodeId").GetInt32();
                        var query = await core.CallDevToolsProtocolMethodAsync("DOM.querySelector",
                            JsonSerializer.Serialize(new { nodeId = rootNode, selector = "#title" }));
                        var titleNode = JsonDocument.Parse(query).RootElement.GetProperty("nodeId").GetInt32();
                        if (titleNode != 0)
                        {
                            result = await core.CallDevToolsProtocolMethodAsync("CSS.getPlatformFontsForNode",
                                JsonSerializer.Serialize(new { nodeId = titleNode }));
                            var dump = JsonNode.Parse(result)!.AsObject();
                            dump["titleFontFamily"] = JsonNode.Parse(await core.ExecuteScriptAsync(
                                "getComputedStyle(document.getElementById('title')).fontFamily"));
                            result = dump.ToJsonString();
                        }
                    }
                }
                catch (Exception ex)
                {
                    result = JsonSerializer.Serialize(new { fonts = Array.Empty<object>(), error = ex.GetType().Name });
                }
                DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(directory, "preview-fonts.json"), result);
            });
        if (TakeDiscordBenchCommand("command-obs-preview-state-dump"))
            StartObsDesignerBenchCommand("command-obs-preview-state-dump", async () =>
            {
                var result = "{\"error\":\"Preview unavailable\"}";
                try
                {
                    if (_overlayDesignerWindow?.Core is { } core)
                        result = await core.ExecuteScriptAsync("window.__state || null");
                }
                catch (Exception ex) { result = JsonSerializer.Serialize(new { error = ex.GetType().Name }); }
                DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(directory, "preview-state.json"), result);
            });

        if (TakeDiscordBenchCommand("command-obs-designer-snapshot"))
            RunObsDesignerBenchCommand("command-obs-designer-snapshot", () =>
            {
                var snapshot = _overlayDesignerWindow?.SnapshotForHook();
                DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(directory, "designer.json"),
                    JsonSerializer.Serialize(new { open = _overlayDesignerWindow is not null, state = snapshot,
                        previewUrl = ObsDesignerPreviewSourceForHook(_overlayDesignerWindow),
                        commands = ObsDesignerBenchCommandState() }));
            });
        return Task.CompletedTask;
    }

    private static string? ObsDesignerPreviewSourceForHook(OverlayDesignerWindow? window)
    {
        try { return window?.Core?.Source; }
        catch (Exception) { return null; } // A dead renderer must not prevent a native snapshot.
    }

    private async Task RunObsDesignerCalibrationLoadAsync(string directory, string payload)
    {
        using var request = JsonDocument.Parse(payload);
        var body = request.RootElement;
        if (body.ValueKind != JsonValueKind.Object)
            throw new ArgumentException("Invalid calibration request");
        var off = body.TryGetProperty("off", out var offValue) && offValue.ValueKind == JsonValueKind.True;
        double cpuPp = 0, memMiB = 0;
        if (!off && (!body.TryGetProperty("cpuPp", out var cpuValue) || !cpuValue.TryGetDouble(out cpuPp)
            || !double.IsFinite(cpuPp) || cpuPp < 0 || cpuPp > 100
            || !body.TryGetProperty("memMiB", out var memValue) || !memValue.TryGetDouble(out memMiB)
            || !double.IsFinite(memMiB) || memMiB < 0 || memMiB > 1024))
            throw new ArgumentException("Invalid calibration load");

        var revision = ++_obsDesignerCalibrationRevision;
        var window = _overlayDesignerWindow;
        if (window?.Core is not { } core)
        {
            if (!off) throw new InvalidOperationException("Preview unavailable");
            WriteObsDesignerCalibrationOff(directory);
            return;
        }
        if (!ReferenceEquals(_obsDesignerCalibrationWindow, window))
        {
            _obsDesignerCalibrationWindow = window;
            window.Closed += (_, _) =>
            {
                if (!ReferenceEquals(_obsDesignerCalibrationWindow, window)) return;
                _obsDesignerCalibrationWindow = null;
                ++_obsDesignerCalibrationRevision;
                // DisposePreview has already disposed the host and its document on close/shutdown.
                try { WriteObsDesignerCalibrationOff(directory); }
                catch (Exception ex) { AppLog.Write("obs", "designer-calibration-off-write-failed " + ex.GetType().Name); }
            };
        }
        // Execute on the designer's own preview target, never on the main player WebView.
        var arguments = off ? "{\"off\":true}" : JsonSerializer.Serialize(new { cpuPp, memMiB });
        var result = await core.ExecuteScriptAsync($"window.__designerCalibrationLoad({arguments})");
        using var acknowledgement = JsonDocument.Parse(result);
        var state = acknowledgement.RootElement;
        var expectedBytes = off ? 0L : (long)Math.Ceiling(memMiB * 1024 * 1024);
        if (state.ValueKind != JsonValueKind.Object || state.GetProperty("active").GetBoolean() != !off
            || state.GetProperty("cpuPp").GetDouble() != cpuPp || state.GetProperty("memMiB").GetDouble() != memMiB
            || state.GetProperty("retainedBytes").GetInt64() != expectedBytes
            || (!off && state.GetProperty("startedAtUtc").ValueKind != JsonValueKind.String))
            throw new InvalidOperationException("Calibration acknowledgement unavailable");
        // Dropping references stops the load; force collection as well so an off arm does not retain its buffers.
        if (off) await core.CallDevToolsProtocolMethodAsync("HeapProfiler.collectGarbage", "{}");
        if (revision != _obsDesignerCalibrationRevision || !ReferenceEquals(_overlayDesignerWindow, window))
            throw new InvalidOperationException("Calibration target changed");
        DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(directory, "designer-calibration-load.json"), result);
    }

    private static void WriteObsDesignerCalibrationOff(string directory) =>
        DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(directory, "designer-calibration-load.json"),
            JsonSerializer.Serialize(new { active = false, cpuPp = 0, memMiB = 0, startedAtUtc = (string?)null, retainedBytes = 0 }));

    private async Task RunObsDesignerSecurityProbeAsync(string directory, string kind)
    {
        var commandId = _obsDesignerBenchCommandId;
        var window = _overlayDesignerWindow;
        var sourceBefore = ObsDesignerPreviewSourceForHook(window);
        JsonNode? snapshotBefore = null, snapshotAfter = null, javascript = null;
        string? error = null;
        var decisionStartIndex = 0;
        Task<string>? pending = null;
        CoreWebView2? observedCore = null;
        var nativeEvents = new List<object>();
        var nativeEvent = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        Windows.Foundation.TypedEventHandler<CoreWebView2, CoreWebView2NewWindowRequestedEventArgs> newWindowObserver = (_, args) =>
        {
            nativeEvents.Add(new { kind = "new-window", uri = args.Uri, handled = args.Handled });
            if (kind == "new-window") nativeEvent.TrySetResult(true);
        };
        Windows.Foundation.TypedEventHandler<CoreWebView2, CoreWebView2DownloadStartingEventArgs> downloadObserver = (_, args) =>
        {
            nativeEvents.Add(new { kind = "download", cancel = args.Cancel });
            if (kind == "download") nativeEvent.TrySetResult(true);
        };
        Windows.Foundation.TypedEventHandler<CoreWebView2, CoreWebView2PermissionRequestedEventArgs> permissionObserver = (_, args) =>
        {
            nativeEvents.Add(new { kind = "permission", permissionKind = args.PermissionKind.ToString(), state = args.State.ToString() });
            if (kind == "permission") nativeEvent.TrySetResult(true);
        };
        try
        {
            if (window?.Core is not { } core) throw new InvalidOperationException("Preview unavailable");
            snapshotBefore = JsonSerializer.SerializeToNode(window.SnapshotForHook());
            decisionStartIndex = (snapshotBefore?["navigation"] as JsonArray)?.Count ?? 0;
            // This file command chooses a fixture, never supplies script or an arbitrary target URL.
            var expression = kind switch
            {
                "new-window" => """
                    (() => {
                      const popup = window.open('http://localhost:47813/?sample=playing', '_blank');
                      const blocked = popup === null;
                      if (popup) popup.close();
                      return { kind: 'new-window', blocked };
                    })()
                    """,
                "download" => """
                    new Promise(resolve => {
                      const url = URL.createObjectURL(new Blob(['Nativune preview security fixture\n'], { type: 'text/plain' }));
                      const link = document.createElement('a');
                      link.href = url;
                      link.download = 'nativune-preview-security-fixture.txt';
                      document.body.append(link);
                      try { link.click(); } finally { link.remove(); }
                      setTimeout(() => {
                        URL.revokeObjectURL(url);
                        resolve({ kind: 'download', clicked: true });
                      }, 250);
                    })
                    """,
                "permission" => """
                    new Promise(resolve => {
                      const timer = setTimeout(() => resolve({ kind: 'permission', rejected: false, timedOut: true }), 2000);
                      // Only rejection is consumed; no coordinates are read or returned if a denial regresses.
                      navigator.geolocation.getCurrentPosition(() => {}, error => {
                        clearTimeout(timer);
                        resolve({ kind: 'permission', rejected: true, errorCode: error.code, errorMessage: error.message });
                      }, { timeout: 1500, maximumAge: 0 });
                    })
                    """,
                _ => throw new ArgumentException("Unknown security probe kind")
            };
            // Observe actual post-handler values as well as RecordDecision: a hardcoded allowed=false
            // log entry alone cannot detect a regression in Handled, Cancel or PermissionState.
            observedCore = core;
            core.NewWindowRequested += newWindowObserver;
            core.DownloadStarting += downloadObserver;
            core.PermissionRequested += permissionObserver;
            async Task<string> EvaluateAsync() => await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate",
                JsonSerializer.Serialize(new { expression, userGesture = true, awaitPromise = true, returnByValue = true }));
            var clock = System.Diagnostics.Stopwatch.StartNew();
            pending = EvaluateAsync();
            // Leave room inside the existing ten-second observer to write failure/native evidence.
            var remaining = TimeSpan.FromSeconds(8) - clock.Elapsed;
            if (remaining <= TimeSpan.Zero) throw new TimeoutException();
            javascript = JsonNode.Parse(await pending.WaitAsync(remaining));
            // A download event can arrive after JS has returned: keep observing within the same budget.
            remaining = TimeSpan.FromSeconds(8) - clock.Elapsed;
            if (remaining <= TimeSpan.Zero) throw new TimeoutException();
            await nativeEvent.Task.WaitAsync(remaining);
        }
        catch (Exception ex)
        {
            error = ex.GetType().Name;
            if (ex is TimeoutException && pending is not null)
                _ = pending.ContinueWith(task =>
                    AppLog.Write("obs", $"designer-hook-security-probe-late-failed {task.Exception!.GetBaseException().GetType().Name}"),
                    CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
                    TaskScheduler.Default);
        }
        finally
        {
            try
            {
                if (observedCore is not null)
                {
                    observedCore.NewWindowRequested -= newWindowObserver;
                    observedCore.DownloadStarting -= downloadObserver;
                    observedCore.PermissionRequested -= permissionObserver;
                }
            }
            catch (Exception ex) { error ??= ex.GetType().Name; }
        }
        try
        {
            if (window is not null) snapshotAfter = JsonSerializer.SerializeToNode(window.SnapshotForHook());
        }
        catch (Exception ex) { error ??= ex.GetType().Name; }
        var decisions = new JsonArray();
        if (snapshotBefore is not null && snapshotAfter?["navigation"] is JsonArray navigation)
            foreach (var decision in navigation.Skip(decisionStartIndex)) decisions.Add(decision?.DeepClone());
        DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(directory, "designer-security-probe.json"),
            JsonSerializer.Serialize(new { kind, commandId, atUtc = DateTimeOffset.UtcNow, sourceBefore,
                sourceAfter = ObsDesignerPreviewSourceForHook(window), decisionStartIndex, decisions,
                snapshotBefore, snapshotAfter, nativeEvents, javascript, error }));
    }

    private void RunObsDesignerBenchCommand(string command, Action action) =>
        StartObsDesignerBenchCommand(command, () => { action(); return Task.CompletedTask; });

    private void StartObsDesignerBenchCommand(string command, Func<Task> action)
    {
        var id = ++_obsDesignerBenchCommandId;
        RecordObsDesignerBenchCommand(id, command, "start");
        _ = ObserveObsDesignerBenchCommandAsync(id, command, action);
    }

    private async Task ObserveObsDesignerBenchCommandAsync(long id, string command, Func<Task> action)
    {
        Task? pending = null;
        try
        {
            pending = action();
            // Do not hold the shared file-command pump on renderer destruction or a native user choice.
            await pending.WaitAsync(ObsDesignerBenchCommandTimeout);
            RecordObsDesignerBenchCommand(id, command, "complete");
        }
        catch (TimeoutException)
        {
            RecordObsDesignerBenchCommand(id, command, "timeout");
            AppLog.Write("obs", $"designer-hook-command-timeout {command}");
            // WaitAsync bounds observation, not the modal/CDP operation. Leave the real state alone
            // and still observe a fault if that operation eventually settles after the timeout.
            if (pending is not null)
                _ = pending.ContinueWith(task =>
                    AppLog.Write("obs", $"designer-hook-command-late-failed {command} {task.Exception!.GetBaseException().GetType().Name}"),
                    CancellationToken.None, TaskContinuationOptions.OnlyOnFaulted | TaskContinuationOptions.ExecuteSynchronously,
                    TaskScheduler.Default);
        }
        catch (Exception ex)
        {
            RecordObsDesignerBenchCommand(id, command, "failed", ex.GetType().Name);
            AppLog.Write("obs", $"designer-hook-command-failed {command} {ex.GetType().Name}");
        }
    }

    private void RecordObsDesignerBenchCommand(long id, string command, string stage, string? error = null)
    {
        var entry = new { id, command, stage, atUtc = DateTimeOffset.UtcNow, error };
        if (id == _obsDesignerBenchCommandId) _obsDesignerBenchLastCommand = entry;
        _obsDesignerBenchCommandHistory.Enqueue(entry);
        while (_obsDesignerBenchCommandHistory.Count > 32) _obsDesignerBenchCommandHistory.Dequeue();
    }

    private object ObsDesignerBenchCommandState() =>
        new { lastCommand = _obsDesignerBenchLastCommand, history = _obsDesignerBenchCommandHistory.ToArray() };

    private DiscordBenchRawJson ObsDesignerBenchStateJson()
    {
        object snapshot = _overlayDesignerWindow is { } window
            ? window.SnapshotForHook()
            : new { open = false, visible = false, navigated = false, nonce = (string?)null };
        var state = JsonSerializer.SerializeToNode(snapshot)!.AsObject();
        state["commands"] = JsonSerializer.SerializeToNode(ObsDesignerBenchCommandState());
        return new DiscordBenchRawJson(state.ToJsonString());
    }

    private DiscordBenchRawJson ObsLyricsBenchStateJson() =>
        new(JsonSerializer.Serialize(new { open = _lyricsWindow is not null }));
}
#endif
