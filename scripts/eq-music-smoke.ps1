<#
EQ Gate C: signed-out smoke test on the REAL music.youtube.com site, using the hook build of the app.
The page is not intercepted (NATIVUNE_TEST_DISCORD_FIXTURE_PAGE is not set). The EQ hooks expose status and
the post-graph RMS collector. The disposable root lives under .cache/eq-music-smoke, and the output is muted
at the Core Audio session, which sits after the EQ graph, so the measurement is unaffected.
No PCM, titles, URLs or account data are recorded.

  pwsh -NoProfile -File scripts/eq-music-smoke.ps1 -Action Start   # then start a track with a real click in the window
  pwsh -NoProfile -File scripts/eq-music-smoke.ps1 -Action Check   # writes artifacts/eq-music-smoke/<UTC>/report.json
  pwsh -NoProfile -File scripts/eq-music-smoke.ps1 -Action Stop
Requires the hook build at artifacts/eq-e2e/app (pwsh -NoProfile -File scripts/eq-e2e.ps1 publishes it).
#>
[CmdletBinding()]
param([Parameter(Mandatory)] [ValidateSet('Start', 'Check', 'Stop')] [string] $Action)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$root = Join-Path $repo '.cache/eq-music-smoke/root'
$app = Join-Path $repo 'artifacts/eq-e2e/app'
$exe = Join-Path $app 'Nativune.exe'
$state = Join-Path $repo '.cache/eq-music-smoke/state.json'

function Wait-For([scriptblock] $Condition, [double] $Seconds = 15) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 200 } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}
$script:sequence = [int](Get-Date -UFormat %s) % 100000
function Hook([string] $Command, $Value = $null) {
    $label = 's' + (++$script:sequence).ToString('d6')
    $dir = Join-Path $root 'data/discord-bench'
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $request = Join-Path $dir "command-eq-$label.json"; $response = Join-Path $dir "eq-$label.json"
    [IO.File]::WriteAllText("$request.tmp", (@{ command = $Command; value = $Value } | ConvertTo-Json -Depth 16 -Compress))
    [IO.File]::Move("$request.tmp", $request)
    if (-not (Wait-For { Test-Path -LiteralPath $response } 15)) { throw "EQ command $Command timed out." }
    $answer = Get-Content -Raw -LiteralPath $response | ConvertFrom-Json -Depth 32
    if (-not $answer.ok) { throw "EQ command $Command failed: $($answer.error)" }
    return $answer.result
}

switch ($Action) {
    'Start' {
        if (-not (Test-Path -LiteralPath $exe)) { throw "Hook build missing: $exe" }
        if (Test-Path -LiteralPath (Split-Path $root)) { Remove-Item -LiteralPath (Split-Path $root) -Recurse -Force }
        [IO.Directory]::CreateDirectory((Join-Path $root 'data')) | Out-Null
        $ubolVersion = [regex]::Match((Get-Content -Raw (Join-Path $repo 'src/Nativune/BrowserPrivacy.cs')), 'ExtensionVersion\s*=\s*"([^"]+)"').Groups[1].Value
        [IO.Directory]::CreateDirectory((Join-Path $root '.tools/ubol')) | Out-Null
        Copy-Item -LiteralPath (Join-Path $repo ".tools/ubol/$ubolVersion") -Destination (Join-Path $root '.tools/ubol') -Recurse
        $settings = @{ Version = 8; X = 100; Y = 100; Width = 1280; Height = 800; Dpi = 96; Zoom = 1; TrayEnabled = $false
            SleepInBackground = $false; StartCompact = $false; AutoCheckUpdates = $false; OutputVolume = 0.05; OutputMuted = $true
            BlockAds = $false; DiscordPresence = $false; ObsOverlay = $false; BetterLyricsEnabled = $false
            Equalizer = @{ enabled = $true; selectedPresetId = 'bass-boost'; gainsDb = @(6, 5, 4, 2, 0, 0, 0, 0, 0, 0)
                manualPreampDb = 0; autoHeadroom = $true; customPresets = @() } }
        [IO.File]::WriteAllText((Join-Path $root 'data/settings.json'), ($settings | ConvertTo-Json -Depth 8))
        $env = @{ NATIVUNE_TEST_EQ_FIXTURE = '1'; NATIVUNE_TEST_EQ_REAL_MUSIC = '1'; NATIVUNE_TEST_DISCORD_CLIENT_ID = '100000000000000001'
            NATIVUNE_TEST_DISCORD_PIPE_PREFIX = ('nativune-test-' + [guid]::NewGuid().ToString('N') + '-discord-ipc-') }
        $helper = Join-Path (Split-Path $root) 'launch.ps1'; $spec = Join-Path (Split-Path $root) 'launch.json'; $pidFile = Join-Path (Split-Path $root) 'pid.json'
        [IO.File]::WriteAllText($helper, @'
param([string] $Spec)
$s = Get-Content -Raw -LiteralPath $Spec | ConvertFrom-Json
foreach ($k in @('NATIVUNE_TEST_DISCORD_FIXTURE_PAGE','NATIVUNE_TEST_DISCORD_BENCH_PROFILE','NATIVUNE_TEST_DISCORD_BENCH_STATE','WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS')) { [Environment]::SetEnvironmentVariable($k, [NullString]::Value, 'Process') }
foreach ($p in $s.env.PSObject.Properties) { [Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value, 'Process') }
$p = Start-Process -FilePath $s.exe -ArgumentList @('web', '--root', $s.root) -WorkingDirectory $s.app -PassThru
[IO.File]::WriteAllText($s.pidFile, (@{ processId = $p.Id } | ConvertTo-Json))
'@)
        [IO.File]::WriteAllText($spec, (@{ exe = $exe; app = $app; root = $root; env = $env; pidFile = $pidFile } | ConvertTo-Json -Depth 6))
        & runas.exe '/trustlevel:0x20000' "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$helper`" `"$spec`"" | Out-Null
        if (-not (Wait-For { Test-Path -LiteralPath $pidFile } 30)) { throw 'Restricted-token launch wrote no PID.' }
        Copy-Item -LiteralPath $pidFile -Destination $state -Force
        Write-Host "Started PID $((Get-Content -Raw $pidFile | ConvertFrom-Json).processId). Start a track with a real click, then run -Action Check."
    }
    'Check' {
        $rows = [Collections.Generic.List[object]]::new()
        $status = Hook 'eq-status'
        $media = Hook 'eq-media'
        $rows.Add([ordered]@{ name = 'real-music.attached-active'; pass = ($status.state -ceq 'active' -and $status.attached -and $status.ctx); evidence = $status })
        $rows.Add([ordered]@{ name = 'real-music.blob-source-playing'; pass = (-not $media.paused -and $media.currentSrc.StartsWith('blob:https://music.youtube.com/')); evidence = @{ paused = $media.paused; blob = $media.currentSrc.StartsWith('blob:https://music.youtube.com/') } })
        $t0 = $media.currentTime; Start-Sleep -Seconds 3; $t1 = (Hook 'eq-media').currentTime
        $rows.Add([ordered]@{ name = 'real-music.playback-continues'; pass = ($t1 - $t0 -gt 2); evidence = @{ advancedSeconds = [math]::Round($t1 - $t0, 2) } })
        # The worklet collector can be blocked by the real site's CSP; use the hook AnalyserNode RMS read instead.
        $rmsResult = Hook 'eq-rms'
        $rows.Add([ordered]@{ name = 'real-music.post-graph-not-silent'; pass = ($rmsResult.ok -and $rmsResult.contextState -ceq 'running' -and $rmsResult.maxRms -gt 1e-4); evidence = $rmsResult })
        $rows.Add([ordered]@{ name = 'real-music.no-protected-media'; pass = (-not $status.encrypted -and -not $status.mediaKeys); evidence = @{ encrypted = $status.encrypted; mediaKeys = $status.mediaKeys } })
        $out = Join-Path $repo ('artifacts/eq-music-smoke/' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
        [IO.Directory]::CreateDirectory($out) | Out-Null
        $report = [ordered]@{ generatedUtc = [DateTime]::UtcNow.ToString('o'); signedIn = $false; rows = $rows }
        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out 'report.json') -Encoding UTF8
        $failed = @($rows | Where-Object { -not $_.pass })
        foreach ($r in $rows) { Write-Host ("{0} {1}" -f $(if ($r.pass) { 'PASS' } else { 'FAIL' }), $r.name) }
        Write-Host "Report: $out\report.json"
        if ($failed.Count) { exit 1 }
    }
    'Stop' {
        $dir = Join-Path $root 'data/discord-bench'
        if (Test-Path -LiteralPath $dir) { [IO.File]::WriteAllText((Join-Path $dir 'command-quit'), 'go') }
        if (Test-Path -LiteralPath $state) {
            $id = (Get-Content -Raw $state | ConvertFrom-Json).processId
            $p = Get-Process -Id $id -ErrorAction SilentlyContinue
            if ($p -and -not $p.WaitForExit(8000)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        }
    }
}
