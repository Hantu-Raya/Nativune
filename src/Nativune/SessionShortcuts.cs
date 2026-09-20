using System.Runtime.InteropServices;

namespace Nativune;

internal interface IHotKeyRegistrar
{
    bool Register(nint windowHandle, int id, uint modifiers, uint key);
    bool Unregister(nint windowHandle, int id);
}

internal sealed class SessionShortcuts : IDisposable
{
    private const uint ModNoRepeat = 0x4000;
    private const int FirstId = 0x6201;
    private const int LastId = 0x7FFC;
    private static readonly string[] Commands = ["toggle", "previous", "next", "compact"];

    private readonly nint _windowHandle;
    private readonly IHotKeyRegistrar _registrar;
    private readonly Dictionary<string, Registration> _registrations = new(StringComparer.Ordinal);
    // Entries remain here whenever an OS call failed, because the registration may
    // still exist. Dispose uses this conservative set for a final best-effort cleanup.
    private readonly Dictionary<int, Registration> _knownRegistrations = new();
    private int _idCursor = FirstId;
    private bool _disposed;

    internal SessionShortcuts(nint windowHandle, IHotKeyRegistrar? registrar = null)
    {
        _windowHandle = windowHandle;
        _registrar = registrar ?? new NativeHotKeyRegistrar();
    }

    internal bool Enabled { get; private set; }
    internal bool CleanupFailed { get; private set; }

    internal bool TryApply(ShortcutBindings bindings, out string error)
    {
        if (_disposed)
        {
            error = "Session shortcuts have already been disposed.";
            return false;
        }
        if (CleanupFailed)
        {
            error = "Session shortcut cleanup was incomplete; restart the app before enabling shortcuts again.";
            return false;
        }
        if (bindings is null)
        {
            error = "Shortcut bindings are unavailable.";
            return false;
        }
        if (!bindings.Validate(out error))
            return false;
        if (_windowHandle == nint.Zero)
        {
            error = "The application window is not ready for session shortcuts.";
            return false;
        }

        var old = new Dictionary<string, Registration>(_registrations, StringComparer.Ordinal);
        var desired = new Dictionary<string, Registration>(StringComparer.Ordinal);
        var usedOldIds = new HashSet<int>();
        var added = new List<Registration>();

        // Reusing any matching combination is important for swaps: Ctrl+Alt+P can
        // move from Toggle to Previous without trying to register a duplicate first.
        for (var commandIndex = 0; commandIndex < Commands.Length; commandIndex++)
        {
            var command = Commands[commandIndex];
            var encoded = bindings[commandIndex];
            if (encoded == 0)
                continue;

            Registration? reuse = null;
            foreach (var candidate in old.Values)
            {
                if (candidate.Encoded == encoded && usedOldIds.Add(candidate.Id))
                {
                    reuse = candidate with { Command = command };
                    break;
                }
            }

            if (reuse is not null)
            {
                desired.Add(command, reuse);
                continue;
            }

            if (!ShortcutBindings.TryDecode(encoded, out var modifiers, out var key, out _))
            {
                error = $"{ShortcutBindings.Format(encoded)} is not a supported shortcut.";
                return false;
            }
            var id = AllocateId(commandIndex, old.Values, desired.Values);
            var registration = new Registration(command, encoded, id, modifiers | ModNoRepeat, key);
            if (!_registrar.Register(_windowHandle, id, registration.Modifiers, registration.Key))
            {
                var rollbackOk = RollbackAdded(added);
                if (!rollbackOk)
                {
                    Fault();
                    error = "Could not register the shortcut; cleanup was incomplete. Restart the app before trying again.";
                }
                else
                {
                    error = $"Could not register {command} shortcut {ShortcutBindings.Format(encoded)}; another application may already use it.";
                }
                return false;
            }
            _knownRegistrations[id] = registration;
            added.Add(registration);
            desired.Add(command, registration);
        }

        var removed = old.Values.Where(item => !usedOldIds.Contains(item.Id)).ToArray();
        var released = new List<Registration>(removed.Length);
        foreach (var registration in removed)
        {
            if (_registrar.Unregister(_windowHandle, registration.Id))
            {
                _knownRegistrations.Remove(registration.Id);
                released.Add(registration);
                continue;
            }

            // Restore everything released so far and drop newly acquired IDs. A
            // failed restore is fail-closed: do not claim the old map is active.
            var cleanupOk = true;
            foreach (var restored in released)
            {
                if (_registrar.Register(_windowHandle, restored.Id, restored.Modifiers, restored.Key))
                    _knownRegistrations[restored.Id] = restored;
                else
                {
                    _knownRegistrations[restored.Id] = restored;
                    cleanupOk = false;
                }
            }
            cleanupOk &= RollbackAdded(added);
            if (!cleanupOk)
            {
                Fault();
                error = "The previous session shortcuts could not be restored; restart the app before trying again.";
            }
            else
            {
                error = "The previous session shortcuts could not be replaced.";
            }
            return false;
        }

        _registrations.Clear();
        foreach (var pair in desired)
            _registrations.Add(pair.Key, pair.Value);
        Enabled = true;
        error = string.Empty;
        return true;
    }

    internal void Disable()
    {
        if (_disposed)
            return;
        var cleanupOk = true;
        foreach (var registration in _knownRegistrations.Values.ToArray())
        {
            if (_registrar.Unregister(_windowHandle, registration.Id))
                _knownRegistrations.Remove(registration.Id);
            else
                cleanupOk = false;
        }
        _registrations.Clear();
        Enabled = false;
        if (!cleanupOk)
            CleanupFailed = true;
    }

    internal string? CommandForHotkey(nint hotkeyId)
    {
        if (CleanupFailed || !Enabled)
            return null;
        var value = hotkeyId.ToInt64();
        if (value < int.MinValue || value > int.MaxValue)
            return null;
        var id = (int)value;
        foreach (var registration in _registrations.Values)
        {
            if (registration.Id == id)
                return registration.Command;
        }
        return null;
    }

    public void Dispose()
    {
        if (_disposed)
            return;
        Disable();
        _disposed = true;
    }

    private void Fault()
    {
        CleanupFailed = true;
        _registrations.Clear();
        Enabled = false;
    }

    private int AllocateId(int commandIndex, IEnumerable<Registration> old,
        IEnumerable<Registration> desired)
    {
        var usedIds = new HashSet<int>(_knownRegistrations.Keys);
        foreach (var registration in old)
            usedIds.Add(registration.Id);
        foreach (var registration in desired)
            usedIds.Add(registration.Id);

        for (var attempt = 0; attempt <= (LastId - FirstId) / 4; attempt++)
        {
            var candidate = _idCursor + commandIndex;
            if (candidate <= LastId && !usedIds.Contains(candidate))
            {
                if (_idCursor > LastId - 4)
                    _idCursor = FirstId;
                else
                    _idCursor += 4;
                return candidate;
            }
            _idCursor = _idCursor > LastId - 4 ? FirstId : _idCursor + 4;
        }
        throw new InvalidOperationException("No session shortcut identifiers are available.");
    }

    private bool RollbackAdded(IEnumerable<Registration> added)
    {
        var ok = true;
        foreach (var registration in added.Reverse())
        {
            if (_registrar.Unregister(_windowHandle, registration.Id))
                _knownRegistrations.Remove(registration.Id);
            else
                ok = false;
        }
        return ok;
    }

    private sealed record Registration(string Command, int Encoded, int Id, uint Modifiers, uint Key);

    private sealed class NativeHotKeyRegistrar : IHotKeyRegistrar
    {
        public bool Register(nint windowHandle, int id, uint modifiers, uint key) =>
            RegisterHotKey(windowHandle, id, modifiers, key);

        public bool Unregister(nint windowHandle, int id) =>
            UnregisterHotKey(windowHandle, id);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool RegisterHotKey(nint hWnd, int id, uint fsModifiers, uint vk);

        [DllImport("user32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        private static extern bool UnregisterHotKey(nint hWnd, int id);
    }
}
