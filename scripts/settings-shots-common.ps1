# Dot-sourced by the Settings screenshot runners; Save-Shot uses the caller's $outDir.
Add-Type -AssemblyName System.Drawing, UIAutomationClient, UIAutomationTypes
if (-not ('DShot' -as [type])) {
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
}
$HWND_TOPMOST = [IntPtr]::new(-1); $HWND_NOTOPMOST = [IntPtr]::new(-2)
$SWP = 0x1 -bor 0x2 -bor 0x10   # NOSIZE | NOMOVE | NOACTIVATE
$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]

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
function Find-MenuItem([int] $ProcessId, [string] $Like) {
    $pidCond = New-Object System.Windows.Automation.PropertyCondition ($AE::ProcessIdProperty), $ProcessId
    foreach ($el in $AE::RootElement.FindAll($Scope::Children, $pidCond)) {
        $menuItems = $el.FindAll($Scope::Descendants, [System.Windows.Automation.PropertyCondition]::new($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem))
        foreach ($m in $menuItems) { if ($m.Current.Name -like $Like) { return $m } }
    }
}
