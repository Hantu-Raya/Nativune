<#
Gate F: synthetic Music whole-tree EQ performance; never use owner profiles.
Regenerate exactly (hook build must already exist at artifacts/eq-e2e/app):
  pwsh -NoProfile -File scripts/eq-bench.ps1 -Pairs 5 -OutputDirectory artifacts/eq-bench
Fixed owner-accepted gates: +0.3 CPU percentage points (total machine), +8 MiB.
Default protocol: fresh process per arm, rotating ABC/BCA/CAB, 60 s windows,
150 s minimum browser age, 30 s settling after each condition change.
#>
[CmdletBinding()]
param([ValidateRange(2,100)][int] $Pairs = 5, [string] $OutputDirectory = 'artifacts/eq-bench', [switch] $KeepRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N')
$output = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
$run = Join-Path $output $runId
$rootBase = Join-Path $repo ".cache/eq-bench/$runId"
$app = Join-Path $repo 'artifacts/eq-e2e/app'
$exe = Join-Path $app 'Nativune.exe'
[IO.Directory]::CreateDirectory($run) | Out-Null
[IO.Directory]::CreateDirectory($rootBase) | Out-Null
$runs = [Collections.Generic.List[object]]::new()
$launches = [Collections.Generic.List[object]]::new()
$script:sequence = 0
$script:process = $null
$script:root = $null
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class EqBenchInput {
 [StructLayout(LayoutKind.Sequential)] struct Mouse { public int x,y;public uint data,flags,time;public UIntPtr extra; }
 [StructLayout(LayoutKind.Explicit)] struct Union { [FieldOffset(0)] public Mouse mouse; }
 [StructLayout(LayoutKind.Sequential)] struct Input { public uint type;public Union u; }
 [DllImport("user32.dll")] static extern uint SendInput(uint count,Input[] input,int size);
 [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int command);
 [DllImport("user32.dll")] public static extern bool IsIconic(IntPtr h);
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
    [void][EqBenchInput]::SetForegroundWindow([IntPtr]$window.Current.NativeWindowHandle)
    $bounds = $button.Current.BoundingRectangle
    [EqBenchInput]::Click([int]($bounds.X+$bounds.Width/2),[int]($bounds.Y+$bounds.Height/2))
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
        NATIVUNE_TEST_EQ_SAMPLE_RATE="$Rate"; NATIVUNE_TEST_OVERLAY_EAGER_GPU_INFO='1'; NATIVUNE_TEST_DISCORD_CLIENT_ID='100000000000000001';
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
    $token = [EqBenchInput]::Token($script:process.Id); $admin = $null
    try {
        if ($token -ne [IntPtr]::Zero) {
            $identity = [Security.Principal.WindowsIdentity]::new($token)
            try { $admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
            finally { $identity.Dispose() }
        }
    } finally { if ($token -ne [IntPtr]::Zero) { [EqBenchInput]::CloseToken($token) } }
    $launches.Add(@{name=$Name;processId=$script:process.Id;viaRunas=$isElevated;adminEnabled=$admin;sampleRate=$Rate})
    if ($admin -ne $false) { throw 'Benchmark app is not proven de-elevated.' }
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

# EX2 includes private working set, not total working set (which counts shared pages).
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class EqBenchMemory {
 [StructLayout(LayoutKind.Sequential)] public struct Counters {
  public uint cb, faults; public UIntPtr peakWs, ws, peakPaged, paged, peakNonpaged, nonpaged,
   pagefile, peakPagefile, privateBytes, privateWs, sharedCommit;
 }
 [DllImport("psapi.dll", SetLastError=true)] static extern bool GetProcessMemoryInfo(IntPtr h,ref Counters c,uint size);
 public static ulong PrivateWorkingSet(IntPtr h) {
  var c=new Counters(); c.cb=(uint)Marshal.SizeOf(typeof(Counters));
  if(!GetProcessMemoryInfo(h,ref c,c.cb)) throw new System.ComponentModel.Win32Exception();
  return c.privateWs.ToUInt64();
 }
}
'@
$logicalProcessors = [int](Get-CimInstance Win32_ComputerSystem -Property NumberOfLogicalProcessors).NumberOfLogicalProcessors
if ($logicalProcessors -lt 1) { throw 'Machine logical processor count is unavailable.' }
$windowSeconds = 60
$sampleMilliseconds = 250
$gateCpuPp = 0.3
$gateMemoryMiB = 8
function Median($Values) {
    $v=@($Values | Sort-Object)
    if (-not $v.Count) { throw 'Empty median.' }
    $mid=[int][Math]::Floor($v.Count/2)
    if ($v.Count % 2) { return [double]$v[$mid] }
    return ([double]$v[$mid-1]+[double]$v[$mid])/2
}
function Owned-WebViews {
    @(Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -Property ProcessId,CreationDate,CommandLine |
        Where-Object { $_.CommandLine -and $_.CommandLine.Contains($script:root,[StringComparison]::OrdinalIgnoreCase) })
}
function Browser {
    $b=@(Owned-WebViews | Where-Object { $_.CommandLine -notmatch '(?:^|\s)--type=' })
    if ($b.Count -ne 1) { throw 'Exactly one owned browser is required.' }
    $b[0]
}
function Assert-Arm([string]$Arm) {
    $s=Hook 'eq-status'
    if ($Arm -eq 'cold-off') {
        if ($s.state -cne 'off' -or $s.attached -or $s.ctx) { throw 'Cold-off created a graph.' }
    } elseif ($Arm -eq 'attached-bypass') {
        if ($s.state -cne 'off' -or -not $s.attached -or $s.contextState -cne 'running') { throw 'Attached bypass is not dry/running.' }
    } elseif ($s.state -cne 'active' -or -not $s.attached -or $s.contextState -cne 'running') { throw 'On is not active/running.' }
    $s
}
function Measure-Tree {
    $ledger=@{}; $clock=[Diagnostics.Stopwatch]::StartNew(); $samples=0
    # Process objects keep their OS handles open, allowing a final CPU read after exit.
    function Sample([bool]$Initial) {
        if ($script:process.HasExited) { throw 'Nativune exited during measurement.' }
        $ids=@($script:process.Id)+@(Owned-WebViews | ForEach-Object {[int]$_.ProcessId})
        $live=@{}; $privateWs=0.0; $privateBytes=0.0
        foreach ($id in $ids) {
            try { $p=Get-Process -Id $id -ErrorAction Stop; $created=$p.StartTime.ToUniversalTime(); $handle=$p.Handle }
            catch { if ($id -eq $script:process.Id) { throw }; continue }
            $key="$id@$($created.ToString('o'))"
            $live[$key]=$true
            if (-not $ledger.ContainsKey($key)) {
                $cpu=$p.TotalProcessorTime.TotalSeconds
                $ledger[$key]=@{pid=$id;createdUtc=$created.ToString('o');process=$p;baseline=$(if($Initial){$cpu}else{0.0});last=$cpu;exited=$false}
            } else { $p.Dispose(); $p=$ledger[$key].process }
            try {
                $p.Refresh(); $ledger[$key].last=$p.TotalProcessorTime.TotalSeconds
                $privateWs += [EqBenchMemory]::PrivateWorkingSet($p.Handle)
                $privateBytes += $p.PrivateMemorySize64
            } catch { if (-not $p.HasExited) { throw } }
        }
        foreach ($key in @($ledger.Keys)) {
            $entry=$ledger[$key]
            if (-not $live.ContainsKey($key) -and -not $entry.exited) {
                try { $entry.process.Refresh(); $entry.last=$entry.process.TotalProcessorTime.TotalSeconds } catch { }
                $entry.exited=$true
            }
        }
        @{privateWorkingSetMiB=$privateWs/1MB;privateBytesMiB=$privateBytes/1MB;liveProcesses=$live.Count}
    }
    try {
        $first=Sample $true
        $start=$clock.Elapsed.TotalSeconds; $startUtc=[DateTime]::UtcNow
        do { Start-Sleep -Milliseconds $sampleMilliseconds; $endMemory=Sample $false; $samples++ }
        while (($clock.Elapsed.TotalSeconds-$start) -lt $windowSeconds)
        $elapsed=$clock.Elapsed.TotalSeconds-$start
        $cpu=0.0
        foreach ($e in $ledger.Values) { $cpu += [Math]::Max(0.0,$e.last-$e.baseline) }
        @{startUtc=$startUtc.ToString('o');endUtc=[DateTime]::UtcNow.ToString('o');seconds=$elapsed;samples=$samples;
            cpuSeconds=$cpu;cpuOneCorePp=100*$cpu/$elapsed;cpuMachinePp=100*$cpu/$elapsed/$logicalProcessors;
            privateWorkingSetMiB=$endMemory.privateWorkingSetMiB;privateBytesMiB=$endMemory.privateBytesMiB;
            endProcessCount=$endMemory.liveProcesses;processes=@($ledger.Values | ForEach-Object {
                @{pid=$_.pid;createdUtc=$_.createdUtc;cpuSeconds=[Math]::Max(0.0,$_.last-$_.baseline);exited=$_.exited}})}
    } finally { foreach ($e in $ledger.Values) { $e.process.Dispose() } }
}
$report=[ordered]@{
    regenerateCommand="pwsh -NoProfile -File scripts/eq-bench.ps1 -Pairs $Pairs -OutputDirectory `"$OutputDirectory`"";
    startedUtc=[DateTime]::UtcNow.ToString('o');pairs=$Pairs;windowSeconds=$windowSeconds;sampleMilliseconds=$sampleMilliseconds;
    logicalProcessors=$logicalProcessors;cpuUnit='percentage points of total machine (one-core percentage / logical processor count)';
    memoryUnit='MiB';gates=@{cpuMachinePp=$gateCpuPp;privateWorkingSetMiB=$gateMemoryMiB;privateBytesMiB=$gateMemoryMiB;ownerAccepted=$true};
    protocol=@{arms=@('cold-off','attached-bypass','on');order='ABC, BCA, CAB repeating; fresh root/process per arm';
        conditions=@('playing','paused-minimized');conditionOrder='playing first on odd pairs, paused-minimized first on even pairs';
        fixture='synthetic Music, looping tones-48000';onGains=@(6,5,4,2,0,0,0,0,0,0);onPreampDb=-7;
        minimumBrowserAgeSeconds=150;settleSeconds=30;eagerGpuInfo=$true;trayEnabled=$false};
    limitations=@('Polling can miss children born and exited entirely between samples; exited observed children retain last readable CPU values.',
        'Synthetic fixture only; not live Music, hardware device switching, or owner listening evidence.',
        'Noise is repeated independent cold-off run spread, not a statistical confidence interval.');
    launches=$launches;runs=$runs;summary=@();pairedDeltas=@();noise=@();status='running'
}
try {
    if (-not (Test-Path -LiteralPath $exe)) { throw "Missing hook build: $exe (run eq-e2e first)." }
    $arms=@('cold-off','attached-bypass','on')
    for ($pair=1;$pair -le $Pairs;$pair++) {
        for ($position=0;$position -lt 3;$position++) {
            $arm=$arms[($pair-1+$position)%3]
            Start-Fixture "pair-$pair-$arm"
            try {
                if ($arm -ne 'cold-off') {
                    [void](Apply)
                    if (-not (Status-Is 'active' 2)) { Click-Page }
                    if (-not (Status-Is 'active')) { throw 'Flat did not attach.' }
                    if ($arm -eq 'attached-bypass') { [void](Apply @(0,0,0,0,0,0,0,0,0,0) 0 $false) }
                    else { [void](Apply @(6,5,4,2,0,0,0,0,0,0) -7) }
                }
                $browser=Browser
                if ($browser.CommandLine -notmatch '(?:^|\s)--no-delay-for-dx12-vulkan-info-collection(?:\s|$)') {
                    throw 'Eager DX12 browser switch was not delivered.'
                }
                $created=([DateTimeOffset]$browser.CreationDate).UtcDateTime
                $conditions=if($pair%2){@('playing','paused-minimized')}else{@('paused-minimized','playing')}
                foreach ($condition in $conditions) {
                    $script:process.Refresh(); $window=$script:process.MainWindowHandle
                    if ($window -eq [IntPtr]::Zero) { throw 'Fixture window not found.' }
                    [void][EqBenchInput]::ShowWindow($window,9)
                    if ($condition -eq 'playing') {
                        Click-Page
                        $media=Hook 'eq-playback' $true
                    } else {
                        $media=Hook 'eq-playback' $false
                        [void][EqBenchInput]::ShowWindow($window,6)
                    }
                    if (-not $media.fixture -or -not $media.loop -or $media.readyState -lt 2 -or
                        $media.paused -ne ($condition -eq 'paused-minimized')) { throw 'Fixture playback condition not established.' }
                    if ($condition -eq 'paused-minimized' -and -not [EqBenchInput]::IsIconic($window)) { throw 'Window did not minimize.' }
                    Start-Sleep -Seconds 30
                    while (([DateTime]::UtcNow-$created).TotalSeconds -lt 150) { Start-Sleep -Seconds 1 }
                    $currentBrowser=Browser
                    if ($currentBrowser.ProcessId -ne $browser.ProcessId -or
                        ([DateTimeOffset]$currentBrowser.CreationDate).UtcDateTime -ne $created) { throw 'Browser restarted before measurement.' }
                    $before=Assert-Arm $arm
                    $mediaBefore=Hook 'eq-media'
                    $age=([DateTime]::UtcNow-$created).TotalSeconds
                    $metrics=Measure-Tree
                    $after=Assert-Arm $arm
                    $mediaAfter=Hook 'eq-media'
                    $endBrowser=Browser
                    if ($endBrowser.ProcessId -ne $browser.ProcessId -or
                        ([DateTimeOffset]$endBrowser.CreationDate).UtcDateTime -ne $created) { throw 'Browser restarted during measurement.' }
                    if ($mediaBefore.paused -ne ($condition -eq 'paused-minimized') -or
                        $mediaAfter.paused -ne $mediaBefore.paused) { throw 'Playback condition changed during window.' }
                    if ($condition -eq 'paused-minimized' -and -not [EqBenchInput]::IsIconic($window)) { throw 'Minimized condition changed.' }
                    $runs.Add(@{pair=$pair;position=$position;arm=$arm;condition=$condition;browserAgeAtStartSeconds=$age;
                        browserCreationUtc=$created.ToString('o');before=$before;after=$after;metrics=$metrics})
                }
            } finally { Stop-Fixture }
        }
    }
    foreach ($condition in @('playing','paused-minimized')) {
        foreach ($arm in $arms) {
            $values=@($runs | Where-Object { $_.condition -eq $condition -and $_.arm -eq $arm })
            $report.summary+=@{condition=$condition;arm=$arm;cpuMachinePp=Median @($values.metrics.cpuMachinePp);
                privateWorkingSetMiB=Median @($values.metrics.privateWorkingSetMiB);privateBytesMiB=Median @($values.metrics.privateBytesMiB)}
        }
        $cold=@($runs | Where-Object { $_.condition -eq $condition -and $_.arm -eq 'cold-off' } | Sort-Object pair)
        $noise=@{condition=$condition;method='cold-off vs cold-off: adjacent paired differences and max-min spread';adjacent=@()}
        for ($i=1;$i -lt $cold.Count;$i++) {
            $noise.adjacent+=@{fromPair=$cold[$i-1].pair;toPair=$cold[$i].pair;
                cpuMachinePp=$cold[$i].metrics.cpuMachinePp-$cold[$i-1].metrics.cpuMachinePp;
                privateWorkingSetMiB=$cold[$i].metrics.privateWorkingSetMiB-$cold[$i-1].metrics.privateWorkingSetMiB;
                privateBytesMiB=$cold[$i].metrics.privateBytesMiB-$cold[$i-1].metrics.privateBytesMiB}
        }
        foreach ($metric in @('cpuMachinePp','privateWorkingSetMiB','privateBytesMiB')) {
            $range=$cold.metrics.$metric | Measure-Object -Minimum -Maximum
            $noise[$metric+'Spread']=$range.Maximum-$range.Minimum
            $noise[$metric+'MedianAbsoluteAdjacentDelta']=Median @($noise.adjacent | ForEach-Object {[Math]::Abs($_[$metric])})
        }
        $report.noise+=$noise
        foreach ($arm in @('attached-bypass','on')) {
            $deltas=@(for($pair=1;$pair -le $Pairs;$pair++) {
                $a=@($runs | Where-Object {$_.condition -eq $condition -and $_.arm -eq $arm -and $_.pair -eq $pair})[0]
                $b=$cold[$pair-1]
                @{pair=$pair;cpuMachinePp=$a.metrics.cpuMachinePp-$b.metrics.cpuMachinePp;
                    privateWorkingSetMiB=$a.metrics.privateWorkingSetMiB-$b.metrics.privateWorkingSetMiB;
                    privateBytesMiB=$a.metrics.privateBytesMiB-$b.metrics.privateBytesMiB}
            })
            $cpu=Median @($deltas.cpuMachinePp);$ws=Median @($deltas.privateWorkingSetMiB);$bytes=Median @($deltas.privateBytesMiB)
            $report.pairedDeltas+=@{condition=$condition;comparison="$arm - cold-off";pairs=$deltas;
                median=@{cpuMachinePp=$cpu;privateWorkingSetMiB=$ws;privateBytesMiB=$bytes};
                pass=($cpu -le $gateCpuPp -and $ws -le $gateMemoryMiB -and $bytes -le $gateMemoryMiB)}
        }
    }
    $report.status=if (@($report.pairedDeltas | Where-Object {-not $_.pass}).Count) {'fail'} else {'pass'}
} catch {
    $report.status='blocked';$report['error']=$_.Exception.Message
} finally {
    Stop-Fixture
    $report['endedUtc']=[DateTime]::UtcNow.ToString('o')
    [IO.File]::WriteAllText((Join-Path $run 'report.json'),($report | ConvertTo-Json -Depth 32))
    if (-not $KeepRoot -and (Test-Path -LiteralPath $rootBase)) { Remove-Item -LiteralPath $rootBase -Recurse -Force }
}
Write-Host "EQ benchmark $($report.status): $(Join-Path $run 'report.json')"
if ($report.status -ne 'pass') { exit 1 }
