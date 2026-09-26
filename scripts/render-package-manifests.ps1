[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidatePattern('^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')]
    [string] $Version,
    [Parameter(Mandatory)]
    [string] $ReleaseDirectory,
    [string] $OutputDirectory = '',
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string] $ReleaseDate = (Get-Date -AsUTC -Format 'yyyy-MM-dd')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
function Resolve-RepositoryPath([string] $Path) {
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    return [IO.Path]::GetFullPath((Join-Path $repository $Path))
}

if (-not $OutputDirectory) { $OutputDirectory = "artifacts/package-managers/$Version" }
$releaseRoot = Resolve-RepositoryPath $ReleaseDirectory
$outputRoot = Resolve-RepositoryPath $OutputDirectory
$setupPath = Join-Path $releaseRoot 'Nativune-Setup.exe'
$checksumsPath = Join-Path $releaseRoot 'SHA256SUMS.txt'
foreach ($path in $setupPath, $checksumsPath) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing release file: $path" }
}

$entries = @(Get-Content -LiteralPath $checksumsPath | Where-Object { $_ -match '^([0-9A-Fa-f]{64})\s+\*?Nativune-Setup\.exe$' })
if ($entries.Count -ne 1) { throw "SHA256SUMS.txt must contain exactly one Nativune-Setup.exe entry." }
$expectedHash = ($entries[0] -split '\s+')[0].ToUpperInvariant()
$actualHash = (Get-FileHash -LiteralPath $setupPath -Algorithm SHA256).Hash.ToUpperInvariant()
if ($actualHash -ne $expectedHash) { throw "Nativune-Setup.exe hash $actualHash does not match SHA256SUMS.txt ($expectedHash)." }

$replacements = @{
    '{{VERSION}}'      = $Version
    '{{SETUP_SHA256}}' = $actualHash
    '{{RELEASE_DATE}}' = $ReleaseDate
}
$targets = @(
    @{ Source = 'packaging/winget'; Destination = Join-Path $outputRoot "winget/manifests/n/Nativune/Nativune/$Version" },
    @{ Source = 'packaging/chocolatey'; Destination = Join-Path $outputRoot 'chocolatey/nativune' }
)
$utf8 = [Text.UTF8Encoding]::new($false)
foreach ($target in $targets) {
    $sourceRoot = Join-Path $repository $target.Source
    if (Test-Path -LiteralPath $target.Destination) { Remove-Item -LiteralPath $target.Destination -Recurse -Force }
    foreach ($file in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse) {
        $relative = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName)
        $destination = Join-Path $target.Destination $relative
        $text = [IO.File]::ReadAllText($file.FullName)
        foreach ($key in $replacements.Keys) { $text = $text.Replace($key, $replacements[$key]) }
        if ($text.Contains('{{')) { throw "Unresolved placeholder in $relative." }
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $destination) | Out-Null
        [IO.File]::WriteAllText($destination, $text, $utf8)
    }
}

Write-Host "Rendered package manifests for $Version into $outputRoot"
