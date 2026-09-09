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
$project = Join-Path $root 'src\OAuthProbe\OAuthProbe.csproj'
$dotnet = Join-Path $PSScriptRoot 'dotnet.ps1'

& $dotnet run --project $project --configuration Release --no-build -- $Command --root $root @Arguments
exit $LASTEXITCODE
