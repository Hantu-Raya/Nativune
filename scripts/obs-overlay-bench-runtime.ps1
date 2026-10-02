# Dot-sourced after the existing sampler helpers. No top-level side effects.
function Send-ObsBenchPayload($Ctx,[string]$Command,[string]$Payload) {
    [IO.File]::WriteAllText((Join-Path (Get-BenchDirectory $Ctx.Root) $Command),$Payload,[Text.UTF8Encoding]::new($false))
}
function Test-ObsBenchA($Ctx,$Snapshot) {
    if (-not $Snapshot -or (Get-Overlay $Snapshot 'streams') -ne 1) {return $false}
    if ($Designer) {
        $d=Get-Prop $Snapshot.state 'designer'; $p=Get-Overlay $Snapshot 'previewNonces'
        $real=if ($script:designerCondition.kind -eq 'current') {1} else {0}
        if ($real -eq 1 -and ((Get-Overlay $Snapshot 'latestState') -ne 'playing' -or [int](Get-Overlay $Snapshot 'fixtureArtServed') -lt 1)) {return $false}
        return (Get-Prop $d 'open') -eq $true -and (Get-Prop $d 'visible') -eq $true -and (Get-Prop $d 'navigated') -eq $true -and
            (Get-Prop $p 'state') -eq 'Open' -and (Get-Prop $p 'open') -eq 1 -and (Get-Prop $p 'current') -eq (Get-Prop $d 'nonce') -and
            (Get-Overlay $Snapshot 'realStreams') -eq $real -and (Get-Overlay $Snapshot 'sampleStreams') -eq (1-$real) -and
            (Get-Prop (Get-Prop $Snapshot.state 'lyrics') 'open') -eq $script:designerCondition.lyrics
    }
    if ((Get-Overlay $Snapshot 'realStreams') -ne 1 -or (Get-Overlay $Snapshot 'latestState') -ne $Ctx.Workload.ToLowerInvariant()) {return $false}
    if ($AppOnly) {return $true}
    $counts=Get-Overlay $Snapshot 'streamsByLook'
    (Get-Prop $counts $Ctx.LookId) -eq 1 -and [int](Get-Overlay $Snapshot 'fixtureArtServed') -ge 1
}
function Test-ObsBenchB($Snapshot) {
    if (-not $Snapshot -or (Get-Overlay $Snapshot 'streams') -ne 0 -or (Get-Overlay $Snapshot 'realStreams') -ne 0) {return $false}
    if ($Designer) {
        return (Get-Prop (Get-Prop $Snapshot.state 'designer') 'open') -eq $false -and
            (Get-Prop (Get-Prop $Snapshot.state 'lyrics') 'open') -eq $script:designerCondition.lyrics
    }
    $true
}
function Get-ObsOffShape($Ctx) {
    $all=Get-AllProcesses; $tree=@(Get-ObsTree $Ctx.ObsProcess.Id $all)
    $shape=@($tree | Where-Object pid -ne $Ctx.ObsProcess.Id | Group-Object name | Sort-Object Name | ForEach-Object {"$($_.Name):$($_.Count)"}) -join '|'
    $pids=@($tree.pid)
    $renderers=@($all | Where-Object {$_.ProcessId -in $pids -and $_.CommandLine -match '(?:^|\s)--type=renderer(?:\s|$)'}).Count
    "$shape|renderers:$renderers"
}
# Trace all starts/stops during a window, including descendants born and gone between 1-second samples.
# Source identifiers are private to this arm; teardown occurs before switching pages.
function Start-ObsArmTrace($Ctx) {
    $prefix='obs-arm-'+[guid]::NewGuid().ToString('N')
    $all=Get-AllProcesses
    $initial=@(Get-AppTree $Ctx.App.Id $Ctx.Root $all)
    if (-not $AppOnly) {$initial+=@(Get-ObsTree $Ctx.ObsProcess.Id $all)}
    $ids=[Collections.Generic.HashSet[int]]::new();foreach ($p in $initial) {[void]$ids.Add($p.pid)}
    try {
        [void](Register-CimIndicationEvent -Query 'SELECT * FROM Win32_ProcessStartTrace' -SourceIdentifier "$prefix-start")
        [void](Register-CimIndicationEvent -Query 'SELECT * FROM Win32_ProcessStopTrace' -SourceIdentifier "$prefix-stop")
    } catch {
        foreach ($suffix in @('start','stop')) {Unregister-Event -SourceIdentifier "$prefix-$suffix" -ErrorAction SilentlyContinue}
        throw 'Arm blocked: full-tree process start/stop tracing unavailable.'
    }
    $log=Join-Path $Ctx.Root 'data/nativune.log'
    $failures=if (Test-Path $log) {@(Select-String -LiteralPath $log -Pattern 'process-failed').Count} else {0}
    @{prefix=$prefix;ids=$ids;initial=$initial;startQpc=(Get-Qpc);startUtc=[DateTime]::UtcNow;failureCountBefore=$failures}
}
function Stop-ObsArmTrace($Trace) {
    $exits=[Collections.Generic.List[object]]::new()
    try {
        $endUtc=[DateTime]::UtcNow
        Start-Sleep -Milliseconds 250
        $events=@(Get-Event | Where-Object {$_.SourceIdentifier -like "$($Trace.prefix)-*"} | Sort-Object { [long]$_.SourceEventArgs.NewEvent.TIME_CREATED })
        foreach ($traceEvent in $events) {
            $e=$traceEvent.SourceEventArgs.NewEvent
            $time=[DateTime]::FromFileTimeUtc([long]$e.TIME_CREATED)
            if ($time -lt $Trace.startUtc -or $time -gt $endUtc) {continue}
            if ($traceEvent.SourceIdentifier -eq "$($Trace.prefix)-start") {
                if ($Trace.ids.Contains([int]$e.ParentProcessID)) {[void]$Trace.ids.Add([int]$e.ProcessID)}
            } elseif ($Trace.ids.Contains([int]$e.ProcessID)) {
                $exits.Add(@{pid=[int]$e.ProcessID;name=[string]$e.ProcessName;time=$time.ToString('o')})
            }
        }
        @($exits)
    } finally {
        foreach ($suffix in @('start','stop')) {
            Unregister-Event -SourceIdentifier "$($Trace.prefix)-$suffix" -ErrorAction SilentlyContinue
            Get-Event -SourceIdentifier "$($Trace.prefix)-$suffix" -ErrorAction SilentlyContinue | Remove-Event -ErrorAction SilentlyContinue
        }
    }
}
function Start-DesignerPreview($Ctx) {
    Send-HookCommand $Ctx.Root 'command-obs-designer-open'
    $open=Wait-For {
        $s=Get-State $Ctx.Root 'designeropen'; $d=Get-Prop (Get-Prop $s 'state') 'designer'
        if ((Get-Prop $d 'open') -eq $true -and (Get-Prop $d 'visible') -eq $true -and (Get-Prop $d 'navigated') -eq $true -and (Get-Prop (Get-Overlay $s 'previewNonces') 'state') -eq 'Open') {$s}
    } 40
    if (-not $open) {throw 'Designer did not open.'}
    $options=if ($script:designerCondition.worst) {$worstData.worst.options} else {New-ObsBenchOptions 'pill'}
    $nonce=Get-Prop (Get-Prop $open.state 'designer') 'nonce'
    Send-ObsBenchPayload $Ctx 'command-obs-draft-look' (@{look=@{id='draft';name='Bench draft';options=$options};backdrop='checker'} | ConvertTo-Json -Depth 8 -Compress)
    if (-not (Wait-For {-not (Test-Path -LiteralPath (Join-Path (Get-BenchDirectory $Ctx.Root) 'command-obs-draft-look'))} 10)) {throw 'Worst draft command was not consumed.'}
    $url="http://localhost:47813/?look=draft&preview=1&pv=$nonce"
    if ($script:designerCondition.kind -ne 'current') {$url+='&sample='+$script:designerCondition.sample}
    Send-ObsBenchPayload $Ctx 'command-obs-designer-navigate' $url
    $Ctx.Reader=$true
}
function Stop-DesignerPreview($Ctx) {
    Send-HookCommand $Ctx.Root 'command-obs-designer-close'
    $closed=Wait-For {$s=Get-State $Ctx.Root 'designerclosed'; if (Test-ObsBenchB $s) {$s}} 20
    if (-not $closed) {throw 'Designer close did not release the preview stream.'}
    $Ctx.Reader=$null
}
function Invoke-SharedBench {
    $ctx=$null;$records=@{};$blocked=$null
    try {
        $ctx=Start-Launch 'Playing' 1; Invoke-Warmup $ctx
        foreach ($spec in $schedule) {
            $ctx.ActiveTheme=if ($spec.theme) {$spec.theme} else {$ctx.ActiveTheme}
            $ctx.LookId=$ctx.Items[$ctx.ActiveTheme].lookId
            $ctx.ItemId=$ctx.Items[$ctx.ActiveTheme].itemId
            $retention=$false;$arm=$null
            for ($attempt=1;$attempt -le 2;$attempt++) {
                if (-not (Test-TimeFits $armSeconds)) {$script:timeBoxHit=$true;throw 'time box reached'}
                if (-not (Test-AgeFits $ctx)) {throw 'PlayingLong age guard: entire unfinished batch blocked; no reset inside a window.'}
                $arm=Invoke-Arm $ctx $spec.pair $spec.condition $attempt
                $arm['id']=$spec.id;$arm['theme']=$spec.theme
                if ($arm.reasons -match 'shape') {$retention=$true}
                if ($arm.valid) {break}
            }
            if (-not $arm.valid) {throw "Arm $($spec.id) invalid twice: $($arm.reasons -join '; ')"}
            $arm['retention']=$retention;$records[$spec.id]=$arm
        }
        $scores=Get-ObsSharedScore $schedule $records $budgets
        $workloadResults['Playing']=$scores
        foreach ($theme in $scores.Keys) {
            $s=$scores[$theme]
            if ($s.status -eq 'fresh-block-required') {Add-Blocked "G3.Playing.$theme" 'fresh separately approved Standard four-pair block' (@{triggers=$s.triggers;command="-Workload Playing -Look $theme -FallbackFrom <this bench-report.json> -FramesFrom $FramesFrom -StillsReport $StillsReport -TimeBoxMinutes 30"}|ConvertTo-Json -Compress)}
            else {Add-Check "G3.Playing.$theme" 'every largest conservative delta <= budget' $s ($s.status -eq 'pass')}
        }
    } catch {$blocked=$_.Exception.Message;Add-Blocked 'G3.Playing.SharedBaseline' 'all 50 valid arms' $blocked;Add-RunError 'shared' 'Playing' 1 $script:launchIndex $_}
    finally {Stop-Launch $ctx}
}
function Invoke-DesignerBench {
    $conditions=@(
        @{name='sample-playing';kind='sample';sample='playing';worst=$false},
        @{name='sample-paused';kind='sample';sample='paused';worst=$false},
        @{name='current';kind='current';sample=$null;worst=$false},
        @{name='max-area';kind='current';sample=$null;worst=$true})
    foreach ($lyrics in @($false,$true)) {
        foreach ($c in $conditions) {
            $script:designerCondition=@{name=$c.name;kind=$c.kind;sample=$c.sample;worst=$c.worst;lyrics=$lyrics}
            if ($script:timeBoxHit) {Add-Blocked "Designer.$($c.name)-lyrics-$lyrics" 'complete full-length block' 'time box reached';continue}
            $b=Invoke-Block 'Playing' 1
            $name="$($c.name)-lyrics-$lyrics"
            $workloadResults[$name]=$b
            if ($b.blocked) {Add-Blocked "Designer.$name" '4 valid AB/BA pairs' $b.blocked;continue}
            foreach ($m in $budgets.Keys) {
                $v=Get-Verdict @($b.pairs | ForEach-Object {$_.delta[$m]}) $budgets[$m]
                Add-Check "Designer.$name.$m" "every pair <= $($budgets[$m])" $v ($v.verdict -eq 'pass')
            }
        }
    }
}
