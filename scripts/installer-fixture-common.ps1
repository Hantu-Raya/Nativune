# Dot-sourced by installer fixtures; New-AppendedSetup uses the caller's Assert-RegularFile.
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
