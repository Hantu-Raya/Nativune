$ErrorActionPreference = 'Stop'

try {
    $elevatedUser = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $consoleUser = (Get-CimInstance -ClassName Win32_ComputerSystem).UserName
    if ($consoleUser -and $consoleUser -ne $elevatedUser) {
        Write-Warning "Nativune installs per user. It will be installed for '$elevatedUser', not for the signed-in user '$consoleUser'. To install it for '$consoleUser', uninstall this package and run Nativune-Setup.exe from https://github.com/Hantu-Raya/Nativune/releases as that user."
    }
} catch {
    Write-Verbose "Could not compare the elevated and console users: $($_.Exception.Message)"
}

$packageArgs = @{
    packageName    = $env:ChocolateyPackageName
    fileType       = 'exe'
    url64bit       = 'https://github.com/Hantu-Raya/Nativune/releases/download/v{{VERSION}}/Nativune-Setup.exe'
    checksum64     = '{{SETUP_SHA256}}'
    checksumType64 = 'sha256'
    silentArgs     = '--silent --no-launch --install-prerequisites'
    validExitCodes = @(0)
    softwareName   = 'Nativune'
}

Install-ChocolateyPackage @packageArgs
