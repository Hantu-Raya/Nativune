<#
E2E-B for the opt-in OBS now-playing overlay against a real, disposable OBS Studio 32.2.2
(notes/research/obs-overlay-2026-09-28/plan.md §6.2; design notes in design.md). Helper: scripts/obs-portable.ps1.
P1 per-theme B-LOOK: notes/research/obs-overlay-themes-2026-09-29/plan.md §3.5, §8.2 (font/fidelity rows deferred to P3).

APPROVAL: running this script needs the owner's explicit approval for this run (plan §6.2 heading: no answer is not
approval). It puts a disposable OBS window on screen for up to -TimeBoxMinutes (default 30, the B-LOOK/B-VIS/B-DOCS
share of the G3 2 h box), and while OBS runs obs-websocket listens on ALL interfaces on a random port 49152-65535,
protected by a random 32-byte password that never reaches argv, logs or artifacts.

Regenerate:
  pwsh -NoProfile -File scripts/obs-overlay-obs-e2e.ps1 -Scenario All -OutputDirectory artifacts/obs-overlay-obs
  pwsh -NoProfile -File scripts/obs-overlay-obs-e2e.ps1 -Scenario B-LOOK,B-DOCS -SkipPublish -UpdateDocsImages
  pwsh -NoProfile -File scripts/obs-overlay-obs-e2e.ps1 -Scenario B-VIS,B-ISO -TimeBoxMinutes 15
  pwsh -NoProfile -File scripts/obs-overlay-obs-e2e.ps1 -Scenario GUIDE [-HoldMinutes 30] [-SkipPublish]

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
  GUIDE   Not part of All; runs only when named. Starts a disposable Nativune (Playing steady fixture, normal full view,
          ObsOverlay off, Discord presence off) and a disposable OBS with its default empty scene (no source created; its
          main window is moved to 80,80 1280x800), writes <run>/guide-env.json (obsPid, appPid, appWindowTitle, overlayUrl,
          stopFile, holdDeadlineUtc), then holds until <run>/guide-stop exists or -HoldMinutes (default 30) elapse, so a
          computer-use agent can capture a from-scratch setup guide. The setup images (docs/images/obs-overlay/setup/NN-*.png)
          come from a GUIDE hold driven by a computer-use walkthrough (steps recorded in <run>/guide/steps.md), copied to
          docs/images/obs-overlay/setup/ after owner approval. Cleanup: OBS, then the app; checks
          GUIDE.ownerObsProfileUnchanged and GUIDE.obsMinutes. The fixture track is 1800 s long.
  B-LOOK  GetSourceScreenshot of 'Nativune Overlay' at each theme's native source size (expected-sizes.json).
          Eight default looks from looks-cases.json are loaded through data/obs-looks.json. Sample-playing stills
          at settled t0 and t0+10 s: look/themes/<theme>-t0.png and -t10.png, with §3.5 mask/progress/text/cover
          oracles. Pill uses today's saturation reveal/art profile; other themes use the generated bar centre row,
          run = bar.width * p +-3 px and luminance step >= 0.25; matte-light glyphs are dark. Classic masks cover
          and panel separately (gap alpha <= 170 beyond their AA rings); simple masks cover/text/time/bar only.
          Real-fixture series for pill (existing check names and look.gif) and matte (B-LOOK.matte.<event>.*):
          command-navigate restarts page 0; windows -0.5..+3.5 s around seek (25 s), pause (45 s), play (60 s),
          track B (80 s), at 10 fps (<8 fps -> blocked). SSE receipt anchors events (predicted page time fallback).
          Show: >=2 intermediate frames, 12 px rise, settled <=2.5 s; hide: >=2 intermediate frames and alpha
          <=0.1 from 2.5 s; track B: glyph mask differs; seek: reveal for pill, luminance bar for matte.
          Frames: look/<event>/*.png (pill), look/matte/<event>/*.png, look/look.gif; stills retained for G2.
          Budget: typically <10 min OBS with B-DOCS, target <=30 min, owner-approved box 45 min. Pill input is
          restored in finally so B-DOCS remains unchanged. Font/CDP/fidelity rows are P3, not this pass.
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
  B-DOCS  Regenerates 04-overlay.gif (B-LOOK frames play -> track B -> pause; needs B-LOOK in the same run) and
          05-paused-dimmed.png (command-obs-hide-paused-off, page 47 s); each GIF <= 3 MB. Written to <run>/docs-images/;
          copied to docs/images/obs-overlay/ only with -UpdateDocsImages. Also checks B-DOCS.guideSetupImages: every
          images/obs-overlay/setup/*.png that docs/obs-overlay.md references exists and is non-empty (those images are
          not regenerated here). The owner reviews the images in the PR.

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
    [switch] $SkipPublish,
    # GUIDE only: how long the environment is held open (minutes) unless <run>/guide-stop appears first.
    [ValidateRange(0.1, 240)] [double] $HoldMinutes = 30
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$allScenarios = @('B-LOOK', 'B-VIS', 'B-ISO', 'B-DOCS')
$Scenario = @($Scenario | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($name in $Scenario) {
    if ($name -ne 'All' -and $name -ne 'GUIDE' -and $name -notin $allScenarios) { throw "Unknown scenario '$name'. Valid: All, GUIDE (only when named), $($allScenarios -join ', ')." }
}
$runGuide = 'GUIDE' -in $Scenario
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
if ('GUIDE' -in $Scenario) { $deadlineUtc = $deadlineUtc.AddMinutes($HoldMinutes) }   # the hold is not part of the readiness time box

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
# B-LOOK consumes the independent layout table, rather than copying default dimensions into this harness.
$expectedSizes = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures/obs-overlay/expected-sizes.json') |
    ConvertFrom-Json -AsHashtable -Depth 16
$themeSpecs = [ordered]@{}
foreach ($theme in @('pill', 'matte', 'matte-light', 'standard', 'classic', 'simple', 'album-art', 'card')) {
    $matches = @($expectedSizes.rows | Where-Object { $_.theme -eq $theme -and $_.default -and $_.scale -eq 100 })
    if ($matches.Count -ne 1) { throw "B-LOOK: expected-sizes has $($matches.Count) default rows for $theme" }
    $row = $matches[0]
    $themeSpecs[$theme] = [ordered]@{
        theme = $theme; box = $row.box; source = $row.source; column = $row.column; bar = $row.bar
        textBand = @([double] $row.textBand.start, [double] $row.textBand.end)
        progressKind = if ($theme -eq 'pill') { 'saturation-reveal' } else { 'luminance-bar' }
        darkGlyphs = $theme -eq 'matte-light'
        outsideAlphaCap = 170
        separateClassicRects = $theme -eq 'classic'
        cover = $row.cover; panel = $row.panel; sourceBar = $row.sourceBar
        progressTolerance = if ($theme -eq 'pill') { 6 } else { 3 }
        minimumLuminanceStep = if ($theme -eq 'pill') { $null } else { 0.25 }
        maskKind = if ($theme -eq 'classic') { 'rounded-cover-and-panel' } elseif ($theme -eq 'simple') { 'cover-text-and-bar' } else { 'rounded-box' }
        dimOpacity = 0.7; thumbFixed = $theme -ne 'pill'; artFixed = $theme -eq 'pill'
    }
}
# Inputs for the per-theme B-LOOK pass; no OBS action occurs while constructing these records.
$bLookInputs = @(
    foreach ($case in (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures/obs-overlay/looks-cases.json') | ConvertFrom-Json -Depth 16)) {
        if ($case.case -ne 'default') { continue }
        $spec = $themeSpecs[$case.theme]
        [ordered]@{ theme = $case.theme; id = $case.lookId; url = "$($overlayUrl)?look=$($case.lookId)&sample=playing"
            width = [int] $spec.source.w; height = [int] $spec.source.h
            look = [ordered]@{ id = $case.lookId; name = "OBS $($case.theme)"; options = $case.options }; spec = $spec }
    }
)
if ($bLookInputs.Count -ne 8 -or @($bLookInputs.theme | Sort-Object -Unique).Count -ne 8 -or
    @($bLookInputs.id | Sort-Object -Unique).Count -ne 8) { throw 'B-LOOK: exactly one distinct default look/id per theme is required.' }
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

Add-Type -AssemblyName System.Drawing
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
# (UI Automation is no longer used by this script.)

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
function Write-Settings([string] $Root, [bool] $HidePaused = $true, [hashtable] $Override = @{}) {
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
    foreach ($entry in $Override.GetEnumerator()) { $settings[$entry.Key] = $entry.Value }
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
function Start-OverlayApp([string] $Name, [string] $BenchProfile = $null, [string] $CheckPrefix, [hashtable] $SettingsOverride = @{}, [string] $LooksJson = $null) {
    $root = New-Root $Name
    Write-Settings $root $true $SettingsOverride
    if ($null -ne $LooksJson) {
        [IO.File]::WriteAllText((Join-Path $root 'data/obs-looks.json'), $LooksJson, [Text.UTF8Encoding]::new($false))
    }
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
# The stream's id is an opaque per-session key, never the video ID, so fixture tracks are recognised by their title.
$script:fixtureTitles = @{ fixtureSngA = 'Fixture Song A'; fixtureSngB = 'Fixture Song B'; fixtureSngC = 'Fixture Song C' }
function Test-Data($D, [string] $State, [string] $Id = $null) { (Get-Prop $D 'state') -eq $State -and (-not $Id -or (Get-Prop $D 'title') -eq $script:fixtureTitles[$Id]) }
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
# Window-scoped capture helpers were removed with the setup images (they come from a GUIDE hold now).
function Get-SourceShotBytes($Session, [int] $Width = 440, [int] $Height = 96) {
    Assert-TimeBox
    $r = Obs $Session 'GetSourceScreenshot' @{ sourceName = $sourceName; imageFormat = 'png'; imageWidth = $Width; imageHeight = $Height }
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

def reveal(img, metric=None):
    # metric: per-pixel value whose column mean steps down at the reveal (default: saturation).
    s = columns(img, metric or sat); n = len(s); best = None; bx = None; k = 8
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

def text_rect(g):
    return {'x': g['box']['x'] + g['column']['start'], 'y': g['textBand'][0],
            'w': g['column']['end'] - g['column']['start'], 'h': g['textBand'][1] - g['textBand'][0], 'r': 0}

def round_contains(x, y, rect, pad=0):
    return in_round(x, y, rect['x'] - pad, rect['y'] - pad,
                    rect['w'] + 2 * pad, rect['h'] + 2 * pad, max(0, rect['r'] + pad))

def theme_mask(img, g):
    expected_size = (int(g['source']['w']), int(g['source']['h']))
    if img.size != expected_size:
        return {'size': list(img.size), 'expectedSize': list(expected_size), 'pass': False}
    kind = g['maskKind']
    if kind == 'rounded-box':
        solid = allowed = [g['box']]
    elif kind == 'rounded-cover-and-panel':
        solid = allowed = [g['cover'], g['panel']]
    elif kind == 'cover-text-and-bar':
        solid = [g['cover']]
        b = g['sourceBar']; text = text_rect(g)
        allowed = solid + [text, {'x': b['start'], 'y': b['y'], 'w': b['width'], 'h': b['h'], 'r': b['h'] / 2}]
        # Default simple also shows two 44px time labels in the generated 14px bottom row, not a solid panel.
        for x in (text['x'], b['end'] + 6):
            allowed.append({'x': x, 'y': b['y'] + b['h'] / 2 - 7, 'w': 44, 'h': 14, 'r': 0})
    else:
        raise ValueError('unknown maskKind: ' + kind)
    a = img.getchannel('A'); px = a.load()
    inside_n = inside_low = outside_bad = gap_bad = 0; max_out = 0
    for y in range(img.height):
        for x in range(img.width):
            v = px[x, y]
            if any(round_contains(x, y, rect, -2) for rect in solid):
                inside_n += 1; inside_low += v < 0.9 * 255
            elif not any(round_contains(x, y, rect, 2) for rect in allowed):
                max_out = max(max_out, v); outside_bad += v > g['outsideAlphaCap']
                if kind == 'rounded-cover-and-panel' and g['cover']['x'] + g['cover']['w'] <= x < g['panel']['x']:
                    gap_bad += v > g['outsideAlphaCap']
    bbox = a.point(lambda v: 255 if v > 200 else 0).getbbox()
    expected_bbox = [min(r['x'] for r in solid), min(r['y'] for r in solid),
                     max(r['x'] + r['w'] for r in solid), max(r['y'] + r['h'] for r in solid)]
    # Simple has no opaque box: cover interior + outside union + independent text/bar oracles are its mask.
    bbox_ok = kind == 'cover-text-and-bar' or (bbox is not None and all(abs(p - q) <= 1 for p, q in zip(bbox, expected_bbox)))
    return {'maskKind': kind, 'insidePixels': inside_n, 'insideBelow09': inside_low,
            'alpha200BBox': bbox, 'expectedBBox': None if kind == 'cover-text-and-bar' else expected_bbox,
            'bboxOk': bbox_ok, 'outsideAboveCap': outside_bad, 'maxOutsideAlpha': max_out, 'gapAboveCap': gap_bad,
            'pass': inside_n > 0 and inside_low == 0 and bbox_ok and outside_bad == 0 and gap_bad == 0}

def theme_progress(img, g, p):
    if g['progressKind'] == 'saturation-reveal':
        # Owner, 4 October: the remaining part is darker as well as greyer, so the edge is a step in saturation plus
        # luminance (a white art highlight raises luminance but lowers saturation, and does not read as the edge).
        x, strength = reveal(img, lambda r, g, b: sat(r, g, b) + lum(r, g, b)); exp = g['box']['x'] + g['box']['w'] * p
        return {'x': x, 'expected': exp, 'strength': strength,
                'pass': x is not None and abs(x - exp) <= g['progressTolerance']}
    if g['progressKind'] != 'luminance-bar':
        raise ValueError('unknown progressKind: ' + g['progressKind'])
    b = g['sourceBar']; x0, x1 = int(b['start']), int(b['end']); y = int(b['y'] + b['h'] / 2)
    px = img.load()
    # Alpha-composited luminance also handles the transparent black track of simple.
    vals = [lum(*px[x, y][:3]) * px[x, y][3] / 255 for x in range(x0, x1)]
    best = None; edge = None; k = 3
    for i in range(k, len(vals) - k):
        d = sum(vals[i-k:i]) / k - sum(vals[i:i+k]) / k
        if best is None or abs(d) > abs(best): best, edge = d, i
    # Classic's 8px round head is centred on the fill end; its centre-row right edge is 4px beyond the run.
    head = b['h'] if g['theme'] == 'classic' else 0
    run = None if edge is None else edge - head
    expected = b['width'] * p
    step = abs(best) if best is not None else 0
    return {'row': y, 'run': run, 'expectedRun': expected, 'edgeX': None if edge is None else x0 + edge,
            'headRadius': head, 'step': step, 'signedStep': best,
            'pass': run is not None and abs(run - expected) <= g['progressTolerance'] and step >= g['minimumLuminanceStep']}

def theme_glyphs(img, g):
    rect = text_rect(g); px = img.load(); found = set()
    for y in range(int(rect['y']), int(rect['y'] + rect['h'])):
        for x in range(int(rect['x']), int(rect['x'] + rect['w'])):
            r, green, b, a = px[x, y]
            if a > 200 and (max(r, green, b) < 60 if g['darkGlyphs'] else min(r, green, b) > 200):
                found.add((x, y))
    return found

def thumb_fixed(a, b, g):
    rect = g['cover']; bar = g['sourceBar']; text = text_rect(g)
    if a.size != b.size: return {'pass': False, 'reason': 'different source sizes'}
    pa, pb = a.load(), b.load(); differences = []; colours = []
    for y in range(int(rect['y']), int(rect['y'] + rect['h'])):
        for x in range(int(rect['x']), int(rect['x'] + rect['w'])):
            if not round_contains(x, y, rect, -2): continue
            # Album-art's cover contains text and a moving bar: compare only the unobscured art.
            if round_contains(x, y, text, 2) or (bar['start'] - 2 <= x < bar['end'] + 2 and bar['y'] - 2 <= y < bar['y'] + bar['h'] + 2): continue
            colours.append(pa[x, y]); differences.append(max(abs(v - w) for v, w in zip(pa[x, y], pb[x, y])))
    variation = max((max(c[i] for c in colours) - min(c[i] for c in colours) for i in range(3)), default=0)
    opaque = bool(colours) and all(c[3] >= 0.9 * 255 for c in colours)
    maximum = max(differences, default=None)
    return {'pixels': len(colours), 'maxChannelDiff': maximum, 'colourRange': variation,
            'pass': opaque and variation >= 3 and maximum is not None and maximum <= 1}

def theme_stills(spec):
    g = spec['themeSpec']; stills = spec['stills']; imgs = {k: load(stills[k]) for k in ('t0', 't10')}
    out = {}
    for name, fn in (('mask', lambda k, i: theme_mask(i, g)),
                     ('progress', lambda k, i: theme_progress(i, g, stills['p_' + k])),
                     ('text', lambda k, i: {'glyphPixels': len(theme_glyphs(i, g)), 'pass': bool(theme_glyphs(i, g))})):
        rows = {k: fn(k, i) for k, i in imgs.items()}; out[name] = dict(rows, **{'pass': all(r['pass'] for r in rows.values())})
    if g['thumbFixed']: out['thumbFixed'] = thumb_fixed(imgs['t0'], imgs['t10'], g)
    if g['artFixed']:
        start = max([v['x'] for v in (out['progress']['t0'], out['progress']['t10']) if v['x'] is not None] or [g['box']['x']]) + 12
        shift, err = profile_shift(imgs['t0'], imgs['t10'], int(start))
        out['artFixed'] = {'shiftPx': shift, 'meanAbsDiff': err, 'fromX': start, 'pass': shift is not None and abs(shift) <= 3}
    return out

def theme_alpha(img, g):
    box = g['box']; x0, x1 = int(box['x'] + box['r'] + 2), int(box['x'] + box['w'] - box['r'] - 2)
    px = img.getchannel('A').load()
    rows = [sum(px[x, y] for x in range(x0, x1)) / (x1 - x0) / 255 for y in range(img.height)]
    opacity = max(rows); top = next((y for y, v in enumerate(rows) if opacity > 0.02 and v >= opacity / 2), None)
    return opacity, top

def theme_events(spec):
    g = spec['themeSpec']; out = {}; ev = spec['events']; top = g['box']['y']
    def series(name): return [(f['t'], load(f['path'])) for f in ev.get(name, [])]
    fr = series('play')
    if fr:
        settled = theme_alpha(fr[-1][1], g)[0] or 1e-6
        rows = [{'t': t, 'o': theme_alpha(i, g)[0] / settled, 'top': theme_alpha(i, g)[1]} for t, i in fr]
        after = [r for r in rows if r['t'] >= 0]; inter = [r for r in after if 0.1 < r['o'] < 0.9]
        tops = [r['top'] for r in after if r['o'] >= 0.05 and r['top'] is not None]
        mono = all(tops[i+1] <= tops[i] + 1 for i in range(len(tops)-1))
        settled_at = next((r['t'] for n, r in enumerate(after) if all(abs(q['o'] - 1) <= 0.05 and q['top'] is not None and abs(q['top'] - top) <= 2 for q in after[n:])), None)
        out['play'] = {'frames': rows, 'intermediate': len(inter), 'firstVisibleTop': tops[0] if tops else None,
            'settledTop': rows[-1]['top'], 'monotone': mono, 'settledAt': settled_at,
            'passIntermediate': len(inter) >= 2,
            'passRise': bool(tops) and top + 6 <= tops[0] <= top + 14 and rows[-1]['top'] is not None and abs(rows[-1]['top'] - top) <= 2 and mono,
            'passSettled': settled_at is not None and settled_at <= 2.5}
    fr = series('pause')
    if fr:
        pre = [theme_alpha(i, g)[0] for t, i in fr if t < 0] or [theme_alpha(fr[0][1], g)[0]]
        ref = sum(pre) / len(pre) or 1e-6
        rows = [{'t': t, 'o': theme_alpha(i, g)[0] / ref, 'alpha': theme_alpha(i, g)[0]} for t, i in fr]
        inter = [r for r in rows if r['t'] >= 0 and 0.1 < r['o'] < 0.9]; late = [r for r in rows if r['t'] >= 2.5]
        out['pause'] = {'frames': rows, 'intermediate': len(inter), 'lateMaxAlpha': max([r['alpha'] for r in late], default=None),
            'passIntermediate': len(inter) >= 2, 'passGone': bool(late) and all(r['alpha'] <= 0.1 for r in late)}
    fr = series('trackB')
    if fr:
        before = [i for t, i in fr if t < 0]
        a, b = theme_glyphs(before[-1] if before else fr[0][1], g), theme_glyphs(fr[-1][1], g)
        rect = text_rect(g); diff = len(a ^ b); fraction = diff / (rect['w'] * rect['h'])
        out['trackB'] = {'glyphsA': len(a), 'glyphsB': len(b), 'differing': diff, 'fraction': fraction,
                         'pass': bool(before) and bool(a) and bool(b) and fraction >= 0.01}
    fr = series('seek')
    if fr: out['seek'] = theme_progress(fr[-1][1], g, spec['seekP'])
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

def flatten(spec):
    f = Image.open(spec['path']).convert('RGBA')
    Image.alpha_composite(Image.new('RGBA', f.size, tuple(spec['background'])), f).convert('RGB').save(spec['out'])
    return {'out': spec['out']}

if __name__ == '__main__':
    mode, path = sys.argv[1], sys.argv[2]
    spec = json.load(open(path, encoding='utf-8'))
    res = {'look': look, 'theme-stills': theme_stills, 'theme-events': theme_events,
           'gif': gif, 'still': alpha_at, 'flatten': flatten}[mode](spec)
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

# Captures native-size GetSourceScreenshot frames at 10 fps; returns frames and achieved rate.
function Invoke-CaptureWindow($Session, [string] $Name, [double] $FromQpc, [double] $ToQpc, [int] $Width = 440, [int] $Height = 96) {
    $dir = Join-Path $lookDirectory $Name
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    Wait-UntilQpc $FromQpc
    $raw = [Collections.Generic.List[object]]::new()
    $next = $FromQpc
    while ((Get-Qpc) -lt $ToQpc) {
        $q = Get-Qpc
        $bytes = Get-SourceShotBytes $Session $Width $Height
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
function Save-SourceStill($Session, [string] $Name, [int] $Width = 440, [int] $Height = 96) {
    $q = Get-Qpc
    $bytes = Get-SourceShotBytes $Session $Width $Height
    $path = Join-Path $lookDirectory "$Name.png"
    [IO.Directory]::CreateDirectory((Split-Path -Parent $path)) | Out-Null
    [IO.File]::WriteAllBytes($path, $bytes)
    [pscustomobject]@{ path = $path; qpc = ($q + (Get-Qpc)) / 2 }
}

$lookEvents = @(
    @{ name = 'seek'; at = 25; test = { param($d) (Test-Data $d 'playing' 'fixtureSngA') -and [Math]::Abs([double] (Get-Prop $d 'position') - 100) -le 1.5 } },
    @{ name = 'pause'; at = 45; test = { param($d) Test-Data $d 'paused' 'fixtureSngA' } },
    @{ name = 'play'; at = 60; test = { param($d) Test-Data $d 'playing' 'fixtureSngA' } },
    @{ name = 'trackB'; at = 80; test = { param($d) Test-Data $d 'playing' 'fixtureSngB' } })

# Uses the existing Browser Source; scene shutdown releases the previous stream before counting the next one.
function Set-BLookSource($Session, [string] $Url, [int] $Width, [int] $Height) {
    [void] (Obs $Session 'SetInputSettings' @{ inputName = $sourceName; inputSettings = @{ url = $Url; width = $Width; height = $Height }; overlay = $true })
    [void] (Obs $Session 'SetSceneItemEnabled' @{ sceneName = $sceneName; sceneItemId = $Session.ItemId; sceneItemEnabled = $true })
}
function Connect-BLookSource($App, $Session, $lookInput, [switch] $Sample) {
    Assert-TimeBox
    # The OBS page owns exactly one stream; wait for it to go. Harness readers can end on their own at the 5-minute
    # stream lifetime (4 October), so the condition counts only the drop from the pre-release snapshot.
    $beforeRelease = Get-State $App.Root 'look-before-release'
    $ownedBefore = [int] (Get-Overlay $beforeRelease 'streams')
    [void] (Obs $Session 'SetSceneItemEnabled' @{ sceneName = $sceneName; sceneItemId = $Session.ItemId; sceneItemEnabled = $false })
    $released = $ownedBefore -eq 0 -or (Wait-For {
        Assert-TimeBox
        $s = Get-State $App.Root 'look-release'
        $s -and (Get-Overlay $s 'sampleStreams') -eq 0 -and [int] (Get-Overlay $s 'streams') -le $ownedBefore - 1
    } 20 250)
    if (-not $released) { throw "B-LOOK: previous OBS stream did not release within 20 s (streams before: $ownedBefore)." }
    $url = if ($Sample) { $lookInput.url } else { "$($overlayUrl)?look=$($lookInput.id)" }
    $lo = Get-Qpc
    Set-BLookSource $Session $url $lookInput.width $lookInput.height
    $until = [DateTime]::UtcNow.AddSeconds(30)
    while ([DateTime]::UtcNow -lt $until) {
        Assert-TimeBox
        $before = Get-Qpc; $s = Get-State $App.Root 'look-connect'; $hi = Get-Qpc
        $connected = if ($Sample) { (Get-Overlay $s 'sampleStreams') -eq 1 } else {
            (Get-Prop (Get-Overlay $s 'streamsByLook') $lookInput.id) -eq 1
        }
        if ($connected) {
            # Sample position starts at this OBS stream's open, not command-navigate or a second SSE reader's open.
            # Last absent -> first present snapshots bracket the epoch without requiring OBS CDP/new app hooks.
            return [ordered]@{ url = $url; width = $lookInput.width; height = $lookInput.height; startQpc = ($lo + $hi) / 2
                epochSpanSeconds = Round3 (($hi - $lo) / $freq); streams = Get-Overlay $s 'streams'; sample = [bool] $Sample }
        }
        if ($s) { $lo = $before }
        Wait-Seconds 0.1
    }
    throw 'B-LOOK: OBS page did not connect within 30 s.'
}
function Test-BLookThemes($App, $Session, $Observed) {
    $Observed.themes = [ordered]@{}
    foreach ($lookInput in $bLookInputs) {
        Assert-TimeBox
        $theme = $lookInput.theme; $prefix = "B-LOOK.$theme"; $row = [ordered]@{ spec = $lookInput.spec }
        $Observed.themes[$theme] = $row
        try {
            $connection = Connect-BLookSource $App $Session $lookInput -Sample
            $row.connection = $connection
            Add-Check "$prefix.sourceConnected" 'one sample stream after previous OBS stream released' $connection $true
            # Eight seconds after observed connection is beyond the <=2.5s show animation/art load.
            Wait-Seconds 8
            $t0 = Save-SourceStill $Session "themes/$theme-t0" $lookInput.width $lookInput.height
            Wait-UntilQpc ($t0.qpc + 10 * $freq)
            $t10 = Save-SourceStill $Session "themes/$theme-t10" $lookInput.width $lookInput.height
            $stills = [ordered]@{ t0 = $t0.path; t10 = $t10.path
                p_t0 = (($t0.qpc - $connection.startQpc) / $freq % 240) / 240
                p_t10 = (($t10.qpc - $connection.startQpc) / $freq % 240) / 240 }
            $row.stills = [ordered]@{ t0 = Get-RelativePath $t0.path; t10 = Get-RelativePath $t10.path
                elapsedSeconds = Round3 (($t10.qpc - $t0.qpc) / $freq); p_t0 = $stills.p_t0; p_t10 = $stills.p_t10 }
            $a = Invoke-Pillow 'theme-stills' ([ordered]@{ themeSpec = $lookInput.spec; stills = $stills })
            $row.analysis = $a
            foreach ($oracle in @('mask', 'progress', 'text') + $(if ($lookInput.spec.thumbFixed) { 'thumbFixed' } else { 'artFixed' })) {
                $value = Get-Prop $a $oracle
                if ($oracle -eq 'progress' -and $connection.epochSpanSeconds -gt 2) {
                    Add-Blocked "$prefix.$oracle" 'sample epoch bracket <=2 s for the specified pixel tolerance' "epoch uncertainty $($connection.epochSpanSeconds) s; stills retained, analysis not accepted"
                } else {
                    Add-Check "$prefix.$oracle" $(switch ($oracle) {
                        'mask' { "$($lookInput.spec.maskKind): inset alpha >=0.9; outside AA ring <=$($lookInput.spec.outsideAlphaCap); native source size" }
                        'progress' { if ($lookInput.spec.progressKind -eq 'saturation-reveal') { 'saturation step at box.x + box.w * p +-6 px, both stills' }
                            else { 'bar run = sourceBar.width * p +-3 px; luminance step >=0.25, both stills' } }
                        'text' { 'glyph pixels in generated column/text band (dark for matte-light, white otherwise), both stills' }
                        'thumbFixed' { 'opaque, nonuniform cover stable (max RGBA difference <=1); album-art text/bar excluded' }
                        'artFixed' { 'pill luminance profile shift <=3 px right of both reveal boundaries' }
                    }) $value ([bool] (Get-Prop $value 'pass'))
                }
            }
        } catch {
            if ($_.Exception.Message -like 'TIMEBOX:*') { throw }
            $row.error = $_.Exception.Message
            Add-RunnerFailure $prefix $_
        }
    }
}
function Test-BLookMatte($App, $Session, $Reader, $Observed) {
    $lookInput = @($bLookInputs | Where-Object { $_.theme -eq 'matte' })[0]
    $row = [ordered]@{}; $Observed.matteSeries = $row
    $row.connection = Connect-BLookSource $App $Session $lookInput
    Add-Check 'B-LOOK.matte.seriesConnected' 'real OBS stream tagged with the matte look' $row.connection $true
    $navQpc = Send-HookCommand $App.Root 'command-navigate'
    $initial = Wait-SseData $Reader { param($d) (Test-Data $d 'playing' 'fixtureSngA') -and [double] (Get-Prop $d 'position') -lt 15 } 60 $navQpc
    if (-not $initial) { Add-Blocked 'B-LOOK.matte.timeline' 'fixture timeline restarted' 'no playing A event within 60 s'; return }
    $start = Get-PageStartQpc $initial; $duration = [double] (Get-Prop $initial.data 'duration')
    $windows = [ordered]@{}; $events = [ordered]@{}; $info = [ordered]@{}
    foreach ($e in $lookEvents) {
        $w = Invoke-CaptureWindow $Session "matte/$($e.name)" ($start + ($e.at - 0.5) * $freq) ($start + ($e.at + 3.5) * $freq) $lookInput.width $lookInput.height
        $windows[$e.name] = $w
        if ($w.Frames.Count -eq 0) { throw "B-LOOK.matte: no $($e.name) frames captured." }
    }
    Wait-Seconds 1
    foreach ($e in $lookEvents) {
        $predicted = $start + $e.at * $freq; $hit = Find-SseData $Reader $e.test ($predicted - 2 * $freq)
        $evQpc = if ($hit -and $hit.qpc -lt $predicted + 3.5 * $freq) { $hit.qpc } else { $predicted }
        $w = $windows[$e.name]
        $info[$e.name] = [ordered]@{ predictedPage = $e.at; receivedPage = if ($hit) { Round3 (($hit.qpc - $start) / $freq) } else { $null }
            source = if ($hit -and $evQpc -eq $hit.qpc) { 'sse' } else { 'predicted' }; fps = $w.Fps; frames = $w.Frames.Count }
        if ($w.Fps -lt 8) { Add-Blocked "B-LOOK.matte.$($e.name).captureRate" '>=8 fps (target10)' "achieved $($w.Fps) fps" }
        else { Add-Check "B-LOOK.matte.$($e.name).captureRate" '>=8 fps (target10)' $w.Fps $true }
        $events[$e.name] = @($w.Frames | ForEach-Object { [ordered]@{ path = $_.path; t = Round3 (($_.qpc - $evQpc) / $freq) } })
    }
    $row.events = $info; $row.durationA = $duration
    $seekP = (100 + ($windows['seek'].Frames[-1].qpc - $start) / $freq - 25) / $duration
    $a = Invoke-Pillow 'theme-events' ([ordered]@{ themeSpec = $lookInput.spec; events = $events; seekP = $seekP })
    $row.analysis = $a
    $add = { param($eventName, $name, $expected, $field)
        $v = Get-Prop $a $eventName; $n = "B-LOOK.matte.$eventName.$name"
        if ($windows[$eventName].Fps -lt 8) { Add-Blocked $n $expected 'capture below 8 fps; see event analysis' }
        else { Add-Check $n $expected $v ([bool] (Get-Prop $v $field)) }
    }
    & $add 'seek' 'progress' 'settled seek: expected bar run +-3 px; luminance step >=0.25' 'pass'
    & $add 'pause' 'intermediateFrames' '>=2 intermediate opacity frames' 'passIntermediate'
    & $add 'pause' 'goneBy2500ms' 'alpha <=0.1 from 2.5 s after pause' 'passGone'
    & $add 'play' 'intermediateFrames' '>=2 intermediate opacity frames' 'passIntermediate'
    & $add 'play' 'rise12px' 'top edge 32+-2 to 20+-2, non-increasing' 'passRise'
    & $add 'play' 'settledBy2500ms' 'settled <=2.5 s after play' 'passSettled'
    & $add 'trackB' 'text.differsAB' 'nonempty glyph masks A/B differ by >=1% of generated text region' 'pass'
}

function Test-BLook($App, $Session) {
    $obs = [ordered]@{}
    $reader = Start-SseReader 'B-LOOK'
    try {
        $showing = Wait-For { $s = Get-State $App.Root 'look-streams'; if ((Get-Overlay $s 'streams') -ge 2) { $s } } 60 1000
        Add-Check 'B-LOOK.sourceConnected' 'OBS page and harness reader both connected (streams >= 2)' (Get-Overlay $showing 'streams') ([bool] $showing)
        $loaded = Get-Overlay $showing 'looks'
        $loadedOk = (Get-Prop $loaded 'count') -eq 8 -and (Get-Prop $loaded 'readOnly') -eq $false
        Add-Check 'B-LOOK.defaultLooksLoaded' 'eight editable default looks loaded from the disposable app data/obs-looks.json' $loaded $loadedOk
        if (-not $loadedOk) { throw 'B-LOOK: default looks were not loaded; refuse fallback-pill screenshots.' }
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
        Test-BLookThemes $App $Session $obs
        # A fresh reader: the first one ends at the 5-minute stream lifetime during the theme stills.
        Stop-SseReader $reader
        $reader = Start-SseReader 'B-LOOK-matte'
        Test-BLookMatte $App $Session $reader $obs
    } finally {
        # Restore the plain preset even after a per-theme failure; B-DOCS captures must stay pill-sized.
        try { Set-BLookSource $Session $overlayUrl 440 96 } finally {
            Stop-SseReader $reader
            $scenarioResults['B-LOOK'] = $obs
        }
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
# B-DOCS (04-overlay.gif and 05-paused-dimmed.png; the setup walkthrough images come from GUIDE)

# (Setup walkthrough images are not produced here; see GUIDE.)
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
    [IO.Directory]::CreateDirectory((Join-Path $runDirectory 'docs-frames')) | Out-Null


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
            $srcPath = Join-Path $runDirectory 'docs-frames/05-source.png'
            [IO.File]::WriteAllBytes($srcPath, (Get-SourceShotBytes $Session))
            # The guide shows the dimmed bar itself, on the same background as 04-overlay.gif.
            [void] (Invoke-Pillow 'flatten' ([ordered]@{ path = $srcPath; out = (Join-Path $docsOut '05-paused-dimmed.png'); background = @(24, 24, 28, 255) }))
            $still = Invoke-Pillow 'still' ([ordered]@{ path = $srcPath })
            $obs.pausedOpacity = $still.opacity
            Add-Check 'B-DOCS.05.dimmed' 'paused pill shown at opacity 0.7 +-0.05 with the toggle off' (Round3 $still.opacity) ([Math]::Abs([double] $still.opacity - 0.7) -le 0.05)
        }
    } finally {
        Stop-SseReader $reader
        try { [void] (Send-HookCommand $App.Root 'command-obs-hide-paused-on') } catch { }
    }

    # Every regenerated image exists at the path the guide references; GIFs <= 3 MB.
    $guide = Get-Content -Raw -LiteralPath (Join-Path $repo 'docs/obs-overlay.md')
    foreach ($n in @('04-overlay.gif', '05-paused-dimmed.png')) {
        $referenced = $guide.Contains("images/obs-overlay/$n")
        Add-Check "B-DOCS.guideReferences.$n" 'docs/obs-overlay.md references the image' $referenced $referenced
        Test-ImageOnDisk $n (Join-Path $docsOut $n) ($n -like '*.gif')
    }
    # Setup images (docs/images/obs-overlay/setup/NN-*.png) come from a GUIDE hold, not from B-DOCS: only check that
    # every one the guide references exists in the repository and is non-empty.
    $setupRefs = @([regex]::Matches($guide, 'images/obs-overlay/setup/[A-Za-z0-9._-]+\.png') | ForEach-Object { $_.Value } | Select-Object -Unique)
    $setupState = @($setupRefs | ForEach-Object {
        $p = Join-Path $repo ('docs/' + $_)
        $len = if (Test-Path -LiteralPath $p -PathType Leaf) { (Get-Item -LiteralPath $p).Length } else { $null }
        [ordered]@{ image = $_; bytes = $len; ok = ($null -ne $len -and $len -gt 0) }
    })
    $setupBad = @($setupState | Where-Object { -not $_.ok })
    $obs.setupImages = [ordered]@{ referenced = $setupRefs.Count; missingOrEmpty = $setupBad.Count }
    Add-Check 'B-DOCS.guideSetupImages' 'docs/obs-overlay.md references at least one images/obs-overlay/setup/*.png and every referenced file exists and is non-empty' ([ordered]@{
            referenced = $setupRefs.Count; problems = @($setupBad | ForEach-Object { $_.image }); images = $setupState }) ($setupRefs.Count -gt 0 -and $setupBad.Count -eq 0)
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

# GUIDE (only when named; not part of All). Starts a disposable Nativune (ObsOverlay off, normal full view via bench
# state Full, Playing steady profile, Discord presence off) and a disposable OBS with its default empty scene (no
# Initialize-ObsOverlayScene, no input), moves the OBS main window to 80,80 1280x800, writes <run>/guide-env.json and
# holds until <run>/guide-stop exists or -HoldMinutes elapse. Both are stopped by the caller's finally path.
function Invoke-Guide {
    $g = [ordered]@{ holdMinutes = $HoldMinutes }
    $scenarioResults['GUIDE'] = $g
    Assert-TimeBox
    $guide = Start-OverlayApp 'guide' 'Playing' 'GUIDE' @{ ObsOverlay = $false }
    $script:guideApp = $guide
    $readyPath = Join-Path (Get-BenchDirectory $guide.Root) 'ready.json'
    $ready = Test-Path -LiteralPath $readyPath
    Add-Check 'GUIDE.appReady' 'Playing fixture ready in the normal full view (ready.json)' ([ordered]@{ ready = $ready; failedJson = Get-FailedJson $guide.Root; adminEnabled = (Get-AdminEnabled $guide.App.Id) }) $ready
    if (-not $ready) { throw 'GUIDE: the app did not become ready; OBS is not launched.' }
    $p = $guide.App
    $title = Wait-For { $p.Refresh(); if ($p.MainWindowTitle) { $p.MainWindowTitle } } 30 500
    Add-Check 'GUIDE.appWindow' 'Nativune main window has a title' $title ([bool] $title)
    $overlayUp = [bool] (Test-OverlayHttp200)
    Add-Check 'GUIDE.overlayOffAtStart' "$overlayUrl does not answer 200 before the guide turns the overlay on" $overlayUp (-not $overlayUp)

    $obs = New-ObsPortable -RunDir (Join-Path $repo ".cache/obs-portable/$runId-guide")
    $obsInstances.Add($obs); $script:guideObs = $obs
    $record = [ordered]@{ label = 'guide'; itemHidden = $false; shutdownOff = $false; owned = $null; paths = $null; scene = $null }
    $obsLaunches.Add($record)
    try { [void] (Start-ObsPortable $obs) } finally { $record.owned = $obs.OwnedCheck }
    $script:guideObsUp = [DateTime]::UtcNow
    Add-Check 'GUIDE.ownedInstance' "launched PID+creation time, websocket listener PID = OBS PID, GetVersion $script:ObsPortableVersion" $obs.OwnedCheck ([bool] $obs.OwnedCheck.passed)
    $session = [pscustomobject]@{ Obs = $obs }
    $main = Get-ObsMainWindow $session
    [void] [ObsBE2E]::SetWindowPos($main, [IntPtr]::Zero, 80, 80, 1280, 800, 0x0014)
    # Read-only look at the default scene: no source may exist (nothing is created).
    $inputs = $null
    try {
        $ws = Connect-ObsWebSocket $obs
        try { $inputs = @((Invoke-ObsRequest $ws 'GetInputList' @{}).inputs) } finally { Close-ObsWebSocket $ws }
    } catch { $g.inputListError = $_.Exception.Message }
    Add-Check 'GUIDE.obsEmptyScene' 'default OBS scene with no sources (GetInputList empty)' ([ordered]@{ inputs = $(if ($null -ne $inputs) { $inputs.Count } else { $null }); error = Get-Prop $g 'inputListError' }) ($null -ne $inputs -and $inputs.Count -eq 0)

    $stopFile = Join-Path $runDirectory 'guide-stop'
    $holdDeadline = [DateTime]::UtcNow.AddMinutes($HoldMinutes)
    $envPath = Join-Path $runDirectory 'guide-env.json'
    [IO.File]::WriteAllText($envPath, ([ordered]@{
        obsPid = $obs.ProcessId; appPid = $guide.App.Id; appWindowTitle = $title; overlayUrl = $overlayUrl
        stopFile = $stopFile; holdDeadlineUtc = $holdDeadline.ToString('o'); holdMinutes = $HoldMinutes
        obsWindow = [ordered]@{ x = 80; y = 80; width = 1280; height = 800 }
        appWindowSettings = [ordered]@{ x = 100; y = 100; width = 1280; height = 800 }
        fixtureTrackSeconds = 1800; appReadyUtc = [DateTime]::UtcNow.ToString('o')
    } | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    $g.envFile = $envPath; $g.stopFile = $stopFile
    Write-Host "GUIDE environment ready. Env file: $envPath"
    Write-Host "Create '$stopFile' to end the hold (or wait until $($holdDeadline.ToString('o')))."
    $reason = $null
    try {
        while ($true) {
            if (Test-Path -LiteralPath $stopFile) { $reason = 'stop-file'; break }
            if ([DateTime]::UtcNow -ge $holdDeadline) { $reason = 'hold-elapsed'; break }
            if ($guide.App.HasExited) { $reason = 'app-exited'; break }
            if ($obs.Process.HasExited) { $reason = 'obs-exited'; break }
            Start-Sleep -Seconds 2
        }
    } finally {
        $g.holdEnded = $reason
        # Order: OBS first, then the app; the owner-profile check runs after both (after the outer finally).
        try { Stop-ObsPortable $obs } catch { Add-Check 'GUIDE.obsStop' 'disposable OBS stopped without an owner-profile change' $_.Exception.Message $false }
        $script:guideObsDown = [DateTime]::UtcNow
        Stop-App $guide.App $guide.Root; $script:guideApp = $null
    }
}

$appVersion = $null
$scenarioErrors = [ordered]@{}
$ownerBefore = Get-OwnerObsProfileSnapshot
$lookApp = $null; $visApp = $null; $lookSession = $null
$script:guideApp = $null; $script:guideObs = $null; $script:guideObsUp = $null; $script:guideObsDown = $null
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
            $looksJson = [ordered]@{ version = 1; looks = @($bLookInputs | ForEach-Object { $_.look }); retired = @() } | ConvertTo-Json -Depth 16
            $lookApp = Start-OverlayApp 'look' $null $first -LooksJson $looksJson
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

    # GUIDE: disposable Nativune (overlay off, full view, Playing) + empty OBS, held open for a computer-use guide.
    if ($runGuide) {
        $t0 = [DateTime]::UtcNow
        try { Invoke-Guide } catch { Add-RunnerFailure 'GUIDE' $_ }
        if ($scenarioResults.Contains('GUIDE')) { $scenarioResults['GUIDE']['wallSeconds'] = [Math]::Round(([DateTime]::UtcNow - $t0).TotalSeconds, 1) }
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
    if ($script:guideApp) { Stop-App $script:guideApp.App $script:guideApp.Root; $script:guideApp = $null }
    foreach ($process in $started) {
        try { if (-not $process.HasExited) { foreach ($id in (Get-ProcessTree $process.Id $rootBase)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } } } catch { }
    }
    foreach ($key in @($testEnv.Keys) + $benchEnvKeys) { Set-ProcessEnv $key $null }
    if (Test-Path -LiteralPath $rootBase) {
        foreach ($d in @(Get-ChildItem -LiteralPath $rootBase -Directory -ErrorAction SilentlyContinue)) { Copy-BenchJson $d.FullName }
        Start-Sleep -Seconds 1; Remove-Item -LiteralPath $rootBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Diff entries with paths relative to %APPDATA% / %LOCALAPPDATA% (snapshot keys are absolute; "listing:" marks the LOCALAPPDATA listing).
function ConvertTo-OwnerDiffPaths($Diff) {
    $rel = {
        param([string] $p)
        $prefix = ''
        if ($p.StartsWith('listing:')) { $prefix = 'listing:'; $p = $p.Substring(8) }
        foreach ($root in @(@('%LOCALAPPDATA%', $env:LOCALAPPDATA), @('%APPDATA%', $env:APPDATA))) {
            if ($root[1] -and $p.StartsWith($root[1], [StringComparison]::OrdinalIgnoreCase)) { return $prefix + $root[0] + $p.Substring($root[1].Length) }
        }
        $prefix + ($p -replace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%')
    }
    foreach ($d in @($Diff)) {
        [ordered]@{ path = (& $rel ([string] $d.path)); change = $d.change; before = Get-Prop $d 'before'; after = Get-Prop $d 'after' }
    }
}
# B-ISO after every OBS instance stopped: the owner's OBS config is byte-identical (content, size, mtime).
if ('B-ISO' -in $selected) {
    $ownerAfter = Get-OwnerObsProfileSnapshot
    $diff = Compare-OwnerObsProfileSnapshot $ownerBefore $ownerAfter
    $scenarioResults['B-ISO'] = [ordered]@{ entriesBefore = $ownerBefore.Count; entriesAfter = $ownerAfter.Count; obsLaunches = $obsLaunches.Count
        changes = @($diff | ForEach-Object { [ordered]@{ path = $_.path -replace [regex]::Escape($env:USERPROFILE), '%USERPROFILE%'; change = $_.change } }) }
    Add-Check 'B-ISO.ownerProfileIdentical' 'SHA-256, size and mtime of every file under %APPDATA%\obs-studio and the %LOCALAPPDATA%\obs-studio* listing identical before/after' ([ordered]@{
            entries = $ownerAfter.Count; changes = $diff.Count; obsLaunches = $obsLaunches.Count; paths = @(ConvertTo-OwnerDiffPaths $diff) }) ($diff.Count -eq 0)
    if ($obsLaunches.Count -eq 0) { Add-Blocked 'B-ISO.obsLaunched' 'at least one disposable OBS launch in this run' 'no OBS launched (select B-LOOK/B-VIS/B-DOCS too)' }
}

# GUIDE after the OBS instance and the app stopped: owner profile identical, OBS on-screen minutes within the hold.
if ($runGuide) {
    $ownerAfterGuide = Get-OwnerObsProfileSnapshot
    $guideDiff = @(Compare-OwnerObsProfileSnapshot $ownerBefore $ownerAfterGuide)
    Add-Check 'GUIDE.ownerObsProfileUnchanged' 'SHA-256, size and mtime of every file under %APPDATA%\obs-studio and the %LOCALAPPDATA%\obs-studio* listing identical before/after' ([ordered]@{
            entries = $ownerAfterGuide.Count; changes = $guideDiff.Count; paths = @(ConvertTo-OwnerDiffPaths $guideDiff) }) ($guideDiff.Count -eq 0)
    $guideMinutes = if ($script:guideObsUp -and $script:guideObsDown) { [Math]::Round(($script:guideObsDown - $script:guideObsUp).TotalMinutes, 2) } else { $null }
    if ($scenarioResults.Contains('GUIDE')) { $scenarioResults['GUIDE']['obsMinutes'] = $guideMinutes }
    Add-Check 'GUIDE.obsMinutes' "OBS on screen (launch to stop) <= HoldMinutes $HoldMinutes + 5 min" ([ordered]@{ obsMinutes = $guideMinutes; holdMinutes = $HoldMinutes }) ($null -ne $guideMinutes -and $guideMinutes -le $HoldMinutes + 5)
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
