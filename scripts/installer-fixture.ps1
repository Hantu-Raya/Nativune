# Usage: .\scripts\installer-fixture.ps1 -PayloadZip artifacts\release\Nativune-Setup.zip
# PayloadZip must be the release payload ZIP produced by scripts\build-release.ps1. This script
# publishes a Setup stub with INSTALLER_TEST_HOOKS, appends that payload, and runs it only under .cache.

[CmdletBinding()]
param(
    [string] $PayloadZip = 'artifacts/release/Nativune-Setup.zip',
    [ValidateSet('Debug', 'Release')]
    [string] $Configuration = 'Release'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repository = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$repository = [IO.Path]::GetFullPath($repository).TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
$fixtureRoot = [IO.Path]::GetFullPath((Join-Path $repository '.cache\install-fixture'))
$workRoot = [IO.Path]::GetFullPath((Join-Path $repository '.cache\installer-fixture-work'))
$reportDirectory = [IO.Path]::GetFullPath((Join-Path $repository 'artifacts\installer-fixture'))
$reportPath = Join-Path $reportDirectory 'report.json'
$payloadPath = $null
$failure = $null
$scenarioReports = [System.Collections.Generic.List[object]]::new()
$report = [ordered]@{
    schemaVersion = 1
    status = 'running'
    payloadZip = $PayloadZip
    buildCommand = $null
    scenarios = $scenarioReports
}

function Assert-NoReparseChain([string] $Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($true) {
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Fixture path contains a reparse point: $current"
            }
        }
        if ($current.Equals($repository, [StringComparison]::OrdinalIgnoreCase)) {
            return
        }
        $parent = [IO.Directory]::GetParent($current)
        if ($null -eq $parent) {
            throw "Fixture path could not be traced to the repository root: $Path"
        }
        $current = $parent.FullName
    }
}

function Resolve-RepositoryPath([string] $Path) {
    if ([IO.Path]::IsPathRooted($Path)) {
        $candidate = [IO.Path]::GetFullPath($Path)
    } else {
        $candidate = [IO.Path]::GetFullPath((Join-Path $repository $Path))
    }
    $prefix = $repository + [IO.Path]::DirectorySeparatorChar
    if (-not ($candidate.Equals($repository, [StringComparison]::OrdinalIgnoreCase) -or
        $candidate.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase))) {
        throw "Path is outside the repository: $Path"
    }
    Assert-NoReparseChain $candidate
    return $candidate
}

function Assert-RegularFile([string] $Path, [string] $Description) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "$Description is missing: $Path"
    }
    $item = Get-Item -LiteralPath $Path -Force
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "$Description is a reparse point: $Path"
    }
}

function Remove-ProjectDirectory([string] $Path, [string] $ExpectedPath) {
    $fullPath = [IO.Path]::GetFullPath($Path)
    if (-not $fullPath.Equals($ExpectedPath, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to remove an unexpected fixture path: $fullPath"
    }
    Assert-NoReparseChain $fullPath
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return
    }
    $item = Get-Item -LiteralPath $fullPath -Force
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "Refusing to remove a non-directory or reparse-point fixture path: $fullPath"
    }
    Remove-Item -LiteralPath $fullPath -Recurse -Force
}

function ConvertTo-WindowsArgument([string] $Value) {
    $builder = [Text.StringBuilder]::new().Append('"')
    $backslashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') {
            $backslashes++
            continue
        }
        if ($character -eq '"') {
            [void]$builder.Append('\', ($backslashes * 2) + 1).Append('"')
            $backslashes = 0
            continue
        }
        if ($backslashes -gt 0) {
            [void]$builder.Append('\', $backslashes)
            $backslashes = 0
        }
        [void]$builder.Append($character)
    }
    if ($backslashes -gt 0) {
        [void]$builder.Append('\', $backslashes * 2)
    }
    return $builder.Append('"').ToString()
}

function Invoke-Setup([string] $FileName, [string[]] $Arguments) {
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $FileName
    $startInfo.Arguments = (($Arguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')
    $startInfo.WorkingDirectory = $repository
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = [Text.UTF8Encoding]::new($false)
    $startInfo.StandardErrorEncoding = [Text.UTF8Encoding]::new($false)

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $startInfo
    if (-not $process.Start()) {
        throw "Could not start Setup: $FileName"
    }
    $stdoutTask = $process.StandardOutput.ReadToEndAsync()
    $stderrTask = $process.StandardError.ReadToEndAsync()
    $process.WaitForExit()
    $commandParts = @($FileName) + @($Arguments)
    $commandText = ($commandParts | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' '
    return [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout = $stdoutTask.GetAwaiter().GetResult()
        Stderr = $stderrTask.GetAwaiter().GetResult()
        Command = $commandText
    }
}

function Assert-NoFixtureAppProcess([string] $Executable) {
    $expectedPath = [IO.Path]::GetFullPath($Executable)
    foreach ($process in [Diagnostics.Process]::GetProcessesByName('Nativune')) {
        try {
            $actualPath = $process.MainModule.FileName
            if ([IO.Path]::GetFullPath($actualPath).Equals($expectedPath, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Nativune.exe was started from the fixture root: $actualPath"
            }
        }
        catch [System.ComponentModel.Win32Exception] {
            throw "Could not verify whether Nativune.exe was started from the fixture root."
        }
        catch [InvalidOperationException] {
            continue
        }
        finally {
            $process.Dispose()
        }
    }
}


function New-AppendedSetup([string] $StubPath, [string] $ZipPath, [string] $OutputPath) {
    Assert-RegularFile $StubPath 'The test-hook Setup stub'
    Assert-RegularFile $ZipPath 'The release payload ZIP'
    if (Test-Path -LiteralPath $OutputPath) {
        throw "The fixture Setup output already exists: $OutputPath"
    }
    $stubLength = (Get-Item -LiteralPath $StubPath).Length
    $zipLength = (Get-Item -LiteralPath $ZipPath).Length
    if ($stubLength -le 0 -or $zipLength -le 0) {
        throw 'The Setup stub or release payload ZIP is empty.'
    }
    $output = [IO.File]::Open($OutputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try {
        $stub = [IO.File]::OpenRead($StubPath)
        $zip = [IO.File]::OpenRead($ZipPath)
        try {
            $stub.CopyTo($output, 131072)
            $zip.CopyTo($output, 131072)
        } finally {
            $zip.Dispose()
            $stub.Dispose()
        }
        $writer = [IO.BinaryWriter]::new($output, [Text.Encoding]::UTF8, $true)
        try {
            $writer.Write([Text.Encoding]::ASCII.GetBytes('NATIVN01'))
            $writer.Write([uint32]1)
            $writer.Write([int64]$stubLength)
            $writer.Write([int64]$zipLength)
            $writer.Write([uint32]0)
        } finally {
            $writer.Dispose()
        }
    } finally {
        $output.Dispose()
    }
}

try {
    if (-not [Environment]::OSVersion.Platform.Equals([PlatformID]::Win32NT)) {
        throw 'The installer fixture runs on Windows only.'
    }
    [void](Resolve-RepositoryPath '.cache')
    [void](Resolve-RepositoryPath 'artifacts')
    $payloadPath = Resolve-RepositoryPath $PayloadZip
    Assert-RegularFile $payloadPath 'The release payload ZIP'

    Remove-ProjectDirectory $fixtureRoot $fixtureRoot
    Remove-ProjectDirectory $workRoot $workRoot
    [IO.Directory]::CreateDirectory($workRoot) | Out-Null
    $publishRoot = Join-Path $workRoot 'publish'
    [IO.Directory]::CreateDirectory($publishRoot) | Out-Null
    $installerProject = Resolve-RepositoryPath 'src\Nativune.Installer\Nativune.Installer.csproj'
    $dotnetScript = Resolve-RepositoryPath 'scripts\dotnet.ps1'
    $buildArguments = @(
        'publish', $installerProject,
        '--configuration', $Configuration,
        '--output', $publishRoot,
        '-p:InstallerTestHooks=true'
    )
    $report.buildCommand = "& pwsh -NoProfile -File $(ConvertTo-WindowsArgument $dotnetScript) $(($buildArguments | ForEach-Object { ConvertTo-WindowsArgument $_ }) -join ' ')"
    & pwsh -NoProfile -File $dotnetScript @buildArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Test-hook Setup publish failed with exit code $LASTEXITCODE."
    }

    $stubPath = Join-Path $publishRoot 'Nativune.Setup.exe'
    $testSetupPath = Join-Path $workRoot 'Nativune-Setup.exe'
    New-AppendedSetup $stubPath $payloadPath $testSetupPath

    $scenarios = @(
        [pscustomobject]@{ Name = 'present'; ExpectedExitCode = 0; ExpectedStatus = 'installed' },
        [pscustomobject]@{ Name = 'missing'; ExpectedExitCode = 19; ExpectedStatus = 'failed' },
        [pscustomobject]@{ Name = 'declined'; ExpectedExitCode = 3; ExpectedStatus = 'cancelled' },
        [pscustomobject]@{ Name = 'offline'; ExpectedExitCode = 19; ExpectedStatus = 'failed' }
    )
    foreach ($scenario in $scenarios) {
        Remove-ProjectDirectory $fixtureRoot $fixtureRoot
        $arguments = @(
            '--silent', '--test-no-shell', '--no-launch',
            '--test-prerequisites', $scenario.Name,
            '--install-dir', $fixtureRoot
        )
        $run = Invoke-Setup $testSetupPath $arguments
        $stdoutLines = @($run.Stdout -split "`r?`n" | Where-Object { $_.Length -gt 0 })
        $stderrLines = @($run.Stderr -split "`r?`n" | Where-Object { $_.Length -gt 0 })
        if ($run.ExitCode -ne $scenario.ExpectedExitCode) {
            throw "$($scenario.Name) returned exit code $($run.ExitCode), expected $($scenario.ExpectedExitCode). stderr: $($run.Stderr.Trim())"
        }
        if (-not ($stdoutLines | Where-Object { $_.Contains('Checking for required Microsoft components') })) {
            throw "$($scenario.Name) did not print its component-check step to stdout."
        }
        if ($scenario.Name -eq 'present') {
            $requiredSteps = @('Unpacking Nativune', 'Checking free space', 'Installing files', 'shortcuts')
            $nextStep = 0
            foreach ($line in $stdoutLines) {
                if ($line.Contains($requiredSteps[$nextStep])) {
                    $nextStep++
                    if ($nextStep -eq $requiredSteps.Count) { break }
                }
            }
            if ($nextStep -ne $requiredSteps.Count) {
                throw "present did not print the expected ordered steps: $($requiredSteps -join ' -> ')."
            }
        }

        $resultPath = Join-Path $fixtureRoot 'updates\last-update.json'
        $result = $null
        if ($scenario.Name -eq 'present') {
            if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
                throw "$($scenario.Name) did not write last-update.json."
            }
            Assert-NoReparseChain $resultPath
            $result = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            if ($result.schemaVersion -ne 1 -or $result.status -ne $scenario.ExpectedStatus -or $result.exitCode -ne $scenario.ExpectedExitCode) {
                throw "$($scenario.Name) result file was inconsistent with its exit code."
            }
            if ([string]::IsNullOrWhiteSpace($result.toVersion) -or $result.toVersion.StartsWith('v', [StringComparison]::OrdinalIgnoreCase)) {
                throw "$($scenario.Name) result file did not use manifest-form version text."
            }
            $fixtureExecutable = Join-Path $fixtureRoot 'app\Nativune.exe'
            Assert-NoFixtureAppProcess $fixtureExecutable

            $waitInfo = [Diagnostics.ProcessStartInfo]::new()
            $waitInfo.FileName = $env:ComSpec
            $waitInfo.Arguments = '/d /c "ping -n 2 127.0.0.1 > nul"'
            $waitInfo.UseShellExecute = $false
            $waitInfo.CreateNoWindow = $true
            $waitProcess = [Diagnostics.Process]::Start($waitInfo)
            if ($null -eq $waitProcess) {
                throw 'Could not start the short-lived process for the update-mode fixture.'
            }
            $waitPid = $waitProcess.Id
            $updateArguments = @(
                '--update', '--wait-pid', [string]$waitPid,
                '--silent', '--test-no-shell', '--no-launch',
                '--expected-version', '9.9.9',
                '--install-dir', $fixtureRoot
            )
            try {
                $updateRun = Invoke-Setup $testSetupPath $updateArguments
            }
            finally {
                $waitProcess.WaitForExit()
                $waitProcess.Dispose()
            }
            if ($updateRun.ExitCode -ne 10) {
                throw "update returned exit code $($updateRun.ExitCode), expected 10. stderr: $($updateRun.Stderr.Trim())"
            }
            Assert-NoFixtureAppProcess $fixtureExecutable

            Assert-NoReparseChain $resultPath
            $updateResult = Get-Content -LiteralPath $resultPath -Raw | ConvertFrom-Json
            if ($updateResult.schemaVersion -ne 1 -or $updateResult.status -ne 'failed' -or $updateResult.exitCode -ne 10) {
                throw 'update result file did not report the expected failed status and exit code.'
            }
            $scenarioReports.Add([ordered]@{
                name = 'update-wrong-expected-version'
                command = $updateRun.Command
                arguments = $updateArguments
                exitCode = $updateRun.ExitCode
                expectedExitCode = 10
                status = $updateResult.status
                expectedStatus = 'failed'
                stdout = @($updateRun.Stdout -split "`r?`n" | Where-Object { $_.Length -gt 0 })
                stderr = @($updateRun.Stderr -split "`r?`n" | Where-Object { $_.Length -gt 0 })
                fixtureAppStarted = $false
            })
        }
        else {
            if (Test-Path -LiteralPath $fixtureRoot) {
                throw "$($scenario.Name) created the fresh install root before setup changed it."
            }
            if (Test-Path -LiteralPath $resultPath) {
                throw "$($scenario.Name) unexpectedly wrote last-update.json."
            }
        }
        $reportedStatus = 'not-written'
        $reportedExpectedStatus = 'not-written'
        if ($null -ne $result) {
            $reportedStatus = $result.status
            $reportedExpectedStatus = $scenario.ExpectedStatus
        }


        $scenarioReports.Add([ordered]@{
            name = $scenario.Name
            command = $run.Command
            arguments = $arguments
            exitCode = $run.ExitCode
            expectedExitCode = $scenario.ExpectedExitCode
            status = $reportedStatus
            expectedStatus = $reportedExpectedStatus
            stdout = $stdoutLines
            stderr = $stderrLines
            stepOrderChecked = ($scenario.Name -eq 'present')
        })
    }
    $report.status = 'passed'
}
catch {
    $failure = $_.Exception.Message
    $report.status = 'failed'
    $report.error = $failure
}
finally {
    try { Remove-ProjectDirectory $fixtureRoot $fixtureRoot } catch { if ($null -eq $failure) { $failure = $_.Exception.Message; $report.status = 'failed'; $report.error = $failure } }
    try { Remove-ProjectDirectory $workRoot $workRoot } catch { if ($null -eq $failure) { $failure = $_.Exception.Message; $report.status = 'failed'; $report.error = $failure } }
    try {
        Assert-NoReparseChain $reportDirectory
        [IO.Directory]::CreateDirectory($reportDirectory) | Out-Null
        if ((Test-Path -LiteralPath $reportPath) -and ((Get-Item -LiteralPath $reportPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "The fixture report is a reparse point: $reportPath"
        }
        $json = $report | ConvertTo-Json -Depth 10
        [IO.File]::WriteAllText($reportPath, $json, [Text.UTF8Encoding]::new($false))
    }
    catch {
        if ($null -eq $failure) { $failure = $_.Exception.Message }
    }
}

if ($null -ne $failure) {
    throw "Installer fixture failed: $failure. See $reportPath."
}
Write-Output "Installer fixture passed. Report: $reportPath"
