<#
Native E2E for opt-in Discord Rich Presence. It drives the actual app (WebHostWindow, settings, the
normal page snapshot reader, scheduler and IPC module) against a fake Discord IPC server; no real
Discord client, account, discord-ipc-N pipe, YouTube or Google request is involved.

  pwsh -NoProfile -File scripts/discord-rpc-e2e.ps1 -Scenario All -OutputDirectory artifacts/discord-rpc

Steps: publish a hook build (-p:DiscordPresenceTestHooks=true) to artifacts/discord-rpc/app (never
ship it), create artifacts/discord-rpc/<utc>-<guid>/ and a fresh root .cache/discord-rpc-e2e/<run-id>/
with data/settings.json v7, pick a random pipe prefix nativune-test-<32 hex>-discord-ipc-, start
scripts/discord-rpc-test-server.ps1 on <prefix>0 and run `Nativune.exe web --root <root>` with
NATIVUNE_TEST_DISCORD_* variables. The owner's data/ and installed profile are never touched. With no
repository WebView2 runtime copied into the fresh root the app uses the registered Evergreen runtime;
-CopyWebView2Runtime copies .tools/webview2 (about 800 MB) into the root instead.

Fixture page timeline (src/Nativune/DiscordFixturePage.html), seconds after page load:
  0 track A playing (Fixture Song A / Fixture Artist / Fixture Album, 210 s); 25 seek to 100 s;
  45 pause; 60 resume; 80 track B (Fixture Song B / Second Artist / Second Album, 185 s);
  100 repeat-one on; 120 stop (ended).

Failure modes caught:
- presence off by default is ignored, or Disable still opens IPC connections;
- wrong or missing handshake client_id / version, SET_ACTIVITY before READY;
- wrong activity type (not Listening = 2), missing/incorrect title, artist, album tooltip or artwork;
- progress bar missing while playing, wrong length, not re-anchored after a seek;
- timestamps kept while paused, missing pause badge, no republish on resume;
- stale track A content after the track change, missing repeat-one badge;
- ended playback or app exit not clearing the activity;
- wrong pid, unproven details_url/buttons, per-tick write spam (below the test min-write interval);
- crash or per-attempt log spam when Discord is absent.
#>
[CmdletBinding()]
param(
    [ValidateSet('All', 'Timeline', 'Absent', 'Disable')] [string] $Scenario = 'All',
    [string] $OutputDirectory = 'artifacts/discord-rpc',
    [switch] $SkipPublish,
    [switch] $CopyWebView2Runtime,
    [switch] $KeepRoot,
    [int] $TimelineSeconds = 140
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$commandLine = 'pwsh -NoProfile -File scripts/discord-rpc-e2e.ps1 ' + (($PSBoundParameters.GetEnumerator() | ForEach-Object {
    if ($_.Value -is [switch]) { if ($_.Value) { "-$($_.Key)" } } else { "-$($_.Key) $($_.Value)" } }) -join ' ')
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
$appDirectory = Join-Path $repo 'artifacts/discord-rpc/app'
$appExe = Join-Path $appDirectory 'Nativune.exe'
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N')
$runDirectory = Join-Path $outputRoot $runId
$rootBase = Join-Path $repo ".cache/discord-rpc-e2e/$runId"
$prefix = 'nativune-test-' + [guid]::NewGuid().ToString('N') + '-discord-ipc-'
$clientId = '100000000000000001'
$minWriteSeconds = 3
$testEnv = [ordered]@{
    NATIVUNE_TEST_DISCORD_PIPE_PREFIX = $prefix
    NATIVUNE_TEST_DISCORD_CLIENT_ID = $clientId
    NATIVUNE_TEST_DISCORD_PAUSE_SECONDS = '20'
    NATIVUNE_TEST_DISCORD_MIN_WRITE_SECONDS = "$minWriteSeconds"
    NATIVUNE_TEST_DISCORD_FIXTURE_PAGE = '1'
}
$checks = [ordered]@{}
$scenarioResults = [ordered]@{}
$framesByScenario = [ordered]@{}
$started = [Collections.Generic.List[Diagnostics.Process]]::new()

function Add-Check([string] $Name, [bool] $Passed) { $checks[$Name] = $Passed }

function Write-Settings([string] $Root, [bool] $Enabled) {
    $data = Join-Path $Root 'data'
    [IO.Directory]::CreateDirectory($data) | Out-Null
    # ShellSettings defaults (src/Nativune/ShellSettings.cs); automatic update checks and background
    # sleep are off so the fixture run makes no update request and keeps reading while unfocused.
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
    [IO.Directory]::CreateDirectory($root) | Out-Null
    if ($CopyWebView2Runtime) {
        $source = Join-Path $repo '.tools/webview2'
        $version = (Get-Content -LiteralPath (Join-Path $source 'runtime-path.txt') -Raw).Trim()
        $destination = Join-Path $root '.tools/webview2'
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        Copy-Item -LiteralPath (Join-Path $source $version) -Destination $destination -Recurse
        Copy-Item -LiteralPath (Join-Path $source 'runtime-path.txt') -Destination $destination
    }
    $root
}

function Start-FakeServer([string] $Name, [string] $Mode = 'Normal') {
    $frames = Join-Path $runDirectory "frames-$Name.jsonl"
    $stop = Join-Path $runDirectory "stop-$Name"
    $arguments = @('-NoProfile', '-File', (Join-Path $repo 'scripts/discord-rpc-test-server.ps1'),
        '-PipeName', ($prefix + '0'), '-FramesPath', $frames, '-StopFile', $stop, '-Mode', $Mode)
    $process = Start-Process -FilePath pwsh -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $started.Add($process)
    Start-Sleep -Seconds 2
    [pscustomobject]@{ Process = $process; Frames = $frames; Stop = $stop }
}

function Stop-FakeServer($Server) {
    if (-not $Server) { return }
    [IO.File]::WriteAllText($Server.Stop, 'stop')
    if (-not $Server.Process.WaitForExit(5000)) { Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue }
}

function Read-Frames($Server) {
    if (-not $Server -or -not (Test-Path -LiteralPath $Server.Frames)) { return @() }
    @(Get-Content -LiteralPath $Server.Frames | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 32 })
}

function Get-ProcessTree([int] $RootId, [string] $Root) {
    $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine)
    $ids = [Collections.Generic.HashSet[int]]::new(); [void] $ids.Add($RootId)
    do {
        $added = $false
        foreach ($p in $all) { if ($ids.Contains([int] $p.ParentProcessId) -and $ids.Add([int] $p.ProcessId)) { $added = $true } }
    } while ($added)
    foreach ($p in $all) {
        if ($p.Name -eq 'msedgewebview2.exe' -and $p.CommandLine -and $p.CommandLine.Contains($Root, [StringComparison]::OrdinalIgnoreCase)) { [void] $ids.Add([int] $p.ProcessId) }
    }
    @($ids)
}

function Start-App([string] $Root) {
    foreach ($entry in $testEnv.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
    $process = Start-Process -FilePath $appExe -ArgumentList @('web', '--root', $Root) -WorkingDirectory $appDirectory -PassThru
    $started.Add($process)
    $process
}

function Stop-App([Diagnostics.Process] $Process, [string] $Root) {
    if (-not $Process) { return $null }
    $closeUtc = [DateTime]::UtcNow
    if (-not $Process.HasExited) {
        [void] $Process.CloseMainWindow()
        # The window may only hide to the tray; give the app time to send its exit clear first.
        if (-not $Process.WaitForExit(8000)) {
            foreach ($id in (Get-ProcessTree $Process.Id $Root)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine)) {
        if ($p.CommandLine -and $p.CommandLine.Contains($Root, [StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    $closeUtc
}

function Get-Prop($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}

function ConvertTo-UtcTime($Value) {
    # PowerShell 7 ConvertFrom-Json already turns ISO 8601 strings into DateTime values.
    if ($Value -isnot [datetime]) { $Value = [DateTime]::Parse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
    $Value.ToUniversalTime()
}

function Get-Activities($Frames) {
    $list = @()
    foreach ($frame in $Frames) {
        if ($frame.direction -ne 'in' -or $frame.opcode -ne 1) { continue }
        $message = try { $frame.json | ConvertFrom-Json -Depth 32 } catch { $null }
        if ((Get-Prop $message 'cmd') -ne 'SET_ACTIVITY') { continue }
        $arguments = Get-Prop $message 'args'
        $list += [pscustomobject]@{ Utc = ConvertTo-UtcTime $frame.utc; Mono = [double] $frame.monoMs
            Pid = Get-Prop $arguments 'pid'; Activity = Get-Prop $arguments 'activity' }
    }
    $list
}

function Test-Timeline {
    $root = New-Root 'timeline'
    Write-Settings $root $true
    $server = Start-FakeServer 'timeline'
    $app = $null; $closeUtc = $null
    try {
        $app = Start-App $root
        Start-Sleep -Seconds $TimelineSeconds
        $alive = -not $app.HasExited
        $closeUtc = Stop-App $app $root
        Start-Sleep -Seconds 2
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['Timeline'] = $frames
    Copy-AppLog $root 'timeline'

    $handshake = $frames | Where-Object { $_.direction -eq 'in' -and $_.opcode -eq 0 } | Select-Object -First 1
    $hs = if ($handshake) { $handshake.json | ConvertFrom-Json } else { $null }
    Add-Check 'timeline.appAliveUntilClose' $alive
    Add-Check 'timeline.handshakeClientId' ([bool] $hs -and "$(Get-Prop $hs 'client_id')" -eq $clientId -and (Get-Prop $hs 'v') -eq 1)
    $readyIndex = [Array]::FindIndex([object[]] $frames, [Predicate[object]] { param($f) $f.direction -eq 'out' -and $f.json -like '*"READY"*' })
    $firstSetIndex = [Array]::FindIndex([object[]] $frames, [Predicate[object]] { param($f) $f.direction -eq 'in' -and $f.opcode -eq 1 -and $f.json -like '*SET_ACTIVITY*' })
    Add-Check 'timeline.readyBeforeFirstSet' ($readyIndex -ge 0 -and $firstSetIndex -gt $readyIndex)

    $sets = @(Get-Activities $frames)
    $nonNull = @($sets | Where-Object { $null -ne $_.Activity })
    $ts = { param($a) Get-Prop $a 'timestamps' }
    $assets = { param($a) Get-Prop $a 'assets' }
    $isA = { param($s) (Get-Prop $s.Activity 'details') -eq 'Fixture Song A' }
    $isB = { param($s) (Get-Prop $s.Activity 'details') -eq 'Fixture Song B' }
    $a = @($nonNull | Where-Object { & $isA $_ }); $b = @($nonNull | Where-Object { & $isB $_ })

    Add-Check 'timeline.activitySent' ($nonNull.Count -gt 0)
    Add-Check 'timeline.typeListening' ($nonNull.Count -gt 0 -and -not ($nonNull | Where-Object { (Get-Prop $_.Activity 'type') -ne 2 }))
    Add-Check 'timeline.pidIsApp' ($sets.Count -gt 0 -and -not ($sets | Where-Object { [int] $_.Pid -ne $app.Id }))
    Add-Check 'timeline.trackAFields' ($a.Count -gt 0 -and -not ($a | Where-Object {
        (Get-Prop $_.Activity 'state') -ne 'Fixture Artist' -or (Get-Prop (& $assets $_.Activity) 'large_text') -ne 'Fixture Album' }))
    Add-Check 'timeline.trackAArtwork' ($a.Count -gt 0 -and (Get-Prop (& $assets $a[0].Activity) 'large_image') -eq 'https://lh3.googleusercontent.com/fixture-a=w544-h544')

    $aPlaying = @($a | Where-Object { $null -ne (& $ts $_.Activity) })
    $spans = @($aPlaying | ForEach-Object { [double] (Get-Prop (& $ts $_.Activity) 'end') - [double] (Get-Prop (& $ts $_.Activity) 'start') })
    Add-Check 'timeline.timestampsWhilePlaying' ($aPlaying.Count -gt 0)
    Add-Check 'timeline.durationSpan210s' ($spans.Count -gt 0 -and -not ($spans | Where-Object { [Math]::Abs($_ - 210) -gt 2 }))
    $starts = @($aPlaying | ForEach-Object { [double] (Get-Prop (& $ts $_.Activity) 'start') })
    $seekShift = $false
    for ($i = 1; $i -lt $starts.Count; $i++) { if ([Math]::Abs(($starts[$i] - $starts[0]) + 100) -le 5) { $seekShift = $true } }
    Add-Check 'timeline.seekReanchors' $seekShift

    $pauseIndex = [Array]::FindIndex([object[]] $sets, [Predicate[object]] { param($s) $null -ne $s.Activity -and (& $isA $s) -and (Get-Prop (& $assets $s.Activity) 'small_image') -eq 'pause' })
    Add-Check 'timeline.pauseBadge' ($pauseIndex -ge 0)
    Add-Check 'timeline.pauseNoTimestamps' ($pauseIndex -ge 0 -and $null -eq (& $ts $sets[$pauseIndex].Activity))
    $resumed = $pauseIndex -ge 0 -and [bool] ($sets | Select-Object -Skip ($pauseIndex + 1) | Where-Object {
        $null -ne $_.Activity -and (& $isA $_) -and $null -ne (& $ts $_.Activity) })
    Add-Check 'timeline.resumeTimestamps' $resumed

    Add-Check 'timeline.trackBFields' ($b.Count -gt 0 -and -not ($b | Where-Object {
        (Get-Prop $_.Activity 'state') -ne 'Second Artist' -or (Get-Prop (& $assets $_.Activity) 'large_text') -ne 'Second Album'
        -or (Get-Prop (& $assets $_.Activity) 'large_image') -ne 'https://lh3.googleusercontent.com/fixture-b=w544-h544' }))
    $firstB = [Array]::FindIndex([object[]] $sets, [Predicate[object]] { param($s) $null -ne $s.Activity -and (& $isB $s) })
    Add-Check 'timeline.noStaleTrackAAfterB' ($firstB -ge 0 -and -not ($sets | Select-Object -Skip $firstB | Where-Object { $null -ne $_.Activity -and (& $isA $_) }))
    $repeatIndex = [Array]::FindIndex([object[]] $sets, [Predicate[object]] { param($s) $null -ne $s.Activity -and (& $isB $s) -and (Get-Prop (& $assets $s.Activity) 'small_image') -eq 'repeat-one' })
    Add-Check 'timeline.repeatOneBadge' ($repeatIndex -ge 0)
    $endedClear = $repeatIndex -ge 0 -and [bool] ($sets | Select-Object -Skip ($repeatIndex + 1) | Where-Object {
        $null -eq $_.Activity -and $closeUtc -and $_.Utc -lt $closeUtc.AddSeconds(-1) })
    Add-Check 'timeline.endedClears' $endedClear
    Add-Check 'timeline.finalClear' ($sets.Count -gt 0 -and $null -eq $sets[-1].Activity)

    $allowedTrackUrls = @('https://music.youtube.com/watch?v=fixtureSngA', 'https://music.youtube.com/watch?v=fixtureSngB')
    $detailsUrls = @($nonNull | ForEach-Object { Get-Prop $_.Activity 'details_url' } | Where-Object { $_ } | Select-Object -Unique)
    $buttons = @($nonNull | ForEach-Object { Get-Prop $_.Activity 'buttons' } | Where-Object { $_ })
    $buttonUrls = @($buttons | ForEach-Object { $_ } | ForEach-Object { Get-Prop $_ 'url' })
    Add-Check 'timeline.linksOnlyProvenTrack' (-not ($detailsUrls + $buttonUrls | Where-Object { $_ -notin $allowedTrackUrls }))
    Add-Check 'timeline.atMostOneButton' (-not ($nonNull | Where-Object { @(Get-Prop $_.Activity 'buttons').Where({ $_ }).Count -gt 1 }))

    $minGapSeconds = [double]::PositiveInfinity
    for ($i = 1; $i -lt $nonNull.Count; $i++) { $minGapSeconds = [Math]::Min($minGapSeconds, ($nonNull[$i].Mono - $nonNull[$i - 1].Mono) / 1000) }
    Add-Check 'timeline.writeRate' ($minGapSeconds -ge ($minWriteSeconds - 0.5))

    $scenarioResults['Timeline'] = [ordered]@{
        appPid = $app.Id; connections = @($frames | Where-Object { $_.json -eq 'connected' }).Count
        setActivityCount = $sets.Count; nonNullCount = $nonNull.Count; clearCount = $sets.Count - $nonNull.Count
        minNonNullGapSeconds = if ([double]::IsInfinity($minGapSeconds)) { $null } else { [Math]::Round($minGapSeconds, 3) }
        observedDetailsUrls = $detailsUrls; observedButtonCount = $buttons.Count
        timestampUnitAssumption = 'unix seconds (contract ToDiscordWireTimestamp; real-client check pending)'
    }
    $root
}

function Copy-AppLog([string] $Root, [string] $Name) {
    $log = Join-Path $Root 'data/nativune.log'
    if (Test-Path -LiteralPath $log) { Copy-Item -LiteralPath $log -Destination (Join-Path $runDirectory "nativune-$Name.log") }
}

function Get-DiscordLogLines([string] $Root) {
    $log = Join-Path $Root 'data/nativune.log'
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    @(Get-Content -LiteralPath $log | Where-Object { $_ -match '\bdiscord\b' })
}

function Test-Absent {
    $root = New-Root 'absent'
    Write-Settings $root $true
    $app = Start-App $root
    Start-Sleep -Seconds 30
    $alive = -not $app.HasExited
    [void] (Stop-App $app $root)
    $lines = Get-DiscordLogLines $root
    Copy-AppLog $root 'absent'
    Add-Check 'absent.noCrash' $alive
    # Backoff immediate, 2, 5, 10 s gives about four attempts in 30 s; one line per attempt is spam.
    Add-Check 'absent.noPerAttemptLogSpam' ($lines.Count -le 3)
    Add-Check 'absent.noErrorLines' (-not ($lines | Where-Object { $_ -match '\berror\b' -and $_ -match 'Exception' }))
    $scenarioResults['Absent'] = [ordered]@{ appPid = $app.Id; seconds = 30; discordLogLines = $lines.Count }
}

function Test-Disable([string] $ExistingRoot) {
    # Restart with the setting turned off, reusing the Timeline profile when it exists.
    $root = if ($ExistingRoot) { $ExistingRoot } else { New-Root 'disable' }
    Write-Settings $root $false
    $server = Start-FakeServer 'disable'
    $app = $null
    try {
        $app = Start-App $root
        Start-Sleep -Seconds 30
        $alive = -not $app.HasExited
        [void] (Stop-App $app $root)
        Start-Sleep -Seconds 1
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['Disable'] = $frames
    Copy-AppLog $root 'disable'
    $connections = @($frames | Where-Object { $_.json -eq 'connected' }).Count
    Add-Check 'disable.appAlive' $alive
    Add-Check 'disable.zeroConnections' ($connections -eq 0)
    $scenarioResults['Disable'] = [ordered]@{ appPid = $app.Id; seconds = 30; connections = $connections; reusedTimelineRoot = [bool] $ExistingRoot }
}

[IO.Directory]::CreateDirectory($runDirectory) | Out-Null
$appVersion = $null
try {
    if (-not $SkipPublish) {
        & pwsh -NoProfile -File (Join-Path $repo 'scripts/dotnet.ps1') publish (Join-Path $repo 'src/Nativune/Nativune.csproj') `
            -c Release -p:DiscordPresenceTestHooks=true -o $appDirectory
        if ($LASTEXITCODE -ne 0) { throw "Hook build publish failed with exit code $LASTEXITCODE." }
    }
    if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) { throw "Hook build not found at $appExe; run without -SkipPublish." }
    $appVersion = (Get-Item -LiteralPath $appExe).VersionInfo.ProductVersion

    $timelineRoot = $null
    if ($Scenario -in 'All', 'Timeline') { $timelineRoot = Test-Timeline }
    if ($Scenario -in 'All', 'Absent') { Test-Absent }
    if ($Scenario -in 'All', 'Disable') { Test-Disable $timelineRoot }
} catch {
    Add-Check 'runner.completed' $false
    $scenarioResults['error'] = $_.Exception.Message
} finally {
    foreach ($key in $testEnv.Keys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
    foreach ($process in $started) {
        try { if (-not $process.HasExited) { foreach ($id in (Get-ProcessTree $process.Id $rootBase)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } } } catch { }
    }
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine)) {
        if ($p.CommandLine -and $p.CommandLine.Contains($rootBase, [StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    if (-not $KeepRoot -and (Test-Path -LiteralPath $rootBase)) {
        Start-Sleep -Seconds 1
        Remove-Item -LiteralPath $rootBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$passed = $checks.Count -gt 0 -and -not ($checks.Values | Where-Object { -not $_ })
$report = [ordered]@{
    command = $commandLine; runId = $runId; appVersion = $appVersion; pipePrefix = $prefix
    scenarios = $scenarioResults; checks = $checks; passed = [bool] $passed
}
[IO.File]::WriteAllText((Join-Path $runDirectory 'report.json'), ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $runDirectory 'frames.json'), ($framesByScenario | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 8
Write-Host "Report: $(Join-Path $runDirectory 'report.json')"
if (-not $passed) { exit 1 }
