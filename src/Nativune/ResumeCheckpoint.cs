using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text.Json;

namespace Nativune;

internal sealed record ResumeCheckpoint(int Version, string VideoId, string? ListId,
    double PositionSeconds, double DurationSeconds, bool Ended)
{
    internal const double MaximumSeconds = 7 * 24 * 60 * 60;
    internal static bool ValidId(string? id) => id is { Length: 11 } && id.All(IdCharacter);
    private static bool IdCharacter(char c) => char.IsAsciiLetterOrDigit(c) || c is '_' or '-';
    internal static string? SafeList(string? id) => id is { Length: > 0 and <= 128 }
        && !id.StartsWith("RD", StringComparison.Ordinal) && id.All(IdCharacter) ? id : null;
    internal bool Valid => Version == 1 && ValidId(VideoId)
        && (ListId is null || ListId is { Length: > 0 and <= 128 } && ListId.All(IdCharacter))
        && double.IsFinite(PositionSeconds) && double.IsFinite(DurationSeconds)
        && DurationSeconds is > 0 and <= MaximumSeconds && PositionSeconds >= 0 && PositionSeconds <= DurationSeconds;
    internal bool MustPause => Ended || DurationSeconds - PositionSeconds <= 3;
    internal string StartupUri => "https://music.youtube.com/watch?v=" + VideoId
        + (SafeList(ListId) is { } list ? "&list=" + list : "")
        + (PositionSeconds < 1 ? "" : "&t=" + Math.Floor(PositionSeconds).ToString(CultureInfo.InvariantCulture));
}

// One store per owned browser; the gate also serializes deletion against an in-flight atomic write.
internal sealed class ResumeCheckpointStore(string root)
{
    private const int MaximumBytes = 4096;
    private static readonly JsonSerializerOptions JsonOptions = new(JsonSerializerDefaults.Web) { MaxDepth = 4 };
    private readonly string _path = Path.Combine(Path.GetFullPath(root), "data", "resume.dat");
    private readonly SemaphoreSlim _gate = new(1, 1);

    internal ResumeCheckpoint? Load(out bool invalid)
    {
        invalid = false;
        try
        {
            using var stream = new FileStream(_path, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (stream.Length is <= 0 or > MaximumBytes) { invalid = true; return null; }
            var protectedBytes = new byte[checked((int)stream.Length)];
            stream.ReadExactly(protectedBytes);
            var bytes = ProtectForCurrentUser(protectedBytes, encrypt: false);
            try
            {
                if (bytes.Length > MaximumBytes) { invalid = true; return null; }
                var checkpoint = JsonSerializer.Deserialize<ResumeCheckpoint>(bytes, JsonOptions);
                if (checkpoint?.Valid == true) return checkpoint with { ListId = ResumeCheckpoint.SafeList(checkpoint.ListId) };
            }
            finally { CryptographicOperations.ZeroMemory(bytes); }
        }
        catch (FileNotFoundException) { return null; }
        catch (DirectoryNotFoundException) { return null; }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or CryptographicException or JsonException)
        {
            // The caller reports a fixed message; never log listening information or filesystem paths.
        }
        invalid = true;
        return null;
    }

    internal async Task SaveAsync(ResumeCheckpoint checkpoint, CancellationToken token)
    {
        if (!checkpoint.Valid) return;
        await _gate.WaitAsync(token);
        var temporary = _path + ".tmp";
        try
        {
            var bytes = JsonSerializer.SerializeToUtf8Bytes(checkpoint, JsonOptions);
            byte[] protectedBytes;
            try { protectedBytes = ProtectForCurrentUser(bytes, encrypt: true); }
            finally { CryptographicOperations.ZeroMemory(bytes); }
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            await using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None,
                4096, FileOptions.Asynchronous | FileOptions.WriteThrough))
            {
                await stream.WriteAsync(protectedBytes, token);
                await stream.FlushAsync(token);
            }
            token.ThrowIfCancellationRequested();
            File.Move(temporary, _path, overwrite: true);
        }
        finally
        {
            try { File.Delete(temporary); } catch (IOException) { } catch (UnauthorizedAccessException) { }
            _gate.Release();
        }
    }

    internal async Task DeleteAsync(CancellationToken token)
    {
        await _gate.WaitAsync(token);
        try { File.Delete(_path); }
        finally { _gate.Release(); }
    }

    // crypt32 defaults to CurrentUser. UI_FORBIDDEN prevents a protection failure from opening OS prompts;
    // deliberately never set CRYPTPROTECT_LOCAL_MACHINE. All input/output allocations stay bounded and are wiped.
    private static byte[] ProtectForCurrentUser(byte[] bytes, bool encrypt)
    {
        if (bytes.Length is <= 0 or > MaximumBytes) throw new CryptographicException("resume-size");
        var input = new DataBlob { Length = bytes.Length, Data = Marshal.AllocHGlobal(bytes.Length) };
        var output = default(DataBlob);
        nint description = 0;
        try
        {
            Marshal.Copy(bytes, 0, input.Data, bytes.Length);
            var success = encrypt
                ? CryptProtectData(ref input, 0, 0, 0, 0, 1, out output)
                : CryptUnprotectData(ref input, out description, 0, 0, 0, 1, out output);
            if (!success || output.Data == 0 || output.Length is <= 0 or > MaximumBytes)
                throw new CryptographicException("resume-protection");
            var result = new byte[output.Length];
            Marshal.Copy(output.Data, result, 0, result.Length);
            return result;
        }
        finally
        {
            for (var index = 0; index < input.Length; index++) Marshal.WriteByte(input.Data, index, 0);
            Marshal.FreeHGlobal(input.Data);
            if (output.Data != 0)
            {
                if (output.Length is > 0 and <= MaximumBytes)
                    for (var index = 0; index < output.Length; index++) Marshal.WriteByte(output.Data, index, 0);
                _ = LocalFree(output.Data);
            }
            if (description != 0) _ = LocalFree(description);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Length;
        public nint Data;
    }

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptProtectData(ref DataBlob input, nint description, nint entropy,
        nint reserved, nint prompt, uint flags, out DataBlob output);

    [DllImport("crypt32.dll", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CryptUnprotectData(ref DataBlob input, out nint description, nint entropy,
        nint reserved, nint prompt, uint flags, out DataBlob output);

    [DllImport("kernel32.dll", ExactSpelling = true, SetLastError = true)]
    private static extern nint LocalFree(nint memory);
}
