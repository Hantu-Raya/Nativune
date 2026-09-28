# Installs a repository-local, hash-pinned Node.js used only to build Barebones Better Lyrics.
# Usage (from the repository root):
#   pwsh -NoProfile -File scripts/setup-node.ps1
# Pinned: Node v24.21.0 (24.x LTS, satisfies ^24.15.0), win-x64 zip.
# Sources: https://nodejs.org/dist/index.json and
#          https://nodejs.org/dist/v24.21.0/SHASUMS256.txt
# No PATH, registry or global changes are made; the node.exe path is printed.
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$version = '24.21.0'
$archiveName = "node-v$version-win-x64.zip"
$expectedHash = '158f7685b44de51f6c0df1d153526cbcd3e1bc739a8dfc607721cef75de9e541'
$url = "https://nodejs.org/dist/v$version/$archiveName"
$cache = Join-Path $root '.cache\downloads'
$archive = Join-Path $cache $archiveName
$toolsNode = Join-Path $root '.tools\node'
$target = Join-Path $toolsNode $version
$nodeExe = Join-Path $target 'node.exe'
$marker = Join-Path $target '.nativune-archive-sha256'

function Assert-NoReparsePoints([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    foreach ($item in @((Get-Item -LiteralPath $Path -Force)) + @(Get-ChildItem -LiteralPath $Path -Recurse -Force)) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Refusing reparse point: $($item.FullName)"
        }
    }
}

# Every write, create or delete goes through this first: the path must be inside the repository, and no existing
# component from the repository root down to it (the leaf included, even a dangling link) may be a reparse point.
# Same helper as scripts/setup-better-lyrics.ps1.
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

$oldTemp = $env:TEMP
$oldTmp = $env:TMP
try {
    $env:TEMP = Join-Path $root '.cache\tmp'
    $env:TMP = $env:TEMP
    # Check every write path (and each existing ancestor) before creating anything, so a junction at .cache or
    # .tools, or a linked partial download, cannot redirect writes or deletions outside the repository.
    foreach ($p in @($env:TEMP, $archive, "$archive.download", $target)) { Assert-RepoWritePath $p }
    [IO.Directory]::CreateDirectory($env:TEMP) | Out-Null
    [IO.Directory]::CreateDirectory($cache) | Out-Null
    foreach ($p in @($env:TEMP, $archive, "$archive.download", $target)) { Assert-RepoWritePath $p }

    if (Test-Path -LiteralPath $target) {
        Assert-NoReparsePoints $target
        if (-not (Test-Path -LiteralPath $nodeExe -PathType Leaf) -or -not (Test-Path -LiteralPath $marker -PathType Leaf) -or
            (Get-Content -LiteralPath $marker -Raw).Trim() -ne $expectedHash) {
            throw "Node directory exists but is not a verified install; left unchanged: $target"
        }
        Write-Host "Verified Node $version already present."
        Write-Output $nodeExe
        return
    }

    if (-not (Test-Path -LiteralPath $archive)) {
        if (Test-Path -LiteralPath "$archive.download") { Remove-Item -LiteralPath "$archive.download" -Force }
        Invoke-WebRequest -Uri $url -OutFile "$archive.download"
        if ((Get-FileHash -LiteralPath "$archive.download" -Algorithm SHA256).Hash -ne $expectedHash) {
            Remove-Item -LiteralPath "$archive.download" -Force
            throw 'Node download checksum does not match the pinned release.'
        }
        Move-Item -LiteralPath "$archive.download" -Destination $archive
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expectedHash) {
        throw 'Cached Node archive checksum does not match the pinned release.'
    }

    $staging = Join-Path $env:TEMP "node-$version-$([Guid]::NewGuid().ToString('N'))"
    Assert-RepoWritePath $staging
    try {
        [IO.Compression.ZipFile]::ExtractToDirectory($archive, $staging)
        $inner = Join-Path $staging "node-v$version-win-x64"
        if (-not (Test-Path -LiteralPath (Join-Path $inner 'node.exe') -PathType Leaf)) {
            throw 'The Node archive layout is unexpected.'
        }
        Assert-NoReparsePoints $inner
        Set-Content -LiteralPath (Join-Path $inner '.nativune-archive-sha256') -Value $expectedHash -NoNewline
        [IO.Directory]::CreateDirectory($toolsNode) | Out-Null
        if (Test-Path -LiteralPath $target) { throw "Node directory appeared concurrently; left unchanged: $target" }
        Move-Item -LiteralPath $inner -Destination $target
    } finally {
        if (Test-Path -LiteralPath $staging) { Remove-Item -LiteralPath $staging -Recurse -Force }
    }
    Write-Host "Verified Node $version extracted to $target"
    Write-Output $nodeExe
} finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
}
