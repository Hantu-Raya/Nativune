using System.Threading.Channels;
using static Nativune.DiscordRpcTransport;

namespace Nativune;

/// <summary>
/// Optional Discord Rich Presence over the local discord-ipc named pipe. Owns no WebView or playback state:
/// the host feeds validated observations and options on the UI thread; all IPC runs on one background
/// session task. Never logs or persists activity content, URLs, frames or READY user data.
/// </summary>
internal sealed class DiscordPresence : IAsyncDisposable
{
    // Public Discord application (client) id of the owner's "Nativune" Developer Portal app
    // (art assets: nativune, pause, repeat-one). Not a secret; no client secret or OAuth is used.
    internal const string ApplicationId = "1553558181240766615";

    private const string LogCategory = "discord";
    private const int AckTimeoutMs = 5000;
    private const int DebounceMs = 1000;
    private const int DebounceMaxMs = 2000;
    private const int StopDeadlineMs = 1000;
    private const long StableResetMs = 30_000;
    private const double ReanchorDriftSeconds = 2.0;
    private const long SharedArtStableMs = 3000;
    private static readonly int[] BackoffSeconds = [2, 5, 10, 30, 60];

    private readonly DiscordPresenceEnvironment _environment;
    private readonly SynchronizationContext? _context;
    private readonly object _gate = new();

    // Guarded by _gate.
    private DiscordPresenceOptions _options = DiscordPresenceOptions.Default;
    private DiscordTrackObservation? _observation;
    private string? _itemTitle, _itemTrackUrl, _itemArt, _previousItemArt;
    private long _itemArtSinceMs; // monotonic start of the current item's continuous run on _itemArt
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
            _previousItemArt = _itemArt; // never carry the prior item's art into the new item right away
            _itemTitle = o.Title;
            _itemTrackUrl = o.TrackUrl;
            _anchorStart = null;
        }
        else if (o.TrackUrl is not null)
        {
            _itemTrackUrl = o.TrackUrl;
        }
        if (itemChanged || !string.Equals(_itemArt, o.ArtworkUrl, StringComparison.Ordinal)) _itemArtSinceMs = nowMs;
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
            string? art = null;
            if (CompactArtwork.IsAllowedUrl(o.ArtworkUrl))
            {
                if (!string.Equals(o.ArtworkUrl, _previousItemArt, StringComparison.Ordinal))
                {
                    art = o.ArtworkUrl;
                }
                else
                {
                    // Same art as the previous item (e.g. same album): accept once stable on the new item.
                    var acceptAt = _itemArtSinceMs + SharedArtStableMs;
                    if (nowMs >= acceptAt) art = o.ArtworkUrl;
                    else changesAtMs = changesAtMs is long c ? Math.Min(c, acceptAt) : acceptAt;
                }
            }
            return DiscordActivity.BuildActivityJson(o, _options, art, o.Paused ? null : _anchorStart, _anchorDuration);
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
                var (connection, protocolFailure, index) = await DiscordRpcTransport.DiscoverAsync(_environment.ApplicationId!, _environment.PipePrefix, preferred, ct).ConfigureAwait(false);
                if (connection is null)
                {
                    session.LastFailureWasProtocol = protocolFailure;
                    if (protocolFailure) { AppLog.Write(LogCategory, "discord: handshake failed"); preferred = (index + 1) % DiscordRpcTransport.PipeCount; }
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
                        ForgetTrackLocked(); // publish only observations received after this READY
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
                            if (ReferenceEquals(_session, session))
                            {
                                _ready = false;
                                ForgetTrackLocked(); // a pre-disconnect song must never be republished on reconnect
                            }
                        }
                    }
                }
                if (session.StopRequested || ct.IsCancellationRequested) break;
                AppLog.Write(LogCategory, lostByProtocol ? "discord: protocol error; reconnecting" : "discord: connection lost; reconnecting");
                session.LastFailureWasProtocol = lostByProtocol;
                if (lostByProtocol) preferred = (index + 1) % DiscordRpcTransport.PipeCount;
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

    // ---------- Connected loop ----------

    // Returns true when the connection ended because of a protocol violation, false for EOF/transport loss.
    private async Task<bool> ServeAsync(Session session, DiscordRpcTransport.Connection connection, CancellationToken ct)
    {
        var incoming = Channel.CreateBounded<Incoming>(new BoundedChannelOptions(8) { SingleReader = true, SingleWriter = true, FullMode = BoundedChannelFullMode.Wait });
        using var readerCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        var reader = connection.ReadLoopAsync(incoming.Writer, readerCts.Token);

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
                        await connection.SendActivityAsync(null, _environment.ProcessId, ct).ConfigureAwait(false);
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
                        pendingNonce = await connection.SendActivityAsync(null, _environment.ProcessId, ct).ConfigureAwait(false);
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
                        pendingNonce = await connection.SendActivityAsync(desired, _environment.ProcessId, ct).ConfigureAwait(false);
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

    // ---------- Nested types ----------

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
}
