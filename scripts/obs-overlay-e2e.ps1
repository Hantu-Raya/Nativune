<#
E2E-A for the opt-in OBS now-playing overlay and the P0 overlay designer transport/store contract (plan v5
`notes/research/obs-overlay-themes-2026-09-29/plan.md` §§8–10; previous overlay plan §6.1 and hook surface design §2.8).
It drives the real app against the repository-local synthetic player page. No OBS, YouTube, Google or Discord request
is involved, except A-PROD's release build, which loads the normal site. A-PROD never clicks the setup-guide button
(that would open the real default browser); it checks the guide URL statically instead.

Regenerate:
  pwsh -NoProfile -File scripts/obs-overlay-e2e.ps1 -Scenario All -OutputDirectory artifacts/obs-overlay
  pwsh -NoProfile -File scripts/obs-overlay-e2e.ps1 -Scenario A-SEC,A-TIME          # a subset
  pwsh -NoProfile -File scripts/obs-overlay-e2e.ps1 -Scenario A-SEC -SkipPublish    # reuse the published builds
  pwsh -NoProfile -File scripts/obs-overlay-e2e.ps1 -Scenario A-PLAIN -CapturePlainBaseline
  pwsh -NoProfile -File scripts/obs-overlay-e2e.ps1 -Scenario A-LOOK -Section fxpaint -SkipPublish
    # Diagnostic only: isolated paint histories, exact frames/layers/traces and fxpaint-summary.json; never a gate.

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
High). Scenarios run serially (the port 47813 is fixed; never run two overlay E2Es at once). The owner's data/ and
installed profile are never touched.

Readers: an SSE reader child process writes events-<name>.jsonl lines
{qpc,utc,kind: open|retry|comment|data|look|close|error,text|json}; a raw TcpClient covers A-SEC/A-LIFE/A-LIVE; the
installed Google Chrome (headless, CDP, --user-data-dir under the run root) checks page behaviour through the DOM
and `window.__state` (absent Chrome -> blocked). App state comes from hook commands and
state-<label>.json (overlay{...}) / diagnostics-<label>.json under <root>/data/discord-bench.

Scenarios (plan v5; `deferred:P1` / `deferred:P2` checks are retained in the report and do not fail the P0 gate):
  A-PLAIN     plain pill pixel identity, 440x96/DPR1 Chrome screenshots at projected positions 8 s/18 s, saved
               baselines/meta, look-first/default options, global hidePaused and ReduceMotion behaviour.
  A-LOOK      P0 pill option rows and geometry, long-text containment, pill cadence, show/hide motion matrix,
               bounded-pump and blocked-write/lifetime backpressure, and exact query grammar. Other themes and
               times-slot rows are generated and reported deferred:P1.
  A-RECON     Chrome error page when off then reload connects; restart after options A→B look-file reload; 30 s without
               streams; 9th-stream 503 then retry after 30 s; lifetime renewal without hiding; lookEpoch changes and
               first post-restart lookSeq 1 is accepted.
  A-STORE-1   whole-file validation/read-only reasons and byte preservation; BOM/future versions, normalization,
               duplicates/quarantine/names/fonts/retired ids, commit/tombstone/cap/fault/downgrade checks.
  A-SAMPLE    synthetic playing/noart/paused phases, 240 s re-anchor during draft pushes and pump hold, real/sample
               isolation, synthetic hidePaused, demand independence, source counts and lifetime phase reset.
  A-SEC       raw request matrix (LAN IPv4 row blocked if none), loopback/Host/Origin/Fetch/method/body guards,
               exact routes/query grammar and headers, current/stale/retired/rotated/closed pv rows, 8 streams + 9th
               503. Preview-host NavigationStarting/window/download/permission handlers are deferred:P2.
  A-PROD      release fallback routes, hook-string scan, stylesheet tokenizer/allowlists, forbidden JavaScript sinks.
  A-OFF       no key / false / true then command-obs-off: prefix registrable by another process, no app response
               on :47813, streams 0, no overlay reads.
  A-TIME      default timeline scored from the initial event through page 143 s, hidePaused true and false, and the
               AdFallback profile: exact semantic event sequence, no other data events, no album canary; privacy:
               no video id, song link or Google URL in any event, opaque 16-hex id (one per track), /art/<key>
               artwork (A and B share one), GET /art/<key> 200 image/png and /art/0000000000000000 404, page CSP
               img-src 'self' only.
  A-AD        Chrome page on the default timeline and AdFallback; hide-when-paused off saved at page 70 s (in the ad):
               pill hidden by 67.5 s, back with A's title by 77.5 s, no data between ad and restore, restore carries
               the new hidePaused.
  A-SAME      IdOnly profile: exactly one new event, only id changed.
  A-CLOCK     command-clock-mismatch-on/off: clock:false, silence until off, then clock:true with a fresh anchor.
  A-GAP       ShortGap (no none), ReaderGap, DomGap, native controls-unavailable (none at gapStartQpc + 8 +-1.2 s;
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
  A-TEXT       Chrome: Text profile literal text + ellipsis, projection within 1 %; ArtSwap sequence guard (final B).
  A-ART        ArtGap profile: a loadable page image the proxy cannot fetch answers 502 (no image, not counted as
               served) and a good key keeps working; the page's failing "missing" artwork is never published.
  A-SET        UI Automation of Settings > OBS (names, live region, Cancel/Save/relaunch, missing key, hide-paused
               broadcast, Copy link, guide URI recorder, Block ads link, keyboard focus, save failure, bind conflict).
  A-PAUSEVIEW  Chrome: paused view (0.7 opacity, frozen fill, no running animations), PausedSeek, hidePaused switch.
  A-TOOLBAR    UI Automation of the toolbar's OBS button (left of the toolbar, after Home): off at launch (name, no
               listener, no red dot); one invoke -> 200 on the port <= 5 s, ObsOverlay=true saved, name
               "OBS overlay: on…", red recording dot in a window-scoped capture; a second invoke reverses all of it;
               five quick invokes end on with exactly one listener.

`-CapturePlainBaseline` runs only A-PLAIN and writes `plain-8s.png`, `plain-18s.png` and `plain-meta.json` under
scripts/fixtures/obs-overlay. It is intentionally explicit because it replaces the committed visual oracle. Normal
A-PLAIN compares against those files (≤ 0.5% of pixels differ by > 8/255 in any channel) and retains diff PNGs.

Report: <OutputDirectory>/<utc>/report.json (each check status pass|fail|blocked|deferred:P1|deferred:P2),
events.json (every reader's lines) and screenshots/. Blocked counts as non-passing; deferred checks are visible with
their phase but do not count as failures. The exit code is 1 if any check fails or is blocked.
#>
[CmdletBinding()]
param(
    # One scenario id, All, or a comma-separated list.
    [string[]] $Scenario = @('All'),
    [string] $OutputDirectory = 'artifacts/obs-overlay',
    [switch] $SkipPublish,
    # Alternate pre-LookFx hook build: fxpaint + SkipPublish only; run FX-free histories, skip FX histories.
    [string] $AppDirectory = 'artifacts/obs-overlay/app',
    [switch] $KeepRoot,
    [switch] $CapturePlainBaseline,
    # Diagnostic wildcard(s) against <theme>.<case>; '*' preserves the full generated matrix.
    [string[]] $LookCase = @('*'),
    # Diagnostic section selector(s) (see scripts/obs-overlay-inventory.ps1); '*' = gate sections, not opt-in fxpaint.
    [string[]] $Section = @('*'),
    # Diagnostic wildcard(s) against A-FRAMES row ids; '*' = the full required matrix.
    [string[]] $FrameRow = @('*'),
    # Resume a previous run directory's journal (scripts/obs-overlay-journal.ps1); strict manifest match required.
    [string] $Resume = '',
    # Static A-LOOK case group size (1 = serial reference behaviour; 2/4 only after validation).
    [ValidateRange(1, 4)] [int] $LookGroup = 1,
    # Coverage profile (notes/plan.md, 3 October fast-gate decision): Fast-v2 = P1 gate; Exhaustive-v1 = release qualification.
    [ValidateSet('Fast-v2', 'Exhaustive-v1')] [string] $GateProfile = 'Exhaustive-v1',
    # Exhaustive-only development rotation slice in covering-array order: '' (all), pairwise, threeway, rest.
    [ValidateSet('', 'pairwise', 'threeway', 'rest')] [string] $Rotation = '',
    # Diagnostic-only grouping red cases, '<theme>.<case>=size|style|route' (requires an explicit -LookCase): size widens
    # the box 7 px, style swaps data-theme, route navigates the page to a sibling look. Each must fail its own case.
    [string[]] $LookRedCase = @()
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$allScenarios = @('A-PLAIN', 'A-LOOK', 'A-OFF', 'A-TIME', 'A-AD', 'A-SAME', 'A-CLOCK', 'A-GAP', 'A-INV', 'A-IDLE', 'A-DEMAND', 'A-LIVE', 'A-LIFE',
    'A-SEC', 'A-RECON', 'A-STORE-1', 'A-SAMPLE', 'A-TEXT', 'A-ART', 'A-SET', 'A-PROD', 'A-PAUSEVIEW', 'A-TOOLBAR', 'A-FRAMES',
    'A-FONT', 'A-STORE-2', 'A-DESIGNER')
$Scenario = @($Scenario | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
# `-File` passes comma lists as one string; normalise every wildcard array parameter like -Scenario.
$LookCase = @($LookCase | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$Section = @($Section | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$FrameRow = @($FrameRow | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$LookRedCase = @($LookRedCase | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
$lookRed = @{}
foreach ($entry in $LookRedCase) {
    if ($entry -notmatch '^([a-z-]+\.[A-Za-z0-9-]+)=(size|style|route)$') { throw "Invalid -LookRedCase '$entry' (expected <theme>.<case>=size|style|route)." }
    $lookRed[$Matches[1]] = $Matches[2]
}
if ($lookRed.Count -and $LookCase.Count -eq 1 -and $LookCase[0] -ceq '*') { throw '-LookRedCase is diagnostic only and requires an explicit -LookCase filter.' }
foreach ($name in $Scenario) {
    if ($name -ne 'All' -and $name -notin $allScenarios) { throw "Unknown scenario '$name'. Valid: All, $($allScenarios -join ', ')." }
}
if ($CapturePlainBaseline -and @($Scenario | Where-Object { $_ -notin @('All', 'A-PLAIN') }).Count -gt 0) {
    throw '-CapturePlainBaseline may be combined only with -Scenario All or -Scenario A-PLAIN.'
}
$selected = if ($CapturePlainBaseline) { @('A-PLAIN') } elseif ('All' -in $Scenario) { $allScenarios } else { @($allScenarios | Where-Object { $_ -in $Scenario }) }
if ('fxpaint' -in $Section -and ($Section.Count -ne 1 -or 'A-LOOK' -notin $selected)) {
    throw '-Section fxpaint is diagnostic only; select it alone with -Scenario A-LOOK (or All).'
}

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$commandLine = 'pwsh -NoProfile -File scripts/obs-overlay-e2e.ps1 ' + (($PSBoundParameters.GetEnumerator() | ForEach-Object {
    if ($_.Value -is [switch]) { if ($_.Value) { "-$($_.Key)" } } else { "-$($_.Key) $(@($_.Value) -join ',')" } }) -join ' ')
$outputRoot = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
$appDirectory = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($AppDirectory)) { $AppDirectory } else { Join-Path $repo $AppDirectory }))
$fxPaintLegacyBuild = -not $appDirectory.Equals([IO.Path]::GetFullPath((Join-Path $repo 'artifacts/obs-overlay/app')), [StringComparison]::OrdinalIgnoreCase)
if ($fxPaintLegacyBuild -and (-not $SkipPublish -or 'fxpaint' -notin $Section)) {
    throw 'An alternate -AppDirectory requires -SkipPublish -Section fxpaint; it runs only FX-free diagnostic histories.'
}
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
$fixtureDirectory = Join-Path $PSScriptRoot 'fixtures/obs-overlay'
$plainBaseline8 = Join-Path $fixtureDirectory 'plain-8s.png'
$plainBaseline18 = Join-Path $fixtureDirectory 'plain-18s.png'
$plainBaselineMeta = Join-Path $fixtureDirectory 'plain-meta.json'
$plainChromeFlags = @('--font-render-hinting=none', '--disable-lcd-text', '--force-color-profile=srgb')
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

# Speed-plan helpers (notes/plan.md, 3 October): row inventory/selectors, run journal/resume, phase telemetry.
. (Join-Path $PSScriptRoot 'obs-overlay-inventory.ps1')
. (Join-Path $PSScriptRoot 'obs-overlay-journal.ps1')
. (Join-Path $PSScriptRoot 'obs-overlay-telemetry.ps1')

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
$script:benchModeByRoot = @{}
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
    $check = [ordered]@{ name = $Name; expected = "$Expected"; observed = $Observed; status = if ($Passed) { 'pass' } else { 'fail' } }
    Add-JournalCheck $check
    $checks.Add($check)
}
function Add-Blocked([string] $Name, $Expected, [string] $Reason) {
    $check = [ordered]@{ name = $Name; expected = "$Expected"; observed = $Reason; status = 'blocked' }
    Add-JournalCheck $check
    $checks.Add($check)
}
function Add-Deferred([string] $Phase, [string] $Name, $Expected, [string] $Reason) {
    if ($Phase -notin @('P1', 'P2')) { throw "Invalid deferred phase '$Phase'." }
    $check = [ordered]@{ name = $Name; expected = "$Expected"; observed = $Reason; status = "deferred:$Phase" }
    Add-JournalCheck $check
    $checks.Add($check)
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
    if (Test-Path -LiteralPath $root) {
        throw "New-Root: destination already exists: '$root'. Preserve the prior evidence and choose a fresh condition/attempt session name."
    }
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $ubolDestination = Join-Path $root '.tools/ubol'
    [IO.Directory]::CreateDirectory($ubolDestination) | Out-Null
    $copyQpc = Get-Qpc; $copyOutcome = 'failure'
    try {
        Copy-Item -LiteralPath $ubolSource -Destination $ubolDestination -Recurse
        $copyOutcome = 'success'
    } finally { Complete-PhaseTiming -Phase 'root.copy' -StartQpc $copyQpc -Extra @{ outcome = $copyOutcome } }
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
# NullString passes an actual CLR null; PowerShell $null binds as an empty string and leaves an environment entry.
foreach ($name in @($spec.unset)) { if ($name) { [Environment]::SetEnvironmentVariable($name, [NullString]::Value, 'Process') } }
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
    $launchQpc = Get-Qpc; $launchOutcome = 'failure'
    try {
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
        foreach ($entry in $environment.GetEnumerator()) {
            if ($null -eq $entry.Value) { [Environment]::SetEnvironmentVariable($entry.Key, [NullString]::Value, 'Process') }
            else { [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process') }
        }
        $process = Start-Process -FilePath $Exe -ArgumentList $arguments -WorkingDirectory $workingDirectory -PassThru
    }
    # Resolve the actual launch environment, including explicit unsets; relaunches replace the root's mode.
    $profileKey = 'NATIVUNE_TEST_DISCORD_BENCH_PROFILE'
    $effectiveProfile = if ($environment.Contains($profileKey)) { $environment[$profileKey] } else {
        [Environment]::GetEnvironmentVariable($profileKey, 'Process') }
    $script:benchModeByRoot[$Root] = [string] $effectiveProfile
    $started.Add($process)
    $integrity = Get-IntegrityName $process.Id
    $adminEnabled = Get-AdminEnabled $process.Id
    $launches.Add([ordered]@{ launch = $script:launchCount; root = [IO.Path]::GetRelativePath($repo, $Root); processId = $process.Id
        viaRunas = $isElevated; adminEnabled = $adminEnabled; integrity = $integrity; helperIntegrity = $helperIntegrity
        release = ($Exe -eq $releaseExe) })
    $process | Add-Member -NotePropertyName Integrity -NotePropertyValue $integrity -Force
    $process | Add-Member -NotePropertyName AdminEnabled -NotePropertyValue $adminEnabled -Force
    $launchOutcome = 'success'
    $process
    } catch {
        if ($_.Exception.Message -like 'runas /trustlevel launch helper wrote no PID file*') { $launchOutcome = 'timeout' }
        throw
    } finally { Complete-PhaseTiming -Phase 'app.launch' -StartQpc $launchQpc -Extra @{ outcome = $launchOutcome; viaRunas = $isElevated } }
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
function Queue-ObsHookCommand([string] $Root, [string] $Name, [string] $Payload = 'go') {
    if ($Name -notmatch '^command-obs-[a-z0-9-]+$') { throw "Invalid OBS hook command name '$Name'." }
    $directory = Get-BenchDirectory $Root
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $path = Join-Path $directory $Name
    if (Test-Path -LiteralPath $path) { return $null }
    $qpc = Get-Qpc
    [IO.File]::WriteAllText($path, $Payload, [Text.UTF8Encoding]::new($false))
    $qpc
}
function Send-ObsHookCommand([string] $Root, [string] $Name, [string] $Payload = 'go') {
    if (-not (Wait-For { -not (Test-Path -LiteralPath (Join-Path (Get-BenchDirectory $Root) $Name)) } 10 25)) { throw "Previous hook command is still pending: $Name." }
    $qpc = Queue-ObsHookCommand $Root $Name $Payload
    if ($null -eq $qpc) { throw "Previous hook command is still pending: $Name." }
    $path = Join-Path (Get-BenchDirectory $Root) $Name
    if (-not (Wait-For { -not (Test-Path -LiteralPath $path) } 10 25)) { throw "Hook command was not consumed: $Name." }
    Start-Sleep -Milliseconds 50
    $qpc
}
function Wait-BenchReady([string] $Root, [double] $Seconds = 90, [string] $BenchProfile = $null) {
    if (-not $PSBoundParameters.ContainsKey('BenchProfile')) {
        if (-not $script:benchModeByRoot.ContainsKey($Root)) { throw "Bench readiness has no recorded launch mode for root $Root." }
        $BenchProfile = $script:benchModeByRoot[$Root]
    }
    $directory = Get-BenchDirectory $Root
    $failedPath = Join-Path $directory 'failed.json'
    $begin = Get-Qpc; $outcome = 'failure'
    try {
        if ($BenchProfile) {
            $readyPath = Join-Path $directory 'ready.json'
            $ready = Wait-For {
                if (Test-Path -LiteralPath $failedPath) { throw "Bench setup failed for $Root; see $failedPath" }
                if (Test-Path -LiteralPath $readyPath) { Get-Content -Raw -LiteralPath $readyPath | ConvertFrom-Json }
            } $Seconds
        } else {
            # Command-only mode never writes ready.json: require a fresh snapshot acknowledgement and listener.
            $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
            $ready = Wait-For {
                if (Test-Path -LiteralPath $failedPath) { throw "Bench setup failed for $Root; see $failedPath" }
                $remaining = ($deadline - [DateTime]::UtcNow).TotalSeconds
                if ($remaining -le 0) { return $null }
                $snapshot = Get-State $Root 'bench-ready' ([Math]::Min(1, $remaining))
                if (Test-Path -LiteralPath $failedPath) { throw "Bench setup failed for $Root; see $failedPath" }
                if ($snapshot -and (Get-Overlay $snapshot 'running') -eq $true) { $snapshot }
            } $Seconds 100
        }
        if (-not $ready) {
            $outcome = 'timeout'
            $expected = if ($BenchProfile) { 'ready.json' } else { 'acknowledged app state with overlay listening' }
            throw "Bench readiness timed out after $Seconds s for $Root; expected $expected."
        }
        if (Test-Path -LiteralPath $failedPath) { throw "Bench setup failed for $Root; see $failedPath" }
        $outcome = 'success'
        return $ready
    } finally {
        Add-PhaseTiming -Phase 'readiness' -Seconds (Get-Seconds $begin (Get-Qpc)) -Extra @{
            mode = if ($BenchProfile) { 'profiled' } else { 'command-only' }; outcome = $outcome }
    }
}
# Requests diagnostics-<label>.json and state-<label>.json; returns { diag, state, overlay } or $null on timeout.
function Get-State([string] $Root, [string] $Tag = 's', [double] $Seconds = 10) {
    $script:labelSeq++
    $label = ('s{0}-{1}' -f $script:labelSeq, ((ConvertTo-SafeName $Tag).ToLowerInvariant())).TrimEnd('-')
    if ($label.Length -gt 32) { $label = $label.Substring(0, 32).TrimEnd('-') }
    $directory = Get-BenchDirectory $Root
    $statePath = Join-Path $directory "state-$label.json"
    $diagPath = Join-Path $directory "diagnostics-$label.json"
    [void] (Send-HookCommand $Root "command-snapshot-$label")
    if (-not (Wait-For { (Test-Path -LiteralPath $statePath) -and (Test-Path -LiteralPath $diagPath) } $Seconds 100)) { return $null }
    $state = Get-Content -Raw -LiteralPath $statePath | ConvertFrom-Json -Depth 16
    $diag = Get-Content -Raw -LiteralPath $diagPath | ConvertFrom-Json -Depth 16
    [pscustomobject]@{ label = $label; state = $state; diag = $diag; overlay = (Get-Prop $state 'overlay'); qpc = [double] (Get-Prop $diag 'boundaryQpc') }
}
function Get-Overlay($Snapshot, [string] $Field) { Get-Prop (Get-Prop $Snapshot 'overlay') $Field }

function Stop-App($Process, [string] $Root, [switch] $Kill) {
    if (-not $Process) { return }
    $forceStop = $false
    if (-not $Process.HasExited) {
        $quitQpc = Get-Qpc; $quitOutcome = 'failure'
        try {
            if (-not $Kill) { try { [void] (Send-HookCommand $Root 'command-quit') } catch { } }
            $forceStop = $Kill -or -not $Process.WaitForExit(8000)
            $quitOutcome = if ($Kill) { 'forced' } elseif ($forceStop) { 'timeout' } else { 'success' }
        } finally { Complete-PhaseTiming -Phase 'app.quitWait' -StartQpc $quitQpc -Extra @{ outcome = $quitOutcome } }
    }
    $cleanupQpc = Get-Qpc; $cleanupOutcome = 'failure'
    try {
        if ($forceStop) {
            foreach ($id in (Get-ProcessTree $Process.Id $Root)) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
        }
        foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId, CommandLine)) {
            if ($p.CommandLine -and $p.CommandLine.Contains($Root, [StringComparison]::OrdinalIgnoreCase)) { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
        }
        $cleanupOutcome = 'success'
    } finally { Complete-PhaseTiming -Phase 'app.cleanup' -StartQpc $cleanupQpc -Extra @{ outcome = $cleanupOutcome; forced = $forceStop } }
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
$eventName = ''
$dataLines = [Collections.Generic.List[string]]::new()
try {
    while ($null -ne ($line = $reader.ReadLine())) {
        if ($line -eq '') {
            if ($dataLines.Count -gt 0) {
                $kind = if ($eventName) { $eventName } else { 'data' }
                Log $kind 'json' ($dataLines -join "`n")
                $dataLines.Clear(); $eventName = ''
            }
        } elseif ($line.StartsWith('data:')) {
            $v = $line.Substring(5); if ($v.StartsWith(' ')) { $v = $v.Substring(1) }; $dataLines.Add($v)
        } elseif ($line.StartsWith('event:')) {
            $eventName = $line.Substring(6).Trim()
        } elseif ($line.StartsWith(':')) { Log 'comment' 'text' $line }
        elseif ($line.StartsWith('retry:')) { Log 'retry' 'text' $line }
        else { Log 'other' 'text' $line }
    }
    if ($dataLines.Count -gt 0) { Log $(if ($eventName) { $eventName } else { 'data' }) 'json' ($dataLines -join "`n") }
    Log 'close' 'text' 'eof'
} catch { Log 'close' 'text' $_.Exception.GetBaseException().Message }
'@

function Start-SseReader([string] $Name, [double] $ConnectSeconds = 120, [string] $Path = '/events') {
    $safe = ConvertTo-SafeName $Name
    $out = Join-Path $runDirectory "events-$safe.jsonl"
    $url = $overlayUrl.TrimEnd('/') + $Path
    $command = "& { $sseReaderScript } -Url '$($url -replace "'", "''")' -Out '$($out -replace "'", "''")' -ConnectSeconds $ConnectSeconds"
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $process = Start-Process -FilePath pwsh -ArgumentList @('-NoProfile', '-EncodedCommand', $encoded) -PassThru -WindowStyle Hidden
    $reader = [pscustomobject]@{ Name = $safe; Path = $out; Url = $url; Process = $process; Stopped = $false }
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
        $o = try { $line | ConvertFrom-Json -Depth 16 } catch { $null }
        if (-not $o) { continue }
        $data = $null
        if ($o.kind -in @('data', 'look')) { $data = try { [string] $o.json | ConvertFrom-Json -Depth 16 } catch { $null } }
        $list.Add([pscustomobject]@{ qpc = [double] $o.qpc; kind = $o.kind; text = (Get-Prop $o 'text'); json = (Get-Prop $o 'json'); data = $data })
    }
    return $list.ToArray()
}
function Get-LookEvents($Events) {
    @(@($Events) | Where-Object { $null -ne $_ -and (Get-Prop $_ 'kind') -eq 'look' -and $null -ne (Get-Prop $_ 'data') })
}
# Only kind=data events with a parsed payload carrying a state; look/open/retry/comment/close/error never count.
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
$ordinaryStreamReleaseSeconds = 12 # Graceful FIN can need two 5 s heartbeats; allow 2 s observation margin.
function Wait-OverlayStreams($Run, [int] $Expected, [string] $Label) {
    $deadline = [DateTime]::UtcNow.AddSeconds($ordinaryStreamReleaseSeconds)
    $snapshot = Wait-For {
        $remaining = ($deadline - [DateTime]::UtcNow).TotalSeconds - 0.1
        if ($remaining -le 0) { return $null }
        $s = Get-State $Run.Root $Label $remaining
        if ((Get-Overlay $s 'streams') -eq $Expected) { $s }
    } $ordinaryStreamReleaseSeconds 100
    if (-not $snapshot) { throw "$($Run.Name): expected $Expected open streams after $Label within $ordinaryStreamReleaseSeconds s." }
    $snapshot
}
function Wait-SseOpen($Reader, [double] $Seconds = 30) {
    Wait-For { @(@(Read-Sse $Reader) | Where-Object { $null -ne $_ -and $_.kind -eq 'open' }) | Select-Object -First 1 } $Seconds
}
function Wait-SseData($Reader, [scriptblock] $Predicate, [double] $Seconds, [double] $AfterQpc = 0) {
    Wait-For { Get-DataEvents (Read-Sse $Reader) | Where-Object { $null -ne $_ -and $_.qpc -gt $AfterQpc -and (& $Predicate $_.data) } | Select-Object -First 1 } $Seconds
}
function Wait-SseLook($Reader, [scriptblock] $Predicate, [double] $Seconds, [double] $AfterQpc = 0) {
    Wait-For { Get-LookEvents (Read-Sse $Reader) | Where-Object { $_.qpc -gt $AfterQpc -and (& $Predicate $_.data) } | Select-Object -First 1 } $Seconds
}
# The stream's id is an opaque per-session key, never the video ID, so fixture tracks are recognised by their title.
$script:fixtureTitles = @{ fixtureSngA = 'Fixture Song A'; fixtureSngB = 'Fixture Song B'; fixtureSngC = 'Fixture Song C' }
function Test-Data($D, [string] $State, [string] $Id = $null) { (Get-Prop $D 'state') -eq $State -and (-not $Id -or (Get-Prop $D 'title') -eq $script:fixtureTitles[$Id]) }
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
# Opens a raw SSE stream; `-NoRead` keeps a tiny receive window. `Path` supports exact `/events` grammar cases.
function Open-RawStream([string] $Address = '127.0.0.1', [switch] $NoRead, [string] $Path = '/events') {
    $ip = [Net.IPAddress]::Parse($Address)
    $client = [Net.Sockets.TcpClient]::new($ip.AddressFamily)
    if ($NoRead) { $client.ReceiveBufferSize = 1024 }
    $openQpc = Get-Qpc
    $client.ConnectAsync($ip, $port).Wait(3000) | Out-Null
    $stream = $client.GetStream(); $stream.ReadTimeout = 3000
    $bytes = [Text.Encoding]::ASCII.GetBytes((New-Request -Path $Path -KeepAlive))
    $stream.Write($bytes, 0, $bytes.Length); $stream.Flush()
    # Read one byte at a time through the header terminator so a coalesced SSE packet is not discarded.
    $ms = [IO.MemoryStream]::new(); $one = [byte[]]::new(1)
    while ($ms.Length -lt 65536) {
        $n = try { $stream.Read($one, 0, 1) } catch { -1 }
        if ($n -le 0) { break }
        $ms.WriteByte($one[0])
        if ($ms.Length -ge 4) {
            $b = $ms.ToArray()
            if ($b[$b.Length - 4] -eq 13 -and $b[$b.Length - 3] -eq 10 -and $b[$b.Length - 2] -eq 13 -and $b[$b.Length - 1] -eq 10) { break }
        }
    }
    $parsed = ConvertFrom-RawResponse $ms.ToArray()
    [pscustomobject]@{ Client = $client; Stream = $stream; Status = $parsed.status; Headers = $parsed.headers; OpenQpc = $openQpc; Path = $Path }
}
function Close-RawStream($Raw) { if ($Raw) { try { $Raw.Client.Close() } catch { } } }

# ---------------------------------------------------------------------------------------------------------------
# Chrome over CDP

$chromeProbeJs = @'
(() => {
  const s = window.__state ? Object.assign({}, window.__state) : null;
  const root = document.documentElement, pill = document.getElementById('pill'), clip = document.getElementById('clip');
  const bar = document.getElementById('bar'), barfill = document.getElementById('barfill'), column = document.getElementById('column');
  const t = document.getElementById('title'), a = document.getElementById('artist');
  const artistStyle = a ? getComputedStyle(a) : null;
  const cs = pill ? getComputedStyle(pill) : null, titleStyle = t ? getComputedStyle(t) : null;
  let frac = null, clipPx = null;
  if (bar && barfill && getComputedStyle(bar).display !== 'none' && bar.getBoundingClientRect().width > 0 &&
      root.getAttribute('data-theme') !== 'pill') {
    const m = new DOMMatrixReadOnly(getComputedStyle(barfill).transform);
    const barWidth = bar.getBoundingClientRect().width;
    clipPx = barfill.getBoundingClientRect().width + m.m41;
    frac = clipPx / barWidth;
  } else if (root.getAttribute('data-theme') === 'pill' && clip) {
    const m = new DOMMatrixReadOnly(getComputedStyle(clip).transform);
    clipPx = m.m41; frac = m.m41 / (clip.offsetWidth || 400);
  }
  const anims = document.getAnimations().map(x => ({
    playState: x.playState, currentTime: x.currentTime, duration: x.effect ? x.effect.getTiming().duration : null,
    keyframes: x.effect ? x.effect.getKeyframes().map(k => ({ opacity: k.opacity ?? null, transform: k.transform ?? null })) : []
  }));
  return JSON.stringify({
    href: location.href, s, opacity: pill ? Number(cs.opacity) : null, frac, clipPx, pageNow: performance.now(),
    nativeFixture: typeof msg === 'undefined' || msg === null ? null : { duration: msg.duration, rate: msg.rate, clock: msg.clock,
      requestedArt: typeof artUrl === 'undefined' ? null : artUrl, loadedArt: typeof artImgUrl === 'undefined' ? null : artImgUrl,
      projectedPosition: typeof projected === 'function' ? projected() : null },
    boxRect: pill ? (() => { const r = pill.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height }; })() : null,
    pageSize: { width: innerWidth, height: innerHeight, dpr: devicePixelRatio },
    // Pill's track is the full grey reveal plane: its countertranslation cancels #clip's moving boundary.
    // Measure that DOM rect independently of frac; #bar is inside the pill's hidden #bottom slot.
    geometry: Object.fromEntries([['column', column], ['bar', root.getAttribute('data-theme') === 'pill' ? (root.getAttribute('data-show-progress') === 'true' ? document.getElementById('grey') : null) : bar]].map(([name, element]) => {
      if (!element) return [name, null];
      const r = element.getBoundingClientRect();
      return [name, { x: r.x, y: r.y, width: r.width, height: r.height, display: getComputedStyle(element).display }];
    })),
    css: cs ? { width: cs.width, height: cs.height, radius: cs.borderRadius, shadow: cs.boxShadow, color: cs.color,
      font: cs.fontFamily, align: cs.textAlign, textShadow: cs.textShadow, k: cs.getPropertyValue('--k').trim(),
      w: cs.getPropertyValue('--w').trim(), fg: cs.getPropertyValue('--fg').trim(), bg: cs.getPropertyValue('--bg').trim(),
      bgAlpha: cs.getPropertyValue('--bg-a').trim(), fontVar: cs.getPropertyValue('--font').trim() } : null,
    attrs: root ? { theme: root.getAttribute('data-theme'), colours: root.getAttribute('data-colours'),
      showArt: root.getAttribute('data-show-art'), showArtist: root.getAttribute('data-show-artist'),
      showProgress: root.getAttribute('data-show-progress'), showTimes: root.getAttribute('data-show-times'),
      paused: root.getAttribute('data-paused'), animShow: root.getAttribute('data-anim-show'), animHide: root.getAttribute('data-anim-hide') } : null,
    title: t ? t.textContent : null, artist: a ? a.textContent : null, titleChildren: t ? t.children.length : null,
    elapsed: document.getElementById('elapsed')?.textContent ?? null,
    duration: document.getElementById('duration')?.textContent ?? null,
    titleEllipsis: t ? (titleStyle.textOverflow === 'ellipsis' && t.scrollWidth > t.clientWidth) : null,
    titleRect: t ? (() => { const r = t.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height, scrollWidth: t.scrollWidth, clientWidth: t.clientWidth, textOverflow: titleStyle.textOverflow }; })() : null,
    artistRect: a ? (() => { const r = a.getBoundingClientRect(); return { x: r.x, y: r.y, width: r.width, height: r.height, display: artistStyle.display }; })() : null,
    running: anims.filter(x => x.playState === 'running').length, animations: anims.length, animationDetails: anims,
    reducedMotionMedia: matchMedia('(prefers-reduced-motion: reduce)').matches,
    resources: performance.getEntriesByType('resource').map(e => { const u = new URL(e.name); return { origin: u.origin, path: u.pathname }; }),
    art: performance.getEntriesByType('resource').filter(e => /\/art\/(?:[0-9a-f]{16}|sample)$/.test(new URL(e.name).pathname))
      .map(e => ({ name: new URL(e.name).pathname, start: e.startTime, end: e.responseEnd }))
  });
})()
'@

function Start-Chrome([string] $Name, [switch] $Plain) {
    $startQpc = Get-Qpc; $startOutcome = 'failure'
    $phase = ''; $phaseQpc = $startQpc; $phaseOutcome = 'failure'
    try {
    $dir = Join-Path $rootBase "chrome-$(ConvertTo-SafeName $Name)"
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $arguments = @('--headless=new', '--remote-debugging-port=0', "--user-data-dir=$dir", '--no-first-run',
        '--no-default-browser-check', '--disable-extensions', '--disable-background-networking', '--window-size=440,96')
    if ($Plain) { $arguments += $plainChromeFlags; $arguments += '--force-device-scale-factor=1' }
    $arguments += 'about:blank'
    $process = Start-Process -FilePath $chromeExe -PassThru -ArgumentList $arguments
    $portFile = Join-Path $dir 'DevToolsActivePort'
    $phase = 'chrome.devtoolsWait'; $phaseQpc = Get-Qpc
    if (-not (Wait-For { Test-Path -LiteralPath $portFile } 30)) {
        $phaseOutcome = 'timeout'; $startOutcome = 'timeout'
        throw 'Chrome wrote no DevToolsActivePort.'
    }
    $phaseOutcome = 'success'
    Complete-PhaseTiming -Phase $phase -StartQpc $phaseQpc -Extra @{ outcome = $phaseOutcome }
    $phase = ''
    $cdpPort = [int] ((Get-Content -LiteralPath $portFile | Select-Object -First 1).Trim())
    $phase = 'chrome.pageDiscovery'; $phaseQpc = Get-Qpc; $phaseOutcome = 'failure'
    $page = Wait-For { Invoke-RestMethod -NoProxy -Uri "http://127.0.0.1:$cdpPort/json/list" | ForEach-Object { $_ } | Where-Object { $null -ne $_ -and $_.type -eq 'page' } | Select-Object -First 1 } 15
    $phaseOutcome = if ($page) { 'success' } else { 'timeout' }
    if (-not $page) { $startOutcome = 'timeout' }
    Complete-PhaseTiming -Phase $phase -StartQpc $phaseQpc -Extra @{ outcome = $phaseOutcome }
    $phase = 'chrome.cdpSetup'; $phaseQpc = Get-Qpc; $phaseOutcome = 'failure'
    $ws = [Net.WebSockets.ClientWebSocket]::new()
    # GetResult() on a non-generic Task surfaces a VoidTaskResult in PowerShell; it must not leak into the output.
    [void] $ws.ConnectAsync([Uri] $page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $chrome = [pscustomobject]@{ Name = $Name; Process = $process; Ws = $ws; Next = 0; Dir = $dir; CdpPort = $cdpPort; Plain = [bool] $Plain; TargetId = [string] $page.id; Events = [Collections.Generic.List[object]]::new() }
    [void] $chromes.Add($chrome)
    [void] (Invoke-Cdp $chrome 'Page.enable')
    # --window-size includes browser chrome; tiny outer windows can have a 1 px content viewport.
    Set-PlainViewport $chrome
    $phaseOutcome = 'success'; $startOutcome = 'success'
    return $chrome
    } finally {
        if ($phase) { Complete-PhaseTiming -Phase $phase -StartQpc $phaseQpc -Extra @{ outcome = $phaseOutcome } }
        Complete-PhaseTiming -Phase 'chrome.start' -StartQpc $startQpc -Extra @{ outcome = $startOutcome; plain = [bool] $Plain }
    }
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
        $method = Get-Prop $message 'method'
        if ($method -like 'LayerTree.*' -or $method -eq 'Tracing.tracingComplete' -or $method -eq 'Network.loadingFailed' -or
            ($method -eq 'Network.responseReceived' -and (Get-Prop (Get-Prop $message 'params') 'type') -eq 'EventSource')) {
            $Chrome.Events.Add($message)
        }
        if ((Get-Prop $message 'id') -eq $id) {
            $err = Get-Prop $message 'error'
            if ($err) { throw "CDP $Method failed: $(Get-Prop $err 'message')" }
            return (Get-Prop $message 'result')
        }
    }
}
function Invoke-ChromeNavigate($Chrome, [string] $Url) { Invoke-Cdp $Chrome 'Page.navigate' @{ url = $Url } }
function Reset-ChromeCasePage($Chrome) {
    # A Page.navigate ACK does not prove unload: history/BFCache may retain the old document.
    # Destroy the exact owned target, keeping a new blank target alive for the next case.
    $oldTarget = $Chrome.TargetId
    $created = Invoke-Cdp $Chrome 'Target.createTarget' @{ url = 'about:blank' }
    $newTarget = [string] (Get-Prop $created 'targetId')
    if (-not $newTarget) { throw 'Chrome did not create the next case target.' }
    $page = Wait-For {
        Invoke-RestMethod -NoProxy -Uri "http://127.0.0.1:$($Chrome.CdpPort)/json/list" |
            ForEach-Object { $_ } | Where-Object { $_.id -eq $newTarget } | Select-Object -First 1
    } 5 50
    if (-not $page) { throw "Chrome target $newTarget was not exposed." }
    $ws = [Net.WebSockets.ClientWebSocket]::new()
    [void] $ws.ConnectAsync([Uri] $page.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $oldWs = $Chrome.Ws
    $Chrome.Ws = $ws; $Chrome.Next = 0; $Chrome.TargetId = $newTarget
    try {
        [void] (Invoke-Cdp $Chrome 'Page.enable')
        $closed = Invoke-Cdp $Chrome 'Target.closeTarget' @{ targetId = $oldTarget }
        if ((Get-Prop $closed 'success') -ne $true) { throw "Chrome refused to close target $oldTarget." }
        $gone = Wait-For {
            $targets = @(Invoke-RestMethod -NoProxy -Uri "http://127.0.0.1:$($Chrome.CdpPort)/json/list" | ForEach-Object { $_ })
            @($targets | Where-Object { $_.id -eq $oldTarget }).Count -eq 0
        } 5 50
        if (-not $gone) { throw "Chrome target $oldTarget survived closeTarget." }
        Set-PlainViewport $Chrome
        [ordered]@{ oldTarget = $oldTarget; newTarget = $newTarget; closeSucceeded = $true; oldTargetGone = $true }
    } finally { $oldWs.Dispose() }
}
function Get-PageProbe($Chrome) {
    $result = Invoke-Cdp $Chrome 'Runtime.evaluate' @{ expression = $chromeProbeJs; returnByValue = $true }
    $value = Get-Prop (Get-Prop $result 'result') 'value'
    $probe = if ($value) { $value | ConvertFrom-Json -Depth 16 } else { [pscustomobject]@{
        href = $null; s = $null; opacity = $null; frac = $null; clipPx = $null; title = $null; artist = $null
        titleChildren = $null; titleEllipsis = $null; running = $null; animations = $null; animationDetails = @(); art = @(); resources = @()
    } }
    $probe | Add-Member -NotePropertyName qpc -NotePropertyValue (Get-Qpc) -Force
    $probe
}
function Get-PageField($Probe, [string] $Field) { Get-Prop (Get-Prop $Probe 's') $Field }
function Get-ChromeVersion($Chrome) {
    $result = Invoke-Cdp $Chrome 'Browser.getVersion'
    $product = [string] (Get-Prop $result 'product')
    $match = [regex]::Match($product, '(?:Chrome|Chromium)/([0-9]+(?:\.[0-9]+){0,3})')
    [pscustomobject]@{ product = $product; version = if ($match.Success) { $match.Groups[1].Value } else { $null }
        major = if ($match.Success) { [int] ($match.Groups[1].Value -split '\.')[0] } else { $null } }
}
$script:defaultThemeSizes = $null
function Get-DefaultThemeSize([string] $Theme) {
    if (-not $script:defaultThemeSizes) {
        $rows = (Get-Content -Raw (Join-Path $fixtureDirectory 'expected-sizes.json') |
            ConvertFrom-Json -AsHashtable -Depth 16).rows
        $script:defaultThemeSizes = @{}
        foreach ($row in $rows) {
            if ($row.default -and $row.scale -eq 100 -and -not $script:defaultThemeSizes.ContainsKey($row.theme)) {
                $script:defaultThemeSizes[$row.theme] = $row
            }
        }
    }
    $result = $script:defaultThemeSizes[$Theme]
    if (-not $result) { throw "Missing expected default size for $Theme" }
    $result
}
function Set-OverlayViewport($Chrome, $Source) {
    $w = [int] (Get-Prop $Source 'w'); $h = [int] (Get-Prop $Source 'h')
    if ($w -le 0 -or $h -le 0) { throw "Invalid independent source dimensions $w x $h" }
    [void] (Invoke-Cdp $Chrome 'Emulation.setDeviceMetricsOverride' @{ width = $w; height = $h; deviceScaleFactor = 1; mobile = $false })
}
function Test-OverlayViewport($Page, $Source) {
    if (-not $Page -or -not $Page.pageSize -or -not $Page.boxRect) { return $false }
    $w = [double] (Get-Prop $Source 'w'); $h = [double] (Get-Prop $Source 'h'); $r = $Page.boxRect
    [double] $Page.pageSize.width -eq $w -and [double] $Page.pageSize.height -eq $h -and
        [double] $r.x -ge -1 -and [double] $r.y -ge -1 -and
        [double] $r.x + [double] $r.width -le $w + 1 -and
        [double] $r.y + [double] $r.height -le $h + 1
}
function Set-PlainViewport($Chrome) {
    Set-OverlayViewport $Chrome @{ w = 440; h = 96 }
}
function Test-ThemeRaster($Raster, [string] $Theme, $Options, $Size) {
    $boxW = [double] $Size.box.w; $boxH = [double] $Size.box.h
    $panelW = [double] $Size.raster.css.w
    $blurred = $Theme -eq 'pill' -or ($Theme -in @('standard', 'classic', 'card') -and $Options.colours -eq 'auto')
    $scale = if ($Theme -eq 'pill' -or -not $blurred) { 1.0 } else {
        [Math]::Min(1.0, [Math]::Sqrt(100000.0 / ($panelW * $boxH)))
    }
    $expected = $Size.raster
    $actual = [ordered]@{ colour = Get-Prop $Raster 'colour'; grey = Get-Prop $Raster 'grey' }
    $areas = [ordered]@{}; $dimensions = $true
    foreach ($name in @('colour', 'grey')) {
        $r = $actual[$name]; $e = $expected[$name]
        $w = [int] (Get-Prop $r 'w'); $h = [int] (Get-Prop $r 'h')
        $areas[$name] = $w * $h
        $dimensions = $dimensions -and [Math]::Abs($w - $e.w) -le 1 -and
            [Math]::Abs($h - $e.h) -le 1 -and $areas[$name] -gt 0 -and $areas[$name] -le 100000
    }
    $sharedScale = if ($blurred -and $Theme -in @('standard', 'classic', 'card')) {
        $w = [double] (Get-Prop $actual.colour 'w'); $h = [double] (Get-Prop $actual.colour 'h')
        [Math]::Abs($w - $panelW * $scale) -le 1 -and
            [Math]::Abs($h - $boxH * $scale) -le 1 -and
            [Math]::Abs($w / $panelW - $h / $boxH) -le [Math]::Max(1 / $panelW, 1 / $boxH)
    } else { $true }
    $cover = Get-Prop $Raster 'cover'
    $coverOk = $null -eq $cover -or ([int] (Get-Prop $cover 'w') -gt 0 -and [int] (Get-Prop $cover 'h') -gt 0 -and
        [int] (Get-Prop $cover 'w') -le 1024 -and [int] (Get-Prop $cover 'h') -le 1024)
    [ordered]@{ pass = $dimensions -and $sharedScale -and $coverOk -and
        [Math]::Abs([double] $expected.scale - $scale) -le 0.000001
        expected = $expected; actual = $actual; cover = $cover; coverOk = $coverOk; areas = $areas
        panelW = $panelW; boxH = $boxH; scale = $scale; sharedScale = $sharedScale }
}

function Get-ChromeShotBytes($Chrome) {
    $shot = Invoke-Cdp $Chrome 'Page.captureScreenshot' @{ format = 'png'; fromSurface = $true }
    [Convert]::FromBase64String([string] $shot.data)
}
function Save-ChromeShot($Chrome, [string] $Name) {
    try {
        $file = Join-Path $shotDirectory "$(ConvertTo-SafeName $Name).png"
        [IO.File]::WriteAllBytes($file, (Get-ChromeShotBytes $Chrome))
        [IO.Path]::GetRelativePath($runDirectory, $file)
    } catch { $null }
}
function Compress-FrameTrace([string] $Path) {
    $compressed = "$Path.gz"
    $partial = "$compressed.part"
    try {
        $inputStream = [IO.File]::OpenRead($Path)
        try {
            $outputStream = [IO.File]::Create($partial)
            try {
                $gzip = [IO.Compression.GZipStream]::new($outputStream, [IO.Compression.CompressionLevel]::Optimal, $true)
                try { $inputStream.CopyTo($gzip) } finally { $gzip.Dispose() }
            } finally { $outputStream.Dispose() }
        } finally { $inputStream.Dispose() }
        [IO.File]::Move($partial, $compressed, $true)
        [IO.File]::Delete($Path)
        [IO.Path]::GetRelativePath($runDirectory, $compressed)
    } catch {
        if (Test-Path -LiteralPath $partial) { [IO.File]::Delete($partial) }
        throw
    }
}
function Keep-FrameTrace($Trace) {
    if ($Trace -and $Trace.traceRetention -eq 'raw') {
        $Trace.trace = Compress-FrameTrace (Join-Path $runDirectory $Trace.trace)
        $Trace.traceRetention = 'gzip'
    }
}
function Save-FrameTraceRecord([string] $Label, $Record, [bool] $Passed) {
    $trace = $Record.trace
    if (-not $Passed) {
        Keep-FrameTrace $trace
        return Save-FrameRecord $Label $Record
    }
    # Persist all measured/audit fields (including original byte count and hash) before discarding raw data.
    $rawPath = Join-Path $runDirectory $trace.trace
    $trace.trace = $null
    $trace.traceRetention = 'discarded'
    try {
        $artifact = Save-FrameRecord $Label $Record
        [IO.File]::Delete($rawPath)
        return $artifact
    } catch {
        $trace.trace = [IO.Path]::GetRelativePath($runDirectory, $rawPath)
        $trace.traceRetention = 'raw'
        Keep-FrameTrace $trace
        [void] (Save-FrameRecord $Label $Record)
        throw
    }
}

function Initialize-FrameTraceReader {
    if ('ObsFrameTraceReader' -as [type]) { return }
    Add-Type @'
using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Text.Json;

public sealed class ObsFrameTraceName {
    public string Name { get; set; }
    public int Count { get; set; }
}
public sealed class ObsFrameTraceSummary {
    public int Frames { get; set; }
    public List<ObsFrameTraceName> Names { get; } = new List<ObsFrameTraceName>();
}
public static class ObsFrameTraceReader {
    // Utf8JsonReader needs an entire token, but never holds the trace or an event tree in memory.
    // Reject a single >4 MiB token instead of growing indefinitely; the raw trace is retained on error.
    public static ObsFrameTraceSummary Parse(string path) {
        var names = new Dictionary<string, int>(StringComparer.OrdinalIgnoreCase);
        var timestamps = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        bool root = false, sawEvents = false, endedEvents = false, expectEvents = false, inEvents = false, inEvent = false;
        string field = null, cat = null, name = null, phase = null, timestamp = null;
        var buffer = new byte[65536];
        int valid = 0;
        bool final = false;
        JsonReaderState state = default;
        using (var stream = File.OpenRead(path)) {
            while (true) {
                if (!final) {
                    if (valid == buffer.Length) {
                        if (buffer.Length >= 4 * 1024 * 1024)
                            throw new InvalidDataException("CDP frame trace has a JSON token over 4 MiB");
                        Array.Resize(ref buffer, buffer.Length * 2);
                    }
                    int count = stream.Read(buffer, valid, buffer.Length - valid);
                    valid += count;
                    final = count == 0;
                }
                var reader = new Utf8JsonReader(new ReadOnlySpan<byte>(buffer, 0, valid), final, state);
                while (reader.Read()) {
                    int depth = reader.CurrentDepth;
                    JsonTokenType token = reader.TokenType;
                    if (token == JsonTokenType.StartObject && depth == 0) root = true;
                    if (token == JsonTokenType.PropertyName && depth == 1) {
                        expectEvents = reader.ValueTextEquals("traceEvents");
                        continue;
                    }
                    if (expectEvents) {
                        if (token != JsonTokenType.StartArray || depth != 1)
                            throw new InvalidDataException("CDP frame trace traceEvents is not an array");
                        sawEvents = true; inEvents = true; expectEvents = false;
                        continue;
                    }
                    if (inEvents && token == JsonTokenType.EndArray && depth == 1) {
                        inEvents = false; endedEvents = true;
                        continue;
                    }
                    if (!inEvents) continue;
                    if (token == JsonTokenType.StartObject && depth == 2) {
                        inEvent = true; field = cat = name = phase = timestamp = null;
                        continue;
                    }
                    if (token == JsonTokenType.EndObject && depth == 2 && inEvent) {
                        if (cat != null && cat.Contains("devtools.timeline.frame", StringComparison.OrdinalIgnoreCase)) {
                            string eventName = name ?? "";
                            names.TryGetValue(eventName, out int existingCount);
                            names[eventName] = existingCount + 1;
                            if (string.Equals(name, "EndActivateToSubmitCompositorFrame", StringComparison.OrdinalIgnoreCase) &&
                                string.Equals(phase, "e", StringComparison.OrdinalIgnoreCase))
                                timestamps.Add(timestamp ?? "");
                        }
                        inEvent = false;
                        continue;
                    }
                    if (!inEvent) continue;
                    if (token == JsonTokenType.PropertyName && depth == 3) {
                        field = reader.GetString();
                        continue;
                    }
                    if (depth != 3 || field == null) continue;
                    string value = token == JsonTokenType.String ? reader.GetString() :
                        token == JsonTokenType.Number ? (reader.TryGetInt64(out long integer) ?
                            integer.ToString(CultureInfo.CurrentCulture) : reader.GetDouble().ToString(CultureInfo.CurrentCulture)) : null;
                    switch (field) {
                        case "cat": cat = value; break;
                        case "name": name = value; break;
                        case "ph": phase = value; break;
                        case "ts": timestamp = value; break;
                    }
                    field = null;
                }
                int consumed = checked((int)reader.BytesConsumed);
                state = reader.CurrentState;
                valid -= consumed;
                if (valid != 0) Buffer.BlockCopy(buffer, consumed, buffer, 0, valid);
                if (final) {
                    if (valid != 0) throw new InvalidDataException("CDP frame trace has an incomplete JSON token");
                    break;
                }
            }
        }
        if (!root || !sawEvents || !endedEvents) throw new InvalidDataException("CDP frame trace has no complete traceEvents array");
        var result = new ObsFrameTraceSummary { Frames = timestamps.Count };
        foreach (var pair in names) result.Names.Add(new ObsFrameTraceName { Name = pair.Key, Count = pair.Value });
        return result;
    }
}
'@
}

function Invoke-FrameTrace($Chrome, [string] $Name, [int] $Seconds, [scriptblock] $During = $null,
    [string] $Categories = '-*,disabled-by-default-devtools.timeline.frame', [switch] $PreserveLayerEvents) {
    $path = Join-Path $runDirectory "trace-$(ConvertTo-SafeName $Name).json"
    $initialLayers = if ($PreserveLayerEvents) { @($Chrome.Events | Where-Object { $_.method -like 'LayerTree.*' }) } else { @() }
    $Chrome.Events.Clear()
    foreach ($event in $initialLayers) { $Chrome.Events.Add($event) }
    [void] (Invoke-Cdp $Chrome 'Tracing.start' @{
        categories = $Categories; transferMode = 'ReturnAsStream'
        options = 'record-continuously'
    })
    $begin = Get-Qpc
    if ($During) { & $During }
    Wait-UntilQpc ($begin + $Seconds * $freq)
    $end = Get-Qpc
    $endPage = Get-PageProbe $Chrome
    $traceEndBegin = Get-Qpc; $traceEndOutcome = 'failure'
    try {
        [void] (Invoke-Cdp $Chrome 'Tracing.end' @{} 30)
        $complete = Wait-For {
            [void] (Invoke-Cdp $Chrome 'Runtime.evaluate' @{ expression = 'true' } 30)
            $Chrome.Events | Where-Object { $_.method -eq 'Tracing.tracingComplete' } | Select-Object -Last 1
        } 30 100
        if (-not $complete) { $traceEndOutcome = 'timeout'; throw "CDP Tracing.tracingComplete missing for $Name" }
        $handle = [string] (Get-Prop (Get-Prop $complete 'params') 'stream')
        if (-not $handle) { throw "CDP Tracing stream missing for $Name" }
        $traceEndOutcome = 'success'
    } finally {
        Add-PhaseTiming -Phase 'trace-end' -Seconds (Get-Seconds $traceEndBegin (Get-Qpc)) -Extra @{ trace = $Name; outcome = $traceEndOutcome }
    }
    try {
        $drainBegin = Get-Qpc; $hashSeconds = 0.0; $drainOutcome = 'failure'
        $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
        try {
            $file = [IO.File]::Create($path)
            try {
                do {
                    $chunk = Invoke-Cdp $Chrome 'IO.read' @{ handle = $handle; size = 1048576 } 30
                    [byte[]] $bytes = if ($chunk.base64Encoded) { ,([Convert]::FromBase64String([string] $chunk.data)) } else { ,([Text.Encoding]::UTF8.GetBytes([string] $chunk.data)) }
                    $file.Write($bytes, 0, $bytes.Length)
                    $hashBegin = Get-Qpc
                    $hash.AppendData($bytes, 0, $bytes.Length)
                    $hashSeconds += Get-Seconds $hashBegin (Get-Qpc)
                } until ($chunk.eof)
                $hashBegin = Get-Qpc
                $rawSha256 = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
                $hashSeconds += Get-Seconds $hashBegin (Get-Qpc)
                $drainOutcome = 'success'
            } finally { $file.Dispose() }
        } finally {
            $hash.Dispose()
            try { [void] (Invoke-Cdp $Chrome 'IO.close' @{ handle = $handle }) } finally {
                Add-PhaseTiming -Phase 'drain' -Seconds ([Math]::Max(0, (Get-Seconds $drainBegin (Get-Qpc)) - $hashSeconds)) -Extra @{ trace = $Name; outcome = $drainOutcome }
                Add-PhaseTiming -Phase 'hash' -Seconds $hashSeconds -Extra @{ trace = $Name; outcome = $drainOutcome; incremental = $true }
            }
        }
        $rawBytes = ([IO.FileInfo] $path).Length
        $parseBegin = Get-Qpc; $parseOutcome = 'failure'
        try {
            Initialize-FrameTraceReader
            $summary = [ObsFrameTraceReader]::Parse($path)
            $parseOutcome = 'success'
        } finally {
            Add-PhaseTiming -Phase 'parse' -Seconds (Get-Seconds $parseBegin (Get-Qpc)) -Extra @{ trace = $Name; outcome = $parseOutcome }
        }
        $names = @($summary.Names | Sort-Object Name | Sort-Object Count -Descending | Select-Object -First 30 |
            ForEach-Object { [ordered]@{ name = $_.Name; count = $_.Count } })
        # Count completed compositor submission spans, not begin-frame requests or timer ticks.
        $frames = $summary.Frames
        [ordered]@{ trace = [IO.Path]::GetRelativePath($runDirectory, $path); rawBytes = $rawBytes
            rawSha256 = $rawSha256; traceRetention = 'raw'; frames = $frames
            seconds = [Math]::Round((Get-Seconds $begin $end), 3); fps = [Math]::Round($frames / (Get-Seconds $begin $end), 3)
            frameEvent = 'EndActivateToSubmitCompositorFrame:e'; categories = $Categories; names = $names
            visible = [bool] (Get-PageField $endPage 'shown'); endPage = $endPage }
    } catch {
        $errorText = $_.Exception.Message
        if (Test-Path -LiteralPath $path) {
            $retained = try { Compress-FrameTrace $path } catch { [IO.Path]::GetRelativePath($runDirectory, $path) }
            throw "Frame trace $Name failed; raw evidence retained at $retained; $errorText"
        }
        throw "Frame trace $Name failed before raw evidence was written; $errorText"
    }
}
# Kills every chrome.exe whose command line carries this instance's --user-data-dir, plus the launched
# process tree. Never throws.
function Stop-Chrome($Chrome) {
    $stopQpc = $null; $stopExtra = @{}
    try {
        if ($null -eq $Chrome) { return }
        $stopQpc = Get-Qpc
        try { $ws = Get-Prop $Chrome 'Ws'; if ($ws) { $ws.Dispose() } } catch { }
        $dir = [string] (Get-Prop $Chrome 'Dir')
        $proc = Get-Prop $Chrome 'Process'
        $rootId = try { if ($proc) { [int] $proc.Id } else { 0 } } catch { 0 }
        for ($pass = 0; $pass -lt 3; $pass++) {
            $passQpc = Get-Qpc; $passExtra = @{ pass = $pass + 1 }
            try {
            $enumerated = $false
            $all = @(try { Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine -ErrorAction Stop; $enumerated = $true } catch { })
            $ids = [Collections.Generic.HashSet[int]]::new()
            $rootStillLive = try { $proc -and -not $proc.HasExited } catch { $false }
            if ($rootId -and $rootStillLive) { [void] $ids.Add($rootId) }
            foreach ($p in $all) {
                if ($p.Name -eq 'chrome.exe' -and $dir -and $p.CommandLine -and $p.CommandLine.Contains($dir, [StringComparison]::OrdinalIgnoreCase)) { [void] $ids.Add([int] $p.ProcessId) }
            }
            do {
                $added = $false
                foreach ($p in $all) { if ($p.Name -eq 'chrome.exe' -and $ids.Contains([int] $p.ParentProcessId) -and $ids.Add([int] $p.ProcessId)) { $added = $true } }
            } while ($added)
            $live = @($ids | Where-Object { $id = $_; $all | Where-Object { [int] $_.ProcessId -eq $id } })
            $passExtra['liveCount'] = $live.Count; $passExtra['enumerated'] = $enumerated
            if ($live.Count -eq 0) {
                if ($enumerated) { $passExtra['outcome'] = 'success'; $stopExtra['outcome'] = 'success' }
                break
            }
            foreach ($id in $live) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
            Start-Sleep -Milliseconds 300
            } finally { Complete-PhaseTiming -Phase 'chrome.killPass' -StartQpc $passQpc -Extra $passExtra }
        }
    } catch { $stopExtra['outcome'] = 'failure' } finally {
        if ($null -ne $stopQpc) { Complete-PhaseTiming -Phase 'chrome.stop' -StartQpc $stopQpc -Extra $stopExtra }
    }
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

function New-DefaultPillOptions {
    [ordered]@{
        theme = 'pill'; font = $null; scale = 100; width = 400; align = 'center'; colours = 'auto'
        text = '#ffffff'; background = '#202020'; backgroundOpacity = 100; accent = '#8a8a95'
        textShadow = $true; showArt = $true; showArtist = $true; showProgress = $true; showTimes = $true
        paused = 'hide'; showAnimation = 'slide-up'; hideAnimation = 'fade'
    }
}
function New-ObsLook([string] $Id, [string] $Name, $Options = $null) {
    if ($null -eq $Options) { $Options = New-DefaultPillOptions }
    [ordered]@{ id = $Id; name = $Name; options = $Options }
}
function New-ObsLooksDocument([object[]] $Looks = @(), [string[]] $Retired = @(), [int] $Version = 1) {
    [ordered]@{ version = $Version; looks = @($Looks); retired = @($Retired) }
}
function ConvertTo-ObsLooksJson($Document) { $Document | ConvertTo-Json -Depth 16 }
function Write-ObsLooksFile([string] $Root, [string] $Json) {
    $path = Join-Path $Root 'data/obs-looks.json'
    [IO.File]::WriteAllText($path, $Json, [Text.UTF8Encoding]::new($false))
    $path
}
function Read-ObsLooksFile([string] $Root) {
    Get-Content -Raw -LiteralPath (Join-Path $Root 'data/obs-looks.json') | ConvertFrom-Json -Depth 16
}

# Starts the app with the overlay on (plus options) and an SSE reader; returns the context.
function Start-OverlayRun([string] $Name, [hashtable] $Settings = @{}, [string] $BenchProfile = $null, [string] $BenchState = 'Full',
    [switch] $NoReader, [hashtable] $Override = @{}, [string] $LooksJson = $null) {
    $startQpc = Get-Qpc; $startOutcome = 'failure'
    try {
    if ($Name -like 'A-FRAMES-*') {
        # Independent attempts own fresh app/Chrome roots and retained logs; journal row IDs stay logical.
        $sessionBase = $Name; $attempt = 1
        while ((Test-Path -LiteralPath (Join-Path $rootBase $Name)) -or
            (Test-Path -LiteralPath (Join-Path $rootBase "chrome-$(ConvertTo-SafeName $Name)")) -or
            (Test-Path -LiteralPath (Join-Path $runDirectory "nativune-$(ConvertTo-SafeName $Name).log"))) {
            $attempt++
            $Name = "$sessionBase-attempt$attempt"
        }
    }
    $root = New-Root $Name
    $s = @{ ObsOverlay = $true }; foreach ($k in $Settings.Keys) { $s[$k] = $Settings[$k] }
    Write-Settings $root $s
    # A typed [string] default arrives as '' not $null; only an explicitly bound fixture is written (missing file = writable empty store).
    if ($PSBoundParameters.ContainsKey('LooksJson')) { [void] (Write-ObsLooksFile $root $LooksJson) }
    $launchEnv = @{}; foreach ($k in $Override.Keys) { $launchEnv[$k] = $Override[$k] }
    if ($BenchProfile) { $launchEnv['NATIVUNE_TEST_DISCORD_BENCH_PROFILE'] = $BenchProfile; $launchEnv['NATIVUNE_TEST_DISCORD_BENCH_STATE'] = $BenchState }
    $app = Start-App $root $launchEnv
    $reader = if ($NoReader) { $null } else { Start-SseReader $Name }
    $startOutcome = 'success'
    [pscustomobject]@{ Name = $Name; Root = $root; App = $app; Reader = $reader }
    } finally { Complete-PhaseTiming -Phase 'overlay.start' -StartQpc $startQpc -Extra @{ outcome = $startOutcome } }
}
function Stop-OverlayRun($Run) {
    if (-not $Run) { return }
    $stopQpc = Get-Qpc; $stopOutcome = 'failure'
    try {
    Stop-SseReader $Run.Reader
    Stop-App $Run.App $Run.Root
    Copy-AppLog $Run.Root $Run.Name
    $stopOutcome = 'success'
    } finally { Complete-PhaseTiming -Phase 'overlay.stop' -StartQpc $stopQpc -Extra @{ outcome = $stopOutcome } }
}
function Wait-Initial($Run, [string] $Id = 'fixtureSngA', [string] $State = 'playing', [double] $Seconds = 120) {
    $ev = Wait-SseData $Run.Reader { param($d) Test-Data $d $State $Id } $Seconds
    if (-not $ev) { throw "$($Run.Name): no initial $State $Id event within $Seconds s." }
    $ev
}
function Get-ReadyQpc($Ready) { if ($Ready) { [double] (Get-Prop $Ready 'qpc') } else { $null } }

function Get-ThemeDefaults([string] $Theme) {
    $options = New-DefaultPillOptions
    $options['theme'] = $Theme
    $options['width'] = switch ($Theme) { 'pill' { 400 } { $_ -in @('matte', 'matte-light', 'standard', 'classic', 'simple') } { 440 } 'album-art' { 200 } 'card' { 280 } }
    $options['align'] = if ($Theme -eq 'pill') { 'center' } else { 'left' }
    $options['textShadow'] = $Theme -notin @('matte', 'matte-light')
    if ($Theme -eq 'matte') { $options['background'] = '#1c1c1e'; $options['backgroundOpacity'] = 94 }
    if ($Theme -eq 'matte-light') { $options['text'] = '#141414'; $options['background'] = '#f5f5f7'; $options['backgroundOpacity'] = 94; $options['textShadow'] = $false }
    if ($Theme -in @('standard', 'classic', 'card')) { $options['background'] = '#1a1a1a'; $options['backgroundOpacity'] = 94 }
    if ($Theme -eq 'album-art') { $options['background'] = '#000000'; $options['backgroundOpacity'] = 80 }
    $options
}
function Copy-LookOptions($Options) {
    $copy = [ordered]@{}
    foreach ($key in $Options.Keys) { $copy[$key] = $Options[$key] }
    $copy
}
function Add-LookCase($Cases, [string] $Theme, [string] $Label, $Options) {
    $Cases.Add([ordered]@{ case = $Label; theme = $Theme; options = (Copy-LookOptions $Options); lookId = $null })
}
function Get-LookFxDefaults([string] $Theme) {
    $values = switch ($Theme) {
        'pill' { 14, 115, 45, 100 } 'matte' { 0, 100, 100, 100 } 'matte-light' { 0, 100, 0, 100 }
        'simple' { 0, 100, 0, 100 } 'album-art' { 0, 100, 100, 100 } 'card' { 16, 100, 100, 35 }
        default { 14, 100, 100, 40 }
    }
    [ordered]@{ backgroundBlur = $values[0]; playedBrightness = $values[1]
        unplayedBrightness = $values[2]; backgroundBrightness = $values[3] }
}
# Generates the entire §8.1 case matrix (all eight themes); A-LOOK executes pill in P0 and reports other rows deferred:P1.
function New-LookCases {
    $themes = @('pill', 'matte', 'matte-light', 'standard', 'classic', 'simple', 'album-art', 'card')
    $cases = [Collections.Generic.List[object]]::new()
    $sequence = 0
    foreach ($theme in $themes) {
        $base = Get-ThemeDefaults $theme
        Add-LookCase $cases $theme 'default' $base
        foreach ($option in @('showArt', 'showArtist', 'showProgress', 'showTimes')) {
            if ($option -eq 'showArt' -and $theme -eq 'pill') { continue }
            if ($option -eq 'showTimes' -and $theme -in @('pill', 'album-art')) { continue }
            $changed = Copy-LookOptions $base; $changed[$option] = $false
            Add-LookCase $cases $theme "$option-off" $changed
        }
        $alignments = if ($theme -eq 'pill') { @('left', 'right') } else { @('center', 'right') }
        foreach ($align in $alignments) { $changed = Copy-LookOptions $base; $changed['align'] = $align; Add-LookCase $cases $theme "align-$align" $changed }
        $custom = Copy-LookOptions $base; $custom['colours'] = 'custom'; $custom['text'] = '#1e90ff'
        if ($theme -notin @('pill', 'simple')) { $custom['background'] = '#101820'; $custom['accent'] = '#ff8c00' }
        Add-LookCase $cases $theme 'custom-colours' $custom
        foreach ($scale in @(50, 200)) {
            $changed = Copy-LookOptions $base; $changed['scale'] = $scale
            $minimum = switch ($theme) { 'pill' { 320 } { $_ -in @('matte', 'matte-light', 'standard', 'classic', 'simple') } { 360 } 'album-art' { 160 } 'card' { 200 } }
            $minimum = [int] ([Math]::Ceiling(($minimum * [Math]::Max(1, $scale / 100.0)) / 10) * 10)
            $changed['width'] = [int] [Math]::Max($minimum, [int] (Get-Prop $base 'width'))
            Add-LookCase $cases $theme "scale-$scale" $changed
        }
        $baseMin = switch ($theme) { 'pill' { 320 } { $_ -in @('matte', 'matte-light', 'standard', 'classic', 'simple') } { 360 } 'album-art' { 160 } 'card' { 200 } }
        $maxWidth = switch ($theme) { 'pill' { 800 } { $_ -in @('matte', 'matte-light', 'standard', 'classic', 'simple') } { 1200 } 'album-art' { 600 } 'card' { 600 } }
        foreach ($scale in @(100, 200)) {
            $minimum = [int] ([Math]::Ceiling(($baseMin * [Math]::Max(1, $scale / 100.0)) / 10) * 10)
            foreach ($width in @($minimum, $maxWidth)) {
                $changed = Copy-LookOptions $base; $changed['scale'] = $scale; $changed['width'] = $width
                Add-LookCase $cases $theme "width-$width-k$scale" $changed
            }
        }
        $dim = Copy-LookOptions $base; $dim['paused'] = 'dim'; Add-LookCase $cases $theme 'paused-dim' $dim
        foreach ($animation in @('fade', 'slide-up', 'slide-down', 'slide-left', 'slide-right', 'none')) {
            $changed = Copy-LookOptions $base; $changed['showAnimation'] = $animation
            Add-LookCase $cases $theme "show-$animation" $changed
            $changed = Copy-LookOptions $base; $changed['hideAnimation'] = $animation
            Add-LookCase $cases $theme "hide-$animation" $changed
        }
        if ($theme -eq 'pill') {
            $font = Copy-LookOptions $base; $font['font'] = 'Arial'; Add-LookCase $cases $theme 'font-arial' $font
            $shadow = Copy-LookOptions $base; $shadow['textShadow'] = $false; Add-LookCase $cases $theme 'shadow-off' $shadow
            foreach ($width in @(320, 800)) { $changed = Copy-LookOptions $base; $changed['width'] = $width; Add-LookCase $cases $theme "width-$width" $changed }
            $artist = Copy-LookOptions $base; $artist['showArtist'] = $false; Add-LookCase $cases $theme 'artist-off' $artist
        }
    }
    # Append, rather than interleave: all pre-LookFx ids and committed default fixtures remain unchanged.
    foreach ($theme in $themes) {
        $base = Get-ThemeDefaults $theme
        $base['paused'] = 'dim'
        $defaults = Get-LookFxDefaults $theme
        $explicit = Copy-LookOptions $base
        foreach ($key in $defaults.Keys) { $explicit[$key] = $defaults[$key] }
        Add-LookCase $cases $theme 'fx-default' $explicit
        $variants = [ordered]@{ 'played-min' = @('playedBrightness', 0); 'played-max' = @('playedBrightness', 200)
            'unplayed-min' = @('unplayedBrightness', 0); 'unplayed-max' = @('unplayedBrightness', 100) }
        if ($theme -in @('pill', 'standard', 'classic', 'album-art', 'card')) {
            $variants['blur-0'] = @('backgroundBlur', 0); $variants['blur-max'] = @('backgroundBlur', 32)
            $variants['bg-min'] = @('backgroundBrightness', 0); $variants['bg-max'] = @('backgroundBrightness', 200)
        }
        foreach ($variant in $variants.Keys) {
            $changed = Copy-LookOptions $base; $changed[$variants[$variant][0]] = $variants[$variant][1]
            Add-LookCase $cases $theme "fx-$variant" $changed
        }
    }
    foreach ($case in $cases) {
        $sequence++
        $case.lookId = 'lk{0:D6}' -f $sequence
        $case.phase = if ($case.theme -eq 'pill') { 'P0' } else { 'P1' }
        $case.batch = [int] [Math]::Floor(($sequence - 1) / 16) + 1
    }
    $json = ConvertTo-Json -InputObject @($cases) -Depth 16
    [IO.Directory]::CreateDirectory($fixtureDirectory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $fixtureDirectory 'looks-cases.json'), $json, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $runDirectory 'looks-cases.json'), $json, [Text.UTF8Encoding]::new($false))
    $cases.ToArray()
}
function Get-PillExpectedBox($Options) {
    $k = [double] (Get-Prop $Options 'scale') / 100
    [ordered]@{
        x = 20; y = 20; width = [int] (Get-Prop $Options 'width'); height = 56 * $k
        sourceWidth = [int] ([Math]::Ceiling(([int] (Get-Prop $Options 'width') + 40) / 2.0) * 2)
        sourceHeight = [int] ([Math]::Ceiling((56 * $k + 40) / 2.0) * 2)
    }
}
function Get-Sha256([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Compare-Png([byte[]] $ExpectedBytes, [byte[]] $ActualBytes, [string] $DiffPath, [int] $Tolerance = 8) {
    $expectedStream = [IO.MemoryStream]::new($ExpectedBytes)
    $actualStream = [IO.MemoryStream]::new($ActualBytes)
    $expected = $null; $actual = $null; $diff = $null
    try {
        $expected = [Drawing.Bitmap]::new($expectedStream); $actual = [Drawing.Bitmap]::new($actualStream)
        if ($expected.Width -ne $actual.Width -or $expected.Height -ne $actual.Height) {
            $diff = [Drawing.Bitmap]::new($actual.Width, $actual.Height)
            for ($y = 0; $y -lt $actual.Height; $y++) {
                for ($x = 0; $x -lt $actual.Width; $x++) { $diff.SetPixel($x, $y, [Drawing.Color]::FromArgb(255, 255, 0, 0)) }
            }
            [IO.Directory]::CreateDirectory((Split-Path -Parent $DiffPath)) | Out-Null
            $diff.Save($DiffPath, [Drawing.Imaging.ImageFormat]::Png)
            return [ordered]@{ width = $actual.Width; height = $actual.Height; expectedWidth = $expected.Width; expectedHeight = $expected.Height
                differing = $null; pixels = $null; percent = 100.0 }
        }
        $diff = [Drawing.Bitmap]::new($expected.Width, $expected.Height)
        $differing = 0
        for ($y = 0; $y -lt $expected.Height; $y++) {
            for ($x = 0; $x -lt $expected.Width; $x++) {
                $a = $expected.GetPixel($x, $y); $b = $actual.GetPixel($x, $y)
                $over = ([Math]::Abs($a.R - $b.R) -gt $Tolerance -or [Math]::Abs($a.G - $b.G) -gt $Tolerance -or
                    [Math]::Abs($a.B - $b.B) -gt $Tolerance -or [Math]::Abs($a.A - $b.A) -gt $Tolerance)
                if ($over) { $differing++; $diff.SetPixel($x, $y, [Drawing.Color]::FromArgb(255, 255, 0, 0)) }
                else { $diff.SetPixel($x, $y, [Drawing.Color]::FromArgb(255, 24, 24, 24)) }
            }
        }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $DiffPath)) | Out-Null
        $diff.Save($DiffPath, [Drawing.Imaging.ImageFormat]::Png)
        [ordered]@{ width = $actual.Width; height = $actual.Height; expectedWidth = $expected.Width; expectedHeight = $expected.Height
            differing = $differing; pixels = $expected.Width * $expected.Height; percent = [Math]::Round(100.0 * $differing / ($expected.Width * $expected.Height), 5) }
    } finally {
        if ($diff) { $diff.Dispose() }; if ($actual) { $actual.Dispose() }; if ($expected) { $expected.Dispose() }
        $actualStream.Dispose(); $expectedStream.Dispose()
    }
}
function Send-PreviewNonce([string] $Root, [string] $Nonce) {
    if ($Nonce -ne 'clear' -and $Nonce -cnotmatch '^[a-z0-9]{8}$') { throw 'Preview nonce must be eight lowercase alphanumeric characters or clear.' }
    Send-ObsHookCommand $Root 'command-obs-preview-nonce' $Nonce
}
function Send-DraftLook([string] $Root, $Look, [string] $Backdrop = 'checker', [switch] $NoWait) {
    if ($null -eq $Look) { return Send-ObsHookCommand $Root 'command-obs-draft-look' 'clear' }
    $payload = ConvertTo-Json -InputObject ([ordered]@{ look = $Look; backdrop = $Backdrop }) -Compress -Depth 16
    if ($NoWait) { return Queue-ObsHookCommand $Root 'command-obs-draft-look' $payload }
    Send-ObsHookCommand $Root 'command-obs-draft-look' $payload
}
function Invoke-ObsLookCommit([string] $Root, [int] $Sequence, $Mutation) {
    $directory = Get-BenchDirectory $Root
    $inputName = "commit-$Sequence.json"; $resultName = "commit-$Sequence-result.json"
    $inputPath = Join-Path $directory $inputName; $resultPath = Join-Path $directory $resultName
    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
    [IO.File]::WriteAllText($inputPath, (ConvertTo-Json -InputObject $Mutation -Compress -Depth 16), [Text.UTF8Encoding]::new($false))
    [void] (Send-ObsHookCommand $Root 'command-obs-looks-commit' $inputName)
    $result = Wait-For { if (Test-Path -LiteralPath $resultPath) { Get-Content -Raw -LiteralPath $resultPath | ConvertFrom-Json -Depth 16 } } 15 100
    if (-not $result) { throw "Missing looks commit result $resultName." }
    $result
}

function Test-APlain {
    if (-not (Test-ChromeAvailable 'A-PLAIN')) { return }
    $run = Start-OverlayRun 'A-PLAIN' @{ ObsOverlay = $true; ObsHidePaused = $true } 'Playing'
    $chrome = $null
    try {
        $initial = Wait-Initial $run
        $chrome = Start-Chrome 'A-PLAIN' -Plain
        Set-PlainViewport $chrome
        [void] (Invoke-ChromeNavigate $chrome $overlayUrl)
        $connected = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'connection') -eq 'open' -and (Get-PageField $p 'state') -eq 'playing') { $p } } 30 100
        $version = Get-ChromeVersion $chrome
        Add-Check 'A-PLAIN.chromeVersion' 'CDP reports an installed Chrome version' ([ordered]@{ product = $version.product; version = $version.version }) ($null -ne $version.major)
        Add-Check 'A-PLAIN.viewport' 'headless Chrome page is 440x96 CSS px at DPR 1' ([ordered]@{
            width = Get-Prop $connected 'pageSize' | ForEach-Object { Get-Prop $_ 'width' }
            height = Get-Prop $connected 'pageSize' | ForEach-Object { Get-Prop $_ 'height' }
            dpr = Get-Prop $connected 'pageSize' | ForEach-Object { Get-Prop $_ 'dpr' }
        }) ($connected -and $connected.pageSize.width -eq 440 -and $connected.pageSize.height -eq 96 -and $connected.pageSize.dpr -eq 1)
        if (-not $connected) { throw 'A-PLAIN page did not connect to the playing fixture.' }

        $baselineMeta = $null
        if (-not $CapturePlainBaseline -and (Test-Path -LiteralPath $plainBaselineMeta -PathType Leaf)) {
            $baselineMeta = Get-Content -Raw -LiteralPath $plainBaselineMeta | ConvertFrom-Json -Depth 16
        }
        $pageStartQpc = Get-PageStartQpc $initial
        $captures = [ordered]@{}; $captureBytes = [ordered]@{}; $capturePaths = [ordered]@{}; $positionResults = [ordered]@{}
        foreach ($target in @(8, 18)) {
            $key = "${target}s"
            Wait-UntilQpc ($pageStartQpc + $target * $freq)
            $probe = Wait-For {
                $p = Get-PageProbe $chrome
                $position = Get-PageField $p 'projectedPosition'
                if ($null -ne $position -and [Math]::Abs([double] $position - $target) -le 0.2) { $p }
            } 3 20
            if (-not $probe) { $probe = Get-PageProbe $chrome }
            $position = Get-PageField $probe 'projectedPosition'
            $fillPx = if ($null -ne $probe.clipPx) { [int] [Math]::Round([double] $probe.clipPx) } else { $null }
            $expectedFillPx = if ($null -ne $position) { [int] [Math]::Round([double] $position / 1800 * 400) } else { $null }
            $bytes = Get-ChromeShotBytes $chrome
            $capturePath = Join-Path $shotDirectory "A-PLAIN-$key-current.png"
            [IO.File]::WriteAllBytes($capturePath, $bytes)
            $captureBytes[$key] = $bytes
            $capturePaths[$key] = [IO.Path]::GetRelativePath($runDirectory, $capturePath)
            $captures[$key] = [ordered]@{ projectedPosition = $position; fillPx = $fillPx; expectedFillPx = $expectedFillPx }
            $positionResults[$key] = $null -ne $position -and [Math]::Abs([double] $position - $target) -le 0.2
            Add-Check "A-PLAIN.position$key" "__state.projectedPosition within 0.2 s of $target" $position $positionResults[$key]
            Add-Check "A-PLAIN.fillPixel$key" 'DOM progress clip pixel equals round(projectedPosition / 1800 * 400)' (
                [ordered]@{ fillPx = $fillPx; expected = $expectedFillPx }) ($null -ne $fillPx -and $fillPx -eq $expectedFillPx)
        }
        if ($CapturePlainBaseline) {
            $positionsOk = @($positionResults.Values | Where-Object { -not $_ }).Count -eq 0
            $fillsOk = @($captures.Values | Where-Object { $_.fillPx -ne $_.expectedFillPx }).Count -eq 0
            if ($positionsOk -and $fillsOk) {
                [IO.Directory]::CreateDirectory($fixtureDirectory) | Out-Null
                [IO.File]::WriteAllBytes($plainBaseline8, $captureBytes['8s'])
                [IO.File]::WriteAllBytes($plainBaseline18, $captureBytes['18s'])
                $meta = [ordered]@{
                    version = 1; sourceRevision = '1e8c964'; chromeVersion = $version.version; chromeProduct = $version.product
                    flags = @($plainChromeFlags + '--force-device-scale-factor=1'); viewport = [ordered]@{ width = 440; height = 96; deviceScaleFactor = 1 }
                    captures = $captures
                }
                [IO.File]::WriteAllText($plainBaselineMeta, (ConvertTo-Json -InputObject $meta -Depth 12), [Text.UTF8Encoding]::new($false))
                Add-Check 'A-PLAIN.baselineCapture' 'wrote the 8 s/18 s PNG baselines and plain-meta.json from the unchanged 1e8c964 build' (
                    [ordered]@{ plain8 = (Get-Item $plainBaseline8).Length; plain18 = (Get-Item $plainBaseline18).Length; meta = $plainBaselineMeta }) $true
            } else {
                Add-Check 'A-PLAIN.baselineCapture' 'both projected positions are within 0.2 s and rendered fill pixels match their projected positions before fixtures are written' (
                    [ordered]@{ positions = $positionResults; captures = $captures }) $false
            }
            return
        }

        if (-not $baselineMeta -or -not $version.major) {
            Add-Blocked 'A-PLAIN.chromeMajorVersion' 'Chrome major matches plain-meta.json' 'plain-meta.json is missing or Chrome version could not be parsed'
            foreach ($target in @(8, 18)) { Add-Blocked "A-PLAIN.pixelComparison${target}s" 'at most 0.5% of pixels differ by more than 8/255 in any channel' 'no valid committed baseline metadata' }
        } else {
            $baselineVersion = [string] (Get-Prop $baselineMeta 'chromeVersion')
            $baselineMajor = [int] (($baselineVersion -split '\.')[0])
            if ([int] $version.major -ne $baselineMajor) {
                Add-Blocked 'A-PLAIN.chromeMajorVersion' "Chrome major $baselineMajor from plain-meta.json" "installed Chrome is $($version.version); recapture from the 1e8c964 build"
                foreach ($target in @(8, 18)) { Add-Blocked "A-PLAIN.pixelComparison${target}s" 'at most 0.5% of pixels differ by more than 8/255 in any channel' 'Chrome major-version mismatch' }
            } else {
                Add-Check 'A-PLAIN.chromeMajorVersion' "Chrome major $baselineMajor matches plain-meta.json" $version.version $true
                foreach ($target in @(8, 18)) {
                    $key = "${target}s"; $basePath = if ($target -eq 8) { $plainBaseline8 } else { $plainBaseline18 }
                    if (-not (Test-Path -LiteralPath $basePath -PathType Leaf)) {
                        Add-Blocked "A-PLAIN.pixelComparison$key" $basePath 'baseline PNG is missing; run -CapturePlainBaseline on the unchanged build'
                        continue
                    }
                    $baseCapture = Get-Prop (Get-Prop $baselineMeta 'captures') $key
                    $expectedFill = Get-Prop $baseCapture 'fillPx'
                    $actualFill = Get-Prop $captures[$key] 'fillPx'
                    Add-Check "A-PLAIN.baselineFillPixel$key" "fill pixel equals baseline metadata value $expectedFill" $actualFill ($null -ne $expectedFill -and $actualFill -eq $expectedFill)
                    $diffPath = Join-Path $shotDirectory "A-PLAIN-$key-diff.png"
                    $diff = Compare-Png ([IO.File]::ReadAllBytes($basePath)) $captureBytes[$key] $diffPath
                    $diffResult = [ordered]@{ width = $diff.width; height = $diff.height; expectedWidth = $diff.expectedWidth
                        expectedHeight = $diff.expectedHeight; differing = $diff.differing; pixels = $diff.pixels; percent = $diff.percent
                        diffImage = [IO.Path]::GetRelativePath($runDirectory, $diffPath) }
                    Add-Check "A-PLAIN.pixelComparison$key" '≤ 0.5% of pixels differ by > 8/255 in any channel; diff image retained' $diffResult (
                        $diff.percent -le 0.5 -and $diff.width -eq 440 -and $diff.height -eq 96 -and (Test-Path -LiteralPath $diffPath))
                }
            }
        }

        if (-not $CapturePlainBaseline) {
            $events = @(Read-Sse $run.Reader)
            $looks = @(Get-LookEvents $events); $data = @(Get-DataEvents $events)
            $firstLook = if ($looks.Count -gt 0) { $looks[0] } else { $null }
            $firstData = if ($data.Count -gt 0) { $data[0] } else { $null }
            Add-Check 'A-PLAIN.lookFirst' 'first SSE payload is the look event before initial data' ([ordered]@{
                firstLookQpc = Get-Prop $firstLook 'qpc'; firstDataQpc = Get-Prop $firstData 'qpc' }) (
                $firstLook -and $firstData -and $firstLook.qpc -lt $firstData.qpc)
            $look = Get-Prop $firstLook 'data'; $options = Get-Prop $look 'options'
            Add-Check 'A-PLAIN.lookPreset' 'plain look id is null and uses the compatibility pill defaults' ([ordered]@{
                id = Get-Prop $look 'id'; theme = Get-Prop $options 'theme'; width = Get-Prop $options 'width'; scale = Get-Prop $options 'scale'
                align = Get-Prop $options 'align'; textShadow = Get-Prop $options 'textShadow'; showArtist = Get-Prop $options 'showArtist'
                showProgress = Get-Prop $options 'showProgress' }) (
                $look -and $null -eq (Get-Prop $look 'id') -and (Get-Prop $options 'theme') -eq 'pill' -and
                (Get-Prop $options 'width') -eq 400 -and (Get-Prop $options 'scale') -eq 100 -and
                (Get-Prop $options 'align') -eq 'center' -and (Get-Prop $options 'textShadow') -eq $true)
            Add-Check 'A-PLAIN.hidePaused' 'plain look carries the configured global hidePaused value' (
                [ordered]@{ look = Get-Prop $look 'hidePaused'; settings = $true }) ($look -and (Get-Prop $look 'hidePaused') -eq $true)
            [void] (Send-ObsHookCommand $run.Root 'command-obs-reduce-motion-on')
            $reducedLook = Wait-SseLook $run.Reader { param($m) (Get-Prop $m 'reduceMotion') -eq $true } 10
            Add-Check 'A-PLAIN.reduceMotionPush' 'plain stream receives ReduceMotion true as a look update' ([bool] $reducedLook) ([bool] $reducedLook)
            $scenarioResults['A-PLAIN'] = [ordered]@{ chrome = $version.version; captures = $captures; screenshotPaths = $capturePaths
                diffImages = @('screenshots/A-PLAIN-8s-diff.png', 'screenshots/A-PLAIN-18s-diff.png') }
        }
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }

    if (-not $CapturePlainBaseline) {
        foreach ($hidePaused in @($true, $false)) {
            $label = if ($hidePaused) { 'hidden' } else { 'dimmed' }
            $pauseRun = Start-OverlayRun "A-PLAIN-$label" @{ ObsHidePaused = $hidePaused } 'Paused'
            $pauseChrome = $null
            try {
                [void] (Wait-Initial $pauseRun 'fixtureSngA' 'paused')
                $pauseChrome = Start-Chrome "A-PLAIN-$label"
                [void] (Invoke-ChromeNavigate $pauseChrome $overlayUrl)
                $paused = Wait-For { $p = Get-PageProbe $pauseChrome; if ((Get-PageField $p 'state') -eq 'paused') { $p } } 20 100
                if ($paused) { Start-Sleep -Milliseconds 700; $paused = Get-PageProbe $pauseChrome }
                $shown = Get-PageField $paused 'shown'
                if ($hidePaused) {
                    Add-Check 'A-PLAIN.hidePausedHidden' 'global hidePaused true hides the paused plain pill' ([ordered]@{
                        hidePaused = Get-PageField $paused 'hidePaused'; shown = $shown }) ($paused -and $shown -eq $false)
                } else {
                    Add-Check 'A-PLAIN.hidePausedDim' 'global hidePaused false shows the paused plain pill dimmed to 0.7' ([ordered]@{
                        hidePaused = Get-PageField $paused 'hidePaused'; shown = $shown; opacity = Get-Prop $paused 'opacity' }) (
                        $paused -and $shown -eq $true -and [Math]::Abs([double] $paused.opacity - 0.7) -le 0.02)
                }
            } finally { Stop-Chrome $pauseChrome; Stop-OverlayRun $pauseRun }
        }
        $motionRun = Start-OverlayRun 'A-PLAIN-reduce-motion' @{ ObsHidePaused = $false } 'Paused'
        $motionChrome = $null
        try {
            [void] (Wait-BenchReady $motionRun.Root)
            $motionChrome = Start-Chrome 'A-PLAIN-reduce-motion'
            [void] (Invoke-ChromeNavigate $motionChrome $overlayUrl)
            $visible = Wait-For { $p = Get-PageProbe $motionChrome; if ((Get-PageField $p 'shown') -eq $true) { $p } } 20 100
            Start-Sleep -Milliseconds 700
            [void] (Send-HookCommand $motionRun.Root 'command-obs-hide-paused-on')
            $hiding = Wait-For { $p = Get-PageProbe $motionChrome; if ($p.running -gt 0) { $p } } 2 20
            [void] (Send-ObsHookCommand $motionRun.Root 'command-obs-reduce-motion-on')
            $reduced = Wait-SseLook $motionRun.Reader { param($m) (Get-Prop $m 'reduceMotion') -eq $true } 10
            $final = Wait-For { $p = Get-PageProbe $motionChrome; if ($p.running -eq 0) { $p } } 2 20
            Add-Check 'A-PLAIN.reduceMotionInstant' 'ReduceMotion push cancels the currently running hide transition and applies hidden state instantly' ([ordered]@{
                visible = Get-PageField $visible 'shown'; transitionRunning = [bool] $hiding; lookObserved = [bool] $reduced
                finalShown = Get-PageField $final 'shown'; running = Get-Prop $final 'running' }) (
                $visible -and $hiding -and $reduced -and $final -and
                (Get-PageField $final 'shown') -eq $false -and $final.running -eq 0)
        } finally { Stop-Chrome $motionChrome; Stop-OverlayRun $motionRun }
    }
}

# Look id a case's page navigates to: its own, or a sibling's under a diagnostic '-LookRedCase <case>=route'.
function Get-LookNavigationId($Case, [object[]] $BatchCases) {
    if ($lookRed["$($Case.theme).$($Case.case)"] -ne 'route') { return $Case.lookId }
    $sibling = @($BatchCases | Where-Object { $_.lookId -ne $Case.lookId }) | Select-Object -First 1
    if (-not $sibling) { throw "-LookRedCase route needs a second selected case in the batch of $($Case.theme).$($Case.case)." }
    Write-Host "LookRedCase: $($Case.theme).$($Case.case) routed to $($sibling.lookId)."
    return $sibling.lookId
}

function Get-LookFxProbe($Chrome, [switch] $NoFx) {
    $page = Get-PageProbe $Chrome
    $expression = @'
(() => {
  const noFx = __NO_FX__;
  const style = id => {
    const element = document.getElementById(id);
    if (!element) return null;
    const c = getComputedStyle(element);
    return {background:c.background, color:c.color, opacity:c.opacity, filter:c.filter,
      font:c.font, textShadow:c.textShadow, display:c.display};
  };
  const canvas = c => {
    // Never read back the live raster: that can switch Chromium's production canvas backend.
    const scratch = document.createElement('canvas'); scratch.width = c.width; scratch.height = c.height;
    const read = scratch.getContext('2d', {willReadFrequently:true});
    if (c.width && c.height) read.drawImage(c, 0, 0);
    const bytes = c.width && c.height ? read.getImageData(0, 0, c.width, c.height).data : [];
    const ctx = c.getContext('2d');
    let hash = 2166136261;
    for (const byte of bytes) hash = Math.imul(hash ^ byte, 16777619) >>> 0;
    const filter = ctx.filter;
    const value = name => Number(filter.match(new RegExp(name + '\\(([-.0-9]+)'))?.[1] ?? NaN);
    return {w:c.width, h:c.height, hash, filter, blur:value('blur'), brightness:value('brightness'),
      saturate:value('saturate'), grayscale:value('grayscale'), alpha:ctx.globalAlpha};
  };
  const artPixel = (() => {
    if (noFx || !artImg || !artImg.complete || !artImg.naturalWidth || !artImg.naturalHeight) return null;
    const c = document.createElement('canvas'); c.width = c.height = 1;
    const ctx = c.getContext('2d', {willReadFrequently:true});
    ctx.drawImage(artImg, 96, 96, 1, 1, 0, 0, 1, 1);
    return Array.from(ctx.getImageData(0, 0, 1, 1).data);
  })();
  const properties = noFx ? ['--bg','--bg-a'] : ['--played-fill','--unplayed-track','--bg','--bg-a'];
  const elements = [document.documentElement, document.body, ...document.querySelectorAll('[id]')]
    .filter(el => !noFx || el.id !== 'cover-fx');
  const captureMetadata = {
    href:location.href, visibility:document.visibilityState, hasFocus:document.hasFocus(),
    lookEpoch:window.__state?.lookEpoch, lookSeq:window.__state?.lookSeq, options:opts,
    lookFxAvailable:typeof effectsOf === 'function',
    elements:Object.fromEntries(elements.map(el => {
      const c = getComputedStyle(el);
      return [el.id || el.tagName.toLowerCase(), {rect:el.getBoundingClientRect().toJSON(),
        transform:c.transform, transformOrigin:c.transformOrigin, translate:c.translate, rotate:c.rotate, scale:c.scale,
        opacity:c.opacity, display:c.display, visibility:c.visibility, filter:c.filter, backdropFilter:c.backdropFilter,
        isolation:c.isolation, mixBlendMode:c.mixBlendMode, willChange:c.willChange, contain:c.contain,
        overflow:c.overflow, clipPath:c.clipPath, backgroundColor:c.backgroundColor, backgroundImage:c.backgroundImage,
        customProperties:Object.fromEntries(properties.map(name => [name,c.getPropertyValue(name).trim()]))}];
    })),
    images:[...document.images, ...(artImg ? [artImg] : [])].map(img => ({
      id:img.id || null, src:img.currentSrc || img.src, complete:img.complete,
      naturalWidth:img.naturalWidth, naturalHeight:img.naturalHeight})),
    animations:document.getAnimations().map(a => ({target:a.effect?.target?.id ?? null,
      playState:a.playState, currentTime:a.currentTime, timing:a.effect?.getComputedTiming(),
      keyframes:a.effect?.getKeyframes()})),
    scrim:{colour:getComputedStyle(document.getElementById('scrim')).backgroundColor,
      background:getComputedStyle(document.getElementById('scrim')).background},
    barfill:{colour:getComputedStyle(document.getElementById('barfill')).backgroundColor,
      background:getComputedStyle(document.getElementById('barfill')).background}
  };
  return {captureMetadata, nativeFixture:{requestedArt:artUrl, loadedArt:artImgUrl, duration:msg?.duration ?? null, rate:msg?.rate ?? null, clock:msg?.clock ?? null},
    fx:!noFx && typeof effectsOf === 'function' ? {resolved:effectsOf(opts), coverFx:document.documentElement.getAttribute('data-cover-fx'),
    requestedArt:artUrl, loadedArt:artImgUrl, artPixel, duration:msg.duration, rate:msg.rate, clock:msg.clock,
    canvases:Object.fromEntries([...document.querySelectorAll('canvas')].map((c,i) => [c.id || `canvas-${i}`,canvas(c)])),
    styles:Object.fromEntries(['bar','barfill','barhead','stripe','scrim','title','artist','thumb','cover-fx'].map(id => [id,style(id)])),
    played:getComputedStyle(document.getElementById('barfill')).backgroundColor,
    track:getComputedStyle(document.getElementById('bar')).backgroundColor,
    head:getComputedStyle(document.getElementById('barhead')).backgroundColor} : null};
})()
'@
    $expression = $expression.Replace('__NO_FX__', $(if ($NoFx) { 'true' } else { 'false' }))
    $result = Invoke-Cdp $Chrome 'Runtime.evaluate' @{ expression = $expression; returnByValue = $true }
    $exception = Get-Prop $result 'exceptionDetails'
    if ($exception) {
        throw "LookFx $(if ($NoFx) { 'native-only' } else { 'canvas/style' }) probe failed: $(ConvertTo-Json -InputObject $exception -Compress -Depth 16)"
    }
    $value = Get-Prop (Get-Prop $result 'result') 'value'
    $page | Add-Member -NotePropertyName fx -NotePropertyValue (Get-Prop $value 'fx') -Force
    $page | Add-Member -NotePropertyName nativeFixture -NotePropertyValue (Get-Prop $value 'nativeFixture') -Force
    $metadata = Get-Prop $value 'captureMetadata'
    $metadata | Add-Member -NotePropertyName TargetId -NotePropertyValue (Resolve-Chrome $Chrome).TargetId -Force
    $page | Add-Member -NotePropertyName captureMetadata -NotePropertyValue $metadata -Force
    $page
}
function Get-LookFxFixtureFailures($Page, $Look, $Fixture) {
    $noFx = (Get-Prop $Fixture 'noFx') -eq $true
    $fx = Get-Prop $Page $(if ($noFx) { 'nativeFixture' } else { 'fx' })
    if (-not $Page -or -not $fx) { return $(if ($noFx) { 'page.nativeFixture' } else { 'page.fx' }) }
    $options = Get-PageField $Page 'options'
    if (-not $options) { return 'options' }
    $expectedOptions = ConvertTo-Json -InputObject $Look.options -Depth 16 | ConvertFrom-Json -Depth 16
    # Saved variants omit inactive nullable FX fields; normalizeOptions publishes them explicitly as null.
    $fxKeys = @((Get-LookFxDefaults $Look.options.theme).Keys)
    if (-not $noFx) {
        foreach ($key in $fxKeys) {
            if (-not $expectedOptions.PSObject.Properties[$key]) {
                $expectedOptions | Add-Member -NotePropertyName $key -NotePropertyValue $null
            }
        }
    }
    $keys = @($expectedOptions.PSObject.Properties.Name)
    $terms = [ordered]@{
        'look.id' = (Get-Prop (Get-PageField $Page 'look') 'id') -ceq $Look.id
        'options.count' = @($options.PSObject.Properties.Name | Where-Object { -not $noFx -or $_ -notin $fxKeys }).Count -eq $keys.Count
        'href' = $Page.href -ceq $Fixture.href
        'viewport' = Test-OverlayViewport $Page $Fixture.source
        'viewport.dpr' = (Get-Prop $Page.pageSize 'dpr') -eq 1
        'connection' = (Get-PageField $Page 'connection') -ceq 'open'
        'shown' = (Get-PageField $Page 'shown') -eq $true
        'animations.running' = $Page.running -eq 0
        'song.id' = (Get-PageField $Page 'id') -eq $null
        'song.title' = (Get-PageField $Page 'title') -ceq 'Sample song'
        'song.artist' = (Get-PageField $Page 'artist') -ceq 'Sample artist'
        'duration' = (Get-Prop $fx 'duration') -eq 240
        'rate' = (Get-Prop $fx 'rate') -eq 1
        'clock' = (Get-Prop $fx 'clock') -eq $true
    }
    if ($noFx) {
        $terms['noFx.overridesAbsent'] = @($fxKeys | Where-Object { $null -ne (Get-Prop $options $_) }).Count -eq 0
    }
    foreach ($key in $keys) {
        $terms["options.$key"] = $null -ne $options.PSObject.Properties[$key] -and
            (Get-Prop $options $key) -ceq (Get-Prop $expectedOptions $key)
    }
    $sources = [ordered]@{ 'source' = Get-PageField $Page 'source'; 'look.source' = Get-Prop (Get-PageField $Page 'look') 'source' }
    foreach ($key in $sources.Keys) {
        $terms["$key.w"] = (Get-Prop $sources[$key] 'w') -eq $Fixture.source.w
        $terms["$key.h"] = (Get-Prop $sources[$key] 'h') -eq $Fixture.source.h
    }
    if ($Fixture.mode -eq 'paused') {
        $terms['state'] = (Get-PageField $Page 'state') -ceq 'paused'
        $terms['projectedPosition'] = (Get-PageField $Page 'projectedPosition') -eq 84
        $terms['art.requested'] = (Get-Prop $fx 'requestedArt') -ceq '/art/sample'
        $terms['art.loaded'] = (Get-Prop $fx 'loadedArt') -ceq '/art/sample'
        $terms['art.failed'] = (Get-PageField $Page 'artFailed') -eq $false
        $terms['art.sequence'] = (Get-PageField $Page 'artLoadedSeq') -eq (Get-PageField $Page 'artSeq')
        $terms['art.resource'] = @($Page.art | Where-Object { $_.name -ceq '/art/sample' }).Count -gt 0
        $terms['progress.fraction'] = if ($Look.options.showProgress) { [Math]::Abs([double] $Page.frac - .35) -lt .01 } else { $true }
    } else {
        $terms['sample.mode'] = $Fixture.mode -ceq 'noart'
        $terms['state'] = (Get-PageField $Page 'state') -ceq 'playing'
        $terms['progress.disabledOption'] = $Look.options.showProgress -eq $false
        $terms['times.disabledOption'] = $Look.options.showTimes -eq $false
        $terms['progress.disabledAttribute'] = $Page.attrs.showProgress -ceq 'false'
        $terms['times.disabledAttribute'] = $Page.attrs.showTimes -ceq 'false'
        $terms['progress.timer'] = (Get-PageField $Page 'fillTimer') -eq 0
        $terms['art.requested'] = (Get-Prop $fx 'requestedArt') -eq $null
        $terms['art.loaded'] = (Get-Prop $fx 'loadedArt') -eq $null
        $terms['art.failed'] = (Get-PageField $Page 'artFailed') -eq $true
        $terms['art.resourcesAbsent'] = @($Page.art).Count -eq 0
    }
    $terms.Keys | Where-Object { -not $terms[$_] }
}
function Test-LookFxFixture($Page, $Look, $Fixture) {
    @(Get-LookFxFixtureFailures $Page $Look $Fixture).Count -eq 0
}
function Wait-LookFxFixture($Chrome, $Look, $Fixture) {
    $poll = @{ last = $null }
    $page = Wait-For {
        # Page.navigate ACK is not a data/art readiness barrier. Do not run raster/native probes on an uninitialized document.
        $initial = Get-PageProbe $Chrome; $poll.last = $initial
        if ($initial.href -cne $Fixture.href -or (Get-PageField $initial 'connection') -cne 'open' -or
            (Get-Prop (Get-PageField $initial 'look') 'id') -cne $Look.id -or (Get-PageField $initial 'shown') -ne $true -or
            (Get-PageField $initial 'state') -notin @('playing', 'paused')) { return $null }
        if ($Fixture.mode -eq 'paused' -and ((Get-PageField $initial 'artLoadedSeq') -lt 1 -or
            (Get-PageField $initial 'artLoadedSeq') -ne (Get-PageField $initial 'artSeq'))) { return $null }
        $poll.last = Get-LookFxProbe $Chrome -NoFx:((Get-Prop $Fixture 'noFx') -eq $true)
        if (Test-LookFxFixture $poll.last $Look $Fixture) { $poll.last }
    } 10 50
    if (-not $page) {
        $failed = @(Get-LookFxFixtureFailures $poll.last $Look $Fixture)
        throw "LookFx native $($Fixture.mode) fixture did not settle for $($Look.id); failed terms: $($failed -join ', '): $(ConvertTo-Json -InputObject $poll.last -Compress -Depth 16)"
    }
    $page
}
function Set-LookFxSamplePage($Run, $Chrome, $Look, $Fixture, [switch] $ReloadLookBeforeAdmission) {
    $oldPage = Get-PageProbe $Chrome
    $before = Get-State $Run.Root "lookfx-$($Look.id)-before-detach"
    $expected = @{ streams = Get-Overlay $before 'streams'; realStreams = Get-Overlay $before 'realStreams'
        sampleStreams = Get-Overlay $before 'sampleStreams'; byLook = @{} }
    $byLook = Get-Overlay $before 'streamsByLook'
    if ($null -eq $byLook -or $null -eq $expected.streams -or $null -eq $expected.realStreams -or
        $null -eq $expected.sampleStreams -or $expected.streams -lt 1) { throw 'LookFx stream ownership snapshot is incomplete.' }
    foreach ($property in $byLook.PSObject.Properties) { $expected.byLook[$property.Name] = [int] $property.Value }
    $wasSample = $oldPage.href -match '[?&]sample=(paused|playing|noart)(?:&|$)'
    $kind = if ($wasSample) { 'sampleStreams' } else { 'realStreams' }
    if ($expected[$kind] -lt 1 -or (-not $wasSample -and $expected.byLook[$Look.id] -lt 1)) {
        throw "LookFx prior page stream for $($Look.id) was not admitted."
    }
    $release = Reset-ChromeCasePage $Chrome
    $expected.streams--; $expected[$kind]--
    if (-not $wasSample) { $expected.byLook[$Look.id]-- }
    $waitStreams = {
        param([string] $Label)
        $deadline = [DateTime]::UtcNow.AddSeconds($ordinaryStreamReleaseSeconds)
        $snapshot = Wait-For {
            $remaining = ($deadline - [DateTime]::UtcNow).TotalSeconds - .1
            if ($remaining -le 0) { return $null }
            $s = Get-State $Run.Root $Label $remaining
            $actual = Get-Overlay $s 'streamsByLook'
            if (-not $s -or $null -eq $actual) { return $null }
            $same = $null -ne $actual
            foreach ($key in @('streams', 'realStreams', 'sampleStreams')) { $same = $same -and (Get-Overlay $s $key) -eq $expected[$key] }
            foreach ($key in @(@($expected.byLook.Keys) + @($actual.PSObject.Properties.Name) | Select-Object -Unique)) {
                $same = $same -and [int] (Get-Prop $actual $key) -eq [int] $expected.byLook[$key]
            }
            if ($same) { $s }
        } $ordinaryStreamReleaseSeconds 100
        if (-not $snapshot) { throw "LookFx $Label did not preserve sibling/reader streams within $ordinaryStreamReleaseSeconds s." }
        $snapshot
    }
    $detached = & $waitStreams "lookfx-$($Look.id)-detached"
    $setup = $null
    if ($ReloadLookBeforeAdmission) {
        # The first sample look must be null/default, not the case's seeded FX followed by a reset.
        # Merge only this owned look while its fresh target is blank; siblings/readers remain admitted.
        $doc = Read-ObsLooksFile $Run.Root
        if (@($doc.looks | Where-Object { $_.id -ceq $Look.id }).Count -ne 1) {
            throw "LookFx fresh setup requires exactly one saved record for $($Look.id)."
        }
        $looks = @($doc.looks | ForEach-Object { if ($_.id -ceq $Look.id) { $Look } else { $_ } })
        [void] (Write-ObsLooksFile $Run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument $looks @($doc.retired))))
        $setup = [ordered]@{ reloadQpc = Send-ObsHookCommand $Run.Root 'command-obs-looks-reload'
            state = Get-State $Run.Root "lookfx-$($Look.id)-fresh-null-setup" }
        if (-not $setup.state) { throw "LookFx fresh null setup reload did not complete for $($Look.id)." }
        $stored = @((Read-ObsLooksFile $Run.Root).looks | Where-Object { $_.id -ceq $Look.id })
        if ($stored.Count -ne 1 -or
            (ConvertTo-Json -InputObject $stored[0] -Compress -Depth 16) -cne
            (ConvertTo-Json -InputObject $Look -Compress -Depth 16)) {
            throw "LookFx fresh null setup did not retain the expected record for $($Look.id)."
        }
    }
    Set-OverlayViewport $Chrome $Fixture.source
    [void] (Invoke-Cdp $Chrome 'Page.bringToFront')
    [void] (Invoke-ChromeNavigate $Chrome $Fixture.href)
    $connected = Wait-For { $p = Get-PageProbe $Chrome; if ((Get-PageField $p 'connection') -ceq 'open' -and
        (Get-Prop (Get-PageField $p 'look') 'id') -ceq $Look.id) { $p } } 15 100
    if (-not $connected) { throw "LookFx native $($Fixture.mode) stream did not connect for $($Look.id)." }
    $expected.streams++; $expected.sampleStreams++
    $admitted = & $waitStreams "lookfx-$($Look.id)-sample-admitted"
    [ordered]@{ release = $release; before = $before; detached = $detached; setup = $setup; admitted = $admitted }
}
function Get-LookFxShotBytes($Chrome, $Look, $Fixture) {
    $before = Wait-LookFxFixture $Chrome $Look $Fixture
    $bytes = Get-ChromeShotBytes $Chrome
    $after = Get-LookFxProbe $Chrome -NoFx:((Get-Prop $Fixture 'noFx') -eq $true)
    $Fixture.captures.Add([ordered]@{ before = $before; after = $after })
    $failed = @(Get-LookFxFixtureFailures $after $Look $Fixture)
    if ($failed.Count -gt 0) { throw "LookFx $($Fixture.mode) fixture changed during capture for $($Look.id); failed terms: $($failed -join ', ')." }
    ,$bytes
}
function Get-LookFxIdentityCapture($Chrome, $Look, $Fixture, [string] $Stem, [string] $CheckName, [switch] $PaintDiagnostic) {
    $Chrome = Resolve-Chrome $Chrome
    $target = Get-Prop (Invoke-Cdp $Chrome 'Target.getTargetInfo') 'targetInfo'
    if ((Get-Prop $target 'targetId') -cne $Chrome.TargetId) { throw 'LookFx capture is not attached to its owned target.' }
    [void] (Invoke-Cdp $Chrome 'Page.bringToFront')
    [void] (Wait-LookFxFixture $Chrome $Look $Fixture)
    $paintExpression = @'
new Promise(resolve => requestAnimationFrame(first => requestAnimationFrame(second => resolve({
  first, second, href:location.href, visibility:document.visibilityState, hasFocus:document.hasFocus()
}))))
'@
    $frames = [Collections.Generic.List[object]]::new()
    $shots = [Collections.Generic.List[byte[]]]::new()
    for ($i = 0; $i -lt 2; $i++) {
        $eventStart = (Resolve-Chrome $Chrome).Events.Count
        # The second frame is an unchanged-state recapture, never a replacement for the first.
        $paintResult = Invoke-Cdp $Chrome 'Runtime.evaluate' @{ expression = $paintExpression; awaitPromise = $true; returnByValue = $true }
        if (Get-Prop $paintResult 'exceptionDetails') { throw 'LookFx identity paint barrier failed.' }
        $paint = Get-Prop (Get-Prop $paintResult 'result') 'value'
        $before = Get-LookFxProbe $Chrome -NoFx:((Get-Prop $Fixture 'noFx') -eq $true)
        $bytes = Get-ChromeShotBytes $Chrome
        $path = Join-Path $shotDirectory "$Stem$(if ($i -eq 1) { '-recapture' }).png"
        [IO.File]::WriteAllBytes($path, $bytes)
        $after = Get-LookFxProbe $Chrome -NoFx:((Get-Prop $Fixture 'noFx') -eq $true)
        $failures = @((Get-LookFxFixtureFailures $before $Look $Fixture); (Get-LookFxFixtureFailures $after $Look $Fixture))
        $active = $paint.visibility -ceq 'visible' -and $paint.hasFocus -eq $true -and $paint.href -ceq $Fixture.href -and
            $before.captureMetadata.visibility -ceq 'visible' -and $before.captureMetadata.hasFocus -eq $true -and
            $after.captureMetadata.visibility -ceq 'visible' -and $after.captureMetadata.hasFocus -eq $true
        $frame = [ordered]@{ TargetId = $Chrome.TargetId; activeOwnedTarget = [bool] $active; paint = $paint
            image = [IO.Path]::GetRelativePath($runDirectory, $path); before = $before; after = $after; fixtureFailures = $failures }
        if ($PaintDiagnostic) {
            $frame['layers'] = Get-FxPaintLayerSnapshot $Chrome
            $frame['layerEvents'] = @($Chrome.Events | Select-Object -Skip $eventStart | Where-Object { $_.method -like 'LayerTree.*' })
        }
        $Fixture.captures.Add($frame); $frames.Add($frame); $shots.Add($bytes)
    }
    $diffPath = Join-Path $shotDirectory "$Stem-capture-diff.png"
    $pixels = Compare-Png $shots[0] $shots[1] $diffPath 0
    $valid = $pixels.differing -eq 0 -and @($frames | Where-Object {
        -not $_.activeOwnedTarget -or $_.fixtureFailures.Count -gt 0
    }).Count -eq 0
    $record = [ordered]@{ valid = [bool] $valid; frames = $frames; pixels = $pixels
        diffImage = [IO.Path]::GetRelativePath($runDirectory, $diffPath) }
    $evidencePath = Join-Path $runDirectory "$Stem-capture.json"
    [IO.File]::WriteAllText($evidencePath, (ConvertTo-Json -InputObject $record -Depth 24), [Text.UTF8Encoding]::new($false))
    Add-Check $CheckName 'valid capture evidence: active owned target, two rAF callbacks per frame, unchanged fixture and exact RGBA recapture' $record $valid
    [pscustomobject]@{ bytes = $shots[0]; valid = [bool] $valid; evidence = $record }
}
function Push-LookFx($Run, $Chrome, $Look, $Fixture = $null) {
    # Preserve sibling looks in a grouped geometry batch.
    $doc = Read-ObsLooksFile $Run.Root
    $prior = @($doc.looks | Where-Object { $_.id -ceq $Look.id })
    if ($prior.Count -ne 1) { throw "LookFx requires exactly one saved record for $($Look.id)." }
    $expected = ConvertTo-Json -InputObject $Look -Depth 16 | ConvertFrom-Json -Depth 16
    $changed = $prior[0].name -cne $expected.name
    $optionKeys = @(@($prior[0].options.PSObject.Properties.Name) + @($expected.options.PSObject.Properties.Name) | Select-Object -Unique)
    foreach ($key in $optionKeys) {
        if ((Get-Prop $prior[0].options $key) -cne (Get-Prop $expected.options $key)) { $changed = $true }
    }
    $before = if ($Fixture) { Wait-LookFxFixture $Chrome $prior[0] $Fixture } else { Get-PageProbe $Chrome }
    $epoch = Get-PageField $before 'lookEpoch'; $seq = Get-PageField $before 'lookSeq'
    $looks = @($doc.looks | ForEach-Object { if ($_.id -ceq $Look.id) { $Look } else { $_ } })
    $rewritten = ConvertTo-ObsLooksJson (New-ObsLooksDocument $looks @($doc.retired))
    $path = Write-ObsLooksFile $Run.Root $rewritten
    $evidence = [ordered]@{ id = $Look.id; changed = $changed; priorRecord = $prior[0]; expectedRecord = $expected
        beforeEpoch = $epoch; beforeSeq = $seq; lastPage = $before; reloadState = $null
        rewrittenDocument = $rewritten; diskHash = Get-Sha256 $path; storedName = $null; newEvent = $false }
    try {
        $evidence['reloadQpc'] = Send-ObsHookCommand $Run.Root 'command-obs-looks-reload'
        # Command-file consumption precedes the awaited reload; the next command tick is the completion barrier.
        $evidence.reloadState = Get-State $Run.Root "lookfx-$($Look.id)-reload"
        if (-not $evidence.reloadState) { throw 'LookFx reload-completion snapshot timed out.' }
        $page = Wait-For {
            $p = Get-PageProbe $Chrome; $evidence.lastPage = $p; $o = Get-PageField $p 'options'
            $same = $p -and (Get-Prop (Get-PageField $p 'look') 'id') -ceq $expected.id
            foreach ($key in $expected.options.PSObject.Properties.Name) {
                $same = $same -and (Get-Prop $o $key) -ceq (Get-Prop $expected.options $key)
            }
            $newEvent = $null -ne $epoch -and $null -ne $seq -and
                (Get-PageField $p 'lookEpoch') -ceq $epoch -and (Get-PageField $p 'lookSeq') -gt $seq
            $evidence.newEvent = [bool] $newEvent
            if ($same -and (-not $changed -or $newEvent)) { $p }
        } 10 25
        if (-not $page) { throw "LookFx native push was not acknowledged for $($Look.id)." }
        $stored = @( (Read-ObsLooksFile $Run.Root).looks | Where-Object { $_.id -ceq $Look.id })
        $evidence.storedName = if ($stored.Count -eq 1) { $stored[0].name } else { $null }
        if ($evidence.storedName -cne $expected.name) { throw "LookFx stored name does not match for $($Look.id)." }
        Start-Sleep -Milliseconds 150
        $result = if ($Fixture) { Wait-LookFxFixture $Chrome $expected $Fixture } else { Get-LookFxProbe $Chrome }
        $result | Add-Member -NotePropertyName lookPush -NotePropertyValue $evidence -Force
        $result
    } catch {
        $evidence['error'] = $_.Exception.Message
        if (-not $evidence.reloadState) {
            try { $evidence.reloadState = Get-State $Run.Root "lookfx-$($Look.id)-failure" 2 }
            catch { $evidence['reloadStateError'] = $_.Exception.Message }
        }
        $evidence['reloadStore'] = Get-Overlay $evidence.reloadState 'looks'
        try {
            $evidence.diskHash = Get-Sha256 $path
            $evidence['actualDocument'] = Get-Content -Raw -LiteralPath $path
        } catch { $evidence['diskEvidenceError'] = $_.Exception.Message }
        $failurePath = Join-Path $runDirectory "lookfx-push-$($script:labelSeq)-$(ConvertTo-SafeName $Look.id)-failure.json"
        [IO.File]::WriteAllText($failurePath, (ConvertTo-Json -InputObject $evidence -Depth 20), [Text.UTF8Encoding]::new($false))
        throw "$($evidence.error) Evidence: $([IO.Path]::GetRelativePath($runDirectory, $failurePath))"
    }
}
function Test-LookFxCounters($Before, $After, [int] $Draws) {
    $a = Get-PageField $Before 'counters'; $b = Get-PageField $After 'counters'
    $null -ne (Get-Prop $a 'blurDraws') -and $null -ne (Get-Prop $b 'blurDraws') -and
        [int] $b.blurDraws - [int] $a.blurDraws -eq $Draws -and
        $a.coverLoads -eq $b.coverLoads -and $a.quantizerRuns -eq $b.quantizerRuns -and
        @($Before.art).Count -eq @($After.art).Count
}
function Test-LookFxRgb([string] $Colour, [double[]] $Expected) {
    $numbers = @([regex]::Matches($Colour, '[\d.]+') | ForEach-Object { [double] $_.Value })
    if ($numbers.Count -eq 3) { $numbers += 1.0 }
    $numbers.Count -eq 4 -and @((0..3) | Where-Object {
        [Math]::Abs($numbers[$_] - $Expected[$_]) -gt 0.001
    }).Count -eq 0
}
function Test-LookFxColours($Page, $Baseline, [string] $Theme, $Options) {
    $d = Get-LookFxDefaults $Theme
    $p = Get-Prop $Options 'playedBrightness'; if ($null -eq $p) { $p = $d.playedBrightness }
    $u = Get-Prop $Options 'unplayedBrightness'; if ($null -eq $u) { $u = $d.unplayedBrightness }
    $b = Get-Prop $Options 'backgroundBrightness'; if ($null -eq $b) { $b = $d.backgroundBrightness }
    $blur = Get-Prop $Options 'backgroundBlur'; if ($null -eq $blur) { $blur = $d.backgroundBlur }
    $resolved = $Page.fx.resolved
    $ok = $resolved.blur -eq $blur -and $resolved.played -eq $p -and $resolved.unplayed -eq $u -and $resolved.background -eq $b
    if ($Theme -ne 'pill') {
        $base = if ((Get-Prop $Options 'colours') -eq 'custom') { $Options.accent }
            elseif ($Theme -in @('matte', 'matte-light')) { Get-PageField $Baseline 'accent' } else { '#ffffff' }
        $rgb = @(@(1, 3, 5) | ForEach-Object {
            [Math]::Min([double] 255, [Math]::Floor([Convert]::ToInt32($base.Substring($_, 2), 16) * $p / 100 + 0.5))
        })
        $alpha = switch ($Theme) { 'matte' { .12 } 'matte-light' { .18 } 'simple' { .4 } 'album-art' { .3 } default { .25 } }
        $greyValue = [Math]::Floor(255 * $u / 100 + 0.5)
        $ok = $ok -and (Test-LookFxRgb $Page.fx.played ($rgb + @(1))) -and
            (Test-LookFxRgb $Page.fx.track @($greyValue, $greyValue, $greyValue, $alpha))
        if ($Theme -eq 'classic') { $ok = $ok -and (Test-LookFxRgb $Page.fx.head ($rgb + @(1))) }
    }
    $active = $Theme -eq 'pill' -or ($Theme -in @('standard', 'classic', 'card') -and $Options.colours -eq 'auto') -or
        ($Theme -eq 'album-art' -and $Options.showArt)
    if ($active -and (Get-PageField $Page 'artFailed') -eq $false) {
        $key = ConvertFrom-Json -InputObject (Get-PageField $Page 'rasterKey') -NoEnumerate
        $expectedKey = if ($Theme -eq 'pill') { @($blur, $p, $u, $b) } else { @($blur, $b) }
        $ok = $ok -and (ConvertTo-Json -InputObject $key[8] -Compress) -ceq (ConvertTo-Json -InputObject $expectedKey -Compress)
        $c = $Page.fx.canvases
        $k = [double] $Options.scale / 100
        $radius = [Math]::Floor($blur * $k * 10 + .5) / 10
        if ($Theme -eq 'pill') {
            $ok = $ok -and [Math]::Abs($c.colour.blur - $radius) -lt .001 -and
                [Math]::Abs($c.colour.brightness - $p / 100 * $b / 100) -lt .001 -and $c.colour.saturate -eq 1.3 -and
                [Math]::Abs($c.grey.blur - $radius) -lt .001 -and
                [Math]::Abs($c.grey.brightness - $u / 100 * $b / 100) -lt .001 -and $c.grey.grayscale -eq .75 -and
                [Math]::Abs($c.grey.alpha - .6) -lt .001
        } elseif ($Theme -eq 'album-art') {
            $enabled = $blur -ne 0 -or $b -ne 100
            $ok = $ok -and $(if ($enabled) {
                $s = if ($radius -gt 0) { [Math]::Min([double] 1, [Math]::Sqrt(100000 / ([double] $Options.width * $Options.width))) } else { [double] 1 }
                $Page.fx.coverFx -eq 'true' -and $Page.fx.styles.'cover-fx'.display -ne 'none' -and
                    [Math]::Abs($c.'cover-fx'.blur - $radius * $s) -lt .001 -and
                    [Math]::Abs($c.'cover-fx'.brightness - $b / 100) -lt .001 -and $c.'cover-fx'.saturate -eq 1
            } else { $Page.fx.coverFx -ne 'true' -and $Page.fx.styles.'cover-fx'.display -eq 'none' })
        } else {
            $cssW = [double] $Options.width - $(if ($Theme -eq 'classic' -and $Options.showArt) { 90 * $k } else { 0 })
            $s = [Math]::Min([double] 1, [Math]::Sqrt(100000 / ($cssW * [double] (Get-PageField $Page 'box').h)))
            $ok = $ok -and [Math]::Abs($c.colour.blur - $radius * $s) -lt .001 -and
                [Math]::Abs($c.colour.brightness - $b / 100) -lt .001 -and $c.colour.saturate -eq 1.2
        }
    }
    [bool] $ok
}
function ConvertTo-LookFxNormalizedOptions($Options) {
    $normalized = [ordered]@{}
    $copy = if ($Options -is [Collections.IDictionary]) { $Options } else {
        $values = [ordered]@{}
        foreach ($property in $Options.PSObject.Properties) { $values[$property.Name] = $property.Value }
        $values
    }
    $defaults = Get-LookFxDefaults $copy.theme
    foreach ($key in @($copy.Keys | Sort-Object)) {
        $normalized[$key] = if ($defaults.Contains($key) -and $null -eq $copy[$key]) { $defaults[$key] } else { $copy[$key] }
    }
    $normalized
}
function Test-LookFxRestoredMetadata($Reference, $Page) {
    # Fixture validation checks complete expected options/art/source/state on both sides of every capture.
    # Keep exact resolved FX, raster/style and DOM geometry identity independent of the pixel differential.
    $terms = [ordered]@{
        options = (ConvertTo-Json -InputObject (ConvertTo-LookFxNormalizedOptions $Reference.captureMetadata.options) -Compress -Depth 16) -ceq
            (ConvertTo-Json -InputObject (ConvertTo-LookFxNormalizedOptions $Page.captureMetadata.options) -Compress -Depth 16)
        fx = (ConvertTo-Json -InputObject $Reference.fx -Compress -Depth 16) -ceq
            (ConvertTo-Json -InputObject $Page.fx -Compress -Depth 16)
        elements = (ConvertTo-Json -InputObject $Reference.captureMetadata.elements -Compress -Depth 16) -ceq
            (ConvertTo-Json -InputObject $Page.captureMetadata.elements -Compress -Depth 16)
        geometry = (ConvertTo-Json -InputObject $Reference.geometry -Compress -Depth 16) -ceq
            (ConvertTo-Json -InputObject $Page.geometry -Compress -Depth 16)
        boxRect = (ConvertTo-Json -InputObject $Reference.boxRect -Compress -Depth 16) -ceq
            (ConvertTo-Json -InputObject $Page.boxRect -Compress -Depth 16)
        nativeFixture = (ConvertTo-Json -InputObject $Reference.nativeFixture -Compress -Depth 16) -ceq
            (ConvertTo-Json -InputObject $Page.nativeFixture -Compress -Depth 16)
        images = (ConvertTo-Json -InputObject $Reference.captureMetadata.images -Compress -Depth 16) -ceq
            (ConvertTo-Json -InputObject $Page.captureMetadata.images -Compress -Depth 16)
        animations = (ConvertTo-Json -InputObject $Reference.captureMetadata.animations -Compress -Depth 16) -ceq
            (ConvertTo-Json -InputObject $Page.captureMetadata.animations -Compress -Depth 16)
        css = (ConvertTo-Json -InputObject $Reference.css -Compress -Depth 16) -ceq
            (ConvertTo-Json -InputObject $Page.css -Compress -Depth 16)
        attrs = (ConvertTo-Json -InputObject $Reference.attrs -Compress -Depth 16) -ceq
            (ConvertTo-Json -InputObject $Page.attrs -Compress -Depth 16)
        pageSize = (ConvertTo-Json -InputObject $Reference.pageSize -Compress -Depth 16) -ceq
            (ConvertTo-Json -InputObject $Page.pageSize -Compress -Depth 16)
        opacity = $Reference.opacity -ceq $Page.opacity
        fill = $Reference.clipPx -ceq $Page.clipPx -and $Reference.frac -ceq $Page.frac
    }
    @($terms.Values | Where-Object { -not $_ }).Count -eq 0
}
function Get-LookFxPaintSignature($Case, $Page, [string] $Stage, [ref] $IneligibleReason = $null) {
    if ($null -eq $IneligibleReason) { $ignoredReason = $null; $IneligibleReason = [ref] $ignoredReason }
    $IneligibleReason.Value = $null
    # Registered from retained pre-LookFx 8ce7688 frames, not learned from the current differential.
    # Fresh null/explicit and all undocumented pure-FX paths always remain absolute0.
    if ($Stage -eq 'initial-explicit') { $IneligibleReason.Value = 'fresh-initial-explicit-requires-exact0'; return $null }
    if ($Case.theme -notin @('simple', 'album-art')) { $IneligibleReason.Value = 'unregistered-theme'; return $null }
    $registeredCases = @('fx-default', 'fx-played-min', 'fx-played-max', 'fx-unplayed-min', 'fx-unplayed-max')
    if ($Case.theme -eq 'album-art') { $registeredCases += @('fx-blur-0', 'fx-blur-max', 'fx-bg-min', 'fx-bg-max') }
    if ($Case.case -notin $registeredCases) { $IneligibleReason.Value = 'unregistered-case'; return $null }
    if ($Stage -eq 'pure-reset' -and -not (
        ($Case.theme -eq 'simple' -and $Case.case -eq 'fx-played-min') -or
        ($Case.theme -eq 'album-art' -and $Case.case -eq 'fx-unplayed-min'))) {
        $IneligibleReason.Value = 'unregistered-pure-reset-case'; return $null
    }
    if ($Stage -notin @('pure-reset', 'reset', 'final-explicit')) { $IneligibleReason.Value = 'unregistered-stage'; return $null }
    $simple = $Case.theme -eq 'simple'
    $expected = [ordered]@{ theme = $Case.theme; font = $null; scale = 100
        width = $(if ($simple) { 440 } else { 200 }); align = 'left'; colours = 'auto'; text = '#ffffff'
        background = $(if ($simple) { '#202020' } else { '#000000' })
        backgroundOpacity = $(if ($simple) { 100 } else { 80 }); accent = '#8a8a95'
        backgroundBlur = 0; playedBrightness = 100; unplayedBrightness = $(if ($simple) { 0 } else { 100 })
        backgroundBrightness = 100; textShadow = $true; showArt = $true; showArtist = $true
        showProgress = $true; showTimes = $true; paused = 'dim'; showAnimation = 'slide-up'; hideAnimation = 'fade' }
    if ((ConvertTo-Json -InputObject (ConvertTo-LookFxNormalizedOptions $expected) -Compress) -cne
        (ConvertTo-Json -InputObject (ConvertTo-LookFxNormalizedOptions $Page.captureMetadata.options) -Compress)) {
        $IneligibleReason.Value = 'nondefault-normalized-options'; return $null
    }
    $elements = $Page.captureMetadata.elements
    $bar = $elements.bar; $fill = $elements.barfill; $scrim = $elements.scrim
    $dimensions = if ($simple) { @(480, 120, 440, 80, 158, 82, 252, -6, 246, 88) } else { @(240, 240, 200, 200, 32, 210, 176, -82, 94, 62) }
    if ($Page.pageSize.width -ne $dimensions[0] -or $Page.pageSize.height -ne $dimensions[1] -or $Page.pageSize.dpr -ne 1 -or
        $Page.boxRect.x -ne 20 -or $Page.boxRect.y -ne 20 -or
        $Page.boxRect.width -ne $dimensions[2] -or $Page.boxRect.height -ne $dimensions[3] -or
        $bar.rect.x -ne $dimensions[4] -or $bar.rect.y -ne $dimensions[5] -or $bar.rect.width -ne $dimensions[6] -or $bar.rect.height -ne 3 -or
        $fill.rect.x -ne $dimensions[7] -or $fill.rect.right -ne $dimensions[8] -or $fill.rect.y -ne $dimensions[5] -or
        $fill.rect.width -ne $dimensions[6] -or $fill.rect.height -ne 3 -or $Page.clipPx -ne $dimensions[9] -or
        $Page.opacity -ne .7 -or $Page.fx.played -cne 'rgb(255, 255, 255)' -or
        $Page.fx.track -cne $(if ($simple) { 'rgba(0, 0, 0, 0.4)' } else { 'rgba(255, 255, 255, 0.3)' }) -or
        $Page.fx.resolved.blur -ne 0 -or $Page.fx.resolved.played -ne 100 -or
        $Page.fx.resolved.unplayed -ne $expected.unplayedBrightness -or $Page.fx.resolved.background -ne 100 -or
        $Page.fx.coverFx -cne 'false' -or $Page.fx.requestedArt -cne '/art/sample' -or $Page.fx.loadedArt -cne '/art/sample' -or
        (ConvertTo-Json -InputObject $Page.fx.artPixel -Compress) -cne '[102,65,172,255]') {
        $IneligibleReason.Value = 'default-source-geometry-fill-or-paint-state-mismatch'; return $null
    }
    if ($bar.customProperties.'--played-fill' -cne '' -or $bar.customProperties.'--unplayed-track' -cne '' -or
        $bar.customProperties.'--bg' -cne $expected.background -or
        $bar.customProperties.'--bg-a' -cne $(if ($simple) { '1' } else { '0.8' })) {
        $IneligibleReason.Value = 'nondefault-paint-variables'; return $null
    }
    # overlayUrl already ends in '/'; URI resolution preserves the exact /art/sample identity.
    $expectedArtSource = [Uri]::new([Uri] $overlayUrl, 'art/sample').AbsoluteUri
    foreach ($image in $Page.captureMetadata.images) {
        if (-not $image.complete -or $image.naturalWidth -ne 256 -or $image.naturalHeight -ne 256) {
            $IneligibleReason.Value = 'artwork-not-loaded-at-registered-size'; return $null
        }
        if ($image.src -cne $expectedArtSource) {
            $IneligibleReason.Value = "artwork-source-mismatch: expected=$expectedArtSource; actual=$($image.src)"; return $null
        }
    }
    if (@($Page.captureMetadata.images).Count -ne 2 -or @($Page.captureMetadata.animations).Count -ne 0) {
        $IneligibleReason.Value = 'image-count-or-animation-state-mismatch'; return $null
    }
    $root = 'artifacts/obs-overlay/20261005T011732Z/screenshots/'
    if ($simple) {
        if ($bar.transform -cne 'matrix(1, 0, 0, 1, 0, 0.5)' -or $fill.transform -cne 'matrix(1, 0, 0, 1, -164, 0)') {
            $IneligibleReason.Value = 'Simple-default-fill-transforms-mismatch'; return $null
        }
        return [ordered]@{ name = 'pre-LookFx.Simple.played-fill-top-AA.v1'; region = @(158, 82, 245, 82)
            width = 480; height = 120; preLookFxCommit = '8ce7688'; evidence = @(
                @{ path = "${root}fxpaint-simple-no-fx-custom-auto-default.png"; sha256 = 'ad5bcd5c13af0e325af105276630f7b0c2de6f2aa7e3b46538b3b97de40c6175' },
                @{ path = "${root}fxpaint-simple-no-fx-custom-auto-reset.png"; sha256 = '8c999f3f1be15f1f49f05c39b09b798ee91d5ab86881ca84327b45d566514693' }) }
    }
    if ($bar.transform -cne 'none' -or $fill.transform -cne 'matrix(1, 0, 0, 1, -114, 0)' -or
        $scrim.rect.x -ne 20 -or $scrim.rect.y -ne 132 -or $scrim.rect.width -ne 200 -or $scrim.rect.height -ne 88 -or
        $scrim.opacity -cne '0.8' -or $scrim.backgroundImage -cne 'linear-gradient(rgba(0, 0, 0, 0), rgb(0, 0, 0))' -or
        $scrim.customProperties.'--bg' -cne '#000000' -or $scrim.customProperties.'--bg-a' -cne '0.8' -or
        $bar.customProperties.'--played-fill' -cne '' -or $bar.customProperties.'--unplayed-track' -cne '') {
        $IneligibleReason.Value = 'Album-default-scrim-track-or-transform-mismatch'; return $null
    }
    [ordered]@{ name = 'pre-LookFx.Album.scrim-band-with-unplayed-track.v1'; region = @(20, 132, 219, 219)
        width = 240; height = 240; preLookFxCommit = '8ce7688'; evidence = @(
            @{ path = "${root}fxpaint-album-art-no-fx-custom-auto-default.png"; sha256 = 'e34ac2297c6596489e10f2f3120ce7e7a3cb1d7f70c0fafce52e03dc1ed1d713' },
            @{ path = "${root}fxpaint-album-art-no-fx-custom-auto-reset.png"; sha256 = '5859ecd4c727c5626cbd521b2330cf564788c45aa5c628d4dff10dbc4cb22cd8' },
            @{ path = "${root}fxpaint-album-art-no-fx-showart-false-true-default.png"; sha256 = 'e34ac2297c6596489e10f2f3120ce7e7a3cb1d7f70c0fafce52e03dc1ed1d713' },
            @{ path = "${root}fxpaint-album-art-no-fx-showart-false-true-reset.png"; sha256 = '8ce3d264745a0d815637c5ef5305a01094ef129837e88d62ba4ca33b741b9dcd' }) }
}
function Compare-LookFxPaint($Reference, $Capture, $Case, [string] $Stage, [string] $Stem) {
    $diffPath = Join-Path $shotDirectory "$Stem-$Stage-absolute-diff.png"
    $pixels = Compare-Png $Reference.bytes $Capture.bytes $diffPath 0
    $referencePage = $Reference.evidence.frames[0].before
    $valid = $Reference.valid -and $Capture.valid
    $restored = $valid
    foreach ($frame in @($Reference.evidence.frames) + @($Capture.evidence.frames)) {
        foreach ($page in @($frame.before, $frame.after)) {
            if (-not (Test-LookFxRestoredMetadata $referencePage $page)) { $restored = $false }
        }
    }
    $signatureIneligibleReason = if (-not $valid) { 'invalid-capture' } elseif (-not $restored) { 'restored-state-mismatch' } else { $null }
    $signature = if ($valid -and $restored) {
        Get-LookFxPaintSignature $Case $referencePage $Stage ([ref] $signatureIneligibleReason)
    } else { $null }
    $max = [ordered]@{ r = 0; g = 0; b = 0; a = 0 }
    $outside = 0; $alpha = 0; $invalid = 0
    $expectedStream = [IO.MemoryStream]::new($Reference.bytes); $actualStream = [IO.MemoryStream]::new($Capture.bytes)
    $expected = $null; $actual = $null
    try {
        $expected = [Drawing.Bitmap]::new($expectedStream); $actual = [Drawing.Bitmap]::new($actualStream)
        $sameSize = $expected.Width -eq $actual.Width -and $expected.Height -eq $actual.Height
        if ($sameSize) {
            for ($y = 0; $y -lt $expected.Height; $y++) {
                for ($x = 0; $x -lt $expected.Width; $x++) {
                    $a = $expected.GetPixel($x, $y); $b = $actual.GetPixel($x, $y)
                    $dr = [int] $b.R - [int] $a.R; $dg = [int] $b.G - [int] $a.G
                    $db = [int] $b.B - [int] $a.B; $da = [int] $b.A - [int] $a.A
                    $max.r = [Math]::Max($max.r, [Math]::Abs($dr)); $max.g = [Math]::Max($max.g, [Math]::Abs($dg))
                    $max.b = [Math]::Max($max.b, [Math]::Abs($db)); $max.a = [Math]::Max($max.a, [Math]::Abs($da))
                    if ($da -ne 0) { $alpha++ }
                    if ($dr -eq 0 -and $dg -eq 0 -and $db -eq 0 -and $da -eq 0) { continue }
                    $inside = $signature -and $x -ge $signature.region[0] -and $x -le $signature.region[2] -and
                        $y -ge $signature.region[1] -and $y -le $signature.region[3]
                    if (-not $inside) { $outside++; continue }
                    if ($Case.theme -eq 'simple') {
                        $delta = if ($x -eq 158) { 2 } else { 9 }
                        if ($dr -ne $dg -or $dr -ne $db -or [Math]::Abs($dr) -ne $delta) { $invalid++ }
                    } elseif ([Math]::Abs($dr) -gt 1 -or [Math]::Abs($dg) -gt 1 -or [Math]::Abs($db) -gt 1) { $invalid++ }
                }
            }
        }
    } finally {
        if ($actual) { $actual.Dispose() }; if ($expected) { $expected.Dispose() }
        $actualStream.Dispose(); $expectedStream.Dispose()
    }
    $exact = $sameSize -and $pixels.differing -eq 0
    $known = $valid -and $restored -and $signature -and $sameSize -and $pixels.width -eq $signature.width -and
        $pixels.height -eq $signature.height -and $pixels.differing -gt 0 -and $outside -eq 0 -and $alpha -eq 0 -and $invalid -eq 0
    if (-not $sameSize) { $max = $null; $outside = $null; $alpha = $null; $invalid = $null }
    [ordered]@{ exactPixels = [bool] $exact; matchesKnownPaintSignature = [bool] $known
        differingPixels = $pixels.differing; maxDeltas = $max; outsideRegionCount = $outside
        alphaDifferenceCount = $alpha; invalidSignatureCount = $invalid; validCapture = [bool] $valid
        exactRestoredState = [bool] $restored; accepted = [bool] ($valid -and $restored -and ($exact -or $known))
        acceptance = $(if (-not ($valid -and $restored -and ($exact -or $known))) { 'rejected' } elseif ($exact) { 'exact0' } else { 'known-paint-signature (not exact0)' })
        signature = $signature; signatureIneligibleReason = $signatureIneligibleReason; absolutePixels = $pixels; evidencePaths = @(
            $Reference.evidence.frames.image; $Capture.evidence.frames.image
            [IO.Path]::GetRelativePath($runDirectory, $diffPath); "$Stem-$Stage-capture.json"; "$Stem-null-capture.json"
            if ($signature) { $signature.evidence.path }) }
}

function Test-LookFxCase($Run, $Chrome, $Case, $Source) {
    $prefix = "A-LOOK.$($Case.theme).$($Case.case)"
    $nullOptions = Copy-LookOptions $Case.options
    foreach ($key in (Get-LookFxDefaults $Case.theme).Keys) { $nullOptions[$key] = $null }
    $look = New-ObsLook $Case.lookId "$($Case.theme) $($Case.case)" $nullOptions
    # Native sample streams keep their own song/clock/artwork when SetLooks pushes paired data.
    $fixture = @{ mode = 'paused'; source = $Source; href = "$($overlayUrl)?look=$($look.id)&sample=paused"
        captures = [Collections.Generic.List[object]]::new() }
    $stem = "$($Case.theme)-$($Case.case)"
    $actions = [Collections.Generic.List[object]]::new()
    $comparisons = [ordered]@{ initialExplicit = $null; pureReset = $null; reset = $null; explicit = $null }
    $identityCaptures = [ordered]@{}
    $baselineBehavior = [ordered]@{
        observation = 'Zero tolerance by default; only registered pre-LookFx paint signatures may pass with nonzero pixels, exact restored state and valid recaptures.'
        preLookFxCommit = '8ce7688'
        currentRun = 'artifacts/obs-overlay/20261005T011507Z'
        preLookFxRun = 'artifacts/obs-overlay/20261005T011732Z'
        regions = @(
            [ordered]@{ theme = 'simple'; history = 'Custom to Auto'; differingPixels = 88; region = 'antialiased edge of the played fill' },
            [ordered]@{ theme = 'album-art'; history = 'Custom to Auto'; differingPixels = 3511; region = 'scrim dither, channel differences of plus/minus 1' },
            [ordered]@{ theme = 'album-art'; history = 'ShowArt false to true'; differingPixels = 6629; region = 'scrim dither, channel differences of plus/minus 1' }
        )
        upstreamCause = 'not proved'; visibility = 'not assessed'
    }
    $evidence = [ordered]@{ baselineBehavior = $baselineBehavior; actions = $actions; pixels = $comparisons
        identityCaptures = $identityCaptures; fixture = $fixture }
    $recordStage = {
        param([string] $Stage, $Page)
        $record = [ordered]@{ stage = $Stage; name = $look.name; options = Copy-LookOptions $look.options
            pairedDelivery = [bool] $Page.lookPush.newEvent; page = $Page; capture = "$stem-$Stage-capture.json" }
        $actions.Add($record)
        $capture = Get-LookFxIdentityCapture $Chrome $look $fixture "$stem-$Stage" "$prefix.captureEvidence.$Stage"
        $record['evidence'] = $capture.evidence
        $identityCaptures[$Stage] = $capture.evidence
        $capture
    }
    try {
    $samplePage = Set-LookFxSamplePage $Run $Chrome $look $fixture -ReloadLookBeforeAdmission
    $evidence['samplePage'] = $samplePage
    $baseline = Push-LookFx $Run $Chrome $look $fixture
    $nullCapture = & $recordStage 'null' $baseline
    $initialIdentity = $true
    if ($Case.case -eq 'fx-default') {
        $look.options = Copy-LookOptions $Case.options
        $initialExplicit = Push-LookFx $Run $Chrome $look $fixture
        $initialExplicitCapture = & $recordStage 'initial-explicit' $initialExplicit
        $initialPixels = Compare-LookFxPaint $nullCapture $initialExplicitCapture $Case 'initial-explicit' $stem
        $initialIdentity = $initialPixels.accepted
        $comparisons.initialExplicit = $initialPixels
        Add-Check "$prefix.defaultIdentity.initialExplicit" 'fresh initial null and explicit defaults are absolutely RGBA/style/geometry identical, zero pixels' $initialPixels $initialIdentity
        $look.options = Copy-LookOptions $nullOptions
        $baseline = Push-LookFx $Run $Chrome $look $fixture
        [void] (& $recordStage 'initial-null-return' $baseline)
    }
    # Initial explicit/reset draws are legitimate setup; the effect/cache check uses a fresh counter baseline.
    $baseline = Wait-LookFxFixture $Chrome $look $fixture
    $look.options = Copy-LookOptions $Case.options
    $changed = Push-LookFx $Run $Chrome $look $fixture
    [void] (& $recordStage 'effect' $changed)
    Add-Check "$prefix.colours" 'resolved values, bar RGB/alpha or both canvas filters and applicable raster effect tuple match independent defaults' $changed (Test-LookFxColours $changed $baseline $Case.theme $look.options)
    $defaults = Get-LookFxDefaults $Case.theme
    $rasterKeys = if ($Case.theme -eq 'pill') { @($defaults.Keys) }
        elseif ($Case.theme -in @('standard', 'classic', 'card', 'album-art')) { @('backgroundBlur', 'backgroundBrightness') } else { @() }
    $expectedChange = @($rasterKeys | Where-Object {
        $value = Get-Prop $Case.options $_
        $null -ne $value -and $value -ne $defaults[$_]
    }).Count -gt 0
    $draws = if ($expectedChange -and $Case.theme -in @('pill', 'standard', 'classic', 'card')) { 1 }
        elseif ($expectedChange -and $Case.theme -eq 'album-art') { 1 } else { 0 }
    Add-Check "$prefix.cache" 'effect-only push draws exactly once iff applicable; progress-only non-pill edits draw zero; no cover fetch or matte quantization' (
        [ordered]@{ before = $baseline; after = $changed; expectedDraws = $draws }) (
        (Test-LookFxCounters $baseline $changed $draws) -and
        ((Get-PageField $baseline 'rasterKey') -cne (Get-PageField $changed 'rasterKey')) -eq $expectedChange)
    $protected = @('stripe', 'scrim', 'title', 'artist')
    $stylesSame = @($protected | Where-Object {
        (ConvertTo-Json -InputObject $baseline.fx.styles.$_ -Compress) -cne (ConvertTo-Json -InputObject $changed.fx.styles.$_ -Compress)
    }).Count -eq 0
    Add-Check "$prefix.protectedStyles" 'matte stripe, album scrim and text styles are unchanged; sampled matte floor precedes dimming' (
        [ordered]@{ baseline = $baseline.fx.styles; changed = $changed.fx.styles; accent = Get-PageField $baseline 'accent' }) (
        $stylesSame -and $(if ($Case.theme -eq 'matte') {
            $hex = Get-PageField $baseline 'accent'
            $luma = (.2126 * [Convert]::ToInt32($hex.Substring(1,2),16) + .7152 * [Convert]::ToInt32($hex.Substring(3,2),16) + .0722 * [Convert]::ToInt32($hex.Substring(5,2),16)) / 255
            $luma -ge .5 -and (Get-PageField $changed 'accent') -ceq $hex
        } else { $true }))
    $equal = Push-LookFx $Run $Chrome $look $fixture
    [void] (& $recordStage 'equal' $equal)
    Add-Check "$prefix.equal" 'equal native reload causes no raster work and retains raster key/styles' $equal (
        (Test-LookFxCounters $changed $equal 0) -and (Get-PageField $changed 'rasterKey') -ceq (Get-PageField $equal 'rasterKey') -and
        (ConvertTo-Json -InputObject $changed.fx -Compress -Depth 8) -ceq (ConvertTo-Json -InputObject $equal.fx -Compress -Depth 8))
    $look.name += ' renamed'
    $named = Push-LookFx $Run $Chrome $look $fixture
    [void] (& $recordStage 'name-only' $named)
    Add-Check "$prefix.nameOnly" 'rename is saved on disk and emits a newer same-epoch look event with no raster work or style change' $named (
        $named.lookPush.storedName -ceq $look.name -and $named.lookPush.newEvent -and
        (Test-LookFxCounters $equal $named 0) -and (ConvertTo-Json -InputObject $equal.fx -Compress -Depth 8) -ceq (ConvertTo-Json -InputObject $named.fx -Compress -Depth 8))
    # This reset is scored before any Custom/inactive/ShowArt history can contaminate it.
    $look.options = Copy-LookOptions $nullOptions
    $pureReset = Push-LookFx $Run $Chrome $look $fixture
    $pureResetCapture = & $recordStage 'pure-reset' $pureReset
    $purePixels = Compare-LookFxPaint $nullCapture $pureResetCapture $Case 'pure-reset' $stem
    $pureIdentity = $purePixels.accepted
    $evidence['pureReset'] = $pureReset
    $evidence['pureResetAbsolute'] = $purePixels.absolutePixels
    $comparisons.pureReset = $purePixels
    Add-Check "$prefix.defaultIdentity.pureReset" 'isolated pure-FX reset: exact0, or explicitly registered Simple played-min/Album unplayed-min signature; exact restored state and valid recaptures mandatory' $purePixels $pureIdentity
    $look.options = Copy-LookOptions $Case.options
    $reapplied = Push-LookFx $Run $Chrome $look $fixture
    [void] (& $recordStage 'reapply' $reapplied)
    if ($Case.theme -ne 'pill') {
        $custom = Copy-LookOptions $look.options; $custom['colours'] = 'custom'; $custom['accent'] = '#123456'
        $look.options = $custom; $customPage = Push-LookFx $Run $Chrome $look $fixture
        [void] (& $recordStage 'custom-accent' $customPage)
        Add-Check "$prefix.customAccent" 'custom accent remains exact (never matte-floored) before played dimming' $customPage (
            (Get-PageField $customPage 'accent') -ceq '#123456' -and (Test-LookFxColours $customPage $customPage $Case.theme $custom))
    }
    if ($Case.theme -in @('standard', 'classic', 'card', 'album-art')) {
        $inactive = Copy-LookOptions $nullOptions
        if ($Case.theme -eq 'album-art') { $inactive['showArt'] = $false } else { $inactive['colours'] = 'custom' }
        $look.options = $inactive; $before = Push-LookFx $Run $Chrome $look $fixture
        [void] (& $recordStage 'inactive' $before)
        $inactive['backgroundBlur'] = 32; $inactive['backgroundBrightness'] = 200
        $after = Push-LookFx $Run $Chrome $look $fixture
        [void] (& $recordStage 'inactive-fx' $after)
        Add-Check "$prefix.inactive" 'Custom backgrounds or hidden album art retain overrides but are style/counter no-ops' ([ordered]@{ before = $before; after = $after }) (
            (Test-LookFxCounters $before $after 0) -and (Get-PageField $before 'rasterKey') -ceq (Get-PageField $after 'rasterKey') -and
            (ConvertTo-Json -InputObject $before.fx.styles -Compress -Depth 8) -ceq (ConvertTo-Json -InputObject $after.fx.styles -Compress -Depth 8))
    }
    $look.options = Copy-LookOptions $nullOptions; $reset = Push-LookFx $Run $Chrome $look $fixture
    $resetCapture = & $recordStage 'reset' $reset
    $explicit = $null; $explicitCapture = $null
    if ($Case.case -eq 'fx-default') {
        $look.options = Copy-LookOptions $Case.options; $explicit = Push-LookFx $Run $Chrome $look $fixture
        $explicitCapture = & $recordStage 'final-explicit' $explicit
    }
    $evidence['baseline'] = $baseline; $evidence['changed'] = $changed; $evidence['equal'] = $equal
    $evidence['named'] = $named; $evidence['reset'] = $reset; $evidence['explicit'] = $explicit

    $resetPixels = Compare-LookFxPaint $nullCapture $resetCapture $Case 'reset' $stem
    $evidence['resetAbsolute'] = $resetPixels.absolutePixels
    $resetIdentity = $resetPixels.accepted
    $comparisons.reset = $resetPixels
    Add-Check "$prefix.defaultIdentity.reset" 'mixed-history reset: exact0 or explicitly labelled registered paint signature; exact restored state and valid recaptures mandatory' $resetPixels $resetIdentity
    $identity = $initialIdentity -and $pureIdentity -and $resetIdentity
    if ($Case.case -eq 'fx-default') {
        $explicitPixels = Compare-LookFxPaint $nullCapture $explicitCapture $Case 'final-explicit' $stem
        $evidence['explicitAbsolute'] = $explicitPixels.absolutePixels
        Add-Check "$prefix.defaultIdentity.finalExplicit" 'explicit defaults after mixed history: exact0 or registered paint signature, never an exception to fresh initial explicit identity' $explicitPixels $explicitPixels.accepted
        $identity = $identity -and $explicitPixels.accepted
        $comparisons.explicit = $explicitPixels
    }
    Add-Check "$prefix.defaultIdentity" 'fresh defaults absolute0; pure/mixed resets exact0 or visibly labelled known signature; all restored state and capture checks exact' $comparisons $identity
    if ($Case.case -eq 'fx-default' -and $Case.theme -in @('pill', 'standard', 'classic', 'album-art', 'card')) {
        $look.options = Copy-LookOptions $nullOptions
        $look.options['showProgress'] = $false; $look.options['showTimes'] = $false
        # Setup only: the scored before/after pages both use these disabled moving elements.
        [void] (Push-LookFx $Run $Chrome $look)
        $sizes = Get-Content -Raw (Join-Path $fixtureDirectory 'expected-sizes.json') | ConvertFrom-Json -AsHashtable -Depth 16
        $noArtSize = @($sizes.rows | Where-Object { $_.theme -ceq $Case.theme -and $_.width -eq $look.options.width -and
            $_.scale -eq $look.options.scale -and $_.showArt -eq $look.options.showArt -and
            $_.showArtist -eq $look.options.showArtist -and -not $_.showProgress -and -not $_.showTimes })
        if ($noArtSize.Count -ne 1) { throw "LookFx missing independent noArt source size for $($look.id)." }
        $noArtFixture = @{ mode = 'noart'; source = $noArtSize[0].source; href = "$($overlayUrl)?look=$($look.id)&sample=noart"
            captures = [Collections.Generic.List[object]]::new() }
        $noArtPage = Set-LookFxSamplePage $Run $Chrome $look $noArtFixture
        $before = Wait-LookFxFixture $Chrome $look $noArtFixture
        $beforeShot = Get-LookFxShotBytes $Chrome $look $noArtFixture
        $look.options['backgroundBlur'] = 32; $look.options['backgroundBrightness'] = 200
        $after = Push-LookFx $Run $Chrome $look $noArtFixture
        $noArtPixels = Compare-Png $beforeShot (Get-LookFxShotBytes $Chrome $look $noArtFixture) (Join-Path $shotDirectory "$($Case.theme)-noart-diff.png") 0
        Add-Check "$prefix.noArt" 'without art, blur/background overrides draw/re-fetch nothing and leave pixels/styles unchanged' ([ordered]@{ before = $before; after = $after; pixels = $noArtPixels }) (
            (Test-LookFxCounters $before $after 0) -and (Get-PageField $after 'artFailed') -eq $true -and
            $noArtPixels.differing -eq 0 -and
            (ConvertTo-Json -InputObject $before.fx.styles -Compress -Depth 8) -ceq (ConvertTo-Json -InputObject $after.fx.styles -Compress -Depth 8) -and
            (ConvertTo-Json -InputObject $before.fx.canvases -Compress -Depth 8) -ceq (ConvertTo-Json -InputObject $after.fx.canvases -Compress -Depth 8))
        $evidence['noArt'] = [ordered]@{ before = $before; after = $after; pixels = $noArtPixels; samplePage = $noArtPage; fixture = $noArtFixture }
    }
    } finally {
        [IO.File]::WriteAllText((Join-Path $runDirectory "lookfx-$stem.json"), (ConvertTo-Json -InputObject $evidence -Depth 100), [Text.UTF8Encoding]::new($false))
    }
    $caseChecks = @($checks | Where-Object { $_.name -like "$prefix.*" })
    $pixelSummary = [ordered]@{}
    foreach ($key in $comparisons.Keys) {
        $comparison = $comparisons[$key]
        if ($null -eq $comparison) { $pixelSummary[$key] = $null; continue }
        $metrics = [ordered]@{}
        foreach ($field in @('exactPixels', 'matchesKnownPaintSignature', 'differingPixels', 'maxDeltas',
            'outsideRegionCount', 'alphaDifferenceCount', 'invalidSignatureCount', 'validCapture',
            'exactRestoredState', 'accepted', 'acceptance', 'signatureIneligibleReason', 'evidencePaths')) { $metrics[$field] = $comparison[$field] }
        $metrics['signatureName'] = if ($comparison.signature) { $comparison.signature.name } else { $null }
        $pixelSummary[$key] = $metrics
    }
    $summary = [ordered]@{ theme = $Case.theme; case = $Case.case; defaultIdentity = [bool] $identity
        checkCount = $caseChecks.Count; pass = @($caseChecks | Where-Object { $_.status -eq 'pass' }).Count
        fail = @($caseChecks | Where-Object { $_.status -eq 'fail' }).Count
        validCaptures = @($identityCaptures.Values | Where-Object { $_.valid }).Count
        captureCount = $identityCaptures.Count; pixels = $pixelSummary }
    New-RunEvidenceReference -RelativePath "lookfx-$stem.json" -Summary $summary
}

# Opt-in painter evidence only. No generated cases, journal rows or required gate inventory are added.
function Get-FxPaintLayerSnapshot($Chrome) {
    $Chrome = Resolve-Chrome $Chrome
    $document = Get-Prop (Invoke-Cdp $Chrome 'DOM.getDocument' @{ depth = 0 }) 'root'
    $nodes = [ordered]@{}
    foreach ($id in @('bar', 'barclip', 'barfill', 'scrim', 'cover', 'thumb')) {
        $nodeId = Get-Prop (Invoke-Cdp $Chrome 'DOM.querySelector' @{ nodeId = $document.nodeId; selector = "#$id" }) 'nodeId'
        $backend = if ($nodeId) { Get-Prop (Get-Prop (Invoke-Cdp $Chrome 'DOM.describeNode' @{ nodeId = $nodeId }) 'node') 'backendNodeId' } else { $null }
        $nodes[$id] = [ordered]@{ nodeId = $nodeId; backendNodeId = $backend; present = [bool] $nodeId; layers = @()
            status = if ($nodeId) { 'tree-unavailable' } else { 'node-absent' } }
    }
    $tree = $Chrome.Events | Where-Object { $_.method -eq 'LayerTree.layerTreeDidChange' } | Select-Object -Last 1
    $layers = @(Get-Prop (Get-Prop $tree 'params') 'layers' | Where-Object { $null -ne $_ })
    foreach ($id in $nodes.Keys) {
        if (-not $nodes[$id].present) { continue }
        $nodes[$id].layers = @($layers | Where-Object {
            (Get-Prop $_ 'backendNodeId') -eq $nodes[$id].backendNodeId
        } | ForEach-Object {
            $entry = [ordered]@{ layer = $_; compositingReasons = $null; error = $null }
            try { $entry.compositingReasons = Invoke-Cdp $Chrome 'LayerTree.compositingReasons' @{ layerId = $_.layerId } }
            catch { $entry.error = $_.Exception.Message }
            $entry
        })
        $nodes[$id].status = if (-not $tree) { 'tree-unavailable' } elseif ($nodes[$id].layers.Count) { 'composited' } else { 'no-compositing-layer' }
    }
    [ordered]@{ treeAvailable = $null -ne $tree; layerTree = $tree; nodes = $nodes }
}

function Test-ALookFxPaint {
    $summaryPath = Join-Path $runDirectory 'fxpaint-summary.json'
    $summary = [ordered]@{ version = 1; diagnosticOnly = $true; tolerance = 0; comparison = 'exact RGBA'
        noFxMeaning = 'FX fields omitted from every saved/pushed payload; no FX activation or mutation.'
        appDirectory = $appDirectory; alternatePreLookFxBuild = [bool] $fxPaintLegacyBuild
        histories = [ordered]@{} }
    $fxKeys = @('backgroundBlur', 'playedBrightness', 'unplayedBrightness', 'backgroundBrightness')
    try {
        foreach ($theme in @('simple', 'album-art')) {
            $base = Get-ThemeDefaults $theme; $base['paused'] = 'dim'
            if (-not $fxPaintLegacyBuild) { foreach ($key in $fxKeys) { $base[$key] = $null } }
            $look = New-ObsLook "paint$(if ($theme -eq 'simple') { '001' } else { '002' })" "$theme paint history" $base
            $source = (Get-DefaultThemeSize $theme).source
            $run = Start-OverlayRun "A-LOOK-fxpaint-$theme" @{} 'PlayingLong' -NoReader -LooksJson (
                ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
            $chrome = $null
            try {
                [void] (Wait-BenchReady $run.Root)
                $chrome = Start-Chrome "A-LOOK-fxpaint-$theme" -Plain
                $histories = @(
                    @{ name = 'custom-auto'; option = 'colours'; value = 'custom'; stage = 'custom'; noFx = $false },
                    @{ name = 'played0-null'; option = 'playedBrightness'; value = 0; stage = 'played0'; noFx = $false }
                )
                if ($theme -eq 'simple') {
                    $histories += @{ name = 'unplayed100-null'; option = 'unplayedBrightness'; value = 100; stage = 'unplayed100'; noFx = $false }
                } else {
                    $histories += @{ name = 'showart-false-true'; option = 'showArt'; value = $false; stage = 'art-hidden'; noFx = $false }
                    $histories += @{ name = 'blur32-null'; option = 'backgroundBlur'; value = 32; stage = 'cover-fx'; noFx = $false }
                }
                $histories += @{ name = 'no-fx-custom-auto'; option = 'colours'; value = 'custom'; stage = 'custom'; noFx = $true }
                if ($theme -eq 'album-art') {
                    $histories += @{ name = 'no-fx-showart-false-true'; option = 'showArt'; value = $false; stage = 'art-hidden'; noFx = $true }
                }
                foreach ($history in $histories) {
                    $prefix = "A-LOOK.fxpaint.$theme.$($history.name)"
                    $stem = "fxpaint-$theme-$($history.name)"
                    if ($fxPaintLegacyBuild -and -not $history.noFx) {
                        $skip = [ordered]@{ theme = $theme; history = $history.name; status = 'skipped-not-applicable'
                            reason = 'Alternate pre-LookFx hook build: FX histories are not applicable, not passed.' }
                        $summary.histories["$theme.$($history.name)"] = $skip
                        $check = [ordered]@{ name = "$prefix.identity"; expected = 'LookFx-capable hook build'
                            observed = $skip.reason; status = 'skipped-not-applicable' }
                        Add-JournalCheck $check; $checks.Add($check)
                        continue
                    }
                    $defaults = Copy-LookOptions $base
                    if ($history.noFx) { foreach ($key in $fxKeys) { $defaults.Remove($key) } }
                    $look.options = $defaults
                    $fixture = @{ mode = 'paused'; source = $source; href = "$($overlayUrl)?look=$($look.id)&sample=paused"; noFx = [bool] $history.noFx
                        captures = [Collections.Generic.List[object]]::new() }
                    $record = [ordered]@{ theme = $theme; history = $history.name; noFx = $history.noFx
                        initialOptions = Copy-LookOptions $defaults; stages = [Collections.Generic.List[object]]::new()
                        differingPixels = $null; identity = $false; completed = $false; trace = $null; error = $null }
                    $summary.histories["$theme.$($history.name)"] = $record
                    try {
                        $record['freshPage'] = Reset-ChromeCasePage $chrome
                        [void] (Wait-OverlayStreams $run 0 "$stem-fresh-page")
                        # Restore on a blank target, never warm or replace the reference document.
                        [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look))))
                        $record['setupReloadQpc'] = Send-ObsHookCommand $run.Root 'command-obs-looks-reload'
                        $record['setupState'] = Get-State $run.Root "$stem-setup"
                        if (-not $record.setupState) { throw "$stem native setup reload did not complete." }
                        # Only this fresh owned target's enable-time snapshot can seed the trace's layer evidence.
                        $chrome.Events.Clear()
                        Set-OverlayViewport $chrome $source
                        [void] (Invoke-Cdp $chrome 'DOM.enable')
                        [void] (Invoke-Cdp $chrome 'LayerTree.enable')
                        $state = @{ baseline = $null; previous = $null; final = $null; error = $null }
                        # Bounded to this one three-stage history, including first paint and the isolated reset.
                        $record.trace = Invoke-FrameTrace $chrome $stem 0 {
                            try {
                            foreach ($stage in @('default', $history.stage, 'reset')) {
                                $push = $null
                                if ($stage -eq 'default') {
                                    [void] (Invoke-Cdp $chrome 'Page.bringToFront')
                                    [void] (Invoke-ChromeNavigate $chrome $fixture.href)
                                } else {
                                    $look.options = Copy-LookOptions $defaults
                                    if ($stage -ne 'reset') {
                                        $look.options[$history.option] = $history.value
                                        if ($history.option -eq 'colours') { $look.options['accent'] = '#123456' }
                                    }
                                    $push = Push-LookFx $run $chrome $look $fixture
                                }
                                $capture = Get-LookFxIdentityCapture $chrome $look $fixture "$stem-$stage" "$prefix.captureEvidence.$stage" -PaintDiagnostic
                                if ($stage -eq 'default') { $state.baseline = $capture }
                                $fromDefault = Compare-Png $state.baseline.bytes $capture.bytes (Join-Path $shotDirectory "$stem-$stage-default-diff.png") 0
                                $fromPrevious = if ($state.previous) {
                                    Compare-Png $state.previous.bytes $capture.bytes (Join-Path $shotDirectory "$stem-$stage-previous-diff.png") 0
                                } else { $null }
                                $record.stages.Add([ordered]@{ stage = $stage; options = Copy-LookOptions $look.options; push = $push
                                    capture = "$stem-$stage-capture.json"; evidence = $capture.evidence
                                    fromDefault = $fromDefault; fromPrevious = $fromPrevious })
                                $state.previous = $capture; $state.final = $capture
                            }
                            } catch { $state.error = $_.Exception.Message }
                        } -PreserveLayerEvents -Categories '-*,blink,cc,skia,devtools.timeline,disabled-by-default-devtools.timeline.frame,disabled-by-default-devtools.timeline.layers,disabled-by-default-cc.debug'
                        $record['layerEvents'] = @($chrome.Events | Where-Object { $_.method -like 'LayerTree.*' })
                        if ($state.error) { throw $state.error }
                        $record.differingPixels = $record.stages[2].fromDefault.differing
                        $record.identity = $state.baseline.valid -and $state.final.valid -and $null -ne $record.differingPixels -and $record.differingPixels -eq 0
                        Add-Check "$prefix.identity" 'fresh default and isolated reset exactly RGBA-identical, zero tolerance, with valid original/recapture frames' (
                            [ordered]@{ differingPixels = $record.differingPixels; stages = @($record.stages | ForEach-Object {
                                [ordered]@{ stage = $_.stage; fromDefault = $_.fromDefault; fromPrevious = $_.fromPrevious; capture = $_.capture } }) }) $record.identity
                        $layerFailures = @($fixture.captures | Where-Object {
                            -not $_.layers.treeAvailable -or @($_.layers.nodes.Values | ForEach-Object { $_.layers } | Where-Object { $_.error }).Count -gt 0
                        })
                        Add-Check "$prefix.layers" 'LayerTree retained for every frame; compositingReasons recorded for each requested node with a layer' (
                            [ordered]@{ frames = $fixture.captures.Count; failedFrames = $layerFailures.Count }) ($layerFailures.Count -eq 0)
                        if ($fxPaintLegacyBuild) {
                            $unexpectedFx = @($fixture.captures | Where-Object {
                                $_.before.captureMetadata.lookFxAvailable -or $_.after.captureMetadata.lookFxAvailable -or
                                $null -ne (Get-PageField $_.before 'fx') -or $null -ne (Get-PageField $_.after 'fx')
                            })
                            Add-Check "$prefix.preLookFx" 'alternate build exposes neither effectsOf nor fx state' $unexpectedFx.Count ($unexpectedFx.Count -eq 0)
                        }
                        $record.completed = $true
                    } catch {
                        $record.error = $_.Exception.Message
                        Add-Check "$prefix.completed" 'isolated painter history completed; all captured evidence retained' $record.error $false
                        if (-not @($checks | Where-Object { $_.name -ceq "$prefix.identity" }).Count) {
                            Add-Check "$prefix.identity" 'complete valid captures and exact RGBA identity, zero tolerance' $record.error $false
                        }
                    } finally {
                        if ($record.error) { $record['partialCaptures'] = @($fixture.captures) }
                        [IO.File]::WriteAllText((Join-Path $runDirectory "$stem.json"), (ConvertTo-Json -InputObject $record -Depth 32), [Text.UTF8Encoding]::new($false))
                        [IO.File]::WriteAllText($summaryPath, (ConvertTo-Json -InputObject $summary -Depth 32), [Text.UTF8Encoding]::new($false))
                    }
                }
            } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
        }
    } finally {
        [IO.File]::WriteAllText($summaryPath, (ConvertTo-Json -InputObject $summary -Depth 32), [Text.UTF8Encoding]::new($false))
    }
    $summary
}

function Test-ALook {
    if (-not (Test-ChromeAvailable 'A-LOOK')) { return }
    if ('fxpaint' -in $Section) {
        $scenarioResults['A-LOOK'] = [ordered]@{ fxpaint = Test-ALookFxPaint }
        return
    }
    $allCases = @(New-LookCases)
    $pillCases = @($allCases | Where-Object { $_.theme -eq 'pill' })
    $otherCases = @($allCases | Where-Object { $_.theme -ne 'pill' })
    $defaultFixturePath = Join-Path $fixtureDirectory 'looks-pill-defaults.json'
    $defaultFixtureDoc = Get-Content -Raw -LiteralPath $defaultFixturePath | ConvertFrom-Json -Depth 16
    $defaultFixture = @($defaultFixtureDoc.looks)[0]
    $defaultCase = $pillCases | Where-Object { $_.case -eq 'default' } | Select-Object -First 1
    Add-Check 'A-LOOK.pill.defaultFixture' 'committed default Pill fixture matches the generated P0 default case' ([ordered]@{
        fixturePath = [IO.Path]::GetRelativePath($repo, $defaultFixturePath); id = Get-Prop $defaultFixture 'id'
        case = $defaultCase.case; options = Get-Prop $defaultFixture 'options' }) (
        $defaultFixture -and $defaultCase -and $defaultFixture.id -eq $defaultCase.lookId -and
        (ConvertTo-Json -InputObject $defaultFixture.options -Compress -Depth 8) -ceq
        (ConvertTo-Json -InputObject $defaultCase.options -Compress -Depth 8))
    $caseFixturePath = Join-Path $fixtureDirectory 'looks-cases.json'
    $caseFixture = if (Test-Path -LiteralPath $caseFixturePath -PathType Leaf) { @(Get-Content -Raw -LiteralPath $caseFixturePath | ConvertFrom-Json -Depth 16) } else { @() }
    $fixtureBatches = @($caseFixture | Group-Object { $_.batch } | ForEach-Object { $_.Count })
    Add-Check 'A-LOOK.generatorAllThemes' 'looks-cases.json in fixtures and artifacts contains all eight plan themes, matching case count, and batches ≤ 16' (
        [ordered]@{ fixturePath = [IO.Path]::GetRelativePath($repo, $caseFixturePath); themes = @($allCases | ForEach-Object { $_.theme } | Select-Object -Unique)
            cases = $allCases.Count; fixtureCases = $caseFixture.Count
            maxBatch = ($fixtureBatches | Measure-Object -Maximum).Maximum }) (
        (Test-Path -LiteralPath $caseFixturePath -PathType Leaf) -and @($allCases | ForEach-Object { $_.theme } | Select-Object -Unique).Count -eq 8 -and
        $caseFixture.Count -eq $allCases.Count -and ($fixtureBatches | Measure-Object -Maximum).Maximum -le 16)
    & (Join-Path $PSScriptRoot 'obs-overlay-sizes.ps1') | Out-Null
    $sizes = Get-Content -Raw (Join-Path $fixtureDirectory 'expected-sizes.json') | ConvertFrom-Json -AsHashtable -Depth 16
    Add-Check 'A-LOOK.expectedSizes' 'independent geometry oracle covers every generated case' $sizes.cases.Count ($sizes.cases.Count -eq $allCases.Count)
    $obs = [ordered]@{ pillCases = $pillCases.Count; otherCases = $otherCases.Count; cases = [ordered]@{} }
    $selectedCases = @($allCases | Where-Object {
        $name = "$($_.theme).$($_.case)"
        @($LookCase | Where-Object { $name -like $_ }).Count -gt 0 -and
            (Test-SectionSelected $(if ($_.case -like 'fx-*') { 'fx' } else { 'geometry' }))
    })
    if ($selectedCases.Count -eq 0 -and ((Test-SectionSelected 'geometry') -or (Test-SectionSelected 'fx'))) { throw "No generated A-LOOK cases match: $($LookCase -join ', ')" }
    $batches = @($selectedCases | Group-Object { $_.batch } | Sort-Object { [int] $_.Name })
    foreach ($batch in $batches) {
        $lookDocsList = [Collections.Generic.List[object]]::new()
        foreach ($case in $batch.Group) {
            if ($case.theme -eq 'pill' -and $case.case -eq 'default') {
                $lookDocsList.Add((New-ObsLook $case.lookId $defaultFixture.name $defaultFixture.options))
            } else { $lookDocsList.Add((New-ObsLook $case.lookId "$($case.theme) $($case.case)" $case.options)) }
        }
        $lookDocs = $lookDocsList.ToArray()
        $looksJson = ConvertTo-ObsLooksJson (New-ObsLooksDocument $lookDocs)
        $run = Start-OverlayRun "A-LOOK-batch-$($batch.Name)" @{} 'PlayingLong' -NoReader -LooksJson $looksJson
        $chrome = $null; $raws = [Collections.Generic.List[object]]::new()
        $groupRows = [ordered]@{}; $caseIndex = 0
        if ($LookGroup -gt 1) {
            $waitGroupStreams = {
                param([int] $PerLook, [object[]] $Cases, [string] $Label)
                # Total and by-look snapshots must agree within the existing stream-release ceiling.
                $deadline = [DateTime]::UtcNow.AddSeconds($ordinaryStreamReleaseSeconds)
                $expectedTotal = $PerLook * $Cases.Count
                $snapshot = Wait-OverlayStreams $run $expectedTotal $Label
                while ($true) {
                    # A state read that times out near the deadline yields no snapshot: treat it as not reached yet.
                    $byLook = if ($snapshot) { Get-Overlay $snapshot 'streamsByLook' } else { $null }
                    if ($snapshot -and $null -eq $byLook) { throw "A-LOOK $Label has no by-look stream counts." }
                    $wrongLooks = @($Cases | Where-Object { -not $byLook -or [int] (Get-Prop $byLook $_.lookId) -ne $PerLook })
                    if ($snapshot -and (Get-Overlay $snapshot 'streams') -eq $expectedTotal -and $wrongLooks.Count -eq 0) { return $snapshot }
                    $remaining = ($deadline - [DateTime]::UtcNow).TotalSeconds - 0.1
                    if ($remaining -le 0) { throw "A-LOOK ${Label}: total/by-look streams did not reach $expectedTotal/$PerLook." }
                    Start-Sleep -Milliseconds 100
                    $snapshot = Get-State $run.Root $Label $remaining
                }
            }
            $releaseGroup = {
                $releaseError = $null
                $releasedCases = @($groupRows.Values | ForEach-Object { $_.Case })
                foreach ($row in $groupRows.Values) {
                    try {
                        if ($row.Chrome) { $row.TargetId = $row.Chrome.TargetId }
                        if ($row.TargetId) {
                            # Destroy the exact owned document; navigation can retain EventSource in BFCache.
                            $closed = Invoke-Cdp $chrome 'Target.closeTarget' @{ targetId = $row.TargetId }
                            if ((Get-Prop $closed 'success') -ne $true) { throw "Chrome refused to close target $($row.TargetId)." }
                            $gone = Wait-For {
                                $targets = @(Invoke-RestMethod -NoProxy -Uri "http://127.0.0.1:$($chrome.CdpPort)/json/list" | ForEach-Object { $_ })
                                @($targets | Where-Object { $_.id -eq $row.TargetId }).Count -eq 0
                            } 5 50
                            if (-not $gone) { throw "Chrome target $($row.TargetId) survived closeTarget." }
                            $caseKey = "$($row.Case.theme).$($row.Case.case)"
                            if ($obs.cases.Contains($caseKey)) {
                                $obs.cases[$caseKey]['release'] = [ordered]@{ oldTarget = $row.TargetId
                                    newTarget = $chrome.TargetId; closeSucceeded = $true; oldTargetGone = $true }
                            }
                        }
                    } catch { if (-not $releaseError) { $releaseError = $_ } }
                    finally {
                        try { if ($row.Chrome) { $row.Chrome.Ws.Dispose() } }
                        catch { if (-not $releaseError) { $releaseError = $_ } }
                        try { Stop-SseReader $row.Reader }
                        catch { if (-not $releaseError) { $releaseError = $_ } }
                        [void] $raws.Remove($row.Reader)
                    }
                }
                $groupRows.Clear()
                [void] (& $waitGroupStreams 0 $releasedCases "group-$caseIndex-released")
                if ($releaseError) { throw $releaseError }
            }
        }
        try {
            [void] (Wait-BenchReady $run.Root)
            $reloadQpc = Send-ObsHookCommand $run.Root 'command-obs-looks-reload'
            [void] (Wait-For { $s = Get-State $run.Root "batch$($batch.Name)"; (Get-Overlay $s 'looks').count -eq $lookDocs.Count } 15 250)
            $chrome = Start-Chrome "A-LOOK-batch-$($batch.Name)" -Plain
            Set-PlainViewport $chrome
            [void] (Invoke-ChromeNavigate $chrome 'about:blank')
            [void] (Wait-OverlayStreams $run 0 'batchInitialStreams')
            foreach ($case in $batch.Group) {
                if ($LookGroup -gt 1 -and ($caseIndex % $LookGroup) -eq 0) {
                    $groupCases = @($batch.Group[$caseIndex..([Math]::Min($caseIndex + $LookGroup, $batch.Group.Count) - 1)])
                    # A blank control target has no EventSource: each case adds exactly one reader and one page.
                    # Stage the readers before pages; N=4 owns eight observers and never admits a ninth.
                    foreach ($groupCase in $groupCases) {
                        $reader = Start-SseReader "A-LOOK-$($groupCase.theme)-$($groupCase.case)" 30 "/events?look=$($groupCase.lookId)"
                        $raws.Add($reader)
                        $groupRows[$groupCase.lookId] = [pscustomobject]@{
                            Case = $groupCase; Reader = $reader; LookEvent = $null; DataEvent = $null; Chrome = $null; TargetId = $null
                        }
                    }
                    foreach ($groupCase in $groupCases) {
                        $row = $groupRows[$groupCase.lookId]
                        $row.LookEvent = Wait-SseLook $row.Reader { param($m) (Get-Prop $m 'id') -eq $groupCase.lookId } 15
                        $row.DataEvent = Wait-SseData $row.Reader { param($d) (Get-Prop $d 'state') -eq 'playing' } 15
                    }
                    foreach ($groupCase in $groupCases) {
                        $row = $groupRows[$groupCase.lookId]
                        $created = Invoke-Cdp $chrome 'Target.createTarget' @{ url = 'about:blank' }
                        $row.TargetId = [string] (Get-Prop $created 'targetId')
                        if (-not $row.TargetId) { throw "Chrome did not create A-LOOK target for $($groupCase.lookId)." }
                        $target = Wait-For {
                            Invoke-RestMethod -NoProxy -Uri "http://127.0.0.1:$($chrome.CdpPort)/json/list" |
                                ForEach-Object { $_ } | Where-Object { $_.id -eq $row.TargetId } | Select-Object -First 1
                        } 5 50
                        if (-not $target) { throw "Chrome target $($row.TargetId) was not exposed." }
                        $ws = [Net.WebSockets.ClientWebSocket]::new()
                        $row.Chrome = [pscustomobject]@{ Name = "A-LOOK-$($groupCase.theme)-$($groupCase.case)"; Process = $chrome.Process
                            Ws = $ws; Next = 0; Dir = $chrome.Dir; CdpPort = $chrome.CdpPort; Plain = $true
                            TargetId = $row.TargetId; Events = [Collections.Generic.List[object]]::new() }
                        [void] $ws.ConnectAsync([Uri] $target.webSocketDebuggerUrl, [Threading.CancellationToken]::None).GetAwaiter().GetResult()
                        [void] (Invoke-Cdp $row.Chrome 'Page.enable')
                        Set-OverlayViewport $row.Chrome $sizes.cases[$groupCase.lookId].source
                        [void] (Invoke-ChromeNavigate $row.Chrome "$($overlayUrl)?look=$(Get-LookNavigationId $groupCase $batch.Group)")
                    }
                    [void] (& $waitGroupStreams 2 $groupCases "group-$caseIndex-admitted")
                }
                if ($LookGroup -eq 1) {
                    # Serial reference: keep the same reader, waits, navigation and check order for N=1.
                    $path = "/events?look=$($case.lookId)"
                    # Case names repeat across themes; separate files prevent stale initial data from another stream.
                    $reader = Start-SseReader "A-LOOK-$($case.theme)-$($case.case)" 30 $path
                    $raws.Add($reader)
                    $lookEvent = Wait-SseLook $reader { param($m) (Get-Prop $m 'id') -eq $case.lookId } 15
                    $dataEvent = Wait-SseData $reader { param($d) (Get-Prop $d 'state') -eq 'playing' } 15
                    Stop-SseReader $reader
                    [void] $raws.Remove($reader)
                    [void] (Wait-OverlayStreams $run 0 "case-$($case.case)-reader-closed")
                    $size = $sizes.cases[$case.lookId]
                    Set-OverlayViewport $chrome $size.source
                    [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$(Get-LookNavigationId $case $batch.Group)")
                    $caseChrome = $chrome
                } else {
                    $row = $groupRows[$case.lookId]
                    $reader = $row.Reader; $lookEvent = $row.LookEvent; $dataEvent = $row.DataEvent
                    $size = $sizes.cases[$case.lookId]; $caseChrome = $row.Chrome
                }
                $page = Wait-For { $p = Get-PageProbe $caseChrome; if ($p -and (Get-PageField $p 'connection') -eq 'open' -and
                    (Get-Prop (Get-PageField $p 'look') 'id') -eq $case.lookId) { $p } } 20 100
                if (-not $page) { throw "A-LOOK case '$($case.case)' never reached its connected page state." }
                # Geometry is a static check: probe after the show animation settles (a mid-slide box moves its text and
                # hidden bar relative to the rest position; 4 October, V6 serial-vs-grouped comparison). Grouped pages are
                # background targets whose animations do not advance, so each case's own target is activated first.
                if ($LookGroup -gt 1) { [void] (Invoke-Cdp $caseChrome 'Page.bringToFront') }
                $page = Wait-For { $p = Get-PageProbe $caseChrome; if ($p -and [int] (Get-Prop $p 'running') -eq 0) { $p } } 10 100
                if (-not $page) { throw "A-LOOK case '$($case.case)' still had running animations 10 s after connecting." }
                $redKind = $lookRed["$($case.theme).$($case.case)"]
                if ($redKind -in @('size', 'style')) {
                    $redExpression = if ($redKind -eq 'size') {
                        "(() => { const p = document.getElementById('pill'); p.style.width = (parseFloat(getComputedStyle(p).width) + 7) + 'px'; })()"
                    } else {
                        "document.documentElement.setAttribute('data-theme', document.documentElement.getAttribute('data-theme') === 'matte' ? 'card' : 'matte')"
                    }
                    [void] (Invoke-Cdp $caseChrome 'Runtime.evaluate' @{ expression = $redExpression })
                    $page = Get-PageProbe $caseChrome
                    Write-Host "LookRedCase: $($case.theme).$($case.case) mutated ($redKind)."
                }
                $options = $case.options; $expected = @{ width = $size.box.w; height = $size.box.h; sourceWidth = $size.source.w; sourceHeight = $size.source.h }; $state = Get-Prop $page 's'
                $box = Get-Prop $state 'box'; $source = Get-Prop $state 'source'; $actualWidth = Get-Prop (Get-Prop $page 'css') 'width'
                $geometry = [ordered]@{ expected = $expected; box = $box; source = $source; cssWidth = $actualWidth
                    viewport = $page.pageSize; boxRect = $page.boxRect }
                Add-Check "A-LOOK.$($case.theme).$($case.case).lookBeforeData" 'each new stream writes look before initial data, with matching id' ([ordered]@{
                    lookQpc = Get-Prop $lookEvent 'qpc'; dataQpc = Get-Prop $dataEvent 'qpc'; id = Get-Prop (Get-Prop $lookEvent 'data') 'id' }) (
                    $lookEvent -and $dataEvent -and $lookEvent.qpc -lt $dataEvent.qpc -and (Get-Prop $lookEvent.data 'id') -eq $case.lookId)
                Add-Check "A-LOOK.$($case.theme).$($case.case).stylesAndSizes" 'theme, custom properties, independent box/source formula and zero page box mismatch' $geometry (
                    $page -and (Get-Prop (Get-Prop $page 'attrs') 'theme') -eq $case.theme -and
                    [double] (Get-Prop $box 'w') -eq [double] $expected.width -and
                    [double] (Get-Prop $box 'h') -eq [double] $expected.height -and
                    [int] (Get-Prop $source 'w') -eq [int] $expected.sourceWidth -and
                    [int] (Get-Prop $source 'h') -eq [int] $expected.sourceHeight -and
                    [string] (Get-Prop $state 'boxMismatch') -in @('', 'false') -and
                    [string] $actualWidth -eq "$($expected.width)px" -and (Test-OverlayViewport $page $size.source))
                $rasterResult = Test-ThemeRaster (Get-PageField $page 'raster') $case.theme $case.options $size
                Add-Check "A-LOOK.$($case.theme).$($case.case).raster" 'theme canvas dimensions match independent 100k area/one-scale projection' $rasterResult $rasterResult.pass
                $actualBar = Get-Prop $page.geometry 'bar'; $actualColumn = Get-Prop $page.geometry 'column'
                $expectedBar = Get-Prop $size 'bar'; $expectedColumn = Get-Prop $size 'column'
                $barShown = [bool] (Get-Prop $expectedBar 'shown')
                $barCorrect = if ($barShown) {
                    $actualBar -and $actualBar.display -ne 'none' -and
                    [Math]::Abs(([double] $actualBar.x - [double] $page.boxRect.x) - [double] $expectedBar.start) -le 1 -and
                    [Math]::Abs([double] $actualBar.width - [double] $expectedBar.width) -le 1 -and
                    [Math]::Abs(([double] $actualBar.y - [double] $page.boxRect.y) - [double] $expectedBar.y) -le 1 -and
                    [Math]::Abs([double] $actualBar.height - [double] $expectedBar.h) -le 1
                } else { -not $actualBar -or $actualBar.display -eq 'none' -or [double] $actualBar.width -eq 0 }
                $columnCorrect = if ($case.theme -in @('matte', 'matte-light', 'standard', 'classic', 'simple')) {
                    $actualColumn -and [Math]::Abs(([double] $actualColumn.x - [double] $page.boxRect.x) - [double] $expectedColumn.start) -le 1 -and
                    [Math]::Abs(([double] $actualColumn.x + [double] $actualColumn.width - [double] $page.boxRect.x) - [double] $expectedColumn.end) -le 1
                } else { $true }
                Add-Check "A-LOOK.$($case.theme).$($case.case).domGeometry" 'bar and horizontal text column independently match expected-sizes (relative to box)' (
                    [ordered]@{ expectedBar = $expectedBar; actualBar = $actualBar; expectedColumn = $expectedColumn; actualColumn = $actualColumn }) ($barCorrect -and $columnCorrect)
                $wireDuration = [double] (Get-Prop (Get-Prop $dataEvent 'data') 'duration')
                $wirePosition = [double] (Get-Prop (Get-Prop $dataEvent 'data') 'position')
                $wireRate = [double] (Get-Prop (Get-Prop $dataEvent 'data') 'rate')
                $expectedFraction = if (-not $case.options.showProgress) { $null } elseif ($wireDuration -gt 0 -and $dataEvent) {
                    # Integer bounds select PowerShell's integral Clamp overload and round away fractional progress.
                    [Math]::Clamp(($wirePosition + (([double] (Get-Prop $dataEvent.data 'ageMs') / 1000) + (Get-Seconds $dataEvent.qpc $page.qpc)) * $wireRate) / $wireDuration, [double] 0, [double] 1)
                } else { $null }
                Add-Check "A-LOOK.$($case.theme).$($case.case).fill" 'bar/reveal position within 1% of independently observed wire snapshot' (
                    [ordered]@{ observed = $page.frac; expected = $expectedFraction; bar = $expectedBar }) (
                    $(if (-not $case.options.showProgress) { $null -eq $page.frac -or $page.frac -eq 1 } else {
                        $null -ne $expectedFraction -and $null -ne $page.frac -and
                        [Math]::Abs([double] $page.frac - $expectedFraction) -le 0.01
                    }))
                $rects = @((Get-Prop $page 'titleRect'), (Get-Prop $page 'artistRect')) | Where-Object { $_ -and $_.width -gt 0 }
                $contained = $page -and @($rects | Where-Object { $_.x -lt $page.boxRect.x -or $_.x + $_.width -gt $page.boxRect.x + $page.boxRect.width -or
                    $_.y -lt $page.boxRect.y -or $_.y + $_.height -gt $page.boxRect.y + $page.boxRect.height }).Count -eq 0
                Add-Check "A-LOOK.$($case.theme).$($case.case).textContainment" 'every visible text row is contained by the box; title uses ellipsis when overflowing' (
                    [ordered]@{ contained = $contained; titleEllipsis = Get-Prop $page 'titleEllipsis'; title = Get-Prop $page 'title'; artist = Get-Prop $page 'artist' }) (
                    $contained -and ((Get-Prop (Get-Prop $page 'titleRect') 'scrollWidth') -le (Get-Prop (Get-Prop $page 'titleRect') 'clientWidth') -or (Get-Prop $page 'titleEllipsis')))
                if ($case.case -eq 'artist-off') {
                    Add-Check 'A-LOOK.pill.artistOff' 'artist row is removed when showArtist is false' $page.artistRect.display ($page.artistRect.display -eq 'none')
                }
                if ($case.case -eq 'shadow-off') {
                    Add-Check 'A-LOOK.pill.shadowOff' 'text-shadow option off removes the compatibility shadow' $page.css.textShadow ($page.css.textShadow -eq 'none')
                }
                if ($case.case -eq 'font-arial') {
                    Add-Check 'A-LOOK.pill.fontOption' 'installed Arial font is selected and available' ([ordered]@{
                        font = $page.css.font; fontAvailable = Get-Prop $state 'fontAvailable' }) (
                        $page.css.font -match '^Arial' -and (Get-Prop $state 'fontAvailable') -eq $true)
                }
                $caseKey = "$($case.theme).$($case.case)"
                $obs.cases[$caseKey] = [ordered]@{ look = [bool] $lookEvent; data = [bool] $dataEvent; geometry = $geometry; titleEllipsis = $page.titleEllipsis }
                if ($case.case -like 'fx-*') { $obs.cases[$caseKey]['fx'] = Test-LookFxCase $run $caseChrome $case $size.source }
                if ($LookGroup -eq 1) {
                    # Close the owned target, not just navigate away: no retained EventSource can survive the case.
                    $obs.cases[$caseKey]['release'] = Reset-ChromeCasePage $chrome
                    [void] (Wait-OverlayStreams $run 0 "case-$($case.case)-released")
                }
                $caseIndex++
                if ($LookGroup -gt 1 -and (($caseIndex % $LookGroup) -eq 0 -or $caseIndex -eq $batch.Group.Count)) {
                    & $releaseGroup
                }
            }
            # Pill-only progress-hidden contract.
            $progressCase = $batch.Group | Where-Object { $_.theme -eq 'pill' -and $_.case -eq 'showProgress-off' } | Select-Object -First 1
            if ($progressCase) {
                [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$($progressCase.lookId)")
                $hiddenProgress = Wait-For { $p = Get-PageProbe $chrome; if ((Get-Prop (Get-Prop $p 'attrs') 'showProgress') -eq 'false') { $p } } 15 100
                Add-Check 'A-LOOK.pill.progressOffFull' 'pill progress off fills the bar and stops the progress timer' ([ordered]@{
                    fillPx = Get-Prop $hiddenProgress 'clipPx'; fillTimer = Get-Prop (Get-Prop $hiddenProgress 's') 'fillTimer' }) (
                    $hiddenProgress -and $hiddenProgress.clipPx -eq 400 -and (Get-Prop $hiddenProgress.s 'fillTimer') -eq 0)
            }
        } finally {
            try { if ($LookGroup -gt 1 -and $groupRows.Count -gt 0) { & $releaseGroup } }
            finally { foreach ($reader in $raws) { Stop-SseReader $reader }; Stop-Chrome $chrome; Stop-OverlayRun $run }
        }
    }
    if ($LookCase.Count -ne 1 -or $LookCase[0] -cne '*') {
        Write-Host 'LookCase filter: cadence/motion and other non-case sections skipped (diagnostic run).'
        $obs['lookCase'] = @($LookCase); $obs['selectedCases'] = $selectedCases.Count
        $scenarioResults['A-LOOK'] = $obs
        return
    }
    if (Test-SectionSelected 'text') {
    # Existing Text fixture supplies a long title; every P0 pill size must clip it inside the pill with ellipsis.
    $longRun = Start-OverlayRun 'A-LOOK-pill-long-text' @{} 'Text' -NoReader
    $longChrome = $null
    try {
        [void] (Wait-BenchReady $longRun.Root)
        $longChrome = Start-Chrome 'A-LOOK-pill-long-text'
        [void] (Invoke-ChromeNavigate $longChrome $overlayUrl)
        $longPage = Wait-For {
            $p = Get-PageProbe $longChrome
            if ($p.titleRect -and $p.titleRect.scrollWidth -gt $p.titleRect.clientWidth) { $p }
        } 25 100
        Add-Check 'A-LOOK.pill.longTextEllipsis' 'long fixture title overflows the text column and is rendered with text-overflow:ellipsis inside the box' ([ordered]@{
            title = Get-Prop $longPage 'title'; rect = Get-Prop $longPage 'titleRect'; ellipsis = Get-Prop $longPage 'titleEllipsis' }) (
            $longPage -and $longPage.titleEllipsis -eq $true -and
            $longPage.titleRect.textOverflow -eq 'ellipsis' -and
            $longPage.titleRect.x -ge $longPage.boxRect.x -and
            $longPage.titleRect.x + $longPage.titleRect.width -le $longPage.boxRect.x + $longPage.boxRect.width)
    } finally { Stop-Chrome $longChrome; Stop-OverlayRun $longRun }
    }
    if (Test-SectionSelected 'cadence') { $obs['cadence'] = Test-ALookCadence }
    if (Test-SectionSelected 'motion') { $obs['motion'] = Test-ALookMotion }
    if (Test-SectionSelected 'regression') {
        $before = $checks.Count
        $obs['backpressure'] = Test-ALookBackpressure
        $script:completedInventorySections['backpressure'] = $checks.Count -gt $before -and
            @($checks | Select-Object -Skip $before | Where-Object { $_.status -ne 'pass' }).Count -eq 0
    }
    if (Test-SectionSelected 'regression') {
        $before = $checks.Count
        $obs['query'] = Test-ALookQueryGrammar
        $script:completedInventorySections['query'] = $checks.Count -gt $before -and
            @($checks | Select-Object -Skip $before | Where-Object { $_.status -ne 'pass' }).Count -eq 0
    }
    if (Test-SectionSelected 'regression') {
        $before = $checks.Count
        $obs['reloadDelete'] = Test-ALookReloadDelete
        $script:completedInventorySections['reloadDelete'] = $checks.Count -gt $before -and
            @($checks | Select-Object -Skip $before | Where-Object { $_.status -ne 'pass' }).Count -eq 0
    }
    if (Test-SectionSelected 'regression') {
        $before = $checks.Count
        $obs['themeCache'] = Test-ALookThemeCache
        $script:completedInventorySections['themeCache'] = $checks.Count -gt $before -and
            @($checks | Select-Object -Skip $before | Where-Object { $_.status -ne 'pass' }).Count -eq 0
    }
    if (Test-SectionSelected 'regression') {
        $before = $checks.Count
        $obs['themeRegressions'] = Test-ALookThemeRegressions
        $script:completedInventorySections['themeRegressions'] = $checks.Count -gt $before -and
            @($checks | Select-Object -Skip $before | Where-Object { $_.status -ne 'pass' }).Count -eq 0
    }
    $scenarioResults['A-LOOK'] = $obs

}

function Test-ALookReloadDelete {
    $options = New-DefaultPillOptions
    $look = New-ObsLook 'reload01' 'Before rename' $options
    $run = Start-OverlayRun 'A-LOOK-reload-delete' @{} 'PlayingLong' -NoReader -LooksJson (
        ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
    $reader = $null; $chrome = $null
    try {
        [void] (Wait-BenchReady $run.Root)
        $reader = Start-SseReader 'A-LOOK-reload-delete' 30 '/events?look=reload01'
        [void] (Wait-SseOpen $reader)
        [void] (Wait-SseLook $reader { param($m) (Get-Prop $m 'id') -eq 'reload01' } 15)
        $chrome = Start-Chrome 'A-LOOK-reload-delete'
        [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=reload01")
        $initial = Wait-For { $p = Get-PageProbe $chrome; if ((Get-Prop (Get-PageField $p 'look') 'id') -eq 'reload01') { $p } } 15 100
        $initialCounters = Get-Prop $initial.s 'counters'
        $blurBefore = Get-Prop $initialCounters 'blurDraws'
        $renamed = New-ObsLook 'reload01' 'After rename only' (Copy-LookOptions $options)
        [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($renamed))))
        $reloadQpc = Send-ObsHookCommand $run.Root 'command-obs-looks-reload'
        $renamedEvent = Wait-SseLook $reader { param($m) (Get-Prop $m 'id') -eq 'reload01' } 15 $reloadQpc
        $renamedPage = Wait-For {
            $p = Get-PageProbe $chrome
            if ((Get-PageField $p 'lookEpoch') -ceq (Get-PageField $initial 'lookEpoch') -and
                (Get-PageField $p 'lookSeq') -gt (Get-PageField $initial 'lookSeq')) { $p }
        } 10 100
        $blurAfter = Get-Prop (Get-Prop $renamedPage.s 'counters') 'blurDraws'
        $storedRename = @((Read-ObsLooksFile $run.Root).looks | Where-Object { $_.id -ceq 'reload01' })
        Add-Check 'A-LOOK.reload.nameOnlyNoRaster' 'rename is saved and emits a newer same-epoch look event without redrawing artwork/quantizer' ([ordered]@{
            reloadLook = Get-Prop $renamedEvent 'data'; storedName = if ($storedRename.Count -eq 1) { $storedRename[0].name } else { $null }
            blurDrawsBefore = $blurBefore; blurDrawsAfter = $blurAfter
            lookApplies = Get-Prop (Get-Prop $renamedPage.s 'counters') 'lookApplies' }) (
            $renamedEvent -and $renamedPage -and $storedRename.Count -eq 1 -and $storedRename[0].name -ceq $renamed.name -and
            (Get-Prop $renamedEvent.data 'epoch') -ceq (Get-PageField $initial 'lookEpoch') -and
            (Get-Prop $renamedEvent.data 'seq') -gt (Get-PageField $initial 'lookSeq') -and $blurBefore -eq $blurAfter)
        $deleteQpc = Get-Qpc
        $delete = Invoke-ObsLookCommit $run.Root 901 @{ action = 'delete'; id = 'reload01' }
        $missingEvent = Wait-SseLook $reader { param($m) (Get-Prop $m 'id') -eq 'reload01' -and (Get-Prop $m 'missing') -eq $true } 15 $deleteQpc
        $missingPage = Wait-For {
            $p = Get-PageProbe $chrome; $lookState = Get-PageField $p 'look'
            if ((Get-Prop $lookState 'missing') -eq $true) { $p }
        } 15 100
        Add-Check 'A-LOOK.deleteFallsBackToPill' 'deleting a saved look live-pushes its pill fallback with missing=true' ([ordered]@{
            commit = Get-Prop $delete 'ok'; event = Get-Prop $missingEvent 'data'; page = Get-PageField $missingPage 'look' }) (
            (Get-Prop $delete 'ok') -eq $true -and $missingEvent -and $missingPage -and
            (Get-Prop $missingEvent.data 'missing') -eq $true -and
            (Get-Prop $missingEvent.data 'theme') -eq 'pill' -and
            (Get-Prop (Get-Prop $missingEvent.data 'options') 'width') -eq 400)
    } finally { Stop-Chrome $chrome; Stop-SseReader $reader; Stop-OverlayRun $run }
    [ordered]@{ blurDrawsBefore = $blurBefore; blurDrawsAfter = $blurAfter; deleted = [bool] (Get-Prop $delete 'ok') }
}

function Test-ALookThemeCache {
    $results = [ordered]@{}
    foreach ($theme in @('matte', 'matte-light', 'standard', 'classic', 'simple', 'album-art', 'card')) {
        $id = 'cac' + [guid]::NewGuid().ToString('N').Substring(0, 5)
        $look = New-ObsLook $id 'Original name' (Get-ThemeDefaults $theme)
        $run = Start-OverlayRun "A-LOOK-cache-$theme" @{} $null -NoReader -LooksJson (
            ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
        $chrome = $null
        try {
            $chrome = Start-Chrome "A-LOOK-cache-$theme"
            $expectedSize = Get-DefaultThemeSize $theme
            Set-OverlayViewport $chrome $expectedSize.source
            [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$id&sample=playing")
            [void] (Wait-PageConnected $chrome 15)
            [void] (Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'artLoadedSeq') -eq (Get-PageField $p 'artSeq') -and
                (Get-PageField $p 'artSeq') -ge 1) { $p } } 10 50)
            $a = Get-PageProbe $chrome
            $look.name = 'Renamed only'
            [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look))))
            [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
            $b = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'lookSeq') -gt (Get-PageField $a 'lookSeq')) { $p } } 10 50
            $aCounters = Get-PageField $a 'counters'; $bCounters = Get-PageField $b 'counters'
            $unchanged = $b -and (Get-Prop $aCounters 'blurDraws') -eq (Get-Prop $bCounters 'blurDraws') -and
                (Get-Prop $aCounters 'quantizerRuns') -eq (Get-Prop $bCounters 'quantizerRuns') -and
                (Get-Prop $aCounters 'coverLoads') -eq (Get-Prop $bCounters 'coverLoads')
            Add-Check "A-LOOK.cache.$theme.nameOnly" 'renaming saved look does not redraw blur, quantize, or reload cover' (
                [ordered]@{ before = $aCounters; after = $bCounters }) $unchanged
            $nextTheme = if ($theme -eq 'matte') { 'standard' } else { 'matte' }
            $nextSize = Get-DefaultThemeSize $nextTheme
            Set-OverlayViewport $chrome $nextSize.source
            $look.options = Get-ThemeDefaults $nextTheme
            [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look))))
            [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
            $c = Wait-For { $p = Get-PageProbe $chrome; if ($p.attrs.theme -eq $nextTheme) { $p } } 10 50
            $delta = [int] (Get-Prop (Get-PageField $c 'counters') 'blurDraws') - [int] (Get-Prop $bCounters 'blurDraws')
            Add-Check "A-LOOK.cache.$theme.themeSwitch" 'theme switch changes cache key and draws at most once (blur theme exactly once)' (
                [ordered]@{ nextTheme = $nextTheme; draws = $delta; coverLoads = Get-Prop (Get-PageField $c 'counters') 'coverLoads' }) (
                $c -and $c.attrs.theme -eq $nextTheme -and $delta -eq $(if ($nextTheme -eq 'standard') { 1 } else { 0 }))
            $results[$theme] = [ordered]@{ nameOnly = $unchanged; switch = $nextTheme; blurDraws = $delta }
        } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
    }
    $results
}

function Test-ALookThemeRegressions {
    $themes = @('pill', 'matte', 'matte-light', 'standard', 'classic', 'simple', 'album-art', 'card')
    $looks = @($themes | ForEach-Object {
        $o = Get-ThemeDefaults $_
        $o['colours'] = 'custom'; $o['background'] = '#123456'; $o['backgroundOpacity'] = 37
        New-ObsLook ("reg" + ([Array]::IndexOf($themes, $_)).ToString('D5')) "Regress $_" $o
    })
    $run = Start-OverlayRun 'A-LOOK-regressions' @{} 'PlayingLong' -NoReader -LooksJson (
        ConvertTo-ObsLooksJson (New-ObsLooksDocument $looks))
    $chrome = $null; $results = [ordered]@{}
    try {
        [void] (Wait-BenchReady $run.Root)
        $chrome = Start-Chrome 'A-LOOK-regressions'
        foreach ($theme in $themes) {
            $look = @($looks | Where-Object { $_.options.theme -eq $theme })[0]
            $size = Get-DefaultThemeSize $theme
            Set-OverlayViewport $chrome $size.source
            [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$($look.id)")
            $custom = Wait-For { $p = Get-PageProbe $chrome; if ($p.attrs.theme -eq $theme -and
                $p.attrs.colours -eq 'custom' -and (Get-PageField $p 'connection') -eq 'open') { $p } } 15 100
            $look.options['colours'] = 'auto'
            [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument $looks)))
            [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
            $auto = Wait-For { $p = Get-PageProbe $chrome; if ($p.attrs.colours -eq 'auto' -and
                (Get-PageField $p 'lookSeq') -gt (Get-PageField $custom 'lookSeq')) { $p } } 10 100
            $defaults = Get-ThemeDefaults $theme
            $result = [ordered]@{ custom = $custom.css; auto = $auto.css
                stored = Get-PageField $auto 'options'; viewport = $auto.pageSize; expectedSource = $size.source }
            $results["auto-$theme"] = $result
            Add-Check "A-LOOK.regression.$theme.autoPalette" 'auto restores theme background/opacity without erasing stored custom palette' $result (
                $custom -and $auto -and $custom.css.bg -eq '#123456' -and [Math]::Abs([double] $custom.css.bgAlpha - .37) -le .001 -and
                $auto.css.bg -eq $defaults.background -and
                [Math]::Abs([double] $auto.css.bgAlpha - [double] $defaults.backgroundOpacity / 100) -le .001 -and
                $result.stored.background -eq '#123456' -and $result.stored.backgroundOpacity -eq 37 -and
                (Test-OverlayViewport $auto $size.source))
        }
        $matte = @($looks | Where-Object { $_.options.theme -eq 'matte' })[0]
        $matteSize = Get-DefaultThemeSize 'matte'
        Set-OverlayViewport $chrome $matteSize.source
        [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$($matte.id)")
        [void] (Wait-PageConnected $chrome 15)
        $matte.options['showTimes'] = $false
        [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument $looks)))
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        [void] (Wait-For { $p = Get-PageProbe $chrome; if ($p.attrs.showTimes -eq 'false') { $p } } 10 100)
        $reanchor = Invoke-Cdp $chrome 'Runtime.evaluate' @{ expression =
            "apply({...msg,id:state.id,title:state.title,artist:state.artist,artwork:artUrl,position:100})" }
        if (Get-Prop $reanchor 'exceptionDetails') { throw 'A-LOOK same-pixel width setup failed' }
        Start-Sleep -Seconds 2
        $before = Get-PageProbe $chrome
        $expandedSource = @{ w = [int] $matteSize.source.w + 10; h = [int] $matteSize.source.h }
        Set-OverlayViewport $chrome $expandedSource
        $matte.options['width'] = [int] $matte.options.width + 10
        [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument $looks)))
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $after = Wait-For { $p = Get-PageProbe $chrome; if ([double] (Get-Prop (Get-PageField $p 'box') 'w') -eq
            [double] $matte.options.width -and $p.attrs.showTimes -eq 'false') { $p } } 10 100
        $beforePixel = [Math]::Floor([double] $before.geometry.bar.width * [double] (Get-PageField $before 'projectedPosition') / 14400)
        $afterPixel = [Math]::Floor([double] $after.geometry.bar.width * [double] (Get-PageField $after 'projectedPosition') / 14400)
        $expected = [double] (Get-PageField $after 'projectedPosition') / 14400
        $results['samePixelWidth'] = [ordered]@{ beforePixel = $beforePixel; afterPixel = $afterPixel
            renderedFraction = $after.frac; projectedFraction = $expected; viewport = $after.pageSize }
        Add-Check 'A-LOOK.regression.samePixelWidth' 'PlayingLong times-hidden width push preserves same fill pixel and DOM transform stays within 1% projection' $results.samePixelWidth (
            $before -and $after -and $beforePixel -eq $afterPixel -and
            [Math]::Abs([double] $after.frac - $expected) -le .01 -and
            (Test-OverlayViewport $after $expandedSource))
        $album = @($looks | Where-Object { $_.options.theme -eq 'album-art' })[0]
        $albumSize = Get-DefaultThemeSize 'album-art'
        Set-OverlayViewport $chrome $albumSize.source
        [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$($album.id)")
        $loaded = Wait-For { $p = Get-PageProbe $chrome; if ($p.attrs.theme -eq 'album-art' -and
            (Get-PageField $p 'artLoadedSeq') -eq (Get-PageField $p 'artSeq') -and
            (Get-PageField $p 'artFailed') -eq $false -and (Get-PageField $p 'raster').cover.w -gt 0) { $p } } 15 100
        $on = [byte[]] (Get-ChromeShotBytes $chrome)
        $onPath = Join-Path $shotDirectory 'A-LOOK-album-scrim-on.png'
        [IO.File]::WriteAllBytes($onPath, $on)
        [void] (Invoke-Cdp $chrome 'Runtime.evaluate' @{ expression = "document.getElementById('scrim').style.display='none'" })
        $off = [byte[]] (Get-ChromeShotBytes $chrome)
        $offPath = Join-Path $shotDirectory 'A-LOOK-album-scrim-off.png'
        [IO.File]::WriteAllBytes($offPath, $off)
        $onStream = [IO.MemoryStream]::new($on); $offStream = [IO.MemoryStream]::new($off)
        try {
            $onBitmap = [Drawing.Bitmap]::new($onStream); $offBitmap = [Drawing.Bitmap]::new($offStream)
            try {
                $x = [int] [Math]::Floor($loaded.boxRect.x + $loaded.boxRect.width - 7)
                $delta = 0; $y = 0
                $fromY = [int] [Math]::Floor($loaded.boxRect.y + $loaded.boxRect.height * .64)
                $toY = [int] [Math]::Floor($loaded.boxRect.y + $loaded.boxRect.height * .86)
                for ($probeY = $fromY; $probeY -le $toY; $probeY += [Math]::Max(1, [int] ($loaded.boxRect.height * .02))) {
                    $aPixel = $onBitmap.GetPixel($x, $probeY); $bPixel = $offBitmap.GetPixel($x, $probeY)
                    $change = [Math]::Abs($aPixel.R - $bPixel.R) + [Math]::Abs($aPixel.G - $bPixel.G) +
                        [Math]::Abs($aPixel.B - $bPixel.B)
                    if ($change -gt $delta) { $delta = $change; $y = $probeY }
                }
            } finally { $onBitmap.Dispose(); $offBitmap.Dispose() }
        } finally { $onStream.Dispose(); $offStream.Dispose() }
        $results['albumScrim'] = [ordered]@{ on = [IO.Path]::GetRelativePath($runDirectory, $onPath)
            off = [IO.Path]::GetRelativePath($runDirectory, $offPath); x = $x; y = $y; rgbDelta = $delta }
        Add-Check 'A-LOOK.regression.albumScrim' 'loaded album cover is visibly darkened by scrim above the bitmap' $results.albumScrim (
            $loaded -and (Test-OverlayViewport $loaded $albumSize.source) -and $delta -ge 10)
        # Runtime push, not a new fixture ID: a fractional card scale and artist-off
        # must agree with the server's published box/source, including the tail formula.
        $card = @($looks | Where-Object { $_.options.theme -eq 'card' })[0]
        $cardDefault = Get-DefaultThemeSize 'card'
        Set-OverlayViewport $chrome $cardDefault.source
        [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$($card.id)")
        $beforeCard = Wait-For { $p = Get-PageProbe $chrome; if ($p.attrs.theme -eq 'card' -and
            (Get-PageField $p 'connection') -eq 'open') { $p } } 15 100
        $card.options['scale'] = 60; $card.options['width'] = 280
        $card.options['showArtist'] = $false
        $card.options['showArt'] = $true; $card.options['showProgress'] = $true; $card.options['showTimes'] = $true
        $cornerSource = @{ w = 320; h = 356 }
        Set-OverlayViewport $chrome $cornerSource
        [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument $looks)))
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $corner = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'lookSeq') -gt
            (Get-PageField $beforeCard 'lookSeq') -and
            (Get-Prop (Get-PageField $p 'options') 'scale') -eq 60) { $p } } 10 100
        $published = Get-PageField $corner 'look'
        $nativeBox = Get-Prop $published 'box'; $nativeSource = Get-Prop $published 'source'
        $domBox = Get-PageField $corner 'box'; $domSource = Get-PageField $corner 'source'
        $cornerResult = [ordered]@{ nativeBox = $nativeBox; nativeSource = $nativeSource
            domBox = $domBox; domSource = $domSource; boxRect = $corner.boxRect
            pageSize = $corner.pageSize; mismatch = Get-PageField $corner 'boxMismatch'
            artist = Get-Prop (Get-PageField $corner 'options') 'showArtist' }
        $results['cardFractionalScale'] = $cornerResult
        Add-Check 'A-LOOK.regression.cardFractionalScale' 'runtime-published card scale60 artist-off box280×316/source320×356 equals DOM and full viewport' $cornerResult (
            $beforeCard -and $corner -and
            [int] (Get-Prop $nativeBox 'w') -eq 280 -and [int] (Get-Prop $nativeBox 'h') -eq 316 -and
            [int] (Get-Prop $nativeSource 'w') -eq 320 -and [int] (Get-Prop $nativeSource 'h') -eq 356 -and
            [int] (Get-Prop $domBox 'w') -eq 280 -and [int] (Get-Prop $domBox 'h') -eq 316 -and
            [int] (Get-Prop $domSource 'w') -eq 320 -and [int] (Get-Prop $domSource 'h') -eq 356 -and
            [Math]::Abs([double] $corner.boxRect.width - 280) -le 1 -and
            [Math]::Abs([double] $corner.boxRect.height - 316) -le 1 -and
            [string] $cornerResult.mismatch -in @('', 'false') -and $cornerResult.artist -eq $false -and
            (Test-OverlayViewport $corner $cornerSource))
        $results
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
}

function Get-CadenceAssertion($Start, $End, [string] $Theme, [bool] $ShowTimes, [double] $Rate,
    [double] $BarPx, [double] $Duration, [double] $Seconds = 60) {
    $a = Get-PageField $Start 'counters'; $b = Get-PageField $End 'counters'
    $ticks = [int] (Get-Prop $b 'ticks') - [int] (Get-Prop $a 'ticks')
    $fill = [int] (Get-Prop $b 'fillWrites') - [int] (Get-Prop $a 'fillWrites')
    $timeWrites = [int] (Get-Prop $b 'timeWrites') - [int] (Get-Prop $a 'timeWrites')
    $maxFill = [Math]::Ceiling($BarPx * $Rate * $Seconds / $Duration) + 2
    $maxTicks = [Math]::Ceiling($Seconds) + 1
    $labelApplicable = $ShowTimes -and $Theme -notin @('pill', 'album-art')
    $elapsed = { param($value) if ("$value" -match '^(\d+):(\d\d)$') { return [int] $Matches[1] * 60 + [int] $Matches[2] }; $null }
    $advance = if ($labelApplicable) { (& $elapsed $End.elapsed) - (& $elapsed $Start.elapsed) } else { $null }
    $passed = if ($labelApplicable) {
        $ticks -le $maxTicks -and $timeWrites -le $maxTicks -and [Math]::Abs([double] $advance - $Seconds * $Rate) -le 2
    } else { $fill -le $maxFill -and $ticks -eq $fill }
    $passed = $passed -and $Seconds -gt 0
    [ordered]@{ passed = $passed; seconds = $Seconds; rate = $Rate; showTimes = $ShowTimes
        labelApplicable = $labelApplicable; duration = $Duration; barPx = $BarPx; maxFill = $maxFill; maxTicks = $maxTicks
        ticks = $ticks; fillWrites = $fill; timeWrites = $timeWrites; elapsedStart = $Start.elapsed
        elapsedEnd = $End.elapsed; advance = $advance }
}

function Save-CadenceEvidence([string] $CheckId, $Start, $End, [switch] $Steady) {
    $seconds = ([double] (Get-Prop $End 'pageNow') - [double] (Get-Prop $Start 'pageNow')) / 1000
    $startSeq = Get-PageField $Start 'cadenceLogSequence'; $endSeq = Get-PageField $End 'cadenceLogSequence'
    $log = @(Get-PageField $End 'cadenceLog')
    $window = @($log | Where-Object { $_ -and $_.sequence -gt $startSeq -and $_.sequence -le $endSeq })
    $complete = $null -ne $startSeq -and $null -ne $endSeq -and $endSeq -ge $startSeq -and
        $window.Count -eq ([long] $endSeq - [long] $startSeq)
    $reanchors = @($window | Where-Object {
        ($_.kind -eq 'stepFill' -and $_.reason -ne 'timer') -or ($Steady -and $_.reason -eq 'reanchor')
    })
    $record = [ordered]@{ id = $CheckId; seconds = $seconds; pageStartMs = Get-Prop $Start 'pageNow'
        pageEndMs = Get-Prop $End 'pageNow'; qpcStart = Get-Prop $Start 'qpc'; qpcEnd = Get-Prop $End 'qpc'
        qpcFrequency = $freq; qpcSeconds = Get-Seconds (Get-Prop $Start 'qpc') (Get-Prop $End 'qpc')
        startSequence = $startSeq; endSequence = $endSeq; timelineComplete = [bool] $complete
        reanchors = $reanchors; steadyWindow = $complete -and $reanchors.Count -eq 0
        start = $Start; end = $End; cadenceLog = $log; windowTimeline = $window }
    $path = Join-Path $runDirectory "cadence-$(ConvertTo-SafeName $CheckId).json"
    $record['artifact'] = [IO.Path]::GetRelativePath($runDirectory, $path)
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $record -Depth 20), [Text.UTF8Encoding]::new($false))
    $summary = [ordered]@{ artifact = $record.artifact; seconds = $seconds; qpcSeconds = $record.qpcSeconds
        timelineComplete = [bool] $complete; events = $window.Count; reanchors = $reanchors.Count
        steadyWindow = $record.steadyWindow }
    Add-Check "$CheckId.evidence" 'start/end page probes, QPC, actual T and complete hook cadence timeline retained' $summary (
        $complete -and $seconds -gt 0 -and $record.qpcSeconds -gt 0)
    $summary
}

function Test-ThemeCadence([string] $Theme, [int] $Width, [bool] $ShowTimes, [double] $Rate,
    [switch] $Sample) {
    $label = "$Theme-w$Width-times$ShowTimes-rate$Rate" + $(if ($Sample) { '-sample' } else { '' })
    $id = 'cad' + [guid]::NewGuid().ToString('N').Substring(0, 5)
    $options = Get-ThemeDefaults $Theme; $options['width'] = $Width; $options['showTimes'] = $ShowTimes
    $sizes = Get-Content -Raw (Join-Path $fixtureDirectory 'expected-sizes.json') | ConvertFrom-Json -AsHashtable -Depth 16
    $size = @($sizes.rows | Where-Object { $_.theme -eq $Theme -and $_.width -eq $Width -and $_.scale -eq 100 -and
        $_.showArt -and $_.showArtist -and $_.showProgress -and $_.showTimes -eq $ShowTimes } | Select-Object -First 1)
    if ($size.Count -ne 1) { throw "A-LOOK cadence missing expected size for $label" }
    $run = Start-OverlayRun "A-LOOK-cadence-$label" @{} $(if ($Sample) { $null } else { 'PlayingLong' }) -NoReader `
        -LooksJson (ConvertTo-ObsLooksJson (New-ObsLooksDocument @((New-ObsLook $id $label $options))))
    $chrome = $null; $readHeld = $false
    try {
        [void] (Wait-BenchReady $run.Root -BenchProfile $(if ($Sample) { $null } else { 'PlayingLong' }))
        if (-not $Sample -and $Rate -ne 1) { [void] (Send-ObsHookCommand $run.Root 'command-obs-fixture-rate' "$Rate") }
        $chrome = Start-Chrome "A-LOOK-cadence-$label"
        Set-OverlayViewport $chrome $size[0].source
        [void] (Invoke-ChromeNavigate $chrome ("$($overlayUrl)?look=$id" + $(if ($Sample) { '&sample=playing' } else { '' })))
        $connected = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'connection') -eq 'open' -and
            (Get-PageField $p 'state') -eq 'playing' -and (Get-PageField $p 'shown') -eq $true -and
            (Get-Prop (Get-PageField $p 'look') 'id') -eq $id) {
                $p = Get-LookFxProbe $chrome; if ($p.fx.rate -eq $Rate) { $p }
            } } 15 250
        if (-not $connected) { throw "Cadence page $label never reached its connected playing look state" }
        # Score the page scheduler against one acknowledged rate-aware anchor, not live clock corrections.
        $readHeld = $true
        $holdQpc = Send-ObsHookCommand $run.Root 'command-obs-hold-read'
        Start-Sleep -Seconds 5
        $start = Get-PageProbe $chrome
        Start-Sleep -Seconds 60
        $end = Get-PageProbe $chrome
        $evidence = Save-CadenceEvidence "A-LOOK.cadence.$label" $start $end -Steady
        $predicate = Get-CadenceAssertion $start $end $Theme $ShowTimes $Rate ([double] $size[0].bar.width) $(if ($Sample) { 240 } else { 14400 }) $evidence.seconds
        $ok = $predicate.passed -and $evidence.steadyWindow -and (Test-OverlayViewport $end $size[0].source)
        $record = [ordered]@{ label = $label; rate = $Rate; showTimes = $ShowTimes; sample = [bool] $Sample
            duration = if ($Sample) { 240 } else { 14400 }; barPx = $predicate.barPx; maxFill = $predicate.maxFill
            ticks = $predicate.ticks; fillWrites = $predicate.fillWrites; timeWrites = $predicate.timeWrites; elapsedStart = $start.elapsed
            elapsedEnd = $end.elapsed; advance = $predicate.advance; seconds = $predicate.seconds
            maxTicks = $predicate.maxTicks; evidence = $evidence; holdQpc = $holdQpc }
        Add-Check "A-LOOK.cadence.$label.steadyWindow" 'reader held before settle; complete scoring timeline with zero reanchors' $record $evidence.steadyWindow
        Add-Check "A-LOOK.cadence.$label" 'after settle over actual T: times <=ceil(T)+1 (61 at T=60), advance rate*T ±2; hidden times pixel-only bound' $record $ok
        return $record
    } finally {
        try { if ($readHeld) { [void] (Send-ObsHookCommand $run.Root 'command-obs-release-read') } }
        finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
    }
}

function Test-ALookCadence {
    $results = [ordered]@{}
    foreach ($rate in @(0.25, 1, 2, 4)) {
        if ($GateProfile -eq 'Fast-v2' -and $rate -notin @(0.25, 2)) { continue }
        $results["rate$rate"] = Invoke-JournalCadenceRow -Id "cadence.timesHidden.rate$rate" -Measure {
        $run = Start-OverlayRun "A-LOOK-cadence-rate$rate" @{} 'PlayingLong' -NoReader
        $chrome = $null; $readHeld = $false
        try {
            [void] (Wait-BenchReady $run.Root)
            [void] (Send-ObsHookCommand $run.Root 'command-obs-fixture-rate' "$rate")
            $chrome = Start-Chrome "A-LOOK-cadence-rate$rate"
            [void] (Invoke-ChromeNavigate $chrome $overlayUrl)
            $connected = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'connection') -eq 'open' -and
                (Get-PageField $p 'shown') -eq $true -and (Get-PageField $p 'state') -eq 'playing') {
                    $p = Get-LookFxProbe $chrome; if ($p.fx.rate -eq $rate) { $p }
                } } 15 250
            if (-not $connected) { throw "Cadence timesHidden rate$rate did not acknowledge its playing rate." }
            $readHeld = $true
            $holdQpc = Send-ObsHookCommand $run.Root 'command-obs-hold-read'
            Start-Sleep -Seconds 5
            $start = Get-PageProbe $chrome
            Start-Sleep -Seconds 60
            $end = Get-PageProbe $chrome
            $a = Get-Prop $start.s 'counters'; $b = Get-Prop $end.s 'counters'
            $fillWrites = [int] (Get-Prop $b 'fillWrites') - [int] (Get-Prop $a 'fillWrites')
            $ticks = [int] (Get-Prop $b 'ticks') - [int] (Get-Prop $a 'ticks')
            $barPx = 400; $duration = 14400
            $evidence = Save-CadenceEvidence "A-LOOK.cadence.timesHidden.rate$rate" $start $end -Steady
            $maximum = [int] [Math]::Ceiling($barPx * $rate * $evidence.seconds / $duration) + 2
            $record = [ordered]@{ rate = $rate; fillWrites = $fillWrites; ticks = $ticks; maximum = $maximum
                seconds = $evidence.seconds; evidence = $evidence; holdQpc = $holdQpc }
            Add-Check "A-LOOK.cadence.timesHidden.rate$rate.steadyWindow" 'reader held before settle; complete scoring timeline with zero reanchors' $record $evidence.steadyWindow
            Add-Check "A-LOOK.cadence.timesHidden.rate$rate" 'after 5 s settle over actual T: fillWrites ≤ ceil(barPx*rate*T/duration)+2 and ticks=fillWrites' $record (
                $evidence.steadyWindow -and $evidence.seconds -gt 0 -and $fillWrites -le $maximum -and $ticks -eq $fillWrites)
            $results["rate$rate"] = $record
        } finally {
            try { if ($readHeld) { [void] (Send-ObsHookCommand $run.Root 'command-obs-release-read') } }
            finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
        }
        $results["rate$rate"]
        }
    }
    $results.sample240s = Invoke-JournalCadenceRow -Id 'cadence.sample240s' -Measure {
    $run = Start-OverlayRun 'A-LOOK-cadence-sample' @{} $null -NoReader
    $chrome = $null
    try {
        [void] (Wait-BenchReady $run.Root -BenchProfile $null)
        $chrome = Start-Chrome 'A-LOOK-cadence-sample'
        [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?sample=playing")
        [void] (Wait-PageConnected $chrome 15)
        Start-Sleep -Seconds 5
        $start = Get-PageProbe $chrome
        Start-Sleep -Seconds 60
        $end = Get-PageProbe $chrome
        $a = Get-Prop $start.s 'counters'; $b = Get-Prop $end.s 'counters'
        $fillWrites = [int] (Get-Prop $b 'fillWrites') - [int] (Get-Prop $a 'fillWrites')
        $ticks = [int] (Get-Prop $b 'ticks') - [int] (Get-Prop $a 'ticks')
        $evidence = Save-CadenceEvidence 'A-LOOK.cadence.sample240s' $start $end
        $maximum = [int] [Math]::Ceiling(400 * $evidence.seconds / 240) + 2
        $record = [ordered]@{ fillWrites = $fillWrites; ticks = $ticks; maximum = $maximum
            seconds = $evidence.seconds; evidence = $evidence }
        Add-Check 'A-LOOK.cadence.sample240s' 'pill sample phase duration 240 s stays within actual-T hidden-time fillWrites/ticks budget' $record (
            $evidence.seconds -gt 0 -and $fillWrites -le $maximum -and $ticks -eq $fillWrites)
        $results.sample240s = $record
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
    $results.sample240s
    }

    [void] (Invoke-JournalCadenceRow -Id 'cadence.progressOffNoTimer' -Measure {
    $progressOptions = Copy-LookOptions (New-DefaultPillOptions); $progressOptions['showProgress'] = $false
    $progressLook = New-ObsLook 'prog0001' 'No progress' $progressOptions
    $progressJson = ConvertTo-ObsLooksJson (New-ObsLooksDocument @($progressLook))
    $run = Start-OverlayRun 'A-LOOK-cadence-progress-off' @{} 'PlayingLong' -NoReader -LooksJson $progressJson
    $chrome = $null
    try {
        [void] (Wait-BenchReady $run.Root)
        $chrome = Start-Chrome 'A-LOOK-cadence-progress-off'
        [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=prog0001")
        $p = Wait-For { $x = Get-PageProbe $chrome; if ((Get-Prop (Get-Prop $x 'attrs') 'showProgress') -eq 'false') { $x } } 15 100
        Start-Sleep -Seconds 5
        $after = Get-PageProbe $chrome
        $evidence = Save-CadenceEvidence 'A-LOOK.cadence.progressOffNoTimer' $p $after
        Add-Check 'A-LOOK.cadence.progressOffNoTimer' 'showProgress=false means fill=100%, fillTimer=0 and no ticks after settle' ([ordered]@{
            fill = Get-Prop $after 'clipPx'; fillTimer = Get-Prop $after.s 'fillTimer'
            ticks = Get-Prop (Get-Prop $after.s 'counters') 'ticks'; evidence = $evidence }) (
            $p -and $after.clipPx -eq 400 -and (Get-Prop $after.s 'fillTimer') -eq 0 -and
            (Get-Prop $after.s 'counters' | ForEach-Object { Get-Prop $_ 'ticks' }) -eq 0)
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
    })
    if ($GateProfile -eq 'Fast-v2') {
        $base = Get-ThemeDefaults 'matte'
        foreach ($rate in @(0.25, 2)) {
            $results["matte-times-rate$rate"] = Invoke-JournalCadenceRow -Id "cadence.matte-w$($base.width)-timesTrue-rate$rate" -Measure {
                Test-ThemeCadence 'matte' ([int] $base.width) $true $rate
            }
        }
        return $results
    }
    foreach ($theme in @('matte', 'matte-light', 'standard', 'classic', 'simple', 'album-art', 'card')) {
        $base = Get-ThemeDefaults $theme
        foreach ($rate in @(0.25, 1, 2, 4)) {
            if ($theme -notin @('album-art')) {
                $results["$theme-times-rate$rate"] = Invoke-JournalCadenceRow -Id "cadence.$theme-w$($base.width)-timesTrue-rate$rate" -Measure {
                    Test-ThemeCadence $theme ([int] $base.width) $true $rate
                }
            }
        }
        foreach ($rate in @(1, 4)) {
            $results["$theme-pixel-rate$rate"] = Invoke-JournalCadenceRow -Id "cadence.$theme-w$($base.width)-timesFalse-rate$rate" -Measure {
                Test-ThemeCadence $theme ([int] $base.width) $false $rate
            }
        }
    }
    foreach ($width in @(360, 1200)) {
        $results["matte-width$width"] = Invoke-JournalCadenceRow -Id "cadence.matte-w$width-timesTrue-rate1" -Measure {
            Test-ThemeCadence 'matte' $width $true 1
        }
    }
    $results['matte-sample240'] = Invoke-JournalCadenceRow -Id 'cadence.matte-w440-timesTrue-rate1-sample' -Measure {
        Test-ThemeCadence 'matte' 440 $true 1 -Sample
    }
    $results
}

function Test-ALookMotion {
    $results = [ordered]@{}
    $expectedTranslation = @{ 'slide-up' = 'translateY(12px)'; 'slide-down' = 'translateY(-12px)'; 'slide-left' = 'translateX(12px)'; 'slide-right' = 'translateX(-12px)' }
    foreach ($animation in @('fade', 'slide-up', 'slide-down', 'slide-left', 'slide-right', 'none')) {
        $options = Copy-LookOptions (New-DefaultPillOptions); $options['showAnimation'] = $animation
        $look = New-ObsLook 'motion01' "show-$animation" $options
        $run = Start-OverlayRun "A-LOOK-motion-show-$animation" @{ ObsHidePaused = $true } 'Paused' -NoReader -LooksJson (
            ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
        $chrome = $null
        try {
            [void] (Wait-BenchReady $run.Root)
            $chrome = Start-Chrome "A-LOOK-motion-show-$animation"
            [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=motion01")
            $initial = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'state') -eq 'paused' -and (Get-PageField $p 'shown') -eq $false) { $p } } 20 100
            # Saved looks own paused behaviour; the global preference only changes the compatibility preset.
            $options['paused'] = 'dim'
            [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look))))
            [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
            $shown = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'shown') -eq $true) { $p } } 5 50
            $lastProbe = if ($shown) { $shown } else { Get-PageProbe $chrome }
            $transition = @(Get-Prop $shown 'animationDetails' | Where-Object { $null -ne $_ -and $_.duration -eq 500 } | Select-Object -First 1)
            $keyframes = if ($transition.Count) { @($transition[0].keyframes) } else { @() }
            $translationOk = if ($animation -in @('fade', 'none')) { $true } else {
                @($keyframes | Where-Object { $_.transform -like "*$($expectedTranslation[$animation])*" }).Count -gt 0
            }
            $fadeOpacity = @($keyframes | Where-Object { $null -ne $_.opacity }).Count -ge 2
            $motionPass = if ($animation -eq 'none') {
                (Get-Prop $shown 'running') -eq 0 -and $transition.Count -eq 0
            } else { $transition.Count -gt 0 -and $translationOk -and $fadeOpacity }
            Add-Check "A-LOOK.motion.show.$animation" "show $animation uses finite 500 ms opacity and approved 12 px direction; none is instant" ([ordered]@{
                initialHidden = [bool] $initial; timedOut = -not [bool] $shown; lastProbe = $lastProbe
                shown = Get-PageField $shown 'shown'; running = Get-Prop $shown 'running'; animation = $transition
                reducedMotion = Get-Prop $shown 'reducedMotionMedia' }) ($initial -and $shown -and (Get-PageField $shown 'shown') -eq $true -and $motionPass)
            $results["show-$animation"] = [bool] ($initial -and $shown -and $motionPass)
        } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }

        $options = Copy-LookOptions (New-DefaultPillOptions); $options['hideAnimation'] = $animation; $options['paused'] = 'dim'
        $look = New-ObsLook 'motion01' "hide-$animation" $options
        $run = Start-OverlayRun "A-LOOK-motion-hide-$animation" @{ ObsHidePaused = $false } 'Paused' -NoReader -LooksJson (
            ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
        $chrome = $null
        try {
            [void] (Wait-BenchReady $run.Root)
            $chrome = Start-Chrome "A-LOOK-motion-hide-$animation"
            [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=motion01")
            $visible = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'shown') -eq $true) { $p } } 20 100
            $options['paused'] = 'hide'
            [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look))))
            [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
            $hidden = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'shown') -eq $false) { $p } } 5 50
            $lastProbe = if ($hidden) { $hidden } else { Get-PageProbe $chrome }
            $hideTransition = @(Get-Prop $hidden 'animationDetails' | Where-Object { $null -ne $_ -and $_.duration -eq 500 } | Select-Object -First 1)
            $hideFrames = if ($hideTransition.Count) { @($hideTransition[0].keyframes) } else { @() }
            $hideTranslation = if ($animation -in @('fade', 'none')) { $true } else {
                @($hideFrames | Where-Object { $_.transform -like "*$($expectedTranslation[$animation])*" }).Count -gt 0
            }
            $hideOpacity = @($hideFrames | Where-Object { $null -ne $_.opacity }).Count -ge 2
            $hidePass = if ($animation -eq 'none') {
                (Get-Prop $hidden 'running') -eq 0 -and $hideTransition.Count -eq 0
            } else { $hideTransition.Count -gt 0 -and $hideTranslation -and $hideOpacity }
            Add-Check "A-LOOK.motion.hide.$animation" "hide $animation uses finite 500 ms opacity and approved direction; none is instant" ([ordered]@{
                timedOut = -not [bool] $hidden; lastProbe = $lastProbe
                visible = Get-PageField $visible 'shown'; hidden = Get-PageField $hidden 'shown'; animation = $hideTransition
                configured = Get-Prop (Get-Prop $hidden 'attrs') 'animHide' }) (
                $visible -and $hidden -and (Get-Prop (Get-Prop $hidden 'attrs') 'animHide') -eq $animation -and $hidePass)
            $results["hide-$animation"] = [bool] ($visible -and $hidden -and $hidePass)
        } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
    }
    # The browser's OS preference is deliberately emulated; only the app ReduceMotion hook may suppress transitions.
    $run = Start-OverlayRun 'A-LOOK-motion-reduced-media' @{ ObsHidePaused = $true } 'Paused' -NoReader
    $chrome = $null
    try {
        [void] (Wait-BenchReady $run.Root)
        $chrome = Start-Chrome 'A-LOOK-motion-reduced-media'
        [void] (Invoke-Cdp $chrome 'Emulation.setEmulatedMedia' @{ features = @(@{ name = 'prefers-reduced-motion'; value = 'reduce' }) })
        [void] (Invoke-ChromeNavigate $chrome $overlayUrl)
        [void] (Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'state') -eq 'paused') { $p } } 20 100)
        [void] (Send-HookCommand $run.Root 'command-obs-hide-paused-off')
        $p = Wait-For { $x = Get-PageProbe $chrome; if ((Get-PageField $x 'shown') -eq $true) { $x } } 5 50
        $lastProbe = if ($p) { $p } else { Get-PageProbe $chrome }
        Add-Check 'A-LOOK.motion.ignoresReducedMedia' 'prefers-reduced-motion does not suppress the finite application transition' ([ordered]@{
            timedOut = -not [bool] $p; lastProbe = $lastProbe
            media = Get-Prop $p 'reducedMotionMedia'; animations = Get-Prop $p 'animations'; details = Get-Prop $p 'animationDetails' }) (
            $p -and (Get-Prop $p 'reducedMotionMedia') -eq $true -and @(Get-Prop $p 'animationDetails' | Where-Object { $null -ne $_ -and $_.duration -eq 500 }).Count -gt 0)
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
    # App ReduceMotion, unlike the emulated OS preference, cancels a running transition immediately.
    $run = Start-OverlayRun 'A-LOOK-motion-reduce-on' @{ ObsHidePaused = $true } 'Paused' -NoReader
    $reader = $null; $chrome = $null
    try {
        [void] (Wait-BenchReady $run.Root)
        $reader = Start-SseReader 'A-LOOK-motion-reduce-on' 30 '/events'
        [void] (Wait-SseOpen $reader)
        $chrome = Start-Chrome 'A-LOOK-motion-reduce-on'
        [void] (Invoke-ChromeNavigate $chrome $overlayUrl)
        [void] (Wait-For { $x = Get-PageProbe $chrome; if ((Get-PageField $x 'state') -eq 'paused') { $x } } 20 100)
        [void] (Send-HookCommand $run.Root 'command-obs-hide-paused-off')
        $transition = Wait-For { $x = Get-PageProbe $chrome; if ((Get-Prop $x 'running') -gt 0) { $x } } 3 20
        [void] (Send-ObsHookCommand $run.Root 'command-obs-reduce-motion-on')
        $reducedEvent = Wait-SseLook $reader { param($m) (Get-Prop $m 'reduceMotion') -eq $true } 10
        $settled = Wait-For { $x = Get-PageProbe $chrome; if ((Get-Prop $x 'running') -eq 0) { $x } } 2 20
        $lastProbe = if ($settled) { $settled } else { Get-PageProbe $chrome }
        Add-Check 'A-LOOK.motion.reduceMotionCancels' 'ReduceMotion look push cancels a currently running show transition and applies its final state immediately' ([ordered]@{
            transitionTimedOut = -not [bool] $transition; settleTimedOut = -not [bool] $settled; lastProbe = $lastProbe
            wasRunning = [bool] $transition; lookObserved = [bool] $reducedEvent; finalShown = Get-PageField $settled 'shown'
            running = Get-Prop $settled 'running' }) ($transition -and $reducedEvent -and $settled -and (Get-Prop $settled 'running') -eq 0 -and
            (Get-PageField $settled 'shown') -eq $true)
    } finally { Stop-SseReader $reader; Stop-Chrome $chrome; Stop-OverlayRun $run }
    $results
}
function Get-PumpSlotValueCount($Value) {
    if ($null -eq $Value) { return 0 }
    if ($Value -is [bool]) { return [int] $Value }
    if ($Value -is [array]) { return @($Value | Where-Object { $null -ne $_ }).Count }
    $count = Get-Prop $Value 'count'
    if ($null -ne $count -and "$count" -match '^\d+$') { return [int] $count }
    1
}
function Get-PumpSlotMax($Node, [string] $Slot) {
    if ($null -eq $Node) { return 0 }
    if ($Node -is [string] -or $Node -is [ValueType]) { return 0 }
    $direct = Get-Prop $Node $Slot
    if ($null -ne $direct) { return Get-PumpSlotValueCount $direct }
    $children = @()
    if ($Node -is [Collections.IDictionary]) { $children = @($Node.Values) }
    elseif ($Node -is [array]) { $children = $Node }
    elseif ($Node.PSObject) { $children = @($Node.PSObject.Properties | ForEach-Object { $_.Value }) }
    $max = 0
    foreach ($child in $children) {
        $value = Get-PumpSlotMax $child $Slot
        if ($value -gt $max) { $max = $value }
    }
    $max
}
function Get-PumpSlotCount($PumpState, [string] $Section, [string] $Slot) {
    Get-PumpSlotMax (Get-Prop $PumpState $Section) $Slot
}
function Get-PumpObservation($Snapshot, [int] $Index) {
    $pump = Get-Overlay $Snapshot 'pump'
    $streams = Get-Overlay $Snapshot 'openStreams'
    if ($null -eq $pump -or $null -eq $streams -or $streams -le 0) { return $null }
    $pending = @(Get-Prop $pump 'pending'); $inFlight = @(Get-Prop $pump 'inFlight')
    if ($pending.Count -ne $streams -or $inFlight.Count -ne $streams) { return $null }
    foreach ($slot in @($pending) + @($inFlight)) {
        if ((Get-Prop $slot 'look') -isnot [bool] -or (Get-Prop $slot 'data') -isnot [bool]) { return $null }
    }
    [pscustomobject][ordered]@{
        index = $Index; streams = $streams; holdMs = Get-Prop $pump 'holdMs'
        inFlightLook = Get-PumpSlotCount $pump 'inFlight' 'look'; inFlightData = Get-PumpSlotCount $pump 'inFlight' 'data'
        pendingLook = Get-PumpSlotCount $pump 'pending' 'look'; pendingData = Get-PumpSlotCount $pump 'pending' 'data'
        inFlightPairs = @($inFlight | Where-Object { $_.look -and $_.data }).Count
        pendingPairs = @($pending | Where-Object { $_.look -and $_.data }).Count
    }
}
function Test-ALookBackpressure {
    $results = [ordered]@{}
    $options = New-DefaultPillOptions; $look = New-ObsLook 'back0001' 'Backpressure' $options
    $run = Start-OverlayRun 'A-LOOK-backpressure-hold' @{} 'PlayingLong' -NoReader -LooksJson (
        ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
    $reader = $null; $chrome = $null
    try {
        [void] (Wait-BenchReady $run.Root)
        $reader = Start-SseReader 'A-LOOK-backpressure-held' 30 '/events?look=back0001'
        [void] (Wait-SseOpen $reader)
        [void] (Wait-SseLook $reader { param($m) (Get-Prop $m 'id') -eq 'back0001' } 15)
        $chrome = Start-Chrome 'A-LOOK-backpressure-held'
        [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=back0001")
        [void] (Wait-For { $p = Get-PageProbe $chrome; if ((Get-Prop (Get-PageField $p 'look') 'id') -eq 'back0001') { $p } } 15 100)
        # Warm the identical held push + snapshot workload and the full-GC hook before measuring managed retention.
        [void] (Send-ObsHookCommand $run.Root 'command-obs-collect-managed-bytes')
        [void] (Get-State $run.Root 'pumpHeapWarm')
        $samples = [Collections.Generic.List[object]]::new()
        $startManagedBytes = $null; $endManagedBytes = $null; $startBytes = $null; $endBytes = $null
        $prime = $null; $heldEventCount = $null; $releasedLooks = @(); $releasedData = @()
        for ($round = 0; $round -lt 2; $round++) {
            # One sustained hold spans all 40 commands; zero releases even an already-held pump.
            [void] (Send-ObsHookCommand $run.Root 'command-obs-pump-hold' '30000')
            $beforeEvents = @(Read-Sse $reader); $beforeCount = $beforeEvents.Count
            # Reload a genuinely changed saved look: the normal SetLooks path atomically primes look + latest data.
            $options['width'] = if ($round -eq 0) { 410 } else { 400 }
            [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @(
                (New-ObsLook 'back0001' 'Backpressure' $options)))))
            [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
            $primed = Wait-For {
                $obs = Get-PumpObservation (Get-State $run.Root "prime$round") -1
                if ($obs -and $obs.inFlightPairs -eq $obs.streams) { $obs }
            } 5 25
            if ($round -eq 1) {
                $prime = $primed
                [void] (Send-ObsHookCommand $run.Root 'command-obs-collect-managed-bytes')
                $startManagedBytes = Get-Overlay (Get-State $run.Root 'pumpHeapBefore') 'retainedManagedBytes'
                $startBytes = (Get-Process -Id $run.App.Id).PrivateMemorySize64
            }
            for ($i = 0; $i -lt 40; $i++) {
                $pairIndex = [int] [Math]::Floor($i / 2)
                if (($i % 2) -eq 0) {
                    $command = if (($pairIndex % 2) -eq 0) { 'command-obs-reduce-motion-on' } else { 'command-obs-reduce-motion-off' }
                } else {
                    # Existing production setting path re-sends latest real data, including on saved-look streams.
                    $command = if (($pairIndex % 2) -eq 0) { 'command-obs-hide-paused-off' } else { 'command-obs-hide-paused-on' }
                }
                [void] (Send-ObsHookCommand $run.Root $command)
                if (($i % 5) -eq 4) {
                    $obs = Get-PumpObservation (Get-State $run.Root "pump$round-$i") $i
                    if ($round -eq 1) { $samples.Add($obs) }
                }
            }
            if ($round -eq 1) {
                $heldEventCount = @(Read-Sse $reader).Count - $beforeCount
                [void] (Send-ObsHookCommand $run.Root 'command-obs-collect-managed-bytes')
                $endManagedBytes = Get-Overlay (Get-State $run.Root 'pumpHeapAfter') 'retainedManagedBytes'
                $endBytes = (Get-Process -Id $run.App.Id).PrivateMemorySize64
            }
            [void] (Send-ObsHookCommand $run.Root 'command-obs-pump-hold' '0')
            [void] (Wait-For { $e = @(Read-Sse $reader); if ($e.Count -ge $beforeCount + 4) { $true } } 5 25)
            Start-Sleep -Milliseconds 250
            if ($round -eq 1) {
                $released = @(Read-Sse $reader | Select-Object -Skip $beforeCount)
                $releasedLooks = @(Get-LookEvents $released); $releasedData = @(Get-DataEvents $released)
            }
        }
        $heapMeasured = $null -ne $startManagedBytes -and $null -ne $endManagedBytes -and $startManagedBytes -gt 0 -and $endManagedBytes -gt 0
        $managedDelta = if ($heapMeasured) { [long] $endManagedBytes - [long] $startManagedBytes } else { $null }
        $validSamples = @($samples | Where-Object { $null -ne $_ })
        $excess = @($validSamples | Where-Object { $_.inFlightLook -gt 1 -or $_.inFlightData -gt 1 -or $_.pendingLook -gt 1 -or $_.pendingData -gt 1 })
        $coalesced = @($validSamples | Where-Object { $_.index -ge 4 -and $_.holdMs -eq 30000 -and
            $_.inFlightPairs -eq $_.streams -and $_.pendingPairs -eq $_.streams })
        $pairOrder = $releasedLooks.Count -eq 2 -and $releasedData.Count -eq 2 -and
            $releasedLooks[0].qpc -lt $releasedData[0].qpc -and $releasedData[0].qpc -lt $releasedLooks[1].qpc -and
            $releasedLooks[1].qpc -lt $releasedData[1].qpc
        Add-Check 'A-LOOK.backpressure.pumpHoldBounded' 'after an identical warm-up, 40 alternating look/data pushes coalesce behind one sustained hold into one pending pair per stream; release delivers only the in-flight and newest pairs in order; full-GC retained managed growth < 1 MiB' (
            [ordered]@{ samples = @($samples); validSamples = $validSamples.Count; prime = $prime; overBound = $excess.Count
                coalescedSamples = $coalesced.Count; heldEvents = $heldEventCount; releasedLooks = $releasedLooks.Count
                releasedData = $releasedData.Count; pairOrder = $pairOrder; warmupPushes = 40
                retainedManagedBytesBefore = $startManagedBytes; retainedManagedBytesAfter = $endManagedBytes
                retainedManagedBytesDelta = $managedDelta; privateBytesDelta = $endBytes - $startBytes }) (
            $prime -and $samples.Count -eq 8 -and $validSamples.Count -eq 8 -and $excess.Count -eq 0 -and
            $coalesced.Count -gt 0 -and $heldEventCount -eq 0 -and $pairOrder -and $heapMeasured -and $managedDelta -lt 1MB)
        $events = @(Read-Sse $reader); $lookEvents = @(Get-LookEvents $events); $dataEvents = @(Get-DataEvents $events)
        $finalLook = if ($lookEvents.Count) { $lookEvents[-1].data } else { $null }
        $lastSeq = Get-Prop $finalLook 'seq'
        $finalPage = Wait-For {
            $p = Get-PageProbe $chrome
            $receivedAt = Get-PageField $p 'receivedAt'; $lookReceivedAt = Get-PageField $p 'lookReceivedAt'
            if ((Get-PageField $p 'lookSeq') -eq $lastSeq -and $null -ne $receivedAt -and
                $null -ne $lookReceivedAt -and $receivedAt -ge $lookReceivedAt) { $p }
        } 5 100
        $pageLook = Get-PageField $finalPage 'look'
        $lastData = if ($dataEvents.Count) { $dataEvents[-1].data } else { $null }
        $pageDataMatches = $lastData -and (Get-PageField $finalPage 'state') -eq (Get-Prop $lastData 'state') -and
            (Get-PageField $finalPage 'title') -eq (Get-Prop $lastData 'title') -and
            (Get-PageField $finalPage 'hidePaused') -eq (Get-Prop $lastData 'hidePaused') -and
            (Get-Prop $lastData 'hidePaused') -eq $true
        Add-Check 'A-LOOK.backpressure.pumpFinalLatest' 'after hold release, latest __state equals the final look/data and look precedes data' ([ordered]@{
            looks = $lookEvents.Count; data = $dataEvents.Count; reduceMotion = Get-Prop $finalLook 'reduceMotion'
            pageSeq = Get-PageField $finalPage 'lookSeq'; eventSeq = $lastSeq; pageState = Get-PageField $finalPage 'state'
            pageTitle = Get-PageField $finalPage 'title'; dataTitle = Get-Prop $lastData 'title'
            pageHidePaused = Get-PageField $finalPage 'hidePaused'; dataHidePaused = Get-Prop $lastData 'hidePaused'
            pageWidth = Get-Prop (Get-PageField $finalPage 'options') 'width'; pairOrder = $pairOrder }) (
            $finalLook -and $finalPage -and $lastData -and (Get-Prop $finalLook 'reduceMotion') -eq $false -and
            (Get-Prop $pageLook 'reduceMotion') -eq $false -and (Get-PageField $finalPage 'lookSeq') -eq $lastSeq -and
            $pageDataMatches -and (Get-Prop (Get-PageField $finalPage 'options') 'width') -eq 400 -and $pairOrder)
    } finally { Stop-SseReader $reader; Stop-Chrome $chrome; Stop-OverlayRun $run }

    # A blocked data write must not absorb an independent pending look update; close then verify a fresh stream.
    $run = Start-OverlayRun 'A-LOOK-backpressure-resume' @{} 'PlayingLong' -NoReader
    $raw = $null; $fresh = $null
    try {
        [void] (Wait-BenchReady $run.Root)
        $raw = Open-RawStream -Path '/events' -NoRead
        [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'write0') 'streams') -eq 1 } 10 250)
        [void] (Send-HookCommand $run.Root 'command-obs-burst')
        $pending = Wait-For { $s = Get-State $run.Root 'writePending'; if ((Get-Overlay $s 'pendingWrite') -eq $true) { $s } } 20 250
        [void] (Send-ObsHookCommand $run.Root 'command-obs-reduce-motion-on')
        $queued = Get-Overlay (Get-State $run.Root 'lookQueued') 'pump'
        $queuedLook = Get-PumpSlotCount $queued 'pending' 'look'
        Close-RawStream $raw; $raw = $null
        [void] (Wait-For { $s = Get-State $run.Root 'writeClosed'; if ((Get-Overlay $s 'lastStreamEndReason') -eq 'Closed') { $s } } 10 250)
        $fresh = Start-SseReader 'A-LOOK-backpressure-after-close' 30 '/events'
        $firstLook = Wait-SseLook $fresh { param($m) (Get-Prop $m 'reduceMotion') -eq $true } 15
        $firstData = Wait-SseData $fresh { param($d) (Get-Prop $d 'state') -eq 'playing' } 15
        Add-Check 'A-LOOK.backpressure.blockedWriteResumed' '8 MiB blocked data write does not swallow a later look; after client close a fresh stream receives the latest look before data' (
            [ordered]@{ pendingWrite = [bool] $pending; queuedLook = $queuedLook; lookQpc = Get-Prop $firstLook 'qpc'; dataQpc = Get-Prop $firstData 'qpc' }) (
            $pending -and $queuedLook -ge 1 -and $firstLook -and $firstData -and $firstLook.qpc -lt $firstData.qpc)
    } finally { Close-RawStream $raw; Stop-SseReader $fresh; Stop-OverlayRun $run }

    # The same blocked writer is cancelled at its five-minute stream lifetime, then a new stream receives the latest slots.
    $run = Start-OverlayRun 'A-LOOK-backpressure-lifetime' @{} 'PlayingLong' -NoReader
    $raw = $null; $fresh = $null
    try {
        [void] (Wait-BenchReady $run.Root)
        $raw = Open-RawStream -Path '/events' -NoRead
        [void] (Wait-For { (Get-Overlay (Get-State $run.Root 'life0') 'streams') -eq 1 } 10 250)
        [void] (Send-HookCommand $run.Root 'command-obs-burst')
        $pending = Wait-For { if ((Get-Overlay (Get-State $run.Root 'lifePending') 'pendingWrite') -eq $true) { $true } } 20 250
        [void] (Send-ObsHookCommand $run.Root 'command-obs-reduce-motion-on')
        $lifetime = Wait-For {
            $s = Get-State $run.Root 'lifeEnd'
            if ((Get-Overlay $s 'lastStreamEndReason') -eq 'Lifetime' -and (Get-Overlay $s 'streams') -eq 0) { $s }
        } 330 1000
        Close-RawStream $raw; $raw = $null
        $fresh = Start-SseReader 'A-LOOK-backpressure-after-lifetime' 30 '/events'
        $latestLook = Wait-SseLook $fresh { param($m) (Get-Prop $m 'reduceMotion') -eq $true } 15
        $latestData = Wait-SseData $fresh { param($d) (Get-Prop $d 'state') -eq 'playing' } 15
        Add-Check 'A-LOOK.backpressure.blockedWriteLifetime' 'blocked write is aborted at Lifetime, no stale bytes follow and reconnect gets the latest look before data' (
            [ordered]@{ pendingWrite = [bool] $pending; endReason = Get-Overlay $lifetime 'lastStreamEndReason'
                streams = Get-Overlay $lifetime 'streams'; lookQpc = Get-Prop $latestLook 'qpc'; dataQpc = Get-Prop $latestData 'qpc' }) (
            $pending -and $lifetime -and $latestLook -and $latestData -and $latestLook.qpc -lt $latestData.qpc)
    } finally { Close-RawStream $raw; Stop-SseReader $fresh; Stop-OverlayRun $run }
    $results
}

function Test-ALookQueryGrammar {
    $saved = New-ObsLook 'look0001' 'Query grammar' (New-DefaultPillOptions)
    $run = Start-OverlayRun 'A-LOOK-query' @{} 'PlayingLong' -NoReader -LooksJson (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($saved)))
    $streams = [Collections.Generic.List[object]]::new()
    try {
        [void] (Wait-BenchReady $run.Root)
        [void] (Send-PreviewNonce $run.Root 'pv000001')
        [void] (Send-DraftLook $run.Root (New-ObsLook 'draft' 'Draft query' (New-DefaultPillOptions)))
        $acceptedPages = @('/', '/?look=look0001', '/?look=draft&preview=1&pv=pv000001&sample=playing',
            '/?look=look0001&sample=paused', '/?sample=noart')
        $pageResults = [Collections.Generic.List[object]]::new()
        foreach ($path in $acceptedPages) {
            $response = Invoke-RawHttp '127.0.0.1' (New-Request -Path $path)
            $pageResults.Add([ordered]@{ path = $path; status = $response.status; type = $response.headers['content-type'] })
        }
        Add-Check 'A-LOOK.query.allowedPageGrammar' 'all five §2.1 page query forms return 200 text/html' @($pageResults) (
            $pageResults.Count -eq 5 -and @($pageResults | Where-Object { $_.status -ne 200 -or $_.type -notlike 'text/html*' }).Count -eq 0)
        $validEventPaths = @('/events', '/events?look=look0001', '/events?look=draft&pv=pv000001&sample=playing',
            '/events?look=look0001&sample=paused', '/events?sample=playing')
        $eventResults = [Collections.Generic.List[object]]::new()
        foreach ($path in $validEventPaths) {
            $stream = Open-RawStream -Path $path
            $streams.Add($stream)
            $eventResults.Add([ordered]@{ path = $path; status = $stream.Status; contentType = $stream.Headers['content-type'] })
            Close-RawStream $stream; [void] $streams.Remove($stream)
        }
        Add-Check 'A-LOOK.query.allowedEventGrammar' 'all five §2.1 events query forms return 200 event-stream' @($eventResults) (
            $eventResults.Count -eq 5 -and @($eventResults | Where-Object { $_.status -ne 200 -or $_.contentType -notlike 'text/event-stream*' }).Count -eq 0)
        $badPaths = @(
            '/?LOOK=look0001', '/?look=LOOK0001', '/?look=', '/?look=look0001&look=look0001', '/?look=look0001&x=1',
            '/?sample=playing&look=look0001', '/?look=look0001%26sample=playing', '/?sample=play+ing',
            '/?look=draft&pv=pv000001', '/?look=draft&preview=1&pv=bad', '/?look=draft&preview=2&pv=pv000001',
            '/events?LOOK=look0001', '/events?look=LOOK0001', '/events?look=', '/events?look=look0001&look=look0001',
            '/events?look=look0001&x=1', '/events?sample=playing&look=look0001', '/events?look=look0001%26sample=playing',
            '/events?sample=play+ing', '/events?pv=pv000001', '/overlay.js?x=1', '/art/sample?x=1'
        )
        $badResults = [Collections.Generic.List[object]]::new()
        foreach ($path in $badPaths) {
            $response = Invoke-RawHttp '127.0.0.1' (New-Request -Path $path)
            $badResults.Add([ordered]@{ path = $path; status = $response.status; origin = $response.origin })
        }
        Add-Check 'A-LOOK.query.rejectsMalformedAndReordered' 'every malformed, duplicate, extra, case-variant, encoded, plus, wrong-order, and wrong-route query returns 400 from the app' (
            @($badResults | Where-Object { $_.status -ne 400 -or $_.origin -ne 'app' })) (
            $badResults.Count -eq $badPaths.Count -and @($badResults | Where-Object { $_.status -ne 400 -or $_.origin -ne 'app' }).Count -eq 0)

        $firstPreview = Open-RawStream -Path '/events?look=draft&pv=pv000001&sample=playing'
        $streams.Add($firstPreview)
        $countBeforeUnknown = Get-Overlay (Get-State $run.Root 'pvUnknownBefore') 'streams'
        $unknown = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/events?look=draft&pv=unknown1')
        $countAfterUnknown = Get-Overlay (Get-State $run.Root 'pvUnknownAfter') 'streams'
        [void] (Send-PreviewNonce $run.Root 'pv000002')
        $countBeforeRetired = Get-Overlay (Get-State $run.Root 'pvRetiredBefore') 'streams'
        $retired = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/events?look=draft&pv=pv000001')
        $countAfterRetired = Get-Overlay (Get-State $run.Root 'pvRetiredAfter') 'streams'
        $newPreview = Open-RawStream -Path '/events?look=draft&pv=pv000002&sample=playing'
        $streams.Add($newPreview)
        for ($i = 3; $i -le 11; $i++) { [void] (Send-PreviewNonce $run.Root ('pv{0:D6}' -f $i)) }
        $afterEightSwitches = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/events?look=draft&pv=pv000001')
        $lastNonce = 'pv000011'
        $lastPreview = Open-RawStream -Path "/events?look=draft&pv=$lastNonce"
        $streams.Add($lastPreview)
        Close-RawStream $lastPreview; [void] $streams.Remove($lastPreview)
        [void] (Send-DraftLook $run.Root $null)
        [void] (Send-PreviewNonce $run.Root 'clear')
        $countBeforeClosedPv = Get-Overlay (Get-State $run.Root 'pvClosedBefore') 'streams'
        $afterClose = Invoke-RawHttp '127.0.0.1' (New-Request -Path "/events?look=draft&pv=$lastNonce")
        $countAfterClosedPv = Get-Overlay (Get-State $run.Root 'pvClosedAfter') 'streams'
        Add-Check 'A-LOOK.query.previewNonceRotation' 'current pv admits 200; unknown/rotated/>8-switch/closed well-formed tokens are 410; 410s never change stream counts' ([ordered]@{
            first = $firstPreview.Status; next = $newPreview.Status; last = $lastPreview.Status; unknown = $unknown.status
            retired = $retired.status; afterEight = $afterEightSwitches.status; afterClose = $afterClose.status
            unknownCounts = @($countBeforeUnknown, $countAfterUnknown); retiredCounts = @($countBeforeRetired, $countAfterRetired)
            closedCounts = @($countBeforeClosedPv, $countAfterClosedPv) }) (
            $firstPreview.Status -eq 200 -and $newPreview.Status -eq 200 -and $lastPreview.Status -eq 200 -and
            $unknown.status -eq 410 -and $retired.status -eq 410 -and $afterEightSwitches.status -eq 410 -and $afterClose.status -eq 410 -and
            $countBeforeUnknown -eq $countAfterUnknown -and $countBeforeRetired -eq $countAfterRetired -and
            $countBeforeClosedPv -eq $countAfterClosedPv)
        Add-Check 'A-LOOK.query.previewNonceHeaders' '410 responses carry standard app headers, no CSP and no CORS headers' ([ordered]@{
            unknown = $unknown.headers; retired = $retired.headers; afterEight = $afterEightSwitches.headers; afterClose = $afterClose.headers }) (
            $unknown.status -eq 410 -and $unknown.origin -eq 'app' -and $unknown.headers['x-content-type-options'] -eq 'nosniff' -and
            $unknown.headers['cache-control'] -like '*no-store*' -and $unknown.headers['referrer-policy'] -eq 'no-referrer' -and
            -not $unknown.headers.Contains('content-security-policy') -and
            @($unknown.headers.Keys | Where-Object { $_ -like 'access-control-*' }).Count -eq 0)
    } finally { foreach ($s in $streams) { Close-RawStream $s }; Stop-OverlayRun $run }
}
function Test-StoreReadOnlyCase([string] $Root, [string] $Label, [byte[]] $Bytes, [switch] $DenyRead) {
    $path = Join-Path $Root 'data/obs-looks.json'
    [IO.File]::WriteAllBytes($path, $Bytes)
    $beforeHash = Get-Sha256 $path
    $aclApplied = $false
    try {
        if ($DenyRead) {
            & icacls.exe $path /deny '*S-1-1-0:(R)' | Out-Null
            $aclApplied = $LASTEXITCODE -eq 0
            if ($aclApplied) { $aclDenied.Add($path) }
        }
        [void] (Send-ObsHookCommand $Root 'command-obs-looks-reload')
        $snapshot = Get-State $Root "store-$Label"
    } finally {
        if ($aclApplied) {
            & icacls.exe $path /remove:d '*S-1-1-0' | Out-Null
            [void] $aclDenied.Remove($path)
        }
    }
    $afterHash = Get-Sha256 $path
    $store = Get-Overlay $snapshot 'looks'
    $readOnly = Get-Prop $store 'readOnly'
    $reason = Get-Prop $store 'reason'
    if ($DenyRead -and -not $aclApplied) {
        Add-Blocked "A-STORE-1.$Label.acl" 'unreadable looks file enters read-only state' 'icacls could not apply an Everyone read-deny rule on this PC'
    } else {
        Add-Check "A-STORE-1.$Label.readOnlyReason" 'whole-file failure is read-only with a non-empty diagnostic reason' ([ordered]@{
            readOnly = $readOnly; reason = $reason }) ($readOnly -eq $true -and -not [string]::IsNullOrWhiteSpace([string] $reason))
        Add-Check "A-STORE-1.$Label.bytesPreserved" 'invalid looks bytes remain unchanged' ([ordered]@{ before = $beforeHash; after = $afterHash }) ($beforeHash -ceq $afterHash)
        if ($DenyRead) { Add-Check 'A-STORE-1.acl.unreadable' 'ACL failure is reported read-only and leaves source bytes unchanged' $aclApplied ($readOnly -eq $true -and $beforeHash -ceq $afterHash) }
        if ($readOnly -eq $true) {
            $writeBlockedHash = Get-Sha256 $path
            $sequence = 10000 + $script:labelSeq
            $writeBlocked = Invoke-ObsLookCommit $Root $sequence @{ action = 'create'; name = 'Must remain blocked'; options = (New-DefaultPillOptions) }
            $afterBlockedHash = Get-Sha256 $path
            Add-Check "A-STORE-1.$Label.writeBlocked" 'read-only state blocks mutations without changing source bytes' ([ordered]@{
                ok = Get-Prop $writeBlocked 'ok'; reason = Get-Prop $writeBlocked 'reason'
                before = $writeBlockedHash; after = $afterBlockedHash }) (
                (Get-Prop $writeBlocked 'ok') -eq $false -and $writeBlockedHash -ceq $afterBlockedHash)
        }
    }
    $reader = Start-SseReader "A-STORE-1-$Label-fallback" 20 '/events?look=store001'
    try {
        $look = Wait-SseLook $reader { param($m) (Get-Prop $m 'id') -eq 'store001' } 10
        Add-Check "A-STORE-1.$Label.pillFallback" 'an id served from a whole-file failure receives the pill preset with missing=true' ([ordered]@{
            id = Get-Prop (Get-Prop $look 'data') 'id'; missing = Get-Prop (Get-Prop $look 'data') 'missing'
            theme = Get-Prop (Get-Prop (Get-Prop $look 'data') 'options') 'theme' }) (
            $look -and (Get-Prop $look.data 'missing') -eq $true -and
            (Get-Prop (Get-Prop $look.data 'options') 'theme') -eq 'pill')
    } finally { Stop-SseReader $reader }
    [pscustomobject]@{ store = $store; readOnly = $readOnly; reason = $reason; beforeHash = $beforeHash; afterHash = $afterHash }
}

function Test-StoreLookFx($Run) {
    $keys = @('backgroundBlur', 'playedBrightness', 'unplayedBrightness', 'backgroundBrightness')
    $vectors = @(
        @{ name = 'malicious'; raw = @('url(https://invalid.example/x)', '<img onerror=1>', 'calc(1)', 'NaN'); expected = @($null,$null,$null,$null) },
        @{ name = 'string'; raw = @('14','100','45','40'); expected = @($null,$null,$null,$null) },
        @{ name = 'boolean'; raw = @($true,$false,$true,$false); expected = @($null,$null,$null,$null) },
        @{ name = 'array'; raw = @(@(1),@(2),@(3),@(4)); expected = @($null,$null,$null,$null) },
        @{ name = 'object'; raw = @(@{v=1},@{v=2},@{v=3},@{v=4}); expected = @($null,$null,$null,$null) },
        @{ name = 'negative'; raw = @(-.1,-1,-5,-100); expected = @($null,$null,$null,$null) },
        @{ name = 'aboveRange'; raw = @(32.1,201,101,201); expected = @($null,$null,$null,$null) },
        @{ name = 'fractional'; raw = @(14.49,112.49,47.49,37.49); expected = @(14,110,45,35) },
        @{ name = 'tiesUp'; raw = @(14.5,112.5,47.5,37.5); expected = @(15,115,50,40) },
        @{ name = 'minimum'; raw = @(0,0,0,0); expected = @(0,0,0,0) },
        @{ name = 'maximum'; raw = @(32,200,100,200); expected = @(32,200,100,200) }
    )
    $chrome = $null
    try {
        if (Test-ChromeAvailable 'A-STORE-1.fx') { $chrome = Start-Chrome 'A-STORE-1-fx' }
        $index = 0
        foreach ($vector in $vectors) {
            [void] (Wait-OverlayStreams $Run 0 "fx-$($vector.name)-before")
            $index++; $id = 'fxs{0:D5}' -f $index
            $o = Get-ThemeDefaults 'card'
            for ($n = 0; $n -lt 4; $n++) { $o[$keys[$n]] = $vector.raw[$n] }
            $path = Write-ObsLooksFile $Run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @((New-ObsLook $id 'FX normalization' $o))))
            $hash = Get-Sha256 $path
            if ($chrome) {
                $chrome.Events.Clear()
                [void] (Invoke-Cdp $chrome 'Network.enable')
            }
            [void] (Send-ObsHookCommand $Run.Root 'command-obs-looks-reload')
            $reader = Start-SseReader "A-STORE-1-fx-$($vector.name)" 20 "/events?look=$id"
            try {
                $event = Wait-SseLook $reader { param($m) (Get-Prop $m 'id') -eq $id } 10
                $wire = Get-Prop (Get-Prop $event 'data') 'options'
                $wireOk = [bool] $event
                for ($n = 0; $n -lt 4; $n++) { $wireOk = $wireOk -and (Get-Prop $wire $keys[$n]) -ceq $vector.expected[$n] }
                Add-Check "A-STORE-1.fx.$($vector.name).wire" 'native file normalizes all four keys to null or snapped numbers (ties up)' (
                    [ordered]@{ raw = $vector.raw; expected = $vector.expected; wire = $wire }) $wireOk
                if ($chrome) {
                    [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$id")
                    $pagePoll = @{ last = $null; errors = [Collections.Generic.List[string]]::new() }
                    $page = Wait-For {
                        try {
                            $p = Get-LookFxProbe $chrome; $pagePoll.last = $p
                            if ((Get-PageField $p 'connection') -eq 'open' -and
                                (Get-Prop (Get-PageField $p 'look') 'id') -eq $id) { $p }
                        } catch { $pagePoll.errors.Add($_.Exception.Message) }
                    } 10 50
                    if (-not $page) {
                        [void] (Save-P2Evidence "store1-fx-$($vector.name)-page-timeout" ([ordered]@{
                            expectedId = $id; raw = $vector.raw; expected = $vector.expected; lastPage = $pagePoll.last
                            errors = $pagePoll.errors; server = Get-State $Run.Root "fx-$($vector.name)-timeout"
                            reader = @(Read-Sse $reader); cdpEventSource = $chrome.Events.ToArray(); targetId = $chrome.TargetId }))
                    }
                    $pageOk = [bool] $page
                    $resolvedKeys = @('blur','played','unplayed','background'); $defaults = Get-LookFxDefaults 'card'
                    for ($n = 0; $n -lt 4; $n++) {
                        $value = $vector.expected[$n]
                        $resolved = if ($null -eq $value) { $defaults[$keys[$n]] } else { $value }
                        $pageOk = $pageOk -and (Get-Prop (Get-PageField $page 'options') $keys[$n]) -ceq $value -and
                            (Get-Prop $page.fx.resolved $resolvedKeys[$n]) -eq $resolved
                    }
                    Add-Check "A-STORE-1.fx.$($vector.name).page" 'page nullable options and resolved defaults agree with independently expected native normalization' $page $pageOk
                    # Exercise the page trust boundary with original raw values, not only native-cleaned SSE.
                    $raw = ConvertTo-Json -InputObject $o -Compress -Depth 8
                    $r = Invoke-Cdp $chrome 'Runtime.evaluate' @{ expression = "({options:normalizeOptions($raw),resolved:effectsOf(normalizeOptions($raw))})"; returnByValue = $true }
                    $direct = Get-Prop (Get-Prop $r 'result') 'value'
                    $directOk = $null -ne $direct -and -not (Get-Prop $r 'exceptionDetails')
                    for ($n = 0; $n -lt 4; $n++) {
                        $value = $vector.expected[$n]; $resolved = if ($null -eq $value) { $defaults[$keys[$n]] } else { $value }
                        $directOk = $directOk -and (Get-Prop $direct.options $keys[$n]) -ceq $value -and
                            (Get-Prop $direct.resolved $resolvedKeys[$n]) -eq $resolved
                    }
                    Add-Check "A-STORE-1.fx.$($vector.name).pageBoundary" 'raw malicious/types/ranges/fractions independently normalize identically at the page boundary' $direct $directOk
                } else {
                    Add-Blocked "A-STORE-1.fx.$($vector.name).page" 'page nullable options and resolved defaults match native' 'Chrome unavailable'
                    Add-Blocked "A-STORE-1.fx.$($vector.name).pageBoundary" 'raw page trust-boundary normalization matches native' 'Chrome unavailable'
                }
                Add-Check "A-STORE-1.fx.$($vector.name).readOnlyBytes" 'loading and serving malformed FX never rewrite file bytes' (
                    [ordered]@{ before = $hash; after = Get-Sha256 $path }) ($hash -ceq (Get-Sha256 $path))
            } finally {
                Stop-SseReader $reader
                try {
                    $release = if ($chrome) { Reset-ChromeCasePage $chrome } else { $null }
                    $drained = Wait-OverlayStreams $Run 0 "fx-$($vector.name)-released"
                    $byLook = Get-Overlay $drained 'streamsByLook'
                    if ($null -eq $byLook -or [int] (Get-Prop $byLook $id) -ne 0) {
                        throw "Prior FX vector $id did not drain from by-look stream counts."
                    }
                    [void] (Save-P2Evidence "store1-fx-$($vector.name)-release" @{ target = $release; server = $drained })
                } catch {
                    $reason = $_.Exception.Message
                    $evidencePath = Save-P2Evidence "store1-fx-$($vector.name)-release-timeout" ([ordered]@{
                        reason = $reason; priorId = $id; server = Get-State $Run.Root "fx-$($vector.name)-release-timeout"
                        reader = @(Read-Sse $reader); cdpEventSource = $(if ($chrome) { $chrome.Events.ToArray() } else { @() }) })
                    throw "$reason Evidence: $evidencePath"
                }
            }
        }
    } finally { Stop-Chrome $chrome }
}

function Test-AStore1 {
    $empty = ConvertTo-ObsLooksJson (New-ObsLooksDocument @())
    $run = Start-OverlayRun 'A-STORE-1' @{} 'PlayingLong' -NoReader -LooksJson $empty
    try {
        [void] (Wait-BenchReady $run.Root)
        Test-StoreLookFx $run
        $badFiles = @(
            @{ name = 'oversize'; bytes = [byte[]]::new(65537) },
            @{ name = 'invalidUtf8'; bytes = [byte[]] @(0xC3, 0x28) },
            @{ name = 'malformed'; bytes = [Text.Encoding]::UTF8.GetBytes('{ "version": 1, ') },
            @{ name = 'depth9'; bytes = [Text.Encoding]::UTF8.GetBytes('{"version":1,"looks":[],"retired":[],"x":{"a":{"b":{"c":{"d":{"e":{"f":{"g":{"h":1}}}}}}}}}') },
            @{ name = 'rootArray'; bytes = [Text.Encoding]::UTF8.GetBytes('[]') },
            @{ name = 'versionZero'; bytes = [Text.Encoding]::UTF8.GetBytes('{"version":0,"looks":[],"retired":[]}') },
            @{ name = 'versionString'; bytes = [Text.Encoding]::UTF8.GetBytes('{"version":"1","looks":[],"retired":[]}') },
            @{ name = 'versionMissing'; bytes = [Text.Encoding]::UTF8.GetBytes('{"looks":[],"retired":[]}') },
            @{ name = 'looksObject'; bytes = [Text.Encoding]::UTF8.GetBytes('{"version":1,"looks":{},"retired":[]}') },
            @{ name = 'retiredObject'; bytes = [Text.Encoding]::UTF8.GetBytes('{"version":1,"looks":[],"retired":{}}') }
        )
        foreach ($entry in $badFiles) { [void] (Test-StoreReadOnlyCase $run.Root $entry.name $entry.bytes) }
        $aclBytes = [Text.Encoding]::UTF8.GetBytes('{"version":1,"looks":[],"retired":[]}')
        [void] (Test-StoreReadOnlyCase $run.Root 'acl' $aclBytes -DenyRead)

        # A UTF-8 BOM is accepted; malformed whole-file input above stays byte-for-byte untouched.
        $validEmpty = [Text.Encoding]::UTF8.GetBytes((ConvertTo-ObsLooksJson (New-ObsLooksDocument @())))
        $bom = [byte[]]::new($validEmpty.Length + 3)
        $bom[0] = 0xEF; $bom[1] = 0xBB; $bom[2] = 0xBF
        [Array]::Copy($validEmpty, 0, $bom, 3, $validEmpty.Length)
        [IO.File]::WriteAllBytes((Join-Path $run.Root 'data/obs-looks.json'), $bom)
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $bomState = Get-State $run.Root 'bom'
        $bomStore = Get-Overlay $bomState 'looks'
        Add-Check 'A-STORE-1.bomAccepted' 'UTF-8 BOM is stripped and an otherwise valid file is writable/empty' ([ordered]@{
            readOnly = Get-Prop $bomStore 'readOnly'; reason = Get-Prop $bomStore 'reason'; count = Get-Prop $bomStore 'count' }) (
            (Get-Prop $bomStore 'readOnly') -eq $false -and (Get-Prop $bomStore 'count') -eq 0)

        $unknownOptions = New-DefaultPillOptions
        $unknownOptions['theme'] = 'PILL'; $unknownOptions['scale'] = 'wrong'; $unknownOptions['width'] = 401
        $unknownOptions['align'] = 'CENTER'; $unknownOptions['colours'] = 'CUSTOM'; $unknownOptions['text'] = '#FF00AA'
        $unknownOptions['background'] = 'bad'; $unknownOptions['backgroundOpacity'] = 101; $unknownOptions['accent'] = 7
        $unknownOptions['textShadow'] = 'false'; $unknownOptions['showArtist'] = $false; $unknownOptions['showProgress'] = 1
        $unknownOptions['showTimes'] = $null; $unknownOptions['paused'] = 'Dim'; $unknownOptions['showAnimation'] = 'slide-Up'
        $unknownOptions['hideAnimation'] = 'slide-down'; $unknownOptions['font'] = 7; $unknownOptions['ignoredFutureField'] = 'not copied'
        $outOfRangeOptions = New-DefaultPillOptions; $outOfRangeOptions['scale'] = 999; $outOfRangeOptions['width'] = 100
        $outOfRangeOptions['font'] = ('F' * 65) -join ''
        $outOfRange = New-ObsLook 'rng00001' 'Range defaults' $outOfRangeOptions
        $controlFontOptions = New-DefaultPillOptions; $controlFontOptions['font'] = "Bad$([char] 1)font"
        $controlFont = New-ObsLook 'fontctl1' 'Control font' $controlFontOptions
        $normalized = New-ObsLook 'norm0001' 'Normalized' $unknownOptions
        $missingOptionsLook = New-ObsLook 'miss0001' 'Missing fields use defaults' ([ordered]@{})
        $doc = New-ObsLooksDocument @($normalized, $missingOptionsLook, $outOfRange, $controlFont) @() 2
        [IO.File]::WriteAllText((Join-Path $run.Root 'data/obs-looks.json'), (ConvertTo-ObsLooksJson $doc), [Text.UTF8Encoding]::new($false))
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $futureReader = Start-SseReader 'A-STORE-1-version2' 20 '/events?look=norm0001'
        try {
            $futureLook = Wait-SseLook $futureReader { param($m) (Get-Prop $m 'id') -eq 'norm0001' } 10
            $futureOptions = Get-Prop (Get-Prop $futureLook 'data') 'options'
            $futureStore = Get-Overlay (Get-State $run.Root 'futureVersion') 'looks'
            Add-Check 'A-STORE-1.version2ReadOnlyAndServed' 'version 2 is read-only as newer data, but a valid record is served with known fields normalized and unknown fields ignored' ([ordered]@{
                readOnly = Get-Prop $futureStore 'readOnly'; reason = Get-Prop $futureStore 'reason'; theme = Get-Prop $futureOptions 'theme'
                scale = Get-Prop $futureOptions 'scale'; width = Get-Prop $futureOptions 'width'; align = Get-Prop $futureOptions 'align'
                colours = Get-Prop $futureOptions 'colours'; text = Get-Prop $futureOptions 'text'; background = Get-Prop $futureOptions 'background'
                backgroundOpacity = Get-Prop $futureOptions 'backgroundOpacity'; accent = Get-Prop $futureOptions 'accent'
                textShadow = Get-Prop $futureOptions 'textShadow'; showArtist = Get-Prop $futureOptions 'showArtist'
                showProgress = Get-Prop $futureOptions 'showProgress'; showTimes = Get-Prop $futureOptions 'showTimes'
                paused = Get-Prop $futureOptions 'paused'; showAnimation = Get-Prop $futureOptions 'showAnimation'
                hideAnimation = Get-Prop $futureOptions 'hideAnimation'; font = Get-Prop $futureOptions 'font'
                unknown = Get-Prop $futureOptions 'ignoredFutureField' }) (
                $futureLook -and (Get-Prop $futureStore 'readOnly') -eq $true -and
                (Get-Prop $futureOptions 'theme') -eq 'pill' -and (Get-Prop $futureOptions 'scale') -eq 100 -and
                (Get-Prop $futureOptions 'width') -eq 400 -and (Get-Prop $futureOptions 'text') -ceq '#ff00aa' -and
                (Get-Prop $futureOptions 'align') -eq 'center' -and (Get-Prop $futureOptions 'colours') -eq 'auto' -and
                (Get-Prop $futureOptions 'background') -ceq '#202020' -and (Get-Prop $futureOptions 'backgroundOpacity') -eq 100 -and
                (Get-Prop $futureOptions 'accent') -ceq '#8a8a95' -and (Get-Prop $futureOptions 'textShadow') -eq $true -and
                (Get-Prop $futureOptions 'showArtist') -eq $false -and (Get-Prop $futureOptions 'showProgress') -eq $true -and
                (Get-Prop $futureOptions 'showTimes') -eq $true -and (Get-Prop $futureOptions 'paused') -eq 'hide' -and
                (Get-Prop $futureOptions 'showAnimation') -eq 'slide-up' -and (Get-Prop $futureOptions 'hideAnimation') -eq 'slide-down' -and
                $null -eq (Get-Prop $futureOptions 'font') -and $null -eq (Get-Prop $futureOptions 'ignoredFutureField'))
        } finally { Stop-SseReader $futureReader }
        $missingReader = Start-SseReader 'A-STORE-1-missing-options' 20 '/events?look=miss0001'
        try {
            $missingOptionLook = Wait-SseLook $missingReader { param($m) (Get-Prop $m 'id') -eq 'miss0001' } 10
            $missingOptions = Get-Prop (Get-Prop $missingOptionLook 'data') 'options'
            Add-Check 'A-STORE-1.missingOptionDefaults' 'missing option fields receive schema defaults' ([ordered]@{
                theme = Get-Prop $missingOptions 'theme'; width = Get-Prop $missingOptions 'width'; scale = Get-Prop $missingOptions 'scale'
                text = Get-Prop $missingOptions 'text'; showProgress = Get-Prop $missingOptions 'showProgress'
                showArtist = Get-Prop $missingOptions 'showArtist'; textShadow = Get-Prop $missingOptions 'textShadow' }) (
                $missingOptionLook -and (Get-Prop $missingOptions 'theme') -eq 'pill' -and
                (Get-Prop $missingOptions 'width') -eq 400 -and (Get-Prop $missingOptions 'scale') -eq 100 -and
                (Get-Prop $missingOptions 'text') -ceq '#ffffff' -and
                (Get-Prop $missingOptions 'showProgress') -eq $true -and
                (Get-Prop $missingOptions 'showArtist') -eq $true -and (Get-Prop $missingOptions 'textShadow') -eq $true)
        } finally { Stop-SseReader $missingReader }
        $rangeReader = Start-SseReader 'A-STORE-1-out-of-range' 20 '/events?look=rng00001'
        $controlReader = Start-SseReader 'A-STORE-1-control-font' 20 '/events?look=fontctl1'
        try {
            $rangeLook = Wait-SseLook $rangeReader { param($m) (Get-Prop $m 'id') -eq 'rng00001' } 10
            $controlLook = Wait-SseLook $controlReader { param($m) (Get-Prop $m 'id') -eq 'fontctl1' } 10
            $rangeOptions = Get-Prop (Get-Prop $rangeLook 'data') 'options'
            $controlOptions = Get-Prop (Get-Prop $controlLook 'data') 'options'
            Add-Check 'A-STORE-1.outOfRangeAndFontValidation' 'scale/width outside dependent ranges use effective defaults; fonts over 64 units or containing controls normalize to null' ([ordered]@{
                scale = Get-Prop $rangeOptions 'scale'; width = Get-Prop $rangeOptions 'width'; longFont = Get-Prop $rangeOptions 'font'
                controlFont = Get-Prop $controlOptions 'font' }) (
                $rangeLook -and $controlLook -and (Get-Prop $rangeOptions 'scale') -eq 100 -and
                (Get-Prop $rangeOptions 'width') -eq 400 -and $null -eq (Get-Prop $rangeOptions 'font') -and
                $null -eq (Get-Prop $controlOptions 'font'))
        } finally { Stop-SseReader $rangeReader; Stop-SseReader $controlReader }

        # A v1 normalization result remains stable after the production serializer writes and re-reads it.
        [IO.File]::WriteAllText((Join-Path $run.Root 'data/obs-looks.json'), (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($normalized))), [Text.UTF8Encoding]::new($false))
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $normReader = Start-SseReader 'A-STORE-1-normalize-once' 20 '/events?look=norm0001'
        $normFirst = Wait-SseLook $normReader { param($m) (Get-Prop $m 'id') -eq 'norm0001' } 10
        $normFirstOptions = Get-Prop (Get-Prop $normFirst 'data') 'options'
        $normCommit = Invoke-ObsLookCommit $run.Root 600 @{ action = 'create'; name = 'Idempotence check'; options = (New-DefaultPillOptions) }
        $writtenOptions = (Read-ObsLooksFile $run.Root).looks | Where-Object { $_.id -eq 'norm0001' } | Select-Object -First 1
        $savedText = [IO.File]::ReadAllText((Join-Path $run.Root 'data/obs-looks.json'))
        Add-Check 'A-STORE-1.fx.explicitNullSave' 'successful Save appends the four explicit nullable FX keys after hideAnimation; load remains read-only' $writtenOptions (
            $savedText -match '"hideAnimation"\s*:\s*"[^"]+"\s*,\s*"backgroundBlur"\s*:\s*null\s*,\s*"playedBrightness"\s*:\s*null\s*,\s*"unplayedBrightness"\s*:\s*null\s*,\s*"backgroundBrightness"\s*:\s*null')
        Stop-SseReader $normReader
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $normAgainReader = Start-SseReader 'A-STORE-1-normalize-twice' 20 '/events?look=norm0001'
        $normAgain = Wait-SseLook $normAgainReader { param($m) (Get-Prop $m 'id') -eq 'norm0001' } 10
        $normAgainOptions = Get-Prop (Get-Prop $normAgain 'data') 'options'
        $diskOptions = Get-Prop $writtenOptions 'options'
        Add-Check 'A-STORE-1.normalizeIdempotent' 'production write/reload preserves the first normalized option set (Normalize(Normalize(x)) == Normalize(x))' ([ordered]@{
            commit = Get-Prop $normCommit 'ok'; first = $normFirstOptions; disk = $diskOptions; reloaded = $normAgainOptions }) (
            (Get-Prop $normCommit 'ok') -eq $true -and $normFirst -and $normAgain -and
            (ConvertTo-Json -InputObject $normFirstOptions -Compress -Depth 8) -ceq
            (ConvertTo-Json -InputObject $diskOptions -Compress -Depth 8) -and
            (ConvertTo-Json -InputObject $normFirstOptions -Compress -Depth 8) -ceq
            (ConvertTo-Json -InputObject $normAgainOptions -Compress -Depth 8))
        Stop-SseReader $normAgainReader

        $seventeen = [Collections.Generic.List[object]]::new()
        for ($i = 1; $i -le 17; $i++) { $seventeen.Add((New-ObsLook ('look{0:D4}' -f $i) "Look $i" (New-DefaultPillOptions))) }
        [IO.File]::WriteAllText((Join-Path $run.Root 'data/obs-looks.json'), (ConvertTo-ObsLooksJson (New-ObsLooksDocument $seventeen.ToArray())), [Text.UTF8Encoding]::new($false))
        $quarantineHashBefore = Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json')
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $quarantine = Get-Overlay (Get-State $run.Root 'quarantine17') 'looks'
        $quarantineHashAfter = Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json')
        $quarantineReader = Start-SseReader 'A-STORE-1-quarantine17' 20 '/events?look=look0017'
        $servedReader = Start-SseReader 'A-STORE-1-served16' 20 '/events?look=look0016'
        try {
            $excessLook = Wait-SseLook $quarantineReader { param($m) (Get-Prop $m 'id') -eq 'look0017' } 10
            $servedLook = Wait-SseLook $servedReader { param($m) (Get-Prop $m 'id') -eq 'look0016' } 10
            Add-Check 'A-STORE-1.seventeenQuarantined' '17 valid records leave the first 16 served; the excess record is quarantined, read-only and file bytes untouched' ([ordered]@{
                count = Get-Prop $quarantine 'count'; readOnly = Get-Prop $quarantine 'readOnly'; reason = Get-Prop $quarantine 'reason'
                excessMissing = Get-Prop $excessLook.data 'missing'; first16Missing = Get-Prop $servedLook.data 'missing'
                hashBefore = $quarantineHashBefore; hashAfter = $quarantineHashAfter }) (
                (Get-Prop $quarantine 'count') -eq 16 -and (Get-Prop $quarantine 'readOnly') -eq $true -and
                -not [string]::IsNullOrWhiteSpace([string] (Get-Prop $quarantine 'reason')) -and
                $excessLook -and (Get-Prop $excessLook.data 'missing') -eq $true -and
                $servedLook -and (Get-Prop $servedLook.data 'missing') -eq $false -and $quarantineHashBefore -ceq $quarantineHashAfter)
        } finally { Stop-SseReader $quarantineReader; Stop-SseReader $servedReader }

        $duplicateFirst = New-DefaultPillOptions; $duplicateFirst['width'] = 320
        $duplicateSecond = New-DefaultPillOptions; $duplicateSecond['width'] = 800
        $invalidName = "control$([char] 1)name"
        $separatorName = "bad$([char] 0x2028)name"
        $maliciousName = '<img src=x onerror=alert(1)>'
        $records = @(
            (New-ObsLook 'dupe0001' 'first record' $duplicateFirst),
            (New-ObsLook 'dupe0001' 'second record' $duplicateSecond),
            (New-ObsLook 'good0001' $invalidName (New-DefaultPillOptions)),
            (New-ObsLook 'good0002' $separatorName (New-DefaultPillOptions)),
            (New-ObsLook 'good0003' $maliciousName (New-DefaultPillOptions)),
            (New-ObsLook 'tomb0001' 'Active tombstone' (New-DefaultPillOptions)),
            [ordered]@{ id = 'bad'; name = 'Bad id'; options = (New-DefaultPillOptions) }
        )
        [IO.File]::WriteAllText((Join-Path $run.Root 'data/obs-looks.json'), (ConvertTo-ObsLooksJson (New-ObsLooksDocument $records @('tomb0001', 'tomb0001', 'BAD00001'))), [Text.UTF8Encoding]::new($false))
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $dedupe = Start-SseReader 'A-STORE-1-duplicate' 20 '/events?look=dupe0001'
        $literal = Start-SseReader 'A-STORE-1-malicious-name' 20 '/events?look=good0003'
        try {
            $first = Wait-SseLook $dedupe { param($m) (Get-Prop $m 'id') -eq 'dupe0001' } 10
            $literalLook = Wait-SseLook $literal { param($m) (Get-Prop $m 'id') -eq 'good0003' } 10
            $eventsWire = Read-SseRaw $literal
            $state = Get-Overlay (Get-State $run.Root 'normalizedRecords') 'looks'
            $nameRecord = (Read-ObsLooksFile $run.Root).looks | Where-Object { $_.id -eq 'good0003' } | Select-Object -First 1
            Add-Check 'A-STORE-1.duplicatesAndNames' 'first duplicate id wins; control/separator names and invalid ids are skipped; malicious name stays literal; retired ids dedupe/filter' ([ordered]@{
                firstWidth = Get-Prop (Get-Prop (Get-Prop $first 'data') 'options') 'width'; count = Get-Prop $state 'count'
                literalNameInSse = $eventsWire.Contains($maliciousName); storedName = $nameRecord.name }) (
                $first -and (Get-Prop (Get-Prop $first.data 'options') 'width') -eq 320 -and
                $literalLook -and -not $eventsWire.Contains($maliciousName) -and
                $nameRecord.name -ceq $maliciousName -and (Get-Prop $state 'count') -eq 3)
        } finally { Stop-SseReader $dedupe; Stop-SseReader $literal }

        $retiredWrite = Invoke-ObsLookCommit $run.Root 80 @{ action = 'create'; name = 'Normalize retired'; options = (New-DefaultPillOptions) }
        $retiredDocument = Read-ObsLooksFile $run.Root
        $retiredIds = @($retiredDocument.retired)
        Add-Check 'A-STORE-1.retiredNormalization' 'retired ids are grammar-checked and deduplicated; an active id wins its intersection with retired' ([ordered]@{
            save = Get-Prop $retiredWrite 'ok'; retired = $retiredIds
            active = @($retiredDocument.looks | ForEach-Object { $_.id }) }) (
            (Get-Prop $retiredWrite 'ok') -eq $true -and
            @($retiredIds | Select-Object -Unique).Count -eq $retiredIds.Count -and
            @($retiredIds | Where-Object { $_ -cnotmatch '^[a-z0-9]{8}$' }).Count -eq 0 -and
            'tomb0001' -in @($retiredDocument.looks | ForEach-Object { $_.id }) -and 'tomb0001' -notin $retiredIds)
        # Font injection seam: forced available must still form exactly one quoted family token; without it, use only the fixed stack.
        if (Test-ChromeAvailable 'A-STORE-1') {
            $fontName = 'Bad "family\); url(evil)'
            $fontOptions = New-DefaultPillOptions; $fontOptions['font'] = $fontName
            $fontLook = New-ObsLook 'font0001' 'Font escape' $fontOptions
            $fontJson = ConvertTo-ObsLooksJson (New-ObsLooksDocument @($fontLook))
            [IO.File]::WriteAllText((Join-Path $run.Root 'data/obs-looks.json'), $fontJson, [Text.UTF8Encoding]::new($false))
            [void] (Send-ObsHookCommand $run.Root 'command-obs-font-force-available' $fontName)
            [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
            $chrome = Start-Chrome 'A-STORE-1-font'
            try {
                [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=font0001")
                $fontPage = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'connection') -eq 'open') { $p } } 15 100
                $fontVar = [string] (Get-Prop (Get-Prop $fontPage 'css') 'fontVar')
                $escapedName = '"' + $fontName.Replace('\', '\\').Replace('"', '\"') + '"'
                $expectedPrefix = $escapedName + ', "Segoe UI Variable Text", "Segoe UI", Arial, sans-serif'
                Add-Check 'A-STORE-1.fontEscapeForced' 'command-obs-font-force-available permits a safe single CSS string token with quote/backslash escaping' ([ordered]@{
                    fontAvailable = Get-Prop (Get-Prop $fontPage 's') 'fontAvailable'; fontVar = $fontVar }) (
                    $fontPage -and (Get-Prop $fontPage.s 'fontAvailable') -eq $true -and $fontVar -ceq $expectedPrefix)
                Stop-Chrome $chrome; $chrome = $null
                [void] (Send-ObsHookCommand $run.Root 'command-obs-font-force-available' 'different-test-font')
                [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
                $chrome = Start-Chrome 'A-STORE-1-font-no-seam'
                [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=font0001")
                $fallback = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'connection') -eq 'open' -and
                    (Get-Prop (Get-Prop $p 's') 'fontAvailable') -eq $false) { $p } } 15 100
                Add-Check 'A-STORE-1.fontEscapeNoSeam' 'without the exact availability seam, saved value stays but page selects only the fixed fallback stack' (
                    [ordered]@{ fontAvailable = Get-Prop (Get-Prop $fallback 's') 'fontAvailable'; fontVar = Get-Prop (Get-Prop $fallback 'css') 'fontVar' }) (
                    $fallback -and (Get-Prop $fallback.s 'fontAvailable') -eq $false -and
                    [string] (Get-Prop $fallback.css 'fontVar') -ceq '"Segoe UI Variable Text", "Segoe UI", Arial, sans-serif')
            } finally { Stop-Chrome $chrome }
        } else { Add-Blocked 'A-STORE-1.fontEscape' 'font seam escaping with and without forced availability' 'Chrome is not installed; CSSOM parsing requires CDP' }

        # Durable mutation contract; input/result JSON lives under data/discord-bench and never reaches release code.
        [IO.File]::WriteAllText((Join-Path $run.Root 'data/obs-looks.json'), (ConvertTo-ObsLooksJson (New-ObsLooksDocument @())), [Text.UTF8Encoding]::new($false))
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $settingsHash = Get-Sha256 (Join-Path $run.Root 'data/settings.json')
        $cycle = Invoke-ObsLookCommit $run.Root 100 @{ action = 'cycle'; count = 100; name = 'Cycle'; options = (New-DefaultPillOptions) }
        $cycleDocument = Read-ObsLooksFile $run.Root
        $cycleIds = @($cycle.ids)
        Add-Check 'A-STORE-1.commitCycles100' '100 create/delete cycles write 100 distinct tombstones; result includes success/reason/ids/revision' ([ordered]@{
            ok = Get-Prop $cycle 'ok'; reason = Get-Prop $cycle 'reason'; ids = $cycleIds.Count; distinct = @($cycleIds | Select-Object -Unique).Count
            retired = @($cycleDocument.retired).Count; revision = Get-Prop $cycle 'revision' }) (
            (Get-Prop $cycle 'ok') -eq $true -and $cycleIds.Count -eq 100 -and @($cycleIds | Select-Object -Unique).Count -eq 100 -and
            @($cycleDocument.retired).Count -eq 100 -and [int] (Get-Prop $cycle 'revision') -ge 200)
        $collision = Invoke-ObsLookCommit $run.Root 101 @{ action = 'create'; name = 'Collision retry'; options = (New-DefaultPillOptions)
            testIdCandidates = @([string] $cycleIds[0], 'newid001') }
        Add-Check 'A-STORE-1.forcedCollisionRetry' 'an id candidate already in retired is rejected and the next valid candidate is used' ([ordered]@{
            ok = Get-Prop $collision 'ok'; id = @($collision.ids | Select-Object -First 1); retiredCollision = $cycleIds[0] }) (
            (Get-Prop $collision 'ok') -eq $true -and @($collision.ids).Count -eq 1 -and
            @($collision.ids)[0] -ceq 'newid001' -and @($collision.ids)[0] -cne $cycleIds[0])
        $deleteCollision = Invoke-ObsLookCommit $run.Root 102 @{ action = 'delete'; id = 'newid001' }
        Add-Check 'A-STORE-1.deletedIdNotReused' 'deleted look id remains tombstoned and is never reused' ([ordered]@{
            deleted = Get-Prop $deleteCollision 'ok'; retired = @((Read-ObsLooksFile $run.Root).retired).Count }) (
            (Get-Prop $deleteCollision 'ok') -eq $true -and 'newid001' -in @((Read-ObsLooksFile $run.Root).retired))
        Add-Check 'A-STORE-1.settingsUnchangedByCommit' 'settings.json hash is unchanged across looks mutations' (
            [ordered]@{ before = $settingsHash; after = Get-Sha256 (Join-Path $run.Root 'data/settings.json') }) (
            $settingsHash -ceq (Get-Sha256 (Join-Path $run.Root 'data/settings.json')))

        # Faults before atomic replacement leave the old file and stream view intact.
        $stableHash = Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json')
        [void] (Send-ObsHookCommand $run.Root 'command-obs-store-fault' 'replace')
        $fault = Invoke-ObsLookCommit $run.Root 103 @{ action = 'create'; name = 'Faulted'; options = (New-DefaultPillOptions) }
        $faultHash = Get-Sha256 (Join-Path $run.Root 'data/obs-looks.json')
        Add-Check 'A-STORE-1.replaceFaultAtomic' 'replace fault reports failure and leaves the old file byte-for-byte unchanged' ([ordered]@{
            ok = Get-Prop $fault 'ok'; reason = Get-Prop $fault 'reason'; before = $stableHash; after = $faultHash }) (
            (Get-Prop $fault 'ok') -eq $false -and $stableHash -ceq $faultHash)
        $tmpPath = (Join-Path $run.Root 'data/obs-looks.json') + '.tmp'
        [IO.File]::WriteAllText($tmpPath, 'stale tmp is ignored', [Text.UTF8Encoding]::new($false))
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $ignoredTmp = Get-Overlay (Get-State $run.Root 'staleTmp') 'looks'
        $save = Invoke-ObsLookCommit $run.Root 104 @{ action = 'create'; name = 'After tmp'; options = (New-DefaultPillOptions) }
        Add-Check 'A-STORE-1.staleTmpAndSuccessfulWrite' 'stale .tmp is ignored on reload and removed after the next successful production write' ([ordered]@{
            count = Get-Prop $ignoredTmp 'count'; saved = Get-Prop $save 'ok'; tmpExists = Test-Path -LiteralPath $tmpPath }) (
            (Get-Prop $ignoredTmp 'readOnly') -eq $false -and (Get-Prop $save 'ok') -eq $true -and -not (Test-Path -LiteralPath $tmpPath))
        $tmpLookId = @($save.ids | Select-Object -First 1)[0]
        $clearTmpLook = Invoke-ObsLookCommit $run.Root 105 @{ action = 'delete'; id = $tmpLookId }
        Add-Check 'A-STORE-1.tmpFixtureCleanup' 'temporary successful-write look removed before cap fixture is built' $clearTmpLook (Get-Prop $clearTmpLook 'ok')

        # Sixteen maximal records round-trip through the production serializer, reopen and reload.
        $maxName = ('界' * 40) -join ''; $maxFont = ('F' * 64) -join ''
        [void] (Send-ObsHookCommand $run.Root 'command-obs-font-force-available' $maxFont)
        $maxOptions = New-DefaultPillOptions; $maxOptions['font'] = $maxFont
        $maxOptions['text'] = '#ABCDEF'; $maxOptions['background'] = '#123456'; $maxOptions['accent'] = '#654321'
        $maxOptions['colours'] = 'custom'; $maxOptions['scale'] = 200; $maxOptions['width'] = 640
        $maxOptions['showArtist'] = $false; $maxOptions['showProgress'] = $true; $maxOptions['showTimes'] = $false
        $maxOptions['paused'] = 'dim'; $maxOptions['showAnimation'] = 'slide-left'; $maxOptions['hideAnimation'] = 'slide-down'
        $maxOk = 0
        for ($i = 1; $i -le 16; $i++) {
            $result = Invoke-ObsLookCommit $run.Root (200 + $i) @{ action = 'create'; name = $maxName; options = $maxOptions }
            if ((Get-Prop $result 'ok') -eq $true) { $maxOk++ } else { break }
        }
        $maxFile = Join-Path $run.Root 'data/obs-looks.json'
        $maxDoc = Read-ObsLooksFile $run.Root
        $maxBytes = (Get-Item -LiteralPath $maxFile).Length
        Add-Check 'A-STORE-1.maximal16RoundTrip' '16 maximal records (40 UTF-16-unit names, 64-unit installed fonts, all options) fit and round-trip under the 64 KiB cap' ([ordered]@{
            created = $maxOk; fileBytes = $maxBytes; names = @($maxDoc.looks | ForEach-Object { $_.name.Length } | Select-Object -Unique)
            fonts = @($maxDoc.looks | ForEach-Object { $_.options.font.Length } | Select-Object -Unique) }) (
            $maxOk -eq 16 -and $maxDoc.looks.Count -eq 16 -and $maxBytes -le 65536 -and
            @($maxDoc.looks | Where-Object { $_.name.Length -ne 40 -or $_.options.font.Length -ne 64 }).Count -eq 0)
        Stop-App $run.App $run.Root
        $run.App = Start-App $run.Root @{ NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'PlayingLong'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
        [void] (Wait-BenchReady $run.Root)
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $reopened = Get-Overlay (Get-State $run.Root 'maxReopen') 'looks'
        Add-Check 'A-STORE-1.maximal16Reopen' 'reopened app reloads all 16 records with no read-only state' ([ordered]@{
            count = Get-Prop $reopened 'count'; readOnly = Get-Prop $reopened 'readOnly'; fileHash = Get-Prop $reopened 'fileHash' }) (
            (Get-Prop $reopened 'count') -eq 16 -and (Get-Prop $reopened 'readOnly') -eq $false)

        # Keep 16 live records while production-serializer cycles increase the retired-id list to its size boundary.
        $growth = Invoke-ObsLookCommit $run.Root 5000 @{ action = 'cycle'; count = 5000; name = $maxName; options = $maxOptions }
        $growthDocument = Read-ObsLooksFile $run.Root
        Add-Check 'A-STORE-1.capGrowthStopsAtFirstLimit' 'tombstone cycles stop at the first >64 KiB production-serializer write' ([ordered]@{
            ok = Get-Prop $growth 'ok'; reason = Get-Prop $growth 'reason'; fileBytes = (Get-Item -LiteralPath $maxFile).Length
            createdIds = @($growth.ids).Count; remainingLooks = $growthDocument.looks.Count; retired = $growthDocument.retired.Count }) (
            (Get-Prop $growth 'ok') -eq $false -and [string] (Get-Prop $growth 'reason') -match 'too large|64 KiB' -and
            (Get-Item -LiteralPath $maxFile).Length -le 65536 -and $growthDocument.looks.Count -in @(15, 16))
        $capFailure = $null; $capBefore = $null; $capAfter = $null; $sequence = 6000
        for ($attempt = 0; $attempt -lt 32 -and -not $capFailure; $attempt++) {
            $current = Read-ObsLooksFile $run.Root
            $before = Get-Sha256 $maxFile
            if ($current.looks.Count -lt 16) { $mutation = @{ action = 'create'; name = $maxName; options = $maxOptions } }
            else { $mutation = @{ action = 'delete'; id = $current.looks[0].id } }
            $result = Invoke-ObsLookCommit $run.Root $sequence $mutation; $sequence++
            if ((Get-Prop $result 'ok') -ne $true) {
                $capFailure = $result; $capBefore = $before; $capAfter = Get-Sha256 $maxFile
            }
        }
        Add-Check 'A-STORE-1.capBoundaryRejectAtomic' 'the first rejected mutation reports the cap error and leaves the file hash unchanged' ([ordered]@{
            ok = Get-Prop $capFailure 'ok'; reason = Get-Prop $capFailure 'reason'; beforeHash = $capBefore; afterHash = $capAfter }) (
            $capFailure -and (Get-Prop $capFailure 'ok') -eq $false -and
            [string] (Get-Prop $capFailure 'reason') -match 'too large|64 KiB' -and $capBefore -ceq $capAfter)
        $postCapDocument = Read-ObsLooksFile $run.Root
        $expectedPostCapCount = $postCapDocument.looks.Count
        Stop-App $run.App $run.Root
        $run.App = Start-App $run.Root @{ NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'PlayingLong'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
        [void] (Wait-BenchReady $run.Root)
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $afterCap = Get-Overlay (Get-State $run.Root 'capReopen') 'looks'
        Add-Check 'A-STORE-1.capFailureReopen' 'after the rejected mutation, reopening loads the last complete file and remains writable' ([ordered]@{
            count = Get-Prop $afterCap 'count'; expected = $expectedPostCapCount; readOnly = Get-Prop $afterCap 'readOnly'; fileHash = Get-Prop $afterCap 'fileHash' }) (
            (Get-Prop $afterCap 'count') -eq $expectedPostCapCount -and (Get-Prop $afterCap 'readOnly') -eq $false -and
            (Get-Prop $afterCap 'fileHash') -ceq $capAfter)

        $olderSettingsHash = Get-Sha256 (Join-Path $run.Root 'data/settings.json')
        Write-Settings $run.Root @{ ObsOverlay = $true }
        $looksHashAfterOlderSettings = Get-Sha256 $maxFile
        Add-Check 'A-STORE-1.downgradeLeavesLooks' 'rewriting old-format settings.json leaves the separate looks file intact' ([ordered]@{
            settingsChanged = $olderSettingsHash -cne (Get-Sha256 (Join-Path $run.Root 'data/settings.json')); looks = $looksHashAfterOlderSettings }) (
            $looksHashAfterOlderSettings -ceq $capAfter -and $olderSettingsHash -cne (Get-Sha256 (Join-Path $run.Root 'data/settings.json')))
    } finally { Stop-OverlayRun $run }
    $scenarioResults['A-STORE-1'] = [ordered]@{ root = [IO.Path]::GetRelativePath($repo, $run.Root); hookPayload = 'commit-<n>.json' }
}
function Test-ASampleDemand {
    foreach ($presence in @($false, $true)) {
        $name = if ($presence) { 'presence-on' } else { 'presence-off' }
        $settings = @{ DiscordPresence = $presence }
        $run = Start-OverlayRun "A-SAMPLE-demand-$name" $settings 'Playing' -NoReader
        $server = $null; $reader = $null
        try {
            if ($presence) { $server = Start-FakeServer "A-SAMPLE-$name" }
            [void] (Wait-BenchReady $run.Root)
            $reader = Start-SseReader "A-SAMPLE-demand-$name" 30 '/events?sample=playing'
            [void] (Wait-SseData $reader { param($d) (Get-Prop $d 'state') -eq 'playing' } 15)
            $start = Get-State $run.Root "demand-$name-start"
            Start-Sleep -Seconds 10
            $end = Get-State $run.Root "demand-$name-end"
            $reads = Get-ReadStats $start $end
            $real = Get-Overlay $end 'realStreams'; $samples = Get-Overlay $end 'sampleStreams'
            Add-Check "A-SAMPLE.demand.$name" 'a sample-only SSE stream exposes Sample/Open counts and causes zero Overlay reads with Presence on or off' ([ordered]@{
                realStreams = $real; sampleStreams = $samples; openStreams = Get-Overlay $end 'streams'; reads = $reads }) (
                $reads.overlay -eq 0 -and $real -eq 0 -and $samples -eq 1 -and (Get-Overlay $end 'streams') -eq 1)
        } finally {
            Stop-SseReader $reader
            if ($server) { Stop-FakeServer $server }
            Stop-OverlayRun $run
        }
    }
}

function Test-ASample {
    $sampleLookFile = Join-Path $fixtureDirectory 'looks-sample.json'
    $sampleLookDoc = Get-Content -Raw -LiteralPath $sampleLookFile | ConvertFrom-Json -Depth 16
    $saved = @($sampleLookDoc.looks)[0]
    $run = Start-OverlayRun 'A-SAMPLE-core' @{ ObsHidePaused = $true } 'AdFallback' -NoReader -LooksJson (
        ConvertTo-ObsLooksJson (New-ObsLooksDocument @($saved)))
    $allReaders = [Collections.Generic.List[object]]::new()
    $realPreview = $null; $realExtra = $null
    try {
        [void] (Wait-BenchReady $run.Root)
        [void] (Send-PreviewNonce $run.Root 'sample01')
        $draftOptions = New-DefaultPillOptions
        [void] (Send-DraftLook $run.Root (New-ObsLook 'draft' 'Sample draft' $draftOptions))
        $paths = [ordered]@{
            plain = '/events?sample=playing'; noart = '/events?sample=noart'; paused = '/events?sample=paused'
            draft = '/events?look=draft&pv=sample01&sample=playing'; real = '/events'
            missing = '/events?look=missing1'; saved = '/events?look=sampl001'
        }
        $readersByKind = [ordered]@{}
        foreach ($key in $paths.Keys) {
            $r = Start-SseReader "A-SAMPLE-$key" 30 $paths[$key]
            $allReaders.Add($r); $readersByKind[$key] = $r
        }
        $openEvents = [ordered]@{}
        foreach ($key in @('plain', 'noart', 'paused', 'draft')) { $openEvents[$key] = Wait-SseOpen $readersByKind[$key] 20 }
        $first = [ordered]@{
            plain = Wait-SseData $readersByKind['plain'] { param($d) (Get-Prop $d 'state') -eq 'playing' } 15
            noart = Wait-SseData $readersByKind['noart'] { param($d) (Get-Prop $d 'state') -eq 'playing' } 15
            paused = Wait-SseData $readersByKind['paused'] { param($d) (Get-Prop $d 'state') -eq 'paused' } 15
            draft = Wait-SseData $readersByKind['draft'] { param($d) (Get-Prop $d 'state') -eq 'playing' } 15
            real = Wait-SseData $readersByKind['real'] { param($d) (Get-Prop $d 'state') -eq 'playing' } 15
        }
        $playingValid = $first.plain -and (Get-Prop $first.plain.data 'title') -eq 'Sample song' -and
            (Get-Prop $first.plain.data 'artist') -eq 'Sample artist' -and (Get-Prop $first.plain.data 'artwork') -eq '/art/sample' -and
            (Get-Prop $first.plain.data 'duration') -eq 240 -and (Get-Prop $first.plain.data 'rate') -eq 1 -and
            (Get-Prop $first.plain.data 'clock') -eq $true -and [Math]::Abs([double] (Get-Prop $first.plain.data 'position')) -le 0.5
        Add-Check 'A-SAMPLE.playingTable' 'sample=playing uses synthetic song/artist, /art/sample, 240 s, rate 1, clock=true and phase 0' $first.plain $playingValid
        Add-Check 'A-SAMPLE.noartTable' 'sample=noart uses the playing row with artwork=null' ([ordered]@{
            state = Get-Prop $first.noart.data 'state'; artwork = Get-Prop $first.noart.data 'artwork'; title = Get-Prop $first.noart.data 'title' }) (
            $first.noart -and (Get-Prop $first.noart.data 'state') -eq 'playing' -and
            $null -eq (Get-Prop $first.noart.data 'artwork') -and (Get-Prop $first.noart.data 'title') -eq 'Sample song')
        Add-Check 'A-SAMPLE.pausedAt84' 'sample=paused is static at state=paused, position=84 and artwork=/art/sample' ([ordered]@{
            state = Get-Prop $first.paused.data 'state'; position = Get-Prop $first.paused.data 'position'; artwork = Get-Prop $first.paused.data 'artwork' }) (
            $first.paused -and (Get-Prop $first.paused.data 'state') -eq 'paused' -and
            (Get-Prop $first.paused.data 'position') -eq 84 -and (Get-Prop $first.paused.data 'artwork') -eq '/art/sample')
        Add-Check 'A-SAMPLE.previewSampleKind' 'pv sample stream is tagged preview=true, kind=sample and uses the synthetic sample snapshot' ([ordered]@{
            preview = Get-Prop (Get-Prop (Wait-SseLook $readersByKind['draft'] { param($m) (Get-Prop $m 'id') -eq 'draft' } 10) 'data') 'preview'
            title = Get-Prop $first.draft.data 'title' }) (
            $first.draft -and (Get-Prop $first.draft.data 'title') -eq 'Sample song')

        $countsSnap = Wait-OverlayStreams $run 7 'counts7'
        $realCount = Get-Overlay $countsSnap 'realStreams'; $sampleCount = Get-Overlay $countsSnap 'sampleStreams'
        $openCount = Get-Overlay $countsSnap 'openStreams'
        if ($null -eq $openCount) { $openCount = Get-Overlay $countsSnap 'streams' }
        Add-Check 'A-SAMPLE.streamCountsExposed' 'the seven admitted readers expose 3 Real and 4 Sample streams (the single preview is Sample)' ([ordered]@{
            realStreams = $realCount; sampleStreams = $sampleCount; openStreams = $openCount }) (
            $realCount -eq 3 -and $sampleCount -eq 4 -and $openCount -eq 7)

        $initialReal = $first.real
        $pauseEvent = $null; $adEvent = $null; $trackBEvent = $null
        $noneEvent = $null; $sampleAfterSuspend = $false; $sampleAfterNavigate = $false
        $controlsSent = $false; $powerSent = $false; $navigateSent = $false; $hidePausedSent = $false; $hideChecked = $false
        $hideQpc = 0; $pumpSent = $false; $draftPushes = 0
        $draftLookAfter = $null; $plainLookAfter = $null; $missingLookAfter = $null; $draftDataAfter = $null
        $plainSampleLookAfter = $null; $plainSampleDataAfter = $null
        $realEventsAfter = @(); $missingEventsAfter = @(); $savedEventsAfter = @()
        $draftStartQpc = $openEvents.draft.qpc
        $reanchorBaseQpc = [Math]::Min([double] $openEvents.plain.qpc, [Math]::Min([double] $openEvents.noart.qpc, [double] $draftStartQpc))
        $deadlineQpc = $reanchorBaseQpc + 245 * $freq
        $nextPushQpc = $draftStartQpc
        $suspendQpc = 0; $navigateQpc = 0
        $reanchorPlain = $null; $reanchorNoart = $null; $reanchorDraft = $null
        while ((Get-Qpc) -lt $deadlineQpc -and (-not $reanchorPlain -or -not $reanchorNoart -or -not $reanchorDraft)) {
            $now = Get-Qpc
            if ($now -ge $nextPushQpc) {
                $draftOptions['textShadow'] = (($draftPushes % 2) -eq 0)
                $draftName = if (($draftPushes % 2) -eq 0) { 'Draft A' } else { 'Draft B' }
                $queuedPush = Send-DraftLook $run.Root (New-ObsLook 'draft' $draftName $draftOptions) -NoWait
                # A still-pending hook is backpressure, not a successfully delivered 500 ms push.
                if ($null -ne $queuedPush) {
                    $draftPushes++
                    $nextPushQpc += 0.5 * $freq
                }
            }
            $realEvents = @(Get-DataEvents (Read-Sse $readersByKind['real']))
            if (-not $pauseEvent) { $pauseEvent = $realEvents | Where-Object { (Get-Prop $_.data 'state') -eq 'paused' } | Select-Object -First 1 }
            if (-not $adEvent) { $adEvent = $realEvents | Where-Object { (Get-Prop $_.data 'state') -eq 'ad' } | Select-Object -First 1 }
            if (-not $trackBEvent) { $trackBEvent = $realEvents | Where-Object { (Get-Prop $_.data 'title') -eq 'Fixture Song B' } | Select-Object -First 1 }
            if ($trackBEvent -and -not $controlsSent) {
                [void] (Send-HookCommand $run.Root 'command-controls-unavailable-on'); $controlsSent = $true
            }
            if ($controlsSent -and -not $noneEvent) {
                $noneEvent = $realEvents | Where-Object { $_.qpc -gt $trackBEvent.qpc -and (Get-Prop $_.data 'state') -eq 'none' } | Select-Object -First 1
            }
            if ($noneEvent -and -not $hidePausedSent) {
                $hideQpc = Send-HookCommand $run.Root 'command-obs-hide-paused-off'; $hidePausedSent = $true
            }
            if ($hidePausedSent -and -not $hideChecked -and (Get-Qpc) -ge ($hideQpc + $freq)) {
                $draftEvents = @(Read-Sse $readersByKind['draft'] | Where-Object { $_.qpc -gt $hideQpc -and $_.qpc -le $hideQpc + $freq })
                $realWindow = @(Read-Sse $readersByKind['real'] | Where-Object { $_.qpc -gt $hideQpc -and $_.qpc -le $hideQpc + $freq })
                $missingWindow = @(Read-Sse $readersByKind['missing'] | Where-Object { $_.qpc -gt $hideQpc -and $_.qpc -le $hideQpc + $freq })
                $savedEventsAfter = @(Read-Sse $readersByKind['saved'] | Where-Object { $_.qpc -gt $hideQpc -and $_.qpc -le $hideQpc + $freq -and $_.kind -in @('look', 'data') })
                $draftLookAfter = Get-LookEvents $draftEvents | Where-Object { (Get-Prop $_.data 'hidePaused') -eq $false } | Select-Object -First 1
                $plainLookAfter = Get-LookEvents $realWindow | Where-Object { (Get-Prop $_.data 'hidePaused') -eq $false } | Select-Object -First 1
                $missingLookAfter = Get-LookEvents $missingWindow | Where-Object { (Get-Prop $_.data 'hidePaused') -eq $false } | Select-Object -First 1
                $draftDataAfter = Get-DataEvents $draftEvents | Where-Object { (Get-Prop $_.data 'title') -eq 'Sample song' } | Select-Object -First 1
                $plainSampleEvents = @(Read-Sse $readersByKind['plain'] | Where-Object { $_.qpc -gt $hideQpc -and $_.qpc -le $hideQpc + $freq })
                $plainSampleLookAfter = Get-LookEvents $plainSampleEvents | Where-Object { (Get-Prop $_.data 'hidePaused') -eq $false } | Select-Object -First 1
                $plainSampleDataAfter = Get-DataEvents $plainSampleEvents | Where-Object { (Get-Prop $_.data 'title') -eq 'Sample song' } | Select-Object -First 1
                $realEventsAfter = @($realWindow | Where-Object { $_.kind -eq 'data' })
                $missingEventsAfter = @($missingWindow | Where-Object { $_.kind -eq 'data' })
                $hideChecked = $true
            }
            if ($hidePausedSent -and -not $powerSent -and (Get-Seconds $reanchorBaseQpc (Get-Qpc)) -ge 90) {
                $suspendQpc = Send-HookCommand $run.Root 'command-power-suspend'
                [void] (Send-HookCommand $run.Root 'command-power-resume'); $powerSent = $true
            }
            if ($powerSent -and -not $navigateSent -and (Get-Seconds $reanchorBaseQpc (Get-Qpc)) -ge 100) {
                $navigateQpc = Send-HookCommand $run.Root 'command-navigate'
                $navigateSent = $true
            }
            $elapsed = Get-Seconds $reanchorBaseQpc (Get-Qpc)
            if ($elapsed -ge 235) {
                $plainData = @(Get-DataEvents (Read-Sse $readersByKind['plain']))
                $noartData = @(Get-DataEvents (Read-Sse $readersByKind['noart']))
                $draftData = @(Get-DataEvents (Read-Sse $readersByKind['draft']))
                if (-not $reanchorPlain) { $reanchorPlain = $plainData | Where-Object { $_.qpc -gt $openEvents.plain.qpc + 235 * $freq -and [double] (Get-Prop $_.data 'position') -le 1 } | Select-Object -Last 1 }
                if (-not $reanchorNoart) { $reanchorNoart = $noartData | Where-Object { $_.qpc -gt $openEvents.noart.qpc + 235 * $freq -and [double] (Get-Prop $_.data 'position') -le 1 } | Select-Object -Last 1 }
                if (-not $reanchorDraft) { $reanchorDraft = $draftData | Where-Object { $_.qpc -gt $openEvents.draft.qpc + 235 * $freq -and [double] (Get-Prop $_.data 'position') -le 1 } | Select-Object -Last 1 }
            }
            $elapsed = Get-Seconds $reanchorBaseQpc (Get-Qpc)
            if ($elapsed -ge 239 -and -not $pumpSent) {
                [void] (Send-ObsHookCommand $run.Root 'command-obs-pump-hold' '200')
                $pumpSent = $true
            }
            Start-Sleep -Milliseconds 100
        }
        $sampleEvents = @(Get-DataEvents (Read-Sse $readersByKind['draft']))
        $sampleAfterSuspend = $powerSent -and $suspendQpc -gt 0 -and @($sampleEvents | Where-Object { $_.qpc -gt $suspendQpc -and (Get-Prop $_.data 'title') -eq 'Sample song' }).Count -gt 0
        $sampleAfterNavigate = $navigateSent -and $navigateQpc -gt 0 -and @($sampleEvents | Where-Object { $_.qpc -gt $navigateQpc -and (Get-Prop $_.data 'title') -eq 'Sample song' }).Count -gt 0
        $sampleWire = (@(Read-Sse $readersByKind['draft']) | ForEach-Object { "$($_.json)$($_.text)" }) -join "`n"
        $samplePrivacyLeaks = @([regex]::Matches($sampleWire, 'fixtureSng|watch\?v=|youtube\.com|googleusercontent|ytimg|ggpht|https?:', 'IgnoreCase') | ForEach-Object { $_.Value } | Select-Object -Unique)
        Add-Check 'A-SAMPLE.noIdentifiersOrUrls' 'sample feed contains no YouTube fixture id, Google host or URL' $samplePrivacyLeaks ($samplePrivacyLeaks.Count -eq 0)
        $plainDue = if ($reanchorPlain) { Get-Seconds $openEvents.plain.qpc $reanchorPlain.qpc }
        $draftDue = if ($reanchorDraft) { Get-Seconds $openEvents.draft.qpc $reanchorDraft.qpc }
        $noartDue = if ($reanchorNoart) { Get-Seconds $openEvents.noart.qpc $reanchorNoart.qpc }
        Add-Check 'A-SAMPLE.reanchorDuringDraftPush' 'playing sample re-anchors at 240 ±1 s while a current-nonce draft look is pushed every 500 ms' ([ordered]@{
            seconds = $draftDue; position = Get-Prop $reanchorDraft.data 'position'; pushes = $draftPushes }) (
            $reanchorDraft -and $draftPushes -ge 450 -and $draftDue -ge 239 -and $draftDue -le 241 -and
            [double] (Get-Prop $reanchorDraft.data 'position') -le 1)
        Add-Check 'A-SAMPLE.reanchorDuringPumpHold' 'plain playing/noart sample rows re-anchor at 240 ±1 s during a 200 ms pump hold' ([ordered]@{
            plainSeconds = $plainDue; plainPosition = Get-Prop $reanchorPlain.data 'position'
            noartSeconds = $noartDue; noartPosition = Get-Prop $reanchorNoart.data 'position'; pumpHeld = $pumpSent }) (
            $pumpSent -and $reanchorPlain -and $reanchorNoart -and $plainDue -ge 239 -and $plainDue -le 241 -and
            $noartDue -ge 239 -and $noartDue -le 241 -and
            (Get-Prop $reanchorNoart.data 'artwork') -eq $null)
        # Reconnect/static observation runs after the timed draft workload, not before its producer starts.
        # Paused sample reconnect is a fresh stream at the fixed position 84.
        Stop-SseReader $readersByKind['paused']; [void] $allReaders.Remove($readersByKind['paused'])
        [void] (Wait-OverlayStreams $run 6 'pausedClosed')
        $pausedAgainReader = Start-SseReader 'A-SAMPLE-paused-reconnect' 30 '/events?sample=paused'
        $allReaders.Add($pausedAgainReader)
        $pausedAgain = Wait-SseData $pausedAgainReader { param($d) (Get-Prop $d 'state') -eq 'paused' } 15
        [void] (Wait-OverlayStreams $run 7 'pausedReopened')
        Add-Check 'A-SAMPLE.pausedReconnect' 'closing/reopening a paused sample starts at position 84 again' ([ordered]@{
            position = Get-Prop (Get-Prop $pausedAgain 'data') 'position'; qpc = Get-Prop $pausedAgain 'qpc' }) (
            $pausedAgain -and (Get-Prop $pausedAgain.data 'position') -eq 84)
        Start-Sleep -Seconds 5
        $pausedWindow = @(Get-DataEvents (Read-Sse $pausedAgainReader))
        Add-Check 'A-SAMPLE.pausedStatic' 'paused sample has no due-work updates while position remains fixed at 84' ([ordered]@{
            dataEvents = $pausedWindow.Count; positions = @($pausedWindow | ForEach-Object { Get-Prop $_.data 'position' }) }) (
            $pausedWindow.Count -eq 1 -and (Get-Prop $pausedWindow[0].data 'position') -eq 84)

        if (-not $hideChecked) { Add-Check 'A-SAMPLE.hidePausedObservationWindow' '1 s window after hidePaused toggle captures sample/real events' $hideChecked $false }
        Add-Check 'A-SAMPLE.syntheticHidePausedSamplePush' 'while real state is none, all Sample streams get a look plus current snapshot when hidePaused changes' ([ordered]@{
            draftLook = [bool] $draftLookAfter; draftData = [bool] $draftDataAfter; plainLook = [bool] $plainSampleLookAfter
            plainData = [bool] $plainSampleDataAfter; hidePaused = Get-Prop (Get-Prop $draftLookAfter 'data') 'hidePaused' }) (
            $hidePausedSent -and $draftLookAfter -and $draftDataAfter -and $plainSampleLookAfter -and $plainSampleDataAfter -and
            (Get-Prop $draftLookAfter.data 'hidePaused') -eq $false -and
            (Get-Prop $plainSampleLookAfter.data 'hidePaused') -eq $false)
        Add-Check 'A-SAMPLE.syntheticHidePausedPillFallbackOnly' 'plain and missing-fallback Real streams get a look but no data event; saved-look Real gets nothing' ([ordered]@{
            plainLook = [bool] $plainLookAfter; missingLook = [bool] $missingLookAfter; plainData = $realEventsAfter.Count
            missingData = $missingEventsAfter.Count; savedEvents = $savedEventsAfter.Count }) (
            $hidePausedSent -and $plainLookAfter -and $missingLookAfter -and $realEventsAfter.Count -eq 0 -and
            $missingEventsAfter.Count -eq 0 -and $savedEventsAfter.Count -eq 0)

        $transitionEvents = @(@($pauseEvent, $adEvent, $trackBEvent, $noneEvent) | Where-Object { $null -ne $_ })
        $transitionStates = @($transitionEvents | ForEach-Object { Get-Prop $_.data 'state' })
        $sampleEvents = @(Get-DataEvents (Read-Sse $readersByKind['draft']))
        $sampleLeak = @($sampleEvents | Where-Object {
            (Get-Prop $_.data 'title') -ne 'Sample song' -or (Get-Prop $_.data 'artist') -ne 'Sample artist' -or
            (Get-Prop $_.data 'artwork') -notin @('/art/sample', $null)
        })
        Add-Check 'A-SAMPLE.realStateIsolation' 'sample stream remains synthetic across real pause/ad/track/none, suspend and navigation transitions' ([ordered]@{
            realStates = $transitionStates; sampleLeakCount = $sampleLeak.Count; afterSuspend = $sampleAfterSuspend; afterNavigate = $sampleAfterNavigate }) (
            $pauseEvent -and $adEvent -and $trackBEvent -and $noneEvent -and $powerSent -and $navigateSent -and
            $sampleAfterSuspend -and $sampleAfterNavigate -and $sampleLeak.Count -eq 0)

        Stop-SseReader $readersByKind['draft']; [void] $allReaders.Remove($readersByKind['draft'])
        [void] (Wait-OverlayStreams $run 6 'draftSampleClosed')
        # One Real preview plus one normal Real stream: Settings' status count must exclude only that preview.
        $realPreview = Start-SseReader 'A-SAMPLE-real-preview' 30 '/events?look=draft&pv=sample01'
        $allReaders.Add($realPreview)
        $realExtra = Start-SseReader 'A-SAMPLE-real-extra' 30 '/events'
        $allReaders.Add($realExtra)
        [void] (Wait-SseLook $realPreview { param($m) (Get-Prop $m 'id') -eq 'draft' } 15)
        [void] (Wait-SseData $realExtra { param($d) (Get-Prop $d 'state') -eq 'none' } 15)
        $statusSnap = Wait-OverlayStreams $run 8 'status-minus-preview'
        $statusReal = Get-Overlay $statusSnap 'realStreams'
        $statusSourceCount = Get-Overlay $statusSnap 'statusSourceCount'
        $nonces = Get-Overlay $statusSnap 'previewNonces'
        Add-Check 'A-SAMPLE.statusCountsExcludePreview' 'statusSourceCount equals realStreams minus one admitted current-nonce Real preview' ([ordered]@{
            realStreams = $statusReal; statusSourceCount = $statusSourceCount; previewNonces = $nonces }) (
            $statusReal -eq 5 -and $statusSourceCount -eq 4 -and (Get-Prop $nonces 'current') -eq 'sample01' -and
            (Get-Prop $nonces 'open') -ge 1)

        $countNow = Get-Overlay (Get-State $run.Root 'sampleBeforeLifetime') 'streams'
        $lifetime = Wait-For {
            $s = Get-State $run.Root 'sampleLifetime'
            if ((Get-Overlay $s 'lastStreamEndReason') -eq 'Lifetime') { $s }
        } 90 1000
        $renewReader = Start-SseReader 'A-SAMPLE-after-renewal' 30 '/events?sample=playing'
        $allReaders.Add($renewReader)
        $renewed = Wait-SseData $renewReader { param($d) (Get-Prop $d 'state') -eq 'playing' } 15
        Add-Check 'A-SAMPLE.lifetimeRenewalPhaseZero' 'after the five-minute lifetime closes streams, a newly admitted sample stream starts at phase 0' ([ordered]@{
            priorStreams = $countNow; endReason = Get-Overlay $lifetime 'lastStreamEndReason'; renewedPosition = Get-Prop $renewed.data 'position' }) (
            $lifetime -and (Get-Overlay $lifetime 'lastStreamEndReason') -eq 'Lifetime' -and
            $renewed -and [Math]::Abs([double] (Get-Prop $renewed.data 'position')) -le 0.5)
        $scenarioResults['A-SAMPLE'] = [ordered]@{ reanchor = [ordered]@{ plain = $plainDue; noart = $noartDue; draft = $draftDue }
            draftPushes = $draftPushes; statusSourceCount = $statusSourceCount; lifetime = [bool] $lifetime }
    } finally {
        foreach ($reader in $allReaders) { Stop-SseReader $reader }
        if ($realPreview) { Stop-SseReader $realPreview }; if ($realExtra) { Stop-SseReader $realExtra }
        Stop-OverlayRun $run
    }
    $demand = Test-ASampleDemand
    $scenarioResults['A-SAMPLE']['demand'] = $demand
}
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
    $probe = [ordered]@{}
    try {
        $initial = Wait-Initial $run
        $start = Get-PageStartQpc $initial
        # Privacy probes against the live server: the artwork the stream advertises, fetched over real HTTP.
        $withArt = Wait-SseData $run.Reader { param($d) "$(Get-Prop $d 'artwork')" -match '^/art/[0-9a-f]{16}$' } 20
        $probe.artPath = if ($withArt) { [string] (Get-Prop $withArt.data 'artwork') } else { $null }
        $probe.page = Invoke-RawHttp '127.0.0.1' (New-Request)
        $probe.art = if ($probe.artPath) { Invoke-RawHttp '127.0.0.1' (New-Request -Path $probe.artPath) } else { $null }
        $probe.unknown = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/art/0000000000000000')
        Wait-UntilQpc ($start + 143 * $freq)
        $alive = -not $run.App.HasExited
    } finally { Stop-OverlayRun $run }
    [pscustomobject]@{ Run = $run; Events = @(Read-Sse $run.Reader); Raw = (Read-SseRaw $run.Reader); Start = $start; Initial = $initial; Alive = $alive; Probe = $probe }
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
    @{ name = 'trackCArt'; at = 137; test = { param($d) (Test-Data $d 'playing' 'fixtureSngC') -and "$(Get-Prop $d 'artwork')" -match '^/art/[0-9a-f]{16}$' } })

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
    # Privacy: everything a local process or the page can learn from the stream and the artwork route.
    $wire = (@($Result.Events | Where-Object { $_.kind -in @('data', 'comment', 'retry') }) | ForEach-Object { "$($_.json)$($_.text)" }) -join "`n"
    $leaks = @([regex]::Matches($wire, 'fixtureS(ng|nA)|fixtureTxt|watch\?v=|googleusercontent|ytimg|ggpht|https?:', 'IgnoreCase') | ForEach-Object { $_.Value } | Select-Object -Unique)
    Add-Check "$Prefix.noVideoIdOrGoogleUrl" 'no fixture video id, watch link, googleusercontent/ytimg/ggpht host or http(s): URL in any event' $leaks ($wire.Length -gt 0 -and $leaks.Count -eq 0)
    $meta = @(Get-DataEvents $Result.Events | Where-Object { (Get-Prop $_.data 'state') -in @('playing', 'paused', 'ended') })
    $badIds = @($meta | Where-Object { "$(Get-Prop $_.data 'id')" -cnotmatch '^[0-9a-f]{16}$' })
    $byTitle = @($meta | Group-Object { "$(Get-Prop $_.data 'title')" })
    $unstable = @($byTitle | Where-Object { @($_.Group | ForEach-Object { Get-Prop $_.data 'id' } | Select-Object -Unique).Count -ne 1 })
    $allIds = @($meta | ForEach-Object { Get-Prop $_.data 'id' } | Select-Object -Unique)
    Add-Check "$Prefix.opaqueStableIds" 'every id is 16 lowercase hex; one id per track (A, B, C) and a different id for each track' ([ordered]@{
        tracks = $byTitle.Count; distinctIds = $allIds.Count; malformed = $badIds.Count; unstableTracks = $unstable.Count }) (
        $meta.Count -gt 0 -and $badIds.Count -eq 0 -and $unstable.Count -eq 0 -and $byTitle.Count -eq 3 -and $allIds.Count -eq 3)
    $badArt = @($meta | ForEach-Object { Get-Prop $_.data 'artwork' } | Where-Object { $null -ne $_ -and "$_" -cnotmatch '^/art/[0-9a-f]{16}$' })
    $artOf = { param($t) @($meta | Where-Object { (Get-Prop $_.data 'title') -eq $t -and $null -ne (Get-Prop $_.data 'artwork') } | ForEach-Object { Get-Prop $_.data 'artwork' } | Select-Object -Unique) }
    $artA = @(& $artOf 'Fixture Song A'); $artB = @(& $artOf 'Fixture Song B'); $artC = @(& $artOf 'Fixture Song C')
    Add-Check "$Prefix.artworkPaths" 'artwork is null or /art/<16 hex>; A and B (same source URL) share one path, C has a different one' ([ordered]@{
        a = $artA; b = $artB; c = $artC; malformed = $badArt.Count }) (
        $badArt.Count -eq 0 -and $artA.Count -eq 1 -and $artB.Count -eq 1 -and $artA[0] -ceq $artB[0] -and $artC.Count -eq 1 -and $artC[0] -cne $artA[0])
    $pr = $Result.Probe
    $img = Get-Prop $pr 'art'; $unknown = Get-Prop $pr 'unknown'
    $imgType = if ($img) { "$($img.headers['content-type'])" } else { '' }
    $imgLength = if ($img) { [int] $img.headers['content-length'] } else { 0 }
    $pngMagic = [bool] ($img -and $img.body.Length -ge 4 -and $img.body.Substring(1, 3) -ceq 'PNG')
    Add-Check "$Prefix.artServed" 'GET the advertised /art/<key> -> 200 image/png, non-empty PNG body, no-store, nosniff; GET /art/0000000000000000 -> 404 from the app' ([ordered]@{
        path = Get-Prop $pr 'artPath'; status = if ($img) { $img.status } else { $null }; contentType = $imgType; contentLength = $imgLength; pngMagic = $pngMagic
        cacheControl = if ($img) { "$($img.headers['cache-control'])" } else { $null }; unknownStatus = if ($unknown) { $unknown.status } else { $null } }) (
        $img -and $img.status -eq 200 -and $imgType -like 'image/png*' -and $imgLength -gt 0 -and $pngMagic -and "$($img.headers['cache-control'])" -like '*no-store*' -and
        "$($img.headers['x-content-type-options'])" -eq 'nosniff' -and $unknown -and $unknown.status -eq 404 -and $unknown.origin -eq 'app')
    $csp = "$((Get-Prop $pr 'page').headers['content-security-policy'])"
    $imgSrc = [regex]::Match($csp, 'img-src[^;]*').Value.Trim()
    Add-Check "$Prefix.cspImgSelfOnly" "page CSP img-src is exactly 'self' (no Google host)" ([ordered]@{ imgSrc = $imgSrc }) ($imgSrc -ceq "img-src 'self'" -and $csp -notmatch 'googleusercontent|ytimg|ggpht')
    $wrongHide = @($data | Where-Object { (Get-Prop $_.data 'state') -in @('playing', 'paused', 'ended') -and (Get-Prop $_.data 'hidePaused') -ne $HidePaused })
    Add-Check "$Prefix.hidePausedField" "every metadata event carries hidePaused=$HidePaused" $wrongHide.Count ($data.Count -gt 0 -and $wrongHide.Count -eq 0)
    $adEvents = @($data | Where-Object { (Get-Prop $_.data 'state') -in @('ad', 'none') })
    $badShape = @($adEvents | Where-Object { @($_.data.PSObject.Properties.Name) -join ',' -ne 'v,state' })
    Add-Check "$Prefix.adNoneShape" 'ad/none events carry only v and state' $badShape.Count ($badShape.Count -eq 0)
    Add-Check "$Prefix.appAlive" 'app alive through page 143 s' $Result.Alive $Result.Alive
    # id and artwork are per-session opaque keys: compare runs by first-seen ordinals (t1.. / a1..), not raw values.
    $ids = @{}; $arts = @{}
    $normalized = @($sequence | ForEach-Object {
        $f = @($_ -split [char] 1)
        if ($f[1]) { if (-not $ids.ContainsKey($f[1])) { $ids[$f[1]] = 't' + ($ids.Count + 1) }; $f[1] = $ids[$f[1]] }
        if ($f[4]) { if (-not $arts.ContainsKey($f[4])) { $arts[$f[4]] = 'a' + ($arts.Count + 1) }; $f[4] = $arts[$f[4]] }
        $f -join [char] 1 })
    [pscustomobject]@{ ok = ($matched.Count -eq $timelineSteps.Count -and $unexpected.Count -eq 0); sequence = $normalized; driftCorrections = @($drift) }
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
    Add-Check 'A-SAME.onlyIdChanged' 'id changes to a different opaque 16-hex key; state, title, artist, artwork, duration, rate, clock unchanged' $(if ($only) { Get-EventSummary $after[0] $start }) (
        [bool] $sameOther -and "$(Get-Prop $only 'id')" -cmatch '^[0-9a-f]{16}$' -and (Get-Prop $only 'id') -cne (Get-Prop $initial.data 'id'))
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
$savedLook = New-ObsLook 'sec00001' 'Security look' (New-DefaultPillOptions)
    $run = Start-OverlayRun 'A-SEC' @{ ObsOverlay = $true } 'Playing' -NoReader -LooksJson (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($savedLook)))
    $raws = [Collections.Generic.List[object]]::new(); $table = [ordered]@{}; $responses = [Collections.Generic.List[object]]::new()
    $previewReader = $null; $newNonceReader = $null; $lastReader = $null
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
            @{ n = 'artUnknown'; a = '127.0.0.1'; r = (New-Request -Path '/art/0000000000000000'); want = { param($x) $x.status -eq 404 -and $x.origin -eq 'app' }; e = '404 app (unknown key)' },
            @{ n = 'artMalformed'; a = '127.0.0.1'; r = (New-Request -Path '/art/not-a-key'); want = { param($x) $x.status -eq 404 -and $x.origin -eq 'app' }; e = '404 app (malformed key)' },
            @{ n = 'artQuery'; a = '127.0.0.1'; r = (New-Request -Path '/art/0000000000000000?x=1'); want = { param($x) $x.status -eq 400 -and $x.origin -eq 'app' }; e = '400 app' },
            @{ n = 'artCrossSite'; a = '127.0.0.1'; r = (New-Request -Path '/art/0000000000000000' -Extra @('Sec-Fetch-Site: cross-site')); want = { param($x) $x.status -eq 403 -and $x.origin -eq 'app' }; e = '403 app' },
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
            "img-src 'self';")
        Add-Check 'A-SEC.htmlCsp' "HTML carries the plan §3 CSP with img-src 'self' only (artwork is served by the app, no Google host)" $csp ($csp -and -not ($cspParts | Where-Object { -not $csp.Contains($_) }) -and $csp -notmatch 'googleusercontent|ytimg|ggpht')
        $nonce = 'pv000001'
        [void] (Send-PreviewNonce $run.Root $nonce)
        [void] (Send-DraftLook $run.Root (New-ObsLook 'draft' 'Security draft' (New-DefaultPillOptions)))
        $routeMatrix = [Collections.Generic.List[object]]::new()
        foreach ($path in @('/', '/?look=sec00001', "/?look=draft&preview=1&pv=$nonce&sample=playing", '/?sample=noart')) {
            $response = Invoke-RawHttp '127.0.0.1' (New-Request -Path $path)
            $responses.Add($response); $routeMatrix.Add([ordered]@{ kind = 'html'; path = $path; status = $response.status
                headers = $response.headers; origin = $response.origin })
        }
        $sampleArt = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/art/sample')
        $responses.Add($sampleArt); $routeMatrix.Add([ordered]@{ kind = 'art'; path = '/art/sample'; status = $sampleArt.status
            headers = $sampleArt.headers; origin = $sampleArt.origin })
        $sampleStream = Open-RawStream -Path '/events?sample=playing'
        $raws.Add($sampleStream); $responses.Add([pscustomobject]@{ status = $sampleStream.Status; headers = $sampleStream.Headers; origin = 'app' })
        $routeMatrix.Add([ordered]@{ kind = 'events'; path = '/events?sample=playing'; status = $sampleStream.Status
            headers = $sampleStream.Headers; origin = 'app' })
        $pageMatrix = @($routeMatrix | Where-Object { $_.kind -eq 'html' })
        $htmlCsp = $pageMatrix[0].headers['content-security-policy']
        $expectedCsp = "default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
        $scriptResponse = $responses | Where-Object { "$($_.headers['content-type'])" -like 'text/javascript*' } | Select-Object -First 1
        $eventResponse = $routeMatrix | Where-Object { $_.kind -eq 'events' } | Select-Object -First 1
        $noCspBad = @($routeMatrix | Where-Object { $_.kind -ne 'html' -and $_.headers.Contains('content-security-policy') })
        $typeBad = @($pageMatrix | Where-Object { "$($_.headers['content-type'])" -cne 'text/html; charset=utf-8' })
        Add-Check 'A-SEC.headerMatrix' 'allowed / queries are 200 text/html with exact CSP; /art/sample is image/png; /events is chunked event-stream; non-HTML routes have no CSP' ([ordered]@{
            routes = @($routeMatrix | ForEach-Object { [ordered]@{ kind = $_.kind; path = $_.path; status = $_.status; type = $_.headers['content-type']; transfer = $_.headers['transfer-encoding'] } })
            csp = $htmlCsp; scriptNoCsp = ($scriptResponse -and -not $scriptResponse.headers.Contains('content-security-policy'))
            nonHtmlCspCount = $noCspBad.Count; badHtmlTypeCount = $typeBad.Count }) (
            $pageMatrix.Count -eq 4 -and @($pageMatrix | Where-Object { $_.status -ne 200 }).Count -eq 0 -and
            $typeBad.Count -eq 0 -and $htmlCsp -ceq $expectedCsp -and
            $sampleArt.status -eq 200 -and "$($sampleArt.headers['content-type'])" -like 'image/png*' -and
            $sampleStream.Status -eq 200 -and "$($sampleStream.Headers['content-type'])" -like 'text/event-stream*' -and
            "$($sampleStream.Headers['transfer-encoding'])" -eq 'chunked' -and
            $scriptResponse -and -not $scriptResponse.headers.Contains('content-security-policy') -and $noCspBad.Count -eq 0)
        Close-RawStream $sampleStream; [void] $raws.Remove($sampleStream)
        [void] (Wait-OverlayStreams $run 0 'headerMatrixReleased')

        $previewReader = Start-SseReader 'A-SEC-preview-current' 20 "/events?look=draft&pv=$nonce&sample=playing"
        $previewOpen = Wait-SseOpen $previewReader 15
        $previewLook = Wait-SseLook $previewReader { param($m) (Get-Prop $m 'preview') -ne $null } 10
        $countBefore410 = Get-Overlay (Get-State $run.Root 'pvBefore410') 'streams'
        $unknownPv = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/events?look=draft&pv=unknown1')
        $retiredPv = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/events?look=draft&pv=retired1')
        $malformedPv = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/events?look=draft&pv=BAD00001')
        $countAfter410 = Get-Overlay (Get-State $run.Root 'pvAfter410') 'streams'
        $responses.Add($unknownPv); $responses.Add($retiredPv); $responses.Add($malformedPv)
        Add-Check 'A-SEC.pvCurrentNonce200' 'current preview nonce admits an event stream and its first look carries preview mode' ([ordered]@{
            open = Get-Prop $previewOpen 'text'; look = Get-Prop $previewLook 'data' }) (
            $previewOpen -and $previewLook -and (Get-Prop $previewLook.data 'preview') -ne $null)
        Add-Check 'A-SEC.pvUnknownRetired410' 'unknown and retired well-formed pv values return 410 with standard headers and no stream count change' ([ordered]@{
            unknown = $unknownPv.status; retired = $retiredPv.status; before = $countBefore410; after = $countAfter410 }) (
            $unknownPv.status -eq 410 -and $retiredPv.status -eq 410 -and $unknownPv.origin -eq 'app' -and
            $retiredPv.origin -eq 'app' -and $countBefore410 -eq $countAfter410)
        Add-Check 'A-SEC.pvMalformed400' 'malformed pv value remains 400, distinct from the valid-unknown 410 response' ([ordered]@{
            status = $malformedPv.status; origin = $malformedPv.origin }) ($malformedPv.status -eq 400 -and $malformedPv.origin -eq 'app')
        $previewData = Wait-SseData $previewReader { param($d) (Get-Prop $d 'state') -eq 'playing' } 15
        $lookObject = Get-Prop $previewLook 'data'
        $lookKeys = @($lookObject.PSObject.Properties.Name)
        $dataKeys = @($previewData.data.PSObject.Properties.Name)
        $allowedLookKeys = @('v','epoch','seq','id','missing','kind','theme','box','source','reduceMotion','fontAvailable','hidePaused','options','preview')
        $allowedDataKeys = @('v','state','id','title','artist','artwork','duration','position','rate','clock','ageMs','hidePaused')
        $extraLookKeys = @($lookKeys | Where-Object { $_ -notin $allowedLookKeys })
        $extraDataKeys = @($dataKeys | Where-Object { $_ -notin $allowedDataKeys })
        $previewWire = Read-SseRaw $previewReader
        $previewPrivacyLeaks = @([regex]::Matches($previewWire, 'fixtureSng|watch\?v=|youtube\.com|googleusercontent|ytimg|ggpht|https?:', 'IgnoreCase') | ForEach-Object { $_.Value } | Select-Object -Unique)
        Add-Check 'A-SEC.wireShapeAndPrivacy' 'look/data carry only plan fields, opaque ids and same-origin art paths; no video id, Google URL or new metadata field' ([ordered]@{
            lookKeys = $lookKeys; dataKeys = $dataKeys; extraLook = $extraLookKeys; extraData = $extraDataKeys
            privacyLeaks = $previewPrivacyLeaks }) (
            $previewLook -and $previewData -and $extraLookKeys.Count -eq 0 -and $extraDataKeys.Count -eq 0 -and
            $previewPrivacyLeaks.Count -eq 0 -and (Get-Prop $previewData.data 'artwork') -eq '/art/sample')

        Stop-SseReader $previewReader
        [void] (Send-PreviewNonce $run.Root 'pv000002')
        $newNonceReader = Start-SseReader 'A-SEC-preview-rotated' 20 '/events?look=draft&pv=pv000002'
        $rotatedOpen = Wait-SseOpen $newNonceReader 15
        $oldAfterRotate = Invoke-RawHttp '127.0.0.1' (New-Request -Path "/events?look=draft&pv=$nonce")
        [void] (Send-PreviewNonce $run.Root 'pv000003')
        for ($i = 4; $i -le 11; $i++) { [void] (Send-PreviewNonce $run.Root ('pv{0:D6}' -f $i)) }
        $oldAfterMany = Invoke-RawHttp '127.0.0.1' (New-Request -Path "/events?look=draft&pv=$nonce")
        $lastNonce = 'pv000011'
        $lastReader = Start-SseReader 'A-SEC-preview-after-eight-switches' 20 "/events?look=draft&pv=$lastNonce"
        $lastOpen = Wait-SseOpen $lastReader 15
        [void] (Send-DraftLook $run.Root $null)
        [void] (Send-PreviewNonce $run.Root 'clear')
        $afterClosePv = Invoke-RawHttp '127.0.0.1' (New-Request -Path "/events?look=draft&pv=$lastNonce")
        $responses.Add($oldAfterRotate); $responses.Add($oldAfterMany); $responses.Add($afterClosePv)
        Add-Check 'A-SEC.pvRotationAndRetirement' 'old nonce is 410 after rotation and after >8 switches; current nonce stays 200; after close any prior token is 410' ([ordered]@{
            rotatedStatus = Get-Prop $rotatedOpen 'text'; oldAfterRotate = $oldAfterRotate.status; oldAfterMany = $oldAfterMany.status
            lastNonceStatus = Get-Prop $lastOpen 'text'; afterClose = $afterClosePv.status }) (
            $rotatedOpen -and $oldAfterRotate.status -eq 410 -and $oldAfterMany.status -eq 410 -and
            $lastOpen -and $afterClosePv.status -eq 410)
        Stop-SseReader $newNonceReader; Stop-SseReader $lastReader; Stop-SseReader $previewReader
        [void] (Wait-OverlayStreams $run 0 'previewMatrixReleased')
        [void] (Test-P2PreviewHostSecurity $run)
        if (Test-ChromeAvailable 'A-SEC') {
            $evilFont = 'Bad "family\); url(http://localhost:47813/unexpected.png)'
            $evilOptions = New-DefaultPillOptions
            $evilOptions['font'] = $evilFont; $evilOptions['colours'] = 'custom'
            $evilOptions['text'] = 'red; background:url(http://localhost:47813/unexpected.png)'
            $evilOptions['background'] = 'url(http://localhost:47813/unexpected.png)'
            $evilOptions['accent'] = '#fff);url(http://localhost:47813/unexpected.png)'
            $evilLook = New-ObsLook 'evil0001' '<img src=x onerror=alert(1)>' $evilOptions
            [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($savedLook, $evilLook))))
            [void] (Send-ObsHookCommand $run.Root 'command-obs-font-force-available' $evilFont)
            [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
            $securityReader = Start-SseReader 'A-SEC-typed-look' 20 '/events?look=evil0001'
            $securityChrome = $null
            try {
                $securityLook = Wait-SseLook $securityReader { param($m) (Get-Prop $m 'id') -eq 'evil0001' } 15
                $securityChrome = Start-Chrome 'A-SEC-typed-sinks'
                [void] (Invoke-ChromeNavigate $securityChrome "$($overlayUrl)?look=evil0001")
                $securityPage = Wait-For { $p = Get-PageProbe $securityChrome; if ((Get-PageField $p 'connection') -eq 'open') { $p } } 15 100
                $resources = @($securityPage.resources)
                $external = @($resources | Where-Object { $_.origin -cne "http://localhost:$port" })
                $unexpectedRoute = @($resources | Where-Object { $_.path -eq '/unexpected.png' })
                $securityWire = Read-SseRaw $securityReader
                $wireLeaks = @([regex]::Matches($securityWire, 'googleusercontent|ytimg|ggpht|youtube\.com|watch\?v=', 'IgnoreCase') | ForEach-Object { $_.Value } | Select-Object -Unique)
                Add-Check 'A-SEC.typedSinksNoNetwork' 'malicious name/font/colour values stay data-only, are normalized/escaped and cause no non-local or attacker-selected resource request' ([ordered]@{
                    id = Get-Prop $securityLook.data 'id'; nameInWire = $securityWire.Contains('<img')
                    fontAvailable = Get-Prop $securityPage.s 'fontAvailable'; fontVar = Get-Prop $securityPage.css 'fontVar'
                    text = Get-Prop $securityPage.css 'fg'; external = $external; unexpected = $unexpectedRoute
                    privacyLeaks = $wireLeaks }) (
                    $securityLook -and $securityPage -and (Get-Prop $securityPage.s 'fontAvailable') -eq $true -and
                    [string] (Get-Prop $securityPage.css 'fontVar') -match '^"Bad \\"family\\\\\); url\(http://localhost:47813/unexpected\.png\)",' -and
                    (Get-Prop $securityPage.css 'fg') -eq '#ffffff' -and
                    -not $securityWire.Contains('<img') -and $external.Count -eq 0 -and $unexpectedRoute.Count -eq 0 -and $wireLeaks.Count -eq 0)
            } finally { Stop-Chrome $securityChrome; Stop-SseReader $securityReader }
        } else { Add-Blocked 'A-SEC.typedSinksNoNetwork' 'typed malicious values create no external resource requests' 'Chrome is not installed; page/CDP Network observation cannot run' }
        # The server's eight-slot cap is tested from a clean listener with zero foreign viewers.
        foreach ($r in $raws) { Close-RawStream $r }; $raws.Clear()
        [void] (Wait-OverlayStreams $run 0 'capacityPreviousReadersClosed')
        $streamsBefore = Get-Overlay (Get-State $run.Root 'streams0b') 'streams'
        for ($i = 0; $i -lt 8; $i++) { $raws.Add((Open-RawStream)) }
        [void] (Wait-OverlayStreams $run 8 'capacityEightAdmitted')
        $ninth = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/events')
        $responses.Add($ninth)
        Add-Check 'A-SEC.ninthStream503' '0 streams before; 8 streams open (200), the 9th gets 503 from the app' ([ordered]@{
            streamsBefore = $streamsBefore; opened = $raws.Count; open = @($raws | ForEach-Object { $_.Status }); ninth = $ninth.status; origin = $ninth.origin }) (
            $streamsBefore -eq 0 -and $raws.Count -eq 8 -and
            -not ($raws | Where-Object { $_.Status -ne 200 }) -and $ninth.status -eq 503 -and $ninth.origin -eq 'app')
        Close-RawStream $raws[0]; $raws.RemoveAt(0)
        [void] (Wait-OverlayStreams $run 7 'capacityOneClosed')
        $again = Open-RawStream; $raws.Add($again)
        Add-Check 'A-SEC.ninthAfterCloseSucceeds' 'after one closes, the next stream gets 200' $again.Status ($again.Status -eq 200)
        foreach ($r in $raws) { $responses.Add([pscustomobject]@{ status = $r.Status; headers = $r.Headers; origin = if ($r.Headers.Contains('x-content-type-options')) { 'app' } else { 'kernel' } }) }
        $appResponses = @($responses | Where-Object { $_.origin -eq 'app' })
        $missing = @($appResponses | Where-Object { "$($_.headers['x-content-type-options'])" -ne 'nosniff' -or "$($_.headers['cache-control'])" -notmatch 'no-store' -or "$($_.headers['referrer-policy'])" -ne 'no-referrer' })
        Add-Check 'A-SEC.appHeadersEverywhere' 'nosniff, no-store, no-referrer on every app response' ([ordered]@{ appResponses = $appResponses.Count; missing = $missing.Count }) ($appResponses.Count -gt 0 -and $missing.Count -eq 0)
        $cors = @($responses | Where-Object { @($_.headers.Keys | Where-Object { $_ -like 'access-control-*' }).Count -gt 0 })
        Add-Check 'A-SEC.noAccessControlHeaders' 'no Access-Control-* on any response' $cors.Count ($cors.Count -eq 0)
        $nonHtmlCsp = @($appResponses | Where-Object { "$($_.headers['content-type'])" -notlike 'text/html*' -and $null -ne $_.headers['content-security-policy'] })
        Add-Check 'A-SEC.nonHtmlNoCsp' 'scripts, art, SSE and admission failures carry no CSP header' @($nonHtmlCsp) ($nonHtmlCsp.Count -eq 0)
    } finally {
        foreach ($r in $raws) { Close-RawStream $r }
        Stop-SseReader $previewReader; Stop-SseReader $newNonceReader; Stop-SseReader $lastReader
        Stop-OverlayRun $run
    }
    $scenarioResults['A-SEC'] = [ordered]@{ lanIPv4Present = [bool] (Get-LanIPv4); table = $table }
}

# ---------------------------------------------------------------------------------------------------------------
# A-RECON

function Wait-PageConnected($Chrome, [double] $Seconds) {
    Wait-For { $p = Get-PageProbe $Chrome; if ((Get-PageField $p 'connection') -eq 'open' -and (Get-PageField $p 'shown') -eq $true -and (Get-PageField $p 'state') -eq 'playing') { $p } } $Seconds 250
}
function Test-ARecon {
    if (-not (Test-ChromeAvailable 'A-RECON')) { return }
$optionsA = New-DefaultPillOptions; $optionsA['width'] = 320
    $lookA = New-ObsLook 'recn0001' 'Restart A' $optionsA
    $run = Start-OverlayRun 'A-RECON' @{ ObsOverlay = $false } 'Playing' -NoReader -LooksJson (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($lookA)))
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
        $lookUrl = "$($overlayUrl)?look=recn0001"
        [void] (Invoke-ChromeNavigate $chrome $lookUrl)
        $optionA = Wait-For {
            $p = Get-PageProbe $chrome; $look = Get-PageField $p 'look'
            if ((Get-Prop $look 'id') -eq 'recn0001' -and (Get-Prop (Get-Prop $look 'options') 'width') -eq 320) { $p }
        } 15 100
        Add-Check 'A-RECON.restartOptionsA' 'connected page begins on saved options A before file replacement' ([ordered]@{
            look = Get-PageField $optionA 'look'; epoch = Get-PageField $optionA 'lookEpoch'; seq = Get-PageField $optionA 'lookSeq' }) (
            $optionA -and (Get-Prop (Get-PageField $optionA 'look') 'id') -eq 'recn0001' -and
            (Get-Prop (Get-Prop (Get-PageField $optionA 'look') 'options') 'width') -eq 320)
        $epochA = Get-PageField $optionA 'lookEpoch'
        $optionsB = Copy-LookOptions $optionsA; $optionsB['width'] = 800
        $lookB = New-ObsLook 'recn0001' 'Restart B' $optionsB
        [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($lookB))))
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $reloadedB = Wait-For {
            $p = Get-PageProbe $chrome; $look = Get-PageField $p 'look'
            if ((Get-Prop $look 'id') -eq 'recn0001' -and (Get-Prop (Get-Prop $look 'options') 'width') -eq 800) { $p }
        } 15 100
        Add-Check 'A-RECON.restartLookFileReload' 'writing options B and command-obs-looks-reload live-pushes B before restart' ([ordered]@{
            look = Get-PageField $reloadedB 'look'; epoch = Get-PageField $reloadedB 'lookEpoch'; seq = Get-PageField $reloadedB 'lookSeq' }) (
            $reloadedB -and (Get-Prop (Get-Prop (Get-PageField $reloadedB 'look') 'options') 'width') -eq 800)
        # (2) server restart after the durable look-file reload.
        [void] (Send-HookCommand $run.Root 'command-obs-off')
        [void] (Wait-For { $pp = Get-PageProbe $chrome; (Get-PageField $pp 'connection') -ne 'open' } 5)
        $onQpc = Send-HookCommand $run.Root 'command-obs-on'
        $back = Wait-PageConnected $chrome 10
        $restartLook = Get-PageField $back 'look'
        Add-Check 'A-RECON.2.reconnectedWithin5s' 'page reconnected with state <= 5 s after the server is back' $(if ($back) { Round3 (Get-Seconds $onQpc $back.qpc) }) (
            $back -and (Get-Seconds $onQpc $back.qpc) -le 5)
        Add-Check 'A-RECON.restartEpochAndSeq' 'server epoch changes and first post-restart look sequence 1 is accepted with options B' ([ordered]@{
            epochA = $epochA; epochB = Get-PageField $back 'lookEpoch'; seq = Get-PageField $back 'lookSeq'
            width = Get-Prop (Get-Prop $restartLook 'options') 'width' }) (
            $back -and (Get-PageField $back 'lookEpoch') -cne $epochA -and (Get-PageField $back 'lookSeq') -eq 1 -and
            (Get-Prop $restartLook 'id') -eq 'recn0001' -and (Get-Prop (Get-Prop $restartLook 'options') 'width') -eq 800)
        # (3) no streams for 30 s while Playing, then reconnect.
        $obs['release3'] = Reset-ChromeCasePage $chrome
        $zero = Wait-OverlayStreams $run 0 'blank'
        Start-Sleep -Seconds 30
        $zeroAfterWait = Get-State $run.Root 'blankAfter30'
        if ((Get-Overlay $zeroAfterWait 'streams') -eq 0) { $zero = $zeroAfterWait }
        $navQpc = Get-Qpc
        [void] (Invoke-ChromeNavigate $chrome $overlayUrl)
        $initial = Wait-PageConnected $chrome 5
        Add-Check 'A-RECON.3.initialStateWithin2s' 'after 30 s without streams: initial state shown <= 2 s' ([ordered]@{
            streamsWhileAway = Get-Overlay $zero 'streams'; seconds = if ($initial) { Round3 (Get-Seconds $navQpc $initial.qpc) } }) (
            $zero -and $initial -and (Get-Seconds $navQpc $initial.qpc) -le 2)
        # (4) 9th stream 503 -> CLOSED -> retry after 30 s.
        $obs['release4'] = Reset-ChromeCasePage $chrome
        [void] (Wait-OverlayStreams $run 0 'blank2')
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

function Test-AThemeTextAndPause([string] $ScenarioName) {
    $themes = @('pill', 'matte', 'matte-light', 'standard', 'classic', 'simple', 'album-art', 'card')
    $looks = foreach ($i in 0..7) {
        $options = Get-ThemeDefaults $themes[$i]
        $options['paused'] = 'dim'
        New-ObsLook ('th{0:D6}' -f $i) "Theme $($themes[$i])" $options
    }
    $obs = [ordered]@{}
    foreach ($look in $looks) {
        $theme = $look.options.theme
        $profile = if ($ScenarioName -eq 'A-TEXT') { 'Text' } else { 'Paused' }
        $run = Start-OverlayRun "$ScenarioName-$theme" @{ ObsHidePaused = $false } $profile -NoReader `
            -LooksJson (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
        $chrome = $null
        try {
            $ready = Wait-BenchReady $run.Root
            $chrome = Start-Chrome "$ScenarioName-$theme"
            $expectedSize = Get-DefaultThemeSize $theme
            Set-OverlayViewport $chrome $expectedSize.source
            [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$($look.id)")
            $connected = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'connection') -eq 'open' -and
                (Get-Prop (Get-PageField $p 'look') 'id') -eq $look.id) { $p } } 15 100
            if ($ScenarioName -eq 'A-TEXT') {
                $longTitle = ('Fixture Long Title ' * 14).Substring(0, 249) + '!'
                $artist = [string]::new([char[]] @(0x97F3, 0x697D, 0x30C6, 0x30B9, 0x30C8, 0x20, 0x0627, 0x0644, 0x0641, 0x0646, 0x0627, 0x0646))
                $p = Wait-For { $q = Get-PageProbe $chrome; if ($q.title -ceq $longTitle) { $q } } 12 100
                $inside = $p -and @($p.titleRect, $p.artistRect | Where-Object { $_ -and $_.width -gt 0 } |
                    Where-Object { $_.x -lt $p.boxRect.x -or $_.x + $_.width -gt $p.boxRect.x + $p.boxRect.width -or
                        $_.y -lt $p.boxRect.y -or $_.y + $_.height -gt $p.boxRect.y + $p.boxRect.height }).Count -eq 0
                Add-Check "A-TEXT.$theme.literalAndEllipsis" 'CJK/RTL artist literal, long title ellipsis and both text rows contained' (
                    [ordered]@{ title = Get-Prop $p 'title'; artist = Get-Prop $p 'artist'; titleRect = Get-Prop $p 'titleRect'
                        artistRect = Get-Prop $p 'artistRect'; box = Get-Prop $p 'boxRect' }) (
                    $connected -and $p -and $p.artist -ceq $artist -and $p.titleEllipsis -eq $true -and $inside)
            } else {
                Start-Sleep -Milliseconds 1100
                $p = Get-PageProbe $chrome
                $before = Get-Prop (Get-PageField $p 'counters') 'fillWrites'
                Start-Sleep -Seconds 2
                $after = Get-PageProbe $chrome
                Add-Check "A-PAUSEVIEW.$theme.dimFrozen" 'saved paused:dim gives opacity .7, frozen progress, no timer or running animation' (
                    [ordered]@{ before = $p; after = $after }) (
                    $connected -and (Get-PageField $after 'shown') -eq $true -and
                    [Math]::Abs([double] $after.opacity - 0.7) -le 0.02 -and $after.running -eq 0 -and
                    (Get-PageField $after 'fillTimer') -eq 0 -and
                    [Math]::Abs([double] $p.frac - [double] $after.frac) -le 0.001 -and
                    $before -eq (Get-Prop (Get-PageField $after 'counters') 'fillWrites'))
            }
            Add-Check "$ScenarioName.$theme.viewport" 'native source viewport shows the entire box without clipping' (
                [ordered]@{ expected = $expectedSize.source; actual = $p.pageSize; box = $p.boxRect }) (
                (Test-OverlayViewport $p $expectedSize.source))
            $obs[$theme] = [ordered]@{ connected = [bool] $connected; page = $p }
        } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
    }
    $scenarioResults["$ScenarioName.themes"] = $obs
}

function Test-AText {
    if (-not (Test-ChromeAvailable 'A-TEXT')) { return }
    $obs = [ordered]@{}
    Test-AThemeTextAndPause 'A-TEXT'
    $longTitle = ('Fixture Long Title ' * 14).Substring(0, 249) + '!'
    $artist = [string]::new([char[]] @(0x97F3, 0x697D, 0x30C6, 0x30B9, 0x30C8, 0x20, 0x0627, 0x0644, 0x0641, 0x0646, 0x0627, 0x0646))
    $run = Start-OverlayRun 'A-TEXT-text' @{} 'Text'
    $chrome = $null
    try {
        $initial = Wait-Initial $run ''   # the Text profile's songs are not the default A/B/C titles: accept its first playing event
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
    # Artwork is now served by the app as /art/<key>: the last two entries by start are the delayed A then the immediate B.
    $artEntries = @($p.art | Sort-Object { [double] $_.start })
    $a = if ($artEntries.Count -ge 2) { $artEntries[$artEntries.Count - 2] }
    $b = if ($artEntries.Count -ge 2) { $artEntries[$artEntries.Count - 1] }
    Add-Check 'A-TEXT.artSwapFinalB' 'delayed A completes after B, but the latest load (B) is applied: artLoadedSeq == artSeq, no failure' ([ordered]@{
        artSeq = Get-PageField $p 'artSeq'; artLoadedSeq = Get-PageField $p 'artLoadedSeq'; artFailed = Get-PageField $p 'artFailed'
        aEnd = if ($a) { $a.end }; bEnd = if ($b) { $b.end }; fixtureArtServed = Get-Overlay $s 'fixtureArtServed' }) (
        $a -and $b -and [double] $a.start -lt [double] $b.start -and [double] $a.end -gt [double] $b.end -and
        (Get-PageField $p 'artSeq') -eq (Get-PageField $p 'artLoadedSeq') -and (Get-PageField $p 'artFailed') -eq $false)
    $scenarioResults['A-TEXT'] = $obs
}

# ---------------------------------------------------------------------------------------------------------------
# A-ART

function Test-AArt {
    # ArtGap: 0 s art A (fixture-a) -> 12 s the page's art fails to load ("missing") -> 24 s track B (art A again) -> 40 s a loadable
    # image with a 300-character URL, which the fixture fetcher seam answers with a failed fetch (the real fetcher would time out or reject).
    $run = Start-OverlayRun 'A-ART' @{} 'ArtGap'
    $r = [ordered]@{}
    try {
        $initial = Wait-Initial $run
        $start = Get-PageStartQpc $initial
        $good = Wait-SseData $run.Reader { param($d) "$(Get-Prop $d 'artwork')" -match '^/art/[0-9a-f]{16}$' } 20
        $k1 = if ($good) { [string] (Get-Prop $good.data 'artwork') } else { $null }
        $second = if ($k1) { Wait-SseData $run.Reader { param($d) "$(Get-Prop $d 'artwork')" -match '^/art/[0-9a-f]{16}$' -and "$(Get-Prop $d 'artwork')" -cne $k1 } 70 } else { $null }
        $k2 = if ($second) { [string] (Get-Prop $second.data 'artwork') } else { $null }
        $missing = @(Get-DataEvents (Read-Sse $run.Reader) | Where-Object {
            (Get-Prop $_.data 'state') -in @('playing', 'paused') -and $null -eq (Get-Prop $_.data 'artwork') -and
            (Get-PageTime $_.qpc $start) -ge 10 -and (Get-PageTime $_.qpc $start) -le 26 })
        Add-Check 'A-ART.missingArtNeverPublished' 'while the page image fails to load (page 10..26 s) the stream carries artwork null, never the failing URL' @($missing | ForEach-Object { Get-EventSummary $_ $start }) ($missing.Count -ge 1)
        Add-Check 'A-ART.twoKeys' 'the stream advertised two different /art/<16 hex> keys (good art, then the failing one)' ([ordered]@{ first = $k1; second = $k2 }) ([bool] $k1 -and [bool] $k2 -and $k1 -cne $k2)
        if ($k1 -and $k2) {
            $g1 = Invoke-RawHttp '127.0.0.1' (New-Request -Path $k1)
            $s1 = Get-State $run.Root 'served1'
            $b1 = Invoke-RawHttp '127.0.0.1' (New-Request -Path $k2)
            $b2 = Invoke-RawHttp '127.0.0.1' (New-Request -Path $k2)
            $g2 = Invoke-RawHttp '127.0.0.1' (New-Request -Path $k1)
            $s2 = Get-State $run.Root 'served2'
            $goodOk = { param($x) $x.status -eq 200 -and "$($x.headers['content-type'])" -like 'image/png*' -and $x.body.Length -ge 4 -and $x.body.Substring(1, 3) -ceq 'PNG' }
            Add-Check 'A-ART.goodKeyServed' 'the good key answers 200 image/png, before and after the failing one' ([ordered]@{ first = $g1.status; again = $g2.status }) ((& $goodOk $g1) -and (& $goodOk $g2))
            $failOk = { param($x) $x.status -eq 502 -and $x.origin -eq 'app' -and $x.body.Length -eq 0 -and "$($x.headers['content-type'])" -notlike 'image/*' -and
                "$($x.headers['cache-control'])" -like '*no-store*' -and "$($x.headers['x-content-type-options'])" -eq 'nosniff' }
            Add-Check 'A-ART.failedFetch502' 'the failing key answers 502 with no body or image type (twice: the retry window still answers 502)' ([ordered]@{
                first = $b1.status; again = $b2.status; contentType = "$($b1.headers['content-type'])" }) ((& $failOk $b1) -and (& $failOk $b2))
            $served1 = Get-Overlay $s1 'fixtureArtServed'; $served2 = Get-Overlay $s2 'fixtureArtServed'
            Add-Check 'A-ART.failureNotCounted' 'fixtureArtServed counts successful serves only: +1 for the second good GET, +0 for the two 502s' ([ordered]@{
                afterFirstGood = $served1; afterFailuresAndSecondGood = $served2 }) ($null -ne $served1 -and [int] $served1 -ge 1 -and [int] $served2 -eq [int] $served1 + 1)
        }
        $r['keys'] = [ordered]@{ first = $k1; second = $k2 }
    } finally { Stop-OverlayRun $run }
    $scenarioResults['A-ART'] = $r
}

# ---------------------------------------------------------------------------------------------------------------
# A-SET

$obsIds = @('ObsNavItem', 'ObsPreviewNotice', 'ObsOverlayCheckBox', 'ObsDisclosureText', 'ObsHidePausedCheckBox', 'ObsLinkTextBox', 'ObsCopyLinkButton', 'ObsCopyLinkResult',
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
function Test-OverlayCssSyntax([string] $Html) {
    $styles = [regex]::Matches($Html, '(?is)<style\b[^>]*>(.*?)</style>')
    $violations = [Collections.Generic.List[string]]::new()
    $properties = [Collections.Generic.List[string]]::new()
    $selectors = [Collections.Generic.List[string]]::new()
    $functions = [Collections.Generic.List[string]]::new()
    $atRules = [Collections.Generic.List[string]]::new()
    if ($styles.Count -eq 0) {
        $violations.Add('missing inline style block')
        return [ordered]@{ styles = 0; properties = @(); selectors = @(); functions = @(); atRules = @(); violations = @($violations); passed = $false }
    }
    $css = (@($styles | ForEach-Object { $_.Groups[1].Value }) -join "`n")
    $css = [regex]::Replace($css, '(?s)/\*.*?\*/', '')
    $forbidden = [regex]::Matches($css, '(?i)&|@layer\b|@scope\b|@container\b|:has\s*\(|color-mix\s*\(')
    foreach ($match in $forbidden) { $violations.Add("forbidden syntax: $($match.Value)") }
    $allowedProperties = @(
        'position','left','right','top','bottom','width','height','min-width','max-width','margin','padding','gap',
        'display','flex','flex-direction','flex-grow','flex-shrink','justify-content','align-items','align-self',
        'color','background','background-color','background-image','border-radius','box-shadow','opacity','transform',
        'overflow','overflow-x','overflow-y','font-family','font-size','font-weight','font-variant-numeric',
        'text-align','text-shadow','white-space','text-overflow','line-height','object-fit','object-position',
        'unicode-bidi','animation','animation-name','animation-duration','animation-timing-function','animation-fill-mode'
    )
    $allowedFunctions = @('calc','var','rgba','linear-gradient','translateX','translateY')
    foreach ($match in [regex]::Matches($css, '@([A-Za-z-]+)')) {
        $name = '@' + $match.Groups[1].Value
        $atRules.Add($name)
        if ($name -cne '@keyframes') { $violations.Add("disallowed at-rule: $name") }
    }
    $keyframesRemoved = [regex]::Replace($css, '(?is)@keyframes\s+[\w-]+\s*\{(?:[^{}]|\{[^{}]*\})*\}', '')
    if ($keyframesRemoved -match '\{[^{}]*\{') { $violations.Add('nested CSS rule') }
    $open = ([regex]::Matches($css, '\{')).Count; $close = ([regex]::Matches($css, '\}')).Count
    if ($open -ne $close) { $violations.Add("unbalanced braces: $open open / $close close") }
    foreach ($rule in [regex]::Matches($css, '(?s)([^{}]+)\{([^{}]*)\}')) {
        $header = $rule.Groups[1].Value.Trim()
        if (-not $header) { continue }
        $isKeyframeStep = $header -match '^(from|to|(?:100|[0-9]{1,2})(?:\.[0-9]+)?%)$'
        if (-not $isKeyframeStep) {
            foreach ($selector in ($header -split ',')) {
                $selector = $selector.Trim()
                $selectors.Add($selector)
                if ($selector -match '\.[A-Za-z_-]' -or $selector -match '[>+~&]' -or $selector -match ':(?!empty\b|root\b)[A-Za-z-]+' -or
                    $selector -notmatch '^[A-Za-z0-9_#:\[\]=""''\-%\s]+$') {
                    $violations.Add("selector outside allowlist: $selector")
                }
            }
        }
        foreach ($declaration in ($rule.Groups[2].Value -split ';')) {
            if (-not $declaration.Trim()) { continue }
            $colon = $declaration.IndexOf(':')
            if ($colon -le 0) { $violations.Add("invalid declaration: $($declaration.Trim())"); continue }
            $property = $declaration.Substring(0, $colon).Trim().ToLowerInvariant()
            $value = $declaration.Substring($colon + 1).Trim()
            $properties.Add($property)
            if ($property -notin $allowedProperties -and $property -notmatch '^--[a-z0-9-]+$') { $violations.Add("property outside allowlist: $property") }
            foreach ($fn in [regex]::Matches($value, '\b([A-Za-z][A-Za-z0-9-]*)\s*\(')) {
                $function = $fn.Groups[1].Value
                $functions.Add($function)
                if ($function -cnotin $allowedFunctions) { $violations.Add("value function outside allowlist: $function") }
            }
        }
    }
    [ordered]@{ styles = $styles.Count; properties = @($properties | Select-Object -Unique); selectors = @($selectors | Select-Object -Unique)
        functions = @($functions | Select-Object -Unique); atRules = @($atRules | Select-Object -Unique)
        violations = @($violations); passed = $violations.Count -eq 0 }
}
function Find-ForbiddenJsSinks([string] $JavaScript) {
    $sinks = @('innerHTML', 'outerHTML', 'insertAdjacentHTML', 'document.write', 'cssText', 'insertRule', 'eval(', 'new Function')
    $found = [Collections.Generic.List[string]]::new()
    foreach ($sink in $sinks) { if ($JavaScript.Contains($sink)) { $found.Add($sink) } }
    $found.ToArray()
}
function Test-AProd {
    if (-not (Test-Path -LiteralPath $releaseExe -PathType Leaf)) { throw "Release build not found at $releaseExe." }
    $releaseGuideUrl = 'https://github.com/Hantu-Raya/Nativune/blob/main/docs/obs-overlay.md'
    $scan = [ordered]@{}; $guideFound = [System.Collections.Generic.List[string]]::new()
    $files = @(Get-ChildItem -LiteralPath $releaseDirectory -File | Where-Object { $_.Name -like 'Nativune*.dll' -or $_.Name -like 'Nativune*.pri' -or $_.Name -like '*.resources.dll' })
    foreach ($f in $files) {
        $bytes = [IO.File]::ReadAllBytes($f.FullName)
        foreach ($needle in @('launched-uri', 'command-obs', 'command-controls', 'fixture-art', 'NATIVUNE_TEST_OBS_')) {
            if ((Find-Bytes $bytes ([Text.Encoding]::UTF8.GetBytes($needle))) -or (Find-Bytes $bytes ([Text.Encoding]::Unicode.GetBytes($needle)))) {
                $scan["$($f.Name):$needle"] = $true
            }
        }
        if ((Find-Bytes $bytes ([Text.Encoding]::UTF8.GetBytes($releaseGuideUrl))) -or (Find-Bytes $bytes ([Text.Encoding]::Unicode.GetBytes($releaseGuideUrl)))) {
            $guideFound.Add($f.Name)
        }
    }
    Add-Check 'A-PROD.assemblyStringScan' 'release Nativune.dll/resources contain no test-hook markers/commands in UTF-8 or UTF-16' ([ordered]@{
        files = @($files | ForEach-Object { $_.Name }); hits = @($scan.Keys) }) ($files.Count -gt 0 -and $scan.Count -eq 0 -and ($files | Where-Object { $_.Name -eq 'Nativune.dll' }))
    Add-Check 'A-PROD.guideUrlInAssembly' "release assembly/resources contain $releaseGuideUrl (UTF-8 or UTF-16; button not clicked)" ([ordered]@{
        foundIn = @($guideFound) }) ($guideFound.Count -gt 0)
    $root = New-Root 'A-PROD'
    Write-Settings $root @{ ObsOverlay = $true }
$releaseReaders = [Collections.Generic.List[object]]::new()
    $app = $null; $obs = [ordered]@{}
    try {
        $app = Start-App $root @{} $releaseExe
        $page = Wait-For { $x = Invoke-RawHttp '127.0.0.1' (New-Request); if ($x.status -eq 200) { $x } } 90 1000
        if (-not $page) { throw 'A-PROD: release overlay page never answered.' }
        $art = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/fixture-art/a.png')
        Add-Check 'A-PROD.fixtureArt404' '/fixture-art/a.png -> 404' $art.status ($art.status -eq 404)
        $artKey = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/art/0000000000000000')
        Add-Check 'A-PROD.unknownArtKey404' '/art/0000000000000000 -> 404 from the app (no key registered without a published song)' ([ordered]@{ status = $artKey.status; origin = $artKey.origin }) ($artKey.status -eq 404 -and $artKey.origin -eq 'app')
        $csp = "$($page.headers['content-security-policy'])"
        $imgSrc = ([regex]::Match($csp, "img-src[^;]*")).Value.Trim()
        Add-Check 'A-PROD.cspSelfImagesOnly' "CSP img-src is exactly 'self' (no Google host)" $imgSrc ($imgSrc -ceq "img-src 'self'" -and $csp -notmatch 'googleusercontent|ytimg|ggpht')
        $js = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/overlay.js')
        Add-Check 'A-PROD.scriptNoFixtureArt' 'served /overlay.js has no fixture-art (and no __state hook)' ([ordered]@{ status = $js.status; length = $js.body.Length }) (
            $js.status -eq 200 -and $js.body.Length -gt 0 -and $js.body -notmatch 'fixture-art' -and $js.body -notmatch '__state')
        $unknownRoute = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/?look=unknown1')
        $draftRoute = Invoke-RawHttp '127.0.0.1' (New-Request -Path '/?look=draft')
        $unknownReader = Start-SseReader 'A-PROD-unknown-look' 20 '/events?look=unknown1'
        $draftReader = Start-SseReader 'A-PROD-draft-look' 20 '/events?look=draft'
        $releaseReaders.Add($unknownReader); $releaseReaders.Add($draftReader)
        $unknownLook = Wait-SseLook $unknownReader { param($m) (Get-Prop $m 'id') -eq 'unknown1' } 15
        $draftLook = Wait-SseLook $draftReader { param($m) (Get-Prop $m 'id') -eq 'draft' } 15
        Add-Check 'A-PROD.fallbackLookRoutes' 'release /?look=<unknown> and /?look=draft are 200; both streams use pill with missing=true' ([ordered]@{
            unknownPage = $unknownRoute.status; draftPage = $draftRoute.status
            unknown = Get-Prop $unknownLook 'data'; draft = Get-Prop $draftLook 'data' }) (
            $unknownRoute.status -eq 200 -and $draftRoute.status -eq 200 -and
            $unknownLook -and $draftLook -and
            (Get-Prop $unknownLook.data 'missing') -eq $true -and (Get-Prop $draftLook.data 'missing') -eq $true -and
            (Get-Prop $unknownLook.data 'theme') -eq 'pill' -and (Get-Prop $draftLook.data 'theme') -eq 'pill')
        $cssLint = Test-OverlayCssSyntax $page.body
        Add-Check 'A-PROD.cssLint' 'served stylesheet uses only allowlisted properties, at-rules, selectors and value functions; no nesting/forbidden syntax' $cssLint (
            $cssLint.passed -eq $true -and $cssLint.violations.Count -eq 0)
        $sinks = @(Find-ForbiddenJsSinks $js.body)
        Add-Check 'A-PROD.forbiddenSinks' 'served /overlay.js contains no HTML parser, cssText/insertRule or dynamic-code sinks' $sinks ($js.status -eq 200 -and $sinks.Count -eq 0)
        $ui = Open-ObsSettings $app
        # The "How to set up…" button is deliberately not clicked: in the release build it opens the owner's real
        # default browser. The guide URL is verified statically by A-PROD.guideUrlInAssembly above.
        $obs['shot'] = Save-WindowShot $ui.Hwnd 'A-PROD-settings-obs'
        Close-Settings $ui 'CancelButton'
    } finally { foreach ($reader in $releaseReaders) { Stop-SseReader $reader }; Stop-App $app $root -Kill; Copy-AppLog $root 'A-PROD' }
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
    Test-AThemeTextAndPause 'A-PAUSEVIEW'
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
# A-TOOLBAR

# Window-scoped capture (Save-WindowShot); counts recording-red pixels (R>180, G<80, B<80) in the top-left quarter of the
# button's UIA rectangle. Returns @{ count; shot } or $null when the window or capture is unavailable.
function Get-ObsButtonRedPixels($Process, $Button, [string] $ShotName) {
    $hwnd = [ObsE2E]::Find([uint32] $Process.Id, $null)
    if ($hwnd -eq [IntPtr]::Zero) { return $null }
    $rel = Save-WindowShot $hwnd $ShotName
    if (-not $rel) { return $null }
    $frame = New-Object ObsE2E+RECT; [void] [ObsE2E]::DwmGetWindowAttribute($hwnd, 9, [ref] $frame, 16)
    $r = $Button.Current.BoundingRectangle
    $left = [int] [Math]::Floor($r.X - $frame.Left); $top = [int] [Math]::Floor($r.Y - $frame.Top)
    $width = [int] [Math]::Ceiling($r.Width / 2); $height = [int] [Math]::Ceiling($r.Height / 2)
    $bmp = [System.Drawing.Bitmap]::new((Join-Path $runDirectory $rel))
    try {
        $count = 0
        for ($y = [Math]::Max(0, $top); $y -lt [Math]::Min($bmp.Height, $top + $height); $y++) {
            for ($x = [Math]::Max(0, $left); $x -lt [Math]::Min($bmp.Width, $left + $width); $x++) {
                $c = $bmp.GetPixel($x, $y)
                if ($c.R -gt 180 -and $c.G -lt 80 -and $c.B -lt 80) { $count++ }
            }
        }
    } finally { $bmp.Dispose() }
    [pscustomobject]@{ count = $count; shot = $rel; region = "x=$left y=$top w=$width h=$height" }
}
function Get-ObsSavedFlag([string] $Root) { try { Get-Prop (Read-SavedSettings $Root) 'ObsOverlay' } catch { $null } }
function Get-ObsPortProbe { Invoke-RawHttp '127.0.0.1' (New-Request) }

function Test-AToolbar {
    $obs = [ordered]@{}
    $root = New-Root 'A-TOOLBAR'
    Write-Settings $root @{ ObsOverlay = $false }
    $bench = @{ NATIVUNE_TEST_DISCORD_BENCH_PROFILE = 'Playing'; NATIVUNE_TEST_DISCORD_BENCH_STATE = 'Full' }
    $app = $null
    try {
        $app = Start-App $root $bench
        [void] (Wait-BenchReady $root)
        $mainHwnd = Wait-For { $h = [ObsE2E]::Find([uint32] $app.Id, $null); if ($h -ne [IntPtr]::Zero) { $h } } 60 300
        if (-not $mainHwnd -or $mainHwnd -eq [IntPtr]::Zero) { throw 'Main window not found.' }
        $main = $AE::FromHandle($mainHwnd)
        $button = Find-Element $main 'AutomationId' 'ObsButton' 30
        Add-Check 'A-TOOLBAR.buttonFound' 'ObsButton found by AutomationId through UI Automation' (Describe $button) ([bool] $button)
        if (-not $button) { return }

        # 1. Off at launch: name, no listener, no red dot.
        $probe = Get-ObsPortProbe
        $red = Get-ObsButtonRedPixels $app $button 'A-TOOLBAR-1-off'
        Add-Check 'A-TOOLBAR.off.name' 'name "OBS overlay: off"' $button.Current.Name ($button.Current.Name -eq 'OBS overlay: off')
        Add-Check 'A-TOOLBAR.off.noListener' 'no 200 on http://localhost:47813/' ([ordered]@{ origin = $probe.origin; status = $probe.status }) ($probe.status -ne 200)
        Add-Check 'A-TOOLBAR.off.noRedDot' 'no red pixels in the top-left quarter of the button' $red ($null -ne $red -and $red.count -eq 0)

        # 2. First invoke: on within 5 s.
        $t0 = [DateTime]::UtcNow
        Invoke-Element $button
        $on200 = Wait-For { $p = Get-ObsPortProbe; if ($p.status -eq 200 -and $p.origin -eq 'app') { $p } } 5 200
        $onSaved = Wait-For { if ((Get-ObsSavedFlag $root) -eq $true) { $true } } 5 200
        $onName = Wait-For { $n = $button.Current.Name; if ($n -like 'OBS overlay: on*') { $n } } 5 200
        $onRed = Wait-For { $r = Get-ObsButtonRedPixels $app $button 'A-TOOLBAR-2-on'; if ($r -and $r.count -ge 6) { $r } } 5 300
        if (-not $onRed) { $onRed = Get-ObsButtonRedPixels $app $button 'A-TOOLBAR-2-on' }
        Add-Check 'A-TOOLBAR.on.port200' '200 on the port within 5 s of the invoke' ([ordered]@{ status = Get-Prop $on200 'status'; origin = Get-Prop $on200 'origin' }) ([bool] $on200)
        Add-Check 'A-TOOLBAR.on.persisted' 'settings.json has ObsOverlay=true within 5 s' (Get-ObsSavedFlag $root) ([bool] $onSaved)
        Add-Check 'A-TOOLBAR.on.name' 'name starts "OBS overlay: on"' $onName ([bool] $onName)
        Add-Check 'A-TOOLBAR.on.redDot' 'red pixels (R>180, G<80, B<80) in the top-left quarter of the button' $onRed ($null -ne $onRed -and $onRed.count -ge 6)
        $obs['on'] = [ordered]@{ name = $onName; redPixels = Get-Prop $onRed 'count'; shot = Get-Prop $onRed 'shot'; helpText = $button.Current.HelpText }

        # 3. Second invoke: off within 5 s.
        Invoke-Element $button
        $off = Wait-For { $p = Get-ObsPortProbe; if ($p.status -ne 200) { $p } } 5 200
        $offSaved = Wait-For { if ((Get-ObsSavedFlag $root) -eq $false) { $true } } 5 200
        $offName = Wait-For { $n = $button.Current.Name; if ($n -eq 'OBS overlay: off') { $n } } 5 200
        $offRed = Wait-For { $r = Get-ObsButtonRedPixels $app $button 'A-TOOLBAR-3-off'; if ($r -and $r.count -eq 0) { $r } } 5 300
        if (-not $offRed) { $offRed = Get-ObsButtonRedPixels $app $button 'A-TOOLBAR-3-off' }
        Add-Check 'A-TOOLBAR.off2.portStops' 'port stops answering within 5 s of the second invoke' ([ordered]@{ origin = Get-Prop $off 'origin'; status = Get-Prop $off 'status' }) ([bool] $off)
        Add-Check 'A-TOOLBAR.off2.persisted' 'settings.json has ObsOverlay=false' (Get-ObsSavedFlag $root) ([bool] $offSaved)
        Add-Check 'A-TOOLBAR.off2.name' 'name "OBS overlay: off"' $offName ($offName -eq 'OBS overlay: off')
        Add-Check 'A-TOOLBAR.off2.noRedDot' 'no red pixels remain' $offRed ($null -ne $offRed -and $offRed.count -eq 0)

        # 4. Five quick invokes (off -> on -> off -> on -> off -> on): the end state matches the persisted setting (on) and
        # exactly one listener answers: one HTTP 200, net "[obs] on" minus "[obs] off" log lines is 1 (a second server would
        # add an extra "on" or a bind failure), and another process cannot register the prefix.
        1..5 | ForEach-Object { Invoke-Element $button }
        $burstSaved = Wait-For { if ((Get-ObsSavedFlag $root) -eq $true) { $true } } 5 200
        $burst200 = Wait-For { $p = Get-ObsPortProbe; if ($p.status -eq 200 -and $p.origin -eq 'app') { $p } } 5 200
        $burstName = Wait-For { $n = $button.Current.Name; if ($n -like 'OBS overlay: on*') { $n } } 5 200
        $script:obsNet = $null
        $settled = Wait-For {
            $lines = @(Get-ObsLogLines $root)
            $onLines = @($lines | Where-Object { $_ -match '\[obs\] on$' }).Count
            $offLines = @($lines | Where-Object { $_ -match '\[obs\] off$' }).Count
            $failed = @($lines | Where-Object { $_ -match '\[obs\] bind (PrefixInUse|AccessDenied|Failed)' }).Count
            $script:obsNet = [ordered]@{ on = $onLines; off = $offLines; bindFailures = $failed }
            if (($onLines - $offLines) -eq 1) { $true }
        } 5 250
        $net = $script:obsNet
        Start-Sleep -Milliseconds 500
        $stable = Get-ObsPortProbe
        $held = -not (Test-PrefixRegistrable)
        $burstRed = Get-ObsButtonRedPixels $app $button 'A-TOOLBAR-4-burst'
        Add-Check 'A-TOOLBAR.burst.persisted' 'five quick invokes end on: settings.json ObsOverlay=true' (Get-ObsSavedFlag $root) ([bool] $burstSaved)
        Add-Check 'A-TOOLBAR.burst.endState' 'name "OBS overlay: on…", 200 on the port and the red dot shown, matching the persisted setting' ([ordered]@{
            name = $burstName; status = Get-Prop $burst200 'status'; redPixels = Get-Prop $burstRed 'count' }) (
            [bool] $burstName -and [bool] $burst200 -and $null -ne $burstRed -and $burstRed.count -ge 6)
        Add-Check 'A-TOOLBAR.burst.oneListener' 'exactly one listener: one 200, on-off log lines = 1, no bind failure, prefix held' ([ordered]@{
            net = $net; settled = [bool] $settled; status = $stable.status; prefixHeld = $held }) (
            [bool] $settled -and $net.bindFailures -eq 0 -and $stable.status -eq 200 -and $held)
        $obs['burst'] = [ordered]@{ log = $net; redPixels = Get-Prop $burstRed 'count'; shot = Get-Prop $burstRed 'shot' }
    } finally {
        Stop-App $app $root; Copy-AppLog $root 'A-TOOLBAR'
        $scenarioResults['A-TOOLBAR'] = $obs
    }
}

function Save-FrameRecord([string] $Label, $Record) {
    $path = Join-Path $runDirectory "frames-$(ConvertTo-SafeName $Label).json"
    [IO.File]::WriteAllText($path, (ConvertTo-Json -InputObject $Record -Depth 12), [Text.UTF8Encoding]::new($false))
    [IO.Path]::GetRelativePath($runDirectory, $path)
}
# Page-initiated requests must be /, /overlay.js, /events or /art on the overlay origin. Chrome's own same-origin
# /favicon.ico probe (the page links no icon; the server answers 404; OBS's CEF source does not fetch favicons) is
# browser-initiated, so it is reported separately and never counted as page traffic.
function Get-UnexpectedOverlayRequests($Resources) {
    @($Resources | Where-Object { $_.origin -ne 'http://localhost:47813' -or
        ($_.path -notmatch '^/(?:$|overlay\.js$|events$|art/(?:[0-9a-f]{16}|sample)$)' -and $_.path -cne '/favicon.ico') })
}
function Test-FrameNetwork([string] $Theme) {
    $id = 'net' + ('{0:D5}' -f [Array]::IndexOf(@('pill', 'matte', 'matte-light', 'standard', 'classic', 'simple', 'album-art', 'card'), $Theme))
    $look = New-ObsLook $id "Network $Theme" (Get-ThemeDefaults $Theme)
    $run = Start-OverlayRun "A-FRAMES-network-$Theme" @{} $null -NoReader -LooksJson (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
    $chrome = $null
    try {
        $chrome = Start-Chrome $run.Name
        $expectedSize = Get-DefaultThemeSize $Theme
        Set-OverlayViewport $chrome $expectedSize.source
        [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$id&sample=playing")
        [void] (Wait-PageConnected $chrome 15)
        Start-Sleep -Milliseconds 1500
        $page = Get-PageProbe $chrome
        $requests = @($page.resources)
        $unexpected = @(Get-UnexpectedOverlayRequests $requests)
        $ok = $page.art.Count -gt 0 -and $unexpected.Count -eq 0 -and (Test-OverlayViewport $page $expectedSize.source)
        Add-Check "A-FRAMES.network.$Theme" 'all resource requests are only /, /overlay.js, /events or /art on localhost' (
            [ordered]@{ resources = $requests; unexpected = $unexpected; art = $page.art }) $ok
        return [ordered]@{ resources = $requests; unexpected = $unexpected }
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
}
function Test-FramePlaying([string] $Label, $Options, [double] $Rate, [string] $Condition, $Size, [int] $Seconds) {
    $id = 'frm' + [guid]::NewGuid().ToString('N').Substring(0, 5)
    $isSample = $Condition -in @('sample-art', 'no-art')
    $run = Start-OverlayRun "A-FRAMES-$Label" @{} $(if ($isSample) { $null } else { 'PlayingLong' }) -NoReader `
        -LooksJson (ConvertTo-ObsLooksJson (New-ObsLooksDocument @((New-ObsLook $id "Frames $($Options.theme)" $Options))))
    $chrome = $null; $trace = $null; $record = $null; $readHeld = $false; $holdQpc = $null; $fixtureSetup = $null
    $fastPixel = $GateProfile -eq 'Fast-v2' -and $Condition -eq 'pixel-only'
    $syntheticMetadata = $Condition -in @('long-sample-art', 'long-no-art') -or $fastPixel
    $testFrameAnchor = {
        param($p)
        (Get-PageField $p 'connection') -eq 'open' -and (Get-PageField $p 'state') -eq 'playing' -and
            (Get-PageField $p 'shown') -eq $true -and (Get-Prop (Get-PageField $p 'look') 'id') -eq $id -and
            $p.nativeFixture.duration -eq 14400 -and $p.nativeFixture.rate -eq $Rate -and $p.nativeFixture.clock -eq $true
    }
    try {
        [void] (Wait-BenchReady $run.Root -BenchProfile $(if ($isSample) { $null } else { 'PlayingLong' }))
        if ($Condition -eq 'fixture-max') { [void] (Send-ObsHookCommand $run.Root 'command-obs-fixture-art' 'fixture-max') }
        if ($Condition -eq 'long-text') { [void] (Send-ObsHookCommand $run.Root 'command-obs-fixture-text-long') }
        if (-not $isSample -and $Rate -ne 1) { [void] (Send-ObsHookCommand $run.Root 'command-obs-fixture-rate' "$Rate") }
        $chrome = Start-Chrome $run.Name
        Set-OverlayViewport $chrome $Size.source
        $query = "?look=$id" + $(if ($Condition -eq 'no-art') { '&sample=noart' } elseif ($isSample) { '&sample=playing' } else { '' })
        [void] (Invoke-ChromeNavigate $chrome ($overlayUrl + $query))
        $connected = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'connection') -eq 'open' -and
            (Get-PageField $p 'state') -eq 'playing' -and (Get-PageField $p 'shown') -eq $true -and
            (Get-Prop (Get-PageField $p 'look') 'id') -eq $id -and
            (-not $syntheticMetadata -or (& $testFrameAnchor $p))) { $p } } 15 250
        if (-not $connected) { throw "Frame page $Label never acknowledged its connected playing look/rate/duration/clock state" }
        if ($syntheticMetadata) {
            # Hold the acknowledged PlayingLong anchor, not a stale rate=1 snapshot.
            $readHeld = $true
            $holdQpc = Send-ObsHookCommand $run.Root 'command-obs-hold-read'
            # Drain already queued data/look/art delivery before the one-shot substitution.
            $drain = @{ signature = $null; stableSince = 0; probes = 0 }
            $drained = Wait-For {
                $p = Get-PageProbe $chrome; $drain.probes++
                $signature = ConvertTo-Json -Compress -InputObject @(
                    (Get-PageField $p 'receivedAt'), (Get-PageField $p 'lookReceivedAt'),
                    (Get-PageField $p 'lookEpoch'), (Get-PageField $p 'lookSeq'),
                    (Get-PageField $p 'artSeq'), (Get-PageField $p 'artLoadedSeq'),
                    (Get-Prop (Get-PageField $p 'counters') 'coverLoads'), @($p.art).Count)
                if (-not (& $testFrameAnchor $p) -or $signature -cne $drain.signature -or
                    (Get-PageField $p 'artSeq') -ne (Get-PageField $p 'artLoadedSeq')) {
                    $drain.signature = $signature; $drain.stableSince = $p.pageNow
                } elseif ([double] $p.pageNow - [double] $drain.stableSince -ge 1000) { $p }
            } 10 100
            if (-not $drained) { throw "Frame page $Label did not settle queued delivery while its reader was held" }
            # Keep PlayingLong's 14,400 s duration, clock, position and native rate.
            $expectedArt = if ($Condition -eq 'long-sample-art') { '/art/sample' } else { $null }
            $testSyntheticFixture = {
                param($p)
                $cover = Get-Prop (Get-PageField $p 'raster') 'cover'
                (& $testFrameAnchor $p) -and (Get-PageField $p 'id') -eq (Get-PageField $connected 'id') -and
                    $p.title -ceq 'Sample song' -and $p.artist -ceq 'Sample artist' -and
                    (Get-PageField $p 'title') -ceq 'Sample song' -and (Get-PageField $p 'artist') -ceq 'Sample artist' -and
                    $p.nativeFixture.requestedArt -ceq $expectedArt -and $p.nativeFixture.loadedArt -ceq $expectedArt -and
                    (Get-PageField $p 'artSeq') -ge 1 -and
                    (Get-PageField $p 'artSeq') -eq (Get-PageField $p 'artLoadedSeq') -and
                    $(if ($expectedArt) {
                        [int] (Get-Prop $cover 'w') -gt 0 -and [int] (Get-Prop $cover 'h') -gt 0 -and
                            (Get-PageField $p 'artFailed') -eq $false -and
                            @($p.art | Where-Object { $_.name -ceq $expectedArt }).Count -gt 0
                    } else { $null -eq $cover -and (Get-PageField $p 'artFailed') -eq $true })
            }
            $artLiteral = if ($expectedArt) { "'$expectedArt'" } else { 'null' }
            $expression = "apply({...msg,id:state.id,title:'Sample song',artist:'Sample artist',artwork:$artLiteral})"
            $result = Invoke-Cdp $chrome 'Runtime.evaluate' @{ expression = $expression }
            if (Get-Prop $result 'exceptionDetails') { throw "Long-track sample substitution failed for $Label" }
            $fixtureReady = Wait-For { $p = Get-PageProbe $chrome; if (& $testSyntheticFixture $p) { $p } } 10 100
            if (-not $fixtureReady) { throw "Frame page $Label did not acknowledge the intended synthetic metadata/art fixture" }
            $fixtureSetup = [ordered]@{ anchor = $connected; holdQpc = $holdQpc; drained = $drained
                stableMilliseconds = [double] $drained.pageNow - [double] $drain.stableSince
                drainProbes = $drain.probes; fixture = $fixtureReady }
        }
        if ($isSample -and $Rate -ne 1) {
            # Samples are fixed at rate=1 on the wire. Re-anchor the *real page scheduler* at rate 4,
            # preserving all server-fed metadata/art, rather than claiming the sample server sent rate 4.
            $result = Invoke-Cdp $chrome 'Runtime.evaluate' @{ expression = "apply({...msg,id:state.id,title:state.title,artist:state.artist,artwork:artUrl,rate:$Rate})" }
            if (Get-Prop $result 'exceptionDetails') { throw "Sample rate re-anchor failed for $Label" }
        }
        Start-Sleep -Seconds 5
        if ($GateProfile -eq 'Fast-v2') {
            # Capture inside the trace window, not before Tracing.start's variable CDP latency.
            $probeWindow = [ordered]@{ start = $null }
            $trace = Invoke-FrameTrace $chrome $Label $Seconds { $probeWindow.start = Get-PageProbe $chrome }
            $start = $probeWindow.start
        } else {
            $start = Get-PageProbe $chrome
            $trace = Invoke-FrameTrace $chrome $Label $Seconds
        }
        $end = $trace.endPage
        $cadenceEvidence = Save-CadenceEvidence "A-FRAMES.playing.$Label.cadence" $start $end -Steady:$syntheticMetadata
        $a = Get-PageField $start 'counters'; $b = Get-PageField $end 'counters'
        $ticks = [int] (Get-Prop $b 'ticks') - [int] (Get-Prop $a 'ticks')
        $fill = [int] (Get-Prop $b 'fillWrites') - [int] (Get-Prop $a 'fillWrites')
        $times = [int] (Get-Prop $b 'timeWrites') - [int] (Get-Prop $a 'timeWrites')
        $syntheticFixture = $null; $syntheticFixtureOk = $true
        if ($syntheticMetadata) {
            $startPosition = $start.nativeFixture.projectedPosition; $endPosition = $end.nativeFixture.projectedPosition
            $advance = [double] $endPosition - [double] $startPosition
            $startArtResources = @($start.resources | Where-Object { $_.path -like '/art/*' }).Count
            $endArtResources = @($end.resources | Where-Object { $_.path -like '/art/*' }).Count
            $syntheticFixture = [ordered]@{
                readHeld = $readHeld; holdQpc = $holdQpc; setup = $fixtureSetup
                startValid = [bool] (& $testSyntheticFixture $start); endValid = [bool] (& $testSyntheticFixture $end)
                steadyWindow = [bool] $cadenceEvidence.steadyWindow; reanchors = $cadenceEvidence.reanchors
                dataAnchorUnchanged = $null -ne (Get-PageField $start 'receivedAt') -and
                    (Get-PageField $start 'receivedAt') -eq (Get-PageField $end 'receivedAt')
                lookAnchorUnchanged = $null -ne (Get-PageField $start 'lookReceivedAt') -and
                    (Get-PageField $start 'lookReceivedAt') -eq (Get-PageField $end 'lookReceivedAt') -and
                    (Get-PageField $start 'lookEpoch') -ceq (Get-PageField $end 'lookEpoch') -and
                    (Get-PageField $start 'lookSeq') -eq (Get-PageField $end 'lookSeq')
                advance = $advance; expectedAdvance = $Rate * $cadenceEvidence.seconds
                progressOk = $null -ne $startPosition -and $null -ne $endPosition -and
                    [Math]::Abs($advance - $Rate * $cadenceEvidence.seconds) -le 2
                steppedProgressOk = $fill -gt 0 -and $ticks -gt 0 -and
                    (Get-PageField $end 'projectedPosition') -gt (Get-PageField $start 'projectedPosition')
                coverLoadsStart = Get-Prop $a 'coverLoads'; coverLoadsEnd = Get-Prop $b 'coverLoads'
                artResourcesStart = $startArtResources; artResourcesEnd = $endArtResources
                noArtRefetchOk = $(if ($expectedArt) { $true } else {
                    $null -ne (Get-Prop $a 'coverLoads') -and $null -ne (Get-Prop $b 'coverLoads') -and
                        (Get-Prop $a 'coverLoads') -eq (Get-Prop $b 'coverLoads') -and
                        @($start.art).Count -eq @($end.art).Count -and $startArtResources -eq $endArtResources
                })
            }
            $syntheticFixtureOk = $readHeld -and $null -ne $holdQpc -and $syntheticFixture.startValid -and
                $syntheticFixture.endValid -and $syntheticFixture.steadyWindow -and
                $syntheticFixture.dataAnchorUnchanged -and $syntheticFixture.lookAnchorUnchanged -and
                $syntheticFixture.progressOk -and $syntheticFixture.steppedProgressOk -and $syntheticFixture.noArtRefetchOk
            $syntheticFixture['passed'] = [bool] $syntheticFixtureOk
            Add-Check "A-FRAMES.playing.$Label.syntheticFixture" 'reader held; intended 14400s/rate-aware metadata/art at both endpoints; zero scored reanchors; progress advances; no no-art cover loads/resources grow' $syntheticFixture $syntheticFixtureOk
        }
        $bar = Get-Prop $end.geometry 'bar'
        $geometryOk = (Test-OverlayViewport $end $Size.source) -and (Get-PageField $end 'theme') -eq $Options.theme -and
            [Math]::Abs([double] $end.boxRect.width - [double] $Size.box.w) -le 1 -and
            [Math]::Abs([double] $end.boxRect.height - [double] $Size.box.h) -le 1 -and
            [double] (Get-Prop (Get-PageField $end 'box') 'w') -eq [double] $Size.box.w -and
            [double] (Get-Prop (Get-PageField $end 'source') 'w') -eq [double] $Size.source.w -and
            [double] (Get-Prop (Get-PageField $end 'source') 'h') -eq [double] $Size.source.h -and
            [string] (Get-PageField $end 'boxMismatch') -in @('', 'false') -and
            $(if ($Options.theme -eq 'pill') { $true } else {
                $bar -and [Math]::Abs([double] $bar.width - [double] $Size.bar.width) -le 1
            })
        $textRects = @($end.titleRect, $end.artistRect | Where-Object { $_ -and $_.width -gt 0 })
        $contained = @($textRects | Where-Object { $_.x -lt $end.boxRect.x -or $_.x + $_.width -gt $end.boxRect.x + $end.boxRect.width -or
            $_.y -lt $end.boxRect.y -or $_.y + $_.height -gt $end.boxRect.y + $end.boxRect.height }).Count -eq 0
        $longOk = if ($Condition -eq 'long-text') {
            $end.titleRect.scrollWidth -gt $end.titleRect.clientWidth -and $end.titleEllipsis -eq $true -and
            $end.artist -match '[\p{IsCJKUnifiedIdeographs}\u0600-\u06ff]'
        } else { $true }
        $artOk = switch ($Condition) {
            'no-art' { $end.art.Count -eq 0 }
            'long-no-art' {
                $null -eq (Get-Prop (Get-PageField $end 'raster') 'cover') -and
                    (Get-PageField $end 'artFailed') -eq $true
            }
            'long-sample-art' {
                $cover = Get-Prop (Get-PageField $end 'raster') 'cover'
                @($end.art | Where-Object { $_.name -eq '/art/sample' }).Count -gt 0 -and
                    [int] (Get-Prop $cover 'w') -gt 0 -and (Get-PageField $end 'artFailed') -eq $false
            }
            'fixture-max' {
                $cover = Get-Prop (Get-PageField $end 'raster') 'cover'
                $end.art.Count -gt 0 -and (Get-Overlay (Get-State $run.Root 'maxArt') 'fixtureArtServed') -gt 0 -and
                    [int] (Get-Prop $cover 'w') -eq 1024 -and [int] (Get-Prop $cover 'h') -eq 1024
            }
            default { $end.art.Count -gt 0 }
        }
        if ($fastPixel) {
            $artOk = $null -eq (Get-Prop (Get-PageField $end 'raster') 'cover') -and
                (Get-PageField $end 'artFailed') -eq $true
        }
        $raster = Get-PageField $end 'raster'
        $rasterResult = Test-ThemeRaster $raster $Options.theme $Options $Size
        $canvasAreas = $rasterResult.areas
        $rasterOk = $rasterResult.pass
        $duration = if ($isSample) { 240 } else { 14400 }
        $measuredT = [double] $trace.seconds
        $cadenceT = $cadenceEvidence.seconds
        $limit = [int] [Math]::Ceiling([double] $Size.bar.width * $Rate * $cadenceT / $duration) + 2
        $tickLimit = [int] [Math]::Ceiling($cadenceT) + 1
        $cadence = if ($Options.showTimes -and $Options.theme -notin @('pill', 'album-art') -and $Condition -ne 'pixel-only') {
            $ticks -le $tickLimit -and $times -le $tickLimit -and $times -ge 1
        } else { $fill -le $limit -and $ticks -eq $fill }
        $cadence = $cadence -and $cadenceT -gt 0
        $network = @(Get-UnexpectedOverlayRequests $end.resources)
        $cadenceAssertion = $null; $networkAssertion = $null
        if ($GateProfile -eq 'Fast-v2') {
            $frameRows = @($script:requiredRowInventory | Where-Object {
                $_.class -in @('playing', 'pixel') -and $_.label -eq $Label })
            if ($frameRows.Count -ne 1) { throw "Shared cadence requires one inventory frame row for $Label" }
            $cadenceAssertion = Get-CadenceAssertion $start $end $Options.theme ([bool] $Options.showTimes) $Rate ([double] $Size.bar.width) $duration $cadenceT
            $cadenceAssertion['id'] = "cadence.shared.$($frameRows[0].id)"
            $cadenceAssertion['traceSeconds'] = $measuredT
            $cadenceAssertion['pageStartMs'] = $start.pageNow; $cadenceAssertion['pageEndMs'] = $end.pageNow
            $cadenceAssertion['evidence'] = $cadenceEvidence
            $cadenceAssertion.passed = $cadenceAssertion.passed -and $cadenceT -gt 0
            $cadence = $cadence -and $cadenceAssertion.passed
            Add-Check $cadenceAssertion.id 'shared scored-window cadence: label advance rate*T ±2; ceil(T)+1 ticks/timeWrites; hidden times pixel-only bound' $cadenceAssertion $cadenceAssertion.passed
            if ($Condition -eq 'sample-art' -and $frameRows[0].config -eq 'default') {
                $networkAssertion = [ordered]@{ id = "network.shared.$($Options.theme)"
                    passed = $network.Count -eq 0 -and $artOk -and (Test-OverlayViewport $end $Size.source)
                    resources = @($end.resources); unexpected = $network; art = $end.art; artworkRequired = $true }
                Add-Check $networkAssertion.id 'shared Playing resource requests only /, /overlay.js, /events or /art on localhost; artwork required' $networkAssertion $networkAssertion.passed
            }
        }
        $frameMeasurement = [ordered]@{
            measured = $trace.visible -and $measuredT -ge ($Seconds - 0.5) -and
                $trace.frameEvent -eq 'EndActivateToSubmitCompositorFrame:e'
            seconds = $measuredT; frames = $trace.frames; fps = $trace.fps; ceiling = 1.3
        }
        $frameMeasurement['exceeded'] = $frameMeasurement.measured -and ($trace.frames / $measuredT) -gt 1.3
        $shortSampleWindowOk = if ($isSample -and $Rate -eq 4) {
            $Seconds -eq 53 -and [double] (Get-PageField $end 'projectedPosition') -lt 240
        } else { $true }
        $record = [ordered]@{
            theme = $Options.theme; config = $Label; condition = $Condition; options = $Options; rate = $Rate
            expected = $Size; start = $start; end = $end; trace = $trace; ticks = $ticks; fillWrites = $fill
            timeWrites = $times; maxFillWrites = $limit; maxTicks = $tickLimit; duration = $duration
            geometryOk = $geometryOk; rasterOk = $rasterOk; canvasAreas = $canvasAreas
            contained = $contained; longTextOk = $longOk; artOk = $artOk; badRequests = $network
            frameMeasurement = $frameMeasurement; shortSampleWindowOk = $shortSampleWindowOk
            cadenceAssertion = $cadenceAssertion; cadenceEvidence = $cadenceEvidence; networkAssertion = $networkAssertion
            syntheticMetadata = [ordered]@{ applied = $syntheticMetadata; title = $(if ($syntheticMetadata) { 'Sample song' } else { $null })
                artist = $(if ($syntheticMetadata) { 'Sample artist' } else { $null }); artwork = $(if ($Condition -eq 'long-sample-art') { '/art/sample' } else { $null })
                retainedDuration = $(if ($syntheticMetadata) { 14400 } else { $null }); retainedRate = $(if ($syntheticMetadata) { $Rate } else { $null })
                fixture = $syntheticFixture }
            o3Trigger = [bool] $frameMeasurement.exceeded
        }
        $ok = $frameMeasurement.measured -and -not $frameMeasurement.exceeded -and $geometryOk -and $contained -and $longOk -and
            $artOk -and $rasterOk -and $cadence -and $shortSampleWindowOk -and
            $syntheticFixtureOk -and
            $network.Count -eq 0
        if ($Condition -eq 'pixel-only') { $ok = $ok -and $trace.frames -le $fill + 1 }
        if ((Get-Prop $Options 'backgroundBlur') -eq 32) {
            $steadyRaster = (Test-LookFxCounters $start $end 0) -and
                (Get-PageField $start 'rasterKey') -ceq (Get-PageField $end 'rasterKey') -and
                (Get-Prop (Get-PageField $start 'options') 'backgroundBlur') -eq 32 -and
                (Get-Prop (Get-PageField $end 'options') 'backgroundBlur') -eq 32
            $ok = $ok -and $steadyRaster
            Add-Check "A-FRAMES.$Label.steadyRaster" 'max-blur 32: steady raster key/counters, no artwork refetch or quantization throughout scored 60s' (
                [ordered]@{ start = $start; end = $end; measurement = $frameMeasurement }) $steadyRaster
        }
        $record.artifact = Save-FrameTraceRecord $Label $record $ok
        Add-Check "A-FRAMES.playing.$Label" 'measured frame ceiling, scheduler cadence, expected size, raster, containment, art and network' (
            [ordered]@{ artifact = $record.artifact; measurement = $frameMeasurement; trace = $trace; cadence = $cadence
                geometry = $geometryOk; raster = $canvasAreas; rasterOk = $rasterOk; contained = $contained
                longText = $longOk; art = $artOk; shortSampleWindow = $shortSampleWindowOk; badRequests = $network.Count }) $ok
        return $record
    } finally {
        try {
            if ($trace -and $trace.traceRetention -eq 'raw') {
                Keep-FrameTrace $trace
                if ($record) { [void] (Save-FrameRecord $Label $record) }
            }
        } finally {
            try { if ($readHeld) { [void] (Send-ObsHookCommand $run.Root 'command-obs-release-read') } }
            finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
        }
    }
}

function Test-FrameIdle([string] $Theme, [string] $Condition) {
    $options = Get-ThemeDefaults $Theme
    $options['paused'] = if ($Condition -eq 'dim-Paused') { 'dim' } else { 'hide' }
    if ($Condition -eq 'progress-hidden') { $options['showProgress'] = $false }
    $id = 'idl' + [guid]::NewGuid().ToString('N').Substring(0, 5)
    $sample = $Condition -in @('dim-Paused', 'hidden-Paused', 'ended')
    $run = Start-OverlayRun "A-FRAMES-idle-$Theme-$Condition" @{} $(if ($sample) { $null } else { 'PlayingLong' }) -NoReader `
        -LooksJson (ConvertTo-ObsLooksJson (New-ObsLooksDocument @((New-ObsLook $id "Idle $Theme" $options))))
    $chrome = $null; $trace = $null; $result = $null
    try {
        [void] (Wait-BenchReady $run.Root -BenchProfile $(if ($sample) { $null } else { 'PlayingLong' }))
        $chrome = Start-Chrome $run.Name
        $expectedSize = Get-DefaultThemeSize $Theme
        Set-OverlayViewport $chrome $expectedSize.source
        [void] (Invoke-ChromeNavigate $chrome ("$($overlayUrl)?look=$id" + $(if ($Condition -in @('dim-Paused', 'hidden-Paused')) { '&sample=paused' } elseif ($sample) { '&sample=playing' } else { '' })))
        $expectedState = if ($Condition -in @('dim-Paused', 'hidden-Paused')) { 'paused' } else { 'playing' }
        $connected = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'connection') -eq 'open' -and
            (Get-PageField $p 'state') -eq $expectedState -and (Get-Prop (Get-PageField $p 'look') 'id') -eq $id) { $p } } 15 250
        if (-not $connected) { throw "Idle page $Theme/$Condition never reached its connected $expectedState look state" }
        if ($Condition -eq 'ended') {
            [void] (Invoke-Cdp $chrome 'Runtime.evaluate' @{ expression = "apply({state:'ended'})" })
        } elseif ($Condition -eq 'clock-mismatch') {
            [void] (Send-HookCommand $run.Root 'command-clock-mismatch-on')
            if (-not (Wait-For { -not (Test-Path -LiteralPath (Join-Path (Get-BenchDirectory $run.Root) 'command-clock-mismatch-on')) } 10 25)) {
                throw "Hook command was not consumed: command-clock-mismatch-on."
            }
            if (-not (Wait-For { (Get-PageField (Get-PageProbe $chrome) 'fillTimer') -eq 0 } 5 50)) { throw "Idle page $Theme/$Condition never stopped its fill timer" }
        }
        Start-Sleep -Seconds 5
        $before = Get-PageProbe $chrome
        $trace = Invoke-FrameTrace $chrome "idle-$Theme-$Condition" 60
        $after = Get-PageProbe $chrome
        $ticks = [int] (Get-Prop (Get-PageField $after 'counters') 'ticks') - [int] (Get-Prop (Get-PageField $before 'counters') 'ticks')
        $result = [ordered]@{ condition = $Condition; theme = $Theme; before = $before; after = $after; trace = $trace; ticks = $ticks }
        $ok = $trace.frames -eq 0 -and $ticks -eq 0 -and (Test-OverlayViewport $after $expectedSize.source) -and
            (Get-PageField $before 'fillTimer') -eq 0 -and (Get-PageField $after 'fillTimer') -eq 0 -and $after.running -eq 0
        $result.artifact = Save-FrameTraceRecord "idle-$Theme-$Condition" $result $ok
        Add-Check "A-FRAMES.idle.$Theme.$Condition" 'zero composited frames, no timer, ticks or animations after 5s settle' (
            [ordered]@{ trace = $trace; ticks = $ticks; timer = Get-PageField $after 'fillTimer'; animation = $after.running; artifact = $result.artifact }) $ok
        return $result
    } finally {
        try {
            if ($trace -and $trace.traceRetention -eq 'raw') {
                Keep-FrameTrace $trace
                if ($result) { [void] (Save-FrameRecord "idle-$Theme-$Condition" $result) }
            }
        } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
    }
}

function Test-FrameIdleStructural([string] $Theme, [string[]] $Conditions, [bool] $LookFx = $false) {
    $records = [ordered]@{}
    foreach ($condition in $Conditions) {
        if ($condition -notin @('dim-Paused', 'hidden-Paused', 'ended', 'clock-mismatch', 'progress-hidden') -or $records.Contains($condition)) {
            throw "Invalid or duplicate structural idle condition '$condition'."
        }
        $records[$condition] = $null
    }
    if ($Conditions.Count -eq 0) { return $records }
    $id = 'isc' + [guid]::NewGuid().ToString('N').Substring(0, 5)
    $look = New-ObsLook $id "Structural idle $Theme" (Get-ThemeDefaults $Theme)
    if ($LookFx) { $look.options['backgroundBlur'] = 32 }
    $sessionName = if ($LookFx) { 'A-FRAMES-fx-card-max-blur-idlecheck' } else { "A-FRAMES-idlecheck-$Theme" }
    $run = Start-OverlayRun $sessionName @{} 'PlayingLong' -NoReader -LooksJson (
        ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
    $chrome = $null
    try {
        [void] (Wait-BenchReady $run.Root -BenchProfile 'PlayingLong')
        $chrome = Start-Chrome $run.Name
        $expectedSize = Get-DefaultThemeSize $Theme
        Set-OverlayViewport $chrome $expectedSize.source
        # Navigate the same owned target; never carry a sample/message/timer into the next phase.
        $captureIdle = {
            $p = Get-PageProbe $chrome
            $result = Invoke-Cdp $chrome 'Runtime.evaluate' @{
                expression = "window.__state ? ({domState:document.documentElement.getAttribute('data-state'),clock:msg === null ? null : msg.clock}) : ({domState:null,clock:null})"
                returnByValue = $true
            }
            if (Get-Prop $result 'exceptionDetails') { throw 'Structural idle state probe failed.' }
            $p | Add-Member -NotePropertyName idleState -NotePropertyValue (Get-Prop (Get-Prop $result 'result') 'value') -Force
            $p
        }
        $matchesIdleState = {
            param($p, [string] $state, [bool] $shown, [double] $opacity, [string] $paused, [bool] $progress)
            $o = Get-PageField $p 'options'
            $null -ne $p -and $null -ne (Get-Prop $p 'opacity') -and
                (Get-PageField $p 'connection') -eq 'open' -and (Get-PageField $p 'visible') -eq $true -and
                (Get-PageField $p 'theme') -eq $Theme -and (Get-Prop (Get-PageField $p 'look') 'id') -eq $id -and
                (Get-PageField $p 'state') -eq $state -and (Get-Prop (Get-Prop $p 'idleState') 'domState') -eq $state -and
                (Get-PageField $p 'shown') -eq $shown -and [Math]::Abs([double] $p.opacity - $opacity) -le 0.02 -and
                (Get-Prop $p.attrs 'theme') -eq $Theme -and (Get-Prop $p.attrs 'paused') -eq $paused -and
                (Get-Prop $o 'paused') -eq $paused -and (Get-Prop $o 'showProgress') -eq $progress -and
                (Get-Prop $p.attrs 'showProgress') -eq $progress.ToString().ToLowerInvariant() -and
                (Test-OverlayViewport $p $expectedSize.source)
        }
        foreach ($condition in $Conditions) {
            $rowId = if ($LookFx) { 'frames.fx.card.max-blur.idlecheck' } else { "frames.$Theme.idlecheck.$condition" }
            Start-JournalRow -Id $rowId -Meta @{ independent = $false; structural = $true; theme = $Theme; condition = $condition }
            $phaseQpc = Get-Qpc
            $record = [ordered]@{ theme = $Theme; condition = $condition; passed = $false
                probes = [ordered]@{ baseline = $null; acknowledged = $null; before = $null; after = $null }
                timings = [ordered]@{ resetSeconds = $null; acknowledgeSeconds = $null; settleSeconds = $null; probeIntervalSeconds = $null; totalSeconds = $null } }
            try {
                # Reset every setting/fixture dimension that these phases mutate, then acknowledge real PlayingLong.
                $clockPath = Join-Path (Get-BenchDirectory $run.Root) 'command-clock-mismatch-off'
                if (-not (Wait-For { -not (Test-Path -LiteralPath $clockPath) } 10 25)) { throw 'Previous clock reset is pending.' }
                [void] (Send-HookCommand $run.Root 'command-clock-mismatch-off')
                if (-not (Wait-For { -not (Test-Path -LiteralPath $clockPath) } 10 25)) { throw 'Clock reset was not consumed.' }
                [void] (Send-ObsHookCommand $run.Root 'command-obs-fixture-rate' '1')
                [void] (Send-ObsHookCommand $run.Root 'command-obs-hide-paused-on')
                [void] (Send-ObsHookCommand $run.Root 'command-obs-reduce-motion-off')
                $options = Get-ThemeDefaults $Theme
                if ($LookFx) { $options['backgroundBlur'] = 32 }
                $options['paused'] = 'hide'; $options['showProgress'] = $true
                $look.options = $options
                [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look))))
                [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
                [void] (Invoke-ChromeNavigate $chrome 'about:blank')
                if (-not (Wait-For { (Get-Prop (Get-PageProbe $chrome) 'href') -eq 'about:blank' } 5 50)) {
                    throw 'Structural idle page reset was not acknowledged.'
                }
                [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$id")
                $baseline = Wait-For {
                    $p = & $captureIdle
                    if ((& $matchesIdleState $p 'playing' $true 1 'hide' $true) -and
                        (Get-Prop $p.idleState 'clock') -eq $true -and (Get-PageField $p 'fillTimer') -gt 0 -and $p.running -eq 0) { $p }
                } 15 100
                if (-not $baseline) { throw "Structural idle $Theme/$condition baseline was not acknowledged." }
                $record.probes.baseline = $baseline
                $appliedQpc = Get-Qpc
                $record.timings.resetSeconds = Round3 (Get-Seconds $phaseQpc $appliedQpc)
                $options['paused'] = if ($condition -eq 'dim-Paused') { 'dim' } else { 'hide' }
                $options['showProgress'] = $condition -ne 'progress-hidden'
                [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look))))
                [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
                if ($condition -in @('dim-Paused', 'hidden-Paused', 'ended')) {
                    $sample = if ($condition -eq 'ended') { 'playing' } else { 'paused' }
                    [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$id&sample=$sample")
                    $sampleReady = Wait-For { $p = & $captureIdle; if ((Get-Prop $p 'href') -eq "$($overlayUrl)?look=$id&sample=$sample" -and
                        (Get-PageField $p 'connection') -eq 'open' -and
                        (Get-PageField $p 'state') -eq $(if ($sample -eq 'paused') { 'paused' } else { 'playing' }) -and
                        (Get-Prop (Get-PageField $p 'look') 'id') -eq $id) { $p } } 15 100
                    if (-not $sampleReady) { throw "Structural idle $Theme/$condition sample was not acknowledged." }
                    if ($condition -eq 'ended') {
                        $result = Invoke-Cdp $chrome 'Runtime.evaluate' @{ expression = "apply({state:'ended'})" }
                        if (Get-Prop $result 'exceptionDetails') { throw 'Structural ended state could not be applied.' }
                    }
                } elseif ($condition -eq 'clock-mismatch') {
                    [void] (Send-HookCommand $run.Root 'command-clock-mismatch-on')
                    if (-not (Wait-For { -not (Test-Path -LiteralPath (Join-Path (Get-BenchDirectory $run.Root) 'command-clock-mismatch-on')) } 10 25)) {
                        throw 'Clock mismatch command was not consumed.'
                    }
                }
                $expectedState = if ($condition -in @('dim-Paused', 'hidden-Paused')) { 'paused' } elseif ($condition -eq 'ended') { 'ended' } else { 'playing' }
                $expectedShown = $condition -notin @('hidden-Paused', 'ended')
                $expectedOpacity = if ($condition -eq 'dim-Paused') { 0.7 } elseif ($expectedShown) { 1 } else { 0 }
                $finalState = {
                    param($p)
                    (& $matchesIdleState $p $expectedState $expectedShown $expectedOpacity $options.paused $options.showProgress) -and
                        (Get-PageField $p 'fillTimer') -eq 0 -and $p.running -eq 0 -and
                        $(if ($condition -eq 'clock-mismatch') { (Get-Prop $p.idleState 'clock') -eq $false }
                          elseif ($condition -eq 'progress-hidden') { (Get-Prop $p.idleState 'clock') -eq $true } else { $true })
                }
                $ack = Wait-For { $p = & $captureIdle; if (& $finalState $p) { $p } } 15 100
                if (-not $ack) { throw "Structural idle $Theme/$condition resulting state was not acknowledged." }
                $record.probes.acknowledged = $ack
                $settleQpc = Get-Qpc
                $record.timings.acknowledgeSeconds = Round3 (Get-Seconds $appliedQpc $settleQpc)
                Start-Sleep -Seconds 5
                $before = & $captureIdle
                $record.probes.before = $before
                $record.timings.settleSeconds = Round3 (Get-Seconds $settleQpc $before.qpc)
                Start-Sleep -Seconds 1
                $after = & $captureIdle
                $record.probes.after = $after
                $record.timings.probeIntervalSeconds = Round3 (Get-Seconds $before.qpc $after.qpc)
                $a = Get-PageField $before 'counters'; $b = Get-PageField $after 'counters'
                $record.passed = [bool] ((& $finalState $before) -and (& $finalState $after) -and
                    $null -ne (Get-Prop $a 'ticks') -and $null -ne (Get-Prop $b 'ticks') -and
                    $null -ne (Get-Prop $a 'fillWrites') -and $null -ne (Get-Prop $b 'fillWrites') -and
                    (Get-Prop $a 'ticks') -eq (Get-Prop $b 'ticks') -and (Get-Prop $a 'fillWrites') -eq (Get-Prop $b 'fillWrites'))
                if ($LookFx) {
                    $record.passed = $record.passed -and (Test-LookFxCounters $before $after 0) -and
                        (Get-PageField $before 'rasterKey') -ceq (Get-PageField $after 'rasterKey') -and
                        (Get-Prop (Get-PageField $before 'options') 'backgroundBlur') -eq 32 -and
                        (Get-Prop (Get-PageField $after 'options') 'backgroundBlur') -eq 32
                }
            } catch { $record.error = $_.Exception.Message }
            $record.timings.totalSeconds = Round3 (Get-Seconds $phaseQpc (Get-Qpc))
            $checkName = if ($LookFx) { 'A-FRAMES.fx.card.max-blur.idlecheck' } else { "A-FRAMES.idlecheck.$Theme.$condition" }
            Add-Check $checkName 'acknowledged final state, own 5s settle, then no fill timer, ticks, fill writes or running animations over 1s; max-blur FX also retain raster counters' $record $record.passed
            $record.artifact = Save-FrameRecord $(if ($LookFx) { 'fx.card.max-blur.idlecheck' } else { "idlecheck-$Theme-$condition" }) $record
            $records[$condition] = $record
            Complete-JournalRow -Id $rowId -Result $record -Artifacts @($record.artifact)
        }
        return $records
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
}

function Test-FrameFxPushes($Run, $Chrome, $Look, [string] $Prefix) {
    $initial = Wait-For { $p = Get-LookFxProbe $Chrome; if ((Get-PageField $p 'artFailed') -eq $false -and
        (Get-PageField $p 'artLoadedSeq') -eq (Get-PageField $p 'artSeq')) { $p } } 10 25
    if (-not $initial) { throw "Frame FX fixture artwork was not loaded: $Prefix" }
    $records = [ordered]@{ initial = $initial; rapid = @() }
    $before = $initial
    foreach ($blur in @(32, 0, 31, 32)) {
        $previous = $before.fx.resolved.blur
        $Look.options['backgroundBlur'] = $blur
        $after = Push-LookFx $Run $Chrome $Look
        $draws = if ($previous -eq $blur -or ($Look.options.theme -eq 'album-art' -and $blur -eq 0)) { 0 } else { 1 }
        $ok = (Test-LookFxCounters $before $after $draws) -and
            (Test-LookFxColours $after $initial $Look.options.theme $Look.options) -and
            (Get-PageField $initial 'artSeq') -eq (Get-PageField $after 'artSeq') -and
            (Get-PageField $after 'artLoadedSeq') -eq (Get-PageField $initial 'artLoadedSeq')
        $records.rapid += [ordered]@{ blur = $blur; expectedDraws = $draws; before = $before; after = $after; passed = $ok }
        $before = $after
    }
    $rapidOk = @($records.rapid | Where-Object { -not $_.passed }).Count -eq 0
    Add-Check "$Prefix.fx.rapid" 'rapid native effect-only edits ending at max blur: exact raster delta per resolved key, no refetch, newest artwork retained' $records.rapid $rapidOk
    $equal = Push-LookFx $Run $Chrome $Look
    Add-Check "$Prefix.fx.equal" 'equal max-blur push does zero raster work and retains the key' $equal (
        (Test-LookFxCounters $before $equal 0) -and (Get-PageField $before 'rasterKey') -ceq (Get-PageField $equal 'rasterKey'))
    $Look.name += ' fx rename'
    $named = Push-LookFx $Run $Chrome $Look
    Add-Check "$Prefix.fx.nameOnly" 'max-blur rename is saved and emits a newer same-epoch look event with no raster work or refetch' $named (
        $named.lookPush.storedName -ceq $Look.name -and $named.lookPush.newEvent -and
        (Test-LookFxCounters $equal $named 0) -and (Get-PageField $equal 'rasterKey') -ceq (Get-PageField $named 'rasterKey'))
    $Look.options['backgroundBlur'] = $null
    $reset = Push-LookFx $Run $Chrome $Look
    $draws = if ($Look.options.theme -eq 'album-art') { 0 } else { 1 }
    Add-Check "$Prefix.fx.reset" 'null reset restores default effects with the expected raster delta, no refetch, newest artwork still wins' $reset (
        (Test-LookFxCounters $named $reset $draws) -and
        (Test-LookFxColours $reset $initial $Look.options.theme $Look.options) -and
        (Get-PageField $reset 'artLoadedSeq') -eq (Get-PageField $initial 'artLoadedSeq') -and
        (Get-PageField $reset 'artSeq') -eq (Get-PageField $initial 'artSeq') -and
        (Get-PageField $reset 'artFailed') -eq $false)
    $records.equal = $equal; $records.named = $named; $records.reset = $reset
    $records
}

function Test-FrameTransitions([string] $Theme) {
    $options = Get-ThemeDefaults $Theme
    $id = 'trn' + [guid]::NewGuid().ToString('N').Substring(0, 5)
    $look = New-ObsLook $id "Transition $Theme" $options
    $run = Start-OverlayRun "A-FRAMES-transitions-$Theme" @{} $null -NoReader -LooksJson (
        ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
    $chrome = $null; $records = [ordered]@{}
    try {
        $chrome = Start-Chrome $run.Name
        $expectedSize = Get-DefaultThemeSize $Theme
        Set-OverlayViewport $chrome $expectedSize.source
        [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$id&sample=playing")
        [void] (Wait-PageConnected $chrome 15)
        $initial = Get-PageProbe $chrome
        Add-Check "A-FRAMES.transitions.$Theme.viewport" 'native default source viewport fully contains theme' (
            [ordered]@{ source = $expectedSize.source; actual = $initial.pageSize; box = $initial.boxRect }) (
            (Test-OverlayViewport $initial $expectedSize.source))
        if ($Theme -in @('pill', 'standard', 'classic', 'album-art', 'card')) {
            $records.fx = Test-FrameFxPushes $run $chrome $look "A-FRAMES.transitions.$Theme"
        }
        foreach ($kind in @('show', 'hide')) {
            foreach ($animation in @('fade', 'slide-up', 'slide-down', 'slide-left', 'slide-right', 'none')) {
                $options[$kind + 'Animation'] = $animation
                $look.options = $options
                [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look))))
                [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
                $received = Wait-For { $p = Get-PageProbe $chrome; if ((Get-Prop $p.attrs "anim$(if ($kind -eq 'show') { 'Show' } else { 'Hide' })") -eq $animation) { $p } } 5 25
                # The sample's real data seeded msg; switching state uses the page's own apply()/setView(),
                # with the same artwork and metadata so no extra network load is created by the test.
                $target = if ($kind -eq 'show') { 'playing' } else { 'ended' }
                $prepare = if ($kind -eq 'show') { 'ended' } else { 'playing' }
                $expression = @"
(async () => {
  const data = { ...msg, id:state.id, title:state.title, artist:state.artist, artwork:artUrl };
  apply({ ...data, state:'$prepare' });
  await new Promise(r => setTimeout(r, 650));
  const start = performance.now();
  apply({ ...data, state:'$target' });
  const target = '$target' === 'playing' ? 1 : 0;
  return await new Promise(resolve => {
    const tick = () => {
      if ((Math.abs(Number(getComputedStyle(document.getElementById('pill')).opacity) - target) < .03 &&
           document.getAnimations().every(a => a.playState !== 'running')) || performance.now() - start > 1000)
        resolve({ ms:performance.now() - start, running:document.getAnimations().filter(a => a.playState === 'running').length });
      else setTimeout(tick, 10);
    }; tick();
  });
})()
"@
                $result = Invoke-Cdp $chrome 'Runtime.evaluate' @{ expression = $expression; awaitPromise = $true; returnByValue = $true } 10
                $value = Get-Prop (Get-Prop $result 'result') 'value'
                $records["$kind-$animation"] = [ordered]@{ look = [bool] $received; timing = $value }
                Add-Check "A-FRAMES.transitions.$Theme.$kind.$animation" 'look received, show/hide reaches final state <=600 ms with no running animation' $records["$kind-$animation"] (
                    $received -and $value -and [double] $value.ms -le 600 -and [int] $value.running -eq 0)
            }
        }
        $nameBase = [int] (Get-Prop (Get-PageField (Get-PageProbe $chrome) 'counters') 'blurDraws')
        for ($n = 0; $n -lt 50; $n++) {
            $look.name = "Name $n"
            [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look))))
            [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        }
        $afterNames = Get-PageProbe $chrome
        $nameDraws = [int] (Get-Prop (Get-PageField $afterNames 'counters') 'blurDraws') - $nameBase
        Add-Check "A-FRAMES.transitions.$Theme.names" '50 name-only pushes redraw no raster' $nameDraws ($nameDraws -eq 0)
        $records.names = [ordered]@{ redraws = $nameDraws; pushes = 50 }
        $startDraw = [int] (Get-Prop (Get-PageField $afterNames 'counters') 'blurDraws')
        $baseWidth = [int] $options.width
        $expandedSource = @{ w = [int] $expectedSize.source.w + 10
            h = [int] $expectedSize.source.h + $(if ($Theme -in @('album-art', 'card')) { 10 } else { 0 }) }
        Set-OverlayViewport $chrome $expandedSource
        for ($n = 0; $n -lt 50; $n++) {
            $options['width'] = $baseWidth + $(if ($n % 2) { 10 } else { 0 })
            $look.options = $options
            [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look))))
            [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        }
        $afterWidths = Wait-For { $p = Get-PageProbe $chrome; if ([double] (Get-Prop (Get-PageField $p 'box') 'w') -eq $baseWidth + 10) { $p } } 10 100
        $drawDelta = [int] (Get-Prop (Get-PageField $afterWidths 'counters') 'blurDraws') - $startDraw
        $blurred = $Theme -in @('pill', 'standard', 'classic', 'card')
        $records.widths = [ordered]@{ pushes = 50; draws = $drawDelta; width = $options.width
            fillTimer = Get-PageField $afterWidths 'fillTimer'; viewport = $afterWidths.pageSize; source = $expandedSource }
        Add-Check "A-FRAMES.transitions.$Theme.widths" '50 width pushes: at most one raster per cache key, one timer and full native source viewport' $records.widths (
            $afterWidths -and $drawDelta -le 50 -and $(if ($blurred) { $drawDelta -ge 1 } else { $drawDelta -eq 0 }) -and
            (Get-PageField $afterWidths 'fillTimer') -ne 0 -and
            (Test-OverlayViewport $afterWidths $expandedSource) -and
            [int] (Get-Prop (Get-PageField $afterWidths 'source') 'w') -eq $expandedSource.w -and
            [int] (Get-Prop (Get-PageField $afterWidths 'source') 'h') -eq $expandedSource.h)
        # Theme push with the same id must change the page without creating another timer.
        $nextTheme = if ($Theme -eq 'matte') { 'standard' } else { 'matte' }
        $newOptions = Get-ThemeDefaults $nextTheme
        $nextSize = Get-DefaultThemeSize $nextTheme
        Set-OverlayViewport $chrome $nextSize.source
        $look.options = $newOptions
        [void] (Write-ObsLooksFile $run.Root (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look))))
        [void] (Send-ObsHookCommand $run.Root 'command-obs-looks-reload')
        $switched = Wait-For { $p = Get-PageProbe $chrome; if ($p.attrs.theme -eq $nextTheme) { $p } } 10 50
        Add-Check "A-FRAMES.transitions.$Theme.themeSwitch" 'live theme change applies once, one timer and fresh cache key' (
            [ordered]@{ theme = Get-Prop (Get-Prop $switched 'attrs') 'theme'; timer = Get-PageField $switched 'fillTimer' }) (
            $switched -and $switched.attrs.theme -eq $nextTheme -and
            (Test-OverlayViewport $switched $nextSize.source) -and (Get-PageField $switched 'fillTimer') -ne 0)
        $records.switch = [ordered]@{ theme = $nextTheme; page = $switched }
        $records.artifact = Save-FrameRecord "transitions-$Theme" $records
        return $records
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
}

function Test-FrameLateArt([string] $Theme) {
    $id = 'lat' + [guid]::NewGuid().ToString('N').Substring(0, 5)
    $o = Get-ThemeDefaults $Theme
    if ($Theme -in @('pill', 'standard', 'classic', 'album-art', 'card')) { $o['backgroundBlur'] = 32 }
    $look = New-ObsLook $id "Late art $Theme" $o
    $run = Start-OverlayRun "A-FRAMES-late-art-$Theme" @{} 'ArtSwap' -NoReader -LooksJson (
        ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
    $chrome = $null
    try {
        $ready = Wait-BenchReady $run.Root
        $start = Get-ReadyQpc $ready
        $chrome = Start-Chrome $run.Name
        $expectedSize = Get-DefaultThemeSize $Theme
        Set-OverlayViewport $chrome $expectedSize.source
        [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$id")
        Wait-UntilQpc ($start + 18 * $freq)
        $page = Get-PageProbe $chrome
        $counters = Get-PageField $page 'counters'
        $art = @($page.art | Sort-Object start)
        $result = [ordered]@{ page = $page; art = $art; counters = $counters }
        $result.artifact = Save-FrameRecord "late-art-$Theme" $result
        Add-Check "A-FRAMES.transitions.$Theme.lateArt" 'delayed A after B cannot replace B; at most one raster draw per loaded cover' (
            [ordered]@{ artifact = $result.artifact; artSeq = Get-PageField $page 'artSeq'; loadedSeq = Get-PageField $page 'artLoadedSeq'
                coverLoads = Get-Prop $counters 'coverLoads'; blurDraws = Get-Prop $counters 'blurDraws'; art = $art }) (
            $art.Count -ge 2 -and [double] $art[-2].end -gt [double] $art[-1].end -and
            (Get-PageField $page 'artLoadedSeq') -eq (Get-PageField $page 'artSeq') -and
            (Get-PageField $page 'artFailed') -eq $false -and
            [int] (Get-Prop $counters 'blurDraws') -le [int] (Get-Prop $counters 'coverLoads') -and
            (Test-OverlayViewport $page $expectedSize.source))
        if ($Theme -in @('pill', 'standard', 'classic', 'album-art', 'card')) {
            $result.fx = Test-FrameFxPushes $run $chrome $look "A-FRAMES.lateart.$Theme"
            $latest = $result.fx.reset.fx
            # Fixture B at (96,96): t=floor(192*255/254)=192, low=floor(t/4)=48.
            Add-Check "A-FRAMES.lateart.$Theme.fx.newestArt" 'after max-blur edits/reset the loaded bitmap is deterministic B, never delayed A; no new resource fetch' $latest (
                $latest.requestedArt -ceq $art[-1].name -and $latest.loadedArt -ceq $latest.requestedArt -and
                (ConvertTo-Json -InputObject $latest.artPixel -Compress) -ceq '[48,48,192,255]')
            $result.artifact = Save-FrameRecord "late-art-$Theme" $result
        }
        return $result
    } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
}

function Test-FrameRenewal([double] $SteadyFps) {
    $options = Get-ThemeDefaults 'matte'; $options['showTimes'] = $true
    $id = 'renew001'
    $run = Start-OverlayRun 'A-FRAMES-renewal' @{} 'PlayingLong' -NoReader -LooksJson (
        ConvertTo-ObsLooksJson (New-ObsLooksDocument @((New-ObsLook $id 'Renewal' $options))))
    $chrome = $null; $trace = $null; $result = $null
    try {
        [void] (Wait-BenchReady $run.Root)
        $chrome = Start-Chrome $run.Name
        $expectedSize = Get-DefaultThemeSize 'matte'
        Set-OverlayViewport $chrome $expectedSize.source
        [void] (Invoke-ChromeNavigate $chrome "$($overlayUrl)?look=$id")
        $connected = Wait-PageConnected $chrome 15
        if (-not $connected) { throw 'A-FRAMES renewal page failed to open' }
        $startQpc = Get-Qpc
        Wait-UntilQpc ($startQpc + 290 * $freq)
        $before = Get-PageProbe $chrome
        $trace = Invoke-FrameTrace $chrome 'renewal' 20
        $after = Get-PageProbe $chrome
        $overlay = Get-Overlay (Get-State $run.Root 'framesRenewal') 'lastStreamEndReason'
        $ticks = [int] (Get-Prop (Get-PageField $after 'counters') 'ticks') - [int] (Get-Prop (Get-PageField $before 'counters') 'ticks')
        $limit = [Math]::Ceiling(20 * $SteadyFps) + 3
        $result = [ordered]@{ trace = $trace; before = $before; after = $after; ticks = $ticks; limit = $limit
            steadyFps = $SteadyFps; lifetimeReason = $overlay; elapsedSeconds = Get-Seconds $startQpc (Get-Qpc) }
        $ok = $overlay -eq 'Lifetime' -and $trace.frames -le $limit -and $ticks -le 23 -and
            $ticks -ge 1 -and (Test-OverlayViewport $after $expectedSize.source) -and
            (Get-PageField $after 'fillTimer') -ne 0 -and (Get-PageField $after 'shown') -eq $true
        [void] (Save-FrameTraceRecord 'renewal' $result $ok)
        Add-Check 'A-FRAMES.renewal' '5-minute SSE lifetime renewed, <=3 additional compositor frames in ±10 s, one timer' (
            [ordered]@{ frames = $trace.frames; limit = $limit; ticks = $ticks; reason = $overlay
                before = Get-PageField $before 'fillTimer'; after = Get-PageField $after 'fillTimer' }) $ok
        return $result
    } finally {
        try {
            if ($trace -and $trace.traceRetention -eq 'raw') {
                Keep-FrameTrace $trace
                if ($result) { [void] (Save-FrameRecord 'renewal' $result) }
            }
        } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
    }
}

function Stop-FramesForO3($Obs, $Record, $Worst, $PausedExtensions) {
    $theme = $Record.theme
    $Obs.o3[$theme] = [ordered]@{ trigger = 'measured-frame-ceiling'; potentialStop = $true
        requiresInvestigation = $true; config = $Record.config; measurement = $Record.frameMeasurement
        artifact = $Record.artifact }
    $reason = "Stopped after $($Record.config) measured $($Record.frameMeasurement.fps) fps > 1.3; trace $($Record.trace.trace), record $($Record.artifact); no further rows executed"
    Add-Blocked "A-FRAMES.O3.$theme" 'measured compositor ceiling exceeded; investigate nonvisual fixes before any owner fallback decision' $reason
    foreach ($class in @('playing.remaining', 'pixelOnly.remaining', 'idle.remaining',
        'transitions.remaining', 'network.remaining', 'renewal')) {
        Add-Blocked "A-FRAMES.$class" 'required rows remaining after measured-ceiling stop' $reason
    }
    if ($GateProfile -eq 'Fast-v2') {
        foreach ($class in @('idlecheck.remaining', 'sharedAssertions.remaining')) {
            Add-Blocked "A-FRAMES.$class" 'required profile rows remaining after measured-ceiling stop' $reason
        }
    }
    $worstFile = Join-Path $runDirectory 'frames-worst.json'
    [IO.File]::WriteAllText($worstFile, (ConvertTo-Json -Depth 16 -InputObject ([ordered]@{
        version = 2; protocol = $GateProfile; scope = "$GateProfile observed"; worstDescription = 'worst observed in this profile'
        worst = $Worst; pausedExtensions = @($PausedExtensions | Select-Object -Unique); framesGreen = $false
        profileComplete = $false; exhaustiveComplete = $false; complete = $false
        stopped = $Obs.o3[$theme]
    })), [Text.UTF8Encoding]::new($false))
    # Filtered diagnostics never certify the full matrix (speed plan S2); the O3 stop stays blocked either way.
    $aggregate = if (-not (Test-DefaultRowSelectors)) { 'A-FRAMES.selectedRows' } elseif ($GateProfile -eq 'Fast-v2') { 'A-FRAMES.fastProfileRows' } else { 'A-FRAMES.allRequiredRows' }
    Add-Blocked $aggregate 'all required frame rows green' (
        "$reason; completed=$($Obs.configurations.Count); worst-so-far=$worstFile; framesGreen=false")
    $scenarioResults['A-FRAMES'] = $Obs
}

function Invoke-FrameCalibration {
    if ($script:frameCalibration) { return $script:frameCalibration }
    $script:frameCalibration = [ordered]@{ mutants = [ordered]@{}; passed = $false }
    if (-not (Test-ChromeAvailable 'A-FRAMES')) { return $script:frameCalibration }
    # Always measure all four mutants afresh, including on resume; no ordinary row can bypass sensitivity.
    foreach ($mutant in @('bar-transition', 'pill-raf', 'ceiling-low', 'ceiling-high')) {
        $rowId = "frames.mutant.$mutant"
        Start-JournalRow -Id $rowId -Meta @{ independent = $false; calibration = $true }
        $run = $null; $chrome = $null; $sample = $null; $artifact = $null
        $nearCeiling = $mutant -in @('ceiling-low', 'ceiling-high')
        $mutationRate = if ($mutant -eq 'ceiling-low') { 1.2 } elseif ($mutant -eq 'ceiling-high') { 1.4 } else { $null }
        $expected = if ($nearCeiling) {
            "60 s visible compositor submissions at ~$mutationRate/s, mutation count within 2 of rate x seconds, no progress work; <= 1.3/s oracle $(if ($mutant -eq 'ceiling-low') { 'accepts nonzero frames' } else { 'rejects' })"
        } else { 'actual CDP compositor-submission frames >= 10/s, while ordinary <= 1.3/s oracle rejects it' }
        try {
            $theme = if ($mutant -eq 'bar-transition') { 'matte' } else { 'pill' }
            $id = if ($mutant -eq 'bar-transition') { 'mutmatte' } else { 'mutpill0' }
            $profile = if ($mutant -ne 'bar-transition') { 'PlayingLong' } else { $null }
            $look = New-ObsLook $id "Mutant $mutant" (Get-ThemeDefaults $theme)
            try {
                $run = Start-OverlayRun "A-FRAMES-mutant-$mutant" @{} $profile -NoReader `
                    -Override @{ NATIVUNE_TEST_OBS_MUTANT = $mutant } -LooksJson (ConvertTo-ObsLooksJson (New-ObsLooksDocument @($look)))
                [void] (Wait-BenchReady $run.Root -BenchProfile $profile)
                $chrome = Start-Chrome $run.Name
                Set-OverlayViewport $chrome (Get-DefaultThemeSize $theme).source
                $url = "$($overlayUrl)?look=$id" + $(if ($mutant -eq 'bar-transition') { '&sample=playing' } else { '' })
                [void] (Invoke-ChromeNavigate $chrome $url)
                $connected = Wait-For { $p = Get-PageProbe $chrome; if ((Get-PageField $p 'connection') -eq 'open' -and
                    (Get-PageField $p 'state') -eq 'playing' -and (Get-PageField $p 'shown') -eq $true -and
                    (Get-Prop (Get-PageField $p 'look') 'id') -eq $id) { $p } } 15 250
                if (-not $connected) { throw "Mutant $mutant did not reach its connected playing look state" }
                Start-Sleep -Seconds 5
                $start = Get-PageProbe $chrome
                $sample = Invoke-FrameTrace $chrome "mutant-$mutant" 60
                $a = Get-PageField $start 'counters'; $b = Get-PageField $sample.endPage 'counters'
                $mutationCounter = if ($mutant -eq 'bar-transition') { 'fillWrites' } else { 'mutantMutations' }
                $sample['startPage'] = $start
                $sample['mutationCounter'] = $mutationCounter
                $sample['mutationCount'] = [int] (Get-Prop $b $mutationCounter) - [int] (Get-Prop $a $mutationCounter)
                $sample['ticks'] = [int] (Get-Prop $b 'ticks') - [int] (Get-Prop $a 'ticks')
                $sample['fillWrites'] = [int] (Get-Prop $b 'fillWrites') - [int] (Get-Prop $a 'fillWrites')
                $sample['timeWrites'] = [int] (Get-Prop $b 'timeWrites') - [int] (Get-Prop $a 'timeWrites')
                $visible = $sample.visible -and (Test-OverlayViewport $sample.endPage (Get-DefaultThemeSize $theme).source)
                if ($nearCeiling) {
                    $sample['targetMutationFps'] = $mutationRate
                    $sample['expectedMutationCount'] = $mutationRate * $sample.seconds
                    $sample['mutationCountTolerance'] = 2
                    $sample['oracleAccepted'] = $sample.frames -gt 0 -and $sample.fps -le 1.3
                    $cadenceOk = [Math]::Abs($sample.mutationCount - $sample.expectedMutationCount) -le $sample.mutationCountTolerance
                    $isolated = (Get-PageField $start 'fillTimer') -eq 0 -and (Get-PageField $sample.endPage 'fillTimer') -eq 0 -and
                        $sample.ticks -eq 0 -and $sample.fillWrites -eq 0 -and $sample.timeWrites -eq 0 -and $sample.endPage.running -eq 0
                    $oracleOk = if ($mutant -eq 'ceiling-low') { $sample.oracleAccepted } else { $sample.fps -gt 1.3 }
                    $passed = $visible -and $cadenceOk -and $isolated -and $oracleOk
                } else {
                    $passed = $visible -and $sample.fps -ge 10 -and $sample.fps -gt 1.3
                }
                Keep-FrameTrace $sample
                $artifact = Save-FrameRecord "mutant-$mutant" $sample
                $script:frameCalibration.mutants[$mutant] = $sample
                Add-Check "A-FRAMES.mutant.$mutant" $expected $sample $passed
            } finally {
                try {
                    if ($sample -and $sample.traceRetention -eq 'raw') { Keep-FrameTrace $sample }
                } finally { Stop-Chrome $chrome; Stop-OverlayRun $run }
            }
        } catch {
            Add-Check "A-FRAMES.mutant.$mutant" $expected $_.Exception.Message $false
        } finally {
            $artifacts = @(); if ($sample) { $artifacts += $sample.trace }; if ($artifact) { $artifacts += $artifact }
            Complete-JournalRow -Id $rowId -Artifacts $artifacts
        }
    }
    $mutantChecks = @($checks | Where-Object { $_.name -like 'A-FRAMES.mutant.*' })
    $script:frameCalibration.passed = $mutantChecks.Count -eq 4 -and @($mutantChecks | Where-Object { $_.status -ne 'pass' }).Count -eq 0
    return $script:frameCalibration
}
function Test-AFrames {
    $calibration = Invoke-FrameCalibration
    $obs = [ordered]@{ protocol = $GateProfile; mutants = $calibration.mutants; configurations = [ordered]@{}; assertions = [ordered]@{}; o3 = [ordered]@{}
        supplemental = [ordered]@{ protocol = 'LookFx-v1'
            rowIds = @($script:requiredRowInventory | Where-Object { $_.scenario -eq 'A-FRAMES' -and (Get-Prop $_ 'supplemental') -eq 'LookFx-v1' } | ForEach-Object { $_.id })
            extendedRowIds = @($script:requiredRowInventory | Where-Object { $_.scenario -eq 'A-FRAMES' -and (Get-Prop $_ 'lookFxSupplemental') -eq $true } | ForEach-Object { $_.id }) } }
    if (-not $calibration.passed) {
        Add-Blocked 'A-FRAMES.calibration' 'all four sensitivity guards: legacy mutants rejected, ceiling-low accepted, ceiling-high rejected' 'calibration not established; all dependent frame rows blocked'
        $aggregate = if (-not (Test-DefaultRowSelectors)) { 'A-FRAMES.selectedRows' } elseif ($GateProfile -eq 'Fast-v2') { 'A-FRAMES.fastProfileRows' } else { 'A-FRAMES.allRequiredRows' }
        Add-Blocked $aggregate 'all required frame rows green' 'calibration not established; no frame rows executed; framesGreen=false'
        $scenarioResults['A-FRAMES'] = $obs
        return
    }
    Add-Check 'A-FRAMES.calibration' 'all four calibration guards satisfy their required acceptance/rejection behavior' $obs.mutants $true
    $sizes = Get-Content -Raw (Join-Path $fixtureDirectory 'expected-sizes.json') | ConvertFrom-Json -AsHashtable -Depth 16
    # The inventory is the single scheduling source: identical serial rows/windows, plus the required late-art row.
    $frameRows = @($script:requiredRowInventory | Where-Object { $_.scenario -eq 'A-FRAMES' })
    if ($Rotation) {
        $orderedPlaying = @($frameRows | Where-Object { $_.class -eq 'playing' -and -not $_.Contains('supplemental') } | Sort-Object rotationOrder)
        $playingIndex = 0
        $frameRows = @($frameRows | ForEach-Object { if ($_.class -eq 'playing' -and -not $_.Contains('supplemental')) { $orderedPlaying[$playingIndex]; $playingIndex++ } else { $_ } })
    }
    $rowRecords = @{}; $structuralThemes = [Collections.Generic.HashSet[string]]::new()
    $worst = $null; $pausedExtensions = [Collections.Generic.List[string]]::new()
    foreach ($entry in $frameRows | Where-Object { $_.selected -and $_.class -ne 'mutant' }) {
        $rowId = $entry.id; $record = $null; $theme = Get-Prop $entry 'theme'
        if ($entry.class -eq 'fx-idlecheck') {
            $phases = Test-FrameIdleStructural $theme @($entry.condition) $true
            $obs.configurations[$entry.label] = $phases[$entry.condition]
            $obs.supplemental['idlecheck'] = $phases[$entry.condition]
            continue
        }
        if ($entry.class -eq 'idlecheck') {
            if (-not $structuralThemes.Contains($theme)) {
                $conditions = @($frameRows | Where-Object { $_.selected -and $_.class -eq 'idlecheck' -and $_.theme -eq $theme } | ForEach-Object { $_.condition })
                $phases = Test-FrameIdleStructural $theme $conditions
                foreach ($condition in $phases.Keys) { $obs.configurations["$theme-idlecheck-$condition"] = $phases[$condition] }
                [void] $structuralThemes.Add($theme)
            }
            continue
        }
        if ($entry.class -in @('shared-cadence', 'shared-network')) {
            $field = if ($entry.class -eq 'shared-cadence') { 'cadenceAssertion' } else { 'networkAssertion' }
            $source = if ($rowRecords.ContainsKey($entry.sourceRow)) { $rowRecords[$entry.sourceRow] } else { $null }
            $record = Get-Prop $source $field
            Start-JournalRow -Id $rowId -Meta @{ independent = $false; class = $entry.class; sourceRow = $entry.sourceRow }
            Add-Check "A-FRAMES.$rowId" 'shared observation assertion passes on the selected source row' $record ($record -and (Get-Prop $record 'passed') -eq $true)
            Complete-JournalRow -Id $rowId -Result $record
            $obs.assertions[$rowId] = $record
            continue
        }
        $independent = $entry.class -in @('playing', 'pixel', 'idle')
        if (Test-JournalRowReusable -Id $rowId) {
            $record = Get-JournalRowResult -Id $rowId
        } else {
            Start-JournalRow -Id $rowId -Meta @{ independent = $independent; class = $entry.class }
            switch ($entry.class) {
                { $_ -in @('playing', 'pixel') } {
                    $o = Copy-LookOptions (Get-ThemeDefaults $theme)
                    if ($entry.class -eq 'playing') {
                        $o['width'] = $entry.width; $o['scale'] = $entry.scale; $o['showTimes'] = $entry.showTimes
                        $condition = $entry.condition
                    } else {
                        $o['showTimes'] = $false; $condition = 'pixel-only'
                        if ($GateProfile -eq 'Fast-v2') { $o['width'] = $entry.width; $o['scale'] = $entry.scale }
                    }
                    if ($null -ne (Get-Prop $entry 'backgroundBlur')) { $o['backgroundBlur'] = $entry.backgroundBlur }
                    $row = @($sizes.rows | Where-Object { $_.theme -eq $theme -and $_.width -eq $o.width -and $_.scale -eq $o.scale -and
                        $_.showArt -and $_.showArtist -and $_.showProgress -and $_.showTimes -eq $o.showTimes } | Select-Object -First 1)
                    if ($row.Count -ne 1) { throw "A-FRAMES: missing independent size row $($entry.label)" }
                    $record = Test-FramePlaying $entry.label $o $entry.rate $condition $row[0] $entry.windowSeconds
                }
                'idle' { $record = Test-FrameIdle $theme $entry.condition }
                'transitions' { $record = Test-FrameTransitions $theme }
                'lateart' { $record = Test-FrameLateArt $theme }
                'network' {
                    if ($GateProfile -ne 'Exhaustive-v1') { throw 'Standalone network rows are exhaustive-only.' }
                    $record = Test-FrameNetwork $theme
                }
                'renewal' {
                    $steadyCase = $obs.configurations['matte-default-timesTrue-rate1-sample-art']
                    if ($steadyCase) { $record = Test-FrameRenewal ([double] $steadyCase.trace.fps) }
                    else { Add-Blocked 'A-FRAMES.renewal' 'steady matte baseline required before renewal' 'selected rows did not supply the matte steady baseline' }
                }
                default { throw "A-FRAMES: unknown inventory class $($entry.class)" }
            }
            # Row functions have returned through their teardown; exceptions leave an incomplete journal row.
            Complete-JournalRow -Id $rowId -Result $record
        }
        if ($entry.class -eq 'renewal') { $obs.renewal = $record; continue }
        $obs.configurations[$entry.label] = $record
        $rowRecords[$rowId] = $record
        if ((Get-Prop $entry 'supplemental') -eq 'LookFx-v1') { $obs.supplemental['playing'] = $record }
        # Preserve the established exhaustive-worst anchor/pointer universe; FX is reported separately.
        if ($entry.class -eq 'playing' -and -not $entry.Contains('supplemental') -and
            ($entry.condition -eq 'fixture-max' -or $GateProfile -eq 'Fast-v2')) {
            $o = Copy-LookOptions (Get-ThemeDefaults $theme)
            $o['width'] = $entry.width; $o['scale'] = $entry.scale; $o['showTimes'] = $entry.showTimes
            if ($null -ne (Get-Prop $entry 'backgroundBlur')) { $o['backgroundBlur'] = $entry.backgroundBlur }
            $row = @($sizes.rows | Where-Object { $_.theme -eq $theme -and $_.width -eq $o.width -and $_.scale -eq $o.scale -and
                $_.showArt -and $_.showArtist -and $_.showProgress -and $_.showTimes -eq $o.showTimes } | Select-Object -First 1)
            if ($row.Count -ne 1) { throw "A-FRAMES: missing independent size row $($entry.label)" }
            $area = [double] $row[0].box.w * [double] $row[0].box.h
            $score = $area * [Math]::Max(0, [double] $record.trace.fps) * $(if ($theme -in @('pill', 'standard', 'classic', 'card')) { 2 } else { 1 })
            if (-not $worst -or $score -gt $worst.score) {
                $worst = [ordered]@{ score = $score; theme = $theme; width = $o.width; scale = $o.scale; options = $o
                    rowId = $rowId; configuration = [ordered]@{ theme = $theme; config = $entry.config; showTimes = $entry.showTimes; rate = $entry.rate; condition = $entry.condition }
                    source = $row[0].source; trace = $record.trace.trace }
            }
        }
        if ($entry.class -in @('playing', 'pixel') -and $record.o3Trigger) {
            Stop-FramesForO3 $obs $record $worst $pausedExtensions
            return
        }
        if ($entry.class -eq 'idle' -and $theme -ne 'pill' -and ($record.trace.frames -ne 0 -or $record.ticks -ne 0)) { $pausedExtensions.Add($theme) }
    }
    $missing = @($frameRows | Where-Object { -not (Test-JournalRowPassed -Id $_.id) } | ForEach-Object { $_.id })
    $selectedMissing = @($frameRows | Where-Object { $_.selected -and -not (Test-JournalRowPassed -Id $_.id) } | ForEach-Object { $_.id })
    $allGreen = @($checks | Where-Object { $_.name -like 'A-FRAMES.*' -and $_.status -ne 'pass' }).Count -eq 0
    $fullGate = Test-DefaultRowSelectors
    $framesComplete = $fullGate -and $missing.Count -eq 0 -and $allGreen -and [bool] $worst
    $worstFile = Join-Path $runDirectory 'frames-worst.json'
    [IO.File]::WriteAllText($worstFile, (ConvertTo-Json -Depth 16 -InputObject ([ordered]@{
        version = 2; protocol = $GateProfile; scope = "$GateProfile observed"; worstDescription = 'worst observed in this profile'
        worst = $worst; pausedExtensions = @($pausedExtensions | Select-Object -Unique)
        profileComplete = [bool] $framesComplete; exhaustiveComplete = [bool] ($GateProfile -eq 'Exhaustive-v1' -and $framesComplete)
        framesGreen = [bool] ($GateProfile -eq 'Exhaustive-v1' -and $framesComplete); complete = [bool] $framesComplete; missingIds = $missing
    })), [Text.UTF8Encoding]::new($false))
    if ($fullGate) {
        $aggregate = if ($GateProfile -eq 'Fast-v2') { 'A-FRAMES.fastProfileRows' } else { 'A-FRAMES.allRequiredRows' }
        Add-Check $aggregate 'every required profile frame row and assertion green; worst observed in this profile retained' (
            [ordered]@{ rows = $frameRows.Count; missingIds = $missing; worst = $worst; file = $worstFile }) $framesComplete
    } else {
        Add-Check 'A-FRAMES.selectedRows' 'every selected inventory frame row green (diagnostic, not a full gate)' (
            [ordered]@{ rows = @($frameRows | Where-Object { $_.selected }).Count; missingIds = $selectedMissing
                omittedIds = @($frameRows | Where-Object { -not $_.selected } | ForEach-Object { $_.id }); file = $worstFile }) ($selectedMissing.Count -eq 0 -and $allGreen)
    }
    $scenarioResults['A-FRAMES'] = $obs
}

. (Join-Path $PSScriptRoot 'obs-overlay-e2e-p2.ps1')

# ---------------------------------------------------------------------------------------------------------------
# Runner (serial: every scenario binds the fixed port 47813)

$appVersion = $null
$scenarioErrors = [ordered]@{}
$functions = [ordered]@{
    'A-PLAIN' = { Test-APlain }; 'A-LOOK' = { Test-ALook }; 'A-OFF' = { Test-AOff }; 'A-TIME' = { Test-ATime }
    'A-AD' = { Test-AAd }; 'A-SAME' = { Test-ASame }; 'A-CLOCK' = { Test-AClock }; 'A-GAP' = { Test-AGap }
    'A-INV' = { Test-AInv }; 'A-IDLE' = { Test-AIdle }; 'A-DEMAND' = { Test-ADemand }; 'A-LIVE' = { Test-ALive }
    'A-LIFE' = { Test-ALife }; 'A-SEC' = { Test-ASec }; 'A-RECON' = { Test-ARecon }; 'A-STORE-1' = { Test-AStore1 }
    'A-SAMPLE' = { Test-ASample }; 'A-TEXT' = { Test-AText }; 'A-ART' = { Test-AArt }; 'A-SET' = { Test-ASet }
    'A-PROD' = { Test-AProd }; 'A-PAUSEVIEW' = { Test-APauseView }; 'A-TOOLBAR' = { Test-AToolbar }
    'A-FRAMES' = { Test-AFrames }
    'A-FONT' = { Test-AFont }; 'A-STORE-2' = { Test-AStore2 }; 'A-DESIGNER' = { Test-ADesigner }
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
    Initialize-RunJournal -BoundParameters $PSBoundParameters
    $foreignStreams = $null; $foreignDiagnostic = $null; $preflight = $null
    if (-not (Test-PrefixRegistrable)) {
        $foreignDiagnostic = 'the overlay prefix is already owned before the harness preflight'
    } else {
        try {
            $preflight = Start-OverlayRun 'harness-preflight' @{} 'Playing' -NoReader
            [void] (Wait-BenchReady $preflight.Root)
            Start-Sleep -Seconds 4
            $preflightState = Get-State $preflight.Root 'foreign-viewer-preflight'
            $foreignStreams = Get-Overlay $preflightState 'streams'
            if ($null -eq $foreignStreams) { $foreignDiagnostic = 'the preflight stream count was unavailable' }
            elseif ($foreignStreams -gt 0) { $foreignDiagnostic = "found $foreignStreams pre-existing viewer stream(s) on $overlayUrl" }
        } catch { $foreignDiagnostic = "preflight failed: $($_.Exception.Message)" }
        finally { if ($preflight) { Stop-OverlayRun $preflight } }
    }
    Add-Check 'harness.foreignViewersAbsent' 'the overlay starts with zero non-harness streams on localhost:47813' ([ordered]@{
        streams = $foreignStreams; diagnostic = $foreignDiagnostic }) ($null -ne $foreignStreams -and $foreignStreams -eq 0)
    if ('fxpaint' -in $Section) {
        # The diagnostic has no required rows; do not route it through gate selector validation/generation.
        $script:requiredRowInventory = @()
        [IO.File]::WriteAllText((Join-Path $runDirectory 'inventory.json'), (ConvertTo-Json -Depth 12 -InputObject (
            [ordered]@{ version = $script:rowInventoryVersion; protocol = $GateProfile; diagnosticOnly = $true
                predictedTotalSeconds = 0; rows = @() })), [Text.UTF8Encoding]::new($false))
    } else { Initialize-RequiredRowInventory }
    $script:frameCalibration = $null
    if ('A-FRAMES' -in $selected -and (Test-ScenarioSelected -Name 'A-FRAMES') -and $null -ne $foreignStreams -and $foreignStreams -eq 0) {
        if (Test-PrefixRegistrable) {
            try { [void] (Invoke-FrameCalibration) } catch {
                Add-Check 'A-FRAMES.calibration.completed' 'calibration ran to completion before other selected scenarios' $_.Exception.Message $false
                if (-not $script:frameCalibration) { $script:frameCalibration = [ordered]@{ mutants = [ordered]@{}; passed = $false } }
                $script:frameCalibration.passed = $false
            }
        } else {
            Add-Blocked 'A-FRAMES.calibration.portFree' "http://localhost:$port/ free before calibration" 'another process holds the overlay prefix'
            $script:frameCalibration = [ordered]@{ mutants = [ordered]@{}; passed = $false }
        }
    }
    foreach ($name in $selected) {
        # Section selectors (scripts/obs-overlay-inventory.ps1) can deselect a whole scenario; '*' selects all.
        if (-not (Test-ScenarioSelected -Name $name) -and -not ($name -eq 'A-LOOK' -and 'fxpaint' -in $Section)) { continue }
        if ($null -eq $foreignStreams -or $foreignStreams -ne 0) {
            $why = if ($foreignDiagnostic) { $foreignDiagnostic } else { 'preflight could not verify zero foreign viewers' }
            Add-Blocked "$name.foreignViewer" 'zero non-harness viewers on localhost:47813 before scenarios' $why
            continue
        }
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
    foreach ($key in @($testEnv.Keys) + $benchEnvKeys) { [Environment]::SetEnvironmentVariable($key, [NullString]::Value, 'Process') }
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

# Every selected scenario/row must produce passing evidence; omitted diagnostic sections are not failures.
foreach ($name in $selected) {
    if (-not (Test-ScenarioSelected -Name $name) -and -not ($name -eq 'A-LOOK' -and 'fxpaint' -in $Section)) { continue }
    if (-not ($checks | Where-Object { $_.name -like "$name.*" })) { Add-Check "$name.producedChecks" 'at least one check' 0 $false }
}
$coverage = Get-RequiredRowCoverage
if ($script:requiredRowInventory.Count -gt 0) {
    Add-Check 'harness.selectedRowCoverage' 'every selected required row completed and passed (including valid journal reuse)' (
        [ordered]@{ selected = $coverage.selected; missingIds = $coverage.missingIds }) ($coverage.missing -eq 0)
}
# A failed/blocked early frame exit can never leave a certifying worst-case artifact.
if ('A-FRAMES' -in $selected -and (Test-ScenarioSelected -Name 'A-FRAMES')) {
    $frameMissing = @($script:requiredRowInventory | Where-Object { $_.scenario -eq 'A-FRAMES' -and -not (Test-JournalRowPassed -Id $_.id) } | ForEach-Object { $_.id })
    $worstFile = Join-Path $runDirectory 'frames-worst.json'
    $worstReport = if (Test-Path -LiteralPath $worstFile -PathType Leaf) {
        Get-Content -Raw -LiteralPath $worstFile | ConvertFrom-Json -AsHashtable -Depth 16
    } else { [ordered]@{ version = 2; worst = $null; pausedExtensions = @(); framesGreen = $false; profileComplete = $false } }
    $worstReport['protocol'] = $GateProfile
    $worstReport['scope'] = "$GateProfile observed"
    $worstReport['worstDescription'] = 'worst observed in this profile'
    $worstReport['missingIds'] = $frameMissing
    if (-not (Test-DefaultRowSelectors) -or $frameMissing.Count -gt 0) {
        $worstReport['framesGreen'] = $false; $worstReport['profileComplete'] = $false
    }
    if ($GateProfile -eq 'Fast-v2') { $worstReport['framesGreen'] = $false }
    $worstReport['exhaustiveComplete'] = [bool] ($GateProfile -eq 'Exhaustive-v1' -and $worstReport['framesGreen'])
    $worstReport['complete'] = [bool] $worstReport['profileComplete']
    [IO.File]::WriteAllText($worstFile, (ConvertTo-Json -Depth 16 -InputObject $worstReport), [Text.UTF8Encoding]::new($false))
}
# Compact each scenario independently before building the report; never serialize a second full evidence graph.
foreach ($scenarioName in @($scenarioResults.Keys)) {
    $value = $scenarioResults[$scenarioName]
    $scenarioChecks = @($checks | Where-Object { $_.name -like "$scenarioName.*" })
    $summary = [ordered]@{ scenario = $scenarioName; checkCount = $scenarioChecks.Count
        pass = @($scenarioChecks | Where-Object { $_.status -eq 'pass' }).Count
        fail = @($scenarioChecks | Where-Object { $_.status -eq 'fail' }).Count
        blocked = @($scenarioChecks | Where-Object { $_.status -eq 'blocked' }).Count }
    if ($value -is [Collections.IDictionary]) {
        foreach ($key in $value.Keys) {
            $item = $value[$key]
            if ($null -eq $item -or $item -is [ValueType] -or ($item -is [string] -and $item.Length -le 1024)) {
                $summary[$key] = $item
            } elseif ($item -is [Collections.IDictionary] -or $item -is [Collections.IList]) {
                $summary["${key}Count"] = $item.Count
            }
        }
    }
    $scenarioResults[$scenarioName] = ConvertTo-RunEvidenceReference -Value $value -Label "scenario-$scenarioName" -Summary $summary
}
$failed = @($checks | Where-Object { $_.status -eq 'fail' })
$blocked = @($checks | Where-Object { $_.status -eq 'blocked' })
$deferredP1 = @($checks | Where-Object { $_.status -eq 'deferred:P1' })
$deferredP2 = @($checks | Where-Object { $_.status -eq 'deferred:P2' })
$passed = $checks.Count -gt 0 -and $failed.Count -eq 0 -and $blocked.Count -eq 0
$diagnosticPassed = [bool] $passed
$gateComplete = (Test-DefaultRowSelectors) -and $script:requiredRowInventory.Count -gt 0 -and $coverage.missing -eq 0 -and $diagnosticPassed
$profileComplete = [bool] $gateComplete
$exhaustiveComplete = [bool] ($GateProfile -eq 'Exhaustive-v1' -and $profileComplete)
$report = [ordered]@{
    command = $commandLine; runId = $runId; appVersion = $appVersion; pipePrefix = $prefix; harnessElevated = $isElevated
    launches = @($launches); scenarios = $scenarioResults
    coverage = $coverage; diagnosticPassed = $diagnosticPassed; gateComplete = [bool] $gateComplete
    protocol = $GateProfile; profileComplete = $profileComplete; exhaustiveComplete = $exhaustiveComplete
    rotation = $script:frameRotation; priorWorst = $script:priorWorst
    summary = [ordered]@{
        pass = @($checks | Where-Object { $_.status -eq 'pass' }).Count; fail = $failed.Count; blocked = $blocked.Count
        deferred = [ordered]@{ P1 = $deferredP1.Count; P2 = $deferredP2.Count; total = $deferredP1.Count + $deferredP2.Count }
    }
    checks = @($checks); passed = [bool] $passed
}
if ('fxpaint' -in $Section) {
    $report.summary['skippedNotApplicable'] = @($checks | Where-Object { $_.status -eq 'skipped-not-applicable' }).Count
}
[IO.File]::WriteAllText((Join-Path $runDirectory 'report.json'), ($report | ConvertTo-Json -Depth 100), [Text.UTF8Encoding]::new($false))
if ($exhaustiveComplete -and 'A-FRAMES' -in $selected -and (Test-ScenarioSelected -Name 'A-FRAMES') -and $worstReport.framesGreen) {
    $pointer = [ordered]@{ version = 1; rowId = $worstReport.worst.rowId; configuration = $worstReport.worst.configuration
        sourceReport = [IO.Path]::GetRelativePath($repo, $worstFile).Replace('\', '/')
        sourceSha256 = (Get-FileHash -LiteralPath $worstFile -Algorithm SHA256).Hash.ToLowerInvariant() }
    # Publish the last complete exhaustive observation only; partial/fast runs never replace it.
    $pointerPath = Join-Path $fixtureDirectory 'exhaustive-worst.json'
    $pointerTemp = "$pointerPath.$runId.tmp"
    try {
        [IO.File]::WriteAllText($pointerTemp, (ConvertTo-Json -Depth 16 -InputObject $pointer), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($pointerTemp, $pointerPath, $true)
    } finally { if (Test-Path -LiteralPath $pointerTemp) { Remove-Item -LiteralPath $pointerTemp -Force } }
}
[IO.File]::WriteAllText((Join-Path $runDirectory 'events.json'), ($eventsByReader | ConvertTo-Json -Depth 6), [Text.UTF8Encoding]::new($false))
$report.summary | ConvertTo-Json
Write-Host "Report: $(Join-Path $runDirectory 'report.json')"
if (-not $passed) { exit 1 }
