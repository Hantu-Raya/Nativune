[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) {
    throw 'This setup script is Windows-only.'
}

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$runtimeRoot = Join-Path $root '.tools\webview2'
$cacheRoot = Join-Path $runtimeRoot '.cache'
$tempRoot = Join-Path $cacheRoot 'tmp'
$version = '152.0.4191.62'
$architecture = 'x64'
$runtimeDirectoryName = $version
$runtimeDirectory = Join-Path $runtimeRoot $runtimeDirectoryName
$runtimePathFile = Join-Path $runtimeRoot 'runtime-path.txt'
$archiveName = "Microsoft.WebView2.FixedVersionRuntime.$version.$architecture.cab"
$archive = Join-Path $cacheRoot $archiveName
$partialArchive = "$archive.download"
$url = 'https://msedge.sf.dl.delivery.mp.microsoft.com/filestreamingservice/files/0a4a34d9-ccaa-4cef-98b4-58cb313fbfeb/Microsoft.WebView2.FixedVersionRuntime.152.0.4191.62.x64.cab'
$sourceMetadata = 'https://developer.microsoft.com/microsoft-edge/api/webview2'
$expand = Join-Path $env:SystemRoot 'System32\expand.exe'
if (-not (Test-Path -LiteralPath $expand -PathType Leaf)) {
    throw "Windows expand.exe is missing: $expand"
}

function Test-X64Pe([string] $Path) {
    $stream = [IO.File]::OpenRead($Path)
    try {
        $reader = New-Object IO.BinaryReader($stream)
        if ($reader.ReadUInt16() -ne 0x5a4d) { return $false }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadInt32()
        if ($peOffset -lt 0 -or $peOffset -gt $stream.Length - 24) { return $false }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x00004550) { return $false }
        return $reader.ReadUInt16() -eq 0x8664
    } finally {
        $stream.Dispose()
    }
}

function Assert-RuntimeExecutable([string] $Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Fixed runtime executable is missing: $Path"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid') {
        throw "Fixed runtime executable signature is not valid ($($signature.Status)): $Path"
    }
    if ($null -eq $signature.SignerCertificate -or $signature.SignerCertificate.Subject -notmatch 'Microsoft') {
        throw "Fixed runtime executable is not signed by Microsoft: $Path"
    }
    if (-not (Test-X64Pe $Path)) {
        throw "Fixed runtime executable is not an x64 PE: $Path"
    }
}

$oldTemp = $env:TEMP
$oldTmp = $env:TMP
try {
    [IO.Directory]::CreateDirectory($cacheRoot) | Out-Null
    [IO.Directory]::CreateDirectory($tempRoot) | Out-Null
    $env:TEMP = $tempRoot
    $env:TMP = $tempRoot

    $executable = Join-Path $runtimeDirectory 'msedgewebview2.exe'
    $runtimeReady = Test-Path -LiteralPath $executable -PathType Leaf
    if ($runtimeReady) {
        try {
            Assert-RuntimeExecutable $executable
        } catch {
            $runtimeReady = $false
        }
    }

    if (-not $runtimeReady) {
        Remove-Item -LiteralPath $runtimePathFile -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) {
            Remove-Item -LiteralPath $partialArchive -Force -ErrorAction SilentlyContinue
            Invoke-WebRequest -Uri $url -OutFile $partialArchive -UseBasicParsing
            if (-not (Test-Path -LiteralPath $partialArchive -PathType Leaf)) {
                throw "WebView2 runtime download did not produce an archive: $partialArchive"
            }
            Move-Item -LiteralPath $partialArchive -Destination $archive -Force
        }

        $extractRoot = Join-Path $tempRoot ("webview2-extract-" + [Guid]::NewGuid().ToString('N'))
        [IO.Directory]::CreateDirectory($extractRoot) | Out-Null
        try {
            $expandOutput = & $expand $archive '-F:*' $extractRoot 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "expand.exe failed with exit code $LASTEXITCODE. $($expandOutput -join ' ')"
            }

            $extractedExecutable = Get-ChildItem -LiteralPath $extractRoot -Filter 'msedgewebview2.exe' -File -Recurse | Select-Object -First 1
            if ($null -eq $extractedExecutable) {
                throw 'Fixed runtime archive did not contain msedgewebview2.exe.'
            }
            Assert-RuntimeExecutable $extractedExecutable.FullName

            if (Test-Path -LiteralPath $runtimeDirectory) {
                Remove-Item -LiteralPath $runtimeDirectory -Recurse -Force
            }
            [IO.Directory]::CreateDirectory($runtimeRoot) | Out-Null
            Move-Item -LiteralPath $extractedExecutable.DirectoryName -Destination $runtimeDirectory
            $executable = Join-Path $runtimeDirectory 'msedgewebview2.exe'
            Assert-RuntimeExecutable $executable
        } finally {
            if (Test-Path -LiteralPath $extractRoot) {
                Remove-Item -LiteralPath $extractRoot -Recurse -Force
            }
        }
    }

    $contractTemp = "$runtimePathFile.tmp"
    Set-Content -LiteralPath $contractTemp -Value $runtimeDirectoryName -Encoding ASCII
    Move-Item -LiteralPath $contractTemp -Destination $runtimePathFile -Force
    $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash.ToLowerInvariant()
    Write-Host "WebView2 Fixed Version $version ($architecture) ready at $runtimeDirectory (archive SHA256 $hash)."
    Write-Host "Source: $sourceMetadata"
} finally {
    $env:TEMP = $oldTemp
    $env:TMP = $oldTmp
    Remove-Item -LiteralPath $partialArchive -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $tempRoot '*') -Recurse -Force -ErrorAction SilentlyContinue
}
