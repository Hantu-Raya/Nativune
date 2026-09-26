using System.Buffers;
using System.Buffers.Binary;
using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using System.Threading.Channels;

namespace Nativune;

/// <summary>
/// Optional Discord Rich Presence over the local discord-ipc named pipe. Owns no WebView or playback state:
/// the host feeds validated observations and options on the UI thread; all IPC runs on one background
/// session task. Never logs or persists activity content, URLs, frames or READY user data.
/// </summary>
internal sealed class DiscordPresence : IAsyncDisposable
{
    // Public Discord application (client) id. Empty until the owner's Developer Portal app exists,
    // which keeps an enabled feature at Status Unavailable with no pipe work.
    internal const string ApplicationId = "";

    private const string LogCategory = "discord";
    private const int OpHandshake = 0, OpFrame = 1, OpClose = 2, OpPing = 3, OpPong = 4;
    private const int MaxFrameBytes = 64 * 1024;
    private const int MaxJsonDepth = 16;
    private const int PipeCount = 10;
    private const int ConnectTimeoutMs = 250;
    private const int ReadyTimeoutMs = 2000;
    private const int PassDeadlineMs = 5000;
    private const int FrameCompletionMs = 5000;
    private const int WriteDeadlineMs = 1000;
    private const int AckTimeoutMs = 5000;
    private const int DebounceMs = 1000;
    private const int DebounceMaxMs = 2000;
    private const int StopDeadlineMs = 1000;
    private const long StableResetMs = 30_000;
    private const double ReanchorDriftSeconds = 2.0;
    private const int MaxTextChars = 128, MaxTextBytes = 128, MaxLinkChars = 512;
    private const string ButtonLabel = "Open in YouTube Music";
    private const string FallbackLargeImage = "nativune";
    private static readonly int[] BackoffSeconds = [2, 5, 10, 30, 60];
    private static readonly JsonDocumentOptions ParseOptions = new() { MaxDepth = MaxJsonDepth };

    private readonly DiscordPresenceEnvironment _environment;
    private readonly SynchronizationContext? _context;
    private readonly object _gate = new();

    // Guarded by _gate.
    private DiscordPresenceOptions _options = DiscordPresenceOptions.Default;
    private DiscordTrackObservation? _observation;
    private string? _itemTitle, _itemTrackUrl, _itemArt, _previousItemArt;
    private long? _pausedSinceMs;
    private DateTimeOffset? _anchorStart;
    private double _anchorDuration;
    private Session? _session;
    private Task? _stopTask;
    private bool _stopped;
    private volatile DiscordPresenceStatus _status = DiscordPresenceStatus.Off;
    private volatile bool _ready;

    internal DiscordPresence(DiscordPresenceEnvironment environment)
    {
        _environment = environment ?? throw new ArgumentNullException(nameof(environment));
        _context = SynchronizationContext.Current;
    }

    internal DiscordPresenceStatus Status => _status;

    internal bool NeedsSnapshot => _ready && _options.Enabled && !_stopped;

    internal event EventHandler? StatusChanged;

    private bool HasApplicationId => !string.IsNullOrEmpty(_environment.ApplicationId);

    internal void ApplyOptions(DiscordPresenceOptions options)
    {
        lock (_gate)
        {
            if (_stopped) return;
            var wasEnabled = _options.Enabled;
            _options = options;
            if (!options.Enabled)
            {
                ForgetTrackLocked();
                StopSessionLocked();
                if (wasEnabled) AppLog.Write(LogCategory, "discord: disabled");
                SetStatus(null, DiscordPresenceStatus.Off);
                return;
            }
            if (!HasApplicationId)
            {
                StopSessionLocked();
                SetStatus(null, DiscordPresenceStatus.Unavailable);
                return;
            }
            if (_session is { StopRequested: false } running)
            {
                running.Signal(); // status line / button change alters the desired payload
                return;
            }
            AppLog.Write(LogCategory, "discord: enabled");
            var previous = _session?.Task ?? Task.CompletedTask;
            var session = new Session();
            _session = session;
            SetStatus(null, DiscordPresenceStatus.Connecting);
            session.Task = Task.Run(() => RunSessionAsync(session, previous));
        }
    }

    internal void Observe(DiscordTrackObservation? observation)
    {
        lock (_gate)
        {
            if (_stopped || !_options.Enabled || _session is not { StopRequested: false } session) return;
            if (observation is null)
                ForgetTrackLocked();
            else
                TrackLocked(observation, Environment.TickCount64);
            session.Signal();
        }
    }

    internal Task StopAsync()
    {
        lock (_gate)
        {
            if (_stopTask is not null) return _stopTask;
            _stopped = true;
            ForgetTrackLocked();
            var task = _session?.Task ?? Task.CompletedTask;
            StopSessionLocked();
            _stopTask = WaitBoundedAsync(task);
            return _stopTask;
        }
    }

    public ValueTask DisposeAsync() => new(StopAsync());

    private static async Task WaitBoundedAsync(Task task)
    {
        try { await Task.WhenAny(task, Task.Delay(StopDeadlineMs + 100)).ConfigureAwait(false); }
        catch (Exception) { }
    }

    // ---------- UI-thread state (under _gate) ----------

    private void ForgetTrackLocked()
    {
        _observation = null;
        _itemTitle = _itemTrackUrl = _itemArt = _previousItemArt = null;
        _pausedSinceMs = null;
        _anchorStart = null;
    }

    private void TrackLocked(DiscordTrackObservation o, long nowMs)
    {
        var itemChanged = _itemTitle is null
            || !string.Equals(_itemTitle, o.Title, StringComparison.Ordinal)
            || (_itemTrackUrl is not null && o.TrackUrl is not null && !string.Equals(_itemTrackUrl, o.TrackUrl, StringComparison.Ordinal));
        if (itemChanged)
        {
            _previousItemArt = _itemArt; // never carry the prior item's art into the new item
            _itemTitle = o.Title;
            _itemTrackUrl = o.TrackUrl;
            _anchorStart = null;
        }
        else if (o.TrackUrl is not null)
        {
            _itemTrackUrl = o.TrackUrl;
        }
        _itemArt = o.ArtworkUrl;

        // Pause deadline starts at the first paused observation of an item; late metadata does not restart it.
        // An ended item clears immediately (BuildDesired); it never starts the pause deadline.
        if (o.Paused && !o.Ended) { if (_pausedSinceMs is null || itemChanged) _pausedSinceMs = nowMs; }
        else _pausedSinceMs = null;

        if (o is { ClockConfirmed: true, Paused: false, Ended: false, Seeking: false, PlaybackRate: 1.0 }
            && o.DurationSeconds is double duration && double.IsFinite(duration) && duration > 0
            && o.PositionSeconds is double position && double.IsFinite(position) && position >= 0 && position <= duration + 1)
        {
            var candidate = o.SampleUtc - TimeSpan.FromSeconds(position);
            if (_anchorStart is not DateTimeOffset anchor
                || Math.Abs(_anchorDuration - duration) > 0.5
                || Math.Abs((candidate - anchor).TotalSeconds) > ReanchorDriftSeconds)
            {
                _anchorStart = candidate;
                _anchorDuration = duration;
            }
        }
        else
        {
            _anchorStart = null; // resume/seek/rate change re-anchors from the next confirmed sample
        }
        _observation = o;
    }

    // Returns the normalized activity JSON, or null when the card must be cleared. Also reports the next
    // monotonic time at which the answer changes by itself (pause expiry).
    private string? BuildDesired(long nowMs, out long? changesAtMs)
    {
        lock (_gate)
        {
            changesAtMs = null;
            var o = _observation;
            if (o is null || o.Ended || !_options.Enabled) return null;
            if (o.Paused && _pausedSinceMs is long since)
            {
                var expiry = since + (long)_environment.PauseTimeout.TotalMilliseconds;
                if (nowMs >= expiry) return null;
                changesAtMs = expiry;
            }
            var art = CompactArtwork.IsAllowedUrl(o.ArtworkUrl)
                && !string.Equals(o.ArtworkUrl, _previousItemArt, StringComparison.Ordinal) ? o.ArtworkUrl : null;
            return BuildActivityJson(o, _options, art, o.Paused ? null : _anchorStart, _anchorDuration);
        }
    }

    // ---------- Activity payload ----------

    internal static string? BuildActivityJson(DiscordTrackObservation o, DiscordPresenceOptions options, string? artwork, DateTimeOffset? start, double durationSeconds)
    {
        var details = NormalizeText(o.Title, "Track: ");
        if (details is null) return null; // a missing title clears rather than manufacturing a song
        var state = NormalizeText(o.Artist, "Artist: ");
        var album = NormalizeText(o.Album, "Album: ");
        var trackUrl = IsAllowedMusicLink(o.TrackUrl) ? o.TrackUrl : null;
        var artistUrl = state is not null && IsAllowedMusicLink(o.ArtistUrl) ? o.ArtistUrl : null;
        var albumUrl = IsAllowedMusicLink(o.AlbumUrl) ? o.AlbumUrl : null;
        var displayType = options.StatusLine switch
        {
            DiscordStatusLine.Title => 2,
            DiscordStatusLine.AppName => 0,
            _ => state is null ? 0 : 1
        };

        var buffer = new ArrayBufferWriter<byte>(1024);
        using (var w = new Utf8JsonWriter(buffer))
        {
            w.WriteStartObject();
            w.WriteNumber("type", 2);
            w.WriteNumber("status_display_type", displayType);
            w.WriteString("details", details);
            if (trackUrl is not null) w.WriteString("details_url", trackUrl);
            if (state is not null) w.WriteString("state", state);
            if (artistUrl is not null) w.WriteString("state_url", artistUrl);
            if (start is DateTimeOffset s && durationSeconds > 0)
            {
                w.WriteStartObject("timestamps");
                w.WriteNumber("start", ToDiscordWireTimestamp(s));
                w.WriteNumber("end", ToDiscordWireTimestamp(s + TimeSpan.FromSeconds(durationSeconds)));
                w.WriteEndObject();
            }
            w.WriteStartObject("assets");
            w.WriteString("large_image", artwork ?? FallbackLargeImage);
            if (album is not null) w.WriteString("large_text", album);
            if (album is not null && albumUrl is not null) w.WriteString("large_url", albumUrl);
            if (o.Paused)
            {
                w.WriteString("small_image", "pause");
                w.WriteString("small_text", "Paused");
            }
            else if (o.RepeatOne)
            {
                w.WriteString("small_image", "repeat-one");
                w.WriteString("small_text", "Repeat one");
            }
            w.WriteEndObject();
            if (options.ShowOpenButton && trackUrl is not null)
            {
                w.WriteStartArray("buttons");
                w.WriteStartObject();
                w.WriteString("label", ButtonLabel);
                w.WriteString("url", trackUrl);
                w.WriteEndObject();
                w.WriteEndArray();
            }
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    // Single place that decides Discord's wire time unit. Unix seconds per the current RPC example;
    // unverified against the real client (release prerequisite).
    internal static long ToDiscordWireTimestamp(DateTimeOffset instant) => instant.ToUnixTimeSeconds();

    // Trim, collapse whitespace, drop control characters and invalid UTF-16; 2..128 chars and <= 128 UTF-8
    // bytes without splitting surrogate pairs. A genuine 1-character value gets a readable role prefix.
    internal static string? NormalizeText(string? raw, string rolePrefix)
    {
        if (string.IsNullOrEmpty(raw)) return null;
        var cleaned = Clean(raw);
        if (cleaned.Length == 0) return null;
        if (cleaned.EnumerateRunes().Count() < 2) cleaned = rolePrefix + cleaned;

        var sb = new StringBuilder(Math.Min(cleaned.Length, MaxTextChars));
        var bytes = 0;
        foreach (var rune in cleaned.EnumerateRunes())
        {
            if (sb.Length + rune.Utf16SequenceLength > MaxTextChars || bytes + rune.Utf8SequenceLength > MaxTextBytes) break;
            sb.Append(rune.ToString());
            bytes += rune.Utf8SequenceLength;
        }
        var result = sb.ToString().TrimEnd();
        return result.Length >= 2 ? result : null;

        static string Clean(string value)
        {
            var sb = new StringBuilder(Math.Min(value.Length, 1024));
            var pendingSpace = false;
            var index = 0;
            while (index < value.Length && sb.Length < 1024)
            {
                if (Rune.DecodeFromUtf16(value.AsSpan(index), out var rune, out var consumed) != OperationStatus.Done)
                {
                    index += Math.Max(consumed, 1); // drop lone surrogates
                    continue;
                }
                index += consumed;
                if (Rune.IsWhiteSpace(rune)) { pendingSpace = sb.Length > 0; continue; }
                if (Rune.IsControl(rune)) continue;
                var category = Rune.GetUnicodeCategory(rune);
                if (category is System.Globalization.UnicodeCategory.LineSeparator or System.Globalization.UnicodeCategory.ParagraphSeparator) continue;
                if (pendingSpace) { sb.Append(' '); pendingSpace = false; }
                sb.Append(rune.ToString());
            }
            return sb.ToString();
        }
    }

    // Absolute https://music.youtube.com (default port, no userinfo/fragment) with /watch?v=<11> or
    // /channel/<id> or /browse/<id>. Never truncated or rewritten.
    internal static bool IsAllowedMusicLink(string? value)
    {
        if (value is not { Length: > 0 and <= MaxLinkChars } || value.Contains('#')) return false;
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)) return false;
        if (uri.Scheme != Uri.UriSchemeHttps || !uri.IsDefaultPort || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0) return false;
        if (!string.Equals(uri.Host, "music.youtube.com", StringComparison.OrdinalIgnoreCase)) return false;
        var path = uri.AbsolutePath;
        var query = uri.Query;
        if (path == "/watch")
            return query.Length == 14 && query.StartsWith("?v=", StringComparison.Ordinal) && IsIdChars(query.AsSpan(3), 11, 11);
        if (query.Length != 0) return false;
        if (path.StartsWith("/channel/", StringComparison.Ordinal)) return IsIdChars(path.AsSpan(9), 1, 128);
        if (path.StartsWith("/browse/", StringComparison.Ordinal)) return IsIdChars(path.AsSpan(8), 1, 128);
        return false;

        static bool IsIdChars(ReadOnlySpan<char> id, int min, int max)
        {
            if (id.Length < min || id.Length > max) return false;
            foreach (var c in id)
                if (!(char.IsAsciiLetterOrDigit(c) || c is '-' or '_')) return false;
            return true;
        }
    }

    // ---------- Status ----------

    // session == null: caller is the UI (holds _gate). Otherwise only the current session may change status.
    private void SetStatus(Session? session, DiscordPresenceStatus status)
    {
        lock (_gate)
        {
            if (session is not null && (!ReferenceEquals(_session, session) || session.StopRequested || _stopped)) return;
            if (_status == status) return;
            var previous = _status;
            _status = status;
            // Coalesced: retries flip Connecting<->DiscordAbsent silently; only real transitions are logged.
            if (!(previous == DiscordPresenceStatus.DiscordAbsent && status == DiscordPresenceStatus.Connecting)
                && !(previous == DiscordPresenceStatus.Connecting && status == DiscordPresenceStatus.DiscordAbsent && session?.LoggedAbsent == true))
                AppLog.Write(LogCategory, $"discord: status {status}");
            if (session is not null && status == DiscordPresenceStatus.DiscordAbsent) session.LoggedAbsent = true;
            if (status == DiscordPresenceStatus.Connected && session is not null) session.LoggedAbsent = false;
        }
        RaiseStatusChanged();
    }

    private void RaiseStatusChanged()
    {
        if (_context is { } context)
        {
            try { context.Post(static state => ((DiscordPresence)state!).InvokeStatusChanged(), this); }
            catch (Exception) { }
        }
        else
        {
            InvokeStatusChanged();
        }
    }

    private void InvokeStatusChanged()
    {
        try { StatusChanged?.Invoke(this, EventArgs.Empty); }
        catch (Exception ex) { AppLog.Write(LogCategory, $"discord: status handler failed ({ex.GetType().Name})"); }
    }

    // ---------- Session lifecycle ----------

    private void StopSessionLocked()
    {
        var session = _session;
        if (session is null || session.StopRequested) return;
        session.StopRequested = true;
        _ready = false;
        try
        {
            if (session.Ready) session.Cts.CancelAfter(StopDeadlineMs); // give the priority clear its bounded window
            else session.Cts.Cancel();                                   // in-flight discovery is cancelled immediately
        }
        catch (ObjectDisposedException) { }
        session.Signal();
    }

    private async Task RunSessionAsync(Session session, Task previous)
    {
        try
        {
            await previous.ConfigureAwait(false); // never faults; lets an old clear finish on its own pipe first
            var ct = session.Cts.Token;
            var failures = 0;
            var preferred = 0;
            while (!ct.IsCancellationRequested && !session.StopRequested)
            {
                if (failures > 0)
                {
                    SetStatus(session, session.LastFailureWasProtocol ? DiscordPresenceStatus.Error : DiscordPresenceStatus.DiscordAbsent);
                    await Task.Delay(Backoff(failures), ct).ConfigureAwait(false);
                    if (session.StopRequested) break;
                }
                SetStatus(session, DiscordPresenceStatus.Connecting);
                var (connection, protocolFailure, index) = await DiscoverAsync(preferred, ct).ConfigureAwait(false);
                if (connection is null)
                {
                    session.LastFailureWasProtocol = protocolFailure;
                    if (protocolFailure) { AppLog.Write(LogCategory, "discord: handshake failed"); preferred = (index + 1) % PipeCount; }
                    failures++;
                    continue;
                }
                preferred = index;
                var connectedAt = Environment.TickCount64;
                bool lostByProtocol;
                await using (connection)
                {
                    lock (_gate)
                    {
                        if (session.StopRequested) break;
                        session.Ready = true;
                        _ready = true;
                    }
                    SetStatus(session, DiscordPresenceStatus.Connected);
                    RaiseStatusChanged(); // prompt the host for a fresh observation (NeedsSnapshot is now true)
                    try
                    {
                        lostByProtocol = await ServeAsync(session, connection, ct).ConfigureAwait(false);
                    }
                    finally
                    {
                        lock (_gate)
                        {
                            session.Ready = false;
                            if (ReferenceEquals(_session, session)) _ready = false;
                        }
                    }
                }
                if (session.StopRequested || ct.IsCancellationRequested) break;
                AppLog.Write(LogCategory, lostByProtocol ? "discord: protocol error; reconnecting" : "discord: connection lost; reconnecting");
                session.LastFailureWasProtocol = lostByProtocol;
                if (lostByProtocol) preferred = (index + 1) % PipeCount;
                failures = Environment.TickCount64 - connectedAt >= StableResetMs ? 0 : failures + 1;
            }
        }
        catch (OperationCanceledException) { }
        catch (Exception ex)
        {
            AppLog.Write(LogCategory, $"discord: session failed ({ex.GetType().Name})");
            SetStatus(session, DiscordPresenceStatus.Error);
        }
        finally
        {
            session.Cts.Dispose();
        }
    }

    private static TimeSpan Backoff(int failures)
    {
        var seconds = BackoffSeconds[Math.Min(failures, BackoffSeconds.Length) - 1];
        var jitter = 0.8 + Random.Shared.NextDouble() * 0.4;
        return TimeSpan.FromSeconds(seconds * jitter);
    }

    // ---------- Discovery and handshake ----------

    private async Task<(Connection? Connection, bool ProtocolFailure, int Index)> DiscoverAsync(int preferred, CancellationToken ct)
    {
        var passStart = Environment.TickCount64;
        var protocolFailure = false;
        var failedIndex = preferred;
        for (var step = 0; step < PipeCount; step++)
        {
            var remaining = PassDeadlineMs - (int)(Environment.TickCount64 - passStart);
            if (remaining <= 0) break;
            ct.ThrowIfCancellationRequested();
            var index = (preferred + step) % PipeCount;
            var pipe = new NamedPipeClientStream(".", $"{_environment.PipePrefix}{index}", PipeDirection.InOut, PipeOptions.Asynchronous);
            try
            {
                await pipe.ConnectAsync(Math.Min(ConnectTimeoutMs, remaining), ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { await pipe.DisposeAsync().ConfigureAwait(false); throw; }
            catch (Exception) { await pipe.DisposeAsync().ConfigureAwait(false); continue; } // absent, busy or timed out

            var connection = new Connection(pipe);
            try
            {
                remaining = PassDeadlineMs - (int)(Environment.TickCount64 - passStart);
                using var readyCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                readyCts.CancelAfter(Math.Max(1, Math.Min(ReadyTimeoutMs, remaining)));
                var handshake = BuildHandshake(_environment.ApplicationId!);
                await connection.WriteAsync(OpHandshake, handshake, readyCts.Token).ConfigureAwait(false);
                while (true)
                {
                    var (op, body) = await ReadFrameAsync(pipe, readyCts.Token).ConfigureAwait(false);
                    if (op == OpPing) { await connection.WriteAsync(OpPong, body, readyCts.Token).ConfigureAwait(false); continue; }
                    if (op == OpPong) continue;
                    if (op != OpFrame) throw new ProtocolException(); // CLOSE (e.g. invalid client id) or handshake reply
                    using var doc = JsonDocument.Parse(body, ParseOptions);
                    if (GetString(doc.RootElement, "cmd") == "DISPATCH" && GetString(doc.RootElement, "evt") == "READY")
                        return (connection, false, index); // READY user data is discarded unread
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                await connection.DisposeAsync().ConfigureAwait(false);
                throw;
            }
            catch (Exception)
            {
                // Timeout, EOF, malformed frame or CLOSE: move past this endpoint.
                protocolFailure = true;
                failedIndex = index;
                await connection.DisposeAsync().ConfigureAwait(false);
            }
        }
        return (null, protocolFailure, failedIndex);
    }

    // ---------- Connected loop ----------

    // Returns true when the connection ended because of a protocol violation, false for EOF/transport loss.
    private async Task<bool> ServeAsync(Session session, Connection connection, CancellationToken ct)
    {
        var incoming = Channel.CreateBounded<Incoming>(new BoundedChannelOptions(8) { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
        using var readerCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var reader = ReaderLoopAsync(connection, incoming.Writer, readerCts.Token);

        string? lastSent = null;          // what Discord currently shows for this connection (null = nothing)
        string? pendingNonce = null;
        long pendingDeadline = 0;
        long lastNormalWrite = long.MinValue / 2;
        string? desiredPrevious = null;
        long desiredChangedAt = 0;
        long? burstStart = null;
        var loggedRejection = false;
        var minWriteMs = (long)_environment.MinWriteInterval.TotalMilliseconds;

        Task? signalWait = null;
        Task<Incoming>? readWait = null;
        try
        {
            while (true)
            {
                var now = Environment.TickCount64;
                if (session.StopRequested)
                {
                    if (lastSent is not null || pendingNonce is not null)
                        await TrySendAsync(connection, null, ct).ConfigureAwait(false);
                    return false;
                }

                var desired = BuildDesired(now, out var changesAt);
                if (!string.Equals(desired, desiredPrevious, StringComparison.Ordinal))
                {
                    burstStart ??= now;
                    desiredChangedAt = now;
                    desiredPrevious = desired;
                }

                long? wakeAt = changesAt;
                if (desired is null)
                {
                    burstStart = null;
                    if (lastSent is not null || pendingNonce is not null)
                    {
                        // Priority clear: bypasses debounce and the write gate, retires any pending normal nonce.
                        pendingNonce = await TrySendAsync(connection, null, ct).ConfigureAwait(false);
                        if (pendingNonce is null) return false;
                        pendingDeadline = Environment.TickCount64 + AckTimeoutMs;
                        lastSent = null;
                    }
                }
                else if (!string.Equals(desired, lastSent, StringComparison.Ordinal))
                {
                    var due = Math.Max(Math.Min(desiredChangedAt + DebounceMs, (burstStart ?? now) + DebounceMaxMs), lastNormalWrite + minWriteMs);
                    if (pendingNonce is null && now >= due)
                    {
                        pendingNonce = await TrySendAsync(connection, desired, ct).ConfigureAwait(false);
                        if (pendingNonce is null) return false;
                        pendingDeadline = Environment.TickCount64 + AckTimeoutMs;
                        lastSent = desired; // a rejected payload is not resent until the desired payload changes
                        lastNormalWrite = Environment.TickCount64;
                        burstStart = null;
                    }
                    else if (pendingNonce is null)
                    {
                        wakeAt = Min(wakeAt, due);
                    }
                }
                else
                {
                    burstStart = null;
                }
                if (pendingNonce is not null) wakeAt = Min(wakeAt, pendingDeadline);

                signalWait ??= session.WaitAsync(ct);
                readWait ??= incoming.Reader.ReadAsync(ct).AsTask();
                using var delayCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                var delay = wakeAt is long at
                    ? Task.Delay(TimeSpan.FromMilliseconds(Math.Max(0, at - Environment.TickCount64)), delayCts.Token)
                    : Task.Delay(Timeout.InfiniteTimeSpan, delayCts.Token);
                await Task.WhenAny(signalWait, readWait, delay).ConfigureAwait(false);
                delayCts.Cancel();
                ct.ThrowIfCancellationRequested();

                if (signalWait.IsCompleted) { ObserveTask(signalWait); signalWait = null; }
                if (readWait.IsCompleted)
                {
                    var message = readWait.IsCompletedSuccessfully ? readWait.Result : new Incoming(IncomingKind.Lost, null, false);
                    ObserveTask(readWait);
                    readWait = null;
                    switch (message.Kind)
                    {
                        case IncomingKind.Lost: return false;
                        case IncomingKind.Protocol: return true;
                        case IncomingKind.Ack when pendingNonce is not null && string.Equals(message.Nonce, pendingNonce, StringComparison.Ordinal):
                            pendingNonce = null;
                            if (message.Error)
                            {
                                if (!loggedRejection) { AppLog.Write(LogCategory, "discord: activity rejected"); loggedRejection = true; }
                                SetStatus(session, DiscordPresenceStatus.Error);
                            }
                            else
                            {
                                SetStatus(session, DiscordPresenceStatus.Connected);
                            }
                            break;
                        // Stale or unknown nonces cannot mark a newer activity accepted.
                    }
                }
                if (pendingNonce is not null && Environment.TickCount64 >= pendingDeadline)
                {
                    AppLog.Write(LogCategory, "discord: acknowledgement timeout");
                    return false;
                }
            }
        }
        finally
        {
            try { readerCts.Cancel(); } catch (Exception) { }
            await connection.DisposeAsync().ConfigureAwait(false); // unblocks the reader
            try { await reader.ConfigureAwait(false); } catch (Exception) { }
            if (signalWait is not null) ObserveTask(signalWait);
            if (readWait is not null) ObserveTask(readWait);
        }
    }

    private static long? Min(long? a, long b) => a is long x ? Math.Min(x, b) : b;

    // Attaches a no-op continuation so abandoned waits never surface as unobserved exceptions.
    private static void ObserveTask(Task task)
    {
        if (task.IsCompleted) { _ = task.Exception; return; }
        _ = task.ContinueWith(static t => _ = t.Exception, CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
    }

    // Writes SET_ACTIVITY; returns the nonce, or null when the write failed (connection unusable).
    private async Task<string?> TrySendAsync(Connection connection, string? activityJson, CancellationToken ct)
    {
        var nonce = Guid.NewGuid().ToString("N");
        var buffer = new ArrayBufferWriter<byte>(activityJson is null ? 256 : activityJson.Length + 256);
        using (var w = new Utf8JsonWriter(buffer))
        {
            w.WriteStartObject();
            w.WriteString("cmd", "SET_ACTIVITY");
            w.WriteStartObject("args");
            w.WriteNumber("pid", _environment.ProcessId);
            w.WritePropertyName("activity");
            if (activityJson is null) w.WriteNullValue();
            else w.WriteRawValue(activityJson, skipInputValidation: true);
            w.WriteEndObject();
            w.WriteString("nonce", nonce);
            w.WriteEndObject();
        }
        try
        {
            await connection.WriteAsync(OpFrame, buffer.WrittenMemory, ct).ConfigureAwait(false);
            return nonce;
        }
        catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
        catch (Exception)
        {
            AppLog.Write(LogCategory, "discord: write failed");
            return null;
        }
    }

    private static async Task ReaderLoopAsync(Connection connection, ChannelWriter<Incoming> output, CancellationToken ct)
    {
        var result = new Incoming(IncomingKind.Lost, null, false);
        try
        {
            while (true)
            {
                var (op, body) = await ReadFrameAsync(connection.Stream, ct).ConfigureAwait(false);
                switch (op)
                {
                    case OpPing:
                        await connection.WriteAsync(OpPong, body, ct).ConfigureAwait(false);
                        break;
                    case OpPong:
                        break;
                    case OpClose:
                        return;
                    case OpFrame:
                        using (var doc = JsonDocument.Parse(body, ParseOptions))
                        {
                            var root = doc.RootElement;
                            if (root.ValueKind == JsonValueKind.Object && GetString(root, "cmd") == "SET_ACTIVITY")
                                await output.WriteAsync(new Incoming(IncomingKind.Ack, GetString(root, "nonce"), GetString(root, "evt") == "ERROR"), ct).ConfigureAwait(false);
                        }
                        break; // other dispatches (and their content) are discarded
                    default:
                        throw new ProtocolException();
                }
            }
        }
        catch (ProtocolException) { result = new Incoming(IncomingKind.Protocol, null, false); }
        catch (JsonException) { result = new Incoming(IncomingKind.Protocol, null, false); }
        catch (Exception) { }
        finally
        {
            output.TryWrite(result);
            output.TryComplete();
        }
    }

    // Exact reads across partial reads. Idle waits have no periodic wakeups; once the first header byte
    // arrives the rest of the frame must follow within 5 s. Lengths are checked before allocating.
    private static async Task<(int Op, byte[] Body)> ReadFrameAsync(Stream stream, CancellationToken ct)
    {
        var header = new byte[8];
        var first = await stream.ReadAsync(header.AsMemory(0, 1), ct).ConfigureAwait(false);
        if (first == 0) throw new EndOfStreamException();
        using var frameCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        frameCts.CancelAfter(FrameCompletionMs);
        await stream.ReadExactlyAsync(header.AsMemory(1, 7), frameCts.Token).ConfigureAwait(false);
        var op = BinaryPrimitives.ReadInt32LittleEndian(header);
        var length = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(4));
        if (op is < OpHandshake or > OpPong || length < 0 || length > MaxFrameBytes) throw new ProtocolException();
        var body = length == 0 ? Array.Empty<byte>() : new byte[length];
        if (length > 0) await stream.ReadExactlyAsync(body, frameCts.Token).ConfigureAwait(false);
        return (op, body);
    }

    private static string? GetString(JsonElement element, string name)
        => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;

    // ---------- Nested types ----------

    private static byte[] BuildHandshake(string clientId)
    {
        var buffer = new ArrayBufferWriter<byte>(64);
        using (var w = new Utf8JsonWriter(buffer))
        {
            w.WriteStartObject();
            w.WriteNumber("v", 1);
            w.WriteString("client_id", clientId);
            w.WriteEndObject();
        }
        return buffer.WrittenSpan.ToArray();
    }

    private enum IncomingKind { Ack, Lost, Protocol }

    private readonly record struct Incoming(IncomingKind Kind, string? Nonce, bool Error);

    private sealed class ProtocolException : Exception;

    private sealed class Session
    {
        private readonly SemaphoreSlim _signal = new(0, 1);
        internal readonly CancellationTokenSource Cts = new();
        internal Task Task = Task.CompletedTask;
        internal volatile bool StopRequested;
        internal volatile bool Ready;
        internal bool LastFailureWasProtocol;
        internal bool LoggedAbsent;

        internal void Signal()
        {
            try { if (_signal.CurrentCount == 0) _signal.Release(); }
            catch (SemaphoreFullException) { }
            catch (ObjectDisposedException) { }
        }

        internal Task WaitAsync(CancellationToken ct) => _signal.WaitAsync(ct);
    }

    // One serialized writer with a 1 s deadline per frame (shared by the publish loop and PONG replies).
    private sealed class Connection(NamedPipeClientStream stream) : IAsyncDisposable
    {
        private readonly SemaphoreSlim _writeLock = new(1, 1);
        private int _disposed;
        internal NamedPipeClientStream Stream => stream;

        internal async Task WriteAsync(int op, ReadOnlyMemory<byte> body, CancellationToken ct)
        {
            if (body.Length > MaxFrameBytes) throw new ProtocolException();
            var frame = new byte[8 + body.Length];
            BinaryPrimitives.WriteInt32LittleEndian(frame, op);
            BinaryPrimitives.WriteInt32LittleEndian(frame.AsSpan(4), body.Length);
            body.Span.CopyTo(frame.AsSpan(8));
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(WriteDeadlineMs);
            await _writeLock.WaitAsync(cts.Token).ConfigureAwait(false);
            try
            {
                await stream.WriteAsync(frame, cts.Token).ConfigureAwait(false);
                await stream.FlushAsync(cts.Token).ConfigureAwait(false);
            }
            finally
            {
                _writeLock.Release();
            }
        }

        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            try { await stream.DisposeAsync().ConfigureAwait(false); } catch (Exception) { }
        }
    }
}

internal sealed record DiscordPresenceEnvironment(string? ApplicationId, string PipePrefix, TimeSpan PauseTimeout, TimeSpan MinWriteInterval, int ProcessId)
{
    private const string ProductionPipePrefix = "discord-ipc-";

    internal static DiscordPresenceEnvironment FromProcess()
    {
        var production = new DiscordPresenceEnvironment(
            DiscordPresence.ApplicationId, ProductionPipePrefix, TimeSpan.FromMinutes(10), TimeSpan.FromSeconds(15), Environment.ProcessId);
#if NATIVUNE_DISCORD_TEST_HOOKS
        var prefix = Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_PIPE_PREFIX");
        if (prefix is null) return production;
        if (!IsValidTestPrefix(prefix))
            return production with { ApplicationId = null, PipePrefix = "nativune-test-invalid-" }; // Unavailable; never real pipes
        var clientId = Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_CLIENT_ID");
        var result = production with
        {
            PipePrefix = prefix,
            ApplicationId = clientId is { Length: > 0 and <= 32 } && clientId.All(char.IsAsciiDigit) ? clientId : production.ApplicationId
        };
        if (ReadSeconds("NATIVUNE_TEST_DISCORD_PAUSE_SECONDS") is int pause) result = result with { PauseTimeout = TimeSpan.FromSeconds(pause) };
        if (ReadSeconds("NATIVUNE_TEST_DISCORD_MIN_WRITE_SECONDS") is int write) result = result with { MinWriteInterval = TimeSpan.FromSeconds(write) };
        return result;
#else
        return production;
#endif
    }

#if NATIVUNE_DISCORD_TEST_HOOKS
    // ^nativune-test-[0-9a-f]{32}-discord-ipc-$
    private static bool IsValidTestPrefix(string value)
    {
        const string head = "nativune-test-", tail = "-discord-ipc-";
        if (value.Length != head.Length + 32 + tail.Length
            || !value.StartsWith(head, StringComparison.Ordinal) || !value.EndsWith(tail, StringComparison.Ordinal)) return false;
        foreach (var c in value.AsSpan(head.Length, 32))
            if (!(c is >= '0' and <= '9' or >= 'a' and <= 'f')) return false;
        return true;
    }

    private static int? ReadSeconds(string name)
        => int.TryParse(Environment.GetEnvironmentVariable(name), System.Globalization.NumberStyles.None,
            System.Globalization.CultureInfo.InvariantCulture, out var value) && value is >= 0 and <= 86_400 ? value : null;
#endif
}
