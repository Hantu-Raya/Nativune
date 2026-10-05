#Requires -Version 7.0
# Read-only source composition. Missing historical harness bytes can only produce provisional diagnostics.
[CmdletBinding()]
param(
    [string] $FullRun = 'artifacts/obs-overlay/20261005T055458Z',
    [string] $Rerun = 'artifacts/obs-overlay/20261005T090303Z',
    [string] $OutputDirectory = '',
    [switch] $AllowAttestedHarness
)
$ErrorActionPreference = 'Stop'
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$checks = [Collections.Generic.List[object]]::new()
$sourceRuns = [Collections.Generic.List[object]]::new()
$selectedRows = [Collections.Generic.List[object]]::new()
$worst = $null
$limitations = @('The full-run e2e.ps1 bytes were not retained. Its identity and the reported hold-read change are attested, not independently verified; unchanged historical predicates cannot be proven. This artifact is provisional Fast diagnostic evidence, not qualification or certification.')
$expectedHarness = @{
    '20261005T055458Z' = 'cf48f1512468cb38c1ac385394bb1f59a11ceb311e39d194397137fde4d6a09d'
    '20261005T090303Z' = 'f14036cb83f26b38d58660d14c8c8b77603e1f34013658c3502b263552ba0c5a'
}
function Assert-Compose([bool] $Passed, [string] $Message) {
    if (-not $Passed) { throw $Message }
}
function Get-ComposeHash([string] $Path) {
    (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}
function Read-ComposeJson([string] $Path) {
    ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($Path)) -AsHashtable -Depth 100 -NoEnumerate
}
function Write-ComposeJson([string] $Path, $Value) {
    $json = ConvertTo-Json -InputObject $Value -Depth 100 -WarningAction Stop
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes($json + "`n")
    $stream = [IO.FileStream]::new($Path, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Add-ComposeCheck([string] $Name, $Detail) {
    $checks.Add([ordered]@{ name = $Name; status = 'pass'; detail = $Detail })
}
function Get-RepositoryPath([string] $Path) {
    $full = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $repo $Path }))
    Assert-Compose ($full.StartsWith($repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) "Path escapes repository: $Path"
    $part = $full
    while ($part -and $part -ne $repo) {
        if (Test-Path -LiteralPath $part) {
            Assert-Compose (-not ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) "Reparse point is not allowed: $part"
        }
        $part = [IO.Path]::GetDirectoryName($part)
    }
    $full
}
function Get-SourceFiles($Manifest) {
    $files = @{}
    foreach ($file in $Manifest.identity.files) {
        Assert-Compose ($file.path -and $file.sha256 -cmatch '^[a-f0-9]{64}$' -and $file.bytes -ge 0 -and -not $files.ContainsKey($file.path)) 'Invalid or duplicate manifest file identity.'
        [void] (Get-RepositoryPath $file.path)
        $files[$file.path] = $file
    }
    return $files
}
function Get-ValueHash($Value) { Get-JournalTextHash (ConvertTo-JournalCanonicalJson $Value) }
function Get-FrameInventory($Inventory) {
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($row in $Inventory.rows | Where-Object scenario -CEQ 'A-FRAMES') {
        Assert-Compose ($row.id -and $ids.Add($row.id)) 'Duplicate frame inventory row.'
        $copy = [ordered]@{}
        foreach ($key in $row.Keys) { if ($key -cne 'selected') { $copy[$key] = $row[$key] } }
        $copy
    }
}
function Read-ComposeSource([string] $Directory) {
    $directory = Get-RepositoryPath $Directory
    $manifest = Read-ComposeJson (Join-Path $directory 'manifest.json')
    Assert-Compose ($manifest.schema -eq 1 -and $manifest.identity.schema -eq 1 -and $expectedHarness.ContainsKey($manifest.runId)) 'Unsupported source run or manifest schema.'
    Assert-Compose ($manifest.identitySha256 -ceq (Get-ValueHash $manifest.identity)) "Manifest identity hash mismatch: $directory"
    $files = Get-SourceFiles $manifest
    Assert-Compose ($files['scripts/obs-overlay-e2e.ps1'].sha256 -ceq $expectedHarness[$manifest.runId]) "Unattested harness identity: $directory"
    $inventory = Read-ComposeJson (Join-Path $directory 'inventory.json')
    Assert-Compose ($inventory.version -eq $manifest.identity.inventoryVersion -and $inventory.version -eq 3 -and $inventory.protocol -ceq 'Fast-v2' -and -not $inventory.rotation -and -not $inventory.priorWorst) "Unsupported inventory: $directory"
    $report = Read-ComposeJson (Join-Path $directory 'report.json')
    $rows = Read-RunJournal $directory $manifest.runId $manifest.identitySha256
    $source = [ordered]@{ runId = $manifest.runId; directory = [IO.Path]::GetRelativePath($repo, $directory).Replace('\', '/')
        manifestSha256 = Get-ComposeHash (Join-Path $directory 'manifest.json'); identitySha256 = $manifest.identitySha256
        journalSha256 = Get-ComposeHash (Join-Path $directory 'journal.jsonl'); inventorySha256 = Get-ComposeHash (Join-Path $directory 'inventory.json')
        reportSha256 = Get-ComposeHash (Join-Path $directory 'report.json'); framesWorstSha256 = Get-ComposeHash (Join-Path $directory 'frames-worst.json') }
    $sourceRuns.Add($source)
    return @{ directory = $directory; manifest = $manifest; files = $files; inventory = $inventory; report = $report; rows = $rows; source = $source }
}
function Get-ValidatedComposeRow($Source, [string] $Id, [switch] $AllowFailure) {
    Assert-Compose ($Source.rows.ContainsKey($Id)) "Missing journal row $Id in $($Source.manifest.runId)"
    $row = $Source.rows[$Id]
    Assert-Compose ($row.complete -and $row.checks.Count -gt 0 -and ($AllowFailure -or ($row.complete.status -ceq 'pass' -and @($row.checks | Where-Object status -CNE 'pass').Count -eq 0))) "Invalid/blocked/nonpassing row $Id in $($Source.manifest.runId)"
    Assert-Compose ($row.complete.status -in @('pass', 'fail') -and @($row.checks | Where-Object status -CEQ 'blocked').Count -eq 0) "Blocked row $Id"
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($artifact in $row.complete.artifacts) {
        Assert-Compose ($paths.Add($artifact.path)) "Duplicate row artifact: $Id/$($artifact.path)"
        $path = Get-JournalArtifactPath $Source.directory $artifact.path
        Assert-Compose ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-ComposeHash $path) -ceq $artifact.sha256) "Missing/tampered row artifact: $Id/$($artifact.path)"
    }
    foreach ($reference in @((Get-RunEvidenceReferences $row.checks)) + @((Get-RunEvidenceReferences $row.complete.result))) {
        [void] (Get-ValidatedRunEvidencePath $reference $Source.directory)
        $data = Get-RunEvidenceReferenceData $reference
        Assert-Compose (@($row.complete.artifacts | Where-Object { $_.path -ceq $data.path -and $_.sha256 -ceq $data.sha256 }).Count -eq 1) "Evidence reference is not bound to row $Id"
    }
    $result = Resolve-RunEvidenceReference $row.complete.result $Source.directory
    return @{ row = $row; result = $result; evidenceSha256 = Get-ValueHash ([ordered]@{ meta = $row.meta; checks = $row.checks.ToArray(); complete = $row.complete }) }
}
function Get-ExpectedOptions($Entry) {
    $o = Copy-LookOptions (Get-ThemeDefaults $Entry.theme)
    $o.width = $Entry.width; $o.scale = $Entry.scale; $o.showTimes = $Entry.showTimes
    if ($Entry.Contains('backgroundBlur')) { $o['backgroundBlur'] = $Entry.backgroundBlur }
    return $o
}
function Get-ComposeCadence($Source, $Evidence) {
    $summary = Resolve-RunEvidenceReference $Evidence.result.cadenceEvidence $Source.directory
    if ($summary.Contains('startSequence')) { return $summary }
    Assert-Compose ($summary.artifact -and @($Evidence.row.complete.artifacts | Where-Object path -CEQ $summary.artifact).Count -eq 1) 'Cadence artifact is not bound to its source row.'
    $cadence = Read-ComposeJson (Get-JournalArtifactPath $Source.directory $summary.artifact)
    foreach ($key in @('seconds', 'qpcSeconds', 'timelineComplete', 'steadyWindow')) {
        Assert-Compose ($summary[$key] -eq $cadence[$key]) "Cadence artifact differs from its retained summary: $key"
    }
    return $cadence
}

# Failure modes: altered payload/row hashes; duplicate/omitted rows; changed inventory/windows/settings;
# stale calibration; fixture restoration/reanchors; changed thresholds; trusting a previously scored worst.
$exitCode = 1
$out = $null
$outputValidated = $false
try {
    $fullPath = Get-RepositoryPath $FullRun
    $rerunPath = Get-RepositoryPath $Rerun
    Assert-Compose ($fullPath -cne $rerunPath) 'Composition sources must differ.'
    $out = Get-RepositoryPath $(if ($OutputDirectory) { $OutputDirectory } else { 'artifacts/obs-overlay/composed-' + [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssfffffffZ') })
    $artifactRoot = Get-RepositoryPath 'artifacts/obs-overlay'
    Assert-Compose ($out.StartsWith($artifactRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        -not $out.StartsWith($fullPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        -not $out.StartsWith($rerunPath + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase) -and
        $out -ine $fullPath -and $out -ine $rerunPath -and -not (Test-Path -LiteralPath $out)) 'Output must be a new artifact directory outside both source runs.'
    $outputValidated = $true
    # This module only defines evidence helpers. Its bytes are also pinned by both source manifests below.
    . (Join-Path $PSScriptRoot 'obs-overlay-journal.ps1')
    $full = Read-ComposeSource $fullPath
    $rerunSource = Read-ComposeSource $rerunPath
    Assert-Compose ($full.manifest.runId -ceq '20261005T055458Z' -and $rerunSource.manifest.runId -ceq '20261005T090303Z') 'Source roles disagree with the authorized supersession.'
    foreach ($name in @('obs-overlay-journal.ps1', 'obs-overlay-inventory.ps1', 'obs-overlay-sizes.ps1')) {
        $key = "scripts/$name"
        Assert-Compose ($full.files[$key].sha256 -ceq $rerunSource.files[$key].sha256 -and (Get-ComposeHash (Join-Path $PSScriptRoot $name)) -ceq $full.files[$key].sha256) "Changed validation/inventory helper: $name"
    }
    $differences = @($full.files.Keys + $rerunSource.files.Keys | Sort-Object -Unique | Where-Object {
        -not $full.files.ContainsKey($_) -or -not $rerunSource.files.ContainsKey($_) -or (Get-ValueHash $full.files[$_]) -cne (Get-ValueHash $rerunSource.files[$_]) })
    Assert-Compose ($differences.Count -eq 1 -and $differences[0] -ceq 'scripts/obs-overlay-e2e.ps1') ('Unexplained product/resource/fixture/hook/harness change: ' + ($differences -join ', '))
    Assert-Compose ((Get-ValueHash $full.manifest.identity.directories) -ceq (Get-ValueHash $rerunSource.manifest.identity.directories)) 'Payload directory identity changed.'
    $payloadFiles = @($full.files.Values | Where-Object { $_.path -cnotmatch '^scripts/obs-overlay-[^/]+\.ps1$' } | Sort-Object path)
    Assert-Compose ($payloadFiles.Count -gt 0) 'Empty payload manifest.'
    foreach ($file in $payloadFiles) {
        $path = Get-RepositoryPath $file.path
        Assert-Compose ((Test-Path -LiteralPath $path -PathType Leaf) -and (Get-Item -LiteralPath $path).Length -eq $file.bytes -and (Get-ComposeHash $path) -ceq $file.sha256) "Retained product/resource payload mismatch: $($file.path)"
    }
    foreach ($directory in $full.manifest.identity.directories.Keys) {
        Assert-Compose ($full.manifest.identity.directories[$directory] -eq $true) "Missing measured payload directory: $directory"
        $actual = @(Get-ChildItem -LiteralPath (Get-RepositoryPath $directory) -Recurse -File -Force | ForEach-Object { [IO.Path]::GetRelativePath($repo, (Get-RepositoryPath $_.FullName)).Replace('\', '/') } | Sort-Object)
        $expected = @($payloadFiles | Where-Object { $_.path.StartsWith($directory + '/', [StringComparison]::Ordinal) } | ForEach-Object path | Sort-Object)
        Assert-Compose ((Get-ValueHash $actual) -ceq (Get-ValueHash $expected)) "Payload file universe changed: $directory"
    }
    Add-ComposeCheck 'payloadIdentity' @{ nonHarnessFiles = $payloadFiles.Count; payloadSha256 = Get-ValueHash $payloadFiles; differingFiles = $differences }
    foreach ($key in @('runtime', 'chromeFlags')) {
        Assert-Compose ((Get-ValueHash $full.manifest.identity[$key]) -ceq (Get-ValueHash $rerunSource.manifest.identity[$key])) "Effective $key identity changed."
    }
    foreach ($key in @('OutputDirectory', 'KeepRoot', 'CapturePlainBaseline', 'LookCase', 'Section', 'GateProfile', 'Rotation', 'ExhaustiveWorst')) {
        Assert-Compose ((Get-ValueHash $full.manifest.identity.parameters[$key]) -ceq (Get-ValueHash $rerunSource.manifest.identity.parameters[$key])) "Effective setting changed: $key"
    }
    Assert-Compose ($full.manifest.identity.parameters.FrameRow.Count -eq 1 -and $full.manifest.identity.parameters.FrameRow[0] -ceq '*' -and
        $rerunSource.manifest.identity.parameters.FrameRow.Count -eq 1 -and $rerunSource.manifest.identity.parameters.FrameRow[0] -ceq 'frames.*.pixel-max.r4.no-art') 'Unexpected source selectors.'
    Add-ComposeCheck 'runtimeAndSettingsIdentity' @{ runtimeSha256 = Get-ValueHash $full.manifest.identity.runtime; chromeFlagsSha256 = Get-ValueHash $full.manifest.identity.chromeFlags }
    $required = @(Get-FrameInventory $full.inventory)
    $rerunInventory = @(Get-FrameInventory $rerunSource.inventory)
    Assert-Compose ($required.Count -eq 127 -and (Get-ValueHash $required) -ceq (Get-ValueHash $rerunInventory)) 'The two Fast-v2 inventories differ or do not cover the authorized 127 rows.'
    Assert-Compose (@($full.inventory.rows | Where-Object { $_.scenario -ceq 'A-FRAMES' -and -not $_.selected }).Count -eq 0) 'The base run was not a full frame inventory.'
    $harnessPath = Join-Path $PSScriptRoot 'obs-overlay-e2e.ps1'
    Assert-Compose ((Get-ComposeHash $harnessPath) -ceq $expectedHarness[$rerunSource.manifest.runId]) 'Current harness differs from the retained rerun identity.'
    $tokens = $null; $parseErrors = $null
    $harnessAst = [Management.Automation.Language.Parser]::ParseFile($harnessPath, [ref] $tokens, [ref] $parseErrors)
    Assert-Compose ($parseErrors.Count -eq 0) 'Harness extraction parse failed.'
    foreach ($name in @('Get-Prop', 'Get-PageField', 'New-DefaultPillOptions', 'Get-ThemeDefaults', 'Copy-LookOptions', 'Get-CadenceAssertion')) {
        $nodes = @($harnessAst.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name }, $true))
        Assert-Compose ($nodes.Count -eq 1) "Ambiguous helper extraction: $name"
        . ([scriptblock]::Create($nodes[0].Extent.Text))
    }
    . (Join-Path $PSScriptRoot 'obs-overlay-inventory.ps1')
    $selected = @('A-FRAMES'); $script:GateProfile = 'Fast-v2'; $script:FrameRow = @('*'); $script:Section = @('*'); $script:LookCase = @('*'); $script:Rotation = ''
    $fixtureDirectory = Get-RepositoryPath 'scripts/fixtures/obs-overlay'
    $generated = @(Get-FrameInventory @{ rows = @(Get-RequiredRowInventory) })
    Assert-Compose ((Get-ValueHash $required) -ceq (Get-ValueHash $generated)) 'Recorded inventory does not match the versioned Fast-v2 generator.'
    Add-ComposeCheck 'inventory' @{ version = 3; requiredRows = $required.Count; inventoryHash = Get-ValueHash $required }
    $selectorNodes = @($harnessAst.FindAll({ param($node)
        $node -is [Management.Automation.Language.IfStatementAst] -and
        $node.Extent.Text.StartsWith("if (`$entry.class -eq 'playing' -and -not `$entry.Contains('supplemental')", [StringComparison]::Ordinal) -and
        $node.Extent.Text.Contains('$score = $area') }, $true))
    Assert-Compose ($selectorNodes.Count -eq 1) 'Existing worst selector extraction is ambiguous.'
    $selector = [scriptblock]::Create($selectorNodes[0].Extent.Text)
    $sizes = Read-ComposeJson (Join-Path $fixtureDirectory 'expected-sizes.json')
    $chosen = @{}; $validated = @{}; $pausedExtensions = [Collections.Generic.List[string]]::new()
    foreach ($entry in $required) {
        $rerunEntry = @($rerunSource.inventory.rows | Where-Object id -CEQ $entry.id)
        Assert-Compose ($rerunEntry.Count -eq 1) "Missing/duplicate rerun inventory row: $($entry.id)"
        $source = if ($rerunEntry[0].selected) { $rerunSource } else { $full }
        $evidence = Get-ValidatedComposeRow $source $entry.id
        $record = $evidence.result
        if ($entry.class -in @('playing', 'pixel')) {
            Assert-Compose ($record -and (Get-ValueHash $record.options) -ceq (Get-ValueHash (Get-ExpectedOptions $entry)) -and
                $record.rate -eq $entry.rate -and $record.theme -ceq $entry.theme -and $record.condition -ceq $entry.condition) "Row options/fixture differ from inventory: $($entry.id)"
            Assert-Compose ($record.frameMeasurement.measured -eq $true -and $record.frameMeasurement.ceiling -eq 1.3 -and
                $record.frameMeasurement.exceeded -eq $false -and $record.o3Trigger -eq $false -and $record.trace.visible -eq $true -and
                $record.trace.seconds -ge $entry.windowSeconds - 0.5 -and $record.trace.frameEvent -ceq 'EndActivateToSubmitCompositorFrame:e' -and
                $record.trace.frames / $record.trace.seconds -le 1.3) "Invalid measured frame window/ceiling: $($entry.id)"
            $cadence = Get-ComposeCadence $source $evidence
            $recomputed = Get-CadenceAssertion $record.start $record.end $entry.theme $entry.showTimes $entry.rate $record.cadenceAssertion.barPx $record.duration $cadence.seconds
            Assert-Compose ($record.cadenceAssertion.passed -eq $true -and $recomputed.passed -eq $true -and
                $recomputed.maxFill -eq $record.maxFillWrites -and $recomputed.maxTicks -eq $record.maxTicks) "Cadence/threshold mismatch: $($entry.id)"
        }
        $chosen[$entry.id] = $source
        $validated[$entry.id] = $evidence
        $selectedRows.Add([ordered]@{ rowId = $entry.id; sourceRun = $source.manifest.runId; attempt = $evidence.row.complete.attempt
            evidenceSha256 = $evidence.evidenceSha256; resultSha256 = Get-ValueHash $record; artifacts = @($evidence.row.complete.artifacts) })
        $theme = $entry.theme; $rowId = $entry.id; $GateProfile = 'Fast-v2'
        . $selector
        if ($entry.class -eq 'idle' -and $theme -ne 'pill' -and ($record.trace.frames -ne 0 -or $record.ticks -ne 0)) { $pausedExtensions.Add($theme) }
    }
    foreach ($entry in $required | Where-Object { $_.class -in @('shared-cadence', 'shared-network') }) {
        Assert-Compose ($chosen[$entry.id].manifest.runId -ceq $chosen[$entry.sourceRow].manifest.runId) "Shared assertion is not from its selected source row: $($entry.id)"
        $field = if ($entry.class -eq 'shared-cadence') { 'cadenceAssertion' } else { 'networkAssertion' }
        Assert-Compose ((Get-ValueHash $validated[$entry.id].result) -ceq (Get-ValueHash $validated[$entry.sourceRow].result[$field])) "Shared assertion result differs from source: $($entry.id)"
    }
    Add-ComposeCheck 'selectedUnion' @{ required = $required.Count; selected = $selectedRows.Count; fullRun = @($selectedRows | Where-Object sourceRun -CEQ $full.manifest.runId).Count; rerun = @($selectedRows | Where-Object sourceRun -CEQ $rerunSource.manifest.runId).Count; missingIds = @() }
    foreach ($entry in $required | Where-Object class -CEQ 'mutant') {
        Assert-Compose ($chosen[$entry.id].manifest.runId -ceq $rerunSource.manifest.runId) "Calibration was not freshly rerun: $($entry.id)"
        $name = $entry.id.Substring('frames.mutant.'.Length)
        $sample = Read-ComposeJson (Get-JournalArtifactPath $rerunSource.directory "frames-mutant-$name.json")
        Assert-Compose ($sample.visible -eq $true -and $sample.frameEvent -ceq 'EndActivateToSubmitCompositorFrame:e' -and $sample.seconds -ge 59.5) "Invalid calibration trace: $name"
        if ($name -in @('ceiling-low', 'ceiling-high')) {
            $rate = if ($name -ceq 'ceiling-low') { 1.2 } else { 1.4 }
            Assert-Compose ($sample.targetMutationFps -eq $rate -and $sample.mutationCountTolerance -eq 2 -and
                [Math]::Abs($sample.mutationCount - $rate * $sample.seconds) -le 2 -and $sample.ticks -eq 0 -and $sample.fillWrites -eq 0 -and $sample.timeWrites -eq 0 -and
                (Get-PageField $sample.startPage 'fillTimer') -eq 0 -and (Get-PageField $sample.endPage 'fillTimer') -eq 0 -and $sample.endPage.running -eq 0 -and
                $(if ($name -ceq 'ceiling-low') { $sample.frames -gt 0 -and $sample.fps -le 1.3 -and $sample.oracleAccepted -eq $true } else { $sample.fps -gt 1.3 -and $sample.oracleAccepted -eq $false })) "Calibration guard failed recomputation: $name"
        } else { Assert-Compose ($sample.fps -ge 10 -and $sample.fps -gt 1.3) "Legacy mutant guard failed recomputation: $name" }
    }
    Add-ComposeCheck 'freshCalibration' @{ sourceRun = $rerunSource.manifest.runId; guards = 4 }
    foreach ($entry in $required | Where-Object class -CEQ 'pixel') {
        $record = $validated[$entry.id].result
        $fixture = $record.syntheticMetadata.fixture
        Assert-Compose ($chosen[$entry.id].manifest.runId -ceq $rerunSource.manifest.runId -and $record.syntheticMetadata.applied -eq $true -and
            $record.syntheticMetadata.retainedDuration -eq 14400 -and $record.syntheticMetadata.retainedRate -eq 4 -and
            $fixture.readHeld -eq $true -and $fixture.holdQpc -gt 0 -and $fixture.setup.stableMilliseconds -ge 1000 -and
            $fixture.startValid -eq $true -and $fixture.endValid -eq $true -and $fixture.steadyWindow -eq $true -and
            $fixture.reanchors -eq 0 -and $fixture.dataAnchorUnchanged -eq $true -and $fixture.lookAnchorUnchanged -eq $true -and
            $fixture.progressOk -eq $true -and $fixture.steppedProgressOk -eq $true -and $fixture.noArtRefetchOk -eq $true -and $fixture.passed -eq $true) "Rerun fixture/cadence evidence missing or invalid: $($entry.id)"
        foreach ($page in @($record.start, $record.end)) {
            Assert-Compose ($page.nativeFixture.duration -eq 14400 -and $page.nativeFixture.rate -eq 4 -and $page.nativeFixture.clock -eq $true -and
                $null -eq $page.nativeFixture.requestedArt -and $null -eq $page.nativeFixture.loadedArt -and
                $page.title -ceq 'Sample song' -and $page.artist -ceq 'Sample artist') "Fixture restoration/identity change: $($entry.id)"
        }
        $cadence = Get-ComposeCadence $rerunSource $validated[$entry.id]
        Assert-Compose ($cadence.timelineComplete -eq $true -and $cadence.steadyWindow -eq $true -and $cadence.reanchors.Count -eq 0 -and
            $cadence.windowTimeline.Count -eq $cadence.endSequence - $cadence.startSequence -and
            [Math]::Abs(($record.end.nativeFixture.projectedPosition - $record.start.nativeFixture.projectedPosition) - 4 * $cadence.seconds) -le 2 -and
            $record.trace.frames -le $record.fillWrites + 1) "Scored synthetic fixture/cadence drift: $($entry.id)"
    }
    Add-ComposeCheck 'rerunFixtureCadence' @{ rows = 8; duration = 14400; rate = 4; windowSeconds = 120; ceiling = 1.3 }
    $failedId = 'frames.matte.pixel-max.r4.no-art'
    $original = Get-ValidatedComposeRow $full $failedId -AllowFailure
    Assert-Compose ($original.row.complete.status -ceq 'fail') 'The original matte failure was not preserved.'
    $nonpassing = @($required | Where-Object { $full.rows[$_.id].complete.status -cne 'pass' })
    Assert-Compose ($nonpassing.Count -eq 1 -and $nonpassing[0].id -ceq $failedId) 'Additional unexplained base frame failures exist.'
    $supersessions = @([ordered]@{ rowId = $failedId; originalRun = $full.manifest.runId; replacementRun = $rerunSource.manifest.runId
        originalStatus = 'fail'; originalEvidenceSha256 = $original.evidenceSha256; replacementEvidenceSha256 = $validated[$failedId].evidenceSha256
        originalArtifacts = @($original.row.complete.artifacts); replacementArtifacts = @($validated[$failedId].row.complete.artifacts)
        harnessChangeReport = 'agent://R10Hold'; authorization = 'orchestrator + GPT-6.1-Sol medium'; reason = 'Authorized hold-read fixture fix supersession; historical harness-only diff is attested, not proven.' })
    Assert-Compose ($worst -and $selectedRows.Count -eq $required.Count) 'Worst selection or union is incomplete.'
    Add-ComposeCheck 'worstRecomputed' @{ rowId = $worst.rowId; score = $worst.score; candidates = @($required | Where-Object { $_.class -ceq 'playing' -and -not $_.Contains('supplemental') }).Count }
    # Recheck durable source files before emitting anything. Source runs are never edited or copied.
    foreach ($source in @($full, $rerunSource)) {
        foreach ($pair in @(@('manifest.json', 'manifestSha256'), @('journal.jsonl', 'journalSha256'), @('inventory.json', 'inventorySha256'), @('report.json', 'reportSha256'), @('frames-worst.json', 'framesWorstSha256'))) {
            Assert-Compose ((Get-ComposeHash (Join-Path $source.directory $pair[0])) -ceq $source.source[$pair[1]]) "Source changed during composition: $($source.manifest.runId)/$($pair[0])"
        }
    }
    Assert-Compose ([bool] $AllowAttestedHarness) 'Conditions 2/5 cannot be fully verified: original harness bytes were not retained. Use -AllowAttestedHarness only for the explicitly authorized provisional Fast diagnostics.'
    $provenance = [ordered]@{ version = 1; kind = 'Fast-v2-composed'; sourceRuns = $sourceRuns.ToArray(); selectedRows = $selectedRows.ToArray()
        payloadIdentical = $true; payloadSha256 = Get-ValueHash $payloadFiles; runtimeSha256 = Get-ValueHash $full.manifest.identity.runtime
        harnessIdentity = 'attested'; originalHarnessBytesRetained = $false; harnessChangeReport = 'agent://R10Hold'
        harnessHashes = [ordered]@{ fullRun = $expectedHarness[$full.manifest.runId]; rerun = $expectedHarness[$rerunSource.manifest.runId] }
        inventory = [ordered]@{ profile = 'Fast-v2'; version = 3; hash = Get-ValueHash $required; requiredRowIds = @($required | ForEach-Object id) }
        calibration = [ordered]@{ sourceRun = $rerunSource.manifest.runId; rowIds = @($required | Where-Object class -CEQ 'mutant' | ForEach-Object id) }
        supersessions = $supersessions; selector = [ordered]@{ sourceFunction = 'Test-AFrames'; harnessSha256 = Get-ComposeHash $harnessPath
            codeSha256 = Get-JournalTextHash $selectorNodes[0].Extent.Text; candidateRowIds = @($required | Where-Object { $_.class -ceq 'playing' -and -not $_.Contains('supplemental') } | ForEach-Object id) }
        limitations = $limitations }
    $artifact = [ordered]@{ version = 2; protocol = 'Fast-v2'; scope = 'Fast-v2 composed provisional observed'; worstDescription = 'worst observed in the selected Fast-v2 union (provisional)'
        worst = $worst; pausedExtensions = @($pausedExtensions | Select-Object -Unique); missingIds = @(); coverageComplete = $true
        qualificationComplete = $false; profileComplete = $false; complete = $false; framesGreen = $false; exhaustiveComplete = $false; provenance = $provenance }
    [void] [IO.Directory]::CreateDirectory($out)
    Write-ComposeJson (Join-Path $out 'frames-worst.json') $artifact
    $exitCode = 0
} catch {
    $checks.Add([ordered]@{ name = 'compositionBlocked'; status = 'blocked'; detail = $_.Exception.Message })
}
if ($outputValidated -and -not (Test-Path -LiteralPath (Join-Path $out 'compose-report.json'))) {
    # Only a fresh validated output path can receive a report, including a blocked report.
    if (-not (Test-Path -LiteralPath $out)) { [void] [IO.Directory]::CreateDirectory($out) }
    if ($out -ine $fullPath -and $out -ine $rerunPath -and $out.StartsWith($artifactRoot + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        $report = [ordered]@{ version = 1; utc = [DateTime]::UtcNow.ToString('o'); status = $(if ($exitCode -eq 0) { 'provisional' } else { 'blocked' })
            command = 'pwsh -NoProfile -File scripts/obs-overlay-frames-compose.ps1' + $(if ($AllowAttestedHarness) { ' -AllowAttestedHarness' } else { '' })
            sourceRuns = $sourceRuns.ToArray(); checks = $checks.ToArray(); coverageComplete = [bool] ($exitCode -eq 0); qualificationComplete = $false
            qualificationBlockedConditions = @(2, 5); limitations = $limitations; worst = $(if ($exitCode -eq 0) { $worst } else { $null })
            framesWorstSha256 = $(if ($exitCode -eq 0) { Get-ComposeHash (Join-Path $out 'frames-worst.json') } else { $null }) }
        Write-ComposeJson (Join-Path $out 'compose-report.json') $report
    }
}
[ordered]@{ outputDirectory = $out; status = $(if ($exitCode -eq 0) { 'provisional' } else { 'blocked' }); checks = $checks.ToArray(); worst = $(if ($exitCode -eq 0) { $worst } else { $null }) } | ConvertTo-Json -Depth 8
exit $exitCode
