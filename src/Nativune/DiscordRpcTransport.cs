using System.Buffers;
using System.Buffers.Binary;
using System.IO.Pipes;
using System.Text.Json;
using System.Threading.Channels;

namespace Nativune;

/// <summary>
/// Discord local IPC transport: pipe discovery/handshake, framing and limits, serialized writer, reader loop
/// with PING/PONG, and the SET_ACTIVITY envelope. Owns pipe I/O, deadlines and disposal only; never sets
/// presence status, touches the presence gate or decides what to publish. Never logs frames or content.
/// </summary>
internal static class DiscordRpcTransport
{
    private const string LogCategory = "discord";
    private const int OpHandshake = 0, OpFrame = 1, OpClose = 2, OpPing = 3, OpPong = 4;
    private const int MaxFrameBytes = 64 * 1024;
    private const int MaxJsonDepth = 16;
    internal const int PipeCount = 10;
    private const int ConnectTimeoutMs = 250;
    private const int ReadyTimeoutMs = 2000;
    private const int PassDeadlineMs = 5000;
    private const int FrameCompletionMs = 5000;
    private const int WriteDeadlineMs = 1000;
    private static readonly JsonDocumentOptions ParseOptions = new() { MaxDepth = MaxJsonDepth };

    // ---------- Discovery and handshake ----------

    internal static async Task<(Connection? Connection, bool ProtocolFailure, int Index)> DiscoverAsync(string applicationId, string pipePrefix, int preferred, CancellationToken ct)
    {
        var passStart = Environment.TickCount64;
        var protocolFailure = false;
        var failedIndex = preferred;
        for (var step = 0; step < PipeCount; step++)
        {
            var remaining = PassDeadlineMs - (int)(Environment.TickCount64 - passStart);
            if (remaining <= 0) break;
            ct.ThrowIfCancellationRequested();
            var index = (preferred + step) % PipeCount;
            var pipe = new NamedPipeClientStream(".", $"{pipePrefix}{index}", PipeDirection.InOut, PipeOptions.Asynchronous);
            try
            {
                await pipe.ConnectAsync(Math.Min(ConnectTimeoutMs, remaining), ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { await pipe.DisposeAsync().ConfigureAwait(false); throw; }
            catch (Exception) { await pipe.DisposeAsync().ConfigureAwait(false); continue; } // absent, busy or timed out

            var connection = new Connection(pipe);
            try
            {
                remaining = PassDeadlineMs - (int)(Environment.TickCount64 - passStart);
                using var readyCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
                readyCts.CancelAfter(Math.Max(1, Math.Min(ReadyTimeoutMs, remaining)));
                var handshake = BuildHandshake(applicationId);
                await connection.WriteAsync(OpHandshake, handshake, readyCts.Token).ConfigureAwait(false);
                while (true)
                {
                    var (op, body) = await ReadFrameAsync(pipe, readyCts.Token).ConfigureAwait(false);
                    if (op == OpPing) { await connection.WriteAsync(OpPong, body, readyCts.Token).ConfigureAwait(false); continue; }
                    if (op == OpPong) continue;
                    if (op != OpFrame) throw new ProtocolException(); // CLOSE (e.g. invalid client id) or handshake reply
                    using var doc = JsonDocument.Parse(body, ParseOptions);
                    if (GetString(doc.RootElement, "cmd") == "DISPATCH" && GetString(doc.RootElement, "evt") == "READY")
                        return (connection, false, index); // READY user data is discarded unread
                }
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                await connection.DisposeAsync().ConfigureAwait(false);
                throw;
            }
            catch (Exception)
            {
                // Timeout, EOF, malformed frame or CLOSE: move past this endpoint.
                protocolFailure = true;
                failedIndex = index;
                await connection.DisposeAsync().ConfigureAwait(false);
            }
        }
        return (null, protocolFailure, failedIndex);
    }

    // Exact reads across partial reads. Idle waits have no periodic wakeups; once the first header byte
    // arrives the rest of the frame must follow within 5 s. Lengths are checked before allocating.
    private static async Task<(int Op, byte[] Body)> ReadFrameAsync(Stream stream, CancellationToken ct)
    {
        var header = new byte[8];
        var first = await stream.ReadAsync(header.AsMemory(0, 1), ct).ConfigureAwait(false);
        if (first == 0) throw new EndOfStreamException();
        using var frameCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
        frameCts.CancelAfter(FrameCompletionMs);
        await stream.ReadExactlyAsync(header.AsMemory(1, 7), frameCts.Token).ConfigureAwait(false);
        var op = BinaryPrimitives.ReadInt32LittleEndian(header);
        var length = BinaryPrimitives.ReadInt32LittleEndian(header.AsSpan(4));
        if (op is < OpHandshake or > OpPong || length < 0 || length > MaxFrameBytes) throw new ProtocolException();
        var body = length == 0 ? Array.Empty<byte>() : new byte[length];
        if (length > 0) await stream.ReadExactlyAsync(body, frameCts.Token).ConfigureAwait(false);
        return (op, body);
    }

    private static string? GetString(JsonElement element, string name)
        => element.ValueKind == JsonValueKind.Object && element.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String
            ? value.GetString() : null;

    private static byte[] BuildHandshake(string clientId)
    {
        var buffer = new ArrayBufferWriter<byte>(64);
        using (var w = new Utf8JsonWriter(buffer))
        {
            w.WriteStartObject();
            w.WriteNumber("v", 1);
            w.WriteString("client_id", clientId);
            w.WriteEndObject();
        }
        return buffer.WrittenSpan.ToArray();
    }

    // ---------- Types ----------

    internal enum IncomingKind { Ack, Lost, Protocol }

    internal readonly record struct Incoming(IncomingKind Kind, string? Nonce, bool Error);

    private sealed class ProtocolException : Exception;

    // One serialized writer with a 1 s deadline per frame (shared by the publish loop and PONG replies).
    internal sealed class Connection(NamedPipeClientStream stream) : IAsyncDisposable
    {
        private readonly SemaphoreSlim _writeLock = new(1, 1);
        private int _disposed;

        internal async Task WriteAsync(int op, ReadOnlyMemory<byte> body, CancellationToken ct)
        {
            if (body.Length > MaxFrameBytes) throw new ProtocolException();
            var frame = new byte[8 + body.Length];
            BinaryPrimitives.WriteInt32LittleEndian(frame, op);
            BinaryPrimitives.WriteInt32LittleEndian(frame.AsSpan(4), body.Length);
            body.Span.CopyTo(frame.AsSpan(8));
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            cts.CancelAfter(WriteDeadlineMs);
            await _writeLock.WaitAsync(cts.Token).ConfigureAwait(false);
            try
            {
                await stream.WriteAsync(frame, cts.Token).ConfigureAwait(false);
                await stream.FlushAsync(cts.Token).ConfigureAwait(false);
            }
            finally
            {
                _writeLock.Release();
            }
        }

        // Writes SET_ACTIVITY; returns the nonce, or null when the write failed (connection unusable).
        internal async Task<string?> SendActivityAsync(string? activityJson, int processId, CancellationToken ct)
        {
            var nonce = Guid.NewGuid().ToString("N");
            var buffer = new ArrayBufferWriter<byte>(activityJson is null ? 256 : activityJson.Length + 256);
            using (var w = new Utf8JsonWriter(buffer))
            {
                w.WriteStartObject();
                w.WriteString("cmd", "SET_ACTIVITY");
                w.WriteStartObject("args");
                w.WriteNumber("pid", processId);
                w.WritePropertyName("activity");
                if (activityJson is null) w.WriteNullValue();
                else w.WriteRawValue(activityJson, skipInputValidation: true);
                w.WriteEndObject();
                w.WriteString("nonce", nonce);
                w.WriteEndObject();
            }
            try
            {
                await WriteAsync(OpFrame, buffer.WrittenMemory, ct).ConfigureAwait(false);
                return nonce;
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested) { throw; }
            catch (Exception)
            {
                AppLog.Write(LogCategory, "discord: write failed");
                return null;
            }
        }

        // Emits Ack for SET_ACTIVITY replies, services PING, and always ends with one Lost/Protocol item.
        internal async Task ReadLoopAsync(ChannelWriter<Incoming> output, CancellationToken ct)
        {
            var result = new Incoming(IncomingKind.Lost, null, false);
            try
            {
                while (true)
                {
                    var (op, body) = await ReadFrameAsync(stream, ct).ConfigureAwait(false);
                    switch (op)
                    {
                        case OpPing:
                            await WriteAsync(OpPong, body, ct).ConfigureAwait(false);
                            break;
                        case OpPong:
                            break;
                        case OpClose:
                            return;
                        case OpFrame:
                            using (var doc = JsonDocument.Parse(body, ParseOptions))
                            {
                                var root = doc.RootElement;
                                if (root.ValueKind == JsonValueKind.Object && GetString(root, "cmd") == "SET_ACTIVITY")
                                    await output.WriteAsync(new Incoming(IncomingKind.Ack, GetString(root, "nonce"), GetString(root, "evt") == "ERROR"), ct).ConfigureAwait(false);
                            }
                            break; // other dispatches (and their content) are discarded
                        default:
                            throw new ProtocolException();
                    }
                }
            }
            catch (ProtocolException) { result = new Incoming(IncomingKind.Protocol, null, false); }
            catch (JsonException) { result = new Incoming(IncomingKind.Protocol, null, false); }
            catch (Exception) { }
            finally
            {
                output.TryWrite(result);
                output.TryComplete();
            }
        }

        public async ValueTask DisposeAsync()
        {
            if (Interlocked.Exchange(ref _disposed, 1) != 0) return;
            try { await stream.DisposeAsync().ConfigureAwait(false); } catch (Exception) { }
        }
    }
}
