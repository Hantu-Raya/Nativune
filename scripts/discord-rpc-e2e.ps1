<#
Native E2E for opt-in Discord Rich Presence. It drives the actual app (WebHostWindow, settings, the
normal page snapshot reader, scheduler and IPC module) against a fake Discord IPC server; no real
Discord client, account, discord-ipc-N pipe, YouTube or Google request is involved.

  pwsh -NoProfile -File scripts/discord-rpc-e2e.ps1 -Scenario All -OutputDirectory artifacts/discord-rpc
  pwsh -NoProfile -File scripts/discord-rpc-e2e.ps1 -Scenario All -Parallel 1 -OutputDirectory artifacts/discord-rpc   # serial

-Scenario takes one name, All, or a comma-separated list (Timeline,Disable). -Parallel N (default 4) publishes the
hook build once, then runs scenario groups as child processes of this script, at most N at a time, longest
first. Each child has its own pipe prefix, fake server and roots, so groups cannot see each other's pipes.
Timeline and Disable stay in one group (Disable reuses the Timeline root). The parent merges every child's
checks, scenario results and frames into one report.json/frames.json and records per-group wall time.

Steps: publish a hook build (-p:DiscordPresenceTestHooks=true) to artifacts/discord-rpc/app (never
ship it), create artifacts/discord-rpc/<utc>-<guid>/ and a fresh root .cache/discord-rpc-e2e/<run-id>/
with data/settings.json v7, pick a random pipe prefix nativune-test-<32 hex>-discord-ipc-, start
scripts/discord-rpc-test-server.ps1 on <prefix>0 and run `Nativune.exe web --root <root>` with
NATIVUNE_TEST_DISCORD_* variables. The owner's data/ and installed profile are never touched. With no
repository WebView2 runtime copied into the fresh root the app uses the registered Evergreen runtime;
-CopyWebView2Runtime copies .tools/webview2 (about 800 MB) into the root instead.

Fixture page timeline (src/Nativune/DiscordFixturePage.html), seconds after page load:
  0 track A playing (Fixture Song A / Fixture Artist, 210 s); 25 seek to 100 s; 45 pause; 60 resume;
  65-75 synthetic ad window; 80 track B (Fixture Song B / Second Artist, 185 s, SAME artwork URL as track A);
  100 repeat-one on (stays on); 120 stop (ended); 125 track C (Fixture Song C / Third Artist, 240 s) with
  unloadable artwork (card must use the 'nativune' fallback); 137 artwork loads; 147-162 title link unproven
  (147 mismatched link text, 152 invalid candidate href, 157 link removed) while the route still names the
  song; 162 link restored; 172 pause with repeat-one on; 182 resume; 192 stop (ended). Every byline carries a
  unique album canary (AlbumCanaryQ7a/b/c, browse/MPREb_albumCanaryQ7*) that must never leave the app.

Failure modes caught:
- presence off by default is ignored, or Disable still opens IPC connections;
- wrong or missing handshake client_id / version, SET_ACTIVITY before READY;
- wrong activity type (not Listening = 2), missing/incorrect title, artist or artwork; cover hover text not
  "Nativune <version> · by Hantu-Raya" or cover link not the Nativune repository on any card (fallback too);
  shared album art between consecutive tracks suppressed for the whole second track; missing-art fallback
  never published or never recovered; album name/URL leaked into any outbound field;
- progress bar missing while playing, wrong length, not re-anchored after a seek;
- timestamps kept while paused, missing or wrongly worded pause/repeat badge, repeat-one winning over pause,
  any small_url, no republish on resume;
- stale track A content after the track change;
- ended playback or app exit not clearing the activity;
- wrong pid, unproven details_url/buttons (ad window, unproven title link), song links not returning together,
  per-tick write spam (below the test min-write interval);
- saved Open-button preference off still sending a button, or dropping the proven title link (ButtonOff);
- crash or per-attempt log spam when Discord is absent;
- after Discord drops and comes back (Reconnect), a cached pre-disconnect card republished on the new connection.

Additional scenarios (hook command files under <root>/data/discord-bench, honoured only by the hook build
with the fixture page and a valid test pipe prefix; see src/Nativune/WebHost.DiscordFixture.cs):
- ProductionGate: MIN_WRITE override unset (production 15 s). Runs the default timeline through seek, pause,
  resume, track change and the page-120 s ended stop. Every consecutive pair of non-null SET_ACTIVITY frames
  must be >= 14.5 s apart, and the ended clear must land within 5 s of the ended moment (page time estimated
  from the first card, +2 s estimate tolerance): clears are never held back by the write gate.
- PauseExpiry: PAUSE override 20 s, bench profile Paused (steady paused track A). One clear ~20 s after the
  first paused card (15-25 s window), no republish while still paused. Then Discord drops and comes back while
  still paused, and then a simulated system suspend/resume (command-power-suspend/-resume): neither may
  republish the expired paused card (the pause deadline survives both). Then command-resume (page
  media.play()) must bring a fresh playing card with timestamps.
- ArtGap: bench profile ArtGap. Track A plays with loaded art, its art becomes unloadable (the reader reports
  no art) at page 12 s, and track B starts at 24 s with track A's art URL. B's first card must use the
  'nativune' fallback (a transient missing-art sample must not erase A's art from the stale-art guard); B's
  shared art may appear only >= 3 s later. At 40 s B's art becomes a loadable URL longer than 256 characters:
  no large_image may exceed 256 characters, and the card falls back to 'nativune'.
- RejectedReplace: profile ArtGap, fake server -Mode ErrorOnFirstReplacement. Track A's card is accepted, then its
  missing-art replacement (page 12 s) is rejected, so Discord may still show the previous card: the app must send
  one clear within 3 s, must not resend the rejected payload, and must publish track B's card when it starts.
- RejectedClear: PAUSE override 20 s, profile Paused, fake server -Mode ErrorOnFirstClear. The pause-expiry
  clear is answered with ERROR, so Discord may still show the card: the app must drop the connection (Discord
  removes a closed client's activity), reconnect, and publish no card while still paused and expired.
- ReaderGap: PAUSE override 20 s, profile ReaderGap. While a song stays paused, the reader returns no coherent
  player long enough for the 8 s hold to clear the card; the same paused song returns after its original 20 s
  deadline. The card must stay cleared (read gaps must not restart the pause deadline).
- SameTitle: PAUSE override 20 s, profile SameTitle. A paused song is replaced at page 12 s by a different
  paused song with the same title and no proven song link; only the route's video id differs. The new song's
  card must get its own 20 s pause deadline (clear >= 25 s after the first card), not inherit the first one's.
- LiveToggle: command-discord-off / command-discord-on call ApplyDiscordOptions(Enabled false/true), the
  Settings Save path. Off: a clear, then the connection closes, then no further frames. On: a new connection,
  READY and a fresh non-null card after that READY.
- TrueQuit: while track A plays, command-quit. A null SET_ACTIVITY must arrive before the connection closes
  and the process must exit within 5 s without a force-kill.
- HiddenAndCompact: bench state Hidden + profile Playing. Hidden: Presence reads continue (~5 s cadence) and
  the card stays up. command-compact (SetCompact(true) + activation): Compact reads ~1/s and zero Presence
  reads (no duplicate read stream), no clear, no other track. command-full: Presence reads at ~5 s cadence
  resume. Read counts come from diagnostics snapshots (command-snapshot-<label>) bounded by boundaryQpc.
- Locale: profile Playing. command-locale-fr / -en set the fixture page's <html lang> (the reader accepts only
  English pages). The Discord button's tooltip/UIA help text must say songs cannot be read while the page is not
  English, the card must clear after the 8 s read hold, Discord off must drop the note (off text only), Discord
  on must bring it back without a card, and English must restore the normal text and a fresh Fixture Song A card.
#>
[CmdletBinding()]
param(
    # One name, All, or a comma-separated list; validated below (a comma list arrives as one string via -File).
    [string[]] $Scenario = @('All'),
    # Qualified at 4 (two consecutive clean full runs, 282 s each); -Parallel 1 runs everything in this process.
    [int] $Parallel = 4,
    [string] $OutputDirectory = 'artifacts/discord-rpc',
    [switch] $SkipPublish,
    [switch] $CopyWebView2Runtime,
    [switch] $KeepRoot,
    [int] $TimelineSeconds = 215
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$allScenarios = @('Timeline', 'Absent', 'Disable', 'Migration', 'Reconnect', 'ButtonOff', 'ProductionGate', 'PauseExpiry',
    'ArtGap', 'RejectedClear', 'RejectedReplace', 'SameTitle', 'ReaderGap', 'LiveToggle', 'TrueQuit', 'HiddenAndCompact', 'Locale')
$Scenario = @($Scenario | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($name in $Scenario) {
    if ($name -ne 'All' -and $name -notin $allScenarios) { throw "Unknown scenario '$name'. Valid: All, $($allScenarios -join ', ')." }
}
$selected = if ('All' -in $Scenario) { $allScenarios } else { @($allScenarios | Where-Object { $_ -in $Scenario }) }

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$commandLine = 'pwsh -NoProfile -File scripts/discord-rpc-e2e.ps1 ' + (($PSBoundParameters.GetEnumerator() | ForEach-Object {
    if ($_.Value -is [switch]) { if ($_.Value) { "-$($_.Key)" } } else { "-$($_.Key) $(@($_.Value) -join ',')" } }) -join ' ')
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
$appDirectory = Join-Path $repo 'artifacts/discord-rpc/app'
$appExe = Join-Path $appDirectory 'Nativune.exe'
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N')
$runDirectory = Join-Path $outputRoot $runId
$rootBase = Join-Path $repo ".cache/discord-rpc-e2e/$runId"
# The pinned version comes from BrowserPrivacy.ExtensionVersion so the two cannot drift.
$ubolVersion = [regex]::Match((Get-Content -Raw (Join-Path $repo 'src/Nativune/BrowserPrivacy.cs')),
    'ExtensionVersion\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $ubolVersion) { throw 'Could not read BrowserPrivacy.ExtensionVersion.' }
$ubolSource = Join-Path $repo ".tools/ubol/$ubolVersion"
if (-not (Test-Path -LiteralPath (Join-Path $ubolSource 'manifest.json') -PathType Leaf)) {
    throw "uBO Lite $ubolVersion is missing at $ubolSource (manifest.json). Provision the repository .tools/ubol tree before running the Discord E2E."
}
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

function Write-Settings([string] $Root, [bool] $Enabled, [bool] $OpenButton = $true) {
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
        DiscordPresence = $Enabled; DiscordStatusLine = 0; DiscordOpenButton = $OpenButton
    }
    [IO.File]::WriteAllText((Join-Path $data 'settings.json'), ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}

function New-Root([string] $Name) {
    $root = Join-Path $rootBase $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    # BrowserPrivacy fails closed without <root>/.tools/ubol/<version>/manifest.json and rejects
    # reparse points, so each root gets a real copy of the repository uBO Lite tree.
    $ubolDestination = Join-Path $root '.tools/ubol'
    [IO.Directory]::CreateDirectory($ubolDestination) | Out-Null
    Copy-Item -LiteralPath $ubolSource -Destination $ubolDestination -Recurse
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
    $ready = Join-Path $runDirectory "ready-$Name.json"
    $arguments = @('-NoProfile', '-File', (Join-Path $repo 'scripts/discord-rpc-test-server.ps1'),
        '-PipeName', ($prefix + '0'), '-FramesPath', $frames, '-StopFile', $stop, '-Mode', $Mode, '-ReadyFile', $ready)
    $process = Start-Process -FilePath pwsh -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $started.Add($process)
    # The server writes the ready file once its first pipe instance is listening (no fixed sleep).
    if (-not (Wait-Until { Test-Path -LiteralPath $ready } 20)) { throw "Fake Discord server '$Name' did not become ready within 20 s." }
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

$benchEnvKeys = @('NATIVUNE_TEST_DISCORD_BENCH_PROFILE', 'NATIVUNE_TEST_DISCORD_BENCH_STATE')

# $Override: name -> value; a $null value removes that variable for this launch (e.g. MIN_WRITE for production).
function Start-App([string] $Root, [hashtable] $Override = @{}) {
    foreach ($entry in $testEnv.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
    foreach ($key in $benchEnvKeys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
    foreach ($entry in $Override.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
    $process = Start-Process -FilePath $appExe -ArgumentList @('web', '--root', $Root) -WorkingDirectory $appDirectory -PassThru
    $started.Add($process)
    $process
}

function Get-BenchDirectory([string] $Root) { Join-Path $Root 'data/discord-bench' }

function Send-HookCommand([string] $Root, [string] $Name) {
    $directory = Get-BenchDirectory $Root
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $directory $Name), 'go')
    [DateTime]::UtcNow
}

function Wait-Until([scriptblock] $Condition, [double] $Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        if (& $Condition) { return $true }
        Start-Sleep -Milliseconds 250
    }
    [bool] (& $Condition)
}

# Requests diagnostics-<label>.json and returns it parsed (or $null after 10 s).
function Get-HookSnapshot([string] $Root, [string] $Label) {
    $path = Join-Path (Get-BenchDirectory $Root) "diagnostics-$Label.json"
    [void] (Send-HookCommand $Root "command-snapshot-$Label")
    if (-not (Wait-Until { Test-Path -LiteralPath $path } 10)) { return $null }
    Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -Depth 8
}

# Reads started in (Start.boundaryQpc, End.boundaryQpc]: total plus the recorded mode (Compact demand vs presence-only).
function Get-ReadCounts($Start, $End) {
    $counts = [ordered]@{ total = 0; presence = 0; compact = 0; seconds = $null }
    if (-not $Start -or -not $End) { return $counts }
    $counts.seconds = [Math]::Round(([double] $End.boundaryQpc - [double] $Start.boundaryQpc) / [double] $End.qpcFrequency, 3)
    foreach ($read in @($End.reads)) {
        if ([double] $read.startQpc -gt [double] $Start.boundaryQpc -and [double] $read.startQpc -le [double] $End.boundaryQpc) {
            $counts.total++
            if ($read.mode -eq 'Presence') { $counts.presence++ } else { $counts.compact++ }
        }
    }
    $counts
}

function Wait-BenchReady([string] $Root, [double] $Seconds = 90) {
    $directory = Get-BenchDirectory $Root
    [void] (Wait-Until { (Test-Path -LiteralPath (Join-Path $directory 'ready.json')) -or (Test-Path -LiteralPath (Join-Path $directory 'failed.json')) } $Seconds)
    Test-Path -LiteralPath (Join-Path $directory 'ready.json')
}

function Get-FrameEvents($Frames, [string] $Name) { @($Frames | Where-Object { $_.direction -eq 'event' -and $_.json -eq $Name }) }

function Stop-App([Diagnostics.Process] $Process, [string] $Root) {
    if (-not $Process) { return $null }
    $closeUtc = [DateTime]::UtcNow
    if (-not $Process.HasExited) {
        # WM_CLOSE only hides to the tray (TrayEnabled), which used to cost a full 8 s wait plus a force kill on
        # every launch. The test-hook command-quit runs the normal Quit path instead. Checks that must not
        # count the quit clear are bounded by the returned close time (see timeline.finalClear).
        try { [void] (Send-HookCommand $Root 'command-quit') } catch { }
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

$repoUrl = 'https://github.com/Hantu-Raya/Nativune'
# AppVersion.DisplayName of the tested artifact: ProductVersion minus only +metadata (prerelease kept).
function Get-ExpectedCaption { "Nativune $(("$appVersion") -replace '\+.*$', '') $([char] 0x00B7) by Hantu-Raya" }
function Test-CoverIdentity($Activity) {
    $assets = Get-Prop $Activity 'assets'
    [bool] $appVersion -and (Get-Prop $assets 'large_text') -ceq (Get-ExpectedCaption) -and (Get-Prop $assets 'large_url') -ceq $repoUrl
}
# The fixture's album anchors carry unique canaries; none may reach any outbound activity field.
function Test-NoAlbumCanary($Activity) { ($Activity | ConvertTo-Json -Depth 16 -Compress) -notmatch 'albumCanary|MPREb_' }

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
    Add-Check 'timeline.trackAFields' ($a.Count -gt 0 -and -not ($a | Where-Object { (Get-Prop $_.Activity 'state') -ne 'Fixture Artist' }))
    $sharedArt = 'https://lh3.googleusercontent.com/fixture-a=w544-h544'
    Add-Check 'timeline.trackAArtwork' ($a.Count -gt 0 -and (Get-Prop (& $assets $a[0].Activity) 'large_image') -eq $sharedArt)
    # Cover (large image) hover text and link identify the app, not the album, on every non-null card.
    Add-Check 'timeline.coverHoverAppInfo' ([bool] $appVersion -and $nonNull.Count -gt 0 -and -not ($nonNull | Where-Object {
        (Get-Prop (& $assets $_.Activity) 'large_text') -cne (Get-ExpectedCaption) }))
    Add-Check 'timeline.coverLinksRepo' ($nonNull.Count -gt 0 -and -not ($nonNull | Where-Object {
        (Get-Prop (& $assets $_.Activity) 'large_url') -cne $repoUrl }))
    Add-Check 'timeline.noAlbumCanaryOutbound' ($nonNull.Count -gt 0 -and -not ($nonNull | Where-Object { -not (Test-NoAlbumCanary $_.Activity) }))

    $aPlaying = @($a | Where-Object { $null -ne (& $ts $_.Activity) })
    $spans = @($aPlaying | ForEach-Object { [double] (Get-Prop (& $ts $_.Activity) 'end') - [double] (Get-Prop (& $ts $_.Activity) 'start') })
    Add-Check 'timeline.timestampsWhilePlaying' ($aPlaying.Count -gt 0)
    Add-Check 'timeline.durationSpan210s' ($spans.Count -gt 0 -and -not ($spans | Where-Object { [Math]::Abs($_ - 210) -gt 2 }))
    $starts = @($aPlaying | ForEach-Object { [double] (Get-Prop (& $ts $_.Activity) 'start') })
    $seekShift = $false
    # Fixture seeks at page time 25 s from ~25 s to 100 s, so start shifts by -(100-25) = -75 s.
    for ($i = 1; $i -lt $starts.Count; $i++) { if ([Math]::Abs(($starts[$i] - $starts[0]) + 75) -le 4) { $seekShift = $true } }
    Add-Check 'timeline.seekReanchors' $seekShift

    $pauseIndex = [Array]::FindIndex([object[]] $sets, [Predicate[object]] { param($s) $null -ne $s.Activity -and (& $isA $s) -and (Get-Prop (& $assets $s.Activity) 'small_image') -eq 'pause' })
    Add-Check 'timeline.pauseBadge' ($pauseIndex -ge 0 -and (Get-Prop (& $assets $sets[$pauseIndex].Activity) 'small_text') -ceq 'Paused')
    Add-Check 'timeline.pauseNoTimestamps' ($pauseIndex -ge 0 -and $null -eq (& $ts $sets[$pauseIndex].Activity))
    $resumed = $pauseIndex -ge 0 -and [bool] ($sets | Select-Object -Skip ($pauseIndex + 1) | Where-Object {
        $null -ne $_.Activity -and (& $isA $_) -and $null -ne (& $ts $_.Activity) })
    Add-Check 'timeline.resumeTimestamps' $resumed

    Add-Check 'timeline.trackBFields' ($b.Count -gt 0 -and -not ($b | Where-Object {
        (Get-Prop $_.Activity 'state') -ne 'Second Artist' -or (Get-Prop (& $assets $_.Activity) 'large_image') -notin @($sharedArt, 'nativune') }))
    $firstB = [Array]::FindIndex([object[]] $sets, [Predicate[object]] { param($s) $null -ne $s.Activity -and (& $isB $s) })
    # Track B shares track A's artwork URL. The app may show the 'nativune' fallback right after the title change
    # (previous-item art protection), but must publish the shared art once track B has kept it for >= 3 s.
    Add-Check 'timeline.sameAlbumArtShown' ($firstB -ge 0 -and [bool] ($b | Where-Object {
        $_.Mono -ge ($sets[$firstB].Mono + 3000) -and (Get-Prop (& $assets $_.Activity) 'large_image') -eq $sharedArt }))
    # Artwork is identical across A and B, so staleness is judged by title and artist only.
    Add-Check 'timeline.noStaleTrackAAfterB' ($firstB -ge 0 -and -not ($sets | Select-Object -Skip $firstB | Where-Object {
        $null -ne $_.Activity -and ((& $isA $_) -or (Get-Prop $_.Activity 'state') -eq 'Fixture Artist') }))
    $repeatIndex = [Array]::FindIndex([object[]] $sets, [Predicate[object]] { param($s) $null -ne $s.Activity -and (& $isB $s) -and (Get-Prop (& $assets $s.Activity) 'small_image') -eq 'repeat-one' })
    Add-Check 'timeline.repeatOneBadge' ($repeatIndex -ge 0 -and (Get-Prop (& $assets $sets[$repeatIndex].Activity) 'small_text') -ceq 'Repeat one')
    # Exact badge wording everywhere, no small_url, and no badge invented for ordinary playback (track A playing).
    Add-Check 'timeline.badgeTextExact' (-not ($nonNull | Where-Object {
        $image = Get-Prop (& $assets $_.Activity) 'small_image'; $text = Get-Prop (& $assets $_.Activity) 'small_text'
        ($image -eq 'pause' -and $text -cne 'Paused') -or ($image -eq 'repeat-one' -and $text -cne 'Repeat one') -or
            ($image -notin @($null, 'pause', 'repeat-one')) -or ($null -eq $image -and $null -ne $text) }))
    Add-Check 'timeline.noSmallUrl' ($nonNull.Count -gt 0 -and -not ($nonNull | Where-Object { $null -ne (Get-Prop (& $assets $_.Activity) 'small_url') }))
    Add-Check 'timeline.noBadgeWhilePlainPlaying' ($aPlaying.Count -gt 0 -and -not ($aPlaying | Where-Object { $null -ne (Get-Prop (& $assets $_.Activity) 'small_image') }))
    # Fixture ends at page time 120 s (repeat-one at 100 s): the first null after the repeat-one frame must
    # arrive within 25 s of it, and no track-B pause-badge card may follow the repeat-one frame.
    $endedClear = $false
    if ($repeatIndex -ge 0) {
        $afterRepeat = @($sets | Select-Object -Skip ($repeatIndex + 1))
        $firstNull = $afterRepeat | Where-Object { $null -eq $_.Activity } | Select-Object -First 1
        $pauseAfterRepeat = $afterRepeat | Where-Object {
            $null -ne $_.Activity -and (& $isB $_) -and (Get-Prop (& $assets $_.Activity) 'small_image') -eq 'pause' }
        $endedClear = $null -ne $firstNull -and (($firstNull.Mono - $sets[$repeatIndex].Mono) / 1000) -le 25 -and -not $pauseAfterRepeat
    }
    Add-Check 'timeline.endedClears' $endedClear
    # Only frames sent before the harness closed the app: the quit path's own clear must not stand in for the
    # ended clear (page 192) that this check proves.
    $preClose = @($sets | Where-Object { $null -ne $closeUtc -and $_.Utc -lt $closeUtc })
    Add-Check 'timeline.finalClear' ($preClose.Count -gt 0 -and $null -eq $preClose[-1].Activity)

    $allowedTrackUrls = @('https://music.youtube.com/watch?v=fixtureSngA', 'https://music.youtube.com/watch?v=fixtureSngB',
        'https://music.youtube.com/watch?v=fixtureSngC')
    $detailsUrls = @($nonNull | ForEach-Object { Get-Prop $_.Activity 'details_url' } | Where-Object { $_ } | Select-Object -Unique)
    $buttons = @($nonNull | ForEach-Object { Get-Prop $_.Activity 'buttons' } | Where-Object { $_ })
    $buttonUrls = @($buttons | ForEach-Object { $_ } | ForEach-Object { Get-Prop $_ 'url' })
    Add-Check 'timeline.linksOnlyProvenTrack' (-not ($detailsUrls + $buttonUrls | Where-Object { $_ -notin $allowedTrackUrls }))
    Add-Check 'timeline.atMostOneButton' (-not ($nonNull | Where-Object { @(Get-Prop $_.Activity 'buttons').Where({ $_ }).Count -gt 1 }))

    # Link ids come from the fixture page itself (byline anchors, in track order A, B, C).
    $fixtureHtml = Get-Content -LiteralPath (Join-Path $repo 'src/Nativune/DiscordFixturePage.html') -Raw
    $channelIds = @([regex]::Matches($fixtureHtml, 'channel/(UC[A-Za-z0-9_-]+)') | ForEach-Object { $_.Groups[1].Value })
    $readyUtc = if ($readyIndex -ge 0) { ConvertTo-UtcTime $frames[$readyIndex].utc } else { $null }
    # The fixture timeline is in PAGE time (ad-showing 65-75 s after page load), but the page loads several
    # seconds after READY. Estimate the READY->page offset from events with known page times: track B starts at
    # page 80 s and track A resumes at page 60 s. Each observed send = pageTime + offset + debounce (1 s) + possible
    # MIN_WRITE gate delay, so (send - pageTime - debounce) is an upper bound on the offset; take the smallest.
    $debounceSeconds = 1; $adStart = 65; $adEnd = 75
    $offsetCandidates = @()
    if ($readyUtc -and $firstB -ge 0) { $offsetCandidates += ($sets[$firstB].Utc - $readyUtc).TotalSeconds - 80 - $debounceSeconds }
    if ($readyUtc -and $pauseIndex -ge 0) {
        $resumeSet = $sets | Select-Object -Skip ($pauseIndex + 1) | Where-Object {
            $null -ne $_.Activity -and (& $isA $_) -and $null -ne (& $ts $_.Activity) } | Select-Object -First 1
        if ($resumeSet) { $offsetCandidates += ($resumeSet.Utc - $readyUtc).TotalSeconds - 60 - $debounceSeconds }
    }
    $adOffset = if ($offsetCandidates.Count -gt 0) { ($offsetCandidates | Measure-Object -Minimum).Minimum } else { $null }
    $inAdWindow = { param($s) $null -ne $adOffset -and $s.Utc -ge $readyUtc.AddSeconds(65 + $adOffset) -and $s.Utc -le $readyUtc.AddSeconds(75 + $adOffset) }
    $hasTrackLinks = { param($s, [string] $Url)
        $btn = @(Get-Prop $s.Activity 'buttons' | Where-Object { $_ })
        (Get-Prop $s.Activity 'details_url') -eq $Url -and $btn.Count -eq 1 -and
            (Get-Prop $btn[0] 'label') -eq 'Open in YouTube Music' -and (Get-Prop $btn[0] 'url') -eq $Url }
    $aOutsideAd = @($a | Where-Object { -not (& $inAdWindow $_) })
    $urlA = 'https://music.youtube.com/watch?v=fixtureSngA'; $urlB = 'https://music.youtube.com/watch?v=fixtureSngB'
    Add-Check 'timeline.trackADetailsUrlAndButton' ($aOutsideAd.Count -gt 0 -and -not ($aOutsideAd | Where-Object { -not (& $hasTrackLinks $_ $urlA) }))
    Add-Check 'timeline.trackAStateUrl' ($channelIds.Count -ge 1 -and $aOutsideAd.Count -gt 0 -and -not ($aOutsideAd | Where-Object {
        (Get-Prop $_.Activity 'state_url') -ne "https://music.youtube.com/channel/$($channelIds[0])" }))
    $linkless = { param($s) -not (Get-Prop $s.Activity 'details_url') -and @(Get-Prop $s.Activity 'buttons' | Where-Object { $_ }).Count -eq 0 }
    $adSets = @(); $adOk = $false
    if ($null -ne $adOffset) {
        # Offset is an upper bound, so [adStart+offset, adEnd+offset] cannot contain pre-ad linked cards; the ad card
        # itself lands debounce later. The fixture's title-link change forces a republish inside the window.
        $winStart = $readyUtc.AddSeconds($adStart + $adOffset); $winEnd = $readyUtc.AddSeconds($adEnd + $adOffset)
        $adSets = @($nonNull | Where-Object { $_.Utc -ge $winStart -and $_.Utc -le $winEnd })
        $restoreAfter = $readyUtc.AddSeconds($adEnd + $adOffset + $minWriteSeconds + $debounceSeconds)
        $afterAd = $nonNull | Where-Object { $_.Utc -gt $restoreAfter } | Select-Object -First 1
        # Song links (details_url, button) are suppressed; the repository cover link and the fixture's independently
        # valid artist link may remain. This does not prove all links or all ad metadata are suppressed.
        $artistUrls = @($channelIds | ForEach-Object { "https://music.youtube.com/channel/$_" })
        $adOk = $adSets.Count -gt 0 -and -not ($adSets | Where-Object {
                -not (& $linkless $_) -or (Get-Prop (& $assets $_.Activity) 'large_url') -cne $repoUrl -or
                ($null -ne (Get-Prop $_.Activity 'state_url') -and (Get-Prop $_.Activity 'state_url') -notin $artistUrls) }) -and
            $null -ne $afterAd -and ((& $hasTrackLinks $afterAd $urlA) -or (& $hasTrackLinks $afterAd $urlB))
    }
    Add-Check 'timeline.adWindowNoSongLinks' $adOk
    Add-Check 'timeline.trackBDetailsUrlAndButton' ($b.Count -gt 0 -and -not ($b | Where-Object { -not (& $hasTrackLinks $_ $urlB) }))
    Add-Check 'timeline.trackBStateUrl' ($channelIds.Count -ge 2 -and $b.Count -gt 0 -and -not ($b | Where-Object {
        (Get-Prop $_.Activity 'state_url') -ne "https://music.youtube.com/channel/$($channelIds[1])" }))

    # Track C (page 125-192): missing artwork -> 'nativune' fallback (same caption/repo link) -> recovery at 137.
    $isC = { param($s) (Get-Prop $s.Activity 'details') -eq 'Fixture Song C' }
    $c = @($nonNull | Where-Object { & $isC $_ }); $urlC = 'https://music.youtube.com/watch?v=fixtureSngC'
    $artB = 'https://lh3.googleusercontent.com/fixture-b=w544-h544'
    Add-Check 'timeline.trackCFields' ($channelIds.Count -ge 3 -and $c.Count -gt 0 -and -not ($c | Where-Object {
        (Get-Prop $_.Activity 'state') -ne 'Third Artist' -or (Get-Prop $_.Activity 'state_url') -ne "https://music.youtube.com/channel/$($channelIds[2])" -or
            (Get-Prop (& $assets $_.Activity) 'large_image') -notin @('nativune', $artB) }))
    $fallbackC = @($c | Where-Object { (Get-Prop (& $assets $_.Activity) 'large_image') -eq 'nativune' })
    Add-Check 'timeline.missingArtFallbackPublished' ($fallbackC.Count -gt 0 -and -not ($fallbackC | Where-Object { -not (Test-CoverIdentity $_.Activity) }))
    Add-Check 'timeline.missingArtRecovers' ($fallbackC.Count -gt 0 -and [bool] ($c | Where-Object {
        $_.Mono -gt $fallbackC[0].Mono -and (Get-Prop (& $assets $_.Activity) 'large_image') -eq $artB -and (Test-CoverIdentity $_.Activity) }))
    # Unproven title link (page 147-162, outside the ad window; route still /watch?v=fixtureSngC): title, artist link
    # and cover identity stay, details_url and button are absent; song links only ever appear or vanish together.
    $cLinkless = @($c | Where-Object { & $linkless $_ })
    $unprovenOk = $false
    if ($null -ne $adOffset -and $cLinkless.Count -gt 0) {
        $uStart = $readyUtc.AddSeconds(147 + $adOffset - 2); $uEnd = $readyUtc.AddSeconds(162 + $adOffset + $minWriteSeconds + $debounceSeconds + 3)
        $unprovenOk = -not ($cLinkless | Where-Object { $_.Utc -lt $uStart -or $_.Utc -gt $uEnd -or -not (Test-CoverIdentity $_.Activity) })
    }
    Add-Check 'timeline.unprovenTitleNoSongLinks' $unprovenOk
    Add-Check 'timeline.songLinksTogether' ($c.Count -gt 0 -and -not ($c | Where-Object { -not (& $linkless $_) -and -not (& $hasTrackLinks $_ $urlC) }))
    Add-Check 'timeline.songLinksReturn' ($cLinkless.Count -gt 0 -and [bool] ($c | Where-Object { $_.Mono -gt $cLinkless[-1].Mono -and (& $hasTrackLinks $_ $urlC) }))
    # Pause at page 172 while repeat-one is on: the pause badge wins; resume brings repeat-one back.
    $cPause = @($c | Where-Object { (Get-Prop (& $assets $_.Activity) 'small_image') -eq 'pause' })
    Add-Check 'timeline.pauseOverRepeatOne' ($cPause.Count -gt 0 -and -not ($cPause | Where-Object {
        (Get-Prop (& $assets $_.Activity) 'small_text') -cne 'Paused' -or $null -ne (& $ts $_.Activity) }) -and [bool] ($c | Where-Object {
        $_.Mono -gt $cPause[-1].Mono -and (Get-Prop (& $assets $_.Activity) 'small_image') -eq 'repeat-one' -and $null -ne (& $ts $_.Activity) }))

    $minGapSeconds = [double]::PositiveInfinity
    for ($i = 1; $i -lt $nonNull.Count; $i++) { $minGapSeconds = [Math]::Min($minGapSeconds, ($nonNull[$i].Mono - $nonNull[$i - 1].Mono) / 1000) }
    Add-Check 'timeline.writeRate' ($minGapSeconds -ge ($minWriteSeconds - 0.5))

    $scenarioResults['Timeline'] = [ordered]@{
        appPid = $app.Id; connections = @($frames | Where-Object { $_.json -eq 'connected' }).Count
        setActivityCount = $sets.Count; nonNullCount = $nonNull.Count; clearCount = $sets.Count - $nonNull.Count
        minNonNullGapSeconds = if ([double]::IsInfinity($minGapSeconds)) { $null } else { [Math]::Round($minGapSeconds, 3) }
        observedDetailsUrls = $detailsUrls; observedButtonCount = $buttons.Count; adWindowActivityCount = $adSets.Count
        trackCActivityCount = $c.Count; trackCFallbackCount = $fallbackC.Count; trackCUnprovenCount = $cLinkless.Count
        expectedCaption = Get-ExpectedCaption
        adWindowOffsetSeconds = if ($null -ne $adOffset) { [Math]::Round($adOffset, 3) } else { $null }
        adWindowMethod = 'offset = min(firstTrackB - 80 s, firstResume - 60 s) - 1 s debounce (READY-relative); window = page 65-75 s + offset'
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

function Test-Migration {
    # A v6 profile that already had DiscordPresence=true must migrate to off (explicit opt-in in v7).
    $root = New-Root 'migration'
    $data = Join-Path $root 'data'
    [IO.Directory]::CreateDirectory($data) | Out-Null
    $settings = [ordered]@{
        Version = 6; X = 100; Y = 100; Width = 1280; Height = 800; Dpi = 96; Maximized = $false; Zoom = 1.0
        TrayEnabled = $true; RestoreSection = $false; LastSection = 'home'; ReduceMotion = $false
        CompactX = 100; CompactY = 100; CompactWidth = 800; CompactHeight = 180; CompactDpi = 96
        SleepInBackground = $false; StartCompact = $false; AutoCheckUpdates = $false
        OutputVolume = 1.0; BlockAds = $false; DiscordPresence = $true
    }
    [IO.File]::WriteAllText((Join-Path $data 'settings.json'), ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $server = Start-FakeServer 'migration'
    $app = $null
    try {
        $app = Start-App $root
        Start-Sleep -Seconds 30
        $alive = -not $app.HasExited
        [void] (Stop-App $app $root)
        Start-Sleep -Seconds 1
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['Migration'] = $frames
    Copy-AppLog $root 'migration'
    $connections = @($frames | Where-Object { $_.json -eq 'connected' }).Count
    Add-Check 'migration.appAlive' $alive
    Add-Check 'migration.v6DiscordTrueZeroConnections' ($connections -eq 0)
    $scenarioResults['Migration'] = [ordered]@{ appPid = $app.Id; seconds = 30; seededVersion = 6; connections = $connections }
}

function Test-Reconnect {
    # Discord drops mid-song and comes back: the first card on the new connection must come from a page
    # observation made after the new READY, never the cached pre-disconnect card.
    $root = New-Root 'reconnect'
    Write-Settings $root $true
    $server1 = Start-FakeServer 'reconnect-1'
    $server2 = $null; $app = $null; $alive = $false; $firstUtc = $null
    try {
        $app = Start-App $root
        $deadline = [DateTime]::UtcNow.AddSeconds(90)
        while ([DateTime]::UtcNow -lt $deadline -and -not $firstUtc) {
            Start-Sleep -Seconds 1
            $first = @(Get-Activities (Read-Frames $server1)) | Where-Object { $null -ne $_.Activity } | Select-Object -First 1
            if ($first) { $firstUtc = $first.Utc }
        }
        if (-not $firstUtc) { throw 'Reconnect: no non-null SET_ACTIVITY on the first connection within 90 s.' }
        # First card lands about page 0 + debounce (1 s), so page time ~= now - firstUtc + 1.
        $untilPage = { param([double] $Page) $wait = ($firstUtc.AddSeconds($Page - 1) - [DateTime]::UtcNow).TotalSeconds
            if ($wait -gt 0) { Start-Sleep -Milliseconds ([int] ($wait * 1000)) } }
        & $untilPage 35
        Stop-FakeServer $server1
        Start-Sleep -Seconds 15
        $server2 = Start-FakeServer 'reconnect-2'
        & $untilPage 75
        $alive = -not $app.HasExited
        [void] (Stop-App $app $root)
        Start-Sleep -Seconds 2
    } finally { Stop-FakeServer $server1; Stop-FakeServer $server2 }
    $frames1 = Read-Frames $server1; $frames2 = Read-Frames $server2
    $framesByScenario['Reconnect'] = [ordered]@{ first = $frames1; second = $frames2 }
    Copy-AppLog $root 'reconnect'

    $sets1 = @(Get-Activities $frames1); $sets2 = @(Get-Activities $frames2)
    $handshake2 = [bool] ($frames2 | Where-Object { $_.direction -eq 'in' -and $_.opcode -eq 0 })
    $connected2 = @($frames2 | Where-Object { $_.json -eq 'connected' }).Count
    Add-Check 'reconnect.reconnected' ($connected2 -ge 1 -and $handshake2)
    Add-Check 'reconnect.noCrash' $alive

    # Freshness of the first SET_ACTIVITY on the second connection. Page timeline: seek to 100 s at page 25,
    # pause at 45 (position 120), resume at 60, track B at 80. The last playing track-A card before the drop has
    # start = page0 - 75; a fresh playing track-A card after resume has start = page0 - 60 (the 15 s pause shifts
    # it by +15); track B has start = page0 + 80 = staleStart + 155. Tolerance: 5 s on start (debounce, 1 s poll
    # jitter, rounding). A pause card is accepted only if sent in estimated page time [40, 68] (the pause window
    # 45-60 widened by 5 s before and debounce + min-write + 5 s after; page time is estimated from the first card).
    $isA = { param($s) (Get-Prop $s.Activity 'details') -eq 'Fixture Song A' }
    $staleStart = @($sets1 | Where-Object { $null -ne $_.Activity -and (& $isA $_) -and $null -ne (Get-Prop $_.Activity 'timestamps') } |
        ForEach-Object { [double] (Get-Prop (Get-Prop $_.Activity 'timestamps') 'start') }) | Select-Object -Last 1
    $firstSet2 = $sets2 | Select-Object -First 1
    $fresh = $false; $verdict = 'no-activity'; $pageAtSend = $null
    if ($firstSet2) {
        $pageAtSend = ($firstSet2.Utc - $firstUtc).TotalSeconds + 1
        $act = $firstSet2.Activity
        $stamps = Get-Prop $act 'timestamps'
        if ($null -eq $act) { $fresh = $true; $verdict = 'clear' }
        elseif ($null -eq $stamps) {
            $isPause = (Get-Prop (Get-Prop $act 'assets') 'small_image') -eq 'pause'
            $fresh = $isPause -and (& $isA $firstSet2) -and $pageAtSend -ge 40 -and $pageAtSend -le 68
            $verdict = if ($isPause) { 'pause-card' } else { 'card-without-timestamps' }
        } elseif ($null -ne $staleStart) {
            $start = [double] (Get-Prop $stamps 'start')
            $details = Get-Prop $act 'details'
            $expected = if ($details -eq 'Fixture Song A') { $staleStart + 15 } elseif ($details -eq 'Fixture Song B') { $staleStart + 155 } else { $null }
            $fresh = $null -ne $expected -and [Math]::Abs($start - $expected) -le 5 -and $pageAtSend -ge 58
            $verdict = 'playing-card'
        }
    }
    Add-Check 'reconnect.firstActivityIsFresh' $fresh
    $scenarioResults['Reconnect'] = [ordered]@{
        appPid = $app.Id; firstConnectionSets = $sets1.Count; secondConnectionSets = $sets2.Count; secondConnections = $connected2
        firstActivityOnReconnect = $verdict
        estimatedPageAtFirstReconnectSend = if ($null -ne $pageAtSend) { [Math]::Round($pageAtSend, 1) } else { $null }
        freshnessRule = 'clear; or track-A pause card at est. page 40-68; or playing card with start within 5 s of (last pre-drop track-A start + 15 s) for A / + 155 s for B'
    }
}

function Test-ButtonOff {
    # Saved DiscordOpenButton = false: the proven title link (details_url) stays, no button is ever sent, and the
    # artist and cover destinations are unchanged. Track A plays with a proven link from page 0 to the 45 s pause.
    $root = New-Root 'buttonoff'
    Write-Settings $root $true $false
    $server = Start-FakeServer 'buttonoff'
    $app = $null; $alive = $false
    try {
        $app = Start-App $root
        Start-Sleep -Seconds 45
        $alive = -not $app.HasExited
        [void] (Stop-App $app $root)
        Start-Sleep -Seconds 2
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['ButtonOff'] = $frames
    Copy-AppLog $root 'buttonoff'
    $nonNull = @(Get-Activities $frames | Where-Object { $null -ne $_.Activity })
    $a = @($nonNull | Where-Object { (Get-Prop $_.Activity 'details') -eq 'Fixture Song A' })
    Add-Check 'buttonOff.noCrash' $alive
    Add-Check 'buttonOff.detailsUrlPresent' ([bool] ($a | Where-Object { (Get-Prop $_.Activity 'details_url') -ceq 'https://music.youtube.com/watch?v=fixtureSngA' }))
    Add-Check 'buttonOff.noButtons' ($nonNull.Count -gt 0 -and -not ($nonNull | Where-Object { @(Get-Prop $_.Activity 'buttons' | Where-Object { $_ }).Count -gt 0 }))
    Add-Check 'buttonOff.artistAndCoverUnchanged' ($a.Count -gt 0 -and -not ($a | Where-Object {
        (Get-Prop $_.Activity 'state_url') -ne 'https://music.youtube.com/channel/UCfixtureArtist000000001' -or -not (Test-CoverIdentity $_.Activity) }))
    $scenarioResults['ButtonOff'] = [ordered]@{ appPid = $app.Id; seconds = 45; nonNullCount = $nonNull.Count; seededDiscordOpenButton = $false }
}

function Wait-FirstCard($Server, [double] $Seconds = 90) {
    $found = @{ utc = $null }
    [void] (Wait-Until {
        $first = @(Get-Activities (Read-Frames $Server)) | Where-Object { $null -ne $_.Activity } | Select-Object -First 1
        if ($first) { $found.utc = $first.Utc; $true } else { $false } } $Seconds)
    $found.utc
}

function Wait-UntilUtc([datetime] $Utc) {
    $wait = ($Utc - [DateTime]::UtcNow).TotalMilliseconds
    if ($wait -gt 0) { Start-Sleep -Milliseconds ([int] $wait) }
}

function Test-ProductionGate {
    # Production write gate (15 s): MIN_WRITE override removed; everything else as Timeline.
    $root = New-Root 'productiongate'
    Write-Settings $root $true
    $server = Start-FakeServer 'productiongate'
    $app = $null; $alive = $false; $firstUtc = $null
    try {
        $app = Start-App $root @{ NATIVUNE_TEST_DISCORD_MIN_WRITE_SECONDS = $null }
        $firstUtc = Wait-FirstCard $server
        if (-not $firstUtc) { throw 'ProductionGate: no non-null SET_ACTIVITY within 90 s.' }
        # First card ~= page 0 + 1 s debounce; run to page ~135 (after the 120 s ended stop and track C start).
        Wait-UntilUtc $firstUtc.AddSeconds(134)
        $alive = -not $app.HasExited
        [void] (Stop-App $app $root)
        Start-Sleep -Seconds 2
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['ProductionGate'] = $frames
    Copy-AppLog $root 'productiongate'
    $sets = @(Get-Activities $frames)
    $nonNull = @($sets | Where-Object { $null -ne $_.Activity })
    $minGap = [double]::PositiveInfinity
    for ($i = 1; $i -lt $nonNull.Count; $i++) { $minGap = [Math]::Min($minGap, ($nonNull[$i].Mono - $nonNull[$i - 1].Mono) / 1000) }
    $firstB = [Array]::FindIndex([object[]] $sets, [Predicate[object]] { param($s) $null -ne $s.Activity -and (Get-Prop $s.Activity 'details') -eq 'Fixture Song B' })
    $endedClear = if ($firstB -ge 0) { $sets | Select-Object -Skip ($firstB + 1) | Where-Object { $null -eq $_.Activity } | Select-Object -First 1 } else { $null }
    $endedPage = if ($endedClear) { ($endedClear.Utc - $firstUtc).TotalSeconds + 1 } else { $null }
    Add-Check 'productionGate.noCrash' $alive
    Add-Check 'productionGate.cardsSent' ($nonNull.Count -ge 3)
    Add-Check 'productionGate.coversTrackChange' ($firstB -ge 0)
    Add-Check 'productionGate.nonNullGapAtLeast14_5s' ($nonNull.Count -ge 2 -and $minGap -ge 14.5)
    # Ended at page 120 s: clear within 5 s (+2 s page-estimate tolerance either side).
    Add-Check 'productionGate.endedClearNotGated' ($null -ne $endedPage -and $endedPage -ge 118 -and $endedPage -le 127)
    $scenarioResults['ProductionGate'] = [ordered]@{
        appPid = $app.Id; minWriteOverride = $null; setActivityCount = $sets.Count; nonNullCount = $nonNull.Count
        minNonNullGapSeconds = if ([double]::IsInfinity($minGap)) { $null } else { [Math]::Round($minGap, 3) }
        estimatedEndedClearPage = if ($null -ne $endedPage) { [Math]::Round($endedPage, 1) } else { $null }
    }
}

function Test-PauseExpiry {
    $root = New-Root 'pauseexpiry'
    Write-Settings $root $true
    $server = Start-FakeServer 'pauseexpiry'
    $server2 = $null
    $app = $null; $alive = $false; $ready = $false; $firstUtc = $null; $resumeUtc = $null; $reconnectUtc = $null; $suspendUtc = $null
    try {
        $app = Start-App $root @{ NATIVUNE_TEST_DISCORD_PAUSE_SECONDS = '20'
            NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'Paused'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
        $ready = Wait-BenchReady $root
        $firstUtc = Wait-FirstCard $server 60
        if (-not $firstUtc) { throw 'PauseExpiry: no paused card within 60 s.' }
        Wait-UntilUtc $firstUtc.AddSeconds(32)
        # Still paused and already expired: drop Discord and bring it back on a new connection.
        Stop-FakeServer $server
        Start-Sleep -Seconds 1
        $server2 = Start-FakeServer 'pauseexpiry-2'
        [void] (Wait-Until { [bool] (@(Read-Frames $server2) | Where-Object { $_.json -eq 'connected' }) } 30)
        $reconnectUtc = [DateTime]::UtcNow
        # Two page reads (5 s cadence) + debounce + write gate: a republished card would land in this window.
        Start-Sleep -Seconds 15
        # System sleep while still paused: suspend then resume must not restart the 10-minute deadline.
        $suspendUtc = Send-HookCommand $root 'command-power-suspend'
        Start-Sleep -Seconds 3
        [void] (Send-HookCommand $root 'command-power-resume')
        Start-Sleep -Seconds 15
        $resumeUtc = Send-HookCommand $root 'command-resume'
        [void] (Wait-Until { [bool] (@(Get-Activities (Read-Frames $server2)) | Where-Object {
            $null -ne $_.Activity -and $_.Utc -gt $resumeUtc -and $null -ne (Get-Prop $_.Activity 'timestamps') }) } 15)
        $alive = -not $app.HasExited
        [void] (Stop-App $app $root)
        Start-Sleep -Seconds 2
    } finally { Stop-FakeServer $server; Stop-FakeServer $server2 }
    $frames = Read-Frames $server
    $frames2 = Read-Frames $server2
    $framesByScenario['PauseExpiry'] = [ordered]@{ first = $frames; second = $frames2 }
    Copy-AppLog $root 'pauseexpiry'
    $sets = @(Get-Activities $frames)
    $firstPaused = $sets | Where-Object { $null -ne $_.Activity } | Select-Object -First 1
    $beforeResume = @(if ($firstPaused -and $resumeUtc) { $sets | Where-Object { $_.Utc -ge $firstPaused.Utc -and $_.Utc -le $resumeUtc } })
    $clears = @($beforeResume | Where-Object { $null -eq $_.Activity })
    $delay = if ($clears.Count -gt 0) { ($clears[0].Utc - $firstPaused.Utc).TotalSeconds } else { $null }
    $afterClear = @(if ($clears.Count -gt 0) { $beforeResume | Where-Object { $_.Utc -gt $clears[0].Utc } })
    $pausedCards = @($beforeResume | Where-Object { $null -ne $_.Activity })
    $resumed = if ($resumeUtc) { @(Get-Activities $frames2) | Where-Object { $null -ne $_.Activity -and $_.Utc -gt $resumeUtc } | Select-Object -First 1 } else { $null }
    $republished = @(if ($resumeUtc) { @(Get-Activities $frames2) | Where-Object { $null -ne $_.Activity -and $_.Utc -le $resumeUtc } })
    Add-Check 'pauseExpiry.benchReady' $ready
    Add-Check 'pauseExpiry.noCrash' $alive
    Add-Check 'pauseExpiry.pausedCardFirst' ($pausedCards.Count -gt 0 -and -not ($pausedCards | Where-Object {
        (Get-Prop (Get-Prop $_.Activity 'assets') 'small_image') -ne 'pause' -or $null -ne (Get-Prop $_.Activity 'timestamps') }))
    Add-Check 'pauseExpiry.oneClearAfter20s' ($clears.Count -eq 1 -and $delay -ge 15 -and $delay -le 25)
    Add-Check 'pauseExpiry.noRepublishWhilePaused' ($clears.Count -eq 1 -and $afterClear.Count -eq 0)
    Add-Check 'pauseExpiry.reconnected' ($null -ne $reconnectUtc)
    Add-Check 'pauseExpiry.noRepublishAfterReconnect' ($null -ne $reconnectUtc -and $republished.Count -eq 0)
    Add-Check 'pauseExpiry.noRepublishAfterSuspendResume' ($null -ne $suspendUtc -and -not ($republished | Where-Object { $_.Utc -gt $suspendUtc }))
    Add-Check 'pauseExpiry.freshPlayingCardAfterResume' ($null -ne $resumed -and $null -ne (Get-Prop $resumed.Activity 'timestamps') -and
        (Get-Prop $resumed.Activity 'details') -eq 'Fixture Song A' -and ($resumed.Utc - $resumeUtc).TotalSeconds -le 15)
    $scenarioResults['PauseExpiry'] = [ordered]@{
        appPid = $app.Id; pauseSeconds = 20; profile = 'Paused'; clearDelaySeconds = if ($null -ne $delay) { [Math]::Round($delay, 3) } else { $null }
        clearsWhilePaused = $clears.Count; setsAfterClearBeforeResume = $afterClear.Count
        cardsOnNewConnectionBeforeResume = $republished.Count
        resumeToCardSeconds = if ($resumed) { [Math]::Round(($resumed.Utc - $resumeUtc).TotalSeconds, 3) } else { $null }
    }
}

function Test-ArtGap {
    $root = New-Root 'artgap'
    Write-Settings $root $true
    $server = Start-FakeServer 'artgap'
    $app = $null; $alive = $false; $ready = $false
    try {
        $app = Start-App $root @{ NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'ArtGap'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
        $ready = Wait-BenchReady $root
        [void] (Wait-Until { [bool] (@(Get-Activities (Read-Frames $server)) | Where-Object {
            $null -ne $_.Activity -and (Get-Prop $_.Activity 'details') -eq 'Fixture Song B' }) } 60)
        Start-Sleep -Seconds 22 # page 40: B's art becomes a loadable URL longer than 256 characters
        $alive = -not $app.HasExited
        [void] (Stop-App $app $root)
        Start-Sleep -Seconds 2
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['ArtGap'] = $frames
    Copy-AppLog $root 'artgap'
    $sharedArt = 'https://lh3.googleusercontent.com/fixture-a=w544-h544'
    $cards = @(Get-Activities $frames | Where-Object { $null -ne $_.Activity })
    $image = { param($s) Get-Prop (Get-Prop $s.Activity 'assets') 'large_image' }
    $a = @($cards | Where-Object { (Get-Prop $_.Activity 'details') -eq 'Fixture Song A' })
    $b = @($cards | Where-Object { (Get-Prop $_.Activity 'details') -eq 'Fixture Song B' })
    Add-Check 'artGap.noCrash' $alive
    Add-Check 'artGap.benchReady' $ready
    Add-Check 'artGap.trackAArtThenFallback' ($a.Count -ge 2 -and (& $image $a[0]) -eq $sharedArt -and
        [bool] ($a | Where-Object { (& $image $_) -eq 'nativune' }))
    Add-Check 'artGap.firstBCardWithoutSharedArt' ($b.Count -gt 0 -and (& $image $b[0]) -eq 'nativune')
    Add-Check 'artGap.sharedArtOnlyAfter3s' ($b.Count -gt 0 -and -not ($b | Where-Object {
        (& $image $_) -eq $sharedArt -and $_.Mono -lt ($b[0].Mono + 2500) }))
    $longest = (@($cards | ForEach-Object { ([string] (& $image $_)).Length }) | Measure-Object -Maximum).Maximum
    $lastB = $b | Select-Object -Last 1
    Add-Check 'artGap.noLargeImageOver256' ($cards.Count -gt 0 -and $longest -le 256)
    Add-Check 'artGap.longArtworkFallsBack' ($null -ne $lastB -and (& $image $lastB) -eq 'nativune' -and
        [bool] ($b | Where-Object { (& $image $_) -eq $sharedArt }))
    $scenarioResults['ArtGap'] = [ordered]@{
        appPid = $app.Id; trackACards = @($a | ForEach-Object { & $image $_ }); trackBCards = @($b | ForEach-Object { & $image $_ }); longestLargeImage = $longest
    }
}

function Test-RejectedClear {
    $root = New-Root 'rejectedclear'
    Write-Settings $root $true
    $server = Start-FakeServer 'rejectedclear' 'ErrorOnFirstClear'
    $app = $null; $alive = $false; $ready = $false; $firstUtc = $null
    try {
        $app = Start-App $root @{ NATIVUNE_TEST_DISCORD_PAUSE_SECONDS = '20'
            NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'Paused'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
        $ready = Wait-BenchReady $root
        $firstUtc = Wait-FirstCard $server 60
        if (-not $firstUtc) { throw 'RejectedClear: no paused card within 60 s.' }
        Wait-UntilUtc $firstUtc.AddSeconds(45)
        $alive = -not $app.HasExited
        [void] (Stop-App $app $root)
        Start-Sleep -Seconds 2
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['RejectedClear'] = $frames
    Copy-AppLog $root 'rejectedclear'
    $sets = @(Get-Activities $frames)
    $clear = $sets | Where-Object { $null -eq $_.Activity } | Select-Object -First 1
    $clearUtc = if ($clear) { $clear.Utc } else { $null }
    $drops = @(if ($clearUtc) { Get-FrameEvents $frames 'disconnected' | Where-Object { (ConvertTo-UtcTime $_.utc) -ge $clearUtc } })
    $dropUtc = if ($drops.Count) { ConvertTo-UtcTime $drops[0].utc } else { $null }
    $reconnects = @(if ($dropUtc) { Get-FrameEvents $frames 'connected' | Where-Object { (ConvertTo-UtcTime $_.utc) -gt $dropUtc } })
    $cardsAfter = @(if ($clearUtc) { $sets | Where-Object { $null -ne $_.Activity -and $_.Utc -gt $clearUtc } })
    Add-Check 'rejectedClear.benchReady' $ready
    Add-Check 'rejectedClear.noCrash' $alive
    Add-Check 'rejectedClear.clearSent' ($null -ne $clearUtc)
    Add-Check 'rejectedClear.connectionDropped' ($null -ne $dropUtc -and ($dropUtc - $clearUtc).TotalSeconds -le 6)
    Add-Check 'rejectedClear.reconnected' ($reconnects.Count -ge 1)
    Add-Check 'rejectedClear.noCardAfterRejectedClear' ($null -ne $clearUtc -and $cardsAfter.Count -eq 0)
    $scenarioResults['RejectedClear'] = [ordered]@{
        appPid = $app.Id; clearToDropSeconds = if ($dropUtc) { [Math]::Round(($dropUtc - $clearUtc).TotalSeconds, 3) } else { $null }
        reconnects = $reconnects.Count; cardsAfterRejectedClear = $cardsAfter.Count
    }
}

function Test-RejectedReplace {
    $root = New-Root 'rejectedreplace'
    Write-Settings $root $true
    $server = Start-FakeServer 'rejectedreplace' 'ErrorOnFirstReplacement'
    $app = $null; $alive = $false; $ready = $false
    try {
        $app = Start-App $root @{ NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'ArtGap'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
        $ready = Wait-BenchReady $root
        [void] (Wait-Until { [bool] (@(Get-Activities (Read-Frames $server)) | Where-Object {
            $null -ne $_.Activity -and (Get-Prop $_.Activity 'details') -eq 'Fixture Song B' }) } 60)
        Start-Sleep -Seconds 3
        $alive = -not $app.HasExited
        [void] (Stop-App $app $root)
        Start-Sleep -Seconds 2
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['RejectedReplace'] = $frames
    Copy-AppLog $root 'rejectedreplace'
    $sets = @(Get-Activities $frames)
    $errorFrame = @($frames | Where-Object { $_.direction -eq 'out' -and $_.json -match '"evt":"ERROR"' }) | Select-Object -First 1
    $errorUtc = if ($errorFrame) { ConvertTo-UtcTime $errorFrame.utc } else { $null }
    $rejected = if ($errorUtc) { $sets | Where-Object { $null -ne $_.Activity -and $_.Utc -le $errorUtc } | Select-Object -Last 1 } else { $null }
    $after = @(if ($errorUtc) { $sets | Where-Object { $_.Utc -gt $errorUtc } })
    $rejectedJson = if ($rejected) { $rejected.Activity | ConvertTo-Json -Depth 16 -Compress } else { $null }
    Add-Check 'rejectedReplace.benchReady' $ready
    Add-Check 'rejectedReplace.noCrash' $alive
    Add-Check 'rejectedReplace.replacementRejected' ($null -ne $errorUtc -and $null -ne $rejected)
    Add-Check 'rejectedReplace.clearAfterRejection' ($after.Count -gt 0 -and $null -eq $after[0].Activity -and ($after[0].Utc - $errorUtc).TotalSeconds -le 3)
    Add-Check 'rejectedReplace.rejectedPayloadNotResent' ($null -ne $rejectedJson -and -not ($after | Where-Object {
        $null -ne $_.Activity -and ($_.Activity | ConvertTo-Json -Depth 16 -Compress) -eq $rejectedJson }))
    Add-Check 'rejectedReplace.nextSongPublished' ([bool] ($after | Where-Object { $null -ne $_.Activity -and (Get-Prop $_.Activity 'details') -eq 'Fixture Song B' }))
    $scenarioResults['RejectedReplace'] = [ordered]@{
        appPid = $app.Id; setsAfterRejection = @($after | ForEach-Object { if ($null -eq $_.Activity) { 'clear' } else { Get-Prop $_.Activity 'details' } })
        rejectionToFirstSendSeconds = if ($after.Count) { [Math]::Round(($after[0].Utc - $errorUtc).TotalSeconds, 3) } else { $null }
    }
}

function Test-SameTitle {
    $root = New-Root 'sametitle'
    Write-Settings $root $true
    $server = Start-FakeServer 'sametitle'
    $app = $null; $alive = $false; $ready = $false; $firstUtc = $null
    try {
        $app = Start-App $root @{ NATIVUNE_TEST_DISCORD_PAUSE_SECONDS = '20'
            NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'SameTitle'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
        $ready = Wait-BenchReady $root
        $firstUtc = Wait-FirstCard $server 60
        if (-not $firstUtc) { throw 'SameTitle: no paused card within 60 s.' }
        Wait-UntilUtc $firstUtc.AddSeconds(45)
        $alive = -not $app.HasExited
        [void] (Stop-App $app $root)
        Start-Sleep -Seconds 2
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['SameTitle'] = $frames
    Copy-AppLog $root 'sametitle'
    $sets = @(Get-Activities $frames)
    $first = $sets | Where-Object { $null -ne $_.Activity } | Select-Object -First 1
    $clear = if ($first) { $sets | Where-Object { $null -eq $_.Activity -and $_.Utc -gt $first.Utc } | Select-Object -First 1 } else { $null }
    $delay = if ($clear) { ($clear.Utc - $first.Utc).TotalSeconds } else { $null }
    $second = @($sets | Where-Object { $null -ne $_.Activity -and (Get-Prop $_.Activity 'state') -eq 'Second Artist' })
    Add-Check 'sameTitle.benchReady' $ready
    Add-Check 'sameTitle.noCrash' $alive
    Add-Check 'sameTitle.secondSongCardShown' ($second.Count -gt 0 -and (Get-Prop $second[0].Activity 'details') -eq 'Fixture Song A')
    Add-Check 'sameTitle.pauseDeadlineRestarted' ($null -ne $delay -and $delay -ge 25 -and $delay -le 40)
    $scenarioResults['SameTitle'] = [ordered]@{
        appPid = $app.Id; firstCardToClearSeconds = if ($null -ne $delay) { [Math]::Round($delay, 3) } else { $null }; secondSongCards = $second.Count
    }
}

function Test-ReaderGap {
    $root = New-Root 'readergap'
    Write-Settings $root $true
    $server = Start-FakeServer 'readergap'
    $app = $null; $alive = $false; $ready = $false; $firstUtc = $null
    $closeUtc = $null
    try {
        $app = Start-App $root @{ NATIVUNE_TEST_DISCORD_PAUSE_SECONDS = '20'
            NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'ReaderGap'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
        $ready = Wait-BenchReady $root
        $firstUtc = Wait-FirstCard $server 60
        if (-not $firstUtc) { throw 'ReaderGap: no paused card within 60 s.' }
        # The song returns at page 32 s; allow two reader ticks, debounce and the write gate after that.
        Wait-UntilUtc $firstUtc.AddSeconds(50)
        $alive = -not $app.HasExited
        $closeUtc = Stop-App $app $root
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['ReaderGap'] = $frames
    Copy-AppLog $root 'readergap'
    $sets = @(Get-Activities $frames | Where-Object { $null -eq $closeUtc -or $_.Utc -lt $closeUtc })
    $first = $sets | Where-Object { $null -ne $_.Activity } | Select-Object -First 1
    $gapClear = if ($first) { $sets | Where-Object { $null -eq $_.Activity -and $_.Utc -gt $first.Utc } | Select-Object -First 1 } else { $null }
    $after = @(if ($gapClear) { $sets | Where-Object { $null -ne $_.Activity -and $_.Utc -gt $gapClear.Utc } })
    Add-Check 'readerGap.benchReady' $ready
    Add-Check 'readerGap.noCrash' $alive
    # The page title vanishes at page 5 s; the 8 s hold plus a 5 s reader tick puts the clear well before 25 s.
    Add-Check 'readerGap.clearedDuringGap' ($null -ne $gapClear -and ($gapClear.Utc - $first.Utc).TotalSeconds -le 25)
    Add-Check 'readerGap.noCardAfterExpiredSongReturns' ($null -ne $gapClear -and $after.Count -eq 0)
    $scenarioResults['ReaderGap'] = [ordered]@{
        appPid = $app.Id; firstCardToGapClearSeconds = if ($gapClear) { [Math]::Round(($gapClear.Utc - $first.Utc).TotalSeconds, 3) } else { $null }
        cardsAfterGap = $after.Count
    }
}

function Test-LiveToggle {
    $root = New-Root 'livetoggle'
    Write-Settings $root $true
    $server = Start-FakeServer 'livetoggle'
    $app = $null; $alive = $false; $offUtc = $null; $onUtc = $null
    try {
        $app = Start-App $root
        if (-not (Wait-FirstCard $server)) { throw 'LiveToggle: no non-null SET_ACTIVITY within 90 s.' }
        Start-Sleep -Seconds 5
        $offUtc = Send-HookCommand $root 'command-discord-off'
        [void] (Wait-Until { [bool] (Get-FrameEvents (Read-Frames $server) 'disconnected' | Where-Object { (ConvertTo-UtcTime $_.utc) -gt $offUtc }) } 10)
        Start-Sleep -Seconds 8
        $onUtc = Send-HookCommand $root 'command-discord-on'
        [void] (Wait-Until { [bool] (@(Get-Activities (Read-Frames $server)) | Where-Object { $null -ne $_.Activity -and $_.Utc -gt $onUtc }) } 20)
        $alive = -not $app.HasExited
        [void] (Stop-App $app $root)
        Start-Sleep -Seconds 2
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['LiveToggle'] = $frames
    Copy-AppLog $root 'livetoggle'
    $utcOf = { param($f) ConvertTo-UtcTime $f.utc }
    $sets = @(Get-Activities $frames)
    $closed = Get-FrameEvents $frames 'disconnected' | Where-Object { (& $utcOf $_) -gt $offUtc } | Select-Object -First 1
    $closedUtc = if ($closed) { & $utcOf $closed } else { $null }
    $offClear = $closed -and [bool] ($sets | Where-Object { $null -eq $_.Activity -and $_.Utc -gt $offUtc -and $_.Utc -le $closedUtc })
    $offNoise = @(if ($closed -and $onUtc) { $frames | Where-Object { $t = & $utcOf $_; $t -gt $closedUtc -and $t -lt $onUtc -and
        ($_.direction -eq 'in' -or ($_.direction -eq 'event' -and $_.json -eq 'connected')) } })
    $reconnect = Get-FrameEvents $frames 'connected' | Where-Object { (& $utcOf $_) -gt $onUtc } | Select-Object -First 1
    $readyIndex = if ($reconnect) { [Array]::FindIndex([object[]] $frames, [Predicate[object]] { param($f)
        $f.direction -eq 'out' -and $f.json -like '*"READY"*' -and (ConvertTo-UtcTime $f.utc) -gt $onUtc }) } else { -1 }
    $readyUtc = if ($readyIndex -ge 0) { & $utcOf $frames[$readyIndex] } else { $null }
    $freshCard = if ($readyUtc) { $sets | Where-Object { $null -ne $_.Activity -and $_.Utc -gt $readyUtc } | Select-Object -First 1 } else { $null }
    Add-Check 'liveToggle.noCrash' $alive
    Add-Check 'liveToggle.offClearBeforeClose' ([bool] $offClear)
    Add-Check 'liveToggle.offConnectionClosed' ($null -ne $closed)
    Add-Check 'liveToggle.offNoFurtherFrames' ($null -ne $closed -and $offNoise.Count -eq 0)
    Add-Check 'liveToggle.onNewConnectionReady' ($null -ne $reconnect -and $null -ne $readyUtc)
    Add-Check 'liveToggle.onFreshCard' ($null -ne $freshCard -and (Get-Prop $freshCard.Activity 'details') -eq 'Fixture Song A')
    $scenarioResults['LiveToggle'] = [ordered]@{
        appPid = $app.Id; offToCloseSeconds = if ($closedUtc) { [Math]::Round(($closedUtc - $offUtc).TotalSeconds, 3) } else { $null }
        framesWhileOff = $offNoise.Count; onToCardSeconds = if ($freshCard) { [Math]::Round(($freshCard.Utc - $onUtc).TotalSeconds, 3) } else { $null }
    }
}

# The Discord toolbar button's UIA help text (the same string as its tooltip), or $null when not found.
function Get-DiscordHelpText([Diagnostics.Process] $Process) {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    $byPid = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty, $Process.Id)
    $byId = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::AutomationIdProperty, 'DiscordButton')
    foreach ($top in [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children, $byPid)) {
        $button = $top.FindFirst([Windows.Automation.TreeScope]::Descendants, $byId)
        if ($button) { return [string] $button.Current.HelpText }
    }
    $null
}

function Test-Locale {
    $root = New-Root 'locale'
    Write-Settings $root $true
    $server = Start-FakeServer 'locale'
    $app = $null; $alive = $false; $ready = $false
    $note = 'not in English'
    $texts = [ordered]@{}
    $marks = [ordered]@{}
    try {
        $app = Start-App $root @{ NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'Playing'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
        $ready = Wait-BenchReady $root
        if (-not (Wait-FirstCard $server)) { throw 'Locale: no non-null SET_ACTIVITY within 90 s.' }
        $texts.english = Get-DiscordHelpText $app
        $marks.fr = Send-HookCommand $root 'command-locale-fr'
        [void] (Wait-Until { (Get-DiscordHelpText $app) -like "*$note*" } 20)
        $texts.french = Get-DiscordHelpText $app
        [void] (Wait-Until { [bool] (@(Get-Activities (Read-Frames $server)) | Where-Object { $null -eq $_.Activity -and $_.Utc -gt $marks.fr }) } 25)
        $marks.off = Send-HookCommand $root 'command-discord-off'
        [void] (Wait-Until { (Get-DiscordHelpText $app) -like '*is off*' } 10)
        $texts.off = Get-DiscordHelpText $app
        $marks.on = Send-HookCommand $root 'command-discord-on'
        [void] (Wait-Until { (Get-DiscordHelpText $app) -like "*$note*" } 25)
        $texts.frenchAgain = Get-DiscordHelpText $app
        Start-Sleep -Seconds 6
        $marks.en = Send-HookCommand $root 'command-locale-en'
        [void] (Wait-Until { [bool] (@(Get-Activities (Read-Frames $server)) | Where-Object { $null -ne $_.Activity -and $_.Utc -gt $marks.en }) } 25)
        [void] (Wait-Until { (Get-DiscordHelpText $app) -notlike "*$note*" } 10)
        $texts.englishAgain = Get-DiscordHelpText $app
        $alive = -not $app.HasExited
        [void] (Stop-App $app $root)
        Start-Sleep -Seconds 2
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['Locale'] = $frames
    Copy-AppLog $root 'locale'
    $sets = @(Get-Activities $frames)
    $isA = { param($s) $null -ne $s.Activity -and (Get-Prop $s.Activity 'details') -eq 'Fixture Song A' }
    $cleared = $sets | Where-Object { $null -eq $_.Activity -and $_.Utc -gt $marks.fr -and $_.Utc -lt $marks.off } | Select-Object -First 1
    $cardsWhileFrench = @($sets | Where-Object { $null -ne $_.Activity -and $_.Utc -gt $marks.on -and $_.Utc -lt $marks.en })
    $freshCard = $sets | Where-Object { (& $isA $_) -and $_.Utc -gt $marks.en } | Select-Object -First 1
    Add-Check 'locale.noCrash' $alive
    Add-Check 'locale.benchReady' $ready
    Add-Check 'locale.englishTextNormal' ($texts.english -like '*is on; connected*' -and $texts.english -notlike "*$note*")
    Add-Check 'locale.frenchTextSaysCannotRead' ($texts.french -like '*is on; connected*' -and $texts.french -like '*cannot be read*' -and $texts.french -like "*$note*")
    Add-Check 'locale.frenchCardCleared' ($null -ne $cleared)
    Add-Check 'locale.offTextOnly' ($texts.off -like '*is off*' -and $texts.off -notlike "*$note*")
    Add-Check 'locale.onTextSaysCannotRead' ($texts.frenchAgain -like '*cannot be read*' -and $cardsWhileFrench.Count -eq 0)
    Add-Check 'locale.englishRestoresTextAndCard' ($null -ne $freshCard -and $texts.englishAgain -like '*is on; connected*' -and $texts.englishAgain -notlike "*$note*")
    $scenarioResults['Locale'] = [ordered]@{
        appPid = $app.Id; helpTexts = $texts
        clearSeconds = if ($cleared) { [Math]::Round(($cleared.Utc - $marks.fr).TotalSeconds, 3) } else { $null }
        cardsWhileFrench = $cardsWhileFrench.Count
        englishToCardSeconds = if ($freshCard) { [Math]::Round(($freshCard.Utc - $marks.en).TotalSeconds, 3) } else { $null }
    }
}

function Test-TrueQuit {
    $root = New-Root 'truequit'
    Write-Settings $root $true
    $server = Start-FakeServer 'truequit'
    $app = $null; $quitUtc = $null; $exited = $false; $exitSeconds = $null
    try {
        $app = Start-App $root
        if (-not (Wait-FirstCard $server)) { throw 'TrueQuit: no non-null SET_ACTIVITY within 90 s.' }
        Start-Sleep -Seconds 5
        $quitUtc = Send-HookCommand $root 'command-quit'
        $exited = $app.WaitForExit(5000)
        if ($exited) { $exitSeconds = ([DateTime]::UtcNow - $quitUtc).TotalSeconds }
        else { [void] (Stop-App $app $root) }
        Start-Sleep -Seconds 2
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['TrueQuit'] = $frames
    Copy-AppLog $root 'truequit'
    $sets = @(Get-Activities $frames)
    $closed = Get-FrameEvents $frames 'disconnected' | Where-Object { (ConvertTo-UtcTime $_.utc) -gt $quitUtc } | Select-Object -First 1
    $closedUtc = if ($closed) { ConvertTo-UtcTime $closed.utc } else { $null }
    $cardBeforeQuit = [bool] ($sets | Where-Object { $null -ne $_.Activity -and $_.Utc -lt $quitUtc -and (Get-Prop $_.Activity 'details') -eq 'Fixture Song A' })
    $quitClear = $closed -and [bool] ($sets | Where-Object { $null -eq $_.Activity -and $_.Utc -gt $quitUtc -and $_.Utc -le $closedUtc })
    Add-Check 'trueQuit.trackAPlayingBeforeQuit' $cardBeforeQuit
    Add-Check 'trueQuit.clearBeforeClose' ([bool] $quitClear)
    Add-Check 'trueQuit.exitWithin5sNoForceKill' $exited
    $scenarioResults['TrueQuit'] = [ordered]@{
        appPid = $app.Id; exitedWithoutForceKill = $exited; quitToExitSeconds = if ($null -ne $exitSeconds) { [Math]::Round($exitSeconds, 3) } else { $null }
        quitToCloseSeconds = if ($closedUtc) { [Math]::Round(($closedUtc - $quitUtc).TotalSeconds, 3) } else { $null }
    }
}

function Test-HiddenAndCompact {
    $root = New-Root 'hiddencompact'
    Write-Settings $root $true
    $server = Start-FakeServer 'hiddencompact'
    $app = $null; $alive = $false; $ready = $false; $snap = [ordered]@{}; $phaseSeconds = 20
    $readState = { param([string] $Label) $path = Join-Path (Get-BenchDirectory $root) "state-$Label.json"
        if (Test-Path -LiteralPath $path) { Get-Content -LiteralPath $path -Raw | ConvertFrom-Json } else { $null } }
    try {
        $app = Start-App $root @{ NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'Playing'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Hidden' }
        $ready = Wait-BenchReady $root
        if (-not $ready) { throw 'HiddenAndCompact: bench state Hidden not ready within 90 s.' }
        [void] (Wait-FirstCard $server 30)
        $snap['hidden-start'] = Get-HookSnapshot $root 'hidden-start'
        Start-Sleep -Seconds $phaseSeconds
        $snap['hidden-end'] = Get-HookSnapshot $root 'hidden-end'
        [void] (Send-HookCommand $root 'command-compact')
        Start-Sleep -Seconds 4
        $snap['compact-start'] = Get-HookSnapshot $root 'compact-start'
        Start-Sleep -Seconds $phaseSeconds
        $snap['compact-end'] = Get-HookSnapshot $root 'compact-end'
        [void] (Send-HookCommand $root 'command-full')
        Start-Sleep -Seconds 4
        $snap['full-start'] = Get-HookSnapshot $root 'full-start'
        Start-Sleep -Seconds $phaseSeconds
        $snap['full-end'] = Get-HookSnapshot $root 'full-end'
        $alive = -not $app.HasExited
        [void] (Stop-App $app $root)
        Start-Sleep -Seconds 2
    } finally { Stop-FakeServer $server }
    $frames = Read-Frames $server
    $framesByScenario['HiddenAndCompact'] = $frames
    Copy-AppLog $root 'hiddencompact'
    $hidden = Get-ReadCounts $snap['hidden-start'] $snap['hidden-end']
    $compact = Get-ReadCounts $snap['compact-start'] $snap['compact-end']
    $full = Get-ReadCounts $snap['full-start'] $snap['full-end']
    # ~5 s total-read cadence hidden/full (+-50 %, plus one boundary read); ~1 s while compact (+-30 %, plus one).
    # The compact upper bound also proves there is no second read stream.
    $fiveSecondCadence = { param($c) $null -ne $c.seconds -and $c.total -gt 0 -and $c.total -ge [Math]::Floor($c.seconds / 5 * 0.5) -and
        $c.total -le [Math]::Ceiling($c.seconds / 5 * 1.5) + 1 }
    $hiddenState = & $readState 'hidden-start'; $compactState = & $readState 'compact-start'; $fullState = & $readState 'full-start'
    $sets = @(Get-Activities $frames)
    $windowStart = if ($snap['hidden-start']) { ConvertTo-UtcTime $snap['hidden-start'].boundaryUtc } else { $null }
    $windowEnd = if ($snap['full-end']) { ConvertTo-UtcTime $snap['full-end'].boundaryUtc } else { $null }
    $inWindow = @(if ($windowStart -and $windowEnd) { $sets | Where-Object { $_.Utc -ge $windowStart -and $_.Utc -le $windowEnd } })
    # A card must be up by the end of the hidden phase (it may first arrive while hidden, after debounce).
    $hiddenEnd = if ($snap['hidden-end']) { ConvertTo-UtcTime $snap['hidden-end'].boundaryUtc } else { $null }
    $cardUp = [bool] $windowStart -and [bool] $windowEnd -and [bool] $hiddenEnd -and [bool] ($sets | Where-Object { $null -ne $_.Activity -and $_.Utc -le $hiddenEnd })
    Add-Check 'hiddenCompact.benchReady' $ready
    Add-Check 'hiddenCompact.noCrash' $alive
    Add-Check 'hiddenCompact.hiddenState' ($null -ne $hiddenState -and $hiddenState.appWindowVisible -eq $false -and $hiddenState.compact -eq $false)
    Add-Check 'hiddenCompact.hiddenReads5s' ([bool] (& $fiveSecondCadence $hidden))
    Add-Check 'hiddenCompact.hiddenCardUp' ($cardUp -and -not ($inWindow | Where-Object { $null -eq $_.Activity }))
    Add-Check 'hiddenCompact.compactState' ($null -ne $compactState -and $compactState.compact -eq $true -and $compactState.windowVisible -eq $true)
    Add-Check 'hiddenCompact.compactReads1s' ($null -ne $compact.seconds -and $compact.total -ge [Math]::Floor($compact.seconds * 0.7) -and
        $compact.total -le [Math]::Ceiling($compact.seconds * 1.3) + 1)
    Add-Check 'hiddenCompact.cardContinuity' ($cardUp -and -not ($inWindow | Where-Object {
        $null -eq $_.Activity -or (Get-Prop $_.Activity 'details') -ne 'Fixture Song A' }))
    Add-Check 'hiddenCompact.fullState' ($null -ne $fullState -and $fullState.compact -eq $false -and $fullState.windowVisible -eq $true)
    Add-Check 'hiddenCompact.fullReads5s' ([bool] (& $fiveSecondCadence $full))
    # Diagnostics label each read by demand: presence-only in Hidden/Full, Compact while Compact is active
    # (one read at a phase boundary may carry the previous label).
    Add-Check 'hiddenCompact.readModesLabelled' ($hidden.presence -gt 0 -and $hidden.compact -le 1 -and $full.presence -gt 0 -and
        $full.compact -le 1 -and $compact.compact -gt 0 -and $compact.presence -le 1)
    $scenarioResults['HiddenAndCompact'] = [ordered]@{
        appPid = $app.Id; phaseSeconds = $phaseSeconds; hiddenReads = $hidden; compactReads = $compact; fullReads = $full
        setsInWindow = $inWindow.Count; snapshotsTaken = @($snap.Keys | Where-Object { $snap[$_] }).Count
    }
}

# -Parallel: groups run as child processes of this script (own prefix, server and roots), longest first.
# Order and grouping come from measured serial times (run 20260927T085304Z): Timeline+Disable ~260 s,
# ProductionGate ~150, PauseExpiry ~95, Reconnect ~90, HiddenAndCompact ~85, then the short ones.
$parallelGroups = @(@('Timeline', 'Disable'), @('ProductionGate'), @('PauseExpiry'), @('Reconnect'), @('HiddenAndCompact'),
    @('ArtGap'), @('ReaderGap'), @('RejectedClear'), @('SameTitle'), @('ButtonOff'), @('RejectedReplace'), @('Locale'), @('Migration'), @('Absent'),
    @('LiveToggle'), @('TrueQuit'))
$childProcesses = [Collections.Generic.List[Diagnostics.Process]]::new()

function Invoke-ParallelGroups {
    $partsRoot = Join-Path $runDirectory 'parts'
    $queue = [Collections.Generic.Queue[object]]::new()
    foreach ($group in $parallelGroups) {
        $names = @($group | Where-Object { $_ -in $selected })
        if ($names.Count) { $queue.Enqueue($names) }
    }
    $running = [Collections.Generic.List[object]]::new()
    $durations = [ordered]@{}
    $childTimeout = [TimeSpan]::FromMinutes(15)
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $Parallel) {
            $names = $queue.Dequeue()
            $label = $names -join '+'
            $out = Join-Path $partsRoot ($label.ToLowerInvariant())
            [IO.Directory]::CreateDirectory($out) | Out-Null
            $arguments = @('-NoProfile', '-File', $PSCommandPath, '-Scenario', ($names -join ','), '-SkipPublish', '-OutputDirectory', $out,
                '-TimelineSeconds', "$TimelineSeconds", '-Parallel', '1')
            if ($CopyWebView2Runtime) { $arguments += '-CopyWebView2Runtime' }
            if ($KeepRoot) { $arguments += '-KeepRoot' }
            $process = Start-Process -FilePath pwsh -ArgumentList $arguments -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput (Join-Path $out 'stdout.txt') -RedirectStandardError (Join-Path $out 'stderr.txt')
            $childProcesses.Add($process)
            $running.Add([pscustomobject]@{ Label = $label; Names = $names; Out = $out; Process = $process; Started = [DateTime]::UtcNow })
        }
        Start-Sleep -Milliseconds 500
        foreach ($child in @($running)) {
            $elapsed = [DateTime]::UtcNow - $child.Started
            if (-not $child.Process.HasExited -and $elapsed -lt $childTimeout) { continue }
            if (-not $child.Process.HasExited) {
                & taskkill /PID $child.Process.Id /T /F 2>&1 | Out-Null
                Add-Check "runner.$($child.Label).timedOut" $false
            }
            $durations[$child.Label] = [Math]::Round($elapsed.TotalSeconds, 1)
            [void] $running.Remove($child)
            Merge-ChildRun $child.Label $child.Out $child.Names
        }
    }
    $scenarioResults['parallel'] = [ordered]@{ parallel = $Parallel; groupSeconds = $durations }
}

function Merge-ChildRun([string] $Label, [string] $Out, [string[]] $Names) {
    $reportFile = Get-ChildItem -LiteralPath $Out -Recurse -Filter report.json -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $reportFile) { Add-Check "runner.$Label.completed" $false; return }
    $child = [IO.File]::ReadAllText($reportFile.FullName) | ConvertFrom-Json -Depth 32
    foreach ($p in $child.checks.PSObject.Properties) {
        $checks[$p.Name] = if ($checks.Contains($p.Name)) { [bool] $checks[$p.Name] -and [bool] $p.Value } else { [bool] $p.Value }
    }
    foreach ($p in $child.scenarios.PSObject.Properties) {
        $key = if ($p.Name -in 'errors', 'error') { "$($p.Name).$Label" } else { $p.Name }
        $scenarioResults[$key] = $p.Value
    }
    $framesFile = Join-Path $reportFile.DirectoryName 'frames.json'
    if (Test-Path -LiteralPath $framesFile) {
        $frames = [IO.File]::ReadAllText($framesFile) | ConvertFrom-Json -Depth 32
        foreach ($p in $frames.PSObject.Properties) { $framesByScenario[$p.Name] = $p.Value }
    }
    # Every requested scenario must have reported its results; a child that stopped early fails the run.
    foreach ($name in $Names) {
        if (-not $child.scenarios.PSObject.Properties[$name]) { Add-Check "runner.$name.reported" $false }
    }
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
    $scenarioErrors = [ordered]@{}
    $runScenario = { param([string] $Name, [scriptblock] $Body)
        if ($Name -notin $selected) { return }
        try { & $Body } catch {
            Add-Check "runner.$Name.completed" $false
            $scenarioErrors[$Name] = [ordered]@{ message = $_.Exception.Message; scriptStackTrace = $_.ScriptStackTrace
                position = "$($_.InvocationInfo.PositionMessage)" }
        }
    }
    $groupCount = @($parallelGroups | Where-Object { @($_ | Where-Object { $_ -in $selected }).Count -gt 0 }).Count
    if ($Parallel -gt 1 -and $groupCount -gt 1) {
        Invoke-ParallelGroups
    } else {
    & $runScenario 'Timeline' { $script:timelineRoot = Test-Timeline }
    & $runScenario 'Absent' { Test-Absent }
    & $runScenario 'Disable' { Test-Disable $script:timelineRoot }
    & $runScenario 'Migration' { Test-Migration }
    & $runScenario 'Reconnect' { Test-Reconnect }
    & $runScenario 'ButtonOff' { Test-ButtonOff }
    & $runScenario 'ProductionGate' { Test-ProductionGate }
    & $runScenario 'PauseExpiry' { Test-PauseExpiry }
    & $runScenario 'ArtGap' { Test-ArtGap }
    & $runScenario 'RejectedClear' { Test-RejectedClear }
    & $runScenario 'RejectedReplace' { Test-RejectedReplace }
    & $runScenario 'SameTitle' { Test-SameTitle }
    & $runScenario 'ReaderGap' { Test-ReaderGap }
    & $runScenario 'LiveToggle' { Test-LiveToggle }
    & $runScenario 'TrueQuit' { Test-TrueQuit }
    & $runScenario 'HiddenAndCompact' { Test-HiddenAndCompact }
    & $runScenario 'Locale' { Test-Locale }
    }
    if ($scenarioErrors.Count -gt 0) { Add-Check 'runner.completed' $false; $scenarioResults['errors'] = $scenarioErrors }
} catch {
    Add-Check 'runner.completed' $false
    $scenarioResults['error'] = [ordered]@{ message = $_.Exception.Message; scriptStackTrace = $_.ScriptStackTrace }
} finally {
    foreach ($key in @($testEnv.Keys) + $benchEnvKeys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
    foreach ($child in $childProcesses) {
        try { if (-not $child.HasExited) { & taskkill /PID $child.Id /T /F 2>&1 | Out-Null } } catch { }
    }
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

# Count failures explicitly: piping the values into Where-Object yields a single $false for one failed check,
# and -not $false is $true, which is how a failed check (timeline.adWindowNoLinks, now adWindowNoSongLinks) once reported passed=true.
$failedChecks = @($checks.Keys | Where-Object { -not $checks[$_] })
$passed = $checks.Count -gt 0 -and $failedChecks.Count -eq 0
$report = [ordered]@{
    command = $commandLine; runId = $runId; appVersion = $appVersion; pipePrefix = $prefix
    scenarios = $scenarioResults; checks = $checks; passed = [bool] $passed
}
[IO.File]::WriteAllText((Join-Path $runDirectory 'report.json'), ($report | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $runDirectory 'frames.json'), ($framesByScenario | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$report | ConvertTo-Json -Depth 8
Write-Host "Report: $(Join-Path $runDirectory 'report.json')"
if (-not $passed) { exit 1 }
