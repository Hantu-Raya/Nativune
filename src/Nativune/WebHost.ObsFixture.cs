#if NATIVUNE_DISCORD_TEST_HOOKS
using System.Diagnostics;
using System.Globalization;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using Microsoft.Web.WebView2.Core;

namespace Nativune;

// OBS overlay E2E seam for approved plan v5 §§2.5-2.7; compiled only with -p:DiscordPresenceTestHooks=true.
// Commands are files in <root>/data/discord-bench and are taken by ProcessDiscordBenchCommandsAsync:
//   command-obs-on/-off and -hide-paused-on/-off          overlay Settings paths
//   command-obs-looks-reload / -looks-commit             reload or atomically mutate the local looks file
//   command-obs-reduce-motion-on/-off                     push the app setting to active streams
//   command-obs-preview-nonce / -draft-look               set the designer's current preview/draft
//   command-obs-store-fault / -pump-hold                  deterministic save/pump pressure
//   command-obs-font-force-available / -fixture-rate      font seam / fixture playback-rate hook
//   command-obs-hold-read / -release-read / -burst         reader delay / 8 MiB pump comment
//   command-clock-mismatch-on/-off / -navigate / -controls-unavailable-on/-off
public sealed partial class WebHostWindow
{
    private TaskCompletionSource? _obsReadHold;
    private CoreWebView2? _obsMaximumArtCore;

    private async Task ProcessObsBenchCommandsAsync()
    {
        if (TakeDiscordBenchCommand("command-obs-off"))
        {
            _settings = _settings with { ObsOverlay = false };
            await ReconcileObsOverlayAsync();
        }
        if (TakeDiscordBenchCommand("command-obs-on"))
        {
            _settings = _settings with { ObsOverlay = true };
            await ReconcileObsOverlayAsync();
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
        if (TakeDiscordBenchCommand("command-obs-reduce-motion-off"))
        {
            _settings = _settings with { ReduceMotion = false };
            ApplyObsReduceMotion(false);
        }
        if (TakeDiscordBenchCommand("command-obs-reduce-motion-on"))
        {
            _settings = _settings with { ReduceMotion = true };
            ApplyObsReduceMotion(true);
        }
        if (TakeDiscordBenchCommand("command-obs-looks-reload"))
            await ReloadObsLooksAsync();
        var previewNonce = TakeObsCommandPayload("command-obs-preview-nonce");
        if (previewNonce is not null)
        {
            previewNonce = previewNonce.Trim();
            ApplyObsDraft(_draftLook, _draftBackdrop, previewNonce == "clear" ? null : ObsLookIds.IsValid(previewNonce) ? previewNonce : _previewNonce);
        }
        var draftPayload = TakeObsCommandPayload("command-obs-draft-look");
        if (draftPayload is not null)
            ApplyObsDraftCommand(draftPayload);
        var commitFile = TakeObsCommandPayload("command-obs-looks-commit");
        if (commitFile is not null)
            await RunObsLookCommitAsync(commitFile);
        var storeFault = TakeObsCommandPayload("command-obs-store-fault");
        if (storeFault is not null)
            SetObsStoreFault(storeFault);
        var pumpHold = TakeObsCommandPayload("command-obs-pump-hold");
        if (int.TryParse(pumpHold, NumberStyles.None, CultureInfo.InvariantCulture, out var holdMs))
            _obsOverlay?.HookPumpHold(Math.Clamp(holdMs, 0, 30_000));
        if (TakeDiscordBenchCommand("command-obs-collect-managed-bytes"))
            _obsOverlay?.HookCollectManagedBytes();
        var forcedFont = TakeObsCommandPayload("command-obs-font-force-available");
        if (forcedFont is not null)
            SystemFonts.HookForceAvailable = forcedFont;
        var fixtureRate = TakeObsCommandPayload("command-obs-fixture-rate");
        if (fixtureRate is not null)
            await SetObsFixtureRateAsync(fixtureRate);
        var fixtureArt = TakeObsCommandPayload("command-obs-fixture-art");
        if (fixtureArt is not null)
            await SetObsFixtureArtAsync(fixtureArt.Trim());
        if (TakeDiscordBenchCommand("command-obs-fixture-text-long") && _browserHost is { } textHost && !_closing && !_disposed)
        {
            await textHost.Core.ExecuteScriptAsync("""
                (() => {
                  const title = ('Fixture Long Title '.repeat(14)).slice(0,249) + '!';
                  const artist = '\u97f3\u697d\u30c6\u30b9\u30c8 \u0627\u0644\u0641\u0646\u0627\u0646';
                  document.querySelector('.title').textContent = title;
                  document.querySelector('ytmusic-player a.ytp-title-link').textContent = title;
                  document.querySelector('.byline a[href^="channel/"]').textContent = artist;
                })()
                """);
        }
        if (TakeDiscordBenchCommand("command-obs-hold-read"))
            _obsReadHold ??= new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        if (TakeDiscordBenchCommand("command-obs-release-read"))
        {
            _obsReadHold?.TrySetResult();
            _obsReadHold = null;
        }
        if (TakeDiscordBenchCommand("command-obs-burst")) _obsOverlay?.HookBurst();
        if (TakeDiscordBenchCommand("command-obs-art-fail-next")) _obsOverlay?.HookFailNextFetches(1);
        if (TakeDiscordBenchCommand("command-controls-unavailable-on")) PlayerControls.HookForceUnavailable = true;
        if (TakeDiscordBenchCommand("command-controls-unavailable-off")) PlayerControls.HookForceUnavailable = false;
        if (TakeDiscordBenchCommand("command-clock-mismatch-on") && _browserHost is { } on)
            await on.Core.ExecuteScriptAsync("window.__nativuneFixture.setClockMismatch(true)");
        if (TakeDiscordBenchCommand("command-clock-mismatch-off") && _browserHost is { } off)
            await off.Core.ExecuteScriptAsync("window.__nativuneFixture.setClockMismatch(false)");
        foreach (var letter in "abc")
            if (TakeDiscordBenchCommand("command-fixture-art-" + letter) && _browserHost is { } art)
                await art.Core.ExecuteScriptAsync($"window.__nativuneFixture.setArtwork('{letter}')");
        if (TakeDiscordBenchCommand("command-navigate") && _browserHost is { } nav && !_closing && !_disposed)
            nav.Core.Reload();
        await ProcessObsDesignerBenchCommandsAsync();
    }

    private static readonly JsonSerializerOptions ObsLookHookJsonOptions = new()
    {
        PropertyNameCaseInsensitive = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) }
    };

    private string? TakeObsCommandPayload(string name)
    {
        if (_discordBenchDirectory is not { } directory) return null;
        var path = Path.Combine(directory, name);
        try
        {
            if (!File.Exists(path)) return null;
            var payload = File.ReadAllText(path);
            File.Delete(path);
            return payload;
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
    }

    private void ApplyObsDraftCommand(string payload)
    {
        if (payload.Trim() == "clear")
        {
            ApplyObsDraft(null, _draftBackdrop, _previewNonce);
            return;
        }
        try
        {
            using var document = JsonDocument.Parse(payload, new JsonDocumentOptions { MaxDepth = 16 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("look", out var lookElement)
                || lookElement.ValueKind != JsonValueKind.Object)
                return;
            var look = ObsLookValidation.ReadDraft(lookElement);
            var backdrop = root.TryGetProperty("backdrop", out var backdropElement)
                && backdropElement.ValueKind == JsonValueKind.String
                    ? backdropElement.GetString() ?? _draftBackdrop
                    : _draftBackdrop;
            ApplyObsDraft(look, backdrop, _previewNonce);
        }
        catch (JsonException) { }
    }

    private static void SetObsStoreFault(string payload)
    {
        var parts = payload.Split(' ', StringSplitOptions.RemoveEmptyEntries);
        if (parts.Length == 0) return;
        var kind = parts[0] switch
        {
            "tmp" => ObsLookStoreFault.Tmp,
            "replace" => ObsLookStoreFault.Replace,
            "slow" => ObsLookStoreFault.Slow,
            _ => (ObsLookStoreFault?)null
        };
        if (kind is null) return;
        var delay = kind == ObsLookStoreFault.Slow && parts.Length > 1
            && int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out var parsed)
                ? Math.Clamp(parsed, 0, 30_000)
                : 0;
        ObsLookStore.InjectFault(kind.Value, delay);
    }

    private async Task SetObsFixtureRateAsync(string value)
    {
        if (_browserHost is not { } browser || _closing || _disposed) return;
        var rate = value.Trim() switch
        {
            "0.25" => "0.25",
            "1" => "1",
            "2" => "2",
            "4" => "4",
            _ => null
        };
        if (rate is not null)
            await browser.Core.ExecuteScriptAsync($"window.__nativuneFixture.setPlaybackRate({rate})");
    }

    private async Task SetObsFixtureArtAsync(string value)
    {
        if (_browserHost is not { } browser || _closing || _disposed
            || value is not ("fixture-max" or "fixture-a" or "fixture-b" or "fixture-c")) return;
        if (!ReferenceEquals(_obsMaximumArtCore, browser.Core))
        {
            _obsMaximumArtCore = browser.Core;
            browser.Core.WebResourceRequested += OnObsMaximumArtRequested;
        }
        // Only fixed synthetic URLs enter the owned fixture DOM. Its existing interceptor prevents network access.
        await browser.Core.ExecuteScriptAsync($$"""
            (() => {
              const url = 'https://lh3.googleusercontent.com/{{value}}=w544-h544';
              document.getElementById('bar-art').src = url;
              document.getElementById('large-art').src = url;
            })()
            """);
    }

    private static void OnObsMaximumArtRequested(CoreWebView2 sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        if (Uri.TryCreate(args.Request.Uri, UriKind.Absolute, out var uri)
            && uri.Scheme == Uri.UriSchemeHttps && uri.IsDefaultPort && uri.UserInfo.Length == 0
            && uri.Host.Equals(DiscordFixtureArtworkHost, StringComparison.OrdinalIgnoreCase)
            && uri.AbsolutePath == "/fixture-max=w544-h544" && uri.Query.Length == 0
            && args.ResourceContext == CoreWebView2WebResourceContext.Image)
            args.Response = DiscordFixtureResponse(sender, ObsOverlayServer.HookFixtureMaximumPng, 200, "OK", "image/png");
    }

    private async Task RunObsLookCommitAsync(string requestedFile)
    {
        var name = requestedFile.Trim();
        if (_discordBenchDirectory is not { } directory
            || Path.GetFileName(name) != name
            || !name.StartsWith("commit-", StringComparison.Ordinal)
            || !name.EndsWith(".json", StringComparison.Ordinal))
            return;
        var digits = name["commit-".Length..^".json".Length];
        if (!int.TryParse(digits, NumberStyles.None, CultureInfo.InvariantCulture, out _)) return;
        var resultName = name[..^".json".Length] + "-result.json";
        ObsLookCommitOutcome outcome;
        try
        {
            using var document = JsonDocument.Parse(File.ReadAllText(Path.Combine(directory, name)),
                new JsonDocumentOptions { MaxDepth = 16 });
            outcome = await ExecuteObsLookMutationAsync(document.RootElement);
        }
        catch (JsonException)
        {
            outcome = new(false, "The looks mutation is invalid", [], _looksRevision);
        }
        catch (IOException)
        {
            outcome = new(false, "Could not read the looks mutation", [], _looksRevision);
        }
        catch (UnauthorizedAccessException)
        {
            outcome = new(false, "Could not read the looks mutation", [], _looksRevision);
        }
        DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(directory, resultName),
            DiscordBenchJson(("ok", outcome.Ok), ("reason", outcome.Reason),
                ("ids", new DiscordBenchRawJson(JsonSerializer.Serialize(outcome.Ids))),
                ("revision", outcome.Revision)));
    }

    private async Task<ObsLookCommitOutcome> ExecuteObsLookMutationAsync(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object
            || !root.TryGetProperty("action", out var actionElement)
            || actionElement.ValueKind != JsonValueKind.String)
            return new(false, "The looks mutation is invalid", [], _looksRevision);

        var action = actionElement.GetString();
        var name = root.TryGetProperty("name", out var nameElement) && nameElement.ValueKind == JsonValueKind.String
            ? nameElement.GetString()
            : null;
        var options = root.TryGetProperty("options", out var optionsElement)
            ? ObsLookValidation.Normalize(optionsElement)
            : ObsLookOptions.Defaults();
        var candidates = ReadObsIdCandidates(root);

        if (action == "create")
            return await CommitLooksAsync(state => PrepareObsLookCreate(state, name, options, candidates));
        if (action == "delete")
        {
            var id = root.TryGetProperty("id", out var idElement) && idElement.ValueKind == JsonValueKind.String
                ? idElement.GetString()
                : null;
            return await CommitLooksAsync(state => PrepareObsLookDelete(state, id));
        }
        if (action != "cycle"
            || !root.TryGetProperty("count", out var countElement)
            || !countElement.TryGetInt32(out var count)
            || count is < 1 or > 5000)
            return new(false, "The looks mutation is invalid", [], _looksRevision);

        return await ExecuteObsLookCycleAsync(count, name, options);

    }

    private async Task<ObsLookCommitOutcome> ExecuteObsLookCycleAsync(int count, string? rawName, ObsLookOptions options)
    {
        await _looksSaveLock.WaitAsync();
        try
        {
            EnsureObsLooksLoaded();
            if (_looks.IsReadOnly)
                return new(false, _looks.ReadOnlyReason ?? "The looks file is read-only", [], _looksRevision);
            if (!ObsLookValidation.TryNormalizeName(rawName, out var name))
                return new(false, "The look name is invalid", [], _looksRevision);

            var current = _looks;
            var ids = new List<string>(count);
            long revisionIncrease = 0;
            string? stopReason = null;
            for (var i = 0; i < count; i++)
            {
                var replacing = current.Looks.Count >= ObsLookState.MaxLooks;
                var baseState = replacing ? current.Without(current.Looks[0].Id) : current;
                var id = ObsLookIds.New(baseState);
                if (id is null)
                {
                    stopReason = "Could not allocate a unique look id";
                    break;
                }
                var created = baseState.WithLook(new ObsLook(id, name, options));
                var candidate = replacing ? created : created.Without(id);
                if (!ObsLookStore.TrySerialize(candidate, out _, out var serializationFailure))
                {
                    stopReason = serializationFailure.Reason ?? "Could not save: the looks file would be too large";
                    break;
                }
                current = candidate;
                ids.Add(id);
                revisionIncrease += 2;
            }

            if (revisionIncrease == 0)
                return new(false, stopReason ?? "No looks could be committed", [], _looksRevision);
            using var commit = CancellationTokenSource.CreateLinkedTokenSource(_looksShutdownCts.Token);
            _activeLooksCommit = commit;
            var saved = await ObsLookStore.SaveAsync(_root, current, commit.Token);
            if (!saved.Committed)
                return new(false, saved.Reason, ids.ToArray(), _looksRevision);
            _looks = current;
            _looksRevision += revisionIncrease;
            _obsOverlay?.SetLooks(_looks);
            return new(stopReason is null, stopReason, ids.ToArray(), _looksRevision);
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

    private static IReadOnlyList<string>? ReadObsIdCandidates(JsonElement root)
    {
        if (!root.TryGetProperty("testIdCandidates", out var candidates)
            || candidates.ValueKind != JsonValueKind.Array)
            return null;
        return candidates.EnumerateArray()
            .Where(static value => value.ValueKind == JsonValueKind.String)
            .Select(static value => value.GetString()!)
            .ToArray();
    }

    private static (ObsLookState? State, string[] Ids, string? Error) PrepareObsLookCreate(
        ObsLookState state, string? rawName, ObsLookOptions options, IReadOnlyList<string>? candidates)
    {
        if (state.Looks.Count >= ObsLookState.MaxLooks)
            return (null, [], "Could not save: the maximum of 16 looks has been reached");
        if (!ObsLookValidation.TryNormalizeName(rawName, out var name))
            return (null, [], "The look name is invalid");
        var id = ObsLookIds.New(state, candidates);
        if (id is null) return (null, [], "Could not allocate a unique look id");
        return (state.WithLook(new ObsLook(id, name, options)), [id], null);
    }

    private static (ObsLookState? State, string[] Ids, string? Error) PrepareObsLookDelete(
        ObsLookState state, string? id)
    {
        if (!ObsLookValidation.IsValidId(id) || state.Find(id!) is null)
            return (null, id is null ? [] : [id], "The look was not found");
        return (state.Without(id!), [id!], null);
    }

    private DiscordBenchRawJson ObsBenchStateJson()
    {
        EnsureObsLooksLoaded();
        var server = _obsOverlay;
        var hook = server?.HookState();
        var counts = server?.Counts();
        var timer = _playbackReadTimer;
        var looksJson = DiscordBenchJson(("readOnly", _looks.IsReadOnly),
            ("reason", _looks.ReadOnlyReason), ("count", _looks.Looks.Count),
            ("fileHash", ObsLooksFileHash()));
        var lookCounts = counts is { } streamCounts
            ? ObsLookCountsJson(streamCounts.ByLook)
            : "{}";
        var previewNonces = counts is { } previewCounts
            ? DiscordBenchJson(("current", previewCounts.Preview.Current),
                ("open", previewCounts.Preview.Open), ("refused503", previewCounts.Preview.Refused503),
                ("state", previewCounts.Preview.State.ToString()))
            : "{}";
        var pump = hook?.Diagnostics;
        var pumpJson = pump is null ? "{}" : JsonSerializer.Serialize(new
        {
            inFlight = pump.Pump.Select(static stream => new
            {
                look = stream.InFlight.Look, data = stream.InFlight.Data, comment = stream.InFlight.Comment
            }).ToArray(),
            pending = pump.Pump.Select(static stream => new
            {
                look = stream.Pending.Look, data = stream.Pending.Data, comment = stream.Pending.Comment
            }).ToArray(),
            holdMs = pump.PumpHoldMs
        }, ObsLookHookJsonOptions);
        var draftJson = DiscordBenchJson(("active", pump?.DraftActive ?? (_draftLook is not null)),
            ("id", pump?.DraftId ?? _draftLook?.Id), ("name", pump?.DraftName ?? _draftLook?.Name),
            ("backdrop", pump?.DraftBackdrop ?? _draftBackdrop));
        var lookCountsRaw = new DiscordBenchRawJson(lookCounts);
        return new DiscordBenchRawJson(DiscordBenchJson(
            ("enabled", _settings.ObsOverlay), ("running", server?.IsRunning ?? false),
            ("bindResult", _obsStartResult?.ToString()), ("streams", server?.OpenStreams ?? 0),
            ("openStreams", counts?.Total ?? 0), ("realStreams", counts?.Real ?? 0),
            ("sampleStreams", counts?.Sample ?? 0), ("statusSourceCount", counts?.StatusSources ?? 0),
            ("previewNonces", new DiscordBenchRawJson(previewNonces)),
            ("lookCounts", lookCountsRaw), ("streamsByLook", lookCountsRaw),
            ("missingLooks", counts?.MissingLooks ?? 0), ("looks", new DiscordBenchRawJson(looksJson)),
            ("draft", new DiscordBenchRawJson(draftJson)), ("pump", new DiscordBenchRawJson(pumpJson)),
            ("retainedManagedBytes", pump?.RetainedManagedBytes),
            ("generation", _overlayGeneration), ("demand", CurrentReaderDemand.ToString()),
            ("timerRunning", timer?.IsRunning ?? false),
            ("intervalMs", timer is null ? null : (long?)timer.Interval.TotalMilliseconds),
            ("lastStreamEndReason", hook?.LastStreamEndReason),
            ("gapStartQpc", _overlayGapSince >= 0 ? (long?)_overlayGapSinceQpc : null),
            ("noneSent", _overlayNoneSent), ("latestState", hook?.LatestState), ("latestStale", hook?.LatestStale ?? true),
            ("latestPosition", hook?.LatestPosition), ("latestDuration", hook?.LatestDuration),
            ("fixtureArtServed", hook?.FixtureArtServed ?? 0), ("pendingWrite", hook?.PendingWrite ?? false),
            ("hidePaused", hook?.HidePaused ?? _settings.ObsHidePaused),
            ("reduceMotion", _settings.ReduceMotion),
            ("designer", ObsDesignerBenchStateJson()), ("lyrics", ObsLyricsBenchStateJson())));
    }

    private static string ObsLookCountsJson(IReadOnlyDictionary<string, int>? counts)
    {
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer))
        {
            json.WriteStartObject();
            if (counts is not null)
                foreach (var (id, count) in counts)
                    json.WriteNumber(id, count);
            json.WriteEndObject();
        }
        return System.Text.Encoding.UTF8.GetString(buffer.ToArray());
    }

    private string? ObsLooksFileHash()
    {
        try
        {
            using var stream = File.OpenRead(ObsLookStore.Path(_root));
            return Convert.ToHexStringLower(SHA256.HashData(stream));
        }
        catch (IOException) { return null; }
        catch (UnauthorizedAccessException) { return null; }
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
