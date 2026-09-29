using System.Net;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Threading.Channels;

namespace Nativune;

internal enum ObsOverlayStartResult { Started, PrefixInUse /*183*/, AccessDenied /*5*/, Failed }

// Reason a stream ended; the hook state reports the last one.
internal enum ObsOverlayStreamEnd { Closed, Lifetime, Stopped }

// One static, non-stream response. Body null => empty body.
internal readonly record struct ObsOverlayResponse(int Status, string? ContentType, byte[]? Body);

/// <summary>
/// Opt-in loopback HTTP server for the OBS now-playing overlay: serves one page, its script and one
/// Server-Sent Events stream per browser source. Only bookkeeping and single-slot TryWrite run under
/// <c>_gate</c>; every network call and await happens outside it.
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

    private const string Origin = "http://localhost:47813";
    private const string ArtPrefix = "/art/";
    private const int MaxArtEntries = 2;
    private const long ArtRetryTicks = 10_000;
    private const string HtmlType = "text/html; charset=utf-8";
    private const string ScriptType = "text/javascript; charset=utf-8";
    private static readonly byte[] RetryBytes = Encoding.UTF8.GetBytes("retry: 3000\n\n");
    private static readonly byte[] HeartbeatBytes = Encoding.UTF8.GetBytes(": k\n\n");

    private readonly object _gate = new();
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
    private bool _stopping = true;
    private int _openStreams;

    private HttpListener? _listener;
    private CancellationTokenSource? _stopCts;
    private Task? _acceptLoop;
    private byte[] _html = [];
    private byte[] _script = [];
    private string _csp = "";

    internal ObsOverlayServer(bool hidePaused) => _hidePaused = hidePaused;

    internal bool IsRunning { get; private set; }
    internal int OpenStreams => Volatile.Read(ref _openStreams);
    internal event Action<int>? StreamsChanged;

    internal ObsOverlayStartResult Start()
    {
        if (IsRunning) return ObsOverlayStartResult.Started;

        byte[] html, script;
        try
        {
            html = ReadResource("Nativune.ObsOverlayPage.html");
            script = ReadResource("Nativune.ObsOverlayPage.js");
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
        _listener = listener;
        _stopCts = new CancellationTokenSource();
        lock (_gate)
        {
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
                if (!broadcast && !stream.NeedsInitial) continue;
                stream.NeedsInitial = false;
                json ??= sample.ToJson(now, _hidePaused);
                stream.Messages.Writer.TryWrite(json);
            }
            if (broadcast) _anchor = sample;
        }
    }

    internal void PublishNone()
    {
        var now = Environment.TickCount64;
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
                // A repeated none is an extra data event while stable (plan F9); only streams
                // still awaiting their initial state need it.
                if (alreadyNone && !stream.NeedsInitial) continue;
                stream.NeedsInitial = false;
                json ??= none.ToJson(now, _hidePaused);
                stream.Messages.Writer.TryWrite(json);
            }
        }
    }

    internal void MarkStale()
    {
        lock (_gate)
        {
            _latestStale = true;
        }
    }

    internal void SetHidePaused(bool hidePaused)
    {
        var now = Environment.TickCount64;
        lock (_gate)
        {
            if (_hidePaused == hidePaused) return;
            _hidePaused = hidePaused;
            if (_stopping || _latestStale || !_latest.HasMetadata) return;
            var json = _latest.ToJson(now, hidePaused);
            foreach (var stream in _streams)
            {
                stream.NeedsInitial = false;
                stream.Messages.Writer.TryWrite(json);
            }
            _anchor = _latest;
        }
    }

    partial void HookAppendScript(ref byte[] overlayJs);
    partial void HookFetchArtwork(string url, CancellationToken cancellation, ref Task<ArtworkPayload?>? fetch);
    partial void HookArtServed(string url);
    partial void HookStreamOpened();
    partial void HookStreamEnded(ObsOverlayStreamEnd reason);
    partial void HookWriteStarted(bool pending);

    private string Opaque(string domain, string value) =>
        Convert.ToHexStringLower(HMACSHA256.HashData(_wireKey, Encoding.UTF8.GetBytes(domain + "\0" + value)), 0, 8);

    // Caller holds _gate. Keeps the current and previous artwork only.
    private void RegisterArt(string key, string url)
    {
        foreach (var known in _art)
            if (known.Key == key) return;
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
            ObsOverlayResponse? answer = Route(request);
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
                    OpenStream(response);
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

    // Every guard before routing; returns a response to send, or null to continue with the path switch.
    private ObsOverlayResponse? Route(HttpListenerRequest request)
    {
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
        if (request.Url.Query.Length > 0)
            return new(400, null, null);
        return null;
    }

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

    private void OpenStream(HttpListenerResponse response)
    {
        var now = Environment.TickCount64;
        StreamEntry? stream = null;
        int count = 0;
        bool abort = false, full = false;
        lock (_gate)
        {
            if (_stopping) abort = true;
            else if (_streams.Count >= MaxStreams) full = true;
            else
            {
                var cts = CancellationTokenSource.CreateLinkedTokenSource(_stopCts!.Token);
                cts.CancelAfter(StreamLifetime);
                stream = new StreamEntry(response, cts);
                if (!_latestStale && now - _latest.CaptureTicks <= (long)FreshSampleAge.TotalMilliseconds)
                    stream.Messages.Writer.TryWrite(_latest.ToJson(now, _hidePaused));
                else
                    stream.NeedsInitial = true;
                _streams.Add(stream);
                count = _streams.Count;
                Volatile.Write(ref _openStreams, count);
                stream.Pump = PumpAsync(stream);
                _pumps.Add(stream.Pump);
            }
        }

        if (abort)
        {
            response.Abort();
            return;
        }
        if (full)
        {
            response.StatusCode = 503;
            SetStandardHeaders(response);
            response.ContentLength64 = 0;
            response.Close();
            return;
        }

        HookStreamOpened();
        StreamsChanged?.Invoke(count);
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
        try
        {
            response.StatusCode = 200;
            SetStandardHeaders(response);
            response.ContentType = "text/event-stream; charset=utf-8";
            response.SendChunked = true;
            response.KeepAlive = true;
            var output = response.OutputStream;
            await WriteAsync(output, RetryBytes, token).ConfigureAwait(false);
            var reader = stream.Messages.Reader;
            while (true)
            {
                bool got;
                try
                {
                    got = await reader.WaitToReadAsync(token).AsTask().WaitAsync(HeartbeatInterval, token).ConfigureAwait(false);
                }
                catch (TimeoutException)
                {
                    await WriteAsync(output, HeartbeatBytes, token).ConfigureAwait(false);
                    continue;
                }
                if (!got) break;
                if (reader.TryRead(out var json))
                    await WriteAsync(output, Encoding.UTF8.GetBytes(json.StartsWith(':') ? json : "data: " + json + "\n\n"), token).ConfigureAwait(false);
            }
        }
        catch (OperationCanceledException) when (token.IsCancellationRequested)
        {
            reason = _stopCts?.IsCancellationRequested == true ? ObsOverlayStreamEnd.Stopped : ObsOverlayStreamEnd.Lifetime;
        }
        catch
        {
            // An aborted write surfaces as HttpListenerException; classify by token state.
            reason = token.IsCancellationRequested
                ? (_stopCts?.IsCancellationRequested == true ? ObsOverlayStreamEnd.Stopped : ObsOverlayStreamEnd.Lifetime)
                : ObsOverlayStreamEnd.Closed;
        }
        finally
        {
            abortRegistration.Dispose();
            stream.Abort();
            stream.Cts.Dispose();
        }

        int count;
        lock (_gate)
        {
            _streams.Remove(stream);
            if (stream.Pump is { } pump) _pumps.Remove(pump);
            count = _streams.Count;
            Volatile.Write(ref _openStreams, count);
        }
        HookStreamEnded(reason);
        StreamsChanged?.Invoke(count);
        AppLog.Write(LogCategory, $"streams {count}");
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

    private sealed class ArtEntry(string key, string url)
    {
        internal string Key { get; } = key;
        internal string Url { get; } = url;
        internal ArtworkPayload? Payload { get; set; }
        internal TaskCompletionSource<ArtworkPayload?>? Flight { get; set; }
        internal long RetryAfterTicks { get; set; }
    }

    private sealed class StreamEntry(HttpListenerResponse response, CancellationTokenSource cts)
    {
        internal HttpListenerResponse Response { get; } = response;
        internal CancellationTokenSource Cts { get; } = cts;
        internal Channel<string> Messages { get; } = Channel.CreateBounded<string>(
            new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest, SingleReader = true, SingleWriter = false });
        internal bool NeedsInitial { get; set; }
        internal Task? Pump { get; set; }
        internal void Abort()
        {
            try { Response.Abort(); } catch { }
        }
    }
}
