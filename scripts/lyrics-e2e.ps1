<#
Barebones Better Lyrics end-to-end acceptance. Protocol and frozen thresholds: scripts/lyrics-e2e-protocol.md.
Needs the bench build: dotnet build src/Nativune -c Release -p:PerfBenchHooks=true -o .cache/build/lyrics-e2e
and the published extension tree under .tools/better-lyrics (scripts/setup-better-lyrics.ps1).
Every arm runs on a disposable root under .cache/lyrics-e2e/runs/<stamp>/<arm>; lyrics are switched on or off only
through that root's data/settings.json. Only processes started here are stopped. Raw network logs are reduced to host
names by scripts/lyrics-e2e-analyze.py and then deleted with the roots (unless -KeepRaw).
#>
param(
    [ValidateSet('All', 'Core', 'HostAllowlist', 'Idle', 'TranslateOn', 'TranslateOff', 'SettingsPersist', 'Off',
        'NonEnglish', 'NoLyrics', 'Coverage', 'StyleIsolation', 'Smoke')]
    [string[]] $Scenario = @('All'),
    [string] $OutputDirectory = 'artifacts/lyrics-e2e',
    [string] $Exe = '.cache/build/lyrics-e2e/Nativune.exe',
    # A frozen public instrumental recording expected to have no synced lyrics.
    [string] $NoLyricsTrack = '4Tr0otuiQuU',
    [switch] $KeepRaw
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$exePath = [IO.Path]::GetFullPath((Join-Path $root $Exe))
$lyricsTools = Join-Path $root '.tools\better-lyrics'
$template = Join-Path $root '.cache\perf\template\webview2'
$templateSettings = Join-Path $root '.cache\perf\template\settings.json'
$ubol = Join-Path $root '.tools\ubol'
foreach ($required in @($exePath, $lyricsTools, $template, $templateSettings, $ubol)) {
    if (-not (Test-Path -LiteralPath $required)) { throw "Missing prerequisite: $required" }
}
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) { throw 'python is required for scripts/lyrics-e2e-analyze.py' }

$all = @('Smoke', 'Core', 'HostAllowlist', 'Idle', 'TranslateOn', 'TranslateOff', 'SettingsPersist', 'Off', 'NonEnglish', 'NoLyrics', 'Coverage', 'StyleIsolation')
$selected = if ($Scenario -contains 'All') { $all | Where-Object { $_ -ne 'Smoke' } } else { $Scenario }
$needs = @{}
foreach ($s in $selected) {
    switch ($s) {
        'Smoke' { $needs.Smoke = $true; $needs.Control = $true }
        'Core' { $needs.Core = $true; $needs.Control = $true }
        'HostAllowlist' { $needs.Core = $true; $needs.Control = $true; $needs.Idle = $true; $needs.Translate = $true }
        'Idle' { $needs.Idle = $true; $needs.Control = $true }
        'TranslateOn' { $needs.Translate = $true; $needs.Control = $true }
        'TranslateOff' { $needs.Translate = $true; $needs.Control = $true }
        'SettingsPersist' { $needs.Settings = $true }
        'Off' { $needs.Off = $true }
        'NonEnglish' { $needs.NonEnglish = $true }
        'NoLyrics' { if ($NoLyricsTrack) { $needs.NoLyrics = $true } }
        'Coverage' { $needs.Coverage = $true }
        'StyleIsolation' { $needs.StyleIsolation = $true }
    }
}

$stamp = [DateTime]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$out = Join-Path ([IO.Path]::GetFullPath((Join-Path $root $OutputDirectory))) $stamp
$runsBase = Join-Path $root ".cache\lyrics-e2e\runs\$stamp"
New-Item -ItemType Directory -Force -Path $out, $runsBase | Out-Null
$seed = 'dQw4w9WgXcQ'
$uri = "https://music.youtube.com/watch?v=$seed&list=RDAMVM$seed"
$nonce = "e2e-$stamp"
$main = 'lyrics@8;pause@70;play@76;seekfwd@95;seekback@115;next@135'
$coverageTracks = @('dQw4w9WgXcQ', 'JGwWNGJdvx8', 'kJQP7kiw5Fk', '9bZkp7q19f0', 'fJ9rUzIMcZQ', 'YQHsXMglC9A', 'gdZLi9oWNZg',
    'IHNzOHi8sJs', 'hT_nvWreIhg', '60ItHLz5WEA', 'RgKAFK5djSk', 'OPf0YbXqDm0', 'CevxZvSJLk8', 'pRpeEdMmmQ0', 'lp-EO5I60KA',
    'DyDfgMOUjCI', 'ZRtdQ81jPUQ', 'oiKj0Z_Xnjc', 'W3q8Od5qJio', 'hcm55lU9knw')
$coverageSchedule = (@('lyrics@8') + @(for ($i = 0; $i -lt $coverageTracks.Count; $i++) { "nav:$($coverageTracks[$i])@$(10 + 30 * $i)" }) +
    @("quit@$(10 + 30 * $coverageTracks.Count + 5)")) -join ';'

# A step is one app launch; a chain is steps that share one root and run in order. Chains run in parallel (max 3).
function Step([string] $Arm, [string] $Schedule, [bool] $Lyrics, [bool] $BlockAds, [int] $Timeout, [string] $Nonce = '', [string] $StartUri = '', [string] $Lang = '') {
    [pscustomobject]@{ Arm = $Arm; Schedule = $Schedule; Lyrics = $Lyrics; BlockAds = $BlockAds; Timeout = $Timeout; Nonce = $Nonce; Lang = $Lang
        StartUri = if ($StartUri) { $StartUri } else { $uri } }
}
$chains = [Collections.Generic.List[object]]::new()
if ($needs.ContainsKey('Core')) {
    $chains.Add([pscustomobject]@{ Root = 'R'; Steps = @(
        (Step 'R1' "$main;options@175;quit@215" $true $false 420 $nonce),
        (Step 'R2' 'lyrics@8;options@60;quit@80' $true $true 300)) })
}
if ($needs.ContainsKey('Control')) {
    # Control arm: lyrics off, same start URI; host judgments subtract its hosts. With Smoke alone it mirrors Smoke's schedule.
    $controlSchedule = if (@('Core', 'Idle', 'Translate') | Where-Object { $needs.ContainsKey($_) }) { "$main;quit@215" } else { 'lyrics@8;quit@60' }
    $chains.Add([pscustomobject]@{ Root = 'C'; Steps = @((Step 'C' $controlSchedule $false $false 420)) })
}
if ($needs.ContainsKey('Idle')) {
    $chains.Add([pscustomobject]@{ Root = 'I'; Steps = @((Step 'I' 'lyrics@8;options@600;quit@620' $true $false 800)) })
}
if ($needs.ContainsKey('Translate')) {
    $chains.Add([pscustomobject]@{ Root = 'T'; Steps = @(
        (Step 'T1' 'lyrics@8;options@20;translate-on@25;capture:translate-on@45;translate-off@110;quit@120' $true $false 300),
        (Step 'T2' 'lyrics@8;options@60;quit@90' $true $false 240)) })
}
if ($needs.ContainsKey('Settings')) {
    $chains.Add([pscustomobject]@{ Root = 'S'; Steps = @(
        (Step 'S1' 'lyrics@8;options@20;offset-set@70;translate-off@75;quit@125' $true $false 240),
        (Step 'S2' 'lyrics@8;options@30;quit@45' $true $false 180)) })
}
if ($needs.ContainsKey('Off')) {
    $chains.Add([pscustomobject]@{ Root = 'O'; Steps = @((Step 'O1' 'lyrics@8;quit@60' $false $false 180)) })
    $chains.Add([pscustomobject]@{ Root = 'P'; Steps = @(
        (Step 'P1' 'lyrics@8;quit@40' $true $false 180),
        (Step 'P2' 'lyrics@8;quit@40' $false $false 180),
        (Step 'P3' 'lyrics@8;quit@40' $false $false 180)) })
}
if ($needs.ContainsKey('NonEnglish')) {
    # YouTube Music ignores hl= (run 20260927T221658Z: <html lang> stayed en); it follows the browser language, so G also runs with --lang=de.
    $chains.Add([pscustomobject]@{ Root = 'G'; Steps = @((Step 'G' 'lyrics@8;next@60;quit@110' $true $false 300 '' "$uri&hl=de" 'de')) })
}
if ($needs.ContainsKey('NoLyrics')) {
    $chains.Add([pscustomobject]@{ Root = 'N'; Steps = @((Step 'N' "lyrics@8;nav:$NoLyricsTrack@10;quit@80" $true $false 240)) })
}
if ($needs.ContainsKey('Coverage')) {
    $chains.Add([pscustomobject]@{ Root = 'V'; Steps = @((Step 'V' $coverageSchedule $true $false (10 + 30 * $coverageTracks.Count + 200))) })
}
if ($needs.ContainsKey('Smoke')) {
    $chains.Add([pscustomobject]@{ Root = 'M'; Steps = @((Step 'M' 'lyrics@8;quit@60' $true $false 180)) })
}
if ($needs.ContainsKey('StyleIsolation')) {
    # S (lyrics on), C2 and C3 (lyrics off) start first and together (3 slots). C3 only detects volatile html/body attributes.
    # Capture names carry the arm's state because every arm writes its PNGs into the report directory.
    $styleSchedule = { param([string] $State) "lyrics@8;style-probe:player@25;capture:style-lyrics-$State-player@26;next@30;style-probe:player2@55;home@58;style-probe:home@64;capture:style-lyrics-$State-home@65;quit@70" }
    $chains.Insert(0, [pscustomobject]@{ Root = 'SC3'; Steps = @((Step 'C3' (& $styleSchedule 'off3') $false $false 240)) })
    $chains.Insert(0, [pscustomobject]@{ Root = 'SC2'; Steps = @((Step 'C2' (& $styleSchedule 'off') $false $false 240)) })
    $chains.Insert(0, [pscustomobject]@{ Root = 'SS'; Steps = @((Step 'S' (& $styleSchedule 'on') $true $false 240)) })
}

function Copy-Tree([string] $From, [string] $To, [string[]] $Exclude = @()) {
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    $arguments = @($From, $To, '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP')
    if ($Exclude.Count -gt 0) { $arguments += '/XF'; $arguments += $Exclude }
    & robocopy @arguments | Out-Null
    if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE): $From" }
    $global:LASTEXITCODE = 0
}
function New-Root([string] $Name) {
    $runRoot = Join-Path $runsBase $Name
    Copy-Tree $template (Join-Path $runRoot 'data\webview2') @('*.lock', '*.lck', 'LOCK', 'LOCKFILE', 'lockfile', 'Singleton*', '*.dmp')
    Copy-Tree $ubol (Join-Path $runRoot '.tools\ubol')
    Copy-Tree $lyricsTools (Join-Path $runRoot '.tools\better-lyrics')
    $runRoot
}
function Set-ArmSettings([string] $RunRoot, $Step, [int] $X) {
    $path = Join-Path $RunRoot 'data\settings.json'
    $source = if (Test-Path -LiteralPath $path) { $path } else { $templateSettings }
    $s = Get-Content -LiteralPath $source -Raw | ConvertFrom-Json
    $values = [ordered]@{ BetterLyricsEnabled = $Step.Lyrics; BlockAds = $Step.BlockAds; AutoCheckUpdates = $false
        SleepInBackground = $false; X = $X; Y = 60 }
    foreach ($key in $values.Keys) { $s | Add-Member -NotePropertyName $key -NotePropertyValue $values[$key] -Force }
    [IO.File]::WriteAllText($path, ($s | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
}
function Start-Step([string] $RunRoot, $Step) {
    $psi = [Diagnostics.ProcessStartInfo]::new($exePath)
    $psi.WorkingDirectory = $root
    $psi.UseShellExecute = $false
    foreach ($a in @('web', '--root', $RunRoot)) { $psi.ArgumentList.Add($a) }
    $psi.Environment['NATIVUNE_BENCH_LOG'] = Join-Path $out "$($Step.Arm).bench.jsonl"
    $psi.Environment['NATIVUNE_BENCH_START_URI'] = $Step.StartUri
    $psi.Environment['NATIVUNE_BENCH_AUTOPLAY'] = '1'
    $psi.Environment['NATIVUNE_BENCH_MUTE'] = '1'
    $psi.Environment['NATIVUNE_BENCH_SCHEDULE'] = $Step.Schedule
    $psi.Environment['NATIVUNE_BENCH_EXTRA_ARGS'] = "--log-net-log=$(Join-Path $runsBase "$($Step.Arm).netlog.json") --net-log-capture-mode=Default" + $(if ($Step.Lang) { " --lang=$($Step.Lang)" } else { '' })
    if ($Step.Nonce) { $psi.Environment['NATIVUNE_BENCH_LYRICS_NONCE'] = $Step.Nonce }
    [Diagnostics.Process]::Start($psi)
}
function Save-AppLog([string] $RunRoot, [string] $Arm) {
    $appLog = Join-Path $RunRoot 'data\nativune.log'
    if (Test-Path -LiteralPath $appLog) {
        # Keep only the lyrics category; it carries versions, ids and states, never track data.
        Get-Content -LiteralPath $appLog | Where-Object { $_ -match '\blyrics\b' } |
            Set-Content -LiteralPath (Join-Path $out "$Arm.lyrics.log") -Encoding utf8
    }
}

$fingerprint = Get-ChildItem -LiteralPath $lyricsTools -Filter 'fingerprint.json' -Recurse -File -ErrorAction SilentlyContinue | Select-Object -First 1
$config = [ordered]@{
    stamp = $stamp; scenarios = @($selected); uri = $uri; nonce = $nonce; coverageTracks = $coverageTracks
    noLyricsTrack = $NoLyricsTrack; expectedExtensionId = 'ogodmldcmpbfeekmejkeppchklblochl'
    fingerprint = if ($fingerprint) { Get-Content -LiteralPath $fingerprint.FullName -Raw | ConvertFrom-Json } else { $null }
    arms = @($chains | ForEach-Object { $_.Steps } | ForEach-Object { [ordered]@{ arm = $_.Arm; schedule = $_.Schedule; lyrics = $_.Lyrics; blockAds = $_.BlockAds; startUri = $_.StartUri } })
    command = "pwsh -NoProfile -File scripts/lyrics-e2e.ps1 -Scenario $($Scenario -join ',') -OutputDirectory $OutputDirectory"
}
$config | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path $out 'config.json') -Encoding utf8

# Chain scheduler: at most 3 app instances at once; window slots keep them apart on screen.
$pending = [Collections.Generic.Queue[object]]::new()
foreach ($c in $chains) { $pending.Enqueue([pscustomobject]@{ Chain = $c; Index = 0; Root = $null; Proc = $null; Deadline = $null; Slot = -1 }) }
$running = [Collections.Generic.List[object]]::new()
$slots = @($false, $false, $false)
while ($pending.Count -gt 0 -or $running.Count -gt 0) {
    while ($running.Count -lt 3 -and $pending.Count -gt 0) {
        $job = $pending.Dequeue()
        $job.Slot = [Array]::IndexOf($slots, $false); $slots[$job.Slot] = $true
        $job.Root = New-Root $job.Chain.Root
        $running.Add($job)
        $job.Proc = $null
    }
    foreach ($job in @($running)) {
        if ($null -eq $job.Proc) {
            $step = $job.Chain.Steps[$job.Index]
            Set-ArmSettings $job.Root $step (100 + 960 * $job.Slot)
            $job.Proc = Start-Step $job.Root $step
            $job.Deadline = [DateTime]::UtcNow.AddSeconds($step.Timeout)
            Write-Host "Started $($step.Arm) (PID $($job.Proc.Id))"
            Start-Sleep -Seconds 2
            continue
        }
        if (-not $job.Proc.HasExited -and [DateTime]::UtcNow -lt $job.Deadline) { continue }
        $step = $job.Chain.Steps[$job.Index]
        if (-not $job.Proc.HasExited) {
            Write-Warning "$($step.Arm) (PID $($job.Proc.Id)) did not quit; stopping its tree."
            & taskkill /PID $job.Proc.Id /T /F | Out-Null
            $global:LASTEXITCODE = 0
            Add-Content -LiteralPath (Join-Path $out "$($step.Arm).bench.jsonl") -Value '{"t":0,"event":"harness-killed"}' -Encoding utf8
        }
        Start-Sleep -Seconds 5
        Save-AppLog $job.Root $step.Arm
        $job.Index++
        $job.Proc = $null
        if ($job.Index -ge $job.Chain.Steps.Count) { $running.Remove($job) | Out-Null; $slots[$job.Slot] = $false }
    }
    Start-Sleep -Seconds 2
}

& $python.Source (Join-Path $PSScriptRoot 'lyrics-e2e-analyze.py') $out $runsBase
$analyzerExit = $LASTEXITCODE
if (-not $KeepRaw) {
    Remove-Item -LiteralPath $runsBase -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $runsBase) { Write-Warning "Could not delete raw roots: $runsBase" }
}
$reportPath = Join-Path $out 'report.json'
if ($analyzerExit -ne 0 -or -not (Test-Path -LiteralPath $reportPath)) {
    Write-Error "Analyzer failed (exit $analyzerExit); output: $out"
    exit 2
}
$report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
$bad = @($report.scenarios.PSObject.Properties | Where-Object { $_.Value.status -ne 'pass' })
foreach ($p in $report.scenarios.PSObject.Properties) { Write-Host ('{0,-16} {1}' -f $p.Name, $p.Value.status) }
Write-Host "Report: $reportPath"
if ($bad.Count -gt 0) { exit 1 }
exit 0
