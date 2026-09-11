[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'login', 'library', 'logout', 'self-check', 'media', 'media-control', 'web')]
    [string] $Command = 'help',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$application = Join-Path $root 'artifacts\bin\OAuthProbe\Release\net10.0-windows10.0.19041.0\OAuthProbe.dll'
if (-not (Test-Path -LiteralPath $application -PathType Leaf)) {
    throw "Release application not found at $application. Build Release through scripts\dotnet.ps1 first."
}
$dotnet = Join-Path $PSScriptRoot 'dotnet.ps1'

& $dotnet $application $Command --root $root @Arguments
exit $LASTEXITCODE
