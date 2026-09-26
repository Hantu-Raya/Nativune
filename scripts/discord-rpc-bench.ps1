<#
Paired on/off resource benchmark for opt-in Discord Rich Presence. Measurement, not pass/fail: exits 0
after a completed run and records withinReviewMargin for review.

  pwsh -NoProfile -File scripts/discord-rpc-bench.ps1 -Pairs 3 -OutputDirectory artifacts/discord-rpc/bench

FROZEN PROTOCOL (fixed before any data; change it only with a new, documented protocol):
- Build: the Discord E2E hook build (-p:DiscordPresenceTestHooks=true) published to artifacts/discord-rpc/app
  (skipped with -SkipPublish). Never shipped.
- Conditions: ON = settings v7 DiscordPresence=true; OFF = DiscordPresence=false. Both runs start the same fake
  server (scripts/discord-rpc-test-server.ps1) on <prefix>0 with a fresh random prefix
  nativune-test-<32 hex>-discord-ipc-, so the ONLY difference is the setting. No real discord-ipc pipe, Discord
  client, YouTube or Google request is involved; data/ is never touched.
- Environment: NATIVUNE_TEST_DISCORD_PIPE_PREFIX, _CLIENT_ID and _FIXTURE_PAGE=1 set;
  NATIVUNE_TEST_DISCORD_MIN_WRITE_SECONDS and _PAUSE_SECONDS UNSET (production 15 s min write interval and
  production pause behaviour).
- Each run: fresh root under .cache/discord-rpc-bench/<run-id>/<run> with a real copy of the repository uBO Lite
  tree and the E2E settings (full view window 1280x800, StartCompact=false, SleepInBackground=false,
  AutoCheckUpdates=false, BlockAds=false). App launched as `Nativune.exe web --root <root>` in the full (not
  Compact) window.
- Order: ABBA across pairs to cancel drift: pair 1 ON,OFF; pair 2 OFF,ON; pair 3 ON,OFF; ...
- Timing: WarmupSeconds (default 15) after process start, then one sample per second for MeasureSeconds (default
  40). Fixture page time (src/Nativune/DiscordFixturePage.html) lags process start by the page load (a few
  seconds), so the window covers roughly page time 15-55 s: all within track A and before track B (80 s) and the
  ended event (120 s). It includes the seek at 25 s and the start of the pause at 45 s (pause lasts to 60 s), so
  ON sees at most a few SET_ACTIVITY writes (seek, pause) gated by the 15 s minimum write interval.
- Tree (complete, per agents.md): the Nativune.exe pid plus every msedgewebview2.exe whose CommandLine contains
  the run root, discovered each sample via Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'".
- Per sample: sum of TotalProcessorTime, PrivateMemorySize64 and WorkingSet64 over the tree. CPU is accumulated
  per pid (first sample is the baseline; pids appearing later count from zero; exited pids keep their last
  value) so process churn cannot produce negative deltas.
- Per run: cpuPercentOneCore = 100 * deltaCpu / wall over the window; mean/max private MB and mean working set
  MB (decimal MB = 1e6 bytes); max process count; SET_ACTIVITY frames seen by the server (whole run and inside
  the window).
- Per pair: ON - OFF for CPU, mean private and mean working set; medians across pairs.
- Review margin: noise = spread (max - min) of the OFF runs. withinReviewMargin =
  medianCpuDelta <= max(offCpuSpread, 0.5 percent-of-one-core) AND
  medianPrivateDelta <= max(offPrivateSpread, 5% of OFF mean private MB).
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 50)] [int] $Pairs = 3,
    [ValidateRange(0, 600)] [int] $WarmupSeconds = 15,
    [ValidateRange(2, 600)] [int] $MeasureSeconds = 40,
    [switch] $SkipPublish,
    [string] $OutputDirectory = 'artifacts/discord-rpc/bench'
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$commandLine = 'pwsh -NoProfile -File scripts/discord-rpc-bench.ps1 ' + (($PSBoundParameters.GetEnumerator() | ForEach-Object {
    if ($_.Value -is [switch]) { if ($_.Value) { "-$($_.Key)" } } else { "-$($_.Key) $($_.Value)" } }) -join ' ')
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
$appDirectory = Join-Path $repo 'artifacts/discord-rpc/app'
$appExe = Join-Path $appDirectory 'Nativune.exe'
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N')
$runDirectory = Join-Path $outputRoot $runId
$rootBase = Join-Path $repo ".cache/discord-rpc-bench/$runId"
$ubolVersion = [regex]::Match((Get-Content -Raw (Join-Path $repo 'src/Nativune/BrowserPrivacy.cs')),
    'ExtensionVersion\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $ubolVersion) { throw 'Could not read BrowserPrivacy.ExtensionVersion.' }
$ubolSource = Join-Path $repo ".tools/ubol/$ubolVersion"
if (-not (Test-Path -LiteralPath (Join-Path $ubolSource 'manifest.json') -PathType Leaf)) {
    throw "uBO Lite $ubolVersion is missing at $ubolSource (manifest.json)."
}
$clientId = '100000000000000001'
$envKeys = @('NATIVUNE_TEST_DISCORD_PIPE_PREFIX', 'NATIVUNE_TEST_DISCORD_CLIENT_ID', 'NATIVUNE_TEST_DISCORD_FIXTURE_PAGE',
    'NATIVUNE_TEST_DISCORD_MIN_WRITE_SECONDS', 'NATIVUNE_TEST_DISCORD_PAUSE_SECONDS')
$started = [Collections.Generic.List[Diagnostics.Process]]::new()
$runs = [Collections.Generic.List[object]]::new()

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

function New-Root([string] $Name) {
    $root = Join-Path $rootBase $Name
    $ubolDestination = Join-Path $root '.tools/ubol'
    [IO.Directory]::CreateDirectory($ubolDestination) | Out-Null
    Copy-Item -LiteralPath $ubolSource -Destination $ubolDestination -Recurse
    $root
}

function Get-TreeIds([int] $AppId, [string] $Root) {
    $ids = [Collections.Generic.HashSet[int]]::new(); [void] $ids.Add($AppId)
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine)) {
        if ($p.CommandLine -and $p.CommandLine.Contains($Root, [StringComparison]::OrdinalIgnoreCase)) { [void] $ids.Add([int] $p.ProcessId) }
    }
    @($ids)
}

function Stop-Tree([Diagnostics.Process] $App, [string] $Root) {
    if ($App -and -not $App.HasExited) {
        [void] $App.CloseMainWindow()
        if (-not $App.WaitForExit(8000)) { Stop-Process -Id $App.Id -Force -ErrorAction SilentlyContinue }
    }
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine)) {
        if ($p.CommandLine -and $p.CommandLine.Contains($Root, [StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}

function Get-SetActivityTimes([string] $FramesPath) {
    if (-not (Test-Path -LiteralPath $FramesPath)) { return @() }
    @(Get-Content -LiteralPath $FramesPath | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 32 } |
        Where-Object { $_.direction -eq 'in' -and $_.opcode -eq 1 -and $_.json -like '*SET_ACTIVITY*' } |
        ForEach-Object { $u = $_.utc; if ($u -isnot [datetime]) { $u = [DateTime]::Parse($u, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }; $u.ToUniversalTime() })
}

function Invoke-Run([int] $Pair, [string] $Condition) {
    $name = "p$Pair-$Condition"
    $enabled = $Condition -eq 'on'
    $root = New-Root $name
    Write-Settings $root $enabled
    $prefix = 'nativune-test-' + [guid]::NewGuid().ToString('N') + '-discord-ipc-'
    $frames = Join-Path $runDirectory "frames-$name.jsonl"
    $stop = Join-Path $runDirectory "stop-$name"
    $server = Start-Process -FilePath pwsh -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-File',
        (Join-Path $repo 'scripts/discord-rpc-test-server.ps1'), '-PipeName', ($prefix + '0'), '-FramesPath', $frames, '-StopFile', $stop, '-Mode', 'Normal')
    $started.Add($server)
    Start-Sleep -Seconds 2
    $app = $null
    $samples = [Collections.Generic.List[object]]::new()
    try {
        foreach ($key in $envKeys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
        [Environment]::SetEnvironmentVariable('NATIVUNE_TEST_DISCORD_PIPE_PREFIX', $prefix, 'Process')
        [Environment]::SetEnvironmentVariable('NATIVUNE_TEST_DISCORD_CLIENT_ID', $clientId, 'Process')
        [Environment]::SetEnvironmentVariable('NATIVUNE_TEST_DISCORD_FIXTURE_PAGE', '1', 'Process')
        $app = Start-Process -FilePath $appExe -ArgumentList @('web', '--root', $root) -WorkingDirectory $appDirectory -PassThru
        $started.Add($app)
        Start-Sleep -Seconds $WarmupSeconds
        if ($app.HasExited) { throw "App exited during warmup ($name)." }

        $cpuByPid = @{}; $baseByPid = @{}
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $windowStartUtc = [DateTime]::UtcNow
        for ($i = 0; $i -le $MeasureSeconds; $i++) {
            $target = [TimeSpan]::FromSeconds($i)
            $wait = $target - $clock.Elapsed
            if ($wait -gt [TimeSpan]::Zero) { Start-Sleep -Milliseconds ([int] $wait.TotalMilliseconds) }
            $elapsed = $clock.Elapsed.TotalSeconds
            $private = 0L; $workingSet = 0L; $count = 0
            foreach ($id in (Get-TreeIds $app.Id $root)) {
                $p = Get-Process -Id $id -ErrorAction SilentlyContinue
                if (-not $p) { continue }
                try {
                    $cpu = $p.TotalProcessorTime.TotalSeconds
                    $private += $p.PrivateMemorySize64; $workingSet += $p.WorkingSet64; $count++
                } catch { continue }
                if (-not $baseByPid.ContainsKey($id)) { $baseByPid[$id] = if ($i -eq 0) { $cpu } else { 0.0 } }
                $cpuByPid[$id] = $cpu
            }
            $cpuTotal = 0.0
            foreach ($id in $cpuByPid.Keys) { $cpuTotal += $cpuByPid[$id] - $baseByPid[$id] }
            $samples.Add([ordered]@{ t = [Math]::Round($elapsed, 3); cpuSeconds = $cpuTotal; privateBytes = $private; workingSetBytes = $workingSet; processes = $count })
        }
        $windowEndUtc = [DateTime]::UtcNow
        $wall = $samples[-1].t - $samples[0].t
        $alive = -not $app.HasExited
    } finally {
        Stop-Tree $app $root
        foreach ($key in $envKeys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
        [IO.File]::WriteAllText($stop, 'stop')
        if (-not $server.WaitForExit(5000)) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    }
    $log = Join-Path $root 'data/nativune.log'
    if (Test-Path -LiteralPath $log) { Copy-Item -LiteralPath $log -Destination (Join-Path $runDirectory "nativune-$name.log") }
    $sets = @(Get-SetActivityTimes $frames)
    $privateMb = @($samples | ForEach-Object { $_.privateBytes / 1e6 })
    $wsMb = @($samples | ForEach-Object { $_.workingSetBytes / 1e6 })
    [ordered]@{
        pair = $Pair; condition = $Condition; discordPresence = $enabled; appPid = $app.Id; pipePrefix = $prefix
        appAliveAtEnd = $alive; wallSeconds = [Math]::Round($wall, 3)
        cpuPercentOneCore = [Math]::Round(100 * $samples[-1].cpuSeconds / $wall, 3)
        meanPrivateMB = [Math]::Round(($privateMb | Measure-Object -Average).Average, 2)
        maxPrivateMB = [Math]::Round(($privateMb | Measure-Object -Maximum).Maximum, 2)
        meanWorkingSetMB = [Math]::Round(($wsMb | Measure-Object -Average).Average, 2)
        processCount = ($samples | ForEach-Object { $_.processes } | Measure-Object -Maximum).Maximum
        setActivityFrames = $sets.Count
        setActivityFramesInWindow = @($sets | Where-Object { $_ -ge $windowStartUtc -and $_ -le $windowEndUtc }).Count
        samples = $samples
    }
}

function Get-Median([double[]] $Values) {
    $sorted = @($Values | Sort-Object); $n = $sorted.Count
    if ($n -eq 0) { return $null }
    if ($n % 2) { $sorted[[int][Math]::Floor($n / 2)] } else { ($sorted[$n / 2 - 1] + $sorted[$n / 2]) / 2 }
}

[IO.Directory]::CreateDirectory($runDirectory) | Out-Null
try {
    if (-not $SkipPublish) {
        & pwsh -NoProfile -File (Join-Path $repo 'scripts/dotnet.ps1') publish (Join-Path $repo 'src/Nativune/Nativune.csproj') `
            -c Release -p:DiscordPresenceTestHooks=true -o $appDirectory
        if ($LASTEXITCODE -ne 0) { throw "Hook build publish failed with exit code $LASTEXITCODE." }
    }
    if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) { throw "Hook build not found at $appExe; run without -SkipPublish." }
    $appVersion = (Get-Item -LiteralPath $appExe).VersionInfo.ProductVersion

    for ($pair = 1; $pair -le $Pairs; $pair++) {
        # ABBA: odd pairs ON then OFF, even pairs OFF then ON.
        $order = if ($pair % 2) { @('on', 'off') } else { @('off', 'on') }
        foreach ($condition in $order) {
            Write-Host "Pair $pair $condition ..."
            $runs.Add((Invoke-Run $pair $condition))
        }
    }
} finally {
    foreach ($key in $envKeys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
    foreach ($process in $started) { try { if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } } catch { } }
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine)) {
        if ($p.CommandLine -and $p.CommandLine.Contains($rootBase, [StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    if (Test-Path -LiteralPath $rootBase) {
        Start-Sleep -Seconds 1
        Remove-Item -LiteralPath $rootBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$pairsOut = @(for ($pair = 1; $pair -le $Pairs; $pair++) {
    $on = $runs | Where-Object { $_.pair -eq $pair -and $_.condition -eq 'on' }
    $off = $runs | Where-Object { $_.pair -eq $pair -and $_.condition -eq 'off' }
    [ordered]@{
        pair = $pair; order = if ($pair % 2) { 'on,off' } else { 'off,on' }
        cpuDeltaPercentOneCore = [Math]::Round($on.cpuPercentOneCore - $off.cpuPercentOneCore, 3)
        privateDeltaMB = [Math]::Round($on.meanPrivateMB - $off.meanPrivateMB, 2)
        workingSetDeltaMB = [Math]::Round($on.meanWorkingSetMB - $off.meanWorkingSetMB, 2)
    }
})
$offRuns = @($runs | Where-Object { $_.condition -eq 'off' })
$offCpu = @($offRuns | ForEach-Object { $_.cpuPercentOneCore })
$offPrivate = @($offRuns | ForEach-Object { $_.meanPrivateMB })
$offCpuSpread = ($offCpu | Measure-Object -Maximum).Maximum - ($offCpu | Measure-Object -Minimum).Minimum
$offPrivateSpread = ($offPrivate | Measure-Object -Maximum).Maximum - ($offPrivate | Measure-Object -Minimum).Minimum
$offPrivateMean = ($offPrivate | Measure-Object -Average).Average
$medianCpu = Get-Median ($pairsOut | ForEach-Object { $_.cpuDeltaPercentOneCore })
$medianPrivate = Get-Median ($pairsOut | ForEach-Object { $_.privateDeltaMB })
$medianWs = Get-Median ($pairsOut | ForEach-Object { $_.workingSetDeltaMB })
$cpuMargin = [Math]::Max($offCpuSpread, 0.5)
$privateMargin = [Math]::Max($offPrivateSpread, 0.05 * $offPrivateMean)
$medians = [ordered]@{
    cpuDeltaPercentOneCore = [Math]::Round($medianCpu, 3); privateDeltaMB = [Math]::Round($medianPrivate, 2)
    workingSetDeltaMB = [Math]::Round($medianWs, 2)
    offCpuSpread = [Math]::Round($offCpuSpread, 3); offPrivateSpreadMB = [Math]::Round($offPrivateSpread, 2)
    offMeanPrivateMB = [Math]::Round($offPrivateMean, 2)
    cpuMargin = [Math]::Round($cpuMargin, 3); privateMarginMB = [Math]::Round($privateMargin, 2)
    withinReviewMargin = [bool] ($medianCpu -le $cpuMargin -and $medianPrivate -le $privateMargin)
}
$protocol = [ordered]@{
    build = 'hook build -p:DiscordPresenceTestHooks=true'; pairs = $Pairs; order = 'ABBA (odd pairs on,off; even pairs off,on)'
    warmupSeconds = $WarmupSeconds; measureSeconds = $MeasureSeconds; sampleIntervalSeconds = 1
    approxPageTimeWindow = "$WarmupSeconds-$($WarmupSeconds + $MeasureSeconds) s after process start (~15-55 s page time at defaults; track A, seek 25 s, pause 45-60 s)"
    env = 'PIPE_PREFIX, CLIENT_ID, FIXTURE_PAGE=1; MIN_WRITE_SECONDS and PAUSE_SECONDS unset'
    fakeServer = 'running in both conditions'; window = 'full view, StartCompact=false'
    tree = "Nativune pid + msedgewebview2.exe with CommandLine containing the run root"
    appVersion = $appVersion; machine = $env:COMPUTERNAME; logicalProcessors = [Environment]::ProcessorCount
}
$report = [ordered]@{ command = $commandLine; protocol = $protocol; runs = $runs; pairs = $pairsOut; medians = $medians }
[IO.File]::WriteAllText((Join-Path $runDirectory 'bench.json'), ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))

foreach ($r in $runs) {
    Write-Host ("p{0} {1,-3} cpu {2,7:N3}%1c  private mean {3,8:N1} max {4,8:N1} MB  ws {5,8:N1} MB  procs {6}  SET_ACTIVITY {7} ({8} in window)" -f
        $r.pair, $r.condition, $r.cpuPercentOneCore, $r.meanPrivateMB, $r.maxPrivateMB, $r.meanWorkingSetMB, $r.processCount, $r.setActivityFrames, $r.setActivityFramesInWindow)
}
Write-Host ("Median ON-OFF: cpu {0:N3} %1c (margin {1:N3}), private {2:N2} MB (margin {3:N2}), ws {4:N2} MB; withinReviewMargin={5}" -f
    $medianCpu, $cpuMargin, $medianPrivate, $privateMargin, $medianWs, $medians.withinReviewMargin)
Write-Host "Report: $(Join-Path $runDirectory 'bench.json')"
exit 0
