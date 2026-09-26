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

    # Run a copy from outside the install root so Setup uninstalls directly and returns its real
    # exit code (the installed copy hands off to a helper and cannot report the helper's result).
    $setupCopy = Join-Path $env:TEMP "Nativune-uninstall-$([guid]::NewGuid().ToString('N'))\Nativune.Setup.exe"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $setupCopy) | Out-Null
    Copy-Item -LiteralPath (Join-Path $installLocation 'installer\Nativune.Setup.exe') -Destination $setupCopy

    $packageArgs = @{
        packageName    = $env:ChocolateyPackageName
        fileType       = 'exe'
        file           = $setupCopy
        silentArgs     = "--uninstall --silent --install-dir `"$installLocation`""
        validExitCodes = @(0)
    }

    try { Uninstall-ChocolateyPackage @packageArgs }
    finally { Remove-Item -LiteralPath (Split-Path -Parent $setupCopy) -Recurse -Force -ErrorAction SilentlyContinue }
}
