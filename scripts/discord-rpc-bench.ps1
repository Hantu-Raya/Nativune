<#
Discord Rich Presence resource benchmark, PROTOCOL VERSION 2 (plan: .cache/tmp/discord-rpc/opt-refactor-plan.md §1).
Measures the incremental cost of presence ON (READY-connected) versus OFF per native state, and optionally
compares a baseline (R) and candidate (C) hook build under the same schedule. Invalid runs exit nonzero; a
valid but inconclusive result exits 0 and is labelled as such.

  pwsh -NoProfile -File scripts/discord-rpc-bench.ps1 -BaselineAppDirectory artifacts/discord-rpc/app-r `
       -CandidateAppDirectory artifacts/discord-rpc/app-c -State All -Workload Playing

The script never builds or publishes; the integration owner publishes immutable hook builds
(-p:DiscordPresenceTestHooks=true) into separate directories. Either directory may be omitted for a
single-binary ON/OFF run.

FROZEN PROTOCOL v2 (fixed before any data; change only with a new, documented protocol version):
- A = ON: settings v7 DiscordPresence=true; requires handshake READY, a successful SET_ACTIVITY acknowledgement
  before warmup (Playing/Paused; Empty requires READY only) and one connection that stays connected through the
  measured window. B = OFF: DiscordPresence=false; requires zero IPC connections and zero SET_ACTIVITY frames.
  A missing Discord connection invalidates an ON run.
- Both conditions run the same isolated fake server (scripts/discord-rpc-test-server.ps1) on a fresh validated
  nativune-test-<32 hex>-discord-ipc- prefix, with deterministic server readiness. Production 15 s write gate and
  600 s pause timeout: NATIVUNE_TEST_DISCORD_MIN_WRITE_SECONDS/_PAUSE_SECONDS are unset. Environment keys are
  restored to their pre-run values afterwards.
- Hook build only (DiscordPresenceTestHooks=true); general performance hooks are not used. Each run: fresh root
  with a copy of the repository uBO Lite tree and fixed settings (full 1280x800, Compact 800x180, 96 DPI,
  StartCompact=false, SleepInBackground=false, AutoCheckUpdates=false, BlockAds=false, ReduceMotion=false).
- Workload profiles, selected natively in WebHost.DiscordFixture.cs via NATIVUNE_TEST_DISCORD_BENCH_PROFILE:
  Playing (track A, 1800 s, progressing), Paused (track A paused at 60 s), Empty (no coherent item).
- States via NATIVUNE_TEST_DISCORD_BENCH_STATE: Full (visible, not minimized); Hidden (Full, then native
  TryHideToTray(), must return true; AppWindow.IsVisible=false, tray visible); Compact (native SetCompact(true);
  Compact visible). The app writes <root>/data/discord-bench/ready.json after native page+state confirmation.
- Timing: wait up to 60 s for page/state readiness (and ON READY/ack), warm up 30 s, then measure 120 s with one
  sample per second (121 samples incl. endpoints) on actual monotonic elapsed time. Boundary diagnostics
  snapshots are requested just before the first and just after the last sample. No forced GC/trim, state
  changes or page probes in the scored interval.
- Order: 4 pairs per cell, ON/OFF exactly A B | B A | A B | B A. With two builds, pair-level interleaving
  R,C | C,R | R,C | C,R; each build keeps the pair's ON/OFF order. Fresh launch for every run. Cell order:
  Playing Full/Hidden/Compact, Paused Full/Hidden/Compact, Empty Full/Hidden/Compact (filtered by -State and
  -Workload). An invalid run causes the whole matched pair (all builds, both conditions) to be rerun, at most
  twice; then the cell is blocked. Invalid attempts are preserved.
- Tree: host pid plus recursive descendants, union msedgewebview2.exe whose command line contains the run root;
  identities are pid + process creation time; role from --type/--utility-sub-type. Complete-tree CPU % of one
  core = 100 * sum(per-process CPU deltas) / monotonic wall seconds (not divided by logical CPUs). A process
  present at the first sample counts from that sample; a newly born process counts its whole lifetime; an exited
  process keeps its last value. Fake server and harness are excluded.
- Memory: PrivateMemorySize64 and WorkingSet64 summed over the tree: mean, max, endpoint (decimal MB = 1e6 B).
  Working-set sums include shared pages. Nativune.exe handles and threads per sample: mean/max/first/last/delta.
- Page state reads: from the app's hook-only DiscordPresenceDiagnostics (dispatch-site counts, mode, script
  chars, validity) split into setup / in-window / teardown by QPC. SET_ACTIVITY writes: parsed `cmd` frames at
  the fake server, activity vs clear, acknowledgements, connection intervals.
- Statistics per cell and build, metric M in {cpu, privateMean, workingSetMean}: D_i = ON_i - OFF_i; report
  median D, all D, OFF range and robustSpread = 1.4826 * MAD(D). With R and C:
  N_M = max(OFF range R, OFF range C, 2*robustSpread(D_R), 2*robustSpread(D_C)); I_M = median(D_R) - median(D_C);
  paired D_R,i - D_C,i; raw ON and OFF C-R medians. Floors X: cpu 0.05 pp of one core, private 2 MB, working
  set 5 MB. A primary improvement needs I_M > max(N_M, X_M) and >= 3/4 positive paired improvements (for a
  shared-reader claim: the same rule on raw ON and raw OFF, noise from each condition's run spread). Any cell
  where the candidate is worse than max(noise, floor) is a regression. decision is one of invalid, not-scored,
  measurement-only, reject, inconclusive, candidate-pending-confirmation (a two-pair reversed confirmation block
  and all E2E gates are still required before adoption).
- Any override of -Pairs/-WarmupSeconds/-MeasureSeconds records protocol "2-override" (not v2-scored).
#>
[CmdletBinding()]
param(
    [ValidateSet('Full', 'Hidden', 'Compact', 'All')] [string] $State = 'All',
    [ValidateSet('Playing', 'Paused', 'Empty', 'All')] [string] $Workload = 'Playing',
    [string] $BaselineAppDirectory,
    [string] $CandidateAppDirectory,
    [ValidateSet('cpu', 'privateMean', 'workingSetMean')] [string] $PrimaryMetric = 'cpu',
    [ValidateSet('incremental', 'shared-reader')] [string] $ClaimKind = 'incremental',
    [ValidateRange(1, 50)] [int] $Pairs = 4,
    [ValidateRange(0, 3600)] [int] $WarmupSeconds = 30,
    [ValidateRange(2, 3600)] [int] $MeasureSeconds = 120,
    [string] $OutputDirectory = 'artifacts/discord-rpc/bench-v2'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$scriptText = Get-Content -Raw -LiteralPath $PSCommandPath
$protocolText = [regex]::Match($scriptText, '(?s)FROZEN PROTOCOL v2.*?(?=#>)').Value
$protocolHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($protocolText))).ToLowerInvariant()
$override = $Pairs -ne 4 -or $WarmupSeconds -ne 30 -or $MeasureSeconds -ne 120
$protocolVersion = if ($override) { '2-override' } else { '2' }
$commandLine = 'pwsh -NoProfile -File scripts/discord-rpc-bench.ps1 ' + (($PSBoundParameters.GetEnumerator() | ForEach-Object { "-$($_.Key) $($_.Value)" }) -join ' ')

function Resolve-AppDirectory([string] $Path) {
    if (-not $Path) { return $null }
    $full = if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $repo $Path }
    if (-not (Test-Path -LiteralPath (Join-Path $full 'Nativune.exe') -PathType Leaf)) { throw "Nativune.exe not found in $full." }
    (Resolve-Path -LiteralPath $full).Path
}
$builds = [Collections.Generic.List[object]]::new()
$baselineDir = Resolve-AppDirectory $BaselineAppDirectory
$candidateDir = Resolve-AppDirectory $CandidateAppDirectory
if ($baselineDir) { $builds.Add([ordered]@{ label = 'R'; directory = $baselineDir }) }
if ($candidateDir) { $builds.Add([ordered]@{ label = 'C'; directory = $candidateDir }) }
if ($builds.Count -eq 0) { throw 'Pass -BaselineAppDirectory and/or -CandidateAppDirectory (published hook builds).' }
if ($builds.Count -eq 2 -and $baselineDir -eq $candidateDir) { throw 'Baseline and candidate directories must differ.' }
foreach ($b in $builds) {
    $b.hashes = [ordered]@{}
    foreach ($file in 'Nativune.exe', 'Nativune.dll') {
        $path = Join-Path $b.directory $file
        if (Test-Path -LiteralPath $path) { $b.hashes[$file] = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() }
    }
    $b.productVersion = (Get-Item -LiteralPath (Join-Path $b.directory 'Nativune.exe')).VersionInfo.ProductVersion
}

$states = if ($State -eq 'All') { @('Full', 'Hidden', 'Compact') } else { @($State) }
$workloads = if ($Workload -eq 'All') { @('Playing', 'Paused', 'Empty') } else { @($Workload) }
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N')
$runDirectory = Join-Path $outputRoot $runId
$rootBase = Join-Path $repo ".cache/discord-rpc-bench/$runId"
$ubolVersion = [regex]::Match((Get-Content -Raw (Join-Path $repo 'src/Nativune/BrowserPrivacy.cs')), 'ExtensionVersion\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $ubolVersion) { throw 'Could not read BrowserPrivacy.ExtensionVersion.' }
$ubolSource = Join-Path $repo ".tools/ubol/$ubolVersion"
if (-not (Test-Path -LiteralPath (Join-Path $ubolSource 'manifest.json') -PathType Leaf)) { throw "uBO Lite $ubolVersion is missing at $ubolSource." }
$clientId = '100000000000000001'
$envKeys = @('NATIVUNE_TEST_DISCORD_PIPE_PREFIX', 'NATIVUNE_TEST_DISCORD_CLIENT_ID', 'NATIVUNE_TEST_DISCORD_FIXTURE_PAGE',
    'NATIVUNE_TEST_DISCORD_MIN_WRITE_SECONDS', 'NATIVUNE_TEST_DISCORD_PAUSE_SECONDS',
    'NATIVUNE_TEST_DISCORD_BENCH_PROFILE', 'NATIVUNE_TEST_DISCORD_BENCH_STATE')
$savedEnv = @{}
foreach ($key in $envKeys) { $savedEnv[$key] = [Environment]::GetEnvironmentVariable($key, 'Process') }
$started = [Collections.Generic.List[Diagnostics.Process]]::new()
$qpcFrequency = [Diagnostics.Stopwatch]::Frequency
$floors = @{ cpu = 0.05; privateMean = 2.0; workingSetMean = 5.0 }
$metricNames = @('cpu', 'privateMean', 'workingSetMean')

function Get-Prop($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}
function Read-Json([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try { Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -Depth 32 } catch { $null }
}
function Wait-File([string] $Path, [double] $Seconds) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    while ($clock.Elapsed.TotalSeconds -lt $Seconds) {
        if (Test-Path -LiteralPath $Path -PathType Leaf) { return $true }
        Start-Sleep -Milliseconds 100
    }
    Test-Path -LiteralPath $Path -PathType Leaf
}
function Get-Median([double[]] $Values) {
    $sorted = @($Values | Sort-Object); $n = $sorted.Count
    if ($n -eq 0) { return $null }
    if ($n % 2) { [double] $sorted[[int][Math]::Floor($n / 2)] } else { ([double] $sorted[$n / 2 - 1] + [double] $sorted[$n / 2]) / 2 }
}
function Get-Range([double[]] $Values) { if (@($Values).Count -eq 0) { return $null }; ($Values | Measure-Object -Maximum).Maximum - ($Values | Measure-Object -Minimum).Minimum }
function Get-RobustSpread([double[]] $Values) {
    if (@($Values).Count -eq 0) { return $null }
    $m = Get-Median $Values
    1.4826 * (Get-Median @($Values | ForEach-Object { [Math]::Abs($_ - $m) }))
}
function Get-Sum($Values) { $total = 0.0; foreach ($v in @($Values)) { if ($null -ne $v) { $total += [double] $v } }; $total }
function Get-Max($Values) { $v = @(@($Values) | Where-Object { $null -ne $_ }); if ($v.Count -eq 0) { return $null }; ($v | Measure-Object -Maximum).Maximum }
function Get-Stats([double[]] $Values) {
    $v = @($Values)
    if ($v.Count -eq 0) { return [ordered]@{ mean = $null; max = $null; first = $null; last = $null; delta = $null } }
    [ordered]@{ mean = ($v | Measure-Object -Average).Average; max = ($v | Measure-Object -Maximum).Maximum; first = $v[0]; last = $v[-1]; delta = $v[-1] - $v[0] }
}

function Write-Settings([string] $Root, [bool] $Enabled) {
    $data = Join-Path $Root 'data'
    [IO.Directory]::CreateDirectory($data) | Out-Null
    $settings = [ordered]@{
        Version = 7; X = 100; Y = 100; Width = 1280; Height = 800; Dpi = 96; Maximized = $false; Zoom = 1.0
        TrayEnabled = $true; RestoreSection = $false; LastSection = 'home'; ReduceMotion = $false
        CompactX = 100; CompactY = 100; CompactWidth = 800; CompactHeight = 180; CompactDpi = 96
        SleepInBackground = $false; StartCompact = $false; AutoCheckUpdates = $false
        OutputVolume = 1.0; BlockAds = $false
        DiscordPresence = $Enabled; DiscordStatusLine = 0; DiscordOpenButton = $true
    }
    [IO.File]::WriteAllText((Join-Path $data 'settings.json'), ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}

# Same discovery as scripts/discord-rpc-e2e.ps1 Get-ProcessTree (descendants + root-tagged WebView2), keeping
# creation time and command-line role so identities survive PID reuse.
function Get-TreeProcesses([int] $RootId, [string] $Root) {
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate)
    $ids = [Collections.Generic.HashSet[int]]::new(); [void] $ids.Add($RootId)
    do {
        $added = $false
        foreach ($p in $all) { if ($ids.Contains([int] $p.ParentProcessId) -and $ids.Add([int] $p.ProcessId)) { $added = $true } }
    } while ($added)
    foreach ($p in $all) {
        if ($p.Name -eq 'msedgewebview2.exe' -and $p.CommandLine -and $p.CommandLine.Contains($Root, [StringComparison]::OrdinalIgnoreCase)) { [void] $ids.Add([int] $p.ProcessId) }
    }
    @($all | Where-Object { $ids.Contains([int] $_.ProcessId) } | ForEach-Object {
        $line = [string] $_.CommandLine
        $type = [regex]::Match($line, '--type=([^\s"]+)').Groups[1].Value
        $sub = [regex]::Match($line, '--utility-sub-type=([^\s"]+)').Groups[1].Value
        $created = if ($_.CreationDate) { ([datetime] $_.CreationDate).ToUniversalTime().ToString('o') } else { '' }
        [pscustomobject]@{ pid = [int] $_.ProcessId; name = $_.Name; created = $created; key = "$($_.ProcessId)@$created"
            role = if ($_.Name -eq 'Nativune.exe') { 'host' } elseif ($type) { if ($sub) { "$type/$sub" } else { $type } } else { 'browser' } }
    })
}

function Stop-RootProcesses([string] $Root) {
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine)) {
        if ($p.CommandLine -and $p.CommandLine.Contains($Root, [StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}

function Read-Frames([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    @(Get-Content -LiteralPath $Path | Where-Object { $_ } | ForEach-Object { try { $_ | ConvertFrom-Json -Depth 32 } catch { } })
}
function Get-FrameMessage($Frame) { try { $Frame.json | ConvertFrom-Json -Depth 32 } catch { $null } }
function Test-OnConnected([object[]] $Frames, [bool] $NeedAck) {
    $ready = $false; $ack = $false
    foreach ($f in $Frames) {
        if ($f.direction -ne 'out' -or $f.opcode -ne 1) { continue }
        $m = Get-FrameMessage $f
        if ((Get-Prop $m 'evt') -eq 'READY') { $ready = $true }
        elseif ((Get-Prop $m 'cmd') -eq 'SET_ACTIVITY' -and $null -eq (Get-Prop $m 'evt')) { $ack = $true }
    }
    $ready -and (-not $NeedAck -or $ack)
}

function Test-StateEvidence($Evidence, [string] $Expected) {
    if (-not $Evidence) { return $false }
    switch ($Expected) {
        'Full' { [bool] ((Get-Prop $Evidence 'windowVisible') -and -not (Get-Prop $Evidence 'compact')) }
        'Hidden' { [bool] ((Get-Prop $Evidence 'appWindowVisible') -eq $false -and (Get-Prop $Evidence 'trayVisible') -and -not (Get-Prop $Evidence 'compact')) }
        'Compact' { [bool] ((Get-Prop $Evidence 'compact') -and (Get-Prop $Evidence 'windowVisible')) }
    }
}

function Invoke-Run($Cell, $Build, [int] $Pair, [int] $Attempt, [string] $Condition) {
    $name = "$($Cell.workload)-$($Cell.state)-$($Build.label)-p$Pair-a$Attempt-$Condition"
    $enabled = $Condition -eq 'on'
    $root = Join-Path $rootBase $name
    $runDir = Join-Path $runDirectory "runs/$name"
    [IO.Directory]::CreateDirectory($runDir) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $root '.tools/ubol')) | Out-Null
    Copy-Item -LiteralPath $ubolSource -Destination (Join-Path $root '.tools/ubol') -Recurse
    Write-Settings $root $enabled
    $benchDir = Join-Path $root 'data/discord-bench'
    $prefix = 'nativune-test-' + [guid]::NewGuid().ToString('N') + '-discord-ipc-'
    $frames = Join-Path $runDir 'frames.jsonl'
    $stop = Join-Path $runDir 'server-stop'
    $serverReady = Join-Path $runDir 'server-ready.json'
    $serverSummary = Join-Path $runDir 'server-summary.json'
    $problems = [Collections.Generic.List[string]]::new()
    $samples = [Collections.Generic.List[object]]::new()
    $processSamples = [Collections.Generic.List[object]]::new()
    $identities = @{}
    $app = $null; $server = $null; $appAliveAtEnd = $false; $graceful = $false; $windowQpc = $null
    $readyEvidence = $null; $startEvidence = $null; $endEvidence = $null; $readinessSeconds = $null
    try {
        $server = Start-Process -FilePath pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-File',
            (Join-Path $repo 'scripts/discord-rpc-test-server.ps1'), '-PipeName', ($prefix + '0'), '-FramesPath', $frames,
            '-StopFile', $stop, '-Mode', 'Normal', '-ReadyFile', $serverReady, '-SummaryPath', $serverSummary)
        $started.Add($server)
        if (-not (Wait-File $serverReady 15)) { throw 'fake server did not signal readiness' }

        foreach ($key in $envKeys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
        [Environment]::SetEnvironmentVariable('NATIVUNE_TEST_DISCORD_PIPE_PREFIX', $prefix, 'Process')
        [Environment]::SetEnvironmentVariable('NATIVUNE_TEST_DISCORD_CLIENT_ID', $clientId, 'Process')
        [Environment]::SetEnvironmentVariable('NATIVUNE_TEST_DISCORD_FIXTURE_PAGE', '1', 'Process')
        [Environment]::SetEnvironmentVariable('NATIVUNE_TEST_DISCORD_BENCH_PROFILE', $Cell.workload, 'Process')
        [Environment]::SetEnvironmentVariable('NATIVUNE_TEST_DISCORD_BENCH_STATE', $Cell.state, 'Process')
        $app = Start-Process -FilePath (Join-Path $Build.directory 'Nativune.exe') -ArgumentList @('web', '--root', $root) -WorkingDirectory $Build.directory -PassThru
        $started.Add($app)
        foreach ($key in $envKeys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }

        # Readiness: native page + state marker, and for ON the fake server's READY (+ ack when an item exists).
        $readyClock = [Diagnostics.Stopwatch]::StartNew()
        $needAck = $Cell.workload -ne 'Empty'
        while ($true) {
            if ($app.HasExited) { throw 'app exited before readiness' }
            $failed = Read-Json (Join-Path $benchDir 'failed.json')
            if ($failed) { throw "native setup failed: $(Get-Prop $failed 'reason')" }
            $readyEvidence = Read-Json (Join-Path $benchDir 'ready.json')
            if ($readyEvidence -and (-not $enabled -or (Test-OnConnected (Read-Frames $frames) $needAck))) { break }
            if ($readyClock.Elapsed.TotalSeconds -ge 60) { throw ('readiness timeout (' + $(if ($readyEvidence) { 'discord READY/ack' } else { 'native page/state' }) + ')') }
            Start-Sleep -Milliseconds 250
        }
        $readinessSeconds = $readyClock.Elapsed.TotalSeconds
        if (-not (Test-StateEvidence $readyEvidence $Cell.state)) { throw 'ready marker does not show the requested state' }

        $warm = [Diagnostics.Stopwatch]::StartNew()
        while ($warm.Elapsed.TotalSeconds -lt $WarmupSeconds) {
            if ($app.HasExited) { throw 'app exited during warmup' }
            Start-Sleep -Milliseconds 250
        }

        [IO.File]::WriteAllText((Join-Path $benchDir 'command-snapshot-start'), 'start')
        if (-not (Wait-File (Join-Path $benchDir 'state-start.json') 5)) { throw 'start diagnostics snapshot missing' }
        $startEvidence = Read-Json (Join-Path $benchDir 'state-start.json')

        $cpuByKey = @{}; $baseByKey = @{}
        $clock = [Diagnostics.Stopwatch]::StartNew()
        for ($i = 0; $i -le $MeasureSeconds; $i++) {
            $wait = [TimeSpan]::FromSeconds($i) - $clock.Elapsed
            if ($wait -gt [TimeSpan]::Zero) { Start-Sleep -Milliseconds ([int] $wait.TotalMilliseconds) }
            $qpc = [Diagnostics.Stopwatch]::GetTimestamp()
            if ($i -eq 0) { $windowQpc = @($qpc, $null) }
            $elapsed = $clock.Elapsed.TotalSeconds
            $private = 0L; $workingSet = 0L; $count = 0; $hostSeen = $false; $perProcess = @()
            foreach ($t in (Get-TreeProcesses $app.Id $root)) {
                $p = Get-Process -Id $t.pid -ErrorAction SilentlyContinue
                if (-not $p) { continue }
                try { $cpu = $p.TotalProcessorTime.TotalSeconds; $pv = $p.PrivateMemorySize64; $ws = $p.WorkingSet64 } catch { continue }
                $private += $pv; $workingSet += $ws; $count++
                if ($t.pid -eq $app.Id) { $hostSeen = $true }
                if (-not $identities.ContainsKey($t.key)) { $identities[$t.key] = [ordered]@{ pid = $t.pid; name = $t.name; role = $t.role; created = $t.created; firstSample = $i } }
                if (-not $baseByKey.ContainsKey($t.key)) { $baseByKey[$t.key] = if ($i -eq 0) { $cpu } else { 0.0 } }
                $cpuByKey[$t.key] = $cpu
                $perProcess += [ordered]@{ key = $t.key; cpuSeconds = $cpu; privateBytes = $pv; workingSetBytes = $ws }
            }
            $cpuTotal = 0.0
            foreach ($k in $cpuByKey.Keys) { $cpuTotal += $cpuByKey[$k] - $baseByKey[$k] }
            $handles = $null; $threads = $null
            try { $app.Refresh(); if (-not $app.HasExited) { $handles = $app.HandleCount; $threads = $app.Threads.Count } } catch { }
            if (-not $hostSeen) { $problems.Add("sample $i missing host process") }
            $samples.Add([ordered]@{ i = $i; t = $elapsed; qpc = $qpc; cpuSeconds = $cpuTotal; privateBytes = $private; workingSetBytes = $workingSet
                processes = $count; handles = $handles; threads = $threads })
            $processSamples.Add([ordered]@{ i = $i; processes = $perProcess })
        }
        $windowQpc[1] = $samples[-1].qpc
        [IO.File]::WriteAllText((Join-Path $benchDir 'command-snapshot-end'), 'end')
        if (-not (Wait-File (Join-Path $benchDir 'state-end.json') 5)) { throw 'end diagnostics snapshot missing' }
        $endEvidence = Read-Json (Join-Path $benchDir 'state-end.json')
        $appAliveAtEnd = -not $app.HasExited
        if (-not $appAliveAtEnd) { $problems.Add('app exited during measurement') }
    } catch {
        $problems.Add($_.Exception.Message)
    } finally {
        # Cancellation-safe collection, then the hook-only native Quit (normal Quit path); bounded forced cleanup.
        if ($app -and -not $app.HasExited -and (Test-Path -LiteralPath $benchDir)) {
            if (-not (Test-Path -LiteralPath (Join-Path $benchDir 'diagnostics-end.json'))) {
                [IO.File]::WriteAllText((Join-Path $benchDir 'command-snapshot-final'), 'final')
                [void] (Wait-File (Join-Path $benchDir 'diagnostics-final.json') 3)
            }
            [IO.File]::WriteAllText((Join-Path $benchDir 'command-quit'), 'quit')
            $graceful = $app.WaitForExit(15000)
        }
        if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force -ErrorAction SilentlyContinue }
        if ($app) { Stop-RootProcesses $root }
        foreach ($key in $envKeys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }
        [IO.File]::WriteAllText($stop, 'stop')
        if ($server -and -not $server.WaitForExit(8000)) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
        if (Test-Path -LiteralPath $benchDir) { Copy-Item -Path (Join-Path $benchDir '*.json') -Destination $runDir -ErrorAction SilentlyContinue }
        $log = Join-Path $root 'data/nativune.log'
        if (Test-Path -LiteralPath $log) { Copy-Item -LiteralPath $log -Destination (Join-Path $runDir 'nativune.log') }
    }

    # Reads (app diagnostics), split by the measured QPC interval.
    $diag = Read-Json (Join-Path $runDir 'diagnostics-end.json')
    if (-not $diag) { $diag = Read-Json (Join-Path $runDir 'diagnostics-final.json') }
    $quitDiag = Read-Json (Join-Path $runDir 'diagnostics-quit.json')
    $reads = $null
    if (-not $diag) { $problems.Add('diagnostics lost') }
    elseif ([long] $diag.dropped -gt 0) { $problems.Add('diagnostics buffer overflowed') }
    if ($diag -and $windowQpc -and $null -ne $windowQpc[1]) {
        $all = @(if ($quitDiag) { $quitDiag.reads } else { $diag.reads })
        $in = @($all | Where-Object { [long] $_.startQpc -ge $windowQpc[0] -and [long] $_.startQpc -le $windowQpc[1] })
        $reads = [ordered]@{
            total = $all.Count
            setup = @($all | Where-Object { [long] $_.startQpc -lt $windowQpc[0] }).Count
            inWindow = $in.Count
            teardown = @($all | Where-Object { [long] $_.startQpc -gt $windowQpc[1] }).Count
            inWindowValid = @($in | Where-Object { $_.completed -and $_.valid }).Count
            inWindowInvalid = @($in | Where-Object { $_.completed -and -not $_.valid }).Count
            inWindowIncomplete = @($in | Where-Object { -not $_.completed }).Count
            inWindowByMode = [ordered]@{ Compact = @($in | Where-Object { $_.mode -eq 'Compact' }).Count; Presence = @($in | Where-Object { $_.mode -eq 'Presence' }).Count }
            inWindowScriptChars = [long] (Get-Sum @($in | ForEach-Object { $_.scriptChars }))
        }
    }

    # Writes and connection evidence (fake server).
    $summary = Read-Json $serverSummary
    $allFrames = @(Read-Frames $frames)
    $writes = $null
    if (-not $summary) { $problems.Add('fake server summary missing') }
    else {
        $sets = @($summary.setActivity.frames)
        $inSets = if ($windowQpc -and $null -ne $windowQpc[1]) { @($sets | Where-Object { [long] $_.qpc -ge $windowQpc[0] -and [long] $_.qpc -le $windowQpc[1] }) } else { @() }
        $activityQpc = @($inSets | Where-Object { $_.kind -eq 'activity' } | ForEach-Object { [long] $_.qpc })
        $gaps = @(for ($g = 1; $g -lt $activityQpc.Count; $g++) { ($activityQpc[$g] - $activityQpc[$g - 1]) / $qpcFrequency })
        $writes = [ordered]@{
            connections = [int] $summary.connectionCount; total = [int] $summary.setActivity.total
            activity = [int] $summary.setActivity.activity; clear = [int] $summary.setActivity.clear
            acks = [int] $summary.setActivity.acks; errors = [int] $summary.setActivity.errors
            inWindowActivity = @($inSets | Where-Object { $_.kind -eq 'activity' }).Count
            inWindowClear = @($inSets | Where-Object { $_.kind -eq 'clear' }).Count
            inWindowActivityGapsSeconds = $gaps
            connectionIntervals = $summary.connections
        }
        if ($windowQpc -and $null -ne $windowQpc[1]) {
            if ($enabled) {
                if ($writes.connections -ne 1) { $problems.Add("ON expected exactly one connection, saw $($writes.connections)") }
                $c = @($summary.connections) | Select-Object -First 1
                if ($c) {
                    $readyQpc = Get-Prop (Get-Prop $c 'ready') 'qpc'
                    $discQpc = Get-Prop (Get-Prop $c 'disconnected') 'qpc'
                    if ($null -eq $readyQpc -or [long] $readyQpc -gt $windowQpc[0]) { $problems.Add('ON READY missing before the window') }
                    if ($null -ne $discQpc -and [long] $discQpc -le $windowQpc[1]) { $problems.Add('ON disconnected inside the window') }
                }
            } else {
                if ($writes.connections -ne 0) { $problems.Add("OFF expected zero connections, saw $($writes.connections)") }
                if ($writes.total -ne 0) { $problems.Add("OFF expected zero SET_ACTIVITY, saw $($writes.total)") }
            }
        }
    }
    if ($samples.Count -ne $MeasureSeconds + 1) { $problems.Add("expected $($MeasureSeconds + 1) samples, got $($samples.Count)") }
    foreach ($boundary in @(@('start', $startEvidence), @('end', $endEvidence))) {
        if ($samples.Count -gt 0 -and -not (Test-StateEvidence $boundary[1] $Cell.state)) { $problems.Add("state evidence at $($boundary[0]) does not match $($Cell.state)") }
    }
    $expectedSize = if ($Cell.state -eq 'Compact') { @(800, 180) } elseif ($Cell.state -eq 'Full') { @(1280, 800) } else { $null }
    $sizeMatches = if ($expectedSize -and $readyEvidence) { (Get-Prop $readyEvidence 'width') -eq $expectedSize[0] -and (Get-Prop $readyEvidence 'height') -eq $expectedSize[1] } else { $null }

    $wall = if ($samples.Count -ge 2) { ($samples[-1].qpc - $samples[0].qpc) / $qpcFrequency } else { 0 }
    if ($samples.Count -gt 0 -and $wall -le 0) { $problems.Add('empty measured interval') }
    $record = [ordered]@{
        name = $name; workload = $Cell.workload; state = $Cell.state; build = $Build.label; pair = $Pair; attempt = $Attempt
        condition = $Condition; discordPresence = $enabled; pipePrefix = $prefix; appPid = if ($app) { $app.Id } else { $null }
        valid = $problems.Count -eq 0; problems = @($problems)
        readinessSeconds = $readinessSeconds
        readyEvidence = $readyEvidence; startEvidence = $startEvidence; endEvidence = $endEvidence; sizeMatchesExpected = $sizeMatches
        appAliveAtEnd = $appAliveAtEnd; gracefulQuit = $graceful; wallSeconds = $wall
        cpuPercentOneCore = if ($wall -gt 0) { 100 * $samples[-1].cpuSeconds / $wall } else { $null }
        privateMB = Get-Stats @($samples | ForEach-Object { $_.privateBytes / 1e6 })
        workingSetMB = Get-Stats @($samples | ForEach-Object { $_.workingSetBytes / 1e6 })
        handles = Get-Stats @($samples | Where-Object { $null -ne $_.handles } | ForEach-Object { [double] $_.handles })
        threads = Get-Stats @($samples | Where-Object { $null -ne $_.threads } | ForEach-Object { [double] $_.threads })
        processCountMax = Get-Max @($samples | ForEach-Object { $_.processes })
        processes = @($identities.Values)
        reads = $reads; writes = $writes; frameLines = $allFrames.Count
        samples = $samples; processSamples = $processSamples
    }
    [IO.File]::WriteAllText((Join-Path $runDir 'run.json'), ($record | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
    $record
}

function Get-MetricValue($Run, [string] $Metric) {
    switch ($Metric) { 'cpu' { $Run.cpuPercentOneCore } 'privateMean' { $Run.privateMB.mean } 'workingSetMean' { $Run.workingSetMB.mean } }
}

# ---- Schedule ----
$cells = @(foreach ($w in @('Playing', 'Paused', 'Empty')) { foreach ($s in @('Full', 'Hidden', 'Compact')) {
    if ($workloads -contains $w -and $states -contains $s) { [ordered]@{ workload = $w; state = $s } } } })
$allRuns = [Collections.Generic.List[object]]::new()
$scored = [Collections.Generic.List[object]]::new()
$blocked = [Collections.Generic.List[string]]::new()
$scheduleLog = [Collections.Generic.List[string]]::new()
[IO.Directory]::CreateDirectory($runDirectory) | Out-Null
$exitCode = 0
try {
    foreach ($cell in $cells) {
        $cellKey = "$($cell.workload)/$($cell.state)"
        for ($pair = 1; $pair -le $Pairs; $pair++) {
            $conditionOrder = if ($pair % 2) { @('on', 'off') } else { @('off', 'on') }
            $buildOrder = if ($builds.Count -eq 2 -and -not ($pair % 2)) { @($builds[1], $builds[0]) } else { @($builds) }
            $pairOk = $false
            for ($attempt = 1; $attempt -le 3 -and -not $pairOk; $attempt++) {
                $pairRuns = @(foreach ($b in $buildOrder) { foreach ($c in $conditionOrder) {
                    Write-Host "$cellKey pair $pair attempt $attempt $($b.label) $c ..."
                    $scheduleLog.Add("$cellKey p$pair a$attempt $($b.label) $c")
                    $r = Invoke-Run $cell $b $pair $attempt $c
                    $allRuns.Add($r)
                    if (-not $r.valid) { Write-Host "  invalid: $($r.problems -join '; ')" }
                    $r
                } })
                $pairOk = @($pairRuns | Where-Object { -not $_.valid }).Count -eq 0
                if ($pairOk) { foreach ($r in $pairRuns) { $scored.Add($r) } }
            }
            if (-not $pairOk) { $blocked.Add($cellKey); break }
        }
    }
} catch {
    Write-Host "Benchmark aborted: $($_.Exception.Message)`n$($_.ScriptStackTrace)"
    $blocked.Add('aborted: ' + $_.Exception.Message + ' @ ' + (($_.ScriptStackTrace -split "`n") | Select-Object -First 1))
} finally {
    foreach ($key in $envKeys) { [Environment]::SetEnvironmentVariable($key, $savedEnv[$key], 'Process') }
    foreach ($process in $started) { try { if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } } catch { } }
    Stop-RootProcesses $rootBase
    if (Test-Path -LiteralPath $rootBase) { Start-Sleep -Seconds 1; Remove-Item -LiteralPath $rootBase -Recurse -Force -ErrorAction SilentlyContinue }
}

# ---- Statistics and decision ----
$cellReports = @(foreach ($cell in $cells) {
    $cellKey = "$($cell.workload)/$($cell.state)"
    $perBuild = [ordered]@{}
    foreach ($b in $builds) {
        $runs = @($scored | Where-Object { $_.workload -eq $cell.workload -and $_.state -eq $cell.state -and $_.build -eq $b.label })
        $metrics = [ordered]@{}
        foreach ($m in $metricNames) {
            $d = @(for ($p = 1; $p -le $Pairs; $p++) {
                $on = $runs | Where-Object { $_.pair -eq $p -and $_.condition -eq 'on' } | Select-Object -First 1
                $off = $runs | Where-Object { $_.pair -eq $p -and $_.condition -eq 'off' } | Select-Object -First 1
                if ($on -and $off) { (Get-MetricValue $on $m) - (Get-MetricValue $off $m) } })
            $onValues = @($runs | Where-Object { $_.condition -eq 'on' } | Sort-Object { $_.pair } | ForEach-Object { Get-MetricValue $_ $m })
            $offValues = @($runs | Where-Object { $_.condition -eq 'off' } | Sort-Object { $_.pair } | ForEach-Object { Get-MetricValue $_ $m })
            $metrics[$m] = [ordered]@{ deltas = $d; medianDelta = Get-Median $d; robustSpread = Get-RobustSpread $d
                offRange = Get-Range $offValues; onRange = Get-Range $onValues; on = $onValues; off = $offValues
                medianOn = Get-Median $onValues; medianOff = Get-Median $offValues }
        }
        $perBuild[$b.label] = [ordered]@{ pairs = [int] (@($runs).Count / 2); metrics = $metrics }
    }
    $comparison = $null
    if ($builds.Count -eq 2 -and $perBuild.R.pairs -eq $Pairs -and $perBuild.C.pairs -eq $Pairs) {
        $comparison = [ordered]@{}
        foreach ($m in $metricNames) {
            $r = $perBuild.R.metrics[$m]; $c = $perBuild.C.metrics[$m]; $x = $floors[$m]
            $noise = Get-Max @($r.offRange, $c.offRange, 2 * $r.robustSpread, 2 * $c.robustSpread)
            $improvement = $r.medianDelta - $c.medianDelta
            $paired = @(for ($i = 0; $i -lt $Pairs; $i++) { $r.deltas[$i] - $c.deltas[$i] })
            $positive = @($paired | Where-Object { $_ -gt 0 }).Count
            $rawOn = @(for ($i = 0; $i -lt $Pairs; $i++) { $c.on[$i] - $r.on[$i] })
            $rawOff = @(for ($i = 0; $i -lt $Pairs; $i++) { $c.off[$i] - $r.off[$i] })
            $onNoise = [Math]::Max($r.onRange, $c.onRange); $offNoise = [Math]::Max($r.offRange, $c.offRange)
            $threshold = [Math]::Max($noise, $x)
            $comparison[$m] = [ordered]@{
                noise = $noise; floor = $x; threshold = $threshold; improvement = $improvement
                pairedImprovements = $paired; positivePaired = $positive
                incrementalWin = $improvement -gt $threshold -and $positive -ge 3
                incrementalRegression = -$improvement -gt $threshold
                rawOnCandidateMinusBaseline = $rawOn; rawOnMedian = Get-Median $rawOn; rawOnNoise = $onNoise
                rawOffCandidateMinusBaseline = $rawOff; rawOffMedian = Get-Median $rawOff; rawOffNoise = $offNoise
                sharedWin = (-(Get-Median $rawOn)) -gt [Math]::Max($onNoise, $x) -and @($rawOn | Where-Object { $_ -lt 0 }).Count -ge 3 -and
                    (-(Get-Median $rawOff)) -gt [Math]::Max($offNoise, $x) -and @($rawOff | Where-Object { $_ -lt 0 }).Count -ge 3
                rawRegression = (Get-Median $rawOn) -gt [Math]::Max($onNoise, $x) -or (Get-Median $rawOff) -gt [Math]::Max($offNoise, $x)
            }
        }
    }
    [ordered]@{ cell = $cellKey; workload = $cell.workload; state = $cell.state; blocked = $blocked -contains $cellKey; builds = $perBuild; comparison = $comparison }
})

$valid = $blocked.Count -eq 0 -and $cells.Count -gt 0
$regressions = @(foreach ($cr in $cellReports) { if ($cr.comparison) { foreach ($m in $metricNames) {
    $cm = $cr.comparison[$m]
    if ($cm.incrementalRegression) { [ordered]@{ cell = $cr.cell; metric = $m; kind = 'incremental'; amount = -$cm.improvement; threshold = $cm.threshold } }
    if ($ClaimKind -eq 'shared-reader' -and $cm.rawRegression) { [ordered]@{ cell = $cr.cell; metric = $m; kind = 'raw'; rawOnMedian = $cm.rawOnMedian; rawOffMedian = $cm.rawOffMedian } }
} } })
$improvement = [ordered]@{ primaryMetric = $PrimaryMetric; claimKind = $ClaimKind; cells = @(foreach ($cr in $cellReports) {
    if ($cr.comparison) { $cm = $cr.comparison[$PrimaryMetric]
        [ordered]@{ cell = $cr.cell; improvement = $cm.improvement; threshold = $cm.threshold; positivePaired = $cm.positivePaired
            meets = if ($ClaimKind -eq 'shared-reader') { [bool] $cm.sharedWin } else { [bool] $cm.incrementalWin } } } }) }
$noiseOut = @(foreach ($cr in $cellReports) { [ordered]@{ cell = $cr.cell
    values = @(foreach ($b in $builds) { foreach ($m in $metricNames) {
        [ordered]@{ build = $b.label; metric = $m; offRange = $cr.builds[$b.label].metrics[$m].offRange; robustSpread = $cr.builds[$b.label].metrics[$m].robustSpread } } })
    combined = if ($cr.comparison) { [ordered]@{ cpu = $cr.comparison.cpu.noise; privateMean = $cr.comparison.privateMean.noise; workingSetMean = $cr.comparison.workingSetMean.noise } } else { $null } } })
$decision = if (-not $valid) { 'invalid' }
    elseif ($override) { 'not-scored' }
    elseif ($builds.Count -lt 2) { 'measurement-only' }
    elseif ($regressions.Count -gt 0) { 'reject' }
    elseif (@($improvement.cells).Count -gt 0 -and @($improvement.cells | Where-Object { -not $_.meets }).Count -eq 0) { 'candidate-pending-confirmation' }
    else { 'inconclusive' }

$commit = try { (& git -C $repo rev-parse HEAD 2>$null) } catch { $null }
$power = try { (& powercfg /getactivescheme 2>$null) -join ' ' } catch { $null }
$report = [ordered]@{
    protocol = [ordered]@{ version = $protocolVersion; v2Scored = -not $override; hash = $protocolHash; pairs = $Pairs
        warmupSeconds = $WarmupSeconds; measureSeconds = $MeasureSeconds; sampleIntervalSeconds = 1; states = $states; workloads = $workloads
        floors = $floors; order = 'ON/OFF A B | B A | A B | B A; builds R,C | C,R per pair' }
    command = $commandLine; runId = $runId; commit = $commit; machine = $env:COMPUTERNAME; logicalProcessors = [Environment]::ProcessorCount
    powerScheme = $power; qpcFrequency = $qpcFrequency; ubolVersion = $ubolVersion; builds = $builds
    schedule = $scheduleLog
    valid = $valid; blocked = @($blocked); noise = $noiseOut; improvement = $improvement; regressions = $regressions; decision = $decision
    cells = $cellReports
    runs = @($allRuns | ForEach-Object { $o = [ordered]@{}; foreach ($k in $_.Keys) { if ($k -ne 'processSamples') { $o[$k] = $_[$k] } }; $o['runFile'] = "runs/$($_.name)/run.json"; $o })
}
[IO.File]::WriteAllText((Join-Path $runDirectory 'bench.json'), ($report | ConvertTo-Json -Depth 14), [Text.UTF8Encoding]::new($false))

foreach ($r in $allRuns) {
    Write-Host ("{0,-44} {1} cpu {2,7:N3}%1c priv {3,8:N1} ws {4,8:N1} MB h {5} t {6} reads {7} sets {8}" -f $r.name, $(if ($r.valid) { 'ok ' } else { 'BAD' }),
        $r.cpuPercentOneCore, $r.privateMB.mean, $r.workingSetMB.mean, $r.handles.last, $r.threads.last,
        $(if ($r.reads) { $r.reads.inWindow } else { '-' }), $(if ($r.writes) { "$($r.writes.inWindowActivity)+$($r.writes.inWindowClear)c" } else { '-' }))
}
foreach ($cr in $cellReports) {
    foreach ($b in $builds) {
        $m = $cr.builds[$b.label].metrics
        Write-Host ("{0} {1}: median ON-OFF cpu {2:N3} (spread {3:N3}, OFF range {4:N3}), private {5:N2} MB, ws {6:N2} MB" -f $cr.cell, $b.label,
            $m.cpu.medianDelta, $m.cpu.robustSpread, $m.cpu.offRange, $m.privateMean.medianDelta, $m.workingSetMean.medianDelta)
    }
    if ($cr.comparison) { Write-Host ("{0} R-C improvement {1} {2:N3} (threshold {3:N3}, {4}/{5} paired positive)" -f $cr.cell, $PrimaryMetric,
        $cr.comparison[$PrimaryMetric].improvement, $cr.comparison[$PrimaryMetric].threshold, $cr.comparison[$PrimaryMetric].positivePaired, $Pairs) }
}
Write-Host "valid=$valid protocol=$protocolVersion decision=$decision blocked=[$($blocked -join ', ')]"
Write-Host "Report: $(Join-Path $runDirectory 'bench.json')"
if (-not $valid) { $exitCode = 1 }
exit $exitCode
