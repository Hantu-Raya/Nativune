namespace Nativune;

internal sealed partial class ObsOverlayServer
{
    // A failed designer renderer cannot reconnect until Retry. Reuse the existing expired-Connecting state:
    // a new nonce resets its deadline, admission makes it Open, and ordinary stream cleanup restarts the deadline.
    internal void MarkPreviewStopped(string? nonce)
    {
        List<StreamEntry> detached;
        ObsOverlayStreamCounts counts;
        lock (_gate)
        {
            if (_stopping || nonce is null || !string.Equals(nonce, _currentNonce, StringComparison.Ordinal)) return;
            detached = DetachPreviewStreamsLocked();
            _previewRefused = false;
            _previewSinceTicks = Environment.TickCount64 - PreviewConnectingMs - 1;
            counts = SnapshotLocked();
        }
        foreach (var stream in detached) stream.Retire();
        NotifyStreams(counts);
        if (detached.Count > 0) AppLog.Write(LogCategory, $"streams {counts.Total}");
    }
}
