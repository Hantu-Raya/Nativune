# Builds Barebones Better Lyrics (GPL-3.0 fork of Better Lyrics v2.4.1) with the repository-local Node
# and publishes the Chrome build to .tools/better-lyrics/<version>/ (never mutating an existing version).
# Usage (from the repository root; run scripts/setup-node.ps1 first):
#   pwsh -NoProfile -File scripts/setup-better-lyrics.ps1
#   pwsh -NoProfile -File scripts/setup-better-lyrics.ps1 -Source .cache/better-lyrics/dev
#   pwsh -NoProfile -File scripts/setup-better-lyrics.ps1 -Verify
#   pwsh -NoProfile -File scripts/setup-better-lyrics.ps1 -AllowInstallScripts
#   pwsh -NoProfile -File scripts/setup-better-lyrics.ps1 -FromPinned
#   pwsh -NoProfile -File scripts/setup-better-lyrics.ps1 -SourceArchive artifacts/release/barebones-better-lyrics-2.4.1.2-source.zip
# -FromPinned deletes and freshly clones release-inputs.json betterLyrics.sourceRepo into .cache/better-lyrics/src,
#   checks out betterLyrics.sourceCommit, verifies HEAD, then builds from that clone. Its only allowed target is
#   .cache/better-lyrics/src; any other -Source is refused, because the target is deleted first.
# -SourceArchive writes `git archive --format=zip` of betterLyrics.sourceCommit from -Source (including
#   package-lock.json) and prints its SHA-256. Entry times come from the commit time (UTC), so the ZIP is
#   deterministic. Nothing is built or published in this mode (with -FromPinned it clones, then archives).
# -Verify builds into .cache/build/better-lyrics-verify/ and compares the tree with
#   release-inputs.json betterLyrics.treeSha256/fileCount/totalBytes; nothing is published.
# -AllowInstallScripts drops `--ignore-scripts` from `npm ci`. Use only if the build fails without
#   dependency install scripts; it runs third-party package lifecycle scripts.
# Output: .tools/better-lyrics/<version>/ plus .tools/better-lyrics/<version>.fingerprint.json beside it.
[CmdletBinding()]
param(
    [string] $Source = '.cache/better-lyrics/dev',
    [switch] $Verify,
    [switch] $AllowInstallScripts,
    [switch] $FromPinned,
    [string] $SourceArchive = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

function Assert-NoReparsePoints([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($item in @((Get-Item -LiteralPath $Path -Force)) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing reparse point: $($item.FullName)"
        }
    }
}

function Assert-NotReparse([string] $Path) {
    if ((Test-Path -LiteralPath $Path) -and ((Get-Item -LiteralPath $Path -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing reparse point: $Path"
    }
}

# Every write, create or delete goes through this first: the path must be inside the repository, and no existing
# component from the repository root down to it (the leaf included, even a dangling link) may be a reparse point.
# Checking only the leaf misses a junction at .cache or .tools, which CreateDirectory would silently follow.
function Assert-RepoWritePath([string] $Path) {
    $full = [IO.Path]::GetFullPath($Path)
    $rootFull = [IO.Path]::GetFullPath($root).TrimEnd('\', '/')
    if (-not $full.StartsWith($rootFull + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing a write outside the repository: $full"
    }
    $current = $rootFull
    foreach ($part in @($full.Substring($rootFull.Length) -split '[\\/]' | Where-Object { $_ -ne '' })) {
        $current = Join-Path $current $part
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException], [IO.DirectoryNotFoundException] { return }
        if (($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw "Refusing reparse point: $current" }
    }
}

function Relative-ForwardPath([string] $Root, [string] $Path) {
    return $Path.Substring($Root.Length).TrimStart([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar).Replace([IO.Path]::DirectorySeparatorChar, '/')
}

# Same algorithm as Get-TreeFingerprint in scripts/build-release.ps1.
function Get-TreeFingerprint([string] $Root) {
    if (-not (Test-Path -LiteralPath $Root -PathType Container)) { throw "The fingerprint source directory is missing: $Root" }
    Assert-NoReparsePoints $Root
    $Root = (Resolve-Path -LiteralPath $Root).Path
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

function Invoke-Checked([string] $Exe, [string[]] $Arguments, [string] $What) {
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$What failed with exit code $LASTEXITCODE." }
}

$inputs = Get-Content -LiteralPath (Join-Path $root 'release-inputs.json') -Raw | ConvertFrom-Json
$pinnedCommit = ([string] $inputs.betterLyrics.sourceCommit).Trim()
if (($FromPinned -or $SourceArchive -ne '') -and $pinnedCommit -notmatch '^[0-9a-f]{40}$') {
    throw 'release-inputs.json betterLyrics.sourceCommit is not set to a full commit SHA.'
}
$pinnedClone = [IO.Path]::GetFullPath((Join-Path $root '.cache/better-lyrics/src'))
if ($FromPinned -and -not $PSBoundParameters.ContainsKey('Source')) { $Source = '.cache/better-lyrics/src' }
$sourcePath = if ([IO.Path]::IsPathRooted($Source)) { [IO.Path]::GetFullPath($Source) } else { [IO.Path]::GetFullPath((Join-Path $root $Source)) }
# -FromPinned deletes its target before cloning, so it may only ever target the dedicated clone directory (never the
# repository, an ancestor, the dev clone under .cache/better-lyrics/dev, or anything outside the repository).
if ($FromPinned -and -not [string]::Equals($sourcePath.TrimEnd('\', '/'), $pinnedClone, [StringComparison]::OrdinalIgnoreCase)) {
    throw "-FromPinned only clones into $pinnedClone; refusing -Source $sourcePath."
}

if ($FromPinned) {
    $sourceRepo = [string] $inputs.betterLyrics.sourceRepo
    if ($sourceRepo -notmatch '^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw "Unexpected betterLyrics.sourceRepo: $sourceRepo" }
    Assert-RepoWritePath $sourcePath
    if (Test-Path -LiteralPath $sourcePath) {
        Assert-NoReparsePoints $sourcePath
        Remove-Item -LiteralPath $sourcePath -Recurse -Force
    }
    [IO.Directory]::CreateDirectory((Split-Path -Parent $sourcePath)) | Out-Null
    Invoke-Checked 'git' @('-c', 'core.autocrlf=false', 'clone', '-c', 'core.autocrlf=false', '--no-checkout', '--', $sourceRepo, $sourcePath) 'git clone'
    Invoke-Checked 'git' @('-C', $sourcePath, '-c', 'core.autocrlf=false', 'checkout', '--detach', '--quiet', $pinnedCommit) 'git checkout of the pinned commit'
    $head = ([string] (& git -C $sourcePath rev-parse HEAD)).Trim()
    if ($LASTEXITCODE -ne 0 -or $head -cne $pinnedCommit) { throw "Cloned HEAD '$head' does not match the pinned commit $pinnedCommit." }
    Write-Host "Cloned $sourceRepo at pinned commit $pinnedCommit into $sourcePath"
}

if (-not (Test-Path -LiteralPath $sourcePath -PathType Container)) { throw "Better Lyrics source directory is missing: $sourcePath" }
$sourcePath = (Resolve-Path -LiteralPath $sourcePath).Path
Assert-NotReparse $sourcePath

if ($SourceArchive -ne '') {
    $archivePath = if ([IO.Path]::IsPathRooted($SourceArchive)) { [IO.Path]::GetFullPath($SourceArchive) } else { [IO.Path]::GetFullPath((Join-Path $root $SourceArchive)) }
    if ($archivePath -notlike '*.zip') { throw "-SourceArchive must name a .zip file: $archivePath" }
    & git -C $sourcePath cat-file -e "$pinnedCommit^{commit}"
    if ($LASTEXITCODE -ne 0) { throw "The pinned commit $pinnedCommit is not present in $sourcePath." }
    & git -C $sourcePath cat-file -e "${pinnedCommit}:package-lock.json"
    if ($LASTEXITCODE -ne 0) { throw 'The pinned commit has no package-lock.json; the source archive would not be reproducible.' }
    & git -C $sourcePath cat-file -e "${pinnedCommit}:LICENSE"
    if ($LASTEXITCODE -ne 0) { throw 'The pinned commit has no LICENSE file.' }
    $archiveParent = Split-Path -Parent $archivePath
    Assert-RepoWritePath $archivePath
    [IO.Directory]::CreateDirectory($archiveParent) | Out-Null
    Assert-RepoWritePath $archivePath
    if (Test-Path -LiteralPath $archivePath) {
        Remove-Item -LiteralPath $archivePath -Force
    }
    $prefix = "barebones-better-lyrics-$([string] $inputs.betterLyrics.version)/"
    $savedTz = [Environment]::GetEnvironmentVariable('TZ', 'Process')
    try {
        # Archiving a commit (not a tree) stamps every entry with the commit time; UTC keeps the
        # ZIP's local-time DOS timestamps identical on every machine.
        $env:TZ = 'UTC0'
        Invoke-Checked 'git' @('-C', $sourcePath, '-c', 'core.autocrlf=false', 'archive', '--format=zip', "--prefix=$prefix", "--output=$archivePath", $pinnedCommit) 'git archive'
    } finally {
        [Environment]::SetEnvironmentVariable('TZ', $savedTz, 'Process')
    }
    $archiveHash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "Source archive: $archivePath"
    Write-Host "SHA-256: $archiveHash"
    return
}

$nodeVersion = [string] $inputs.node.version
$nodeRoot = Join-Path $root ".tools\node\$nodeVersion"
$nodeExe = Join-Path $nodeRoot 'node.exe'
$npmCli = Join-Path $nodeRoot 'node_modules\npm\bin\npm-cli.js'
$npxCli = Join-Path $nodeRoot 'node_modules\npm\bin\npx-cli.js'
$marker = Join-Path $nodeRoot '.nativune-archive-sha256'
if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf) -or -not (Test-Path -LiteralPath $npmCli -PathType Leaf) -or
    -not (Test-Path -LiteralPath $marker -PathType Leaf) -or (Get-Content -LiteralPath $marker -Raw).Trim() -ne [string] $inputs.node.sha256) {
    throw "Verified repository-local Node $nodeVersion is missing; run scripts/setup-node.ps1 first."
}
Assert-NoReparsePoints $nodeRoot

$packageJsonPath = Join-Path $sourcePath 'package.json'
Assert-NotReparse $packageJsonPath
$packageJson = Get-Content -LiteralPath $packageJsonPath -Raw | ConvertFrom-Json
$hasNativuneBuild = $false
if ($null -ne $packageJson.PSObject.Properties['scripts'] -and $null -ne $packageJson.scripts.PSObject.Properties['build:nativune']) {
    $hasNativuneBuild = $true
}

$saved = @{}
foreach ($name in @('TEMP', 'TMP', 'npm_config_cache', 'npm_config_update_notifier', 'npm_config_fund', 'npm_config_audit', 'PATH')) {
    $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
$oldLocation = Get-Location
try {
    $env:TEMP = Join-Path $root '.cache\tmp'
    $env:TMP = $env:TEMP
    $env:npm_config_cache = Join-Path $root '.cache\npm'
    $env:npm_config_update_notifier = 'false'
    $env:npm_config_fund = 'false'
    $env:npm_config_audit = 'false'
    # Process-only: let npm lifecycle scripts resolve the pinned node.exe first.
    $env:PATH = "$nodeRoot;$($saved['PATH'])"
    foreach ($p in @($env:TEMP, $env:npm_config_cache)) {
        Assert-RepoWritePath $p
        [IO.Directory]::CreateDirectory($p) | Out-Null
        Assert-RepoWritePath $p
    }

    Set-Location -LiteralPath $sourcePath
    $ciArgs = @($npmCli, 'ci')
    if (-not $AllowInstallScripts) { $ciArgs += '--ignore-scripts' }
    Invoke-Checked $nodeExe $ciArgs 'npm ci'
    if ($hasNativuneBuild) {
        Invoke-Checked $nodeExe @($npmCli, 'run', 'build:nativune') 'npm run build:nativune'
    } else {
        Invoke-Checked $nodeExe @($npxCli, '--no-install', 'extension', 'build', '--browser', 'chrome', '--polyfill') 'extension build'
    }
    Set-Location -LiteralPath $oldLocation

    $dist = Join-Path $sourcePath 'dist\chrome'
    Assert-NoReparsePoints $dist
    $manifest = Get-Content -LiteralPath (Join-Path $dist 'manifest.json') -Raw | ConvertFrom-Json
    $version = [string] $manifest.version
    if ($version -notmatch '^\d+(\.\d+){1,3}$') { throw "Unexpected manifest version: $version" }
    if ([string] $manifest.name -ne [string] $inputs.betterLyrics.name) { throw 'Built manifest name does not match release-inputs.json.' }

    $commit = (& git -C $sourcePath rev-parse HEAD)
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the source git commit.' }
    $status = @(& git -C $sourcePath status --porcelain)
    if ($LASTEXITCODE -ne 0) { throw 'Could not read the source git status.' }
    $dirty = $status.Count -gt 0

    if ($Verify) {
        $verifyRoot = Join-Path $root '.cache\build\better-lyrics-verify'
        Assert-RepoWritePath $verifyRoot
        if (Test-Path -LiteralPath $verifyRoot) {
            Assert-NoReparsePoints $verifyRoot
            Remove-Item -LiteralPath $verifyRoot -Recurse -Force
        }
        [IO.Directory]::CreateDirectory((Split-Path -Parent $verifyRoot)) | Out-Null
        Copy-Item -LiteralPath $dist -Destination $verifyRoot -Recurse
        $fp = Get-TreeFingerprint $verifyRoot
        $expected = $inputs.betterLyrics
        if ([string] $expected.treeSha256 -eq '') { throw "release-inputs.json betterLyrics.treeSha256 is not set; built tree is $($fp.sha256) ($($fp.fileCount) files, $($fp.totalBytes) bytes)." }
        if ($version -ne [string] $expected.version -or $fp.sha256 -ne [string] $expected.treeSha256 -or
            $fp.fileCount -ne [int64] $expected.fileCount -or $fp.totalBytes -ne [int64] $expected.totalBytes) {
            throw "Rebuilt Better Lyrics tree does not match release-inputs.json (got $($fp.sha256), $($fp.fileCount) files, $($fp.totalBytes) bytes)."
        }
        Write-Host "Verified: rebuilt Barebones Better Lyrics $version matches release-inputs.json ($($fp.sha256))."
        return
    }

    $toolsRoot = Join-Path $root '.tools\better-lyrics'
    Assert-RepoWritePath $toolsRoot
    [IO.Directory]::CreateDirectory($toolsRoot) | Out-Null
    $target = Join-Path $toolsRoot $version
    $fingerprintPath = Join-Path $toolsRoot "$version.fingerprint.json"
    Assert-RepoWritePath $target
    Assert-RepoWritePath $fingerprintPath
    $built = Get-TreeFingerprint $dist

    if (Test-Path -LiteralPath $target) {
        $existing = Get-TreeFingerprint $target
        if ($existing.sha256 -ne $built.sha256 -or $existing.fileCount -ne $built.fileCount -or $existing.totalBytes -ne $built.totalBytes) {
            throw "Published Better Lyrics $version differs from this build; left unchanged: $target. Bump the fork version instead."
        }
        Write-Host "Better Lyrics $version already published and identical: $target"
    } else {
        $staging = Join-Path $toolsRoot ".staging-$version-$([Guid]::NewGuid().ToString('N'))"
        try {
            Copy-Item -LiteralPath $dist -Destination $staging -Recurse
            $staged = Get-TreeFingerprint $staging
            if ($staged.sha256 -ne $built.sha256) { throw 'Staged Better Lyrics tree differs from the build output.' }
            Move-Item -LiteralPath $staging -Destination $target
        } finally {
            if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
        }
        Write-Host "Published Barebones Better Lyrics $version to $target"
    }

    $record = [ordered]@{
        name = [string] $manifest.name
        version = $version
        treeSha256 = $built.sha256
        fileCount = $built.fileCount
        totalBytes = $built.totalBytes
        sourceCommit = ([string] $commit).Trim()
        sourceDirty = $dirty
    }
    $json = $record | ConvertTo-Json
    if (Test-Path -LiteralPath $fingerprintPath) {
        Assert-NotReparse $fingerprintPath
        $old = Get-Content -LiteralPath $fingerprintPath -Raw | ConvertFrom-Json
        if ([string] $old.treeSha256 -ne $built.sha256) { throw "Existing fingerprint file disagrees with the published tree: $fingerprintPath" }
    }
    Set-Content -LiteralPath $fingerprintPath -Value $json -Encoding utf8NoBOM
    if ($dirty) { Write-Warning 'The source working tree is dirty; this build is not reproducible from sourceCommit.' }
    Write-Host "Fingerprint: $($built.sha256) ($($built.fileCount) files, $($built.totalBytes) bytes) -> $fingerprintPath"
} finally {
    Set-Location -LiteralPath $oldLocation
    foreach ($name in $saved.Keys) {
        [Environment]::SetEnvironmentVariable($name, $saved[$name], 'Process')
    }
}
