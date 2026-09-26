<#
E2E for quiet automatic update checks on the real app (owner-approved 26 September 2026 for
%LOCALAPPDATA%\Nativune-fixture only; the owner's %LOCALAPPDATA%\Nativune is never touched).

Failure modes it catches:
- an automatic check shows the Checking state (button renamed/disabled) or the update bar;
- an automatic check that finds an update does not mark the Update button;
- a failed automatic check erases a known available update;
- a failed automatic check is not logged.

  pwsh -NoProfile -File scripts/delta-update-fixture.ps1                  # once: artifacts/delta-fixture-a and -b
  pwsh -NoProfile -File scripts/delta-update-app-e2e.ps1 -Action Prepare  # installs the test-hook build as 0.9.1
  pwsh -NoProfile -File scripts/quiet-update-e2e.ps1                      # writes artifacts/quiet-update/e2e-report.json
  pwsh -NoProfile -File scripts/delta-update-app-e2e.ps1 -Action Remove

The app runs with a 20 s automatic-check interval (NATIVUNE_TEST_UPDATE_CHECK_SECONDS, test-hook
builds only) against scripts/updater-test-server.py: first "available", then "servererror".
Start-with-Windows writes go to a test key (NATIVUNE_TEST_STARTUP_KEY), removed afterwards.
No mouse or keyboard input is used; the toolbar is read through UI Automation.
#>
[CmdletBinding()]
param([int] $Port = 8766, [int] $IntervalSeconds = 20)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$fixtureRoot = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'Nativune-fixture'
$served = Join-Path $repo '.cache\delta-app-e2e\served'
$reportPath = Join-Path $repo 'artifacts\quiet-update\e2e-report.json'
$startupKey = 'Software\Nativune\Test\quiet-update-e2e'
if (-not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'app\Nativune.exe'))) { throw 'Run delta-update-app-e2e.ps1 -Action Prepare first.' }

function Start-Server([string] $Scenario) {
    $serverArgs = @('scripts/updater-test-server.py', '--port', $Port, '--scenario', $Scenario, '--tag', 'v0.9.2',
        '--setup-file', (Join-Path $served 'Nativune-Setup.exe'), '--delta-dir', $served)
    $p = Start-Process -FilePath python -ArgumentList $serverArgs -WorkingDirectory $repo -PassThru -WindowStyle Hidden
    Start-Sleep -Seconds 2
    $p
}

function Get-Toolbar([IntPtr] $Hwnd) {
    $root = [Windows.Automation.AutomationElement]::FromHandle($Hwnd)
    $byId = { param($id) $root.FindFirst([Windows.Automation.TreeScope]::Descendants,
        (New-Object Windows.Automation.PropertyCondition ([Windows.Automation.AutomationElement]::AutomationIdProperty), $id)) }
    $button = & $byId 'UpdateButton'
    $bar = & $byId 'UpdateInfoBar'
    [pscustomobject]@{
        name = if ($button) { $button.Current.Name } else { $null }
        enabled = if ($button) { $button.Current.IsEnabled } else { $null }
        barShown = [bool] ($bar -and -not $bar.Current.IsOffscreen -and $bar.Current.BoundingRectangle.Height -gt 0)
        barText = if ($bar) { (@($bar.FindAll([Windows.Automation.TreeScope]::Descendants, [Windows.Automation.Condition]::TrueCondition)) |
            ForEach-Object { $_.Current.Name } | Where-Object { $_ -and $_ -ne 'Nativune update progress announcement' }) -join ' | ' } else { '' }
    }
}

function Watch-Toolbar([IntPtr] $Hwnd, [int] $Seconds) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds); $samples = @()
    while ([DateTime]::UtcNow -lt $until) { $samples += Get-Toolbar $Hwnd; Start-Sleep -Milliseconds 200 }
    $samples
}

$server = $null; $app = $null
$report = [ordered]@{ command = 'pwsh -NoProfile -File scripts/quiet-update-e2e.ps1'; intervalSeconds = $IntervalSeconds }
try {
    $server = Start-Server 'available'
    $env:NATIVUNE_TEST_RELEASE_METADATA_URL = "http://127.0.0.1:$Port/repos/Hantu-Raya/Nativune/releases/latest"
    $env:NATIVUNE_TEST_SETUP_NO_SHELL = '1'
    $env:NATIVUNE_TEST_STARTUP_KEY = $startupKey
    $env:NATIVUNE_TEST_UPDATE_CHECK_SECONDS = "$IntervalSeconds"
    $logPath = Join-Path $fixtureRoot 'data\nativune.log'
    $logBefore = if (Test-Path $logPath) { (Get-Content $logPath).Count } else { 0 }
    $app = Start-Process -FilePath (Join-Path $fixtureRoot 'app\Nativune.exe') -ArgumentList @('web', '--root', "`"$fixtureRoot`"") -PassThru
    $hwnd = [IntPtr]::Zero; $until = [DateTime]::UtcNow.AddSeconds(60)
    while ($hwnd -eq [IntPtr]::Zero -and [DateTime]::UtcNow -lt $until) { Start-Sleep -Milliseconds 500; $app.Refresh(); $hwnd = $app.MainWindowHandle }
    if ($hwnd -eq [IntPtr]::Zero) { throw 'Fixture window not found.' }

    # Phase 1: startup check plus two automatic ticks against "available".
    $phase1 = Watch-Toolbar $hwnd ($IntervalSeconds * 2 + 10)
    # Phase 2: the server now fails; two more automatic ticks.
    Stop-Process -Id $server.Id -Force; $server = Start-Server 'servererror'
    $phase2 = Watch-Toolbar $hwnd ($IntervalSeconds * 2 + 5)

    $available = 'Update Nativune to v0.9.2'
    $newLog = if (Test-Path $logPath) { @(Get-Content $logPath | Select-Object -Skip $logBefore) } else { @() }
    $checks = [ordered]@{
        markedAvailable = [bool] ($phase1 | Where-Object name -eq $available)
        noCheckingState = -not ($phase1 + $phase2 | Where-Object { $_.name -like 'Checking*' -or $_.enabled -eq $false })
        # The bar may carry the first-run start-with-Windows notice; it must never carry update news.
        noUpdateBar = -not ($phase1 + $phase2 | Where-Object { $_.barShown -and $_.barText -match 'update|available|check|download' })
        failureKeepsMark = [bool] ($phase2.Count -gt 0 -and -not ($phase2 | Where-Object name -ne $available))
        failureLogged = [bool] ($newLog | Where-Object { $_ -match 'update' -and $_ -match 'HTTP 5\d\d' })
    }
    $report.checks = $checks
    $report.namesSeen = @(($phase1 + $phase2).name | Select-Object -Unique)
    $report.barTextsSeen = @(($phase1 + $phase2) | Where-Object barShown | ForEach-Object barText | Select-Object -Unique)
    $report.passed = -not ($checks.Values -contains $false)
}
finally {
    if ($app -and -not $app.HasExited) { Stop-Process -Id $app.Id -Force; Start-Sleep -Seconds 3 }
    Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($fixtureRoot) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    if ($server) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
    Remove-Item -Path "HKCU:\$startupKey" -Recurse -Force -ErrorAction SilentlyContinue
    foreach ($n in 'NATIVUNE_TEST_RELEASE_METADATA_URL', 'NATIVUNE_TEST_SETUP_NO_SHELL', 'NATIVUNE_TEST_STARTUP_KEY', 'NATIVUNE_TEST_UPDATE_CHECK_SECONDS') {
        Remove-Item "Env:$n" -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Force (Split-Path $reportPath) | Out-Null
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $reportPath -Encoding utf8NoBOM
}
Get-Content -LiteralPath $reportPath
if (-not $report['passed']) { exit 1 }
