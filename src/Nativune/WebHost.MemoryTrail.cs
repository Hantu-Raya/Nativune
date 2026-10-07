using Microsoft.Web.WebView2.Core;
using Microsoft.Win32.SafeHandles;
using System.Globalization;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace Nativune;

public sealed partial class WebHostWindow
{
    private const double MemoryTrailMiB = 1024d * 1024d;
    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _memoryTrailTimer;
    private CancellationTokenSource? _memoryTrailCancellation;
    private Task _memoryTrailPending = Task.CompletedTask;
    private bool _memoryTrailCollecting, _memoryTrailStopped, _memoryTrailDocumentReady, _memoryTrailLimitRead;
    private bool _memoryTrailFirstSamplePending;
    private int _memoryTrailDocument, _memoryTrailSample;
    private double? _memoryTrailHeapLimit;
    private string? _memoryTrailLastLine;
    private long _memoryTrailLastAt;

    private void InitializeMemoryTrail(CoreWebView2 core)
    {
        core.ContentLoading += (_, _) => MemoryTrailDocumentChanged();
        core.NavigationCompleted += (_, args) =>
        {
            if (!_configuringPrivacy && args.IsSuccess && args.NavigationId == _activeNavigation
                && args.NavigationId != _blockedNavigation) MemoryTrailPageReady();
        };
    }

    private void MemoryTrailDocumentChanged()
    {
        _memoryTrailCancellation?.Cancel();
        _memoryTrailDocument++;
        _memoryTrailDocumentReady = false;
        _memoryTrailLimitRead = false;
        _memoryTrailHeapLimit = null;
        if (_memoryTrailSample == 0) _memoryTrailFirstSamplePending = true;
    }

    private void MemoryTrailPageReady()
    {
        if (_memoryTrailStopped || _closing || _disposed || _browserFailed) return;
        _memoryTrailDocumentReady = true;
        if (_memoryTrailTimer is null)
        {
            _memoryTrailTimer = _dispatcherQueue.CreateTimer();
            _memoryTrailTimer.Interval = TimeSpan.FromMinutes(5);
#if NATIVUNE_PERF_BENCH_HOOKS
            _memoryTrailTimer.Interval = TimeSpan.FromSeconds(BenchHooks.MemoryTrailSeconds);
#endif
            _memoryTrailTimer.IsRepeating = true;
            _memoryTrailTimer.Tick += (_, _) => _ = CollectMemoryTrailAsync(writeSample: true);
        }
        var firstLoad = !_memoryTrailTimer.IsRunning;
        if (firstLoad)
        {
            _memoryTrailFirstSamplePending = true;
            _memoryTrailTimer.Start();
        }
        // Refresh the limit once for each committed document, without adding a row on every navigation.
        _ = CollectMemoryTrailAsync(writeSample: firstLoad);
    }

    private async Task CollectMemoryTrailAsync(bool writeSample)
    {
        writeSample |= _memoryTrailFirstSamplePending;
        if (_memoryTrailStopped || _closing || _disposed || _browserFailed || _memoryTrailCollecting
            || _browserHost is not { } host
            || (!writeSample && _memoryTrailLimitRead)) return;
        _memoryTrailCollecting = true;
        if (writeSample) _memoryTrailFirstSamplePending = false;
        var document = _memoryTrailDocument;
        var started = Environment.TickCount64;
        var session = AppLog.SessionMinutes;
        var mode = IsInTray ? "tray" : _compact ? "compact" : "full";
        double? jsUsed = null, jsTotal = null, documents = null, nodes = null, listeners = null;
        double? rendererAge = null, rendererPrivate = null, rendererWorkingSet = null, treePrivate = null;
        double? commitUsed = null, commitLimit = null, physicalAvailable = null;
        var status = "ok";
        using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        cancellation.CancelAfter(TimeSpan.FromSeconds(2));
        _memoryTrailCancellation = cancellation;
        try
        {
            // A timed-out WebView2 request may still be alive; wait within this sample's deadline, never overlap it.
            if (!_memoryTrailPending.IsCompleted) await _memoryTrailPending.WaitAsync(cancellation.Token);
            if (writeSample)
            {
                ReadMemoryTrailSystem(out commitUsed, out commitLimit, out physicalAvailable);
                cancellation.Token.ThrowIfCancellationRequested();
                var (processId, _) = await AwaitMemoryTrailAsync(FindMainRendererAsync(), cancellation.Token);
                if (processId != 0)
                {
                    using var handle = OpenProcess(0x1000, false, processId); // PROCESS_QUERY_LIMITED_INFORMATION
                    // Pin the process identity and confirm it still hosts this main frame before attributing counters.
                    cancellation.Token.ThrowIfCancellationRequested();
                    var (recheckId, _) = await AwaitMemoryTrailAsync(FindMainRendererAsync(), cancellation.Token);
                    if (!handle.IsInvalid && recheckId == processId
                        && TryReadMemoryTrailProcess(handle, out var counters))
                    {
                        rendererPrivate = (double)counters.PrivateUsage / MemoryTrailMiB;
                        rendererWorkingSet = (double)counters.WorkingSetSize / MemoryTrailMiB;
                        if (GetProcessTimes(handle, out var created, out _, out _, out _))
                            rendererAge = Math.Max(0, (DateTime.UtcNow - DateTime.FromFileTimeUtc(created)).TotalMinutes);
                    }
                }
                treePrivate = ReadMemoryTrailTree(cancellation.Token);
            }

            if (_memoryTrailDocumentReady && !_memoryTrailLimitRead && document == _memoryTrailDocument)
            {
                _memoryTrailLimitRead = true; // Unavailable/failed reads stay null; no retry in this document.
                using var limit = await MemoryTrailCallAsync(host.Core, "Runtime.evaluate",
                    "{\"expression\":\"performance.memory?.jsHeapSizeLimit\",\"returnByValue\":true,\"timeout\":1000}", cancellation.Token);
                if (document == _memoryTrailDocument && limit is not null
                    && limit.RootElement.TryGetProperty("result", out var result))
                    _memoryTrailHeapLimit = MemoryTrailNumber(result, "value") / MemoryTrailMiB;
            }
            if (writeSample)
            {
                using var heap = await MemoryTrailCallAsync(host.Core, "Runtime.getHeapUsage", "{}", cancellation.Token);
                if (heap is not null)
                {
                    jsUsed = MemoryTrailNumber(heap.RootElement, "usedSize") / MemoryTrailMiB;
                    jsTotal = MemoryTrailNumber(heap.RootElement, "totalSize") / MemoryTrailMiB;
                }
                using var dom = await MemoryTrailCallAsync(host.Core, "Memory.getDOMCounters", "{}", cancellation.Token);
                if (dom is not null)
                {
                    documents = MemoryTrailNumber(dom.RootElement, "documents");
                    nodes = MemoryTrailNumber(dom.RootElement, "nodes");
                    listeners = MemoryTrailNumber(dom.RootElement, "jsEventListeners");
                }
                if (jsUsed is null || jsTotal is null || _memoryTrailHeapLimit is null || documents is null
                    || nodes is null || listeners is null || rendererAge is null || rendererPrivate is null
                    || rendererWorkingSet is null || treePrivate is null || commitUsed is null
                    || commitLimit is null || physicalAvailable is null) status = "partial";
            }
        }
        catch (OperationCanceledException) { status = "timeout"; }
        catch (Exception) { status = "failed"; } // Never log CDP responses or exception messages.
        finally
        {
            _memoryTrailCancellation = null;
            _memoryTrailCollecting = false;
            // A load can finish while the previous document's cancelled collection is unwinding.
            if (_memoryTrailDocumentReady && !_memoryTrailStopped && !_closing && !_disposed && !_browserFailed
                && (_memoryTrailFirstSamplePending || document != _memoryTrailDocument && !_memoryTrailLimitRead))
                _dispatcherQueue.TryEnqueue(() => _ = CollectMemoryTrailAsync(writeSample: _memoryTrailFirstSamplePending));
        }
        if (!writeSample || _memoryTrailStopped || _closing || _disposed || _browserFailed
            || document != _memoryTrailDocument) return;
        var line = $"sample={++_memoryTrailSample} session_min={MemoryTrailFormat(session)} renderer_min={MemoryTrailFormat(rendererAge)} mode={mode} "
            + $"js_used_mib={MemoryTrailFormat(jsUsed)} js_total_mib={MemoryTrailFormat(jsTotal)} js_limit_mib={MemoryTrailFormat(_memoryTrailHeapLimit)} "
            + $"documents={MemoryTrailFormat(documents, "0")} nodes={MemoryTrailFormat(nodes, "0")} listeners={MemoryTrailFormat(listeners, "0")} "
            + $"renderer_private_mib={MemoryTrailFormat(rendererPrivate)} renderer_ws_mib={MemoryTrailFormat(rendererWorkingSet)} tree_private_mib={MemoryTrailFormat(treePrivate)} "
            + $"commit_used_mib={MemoryTrailFormat(commitUsed)} commit_limit_mib={MemoryTrailFormat(commitLimit)} phys_available_mib={MemoryTrailFormat(physicalAvailable)} "
            + $"collection_ms={Environment.TickCount64 - started} status={status}";
        _memoryTrailLastLine = line;
        _memoryTrailLastAt = started;
        AppLog.Write("memory-trail", line);
    }

    private async Task<T> AwaitMemoryTrailAsync<T>(Task<T> operation, CancellationToken token)
    {
        _memoryTrailPending = operation;
        try { return await operation.WaitAsync(token); }
        catch
        {
            // WaitAsync cannot cancel WebView2's call. Keep it as a barrier to overlapping requests after timeout.
            _ = ObserveMemoryTrailPendingAsync(operation);
            throw;
        }
    }

    private static async Task ObserveMemoryTrailPendingAsync(Task operation)
    {
        try { await operation; } catch (Exception) { }
    }

    private async Task<JsonDocument?> MemoryTrailCallAsync(CoreWebView2 core, string method, string parameters, CancellationToken token)
    {
        token.ThrowIfCancellationRequested();
        try { return JsonDocument.Parse(await AwaitMemoryTrailAsync(core.CallDevToolsProtocolMethodAsync(method, parameters).AsTask(), token)); }
        catch (OperationCanceledException) { throw; }
        catch (Exception) { return null; }
    }

    private static double? MemoryTrailNumber(JsonElement element, string name)
        => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value)
            && value.ValueKind == JsonValueKind.Number && value.TryGetDouble(out var number)
            && double.IsFinite(number) && number >= 0 ? number : null;

    private static string MemoryTrailFormat(double? value, string format = "0.0")
        => value?.ToString(format, CultureInfo.InvariantCulture) ?? "null";

    private void MemoryTrailBeforeFailure()
    {
        AppLog.Write("memory-trail-before-failure", _memoryTrailLastLine is { } line
            ? $"{line} age_min={MemoryTrailFormat((Environment.TickCount64 - _memoryTrailLastAt) / 60_000d)}"
            : "sample=null age_min=null");
        _memoryTrailTimer?.Stop();
        MemoryTrailDocumentChanged();
    }

    private void StopMemoryTrail()
    {
        _memoryTrailStopped = true;
        _memoryTrailTimer?.Stop();
        _memoryTrailCancellation?.Cancel();
    }

    private double? ReadMemoryTrailTree(CancellationToken token)
    {
        if (_environment is null) return null;
        try
        {
            double total = 0;
            var count = 0;
            foreach (var info in _environment.GetProcessInfos())
            {
                token.ThrowIfCancellationRequested();
                using var handle = OpenProcess(0x1000, false, info.ProcessId);
                if (!TryReadMemoryTrailProcess(handle, out var counters)) return null; // No misleading partial sum.
                total += (double)counters.PrivateUsage / MemoryTrailMiB;
                count++;
            }
            return count == 0 ? null : total;
        }
        catch (OperationCanceledException) { throw; }
        catch (Exception) { return null; }
    }

    private static bool TryReadMemoryTrailProcess(SafeProcessHandle handle, out MemoryTrailProcessCounters counters)
    {
        counters = new() { Size = (uint)Marshal.SizeOf<MemoryTrailProcessCounters>() };
        return !handle.IsInvalid && GetProcessMemoryInfo(handle, ref counters, counters.Size)
            && GetExitCodeProcess(handle, out var exitCode) && exitCode == 259; // STILL_ACTIVE
    }

    private static void ReadMemoryTrailSystem(out double? commitUsed, out double? commitLimit, out double? physicalAvailable)
    {
        commitUsed = commitLimit = physicalAvailable = null;
        var performance = new MemoryTrailPerformanceInfo { Size = (uint)Marshal.SizeOf<MemoryTrailPerformanceInfo>() };
        if (GetPerformanceInfo(ref performance, performance.Size))
        {
            commitUsed = (double)performance.CommitTotal * (double)performance.PageSize / MemoryTrailMiB;
            commitLimit = (double)performance.CommitLimit * (double)performance.PageSize / MemoryTrailMiB;
        }
        var memory = new MemoryTrailMemoryStatus { Length = (uint)Marshal.SizeOf<MemoryTrailMemoryStatus>() };
        if (GlobalMemoryStatusEx(ref memory)) physicalAvailable = memory.AvailablePhysical / MemoryTrailMiB;
    }

#pragma warning disable CS0649
    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryTrailProcessCounters
    {
        internal uint Size, PageFaultCount;
        internal nuint PeakWorkingSetSize, WorkingSetSize, QuotaPeakPagedPoolUsage, QuotaPagedPoolUsage;
        internal nuint QuotaPeakNonPagedPoolUsage, QuotaNonPagedPoolUsage, PagefileUsage, PeakPagefileUsage, PrivateUsage;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryTrailPerformanceInfo
    {
        internal uint Size;
        internal nuint CommitTotal, CommitLimit, CommitPeak, PhysicalTotal, PhysicalAvailable, SystemCache;
        internal nuint KernelTotal, KernelPaged, KernelNonpaged, PageSize;
        internal uint HandleCount, ProcessCount, ThreadCount;
    }
    [StructLayout(LayoutKind.Sequential)]
    private struct MemoryTrailMemoryStatus
    {
        internal uint Length, MemoryLoad;
        internal ulong TotalPhysical, AvailablePhysical, TotalPageFile, AvailablePageFile;
        internal ulong TotalVirtual, AvailableVirtual, AvailableExtendedVirtual;
    }
#pragma warning restore CS0649

    [DllImport("psapi.dll", SetLastError = true)]
    private static extern bool GetProcessMemoryInfo(SafeProcessHandle process, ref MemoryTrailProcessCounters counters, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GetProcessTimes(SafeProcessHandle process, out long creationTime, out long exitTime, out long kernelTime, out long userTime);
    [DllImport("psapi.dll", SetLastError = true)]
    private static extern bool GetPerformanceInfo(ref MemoryTrailPerformanceInfo information, uint size);
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool GlobalMemoryStatusEx(ref MemoryTrailMemoryStatus status);
}
