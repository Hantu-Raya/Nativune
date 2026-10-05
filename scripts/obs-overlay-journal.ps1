# Dot-sourced by obs-overlay-e2e.ps1. Append-only evidence; resume never edits the source run.
$script:journalPath = ''
$script:currentRowId = ''
$script:journalRows = @{}
$script:resumeRows = @{}
$script:resumeDirectory = ''
$script:resumeRunId = ''
$script:evidenceSequence = 0
$script:evidenceRunKey = [Guid]::NewGuid().ToString('N')

# "Compressed" means minified JSON, not gzip: retain values below 32 KiB of UTF-8.
# Full evidence uses the same depth as the journal; serialization warnings fail, never truncate.
function Get-RunEvidenceReferenceData($Value) {
    if ($Value -is [Collections.IDictionary] -and $Value.Contains('evidenceRef')) { return $Value.evidenceRef }
    if ($Value -is [pscustomobject] -and $Value.PSObject.Properties['evidenceRef']) { return $Value.evidenceRef }
}
function Get-RunEvidenceReferences($Value) {
    if (($Value -is [Collections.IDictionary] -and $Value.Contains('evidenceRef')) -or
        ($Value -is [pscustomobject] -and $Value.PSObject.Properties['evidenceRef'])) { return ,$Value }
    if ($Value -is [Collections.IDictionary]) {
        foreach ($item in $Value.Values) { Get-RunEvidenceReferences $item }
    } elseif ($Value -is [pscustomobject]) {
        foreach ($property in $Value.PSObject.Properties) { Get-RunEvidenceReferences $property.Value }
    } elseif ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        foreach ($item in $Value) { Get-RunEvidenceReferences $item }
    }
}
function Register-RunEvidenceReference($Value) {
    if ($script:currentRowId) {
        $reference = Get-RunEvidenceReferenceData $Value
        $script:journalRows[$script:currentRowId].evidenceReferences[$reference.path] = $Value
    }
}
function Get-ValidatedRunEvidencePath {
    param($Value, [string] $Directory = $runDirectory)
    $reference = Get-RunEvidenceReferenceData $Value
    if ($null -eq $reference -or ($reference -isnot [Collections.IDictionary] -and $reference -isnot [pscustomobject]) -or
        -not $reference.path -or [IO.Path]::IsPathRooted([string] $reference.path) -or
        $reference.sha256 -cnotmatch '^[a-f0-9]{64}$' -or $reference.format -cne 'json' -or $reference.version -ne 1 -or
        ($reference.bytes -isnot [int] -and $reference.bytes -isnot [long]) -or $reference.bytes -lt 0) {
        throw 'Invalid run evidence reference.'
    }
    $summary = if ($Value -is [Collections.IDictionary]) {
        if ($Value.Contains('summary')) { $Value.summary } else { $null }
    } elseif ($Value.PSObject.Properties['summary']) { $Value.summary } else { $null }
    $summaryJson = ConvertTo-Json -InputObject $summary -Depth 100 -Compress -WarningAction Stop
    if ([Text.Encoding]::UTF8.GetByteCount($summaryJson) -gt 8192) { throw "Evidence summary exceeds 8 KiB: $($reference.path)" }
    $path = Get-JournalArtifactPath $Directory ([string] $reference.path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing run evidence: $($reference.path)" }
    $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($file.Length -ne $reference.bytes -or
        (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() -cne $reference.sha256) {
        throw "Tampered run evidence: $($reference.path)"
    }
    return $path
}
function New-RunEvidenceReference {
    param([string] $RelativePath, $Summary = $null)
    if (-not $RelativePath -or [IO.Path]::IsPathRooted($RelativePath)) { throw 'Evidence path must be relative to the run directory.' }
    $path = Get-JournalArtifactPath $runDirectory $RelativePath
    $file = Get-Item -LiteralPath $path -Force -ErrorAction Stop
    if ($file.PSIsContainer) { throw "Evidence must be a file: $RelativePath" }
    # Caller summaries are bounded too, so a new megagraph cannot hide in the wrapper.
    $summaryJson = ConvertTo-Json -InputObject $Summary -Depth 100 -Compress -WarningAction Stop
    if ([Text.Encoding]::UTF8.GetByteCount($summaryJson) -gt 8192) { throw "Evidence summary exceeds 8 KiB: $RelativePath" }
    $value = [ordered]@{ evidenceRef = [ordered]@{
        path = [IO.Path]::GetRelativePath($runDirectory, $path).Replace('\', '/')
        sha256 = (Get-FileHash -LiteralPath $path -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant()
        bytes = $file.Length; format = 'json'; version = 1 }; summary = $Summary }
    Register-RunEvidenceReference $value
    return $value
}
function ConvertTo-RunEvidenceReference {
    param($Value, [string] $Label, $Summary = $null)
    $references = @(Get-RunEvidenceReferences $Value)
    foreach ($reference in $references) {
        [void] (Get-ValidatedRunEvidencePath $reference)
        Register-RunEvidenceReference $reference
    }
    if ($null -ne (Get-RunEvidenceReferenceData $Value)) { return ,$Value }
    $json = ConvertTo-Json -InputObject $Value -Depth 100 -Compress -WarningAction Stop
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    if ($bytes.Length -lt 32768) { return ,$Value }
    $labelPart = ($Label -replace '[^a-zA-Z0-9._-]', '-')
    if (-not $labelPart) { $labelPart = 'payload' }
    if ($labelPart.Length -gt 80) { $labelPart = $labelPart.Substring(0, 80) }
    if ($null -eq $Summary) { $Summary = [ordered]@{ label = $labelPart; externalized = $true } }
    $script:evidenceSequence++
    $relative = 'evidence/{0}-{1:D6}-{2}.json' -f $script:evidenceRunKey, $script:evidenceSequence, $labelPart
    $path = Get-JournalArtifactPath $runDirectory $relative
    $temporary = $path + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        [void] [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
        $stream = [IO.FileStream]::new($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        [IO.File]::Move($temporary, $path)
        return New-RunEvidenceReference -RelativePath $relative -Summary $Summary
    } catch {
        throw "Cannot write run evidence '${relative}': $($_.Exception.Message)"
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}
function Resolve-RunEvidenceReference {
    param($Value, [string] $Directory = $runDirectory)
    if (-not (($Value -is [Collections.IDictionary] -and $Value.Contains('evidenceRef')) -or
        ($Value -is [pscustomobject] -and $Value.PSObject.Properties['evidenceRef']))) { return ,$Value }
    $path = Get-ValidatedRunEvidencePath $Value $Directory
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    $bytes = [IO.File]::ReadAllBytes($path)
    $reference = Get-RunEvidenceReferenceData $Value
    if ($bytes.Length -ne $reference.bytes -or
        [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() -cne $reference.sha256) {
        throw "Run evidence changed during resolution: $($reference.path)"
    }
    return ,(ConvertFrom-Json -InputObject $utf8.GetString($bytes) -AsHashtable -NoEnumerate -Depth 100 -ErrorAction Stop)
}

function ConvertTo-JournalCanonicalValue($Value) {
    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) { $ordered[$key] = ConvertTo-JournalCanonicalValue $Value[$key] }
        return $ordered
    }
    if ($Value -is [Collections.IEnumerable] -and $Value -isnot [string]) {
        $items = @($Value | ForEach-Object { ConvertTo-JournalCanonicalValue $_ })
        return ,$items
    }
    return $Value
}
function ConvertTo-JournalCanonicalJson($Value) {
    ConvertTo-Json -InputObject (ConvertTo-JournalCanonicalValue $Value) -Depth 100 -Compress
}
function Get-JournalTextHash([string] $Text) {
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text))).ToLowerInvariant()
}
function Write-JournalRecord([Collections.IDictionary] $Record) {
    if (-not $script:journalPath) { return }
    $Record['utc'] = [DateTime]::UtcNow.ToString('o')
    $Record['qpc'] = [Diagnostics.Stopwatch]::GetTimestamp()
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Record -Depth 100 -Compress) + "`n")
    # Open per record so neither normal exit nor forced interruption needs a shutdown hook.
    $stream = [IO.FileStream]::new($script:journalPath, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
}
function Get-JournalFileIdentity([string] $Path) {
    $file = Get-Item -LiteralPath $Path -Force
    [ordered]@{ path = [IO.Path]::GetRelativePath($repo, $file.FullName).Replace('\', '/'); bytes = $file.Length
        sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
}
function Get-JournalRuntimeIdentity {
    $evergreen = [ordered]@{}
    foreach ($key in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}',
        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}')) {
        $pv = Get-ItemPropertyValue -LiteralPath $key -Name pv -ErrorAction SilentlyContinue
        $evergreen[$key] = [string] $pv
    }
    $fixed = @()
    foreach ($directory in @($appDirectory, $releaseDirectory)) {
        if (Test-Path -LiteralPath $directory -PathType Container) {
            $fixed += @(Get-ChildItem -LiteralPath $directory -Filter msedgewebview2.exe -Recurse -File -Force | Sort-Object FullName |
                ForEach-Object { [ordered]@{ path = [IO.Path]::GetRelativePath($repo, $_.FullName).Replace('\', '/'); version = $_.VersionInfo.ProductVersion } })
        }
    }
    $chrome = if (Test-Path -LiteralPath $chromeExe -PathType Leaf) { (Get-Item -LiteralPath $chromeExe).VersionInfo.ProductVersion } else { 'missing' }
    [ordered]@{ chrome = $chrome; webView2 = $evergreen; fixedWebView2 = $fixed
        os = [Environment]::OSVersion.VersionString; architecture = [Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString()
        processors = [Environment]::ProcessorCount; machine = [Environment]::MachineName; elevated = [bool] $isElevated
        # Hash environment overrides: arguments can contain private proxy/user paths.
        webViewEnvironmentSha256 = [ordered]@{ browserExecutableFolder = Get-JournalTextHash ([string] [Environment]::GetEnvironmentVariable('WEBVIEW2_BROWSER_EXECUTABLE_FOLDER'))
            additionalBrowserArguments = Get-JournalTextHash ([string] [Environment]::GetEnvironmentVariable('WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS'))
            releaseChannelPreference = Get-JournalTextHash ([string] [Environment]::GetEnvironmentVariable('WEBVIEW2_RELEASE_CHANNEL_PREFERENCE')) } }
}
function Get-JournalArtifactPath([string] $Directory, [string] $Path) {
    $base = [IO.Path]::GetFullPath($Directory).TrimEnd('\', '/')
    $full = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($Path)) { $Path } else { Join-Path $base $Path }))
    if (-not $full.StartsWith($base + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Journal artifact escapes run directory: $Path"
    }
    $part = $full
    while ($part) {
        if (Test-Path -LiteralPath $part) {
            if ((Get-Item -LiteralPath $part -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Journal artifact uses a reparse point: $Path" }
        }
        if ($part -eq $base) { break }
        $part = [IO.Path]::GetDirectoryName($part)
    }
    return $full
}
function Read-RunJournal([string] $Directory, [string] $ExpectedRunId = '', [string] $ExpectedManifestHash = '') {
    $path = Join-Path $Directory 'journal.jsonl'
    $bytes = [IO.File]::ReadAllBytes($path)
    $utf8 = [Text.UTF8Encoding]::new($false, $true)
    try { $text = $utf8.GetString($bytes) } catch {
        # A partial UTF-8 code point is allowed only in the final unterminated record.
        $lastNewline = [Array]::LastIndexOf($bytes, [byte] 10)
        $text = $utf8.GetString($bytes, 0, $lastNewline + 1) + '{'
    }
    $lines = $text.Split("`n")
    $last = $lines.Length - 1
    if ($text.EndsWith("`n")) { $last-- }
    $rows = @{}
    $active = ''
    $started = $false
    for ($i = 0; $i -le $last; $i++) {
        try { $record = ConvertFrom-Json -InputObject $lines[$i] -AsHashtable -Depth 100 -ErrorAction Stop }
        catch {
            if ($i -eq $last -and -not $text.EndsWith("`n")) { break }
            throw "Damaged journal record $($i + 1) in ${path}: $($_.Exception.Message)"
        }
        if ($record -isnot [Collections.IDictionary] -or -not $record.Contains('type') -or
            -not $record.Contains('utc') -or -not $record.Contains('qpc')) { throw "Invalid journal record $($i + 1) in $path" }
        if ($i -eq 0 -and $record.type -ne 'run-start') { throw "Journal must begin with run-start: $path" }
        switch ($record.type) {
            'run-start' {
                if ($i -ne 0 -or -not $record.runId -or $record.manifestSha256 -notmatch '^[a-f0-9]{64}$' -or
                    ($ExpectedRunId -and $record.runId -cne $ExpectedRunId) -or
                    ($ExpectedManifestHash -and $record.manifestSha256 -cne $ExpectedManifestHash)) { throw "Invalid run-start in $path" }
                $started = $true
            }
            'resume' {
                if (-not $record.sourceRunId -or -not $record.sourceDirectory -or $record.sourceJournalSha256 -notmatch '^[a-f0-9]{64}$') {
                    throw "Invalid resume provenance in $path"
                }
            }
            'row-start' {
                if (-not $record.id -or $record.attempt -isnot [long] -and $record.attempt -isnot [int] -or
                    $record.attempt -lt 1 -or $record.meta -isnot [Collections.IDictionary]) { throw "Invalid row-start in $path" }
                if ($rows.ContainsKey($record.id) -and $record.attempt -le $rows[$record.id].attempt) { throw "Non-increasing row attempt in $path" }
                $active = [string] $record.id
                $rows[$active] = @{ attempt = $record.attempt; meta = $record.meta; checks = [Collections.Generic.List[object]]::new(); complete = $null }
            }
            'check' {
                if (-not $record.name -or $record.status -notin @('pass', 'fail', 'blocked', 'deferred:P1', 'deferred:P2') -or
                    -not $record.Contains('id') -or -not $record.Contains('attempt') -or
                    -not $record.Contains('expected') -or -not $record.Contains('observed')) { throw "Invalid check in $path" }
                if ($record.id) {
                    if ($record.id -ne $active -or -not $rows.ContainsKey($active) -or $record.attempt -ne $rows[$active].attempt -or
                        $rows[$active].complete) { throw "Check outside its row attempt in $path" }
                    $check = [ordered]@{ name = $record.name; expected = $record.expected; observed = $record.observed; status = $record.status }
                    if ($record.Contains('reused')) { $check['reused'] = $record.reused }
                    $rows[$active].checks.Add($check)
                } elseif ($active -or $record.attempt -ne 0) { throw "Unscoped check during a row in $path" }
            }
            'row-complete' {
                if (-not $record.id -or $record.id -ne $active -or -not $rows.ContainsKey($active) -or
                    $record.attempt -ne $rows[$active].attempt -or $rows[$active].complete -or
                    $record.status -notin @('pass', 'fail', 'blocked') -or -not $record.Contains('result') -or
                    $record.artifacts -isnot [Collections.IList]) { throw "Invalid row-complete in $path" }
                foreach ($artifact in $record.artifacts) {
                    if ($artifact -isnot [Collections.IDictionary] -or -not $artifact.path -or $artifact.sha256 -notmatch '^[a-f0-9]{64}$') {
                        throw "Invalid artifact in $path"
                    }
                    [void] (Get-JournalArtifactPath $Directory $artifact.path)
                    if ($artifact.Contains('evidence') -and ($artifact.evidence -isnot [bool] -or
                        ($artifact.evidence -and (-not $artifact.Contains('bytes') -or
                        ($artifact.bytes -isnot [int] -and $artifact.bytes -isnot [long]) -or $artifact.bytes -lt 0)))) {
                        throw "Invalid evidence artifact in $path"
                    }
                }
                if ($record.status -eq 'pass' -and ($rows[$active].checks.Count -eq 0 -or
                    @($rows[$active].checks | Where-Object { $_.status -ne 'pass' }).Count -gt 0)) { throw "Passing row contains non-passing checks in $path" }
                $rows[$active].complete = $record
                $active = ''
            }
            default { throw "Unknown journal record type '$($record.type)' in $path" }
        }
    }
    if (-not $started) { throw "Journal has no durable run-start: $path" }
    return $rows
}
function Initialize-RunJournal {
    param([Collections.IDictionary] $BoundParameters = @{})
    $files = [Collections.Generic.List[object]]::new()
    $payloads = [ordered]@{}
    foreach ($directory in @($appDirectory, $releaseDirectory, $fixtureDirectory, $ubolSource)) {
        $relative = [IO.Path]::GetRelativePath($repo, $directory).Replace('\', '/')
        $payloads[$relative] = Test-Path -LiteralPath $directory -PathType Container
        if ($payloads[$relative]) {
            foreach ($entry in @(Get-ChildItem -LiteralPath $directory -Recurse -Force | Sort-Object FullName)) {
                if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Manifest payload contains a reparse point: $($entry.FullName)" }
                if (-not $entry.PSIsContainer) { $files.Add((Get-JournalFileIdentity $entry.FullName)) }
            }
        }
    }
    foreach ($file in @(Get-ChildItem -LiteralPath $PSScriptRoot -Filter 'obs-overlay-*.ps1' -File -Force | Sort-Object FullName)) { $files.Add((Get-JournalFileIdentity $file.FullName)) }
    $files.Add((Get-JournalFileIdentity (Join-Path $repo 'src/Nativune/DiscordFixturePage.html')))
    $bound = [ordered]@{}
    foreach ($key in @($BoundParameters.Keys | Sort-Object -CaseSensitive)) {
        # Resume and SkipPublish only steer this invocation; the published payload itself is pinned by file hashes above.
        if ($key -in @('Resume', 'SkipPublish')) { continue }
        $bound[$key] = if ($BoundParameters[$key] -is [Management.Automation.SwitchParameter]) { [bool] $BoundParameters[$key] } else { $BoundParameters[$key] }
    }
    # Effective profile values are recorded even when defaulted, so a resume can't mix profiles or prior-worst pointers.
    $pointerPath = Join-Path $fixtureDirectory 'exhaustive-worst.json'
    $exhaustiveWorst = if (Test-Path -LiteralPath $pointerPath -PathType Leaf) { Get-JournalFileIdentity $pointerPath } else { $null }
    $identity = [ordered]@{ schema = 1; inventoryVersion = $script:rowInventoryVersion
        files = @($files | Sort-Object { $_.path }); directories = $payloads; runtime = Get-JournalRuntimeIdentity
        chromeFlags = [ordered]@{ launch = (Get-Command Start-Chrome -CommandType Function).ScriptBlock.ToString(); plain = $plainChromeFlags }
        boundParameters = $bound; parameters = [ordered]@{ Scenario = $Scenario; OutputDirectory = $OutputDirectory
            KeepRoot = [bool] $KeepRoot; CapturePlainBaseline = [bool] $CapturePlainBaseline
            LookCase = $LookCase; Section = $Section; FrameRow = $FrameRow; LookGroup = $LookGroup
            GateProfile = $GateProfile; Rotation = $Rotation; ExhaustiveWorst = $exhaustiveWorst } }
    $canonical = ConvertTo-JournalCanonicalJson $identity
    $manifest = [ordered]@{ schema = 1; runId = $runId; utc = [DateTime]::UtcNow.ToString('o')
        identitySha256 = Get-JournalTextHash $canonical; identity = $identity }
    if ($Resume) {
        $source = [IO.Path]::GetFullPath($(if ([IO.Path]::IsPathRooted($Resume)) { $Resume } else { Join-Path $repo $Resume }))
        if ($source.TrimEnd('\', '/') -eq [IO.Path]::GetFullPath($runDirectory).TrimEnd('\', '/')) { throw 'Resume source must be a previous run directory.' }
        $previous = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText((Join-Path $source 'manifest.json'))) -AsHashtable -Depth 100
        $previousCanonical = ConvertTo-JournalCanonicalJson $previous.identity
        if ($previous.schema -ne 1 -or -not $previous.runId -or $previous.identitySha256 -ne (Get-JournalTextHash $previousCanonical) -or
            $previousCanonical -cne $canonical) { throw "Resume manifest mismatch: $source. Payloads, fixtures, runtime, flags, parameters and inventory must match exactly (except Resume)." }
        $script:resumeRows = Read-RunJournal $source $previous.runId $previous.identitySha256
        $script:resumeDirectory = $source
        $script:resumeRunId = [string] $previous.runId
    }
    $manifestPath = Join-Path $runDirectory 'manifest.json'
    $path = Join-Path $runDirectory 'journal.jsonl'
    if ((Test-Path -LiteralPath $manifestPath) -or (Test-Path -LiteralPath $path)) { throw "Run evidence already exists: $runDirectory" }
    [IO.File]::WriteAllText($manifestPath, (ConvertTo-Json -InputObject $manifest -Depth 100), [Text.UTF8Encoding]::new($false))
    $script:journalPath = $path
    Write-JournalRecord ([ordered]@{ type = 'run-start'; runId = $runId; manifestSha256 = $manifest.identitySha256 })
    if ($Resume) {
        Write-JournalRecord ([ordered]@{ type = 'resume'; sourceRunId = $script:resumeRunId; sourceDirectory = $script:resumeDirectory
            sourceJournalSha256 = (Get-FileHash -LiteralPath (Join-Path $script:resumeDirectory 'journal.jsonl') -Algorithm SHA256).Hash.ToLowerInvariant() })
    }
}
function Get-JournalArtifactSnapshot {
    $snapshot = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $runDirectory -Recurse -File -Force)) {
        if ($file.Name -in @('manifest.json', 'journal.jsonl', 'timings.jsonl', 'report.json', 'events.json')) { continue }
        $snapshot[$file.FullName] = "$($file.Length):$($file.LastWriteTimeUtc.Ticks)"
    }
    return $snapshot
}
function Start-JournalRow {
    param([string] $Id, [hashtable] $Meta = @{})
    if (-not $Id) { throw 'Journal row id cannot be empty.' }
    if (-not $script:journalPath) { throw 'Run journal has not been initialized.' }
    # Starting another row leaves the previous attempt interrupted, never reusable.
    $attempt = if ($script:journalRows.ContainsKey($Id)) { $script:journalRows[$Id].attempt + 1 } elseif ($script:resumeRows.ContainsKey($Id)) { $script:resumeRows[$Id].attempt + 1 } else { 1 }
    $row = @{ attempt = $attempt; meta = $Meta; checks = [Collections.Generic.List[object]]::new(); complete = $null
        snapshot = Get-JournalArtifactSnapshot; evidenceReferences = @{} }
    Write-JournalRecord ([ordered]@{ type = 'row-start'; id = $Id; attempt = $attempt; meta = $Meta })
    $script:journalRows[$Id] = $row
    $script:currentRowId = $Id
}
function Add-JournalCheck([Collections.IDictionary] $Check) {
    # Mutate the same object Add-Check retains; compact before either durable or in-memory retention.
    $Check['observed'] = ConvertTo-RunEvidenceReference -Value $Check.observed -Label ([string] $Check.name)
    $record = [ordered]@{ type = 'check'; id = $script:currentRowId; attempt = 0 }
    foreach ($key in $Check.Keys) { $record[$key] = $Check[$key] }
    if ($script:currentRowId) { $record.attempt = $script:journalRows[$script:currentRowId].attempt }
    Write-JournalRecord $record
    if ($script:currentRowId) { $script:journalRows[$script:currentRowId].checks.Add($Check) }
}
function Complete-JournalRow {
    param([string] $Id, [string[]] $Artifacts = @(), $Result = $null)
    if ($Id -ne $script:currentRowId -or -not $script:journalRows.ContainsKey($Id)) { throw "Cannot complete inactive journal row: $Id" }
    $row = $script:journalRows[$Id]
    $Result = ConvertTo-RunEvidenceReference -Value $Result -Label "$Id-result"
    $evidencePaths = @{}
    foreach ($reference in $row.evidenceReferences.Values) {
        $path = Get-ValidatedRunEvidencePath $reference
        $evidencePaths[$path] = $reference
    }
    $snapshot = Get-JournalArtifactSnapshot
    $paths = @($Artifacts) + @($evidencePaths.Keys) +
        @($snapshot.Keys | Where-Object { -not $row.snapshot.ContainsKey($_) -or $snapshot[$_] -ne $row.snapshot[$_] })
    $hashes = @($paths | ForEach-Object { Get-JournalArtifactPath $runDirectory $_ } | Sort-Object -Unique | ForEach-Object {
        if (-not (Test-Path -LiteralPath $_ -PathType Leaf)) { throw "Missing row artifact: $_" }
        $artifact = [ordered]@{ path = [IO.Path]::GetRelativePath($runDirectory, $_).Replace('\', '/')
            sha256 = (Get-FileHash -LiteralPath $_ -Algorithm SHA256 -ErrorAction Stop).Hash.ToLowerInvariant() }
        if ($evidencePaths.ContainsKey($_)) {
            $reference = Get-RunEvidenceReferenceData $evidencePaths[$_]
            if ($artifact.sha256 -cne $reference.sha256) { throw "Run evidence changed during hashing: $_" }
            $artifact['evidence'] = $true
            $artifact['bytes'] = $reference.bytes
        }
        $artifact
    })
    $status = if ($row.checks.Count -eq 0) { 'blocked' } elseif (@($row.checks | Where-Object { $_.status -eq 'blocked' }).Count) { 'blocked' }
        elseif (@($row.checks | Where-Object { $_.status -ne 'pass' }).Count) { 'fail' } else { 'pass' }
    $record = [ordered]@{ type = 'row-complete'; id = $Id; attempt = $row.attempt; status = $status; artifacts = $hashes; result = $Result }
    Write-JournalRecord $record
    $row.complete = $record
    $script:currentRowId = ''
}
function Get-JournalRowChecks {
    param([string] $Id)
    if ($script:journalRows.ContainsKey($Id) -and $script:journalRows[$Id].complete) { $script:journalRows[$Id].checks.ToArray() }
}
function Test-JournalRowPassed {
    param([string] $Id)
    if (-not $script:journalRows.ContainsKey($Id)) { return $false }
    $row = $script:journalRows[$Id]
    return [bool] ($row.complete -and $row.complete.status -eq 'pass' -and $row.checks.Count -gt 0 -and
        @($row.checks | Where-Object { $_.status -ne 'pass' }).Count -eq 0)
}
function Get-JournalRowResult {
    param([string] $Id)
    if ($script:journalRows.ContainsKey($Id) -and $script:journalRows[$Id].complete) {
        return Resolve-RunEvidenceReference $script:journalRows[$Id].complete.result
    }
}
function Test-JournalRowReusable {
    param([string] $Id)
    # Only standalone cadence/Playing/pixel/idle windows; dependent sequences and mutants always rerun.
    $independent = $Id -match '^cadence\.' -or
        $Id -match '^frames\.[^.]+\.(pixel\.r(1|4)|pixel-max\.r4\.no-art)$' -or
        $Id -match '^frames\.[^.]+\.idle\.(dim-Paused|hidden-Paused|ended|clock-mismatch|progress-hidden)$' -or
        $Id -match '^frames\.[^.]+\.(default|max-k200|min-k200|min-k50)\.times(True|False)\.r(1|4)\.(sample-art|no-art|fixture-max|long-text|long-sample-art|long-no-art)$'
    if (-not $independent -or -not $script:resumeRows.ContainsKey($Id) -or $script:journalRows.ContainsKey($Id)) { return $false }
    $row = $script:resumeRows[$Id]
    if (-not $row.complete -or $row.complete.status -ne 'pass' -or $row.checks.Count -eq 0 -or
        @($row.checks | Where-Object { $_.status -ne 'pass' }).Count -gt 0 -or
        ($row.meta.Contains('independent') -and -not $row.meta.independent)) { return $false }
    # Validate tagged evidence before reuse; unlike an ordinary stale artifact it is never silently rerun.
    $references = @(Get-RunEvidenceReferences $row.checks) + @(Get-RunEvidenceReferences $row.complete.result)
    foreach ($artifact in $row.complete.artifacts) {
        if ($artifact.Contains('evidence') -and $artifact.evidence) {
            $references += @{ evidenceRef = @{ path = $artifact.path; sha256 = $artifact.sha256
                bytes = $artifact.bytes; format = 'json'; version = 1 }; summary = $null }
        }
    }
    foreach ($reference in $references) {
        [void] (Get-ValidatedRunEvidencePath $reference $script:resumeDirectory)
        $data = Get-RunEvidenceReferenceData $reference
        if (@($row.complete.artifacts | Where-Object { $_.path -ceq $data.path -and $_.sha256 -ceq $data.sha256 }).Count -ne 1) {
            throw "Run evidence missing from row artifact hashes: $($data.path)"
        }
        $destination = Get-JournalArtifactPath $runDirectory $data.path
        if (Test-Path -LiteralPath $destination) { [void] (Get-ValidatedRunEvidencePath $reference) }
    }
    $paths = @()
    foreach ($artifact in $row.complete.artifacts) {
        $source = Get-JournalArtifactPath $script:resumeDirectory $artifact.path
        if (-not (Test-Path -LiteralPath $source -PathType Leaf) -or
            (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash.ToLowerInvariant() -cne $artifact.sha256) { return $false }
        $destination = Get-JournalArtifactPath $runDirectory $artifact.path
        if ((Test-Path -LiteralPath $destination) -and
            (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $artifact.sha256) { return $false }
        $paths += $artifact.path
    }
    Start-JournalRow -Id $Id -Meta @{ independent = $true; reused = $script:resumeRunId; sourceAttempt = $row.attempt }
    foreach ($artifact in $row.complete.artifacts) {
        $path = $artifact.path
        $source = Get-JournalArtifactPath $script:resumeDirectory $path
        $destination = Get-JournalArtifactPath $runDirectory $path
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination)) | Out-Null
        if (-not (Test-Path -LiteralPath $destination)) { [IO.File]::Copy($source, $destination) }
        if ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -cne $artifact.sha256) {
            throw "Reused artifact changed during copy: $path"
        }
    }
    foreach ($reference in $references) {
        [void] (Get-ValidatedRunEvidencePath $reference)
        Register-RunEvidenceReference $reference
    }
    foreach ($prior in $row.checks) {
        $check = [ordered]@{ name = $prior.name; expected = $prior.expected; observed = $prior.observed; status = $prior.status; reused = $script:resumeRunId }
        Add-JournalCheck $check
        $checks.Add($check)
    }
    Complete-JournalRow -Id $Id -Artifacts $paths -Result $row.complete.result
    return $true
}
# Runs one existing cadence call, with the original result available on reuse.
function Invoke-JournalCadenceRow {
    param([string] $Id, [scriptblock] $Measure)
    if (Test-JournalRowReusable -Id $Id) { return Get-JournalRowResult -Id $Id }
    Start-JournalRow -Id $Id -Meta @{ independent = $true }
    $result = & $Measure
    Complete-JournalRow -Id $Id -Result $result
    return $result
}
