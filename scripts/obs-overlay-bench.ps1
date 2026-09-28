<#
G3 performance bench for the OBS now-playing overlay in real OBS (notes/research/obs-overlay-2026-09-28/plan.md §6.3 G3).
Needs the owner's explicit E2E-B approval before it is run: it launches a disposable portable OBS 32.1.2 copy
(scripts/obs-portable.ps1) on screen.

Regenerate:
  pwsh -NoProfile -File scripts/obs-overlay-bench.ps1 -OutputDirectory artifacts/obs-overlay-obs
  pwsh -NoProfile -File scripts/obs-overlay-bench.ps1 -Workload Playing -SkipPublish -TimeBoxMinutes 45

Environment: the E2E-B seeds (New-ObsPortable: one scene 'Overlay' with the browser source 'Nativune Overlay',
shutdown-when-hidden on, no outputs), Studio Mode forced off and recorded, preview and browser hardware acceleration
at OBS defaults (read from the portable config and recorded), no output active (checked). Nativune: the hook build
(artifacts/obs-overlay/app, -p:DiscordPresenceTestHooks=true), fresh root, settings v7 with ObsOverlay=true,
SleepInBackground=true, DiscordPresence=false, started Full and tray-hidden by the fixture bench state 'Hidden'
(Compact off). Launch order per block: app, its bench ready.json, 200 on http://localhost:47813/, then OBS.

Protocol per workload (Playing = the 1800 s steady profile from 0 s; Paused = paused at 60 s):
  block    fresh app + OBS launch; 4 pairs as ABBA x2 (A B | B A | A B | B A). A = source item enabled,
           B = source item disabled (shutdown on, so the page is destroyed).
  arm      30 s settle + 120 s measure. Validity from hook state (never inside the 120 s window):
           A  settle: streams >= 1, latestState = workload, fixtureArtServed above the value before this page was
              enabled, and (Playing) a fresh latestPosition within +-5 s of the monotonic time since ready.json;
              after measure: streams >= 1, latestState = workload, fixtureArtServed still above the baseline.
           B  settle: streams reach 0 and no Overlay-mode read from then to the settle end;
              after measure: streams 0 and no Overlay-mode read during measure.
           Also invalid: a process of either tree exits/appears (PID + creation time) or a sample gap > 3 s.
           An invalid arm is rerun once; a second failure makes the pair invalid and the workload gate blocked.
  age      Playing only: an arm (or rerun) starts only if elapsed-since-ready + 150 <= duration - 60 (1740 s);
           otherwise the unfinished pair is discarded and the block continues on a fresh app + OBS launch.
  samples  every 1 s: both trees' CPU time and private bytes, and the sum of \GPU Engine(*)\Utilization Percentage
           over instances whose pid_<n> is in the OBS tree (labelled engine-percent sum; unavailable -> blocked);
           OBS GetStats every 5 s (renderSkippedFrames delta, mean averageFrameRenderTime).
  scoring  paired delta = A - B per pair. pass: max delta <= budget; fail: min delta > budget; otherwise one extra
           fresh block for that workload, then still between -> inconclusive, reported as fail (no merge).
  time box OBS on-screen seconds (launch to stop) are totalled; an arm starts only if it fits in -TimeBoxMinutes
           (default 90: the 2 h G3 box less the 30 min of B-LOOK/B-VIS/B-DOCS). Unfinished checks stay blocked.

Artifacts: <OutputDirectory>/<utc>/bench-report.json (same check format as the E2E reports) and perf.csv (one row per
tree per 1 s sample). No screenshots, no page probes, no websocket password (it stays in the portable copy's config).
#>
[CmdletBinding()]
param(
    [ValidateSet('Playing', 'Paused')] [string[]] $Workload = @('Playing', 'Paused'),
    [string] $OutputDirectory = 'artifacts/obs-overlay-obs',
    [double] $TimeBoxMinutes = 90,
    [double] $ObsCpuBudgetPp = 1.0,
    [double] $ObsPrivateBudgetMiB = 60,
    [double] $ObsGpuBudgetEnginePp = 1.0,
    [double] $ObsRenderBudgetMs = 0.5,
    [double] $ObsSkippedFramesBudget = 0,
    [double] $AppCpuBudgetPp = 0.1,
    [double] $AppPrivateBudgetMiB = 5,
    [switch] $SkipPublish,
    [switch] $KeepRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'obs-portable.ps1')
$commandLine = 'pwsh -NoProfile -File scripts/obs-overlay-bench.ps1 ' + (($PSBoundParameters.GetEnumerator() | ForEach-Object {
    if ($_.Value -is [switch]) { if ($_.Value) { "-$($_.Key)" } } else { "-$($_.Key) $(@($_.Value) -join ',')" } }) -join ' ')
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
$appDirectory = Join-Path $repo 'artifacts/obs-overlay/app'
$appExe = Join-Path $appDirectory 'Nativune.exe'
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$runDirectory = Join-Path $outputRoot $runId
$rootBase = Join-Path $repo ".cache/obs-overlay-bench/$runId"
[IO.Directory]::CreateDirectory($runDirectory) | Out-Null
[IO.Directory]::CreateDirectory($rootBase) | Out-Null

$ubolVersion = [regex]::Match((Get-Content -Raw (Join-Path $repo 'src/Nativune/BrowserPrivacy.cs')),
    'ExtensionVersion\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $ubolVersion) { throw 'Could not read BrowserPrivacy.ExtensionVersion.' }
$ubolSource = Join-Path $repo ".tools/ubol/$ubolVersion"
if (-not (Test-Path -LiteralPath (Join-Path $ubolSource 'manifest.json') -PathType Leaf)) {
    throw "uBO Lite $ubolVersion is missing at $ubolSource (manifest.json)."
}

$port = 47813
$overlayUrl = "http://localhost:$port/"
$sceneName = 'Overlay'
$sourceName = 'Nativune Overlay'
$trackSeconds = 1800.0
$ageMarginSeconds = 60.0
$settleSeconds = 30.0
$measureSeconds = 120.0
$armSeconds = $settleSeconds + $measureSeconds
$positionTolerance = 5.0
$maxGapSeconds = 3.0
$statsEverySeconds = 5.0
$pairsPerBlock = 4
$pairOrders = @(@('A', 'B'), @('B', 'A'), @('A', 'B'), @('B', 'A'))
$maxLaunchesPerBlock = 3
$timeBoxSeconds = $TimeBoxMinutes * 60.0
$freq = [double] [Diagnostics.Stopwatch]::Frequency
$prefix = 'nativune-test-' + [guid]::NewGuid().ToString('N') + '-discord-ipc-'
$testEnv = [ordered]@{
    NATIVUNE_TEST_DISCORD_PIPE_PREFIX = $prefix
    NATIVUNE_TEST_DISCORD_CLIENT_ID = '100000000000000001'
    NATIVUNE_TEST_DISCORD_FIXTURE_PAGE = '1'
}
$benchEnvKeys = @('NATIVUNE_TEST_DISCORD_BENCH_PROFILE', 'NATIVUNE_TEST_DISCORD_BENCH_STATE', 'NATIVUNE_TEST_DISCORD_MIN_WRITE_SECONDS',
    'NATIVUNE_TEST_DISCORD_PAUSE_SECONDS')
$isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$budgets = [ordered]@{
    'obs.cpuPp' = $ObsCpuBudgetPp; 'obs.privateMiB' = $ObsPrivateBudgetMiB; 'obs.gpuEnginePp' = $ObsGpuBudgetEnginePp
    'obs.renderMs' = $ObsRenderBudgetMs; 'obs.skippedFrames' = $ObsSkippedFramesBudget
    'app.cpuPp' = $AppCpuBudgetPp; 'app.privateMiB' = $AppPrivateBudgetMiB
}

$checks = [Collections.Generic.List[object]]::new()
$launches = [Collections.Generic.List[object]]::new()
$arms = [Collections.Generic.List[object]]::new()
$workloadResults = [ordered]@{}
$csv = [Collections.Generic.List[string]]::new()
$csv.Add('workload,block,launch,pair,condition,attempt,sample,tSeconds,tree,processes,cpuSeconds,privateMiB,gpuEnginePct')
$script:launchCount = 0
$script:labelSeq = 0
$script:obsUsedSeconds = 0.0
$script:obsLaunchQpc = $null
$script:timeBoxHit = $false
$script:gpuUnavailable = $null

# ---------------------------------------------------------------------------------------------------------------
# Shared helpers (as in scripts/obs-overlay-e2e.ps1)

function Add-Check([string] $Name, $Expected, $Observed, [bool] $Passed) {
    $checks.Add([ordered]@{ name = $Name; expected = "$Expected"; observed = $Observed; status = if ($Passed) { 'pass' } else { 'fail' } })
}
function Add-Blocked([string] $Name, $Expected, [string] $Reason) {
    $checks.Add([ordered]@{ name = $Name; expected = "$Expected"; observed = $Reason; status = 'blocked' })
}
function Get-Prop($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}
function Get-Qpc { [double] [Diagnostics.Stopwatch]::GetTimestamp() }
function Get-Seconds($From, $To) { ([double] $To - [double] $From) / $freq }
function Wait-UntilQpc([double] $Qpc) {
    while ($true) {
        $left = ($Qpc - (Get-Qpc)) / $freq
        if ($left -le 0) { return }
        Start-Sleep -Milliseconds ([int] [Math]::Max(10, [Math]::Min(250, $left * 1000)))
    }
}
function Wait-For([scriptblock] $Probe, [double] $Seconds, [int] $PollMs = 250) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $value = & $Probe
        if ($value) { return $value }
        Start-Sleep -Milliseconds $PollMs
    }
    & $Probe
}
function ConvertTo-SafeName([string] $Name) { ($Name -replace '[^A-Za-z0-9-]', '-') }
function Round3($Value) { if ($null -eq $Value) { $null } else { [Math]::Round([double] $Value, 3) } }
function Get-Mean($Values) { $v = @(@($Values) | Where-Object { $null -ne $_ }); if ($v.Count -eq 0) { $null } else { ($v | Measure-Object -Average).Average } }

function New-Root([string] $Name) {
    $root = Join-Path $rootBase $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $ubolDestination = Join-Path $root '.tools/ubol'
    [IO.Directory]::CreateDirectory($ubolDestination) | Out-Null
    Copy-Item -LiteralPath $ubolSource -Destination $ubolDestination -Recurse
    [IO.Directory]::CreateDirectory((Join-Path $root 'data/discord-bench')) | Out-Null
    $root
}
# G3 app environment: overlay on, SleepInBackground on, Discord off; Compact off (StartCompact false, state Hidden).
function Write-Settings([string] $Root) {
    $data = Join-Path $Root 'data'
    [IO.Directory]::CreateDirectory($data) | Out-Null
    $settings = [ordered]@{
        Version = 7; X = 100; Y = 100; Width = 1280; Height = 800; Dpi = 96; Maximized = $false; Zoom = 1.0
        TrayEnabled = $true; RestoreSection = $false; LastSection = 'home'; ReduceMotion = $false
        CompactX = 100; CompactY = 100; CompactWidth = 800; CompactHeight = 180; CompactDpi = 96
        SleepInBackground = $true; StartCompact = $false; AutoCheckUpdates = $false
        OutputVolume = 1.0; BlockAds = $false
        DiscordPresence = $false; DiscordStatusLine = 0; DiscordOpenButton = $true
        ObsOverlay = $true; ObsHidePaused = $true
    }
    [IO.File]::WriteAllText((Join-Path $data 'settings.json'), ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}

$launchHelper = Join-Path $rootBase 'launch-helper.ps1'
[IO.File]::WriteAllText($launchHelper, @'
param([string] $SpecPath)
$ErrorActionPreference = 'Stop'
$spec = Get-Content -Raw -LiteralPath $SpecPath | ConvertFrom-Json
foreach ($name in @($spec.unset)) { if ($name) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') } }
foreach ($p in $spec.env.PSObject.Properties) { [Environment]::SetEnvironmentVariable($p.Name, [string] $p.Value, 'Process') }
$proc = Start-Process -FilePath $spec.exe -ArgumentList @($spec.arguments) -WorkingDirectory $spec.workingDirectory -PassThru
[IO.File]::WriteAllText($spec.pidFile, (@{ processId = $proc.Id } | ConvertTo-Json -Compress))
'@, [Text.UTF8Encoding]::new($false))

# Basic-user token launch (runas /trustlevel:0x20000 -> helper), as in the E2E harness.
function Invoke-RunasLaunch([string] $Exe, [string[]] $Arguments, [string] $WorkingDirectory, $Environment) {
    $spec = Join-Path $rootBase "launch-$($script:launchCount).json"
    $pidFile = Join-Path $rootBase "launch-$($script:launchCount).pid.json"
    $set = [ordered]@{}; $unset = @()
    foreach ($entry in $Environment.GetEnumerator()) { if ($null -eq $entry.Value) { $unset += $entry.Key } else { $set[$entry.Key] = $entry.Value } }
    $specJson = [ordered]@{ exe = $Exe; arguments = $Arguments; workingDirectory = $WorkingDirectory; env = $set; unset = $unset; pidFile = $pidFile }
    [IO.File]::WriteAllText($spec, ($specJson | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    & runas.exe '/trustlevel:0x20000' "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$launchHelper`" `"$spec`"" | Out-Null
    if (-not (Wait-For { Test-Path -LiteralPath $pidFile } 30)) { throw "runas /trustlevel launch helper wrote no PID file ($pidFile)." }
    Get-Process -Id ([int] (Get-Content -Raw -LiteralPath $pidFile | ConvertFrom-Json).processId)
}
function Start-App([string] $Root, [string] $BenchProfile) {
    $environment = [ordered]@{}
    foreach ($entry in $testEnv.GetEnumerator()) { $environment[$entry.Key] = $entry.Value }
    foreach ($key in $benchEnvKeys) { $environment[$key] = $null }
    $environment['NATIVUNE_TEST_DISCORD_BENCH_PROFILE'] = $BenchProfile
    $environment['NATIVUNE_TEST_DISCORD_BENCH_STATE'] = 'Hidden'
    $arguments = @('web', '--root', $Root)
    $script:launchCount++
    if ($isElevated) { $process = Invoke-RunasLaunch $appExe $arguments $appDirectory $environment }
    else {
        foreach ($entry in $environment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
        $process = Start-Process -FilePath $appExe -ArgumentList $arguments -WorkingDirectory $appDirectory -PassThru
    }
    $process
}
function Get-BenchDirectory([string] $Root) { Join-Path $Root 'data/discord-bench' }
function Send-HookCommand([string] $Root, [string] $Name) {
    $directory = Get-BenchDirectory $Root
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $directory $Name), 'go')
}
function Wait-BenchReady([string] $Root, [double] $Seconds = 90) {
    $directory = Get-BenchDirectory $Root
    [void] (Wait-For { (Test-Path -LiteralPath (Join-Path $directory 'ready.json')) -or (Test-Path -LiteralPath (Join-Path $directory 'failed.json')) } $Seconds)
    $path = Join-Path $directory 'ready.json'
    if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } else { $null }
}
# diagnostics-<label>.json + state-<label>.json; { state, diag, overlay, qpc } or $null after 10 s.
function Get-State([string] $Root, [string] $Tag = 's') {
    $script:labelSeq++
    $label = ('s{0}-{1}' -f $script:labelSeq, ((ConvertTo-SafeName $Tag).ToLowerInvariant())).TrimEnd('-')
    if ($label.Length -gt 32) { $label = $label.Substring(0, 32).TrimEnd('-') }
    $directory = Get-BenchDirectory $Root
    $statePath = Join-Path $directory "state-$label.json"
    $diagPath = Join-Path $directory "diagnostics-$label.json"
    Send-HookCommand $Root "command-snapshot-$label"
    if (-not (Wait-For { (Test-Path -LiteralPath $statePath) -and (Test-Path -LiteralPath $diagPath) } 10 100)) { return $null }
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 16
    $diag = Get-Content -Raw -LiteralPath $diagPath | ConvertFrom-Json -Depth 16
    [pscustomobject]@{ label = $label; state = $state; diag = $diag; overlay = (Get-Prop $state 'overlay'); qpc = [double] (Get-Prop $diag 'boundaryQpc') }
}
function Get-Overlay($Snapshot, [string] $Field) { Get-Prop (Get-Prop $Snapshot 'overlay') $Field }
# Overlay-mode reads that started in (Start, End] of the diagnostics' boundary QPCs.
function Get-OverlayReads($Start, $End) {
    if (-not $Start -or -not $End) { return $null }
    $s0 = [double] $Start.qpc; $s1 = [double] $End.qpc; $n = 0
    foreach ($read in @(Get-Prop $End.diag 'reads')) {
        if (-not $read) { continue }
        $q = [double] $read.startQpc
        if ($q -gt $s0 -and $q -le $s1 -and [string] (Get-Prop $read 'mode') -eq 'Overlay') { $n++ }
    }
    $n
}
function Stop-App($Process, [string] $Root) {
    if (-not $Process) { return }
    if (-not $Process.HasExited) {
        try { Send-HookCommand $Root 'command-quit' } catch { }
        if (-not $Process.WaitForExit(8000)) {
            foreach ($t in (Get-AppTree $Process.Id $Root)) { Stop-Process -Id $t.pid -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine)) {
        if ($p.CommandLine -and $p.CommandLine.Contains($Root, [StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}
function Test-PrefixFree {
    $l = [Net.HttpListener]::new(); $l.Prefixes.Add($overlayUrl)
    try { $l.Start(); $true } catch { $false } finally { try { $l.Close() } catch { } }
}

# ---------------------------------------------------------------------------------------------------------------
# Process trees (tree sampler of scripts/discord-rpc-bench.ps1): identity = PID + creation time.

function ConvertTo-TreeEntries($All, $Ids) {
    @($All | Where-Object { $Ids.Contains([int] $_.ProcessId) } | ForEach-Object {
        $created = if ($_.CreationDate) { ([datetime] $_.CreationDate).ToUniversalTime().ToString('o') } else { '' }
        [pscustomobject]@{ pid = [int] $_.ProcessId; name = $_.Name; created = $created; key = "$($_.ProcessId)@$created" }
    })
}
function Get-Descendants($All, [int] $RootId) {
    $ids = [Collections.Generic.HashSet[int]]::new(); [void] $ids.Add($RootId)
    do {
        $added = $false
        foreach ($p in $All) { if ($ids.Contains([int] $p.ParentProcessId) -and $ids.Add([int] $p.ProcessId)) { $added = $true } }
    } while ($added)
    $ids
}
function Get-AllProcesses { @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine, CreationDate) }
# Nativune + its WebView2 descendants (WebView2 browser processes are not children; matched by the root in argv).
function Get-AppTree([int] $RootId, [string] $Root, $All = $null) {
    if (-not $All) { $All = Get-AllProcesses }
    $ids = Get-Descendants $All $RootId
    foreach ($p in $All) {
        if ($p.Name -eq 'msedgewebview2.exe' -and $p.CommandLine -and $p.CommandLine.Contains($Root, [StringComparison]::OrdinalIgnoreCase)) {
            foreach ($id in (Get-Descendants $All ([int] $p.ProcessId))) { [void] $ids.Add($id) }
        }
    }
    ConvertTo-TreeEntries $All $ids
}
# obs64 + all descendants (obs-browser-page included).
function Get-ObsTree([int] $RootId, $All = $null) {
    if (-not $All) { $All = Get-AllProcesses }
    ConvertTo-TreeEntries $All (Get-Descendants $All $RootId)
}
function Measure-Tree($Entries) {
    $cpu = 0.0; $priv = 0.0; $missing = 0
    foreach ($t in $Entries) {
        $p = Get-Process -Id $t.pid -ErrorAction SilentlyContinue
        if (-not $p) { $missing++; continue }
        try { $cpu += $p.TotalProcessorTime.TotalSeconds; $priv += [double] $p.PrivateMemorySize64 } catch { $missing++ }
    }
    [pscustomobject]@{ cpu = $cpu; privateMiB = $priv / 1048576.0; missing = $missing }
}

# GPU engine-percent sum over \GPU Engine(*)\Utilization Percentage instances named pid_<n>_... with n in the OBS tree.
$script:gpuCounters = @{}
function Update-GpuCounters($PidSet) {
    try {
        $category = [Diagnostics.PerformanceCounterCategory]::new('GPU Engine')
        $names = $category.GetInstanceNames()
    } catch { $script:gpuUnavailable = "GPU Engine category unavailable: $($_.Exception.Message)"; return $false }
    foreach ($name in $names) {
        $m = [regex]::Match($name, '^pid_(\d+)_')
        if (-not $m.Success -or -not $PidSet.Contains([int] $m.Groups[1].Value) -or $script:gpuCounters.ContainsKey($name)) { continue }
        try {
            $c = [Diagnostics.PerformanceCounter]::new('GPU Engine', 'Utilization Percentage', $name, $true)
            [void] $c.NextValue(); $script:gpuCounters[$name] = $c
        } catch { }
    }
    $true
}
function Read-GpuSum($PidSet) {
    $sum = 0.0
    foreach ($name in @($script:gpuCounters.Keys)) {
        $m = [regex]::Match($name, '^pid_(\d+)_')
        if (-not $PidSet.Contains([int] $m.Groups[1].Value)) { continue }
        try { $sum += [double] $script:gpuCounters[$name].NextValue() } catch { $script:gpuCounters[$name].Dispose(); $script:gpuCounters.Remove($name) }
    }
    $sum
}
function Clear-GpuCounters { foreach ($c in @($script:gpuCounters.Values)) { try { $c.Dispose() } catch { } }; $script:gpuCounters = @{} }

# ---------------------------------------------------------------------------------------------------------------
# Launch (app first, then OBS) and environment

function Get-ObsOnScreenSeconds {
    $s = $script:obsUsedSeconds
    if ($null -ne $script:obsLaunchQpc) { $s += Get-Seconds $script:obsLaunchQpc (Get-Qpc) }
    $s
}
function Test-TimeFits([double] $Seconds) { ((Get-ObsOnScreenSeconds) + $Seconds) -le $timeBoxSeconds }

function Read-IniValue([string] $Directory, [string] $Section, [string] $Key) {
    if (-not (Test-Path -LiteralPath $Directory)) { return $null }
    foreach ($file in @(Get-ChildItem -LiteralPath $Directory -Filter '*.ini' -File -ErrorAction SilentlyContinue)) {
        $current = $null
        foreach ($line in [IO.File]::ReadAllLines($file.FullName)) {
            if ($line -match '^\s*\[(.+)\]\s*$') { $current = $Matches[1]; continue }
            if ($current -eq $Section -and $line -match "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$") { return [ordered]@{ file = $file.Name; value = $Matches[1].Trim() } }
        }
    }
    $null
}

function Start-Launch([string] $WorkloadName, [int] $Block) {
    $script:launchIndex = $launches.Count + 1
    $name = "$WorkloadName-b$Block-l$($script:launchIndex)"
    $record = [ordered]@{ launch = $script:launchIndex; workload = $WorkloadName; block = $Block; name = $name }
    $launches.Add($record)
    if (-not (Test-PrefixFree)) { throw "http://localhost:$port/ is held by another process before $name." }
    $root = New-Root $name
    Write-Settings $root
    $app = Start-App $root $WorkloadName
    $ctx = [pscustomobject]@{ Name = $name; Workload = $WorkloadName; Block = $Block; Launch = $script:launchIndex; Root = $root
        App = $app; AppStart = $app.StartTime; Obs = $null; ObsProcess = $null; ObsStart = $null; Session = $null; ItemId = $null
        ReadyQpc = $null; ItemEnabled = $true; PageArtBaseline = 0; Record = $record }
    $script:currentCtx = $ctx
    $ready = Wait-BenchReady $root
    if (-not $ready) { throw "$name`: no fixture ready.json (failed.json or timeout)." }
    $ctx.ReadyQpc = [double] (Get-Prop $ready 'qpc')
    $hidden = Wait-For { $s = Get-State $root 'hidden'; if ((Get-Prop $s.state 'appWindowVisible') -eq $false) { $s } } 20 500
    $record['appTrayHidden'] = [bool] $hidden
    if (-not $hidden) { throw "$name`: app did not reach tray-hidden." }
    $record['appCompact'] = Get-Prop $hidden.state 'compact'
    $record['appOverlayRunning'] = Get-Overlay $hidden 'running'
    # The listener must answer before OBS starts (OBS's browser does not retry a failed first load, D13).
    $ok = Wait-For { try { (Invoke-WebRequest -Uri $overlayUrl -UseBasicParsing -TimeoutSec 5).StatusCode -eq 200 } catch { $false } } 20 500
    $record['listener200'] = [bool] $ok
    if (-not $ok) { throw "$name`: $overlayUrl did not answer 200 before OBS launch." }
    # Every arm before the first A has its baseline from before OBS existed.
    $ctx.PageArtBaseline = [int] (Get-Overlay $hidden 'fixtureArtServed')

    $ctx.Obs = New-ObsPortable -RunDir (Join-Path $rootBase "$name-obs")
    $script:obsLaunchQpc = Get-Qpc
    $ctx.ObsProcess = Start-ObsPortable $ctx.Obs
    $ctx.ObsStart = $ctx.ObsProcess.StartTime
    $ctx.Session = Connect-ObsWebSocket $ctx.Obs
    $version = Invoke-ObsRequest $ctx.Session 'GetVersion' @{}
    $record['obsVersion'] = Get-Prop $version 'obsVersion'
    # Environment: Studio Mode off, no outputs, preview + browser HW acceleration at defaults (recorded).
    $studio = Get-Prop (Invoke-ObsRequest $ctx.Session 'GetStudioModeEnabled' @{}) 'studioModeEnabled'
    if ($studio) { [void] (Invoke-ObsRequest $ctx.Session 'SetStudioModeEnabled' @{ studioModeEnabled = $false }) }
    $record['studioModeInitially'] = $studio
    $record['studioModeEnabled'] = Get-Prop (Invoke-ObsRequest $ctx.Session 'GetStudioModeEnabled' @{}) 'studioModeEnabled'
    $outputs = [ordered]@{}
    foreach ($req in @('GetStreamStatus', 'GetRecordStatus', 'GetVirtualCamStatus', 'GetReplayBufferStatus')) {
        try { $outputs[$req] = [bool] (Get-Prop (Invoke-ObsRequest $ctx.Session $req @{}) 'outputActive') } catch { $outputs[$req] = "unavailable: $($_.Exception.Message)" }
    }
    $record['outputsActive'] = $outputs
    $configDir = Join-Path $ctx.Obs.RunDir 'config/obs-studio'
    $record['previewEnabled'] = Read-IniValue $configDir 'BasicWindow' 'PreviewEnabled'
    $record['browserHWAccel'] = Read-IniValue $configDir 'General' 'BrowserHWAccel'
    $record['previewEnabledNote'] = 'absent key = OBS default (preview shown)'
    $record['browserHWAccelNote'] = 'absent key = OBS default (enabled)'
    $settings = Get-Prop (Invoke-ObsRequest $ctx.Session 'GetInputSettings' @{ inputName = $sourceName }) 'inputSettings'
    $record['source'] = [ordered]@{ url = Get-Prop $settings 'url'; width = Get-Prop $settings 'width'; height = Get-Prop $settings 'height'
        shutdown = Get-Prop $settings 'shutdown'; fps = Get-Prop $settings 'fps'; fps_custom = Get-Prop $settings 'fps_custom' }
    $ctx.ItemId = [int] (Get-Prop (Invoke-ObsRequest $ctx.Session 'GetSceneItemId' @{ sceneName = $sceneName; sourceName = $sourceName }) 'sceneItemId')
    $ctx.ItemEnabled = [bool] (Get-Prop (Invoke-ObsRequest $ctx.Session 'GetSceneItemEnabled' @{ sceneName = $sceneName; sceneItemId = $ctx.ItemId }) 'sceneItemEnabled')
    $envOk = ($record['studioModeEnabled'] -eq $false) -and -not (@($outputs.Values) -contains $true) -and
        (Get-Prop $settings 'shutdown') -eq $true -and "$($record['obsVersion'])" -eq '32.1.2'
    $record['environmentOk'] = $envOk
    if (-not $envOk) { throw "$name`: OBS environment differs from the G3 seeds (see launches[$($script:launchIndex - 1)])." }
    $ctx
}
function Stop-Launch($Ctx) {
    if (-not $Ctx) { return }
    Clear-GpuCounters
    if ($Ctx.Obs) {
        try { Stop-ObsPortable $Ctx.Obs } catch { $Ctx.Record['obsStopError'] = $_.Exception.Message }
    }
    if ($null -ne $script:obsLaunchQpc) {
        $script:obsUsedSeconds += Get-Seconds $script:obsLaunchQpc (Get-Qpc); $script:obsLaunchQpc = $null
    }
    try { Stop-App $Ctx.App $Ctx.Root } catch { }
    $log = Join-Path $Ctx.Root 'data/nativune.log'
    if (Test-Path -LiteralPath $log) { Copy-Item -LiteralPath $log -Destination (Join-Path $runDirectory "nativune-$($Ctx.Name).log") }
    [void] (Wait-For { Test-PrefixFree } 10 250)
    $script:currentCtx = $null
}
function Set-SourceEnabled($Ctx, [bool] $Enabled) {
    [void] (Invoke-ObsRequest $Ctx.Session 'SetSceneItemEnabled' @{ sceneName = $sceneName; sceneItemId = $Ctx.ItemId; sceneItemEnabled = $Enabled })
    $Ctx.ItemEnabled = $Enabled
}
function Get-ObsStats($Ctx) {
    $s = Invoke-ObsRequest $Ctx.Session 'GetStats' @{}
    [pscustomobject]@{ skipped = [double] (Get-Prop $s 'renderSkippedFrames'); renderMs = [double] (Get-Prop $s 'averageFrameRenderTime') }
}
function Test-RootsAlive($Ctx) {
    $a = Get-Process -Id $Ctx.App.Id -ErrorAction SilentlyContinue
    $o = Get-Process -Id $Ctx.ObsProcess.Id -ErrorAction SilentlyContinue
    $a -and $o -and $a.StartTime -eq $Ctx.AppStart -and $o.StartTime -eq $Ctx.ObsStart
}

# ---------------------------------------------------------------------------------------------------------------
# One arm: 30 s settle (validity from hook state) + 120 s measure (samples only) + post-measure validity.

function Invoke-Arm($Ctx, [int] $Pair, [string] $Condition, [int] $Attempt) {
    $arm = [ordered]@{ workload = $Ctx.Workload; block = $Ctx.Block; launch = $Ctx.Launch; pair = $Pair; condition = $Condition
        attempt = $Attempt; valid = $true; reasons = [Collections.Generic.List[string]]::new() }
    $arms.Add($arm)
    $invalid = { param($r) $arm.valid = $false; $arm.reasons.Add($r) }
    $wantState = $Ctx.Workload.ToLowerInvariant()
    $settleStart = Get-Qpc
    $settleEnd = $settleStart + $settleSeconds * $freq
    $arm['elapsedSinceReadyAtStart'] = Round3 (Get-Seconds $Ctx.ReadyQpc $settleStart)

    if ($Condition -eq 'A') {
        if (-not $Ctx.ItemEnabled) {
            $pre = Get-State $Ctx.Root 'artbase'
            $Ctx.PageArtBaseline = [int] (Get-Overlay $pre 'fixtureArtServed')
            Set-SourceEnabled $Ctx $true
        }
        $arm['artBaseline'] = $Ctx.PageArtBaseline
        # Settle-start validity: the page's stream, workload state, fixture art, and (Playing) a fresh position.
        $open = Wait-For { $s = Get-State $Ctx.Root 'aopen'; if ((Get-Overlay $s 'streams') -ge 1) { $s } } ($settleSeconds - 8) 500
        $fresh = if ($open) { Start-Sleep -Milliseconds 1500; Get-State $Ctx.Root 'afresh' } else { $null }
        $okSettle = $fresh -and (Get-Overlay $fresh 'streams') -ge 1 -and (Get-Overlay $fresh 'latestState') -eq $wantState -and
            [int] (Get-Overlay $fresh 'fixtureArtServed') -gt $Ctx.PageArtBaseline
        if (-not $okSettle) {
            $art = Wait-For { $s = Get-State $Ctx.Root 'aart'; if ([int] (Get-Overlay $s 'fixtureArtServed') -gt $Ctx.PageArtBaseline -and (Get-Overlay $s 'latestState') -eq $wantState -and (Get-Overlay $s 'streams') -ge 1) { $s } } ([Math]::Max(1, (Get-Seconds (Get-Qpc) $settleEnd) - 2)) 500
            if ($art) { $fresh = $art; $okSettle = $true }
        }
        $arm['settle'] = [ordered]@{ streams = Get-Overlay $fresh 'streams'; latestState = Get-Overlay $fresh 'latestState'
            latestStale = Get-Overlay $fresh 'latestStale'; fixtureArtServed = Get-Overlay $fresh 'fixtureArtServed'; latestPosition = Get-Overlay $fresh 'latestPosition' }
        if (-not $okSettle) { & $invalid 'A settle: streams>=1, latestState, fixtureArtServed for this page not all met' }
        if ($Ctx.Workload -eq 'Playing' -and $fresh) {
            $elapsed = Get-Seconds $Ctx.ReadyQpc $fresh.qpc
            $position = Get-Overlay $fresh 'latestPosition'
            $arm['settle']['elapsedAtRead'] = Round3 $elapsed
            if ($null -eq $position -or [Math]::Abs([double] $position - $elapsed) -gt $positionTolerance) {
                & $invalid "A settle: latestPosition $position vs elapsed $(Round3 $elapsed) beyond +-$positionTolerance s"
            }
        }
    } else {
        if ($Ctx.ItemEnabled) { Set-SourceEnabled $Ctx $false }
        $zero = Wait-For { $s = Get-State $Ctx.Root 'bzero'; if ((Get-Overlay $s 'streams') -eq 0) { $s } } ($settleSeconds - 8) 500
        $arm['settle'] = [ordered]@{ streamsZero = [bool] $zero; secondsToZero = if ($zero) { Round3 (Get-Seconds $settleStart $zero.qpc) } }
        $script:bZero = $zero
        if (-not $zero) { & $invalid 'B settle: streams did not reach 0' }
    }
    Wait-UntilQpc $settleEnd
    $sPre = Get-State $Ctx.Root "$($Condition.ToLowerInvariant())pre"
    if ($Condition -eq 'B') {
        $reads = if ($script:bZero -and $sPre) { Get-OverlayReads $script:bZero $sPre } else { $null }
        $arm['settle']['overlayReads'] = $reads
        if ($null -eq $reads -or $reads -ne 0 -or (Get-Overlay $sPre 'streams') -ne 0) { & $invalid "B settle: overlay reads $reads / streams $(Get-Overlay $sPre 'streams')" }
    }

    # Measure: no hook probes, no page probes, no screenshots.
    $appTree0 = Get-AppTree $Ctx.App.Id $Ctx.Root
    $obsTree0 = Get-ObsTree $Ctx.ObsProcess.Id
    $appKeys = ($appTree0.key | Sort-Object) -join '|'; $obsKeys = ($obsTree0.key | Sort-Object) -join '|'
    $obsPids = [Collections.Generic.HashSet[int]]::new(); foreach ($t in $obsTree0) { [void] $obsPids.Add($t.pid) }
    $gpuOk = Update-GpuCounters $obsPids
    $samples = [Collections.Generic.List[object]]::new()
    $stats = [Collections.Generic.List[object]]::new()
    $mStart = Get-Qpc
    $mEnd = $mStart + $measureSeconds * $freq
    $nextStats = $mStart
    $i = 0; $lastQpc = $null; $maxGap = 0.0; $treeChanged = $null
    while ($true) {
        $now = Get-Qpc
        if ($now -ge $nextStats) {
            try { $stats.Add([ordered]@{ t = Round3 (Get-Seconds $mStart $now); v = (Get-ObsStats $Ctx) }) } catch { & $invalid "GetStats failed: $($_.Exception.Message)" }
            $nextStats += $statsEverySeconds * $freq
        }
        $all = Get-AllProcesses
        $appTree = Get-AppTree $Ctx.App.Id $Ctx.Root $all
        $obsTree = Get-ObsTree $Ctx.ObsProcess.Id $all
        $q = Get-Qpc
        $a = Measure-Tree $appTree0; $o = Measure-Tree $obsTree0
        $gpu = if ($gpuOk) { Read-GpuSum $obsPids } else { $null }
        if ($null -ne $lastQpc) { $maxGap = [Math]::Max($maxGap, (Get-Seconds $lastQpc $q)) }
        $lastQpc = $q
        if (-not $treeChanged -and ((($appTree.key | Sort-Object) -join '|') -ne $appKeys -or (($obsTree.key | Sort-Object) -join '|') -ne $obsKeys -or $a.missing -gt 0 -or $o.missing -gt 0)) {
            $treeChanged = Round3 (Get-Seconds $mStart $q)
        }
        $t = Round3 (Get-Seconds $mStart $q)
        $samples.Add([pscustomobject]@{ i = $i; t = $t; appCpu = $a.cpu; appPriv = $a.privateMiB; obsCpu = $o.cpu; obsPriv = $o.privateMiB; gpu = $gpu })
        $prefixCsv = "$($Ctx.Workload),$($Ctx.Block),$($Ctx.Launch),$Pair,$Condition,$Attempt,$i,$t"
        $csv.Add("$prefixCsv,app,$(@($appTree0).Count),$(Round3 $a.cpu),$(Round3 $a.privateMiB),")
        $csv.Add("$prefixCsv,obs,$(@($obsTree0).Count),$(Round3 $o.cpu),$(Round3 $o.privateMiB),$(Round3 $gpu)")
        $i++
        if ($q -ge $mEnd) { break }
        Wait-UntilQpc ([Math]::Min($mEnd, $mStart + $i * $freq))
    }
    try { $stats.Add([ordered]@{ t = Round3 (Get-Seconds $mStart (Get-Qpc)); v = (Get-ObsStats $Ctx) }) } catch { & $invalid "GetStats failed: $($_.Exception.Message)" }
    $wall = Get-Seconds $mStart $lastQpc

    $arm['measure'] = [ordered]@{ seconds = Round3 $wall; samples = $samples.Count; maxGapSeconds = Round3 $maxGap
        appProcesses = @($appTree0).Count; obsProcesses = @($obsTree0).Count; treeChangedAt = $treeChanged; gpuCounters = $script:gpuCounters.Count }
    if ($maxGap -gt $maxGapSeconds) { & $invalid "sample gap $(Round3 $maxGap) s > $maxGapSeconds s" }
    if ($null -ne $treeChanged) { & $invalid "process tree changed (restart/exit/new process) at $treeChanged s" }
    if (-not (Test-RootsAlive $Ctx)) { & $invalid 'Nativune or obs64 root process restarted or exited' }

    # Post-measure validity.
    $sPost = Get-State $Ctx.Root "$($Condition.ToLowerInvariant())post"
    if ($Condition -eq 'A') {
        $arm['post'] = [ordered]@{ streams = Get-Overlay $sPost 'streams'; latestState = Get-Overlay $sPost 'latestState'; fixtureArtServed = Get-Overlay $sPost 'fixtureArtServed' }
        if (-not ($sPost -and (Get-Overlay $sPost 'streams') -ge 1 -and (Get-Overlay $sPost 'latestState') -eq $wantState -and
            [int] (Get-Overlay $sPost 'fixtureArtServed') -gt $Ctx.PageArtBaseline)) { & $invalid 'A after measure: streams>=1, latestState, fixtureArtServed not all met' }
    } else {
        $reads = if ($sPre -and $sPost) { Get-OverlayReads $sPre $sPost } else { $null }
        $arm['post'] = [ordered]@{ streams = Get-Overlay $sPost 'streams'; overlayReadsDuringMeasure = $reads }
        if (-not ($sPost -and (Get-Overlay $sPost 'streams') -eq 0 -and $reads -eq 0)) { & $invalid 'B after measure: streams 0 and no overlay reads not both met' }
    }

    if ($samples.Count -ge 2) {
        $f = $samples[0]; $l = $samples[$samples.Count - 1]; $span = $l.t - $f.t
        $renders = @($stats | ForEach-Object { $_.v.renderMs })
        $arm['metrics'] = [ordered]@{
            'obs.cpuPp' = Round3 (($l.obsCpu - $f.obsCpu) / $span * 100)
            'obs.privateMiB' = Round3 (Get-Mean ($samples | ForEach-Object { $_.obsPriv }))
            'obs.gpuEnginePp' = if ($gpuOk) { Round3 (Get-Mean ($samples | Select-Object -Skip 1 | ForEach-Object { $_.gpu })) } else { $null }
            'obs.renderMs' = Round3 (Get-Mean $renders)
            'obs.skippedFrames' = if ($stats.Count -ge 2) { $stats[$stats.Count - 1].v.skipped - $stats[0].v.skipped } else { $null }
            'app.cpuPp' = Round3 (($l.appCpu - $f.appCpu) / $span * 100)
            'app.privateMiB' = Round3 (Get-Mean ($samples | ForEach-Object { $_.appPriv }))
        }
    } else { & $invalid 'fewer than 2 samples' }
    $arm['reasons'] = @($arm.reasons)
    $arm
}

# ---------------------------------------------------------------------------------------------------------------
# Blocks, pairs, reruns, fixture-age bound, time box

function Test-AgeFits($Ctx) {
    if ($Ctx.Workload -ne 'Playing') { return $true }
    ((Get-Seconds $Ctx.ReadyQpc (Get-Qpc)) + $armSeconds) -le ($trackSeconds - $ageMarginSeconds)
}
# Returns { pairs = valid pair records; blocked = reason or $null }.
function Invoke-Block([string] $WorkloadName, [int] $Block) {
    $pairs = [Collections.Generic.List[object]]::new()
    $ctx = $null; $launchesUsed = 0
    try {
        for ($p = 1; $p -le $pairsPerBlock; $p++) {
            $order = $pairOrders[$p - 1]
            $pairArms = @{}
            $restart = $false
            foreach ($cond in $order) {
                $result = $null
                for ($attempt = 1; $attempt -le 2; $attempt++) {
                    if (-not (Test-TimeFits ($armSeconds + $(if ($ctx) { 0 } else { 120 })))) { $script:timeBoxHit = $true; return @{ pairs = $pairs; blocked = 'time box reached' } }
                    if (-not $ctx) {
                        if ($launchesUsed -ge $maxLaunchesPerBlock) { return @{ pairs = $pairs; blocked = "block needed more than $maxLaunchesPerBlock fresh launches" } }
                        $ctx = Start-Launch $WorkloadName $Block; $launchesUsed++
                    }
                    if (-not (Test-AgeFits $ctx)) { $restart = $true; break }
                    $result = Invoke-Arm $ctx $p $cond $attempt
                    if ($result.valid) { break }
                }
                if ($restart) { break }
                if (-not $result.valid) { return @{ pairs = $pairs; blocked = "pair $p arm $cond invalid twice: $($result.reasons -join '; ')" } }
                $pairArms[$cond] = $result
            }
            if ($restart) {
                # Fixture-age bound: discard the unfinished pair, fresh app + OBS launch, redo it.
                foreach ($a in $pairArms.Values) { $a['discarded'] = 'fixture-age restart' }
                Stop-Launch $ctx; $ctx = $null; $p--; continue
            }
            $delta = [ordered]@{}
            foreach ($m in $budgets.Keys) {
                $va = $pairArms['A'].metrics[$m]; $vb = $pairArms['B'].metrics[$m]
                $delta[$m] = if ($null -ne $va -and $null -ne $vb) { Round3 ([double] $va - [double] $vb) } else { $null }
            }
            $pairs.Add([ordered]@{ block = $Block; pair = $p; order = ($order -join ''); launch = $ctx.Launch; delta = $delta })
        }
        @{ pairs = $pairs; blocked = $null }
    } finally { Stop-Launch $ctx }
}
function Get-Verdict($Deltas, [double] $Budget) {
    $v = @($Deltas | Where-Object { $null -ne $_ } | ForEach-Object { [double] $_ })
    if ($v.Count -eq 0) { return @{ verdict = 'blocked'; max = $null; min = $null } }
    $max = ($v | Measure-Object -Maximum).Maximum; $min = ($v | Measure-Object -Minimum).Minimum
    $verdict = if ($max -le $Budget) { 'pass' } elseif ($min -gt $Budget) { 'fail' } else { 'between' }
    @{ verdict = $verdict; max = Round3 $max; min = Round3 $min; n = $v.Count }
}

function Invoke-Workload([string] $WorkloadName) {
    $all = [Collections.Generic.List[object]]::new()
    $result = [ordered]@{ blocks = 0; blocked = $null; pairs = $all; metrics = [ordered]@{} }
    $workloadResults[$WorkloadName] = $result
    $verdicts = $null
    for ($block = 1; $block -le 2; $block++) {
        $b = Invoke-Block $WorkloadName $block
        $result.blocks = $block
        foreach ($x in $b.pairs) { $all.Add($x) }
        if ($b.blocked) { $result.blocked = "block $block`: $($b.blocked)"; break }
        $verdicts = [ordered]@{}
        foreach ($m in $budgets.Keys) { $verdicts[$m] = Get-Verdict @($all | ForEach-Object { $_.delta[$m] }) $budgets[$m] }
        $between = @($verdicts.Keys | Where-Object { $verdicts[$_].verdict -eq 'between' })
        if ($between.Count -eq 0) { break }
        # Otherwise one more fresh 4-pair block for this workload.
    }
    foreach ($m in $budgets.Keys) {
        $name = "G3.$WorkloadName.$m"
        $expected = "paired delta A-B <= $($budgets[$m]) (pass: max <= budget; fail: min > budget; else +1 block, then inconclusive = fail)"
        if ($result.blocked) { Add-Blocked $name $expected $result.blocked; continue }
        if ($m -eq 'obs.gpuEnginePp' -and $script:gpuUnavailable) { Add-Blocked $name $expected $script:gpuUnavailable; continue }
        $v = $verdicts[$m]; $result.metrics[$m] = $v
        switch ($v.verdict) {
            'pass' { Add-Check $name $expected $v $true }
            'fail' { Add-Check $name $expected $v $false }
            'between' { $v['inconclusive'] = $true; Add-Check $name $expected $v $false }
            default { Add-Blocked $name $expected 'no paired values' }
        }
    }
}

# ---------------------------------------------------------------------------------------------------------------

$ownerBefore = $null
$script:currentCtx = $null
try {
    if (-not $SkipPublish) {
        & pwsh -NoProfile -File (Join-Path $repo 'scripts/dotnet.ps1') publish (Join-Path $repo 'src/Nativune/Nativune.csproj') `
            --runtime win-x64 --self-contained false -p:DiscordPresenceTestHooks=true -o $appDirectory
        if ($LASTEXITCODE -ne 0) { throw "Hook build publish failed with exit code $LASTEXITCODE." }
    }
    if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) { throw "Hook build not found at $appExe; run without -SkipPublish." }
    $appVersion = (Get-Item -LiteralPath $appExe).VersionInfo.ProductVersion
    $ownerBefore = Get-OwnerObsProfileSnapshot
    foreach ($w in $Workload) {
        if ($script:timeBoxHit) {
            foreach ($m in $budgets.Keys) { Add-Blocked "G3.$w.$m" "paired delta A-B <= $($budgets[$m])" 'time box reached before this workload' }
            continue
        }
        try { Invoke-Workload $w } catch {
            Add-Check "G3.$w.runner.completed" 'workload ran to completion' $_.Exception.Message $false
            $workloadResults["$w.error"] = [ordered]@{ message = $_.Exception.Message; scriptStackTrace = $_.ScriptStackTrace }
            try { Stop-Launch $script:currentCtx } catch { }
            foreach ($m in $budgets.Keys) { if (-not ($checks | Where-Object { $_.name -eq "G3.$w.$m" })) { Add-Blocked "G3.$w.$m" "paired delta A-B <= $($budgets[$m])" 'workload aborted' } }
        }
    }
} catch {
    Add-Check 'G3.runner.completed' 'harness setup succeeded' $_.Exception.Message $false
} finally {
    try { Stop-Launch $script:currentCtx } catch { }
    Clear-GpuCounters
    foreach ($key in @($testEnv.Keys) + $benchEnvKeys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine)) {
        if ($p.CommandLine -and $p.CommandLine.Contains($rootBase, [StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    if ($ownerBefore) {
        $ownerAfter = Get-OwnerObsProfileSnapshot
        $diff = @(@($ownerBefore.Keys) + @($ownerAfter.Keys) | Sort-Object -Unique | Where-Object {
            -not $ownerBefore.ContainsKey($_) -or -not $ownerAfter.ContainsKey($_) -or
            (($ownerBefore[$_] | ConvertTo-Json -Compress) -ne ($ownerAfter[$_] | ConvertTo-Json -Compress)) })
        Add-Check 'G3.ownerObsProfileUnchanged' 'owner %APPDATA%/%LOCALAPPDATA% obs-studio identical before/after' ([ordered]@{ changed = $diff.Count; paths = @($diff | Select-Object -First 20) }) ($diff.Count -eq 0)
    }
    if (-not $KeepRoot -and (Test-Path -LiteralPath $rootBase)) {
        Start-Sleep -Seconds 1
        Remove-Item -LiteralPath $rootBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($script:timeBoxHit) { Add-Blocked 'G3.timeBox' "all blocks within $TimeBoxMinutes min of OBS on screen" "stopped at $(Round3 ($script:obsUsedSeconds / 60)) min; owner approval needed for more time" }
$failed = @($checks | Where-Object { $_.status -eq 'fail' })
$blocked = @($checks | Where-Object { $_.status -eq 'blocked' })
$passed = $checks.Count -gt 0 -and $failed.Count -eq 0 -and $blocked.Count -eq 0
$report = [ordered]@{
    command = $commandLine; runId = $runId; appVersion = $(if (Get-Variable appVersion -ErrorAction SilentlyContinue) { $appVersion }); pipePrefix = $prefix
    harnessElevated = $isElevated; budgets = $budgets; timeBoxMinutes = $TimeBoxMinutes; obsOnScreenMinutes = Round3 ($script:obsUsedSeconds / 60)
    protocol = [ordered]@{ settleSeconds = $settleSeconds; measureSeconds = $measureSeconds; sampleSeconds = 1; statsEverySeconds = $statsEverySeconds
        trackSeconds = $trackSeconds; ageLimitSeconds = $trackSeconds - $ageMarginSeconds; positionToleranceSeconds = $positionTolerance
        maxGapSeconds = $maxGapSeconds; pairOrders = @($pairOrders | ForEach-Object { $_ -join '' }); gpuMetric = 'engine-percent sum (not Task Manager %)' }
    launches = @($launches); arms = @($arms); workloads = $workloadResults
    summary = [ordered]@{ pass = @($checks | Where-Object { $_.status -eq 'pass' }).Count; fail = $failed.Count; blocked = $blocked.Count }
    checks = @($checks); passed = [bool] $passed
}
[IO.File]::WriteAllText((Join-Path $runDirectory 'bench-report.json'), ($report | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllLines((Join-Path $runDirectory 'perf.csv'), $csv, [Text.UTF8Encoding]::new($false))
$report.summary | ConvertTo-Json
Write-Host "Report: $(Join-Path $runDirectory 'bench-report.json')"
if (-not $passed) { exit 1 }
