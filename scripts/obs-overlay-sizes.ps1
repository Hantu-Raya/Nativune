<# Independent plan v5 §§3.2–3.5 oracle. Regenerate with:
   pwsh -NoProfile -File scripts/obs-overlay-sizes.ps1
   Dot-source to use Get-OverlayExpectedSize without rewriting the fixture. #>
[CmdletBinding()]
param([string] $OutputPath = (Join-Path $PSScriptRoot 'fixtures/obs-overlay/expected-sizes.json'))
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
function Get-OverlayExpectedSize($Options) {
    $theme = [string] $Options.theme; $k = [double] $Options.scale / 100; $w = [double] $Options.width
    $art = [bool] $Options.showArt; $artist = [bool] $Options.showArtist
    $progress = [bool] $Options.showProgress; $times = [bool] $Options.showTimes
    $tail = if (-not $progress) { 56 * $k } elseif ($times) { 96 * $k } else { 72 * $k }
    if (-not $artist) { $tail -= 20 * $k }
    $h = switch ($theme) {
        'pill' { 56 * $k }
        'album-art' { $w }
        'card' { $(if ($art) { $w - 32 * $k } else { 0 }) + 16 * $k + $tail }
        default { 80 * $k }
    }
    $left = 0.0; $right = $w
    switch ($theme) {
        'pill' { $left = 28 * $k; $right = $w - 28 * $k }
        'classic' { $left = $(if ($art) { 102 * $k } else { 12 * $k }); $right = $w - 12 * $k }
        'simple' { $left = $(if ($art) { 88 * $k } else { 12 * $k }) }
        'album-art' { $left = 12 * $k; $right = $w - 12 * $k }
        'card' { $left = 16 * $k; $right = $w - 16 * $k }
        default { $left = $(if ($art) { 84 * $k } else { 12 * $k }); $right = $w - 12 * $k }
    }
    $horizontal = $theme -in @('matte', 'matte-light', 'standard', 'classic', 'simple')
    $barLeft = if ($theme -eq 'pill') { 0.0 } elseif ($horizontal -and $times) { $left + 50 * $k } else { $left }
    $barRight = if ($theme -eq 'pill') { $w } elseif ($horizontal -and $times) { $right - 50 * $k } else { $right }
    if ($horizontal) {
        # Left reservation includes the cover/margins; right reservation includes the panel padding.
        $sum = $left + $(if ($times) { 44 * $k + 6 * $k } else { 0 }) + ($barRight - $barLeft) +
            $(if ($times) { 6 * $k + 44 * $k } else { 0 }) + ($w - $right)
        if ([Math]::Abs($sum - $w) -gt 0.000001 -or $barRight -lt $barLeft) { throw "Row width invariant failed: $theme/$w/$k" }
    }
    $barY = switch ($theme) { 'pill' { 0 } 'simple' { 62 * $k } 'album-art' { $h - 10 * $k }
        'card' { $h - $(if ($times) { 28 * $k } else { 4 * $k }) } default { 61 * $k } }
    $barH = switch ($theme) { 'pill' { $h } { $_ -in @('simple', 'album-art') } { 3 * $k } default { 4 * $k } }
    $textTop = switch ($theme) { 'pill' { 6 * $k } 'simple' { 6 * $k }
        'album-art' { $h - (18 + 24 + $(if ($artist) { 18 } else { 0 })) * $k }
        'card' { $(if ($art) { $w - 32 * $k } else { 0 }) + $(if ($progress) { 28 * $k } else { 21 * $k }) }
        default { 10 * $k } }
    $textBottom = switch ($theme) { 'pill' { 51 * $k } 'simple' { 50 * $k }
        'album-art' { $h - 18 * $k } 'card' { $textTop + (26 + $(if ($artist) { 20 } else { 0 })) * $k }
        default { 52 * $k } }
    $radius = switch ($theme) { 'pill' { 28 * $k } 'album-art' { 12 * $k } 'card' { 16 * $k } 'simple' { 0 } default { 14 * $k } }
    $box = [ordered]@{ x = 20; y = 20; w = $w; h = $h; r = $radius }
    $cover = if ($art -and $theme -ne 'pill') {
        switch ($theme) {
            'classic' { [ordered]@{ x = 20; y = 20; w = 80 * $k; h = 80 * $k; r = 10 * $k } }
            'simple' { [ordered]@{ x = 20; y = 20 + 4 * $k; w = 72 * $k; h = 72 * $k; r = 10 * $k } }
            'album-art' { [ordered]@{ x = 20; y = 20; w = $w; h = $w; r = 12 * $k } }
            'card' { [ordered]@{ x = 20 + 16 * $k; y = 20 + 16 * $k; w = $w - 32 * $k; h = $w - 32 * $k; r = 8 * $k } }
            default { [ordered]@{ x = 20 + 8 * $k; y = 20 + 8 * $k; w = 64 * $k; h = 64 * $k; r = 8 * $k } }
        }
    } else { $null }
    $panel = if ($theme -eq 'simple') { $null } elseif ($theme -eq 'classic') {
        $offset = if ($art) { 90 * $k } else { 0 }
        [ordered]@{ x = 20 + $offset; y = 20; w = $w - $offset; h = $h; r = 14 * $k }
    } else { $box }
    $custom = if ($Options -is [Collections.IDictionary]) { $Options['colours'] -eq 'custom' } else {
        $property = $Options.PSObject.Properties['colours']; $property -and $property.Value -eq 'custom'
    }
    $cssW = if ($theme -eq 'classic' -and $art) { $w - 90 * $k } else { $w }
    $blurred = $theme -eq 'pill' -or ($theme -in @('standard', 'classic', 'card') -and -not $custom)
    $rasterScale = if ($theme -eq 'pill' -or -not $blurred) { 1.0 } else { [Math]::Min(1.0, [Math]::Sqrt(100000 / ($cssW * $h))) }
    $rw = if (-not $blurred) { 1 } elseif ($theme -eq 'pill') { [Math]::Ceiling($w) } else { [Math]::Max(1, [Math]::Floor($cssW * $rasterScale)) }
    $rh = if (-not $blurred) { 1 } elseif ($theme -eq 'pill') { [Math]::Ceiling($h) } else { [Math]::Max(1, [Math]::Floor($h * $rasterScale)) }
    if ($rw * $rh -gt 100000) { throw "Raster area exceeds cap: $theme/$w/$k" }
    [ordered]@{
        theme = $theme; scale = $Options.scale; width = $Options.width
        showArt = $art; showArtist = $artist; showProgress = $progress; showTimes = $times
        box = $box; cover = $cover; panel = $panel
        source = [ordered]@{ w = 2 * [Math]::Ceiling(($w + 40) / 2); h = 2 * [Math]::Ceiling(($h + 40) / 2) }
        column = [ordered]@{ start = $left; end = $right }
        bar = [ordered]@{ start = $barLeft; end = $barRight; width = $barRight - $barLeft; y = $barY; h = $barH; shown = $progress }
        sourceBar = [ordered]@{ start = 20 + $barLeft; end = 20 + $barRight; y = 20 + $barY; h = $barH; width = $barRight - $barLeft }
        textBand = [ordered]@{ start = 20 + $textTop; end = 20 + $textBottom }
        raster = [ordered]@{ colour = [ordered]@{ w = $rw; h = $rh }
            grey = [ordered]@{ w = $(if ($theme -eq 'pill') { $rw } else { 1 }); h = $(if ($theme -eq 'pill') { $rh } else { 1 }) }
            css = [ordered]@{ w = $cssW; h = $h }; scale = $rasterScale }
    }
}
if ($MyInvocation.InvocationName -ne '.') {
    $rows = [Collections.Generic.List[object]]::new()
    foreach ($theme in @('pill', 'matte', 'matte-light', 'standard', 'classic', 'simple', 'album-art', 'card')) {
        $min = switch ($theme) { 'pill' { 320 } 'album-art' { 160 } 'card' { 200 } default { 360 } }
        $max = switch ($theme) { 'pill' { 800 } { $_ -in @('album-art', 'card') } { 600 } default { 1200 } }
        $default = switch ($theme) { 'pill' { 400 } 'album-art' { 200 } 'card' { 280 } default { 440 } }
        foreach ($scale in @(50, 100, 200)) {
            $effectiveMin = [Math]::Ceiling($min * [Math]::Max(1, $scale / 100.0) / 10) * 10
            $effectiveDefault = [Math]::Min($max, [Math]::Max($effectiveMin, $default))
            foreach ($width in @($effectiveMin, $effectiveDefault, $max) | Select-Object -Unique) {
                foreach ($bits in 0..15) {
                    $o = @{ theme = $theme; scale = $scale; width = $width; showArt = [bool]($bits -band 1)
                        showArtist = [bool]($bits -band 2); showProgress = [bool]($bits -band 4); showTimes = [bool]($bits -band 8) }
                    $row = Get-OverlayExpectedSize $o
                    $row['default'] = $scale -eq 100 -and $width -eq $default -and $bits -eq 15
                    $rows.Add($row)
                }
            }
        }
    }
    $casesPath = Join-Path $PSScriptRoot 'fixtures/obs-overlay/looks-cases.json'
    $cases = [ordered]@{}
    foreach ($case in (Get-Content -Raw -LiteralPath $casesPath | ConvertFrom-Json)) {
        $cases[$case.lookId] = Get-OverlayExpectedSize $case.options
    }
    $json = [ordered]@{ version = 1; rows = $rows.ToArray(); cases = $cases } | ConvertTo-Json -Depth 10
    [IO.File]::WriteAllText($OutputPath, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Output "$($rows.Count) configurations, $($cases.Count) look cases; all horizontal row sums passed. $OutputPath"
}
