[CmdletBinding()]
param([switch]$Restore)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script from an elevated PowerShell window.'
}
$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$backupPath = Join-Path $root 'data\windows-background-policy-backup.json'
$policies = @(
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'ConnectedSearchUseWeb'; Value = 0 },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search'; Name = 'EnableDynamicContentInWSB'; Value = 0 },
    @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'; Name = 'NoAutoUpdate'; Value = 1 }
)
$serviceNames = @('wuauserv', 'EventLog')

if ($Restore) {
    $backup = Get-Content -LiteralPath $backupPath -Raw | ConvertFrom-Json
    if ($backup.Machine -ne [Environment]::MachineName) { throw 'This backup belongs to another computer.' }
    foreach ($policy in $policies) {
        $saved = @($backup.Policies | Where-Object Name -eq $policy.Name)
        if ($saved.Count -ne 1) { throw "Missing policy backup: $($policy.Name)" }
        if ($saved[0].Existed) {
            if (-not (Test-Path -LiteralPath $policy.Path)) {
                New-Item -Path $policy.Path -Force | Out-Null
            }
            New-ItemProperty -Path $policy.Path -Name $policy.Name -Value $saved[0].Value -PropertyType $saved[0].Kind -Force | Out-Null
        } elseif (Test-Path -LiteralPath $policy.Path) {
            Remove-ItemProperty -Path $policy.Path -Name $policy.Name -ErrorAction SilentlyContinue
        }
    }
    foreach ($name in $serviceNames) {
        $saved = @($backup.Services | Where-Object Name -eq $name)
        if ($saved.Count -ne 1) { throw "Missing service backup: $name" }
        Set-Service -Name $name -StartupType $saved[0].StartupType
        if ($saved[0].WasRunning) { Start-Service -Name $name }
    }
    Write-Host 'Original policies and service startup settings restored. Sign out/restart for Search to reload policy.'
} else {
    if (-not (Test-Path -LiteralPath $backupPath)) {
        $savedPolicies = @(foreach ($policy in $policies) {
            $key = Get-Item -LiteralPath $policy.Path -ErrorAction SilentlyContinue
            $exists = $null -ne $key -and $key.GetValueNames() -contains $policy.Name
            [pscustomobject]@{
                Name = $policy.Name
                Existed = $exists
                Kind = if ($exists) { $key.GetValueKind($policy.Name).ToString() } else { 'DWord' }
                Value = if ($exists) { $key.GetValue($policy.Name) } else { $null }
            }
        })
        $savedServices = @(foreach ($name in $serviceNames) {
            $service = Get-Service -Name $name
            [pscustomobject]@{ Name = $name; StartupType = $service.StartType.ToString(); WasRunning = $service.Status -eq 'Running' }
        })
        [IO.Directory]::CreateDirectory((Split-Path $backupPath)) | Out-Null
        [pscustomobject]@{ Machine = [Environment]::MachineName; Policies = $savedPolicies; Services = $savedServices } |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$backupPath.tmp" -Encoding utf8
        Move-Item -LiteralPath "$backupPath.tmp" -Destination $backupPath
    }
    foreach ($policy in $policies) {
        if (-not (Test-Path -LiteralPath $policy.Path)) {
            New-Item -Path $policy.Path -Force | Out-Null
        }
        New-ItemProperty -Path $policy.Path -Name $policy.Name -Value $policy.Value -PropertyType DWord -Force | Out-Null
    }
    foreach ($name in $serviceNames) {
        Set-Service -Name $name -StartupType Disabled
        $service = Get-Service -Name $name
        if ($service.Status -ne 'Stopped') {
            $service.Stop()
            $service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
    }
    Write-Host 'Search web results/highlights and automatic updates disabled; Windows Update and Event Log stopped/disabled.'
    Write-Host "Original settings saved locally: $backupPath"
    Write-Host 'Sign out/restart for Search policy changes. Windows servicing or managed policy may override these settings.'
}
Get-Service -Name $serviceNames | Select-Object Name,StartType,Status
