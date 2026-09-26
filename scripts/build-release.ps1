[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidatePattern('^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$')]
    [string] $Version = '0.1.26',
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release',
    [ValidatePattern('^artifacts[/\\][A-Za-z0-9._-]+$')]
    [string] $OutputDirectory = 'artifacts/release',
    [string] $PreviousReleaseDirectory = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$appProject = 'src/Nativune/Nativune.csproj'
$installerProject = 'src/Nativune.Installer/Nativune.Installer.csproj'
$ubolVersion = '2026.907.2003'
$releaseRoot = Join-Path $repository $OutputDirectory
$workRoot = Join-Path $releaseRoot ('.staging-' + [Guid]::NewGuid().ToString('N'))
$ubolExtractRoot = Join-Path $workRoot 'ubol-upstream'
$stageRoot = Join-Path $workRoot 'payload'
$appPublishRoot = Join-Path $workRoot 'app-publish'
$setupPublishRoot = Join-Path $workRoot 'setup-publish'
$zipPath = Join-Path $workRoot 'Nativune-Setup.zip'
$setupPath = Join-Path $releaseRoot 'Nativune-Setup.exe'
$releaseZipPath = Join-Path $releaseRoot 'Nativune-Setup.zip'
$manifestPath = Join-Path $releaseRoot 'release-manifest.json'
$checksumsPath = Join-Path $releaseRoot 'SHA256SUMS.txt'
$deltaDescriptorPath = Join-Path $releaseRoot 'delta-update.json'
$installerEntryPath = 'installer/Nativune.Setup.exe'
function Resolve-RepositoryPath([string] $Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        $candidate = [IO.Path]::GetFullPath($Path)
    } else {
        $candidate = [IO.Path]::GetFullPath((Join-Path $repository $Path))
    }
    $rootWithSeparator = $repository.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not ($candidate.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase))) {
        throw "Path is outside the repository: $Path"
    }
    $current = $candidate
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Repository input path contains a reparse point: $current"
            }
        }
        if ($current.Equals($repository, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            throw "Repository input path could not be traced to the repository root: $Path"
        }
        $current = $parent.FullName
    }
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

function Assert-NoBundledAppRuntime([string] $Root, [string] $Description) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "$Description directory is missing: $Root"
    }
    $forbiddenNames = '(?i)^(?:(?:coreclr|clrjit|hostfxr|hostpolicy|msedgewebview2|msedge|msedge_proxy|icudtl)\.(?:dll|exe|dat)|Microsoft\.WindowsAppRuntime[^\\/]*\.(?:dll|exe|msix|msixbundle|appx|appxbundle)|(?:v8_context_snapshot|snapshot_blob)\.bin)$'
    foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force) {
        if ($item.Name -match $forbiddenNames -and $item.Name -notin @(
            'Microsoft.WindowsAppRuntime.Bootstrap.dll',
            'Microsoft.WindowsAppRuntime.Bootstrap.Net.dll'
        )) {
            throw "$Description contains a bundled .NET, Windows App SDK, or fixed WebView2 runtime file: $($item.FullName)"
        }
    }
}

function Remove-SafeOutputFile([string] $Path, [string] $Description) {
    [void](Resolve-RepositoryPath $Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }
    $item = Get-Item -LiteralPath $Path -Force
    if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description is not a regular replaceable file: $Path"
    }
    Remove-Item -LiteralPath $Path -Force
}

function Assert-PublicTree([string] $Root) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
        throw "The public payload source directory is missing: $Root"
    }
    $rootItem = Get-Item -LiteralPath $Root -Force
    if (($rootItem.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "The public payload source directory is a reparse point: $Root"
    }
    $forbidden = '(?i)(^|[\\/])(data|profiles?|caches?|credentials?|tokens?|cookies?|logs?|handoff|evidence)([\\/]|$)|(?i)(^|[\\/])(\.env(?:\.[^\\/]*)?|oauth\.(json|txt|bin)|client[-_]?secret[^\\/]*|api[-_]?key[^\\/]*|private\.key|id_rsa|history\.(json|db|sqlite)|cookies?\.(json|db|sqlite)|tokens?\.(bin|json|txt))$|(?i)(credential|\.pfx$|\.p12$|\.pem$|\.(pdb|dbg|dmp)$)'
    $secretContent = '(?i)"(client_secret|refresh_token|access_token|private_key)"\s*:\s*"[^"]+"|AIza[0-9A-Za-z_-]{30,}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----'
    foreach ($item in Get-ChildItem -LiteralPath $Root -Recurse -Force) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The public payload source contains a reparse point: $($item.FullName)"
        }
        $relative = $item.FullName.Substring($Root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
        if ($relative -match $forbidden) {
            throw "The public payload contains a private or generated path: $relative"
        }
        if (-not $item.PSIsContainer -and $item.Length -le 16MB -and $item.Extension -in @('.json', '.txt', '.config', '.xml', '.ini', '.yaml', '.yml')) {
            $content = Get-Content -LiteralPath $item.FullName -Raw
            if ($content -match $secretContent) {
                throw "The public payload contains credential-like content: $relative"
            }
        }
    }
}

function Copy-TreeContent([string] $Source, [string] $Destination) {
    Assert-PublicTree $Source
    [IO.Directory]::CreateDirectory($Destination) | Out-Null
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Recurse -Force
    }
}

function Expand-VerifiedArchive([string] $ArchivePath, [string] $ExpectedSha256, [string] $Destination) {
    if (Test-Path -LiteralPath $Destination) {
        throw "The uBO Lite extraction directory is not fresh: $Destination"
    }
    [void](Resolve-RepositoryPath $Destination)
    $stream = [IO.File]::Open($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    $archive = $null
    try {
        $sha256 = [Security.Cryptography.SHA256]::Create()
        try {
            $archiveHash = [Convert]::ToHexString($sha256.ComputeHash($stream)).ToLowerInvariant()
        } finally {
            $sha256.Dispose()
        }
        if ($archiveHash -ne $ExpectedSha256) {
            throw 'The pinned uBO Lite source archive does not match release-inputs.json.'
        }
        $stream.Position = 0
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true, [Text.Encoding]::UTF8)
        [IO.Directory]::CreateDirectory($Destination) | Out-Null
        $destinationRoot = [IO.Path]::GetFullPath($Destination).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        $invalidFileNameChars = [IO.Path]::GetInvalidFileNameChars()
        foreach ($entry in $archive.Entries) {
            $entryName = $entry.FullName
            if ([string]::IsNullOrEmpty($entryName) -or $entryName.StartsWith('/') -or $entryName.Contains('\') -or $entryName -match '^[A-Za-z]:') {
                throw "The uBO Lite archive contains an unsafe path: $entryName"
            }
            $isDirectory = $entryName.EndsWith('/')
            $relative = if ($isDirectory) { $entryName.Substring(0, $entryName.Length - 1) } else { $entryName }
            $segments = $relative.Split('/')
            foreach ($segment in $segments) {
                if ([string]::IsNullOrEmpty($segment) -or $segment -in @('.', '..') -or $segment.EndsWith('.') -or $segment.EndsWith(' ') -or $segment.IndexOfAny($invalidFileNameChars) -ge 0) {
                    throw "The uBO Lite archive contains an unsafe path: $entryName"
                }
            }
            $unixFileType = ($entry.ExternalAttributes -shr 16) -band 0xF000
            if (($entry.ExternalAttributes -band [int][IO.FileAttributes]::ReparsePoint) -ne 0 -or $unixFileType -eq 0xA000) {
                throw "The uBO Lite archive contains reparse or symbolic-link content: $entryName"
            }
            $destinationPath = [IO.Path]::GetFullPath((Join-Path $Destination $relative.Replace('/', [IO.Path]::DirectorySeparatorChar)))
            if (-not $destinationPath.StartsWith($destinationRoot, [StringComparison]::OrdinalIgnoreCase)) {
                throw "The uBO Lite archive path escapes its extraction directory: $entryName"
            }
            if ($isDirectory) {
                [IO.Directory]::CreateDirectory($destinationPath) | Out-Null
                continue
            }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destinationPath)) | Out-Null
            $entryStream = $entry.Open()
            $outputStream = $null
            try {
                $outputStream = [IO.File]::Open($destinationPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                $entryStream.CopyTo($outputStream)
            } finally {
                if ($null -ne $outputStream) { $outputStream.Dispose() }
                $entryStream.Dispose()
            }
        }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $stream.Dispose()
    }
    Assert-PublicTree $Destination
}

function Relative-ForwardPath([string] $Root, [string] $Path) {
    return $Path.Substring($Root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace([IO.Path]::DirectorySeparatorChar, '/')
}

function Get-TreeFingerprint([string] $Root, [switch] $AllowDevelopmentFiles) {
    if ($AllowDevelopmentFiles) {
        if (-not (Test-Path -LiteralPath $Root -PathType Container)) {
            throw "The fingerprint source directory is missing: $Root"
        }
        foreach ($item in @((Get-Item -LiteralPath $Root -Force)) + @(Get-ChildItem -LiteralPath $Root -Recurse -Force)) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "The fingerprint source contains a reparse point: $($item.FullName)"
            }
        }
    } else {
        Assert-PublicTree $Root
    }
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    [int64] $count = 0
    [int64] $totalBytes = 0
    try {
        foreach ($item in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Sort-Object -CaseSensitive @{ Expression = { Relative-ForwardPath $Root $_.FullName }; Ascending = $true })) {
            $relative = Relative-ForwardPath $Root $item.FullName
            $fileHash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $record = $relative + [char]0 + $item.Length.ToString([Globalization.CultureInfo]::InvariantCulture) + [char]0 + $fileHash + "`n"
            $hash.AppendData([Text.Encoding]::UTF8.GetBytes($record))
            $count++
            $totalBytes += $item.Length
        }
        return [pscustomobject]@{
            sha256 = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
            fileCount = $count
            totalBytes = $totalBytes
        }
    } finally {
        $hash.Dispose()
    }
}

function Get-InstallerSourceFingerprint([string] $SdkVersion, [string[]] $PublishOptions) {
    $installerRoot = Resolve-RepositoryPath 'src/Nativune.Installer'
    $records = [Collections.Generic.List[string]]::new()
    $files = [Collections.Generic.List[IO.FileInfo]]::new()
    foreach ($item in Get-ChildItem -LiteralPath $installerRoot -Recurse -Force) {
        $relative = Relative-ForwardPath $repository $item.FullName
        if ($relative -match '(?i)^src/Nativune\.Installer/(bin|obj)(/|$)') { continue }
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The installer source contains a reparse point: $($item.FullName)"
        }
        if (-not $item.PSIsContainer) { $files.Add($item) }
    }
    foreach ($name in @('global.json', 'Directory.Build.props', 'Directory.Build.targets', 'Directory.Packages.props', 'NuGet.config')) {
        $path = Resolve-RepositoryPath $name
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Assert-RegularFile $path "Repository build input $name"
            $files.Add((Get-Item -LiteralPath $path -Force))
        }
    }
    # Project inputs outside src/Nativune.Installer (for example the ApplicationIcon under assets/) are
    # referenced with ..\ paths in the project file; a change to any of them must force a fresh Setup build.
    $projectText = [IO.File]::ReadAllText((Join-Path $installerRoot 'Nativune.Installer.csproj'))
    foreach ($match in [regex]::Matches($projectText, '\.\.[\\/][^<>";]+')) {
        $path = Resolve-RepositoryPath ([IO.Path]::GetFullPath((Join-Path $installerRoot $match.Value.Trim())))
        Assert-RegularFile $path "Installer project input $($match.Value)"
        $files.Add((Get-Item -LiteralPath $path -Force))
    }
    foreach ($item in $files) {
        $relative = Relative-ForwardPath $repository $item.FullName
        $fileHash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
        $records.Add($relative + [char]0 + $item.Length.ToString([Globalization.CultureInfo]::InvariantCulture) + [char]0 + $fileHash + "`n")
    }
    $records.Add('dotnet-sdk-version' + [char]0 + $SdkVersion + "`n")
    $records.Add('installer-publish-arguments' + [char]0 + ($PublishOptions -join [char]0) + "`n")
    $records.Sort([StringComparer]::Ordinal)
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]::Concat($records))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

function Read-DeltaDescriptor([string] $Path) {
    $descriptor = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
    $expected = @('schemaVersion', 'product', 'version', 'enabled', 'applyProtocol', 'installerSha256', 'installerSourceSha256')
    $names = @($descriptor.PSObject.Properties.Name)
    if ($names.Count -ne $expected.Count -or @($expected | Where-Object { $_ -cnotin $names }).Count -ne 0) { return $null }
    if ($descriptor.schemaVersion -isnot [int64] -and $descriptor.schemaVersion -isnot [int]) { return $null }
    if ($descriptor.schemaVersion -ne 1 -or $descriptor.product -cne 'Nativune' -or $descriptor.version -isnot [string] -or $descriptor.enabled -isnot [bool] -or $descriptor.applyProtocol -ne 1) { return $null }
    if ($descriptor.installerSha256 -cnotmatch '^[0-9a-f]{64}$' -or $descriptor.installerSourceSha256 -cnotmatch '^[0-9a-f]{64}$') { return $null }
    return $descriptor
}

function Get-ReusableStub([string] $PreviousRoot, [string] $Fingerprint, [string] $Destination) {
    $previousDescriptorPath = Join-Path $PreviousRoot 'delta-update.json'
    $previousManifestPath = Join-Path $PreviousRoot 'release-manifest.json'
    $previousZipPath = Join-Path $PreviousRoot 'Nativune-Setup.zip'
    foreach ($path in @($previousDescriptorPath, $previousManifestPath, $previousZipPath)) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-Host "Previous release asset missing, building a fresh installer stub: $path"
            return $false
        }
        Assert-RegularFile $path 'The previous release asset'
    }
    $descriptor = Read-DeltaDescriptor $previousDescriptorPath
    if ($null -eq $descriptor) {
        Write-Host 'The previous delta-update.json is not a valid schema 1 descriptor; building a fresh installer stub.'
        return $false
    }
    if ($descriptor.installerSourceSha256 -cne $Fingerprint) {
        Write-Host 'Installer inputs changed since the previous release; building a fresh installer stub.'
        return $false
    }
    $manifestBytes = [IO.File]::ReadAllBytes($previousManifestPath)
    $manifest = [Text.Encoding]::UTF8.GetString($manifestBytes) | ConvertFrom-Json
    $entries = @($manifest.files | Where-Object { $_.path -ceq $installerEntryPath })
    if ($manifest.schemaVersion -ne 1 -or $manifest.product -cne 'Nativune' -or $entries.Count -ne 1) {
        throw 'The previous release manifest does not contain exactly one installer entry.'
    }
    $stream = [IO.File]::OpenRead($previousZipPath)
    $archive = $null
    try {
        $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Read, $true, [Text.Encoding]::UTF8)
        $zipManifest = @($archive.Entries | Where-Object { $_.FullName -ceq 'release-manifest.json' })
        $zipStub = @($archive.Entries | Where-Object { $_.FullName -ceq $installerEntryPath })
        if ($zipManifest.Count -ne 1 -or $zipStub.Count -ne 1) {
            throw 'The previous release ZIP does not contain exactly one manifest and installer entry.'
        }
        $buffer = [IO.MemoryStream]::new()
        $entryStream = $zipManifest[0].Open()
        try { $entryStream.CopyTo($buffer) } finally { $entryStream.Dispose() }
        if (-not [Linq.Enumerable]::SequenceEqual([byte[]]$buffer.ToArray(), [byte[]]$manifestBytes)) {
            throw 'The previous release ZIP manifest differs from the previous release-manifest.json.'
        }
        if ($zipStub[0].Length -ne [int64]$entries[0].length -or $zipStub[0].Length -gt 512MB) {
            throw 'The previous installer stub length does not match its manifest entry.'
        }
        $entryStream = $zipStub[0].Open()
        $output = [IO.File]::Open($Destination, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $entryStream.CopyTo($output, 131072) } finally { $output.Dispose(); $entryStream.Dispose() }
    } finally {
        if ($null -ne $archive) { $archive.Dispose() }
        $stream.Dispose()
    }
    $stubHash = (Get-FileHash -LiteralPath $Destination -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($stubHash -cne $entries[0].sha256 -or $stubHash -cne $descriptor.installerSha256) {
        throw 'The previous installer stub hash does not match its manifest entry and delta descriptor.'
    }
    return $true
}

function New-Manifest([string] $PayloadRoot) {
    $files = @(
        foreach ($item in (Get-ChildItem -LiteralPath $PayloadRoot -Recurse -File -Force | Sort-Object @{ Expression = { Relative-ForwardPath $PayloadRoot $_.FullName }; Ascending = $true })) {
            $relative = Relative-ForwardPath $PayloadRoot $item.FullName
            if ($relative -eq 'release-manifest.json') { continue }
            $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            [ordered]@{
                path = $relative
                length = [int64]$item.Length
                sha256 = $hash
            }
        }
    )
    if ($files.Count -eq 0) { throw 'The public release payload is empty.' }
    $manifest = [ordered]@{
        schemaVersion = 1
        product = 'Nativune'
        version = $Version
        executable = 'app/Nativune.exe'
        files = $files
    }
    $json = $manifest | ConvertTo-Json -Depth 8 -Compress
    [IO.File]::WriteAllText((Join-Path $PayloadRoot 'release-manifest.json'), $json, [Text.UTF8Encoding]::new($false))
}

function New-CanonicalZip([string] $PayloadRoot, [string] $ZipPath) {
    $stream = [IO.File]::Open($ZipPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    $archive = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false, [Text.Encoding]::UTF8)
    try {
        foreach ($item in (Get-ChildItem -LiteralPath $PayloadRoot -Recurse -File -Force | Sort-Object @{ Expression = { Relative-ForwardPath $PayloadRoot $_.FullName }; Ascending = $true })) {
            $relative = Relative-ForwardPath $PayloadRoot $item.FullName
            $entry = $archive.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
            $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
            $input = [IO.File]::OpenRead($item.FullName)
            $output = $entry.Open()
            try {
                $input.CopyTo($output, 131072)
            } finally {
                $output.Dispose()
                $input.Dispose()
            }
        }
    } finally {
        $archive.Dispose()
        $stream.Dispose()
    }
}

function New-AppendedSetup([string] $StubPath, [string] $ZipPath, [string] $OutputPath) {
    Assert-RegularFile $StubPath 'The unpayloaded setup stub'
    Assert-RegularFile $ZipPath 'The release ZIP'
    $stubLength = (Get-Item -LiteralPath $StubPath).Length
    $zipLength = (Get-Item -LiteralPath $ZipPath).Length
    if ($stubLength -le 0 -or $zipLength -le 0) { throw 'The setup stub or release ZIP is empty.' }
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

try {
    if (-not [Environment]::OSVersion.Platform.Equals([PlatformID]::Win32NT)) {
        throw 'Release packaging is Windows-only.'
    }
    [void](Resolve-RepositoryPath 'artifacts')
    [void](Resolve-RepositoryPath $releaseRoot)
    [IO.Directory]::CreateDirectory($releaseRoot) | Out-Null
    [IO.Directory]::CreateDirectory($workRoot) | Out-Null
    [IO.Directory]::CreateDirectory($stageRoot) | Out-Null
    [void](Resolve-RepositoryPath $releaseRoot)
    [void](Resolve-RepositoryPath $workRoot)

    $appProjectPath = Resolve-RepositoryPath $AppProject
    $installerProjectPath = Resolve-RepositoryPath $InstallerProject
    $ubolExtractRoot = Resolve-RepositoryPath $ubolExtractRoot
    $ubolArchive = Resolve-RepositoryPath '.cache/downloads/ubol-2026.907.2003.zip'
    $dotnetExecutable = Resolve-RepositoryPath '.tools/dotnet/dotnet.exe'
    $dotnetRoot = Resolve-RepositoryPath '.tools/dotnet'
    $nativuneLicense = Resolve-RepositoryPath 'LICENSE'
    $repositoryNotice = Resolve-RepositoryPath 'THIRD-PARTY-NOTICES.txt'
    $appSdkLicense = Resolve-RepositoryPath '.cache/nuget/packages/microsoft.windowsappsdk/2.5.1/license.txt'
    $dotnetLicense = Resolve-RepositoryPath '.tools/dotnet/LICENSE.txt'
    $dotnetNotice = Resolve-RepositoryPath '.tools/dotnet/ThirdPartyNotices.txt'
    $webView2License = Resolve-RepositoryPath '.cache/nuget/packages/microsoft.web.webview2/1.0.4191.47/LICENSE.txt'
    $webView2Notice = Resolve-RepositoryPath '.cache/nuget/packages/microsoft.web.webview2/1.0.4191.47/NOTICE.txt'
    $releaseInputsPath = Resolve-RepositoryPath 'release-inputs.json'

    Assert-RegularFile $dotnetExecutable 'The repository-local .NET SDK'
    Assert-RegularFile $nativuneLicense 'The Nativune MIT license'
    Assert-RegularFile $repositoryNotice 'The repository third-party notices file'
    Assert-RegularFile $appProjectPath 'The application project'
    Assert-RegularFile $installerProjectPath 'The installer project'
    Assert-RegularFile $releaseInputsPath 'The pinned release input manifest'
    Assert-RegularFile $ubolArchive 'The pinned uBO Lite source archive'
    $releaseInputs = Get-Content -LiteralPath $releaseInputsPath -Raw | ConvertFrom-Json
    if ($releaseInputs.schemaVersion -ne 1 -or $releaseInputs.dotnetSdk.version -ne '10.0.401' -or $releaseInputs.uBlockOriginLite.version -ne $ubolVersion) {
        throw 'The pinned release input manifest has unexpected identity fields.'
    }
    $dotnetSignature = Get-AuthenticodeSignature -LiteralPath $dotnetExecutable
    if ($dotnetSignature.Status -ne 'Valid' -or $null -eq $dotnetSignature.SignerCertificate -or $dotnetSignature.SignerCertificate.Subject -notmatch 'Microsoft|\.NET') {
        throw 'The repository-local .NET SDK host does not have a valid Microsoft signature.'
    }
    $dotnetVersion = (& $dotnetExecutable --version)
    if ($LASTEXITCODE -ne 0 -or $dotnetVersion.Trim() -ne $releaseInputs.dotnetSdk.version) {
        throw 'The repository-local .NET SDK version does not match release-inputs.json.'
    }
    $dotnetFingerprint = Get-TreeFingerprint $dotnetRoot -AllowDevelopmentFiles
    if ($dotnetFingerprint.sha256 -ne $releaseInputs.dotnetSdk.treeSha256 -or $dotnetFingerprint.fileCount -ne $releaseInputs.dotnetSdk.fileCount -or $dotnetFingerprint.totalBytes -ne $releaseInputs.dotnetSdk.totalBytes) {
        throw 'The repository-local .NET SDK tree does not match release-inputs.json.'
    }
    Expand-VerifiedArchive $ubolArchive $releaseInputs.uBlockOriginLite.sourceArchiveSha256 $ubolExtractRoot
    $ubolSource = $ubolExtractRoot
    $ubolManifest = Resolve-RepositoryPath (Join-Path $ubolSource 'manifest.json')
    Assert-RegularFile $ubolManifest 'The pinned uBO Lite manifest'
    $ubolIdentity = Get-Content -LiteralPath $ubolManifest -Raw | ConvertFrom-Json
    if ($ubolIdentity.version -ne $ubolVersion -or $ubolIdentity.short_name -ne 'uBO Lite') {
        throw "The uBO Lite payload identity does not match version $ubolVersion."
    }
    $ubolFingerprint = Get-TreeFingerprint $ubolSource
    if ($ubolFingerprint.sha256 -ne $releaseInputs.uBlockOriginLite.treeSha256 -or $ubolFingerprint.fileCount -ne $releaseInputs.uBlockOriginLite.fileCount -or $ubolFingerprint.totalBytes -ne $releaseInputs.uBlockOriginLite.totalBytes) {
        throw 'The pristine uBO Lite source tree does not match release-inputs.json.'
    }
    Assert-RegularFile $appSdkLicense 'The Windows App SDK license'
    Assert-RegularFile $dotnetLicense '.NET license'
    Assert-RegularFile $dotnetNotice '.NET third-party notices'
    Assert-RegularFile $webView2License 'The WebView2 license'
    Assert-RegularFile $webView2Notice 'The WebView2 notice'
    # The installer keeps its own version; its publish must not depend on the app version.
    $installerPublishOptions = @('-c', $Configuration, '-r', 'win-x64', '--self-contained', 'true', '--no-restore', '-p:PublishSingleFile=true', '-p:IncludeNativeLibrariesForSelfExtract=true', '-p:DebugType=none', '-p:DebugSymbols=false', '-p:InstallerTestHooks=false')
    $installerSourceSha256 = Get-InstallerSourceFingerprint $dotnetVersion.Trim() $installerPublishOptions
    [IO.Directory]::CreateDirectory($setupPublishRoot) | Out-Null
    $stubReused = $false
    if (-not [string]::IsNullOrEmpty($PreviousReleaseDirectory)) {
        $previousRoot = Resolve-RepositoryPath $PreviousReleaseDirectory
        if (-not (Test-Path -LiteralPath $previousRoot -PathType Container)) {
            throw "The previous release directory is missing: $PreviousReleaseDirectory"
        }
        $stubReused = Get-ReusableStub $previousRoot $installerSourceSha256 (Join-Path $setupPublishRoot 'Nativune.Setup.exe')
    }
    Push-Location $repository
    try {
        & $dotnetExecutable publish $appProjectPath -c $Configuration -r win-x64 --no-restore -p:AssemblyName=Nativune -p:Version=$Version -p:DebugType=none -p:DebugSymbols=false -p:UpdaterTestHooks=false -p:PerfBenchHooks=false -o $appPublishRoot
        if ($LASTEXITCODE -ne 0) { throw 'The application publish failed.' }
        Assert-NoBundledAppRuntime $appPublishRoot 'The published Nativune app'
        if (-not $stubReused) {
            & $dotnetExecutable publish $installerProjectPath @installerPublishOptions -o $setupPublishRoot
            if ($LASTEXITCODE -ne 0) { throw 'The installer stub publish failed.' }
        }
    } finally {
        Pop-Location
    }

    $appDestination = Join-Path $stageRoot 'app'
    Copy-TreeContent $appPublishRoot $appDestination
    $appExecutable = Join-Path $appDestination 'Nativune.exe'
    Assert-NoBundledAppRuntime $appDestination 'The staged Nativune app'
    Assert-RegularFile $appExecutable 'The published Nativune executable'
    $stubPath = Join-Path $setupPublishRoot 'Nativune.Setup.exe'
    Assert-RegularFile $stubPath 'The published setup stub'
    $stubSha256 = (Get-FileHash -LiteralPath $stubPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($stubReused) { Write-Host "Installer stub: reused $stubSha256" } else { Write-Host "Installer stub: built $stubSha256" }
    # Test and benchmark seams must be compiled out of public builds (UpdaterTestHooks/PerfBenchHooks/InstallerTestHooks=false above).
    $seamChecks = @(
        @{ Path = Join-Path $appPublishRoot 'Nativune.dll'; Markers = @('NATIVUNE_TEST_RELEASE_METADATA_URL', 'NATIVUNE_BENCH_') },
        @{ Path = $stubPath; Markers = @('--test-prerequisites') }
    )
    foreach ($check in $seamChecks) {
        $bytes = [IO.File]::ReadAllBytes($check.Path)
        foreach ($marker in $check.Markers) {
            foreach ($encoding in @([Text.Encoding]::UTF8, [Text.Encoding]::Unicode)) {
                $needle = $encoding.GetBytes($marker)
                $text = [Text.Encoding]::Latin1.GetString($bytes)
                if ($text.Contains([Text.Encoding]::Latin1.GetString($needle), [StringComparison]::Ordinal)) {
                    throw "A test seam ($marker) is present in $($check.Path)."
                }
            }
        }
    }

    $ubolDestination = Join-Path $stageRoot ".tools/ubol/$ubolVersion"
    Copy-TreeContent $ubolSource $ubolDestination

    $installerDestination = Join-Path $stageRoot 'installer'
    [IO.Directory]::CreateDirectory($installerDestination) | Out-Null
    Copy-Item -LiteralPath $stubPath -Destination (Join-Path $installerDestination 'Nativune.Setup.exe') -Force

    $licensesDestination = Join-Path $stageRoot 'licenses'
    [IO.Directory]::CreateDirectory($licensesDestination) | Out-Null
    Copy-Item -LiteralPath $appSdkLicense -Destination (Join-Path $licensesDestination 'Microsoft-WindowsAppSDK.txt') -Force
    Copy-Item -LiteralPath $dotnetLicense -Destination (Join-Path $licensesDestination 'Microsoft-DotNet-LICENSE.txt') -Force
    Copy-Item -LiteralPath $dotnetNotice -Destination (Join-Path $licensesDestination 'Microsoft-DotNet-ThirdPartyNotices.txt') -Force
    Copy-Item -LiteralPath $webView2License -Destination (Join-Path $licensesDestination 'Microsoft-WebView2-SDK-LICENSE.txt') -Force
    Copy-Item -LiteralPath $webView2Notice -Destination (Join-Path $licensesDestination 'Microsoft-WebView2-SDK-NOTICE.txt') -Force
    Copy-Item -LiteralPath $nativuneLicense -Destination (Join-Path $licensesDestination 'Nativune-LICENSE.txt') -Force
    Copy-Item -LiteralPath $repositoryNotice -Destination (Join-Path $licensesDestination 'THIRD-PARTY-NOTICES.txt') -Force

    $fixedWebViewPath = Join-Path $stageRoot '.tools/webview2'
    $runtimeMarkers = @(Get-ChildItem -LiteralPath $stageRoot -Recurse -File -Force | Where-Object { $_.Name -eq 'runtime-path.txt' })
    if ((Test-Path -LiteralPath $fixedWebViewPath) -or $runtimeMarkers.Count -gt 0) {
        throw 'The public release payload unexpectedly contains a fixed WebView2 runtime or runtime marker.'
    }
    Assert-NoBundledAppRuntime (Join-Path $stageRoot 'app') 'The public Nativune app payload'
    Assert-PublicTree $stageRoot
    New-Manifest $stageRoot
    Assert-RegularFile (Join-Path $stageRoot 'release-manifest.json') 'The generated release manifest'
    New-CanonicalZip $stageRoot $zipPath
    Remove-SafeOutputFile $releaseZipPath 'The release ZIP output'
    Remove-SafeOutputFile $setupPath 'The setup executable output'
    Remove-SafeOutputFile $manifestPath 'The release manifest output'
    Remove-SafeOutputFile $checksumsPath 'The checksum output'
    Remove-SafeOutputFile $deltaDescriptorPath 'The delta update descriptor output'
    Copy-Item -LiteralPath $zipPath -Destination $releaseZipPath
    New-AppendedSetup $stubPath $zipPath $setupPath
    Copy-Item -LiteralPath (Join-Path $stageRoot 'release-manifest.json') -Destination $manifestPath

    $descriptor = [ordered]@{
        schemaVersion = 1
        product = 'Nativune'
        version = $Version
        enabled = $true
        applyProtocol = 1
        installerSha256 = $stubSha256
        installerSourceSha256 = $installerSourceSha256
    }
    [IO.File]::WriteAllText($deltaDescriptorPath, ($descriptor | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))

    $checksumNames = @('Nativune-Setup.exe', 'Nativune-Setup.zip', 'delta-update.json', 'release-manifest.json')
    $checksumLines = foreach ($name in ($checksumNames | Sort-Object)) {
        $path = Join-Path $releaseRoot $name
        $hash = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        "$hash  $name"
    }
    [IO.File]::WriteAllLines($checksumsPath, $checksumLines, [Text.UTF8Encoding]::new($false))
    Write-Host "Created $setupPath"
    Write-Host "Created $releaseZipPath"
    Write-Host "Created $manifestPath"
    Write-Host "Created $deltaDescriptorPath"
    Write-Host "Created $checksumsPath"
} finally {
    if (Test-Path -LiteralPath $workRoot) {
        [void](Resolve-RepositoryPath $workRoot)
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
