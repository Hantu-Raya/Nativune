<#
Fake Discord IPC server for scripts/discord-rpc-e2e.ps1. Standard library only (NamedPipeServerStream).

It listens on one test pipe name (never a real discord-ipc-N name), accepts repeated connections,
answers HANDSHAKE with READY, SET_ACTIVITY with a success response (or one ERROR in
-Mode ErrorOnFirstSet; one ERROR for the first clear in -Mode ErrorOnFirstClear; one ERROR for the first
non-null activity sent after an accepted one in -Mode ErrorOnFirstReplacement), PING with PONG, and
records every frame in both directions as one JSON line:
  {utc, monoMs, direction ("in"|"out"|"event"), connection, opcode, length, json}
It runs until -StopFile exists or the process is killed.

Bench protocol v2 additions (optional, backwards compatible):
  -ReadyFile    written once the first pipe instance exists and is listening (deterministic readiness
                instead of a fixed sleep); contains {utc, qpc, qpcFrequency, pid}.
  -SummaryPath  written at exit: per-connection intervals (connected/READY/disconnected UTC and QPC),
                SET_ACTIVITY counts parsed from `cmd` (non-null activity vs clear), acknowledgements and
                the UTC/QPC of each SET_ACTIVITY. Frame lines also carry `qpc` (Stopwatch.GetTimestamp,
                comparable with the app's diagnostics clock on the same machine).

  pwsh -NoProfile -File scripts/discord-rpc-test-server.ps1 -PipeName nativune-test-<32 hex>-discord-ipc-0 `
       -FramesPath artifacts/discord-rpc/<run>/frames.jsonl -StopFile artifacts/discord-rpc/<run>/stop
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PipeName,
    [Parameter(Mandatory)] [string] $FramesPath,
    [Parameter(Mandatory)] [string] $StopFile,
    [ValidateSet('Normal', 'ErrorOnFirstSet', 'ErrorOnFirstClear', 'ErrorOnFirstReplacement')] [string] $Mode = 'Normal',
    [string] $ReadyFile,
    [string] $SummaryPath
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($PipeName -notmatch '^nativune-test-[0-9a-f]{32}-discord-ipc-\d$') {
    throw 'Refusing a pipe name outside the nativune-test-<32 hex>-discord-ipc-N test namespace.'
}

$OpHandshake = 0; $OpFrame = 1; $OpClose = 2; $OpPing = 3; $OpPong = 4
$MaxFrameBytes = 64 * 1024
$clock = [Diagnostics.Stopwatch]::StartNew()
$utf8 = [Text.UTF8Encoding]::new($false)
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($FramesPath))) | Out-Null
$log = [IO.StreamWriter]::new([IO.Path]::GetFullPath($FramesPath), $true, $utf8)
$log.AutoFlush = $true
$script:errorSent = $false
$script:acceptedActivity = $false
$script:connection = 0
$script:connections = [Collections.Generic.List[object]]::new()
$script:current = $null
$script:sets = [Collections.Generic.List[object]]::new()
$script:acks = 0; $script:errors = 0; $script:unparsedFrames = 0

function Get-Stamp { [ordered]@{ utc = [DateTime]::UtcNow.ToString('o'); qpc = [Diagnostics.Stopwatch]::GetTimestamp() } }

function Write-FrameLog([string] $Direction, [int] $Opcode, [int] $Length, [string] $Json) {
    $entry = [ordered]@{
        utc = [DateTime]::UtcNow.ToString('o'); qpc = [Diagnostics.Stopwatch]::GetTimestamp(); monoMs = $clock.Elapsed.TotalMilliseconds; direction = $Direction
        connection = $script:connection; opcode = $Opcode; length = $Length; json = $Json
    }
    $log.WriteLine(($entry | ConvertTo-Json -Compress -Depth 4))
}

function Read-Exact([IO.Stream] $Stream, [int] $Count) {
    $buffer = [byte[]]::new($Count); $read = 0
    while ($read -lt $Count) {
        $task = $Stream.ReadAsync($buffer, $read, $Count - $read)
        while (-not $task.Wait(250)) { if (Test-Path -LiteralPath $StopFile) { return $null } }
        $n = $task.Result
        if ($n -le 0) { return $null }
        $read += $n
    }
    , $buffer
}

function Send-Frame([IO.Stream] $Stream, [int] $Opcode, [string] $Json) {
    $body = $utf8.GetBytes($Json)
    $frame = [byte[]]::new(8 + $body.Length)
    [BitConverter]::GetBytes([int32] $Opcode).CopyTo($frame, 0)
    [BitConverter]::GetBytes([int32] $body.Length).CopyTo($frame, 4)
    $body.CopyTo($frame, 8)
    $Stream.Write($frame, 0, $frame.Length); $Stream.Flush()
    Write-FrameLog 'out' $Opcode $body.Length $Json
}

function Invoke-Connection([IO.Pipes.NamedPipeServerStream] $Pipe) {
    while ($true) {
        $header = Read-Exact $Pipe 8
        if ($null -eq $header) { return }
        $opcode = [BitConverter]::ToInt32($header, 0); $length = [BitConverter]::ToInt32($header, 4)
        if ($length -lt 0 -or $length -gt $MaxFrameBytes) { Write-FrameLog 'event' $opcode $length 'invalid-length'; return }
        $body = if ($length -gt 0) { Read-Exact $Pipe $length } else { [byte[]]::new(0) }
        if ($null -eq $body) { return }
        $json = $utf8.GetString($body)
        Write-FrameLog 'in' $opcode $length $json
        $message = $null
        try { $message = $json | ConvertFrom-Json -Depth 16 } catch { }
        switch ($opcode) {
            $OpHandshake {
                Send-Frame $Pipe $OpFrame '{"cmd":"DISPATCH","evt":"READY","data":{"v":1,"user":{"id":"0","username":"fixture"}},"nonce":null}'
                if ($script:current -and -not $script:current.ready) { $script:current.ready = Get-Stamp }
            }
            $OpFrame {
                if (-not $message) { $script:unparsedFrames++ }
                if ($message -and $message.PSObject.Properties['cmd'] -and $message.cmd -eq 'SET_ACTIVITY') {
                    $arguments = if ($message.PSObject.Properties['args']) { $message.args } else { $null }
                    $activity = if ($arguments -and $arguments.PSObject.Properties['activity']) { $arguments.activity } else { $null }
                    $stamp = Get-Stamp
                    $script:sets.Add([ordered]@{ connection = $script:connection; kind = if ($null -eq $activity) { 'clear' } else { 'activity' }; utc = $stamp.utc; qpc = $stamp.qpc })
                    $nonce = if ($message.PSObject.Properties['nonce']) { $message.nonce } else { $null }
                    $nonceJson = ConvertTo-Json -InputObject $nonce -Compress
                    $reject = -not $script:errorSent -and ($Mode -eq 'ErrorOnFirstSet' -or
                        ($Mode -eq 'ErrorOnFirstClear' -and $null -eq $activity) -or
                        ($Mode -eq 'ErrorOnFirstReplacement' -and $null -ne $activity -and $script:acceptedActivity))
                    if ($reject) {
                        $script:errorSent = $true
                        Send-Frame $Pipe $OpFrame ('{"cmd":"SET_ACTIVITY","nonce":' + $nonceJson + ',"evt":"ERROR","data":{"code":4000,"message":"fixture"}}')
                        $script:errors++
                    } else {
                        Send-Frame $Pipe $OpFrame ('{"cmd":"SET_ACTIVITY","nonce":' + $nonceJson + ',"evt":null,"data":{}}')
                        $script:acks++
                        if ($null -ne $activity) { $script:acceptedActivity = $true }
                    }
                }
            }
            $OpPing { Send-Frame $Pipe $OpPong $json }
            $OpClose { return }
        }
    }
}

try {
    while (-not (Test-Path -LiteralPath $StopFile)) {
        $pipe = [IO.Pipes.NamedPipeServerStream]::new($PipeName, [IO.Pipes.PipeDirection]::InOut, 1,
            [IO.Pipes.PipeTransmissionMode]::Byte, [IO.Pipes.PipeOptions]::Asynchronous)
        try {
            $wait = $pipe.WaitForConnectionAsync()
            if ($ReadyFile -and -not (Test-Path -LiteralPath $ReadyFile)) {
                $readyPath = [IO.Path]::GetFullPath($ReadyFile)
                $stamp = Get-Stamp
                [IO.File]::WriteAllText($readyPath + '.tmp', ([ordered]@{ utc = $stamp.utc; qpc = $stamp.qpc
                    qpcFrequency = [Diagnostics.Stopwatch]::Frequency; pid = $PID; pipe = $PipeName } | ConvertTo-Json -Compress), $utf8)
                [IO.File]::Move($readyPath + '.tmp', $readyPath, $true)
            }
            while (-not $wait.Wait(250)) { if (Test-Path -LiteralPath $StopFile) { break } }
            if (-not $wait.IsCompleted) { continue }
            $script:connection++
            $script:current = [ordered]@{ connection = $script:connection; connected = Get-Stamp; ready = $null; disconnected = $null; error = $null }
            $script:connections.Add($script:current)
            Write-FrameLog 'event' -1 0 'connected'
            try { Invoke-Connection $pipe } catch { $script:current.error = $_.Exception.GetType().Name; Write-FrameLog 'event' -1 0 ('connection-error: ' + $_.Exception.GetType().Name) }
            $script:current.disconnected = Get-Stamp
            Write-FrameLog 'event' -1 0 'disconnected'
        } finally {
            $pipe.Dispose()
        }
    }
} finally {
    $log.Dispose()
    if ($SummaryPath) {
        $summary = [ordered]@{
            schema = 2; pipe = $PipeName; mode = $Mode; qpcFrequency = [Diagnostics.Stopwatch]::Frequency; stopped = Get-Stamp
            connectionCount = $script:connections.Count; connections = $script:connections
            setActivity = [ordered]@{
                total = $script:sets.Count
                activity = @($script:sets | Where-Object { $_.kind -eq 'activity' }).Count
                clear = @($script:sets | Where-Object { $_.kind -eq 'clear' }).Count
                acks = $script:acks; errors = $script:errors; frames = $script:sets
            }
            unparsedFrames = $script:unparsedFrames
        }
        $summaryPath = [IO.Path]::GetFullPath($SummaryPath)
        [IO.File]::WriteAllText($summaryPath + '.tmp', ($summary | ConvertTo-Json -Depth 8), $utf8)
        [IO.File]::Move($summaryPath + '.tmp', $summaryPath, $true)
    }
}
