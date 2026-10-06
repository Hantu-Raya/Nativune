<#
EQ Gates A+B: real hook app, production isolated-world attach path, synthetic non-silent stereo media.
Regenerate exactly (all rows, both sample rates):
  pwsh -NoProfile -File scripts/eq-e2e.ps1 -OutputDirectory artifacts/eq-e2e
Never ship artifacts/eq-e2e/app. Profiles live only under .cache/eq-e2e; owner data is untouched.
Reports retain statistics/response oracles, not PCM. Mutant rows pass ONLY when the audio oracle rejects them.
#>
[CmdletBinding()]
param([string] $OutputDirectory = 'artifacts/eq-e2e', [switch] $SkipPublish, [switch] $KeepRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N')
$output = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
$run = Join-Path $output $runId
$rootBase = Join-Path $repo ".cache/eq-e2e/$runId"
$app = Join-Path $repo 'artifacts/eq-e2e/app'
$exe = Join-Path $app 'Nativune.exe'
[IO.Directory]::CreateDirectory($run) | Out-Null
[IO.Directory]::CreateDirectory($rootBase) | Out-Null
$rows = [Collections.Generic.List[object]]::new()
$launches = [Collections.Generic.List[object]]::new()
$script:sequence = 0
$script:process = $null
$script:root = $null
# Fixed independent audio oracle: for a 63 Hz tone at 44.1/48 kHz, the smooth 8 ms
# time-constant (~25 ms settling) gain ramp's initial slope is <0.004 of dry RMS.
# A discontinuous 12 dB gain step has order-unity second difference. 0.01 leaves
# quantization/phase margin without adapting to a mutant's observed result.
$ClickRatioLimit = 0.01
$ResponseToleranceDb = 0.5
$NullLimitDb = -80
$requiredRows = @('foreign-source.de-elevated','foreign-source-rejected-before-attach')
foreach ($rate in @(48000,44100)) {
    $requiredRows += "rate-$rate.de-elevated"
    foreach ($suffix in @('cold-Off','natural-policy','gesture-active','blob-playing','series-response','Flat-null',
        'attached-Off-null','transient','mutant-parallel','restore-parallel','mutant-preamp-ignored','restore-preamp-ignored',
        'mutant-duplicate-path','restore-duplicate-path','click-none','click-zero-ramp','stale-rollback',
        'suspend-rejected-resume','normal-resume','suspend-normal-resume','element-replacement','navigation-new-world')) {
        $requiredRows += "$rate.$suffix"
    }
    for ($band=0;$band -lt 10;$band++) { $requiredRows += "$rate.band-$band-response" }
    $requiredRows += "injected-$rate.de-elevated"
    foreach ($suffix in @('waiting','synthetic-event','no-spin','click')) { $requiredRows += "$rate.injected-block-$suffix" }
}
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class EqE2EInput {
 [StructLayout(LayoutKind.Sequential)] struct Mouse { public int x,y;public uint data,flags,time;public UIntPtr extra; }
 [StructLayout(LayoutKind.Explicit)] struct Union { [FieldOffset(0)] public Mouse mouse; }
 [StructLayout(LayoutKind.Sequential)] struct Input { public uint type;public Union u; }
 [DllImport("user32.dll")] static extern uint SendInput(uint count,Input[] input,int size);
 [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr p,uint access,out IntPtr t);
 public static IntPtr Token(int pid) { var p=OpenProcess(0x1000,false,pid);try {IntPtr t;return OpenProcessToken(p,0xA,out t)?t:IntPtr.Zero;}finally{CloseHandle(p);} }
 public static void CloseToken(IntPtr t){CloseHandle(t);}
 public static void Click(int x,int y){SetCursorPos(x,y);var a=new Input[2];a[0].u.mouse.flags=2;a[1].u.mouse.flags=4;
   if(SendInput(2,a,Marshal.SizeOf(typeof(Input)))!=2)throw new Exception("SendInput failed");}
}
'@
function Wait-For([scriptblock] $Condition, [double] $Seconds = 15) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do { if (& $Condition) { return $true }; Start-Sleep -Milliseconds 150 } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}
function Row([string] $Name, [bool] $Pass, $Evidence) {
    $rows.Add([ordered]@{ name = $Name; status = $(if ($Pass) { 'pass' } else { 'fail' }); evidence = $Evidence })
}
function Hook([string] $Command, $Value = $null) {
    $label = 'r' + (++$script:sequence).ToString('d5')
    $dir = Join-Path $script:root 'data/discord-bench'
    [IO.Directory]::CreateDirectory($dir) | Out-Null
    $request = Join-Path $dir "command-eq-$label.json"
    $response = Join-Path $dir "eq-$label.json"
    $temp = "$request.tmp"
    [IO.File]::WriteAllText($temp, (@{ command = $Command; value = $Value } | ConvertTo-Json -Depth 16 -Compress))
    [IO.File]::Move($temp, $request)
    if (-not (Wait-For { Test-Path -LiteralPath $response } 15)) { throw "EQ command $Command timed out ($label)." }
    $answer = Get-Content -Raw -LiteralPath $response | ConvertFrom-Json -Depth 32
    Copy-Item -LiteralPath $response -Destination (Join-Path $run "$label-$Command.json")
    if (-not $answer.ok) { throw "EQ command $Command failed: $($answer.error)" }
    return $answer.result
}
function Apply($Gains = @(0,0,0,0,0,0,0,0,0,0), [double] $Preamp = 0, [bool] $Enabled = $true) {
    Hook 'eq-apply' @{ enabled = $Enabled; gains = @($Gains); preampDb = $Preamp; bypass = $false }
}
function Status-Is([string] $State, [double] $Seconds = 10) {
    $script:lastStatus = $null
    Wait-For { $script:lastStatus = Hook 'eq-status'; $script:lastStatus.state -ceq $State } $Seconds
}
function Click-Page {
    # Fresh UIA grounds the input in the fixture button's actual bounds; InvokePattern is
    # intentionally NOT used because activation must be a trusted pointer gesture.
    $window = $null; $button = $null
    $found = Wait-For {
        $condition = [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$script:process.Id)
        $windows = [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,$condition)
        foreach ($w in $windows) {
            $b = $w.FindFirst([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'Activate EQ fixture'))
            if ($b -and -not $b.Current.IsOffscreen) { $script:clickWindow = $w; $script:clickButton = $b; return $true }
        }
        return $false
    } 20
    if (-not $found) { throw 'Visible Activate EQ fixture UIA button not found.' }
    $window = $script:clickWindow; $button = $script:clickButton
    [void][EqE2EInput]::SetForegroundWindow([IntPtr]$window.Current.NativeWindowHandle)
    $bounds = $button.Current.BoundingRectangle
    [EqE2EInput]::Click([int]($bounds.X+$bounds.Width/2),[int]($bounds.Y+$bounds.Height/2))
}
$launchHelper = Join-Path $rootBase 'launch-helper.ps1'
[IO.File]::WriteAllText($launchHelper, @'
param([string]$Spec)
$ErrorActionPreference='Stop'
$s=Get-Content -Raw -LiteralPath $Spec|ConvertFrom-Json
foreach($k in @($s.unset)){[Environment]::SetEnvironmentVariable($k,[NullString]::Value,'Process')}
foreach($p in $s.env.PSObject.Properties){[Environment]::SetEnvironmentVariable($p.Name,[string]$p.Value,'Process')}
$p=Start-Process -FilePath $s.exe -ArgumentList @('web','--root',$s.root) -WorkingDirectory $s.app -PassThru
[IO.File]::WriteAllText($s.pidFile,(@{processId=$p.Id}|ConvertTo-Json))
'@)
function Start-Fixture([string] $Name, [int] $Rate = 48000) {
    $script:root = Join-Path $rootBase $Name
    [IO.Directory]::CreateDirectory((Join-Path $script:root 'data')) | Out-Null
    $ubolVersion = [regex]::Match((Get-Content -Raw (Join-Path $repo 'src/Nativune/BrowserPrivacy.cs')),'ExtensionVersion\s*=\s*"([^"]+)"').Groups[1].Value
    $ubol = Join-Path $repo ".tools/ubol/$ubolVersion"
    if (-not (Test-Path -LiteralPath (Join-Path $ubol 'manifest.json'))) { throw "Missing pinned uBO Lite: $ubol" }
    $dest = Join-Path $script:root '.tools/ubol'
    [IO.Directory]::CreateDirectory($dest) | Out-Null
    Copy-Item -LiteralPath $ubol -Destination $dest -Recurse
    $settings = @{ Version=8; X=100; Y=100; Width=1280; Height=800; Dpi=96; Zoom=1;
        TrayEnabled=$false; SleepInBackground=$false; StartCompact=$false; AutoCheckUpdates=$false;
        OutputVolume=1; BlockAds=$false; DiscordPresence=$false; ObsOverlay=$false }
    [IO.File]::WriteAllText((Join-Path $script:root 'data/settings.json'),($settings|ConvertTo-Json))
    $environment = @{ NATIVUNE_TEST_DISCORD_FIXTURE_PAGE='1'; NATIVUNE_TEST_EQ_FIXTURE='1';
        NATIVUNE_TEST_EQ_SAMPLE_RATE="$Rate"; NATIVUNE_TEST_DISCORD_CLIENT_ID='100000000000000001';
        NATIVUNE_TEST_DISCORD_PIPE_PREFIX=('nativune-test-'+[guid]::NewGuid().ToString('N')+'-discord-ipc-') }
    $unset = @('NATIVUNE_TEST_DISCORD_BENCH_PROFILE','NATIVUNE_TEST_DISCORD_BENCH_STATE','WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS')
    if ($isElevated) {
        $pidFile = Join-Path $script:root 'launch.pid.json'; $spec = Join-Path $script:root 'launch.json'
        [IO.File]::WriteAllText($spec,(@{exe=$exe;app=$app;root=$script:root;env=$environment;unset=$unset;pidFile=$pidFile}|ConvertTo-Json -Depth 8))
        & runas.exe '/trustlevel:0x20000' "pwsh.exe -NoProfile -ExecutionPolicy Bypass -File `"$launchHelper`" `"$spec`"" | Out-Null
        if (-not (Wait-For { Test-Path -LiteralPath $pidFile } 30)) { throw 'Restricted-token launch wrote no PID.' }
        $script:process = Get-Process -Id ((Get-Content -Raw $pidFile|ConvertFrom-Json).processId)
    } else {
        foreach ($key in $unset) { [Environment]::SetEnvironmentVariable($key,[NullString]::Value,'Process') }
        foreach ($e in $environment.GetEnumerator()) { [Environment]::SetEnvironmentVariable($e.Key,$e.Value,'Process') }
        $script:process = Start-Process -FilePath $exe -ArgumentList @('web','--root',$script:root) -WorkingDirectory $app -PassThru
    }
    $token = [EqE2EInput]::Token($script:process.Id); $admin = $null
    try {
        if ($token -ne [IntPtr]::Zero) {
            $identity = [Security.Principal.WindowsIdentity]::new($token)
            try { $admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
            finally { $identity.Dispose() }
        }
    } finally { if ($token -ne [IntPtr]::Zero) { [EqE2EInput]::CloseToken($token) } }
    $launches.Add(@{name=$Name;processId=$script:process.Id;viaRunas=$isElevated;adminEnabled=$admin;sampleRate=$Rate})
    Row "$Name.de-elevated" ($admin -eq $false) $launches[$launches.Count-1]
    if (-not (Wait-For { try { (Hook 'eq-media').fixture } catch { $false } } 60)) { throw 'Synthetic EQ page did not become ready.' }
    [void](Hook 'eq-profile' "tones-$Rate")
    if (-not (Wait-For { (Hook 'eq-media').readyState -ge 2 } 15)) { throw 'EQ WAV did not load.' }
}
function Stop-Fixture {
    if ($script:process -and -not $script:process.HasExited) {
        $dir=Join-Path $script:root 'data/discord-bench'
        [IO.File]::WriteAllText((Join-Path $dir 'command-quit'),'go')
        if (-not $script:process.WaitForExit(8000)) { Stop-Process -Id $script:process.Id -Force -ErrorAction SilentlyContinue }
    }
    # Kill only WebView children whose command line contains this disposable root.
    if ($script:root) { foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId,CommandLine)) {
        if ($p.CommandLine -and $p.CommandLine.Contains($script:root,[StringComparison]::OrdinalIgnoreCase)) {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
        }
    } }
    $script:process=$null
}
function Collect($Options = @{}) {
    [void](Hook 'eq-collect-reset' $Options)
    Read-Collection
}
function Read-Collection {
    $script:collection=$null
    if (-not (Wait-For { $script:collection=Hook 'eq-collect-read'; $script:collection.complete } 15)) { throw 'Audio collector never completed (silent/suspended graph).' }
    return $script:collection
}
function Response-Oracle($Measurement,$Gains,[double]$Preamp) {
    $expected = Hook 'eq-response' @{gains=@($Gains);frequencies=@($Measurement.frequencies);sampleRate=$Measurement.sampleRate}
    $maxMath=0.0; $maxNode=0.0; $observed=@()
    for ($ch=0;$ch -lt 2;$ch++) {
        $response=@()
        for ($k=0;$k -lt $Measurement.frequencies.Count;$k++) {
            if ($Measurement.dry[$ch][$k] -le 1e-6 -or $Measurement.wet[$ch][$k] -le 1e-9) { return @{pass=$false;error='silent frequency'} }
            $db=20*[Math]::Log10($Measurement.wet[$ch][$k]/$Measurement.dry[$ch][$k]); $response+=$db
            $maxMath=[Math]::Max($maxMath,[Math]::Abs($db-($expected.responseDb[$k]+$Preamp)))
            $maxNode=[Math]::Max($maxNode,[Math]::Abs($db-$Measurement.frequencyResponseDb[$k]))
        }
        $observed+=,@($response)
    }
    return @{pass=($maxMath -le $ResponseToleranceDb -and $maxNode -le $ResponseToleranceDb -and
        $Measurement.dryRms[0] -gt 0.0001 -and $Measurement.dryRms[1] -gt 0.0001);
        maxMathErrorDb=$maxMath;maxNodeErrorDb=$maxNode;expectedDb=@($expected.responseDb|ForEach-Object{$_+$Preamp});
        measuredDb=$observed;statistics=$Measurement}
}
function Run-Rate([int] $Rate) {
    Start-Fixture "rate-$Rate" $Rate
    try {
        $off=Hook 'eq-status'
        Row "$Rate.cold-Off" ($off.state -ceq 'off' -and -not $off.attached -and -not $off.ctx) $off
        $natural=Apply
        $activationRequired=$natural.state -ceq 'waiting' -and $natural.reason -ceq 'gesture' -and
            $natural.contextState -cne 'running' -and -not $natural.attached
        $alreadyActive=$natural.state -ceq 'active' -and $natural.contextState -ceq 'running' -and $natural.attached
        Row "$Rate.natural-policy" ($activationRequired -or $alreadyActive) @{
            activationRequired=[bool]$activationRequired;status=$natural;scope='This fresh profile and runtime only; no universal autoplay-policy claim.'}
        if ($activationRequired) { Click-Page }
        $active=Status-Is 'active'
        Row "$Rate.gesture-active" ($active -and $script:lastStatus.attached -and $script:lastStatus.sampleRate -eq $Rate) $script:lastStatus
        if (-not $active) { throw 'Production attach did not become active under the observed natural policy.' }
        $media=Hook 'eq-media'
        Row "$Rate.blob-playing" (-not $media.paused -and $media.currentSrc.StartsWith('blob:https://music.youtube.com/')) $media
        for ($band=0;$band -lt 10;$band++) {
            $g=@(0,0,0,0,0,0,0,0,0,0);$g[$band]=6
            [void](Apply $g -8)
            $oracle=Response-Oracle (Collect) $g -8
            Row "$Rate.band-$band-response" $oracle.pass $oracle
        }
        $series=@(6,-3,5,0,-4,7,-2,5,-3,4)
        [void](Apply $series -12)
        $oracle=Response-Oracle (Collect) $series -12
        Row "$Rate.series-response" $oracle.pass $oracle
        [void](Apply)
        $flat=Collect
        Row "$Rate.Flat-null" ($flat.dryRms[0] -gt 0.001 -and $flat.dryRms[1] -gt 0.001 -and
            $flat.nullDb[0] -le $NullLimitDb -and $flat.nullDb[1] -le $NullLimitDb) $flat
        [void](Apply $series -12)
        [void](Apply @(0,0,0,0,0,0,0,0,0,0) 0 $false)
        $offNull=Collect
        Row "$Rate.attached-Off-null" ($offNull.dryRms[0] -gt 0.001 -and $offNull.dryRms[1] -gt 0.001 -and
            $offNull.nullDb[0] -le $NullLimitDb -and $offNull.nullDb[1] -le $NullLimitDb) $offNull
        # Bursty asymmetric content through several boosted bands must remain non-silent.
        [void](Hook 'eq-profile' "transient-$Rate")
        [void](Apply @(6,6,0,4,0,5,0,0,0,0) -18)
        $transient=Collect
        Row "$Rate.transient" ($transient.dryRms[0] -gt 0.001 -and $transient.dryRms[1] -gt 0.001 -and
            $transient.wetRms[0] -gt 0.0001 -and $transient.wetRms[1] -gt 0.0001 -and
            $transient.wetPeak[0] -lt 1 -and $transient.wetPeak[1] -lt 1 -and $transient.complete) $transient
        [void](Hook 'eq-profile' "tones-$Rate")
        foreach ($mutant in @('parallel','preamp-ignored','duplicate-path')) {
            [void](Hook 'eq-mutant' $mutant)
            [void](Apply $series -12)
            $oracle=Response-Oracle (Collect) $series -12
            Row "$Rate.mutant-$mutant" (-not $oracle.pass) @{verdict=$(if(-not $oracle.pass){'mutant detected'}else{'mutant escaped'});oracle=$oracle}
            [void](Hook 'eq-mutant' 'none')
            [void](Apply $series -12)
            $recovery=Response-Oracle (Collect) $series -12
            Row "$Rate.restore-$mutant" $recovery.pass $recovery
        }
        [void](Hook 'eq-profile' "click-$Rate")
        foreach ($mode in @('none','zero-ramp')) {
            [void](Hook 'eq-mutant' $mode);[void](Apply)
            Start-Sleep -Milliseconds 500
            [void](Hook 'eq-collect-reset' @{frequencies=@(63);seconds=2;settle=0})
            [void](Apply @(0,0,0,0,0,0,0,0,0,0) -12)
            $click=Read-Collection
            $pass=if($mode -eq 'none'){$click.clickRatio -le $ClickRatioLimit}else{$click.clickRatio -gt $ClickRatioLimit}
            $pass = $pass -and [double]::IsFinite($click.clickRatio) -and $click.dryRms[0] -gt 0.01 -and $click.dryRms[1] -gt 0.01
            Row "$Rate.click-$mode" $pass @{limit=$ClickRatioLimit;measured=$click.clickRatio;
                verdict=$(if($mode -eq 'zero-ramp' -and $pass){'mutant detected'}elseif($pass){'smooth ramp'}else{'oracle failed'});statistics=$click}
        }
        [void](Hook 'eq-mutant' 'none')
        [void](Hook 'eq-profile' "tones-$Rate")
        [void](Apply @(0,0,0,0,0,0,0,0,0,0) -3)
        $latest=Apply $series -12
        $late=Hook 'eq-stale'
        Row "$Rate.stale-rollback" ($late.rev -eq $latest.rev -and $late.state -ceq 'active') @{latest=$latest;late=$late}
        [void](Hook 'eq-reject-resume')
        [void](Hook 'eq-suspend')
        $interrupted=Status-Is 'interrupted'
        Row "$Rate.suspend-rejected-resume" $interrupted $script:lastStatus
        Click-Page
        $resumed=Status-Is 'active'
        Row "$Rate.normal-resume" $resumed $script:lastStatus
        [void](Hook 'eq-suspend')
        $resumed=Status-Is 'active'
        Row "$Rate.suspend-normal-resume" $resumed $script:lastStatus
        [void](Hook 'eq-replace-element')
        $replaced=Status-Is 'reloadNeeded'
        Row "$Rate.element-replacement" $replaced $script:lastStatus
        $generationBefore=(Get-Content -Raw (Join-Path $script:root ('data/discord-bench/eq-r'+$script:sequence.ToString('d5')+'.json'))|ConvertFrom-Json).generation
        [void](Hook 'eq-navigate')
        $newOff=Status-Is 'off' 20
        $new=Hook 'eq-status'
        $generationAfter=(Get-Content -Raw (Join-Path $script:root ('data/discord-bench/eq-r'+$script:sequence.ToString('d5')+'.json'))|ConvertFrom-Json).generation
        Row "$Rate.navigation-new-world" ($newOff -and -not $new.ctx -and -not $new.attached -and $generationAfter -gt $generationBefore) @{before=$generationBefore;after=$generationAfter;status=$new}
    } finally { Stop-Fixture }
}
function Run-InjectedBlock([int] $Rate) {
    Start-Fixture "injected-$Rate" $Rate
    try {
        # Start ORIGINAL playback with real input before arming the isolated-world machinery.
        # No EQ context exists yet. This separates media activation from the injected EQ block.
        Click-Page
        [void](Hook 'eq-block-activation')
        $first=Hook 'eq-media'
        $waiting=Apply
        Start-Sleep -Milliseconds 600
        $second=Hook 'eq-media'
        Row "$Rate.injected-block-waiting" ($waiting.state -ceq 'waiting' -and $waiting.reason -ceq 'gesture' -and
            $waiting.contextState -ceq 'suspended' -and -not $waiting.attached -and $waiting.activation.sourceCalls -eq 0 -and
            -not $second.paused -and $second.currentTime -gt $first.currentTime) @{
                classification='fixture machinery, not WebView2 policy enforcement';status=$waiting;before=$first;after=$second}
        [void](Hook 'eq-synthetic-event')
        $synthetic=Hook 'eq-status'
        Row "$Rate.injected-block-synthetic-event" ($synthetic.state -ceq 'waiting' -and $synthetic.reason -ceq 'gesture' -and
            $synthetic.contextState -ceq 'suspended' -and -not $synthetic.attached -and $synthetic.activation.blocked -and
            $synthetic.activation.sourceCalls -eq 0) @{
                classification='fixture machinery, not WebView2 policy enforcement';status=$synthetic}
        Start-Sleep -Seconds 5
        $idle=Hook 'eq-status'
        Row "$Rate.injected-block-no-spin" ($idle.state -ceq 'waiting' -and $idle.reason -ceq 'gesture' -and
            $idle.contextState -ceq 'suspended' -and -not $idle.attached -and $idle.activation.resumeCalls -le 2 -and
            $idle.activation.sourceCalls -eq 0) @{
                classification='fixture machinery, not WebView2 policy enforcement';secondsWithoutClick=5;resumeCallLimit=2;status=$idle}
        Click-Page
        $active=Status-Is 'active'
        $status=$script:lastStatus
        $statistics=if($active){Collect}else{$null}
        Row "$Rate.injected-block-click" ($active -and $status.attached -and $status.contextState -ceq 'running' -and
            $status.activation.sourceCalls -eq 1 -and $statistics -and $statistics.wetRms[0] -gt 0 -and $statistics.wetRms[1] -gt 0) @{
                classification='fixture machinery, not WebView2 policy enforcement';status=$status;statistics=$statistics}
    } finally { Stop-Fixture }
}
$failure=$null
try {
    if (-not $SkipPublish) {
        & pwsh -NoProfile -File (Join-Path $repo 'scripts/dotnet.ps1') publish (Join-Path $repo 'src/Nativune/Nativune.csproj') `
            --runtime win-x64 --self-contained false -p:DiscordPresenceTestHooks=true -o $app
        if ($LASTEXITCODE -ne 0) { throw "Hook publish failed ($LASTEXITCODE)." }
    }
    if (-not (Test-Path -LiteralPath $exe)) { throw "Hook app not found: $exe" }
    foreach ($rate in @(48000,44100)) {
        try { Run-Rate $rate } catch { Row "$rate.run-completion" $false @{error=$_.Exception.Message}; Stop-Fixture }
        try { Run-InjectedBlock $rate } catch { Row "$rate.injected-block-completion" $false @{error=$_.Exception.Message}; Stop-Fixture }
    }
    Start-Fixture 'foreign-source'
    try {
        [void](Hook 'eq-profile' 'foreign-source')
        if (-not (Wait-For { (Hook 'eq-media').readyState -ge 2 } 15)) { throw 'Foreign WAV not loaded.' }
        Click-Page
        $rejected=Apply
        $first=Hook 'eq-media'; Start-Sleep -Milliseconds 600; $second=Hook 'eq-media'
        Row 'foreign-source-rejected-before-attach' ($rejected.state -ceq 'notApplied' -and $rejected.reason -ceq 'source' -and
            -not $rejected.attached -and -not $rejected.ctx -and -not $second.paused -and $second.currentTime -gt $first.currentTime) @{status=$rejected;before=$first;after=$second}
    } finally { Stop-Fixture }
} catch { $failure=$_.Exception.Message; Row 'harness-completion' $false @{error=$failure} }
finally {
    Stop-Fixture
    foreach ($key in @('NATIVUNE_TEST_EQ_FIXTURE','NATIVUNE_TEST_EQ_SAMPLE_RATE','NATIVUNE_TEST_DISCORD_FIXTURE_PAGE',
        'NATIVUNE_TEST_DISCORD_PIPE_PREFIX','NATIVUNE_TEST_DISCORD_CLIENT_ID')) { [Environment]::SetEnvironmentVariable($key,[NullString]::Value,'Process') }
    foreach ($name in $requiredRows) {
        if (-not @($rows | Where-Object { $_.name -ceq $name }).Count) {
            $rows.Add([ordered]@{name=$name;status='blocked';evidence=@{reason='Prerequisite failed; row was not executed.'}})
        }
    }
    $failed=@($rows|Where-Object{$_.status -ne 'pass'})
    $report=@{schema=1;utc=[DateTime]::UtcNow.ToString('o');regenerate='pwsh -NoProfile -File scripts/eq-e2e.ps1 -OutputDirectory artifacts/eq-e2e';
        limits=@{responseDb=$ResponseToleranceDb;nullDb=$NullLimitDb;clickRatio=$ClickRatioLimit};launches=@($launches.ToArray());
        rows=@($rows.ToArray());passed=($failed.Count -eq 0);failure=$failure}
    [IO.File]::WriteAllText((Join-Path $run 'report.json'),($report|ConvertTo-Json -Depth 48))
    Write-Host "EQ E2E: $($rows.Count) rows, $($failed.Count) failed. Report: $run/report.json"
    if (-not $KeepRoot -and $failed.Count -eq 0) { Remove-Item -LiteralPath $rootBase -Recurse -Force }
}
if (@($rows|Where-Object{$_.status -ne 'pass'}).Count -gt 0) { exit 1 }
