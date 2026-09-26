$ErrorActionPreference = 'Stop'

[array] $keys = Get-UninstallRegistryKey -SoftwareName 'Nativune'

if ($keys.Count -eq 0) {
    Write-Warning 'Nativune was not found in the installed programs of this account. Nothing was uninstalled.'
    exit 0
}

foreach ($key in $keys) {
    $installLocation = "$($key.InstallLocation)".TrimEnd('\')
    if (-not $installLocation) {
        Write-Warning "Skipping '$($key.DisplayName)': no install location is registered."
        continue
    }

    $packageArgs = @{
        packageName    = $env:ChocolateyPackageName
        fileType       = 'exe'
        file           = Join-Path $installLocation 'installer\Nativune.Setup.exe'
        silentArgs     = "--uninstall --silent --install-dir `"$installLocation`""
        validExitCodes = @(0)
    }

    Uninstall-ChocolateyPackage @packageArgs
}
