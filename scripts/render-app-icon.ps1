[CmdletBinding()]
param(
    [string] $RendererPath,
    [string] $InputSvg,
    [string] $OutputIco
)

# Renders assets/app-icon/nativune-icon.svg into a multi-size Windows .ico with the pinned local
# resvg (see .tools/resvg/0.47.0/PROVENANCE.json). Each entry is a PNG, which Windows Vista and
# later accept inside .ico files. The .ico is committed; rerun this only when the SVG changes.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($RendererPath)) { $RendererPath = Join-Path $root '.tools\resvg\0.47.0\resvg.exe' }
if ([string]::IsNullOrWhiteSpace($InputSvg)) { $InputSvg = Join-Path $root 'assets\app-icon\nativune-icon.svg' }
if ([string]::IsNullOrWhiteSpace($OutputIco)) { $OutputIco = Join-Path $root 'assets\app-icon\nativune.ico' }
foreach ($path in @($RendererPath, $InputSvg)) {
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw "Missing input: $path" }
}

# Shell small/large icons at 100-200% scale, plus the 256 px Explorer/Start tile.
$sizes = @(16, 20, 24, 32, 40, 48, 64, 256)
$work = Join-Path $root ".cache\tmp\app-icon-$PID"
[IO.Directory]::CreateDirectory($work) | Out-Null
try {
    $images = foreach ($size in $sizes) {
        $png = Join-Path $work "$size.png"
        & $RendererPath -w $size -h $size $InputSvg $png
        if ($LASTEXITCODE -ne 0) { throw "resvg failed for $size px." }
        , [IO.File]::ReadAllBytes($png)
    }

    $stream = [IO.MemoryStream]::new()
    $writer = [IO.BinaryWriter]::new($stream)
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $dimension = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension)
        $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32)
        $writer.Write([uint32]$images[$i].Length); $writer.Write([uint32]$offset)
        $offset += $images[$i].Length
    }
    foreach ($image in $images) { $writer.Write($image) }
    $writer.Flush()
    [IO.File]::WriteAllBytes($OutputIco, $stream.ToArray())
    "Wrote $OutputIco ($($sizes -join ', ') px)."
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}
