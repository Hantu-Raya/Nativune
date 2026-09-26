<#
.SYNOPSIS
Runs repeatable Nativune performance measurements.

.DESCRIPTION
Build the bench flavour with scripts/dotnet.ps1 publish src/Nativune/Nativune.csproj --runtime win-x64 --self-contained false -o artifacts/perf-bench/publish -p:PerfBenchHooks=true.
Prepare a reusable profile once with -PrepareTemplate, then run named conditions with -Condition. An optional .cache/perf/template/settings.json seeds app settings for each run (for example, Block ads).
Run reports default to .cache/perf/results/<condition>/run-<n>.json and <condition>/summary.json; runs.csv is .cache/perf/results/runs.csv. Template preparation writes .cache/perf/results/template/prepare-template.json.
Cleanup only stops the benchmark process started by this script and its descendants; unrelated processes are never stopped.

.PARAMETER Condition
Name of the measurement condition; required unless preparing a template.

.PARAMETER Runs
Number of runs for the condition (default 3).

.PARAMETER ExtraArgs
Additional Chromium browser arguments.

.PARAMETER EnableFeatures
Comma-separated Chromium features to enable.

.PARAMETER DisableFeatures
Comma-separated Chromium features to disable.

.PARAMETER DotnetEnv
Hashtable of DOTNET_* environment variable overrides.

.PARAMETER Exe
Path to the published bench executable.

.PARAMETER StartUri
Initial public YouTube Music watch URI.

.PARAMETER Schedule
Timed compact, full, hide, show, and quit actions.

.PARAMETER SettleSeconds
Seconds skipped after each phase begins before its metrics are measured.

.PARAMETER OutDir
Directory for run results and summaries.

.PARAMETER TemplateProfile
Reusable WebView2 profile used to seed each run.

.PARAMETER PrepareTemplate
Create or replace the reusable profile before measuring conditions.

.PARAMETER TimeoutSeconds
Run timeout in seconds; zero selects the default.

.PARAMETER DryRun
Validate and display the plan without launching the executable.

.EXAMPLE
pwsh -NoProfile -File scripts/bench-perf.ps1 -PrepareTemplate

.EXAMPLE
pwsh -NoProfile -File scripts/bench-perf.ps1 -Condition baseline -Runs 5
#>

[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Run')]
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string] $Condition,
    [ValidateRange(1, 1000)]
    [int] $Runs = 3,
    [string] $ExtraArgs = '',
    [string] $EnableFeatures = '',
    [string] $DisableFeatures = '',
    [hashtable] $DotnetEnv = @{},
    [string] $Exe = 'artifacts/perf-bench/publish/Nativune.exe',
    [string] $StartUri = 'https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVMdQw4w9WgXcQ',
    [string] $Schedule = 'compact@150;full@300;hide@420;quit@540',
    [ValidateRange(0, 3600)]
    [int] $SettleSeconds = 30,
    [string] $OutDir = '.cache/perf/results',
    [string] $TemplateProfile = '.cache/perf/template/webview2',
    [Parameter(Mandatory = $true, ParameterSetName = 'Prepare')]
    [switch] $PrepareTemplate,
    [ValidateRange(0, 86400)]
    [int] $TimeoutSeconds = 0,
    [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ProjectRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$script:RunsBase = Join-Path $script:ProjectRoot '.cache\perf\runs'
$script:Utf8NoBom = [Text.UTF8Encoding]::new($false)
$script:PhaseNames = @('full', 'compact', 'full2', 'hidden')

function Resolve-ProjectPath {
    param(
        [Parameter(Mandatory = $true)][string] $Value,
        [Parameter(Mandatory = $true)][string] $Name
    )

    if ([IO.Path]::IsPathRooted($Value)) {
        $fullPath = [IO.Path]::GetFullPath($Value)
    }
    else {
        $fullPath = [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Value))
    }

    $root = $script:ProjectRoot.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $rootPrefix = $root + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase) -and
        -not $fullPath.StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "$Name must stay inside the repository: $Value"
    }
    return $fullPath
}

function Assert-RepositoryPath {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $Name
    )

    $rootItem = Get-Item -LiteralPath $script:ProjectRoot -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw 'The repository root cannot be a reparse point for benchmark output.'
    }
    $relative = [IO.Path]::GetRelativePath($script:ProjectRoot, $Path)
    $current = $script:ProjectRoot
    foreach ($part in ($relative -split '[\\/]+')) {
        if ([string]::IsNullOrEmpty($part) -or $part -eq '.') { continue }
        $current = Join-Path $current $part
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "$Name cannot traverse a reparse point: $current"
            }
        }
    }
}

function Test-PathOverlap {
    param(
        [Parameter(Mandatory = $true)][string] $First,
        [Parameter(Mandatory = $true)][string] $Second
    )

    $firstPath = [IO.Path]::GetFullPath($First).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $secondPath = [IO.Path]::GetFullPath($Second).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    $firstPrefix = $firstPath + [IO.Path]::DirectorySeparatorChar
    $secondPrefix = $secondPath + [IO.Path]::DirectorySeparatorChar
    return ($firstPath.Equals($secondPath, [StringComparison]::OrdinalIgnoreCase) -or
        $firstPath.StartsWith($secondPrefix, [StringComparison]::OrdinalIgnoreCase) -or
        $secondPath.StartsWith($firstPrefix, [StringComparison]::OrdinalIgnoreCase))
}

function Get-StartUriPath {
    param([Parameter(Mandatory = $true)][uri] $Uri)
    return $Uri.AbsolutePath
}

function ConvertTo-SafeEventPath {
    param([AllowNull()][object] $Value)

    if ($null -eq $Value) { return $null }
    $text = [string] $Value
    if ($text -match '^https://') {
        try { return ([uri] $text).AbsolutePath } catch { }
    }
    return ($text -replace '[?#].*$', '')
}

function Parse-Schedule {
    param([Parameter(Mandatory = $true)][string] $Text)

    $actions = [Collections.Generic.List[object]]::new()
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($part in $Text.Split(';')) {
        if ([string]::IsNullOrWhiteSpace($part)) { continue }
        if ($part -notmatch '^\s*(compact|full|hide|show|quit)\s*@\s*(\d+)\s*$') {
            throw "Invalid schedule entry '$part'. Use action@seconds with compact, full, hide, show, or quit."
        }
        $action = $Matches[1].ToLowerInvariant()
        if (-not $seen.Add($action)) { throw "Schedule action '$action' appears more than once." }
        $actions.Add([pscustomobject]@{ action = $action; seconds = [int] $Matches[2] })
    }
    if ($actions.Count -eq 0) { throw 'Schedule must contain at least one action.' }

    if (-not $PrepareTemplate) {
        foreach ($requiredAction in @('compact', 'full', 'hide', 'quit')) {
            if (-not $seen.Contains($requiredAction)) {
                throw "Schedule must contain '$requiredAction' to measure all requested phase windows."
            }
        }
        $compactAt = ($actions | Where-Object action -eq 'compact').seconds
        $fullAt = ($actions | Where-Object action -eq 'full').seconds
        $hideAt = ($actions | Where-Object action -eq 'hide').seconds
        $quitAt = ($actions | Where-Object action -eq 'quit').seconds
        if (-not ($compactAt -lt $fullAt -and $fullAt -lt $hideAt -and $hideAt -lt $quitAt)) {
            throw 'Schedule times must be ordered compact < full < hide < quit.'
        }
    }
    return $actions.ToArray()
}

function Test-ExcludedProfileEntry {
    param([Parameter(Mandatory = $true)][string] $Name)

    return ($Name -match '\.(dmp|mdmp|core|crash)$' -or
        $Name -match '\.(lock|lck)$' -or
        $Name -match '^(Singleton(Lock|Cookie|Socket)|LOCK|LOCKFILE|lockfile)$')
}

function Copy-FilteredProfile {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($entry in ([IO.DirectoryInfo]::new($Source)).EnumerateFileSystemInfos()) {
        if (Test-ExcludedProfileEntry -Name $entry.Name) { continue }
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Refusing to follow a reparse point in the WebView2 profile.'
        }

        $target = Join-Path $Destination $entry.Name
        if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
            Copy-FilteredProfile -Source $entry.FullName -Destination $target
        }
        else {
            [IO.File]::Copy($entry.FullName, $target, $true)
        }
    }
}

function Copy-LocalTree {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($entry in ([IO.DirectoryInfo]::new($Source)).EnumerateFileSystemInfos()) {
        if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'Refusing to follow a reparse point in the bundled extension tree.'
        }
        $target = Join-Path $Destination $entry.Name
        if (($entry.Attributes -band [IO.FileAttributes]::Directory) -ne 0) {
            Copy-LocalTree -Source $entry.FullName -Destination $target
        }
        else {
            [IO.File]::Copy($entry.FullName, $target, $true)
        }
    }
}

function Copy-TemplateProfile {
    param(
        [Parameter(Mandatory = $true)][string] $Source,
        [Parameter(Mandatory = $true)][string] $Destination
    )

    $parent = Split-Path -Parent $Destination
    [IO.Directory]::CreateDirectory($parent) | Out-Null
    $stage = "$Destination.stage-$([guid]::NewGuid().ToString('N'))"
    $backup = "$Destination.previous-$([guid]::NewGuid().ToString('N'))"
    try {
        Copy-FilteredProfile -Source $Source -Destination $stage
        if (Test-Path -LiteralPath $Destination) {
            Move-Item -LiteralPath $Destination -Destination $backup | Out-Null
            try {
                Move-Item -LiteralPath $stage -Destination $Destination | Out-Null
            }
            catch {
                if (-not (Test-Path -LiteralPath $Destination) -and (Test-Path -LiteralPath $backup)) {
                    Move-Item -LiteralPath $backup -Destination $Destination | Out-Null
                }
                throw
            }
            Remove-Item -LiteralPath $backup -Recurse -Force
        }
        else {
            Move-Item -LiteralPath $stage -Destination $Destination | Out-Null
        }
    }
    finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    }
}

function Write-JsonFile {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][object] $Value
    )

    $json = ConvertTo-Json -InputObject $Value -Depth 40
    [IO.File]::WriteAllText($Path, $json, $script:Utf8NoBom)
}

function Get-UniqueRunRoot {
    param([Parameter(Mandatory = $true)][string] $Label)

    while ($true) {
        $stamp = [DateTime]::UtcNow.ToString('yyyyMMddHHmmss', [Globalization.CultureInfo]::InvariantCulture)
        $candidate = Join-Path $script:RunsBase "$Label-$stamp"
        if (-not (Test-Path -LiteralPath $candidate)) { return $candidate }
        Start-Sleep -Milliseconds 1050
    }
}

function Get-TreeRecords {
    param(
        [Parameter(Mandatory = $true)][AllowNull()][AllowEmptyCollection()][object[]] $Records,
        [Parameter(Mandatory = $true)][hashtable] $TreeState,
        [Parameter(Mandatory = $true)][Diagnostics.Process] $LaunchProcess
    )

    $currentByPid = [Collections.Generic.Dictionary[long, object]]::new()
    foreach ($record in $Records) {
        $currentByPid[[long] $record.ProcessId] = $record
    }

    if ($currentByPid.ContainsKey([long] $TreeState.RootPid) -and -not $LaunchProcess.HasExited) {
        $rootRecord = $currentByPid[[long] $TreeState.RootPid]
        if ([long] $TreeState.RootCreateTime -ne [long] $rootRecord.CreateTime) {
            foreach ($oldKey in @($TreeState.Seen.Keys)) {
                $oldRecord = $TreeState.Seen[$oldKey]
                if ([long] $oldRecord.ProcessId -eq [long] $TreeState.RootPid) { [void] $TreeState.Seen.Remove($oldKey) }
            }
            $TreeState.RootCreateTime = [long] $rootRecord.CreateTime
            $rootKey = '{0}:{1}' -f $rootRecord.ProcessId, $rootRecord.CreateTime
            $TreeState.Seen[$rootKey] = $rootRecord
        }
    }

    $memberKeys = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    if ([long] $TreeState.RootCreateTime -gt 0 -and
        $currentByPid.ContainsKey([long] $TreeState.RootPid)) {
        $rootCurrent = $currentByPid[[long] $TreeState.RootPid]
        if ([long] $rootCurrent.CreateTime -eq [long] $TreeState.RootCreateTime) {
            [void] $memberKeys.Add(('{0}:{1}' -f $rootCurrent.ProcessId, $rootCurrent.CreateTime))
        }
    }

    foreach ($record in $Records) {
        $key = '{0}:{1}' -f $record.ProcessId, $record.CreateTime
        if ($TreeState.Seen.ContainsKey($key)) { [void] $memberKeys.Add($key) }
    }

    $changed = $true
    while ($changed) {
        $changed = $false
        foreach ($record in $Records) {
            $key = '{0}:{1}' -f $record.ProcessId, $record.CreateTime
            if ($memberKeys.Contains($key) -or [long] $record.ParentProcessId -le 0) { continue }

            $parentPid = [long] $record.ParentProcessId
            $parentRecord = $null
            if ($currentByPid.ContainsKey($parentPid)) {
                $parentRecord = $currentByPid[$parentPid]
                if ([long] $parentRecord.CreateTime -le [long] $record.CreateTime) {
                    $parentKey = '{0}:{1}' -f $parentRecord.ProcessId, $parentRecord.CreateTime
                    if ($memberKeys.Contains($parentKey)) {
                        [void] $memberKeys.Add($key)
                        $changed = $true
                    }
                    continue
                }
            }

            if ($parentPid -eq [long] $TreeState.RootPid -and
                [long] $TreeState.RootCreateTime -gt 0 -and
                [long] $TreeState.RootExitTime -gt 0 -and
                [long] $record.CreateTime -ge [long] $TreeState.RootCreateTime -and
                [long] $record.CreateTime -le [long] $TreeState.RootExitTime) {
                [void] $memberKeys.Add($key)
                $changed = $true
            }
        }
    }

    $members = [Collections.Generic.List[object]]::new()
    foreach ($record in $Records) {
        $key = '{0}:{1}' -f $record.ProcessId, $record.CreateTime
        if ($memberKeys.Contains($key)) {
            $TreeState.Seen[$key] = $record
            $members.Add($record)
        }
    }
    return $members.ToArray()
}

function Add-ProcessSample {
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][Collections.Generic.List[object]] $Samples,
        [Parameter(Mandatory = $true)][hashtable] $TreeState,
        [Parameter(Mandatory = $true)][hashtable] $SampleState,
        [Parameter(Mandatory = $true)][Diagnostics.Process] $LaunchProcess,
        [Parameter(Mandatory = $true)][Diagnostics.Stopwatch] $RunClock,
        [Parameter(Mandatory = $true)][int] $LogicalProcessorCount
    )

    $allProcesses = [Nativune.PerfBench.Native]::Snapshot()
    if ($null -eq $allProcesses) { return }
    $tree = @(Get-TreeRecords -Records $allProcesses -TreeState $TreeState -LaunchProcess $LaunchProcess)
    $treeItems = [Collections.Generic.List[object]]::new()
    $currentCpu = [Collections.Generic.Dictionary[string, long]]::new([StringComparer]::Ordinal)
    [double] $workingSet = 0
    [double] $privateBytes = 0
    [long] $threads = 0
    [long] $handles = 0
    [double] $pageFaults = 0
    [double] $cpuDelta = 0

    foreach ($record in $tree) {
        $key = '{0}:{1}' -f $record.ProcessId, $record.CreateTime
        $cpuTicks = [long] $record.UserTime100ns + [long] $record.KernelTime100ns
        $currentCpu[$key] = $cpuTicks
        if ($SampleState.PreviousCpu.ContainsKey($key)) {
            $delta = $cpuTicks - [long] $SampleState.PreviousCpu[$key]
            if ($delta -gt 0) { $cpuDelta += $delta }
        }
        else {
            if ($cpuTicks -gt 0) { $cpuDelta += $cpuTicks }
        }
        $workingSet += [double] $record.WorkingSetPrivateBytes
        $privateBytes += [double] $record.PrivateBytes
        $threads += [long] $record.ThreadCount
        $handles += [long] $record.HandleCount
        $pageFaults += [double] $record.PageFaultCount
        $treeItems.Add([pscustomobject]@{
            processId = [long] $record.ProcessId
            parentProcessId = [long] $record.ParentProcessId
            imageName = [string] $record.ImageName
            createTime100ns = [long] $record.CreateTime
            workingSetPrivateBytes = [long] $record.WorkingSetPrivateBytes
            privateBytes = [ulong] $record.PrivateBytes
            userTime100ns = [long] $record.UserTime100ns
            kernelTime100ns = [long] $record.KernelTime100ns
            threadCount = [long] $record.ThreadCount
            handleCount = [long] $record.HandleCount
            pageFaultCount = [long] $record.PageFaultCount
        })
    }

    $elapsed = $RunClock.Elapsed.TotalSeconds
    $timestamp = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
    $cpuPercent = $null
    if ($Samples.Count -gt 0) {
        $wallSeconds = $elapsed - [double] $Samples[$Samples.Count - 1].elapsedSeconds
        if ($wallSeconds -gt 0 -and $LogicalProcessorCount -gt 0) {
            $cpuPercent = 100.0 * $cpuDelta / (10000000.0 * $wallSeconds * $LogicalProcessorCount)
        }
    }

    $sample = [pscustomobject]@{
        timestampUnixMs = [long] $timestamp
        elapsedSeconds = [double] $elapsed
        processCount = [int] $tree.Count
        workingSetPrivateBytes = [double] $workingSet
        privateBytes = [double] $privateBytes
        cpuPercent = $cpuPercent
        cpuDelta100ns = [double] $cpuDelta
        threadCount = [long] $threads
        handleCount = [long] $handles
        pageFaultCount = [double] $pageFaults
        processes = $treeItems.ToArray()
    }
    $Samples.Add($sample)
    $SampleState.PreviousCpu = $currentCpu
}

function Stop-OwnedTree {
    param(
        [Parameter(Mandatory = $true)][Diagnostics.Process] $LaunchProcess,
        [Parameter(Mandatory = $true)][hashtable] $TreeState,
        [Parameter(Mandatory = $true)][int] $WaitSeconds
    )

    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    try {
        if ($LaunchProcess.HasExited -and [long] $TreeState.RootExitTime -le 0) {
            $TreeState.RootExitTime = [long] $LaunchProcess.ExitTime.ToFileTimeUtc()
        }
    }
    catch { }
    $forced = $false
    $killed = $false
    $verifiedEmpty = $false
    $lastSnapshotSucceeded = $false
    $leftoversBeforeKill = 0
    $lastTree = @()
    $cleanupErrors = [Collections.Generic.List[string]]::new()
    $hardLimit = [Math]::Max(15, $WaitSeconds + 15)
    if ($WaitSeconds -eq 0) {
        try {
            if (-not $LaunchProcess.HasExited) {
                $LaunchProcess.Kill($false)
                $killed = $true
                $forced = $true
                [void] $LaunchProcess.WaitForExit(1000)
            }
            if ($LaunchProcess.HasExited) { $TreeState.RootExitTime = [long] $LaunchProcess.ExitTime.ToFileTimeUtc() }
        }
        catch { $cleanupErrors.Add($_.Exception.Message) }
    }

    while ($stopwatch.Elapsed.TotalSeconds -le $hardLimit) {
        try {
            if ($LaunchProcess.HasExited -and [long] $TreeState.RootExitTime -le 0) {
                $TreeState.RootExitTime = [long] $LaunchProcess.ExitTime.ToFileTimeUtc()
            }
        }
        catch { }
        $snapshotSucceeded = $false
        try {
            $snapshot = [Nativune.PerfBench.Native]::Snapshot()
            if ($null -eq $snapshot) {
                Start-Sleep -Milliseconds 100
                continue
            }
            $lastTree = @(Get-TreeRecords -Records $snapshot -TreeState $TreeState -LaunchProcess $LaunchProcess)
            $snapshotSucceeded = $true
            $lastSnapshotSucceeded = $true
        }
        catch {
            $cleanupErrors.Add($_.Exception.Message)
            if (-not $forced -and $WaitSeconds -eq 0) {
                try {
                    if (-not $LaunchProcess.HasExited) {
                        $LaunchProcess.Kill($false)
                        $killed = $true
                        $forced = $true
                    }
                }
                catch { $cleanupErrors.Add($_.Exception.Message) }
            }
        }
        if ($forced -and $leftoversBeforeKill -eq 0 -and $lastTree.Count -gt 0) {
            $leftoversBeforeKill = $lastTree.Count
        }

        if ($snapshotSucceeded -and $lastTree.Count -eq 0) {
            $verifiedEmpty = $true
            break
        }
        if (-not $snapshotSucceeded) {
            Start-Sleep -Milliseconds 100
            continue
        }
        if (-not $forced -and $stopwatch.Elapsed.TotalSeconds -lt $WaitSeconds) {
            Start-Sleep -Milliseconds 100
            continue
        }

        if (-not $forced) {
            $leftoversBeforeKill = $lastTree.Count
            $forced = $true
        }
        foreach ($record in ($lastTree | Sort-Object -Property { [long] $_.CreateTime } -Descending)) {
            if ([Nativune.PerfBench.Native]::TryTerminate([long] $record.ProcessId, [long] $record.CreateTime)) {
                $killed = $true
            }
        }
        try {
            if (-not $LaunchProcess.HasExited -and [long] $TreeState.RootCreateTime -gt 0) {
                $LaunchProcess.Kill($false)
                $killed = $true
            }
        }
        catch { $cleanupErrors.Add($_.Exception.Message) }
        Start-Sleep -Milliseconds 100
    }

    return [pscustomobject]@{
        exitCleanupSeconds = [Math]::Round($stopwatch.Elapsed.TotalSeconds, 3)
        leftovers = $(if ($verifiedEmpty) { 0 } elseif ($lastSnapshotSucceeded) { [int] $lastTree.Count } else { -1 })
        leftoversBeforeKill = [int] $leftoversBeforeKill
        killed = [bool] $killed
        forcedKill = [bool] $forced
        verifiedEmpty = [bool] $verifiedEmpty
        errors = $cleanupErrors.ToArray()
    }
}

function Read-BenchEvents {
    param([Parameter(Mandatory = $true)][string] $Path)

    $result = [Collections.Generic.List[object]]::new()
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result.ToArray() }
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    $reader = $null
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::UTF8, $true)
        while ($null -ne ($line = $reader.ReadLine())) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $eventData = ConvertFrom-Json -InputObject $line -AsHashtable -Depth 20
            if (-not $eventData.ContainsKey('event') -or -not $eventData.ContainsKey('t')) { continue }
            $eventName = [string] $eventData['event']
            $event = [ordered]@{ t = [double] $eventData['t']; event = $eventName }
            switch ($eventName) {
                'bench-start' {
                    foreach ($key in @('pid', 'processStart')) {
                        if ($eventData.ContainsKey($key)) { $event[$key] = $eventData[$key] }
                    }
                }
                'navigation-completed' {
                    if ($eventData.ContainsKey('ok')) { $event['ok'] = [bool] $eventData['ok'] }
                    if ($eventData.ContainsKey('path')) { $event['path'] = ConvertTo-SafeEventPath $eventData['path'] }
                }
                'media-playing' {
                    if ($eventData.ContainsKey('currentTime')) { $event['currentTime'] = $eventData['currentTime'] }
                }
                'anchor' {
                    if ($eventData.ContainsKey('source')) { $event['source'] = [string] $eventData['source'] }
                }
                'media-sample' {
                    foreach ($key in @('paused', 'currentTime', 'duration')) {
                        if ($eventData.ContainsKey($key)) { $event[$key] = $eventData[$key] }
                    }
                }
                'process-infos' {
                    $processes = [Collections.Generic.List[object]]::new()
                    foreach ($entry in @($eventData['processes'])) {
                        if ($entry -isnot [Collections.IDictionary]) { continue }
                        $processId = $entry['pid'] -as [int]
                        $kind = [string] $entry['kind']
                        if ($processId -gt 0 -and $kind -match '^[A-Za-z]{1,32}$') {
                            [void] $processes.Add([ordered]@{ pid = $processId; kind = $kind })
                        }
                    }
                    $event['processes'] = $processes.ToArray()
                }
            }
            [void] $result.Add([pscustomobject] $event)
        }
        catch {
            Write-Warning 'Skipped a malformed benchmark log line.'
        }
    }
    }
    finally {
        if ($null -ne $reader) { $reader.Dispose() } else { $stream.Dispose() }
    }
    return $result.ToArray()
}

function Write-SafeBenchLog {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [AllowNull()][AllowEmptyCollection()][object[]] $Events
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    $lines = @($Events | ForEach-Object { ConvertTo-Json -InputObject $_ -Depth 10 -Compress })
    $content = ''
    if ($lines.Count -gt 0) { $content = ($lines -join [Environment]::NewLine) + [Environment]::NewLine }
    [IO.File]::WriteAllText($Path, $content, $script:Utf8NoBom)
}

function Get-FirstEvent {
    param([AllowNull()][AllowEmptyCollection()][object[]] $Events, [Parameter(Mandatory = $true)][string] $Name)
    return $Events | Where-Object { $_.event -eq $Name } | Sort-Object -Property t | Select-Object -First 1
}

function Get-EventLatency {
    param([AllowNull()][AllowEmptyCollection()][object[]] $Events, [string] $StartName, [string] $EndName, [double] $StartTimeMs)

    $endEvent = Get-FirstEvent -Events $Events -Name $EndName
    if ($null -eq $endEvent) { return $null }
    if ([string]::IsNullOrEmpty($StartName)) { $start = $StartTimeMs }
    else {
        $startEvent = Get-FirstEvent -Events $Events -Name $StartName
        if ($null -eq $startEvent) { return $null }
        $start = [double] $startEvent.t
    }
    return [Math]::Round(([double] $endEvent.t - $start), 2)
}

function Get-PageFaultDelta {
    param([AllowNull()][AllowEmptyCollection()][object[]] $Samples, [double] $WindowStart, [double] $WindowEnd)

    $baseline = [Collections.Generic.Dictionary[string, long]]::new([StringComparer]::Ordinal)
    foreach ($sample in $Samples) {
        if ([double] $sample.timestampUnixMs -ge $WindowStart) { break }
        foreach ($processRecord in $sample.processes) {
            $key = '{0}:{1}' -f $processRecord.processId, $processRecord.createTime100ns
            $baseline[$key] = [long] $processRecord.pageFaultCount
        }
    }

    [double] $deltaTotal = 0
    foreach ($sample in $Samples) {
        $time = [double] $sample.timestampUnixMs
        if ($time -lt $WindowStart -or $time -ge $WindowEnd) { continue }
        foreach ($processRecord in $sample.processes) {
            $key = '{0}:{1}' -f $processRecord.processId, $processRecord.createTime100ns
            $faults = [long] $processRecord.pageFaultCount
            if ($baseline.ContainsKey($key)) {
                $delta = $faults - [long] $baseline[$key]
                if ($delta -gt 0) { $deltaTotal += $delta }
            }
            else {
                if ($faults -gt 0) { $deltaTotal += $faults }
            }
            $baseline[$key] = $faults
        }
    }
    return [long] $deltaTotal
}

function Get-PhaseMetrics {
    param(
        [AllowNull()][AllowEmptyCollection()][object[]] $Samples,
        [AllowNull()][AllowEmptyCollection()][object[]] $Events,
        [Parameter(Mandatory = $true)][string] $PhaseName,
        [Parameter(Mandatory = $true)][string] $StartEvent,
        [Parameter(Mandatory = $true)][string] $EndEvent,
        [Parameter(Mandatory = $true)][int] $Settle
    )

    $startRecord = Get-FirstEvent -Events $Events -Name $StartEvent
    $endRecord = Get-FirstEvent -Events $Events -Name $EndEvent
    if ($null -eq $startRecord -or $null -eq $endRecord) {
        return [pscustomobject]@{ available = $false; sampleCount = 0; reason = 'Required boundary event is missing.' }
    }
    $windowStart = [double] $startRecord.t + ($Settle * 1000.0)
    $windowEnd = [double] $endRecord.t
    if ($windowEnd -le $windowStart) {
        return [pscustomobject]@{ available = $false; sampleCount = 0; startUnixMs = $windowStart; endUnixMs = $windowEnd; reason = 'Phase window is empty after settling.' }
    }
    $windowSamples = @($Samples | Where-Object {
        [double] $_.timestampUnixMs -ge $windowStart -and [double] $_.timestampUnixMs -lt $windowEnd
    })
    if ($windowSamples.Count -eq 0) {
        return [pscustomobject]@{ available = $true; sampleCount = 0; startUnixMs = $windowStart; endUnixMs = $windowEnd; meanPrivateWorkingSetMiB = $null; peakPrivateWorkingSetMiB = $null; meanPrivateBytesMiB = $null; peakPrivateBytesMiB = $null; meanCpuPercent = $null; maxProcessCount = $null; meanThreads = $null; meanHandles = $null; pageFaultDelta = 0 }
    }

    $ws = @($windowSamples | ForEach-Object { [double] $_.workingSetPrivateBytes / 1048576.0 })
    $pb = @($windowSamples | ForEach-Object { [double] $_.privateBytes / 1048576.0 })
    $cpu = @($windowSamples | Where-Object { $null -ne $_.cpuPercent } | ForEach-Object { [double] $_.cpuPercent })
    $threads = @($windowSamples | ForEach-Object { [double] $_.threadCount })
    $handles = @($windowSamples | ForEach-Object { [double] $_.handleCount })
    $processCounts = @($windowSamples | ForEach-Object { [int] $_.processCount })
    $meanCpu = $null
    if ($cpu.Count -gt 0) { $meanCpu = [Math]::Round(($cpu | Measure-Object -Average).Average, 4) }

    return [pscustomobject]@{
        available = $true
        sampleCount = $windowSamples.Count
        startUnixMs = $windowStart
        endUnixMs = $windowEnd
        meanPrivateWorkingSetMiB = [Math]::Round(($ws | Measure-Object -Average).Average, 3)
        peakPrivateWorkingSetMiB = [Math]::Round(($ws | Measure-Object -Maximum).Maximum, 3)
        meanPrivateBytesMiB = [Math]::Round(($pb | Measure-Object -Average).Average, 3)
        peakPrivateBytesMiB = [Math]::Round(($pb | Measure-Object -Maximum).Maximum, 3)
        meanCpuPercent = $meanCpu
        maxProcessCount = ($processCounts | Measure-Object -Maximum).Maximum
        meanThreads = [Math]::Round(($threads | Measure-Object -Average).Average, 2)
        meanHandles = [Math]::Round(($handles | Measure-Object -Average).Average, 2)
        pageFaultDelta = Get-PageFaultDelta -Samples $Samples -WindowStart $windowStart -WindowEnd $windowEnd
    }
}

function Get-PlaybackCheck {
    param([AllowNull()][AllowEmptyCollection()][object[]] $Events)

    $media = @($Events | Where-Object { $_.event -eq 'media-sample' } | Sort-Object -Property t)
    $advancingPairs = 0
    for ($index = 1; $index -lt $media.Count; $index++) {
        $previous = $media[$index - 1]
        $current = $media[$index]
        $previousPaused = $previous.PSObject.Properties['paused']
        $currentPaused = $current.PSObject.Properties['paused']
        $previousTime = $previous.PSObject.Properties['currentTime']
        $currentTime = $current.PSObject.Properties['currentTime']
        if ($null -ne $previousPaused -and $null -ne $currentPaused -and
            $previousPaused.Value -eq $false -and $currentPaused.Value -eq $false -and
            $null -ne $previousTime -and $null -ne $currentTime -and
            [double] $currentTime.Value -gt [double] $previousTime.Value) {
            $advancingPairs++
        }
    }
    $firstTime = $null
    $lastTime = $null
    foreach ($record in $media) {
        $currentTime = $record.PSObject.Properties['currentTime']
        if ($null -ne $currentTime) {
            if ($null -eq $firstTime) { $firstTime = [double] $currentTime.Value }
            $lastTime = [double] $currentTime.Value
        }
    }
    return [pscustomobject]@{
        passed = ($advancingPairs -gt 0)
        mediaSampleCount = $media.Count
        advancingPairs = $advancingPairs
        firstCurrentTime = $firstTime
        lastCurrentTime = $lastTime
    }
}

function Get-RunMetricMap {
    param([Parameter(Mandatory = $true)][object] $RunReport)

    $metrics = [ordered]@{}
    foreach ($phaseName in $script:PhaseNames) {
        $phaseProperty = $RunReport.phases.PSObject.Properties[$phaseName]
        if ($null -eq $phaseProperty) { continue }
        $phase = $phaseProperty.Value
        foreach ($metricName in @('sampleCount', 'meanPrivateWorkingSetMiB', 'peakPrivateWorkingSetMiB', 'meanPrivateBytesMiB', 'peakPrivateBytesMiB', 'meanCpuPercent', 'maxProcessCount', 'meanThreads', 'meanHandles', 'pageFaultDelta')) {
            $metricProperty = $phase.PSObject.Properties[$metricName]
            if ($null -ne $metricProperty -and $null -ne $metricProperty.Value -and $metricProperty.Value -is [ValueType]) {
                $metrics["phase.$phaseName.$metricName"] = [double] $metricProperty.Value
            }
        }
    }
    foreach ($property in $RunReport.startup.PSObject.Properties) {
        if ($null -ne $property.Value) { $metrics["startup.$($property.Name)"] = [double] $property.Value }
    }
    foreach ($property in $RunReport.transitions.PSObject.Properties) {
        if ($null -ne $property.Value) { $metrics["transition.$($property.Name)"] = [double] $property.Value }
    }
    $metrics['playback.passed'] = [int] [bool] $RunReport.playback.passed
    $metrics['playback.mediaSampleCount'] = [double] $RunReport.playback.mediaSampleCount
    $metrics['playback.advancingPairs'] = [double] $RunReport.playback.advancingPairs
    foreach ($key in @('exitCleanupSeconds', 'leftovers', 'leftoversBeforeKill')) {
        $property = $RunReport.cleanup.PSObject.Properties[$key]
        if ($null -ne $property -and $null -ne $property.Value) { $metrics["cleanup.$key"] = [double] $property.Value }
    }
    $metrics['cleanup.killed'] = [int] [bool] $RunReport.cleanup.killed
    $metrics['cleanup.timedOut'] = [int] [bool] $RunReport.timedOut
    return [pscustomobject] $metrics
}

function Get-Median {
    param([AllowNull()][AllowEmptyCollection()][double[]] $Values)
    $sorted = @($Values | Sort-Object)
    if ($sorted.Count -eq 0) { return $null }
    $middle = [int] [Math]::Floor($sorted.Count / 2.0)
    if (($sorted.Count % 2) -eq 1) { return [double] $sorted[$middle] }
    return (([double] $sorted[$middle - 1] + [double] $sorted[$middle]) / 2.0)
}

function Add-CsvRun {
    param(
        [Parameter(Mandatory = $true)][string] $CsvPath,
        [Parameter(Mandatory = $true)][object] $RunReport
    )

    $row = [ordered]@{
        condition = $RunReport.condition
        run = $RunReport.run
        runStartedUtc = $RunReport.runStartedUtc
        status = $RunReport.status
    }
    foreach ($phaseName in $script:PhaseNames) {
        $phaseProperty = $RunReport.phases.PSObject.Properties[$phaseName]
        $phase = if ($null -ne $phaseProperty) { $phaseProperty.Value } else { $null }
        foreach ($metricName in @('sampleCount', 'meanPrivateWorkingSetMiB', 'peakPrivateWorkingSetMiB', 'meanPrivateBytesMiB', 'peakPrivateBytesMiB', 'meanCpuPercent', 'maxProcessCount', 'meanThreads', 'meanHandles', 'pageFaultDelta')) {
            $metricProperty = if ($null -ne $phase) { $phase.PSObject.Properties[$metricName] } else { $null }
            $metricValue = if ($null -ne $metricProperty) { $metricProperty.Value } else { $null }
            $row["${phaseName}_$metricName"] = $metricValue
        }
    }
    foreach ($property in $RunReport.startup.PSObject.Properties) { $row["startup_$($property.Name)"] = $property.Value }
    foreach ($property in $RunReport.transitions.PSObject.Properties) { $row["transition_$($property.Name)"] = $property.Value }
    $row.playbackPassed = $RunReport.playback.passed
    $row.mediaSampleCount = $RunReport.playback.mediaSampleCount
    $row.advancingPairs = $RunReport.playback.advancingPairs
    $row.exitCleanupSeconds = $RunReport.cleanup.exitCleanupSeconds
    $row.leftovers = $RunReport.cleanup.leftovers
    $row.leftoversBeforeKill = $RunReport.cleanup.leftoversBeforeKill
    $row.killed = $RunReport.cleanup.killed
    $row.timedOut = $RunReport.timedOut
    $lines = @(([pscustomobject] $row) | ConvertTo-Csv -NoTypeInformation)
    $fileExists = Test-Path -LiteralPath $CsvPath -PathType Leaf
    if ($fileExists -and (Get-Item -LiteralPath $CsvPath).Length -eq 0) { $fileExists = $false }
    if ($fileExists) {
        [IO.File]::AppendAllText($CsvPath, ($lines[1] + [Environment]::NewLine), $script:Utf8NoBom)
    }
    else {
        [IO.File]::WriteAllText($CsvPath, (($lines -join [Environment]::NewLine) + [Environment]::NewLine), $script:Utf8NoBom)
    }
}

function Write-ConditionSummary {
    param(
        [Parameter(Mandatory = $true)][string] $ConditionName,
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]] $Reports,
        [Parameter(Mandatory = $true)][string] $ConditionDirectory
    )

    $perRun = @($Reports | ForEach-Object { Get-RunMetricMap -RunReport $_ })
    $allNames = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($map in $perRun) {
        foreach ($property in $map.PSObject.Properties) { [void] $allNames.Add([string] $property.Name) }
    }
    $stats = [ordered]@{}
    foreach ($name in $allNames) {
        $values = [Collections.Generic.List[double]]::new()
        foreach ($map in $perRun) {
            $metricProperty = $map.PSObject.Properties[$name]
            if ($null -ne $metricProperty) { $values.Add([double] $metricProperty.Value) }
        }
        if ($values.Count -gt 0) {
            $valueArray = $values.ToArray()
            $stats[$name] = [ordered]@{
                median = [Math]::Round((Get-Median -Values $valueArray), 4)
                min = [Math]::Round(($valueArray | Measure-Object -Minimum).Minimum, 4)
                max = [Math]::Round(($valueArray | Measure-Object -Maximum).Maximum, 4)
                runCount = $valueArray.Count
            }
        }
    }

    $playbackPasses = @($Reports | Where-Object { $_.playback.passed }).Count
    $summary = [ordered]@{
        condition = $ConditionName
        generatedAtUtc = [DateTime]::UtcNow.ToString('o')
        runCount = $Reports.Count
        metricSummaries = $stats
        playback = [ordered]@{
            passedRuns = $playbackPasses
            failedRuns = $Reports.Count - $playbackPasses
            passRate = $(if ($Reports.Count -gt 0) { [Math]::Round($playbackPasses / [double] $Reports.Count, 4) } else { 0 })
        }
        runFiles = @($Reports | ForEach-Object { $_.runFile })
    }
    Write-JsonFile -Path (Join-Path $ConditionDirectory 'summary.json') -Value $summary
}

function Invoke-BenchRun {
    param(
        [Parameter(Mandatory = $true)][string] $RunCondition,
        [Parameter(Mandatory = $true)][int] $RunNumber,
        [Parameter(Mandatory = $true)][bool] $IsTemplatePreparation,
        [Parameter(Mandatory = $true)][string] $ExecutablePath,
        [Parameter(Mandatory = $true)][string] $StartUriValue,
        [Parameter(Mandatory = $true)][string] $EffectiveSchedule,
        [Parameter(Mandatory = $true)][int] $EffectiveTimeout,
        [Parameter(Mandatory = $true)][bool] $TimeoutFromAnchor,
        [Parameter(Mandatory = $true)][string] $TemplatePath,
        [Parameter(Mandatory = $true)][string] $UbolSource,
        [Parameter(Mandatory = $true)][string] $OutputDirectory
    )

    $runLabel = if ($IsTemplatePreparation) { 'template' } else { "$RunCondition-$RunNumber" }
    $runRoot = Get-UniqueRunRoot -Label $runLabel
    [IO.Directory]::CreateDirectory($runRoot) | Out-Null
    $profilePath = Join-Path $runRoot 'data\webview2'
    $logPath = Join-Path $runRoot 'bench.jsonl'
    $sampleList = [Collections.Generic.List[object]]::new()
    $logicalProcessors = 0
    $processStarted = $false
    $treeState = @{ RootPid = 0L; RootCreateTime = 0L; RootExitTime = 0L; Seen = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal) }
    $sampleState = @{ PreviousCpu = [Collections.Generic.Dictionary[string, long]]::new([StringComparer]::Ordinal) }
    $process = $null
    $clock = $null
    $runStartUtc = [DateTime]::UtcNow
    $runError = $null
    $timedOut = $false
    $timeoutDeadlineSeconds = [double] $EffectiveTimeout
    $anchorDeadlineSet = $false
    $timeoutBase = if ($TimeoutFromAnchor) { 'anchor' } else { 'process-start' }
    $cleanup = [pscustomobject]@{ exitCleanupSeconds = 0.0; leftovers = 0; leftoversBeforeKill = 0; killed = $false; forcedKill = $false; verifiedEmpty = $false; errors = @() }
    $exitCode = $null
    $profileCopied = $false
    $profileRemoved = $false
    $events = @()

    try {
        [IO.Directory]::CreateDirectory((Join-Path $runRoot '.tools')) | Out-Null
        $toolTarget = Join-Path $runRoot '.tools\ubol'
        [IO.Directory]::CreateDirectory($toolTarget) | Out-Null
        Copy-LocalTree -Source $UbolSource -Destination $toolTarget

        if ($IsTemplatePreparation) {
            [IO.Directory]::CreateDirectory($profilePath) | Out-Null
        }
        else {
            Copy-FilteredProfile -Source $TemplatePath -Destination $profilePath
        }

        # Seed the run's settings (e.g. Block ads on) from the template folder when present.
        $templateSettings = Join-Path (Split-Path -Parent $TemplatePath) 'settings.json'
        if (Test-Path -LiteralPath $templateSettings -PathType Leaf) {
            Copy-Item -LiteralPath $templateSettings -Destination (Join-Path $runRoot 'data\settings.json') -Force
        }

        $psi = [Diagnostics.ProcessStartInfo]::new()
        $psi.FileName = $ExecutablePath
        $psi.WorkingDirectory = $script:ProjectRoot
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.ArgumentList.Add('web')
        $psi.ArgumentList.Add('--root')
        $psi.ArgumentList.Add($runRoot)
        $psi.Environment['NATIVUNE_BENCH_LOG'] = $logPath
        $psi.Environment['NATIVUNE_BENCH_START_URI'] = $StartUriValue
        $psi.Environment['NATIVUNE_BENCH_AUTOPLAY'] = '1'
        $psi.Environment['NATIVUNE_BENCH_MUTE'] = '1'
        $psi.Environment['NATIVUNE_BENCH_SCHEDULE'] = $EffectiveSchedule
        $psi.Environment['NATIVUNE_BENCH_EXTRA_ARGS'] = $ExtraArgs
        $psi.Environment['NATIVUNE_BENCH_ENABLE_FEATURES'] = $EnableFeatures
        $psi.Environment['NATIVUNE_BENCH_DISABLE_FEATURES'] = $DisableFeatures
        foreach ($entry in $DotnetEnv.GetEnumerator()) {
            $name = [string] $entry.Key
            if ($name -notmatch '^DOTNET_[A-Za-z0-9_]+$') { throw "Invalid .NET environment variable name '$name'. Use DOTNET_* names only." }
            $value = if ($null -eq $entry.Value) { '' } else { [string] $entry.Value }
            $psi.Environment[$name] = $value
        }

        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $psi
        $runStartUtc = [DateTime]::UtcNow
        $clock = [Diagnostics.Stopwatch]::StartNew()
        if (-not $process.Start()) { throw 'Process.Start returned false for the benchmark executable.' }
        $processStarted = $true
        $treeState.RootPid = [long] $process.Id
        try {
            $treeState.RootCreateTime = [long] $process.StartTime.ToUniversalTime().ToFileTimeUtc()
            $syntheticRoot = [pscustomobject]@{ ProcessId = $treeState.RootPid; CreateTime = $treeState.RootCreateTime; ParentProcessId = 0L }
            $treeState.Seen[('{0}:{1}' -f $treeState.RootPid, $treeState.RootCreateTime)] = $syntheticRoot
        }
        catch { $treeState.RootCreateTime = 0L }
        $logicalProcessors = [Nativune.PerfBench.Native]::LogicalProcessorCount()
        $firstSample = $true
        [double] $nextSampleAt = 0
        while ($true) {
            if (-not $firstSample) {
                if ($process.HasExited) { break }
                $remaining = $nextSampleAt - $clock.Elapsed.TotalSeconds
                if ($remaining -gt 0) { Start-Sleep -Milliseconds ([Math]::Max(1, [int] [Math]::Floor($remaining * 1000))) }
                if ($process.HasExited) { break }
            }
            if ($TimeoutFromAnchor -and -not $anchorDeadlineSet) {
                try {
                    $observedEvents = @(Read-BenchEvents -Path $logPath)
                    $observedAnchor = Get-FirstEvent -Events $observedEvents -Name 'anchor'
                    $observedStart = Get-FirstEvent -Events $observedEvents -Name 'bench-start'
                    if ($null -ne $observedAnchor -and $null -ne $observedStart -and $null -ne $observedStart.processStart) {
                        $anchorOffset = [Math]::Max(0.0, ([double] $observedAnchor.t - [double] $observedStart.processStart) / 1000.0)
                        $timeoutDeadlineSeconds = $anchorOffset + $EffectiveTimeout
                        $anchorDeadlineSet = $true
                    }
                }
                catch { }
            }
            if ($clock.Elapsed.TotalSeconds -ge $timeoutDeadlineSeconds) { $timedOut = $true; break }
            Add-ProcessSample -Samples $sampleList -TreeState $treeState -SampleState $sampleState -LaunchProcess $process -RunClock $clock -LogicalProcessorCount $logicalProcessors
            $firstSample = $false
            $nextSampleAt += 1.0
            while ($nextSampleAt -le $clock.Elapsed.TotalSeconds) { $nextSampleAt += 1.0 }
        }
    }
    catch {
        $runError = $_.Exception.Message
        if ($null -ne $_.InvocationInfo -and -not [string]::IsNullOrWhiteSpace($_.InvocationInfo.PositionMessage)) {
            $runError = "$runError`n$($_.InvocationInfo.PositionMessage)"
        }
    }
    finally {
        if ($null -ne $process) {
            if ($processStarted) {
                $waitSeconds = 15
                if ($timedOut -or $null -ne $runError) { $waitSeconds = 0 }
                try {
                    $cleanup = Stop-OwnedTree -LaunchProcess $process -TreeState $treeState -WaitSeconds $waitSeconds
                }
                catch {
                    $cleanup.errors = @($_.Exception.Message)
                    $cleanup.leftovers = -1
                    $cleanup.verifiedEmpty = $false
                }
                try {
                    if ($process.HasExited) { $exitCode = $process.ExitCode }
                }
                catch { }
            }
            $process.Dispose()
        }

        try {
            $events = @(Read-BenchEvents -Path $logPath)
            if (-not $processStarted -or $cleanup.verifiedEmpty) {
                Write-SafeBenchLog -Path $logPath -Events $events
            }
            elseif (Test-Path -LiteralPath $logPath -PathType Leaf) {
                Remove-Item -LiteralPath $logPath -Force
                if ((Test-Path -LiteralPath $logPath -PathType Leaf) -and $null -eq $runError) {
                    $runError = 'The unsanitized benchmark log could not be removed after incomplete process cleanup.'
                }
            }
        }
        catch {
            if ($null -eq $runError) { $runError = "Could not read or sanitize the benchmark event log: $($_.Exception.Message)" }
            if (Test-Path -LiteralPath $logPath -PathType Leaf) {
                try { Remove-Item -LiteralPath $logPath -Force } catch { }
            }
        }
        if ($null -eq $runError -and $null -eq (Get-FirstEvent -Events $events -Name 'bench-start')) {
            $runError = 'No bench-start event was written; the executable may not include PerfBenchHooks.'
        }

        if ($IsTemplatePreparation -and $null -eq $runError) {
            if ($null -eq (Get-FirstEvent -Events $events -Name 'media-playing')) {
                $runError = 'Template preparation finished without a media-playing event.'
            }
            elseif ($timedOut) {
                $runError = 'Template preparation timed out before its scheduled quit.'
            }
            elseif ($cleanup.leftovers -ne 0 -or -not $cleanup.verifiedEmpty) {
                $runError = 'Template profile was not copied because the process tree did not verify clean exit.'
            }
            elseif (-not (Test-Path -LiteralPath $profilePath -PathType Container)) {
                $runError = 'The app did not create its data/webview2 profile.'
            }
            else {
                try {
                    Copy-TemplateProfile -Source $profilePath -Destination $TemplatePath
                    $profileCopied = $true
                }
                catch { $runError = "Could not install the template profile: $($_.Exception.Message)" }
            }
        }

        if (Test-Path -LiteralPath $profilePath) {
            if (-not $processStarted -or ($cleanup.leftovers -eq 0 -and $cleanup.verifiedEmpty)) {
                try {
                    Remove-Item -LiteralPath $profilePath -Recurse -Force
                    $profileRemoved = -not (Test-Path -LiteralPath $profilePath)
                }
                catch { if ($null -eq $runError) { $runError = "Could not remove the temporary WebView2 profile: $($_.Exception.Message)" } }
            }
            elseif ($null -eq $runError) {
                $runError = 'The temporary WebView2 profile was retained because descendant cleanup was not verified.'
            }
        }
    }

    $benchStart = Get-FirstEvent -Events $events -Name 'bench-start'
    $processStartMs = $null
    if ($null -ne $benchStart -and $null -ne $benchStart.processStart) {
        $processStartMs = [double] $benchStart.processStart
    }
    else {
        $processStartMs = ([DateTimeOffset] $runStartUtc).ToUnixTimeMilliseconds()
    }
    $startup = [pscustomobject]@{
        windowShownMs = Get-EventLatency -Events $events -EndName 'window-shown' -StartTimeMs $processStartMs
        environmentCreatedMs = Get-EventLatency -Events $events -EndName 'environment-created' -StartTimeMs $processStartMs
        navigationCompletedMs = Get-EventLatency -Events $events -EndName 'navigation-completed' -StartTimeMs $processStartMs
        mediaPlayingMs = Get-EventLatency -Events $events -EndName 'media-playing' -StartTimeMs $processStartMs
    }
    $transitions = [pscustomobject]@{
        compactMs = Get-EventLatency -Events $events -StartName 'compact-requested' -EndName 'compact-shown'
        fullMs = Get-EventLatency -Events $events -StartName 'full-requested' -EndName 'full-shown'
    }
    $hiddenEndEvent = 'quit-requested'
    $hideDoneEvent = Get-FirstEvent -Events $events -Name 'hide-done'
    $showRequestEvent = Get-FirstEvent -Events $events -Name 'show-requested'
    $quitRequestEvent = Get-FirstEvent -Events $events -Name 'quit-requested'
    if ($null -ne $hideDoneEvent -and $null -ne $showRequestEvent -and
        [double] $showRequestEvent.t -ge [double] $hideDoneEvent.t -and
        ($null -eq $quitRequestEvent -or [double] $showRequestEvent.t -lt [double] $quitRequestEvent.t)) {
        $hiddenEndEvent = 'show-requested'
    }
    $phases = [pscustomobject]@{
        full = Get-PhaseMetrics -Samples $sampleList.ToArray() -Events $events -PhaseName 'full' -StartEvent 'anchor' -EndEvent 'compact-requested' -Settle $SettleSeconds
        compact = Get-PhaseMetrics -Samples $sampleList.ToArray() -Events $events -PhaseName 'compact' -StartEvent 'compact-shown' -EndEvent 'full-requested' -Settle $SettleSeconds
        full2 = Get-PhaseMetrics -Samples $sampleList.ToArray() -Events $events -PhaseName 'full2' -StartEvent 'full-shown' -EndEvent 'hide-requested' -Settle $SettleSeconds
        hidden = Get-PhaseMetrics -Samples $sampleList.ToArray() -Events $events -PhaseName 'hidden' -StartEvent 'hide-done' -EndEvent $hiddenEndEvent -Settle $SettleSeconds
    }
    $playback = Get-PlaybackCheck -Events $events
    $status = if ($null -ne $runError) { 'error' } elseif ($timedOut) { 'timeout' } elseif ($cleanup.leftovers -lt 0) { 'cleanup-unverified' } elseif ($cleanup.leftovers -gt 0) { 'leftovers' } elseif ($cleanup.killed) { 'killed' } elseif ($null -ne $exitCode -and $exitCode -ne 0) { 'process-error' } else { 'ok' }
    $conditionFolder = Join-Path $OutputDirectory $RunCondition
    $runFileName = if ($IsTemplatePreparation) { 'prepare-template.json' } else { "run-$RunNumber.json" }
    $runFile = Join-Path $conditionFolder $runFileName
    $report = [pscustomobject]@{
        schemaVersion = 1
        condition = $RunCondition
        run = $RunNumber
        status = $status
        error = $runError
        runStartedUtc = $runStartUtc.ToString('o')
        runRoot = $runRoot
        executable = $ExecutablePath
        startUriPath = Get-StartUriPath -Uri ([uri] $StartUriValue)
        extraArgsPresent = -not [string]::IsNullOrWhiteSpace($ExtraArgs)
        enableFeatures = $EnableFeatures
        disableFeatures = $DisableFeatures
        dotnetEnvNames = @($DotnetEnv.Keys | ForEach-Object { [string] $_ })
        schedule = $EffectiveSchedule
        settleSeconds = $SettleSeconds
        timeoutSeconds = $EffectiveTimeout
        timeoutBase = $timeoutBase
        logicalProcessorCount = $logicalProcessors
        timedOut = [bool] $timedOut
        processExitCode = $exitCode
        processSamples = $sampleList.ToArray()
        events = $events
        phases = $phases
        startup = $startup
        transitions = $transitions
        playback = $playback
        cleanup = $cleanup
        templateCopied = [bool] $profileCopied
        profileRemoved = [bool] $profileRemoved
        runFile = $runFile
    }
    [IO.Directory]::CreateDirectory($conditionFolder) | Out-Null
    Write-JsonFile -Path $runFile -Value $report
    Add-CsvRun -CsvPath (Join-Path $OutputDirectory 'runs.csv') -RunReport $report
    return $report
}

# Validate all user-controlled paths before any directory is created or process is started.
if ([string]::IsNullOrWhiteSpace($StartUri)) { throw 'StartUri is required.' }
$startUriObject = $null
if (-not [uri]::TryCreate($StartUri, [UriKind]::Absolute, [ref] $startUriObject) -or
    $startUriObject.Scheme -ne 'https' -or
    -not $startUriObject.IsDefaultPort -or
    -not [string]::IsNullOrEmpty($startUriObject.UserInfo) -or
    -not $startUriObject.Host.Equals('music.youtube.com', [StringComparison]::OrdinalIgnoreCase) -or
    $startUriObject.AbsolutePath -ne '/watch' -or
    $startUriObject.Query -notmatch '(?:^|[?&])v=[^&]+') {
    throw 'StartUri must be an https://music.youtube.com/watch URI with a public video id.'
}

$executablePath = if ([IO.Path]::IsPathRooted($Exe)) { [IO.Path]::GetFullPath($Exe) } else { [IO.Path]::GetFullPath((Join-Path $script:ProjectRoot $Exe)) }
$outputPath = Resolve-ProjectPath -Value $OutDir -Name 'OutDir'
$templatePath = Resolve-ProjectPath -Value $TemplateProfile -Name 'TemplateProfile'
$ubolPath = Join-Path $script:ProjectRoot '.tools\ubol'
$effectiveSchedule = if ($PrepareTemplate) { 'quit@30' } else { $Schedule }
$scheduleEntries = Parse-Schedule -Text $effectiveSchedule
$maximumScheduleSeconds = ($scheduleEntries | Measure-Object -Property seconds -Maximum).Maximum
$effectiveTimeout = $TimeoutSeconds
if ($effectiveTimeout -eq 0) {
    if ($PrepareTemplate) { $effectiveTimeout = 150 }
    else { $effectiveTimeout = [int] $maximumScheduleSeconds + 120 }
}
    $timeoutFromAnchor = ($TimeoutSeconds -eq 0 -and -not $PrepareTemplate)
    $timeoutBase = if ($timeoutFromAnchor) { 'anchor' } else { 'process-start' }
if ($effectiveTimeout -le 0) { throw 'TimeoutSeconds must be positive.' }
if (-not $PrepareTemplate -and [string]::IsNullOrWhiteSpace($Condition)) { throw 'Condition is required unless -PrepareTemplate is used.' }
if ($PrepareTemplate) { $runCondition = 'template' } else { $runCondition = $Condition }

$runsBaseFull = [IO.Path]::GetFullPath($script:RunsBase)
Assert-RepositoryPath -Path $runsBaseFull -Name 'Run root'
Assert-RepositoryPath -Path $outputPath -Name 'OutDir'
Assert-RepositoryPath -Path $templatePath -Name 'TemplateProfile'
Assert-RepositoryPath -Path $ubolPath -Name 'uBlock source'
if (Test-PathOverlap -First $templatePath -Second $runsBaseFull) {
    throw 'TemplateProfile cannot overlap the temporary benchmark run directory.'
}
if (Test-PathOverlap -First $outputPath -Second $runsBaseFull) {
    throw 'OutDir cannot overlap the temporary benchmark run directory.'
}
if (Test-PathOverlap -First $outputPath -Second $templatePath) {
    throw 'OutDir and TemplateProfile cannot overlap.'
}
if (-not (Test-Path -LiteralPath $ubolPath -PathType Container)) { throw "Required repo extension directory is missing: $ubolPath" }
if (-not $PrepareTemplate -and -not $DryRun -and -not (Test-Path -LiteralPath $templatePath -PathType Container)) {
    throw "WebView2 template profile is missing at '$templatePath'. Run with -PrepareTemplate -StartUri <uri> first."
}
if (-not $DryRun -and -not (Test-Path -LiteralPath $executablePath -PathType Leaf)) {
    throw "Benchmark executable is missing at '$executablePath'. Publish the PerfBenchHooks build with scripts/dotnet.ps1 first."
}
foreach ($entry in $DotnetEnv.GetEnumerator()) {
    if ([string] $entry.Key -notmatch '^DOTNET_[A-Za-z0-9_]+$') {
        throw "Invalid .NET environment variable name '$($entry.Key)'. Use DOTNET_* names only."
    }
}

if ($DryRun) {
    $uriPath = Get-StartUriPath -Uri $startUriObject
    $runCount = if ($PrepareTemplate) { 1 } else { $Runs }
    Write-Host "Plan: $runCount run(s); condition=$runCondition; executable=$executablePath"
    Write-Host "Run root: $script:RunsBase"
    Write-Host "Profile: $(if ($PrepareTemplate) { 'empty profile -> ' + $templatePath } else { $templatePath })"
    Write-Host "URI: https://music.youtube.com$uriPath (query omitted)"
    Write-Host "Schedule: $effectiveSchedule; timeout=$effectiveTimeout s from $timeoutBase; settle=$SettleSeconds s"
    Write-Host "Output: $outputPath; extension source: $ubolPath"
    Write-Host "DotnetEnv names: $(@($DotnetEnv.Keys | ForEach-Object { [string] $_ }) -join ', ')"
    return
}

if (-not ('Nativune.PerfBench.Native' -as [type])) {
    $nativeSource = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
namespace Nativune.PerfBench
{
    public sealed class ProcessRecord
    {
        public long ProcessId;
        public long ParentProcessId;
        public string ImageName;
        public long WorkingSetPrivateBytes;
        public ulong PrivateBytes;
        public long UserTime100ns;
        public long KernelTime100ns;
        public uint ThreadCount;
        public uint HandleCount;
        public uint PageFaultCount;
        public long CreateTime;
    }

    public static class Native
    {


        private const int SystemProcessInformationClass = 5;
        private static uint BufferSize = 64U * 1024U * 1024U;
        private static IntPtr Buffer = Marshal.AllocHGlobal((int)BufferSize);
        private static readonly int EntrySize = Marshal.SizeOf(typeof(SystemProcessInformation));

        [StructLayout(LayoutKind.Sequential)]
        private struct UnicodeString
        {
            public ushort Length;
            public ushort MaximumLength;
            public IntPtr Buffer;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct SystemProcessInformation
        {
            public uint NextEntryOffset;
            public uint NumberOfThreads;
            public long WorkingSetPrivateSize;
            public uint HardFaultCount;
            public uint NumberOfThreadsHighWatermark;
            public ulong CycleTime;
            public long CreateTime;
            public long UserTime;
            public long KernelTime;
            public UnicodeString ImageName;
            public int BasePriority;
            public IntPtr UniqueProcessId;
            public IntPtr InheritedFromUniqueProcessId;
            public uint HandleCount;
            public uint SessionId;
            public UIntPtr UniqueProcessKey;
            public UIntPtr PeakVirtualSize;
            public UIntPtr VirtualSize;
            public uint PageFaultCount;
            public UIntPtr PeakWorkingSetSize;
            public UIntPtr WorkingSetSize;
            public UIntPtr QuotaPeakPagedPoolUsage;
            public UIntPtr QuotaPagedPoolUsage;
            public UIntPtr QuotaPeakNonPagedPoolUsage;
            public UIntPtr QuotaNonPagedPoolUsage;
            public UIntPtr PagefileUsage;
            public UIntPtr PeakPagefileUsage;
            public UIntPtr PrivatePageCount;
        }

        [StructLayout(LayoutKind.Sequential)]
        private struct NativeFileTime
        {
            public uint LowDateTime;
            public uint HighDateTime;
        }

        [DllImport("ntdll.dll", ExactSpelling = true)]
        private static extern int NtQuerySystemInformation(int informationClass, IntPtr information, uint informationLength, out uint returnLength);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern IntPtr OpenProcess(uint desiredAccess, bool inheritHandle, uint processId);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool GetProcessTimes(IntPtr process, out NativeFileTime creation, out NativeFileTime exit, out NativeFileTime kernel, out NativeFileTime user);

        [DllImport("kernel32.dll", SetLastError = true)]
        private static extern bool TerminateProcess(IntPtr process, uint exitCode);

        [DllImport("kernel32.dll")]
        private static extern bool CloseHandle(IntPtr handle);

        [DllImport("kernel32.dll", ExactSpelling = true)]
        private static extern uint GetActiveProcessorCount(ushort groupNumber);

        private static long PointerToLong(IntPtr value)
        {
            return IntPtr.Size == 8 ? value.ToInt64() : value.ToInt32();
        }

        private static ulong ToUInt64(UIntPtr value)
        {
            return UIntPtr.Size == 8 ? value.ToUInt64() : value.ToUInt32();
        }

        private static long FileTimeToLong(NativeFileTime value)
        {
            return unchecked((long)(((ulong)value.HighDateTime << 32) | value.LowDateTime));
        }

        public static int LogicalProcessorCount()
        {
            return checked((int)GetActiveProcessorCount(UInt16.MaxValue));
        }

        public static ProcessRecord[] Snapshot()
        {
            uint returned;
            int status = NtQuerySystemInformation(SystemProcessInformationClass, Buffer, BufferSize, out returned);
            if (status == unchecked((int)0xC0000004))
            {
                ulong nextSize = (ulong)BufferSize * 2;
                ulong requiredSize = (ulong)returned + 1024UL * 1024UL;
                if (requiredSize > nextSize) nextSize = requiredSize;
                if (nextSize > Int32.MaxValue)
                {
                    throw new InvalidOperationException("NtQuerySystemInformation requires more than 2 GiB for the process snapshot.");
                }
                IntPtr expandedBuffer = Marshal.AllocHGlobal((int)nextSize);
                Marshal.FreeHGlobal(Buffer);
                Buffer = expandedBuffer;
                BufferSize = (uint)nextSize;
                return null;
            }
            if (status < 0)
            {
                throw new InvalidOperationException("NtQuerySystemInformation failed with NTSTATUS 0x" + status.ToString("X8") + ".");
            }

            long limit = returned == 0 ? BufferSize : Math.Min((long)returned, BufferSize);
            var processes = new List<ProcessRecord>();
            long offset = 0;
            while (offset + EntrySize <= limit)
            {
                IntPtr entry = IntPtr.Add(Buffer, checked((int)offset));
                var native = (SystemProcessInformation)Marshal.PtrToStructure(entry, typeof(SystemProcessInformation));
                string imageName = String.Empty;
                if (native.ImageName.Buffer != IntPtr.Zero && native.ImageName.Length > 0)
                {
                    long namePointer = native.ImageName.Buffer.ToInt64();
                    long bufferStart = Buffer.ToInt64();
                    if (namePointer >= bufferStart && namePointer + native.ImageName.Length <= bufferStart + limit)
                    {
                        imageName = Marshal.PtrToStringUni(native.ImageName.Buffer, native.ImageName.Length / 2) ?? String.Empty;
                    }
                }
                ulong privateBytes = ToUInt64(native.PrivatePageCount);
                if (privateBytes == 0) privateBytes = ToUInt64(native.PagefileUsage);
                processes.Add(new ProcessRecord
                {
                    ProcessId = PointerToLong(native.UniqueProcessId),
                    ParentProcessId = PointerToLong(native.InheritedFromUniqueProcessId),
                    ImageName = imageName,
                    WorkingSetPrivateBytes = native.WorkingSetPrivateSize,
                    PrivateBytes = privateBytes,
                    UserTime100ns = native.UserTime,
                    KernelTime100ns = native.KernelTime,
                    ThreadCount = native.NumberOfThreads,
                    HandleCount = native.HandleCount,
                    PageFaultCount = native.PageFaultCount,
                    CreateTime = native.CreateTime
                });

                if (native.NextEntryOffset == 0) break;
                if (native.NextEntryOffset < EntrySize || offset + native.NextEntryOffset > limit)
                {
                    throw new InvalidOperationException("NtQuerySystemInformation returned an invalid process-list offset.");
                }
                offset += native.NextEntryOffset;
            }
            return processes.ToArray();
        }

        public static bool TryTerminate(long processId, long expectedCreateTime)
        {
            if (processId <= 0 || processId > UInt32.MaxValue || expectedCreateTime <= 0) return false;
            const uint ProcessTerminate = 0x0001;
            const uint ProcessQueryLimitedInformation = 0x1000;
            IntPtr process = OpenProcess(ProcessTerminate | ProcessQueryLimitedInformation, false, (uint)processId);
            if (process == IntPtr.Zero) return false;
            try
            {
                NativeFileTime creation, exit, kernel, user;
                if (!GetProcessTimes(process, out creation, out exit, out kernel, out user)) return false;
                if (FileTimeToLong(creation) != expectedCreateTime) return false;
                return TerminateProcess(process, 1);
            }
            finally
            {
                CloseHandle(process);
            }
        }
    }
}
'@
    Add-Type -TypeDefinition $nativeSource -Language CSharp -ErrorAction Stop
}

[IO.Directory]::CreateDirectory($script:RunsBase) | Out-Null
[IO.Directory]::CreateDirectory($outputPath) | Out-Null
if (-not $PrepareTemplate) {
    $conditionDirectory = Join-Path $outputPath $Condition
    [IO.Directory]::CreateDirectory($conditionDirectory) | Out-Null
}

$reports = [Collections.Generic.List[object]]::new()
$runLimit = if ($PrepareTemplate) { 1 } else { $Runs }
for ($runNumber = 1; $runNumber -le $runLimit; $runNumber++) {
    $runReport = Invoke-BenchRun -RunCondition $runCondition -RunNumber $runNumber -IsTemplatePreparation ([bool] $PrepareTemplate) -ExecutablePath $executablePath -StartUriValue $StartUri -EffectiveSchedule $effectiveSchedule -EffectiveTimeout $effectiveTimeout -TimeoutFromAnchor ([bool] $timeoutFromAnchor) -TemplatePath $templatePath -UbolSource $ubolPath -OutputDirectory $outputPath
    $reports.Add($runReport)
    if ($PrepareTemplate) {
        Write-Host ("template status={0} media-playing={1} cleanup={2:N1}s leftovers={3}" -f $runReport.status, ($null -ne (Get-FirstEvent -Events $runReport.events -Name 'media-playing')), $runReport.cleanup.exitCleanupSeconds, $runReport.cleanup.leftovers)
    }
    else {
        $fullWs = $runReport.phases.full.meanPrivateWorkingSetMiB
        $compactWs = $runReport.phases.compact.meanPrivateWorkingSetMiB
        $full2Ws = $runReport.phases.full2.meanPrivateWorkingSetMiB
        $hiddenWs = $runReport.phases.hidden.meanPrivateWorkingSetMiB
        $media = if ($runReport.playback.passed) { 'playback=ok' } else { 'playback=FAIL' }
        Write-Host ("{0} run {1}/{2} status={3} WS-MiB full={4} compact={5} full2={6} hidden={7} CPU% full={8} compact={9} full2={10} hidden={11} startup-media-ms={12} {13} cleanup={14:N1}s leftovers={15}" -f $Condition, $runNumber, $runLimit, $runReport.status, $fullWs, $compactWs, $full2Ws, $hiddenWs, $runReport.phases.full.meanCpuPercent, $runReport.phases.compact.meanCpuPercent, $runReport.phases.full2.meanCpuPercent, $runReport.phases.hidden.meanCpuPercent, $runReport.startup.mediaPlayingMs, $media, $runReport.cleanup.exitCleanupSeconds, $runReport.cleanup.leftovers)
    }
}

if (-not $PrepareTemplate) {
    Write-ConditionSummary -ConditionName $Condition -Reports $reports.ToArray() -ConditionDirectory (Join-Path $outputPath $Condition)
    Write-Host ''
    Write-Host "Condition summary: $((Join-Path $outputPath $Condition 'summary.json'))"
    $reports | Select-Object @{ Name = 'Run'; Expression = { $_.run } }, status,
        @{ Name = 'Full WS MiB'; Expression = { $_.phases.full.meanPrivateWorkingSetMiB } },
        @{ Name = 'Compact WS MiB'; Expression = { $_.phases.compact.meanPrivateWorkingSetMiB } },
        @{ Name = 'Full2 WS MiB'; Expression = { $_.phases.full2.meanPrivateWorkingSetMiB } },
        @{ Name = 'Hidden WS MiB'; Expression = { $_.phases.hidden.meanPrivateWorkingSetMiB } },
        @{ Name = 'Full CPU %'; Expression = { $_.phases.full.meanCpuPercent } },
        @{ Name = 'Compact CPU %'; Expression = { $_.phases.compact.meanCpuPercent } },
        @{ Name = 'Full2 CPU %'; Expression = { $_.phases.full2.meanCpuPercent } },
        @{ Name = 'Hidden CPU %'; Expression = { $_.phases.hidden.meanCpuPercent } },
        @{ Name = 'Media'; Expression = { $_.playback.passed } },
        @{ Name = 'Cleanup s'; Expression = { $_.cleanup.exitCleanupSeconds } },
        @{ Name = 'Leftovers'; Expression = { $_.cleanup.leftovers } } | Format-Table -AutoSize | Out-Host
}
