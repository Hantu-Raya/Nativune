<#
E2E-B for the opt-in OBS now-playing overlay against a real, disposable OBS Studio 32.2.2
(notes/research/obs-overlay-2026-09-28/plan.md §6.2; design notes in design.md). Helper: scripts/obs-portable.ps1.

APPROVAL: running this script needs the owner's explicit approval for this run (plan §6.2 heading: no answer is not
approval). It puts a disposable OBS window on screen for up to -TimeBoxMinutes (default 30, the B-LOOK/B-VIS/B-DOCS
share of the G3 2 h box), and while OBS runs obs-websocket listens on ALL interfaces on a random port 49152-65535,
protected by a random 32-byte password that never reaches argv, logs or artifacts.

Regenerate:
  pwsh -NoProfile -File scripts/obs-overlay-obs-e2e.ps1 -Scenario All -OutputDirectory artifacts/obs-overlay-obs
  pwsh -NoProfile -File scripts/obs-overlay-obs-e2e.ps1 -Scenario B-LOOK,B-DOCS -SkipPublish -UpdateDocsImages
  pwsh -NoProfile -File scripts/obs-overlay-obs-e2e.ps1 -Scenario B-VIS,B-ISO -TimeBoxMinutes 15

Flow: publish the hook build (-p:DiscordPresenceTestHooks=true) to artifacts/obs-overlay/app unless -SkipPublish;
snapshot the owner's OBS profile (B-ISO); per session start the app first (Basic-user token through runas when this
harness is elevated, as in obs-overlay-e2e.ps1), confirm overlay.running and a 200 on http://localhost:47813/, then
New-ObsPortable (.cache/obs-portable/<run>-<session>, current-user-only ACL) + Start-ObsPortable (owned-instance
check: PID + creation time, listening PID, GetVersion 32.2.2; expected vs observed paths). Sessions:
  look   default fixture timeline: B-LOOK then B-DOCS (one OBS launch).
  vis    Playing profile (1800 s steady): B-VIS matrix; then OBS relaunched with the item hidden; then OBS relaunched
         with shutdown off (recorded, not gated: D9). The app keeps running across these OBS launches.
Cleanup (finally): Stop-ObsPortable (close window, 10 s, kill owned tree, delete run folder; an owner-profile change
stops and preserves evidence), stop the app.

Scenarios (plan §6.2):
  B-LOOK  GetSourceScreenshot of the input 'Nativune Overlay' (PNG, native 440x96). After command-navigate restarts
          the fixture timeline (page 0 = new page load): stills at page 8 s (t0) and 18 s (t0+10 s); capture windows
          -0.5..+3.5 s around seek (25 s), pause (45 s, hide: hidePaused on), play (resume 60 s, show) and track B
          (80 s) at 10 fps with the achieved rate recorded (< 8 fps -> blocked). Event time = receipt of the matching
          SSE data event by the harness reader (fallback: predicted page time). Oracles (Pillow, analyze-look.py):
            mask      alpha >= 0.9 inside the rounded rect (20,20,400,56,r28) inset 2 px; the alpha > 200 bounding box
                      equals (20,20,420,76) +-1 px; outside the rect beyond a 2 px anti-alias ring every pixel has
                      alpha <= 170 (the box-shadow rgba(0,0,0,.65) maximum 166 plus rounding); counts reported.
            reveal    saturation step x at 20 + 400 p +-6 px (stills and the settled seek frame).
            artFixed  the art's luminance profile right of both reveal boundaries shifts <= 3 px between t0 and
                      t0+10 s. (The fixture's bright top-left 48x48 quadrant is cropped out of the 56 px band by the
                      cover scaling, so the diagonal gradient profile is the feature.)
            show      >= 2 frames with normalized opacity 0.1-0.9 (vs the settled +3.5 s frame), top edge rising
                      from 32+-2 (first visible frame >= 26, <= 34) to 20+-2, non-increasing, settled <= 2.5 s.
            hide      >= 2 intermediate frames (vs the pre-event frames), alpha <= 0.1 from 2.5 s after pause.
            text      text region (white glyph mask) differs between the last A frame and the settled B frame.
          Frames: look/<event>/*.png, look/look.gif (owner review, G2).
  B-VIS   Supported mode (shutdown on). Showing steps: settled >= 7 s, then two hook snapshots 3 s apart: overlay.streams
          >= 1 and Overlay-mode reads >= 1 in between. Not-showing steps: streams must reach 0 within 11 s of the step
          (2 x 5 s SSE heartbeat + 1 s: after CEF closes the page cleanly the first keep-alive write still succeeds and
          only the second fails; time recorded); reads counted in a >= 5 s window starting 2 s after streams first
          reads 0 must be 0 (one read may be in flight). Steps: eye
          off/on; scene away/back; Studio Mode preview-only / program-only / both / neither; windowed projector on
          the scene opened then closed (WM_CLOSE to the owned projector window); the source referenced in 2 scenes
          (one showing, then none); a nested scene; a 1 s Fade transition in and out; OBS started with the item
          hidden, then shown. No screenshots. Shutdown-off: recorded under scenarios.B-VIS.shutdownOff, no check.
  B-ISO   Get-OwnerObsProfileSnapshot (SHA-256, size, mtime under %APPDATA%\obs-studio; listing of
          %LOCALAPPDATA%\obs-studio*) at start and after all cleanup: identical.
  B-DOCS  Window-scoped captures of the owned OBS windows only (PrintWindow of owned top-level windows of the OBS PID,
          composited onto the main window's frame; never the desktop): 01-sources-add.png (Sources + popup opened by
          WM_LBUTTONDOWN/UP posted to the UIA-located Add Source button; the real cursor is not moved; blocked if no
          owned popup appears within 3 s), 02-browser-properties.png (dialog opened with obs-websocket
          OpenInputPropertiesDialog, PrintWindow on its HWND, then WM_CLOSE), 03-add-source.gif (main window, menu,
          properties at ~1 fps), 04-overlay.gif (B-LOOK frames play -> track B -> pause; needs B-LOOK in the
          same run), 05-paused-dimmed.png (command-obs-hide-paused-off, page 47 s). Each GIF <= 3 MB. Written to
          <run>/docs-images/; copied to docs/images/obs-overlay/ only with -UpdateDocsImages. The owner reviews the
          images in the PR.

Report: <OutputDirectory>/<utc>/report.json (checks {name, expected, observed, status pass|fail|blocked}); no secrets.
Blocked never counts as pass; the exit code is 1 when any check fails or is blocked.
#>
[CmdletBinding()]
param(
    # One scenario id, All, or a comma-separated list (B-LOOK,B-VIS).
    [string[]] $Scenario = @('All'),
    [string] $OutputDirectory = 'artifacts/obs-overlay-obs',
    [switch] $UpdateDocsImages,
    [double] $TimeBoxMinutes = 30,
    [switch] $SkipPublish
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$allScenarios = @('B-LOOK', 'B-VIS', 'B-ISO', 'B-DOCS')
$Scenario = @($Scenario | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($name in $Scenario) {
    if ($name -ne 'All' -and $name -notin $allScenarios) { throw "Unknown scenario '$name'. Valid: All, $($allScenarios -join ', ')." }
}
$selected = if ('All' -in $Scenario) { $allScenarios } else { @($allScenarios | Where-Object { $_ -in $Scenario }) }

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
. (Join-Path $PSScriptRoot 'obs-portable.ps1')
$commandLine = 'pwsh -NoProfile -File scripts/obs-overlay-obs-e2e.ps1 ' + (($PSBoundParameters.GetEnumerator() | ForEach-Object {
    if ($_.Value -is [switch]) { if ($_.Value) { "-$($_.Key)" } } else { "-$($_.Key) $(@($_.Value) -join ',')" } }) -join ' ')
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
$appDirectory = Join-Path $repo 'artifacts/obs-overlay/app'
$appExe = Join-Path $appDirectory 'Nativune.exe'
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$runDirectory = Join-Path $outputRoot $runId
$lookDirectory = Join-Path $runDirectory 'look'
$docsOut = Join-Path $runDirectory 'docs-images'
$docsImages = Join-Path $repo 'docs/images/obs-overlay'
$rootBase = Join-Path $repo ".cache/obs-overlay-obs-e2e/$runId"
foreach ($d in @($runDirectory, $lookDirectory, $docsOut, $rootBase)) { [IO.Directory]::CreateDirectory($d) | Out-Null }
$deadlineUtc = [DateTime]::UtcNow.AddMinutes($TimeBoxMinutes)

$ubolVersion = [regex]::Match((Get-Content -Raw (Join-Path $repo 'src/Nativune/BrowserPrivacy.cs')),
    'ExtensionVersion\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $ubolVersion) { throw 'Could not read BrowserPrivacy.ExtensionVersion.' }
$ubolSource = Join-Path $repo ".tools/ubol/$ubolVersion"
if (-not (Test-Path -LiteralPath (Join-Path $ubolSource 'manifest.json') -PathType Leaf)) {
    throw "uBO Lite $ubolVersion is missing at $ubolSource (manifest.json). Provision the repository .tools/ubol tree first."
}

$port = 47813
$overlayUrl = "http://localhost:$port/"
$sourceName = 'Nativune Overlay'
$sceneName = 'Overlay'
$freq = [double] [Diagnostics.Stopwatch]::Frequency
$prefix = 'nativune-test-' + [guid]::NewGuid().ToString('N') + '-discord-ipc-'
$testEnv = [ordered]@{
    NATIVUNE_TEST_DISCORD_PIPE_PREFIX = $prefix
    NATIVUNE_TEST_DISCORD_CLIENT_ID = '100000000000000001'
    NATIVUNE_TEST_DISCORD_FIXTURE_PAGE = '1'
}
$benchEnvKeys = @('NATIVUNE_TEST_DISCORD_BENCH_PROFILE', 'NATIVUNE_TEST_DISCORD_BENCH_STATE', 'NATIVUNE_TEST_DISCORD_MIN_WRITE_SECONDS',
    'NATIVUNE_TEST_DISCORD_PAUSE_SECONDS')
$isElevated = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

$checks = [Collections.Generic.List[object]]::new()
$scenarioResults = [ordered]@{}
$eventsByReader = [ordered]@{}
$launches = [Collections.Generic.List[object]]::new()
$obsLaunches = [Collections.Generic.List[object]]::new()
$started = [Collections.Generic.List[Diagnostics.Process]]::new()
$readers = [Collections.Generic.List[object]]::new()
$obsInstances = [Collections.Generic.List[object]]::new()
$script:launchCount = 0
$script:labelSeq = 0
$script:lookFrames = $null
$script:python = $null

Add-Type -AssemblyName System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class ObsBE2E {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint msg, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [DllImport("user32.dll")] public static extern bool ScreenToClient(IntPtr h, ref POINT p);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  public static string ClassName(IntPtr h) { var t = new StringBuilder(256); GetClassName(h, t, 256); return t.ToString(); }
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
  [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
  // Visible top-level windows of the process, topmost first (EnumWindows order).
  public static IntPtr[] Windows(uint pid) {
    var list = new List<IntPtr>();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p == pid && IsWindowVisible(h)) list.Add(h); return true; }, IntPtr.Zero);
    return list.ToArray();
  }
  public static string Title(IntPtr h) { var t = new StringBuilder(512); GetWindowText(h, t, 512); return t.ToString(); }
  public static IntPtr OpenToken(int pid) {
    IntPtr p = OpenProcess(0x1000, false, pid); if (p == IntPtr.Zero) return IntPtr.Zero;
    try { IntPtr t; return OpenProcessToken(p, 0x0008 | 0x0002, out t) ? t : IntPtr.Zero; } finally { CloseHandle(p); }
  }
  public static void CloseToken(IntPtr t) { if (t != IntPtr.Zero) CloseHandle(t); }
  public static int Resume(int pid) {
    IntPtr p = OpenProcess(0x0800, false, pid); if (p == IntPtr.Zero) return -1;
    try { return NtResumeProcess(p); } finally { CloseHandle(p); }
  }
}
"@
$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]

# ---------------------------------------------------------------------------------------------------------------
# Report helpers (same check format as obs-overlay-e2e.ps1)

function Add-Check([string] $Name, $Expected, $Observed, [bool] $Passed) {
    $checks.Add([ordered]@{ name = $Name; expected = "$Expected"; observed = $Observed; status = if ($Passed) { 'pass' } else { 'fail' } })
}
function Add-Blocked([string] $Name, $Expected, [string] $Reason) {
    $checks.Add([ordered]@{ name = $Name; expected = "$Expected"; observed = $Reason; status = 'blocked' })
}
function Get-Prop($Object, [string] $Name) {
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $property = $Object.PSObject.Properties[$Name]
    if ($property) { $property.Value } else { $null }
}
function Get-Qpc { [double] [Diagnostics.Stopwatch]::GetTimestamp() }
function Wait-UntilQpc([double] $Qpc) {
    while ($true) {
        Assert-TimeBox
        $left = ($Qpc - (Get-Qpc)) / $freq
        if ($left -le 0) { return }
        Start-Sleep -Milliseconds ([int] [Math]::Max(5, [Math]::Min(250, $left * 1000)))
    }
}
function Wait-For([scriptblock] $Probe, [double] $Seconds, [int] $PollMs = 250) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $value = & $Probe
        if ($value) { return $value }
        Start-Sleep -Milliseconds $PollMs
    }
    & $Probe
}
function Wait-Seconds([double] $Seconds) { Wait-UntilQpc ((Get-Qpc) + $Seconds * $freq) }
function ConvertTo-SafeName([string] $Name) { ($Name -replace '[^A-Za-z0-9-]', '-') }
function Round3($Value) { if ($null -eq $Value) { $null } else { [Math]::Round([double] $Value, 3) } }
function Get-RelativePath([string] $Path) { [IO.Path]::GetRelativePath($runDirectory, $Path) }
# Hard time box: throws a TIMEBOX error that the runner records as blocked.
function Assert-TimeBox { if ([DateTime]::UtcNow -gt $deadlineUtc) { throw "TIMEBOX: the $TimeBoxMinutes min time box elapsed; approve more time to continue." } }

# ---------------------------------------------------------------------------------------------------------------
# App (pattern of obs-overlay-e2e.ps1: roots, settings, Basic-user launch, hook commands and state)

function New-Root([string] $Name) {
    $root = Join-Path $rootBase $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $ubolDestination = Join-Path $root '.tools/ubol'
    [IO.Directory]::CreateDirectory($ubolDestination) | Out-Null
    Copy-Item -LiteralPath $ubolSource -Destination $ubolDestination -Recurse
    [IO.Directory]::CreateDirectory((Join-Path $root 'data/discord-bench')) | Out-Null
    $root
}
function Write-Settings([string] $Root, [bool] $HidePaused = $true) {
    $data = Join-Path $Root 'data'
    [IO.Directory]::CreateDirectory($data) | Out-Null
    $settings = [ordered]@{
        Version = 7; X = 100; Y = 100; Width = 1280; Height = 800; Dpi = 96; Maximized = $false; Zoom = 1.0
        TrayEnabled = $true; RestoreSection = $false; LastSection = 'home'; ReduceMotion = $false
        CompactX = 100; CompactY = 100; CompactWidth = 800; CompactHeight = 180; CompactDpi = 96
        SleepInBackground = $false; StartCompact = $false; AutoCheckUpdates = $false
        OutputVolume = 1.0; BlockAds = $false
        DiscordPresence = $false; DiscordStatusLine = 0; DiscordOpenButton = $true
        ObsOverlay = $true; ObsHidePaused = $HidePaused
    }
    [IO.File]::WriteAllText((Join-Path $data 'settings.json'), ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}

$launchHelper = Join-Path $rootBase 'launch-helper.ps1'
[IO.File]::WriteAllText($launchHelper, @'
param([string] $SpecPath)
$ErrorActionPreference = 'Stop'
$spec = Get-Content -Raw -LiteralPath $SpecPath | ConvertFrom-Json
# Unset = remove the variable (PowerShell passes $null to .NET string parameters as ''); empty values are removed too.
foreach ($name in @($spec.unset)) { if ($name) { Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue } }
foreach ($p in $spec.env.PSObject.Properties) {
    if ([string]::IsNullOrEmpty([string] $p.Value)) { Remove-Item -LiteralPath "Env:$($p.Name)" -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable($p.Name, [string] $p.Value, 'Process') }
}
$proc = Start-Process -FilePath $spec.exe -ArgumentList @($spec.arguments) -WorkingDirectory $spec.workingDirectory -PassThru
[IO.File]::WriteAllText($spec.pidFile, (@{ processId = $proc.Id } | ConvertTo-Json -Compress))
'@, [Text.UTF8Encoding]::new($false))

# $null/'' removes the variable: the app treats an empty NATIVUNE_TEST_DISCORD_BENCH_* value as invalid (only an
# absent variable means command-only), and PowerShell passes $null to .NET string parameters as ''.
function Set-ProcessEnv([string] $Name, $Value) {
    if ([string]::IsNullOrEmpty([string] $Value)) { Remove-Item -LiteralPath "Env:$Name" -ErrorAction SilentlyContinue }
    else { [Environment]::SetEnvironmentVariable($Name, [string] $Value, 'Process') }
}
function Get-AdminEnabled([int] $ProcessId) {
    $token = [ObsBE2E]::OpenToken($ProcessId)
    if ($token -eq [IntPtr]::Zero) { return $null }
    try {
        $identity = [Security.Principal.WindowsIdentity]::new($token)
        try { [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
        finally { $identity.Dispose() }
    } finally { [ObsBE2E]::CloseToken($token) }
}
function Start-App([string] $Root, [hashtable] $Override = @{}) {
    $environment = [ordered]@{}
    foreach ($entry in $testEnv.GetEnumerator()) { $environment[$entry.Key] = $entry.Value }
    foreach ($key in $benchEnvKeys) { $environment[$key] = $null }
    foreach ($entry in $Override.GetEnumerator()) { $environment[$entry.Key] = $entry.Value }
    $workingDirectory = Split-Path -Parent $appExe
    $arguments = @('web', '--root', $Root)
    $script:launchCount++
    if ($isElevated) {
        $spec = Join-Path $rootBase "launch-$($script:launchCount).json"
        $pidFile = Join-Path $rootBase "launch-$($script:launchCount).pid.json"
        $set = [ordered]@{}; $unset = @()
        foreach ($entry in $environment.GetEnumerator()) { if ([string]::IsNullOrEmpty([string] $entry.Value)) { $unset += $entry.Key } else { $set[$entry.Key] = [string] $entry.Value } }
        [IO.File]::WriteAllText($spec, ([ordered]@{ exe = $appExe; arguments = $arguments; workingDirectory = $workingDirectory; env = $set; unset = $unset; pidFile = $pidFile } |
            ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
        & runas.exe '/trustlevel:0x20000' "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$launchHelper`" `"$spec`"" | Out-Null
        if (-not (Wait-For { Test-Path -LiteralPath $pidFile } 30)) { throw "runas /trustlevel launch helper wrote no PID file ($pidFile)." }
        $process = Get-Process -Id ([int] (Get-Content -Raw -LiteralPath $pidFile | ConvertFrom-Json).processId)
    } else {
        foreach ($entry in $environment.GetEnumerator()) { Set-ProcessEnv $entry.Key $entry.Value }
        $process = Start-Process -FilePath $appExe -ArgumentList $arguments -WorkingDirectory $workingDirectory -PassThru
    }
    $started.Add($process)
    $launches.Add([ordered]@{ launch = $script:launchCount; root = [IO.Path]::GetRelativePath($repo, $Root); processId = $process.Id
        viaRunas = $isElevated; adminEnabled = (Get-AdminEnabled $process.Id) })
    $process
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
function Get-BenchDirectory([string] $Root) { Join-Path $Root 'data/discord-bench' }
function Send-HookCommand([string] $Root, [string] $Name) {
    $directory = Get-BenchDirectory $Root
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $qpc = Get-Qpc
    [IO.File]::WriteAllText((Join-Path $directory $Name), 'go')
    $qpc
}
function Wait-BenchReady([string] $Root, [double] $Seconds = 90) {
    $directory = Get-BenchDirectory $Root
    [void] (Wait-For { (Test-Path -LiteralPath (Join-Path $directory 'ready.json')) -or (Test-Path -LiteralPath (Join-Path $directory 'failed.json')) } $Seconds)
    $path = Join-Path $directory 'ready.json'
    if (Test-Path -LiteralPath $path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json } else { $null }
}
function Get-State([string] $Root, [string] $Tag = 's') {
    $script:labelSeq++
    $label = ('s{0}-{1}' -f $script:labelSeq, ((ConvertTo-SafeName $Tag).ToLowerInvariant())).TrimEnd('-')
    if ($label.Length -gt 32) { $label = $label.Substring(0, 32).TrimEnd('-') }
    $directory = Get-BenchDirectory $Root
    $statePath = Join-Path $directory "state-$label.json"
    $diagPath = Join-Path $directory "diagnostics-$label.json"
    [void] (Send-HookCommand $Root "command-snapshot-$label")
    if (-not (Wait-For { (Test-Path -LiteralPath $statePath) -and (Test-Path -LiteralPath $diagPath) } 10 100)) { return $null }
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 16
    $diag = Get-Content -Raw -LiteralPath $diagPath | ConvertFrom-Json -Depth 16
    [pscustomobject]@{ label = $label; state = $state; diag = $diag; overlay = (Get-Prop $state 'overlay'); qpc = [double] (Get-Prop $diag 'boundaryQpc') }
}
function Get-Overlay($Snapshot, [string] $Field) { Get-Prop (Get-Prop $Snapshot 'overlay') $Field }
# Overlay-mode reads started in (Start.boundaryQpc, End.boundaryQpc].
function Get-OverlayReads($Start, $End) {
    if (-not $Start -or -not $End) { return $null }
    $s0 = [double] $Start.diag.boundaryQpc; $s1 = [double] $End.diag.boundaryQpc
    @(@(Get-Prop $End.diag 'reads') | Where-Object { $_ -and (Get-Prop $_ 'mode') -eq 'Overlay' -and [double] $_.startQpc -gt $s0 -and [double] $_.startQpc -le $s1 }).Count
}
function Stop-App($Process, [string] $Root) {
    if (-not $Process) { return }
    if (-not $Process.HasExited) {
        try { [void] (Send-HookCommand $Root 'command-quit') } catch { }
        if (-not $Process.WaitForExit(8000)) {
            foreach ($id in (Get-ProcessTree $Process.Id $Root)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine)) {
        if ($p.CommandLine -and $p.CommandLine.Contains($Root, [StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    $log = Join-Path $Root 'data/nativune.log'
    if (Test-Path -LiteralPath $log) { Copy-Item -LiteralPath $log -Destination (Join-Path $runDirectory "nativune-$(Split-Path -Leaf $Root).log") -Force }
    Copy-BenchJson $Root
}
# Keeps data/discord-bench/*.json of an app root in the run folder (roots are deleted on cleanup).
function Copy-BenchJson([string] $Root) {
    $directory = Get-BenchDirectory $Root
    if (-not (Test-Path -LiteralPath $directory)) { return }
    $destination = Join-Path $runDirectory "discord-bench-$(Split-Path -Leaf $Root)"
    [IO.Directory]::CreateDirectory($destination) | Out-Null
    foreach ($f in @(Get-ChildItem -LiteralPath $directory -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try { Copy-Item -LiteralPath $f.FullName -Destination $destination -Force } catch { }
    }
}
function Get-FailedJson([string] $Root) {
    $path = Join-Path (Get-BenchDirectory $Root) 'failed.json'
    if (Test-Path -LiteralPath $path) { try { (Get-Content -Raw -LiteralPath $path).Trim() } catch { "unreadable: $($_.Exception.Message)" } } else { $null }
}
function Test-OverlayHttp200 {
    try { $r = Invoke-WebRequest -Uri $overlayUrl -UseBasicParsing -TimeoutSec 5 -NoProxy; [int] $r.StatusCode -eq 200 } catch { $false }
}

# Mode-aware serving wait, polled every 500 ms up to $Seconds; all conditions must hold in the same pass.
# Bench profile: ready.json exists. Command-only fixture (default timeline, no ready.json is ever written): the fixture
# page is ready, i.e. an SSE data event playing fixtureSngA arrived (the Wait-Initial signal obs-overlay-e2e.ps1 uses for
# A-TIME). Both modes then need a fresh snapshot (command-snapshot-<label>) with overlay.running true and 200 on /.
function Wait-OverlayServing([string] $Root, [string] $BenchProfile, [double] $Seconds = 60) {
    $readyPath = Join-Path (Get-BenchDirectory $Root) 'ready.json'
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    $mode = if ($BenchProfile) { 'benchProfile' } else { 'commandOnly' }
    $last = [ordered]@{ ok = $false; mode = $mode; ready = $false; fixturePlaying = $null; running = $null; http200 = $false; snapshot = $null; failed = $false; failedJson = $null }
    $reader = $null
    try {
        if (-not $BenchProfile) { $reader = Start-SseReader "serving-$(Split-Path -Leaf $Root)-$([DateTime]::UtcNow.Ticks)" }
        while ($true) {
            Assert-TimeBox
            $last.failedJson = Get-FailedJson $Root
            $last.failed = $null -ne $last.failedJson
            if ($BenchProfile) { $last.ready = Test-Path -LiteralPath $readyPath }
            else {
                if ($last.fixturePlaying -ne $true) {
                    $last.fixturePlaying = [bool] (Find-FirstSseData $reader { param($d) Test-Data $d 'playing' 'fixtureSngA' })
                }
                $last.ready = $last.fixturePlaying
            }
            $last.running = $null; $last.snapshot = $null; $last.http200 = $false
            if ($last.ready -and -not $last.failed) {
                # Fresh snapshot: Get-State sends a new command-snapshot-<label> and reads state-<label>.json.
                $s = Get-State $Root 'running'
                $last.snapshot = if ($s) { $s.label } else { $null }
                $last.running = Get-Overlay $s 'running'
                $last.http200 = [bool] (Test-OverlayHttp200)
            }
            if ($last.ready -and -not $last.failed -and $last.running -eq $true -and $last.http200) { $last.ok = $true; return $last }
            if ($last.failed -or [DateTime]::UtcNow -ge $deadline) { return $last }
            Start-Sleep -Milliseconds 500
        }
    } finally { Stop-SseReader $reader }
}
function Find-FirstSseData($Reader, [scriptblock] $Predicate) {
    @(Read-Sse $Reader) | Where-Object { $null -ne $_ -and $_.kind -eq 'data' -and $_.data -and (& $Predicate $_.data) } | Select-Object -First 1
}
function Assert-OverlayServing($App, [string] $Label, [string] $CheckName) {
    $w = Wait-OverlayServing $App.Root $App.BenchProfile 60
    $observed = [ordered]@{ mode = $w.mode; ready = $w.ready; fixturePlaying = $w.fixturePlaying; failed = $w.failed; failedJson = $w.failedJson
        running = $w.running; http200 = $w.http200; snapshot = $w.snapshot; adminEnabled = (Get-AdminEnabled $App.App.Id) }
    $expected = if ($App.BenchProfile) { 'ready.json, fresh overlay.running true and 200 on / together before OBS launches' }
    else { 'command-only fixture: SSE playing fixtureSngA, fresh overlay.running true and 200 on / together before OBS launches' }
    Add-Check $CheckName $expected $observed $w.ok
    if (-not $w.ok) {
        throw "$Label`: the overlay app is not serving after 60 s (mode=$($w.mode) ready=$($w.ready) fixturePlaying=$($w.fixturePlaying) running=$($w.running) http200=$($w.http200) snapshot=$($w.snapshot) failed.json=$(if ($w.failed) { $w.failedJson } else { 'absent' })); OBS is not launched."
    }
}
# Starts the app first (plan D13); the serving wait runs in Start-ObsSession before every OBS launch.
function Start-OverlayApp([string] $Name, [string] $BenchProfile = $null, [string] $CheckPrefix) {
    $root = New-Root $Name
    Write-Settings $root $true
    $launchEnv = @{}
    if ($BenchProfile) { $launchEnv['NATIVUNE_TEST_DISCORD_BENCH_PROFILE'] = $BenchProfile; $launchEnv['NATIVUNE_TEST_DISCORD_BENCH_STATE'] = 'Full' }
    $app = Start-App $root $launchEnv
    # Cold start: with a bench profile allow the fixture up to 120 s to write ready.json before the 60 s serving wait.
    # Command-only mode never writes ready.json; its readiness is checked in Wait-OverlayServing.
    if ($BenchProfile) { [void] (Wait-BenchReady $root 120) }
    [pscustomobject]@{ Name = $Name; Root = $root; App = $app; CheckPrefix = $CheckPrefix; BenchProfile = $BenchProfile }
}

# ---------------------------------------------------------------------------------------------------------------
# SSE reader child process (B-LOOK event times; pattern of obs-overlay-e2e.ps1)

$sseReaderScript = @'
param([string] $Url, [string] $Out, [double] $ConnectSeconds)
$ErrorActionPreference = 'Stop'
$fs = [IO.FileStream]::new($Out, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
$w = [IO.StreamWriter]::new($fs, [Text.UTF8Encoding]::new($false)); $w.AutoFlush = $true
function Log([string] $Kind, [string] $Field, $Value) {
    $o = [ordered]@{ qpc = [Diagnostics.Stopwatch]::GetTimestamp(); utc = [DateTime]::UtcNow.ToString('o'); kind = $Kind }
    if ($Field) { $o[$Field] = $Value }
    $w.WriteLine(($o | ConvertTo-Json -Compress -Depth 3))
}
$handler = [Net.Http.SocketsHttpHandler]::new(); $handler.UseProxy = $false
$client = [Net.Http.HttpClient]::new($handler); $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
$deadline = [DateTime]::UtcNow.AddSeconds($ConnectSeconds); $response = $null
while (-not $response) {
    try {
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Url)
        $r = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
        if ([int] $r.StatusCode -eq 200) { $response = $r } else { Log 'error' 'text' ('status ' + [int] $r.StatusCode); $r.Dispose() }
    } catch { Log 'error' 'text' $_.Exception.GetBaseException().Message }
    if (-not $response) {
        if ([DateTime]::UtcNow -gt $deadline) { Log 'close' 'text' 'connect-timeout'; exit 2 }
        Start-Sleep -Milliseconds 250
    }
}
Log 'open' 'text' ('{0} {1}' -f [int] $response.StatusCode, $response.Content.Headers.ContentType)
$reader = [IO.StreamReader]::new($response.Content.ReadAsStream(), [Text.UTF8Encoding]::new($false))
try {
    while ($null -ne ($line = $reader.ReadLine())) {
        if ($line.StartsWith('data:')) { $v = $line.Substring(5); if ($v.StartsWith(' ')) { $v = $v.Substring(1) }; Log 'data' 'json' $v }
        elseif ($line.StartsWith(':')) { Log 'comment' 'text' $line }
    }
    Log 'close' 'text' 'eof'
} catch { Log 'close' 'text' $_.Exception.GetBaseException().Message }
'@
function Start-SseReader([string] $Name) {
    $safe = ConvertTo-SafeName $Name
    $out = Join-Path $runDirectory "events-$safe.jsonl"
    $command = "& { $sseReaderScript } -Url '$($overlayUrl)events' -Out '$($out -replace "'", "''")' -ConnectSeconds 60"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process -FilePath pwsh -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -PassThru -WindowStyle Hidden
    $reader = [pscustomobject]@{ Name = $safe; Path = $out; Process = $process; Stopped = $false }
    $readers.Add($reader)
    $reader
}
function Read-Sse($Reader) {
    if (-not $Reader -or -not (Test-Path -LiteralPath $Reader.Path)) { return @() }
    $fs = [IO.FileStream]::new($Reader.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { $text = [IO.StreamReader]::new($fs, [Text.UTF8Encoding]::new($false)).ReadToEnd() } finally { $fs.Dispose() }
    $list = [Collections.Generic.List[object]]::new()
    foreach ($line in ($text -split "`n")) {
        if (-not $line.Trim()) { continue }
        $o = try { $line | ConvertFrom-Json -Depth 8 } catch { $null }
        if (-not $o) { continue }
        $data = $null
        if ($o.kind -eq 'data') { $data = try { [string] $o.json | ConvertFrom-Json -Depth 8 } catch { $null } }
        $list.Add([pscustomobject]@{ qpc = [double] $o.qpc; kind = $o.kind; text = (Get-Prop $o 'text'); json = (Get-Prop $o 'json'); data = $data })
    }
    return $list.ToArray()
}
function Stop-SseReader($Reader) {
    if (-not $Reader -or $Reader.Stopped) { return }
    $Reader.Stopped = $true
    try { if (-not $Reader.Process.HasExited) { Stop-Process -Id $Reader.Process.Id -Force -ErrorAction SilentlyContinue; [void] $Reader.Process.WaitForExit(5000) } } catch { }
    $eventsByReader[$Reader.Name] = @(@(Read-Sse $Reader) | Where-Object { $null -ne $_ } | ForEach-Object { [ordered]@{ qpc = $_.qpc; kind = $_.kind; text = $_.text; json = $_.json } })
}
function Wait-SseData($Reader, [scriptblock] $Predicate, [double] $Seconds, [double] $AfterQpc = 0) {
    Wait-For { @(Read-Sse $Reader) | Where-Object { $null -ne $_ -and $_.kind -eq 'data' -and $_.data -and $_.qpc -gt $AfterQpc -and (& $Predicate $_.data) } | Select-Object -First 1 } $Seconds
}
function Find-SseData($Reader, [scriptblock] $Predicate, [double] $AfterQpc) {
    @(Read-Sse $Reader) | Where-Object { $null -ne $_ -and $_.kind -eq 'data' -and $_.data -and $_.qpc -gt $AfterQpc -and (& $Predicate $_.data) } | Select-Object -First 1
}
function Test-Data($D, [string] $State, [string] $Id = $null) { (Get-Prop $D 'state') -eq $State -and (-not $Id -or (Get-Prop $D 'id') -eq $Id) }
function Get-PageStartQpc($Initial) {
    [double] $Initial.qpc - (([double] (Get-Prop $Initial.data 'ageMs')) / 1000 + [double] (Get-Prop $Initial.data 'position')) * $freq
}

# ---------------------------------------------------------------------------------------------------------------
# OBS sessions

# $ItemHidden: create the scene item disabled. $ShutdownOff: create the browser input with shutdown=false.
# The scene is created through obs-websocket right after connecting (Initialize-ObsOverlayScene).
function Start-ObsSession([string] $Label, [string] $CheckPrefix, $App, [switch] $ItemHidden, [switch] $ShutdownOff) {
    Assert-TimeBox
    Assert-OverlayServing $App $Label "$CheckPrefix.$Label.appListeningBeforeObs"
    $obs = New-ObsPortable -RunDir (Join-Path $repo ".cache/obs-portable/$runId-$Label")
    $obsInstances.Add($obs)
    $record = [ordered]@{ label = $Label; itemHidden = [bool] $ItemHidden; shutdownOff = [bool] $ShutdownOff; owned = $null; paths = $null; scene = $null }
    $obsLaunches.Add($record)
    try { [void] (Start-ObsPortable $obs) } finally { $record.owned = $obs.OwnedCheck }
    Add-Check "$CheckPrefix.$Label.ownedInstance" "launched PID+creation time, websocket listener PID = OBS PID, GetVersion $script:ObsPortableVersion" $obs.OwnedCheck ([bool] $obs.OwnedCheck.passed)
    $ws = Connect-ObsWebSocket $obs
    $scene = Initialize-ObsOverlayScene $ws -Shutdown (-not $ShutdownOff) -ItemEnabled (-not $ItemHidden)
    $record.scene = [ordered]@{ sceneItemId = $scene.sceneItemId; shutdown = Get-Prop $scene.settings 'shutdown'; itemEnabled = -not $ItemHidden }
    [pscustomobject]@{ Label = $Label; Obs = $obs; Ws = $ws; Record = $record; Prefix = $CheckPrefix; ItemId = $scene.sceneItemId }
}
# Graceful close + relaunch of the same run folder; reconnects the session's websocket.
function Restart-ObsSession($Session) {
    Close-ObsWebSocket $Session.Ws; $Session.Ws = $null
    try { $graceful = Restart-ObsPortable $Session.Obs } finally { $Session.Record.relaunchOwned = $Session.Obs.OwnedCheck }
    Add-Check "$($Session.Prefix).$($Session.Label).relaunchOwnedInstance" 'relaunched same run folder: owned-instance check passes' $Session.Obs.OwnedCheck ([bool] $Session.Obs.OwnedCheck.passed)
    $Session.Ws = Connect-ObsWebSocket $Session.Obs
    $graceful
}
# Wait until the page has connected (overlay streams >= 1) so obs-browser has written its cache files.
function Wait-OverlayStream($App, [double] $Seconds = 30) {
    [bool] (Wait-For { $s = Get-State $App.Root 'streamwait'; [int] (Get-Overlay $s 'streams') -ge 1 } $Seconds 500)
}
# Observed paths after the page loaded (plan §6.2, W6).
# With $PageExpected, first wait until the browser source has loaded (overlay streams >= 1), then allow obs-browser
# up to 15 s to write its files before the paths are evaluated.
function Test-ObsPaths($Session, [bool] $PageExpected, $App = $null) {
    if ($PageExpected) {
        if ($App) { $Session.Record.pageStreamed = Wait-OverlayStream $App 30 }
        $browserDir = Join-Path $Session.Obs.ConfigDir 'plugin_config\obs-browser'
        [void] (Wait-For { (Test-Path -LiteralPath $browserDir) -and @(Get-ChildItem -LiteralPath $browserDir -Recurse -File -Force -ErrorAction SilentlyContinue).Count -gt 0 } 15 500)
    }
    $paths = Update-ObsPortablePaths $Session.Obs
    $Session.Record.paths = $paths
    $o = $paths.observed
    $ok = $o.logsFresh -gt 0 -and $o.profileFresh -gt 0 -and $o.allPagePathsUnderRun
    if ($PageExpected) { $ok = $ok -and $o.obsBrowserFiles -gt 0 -and @($o.browserPages).Count -gt 0 }
    Add-Check "$($Session.Prefix).$($Session.Label).pathsUnderRun" 'fresh files in <run>\config\obs-studio\logs and profile; obs-browser gained files; every obs-browser-page cache/user-data/log path under <run>' $paths $ok
}
function Stop-ObsSession($Session) {
    if (-not $Session) { return }
    Close-ObsWebSocket $Session.Ws
    try { Stop-ObsPortable $Session.Obs } catch {
        Add-Check "B-ISO.$($Session.Label).ownerProfileUnchangedAtStop" 'owner OBS profile unchanged when the disposable OBS stopped' $_.Exception.Message $false
    }
}
function Obs([object] $Session, [string] $Type, [hashtable] $Data = @{}) { Invoke-ObsRequest $Session.Ws $Type $Data }

function Get-ObsMainWindow($Session) {
    $p = $Session.Obs.Process; $p.Refresh()
    $h = Wait-For { $p.Refresh(); if ($p.MainWindowHandle -ne [IntPtr]::Zero) { $p.MainWindowHandle } } 30 300
    if (-not $h) { throw 'OBS main window not found.' }
    $h
}
function Get-FrameRect([IntPtr] $Hwnd) {
    $r = New-Object ObsBE2E+RECT
    if ([ObsBE2E]::DwmGetWindowAttribute($Hwnd, 9, [ref] $r, 16) -ne 0 -or $r.Right -le $r.Left) { [void] [ObsBE2E]::GetWindowRect($Hwnd, [ref] $r) }
    $r
}
function Get-WindowBitmap([IntPtr] $Hwnd) {
    $wr = New-Object ObsBE2E+RECT; [void] [ObsBE2E]::GetWindowRect($Hwnd, [ref] $wr)
    $w = $wr.Right - $wr.Left; $h = $wr.Bottom - $wr.Top
    if ($w -le 0 -or $h -le 0) { return $null }
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
    [void] [ObsBE2E]::PrintWindow($Hwnd, $hdc, 2); $g.ReleaseHdc($hdc); $g.Dispose()
    $fr = Get-FrameRect $Hwnd
    $crop = New-Object System.Drawing.Rectangle ([Math]::Max(0, $fr.Left - $wr.Left)), ([Math]::Max(0, $fr.Top - $wr.Top)), ([Math]::Min($w, $fr.Right - $fr.Left)), ([Math]::Min($h, $fr.Bottom - $fr.Top))
    $out = $bmp.Clone($crop, $bmp.PixelFormat); $bmp.Dispose()
    [pscustomobject]@{ Bitmap = $out; Left = [Math]::Max($fr.Left, $wr.Left); Top = [Math]::Max($fr.Top, $wr.Top) }
}
# Window-scoped capture: only the owned OBS process's visible top-level windows (main window, its menus and
# dialogs), each rendered with PrintWindow and composited bottom-to-top onto the main window's frame. No screen copy.
function Save-ObsWindowShot($Session, [string] $Path) {
    $main = Get-ObsMainWindow $Session
    $mr = Get-FrameRect $main
    $canvas = New-Object System.Drawing.Bitmap ($mr.Right - $mr.Left), ($mr.Bottom - $mr.Top)
    $g = [System.Drawing.Graphics]::FromImage($canvas)
    try {
        $g.Clear([System.Drawing.Color]::Black)
        $windows = @([ObsBE2E]::Windows([uint32] $Session.Obs.ProcessId)); [Array]::Reverse($windows)
        $ordered = @($main) + @($windows | Where-Object { $_ -ne $main })
        foreach ($h in $ordered) {
            $shot = Get-WindowBitmap $h
            if (-not $shot) { continue }
            try { $g.DrawImage($shot.Bitmap, $shot.Left - $mr.Left, $shot.Top - $mr.Top, $shot.Bitmap.Width, $shot.Bitmap.Height) } finally { $shot.Bitmap.Dispose() }
        }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
        $canvas.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally { $g.Dispose(); $canvas.Dispose() }
    $Path
}
function Get-SourceShotBytes($Session) {
    $r = Obs $Session 'GetSourceScreenshot' @{ sourceName = $sourceName; imageFormat = 'png'; imageWidth = 440; imageHeight = 96 }
    $data = [string] $r.imageData
    [Convert]::FromBase64String($data.Substring($data.IndexOf(',') + 1))
}

# ---------------------------------------------------------------------------------------------------------------
# Pillow analysis and GIF encoding (installed Python + Pillow 12.3; absent -> blocked)

$analyzeScript = Join-Path $rootBase 'analyze-look.py'
[IO.File]::WriteAllText($analyzeScript, @'
import json, sys, colorsys
from PIL import Image

X0, Y0, W, H, R = 20, 20, 400, 56, 28

def load(p):
    return Image.open(p).convert('RGBA')

def in_round(x, y, x0, y0, w, h, r):
    px, py = x + 0.5, y + 0.5
    if px < x0 or px > x0 + w or py < y0 or py > y0 + h:
        return False
    cx = min(max(px, x0 + r), x0 + w - r)
    cy = min(max(py, y0 + r), y0 + h - r)
    return (px - cx) ** 2 + (py - cy) ** 2 <= r * r

def mask(img):
    # Spec: inside the pill inset 2 px alpha >= 0.9; alpha>200 bbox == pill rect +-1 px; outside the pill beyond a
    # 2 px anti-alias ring alpha <= 170 (box-shadow rgba(0,0,0,.65) max = 166 + rounding).
    a = img.getchannel('A').load()
    iw, ih = img.size
    inside_n = inside_low = 0
    outside_n = outside_bad = 0; max_out = 0; shadow_n = 0
    bx0 = by0 = None; bx1 = by1 = None
    for y in range(ih):
        for x in range(iw):
            v = a[x, y]
            if v > 200:
                bx0 = x if bx0 is None else min(bx0, x); by0 = y if by0 is None else min(by0, y)
                bx1 = x + 1 if bx1 is None else max(bx1, x + 1); by1 = y + 1 if by1 is None else max(by1, y + 1)
            if in_round(x, y, X0 + 2, Y0 + 2, W - 4, H - 4, R - 2):
                inside_n += 1
                if v < 0.9 * 255: inside_low += 1
            elif not in_round(x, y, X0 - 2, Y0 - 2, W + 4, H + 4, R + 2):
                outside_n += 1
                if v > 0: shadow_n += 1
                max_out = max(max_out, v)
                if v > 170: outside_bad += 1
    bbox = None if bx0 is None else [bx0, by0, bx1, by1]
    bbox_ok = bbox is not None and all(abs(p - q) <= 1 for p, q in zip(bbox, [X0, Y0, X0 + W, Y0 + H]))
    return {'insidePixels': inside_n, 'insideBelow09': inside_low, 'alpha200BBox': bbox,
            'expectedBBox': [X0, Y0, X0 + W, Y0 + H], 'bboxOk': bbox_ok, 'outsidePixels': outside_n,
            'outsideNonZero': shadow_n, 'outsideAbove170': outside_bad, 'maxOutsideAlpha': max_out,
            'pass': inside_n > 0 and inside_low == 0 and bbox_ok and outside_bad == 0}

def row_alpha(img):
    a = img.getchannel('A').load()
    iw, ih = img.size
    return [sum(a[x, y] for x in range(60, 380)) / 320.0 / 255.0 for y in range(ih)]

def opacity(img):
    return max(row_alpha(img))

def top_edge(img):
    rows = row_alpha(img); m = max(rows)
    if m <= 0.02: return None
    for y, v in enumerate(rows):
        if v >= 0.5 * m: return y
    return None

def columns(img, fn):
    px = img.load(); out = []
    for x in range(X0 + 2, X0 + W - 2):
        vals = []
        for y in range(40, 57):
            r, g, b, a = px[x, y]
            if a < 200 or min(r, g, b) > 200: continue  # skip glyphs and translucent pixels
            vals.append(fn(r, g, b))
        out.append(sum(vals) / len(vals) if vals else None)
    return out

def sat(r, g, b): return colorsys.rgb_to_hsv(r / 255, g / 255, b / 255)[1]
def lum(r, g, b): return (0.2126 * r + 0.7152 * g + 0.0722 * b) / 255

def reveal(img):
    s = columns(img, sat); n = len(s); best = None; bx = None; k = 8
    for i in range(k, n - k):
        left = [v for v in s[i - k:i] if v is not None]; right = [v for v in s[i:i + k] if v is not None]
        if len(left) < k // 2 or len(right) < k // 2: continue
        d = sum(left) / len(left) - sum(right) / len(right)
        if best is None or d > best: best, bx = d, i
    return (None if bx is None else X0 + 2 + bx), best

def profile_shift(a, b, start):
    pa = columns(a, lum); pb = columns(b, lum); lo = max(0, start - (X0 + 2)); best = None; bs = None
    for s in range(-10, 11):
        diffs = []
        for i in range(lo, len(pa)):
            j = i + s
            if 0 <= j < len(pb) and pa[i] is not None and pb[j] is not None: diffs.append(abs(pa[i] - pb[j]))
        if len(diffs) < 40: continue
        m = sum(diffs) / len(diffs)
        if best is None or m < best: best, bs = m, s
    return bs, best

def glyphs(img):
    px = img.load(); s = set()
    for y in range(26, 71):
        for x in range(50, 391):
            r, g, b, a = px[x, y]
            if a > 200 and min(r, g, b) > 200: s.add((x, y))
    return s

def look(spec):
    out = {}
    t0, t10 = load(spec['stills']['t0']), load(spec['stills']['t10'])
    out['mask'] = {'t0': mask(t0), 't10': mask(t10)}
    rv = {}
    for key, img in (('t0', t0), ('t10', t10)):
        x, strength = reveal(img); exp = X0 + W * spec['stills']['p_' + key]
        rv[key] = {'x': x, 'expected': round(exp, 1), 'strength': strength, 'pass': x is not None and abs(x - exp) <= 6}
    out['reveal'] = rv
    start = max([v['x'] for v in rv.values() if v['x'] is not None] or [X0]) + 12
    shift, err = profile_shift(t0, t10, start)
    out['artFixed'] = {'shiftPx': shift, 'meanAbsDiff': err, 'fromX': start, 'pass': shift is not None and abs(shift) <= 3}
    ev = spec['events']
    def series(name):
        return [(f['t'], load(f['path'])) for f in ev.get(name, [])]
    # show (play)
    fr = series('play')
    if fr:
        settled = opacity(fr[-1][1]) or 1e-6
        rows = [{'t': t, 'o': opacity(i) / settled, 'top': top_edge(i)} for t, i in fr]
        after = [r for r in rows if r['t'] >= 0]
        inter = [r for r in after if 0.1 < r['o'] < 0.9]
        vis = [r for r in after if r['o'] >= 0.05 and r['top'] is not None]
        tops = [r['top'] for r in vis]
        mono = all(tops[i + 1] <= tops[i] + 1 for i in range(len(tops) - 1))
        settled_at = None
        for i, r in enumerate(after):
            if all(abs(q['o'] - 1) <= 0.05 and q['top'] is not None and abs(q['top'] - 20) <= 2 for q in after[i:]):
                settled_at = r['t']; break
        out['show'] = {'frames': rows, 'intermediate': len(inter), 'firstVisibleTop': tops[0] if tops else None,
            'settledTop': rows[-1]['top'], 'monotone': mono, 'settledAt': settled_at,
            'passIntermediate': len(inter) >= 2,
            'passRise': bool(tops) and 26 <= tops[0] <= 34 and rows[-1]['top'] is not None and abs(rows[-1]['top'] - 20) <= 2 and mono,
            'passSettled': settled_at is not None and settled_at <= 2.5}
    fr = series('pause')
    if fr:
        pre = [opacity(i) for t, i in fr if t < 0] or [opacity(fr[0][1])]
        ref = (sum(pre) / len(pre)) or 1e-6
        rows = [{'t': t, 'o': opacity(i) / ref, 'alpha': opacity(i)} for t, i in fr]
        inter = [r for r in rows if r['t'] >= 0 and 0.1 < r['o'] < 0.9]
        late = [r for r in rows if r['t'] >= 2.5]
        out['hide'] = {'frames': rows, 'intermediate': len(inter), 'lateMaxAlpha': max([r['alpha'] for r in late], default=None),
            'passIntermediate': len(inter) >= 2, 'passGone': bool(late) and all(r['alpha'] <= 0.1 for r in late)}
    fr = series('trackB')
    if fr:
        before = [i for t, i in fr if t < 0]
        a = glyphs(before[-1] if before else fr[0][1]); b = glyphs(fr[-1][1])
        region = (391 - 50) * (71 - 26); diff = len(a ^ b)
        out['text'] = {'glyphsA': len(a), 'glyphsB': len(b), 'differing': diff, 'fraction': diff / region,
            'pass': len(a) > 0 and len(b) > 0 and diff / region >= 0.01}
    fr = series('seek')
    if fr:
        x, strength = reveal(fr[-1][1]); exp = X0 + W * spec['seekP']
        out['seekReveal'] = {'x': x, 'expected': round(exp, 1), 'strength': strength, 'pass': x is not None and abs(x - exp) <= 6}
    return out

def gif(spec):
    import os
    frames = [Image.open(p).convert('RGBA') for p in spec['frames']]
    if not frames: return {'error': 'no frames'}
    limit = spec.get('maxBytes', 3 * 1024 * 1024); tried = []
    for width in spec.get('widths', [frames[0].width]):
        scale = min(1.0, width / frames[0].width)
        conv = []
        for f in frames:
            bg = Image.new('RGBA', f.size, tuple(spec.get('background', [0, 0, 0, 255])))
            g = Image.alpha_composite(bg, f).convert('RGB')
            if scale < 1.0: g = g.resize((max(1, int(f.width * scale)), max(1, int(f.height * scale))), Image.LANCZOS)
            conv.append(g.quantize(colors=128, method=Image.Quantize.MEDIANCUT))
        conv[0].save(spec['out'], save_all=True, append_images=conv[1:], duration=spec.get('durations', spec.get('durationMs', 100)), loop=0, optimize=True)
        size = os.path.getsize(spec['out']); tried.append({'width': conv[0].width, 'bytes': size})
        if size <= limit: break
    return {'out': spec['out'], 'bytes': tried[-1]['bytes'], 'tried': tried, 'frames': len(frames)}

def alpha_at(spec):
    img = load(spec['path'])
    return {'opacity': opacity(img), 'mask': mask(img) if spec.get('mask') else None}

mode, path = sys.argv[1], sys.argv[2]
spec = json.load(open(path, encoding='utf-8'))
res = {'look': look, 'gif': gif, 'still': alpha_at}[mode](spec)
print(json.dumps(res))
'@, [Text.UTF8Encoding]::new($false))

function Resolve-Python {
    if ($script:python) { return $script:python }
    foreach ($candidate in @('python', 'py')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if (-not $cmd) { continue }
        $v = & $cmd.Source -c 'import PIL; print(PIL.__version__)' 2>$null
        if ($LASTEXITCODE -eq 0 -and $v) { $script:python = [pscustomobject]@{ Exe = $cmd.Source; Pillow = "$v".Trim() }; return $script:python }
    }
    $null
}
function Invoke-Pillow([string] $Mode, $Spec) {
    $py = Resolve-Python
    if (-not $py) { throw 'PILLOW: Python with Pillow not found.' }
    $specPath = Join-Path $rootBase ("pillow-{0}-{1}.json" -f $Mode, [guid]::NewGuid().ToString('N').Substring(0, 8))
    [IO.File]::WriteAllText($specPath, ($Spec | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
    $out = & $py.Exe $analyzeScript $Mode $specPath
    if ($LASTEXITCODE -ne 0) { throw "Pillow $Mode analysis failed (exit $LASTEXITCODE)." }
    ($out -join "`n") | ConvertFrom-Json -Depth 16
}

# ---------------------------------------------------------------------------------------------------------------
# B-LOOK

# Captures GetSourceScreenshot frames at 10 fps between two QPC instants; returns frame records and the achieved rate.
function Invoke-CaptureWindow($Session, [string] $Name, [double] $FromQpc, [double] $ToQpc) {
    $dir = Join-Path $lookDirectory $Name
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    Wait-UntilQpc $FromQpc
    $raw = [Collections.Generic.List[object]]::new()
    $next = $FromQpc
    while ((Get-Qpc) -lt $ToQpc) {
        $q = Get-Qpc
        $bytes = Get-SourceShotBytes $Session
        $raw.Add([pscustomobject]@{ qpc = ($q + (Get-Qpc)) / 2; bytes = $bytes })
        $next += 0.1 * $freq
        while ($next -lt (Get-Qpc)) { $next += 0.1 * $freq }
        Wait-UntilQpc ([Math]::Min($next, $ToQpc))
    }
    $seconds = ($ToQpc - $FromQpc) / $freq
    $frames = for ($i = 0; $i -lt $raw.Count; $i++) {
        $path = Join-Path $dir ('{0:D3}.png' -f $i)
        [IO.File]::WriteAllBytes($path, $raw[$i].bytes)
        [pscustomobject]@{ path = $path; qpc = $raw[$i].qpc }
    }
    [pscustomobject]@{ Name = $Name; Frames = @($frames); Fps = Round3 ($raw.Count / $seconds); Seconds = Round3 $seconds }
}
function Save-SourceStill($Session, [string] $Name) {
    $q = Get-Qpc
    $bytes = Get-SourceShotBytes $Session
    $path = Join-Path $lookDirectory "$Name.png"
    [IO.File]::WriteAllBytes($path, $bytes)
    [pscustomobject]@{ path = $path; qpc = ($q + (Get-Qpc)) / 2 }
}

$lookEvents = @(
    @{ name = 'seek'; at = 25; test = { param($d) (Test-Data $d 'playing' 'fixtureSngA') -and [Math]::Abs([double] (Get-Prop $d 'position') - 100) -le 1.5 } },
    @{ name = 'pause'; at = 45; test = { param($d) Test-Data $d 'paused' 'fixtureSngA' } },
    @{ name = 'play'; at = 60; test = { param($d) Test-Data $d 'playing' 'fixtureSngA' } },
    @{ name = 'trackB'; at = 80; test = { param($d) Test-Data $d 'playing' 'fixtureSngB' } })

function Test-BLook($App, $Session) {
    $obs = [ordered]@{}
    $reader = Start-SseReader 'B-LOOK'
    try {
        $showing = Wait-For { $s = Get-State $App.Root 'look-streams'; if ((Get-Overlay $s 'streams') -ge 2) { $s } } 60 1000
        Add-Check 'B-LOOK.sourceConnected' 'OBS page and harness reader both connected (streams >= 2)' (Get-Overlay $showing 'streams') ([bool] $showing)
        Test-ObsPaths $Session $true $App
        $navQpc = Send-HookCommand $App.Root 'command-navigate'
        $initial = Wait-SseData $reader { param($d) (Test-Data $d 'playing' 'fixtureSngA') -and [double] (Get-Prop $d 'position') -lt 15 } 60 $navQpc
        if (-not $initial) { Add-Blocked 'B-LOOK.timeline' 'fixture timeline restarted by command-navigate' 'no playing A event within 60 s'; return }
        $start = Get-PageStartQpc $initial
        $duration = [double] (Get-Prop $initial.data 'duration')
        $obs.durationA = $duration
        Wait-UntilQpc ($start + 8 * $freq); $t0 = Save-SourceStill $Session 't0'
        Wait-UntilQpc ($start + 18 * $freq); $t10 = Save-SourceStill $Session 't10'
        $windows = [ordered]@{}
        foreach ($e in $lookEvents) {
            $windows[$e.name] = Invoke-CaptureWindow $Session $e.name ($start + ($e.at - 0.5) * $freq) ($start + ($e.at + 3.5) * $freq)
        }
        Start-Sleep -Seconds 1
        $events = [ordered]@{}; $eventInfo = [ordered]@{}
        foreach ($e in $lookEvents) {
            $predicted = $start + $e.at * $freq
            $hit = Find-SseData $reader $e.test ($predicted - 2 * $freq)
            $evQpc = if ($hit -and $hit.qpc -lt $predicted + 3.5 * $freq) { $hit.qpc } else { $predicted }
            $w = $windows[$e.name]
            $eventInfo[$e.name] = [ordered]@{ predictedPage = $e.at; receivedPage = if ($hit) { Round3 (($hit.qpc - $start) / $freq) } else { $null }
                source = if ($hit -and $evQpc -eq $hit.qpc) { 'sse' } else { 'predicted' }; fps = $w.Fps; frames = $w.Frames.Count }
            if ($w.Fps -lt 8) {
                Add-Blocked "B-LOOK.$($e.name).captureRate" '>= 8 fps GetSourceScreenshot capture (target 10)' "achieved $($w.Fps) fps"
            } else {
                Add-Check "B-LOOK.$($e.name).captureRate" '>= 8 fps GetSourceScreenshot capture (target 10)' $w.Fps $true
            }
            $events[$e.name] = @($w.Frames | ForEach-Object { [ordered]@{ path = $_.path; t = Round3 (($_.qpc - $evQpc) / $freq) } })
        }
        $obs.events = $eventInfo
        $pageOf = { param($q) ($q - $start) / $freq }
        $seekLast = $windows['seek'].Frames[-1]
        $spec = [ordered]@{
            stills = [ordered]@{ t0 = $t0.path; t10 = $t10.path; p_t0 = (& $pageOf $t0.qpc) / $duration; p_t10 = (& $pageOf $t10.qpc) / $duration }
            seekP = (100 + (& $pageOf $seekLast.qpc) - 25) / $duration
            events = $events
        }
        $a = Invoke-Pillow 'look' $spec
        $obs.analysis = $a
        $blockedRate = @($checks | Where-Object { $_.name -like 'B-LOOK.*.captureRate' -and $_.status -eq 'blocked' }).Count -gt 0
        Add-Check 'B-LOOK.mask.t0' 'alpha >= 0.9 inside the inset rounded rect; alpha>200 bbox (20,20,420,76) +-1; outside the 2 px AA ring alpha <= 170' $a.mask.t0 ([bool] $a.mask.t0.pass)
        Add-Check 'B-LOOK.mask.t10' 'same at t0+10 s' $a.mask.t10 ([bool] $a.mask.t10.pass)
        Add-Check 'B-LOOK.reveal.t0' 'saturation step at 20 + 400 p +-6 px' $a.reveal.t0 ([bool] $a.reveal.t0.pass)
        Add-Check 'B-LOOK.reveal.t10' 'saturation step at 20 + 400 p +-6 px' $a.reveal.t10 ([bool] $a.reveal.t10.pass)
        Add-Check 'B-LOOK.reveal.seek' 'after the seek, saturation step at 20 + 400 p +-6 px' (Get-Prop $a 'seekReveal') ([bool] (Get-Prop (Get-Prop $a 'seekReveal') 'pass'))
        Add-Check 'B-LOOK.artFixed' 'art profile shift <= 3 px between t0 and t0+10 s' $a.artFixed ([bool] $a.artFixed.pass)
        $show = Get-Prop $a 'show'; $hide = Get-Prop $a 'hide'; $text = Get-Prop $a 'text'
        $add = { param($n, $exp, $val, $ok) if ($blockedRate -and -not $ok) { Add-Blocked $n $exp "capture below 8 fps; observed $($val | ConvertTo-Json -Compress -Depth 4)" } else { Add-Check $n $exp $val $ok } }
        & $add 'B-LOOK.show.intermediateFrames' '>= 2 frames with normalized opacity 0.1-0.9' (Get-Prop $show 'intermediate') ([bool] (Get-Prop $show 'passIntermediate'))
        & $add 'B-LOOK.show.rise12px' 'top edge from 32+-2 to 20+-2, non-increasing' ([ordered]@{ first = Get-Prop $show 'firstVisibleTop'; settled = Get-Prop $show 'settledTop'; monotone = Get-Prop $show 'monotone' }) ([bool] (Get-Prop $show 'passRise'))
        & $add 'B-LOOK.show.settledBy2500ms' 'settled <= 2.5 s after play' (Get-Prop $show 'settledAt') ([bool] (Get-Prop $show 'passSettled'))
        & $add 'B-LOOK.hide.intermediateFrames' '>= 2 intermediate frames after pause' (Get-Prop $hide 'intermediate') ([bool] (Get-Prop $hide 'passIntermediate'))
        & $add 'B-LOOK.hide.goneBy2500ms' 'alpha <= 0.1 from 2.5 s after pause' (Get-Prop $hide 'lateMaxAlpha') ([bool] (Get-Prop $hide 'passGone'))
        Add-Check 'B-LOOK.text.differsAB' 'text region differs between A and B frames' $text ([bool] (Get-Prop $text 'pass'))
        # Frames for the owner (G2) and for B-DOCS 04.
        $all = @($t0.path, $t10.path) + @(foreach ($e in $lookEvents) { $windows[$e.name].Frames | ForEach-Object { $_.path } })
        $g = Invoke-Pillow 'gif' ([ordered]@{ out = (Join-Path $lookDirectory 'look.gif'); frames = $all; durationMs = 100; widths = @(440); maxBytes = 50MB; background = @(0, 177, 64, 255) })
        $obs.gif = [ordered]@{ path = Get-RelativePath $g.out; bytes = $g.bytes }
        Add-Check 'B-LOOK.framesSaved' 'PNG frames and look.gif written for owner review (G2)' ([ordered]@{ frames = $all.Count; gif = $obs.gif }) ($all.Count -gt 0 -and (Test-Path -LiteralPath $g.out))
        $script:lookFrames = [ordered]@{ play = @($windows['play'].Frames | ForEach-Object { $_.path }); trackB = @($windows['trackB'].Frames | ForEach-Object { $_.path })
            pause = @($windows['pause'].Frames | ForEach-Object { $_.path }) }
    } finally {
        Stop-SseReader $reader
        $scenarioResults['B-LOOK'] = $obs
    }
}

# ---------------------------------------------------------------------------------------------------------------
# B-VIS

# Settle >= 7 s after the step, then streams and Overlay-mode reads over a 3 s window (showing steps and D9).
function Measure-Vis($App, [string] $Name) {
    Wait-Seconds 7
    $s0 = Get-State $App.Root "vis-$Name-a"
    Wait-Seconds 3
    $s1 = Get-State $App.Root "vis-$Name-b"
    [ordered]@{ streams = Get-Overlay $s1 'streams'; overlayReads = Get-OverlayReads $s0 $s1; demand = Get-Overlay $s1 'demand' }
}
# Not-showing steps: after CEF closes the page cleanly (FIN) the first SSE keep-alive write still succeeds and only the
# second (5 s later) fails, so the server notices within 2 heartbeats; one read may be in flight, so reads are counted
# from 2 s after the app first reports streams == 0, over >= 5 s; streams must reach 0 within $VisHiddenZeroBoundS
# (2 x 5 s heartbeat + 1 s) of the step and the step still settles >= 7 s overall.
$VisHiddenZeroBoundS = 11
function Measure-VisHidden($App, [string] $Name, [double] $StepQpc) {
    $zeroQpc = $null; $poll = 0
    $limit = $StepQpc + 15 * $freq
    while ((Get-Qpc) -lt $limit) {
        $s = Get-State $App.Root "vis-$Name-z$((++$poll))"
        if ($null -ne (Get-Overlay $s 'streams') -and [int] (Get-Overlay $s 'streams') -eq 0) { $zeroQpc = Get-Qpc; break }
        Wait-Seconds 0.5
    }
    if ($null -eq $zeroQpc) {
        return [ordered]@{ streams = Get-Overlay $s 'streams'; streamsZeroAfterS = $null; overlayReads = $null; windowS = $null; demand = Get-Overlay $s 'demand' }
    }
    Wait-UntilQpc ($zeroQpc + 2 * $freq)
    $s0 = Get-State $App.Root "vis-$Name-a"
    $w0 = Get-Qpc
    Wait-UntilQpc ([Math]::Max($w0 + 5 * $freq, $StepQpc + 7 * $freq))
    $s1 = Get-State $App.Root "vis-$Name-b"
    [ordered]@{ streams = Get-Overlay $s1 'streams'; streamsZeroAfterS = Round3 (($zeroQpc - $StepQpc) / $freq)
        overlayReads = Get-OverlayReads $s0 $s1; windowStartAfterZeroS = Round3 (($w0 - $zeroQpc) / $freq)
        windowS = Round3 (((Get-Qpc) - $w0) / $freq); demand = Get-Overlay $s1 'demand' }
}
function Test-VisStep($App, [string] $Name, [bool] $Showing, [string] $What, [scriptblock] $Action) {
    Assert-TimeBox
    $stepQpc = Get-Qpc
    & $Action
    if ($Showing) {
        $m = Measure-Vis $App $Name
        $ok = $m.streams -ge 1 -and $m.overlayReads -ge 1
        $expected = "$What`: showing -> streams >= 1 and overlay reads >= 1"
    } else {
        $m = Measure-VisHidden $App $Name $stepQpc
        $ok = $null -ne $m.streamsZeroAfterS -and $m.streamsZeroAfterS -le $VisHiddenZeroBoundS -and $m.streams -eq 0 -and $m.overlayReads -eq 0
        $expected = "$What`: not showing in any view -> streams 0 within $VisHiddenZeroBoundS s of the step (2 x 5 s SSE heartbeat + 1 s), and 0 overlay reads in a >= 5 s window starting 2 s after streams reached 0"
    }
    Add-Check "B-VIS.$Name" $expected $m $ok
    $m
}
function Find-ProjectorWindow($Session) {
    foreach ($h in [ObsBE2E]::Windows([uint32] $Session.Obs.ProcessId)) { if ([ObsBE2E]::Title($h) -like '*Projector*') { return $h } }
    $null
}

function Test-BVis($App) {
    $obs = [ordered]@{ steps = [ordered]@{} }
    $scenarioResults['B-VIS'] = $obs
    $session = Start-ObsSession 'vis' 'B-VIS' $App
    try {
        $item = (Obs $session 'GetSceneItemId' @{ sceneName = $sceneName; sourceName = $sourceName }).sceneItemId
        [void] (Obs $session 'CreateScene' @{ sceneName = 'Other' })
        [void] (Obs $session 'CreateScene' @{ sceneName = 'Reuse' })
        [void] (Obs $session 'CreateScene' @{ sceneName = 'Nested' })
        [void] (Obs $session 'SetCurrentProgramScene' @{ sceneName = $sceneName })
        $steps = $obs.steps
        $steps.baseline = Test-VisStep $App 'baseline' $true 'program = Overlay, eye on' { }
        Test-ObsPaths $session $true $App
        $steps.eyeOff = Test-VisStep $App 'eyeOff' $false 'eye off' { [void] (Obs $session 'SetSceneItemEnabled' @{ sceneName = $sceneName; sceneItemId = $item; sceneItemEnabled = $false }) }
        $steps.eyeOn = Test-VisStep $App 'eyeOn' $true 'eye on' { [void] (Obs $session 'SetSceneItemEnabled' @{ sceneName = $sceneName; sceneItemId = $item; sceneItemEnabled = $true }) }
        $steps.sceneAway = Test-VisStep $App 'sceneAway' $false 'program switched to Other' { [void] (Obs $session 'SetCurrentProgramScene' @{ sceneName = 'Other' }) }
        $steps.sceneBack = Test-VisStep $App 'sceneBack' $true 'program back to Overlay' { [void] (Obs $session 'SetCurrentProgramScene' @{ sceneName = $sceneName }) }
        [void] (Obs $session 'SetCurrentSceneTransition' @{ transitionName = 'Cut' })
        $steps.studioPreviewOnly = Test-VisStep $App 'studioPreviewOnly' $true 'Studio Mode, preview Overlay, program Other' {
            [void] (Obs $session 'SetStudioModeEnabled' @{ studioModeEnabled = $true }); Start-Sleep -Milliseconds 500
            [void] (Obs $session 'SetCurrentProgramScene' @{ sceneName = 'Other' })
            [void] (Obs $session 'SetCurrentPreviewScene' @{ sceneName = $sceneName }) }
        $steps.studioProgramOnly = Test-VisStep $App 'studioProgramOnly' $true 'Studio Mode, preview Other, program Overlay' {
            [void] (Obs $session 'SetCurrentProgramScene' @{ sceneName = $sceneName })
            [void] (Obs $session 'SetCurrentPreviewScene' @{ sceneName = 'Other' }) }
        $steps.studioBoth = Test-VisStep $App 'studioBoth' $true 'Studio Mode, preview and program Overlay' {
            [void] (Obs $session 'SetCurrentPreviewScene' @{ sceneName = $sceneName }) }
        $steps.studioNeither = Test-VisStep $App 'studioNeither' $false 'Studio Mode, preview and program Other' {
            [void] (Obs $session 'SetCurrentProgramScene' @{ sceneName = 'Other' })
            [void] (Obs $session 'SetCurrentPreviewScene' @{ sceneName = 'Other' }) }
        $steps.studioOff = Test-VisStep $App 'studioOffOther' $false 'Studio Mode off, program Other' { [void] (Obs $session 'SetStudioModeEnabled' @{ studioModeEnabled = $false }) }
        $steps.projectorOpen = Test-VisStep $App 'projectorOpen' $true 'windowed projector on scene Overlay (program Other)' {
            [void] (Obs $session 'OpenSourceProjector' @{ sourceName = $sceneName; monitorIndex = -1 }) }
        $projector = Find-ProjectorWindow $session
        $obs.projectorTitle = if ($projector) { [ObsBE2E]::Title($projector) } else { $null }
        $steps.projectorClosed = Test-VisStep $App 'projectorClosed' $false 'projector closed (WM_CLOSE)' {
            $h = Find-ProjectorWindow $session
            if (-not $h) { throw 'Owned projector window not found.' }
            [void] [ObsBE2E]::PostMessage($h, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)
            if (-not (Wait-For { -not (Find-ProjectorWindow $session) } 10 250)) { throw 'Projector window did not close.' } }
        [void] (Obs $session 'CreateSceneItem' @{ sceneName = 'Reuse'; sourceName = $sourceName; sceneItemEnabled = $true })
        $steps.twoScenesOneShowing = Test-VisStep $App 'twoScenesOneShowing' $true 'source in Overlay and Reuse; program Reuse' {
            [void] (Obs $session 'SetCurrentProgramScene' @{ sceneName = 'Reuse' }) }
        $steps.twoScenesNone = Test-VisStep $App 'twoScenesNone' $false 'source in Overlay and Reuse; program Other' {
            [void] (Obs $session 'SetCurrentProgramScene' @{ sceneName = 'Other' }) }
        [void] (Obs $session 'CreateSceneItem' @{ sceneName = 'Nested'; sourceName = $sceneName; sceneItemEnabled = $true })
        $steps.nestedShowing = Test-VisStep $App 'nestedShowing' $true 'program Nested (scene Overlay nested)' {
            [void] (Obs $session 'SetCurrentProgramScene' @{ sceneName = 'Nested' }) }
        $steps.nestedAway = Test-VisStep $App 'nestedAway' $false 'program Other after Nested' {
            [void] (Obs $session 'SetCurrentProgramScene' @{ sceneName = 'Other' }) }
        [void] (Obs $session 'SetCurrentSceneTransition' @{ transitionName = 'Fade' })
        [void] (Obs $session 'SetCurrentSceneTransitionDuration' @{ transitionDuration = 1000 })
        $steps.transitionIn = Test-VisStep $App 'transitionIn' $true '1 s Fade Other -> Overlay' {
            [void] (Obs $session 'SetCurrentProgramScene' @{ sceneName = $sceneName }) }
        $steps.transitionOut = Test-VisStep $App 'transitionOut' $false '1 s Fade Overlay -> Other' {
            [void] (Obs $session 'SetCurrentProgramScene' @{ sceneName = 'Other' }) }
    } finally { Stop-ObsSession $session }

    # OBS started with the item hidden, then shown: create the scene with the item disabled, close OBS gracefully so
    # it saves the collection, relaunch the same run folder, and measure only if the item persisted disabled.
    $session = $null
    try {
        $session = Start-ObsSession 'vis-hidden' 'B-VIS' $App -ItemHidden
        $persist = [ordered]@{ gracefulExit = $null; itemFound = $false; itemEnabled = $null; programScene = $null; error = $null }
        $obs.startHiddenPersistence = $persist
        $item = $null
        try {
            $persist.gracefulExit = Restart-ObsSession $session
            $item = [int] (Obs $session 'GetSceneItemId' @{ sceneName = $sceneName; sourceName = $sourceName }).sceneItemId
            $persist.itemFound = $true
            $persist.itemEnabled = [bool] (Obs $session 'GetSceneItemEnabled' @{ sceneName = $sceneName; sceneItemId = $item }).sceneItemEnabled
            $persist.programScene = (Obs $session 'GetCurrentProgramScene' @{}).currentProgramSceneName
        } catch { $persist.error = $_.Exception.Message }
        $persisted = $persist.itemFound -and $persist.itemEnabled -eq $false -and $persist.programScene -eq $sceneName
        if ($persisted) {
            $obs.steps.startHidden = Test-VisStep $App 'startHidden' $false 'OBS started with the item hidden (persisted across a graceful relaunch)' { }
            Test-ObsPaths $session $false
            $obs.steps.startHiddenThenShown = Test-VisStep $App 'startHiddenThenShown' $true 'item shown after a hidden start' {
                [void] (Obs $session 'SetSceneItemEnabled' @{ sceneName = $sceneName; sceneItemId = $item; sceneItemEnabled = $true }) }
        } else {
            $reason = "disabled item did not persist across a graceful relaunch: $($persist | ConvertTo-Json -Compress)"
            Add-Blocked 'B-VIS.startHidden' 'OBS started with the item hidden: streams 0 and overlay reads 0' $reason
            Add-Blocked 'B-VIS.startHiddenThenShown' 'item shown after a hidden start: streams >= 1 and overlay reads >= 1' $reason
        }
    } finally { Stop-ObsSession $session }

    # Shutdown off: recorded, not gated (D9).
    $off = [ordered]@{}
    $obs.shutdownOff = $off
    $session = $null
    try {
        $session = Start-ObsSession 'vis-shutdown-off' 'B-VIS' $App -ShutdownOff
        $item = (Obs $session 'GetSceneItemId' @{ sceneName = $sceneName; sourceName = $sourceName }).sceneItemId
        $off.eyeOn = Measure-Vis $App 'off-eyeon'
        [void] (Obs $session 'SetSceneItemEnabled' @{ sceneName = $sceneName; sceneItemId = $item; sceneItemEnabled = $false })
        $off.eyeOff = Measure-Vis $App 'off-eyeoff'
        [void] (Obs $session 'SetSceneItemEnabled' @{ sceneName = $sceneName; sceneItemId = $item; sceneItemEnabled = $true })
        [void] (Obs $session 'SetCurrentProgramScene' @{ sceneName = $sceneName })
    } catch { $off.error = $_.Exception.Message } finally { Stop-ObsSession $session }
}

# ---------------------------------------------------------------------------------------------------------------
# B-DOCS (UI Automation of the owned OBS window; captures are window-scoped)

function Find-ObsElement($Session, [scriptblock] $Match, [int] $Seconds = 10) {
    $pidCond = New-Object System.Windows.Automation.PropertyCondition ($AE::ProcessIdProperty), ([int] $Session.Obs.ProcessId)
    Wait-For {
        foreach ($w in $AE::RootElement.FindAll($Scope::Children, $pidCond)) {
            foreach ($d in @($w) + @($w.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition))) {
                try { if (& $Match $d) { return $d } } catch { }
            }
        }
    } $Seconds 300
}
function Test-ImageOnDisk([string] $Name, [string] $Path, [bool] $Gif) {
    $exists = Test-Path -LiteralPath $Path -PathType Leaf
    $bytes = if ($exists) { (Get-Item -LiteralPath $Path).Length } else { $null }
    $ok = $exists -and $bytes -gt 0 -and (-not $Gif -or $bytes -le 3MB)
    Add-Check "B-DOCS.$Name" $(if ($Gif) { "$Name exists, <= 3 MB" } else { "$Name exists" }) ([ordered]@{ path = Get-RelativePath $Path; bytes = $bytes }) $ok
}

function Test-BDocs($App, $Session) {
    $obs = [ordered]@{ steps = [ordered]@{} }
    $scenarioResults['B-DOCS'] = $obs
    $main = Get-ObsMainWindow $Session
    # Fixed window size for consistent guide images (only the owned OBS window is moved).
    [void] [ObsBE2E]::SetWindowPos($main, [IntPtr]::Zero, 80, 80, 1280, 800, 0x0014)
    Start-Sleep -Seconds 2
    $gifFrames = [Collections.Generic.List[string]]::new()
    $durations = [Collections.Generic.List[int]]::new()
    $frameDir = Join-Path $runDirectory 'docs-frames'
    $snap = { param([string] $Tag, [int] $Ms = 900)
        $p = Save-ObsWindowShot $Session (Join-Path $frameDir ('{0:D2}-{1}.png' -f $gifFrames.Count, $Tag))
        $gifFrames.Add($p); $durations.Add($Ms); $p }

    & $snap 'start' 1000 | Out-Null
    # (1) Sources dock '+' (Add source): located through UIA, clicked with posted WM_LBUTTONDOWN/UP at the button's
    # client coordinates (the real mouse cursor is never moved). The popup is an owned top-level window of the OBS
    # PID (Qt popup / QMenu class) that did not exist before the click.
    $addButton = Find-ObsElement $Session { param($e) $e.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -and $e.Current.Name -eq 'Add Source' } 5
    if (-not $addButton) {
        $dock = Find-ObsElement $Session { param($e) $e.Current.Name -eq 'Sources' -and $e.Current.ControlType -ne [System.Windows.Automation.ControlType]::Text } 5
        if ($dock) {
            $addButton = $dock.FindAll($Scope::Descendants, [System.Windows.Automation.PropertyCondition]::new($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)) |
                Where-Object { $_.Current.Name -like 'Add*' -or $_.Current.HelpText -like 'Add*' } | Select-Object -First 1
        }
    }
    if (-not $addButton) { Add-Blocked 'B-DOCS.01-sources-add' 'Sources + button found through UI Automation' 'no Add Source button exposed by OBS UIA' }
    else {
        $b = $addButton.Current.BoundingRectangle
        $target = [IntPtr] $addButton.Current.NativeWindowHandle
        if ($target -eq [IntPtr]::Zero) { $target = $main }
        $pt = New-Object ObsBE2E+POINT; $pt.X = [int] ($b.Left + $b.Width / 2); $pt.Y = [int] ($b.Top + $b.Height / 2)
        [void] [ObsBE2E]::ScreenToClient($target, [ref] $pt)
        $lp = [IntPtr] ((($pt.Y -band 0xFFFF) -shl 16) -bor ($pt.X -band 0xFFFF))
        $before = [Collections.Generic.HashSet[long]]::new()
        foreach ($h in [ObsBE2E]::Windows([uint32] $Session.Obs.ProcessId)) { [void] $before.Add($h.ToInt64()) }
        [void] [ObsBE2E]::PostMessage($target, 0x0200, [IntPtr]::Zero, $lp)   # WM_MOUSEMOVE
        Start-Sleep -Milliseconds 100
        [void] [ObsBE2E]::PostMessage($target, 0x0201, [IntPtr] 1, $lp)       # WM_LBUTTONDOWN, MK_LBUTTON
        Start-Sleep -Milliseconds 80
        [void] [ObsBE2E]::PostMessage($target, 0x0202, [IntPtr]::Zero, $lp)   # WM_LBUTTONUP
        $popup = Wait-For {
            foreach ($h in [ObsBE2E]::Windows([uint32] $Session.Obs.ProcessId)) {
                if ($before.Contains($h.ToInt64())) { continue }
                $cls = [ObsBE2E]::ClassName($h)
                if ($cls -like '*Popup*' -or $cls -like '*QMenu*' -or $cls -like 'Qt*QWindow*') { return $h }
            }
        } 3 150
        $newWindows = @([ObsBE2E]::Windows([uint32] $Session.Obs.ProcessId) | Where-Object { -not $before.Contains($_.ToInt64()) } | ForEach-Object { [ObsBE2E]::ClassName($_) })
        $obs.steps.addClick = [ordered]@{ button = $addButton.Current.Name; targetClass = [ObsBE2E]::ClassName($target); client = @($pt.X, $pt.Y)
            popupClass = if ($popup) { [ObsBE2E]::ClassName($popup) } else { $null }; newOwnedWindows = $newWindows }
        if (-not $popup) {
            Add-Blocked 'B-DOCS.01-sources-add' 'Sources + popup opened by a posted click on the Add Source button' "no new owned popup window within 3 s after WM_LBUTTONDOWN/UP to $($obs.steps.addClick.targetClass) at client $($pt.X),$($pt.Y) (new owned windows: $($newWindows -join ', '))"
        } else {
            Start-Sleep -Milliseconds 400
            $shot1 = & $snap 'menu' 1000
            $menuShot = Get-WindowBitmap $popup
            if ($menuShot) { try { $menuShot.Bitmap.Save((Join-Path $frameDir 'menu-only.png'), [System.Drawing.Imaging.ImageFormat]::Png) } finally { $menuShot.Bitmap.Dispose() } }
            Copy-Item -LiteralPath $shot1 -Destination (Join-Path $docsOut '01-sources-add.png') -Force
            Add-Check 'B-DOCS.01.popupOpened' 'Sources + popup opened (owned top-level popup window) and captured window-scoped' $obs.steps.addClick $true
            [void] [ObsBE2E]::PostMessage($popup, 0x0100, [IntPtr] 0x1B, [IntPtr]::Zero)   # WM_KEYDOWN Escape
            [void] [ObsBE2E]::PostMessage($popup, 0x0101, [IntPtr] 0x1B, [IntPtr]::Zero)
            if (-not (Wait-For { -not [ObsBE2E]::IsWindowVisible($popup) } 2 150)) { [void] [ObsBE2E]::PostMessage($popup, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) }
            Start-Sleep -Milliseconds 300
        }
    }

    # (2) Browser source properties: opened with obs-websocket OpenInputPropertiesDialog, captured with PrintWindow on
    # the owned dialog HWND only, then closed with WM_CLOSE (no settings changed).
    $beforeProps = [Collections.Generic.HashSet[long]]::new()
    foreach ($h in [ObsBE2E]::Windows([uint32] $Session.Obs.ProcessId)) { [void] $beforeProps.Add($h.ToInt64()) }
    $openError = $null
    try { [void] (Obs $Session 'OpenInputPropertiesDialog' @{ inputName = $sourceName }) } catch { $openError = $_.Exception.Message }
    $dialog = if ($openError) { $null } else {
        Wait-For { foreach ($h in [ObsBE2E]::Windows([uint32] $Session.Obs.ProcessId)) { if (-not $beforeProps.Contains($h.ToInt64()) -and [ObsBE2E]::Title($h) -like 'Properties*') { return $h } } } 10 200 }
    if (-not $dialog) {
        Add-Blocked 'B-DOCS.02-browser-properties' 'properties dialog opened by OpenInputPropertiesDialog' $(if ($openError) { "request failed: $openError" } else { 'no new owned Properties window within 10 s' })
    } else {
        Start-Sleep -Seconds 2   # let the dialog's preview and property widgets render
        $shot = Get-WindowBitmap $dialog
        if ($shot) { try { $shot.Bitmap.Save((Join-Path $docsOut '02-browser-properties.png'), [System.Drawing.Imaging.ImageFormat]::Png) } finally { $shot.Bitmap.Dispose() } }
        & $snap 'props' 2000 | Out-Null
        $obs.steps.properties = [ordered]@{ title = [ObsBE2E]::Title($dialog); captured = [bool] $shot }
        Add-Check 'B-DOCS.02.dialogCaptured' 'owned Properties dialog captured window-scoped (PrintWindow on its HWND)' $obs.steps.properties ([bool] $shot)
        [void] [ObsBE2E]::PostMessage($dialog, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero)   # WM_CLOSE
        $obs.steps.properties.closed = [bool] (Wait-For { -not [ObsBE2E]::IsWindowVisible($dialog) } 10 250)
    }
    # (3) GIF of the captured sequence (main window, + menu if captured, properties dialog over the main window) ~1 fps.
    if ($gifFrames.Count -gt 1) {
        $obs.gif03 = Invoke-Pillow 'gif' ([ordered]@{ out = (Join-Path $docsOut '03-add-source.gif'); frames = @($gifFrames); durations = @($durations); widths = @(1280, 1024, 800, 640); maxBytes = 3MB })
    }

    # (4) Overlay GIF from B-LOOK frames: playing -> track change -> pause (hide).
    if ($script:lookFrames) {
        $frames = @($script:lookFrames.play) + @($script:lookFrames.trackB) + @($script:lookFrames.pause)
        $obs.gif04 = Invoke-Pillow 'gif' ([ordered]@{ out = (Join-Path $docsOut '04-overlay.gif'); frames = $frames; durationMs = 100; widths = @(440); background = @(24, 24, 28, 255) })
    } else {
        Add-Blocked 'B-DOCS.04-overlay.gif' 'B-LOOK frames from the same run' 'B-LOOK did not run or produced no frames in this run'
    }

    # (5) Paused with hide-when-paused off: the dimmed pill (page 45-60 s is paused A).
    $reader = Start-SseReader 'B-DOCS'
    try {
        [void] (Send-HookCommand $App.Root 'command-obs-hide-paused-off')
        Start-Sleep -Seconds 2
        $navQpc = Send-HookCommand $App.Root 'command-navigate'
        $initial = Wait-SseData $reader { param($d) (Test-Data $d 'playing' 'fixtureSngA') -and [double] (Get-Prop $d 'position') -lt 15 } 60 $navQpc
        if (-not $initial) { Add-Blocked 'B-DOCS.05-paused-dimmed' 'fixture timeline restarted' 'no playing A event' }
        else {
            $start = Get-PageStartQpc $initial
            Wait-UntilQpc ($start + 48 * $freq)
            [void] (Save-ObsWindowShot $Session (Join-Path $docsOut '05-paused-dimmed.png'))
            $srcPath = Join-Path $runDirectory 'docs-frames/05-source.png'
            [IO.File]::WriteAllBytes($srcPath, (Get-SourceShotBytes $Session))
            $still = Invoke-Pillow 'still' ([ordered]@{ path = $srcPath })
            $obs.pausedOpacity = $still.opacity
            Add-Check 'B-DOCS.05.dimmed' 'paused pill shown at opacity 0.7 +-0.05 with the toggle off' (Round3 $still.opacity) ([Math]::Abs([double] $still.opacity - 0.7) -le 0.05)
        }
    } finally {
        Stop-SseReader $reader
        try { [void] (Send-HookCommand $App.Root 'command-obs-hide-paused-on') } catch { }
    }

    # Every image exists at the path the guide references; GIFs <= 3 MB.
    $guide = Get-Content -Raw -LiteralPath (Join-Path $repo 'docs/obs-overlay.md')
    foreach ($n in @('01-sources-add.png', '02-browser-properties.png', '03-add-source.gif', '04-overlay.gif', '05-paused-dimmed.png')) {
        $referenced = $guide.Contains("images/obs-overlay/$n")
        Add-Check "B-DOCS.guideReferences.$n" 'docs/obs-overlay.md references the image' $referenced $referenced
        Test-ImageOnDisk $n (Join-Path $docsOut $n) ($n -like '*.gif')
    }
    $obs.ownerReview = 'pending: only fixture titles/art, no other window, notification or personal path (owner reviews the images in the PR)'
    if ($UpdateDocsImages) {
        [IO.Directory]::CreateDirectory($docsImages) | Out-Null
        $copied = @()
        foreach ($f in Get-ChildItem -LiteralPath $docsOut -File) {
            if ($f.Extension -eq '.gif' -and $f.Length -gt 3MB) { continue }
            Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $docsImages $f.Name) -Force; $copied += $f.Name
        }
        $obs.copiedToDocs = $copied
    }
}

# ---------------------------------------------------------------------------------------------------------------
# Runner

$appVersion = $null
$scenarioErrors = [ordered]@{}
$ownerBefore = Get-OwnerObsProfileSnapshot
$lookApp = $null; $visApp = $null; $lookSession = $null
function Add-RunnerFailure([string] $Name, $ErrorRecord) {
    $message = $ErrorRecord.Exception.Message
    if ($message -like 'TIMEBOX:*' -or $message -like 'PILLOW:*') { Add-Blocked "$Name.runner.completed" 'scenario ran to completion' $message }
    else { Add-Check "$Name.runner.completed" 'scenario ran to completion' $message $false }
    $scenarioErrors[$Name] = [ordered]@{ message = $message; scriptStackTrace = $ErrorRecord.ScriptStackTrace }
}
try {
    if (-not $SkipPublish) {
        & pwsh -NoProfile -File (Join-Path $repo 'scripts/dotnet.ps1') publish (Join-Path $repo 'src/Nativune/Nativune.csproj') `
            --runtime win-x64 --self-contained false -p:DiscordPresenceTestHooks=true -o $appDirectory
        if ($LASTEXITCODE -ne 0) { throw "Hook build publish failed with exit code $LASTEXITCODE." }
    }
    if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) { throw "Hook build not found at $appExe; run without -SkipPublish." }
    $appVersion = (Get-Item -LiteralPath $appExe).VersionInfo.ProductVersion
    if (-not (Resolve-Python) -and ($selected -contains 'B-LOOK' -or $selected -contains 'B-DOCS')) {
        foreach ($n in @('B-LOOK', 'B-DOCS') | Where-Object { $_ -in $selected }) { Add-Blocked "$n.pillow" 'installed Python with Pillow' 'python/Pillow not found' }
    }

    # Session "look": B-LOOK then B-DOCS on one app + one OBS launch.
    $lookSet = @('B-LOOK', 'B-DOCS') | Where-Object { $_ -in $selected }
    if ($lookSet) {
        $first = $lookSet[0]
        try {
            $lookApp = Start-OverlayApp 'look' $null $first
            $lookSession = Start-ObsSession 'look' $first $lookApp
            foreach ($n in $lookSet) {
                $t0 = [DateTime]::UtcNow
                try {
                    Assert-TimeBox
                    if ($n -eq 'B-LOOK') { Test-BLook $lookApp $lookSession } else { Test-BDocs $lookApp $lookSession }
                } catch { Add-RunnerFailure $n $_ }
                if ($scenarioResults.Contains($n)) { $scenarioResults[$n]['wallSeconds'] = [Math]::Round(([DateTime]::UtcNow - $t0).TotalSeconds, 1) }
            }
        } catch { Add-RunnerFailure $first $_ }
        finally {
            Stop-ObsSession $lookSession; $lookSession = $null
            if ($lookApp) { Stop-App $lookApp.App $lookApp.Root; $lookApp = $null }
        }
    }

    # Session "vis": B-VIS on the steady Playing profile.
    if ('B-VIS' -in $selected) {
        $t0 = [DateTime]::UtcNow
        try {
            Assert-TimeBox
            $visApp = Start-OverlayApp 'vis' 'Playing' 'B-VIS'
            Test-BVis $visApp
        } catch { Add-RunnerFailure 'B-VIS' $_ }
        finally { if ($visApp) { Stop-App $visApp.App $visApp.Root; $visApp = $null } }
        if ($scenarioResults.Contains('B-VIS')) { $scenarioResults['B-VIS']['wallSeconds'] = [Math]::Round(([DateTime]::UtcNow - $t0).TotalSeconds, 1) }
    }
    if ($scenarioErrors.Count -gt 0) { $scenarioResults['errors'] = $scenarioErrors }
} catch {
    Add-Check 'runner.completed' 'harness setup succeeded' $_.Exception.Message $false
    $scenarioResults['error'] = [ordered]@{ message = $_.Exception.Message; scriptStackTrace = $_.ScriptStackTrace }
} finally {
    foreach ($r in @($readers)) { Stop-SseReader $r }
    foreach ($o in @($obsInstances)) { if (-not $o.Stopped) { try { Stop-ObsPortable $o } catch { Add-Check "B-ISO.cleanup.$(Split-Path -Leaf $o.RunDir)" 'owner OBS profile unchanged at cleanup' $_.Exception.Message $false } } }
    if ($lookApp) { Stop-App $lookApp.App $lookApp.Root }
    if ($visApp) { Stop-App $visApp.App $visApp.Root }
    foreach ($process in $started) {
        try { if (-not $process.HasExited) { foreach ($id in (Get-ProcessTree $process.Id $rootBase)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } } } catch { }
    }
    foreach ($key in @($testEnv.Keys) + $benchEnvKeys) { Set-ProcessEnv $key $null }
    if (Test-Path -LiteralPath $rootBase) {
        foreach ($d in @(Get-ChildItem -LiteralPath $rootBase -Directory -ErrorAction SilentlyContinue)) { Copy-BenchJson $d.FullName }
        Start-Sleep -Seconds 1; Remove-Item -LiteralPath $rootBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# B-ISO after every OBS instance stopped: the owner's OBS config is byte-identical (content, size, mtime).
if ('B-ISO' -in $selected) {
    $ownerAfter = Get-OwnerObsProfileSnapshot
    $diff = Compare-OwnerObsProfileSnapshot $ownerBefore $ownerAfter
    $scenarioResults['B-ISO'] = [ordered]@{ entriesBefore = $ownerBefore.Count; entriesAfter = $ownerAfter.Count; obsLaunches = $obsLaunches.Count
        changes = @($diff | ForEach-Object { [ordered]@{ path = $_.path -replace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%'; change = $_.change } }) }
    Add-Check 'B-ISO.ownerProfileIdentical' 'SHA-256, size and mtime of every file under %APPDATA%\obs-studio and the %LOCALAPPDATA%\obs-studio* listing identical before/after' ([ordered]@{
            entries = $ownerAfter.Count; changes = $diff.Count; obsLaunches = $obsLaunches.Count }) ($diff.Count -eq 0)
    if ($obsLaunches.Count -eq 0) { Add-Blocked 'B-ISO.obsLaunched' 'at least one disposable OBS launch in this run' 'no OBS launched (select B-LOOK/B-VIS/B-DOCS too)' }
}

foreach ($name in $selected) {
    if (-not ($checks | Where-Object { $_.name -like "$name.*" })) { Add-Check "$name.producedChecks" 'at least one check' 0 $false }
}
$failed = @($checks | Where-Object { $_.status -eq 'fail' })
$blocked = @($checks | Where-Object { $_.status -eq 'blocked' })
$passed = $checks.Count -gt 0 -and $failed.Count -eq 0 -and $blocked.Count -eq 0
$report = [ordered]@{
    command = $commandLine; runId = $runId; appVersion = $appVersion; obsVersion = $script:ObsPortableVersion
    pillow = if ($script:python) { $script:python.Pillow } else { $null }; harnessElevated = $isElevated; timeBoxMinutes = $TimeBoxMinutes
    launches = @($launches); obsLaunches = @($obsLaunches); scenarios = $scenarioResults
    summary = [ordered]@{ pass = @($checks | Where-Object { $_.status -eq 'pass' }).Count; fail = $failed.Count; blocked = $blocked.Count }
    checks = @($checks); passed = [bool] $passed
}
[IO.File]::WriteAllText((Join-Path $runDirectory 'report.json'), ($report | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $runDirectory 'events.json'), ($eventsByReader | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
$report.summary | ConvertTo-Json
Write-Host "Report: $(Join-Path $runDirectory 'report.json')"
if (-not $passed) { exit 1 }
