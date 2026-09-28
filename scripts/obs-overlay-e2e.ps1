<#
E2E-A for the opt-in OBS now-playing overlay (notes/research/obs-overlay-2026-09-28/plan.md §6.1; hook surface in
design.md §2.8). It drives the real app (WebHostWindow, the shared reader, ObsOverlayServer on
http://localhost:47813/) against the local fixture page. No OBS, YouTube, Google or Discord request is involved,
except A-PROD, whose release build has no fixture page and loads the normal site. A-PROD never clicks the
"How to set up…" button (that would open the real default browser); it checks the guide URL statically instead.

Regenerate:
  pwsh -NoProfile -File scripts/obs-overlay-e2e.ps1 -Scenario All -OutputDirectory artifacts/obs-overlay
  pwsh -NoProfile -File scripts/obs-overlay-e2e.ps1 -Scenario A-SEC,A-TIME          # a subset
  pwsh -NoProfile -File scripts/obs-overlay-e2e.ps1 -Scenario A-SEC -SkipPublish    # reuse the published builds

Steps: publish the hook build (-p:DiscordPresenceTestHooks=true) to artifacts/obs-overlay/app (never ship it) and,
for A-PROD, the release build to artifacts/obs-overlay/release-app; per scenario create fresh roots
.cache/obs-overlay-e2e/<run>/<scenario>/ with data/settings.json v7 (ObsOverlay/ObsHidePaused written explicitly
unless the check is about a missing key) and a copy of the pinned uBO Lite tree. The app runs as
`Nativune.exe web --root <root>` with NATIVUNE_TEST_DISCORD_FIXTURE_PAGE=1 and a random
nativune-test-<32 hex>-discord-ipc- prefix. When this harness is elevated, the app is started with a restricted
token: `runas /trustlevel:0x20000` runs a small pwsh helper (written into the run root) that reads a JSON launch
spec, sets the environment, starts the app and writes its PID. That token has BUILTIN\Administrators deny-only; the
oracle is "Administrators group not enabled in the app token" (WindowsPrincipal.IsInRole(Administrator) on the app's
process token is false). When the harness is not elevated the app is started directly and the same oracle applies.
Integrity is recorded as information only (as the built-in Administrator with admin approval off, every process is
High). Scenarios run serially (the port 47813 is fixed; never run two overlay E2Es at once).
The owner's data/ and installed profile are never touched.

Readers: an SSE reader child process (HttpClient streaming) writes events-<name>.jsonl lines
{qpc, utc, kind: open|retry|comment|data|close|error, text|json}; a raw TcpClient covers A-SEC/A-LIFE/A-LIVE;
the installed Google Chrome (headless, CDP, --user-data-dir under the run root) checks page behaviour through the
DOM and window.__state (absent Chrome -> blocked). App state comes from the hook commands and
state-<label>.json (overlay{...}) / diagnostics-<label>.json under <root>/data/discord-bench.

Scenarios (plan §6.1):
  A-OFF        no key / false / true then command-obs-off: prefix registrable by another process, no app response
               on :47813, streams 0, no overlay reads.
  A-TIME       default timeline scored from the initial event through page 143 s, hidePaused true and false, and the
               AdFallback profile: exact semantic event sequence, no other data events, no album canary.
  A-AD         Chrome page on the default timeline and AdFallback; hide-when-paused off saved at page 70 s (in the ad):
               pill hidden by 67.5 s, back with A's title by 77.5 s, no data between ad and restore, restore carries
               the new hidePaused.
  A-SAME       IdOnly profile: exactly one new event, only id changed.
  A-CLOCK      command-clock-mismatch-on/off: clock:false, silence until off, then clock:true with a fresh anchor.
  A-GAP        ShortGap (no none), ReaderGap, DomGap, native controls-unavailable (none at gapStartQpc + 8 +-1.2 s;
               fresh playing <= 2 s after -off).
  A-INV        power suspend, command-navigate, renderer kill (ProcessFailed): none <= 1 s; hold-read + off/on +
               release: the held sample is not sent and off closes the stream <= 1 s.
  A-IDLE       Paused for 120 s: 0 data events, comments every 5 +-1 s.
  A-DEMAND     overlay reads 1 +-0.2/s for 1 and 2 streams, 0 after the last closes, late join <= 1.1 s after a
               Presence read, Compact 1/s, Presence back to 5 s, Discord write gaps >= 14.5 s, reads while hidden
               with SleepInBackground=true, never two reads in flight.
  A-LIVE       clean close released <= 7 s (Closed); suspended consumer and non-reading burst client released at
               lifetime (Lifetime), pending write observed, no crash.
  A-LIFE       quit with 0, 2, 8 streams and during a pending write (exit <= 5 s, prefix registrable after), off/on x20,
               start while another process holds the prefix then recover, Administrators group not enabled in the app token.
  A-SEC        raw request table (LAN IPv4 row blocked when the PC has no LAN IPv4), headers, 8 streams + 9th 503.
  A-RECON      Chrome: error page when off then reload connects; server restart; 30 s without streams; 9th-stream 503
               then retry after 30 s; lifetime renewal without hiding.
  A-TEXT       Chrome: Text profile literal text + ellipsis, projection within 1 %; ArtSwap sequence guard (final B).
  A-SET        UI Automation of Settings > OBS (names, live region, Cancel/Save/relaunch, missing key, hide-paused
               broadcast, Copy link, guide URI recorder, Block ads link, keyboard focus, save failure, bind conflict).
  A-PROD       release build: no /fixture-art route, CSP without 'self', no fixture-art in /overlay.js, no hook strings
               (launched-uri, command-obs, command-controls, fixture-art) in Nativune.dll/resources (UTF-8 and UTF-16),
               guide URL present in the release assembly/resources (static check; the button is not clicked).
  A-PAUSEVIEW  Chrome: paused view (0.7 opacity, frozen fill, no running animations), PausedSeek, hidePaused switch.

Report: <OutputDirectory>/<utc>/report.json (each check {name, expected, observed, status pass|fail|blocked}),
events.json (every reader's lines), screenshots/. Blocked never counts as pass; the exit code is 1 when any check
fails or is blocked.
#>
[CmdletBinding()]
param(
    # One scenario id, All, or a comma-separated list (A-SEC,A-TIME).
    [string[]] $Scenario = @('All'),
    [string] $OutputDirectory = 'artifacts/obs-overlay',
    [switch] $SkipPublish,
    [switch] $KeepRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$allScenarios = @('A-OFF', 'A-TIME', 'A-AD', 'A-SAME', 'A-CLOCK', 'A-GAP', 'A-INV', 'A-IDLE', 'A-DEMAND', 'A-LIVE', 'A-LIFE',
    'A-SEC', 'A-RECON', 'A-TEXT', 'A-SET', 'A-PROD', 'A-PAUSEVIEW')
$Scenario = @($Scenario | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
foreach ($name in $Scenario) {
    if ($name -ne 'All' -and $name -notin $allScenarios) { throw "Unknown scenario '$name'. Valid: All, $($allScenarios -join ', ')." }
}
$selected = if ('All' -in $Scenario) { $allScenarios } else { @($allScenarios | Where-Object { $_ -in $Scenario }) }

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$commandLine = 'pwsh -NoProfile -File scripts/obs-overlay-e2e.ps1 ' + (($PSBoundParameters.GetEnumerator() | ForEach-Object {
    if ($_.Value -is [switch]) { if ($_.Value) { "-$($_.Key)" } } else { "-$($_.Key) $(@($_.Value) -join ',')" } }) -join ' ')
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
$appDirectory = Join-Path $repo 'artifacts/obs-overlay/app'
$appExe = Join-Path $appDirectory 'Nativune.exe'
$releaseDirectory = Join-Path $repo 'artifacts/obs-overlay/release-app'
$releaseExe = Join-Path $releaseDirectory 'Nativune.exe'
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$runDirectory = Join-Path $outputRoot $runId
$shotDirectory = Join-Path $runDirectory 'screenshots'
$rootBase = Join-Path $repo ".cache/obs-overlay-e2e/$runId"
[IO.Directory]::CreateDirectory($shotDirectory) | Out-Null
[IO.Directory]::CreateDirectory($rootBase) | Out-Null

$ubolVersion = [regex]::Match((Get-Content -Raw (Join-Path $repo 'src/Nativune/BrowserPrivacy.cs')),
    'ExtensionVersion\s*=\s*"([^"]+)"').Groups[1].Value
if (-not $ubolVersion) { throw 'Could not read BrowserPrivacy.ExtensionVersion.' }
$ubolSource = Join-Path $repo ".tools/ubol/$ubolVersion"
if (-not (Test-Path -LiteralPath (Join-Path $ubolSource 'manifest.json') -PathType Leaf)) {
    throw "uBO Lite $ubolVersion is missing at $ubolSource (manifest.json). Provision the repository .tools/ubol tree first."
}

$port = 47813
$overlayUrl = "http://localhost:$port/"
$guideUri = 'https://github.com/Hantu-Raya/Nativune/blob/main/docs/obs-overlay.md'
$guideFailedMessage = 'The setup guide could not be opened. Visit github.com/Hantu-Raya/Nativune/blob/main/docs/obs-overlay.md in your browser.'
$chromeExe = 'C:\Program Files\Google\Chrome\Application\chrome.exe'
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
$started = [Collections.Generic.List[Diagnostics.Process]]::new()
$readers = [Collections.Generic.List[object]]::new()
$chromes = [Collections.Generic.List[object]]::new()
$heldListeners = [Collections.Generic.List[object]]::new()
$aclDenied = [Collections.Generic.List[string]]::new()
$script:launchCount = 0
$script:labelSeq = 0

Add-Type -AssemblyName System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class ObsE2E {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int size);
  [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
  [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
  [DllImport("advapi32.dll", SetLastError = true)] static extern bool OpenProcessToken(IntPtr p, uint access, out IntPtr token);
  [DllImport("advapi32.dll", SetLastError = true)] static extern bool GetTokenInformation(IntPtr t, int cls, IntPtr buf, int len, out int ret);
  [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthorityCount(IntPtr sid);
  [DllImport("advapi32.dll")] static extern IntPtr GetSidSubAuthority(IntPtr sid, uint n);
  [DllImport("ntdll.dll")] static extern int NtSuspendProcess(IntPtr h);
  [DllImport("ntdll.dll")] static extern int NtResumeProcess(IntPtr h);
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
  // Mandatory integrity RID of the process token (0x2000 medium, 0x3000 high), or -1.
  public static int IntegrityRid(int pid) {
    IntPtr p = OpenProcess(0x1000, false, pid); if (p == IntPtr.Zero) return -1;
    IntPtr t; if (!OpenProcessToken(p, 0x0008, out t)) { CloseHandle(p); return -1; }
    int len; GetTokenInformation(t, 25, IntPtr.Zero, 0, out len);
    IntPtr buf = Marshal.AllocHGlobal(len); int rid = -1;
    try {
      if (GetTokenInformation(t, 25, buf, len, out len)) {
        IntPtr sid = Marshal.ReadIntPtr(buf);
        int count = Marshal.ReadByte(GetSidSubAuthorityCount(sid));
        rid = Marshal.ReadInt32(GetSidSubAuthority(sid, (uint)(count - 1)));
      }
    } finally { Marshal.FreeHGlobal(buf); CloseHandle(t); CloseHandle(p); }
    return rid;
  }
  // Process token handle (TOKEN_QUERY | TOKEN_DUPLICATE; the duplicate right lets WindowsIdentity build the
  // impersonation token IsInRole needs), or IntPtr.Zero. Caller releases it with CloseToken.
  public static IntPtr OpenToken(int pid) {
    IntPtr p = OpenProcess(0x1000, false, pid); if (p == IntPtr.Zero) return IntPtr.Zero;
    try { IntPtr t; return OpenProcessToken(p, 0x0008 | 0x0002, out t) ? t : IntPtr.Zero; } finally { CloseHandle(p); }
  }
  public static void CloseToken(IntPtr t) { if (t != IntPtr.Zero) CloseHandle(t); }
  public static int Suspend(int pid, bool resume) {
    IntPtr p = OpenProcess(0x0800, false, pid); if (p == IntPtr.Zero) return -1;
    try { return resume ? NtResumeProcess(p) : NtSuspendProcess(p); } finally { CloseHandle(p); }
  }
}
"@
$liveRecorderSupported = $true; $liveRecorderError = $null
try {
    Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
    # -ReferencedAssemblies replaces the compiler's default reference set, and System.Collections.Concurrent /
    # System.Threading are then unresolvable (CS0234/CS1069). The recorder therefore uses only a plain array: UIA
    # delivers one handler's events serially on its callback thread, and the reader copies up to the published count.
    Add-Type -ReferencedAssemblies @([System.Windows.Automation.AutomationElement].Assembly.Location,
        [System.Windows.Automation.AutomationEvent].Assembly.Location) @"
using System; using System.Windows.Automation;
public sealed class ObsLiveRecorder {
  readonly string[] _names = new string[4096]; int _count;
  public string[] Snapshot() {
    int n = Math.Min(_count, _names.Length);
    var copy = new string[n]; for (int i = 0; i < n; i++) copy[i] = _names[i] ?? "";
    return copy;
  }
  AutomationElement _root; AutomationEventHandler _handler; AutomationEvent _ev;
  public static AutomationEvent LiveRegionEvent() {
    var f = typeof(AutomationElement).GetField("LiveRegionChangedEvent");
    var ev = f != null ? (AutomationEvent)f.GetValue(null) : AutomationEvent.LookupById(20024);
    if (ev == null) throw new NotSupportedException("AutomationElement.LiveRegionChangedEvent missing and LookupById(20024) returned null");
    return ev;
  }
  public void Attach(AutomationElement root) {
    _ev = LiveRegionEvent();
    _root = root; _handler = (s, e) => { try { var name = ((AutomationElement)s).Current.Name ?? ""; int i = _count; if (i < _names.Length) { _names[i] = name; _count = i + 1; } } catch { } };
    Automation.AddAutomationEventHandler(_ev, root, TreeScope.Subtree, _handler);
  }
  public void Detach() {
    try { if (_handler != null) Automation.RemoveAutomationEventHandler(_ev, _root, _handler); } catch { }
    _handler = null;
  }
}
"@
} catch { $liveRecorderSupported = $false; $liveRecorderError = "$($_.Exception.GetType().FullName): $($_.Exception.Message)" }
$AE = [System.Windows.Automation.AutomationElement]
$Scope = [System.Windows.Automation.TreeScope]

# ---------------------------------------------------------------------------------------------------------------
# Report helpers

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
function Get-Seconds($From, $To) { ([double] $To - [double] $From) / $freq }
function Wait-UntilQpc([double] $Qpc) {
    while ($true) {
        $left = ($Qpc - (Get-Qpc)) / $freq
        if ($left -le 0) { return }
        Start-Sleep -Milliseconds ([int] [Math]::Max(10, [Math]::Min(250, $left * 1000)))
    }
}
# Returns the first truthy probe value within $Seconds (or the last probe value).
function Wait-For([scriptblock] $Probe, [double] $Seconds, [int] $PollMs = 250) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        $value = & $Probe
        if ($value) { return $value }
        Start-Sleep -Milliseconds $PollMs
    }
    & $Probe
}
function ConvertTo-SafeName([string] $Name) { ($Name -replace '[^A-Za-z0-9-]', '-') }
function Round3($Value) { if ($null -eq $Value) { $null } else { [Math]::Round([double] $Value, 3) } }

# ---------------------------------------------------------------------------------------------------------------
# Roots, settings, launch

function New-Root([string] $Name) {
    $root = Join-Path $rootBase $Name
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $ubolDestination = Join-Path $root '.tools/ubol'
    [IO.Directory]::CreateDirectory($ubolDestination) | Out-Null
    Copy-Item -LiteralPath $ubolSource -Destination $ubolDestination -Recurse
    [IO.Directory]::CreateDirectory((Join-Path $root 'data/discord-bench')) | Out-Null
    $root
}

# Options: ObsOverlay, ObsHidePaused (default true), OmitObsKeys, SleepInBackground, DiscordPresence.
function Write-Settings([string] $Root, [hashtable] $Options = @{}) {
    $data = Join-Path $Root 'data'
    [IO.Directory]::CreateDirectory($data) | Out-Null
    $settings = [ordered]@{
        Version = 7; X = 100; Y = 100; Width = 1280; Height = 800; Dpi = 96; Maximized = $false; Zoom = 1.0
        TrayEnabled = $true; RestoreSection = $false; LastSection = 'home'; ReduceMotion = $false
        CompactX = 100; CompactY = 100; CompactWidth = 800; CompactHeight = 180; CompactDpi = 96
        SleepInBackground = [bool] $Options['SleepInBackground']; StartCompact = $false; AutoCheckUpdates = $false
        OutputVolume = 1.0; BlockAds = $false
        DiscordPresence = [bool] $Options['DiscordPresence']; DiscordStatusLine = 0; DiscordOpenButton = $true
    }
    if (-not $Options['OmitObsKeys']) {
        $settings['ObsOverlay'] = [bool] $Options['ObsOverlay']
        $settings['ObsHidePaused'] = if ($Options.ContainsKey('ObsHidePaused')) { [bool] $Options['ObsHidePaused'] } else { $true }
    }
    [IO.File]::WriteAllText((Join-Path $data 'settings.json'), ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
}
function Read-SavedSettings([string] $Root) { [IO.File]::ReadAllText((Join-Path $Root 'data/settings.json')) | ConvertFrom-Json }

$launchHelper = Join-Path $rootBase 'launch-helper.ps1'
[IO.File]::WriteAllText($launchHelper, @'
param([string] $SpecPath)
$ErrorActionPreference = 'Stop'
$spec = Get-Content -Raw -LiteralPath $SpecPath | ConvertFrom-Json
foreach ($name in @($spec.unset)) { if ($name) { [Environment]::SetEnvironmentVariable($name, $null, 'Process') } }
foreach ($p in $spec.env.PSObject.Properties) { [Environment]::SetEnvironmentVariable($p.Name, [string] $p.Value, 'Process') }
$proc = Start-Process -FilePath $spec.exe -ArgumentList @($spec.arguments) -WorkingDirectory $spec.workingDirectory -PassThru
$level = if (((whoami /groups) -join "`n") -match 'Mandatory Label\\(\w+(?: \w+)?) Mandatory Level') { $Matches[1] } else { 'unknown' }
[IO.File]::WriteAllText($spec.pidFile, (@{ processId = $proc.Id; helperIntegrity = $level } | ConvertTo-Json -Compress))
'@, [Text.UTF8Encoding]::new($false))

function Get-IntegrityName([int] $ProcessId) {
    $rid = [ObsE2E]::IntegrityRid($ProcessId)
    switch ($rid) { -1 { 'unknown' } 0x1000 { 'Low' } 0x2000 { 'Medium' } 0x2100 { 'MediumPlus' } 0x3000 { 'High' } 0x4000 { 'System' } default { "rid-$rid" } }
}

# True when BUILTIN\Administrators is enabled in the process token; false when it is absent or deny-only (what
# runas /trustlevel:0x20000 produces). $null when the token cannot be read.
function Get-AdminEnabled([int] $ProcessId) {
    $token = [ObsE2E]::OpenToken($ProcessId)
    if ($token -eq [IntPtr]::Zero) { return $null }
    try {
        $identity = [Security.Principal.WindowsIdentity]::new($token)
        try { [Security.Principal.WindowsPrincipal]::new($identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
        finally { $identity.Dispose() }
    } finally { [ObsE2E]::CloseToken($token) }
}

# Launches $Exe with the Basic-user token (runas /trustlevel:0x20000 -> launch helper), numbered like app launches so
# the per-scenario cleanup finds it through launch-<n>.pid.json. $Environment: name -> value ($null unsets).
function Invoke-RunasLaunch([string] $Exe, [string[]] $Arguments, [string] $WorkingDirectory, $Environment) {
    $spec = Join-Path $rootBase "launch-$($script:launchCount).json"
    $pidFile = Join-Path $rootBase "launch-$($script:launchCount).pid.json"
    $set = [ordered]@{}; $unset = @()
    foreach ($entry in $Environment.GetEnumerator()) { if ($null -eq $entry.Value) { $unset += $entry.Key } else { $set[$entry.Key] = $entry.Value } }
    $specJson = [ordered]@{ exe = $Exe; arguments = $Arguments; workingDirectory = $WorkingDirectory; env = $set; unset = $unset; pidFile = $pidFile }
    [IO.File]::WriteAllText($spec, ($specJson | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))
    & runas.exe '/trustlevel:0x20000' "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$launchHelper`" `"$spec`"" | Out-Null
    if (-not (Wait-For { Test-Path -LiteralPath $pidFile } 30)) { throw "runas /trustlevel launch helper wrote no PID file ($pidFile)." }
    $info = Get-Content -Raw -LiteralPath $pidFile | ConvertFrom-Json
    [pscustomobject]@{ Process = (Get-Process -Id ([int] $info.processId)); HelperIntegrity = $info.helperIntegrity }
}
# $Override: name -> value; $null removes the variable for this launch.
function Start-App([string] $Root, [hashtable] $Override = @{}, [string] $Exe = $appExe) {
    $environment = [ordered]@{}
    foreach ($entry in $testEnv.GetEnumerator()) { $environment[$entry.Key] = $entry.Value }
    foreach ($key in $benchEnvKeys) { $environment[$key] = $null }
    foreach ($entry in $Override.GetEnumerator()) { $environment[$entry.Key] = $entry.Value }
    $workingDirectory = Split-Path -Parent $Exe
    $arguments = @('web', '--root', $Root)
    $script:launchCount++
    $helperIntegrity = $null
    if ($isElevated) {
        $launched = Invoke-RunasLaunch $Exe $arguments $workingDirectory $environment
        $process = $launched.Process
        $helperIntegrity = $launched.HelperIntegrity
    } else {
        foreach ($entry in $environment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
        $process = Start-Process -FilePath $Exe -ArgumentList $arguments -WorkingDirectory $workingDirectory -PassThru
    }
    $started.Add($process)
    $integrity = Get-IntegrityName $process.Id
    $adminEnabled = Get-AdminEnabled $process.Id
    $launches.Add([ordered]@{ launch = $script:launchCount; root = [IO.Path]::GetRelativePath($repo, $Root); processId = $process.Id
        viaRunas = $isElevated; adminEnabled = $adminEnabled; integrity = $integrity; helperIntegrity = $helperIntegrity
        release = ($Exe -eq $releaseExe) })
    $process | Add-Member -NotePropertyName Integrity -NotePropertyValue $integrity -Force
    $process | Add-Member -NotePropertyName AdminEnabled -NotePropertyValue $adminEnabled -Force
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
# Requests diagnostics-<label>.json and state-<label>.json; returns { diag, state, overlay } or $null after 10 s.
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

function Stop-App($Process, [string] $Root, [switch] $Kill) {
    if (-not $Process) { return }
    if (-not $Process.HasExited) {
        if (-not $Kill) { try { [void] (Send-HookCommand $Root 'command-quit') } catch { } }
        if ($Kill -or -not $Process.WaitForExit(8000)) {
            foreach ($id in (Get-ProcessTree $Process.Id $Root)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        }
    }
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine)) {
        if ($p.CommandLine -and $p.CommandLine.Contains($Root, [StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
}
function Copy-AppLog([string] $Root, [string] $Name) {
    $log = Join-Path $Root 'data/nativune.log'
    if (Test-Path -LiteralPath $log) { Copy-Item -LiteralPath $log -Destination (Join-Path $runDirectory "nativune-$(ConvertTo-SafeName $Name).log") }
}
function Get-ObsLogLines([string] $Root) {
    $log = Join-Path $Root 'data/nativune.log'
    if (-not (Test-Path -LiteralPath $log)) { return @() }
    # AppLog lines read `<timestamp> [obs] <message>` (e.g. `2026-09-28 23:25:06.692 +08:00 [obs] bind PrefixInUse`).
    @(Get-Content -LiteralPath $log | Where-Object { $_ -match '\[obs\]' })
}

# Exact-prefix registration by this (other) process: plan §4.3 "proof of release".
function Test-PrefixRegistrable {
    $listener = [Net.HttpListener]::new()
    try { $listener.Prefixes.Add($overlayUrl); $listener.Start(); $true } catch { $false } finally { try { $listener.Close() } catch { } }
}
function Hold-Prefix {
    $listener = [Net.HttpListener]::new(); $listener.Prefixes.Add($overlayUrl); $listener.Start()
    $heldListeners.Add($listener); $listener
}
function Release-Prefix($Listener) { try { $Listener.Close() } catch { }; [void] $heldListeners.Remove($Listener) }

# Overlay-aware read counter (design §5 U6): reads started in (Start.boundaryQpc, End.boundaryQpc].
function Get-ReadStats($Start, $End) {
    $stats = [ordered]@{ total = 0; overlay = 0; presence = 0; compact = 0; seconds = $null; perSecond = $null }
    if (-not $Start -or -not $End) { return $stats }
    $s0 = [double] $Start.diag.boundaryQpc; $s1 = [double] $End.diag.boundaryQpc
    $stats.seconds = Round3 (($s1 - $s0) / $freq)
    foreach ($read in @(Get-Prop $End.diag 'reads')) {
        $q = [double] $read.startQpc
        if ($q -le $s0 -or $q -gt $s1) { continue }
        $stats.total++
        switch ([string] (Get-Prop $read 'mode')) { 'Overlay' { $stats.overlay++ } 'Presence' { $stats.presence++ } default { $stats.compact++ } }
    }
    if ($stats.seconds -gt 0) { $stats.perSecond = Round3 ($stats.total / $stats.seconds) }
    $stats
}
function Test-RatePerSecond($Count, $Seconds, [double] $Rate = 1.0, [double] $Tolerance = 0.2) {
    if (-not $Seconds -or $Seconds -le 0) { return $false }
    $r = [double] $Count / [double] $Seconds
    $r -ge ($Rate - $Tolerance) -and $r -le ($Rate + $Tolerance)
}
# Never two reads in flight: each completed read ends before the next starts; only the last may be incomplete.
function Test-NoOverlap($Snapshot) {
    $reads = @(@(Get-Prop (Get-Prop $Snapshot 'diag') 'reads') | Where-Object { $_ } | Sort-Object { [double] $_.startQpc })
    for ($i = 0; $i -lt $reads.Count - 1; $i++) {
        if (-not (Get-Prop $reads[$i] 'completed')) { return $false }
        if ([double] (Get-Prop $reads[$i] 'endQpc') -gt [double] $reads[$i + 1].startQpc) { return $false }
    }
    $reads.Count -gt 0
}

# ---------------------------------------------------------------------------------------------------------------
# SSE reader child process

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
        elseif ($line.StartsWith('retry:')) { Log 'retry' 'text' $line }
        elseif ($line -ne '') { Log 'other' 'text' $line }
    }
    Log 'close' 'text' 'eof'
} catch { Log 'close' 'text' $_.Exception.GetBaseException().Message }
'@

function Start-SseReader([string] $Name, [double] $ConnectSeconds = 120) {
    $safe = ConvertTo-SafeName $Name
    $out = Join-Path $runDirectory "events-$safe.jsonl"
    $command = "& { $sseReaderScript } -Url '$($overlayUrl)events' -Out '$($out -replace "'", "''")' -ConnectSeconds $ConnectSeconds"
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
# Only kind=data events with a parsed payload carrying a state; open/retry/comment/close/error/other never count.
function Get-DataEvents($Events) {
    $out = [Collections.Generic.List[object]]::new()
    foreach ($e in @($Events)) {
        if ($null -eq $e) { continue }
        if ($e -is [Array]) { foreach ($x in (Get-DataEvents $e)) { $out.Add($x) }; continue }
        if ([string] (Get-Prop $e 'kind') -ne 'data') { continue }
        $d = Get-Prop $e 'data'
        if ($null -eq $d -or $d -is [string] -or $null -eq (Get-Prop $d 'state')) { continue }
        $out.Add($e)
    }
    return $out.ToArray()
}
function Read-SseRaw($Reader) {
    if (-not (Test-Path -LiteralPath $Reader.Path)) { return '' }
    $fs = [IO.FileStream]::new($Reader.Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try { [IO.StreamReader]::new($fs).ReadToEnd() } finally { $fs.Dispose() }
}
function Stop-SseReader($Reader) {
    if (-not $Reader -or $Reader.Stopped) { return }
    $Reader.Stopped = $true
    try { if (-not $Reader.Process.HasExited) { [void] [ObsE2E]::Suspend($Reader.Process.Id, $true); Stop-Process -Id $Reader.Process.Id -Force -ErrorAction SilentlyContinue; [void] $Reader.Process.WaitForExit(5000) } } catch { }
    $eventsByReader[$Reader.Name] = @(@(Read-Sse $Reader) | Where-Object { $null -ne $_ } | ForEach-Object { [ordered]@{ qpc = $_.qpc; kind = $_.kind; text = $_.text; json = $_.json } })
}
function Wait-SseOpen($Reader, [double] $Seconds = 30) {
    Wait-For { @(@(Read-Sse $Reader) | Where-Object { $null -ne $_ -and $_.kind -eq 'open' }) | Select-Object -First 1 } $Seconds
}
function Wait-SseData($Reader, [scriptblock] $Predicate, [double] $Seconds, [double] $AfterQpc = 0) {
    Wait-For { Get-DataEvents (Read-Sse $Reader) | Where-Object { $null -ne $_ -and $_.qpc -gt $AfterQpc -and (& $Predicate $_.data) } | Select-Object -First 1 } $Seconds
}
function Test-Data($D, [string] $State, [string] $Id = $null) { (Get-Prop $D 'state') -eq $State -and (-not $Id -or (Get-Prop $D 'id') -eq $Id) }
# Page time: the playing fixture track starts at 0 at page load, so load ~= receipt - ageMs - position.
function Get-PageStartQpc($Initial) {
    [double] $Initial.qpc - (([double] (Get-Prop $Initial.data 'ageMs')) / 1000 + [double] (Get-Prop $Initial.data 'position')) * $freq
}
function Get-PageTime([double] $Qpc, [double] $Start) { Round3 (($Qpc - $Start) / $freq) }
function Get-EventSummary($Ev, [double] $Start = 0) {
    $d = $Ev.data
    [ordered]@{ pageTime = if ($Start) { Get-PageTime $Ev.qpc $Start } else { $null }; state = Get-Prop $d 'state'; id = Get-Prop $d 'id'
        position = Get-Prop $d 'position'; clock = Get-Prop $d 'clock'; artwork = Get-Prop $d 'artwork'; hidePaused = Get-Prop $d 'hidePaused'; ageMs = Get-Prop $d 'ageMs' }
}
$semanticFields = @('state', 'id', 'title', 'artist', 'artwork', 'duration', 'rate')
function Get-SemanticKey($D) { ($semanticFields | ForEach-Object { "$(Get-Prop $D $_)" }) -join [char] 1 }

# ---------------------------------------------------------------------------------------------------------------
# Raw HTTP (TcpClient)

function New-Request([string] $Method = 'GET', [string] $Path = '/', [string] $HostHeader = "localhost:$port", [string[]] $Extra = @(), [switch] $KeepAlive) {
    $lines = @("$Method $Path HTTP/1.1")
    if ($HostHeader) { $lines += "Host: $HostHeader" }
    $lines += $Extra
    if (-not $KeepAlive) { $lines += 'Connection: close' }
    ($lines -join "`r`n") + "`r`n`r`n"
}
function ConvertFrom-RawResponse([byte[]] $Bytes) {
    $text = [Text.Encoding]::UTF8.GetString($Bytes)
    $split = $text.IndexOf("`r`n`r`n")
    $head = if ($split -ge 0) { $text.Substring(0, $split) } else { $text }
    $lines = @($head -split "`r`n")
    $status = if ($lines.Count -gt 0 -and $lines[0] -match '^HTTP/\d\.\d (\d{3})') { [int] $Matches[1] } else { $null }
    $headers = [ordered]@{}
    foreach ($l in ($lines | Select-Object -Skip 1)) {
        $i = $l.IndexOf(':'); if ($i -le 0) { continue }
        $k = $l.Substring(0, $i).Trim().ToLowerInvariant(); $v = $l.Substring($i + 1).Trim()
        if ($headers.Contains($k)) { $headers[$k] = $headers[$k] + ', ' + $v } else { $headers[$k] = $v }
    }
    [ordered]@{ status = $status; headers = $headers; body = if ($split -ge 0) { $text.Substring($split + 4) } else { '' } }
}
function Invoke-RawHttp([string] $Address, [string] $Request, [byte[]] $Body = $null, [int] $IdleMs = 1500, [int] $MaxBytes = 262144) {
    $result = [ordered]@{ address = $Address; connected = $false; status = $null; origin = 'none'; headers = [ordered]@{}; body = ''; error = $null }
    $ip = [Net.IPAddress]::Parse($Address)
    $client = [Net.Sockets.TcpClient]::new($ip.AddressFamily)
    try {
        if (-not $client.ConnectAsync($ip, $port).Wait(3000)) { $result.error = 'connect-timeout'; return [pscustomobject] $result }
        $result.connected = $true
        $stream = $client.GetStream(); $stream.ReadTimeout = $IdleMs
        $bytes = [Text.Encoding]::ASCII.GetBytes($Request)
        $stream.Write($bytes, 0, $bytes.Length)
        if ($Body) { $stream.Write($Body, 0, $Body.Length) }
        $stream.Flush()
        $ms = [IO.MemoryStream]::new(); $buf = [byte[]]::new(16384)
        while ($ms.Length -lt $MaxBytes) {
            $n = try { $stream.Read($buf, 0, $buf.Length) } catch { -1 }
            if ($n -le 0) { break }
            $ms.Write($buf, 0, $n)
        }
        $parsed = ConvertFrom-RawResponse $ms.ToArray()
        $result.status = $parsed.status; $result.headers = $parsed.headers; $result.body = $parsed.body
    } catch { $result.error = $_.Exception.GetBaseException().Message } finally { $client.Dispose() }
    # App responses always carry nosniff; HTTP.sys kernel responses (400/503/404 for unknown groups) do not.
    $result.origin = if ($null -eq $result.status) { 'none' } elseif ($result.headers.Contains('x-content-type-options')) { 'app' } else { 'kernel' }
    [pscustomobject] $result
}
# Opens /events and returns after the status line; -NoRead keeps a tiny receive window and never reads again.
function Open-RawStream([string] $Address = '127.0.0.1', [switch] $NoRead) {
    $ip = [Net.IPAddress]::Parse($Address)
    $client = [Net.Sockets.TcpClient]::new($ip.AddressFamily)
    if ($NoRead) { $client.ReceiveBufferSize = 1024 }
    $openQpc = Get-Qpc
    $client.ConnectAsync($ip, $port).Wait(3000) | Out-Null
    $stream = $client.GetStream(); $stream.ReadTimeout = 3000
    $bytes = [Text.Encoding]::ASCII.GetBytes((New-Request -Path '/events' -KeepAlive))
    $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
    $ms = [IO.MemoryStream]::new(); $buf = [byte[]]::new(512)
    while ($true) {
        $n = try { $stream.Read($buf, 0, $buf.Length) } catch { -1 }
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        if ([Text.Encoding]::ASCII.GetString($ms.ToArray()).Contains("`r`n`r`n")) { break }
    }
    $parsed = ConvertFrom-RawResponse $ms.ToArray()
    [pscustomobject]@{ Client = $client; Status = $parsed.status; Headers = $parsed.headers; OpenQpc = $openQpc }
}
function Close-RawStream($Raw) { if ($Raw) { try { $Raw.Client.Close() } catch { } } }

# ---------------------------------------------------------------------------------------------------------------
# Chrome over CDP

$chromeProbeJs = @'
(() => {
  const s = window.__state ? Object.assign({}, window.__state) : null;
  const pill = document.getElementById('pill'), clip = document.getElementById('clip');
  const t = document.getElementById('title'), a = document.getElementById('artist');
  let frac = null;
  if (clip) { const m = new DOMMatrixReadOnly(getComputedStyle(clip).transform); frac = m.m41 / (clip.offsetWidth || 400); }
  const anims = document.getAnimations().map(x => x.playState);
  return JSON.stringify({
    href: location.href, s, opacity: pill ? Number(getComputedStyle(pill).opacity) : null, frac,
    title: t ? t.textContent : null, artist: a ? a.textContent : null, titleChildren: t ? t.children.length : null,
    titleEllipsis: t ? (getComputedStyle(t).textOverflow === 'ellipsis' && t.scrollWidth > t.clientWidth) : null,
    running: anims.filter(p => p === 'running').length, animations: anims.length,
    art: performance.getEntriesByType('resource').filter(e => e.name.includes('/fixture-art/'))
      .map(e => ({ name: new URL(e.name).pathname, start: e.startTime, end: e.responseEnd }))
  });
})()
'@

function Start-Chrome([string] $Name) {
    $dir = Join-Path $rootBase "chrome-$(ConvertTo-SafeName $Name)"
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $process = Start-Process -FilePath $chromeExe -PassThru -ArgumentList @('--headless=new', '--remote-debugging-port=0', "--user-data-dir=$dir",
        '--no-first-run', '--no-default-browser-check', '--disable-extensions', '--disable-background-networking', '--window-size=440,96', 'about:blank')
    $portFile = Join-Path $dir 'DevToolsActivePort'
    if (-not (Wait-For { Test-Path -LiteralPath $portFile } 30)) { throw 'Chrome wrote no DevToolsActivePort.' }
    $cdpPort = [int] ((Get-Content -LiteralPath $portFile | Select-Object -First 1).Trim())
    $page = Wait-For { Invoke-RestMethod -NoProxy -Uri "http://127.0.0.1:$cdpPort/json/list" | ForEach-Object { $_ } | Where-Object { $null -ne $_ -and $_.type -eq 'page' } | Select-Object -First 1 } 15
    $ws = [Net.WebSockets.ClientWebSocket]::new()
    # GetResult() on a non-generic Task surfaces a VoidTaskResult in PowerShell; it must not leak into the output.
    [void] $ws.ConnectAsync([Uri] $page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $chrome = [pscustomobject]@{ Name = $Name; Process = $process; Ws = $ws; Next = 0; Dir = $dir }
    [void] $chromes.Add($chrome)
    [void] (Invoke-Cdp $chrome 'Page.enable')
    return $chrome
}
# Accepts the Start-Chrome object even if a caller received it wrapped in an array with stray pipeline values.
function Resolve-Chrome($Chrome) {
    $c = @($Chrome) | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Ws'] -and $_.PSObject.Properties['Next'] } | Select-Object -Last 1
    if (-not $c) { throw 'Invoke-Cdp: no Chrome session object (Start-Chrome result) was passed.' }
    $c
}
function Invoke-Cdp($Chrome, [string] $Method, [hashtable] $Params = @{}, [double] $TimeoutSeconds = 20) {
    $Chrome = Resolve-Chrome $Chrome
    $Chrome.Next++
    $id = $Chrome.Next
    $bytes = [Text.Encoding]::UTF8.GetBytes((@{ id = $id; method = $Method; params = $Params } | ConvertTo-Json -Compress -Depth 8))
    [void] $Chrome.Ws.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $cts = [Threading.CancellationTokenSource]::new([TimeSpan]::FromSeconds($TimeoutSeconds))
    $buf = [byte[]]::new(1MB)
    while ($true) {
        $ms = [IO.MemoryStream]::new()
        do {
            $r = $Chrome.Ws.ReceiveAsync([ArraySegment[byte]]::new($buf), $cts.Token).GetAwaiter().GetResult()
            $ms.Write($buf, 0, $r.Count)
        } while (-not $r.EndOfMessage)
        $message = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json -Depth 32
        if ((Get-Prop $message 'id') -eq $id) {
            $err = Get-Prop $message 'error'
            if ($err) { throw "CDP $Method failed: $(Get-Prop $err 'message')" }
            return (Get-Prop $message 'result')
        }
    }
}
function Invoke-ChromeNavigate($Chrome, [string] $Url) { Invoke-Cdp $Chrome 'Page.navigate' @{ url = $Url } }
function Get-PageProbe($Chrome) {
    $result = Invoke-Cdp $Chrome 'Runtime.evaluate' @{ expression = $chromeProbeJs; returnByValue = $true }
    $value = Get-Prop (Get-Prop $result 'result') 'value'
    $probe = if ($value) { $value | ConvertFrom-Json -Depth 8 } else { [pscustomobject]@{ href = $null; s = $null; opacity = $null; frac = $null; title = $null; artist = $null; titleChildren = $null; titleEllipsis = $null; running = $null; animations = $null; art = @() } }
    $probe | Add-Member -NotePropertyName qpc -NotePropertyValue (Get-Qpc) -Force
    $probe
}
function Get-PageField($Probe, [string] $Field) { Get-Prop (Get-Prop $Probe 's') $Field }
function Save-ChromeShot($Chrome, [string] $Name) {
    try {
        $shot = Invoke-Cdp $Chrome 'Page.captureScreenshot' @{ format = 'png' }
        $file = Join-Path $shotDirectory "$(ConvertTo-SafeName $Name).png"
        [IO.File]::WriteAllBytes($file, [Convert]::FromBase64String($shot.data))
        [IO.Path]::GetRelativePath($runDirectory, $file)
    } catch { $null }
}
# Kills every chrome.exe whose command line carries this instance's --user-data-dir, plus the launched
# process tree. Never throws.
function Stop-Chrome($Chrome) {
    try {
        if ($null -eq $Chrome) { return }
        try { $ws = Get-Prop $Chrome 'Ws'; if ($ws) { $ws.Dispose() } } catch { }
        $dir = [string] (Get-Prop $Chrome 'Dir')
        $proc = Get-Prop $Chrome 'Process'
        $rootId = try { if ($proc) { [int] $proc.Id } else { 0 } } catch { 0 }
        for ($pass = 0; $pass -lt 3; $pass++) {
            $all = @(try { Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine -ErrorAction Stop } catch { })
            $ids = [Collections.Generic.HashSet[int]]::new()
            if ($rootId) { [void] $ids.Add($rootId) }
            foreach ($p in $all) {
                if ($p.Name -eq 'chrome.exe' -and $dir -and $p.CommandLine -and $p.CommandLine.Contains($dir, [StringComparison]::OrdinalIgnoreCase)) { [void] $ids.Add([int] $p.ProcessId) }
            }
            do {
                $added = $false
                foreach ($p in $all) { if ($p.Name -eq 'chrome.exe' -and $ids.Contains([int] $p.ParentProcessId) -and $ids.Add([int] $p.ProcessId)) { $added = $true } }
            } while ($added)
            $live = @($ids | Where-Object { $id = $_; $all | Where-Object { [int] $_.ProcessId -eq $id } })
            if ($live.Count -eq 0) { break }
            foreach ($id in $live) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 300
        }
    } catch { }
}
function Test-ChromeAvailable([string] $ScenarioId) {
    if (Test-Path -LiteralPath $chromeExe -PathType Leaf) { return $true }
    Add-Blocked "$ScenarioId.chromeAvailable" "Google Chrome at $chromeExe" 'Chrome is not installed; page checks cannot run'
    $false
}

# ---------------------------------------------------------------------------------------------------------------
# UI Automation (pattern of scripts/discord-settings-shots.ps1)

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
function Invoke-Element($El) { (Get-Pattern $El ([System.Windows.Automation.InvokePattern])).Invoke() }
function Get-ToggleState($El) { (Get-Pattern $El ([System.Windows.Automation.TogglePattern])).Current.ToggleState.ToString() }
function Set-Toggle($El, [bool] $On) {
    $pattern = Get-Pattern $El ([System.Windows.Automation.TogglePattern])
    $want = if ($On) { [System.Windows.Automation.ToggleState]::On } else { [System.Windows.Automation.ToggleState]::Off }
    if ($pattern.Current.ToggleState -ne $want) { $pattern.Toggle() }
}
function Find-MenuItem([int] $ProcessId, [string] $Like) {
    $pidCond = New-Object System.Windows.Automation.PropertyCondition ($AE::ProcessIdProperty), $ProcessId
    foreach ($el in $AE::RootElement.FindAll($Scope::Children, $pidCond)) {
        $items = $el.FindAll($Scope::Descendants, [System.Windows.Automation.PropertyCondition]::new($AE::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem))
        foreach ($m in $items) { if ($m.Current.Name -like $Like) { return $m } }
    }
}
function Find-NameLike([int] $ProcessId, [string] $Like) {
    $pidCond = New-Object System.Windows.Automation.PropertyCondition ($AE::ProcessIdProperty), $ProcessId
    foreach ($el in $AE::RootElement.FindAll($Scope::Children, $pidCond)) {
        foreach ($d in $el.FindAll($Scope::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
            if ($d.Current.Name -like $Like) { return $d.Current.Name }
        }
    }
    $null
}
function Describe($El) {
    if (-not $El) { return $null }
    $c = $El.Current
    [ordered]@{ AutomationId = $c.AutomationId; Name = $c.Name; HelpText = $c.HelpText; ControlType = $c.ControlType.ProgrammaticName
        IsEnabled = $c.IsEnabled; IsKeyboardFocusable = $c.IsKeyboardFocusable }
}
function Save-WindowShot([IntPtr] $Hwnd, [string] $Name) {
    try {
        $wr = New-Object ObsE2E+RECT; [void] [ObsE2E]::GetWindowRect($Hwnd, [ref] $wr)
        $bmp = New-Object System.Drawing.Bitmap ($wr.Right - $wr.Left), ($wr.Bottom - $wr.Top)
        $g = [System.Drawing.Graphics]::FromImage($bmp); $hdc = $g.GetHdc()
        [void] [ObsE2E]::PrintWindow($Hwnd, $hdc, 2); $g.ReleaseHdc($hdc); $g.Dispose()
        $fr = New-Object ObsE2E+RECT; [void] [ObsE2E]::DwmGetWindowAttribute($Hwnd, 9, [ref] $fr, 16)
        $crop = New-Object System.Drawing.Rectangle ($fr.Left - $wr.Left), ($fr.Top - $wr.Top), ($fr.Right - $fr.Left), ($fr.Bottom - $fr.Top)
        $out = $bmp.Clone($crop, $bmp.PixelFormat); $bmp.Dispose()
        $file = Join-Path $shotDirectory "$(ConvertTo-SafeName $Name).png"; $out.Save($file, [System.Drawing.Imaging.ImageFormat]::Png); $out.Dispose()
        [IO.Path]::GetRelativePath($runDirectory, $file)
    } catch { $null }
}
function Open-ObsSettings($Process) {
    $mainHwnd = Wait-For { $h = [ObsE2E]::Find([uint32] $Process.Id, $null); if ($h -ne [IntPtr]::Zero) { $h } } 60 300
    if (-not $mainHwnd -or $mainHwnd -eq [IntPtr]::Zero) { throw 'Main window not found.' }
    $main = $AE::FromHandle($mainHwnd)
    $more = Find-Element $main 'AutomationId' 'MoreButton' 30
    if (-not $more) { $more = Find-Element $main 'Name' 'More commands and settings' 5 }
    if (-not $more) { throw 'More button not found.' }
    Invoke-Element $more
    $item = Wait-For { Find-MenuItem $Process.Id 'Settings*' } 15 300
    if (-not $item) { throw 'Settings menu item not found.' }
    Invoke-Element $item
    $hwnd = Wait-For { $h = [ObsE2E]::Find([uint32] $Process.Id, 'Settings'); if ($h -ne [IntPtr]::Zero) { $h } } 30 300
    if (-not $hwnd -or $hwnd -eq [IntPtr]::Zero) { throw 'Settings window not found.' }
    $dlg = $AE::FromHandle($hwnd)
    $nav = Find-Element $dlg 'AutomationId' 'ObsNavItem' 15
    if (-not $nav) { throw 'ObsNavItem not found.' }
    (Get-Pattern $nav ([System.Windows.Automation.SelectionItemPattern])).Select()
    Start-Sleep -Milliseconds 1000
    [pscustomobject]@{ MainHwnd = $mainHwnd; Hwnd = $hwnd; Dlg = $dlg; Nav = $nav; ProcessId = $Process.Id }
}
# Reads the main window's application status the way a UIA user does: WebHost.SetStatus(text, isError) renames
# MoreButton ("... Application status reports an error.") and keeps the text for More > "Application status (error)",
# whose dialog shows it in the read-only "Current application status" box. Waits up to $Seconds for the error
# (async settings saves fail after Save returns). Returns @{ moreName; text } (text $null when never seen).
function Get-AppStatusText($Process, [string] $Like, [double] $Seconds = 30) {
    $mainHwnd = Wait-For { $h = [ObsE2E]::Find([uint32] $Process.Id, $null); if ($h -ne [IntPtr]::Zero) { $h } } 30 300
    if (-not $mainHwnd -or $mainHwnd -eq [IntPtr]::Zero) { throw 'Main window not found.' }
    $main = $AE::FromHandle($mainHwnd)
    $more = Find-Element $main 'AutomationId' 'MoreButton' 15
    if (-not $more) { throw 'More button not found.' }
    $moreName = Wait-For { $n = $more.Current.Name; if ($n -like '*reports an error*') { $n } } $Seconds 250
    $text = $null
    $deadline = [DateTime]::UtcNow.AddSeconds([Math]::Max(10, $Seconds / 2))
    while (-not $text -and [DateTime]::UtcNow -lt $deadline) {
        Invoke-Element $more
        $item = Wait-For { Find-MenuItem $Process.Id 'Application status*' } 10 300
        if (-not $item) { throw 'Application status menu item not found.' }
        Invoke-Element $item
        $box = Wait-For {
            $pidCond = New-Object System.Windows.Automation.PropertyCondition ($AE::ProcessIdProperty), $Process.Id
            $nameCond = New-Object System.Windows.Automation.PropertyCondition ($AE::NameProperty), 'Current application status'
            foreach ($w in $AE::RootElement.FindAll($Scope::Children, $pidCond)) { $b = $w.FindFirst($Scope::Descendants, $nameCond); if ($b) { $b; break } }
        } 15 300
        if (-not $box) { throw 'Current application status box not found.' }
        $value = try { (Get-Pattern $box ([System.Windows.Automation.ValuePattern])).Current.Value } catch { $null }
        $dialog = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($box)
        while ($dialog -and $dialog.Current.ControlType -ne [System.Windows.Automation.ControlType]::Window) { $dialog = [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($dialog) }
        $close = if ($dialog) { Find-Element $dialog 'Name' 'Close application status' 5 }
        if ($close) { Invoke-Element $close; Start-Sleep -Milliseconds 500 }
        if ("$value" -like $Like) { $text = "$value" } else { Start-Sleep -Seconds 1 }
    }
    [ordered]@{ moreName = $moreName; text = $text }
}
function Close-Settings($Settings, [string] $Button) {
    $el = Find-Element $Settings.Dlg 'AutomationId' $Button 5
    if (-not $el) { throw "$Button not found." }
    Invoke-Element $el
    [void] (Wait-For { [ObsE2E]::Find([uint32] $Settings.ProcessId, 'Settings') -eq [IntPtr]::Zero } 10 300)
    Start-Sleep -Milliseconds 800
}
function Get-ObsControl($Settings, [string] $Id) { Find-Element $Settings.Dlg 'AutomationId' $Id 10 }

# ---------------------------------------------------------------------------------------------------------------
# Discord fake server (A-DEMAND)

# When the harness is elevated the app runs with the Basic-user token; a pipe created by an elevated server gets a
# default DACL the app cannot open (app log: `discord: status DiscordAbsent`). So the server is launched through the
# same runas helper (same token) and keeps its files under this run's root, where that token can write.
function Start-FakeServer([string] $Name) {
    $dir = Join-Path $rootBase "discord-$(ConvertTo-SafeName $Name)"
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $frames = Join-Path $dir 'frames.jsonl'
    $stop = Join-Path $dir 'stop'
    $ready = Join-Path $dir 'ready.json'
    $serverScript = Join-Path $repo 'scripts/discord-rpc-test-server.ps1'
    $arguments = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', $serverScript,
        '-PipeName', ($prefix + '0'), '-FramesPath', $frames, '-StopFile', $stop, '-Mode', 'Normal', '-ReadyFile', $ready)
    $integrity = $null; $adminEnabled = $null
    if ($isElevated) {
        $script:launchCount++
        $pwshExe = 'pwsh.exe'
        $launched = Invoke-RunasLaunch $pwshExe $arguments $repo ([ordered]@{})
        $process = $launched.Process
        $integrity = Get-IntegrityName $process.Id; $adminEnabled = Get-AdminEnabled $process.Id
    } else {
        $process = Start-Process -FilePath pwsh -ArgumentList $arguments -PassThru -WindowStyle Hidden
    }
    $started.Add($process)
    if (-not (Wait-For { Test-Path -LiteralPath $ready } 20)) { throw "Fake Discord server '$Name' did not become ready within 20 s." }
    [pscustomobject]@{ Name = $Name; Process = $process; Frames = $frames; Stop = $stop; ViaRunas = $isElevated; Integrity = $integrity; AdminEnabled = $adminEnabled }
}
function Stop-FakeServer($Server) {
    if (-not $Server) { return }
    try { [IO.File]::WriteAllText($Server.Stop, 'stop') } catch { }
    if (-not $Server.Process.WaitForExit(5000)) { Stop-Process -Id $Server.Process.Id -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $Server.Frames) { Copy-Item -LiteralPath $Server.Frames -Destination (Join-Path $runDirectory "frames-$(ConvertTo-SafeName $Server.Name).jsonl") -Force }
}
# Qpc of the first READY dispatch the fake server sent (the app completed the IPC handshake), else $null.
function Get-FakeServerReadyQpc($Server) {
    if (-not (Test-Path -LiteralPath $Server.Frames)) { return $null }
    $fs = [IO.FileStream]::new($Server.Frames, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $lines = try { [IO.StreamReader]::new($fs).ReadToEnd() -split "`n" } finally { $fs.Dispose() }
    foreach ($line in $lines) {
        if (-not $line.Trim()) { continue }
        $f = try { $line | ConvertFrom-Json -Depth 32 } catch { $null }
        if ((Get-Prop $f 'direction') -ne 'out') { continue }
        $m = try { (Get-Prop $f 'json') | ConvertFrom-Json -Depth 32 } catch { $null }
        if ((Get-Prop $m 'evt') -eq 'READY') { return [double] (Get-Prop $f 'qpc') }
    }
    $null
}
function Get-NonNullSets($Server) {
    if (-not (Test-Path -LiteralPath $Server.Frames)) { return @() }
    @(Get-Content -LiteralPath $Server.Frames | Where-Object { $_ } | ForEach-Object { $_ | ConvertFrom-Json -Depth 32 } | Where-Object {
        $_.direction -eq 'in' -and $_.opcode -eq 1 } | ForEach-Object {
        $m = try { $_.json | ConvertFrom-Json -Depth 32 } catch { $null }
        if ((Get-Prop $m 'cmd') -eq 'SET_ACTIVITY' -and $null -ne (Get-Prop (Get-Prop $m 'args') 'activity')) { [double] $_.monoMs } })
}

# ---------------------------------------------------------------------------------------------------------------
# Scenario helpers

# Starts the app with the overlay on (plus options) and an SSE reader; returns the context.
function Start-OverlayRun([string] $Name, [hashtable] $Settings = @{}, [string] $BenchProfile = $null, [string] $BenchState = 'Full',
    [switch] $NoReader, [hashtable] $Override = @{}) {
    $root = New-Root $Name
    $s = @{ ObsOverlay = $true }; foreach ($k in $Settings.Keys) { $s[$k] = $Settings[$k] }
    Write-Settings $root $s
    $launchEnv = @{}; foreach ($k in $Override.Keys) { $launchEnv[$k] = $Override[$k] }
    if ($BenchProfile) { $launchEnv['NATIVUNE_TEST_DISCORD_BENCH_PROFILE'] = $BenchProfile; $launchEnv['NATIVUNE_TEST_DISCORD_BENCH_STATE'] = $BenchState }
    $app = Start-App $root $launchEnv
    $reader = if ($NoReader) { $null } else { Start-SseReader $Name }
    [pscustomobject]@{ Name = $Name; Root = $root; App = $app; Reader = $reader }
}
function Stop-OverlayRun($Run) {
    if (-not $Run) { return }
    Stop-SseReader $Run.Reader
    Stop-App $Run.App $Run.Root
    Copy-AppLog $Run.Root $Run.Name
}
function Wait-Initial($Run, [string] $Id = 'fixtureSngA', [string] $State = 'playing', [double] $Seconds = 120) {
    $ev = Wait-SseData $Run.Reader { param($d) Test-Data $d $State $Id } $Seconds
    if (-not $ev) { throw "$($Run.Name): no initial $State $Id event within $Seconds s." }
    $ev
}
function Get-ReadyQpc($Ready) { if ($Ready) { [double] (Get-Prop $Ready 'qpc') } else { $null } }

# ---------------------------------------------------------------------------------------------------------------
# A-OFF

function Test-AOff {
    $variants = @(
        @{ n = 'nokey'; s = @{ OmitObsKeys = $true } },
        @{ n = 'false'; s = @{ ObsOverlay = $false } },
        @{ n = 'trueThenOff'; s = @{ ObsOverlay = $true } })
    $results = [ordered]@{}
    foreach ($v in $variants) {
        $n = $v.n; $root = New-Root "A-OFF/$n"; Write-Settings $root $v.s
        $app = $null
        try {
            $app = Start-App $root @{ NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'Playing'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
            $ready = Wait-BenchReady $root
            Add-Check "A-OFF.$n.benchReady" 'ready.json' ([bool] $ready) ([bool] $ready)
            if ($n -eq 'trueThenOff') {
                $on = Wait-For { $s = Get-State $root 'on'; if ((Get-Overlay $s 'running') -eq $true) { $s } } 20 500
                Add-Check "A-OFF.$n.runningBeforeOff" 'overlay.running true before command-obs-off' (Get-Overlay $on 'running') ((Get-Overlay $on 'running') -eq $true)
                [void] (Send-HookCommand $root 'command-obs-off')
                [void] (Wait-For { $s = Get-State $root 'off'; (Get-Overlay $s 'running') -eq $false } 10 500)
            }
            Start-Sleep -Seconds 8
            [void] (Get-State $root 'w0')
            Start-Sleep -Seconds 10
            $s1 = Get-State $root 'w1'
            $registrable = Test-PrefixRegistrable
            $probe = Invoke-RawHttp '127.0.0.1' (New-Request)
            $overlayReads = @(@(Get-Prop $s1.diag 'reads') | Where-Object { $_ -and (Get-Prop $_ 'mode') -eq 'Overlay' }).Count
            Add-Check "A-OFF.$n.prefixRegistrable" 'another process registers http://localhost:47813/' $registrable $registrable
            Add-Check "A-OFF.$n.noAppResponse" 'no app response on :47813 (refused or kernel outcome)' ([ordered]@{ origin = $probe.origin; status = $probe.status; error = $probe.error }) ($probe.origin -ne 'app')
            Add-Check "A-OFF.$n.streams0" 'overlay.streams 0 and running false' ([ordered]@{ streams = Get-Overlay $s1 'streams'; running = Get-Overlay $s1 'running' }) (
                (Get-Overlay $s1 'streams') -eq 0 -and (Get-Overlay $s1 'running') -ne $true)
            Add-Check "A-OFF.$n.noOverlayReads" 'no read with mode Overlay' $overlayReads ($null -ne $s1 -and $overlayReads -eq 0)
            $results[$n] = [ordered]@{ integrity = $app.Integrity; enabled = Get-Overlay $s1 'enabled'; demand = Get-Overlay $s1 'demand' }
        } finally { Stop-App $app $root; Copy-AppLog $root "A-OFF-$n" }
    }
    $scenarioResults['A-OFF'] = $results
}

# ---------------------------------------------------------------------------------------------------------------
# A-TIME

function Invoke-TimelineRun([string] $Name, [bool] $HidePaused, [string] $BenchProfile = $null) {
    $run = Start-OverlayRun $Name @{ ObsHidePaused = $HidePaused } $BenchProfile
    try {
        $initial = Wait-Initial $run
        $start = Get-PageStartQpc $initial
        Wait-UntilQpc ($start + 143 * $freq)
        $alive = -not $run.App.HasExited
    } finally { Stop-OverlayRun $run }
    [pscustomobject]@{ Run = $run; Events = @(Read-Sse $run.Reader); Raw = (Read-SseRaw $run.Reader); Start = $start; Initial = $initial; Alive = $alive }
}

$timelineSteps = @(
    @{ name = 'seekAnchor'; at = 25; test = { param($d) (Test-Data $d 'playing' 'fixtureSngA') -and [Math]::Abs([double] (Get-Prop $d 'position') - 100) -le 1.5 } },
    @{ name = 'paused'; at = 45; test = { param($d) Test-Data $d 'paused' 'fixtureSngA' } },
    @{ name = 'resumed'; at = 60; test = { param($d) Test-Data $d 'playing' 'fixtureSngA' } },
    @{ name = 'ad'; at = 65; test = { param($d) (Get-Prop $d 'state') -eq 'ad' } },
    @{ name = 'adRestore'; at = 75; test = { param($d) Test-Data $d 'playing' 'fixtureSngA' } },
    @{ name = 'trackB'; at = 80; test = { param($d) Test-Data $d 'playing' 'fixtureSngB' } },
    @{ name = 'ended'; at = 120; test = { param($d) (Get-Prop $d 'state') -eq 'ended' } },
    @{ name = 'trackCNoArt'; at = 125; test = { param($d) (Test-Data $d 'playing' 'fixtureSngC') -and $null -eq (Get-Prop $d 'artwork') } },
    @{ name = 'trackCArt'; at = 137; test = { param($d) (Test-Data $d 'playing' 'fixtureSngC') -and $null -ne (Get-Prop $d 'artwork') } })

# Plan §4.2 drift rule: same id and state as the previous event and |position - projection| > 1.5 s, where
# projection = prev.position + elapsed * rate over the page-sample times (qpc receipt minus ageMs). Returns the
# evidence when $Ev is such a re-anchor, else $null. A paused projection does not advance.
function Get-DriftCorrection($Ev, $PrevEv, [double] $Start = 0) {
    if (-not $PrevEv) { return $null }
    $d = $Ev.data; $p = $PrevEv.data
    if ((Get-SemanticKey $d) -ne (Get-SemanticKey $p)) { return $null }
    if ((Get-Prop $d 'state') -notin @('playing', 'paused')) { return $null }
    $pos = Get-Prop $d 'position'; $prevPos = Get-Prop $p 'position'
    if ($null -eq $pos -or $null -eq $prevPos) { return $null }
    $sampleQpc = { param($e) [double] $e.qpc - ([double] (Get-Prop $e.data 'ageMs')) / 1000 * $freq }
    $elapsed = Get-Seconds (& $sampleQpc $PrevEv) (& $sampleQpc $Ev)
    $rate = if ((Get-Prop $p 'state') -eq 'playing') { $r = Get-Prop $p 'rate'; if ($null -eq $r) { 1.0 } else { [double] $r } } else { 0.0 }
    $projection = [double] $prevPos + $elapsed * $rate
    $delta = [double] $pos - $projection
    if ([Math]::Abs($delta) -le 1.5) { return $null }
    [ordered]@{ pageTime = if ($Start) { Get-PageTime $Ev.qpc $Start } else { $null }; state = Get-Prop $d 'state'; id = Get-Prop $d 'id'
        position = $pos; previousPosition = $prevPos; elapsedSeconds = Round3 $elapsed; rate = $rate; projection = Round3 $projection; delta = Round3 $delta }
}

# Scores the semantic sequence. Returns @{ ok; sequence; driftCorrections }: ok when every step matched and nothing
# else was sent except allowed clock flips and §4.2 drift corrections; sequence = semantic keys of the remaining events.
function Test-TimelineEvents([string] $Prefix, $Result, [bool] $HidePaused) {
    $start = $Result.Start
    $data = @(Get-DataEvents $Result.Events)
    # Startup noise (page navigation `none` etc.) before the initial playing event is excluded.
    $initialIndex = [Array]::FindIndex([object[]] $data, [Predicate[object]] { param($e) $e.qpc -ge $Result.Initial.qpc -and (Test-Data $e.data 'playing') })
    if ($initialIndex -lt 0) { $initialIndex = 0 }
    $data = @($data | Select-Object -Skip $initialIndex)
    $after = @($data | Select-Object -Skip 1 | Where-Object { (Get-PageTime $_.qpc $start) -le 143 })
    $matched = [ordered]@{}; $unexpected = [Collections.Generic.List[object]]::new(); $drift = [Collections.Generic.List[object]]::new()
    $sequence = [Collections.Generic.List[string]]::new()
    $prevEv = if ($data.Count -gt 0) { $data[0] } else { $null }
    if ($prevEv) { $sequence.Add((Get-SemanticKey $prevEv.data)) }
    $k = 0
    foreach ($ev in $after) {
        $pt = Get-PageTime $ev.qpc $start
        $prev = if ($prevEv) { $prevEv.data } else { $null }
        $step = if ($k -lt $timelineSteps.Count) { $timelineSteps[$k] } else { $null }
        if ($step -and (& $step.test $ev.data) -and $pt -ge ($step.at - 1) -and $pt -le ($step.at + 2)) {
            $matched[$step.name] = Get-EventSummary $ev $start; $k++; $prevEv = $ev; $sequence.Add((Get-SemanticKey $ev.data)); continue
        }
        $clockFlip = (Get-SemanticKey $ev.data) -eq (Get-SemanticKey $prev) -and (Get-Prop $ev.data 'clock') -ne (Get-Prop $prev 'clock')
        $nearStep = [bool] ($timelineSteps | Where-Object { [Math]::Abs($pt - $_.at) -le 2 })
        $correction = Get-DriftCorrection $ev $prevEv $start
        if ($correction) { $drift.Add($correction) }
        elseif (-not ($clockFlip -and $nearStep)) { $unexpected.Add((Get-EventSummary $ev $start)); $sequence.Add((Get-SemanticKey $ev.data)) }
        $prevEv = $ev
    }
    Add-Check "$Prefix.initialAPlaying" 'initial event: A playing' (Get-EventSummary $Result.Initial $start) ((Test-Data $Result.Initial.data 'playing' 'fixtureSngA'))
    foreach ($step in $timelineSteps) {
        $m = $matched[$step.name]
        Add-Check "$Prefix.$($step.name)" "event within page $($step.at)..$($step.at + 2) s in sequence" $m ($null -ne $m)
    }
    Add-Check "$Prefix.noOtherDataEvents" 'no other data events (clock flips only within +-2 s of an event; plan §4.2 drift corrections allowed)' ([ordered]@{
        unexpected = @($unexpected); allowedDriftCorrections = @($drift) }) ($unexpected.Count -eq 0)
    $canary = $Result.Raw -match 'albumCanary|MPREb_|AlbumCanary'
    Add-Check "$Prefix.noAlbumCanary" 'album canary absent from all bytes' $canary (-not $canary -and $Result.Raw.Length -gt 0)
    $wrongHide = @($data | Where-Object { (Get-Prop $_.data 'state') -in @('playing', 'paused', 'ended') -and (Get-Prop $_.data 'hidePaused') -ne $HidePaused })
    Add-Check "$Prefix.hidePausedField" "every metadata event carries hidePaused=$HidePaused" $wrongHide.Count ($data.Count -gt 0 -and $wrongHide.Count -eq 0)
    $adEvents = @($data | Where-Object { (Get-Prop $_.data 'state') -in @('ad', 'none') })
    $badShape = @($adEvents | Where-Object { @($_.data.PSObject.Properties.Name) -join ',' -ne 'v,state' })
    Add-Check "$Prefix.adNoneShape" 'ad/none events carry only v and state' $badShape.Count ($badShape.Count -eq 0)
    Add-Check "$Prefix.appAlive" 'app alive through page 143 s' $Result.Alive $Result.Alive
    [pscustomobject]@{ ok = ($matched.Count -eq $timelineSteps.Count -and $unexpected.Count -eq 0); sequence = @($sequence); driftCorrections = @($drift) }
}

function Test-ATime {
    $variants = @(@{ n = 'hidePausedTrue'; h = $true; p = $null }, @{ n = 'hidePausedFalse'; h = $false; p = $null }, @{ n = 'adFallback'; h = $true; p = 'AdFallback' })
    $res = [ordered]@{}
    foreach ($v in $variants) {
        $result = Invoke-TimelineRun "A-TIME-$($v.n)" $v.h $v.p
        $res[$v.n] = Test-TimelineEvents "A-TIME.$($v.n)" $result $v.h
    }
    # Semantic sequences (state/id/title/artist/artwork/duration/rate) without clock flips or drift corrections.
    $readable = { param($r) @($r.sequence | ForEach-Object { ($_ -split [char] 1 | Select-Object -First 2) -join '/' }) }
    $same = { param($a, $b) ($a.sequence -join [char] 2) -ceq ($b.sequence -join [char] 2) }
    $t = $res['hidePausedTrue']; $f = $res['hidePausedFalse']; $a = $res['adFallback']
    Add-Check 'A-TIME.hidePausedVariantsSameSequence' 'hidePaused true and false produce the same semantic event sequence (drift corrections excluded)' ([ordered]@{
        hidePausedTrue = & $readable $t; hidePausedFalse = & $readable $f; okTrue = $t.ok; okFalse = $f.ok }) ($t.ok -and $f.ok -and (& $same $t $f))
    Add-Check 'A-TIME.adFallbackSameAdEvents' 'AdFallback yields the same semantic sequence, including ad and restore events (drift corrections excluded)' ([ordered]@{
        adFallback = & $readable $a; reference = & $readable $t; ok = $a.ok; driftCorrections = $a.driftCorrections }) ($a.ok -and (& $same $a $t))
    $scenarioResults['A-TIME'] = [ordered]@{
        hidePausedTrue = $t.ok; hidePausedFalse = $f.ok; adFallback = $a.ok
        driftCorrections = [ordered]@{ hidePausedTrue = $t.driftCorrections; hidePausedFalse = $f.driftCorrections; adFallback = $a.driftCorrections } }
}

# ---------------------------------------------------------------------------------------------------------------
# A-AD

function Test-AAd {
    if (-not (Test-ChromeAvailable 'A-AD')) { return }
    $results = [ordered]@{}
    foreach ($v in @(@{ n = 'default'; p = $null }, @{ n = 'adFallback'; p = 'AdFallback' })) {
        $run = Start-OverlayRun "A-AD-$($v.n)" @{ ObsHidePaused = $true } $v.p
        $chrome = $null
        try {
            $initial = Wait-Initial $run
            $start = Get-PageStartQpc $initial
            $chrome = Start-Chrome "A-AD-$($v.n)"
            [void] (Invoke-ChromeNavigate $chrome $overlayUrl)
            Wait-UntilQpc ($start + 67.5 * $freq)
            $during = Get-PageProbe $chrome
            $shotAd = Save-ChromeShot $chrome "A-AD-$($v.n)-67s"
            Wait-UntilQpc ($start + 70 * $freq)
            $saveQpc = Send-HookCommand $run.Root 'command-obs-hide-paused-off'
            Wait-UntilQpc ($start + 77.5 * $freq)
            $afterProbe = Get-PageProbe $chrome
            $shotBack = Save-ChromeShot $chrome "A-AD-$($v.n)-77s"
        } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
        $p = "A-AD.$($v.n)"
        Add-Check "$p.pageHiddenBy67_5" 'pill computed opacity <= 0.05 at page 67.5 s' $during.opacity ($null -ne $during.opacity -and [double] $during.opacity -le 0.05)
        Add-Check "$p.pageBackBy77_5" 'opacity 1 +-0.02 with "Fixture Song A" at page 77.5 s' ([ordered]@{ opacity = $afterProbe.opacity; title = $afterProbe.title }) (
            $null -ne $afterProbe.opacity -and [Math]::Abs([double] $afterProbe.opacity - 1) -le 0.02 -and $afterProbe.title -ceq 'Fixture Song A')
        $data = Get-DataEvents (Read-Sse $run.Reader)
        $adIndex = [Array]::FindIndex([object[]] $data, [Predicate[object]] { param($e) (Get-Prop $e.data 'state') -eq 'ad' })
        $restoreIndex = if ($adIndex -ge 0) { [Array]::FindIndex([object[]] $data, $adIndex + 1, [Predicate[object]] { param($e) Test-Data $e.data 'playing' 'fixtureSngA' }) } else { -1 }
        $between = if ($adIndex -ge 0 -and $restoreIndex -gt $adIndex) { $restoreIndex - $adIndex - 1 } else { $null }
        Add-Check "$p.adEvent" 'an ad event near page 65 s' $(if ($adIndex -ge 0) { Get-PageTime $data[$adIndex].qpc $start }) ($adIndex -ge 0 -and [Math]::Abs((Get-PageTime $data[$adIndex].qpc $start) - 66) -le 1.5)
        Add-Check "$p.noDataDuringAd" 'no data event between ad and restore' $between ($between -eq 0)
        Add-Check "$p.restoreCarriesNewHidePaused" 'restore event hidePaused false (saved at 70 s during the ad)' $(if ($restoreIndex -ge 0) { Get-EventSummary $data[$restoreIndex] $start }) (
            $restoreIndex -ge 0 -and (Get-Prop $data[$restoreIndex].data 'hidePaused') -eq $false -and $data[$restoreIndex].qpc -gt $saveQpc)
        $results[$v.n] = [ordered]@{ shots = @($shotAd, $shotBack) }
    }
    $scenarioResults['A-AD'] = $results
}

# ---------------------------------------------------------------------------------------------------------------
# A-SAME

function Test-ASame {
    $run = Start-OverlayRun 'A-SAME' @{} 'IdOnly'
    try {
        $initial = Wait-Initial $run
        $start = Get-PageStartQpc $initial
        Wait-UntilQpc ($start + 25 * $freq)
    } finally { Stop-OverlayRun $run }
    $after = @(Get-DataEvents (Read-Sse $run.Reader) | Where-Object { $_.qpc -gt $initial.qpc })
    $only = if ($after.Count -eq 1) { $after[0].data } else { $null }
    $sameOther = $only -and @(@('state', 'title', 'artist', 'artwork', 'duration', 'rate', 'clock') | Where-Object { "$(Get-Prop $only $_)" -ne "$(Get-Prop $initial.data $_)" }).Count -eq 0
    Add-Check 'A-SAME.oneNewEvent' 'exactly one data event after the initial one' @($after | ForEach-Object { Get-EventSummary $_ $start }) ($after.Count -eq 1)
    Add-Check 'A-SAME.onlyIdChanged' 'id fixtureSnA2; state, title, artist, artwork, duration, rate, clock unchanged' $(if ($only) { Get-EventSummary $after[0] $start }) (
        [bool] $sameOther -and (Get-Prop $only 'id') -eq 'fixtureSnA2')
    $scenarioResults['A-SAME'] = [ordered]@{ events = $after.Count }
}

# ---------------------------------------------------------------------------------------------------------------
# A-CLOCK

function Test-AClock {
    $run = Start-OverlayRun 'A-CLOCK' @{} 'Playing'
    try {
        $initial = Wait-Initial $run
        $start = Get-PageStartQpc $initial
        Start-Sleep -Seconds 3
        $onQpc = Send-HookCommand $run.Root 'command-clock-mismatch-on'
        Start-Sleep -Seconds 12
        $offQpc = Send-HookCommand $run.Root 'command-clock-mismatch-off'
        Start-Sleep -Seconds 6
    } finally { Stop-OverlayRun $run }
    $data = @(Get-DataEvents (Read-Sse $run.Reader) | Where-Object { $_.qpc -gt $initial.qpc })
    $falseEv = $data | Where-Object { $_.qpc -gt $onQpc -and (Get-Prop $_.data 'clock') -eq $false } | Select-Object -First 1
    $during = @($data | Where-Object { $falseEv -and $_.qpc -gt $falseEv.qpc -and $_.qpc -le $offQpc })
    $trueEv = $data | Where-Object { $_.qpc -gt $offQpc -and (Get-Prop $_.data 'clock') -eq $true } | Select-Object -First 1
    Add-Check 'A-CLOCK.clockFalseEvent' 'clock:false event <= 3 s after mismatch on' $(if ($falseEv) { Round3 (Get-Seconds $onQpc $falseEv.qpc) }) ($falseEv -and (Get-Seconds $onQpc $falseEv.qpc) -le 3)
    Add-Check 'A-CLOCK.silentUntilOff' 'no data events while mismatched' $during.Count ($falseEv -and $during.Count -eq 0)
    $fresh = $null
    if ($trueEv) {
        $capture = $trueEv.qpc - ([double] (Get-Prop $trueEv.data 'ageMs')) / 1000 * $freq
        $fresh = Round3 ([double] (Get-Prop $trueEv.data 'position') - (Get-Seconds $start $capture))
    }
    Add-Check 'A-CLOCK.clockTrueFreshAnchor' 'clock:true <= 3 s after off, position = page time +-1.5 s' ([ordered]@{
        delay = if ($trueEv) { Round3 (Get-Seconds $offQpc $trueEv.qpc) }; positionError = $fresh }) (
        $trueEv -and (Get-Seconds $offQpc $trueEv.qpc) -le 3 -and [Math]::Abs($fresh) -le 1.5)
    $scenarioResults['A-CLOCK'] = [ordered]@{ events = $data.Count }
}

# ---------------------------------------------------------------------------------------------------------------
# A-GAP

# Polls overlay.gapStartQpc once per second; returns the first non-null value (the gap's first failure).
function Watch-GapStart($Run, [double] $Seconds) {
    $first = $null; $deadline = (Get-Qpc) + $Seconds * $freq
    while ((Get-Qpc) -lt $deadline) {
        $s = Get-State $Run.Root 'gap'
        $g = Get-Overlay $s 'gapStartQpc'
        if ($null -ne $g -and $null -eq $first) { $first = [double] $g }
        Start-Sleep -Milliseconds 700
    }
    $first
}
function Test-GapNone([string] $Prefix, $Run, $GapStart) {
    $none = Get-DataEvents (Read-Sse $Run.Reader) | Where-Object { (Get-Prop $_.data 'state') -eq 'none' -and (-not $GapStart -or $_.qpc -gt $GapStart) } | Select-Object -First 1
    $delta = if ($none -and $GapStart) { Round3 (Get-Seconds $GapStart $none.qpc) } else { $null }
    Add-Check "$Prefix.gapStartRecorded" 'overlay.gapStartQpc recorded during the gap' $GapStart ($null -ne $GapStart)
    Add-Check "$Prefix.noneAt8s" 'none at gapStartQpc + 8 +-1.2 s' $delta ($null -ne $delta -and [Math]::Abs($delta - 8) -le 1.2)
}
function Test-AGap {
    $results = [ordered]@{}
    # Short gap (title removed 3 s at page 10 s): no none.
    $run = Start-OverlayRun 'A-GAP-short' @{} 'ShortGap'
    try { $initial = Wait-Initial $run; $start = Get-PageStartQpc $initial; Wait-UntilQpc ($start + 25 * $freq) } finally { Stop-OverlayRun $run }
    $nones = @(Get-DataEvents (Read-Sse $run.Reader) | Where-Object { $_.qpc -gt $initial.qpc -and (Get-Prop $_.data 'state') -eq 'none' })
    Add-Check 'A-GAP.shortGap.noNone' 'no none event for a 3 s gap' $nones.Count ($nones.Count -eq 0)

    # Existing ReaderGap (paused A, title empties at page 5 s until 32 s).
    $run = Start-OverlayRun 'A-GAP-readergap' @{} 'ReaderGap'
    try { [void] (Wait-BenchReady $run.Root); $gap = Watch-GapStart $run 22 } finally { Stop-OverlayRun $run }
    Test-GapNone 'A-GAP.readerGap' $run $gap
    $results['readerGapStart'] = $gap

    # DomGap (controls removed 10..30 s while playing).
    $run = Start-OverlayRun 'A-GAP-domgap' @{} 'DomGap'
    try { $initial = Wait-Initial $run; $start = Get-PageStartQpc $initial; Wait-UntilQpc ($start + 8 * $freq); $gap = Watch-GapStart $run 18 } finally { Stop-OverlayRun $run }
    Test-GapNone 'A-GAP.domGap' $run $gap

    # Native unavailable branch.
    $run = Start-OverlayRun 'A-GAP-native' @{} 'Playing'
    try {
        [void] (Wait-Initial $run)
        $onQpc = Send-HookCommand $run.Root 'command-controls-unavailable-on'
        $gap = Watch-GapStart $run 18
        Wait-UntilQpc ($onQpc + 20 * $freq)
        $offQpc = Send-HookCommand $run.Root 'command-controls-unavailable-off'
        Start-Sleep -Seconds 4
    } finally { Stop-OverlayRun $run }
    Test-GapNone 'A-GAP.native' $run $gap
    $fresh = Get-DataEvents (Read-Sse $run.Reader) | Where-Object { $_.qpc -gt $offQpc -and (Test-Data $_.data 'playing') } | Select-Object -First 1
    Add-Check 'A-GAP.native.playingAfterOff' 'fresh playing event <= 2 s after controls-unavailable-off' $(if ($fresh) { Round3 (Get-Seconds $offQpc $fresh.qpc) }) (
        $fresh -and (Get-Seconds $offQpc $fresh.qpc) -le 2)
    $scenarioResults['A-GAP'] = $results
}

# ---------------------------------------------------------------------------------------------------------------
# A-INV

function Test-AInv {
    $run = Start-OverlayRun 'A-INV' @{} 'Playing'
    $reader2 = $null; $obs = [ordered]@{}
    $noneAfter = { param($Reader, $Qpc) Wait-SseData $Reader { param($d) (Get-Prop $d 'state') -eq 'none' } 3 $Qpc }
    $playingAfter = { param($Reader, $Qpc, $Seconds) Wait-SseData $Reader { param($d) Test-Data $d 'playing' } $Seconds $Qpc }
    try {
        [void] (Wait-Initial $run)
        # Power suspend / resume.
        $q = Send-HookCommand $run.Root 'command-power-suspend'
        $none = & $noneAfter $run.Reader $q
        Add-Check 'A-INV.powerSuspend.noneWithin1s' 'none <= 1 s after power suspend' $(if ($none) { Round3 (Get-Seconds $q $none.qpc) }) ($none -and (Get-Seconds $q $none.qpc) -le 1)
        Start-Sleep -Seconds 2
        $q = Send-HookCommand $run.Root 'command-power-resume'
        $obs['resumedPlaying'] = [bool] (& $playingAfter $run.Reader $q 20)
        # Navigation.
        $q = Send-HookCommand $run.Root 'command-navigate'
        $none = & $noneAfter $run.Reader $q
        Add-Check 'A-INV.navigate.noneWithin1s' 'none <= 1 s after command-navigate' $(if ($none) { Round3 (Get-Seconds $q $none.qpc) }) ($none -and (Get-Seconds $q $none.qpc) -le 1)
        $obs['navigatePlaying'] = [bool] (& $playingAfter $run.Reader $q 40)
        # Held read across off/on: the held sample must not be sent.
        $genBefore = Get-Overlay (Get-State $run.Root 'hold0') 'generation'
        [void] (Send-HookCommand $run.Root 'command-obs-hold-read')
        Start-Sleep -Milliseconds 2500
        $offQpc = Send-HookCommand $run.Root 'command-obs-off'
        $close = Wait-For { @(Read-Sse $run.Reader) | Where-Object { $null -ne $_ -and $_.kind -eq 'close' -and $_.qpc -gt $offQpc } | Select-Object -First 1 } 5
        $finalData = @(Get-DataEvents (Read-Sse $run.Reader) | Where-Object { $_.qpc -gt $offQpc })
        Add-Check 'A-INV.hold.offClosesStreamWithin1s' 'server closes the stream <= 1 s after off, no final data event' ([ordered]@{
            closeSeconds = if ($close) { Round3 (Get-Seconds $offQpc $close.qpc) }; dataAfterOff = $finalData.Count }) (
            $close -and (Get-Seconds $offQpc $close.qpc) -le 1 -and $finalData.Count -eq 0)
        [void] (Send-HookCommand $run.Root 'command-obs-on')
        [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'hold-on') 'running') -eq $true } 10 500)
        $reader2 = Start-SseReader 'A-INV-after-hold'
        [void] (Wait-SseOpen $reader2)
        Start-Sleep -Seconds 3
        $relQpc = Send-HookCommand $run.Root 'command-obs-release-read'
        Start-Sleep -Seconds 5
        $genAfter = Get-Overlay (Get-State $run.Root 'hold1') 'generation'
        $d2 = @(Get-DataEvents (Read-Sse $reader2))
        $stale = @($d2 | Where-Object { [double] (Get-Prop $_.data 'ageMs') -gt 1500 -or $_.qpc -lt $relQpc })
        Add-Check 'A-INV.hold.heldSampleNotSent' 'no event from the held read (none before release, none with ageMs > 1500)' ([ordered]@{
            events = $d2.Count; stale = @($stale | ForEach-Object { Get-EventSummary $_ }); generationBefore = $genBefore; generationAfter = $genAfter }) (
            $stale.Count -eq 0 -and [int] $genAfter -gt [int] $genBefore)
        Add-Check 'A-INV.hold.freshSampleAfterRelease' 'a fresh sample follows the release' $d2.Count ($d2.Count -gt 0)
        # Renderer kill -> real ProcessFailed.
        $renderers = @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine | Where-Object {
            $_.CommandLine -and $_.CommandLine.Contains($run.Root, [StringComparison]::OrdinalIgnoreCase) -and $_.CommandLine -match '--type=renderer' })
        $q = Get-Qpc
        foreach ($r in $renderers) { Stop-Process -Id $r.ProcessId -Force -ErrorAction SilentlyContinue }
        $none = & $noneAfter $reader2 $q
        Add-Check 'A-INV.rendererKill.noneWithin1s' 'none <= 1 s after the renderer is killed' ([ordered]@{
            renderers = $renderers.Count; seconds = if ($none) { Round3 (Get-Seconds $q $none.qpc) } }) ($renderers.Count -gt 0 -and $none -and (Get-Seconds $q $none.qpc) -le 1)
        Start-Sleep -Seconds 2
        $obs['aliveAfterRendererKill'] = -not $run.App.HasExited
    } finally { Stop-SseReader $reader2; Stop-OverlayRun $run }
    $scenarioResults['A-INV'] = $obs
}

# ---------------------------------------------------------------------------------------------------------------
# A-IDLE

function Test-AIdle {
    $run = Start-OverlayRun 'A-IDLE' @{} 'Paused'
    try {
        $initial = Wait-SseData $run.Reader { param($d) Test-Data $d 'paused' 'fixtureSngA' } 120
        if (-not $initial) { throw 'A-IDLE: no initial paused event.' }
        Wait-UntilQpc ($initial.qpc + 121 * $freq)
    } finally { Stop-OverlayRun $run }
    $events = @(@(Read-Sse $run.Reader) | Where-Object { $null -ne $_ -and $_.qpc -gt $initial.qpc -and $_.qpc -le $initial.qpc + 120 * $freq })
    $data = @($events | Where-Object { $null -ne $_ -and $_.kind -eq 'data' })
    $comments = @($events | Where-Object { $null -ne $_ -and $_.kind -eq 'comment' })
    $gaps = @(for ($i = 1; $i -lt $comments.Count; $i++) { Round3 (Get-Seconds $comments[$i - 1].qpc $comments[$i].qpc) })
    Add-Check 'A-IDLE.noDataEvents' '0 data events for 120 s' $data.Count ($data.Count -eq 0)
    Add-Check 'A-IDLE.commentsEvery5s' 'comments every 5 +-1 s' ([ordered]@{ count = $comments.Count; min = ($gaps | Measure-Object -Minimum).Minimum; max = ($gaps | Measure-Object -Maximum).Maximum }) (
        $comments.Count -ge 20 -and -not ($gaps | Where-Object { $_ -lt 4 -or $_ -gt 6 }))
    $scenarioResults['A-IDLE'] = [ordered]@{ comments = $comments.Count }
}

# ---------------------------------------------------------------------------------------------------------------
# A-DEMAND

function Test-ADemand {
    $obs = [ordered]@{}
    # Part 1: Discord off, stream counts.
    $run = Start-OverlayRun 'A-DEMAND-streams' @{} 'Playing' -NoReader
    $r1 = $null; $r2 = $null
    try {
        [void] (Wait-BenchReady $run.Root)
        Start-Sleep -Seconds 3
        $s0 = Get-State $run.Root 'none0'; Start-Sleep -Seconds 6; $s1 = Get-State $run.Root 'none1'
        $none = Get-ReadStats $s0 $s1
        Add-Check 'A-DEMAND.noStreams.noReads' '0 reads with no stream (Discord off)' $none ($none.total -eq 0)
        $r1 = Start-SseReader 'A-DEMAND-r1'; [void] (Wait-SseOpen $r1); Start-Sleep -Seconds 2
        $a = Get-State $run.Root 'one0'; Start-Sleep -Seconds 12; $b = Get-State $run.Root 'one1'
        $one = Get-ReadStats $a $b
        Add-Check 'A-DEMAND.oneStream.overlay1PerSec' 'Overlay reads 1 +-0.2/s with 1 stream' $one (Test-RatePerSecond $one.overlay $one.seconds)
        Add-Check 'A-DEMAND.oneStream.state' 'demand Overlay, timer 1000 ms' ([ordered]@{ demand = Get-Overlay $b 'demand'; intervalMs = Get-Overlay $b 'intervalMs'; streams = Get-Overlay $b 'streams' }) (
            (Get-Overlay $b 'demand') -eq 'Overlay' -and (Get-Overlay $b 'intervalMs') -eq 1000 -and (Get-Overlay $b 'streams') -eq 1)
        $r2 = Start-SseReader 'A-DEMAND-r2'; [void] (Wait-SseOpen $r2); Start-Sleep -Seconds 1
        $c = Get-State $run.Root 'two0'; Start-Sleep -Seconds 12; $d = Get-State $run.Root 'two1'
        $two = Get-ReadStats $c $d
        Add-Check 'A-DEMAND.twoStreams.overlay1PerSec' 'still 1 +-0.2/s with 2 streams' ([ordered]@{ reads = $two; streams = Get-Overlay $d 'streams' }) (
            (Test-RatePerSecond $two.overlay $two.seconds) -and (Get-Overlay $d 'streams') -eq 2)
        Stop-SseReader $r1
        [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'close1') 'streams') -eq 1 } 10 500)
        $e = Get-State $run.Root 'rest0'; Start-Sleep -Seconds 12; $f = Get-State $run.Root 'rest1'
        $rest = Get-ReadStats $e $f
        Add-Check 'A-DEMAND.closeOne.overlay1PerSec' '1 +-0.2/s after one of two closes' $rest (Test-RatePerSecond $rest.overlay $rest.seconds)
        $closeQpc = Get-Qpc
        Stop-SseReader $r2
        Start-Sleep -Seconds 17
        $g = Get-State $run.Root 'closed'
        $late = @(@(Get-Prop $g.diag 'reads') | Where-Object { $_ -and [double] $_.startQpc -gt $closeQpc + 7 * $freq })
        Add-Check 'A-DEMAND.closeAll.noReadsAfter7s' 'no reads start later than 7 s after the last stream closes' ([ordered]@{ reads = $late.Count; demand = Get-Overlay $g 'demand' }) (
            $null -ne $g -and $late.Count -eq 0)
        Add-Check 'A-DEMAND.streams.neverTwoInFlight' 'never two reads in flight' $true (Test-NoOverlap $g)
    } finally { Stop-SseReader $r1; Stop-SseReader $r2; Stop-OverlayRun $run }

    # Part 2: tray-hidden with SleepInBackground=true.
    $run = Start-OverlayRun 'A-DEMAND-hidden' @{ SleepInBackground = $true } 'Playing' 'Hidden'
    try {
        $ready = Wait-BenchReady $run.Root
        [void] (Wait-SseOpen $run.Reader); Start-Sleep -Seconds 4
        $h0 = Get-State $run.Root 'hid0'; Start-Sleep -Seconds 15; $h1 = Get-State $run.Root 'hid1'
        $hidden = Get-ReadStats $h0 $h1
        Add-Check 'A-DEMAND.hidden.readsContinue' 'hidden in tray with SleepInBackground=true: Overlay reads 1 +-0.2/s' ([ordered]@{
            reads = $hidden; appWindowVisible = Get-Prop $h1.state 'appWindowVisible'; ready = [bool] $ready }) (
            [bool] $ready -and (Get-Prop $h1.state 'appWindowVisible') -eq $false -and (Test-RatePerSecond $hidden.overlay $hidden.seconds))
    } finally { Stop-OverlayRun $run }

    # Part 3: Discord on (fake server READY), default timeline, production write gate.
    $server = Start-FakeServer 'A-DEMAND'
    $run = Start-OverlayRun 'A-DEMAND-discord' @{ DiscordPresence = $true }
    $raw = $null
    try {
        $initial = Wait-Initial $run
        $start = Get-PageStartQpc $initial
        # Measure only once the app has completed the IPC handshake with the fake server (READY sent).
        $readyQpc = Wait-For { Get-FakeServerReadyQpc $server } 30 500
        Add-Check 'A-DEMAND.discordReady' 'fake Discord server sent READY to the app before measuring' ([ordered]@{
            ready = [bool] $readyQpc; serverViaRunas = $server.ViaRunas; serverIntegrity = $server.Integrity; serverAdminEnabled = $server.AdminEnabled
            appIntegrity = $run.App.Integrity }) ([bool] $readyQpc)
        if (-not $readyQpc) { throw 'Fake Discord server never sent READY (app did not connect to the test pipe); Discord checks cannot be measured.' }
        Wait-UntilQpc ([Math]::Max($start + 8 * $freq, $readyQpc + 3 * $freq))
        $o0 = Get-State $run.Root 'ov0'; Start-Sleep -Seconds 12; $o1 = Get-State $run.Root 'ov1'
        $ov = Get-ReadStats $o0 $o1
        Add-Check 'A-DEMAND.discordOn.overlay1PerSec' 'Overlay reads 1 +-0.2/s with Discord on and a stream open, no Presence reads' $ov (
            (Test-RatePerSecond $ov.overlay $ov.seconds) -and $ov.presence -le 1)
        [void] (Send-HookCommand $run.Root 'command-compact'); Start-Sleep -Seconds 3
        $c0 = Get-State $run.Root 'cmp0'; Start-Sleep -Seconds 12; $c1 = Get-State $run.Root 'cmp1'
        $cmp = Get-ReadStats $c0 $c1
        Add-Check 'A-DEMAND.compact.oneReadStream' 'Compact reads 1 +-0.2/s, total 1 +-0.2/s (no second stream)' $cmp (
            (Test-RatePerSecond $cmp.compact $cmp.seconds) -and (Test-RatePerSecond $cmp.total $cmp.seconds) -and $cmp.overlay -le 1)
        [void] (Send-HookCommand $run.Root 'command-full'); Start-Sleep -Seconds 3
        Stop-SseReader $run.Reader
        Start-Sleep -Seconds 10
        $p0 = Get-State $run.Root 'pr0'; Start-Sleep -Seconds 20; $p1 = Get-State $run.Root 'pr1'
        $pr = Get-ReadStats $p0 $p1
        Add-Check 'A-DEMAND.presenceBackTo5s' 'Presence ~5 s cadence after the stream closes, no Overlay reads' $pr (
            $pr.seconds -gt 0 -and $pr.presence -ge [Math]::Floor($pr.seconds / 5 * 0.5) -and $pr.total -le [Math]::Ceiling($pr.seconds / 5 * 1.5) + 1 -and $pr.overlay -eq 0)
        # Late join 0.5 s after a Presence read.
        $join = $null
        for ($attempt = 0; $attempt -lt 8 -and -not $join; $attempt++) {
            $snap = Get-State $run.Root 'late'
            $pres = @(@(Get-Prop $snap.diag 'reads') | Where-Object { $_ -and (Get-Prop $_ 'mode') -eq 'Presence' } | Sort-Object { [double] $_.startQpc })
            if ($pres.Count -eq 0) { Start-Sleep -Seconds 5; continue }
            $last = [double] $pres[-1].startQpc
            $since = Get-Seconds $last (Get-Qpc)
            if ($since -ge 0.3 -and $since -le 0.9) {
                $jq = Get-Qpc; $raw = Open-RawStream
                $join = [ordered]@{ presenceReadQpc = $last; joinQpc = $jq; offsetSeconds = Round3 (Get-Seconds $last $jq); status = $raw.Status }
            } else {
                $wait = 5 - $since + 0.35; while ($wait -lt 0) { $wait += 5 }
                Start-Sleep -Milliseconds ([int] ($wait * 1000))
            }
        }
        Start-Sleep -Seconds 3
        $j = Get-State $run.Root 'join'
        $firstOverlay = if ($join) { @(Get-Prop $j.diag 'reads') | Where-Object { $_ -and (Get-Prop $_ 'mode') -eq 'Overlay' -and [double] $_.startQpc -gt $join.joinQpc } |
            Sort-Object { [double] $_.startQpc } | Select-Object -First 1 } else { $null }
        $delay = if ($firstOverlay) { Round3 (Get-Seconds $join.joinQpc $firstOverlay.startQpc) } else { $null }
        if ($join) { $join['firstOverlayReadSeconds'] = $delay }
        Add-Check 'A-DEMAND.lateJoin.firstReadWithin1_1s' 'first Overlay read <= 1.1 s after a join 0.5 s after a Presence read' $join ($null -ne $delay -and $delay -le 1.1)
        Close-RawStream $raw; $raw = $null
        Wait-UntilQpc ($start + 128 * $freq)
        $end = Get-State $run.Root 'end'
        Add-Check 'A-DEMAND.discordOn.neverTwoInFlight' 'never two reads in flight' $true (Test-NoOverlap $end)
        $alive = -not $run.App.HasExited
    } finally { Close-RawStream $raw; Stop-OverlayRun $run; Stop-FakeServer $server }
    $sets = @(Get-NonNullSets $server)
    $gaps = @(for ($i = 1; $i -lt $sets.Count; $i++) { Round3 (($sets[$i] - $sets[$i - 1]) / 1000) })
    Add-Check 'A-DEMAND.discordWriteGaps' 'consecutive non-null SET_ACTIVITY >= 14.5 s apart' ([ordered]@{ sets = $sets.Count; gaps = $gaps }) (
        $sets.Count -ge 2 -and -not ($gaps | Where-Object { $_ -lt 14.5 }))
    $obs['alive'] = $alive
    $scenarioResults['A-DEMAND'] = $obs
}

# ---------------------------------------------------------------------------------------------------------------
# A-LIVE

function Test-ALive {
    $run = Start-OverlayRun 'A-LIVE' @{} 'Playing'
    $nonReader = $null; $suspended = $null; $obs = [ordered]@{}
    try {
        [void] (Wait-BenchReady $run.Root)
        [void] (Wait-SseOpen $run.Reader); Start-Sleep -Seconds 2
        # (a) clean close
        $q = Get-Qpc
        Stop-SseReader $run.Reader
        $released = Wait-For { $s = Get-State $run.Root 'a'; if ((Get-Overlay $s 'streams') -eq 0) { $s } } 15 300
        Add-Check 'A-LIVE.cleanClose.releasedWithin7s' 'stream released <= 7 s, reason Closed' ([ordered]@{
            seconds = if ($released) { Round3 (Get-Seconds $q $released.qpc) }; reason = Get-Overlay $released 'lastStreamEndReason' }) (
            $released -and (Get-Seconds $q $released.qpc) -le 7 -and (Get-Overlay $released 'lastStreamEndReason') -eq 'Closed')
        # (c) non-reading client + burst, then (b) a suspended reader; both run to the 5 min lifetime.
        $nonReader = Open-RawStream -NoRead
        [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'c0') 'streams') -eq 1 } 10 500)
        [void] (Send-HookCommand $run.Root 'command-obs-burst')
        $pending = Wait-For { $s = Get-State $run.Root 'c1'; if ((Get-Overlay $s 'pendingWrite') -eq $true) { $s } } 20 500
        Add-Check 'A-LIVE.burst.pendingWriteObserved' 'pendingWrite true after command-obs-burst to a non-reading client' ([bool] $pending) ([bool] $pending)
        $suspended = Start-SseReader 'A-LIVE-suspended'
        [void] (Wait-SseOpen $suspended)
        $bQpc = Get-Qpc
        $rc = [ObsE2E]::Suspend($suspended.Process.Id, $false)
        $obs['suspendStatus'] = $rc
        $transitions = [Collections.Generic.List[object]]::new(); $prevStreams = 2
        $deadline = $nonReader.OpenQpc + 330 * $freq
        while ((Get-Qpc) -lt $deadline -and $prevStreams -gt 0) {
            Start-Sleep -Seconds 2
            $s = Get-State $run.Root 'life'
            $n = Get-Overlay $s 'streams'
            if ($null -ne $n -and [int] $n -lt $prevStreams) {
                $transitions.Add([ordered]@{ streams = [int] $n; reason = Get-Overlay $s 'lastStreamEndReason'; qpc = $s.qpc })
                $prevStreams = [int] $n
            }
        }
        $first = if ($transitions.Count -ge 1) { $transitions[0] } else { $null }
        $second = if ($transitions.Count -ge 2) { $transitions[1] } elseif ($first -and $first.streams -eq 0) { $first } else { $null }
        Add-Check 'A-LIVE.nonReading.releasedAtLifetime' 'non-reading burst client released <= 5 min 15 s, reason Lifetime' ([ordered]@{
            seconds = if ($first) { Round3 (Get-Seconds $nonReader.OpenQpc $first.qpc) }; reason = if ($first) { $first.reason } }) (
            $first -and (Get-Seconds $nonReader.OpenQpc $first.qpc) -le 315 -and $first.reason -eq 'Lifetime')
        Add-Check 'A-LIVE.suspended.releasedAtLifetime' 'suspended consumer released <= 5 min 15 s, reason Lifetime' ([ordered]@{
            seconds = if ($second) { Round3 (Get-Seconds $bQpc $second.qpc) }; reason = if ($second) { $second.reason } }) (
            $second -and (Get-Seconds $bQpc $second.qpc) -le 315 -and $second.reason -eq 'Lifetime')
        Add-Check 'A-LIVE.noCrash' 'app alive after the lifetime releases' (-not $run.App.HasExited) (-not $run.App.HasExited)
        $obs['transitions'] = @($transitions)
    } finally {
        if ($suspended) { [void] [ObsE2E]::Suspend($suspended.Process.Id, $true) }
        Stop-SseReader $suspended; Close-RawStream $nonReader; Stop-OverlayRun $run
    }
    $scenarioResults['A-LIVE'] = $obs
}

# ---------------------------------------------------------------------------------------------------------------
# A-LIFE

function Test-ALife {
    $obs = [ordered]@{}; $adminStates = [Collections.Generic.List[object]]::new()
    foreach ($case in @('0', '2', '8', 'pendingWrite')) {
        $run = Start-OverlayRun "A-LIFE-quit-$case" @{} 'Playing' -NoReader
        $adminStates.Add([ordered]@{ run = "quit-$case"; adminEnabled = $run.App.AdminEnabled; integrity = $run.App.Integrity })
        $streams = [Collections.Generic.List[object]]::new()
        try {
            [void] (Wait-BenchReady $run.Root)
            if ($case -eq 'pendingWrite') {
                $streams.Add((Open-RawStream -NoRead))
                [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'pw0') 'streams') -eq 1 } 10 500)
                [void] (Send-HookCommand $run.Root 'command-obs-burst')
                $pending = Wait-For { (Get-Overlay (Get-State $run.Root 'pw1') 'pendingWrite') -eq $true } 20 500
                Add-Check 'A-LIFE.quitPendingWrite.pendingObserved' 'pendingWrite true before quit' ([bool] $pending) ([bool] $pending)
            } else {
                $count = [int] $case
                for ($i = 0; $i -lt $count; $i++) { $streams.Add((Open-RawStream)) }
                $open = Wait-For { $s = Get-State $run.Root 'open'; if ((Get-Overlay $s 'streams') -eq $count) { $s } } 10 500
                Add-Check "A-LIFE.quit$case.streamsOpen" "$count streams open before quit" (Get-Overlay $open 'streams') ($count -eq 0 -or $open)
            }
            $q = Send-HookCommand $run.Root 'command-quit'
            $exitQpc = Wait-For { if ($run.App.HasExited) { Get-Qpc } } 10 50
            $exited = $run.App.HasExited
            $exitSeconds = if ($exited -and $exitQpc) { Round3 (Get-Seconds $q $exitQpc) } else { $null }
            $name = if ($case -eq 'pendingWrite') { 'quitPendingWrite' } else { "quit$case" }
            Add-Check "A-LIFE.$name.exitWithin5s" 'process exits <= 5 s after command-quit' $exitSeconds ($exited -and $exitSeconds -le 5)
            $reg = Test-PrefixRegistrable
            Add-Check "A-LIFE.$name.prefixRegistrableAfter" 'another process registers the prefix after exit' $reg $reg
        } finally { foreach ($s in $streams) { Close-RawStream $s }; Stop-OverlayRun $run }
    }
    # Off/on x20.
    $run = Start-OverlayRun 'A-LIFE-toggle' @{} 'Playing' -NoReader
    $adminStates.Add([ordered]@{ run = 'toggle'; adminEnabled = $run.App.AdminEnabled; integrity = $run.App.Integrity })
    $reader = $null
    try {
        [void] (Wait-BenchReady $run.Root)
        $ok = 0; $releasedOnOff = $null
        for ($i = 1; $i -le 20; $i++) {
            [void] (Send-HookCommand $run.Root 'command-obs-off')
            $off = Wait-For { (Get-Overlay (Get-State $run.Root "t$i-off") 'running') -eq $false } 8 300
            if ($i -eq 10) { $releasedOnOff = Test-PrefixRegistrable }
            [void] (Send-HookCommand $run.Root 'command-obs-on')
            $on = Wait-For { (Get-Overlay (Get-State $run.Root "t$i-on") 'running') -eq $true } 8 300
            if ($off -and $on) { $ok++ }
        }
        Add-Check 'A-LIFE.toggle20.allCycles' '20 off/on cycles, each off stops and each on runs' $ok ($ok -eq 20)
        Add-Check 'A-LIFE.toggle20.prefixReleasedWhenOff' 'prefix registrable by another process while off' $releasedOnOff ([bool] $releasedOnOff)
        $reader = Start-SseReader 'A-LIFE-toggle'
        $data = Wait-SseData $reader { param($d) Test-Data $d 'playing' } 10
        Add-Check 'A-LIFE.toggle20.connectsAfter' 'a stream connects and receives playing after 20 cycles' ([bool] $data) ([bool] $data)
        Add-Check 'A-LIFE.toggle20.noCrash' 'app alive' (-not $run.App.HasExited) (-not $run.App.HasExited)
    } finally { Stop-SseReader $reader; Stop-OverlayRun $run }
    # Start while another process holds the prefix.
    $held = Hold-Prefix
    $run = Start-OverlayRun 'A-LIFE-held' @{} 'Playing' -NoReader
    $adminStates.Add([ordered]@{ run = 'held'; adminEnabled = $run.App.AdminEnabled; integrity = $run.App.Integrity })
    $reader = $null
    try {
        [void] (Wait-BenchReady $run.Root)
        $s = Wait-For { $x = Get-State $run.Root 'held'; if ((Get-Overlay $x 'bindResult')) { $x } } 10 500
        Add-Check 'A-LIFE.held.bindErrorReported' 'bindResult PrefixInUse, not running' ([ordered]@{ bindResult = Get-Overlay $s 'bindResult'; running = Get-Overlay $s 'running' }) (
            (Get-Overlay $s 'bindResult') -eq 'PrefixInUse' -and (Get-Overlay $s 'running') -ne $true)
        Release-Prefix $held; $held = $null
        [void] (Send-HookCommand $run.Root 'command-obs-off'); Start-Sleep -Seconds 1
        [void] (Send-HookCommand $run.Root 'command-obs-on')
        $running = Wait-For { (Get-Overlay (Get-State $run.Root 'recover') 'running') -eq $true } 10 500
        $reader = Start-SseReader 'A-LIFE-held-recover'
        $data = Wait-SseData $reader { param($d) Test-Data $d 'playing' } 15
        Add-Check 'A-LIFE.held.recoveryConnects' 'after freeing the prefix, off/on runs and a stream connects' ([ordered]@{ running = [bool] $running; data = [bool] $data }) ($running -and $data)
    } finally { if ($held) { Release-Prefix $held }; Stop-SseReader $reader; Stop-OverlayRun $run }
    $logLine = @(Get-ObsLogLines $run.Root | Where-Object { $_ -match '\[obs\] bind PrefixInUse' }).Count
    Add-Check 'A-LIFE.held.bindLogLine' 'log line "[obs] bind PrefixInUse"' $logLine ($logLine -ge 1)
    Add-Check 'A-LIFE.appTokenNotElevated' 'Administrators group not enabled in the app token (adminEnabled false) for every launch' @($adminStates) (
        $adminStates.Count -gt 0 -and -not ($adminStates | Where-Object { $_.adminEnabled -ne $false }))
    $scenarioResults['A-LIFE'] = $obs
}

# ---------------------------------------------------------------------------------------------------------------
# A-SEC

function Get-LanIPv4 {
    $a = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object {
        $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' -and $_.AddressState -eq 'Preferred' } | Select-Object -First 1
    if ($a) { $a.IPAddress } else { $null }
}
function Test-ASec {
    $run = Start-OverlayRun 'A-SEC' @{} 'Playing' -NoReader
    $raws = [Collections.Generic.List[object]]::new(); $table = [ordered]@{}; $responses = [Collections.Generic.List[object]]::new()
    try {
        [void] (Wait-BenchReady $run.Root)
        $rows = @(
            @{ n = 'host127'; a = '127.0.0.1'; r = (New-Request -HostHeader "127.0.0.1:$port"); want = { param($x) $x.status -eq 400 -and $x.origin -eq 'kernel' }; e = '400 kernel' },
            @{ n = 'hostV6Literal'; a = '127.0.0.1'; r = (New-Request -HostHeader "[::1]:$port"); want = { param($x) $x.status -eq 400 -and $x.origin -eq 'kernel' }; e = '400 kernel' },
            @{ n = 'hostEvil'; a = '127.0.0.1'; r = (New-Request -HostHeader 'evil.test'); want = { param($x) $x.status -eq 400 -and $x.origin -eq 'kernel' }; e = '400 kernel' },
            @{ n = 'twoHosts'; a = '127.0.0.1'; r = (New-Request -Extra @("Host: localhost:$port")); want = { param($x) ($x.status -eq 400 -and $x.origin -eq 'kernel') -or ($x.status -eq 403 -and $x.origin -eq 'app') }; e = '400 kernel or 403 app' },
            @{ n = 'secFetchCrossSite'; a = '127.0.0.1'; r = (New-Request -Extra @('Sec-Fetch-Site: cross-site')); want = { param($x) $x.status -eq 403 -and $x.origin -eq 'app' }; e = '403 app' },
            @{ n = 'secFetchSameSite'; a = '127.0.0.1'; r = (New-Request -Extra @('Sec-Fetch-Site: same-site')); want = { param($x) $x.status -eq 403 -and $x.origin -eq 'app' }; e = '403 app' },
            @{ n = 'originEvil'; a = '127.0.0.1'; r = (New-Request -Extra @('Origin: https://evil.test')); want = { param($x) $x.status -eq 403 -and $x.origin -eq 'app' }; e = '403 app' },
            @{ n = 'originNull'; a = '127.0.0.1'; r = (New-Request -Extra @('Origin: null')); want = { param($x) $x.status -eq 403 -and $x.origin -eq 'app' }; e = '403 app' },
            @{ n = 'post'; a = '127.0.0.1'; r = (New-Request -Method POST -Extra @('Content-Length: 0')); want = { param($x) $x.status -eq 405 -and $x.origin -eq 'app' }; e = '405 app' },
            @{ n = 'put'; a = '127.0.0.1'; r = (New-Request -Method PUT -Extra @('Content-Length: 0')); want = { param($x) $x.status -eq 405 -and $x.origin -eq 'app' }; e = '405 app' },
            @{ n = 'options'; a = '127.0.0.1'; r = (New-Request -Method OPTIONS); want = { param($x) $x.status -eq 405 -and $x.origin -eq 'app' }; e = '405 app' },
            @{ n = 'getContentLength1'; a = '127.0.0.1'; r = (New-Request -Extra @('Content-Length: 1')); b = [byte[]] @(0x78); want = { param($x) $x.status -eq 400 }; e = '400' },
            @{ n = 'getChunked'; a = '127.0.0.1'; r = (New-Request -Extra @('Transfer-Encoding: chunked')); b = [Text.Encoding]::ASCII.GetBytes("1`r`nx`r`n0`r`n`r`n"); want = { param($x) $x.status -eq 400 }; e = '400' },
            @{ n = 'eventsQuery'; a = '127.0.0.1'; r = (New-Request -Path '/events?x=1'); want = { param($x) $x.status -eq 400 -and $x.origin -eq 'app' }; e = '400 app' },
            @{ n = 'rawDotDot'; a = '127.0.0.1'; r = (New-Request -Path '/../'); want = { param($x) ($x.status -eq 200 -and $x.origin -eq 'app' -and "$($x.headers['content-type'])" -like 'text/html*') -or ($x.origin -eq 'kernel' -and $x.status -ge 400 -and $x.status -lt 500) }; e = '200 page (app) or kernel 4xx (HTTP.sys normalizes/rejects); harmless either way' },
            @{ n = 'nope'; a = '127.0.0.1'; r = (New-Request -Path '/nope'); want = { param($x) $x.status -eq 404 -and $x.origin -eq 'app' }; e = '404 app' },
            @{ n = 'pageIPv4'; a = '127.0.0.1'; r = (New-Request); want = { param($x) $x.status -eq 200 -and "$($x.headers['content-type'])" -like 'text/html*' }; e = '200 page over IPv4' },
            @{ n = 'pageIPv6'; a = '::1'; r = (New-Request); want = { param($x) $x.status -eq 200 -and "$($x.headers['content-type'])" -like 'text/html*' }; e = '200 page over IPv6' },
            @{ n = 'script'; a = '127.0.0.1'; r = (New-Request -Path '/overlay.js'); want = { param($x) $x.status -eq 200 -and "$($x.headers['content-type'])" -like 'text/javascript*' }; e = '200 script' },
            @{ n = 'events'; a = '127.0.0.1'; r = (New-Request -Path '/events'); want = { param($x) $x.status -eq 200 -and "$($x.headers['content-type'])" -like 'text/event-stream*' -and $x.body -match 'retry: 3000' }; e = '200 event-stream starting retry: 3000' })
        $lan = Get-LanIPv4
        if ($lan) {
            $x = Invoke-RawHttp $lan (New-Request)
            $responses.Add($x)
            Add-Check 'A-SEC.lanIPv4ForgedHost' '403 app (LAN IPv4 peer with Host: localhost)' ([ordered]@{ status = $x.status; origin = $x.origin; error = $x.error }) ($x.status -eq 403 -and $x.origin -eq 'app')
        } else {
            Add-Blocked 'A-SEC.lanIPv4ForgedHost' '403 app (LAN IPv4 peer with Host: localhost)' 'this PC has no LAN IPv4 address; run on a PC with one before merge'
        }
        foreach ($row in $rows) {
            $x = Invoke-RawHttp $row.a $row.r $row['b']
            $responses.Add($x)
            $table[$row.n] = [ordered]@{ status = $x.status; origin = $x.origin; error = $x.error }
            Add-Check "A-SEC.$($row.n)" $row.e $table[$row.n] ([bool] (& $row.want $x))
        }
        $page = $responses | Where-Object { $_.status -eq 200 -and "$($_.headers['content-type'])" -like 'text/html*' } | Select-Object -First 1
        $csp = if ($page) { "$($page.headers['content-security-policy'])" } else { '' }
        $cspParts = @("default-src 'none'", "script-src 'self'", "style-src 'unsafe-inline'", "connect-src 'self'", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'",
            'img-src https://lh3.googleusercontent.com https://i.ytimg.com https://yt3.ggpht.com https://yt3.googleusercontent.com')
        Add-Check 'A-SEC.htmlCsp' 'HTML carries the plan §3 CSP' $csp ($csp -and -not ($cspParts | Where-Object { -not $csp.Contains($_) }))
        # 8 streams + 9th 503, close one, 9th succeeds.
        # Release earlier streams (e.g. the 'events' row) and wait until the app has deregistered them.
        foreach ($r in $raws) { Close-RawStream $r }; $raws.Clear()
        [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'streams0') 'streams') -eq 0 } 10 500)
        $streamsBefore = Get-Overlay (Get-State $run.Root 'streams0b') 'streams'
        for ($i = 0; $i -lt 8; $i++) { $raws.Add((Open-RawStream)) }
        $ninth = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/events')
        $responses.Add($ninth)
        Add-Check 'A-SEC.ninthStream503' '0 streams before; 8 streams open (200), the 9th gets 503 from the app' ([ordered]@{ streamsBefore = $streamsBefore; open = @($raws | ForEach-Object { $_.Status }); ninth = $ninth.status; origin = $ninth.origin }) (
            $streamsBefore -eq 0 -and -not ($raws | Where-Object { $_.Status -ne 200 }) -and $ninth.status -eq 503 -and $ninth.origin -eq 'app')
        Close-RawStream $raws[0]; $raws.RemoveAt(0)
        [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'seven') 'streams') -eq 7 } 10 500)
        $again = Open-RawStream; $raws.Add($again)
        Add-Check 'A-SEC.ninthAfterCloseSucceeds' 'after one closes, the next stream gets 200' $again.Status ($again.Status -eq 200)
        foreach ($r in $raws) { $responses.Add([pscustomobject]@{ status = $r.Status; headers = $r.Headers; origin = if ($r.Headers.Contains('x-content-type-options')) { 'app' } else { 'kernel' } }) }
        $appResponses = @($responses | Where-Object { $_.origin -eq 'app' })
        $missing = @($appResponses | Where-Object { "$($_.headers['x-content-type-options'])" -ne 'nosniff' -or "$($_.headers['cache-control'])" -notmatch 'no-store' -or "$($_.headers['referrer-policy'])" -ne 'no-referrer' })
        Add-Check 'A-SEC.appHeadersEverywhere' 'nosniff, no-store, no-referrer on every app response' ([ordered]@{ appResponses = $appResponses.Count; missing = $missing.Count }) ($appResponses.Count -gt 0 -and $missing.Count -eq 0)
        $cors = @($responses | Where-Object { @($_.headers.Keys | Where-Object { $_ -like 'access-control-*' }).Count -gt 0 })
        Add-Check 'A-SEC.noAccessControlHeaders' 'no Access-Control-* on any response' $cors.Count ($cors.Count -eq 0)
    } finally { foreach ($r in $raws) { Close-RawStream $r }; Stop-OverlayRun $run }
    $scenarioResults['A-SEC'] = [ordered]@{ lanIPv4Present = [bool] (Get-LanIPv4); table = $table }
}

# ---------------------------------------------------------------------------------------------------------------
# A-RECON

function Wait-PageConnected($Chrome, [double] $Seconds) {
    Wait-For { $p = Get-PageProbe $Chrome; if ((Get-PageField $p 'connection') -eq 'open' -and (Get-PageField $p 'shown') -eq $true -and (Get-PageField $p 'state') -eq 'playing') { $p } } $Seconds 250
}
function Test-ARecon {
    if (-not (Test-ChromeAvailable 'A-RECON')) { return }
    $run = Start-OverlayRun 'A-RECON' @{ ObsOverlay = $false } 'Playing' -NoReader
    $chrome = $null; $raws = [Collections.Generic.List[object]]::new(); $obs = [ordered]@{}
    try {
        [void] (Wait-BenchReady $run.Root)
        $chrome = Start-Chrome 'A-RECON'
        # (1) off -> error page; on + reload -> connected.
        $nav = Invoke-ChromeNavigate $chrome $overlayUrl
        Start-Sleep -Seconds 1
        $p = Get-PageProbe $chrome
        $errorPage = [bool] (Get-Prop $nav 'errorText') -or "$($p.href)" -like 'chrome-error:*' -or $null -eq (Get-Prop $p 's')
        Add-Check 'A-RECON.1.errorPageWhenOff' 'Chrome shows an error page while the overlay is off' ([ordered]@{ errorText = Get-Prop $nav 'errorText'; href = $p.href }) $errorPage
        [void] (Send-HookCommand $run.Root 'command-obs-on')
        [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'on') 'running') -eq $true } 10 500)
        [void] (Invoke-Cdp $chrome 'Page.reload')
        $connected = Wait-PageConnected $chrome 15
        $obs['reloadHref'] = if ($connected) { $connected.href } else { (Get-PageProbe $chrome).href }
        Add-Check 'A-RECON.1.connectedAfterReload' 'after on + CDP reload: connection open, pill shown with playing state' ([bool] $connected) ([bool] $connected)
        $obs['shot1'] = Save-ChromeShot $chrome 'A-RECON-1-connected'
        # (2) server restart.
        [void] (Send-HookCommand $run.Root 'command-obs-off')
        [void] (Wait-For { $pp = Get-PageProbe $chrome; (Get-PageField $pp 'connection') -ne 'open' } 5)
        $onQpc = Send-HookCommand $run.Root 'command-obs-on'
        $back = Wait-PageConnected $chrome 10
        Add-Check 'A-RECON.2.reconnectedWithin5s' 'page reconnected with state <= 5 s after the server is back' $(if ($back) { Round3 (Get-Seconds $onQpc $back.qpc) }) (
            $back -and (Get-Seconds $onQpc $back.qpc) -le 5)
        # (3) no streams for 30 s while Playing, then reconnect.
        [void] (Invoke-ChromeNavigate $chrome 'about:blank')
        $zero = Wait-For { $s = Get-State $run.Root 'blank'; if ((Get-Overlay $s 'streams') -eq 0) { $s } } 10 500
        Start-Sleep -Seconds 30
        $navQpc = Get-Qpc
        [void] (Invoke-ChromeNavigate $chrome $overlayUrl)
        $initial = Wait-PageConnected $chrome 5
        Add-Check 'A-RECON.3.initialStateWithin2s' 'after 30 s without streams: initial state shown <= 2 s' ([ordered]@{
            streamsWhileAway = Get-Overlay $zero 'streams'; seconds = if ($initial) { Round3 (Get-Seconds $navQpc $initial.qpc) } }) (
            $zero -and $initial -and (Get-Seconds $navQpc $initial.qpc) -le 2)
        # (4) 9th stream 503 -> CLOSED -> retry after 30 s.
        [void] (Invoke-ChromeNavigate $chrome 'about:blank')
        [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'blank2') 'streams') -eq 0 } 10 500)
        for ($i = 0; $i -lt 8; $i++) { $raws.Add((Open-RawStream)) }
        [void] (Invoke-ChromeNavigate $chrome $overlayUrl)
        $closed = Wait-For { $pp = Get-PageProbe $chrome; if ((Get-PageField $pp 'connection') -eq 'closed' -and (Get-PageField $pp 'shown') -eq $false) { $pp } } 8
        Add-Check 'A-RECON.4.closedOn503' 'page CLOSED and hidden after a 503' ([bool] $closed) ([bool] $closed)
        $obs['shot4'] = Save-ChromeShot $chrome 'A-RECON-4-503'
        Close-RawStream $raws[0]; $raws.RemoveAt(0)
        $retry = Wait-For { $pp = Get-PageProbe $chrome; if ((Get-PageField $pp 'connection') -eq 'open') { $pp } } 45 500
        $retrySeconds = if ($closed -and $retry) { Round3 (Get-Seconds $closed.qpc $retry.qpc) } else { $null }
        Add-Check 'A-RECON.4.retryAfter30s' 'one retry about 30 s after CLOSED (29..36 s)' $retrySeconds ($null -ne $retrySeconds -and $retrySeconds -ge 29 -and $retrySeconds -le 36)
        foreach ($r in $raws) { Close-RawStream $r }; $raws.Clear()
        # (5) 5 min lifetime renewal without hiding.
        $renewStart = Get-Qpc; $hiddenSamples = 0; $samples = 0
        while ((Get-Seconds $renewStart (Get-Qpc)) -lt 320) {
            $pp = Get-PageProbe $chrome; $samples++
            if ((Get-PageField $pp 'shown') -ne $true) { $hiddenSamples++ }
            Start-Sleep -Milliseconds 1000
        }
        $s = Get-State $run.Root 'renew'
        Add-Check 'A-RECON.5.lifetimeRenewalNoHide' 'the pill stays shown through the 5 min lifetime renewal' ([ordered]@{
            samples = $samples; hiddenSamples = $hiddenSamples; lastStreamEndReason = Get-Overlay $s 'lastStreamEndReason'; streams = Get-Overlay $s 'streams' }) (
            $hiddenSamples -eq 0 -and (Get-Overlay $s 'lastStreamEndReason') -eq 'Lifetime' -and (Get-Overlay $s 'streams') -ge 1)
    } finally { foreach ($r in $raws) { Close-RawStream $r }; Stop-Chrome $chrome; Stop-OverlayRun $run }
    $scenarioResults['A-RECON'] = $obs
}

# ---------------------------------------------------------------------------------------------------------------
# A-TEXT

function Test-AText {
    if (-not (Test-ChromeAvailable 'A-TEXT')) { return }
    $obs = [ordered]@{}
    $longTitle = ('Fixture Long Title ' * 14).Substring(0, 249) + '!'
    $artist = [string]::new([char[]] @(0x97F3, 0x697D, 0x30C6, 0x30B9, 0x30C8, 0x20, 0x0627, 0x0644, 0x0641, 0x0646, 0x0627, 0x0646))
    $run = Start-OverlayRun 'A-TEXT-text' @{} 'Text'
    $chrome = $null
    try {
        $initial = Wait-Initial $run
        $start = Get-PageStartQpc $initial
        $chrome = Start-Chrome 'A-TEXT-text'
        [void] (Invoke-ChromeNavigate $chrome $overlayUrl)
        Wait-UntilQpc ($start + 9 * $freq)
        $p1 = Get-PageProbe $chrome
        $obs['shotLong'] = Save-ChromeShot $chrome 'A-TEXT-long'
        Add-Check 'A-TEXT.longTitleLiteral' 'DOM title equals the 250-char fixture title' ([ordered]@{ length = "$($p1.title)".Length }) ($p1.title -ceq $longTitle)
        Add-Check 'A-TEXT.artistLiteral' 'DOM artist equals the CJK + Arabic fixture artist' $p1.artist ($p1.artist -ceq $artist)
        Add-Check 'A-TEXT.ellipsis' 'title overflow shows an ellipsis' $p1.titleEllipsis ($p1.titleEllipsis -eq $true)
        Wait-UntilQpc ($start + 19 * $freq)
        $p2 = Get-PageProbe $chrome
        $obs['shotHtml'] = Save-ChromeShot $chrome 'A-TEXT-html-literal'
        Add-Check 'A-TEXT.htmlLiteral' 'DOM title is the literal "<b>&amp;</b>" with no child elements' ([ordered]@{ title = $p2.title; children = $p2.titleChildren }) (
            $p2.title -ceq '<b>&amp;</b>' -and $p2.titleChildren -eq 0)
        # Projection (§4.2) against the latest sample seen by the SSE reader, at t0 and t0 + 10 s.
        foreach ($offset in @(0, 10)) {
            if ($offset) { Start-Sleep -Seconds 10 }
            $pp = Get-PageProbe $chrome
            $last = Get-DataEvents (Read-Sse $run.Reader) | Where-Object { $_.qpc -le $pp.qpc } | Select-Object -Last 1
            $expected = $null
            if ($last -and (Test-Data $last.data 'playing') -and (Get-Prop $last.data 'clock') -and (Get-Prop $last.data 'duration')) {
                $duration = [double] $last.data.duration
                $pos = [double] $last.data.position + ([double] $last.data.ageMs / 1000 + (Get-Seconds $last.qpc $pp.qpc)) * [double] $last.data.rate
                $expected = [Math]::Min([Math]::Max($pos, 0), $duration) / $duration
            }
            Add-Check "A-TEXT.projectionT$offset" "boundary at t0+$offset s matches §4.2 projection within 1 %" ([ordered]@{ observed = Round3 $pp.frac; expected = Round3 $expected }) (
                $null -ne $expected -and $null -ne $pp.frac -and [Math]::Abs([double] $pp.frac - $expected) -le 0.01)
        }
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }

    $run = Start-OverlayRun 'A-TEXT-artswap' @{} 'ArtSwap'
    $chrome = $null
    try {
        $initial = Wait-Initial $run
        $start = Get-PageStartQpc $initial
        $chrome = Start-Chrome 'A-TEXT-artswap'
        [void] (Invoke-ChromeNavigate $chrome $overlayUrl)
        Wait-UntilQpc ($start + 18 * $freq)
        $p = Get-PageProbe $chrome
        $s = Get-State $run.Root 'art'
        $obs['shotArt'] = Save-ChromeShot $chrome 'A-TEXT-artswap-final'
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
    $a = @($p.art | Where-Object { $_.name -eq '/fixture-art/a.png' }) | Select-Object -Last 1
    $b = @($p.art | Where-Object { $_.name -eq '/fixture-art/b.png' }) | Select-Object -Last 1
    Add-Check 'A-TEXT.artSwapFinalB' 'delayed A completes after B, but the latest load (B) is applied: artLoadedSeq == artSeq, no failure' ([ordered]@{
        artSeq = Get-PageField $p 'artSeq'; artLoadedSeq = Get-PageField $p 'artLoadedSeq'; artFailed = Get-PageField $p 'artFailed'
        aEnd = if ($a) { $a.end }; bEnd = if ($b) { $b.end }; fixtureArtServed = Get-Overlay $s 'fixtureArtServed' }) (
        $a -and $b -and [double] $a.start -lt [double] $b.start -and [double] $a.end -gt [double] $b.end -and
        (Get-PageField $p 'artSeq') -eq (Get-PageField $p 'artLoadedSeq') -and (Get-PageField $p 'artFailed') -eq $false)
    $scenarioResults['A-TEXT'] = $obs
}

# ---------------------------------------------------------------------------------------------------------------
# A-SET

$obsIds = @('ObsNavItem', 'ObsOverlayCheckBox', 'ObsDisclosureText', 'ObsHidePausedCheckBox', 'ObsLinkTextBox', 'ObsCopyLinkButton', 'ObsCopyLinkResult',
    'ObsGuideButton', 'ObsGuideResult', 'ObsAdTipText', 'ObsOpenBlockAdsButton', 'ObsStepsText', 'ObsStatusText')
function Test-ASet {
    $obs = [ordered]@{}; $shots = [ordered]@{}
    $root = New-Root 'A-SET'
    Write-Settings $root @{ OmitObsKeys = $true }
    $bench = @{ NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'Playing'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
    $app = $null; $reader = $null; $recorder = $null; $held = $null
    try {
        # Launch 1: missing-key v7 file.
        $app = Start-App $root $bench
        [void] (Wait-BenchReady $root)
        $ui = Open-ObsSettings $app
        $els = [ordered]@{}; $missing = @()
        foreach ($id in $obsIds) { $els[$id] = Find-Element $ui.Dlg 'AutomationId' $id 10; if (-not $els[$id]) { $missing += $id } }
        $described = [ordered]@{}; foreach ($id in $obsIds) { $described[$id] = Describe $els[$id] }
        $unnamed = @($obsIds | Where-Object { $els[$_] -and -not $els[$_].Current.Name })
        Add-Check 'A-SET.namesAndHelp' 'every OBS control present with an accessible name' ([ordered]@{ missing = $missing; unnamed = $unnamed; controls = $described }) (
            $missing.Count -eq 0 -and $unnamed.Count -eq 0)
        $shots['obsPage'] = Save-WindowShot $ui.Hwnd 'A-SET-obs-page'
        Add-Check 'A-SET.missingKeyDefaults' 'missing keys: overlay off, hide-when-paused on' ([ordered]@{
            overlay = Get-ToggleState $els['ObsOverlayCheckBox']; hidePaused = Get-ToggleState $els['ObsHidePausedCheckBox'] }) (
            (Get-ToggleState $els['ObsOverlayCheckBox']) -eq 'Off' -and (Get-ToggleState $els['ObsHidePausedCheckBox']) -eq 'On')
        $focusIds = @('ObsOverlayCheckBox', 'ObsHidePausedCheckBox', 'ObsLinkTextBox', 'ObsCopyLinkButton', 'ObsGuideButton', 'ObsOpenBlockAdsButton')
        $focus = [ordered]@{}
        foreach ($id in $focusIds) {
            $el = $els[$id]; $ok = $false
            if ($el -and $el.Current.IsKeyboardFocusable) { try { $el.SetFocus(); Start-Sleep -Milliseconds 150; $ok = $el.Current.HasKeyboardFocus } catch { } }
            $focus[$id] = $ok
        }
        Add-Check 'A-SET.keyboardFocusable' 'every interactive OBS control is keyboard-focusable and takes focus' $focus (-not ($focus.Values | Where-Object { -not $_ }))
        $linkValue = try { (Get-Pattern $els['ObsLinkTextBox'] ([System.Windows.Automation.ValuePattern])).Current } catch { $null }
        Add-Check 'A-SET.linkReadOnly' 'link box read-only with http://localhost:47813/' ([ordered]@{ value = Get-Prop $linkValue 'Value'; readOnly = Get-Prop $linkValue 'IsReadOnly' }) (
            (Get-Prop $linkValue 'Value') -eq $overlayUrl -and (Get-Prop $linkValue 'IsReadOnly') -eq $true)
        Set-Clipboard -Value 'nativune-e2e-placeholder'
        Invoke-Element $els['ObsCopyLinkButton']
        $clip = Wait-For { $c = Get-Clipboard -Raw; if ($c -eq $overlayUrl) { $c } } 5
        Add-Check 'A-SET.copyLink' 'clipboard = http://localhost:47813/' (Get-Clipboard -Raw) ($clip -eq $overlayUrl)
        $launchedPath = Join-Path (Get-BenchDirectory $root) 'launched-uri.json'
        Invoke-Element $els['ObsGuideButton']
        $launched = Wait-For { if (Test-Path -LiteralPath $launchedPath) { Get-Content -Raw -LiteralPath $launchedPath | ConvertFrom-Json } } 10
        Add-Check 'A-SET.guideUriRecorded' "hook build records the guide URI $guideUri instead of launching" (Get-Prop $launched 'uri') ((Get-Prop $launched 'uri') -eq $guideUri)
        # Tick -> announced "Turns on after Save" -> Cancel -> off.
        $attached = $false; $attachError = $liveRecorderError
        if ($liveRecorderSupported) {
            try { $recorder = [ObsLiveRecorder]::new(); $recorder.Attach($ui.Dlg); $attached = $true }
            catch { $attachError = "$($_.Exception.GetType().FullName): $($_.Exception.Message)"; $recorder = $null }
        }
        Set-Toggle $els['ObsOverlayCheckBox'] $true
        $status = Wait-For { $n = (Find-Element $ui.Dlg 'AutomationId' 'ObsStatusText' 3).Current.Name; if ($n -like '*Turns on after Save*') { $n } } 5
        Add-Check 'A-SET.tickShowsTurnsOnAfterSave' 'status "Turns on after Save" after ticking' $status ([bool] $status)
        if ($attached) {
            $isStatus = { param($n) $n -like '*Turns on after Save*' -or $n -like '*OBS overlay status*' }
            $announced = Wait-For { @($recorder.Snapshot() | Where-Object { & $isStatus $_ }).Count -gt 0 } 3
            $statusNames = @($recorder.Snapshot() | Where-Object { & $isStatus $_ })
            Add-Check 'A-SET.liveRegionAnnounced' 'LiveRegionChanged raised by the OBS status text ("Turns on after Save" / "OBS overlay status")' ([ordered]@{ statusEvents = $statusNames; all = @($recorder.Snapshot()) }) ([bool] $announced)
        } else {
            Add-Blocked 'A-SET.liveRegionAnnounced' 'LiveRegionChanged raised with "Turns on after Save"' "UIA LiveRegionChanged not available: $attachError"
        }
        if ($recorder) { $recorder.Detach(); $recorder = $null }
        $shots['turnsOn'] = Save-WindowShot $ui.Hwnd 'A-SET-turns-on-after-save'
        Close-Settings $ui 'CancelButton'
        $afterCancel = Get-State $root 'cancel'
        Add-Check 'A-SET.cancelKeepsOff' 'after Cancel the overlay stays off and nothing is saved' ([ordered]@{
            enabled = Get-Overlay $afterCancel 'enabled'; saved = Get-Prop (Read-SavedSettings $root) 'ObsOverlay' }) (
            (Get-Overlay $afterCancel 'enabled') -eq $false -and (Get-Prop (Read-SavedSettings $root) 'ObsOverlay') -ne $true)
        # Open Block ads setting: Privacy page, Block ads unchanged.
        $ui = Open-ObsSettings $app
        $blockBefore = Get-Prop (Read-SavedSettings $root) 'BlockAds'
        Invoke-Element (Get-ObsControl $ui 'ObsOpenBlockAdsButton')
        Start-Sleep -Milliseconds 800
        $privacy = Find-Element $ui.Dlg 'AutomationId' 'PrivacyNavItem' 5
        $privacySelected = $privacy -and (Get-Pattern $privacy ([System.Windows.Automation.SelectionItemPattern])).Current.IsSelected
        $blockBox = Find-Element $ui.Dlg 'AutomationId' 'BlockAdsCheckBox' 5
        $blockState = if ($blockBox) { Get-ToggleState $blockBox } else { $null }
        Add-Check 'A-SET.openBlockAdsSetting' 'Privacy page selected, Block ads value unchanged' ([ordered]@{ privacySelected = [bool] $privacySelected; blockAds = $blockState; saved = $blockBefore }) (
            [bool] $privacySelected -and $blockState -eq $(if ($blockBefore) { 'On' } else { 'Off' }))
        $shots['blockAds'] = Save-WindowShot $ui.Hwnd 'A-SET-open-block-ads'
        (Get-Pattern $ui.Nav ([System.Windows.Automation.SelectionItemPattern])).Select(); Start-Sleep -Milliseconds 800
        # Tick -> Save -> Waiting.
        Set-Toggle (Get-ObsControl $ui 'ObsOverlayCheckBox') $true
        Close-Settings $ui 'SaveButton'
        $saved = Wait-For { (Get-Prop (Read-SavedSettings $root) 'ObsOverlay') -eq $true } 10
        $ui = Open-ObsSettings $app
        $waiting = Wait-For { $n = (Get-ObsControl $ui 'ObsStatusText').Current.Name; if ($n -like '*Waiting for OBS*') { $n } } 8
        Add-Check 'A-SET.saveShowsWaiting' 'Save persists ObsOverlay true and the status reads "Waiting for OBS"' ([ordered]@{ saved = [bool] $saved; status = $waiting }) ([bool] $saved -and [bool] $waiting)
        $shots['waiting'] = Save-WindowShot $ui.Hwnd 'A-SET-waiting'
        Close-Settings $ui 'CancelButton'
        # Hide-when-paused off -> Save while playing -> open stream receives the latest sample with hidePaused:false.
        $reader = Start-SseReader 'A-SET-hidepaused'
        [void] (Wait-SseData $reader { param($d) Test-Data $d 'playing' } 20)
        $ui = Open-ObsSettings $app
        $connected = (Get-ObsControl $ui 'ObsStatusText').Current.Name
        $shots['connected'] = Save-WindowShot $ui.Hwnd 'A-SET-connected'
        Set-Toggle (Get-ObsControl $ui 'ObsHidePausedCheckBox') $false
        $saveQpc = Get-Qpc
        Close-Settings $ui 'SaveButton'
        $ev = Wait-SseData $reader { param($d) (Test-Data $d 'playing') -and (Get-Prop $d 'hidePaused') -eq $false } 5 $saveQpc
        Add-Check 'A-SET.hidePausedSaveBroadcasts' 'open stream receives the latest playing sample with hidePaused:false after Save' ([ordered]@{
            status = $connected; seconds = if ($ev) { Round3 (Get-Seconds $saveQpc $ev.qpc) } }) ([bool] $ev)
        Stop-SseReader $reader; $reader = $null
        Stop-App $app $root; $app = $null
        # Launch 2: relaunch -> on; untick -> Save.
        $app = Start-App $root $bench
        [void] (Wait-BenchReady $root)
        $ui = Open-ObsSettings $app
        $on = Get-ToggleState (Get-ObsControl $ui 'ObsOverlayCheckBox')
        Add-Check 'A-SET.relaunchOn' 'after relaunch the overlay is on' $on ($on -eq 'On')
        Set-Toggle (Get-ObsControl $ui 'ObsOverlayCheckBox') $false
        Close-Settings $ui 'SaveButton'
        [void] (Wait-For { (Get-Prop (Read-SavedSettings $root) 'ObsOverlay') -eq $false } 10)
        Stop-App $app $root; $app = $null
        # Launch 3: relaunch -> off.
        $app = Start-App $root $bench
        [void] (Wait-BenchReady $root)
        $ui = Open-ObsSettings $app
        $off = Get-ToggleState (Get-ObsControl $ui 'ObsOverlayCheckBox')
        Add-Check 'A-SET.relaunchOff' 'after untick + Save + relaunch the overlay is off' $off ($off -eq 'Off')
        # Save failure: deny creating files in data/ (settings.json.tmp) for Everyone.
        $data = Join-Path $root 'data'
        & icacls.exe $data /deny '*S-1-1-0:(WD)' | Out-Null
        $aclDenied.Add($data)
        Set-Toggle (Get-ObsControl $ui 'ObsOverlayCheckBox') $true
        Close-Settings $ui 'SaveButton'
        # SaveSettingsAsync fails on its worker after Save returns, then SetStatus(..., isError) renames MoreButton
        # and stores the text shown by More > Application status (error) > "Current application status".
        $failure = Get-AppStatusText $app '*could not be saved*' 30
        $message = $failure.text
        $session = Get-State $root 'savefail'
        Add-Check 'A-SET.saveFailureSessionMessage' 'session-only save-failure message (Application status); overlay on for this session' ([ordered]@{
            message = $message; moreButton = $failure.moreName; enabled = Get-Overlay $session 'enabled' }) (
            "$message" -like '*could not be saved*' -and "$message" -like '*this session only*' -and (Get-Overlay $session 'enabled') -eq $true)
        $shots['saveFailure'] = Save-WindowShot $ui.MainHwnd 'A-SET-save-failure'
        Stop-App $app $root; $app = $null
        & icacls.exe $data /remove:d '*S-1-1-0' | Out-Null
        [void] $aclDenied.Remove($data)
        $app = Start-App $root $bench
        [void] (Wait-BenchReady $root)
        $ui = Open-ObsSettings $app
        $notPersisted = Get-ToggleState (Get-ObsControl $ui 'ObsOverlayCheckBox')
        Add-Check 'A-SET.saveFailureNotPersisted' 'after relaunch the failed save is not persisted (off)' $notPersisted ($notPersisted -eq 'Off')
        Close-Settings $ui 'CancelButton'
        Stop-App $app $root; $app = $null
        # Bind conflict -> error text -> free -> off/on -> Waiting.
        $held = Hold-Prefix
        $settings = Read-SavedSettings $root; $settings.ObsOverlay = $true
        [IO.File]::WriteAllText((Join-Path $root 'data/settings.json'), ($settings | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
        $app = Start-App $root $bench
        [void] (Wait-BenchReady $root)
        $ui = Open-ObsSettings $app
        $bindText = Wait-For { $n = (Get-ObsControl $ui 'ObsStatusText').Current.Name; if ($n -like '*another app, or another Nativune*') { $n } } 8
        Add-Check 'A-SET.bindConflictText' 'status names the prefix conflict' $bindText ([bool] $bindText)
        $shots['bindConflict'] = Save-WindowShot $ui.Hwnd 'A-SET-bind-conflict'
        Release-Prefix $held; $held = $null
        Set-Toggle (Get-ObsControl $ui 'ObsOverlayCheckBox') $false
        Close-Settings $ui 'SaveButton'
        $ui = Open-ObsSettings $app
        Set-Toggle (Get-ObsControl $ui 'ObsOverlayCheckBox') $true
        Close-Settings $ui 'SaveButton'
        $ui = Open-ObsSettings $app
        $recovered = Wait-For { $n = (Get-ObsControl $ui 'ObsStatusText').Current.Name; if ($n -like '*Waiting for OBS*') { $n } } 8
        Add-Check 'A-SET.bindConflictRecovers' 'after freeing the prefix, off/on shows "Waiting for OBS"' $recovered ([bool] $recovered)
        Close-Settings $ui 'CancelButton'
    } finally {
        if ($recorder) { $recorder.Detach() }
        if ($held) { Release-Prefix $held }
        Stop-SseReader $reader
        foreach ($d in @($aclDenied)) { & icacls.exe $d /remove:d '*S-1-1-0' | Out-Null; [void] $aclDenied.Remove($d) }
        Stop-App $app $root
        Copy-AppLog $root 'A-SET'
    }
    $obs['shots'] = $shots
    $scenarioResults['A-SET'] = $obs
}

# ---------------------------------------------------------------------------------------------------------------
# A-PROD

function Find-Bytes([byte[]] $Haystack, [byte[]] $Needle) {
    $first = $Needle[0]; $limit = $Haystack.Length - $Needle.Length
    for ($i = [Array]::IndexOf($Haystack, $first); $i -ge 0 -and $i -le $limit; $i = [Array]::IndexOf($Haystack, $first, $i + 1)) {
        $match = $true
        for ($j = 1; $j -lt $Needle.Length; $j++) { if ($Haystack[$i + $j] -ne $Needle[$j]) { $match = $false; break } }
        if ($match) { return $true }
    }
    $false
}
function Test-AProd {
    if (-not (Test-Path -LiteralPath $releaseExe -PathType Leaf)) { throw "Release build not found at $releaseExe." }
    $releaseGuideUrl = 'https://github.com/Hantu-Raya/Nativune/blob/main/docs/obs-overlay.md'
    $scan = [ordered]@{}; $guideFound = [System.Collections.Generic.List[string]]::new()
    $files = @(Get-ChildItem -LiteralPath $releaseDirectory -File | Where-Object { $_.Name -like 'Nativune*.dll' -or $_.Name -like 'Nativune*.pri' -or $_.Name -like '*.resources.dll' })
    foreach ($f in $files) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        foreach ($needle in @('launched-uri', 'command-obs', 'command-controls', 'fixture-art')) {
            if ((Find-Bytes $bytes ([Text.Encoding]::UTF8.GetBytes($needle))) -or (Find-Bytes $bytes ([Text.Encoding]::Unicode.GetBytes($needle)))) {
                $scan["$($f.Name):$needle"] = $true
            }
        }
        if ((Find-Bytes $bytes ([Text.Encoding]::UTF8.GetBytes($releaseGuideUrl))) -or (Find-Bytes $bytes ([Text.Encoding]::Unicode.GetBytes($releaseGuideUrl)))) {
            $guideFound.Add($f.Name)
        }
    }
    Add-Check 'A-PROD.assemblyStringScan' 'no launched-uri, command-obs, command-controls or fixture-art in Nativune.dll/resources (UTF-8 and UTF-16)' ([ordered]@{
        files = @($files | ForEach-Object { $_.Name }); hits = @($scan.Keys) }) ($files.Count -gt 0 -and $scan.Count -eq 0 -and ($files | Where-Object { $_.Name -eq 'Nativune.dll' }))
    Add-Check 'A-PROD.guideUrlInAssembly' "release assembly/resources contain $releaseGuideUrl (UTF-8 or UTF-16; button not clicked)" ([ordered]@{
        foundIn = @($guideFound) }) ($guideFound.Count -gt 0)
    $root = New-Root 'A-PROD'
    Write-Settings $root @{ ObsOverlay = $true }
    $app = $null; $obs = [ordered]@{}
    try {
        $app = Start-App $root @{} $releaseExe
        $page = Wait-For { $x = Invoke-RawHttp '127.0.0.1' (New-Request); if ($x.status -eq 200) { $x } } 90 1000
        if (-not $page) { throw 'A-PROD: release overlay page never answered.' }
        $art = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/fixture-art/a.png')
        Add-Check 'A-PROD.fixtureArt404' '/fixture-art/a.png -> 404' $art.status ($art.status -eq 404)
        $csp = "$($page.headers['content-security-policy'])"
        $imgSrc = ([regex]::Match($csp, "img-src[^;]*")).Value
        Add-Check 'A-PROD.cspNoSelfImages' "CSP img-src without 'self'" $imgSrc ($imgSrc -and $imgSrc -notmatch "'self'")
        $js = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/overlay.js')
        Add-Check 'A-PROD.scriptNoFixtureArt' 'served /overlay.js has no fixture-art (and no __state hook)' ([ordered]@{ status = $js.status; length = $js.body.Length }) (
            $js.status -eq 200 -and $js.body.Length -gt 0 -and $js.body -notmatch 'fixture-art' -and $js.body -notmatch '__state')
        $ui = Open-ObsSettings $app
        # The "How to set up…" button is deliberately not clicked: in the release build it opens the owner's real
        # default browser. The guide URL is verified statically by A-PROD.guideUrlInAssembly above.
        $obs['shot'] = Save-WindowShot $ui.Hwnd 'A-PROD-settings-obs'
        Close-Settings $ui 'CancelButton'
    } finally { Stop-App $app $root -Kill; Copy-AppLog $root 'A-PROD' }
    $scenarioResults['A-PROD'] = $obs
}

# ---------------------------------------------------------------------------------------------------------------
# A-PAUSEVIEW

function Get-PauseSamples($Chrome, [double] $Start, [double] $Until) {
    $samples = [Collections.Generic.List[object]]::new()
    while ((Get-Qpc) -lt $Until) {
        $p = Get-PageProbe $Chrome
        $samples.Add([pscustomobject]@{ pt = Get-PageTime $p.qpc $Start; frac = $p.frac; opacity = $p.opacity; running = $p.running; shown = Get-PageField $p 'shown' })
        Start-Sleep -Milliseconds 250
    }
    $samples.ToArray()
}
function Test-APauseView {
    if (-not (Test-ChromeAvailable 'A-PAUSEVIEW')) { return }
    $obs = [ordered]@{}
    # (1) Paused, hidePaused false then true.
    $run = Start-OverlayRun 'A-PAUSEVIEW-1' @{ ObsHidePaused = $false } 'Paused' -NoReader
    $chrome = $null
    try {
        [void] (Wait-BenchReady $run.Root)
        $chrome = Start-Chrome 'A-PAUSEVIEW-1'
        [void] (Invoke-ChromeNavigate $chrome $overlayUrl)
        [void] (Wait-For { (Get-PageField (Get-PageProbe $chrome) 'shown') -eq $true } 10)
        Start-Sleep -Milliseconds 1500
        $p = Get-PageProbe $chrome
        $obs['shotShown'] = Save-ChromeShot $chrome 'A-PAUSEVIEW-1-paused-shown'
        Add-Check 'A-PAUSEVIEW.1.shownDimmedFrozen' 'shown, opacity 0.7 +-0.02, no running animation, boundary 60/1800 +-1 %' ([ordered]@{
            opacity = $p.opacity; running = $p.running; frac = Round3 $p.frac }) (
            (Get-PageField $p 'shown') -eq $true -and [Math]::Abs([double] $p.opacity - 0.7) -le 0.02 -and $p.running -eq 0 -and [Math]::Abs([double] $p.frac - 60 / 1800) -le 0.01)
        [void] (Send-HookCommand $run.Root 'command-obs-hide-paused-on')
        $hidden = Wait-For { $pp = Get-PageProbe $chrome; if ($null -ne $pp.opacity -and [double] $pp.opacity -le 0.05) { $pp } } 5
        Add-Check 'A-PAUSEVIEW.1.hiddenWhenHidePaused' 'hidePaused true: pill hidden' $(if ($hidden) { $hidden.opacity }) ([bool] $hidden)
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }

    # (2) PausedSeek, hidePaused false.
    $run = Start-OverlayRun 'A-PAUSEVIEW-2' @{ ObsHidePaused = $false } 'PausedSeek' -NoReader
    $chrome = $null
    try {
        $ready = Wait-BenchReady $run.Root
        $start = Get-ReadyQpc $ready
        if (-not $start) { throw 'A-PAUSEVIEW(2): bench not ready.' }
        $chrome = Start-Chrome 'A-PAUSEVIEW-2'
        [void] (Invoke-ChromeNavigate $chrome $overlayUrl)
        $samples = Get-PauseSamples $chrome $start ($start + 30 * $freq)
        $obs['shotSeek'] = Save-ChromeShot $chrome 'A-PAUSEVIEW-2-150s'
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
    $t120 = $samples | Where-Object { $null -ne $_.frac -and [Math]::Abs([double] $_.frac - 120 / 1800) -le 0.01 } | Select-Object -First 1
    $t150 = $samples | Where-Object { $null -ne $_.frac -and [Math]::Abs([double] $_.frac - 150 / 1800) -le 0.01 } | Select-Object -First 1
    $firstShown = $samples | Where-Object { $_.shown -eq $true } | Select-Object -First 1
    $runningWhileShown = @($samples | Where-Object { $firstShown -and $_.pt -ge $firstShown.pt + 1 -and $_.running -gt 0 })
    Add-Check 'A-PAUSEVIEW.2.boundaryAt120' 'boundary at 120/1800 <= 2 s after page 10 s (page time from ready.json)' $(if ($t120) { $t120.pt }) ($t120 -and $t120.pt -le 12)
    Add-Check 'A-PAUSEVIEW.2.boundaryAt150' 'boundary at 150/1800 <= 2 s after page 25 s' $(if ($t150) { $t150.pt }) ($t150 -and $t150.pt -le 27)
    Add-Check 'A-PAUSEVIEW.2.noRunningAnimation' 'no running animation while paused' $runningWhileShown.Count ($firstShown -and $runningWhileShown.Count -eq 0)

    # (3) PausedSeek, hidePaused true until 20 s, then false.
    $run = Start-OverlayRun 'A-PAUSEVIEW-3' @{ ObsHidePaused = $true } 'PausedSeek' -NoReader
    $chrome = $null
    try {
        $ready = Wait-BenchReady $run.Root
        $start = Get-ReadyQpc $ready
        if (-not $start) { throw 'A-PAUSEVIEW(3): bench not ready.' }
        $chrome = Start-Chrome 'A-PAUSEVIEW-3'
        [void] (Invoke-ChromeNavigate $chrome $overlayUrl)
        $before = Get-PauseSamples $chrome $start ($start + 20 * $freq)
        [void] (Send-HookCommand $run.Root 'command-obs-hide-paused-off')
        $after = Get-PauseSamples $chrome $start ($start + 30 * $freq)
        $obs['shotSwitch'] = Save-ChromeShot $chrome 'A-PAUSEVIEW-3-after-switch'
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
    $shownBefore = @($before | Where-Object { $_.shown -eq $true })
    $firstAfter = $after | Where-Object { $_.shown -eq $true -and $_.pt -lt 25 } | Select-Object -First 1
    $late = $after | Where-Object { $_.pt -ge 25 -and $_.pt -le 27 -and $null -ne $_.frac -and [Math]::Abs([double] $_.frac - 150 / 1800) -le 0.01 } | Select-Object -First 1
    Add-Check 'A-PAUSEVIEW.3.hiddenBeforeSwitch' 'hidden while hidePaused true' $shownBefore.Count ($shownBefore.Count -eq 0)
    Add-Check 'A-PAUSEVIEW.3.latestSampleOnSwitch' 'when shown after the switch the boundary is at 120/1800 (latest sample, not 60)' $(if ($firstAfter) { Round3 $firstAfter.frac }) (
        $firstAfter -and [Math]::Abs([double] $firstAfter.frac - 120 / 1800) -le 0.01)
    Add-Check 'A-PAUSEVIEW.3.boundaryAt150' 'then 150/1800 <= 2 s after page 25 s' $(if ($late) { $late.pt }) ([bool] $late)
    $scenarioResults['A-PAUSEVIEW'] = $obs
}

# ---------------------------------------------------------------------------------------------------------------
# Runner (serial: every scenario binds the fixed port 47813)

$appVersion = $null
$scenarioErrors = [ordered]@{}
$functions = [ordered]@{
    'A-OFF' = { Test-AOff }; 'A-TIME' = { Test-ATime }; 'A-AD' = { Test-AAd }; 'A-SAME' = { Test-ASame }; 'A-CLOCK' = { Test-AClock }
    'A-GAP' = { Test-AGap }; 'A-INV' = { Test-AInv }; 'A-IDLE' = { Test-AIdle }; 'A-DEMAND' = { Test-ADemand }; 'A-LIVE' = { Test-ALive }
    'A-LIFE' = { Test-ALife }; 'A-SEC' = { Test-ASec }; 'A-RECON' = { Test-ARecon }; 'A-TEXT' = { Test-AText }; 'A-SET' = { Test-ASet }
    'A-PROD' = { Test-AProd }; 'A-PAUSEVIEW' = { Test-APauseView }
}
try {
    if (-not $SkipPublish) {
        & pwsh -NoProfile -File (Join-Path $repo 'scripts/dotnet.ps1') publish (Join-Path $repo 'src/Nativune/Nativune.csproj') `
            --runtime win-x64 --self-contained false -p:DiscordPresenceTestHooks=true -o $appDirectory
        if ($LASTEXITCODE -ne 0) { throw "Hook build publish failed with exit code $LASTEXITCODE." }
        if ('A-PROD' -in $selected) {
            & pwsh -NoProfile -File (Join-Path $repo 'scripts/dotnet.ps1') publish (Join-Path $repo 'src/Nativune/Nativune.csproj') `
                --runtime win-x64 --self-contained false -o $releaseDirectory
            if ($LASTEXITCODE -ne 0) { throw "Release build publish failed with exit code $LASTEXITCODE." }
        }
    }
    if (-not (Test-Path -LiteralPath $appExe -PathType Leaf)) { throw "Hook build not found at $appExe; run without -SkipPublish." }
    $appVersion = (Get-Item -LiteralPath $appExe).VersionInfo.ProductVersion
    foreach ($name in $selected) {
        if (-not (Test-PrefixRegistrable)) {
            Add-Blocked "$name.portFree" "http://localhost:$port/ free before the scenario" 'another process holds the overlay prefix'
            continue
        }
        $t0 = [DateTime]::UtcNow
        $startedBefore = $started.Count; $launchBefore = $script:launchCount
        try { & $functions[$name] } catch {
            Add-Check "$name.runner.completed" 'scenario ran to completion' $_.Exception.Message $false
            $scenarioErrors[$name] = [ordered]@{ message = $_.Exception.Message; scriptStackTrace = $_.ScriptStackTrace }
        } finally {
            foreach ($r in @($readers)) { try { Stop-SseReader $r } catch { } }
            foreach ($c in @($chromes)) { Stop-Chrome $c }
            try { $chromes.Clear() } catch { }
            foreach ($l in @($heldListeners)) { try { Release-Prefix $l } catch { } }
            # Every app this scenario launched, including runas launches only known through their pid file.
            $pids = [Collections.Generic.List[object]]::new()
            for ($i = $startedBefore; $i -lt $started.Count; $i++) {
                $p = $started[$i]
                try { $pids.Add(@{ id = [int] $p.Id; start = $(try { $p.StartTime } catch { $null }) }) } catch { }
            }
            for ($n = $launchBefore + 1; $n -le $script:launchCount; $n++) {
                $pidFile = Join-Path $rootBase "launch-$n.pid.json"
                try { if (Test-Path -LiteralPath $pidFile) { $pids.Add(@{ id = [int] (Get-Content -Raw -LiteralPath $pidFile | ConvertFrom-Json).processId; start = $null }) } } catch { }
            }
            foreach ($entry in $pids) {
                try {
                    $live = Get-Process -Id $entry.id -ErrorAction SilentlyContinue
                    if (-not $live -or $live.HasExited) { continue }
                    # PID reuse guard: the live process must be the one launched (same creation time when known).
                    if ($entry.start -and $live.StartTime -ne $entry.start) { continue }
                    foreach ($id in (Get-ProcessTree $entry.id $rootBase)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
                    [void] $live.WaitForExit(5000)
                } catch { }
            }
            foreach ($process in $started) {
                try { if (-not $process.HasExited) { foreach ($id in (Get-ProcessTree $process.Id $rootBase)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } } } catch { }
            }
            try { [void] (Wait-For { Test-PrefixRegistrable } 10 250) } catch { }
        }
        if ($scenarioResults.Contains($name) -and $scenarioResults[$name] -is [Collections.IDictionary]) {
            $scenarioResults[$name]['wallSeconds'] = [Math]::Round(([DateTime]::UtcNow - $t0).TotalSeconds, 1)
        }
    }
    if ($scenarioErrors.Count -gt 0) { $scenarioResults['errors'] = $scenarioErrors }
} catch {
    Add-Check 'runner.completed' 'harness setup succeeded' $_.Exception.Message $false
    $scenarioResults['error'] = [ordered]@{ message = $_.Exception.Message; scriptStackTrace = $_.ScriptStackTrace }
} finally {
    foreach ($key in @($testEnv.Keys) + $benchEnvKeys) { [Environment]::SetEnvironmentVariable($key, $null, 'Process') }
    foreach ($d in @($aclDenied)) { & icacls.exe $d /remove:d '*S-1-1-0' | Out-Null }
    foreach ($r in @($readers)) { Stop-SseReader $r }
    foreach ($c in @($chromes)) { Stop-Chrome $c }
    foreach ($l in @($heldListeners)) { try { $l.Close() } catch { } }
    foreach ($process in $started) {
        try { if (-not $process.HasExited) { foreach ($id in (Get-ProcessTree $process.Id $rootBase)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } } } catch { }
    }
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine)) {
        if ($p.CommandLine -and $p.CommandLine.Contains($rootBase, [StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
    }
    if (-not $KeepRoot -and (Test-Path -LiteralPath $rootBase)) {
        Start-Sleep -Seconds 1
        Remove-Item -LiteralPath $rootBase -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Every §6.1 row must have produced at least one check; a scenario with none (skipped by an early return) fails.
foreach ($name in $selected) {
    if (-not ($checks | Where-Object { $_.name -like "$name.*" })) { Add-Check "$name.producedChecks" 'at least one check' 0 $false }
}
$failed = @($checks | Where-Object { $_.status -eq 'fail' })
$blocked = @($checks | Where-Object { $_.status -eq 'blocked' })
$passed = $checks.Count -gt 0 -and $failed.Count -eq 0 -and $blocked.Count -eq 0
$report = [ordered]@{
    command = $commandLine; runId = $runId; appVersion = $appVersion; pipePrefix = $prefix; harnessElevated = $isElevated
    launches = @($launches); scenarios = $scenarioResults
    summary = [ordered]@{ pass = @($checks | Where-Object { $_.status -eq 'pass' }).Count; fail = $failed.Count; blocked = $blocked.Count }
    checks = @($checks); passed = [bool] $passed
}
[IO.File]::WriteAllText((Join-Path $runDirectory 'report.json'), ($report | ConvertTo-Json -Depth 12), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $runDirectory 'events.json'), ($eventsByReader | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
$report.summary | ConvertTo-Json
Write-Host "Report: $(Join-Path $runDirectory 'report.json')"
if (-not $passed) { exit 1 }
