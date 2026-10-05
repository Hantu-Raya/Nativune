# Dot-sourced after the existing sampler helpers. No top-level side effects.
function Send-ObsBenchPayload($Ctx,[string]$Command,[string]$Payload) {
    Assert-DesignerDeadline
    [IO.File]::WriteAllText((Join-Path (Get-BenchDirectory $Ctx.Root) $Command),$Payload,[Text.UTF8Encoding]::new($false))
}
function Test-ObsBenchA($Ctx,$Snapshot) {
    if (-not $Snapshot -or (Get-Overlay $Snapshot 'streams') -ne 1) {return $false}
    if ($Designer) {
        $d=Get-Overlay $Snapshot 'designer'; $p=Get-Overlay $Snapshot 'previewNonces'
        $real=if ($script:designerCondition.kind -eq 'current') {1} else {0}
        if ($real -eq 1 -and ((Get-Overlay $Snapshot 'latestState') -ne 'playing' -or [int](Get-Overlay $Snapshot 'fixtureArtServed') -lt 1)) {return $false}
        return (Get-Prop $d 'open') -eq $true -and (Get-Prop $d 'visible') -eq $true -and (Get-Prop $d 'navigated') -eq $true -and
            (Get-Prop $p 'state') -eq 'Open' -and (Get-Prop $p 'open') -eq 1 -and (Get-Prop $p 'current') -eq (Get-Prop $d 'nonce') -and
            (Get-Overlay $Snapshot 'realStreams') -eq $real -and (Get-Overlay $Snapshot 'sampleStreams') -eq (1-$real) -and
            (Get-Prop (Get-Overlay $Snapshot 'lyrics') 'open') -eq $script:designerCondition.lyrics
    }
    if ((Get-Overlay $Snapshot 'realStreams') -ne 1 -or (Get-Overlay $Snapshot 'latestState') -ne $Ctx.Workload.ToLowerInvariant()) {return $false}
    if ($AppOnly) {return $true}
    $counts=Get-Overlay $Snapshot 'streamsByLook'
    (Get-Prop $counts $Ctx.LookId) -eq 1 -and [int](Get-Overlay $Snapshot 'fixtureArtServed') -ge 1
}
function Test-ObsBenchB($Snapshot) {
    if (-not $Snapshot -or (Get-Overlay $Snapshot 'streams') -ne 0 -or (Get-Overlay $Snapshot 'realStreams') -ne 0) {return $false}
    if ($Designer) {
        return (Get-Prop (Get-Overlay $Snapshot 'designer') 'open') -eq $false -and
            (Get-Prop (Get-Overlay $Snapshot 'lyrics') 'open') -eq $script:designerCondition.lyrics
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
    Assert-DesignerDeadline 60
    Send-HookCommand $Ctx.Root 'command-obs-designer-open'
    $open=Wait-For {
        $s=Get-State $Ctx.Root 'designeropen'; $d=Get-Overlay $s 'designer'
        if ((Get-Prop $d 'open') -eq $true -and (Get-Prop $d 'visible') -eq $true -and (Get-Prop $d 'navigated') -eq $true -and (Get-Prop (Get-Overlay $s 'previewNonces') 'state') -eq 'Open') {$s}
    } 40
    if (-not $open) {throw 'Designer did not open.'}
    $options=if ($script:designerCondition.worst) {$worstData.worst.options} else {New-ObsBenchOptions 'pill'}
    $nonce=Get-Prop (Get-Overlay $open 'designer') 'nonce'
    Send-ObsBenchPayload $Ctx 'command-obs-draft-look' (@{look=@{id='draft';name='Bench draft';options=$options};backdrop='checker'} | ConvertTo-Json -Depth 8 -Compress)
    if (-not (Wait-For {-not (Test-Path -LiteralPath (Join-Path (Get-BenchDirectory $Ctx.Root) 'command-obs-draft-look'))} 10)) {throw 'Worst draft command was not consumed.'}
    $url="http://localhost:47813/?look=draft&preview=1&pv=$nonce"
    if ($script:designerCondition.kind -ne 'current') {$url+='&sample='+$script:designerCondition.sample}
    Send-ObsBenchPayload $Ctx 'command-obs-designer-navigate' $url
    $Ctx.Reader=$true
    if ($script:designerCalibration) {
        if (-not (Wait-For {$s=Get-State $Ctx.Root 'calibrationready';if (Test-ObsBenchA $Ctx $s) {$s}} 20)) {throw 'Calibration preview did not become ready.'}
        $ack=Set-DesignerCalibrationLoad $Ctx $script:designerCalibration
        $Ctx.Record['calibrationStart']=$ack
    }
}
function Stop-DesignerPreview($Ctx) {
    Assert-DesignerDeadline
    try {
        if ($script:designerCalibration) {
            $Ctx.Record['calibrationOff']=Set-DesignerCalibrationLoad $Ctx @{off=$true}
        }
    } finally {
        Send-HookCommand $Ctx.Root 'command-obs-designer-close'
        $closed=Wait-For {$s=Get-State $Ctx.Root 'designerclosed'; if (Test-ObsBenchB $s) {$s}} 20
        if (-not $closed) {throw 'Designer close did not release the preview stream.'}
        $Ctx.Reader=$null
    }
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
    } catch {$blocked=$_.Exception.Message;Add-Blocked 'G3.Playing.SharedBaseline' "all $($schedule.Count) valid arms" $blocked;Add-RunError 'shared' 'Playing' 1 $script:launchIndex $_}
    finally {Stop-Launch $ctx}
}
function Get-DesignerCalibrationAck($Ctx, $Load) {
    $path=Join-Path (Get-BenchDirectory $Ctx.Root) 'designer-calibration-load.json'
    if (-not (Test-Path -LiteralPath $path)) {return $null}
    $ack=Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable
    if ($ack['active'] -isnot [bool]) {return $null}
    foreach ($field in @('cpuPp','memMiB','retainedBytes')) {
        if ($ack[$field] -isnot [ValueType] -or $ack[$field] -is [bool] -or -not [double]::IsFinite([double]$ack[$field])) {return $null}
    }
    if ($Load.ContainsKey('off')) {
        if ($ack['active'] -ceq $false -and $ack['cpuPp'] -eq 0 -and $ack['memMiB'] -eq 0 -and $ack['retainedBytes'] -eq 0 -and $null -eq $ack['startedAtUtc']) {return $ack}
    } elseif ($ack['active'] -ceq $true -and $ack['cpuPp'] -eq $Load.cpuPp -and $ack['memMiB'] -eq $Load.memMiB -and
        $ack['retainedBytes'] -eq [Math]::Ceiling($Load.memMiB*1MB) -and $ack['startedAtUtc']) {
        return $ack
    }
    $null
}
function Set-DesignerCalibrationLoad($Ctx, $Load) {
    Assert-DesignerDeadline
    $path=Join-Path (Get-BenchDirectory $Ctx.Root) 'designer-calibration-load.json'
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    Send-ObsBenchPayload $Ctx 'command-obs-designer-calibration-load' ($Load | ConvertTo-Json -Compress)
    $ack=Wait-For {Get-DesignerCalibrationAck $Ctx $Load} 10 100
    if (-not $ack) {throw 'Calibration load acknowledgement missing or mismatched.'}
    $ack
}
function Get-DesignerPreviewDump($Ctx) {
    Assert-DesignerDeadline
    $path=Join-Path (Get-BenchDirectory $Ctx.Root) 'preview-state.json'
    Remove-Item -LiteralPath $path -ErrorAction SilentlyContinue
    Send-HookCommand $Ctx.Root 'command-obs-preview-state-dump'
    if (-not (Wait-For {Test-Path -LiteralPath $path} 10 100)) {throw 'Preview-state-dump unavailable.'}
    $dump=Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable -Depth 16
    if (-not $dump -or $dump.ContainsKey('error')) {throw 'Preview-state-dump failed.'}
    $dump
}
function Test-DesignerPausedDump($Before, $After) {
    foreach ($dump in @($Before,$After)) {
        if (-not $dump -or $dump['fillTimer'] -isnot [ValueType] -or $dump['fillTimer'] -is [bool] -or $dump['fillTimer'] -ne 0 -or
            $dump['runningAnimations'] -isnot [ValueType] -or $dump['runningAnimations'] -is [bool] -or $dump['runningAnimations'] -ne 0 -or
            $dump['cadenceLogSequence'] -isnot [ValueType] -or $dump['cadenceLogSequence'] -is [bool] -or
            $dump['pageNow'] -isnot [ValueType] -or $dump['pageNow'] -is [bool] -or -not [double]::IsFinite([double]$dump['pageNow']) -or
            $dump['counters'] -isnot [Collections.IDictionary] -or $dump['counters'].Count -eq 0) {return $false}
    }
    if ($Before.counters.Count -ne $After.counters.Count) {return $false}
    foreach ($key in $Before.counters.Keys) {
        if ($Before.counters[$key] -isnot [ValueType] -or $Before.counters[$key] -is [bool] -or
            -not [double]::IsFinite([double]$Before.counters[$key]) -or -not $After.counters.Contains($key) -or
            $After.counters[$key] -isnot [ValueType] -or $After.counters[$key] -is [bool] -or $Before.counters[$key] -ne $After.counters[$key]) {return $false}
    }
    $Before['cadenceLogSequence'] -eq $After['cadenceLogSequence'] -and $After['pageNow']-$Before['pageNow'] -ge 5000
}
function Invoke-DesignerPausedProbe($Ctx) {
    $id='sample-paused-structural';$saved=$script:designerCondition
    try {
        if (-not (Test-TimeFits 60)) {throw 'deadline: structural probe and cleanup cannot fit'}
        if ($Ctx.Reader) {Stop-DesignerPreview $Ctx}
        $script:designerCondition=@{name='sample-paused';kind='sample';sample='paused';worst=$false;lyrics=$false}
        Start-DesignerPreview $Ctx
        if (-not (Wait-For {$s=Get-State $Ctx.Root 'pausedstructural';if (Test-ObsBenchA $Ctx $s) {$s}} 20)) {throw 'Paused structural preview not ready.'}
        $before=Wait-For {$d=Get-DesignerPreviewDump $Ctx;if ($d['fillTimer'] -eq 0 -and $d['runningAnimations'] -eq 0) {$d}} 10 250
        if (-not $before) {throw 'Paused structural preview did not become idle.'}
        $start=Get-Qpc
        Wait-UntilQpc ($start+5*$freq)
        $after=Get-DesignerPreviewDump $Ctx
        $ok=Test-DesignerPausedDump $before $after
        $row=@{kind='structural';status=$(if ($ok) {'pass'} else {'fail'});seconds=Get-Seconds $start (Get-Qpc);before=$before;after=$after;resourceQualified=$false}
        $script:designerProfileRows[$id]=$row
        Add-Check "Designer.$id" 'fillTimer=0; no running animations; all counters and cadence stable over >=5s; NOT resource qualification' $row $ok
    } catch {
        $script:designerProfileRows[$id]=@{kind='structural';status='blocked';reason=$_.Exception.Message;resourceQualified=$false}
        Add-Blocked "Designer.$id" '5s structural idle probe, not a resource pass' $_.Exception.Message
    } finally {
        try {if ($Ctx.Reader) {Stop-DesignerPreview $Ctx}} catch {Add-Blocked "Designer.$id.cleanup" 'preview closed' $_.Exception.Message}
        $script:designerCondition=$saved
    }
}
function Invoke-DesignerGrossCalibration($Ctx) {
    foreach ($spec in @(
        @{id='gross-cpu';metric='app.cpuPp';cpuPp=1.0;memMiB=0.0},
        @{id='gross-memory';metric='app.privateMiB';cpuPp=0.0;memMiB=120.0})) {
        $id=$spec.id
        try {
            if (-not (Test-TimeFits (2*$armSeconds+60))) {throw 'deadline: full calibration AB pair and cleanup cannot fit'}
            $script:designerCalibration=@{cpuPp=$spec.cpuPp;memMiB=$spec.memMiB}
            $pair=@{}
            foreach ($condition in @('A','B')) {
                $arm=$null
                for ($attempt=1;$attempt -le 2;$attempt++) {
                    $remaining=if ($condition -eq 'A') {2*$armSeconds+60} else {$armSeconds+60}
                    if (-not (Test-TimeFits $remaining)) {throw 'deadline: calibration windows and cleanup cannot fit'}
                    if (-not (Test-AgeFits $Ctx)) {throw 'Calibration fixture-age guard reached.'}
                    $arm=Invoke-Arm $Ctx $(if ($id -eq 'gross-cpu') {3} else {4}) $condition $attempt
                    $arm['calibration']=$id
                    if ($arm.valid) {break}
                }
                if (-not $arm.valid) {throw "Calibration arm invalid twice: $($arm.reasons -join '; ')"}
                $pair[$condition]=$arm
            }
            $delta=Round3 ([double]$pair.A.metrics[$spec.metric]-[double]$pair.B.metrics[$spec.metric])
            $v=Get-Verdict @($delta) $budgets[$spec.metric]
            $detected=$v.verdict -eq 'fail'
            $row=@{kind='calibration';label='gross attribution check; not near-ceiling sensitivity';status=$(if ($detected) {'pass'} else {'fail'})
                verdict=$(if ($detected) {'calibration detected'} else {'calibration NOT detected'});metric=$spec.metric;budget=$budgets[$spec.metric]
                injected=$script:designerCalibration;delta=$delta;metricVerdict=$v.verdict;a=$pair.A.id;b=$pair.B.id;ack=$pair.A.calibrationAck;offAck=$Ctx.Record['calibrationOff']}
            $script:designerProfileRows[$id]=$row
            Add-Check "Designer.$id" "A-only gross load: $($spec.metric) MUST FAIL unchanged budget (calibration detected)" $row $detected
        } catch {
            $script:designerProfileRows[$id]=@{kind='calibration';status='blocked';reason=$_.Exception.Message}
            Add-Blocked "Designer.$id" 'full valid AB pair; gross attribution check detects metric violation' $_.Exception.Message
        } finally {
            try {if ($Ctx.Reader) {Stop-DesignerPreview $Ctx}} catch {Add-Blocked "Designer.$id.cleanup" 'load off and preview closed' $_.Exception.Message}
            $script:designerCalibration=$null
        }
    }
}
function Invoke-DesignerBench {
    $conditions=@(Get-ObsDesignerConditions $Profile)
    if ($Profile -eq 'Fast-v1') {
        foreach ($c in $conditions) {$script:designerProfileRows["$($c.name)-lyrics-$($c.lyrics)"]=@{kind='measured';status='blocked';reason='not run'}}
        foreach ($id in @('sample-paused-structural','gross-cpu','gross-memory')) {$script:designerProfileRows[$id]=@{kind=$(if ($id -eq 'sample-paused-structural') {'structural'} else {'calibration'});status='blocked';reason='not run'}}
    }
    for ($i=0;$i -lt $conditions.Count;$i++) {
        $c=$conditions[$i];$script:designerCondition=$c
        $name="$($c.name)-lyrics-$($c.lyrics)"
        if ($script:timeBoxHit) {Add-Blocked "Designer.$name" 'complete full-length block' 'time box reached';continue}
        $b=Invoke-Block 'Playing' 1 -ProbeAfter:($Profile -eq 'Fast-v1' -and $i -eq 0) -CalibrationAfter:($Profile -eq 'Fast-v1' -and $i -eq $conditions.Count-1)
        $workloadResults[$name]=$b
        if ($b.blocked) {
            $script:designerProfileRows[$name]=@{kind='measured';status='blocked';reason=$b.blocked;pairs=$b.pairs}
            Add-Blocked "Designer.$name" "$Pairs valid balanced AB/BA pairs" $b.blocked;continue
        }
        $metrics=[ordered]@{}
        foreach ($m in $budgets.Keys) {
            $v=Get-Verdict @($b.pairs | ForEach-Object {$_.delta[$m]}) $budgets[$m];$metrics[$m]=$v
            if ($Profile -eq 'Fast-v1' -and $v.verdict -in @('between','blocked')) {Add-Blocked "Designer.$name.$m" "every pair <= $($budgets[$m])" 'mixed or missing paired values'}
            else {Add-Check "Designer.$name.$m" "every pair <= $($budgets[$m])" $v ($v.verdict -eq 'pass')}
        }
        $script:designerProfileRows[$name]=@{kind='measured';status=$(if (@($metrics.Values | Where-Object {$_.verdict -in @('between','blocked')}).Count) {'blocked'} elseif (@($metrics.Values | Where-Object {$_.verdict -eq 'fail'}).Count) {'fail'} else {'pass'});metrics=$metrics;pairs=$b.pairs}
    }
    if ($Profile -eq 'Fast-v1') {
        foreach ($id in @('sample-paused-structural','gross-cpu','gross-memory')) {
            if ($script:designerProfileRows[$id].status -eq 'blocked' -and $script:designerProfileRows[$id].reason -eq 'not run') {
                Add-Blocked "Designer.$id" 'required fast diagnostic row' 'not run before deadline or anchor failure'
            }
        }
    }
}
