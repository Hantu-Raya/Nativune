# Pure checks invoked only by -DryRun. No process, network, sleep or filesystem mutation.
function Test-ObsBenchWorst {
    $v1Path = Join-Path $PSScriptRoot 'fixtures/obs-overlay/bench-worst-selfcheck.json'
    $v2Path = Join-Path $PSScriptRoot 'fixtures/obs-overlay/bench-worst-v2-selfcheck.json'
    foreach ($designer in @($false, $true)) {
        $v1 = Read-ObsFramesWorst $v1Path -Designer:$designer
        if ($v1.version -ne 1 -or $v1.framesGreen -ne $false) { throw 'Legacy v1 evidence changed.' }
    }
    $v2 = Read-ObsFramesWorst $v2Path -Designer
    if ($v2.version -ne 2 -or $v2.framesGreen -ne $false -or $v2.exhaustiveComplete -ne $false) { throw 'Fast-v2 evidence must not be relabelled or certified exhaustive.' }
    Assert-ObsFramesWorst $v2 -Profile Fast-v1
    Assert-ObsFramesWorst $v2 -Designer -Profile Fast-v1
    $json = Get-Content -Raw -LiteralPath $v2Path
    $certified = $json | ConvertFrom-Json -AsHashtable -Depth 32
    $certified.protocol = 'Exhaustive-v1'; $certified.framesGreen = $true; $certified.exhaustiveComplete = $true
    Assert-ObsFramesWorst $certified
    Assert-ObsFramesWorst $certified -Designer
    Assert-ObsFramesWorst $certified -Profile Fast-v1
    $withMetadata = $json | ConvertFrom-Json -AsHashtable -Depth 32
    $withMetadata.supplemental = @{protocol='LookFx-v1'; rowIds=@('lookfx.playing')}
    $withMetadata.worst.options.backgroundBlur = 12
    Assert-ObsFramesWorst $withMetadata -Designer
    if ($withMetadata.supplemental.protocol -ne 'LookFx-v1' -or $withMetadata.worst.options.backgroundBlur -ne 12) { throw 'Supplemental metadata must be preserved.' }
    $cases = @(
        @{name='unsupported version'; edit={$args[0].version=3}; error='version:1 or version:2'}
        @{name='string v2 version'; edit={$args[0].version='2'}; error='numeric version'}
        @{name='missing worst'; edit={[void]$args[0].Remove('worst')}; error='worst:'}
        @{name='missing options'; edit={[void]$args[0].worst.Remove('options')}; error='worst:'}
        @{name='missing protocol'; edit={[void]$args[0].Remove('protocol')}; error='protocol'}
        @{name='unknown protocol'; edit={$args[0].protocol='unknown'}; error='protocol'}
        @{name='profile incomplete'; edit={$args[0].profileComplete=$false}; error='profileComplete'}
        @{name='missing profile completion'; edit={[void]$args[0].Remove('profileComplete')}; error='profileComplete'}
        @{name='string profile completion'; edit={$args[0].profileComplete='true'}; error='profileComplete'}
        @{name='incomplete'; edit={$args[0].complete=$false}; error='complete'}
        @{name='missing completion'; edit={[void]$args[0].Remove('complete')}; error='complete'}
        @{name='string completion'; edit={$args[0].complete='true'}; error='complete'}
        @{name='missing rows'; edit={$args[0].missingIds=@('frames.missing')}; error='missingIds'}
        @{name='absent missingIds'; edit={[void]$args[0].Remove('missingIds')}; error='missingIds'}
        @{name='null missingIds'; edit={$args[0].missingIds=$null}; error='missingIds'}
        @{name='string missingIds'; edit={$args[0].missingIds=''}; error='missingIds'}
        @{name='unknown theme'; edit={$args[0].worst.theme='unknown'}; error='theme'}
        @{name='fractional width'; edit={$args[0].worst.width=600.5}; error='geometry'}
        @{name='string width'; edit={$args[0].worst.width='600'}; error='geometry'}
        @{name='out-of-range scale'; edit={$args[0].worst.scale=205}; error='configuration range'}
        @{name='mismatched options'; edit={$args[0].worst.options.width=590}; error='options disagree'}
        @{name='missing source'; edit={[void]$args[0].worst.Remove('source')}; error='geometry'}
        @{name='missing source height'; edit={[void]$args[0].worst.source.Remove('h')}; error='geometry'}
        @{name='wrong source height'; edit={$args[0].worst.source.h=802}; error='canonical geometry'}
        @{name='fractional source'; edit={$args[0].worst.source.h=800.5}; error='geometry'}
        @{name='negative source'; edit={$args[0].worst.source.w=-640}; error='geometry'}
        @{name='missing geometry option'; edit={[void]$args[0].worst.options.Remove('showArt')}; error='geometry option'}
        @{name='string geometry option'; edit={$args[0].worst.options.showTimes='false'}; error='geometry option'}
        @{name='mismatched geometry option'; edit={$args[0].worst.options.showTimes=$false}; error='canonical geometry'}
        @{name='missing framesGreen'; edit={[void]$args[0].Remove('framesGreen')}; error='framesGreen'}
        @{name='string framesGreen'; edit={$args[0].framesGreen='true'}; error='framesGreen'}
        @{name='missing exhaustiveComplete'; edit={[void]$args[0].Remove('exhaustiveComplete')}; error='exhaustiveComplete'}
        @{name='Fast claims exhaustive'; edit={$args[0].exhaustiveComplete=$true}; error='certification'}
        @{name='Fast claims green'; edit={$args[0].framesGreen=$true}; error='certification'}
        @{name='incomplete exhaustive Designer'; edit={$args[0].protocol='Exhaustive-v1'}; error='certification'}
        @{name='Fast real OBS'; edit={}; error='not certified green'; realObs=$true}
        @{name='incomplete exhaustive real OBS'; edit={$args[0].protocol='Exhaustive-v1'}; error='not certified green'; realObs=$true}
        @{name='exhaustive green without completion'; edit={$args[0].protocol='Exhaustive-v1';$args[0].framesGreen=$true}; error='certification'; realObs=$true}
        @{name='Fast OBS profile incomplete';edit={$args[0].profileComplete=$false};error='profileComplete';realObs=$true;profile='Fast-v1'}
        @{name='Fast OBS incomplete';edit={$args[0].complete=$false};error='complete';realObs=$true;profile='Fast-v1'}
        @{name='Fast OBS missing rows';edit={$args[0].missingIds=@('frames.missing')};error='missingIds';realObs=$true;profile='Fast-v1'}
        @{name='Fast OBS absent missingIds';edit={[void]$args[0].Remove('missingIds')};error='missingIds';realObs=$true;profile='Fast-v1'}
    )
    foreach ($case in $cases) {
        $data = $json | ConvertFrom-Json -AsHashtable -Depth 32
        & $case.edit $data
        $rejected = $false
        try { Assert-ObsFramesWorst $data -Designer:(-not $case['realObs']) -Profile $(if ($case['profile']) {$case.profile} else {'Exhaustive-v1'}) }
        catch {
            if ($_.Exception.Message -notlike "*$($case.error)*") { throw "Wrong rejection for $($case.name): $($_.Exception.Message)" }
            $rejected = $true
        }
        if (-not $rejected) { throw "Malformed evidence accepted: $($case.name)." }
    }
    "Self-check: v1 unchanged; complete Fast-v2 admitted by Designer/Fast-v1 OBS, rejected by Exhaustive OBS; certified Exhaustive-v1 and supplemental metadata accepted; $($cases.Count) schema/geometry/completion/certification rejections PASS"
}
function Test-ObsBenchComposedAdmission {
    $base=Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'fixtures/obs-overlay/bench-worst-v2-selfcheck.json') | ConvertFrom-Json -AsHashtable -Depth 32
    $base.profileComplete=$false;$base.complete=$false;$base.coverageComplete=$true;$base.qualificationComplete=$false
    $base.provenance=@{kind='Fast-v2-composed';version=1;payloadIdentical=$true;harnessIdentity='attested';originalHarnessBytesRetained=$false
        limitations=@('Synthetic schema check only; original harness bytes not retained.')
        sourceRuns=@(@{runId='run-a';manifestSha256=('a'*64)},@{runId='run-b';manifestSha256=('b'*64)})
        inventory=@{profile='Fast-v2';version=1;hash=('c'*64);requiredRowIds=@('guard','mutant')}
        selectedRows=@(@{rowId='guard';sourceRun='run-a';evidenceSha256=('d'*64)},@{rowId='mutant';sourceRun='run-b';evidenceSha256=('e'*64)})}
    $json=$base|ConvertTo-Json -Depth 32
    foreach ($designer in @($false,$true)) {Assert-ObsFramesWorst $base -Profile Fast-v1 -Designer:$designer}
    if ((Get-ObsBenchAdmission $base) -ne 'provisional-composed' -or $base.profileComplete -or $base.complete -or $base.qualificationComplete -or $base.framesGreen) {throw 'Provisional composed evidence relabelled as certified.'}
    foreach ($designer in @($false,$true)) {
        $rejected=$false
        try {Assert-ObsFramesWorst $base -Designer:$designer} catch {$rejected=$true}
        if (-not $rejected) {throw 'Exhaustive profile accepted provisional incomplete composition.'}
    }
    $cases=@(
        @{name='kind';edit={$args[0].provenance.kind='composed'}}
        @{name='string version';edit={$args[0].provenance.version='1'}}
        @{name='protocol';edit={$args[0].protocol='Exhaustive-v1'}}
        @{name='missingIds';edit={$args[0].missingIds=@('guard')}}
        @{name='coverage';edit={$args[0].coverageComplete=$false}}
        @{name='qualification';edit={$args[0].qualificationComplete=$true}}
        @{name='profile completion mixture';edit={$args[0].profileComplete=$true}}
        @{name='completion mixture';edit={$args[0].complete=$true}}
        @{name='green mixture';edit={$args[0].framesGreen=$true}}
        @{name='exhaustive mixture';edit={$args[0].exhaustiveComplete=$true}}
        @{name='string boolean';edit={$args[0].coverageComplete='true'}}
        @{name='payload identity';edit={$args[0].provenance.payloadIdentical=$false}}
        @{name='harness identity';edit={$args[0].provenance.harnessIdentity='verified'}}
        @{name='original bytes';edit={$args[0].provenance.originalHarnessBytesRetained=$true}}
        @{name='missing limitations';edit={$args[0].provenance.limitations=@()}}
        @{name='sources absent';edit={$args[0].provenance.sourceRuns=@()}}
        @{name='duplicate source';edit={$args[0].provenance.sourceRuns[1].runId='run-a'}}
        @{name='source hash';edit={$args[0].provenance.sourceRuns[0].manifestSha256='invalid'}}
        @{name='inventory profile';edit={$args[0].provenance.inventory.profile='Fast-v1'}}
        @{name='inventory hash';edit={$args[0].provenance.inventory.hash='invalid'}}
        @{name='inventory version';edit={$args[0].provenance.inventory.version='1'}}
        @{name='duplicate required';edit={$args[0].provenance.inventory.requiredRowIds=@('guard','guard')}}
        @{name='dropped required guard';edit={$args[0].provenance.inventory.requiredRowIds=@('mutant')}}
        @{name='selection incomplete';edit={$args[0].provenance.selectedRows=@($args[0].provenance.selectedRows[0])}}
        @{name='duplicate selection';edit={$args[0].provenance.selectedRows[1].rowId='guard'}}
        @{name='unknown row';edit={$args[0].provenance.selectedRows[1].rowId='phantom'}}
        @{name='unknown source';edit={$args[0].provenance.selectedRows[1].sourceRun='run-c'}}
        @{name='evidence hash';edit={$args[0].provenance.selectedRows[1].evidenceSha256='invalid'}}
        @{name='geometry still mandatory';edit={$args[0].worst.source.h=802}}
    )
    foreach ($case in $cases) {
        $data=$json|ConvertFrom-Json -AsHashtable -Depth 32
        & $case.edit $data
        foreach ($designer in @($false,$true)) {
            $rejected=$false
            try {Assert-ObsFramesWorst $data -Profile Fast-v1 -Designer:$designer} catch {$rejected=$true}
            if (-not $rejected) {throw "Malformed provisional composition accepted: $($case.name)."}
        }
    }
    "Self-check: authorized provisional composition ONLY in Fast-v1; strict flag bundle, exact inventory/selected set, source references, hashes, unchanged geometry, no certification; $($cases.Count*2) malformed Designer/OBS admissions rejected PASS"
}
function Test-ObsBenchProfiles {
    . (Join-Path $PSScriptRoot 'obs-overlay-bench-runtime.ps1')
    $themes=@('pill','matte','matte-light','standard','classic','simple','album-art','card')
    $fast=@(New-ObsBenchSchedule SharedBaseline $themes 47813 -Profile Fast-v1)
    if ($fast.Count -ne 26 -or $fast[0].id -ne 'B0' -or $fast[-1].id -ne 'B_end' -or
        @($fast | Where-Object condition -eq A).Count -ne 16 -or @($fast | Where-Object condition -eq B).Count -ne 10) {throw 'Fast shared schedule requires 16 A + 10 B, both endpoints.'}
    if (($fast.id -join ',') -ne ((@(New-ObsBenchSchedule SharedBaseline $themes 47813 -Profile Fast-v1)).id -join ',')) {throw 'Fast seed reproducibility regression.'}
    $r1=@($fast | Where-Object {$_.condition -eq 'A' -and $_.round -eq 1} | ForEach-Object theme)
    $r2=@($fast | Where-Object {$_.condition -eq 'A' -and $_.round -eq 2} | ForEach-Object theme)
    [array]::Reverse($r1)
    if (($r1 -join ',') -ne ($r2 -join ',')) {throw 'Fast round 2 must reverse seeded round 1.'}
    foreach ($theme in $themes) {
        $aa=@($fast | Where-Object theme -eq $theme)
        if ($aa.Count -ne 2) {throw 'Fast shared profile dropped a theme or repeat.'}
        foreach ($a in $aa) {
            $index=[array]::IndexOf($fast,$a)
            $b=@($fast | Where-Object id -eq $a.immediateB)[0]
            if ([Math]::Abs([array]::IndexOf($fast,$b)-$index) -ne 1 -or -not $a.beforeB -or -not $a.afterB) {throw 'Fast adjacency/brackets regression.'}
        }
    }
    $standard=@(New-ObsBenchSchedule Standard @('pill') 1 -Profile Fast-v1)
    if ($standard.Count -ne 4 -or ($standard.condition -join '') -ne 'ABBA') {throw 'Fast standard requires two balanced pairs.'}
    if ((26*150+180)/60 -ne 68 -or (26*150+180+420)/60 -ne 75 -or
        (4*150+180)/60 -ne 13 -or (4*150+180+120)/60 -ne 15) {throw 'Fast OBS arithmetic regression.'}
    $anchors=@(Get-ObsDesignerConditions Fast-v1)
    if ($anchors.Count -ne 4 -or ($anchors.name -join ',') -ne 'sample-playing,current-default,current-max-area,current-max-area' -or
        ($anchors.lyrics -join ',') -ne 'False,False,False,True' -or ($anchors.worst -join ',') -ne 'False,False,True,True' -or
        @(Get-ObsDesignerConditions Exhaustive-v1).Count -ne 8 -or
        (4*2*2*150+4*60+2*2*150+60+300)/60 -ne 60) {throw 'Designer profiles/60-minute arithmetic regression.'}
    if (-not (Test-ObsDesignerDeadlineFits 0 3600 1 3579 20) -or
        (Test-ObsDesignerDeadlineFits 0 3600 1 3580 20) -or
        (Test-ObsDesignerDeadlineFits 3590 3600 1 0 20) -or
        -not (Test-ObsDesignerDeadlineFits 3590 3600 1 0 2)) {throw 'Invocation deadline/cleanup reserve boundary regression.'}
    foreach ($profile in @('Fast-v1','Exhaustive-v1')) {
        $s=@(New-ObsBenchSchedule SharedBaseline $themes 47813 -Profile $profile);$records=@{}
        foreach ($arm in $s) {$records[$arm.id]=@{metrics=@{metric=$(if ($arm.condition -eq 'A') {1} else {0})};retention=$false}}
        if (@((Get-ObsSharedScore $s $records @{metric=2}).Values | Where-Object status -ne pass).Count) {throw 'Clean profile score must pass.'}
        $a=@($s | Where-Object condition -eq A)[0]
        $records[$a.immediateB].retention=$true
        if ((Get-ObsSharedScore $s $records @{metric=2})[$a.theme].triggers -notcontains 'retention') {throw 'Profile retention guard removed.'}
        $records[$a.immediateB].retention=$false;$records[$a.beforeB].metrics.metric=-2
        $score=Get-ObsSharedScore $s $records @{metric=2}
        if ($score[$a.theme].triggers -notcontains 'drift' -or $score[$a.theme].pairs[0].conservative.metric -ne 3) {throw 'Profile drift/bracket guard removed.'}
        $records[$a.beforeB].metrics.metric=0;$records[$a.id].metrics.metric=4
        $score=Get-ObsSharedScore $s $records @{metric=2}
        if ($score[$a.theme].triggers -notcontains 'cold-cost' -or $score[$a.theme].triggers -notcontains 'mixed') {throw 'Profile cold-cost/mixed guard removed.'}
    }
    foreach ($metric in @(@{budget=0.5;gross=1.0},@{budget=80.0;gross=120.0})) {
        if ((Get-Verdict @($metric.gross) $metric.budget).verdict -ne 'fail' -or
            (Get-Verdict @($metric.budget) $metric.budget).verdict -ne 'pass' -or
            (Get-Verdict @($null) $metric.budget).verdict -ne 'blocked') {throw 'Calibration must detect gross failure at unchanged thresholds; absent evidence is blocked.'}
    }
    $idle=@{pageNow=0;fillTimer=0;runningAnimations=0;cadenceLogSequence=10;counters=@{ticks=0;fillWrites=1;timeWrites=1}}
    $after=@{pageNow=5000;fillTimer=0;runningAnimations=0;cadenceLogSequence=10;counters=@{ticks=0;fillWrites=1;timeWrites=1}}
    if (-not (Test-DesignerPausedDump $idle $after)) {throw 'Stable structural paused probe rejected.'}
    $after.pageNow=4999
    if (Test-DesignerPausedDump $idle $after) {throw 'Structural paused probe accepted a shortened window.'}
    $after.pageNow=5000
    $after.counters.ticks=1
    if (Test-DesignerPausedDump $idle $after) {throw 'Structural paused probe accepted running work.'}
    $after.counters.ticks=0;$after.runningAnimations=1
    if (Test-DesignerPausedDump $idle $after) {throw 'Structural paused probe accepted animation.'}
    $after.runningAnimations=0;[void]$after.Remove('fillTimer')
    if (Test-DesignerPausedDump $idle $after) {throw 'Structural paused probe accepted missing diagnostics.'}
    'Self-check: Fast/Exhaustive schedules, all 8 themes, balanced pairs, 68+7/13+2/60-minute arithmetic, deadline reserves, unchanged drift/retention guards, calibration thresholds and structural idle PASS'
    $off=@{complete=$true;itemsOff=$true;streams=0;realStreams=0;demand='None';shape='pages:4|renderers:1';expectedShape='pages:4|renderers:1'
        overlayTargets=@();overlayFrames=@();mappedSurvivors=@();unknownRenderers=@();unknownTargets=@();unknownFrames=@()}
    if (@(Get-ObsOffCertificationReasons $off).Count) {throw 'Independently evidenced unowned infrastructure renderer must pass certified-off.'}
    foreach ($mutation in @(
        @{field='overlayTargets';value=@('disabled-source-target')},
        @{field='overlayFrames';value=@('disabled-source-frame')},
        @{field='mappedSurvivors';value=@('123@birth')},
        @{field='unknownRenderers';value=@('456@birth')},
        @{field='unknownTargets';value=@('unattributed-page')},
        @{field='unknownFrames';value=@('unattributed-frame')},
        @{field='complete';value=$false},@{field='itemsOff';value=$false},
        @{field='streams';value=1},@{field='realStreams';value=1},
        @{field='demand';value='Overlay'},@{field='demand';value=$null},
        @{field='shape';value='pages:5|renderers:2'})) {
        $bad=$off.Clone();$bad[$mutation.field]=$mutation.value
        if (-not @(Get-ObsOffCertificationReasons $bad).Count) {throw "Certified-off accepted $($mutation.field)."}
    }
    if ((Get-ObsPairedDiagnostic (Get-Verdict @(0.404,1.719) 0.5)) -ne 'mixed paired values' -or
        (Get-ObsPairedDiagnostic (Get-Verdict @($null) 0.5)) -ne 'missing paired values') {throw 'Mixed paired CPU values must not be reported as missing.'}
    if (-not (Test-ObsFixturePosition 305 305 14400) -or -not (Test-ObsFixturePosition 605 605 14400) -or
        (Test-ObsFixturePosition 677 298 14400) -or (Test-ObsFixturePosition 305 305 1800) -or
        (Test-ObsFixturePosition 14200 14200 14400 -RemainingSeconds 150)) {throw 'Long fixture hidden-boundary/wrap freshness or full-arm age guard changed.'}
    $rootCreated=[datetime]'2026-10-05T00:00:00Z'
    $processes=@(
        @{pid=10;parent=1;created='2026-10-05T00:00:00Z'},
        @{pid=20;parent=10;created='2026-10-05T00:00:01Z'},
        @{pid=30;parent=20;created='2026-10-05T00:00:02Z'},
        @{pid=40;parent=99;created='2026-10-05T00:00:02Z'})
    $rootChain=Get-ObsDebugOwnerChain 10 10 $rootCreated $processes
    $childChain=Get-ObsDebugOwnerChain 30 10 $rootCreated $processes
    if (-not $rootChain -or -not $childChain -or $rootChain.Count -ne 1 -or
        $childChain.Count -ne 3) {throw 'Owned OBS root/CEF descendant listener rejected.'}
    if ($null -ne (Get-ObsDebugOwnerChain 40 10 $rootCreated $processes) -or
        $null -ne (Get-ObsDebugOwnerChain 30 10 $rootCreated.AddSeconds(1) $processes)) {throw 'Foreign listener or recycled OBS identity accepted.'}
    foreach ($mutation in @(
        @{parent=10;created='2026-10-05T00:00:03Z'},
        @{parent=30;created='2026-10-05T00:00:01Z'},
        @{parent=10;created=$null})) {
        $bad=@($processes | ForEach-Object {$_.Clone()})
        $bad[1].parent=$mutation.parent;$bad[1].created=$mutation.created
        if ($null -ne (Get-ObsDebugOwnerChain 30 10 $rootCreated $bad)) {throw 'Invalid/missing parent-birth chain accepted.'}
    }
    'Self-check: listener owned root/descendant chain passes; foreign/recycled roots, cycles, impossible birth order and missing creation identity BLOCK PASS'
    if ((Get-ObsCefBaselineState @(@{pid=10;name='obs64.exe'})) -ne 'cef-not-started' -or
        (Get-ObsCefBaselineState @(@{pid=10;name='obs64.exe'},@{pid=20;name='obs-browser-page.exe'})) -ne 'cef-processes-present') {
        throw 'Lazy CEF baseline must distinguish zero browser children from initialized browser infrastructure.'
    }
    $empty=@{before=@();after=@();tracedTargets=@();markerTargets=@();changedDuringCapture=$false}
    $page=@{before=@('p1');after=@('p1');tracedTargets=@('p1');markerTargets=@('p1');changedDuringCapture=$false}
    if (@(Get-ObsTargetCensusReasons $empty).Count -or @(Get-ObsTargetCensusReasons $page).Count) {throw 'Complete empty/page-bound CDP census rejected.'}
    foreach ($mutation in @(
        @{field='after';value=@('p2')},
        @{field='markerTargets';value=@()},
        @{field='changedDuringCapture';value=$true})) {
        $bad=$page.Clone();$bad[$mutation.field]=$mutation.value
        if (-not @(Get-ObsTargetCensusReasons $bad).Count) {throw 'Incomplete/changing page CDP inventory accepted.'}
    }
    $old=@{pid=100;created='2026-10-05T00:00:01Z';key='100@2026-10-05T00:00:01Z';slot='slot0'}
    $replacement=@{pid=200;created='2026-10-05T00:00:03Z';key='200@2026-10-05T00:00:03Z'}
    $active=@{complete=$true;census=$page;renderersBefore=@($old,$replacement);renderers=@($old,$replacement)
        cdpRenderersBefore=@(100,200);cdpRenderers=@(100,200)
        targets=@(@{id='p1';role='overlay'});frames=@(@{id='f1';role='overlay'})
        traceFrames=@(@{id='f1';role='overlay';key=$old.key})}
    $generation=@{consumed=$old;mapping=@{key=$old.key;look='bench000';phase='active-pill'}
        candidate=$replacement;active=$active;activationStartUtc='2026-10-05T00:00:02Z'
        activationEndUtc='2026-10-05T00:00:04Z';beforeKeys=@($old.key)}
    $closed=@{complete=$true;census=$empty;renderersBefore=@($replacement);renderers=@($replacement)
        cdpRenderersBefore=@(200);cdpRenderers=@(200);targets=@();frames=@();traceFrames=@()}
    if (@(Get-ObsRendererGenerationReasons $generation $closed @($old.key) 1).Count) {
        throw 'Consumed spare replacement born before overlay exit must pass with complete active/off ownership evidence.'
    }
    foreach ($mutation in @('mapped-survivor','missing-census','changed-census','extra-slot','no-consumption','pid-reuse','replacement-mapped','unrelated-target','inventory-mismatch','late-birth')) {
        $g=$generation | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $b=$closed | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        $mapped=@($old.key)
        switch ($mutation) {
            'mapped-survivor' {$b.renderers+=@($old);$b.renderersBefore+=@($old);$b.cdpRenderers+=100;$b.cdpRenderersBefore+=100}
            'missing-census' {[void]$g.active.Remove('census')}
            'changed-census' {$g.active.census.after=@('p2')}
            'extra-slot' {$b.renderers+=@(@{pid=300;created='2026-10-05T00:00:03Z';key='300@birth'})}
            'no-consumption' {$g.mapping.key='999@unowned'}
            'pid-reuse' {$g.candidate.pid=100}
            'replacement-mapped' {$mapped+=@($replacement.key)}
            'unrelated-target' {$g.active.targets+=@(@{id='foreign';role='unowned'})}
            'inventory-mismatch' {$g.active.cdpRenderers=@(100)}
            'late-birth' {$g.activationEndUtc='2026-10-05T00:00:02Z'}
        }
        if (-not @(Get-ObsRendererGenerationReasons $g $b $mapped 1).Count) {throw "Consumed-spare certificate accepted $mutation."}
    }
    # A certified replacement can itself be consumed, but former membership never
    # exempts it from the irrevocable overlay-mapped survivor rule.
    $next=@{pid=300;created='2026-10-05T00:00:06Z';key='300@2026-10-05T00:00:06Z'}
    $second=$generation | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $second.consumed=$replacement.Clone();$second.consumed.slot='slot0';$second.mapping.key=$replacement.key
    $second.candidate=$next;$second.beforeKeys=@($replacement.key)
    $second.activationStartUtc='2026-10-05T00:00:05Z';$second.activationEndUtc='2026-10-05T00:00:07Z'
    $second.active.renderersBefore=@($replacement,$next);$second.active.renderers=@($replacement,$next)
    $second.active.cdpRenderersBefore=@(200,300);$second.active.cdpRenderers=@(200,300);$second.active.traceFrames[0].key=$replacement.key
    $secondOff=$closed.Clone();$secondOff.renderersBefore=@($next);$secondOff.renderers=@($next)
    $secondOff.cdpRenderersBefore=@(300);$secondOff.cdpRenderers=@(300)
    if (@(Get-ObsRendererGenerationReasons $second $secondOff @($old.key,$replacement.key) 1).Count) {throw 'Second consumed-spare generation rejected.'}
    'Self-check: two consumed-spare generations pass, including birth before overlay exit; mapped survivors, missing/changing census, extra slot, no chain, PID reuse, later mapping and unknown ownership BLOCK PASS'
    'Self-check: certified off allows evidenced infrastructure only; disabled target/frame, mapped survivor, unknown ownership, missing inventory, shape drift and demand fail; long clock freshness and mixed/missing diagnostics PASS'
}
function Test-DesignerGpuInfo {
    . (Join-Path $PSScriptRoot 'obs-overlay-bench-runtime.ps1')
    $birth=ConvertTo-ObsBenchUtc '2026-10-05T00:00:00Z'
    $knownCreated=ConvertTo-ObsBenchUtc '2026-10-05T15:46:45.156368Z'
    $knownEvent=ConvertTo-ObsBenchUtc '2026-10-05T15:46:46.736298Z'
    if ([Math]::Abs(($knownEvent-$knownCreated).TotalSeconds-1.579930) -gt 0.000001 -or
        -not (Test-DesignerTraceBirth $knownCreated $knownEvent $birth) -or
        -not (Test-DesignerTraceBirth $birth $birth.AddSeconds(5) $birth) -or
        (Test-DesignerTraceBirth $birth $birth.AddSeconds(5.000001) $birth) -or
        (Test-DesignerTraceBirth $birth $birth.AddTicks(-1) $birth) -or
        (Test-DesignerTraceBirth $birth $birth.AddSeconds(1) $birth.AddTicks(1))) {throw 'Process birth event latency bounds changed.'}
    $initial=Get-DesignerStartupGateMath $birth $birth.AddSeconds(66) 10
    $local=Get-DesignerStartupGateMath '2026-10-05T08:00:00+08:00' $birth.AddSeconds(66).ToLocalTime() 10
    if ($initial.waitSeconds -ne 44 -or $initial.browserAgeSeconds -ne 66 -or
        $initial.settleSeconds -ne 30 -or $initial.projectedMeasureAgeSeconds -ne 150 -or
        $local.waitSeconds -ne $initial.waitSeconds -or
        -not (Test-ObsDesignerDeadlineFits 66000 3600000 1000 ($initial.waitSeconds+210) 20)) {throw 'UTC/local gate math or wait-counting deadline regression.'}
    foreach ($switchSeconds in @(0,2.446,10,35,130)) {
        $afterSwitch=$birth.AddSeconds(66+$initial.waitSeconds+$switchSeconds)
        $remaining=Get-DesignerStartupGateMath $birth $afterSwitch 0
        $settleStartAge=66+$initial.waitSeconds+$switchSeconds+$remaining.waitSeconds
        if ($settleStartAge+30 -lt 150 -or $remaining.settleSeconds -ne 30 -or
            ($switchSeconds -lt 10 -and $remaining.waitSeconds -le 0) -or
            ($switchSeconds -ge 10 -and $remaining.waitSeconds -ne 0)) {throw 'Switch duration must be rechecked; extra wait belongs before the exact 30s settle.'}
    }
    if ((Get-DesignerStartupGateMath $birth $birth.AddSeconds(120) 0).waitSeconds -ne 0 -or
        (Get-DesignerStartupGateMath $birth $birth.AddSeconds(165) 10).waitSeconds -ne 0 -or
        (Get-DesignerAdmissionSeconds 300 $true) -ne 310 -or
        (Get-DesignerAdmissionSeconds 150 $true) -ne 160 -or
        (Get-DesignerAdmissionSeconds 300 $false) -ne 360 -or
        (Get-DesignerAdmissionSeconds 150 $false) -ne 210 -or
        -not (Test-ObsDesignerDeadlineFits 3269 3600 1 (Get-DesignerAdmissionSeconds 300 $true) 20) -or
        (Test-ObsDesignerDeadlineFits 3270 3600 1 (Get-DesignerAdmissionSeconds 300 $true) 20) -or
        -not (Test-ObsDesignerDeadlineFits 3219 3600 1 (Get-DesignerAdmissionSeconds 300 $false) 20) -or
        (Test-ObsDesignerDeadlineFits 3220 3600 1 (Get-DesignerAdmissionSeconds 300 $false) 20)) {throw 'Calibration-only 10s switching +20s cleanup, unchanged anchor reserves, or fail-closed deadline boundary changed.'}
    $flags='--type=gpu-process --disable-gpu-sandbox --use-gl=disabled --gpu-vendor-id=4098 --gpu-device-id=30032'
    if (-not (Test-DesignerGpuCollector $flags) -or (Test-DesignerGpuCollector '--type=gpu-process --use-gl=angle')) {throw 'Informational collector identity must remain positive, not count/order.'}
    # Ignored DX switch: delayed collector exits in settle, never exempted.
    $collector=@{key='20@birth';created=$birth.AddSeconds(121).ToString('o');exitUtc=$birth.AddSeconds(124).ToString('o');commandLine=$flags}
    $events=@(Get-DesignerCollectorWindowEvents @($collector) $birth.AddSeconds(120) $birth.AddSeconds(270))
    if ($events.Count -ne 1 -or -not $events[0].exitInside -or
        @(Get-ObsArmExitReasons @($events | Where-Object exitInside)).Count -ne 1 -or
        @(Get-ObsArmExitReasons @()).Count) {throw 'Ignored-switch collector exit inside settle/measure must still invalidate.'}
    $switchExit=$collector.Clone();$switchExit.created=$birth.AddSeconds(111).ToString('o');$switchExit.exitUtc=$birth.AddSeconds(115).ToString('o')
    if (@(Get-DesignerCollectorWindowEvents @($switchExit) $birth.AddSeconds(120) $birth.AddSeconds(270)).Count) {throw 'Excluded switch exit must remain outside arm trace/windows.'}
    $queue=[Collections.Concurrent.ConcurrentQueue[object]]::new()
    $queue.Enqueue(@{kind='birth';process=@{key='10@birth';created=$birth.ToString('o');commandLine='msedgewebview2.exe --no-delay-for-dx12-vulkan-info-collection';parentKey=$null}})
    $queue.Enqueue(@{kind='birth';process=@{key='20@trace';created=$null;commandLine=$null;parentKey='10@birth';traceBirthUtc=$birth.AddSeconds(121).ToString('o');exitUtc=$null}})
    $queue.Enqueue(@{kind='exit';key='20@trace';utc=$birth.AddSeconds(124).ToString('o')})
    $ctx=@{GpuTrace=@{state=@{rows=$queue;stop=$false};handle=@{IsCompleted=$false};processes=@{};failed=$false}
        Record=@{gpuInfo=@{browsers=@();browserChildren=@();collectors=@();effectiveBrowserArguments=@()}}}
    Update-DesignerGpuTrace $ctx
    if ($ctx.Record.gpuInfo.browsers.Count -ne 1 -or $ctx.Record.gpuInfo.browserChildren.Count -ne 1 -or
        -not $ctx.Record.gpuInfo.browserChildren[0].exitUtc -or $ctx.Record.gpuInfo.collectors.Count) {throw 'Short-lived trace-only child must stay informational, not become browser/collector proof.'}
    'Self-check: UTC/local startup-age wait, fast/long switch recheck before exact 30s settle, measurement age >=150s; ignored-switch settle exits invalidate, switch exits excluded; calibration-only 10+20 reserve and unchanged anchors/deadline boundaries PASS'
}

function Test-ObsBenchSchedule {
    $themes = @('pill','matte','matte-light','standard','classic','simple','album-art','card')
    $s = @(New-ObsBenchSchedule -Protocol SharedBaseline -Themes $themes -Seed 47813)
    if ($s.Count -ne 50 -or $s[0].id -ne 'B0' -or $s[-1].id -ne 'B_end') { throw 'Shared schedule needs 50 arms and endpoint baselines.' }
    if (@($s | Where-Object condition -eq A).Count -ne 32 -or @($s | Where-Object condition -eq B).Count -ne 18) { throw 'Shared schedule arithmetic mismatch.' }
    foreach ($theme in $themes) {
        $a = @($s | Where-Object theme -eq $theme)
        if ($a.Count -ne 4) { throw "Four pairs required for $theme." }
        foreach ($arm in $a) {
            $i = [array]::IndexOf($s, $arm)
            $b = @($s | Where-Object id -eq $arm.immediateB)[0]
            if ([Math]::Abs([array]::IndexOf($s,$b) - $i) -ne 1) { throw 'Immediate B must be adjacent.' }
            if (-not $arm.beforeB -or -not $arm.afterB) { throw 'Every A needs brackets.' }
        }
    }
    $r1 = @($s | Where-Object { $_.round -eq 1 -and $_.condition -eq 'A' } | ForEach-Object theme)
    $r2 = @($s | Where-Object { $_.round -eq 2 -and $_.condition -eq 'A' } | ForEach-Object theme)
    [array]::Reverse($r1)
    if (($r1 -join ',') -ne ($r2 -join ',')) { throw 'Round 2 must reverse round 1.' }
    $standard = @(New-ObsBenchSchedule -Protocol Standard -Themes @('pill') -Seed 1)
    if ($standard.Count -ne 8 -or (($standard.condition -join '') -ne 'ABBAABBA')) { throw 'Standard block must be four AB/BA pairs.' }
    if ((50 * 150 + 180) / 60 -ne 128) { throw 'Playing window arithmetic changed.' }
    if ((8 * 150 + 180) / 60 -ne 23) { throw 'Standard window arithmetic changed.' }
    # Bracket optimism, drift, cold-cost and retention are independent triggers.
    $records = @{}
    foreach ($arm in $s) { $records[$arm.id] = @{ metrics = @{ metric = 0 }; retention = $false } }
    foreach ($arm in @($s | Where-Object condition -eq A)) { $records[$arm.id].metrics.metric = 1 }
    $score = Get-ObsSharedScore $s $records @{metric=2}
    if (@($score.Values | Where-Object { $_.status -ne 'pass' }).Count) { throw 'Clean shared score must pass.' }
    $first = @($s | Where-Object { $_.condition -eq 'A' })[0]
    $records[$first.immediateB].retention = $true
    $score = Get-ObsSharedScore $s $records @{metric=2}
    if ($score[$first.theme].triggers -notcontains 'retention') { throw 'Retention must trigger a fresh block.' }
    $records[$first.immediateB].retention = $false
    $records[$first.beforeB].metrics.metric = -2
    $score = Get-ObsSharedScore $s $records @{metric=2}
    if ($score[$first.theme].triggers -notcontains 'drift' -or $score[$first.theme].pairs[0].conservative.metric -ne 3) { throw 'Conservative low-baseline bracket and drift regression.' }
    $records[$first.beforeB].metrics.metric = 0
    $records[$first.id].metrics.metric = 4
    $score = Get-ObsSharedScore $s $records @{metric=2}
    if ($score[$first.theme].triggers -notcontains 'cold-cost' -or $score[$first.theme].triggers -notcontains 'mixed') { throw 'Cold cost and mixed observations require a fresh block.' }
    foreach ($path in @('obs-overlay-bench.ps1','obs-overlay-bench-protocol.ps1','obs-overlay-bench-selfcheck.ps1','obs-overlay-bench-runtime.ps1','obs-portable.ps1','obs-overlay-obs-e2e.ps1')) {
        $tokens=$null;$parseErrors=$null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $path),[ref]$tokens,[ref]$parseErrors)
        if ($parseErrors.Count) {throw "$path parse errors: $($parseErrors.Message -join '; ')"}
    }
    Test-ObsBenchWorst
    Test-ObsBenchComposedAdmission
    Test-ObsBenchProfiles
    Test-DesignerGpuInfo
    'Self-check: schedule, arithmetic, endpoints, adjacency, brackets, reversal, 4 pairs, drift/cold-cost/retention/mixed and script parse PASS'
}
