# Dot-sourced by obs-overlay-e2e.ps1. Estimates never alter measurement windows or predicates.
$script:rowInventoryVersion = 2
$script:requiredRowInventory = @()
$script:completedInventorySections = @{}
$script:frameRotation = $null
$script:priorWorst = $null

function Test-DefaultRowSelectors {
    $script:Section.Count -eq 1 -and $script:Section[0] -ceq '*' -and
    $script:FrameRow.Count -eq 1 -and $script:FrameRow[0] -ceq '*' -and
    $script:LookCase.Count -eq 1 -and $script:LookCase[0] -ceq '*' -and -not $script:Rotation
}
function Test-SectionSelected { param([string] $Section)
    @($script:Section | Where-Object { $Section -like $_ }).Count -gt 0
}
function Test-FrameRowSelected { param([string] $Id)
    @($script:FrameRow | Where-Object { $Id -like $_ }).Count -gt 0
}
function Test-ScenarioSelected { param([string] $Name)
    switch ($Name) {
        'A-LOOK' { return @( 'geometry', 'cadence', 'motion', 'regression', 'text' | Where-Object { Test-SectionSelected $_ }).Count -gt 0 }
        'A-FRAMES' { return Test-SectionSelected 'frames' }
        'A-TEXT' { return Test-SectionSelected 'text' }
        'A-PAUSEVIEW' { return Test-SectionSelected 'pauseview' }
        'A-PLAIN' { return Test-SectionSelected 'plain' }
        'A-PROD' { return Test-SectionSelected 'prod' }
        default { return Test-SectionSelected 'regression' }
    }
}

function Get-FrameTupleKeys($Row, [int] $Strength) {
    $factors = @('theme', 'config', 'showTimes', 'rate', 'condition')
    for ($a = 0; $a -lt $factors.Count; $a++) {
        for ($b = $a + 1; $b -lt $factors.Count; $b++) {
            $pair = "$($factors[$a])=$($Row[$factors[$a]])|$($factors[$b])=$($Row[$factors[$b]])"
            if ($Strength -eq 2) { $pair; continue }
            for ($c = $b + 1; $c -lt $factors.Count; $c++) { "$pair|$($factors[$c])=$($Row[$factors[$c]])" }
        }
    }
}
function Get-FrameRotation([object[]] $PlayingRows) {
    # Fixed seeded tie order; only feasible rows from the exhaustive inventory can be candidates.
    $seed = 20261003
    $random = [Random]::new($seed)
    $candidates = @($PlayingRows)
    for ($i = $candidates.Count - 1; $i -gt 0; $i--) {
        $j = $random.Next($i + 1); $swap = $candidates[$i]; $candidates[$i] = $candidates[$j]; $candidates[$j] = $swap
    }
    $tupleKeys = @{}; $universes = @{}; $uncovered = @{}
    foreach ($strength in @(2, 3)) {
        $universes[$strength] = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($row in $PlayingRows) {
            $keys = @(Get-FrameTupleKeys $row $strength)
            $tupleKeys["$strength/$($row.id)"] = $keys
            foreach ($key in $keys) { [void] $universes[$strength].Add($key) }
        }
        $uncovered[$strength] = [Collections.Generic.HashSet[string]]::new($universes[$strength], [StringComparer]::Ordinal)
    }
    $used = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $slices = [ordered]@{ pairwise = [Collections.Generic.List[object]]::new()
        threeway = [Collections.Generic.List[object]]::new(); rest = [Collections.Generic.List[object]]::new() }
    $afterPairwise = @()
    foreach ($strength in @(2, 3)) {
        $slice = if ($strength -eq 2) { 'pairwise' } else { 'threeway' }
        while ($uncovered[$strength].Count -gt 0) {
            $best = $null; $bestGain = 0
            foreach ($row in $candidates) {
                if ($used.Contains($row.id)) { continue }
                $gain = 0
                foreach ($key in $tupleKeys["$strength/$($row.id)"]) { if ($uncovered[$strength].Contains($key)) { $gain++ } }
                if ($gain -gt $bestGain) { $best = $row; $bestGain = $gain }
            }
            if (-not $best) { throw "Frame rotation cannot cover feasible strength-$strength tuples." }
            [void] $used.Add($best.id); $slices[$slice].Add($best)
            foreach ($s in @(2, 3)) { foreach ($key in $tupleKeys["$s/$($best.id)"]) { [void] $uncovered[$s].Remove($key) } }
        }
        if ($strength -eq 2) { $afterPairwise = @($uncovered[3] | Sort-Object) }
    }
    foreach ($row in $PlayingRows) { if (-not $used.Contains($row.id)) { $slices.rest.Add($row); [void] $used.Add($row.id) } }
    $order = 0
    foreach ($slice in $slices.Keys) {
        foreach ($row in $slices[$slice]) { $row['rotationSlice'] = $slice; $row['rotationOrder'] = $order; $order++ }
    }
    # Independently verify emitted slices against the original feasible universe, not greedy bookkeeping.
    $verification = [ordered]@{}
    foreach ($strength in @(2, 3)) {
        $covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $verificationRows = @($slices.pairwise.ToArray())
        if ($strength -eq 3) { $verificationRows += @($slices.threeway.ToArray()) }
        foreach ($row in $verificationRows) { foreach ($key in @(Get-FrameTupleKeys $row $strength)) { [void] $covered.Add($key) } }
        $missing = @($universes[$strength] | Where-Object { -not $covered.Contains($_) } | Sort-Object)
        if ($missing.Count -gt 0) { throw "Frame rotation verification found $($missing.Count) uncovered strength-$strength tuples." }
        $verification["strength$strength"] = [ordered]@{ feasible = $universes[$strength].Count; covered = $covered.Count; uncovered = $missing }
    }
    if ($used.Count -ne $PlayingRows.Count -or $order -ne $PlayingRows.Count) { throw 'Frame rotation slices do not partition exhaustive Playing rows.' }
    $selectedCovered = @{}
    foreach ($strength in @(2, 3)) {
        $covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $chosen = if ($script:Rotation) { $slices[$script:Rotation].ToArray() } else { $PlayingRows }
        foreach ($row in $chosen) { foreach ($key in @(Get-FrameTupleKeys $row $strength)) { [void] $covered.Add($key) } }
        $selectedCovered["strength$strength"] = @($universes[$strength] | Where-Object { -not $covered.Contains($_) } | Sort-Object)
    }
    [ordered]@{ generator = 'seeded-feasible-greedy-v1'; seed = $seed; factors = @('theme', 'config', 'showTimes', 'rate', 'condition')
        sliceCounts = [ordered]@{ pairwise = $slices.pairwise.Count; threeway = $slices.threeway.Count; rest = $slices.rest.Count }
        verification = $verification; uncoveredThreewayAfterPairwise = $afterPairwise; selectedSlice = $script:Rotation
        uncoveredSelectedTuples = $selectedCovered; playingRows = $PlayingRows.Count }
}
function Get-RequiredRowInventory {
    param([ValidateRange(0, 3600)] [double] $EstimatedOverheadSeconds = 15)
    $rows = [Collections.Generic.List[object]]::new()
    function Add-InventoryRow([string] $Id, [string] $Section, [string] $Scenario, [double] $Window = 0,
        [double] $Settle = 0, [hashtable] $Meta = @{}) {
        $row = [ordered]@{ id = $Id; section = $Section; scenario = $Scenario; windowSeconds = $Window
            settleSeconds = $Settle; waitSeconds = 0; estimatedOverheadSeconds = $EstimatedOverheadSeconds
            predictedSeconds = $Window + $Settle + $EstimatedOverheadSeconds; selected = $false }
        foreach ($key in $Meta.Keys) { $row[$key] = $Meta[$key] }
        $row.predictedSeconds += $row.waitSeconds
        $rows.Add($row)
    }
    $themes = @('pill', 'matte', 'matte-light', 'standard', 'classic', 'simple', 'album-art', 'card')
    if ($script:GateProfile -eq 'Fast-v2' -and $script:Rotation) { throw 'Rotation is supported only by Exhaustive-v1.' }
    $script:frameRotation = $null
    $script:priorWorst = $null
    if ('A-LOOK' -in $selected) {
        foreach ($case in @(New-LookCases)) {
            Add-InventoryRow "look.$($case.theme).$($case.case)" 'geometry' 'A-LOOK' 0 0 @{
                class = 'look'; theme = $case.theme; case = $case.case; checkPattern = "A-LOOK.$($case.theme).$($case.case).*" }
        }
        if ($script:GateProfile -eq 'Fast-v2') {
            foreach ($rate in @(0.25, 2)) {
                Add-InventoryRow "cadence.timesHidden.rate$rate" 'cadence' 'A-LOOK' 60 5 @{ class = 'cadence' }
                Add-InventoryRow "cadence.matte-w440-timesTrue-rate$rate" 'cadence' 'A-LOOK' 60 5 @{ class = 'cadence' }
            }
            Add-InventoryRow 'cadence.sample240s' 'cadence' 'A-LOOK' 60 5 @{ class = 'cadence' }
            Add-InventoryRow 'cadence.progressOffNoTimer' 'cadence' 'A-LOOK' 0 5 @{ class = 'cadence' }
        } else {
        foreach ($rate in @(0.25, 1, 2, 4)) {
            Add-InventoryRow "cadence.timesHidden.rate$rate" 'cadence' 'A-LOOK' 60 5 @{ class = 'cadence' }
        }
        Add-InventoryRow 'cadence.sample240s' 'cadence' 'A-LOOK' 60 5 @{ class = 'cadence' }
        Add-InventoryRow 'cadence.progressOffNoTimer' 'cadence' 'A-LOOK' 0 5 @{ class = 'cadence' }
        foreach ($theme in $themes | Where-Object { $_ -ne 'pill' }) {
            $width = [int] (Get-ThemeDefaults $theme).width
            if ($theme -ne 'album-art') {
                foreach ($rate in @(0.25, 1, 2, 4)) {
                    Add-InventoryRow "cadence.$theme-w$width-timesTrue-rate$rate" 'cadence' 'A-LOOK' 60 5 @{ class = 'cadence' }
                }
            }
            foreach ($rate in @(1, 4)) {
                Add-InventoryRow "cadence.$theme-w$width-timesFalse-rate$rate" 'cadence' 'A-LOOK' 60 5 @{ class = 'cadence' }
            }
        }
        foreach ($width in @(360, 1200)) {
            Add-InventoryRow "cadence.matte-w$width-timesTrue-rate1" 'cadence' 'A-LOOK' 60 5 @{ class = 'cadence' }
        }
        Add-InventoryRow 'cadence.matte-w440-timesTrue-rate1-sample' 'cadence' 'A-LOOK' 60 5 @{ class = 'cadence' }
        }
        foreach ($animation in @('fade', 'slide-up', 'slide-down', 'slide-left', 'slide-right', 'none')) {
            foreach ($kind in @('show', 'hide')) {
                Add-InventoryRow "motion.$kind.$animation" 'motion' 'A-LOOK' 0.5 0 @{
                    class = 'check'; checkPattern = "A-LOOK.motion.$kind.$animation" }
            }
        }
        foreach ($name in @('ignoresReducedMedia', 'reduceMotionCancels')) {
            Add-InventoryRow "motion.$name" 'motion' 'A-LOOK' 0.5 0 @{ class = 'check'; checkPattern = "A-LOOK.motion.$name" }
        }
        Add-InventoryRow 'look.longTextEllipsis' 'text' 'A-LOOK' 0 0 @{ class = 'check'; checkPattern = 'A-LOOK.pill.longTextEllipsis' }
        foreach ($name in @('backpressure', 'query', 'reloadDelete', 'themeCache', 'themeRegressions')) {
            Add-InventoryRow "regression.$name" 'regression' 'A-LOOK' 0 0 @{ class = 'section'; completionKey = $name }
        }
    }
    if ('A-FRAMES' -in $selected) {
        foreach ($mutant in @('bar-transition', 'pill-raf', 'ceiling-low', 'ceiling-high')) {
            Add-InventoryRow "frames.mutant.$mutant" 'frames' 'A-FRAMES' 60 5 @{ class = 'mutant'; prerequisite = $true }
        }
        foreach ($theme in $themes) {
            $base = Get-ThemeDefaults $theme
            $minimum = switch ($theme) { 'pill' { 320 } { $_ -in @('matte', 'matte-light', 'standard', 'classic', 'simple') } { 360 } 'album-art' { 160 } 'card' { 200 } }
            $maximum = switch ($theme) { 'pill' { 800 } { $_ -in @('matte', 'matte-light', 'standard', 'classic', 'simple') } { 1200 } default { 600 } }
            $configs = @(@{ label = 'default'; width = [int] $base.width; scale = 100 },
                @{ label = 'max-k200'; width = $maximum; scale = 200 },
                @{ label = 'min-k200'; width = 2 * $minimum; scale = 200 },
                @{ label = 'min-k50'; width = $minimum; scale = 50 })
            if ($script:GateProfile -eq 'Fast-v2') {
                $fastPlaying = @(@{ config = $configs[0]; times = $true; rate = 1; condition = 'sample-art' },
                    @{ config = $configs[1]; times = $true; rate = 4; condition = 'fixture-max' })
                $stressConfig = switch ($theme) { 'pill' { $configs[3] } 'classic' { $configs[2] } 'album-art' { $configs[3] } 'card' { $configs[2] } }
                if ($stressConfig) { $fastPlaying += @{ config = $stressConfig; times = $false; rate = 4; condition = 'long-text' } }
                foreach ($case in $fastPlaying) {
                    $config = $case.config; $times = $case.times; $rate = $case.rate; $condition = $case.condition
                    $id = "frames.$theme.$($config.label).times$times.r$rate.$condition"
                    Add-InventoryRow $id 'frames' 'A-FRAMES' 60 5 @{
                        class = 'playing'; theme = $theme; config = $config.label; width = $config.width; scale = $config.scale
                        showTimes = $times; rate = $rate; condition = $condition; label = "$theme-$($config.label)-times$times-rate$rate-$condition" }
                    Add-InventoryRow "cadence.shared.$id" 'frames' 'A-FRAMES' 0 0 @{
                        class = 'shared-cadence'; theme = $theme; sourceRow = $id; estimatedOverheadSeconds = 0; predictedSeconds = 0 }
                    if ($condition -eq 'sample-art') {
                        Add-InventoryRow "network.shared.$theme" 'frames' 'A-FRAMES' 0 0 @{
                            class = 'shared-network'; theme = $theme; sourceRow = $id; estimatedOverheadSeconds = 0; predictedSeconds = 0 }
                    }
                }
                $pixelId = "frames.$theme.pixel-max.r4.no-art"
                Add-InventoryRow $pixelId 'frames' 'A-FRAMES' 120 5 @{
                    class = 'pixel'; theme = $theme; config = 'max-k200'; width = $maximum; scale = 200
                    showTimes = $false; rate = 4; condition = 'pixel-only'; label = "$theme-pixel-max-rate4-no-art" }
                Add-InventoryRow "cadence.shared.$pixelId" 'frames' 'A-FRAMES' 0 0 @{
                    class = 'shared-cadence'; theme = $theme; sourceRow = $pixelId; estimatedOverheadSeconds = 0; predictedSeconds = 0 }
                $phase = 0
                foreach ($idle in @('dim-Paused', 'hidden-Paused', 'ended', 'clock-mismatch', 'progress-hidden')) {
                    if ($idle -eq 'dim-Paused' -or $theme -eq 'matte') {
                        Add-InventoryRow "frames.$theme.idle.$idle" 'frames' 'A-FRAMES' 60 5 @{
                            class = 'idle'; theme = $theme; condition = $idle; label = "$theme-idle-$idle" }
                    } else {
                        # One app session per theme; each phase owns its settle and two probes one second apart.
                        Add-InventoryRow "frames.$theme.idlecheck.$idle" 'frames' 'A-FRAMES' 1 5 @{
                            class = 'idlecheck'; theme = $theme; condition = $idle; label = "$theme-idlecheck-$idle"
                            estimatedOverheadSeconds = $(if ($phase -eq 0) { $EstimatedOverheadSeconds } else { 0 })
                            predictedSeconds = 6 + $(if ($phase -eq 0) { $EstimatedOverheadSeconds } else { 0 }) }
                        $phase++
                    }
                }
            } else {
            foreach ($config in $configs) {
                foreach ($times in @($true, $false)) {
                    foreach ($rate in @(1, 4)) {
                        $conditions = @('sample-art', 'no-art', 'fixture-max', 'long-text')
                        if ($rate -eq 4) { $conditions += @('long-sample-art', 'long-no-art') }
                        foreach ($condition in $conditions) {
                            $window = if ($rate -eq 4 -and $condition -in @('sample-art', 'no-art')) { 53 } else { 60 }
                            Add-InventoryRow "frames.$theme.$($config.label).times$times.r$rate.$condition" 'frames' 'A-FRAMES' $window 5 @{
                                class = 'playing'; theme = $theme; config = $config.label; width = $config.width; scale = $config.scale
                                showTimes = $times; rate = $rate; condition = $condition
                                label = "$theme-$($config.label)-times$times-rate$rate-$condition" }
                        }
                    }
                }
            }
            foreach ($rate in @(1, 4)) {
                Add-InventoryRow "frames.$theme.pixel.r$rate" 'frames' 'A-FRAMES' 120 5 @{
                    class = 'pixel'; theme = $theme; rate = $rate; label = "$theme-pixel-only-rate$rate" }
            }
            foreach ($idle in @('dim-Paused', 'hidden-Paused', 'ended', 'clock-mismatch', 'progress-hidden')) {
                Add-InventoryRow "frames.$theme.idle.$idle" 'frames' 'A-FRAMES' 60 5 @{
                    class = 'idle'; theme = $theme; condition = $idle; label = "$theme-idle-$idle" }
            }
            }
            Add-InventoryRow "frames.$theme.transitions" 'frames' 'A-FRAMES' 6 0 @{ class = 'transitions'; theme = $theme; label = "$theme-transitions" }
            Add-InventoryRow "frames.$theme.lateart" 'frames' 'A-FRAMES' 18 0 @{ class = 'lateart'; theme = $theme; label = "$theme-late-art" }
            if ($script:GateProfile -eq 'Exhaustive-v1') {
                Add-InventoryRow "frames.network.$theme" 'frames' 'A-FRAMES' 1.5 0 @{ class = 'network'; theme = $theme; label = "$theme-network" }
            }
        }
        if ($script:GateProfile -eq 'Fast-v2') {
            $pointerPath = Join-Path $fixtureDirectory 'exhaustive-worst.json'
            if (Test-Path -LiteralPath $pointerPath -PathType Leaf) {
                $pointer = Get-Content -Raw -LiteralPath $pointerPath | ConvertFrom-Json -AsHashtable -Depth 16
                if ($pointer -isnot [Collections.IDictionary] -or $pointer.version -ne 1 -or
                    $pointer.configuration -isnot [Collections.IDictionary] -or $pointer.sourceReport -isnot [string] -or
                    -not $pointer.sourceReport -or $pointer.sourceSha256 -cnotmatch '^[a-f0-9]{64}$') { throw 'Malformed exhaustive-worst.json pointer.' }
                $c = $pointer.configuration
                if ($c.theme -notin $themes -or $c.config -notin @('default', 'max-k200', 'min-k200', 'min-k50') -or
                    $c.showTimes -isnot [bool] -or $c.rate -notin @(1, 4) -or $c.condition -notin
                    @('sample-art', 'no-art', 'fixture-max', 'long-text', 'long-sample-art', 'long-no-art') -or
                    ($c.rate -ne 4 -and $c.condition -in @('long-sample-art', 'long-no-art'))) { throw 'Malformed exhaustive-worst.json configuration.' }
                $id = "frames.$($c.theme).$($c.config).times$($c.showTimes).r$($c.rate).$($c.condition)"
                if ($pointer.rowId -cne $id) { throw 'exhaustive-worst.json row id disagrees with its feasible configuration.' }
                $script:priorWorst = $pointer
                if (-not @($rows | Where-Object { $_.id -ceq $id }).Count) {
                    $minimum = switch ($c.theme) { 'pill' { 320 } 'album-art' { 160 } 'card' { 200 } default { 360 } }
                    $maximum = switch ($c.theme) { 'pill' { 800 } { $_ -in @('album-art', 'card') } { 600 } default { 1200 } }
                    $width = switch ($c.config) { 'default' { [int] (Get-ThemeDefaults $c.theme).width } 'max-k200' { $maximum } 'min-k200' { 2 * $minimum } 'min-k50' { $minimum } }
                    $scale = switch ($c.config) { 'default' { 100 } 'min-k50' { 50 } default { 200 } }
                    Add-InventoryRow $id 'frames' 'A-FRAMES' 60 5 @{
                        class = 'playing'; theme = $c.theme; config = $c.config; width = $width; scale = $scale
                        showTimes = $c.showTimes; rate = $c.rate; condition = $c.condition; priorWorst = $true
                        label = "$($c.theme)-$($c.config)-times$($c.showTimes)-rate$($c.rate)-$($c.condition)" }
                    Add-InventoryRow "cadence.shared.$id" 'frames' 'A-FRAMES' 0 0 @{
                        class = 'shared-cadence'; theme = $c.theme; sourceRow = $id; estimatedOverheadSeconds = 0; predictedSeconds = 0 }
                }
            }
        }
        Add-InventoryRow 'frames.renewal' 'frames' 'A-FRAMES' 20 0 @{ class = 'renewal'; label = 'renewal'; waitSeconds = 290 }
        if ($script:GateProfile -eq 'Exhaustive-v1') {
            $script:frameRotation = Get-FrameRotation @($rows | Where-Object { $_.scenario -eq 'A-FRAMES' -and $_.class -eq 'playing' })
        }
    }
    foreach ($name in $selected | Where-Object { $_ -notin @('A-LOOK', 'A-FRAMES') }) {
        $sectionName = switch ($name) { 'A-TEXT' { 'text' } 'A-PAUSEVIEW' { 'pauseview' } 'A-PLAIN' { 'plain' } 'A-PROD' { 'prod' } default { 'regression' } }
        Add-InventoryRow "scenario.$name" $sectionName $name 0 0 @{ class = 'check'; checkPattern = "$name.*" }
    }
    foreach ($row in $rows) {
        $chosen = Test-SectionSelected $row.section
        if ($row.scenario -eq 'A-LOOK') {
            if ($row.class -eq 'look') {
                $caseName = "$($row.theme).$($row.case)"
                $chosen = $chosen -and @($script:LookCase | Where-Object { $caseName -like $_ }).Count -gt 0
            } elseif ($script:LookCase.Count -ne 1 -or $script:LookCase[0] -cne '*') { $chosen = $false }
        }
        if ($row.scenario -eq 'A-FRAMES' -and $row.class -ne 'mutant') { $chosen = $chosen -and (Test-FrameRowSelected $row.id) }
        if ($row.scenario -eq 'A-FRAMES' -and $row.class -eq 'playing' -and $script:Rotation) {
            $chosen = $chosen -and $row.rotationSlice -eq $script:Rotation
        }
        if ($row.class -in @('shared-cadence', 'shared-network')) {
            $chosen = (Test-SectionSelected $row.section) -and (Test-FrameRowSelected $row.sourceRow)
        }
        $row.selected = [bool] $chosen
    }
    $rows.ToArray()
}

function Initialize-RequiredRowInventory {
    if ($script:Section.Count -eq 0 -or $script:FrameRow.Count -eq 0 -or $script:LookCase.Count -eq 0) {
        throw 'Section, FrameRow and LookCase selectors must each contain at least one pattern.'
    }
    $script:requiredRowInventory = @(Get-RequiredRowInventory)
    foreach ($pattern in $script:Section) {
        if (-not @($script:requiredRowInventory | Where-Object { $_.section -like $pattern -and $_.selected }).Count) {
            throw "Section selector '$pattern' matches no rows in the selected scenarios."
        }
    }
    if ($script:FrameRow.Count -ne 1 -or $script:FrameRow[0] -cne '*') {
        foreach ($pattern in $script:FrameRow) {
            if (-not @($script:requiredRowInventory | Where-Object { $_.scenario -eq 'A-FRAMES' -and $_.selected -and $_.id -like $pattern }).Count) {
                throw "FrameRow selector '$pattern' matches no selected frame rows."
            }
        }
    }
    if ($script:LookCase.Count -ne 1 -or $script:LookCase[0] -cne '*') {
        foreach ($pattern in $script:LookCase) {
            if (-not @($script:requiredRowInventory | Where-Object { $_.class -eq 'look' -and $_.selected -and "$($_.theme).$($_.case)" -like $pattern }).Count) {
                throw "LookCase selector '$pattern' matches no selected geometry rows."
            }
        }
    }
    $predicted = 0.0
    foreach ($row in $script:requiredRowInventory) { if ($row.selected) { $predicted += [double] $row.predictedSeconds } }
    [IO.File]::WriteAllText((Join-Path $runDirectory 'inventory.json'), (ConvertTo-Json -Depth 12 -InputObject ([ordered]@{
        version = $script:rowInventoryVersion; protocol = $script:GateProfile; rotation = $script:frameRotation
        priorWorst = $script:priorWorst
        predictedTotalSeconds = [double] $predicted; estimatesOnly = $true; rows = $script:requiredRowInventory })), [Text.UTF8Encoding]::new($false))
    Write-Host "Required-row inventory: $(@($script:requiredRowInventory | Where-Object { $_.selected }).Count) selected; predicted $predicted seconds (estimated overhead)."
}

function Test-InventoryRowPassed($Row) {
    if ($Row.scenario -eq 'A-FRAMES' -or $Row.class -eq 'cadence') { return Test-JournalRowPassed -Id $Row.id }
    if ($Row.class -eq 'section') { return $script:completedInventorySections.ContainsKey($Row.completionKey) -and $script:completedInventorySections[$Row.completionKey] }
    $rowChecks = @($checks | Where-Object { $_.name -like $Row.checkPattern })
    if ($Row.class -eq 'look') {
        # Presence alone is insufficient: all independent case predicates and the release barrier must finish.
        $key = "$($Row.theme).$($Row.case)"
        if (-not $scenarioResults.Contains('A-LOOK') -or -not $scenarioResults['A-LOOK'].cases.Contains($key)) { return $false }
        foreach ($suffix in @('lookBeforeData', 'stylesAndSizes', 'raster', 'domGeometry', 'fill', 'textContainment')) {
            if (-not @($rowChecks | Where-Object { $_.name -eq "A-LOOK.$key.$suffix" }).Count) { return $false }
        }
    }
    $rowChecks.Count -gt 0 -and @($rowChecks | Where-Object { $_.status -ne 'pass' }).Count -eq 0
}
function Get-RequiredRowCoverage {
    $selectedIds = @($script:requiredRowInventory | Where-Object { $_.selected } | ForEach-Object { $_.id })
    $omittedIds = @($script:requiredRowInventory | Where-Object { -not $_.selected } | ForEach-Object { $_.id })
    $missingIds = @($script:requiredRowInventory | Where-Object { $_.selected -and -not (Test-InventoryRowPassed $_) } | ForEach-Object { $_.id })
    $fullMissing = @($script:requiredRowInventory | Where-Object { -not (Test-InventoryRowPassed $_) } | ForEach-Object { $_.id })
    [ordered]@{ selected = $selectedIds.Count; omitted = $omittedIds.Count; missing = $missingIds.Count
        selectedIds = $selectedIds; omittedIds = $omittedIds; missingIds = $missingIds
        selectedMissing = $missingIds; fullMissing = $fullMissing; fullMissingCount = $fullMissing.Count }
}
