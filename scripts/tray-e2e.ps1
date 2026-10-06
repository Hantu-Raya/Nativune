<#
Tray icon recovery E2E (about 40 s). Drives the hook build on the offline fixture page in a disposable root
under .cache/tray-e2e, de-elevated like a normal launch. Whether the icon exists is asked of the shell itself
(NIM_MODIFY of the unchanged tooltip succeeds only for a registered icon), not read from the app's flags.

Rows:
  baseline        icon wanted, visible and registered with the shell after startup
  shell-restart   the shell forgets the icon, then TaskbarCreated arrives: icon is back within 3 s
  slow-shell      same, but the first 2 re-adds fail (ERROR_TIMEOUT): icon missing at first and Close may not
                  hide (visible=false), then restored by the 1 s + 2 s retries within 8 s; log has the codes
  version-fail    the re-add succeeds but the version-4 handshake fails: the icon is rolled back and not
                  usable (visible=false), then restored by the 1 s retry
  slow-startup    a new launch whose first 2 adds fail: Tray stays enabled and the icon appears within 8 s

  pwsh -NoProfile -File scripts/tray-e2e.ps1 [-SkipPublish]   # writes artifacts/tray-e2e/<UTC>/report.json
#>
[CmdletBinding()]
param([switch] $SkipPublish, [string] $App = 'artifacts/tray-e2e/app')
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$app = Join-Path $repo $App
$exe = Join-Path $app 'Nativune.exe'
$base = Join-Path $repo '.cache/tray-e2e'
$out = Join-Path $repo ('artifacts/tray-e2e/' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ'))
if (-not $SkipPublish) {
    & pwsh -NoProfile -File (Join-Path $repo 'scripts/dotnet.ps1') publish (Join-Path $repo 'src/Nativune/Nativune.csproj') `
        --runtime win-x64 --self-contained false -p:DiscordPresenceTestHooks=true -o $app | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Hook publish failed ($LASTEXITCODE)." }
}
if (-not (Test-Path -LiteralPath $exe)) { throw "Hook build missing: $exe" }
[IO.Directory]::CreateDirectory($out) | Out-Null

function Wait-For([scriptblock] $Condition, [double] $Seconds) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 100 } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}
$script:sequence = 0
function Hook([string] $Root, [string] $Command, $Value = $null) {
    $label = 't' + (++$script:sequence).ToString('d6')
    $dir = Join-Path $Root 'data/discord-bench'
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $request = Join-Path $dir "command-eq-$label.json"; $response = Join-Path $dir "eq-$label.json"
    [IO.File]::WriteAllText("$request.tmp", (@{ command = $Command; value = $Value } | ConvertTo-Json -Compress))
    [IO.File]::Move("$request.tmp", $request)
    if (-not (Wait-For { Test-Path -LiteralPath $response } 10)) { throw "Hook $Command timed out." }
    $answer = Get-Content -Raw -LiteralPath $response | ConvertFrom-Json
    if (-not $answer.ok) { throw "Hook $Command failed: $($answer.error)" }
    return $answer.result
}
function Start-App([string] $Name, [hashtable] $Extra = @{}) {
    $root = Join-Path $base $Name
    if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    [IO.Directory]::CreateDirectory((Join-Path $root 'data')) | Out-Null
    $ubol = [regex]::Match((Get-Content -Raw (Join-Path $repo 'src/Nativune/BrowserPrivacy.cs')), 'ExtensionVersion\s*=\s*"([^"]+)"').Groups[1].Value
    [IO.Directory]::CreateDirectory((Join-Path $root '.tools/ubol')) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo ".tools/ubol/$ubol") -Destination (Join-Path $root '.tools/ubol') -Recurse
    $settings = @{ Version = 8; X = 100; Y = 100; Width = 1100; Height = 760; Dpi = 96; Zoom = 1; TrayEnabled = $true
        SleepInBackground = $false; StartCompact = $false; AutoCheckUpdates = $false; OutputVolume = 0.05; OutputMuted = $true
        BlockAds = $false; DiscordPresence = $false; ObsOverlay = $false; BetterLyricsEnabled = $false }
    [IO.File]::WriteAllText((Join-Path $root 'data/settings.json'), ($settings | ConvertTo-Json))
    $env = @{ NATIVUNE_TEST_DISCORD_FIXTURE_PAGE = '1'; NATIVUNE_TEST_EQ_FIXTURE = '1'; NATIVUNE_TEST_DISCORD_CLIENT_ID = '100000000000000001'
        NATIVUNE_TEST_DISCORD_PIPE_PREFIX = ('nativune-test-' + [guid]::NewGuid().ToString('N') + '-discord-ipc-') } + $Extra
    $helper = Join-Path $base 'launch.ps1'; $spec = Join-Path $base "$Name.json"; $pidFile = Join-Path $base "$Name.pid"
    Remove-Item -LiteralPath $pidFile -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($helper, @'
param([string] $Spec)
$s = Get-Content -Raw -LiteralPath $Spec | ConvertFrom-Json
foreach ($k in @('NATIVUNE_TEST_DISCORD_BENCH_PROFILE','NATIVUNE_TEST_DISCORD_BENCH_STATE','WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS','NATIVUNE_TEST_TRAY_FAIL_ADDS')) { [Environment]::SetEnvironmentVariable($k, [NullString]::Value, 'Process') }
foreach ($p in $s.env.PSObject.Properties) { [Environment]::SetEnvironmentVariable($p.Name, [string]$p.Value, 'Process') }
$p = Start-Process -FilePath $s.exe -ArgumentList @('web', '--root', $s.root) -WorkingDirectory $s.app -PassThru
[IO.File]::WriteAllText($s.pidFile, (@{ processId = $p.Id } | ConvertTo-Json))
'@)
    [IO.File]::WriteAllText($spec, (@{ exe = $exe; app = $app; root = $root; env = $env; pidFile = $pidFile } | ConvertTo-Json -Depth 4))
    & runas.exe '/trustlevel:0x20000' "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$helper`" `"$spec`"" | Out-Null
    if (-not (Wait-For { Test-Path -LiteralPath $pidFile } 30)) { throw 'Restricted-token launch wrote no PID.' }
    return @{ root = $root; pid = (Get-Content -Raw $pidFile | ConvertFrom-Json).processId }
}
function Stop-App($Run) {
    Get-CimInstance Win32_Process -Filter "ParentProcessId=$($Run.pid)" -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $Run.pid -Force -ErrorAction SilentlyContinue
}
function Present($s) { $s.exists -and $s.wanted -and $s.visible -and $s.shellHasIcon }
function LogText($Run) { $log = Join-Path $Run.root 'data/nativune.log'; if (Test-Path -LiteralPath $log) { Get-Content -Raw $log } else { '' } }

$rows = [Collections.Generic.List[object]]::new()
function Row([string] $Name, [bool] $Pass, $Evidence) { $rows.Add([ordered]@{ name = $Name; pass = $Pass; evidence = $Evidence }) }

$run = Start-App 'main'
try {
    $ready = Wait-For { try { Present (Hook $run.root 'tray-state') } catch { $false } } 30
    $s = Hook $run.root 'tray-state'
    Row 'baseline' ($ready -and (Present $s)) $s

    $null = Hook $run.root 'tray-shell-restart' 0
    $t0 = [DateTime]::UtcNow
    $back = Wait-For { Present (Hook $run.root 'tray-state') } 3
    Row 'shell-restart' $back @{ seconds = [math]::Round(([DateTime]::UtcNow - $t0).TotalSeconds, 2); state = (Hook $run.root 'tray-state') }

    $null = Hook $run.root 'tray-shell-restart' 2
    $t0 = [DateTime]::UtcNow
    Start-Sleep -Milliseconds 300
    $mid = Hook $run.root 'tray-state'
    $back = Wait-For { Present (Hook $run.root 'tray-state') } 8
    $seconds = [math]::Round(([DateTime]::UtcNow - $t0).TotalSeconds, 2)
    $log = LogText $run
    Row 'slow-shell' ($back -and $mid.wanted -and -not $mid.visible -and -not $mid.shellHasIcon -and $seconds -ge 2.5 `
        -and $log.Contains('[tray] add-failed shell-restart 1460') -and $log.Contains('[tray] restored after 2 retries')) `
        @{ mid = $mid; seconds = $seconds; final = (Hook $run.root 'tray-state') }

    $failuresBefore = ([regex]::Matches((LogText $run), [regex]::Escape('[tray] add-failed shell-restart'))).Count
    $null = Hook $run.root 'tray-fail-version'
    $null = Hook $run.root 'tray-shell-restart' 0
    $t0 = [DateTime]::UtcNow
    Start-Sleep -Milliseconds 300
    $mid = Hook $run.root 'tray-state'
    $back = Wait-For { Present (Hook $run.root 'tray-state') } 5
    $failuresAfter = ([regex]::Matches((LogText $run), [regex]::Escape('[tray] add-failed shell-restart'))).Count
    Row 'version-fail' ($back -and $mid.wanted -and -not $mid.visible -and $failuresAfter -eq $failuresBefore + 1) `
        @{ mid = $mid; seconds = [math]::Round(([DateTime]::UtcNow - $t0).TotalSeconds, 2); final = (Hook $run.root 'tray-state') }
}
finally { Stop-App $run }

Start-Sleep -Seconds 2
$run = Start-App 'startup' @{ NATIVUNE_TEST_TRAY_FAIL_ADDS = '2' }
try {
    $null = Wait-For { try { $null = Hook $run.root 'tray-state'; $true } catch { $false } } 30
    $t0 = [DateTime]::UtcNow
    $back = Wait-For { Present (Hook $run.root 'tray-state') } 8
    $log = LogText $run
    Row 'slow-startup' ($back -and $log.Contains('[tray] add-failed start 1460') -and -not $log.Contains('Tray icon could not be created')) `
        @{ seconds = [math]::Round(([DateTime]::UtcNow - $t0).TotalSeconds, 2); state = (Hook $run.root 'tray-state') }
}
finally { Stop-App $run }

$passed = @($rows | Where-Object { -not $_.pass }).Count -eq 0
$report = [ordered]@{ generatedUtc = [DateTime]::UtcNow.ToString('o'); passed = $passed; rows = $rows
    command = 'pwsh -NoProfile -File scripts/tray-e2e.ps1' }
[IO.File]::WriteAllText((Join-Path $out 'report.json'), ($report | ConvertTo-Json -Depth 8))
$rows | ForEach-Object { '{0} {1}' -f ($(if ($_.pass) { 'PASS' } else { 'FAIL' }), $_.name) }
Write-Host (Join-Path $out 'report.json')
if (-not $passed) { exit 1 }
