<#
In-app quick-update E2E (owner-approved 26 September 2026 for %LOCALAPPDATA%\Nativune-fixture only).

Prepare lays out an "installed" 0.9.1 at %LOCALAPPDATA%\Nativune-fixture: release A's payload with the
UpdaterTestHooks app and an INSTALLER_TEST_HOOKS Setup as installer\Nativune.Setup.exe. It also builds
release assets for 0.9.2 from release B's payload with the same hook Setup, so the installed Setup matches
and the app offers a quick update. The app passes --test-no-shell to that Setup (NATIVUNE_TEST_SETUP_NO_SHELL),
so the real Start menu/desktop shortcuts and uninstall entry, which share names with the owner's install,
are never written. %LOCALAPPDATA%\Nativune is never touched.

  pwsh -NoProfile -File scripts/delta-update-fixture.ps1                 # builds artifacts/delta-fixture-a and -b
  pwsh -NoProfile -File scripts/delta-update-app-e2e.ps1 -Action Prepare
  python scripts/updater-test-server.py --port 8765 --scenario available --tag v0.9.2 `
      --setup-file .cache/delta-app-e2e/served/Nativune-Setup.exe --delta-dir .cache/delta-app-e2e/served
  pwsh -NoProfile -File scripts/delta-update-app-e2e.ps1 -Action Start -MetadataUrl http://127.0.0.1:8765/repos/Hantu-Raya/Nativune/releases/latest
  (click the update button, then Update now)
  pwsh -NoProfile -File scripts/delta-update-app-e2e.ps1 -Action Verify   # writes artifacts/delta-update/app-e2e-report.json
  pwsh -NoProfile -File scripts/delta-update-app-e2e.ps1 -Action Remove
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Prepare', 'Start', 'Verify', 'Remove')] [string] $Action,
    [string] $ReleaseADirectory = 'artifacts/delta-fixture-a',
    [string] $ReleaseBDirectory = 'artifacts/delta-fixture-b',
    [string] $FromVersion = '0.9.1',
    [string] $ToVersion = '0.9.2',
    [string] $MetadataUrl
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if ([string]::IsNullOrWhiteSpace($localAppData)) { throw 'LocalApplicationData is unavailable.' }
$fixtureRoot = Join-Path $localAppData 'Nativune-fixture'
$work = Join-Path $repo '.cache\delta-app-e2e'
$served = Join-Path $work 'served'
$hookAppRoot = Join-Path $repo 'artifacts\winui3\publish-updater-hooks'
$hookStubRoot = Join-Path $work 'hook-stub'
$reportPath = Join-Path $repo 'artifacts\delta-update\app-e2e-report.json'

function Sha([string] $Path) { (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant() }

function Get-FixtureProcesses {
    Get-CimInstance Win32_Process -Filter "Name='Nativune.exe' or Name='Nativune-Setup.exe' or Name='Nativune.Setup.exe'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase) }
}

function Expand-Payload([string] $Zip, [string] $Destination) {
    $archive = [IO.Compression.ZipFile]::OpenRead($Zip)
    try {
        foreach ($entry in $archive.Entries) {
            if ($entry.FullName -eq 'release-manifest.json' -or $entry.FullName.EndsWith('/')) { continue }
            $target = [IO.Path]::GetFullPath((Join-Path $Destination $entry.FullName))
            if (-not $target.StartsWith($Destination + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe payload path: $($entry.FullName)" }
            New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        }
    } finally { $archive.Dispose() }
}

# Same manifest shape as build-release.ps1 (compressed JSON, UTF-8 without BOM, ordinal path order).
function Write-Manifest([string] $Root, [string] $Version, [string[]] $Exclude) {
    $items = Get-ChildItem -LiteralPath $Root -Recurse -File -Force | ForEach-Object {
        [pscustomobject]@{ Relative = $_.FullName.Substring($Root.Length + 1).Replace('\', '/'); Item = $_ }
    } | Where-Object { $_.Relative -ne 'release-manifest.json' -and $Exclude -notcontains $_.Relative.Split('/')[0] }
    $sorted = [Collections.Generic.List[object]]::new(@($items))
    $sorted.Sort([Comparison[object]] { param($a, $b) [string]::CompareOrdinal($a.Relative, $b.Relative) })
    $files = foreach ($entry in $sorted) {
        [ordered]@{ path = $entry.Relative; length = [int64]$entry.Item.Length; sha256 = Sha $entry.Item.FullName }
    }
    $json = [ordered]@{ schemaVersion = 1; product = 'Nativune'; version = $Version; executable = 'app/Nativune.exe'; files = @($files) } |
        ConvertTo-Json -Depth 8 -Compress
    $path = Join-Path $Root 'release-manifest.json'
    [IO.File]::WriteAllText($path, $json, [Text.UTF8Encoding]::new($false))
    return $path
}

switch ($Action) {
    'Prepare' {
        foreach ($dir in @($ReleaseADirectory, $ReleaseBDirectory)) {
            if (-not (Test-Path -LiteralPath (Join-Path $repo "$dir\Nativune-Setup.zip"))) { throw "Missing $dir; run scripts/delta-update-fixture.ps1 first." }
        }
        if (@(Get-FixtureProcesses).Count -gt 0) { throw 'The fixture is running; stop it first.' }
        if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
        New-Item -ItemType Directory -Force -Path $work, $served | Out-Null

        & pwsh -NoProfile -File (Join-Path $repo 'scripts\dotnet.ps1') publish (Join-Path $repo 'src\Nativune\Nativune.csproj') `
            --runtime win-x64 --self-contained false -p:UpdaterTestHooks=true -o $hookAppRoot
        if ($LASTEXITCODE -ne 0) { throw 'Test-hook app publish failed.' }
        & pwsh -NoProfile -File (Join-Path $repo 'scripts\dotnet.ps1') publish (Join-Path $repo 'src\Nativune.Installer\Nativune.Installer.csproj') `
            -c Release -p:InstallerTestHooks=true -o $hookStubRoot
        if ($LASTEXITCODE -ne 0) { throw 'Test-hook Setup publish failed.' }
        $hookStub = Join-Path $hookStubRoot 'Nativune.Setup.exe'

        # Installed 0.9.1: release A payload, hook app, hook Setup.
        New-Item -ItemType Directory -Force -Path $fixtureRoot | Out-Null
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        & icacls $fixtureRoot /inheritance:r /grant:r "*${user}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /C /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not set the fixture folder permissions.' }
        foreach ($item in Get-ChildItem -LiteralPath $fixtureRoot -Force) { Remove-Item -LiteralPath $item.FullName -Recurse -Force }
        Expand-Payload (Join-Path $repo "$ReleaseADirectory\Nativune-Setup.zip") $fixtureRoot
        Remove-Item -LiteralPath (Join-Path $fixtureRoot 'app') -Recurse -Force
        New-Item -ItemType Directory -Force -Path (Join-Path $fixtureRoot 'app'), (Join-Path $fixtureRoot 'data') | Out-Null
        Copy-Item -Path (Join-Path $hookAppRoot '*') -Destination (Join-Path $fixtureRoot 'app') -Recurse -Force
        Copy-Item -LiteralPath $hookStub -Destination (Join-Path $fixtureRoot 'installer\Nativune.Setup.exe') -Force
        [void](Write-Manifest $fixtureRoot $FromVersion @('data', 'updates'))
        [IO.File]::WriteAllText((Join-Path $fixtureRoot 'data\sentinel.txt'), [Guid]::NewGuid().ToString('N'))

        # Served 0.9.2: release B payload with the same hook Setup.
        $payload = Join-Path $work 'payload-b'
        New-Item -ItemType Directory -Force -Path $payload | Out-Null
        Expand-Payload (Join-Path $repo "$ReleaseBDirectory\Nativune-Setup.zip") $payload
        Copy-Item -LiteralPath $hookStub -Destination (Join-Path $payload 'installer\Nativune.Setup.exe') -Force
        $manifest = Write-Manifest $payload $ToVersion @()
        Copy-Item -LiteralPath $manifest -Destination (Join-Path $served 'release-manifest.json')
        $zipPath = Join-Path $served 'Nativune-Setup.zip'
        $entries = Get-ChildItem -LiteralPath $payload -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($payload.Length + 1).Replace('\', '/') }
        $sortedEntries = [Collections.Generic.List[string]]::new([string[]]@($entries))
        $sortedEntries.Sort([StringComparer]::Ordinal)
        $stream = [IO.File]::Open($zipPath, [IO.FileMode]::CreateNew)
        $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $false, [Text.Encoding]::UTF8)
        try {
            foreach ($relative in $sortedEntries) {
                $entry = $zip.CreateEntry($relative, [IO.Compression.CompressionLevel]::Optimal)
                $entry.LastWriteTime = [DateTimeOffset]::new(1980, 1, 1, 0, 0, 0, [TimeSpan]::Zero)
                $in = [IO.File]::OpenRead((Join-Path $payload $relative)); $out = $entry.Open()
                try { $in.CopyTo($out) } finally { $out.Dispose(); $in.Dispose() }
            }
        } finally { $zip.Dispose(); $stream.Dispose() }
        $stubSha = Sha $hookStub
        $descriptor = [ordered]@{ schemaVersion = 1; product = 'Nativune'; version = $ToVersion; enabled = $true; applyProtocol = 1; installerSha256 = $stubSha; installerSourceSha256 = ('0' * 64) } |
            ConvertTo-Json -Compress
        [IO.File]::WriteAllText((Join-Path $served 'delta-update.json'), $descriptor, [Text.UTF8Encoding]::new($false))
        # Full Setup for the fallback path: stub + ZIP + NATIVN01 footer.
        $setup = Join-Path $served 'Nativune-Setup.exe'
        $stubBytes = [IO.File]::ReadAllBytes($hookStub); $zipBytes = [IO.File]::ReadAllBytes($zipPath)
        $footer = [byte[]]::new(32)
        [Text.Encoding]::ASCII.GetBytes('NATIVN01').CopyTo($footer, 0)
        [BitConverter]::GetBytes([uint32]1).CopyTo($footer, 8)
        [BitConverter]::GetBytes([int64]$stubBytes.Length).CopyTo($footer, 12)
        [BitConverter]::GetBytes([int64]$zipBytes.Length).CopyTo($footer, 20)
        [IO.File]::WriteAllBytes($setup, [byte[]]($stubBytes + $zipBytes + $footer))
        "Installed $FromVersion at $fixtureRoot; served $ToVersion from $served (installer $stubSha)."
    }
    'Start' {
        if (@(Get-FixtureProcesses).Count -gt 0) { throw 'The fixture is already running.' }
        if ($MetadataUrl -notmatch '^http://127\.0\.0\.1:\d+/') { throw 'MetadataUrl must be a loopback test-server URL.' }
        $env:NATIVUNE_TEST_RELEASE_METADATA_URL = $MetadataUrl
        $env:NATIVUNE_TEST_SETUP_NO_SHELL = '1'
        $process = Start-Process -FilePath (Join-Path $fixtureRoot 'app\Nativune.exe') -ArgumentList @('web', '--root', "`"$fixtureRoot`"") -PassThru
        "Started fixture pid $($process.Id)."
    }
    'Verify' {
        $expected = Get-Content -LiteralPath (Join-Path $served 'release-manifest.json') -Raw | ConvertFrom-Json
        $installed = Get-Content -LiteralPath (Join-Path $fixtureRoot 'release-manifest.json') -Raw | ConvertFrom-Json
        $mismatches = @(foreach ($file in $expected.files) {
            $path = Join-Path $fixtureRoot $file.path
            if (-not (Test-Path -LiteralPath $path -PathType Leaf) -or (Sha $path) -ne $file.sha256) { $file.path }
        })
        $outcomePath = Join-Path $fixtureRoot 'updates\last-update.json'
        $outcome = if (Test-Path -LiteralPath $outcomePath) { Get-Content -LiteralPath $outcomePath -Raw | ConvertFrom-Json } else { $null }
        $report = [ordered]@{
            schemaVersion = 1
            installedVersion = $installed.version
            expectedVersion = $expected.version
            manifestMatchesServed = ((Sha (Join-Path $fixtureRoot 'release-manifest.json')) -eq (Sha (Join-Path $served 'release-manifest.json')))
            mismatchedFiles = $mismatches
            sentinelKept = (Test-Path -LiteralPath (Join-Path $fixtureRoot 'data\sentinel.txt'))
            deltaDirRemoved = -not (Test-Path -LiteralPath (Join-Path $fixtureRoot 'updates\delta'))
            outcome = $outcome
            servedSetupBytes = (Get-Item -LiteralPath (Join-Path $served 'Nativune-Setup.exe')).Length
            regenerate = 'see the header of scripts/delta-update-app-e2e.ps1'
        }
        $report.passed = $report.installedVersion -eq $ToVersion -and $report.manifestMatchesServed -and $mismatches.Count -eq 0 -and $report.sentinelKept -and $report.deltaDirRemoved
        New-Item -ItemType Directory -Force -Path (Split-Path $reportPath) | Out-Null
        $report | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $reportPath -Encoding utf8
        $report | ConvertTo-Json -Depth 6
        if (-not $report.passed) { exit 1 }
    }
    'Remove' {
        foreach ($process in @(Get-FixtureProcesses)) { Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
        if ((Split-Path $fixtureRoot -Leaf) -ne 'Nativune-fixture') { throw 'Refusing to remove an unexpected folder.' }
        if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
        "Removed $fixtureRoot."
    }
}
