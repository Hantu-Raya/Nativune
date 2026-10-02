# Full-length OBS designer protocol v5 §7.3/7.4. This file has no top-level side effects.
function New-ObsBenchSchedule {
    param([ValidateSet('Standard','SharedBaseline')] [string] $Protocol, [string[]] $Themes, [int] $Seed)
    $out = [Collections.Generic.List[object]]::new()
    if ($Protocol -eq 'Standard') {
        if ($Themes.Count -ne 1) { throw 'A standard block measures exactly one configuration.' }
        for ($p=1; $p -le 4; $p++) {
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
        for ($r=1; $r -le 4; $r++) {
            $o=$rounds[$r-1]
            for ($q=0; $q -lt 4; $q++) {
                $b="r$r-q$q-B"
                $out.Add([pscustomobject]@{id="r$r-q$q-A1";condition='A';theme=$o[2*$q];round=$r;pair=$r;immediateB=$b;beforeB=$null;afterB=$null})
                $out.Add([pscustomobject]@{id=$b;condition='B';theme=$null;round=$r;pair=$r;immediateB=$null;beforeB=$null;afterB=$null})
                $out.Add([pscustomobject]@{id="r$r-q$q-A2";condition='A';theme=$o[2*$q+1];round=$r;pair=$r;immediateB=$b;beforeB=$null;afterB=$null})
            }
        }
        $out.Add([pscustomobject]@{id='B_end';condition='B';theme=$null;round=5;pair=0;immediateB=$null;beforeB=$null;afterB=$null})
        for ($i=0; $i -lt $out.Count; $i++) {
            if ($out[$i].condition -ne 'A') { continue }
            for ($j=$i-1; $j -ge 0; $j--) { if ($out[$j].condition -eq 'B') { $out[$i].beforeB=$out[$j].id; break } }
            for ($j=$i+1; $j -lt $out.Count; $j++) { if ($out[$j].condition -eq 'B') { $out[$i].afterB=$out[$j].id; break } }
        }
    }
    $out.ToArray()
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
function Read-ObsFramesWorst([string]$Path) {
    $data=Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json -AsHashtable -Depth 32
    if ($data.version -ne 1 -or -not $data.worst -or -not $data.worst.options) {throw 'frames-worst.json requires version:1 and worst:{theme,width,scale,options,source:{w,h}}.'}
    $w=$data.worst; $o=$w.options
    [void](New-ObsBenchOptions $w.theme $w.width $w.scale)
    if ($o.theme -ne $w.theme -or $o.width -ne $w.width -or $o.scale -ne $w.scale) {throw 'Worst options disagree with configuration.'}
    $size=Get-ObsBenchSourceSize $o
    if ($size.w -ne $w.source.w -or $size.h -ne $w.source.h) {throw 'Worst source size disagrees with canonical geometry.'}
    $data
}
