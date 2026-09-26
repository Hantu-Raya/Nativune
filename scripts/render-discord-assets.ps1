[CmdletBinding()]
param(
    [Parameter()]
    [string] $RendererPath
)

# Regenerates the Discord Rich Presence art assets in assets\discord from the
# Nativune app icon and native-icon masters, using the pinned project-local resvg.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
if ([string]::IsNullOrWhiteSpace($RendererPath)) {
    $RendererPath = Join-Path $root '.tools\resvg\0.47.0\resvg.exe'
}
$outputRoot = Join-Path $root 'assets\discord'
$workRoot = Join-Path $root '.cache\discord-assets'
$accent = '#FF0033'   # AccentBrush in src\Nativune\ShellTheme.xaml
$glyph = '#FFFFFF'    # PrimaryTextBrush

function Fail([string] $message) { throw "Discord asset rendering refused: $message" }

if (-not (Test-Path -LiteralPath $RendererPath -PathType Leaf)) { Fail "renderer not found: $RendererPath (run scripts/setup.ps1)" }
$sidecar = "$RendererPath.sha256"
if (-not (Test-Path -LiteralPath $sidecar -PathType Leaf)) { Fail "renderer checksum sidecar missing: $sidecar" }
$expected = (Get-Content -LiteralPath $sidecar -Raw).Trim().ToLowerInvariant()
$actual = (Get-FileHash -LiteralPath $RendererPath -Algorithm SHA256).Hash.ToLowerInvariant()
if ($expected -ne $actual) { Fail "renderer SHA-256 mismatch: $RendererPath" }

New-Item -ItemType Directory -Force -Path $outputRoot, $workRoot | Out-Null

# Large image: the app icon's white tile filled edge to edge (Discord applies its own
# rounded-square crop), with the mark scaled to leave a generous safe margin.
[xml] $icon = Get-Content -LiteralPath (Join-Path $root 'assets\app-icon\nativune-icon.svg') -Raw
$ns = [System.Xml.XmlNamespaceManager]::new($icon.NameTable)
$ns.AddNamespace('s', 'http://www.w3.org/2000/svg')
$markGroup = $icon.SelectSingleNode('/s:svg/s:g', $ns)
if ($null -eq $markGroup) { Fail 'app icon mark group not found' }
$markInner = $markGroup.InnerXml -replace ' xmlns="http://www.w3.org/2000/svg"', ''
$large = @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="121.5 67.5 612 612" width="1024" height="1024">
  <rect x="121.5" y="67.5" width="612" height="612" fill="#FFFFFF"/>
  <g transform="translate(427.5 373.5) scale(0.72) translate(-427.5 -373.5)">$markInner</g>
</svg>
"@

# Badges: white 24-unit glyph scaled to 60% of the width inside a solid accent disc;
# everything outside the disc stays transparent.
function New-Badge([string] $master) {
    [xml] $svg = Get-Content -LiteralPath (Join-Path $root "assets\native-icons\masters\$master.svg") -Raw
    $m = [System.Xml.XmlNamespaceManager]::new($svg.NameTable)
    $m.AddNamespace('s', 'http://www.w3.org/2000/svg')
    $g = $svg.SelectSingleNode('/s:svg/s:g', $m)
    if ($null -eq $g) { Fail "glyph group not found in $master.svg" }
    $inner = $g.InnerXml -replace ' xmlns="http://www.w3.org/2000/svg"', ''
    $scale = 512 * 0.6 / 24
    $offset = (512 - 24 * $scale) / 2
    return @"
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 512 512" width="512" height="512">
  <circle cx="256" cy="256" r="256" fill="$accent"/>
  <g transform="translate($offset $offset) scale($scale)" fill="none" stroke="$glyph" stroke-width="2" stroke-linecap="round" stroke-linejoin="round">$inner</g>
</svg>
"@
}

$jobs = @(
    @{ Name = 'nativune-1024'; Svg = $large; Size = 1024 },
    @{ Name = 'pause-512'; Svg = (New-Badge 'pause'); Size = 512 },
    @{ Name = 'repeat-one-512'; Svg = (New-Badge 'repeat-one'); Size = 512 }
)
foreach ($job in $jobs) {
    $svgPath = Join-Path $workRoot "$($job.Name).svg"
    $pngPath = Join-Path $outputRoot "$($job.Name).png"
    [IO.File]::WriteAllText($svgPath, $job.Svg, [Text.UTF8Encoding]::new($false))
    & $RendererPath --width $job.Size --height $job.Size $svgPath $pngPath
    if ($LASTEXITCODE -ne 0) { Fail "resvg failed for $($job.Name)" }
    $bytes = [IO.File]::ReadAllBytes($pngPath)
    $w = ([int]$bytes[16] -shl 24) -bor ([int]$bytes[17] -shl 16) -bor ([int]$bytes[18] -shl 8) -bor $bytes[19]
    $h = ([int]$bytes[20] -shl 24) -bor ([int]$bytes[21] -shl 16) -bor ([int]$bytes[22] -shl 8) -bor $bytes[23]
    if ($w -ne $job.Size -or $h -ne $job.Size) { Fail "$($job.Name) is ${w}x${h}, expected $($job.Size)" }
    Write-Host "$($job.Name).png ${w}x${h}"
}
