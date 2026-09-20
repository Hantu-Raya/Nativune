[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('help', 'login', 'library', 'logout', 'self-check', 'media', 'media-control', 'web', 'native-fixture', 'native-interactions')]
    [string] $Command = 'help',
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]] $Arguments
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$application = Join-Path $root 'artifacts\winui3\publish\Nativune.exe'
if (-not (Test-Path -LiteralPath $application -PathType Leaf)) {
    throw "WinUI application not found at $application. Publish src\Nativune\Nativune.csproj through scripts\dotnet.ps1 to artifacts\winui3\publish first."
}
$temp = Join-Path $root '.cache\tmp'
[IO.Directory]::CreateDirectory($temp) | Out-Null
$env:TEMP = $temp
$env:TMP = $temp

# A pipeline makes PowerShell wait for the WinExe host and retain its exit code.
& $application $Command --root $root @Arguments | Out-Host
exit $LASTEXITCODE
