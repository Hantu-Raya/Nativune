# Full-length OBS designer protocol v5 §7.3/7.4. This file has no top-level side effects.
# §7.4 certified off: all eight items disabled, zero streams/realStreams/demand,
# zero Overlay reads throughout B settle/measure, no overlay CDP target/frame or
# live PID@creation ever mapped to an overlay. Infrastructure is a certified
# replaceable renderer slot, with recorded consumed-spare generations, not a
# lifetime PID whitelist. Unknown targetless renderers are never inferred safe.
# Zero pre-scene browser children records cef-not-started, NOT a CDP certificate.
# Listener ownership is loopback plus a live parent/birth chain to the owned OBS.
# Unknown attribution still BLOCKS; a mapped survivor can never be reclassified.
# shape0 equality is required at every B pre/post including B0 and B_end.
# Attribution traces are drained outside scored windows; all descendants remain
# in resource totals. -AttributionOnly runs the same bounded warm-up oracle only.
# Chromium's browser target has no WebContents. Each enumerated page therefore
# needs its own drained trace/frame marker; an empty off-state uses matching
# complete before/after Target.getTargets censuses, not a fabricated marker.
# All eight inputs receive bounded unscored show/hide bootstrap transitions,
# with every live page mapped before each hide, before exact-one warm-up visits.
# The ordinary warm-up remains 15 s per look, >=180 s excluding bootstrap.
# Only then certify infrastructure and shape0; every mapped overlay PID@creation
# must be gone, even with no remaining target.
function New-ObsBenchSchedule {
    param([ValidateSet('Standard','SharedBaseline')] [string] $Protocol, [string[]] $Themes, [int] $Seed,
        [ValidateSet('Fast-v1','Exhaustive-v1')] [string] $Profile = 'Exhaustive-v1')
    $pairCount = if ($Profile -eq 'Fast-v1') {2} else {4}
    $out = [Collections.Generic.List[object]]::new()
    if ($Protocol -eq 'Standard') {
        if ($Themes.Count -ne 1) { throw 'A standard block measures exactly one configuration.' }
        for ($p=1; $p -le $pairCount; $p++) {
            foreach ($c in $(if ($p % 2) { @('A','B') } else { @('B','A') })) {
                $out.Add([pscustomobject]@{id="p$p$c";condition=$c;theme=$(if ($c -eq 'A') {$Themes[0]} else {$null});round=$p;pair=$p;immediateB="p${p}B";beforeB=$null;afterB=$null})
            }
        }
    } else {
        if ($Themes.Count -ne 8 -or @($Themes | Select-Object -Unique).Count -ne 8) { throw 'SharedBaseline requires all eight distinct themes.' }
        $order = @($Themes); $rng = [Random]::new($Seed)
        for ($i=$order.Count-1; $i -gt 0; $i--) { $j=$rng.Next($i+1); $t=$order[$i]; $order[$i]=$order[$j]; $order[$j]=$t }
        $reverse = @($order); [array]::Reverse($reverse)
        # Rotate four two-look quartets by two (A B A is one quartet in plan terminology).
        $rotate = @($order[4..7]) + @($order[0..3]); $reverseRotate = @($rotate); [array]::Reverse($reverseRotate)
        $rounds = @($order,$reverse,$rotate,$reverseRotate)
        $out.Add([pscustomobject]@{id='B0';condition='B';theme=$null;round=0;pair=0;immediateB=$null;beforeB=$null;afterB=$null})
        for ($r=1; $r -le $pairCount; $r++) {
            $o=$rounds[$r-1]
            for ($q=0; $q -lt 4; $q++) {
                $b="r$r-q$q-B"
                $out.Add([pscustomobject]@{id="r$r-q$q-A1";condition='A';theme=$o[2*$q];round=$r;pair=$r;immediateB=$b;beforeB=$null;afterB=$null})
                $out.Add([pscustomobject]@{id=$b;condition='B';theme=$null;round=$r;pair=$r;immediateB=$null;beforeB=$null;afterB=$null})
                $out.Add([pscustomobject]@{id="r$r-q$q-A2";condition='A';theme=$o[2*$q+1];round=$r;pair=$r;immediateB=$b;beforeB=$null;afterB=$null})
            }
        }
        $out.Add([pscustomobject]@{id='B_end';condition='B';theme=$null;round=($pairCount+1);pair=0;immediateB=$null;beforeB=$null;afterB=$null})
        for ($i=0; $i -lt $out.Count; $i++) {
            if ($out[$i].condition -ne 'A') { continue }
            for ($j=$i-1; $j -ge 0; $j--) { if ($out[$j].condition -eq 'B') { $out[$i].beforeB=$out[$j].id; break } }
            for ($j=$i+1; $j -lt $out.Count; $j++) { if ($out[$j].condition -eq 'B') { $out[$i].afterB=$out[$j].id; break } }
        }
    }
    $out.ToArray()
}
function Get-ObsDesignerConditions([ValidateSet('Fast-v1','Exhaustive-v1')] [string] $Profile = 'Exhaustive-v1') {
    if ($Profile -eq 'Fast-v1') {
        return @(
            @{name='sample-playing';kind='sample';sample='playing';worst=$false;lyrics=$false},
            @{name='current-default';kind='current';sample=$null;worst=$false;lyrics=$false},
            @{name='current-max-area';kind='current';sample=$null;worst=$true;lyrics=$false},
            @{name='current-max-area';kind='current';sample=$null;worst=$true;lyrics=$true})
    }
    foreach ($lyrics in @($false,$true)) {
        foreach ($c in @(
            @{name='sample-playing';kind='sample';sample='playing';worst=$false},
            @{name='sample-paused';kind='sample';sample='paused';worst=$false},
            @{name='current';kind='current';sample=$null;worst=$false},
            @{name='max-area';kind='current';sample=$null;worst=$true})) {
            $c.lyrics=$lyrics
            $c
        }
    }
}
function Round3($Value) { if ($null -eq $Value) { $null } else { [Math]::Round([double] $Value, 3) } }
function Get-Verdict($Deltas, [double] $Budget) {
    $v = @($Deltas | Where-Object { $null -ne $_ } | ForEach-Object { [double] $_ })
    if ($v.Count -eq 0) { return @{ verdict = 'blocked'; max = $null; min = $null } }
    $max = ($v | Measure-Object -Maximum).Maximum; $min = ($v | Measure-Object -Minimum).Minimum
    $verdict = if ($max -le $Budget) { 'pass' } elseif ($min -gt $Budget) { 'fail' } else { 'between' }
    @{ verdict = $verdict; max = Round3 $max; min = Round3 $min; n = $v.Count }
}
function Test-ObsDesignerDeadlineFits([double]$NowQpc, [double]$DeadlineQpc, [double]$Frequency,
    [double]$RequiredSeconds, [double]$ReserveSeconds = 20) {
    $NowQpc + ($RequiredSeconds + $ReserveSeconds) * $Frequency -lt $DeadlineQpc
}
function Get-ObsOffCertificationReasons($Evidence) {
    $reasons=[Collections.Generic.List[string]]::new()
    if (-not $Evidence -or $Evidence['complete'] -ne $true) {
        $reasons.Add('off attribution missing or ambiguous')
        return @($reasons)
    }
    if ($Evidence['itemsOff'] -ne $true) {$reasons.Add('off state: all eight items must be disabled')}
    foreach ($field in @('streams','realStreams')) {
        if ($null -eq $Evidence[$field] -or $Evidence[$field] -ne 0) {$reasons.Add("off state: $field must be zero")}
    }
    if ($Evidence['demand'] -cne 'None') {$reasons.Add('off state: demand must be None (zero consumers)')}
    if ($Evidence['shape'] -ne $Evidence['expectedShape']) {$reasons.Add('B shape differs from shape0')}
    if (@($Evidence['overlayTargets']).Count -or @($Evidence['overlayFrames']).Count) {$reasons.Add('off retention: surviving overlay target/frame (disabled sources included)')}
    if (@($Evidence['mappedSurvivors']).Count) {$reasons.Add('off retention: mapped overlay renderer survives without its target')}
    if (@($Evidence['unknownRenderers']).Count) {$reasons.Add('off attribution unknown renderer; BLOCKED')}
    if (@($Evidence['unknownTargets']).Count) {$reasons.Add('off attribution unknown target; BLOCKED')}
    if (@($Evidence['unknownFrames']).Count) {$reasons.Add('off attribution unknown frame; BLOCKED')}
    @($reasons)
}
function Get-ObsTargetCensusReasons($Census) {
    $reasons=[Collections.Generic.List[string]]::new()
    $before=[Collections.Generic.HashSet[string]]::new()
    $after=[Collections.Generic.HashSet[string]]::new()
    foreach ($id in @($Census['before'])) {
        if (-not $id -or -not $before.Add([string]$id)) {$reasons.Add('CDP before-target census missing/ambiguous')}
    }
    foreach ($id in @($Census['after'])) {
        if (-not $id -or -not $after.Add([string]$id)) {$reasons.Add('CDP after-target census missing/ambiguous')}
    }
    if (-not $before.SetEquals($after) -or $Census['changedDuringCapture'] -ne $false) {
        $reasons.Add('CDP target census changed during attribution; BLOCKED')
    }
    foreach ($target in @($Census['tracedTargets'])) {
        if (-not $target -or $target -notin $Census['markerTargets']) {$reasons.Add('Page frame inventory marker missing; attribution BLOCKED')}
    }
    @($reasons | Select-Object -Unique)
}
function Get-ObsRendererCensusReasons($Attribution) {
    $reasons=[Collections.Generic.List[string]]::new()
    if (-not $Attribution -or $Attribution['complete'] -ne $true -or -not $Attribution['census']) {
        return @('Renderer generation missing complete target/frame census; BLOCKED')
    }
    foreach ($reason in @(Get-ObsTargetCensusReasons $Attribution.census)) {$reasons.Add($reason)}
    foreach ($field in @('renderersBefore','renderers','cdpRenderersBefore','cdpRenderers')) {
        if (-not $Attribution.Contains($field)) {$reasons.Add("Renderer generation missing $field census; BLOCKED")}
    }
    $before=@($Attribution['renderersBefore']);$after=@($Attribution['renderers'])
    if (@(Compare-Object @($before | ForEach-Object key) @($after | ForEach-Object key)).Count -or
        @(Compare-Object @($before | ForEach-Object pid) @($Attribution['cdpRenderersBefore'])).Count -or
        @(Compare-Object @($after | ForEach-Object pid) @($Attribution['cdpRenderers'])).Count) {
        $reasons.Add('Renderer generation OS/CDP inventories changed or disagree; BLOCKED')
    }
    foreach ($p in $after) {
        if (-not $p.created -or $p.key -cne "$($p.pid)@$($p.created)" -or
            @($after | Where-Object pid -eq $p.pid).Count -ne 1) {$reasons.Add('Renderer generation missing/reused birth identity; BLOCKED')}
    }
    @($reasons | Select-Object -Unique)
}
function Get-ObsRendererGenerationReasons($Generation,$Off,$OverlayKeys,[int]$SlotCount) {
    $reasons=[Collections.Generic.List[string]]::new()
    if (-not $Generation) {return @('Renderer generation missing consumed-spare chain; BLOCKED')}
    foreach ($row in @($Generation['active'],$Off)) {
        foreach ($reason in @(Get-ObsRendererCensusReasons $row)) {$reasons.Add($reason)}
    }
    $old=$Generation['consumed'];$candidate=$Generation['candidate'];$active=$Generation['active']
    if (-not $old -or -not $candidate -or -not $old['slot'] -or
        $Generation['mapping']['key'] -cne $old['key'] -or $old['key'] -notin $OverlayKeys -or
        $old['key'] -notin $Generation['beforeKeys'] -or $candidate['key'] -in $Generation['beforeKeys'] -or
        $old['key'] -notin @($active['traceFrames'] | Where-Object role -eq overlay | ForEach-Object key)) {
        $reasons.Add('Renderer generation missing positive certified-spare consumption; BLOCKED')
    }
    $born=[datetime]::MinValue;$start=[datetime]::MinValue;$end=[datetime]::MinValue
    if (-not [datetime]::TryParse([string]$candidate['created'],[ref]$born) -or
        -not [datetime]::TryParse([string]$Generation['activationStartUtc'],[ref]$start) -or
        -not [datetime]::TryParse([string]$Generation['activationEndUtc'],[ref]$end) -or
        $born -lt $start -or $born -gt $end -or $candidate['pid'] -eq $old['pid'] -or
        $candidate['key'] -cne "$($candidate['pid'])@$($candidate['created'])" -or
        $candidate['key'] -notin @($active['renderers'] | ForEach-Object key)) {
        $reasons.Add('Renderer generation candidate missing valid activation birth identity; BLOCKED')
    }
    if ($candidate['key'] -in $OverlayKeys -or
        @($active['traceFrames'] | Where-Object key -eq $candidate['key']).Count) {
        $reasons.Add('Renderer generation candidate has frame ownership; BLOCKED')
    }
    if (@($active['targets'] | Where-Object role -ne overlay).Count -or
        @($active['frames'] | Where-Object role -ne overlay).Count -or
        @($active['traceFrames'] | Where-Object role -ne overlay).Count) {$reasons.Add('Renderer generation unknown active ownership; BLOCKED')}
    foreach ($frame in @($active['frames'])) {
        if (-not @($active['traceFrames'] | Where-Object {$_.id -eq $frame.id -and $_.role -eq 'overlay' -and $_.key}).Count) {
            $reasons.Add('Renderer generation active frame unmapped; BLOCKED')
        }
    }
    if (@($Off['targets']).Count -or @($Off['frames']).Count -or @($Off['traceFrames']).Count -or
        @($Off['renderers'] | Where-Object {$_.key -in $OverlayKeys}).Count) {
        $reasons.Add('off retention: renderer generation still has mapped ownership')
    }
    if (@($Off['renderers']).Count -ne $SlotCount -or
        @($Off['renderers'] | Where-Object key -eq $candidate['key']).Count -ne 1) {$reasons.Add('Renderer generation does not fit certified slots; BLOCKED')}
    @($reasons | Select-Object -Unique)
}
function Get-ObsPairedDiagnostic($Verdict) {
    if ($Verdict.verdict -eq 'between') {'mixed paired values'}
    else {'missing paired values'}
}
function Test-ObsFixturePosition([double]$Age, $Position, $Duration,
    [double]$TrackSeconds = 14400, [double]$Tolerance = 5, [double]$RemainingSeconds = 0) {
    $null -ne $Position -and $null -ne $Duration -and
        [double]::IsFinite([double]$Position) -and [double]::IsFinite([double]$Duration) -and
        [Math]::Abs([double]$Position-$Age) -le $Tolerance -and
        [double]$Duration -ge $TrackSeconds -and $Age+$RemainingSeconds -le [double]$Duration-60
}
function Get-ObsSharedScore($Schedule, $Records, $Budgets) {
    $result=[ordered]@{}
    foreach ($theme in @($Schedule | Where-Object condition -eq A | ForEach-Object theme | Select-Object -Unique)) {
        $aa=@($Schedule | Where-Object theme -eq $theme); $pairs=@(); $triggers=[Collections.Generic.HashSet[string]]::new(); $metrics=[ordered]@{}
        foreach ($a in $aa) {
            $record=$Records[$a.id]; $ib=$Records[$a.immediateB]; $bb=$Records[$a.beforeB]; $ab=$Records[$a.afterB]
            $immediate=[ordered]@{}; $conservative=[ordered]@{}; $bracket=[ordered]@{}
            foreach ($m in $Budgets.Keys) {
                $av=$record.metrics[$m]; $iv=$ib.metrics[$m]; $bv=$bb.metrics[$m]; $ev=$ab.metrics[$m]
                if ($null -eq $av -or $null -eq $iv -or $null -eq $bv -or $null -eq $ev) { throw "Missing metric $m for $($a.id)." }
                $immediate[$m]=[double]$av-[double]$iv
                $bracket[$m]=[double]$av-[Math]::Min([double]$bv,[double]$ev)
                $conservative[$m]=[Math]::Max($immediate[$m],$bracket[$m])
                if ([Math]::Abs([double]$bv-[double]$ev) -gt $Budgets[$m]/2) { [void]$triggers.Add('drift') }
            }
            if ($ib.retention -or $bb.retention -or $ab.retention) { [void]$triggers.Add('retention') }
            $pairs+= [ordered]@{a=$a.id;b=$a.immediateB;beforeB=$a.beforeB;afterB=$a.afterB;immediate=$immediate;bracket=$bracket;conservative=$conservative}
        }
        $status='pass'
        foreach ($m in $Budgets.Keys) {
            $later=@($aa | Select-Object -Skip 1 | ForEach-Object {$Records[$_.id].metrics[$m]})
            $laterMean=($later | Measure-Object -Average).Average
            if ([double]$Records[$aa[0].id].metrics[$m]-$laterMean -gt $Budgets[$m]/2) { [void]$triggers.Add('cold-cost') }
            $max=($pairs | ForEach-Object {$_.conservative[$m]} | Measure-Object -Maximum).Maximum
            $min=($pairs | ForEach-Object {$_.immediate[$m]} | Measure-Object -Minimum).Minimum
            $v=if ($max -le $Budgets[$m]) {'pass'} elseif ($min -gt $Budgets[$m]) {'fail'} else {'mixed'}
            $metrics[$m]=@{status=$v;largestConservative=$max;smallestImmediate=$min;budget=$Budgets[$m]}
            if ($v -eq 'mixed') { [void]$triggers.Add('mixed'); if ($status -ne 'fail') {$status='mixed'} }
            if ($v -eq 'fail') {$status='fail'}
        }
        if ($triggers.Count) {$status='fresh-block-required'}
        $result[$theme]=@{status=$status;pairs=$pairs;metrics=$metrics;triggers=@($triggers);fallback=@{protocol='Standard';look=$theme;pairs=4;timeBoxMinutes=30;approvalRequired=$true}}
    }
    $result
}
function Get-ObsBenchSourceSize($Options) {
    $k=[double]$Options.scale/100; $w=[int]$Options.width; $theme=$Options.theme
    $h=switch ($theme) {
        'pill' {56*$k}
        'album-art' {$w}
        'card' {
            $t=if (-not $Options.showProgress) {56*$k} elseif (-not $Options.showTimes) {72*$k} else {96*$k}
            if (-not $Options.showArtist) {$t-=20*$k}
            $(if ($Options.showArt) {$w-32*$k} else {0}) + 16*$k + $t
        }
        default {80*$k}
    }
    @{w=[int](2*[Math]::Ceiling(($w+40)/2));h=[int](2*[Math]::Ceiling(($h+40)/2))}
}
function New-ObsBenchOptions([string]$Theme, [int]$Width=0, [int]$Scale=100) {
    $baseMin=switch ($Theme) {'pill' {320};'album-art' {160};'card' {200};default {360}}
    $baseMax=switch ($Theme) {'pill' {800};'album-art' {600};'card' {600};default {1200}}
    $default=switch ($Theme) {'pill' {400};'album-art' {200};'card' {280};default {440}}
    $min=[int](10*[Math]::Ceiling($baseMin*[Math]::Max($Scale/100,1)/10))
    if (-not $Width) {$Width=[int](10*[Math]::Round([Math]::Clamp($default,$min,$baseMax)/10))}
    if ($Scale -lt 50 -or $Scale -gt 200 -or $Scale%5 -or $Width -lt $min -or $Width -gt $baseMax -or $Width%10) {throw 'Width/Scale outside the dependent configuration range.'}
    @{theme=$Theme;width=$Width;scale=$Scale;align=$(if ($Theme -eq 'pill') {'center'} else {'left'});font=$null;colours='auto';text=$(if ($Theme -eq 'matte-light') {'#141414'} else {'#ffffff'});background=$(switch ($Theme) {'matte' {'#1c1c1e'};'matte-light' {'#f5f5f7'};'album-art' {'#000000'};default {'#1a1a1a'}});backgroundOpacity=$(if ($Theme -eq 'album-art') {80} else {94});accent='#8a8a95';textShadow=($Theme -in @('pill','simple','album-art'));showArt=$true;showArtist=$true;showProgress=$true;showTimes=($Theme -ne 'pill');paused=$(if ($Theme -eq 'pill') {'hide'} else {'dim'});showAnimation='slide-up';hideAnimation='fade'}
}
function Assert-ObsComposedProvenance($Data) {
    $p=$Data['provenance']
    if ($Data['protocol'] -ne 'Fast-v2' -or $p -isnot [Collections.IDictionary] -or
        $p['kind'] -ne 'Fast-v2-composed' -or $p['version'] -isnot [ValueType] -or $p['version'] -is [bool] -or
        $p['version'] -ne 1) {throw 'Composed provenance kind/version/protocol invalid.'}
    foreach ($field in @('profileComplete','complete','qualificationComplete','framesGreen','exhaustiveComplete')) {
        if ($Data[$field] -isnot [bool] -or $Data[$field] -ne $false) {throw "Provisional composed evidence requires ${field}=false."}
    }
    if ($Data['coverageComplete'] -isnot [bool] -or $Data['coverageComplete'] -ne $true) {throw 'Provisional composed evidence requires coverageComplete=true.'}
    if ($Data['missingIds'] -isnot [array] -or $Data['missingIds'].Count) {throw 'Provisional composed evidence requires empty missingIds.'}
    if ($p['payloadIdentical'] -isnot [bool] -or $p['payloadIdentical'] -ne $true -or $p['harnessIdentity'] -ne 'attested' -or
        $p['originalHarnessBytesRetained'] -isnot [bool] -or $p['originalHarnessBytesRetained'] -ne $false) {throw 'Provisional composed payload/harness identity assertion invalid.'}
    if ($p['limitations'] -isnot [array] -or $p['limitations'].Count -eq 0 -or
        @($p['limitations'] | Where-Object {$_ -isnot [string] -or [string]::IsNullOrWhiteSpace($_)}).Count) {throw 'Provisional composed limitations must be non-empty strings.'}
    if ($p['sourceRuns'] -isnot [array] -or $p['sourceRuns'].Count -eq 0) {throw 'Composed provenance requires sourceRuns.'}
    $sources=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($source in $p.sourceRuns) {
        if ($source -isnot [Collections.IDictionary] -or $source['runId'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($source['runId']) -or -not $sources.Add($source['runId'])) {throw 'Composed provenance source run ids must be unique non-empty strings.'}
        foreach ($field in @('manifestSha256','identitySha256','journalSha256','inventorySha256','reportSha256')) {
            if (($field -eq 'manifestSha256' -or $source.Contains($field)) -and
                ($source[$field] -isnot [string] -or $source[$field] -notmatch '^[a-fA-F0-9]{64}$')) {throw "Composed provenance source $field hash invalid."}
        }
    }
    $inventory=$p['inventory']
    if ($inventory -isnot [Collections.IDictionary] -or $inventory['profile'] -ne 'Fast-v2' -or
        $inventory['version'] -isnot [ValueType] -or $inventory['version'] -is [bool] -or $inventory['version'] -lt 1 -or
        -not [double]::IsFinite([double]$inventory['version']) -or
        [Math]::Floor([double]$inventory['version']) -ne $inventory['version'] -or
        $inventory['hash'] -isnot [string] -or $inventory['hash'] -notmatch '^[a-fA-F0-9]{64}$' -or
        $inventory['requiredRowIds'] -isnot [array] -or $inventory['requiredRowIds'].Count -eq 0) {throw 'Composed provenance inventory profile/version/hash/requiredRowIds invalid.'}
    $required=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($id in $inventory.requiredRowIds) {
        if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id) -or -not $required.Add($id)) {throw 'Composed inventory row ids must be unique non-empty strings.'}
    }
    if ($p['selectedRows'] -isnot [array] -or $p['selectedRows'].Count -ne $required.Count) {throw 'Composed selectedRows must exactly cover requiredRowIds.'}
    $selected=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $p.selectedRows) {
        if ($row -isnot [Collections.IDictionary] -or $row['rowId'] -isnot [string] -or -not $required.Contains($row['rowId']) -or
            -not $selected.Add($row['rowId']) -or $row['sourceRun'] -isnot [string] -or -not $sources.Contains($row['sourceRun']) -or
            $row['evidenceSha256'] -isnot [string] -or $row['evidenceSha256'] -notmatch '^[a-fA-F0-9]{64}$') {throw 'Composed selected row id/sourceRun/evidence hash invalid.'}
        if ($row.Contains('resultSha256') -and ($row['resultSha256'] -isnot [string] -or $row['resultSha256'] -notmatch '^[a-fA-F0-9]{64}$')) {throw 'Composed selected row result hash invalid.'}
    }
    if (-not $required.SetEquals($selected)) {throw 'Composed selectedRows must exactly cover requiredRowIds.'}
}
function Get-ObsBenchAdmission($Data) {
    if (-not $Data) {return 'none'}
    if ($Data['provenance'] -is [Collections.IDictionary] -and $Data['provenance']['kind'] -eq 'Fast-v2-composed') {return 'provisional-composed'}
    if ($Data['version'] -eq 1) {return 'legacy-v1-configuration'}
    if ($Data['framesGreen'] -eq $true) {return 'frames-green'}
    'complete-profile'
}
function Assert-ObsFramesWorst($Data, [switch]$Designer,
    [ValidateSet('Fast-v1','Exhaustive-v1')] [string] $Profile = 'Exhaustive-v1') {
    if ($Data -isnot [Collections.IDictionary] -or $Data['version'] -notin @(1,2) -or -not $Data['worst'] -or -not $Data['worst']['options']) {throw 'frames-worst.json requires version:1 or version:2 and worst:{theme,width,scale,options,source:{w,h}}.'}
    if ($Profile -eq 'Fast-v1' -and $Designer -and $Data.version -ne 2) {throw 'Designer Fast-v1 requires complete version:2 evidence or authorized provisional composition.'}
    if ($Data.version -eq 2) {
        if ($Data.version -isnot [ValueType] -or $Data.version -is [bool]) {throw 'frames-worst.json v2 requires a numeric version.'}
        if ($Data['protocol'] -notin @('Fast-v2','Exhaustive-v1')) {throw 'frames-worst.json v2 requires a recognized protocol.'}
        $provisional=$false
        if ($Profile -eq 'Fast-v1' -and $Data.Contains('provenance')) {
            Assert-ObsComposedProvenance $Data
            $provisional=$true
        }
        if (-not $provisional) {
            foreach ($field in @('profileComplete','complete')) {
                if ($Data[$field] -isnot [bool] -or $Data[$field] -ne $true) {throw "frames-worst.json v2 requires ${field}=true."}
            }
            if ($Data['missingIds'] -isnot [array] -or $Data['missingIds'].Count -ne 0) {throw 'frames-worst.json v2 requires an empty missingIds array.'}
        }
        foreach ($field in @('framesGreen','exhaustiveComplete')) {
            if ($Data[$field] -isnot [bool]) {throw "frames-worst.json v2 requires boolean $field."}
        }
        # Fast OBS admits COMPLETE single-run or explicitly authorized provisional composition.
        if (-not $Designer -and $Data.framesGreen -ne $true -and
            -not ($Profile -eq 'Fast-v1' -and $Data.protocol -eq 'Fast-v2')) {throw 'A-FRAMES not certified green.'}
        if (($Data.protocol -eq 'Fast-v2' -and ($Data.framesGreen -or $Data.exhaustiveComplete)) -or
            ($Data.protocol -eq 'Exhaustive-v1' -and (-not $Data.framesGreen -or -not $Data.exhaustiveComplete))) {
            throw 'frames-worst.json v2 certification flags disagree with protocol.'
        }
        $w=$Data.worst; $o=$w.options
        if ($w -isnot [Collections.IDictionary] -or $o -isnot [Collections.IDictionary] -or
            $w['source'] -isnot [Collections.IDictionary]) {throw 'Worst geometry requires options and source objects.'}
        if ($w['theme'] -notin @('pill','matte','matte-light','standard','classic','simple','album-art','card')) {throw 'Worst theme is not recognized.'}
        foreach ($value in @($w['width'],$w['scale'],$o['width'],$o['scale'],$w['source']['w'],$w['source']['h'])) {
            if ($value -isnot [ValueType] -or $value -is [bool] -or
                -not [double]::IsFinite([double]$value) -or $value -le 0 -or [Math]::Floor([double]$value) -ne $value) {
                throw 'Worst geometry requires positive finite integer dimensions and scale.'
            }
        }
        foreach ($field in @('showArt','showArtist','showProgress','showTimes')) {
            if ($o[$field] -isnot [bool]) {throw "Worst geometry option $field must be boolean."}
        }
    }
    # Preserve the established v1 configuration and canonical geometry checks.
    $w=$data.worst; $o=$w.options
    [void](New-ObsBenchOptions $w.theme $w.width $w.scale)
    if ($o.theme -ne $w.theme -or $o.width -ne $w.width -or $o.scale -ne $w.scale) {throw 'Worst options disagree with configuration.'}
    $size=Get-ObsBenchSourceSize $o
    if ($size.w -ne $w.source.w -or $size.h -ne $w.source.h) {throw 'Worst source size disagrees with canonical geometry.'}
    if (-not $Designer -and $Profile -eq 'Fast-v1' -and $Data.version -eq 1 -and $Data.framesGreen -ne $true) {
        throw 'Fast OBS requires COMPLETE version:2 Fast-v2 evidence or framesGreen=true.'
    }
}
function Read-ObsFramesWorst([string]$Path, [switch]$Designer,
    [ValidateSet('Fast-v1','Exhaustive-v1')] [string] $Profile = 'Exhaustive-v1') {
    $data=Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable -Depth 32
    Assert-ObsFramesWorst $data -Designer:$Designer -Profile $Profile
    $data
}
