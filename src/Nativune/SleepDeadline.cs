using System.Runtime.InteropServices;

namespace Nativune;

internal sealed class SleepDeadline : IDisposable
{
    private static readonly TimeSpan MinimumDuration = TimeSpan.FromSeconds(1);
    private static readonly TimeSpan MaximumDuration = TimeSpan.FromMinutes(240);
    private static readonly TimeSpan Infinite = Timeout.InfiniteTimeSpan;

    private readonly object _gate = new();
    private readonly Action _expired;
    private readonly SynchronizationContext _context;
    private readonly System.Threading.Timer _timer;
    private bool _disposed;
    private bool _armed;
    private ulong _generation;
    private ulong _deadlineTick;
    private ulong? _pendingExpiry;
    private DateTimeOffset? _displayDeadline;

    public SleepDeadline(Action expired, SynchronizationContext context)
    {
        _expired = expired ?? throw new ArgumentNullException(nameof(expired));
        _context = context ?? throw new ArgumentNullException(nameof(context));
        _timer = new System.Threading.Timer(OnTimer, null, Infinite, Infinite);
    }

    public bool IsArmed
    {
        get { lock (_gate) return _armed; }
    }

    public DateTimeOffset? DisplayDeadline
    {
        get { lock (_gate) return _displayDeadline; }
    }

    public TimeSpan? TimeRemaining
    {
        get
        {
            lock (_gate)
                return _armed ? TimeSpan.FromMilliseconds(Remaining(GetTickCount64(), _deadlineTick)) : null;
        }
    }

    public void Arm(TimeSpan duration)
    {
        if (duration < MinimumDuration || duration > MaximumDuration)
            throw new ArgumentOutOfRangeException(nameof(duration), "Duration must be between one second and four hours.");

        var milliseconds = (ulong)Math.Ceiling(duration.TotalMilliseconds);
        var now = GetTickCount64();
        lock (_gate)
        {
            ThrowIfDisposed();
            _generation++;
            _armed = true;
            _pendingExpiry = null;
            _deadlineTick = now + milliseconds;
            _displayDeadline = DateTimeOffset.Now.Add(duration);
            _timer.Change(ToTimerDue(milliseconds), Infinite);
        }
    }

    public void Cancel()
    {
        lock (_gate)
        {
            if (_disposed)
                return;
            _generation++;
            _armed = false;
            _pendingExpiry = null;
            _displayDeadline = null;
            _timer.Change(Infinite, Infinite);
        }
    }

    public void CheckOnResume() => OnTimer(null);

    public void Dispose()
    {
        lock (_gate)
        {
            if (_disposed)
                return;
            _disposed = true;
            _generation++;
            _armed = false;
            _pendingExpiry = null;
            _displayDeadline = null;
            _timer.Change(Infinite, Infinite);
        }
        _timer.Dispose();
    }

    private void OnTimer(object? state)
    {
        ulong generation;
        lock (_gate)
        {
            if (_disposed || !_armed)
                return;

            var remaining = Remaining(GetTickCount64(), _deadlineTick);
            if (remaining != 0)
            {
                // Timer callbacks can arrive early. Keep the one-shot timer and only
                // schedule the measured remainder; never poll the clock in a loop.
                _timer.Change(ToTimerDue(remaining), Infinite);
                return;
            }

            _armed = false;
            _displayDeadline = null;
            _pendingExpiry = generation = _generation;
            _timer.Change(Infinite, Infinite);
        }

        PostExpiry(generation);
    }

    private void PostExpiry(ulong generation)
    {
        try
        {
            _context.Post(static value =>
            {
                var request = (ExpiryRequest)value!;
                request.Owner.FireIfCurrent(request.Generation);
            }, new ExpiryRequest(this, generation));
        }
        catch (InvalidOperationException) { }
    }

    private void FireIfCurrent(ulong generation)
    {
        lock (_gate)
        {
            if (_disposed || _armed || _generation != generation || _pendingExpiry != generation)
                return;
            _pendingExpiry = null;
        }
        _expired();
    }

    private static ulong Remaining(ulong now, ulong deadline)
        => now < deadline ? deadline - now : 0;

    private static TimeSpan ToTimerDue(ulong milliseconds)
    {
        // Arm's public bounds keep this below Int32.MaxValue; the extra guard also
        // keeps this conversion safe if the constants change later.
        var due = Math.Min(milliseconds, (ulong)int.MaxValue);
        return TimeSpan.FromMilliseconds(Math.Max(1UL, due));
    }

    [DllImport("kernel32.dll")]
    private static extern ulong GetTickCount64();

    private void ThrowIfDisposed()
    {
        if (_disposed)
            throw new ObjectDisposedException(nameof(SleepDeadline));
    }

    private readonly record struct ExpiryRequest(SleepDeadline Owner, ulong Generation);

}
