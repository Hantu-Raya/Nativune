<#
Fake Discord IPC server for scripts/discord-rpc-e2e.ps1. Standard library only (NamedPipeServerStream).

It listens on one test pipe name (never a real discord-ipc-N name), accepts repeated connections,
answers HANDSHAKE with READY, SET_ACTIVITY with a success response (or one ERROR in
-Mode ErrorOnFirstSet), PING with PONG, and records every frame in both directions as one JSON line:
  {utc, monoMs, direction ("in"|"out"|"event"), connection, opcode, length, json}
It runs until -StopFile exists or the process is killed.

  pwsh -NoProfile -File scripts/discord-rpc-test-server.ps1 -PipeName nativune-test-<32 hex>-discord-ipc-0 `
       -FramesPath artifacts/discord-rpc/<run>/frames.jsonl -StopFile artifacts/discord-rpc/<run>/stop
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PipeName,
    [Parameter(Mandatory)] [string] $FramesPath,
    [Parameter(Mandatory)] [string] $StopFile,
    [ValidateSet('Normal', 'ErrorOnFirstSet')] [string] $Mode = 'Normal'
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
$script:connection = 0

function Write-FrameLog([string] $Direction, [int] $Opcode, [int] $Length, [string] $Json) {
    $entry = [ordered]@{
        utc = [DateTime]::UtcNow.ToString('o'); monoMs = $clock.Elapsed.TotalMilliseconds; direction = $Direction
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
            }
            $OpFrame {
                if ($message -and $message.PSObject.Properties['cmd'] -and $message.cmd -eq 'SET_ACTIVITY') {
                    $nonce = if ($message.PSObject.Properties['nonce']) { $message.nonce } else { $null }
                    $nonceJson = ConvertTo-Json -InputObject $nonce -Compress
                    if ($Mode -eq 'ErrorOnFirstSet' -and -not $script:errorSent) {
                        $script:errorSent = $true
                        Send-Frame $Pipe $OpFrame ('{"cmd":"SET_ACTIVITY","nonce":' + $nonceJson + ',"evt":"ERROR","data":{"code":4000,"message":"fixture"}}')
                    } else {
                        Send-Frame $Pipe $OpFrame ('{"cmd":"SET_ACTIVITY","nonce":' + $nonceJson + ',"evt":null,"data":{}}')
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
            while (-not $wait.Wait(250)) { if (Test-Path -LiteralPath $StopFile) { break } }
            if (-not $wait.IsCompleted) { continue }
            $script:connection++
            Write-FrameLog 'event' -1 0 'connected'
            try { Invoke-Connection $pipe } catch { Write-FrameLog 'event' -1 0 ('connection-error: ' + $_.Exception.GetType().Name) }
            Write-FrameLog 'event' -1 0 'disconnected'
        } finally {
            $pipe.Dispose()
        }
    }
} finally {
    $log.Dispose()
}
