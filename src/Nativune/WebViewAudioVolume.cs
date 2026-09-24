using System.Runtime.InteropServices;
using System.Text;
using Microsoft.Win32.SafeHandles;

namespace Nativune;

internal sealed class WebViewAudioVolume : IDisposable
{
    internal const float DefaultVolume = 1f;
    private const int S_OK = 0;
    private const int S_FALSE = 1;
    internal const int AudclntSNoSingleProcess = unchecked((int)0x0889000D);
    private const uint ClsCtxAll = 0x17;
    private const uint CoInitMultithreaded = 0;
    private const uint ProcessQueryLimitedInformation = 0x1000;
    private const uint Synchronize = 0x00100000;
    private const uint WaitTimeout = 258;
    private const int ErrorInsufficientBuffer = 122;
    private const int MaximumProcessImagePathLength = 32768;
    private const float VolumeTolerance = 0.0001f;
    private const int MaximumSessionCount = 4096;
    private const int MaximumRenderEndpointCount = 256;
    internal const int MaximumNewSessionPreferenceAttempts = 2;

    private const uint DeviceStateActive = 0x00000001;

    private static readonly Guid MmDeviceEnumeratorClassId = new("BCDE0395-E52F-467C-8E3D-C4579291692E");
    private static readonly Guid MmDeviceEnumeratorInterfaceId = new("A95664D2-9614-4F35-A746-DE8DB63617E6");
    private static readonly Guid AudioSessionManager2InterfaceId = new("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F");

    private readonly string _expectedBrowserExecutablePath;
    private readonly Dictionary<int, SafeProcessHandle> _processHandles = [];
    private readonly HashSet<int> _retiredProcessIds = [];
    private HashSet<int> _activeProcessIds = [];
    private HashSet<string> _knownSessionIds = new(StringComparer.Ordinal);
    private readonly Dictionary<string, int> _newSessionPreferenceAttempts = new(StringComparer.Ordinal);
    private bool _hasVerifiedOwnedSessions;
    private bool _available;
    private bool _muted;
    private double _volume;
    private bool _hasMutePreference;
    private float _preferredVolume = DefaultVolume;
    private bool _preferredMute;
    private bool _disposed;


    public WebViewAudioVolume(string expectedBrowserExecutablePath)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(expectedBrowserExecutablePath);
        _expectedBrowserExecutablePath = Path.GetFullPath(expectedBrowserExecutablePath);
    }

    internal static bool TryGetWebViewProcessExecutablePath(int processId, out string executablePath)
    {
        executablePath = string.Empty;
        if (processId <= 0)
            return false;

        try
        {
            using var processHandle = OpenProcess(
                ProcessQueryLimitedInformation | Synchronize,
                inheritHandle: false,
                (uint)processId);
            if (processHandle is null || processHandle.IsInvalid
                || !TryGetProcessImagePath(processHandle, out var imagePath)
                || !IsProcessAlive(processHandle)
                || !Path.IsPathFullyQualified(imagePath))
                return false;

            var fullPath = Path.GetFullPath(imagePath);
            if (!string.Equals(Path.GetFileName(fullPath), "msedgewebview2.exe", StringComparison.OrdinalIgnoreCase)
                || !File.Exists(fullPath))
                return false;

            executablePath = fullPath;
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    public double Volume => _volume;
    public bool Muted => _muted;
    public bool Available => _available && !_disposed;
    // A complete owned-session inventory may coexist with inconsistent values; Available stays false.
    internal bool HasVerifiedOwnedSessions => _hasVerifiedOwnedSessions && !_disposed;

    // Calls are serialized by the host and run on MTA jobs. Each method owns and releases every
    // Core Audio RCW before leaving its COM-initialized call, even when Task.Run changes threads.
    public void Refresh(IReadOnlySet<int> webViewProcessIds, Func<bool>? canApplyPreference = null)
    {
        ArgumentNullException.ThrowIfNull(webViewProcessIds);
        if (_disposed)
            return;
        _hasVerifiedOwnedSessions = false;
        if (!TryInitializeComMta(out var uninitializeCom))
        {
            _activeProcessIds.Clear();
            MarkUnavailable();
            return;
        }

        try
        {
            if (!TryActivateOwnedProcesses(webViewProcessIds))
            {
                RetireExitedProcesses();
                _activeProcessIds.Clear();
                MarkUnavailable();
                return;
            }
            if (!TryEnumerateOwnedSessions(_activeProcessIds, _processHandles, out var sessions))
            {
                RetireExitedProcesses();
                _activeProcessIds.Clear();
                MarkUnavailable();
                return;
            }
            if (sessions.Count == 0)
            {
                _knownSessionIds.Clear();
                RetireExitedProcesses();
                _activeProcessIds.Clear();
                MarkUnavailable();
                return;
            }

            _hasVerifiedOwnedSessions = true;
            try
            {
                var currentSessionIds = sessions.Select(static session => session.InstanceId)
                    .ToHashSet(StringComparer.Ordinal);
                foreach (var staleAttemptId in _newSessionPreferenceAttempts.Keys
                    .Where(instanceId => !currentSessionIds.Contains(instanceId)).ToArray())
                    _newSessionPreferenceAttempts.Remove(staleAttemptId);

                var previousSessionIds = _knownSessionIds;
                var newSessions = sessions.Where(session =>
                    !_knownSessionIds.Contains(session.InstanceId)
                    && ShouldRetryNewSessionPreference(
                        _newSessionPreferenceAttempts.GetValueOrDefault(session.InstanceId))).ToList();
                _knownSessionIds = currentSessionIds;
                foreach (var session in newSessions)
                    _knownSessionIds.Remove(session.InstanceId);

                // New verified WebView sessions start at full app-output volume. Failed applies retry
                // only a bounded number of times; stale generations do not consume a retry.
                if (newSessions.Count > 0)
                {
                    float? volume = _preferredVolume;
                    bool? mute = _hasMutePreference ? _preferredMute : null;
                    if (!TryApplyTransaction(newSessions, volume, mute, canApplyPreference))
                    {
                        if (canApplyPreference is not null && !canApplyPreference())
                            _knownSessionIds = previousSessionIds;
                        else
                            RecordNewSessionPreferenceFailures(newSessions);
                        MarkUnavailable();
                        return;
                    }
                    if (!TryRefreshStates(newSessions))
                    {
                        if (canApplyPreference is not null && !canApplyPreference())
                            _knownSessionIds = previousSessionIds;
                        else
                            RecordNewSessionPreferenceFailures(newSessions);
                        MarkUnavailable();
                        return;
                    }
                    foreach (var session in newSessions)
                    {
                        _knownSessionIds.Add(session.InstanceId);
                        _newSessionPreferenceAttempts.Remove(session.InstanceId);
                    }
                }

                // Distinct owned sessions with divergent state cannot be represented safely by one
                // slider/mute value. Do not choose a session or silently normalize it in the background.
                if (!HaveConsistentState(sessions))
                {
                    MarkUnavailable();
                    return;
                }

                _volume = sessions[0].Volume;
                _muted = sessions[0].Muted;
                _available = true;
            }
            finally
            {
                ReleaseSessions(sessions);
            }
        }
        finally
        {
            if (uninitializeCom)
                CoUninitialize();
        }
    }



    public void SetPreferredOutput(double volume, bool? muted)
    {
        if (!double.IsFinite(volume) || volume < 0 || volume > 1)
            throw new ArgumentOutOfRangeException(nameof(volume), "Volume must be finite and between 0 and 1.");

        if (_disposed)
            return;

        _preferredVolume = (float)volume;
        if (muted is { } preferredMute)
        {
            _hasMutePreference = true;
            _preferredMute = preferredMute;
        }
    }

    public bool TrySetVolume(double value, Func<bool>? canApplyPreference = null)
    {
        if (!double.IsFinite(value) || value < 0 || value > 1 || _disposed)
            return false;
        if (!TryInitializeComMta(out var uninitializeCom))
        {
            MarkUnavailable();
            return false;
        }

        List<AudioSession> sessions = [];
        try
        {
            if (!TryGetCurrentSessions(out sessions))
                return false;

            var requested = (float)value;
            if (!TryApplyTransaction(sessions, requested, null, canApplyPreference))
            {
                MarkUnavailable();
                return false;
            }

            if (!TryRefreshStates(sessions) || !HaveRequestedVolume(sessions, requested))
            {
                MarkUnavailable();
                return false;
            }

            _preferredVolume = requested;
            RememberSessions(sessions);
            if (HaveConsistentState(sessions))
                SetObservedState(sessions);
            else
                MarkUnavailable();
            return true;
        }
        finally
        {
            ReleaseSessions(sessions);
            if (uninitializeCom)
                CoUninitialize();
        }
    }

    public bool TrySetMute(bool requested, Func<bool>? canApplyPreference = null)
    {
        if (_disposed || !TryInitializeComMta(out var uninitializeCom))
        {
            MarkUnavailable();
            return false;
        }

        List<AudioSession> sessions = [];
        try
        {
            if (!TryGetCurrentSessions(out sessions))
                return false;

            if (!TryApplyTransaction(sessions, null, requested, canApplyPreference))
            {
                MarkUnavailable();
                return false;
            }

            if (!TryRefreshStates(sessions) || !HaveRequestedMute(sessions, requested))
            {
                MarkUnavailable();
                return false;
            }

            _hasMutePreference = true;
            _preferredMute = requested;
            RememberSessions(sessions);
            if (HaveConsistentState(sessions))
                SetObservedState(sessions);
            else
                MarkUnavailable();
            return true;
        }
        finally
        {
            ReleaseSessions(sessions);
            if (uninitializeCom)
                CoUninitialize();
        }
    }

    public void Dispose()
    {
        if (_disposed)
            return;

        _disposed = true;
        _activeProcessIds.Clear();
        foreach (var processHandle in _processHandles.Values)
            processHandle.Dispose();
        _processHandles.Clear();
        _retiredProcessIds.Clear();
        _newSessionPreferenceAttempts.Clear();
        MarkUnavailable(clearKnownSessions: true);
    }

    private bool TryGetCurrentSessions(out List<AudioSession> sessions)
    {
        sessions = [];
        if (_disposed || _activeProcessIds.Count == 0
            || !AreOwnedProcessesAlive(_activeProcessIds, _processHandles))
        {
            _hasVerifiedOwnedSessions = false;
            MarkUnavailable();
            return false;
        }

        if (!TryEnumerateOwnedSessions(_activeProcessIds, _processHandles, out sessions)
            || sessions.Count == 0)
        {
            _hasVerifiedOwnedSessions = false;
            MarkUnavailable();
            return false;
        }

        _hasVerifiedOwnedSessions = true;
        return true;
    }

    private bool TryActivateOwnedProcesses(IReadOnlySet<int> processIds)
    {
        _activeProcessIds.Clear();
        RetireExitedProcesses();
        if (processIds.Count == 0)
            return false;

        var candidateProcessIds = new HashSet<int>();
        foreach (var processId in processIds)
        {
            if (processId <= 0)
                return false;
            if (_retiredProcessIds.Contains(processId))
                return false;

            if (_processHandles.TryGetValue(processId, out var retainedHandle))
            {
                if (!IsProcessAlive(retainedHandle))
                {
                    RetireProcess(processId);
                    return false;
                }
            }
            else
            {
                var processHandle = OpenProcess(
                    ProcessQueryLimitedInformation | Synchronize,
                    inheritHandle: false,
                    (uint)processId);
                if (processHandle is null || processHandle.IsInvalid)
                {
                    processHandle?.Dispose();
                    return false;
                }

                if (!TryGetProcessImagePath(processHandle, out var imagePath))
                {
                    processHandle.Dispose();
                    return false;
                }
                if (!PathsEqual(imagePath, _expectedBrowserExecutablePath))
                {
                    processHandle.Dispose();
                    return false;
                }
                if (!IsProcessAlive(processHandle))
                {
                    _retiredProcessIds.Add(processId);
                    processHandle.Dispose();
                    return false;
                }

                // Keep every verified handle until disposal, even if this PID set later fails
                // validation. A held process object prevents PID reuse from changing identity.
                _processHandles.Add(processId, processHandle);
            }

            candidateProcessIds.Add(processId);
        }

        foreach (var processId in candidateProcessIds)
        {
            if (!_processHandles.TryGetValue(processId, out var processHandle)
                || !IsProcessAlive(processHandle))
            {
                RetireProcess(processId);
                return false;
            }
        }

        _activeProcessIds = candidateProcessIds;
        return true;
    }


    private void RetireExitedProcesses()
    {
        foreach (var processId in _processHandles.Keys.ToArray())
        {
            if (_processHandles.TryGetValue(processId, out var processHandle) && !IsProcessAlive(processHandle))
                RetireProcess(processId);
        }
    }

    private void RetireProcess(int processId)
    {
        _retiredProcessIds.Add(processId);
        if (_processHandles.Remove(processId, out var processHandle))
            processHandle.Dispose();
    }


    private static bool AreOwnedProcessesAlive(
        IReadOnlySet<int> processIds,
        IReadOnlyDictionary<int, SafeProcessHandle> processHandles)
    {
        if (processIds.Count == 0)
            return false;
        foreach (var processId in processIds)
        {
            if (!processHandles.TryGetValue(processId, out var processHandle) || !IsProcessAlive(processHandle))
                return false;
        }
        return true;
    }

    private static bool TryInitializeComMta(out bool uninitializeCom)
    {
        uninitializeCom = false;
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.MTA)
            return false;

        var result = CoInitializeEx(0, CoInitMultithreaded);
        if (result != S_OK && result != S_FALSE)
            return false;

        uninitializeCom = true;
        return true;
    }

    private static bool IsProcessAlive(SafeProcessHandle processHandle) =>
        !processHandle.IsClosed
        && !processHandle.IsInvalid
        && WaitForSingleObject(processHandle, 0) == WaitTimeout;

    private static bool TryGetProcessImagePath(SafeProcessHandle processHandle, out string imagePath)
    {
        imagePath = string.Empty;
        for (var capacity = 512; capacity <= MaximumProcessImagePathLength; capacity = Math.Min(
                 capacity * 2,
                 MaximumProcessImagePathLength))
        {
            var buffer = new StringBuilder(capacity);
            uint length = (uint)buffer.Capacity;
            if (QueryFullProcessImageNameW(processHandle, 0, buffer, ref length))
            {
                imagePath = buffer.ToString();
                return length > 0
                    && length <= (uint)buffer.Capacity
                    && imagePath.Length == (int)length;
            }

            if (Marshal.GetLastWin32Error() != ErrorInsufficientBuffer
                || capacity == MaximumProcessImagePathLength)
                return false;
        }
        return false;
    }

    private static bool PathsEqual(string actualPath, string expectedPath)
    {
        try
        {
            if (!Path.IsPathFullyQualified(actualPath))
                return false;

            return string.Equals(
                Path.GetFullPath(actualPath),
                expectedPath,
                StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception exception) when (
            exception is ArgumentException or NotSupportedException or PathTooLongException)
        {
            return false;
        }
    }

    private void RememberSessions(List<AudioSession> sessions) =>
        _knownSessionIds = sessions.Select(static session => session.InstanceId)
            .ToHashSet(StringComparer.Ordinal);

    private void SetObservedState(List<AudioSession> sessions)
    {
        _volume = sessions[0].Volume;
        _muted = sessions[0].Muted;
        _available = true;
    }

    private void MarkUnavailable(bool clearKnownSessions = false)
    {
        _available = false;
        _volume = 0;
        _muted = false;
        if (clearKnownSessions)
            _knownSessionIds.Clear();
    }

    private static bool TryEnumerateOwnedSessions(
        IReadOnlySet<int> ownedProcessIds,
        IReadOnlyDictionary<int, SafeProcessHandle> processHandles,
        out List<AudioSession> ownedSessions)
    {
        ownedSessions = [];
        if (!AreOwnedProcessesAlive(ownedProcessIds, processHandles))
            return false;

        IMMDeviceEnumerator? deviceEnumerator = null;
        IMMDeviceCollection? devices = null;
        var complete = false;
        try
        {
            var classId = MmDeviceEnumeratorClassId;
            var interfaceId = MmDeviceEnumeratorInterfaceId;
            var result = CoCreateInstance(ref classId, 0, ClsCtxAll, ref interfaceId, out deviceEnumerator);
            if (result != S_OK || deviceEnumerator is null)
                return false;

            result = deviceEnumerator.EnumAudioEndpoints(DataFlow.Render, DeviceStateActive, out devices);
            if (result != S_OK || devices is null)
                return false;
            result = devices.GetCount(out var endpointCount);
            if (result != S_OK || endpointCount > MaximumRenderEndpointCount)
                return false;
            if (endpointCount == 0)
            {
                complete = true;
                return true;
            }

            var seenInstanceIds = new HashSet<string>(StringComparer.Ordinal);
            for (uint endpointIndex = 0; endpointIndex < endpointCount; endpointIndex++)
            {
                IMMDevice? device = null;
                object? managerObject = null;
                IAudioSessionEnumerator? sessionEnumerator = null;
                try
                {
                    result = devices.Item(endpointIndex, out device);
                    if (result != S_OK || device is null)
                        return false;

                    var managerInterfaceId = AudioSessionManager2InterfaceId;
                    result = device.Activate(ref managerInterfaceId, ClsCtxAll, 0, out managerObject);
                    if (result != S_OK || managerObject is not IAudioSessionManager2 manager)
                        return false;
                    result = manager.GetSessionEnumerator(out sessionEnumerator);
                    if (result != S_OK || sessionEnumerator is null)
                        return false;
                    result = sessionEnumerator.GetCount(out var sessionCount);
                    if (result != S_OK || sessionCount < 0 || sessionCount > MaximumSessionCount)
                        return false;

                    for (var index = 0; index < sessionCount; index++)
                    {
                        IAudioSessionControl? control = null;
                        try
                        {
                            result = sessionEnumerator.GetSession(index, out control);
                            if (result != S_OK || control is null)
                                return false;

                            IAudioSessionControl2 control2;
                            try
                            {
                                control2 = (IAudioSessionControl2)control;
                            }
                            catch (InvalidCastException)
                            {
                                return false;
                            }

                            var processResult = control2.GetProcessId(out var processId);
                            // Windows explicitly reports shared mixed-process sessions as not attributable
                            // to a single PID. They cannot belong to the exact WebView PID set, so skip them.
                            if (IsMixedAudioSessionProcessResult(processResult))
                                continue;
                            if (processResult != S_OK)
                                return false;
                            if (!IsOwnedWebViewProcessId(processId, ownedProcessIds))
                                continue;

                            var ownerProcessId = (int)processId;
                            if (!processHandles.TryGetValue(ownerProcessId, out var ownerHandle)
                                || !IsProcessAlive(ownerHandle))
                                return false;
                            if (!TryGetInstanceId(control2, out var instanceId)
                                || !seenInstanceIds.Add(instanceId))
                                return false;
                            if (!TryReadState(control, out var state))
                                return false;

                            ownedSessions.Add(new AudioSession(control, ownerProcessId, instanceId, state.Volume, state.Muted));
                            control = null;
                        }
                        finally
                        {
                            ReleaseComObject(control);
                        }
                    }
                }
                finally
                {
                    ReleaseComObject(sessionEnumerator);
                    ReleaseComObject(managerObject);
                    ReleaseComObject(device);
                }
            }

            if (!AreOwnedProcessesAlive(ownedProcessIds, processHandles))
                return false;

            complete = true;
            return true;
        }
        catch (Exception exception) when (IsInteropFailure(exception))
        {
            return false;
        }
        finally
        {
            ReleaseComObject(devices);
            ReleaseComObject(deviceEnumerator);
            if (!complete)
                ReleaseSessions(ownedSessions);
        }
    }



    internal static bool IsMixedAudioSessionProcessResult(int result) =>
        result == AudclntSNoSingleProcess;

    internal static bool IsOwnedWebViewProcessId(uint processId, IReadOnlySet<int> ownedProcessIds) =>
        processId > 0
        && processId <= int.MaxValue
        && ownedProcessIds.Contains((int)processId);
    internal static bool ShouldRetryNewSessionPreference(int failedAttempts) =>
        failedAttempts >= 0 && failedAttempts < MaximumNewSessionPreferenceAttempts;

    private void RecordNewSessionPreferenceFailures(List<AudioSession> sessions)
    {
        foreach (var session in sessions)
        {
            var attempts = _newSessionPreferenceAttempts.GetValueOrDefault(session.InstanceId) + 1;
            if (ShouldRetryNewSessionPreference(attempts))
            {
                _newSessionPreferenceAttempts[session.InstanceId] = attempts;
            }
            else
            {
                _newSessionPreferenceAttempts[session.InstanceId] =
                    MaximumNewSessionPreferenceAttempts;
                _knownSessionIds.Add(session.InstanceId);
            }
        }
    }


    private static bool TryGetInstanceId(
        IAudioSessionControl2 control,
        out string instanceId)
    {
        instanceId = string.Empty;
        nint buffer = 0;
        try
        {
            var result = control.GetSessionInstanceIdentifier(out buffer);
            if (result != S_OK || buffer == 0)
                return false;
            instanceId = Marshal.PtrToStringUni(buffer) ?? string.Empty;
            return instanceId.Length > 0;
        }
        catch (Exception exception) when (IsInteropFailure(exception))
        {
            return false;
        }
        finally
        {
            if (buffer != 0)
                Marshal.FreeCoTaskMem(buffer);
        }
    }


    private static bool TryReadState(
        IAudioSessionControl control,
        out SessionState state)
    {
        state = default;
        try
        {
            ISimpleAudioVolume volume;
            try
            {
                volume = (ISimpleAudioVolume)control;
            }
            catch (InvalidCastException)
            {
                return false;
            }
            var result = volume.GetMasterVolume(out var level);
            if (result != S_OK)
                return false;
            result = volume.GetMute(out var muted);
            if (result != S_OK)
                return false;
            if (!float.IsFinite(level) || level < 0 || level > 1)
                return false;

            state = new SessionState(level, muted);
            return true;
        }
        catch (Exception exception) when (IsInteropFailure(exception))
        {
            return false;
        }
    }


    private static bool TryRefreshStates(List<AudioSession> sessions)
    {
        foreach (var session in sessions)
        {
            if (!TryReadState(session.Control, out var state))
                return false;
            session.Volume = state.Volume;
            session.Muted = state.Muted;
        }
        return true;
    }


    private static bool HaveConsistentState(List<AudioSession> sessions) =>
        AreOutputStatesConsistent(sessions
            .Select(static session => (session.Volume, session.Muted))
            .ToArray());

    internal static bool AreOutputStatesConsistent(
        IReadOnlyList<(float Volume, bool Muted)> sessions)
    {
        if (sessions.Count == 0)
            return false;

        var first = sessions[0];
        for (var index = 1; index < sessions.Count; index++)
        {
            var session = sessions[index];
            if (session.Muted != first.Muted
                || Math.Abs(session.Volume - first.Volume) > VolumeTolerance)
                return false;
        }
        return true;
    }

    private static bool HaveRequestedVolume(List<AudioSession> sessions, float requested) =>
        sessions.Count > 0
        && sessions.All(session => Math.Abs(session.Volume - requested) <= VolumeTolerance);

    private static bool HaveRequestedMute(List<AudioSession> sessions, bool requested) =>
        sessions.Count > 0
        && sessions.All(session => session.Muted == requested);

    private bool TryApplyTransaction(
        List<AudioSession> sessions, float? requestedVolume, bool? requestedMute,
        Func<bool>? canApplyPreference = null)
    {
        if (sessions.Count == 0 || requestedVolume is null && requestedMute is null)
            return false;

        var previous = new SessionState[sessions.Count];
        for (var index = 0; index < sessions.Count; index++)
        {
            if (!TryReadState(sessions[index].Control, out previous[index]))
                return false;
        }

        if (canApplyPreference is not null && !canApplyPreference())
            return false;
        var attemptedCount = 0;
        var succeeded = true;
        for (var index = 0; index < sessions.Count; index++)
        {
            attemptedCount = index + 1;
            if (canApplyPreference is not null && !canApplyPreference())
            {
                succeeded = false;
                break;
            }
            if (requestedVolume is { } level && !TrySetRawVolume(sessions[index], level))
            {
                succeeded = false;
                break;
            }
            if (canApplyPreference is not null && !canApplyPreference())
            {
                succeeded = false;
                break;
            }
            if (requestedMute is { } muted && !TrySetRawMute(sessions[index], muted))
            {
                succeeded = false;
                break;
            }
        }

        if (succeeded)
        {
            for (var index = 0; index < sessions.Count; index++)
            {
                if (!TryReadState(sessions[index].Control, out var current)
                    || (requestedVolume is { } level && Math.Abs(current.Volume - level) > VolumeTolerance)
                    || (requestedMute is { } muted && current.Muted != muted))
                {
                    succeeded = false;
                    attemptedCount = sessions.Count;
                    break;
                }
                sessions[index].Volume = current.Volume;
                sessions[index].Muted = current.Muted;
            }
        }

        if (succeeded)
            return true;

        // Restore only values still equal to the requested value (or original snapshot). If an
        // external controller changed a session concurrently, do not overwrite that newer state.
        for (var index = attemptedCount - 1; index >= 0; index--)
        {
            if (!TryReadState(sessions[index].Control, out var current))
                continue;

            if (requestedVolume is { } targetVolume
                && Math.Abs(current.Volume - previous[index].Volume) > VolumeTolerance)
            {
                if (Math.Abs(current.Volume - targetVolume) <= VolumeTolerance)
                    TrySetRawVolume(sessions[index], previous[index].Volume);
            }
            if (requestedMute is { } targetMute && current.Muted != previous[index].Muted)
            {
                if (current.Muted == targetMute)
                    TrySetRawMute(sessions[index], previous[index].Muted);
            }
        }

        for (var index = 0; index < attemptedCount; index++)
        {
            if (!TryReadState(sessions[index].Control, out var restored)
                || (requestedVolume is not null
                    && Math.Abs(restored.Volume - previous[index].Volume) > VolumeTolerance)
                || (requestedMute is not null && restored.Muted != previous[index].Muted))
                return false;
        }
        return false;
    }

    private bool TrySetRawVolume(AudioSession session, float value)
    {
        try
        {
            var volume = (ISimpleAudioVolume)session.Control;
            var eventContext = Guid.Empty;
            if (!_activeProcessIds.Contains(session.ProcessId)
                || !_processHandles.TryGetValue(session.ProcessId, out var ownerHandle)
                || !AreOwnedProcessesAlive(_activeProcessIds, _processHandles)
                || !IsProcessAlive(ownerHandle))
                return false;
            return volume.SetMasterVolume(value, ref eventContext) == S_OK;
        }
        catch (Exception exception) when (IsInteropFailure(exception))
        {
            return false;
        }
    }

    private bool TrySetRawMute(AudioSession session, bool muted)
    {
        try
        {
            var volume = (ISimpleAudioVolume)session.Control;
            var eventContext = Guid.Empty;
            if (!_activeProcessIds.Contains(session.ProcessId)
                || !_processHandles.TryGetValue(session.ProcessId, out var ownerHandle)
                || !AreOwnedProcessesAlive(_activeProcessIds, _processHandles)
                || !IsProcessAlive(ownerHandle))
                return false;
            return volume.SetMute(muted, ref eventContext) == S_OK;
        }
        catch (Exception exception) when (IsInteropFailure(exception))
        {
            return false;
        }
    }


    private static bool IsInteropFailure(Exception exception) =>
        exception is COMException
            or ExternalException
            or InvalidCastException
            or MarshalDirectiveException
            or ArgumentException
            or InvalidOperationException;

    private static void ReleaseSessions(List<AudioSession> sessions)
    {
        foreach (var session in sessions)
            ReleaseComObject(session.Control);
        sessions.Clear();
    }

    private static void ReleaseComObject(object? instance)
    {
        if (instance is null)
            return;
        try
        {
            if (Marshal.IsComObject(instance))
                Marshal.FinalReleaseComObject(instance);
        }
        catch
        {
            // Cleanup must not mask a failed native operation.
        }
    }

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoCreateInstance(
        [In] ref Guid classId,
        nint outer,
        uint classContext,
        [In] ref Guid interfaceId,
        [MarshalAs(UnmanagedType.Interface)] out IMMDeviceEnumerator instance);

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern int CoInitializeEx(nint reserved, uint coInit);

    [DllImport("ole32.dll", ExactSpelling = true)]
    private static extern void CoUninitialize();

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(
        uint desiredAccess,
        [MarshalAs(UnmanagedType.Bool)] bool inheritHandle,
        uint processId);

    [DllImport(
        "kernel32.dll",
        EntryPoint = "QueryFullProcessImageNameW",
        ExactSpelling = true,
        CharSet = CharSet.Unicode,
        SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool QueryFullProcessImageNameW(
        SafeProcessHandle processHandle,
        uint flags,
        StringBuilder imageName,
        ref uint size);

    [DllImport("kernel32.dll", ExactSpelling = true)]
    private static extern uint WaitForSingleObject(SafeProcessHandle handle, uint milliseconds);

    private enum DataFlow
    {
        Render = 0,
        Capture = 1,
        All = 2
    }


    [ComImport]
    [Guid("A95664D2-9614-4F35-A746-DE8DB63617E6")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceEnumerator
    {
        [PreserveSig]
        int EnumAudioEndpoints(DataFlow dataFlow, uint stateMask, out IMMDeviceCollection devices);

    }

    // IID matches IMMDeviceCollection in the Windows SDK mmdeviceapi.h.
    [ComImport]
    [Guid("0BD7A1BE-7A1A-44DB-8397-CC5392387B5E")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDeviceCollection
    {
        [PreserveSig]
        int GetCount(out uint deviceCount);

        [PreserveSig]
        int Item(uint deviceNumber, out IMMDevice device);
    }

    [ComImport]
    [Guid("D666063F-1587-4E43-81F1-B948E807363F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IMMDevice
    {
        [PreserveSig]
        int Activate(
            [In] ref Guid interfaceId,
            uint classContext,
            nint activationParameters,
            [MarshalAs(UnmanagedType.IUnknown)] out object activatedInterface);
    }

    [ComImport]
    [Guid("77AA99A0-1BD6-484F-8BC7-2C654C9A9B6F")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionManager2
    {
        [PreserveSig]
        int GetAudioSessionControl([In] ref Guid sessionGuid, uint streamFlags, out IAudioSessionControl sessionControl);

        [PreserveSig]
        int GetSimpleAudioVolume([In] ref Guid sessionGuid, uint streamFlags, out ISimpleAudioVolume audioVolume);

        [PreserveSig]
        int GetSessionEnumerator(out IAudioSessionEnumerator sessionEnumerator);
    }

    [ComImport]
    [Guid("E2F5BB11-0570-40CA-ACDD-3AA01277DEE8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionEnumerator
    {
        [PreserveSig]
        int GetCount(out int count);

        [PreserveSig]
        int GetSession(int index, out IAudioSessionControl sessionControl);
    }

    [ComImport]
    [Guid("F4B1A599-7266-4319-A8CA-E70ACB11E8CD")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl
    {
        [PreserveSig]
        int GetState(out int state);

        [PreserveSig]
        int GetDisplayName(out nint displayName);

        [PreserveSig]
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string displayName, [In] ref Guid eventContext);

        [PreserveSig]
        int GetIconPath(out nint iconPath);

        [PreserveSig]
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string iconPath, [In] ref Guid eventContext);

        [PreserveSig]
        int GetGroupingParam(out Guid groupingId);

        [PreserveSig]
        int SetGroupingParam([In] ref Guid groupingId, [In] ref Guid eventContext);

        [PreserveSig]
        int RegisterAudioSessionNotification(nint notification);

        [PreserveSig]
        int UnregisterAudioSessionNotification(nint notification);
    }

    // Flatten the inherited IAudioSessionControl vtable before declaring the five Control2 methods.
    [ComImport]
    [Guid("BFB7FF88-7239-4FC9-8FA2-07C950BE9C6D")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IAudioSessionControl2
    {
        [PreserveSig]
        int GetState(out int state);

        [PreserveSig]
        int GetDisplayName(out nint displayName);

        [PreserveSig]
        int SetDisplayName([MarshalAs(UnmanagedType.LPWStr)] string displayName, [In] ref Guid eventContext);

        [PreserveSig]
        int GetIconPath(out nint iconPath);

        [PreserveSig]
        int SetIconPath([MarshalAs(UnmanagedType.LPWStr)] string iconPath, [In] ref Guid eventContext);

        [PreserveSig]
        int GetGroupingParam(out Guid groupingId);

        [PreserveSig]
        int SetGroupingParam([In] ref Guid groupingId, [In] ref Guid eventContext);

        [PreserveSig]
        int RegisterAudioSessionNotification(nint notification);

        [PreserveSig]
        int UnregisterAudioSessionNotification(nint notification);

        [PreserveSig]
        int GetSessionIdentifier(out nint sessionIdentifier);

        [PreserveSig]
        int GetSessionInstanceIdentifier(out nint sessionInstanceIdentifier);

        [PreserveSig]
        int GetProcessId(out uint processId);

        [PreserveSig]
        int IsSystemSoundsSession();

        [PreserveSig]
        int SetDuckingPreference([MarshalAs(UnmanagedType.Bool)] bool optOut);
    }

    [ComImport]
    [Guid("87CE5498-68D6-44E5-9215-6DA47EF883D8")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface ISimpleAudioVolume
    {
        [PreserveSig]
        int SetMasterVolume(float volume, [In] ref Guid eventContext);

        [PreserveSig]
        int GetMasterVolume(out float volume);

        [PreserveSig]
        int SetMute([MarshalAs(UnmanagedType.Bool)] bool muted, [In] ref Guid eventContext);

        [PreserveSig]
        int GetMute([MarshalAs(UnmanagedType.Bool)] out bool muted);
    }

    private readonly record struct SessionState(float Volume, bool Muted);

    private sealed class AudioSession(
        IAudioSessionControl control,
        int processId,
        string instanceId,
        float volume,
        bool muted)
    {
        public IAudioSessionControl Control { get; } = control;
        public int ProcessId { get; } = processId;
        public string InstanceId { get; } = instanceId;
        public float Volume { get; set; } = volume;
        public bool Muted { get; set; } = muted;
    }
}
