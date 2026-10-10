param(
    [string] $App = '.cache/build/pub-feature/Nativune.exe',
    [string] $OutputDirectory = 'artifacts/lyrics/settings'
)
# PR evidence for Settings > Lyrics and the host-owned "Lyric settings" window. Each run uses a fresh disposable
# root under .cache/lyrics-settings-shots (never data/), drives the app through UI Automation only (no mouse or
# keyboard), captures windows with PrintWindow and records the accessibility properties of the Lyrics controls.
# Run 1: BetterLyricsEnabled=true (settings-lyrics.png, lyric-settings.png). Run 2: false (settings-lyrics-off.png).
# Exit 1 when an expected control is missing.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'settings-shots-common.ps1')


$repo = Split-Path -Parent $PSScriptRoot
$appExe = [IO.Path]::GetFullPath((Join-Path $repo $App))
if ([IO.Path]::IsPathRooted($App)) { $appExe = [IO.Path]::GetFullPath($App) }
$outDir = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) { throw "App not found: $appExe" }
[IO.Directory]::CreateDirectory($outDir) | Out-Null
$commandLine = "pwsh -NoProfile -File scripts/lyrics-settings-shots.ps1 -App '$App' -OutputDirectory '$OutputDirectory'"
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$template = Join-Path $repo '.cache/perf/template/webview2'
foreach ($required in $template, (Join-Path $repo '.tools/ubol'), (Join-Path $repo '.tools/better-lyrics')) {
    if (-not (Test-Path -LiteralPath $required -PathType Container)) { throw "Missing prerequisite: $required" }
}

# Disposable root: signed-out template profile, uBO Lite + Better Lyrics trees, v7 settings.
function New-ShotRoot([string] $Name, [bool] $Lyrics) {
    $r = Join-Path $repo ".cache/lyrics-settings-shots/$runId-$Name"
    $d = Join-Path $r 'data'
    [IO.Directory]::CreateDirectory($d) | Out-Null
    Copy-Item -LiteralPath $template -Destination (Join-Path $d 'webview2') -Recurse
    $tools = Join-Path $r '.tools'
    [IO.Directory]::CreateDirectory($tools) | Out-Null
    Copy-Item -LiteralPath (Join-Path $repo '.tools/ubol') -Destination $tools -Recurse
    Copy-Item -LiteralPath (Join-Path $repo '.tools/better-lyrics') -Destination $tools -Recurse
    $settings = [ordered]@{
        Version = 7; X = 100; Y = 60; Width = 1280; Height = 800; Dpi = 96; Maximized = $false; Zoom = 1.0
        TrayEnabled = $true; RestoreSection = $false; LastSection = 'home'; ReduceMotion = $false
        CompactX = 100; CompactY = 100; CompactWidth = 800; CompactHeight = 180; CompactDpi = 96
        SleepInBackground = $false; StartCompact = $false; AutoCheckUpdates = $false
        OutputVolume = 1.0; BlockAds = $false
        DiscordPresence = $false; DiscordStatusLine = 0; DiscordOpenButton = $true
        BetterLyricsEnabled = $Lyrics
    }
    [IO.File]::WriteAllText((Join-Path $d 'settings.json'), ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    $r
}

function Describe($El) {
    if (-not $El) { return $null }
    $c = $El.Current
    [ordered]@{
        AutomationId = $c.AutomationId; Name = $c.Name; HelpText = $c.HelpText
        ControlType = $c.ControlType.ProgrammaticName; IsEnabled = $c.IsEnabled; IsKeyboardFocusable = $c.IsKeyboardFocusable
    }
}
function Invoke-El($El) { (Get-Pattern $El ([System.Windows.Automation.InvokePattern])).Invoke() }

$ids = 'LyricsNavItem', 'LyricsEnabledCheckBox', 'LyricsDisclosureText', 'OpenLyricsSettingsButton', 'LyricsStatusText'
$report = [ordered]@{ command = $commandLine; runId = $runId; app = $appExe; appVersion = (Get-Item -LiteralPath $appExe).VersionInfo.ProductVersion }
$missing = New-Object System.Collections.Generic.List[string]
$shots = [ordered]@{}

# One app session: open Settings > Lyrics, describe, capture; optionally open the lyric settings window.
function Invoke-Run([string] $Name, [bool] $Lyrics, [string] $ShotName) {
    $run = [ordered]@{ betterLyricsEnabled = $Lyrics }
    $root = New-ShotRoot $Name $Lyrics
    $proc = $null; $settingsHwnd = [IntPtr]::Zero; $mainHwnd = [IntPtr]::Zero; $lyricHwnd = [IntPtr]::Zero
    try {
        $proc = Start-Process -FilePath $appExe -ArgumentList @('web', '--root', "`"$root`"") -PassThru
        $mainHwnd = Wait-Until { $h = [DShot]::Find([uint32] $proc.Id, $null); if ($h -ne [IntPtr]::Zero) { $h } } 'main window' 60
        $main = $AE::FromHandle($mainHwnd)
        Start-Sleep -Seconds 3

        $more = Find-Element $main 'AutomationId' 'MoreButton' 30
        if (-not $more) { $more = Find-Element $main 'Name' 'More commands and settings' 5 }
        if (-not $more) { $missing.Add("${Name}:MoreButton"); throw 'More button not found.' }
        Invoke-El $more
        $item = Wait-Until { Find-MenuItem $proc.Id 'Settings*' } 'Settings menu item' 15
        Invoke-El $item

        $settingsHwnd = Wait-Until { $h = [DShot]::Find([uint32] $proc.Id, 'Settings'); if ($h -ne [IntPtr]::Zero) { $h } } 'Settings window' 30
        [void][DShot]::SetWindowPos($settingsHwnd, $HWND_TOPMOST, 0, 0, 0, 0, $SWP)
        $dlg = $AE::FromHandle($settingsHwnd)

        $nav = Find-Element $dlg 'AutomationId' 'LyricsNavItem'
        if (-not $nav) { $missing.Add("${Name}:LyricsNavItem"); throw 'Lyrics nav item not found.' }
        $sel = $null
        if ($nav.TryGetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern, [ref] $sel)) { $sel.Select() }
        else { Invoke-El $nav }
        if (-not (Find-Element $dlg 'AutomationId' 'LyricsEnabledCheckBox' 10)) { $missing.Add("${Name}:LyricsEnabledCheckBox"); throw 'Lyrics page did not open.' }
        Start-Sleep -Milliseconds 1200

        $els = [ordered]@{}; $desc = [ordered]@{}
        foreach ($id in $ids) {
            $els[$id] = Find-Element $dlg 'AutomationId' $id 10
            if (-not $els[$id]) { $missing.Add("${Name}:$id") }
            $desc[$id] = Describe $els[$id]
        }
        $run['controls'] = $desc
        $run['statusText'] = if ($els['LyricsStatusText']) { $els['LyricsStatusText'].Current.Name } else { $null }
        $run['openButtonEnabled'] = if ($els['OpenLyricsSettingsButton']) { $els['OpenLyricsSettingsButton'].Current.IsEnabled } else { $null }
        $shots[$ShotName] = Save-Shot $settingsHwnd $ShotName
        $run['shot'] = "$ShotName.png"

        if ($Lyrics) {
            if ($run['openButtonEnabled']) {
                Invoke-El $els['OpenLyricsSettingsButton']
                $lyricHwnd = Wait-Until { $h = [DShot]::Find([uint32] $proc.Id, 'Lyric settings'); if ($h -ne [IntPtr]::Zero) { $h } } 'Lyric settings window' 20
                [void][DShot]::SetWindowPos($lyricHwnd, $HWND_TOPMOST, 0, 0, 0, 0, $SWP)
                Start-Sleep -Seconds 4
                $shots['lyricSettings'] = Save-Shot $lyricHwnd 'lyric-settings'
                $run['lyricSettingsShot'] = 'lyric-settings.png'
                $run['lyricSettingsWindow'] = Describe ($AE::FromHandle($lyricHwnd))
                [void][DShot]::SetWindowPos($lyricHwnd, $HWND_NOTOPMOST, 0, 0, 0, 0, $SWP)
                $wp = $null
                if ($AE::FromHandle($lyricHwnd).TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref] $wp)) { $wp.Close() }
                Start-Sleep -Seconds 1
            }
            else { $run['openButtonDisabled'] = $run['statusText']; $missing.Add("${Name}:OpenLyricsSettingsButtonEnabled") }
        }

        $cancel = Find-Element $dlg 'AutomationId' 'CancelButton' 5
        if ($cancel) { Invoke-El $cancel } else { $missing.Add("${Name}:CancelButton") }
        Start-Sleep -Seconds 1
    }
    catch { $run['error'] = $_.Exception.Message }
    finally {
        if ($settingsHwnd -ne [IntPtr]::Zero) { [void][DShot]::SetWindowPos($settingsHwnd, $HWND_NOTOPMOST, 0, 0, 0, 0, $SWP) }
        if ($proc) {
            if (-not $proc.HasExited) { [void]$proc.CloseMainWindow(); [void]$proc.WaitForExit(8000) }
            if (-not $proc.HasExited) { & taskkill /PID $proc.Id /T /F 2>&1 | Out-Null }
        }
        Get-CimInstance Win32_Process -Filter "Name = 'msedgewebview2.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.CommandLine -and $_.CommandLine.Contains($root) } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
    $run
}

$report['lyricsOn'] = Invoke-Run 'on' $true 'settings-lyrics'
$report['lyricsOff'] = Invoke-Run 'off' $false 'settings-lyrics-off'
$report['shots'] = @($shots.Keys | ForEach-Object { [IO.Path]::GetFileName($shots[$_].file) })
$report['missing'] = @($missing)
$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'report.json') -Encoding UTF8
$errors = @(@($report.lyricsOn, $report.lyricsOff) | Where-Object { $_.Contains('error') } | ForEach-Object { $_['error'] })
if ($missing.Count -or $errors.Count) {
    Write-Error "Lyrics settings capture failed: $($errors -join '; ') missing=[$($missing -join ', ')]" -ErrorAction Continue
    exit 1
}
"Wrote $(@($shots.Values | ForEach-Object { $_.file }) -join ', ') and report.json"
