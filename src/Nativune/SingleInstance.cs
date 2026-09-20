using Microsoft.Win32.SafeHandles;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;

namespace Nativune;

internal sealed class SingleInstance : IDisposable
{
    private const string ProfileDirectoryName = "data\\webview2";
    private const string ProfileFailureMessage =
        "Could not resolve the profile directory for single-instance coordination.";
    private const string OwnershipFailureMessage =
        "Could not establish single-instance ownership for this profile.";
    private const string ActivationFailureMessage =
        "An existing profile instance could not be activated in this Windows session.";
    private const uint FileReadAttributes = 0x00000080;
    private const uint OpenExisting = 3;
    private const uint FileFlagBackupSemantics = 0x02000000;
    private const int SignalAttempts = 4;
    private const int SignalDelayMilliseconds = 15;

    private static readonly NamedWaitHandleOptions MutexOptions = new()
    {
        CurrentUserOnly = true,
        CurrentSessionOnly = false
    };

    private static readonly NamedWaitHandleOptions EventOptions = new()
    {
        CurrentUserOnly = true,
        CurrentSessionOnly = true
    };

    private static readonly object ProcessOwnersGate = new();
    private static readonly HashSet<string> ProcessOwners = new(StringComparer.Ordinal);

    private readonly string _identity;
    private readonly Mutex _mutex;
    private readonly EventWaitHandle _activationEvent;
    private readonly object _listenerGate = new();
    private RegisteredWaitHandle? _registration;
    private Action? _activate;
    private bool _started;
    private bool _disposed;

    private SingleInstance(string identity, Mutex mutex, EventWaitHandle activationEvent)
    {
        _identity = identity;
        _mutex = mutex;
        _activationEvent = activationEvent;
    }

    public static SingleInstance? Acquire(string root)
    {
        var profile = ResolveProfile(root);
        var names = CreateNames(profile);

        if (IsProcessOwner(names.Identity))
        {
            if (TrySignal(names.EventName))
                return null;

            throw new InvalidOperationException(ActivationFailureMessage);
        }

        Mutex? mutex = null;
        var ownsMutex = false;
        var processOwnerAdded = false;
        var activationFailure = false;

        try
        {
            mutex = new Mutex(false, names.MutexName, MutexOptions, out _);
            ownsMutex = TryAcquire(mutex);

            if (!ownsMutex)
            {
                if (TrySignal(names.EventName))
                {
                    mutex.Dispose();
                    return null;
                }

                // The owner can be between mutex creation and event creation, or can
                // have exited while the bounded signal attempts were in progress.
                ownsMutex = TryAcquire(mutex);
                if (!ownsMutex)
                {
                    activationFailure = true;
                    throw new InvalidOperationException(ActivationFailureMessage);
                }
            }

            processOwnerAdded = AddProcessOwner(names.Identity);
            if (!processOwnerAdded)
            {
                ReleaseMutex(mutex!);
                ownsMutex = false;
                mutex!.Dispose();
                if (TrySignal(names.EventName))
                    return null;

                activationFailure = true;
                throw new InvalidOperationException(ActivationFailureMessage);
            }

            var activationEvent = new EventWaitHandle(
                false,
                EventResetMode.AutoReset,
                names.EventName,
                EventOptions,
                out _);

            processOwnerAdded = false;
            return new SingleInstance(names.Identity, mutex!, activationEvent);
        }
        catch (Exception)
        {
            if (processOwnerAdded)
                RemoveProcessOwner(names.Identity);
            if (ownsMutex && mutex is not null)
                ReleaseMutex(mutex);
            mutex?.Dispose();
            if (activationFailure)
                throw;
            throw new InvalidOperationException(OwnershipFailureMessage);
        }

    }

    public void StartListening(Action activate)
    {
        ArgumentNullException.ThrowIfNull(activate);

        lock (_listenerGate)
        {
            if (_disposed)
                throw new InvalidOperationException(
                    "Single-instance ownership has already been disposed.");
            if (_started)
                throw new InvalidOperationException(
                    "Single-instance activation is already listening.");

            _activate = activate;
            _started = true;
            try
            {
                _registration = ThreadPool.RegisterWaitForSingleObject(
                    _activationEvent,
                    static (state, timedOut) => ((SingleInstance)state!).OnActivation(timedOut),
                    this,
                    Timeout.InfiniteTimeSpan,
                    executeOnlyOnce: false);
            }
            catch (Exception)
            {
                _activate = null;
                _started = false;
                throw new InvalidOperationException(
                    "Could not start single-instance activation listening.");
            }
        }
    }

    public void Dispose()
    {
        RegisteredWaitHandle? registration;
        lock (_listenerGate)
        {
            if (_disposed)
                return;

            _disposed = true;
            _activate = null;
            registration = _registration;
            _registration = null;
        }

        registration?.Unregister(null);

        Exception? releaseFailure = null;
        try
        {
            _mutex.ReleaseMutex();
        }
        catch (Exception)
        {
            releaseFailure = new InvalidOperationException(
                "Could not release single-instance ownership.");
        }
        finally
        {
            _activationEvent.Dispose();
            _mutex.Dispose();
        }
        RemoveProcessOwner(_identity);

        if (releaseFailure is not null)
            throw releaseFailure;
    }

    private void OnActivation(bool timedOut)
    {
        if (timedOut)
            return;

        Action? activate;
        lock (_listenerGate)
        {
            if (_disposed)
                return;
            activate = _activate;
        }

        if (activate is null)
            return;

        try
        {
            activate();
        }
        catch (Exception)
        {
            // An activation callback runs on a ThreadPool thread. Do not let an
            // already-closing UI turn a duplicate launch into process termination.
        }
    }

    private static bool TryAcquire(Mutex mutex)
    {
        try
        {
            return mutex.WaitOne(0);
        }
        catch (AbandonedMutexException)
        {
            return true;
        }
    }

    private static bool TrySignal(string eventName)
    {
        for (var attempt = 0; attempt < SignalAttempts; attempt++)
        {
            try
            {
                if (EventWaitHandle.TryOpenExisting(eventName, EventOptions, out var activationEvent))
                {
                    using (activationEvent!)
                        return activationEvent.Set();
                }
            }
            catch (UnauthorizedAccessException)
            {
                return false;
            }
            catch (WaitHandleCannotBeOpenedException)
            {
                // The owner may still be creating its session-local event.
            }
            catch (IOException)
            {
                // A concurrently exiting owner can close the event between open and Set.
            }
            catch (ObjectDisposedException)
            {
                // Treat a disappearing event as an unsuccessful activation attempt.
            }
            catch (InvalidOperationException)
            {
                // Treat a disappearing event as an unsuccessful activation attempt.
            }

            if (attempt + 1 < SignalAttempts)
                Thread.Sleep(SignalDelayMilliseconds);
        }

        return false;
    }

    private static bool IsProcessOwner(string identity)
    {
        lock (ProcessOwnersGate)
            return ProcessOwners.Contains(identity);
    }

    private static bool AddProcessOwner(string identity)
    {
        lock (ProcessOwnersGate)
            return ProcessOwners.Add(identity);
    }

    private static void RemoveProcessOwner(string identity)
    {
        lock (ProcessOwnersGate)
            ProcessOwners.Remove(identity);
    }

    private static string ResolveProfile(string root)
    {
        if (string.IsNullOrWhiteSpace(root))
            throw new InvalidOperationException(ProfileFailureMessage);

        try
        {
            var profilePath = Path.Combine(Path.GetFullPath(root), ProfileDirectoryName);
            Directory.CreateDirectory(profilePath);
            using var directory = OpenDirectory(profilePath);
            var finalPath = GetFinalPath(directory);
            var identity = NormalizeFinalPath(finalPath);
            if (identity.Length == 0)
                throw new InvalidOperationException();
            return identity;
        }
        catch (Exception)
        {
            throw new InvalidOperationException(ProfileFailureMessage);
        }
    }

    private static SafeFileHandle OpenDirectory(string path)
    {
        var handle = CreateFile(
            path,
            FileReadAttributes,
            (uint)(FileShare.Read | FileShare.Write | FileShare.Delete),
            IntPtr.Zero,
            OpenExisting,
            FileFlagBackupSemantics,
            IntPtr.Zero);

        if (handle.IsInvalid)
        {
            handle.Dispose();
            throw new InvalidOperationException();

        }

        return handle;
    }

    private static string GetFinalPath(SafeFileHandle directory)
    {
        const int initialCapacity = 256;
        var capacity = initialCapacity;
        for (var attempt = 0; attempt < 4; attempt++)
        {
            var path = new StringBuilder(capacity);
            var length = GetFinalPathNameByHandle(directory, path, path.Capacity, 0);
            if (length == 0)
                throw new InvalidOperationException();
            if (length < path.Capacity - 1)
                return path.ToString();

            capacity = checked((int)length + 1);
        }

        throw new InvalidOperationException();
    }

    private static string NormalizeFinalPath(string path)
    {
        if (path.StartsWith(@"\\?\UNC\", StringComparison.OrdinalIgnoreCase))
            path = @"\\" + path[8..];
        else if (path.StartsWith(@"\\?\", StringComparison.OrdinalIgnoreCase))
            path = path[4..];

        return path.TrimEnd('\\', '/').ToUpperInvariant();
    }

    private static Names CreateNames(string identity)
    {
        var hash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(identity)));
        return new Names(
            identity,
            $"Nativune.SingleInstance.Mutex.{hash}",
            $"Nativune.SingleInstance.Activate.{hash}");
    }

    private static void ReleaseMutex(Mutex mutex)
    {
        try
        {
            mutex.ReleaseMutex();
        }
        catch (Exception)
        {
            // Closing the handle below abandons it if release is no longer possible.
        }
    }

    [DllImport("kernel32.dll", EntryPoint = "CreateFileW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern SafeFileHandle CreateFile(
        string fileName,
        uint desiredAccess,
        uint shareMode,
        IntPtr securityAttributes,
        uint creationDisposition,
        uint flagsAndAttributes,
        IntPtr templateFile);

    [DllImport("kernel32.dll", EntryPoint = "GetFinalPathNameByHandleW", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern uint GetFinalPathNameByHandle(
        SafeFileHandle file,
        StringBuilder path,
        int pathLength,
        uint flags);


    private readonly record struct Names(string Identity, string MutexName, string EventName);
}

