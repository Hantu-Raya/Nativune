using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32.SafeHandles;

namespace Nativune;

// Tray only: a hard 60 MiB working-set maximum on the main page's renderer cut the tray tree from 172-183 to
// 81-84 MiB private WS at +0.2 points of tree CPU (7 Oct 2026 memory-attribution runs). Allocation is unchanged;
// pages over the cap move to the standby list and soft-fault back in. The original limits are restored before
// every show, on page or browser process failure and on shutdown. Minimize, Compact and other views are untouched.
public sealed partial class WebHostWindow
{
    private const nint TrayRendererCapBytes = 60 << 20;
    private const uint QuotaMinEnable = 0x1, QuotaMinDisable = 0x2, QuotaMaxEnable = 0x4, QuotaMaxDisable = 0x8;
    private SafeProcessHandle? _trayCapHandle;
    private nint _trayCapOriginalMin, _trayCapOriginalMax;
    private uint _trayCapOriginalFlags;
    private int _trayCapGeneration;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer _trayCapTimer = null!;
    private bool _wasInTray;

    private bool IsInTray => _appWindow?.IsVisible == false;

    private async Task CapTrayRendererAsync()
    {
        var generation = ++_trayCapGeneration;
        bool Current() => generation == _trayCapGeneration && IsInTray && !_closing && !_disposed && _trayCapHandle is null;
        if (!Current()) return;
        var (processId, outcome) = await FindMainRendererAsync();
        if (!Current()) return;
        if (processId == 0) { TrayCapLog(outcome, 0); return; }

        const uint processSetQuota = 0x0100, processQueryLimitedInformation = 0x1000;
        var handle = OpenProcess(processSetQuota | processQueryLimitedInformation, false, processId);
        if (handle.IsInvalid) { handle.Dispose(); TrayCapLog("open-failed", processId); return; }
        // The open handle pins the PID from here on; a fresh snapshot proves it still hosts this view's main frame
        // (the PID could have been reused between the first snapshot and OpenProcess).
        var (recheckId, _) = await FindMainRendererAsync();
        if (!Current() || recheckId != processId)
        {
            handle.Dispose();
            if (Current()) TrayCapLog("renderer-changed", processId);
            return;
        }
        // Keep the renderer's own minimum: raising it needs a privilege a standard-user token lacks
        // (ERROR_PRIVILEGE_NOT_HELD, 7 Oct 2026 probe); only the maximum changes.
        if (!GetProcessWorkingSetSizeEx(handle.DangerousGetHandle(), out var min, out var max, out var flags)
            || min >= TrayRendererCapBytes
            || !SetProcessWorkingSetSizeEx(handle.DangerousGetHandle(), min, TrayRendererCapBytes, QuotaMinDisable | QuotaMaxEnable))
        {
            TrayCapLog($"apply-failed {new Win32Exception(Marshal.GetLastWin32Error()).Message}", processId);
            handle.Dispose();
            return;
        }
        _trayCapHandle = handle;
        (_trayCapOriginalMin, _trayCapOriginalMax, _trayCapOriginalFlags) = (min, max, flags);
        TrayCapLog("applied", processId);
    }

    // Exactly one renderer must host this view's main frame and no other view's main frame; no fallback.
    private async Task<(int ProcessId, string Outcome)> FindMainRendererAsync()
    {
        var core = _browserHost?.Core;
        if (_environment is null || core is null) return (0, "no-view");
        try
        {
            var frameId = core.FrameId;
            if (frameId == 0) return (0, "no-frame-id");
            var infos = await _environment.GetProcessExtendedInfosAsync();
            int processId = 0, matches = 0;
            foreach (var info in infos)
            {
                if (info.ProcessInfo.Kind != CoreWebView2ProcessKind.Renderer) continue;
                bool ours = false, foreign = false;
                foreach (var frame in info.AssociatedFrameInfos)
                {
                    if (frame.FrameKind != CoreWebView2FrameKind.MainFrame) continue;
                    if (frame.FrameId == frameId) ours = true;
                    else foreign = true;
                }
                if (!ours) continue;
                matches++;
                processId = foreign ? 0 : info.ProcessInfo.ProcessId;
            }
            return matches == 1 && processId != 0 ? (processId, "found")
                : (0, matches == 0 ? "renderer-not-found" : "renderer-ambiguous");
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException) { return (0, "discovery-failed"); }
    }

    private void ReleaseTrayRendererCap(string reason)
    {
        _trayCapGeneration++;
        var handle = _trayCapHandle;
        if (handle is null) return;
        var flags = ((_trayCapOriginalFlags & QuotaMinEnable) != 0 ? QuotaMinEnable : QuotaMinDisable)
            | ((_trayCapOriginalFlags & QuotaMaxEnable) != 0 ? QuotaMaxEnable : QuotaMaxDisable);
        // Never (-1, -1): that would empty the renderer's working set right before the window shows.
        var restored = SetProcessWorkingSetSizeEx(handle.DangerousGetHandle(), _trayCapOriginalMin, _trayCapOriginalMax, flags);
        var error = restored ? 0 : Marshal.GetLastWin32Error();
        // Fallback: drop both hard limits at the current sizes, so a visible window never keeps the cap.
        if (!restored && GetProcessWorkingSetSizeEx(handle.DangerousGetHandle(), out var currentMin, out var currentMax, out _))
            restored = SetProcessWorkingSetSizeEx(handle.DangerousGetHandle(), currentMin, currentMax, QuotaMinDisable | QuotaMaxDisable);
        const uint stillActive = 259;
        if (restored || (GetExitCodeProcess(handle, out var exitCode) && exitCode != stillActive))
        {
            handle.Dispose();
            _trayCapHandle = null;
            TrayCapLog(restored ? $"released {reason}" : $"released {reason} (process exited)", 0);
            return;
        }
        // Keep the handle so the next show, failure or shutdown retries the restore.
        TrayCapLog($"release-failed {reason} {new Win32Exception(error).Message}", 0);
    }

    private static void TrayCapLog(string outcome, int processId)
    {
        if (!outcome.StartsWith("applied", StringComparison.Ordinal) && !outcome.StartsWith("released", StringComparison.Ordinal))
            AppLog.Write("memory", $"Tray renderer cap: {outcome}");
#if NATIVUNE_PERF_BENCH_HOOKS
        BenchHooks.Event("tray-cap", ("outcome", outcome), ("pid", processId));
#endif
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessWorkingSetSizeEx(nint process, out nint minimumWorkingSetSize, out nint maximumWorkingSetSize, out uint flags);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetExitCodeProcess(SafeProcessHandle process, out uint exitCode);
}
