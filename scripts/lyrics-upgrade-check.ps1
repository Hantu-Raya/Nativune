# Bundle-version reinstall check on the actual bench app (build with -p:PerfBenchHooks=true -o .cache/build/lyrics-e2e/).
# Disposable root under .cache/lyrics-upgrade/<stamp>; four launches: fresh install, an older record, a pending record
# and the current record. Expect: installed; reinstall+installed; reinstall+installed; installed only. Writes result.json.
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

function Launch([string] $label) {
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
    $lines = @(Get-Content $appLog | Where-Object { $_ -match '\[lyrics\]' })
    $ext = @(Get-Content (Join-Path $base "$label.bench.jsonl") | Where-Object { $_ -match '"lyrics-extensions"' } | Select-Object -Last 1)
    [ordered]@{ step = $label; marker = $(if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { $null }); lyricsLog = $lines; extensions = $ext }
}

$results = @()
$results += Launch 'fresh'
Set-Content -LiteralPath $marker -Value '2.4.1.1' -NoNewline
$results += Launch 'older-record'
Set-Content -LiteralPath $marker -Value 'pending 2.4.1.2' -NoNewline
$results += Launch 'pending-record'
$results += Launch 'current-record'
$results | ConvertTo-Json -Depth 5 | Tee-Object (Join-Path $base 'result.json')
