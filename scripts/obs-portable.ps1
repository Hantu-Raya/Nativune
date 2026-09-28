<#
Disposable portable OBS Studio for the OBS overlay E2E-B and G3 bench (notes/research/obs-overlay-2026-09-28/plan.md
§6.2 "Sandbox", "Seeds", "Owned-instance check", "Secret handling", "Cleanup"; §6.3 G3). Dot-source it:

  . (Join-Path $PSScriptRoot 'obs-portable.ps1')
  $obs = New-ObsPortable -RunDir (Join-Path $repo ".cache/obs-portable/$runId")
  # start the Nativune hook build and confirm a 200 on http://localhost:47813/ FIRST (plan D13), then:
  $proc = Start-ObsPortable $obs
  $ws = Connect-ObsWebSocket $obs
  Invoke-ObsRequest $ws 'GetVersion' @{}
  ...
  finally { Stop-ObsPortable $obs }

Running any of this needs the owner's explicit approval (plan §6.2 heading: no answer is not approval).
Disclosure: while OBS runs, obs-websocket listens on all interfaces on a random port 49152-65535 with a random
32-byte password (pinned WebSocketServer.cpp).

Secret handling: the password is generated here, written only into <RunDir>/pw.txt and
<RunDir>/config/obs-studio/plugin_config/obs-websocket/config.json after the run folder's ACL is current-user-only
(inheritance off), read back only inside Connect-ObsWebSocket, and never placed in argv, logs, returned objects or
artifacts. The returned object carries the password file path, not the password.

Callers may edit the seeded scene collection between New-ObsPortable and Start-ObsPortable
($obs.SceneCollectionFile, e.g. item visible=false or shutdown=false for one arm).
#>
Set-StrictMode -Version Latest

$script:ObsPortableSource = 'C:\Program Files\obs-studio'
$script:ObsPortableVersion = '32.1.2'
$script:ObsPortableName = 'nativune-e2e'
$script:ObsPortableSourceName = 'Nativune Overlay'
$script:ObsPortableSceneName = 'Overlay'

function Write-ObsPortableText([string] $Path, [string] $Text) {
    [IO.Directory]::CreateDirectory((Split-Path -Parent $Path)) | Out-Null
    [IO.File]::WriteAllText($Path, $Text, [Text.UTF8Encoding]::new($false))
}

function Get-ObsPortableFreePort {
    $used = [Collections.Generic.HashSet[int]]::new()
    foreach ($e in [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()) { [void] $used.Add($e.Port) }
    for ($i = 0; $i -lt 200; $i++) {
        $candidate = [Security.Cryptography.RandomNumberGenerator]::GetInt32(49152, 65536)
        if (-not $used.Contains($candidate)) { return $candidate }
    }
    throw 'No free TCP port in 49152-65535 after 200 tries.'
}

# Current-user-only ACL, inheritance off (applied before any secret exists in the folder).
function Set-ObsPortableAcl([string] $Path) {
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetAccessRuleProtection($true, $false)
    $acl.SetOwner($sid)
    $inherit = [Security.AccessControl.InheritanceFlags] 'ContainerInherit, ObjectInherit'
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new($sid, 'FullControl', $inherit, 'None', 'Allow'))
    [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($Path), $acl)
    # Verify: exactly one explicit rule, for the current user, and no inherited rules.
    $check = [IO.FileSystemAclExtensions]::GetAccessControl([IO.DirectoryInfo]::new($Path))
    $rules = @($check.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
    if (-not $check.AreAccessRulesProtected -or $rules.Count -ne 1 -or $rules[0].IdentityReference.Value -ne $sid.Value -or $rules[0].IsInherited) {
        throw "Run folder ACL is not current-user-only: $Path"
    }
}

function New-ObsSceneCollectionJson([string] $SourceName, [string] $SceneName, [string] $Collection) {
    $sceneUuid = [guid]::NewGuid().ToString(); $sourceUuid = [guid]::NewGuid().ToString()
    $collection = [ordered]@{
        name = $Collection
        current_scene = $SceneName; current_program_scene = $SceneName
        scene_order = @([ordered]@{ name = $SceneName })
        current_transition = 'Fade'; transition_duration = 300; transitions = @(); groups = @(); quick_transitions = @()
        sources = @(
            [ordered]@{
                id = 'scene'; versioned_id = 'scene'; name = $SceneName; uuid = $sceneUuid; enabled = $true; flags = 0; mixers = 0
                settings = [ordered]@{
                    id_counter = 1; custom_size = $false
                    items = @([ordered]@{
                        name = $SourceName; source_uuid = $sourceUuid; visible = $true; locked = $false
                        rot = 0.0; pos = [ordered]@{ x = 0.0; y = 0.0 }; scale = [ordered]@{ x = 1.0; y = 1.0 }; align = 5
                        bounds_type = 0; bounds_align = 0; bounds_crop = $false; bounds = [ordered]@{ x = 0.0; y = 0.0 }
                        crop_left = 0; crop_top = 0; crop_right = 0; crop_bottom = 0; id = 1; group_item_backup = $false
                        scale_filter = 'disable'; blend_method = 'default'; blend_type = 'normal'
                    })
                }
            },
            [ordered]@{
                id = 'browser_source'; versioned_id = 'browser_source'; name = $SourceName; uuid = $sourceUuid; enabled = $true
                flags = 0; mixers = 255; muted = $false; volume = 1.0; monitoring_type = 0
                settings = [ordered]@{
                    url = 'http://localhost:47813/'; is_local_file = $false; width = 440; height = 96
                    fps_custom = $true; fps = 30; shutdown = $true; restart_when_active = $false
                    webpage_control_level = 0; reroute_audio = $false; css = ''
                }
            })
    }
    $collection | ConvertTo-Json -Depth 12
}

function New-ObsPortable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RunDir)
    $RunDir = [IO.Path]::GetFullPath($RunDir)
    if (Test-Path -LiteralPath $RunDir) { throw "Run folder already exists: $RunDir" }
    $ownerBefore = Get-OwnerObsProfileSnapshot
    [IO.Directory]::CreateDirectory($RunDir) | Out-Null
    Set-ObsPortableAcl $RunDir

    $exeSource = Join-Path $script:ObsPortableSource 'bin\64bit\obs64.exe'
    if (-not (Test-Path -LiteralPath $exeSource -PathType Leaf)) { throw "OBS Studio not installed at $script:ObsPortableSource." }
    foreach ($item in Get-ChildItem -LiteralPath $script:ObsPortableSource -Force) {
        if ($item.Name -ieq 'uninstall.exe') { continue }
        Copy-Item -LiteralPath $item.FullName -Destination $RunDir -Recurse -Force
    }
    $exe = Join-Path $RunDir 'bin\64bit\obs64.exe'
    $version = (Get-Item -LiteralPath $exe).VersionInfo
    $productVersion = "$($version.ProductMajorPart).$($version.ProductMinorPart).$($version.ProductBuildPart)"
    if ($productVersion -ne $script:ObsPortableVersion) { throw "OBS version $productVersion, expected $script:ObsPortableVersion." }
    Write-ObsPortableText (Join-Path $RunDir 'portable_mode.txt') ''

    $config = Join-Path $RunDir 'config\obs-studio'
    Write-ObsPortableText (Join-Path $config 'user.ini') "[General]`r`nFirstRun=true`r`n"
    Write-ObsPortableText (Join-Path $config "basic\profiles\$script:ObsPortableName\basic.ini") (@(
            '[General]', "Name=$script:ObsPortableName", '',
            '[Video]', 'BaseCX=1920', 'BaseCY=1080', 'OutputCX=1920', 'OutputCY=1080', 'FPSType=1', 'FPSInt=60', 'FPSCommon=60', '',
            '[Output]', 'Mode=Simple', '',
            '[SimpleOutput]', 'RecRB=false', '') -join "`r`n")
    $sceneFile = Join-Path $config "basic\scenes\$script:ObsPortableName.json"
    Write-ObsPortableText $sceneFile (New-ObsSceneCollectionJson $script:ObsPortableSourceName $script:ObsPortableSceneName $script:ObsPortableName)

    $port = Get-ObsPortableFreePort
    $bytes = [byte[]]::new(32); [Security.Cryptography.RandomNumberGenerator]::Fill($bytes)
    $passwordFile = Join-Path $RunDir 'pw.txt'
    Write-ObsPortableText $passwordFile ([Convert]::ToBase64String($bytes))
    [Array]::Clear($bytes, 0, $bytes.Length)
    $wsConfig = [ordered]@{ first_load = $false; server_enabled = $true; server_port = $port; auth_required = $true
        server_password = [IO.File]::ReadAllText($passwordFile); alerts_enabled = $false }
    Write-ObsPortableText (Join-Path $config 'plugin_config\obs-websocket\config.json') ($wsConfig | ConvertTo-Json)
    $wsConfig = $null

    [pscustomobject]@{
        RunDir = $RunDir; Exe = $exe; Cwd = (Split-Path -Parent $exe); Port = $port; PasswordFile = $passwordFile
        ConfigDir = $config; SceneCollectionFile = $sceneFile; Version = $productVersion
        Process = $null; ProcessId = $null; StartTime = $null; OwnedCheck = $null; Paths = $null
        OwnerBefore = $ownerBefore; OwnerChanged = $null; Stopped = $false; SeededUtc = [DateTime]::UtcNow
    }
}

# Expected vs observed paths (plan §6.2, review W6). Safe to call again after the page has loaded.
function Update-ObsPortablePaths($Obs) {
    $root = $Obs.RunDir.TrimEnd('\') + '\'
    $config = $Obs.ConfigDir
    $fresh = { param($dir) if (Test-Path -LiteralPath $dir) { @(Get-ChildItem -LiteralPath $dir -Recurse -File -Force | Where-Object { $_.LastWriteTimeUtc -ge $Obs.SeededUtc }).Count } else { 0 } }
    $browserDir = Join-Path $config 'plugin_config\obs-browser'
    $pages = @()
    if ($Obs.ProcessId) {
        $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine)
        $tree = [Collections.Generic.HashSet[int]]::new(); [void] $tree.Add([int] $Obs.ProcessId)
        do { $added = $false; foreach ($p in $all) { if ($tree.Contains([int] $p.ParentProcessId) -and $tree.Add([int] $p.ProcessId)) { $added = $true } } } while ($added)
        foreach ($p in $all) {
            if ($p.Name -ne 'obs-browser-page.exe' -or -not $tree.Contains([int] $p.ProcessId)) { continue }
            $named = @([regex]::Matches([string] $p.CommandLine, '--([a-z-]*(?:cache|user-data|log)[a-z-]*)=(?:"([^"]+)"|(\S+))') | ForEach-Object {
                    $value = if ($_.Groups[2].Success) { $_.Groups[2].Value } else { $_.Groups[3].Value }
                    $full = try { [IO.Path]::GetFullPath($value) } catch { $value }
                    [ordered]@{ switch = $_.Groups[1].Value; underRun = $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase) -or ($full.TrimEnd('\') + '\') -ieq $root
                        path = if ($full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { '<run>\' + $full.Substring($root.Length) } else { $full } } })
            $pages += [ordered]@{ processId = $p.ProcessId; pathSwitches = $named }
        }
    }
    $Obs.Paths = [ordered]@{
        expected = [ordered]@{ config = '<run>\config\obs-studio'; cefCache = '<run>\config\obs-studio\plugin_config\obs-browser' }
        observed = [ordered]@{
            logsFresh = & $fresh (Join-Path $config 'logs')
            profileFresh = & $fresh (Join-Path $config "basic\profiles\$script:ObsPortableName")
            obsBrowserFiles = if (Test-Path -LiteralPath $browserDir) { @(Get-ChildItem -LiteralPath $browserDir -Recurse -File -Force).Count } else { 0 }
            browserPages = $pages
            allPagePathsUnderRun = -not ($pages | ForEach-Object { $_.pathSwitches } | Where-Object { -not $_.underRun })
        }
    }
    $Obs.Paths
}

function Start-ObsPortable {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Obs)
    if ($Obs.Process) { throw 'This portable OBS was already started.' }
    $arguments = @('--portable', '--multi', '--only-bundled-plugins', '--disable-updater', '--disable-missing-files-check',
        '--collection', $script:ObsPortableName, '--profile', $script:ObsPortableName)
    $process = Start-Process -FilePath $Obs.Exe -ArgumentList $arguments -WorkingDirectory $Obs.Cwd -PassThru
    $Obs.Process = $process; $Obs.ProcessId = $process.Id; $Obs.StartTime = $process.StartTime

    # Owned-instance check before any request: the listening PID on the seeded port is the launched PID.
    $deadline = [DateTime]::UtcNow.AddSeconds(60); $listenPid = $null
    while ([DateTime]::UtcNow -lt $deadline -and -not $process.HasExited) {
        $listenPid = @(Get-NetTCPConnection -LocalPort $Obs.Port -State Listen -ErrorAction SilentlyContinue | ForEach-Object { [int] $_.OwningProcess } | Select-Object -Unique)
        if ($listenPid.Count -gt 0) { break }
        Start-Sleep -Milliseconds 250
    }
    $samePid = $listenPid -and @($listenPid | Where-Object { $_ -ne $process.Id }).Count -eq 0
    $live = Get-Process -Id $process.Id -ErrorAction SilentlyContinue
    $sameStart = $live -and $live.StartTime -eq $Obs.StartTime
    $version = $null
    if ($samePid -and $sameStart) {
        $ws = Connect-ObsWebSocket $Obs
        try { $version = Invoke-ObsRequest $ws 'GetVersion' @{} } finally { Close-ObsWebSocket $ws }
    }
    $Obs.OwnedCheck = [ordered]@{
        processId = $process.Id; startTime = $Obs.StartTime.ToUniversalTime().ToString('o'); exited = $process.HasExited
        listeningPids = @($listenPid); listenerIsObs = [bool] $samePid; startTimeMatches = [bool] $sameStart
        obsVersion = if ($version) { $version.obsVersion } else { $null }; wsVersion = if ($version) { $version.obsWebSocketVersion } else { $null }
        passed = [bool] ($samePid -and $sameStart -and $version -and $version.obsVersion -like "$script:ObsPortableVersion*")
    }
    [void] (Update-ObsPortablePaths $Obs)
    if (-not $Obs.OwnedCheck.passed) { throw "Owned-instance check failed: $($Obs.OwnedCheck | ConvertTo-Json -Compress)" }
    $process
}

function Receive-ObsMessage($Session, [int] $TimeoutMs = 20000) {
    $buffer = [byte[]]::new(65536); $ms = [IO.MemoryStream]::new()
    $cts = [Threading.CancellationTokenSource]::new($TimeoutMs)
    try {
        do {
            $segment = [ArraySegment[byte]]::new($buffer)
            $result = $Session.Socket.ReceiveAsync($segment, $cts.Token).GetAwaiter().GetResult()
            if ($result.MessageType -eq [Net.WebSockets.WebSocketMessageType]::Close) { throw "obs-websocket closed: $($result.CloseStatus) $($result.CloseStatusDescription)" }
            $ms.Write($buffer, 0, $result.Count)
        } while (-not $result.EndOfMessage)
        [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json -Depth 32
    } finally { $cts.Dispose(); $ms.Dispose() }
}
function Send-ObsMessage($Session, $Message) {
    $bytes = [Text.Encoding]::UTF8.GetBytes(($Message | ConvertTo-Json -Depth 32 -Compress))
    $Session.Socket.SendAsync([ArraySegment[byte]]::new($bytes), [Net.WebSockets.WebSocketMessageType]::Text, $true,
        [Threading.CancellationToken]::None).GetAwaiter().GetResult()
}

function Connect-ObsWebSocket {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Obs)
    $socket = [Net.WebSockets.ClientWebSocket]::new()
    $socket.Options.AddSubProtocol('obswebsocket.json')
    $socket.ConnectAsync([Uri] "ws://127.0.0.1:$($Obs.Port)", [Threading.CancellationToken]::None).GetAwaiter().GetResult()
    $session = [pscustomobject]@{ Socket = $socket; Port = $Obs.Port; NextId = 0 }
    $hello = Receive-ObsMessage $session
    if ($hello.op -ne 0) { throw "Expected Hello (op 0), got op $($hello.op)." }
    $identify = [ordered]@{ rpcVersion = 1; eventSubscriptions = 0 }
    $auth = $hello.d.PSObject.Properties['authentication']
    if ($auth -and $auth.Value) {
        # obs-websocket v5: secret = b64(sha256(password + salt)); auth = b64(sha256(secret + challenge)).
        $password = [IO.File]::ReadAllText($Obs.PasswordFile)
        $sha = [Security.Cryptography.SHA256]::Create()
        try {
            $secret = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($password + $auth.Value.salt)))
            $identify.authentication = [Convert]::ToBase64String($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($secret + $auth.Value.challenge)))
        } finally { $sha.Dispose(); $password = $null; $secret = $null }
    }
    Send-ObsMessage $session ([ordered]@{ op = 1; d = $identify })
    $identified = Receive-ObsMessage $session
    if ($identified.op -ne 2) { throw "obs-websocket identify failed (op $($identified.op))." }
    $session
}
function Close-ObsWebSocket($Session) {
    if (-not $Session) { return }
    try { $Session.Socket.CloseAsync([Net.WebSockets.WebSocketCloseStatus]::NormalClosure, 'done', [Threading.CancellationToken]::None).GetAwaiter().GetResult() } catch { }
    try { $Session.Socket.Dispose() } catch { }
}

# Returns responseData (or $null when the request has none); throws on a failed requestStatus.
function Invoke-ObsRequest {
    param([Parameter(Mandatory)] $Session, [Parameter(Mandatory)] [string] $RequestType, [hashtable] $Data = @{}, [int] $TimeoutMs = 20000)
    $Session.NextId++
    $id = "r$($Session.NextId)"
    $d = [ordered]@{ requestType = $RequestType; requestId = $id }
    if ($Data.Count -gt 0) { $d.requestData = $Data }
    Send-ObsMessage $Session ([ordered]@{ op = 6; d = $d })
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        $left = [int] [Math]::Max(1, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        $message = Receive-ObsMessage $Session $left
        if ($message.op -ne 7 -or $message.d.requestId -ne $id) { continue }
        $status = $message.d.requestStatus
        if (-not $status.result) { throw "obs-websocket $RequestType failed: code $($status.code) $($status.PSObject.Properties['comment'].Value)" }
        $rd = $message.d.PSObject.Properties['responseData']
        return $(if ($rd) { $rd.Value } else { $null })
    }
}

function Get-OwnerObsProfileSnapshot {
    $snapshot = [ordered]@{}
    $appData = Join-Path $env:APPDATA 'obs-studio'
    if (Test-Path -LiteralPath $appData) {
        foreach ($f in Get-ChildItem -LiteralPath $appData -Recurse -File -Force -ErrorAction SilentlyContinue) {
            $hash = try { (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash } catch { "unreadable: $($_.Exception.GetType().Name)" }
            $snapshot[$f.FullName] = [ordered]@{ sha256 = $hash; size = $f.Length; mtime = $f.LastWriteTimeUtc.ToString('o') }
        }
    }
    foreach ($dir in @(Get-ChildItem -LiteralPath $env:LOCALAPPDATA -Directory -Force -Filter 'obs-studio*' -ErrorAction SilentlyContinue)) {
        foreach ($f in @($dir) + @(Get-ChildItem -LiteralPath $dir.FullName -Recurse -Force -ErrorAction SilentlyContinue)) {
            $snapshot["listing:$($f.FullName)"] = [ordered]@{ sha256 = $null; size = if ($f -is [IO.FileInfo]) { $f.Length } else { $null }; mtime = $f.LastWriteTimeUtc.ToString('o') }
        }
    }
    $snapshot
}

# Keys added, removed or changed between two snapshots (empty when identical).
function Compare-OwnerObsProfileSnapshot($Before, $After) {
    $diff = [Collections.Generic.List[object]]::new()
    foreach ($k in $Before.Keys) {
        if (-not $After.Contains($k)) { $diff.Add([ordered]@{ path = $k; change = 'removed' }); continue }
        $a = $Before[$k]; $b = $After[$k]
        if ($a.sha256 -ne $b.sha256 -or $a.size -ne $b.size -or $a.mtime -ne $b.mtime) { $diff.Add([ordered]@{ path = $k; change = 'changed'; before = $a; after = $b }) }
    }
    foreach ($k in $After.Keys) { if (-not $Before.Contains($k)) { $diff.Add([ordered]@{ path = $k; change = 'added' }) } }
    , $diff.ToArray()
}

function Stop-ObsPortable {
    [CmdletBinding()]
    param($Obs)
    if (-not $Obs -or $Obs.Stopped) { return }
    $Obs.Stopped = $true
    $proc = $Obs.Process
    if ($proc) {
        $owned = { $live = Get-Process -Id $Obs.ProcessId -ErrorAction SilentlyContinue; $live -and -not $live.HasExited -and $live.StartTime -eq $Obs.StartTime }
        if (& $owned) {
            try { [void] $proc.CloseMainWindow() } catch { }
            [void] $proc.WaitForExit(10000)
        }
        # Kill only the owned tree: descendants of the owned PID plus obs-browser-page processes naming the run folder.
        $all = @(Get-CimInstance Win32_Process -Property ProcessId, ParentProcessId, Name, CommandLine)
        $tree = [Collections.Generic.HashSet[int]]::new(); [void] $tree.Add([int] $Obs.ProcessId)
        do { $added = $false; foreach ($p in $all) { if ($tree.Contains([int] $p.ParentProcessId) -and $tree.Add([int] $p.ProcessId)) { $added = $true } } } while ($added)
        foreach ($p in $all) { if ($p.CommandLine -and $p.CommandLine.Contains($Obs.RunDir, [StringComparison]::OrdinalIgnoreCase)) { [void] $tree.Add([int] $p.ProcessId) } }
        foreach ($id in $tree) {
            if ($id -eq $Obs.ProcessId -and -not (& $owned)) { continue }
            Stop-Process -Id $id -Force -ErrorAction SilentlyContinue
        }
        try { [void] $proc.WaitForExit(5000) } catch { }
    }
    $after = Get-OwnerObsProfileSnapshot
    $diff = Compare-OwnerObsProfileSnapshot $Obs.OwnerBefore $after
    $Obs.OwnerChanged = $diff.Count -gt 0
    if ($Obs.OwnerChanged) {
        # Stop and preserve the evidence; never "restore" the owner's profile.
        try { Remove-Item -LiteralPath $Obs.PasswordFile -Force -ErrorAction SilentlyContinue } catch { }
        try { Remove-Item -LiteralPath (Join-Path $Obs.ConfigDir 'plugin_config\obs-websocket\config.json') -Force -ErrorAction SilentlyContinue } catch { }
        Write-ObsPortableText (Join-Path $Obs.RunDir 'owner-profile-changed.json') ([ordered]@{ changes = $diff } | ConvertTo-Json -Depth 6)
        throw "The owner's OBS profile changed during the run; evidence kept in $($Obs.RunDir)."
    }
    for ($i = 0; $i -lt 5 -and (Test-Path -LiteralPath $Obs.RunDir); $i++) {
        Remove-Item -LiteralPath $Obs.RunDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Obs.RunDir) { Start-Sleep -Seconds 1 }
    }
}
