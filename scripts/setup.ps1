[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This setup script is Windows-only.'
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$cache = Join-Path $root '.cache'
$sdkRoot = Join-Path $root '.tools\dotnet'
$archive = Join-Path $cache 'dotnet-sdk-10.0.401-win-x64.zip'
$provenance = Join-Path $cache 'dotnet-sdk-10.0.401-win-x64.provenance.json'
$url = 'https://builds.dotnet.microsoft.com/dotnet/Sdk/10.0.401/dotnet-sdk-10.0.401-win-x64.zip'
$sha512 = '24b670ad3d923bfcf47df6c3b034152398b42f6dbc388e10d783aee1cfb5e5817d399fc0ae2a12cfa822a55e61d34830ccb15c50ef6efee437ab874bb7c79430'

[IO.Directory]::CreateDirectory($cache) | Out-Null
[IO.Directory]::CreateDirectory((Split-Path $sdkRoot -Parent)) | Out-Null

if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
    $partial = "$archive.download"
    Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
    Invoke-WebRequest -Uri $url -OutFile $partial -UseBasicParsing
    Move-Item -LiteralPath $partial -Destination $archive
}

$actualSha512 = (Get-FileHash -LiteralPath $archive -Algorithm SHA512).Hash.ToLowerInvariant()
if ($actualSha512 -ne $sha512) {
    throw "SDK archive SHA512 mismatch. Expected $sha512, got $actualSha512."
}

$provenanceObject = [ordered]@{
    sourceMetadata = 'https://builds.dotnet.microsoft.com/dotnet/release-metadata/10.0/releases.json'
    version = '10.0.401'
    rid = 'win-x64'
    archive = 'dotnet-sdk-10.0.401-win-x64.zip'
    url = $url
    sha512 = $sha512
}
$provenanceObject | ConvertTo-Json | Set-Content -LiteralPath $provenance -Encoding UTF8

$marker = Join-Path $sdkRoot '.provenance.json'
$ready = (Test-Path -LiteralPath (Join-Path $sdkRoot 'dotnet.exe') -PathType Leaf) -and (Test-Path -LiteralPath $marker -PathType Leaf)
if ($ready) {
    try {
        $installed = Get-Content -LiteralPath $marker -Raw | ConvertFrom-Json
        $ready = $installed.sha512 -eq $sha512 -and $installed.version -eq '10.0.401'
    } catch {
        $ready = $false
    }
}

if (-not $ready) {
    $extractRoot = Join-Path $cache ("dotnet-extract-" + [Guid]::NewGuid().ToString('N'))
    try {
        Expand-Archive -LiteralPath $archive -DestinationPath $extractRoot -Force
        if (-not (Test-Path -LiteralPath (Join-Path $extractRoot 'dotnet.exe') -PathType Leaf)) {
            throw 'SDK archive did not contain dotnet.exe at its root.'
        }
        if (Test-Path -LiteralPath $sdkRoot) {
            Remove-Item -LiteralPath $sdkRoot -Recurse -Force
        }
        Move-Item -LiteralPath $extractRoot -Destination $sdkRoot
        $provenanceObject | ConvertTo-Json | Set-Content -LiteralPath $marker -Encoding UTF8
    } finally {
        if (Test-Path -LiteralPath $extractRoot) {
            Remove-Item -LiteralPath $extractRoot -Recurse -Force
        }
    }
}

Write-Host "SDK $($provenanceObject.version) ready at $sdkRoot (SHA512 $sha512)."
