using Microsoft.UI.Dispatching;
using Microsoft.Web.WebView2.Core;
using System.Text.Json;

namespace Nativune;

internal enum EqualizerState { Off, Waiting, NotApplied, Active, Bypassed, Interrupted, ProtectedMedia, ReloadNeeded, Unsupported, Unavailable }
internal sealed record EqualizerStatus(EqualizerState State, string? Reason, double? SampleRate, double? BaseLatency, bool Attached);

public sealed partial class WebHostWindow
{
    private static readonly TimeSpan EqualizerDeadline = TimeSpan.FromSeconds(3);
    private static readonly string EqualizerControllerSource = ReadEqualizerController();
    private long _equalizerGeneration;
    private long _equalizerRevision;
    private int? _equalizerContext;
    private Task? _equalizerInstall;
    private EqualizerApply? _equalizerDesired;
    private DispatcherQueueTimer? _equalizerTimer;
    private bool _equalizerPolling;
    private bool _equalizerEnabledInDocument;
    private bool _equalizerUnknownOutcome;
    private bool _equalizerApplyingSettings, _equalizerDesiredFromSettings;

    internal EqualizerStatus EqualizerStatus { get; private set; } = new(EqualizerState.Off, null, null, null, false);
    internal event EventHandler? EqualizerStatusChanged;

    private static string ReadEqualizerController()
    {
        using var stream = typeof(WebHostWindow).Assembly.GetManifestResourceStream("Nativune.EqualizerController.js")
            ?? throw new InvalidOperationException("Equalizer controller resource is missing.");
        using var reader = new StreamReader(stream);
        return reader.ReadToEnd();
    }

    private static bool IsEqualizerMusicOrigin(string? source) =>
        Uri.TryCreate(source, UriKind.Absolute, out var uri) && uri.Scheme == "https" &&
        string.Equals(uri.Host, "music.youtube.com", StringComparison.OrdinalIgnoreCase) && uri.Port == 443 &&
        string.IsNullOrEmpty(uri.UserInfo);

    private void InvalidateEqualizer()
    {
        ++_equalizerGeneration;
        _equalizerContext = null;
        _equalizerInstall = null;
        _equalizerEnabledInDocument = false;
        _equalizerUnknownOutcome = false;
        _equalizerTimer?.Stop();
        SetEqualizerStatus(new(EqualizerState.Off, null, null, null, false));
    }

    private async Task OnEqualizerNavigationCompletedAsync(CoreWebView2NavigationCompletedEventArgs args)
    {
        if (!args.IsSuccess || !IsEqualizerMusicOrigin(_browserHost?.Core.Source)) return;
        if (_settingsDialog?.ReapplyEqualizerDraft() == true) return;
        await ApplyEqualizerFromSettingsAsync();
    }

    private double ActiveEqualizerSampleRate() =>
        EqualizerStatus.SampleRate is double rate && double.IsFinite(rate) && rate >= EqualizerMath.MinimumSampleRate ? rate : 48000;

    internal async Task ApplyEqualizerFromSettingsAsync()
    {
        if (_closing || _disposed) return;
        _equalizerApplyingSettings = true;
        await ApplyEqualizerAsync(EqualizerApply.From(_settings.Equalizer, bypass: false, ActiveEqualizerSampleRate()), _lifetime.Token);
    }

    internal async Task<EqualizerStatus> ApplyEqualizerAsync(EqualizerApply apply, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        if (apply.GainsDb.Length != EqualizerBands.Count || apply.GainsDb.Any(value => !double.IsFinite(value) || value < -12 || value > 12) ||
            !double.IsFinite(apply.PreampDb) || apply.PreampDb < -24 || apply.PreampDb > 6)
            throw new ArgumentOutOfRangeException(nameof(apply));
        apply = apply with { GainsDb = (double[])apply.GainsDb.Clone() };
        // Only an apply built from the saved settings may later be recomputed for the real sample rate;
        // a Settings preview or test apply must never be replaced by the saved state.
        _equalizerDesiredFromSettings = _equalizerApplyingSettings;
        _equalizerApplyingSettings = false;
        _equalizerDesired = apply;
        var revision = ++_equalizerRevision;
        var generation = _equalizerGeneration;
        var core = _browserHost?.Core;
        if (_closing || _disposed || core is null || _navigationFailed || !IsEqualizerMusicOrigin(core.Source))
        {
            SetEqualizerStatus(new(EqualizerState.Unavailable, "navigation", null, null, false));
            return EqualizerStatus;
        }
        if (_equalizerUnknownOutcome) return EqualizerStatus;
        _equalizerEnabledInDocument |= apply.Enabled;
        if (!_equalizerEnabledInDocument && _equalizerContext is null)
        {
            SetEqualizerStatus(new(EqualizerState.Off, null, null, null, false));
            return EqualizerStatus;
        }
        try
        {
            _equalizerInstall ??= InstallEqualizerAsync(core, generation);
            await _equalizerInstall.WaitAsync(EqualizerDeadline, token);
            if (!EqualizerRequestCurrent(core, generation) || _equalizerUnknownOutcome ||
                revision != _equalizerRevision || _equalizerContext is not int context) return EqualizerStatus;
            var payload = JsonSerializer.Serialize(new { rev = revision, epoch = generation, enabled = apply.Enabled,
                gains = apply.GainsDb, preampDb = apply.PreampDb, bypass = apply.Bypass });
            var status = await EvaluateEqualizerStatusAsync(core, context, $"globalThis.__nativuneEq.apply({payload})", token);
            if (EqualizerRequestCurrent(core, generation) && revision == _equalizerRevision)
                SetEqualizerStatus(status);
        }
        catch (Exception)
        {
            if (EqualizerRequestCurrent(core, generation) && revision == _equalizerRevision)
            {
                _equalizerUnknownOutcome = true;
                SetEqualizerStatus(new(EqualizerState.ReloadNeeded, "controller", null, null, EqualizerStatus.Attached));
            }
        }
        UpdateEqualizerPolling();
        return EqualizerStatus;
    }

    // The CoreWebView2 projection may hand out a fresh managed wrapper per property read, so wrapper
    // identity is not a reliable "same browser" test. A replaced browser always navigates again, which
    // advances _equalizerGeneration; here we only require that a browser host still exists.
    private bool IsCurrentEqualizerCore(CoreWebView2 core) => _browserHost is not null && core is not null;

    private bool EqualizerRequestCurrent(CoreWebView2 core, long generation) => !_closing && !_disposed &&
        generation == _equalizerGeneration && IsCurrentEqualizerCore(core) && IsEqualizerMusicOrigin(core.Source);

    private async Task InstallEqualizerAsync(CoreWebView2 core, long generation)
    {
        var json = await core.CallDevToolsProtocolMethodAsync("Page.getFrameTree", "{}").AsTask().WaitAsync(EqualizerDeadline, _lifetime.Token);
        if (!EqualizerRequestCurrent(core, generation)) return;
        using var tree = JsonDocument.Parse(json);
        var frame = tree.RootElement.GetProperty("frameTree").GetProperty("frame");
        var frameId = frame.GetProperty("id").GetString();
        if (string.IsNullOrEmpty(frameId) || frameId.Length > 256 || !IsEqualizerMusicOrigin(frame.GetProperty("url").GetString()))
            throw new InvalidDataException("Invalid equalizer frame.");
        json = await core.CallDevToolsProtocolMethodAsync("Page.createIsolatedWorld", JsonSerializer.Serialize(new {
            frameId, worldName = "nativune-eq", grantUniveralAccess = false })).AsTask().WaitAsync(EqualizerDeadline, _lifetime.Token);
        if (!EqualizerRequestCurrent(core, generation)) return;
        using var world = JsonDocument.Parse(json);
        var context = world.RootElement.GetProperty("executionContextId").GetInt32();
        if (context <= 0) throw new InvalidDataException("Invalid equalizer context.");
#if NATIVUNE_DISCORD_TEST_HOOKS
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_EQ_FIXTURE") == "1")
        {
            var rate = Environment.GetEnvironmentVariable("NATIVUNE_TEST_EQ_SAMPLE_RATE") switch { "44100" => 44100, "16000" => 16000, _ => 48000 };
            await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new {
                expression = "globalThis.__nativuneEqTestHooks = true;" +
                    "globalThis.__nativuneEqActivation = {blocked:false,resumeCalls:0,sourceCalls:0};" +
                    (Environment.GetEnvironmentVariable("NATIVUNE_TEST_EQ_REAL_MUSIC") == "1" ? "" :
                    "globalThis.AudioContext = class extends AudioContext { constructor(options) {" +
                    " if(globalThis.__nativuneEqPreparedContext){const prepared=globalThis.__nativuneEqPreparedContext;" +
                    " delete globalThis.__nativuneEqPreparedContext;return prepared;}" +
                    $" super({{...options, sampleRate:{rate}}});" +
                    " const hook=globalThis.__nativuneEqActivation; this.__eqHook=hook;" +
                    " if(hook.blocked) {" +
                    " this.__eqSuspended=super.suspend();" +
                    " this.__eqPermit=new Promise(resolve=>{const release=e=>{if(!e.isTrusted)return;" +
                    " hook.blocked=false;document.removeEventListener('pointerdown',release,true);" +
                    " document.removeEventListener('keydown',release,true);resolve();};" +
                    " document.addEventListener('pointerdown',release,true);document.addEventListener('keydown',release,true);});" +
                    " }} resume(){this.__eqHook.resumeCalls++;" +
                    " return this.__eqHook.blocked?Promise.all([this.__eqSuspended,this.__eqPermit]).then(()=>super.resume()):super.resume();}" +
                    " createMediaElementSource(element){this.__eqHook.sourceCalls++;return super.createMediaElementSource(element);} };"),
                contextId = context, returnByValue = true
            })).AsTask().WaitAsync(EqualizerDeadline, _lifetime.Token);
        }
#endif
        json = await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new {
            expression = EqualizerControllerSource, contextId = context, returnByValue = true, timeout = 2000
        })).AsTask().WaitAsync(EqualizerDeadline, _lifetime.Token);
        using var result = JsonDocument.Parse(json);
        if (result.RootElement.TryGetProperty("exceptionDetails", out _)) throw new InvalidDataException("Equalizer installation failed.");
        if (EqualizerRequestCurrent(core, generation)) _equalizerContext = context;
    }

    private async Task<EqualizerStatus> EvaluateEqualizerStatusAsync(CoreWebView2 core, int context, string expression, CancellationToken token)
    {
        var json = await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new {
            expression, contextId = context, returnByValue = true, awaitPromise = true, timeout = 2000
        })).AsTask().WaitAsync(EqualizerDeadline, token);
        using var document = JsonDocument.Parse(json);
        var root = document.RootElement;
        if (root.TryGetProperty("exceptionDetails", out _)) throw new InvalidDataException("Equalizer evaluation failed.");
        var value = root.GetProperty("result").GetProperty("value");
        var state = value.GetProperty("state").GetString() switch
        {
            "off" => EqualizerState.Off, "waiting" => EqualizerState.Waiting, "notApplied" => EqualizerState.NotApplied,
            "active" => EqualizerState.Active, "bypassed" => EqualizerState.Bypassed, "interrupted" => EqualizerState.Interrupted,
            "protectedMedia" => EqualizerState.ProtectedMedia, "reloadNeeded" => EqualizerState.ReloadNeeded,
            "unsupported" => EqualizerState.Unsupported, "unavailable" => EqualizerState.Unavailable,
            _ => throw new InvalidDataException("Invalid equalizer state.")
        };
        var reason = value.GetProperty("reason").GetString();
        if (reason is null || reason.Length > 64 || reason.Any(character => !char.IsAsciiLetterOrDigit(character)))
            throw new InvalidDataException("Invalid equalizer reason.");
        var sampleRate = value.GetProperty("sampleRate").GetDouble();
        var latency = value.GetProperty("baseLatency").GetDouble();
        if (!double.IsFinite(sampleRate) || sampleRate < 0 || sampleRate > 384000 || !double.IsFinite(latency) || latency < 0 || latency > 60 ||
            value.GetProperty("rev").GetInt64() < 0) throw new InvalidDataException("Invalid equalizer numbers.");
        var attached = value.GetProperty("attached").GetBoolean();
        _ = value.GetProperty("encrypted").GetBoolean();
        _ = value.GetProperty("mediaKeys").GetBoolean();
        if (attached && sampleRate == 0) throw new InvalidDataException("Invalid equalizer graph status.");
        return new(state, reason.Length == 0 ? null : reason, sampleRate == 0 ? null : sampleRate, sampleRate == 0 ? null : latency, attached);
    }

    private void SetEqualizerStatus(EqualizerStatus status)
    {
        if (!_dispatcherQueue.HasThreadAccess)
        {
            _dispatcherQueue.TryEnqueue(() => SetEqualizerStatus(status));
            return;
        }
        if (_closing || _disposed || EqualizerStatus == status) return;
        var previousRate = EqualizerStatus.SampleRate;
        EqualizerStatus = status;
        // Auto headroom depends on the context's real rate, known only after attachment; re-apply once it changes.
        // Saved state still owns the graph while Settings is open until a dialog preview replaces it.
        if (status.SampleRate is double rate && rate != (previousRate ?? 48000) && _settings.Equalizer.AutoHeadroom && _equalizerDesiredFromSettings)
            _ = ApplyEqualizerFromSettingsAsync();
        EqualizerStatusChanged?.Invoke(this, EventArgs.Empty);
    }

    private void UpdateEqualizerPolling()
    {
        if (_closing || _disposed || _equalizerContext is null || !(_equalizerDesired?.Enabled == true || EqualizerStatus.Attached))
        {
            _equalizerTimer?.Stop();
            return;
        }
        if (_equalizerTimer is null)
        {
            _equalizerTimer = _dispatcherQueue.CreateTimer();
            _equalizerTimer.Interval = TimeSpan.FromSeconds(2);
            _equalizerTimer.IsRepeating = true;
            _equalizerTimer.Tick += (_, _) => _ = PollEqualizerAsync();
        }
        _equalizerTimer.Start();
    }

    private async Task PollEqualizerAsync()
    {
        if (_equalizerUnknownOutcome || _equalizerPolling || _equalizerContext is not int context || _browserHost?.Core is not { } core) return;
        var generation = _equalizerGeneration;
        var revision = _equalizerRevision;
        if (!EqualizerRequestCurrent(core, generation)) { _equalizerTimer?.Stop(); return; }
        _equalizerPolling = true;
        try
        {
            var status = await EvaluateEqualizerStatusAsync(core, context, "globalThis.__nativuneEq.status()", _lifetime.Token);
            if (!_equalizerUnknownOutcome && EqualizerRequestCurrent(core, generation) && revision == _equalizerRevision) SetEqualizerStatus(status);
        }
        catch (Exception)
        {
            if (!_equalizerUnknownOutcome && EqualizerRequestCurrent(core, generation) && revision == _equalizerRevision)
                SetEqualizerStatus(new(EqualizerState.Unavailable, "status", null, null, EqualizerStatus.Attached));
        }
        finally { _equalizerPolling = false; UpdateEqualizerPolling(); }
    }

    // Returns true only when the disabled setting was persisted and the Music reload was issued.
    internal async Task<bool> ReloadWithoutEqualizerAsync()
    {
        if (_closing || _disposed || _browserHost?.Core is not { } core || !IsEqualizerMusicOrigin(core.Source)) return false;
        var previous = _settings.Equalizer;
        _settings = _settings with { Equalizer = previous with { Enabled = false } };
        if (!await SaveSettingsConfirmedAsync())
        {
            // Nothing was reloaded and the graph is unchanged, so keep the in-memory setting truthful.
            _settings = _settings with { Equalizer = previous };
            SetStatus("Equalizer setting could not be saved. Reload cancelled.", isError: true);
            return false;
        }
        try
        {
            if (!_closing && !_disposed && !_settings.Equalizer.Enabled &&
                IsCurrentEqualizerCore(core) && IsEqualizerMusicOrigin(core.Source))
            {
                core.Reload();
                return true;
            }
        }
        catch (Exception) { }
        _settings = _settings with { Equalizer = previous };
        var restored = await SaveSettingsConfirmedAsync();
        SetStatus(restored
            ? "Reload was not issued; equalizer setting restored."
            : "Reload was not issued; equalizer setting could not be restored.", isError: true);
        return false;
    }

    private void DisposeEqualizer()
    {
        ++_equalizerGeneration;
        _equalizerTimer?.Stop();
        _equalizerTimer = null;
        _equalizerContext = null;
        _equalizerInstall = null;
        EqualizerStatusChanged = null;
    }
}
