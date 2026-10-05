<#
Overlay designer/OBS benchmark. Exhaustive-v1 preserves the full protocol;
Fast-v1 is deadline-bound diagnostic evidence, not release qualification.
-DryRun prints/self-checks schedules without creating roots, building, opening
listeners or starting app/OBS/Chrome. Its synthetic schema fixture is not evidence.

Playing: -Protocol SharedBaseline -Looks All -Workload Playing -TimeBoxMinutes 150
Paused: -Workload Paused -Look pill -TimeBoxMinutes 30
Worst: -Workload Playing -WorstFrom <frames-worst.json> -TimeBoxMinutes 30
Designer: -Designer -WorstFrom <frames-worst.json> -TimeBoxMinutes 180 (no OBS)
OBS also requires -FramesFrom <frames-worst.json> and -StillsReport <B-LOOK report.json>.

Shared: B0, four seeded/reversed/rotated rounds of A B A quartets, B_end (50 arms).
Every arm: 30 s settle + 120 s measurement; once-only 180 s warm-up visits all looks.
Standard: four AB/BA pairs, same windows/warm-up, one configuration per command.
Designer: four AB/BA pairs and 60 s first-open warm-up in each of eight conditions.
Complete trees are sampled at 1 s; any root/descendant exit or ProcessFailed,
>3 s gap, wrong workload/count, missing GPU counter or renewal invalidates.
Retry each invalid arm once, then blocked. Teardown/switching is outside windows.
Shared retains adjacent immediate pairs, brackets and conservative observed extremes;
mixed/drift/cold-cost/retention needs a separately approved fresh standard command
(-FallbackFrom <bench-report.json> -Look <theme>, box 30).
Fresh mixed is inconclusive: no merge. Paused extensions need separate approved blocks.
Artifacts: bench-report.json, perf.csv, fixture-ready epoch, seed/order, shapes, triggers.
#>
[CmdletBinding()]
param(
    [Alias('Workloads')] [ValidateSet('Playing', 'Paused')] [string[]] $Workload = @('Playing'),
    [ValidateSet('Fast-v1','Exhaustive-v1')] [string] $Profile = 'Exhaustive-v1',
    [ValidateSet(2, 4)] [int] $Pairs = 4,
    [switch] $Designer,
    [switch] $DryRun,
    [switch] $AttributionOnly,
    [ValidateSet('Standard', 'SharedBaseline')] [string] $Protocol = 'Standard',
    [string[]] $Looks = @('All'),
    [ValidateSet('pill','matte','matte-light','standard','classic','simple','album-art','card')] [string] $Look = 'pill',
    [int] $Width = 0,
    [int] $Scale = 100,
    [string] $WorstFrom,
    [string] $FramesFrom,
    [string] $StillsReport,
    [string] $FallbackFrom,
    [int] $Seed = 47813,
    [switch] $AppOnly,
    [ValidateSet(60,180)] [double] $WarmupSeconds = 180,
    [ValidateRange(60, 60)] [double] $WarmupASeconds = 60,
    [ValidateSet('none', 'noop')] [string] $ReadProbe = 'none',
    [string] $OutputDirectory = 'artifacts/obs-overlay-obs',
    [double] $TimeBoxMinutes = 0,
    [double] $ObsCpuBudgetPp = 1.0,
    [double] $ObsPrivateBudgetMiB = 60,
    [double] $ObsGpuBudgetEnginePp = 1.0,
    [double] $ObsRenderBudgetMs = 0.5,
    [double] $ObsSkippedFramesBudget = 0,
    [double] $AppCpuBudgetPp = 0.5,
    [double] $AppPrivateBudgetMiB = 8,
    [switch] $SkipPublish,
    [switch] $KeepRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$invocationQpc = [double][Diagnostics.Stopwatch]::GetTimestamp()
$invocationUtc = [DateTime]::UtcNow
$script:designerCleaning = $false
$script:designerCalibration = $null
$script:designerRoleBaseline = $null
$script:designerProfileRows = [ordered]@{}
$script:designerRunStart = $invocationQpc
$script:designerDeadlineQpc = $invocationQpc + 3600.0 * [Diagnostics.Stopwatch]::Frequency
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'obs-portable.ps1')
. (Join-Path $PSScriptRoot 'obs-overlay-bench-protocol.ps1')
if ($Workload.Count -ne 1) { throw 'One approved block per command: select one workload.' }
if ($Profile -eq 'Fast-v1' -and $PSBoundParameters.ContainsKey('Pairs') -and $Pairs -ne 2) { throw 'Fast-v1 requires two pairs.' }
if ($Profile -eq 'Exhaustive-v1' -and $Pairs -ne 4) { throw 'Exhaustive-v1 requires four pairs.' }
if ($Profile -eq 'Fast-v1') { $Pairs = 2 }
if ($Designer -and $Profile -eq 'Fast-v1' -and $TimeBoxMinutes -and $TimeBoxMinutes -ne 60) { throw 'Designer Fast-v1 has a hard 60-minute invocation deadline.' }
if ($PSBoundParameters.ContainsKey('WarmupSeconds') -and $WarmupSeconds -ne $(if ($Designer) {60} else {180})) {throw 'Full protocol warm-up is 60 seconds for Designer, 180 otherwise.'}
if ($FallbackFrom) {
    if ($Profile -ne 'Exhaustive-v1') {throw 'Fresh fallback qualification requires Exhaustive-v1.'}
    if ($Protocol -ne 'Standard' -or $Designer -or $WorstFrom) {throw 'FallbackFrom requires a standard single-look block.'}
    $previous=Get-Content -Raw -LiteralPath $FallbackFrom | ConvertFrom-Json -AsHashtable -Depth 32
    $fallback=$previous.workloads.Playing[$Look]
    if (-not $fallback -or $fallback.status -ne 'fresh-block-required') {throw 'FallbackFrom does not request this look.'}
}
if ($Designer -and ($AppOnly -or $Protocol -ne 'Standard')) { throw '-Designer cannot be combined with AppOnly or SharedBaseline.' }
if ($AttributionOnly -and ($Designer -or $AppOnly -or $Protocol -ne 'Standard' -or $WorstFrom -or $FallbackFrom -or $Workload[0] -ne 'Playing')) {
    throw '-AttributionOnly requires Standard Playing OBS; no Designer/AppOnly/Worst/fallback.'
}
if ($Protocol -eq 'SharedBaseline' -and ($Workload[0] -ne 'Playing' -or ($Looks -join ',') -ne 'All' -or $WorstFrom -or $Width -or $Scale -ne 100)) {
    throw 'SharedBaseline requires -Workload Playing -Looks All at defaults.'
}
$allThemes = @('pill','matte','matte-light','standard','classic','simple','album-art','card')
$worstData = if ($WorstFrom) { Read-ObsFramesWorst $WorstFrom -Designer:$Designer -Profile $Profile } else { $null }
$framesEvidence=$worstData
$admission=Get-ObsBenchAdmission $framesEvidence
$selectedOptions = if ($worstData) { $worstData.worst.options } else { New-ObsBenchOptions $Look $Width $Scale }
$selectedThemes = if ($Protocol -eq 'SharedBaseline') { $allThemes } else { @($selectedOptions.theme) }
$schedule = @(New-ObsBenchSchedule $Protocol $selectedThemes $Seed -Profile $Profile)
if (-not $TimeBoxMinutes) {
    $TimeBoxMinutes = if ($Profile -eq 'Fast-v1') {
        if ($Designer) {60} elseif ($Protocol -eq 'SharedBaseline') {75} else {15}
    } else { if ($Designer) {180} elseif ($Protocol -eq 'SharedBaseline') {150} else {30} }
}
if ($AttributionOnly -and -not $PSBoundParameters.ContainsKey('TimeBoxMinutes')) {$TimeBoxMinutes=5}
if ($DryRun) {
    . (Join-Path $PSScriptRoot 'obs-overlay-bench-selfcheck.ps1')
    Test-ObsBenchSchedule
    $count = if ($Designer) { @(Get-ObsDesignerConditions $Profile).Count } else { 1 }
    $warmup = if ($Designer) { 60 } else { 180 }
    $reserve = if ($Designer) { 0 } elseif ($Protocol -eq 'SharedBaseline') { if ($Profile -eq 'Fast-v1') {420} else {240} } else {120}
    $windows = if ($AttributionOnly) {0} else {$schedule.Count * 150}
    $minutes = ($windows + $warmup + $reserve) / 60
    $total = $minutes * $count
    if ($Designer -and $Profile -eq 'Fast-v1') { $total += 10 + 1 + 5 }
    if ($total -gt $TimeBoxMinutes) { throw "Profile requires $total minutes including switching reserve; box is $TimeBoxMinutes." }
    Write-Output "Mode: $(if ($Designer) {'Designer'} elseif ($WorstFrom) {'Worst'} else {$Protocol}) / $($Workload[0]); profile=$Profile; version=1; seed=$Seed"
    if ($AttributionOnly) {
        Write-Output 'Warm-up-only attribution diagnostic: bounded unscored all-8 show/hide bootstrap, then all 8 exact-one live look mappings and off-state exit certification, 180s minimum excluding bootstrap; no scored arms or resource qualification.'
        Write-Output 'DryRun only: no listener/process/filesystem mutation; diagnostic time box includes OBS switching.'
        return
    }
    if ($Designer) {
        foreach ($c in @(Get-ObsDesignerConditions $Profile)) {
            $theme = if ($c.worst) {$selectedOptions.theme} else {'pill'}
            Write-Output "Schedule [$($c.name) / $theme / Lyrics $(if ($c.lyrics) {'open'} else {'closed'})]: $(if ($Pairs -eq 2) {'A B | B A'} else {'A B | B A | A B | B A'}) (30+120s each); fresh launch + 60s warm-up"
        }
    } else { Write-Output "Schedule: $(($schedule | ForEach-Object { $_.id + $(if ($_.theme) { ':' + $_.theme }) }) -join ' ')" }
    if ($Designer -and $Profile -eq 'Fast-v1') {
        Write-Output 'Arithmetic: 4 anchors x 2 pairs x 2 arms x (30+120)s = 40 min; 4 x 60s warm-up = 4 min; 2 calibration AB pairs = 10 min; structural probe reserve = 1 min; setup/switching/cleanup reserve = 5 min; total=60 min; hard deadline from invocation'
        Write-Output 'Structural: sample-paused, fillTimer=0, runningAnimations=0, counters stable over 5s; NOT a resource pass. Sample-paused resources and omitted Lyrics interactions deferred to Exhaustive-v1.'
        Write-Output 'Calibration: A-only +1 pp CPU and +120 MiB retained memory, single AB pair each; target metric must FAIL budget (calibration detected); gross attribution checks, NOT near-ceiling sensitivity.'
        Write-Output 'Calibration-only admission: 10s switching + 20s cleanup; anchors retain existing reserves; startup-age waits count toward the hard deadline.'
    } else {
        Write-Output "Arithmetic: $($schedule.Count) arms x (30+120)s + ${warmup}s warm-up = $(($windows+$warmup)/60) min + $($reserve/60) min switching reserve = $minutes min/block; $count block(s) = $total min; time box=$TimeBoxMinutes min; fits=True"
    }
    if ($Designer) { Write-Output 'A=preview Open+visible; B=closed; whole-owned-tree budgets +80 MiB/+0.5 pp. WorstFrom must satisfy the selected profile admission.' }
    if ($Designer) { Write-Output 'DX12-eager only. Before the first switch, wait unscored so the exact 30s settle ends at browser age >=150s; recheck after switching and put extra wait before settle, never inside it. Collector trace/argv delivery informational; exits inside settle/measurement still invalidate; no runtime equivalence claim.' }
    if ($Protocol -eq 'SharedBaseline') { Write-Output "$($Pairs*8) A + $($Pairs*4+2) B (B0/B_end included); only adjacent A share each B; conservative brackets; drift/cold-cost/retention/mixed -> separately approved fresh Exhaustive-v1 four-pair 30-minute command." }
    if ($Workload[0] -eq 'Paused') { Write-Output $(if ($Profile -eq 'Fast-v1') {'Pill standard baseline; frames-worst.json pausedExtensions each require a separate approved command; fast profile is diagnostic only.'} else {'Pill standard baseline; frames-worst.json pausedExtensions each require a separate 30-minute command.'}) }
    Write-Output "Frames admission: $admission$(if ($admission -eq 'provisional-composed') {'; qualificationComplete=false; source hashes/payload identity are attested assertions, not independently verified; NOT certification'})"
    Write-Output 'DryRun only: profileComplete=false; exhaustiveComplete=false; no measurements or admission bypass.'
    return
}
if (-not $Designer -and -not $AppOnly) {
    $gatePath = if ($FramesFrom) { $FramesFrom } elseif ($WorstFrom) { $WorstFrom } else { throw 'Real OBS requires -FramesFrom frames-worst.json certifying all A-FRAMES rows.' }
    $gate = Read-ObsFramesWorst $gatePath -Profile $Profile
    $framesEvidence=$gate
    $admission=Get-ObsBenchAdmission $framesEvidence
    if ($gate.framesGreen -ne $true -and -not ($Profile -eq 'Fast-v1' -and $gate.version -eq 2 -and $gate.protocol -eq 'Fast-v2')) { throw 'A-FRAMES not certified green.' }
    if (-not $StillsReport) { throw 'Real OBS requires -StillsReport from the approved B-LOOK run.' }
    $stills = Get-Content -Raw -LiteralPath $StillsReport | ConvertFrom-Json -Depth 32
    $lookChecks = @($stills.checks | Where-Object { $_.name -like 'B-LOOK*' })
    if (-not $stills.passed -or $lookChecks.Count -eq 0 -or @($lookChecks | Where-Object status -ne pass).Count) { throw 'B-LOOK stills are not certified green.' }
}
if ($Designer) {
    if (-not $worstData) { throw '-Designer requires -WorstFrom for the max-area preview condition.' }
    if ($Profile -eq 'Fast-v1' -and -not $SkipPublish) { throw 'Designer Fast-v1 requires a prebuilt hook executable (-SkipPublish); build time cannot overrun its hard deadline.' }
    if (-not (Test-Path (Join-Path $repo '.tools/better-lyrics/2.4.1.2.fingerprint.json'))) { throw 'P2 blocked: provision the lyrics fixture before Designer bench.' }
    $AppOnly = $true
    $WarmupSeconds = 60
    $AppPrivateBudgetMiB = 80
}
$commandLine = 'pwsh -NoProfile -File scripts/obs-overlay-bench.ps1 ' + (($PSBoundParameters.GetEnumerator() | ForEach-Object {
    if ($_.Value -is [switch]) { if ($_.Value) { "-$($_.Key)" } } else { "-$($_.Key) $(@($_.Value) -join ',')" } }) -join ' ')
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
$appDirectory = Join-Path $repo 'artifacts/obs-overlay/app'
$appExe = Join-Path $appDirectory 'Nativune.exe'
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$runDirectory = Join-Path $outputRoot $(if ($AppOnly) { "$runId-apponly" } else { $runId })
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
$trackSeconds = 14400.0
$ageMarginSeconds = 60.0
$settleSeconds = 30.0
$measureSeconds = 120.0
$armSeconds = $settleSeconds + $measureSeconds
$ageLimitSeconds = $trackSeconds - $ageMarginSeconds
if ($WarmupSeconds + $armSeconds -gt $ageLimitSeconds) {
    throw "-WarmupSeconds $WarmupSeconds plus one arm ($armSeconds s) exceeds the fixture age limit ($ageLimitSeconds s = track $trackSeconds s minus $ageMarginSeconds s margin); use -WarmupSeconds $($ageLimitSeconds - $armSeconds) or less."
}
# -WarmupASeconds defaults to 60 but never above -WarmupSeconds unless given explicitly (then it must fit).
if (-not $PSBoundParameters.ContainsKey('WarmupASeconds')) { $WarmupASeconds = [Math]::Min($WarmupASeconds, $WarmupSeconds) }
if ($WarmupASeconds -gt $WarmupSeconds) { throw "-WarmupASeconds $WarmupASeconds must be <= -WarmupSeconds $WarmupSeconds." }
$positionTolerance = 5.0
$maxGapSeconds = 3.0
$statsEverySeconds = 5.0
$pairsPerBlock = $Pairs
# ABBA x2 generalised: odd pairs A B, even pairs B A.
$pairOrders = @(for ($p = 1; $p -le $Pairs; $p++) { , @(if ($p % 2) { 'A', 'B' } else { 'B', 'A' }) })
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
    'NATIVUNE_TEST_DISCORD_PAUSE_SECONDS', 'NATIVUNE_TEST_OVERLAY_READ_PROBE', 'NATIVUNE_TEST_OVERLAY_EAGER_GPU_INFO')
$isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
$budgets = if ($AppOnly) {
    [ordered]@{ 'app.cpuPp' = $AppCpuBudgetPp; 'app.privateMiB' = $AppPrivateBudgetMiB }
} else {
    [ordered]@{
        'obs.cpuPp' = $ObsCpuBudgetPp; 'obs.privateMiB' = $ObsPrivateBudgetMiB; 'obs.gpuEnginePp' = $ObsGpuBudgetEnginePp
        'obs.renderMs' = $ObsRenderBudgetMs; 'obs.skippedFrames' = $ObsSkippedFramesBudget
        'app.cpuPp' = $AppCpuBudgetPp; 'app.privateMiB' = $AppPrivateBudgetMiB
    }
}

$checks = [Collections.Generic.List[object]]::new()
$launches = [Collections.Generic.List[object]]::new()
$arms = [Collections.Generic.List[object]]::new()
$errors = [Collections.Generic.List[object]]::new()
$script:launchIndex = 0
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
# Every launch/block/workload/harness error lands in report.errors (never lost to a later failure).
function Add-RunError([string] $Scope, $Workload, $Block, $Launch, $ErrorRecord) {
    $errors.Add([ordered]@{ scope = $Scope; workload = $Workload; block = $Block; launch = $Launch
        message = $ErrorRecord.Exception.Message; scriptStackTrace = $ErrorRecord.ScriptStackTrace })
}
function Get-Prop($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}
function Get-Qpc { [double] [Diagnostics.Stopwatch]::GetTimestamp() }
function Get-Seconds($From, $To) { ([double] $To - [double] $From) / $freq }
function Assert-DesignerDeadline([double] $RequiredSeconds = 0) {
    if (-not $Designer -or $Profile -ne 'Fast-v1') { return }
    $reserve = if ($script:designerCleaning) {2} else {20}
    if (-not (Test-ObsDesignerDeadlineFits (Get-Qpc) $script:designerDeadlineQpc $freq $RequiredSeconds $reserve)) {
        $script:timeBoxHit = $true
        throw 'Designer Fast-v1 invocation deadline: unfinished work BLOCKED; cleanup reserve retained.'
    }
}
function Wait-UntilQpc([double] $Qpc) {
    while ($true) {
        Assert-DesignerDeadline
        $left = ($Qpc - (Get-Qpc)) / $freq
        if (($Designer -or -not $AppOnly) -and (Get-ObsOnScreenSeconds) -ge $timeBoxSeconds) {$script:timeBoxHit=$true;throw 'TIMEBOX reached; unfinished gates blocked.'}
        if ($left -le 0) { return }
        Start-Sleep -Milliseconds ([int] [Math]::Max(10, [Math]::Min(250, $left * 1000)))
    }
}
function Wait-For([scriptblock] $Probe, [double] $Seconds, [int] $PollMs = 250) {
    Assert-DesignerDeadline
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        Assert-DesignerDeadline
        $value = & $Probe
        Assert-DesignerDeadline
        if ($value) { return $value }
        Start-Sleep -Milliseconds $PollMs
    }
    Assert-DesignerDeadline
    & $Probe
}
function ConvertTo-SafeName([string] $Name) { ($Name -replace '[^A-Za-z0-9-]', '-') }
function Get-Mean($Values) { $v = @(@($Values) | Where-Object { $null -ne $_ }); if ($v.Count -eq 0) { $null } else { ($v | Measure-Object -Average).Average } }

function New-Root([string] $Name) {
    Assert-DesignerDeadline 120
    $root = Join-Path $rootBase $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $ubolDestination = Join-Path $root '.tools/ubol'
    [IO.Directory]::CreateDirectory($ubolDestination) | Out-Null
    Copy-Item -LiteralPath $ubolSource -Destination $ubolDestination -Recurse
    Assert-DesignerDeadline
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
# Unset = remove the variable (PowerShell passes $null to .NET string parameters as ''); empty values are removed too.
foreach ($name in @($spec.unset)) { if ($name) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue } }
foreach ($p in $spec.env.PSObject.Properties) {
    if ([string]::IsNullOrEmpty([string] $p.Value)) { Remove-Item -LiteralPath "Env:$($p.Name)" -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable($p.Name, [string] $p.Value, 'Process') }
}
$proc = Start-Process -FilePath $spec.exe -ArgumentList @($spec.arguments) -WorkingDirectory $spec.workingDirectory -PassThru
[IO.File]::WriteAllText($spec.pidFile, (@{ processId = $proc.Id } | ConvertTo-Json -Compress))
'@, [Text.UTF8Encoding]::new($false))

# $null/'' removes the variable: the app treats an empty NATIVUNE_TEST_DISCORD_BENCH_* value as invalid (only an
# absent variable means command-only), and PowerShell passes $null to .NET string parameters as ''.
function Set-ProcessEnv([string] $Name, $Value) {
    if ([string]::IsNullOrEmpty([string] $Value)) { Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable($Name, [string] $Value, 'Process') }
}
# Basic-user token launch (runas /trustlevel:0x20000 -> helper), as in the E2E harness.
function Invoke-RunasLaunch([string] $Exe, [string[]] $Arguments, [string] $WorkingDirectory, $Environment) {
    Assert-DesignerDeadline 30
    $spec = Join-Path $rootBase "launch-$($script:launchCount).json"
    $pidFile = Join-Path $rootBase "launch-$($script:launchCount).pid.json"
    $set = [ordered]@{}; $unset = @()
    foreach ($entry in $Environment.GetEnumerator()) { if ([string]::IsNullOrEmpty([string] $entry.Value)) { $unset += $entry.Key } else { $set[$entry.Key] = [string] $entry.Value } }
    $specJson = [ordered]@{ exe = $Exe; arguments = $Arguments; workingDirectory = $WorkingDirectory; env = $set; unset = $unset; pidFile = $pidFile }
    [IO.File]::WriteAllText($spec, ($specJson | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    & runas.exe '/trustlevel:0x20000' "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$launchHelper`" `"$spec`"" | Out-Null
    if (-not (Wait-For { Test-Path -LiteralPath $pidFile } 30)) { throw "runas /trustlevel launch helper wrote no PID file ($pidFile)." }
    Get-Process -Id ([int] (Get-Content -Raw -LiteralPath $pidFile | ConvertFrom-Json).processId)
}
function Start-App([string] $Root, [string] $BenchProfile) {
    Assert-DesignerDeadline 90
    $environment = [ordered]@{}
    foreach ($entry in $testEnv.GetEnumerator()) { $environment[$entry.Key] = $entry.Value }
    foreach ($key in $benchEnvKeys) { $environment[$key] = $null }
    $environment['NATIVUNE_TEST_DISCORD_BENCH_PROFILE'] = $BenchProfile
    $environment['NATIVUNE_TEST_DISCORD_BENCH_STATE'] = 'Hidden'
    # Explicitly clear inherited opt-in for non-Designer runs (including runas).
    $environment['NATIVUNE_TEST_OVERLAY_EAGER_GPU_INFO'] = if ($Designer) {'1'} else {$null}
    # Hook-only overlay read probe (PlayerControls.ReadPlaybackStateAsync); absent = normal reads.
    if ($ReadProbe -ne 'none') { $environment['NATIVUNE_TEST_OVERLAY_READ_PROBE'] = $ReadProbe }
    $arguments = @('web', '--root', $Root)
    $script:launchCount++
    if ($isElevated) { $process = Invoke-RunasLaunch $appExe $arguments $appDirectory $environment }
    else {
        foreach ($entry in $environment.GetEnumerator()) { Set-ProcessEnv $entry.Key $entry.Value }
        $process = Start-Process -FilePath $appExe -ArgumentList $arguments -WorkingDirectory $appDirectory -PassThru
    }
    $process
}
function Get-BenchDirectory([string] $Root) { Join-Path $Root 'data/discord-bench' }
function Send-HookCommand([string] $Root, [string] $Name) {
    Assert-DesignerDeadline
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
    Assert-DesignerDeadline
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
# Report only: scriptChars -> count for Overlay-mode reads in the same (Start, End] window as Get-OverlayReads. Tells
# whether ticks used the tiny invoker (small scriptChars) or the full script / install-and-read (large).
function Get-OverlayScriptChars($Start, $End) {
    if (-not $Start -or -not $End) { return $null }
    $s0 = [double] $Start.qpc; $s1 = [double] $End.qpc; $counts = @{}
    foreach ($read in @(Get-Prop $End.diag 'reads')) {
        if (-not $read) { continue }
        $q = [double] $read.startQpc
        if ($q -gt $s0 -and $q -le $s1 -and [string] (Get-Prop $read 'mode') -eq 'Overlay') {
            $k = [string] [int] (Get-Prop $read 'scriptChars'); $counts[$k] = [int] $counts[$k] + 1
        }
    }
    $out = [ordered]@{}
    foreach ($k in ($counts.Keys | Sort-Object { [int] $_ })) { $out[$k] = $counts[$k] }
    $out
}
function Merge-ScriptCharCounts($Maps) {
    $counts = @{}
    foreach ($m in @($Maps)) { if ($null -eq $m) { continue }; foreach ($k in $m.Keys) { $counts[[string] $k] = [int] $counts[[string] $k] + [int] $m[$k] } }
    $out = [ordered]@{}
    foreach ($k in ($counts.Keys | Sort-Object { [int] $_ })) { $out[$k] = $counts[$k] }
    $out
}
function Stop-App($Process, [string] $Root) {
    if (-not $Process) { return }
    if (-not $Process.HasExited) {
        try { Send-HookCommand $Root 'command-quit' } catch { }
        $waitMs = if ($Designer -and $Profile -eq 'Fast-v1') {
            [int][Math]::Clamp(($script:designerDeadlineQpc-(Get-Qpc))/$freq*1000-2000,0,8000)
        } else {8000}
        if (-not $Process.WaitForExit($waitMs)) {
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

# -AppOnly SSE client: a hidden pwsh child that holds one /events stream and discards what it reads (no logging, so
# the reader adds no disk I/O). It is not in the app tree (matched by PID descent from Nativune / the WebView2 root).
$benchReaderScript = @'
param([string] $Url)
$handler = [Net.Http.SocketsHttpHandler]::new(); $handler.UseProxy = $false
$client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
while ($true) {
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Url)
        $r = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if ([int] $r.StatusCode -eq 200) {
            $reader = [IO.StreamReader]::new($r.Content.ReadAsStream(), [Text.UTF8Encoding]::new($false))
            while ($null -ne $reader.ReadLine()) { }
        }
        $r.Dispose()
    } catch { }
    Start-Sleep -Milliseconds 500
}
'@
function Start-BenchReader($Ctx) {
    $command = "& { $benchReaderScript } -Url '$($overlayUrl)events'"
    if ($Designer) { Start-DesignerPreview $Ctx; return }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $Ctx.Reader = Start-Process -FilePath pwsh -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -PassThru -WindowStyle Hidden
}
function Stop-BenchReader($Ctx) {
    if ($Designer -and $Ctx -and $Ctx.Reader) { Stop-DesignerPreview $Ctx; return }
    if (-not $Ctx -or -not $Ctx.Reader) { return }
    try { if (-not $Ctx.Reader.HasExited) { Stop-Process -Id $Ctx.Reader.Id -Force -ErrorAction SilentlyContinue; [void] $Ctx.Reader.WaitForExit(5000) } } catch { }
    $Ctx.Reader = $null
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
    # Comma: return the HashSet itself; a bare `$ids` unrolls it to Object[] (fixed size: .Add throws in Get-AppTree).
    , $ids
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
# Cumulative tree CPU: $Seen maps process key (PID@creation) -> last observed CPU seconds, so an exited child keeps
# its last value (no negative step) and a new child adds its CPU from creation (it was created inside the window).
function Measure-Tree($Entries, [hashtable] $Seen) {
    $priv = 0.0; $missing = 0
    foreach ($t in $Entries) {
        $p = Get-Process -Id $t.pid -ErrorAction SilentlyContinue
        if (-not $p) { $missing++; continue }
        try { $Seen[$t.key] = $p.TotalProcessorTime.TotalSeconds; $priv += [double] $p.PrivateMemorySize64 } catch { $missing++ }
    }
    $cpu = 0.0; foreach ($v in $Seen.Values) { $cpu += [double] $v }
    [pscustomobject]@{ cpu = $cpu; privateMiB = $priv / 1048576.0; missing = $missing }
}

# Per-role CPU breakdown of the app tree (report only). Roles come from the Win32_Process command line already fetched
# for the tree: Nativune.exe = host; msedgewebview2.exe by --type= (none = browser).
$roleNames = @('host', 'browser', 'renderer', 'gpu-process', 'utility', 'crashpad-handler', 'other')
function Get-ProcessRole($Proc) {
    $role = 'other'; $sub = $null
    if ($Proc -and $Proc.Name -ieq 'Nativune.exe') { $role = 'host' }
    elseif ($Proc -and $Proc.Name -in @('msedgewebview2.exe','obs-browser-page.exe') -and $Proc.CommandLine) {
        $m = [regex]::Match([string] $Proc.CommandLine, '(?:^|\s)--type=([^\s"]+)')
        if (-not $m.Success) { $role = 'browser' }
        elseif ($m.Groups[1].Value -in @('renderer', 'gpu-process', 'utility', 'crashpad-handler')) {
            $role = $m.Groups[1].Value
            if ($role -eq 'utility') {
                $s = [regex]::Match([string] $Proc.CommandLine, '(?:^|\s)--utility-sub-type=([^\s"]+)')
                if ($s.Success) { $sub = $s.Groups[1].Value }
            }
        }
    }
    [pscustomobject]@{ role = $role; label = $(if ($sub) { "${role}:$sub" } else { $role }) }
}
function Add-ProcessRoles([hashtable] $RoleByKey, $Entries, $All) {
    $need = @($Entries | Where-Object { -not $RoleByKey.ContainsKey($_.key) })
    if ($need.Count -eq 0) { return }
    $byId = @{}; foreach ($p in $All) { $byId[[int] $p.ProcessId] = $p }
    foreach ($t in $need) { $RoleByKey[$t.key] = Get-ProcessRole $byId[[int] $t.pid] }
}
# Cumulative CPU seconds per role label ("utility:<sub-type>" for utility with a sub-type), from Measure-Tree's $Seen.
function Get-RoleCpu([hashtable] $Seen, [hashtable] $RoleByKey) {
    $h = @{}
    foreach ($k in $Seen.Keys) {
        $label = if ($RoleByKey.ContainsKey($k)) { $RoleByKey[$k].label } else { 'other' }
        $h[$label] = [double] $h[$label] + [double] $Seen[$k]
    }
    $h
}
# metrics.roles: cpuPp (same pp-of-one-core formula as app.cpuPp) and the number of distinct processes seen, per role.
function New-RoleMetrics([hashtable] $First, [hashtable] $Last, [double] $Span, [hashtable] $RoleByKey) {
    $pp = @{}; $subs = [ordered]@{}; $count = @{}
    foreach ($label in @(@($First.Keys) + @($Last.Keys) | Select-Object -Unique)) {
        $d = ([double] $Last[$label] - [double] $First[$label]) / $Span * 100
        $c = $label.IndexOf(':')
        $role = if ($c -ge 0) { $label.Substring(0, $c) } else { $label }
        $pp[$role] = [double] $pp[$role] + $d
        if ($c -ge 0) { $sk = $label.Substring($c + 1); $subs[$sk] = Round3 ([double] $subs[$sk] + $d) }
    }
    foreach ($v in $RoleByKey.Values) { $count[$v.role] = [int] $count[$v.role] + 1 }
    $out = [ordered]@{}
    foreach ($r in $roleNames) {
        $out[$r] = [ordered]@{ cpuPp = Round3 ([double] $pp[$r]); count = [int] $count[$r] }
        if ($r -eq 'utility') { $out[$r]['subTypesCpuPp'] = $subs }
    }
    $out
}
function Get-RoleDeltaSummary($Pairs) {
    $out = [ordered]@{}
    foreach ($r in $roleNames) {
        $v = @(@($Pairs) | ForEach-Object { $_.roleDelta[$r] } | Where-Object { $null -ne $_ } | ForEach-Object { [double] $_ })
        if ($v.Count -eq 0) { continue }
        $out[$r] = [ordered]@{ min = Round3 ($v | Measure-Object -Minimum).Minimum; max = Round3 ($v | Measure-Object -Maximum).Maximum; mean = Round3 (Get-Mean $v); n = $v.Count }
    }
    $out
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

. (Join-Path $PSScriptRoot 'obs-overlay-bench-runtime.ps1')
function Get-ObsOnScreenSeconds {
    $s = $script:obsUsedSeconds
    if ($Designer -and (Get-Variable designerRunStart -Scope Script -ErrorAction SilentlyContinue)) {return (Get-Seconds $script:designerRunStart (Get-Qpc))}
    if ($null -ne $script:obsLaunchQpc) { $s += Get-Seconds $script:obsLaunchQpc (Get-Qpc) }
    $s
}
function Test-TimeFits([double] $Seconds) {
    if ($Designer -and $Profile -eq 'Fast-v1') { return Test-ObsDesignerDeadlineFits (Get-Qpc) $script:designerDeadlineQpc $freq $Seconds 20 }
    ((Get-ObsOnScreenSeconds) + $Seconds) -le $timeBoxSeconds
}

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
    Assert-DesignerDeadline 120
    $script:launchIndex = $launches.Count + 1
    $name = "$WorkloadName-b$Block-l$($script:launchIndex)"
    $record = [ordered]@{ launch = $script:launchIndex; workload = $WorkloadName; block = $Block; name = $name }
    $launches.Add($record)
    if (-not (Test-PrefixFree)) { throw "http://localhost:$port/ is held by another process before $name." }
    $root = New-Root $name
    Write-Settings $root
    $configurations = @{}
    $specs = @(for ($i=0; $i -lt $allThemes.Count; $i++) {
        $theme = $allThemes[$i]; $id = 'bench00' + $i
        $options = if ($Protocol -ne 'SharedBaseline' -and $theme -eq $selectedOptions.theme) { $selectedOptions } else { New-ObsBenchOptions $theme }
        $configurations[$theme] = @{id=$id;name="Bench $theme";options=$options}
        $size=Get-ObsBenchSourceSize $options
        [pscustomobject]@{theme=$theme;id=$id;url="http://localhost:47813/?look=$id";width=$size.w;height=$size.h}
    })
    [IO.File]::WriteAllText((Join-Path $root 'data/obs-looks.json'),(@{version=1;looks=@($configurations.Values);retired=@()}|ConvertTo-Json -Depth 8),[Text.UTF8Encoding]::new($false))
    if ($Designer) {
        Copy-Item -LiteralPath (Join-Path $repo '.tools/better-lyrics') -Destination (Join-Path $root '.tools/better-lyrics') -Recurse
    }
    $profile=if ($WorkloadName -eq 'Playing') {'PlayingLong'} else {'Paused'}
    $ctx = [pscustomobject]@{ Name = $name; Workload = $WorkloadName; Block = $Block; Launch = $script:launchIndex; Root = $root
        App = $null; AppStart = $null; Obs = $null; ObsProcess = $null; ObsStart = $null; Session = $null; ItemId = $null
        ReadyQpc = $null; ItemEnabled = $false; PageArtBaseline = 0; Record = $record; Reader = $null
        Items = $null; ActiveTheme = $selectedOptions.theme; LookId = $configurations[$selectedOptions.theme].id; Shape0 = $null; ArmTrace = $null
        PreviewCandidates=@();PreviewBirths=@();PreviewBefore=@();PreviewCloseKeys=@();PreviewOpenUtc=$null
        OverlayRenderers=@{};OverlayTargets=@{};InfrastructureRenderers=@{};RendererGenerations=@{};RendererActivation=$null
        InfrastructureSlotCount=0;CefBaselinePending=$false;WarmingUp=$false;GpuTrace=$null;GpuGateComplete=$false }
    $script:currentCtx = $ctx
    try {
        if ($Designer) {
            $record['designerCondition']="$($script:designerCondition.name)-lyrics-$($script:designerCondition.lyrics)"
            $record['roleInventory']=[Collections.Generic.List[object]]::new()
            $ctx.GpuTrace=Start-DesignerGpuTrace $root $record
        }
        $app=Start-App $root $profile
        $ctx.App=$app
        $record['fixtureProfile']=$profile
        $record['designerLifecycle']=[Collections.Generic.List[object]]::new()
        $record['fixtureProgress']=[Collections.Generic.List[object]]::new()
        $record['obsAttribution']=[Collections.Generic.List[object]]::new()
        $record['rendererGenerations']=[Collections.Generic.List[object]]::new()
        $ctx.AppStart = $app.StartTime
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
        $record['fixtureReadyEpochQpc'] = $ctx.ReadyQpc
        $maxArt = if ($Designer -and $Profile -eq 'Fast-v1') {$script:designerCondition.worst} else {$WorstFrom -or ($Designer -and $script:designerCondition.worst)}
        if ($maxArt) { Send-ObsBenchPayload $ctx 'command-obs-fixture-art' 'fixture-max' }
        if ($Designer) {
            Send-HookCommand $root $(if ($script:designerCondition.lyrics) {'command-lyrics-open'} else {'command-lyrics-close'})
            $lyricsReady = Wait-For {$s=Get-State $root 'lyrics';if ((Get-Prop (Get-Overlay $s 'lyrics') 'open') -eq $script:designerCondition.lyrics) {$s}} 30
            if (-not $lyricsReady) { throw 'P2 blocked: lyrics window did not reach the requested state.' }
        }
        $record['mode'] = if ($AppOnly) { 'apponly' } else { 'obs' }
        if ($AppOnly) { return $ctx }

        $ctx.Obs = New-ObsPortable -RunDir (Join-Path $rootBase "$name-obs") -RemoteDebuggingPort (Get-ObsPortableFreePort)
        $script:obsLaunchQpc = Get-Qpc
        $ctx.ObsProcess = Start-ObsPortable $ctx.Obs
        $ctx.ObsStart = $ctx.ObsProcess.StartTime
        $ctx.Session = Connect-ObsWebSocket $ctx.Obs
        Get-ObsPreSceneAttribution $ctx
        $record['cdpListener']=$ctx.Obs.DebugListener
        $ctx.Items = Initialize-ObsOverlayEightSourceScene $ctx.Session $specs
        $record['sceneSpecs'] = $specs
        $record['sceneItems'] = $ctx.Items
        $version = Invoke-ObsRequest $ctx.Session 'GetVersion' @{}
        $record['obsVersion'] = Get-Prop $version 'obsVersion'
        # Environment: Studio Mode off, no outputs, preview + browser HW acceleration at defaults (recorded).
        $studio = Get-Prop (Invoke-ObsRequest $ctx.Session 'GetStudioModeEnabled' @{}) 'studioModeEnabled'
        if ($studio) { [void] (Invoke-ObsRequest $ctx.Session 'SetStudioModeEnabled' @{ studioModeEnabled = $false }) }
        $record['studioModeInitially'] = $studio
        $record['studioModeEnabled'] = Get-Prop (Invoke-ObsRequest $ctx.Session 'GetStudioModeEnabled' @{}) 'studioModeEnabled'
        $outputs = [ordered]@{}
        foreach ($req in @('GetStreamStatus', 'GetRecordStatus', 'GetVirtualCamStatus', 'GetReplayBufferStatus')) {
            # Code 604 means the output isn't configured (for example, replay buffer off), so it can't be active.
            try { $outputs[$req] = [bool] (Get-Prop (Invoke-ObsRequest $ctx.Session $req @{}) 'outputActive') } catch { $outputs[$req] = if ($_.Exception.Message -match 'code 604\b') { $false } else { "unavailable: $($_.Exception.Message)" } }
        }
        $record['outputsActive'] = $outputs
        $configDir = Join-Path $ctx.Obs.RunDir 'config/obs-studio'
        $record['previewEnabled'] = Read-IniValue $configDir 'BasicWindow' 'PreviewEnabled'
        $record['browserHWAccel'] = Read-IniValue $configDir 'General' 'BrowserHWAccel'
        $record['previewEnabledNote'] = 'absent key = OBS default (preview shown)'
        $record['browserHWAccelNote'] = 'absent key = OBS default (enabled)'
        $settings = $ctx.Items[$ctx.ActiveTheme].settings
        $record['source'] = [ordered]@{ url = Get-Prop $settings 'url'; width = Get-Prop $settings 'width'; height = Get-Prop $settings 'height'
            shutdown = Get-Prop $settings 'shutdown'; fps = Get-Prop $settings 'fps'; fps_custom = Get-Prop $settings 'fps_custom' }
        $ctx.ItemId = $ctx.Items[$ctx.ActiveTheme].itemId
        $ctx.ItemEnabled = $false
        $envOk = ($record['studioModeEnabled'] -eq $false) -and @($outputs.Values | Where-Object {$_ -ne $false}).Count -eq 0 -and
            (Get-Prop $settings 'shutdown') -eq $true -and "$($record['obsVersion'])" -like "$script:ObsPortableVersion*"
        $record['environmentOk'] = $envOk
        if (-not $envOk) { throw "$name`: OBS environment differs from the G3 seeds (see launches[$($script:launchIndex - 1)])." }
        $ctx
    } catch {
        $launchError = $_
        try { Stop-Launch $ctx } catch { Add-RunError 'stopLaunch' $WorkloadName $Block $ctx.Launch $_ }
        throw $launchError
    }
}
function Stop-Launch($Ctx) {
    if (-not $Ctx) { return }
    $wasCleaning=$script:designerCleaning
    $script:designerCleaning=$true
    try {
        if ($Ctx.ArmTrace) { try { [void](Stop-ObsArmTrace $Ctx.ArmTrace) } catch {} ; $Ctx.ArmTrace=$null }
        try { Stop-BenchReader $Ctx } catch { $Ctx.Record['readerStopError']=$_.Exception.Message }
        if ($Ctx.GpuTrace) {
            try { Stop-DesignerGpuTrace $Ctx } catch { $Ctx.Record.gpuInfo['traceStopError']=$_.Exception.Message }
        }
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
    } finally {
        $script:currentCtx=$null
        $script:designerCleaning=$wasCleaning
    }
}
function Set-SourceEnabled($Ctx, [bool] $Enabled) {
    if (-not $Enabled -and $Ctx.ItemEnabled) {
        [void](Get-ObsAttribution $Ctx "before-disable-$($Ctx.ActiveTheme)")
    }
    if ($Enabled) {
        $Ctx.RendererActivation=@{beforeKeys=@(Get-ObsRendererInventory $Ctx | ForEach-Object key);startUtc=[DateTime]::UtcNow.ToString('o')}
    }
    Set-ObsOverlayEightSource $Ctx.Session $Ctx.Items $(if ($Enabled) {$Ctx.ActiveTheme} else {$null})
    if ($Enabled) {
        $Ctx.LookId=$Ctx.Items[$Ctx.ActiveTheme].lookId
        if ($Ctx.CefBaselinePending) {Initialize-ObsLazyAttribution $Ctx}
        if (-not (Wait-For {$s=Get-State $Ctx.Root 'sourceattribution';if (Test-ObsBenchA $Ctx $s) {$s}} 15)) {
            throw 'Source not ready for pre-window renderer attribution.'
        }
        try {[void](Get-ObsAttribution $Ctx "active-$($Ctx.ActiveTheme)")}
        finally {$Ctx.RendererActivation=$null}
    }
    $Ctx.ItemEnabled = $Enabled
    if (-not $Enabled) {
        [void](Wait-For {$s=Get-State $Ctx.Root 'switchzero';Test-ObsBenchB $s} 10)
        if (-not $Ctx.WarmingUp) {Wait-ObsOverlayTeardown $Ctx}
        $shapeDeadline=(Get-Qpc)+10*$freq
        do {
            $shape=Get-ObsOffShape $Ctx
            if (-not $Ctx.Shape0 -or $shape -eq $Ctx.Shape0) {break}
            Start-Sleep -Milliseconds 250
        } while ((Get-Qpc) -lt $shapeDeadline)
    }
}
function Get-ObsStats($Ctx) {
    $s = Invoke-ObsRequest $Ctx.Session 'GetStats' @{}
    [pscustomobject]@{ skipped = [double] (Get-Prop $s 'renderSkippedFrames'); renderMs = [double] (Get-Prop $s 'averageFrameRenderTime') }
}
# Root identity guard supplements full-tree tracing and sampled descendant identities.
function Test-RootsAlive($Ctx) {
    $a = Get-Process -Id $Ctx.App.Id -ErrorAction SilentlyContinue
    $appOk = $a -and $a.StartTime -eq $Ctx.AppStart
    if ($AppOnly) { return [bool] $appOk }
    $o = Get-Process -Id $Ctx.ObsProcess.Id -ErrorAction SilentlyContinue
    [bool] ($appOk -and $o -and $o.StartTime -eq $Ctx.ObsStart)
}

# ---------------------------------------------------------------------------------------------------------------
# One arm: 30 s settle (validity from hook state) + 120 s measure (samples only) + post-measure validity.

function Invoke-Arm($Ctx, [int] $Pair, [string] $Condition, [int] $Attempt) {
    Assert-DesignerDeadline (Get-DesignerAdmissionSeconds $armSeconds ([bool]$script:designerCalibration))
    $firstGpuWindow=$Designer -and -not $Ctx.GpuGateComplete
    Wait-DesignerStartupGate $Ctx
    $arm = [ordered]@{ workload = $Ctx.Workload; block = $Ctx.Block; launch = $Ctx.Launch; pair = $Pair; condition = $Condition
        attempt = $Attempt; valid = $true; reasons = [Collections.Generic.List[string]]::new() }
    $arm['id'] = "l$($Ctx.Launch)-p$Pair-$Condition-a$Attempt"
    $arm['theme'] = $Ctx.ActiveTheme
    $arms.Add($arm)
    $invalid = { param($r) $arm.valid = $false; if (-not $arm.reasons.Contains($r)) {$arm.reasons.Add($r)} }
    $wantState = $Ctx.Workload.ToLowerInvariant()
    $arm['sampledExits']=[Collections.Generic.List[object]]::new()
    $reportedExits=[Collections.Generic.HashSet[string]]::new()
    if ($Designer -and -not $Ctx.Reader) {Wait-DesignerPreviewTeardown $Ctx}
    $settleStart = Get-Qpc
    $settleEnd = $settleStart + $settleSeconds * $freq
    $arm['elapsedSinceReadyAtStart'] = Round3 (Get-Seconds $Ctx.ReadyQpc $settleStart)
    # Source/designer teardown is outside both windows.
    $switchStart = Get-Qpc

    if ($Condition -eq 'A') {
        # Fixture art is fetched only by a fresh page/stream, and fixtureArtServed resets on stream renewal while the page
        # keeps its image. So an A arm that finds the source already enabled (A after A) recycles it first: disable / stop,
        # wait for streams 0 (bounded 10 s, as B does), then enable / start. The 30 s settle counts from the re-enable.
        $recycled = $false
        if (($AppOnly -and $Ctx.Reader) -or (-not $AppOnly -and $Ctx.ItemEnabled)) {
            $recycled = $true
            if ($AppOnly) { Stop-BenchReader $Ctx } else { Set-SourceEnabled $Ctx $false }
            $recycleZero = Wait-For { $s = Get-State $Ctx.Root 'arecycle'; if ((Get-Overlay $s 'streams') -eq 0) { $s } } 10 500
            if (-not $recycleZero) { & $invalid 'A recycle: streams did not reach 0 within 10 s' }
        }
        if ($AppOnly) {
            # One SSE client instead of the OBS page; no page, so no fixture art is fetched.
            Start-BenchReader $Ctx
        } else {
            $pre = Get-State $Ctx.Root 'artbase'
            $Ctx.PageArtBaseline = [int] (Get-Overlay $pre 'fixtureArtServed')
            Set-SourceEnabled $Ctx $true
        }
        if ($recycled) { $settleStart = Get-Qpc; $settleEnd = $settleStart + $settleSeconds * $freq }
        if (-not $AppOnly) { $arm['artBaseline'] = $Ctx.PageArtBaseline }
        # Settle-start validity: the stream, workload state, fixture art (page only), and (Playing) a fresh position.
        # fixtureArtServed resets when a stream opens, so require >= 1 from a snapshot taken with streams >= 1.
        if ($firstGpuWindow) {Wait-DesignerStartupGate $Ctx -BeforeSettle}
        $settleStart = Get-Qpc; $settleEnd = $settleStart + $settleSeconds * $freq
        $Ctx.ArmTrace = Start-ObsArmTrace $Ctx
        $settleOk = { param($s) Test-ObsBenchA $Ctx $s }
        $open = Wait-For { $s = Get-State $Ctx.Root 'aopen'; if ((Get-Overlay $s 'streams') -ge 1) { $s } } ($settleSeconds - 8) 500
        $fresh = if ($open) { Start-Sleep -Milliseconds 1500; Get-State $Ctx.Root 'afresh' } else { $null }
        $okSettle = [bool] (& $settleOk $fresh)
        if (-not $okSettle) {
            $art = Wait-For { $s = Get-State $Ctx.Root 'aart'; if (& $settleOk $s) { $s } } ([Math]::Max(1, (Get-Seconds (Get-Qpc) $settleEnd) - 2)) 500
            if ($art) { $fresh = $art; $okSettle = $true }
        }
        $arm['settle'] = [ordered]@{ recycled = $recycled; streams = Get-Overlay $fresh 'streams'; latestState = Get-Overlay $fresh 'latestState'
            latestStale = Get-Overlay $fresh 'latestStale'; fixtureArtServed = Get-Overlay $fresh 'fixtureArtServed'; latestPosition = Get-Overlay $fresh 'latestPosition' }
        if (-not $okSettle) { & $invalid 'A settle: streams>=1, latestState, fixtureArtServed>=1 not all met' }
        if ($Ctx.Workload -eq 'Playing' -and $fresh -and (-not $Designer -or $script:designerCondition.kind -eq 'current')) {
            # Throttled fixture timers drop ticks, so position may lag wall time but never lead it,
            # and the arm (position + 150 s) must end before the last 60 s of the track.
            $elapsed = Get-Seconds $Ctx.ReadyQpc $fresh.qpc
            $position = Get-Overlay $fresh 'latestPosition'
            $duration = Get-Overlay $fresh 'latestDuration'
            $arm['settle']['elapsedAtRead'] = Round3 $elapsed
            $arm['settle']['latestDuration'] = $duration
            $arm['settle']['positionMaxAllowed'] = Round3 ($elapsed + $positionTolerance)
            $arm['settle']['positionPlusArm'] = if ($null -ne $position) { Round3 ([double] $position + 150) } else { $null }
            $arm['settle']['durationLimit'] = if ($null -ne $duration) { Round3 ([double] $duration - 60) } else { $null }
            if ($null -eq $position -or [Math]::Abs([double]$position-$elapsed) -gt $positionTolerance) {
                & $invalid "A settle: position $position differs from fixture epoch $(Round3 $elapsed) by > $positionTolerance s"
            } elseif ($null -eq $duration -or [double]$duration -lt $trackSeconds -or $elapsed + 150 -gt [double]$duration - 60) {
                & $invalid "A settle: elapsed $(Round3 $elapsed) + 150 exceeds duration $duration - 60, or duration <14400"
            }
        }
    } else {
        if ($AppOnly) { Stop-BenchReader $Ctx } elseif ($Ctx.ItemEnabled) { Set-SourceEnabled $Ctx $false }
        if ($firstGpuWindow) {Wait-DesignerStartupGate $Ctx -BeforeSettle}
        $settleStart = Get-Qpc; $settleEnd = $settleStart + $settleSeconds * $freq
        $Ctx.ArmTrace = Start-ObsArmTrace $Ctx
        $zero = Wait-For { $s = Get-State $Ctx.Root 'bzero'; if ((Get-Overlay $s 'streams') -eq 0) { $s } } ($settleSeconds - 8) 500
        $arm['settle'] = [ordered]@{ streamsZero = [bool] $zero; secondsToZero = if ($zero) { Round3 (Get-Seconds $settleStart $zero.qpc) } }
        $script:bZero = $zero
        if (-not $zero) { & $invalid 'B settle: streams did not reach 0' }
    }
    if (-not (Test-AgeFits $Ctx)) { & $invalid 'fixture elapsed +150 exceeds duration -60 at arm start' }
    Wait-UntilQpc $settleEnd
    $sPre = Get-State $Ctx.Root "$($Condition.ToLowerInvariant())pre"
    $arm['switchSeconds'] = Round3 (Get-Seconds $switchStart $settleStart)
    $arm['pre'] = Get-Prop $sPre 'state'
    if ($Designer -and $script:designerCalibration) {
        $arm['calibrationAck']=Get-DesignerCalibrationAck $Ctx $(if ($Condition -eq 'A') {$script:designerCalibration} else {@{off=$true}})
        if (-not $arm.calibrationAck) { & $invalid 'Calibration pre-window load acknowledgement missing or mismatched' }
    }
    if ($Condition -eq 'A' -and -not (Test-ObsBenchA $Ctx $sPre)) { & $invalid 'A pre-window workload/preview/count mismatch' }
    if ($Condition -eq 'A' -and $sPre -and $Ctx.Workload -eq 'Playing' -and
        (-not $Designer -or $script:designerCondition.kind -eq 'current')) {
        $age=Get-Seconds $Ctx.ReadyQpc $sPre.qpc
        if (-not (Test-ObsFixturePosition $age (Get-Overlay $sPre 'latestPosition') (Get-Overlay $sPre 'latestDuration') $trackSeconds $positionTolerance $measureSeconds)) {
            & $invalid 'A pre-window fixture position freshness/duration mismatch'
        }
    }
    if ($Condition -eq 'B' -and -not (Test-ObsBenchB $sPre)) { & $invalid 'B pre-window designer/count mismatch' }
    if (-not $AppOnly -and $Condition -eq 'B') {
        $off=Get-ObsCertifiedOff $Ctx $sPre "$($arm.id)-pre";$arm['offPre']=$off;$arm['shapePre']=$off.shape
        foreach ($reason in $off.reasons) {& $invalid $reason}
        if ($off.shape -ne $Ctx.Shape0) { & $invalid "B shape differs from shape0: $($off.shape)" }
    }
    $failureLog=Join-Path $Ctx.Root 'data/nativune.log'
    $failureCountBefore = $Ctx.ArmTrace.failureCountBefore
    if ($Condition -eq 'B') {
        $reads = if ($script:bZero -and $sPre) { Get-OverlayReads $script:bZero $sPre } else { $null }
        $arm['settle']['overlayReads'] = $reads
        if ($null -eq $reads -or $reads -ne 0 -or (Get-Overlay $sPre 'streams') -ne 0) { & $invalid "B settle: overlay reads $reads / streams $(Get-Overlay $sPre 'streams')" }
    }

    # Measure: no hook probes, no page probes, no screenshots.
    # Any descendant exit invalidates; trace also covers children born/exited between samples.
    $all0 = Get-AllProcesses
    $appTree0 = Get-AppTree $Ctx.App.Id $Ctx.Root $all0
    $obsTree0 = if ($AppOnly) { @() } else { Get-ObsTree $Ctx.ObsProcess.Id }
    $appSeen = @{}; $obsSeen = @{}
    $roleByKey = @{}; Add-ProcessRoles $roleByKey $appTree0 $all0
    $appNames = @{}; foreach ($t in $appTree0) { $appNames[$t.key] = $t.name }
    $obsNames = @{}; foreach ($t in $obsTree0) { $obsNames[$t.key] = $t.name }
    $appKeys0 = @($appNames.Keys); $obsKeys0 = @($obsNames.Keys)
    $appTree = $appTree0; $obsTree = $obsTree0
    $obsPids = [Collections.Generic.HashSet[int]]::new(); foreach ($t in $obsTree0) { [void] $obsPids.Add($t.pid) }
    $gpuOk = if ($AppOnly) { $false } else { Update-GpuCounters $obsPids }
    $samples = [Collections.Generic.List[object]]::new()
    $stats = [Collections.Generic.List[object]]::new()
    $mStart = Get-Qpc
    $Ctx.ArmTrace.measureStartUtc=[DateTime]::UtcNow
    if ($firstGpuWindow) {
        $gate=$Ctx.Record.gpuInfo.gate
        $gate['ageAtMeasurementStartSeconds']=($Ctx.ArmTrace.measureStartUtc-(ConvertTo-ObsBenchUtc $gate.browserCreationUtc)).TotalSeconds
        $gate['measurementAgeMet']=$gate.ageAtMeasurementStartSeconds -ge 150
        if (-not $gate.measurementAgeMet) { & $invalid 'First measurement began before browser age 150s' }
    }
    $mEnd = $mStart + $measureSeconds * $freq
    $nextStats = $mStart
    $i = 0; $lastQpc = $null; $maxGap = 0.0; $firstChildChange = $null
    while ($true) {
        $now = Get-Qpc
        if (-not $AppOnly -and $now -ge $nextStats) {
            try { $stats.Add([ordered]@{ t = Round3 (Get-Seconds $mStart $now); v = (Get-ObsStats $Ctx) }) } catch { & $invalid "GetStats failed: $($_.Exception.Message)" }
            $nextStats += $statsEverySeconds * $freq
        }
        $all = Get-AllProcesses
        $appTree = Get-AppTree $Ctx.App.Id $Ctx.Root $all
        $obsTree = if ($AppOnly) { @() } else { Get-ObsTree $Ctx.ObsProcess.Id $all }
        $newObsPid = $false
        foreach ($t in $appTree) { if (-not $appNames.ContainsKey($t.key)) { $appNames[$t.key] = $t.name; if ($null -eq $firstChildChange) { $firstChildChange = Round3 (Get-Seconds $mStart $now) } } }
        Add-ProcessRoles $roleByKey $appTree $all
        foreach ($t in $obsTree) {
            if (-not $obsNames.ContainsKey($t.key)) { $obsNames[$t.key] = $t.name; if ($null -eq $firstChildChange) { $firstChildChange = Round3 (Get-Seconds $mStart $now) } }
            if ($obsPids.Add($t.pid)) { $newObsPid = $true }
        }
        if ($newObsPid -and $gpuOk) { [void] (Update-GpuCounters $obsPids) }
        $q = Get-Qpc
        $a = Measure-Tree $appTree $appSeen; $o = Measure-Tree $obsTree $obsSeen
        foreach ($processEntry in @($appTree)+@($obsTree)) {
            [void]$Ctx.ArmTrace.ids.Add($processEntry.pid)
            $role=if ($roleByKey.ContainsKey($processEntry.key)) {$roleByKey[$processEntry.key].label} else {'owned OBS descendant'}
            $Ctx.ArmTrace.observed[$processEntry.key]=@{pid=$processEntry.pid;key=$processEntry.key;created=$processEntry.created;role=$role
                owner=$(if ($Designer -and $processEntry.key -in @($Ctx.PreviewCandidates | ForEach-Object key)) {'designer preview candidate'} else {'owned tree; preview ownership unknown/shared'})}
        }
        # StrictMode: member enumeration on an empty array (AppOnly has no OBS tree) throws, so project explicitly.
        $liveAppKeys = @($appTree | ForEach-Object { $_.key }); $liveObsKeys = @($obsTree | ForEach-Object { $_.key })
        foreach ($key in @($appNames.Keys)+@($obsNames.Keys)) {
            if ($key -notin $liveAppKeys -and $key -notin $liveObsKeys) {
                & $invalid 'descendant process exited inside measurement window'
                if ($reportedExits.Add($key)) {
                    $arm.sampledExits.Add(@{key=$key;observedUtc=[DateTime]::UtcNow.ToString('o');tSeconds=Round3 (Get-Seconds $mStart $now)})
                }
            }
        }
        $rc = Get-RoleCpu $appSeen $roleByKey
        $gpu = if ($gpuOk) { Read-GpuSum $obsPids } else { $null }
        if ($null -ne $lastQpc) { $maxGap = [Math]::Max($maxGap, (Get-Seconds $lastQpc $q)) }
        $lastQpc = $q
        $t = Round3 (Get-Seconds $mStart $q)
        $samples.Add([pscustomobject]@{ i = $i; t = $t; appCpu = $a.cpu; appPriv = $a.privateMiB; obsCpu = $o.cpu; obsPriv = $o.privateMiB; gpu = $gpu; roles = $rc })
        $prefixCsv = "$($Ctx.Workload),$($Ctx.Block),$($Ctx.Launch),$Pair,$Condition,$Attempt,$i,$t"
        $csv.Add("$prefixCsv,app,$(@($appTree).Count),$(Round3 $a.cpu),$(Round3 $a.privateMiB),")
        if (-not $AppOnly) { $csv.Add("$prefixCsv,obs,$(@($obsTree).Count),$(Round3 $o.cpu),$(Round3 $o.privateMiB),$(Round3 $gpu)") }
        $i++
        if ($q -ge $mEnd) { break }
        Wait-UntilQpc ([Math]::Min($mEnd, $mStart + $i * $freq))
    }
    $measureEndUtc=[DateTime]::UtcNow
    if (-not $AppOnly) { try { $stats.Add([ordered]@{ t = Round3 (Get-Seconds $mStart (Get-Qpc)); v = (Get-ObsStats $Ctx) }) } catch { & $invalid "GetStats failed: $($_.Exception.Message)" } }
    $wall = Get-Seconds $mStart $lastQpc

    $childChanges = {
        param($Names, $Keys0, $Last)
        $lastKeys = @($Last | ForEach-Object { $_.key })
        $added = @($Names.Keys | Where-Object { $Keys0 -notcontains $_ })
        $exited = @($Names.Keys | Where-Object { $lastKeys -notcontains $_ })
        [ordered]@{ added = $added.Count; addedKeys=$added; addedNames = @($added | ForEach-Object { $Names[$_] }); exited = $exited.Count; exitedKeys=$exited; exitedNames = @($exited | ForEach-Object { $Names[$_] }) }
    }
    $arm['measure'] = [ordered]@{ seconds = Round3 $wall; samples = $samples.Count; maxGapSeconds = Round3 $maxGap
        appProcesses = @($appTree0).Count; obsProcesses = @($obsTree0).Count; firstChildChangeAt = $firstChildChange
        appChildren = (& $childChanges $appNames $appKeys0 $appTree)
        obsChildren = if ($AppOnly) { $null } else { & $childChanges $obsNames $obsKeys0 $obsTree }
        gpuCounters = $script:gpuCounters.Count }
    if ($maxGap -gt $maxGapSeconds) { & $invalid "sample gap $(Round3 $maxGap) s > $maxGapSeconds s" }
    if (-not (Test-RootsAlive $Ctx)) { & $invalid 'Nativune or obs64 root process restarted or exited' }
    $protectedStartUtc=$Ctx.ArmTrace.startUtc
    $arm['treeExits'] = @(Stop-ObsArmTrace $Ctx.ArmTrace $measureEndUtc); $Ctx.ArmTrace=$null
    foreach ($reason in @(Get-ObsArmExitReasons $arm.treeExits)) { & $invalid $reason }
    if ($Designer) {
        Update-DesignerGpuTrace $Ctx
        $arm['gpuCollectorsInWindow']=@(Get-DesignerCollectorWindowEvents $Ctx.Record.gpuInfo.collectors $protectedStartUtc $measureEndUtc)
        foreach ($reason in @(Get-ObsArmExitReasons @($arm.gpuCollectorsInWindow | Where-Object exitInside))) { & $invalid $reason }
    }
    if (-not $AppOnly -and (-not $gpuOk -or $script:gpuCounters.Count -eq 0)) { & $invalid 'missing GPU counter' }
    $failureCountAfter=if (Test-Path $failureLog) {@(Select-String -LiteralPath $failureLog -Pattern 'process-failed').Count} else {0}
    if ($failureCountAfter -gt $failureCountBefore) { & $invalid 'ProcessFailed inside window' }

    # Post-measure validity.
    $sPost = Get-State $Ctx.Root "$($Condition.ToLowerInvariant())post"
    if ($Designer -and $script:designerCalibration) {
        $ack=Get-DesignerCalibrationAck $Ctx $(if ($Condition -eq 'A') {$script:designerCalibration} else {@{off=$true}})
        $arm['calibrationPostAck']=$ack
        if (-not $ack -or -not $arm.calibrationAck -or ($Condition -eq 'A' -and $ack.startedAtUtc -ne $arm.calibrationAck.startedAtUtc)) { & $invalid 'Calibration post-window acknowledgement missing, changed or mismatched' }
    }
    if ($Condition -eq 'A') {
        # The 5-minute stream lifetime renewal closes and reopens the stream within a few seconds; if the snapshot landed
        # in that gap, re-read every 1 s for up to 8 s. Outside the measure window. Reads are still counted only up to the
        # first post snapshot.
        $sPostWindow = $sPost
        $renewalRetry = 0.0
        if ($sPost -and (Get-Overlay $sPost 'streams') -eq 0) {
            $retryStart = Get-Qpc
            while ((Get-Seconds $retryStart (Get-Qpc)) -lt 8) {
                Start-Sleep -Seconds 1
                $again = Get-State $Ctx.Root 'apostretry'
                if ($again) { $sPost = $again }
                if ($again -and (Get-Overlay $again 'streams') -ge 1) { break }
            }
            $renewalRetry = Round3 (Get-Seconds $retryStart (Get-Qpc))
        }
        $arm['post'] = [ordered]@{ streams = Get-Overlay $sPost 'streams'; latestState = Get-Overlay $sPost 'latestState'; fixtureArtServed = Get-Overlay $sPost 'fixtureArtServed'
            renewalRetrySeconds = $renewalRetry
            overlayScriptChars = if ($sPre -and $sPostWindow) { Get-OverlayScriptChars $sPre $sPostWindow } else { $null } }
        if ($sPre -and $sPost -and $Ctx.Workload -eq 'Playing' -and (-not $Designer -or $script:designerCondition.kind -eq 'current')) {
            $age=Get-Seconds $Ctx.ReadyQpc $sPost.qpc
            $position=Get-Overlay $sPost 'latestPosition';$duration=Get-Overlay $sPost 'latestDuration'
            $progress=@{arm=$arm.id;ageSeconds=Round3 $age;position=$position;duration=$duration
                afterHiddenBoundary=$age -ge 305;afterPcmWrap=$age -ge 605
                fresh=Test-ObsFixturePosition $age $position $duration $trackSeconds $positionTolerance}
            $Ctx.Record['fixtureProgress'].Add($progress);$arm.post['fixtureProgress']=$progress
            if (-not $progress.fresh) {& $invalid 'A after measure: fixture position frozen/stale or duration mismatch'}
            $prePosition=Get-Overlay $sPre 'latestPosition'
            $preAge=Get-Seconds $Ctx.ReadyQpc $sPre.qpc
            if ($null -eq $prePosition -or $null -eq $position -or
                [Math]::Abs(([double]$position-[double]$prePosition)-($age-$preAge)) -gt $positionTolerance) {
                & $invalid 'A after measure: position did not progress with fixture epoch'
            }
        }
        # fixtureArtServed is recorded but not required: it resets to 0 when the 5-minute stream lifetime renews and
        # the page keeps its already-loaded image (checked once, at settle).
        if (-not (Test-ObsBenchA $Ctx $sPost)) { & $invalid 'A after measure: exact stream/workload/preview state not met' }
        if ($renewalRetry -gt 0 -or ((Get-Overlay $sPost 'lastStreamEndReason') -eq 'Lifetime' -and (Get-Overlay $sPre 'lastStreamEndReason') -ne 'Lifetime')) { & $invalid 'unexpected lifetime renewal' }
    } else {
        $reads = if ($sPre -and $sPost) { Get-OverlayReads $sPre $sPost } else { $null }
        $arm['post'] = [ordered]@{ streams = Get-Overlay $sPost 'streams'; overlayReadsDuringMeasure = $reads }
        if (-not (Test-ObsBenchB $sPost) -or $null -eq $reads -or $reads -ne 0) { & $invalid 'B after measure: zero streams/realStreams/demand and no overlay reads not all met' }
        if (-not $AppOnly) {
            $off=Get-ObsCertifiedOff $Ctx $sPost "$($arm.id)-post";$arm['offPost']=$off;$arm['shapePost']=$off.shape
            foreach ($reason in $off.reasons) {& $invalid $reason}
            if ($off.shape -ne $Ctx.Shape0) { & $invalid "B shape differs from shape0: $($off.shape)" }
        }
    }

    if ($samples.Count -ge 2) {
        $f = $samples[0]; $l = $samples[$samples.Count - 1]; $span = $l.t - $f.t
        $metrics = [ordered]@{}
        if (-not $AppOnly) {
            $renders = @($stats | ForEach-Object { $_.v.renderMs })
            $metrics['obs.cpuPp'] = Round3 (($l.obsCpu - $f.obsCpu) / $span * 100)
            $metrics['obs.privateMiB'] = Round3 (Get-Mean ($samples | ForEach-Object { $_.obsPriv }))
            $metrics['obs.gpuEnginePp'] = if ($gpuOk) { Round3 (Get-Mean ($samples | Select-Object -Skip 1 | ForEach-Object { $_.gpu })) } else { $null }
            $metrics['obs.renderMs'] = Round3 (Get-Mean $renders)
            $metrics['obs.skippedFrames'] = if ($stats.Count -ge 2) { $stats[$stats.Count - 1].v.skipped - $stats[0].v.skipped } else { $null }
        }
        $metrics['app.cpuPp'] = Round3 (($l.appCpu - $f.appCpu) / $span * 100)
        $metrics['app.privateMiB'] = Round3 (Get-Mean ($samples | ForEach-Object { $_.appPriv }))
        $metrics['roles'] = New-RoleMetrics $f.roles $l.roles $span $roleByKey
        $arm['metrics'] = $metrics
    } else { & $invalid 'fewer than 2 samples' }
    if ($Designer) { Add-DesignerRoleInventory $Ctx $arm $appTree0 $roleByKey }
    $arm['reasons'] = @($arm.reasons)
    $arm
}

# ---------------------------------------------------------------------------------------------------------------
# Blocks, pairs, reruns, fixture-age bound, time box

# Once-only full warm-up after every fresh launch; never scored.
function Invoke-Warmup($Ctx) {
    # Bootstrap is setup overhead, not part of the >=180 s ordinary warm-up.
    if (-not $AppOnly -and $Ctx.CefBaselinePending) {Initialize-ObsLazyAttribution $Ctx}
    $start = Get-Qpc
    $Ctx.WarmingUp=$true
    try {
    if ($Designer) {
        Start-BenchReader $Ctx
        if (-not (Wait-For {$s=Get-State $Ctx.Root 'warmopen';if (Test-ObsBenchA $Ctx $s) {$s}} 30)) {throw 'Designer warmup preview did not connect visibly.'}
        $start=Get-Qpc; Wait-UntilQpc ($start+60*$freq); Stop-BenchReader $Ctx
    } elseif ($AppOnly) {
        Start-BenchReader $Ctx
        Wait-UntilQpc ($start+60*$freq); Stop-BenchReader $Ctx
        Wait-UntilQpc ($start+180*$freq)
    } else {
        $Ctx.Record['warmupVisits']=[Collections.Generic.List[object]]::new()
        foreach ($theme in $allThemes) {
            $Ctx.ActiveTheme=$theme; Set-SourceEnabled $Ctx $true
            $visibleStart=Get-Qpc
            Wait-UntilQpc ($visibleStart+15*$freq)
            $visibleSeconds=Get-Seconds $visibleStart (Get-Qpc)
            Set-SourceEnabled $Ctx $false
            $zero=Wait-For {$s=Get-State $Ctx.Root 'warmzero';if (Test-ObsBenchB $s) {$s}} 10
            if (-not $zero) {throw 'Warmup source failed to release stream/demand.'}
            # Infrastructure is still uncertified until all ordinary visits end.
            [void](Get-ObsAttribution $Ctx "warmoff-$theme")
            $after=Get-State $Ctx.Root 'warmzeroafter'
            $reads=Get-OverlayReads $zero $after
            $Ctx.Record['warmupVisits'].Add(@{theme=$theme;visibleSeconds=Round3 $visibleSeconds
                streams=Get-Overlay $after 'streams';realStreams=Get-Overlay $after 'realStreams';demand=Get-Overlay $after 'demand'
                overlayReads=$reads;zeroStartQpc=$zero.qpc;zeroEndQpc=Get-Prop $after 'qpc'})
            if (-not (Test-ObsBenchB $after) -or $null -eq $reads -or $reads -ne 0) {throw 'Warmup off interval has demand or overlay reads.'}
        }
        $Ctx.ActiveTheme=$selectedOptions.theme; $Ctx.LookId=$Ctx.Items[$Ctx.ActiveTheme].lookId
        Wait-UntilQpc ($start+180*$freq)
        Wait-ObsOverlayTeardown $Ctx
        [void](Get-ObsAttribution $Ctx 'warm-infrastructure' -BeforeScene)
        $final=Get-State $Ctx.Root 'warmfinal'
        $finalReads=Get-OverlayReads $zero $final
        if (-not (Test-ObsBenchB $final) -or $null -eq $finalReads -or $finalReads -ne 0) {throw 'Final warmup off interval has demand or overlay reads.'}
        $off=Get-ObsCertifiedOff $Ctx $final 'warmfinal'
        $off['overlayReadsSinceLastWarmVisit']=$finalReads
        if (-not $off.certified) {throw "Warmup certified-off failed: $($off.reasons -join '; ')"}
        $Ctx.Shape0=$off.shape;$Ctx.Record['shape0']=$Ctx.Shape0;$Ctx.Record['certifiedOff0']=$off
        $Ctx.InfrastructureSlotCount=@($off.infrastructureRenderers).Count
    }
    $Ctx.Record['warmup']=@{seconds=Round3 (Get-Seconds $start (Get-Qpc));minimumSeconds=$(if ($Designer) {60} else {180});allSourcesOff=$true}
    } finally {$Ctx.WarmingUp=$false}
}
function Test-AgeFits($Ctx) {
    if ($Ctx.Workload -ne 'Playing') { return $true }
    ((Get-Seconds $Ctx.ReadyQpc (Get-Qpc)) + $armSeconds) -le ($trackSeconds - $ageMarginSeconds)
}
# Returns { pairs = valid pair records; blocked = reason or $null }.
function Invoke-Block([string] $WorkloadName, [int] $Block, [switch] $ProbeAfter, [switch] $CalibrationAfter) {
    $pairs = [Collections.Generic.List[object]]::new()
    $ctx = $null; $launchesUsed = 0
    try {
        for ($p = 1; $p -le $pairsPerBlock; $p++) {
            if ($Designer -and $Profile -eq 'Fast-v1' -and
                -not (Test-TimeFits (2*$armSeconds + 60 + $(if ($ctx) {0} else {120+$WarmupSeconds})))) {
                $script:timeBoxHit=$true
                return @{pairs=$pairs;blocked='deadline: full pair, switching and cleanup cannot fit'}
            }
            $order = $pairOrders[$p - 1]
            $pairArms = @{}
            $restart = $false
            foreach ($cond in $order) {
                $result = $null
                for ($attempt = 1; $attempt -le 2; $attempt++) {
                    if (-not (Test-TimeFits ($armSeconds + $(if ($Designer -and $Profile -eq 'Fast-v1') {60} else {0}) + $(if ($ctx) { 0 } else { 120 + $WarmupSeconds })))) { $script:timeBoxHit = $true; return @{ pairs = $pairs; blocked = 'time box reached' } }
                    if (-not $ctx) {
                        if ($launchesUsed -ge $maxLaunchesPerBlock) { return @{ pairs = $pairs; blocked = "block needed more than $maxLaunchesPerBlock fresh launches" } }
                        $ctx = Start-Launch $WorkloadName $Block; $launchesUsed++
                        Invoke-Warmup $ctx
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
            $roleDelta = [ordered]@{}
            foreach ($r in $roleNames) {
                $ra = $pairArms['A'].metrics['roles']; $rb = $pairArms['B'].metrics['roles']
                $roleDelta[$r] = if ($ra -and $rb) { Round3 ([double] $ra[$r].cpuPp - [double] $rb[$r].cpuPp) } else { $null }
            }
            $pairs.Add([ordered]@{ block = $Block; pair = $p; order = ($order -join ''); launch = $ctx.Launch; delta = $delta; roleDelta = $roleDelta
                a = $pairArms['A'].id; b = $pairArms['B'].id; look = $ctx.ActiveTheme
                overlayScriptChars = $pairArms['A'].post['overlayScriptChars'] })
        }
        if ($Designer -and $script:designerCondition.kind -eq 'current') {
            $progress=@($ctx.Record['fixtureProgress'] | Where-Object fresh)
            $proof=@{hiddenBoundary=@($progress | Where-Object afterHiddenBoundary).Count -gt 0
                pcmWrap=@($progress | Where-Object afterPcmWrap).Count -gt 0;trackSeconds=$trackSeconds}
            $ctx.Record['fixtureClockProof']=$proof
            if (-not $proof.hiddenBoundary -or -not $proof.pcmWrap) {throw 'Current fixture clock not verified after hidden 5-minute boundary and 600-second PCM wrap.'}
        }
        if ($ProbeAfter) { Invoke-DesignerPausedProbe $ctx }
        if ($CalibrationAfter) { Invoke-DesignerGrossCalibration $ctx }
        @{ pairs = $pairs; blocked = $null }
    } catch {
        $launchNo = if ($ctx) { $ctx.Launch } else { $script:launchIndex }
        Add-RunError 'launch' $WorkloadName $Block $launchNo $_
        Add-Check "G3.$WorkloadName.b$Block.l$launchNo.completed" 'launch and its arms ran without error' $_.Exception.Message $false
        @{ pairs = $pairs; blocked = "launch $launchNo error: $($_.Exception.Message)" }
    } finally { try { Stop-Launch $ctx } catch { Add-RunError 'stopLaunch' $WorkloadName $Block $(if ($ctx) { $ctx.Launch }) $_ } }
}

function Invoke-Workload([string] $WorkloadName) {
    $all = [Collections.Generic.List[object]]::new()
    $result = [ordered]@{ blocks = 0; blocked = $null; pairs = $all; metrics = [ordered]@{} }
    $workloadResults[$WorkloadName] = $result
    $verdicts = $null
    for ($block = 1; $block -le 1; $block++) {
        $b = Invoke-Block $WorkloadName $block
        $result.blocks = $block
        foreach ($x in $b.pairs) { $all.Add($x) }
        if ($b.blocked) { $result.blocked = "block $block`: $($b.blocked)"; break }
        $verdicts = [ordered]@{}
        foreach ($m in $budgets.Keys) { $verdicts[$m] = Get-Verdict @($all | ForEach-Object { $_.delta[$m] }) $budgets[$m] }
        $between = @($verdicts.Keys | Where-Object { $verdicts[$_].verdict -eq 'between' })
        if ($between.Count -eq 0) { break }
        # Any additional block needs a separate invocation and owner approval.
    }
    if ($all.Count -gt 0) { $result['roleDeltaPp'] = Get-RoleDeltaSummary $all }
    if ($all.Count -gt 0) { $result['overlayScriptChars'] = Merge-ScriptCharCounts @($all | ForEach-Object { $_.overlayScriptChars }) }
    foreach ($m in $budgets.Keys) {
        $name = "G3.$WorkloadName.$m"
        $expected = "$Pairs paired deltas A-B <= $($budgets[$m]); observed extremes, never averaged; mixed requires separately approved fresh Exhaustive-v1 block"
        if ($result.blocked) { Add-Blocked $name $expected $result.blocked; continue }
        if ($m -eq 'obs.gpuEnginePp' -and $script:gpuUnavailable) { Add-Blocked $name $expected $script:gpuUnavailable; continue }
        $v = $verdicts[$m]; $result.metrics[$m] = $v
        switch ($v.verdict) {
            'pass' { Add-Check $name $expected $v $true }
            'fail' { Add-Check $name $expected $v $false }
            'between' {
                $v['inconclusive'] = [bool]$FallbackFrom
                Add-Blocked $name $expected $(if ($FallbackFrom) {'fresh block still mixed: inconclusive, no merge'} else {"mixed: approve a fresh four-pair -Workload $WorkloadName -Look $Look -TimeBoxMinutes 30 command"})
            }
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
    Assert-DesignerDeadline
    if (-not ($Designer -and $Profile -eq 'Fast-v1')) { $ownerBefore = Get-OwnerObsProfileSnapshot }
    if ($Designer -and $Profile -eq 'Exhaustive-v1') {$script:designerRunStart=Get-Qpc}
    if ($AttributionOnly) {
        $ctx=$null
        try {
            $ctx=Start-Launch 'Playing' 1;Invoke-Warmup $ctx
            Add-Check 'OBS.attributionOnly' 'all 8 look renderer mappings exit; certified off; unknown BLOCKS' $ctx.Record['certifiedOff0'] $true
        } catch {
            Add-RunError 'attribution' 'Playing' 1 $script:launchIndex $_
            if ($_.Exception.Message -match 'off retention:|off state:') {
                Add-Check 'OBS.attributionOnly' 'certified zero overlay demand/ownership' $_.Exception.Message $false
            } else {
                Add-Blocked 'OBS.attributionOnly' 'complete owned CDP attribution; unknown BLOCKS' $_.Exception.Message
            }
        } finally {Stop-Launch $ctx}
    } else {
    foreach ($w in $Workload) {
        if ($script:timeBoxHit) {
            foreach ($m in $budgets.Keys) { Add-Blocked "G3.$w.$m" "paired delta A-B <= $($budgets[$m])" 'time box reached before this workload' }
            continue
        }
        try { if ($Designer) {Invoke-DesignerBench} elseif ($Protocol -eq 'SharedBaseline') {Invoke-SharedBench} else {Invoke-Workload $w} } catch {
            Add-RunError 'workload' $w $null $null $_
            Add-Check "G3.$w.runner.completed" 'workload ran to completion' $_.Exception.Message $false
            try { Stop-Launch $script:currentCtx } catch { }
            foreach ($m in $budgets.Keys) { if (-not ($checks | Where-Object { $_.name -eq "G3.$w.$m" })) { Add-Blocked "G3.$w.$m" "paired delta A-B <= $($budgets[$m])" 'workload aborted' } }
        }
    }
    }
} catch {
    Add-RunError 'harness' $null $null $null $_
    Add-Check 'G3.runner.completed' 'harness setup succeeded' $_.Exception.Message $false
} finally {
    try { Stop-Launch $script:currentCtx } catch { Add-RunError 'cleanup.stopLaunch' $null $null $null $_ }
    try { Clear-GpuCounters } catch { Add-RunError 'cleanup.gpu' $null $null $null $_ }
    try {
        foreach ($key in @($testEnv.Keys) + $benchEnvKeys) { Set-ProcessEnv $key $null }
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine)) {
            if ($p.CommandLine -and $p.CommandLine.Contains($rootBase, [StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        }
    } catch { Add-RunError 'cleanup.processes' $null $null $null $_ }
    if ($ownerBefore) {
        try {
            # Returns one object[] of ordered dicts (written with the unary comma), so do not wrap in @().
            [object[]] $diff = Compare-OwnerObsProfileSnapshot $ownerBefore (Get-OwnerObsProfileSnapshot)
            if ($null -eq $diff) { $diff = @() }
            $diffPaths = @($diff | Select-Object -First 20 | ForEach-Object { "$($_['change']): $($_['path'])" })
            Add-Check 'G3.ownerObsProfileUnchanged' 'owner %APPDATA%/%LOCALAPPDATA% obs-studio identical before/after' ([ordered]@{ changed = $diff.Count; paths = $diffPaths }) ($diff.Count -eq 0)
        } catch {
            Add-RunError 'ownerProfileCompare' $null $null $null $_
            Add-Blocked 'G3.ownerObsProfileUnchanged' 'owner %APPDATA%/%LOCALAPPDATA% obs-studio identical before/after' "comparison failed: $($_.Exception.Message)"
        }
    }
    try {
        if (-not $KeepRoot -and (Test-Path -LiteralPath $rootBase)) {
            Start-Sleep -Seconds 1
            Remove-Item -LiteralPath $rootBase -Recurse -Force -ErrorAction SilentlyContinue
        }
    } catch { Add-RunError 'cleanup.root' $null $null $null $_ }
}

if ($Designer -and (Get-Variable designerRunStart -Scope Script -ErrorAction SilentlyContinue)) { $script:obsUsedSeconds = Get-Seconds $script:designerRunStart (Get-Qpc) }
if ($script:timeBoxHit) { Add-Blocked 'G3.timeBox' "all blocks within $TimeBoxMinutes min $(if ($Designer -and $Profile -eq 'Fast-v1') {'from invocation'} else {'of OBS on screen'})" "stopped at $(Round3 ($script:obsUsedSeconds / 60)) min; unfinished rows BLOCKED" }
$failed = @($checks | Where-Object { $_.status -eq 'fail' })
$blocked = @($checks | Where-Object { $_.status -eq 'blocked' })
$passed = $checks.Count -gt 0 -and $failed.Count -eq 0 -and $blocked.Count -eq 0
$profileComplete = $checks.Count -gt 0 -and $blocked.Count -eq 0 -and $errors.Count -eq 0
if ($AttributionOnly) {$profileComplete=$false}
if ($Designer -and $Profile -eq 'Fast-v1') {
    $profileComplete = $profileComplete -and $script:designerProfileRows.Count -eq 7 -and
        @($script:designerProfileRows.Values | Where-Object { $_.status -eq 'blocked' }).Count -eq 0
}
$report = [ordered]@{
    version = 1; profile = $Profile; profileVersion = 1; profileComplete = [bool]$profileComplete
    exhaustiveComplete = [bool]($Profile -eq 'Exhaustive-v1' -and $profileComplete)
    admission = $admission
    qualificationComplete = [bool](-not $AttributionOnly -and $Profile -eq 'Exhaustive-v1' -and $passed -and $admission -ne 'provisional-composed')
    invocationUtc = $invocationUtc.ToString('o'); invocationElapsedMinutes = Round3 ((Get-Seconds $invocationQpc (Get-Qpc))/60)
    deadlineUtc = $(if ($Designer -and $Profile -eq 'Fast-v1') {$invocationUtc.AddMinutes(60).ToString('o')} else {$null})
    framesEvidence = $framesEvidence
    provenance = $(if ($framesEvidence) {Get-Prop $framesEvidence 'provenance'} else {$null})
    payloadIdentityVerification = $(if ($admission -eq 'provisional-composed') {'attested assertion; source manifests/historical harness bytes not independently verified by this reader'} else {'not composed'})
    qualification = $(if ($AttributionOnly) {'warm-up attribution only; no resource qualification'} elseif ($Profile -eq 'Fast-v1') {'diagnostic only; exhaustive qualification deferred'} else {'exhaustive profile'})
    designerRows = $script:designerProfileRows
    deferred = $(if ($Designer -and $Profile -eq 'Fast-v1') {@(
        @{kind='resource';id='sample-paused-lyrics-False';status='deferred';to='Exhaustive-v1'},
        @{kind='resource';id='sample-paused-lyrics-True';status='deferred';to='Exhaustive-v1'},
        @{kind='resource';id='sample-playing-lyrics-True';status='deferred';to='Exhaustive-v1'},
        @{kind='resource';id='current-default-lyrics-True';status='deferred';to='Exhaustive-v1'})} else {@()})
    command = $commandLine; runId = $runId; appVersion = $(if (Get-Variable appVersion -ErrorAction SilentlyContinue) { $appVersion }); pipePrefix = $prefix
    harnessElevated = $isElevated; budgets = $budgets; timeBoxMinutes = $TimeBoxMinutes; obsOnScreenMinutes = Round3 ($script:obsUsedSeconds / 60)
    appOnly = [bool] $AppOnly; pairsPerBlock = $pairsPerBlock; warmupSeconds = $WarmupSeconds; warmupASeconds = $WarmupASeconds; readProbe = $ReadProbe
    mode = $Protocol; designer = [bool]$Designer; seed = $Seed; schedule = $schedule; options = $selectedOptions
    attributionOnly=[bool]$AttributionOnly
    framesFrom = $FramesFrom; worstFrom = $WorstFrom; stillsReport = $StillsReport; fallbackFrom = $FallbackFrom
    pausedExtensions = $(if (Get-Variable gate -ErrorAction SilentlyContinue) { @($gate.pausedExtensions) } else { @() })
    protocol = [ordered]@{ settleSeconds = $settleSeconds; measureSeconds = $measureSeconds; sampleSeconds = 1; statsEverySeconds = $statsEverySeconds
        trackSeconds = $trackSeconds; ageLimitSeconds = $trackSeconds - $ageMarginSeconds; positionToleranceSeconds = $positionTolerance
        maxGapSeconds = $maxGapSeconds; pairOrders = @($pairOrders | ForEach-Object { $_ -join '' }); gpuMetric = 'engine-percent sum (not Task Manager %)' }
    launches = @($launches); arms = @($arms); workloads = $workloadResults; errors = @($errors)
    summary = [ordered]@{ pass = @($checks | Where-Object { $_.status -eq 'pass' }).Count; fail = $failed.Count; blocked = $blocked.Count }
    checks = @($checks); passed = [bool] $passed
}
[IO.File]::WriteAllText((Join-Path $runDirectory 'bench-report.json'), ($report | ConvertTo-Json -Depth 32), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllLines((Join-Path $runDirectory 'perf.csv'), $csv, [Text.UTF8Encoding]::new($false))
$report.summary | ConvertTo-Json
Write-Host "Report: $(Join-Path $runDirectory 'bench-report.json')"
if (-not $passed) { exit 1 }
