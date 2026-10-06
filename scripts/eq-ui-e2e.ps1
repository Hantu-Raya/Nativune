<#
EQ Gates D/E/F(volume): actual hook app + UIA, synthetic Music audio, disposable settings.
Regenerate exactly:
  pwsh -NoProfile -File scripts/eq-ui-e2e.ps1 -OutputDirectory artifacts/eq-ui-e2e
No PCM, titles, URLs, device identities or clipboard text are retained. Narrator/high contrast remain operator-only.
Never ship artifacts/eq-e2e/app. -SkipPublish reuses the hook app built by eq-e2e.
#>
[CmdletBinding()]
param([string] $OutputDirectory = 'artifacts/eq-ui-e2e', [switch] $SkipPublish, [switch] $KeepRoot)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runId = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ') + '-' + [guid]::NewGuid().ToString('N')
$output = if ([IO.Path]::IsPathRooted($OutputDirectory)) { $OutputDirectory } else { Join-Path $repo $OutputDirectory }
$run = Join-Path $output $runId
$rootBase = Join-Path $repo ".cache/eq-ui-e2e/$runId"
$app = Join-Path $repo 'artifacts/eq-e2e/app'
$exe = Join-Path $app 'Nativune.exe'
[IO.Directory]::CreateDirectory($run) | Out-Null
[IO.Directory]::CreateDirectory($rootBase) | Out-Null
$rows = [Collections.Generic.List[object]]::new()
$launches = [Collections.Generic.List[object]]::new()
$script:sequence = 0
$script:process = $null
$script:root = $null
$ResponseToleranceDb = 0.5
$isElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
Add-Type @'
using System; using System.Runtime.InteropServices;
public static class EqUiE2EInput {
 [StructLayout(LayoutKind.Sequential)] struct Mouse { public int x,y;public uint data,flags,time;public UIntPtr extra; }
 [StructLayout(LayoutKind.Sequential)] struct Keyboard { public ushort vk,scan;public uint flags,time;public UIntPtr extra; }
 [StructLayout(LayoutKind.Explicit)] struct Union { [FieldOffset(0)] public Mouse mouse; [FieldOffset(0)] public Keyboard key; }
 [StructLayout(LayoutKind.Sequential)] struct Input { public uint type;public Union u; }
 [DllImport("user32.dll")] static extern uint SendInput(uint count,Input[] input,int size);
 [DllImport("user32.dll")] static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("kernel32.dll")] static extern IntPtr OpenProcess(uint access,bool inherit,int pid);
 [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
 [DllImport("advapi32.dll")] static extern bool OpenProcessToken(IntPtr p,uint access,out IntPtr t);
 public static IntPtr Token(int pid) { var p=OpenProcess(0x1000,false,pid);try {IntPtr t;return OpenProcessToken(p,0xA,out t)?t:IntPtr.Zero;}finally{CloseHandle(p);} }
 public static void CloseToken(IntPtr t){CloseHandle(t);}
 public static void Key(ushort vk,bool up=false){var a=new Input[1];a[0].type=1;a[0].u.key.vk=vk;a[0].u.key.flags=up?2u:0u;
   if(SendInput(1,a,Marshal.SizeOf(typeof(Input)))!=1)throw new Exception("SendInput keyboard failed");}
 public static void Text(string text){foreach(char c in text){var a=new Input[2];a[0].type=a[1].type=1;a[0].u.key.scan=a[1].u.key.scan=c;a[0].u.key.flags=4;a[1].u.key.flags=6;
   if(SendInput(2,a,Marshal.SizeOf(typeof(Input)))!=2)throw new Exception("SendInput text failed");}}
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
    [void][EqUiE2EInput]::SetForegroundWindow([IntPtr]$window.Current.NativeWindowHandle)
    $bounds = $button.Current.BoundingRectangle
    [EqUiE2EInput]::Click([int]($bounds.X+$bounds.Width/2),[int]($bounds.Y+$bounds.Height/2))
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
function Start-Fixture([string] $Name, [int] $Rate = 48000, $EqualizerSeed = $null, [bool] $DeferMedia = $false) {
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
    if ($EqualizerSeed) { $settings.Equalizer = $EqualizerSeed }
    [IO.File]::WriteAllText((Join-Path $script:root 'data/settings.json'),($settings|ConvertTo-Json -Depth 16))
    $environment = @{ NATIVUNE_TEST_DISCORD_FIXTURE_PAGE='1'; NATIVUNE_TEST_EQ_FIXTURE='1';
        NATIVUNE_TEST_EQ_SAMPLE_RATE="$Rate"; NATIVUNE_TEST_DISCORD_CLIENT_ID='100000000000000001';
        NATIVUNE_TEST_DISCORD_PIPE_PREFIX=('nativune-test-'+[guid]::NewGuid().ToString('N')+'-discord-ipc-') }
    $environment.NATIVUNE_TEST_EQ_DEFER_MEDIA = $(if ($DeferMedia) { '1' } else { '0' })
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
    $token = [EqUiE2EInput]::Token($script:process.Id); $admin = $null
    try {
        if ($token -ne [IntPtr]::Zero) {
            $identity = [Security.Principal.WindowsIdentity]::new($token)
            try { $admin = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
            finally { $identity.Dispose() }
        }
    } finally { if ($token -ne [IntPtr]::Zero) { [EqUiE2EInput]::CloseToken($token) } }
    $launches.Add(@{name=$Name;processId=$script:process.Id;viaRunas=$isElevated;adminEnabled=$admin;sampleRate=$Rate})
    Row "$Name.de-elevated" ($admin -eq $false) $launches[$launches.Count-1]
    if (-not (Wait-For { try { (Hook 'eq-media').fixture } catch { $false } } 60)) { throw 'Synthetic EQ page did not become ready.' }
    if (-not $DeferMedia) {
        [void](Hook 'eq-profile' "tones-$Rate")
        if (-not (Wait-For { (Hook 'eq-media').readyState -ge 2 } 15)) { throw 'EQ WAV did not load.' }
    }
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

# Native UIA resolves fresh elements; only the disposable fixture receives keyboard input.
function Windows {
    # UIA parents an owned WinUI window (Settings) under the main window, not the desktop root,
    # so return both the top-level windows of this process and their direct child windows.
    $condition=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ProcessIdProperty,$script:process.Id)
    $windowType=[Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Window)
    $result=[Collections.Generic.List[object]]::new()
    foreach ($top in [Windows.Automation.AutomationElement]::RootElement.FindAll([Windows.Automation.TreeScope]::Children,$condition)) {
        $result.Add($top)
        foreach ($child in $top.FindAll([Windows.Automation.TreeScope]::Children,$windowType)) { $result.Add($child) }
    }
    return $result
}
function Find-Control([string] $Id, [string] $Name = '', [bool] $Settings = $true) {
    foreach ($w in (Windows)) {
        if ($Settings -and $w.Current.Name -ne 'Settings') { continue }
        $property=if($Id){[Windows.Automation.AutomationElement]::AutomationIdProperty}else{[Windows.Automation.AutomationElement]::NameProperty}
        $value=if($Id){$Id}else{$Name}
        $e=$w.FindFirst([Windows.Automation.TreeScope]::Descendants,[Windows.Automation.PropertyCondition]::new($property,$value))
        if ($e) { return $e }
    }
    return $null
}
function Control([string] $Id) {
    $script:foundControl=$null
    if (-not (Wait-For { $script:foundControl=Find-Control $Id; $null -ne $script:foundControl } 10)) {
        $names=@(Windows | ForEach-Object { $_.Current.Name + '/' + $_.Current.ClassName }) -join ', '
        $settingsOpen=try { (Hook 'eq-settings-open').open } catch { 'unknown' }
        throw "UIA control missing: $Id (windows: $names; settings dialog open: $settingsOpen)"
    }
    return $script:foundControl
}
function Pattern($Element, $Type) { return $Element.GetCurrentPattern($Type::Pattern) }
function Invoke([string] $Id) {
    $e=Control $Id
    if (-not $e.Current.IsEnabled) { throw "UIA control disabled: $Id" }
    (Pattern $e ([Windows.Automation.InvokePattern])).Invoke()
    Start-Sleep -Milliseconds 200
}
function Focus($Element) {
    $walker=[Windows.Automation.TreeWalker]::ControlViewWalker
    $w=$Element
    while ($w -and -not $w.Current.NativeWindowHandle) { $w=$walker.GetParent($w) }
    if (-not $w) { throw 'No native window for input target.' }
    [void][EqUiE2EInput]::SetForegroundWindow([IntPtr]$w.Current.NativeWindowHandle)
    $Element.SetFocus()
    Start-Sleep -Milliseconds 100
    $focused=[Windows.Automation.AutomationElement]::FocusedElement
    $expectedId=($Element.GetRuntimeId() -join ',')
    $verified=$false
    while($focused){
        if(($focused.GetRuntimeId() -join ',') -ceq $expectedId){$verified=$true;break}
        $focused=$walker.GetParent($focused)
    }
    if(-not $verified){throw 'Native focus did not reach the intended input target.'}
}
function Key([int] $Code) {
    [EqUiE2EInput]::Key([ushort]$Code); [EqUiE2EInput]::Key([ushort]$Code,$true)
    Start-Sleep -Milliseconds 120
}
function Enter-Text([string] $Id, [string] $Text) {
    $e=Control $Id
    if ($Id -match '^Eq(BandBox\d+|PreampBox)$') {
        $edit=$e.FindFirst([Windows.Automation.TreeScope]::Descendants,
            [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::Edit))
        if ($edit) { $e=$edit }
    }
    Focus $e
    [EqUiE2EInput]::Key(0x11)
    try { Key 0x41 } finally { [EqUiE2EInput]::Key(0x11,$true) }
    [EqUiE2EInput]::Text($Text); Key 0x0D
    Start-Sleep -Milliseconds 250
}
function Toggle([string] $Id, [bool] $On) {
    $p=Pattern (Control $Id) ([Windows.Automation.TogglePattern])
    if (($p.Current.ToggleState -eq [Windows.Automation.ToggleState]::On) -ne $On) { $p.Toggle() }
    Start-Sleep -Milliseconds 300
}
function Range([string] $Id) { return (Pattern (Control $Id) ([Windows.Automation.RangeValuePattern])).Current.Value }
function Band-Gains { return @(0..9|ForEach-Object { Range "EqBand$_" }) }
function Selected-Preset {
    $selected=(Pattern (Control 'EqPreset') ([Windows.Automation.SelectionPattern])).Current.GetSelection()
    if ($selected.Count -ne 1) { throw 'Preset selection is not singular.' }
    return $selected[0].Current.Name
}
function Select-Preset([string] $Name) {
    (Pattern (Control 'EqPreset') ([Windows.Automation.ExpandCollapsePattern])).Expand()
    $script:presetItem=$null
    if (-not (Wait-For { $script:presetItem=Find-Control '' $Name; $null -ne $script:presetItem } 5)) { throw "Preset missing: $Name" }
    (Pattern $script:presetItem ([Windows.Automation.SelectionItemPattern])).Select()
    # Never send Escape here: if selecting already closed the drop-down, Escape reaches the Settings
    # window and cancels the whole dialog.
    $combo=Pattern (Control 'EqPreset') ([Windows.Automation.ExpandCollapsePattern])
    if ($combo.Current.ExpandCollapseState -ne [Windows.Automation.ExpandCollapseState]::Collapsed) { $combo.Collapse() }
    Start-Sleep -Milliseconds 250
}
function Open-Settings {
    [void](Hook 'eq-open-settings' 'Equalizer')
    [void](Control 'EqEnabled')
}
function Close-Settings([string] $Action = 'CancelButton') {
    Invoke $Action
    if (-not (Wait-For { $null -eq (Find-Control 'EqEnabled') } 10)) { throw 'Settings did not close.' }
    Start-Sleep -Milliseconds 400
}
function File-State { return Hook 'eq-settings-file' }
function Canonical($Value) { return $Value | ConvertTo-Json -Depth 24 -Compress }
function Error-Text {
    $e=Control 'EqError'
    return $e.Current.Name
}
function Keep-Preset([string] $Action,[string] $Name) {
    Invoke $Action; Enter-Text 'EqName' $Name; Invoke 'EqNameConfirm'
}
function Same-Gains($A,$B) {
    # Compare numerically: ConvertTo-Json prints a double 0 as 0.0 but a parsed integer 0 as 0.
    $a=@($A);$b=@($B)
    if ($a.Count -ne $b.Count) { return $false }
    for($i=0;$i -lt $a.Count;$i++){ if ([math]::Abs([double]$a[$i]-[double]$b[$i]) -gt 1e-9) { return $false } }
    return $true
}
function Check-TabOrder {
    # NumberBox template descendants count as one logical numeric entry.
    $expected=@('EqEnabled','EqPreset')
    foreach($i in 0..9){$expected+="EqBand$i";$expected+="EqBandBox$i"}
    $expected+=@('EqResetBands','EqAutoHeadroom','EqPreamp','EqPreampBox','EqResetPreamp',
        'EqSaveNew','EqRename','EqDuplicate','EqDelete','EqCopy','EqPaste','EqBypass')
    Focus (Control 'EqEnabled')
    $trace=[Collections.Generic.List[string]]::new()
    $walker=[Windows.Automation.TreeWalker]::ControlViewWalker
    for($i=0;$i -lt 100;$i++){
        $e=[Windows.Automation.AutomationElement]::FocusedElement
        $id=''
        while($e){
            if($e.Current.AutomationId -in $expected){$id=$e.Current.AutomationId;break}
            $e=$walker.GetParent($e)
        }
        if($id -and ($trace.Count -eq 0 -or $trace[$trace.Count-1] -ne $id)){$trace.Add($id)}
        if($id -eq 'EqBypass'){break}
        Key 0x09
    }
    Row 'tab-order' ((Canonical @($trace.ToArray())) -ceq (Canonical $expected)) @{expected=$expected;observed=@($trace.ToArray());input='SendInput Tab'}
}
function More-Toggle {
    $more=Find-Control '' 'More commands and settings' $false
    if(-not $more){throw 'More button missing.'}
    # The More flyout opens from a pointer click or its F10 / Alt+M accelerator; UIA Invoke on the button
    # does not open it, so use the documented keyboard accelerator with real input on the main window.
    $main=@(Windows | Where-Object { $_.Current.Name -eq 'Nativune' })[0]
    [void][EqUiE2EInput]::SetForegroundWindow([IntPtr]$main.Current.NativeWindowHandle)
    Start-Sleep -Milliseconds 300
    Key 0x79
    $script:moreEq=$null
    if(-not(Wait-For {
        foreach($w in (Windows)){
            $e=$w.FindFirst([Windows.Automation.TreeScope]::Descendants,
                [Windows.Automation.AndCondition]::new(
                    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::NameProperty,'Equalizer'),
                    [Windows.Automation.PropertyCondition]::new([Windows.Automation.AutomationElement]::ControlTypeProperty,[Windows.Automation.ControlType]::MenuItem)))
            if($e -and -not $e.Current.IsOffscreen){$script:moreEq=$e;return $true}
        };return $false
    } 5)){throw 'More Equalizer menu item missing.'}
    # A ToggleMenuFlyoutItem exposes TogglePattern (not Invoke); its automation peer raises the item's Click.
    $toggle=$null
    if ($script:moreEq.TryGetCurrentPattern([Windows.Automation.TogglePattern]::Pattern,[ref]$toggle)) { $toggle.Toggle() }
    else { (Pattern $script:moreEq ([Windows.Automation.InvokePattern])).Invoke() }
    Start-Sleep -Milliseconds 400
}
function Assert-File([scriptblock] $Predicate) {
    $script:lastFile=$null
    return Wait-For { $script:lastFile=File-State; & $Predicate $script:lastFile } 10
}
function Seed([bool] $Enabled = $false, [int] $CustomCount = 0) {
    $custom=@(for($i=0;$i -lt $CustomCount;$i++){
        @{id=('c-'+$i.ToString('x8'));name="Limit $i";gainsDb=@(0,0,0,0,0,0,0,0,0,0);preampDb=0;autoHeadroom=$true}
    })
    return @{enabled=$Enabled;selectedPresetId='flat';gainsDb=@(0,0,0,0,0,0,0,0,0,0);
        manualPreampDb=0;autoHeadroom=$true;customPresets=$custom}
}
function Run-Reload {
    # Codex review: when the disabled setting cannot be saved, Reload without EQ must not reload or show EQ off.
    Start-Fixture 'reload' 48000 (Seed $true)
    Click-Page
    if (-not (Status-Is 'active' 20)) { throw 'Reload fixture never attached.' }
    [void](Hook 'eq-profile' 'foreign-source')
    if (-not (Status-Is 'reloadNeeded' 10)) { throw 'Reload fixture never reached Reload needed.' }
    Open-Settings
    $settingsFile=Join-Path $script:root 'data/settings.json'
    (Get-Item -LiteralPath $settingsFile).IsReadOnly=$true
    try { Invoke 'EqReload'; Start-Sleep -Milliseconds 1500 }
    finally { (Get-Item -LiteralPath $settingsFile).IsReadOnly=$false }
    $errorText=(Control 'EqError').Current.Name
    $toggleOn=(Pattern (Control 'EqEnabled') ([Windows.Automation.TogglePattern])).Current.ToggleState -eq [Windows.Automation.ToggleState]::On
    $stillAttached=Hook 'eq-status'; $fileAfterFailure=File-State
    Row 'reload-save-failure-keeps-state' ($errorText -like '*could not be completed*' -and $toggleOn -and $stillAttached.attached -and
        $stillAttached.state -ceq 'reloadNeeded' -and $fileAfterFailure.equalizer.enabled) @{error=$errorText;toggleOn=$toggleOn;status=$stillAttached;fileEnabled=$fileAfterFailure.equalizer.enabled}
    Invoke 'EqReload'
    $reloadedOff=Wait-For { try { $script:afterReload=Hook 'eq-status'; $script:afterReload.state -ceq 'off' -and -not $script:afterReload.attached } catch { $false } } 30
    $fileAfterReload=File-State
    Row 'reload-success-disables' ($reloadedOff -and -not $fileAfterReload.equalizer.enabled) @{status=$script:afterReload;fileEnabled=$fileAfterReload.equalizer.enabled}
}
function Run-SavedRateWithSettingsOpen {
    $saved=Seed $true
    $saved.gainsDb=@(0,0,0,0,0,0,0,0,0,12)
    Start-Fixture 'saved-rate-settings-open' 16000 $saved $true
    $fallback=Hook 'eq-math' @{gains=$saved.gainsDb;sampleRate=48000}
    $real=Hook 'eq-math' @{gains=$saved.gainsDb;sampleRate=16000}
    $staged=Wait-For {
        $script:savedRateBefore=Hook 'eq-host-status'
        -not $script:savedRateBefore.attached -and $null -eq $script:savedRateBefore.sampleRate -and
        [math]::Abs($script:savedRateBefore.preampDb-$fallback.effectivePreampDb) -lt 0.001
    } 10
    # Settings disables its owner, so a page click cannot reach it while the dialog is open.
    # Give the empty page a trusted gesture first, then load media only after opening Settings.
    Click-Page
    $trusted=Wait-For { (Hook 'eq-media').trustedClicks -gt 0 } 5
    Open-Settings
    $beforeMedia=Hook 'eq-host-status'
    [void](Hook 'eq-profile' 'tones-16000')
    $script:savedRateApplied=$null
    $reapplied=Wait-For {
        $script:savedRateHost=Hook 'eq-host-status'
        if ($script:savedRateHost.state -cne 'active') { return $false }
        $script:savedRateApplied=Hook 'eq-applied-preamp'
        $script:savedRateHost.attached -and $script:savedRateHost.sampleRate -eq 16000 -and
        [math]::Abs($script:savedRateHost.preampDb-$real.effectivePreampDb) -lt 0.001 -and
        $script:savedRateApplied.sampleRate -eq 16000 -and
        [math]::Abs($script:savedRateApplied.preampDb-$real.effectivePreampDb) -lt 0.01
    } 20
    $dialogStillOpen=$null -ne (Find-Control 'EqEnabled')
    $persisted=File-State
    Row 'saved-eq-real-rate-with-settings-open' ($staged -and $trusted -and -not $beforeMedia.attached -and
        $reapplied -and $dialogStillOpen -and $persisted.equalizer.enabled -and
        (Same-Gains $persisted.equalizer.gainsDb $saved.gainsDb) -and
        [math]::Abs($fallback.effectivePreampDb-$real.effectivePreampDb) -gt 1) @{
            staged=$script:savedRateBefore;beforeMedia=$beforeMedia;host=$script:savedRateHost;
            applied=$script:savedRateApplied;dialogOpen=$dialogStillOpen;trustedClick=$trusted;
            fallbackDb=$fallback.effectivePreampDb;realDb=$real.effectivePreampDb;persisted=$persisted}
    Close-Settings
}
function Run-FirstPreviewRate {
    Start-Fixture 'first-preview-rate' 16000 (Seed)
    Click-Page
    Open-Settings
    # Stage a draft with a boosted band above the real Nyquist while EQ is still Off.
    Enter-Text 'EqBandBox9' '12'
    $draftGains=@(0,0,0,0,0,0,0,0,0,12)
    $fallback=Hook 'eq-math' @{gains=$draftGains;sampleRate=48000}
    $real=Hook 'eq-math' @{gains=$draftGains;sampleRate=16000}
    $staged=Wait-For { $script:stagedPreview=Hook 'eq-host-status'
        $null -eq $script:stagedPreview.sampleRate -and
        [math]::Abs($script:stagedPreview.preampDb-$fallback.effectivePreampDb) -lt 0.001 } 10
    Toggle 'EqEnabled' $true
    $script:appliedPreview=$null
    $reapplied=Wait-For {
        $script:ratePreview=Hook 'eq-host-status'
        if ($script:ratePreview.state -cne 'active') { return $false }
        $script:appliedPreview=Hook 'eq-applied-preamp'
        $script:ratePreview.state -ceq 'active' -and $script:ratePreview.sampleRate -eq 16000 -and
        [math]::Abs($script:ratePreview.preampDb-$real.effectivePreampDb) -lt 0.001 -and
        $script:appliedPreview.sampleRate -eq 16000 -and
        [math]::Abs($script:appliedPreview.preampDb-$real.effectivePreampDb) -lt 0.01
    } 20
    $persisted=File-State
    Row 'first-preview-real-rate-auto-headroom' ($staged -and $reapplied -and
        [math]::Abs($fallback.effectivePreampDb-$real.effectivePreampDb) -gt 1 -and
        -not $persisted.equalizer.enabled -and (Same-Gains $persisted.equalizer.gainsDb @(0,0,0,0,0,0,0,0,0,0))) @{
            staged=$script:stagedPreview;host=$script:ratePreview;applied=$script:appliedPreview;
            fallbackDb=$fallback.effectivePreampDb;realDb=$real.effectivePreampDb;persisted=$persisted}
    Close-Settings
}
function Run-LowRate {
    # Codex review: a 16 kHz output (e.g. Bluetooth hands-free) must not stop Settings or the curve.
    Start-Fixture 'low-rate' 16000 (Seed $true)
    Click-Page
    $active=Wait-For { $script:lowStatus=Hook 'eq-status'; $script:lowStatus.state -ceq 'active' -and $script:lowStatus.sampleRate -eq 16000 } 20
    Row 'low-rate-attached-16k' $active $script:lowStatus
    Open-Settings
    $curve=Hook 'eq-ui-curve'
    $x=@($curve.points|ForEach-Object{$_.x})
    $nyquistX=$curve.width*[Math]::Log(8000/20)/[Math]::Log(1000)
    $maxX=if($x.Count){($x|Measure-Object -Maximum).Maximum}else{-1}
    Row 'low-rate-settings-curve' ($x.Count -gt 50 -and $maxX -le $nyquistX + 0.5 -and $null -ne (Find-Control 'EqEnabled')) @{points=$x.Count;maxX=$maxX;nyquistX=$nyquistX;width=$curve.width}
    Close-Settings
}
function Run-Ui {
    Start-Fixture 'ui' 48000 (Seed)
    # Trusted fixture activation is performed before opening the native dialog.
    Click-Page
    Open-Settings
    $before=File-State
    Row 'equalizer-navigation' ($null -ne (Find-Control 'EqualizerNavItem')) @{present=($null -ne (Find-Control 'EqualizerNavItem'))}
    # Codex P2: at the dialog's 640-DIP minimum width every band and its numeric box must stay inside the window.
    $settingsWindow=@(Windows | Where-Object { $_.Current.Name -eq 'Settings' })[0]
    $transform=Pattern $settingsWindow ([Windows.Automation.TransformPattern])
    if (-not ('EqUiDpi' -as [type])) { Add-Type -Namespace '' -Name 'EqUiDpi' -MemberDefinition '[DllImport("user32.dll")] public static extern uint GetDpiForWindow(System.IntPtr hwnd);' }
    $scale=[EqUiDpi]::GetDpiForWindow([IntPtr]$settingsWindow.Current.NativeWindowHandle)/96.0
    # 640 DIPs of content (the dialog's declared minimum) plus the window frame.
    $transform.Resize([Math]::Ceiling(640*$scale)+16, [Math]::Ceiling(700*$scale)); Start-Sleep -Milliseconds 800
    $windowRect=$settingsWindow.Current.BoundingRectangle
    $bandRects=@(0..9 | ForEach-Object {
        $slider=(Control "EqBand$_").Current.BoundingRectangle; $box=(Control "EqBandBox$_").Current.BoundingRectangle
        [ordered]@{band=$_;sliderRight=$slider.Right;sliderWidth=$slider.Width;boxRight=$box.Right;boxWidth=$box.Width
            fits=($slider.Width -gt 0 -and $box.Width -ge 30 -and $box.Right -le $windowRect.Right -and $slider.Right -le $windowRect.Right)} })
    $fit=@($bandRects | ForEach-Object { $_.fits })
    Row 'bands-fit-min-width' (@($fit | Where-Object { -not $_ }).Count -eq 0) @{bands=$bandRects;dpiScale=$scale;windowWidth=$windowRect.Width;band9Right=(Control 'EqBandBox9').Current.BoundingRectangle.Right;windowRight=$windowRect.Right}
    $transform.Resize(900, 760); Start-Sleep -Milliseconds 500
    $curve=Hook 'eq-ui-curve'
    $x=@($curve.points|ForEach-Object{$_.x});$y=@($curve.points|ForEach-Object{$_.y})
    $span=($x|Measure-Object -Maximum).Maximum-($x|Measure-Object -Minimum).Minimum
    $maxCentreError=($y|ForEach-Object{[Math]::Abs($_-$curve.height/2)}|Measure-Object -Maximum).Maximum
    Row 'flat-curve-geometry' ($curve.width -gt 0 -and $curve.height -gt 0 -and $curve.points.Count -ge 2 -and
        $span -ge 0.95*$curve.width -and $maxCentreError -le 0.5) @{
            width=$curve.width;height=$curve.height;span=$span;maxCentreError=$maxCentreError;pointCount=$curve.points.Count}
    Toggle 'EqEnabled' $true
    if(-not(Status-Is 'active')){throw 'Enabled preview did not attach.'}
    $statusName=(Control 'EqStatus').Current.Name
    Row 'status-accessible-current-state' ($statusName -cmatch '\bActive\b' -and $statusName -cne 'Equalizer status') @{name=$statusName;expectedState='Active'}
    $freq=@('31.5','63','125','250','500','1000','2000','4000','8000','16000')
    foreach($i in 0..9){
        $old=Range "EqBand$i";$oldName=(Control "EqBand$i").Current.Name
        Focus (Control "EqBand$i"); Key 0x26
        $new=Range "EqBand$i";$newName=(Control "EqBand$i").Current.Name
        Row "slider-$i-name-step" ($old -eq 0 -and $oldName -ceq "$($freq[$i]) hertz, 0 decibels" -and
            $new -eq 0.5 -and $newName -ceq "$($freq[$i]) hertz, plus 0.5 decibels") @{
                before=$old;after=$new;beforeName=$oldName;afterName=$newName;input='SendInput Up'}
    }
    Row 'slider-unsaved' ((Selected-Preset) -ceq 'Unsaved custom') @{selected=Selected-Preset}
    Enter-Text 'EqBandBox1' '3.5'
    Row 'numberbox-sync' ((Range 'EqBand1') -eq 3.5 -and (Control 'EqBand1').Current.Name -ceq '63 hertz, plus 3.5 decibels') @{
        slider=Range 'EqBand1';name=(Control 'EqBand1').Current.Name;input='SendInput 3.5 Enter'}
    Enter-Text 'EqBandBox9' '-3.5'
    Row 'slider-minus-name' ((Range 'EqBand9') -eq -3.5 -and (Control 'EqBand9').Current.Name -ceq '16000 hertz, minus 3.5 decibels') @{
        slider=Range 'EqBand9';name=(Control 'EqBand9').Current.Name}
    $g=Band-Gains;$math=Hook 'eq-math' @{gains=$g}
    $effective=(Control 'EqEffectivePreamp').Current.Name
    $number=[double]$math.effectivePreampDb
    $formatted=$number.ToString('+0.#;-0.#;0',[Globalization.CultureInfo]::CurrentCulture)
    Row 'auto-headroom-math' ($effective -ceq "Effective preamp: $formatted dB") @{text=$effective;expectedDb=$number;mayClip=$math.mayClip}
    $absentWithAuto=-not (Wait-For { $null -ne (Find-Control 'EqMayClip') } 2)
    Row 'may-clip-absent-with-auto-headroom' $absentWithAuto @{absent=$absentWithAuto}
    Toggle 'EqAutoHeadroom' $false
    Enter-Text 'EqBandBox1' '6';Enter-Text 'EqPreampBox' '6'
    # A Collapsed TextBlock is absent from the UIA tree; a Visible one may still be scrolled below the
    # fold (IsOffscreen), so presence plus its text is the visibility oracle here.
    $script:mayClipElement=$null
    $mayClipPresent=Wait-For { $script:mayClipElement=Find-Control 'EqMayClip'; $null -ne $script:mayClipElement } 5
    Row 'may-clip' ($mayClipPresent -and $script:mayClipElement.Current.Name -ceq 'May clip') @{present=$mayClipPresent}
    # Commit a non-clipping manual preview to make the collector's transfer oracle unambiguous.
    Enter-Text 'EqPreampBox' '0'
    $revBefore=(Hook 'eq-status').rev
    Focus (Control 'EqBand0');Key 0x26
    $g=Band-Gains
    $revisionAdvanced=Wait-For { (Hook 'eq-status').rev -gt $revBefore } 10
    $preview=Response-Oracle (Collect) $g 0
    Row 'live-preview' ($revisionAdvanced -and $preview.pass) @{revisionBefore=$revBefore;revisionAfter=(Hook 'eq-status').rev;oracle=$preview}
    Toggle 'EqBypass' $true
    $bypass=Status-Is 'bypassed';$flat=Collect
    Row 'bypass-flat' ($bypass -and $flat.nullDb[0] -le -80 -and $flat.nullDb[1] -le -80 -and
        $flat.dryRms[0] -gt 0.001 -and $flat.dryRms[1] -gt 0.001) @{status=Hook 'eq-status';statistics=$flat}
    Close-Settings
    $cancelOff=Status-Is 'off';$restored=Collect
    $after=File-State
    Row 'cancel-restores' ($cancelOff -and (Canonical $before) -ceq (Canonical $after) -and
        $restored.nullDb[0] -le -80 -and $restored.nullDb[1] -le -80) @{before=$before;after=$after;status=Hook 'eq-status';statistics=$restored}
    Open-Settings
    $bypassCleared=(Pattern (Control 'EqBypass') ([Windows.Automation.TogglePattern])).Current.ToggleState -eq [Windows.Automation.ToggleState]::Off
    Row 'bypass-cleared-close' $bypassCleared @{toggleOff=$bypassCleared}
    Toggle 'EqEnabled' $true;Toggle 'EqAutoHeadroom' $false
    Enter-Text 'EqBandBox1' '3.5'
    $savedGains=Band-Gains
    Close-Settings 'SaveButton'
    $persisted=Assert-File {param($s) $s.version -eq 7 -and $s.equalizer.enabled -and (Same-Gains $s.equalizer.gainsDb $savedGains)}
    Row 'save-persists-v8' $persisted $script:lastFile
    Open-Settings
    Keep-Preset 'EqSaveNew' 'My EQ'
    Row 'save-new-preset' ((Selected-Preset) -ceq 'My EQ') @{selected=Selected-Preset}
    Check-TabOrder
    Keep-Preset 'EqSaveNew' 'My EQ'
    $duplicateError=Error-Text
    Row 'duplicate-name-rejected' ($duplicateError -like '*already exists*' -and (Selected-Preset) -ceq 'My EQ') @{error=$duplicateError;selected=Selected-Preset}
    Invoke 'EqNameCancel'
    Keep-Preset 'EqRename' 'My EQ renamed'
    Row 'rename-preset' ((Selected-Preset) -ceq 'My EQ renamed') @{selected=Selected-Preset}
    Select-Preset 'Bass boost'
    $builtInGains=Band-Gains
    $immutable= -not (Control 'EqRename').Current.IsEnabled -and -not (Control 'EqDelete').Current.IsEnabled
    Keep-Preset 'EqDuplicate' 'Bass copy'
    $copyOkay=(Selected-Preset) -ceq 'Bass copy' -and (Same-Gains (Band-Gains) $builtInGains)
    Select-Preset 'Bass boost'
    Row 'duplicate-builtin-immutable' ($immutable -and $copyOkay -and (Same-Gains (Band-Gains) $builtInGains) -and
        -not (Control 'EqRename').Current.IsEnabled -and -not (Control 'EqDelete').Current.IsEnabled) @{
            copied=$copyOkay;builtinGains=$builtInGains;builtInStillSelected=Selected-Preset;immutable=$immutable}
    Select-Preset 'Bass copy';Invoke 'EqDelete'
    Row 'delete-active-retains-curve' ((Selected-Preset) -ceq 'Unsaved custom' -and (Same-Gains (Band-Gains) $builtInGains)) @{
        selected=Selected-Preset;gains=Band-Gains}
    Invoke 'EqCopy'
    $copyText=Get-Clipboard -Raw
    $copyJson=$copyText|ConvertFrom-Json
    Row 'copy-preset-schema' ($copyJson.format -ceq 'nativune-eq' -and $copyJson.version -eq 1 -and $copyJson.gainsDb.Count -eq 10) @{
        format=$copyJson.format;version=$copyJson.version;gainCount=$copyJson.gainsDb.Count}
    Toggle 'EqEnabled' $false
    $fileBeforePaste=File-State
    $valid=@{format='nativune-eq';version=1;name='Imported';gainsDb=@(0,4,0,0,0,0,0,0,0,0);preampDb=0;autoHeadroom=$false}|ConvertTo-Json -Compress
    Set-Clipboard -Value $valid;Invoke 'EqPaste'
    $pasteOff=(Pattern (Control 'EqEnabled') ([Windows.Automation.TogglePattern])).Current.ToggleState -eq [Windows.Automation.ToggleState]::Off
    Row 'paste-valid-staged-only' ($pasteOff -and (Selected-Preset) -ceq 'Unsaved custom' -and (Range 'EqBand1') -eq 4 -and
        (Canonical (File-State)) -ceq (Canonical $fileBeforePaste)) @{
            enabled=$false;selected=Selected-Preset;gains=Band-Gains;fileUnchanged=((Canonical (File-State)) -ceq (Canonical $fileBeforePaste))}
    $invalid=@{
        version=$valid.Replace('"version":1','"version":2')
        nine=(@{format='nativune-eq';version=1;name='Imported';gainsDb=@(0,0,0,0,0,0,0,0,0);preampDb=0;autoHeadroom=$false}|ConvertTo-Json -Compress)
        nan=$valid.Replace('"preampDb":0','"preampDb":NaN')
        oversize=($valid + (' ' * 2049))
    }
    foreach($kind in @('version','nine','nan','oversize')){
        $gainsBefore=Band-Gains;$preBefore=Range 'EqPreamp';$selectedBefore=Selected-Preset
        $autoBefore=(Pattern (Control 'EqAutoHeadroom') ([Windows.Automation.TogglePattern])).Current.ToggleState
        Set-Clipboard -Value $invalid[$kind];Invoke 'EqPaste'
        $errorText=Error-Text
        $stillOff=(Pattern (Control 'EqEnabled') ([Windows.Automation.TogglePattern])).Current.ToggleState -eq [Windows.Automation.ToggleState]::Off
        Row "paste-invalid-$kind" ($errorText.Length -gt 0 -and (Same-Gains (Band-Gains) $gainsBefore) -and
            (Range 'EqPreamp') -eq $preBefore -and (Selected-Preset) -ceq $selectedBefore -and $stillOff -and
            (Pattern (Control 'EqAutoHeadroom') ([Windows.Automation.TogglePattern])).Current.ToggleState -eq $autoBefore -and
            (Canonical (File-State)) -ceq (Canonical $fileBeforePaste)) @{error=$errorText;unchangedGains=Band-Gains;stillDisabled=$stillOff;bytes=[Text.Encoding]::UTF8.GetByteCount($invalid[$kind])}
    }
    Close-Settings
    # Menu toggles production settings, not the hook apply surface.
    More-Toggle
    $menuOff=Status-Is 'off'
    $fileOff=Assert-File {param($s) -not $s.equalizer.enabled}
    More-Toggle
    $menuActive=Status-Is 'active'
    $fileOn=Assert-File {param($s) $s.equalizer.enabled}
    Row 'more-toggle-persists-status' ($menuOff -and $fileOff -and $menuActive -and $fileOn) @{off=$menuOff;active=$menuActive;file=$script:lastFile}
    $script:sessions=$null
    $owned=Wait-For {try{$script:sessions=Hook 'eq-session';$script:sessions.count -ge 1}catch{$false}} 15
    Row 'volume-owned-session' $owned $script:sessions
    [void](Hook 'eq-set-volume' 0.25)
    $volume=Wait-For {$script:sessions=Hook 'eq-session';$script:sessions.count -ge 1 -and
        @($script:sessions.sessions|Where-Object{[Math]::Abs($_.volume-0.25) -gt 0.0001}).Count -eq 0} 10
    Row 'volume-quarter-eq-active' ($volume -and (Status-Is 'active')) @{inventory=$script:sessions;status=Hook 'eq-status'}
    [void](Hook 'eq-set-mute' $true)
    $mute=Wait-For {$script:sessions=Hook 'eq-session';$script:sessions.count -ge 1 -and
        @($script:sessions.sessions|Where-Object{-not $_.muted}).Count -eq 0} 10
    Row 'mute-eq-active' ($mute -and (Status-Is 'active')) @{inventory=$script:sessions;status=Hook 'eq-status'}
    [void](Hook 'eq-set-mute' $false);[void](Hook 'eq-set-volume' 1)
}
function Run-Limit {
    Start-Fixture 'preset-limit' 48000 (Seed $false 20)
    Open-Settings
    Enter-Text 'EqBandBox1' '1'
    $saveNew=Control 'EqSaveNew';$duplicate=Control 'EqDuplicate'
    $saveDisabled= -not $saveNew.Current.IsEnabled;$duplicateDisabled= -not $duplicate.Current.IsEnabled
    $refused=$saveDisabled -and $duplicateDisabled
    # A disabled native action is the UI refusal; ensure no hidden twenty-first preset is persisted.
    Close-Settings 'SaveButton'
    $countCorrect=Assert-File {param($s) $s.equalizer.customPresets.Count -eq 20}
    Row 'twenty-first-preset-refused' ($refused -and $countCorrect) @{
        saveNewDisabled=$saveDisabled;duplicateDisabled=$duplicateDisabled;file=$script:lastFile}
}
$requiredRows=@('bands-fit-min-width','flat-curve-geometry','status-accessible-current-state','slider-minus-name','equalizer-navigation','slider-unsaved','numberbox-sync','auto-headroom-math','may-clip-absent-with-auto-headroom','may-clip',
    'live-preview','bypass-flat','cancel-restores','bypass-cleared-close','save-persists-v8','save-new-preset',
    'tab-order','duplicate-name-rejected','rename-preset','duplicate-builtin-immutable','delete-active-retains-curve',
    'copy-preset-schema','paste-valid-staged-only','paste-invalid-version','paste-invalid-nine','paste-invalid-nan',
    'paste-invalid-oversize','more-toggle-persists-status','volume-owned-session','volume-quarter-eq-active',
    'mute-eq-active','twenty-first-preset-refused','ui.de-elevated','preset-limit.de-elevated','low-rate.de-elevated','low-rate-attached-16k','low-rate-settings-curve','reload.de-elevated','reload-save-failure-keeps-state','reload-success-disables')
foreach($i in 0..9){$requiredRows+="slider-$i-name-step"}
$requiredRows+=@('first-preview-rate.de-elevated','first-preview-real-rate-auto-headroom')
$requiredRows+=@('saved-rate-settings-open.de-elevated','saved-eq-real-rate-with-settings-open')
$clipboardSaved=Get-Clipboard -Raw
$failure=$null
try {
    if(-not $SkipPublish){
        & pwsh -NoProfile -File (Join-Path $repo 'scripts/dotnet.ps1') publish (Join-Path $repo 'src/Nativune/Nativune.csproj') `
            --runtime win-x64 --self-contained false -p:DiscordPresenceTestHooks=true -o $app
        if($LASTEXITCODE -ne 0){throw "Hook publish failed ($LASTEXITCODE)."}
    }
    if(-not(Test-Path -LiteralPath $exe)){throw "Hook app missing: $exe"}
    try { Run-Ui } catch { Row 'ui-completion' $false @{error=$_.Exception.Message} } finally { Stop-Fixture }
    try { Run-Limit } catch { Row 'limit-completion' $false @{error=$_.Exception.Message} } finally { Stop-Fixture }
    try { Run-LowRate } catch { Row 'low-rate-completion' $false @{error=$_.Exception.Message} } finally { Stop-Fixture }
    try { Run-FirstPreviewRate } catch { Row 'first-preview-rate-completion' $false @{error=$_.Exception.Message} } finally { Stop-Fixture }
    try { Run-SavedRateWithSettingsOpen } catch { Row 'saved-rate-settings-open-completion' $false @{error=$_.Exception.Message} } finally { Stop-Fixture }
    try { Run-Reload } catch { Row 'reload-completion' $false @{error=$_.Exception.Message} } finally { Stop-Fixture }
} catch { $failure=$_.Exception.Message;Row 'harness-completion' $false @{error=$failure} }
finally {
    Stop-Fixture
    # Preserve text even on a failed row; clipboard payloads never enter evidence.
    try {
        if($null -eq $clipboardSaved){Set-Clipboard -Value ''}else{Set-Clipboard -Value $clipboardSaved}
    } catch { Row 'clipboard-restore' $false @{error='Could not restore original clipboard text.'} }
    foreach($key in @('NATIVUNE_TEST_EQ_FIXTURE','NATIVUNE_TEST_EQ_SAMPLE_RATE','NATIVUNE_TEST_EQ_DEFER_MEDIA','NATIVUNE_TEST_DISCORD_FIXTURE_PAGE',
        'NATIVUNE_TEST_DISCORD_PIPE_PREFIX','NATIVUNE_TEST_DISCORD_CLIENT_ID')){[Environment]::SetEnvironmentVariable($key,[NullString]::Value,'Process')}
    foreach($name in $requiredRows){
        if(-not @($rows|Where-Object{$_.name -ceq $name}).Count){
            $rows.Add([ordered]@{name=$name;status='blocked';evidence=@{reason='Prerequisite failed; row was not executed.'}})
        }
    }
    foreach($name in @('Narrator','high-contrast')){
        $rows.Add([ordered]@{name=$name;status='operator-only';evidence=@{reason='Requires operator evaluation; not claimed as passing.'}})
    }
    $failed=@($rows|Where-Object{$_.status -in @('fail','blocked')})
    $report=@{schema=1;utc=[DateTime]::UtcNow.ToString('o');
        regenerate='pwsh -NoProfile -File scripts/eq-ui-e2e.ps1 -OutputDirectory artifacts/eq-ui-e2e';
        rows=@($rows.ToArray());launches=@($launches.ToArray());automatedPassed=($failed.Count -eq 0);
        operatorReviewRequired=$true;failure=$failure}
    [IO.File]::WriteAllText((Join-Path $run 'report.json'),($report|ConvertTo-Json -Depth 48))
    Write-Host "EQ UI E2E: $($rows.Count) rows, $($failed.Count) failed/blocked. Report: $run/report.json"
    if(-not $KeepRoot -and $failed.Count -eq 0){Remove-Item -LiteralPath $rootBase -Recurse -Force}
}
if(@($rows|Where-Object{$_.status -in @('fail','blocked')}).Count -gt 0){exit 1}
