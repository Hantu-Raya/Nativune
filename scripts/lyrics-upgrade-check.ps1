# Bundle-version reinstall check on the actual bench app (build with -p:PerfBenchHooks=true -o .cache/build/lyrics-e2e/).
# Disposable root under .cache/lyrics-upgrade/<stamp>; four launches: fresh install, an older record, a pending record
# and the current record. Expect: installed; reinstall+installed; reinstall+installed; installed only, with the current
# version recorded and the extension enabled. Checks only the log lines each launch added; writes result.json; exits 1 on mismatch.
# pwsh -NoProfile -File scripts/lyrics-upgrade-check.ps1
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$exe = Join-Path $root '.cache\build\lyrics-e2e\Nativune.exe'
$base = Join-Path $root ".cache\lyrics-upgrade\$(Get-Date -Format yyyyMMddTHHmmss)"
$run = Join-Path $base 'root'
New-Item -ItemType Directory -Force (Join-Path $run 'data'), (Join-Path $run '.tools') | Out-Null
Copy-Item -Recurse (Join-Path $root '.cache\perf\template\webview2') (Join-Path $run 'data\webview2')
Get-ChildItem (Join-Path $run 'data\webview2') -Recurse -Force -Include '*.lock','LOCK','lockfile','Singleton*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
Copy-Item -Recurse (Join-Path $root '.tools\ubol') (Join-Path $run '.tools\ubol')
Copy-Item -Recurse (Join-Path $root '.tools\better-lyrics') (Join-Path $run '.tools\better-lyrics')
$s = Get-Content (Join-Path $root '.cache\perf\template\settings.json') -Raw | ConvertFrom-Json
foreach ($kv in @{ BetterLyricsEnabled = $true; AutoCheckUpdates = $false; SleepInBackground = $false }.GetEnumerator()) { $s | Add-Member -NotePropertyName $kv.Key -NotePropertyValue $kv.Value -Force }
[IO.File]::WriteAllText((Join-Path $run 'data\settings.json'), ($s | ConvertTo-Json -Depth 8), [Text.UTF8Encoding]::new($false))
$marker = Join-Path $run 'data\webview2\better-lyrics-extension.version'
$appLog = Join-Path $run 'data\nativune.log'

$version = [string] ((Get-Content (Join-Path $root 'release-inputs.json') -Raw | ConvertFrom-Json).betterLyrics.version)

function Launch([string] $label) {
    # The app log appends across launches of the same root; keep only the lines this launch added.
    $before = if (Test-Path $appLog) { @(Get-Content $appLog).Count } else { 0 }
    $psi = [Diagnostics.ProcessStartInfo]::new($exe)
    $psi.UseShellExecute = $false
    foreach ($a in @('web', '--root', $run)) { $psi.ArgumentList.Add($a) }
    $psi.Environment['NATIVUNE_BENCH_LOG'] = Join-Path $base "$label.bench.jsonl"
    $psi.Environment['NATIVUNE_BENCH_START_URI'] = 'https://music.youtube.com/watch?v=dQw4w9WgXcQ&list=RDAMVMdQw4w9WgXcQ'
    $psi.Environment['NATIVUNE_BENCH_AUTOPLAY'] = '1'
    $psi.Environment['NATIVUNE_BENCH_SCHEDULE'] = 'lyrics@4;quit@8'
    $p = [Diagnostics.Process]::Start($psi)
    if (-not $p.WaitForExit(90000)) { $p.Kill($true); throw "$label timed out" }
    Start-Sleep -Seconds 3
    $added = @(Get-Content $appLog | Select-Object -Skip $before)
    $events = @($added | Where-Object { $_ -match '\[lyrics\] (.+)$' } | ForEach-Object { ($_ -replace '^.*\[lyrics\] ', '').Trim() })
    $ext = @(Get-Content (Join-Path $base "$label.bench.jsonl") | Where-Object { $_ -match '"lyrics-extensions"' } | Select-Object -Last 1)
    $enabled = $null
    if ($ext.Count) {
        $item = @(($ext[0] | ConvertFrom-Json).items | Where-Object { $_.id -eq 'ogodmldcmpbfeekmejkeppchklblochl' })
        $enabled = if ($item.Count) { [bool] $item[0].enabled } else { $false }
    }
    [ordered]@{ step = $label; exitCode = $p.ExitCode; marker = $(if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { $null }); events = $events; extensionEnabled = $enabled }
}

function Check($result, [string[]] $expectedEvents) {
    $problems = @()
    if ($result.exitCode -ne 0) { $problems += "exit code $($result.exitCode)" }
    if (($result.events -join '|') -cne ($expectedEvents -join '|')) { $problems += "events [$($result.events -join ', ')] expected [$($expectedEvents -join ', ')]" }
    if ($result.marker -cne $version) { $problems += "record '$($result.marker)' expected '$version'" }
    if ($result.extensionEnabled -ne $true) { $problems += "extension enabled = $($result.extensionEnabled)" }
    $result['expectedEvents'] = $expectedEvents
    $result['pass'] = $problems.Count -eq 0
    $result['problems'] = $problems
    $result
}

$installed = "installed $version"
$reinstall = "reinstall $version"
$results = @()
$results += Check (Launch 'fresh') @($installed)
Set-Content -LiteralPath $marker -Value '2.4.1.1' -NoNewline
$results += Check (Launch 'older-record') @($reinstall, $installed)
Set-Content -LiteralPath $marker -Value "pending $version" -NoNewline
$results += Check (Launch 'pending-record') @($reinstall, $installed)
$results += Check (Launch 'current-record') @($installed)
$report = [ordered]@{ version = $version; pass = -not ($results | Where-Object { -not $_.pass }); steps = $results
    command = 'pwsh -NoProfile -File scripts/lyrics-upgrade-check.ps1' }
$report | ConvertTo-Json -Depth 6 | Tee-Object (Join-Path $base 'result.json')
if (-not $report.pass) { Write-Error 'Upgrade check failed.'; exit 1 }
exit 0
