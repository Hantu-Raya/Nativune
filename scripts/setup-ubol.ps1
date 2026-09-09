[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$version = '2026.907.2003'
$expectedHash = '56ba6fb728cc272bca1931792b1a4a15963eede4557ea829e5367e85d6057dd9'
$url = "https://github.com/uBlockOrigin/uBOL-home/releases/download/$version/uBOLite_$version.chromium.zip"
$cache = Join-Path $root '.cache\downloads'
$target = Join-Path $root ".tools\ubol\$version"
$archive = Join-Path $cache "ubol-$version.zip"
$oldTemp = $env:TEMP
$oldTmp = $env:TMP
try {
    $env:TEMP = Join-Path $root '.cache\tmp'
    $env:TMP = $env:TEMP
    [IO.Directory]::CreateDirectory($env:TEMP) | Out-Null
    [IO.Directory]::CreateDirectory($cache) | Out-Null
    if (-not (Test-Path -LiteralPath $archive)) {
        Invoke-WebRequest -Uri $url -OutFile "$archive.download"
        if ((Get-FileHash -LiteralPath "$archive.download" -Algorithm SHA256).Hash -ne $expectedHash) {
            throw 'uBO Lite download checksum does not match the pinned release.'
        }
        Move-Item -LiteralPath "$archive.download" -Destination $archive
    }
    if ((Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash -ne $expectedHash) {
        throw 'Cached uBO Lite checksum does not match the pinned release.'
    }
    if (Test-Path -LiteralPath $target) {
        throw "Extension directory already exists; left unchanged: $target"
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $target)
    Write-Host "Verified upstream uBO Lite $version extracted to $target"
    Write-Host 'The application must configure privacy-only filtering before loading Music.'
} finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
}
