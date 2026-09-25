<#
Installed-layout fixture for checking the in-app update flow on screen (owner-approved once, 25 September 2026).

Update checks run only in installed builds (root under %LOCALAPPDATA% with app\Nativune.exe and release-manifest.json),
so this script builds the app with -p:UpdaterTestHooks=true and lays it out at %LOCALAPPDATA%\Nativune-fixture with an
older manifest version. It never touches %LOCALAPPDATA%\Nativune (the owner's install).

  pwsh -NoProfile -File scripts/install-fixture.ps1 -Action Install [-Version 0.1.0]
  python scripts/updater-test-server.py --port 8765 --scenario available [--setup-file <Nativune-Setup.exe>] [--rate-kbps 4000] [--corrupt]
  pwsh -NoProfile -File scripts/install-fixture.ps1 -Action Start -MetadataUrl http://127.0.0.1:8765/repos/Hantu-Raya/Nativune/releases/latest
  pwsh -NoProfile -File scripts/install-fixture.ps1 -Action Remove

Test-hook builds are never published; build-release.ps1 always passes -p:UpdaterTestHooks=false.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [ValidateSet('Install', 'Start', 'Stop', 'Remove')] [string] $Action,
    [string] $Version = '0.1.0',
    [string] $MetadataUrl,
    # Release payload ZIP from scripts/build-release.ps1; gives the fixture a real install layout
    # (installer/, licenses/, .tools/) that Setup validates during an update.
    [string] $PayloadZip = 'artifacts\release\Nativune-Setup.zip'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$localAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)
if ([string]::IsNullOrWhiteSpace($localAppData)) { throw 'LocalApplicationData is unavailable.' }
$fixtureRoot = Join-Path $localAppData 'Nativune-fixture'
$appRoot = Join-Path $fixtureRoot 'app'
$publishRoot = Join-Path $repo 'artifacts\winui3\publish-updater-hooks'

function Get-FixtureProcesses {
    Get-CimInstance Win32_Process -Filter "Name='Nativune.exe'" |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($appRoot + '\', [StringComparison]::OrdinalIgnoreCase) }
}

function Stop-Fixture {
    foreach ($process in @(Get-FixtureProcesses)) {
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

switch ($Action) {
    'Install' {
        if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw 'Version must be a stable x.y.z version.' }
        Stop-Fixture
        & pwsh -NoProfile -File (Join-Path $repo 'scripts\dotnet.ps1') publish (Join-Path $repo 'src\Nativune\Nativune.csproj') `
            --runtime win-x64 --self-contained false -p:UpdaterTestHooks=true -o $publishRoot
        if ($LASTEXITCODE -ne 0) { throw 'Test-hook publish failed.' }

        New-Item -ItemType Directory -Force -Path $appRoot, (Join-Path $fixtureRoot 'data') | Out-Null
        # Same private, protected DACL Setup gives a real install (current user, SYSTEM, Administrators),
        # so Setup's root validation accepts the fixture during an update.
        $user = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        & icacls $fixtureRoot /inheritance:r /grant:r "*${user}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /C /Q | Out-Null
        if ($LASTEXITCODE -ne 0) { throw 'Could not set the fixture folder permissions.' }
        # Existing children inherit that DACL again (earlier fixtures may carry other ACLs).
        & icacls (Join-Path $fixtureRoot '*') /reset /T /C /Q | Out-Null
        $payload = Join-Path $repo $PayloadZip
        if (-not (Test-Path -LiteralPath $payload -PathType Leaf)) { throw "Payload ZIP not found: $payload (run scripts/build-release.ps1)." }
        # Replace everything except the fixture's own data/ profile.
        foreach ($item in Get-ChildItem -LiteralPath $fixtureRoot -Force) {
            if ($item.Name -ne 'data') { Remove-Item -LiteralPath $item.FullName -Recurse -Force }
        }
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($payload)
        try {
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName -eq 'release-manifest.json' -or $entry.FullName.EndsWith('/')) { continue }
                $target = [IO.Path]::GetFullPath((Join-Path $fixtureRoot $entry.FullName))
                if (-not $target.StartsWith($fixtureRoot + '\', [StringComparison]::OrdinalIgnoreCase)) { throw "Unsafe payload path: $($entry.FullName)" }
                New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
                [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
            }
        } finally { $zip.Dispose() }
        # The app itself is the test-hook build so it can read the loopback feed.
        Remove-Item -LiteralPath $appRoot -Recurse -Force
        New-Item -ItemType Directory -Force -Path $appRoot | Out-Null
        Copy-Item -Path (Join-Path $publishRoot '*') -Destination $appRoot -Recurse -Force

        $excluded = @('data', 'updates')
        $files = foreach ($file in Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File) {
            $relative = $file.FullName.Substring($fixtureRoot.Length + 1).Replace('\', '/')
            if ($relative -eq 'release-manifest.json' -or $excluded -contains $relative.Split('/')[0]) { continue }
            [ordered]@{
                path = $relative
                length = $file.Length
                sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
        $manifest = [ordered]@{
            schemaVersion = 1
            product = 'Nativune'
            version = $Version
            executable = 'app/Nativune.exe'
            files = @($files)
        }
        $manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixtureRoot 'release-manifest.json') -Encoding utf8
        "Fixture installed at $fixtureRoot as version $Version."
    }
    'Start' {
        if (-not (Test-Path -LiteralPath (Join-Path $appRoot 'Nativune.exe'))) { throw 'Run -Action Install first.' }
        if (@(Get-FixtureProcesses).Count -gt 0) { throw 'The fixture is already running.' }
        if ($MetadataUrl) {
            if ($MetadataUrl -notmatch '^http://127\.0\.0\.1:\d+/') { throw 'MetadataUrl must be a loopback test-server URL.' }
            $env:NATIVUNE_TEST_RELEASE_METADATA_URL = $MetadataUrl
        }
        $process = Start-Process -FilePath (Join-Path $appRoot 'Nativune.exe') -ArgumentList @('web', '--root', "`"$fixtureRoot`"") -PassThru
        "Started fixture pid $($process.Id)."
    }
    'Stop' { Stop-Fixture; 'Fixture stopped.' }
    'Remove' {
        Stop-Fixture
        Start-Sleep -Seconds 1
        if ((Split-Path $fixtureRoot -Leaf) -ne 'Nativune-fixture') { throw 'Refusing to remove an unexpected folder.' }
        if (Test-Path -LiteralPath $fixtureRoot) { Remove-Item -LiteralPath $fixtureRoot -Recurse -Force }
        "Removed $fixtureRoot."
    }
}
