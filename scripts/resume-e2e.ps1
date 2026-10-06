<# Real native-app resume acceptance, disposable signed-out profiles only. Never run alongside another Nativune E2E.
   pwsh -NoProfile -File scripts/resume-e2e.ps1 [-SkipPublish]
   Report + exact command: artifacts/resume-e2e/<UTC>/. Audio is measured at owned Core Audio sessions, not inferred from play(). #>
[CmdletBinding()]
param([switch] $SkipPublish, [string] $App = 'artifacts/resume-e2e/app',
    [ValidatePattern('^[A-Za-z0-9_-]{11}$')] [string] $VideoId = 'dQw4w9WgXcQ', [switch] $AllowOtherInstances)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$appPath = Join-Path $repo $App
$exe = Join-Path $appPath 'Nativune.exe'
$id = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$out = Join-Path $repo "artifacts/resume-e2e/$id"
$base = Join-Path $repo ".cache/resume-e2e/$id"
[void][IO.Directory]::CreateDirectory($out)
[void][IO.Directory]::CreateDirectory($base)
$command = "pwsh -NoProfile -File scripts/resume-e2e.ps1$(if ($SkipPublish) { ' -SkipPublish' }) -App $App -VideoId $VideoId$(if ($AllowOtherInstances) { ' -AllowOtherInstances' })"
[IO.File]::WriteAllText((Join-Path $out 'command.txt'), $command + "`n")
if (-not $SkipPublish) {
    & pwsh -NoProfile -File (Join-Path $repo 'scripts/dotnet.ps1') publish (Join-Path $repo 'src/Nativune/Nativune.csproj') --runtime win-x64 --self-contained false -p:DiscordPresenceTestHooks=true -o $appPath | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Hook publish failed.' }
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$rows = [Collections.Generic.List[object]]::new()
$script:sequence = 0
$script:run = $null
function Wait-For([scriptblock] $Test, [double] $Seconds = 8) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do { if (& $Test) { return $true }; Start-Sleep -Milliseconds 100 } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}
function Hook([string] $Name, $Value = $null, [double] $Seconds = 5) {
    $label = 'r' + (++$script:sequence).ToString('d5')
    $dir = Join-Path $script:run.root 'data/discord-bench'
    [void][IO.Directory]::CreateDirectory($dir)
    $request = Join-Path $dir "command-eq-$label.json"
    $response = Join-Path $dir "eq-$label.json"
    [IO.File]::WriteAllText("$request.tmp", (@{ command = $Name; value = $Value } | ConvertTo-Json -Depth 8 -Compress))
    [IO.File]::Move("$request.tmp", $request)
    if (-not (Wait-For { Test-Path -LiteralPath $response } $Seconds)) { throw "Hook timeout: $Name" }
    $answer = Get-Content -Raw $response | ConvertFrom-Json -Depth 16
    if (-not $answer.ok) { throw "Hook rejected: $Name ($($answer.error))" }
    return $answer.result
}
function New-Root([string] $Name, [bool] $Playing = $false, [bool] $Eq = $false, [bool] $BlockAds = $false) {
    $root = Join-Path $base $Name
    [void][IO.Directory]::CreateDirectory((Join-Path $root 'data'))
    $v = [regex]::Match((Get-Content -Raw (Join-Path $repo 'src/Nativune/BrowserPrivacy.cs')), 'ExtensionVersion\s*=\s*"([^"]+)"').Groups[1].Value
    [void][IO.Directory]::CreateDirectory((Join-Path $root '.tools/ubol'))
    Copy-Item (Join-Path $repo ".tools/ubol/$v") (Join-Path $root '.tools/ubol') -Recurse
    $settings = @{ Version = 7; X = 100; Y = 100; Width = 1100; Height = 760; Dpi = 96; Zoom = 1;
        TrayEnabled = $false; SleepInBackground = $false; StartCompact = $false; AutoCheckUpdates = $false;
        OutputVolume = 0.05; OutputMuted = $false; BlockAds = $BlockAds; DiscordPresence = $false;
        ObsOverlay = $false; BetterLyricsEnabled = $false; StartupDestination = 2; ResumeLaunch = $(if ($Playing) { 1 } else { 0 });
        Equalizer = @{ enabled = $Eq; selectedPresetId = 'flat'; gainsDb = @(0,0,0,0,0,0,0,0,0,0); manualPreampDb = 0; autoHeadroom = $true; customPresets = @() } }
    [IO.File]::WriteAllText((Join-Path $root 'data/settings.json'), ($settings | ConvertTo-Json -Depth 8))
    return $root
}
function Seed([string] $Root, [string] $Track = 'fixtureSngB', [double] $Position = 73.625, [double] $Duration = 185, [bool] $Ended = $false) {
    $bytes = [Text.Encoding]::UTF8.GetBytes((@{ version = 1; videoId = $Track; listId = $null; positionSeconds = $Position; durationSeconds = $Duration; ended = $Ended } | ConvertTo-Json -Compress))
    [IO.File]::WriteAllBytes((Join-Path $Root 'data/resume.dat'), [Security.Cryptography.ProtectedData]::Protect($bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser))
}
function Inspect([string] $Root) {
    $path = Join-Path $Root 'data/resume.dat'
    if (-not (Test-Path $path)) { return @{ exists = $false; valid = $false; isB = $false; position = 0 } }
    try {
        $data = [Security.Cryptography.ProtectedData]::Unprotect([IO.File]::ReadAllBytes($path), $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        $s = [Text.Encoding]::UTF8.GetString($data) | ConvertFrom-Json
        return @{ exists = $true; valid = $s.version -eq 1; isB = $s.videoId -ceq 'fixtureSngB'; position = $s.positionSeconds; ended = $s.ended }
    } catch { return @{ exists = $true; valid = $false; isB = $false; position = 0 } }
}
function Start-App([string] $Root, [hashtable] $Extra = @{}, [bool] $Autostart = $false) {
    if ($script:run) { throw 'Only one test instance may run.' }
    # -AllowOtherInstances only tolerates instances from another app folder (e.g. a separate bench); this harness never overlaps itself.
    $guard = if ($AllowOtherInstances) { [IO.Path]::GetFullPath($appPath) } else { $repo }
    $other = @(Get-CimInstance Win32_Process -Filter "Name='Nativune.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine -match [regex]::Escape($guard) })
    if ($other.Count) { throw 'Another project Nativune instance is running; test launch refused.' }
    $envs = @{ NATIVUNE_TEST_DISCORD_FIXTURE_PAGE = '1'; NATIVUNE_TEST_EQ_FIXTURE = '1'; NATIVUNE_TEST_RESUME_FIXTURE = '1';
        NATIVUNE_TEST_AUTOPLAY_POLICY = 'no-user-gesture-required'; NATIVUNE_TEST_DISCORD_CLIENT_ID = '100000000000000001';
        NATIVUNE_TEST_DISCORD_PIPE_PREFIX = ('nativune-test-' + [guid]::NewGuid().ToString('N') + '-discord-ipc-') }
    foreach ($key in $Extra.Keys) { $envs[$key] = $Extra[$key] }
    if ($Autostart) { $envs.NATIVUNE_TEST_AUTOSTART_MODE = '1' }
    $helper = Join-Path $base 'launch.ps1'; $spec = Join-Path $base 'launch.json'; $pidFile = Join-Path $base 'pid.json'
    Remove-Item $pidFile -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($helper, @'
param([string] $Spec)
$s = Get-Content -Raw $Spec | ConvertFrom-Json
foreach ($k in @('NATIVUNE_TEST_DISCORD_FIXTURE_PAGE','NATIVUNE_TEST_DISCORD_BENCH_PROFILE','NATIVUNE_TEST_DISCORD_BENCH_STATE','NATIVUNE_TEST_START_URI','NATIVUNE_TEST_EQ_REAL_MUSIC','NATIVUNE_TEST_RESUME_AD','NATIVUNE_TEST_RESUME_DELAY','WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS')) { [Environment]::SetEnvironmentVariable($k, [NullString]::Value, 'Process') }
foreach ($p in $s.env.PSObject.Properties) { [Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value, 'Process') }
 $args = @('web','--root',$s.root); if ($s.autostart) { $args += '--autostart' }
 $p = Start-Process $s.exe -ArgumentList $args -WorkingDirectory $s.app -PassThru
[IO.File]::WriteAllText($s.pidFile, (@{ processId = $p.Id } | ConvertTo-Json))
'@)
    [IO.File]::WriteAllText($spec, (@{ exe = $exe; app = $appPath; root = $Root; env = $envs; pidFile = $pidFile; autostart = $Autostart } | ConvertTo-Json -Depth 6))
    & runas.exe '/trustlevel:0x20000' "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$helper`" `"$spec`"" | Out-Null
    if (-not (Wait-For { Test-Path $pidFile } 15)) { throw 'De-elevated launch failed.' }
    $script:run = @{ root = $Root; pid = (Get-Content -Raw $pidFile | ConvertFrom-Json).processId }
    $script:last = $null
    # Before the first navigation Source is about:blank, which also reports otherDocument; only a resolved state counts.
    [void](Wait-For { try { $script:last = Hook 'resume-state'; $script:last.ready -or ($script:last.otherDocument -and $script:last.restoreState -cin @('Cancelled','Failed','Done')) } catch { $false } } 12)
}
function Stop-App {
    if (-not $script:run) { return }
    $r = $script:run
    try {
        [IO.File]::WriteAllText((Join-Path $r.root 'data/discord-bench/command-quit'), '')
        if (-not (Wait-For { -not (Get-Process -Id $r.pid -ErrorAction SilentlyContinue) } 8)) { throw 'Quit did not complete.' }
    } catch {
        Get-CimInstance Win32_Process -Filter "ParentProcessId=$($r.pid)" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Stop-Process -Id $r.pid -Force -ErrorAction SilentlyContinue
    }
    $script:run = $null
}
function State { Hook 'resume-state' }
function Await-Done {
    $script:last = $null
    [void](Wait-For { $script:last = State; $script:last.restoreState -in @('Done','Failed','Cancelled','Absent') } 11)
    return $script:last
}
function Audio { Hook 'resume-audio' }
function Row([int] $Number, [string] $Name, [scriptblock] $Test) {
    try { $e = & $Test; $rows.Add([ordered]@{ row = $Number; name = $Name; status = $(if ($e.pass) { 'PASS' } else { 'FAIL' }); evidence = $e }) }
    catch { $rows.Add([ordered]@{ row = $Number; name = $Name; status = 'FAIL'; reason = $_.Exception.Message }) }
    finally { Stop-App }
}
$paired = New-Root 'paired'
Row 1 'paired-track-checkpoint' {
    Start-App $paired
    [void](Hook 'resume-fixture' @{ track = 'A'; position = 131.25 })
    Start-Sleep -Seconds 2
    [void](Hook 'resume-fixture' @{ track = 'B'; position = 0 })
    Start-Sleep -Seconds 2
    [void](Hook 'resume-compact' @{ command = 'seek'; value = 73.625 })
    [void](Hook 'resume-compact' @{ command = 'toggle' })
    $s = State
    Start-Sleep -Milliseconds 2500
    $mid = Inspect $paired
    # A website-side seek on the same song right before quit: only the shutdown read can see it.
    [void](Hook 'resume-fixture' @{ track = 'B'; position = 120.5 })
    Stop-App
    $cp = Inspect $paired
    @{ pass = $mid.valid -and $mid.isB -and [math]::Abs($mid.position - 73.625) -le 1 -and $cp.valid -and $cp.isB -and [math]::Abs($cp.position - 120.5) -le 1.5;
        checkpointBeforeLastSeek = $mid; checkpoint = $cp; beforeQuit = $s }
}
Row 2 'wait-paused-and-compact-play' {
    $root = New-Root 'wait'; Seed $root
    Start-App $root
    $a = Await-Done; $silent = Audio
    Start-Sleep -Seconds 3
    $b = State
    [void](Hook 'resume-compact' @{ command = 'toggle' })
    Start-Sleep -Seconds 2
    $c = State; $audible = Audio
    Stop-App
    $modes = [Collections.Generic.List[object]]::new()
    foreach ($mode in @('compact','tray')) {
        $root = New-Root "wait-$mode"; Seed $root
        $file = Join-Path $root 'data/settings.json'; $prefs = Get-Content -Raw $file | ConvertFrom-Json -AsHashtable
        $prefs.StartCompact = $mode -eq 'compact'; $prefs.TrayEnabled = $mode -eq 'tray'; $prefs.AutostartMode = 2
        [IO.File]::WriteAllText($file, ($prefs | ConvertTo-Json -Depth 8))
        Start-App $root @{} ($mode -eq 'tray')
        $hiddenWait = $null; $hiddenPass = $true
        if ($mode -eq 'tray') {
            # A never-shown page gets no media; restoration must outlast the 10 s visible deadline and stay silent, then finish on Show.
            Start-Sleep -Seconds 13; $hiddenWait = State
            # No owned audio session yet is also silence; any other hook failure still fails the row.
            $hiddenLevel = try { Audio } catch { if ($_.Exception.Message -match 'session-path-unverified') { @{ count = 0; peak = 0 } } else { throw } }
            $hiddenPass = $hiddenWait.restoreState -cnotin @('Done','Failed','Cancelled','Absent') -and $hiddenWait.safetyMuted -and -not $hiddenWait.visible -and $hiddenWait.tray -and $hiddenLevel.peak -le 0.00001
            [void](Hook 'resume-show')
        }
        $start = Await-Done; Start-Sleep -Seconds 1; $stable = State; $level = Audio
        $modes.Add(@{ mode = $mode; pass = $hiddenPass -and $start.restoreState -ceq 'Done' -and $start.paused -and $start.isB -and [math]::Abs($start.position - 73.625) -le 1 -and [math]::Abs($stable.position - $start.position) -le 0.1 -and $level.peak -le 0.00001 -and $(if ($mode -eq 'compact') { $stable.compact } else { $stable.visible }); hiddenWait = $hiddenWait; restored = $start; stable = $stable; audio = $level })
        Stop-App
    }
    @{ pass = $a.restoreState -ceq 'Done' -and $a.isB -and $a.paused -and [math]::Abs($a.position - 73.625) -le 1 -and $b.paused -and [math]::Abs($a.position - $b.position) -le 0.1 -and $silent.peak -le 0.00001 -and -not $c.paused -and $c.position -gt $b.position + 1 -and $audible.count -gt 0 -and $audible.peak -gt 0.00001 -and @($modes | Where-Object { -not $_.pass }).Count -eq 0;
        restored = $a; stable = $b; silent = $silent; afterCompactPlay = $c; audible = $audible; startupModes = $modes }
}
Row 3 'start-playing-with-eq' {
    $root = New-Root 'playing' $true $true; Seed $root
    Start-App $root @{ NATIVUNE_TEST_RESUME_DELAY = '4000'; NATIVUNE_TEST_RESUME_STALL = '1' }
    $a = Await-Done; Start-Sleep -Seconds 1; $audio = Audio; $eq = Hook 'eq-status'
    @{ pass = $a.restoreState -ceq 'Done' -and $a.stallApplied -and $a.isB -and -not $a.paused -and $a.firstPlayingPosition -ge 73 -and $a.firstPlayingPosition -lt 75 -and $audio.count -gt 0 -and $audio.peak -gt 0.00001 -and $eq.attached -and $eq.contextState -ceq 'running'; state = $a; audio = $audio; eq = $eq }
}
Row 4 'failure-ad-ended-and-cancellation' {
    $root = New-Root 'corrupt'; [IO.File]::WriteAllBytes((Join-Path $root 'data/resume.dat'), [byte[]](1,2,3,4))
    Start-App $root @{ NATIVUNE_TEST_RESUME_HOME_MEDIA = '1' }; $bad = Await-Done
    # The guarded Home load removes the unreadable file so it cannot fail every launch.
    $corruptRemoved = Wait-For { -not (State).checkpointExists } 3
    [void](Hook 'resume-compact' @{ command = 'next' }); Start-Sleep -Seconds 2; Stop-App; $repaired = Inspect $root
    # Fresh profile: Home has no media at all. The guard must still finish (not time out) and remove the file.
    $root = New-Root 'corrupt-nomedia'; [IO.File]::WriteAllBytes((Join-Path $root 'data/resume.dat'), [byte[]](1,2,3,4))
    Start-App $root; $noMedia = Await-Done; $noMediaRemoved = Wait-For { -not (State).checkpointExists } 3; Stop-App
    $root = New-Root 'ad'; Seed $root
    Start-App $root @{ NATIVUNE_TEST_RESUME_AD = '1' }; Start-Sleep -Seconds 1; $ad = State
    [void](Hook 'resume-compact' @{ command = 'toggle' }); $adPlaying = State
    [void](Hook 'resume-fixture' @{ endAd = $true }); $post = Await-Done; Stop-App
    $root = New-Root 'ended' $true; Seed $root 'fixtureSngB' 184.25 185 $true
    Start-App $root; $ended = Await-Done
    $ui = Hook 'resume-settings' @{ destination = 0; launch = 0 }
    [void](Wait-For { -not (State).checkpointExists } 3); $disabled = State; Stop-App
    $root = New-Root 'cancel'; Seed $root
    Start-App $root @{ NATIVUNE_TEST_RESUME_DELAY = '4000' }
    [void](Hook 'resume-compact' @{ command = 'next' }); Start-Sleep -Seconds 5; $cancel = State
    Stop-App
    $root = New-Root 'ad-playing' $true; Seed $root
    Start-App $root @{ NATIVUNE_TEST_RESUME_AD = '1' }; Start-Sleep -Seconds 1; $naturalAd = State
    [void](Hook 'resume-fixture' @{ endAd = $true; ignoreT = $true }); $wrongStart = Await-Done; Stop-App
    $root = New-Root 'timeout'; Seed $root
    Start-App $root @{ NATIVUNE_TEST_RESUME_BAD_LINK = '1' }; $failed = Await-Done
    [void](Hook 'resume-compact' @{ command = 'toggle' }); Start-Sleep -Seconds 1; $recovered = State; Stop-App
    # After a failed Wait paused restore: a late site autoplay stays paused and muted; an in-page play with
    # trusted in-page input (key shortcut) releases the guard and plays.
    $root = New-Root 'failed-keyplay'; Seed $root
    Start-App $root @{ NATIVUNE_TEST_RESUME_BAD_LINK = '1' }; $failed2 = Await-Done
    [void](Hook 'resume-page-play' @{ key = $false }); Start-Sleep -Seconds 1; $lateAutoplay = State
    [void](Hook 'resume-page-play' @{ key = $true }); [void](Wait-For { (State).restoreState -ceq 'Cancelled' } 4); Start-Sleep -Seconds 1; $keyPlay = State
    Stop-App
    # Media duration differs from the saved track's (a shared signed-in timeline): never seek the element,
    # keep the site's whole-second t= position and pause.
    $root = New-Root 'shared-timeline'; Seed $root 'fixtureSngB' 73.625 400
    Start-App $root; $shared = Await-Done; Stop-App
    $root = New-Root 'account-redirect'; Seed $root
    Start-App $root @{ NATIVUNE_TEST_RESUME_REDIRECT = '1' }; Start-Sleep -Seconds 1; $redirect = State
    [void](Hook 'resume-visit'); [void](Wait-For { (State).isC } 5); Start-Sleep -Seconds 1; $afterRedirect = State; Stop-App
    $migrations = [Collections.Generic.List[object]]::new()
    foreach ($mode in @('missing','legacy-library','explicit-home')) {
        $root = New-Root $mode; Seed $root
        $file = Join-Path $root 'data/settings.json'; $prefs = Get-Content -Raw $file | ConvertFrom-Json -AsHashtable
        if ($mode -eq 'missing') { [void]$prefs.Remove('StartupDestination'); [void]$prefs.Remove('ResumeLaunch') }
        if ($mode -eq 'legacy-library') {
            [void]$prefs.Remove('StartupDestination'); [void]$prefs.Remove('ResumeLaunch')
            $prefs.RestoreSection = $true; $prefs.LastSection = 'library'
        }
        if ($mode -eq 'explicit-home') { $prefs.StartupDestination = 0; $prefs.ResumeLaunch = 1; $prefs.RestoreSection = $true; $prefs.LastSection = 'library' }
        [IO.File]::WriteAllText($file, ($prefs | ConvertTo-Json -Depth 8))
        Start-App $root; $s = Await-Done; $screen = Hook 'resume-settings'
        $expected = @{ missing = 2; 'legacy-library' = 1; 'explicit-home' = 0 }[$mode]
        $migrations.Add(@{ mode = $mode; pass = $s.destination -eq $expected -and $screen.destination -eq $expected -and $screen.accessible -and $screen.shown -and $(if ($mode -eq 'missing') { $s.paused -and $s.isB -and $s.launch -eq 0 } elseif ($mode -eq 'explicit-home') { $s.launch -eq 1 -and -not $s.checkpointExists } else { -not $s.checkpointExists }); state = $s; ui = $screen })
        Stop-App
    }
    $checks = @{
        corruptHome = $bad.home -and $bad.paused -and $bad.status -like '*Saved song could not be restored*'
        corruptRemoved = $corruptRemoved
        corruptNoMedia = $noMedia.restoreState -ceq 'Done' -and $noMedia.home -and -not $noMedia.safetyMuted -and $noMediaRemoved
        corruptRecovery = $repaired.valid -and $repaired.isB -and $repaired.position -lt 5
        adPaused = $ad.isAd -and $ad.paused -and $ad.seekCount -eq 0 -and $ad.status -like '*Ad paused*'
        adPlay = -not $adPlaying.paused -and -not $adPlaying.coreMuted
        afterAd = $post.restoreState -ceq 'Done' -and $post.isB -and $post.paused -and [math]::Abs($post.position - 73.625) -le 1
        ended = $ended.isB -and $ended.paused -and [math]::Abs($ended.position - 184.25) -le 1
        settingsClear = $ui.shown -and $ui.accessible -and -not $disabled.checkpointExists
        nextCancellation = $cancel.restoreState -ceq 'Cancelled' -and $cancel.isC -and $cancel.position -lt 15 -and $cancel.seekCount -eq 0
        startPlayingAd = $naturalAd.isAd -and -not $naturalAd.paused -and $naturalAd.seekCount -eq 0
        wrongPosition = $wrongStart.restoreState -ceq 'Failed' -and -not $wrongStart.paused -and $wrongStart.seekCount -eq 0 -and $wrongStart.status -like '*saved position*'
        timeout = $failed.restoreState -ceq 'Failed' -and $failed.safetyMuted -and $failed.status -like '*Playback is muted*'
        recovery = $recovered.restoreState -ceq 'Cancelled' -and -not $recovered.coreMuted -and -not $recovered.paused
        failedLateAutoplay = $failed2.restoreState -ceq 'Failed' -and $lateAutoplay.restoreState -ceq 'Failed' -and $lateAutoplay.paused -and $lateAutoplay.safetyMuted
        failedKeyPlay = $keyPlay.restoreState -ceq 'Cancelled' -and -not $keyPlay.paused -and -not $keyPlay.coreMuted -and -not $keyPlay.safetyMuted
        sharedTimeline = $shared.restoreState -ceq 'Done' -and $shared.isB -and $shared.paused -and $shared.seekCount -eq 0 -and [math]::Abs($shared.position - 73) -le 0.5 -and -not $shared.coreMuted
        migrations = @($migrations | Where-Object { -not $_.pass }).Count -eq 0
        accountRedirect = $redirect.otherDocument -and $redirect.restoreState -ceq 'Cancelled' -and -not $redirect.coreMuted -and $afterRedirect.isC -and -not $afterRedirect.coreMuted -and $afterRedirect.position -lt 10 -and $afterRedirect.seekCount -eq 0
    }
    @{ pass = @($checks.Values | Where-Object { -not $_ }).Count -eq 0; checks = $checks;
        corrupt = $bad; corruptNoMedia = $noMedia; repairedCheckpoint = $repaired; ad = $ad; adPlaying = $adPlaying; afterAd = $post;
        failedLateAutoplay = $lateAutoplay; failedKeyPlay = $keyPlay; sharedTimeline = $shared;
        ended = $ended; settingsUi = $ui; disabled = $disabled; cancelled = $cancel; startPlayingAd = $naturalAd;
        wrongPosition = $wrongStart; timeout = $failed; recovered = $recovered; migrations = $migrations;
        accountRedirect = $redirect; afterRedirect = $afterRedirect }
}
try {
    # Match the existing real-site probe's explicit disposable-profile ad-filter opt-in; production default remains off.
    $root = New-Root 'real' $false $false $true; Seed $root $VideoId 60.625 213
    $realEnv = @{ NATIVUNE_TEST_DISCORD_FIXTURE_PAGE = '0'; NATIVUNE_TEST_RESUME_FIXTURE = '0'; NATIVUNE_TEST_EQ_REAL_MUSIC = '1' }
    Start-App $root $realEnv
    $samples = [Collections.Generic.List[object]]::new()
    $realStart = [DateTime]::UtcNow
    do { $s = State; $samples.Add($s); Start-Sleep -Seconds 2 } while (([DateTime]::UtcNow - $realStart).TotalSeconds -lt 20)
    $ready = @($samples | Where-Object { $_.ready -and $_.duration -gt 0 -and $_.restoreState -ceq 'Done' })
    $blocked = $ready.Count -eq 0 -and @($samples | Where-Object { $_.networkFailed }).Count -gt 0
    $held = $ready.Count -ge 2 -and @($ready | Where-Object { -not $_.paused -or [math]::Abs($_.position - 60.625) -gt 1 }).Count -eq 0
    $guarded = @($samples | Where-Object { $_.restoreState -cne 'Done' -and -not $_.safetyMuted }).Count -eq 0
    Stop-App
    $root = New-Root 'real-t' $true $false $true; Seed $root $VideoId 60.625 213
    $file = Join-Path $root 'data/settings.json'; $prefs = Get-Content -Raw $file | ConvertFrom-Json -AsHashtable; $prefs.OutputMuted = $true
    [IO.File]::WriteAllText($file, ($prefs | ConvertTo-Json -Depth 8))
    Start-App $root $realEnv; $urlOnly = Await-Done
    # The site may rewrite the address after load, so t= is optional evidence; the first played position is the proof.
    $urlPass = $urlOnly.restoreState -ceq 'Done' -and ($null -eq $urlOnly.timeParameter -or $urlOnly.timeParameter -eq 60) -and $urlOnly.firstPlayingPosition -ge 59.625 -and $urlOnly.firstPlayingPosition -le 61.625
    $blocked = $blocked -or $urlOnly.networkFailed
    $pass = $held -and $guarded -and $urlPass
    $rows.Add([ordered]@{ row = 5; name = 'signed-out-real-site'; blockAds = $true; status = $(if ($blocked) { 'BLOCKED' } elseif ($pass) { 'PASS' } else { 'FAIL' }); reason = $(if ($blocked) { 'Official Music network navigation/media failed.' } else { $null }); samples = $samples; urlOnly = $urlOnly; urlOnlyOutputMuted = $true })
} catch { $rows.Add([ordered]@{ row = 5; name = 'signed-out-real-site'; status = 'FAIL'; reason = $_.Exception.Message }) }
finally { Stop-App }
$clock.Stop()
$passed = @($rows | Where-Object { $_.status -eq 'FAIL' }).Count -eq 0 -and $rows.Count -eq 5
$report = [ordered]@{ generatedUtc = [DateTime]::UtcNow.ToString('o'); passed = $passed; runtimeSeconds = [math]::Round($clock.Elapsed.TotalSeconds, 2); command = $command; signedIn = $false; blockAds = $false; rows = $rows }
[IO.File]::WriteAllText((Join-Path $out 'report.json'), ($report | ConvertTo-Json -Depth 16))
$rows | ForEach-Object { Write-Host "$($_.status) row $($_.row): $($_.name)" }
Write-Host (Join-Path $out 'report.json')
if (-not $passed) { exit 1 }
