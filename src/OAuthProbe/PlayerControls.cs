using Microsoft.Web.WebView2.Core;
using System.Runtime.InteropServices;
using System.Text.Json;
using Windows.Foundation;

namespace OAuthProbe;

internal sealed class PlayerControls : IDisposable
{
    private const int MaxScriptResultLength = 4096;
    private static readonly TimeSpan ScriptTimeout = TimeSpan.FromMilliseconds(2500);
    private static readonly TimeSpan DispatchWindow = TimeSpan.FromMilliseconds(1200);

    private readonly CoreWebView2 _core;
    private readonly Func<bool> _hostReady;
    private readonly CancellationToken _lifetime;
    private readonly SynchronizationContext? _context;
    private readonly object _gate = new();
    private CancellationTokenSource? _operation;
    private Task<string>? _pendingScript;
    private CancellationTokenRegistration _lifetimeRegistration;
    private ulong? _navigationId;
    private int _generation;
    private bool _navigating = true;
    private bool _navigationReady;
    private bool _busy;
    private bool _poisoned;
    private bool _disposed;
    private CompactPlaybackState? _lastCompactState;
    private string? _lastCompactHref;
    private long _lastCompactReadAt = -1000, _lastCompactStateAt;

    public PlayerControls(CoreWebView2 core, Func<bool> hostReady, CancellationToken lifetime)
    {
        _core = core ?? throw new ArgumentNullException(nameof(core));
        _hostReady = hostReady ?? throw new ArgumentNullException(nameof(hostReady));
        _lifetime = lifetime;
        _context = SynchronizationContext.Current;

        _core.NavigationStarting += NavigationStarting;
        _core.NavigationCompleted += NavigationCompleted;
        _core.SourceChanged += SourceChanged;
        _core.ProcessFailed += ProcessFailed;
        _lifetimeRegistration = lifetime.Register(static state => ((PlayerControls)state!).Invalidate(), this);
    }

    public bool IsAvailable
    {
        get
        {
            lock (_gate)
            {
                if (!CanAttemptLocked()) return false;
            }

            if (!TryGetSource(out var source) || !IsReady(source)) return false;

            if (!TryGetSource(out var currentSource) || currentSource != source) return false;
            lock (_gate)
            {
                return CanAttemptLocked() && _navigationReady && !_navigating;
            }
        }
    }

    public event EventHandler? StateChanged;

    public async Task<string> ExecuteAsync(string command)
    {
        if (!IsSupportedCommand(command)) return "Unsupported control command.";
        if (!TryStart(command, out var request, out var failure)) return failure;

        try
        {
            if (!Owns(request)) return "Control request invalidated; no action was sent.";

            var notAfterUnixMs = DateTimeOffset.UtcNow.Add(DispatchWindow).ToUnixTimeMilliseconds();
            var script = BuildScript(request.Command, request.Href, notAfterUnixMs);
            Task<string> pending;
            try
            {
                pending = _core.ExecuteScriptAsync(script).AsTask();
            }
            catch (Exception ex) when (ex is InvalidOperationException or COMException)
            {
                return "Player control action failed; no retry.";
            }

            SetPendingScript(pending);

            string json;
            try
            {
                json = await pending.WaitAsync(ScriptTimeout, request.Cancellation.Token);
            }
            catch (TimeoutException) when (!request.Cancellation.IsCancellationRequested)
            {
                Poison();
                return "Control script timed out; controls disabled until restart.";
            }
            catch (OperationCanceledException) when (request.Cancellation.IsCancellationRequested)
            {
                // Cancellation stops our wait, not a DOM click already dispatched by WebView2.
                return "Control request invalidated; action may have occurred; no retry.";
            }
            catch (Exception)
            {
                return "Player control action failed; no retry.";
            }

            if (!Owns(request))
                return "Control request invalidated; action may have occurred; no retry.";
            if (!TryParseOutcome(json, out var outcome))
                return "Player control action failed; no retry.";
            return FormatOutcome(command, outcome);
        }
        finally
        {
            CompleteRequest(request);
        }
    }

    internal async Task<CompactPlaybackState?> ReadCompactStateAsync()
    {
        if (!IsAvailable || !TryGetSource(out var source)) return null;
        lock (_gate)
            if (Environment.TickCount64 - _lastCompactReadAt < 1000)
                return _lastCompactHref == source ? _lastCompactState : null;
        if (!TryStart("compact-state", out var request, out _)) return null;
        try
        {
            lock (_gate)
            {
                _lastCompactReadAt = Environment.TickCount64;
                _lastCompactState = null;
                _lastCompactHref = null;
            }
            var script = CompactPlayback.BuildScript("state", null, request.Href,
                DateTimeOffset.UtcNow.Add(DispatchWindow).ToUnixTimeMilliseconds());
            var json = await RunCompactScriptAsync(request, script);
            if (json is null || !Owns(request) || !CompactPlayback.TryParseState(json, out var state))
                return null;
            lock (_gate)
            {
                if (_generation != request.Generation) return null;
                _lastCompactState = state;
                _lastCompactHref = request.Href;
                _lastCompactStateAt = Environment.TickCount64;
            }
            return state;
        }
        finally { CompleteRequest(request); }
    }

    internal async Task<string> ExecuteCompactAsync(string command, double? value = null)
    {
        if (command is not ("like" or "dislike" or "repeat" or "shuffle" or "mute" or "seek" or "volume"))
            return "Unsupported compact command.";
        if (command is "seek" or "volume"
            && (value is null || !double.IsFinite(value.Value) || value < 0 || command == "volume" && value > 1))
            return "Invalid control value; no action was sent.";
        if (!TryStart(command, out var request, out var failure)) return failure;
        try
        {
            string? signature = null;
            lock (_gate)
            {
                if (_lastCompactState is { } state && _lastCompactHref == request.Href
                    && Environment.TickCount64 - _lastCompactStateAt <= 2500)
                    signature = CompactPlayback.ComputeSignature(state);
            }
            if (command is "seek" or "like" or "dislike" && signature is null)
                return "Playback state is stale; no action was sent.";
            var script = CompactPlayback.BuildScript("action", command, request.Href,
                DateTimeOffset.UtcNow.Add(DispatchWindow).ToUnixTimeMilliseconds(), value, signature);
            var json = await RunCompactScriptAsync(request, script);
            if (json is null || !Owns(request) || !CompactPlayback.TryParseOutcome(json, out var outcome))
                return "Player action outcome unknown; no retry. If controls remain unavailable, restart the app.";
            return outcome.Code switch
            {
                "requested" when outcome.Dispatched => "Player action requested; awaiting confirmed website state.",
                "stale-state" => "Playback changed; no action was sent.",
                "script-error" when outcome.Dispatched => "Player action outcome unknown; no retry.",
                _ => "Player control unavailable or ambiguous; no action was sent."
            };
        }
        finally { CompleteRequest(request); }
    }

    private async Task<string?> RunCompactScriptAsync(Request request, string script)
    {
        if (!Owns(request)) return null;
        try
        {
            var pending = _core.ExecuteScriptAsync(script).AsTask();
            SetPendingScript(pending);
            return await pending.WaitAsync(ScriptTimeout, request.Cancellation.Token);
        }
        catch (TimeoutException) when (!request.Cancellation.IsCancellationRequested)
        {
            Poison();
            return null;
        }
        catch (Exception) { return null; }
    }

    private void CompleteRequest(Request request)
    {
        lock (_gate)
        {
            if (ReferenceEquals(_operation, request.Cancellation)) _operation = null;
            _busy = false;
        }
        request.Cancellation.Dispose();
        RaiseStateChanged();
    }

    public void Invalidate()
    {
        CancellationTokenSource? operation;
        lock (_gate)
        {
            if (_disposed) return;
            _generation++;
            _lastCompactState = null;
            _lastCompactHref = null;
            operation = _operation;
        }
        operation?.Cancel();
        RaiseStateChanged();
    }

    public void Dispose()
    {
        CancellationTokenSource? operation;
        lock (_gate)
        {
            if (_disposed) return;
            _disposed = true;
            _generation++;
            _lastCompactState = null;
            _lastCompactHref = null;
            operation = _operation;
            _operation = null;
        }

        operation?.Cancel();
        _lifetimeRegistration.Dispose();
        _core.NavigationStarting -= NavigationStarting;
        _core.NavigationCompleted -= NavigationCompleted;
        _core.SourceChanged -= SourceChanged;
        _core.ProcessFailed -= ProcessFailed;
        StateChanged = null;
    }

    private bool CanAttemptLocked()
        => !_disposed && !_poisoned && !_lifetime.IsCancellationRequested && !_busy
            && _pendingScript is not { IsCompleted: false };

    private bool TryStart(string command, out Request request, out string failure)
    {
        request = default;
        failure = string.Empty;
        int generation;
        ulong? navigationId;

        lock (_gate)
        {
            if (_disposed || _poisoned || _lifetime.IsCancellationRequested)
            {
                failure = "Player controls unavailable.";
                return false;
            }
            if (_busy || _pendingScript is { IsCompleted: false })
            {
                failure = "A player control request is already in progress.";
                return false;
            }
            if (!_navigationReady || _navigating)
            {
                failure = "Player controls unavailable; the page is not ready.";
                return false;
            }
            generation = _generation;
            navigationId = _navigationId;
        }

        if (!TryGetSource(out var source) || !IsReady(source))
        {
            failure = "Player controls unavailable; no action was sent.";
            return false;
        }

        CancellationTokenSource operation;
        lock (_gate)
        {
            if (_disposed || _poisoned || _lifetime.IsCancellationRequested)
            {
                failure = "Player controls unavailable.";
                return false;
            }
            if (_busy || _pendingScript is { IsCompleted: false })
            {
                failure = "A player control request is already in progress.";
                return false;
            }
            if (generation != _generation || !Equals(navigationId, _navigationId)
                || !_navigationReady || _navigating)
            {
                failure = "Control request invalidated; no action was sent.";
                return false;
            }

            operation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime);
            _operation = operation;
            _busy = true;
            request = new Request(command, source, navigationId, generation, operation);
        }

        RaiseStateChanged();
        return true;
    }

    private bool Owns(Request request)
    {
        lock (_gate)
        {
            if (_disposed || _poisoned || _lifetime.IsCancellationRequested || _busy == false
                || _generation != request.Generation || !Equals(_navigationId, request.NavigationId)
                || !_navigationReady || _navigating)
                return false;
        }

        return TryGetSource(out var source) && source == request.Href && IsReady(source);
    }

    private bool IsReady(string source)
    {
        if (!IsMusicUri(source)) return false;
        try
        {
            return _hostReady() && !_core.Settings.AreHostObjectsAllowed
                && !_core.Settings.IsWebMessageEnabled;
        }
        catch (Exception ex) when (ex is InvalidOperationException or COMException)
        {
            return false;
        }
    }

    private bool TryGetSource(out string source)
    {
        try
        {
            source = _core.Source;
            return true;
        }
        catch (Exception ex) when (ex is InvalidOperationException or COMException)
        {
            source = string.Empty;
            return false;
        }
    }

    private void SetPendingScript(Task<string> pending)
    {
        lock (_gate) _pendingScript = pending;
        var owner = new WeakReference<PlayerControls>(this);
        _ = pending.ContinueWith(task =>
        {
            _ = task.Exception;
            if (owner.TryGetTarget(out var controls)) controls.ClearPendingScript(task);
        }, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }

    private void ClearPendingScript(Task<string> pending)
    {
        var changed = false;
        lock (_gate)
        {
            if (ReferenceEquals(_pendingScript, pending))
            {
                _pendingScript = null;
                changed = true;
            }
        }
        if (changed) RaiseStateChanged();
    }

    private void Poison()
    {
        CancellationTokenSource? operation;
        lock (_gate)
        {
            if (_disposed) return;
            _poisoned = true;
            _generation++;
            operation = _operation;
        }
        operation?.Cancel();
        RaiseStateChanged();
    }

    private void NavigationStarting(CoreWebView2 sender, CoreWebView2NavigationStartingEventArgs e)
    {
        if (e.Cancel) return;
        lock (_gate)
        {
            if (_disposed) return;
            _navigationId = e.NavigationId;
            _navigating = true;
            _navigationReady = false;
        }
        Invalidate();
    }

    private void NavigationCompleted(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        lock (_gate)
        {
            if (_disposed || !Equals(_navigationId, e.NavigationId)) return;
            _navigating = !e.IsSuccess;
            _navigationReady = e.IsSuccess;
        }
        if (e.IsSuccess) RaiseStateChanged();
        else Invalidate();
    }

    private void SourceChanged(CoreWebView2 sender, CoreWebView2SourceChangedEventArgs e)
    {
        if (e.IsNewDocument)
        {
            lock (_gate)
            {
                if (_disposed) return;
                _navigating = true;
                _navigationReady = false;
            }
            Invalidate();
            return;
        }

        if (!TryGetSource(out var source) || !IsMusicUri(source))
        {
            lock (_gate) _navigationReady = false;
            Invalidate();
        }
        else
        {
            RaiseStateChanged();
        }
    }

    private void ProcessFailed(CoreWebView2 sender, CoreWebView2ProcessFailedEventArgs e)
    {
        lock (_gate)
        {
            if (_disposed) return;
            _navigationReady = false;
            _navigating = true;
        }
        Poison();
    }

    private void RaiseStateChanged()
    {
        if (_context is not null && SynchronizationContext.Current != _context)
        {
            try { _context.Post(static state => ((PlayerControls)state!).RaiseStateChangedOnContext(), this); }
            catch (InvalidOperationException) { }
            return;
        }
        RaiseStateChangedOnContext();
    }

    private void RaiseStateChangedOnContext()
    {
        EventHandler? handler;
        lock (_gate)
        {
            if (_disposed) return;
            handler = StateChanged;
        }
        try { handler?.Invoke(this, EventArgs.Empty); }
        catch (Exception) { }
    }

    private static bool IsSupportedCommand(string? command)
        => command is "play" or "pause" or "next" or "previous" or "toggle";

    private static bool IsMusicUri(string? source)
    {
        if (source is not { Length: <= 4096 } || !Uri.TryCreate(source, UriKind.Absolute, out var uri))
            return false;
        if (uri.Scheme != Uri.UriSchemeHttps || !uri.IsDefaultPort || uri.UserInfo.Length != 0
            || !uri.Host.Equals("music.youtube.com", StringComparison.OrdinalIgnoreCase)) return false;
        return !new[] { "/signin", "/signout", "/logout", "/account", "/channel_switcher" }
            .Any(path => uri.AbsolutePath.Equals(path, StringComparison.OrdinalIgnoreCase)
                || uri.AbsolutePath.StartsWith(path + "/", StringComparison.OrdinalIgnoreCase));
    }

    private static string BuildScript(string command, string href, long notAfterUnixMs)
    {
        var request = JsonSerializer.Serialize(new { command, href, notAfterUnixMs });
        return "(() => { const request = " + request + ";\n" + JavaScript + "\n})()";
    }

    private static bool TryParseOutcome(string json, out ScriptOutcome outcome)
    {
        outcome = default;
        if (json is null || json.Length == 0 || json.Length > MaxScriptResultLength) return false;
        try
        {
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !root.TryGetProperty("code", out var codeElement)
                || codeElement.ValueKind != JsonValueKind.String) return false;
            var code = codeElement.GetString();
            if (code is not ("observed" or "requested" or "invalidated" or "unavailable"
                or "wrong-origin" or "stale-document" or "disabled-control" or "unsupported-locale"
                or "expired" or "script-error")) return false;
            outcome = new ScriptOutcome(code, ReadBool(root, "dispatched"),
                ReadBool(root, "observed"), ReadBool(root, "noOp"));
            return true;
        }
        catch (JsonException) { return false; }
    }

    private static bool ReadBool(JsonElement root, string name)
        => root.TryGetProperty(name, out var value) && value.ValueKind is JsonValueKind.True or JsonValueKind.False
            && value.GetBoolean();

    private static string FormatOutcome(string requestedCommand, ScriptOutcome outcome)
    {
        var label = requestedCommand switch
        {
            "play" => "Play",
            "pause" => "Pause",
            "next" => "Next",
            "previous" => "Previous",
            _ => "Toggle"
        };

        if (outcome.Code == "observed")
            return outcome.NoOp ? $"{label} already active." : $"{label} observed.";
        if (outcome.Code == "requested")
            return $"{label} requested; result not observed.";
        if (outcome.Code == "expired") return "Control request expired; no action was sent.";
        if (outcome.Code is "invalidated" or "stale-document")
            return outcome.Dispatched
                ? "Control request invalidated; action may have occurred; no retry."
                : "Control request invalidated; no action was sent.";
        if (outcome.Code == "unavailable")
            return outcome.Dispatched
                ? "Control action outcome unknown; no retry."
                : "Player controls unavailable; no action was sent.";
        if (outcome.Code == "wrong-origin") return "Player controls unavailable; origin check failed.";
        if (outcome.Code == "unsupported-locale") return "Player controls unavailable in this locale.";
        if (outcome.Code == "disabled-control") return "Player control unavailable or disabled; no action was sent.";
        return outcome.Dispatched
            ? "Player control action outcome unknown; no retry."
            : "Player control action failed; no retry.";
    }

    private readonly record struct Request(string Command, string Href, ulong? NavigationId,
        int Generation, CancellationTokenSource Cancellation);

    private readonly record struct ScriptOutcome(string Code, bool Dispatched, bool Observed, bool NoOp);

    private const string JavaScript = """
let dispatched = false;
try {
  const requestDocument = document;
  const requestHref = request.href;
  const result = (code, observed = false, noOp = false) =>
    ({code, dispatched, observed, noOp});
  if (window !== window.top || location.origin !== 'https://music.youtube.com')
    return result('wrong-origin');
  if (location.href !== requestHref)
    return result('stale-document');
  const enabled = button => {
    if (!(button instanceof HTMLElement) || !button.isConnected
      || button.ownerDocument !== requestDocument) return false;
    if (button.matches(':disabled') || button.hasAttribute('disabled')
      || button.getAttribute('aria-disabled') === 'true') return false;
    let node = button;
    for (let depth = 0; node && depth < 64; depth++, node = node.parentElement) {
      if (node.hasAttribute('hidden') || node.hasAttribute('inert')
        || node.getAttribute('aria-hidden') === 'true') return false;
      const style = getComputedStyle(node);
      if (style.display === 'none' || style.visibility === 'hidden'
        || style.visibility === 'collapse') return false;
    }
    return node === null;
  };
  const acquire = () => {
    if (document !== requestDocument || location.href !== requestHref) return null;
    const bars = requestDocument.querySelectorAll('ytmusic-player-bar');
    const media = requestDocument.querySelectorAll('audio,video');
    const modals = requestDocument.querySelectorAll('dialog[open],[aria-modal=\"true\"]');
    if (modals.length > 16 || [...modals].some(enabled)) return null;
    if (bars.length !== 1 || media.length !== 1
      || !(media[0] instanceof HTMLMediaElement)) return null;
    const bar = bars[0];
    const groups = bar.querySelectorAll('[id=\"left-controls\"].left-controls.ytmusic-player-bar');
    if (groups.length !== 1) return null;
    const group = groups[0];
    const candidates = group.querySelectorAll('button,[role=\"button\"]');
    if (candidates.length > 16) return null;
    const controls = {play: [], pause: [], next: [], previous: []};
    for (const candidate of candidates) {
      const label = (candidate.getAttribute('aria-label') || '').trim().toLowerCase();
      if (Object.hasOwn(controls, label)) controls[label].push(candidate);
    }
    const locale = (requestDocument.documentElement.lang || '').toLowerCase();
    if (!(locale === 'en' || locale.startsWith('en-'))
      || controls.play.length + controls.pause.length !== 1
      || controls.next.length !== 1 || controls.previous.length !== 1
      || !bar.isConnected || !group.isConnected || !media[0].isConnected)
      return null;
    return {bar, group, element: media[0], controls, paused: media[0].paused};
  };
  const initial = acquire();
  if (!initial) return result('unavailable');
  if (!['play', 'pause', 'next', 'previous', 'toggle'].includes(request.command))
    return result('unavailable');
  const command = request.command === 'toggle'
    ? (initial.paused ? 'play' : 'pause') : request.command;
  const noOp = command === 'play' ? !initial.paused : command === 'pause' ? initial.paused : false;
  if (noOp) return result('observed', true, true);
  const current = acquire();
  if (!current || current.bar !== initial.bar || current.group !== initial.group
    || current.element !== initial.element) return result('stale-document');
  const button = current.controls[command][0];
  if (!enabled(button)) return result('disabled-control');
  if (Date.now() > request.notAfterUnixMs) return result('expired');
  const final = acquire();
  if (!final || final.bar !== current.bar || final.group !== current.group
    || final.element !== current.element) return result('stale-document');
  const finalButton = final.controls[command][0];
  if (!enabled(finalButton)) return result('disabled-control');
  if (Date.now() > request.notAfterUnixMs) return result('expired');
  dispatched = true;
  try {
    HTMLElement.prototype.click.call(finalButton);
  } catch {
    return result('script-error');
  }
  // ExecuteScriptAsync reports this synchronous result only. It does not await
  // a Promise, so a dispatched action is requested, not falsely observed.
  return result('requested');
} catch {
  return {code: 'script-error', dispatched, observed: false, noOp: false};
}
""";
}
