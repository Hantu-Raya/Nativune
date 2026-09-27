param(
    [string] $App = '.cache/build/pub-feature/Nativune.exe',
    [string] $OutputDirectory = 'artifacts/discord-rpc/settings'
)
# PR evidence for the Discord toolbar toggle and Settings > Discord. Runs a disposable root (never data/),
# drives the app through UI Automation only (no mouse/keyboard), captures windows with PrintWindow and records
# the accessibility properties of the Discord controls. Toolbar: the top-right Discord button toggles the saved
# setting (checked in settings.json) and announces on/off; More > "Discord settings…" opens Settings directly on
# the Discord page. Turning the toggle on uses the real Discord pipe of this machine for a few seconds with no
# song playing (signed-out Home page), so no activity card is shown. Exit 1 when an expected control is missing.
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class DShot {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
  public static IntPtr Find(uint pid, string title) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p);
      if (p != pid || !IsWindowVisible(h)) return true;
      var c = new StringBuilder(256); GetClassName(h, c, 256);
      if (c.ToString() != "WinUIDesktopWin32WindowClass") return true;
      var t = new StringBuilder(512); GetWindowText(h, t, 512);
      if (string.IsNullOrEmpty(title) ? t.ToString() != "Settings" : t.ToString() == title) { found = h; return false; }
      return true; }, IntPtr.Zero);
    return found;
  }
}
"@
$HWND_TOPMOST = [IntPtr]::new(-1); $HWND_NOTOPMOST = [IntPtr]::new(-2)
$SWP = 0x1 -bor 0x2 -bor 0x10   # NOSIZE | NOMOVE | NOACTIVATE
$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]

$repo = Split-Path -Parent $PSScriptRoot
$appExe = [IO.Path]::GetFullPath((Join-Path $repo $App))
if ([IO.Path]::IsPathRooted($App)) { $appExe = [IO.Path]::GetFullPath($App) }
$outDir = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) { throw "App not found: $appExe" }
[IO.Directory]::CreateDirectory($outDir) | Out-Null
$commandLine = "pwsh -NoProfile -File scripts/discord-settings-shots.ps1 -App '$App' -OutputDirectory '$OutputDirectory'"

# Fresh root: real copy of the pinned uBO Lite tree (BrowserPrivacy fails closed without it) + v7 settings.
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$root = Join-Path $repo ".cache/discord-settings-shots/$runId"
$ubolVersion = [regex]::Match((Get-Content -Raw (Join-Path $repo 'src/Nativune/BrowserPrivacy.cs')),
    'ExtensionVersion\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $ubolVersion) { throw 'Could not read BrowserPrivacy.ExtensionVersion.' }
$ubolSource = Join-Path $repo ".tools/ubol/$ubolVersion"
if (-not (Test-Path -LiteralPath (Join-Path $ubolSource 'manifest.json') -PathType Leaf)) { throw "uBO Lite missing at $ubolSource" }
$ubolDestination = Join-Path $root '.tools/ubol'
[IO.Directory]::CreateDirectory($ubolDestination) | Out-Null
Copy-Item -LiteralPath $ubolSource -Destination $ubolDestination -Recurse
$data = Join-Path $root 'data'
[IO.Directory]::CreateDirectory($data) | Out-Null
$settings = [ordered]@{
    Version = 7; X = 100; Y = 100; Width = 1280; Height = 800; Dpi = 96; Maximized = $false; Zoom = 1.0
    TrayEnabled = $true; RestoreSection = $false; LastSection = 'home'; ReduceMotion = $false
    CompactX = 100; CompactY = 100; CompactWidth = 800; CompactHeight = 180; CompactDpi = 96
    SleepInBackground = $false; StartCompact = $false; AutoCheckUpdates = $false
    OutputVolume = 1.0; BlockAds = $false
    DiscordPresence = $false; DiscordStatusLine = 0; DiscordOpenButton = $true
}
[IO.File]::WriteAllText((Join-Path $data 'settings.json'), ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))

function Wait-Until([scriptblock] $Probe, [string] $What, [int] $Seconds = 30) {
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $until) {
        $value = & $Probe
        if ($value) { return $value }
        Start-Sleep -Milliseconds 300
    }
    throw "Timed out waiting for $What."
}
function Find-Element($Parent, [string] $Property, [string] $Value, [int] $Seconds = 15) {
    $cond = New-Object System.Windows.Automation.PropertyCondition ($AE::($Property + 'Property')), $Value
    $until = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $el = $Parent.FindFirst($Scope::Descendants, $cond)
        if ($el) { return $el }
        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $until)
    $null
}
function Get-Pattern($El, $Pattern) { $El.GetCurrentPattern($Pattern::Pattern) }
function Save-Shot([IntPtr] $Hwnd, [string] $Name) {
    $wr = New-Object DShot+RECT; [void][DShot]::GetWindowRect($Hwnd, [ref] $wr)
    $bmp = New-Object System.Drawing.Bitmap ($wr.Right - $wr.Left), ($wr.Bottom - $wr.Top)
    $g = [System.Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
    $ok = [DShot]::PrintWindow($Hwnd, $hdc, 2); $g.ReleaseHdc($hdc); $g.Dispose()
    $fr = New-Object DShot+RECT; [void][DShot]::DwmGetWindowAttribute($Hwnd, 9, [ref] $fr, 16)
    $crop = New-Object System.Drawing.Rectangle ($fr.Left - $wr.Left), ($fr.Top - $wr.Top), ($fr.Right - $fr.Left), ($fr.Bottom - $fr.Top)
    $out = $bmp.Clone($crop, $bmp.PixelFormat); $bmp.Dispose()
    $file = Join-Path $outDir "$Name.png"; $out.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $size = "$($out.Width)x$($out.Height)"; $out.Dispose()
    [ordered]@{ file = $file; printed = $ok; pixels = $size }
}
function Save-ToolbarCrop([IntPtr] $Hwnd, [string] $Name, [int] $Width = 420, [int] $Height = 49) {
    $shot = Save-Shot $Hwnd "$Name-window"
    $full = [System.Drawing.Bitmap]::FromFile($shot.file)
    $w = [Math]::Min($Width, $full.Width)
    $crop = $full.Clone([System.Drawing.Rectangle]::new($full.Width - $w, 0, $w, [Math]::Min($Height, $full.Height)), $full.PixelFormat)
    $full.Dispose(); Remove-Item -LiteralPath $shot.file
    $file = Join-Path $outDir "$Name.png"; $crop.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $size = "$($crop.Width)x$($crop.Height)"; $crop.Dispose()
    [ordered]@{ file = $file; printed = $shot.printed; pixels = $size }
}
function Read-SavedDiscord { ([IO.File]::ReadAllText((Join-Path $data 'settings.json')) | ConvertFrom-Json).DiscordPresence }
function Find-MenuItem([int] $ProcessId, [string] $Like) {
    $pidCond = New-Object System.Windows.Automation.PropertyCondition ($AE::ProcessIdProperty), $ProcessId
    foreach ($el in $AE::RootElement.FindAll($Scope::Children, $pidCond)) {
        $menuItems = $el.FindAll($Scope::Descendants, [System.Windows.Automation.PropertyCondition]::new($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem))
        foreach ($m in $menuItems) { if ($m.Current.Name -like $Like) { return $m } }
    }
}
# Counts white-ish and Discord-Blurple pixels inside the element's bounds on a PrintWindow capture.
function Measure-IconColors([IntPtr] $Hwnd, $Element, [string] $Name) {
    $shot = Save-Shot $Hwnd "$Name-window"
    $full = [System.Drawing.Bitmap]::FromFile($shot.file)
    $fr = New-Object DShot+RECT; [void][DShot]::DwmGetWindowAttribute($Hwnd, 9, [ref] $fr, 16)
    $b = $Element.Current.BoundingRectangle
    $white = 0; $blurple = 0; $inset = 5 # skip the focus rectangle / border
    for ($x = [int] ($b.Left - $fr.Left) + $inset; $x -lt [int] ($b.Right - $fr.Left) - $inset; $x++) {
        for ($y = [int] ($b.Top - $fr.Top) + $inset; $y -lt [int] ($b.Bottom - $fr.Top) - $inset; $y++) {
            if ($x -lt 0 -or $y -lt 0 -or $x -ge $full.Width -or $y -ge $full.Height) { continue }
            $p = $full.GetPixel($x, $y)
            if ($p.R -ge 200 -and $p.G -ge 200 -and $p.B -ge 200) { $white++ }
            elseif ([Math]::Abs($p.R - 0x58) -le 30 -and [Math]::Abs($p.G - 0x65) -le 30 -and [Math]::Abs($p.B - 0xF2) -le 30) { $blurple++ }
        }
    }
    $full.Dispose(); Remove-Item -LiteralPath $shot.file
    [ordered]@{ white = $white; blurple = $blurple }
}
function Describe($El) {
    if (-not $El) { return $null }
    $c = $El.Current
    [ordered]@{
        AutomationId = $c.AutomationId; Name = $c.Name; HelpText = $c.HelpText
        ControlType = $c.ControlType.ProgrammaticName; IsEnabled = $c.IsEnabled; IsKeyboardFocusable = $c.IsKeyboardFocusable
    }
}

$ids = 'DiscordNavItem', 'DiscordPresenceCheckBox', 'DiscordStatusLineComboBox', 'DiscordOpenButtonCheckBox', 'DiscordDisclosureText', 'DiscordStatusText'
$report = [ordered]@{ command = $commandLine; runId = $runId; app = $appExe; appVersion = (Get-Item -LiteralPath $appExe).VersionInfo.ProductVersion }
$missing = New-Object System.Collections.Generic.List[string]
$shots = [ordered]@{}
$proc = $null; $settingsHwnd = [IntPtr]::Zero; $mainHwnd = [IntPtr]::Zero
try {
    $proc = Start-Process -FilePath $appExe -ArgumentList @('web', '--root', "`"$root`"") -PassThru
    $mainHwnd = Wait-Until { $h = [DShot]::Find([uint32] $proc.Id, $null); if ($h -ne [IntPtr]::Zero) { $h } } 'main window' 60
    $main = $AE::FromHandle($mainHwnd)
    [void][DShot]::SetWindowPos($mainHwnd, $HWND_TOPMOST, 0, 0, 0, 0, $SWP)

    # Toolbar toggle (top right, beside the update indicator).
    $discordButton = Find-Element $main 'AutomationId' 'DiscordButton' 30
    if (-not $discordButton) { $missing.Add('DiscordButton'); throw 'Discord toolbar button not found.' }
    Start-Sleep -Seconds 3
    $toolbar = [ordered]@{ initial = Describe $discordButton; initialSaved = Read-SavedDiscord }
    $shots['toolbarOff'] = Save-ToolbarCrop $mainHwnd 'toolbar-discord-off'
    $toolbar['initialColors'] = Measure-IconColors $mainHwnd $discordButton 'color-initial'
    (Get-Pattern $discordButton ([System.Windows.Automation.InvokePattern])).Invoke()
    $toolbar['onName'] = Wait-Until { $n = $discordButton.Current.Name; if ($n -like 'Discord: on*') { $n } } 'Discord button on' 10
    Start-Sleep -Seconds 2
    $toolbar['onSaved'] = Wait-Until { if ((Read-SavedDiscord) -eq $true) { 'true' } } 'saved DiscordPresence=true' 10
    $toolbar['on'] = Describe $discordButton
    $shots['toolbarOn'] = Save-ToolbarCrop $mainHwnd 'toolbar-discord-on'
    $toolbar['onColors'] = Measure-IconColors $mainHwnd $discordButton 'color-on'
    (Get-Pattern $discordButton ([System.Windows.Automation.InvokePattern])).Invoke()
    $toolbar['offName'] = Wait-Until { $n = $discordButton.Current.Name; if ($n -eq 'Discord: off') { $n } } 'Discord button off' 10
    $toolbar['offSaved'] = Wait-Until { if ((Read-SavedDiscord) -eq $false) { 'false' } } 'saved DiscordPresence=false' 10
    Start-Sleep -Milliseconds 800
    $shots['toolbarOffAfterToggle'] = Save-ToolbarCrop $mainHwnd 'toolbar-discord-off-after-toggle'
    $toolbar['offAfterToggleColors'] = Measure-IconColors $mainHwnd $discordButton 'color-off-after'
    # Off (initially and after toggling back) must be the white template brush; on must be Blurple.
    $toolbar['colorsOk'] = $toolbar.initialColors.white -ge 20 -and $toolbar.initialColors.blurple -eq 0 -and
        $toolbar.onColors.blurple -ge 20 -and $toolbar.offAfterToggleColors.white -ge 20 -and $toolbar.offAfterToggleColors.blurple -eq 0
    if (-not $toolbar['colorsOk']) { $missing.Add('toolbarIconColors') }
    $report['toolbar'] = $toolbar
    [void][DShot]::SetWindowPos($mainHwnd, $HWND_NOTOPMOST, 0, 0, 0, 0, $SWP)

    # More menu: the Discord toggle item and "Discord settings…", which opens Settings on the Discord page.
    $more = Find-Element $main 'AutomationId' 'MoreButton' 30
    if (-not $more) { $more = Find-Element $main 'Name' 'More commands and settings' 5 }
    if (-not $more) { $missing.Add('MoreButton'); throw 'More button not found.' }
    (Get-Pattern $more ([System.Windows.Automation.InvokePattern])).Invoke()
    $toggleItem = Wait-Until { Find-MenuItem $proc.Id "Show what I'm playing on Discord" } 'Discord toggle menu item' 15
    $report['moreToggleItem'] = [ordered]@{ name = $toggleItem.Current.Name
        toggleState = (Get-Pattern $toggleItem ([System.Windows.Automation.TogglePattern])).Current.ToggleState.ToString() }
    $item = Wait-Until { Find-MenuItem $proc.Id 'Discord settings*' } 'Discord settings menu item' 15
    (Get-Pattern $item ([System.Windows.Automation.InvokePattern])).Invoke()

    $settingsHwnd = Wait-Until { $h = [DShot]::Find([uint32] $proc.Id, 'Settings'); if ($h -ne [IntPtr]::Zero) { $h } } 'Settings window' 30
    [void][DShot]::SetWindowPos($settingsHwnd, $HWND_TOPMOST, 0, 0, 0, 0, $SWP)
    $dlg = $AE::FromHandle($settingsHwnd)

    # Opened from "Discord settings…": the Discord page must already be selected.
    $nav = Find-Element $dlg 'AutomationId' 'DiscordNavItem'
    if (-not $nav) { $missing.Add('DiscordNavItem'); throw 'Discord nav item not found.' }
    $report['openedOnDiscordPage'] = (Get-Pattern $nav ([System.Windows.Automation.SelectionItemPattern])).Current.IsSelected
    Start-Sleep -Milliseconds 1200

    $els = [ordered]@{}
    foreach ($id in $ids) { $els[$id] = Find-Element $dlg 'AutomationId' $id 10; if (-not $els[$id]) { $missing.Add($id) } }
    if ($missing.Count) { throw "Missing controls: $($missing -join ', ')" }

    $off = [ordered]@{}
    foreach ($id in $ids) { $off[$id] = Describe $els[$id] }
    $off['statusText'] = $els['DiscordStatusText'].Current.Name
    $shots['off'] = Save-Shot $settingsHwnd 'discord-off'

    $toggle = Get-Pattern $els['DiscordPresenceCheckBox'] ([System.Windows.Automation.TogglePattern])
    if ($toggle.Current.ToggleState -ne [System.Windows.Automation.ToggleState]::On) { $toggle.Toggle() }
    Start-Sleep -Milliseconds 1200
    $on = [ordered]@{}
    foreach ($id in $ids) { $on[$id] = Describe (Find-Element $dlg 'AutomationId' $id 5) }
    $on['statusText'] = (Find-Element $dlg 'AutomationId' 'DiscordStatusText' 5).Current.Name
    $shots['on'] = Save-Shot $settingsHwnd 'discord-on'

    $report['off'] = $off
    $report['on'] = $on
    $report['dependentControls'] = [ordered]@{
        comboDisabledWhenOff = -not $off['DiscordStatusLineComboBox'].IsEnabled
        comboEnabledWhenOn = [bool] $on['DiscordStatusLineComboBox'].IsEnabled
        openButtonDisabledWhenOff = -not $off['DiscordOpenButtonCheckBox'].IsEnabled
        openButtonEnabledWhenOn = [bool] $on['DiscordOpenButtonCheckBox'].IsEnabled
        unsavedStatusMentionsSave = [string] $on['statusText'] -like '*Turns on after Save*'
    }
    if (-not $report['openedOnDiscordPage']) { $missing.Add('openedOnDiscordPage') }
    if ($report['moreToggleItem'].toggleState -ne 'Off') { $missing.Add('moreToggleItemOff') }

    $cancel = Find-Element $dlg 'AutomationId' 'CancelButton' 5
    if ($cancel) { (Get-Pattern $cancel ([System.Windows.Automation.InvokePattern])).Invoke() } else { $missing.Add('CancelButton') }
    Start-Sleep -Seconds 1
}
catch {
    $report['error'] = $_.Exception.Message
}
finally {
    if ($settingsHwnd -ne [IntPtr]::Zero) { [void][DShot]::SetWindowPos($settingsHwnd, $HWND_NOTOPMOST, 0, 0, 0, 0, $SWP) }
    if ($mainHwnd -ne [IntPtr]::Zero) { [void][DShot]::SetWindowPos($mainHwnd, $HWND_NOTOPMOST, 0, 0, 0, 0, $SWP) }
    if ($proc) {
        if (-not $proc.HasExited) { [void]$proc.CloseMainWindow(); [void]$proc.WaitForExit(8000) }
        if (-not $proc.HasExited) { & taskkill /PID $proc.Id /T /F 2>&1 | Out-Null }
    }
    Get-CimInstance Win32_Process -Filter "Name = 'msedgewebview2.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($root) } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
    $report['shots'] = $shots
    $report['missing'] = @($missing)
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $outDir 'settings-a11y.json') -Encoding UTF8
    Start-Sleep -Seconds 1
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
if ($missing.Count -or $report.Contains('error')) {
    Write-Error "Discord settings capture failed: $($report['error']) missing=[$($missing -join ', ')]" -ErrorAction Continue
    exit 1
}
"Wrote $(@($shots.Values | ForEach-Object { $_.file }) -join ', ') and settings-a11y.json"
