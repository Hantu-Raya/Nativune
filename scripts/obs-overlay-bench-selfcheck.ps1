# Pure checks invoked only by -DryRun. No process, network, sleep or filesystem mutation.
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
    foreach ($path in @('obs-overlay-bench.ps1','obs-overlay-bench-protocol.ps1','obs-overlay-bench-runtime.ps1','obs-portable.ps1','obs-overlay-obs-e2e.ps1')) {
        $tokens=$null;$parseErrors=$null
        [void][Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot $path),[ref]$tokens,[ref]$parseErrors)
        if ($parseErrors.Count) {throw "$path parse errors: $($parseErrors.Message -join '; ')"}
    }
    'Self-check: schedule, arithmetic, endpoints, adjacency, brackets, reversal, 4 pairs, drift/cold-cost/retention/mixed and script parse PASS'
}
