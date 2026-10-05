# Dot-sourced by obs-overlay-e2e.ps1, or run standalone with -Summarize <run directory>.
param([string] $Summarize = '')

# Best-effort only: no pipeline output, exceptions, or verdict changes.
# Extra.outcome is also exposed at the top level when the caller knows the outcome.
function Add-PhaseTiming {
    param([string] $Phase, [double] $Seconds, [string] $Row = '', [hashtable] $Extra = @{})
    try {
        $directory = Get-Variable -Name runDirectory -Scope Script -ErrorAction SilentlyContinue
        if (-not $directory -or -not $directory.Value) { return }
        if (-not $Row) {
            $current = Get-Variable -Name currentRowId -Scope Script -ErrorAction SilentlyContinue
            if ($current) { $Row = [string] $current.Value }
        }
        $record = [ordered]@{ phase = $Phase; seconds = $Seconds; row = $Row
            utc = [DateTime]::UtcNow.ToString('o'); extra = $Extra }
        if ($Extra -and $Extra.ContainsKey('outcome')) { $record['outcome'] = $Extra['outcome'] }
        $line = ConvertTo-Json -InputObject $record -Depth 16 -Compress -WarningAction SilentlyContinue -ErrorAction Stop
        [IO.File]::AppendAllText((Join-Path $directory.Value 'timings.jsonl'), ($line + "`n"), [Text.UTF8Encoding]::new($false))
    } catch { }
}

# Keep QPC conversion inside the same best-effort boundary for lifecycle finally blocks.
function Complete-PhaseTiming {
    param([string] $Phase, [double] $StartQpc, [hashtable] $Extra = @{})
    try { Add-PhaseTiming -Phase $Phase -Seconds (((Get-Qpc) - $StartQpc) / $freq) -Extra $Extra } catch { }
}

# Median averages the middle pair; p95 uses nearest rank. Totals overlap for nested phases.
function Get-PhaseTimingSummary {
    param([Parameter(Mandatory)][string] $RunDirectory)
    $records = @(Get-Content -LiteralPath (Join-Path $RunDirectory 'timings.jsonl') -ErrorAction Stop |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json -ErrorAction Stop })
    foreach ($group in @($records | Group-Object -Property phase | Sort-Object -Property Name)) {
        $seconds = @($group.Group | ForEach-Object { [double] $_.seconds } | Sort-Object)
        $count = $seconds.Count
        $middle = [int] [Math]::Floor($count / 2)
        $median = if ($count % 2) { $seconds[$middle] } else { ($seconds[$middle - 1] + $seconds[$middle]) / 2 }
        [pscustomobject]@{ phase = $group.Name; count = $count; median = $median
            p95 = $seconds[[int] [Math]::Ceiling($count * 0.95) - 1]
            total = [double] ($seconds | Measure-Object -Sum).Sum }
    }
}

if ($Summarize) { Get-PhaseTimingSummary -RunDirectory $Summarize | Format-Table -AutoSize }
