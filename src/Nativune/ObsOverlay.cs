using System.Buffers.Binary;
using System.Collections.Frozen;
using System.IO.Compression;
using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Channels;

namespace Nativune;

internal enum ObsOverlayStartResult { Started, PrefixInUse /*183*/, AccessDenied /*5*/, Failed }

// Reason a stream ended; the hook state reports the last one.
internal enum ObsOverlayStreamEnd { Closed, Lifetime, Stopped }

// One static, non-stream response. Body null => empty body.
internal readonly record struct ObsOverlayResponse(int Status, string? ContentType, byte[]? Body);

// The designer preview's connection, for the current preview nonce (plan §2.6). Stopped: no current nonce, the
// server is stopping, or Connecting lasted longer than the 40 s reconnect window.
internal enum ObsPreviewState { Connecting, Open, Refused503, Stopped }

// Open = streams carrying any pv nonce (at most one once the current nonce has been admitted); Refused503 = the
// cumulative number of 503s answered to a request that carried the current nonce.
internal readonly record struct ObsOverlayPreview(string? Current, int Open, int Refused503, ObsPreviewState State);

// Point-in-time stream counts, published on every change (plan §2.5). Version increases with every change, so a
// consumer can discard an older snapshot. Real = streams fed by the player (including the designer's current-song
// preview: it needs the reader); StatusSources = Real streams that are not a preview (Settings "Connected to N
// sources"); ByLook = Real, non-preview streams by the look id in their query (saved or not; plain streams absent);
// MissingLooks = those whose id is not a saved look (the designer's own `draft` tag excluded).
internal sealed record ObsOverlayStreamCounts(
    long Version,
    int Total,
    int Real,
    int Sample,
    int StatusSources,
    IReadOnlyDictionary<string, int> ByLook,
    int MissingLooks,
    ObsOverlayPreview Preview);

#if NATIVUNE_DISCORD_TEST_HOOKS
// Hook-build diagnostics of the stream pumps (plan §2.2 A-LOOK.backpressure): what each stream still holds in its
// slots (Pending) and what its pump has taken out of them but not finished writing (InFlight).
internal readonly record struct ObsOverlayPumpSlots(bool Look, bool Data, bool Comment);

internal readonly record struct ObsOverlayPumpStream(
    string Kind, string? LookId, bool HasNonce, int LookSeq, ObsOverlayPumpSlots Pending, ObsOverlayPumpSlots InFlight);

internal sealed record ObsOverlayHookDiagnostics(
    string Epoch,
    bool ReduceMotion,
    int PumpHoldMs,
    long? RetainedManagedBytes,
    ObsOverlayStreamCounts Counts,
    bool DraftActive,
    string? DraftId,
    string? DraftName,
    string DraftBackdrop,
    IReadOnlyList<ObsOverlayPumpStream> Pump);
#endif

/// <summary>
/// Opt-in loopback HTTP server for the OBS now-playing overlay: serves one page, its script and one
/// Server-Sent Events stream per browser source. Every stream owns a look slot, a data slot (newest value wins) and
/// a one-token wake channel; only bookkeeping, slot writes and JSON assembly run under <c>_gate</c>, and every
/// network call and await happens outside it.
/// </summary>
internal sealed partial class ObsOverlayServer : IAsyncDisposable
{
    internal const int Port = 47813;
    internal const string Prefix = "http://localhost:47813/";
    internal const string HostHeader = "localhost:47813";
    internal static readonly Uri PageUri = new(Prefix);
    internal const int MaxStreams = 8;
    internal static readonly TimeSpan StreamLifetime = TimeSpan.FromMinutes(5);
    internal static readonly TimeSpan HeartbeatInterval = TimeSpan.FromSeconds(5);
    internal static readonly TimeSpan FreshSampleAge = TimeSpan.FromMilliseconds(1500);
    internal static readonly TimeSpan StopBudget = TimeSpan.FromSeconds(2);
    internal const string LogCategory = "obs";
    // The look id of the designer's own preview; a request with a pv nonce is always served as this stream.
    internal const string DraftId = "draft";

    private const string Origin = "http://localhost:47813";
    private const string ArtPrefix = "/art/";
    private const int MaxArtEntries = 2;
    private const long ArtRetryTicks = 10_000;
    private const string HtmlType = "text/html; charset=utf-8";
    private const string ScriptType = "text/javascript; charset=utf-8";
    private const int MaxQueryLength = 64;
    private const long SamplePeriodMs = 240_000;      // a sample song plays 240 s, then re-anchors at position 0
    private const long PreviewConnectingMs = 40_000;  // Connecting longer than this is Stopped
    private static readonly long HeartbeatMs = (long)HeartbeatInterval.TotalMilliseconds;
    private static readonly byte[] RetryBytes = Encoding.UTF8.GetBytes("retry: 3000\n\n");
    private static readonly byte[] HeartbeatBytes = Encoding.UTF8.GetBytes(": k\n\n");

    // The exact query grammar of plan §2.1, matched against the raw query (no decoding). One pattern per path;
    // the only optional parts are the ones the table allows, in its key order.
    private static readonly Regex s_pageQuery = new(
        @"^(?:\?(?:look=(?<look>[a-z0-9]{8}|draft)(?:&preview=1&pv=(?<pv>[a-z0-9]{8}))?(?:&sample=(?<sample>playing|paused|noart))?"
        + @"|sample=(?<sample>playing|paused|noart)))?\z",
        RegexOptions.CultureInvariant | RegexOptions.ExplicitCapture);
    private static readonly Regex s_eventsQuery = new(
        @"^(?:\?(?:look=(?<look>[a-z0-9]{8}|draft)(?:&pv=(?<pv>[a-z0-9]{8}))?(?:&sample=(?<sample>playing|paused|noart))?"
        + @"|sample=(?<sample>playing|paused|noart)))?\z",
        RegexOptions.CultureInvariant | RegexOptions.ExplicitCapture);
    private static readonly uint[] s_crcTable = BuildCrcTable();

    private readonly object _gate = new();
    // Serialises StreamsChanged deliveries so a consumer sees the snapshots in version order. Never taken under _gate.
    private readonly object _notifyGate = new();
    // Per-server key: wire ids and artwork keys are HMACs of the raw values, stable within this server object
    // and unlinkable to the video ID, the source URL or another session.
    private readonly byte[] _wireKey = RandomNumberGenerator.GetBytes(32);
    private readonly List<ArtEntry> _art = []; // current and previous artwork only, oldest first
    private readonly List<StreamEntry> _streams = [];
    private readonly HashSet<Task> _pumps = [];
    private ObsOverlaySnapshot _latest = ObsOverlaySnapshot.None(0);
    private bool _latestStale = true;
    private ObsOverlaySnapshot _anchor = ObsOverlaySnapshot.None(0);
    private bool _hidePaused;
    private bool _reduceMotion;
    private ObsLookState _looks;
    private ObsLook? _draft;                // the designer's draft (options normalised); null while no designer is open
    private string _draftBackdrop = "checker";
    private string? _currentNonce;          // the one admitted preview token; null while no designer is open
    private long _previewSinceTicks;        // the nonce became current, or its stream last ended: Connecting window start
    private bool _previewRefused;           // a request with the current nonce hit the cap and none was admitted since
    private int _previewRefusedCount;
    private string _epoch = "";
    private long _countsVersion;
    private long _notifiedVersion;
    private bool _stopping = true;
    private int _openStreams;
    private int _realStreams;
    private int _sampleStreams;
    private int _statusSources;

    private HttpListener? _listener;
    private CancellationTokenSource? _stopCts;
    private Task? _acceptLoop;
    private byte[] _html = [];
    private byte[] _script = [];
    private byte[] _sampleArt = [];
    private string _csp = "";

    internal ObsOverlayServer(ObsOverlayOptions options)
    {
        _hidePaused = options.HidePaused;
        _reduceMotion = options.ReduceMotion;
        _looks = options.Looks ?? ObsLookState.Empty;
    }

    internal bool IsRunning { get; private set; }
    internal int OpenStreams => Volatile.Read(ref _openStreams);
    internal int RealStreams => Volatile.Read(ref _realStreams);
    internal int SampleStreams => Volatile.Read(ref _sampleStreams);
    // Real streams that are not the designer's preview: what Settings reports as "Connected to N sources".
    internal int StatusSourceCount => Volatile.Read(ref _statusSources);
    internal IReadOnlyDictionary<string, int> StreamsByLook
    {
        get
        {
            lock (_gate)
            {
                return CountsLocked(bump: false).ByLook;
            }
        }
    }
    // Raised on a server thread, in version order, after every stream/preview/looks change.
    internal event Action<ObsOverlayStreamCounts>? StreamsChanged;

    internal ObsOverlayStreamCounts Counts()
    {
        lock (_gate)
        {
            return CountsLocked(bump: false);
        }
    }

    internal ObsPreviewState PreviewState(string? nonce)
    {
        lock (_gate)
        {
            return PreviewStateLocked(nonce, Environment.TickCount64);
        }
    }

    internal ObsOverlayStartResult Start()
    {
        if (IsRunning) return ObsOverlayStartResult.Started;

        byte[] html, script, sampleArt;
        try
        {
            html = ReadResource("Nativune.ObsOverlayPage.html");
            script = ReadResource("Nativune.ObsOverlayPage.js");
            sampleArt = SampleCoverPng();
        }
        catch (Exception ex)
        {
            AppLog.Write(LogCategory, "bind Failed");
            AppLog.Write(LogCategory, $"page resources unavailable ({ex.GetType().Name})");
            return ObsOverlayStartResult.Failed;
        }
        HookAppendScript(ref script);
        _csp = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self'"
            + "; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'";

        var listener = new HttpListener { IgnoreWriteExceptions = false };
        listener.Prefixes.Add(Prefix);
        try
        {
            listener.Start();
        }
        catch (Exception ex)
        {
            try { listener.Close(); } catch { }
            var result = ex is HttpListenerException hle
                ? hle.ErrorCode switch
                {
                    183 => ObsOverlayStartResult.PrefixInUse,
                    5 => ObsOverlayStartResult.AccessDenied,
                    _ => ObsOverlayStartResult.Failed,
                }
                : ObsOverlayStartResult.Failed;
            AppLog.Write(LogCategory, $"bind {result}");
            return result;
        }

        _html = html;
        _script = script;
        _sampleArt = sampleArt;
        _listener = listener;
        _stopCts = new CancellationTokenSource();
        lock (_gate)
        {
            _epoch = ObsLookIds.NewEpoch();
            _stopping = false;
        }
        IsRunning = true;
        _acceptLoop = Task.Run(() => AcceptLoopAsync(listener));
        AppLog.Write(LogCategory, "on");
        return ObsOverlayStartResult.Started;
    }

    internal async Task StopAsync()
    {
        // 1. Refuse admissions and publishes; snapshot the open streams.
        StreamEntry[] streams;
        Task[] pumps;
        bool wasStopping;
        lock (_gate)
        {
            wasStopping = _stopping;
            _stopping = true;
            streams = [.. _streams];
            pumps = [.. _pumps];
        }

        // 2. Cancel every stream token, then abort responses so blocked writes return.
        try { _stopCts?.Cancel(); } catch (ObjectDisposedException) { }
        foreach (var stream in streams) stream.Abort();

        // 3. Stop the listener; the pending GetContextAsync faults and the accept loop exits.
        var listener = _listener;
        _listener = null;
        if (listener is not null)
        {
            try { listener.Stop(); } catch { }
            try { listener.Close(); } catch { }
        }

        // 4. Wait for the accept loop and pumps within the budget.
        var waits = new List<Task>(pumps);
        if (_acceptLoop is { } accept) waits.Add(accept);
        _acceptLoop = null;
        try
        {
            await Task.WhenAll(waits).WaitAsync(StopBudget).ConfigureAwait(false);
        }
        catch
        {
            // A straggler holds only a dead response.
        }

        lock (_gate)
        {
            _art.Clear();
        }

        // 5. Detach subscribers and report stopped.
        StreamsChanged = null;
        var wasRunning = IsRunning;
        IsRunning = false;
        if (wasRunning && !wasStopping) AppLog.Write(LogCategory, "off");
    }

    public ValueTask DisposeAsync() => new(StopAsync());

    // Real streams only: a sample stream is synthetic and never sees the player's state (plan §2.5 isolation).
    internal void Publish(ObsOverlaySnapshot sample)
    {
        // The stream never carries the raw video ID or a Google URL: both leave here as opaque keys.
        var artUrl = sample.Artwork;
        var artKey = artUrl is null ? null : Opaque("art", artUrl);
        sample = sample with
        {
            Id = sample.Id is null ? null : Opaque("id", sample.Id),
            Artwork = artKey is null ? null : ArtPrefix + artKey,
        };

        var now = Environment.TickCount64;
        List<StreamEntry>? wake = null;
        lock (_gate)
        {
            if (_stopping) return;
            if (artUrl is not null) RegisterArt(artKey!, artUrl);
            _latest = sample;
            _latestStale = false;
            var broadcast = ObsOverlaySnapshot.ShouldBroadcast(_anchor, sample, now);
            string? json = null;
            foreach (var stream in _streams)
            {
                if (stream.Kind != StreamKind.Real) continue;
                if (!broadcast && !stream.NeedsInitial) continue;
                stream.NeedsInitial = false;
                json ??= sample.ToJson(now, _hidePaused);
                stream.PendingData = json;
                (wake ??= []).Add(stream);
            }
            if (broadcast) _anchor = sample;
        }
        WakeAll(wake);
    }

    internal void PublishNone()
    {
        var now = Environment.TickCount64;
        List<StreamEntry>? wake = null;
        lock (_gate)
        {
            if (_stopping) return;
            var alreadyNone = _anchor.State == ObsOverlayState.None;
            var none = ObsOverlaySnapshot.None(now);
            _latest = none;
            _latestStale = true;
            if (!alreadyNone) _anchor = none;
            string? json = null;
            foreach (var stream in _streams)
            {
                if (stream.Kind != StreamKind.Real) continue;
                // A repeated none is an extra data event while stable (plan F9); only streams
                // still awaiting their initial state need it.
                if (alreadyNone && !stream.NeedsInitial) continue;
                stream.NeedsInitial = false;
                json ??= none.ToJson(now, _hidePaused);
                stream.PendingData = json;
                (wake ??= []).Add(stream);
            }
        }
        WakeAll(wake);
    }

    internal void MarkStale()
    {
        lock (_gate)
        {
            _latestStale = true;
        }
    }

    // (a) Real streams: today's behaviour, quiet while the state is stale or has no metadata. (b) Independently, every
    // Sample stream and every pill-preset stream (plain or missing-fallback, either kind) gets a look with the new
    // setting, and Sample streams re-send their snapshot so the page re-evaluates paused visibility; that branch never
    // reads _latest. A saved look's Real stream gets nothing from (b): its own `paused` option governs.
    internal void SetHidePaused(bool hidePaused)
    {
        if (Volatile.Read(ref _hidePaused) == hidePaused) return;
        var probe = ProbeFonts();
        var now = Environment.TickCount64;
        List<StreamEntry>? wake = null;
        lock (_gate)
        {
            if (_hidePaused == hidePaused) return;
            _hidePaused = hidePaused;
            if (_stopping) return;
            foreach (var stream in _streams)
            {
                if (stream.Kind == StreamKind.Sample || IsPillPresetLocked(stream))
                {
                    stream.PendingLook = BuildLookLocked(stream, probe);
                    (wake ??= []).Add(stream);
                }
                if (stream.Kind == StreamKind.Sample) stream.PendingData = SampleJsonLocked(stream, now);
            }
            if (!_latestStale && _latest.HasMetadata)
            {
                var json = _latest.ToJson(now, hidePaused);
                foreach (var stream in _streams)
                {
                    if (stream.Kind != StreamKind.Real) continue;
                    stream.NeedsInitial = false;
                    stream.PendingData = json;
                    (wake ??= []).Add(stream);
                }
                _anchor = _latest;
            }
        }
        WakeAll(wake);
    }

    // The app's Reduce motion setting travels in every look message; every stream gets the new value.
    internal void SetReduceMotion(bool reduceMotion)
    {
        if (Volatile.Read(ref _reduceMotion) == reduceMotion) return;
        var probe = ProbeFonts();
        List<StreamEntry>? wake = null;
        lock (_gate)
        {
            if (_reduceMotion == reduceMotion) return;
            _reduceMotion = reduceMotion;
            if (_stopping) return;
            foreach (var stream in _streams)
            {
                stream.PendingLook = BuildLookLocked(stream, probe);
                (wake ??= []).Add(stream);
            }
        }
        WakeAll(wake);
    }

    // A durable commit or a reload replaced the saved looks: streams tagged with a changed, created or deleted id get
    // the look (a deleted or unknown id is the pill preset with missing: true) plus the latest data. Plain streams and
    // the designer's preview do not depend on the saved looks.
    internal void SetLooks(ObsLookState state)
    {
        ArgumentNullException.ThrowIfNull(state);
        var probe = new FontProbe();
        foreach (var look in state.Looks) probe.Add(look.Options);
        var now = Environment.TickCount64;
        List<StreamEntry>? wake = null;
        ObsOverlayStreamCounts counts;
        lock (_gate)
        {
            var previous = _looks;
            Volatile.Write(ref _looks, state);
            if (_stopping) return;
            string? latest = null;
            foreach (var stream in _streams)
            {
                if (stream.Nonce is not null || stream.LookId is not { } id) continue;
                if (Equals(previous.Find(id), state.Find(id))) continue;
                stream.PendingLook = BuildLookLocked(stream, probe);
                PushLatestLocked(stream, now, ref latest);
                (wake ??= []).Add(stream);
            }
            counts = SnapshotLocked();
        }
        WakeAll(wake);
        NotifyStreams(counts);
    }

    // The designer's draft. Both arguments null closes the designer: the draft and the current nonce are cleared and
    // every preview stream is detached. Otherwise the nonce becomes current (an earlier nonce's stream stays until the
    // new navigation is admitted; a null look leaves the nonce without a draft, served as the missing-look pill) and the
    // streams carrying the current nonce get the look plus the latest data.
    internal void SetDraftLook(ObsLook? look, string backdrop, string? nonce)
    {
        if (look is not null) look = look with { Options = ObsLookValidation.Normalize(look.Options) };
        if (!ObsLookIds.IsValid(nonce)) nonce = null;
        var normalizedBackdrop = ObsLookValidation.NormalizeBackdrop(backdrop);
        var probe = new FontProbe();
        probe.Add(look?.Options);
        var now = Environment.TickCount64;
        List<StreamEntry>? wake = null;
        ObsOverlayStreamCounts? counts = null;
        StreamEntry[] closing = [];
        lock (_gate)
        {
            if (_stopping) return;
            if (look is null && nonce is null)
            {
                var had = _draft is not null || _currentNonce is not null;
                Volatile.Write(ref _draft, null);
                Volatile.Write(ref _currentNonce, null);
                _previewRefused = false;
                closing = [.. _streams.Where(s => s.Nonce is not null)];
                if (had) counts = SnapshotLocked();
            }
            else
            {
                var changed = !string.Equals(nonce, _currentNonce, StringComparison.Ordinal);
                Volatile.Write(ref _draft, look);
                _draftBackdrop = normalizedBackdrop;
                Volatile.Write(ref _currentNonce, nonce);
                if (changed)
                {
                    _previewRefused = false;
                    _previewSinceTicks = now;
                }
                string? latest = null;
                foreach (var stream in _streams)
                {
                    if (nonce is null || !string.Equals(stream.Nonce, nonce, StringComparison.Ordinal)) continue;
                    stream.PendingLook = BuildLookLocked(stream, probe);
                    PushLatestLocked(stream, now, ref latest);
                    (wake ??= []).Add(stream);
                }
                if (changed) counts = SnapshotLocked();
            }
        }
        WakeAll(wake);
        if (counts is not null) NotifyStreams(counts);
        foreach (var stream in closing) Detach(stream);
    }

    partial void HookAppendScript(ref byte[] overlayJs);
    partial void HookFetchArtwork(string url, CancellationToken cancellation, ref Task<ArtworkPayload?>? fetch);
    partial void HookArtServed(string url);
    partial void HookStreamOpened();
    partial void HookStreamEnded(ObsOverlayStreamEnd reason);
    partial void HookWriteStarted(bool pending);

    private string Opaque(string domain, string value) =>
        Convert.ToHexStringLower(HMACSHA256.HashData(_wireKey, Encoding.UTF8.GetBytes(domain + "\0" + value)), 0, 8);

    // Caller holds _gate. Keeps the current and previous artwork only: a recurring key moves to the newest slot, so
    // the entry evicted next is always the older of the two (A, B, A, C keeps A for streams still on it).
    private void RegisterArt(string key, string url)
    {
        var index = _art.FindIndex(known => known.Key == key);
        if (index >= 0)
        {
            var known = _art[index];
            _art.RemoveAt(index);
            _art.Add(known);
            return;
        }
        if (_art.Count >= MaxArtEntries) _art.RemoveAt(0);
        _art.Add(new ArtEntry(key, url));
    }

    private static bool IsArtKey(string key)
    {
        if (key.Length != 16) return false;
        foreach (var c in key)
            if (c is not ((>= '0' and <= '9') or (>= 'a' and <= 'f'))) return false;
        return true;
    }

    private Task<ArtworkPayload?> FetchArtAsync(string url, CancellationToken cancellation)
    {
        Task<ArtworkPayload?>? hooked = null;
        HookFetchArtwork(url, cancellation, ref hooked);
        return hooked ?? CompactArtwork.FetchAsync(url, cancellation);
    }

    // GET /art/<key>: the one route that reaches YouTube's image servers, only for a URL the player published.
    // One fetch per key at a time; a failure is remembered for ArtRetryTicks so a page retry loop cannot hammer it.
    private async Task ServeArtAsync(HttpListenerResponse response, string key)
    {
        ArtEntry? entry = null;
        ArtworkPayload? payload = null;
        TaskCompletionSource<ArtworkPayload?>? flight = null;
        var owner = false;
        var known = false;
        var stop = _stopCts?.Token ?? CancellationToken.None;
        if (IsArtKey(key))
        {
            var now = Environment.TickCount64;
            lock (_gate)
            {
                if (_stopping)
                {
                    response.Abort();
                    return;
                }
                entry = _art.Find(e => e.Key == key);
                if (entry is not null)
                {
                    known = true;
                    if (entry.Payload is { } ready) payload = ready;
                    else if (entry.Flight is { } running) flight = running;
                    else if (now >= entry.RetryAfterTicks)
                    {
                        flight = entry.Flight = new TaskCompletionSource<ArtworkPayload?>(TaskCreationOptions.RunContinuationsAsynchronously);
                        owner = true;
                    }
                }
            }
        }

        if (!known)
        {
            await WriteStaticAsync(response, new(404, null, null), html: false).ConfigureAwait(false);
            return;
        }

        if (owner)
        {
            try
            {
                payload = await FetchArtAsync(entry!.Url, stop).ConfigureAwait(false);
            }
            catch
            {
                payload = null;
            }
            finally
            {
                lock (_gate)
                {
                    if (payload is not null) entry!.Payload = payload;
                    else entry!.RetryAfterTicks = Environment.TickCount64 + ArtRetryTicks;
                    entry.Flight = null;
                }
                flight!.TrySetResult(payload);
            }
        }
        else if (flight is not null)
        {
            payload = await flight.Task.ConfigureAwait(false);
        }

        if (payload is null)
        {
            await WriteStaticAsync(response, new(502, null, null), html: false).ConfigureAwait(false);
            return;
        }
        await WriteStaticAsync(response, new(200, payload.ContentType, payload.Bytes), html: false).ConfigureAwait(false);
        HookArtServed(entry!.Url);
    }

    private static byte[] ReadResource(string name)
    {
        using var source = Assembly.GetExecutingAssembly().GetManifestResourceStream(name)
            ?? throw new InvalidOperationException("Missing resource " + name);
        using var copy = new MemoryStream();
        source.CopyTo(copy);
        return copy.ToArray();
    }

    private async Task AcceptLoopAsync(HttpListener listener)
    {
        while (true)
        {
            HttpListenerContext context;
            try
            {
                context = await listener.GetContextAsync().ConfigureAwait(false);
            }
            catch
            {
                return; // Stop/Close: normal exit.
            }
            _ = Task.Run(() => HandleAsync(context));
        }
    }

    private async Task HandleAsync(HttpListenerContext context)
    {
        var response = context.Response;
        try
        {
            lock (_gate)
            {
                if (_stopping)
                {
                    response.Abort();
                    return;
                }
            }

            var request = context.Request;
            ObsOverlayResponse? answer = Route(request, out var query);
            if (answer is { } fixedResponse)
            {
                await WriteStaticAsync(response, fixedResponse, html: false).ConfigureAwait(false);
                return;
            }

            switch (request.Url!.AbsolutePath)
            {
                case "/":
                    await WriteStaticAsync(response, new(200, HtmlType, _html), html: true).ConfigureAwait(false);
                    break;
                case "/overlay.js":
                    await WriteStaticAsync(response, new(200, ScriptType, _script), html: false).ConfigureAwait(false);
                    break;
                case "/events":
                    OpenStream(response, query);
                    break;
                case "/art/sample":
                    await WriteStaticAsync(response, new(200, "image/png", _sampleArt), html: false).ConfigureAwait(false);
                    break;
                case var art when art.StartsWith(ArtPrefix, StringComparison.Ordinal):
                    await ServeArtAsync(response, art[ArtPrefix.Length..]).ConfigureAwait(false);
                    break;
                default:
                    await WriteStaticAsync(response, new(404, null, null), html: false).ConfigureAwait(false);
                    break;
            }
        }
        catch
        {
            response.Abort();
        }
    }

    // Every guard before routing; returns a response to send, or null to continue with the path switch. Only "/" and
    // "/events" take a query, and only the exact forms of plan §2.1 (anything else is 400). A request that carries a
    // well-formed pv is admitted only when it equals the current preview nonce; every other pv is 410 Gone.
    private ObsOverlayResponse? Route(HttpListenerRequest request, out ObsQuery query)
    {
        query = default;
        if (request.RemoteEndPoint is not { } ep || !IPAddress.IsLoopback(ep.Address))
            return new(403, null, null);
        var hosts = request.Headers.GetValues("Host");
        if (hosts is not { Length: 1 } || !string.Equals(hosts[0], HostHeader, StringComparison.Ordinal))
            return new(403, null, null);
        var fetchSite = request.Headers["Sec-Fetch-Site"];
        if (fetchSite is not null && fetchSite != "same-origin" && fetchSite != "none")
            return new(403, null, null);
        var origin = request.Headers["Origin"];
        if (origin is not null && origin != Origin)
            return new(403, null, null);
        if (request.HttpMethod != "GET")
            return new(405, null, null);
        if (request.HasEntityBody || request.Headers["Transfer-Encoding"] != null)
            return new(400, null, null);
        if (request.Url is null)
            return new(400, null, null);
        var path = request.Url.AbsolutePath;
        var raw = request.Url.Query;
        if (path is "/" or "/events")
        {
            if (!TryParseQuery(path, raw, out query))
                return new(400, null, null);
            if (query.Nonce is { } nonce && !IsCurrentNonce(nonce))
                return new(410, null, null);
        }
        else if (raw.Length > 0)
        {
            return new(400, null, null);
        }
        return null;
    }

    private static bool TryParseQuery(string path, string raw, out ObsQuery query)
    {
        query = default;
        if (raw.Length == 0) return true;
        if (raw.Length > MaxQueryLength) return false;
        var match = (path == "/" ? s_pageQuery : s_eventsQuery).Match(raw);
        if (!match.Success) return false;
        query = new ObsQuery(CapturedValue(match, "look"), CapturedValue(match, "pv"), CapturedValue(match, "sample"));
        return true;
    }

    private static string? CapturedValue(Match match, string name) =>
        match.Groups[name] is { Success: true } group ? group.Value : null;

    private bool IsCurrentNonce(string nonce) =>
        string.Equals(nonce, Volatile.Read(ref _currentNonce), StringComparison.Ordinal);

    private static void SetStandardHeaders(HttpListenerResponse response)
    {
        response.Headers["X-Content-Type-Options"] = "nosniff";
        response.Headers["Cache-Control"] = "no-store";
        response.Headers["Referrer-Policy"] = "no-referrer";
    }

    private async Task WriteStaticAsync(HttpListenerResponse response, ObsOverlayResponse answer, bool html)
    {
        response.StatusCode = answer.Status;
        SetStandardHeaders(response);
        if (html) response.Headers["Content-Security-Policy"] = _csp;
        if (answer.ContentType is not null) response.ContentType = answer.ContentType;
        var body = answer.Body ?? [];
        response.ContentLength64 = body.Length;
        if (body.Length > 0)
            await response.OutputStream.WriteAsync(body).ConfigureAwait(false);
        response.Close();
    }

    // Admission (plan §2.5, §2.6). A pv request is admitted only with the current nonce (else 410, nothing changes); its
    // admission first detaches every earlier preview stream (the previous navigation's, or a dead reconnect of this
    // one), so the designer never needs a second slot. The cap is checked after that: the 9th stream is 503.
    private void OpenStream(HttpListenerResponse response, ObsQuery query)
    {
        var now = Environment.TickCount64;
        var preview = query.Nonce is not null;
        var kind = query.Sample is null ? StreamKind.Real : StreamKind.Sample;
        var lookId = preview ? DraftId : query.Look;

        // The font lookup (DirectWrite) happens before the lock; the lock only assembles the look from the result.
        var probe = new FontProbe();
        probe.Add(preview
            ? Volatile.Read(ref _draft)?.Options
            : lookId is null ? null : Volatile.Read(ref _looks).Find(lookId)?.Options);

        StreamEntry? stream = null;
        List<StreamEntry>? retired = null;
        ObsOverlayStreamCounts? counts = null;
        var count = 0;
        var changedTotal = false;
        bool abort = false, full = false, gone = false;
        lock (_gate)
        {
            if (_stopping) abort = true;
            else if (preview && !string.Equals(query.Nonce, _currentNonce, StringComparison.Ordinal)) gone = true;
            else
            {
                var before = _streams.Count;
                if (preview) retired = DetachPreviewStreamsLocked();
                if (_streams.Count >= MaxStreams)
                {
                    full = true;
                    if (preview)
                    {
                        _previewRefused = true;
                        _previewRefusedCount++;
                    }
                }
                else
                {
                    var cts = CancellationTokenSource.CreateLinkedTokenSource(_stopCts!.Token);
                    cts.CancelAfter(StreamLifetime);
                    stream = new StreamEntry(response, cts, kind, lookId, query.Sample, preview ? query.Nonce : null, now)
                    {
                        HeartbeatDueTicks = now + HeartbeatMs,
                    };
                    stream.PendingLook = BuildLookLocked(stream, probe);
                    if (kind == StreamKind.Sample)
                    {
                        stream.SampleDueTicks = query.Sample == "paused" ? long.MaxValue : now + SamplePeriodMs;
                        stream.PendingData = SampleJsonLocked(stream, now);
                    }
                    else if (!_latestStale && now - _latest.CaptureTicks <= (long)FreshSampleAge.TotalMilliseconds)
                        stream.PendingData = _latest.ToJson(now, _hidePaused);
                    else
                        stream.NeedsInitial = true;
                    _streams.Add(stream);
                    if (preview) _previewRefused = false;
                    stream.Pump = PumpAsync(stream);
                    _pumps.Add(stream.Pump);
                }
                count = _streams.Count;
                changedTotal = count != before;
                if (stream is not null || retired is { Count: > 0 } || (full && preview)) counts = SnapshotLocked();
            }
        }

        if (retired is not null)
            foreach (var old in retired) old.Retire();
        if (abort)
        {
            response.Abort();
            return;
        }
        if (gone)
        {
            response.StatusCode = 410;
            SetStandardHeaders(response);
            response.ContentLength64 = 0;
            response.Close();
            return;
        }
        if (full)
        {
            response.StatusCode = 503;
            SetStandardHeaders(response);
            response.ContentLength64 = 0;
            response.Close();
        }
        else
        {
            HookStreamOpened();
            stream?.Wake(); // its first look (and the initial data) are already in the slots
        }
        if (counts is not null) NotifyStreams(counts);
        if (changedTotal) AppLog.Write(LogCategory, $"streams {count}");
    }

    // Caller holds _gate. Removes every stream that carries a pv nonce; the caller retires them after the lock.
    private List<StreamEntry> DetachPreviewStreamsLocked()
    {
        List<StreamEntry> detached = [];
        for (var i = _streams.Count - 1; i >= 0; i--)
        {
            if (_streams[i].Nonce is null) continue;
            var stream = _streams[i];
            stream.Detached = true;
            _streams.RemoveAt(i);
            detached.Add(stream);
        }
        return detached;
    }

    // Logical detach (plan §2.6): remove from the streams, count once, then retire the connection outside the lock. The
    // pump's own cleanup sees Detached and does not remove or count the stream again. Idempotent.
    private void Detach(StreamEntry stream)
    {
        ObsOverlayStreamCounts counts;
        int count;
        lock (_gate)
        {
            if (stream.Detached) return;
            stream.Detached = true;
            _streams.Remove(stream);
            count = _streams.Count;
            counts = SnapshotLocked();
        }
        stream.Retire();
        NotifyStreams(counts);
        AppLog.Write(LogCategory, $"streams {count}");
    }

    private async Task PumpAsync(StreamEntry stream)
    {
        // Leave the caller's lock before any network work.
        await Task.Yield();
        var response = stream.Response;
        var token = stream.Cts.Token;
        var reason = ObsOverlayStreamEnd.Closed;
        // A native send ignores the token once started; abort the response at lifetime/stop so a
        // write blocked behind a non-reading client returns. Registered here, outside lock(_gate).
        var abortRegistration = token.UnsafeRegister(static s => ((StreamEntry)s!).Abort(), stream);
        ObsOverlayStreamEnd Classify() =>
            stream.Detached ? ObsOverlayStreamEnd.Closed
            : token.IsCancellationRequested
                ? (_stopCts?.IsCancellationRequested == true ? ObsOverlayStreamEnd.Stopped : ObsOverlayStreamEnd.Lifetime)
                : ObsOverlayStreamEnd.Closed;
        try
        {
            response.StatusCode = 200;
            SetStandardHeaders(response);
            response.ContentType = "text/event-stream; charset=utf-8";
            response.SendChunked = true;
            response.KeepAlive = true;
            var output = response.OutputStream;
            await WriteAsync(output, RetryBytes, token).ConfigureAwait(false);
            stream.HeartbeatDueTicks = Environment.TickCount64 + HeartbeatMs;
            var signal = stream.Signal.Reader;
            while (true)
            {
                // (1) Sleep until a writer signals, or until the sample deadline or the heartbeat is due.
                var wait = Math.Max(0, Math.Min(stream.SampleDueTicks, stream.HeartbeatDueTicks) - Environment.TickCount64);
                try
                {
                    // (2) A timeout means due work; cancellation takes the abort path below.
                    if (!await signal.WaitToReadAsync(token).AsTask().WaitAsync(TimeSpan.FromMilliseconds(wait), token).ConfigureAwait(false))
                        break;
                }
                catch (TimeoutException)
                {
                }
                // (3) Drain the wake token before looking at the slots: a writer that sets a slot after this point
                // leaves a fresh token for the next iteration, so no wake is ever lost.
                signal.TryRead(out _);

                // (4)+(5) Due work regardless of the wake reason, then take the slots (look, data, comment) under the lock.
                string? look, data;
#if NATIVUNE_DISCORD_TEST_HOOKS
                string? comment;
#endif
                lock (_gate)
                {
                    var stamp = Environment.TickCount64;
                    if (stream.Kind == StreamKind.Sample && stamp >= stream.SampleDueTicks)
                    {
                        // The sample song ended: re-anchor at the current phase (position 0 at the due time).
                        stream.SampleDueTicks += ((stamp - stream.SampleDueTicks) / SamplePeriodMs + 1) * SamplePeriodMs;
                        stream.PendingData = SampleJsonLocked(stream, stamp);
                    }
                    look = stream.PendingLook;
                    stream.PendingLook = null;
                    data = stream.PendingData;
                    stream.PendingData = null;
#if NATIVUNE_DISCORD_TEST_HOOKS
                    comment = stream.PendingComment;
                    stream.PendingComment = null;
                    stream.InFlightLook = look;
                    stream.InFlightData = data;
                    stream.InFlightComment = comment;
#endif
                }

                var pending = look is not null || data is not null;
#if NATIVUNE_DISCORD_TEST_HOOKS
                pending |= comment is not null;
#endif
                if (!pending)
                {
                    if (Environment.TickCount64 >= stream.HeartbeatDueTicks)
                    {
                        await WriteAsync(output, HeartbeatBytes, token).ConfigureAwait(false);
                        stream.HeartbeatDueTicks = Environment.TickCount64 + HeartbeatMs;
                    }
                    continue;
                }

#if NATIVUNE_DISCORD_TEST_HOOKS
                Task? holdRelease;
                int hold;
                lock (_gate) { hold = _hookPumpHoldMs; holdRelease = _hookPumpRelease?.Task; }
                if (hold > 0 && holdRelease is not null)
                {
                    try { await holdRelease.WaitAsync(TimeSpan.FromMilliseconds(hold), token).ConfigureAwait(false); }
                    catch (TimeoutException) { }
                }
#endif
                // (6) Write outside the lock, in order: a look set at time t precedes any data set at t or later.
                if (look is not null)
                    await WriteAsync(output, Encoding.UTF8.GetBytes("event: look\ndata: " + look + "\n\n"), token).ConfigureAwait(false);
                if (data is not null)
                    await WriteAsync(output, Encoding.UTF8.GetBytes("data: " + data + "\n\n"), token).ConfigureAwait(false);
#if NATIVUNE_DISCORD_TEST_HOOKS
                if (comment is not null)
                    await WriteAsync(output, Encoding.UTF8.GetBytes(comment), token).ConfigureAwait(false);
                lock (_gate)
                {
                    stream.InFlightLook = null;
                    stream.InFlightData = null;
                    stream.InFlightComment = null;
                }
#endif
                stream.HeartbeatDueTicks = Environment.TickCount64 + HeartbeatMs;
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            reason = Classify();
        }
        catch
        {
            // An aborted write surfaces as HttpListenerException; classify by token state.
            reason = Classify();
        }
        finally
        {
            abortRegistration.Dispose();
            stream.Abort();
            stream.Cts.Dispose();
        }

        ObsOverlayStreamCounts? counts = null;
        var count = 0;
        lock (_gate)
        {
            if (stream.Pump is { } pump) _pumps.Remove(pump);
            // A detached stream was already removed and counted (Detach / admission); count each change once.
            if (!stream.Detached)
            {
                stream.Detached = true;
                _streams.Remove(stream);
                if (stream.Nonce is not null && string.Equals(stream.Nonce, _currentNonce, StringComparison.Ordinal))
                    _previewSinceTicks = Environment.TickCount64;
                count = _streams.Count;
                counts = SnapshotLocked();
            }
        }
        HookStreamEnded(reason);
        if (counts is not null)
        {
            NotifyStreams(counts);
            AppLog.Write(LogCategory, $"streams {count}");
        }
    }

    private async Task WriteAsync(Stream output, byte[] bytes, CancellationToken token)
    {
        HookWriteStarted(true);
        try
        {
            await output.WriteAsync(bytes, token).ConfigureAwait(false);
            await output.FlushAsync(token).ConfigureAwait(false);
        }
        finally
        {
            HookWriteStarted(false);
        }
    }

    private static void WakeAll(List<StreamEntry>? streams)
    {
        if (streams is null) return;
        foreach (var stream in streams) stream.Wake();
    }

    // Caller holds _gate. The look message for this stream at this moment (plan §2.3): the designer's draft for a
    // preview stream, the saved look for its id, else the pill preset (the plain stream, or missing: true for an
    // unknown, deleted or draft-without-designer id). Assigns the stream's next seq.
    private string BuildLookLocked(StreamEntry stream, FontProbe probe)
    {
        ObsLookOptions options;
        string? id;
        var missing = false;
        string? backdrop = null;
        if (stream.Nonce is not null && _draft is { } draft)
        {
            options = draft.Options;
            id = DraftId;
            backdrop = _draftBackdrop;
        }
        else if (stream.LookId is null)
        {
            options = ObsLookOptions.Preset(_hidePaused);
            id = null;
        }
        else if (stream.Nonce is null && _looks.Find(stream.LookId) is { } saved)
        {
            options = saved.Options;
            id = saved.Id;
        }
        else
        {
            options = ObsLookOptions.Preset(_hidePaused);
            id = stream.LookId;
            missing = true;
        }
        return ObsLookJson.WriteLookEvent(_epoch, ++stream.LookSeq, id, missing,
            stream.Kind == StreamKind.Sample ? "sample" : "real", options, _reduceMotion,
            probe.Available(options.Font), _hidePaused, backdrop);
    }

    // Caller holds _gate. Pill-preset streams read the global hide-when-paused setting from the look message.
    private bool IsPillPresetLocked(StreamEntry stream) =>
        stream.Nonce is not null
            ? _draft is null
            : stream.LookId is null || _looks.Find(stream.LookId) is null;

    // Caller holds _gate. The "+ latest data" of a look push: a sample stream re-sends its snapshot at the current
    // phase; a Real stream gets the player's latest state when there is a fresh one (as SetHidePaused does).
    private void PushLatestLocked(StreamEntry stream, long now, ref string? realJson)
    {
        if (stream.Kind == StreamKind.Sample)
        {
            stream.PendingData = SampleJsonLocked(stream, now);
            return;
        }
        if (_latestStale || !_latest.HasMetadata) return;
        stream.NeedsInitial = false;
        stream.PendingData = realJson ??= _latest.ToJson(now, _hidePaused);
    }

    // Caller holds _gate. The synthetic song at this stream's current phase: (now - open) mod 240 s. The paused
    // sample is always at position 84 (ObsOverlaySnapshot.Sample ignores the position for it).
    private string SampleJsonLocked(StreamEntry stream, long now)
    {
        var phase = (now - stream.OpenTicks) % SamplePeriodMs / 1000.0;
        return ObsOverlaySnapshot.Sample(stream.SampleState!, phase, now).ToJson(now, _hidePaused);
    }

    private FontProbe ProbeFonts()
    {
        var probe = new FontProbe();
        foreach (var look in Volatile.Read(ref _looks).Looks) probe.Add(look.Options);
        probe.Add(Volatile.Read(ref _draft)?.Options);
        return probe;
    }

    // Caller holds _gate. Recomputes the counts from the streams; with bump, publishes the volatile counters and
    // advances the version (every mutation of the stream set, the nonce or the saved looks does).
    private ObsOverlayStreamCounts CountsLocked(bool bump)
    {
        int real = 0, sample = 0, status = 0, missing = 0, open = 0;
        Dictionary<string, int>? byLook = null;
        foreach (var stream in _streams)
        {
            if (stream.Nonce is not null) open++;
            if (stream.Kind == StreamKind.Sample)
            {
                sample++;
                continue;
            }
            real++;
            if (stream.Nonce is not null) continue; // the designer's own preview is not an OBS source
            status++;
            if (stream.LookId is not { } id) continue;
            byLook ??= new Dictionary<string, int>(StringComparer.Ordinal);
            byLook[id] = byLook.GetValueOrDefault(id) + 1;
            if (id != DraftId && _looks.Find(id) is null) missing++;
        }
        var total = _streams.Count;
        if (bump)
        {
            Volatile.Write(ref _openStreams, total);
            Volatile.Write(ref _realStreams, real);
            Volatile.Write(ref _sampleStreams, sample);
            Volatile.Write(ref _statusSources, status);
            _countsVersion++;
        }
        IReadOnlyDictionary<string, int> map = byLook is null ? FrozenDictionary<string, int>.Empty : byLook;
        return new ObsOverlayStreamCounts(_countsVersion, total, real, sample, status, map, missing,
            new ObsOverlayPreview(_currentNonce, open, _previewRefusedCount,
                PreviewStateLocked(_currentNonce, Environment.TickCount64)));
    }

    private ObsOverlayStreamCounts SnapshotLocked() => CountsLocked(bump: true);

    // Caller holds _gate.
    private ObsPreviewState PreviewStateLocked(string? nonce, long now)
    {
        if (_stopping || nonce is null || !string.Equals(nonce, _currentNonce, StringComparison.Ordinal))
            return ObsPreviewState.Stopped;
        foreach (var stream in _streams)
            if (string.Equals(stream.Nonce, nonce, StringComparison.Ordinal)) return ObsPreviewState.Open;
        if (_previewRefused) return ObsPreviewState.Refused503;
        return now - _previewSinceTicks > PreviewConnectingMs ? ObsPreviewState.Stopped : ObsPreviewState.Connecting;
    }

    // Deliveries are serialised and version-checked: a snapshot older than one already delivered is dropped, so a
    // consumer that enqueues each delivery sees the state only move forward. The handler must not block.
    private void NotifyStreams(ObsOverlayStreamCounts counts)
    {
        var handler = StreamsChanged;
        if (handler is null) return;
        lock (_notifyGate)
        {
            if (counts.Version <= _notifiedVersion) return;
            _notifiedVersion = counts.Version;
            try
            {
                handler(counts);
            }
            catch (Exception ex)
            {
                AppLog.Write(LogCategory, $"streams handler failed ({ex.GetType().Name})");
            }
        }
    }

    // The synthetic cover for /art/sample: 256 x 256 RGB, a diagonal two-colour gradient with a white eighth-note glyph.
    // Built once at Start() from constants only, so every start produces the same pixels.
    private static byte[] SampleCoverPng()
    {
        const int size = 256;
        var raw = new byte[size * (1 + size * 3)];
        for (var y = 0; y < size; y++)
        {
            var row = y * (1 + size * 3);
            for (var x = 0; x < size; x++)
            {
                var t = (x + y) / (2.0 * (size - 1));
                var r = 47 + (192 - 47) * t;
                var g = 79 + (42 - 79) * t;
                var b = 216 + (98 - 216) * t;
                var glyph = NoteCoverage(x + 0.5, y + 0.5) * 0.92;
                raw[row + 1 + x * 3] = (byte)Math.Round(r + (255 - r) * glyph);
                raw[row + 2 + x * 3] = (byte)Math.Round(g + (255 - g) * glyph);
                raw[row + 3 + x * 3] = (byte)Math.Round(b + (255 - b) * glyph);
            }
        }

        byte[] compressed;
        using (var buffer = new MemoryStream())
        {
            using (var zlib = new ZLibStream(buffer, CompressionLevel.Optimal, leaveOpen: true)) zlib.Write(raw);
            compressed = buffer.ToArray();
        }
        var header = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(0), size);
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), size);
        header[8] = 8; // bit depth
        header[9] = 2; // truecolour; compression, filter and interlace stay 0
        using var png = new MemoryStream();
        png.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        WritePngChunk(png, "IHDR", header);
        WritePngChunk(png, "IDAT", compressed);
        WritePngChunk(png, "IEND", []);
        return png.ToArray();
    }

    // Antialiased coverage (0..1) of the note glyph at a pixel centre: a tilted ellipse head, a stem on its right
    // edge and a thick diagonal flag from the stem's top.
    private static double NoteCoverage(double px, double py)
    {
        const double cos = 0.9396926207859084, sin = -0.3420201433256687; // head tilted 20 degrees
        double dx = px - 100, dy = py - 184;
        double u = dx * cos + dy * sin, v = -dx * sin + dy * cos;
        var head = (Math.Sqrt(u * u / (38 * 38) + v * v / (28 * 28)) - 1) * 28;

        double qx = Math.Abs(px - 133) - 8, qy = Math.Abs(py - 119) - 67;
        var stem = Math.Sqrt(Math.Max(qx, 0) * Math.Max(qx, 0) + Math.Max(qy, 0) * Math.Max(qy, 0)) + Math.Min(Math.Max(qx, qy), 0);

        double abx = 186 - 141, aby = 118 - 58;
        var along = Math.Clamp(((px - 141) * abx + (py - 58) * aby) / (abx * abx + aby * aby), 0, 1);
        double cx = 141 + abx * along - px, cy = 58 + aby * along - py;
        var flag = Math.Sqrt(cx * cx + cy * cy) - 11;

        return Math.Clamp(0.5 - Math.Min(head, Math.Min(stem, flag)), 0, 1);
    }

    private static void WritePngChunk(Stream png, string type, ReadOnlySpan<byte> data)
    {
        Span<byte> word = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(word, data.Length);
        png.Write(word);
        var name = Encoding.ASCII.GetBytes(type);
        png.Write(name);
        png.Write(data);
        BinaryPrimitives.WriteUInt32BigEndian(word, Crc32(Crc32(0xFFFFFFFF, name), data) ^ 0xFFFFFFFF);
        png.Write(word);
    }

    private static uint Crc32(uint crc, ReadOnlySpan<byte> data)
    {
        foreach (var b in data) crc = s_crcTable[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc;
    }

    private static uint[] BuildCrcTable()
    {
        var table = new uint[256];
        for (uint n = 0; n < 256; n++)
        {
            var c = n;
            for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
            table[n] = c;
        }
        return table;
    }

#if NATIVUNE_DISCORD_TEST_HOOKS
    // command-obs-pump-hold <ms>: every pump that has taken something out of its slots waits this long before it
    // writes (0 releases). While it waits the values are "in flight" and later pushes accumulate in the slots only.
    private int _hookPumpHoldMs;
    private TaskCompletionSource? _hookPumpRelease;
    private long? _hookRetainedManagedBytes;

    internal void HookPumpHold(int ms)
    {
        TaskCompletionSource? previous;
        lock (_gate)
        {
            previous = _hookPumpRelease;
            _hookPumpHoldMs = Math.Clamp(ms, 0, 60_000);
            _hookPumpRelease = _hookPumpHoldMs > 0 ? new(TaskCreationOptions.RunContinuationsAsynchronously) : null;
        }
        previous?.TrySetResult(); // Also releases a pump already inside the hold, not just its next iteration.
    }

    // Explicit hook-only barrier: private bytes include JIT/native allocations and uncollected JSON, not retained slots.
    // Never collect during ordinary snapshots (or under _gate); the harness warms the same workload before comparing.
    internal void HookCollectManagedBytes()
    {
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        var bytes = GC.GetTotalMemory(true);
        lock (_gate) _hookRetainedManagedBytes = bytes;
    }

    internal ObsOverlayHookDiagnostics HookDiagnostics()
    {
        lock (_gate)
        {
            var pump = new List<ObsOverlayPumpStream>(_streams.Count);
            foreach (var stream in _streams)
                pump.Add(new ObsOverlayPumpStream(
                    stream.Kind == StreamKind.Sample ? "sample" : "real", stream.LookId, stream.Nonce is not null, stream.LookSeq,
                    new ObsOverlayPumpSlots(stream.PendingLook is not null, stream.PendingData is not null, stream.PendingComment is not null),
                    new ObsOverlayPumpSlots(stream.InFlightLook is not null, stream.InFlightData is not null, stream.InFlightComment is not null)));
            return new ObsOverlayHookDiagnostics(_epoch, _reduceMotion, Volatile.Read(ref _hookPumpHoldMs), _hookRetainedManagedBytes,
                CountsLocked(bump: false), _draft is not null, _draft is null ? null : DraftId, _draft?.Name, _draftBackdrop, pump);
        }
    }
#endif

    private enum StreamKind { Real, Sample }

    // The parsed query of "/" or "/events": look id or null, pv nonce or null, sample state or null.
    private readonly record struct ObsQuery(string? Look, string? Nonce, string? Sample);

    // Font availability answered before the lock: one DirectWrite lookup per distinct family per push. A family that
    // was not probed (the state changed in between) is looked up on the spot.
    private sealed class FontProbe
    {
        private readonly Dictionary<string, bool> _known = new(StringComparer.Ordinal);

        internal void Add(ObsLookOptions? options)
        {
            if (options?.Font is { } font && !_known.ContainsKey(font)) _known[font] = SystemFonts.IsInstalled(font);
        }

        internal bool Available(string? font) =>
            font is not null && (_known.TryGetValue(font, out var installed) ? installed : SystemFonts.IsInstalled(font));
    }

    private sealed class ArtEntry(string key, string url)
    {
        internal string Key { get; } = key;
        internal string Url { get; } = url;
        internal ArtworkPayload? Payload { get; set; }
        internal TaskCompletionSource<ArtworkPayload?>? Flight { get; set; }
        internal long RetryAfterTicks { get; set; }
    }

    // One SSE connection. Real streams are fed by the player, Sample streams by the sample table; LookId is the tag of
    // the look it serves (null = plain, DraftId for the designer's preview), Nonce the pv token it was admitted with.
    // The slots and LookSeq belong to _gate; the pump owns SampleDueTicks/HeartbeatDueTicks after admission.
    private sealed class StreamEntry(
        HttpListenerResponse response, CancellationTokenSource cts, StreamKind kind, string? lookId, string? sampleState,
        string? nonce, long openTicks)
    {
        internal HttpListenerResponse Response { get; } = response;
        internal CancellationTokenSource Cts { get; } = cts;
        internal StreamKind Kind { get; } = kind;
        internal string? LookId { get; } = lookId;
        internal string? SampleState { get; } = sampleState;
        internal string? Nonce { get; } = nonce;
        internal long OpenTicks { get; } = openTicks;
        internal long SampleDueTicks { get; set; } = long.MaxValue; // Real and paused samples never come due
        internal long HeartbeatDueTicks { get; set; }
        internal string? PendingLook { get; set; }
        internal string? PendingData { get; set; }
        internal bool NeedsInitial { get; set; }
        internal int LookSeq { get; set; }
        internal volatile bool Detached;
        internal Task? Pump { get; set; }
        // One token: repeated wakes coalesce; TryWrite neither throws nor blocks, and fails quietly once completed.
        internal Channel<bool> Signal { get; } = Channel.CreateBounded<bool>(
            new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest });
#if NATIVUNE_DISCORD_TEST_HOOKS
        // Hook builds: a raw SSE comment slot (command-obs-burst) and what the pump has taken out but not yet written.
        internal string? PendingComment;
        internal string? InFlightLook, InFlightData, InFlightComment;
#endif
        internal void Wake() => Signal.Writer.TryWrite(true);

        internal void Abort()
        {
            try { Response.Abort(); } catch { }
        }

        // Ends the stream from outside its pump: wakes an idle pump (the channel completes), cancels a held or waiting
        // one and aborts a blocked write.
        internal void Retire()
        {
            Signal.Writer.TryComplete();
            try { Cts.Cancel(); } catch (ObjectDisposedException) { }
            Abort();
        }
    }
}
