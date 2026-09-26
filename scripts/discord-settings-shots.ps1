param(
    [string] $App = '.cache/build/pub-feature/Nativune.exe',
    [string] $OutputDirectory = 'artifacts/discord-rpc/settings'
)
# PR evidence for Settings > Discord. Runs a disposable root (never data/), opens Settings through
# UI Automation only (no mouse/keyboard), captures the Settings window with PrintWindow and records
# the accessibility properties of the Discord controls. Exit 1 when an expected control is missing.
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
$proc = $null; $settingsHwnd = [IntPtr]::Zero
try {
    $proc = Start-Process -FilePath $appExe -ArgumentList @('web', '--root', "`"$root`"") -PassThru
    $mainHwnd = Wait-Until { $h = [DShot]::Find([uint32] $proc.Id, $null); if ($h -ne [IntPtr]::Zero) { $h } } 'main window' 60
    $main = $AE::FromHandle($mainHwnd)

    # Open Settings: More button -> "Settings…" menu item (flyout items live in a popup, search from desktop root scoped by pid).
    $more = Find-Element $main 'AutomationId' 'MoreButton' 30
    if (-not $more) { $more = Find-Element $main 'Name' 'More commands and settings' 5 }
    if (-not $more) { $missing.Add('MoreButton'); throw 'More button not found.' }
    (Get-Pattern $more ([System.Windows.Automation.InvokePattern])).Invoke()
    $pidCond = New-Object System.Windows.Automation.PropertyCondition ($AE::ProcessIdProperty), $proc.Id
    $item = Wait-Until {
        foreach ($el in $AE::RootElement.FindAll($Scope::Children, $pidCond)) {
            $menuItems = $el.FindAll($Scope::Descendants, [System.Windows.Automation.PropertyCondition]::new($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem))
            foreach ($m in $menuItems) { if ($m.Current.Name -like 'Settings*') { return $m } }
        }
    } 'Settings menu item' 15
    (Get-Pattern $item ([System.Windows.Automation.InvokePattern])).Invoke()

    $settingsHwnd = Wait-Until { $h = [DShot]::Find([uint32] $proc.Id, 'Settings'); if ($h -ne [IntPtr]::Zero) { $h } } 'Settings window' 30
    [void][DShot]::SetWindowPos($settingsHwnd, $HWND_TOPMOST, 0, 0, 0, 0, $SWP)
    $dlg = $AE::FromHandle($settingsHwnd)

    $nav = Find-Element $dlg 'AutomationId' 'DiscordNavItem'
    if (-not $nav) { $missing.Add('DiscordNavItem'); throw 'Discord nav item not found.' }
    (Get-Pattern $nav ([System.Windows.Automation.SelectionItemPattern])).Select()
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

    $cancel = Find-Element $dlg 'AutomationId' 'CancelButton' 5
    if ($cancel) { (Get-Pattern $cancel ([System.Windows.Automation.InvokePattern])).Invoke() } else { $missing.Add('CancelButton') }
    Start-Sleep -Seconds 1
}
catch {
    $report['error'] = $_.Exception.Message
}
finally {
    if ($settingsHwnd -ne [IntPtr]::Zero) { [void][DShot]::SetWindowPos($settingsHwnd, $HWND_NOTOPMOST, 0, 0, 0, 0, $SWP) }
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
"Wrote $($shots['off'].file), $($shots['on'].file) and settings-a11y.json"
