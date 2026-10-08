[CmdletBinding()]
param(
    [ValidateSet('winget', 'chocolatey')]
    [string] $Store,
    [ValidatePattern('^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$')]
    [string] $Version,
    [switch] $SelfCheck
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Failure modes first: pending is not failure, absent/rejected is not pending,
# duplicates/newer approvals must not publish, and API errors must not mean missing.
$selfCheckCases = @(
    @{ Name = 'winget first approval pending'; Kind = 'state'; Input = @{ InitialPending = $true }; Expected = 'waiting-first-approval' }
    @{ Name = 'chocolatey first approval pending'; Kind = 'state'; Input = @{ Store = 'chocolatey'; InitialPending = $true }; Expected = 'waiting-first-approval' }
    @{ Name = 'winget ready'; Kind = 'state'; Input = @{ ApprovedVersions = @('0.1.32') }; Expected = 'ready' }
    @{ Name = 'chocolatey ready'; Kind = 'state'; Input = @{ Store = 'chocolatey'; ApprovedVersions = @('0.1.32') }; Expected = 'ready' }
    @{ Name = 'winget open duplicate'; Kind = 'state'; Input = @{ ApprovedVersions = @('0.1.32'); TargetPrOpen = $true }; Expected = 'submitted-pending' }
    @{ Name = 'chocolatey exact pending duplicate'; Kind = 'state'; Input = @{ Store = 'chocolatey'; TargetPackage = @{ Version = '0.1.39'; IsApproved = $false; PackageStatus = 'Submitted' } }; Expected = 'submitted-pending' }
    @{ Name = 'approved target'; Kind = 'state'; Input = @{ ApprovedVersions = @('0.1.39') }; Expected = 'up-to-date' }
    @{ Name = 'chocolatey exact approved'; Kind = 'state'; Input = @{ Store = 'chocolatey'; TargetPackage = @{ Version = '0.1.39'; IsApproved = $true; PackageStatus = 'Approved' } }; Expected = 'up-to-date' }
    @{ Name = 'newer approved'; Kind = 'state'; Input = @{ ApprovedVersions = @('0.1.40') }; Expected = 'superseded' }
    @{ Name = 'rejected exact package'; Kind = 'state'; Input = @{ Store = 'chocolatey'; TargetPackage = @{ Version = '0.1.39'; IsApproved = $false; PackageStatus = 'Rejected' } }; Expected = 'throw' }
    @{ Name = 'unrecognized exact status'; Kind = 'state'; Input = @{ Store = 'chocolatey'; TargetPackage = @{ Version = '0.1.39'; IsApproved = $false; PackageStatus = 'Unknown' } }; Expected = 'throw' }
    @{ Name = 'wrong exact version'; Kind = 'state'; Input = @{ Store = 'chocolatey'; TargetPackage = @{ Version = '0.1.390'; IsApproved = $true; PackageStatus = 'Approved' } }; Expected = 'throw' }
    @{ Name = 'initial submission absent'; Kind = 'state'; Input = @{}; Expected = 'throw' }
    @{ Name = 'HTTP 200 present'; Kind = 'http'; Input = 200; Expected = 'present' }
    @{ Name = 'only HTTP 404 missing'; Kind = 'http'; Input = 404; Expected = 'missing' }
    @{ Name = 'HTTP 403 fails'; Kind = 'http'; Input = 403; Expected = 'throw' }
    @{ Name = 'HTTP 500 fails'; Kind = 'http'; Input = 500; Expected = 'throw' }
    @{ Name = 'exact version title'; Kind = 'title'; Input = 'Update Nativune.Nativune version 0.1.39'; Expected = $true }
    @{ Name = 'version substring is not exact'; Kind = 'title'; Input = 'Update Nativune.Nativune version 0.1.390'; Expected = $false }
    @{ Name = 'complete PR search'; Kind = 'search'; Input = @{ incomplete_results = $false; total_count = 0; items = @() }; Expected = 'complete' }
    @{ Name = 'incomplete PR search fails'; Kind = 'search'; Input = @{ incomplete_results = $true; total_count = 0; items = @() }; Expected = 'throw' }
    @{ Name = 'truncated PR search fails'; Kind = 'search'; Input = @{ incomplete_results = $false; total_count = 101; items = @() }; Expected = 'throw' }
)

function Get-HttpState([int] $StatusCode) {
    if ($StatusCode -eq 200) { return 'present' }
    if ($StatusCode -eq 404) { return 'missing' }
    throw "Preflight HTTP request failed with status $StatusCode."
}

function Test-VersionTitle([string] $Title, [string] $ExpectedVersion) {
    return $Title -match '(?<!\S)Nativune\.Nativune(?!\S)' -and
        $Title -match ('(?<!\S)' + [regex]::Escape($ExpectedVersion) + '(?!\S)')
}

function Assert-CompleteSearch($Results) {
    if ($Results.incomplete_results -isnot [bool] -or $Results.incomplete_results -or
        $Results.total_count -lt 0 -or $Results.total_count -ne @($Results.items).Count) {
        throw 'The winget PR search was incomplete; refusing to infer that no PR exists.'
    }
}

function Get-PackageManagerState(
    [string] $Store,
    [version] $Version,
    [string[]] $ApprovedVersions = @(),
    [hashtable] $TargetPackage = $null,
    [bool] $InitialPending = $false,
    [bool] $TargetPrOpen = $false
) {
    if ($TargetPackage) {
        if ($TargetPackage.Version -ne $Version.ToString() -or
            $TargetPackage.IsApproved -isnot [bool] -or
            (-not $TargetPackage.IsApproved -and $TargetPackage.PackageStatus -ne 'Submitted')) {
            throw 'The exact Chocolatey package has an unexpected version or moderation status.'
        }
    }
    if (@($ApprovedVersions | Where-Object { [version]$_ -gt $Version }).Count -gt 0) { return 'superseded' }
    if (@($ApprovedVersions | Where-Object { [version]$_ -eq $Version }).Count -gt 0 -or
        ($TargetPackage -and $TargetPackage.IsApproved)) { return 'up-to-date' }
    if ($TargetPrOpen -or $TargetPackage) { return 'submitted-pending' }
    if ($ApprovedVersions.Count -gt 0) { return 'ready' }
    if ($InitialPending) { return 'waiting-first-approval' }
    throw "$Store has no approved version and its initial submission is missing or requires attention."
}

if ($SelfCheck) {
    foreach ($case in $selfCheckCases) {
        $actual = $null
        try {
            switch ($case.Kind) {
                'state' {
                    $parameters = @{ Store = 'winget'; Version = [version]'0.1.39' }
                    foreach ($key in $case.Input.Keys) { $parameters[$key] = $case.Input[$key] }
                    $actual = Get-PackageManagerState @parameters
                }
                'http' { $actual = Get-HttpState $case.Input }
                'title' { $actual = Test-VersionTitle $case.Input '0.1.39' }
                'search' { Assert-CompleteSearch $case.Input; $actual = 'complete' }
            }
        } catch {
            if ($case.Expected -ne 'throw') { throw }
            $actual = 'throw'
        }
        if ($actual -ne $case.Expected) { throw "Self-check failed: $($case.Name); expected $($case.Expected), got $actual." }
        Write-Output "PASS $($case.Name)"
    }
    return
}
if (-not $Store -or -not $Version) { throw 'Live preflight requires -Store and -Version.' }

function Get-Resource([string] $Uri) {
    $headers = @{ 'User-Agent' = 'Nativune-package-preflight' }
    if ($Uri.StartsWith('https://api.github.com/', [StringComparison]::Ordinal)) {
        $headers['Accept'] = 'application/vnd.github+json'
        $headers['X-GitHub-Api-Version'] = '2022-11-28'
        if ($env:GH_TOKEN) { $headers['Authorization'] = "Bearer $env:GH_TOKEN" }
    }
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            $response = Invoke-WebRequest -Uri $Uri -Headers $headers -SkipHttpErrorCheck -TimeoutSec 30
        } catch {
            if ($attempt -eq 3) { throw "Preflight could not reach $Uri after three attempts." }
            Start-Sleep -Seconds $attempt
            continue
        }
        $status = [int]$response.StatusCode
        if (($status -eq 429 -or $status -ge 500) -and $attempt -lt 3) {
            Start-Sleep -Seconds $attempt
            continue
        }
        if ((Get-HttpState $status) -eq 'missing') { return $null }
        return $response.Content
    }
}

function Test-WingetPr($Pr, [string] $ExpectedVersion) {
    return $null -ne $Pr -and $Pr.state -eq 'open' -and
        $Pr.user.login -eq 'Hantu-Raya' -and
        $Pr.base.repo.full_name -eq 'microsoft/winget-pkgs' -and
        $Pr.head.repo.full_name -eq 'Hantu-Raya/winget-pkgs' -and
        (Test-VersionTitle $Pr.title $ExpectedVersion)
}

function Get-ChocolateyRecords([string] $Content, [switch] $LatestApproved) {
    [xml]$xml = $Content
    $namespaces = [Xml.XmlNamespaceManager]::new($xml.NameTable)
    $namespaces.AddNamespace('a', 'http://www.w3.org/2005/Atom')
    $namespaces.AddNamespace('m', 'http://schemas.microsoft.com/ado/2007/08/dataservices/metadata')
    $namespaces.AddNamespace('d', 'http://schemas.microsoft.com/ado/2007/08/dataservices')
    $root = if ($LatestApproved) { '/a:feed' } else { '/a:entry' }
    if (-not $xml.SelectSingleNode($root, $namespaces)) { throw 'Unexpected Chocolatey XML response.' }
    $entries = @(if ($LatestApproved) { $xml.SelectNodes('/a:feed/a:entry', $namespaces) } else { $xml.SelectNodes('/a:entry', $namespaces) })
    # Chocolatey emits a next link even for IsLatestVersion; only this filtered query ignores it.
    if ($LatestApproved -and $entries.Count -gt 1) { throw 'Chocolatey returned more than one latest approved version.' }
    foreach ($entry in $entries) {
        if ($entry.SelectSingleNode('a:title', $namespaces).InnerText -ne 'nativune') { throw 'Unexpected Chocolatey package identity.' }
        $properties = $entry.SelectSingleNode('m:properties', $namespaces)
        $record = @{}
        foreach ($name in 'Version', 'IsApproved', 'PackageStatus') {
            $node = $properties.SelectSingleNode("d:$name", $namespaces)
            if (-not $node -or [string]::IsNullOrWhiteSpace($node.InnerText)) { throw "Chocolatey omitted $name." }
            $record[$name] = $node.InnerText
        }
        if ($record.Version -notmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$') {
            throw 'Chocolatey returned an unsupported package version.'
        }
        $approved = $false
        if (-not [bool]::TryParse($record.IsApproved, [ref]$approved)) { throw 'Chocolatey returned an invalid IsApproved value.' }
        if ($LatestApproved -and -not $approved) { throw 'Chocolatey returned an unapproved version in the latest-approved query.' }
        $record.IsApproved = $approved
        $record
    }
}

function Get-ChocolateyPackage([string] $PackageVersion) {
    $content = Get-Resource "https://community.chocolatey.org/api/v2/Packages(Id='nativune',Version='$PackageVersion')"
    if ($null -eq $content) { return $null }
    $record = Get-ChocolateyRecords $content
    if ($record.Version -ne $PackageVersion) { throw 'Chocolatey returned the wrong exact version.' }
    return $record
}

$approvedVersions = @()
$targetPackage = $null
$initialPending = $false
$targetPrOpen = $false
$reviewUrl = ''
if ($Store -eq 'winget') {
    $api = 'https://api.github.com/repos/microsoft/winget-pkgs'
    $content = Get-Resource "$api/contents/manifests/n/Nativune/Nativune?ref=master"
    if ($null -eq $content) {
        $initialContent = Get-Resource "$api/pulls/442614"
        if ($null -ne $initialContent) {
            $initial = $initialContent | ConvertFrom-Json
            $initialPending = Test-WingetPr $initial '0.1.32'
            $reviewUrl = 'https://github.com/microsoft/winget-pkgs/pull/442614'
        }
    } else {
        $directories = @($content | ConvertFrom-Json)
        if ($directories.Count -ge 1000) { throw 'The winget directory response may be truncated.' }
        $approvedVersions = @($directories | Where-Object { $_.type -eq 'dir' -and $_.name -match '^\d+\.\d+\.\d+$' } | ForEach-Object { $_.name })
        if (@($approvedVersions | Where-Object { [version]$_ -ge [version]$Version }).Count -eq 0) {
            $query = [Uri]::EscapeDataString("repo:microsoft/winget-pkgs is:pr is:open author:Hantu-Raya in:title Nativune.Nativune $Version")
            $search = Get-Resource "https://api.github.com/search/issues?q=$query&per_page=100" | ConvertFrom-Json
            Assert-CompleteSearch $search
            foreach ($item in $search.items) {
                if (-not (Test-VersionTitle $item.title $Version)) { continue }
                $pr = Get-Resource "$api/pulls/$($item.number)" | ConvertFrom-Json
                if (Test-WingetPr $pr $Version) {
                    $targetPrOpen = $true
                    $reviewUrl = $pr.html_url
                    break
                }
            }
        }
    }
} else {
    $reviewUrl = "https://community.chocolatey.org/packages/nativune/$Version"
    $targetPackage = Get-ChocolateyPackage $Version
    if (-not $targetPackage) {
        $filter = [Uri]::EscapeDataString("Id eq 'nativune' and IsLatestVersion")
        $feed = Get-Resource ('https://community.chocolatey.org/api/v2/Packages()?$filter=' + $filter)
        if ($null -eq $feed) { throw 'The Chocolatey approval feed is missing.' }
        $approvedVersions = @(Get-ChocolateyRecords $feed -LatestApproved | ForEach-Object { $_.Version })
        if ($approvedVersions.Count -eq 0) {
            $initial = Get-ChocolateyPackage '0.1.32'
            if ($initial) {
                if ($initial.IsApproved) { $approvedVersions = @($initial.Version) }
                elseif ($initial.PackageStatus -eq 'Submitted') { $initialPending = $true }
                else { throw 'The initial Chocolatey submission requires attention.' }
            }
            $reviewUrl = 'https://community.chocolatey.org/packages/nativune/0.1.32'
        }
    }
}
$state = Get-PackageManagerState -Store $Store -Version $Version -ApprovedVersions $approvedVersions `
    -TargetPackage $targetPackage -InitialPending $initialPending -TargetPrOpen $targetPrOpen
if ($env:GITHUB_OUTPUT) { "state=$state" >> $env:GITHUB_OUTPUT }
if ($state -in 'waiting-first-approval', 'submitted-pending') {
    Write-Output "::warning::$Store $Version is $state; no submission attempted. $reviewUrl"
}
if ($env:GITHUB_STEP_SUMMARY) { "- $Store $Version`: $state $reviewUrl" >> $env:GITHUB_STEP_SUMMARY }
Write-Output $state
