$Arguments = @($args)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$sdkRoot = Join-Path $root '.tools\dotnet'
$dotnet = Join-Path $sdkRoot 'dotnet.exe'
if (-not (Test-Path -LiteralPath $dotnet -PathType Leaf)) {
    throw "Local SDK not found at $sdkRoot. Run scripts\setup.ps1 first."
}

$cache = Join-Path $root '.cache'
$nuget = Join-Path $cache 'nuget'
$temp = Join-Path $cache 'tmp'
$directories = @(
    (Join-Path $cache 'dotnet-cli'),
    (Join-Path $nuget 'packages'),
    (Join-Path $nuget 'http'),
    (Join-Path $nuget 'plugins'),
    (Join-Path $nuget 'scratch'),
    $temp,
    (Join-Path $cache 'dotnet-bundles')
)
foreach ($directory in $directories) {
    [IO.Directory]::CreateDirectory($directory) | Out-Null
}

$env:DOTNET_ROOT = $sdkRoot
$env:DOTNET_MULTILEVEL_LOOKUP = '0'
$env:DOTNET_CLI_HOME = Join-Path $cache 'dotnet-cli'
$env:NUGET_PACKAGES = Join-Path $nuget 'packages'
$env:NUGET_HTTP_CACHE_PATH = Join-Path $nuget 'http'
$env:NUGET_PLUGINS_CACHE_PATH = Join-Path $nuget 'plugins'
$env:NUGET_SCRATCH = Join-Path $nuget 'scratch'
$env:NUGET_SCRATCHROOT = Join-Path $nuget 'scratch'
$env:TEMP = $temp
$env:TMP = $temp
$env:DOTNET_BUNDLE_EXTRACT_BASE_DIR = Join-Path $cache 'dotnet-bundles'
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'
$env:DOTNET_GENERATE_ASPNET_CERTIFICATE = 'false'
$env:DOTNET_ADD_GLOBAL_TOOLS_TO_PATH = 'false'
$env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
$env:DOTNET_SKIP_WORKLOAD_MANIFEST_UPDATE = '1'
$env:DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE = '1'
$env:MSBUILDDISABLENODEREUSE = '1'
$env:MSBUILDUSESERVER = '0'

$nugetConfig = Join-Path $root 'NuGet.Config'
$forward = @($Arguments)
$command = if ($Arguments.Count -gt 0) { $Arguments[0].ToLowerInvariant() } else { '' }
if ($command -eq 'restore' -and -not ($Arguments -contains '--configfile')) {
    $forward += @('--configfile', $nugetConfig)
} elseif ($command -eq 'tool' -and $Arguments.Count -gt 1 -and $Arguments[1].ToLowerInvariant() -eq 'restore' -and -not ($Arguments -contains '--configfile')) {
    $forward += @('--configfile', $nugetConfig)
} elseif (@('build', 'test', 'pack', 'publish') -contains $command -and -not ($Arguments -match '(^|[/:])-p:RestoreConfigFile=')) {
    $forward += "-p:RestoreConfigFile=$nugetConfig"
} elseif ($command -eq 'run' -and -not ($Arguments -contains '--no-build') -and -not ($Arguments -match '(^|[/:])-p:RestoreConfigFile=')) {
    $property = "-p:RestoreConfigFile=$nugetConfig"
    $separator = [Array]::IndexOf([string[]]$forward, '--')
    if ($separator -ge 0) {
        $forward = @($forward[0..($separator - 1)]) + $property + @($forward[$separator..($forward.Count - 1)])
    } else {
        $forward += $property
    }
}

& $dotnet @forward
exit $LASTEXITCODE
