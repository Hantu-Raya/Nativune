# Usage: .\scripts\delta-update-fixture.ps1
#        .\scripts\delta-update-fixture.ps1 -ReleaseADirectory artifacts\delta-fixture-a -ReleaseBDirectory artifacts\delta-fixture-b -SkipBuild
# Builds releases A and B (B reuses A's installer), publishes a Setup stub with INSTALLER_TEST_HOOKS,
# installs A under .cache and applies A -> B delta updates through Setup's --delta-dir mode.
# Never touches %LOCALAPPDATA%\Nativune; every path is checked to stay inside the repository.

[CmdletBinding()]
param(
    [string] $VersionA = '0.9.1',
    [string] $VersionB = '0.9.2',
    [ValidatePattern('^artifacts[/\\][A-Za-z0-9._-]+$')]
    [string] $ReleaseADirectory = 'artifacts/delta-fixture-a',
    [ValidatePattern('^artifacts[/\\][A-Za-z0-9._-]+$')]
    [string] $ReleaseBDirectory = 'artifacts/delta-fixture-b',
    [switch] $SkipBuild,
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression.FileSystem
$ErrorActionPreference = 'Stop'

$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repository = [IO.Path]::GetFullPath($repository).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
# The install root lives inside its own parent so Setup's adjacent .nativune-* directories stay contained.
$fixtureParent = [IO.Path]::GetFullPath((Join-Path $repository '.cache\delta-update-fixture'))
$fixtureRoot = Join-Path $fixtureParent 'Nativune'
$workRoot = [IO.Path]::GetFullPath((Join-Path $repository '.cache\delta-update-fixture-work'))
$reportDirectory = [IO.Path]::GetFullPath((Join-Path $repository 'artifacts\delta-update'))
$reportPath = Join-Path $reportDirectory 'fixture-report.json'
$failure = $null
$scenarioReports = [System.Collections.Generic.List[object]]::new()
$regenerate = "& pwsh -NoProfile -File scripts\delta-update-fixture.ps1 -VersionA $VersionA -VersionB $VersionB -ReleaseADirectory $ReleaseADirectory -ReleaseBDirectory $ReleaseBDirectory -Configuration $Configuration"
$report = [ordered]@{
    schemaVersion = 1
    status = 'running'
    regenerateCommand = $regenerate
    skipBuild = [bool]$SkipBuild
    releaseA = $null
    releaseB = $null
    installer = $null
    stubBuildCommand = $null
    delta = $null
    scenarios = $scenarioReports
}

function Assert-NoReparseChain([string] $Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Fixture path contains a reparse point: $current"
            }
        }
        if ($current.Equals($repository, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            throw "Fixture path could not be traced to the repository root: $Path"
        }
        $current = $parent.FullName
    }
}

function Resolve-RepositoryPath([string] $Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        $candidate = [IO.Path]::GetFullPath($Path)
    } else {
        $candidate = [IO.Path]::GetFullPath((Join-Path $repository $Path))
    }
    $prefix = $repository + [IO.Path]::DirectorySeparatorChar
    if (-not ($candidate.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
        throw "Path is outside the repository: $Path"
    }
    Assert-NoReparseChain $candidate
    return $candidate
}

function Assert-RegularFile([string] $Path, [string] $Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description is a reparse point: $Path"
    }
}

function Remove-ProjectDirectory([string] $Path, [string] $ExpectedPath) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.Equals($ExpectedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unexpected fixture path: $fullPath"
    }
    Assert-NoReparseChain $fullPath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return
    }
    $item = Get-Item -LiteralPath $fullPath -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove a non-directory or reparse-point fixture path: $fullPath"
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function ConvertTo-WindowsArgument([string] $Value) {
    $builder = [Text.StringBuilder]::new().Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append('\', ($backslashes * 2) + 1).Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append('\', $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append('\', $backslashes * 2)
    }
    return $builder.Append('"').ToString()
}

function Invoke-Setup([string] $FileName, [string[]] $Arguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $startInfo.WorkingDirectory = $repository
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Could not start Setup: $FileName"
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $commandText = ((@($FileName) + @($Arguments)) | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.GetAwaiter().GetResult()
        Stderr = $stderrTask.GetAwaiter().GetResult()
        Command = $commandText
    }
}

function New-AppendedSetup([string] $StubPath, [string] $ZipPath, [string] $OutputPath) {
    Assert-RegularFile $StubPath 'The test-hook Setup stub'
    Assert-RegularFile $ZipPath 'The release payload ZIP'
    if (Test-Path -LiteralPath $OutputPath) {
        throw "The fixture Setup output already exists: $OutputPath"
    }
    $stubLength = (Get-Item -LiteralPath $StubPath).Length
    $zipLength = (Get-Item -LiteralPath $ZipPath).Length
    if ($stubLength -le 0 -or $zipLength -le 0) {
        throw 'The Setup stub or release payload ZIP is empty.'
    }
    $output = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stub = [IO.File]::OpenRead($StubPath)
        $zip = [IO.File]::OpenRead($ZipPath)
        try {
            $stub.CopyTo($output, 131072)
            $zip.CopyTo($output, 131072)
        } finally {
            $zip.Dispose()
            $stub.Dispose()
        }
        $writer = [IO.BinaryWriter]::new($output, [Text.Encoding]::UTF8, $true)
        try {
            $writer.Write([Text.Encoding]::ASCII.GetBytes('NATIVN01'))
            $writer.Write([uint32]1)
            $writer.Write([int64]$stubLength)
            $writer.Write([int64]$zipLength)
            $writer.Write([uint32]0)
        } finally {
            $writer.Dispose()
        }
    } finally {
        $output.Dispose()
    }
}

function Get-Sha256Hex([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Get-BytesSha256Hex([byte[]] $Bytes) {
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Bytes)).ToLowerInvariant()
}

function Read-Release([string] $Directory, [string] $Version) {
    $root = Resolve-RepositoryPath $Directory
    $manifestPath = Join-Path $root 'release-manifest.json'
    $zipPath = Join-Path $root 'Nativune-Setup.zip'
    $setupPath = Join-Path $root 'Nativune-Setup.exe'
    $deltaPath = Join-Path $root 'delta-update.json'
    foreach ($path in @($manifestPath, $zipPath, $setupPath, $deltaPath, (Join-Path $root 'SHA256SUMS.txt'))) {
        Assert-RegularFile $path 'A release output'
    }
    $manifestBytes = [IO.File]::ReadAllBytes($manifestPath)
    $manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or $manifest.product -ne 'Nativune' -or $manifest.version -ne $Version) {
        throw "Release manifest in $Directory is not Nativune $Version."
    }
    $files = [ordered]@{}
    foreach ($entry in $manifest.files) {
        $files[[string]$entry.path] = [pscustomobject]@{ Length = [int64]$entry.length; Sha256 = [string]$entry.sha256 }
    }
    $delta = Get-Content -LiteralPath $deltaPath -Raw | ConvertFrom-Json
    $expectedNames = @('schemaVersion', 'product', 'version', 'enabled', 'applyProtocol', 'installerSha256', 'installerSourceSha256')
    $names = @($delta.PSObject.Properties.Name)
    if ($names.Count -ne $expectedNames.Count -or @($expectedNames | Where-Object { $names -notcontains $_ }).Count -ne 0) {
        throw "delta-update.json in $Directory does not have exactly the contract properties."
    }
    if ($delta.schemaVersion -ne 1 -or $delta.product -ne 'Nativune' -or $delta.version -ne $Version -or $delta.enabled -ne $true -or $delta.applyProtocol -ne 1) {
        throw "delta-update.json in $Directory has unexpected values."
    }
    $installerEntry = $files['installer/Nativune.Setup.exe']
    if ($null -eq $installerEntry -or $delta.installerSha256 -ne $installerEntry.Sha256) {
        throw "delta-update.json installerSha256 in $Directory does not match the manifest installer entry."
    }
    $sums = Get-Content -LiteralPath (Join-Path $root 'SHA256SUMS.txt') -Raw
    if (-not $sums.Contains((Get-Sha256Hex $deltaPath))) {
        throw "SHA256SUMS.txt in $Directory does not list delta-update.json."
    }
    return [pscustomobject]@{
        Root = $root
        Version = $Version
        ManifestBytes = $manifestBytes
        ManifestSha256 = Get-BytesSha256Hex $manifestBytes
        Files = $files
        ZipPath = $zipPath
        SetupLength = (Get-Item -LiteralPath $setupPath).Length
        Delta = $delta
    }
}

function Get-ManagedTree([string] $Root) {
    $tree = @{}
    foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Installed tree contains a reparse point: $($item.FullName)"
        }
        if ($item.PSIsContainer) { continue }
        $relative = [IO.Path]::GetRelativePath($Root, $item.FullName).Replace('\', '/')
        $top = $relative.Split('/')[0]
        if ($top -ieq 'data' -or $top -ieq 'updates') { continue }
        $tree[$relative] = Get-Sha256Hex $item.FullName
    }
    return $tree
}

# Asserts the root matches exactly one release: every managed file, no extras, data preserved, delta dir gone.
function Assert-Tree([pscustomobject] $Expected, [string] $Label) {
    $problems = [System.Collections.Generic.List[string]]::new()
    $tree = Get-ManagedTree $fixtureRoot
    $expectedFiles = @{}
    foreach ($key in $Expected.Files.Keys) { $expectedFiles[$key] = $Expected.Files[$key].Sha256 }
    $expectedFiles['release-manifest.json'] = $Expected.ManifestSha256
    foreach ($key in $expectedFiles.Keys) {
        if (-not $tree.ContainsKey($key)) { $problems.Add("missing $key") }
        elseif ($tree[$key] -ne $expectedFiles[$key]) { $problems.Add("hash mismatch $key") }
    }
    foreach ($key in $tree.Keys) {
        if (-not $expectedFiles.ContainsKey($key)) { $problems.Add("extra $key") }
    }
    $sentinel = Join-Path $fixtureRoot 'data\delta-fixture-sentinel.txt'
    if (-not (Test-Path -LiteralPath $sentinel -PathType Leaf) -or (Get-Content -LiteralPath $sentinel -Raw) -ne $sentinelText) {
        $problems.Add('data sentinel lost or changed')
    }
    if (Test-Path -LiteralPath (Join-Path $fixtureRoot 'updates\delta')) {
        $problems.Add('updates/delta was not removed')
    }
    foreach ($leftover in Get-ChildItem -LiteralPath $fixtureParent -Force | Where-Object { $_.Name -ne 'Nativune' }) {
        $problems.Add("leftover beside root: $($leftover.Name)")
    }
    if ($problems.Count -gt 0) {
        throw "$Label tree check failed: $(($problems | Select-Object -First 20) -join '; ')"
    }
    return $tree.Count
}

function Install-ReleaseA {
    Remove-ProjectDirectory $fixtureParent $fixtureParent
    [IO.Directory]::CreateDirectory($fixtureParent) | Out-Null
    $run = Invoke-Setup $setupAPath @('--silent', '--test-no-shell', '--no-launch', '--test-prerequisites', 'present', '--install-dir', $fixtureRoot)
    if ($run.ExitCode -ne 0) {
        throw "Installing release A returned exit code $($run.ExitCode). stderr: $($run.Stderr.Trim())"
    }
    $dataDirectory = Join-Path $fixtureRoot 'data'
    [IO.Directory]::CreateDirectory($dataDirectory) | Out-Null
    [IO.File]::WriteAllText((Join-Path $dataDirectory 'delta-fixture-sentinel.txt'), $sentinelText, [Text.UTF8Encoding]::new($false))
    [void](Assert-Tree $releaseA 'Fresh release A install')
}

function Write-DeltaFile([string] $RelativePath, [byte[]] $Bytes) {
    $target = Join-Path $deltaDirectory ($RelativePath.Replace('/', '\'))
    [IO.Directory]::CreateDirectory((Split-Path -Parent $target)) | Out-Null
    [IO.File]::WriteAllBytes($target, $Bytes)
}

function Read-ZipEntry([string] $RelativePath) {
    $entry = $zipB.GetEntry($RelativePath)
    if ($null -eq $entry) { throw "Release B ZIP has no entry $RelativePath." }
    $stream = $entry.Open()
    try {
        $memory = [IO.MemoryStream]::new()
        $stream.CopyTo($memory)
        return $memory.ToArray()
    } finally {
        $stream.Dispose()
    }
}

# Builds C3: target manifest bytes plus the given target files taken from B's ZIP.
function New-DeltaDirectory([byte[]] $ManifestBytes, [string[]] $Paths) {
    $updates = Join-Path $fixtureRoot 'updates'
    Remove-ProjectDirectory $deltaDirectory $deltaDirectory
    [IO.Directory]::CreateDirectory($updates) | Out-Null
    [IO.Directory]::CreateDirectory($deltaDirectory) | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $deltaDirectory 'release-manifest.json'), $ManifestBytes)
    foreach ($path in $Paths) {
        Write-DeltaFile $path (Read-ZipEntry $path)
    }
    # C4: the app runs Setup from updates\Nativune-Setup.exe; the fixture uses the test-hook stub there.
    $installedStyle = Join-Path $updates 'Nativune-Setup.exe'
    Copy-Item -LiteralPath $stubPath -Destination $installedStyle -Force
    return $installedStyle
}

function Get-DirectoryBytes([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = 0L
    foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -File -Force) { $sum += $file.Length }
    return $sum
}

function Invoke-DeltaSetup([string] $SetupPath, [string] $ExpectedVersion, [string] $ManifestSha256, [switch] $OmitManifestSha) {
    $waitInfo = [Diagnostics.ProcessStartInfo]::new()
    $waitInfo.FileName = $env:ComSpec
    $waitInfo.Arguments = '/d /c "ping -n 2 127.0.0.1 > nul"'
    $waitInfo.UseShellExecute = $false
    $waitInfo.CreateNoWindow = $true
    $waitProcess = [Diagnostics.Process]::Start($waitInfo)
    if ($null -eq $waitProcess) {
        throw 'Could not start the short-lived process for --wait-pid.'
    }
    $arguments = @(
        '--update', '--wait-pid', [string]$waitProcess.Id,
        '--install-dir', $fixtureRoot,
        '--expected-version', $ExpectedVersion,
        '--delta-dir', $deltaDirectory
    )
    if (-not $OmitManifestSha) {
        $arguments += @('--expected-manifest-sha256', $ManifestSha256)
    }
    $arguments += @('--silent', '--test-no-shell', '--no-launch', '--test-prerequisites', 'present')
    try {
        return Invoke-Setup $SetupPath $arguments
    } finally {
        $waitProcess.WaitForExit()
        $waitProcess.Dispose()
    }
}

try {
    if (-not [Environment]::OSVersion.Platform.Equals([PlatformID]::Win32NT)) {
        throw 'The delta update fixture runs on Windows only.'
    }
    [void](Resolve-RepositoryPath '.cache')
    [void](Resolve-RepositoryPath 'artifacts')
    $sentinelText = 'delta-fixture user data ' + [Guid]::NewGuid().ToString('N')
    $deltaDirectory = Join-Path $fixtureRoot 'updates\delta'

    if (-not $SkipBuild) {
        $buildScript = Resolve-RepositoryPath 'scripts\build-release.ps1'
        foreach ($directory in @($ReleaseADirectory, $ReleaseBDirectory)) {
            $full = Resolve-RepositoryPath $directory
            Remove-ProjectDirectory $full $full
        }
        & pwsh -NoProfile -File $buildScript -Version $VersionA -Configuration $Configuration -OutputDirectory $ReleaseADirectory
        if ($LASTEXITCODE -ne 0) { throw "Building release A failed with exit code $LASTEXITCODE." }
        & pwsh -NoProfile -File $buildScript -Version $VersionB -Configuration $Configuration -OutputDirectory $ReleaseBDirectory -PreviousReleaseDirectory $ReleaseADirectory
        if ($LASTEXITCODE -ne 0) { throw "Building release B failed with exit code $LASTEXITCODE." }
    }
    $releaseA = Read-Release $ReleaseADirectory $VersionA
    $releaseB = Read-Release $ReleaseBDirectory $VersionB
    $report.releaseA = [ordered]@{ directory = $ReleaseADirectory; version = $VersionA; manifestSha256 = $releaseA.ManifestSha256; setupBytes = $releaseA.SetupLength; fileCount = $releaseA.Files.Count }
    $report.releaseB = [ordered]@{ directory = $ReleaseBDirectory; version = $VersionB; manifestSha256 = $releaseB.ManifestSha256; setupBytes = $releaseB.SetupLength; fileCount = $releaseB.Files.Count }

    # C2: B must reuse A's installer byte-for-byte.
    $installerA = $releaseA.Files['installer/Nativune.Setup.exe'].Sha256
    $installerB = $releaseB.Files['installer/Nativune.Setup.exe'].Sha256
    if ($installerA -ne $installerB -or $releaseB.Delta.installerSha256 -ne $installerA -or $releaseA.Delta.installerSourceSha256 -ne $releaseB.Delta.installerSourceSha256) {
        throw 'Release B did not reuse release A''s installer byte-for-byte.'
    }
    $report.installer = [ordered]@{ sha256 = $installerB; sourceSha256 = $releaseB.Delta.installerSourceSha256; reusedAcrossReleases = $true }

    $changed = @($releaseB.Files.Keys | Where-Object { $releaseA.Files.Contains($_) -and $releaseA.Files[$_].Sha256 -ne $releaseB.Files[$_].Sha256 })
    $added = @($releaseB.Files.Keys | Where-Object { -not $releaseA.Files.Contains($_) })
    $removed = @($releaseA.Files.Keys | Where-Object { -not $releaseB.Files.Contains($_) })
    $unchanged = @($releaseB.Files.Keys | Where-Object { $releaseA.Files.Contains($_) -and $releaseA.Files[$_].Sha256 -eq $releaseB.Files[$_].Sha256 })
    $deltaPaths = @($changed) + @($added)
    if ($changed.Count -eq 0) { throw 'Release A and B have no changed files; the fixture needs at least one.' }
    if ($unchanged.Count -eq 0) { throw 'Release A and B share no unchanged files; the fixture needs at least one.' }
    $deltaBytes = 0L
    foreach ($path in $deltaPaths) { $deltaBytes += $releaseB.Files[$path].Length }
    $report.delta = [ordered]@{
        changedFiles = $changed
        addedFiles = $added
        removedFiles = $removed
        unchangedFileCount = $unchanged.Count
        deltaFileBytes = $deltaBytes
        deltaDirectoryBytes = $deltaBytes + $releaseB.ManifestBytes.Length
        fullSetupBytes = $releaseB.SetupLength
        fullZipBytes = (Get-Item -LiteralPath $releaseB.ZipPath).Length
    }

    Remove-ProjectDirectory $workRoot $workRoot
    [IO.Directory]::CreateDirectory($workRoot) | Out-Null
    $publishRoot = Join-Path $workRoot 'publish'
    [IO.Directory]::CreateDirectory($publishRoot) | Out-Null
    $dotnetScript = Resolve-RepositoryPath 'scripts\dotnet.ps1'
    $buildArguments = @(
        'publish', (Resolve-RepositoryPath 'src\Nativune.Installer\Nativune.Installer.csproj'),
        '--configuration', $Configuration,
        '--output', $publishRoot,
        '-p:InstallerTestHooks=true'
    )
    $report.stubBuildCommand = "& pwsh -NoProfile -File $(ConvertTo-WindowsArgument $dotnetScript) $(($buildArguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')"
    & pwsh -NoProfile -File $dotnetScript @buildArguments
    if ($LASTEXITCODE -ne 0) { throw "Test-hook Setup publish failed with exit code $LASTEXITCODE." }
    $stubPath = Join-Path $publishRoot 'Nativune.Setup.exe'
    $setupAPath = Join-Path $workRoot 'Nativune-Setup-A.exe'
    New-AppendedSetup $stubPath $releaseA.ZipPath $setupAPath

    # (g) Obsolete removal: Setup trusts --expected-manifest-sha256, so a copy of B's manifest without one
    # unchanged file (hashed here) is a self-consistent target whose apply must delete that installed file.
    $obsoleteCandidate = $unchanged | Where-Object { $_ -ne 'installer/Nativune.Setup.exe' -and $_ -ne 'app/Nativune.exe' -and -not $_.StartsWith('.tools/') } | Select-Object -First 1
    $obsoleteRelease = $null
    if ($null -ne $obsoleteCandidate) {
        $parsedB = [Text.Encoding]::UTF8.GetString($releaseB.ManifestBytes) | ConvertFrom-Json
        $parsedB.files = @($parsedB.files | Where-Object { $_.path -ne $obsoleteCandidate })
        $obsoleteBytes = [Text.UTF8Encoding]::new($false).GetBytes(($parsedB | ConvertTo-Json -Depth 8 -Compress))
        $obsoleteFiles = [ordered]@{}
        foreach ($key in $releaseB.Files.Keys) { if ($key -ne $obsoleteCandidate) { $obsoleteFiles[$key] = $releaseB.Files[$key] } }
        $obsoleteRelease = [pscustomobject]@{ Version = $VersionB; ManifestBytes = $obsoleteBytes; ManifestSha256 = Get-BytesSha256Hex $obsoleteBytes; Files = $obsoleteFiles }
    }

    $zipB = [IO.Compression.ZipFile]::OpenRead($releaseB.ZipPath)
    $scenarios = @(
        [pscustomobject]@{ Name = 'a-happy-path'; ExpectedExitCode = 0; ExpectedTree = 'B' },
        [pscustomobject]@{ Name = 'b-tampered-staged-file'; ExpectedExitCode = 10; ExpectedTree = 'A' },
        [pscustomobject]@{ Name = 'c-missing-staged-installed-differs'; ExpectedExitCode = 10; ExpectedTree = 'A' },
        [pscustomobject]@{ Name = 'd-wrong-manifest-sha256'; ExpectedExitCode = 10; ExpectedTree = 'A' },
        [pscustomobject]@{ Name = 'e-extra-unlisted-file'; ExpectedExitCode = 10; ExpectedTree = 'A' },
        [pscustomobject]@{ Name = 'f-repair-corrupted-unchanged-file'; ExpectedExitCode = 0; ExpectedTree = 'B' },
        [pscustomobject]@{ Name = 'g-obsolete-file-removal'; ExpectedExitCode = 0; ExpectedTree = 'B-minus-obsolete' },
        [pscustomobject]@{ Name = 'h-usage-missing-manifest-sha256'; ExpectedExitCode = 2; ExpectedTree = 'A' }
    )
    try {
        foreach ($scenario in $scenarios) {
            $entry = [ordered]@{ name = $scenario.Name; expectedExitCode = $scenario.ExpectedExitCode; expectedTree = $scenario.ExpectedTree; status = 'running' }
            $scenarioReports.Add($entry)
            try {
                if ($scenario.Name -eq 'g-obsolete-file-removal' -and $null -eq $obsoleteRelease) {
                    $entry.status = 'skipped'
                    $entry.reason = 'No unchanged, non-executable file outside .tools/ exists to drop from the target manifest.'
                    continue
                }
                Install-ReleaseA
                $target = $releaseB
                $paths = $deltaPaths
                $manifestSha = $releaseB.ManifestSha256
                $omitSha = $false
                switch ($scenario.Name) {
                    'f-repair-corrupted-unchanged-file' {
                        $victim = $unchanged | Where-Object { $_ -ne 'installer/Nativune.Setup.exe' } | Select-Object -First 1
                        $installedVictim = Join-Path $fixtureRoot ($victim.Replace('/', '\'))
                        [IO.File]::AppendAllText($installedVictim, 'corrupted by delta fixture')
                        $paths = @($deltaPaths) + @($victim)
                        $entry.repairedFile = $victim
                    }
                    'g-obsolete-file-removal' {
                        $target = $obsoleteRelease
                        $manifestSha = $obsoleteRelease.ManifestSha256
                        $entry.obsoleteFile = $obsoleteCandidate
                        $entry.note = 'Synthetic target manifest: B''s manifest minus one file, passed with its own SHA-256.'
                    }
                    'd-wrong-manifest-sha256' { $manifestSha = '0' * 64 }
                    'h-usage-missing-manifest-sha256' { $omitSha = $true }
                }
                $setup = New-DeltaDirectory $target.ManifestBytes $paths
                switch ($scenario.Name) {
                    'b-tampered-staged-file' {
                        $tampered = Join-Path $deltaDirectory ($changed[0].Replace('/', '\'))
                        $bytes = [IO.File]::ReadAllBytes($tampered)
                        $bytes[0] = $bytes[0] -bxor 0xFF
                        [IO.File]::WriteAllBytes($tampered, $bytes)
                        $entry.tamperedFile = $changed[0]
                    }
                    'c-missing-staged-installed-differs' {
                        Remove-Item -LiteralPath (Join-Path $deltaDirectory ($changed[0].Replace('/', '\'))) -Force
                        $entry.omittedFile = $changed[0]
                    }
                    'e-extra-unlisted-file' {
                        Write-DeltaFile 'app/unlisted-delta-fixture.bin' ([Text.Encoding]::ASCII.GetBytes('not in the manifest'))
                        $entry.extraFile = 'app/unlisted-delta-fixture.bin'
                    }
                }
                $entry.deltaDirectoryBytes = Get-DirectoryBytes $deltaDirectory
                $entry.expectedManifestSha256 = $manifestSha
                $run = Invoke-DeltaSetup $setup $VersionB $manifestSha -OmitManifestSha:$omitSha
                $entry.command = $run.Command
                $entry.exitCode = $run.ExitCode
                $entry.stderr = $run.Stderr.Trim()
                if ($run.ExitCode -ne $scenario.ExpectedExitCode) {
                    throw "exit code $($run.ExitCode), expected $($scenario.ExpectedExitCode)."
                }
                if ($scenario.Name -eq 'h-usage-missing-manifest-sha256') {
                    # Usage errors stop before Setup touches the delta dir; only the installed tree must be intact.
                    Remove-ProjectDirectory $deltaDirectory $deltaDirectory
                }
                $expected = switch ($scenario.ExpectedTree) { 'A' { $releaseA } 'B' { $releaseB } default { $obsoleteRelease } }
                $entry.managedFileCount = Assert-Tree $expected $scenario.Name
                $entry.status = 'passed'
            } catch {
                $entry.status = 'failed'
                $entry.error = $_.Exception.Message
            }
        }
    } finally {
        $zipB.Dispose()
    }
    $failed = @($scenarioReports | Where-Object { $_.status -eq 'failed' })
    if ($failed.Count -gt 0) {
        throw "$($failed.Count) scenario(s) failed: $(($failed | ForEach-Object { "$($_.name): $($_.error)" }) -join ' | ')"
    }
    $report.status = 'passed'
}
catch {
    $failure = $_.Exception.Message
    $report.status = 'failed'
    $report.error = $failure
}
finally {
    try { Remove-ProjectDirectory $fixtureParent $fixtureParent } catch { if ($null -eq $failure) { $failure = $_.Exception.Message; $report.status = 'failed'; $report.error = $failure } }
    try { Remove-ProjectDirectory $workRoot $workRoot } catch { if ($null -eq $failure) { $failure = $_.Exception.Message; $report.status = 'failed'; $report.error = $failure } }
    try {
        Assert-NoReparseChain $reportDirectory
        [IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
        if ((Test-Path -LiteralPath $reportPath) -and ((Get-Item -LiteralPath $reportPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The fixture report is a reparse point: $reportPath"
        }
        [IO.File]::WriteAllText($reportPath, ($report | ConvertTo-Json -Depth 10), [Text.UTF8Encoding]::new($false))
    }
    catch {
        if ($null -eq $failure) { $failure = $_.Exception.Message }
    }
}

if ($null -ne $failure) {
    Write-Error "Delta update fixture failed: $failure. See $reportPath."
    exit 1
}
Write-Output "Delta update fixture passed. Report: $reportPath"
