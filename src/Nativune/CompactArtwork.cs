using System.Net;
using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml.Media.Imaging;
using Windows.Storage.Streams;

namespace Nativune;

/// <summary>
/// Bounded artwork loader for the native Compact surface. It intentionally accepts only the
/// existing public artwork origins and decodes bytes through the WinUI native image pipeline.
/// </summary>
internal static class CompactArtwork
{
    private const int MaxBytes = 1024 * 1024;
    private const int MaxDimension = 1024;
    private static readonly HttpClient Client = new(new HttpClientHandler
    {
        AllowAutoRedirect = false,
        UseCookies = false,
        UseDefaultCredentials = false,
        Credentials = null,
        AutomaticDecompression = DecompressionMethods.None,
        MaxResponseHeadersLength = 16
    }) { Timeout = TimeSpan.FromSeconds(3) };

    internal static bool IsAllowedUrl(string? value)
        => value is { Length: > 0 and <= 2048 }
            && Uri.TryCreate(value, UriKind.Absolute, out var uri)
            && uri.Scheme == Uri.UriSchemeHttps && uri.IsDefaultPort && uri.UserInfo.Length == 0
            && uri.Host.ToLowerInvariant() is "lh3.googleusercontent.com" or "i.ytimg.com"
                or "yt3.ggpht.com" or "yt3.googleusercontent.com";

    internal static async Task<BitmapImage?> LoadAsync(string url, CancellationToken cancellation)
    {
        if (!IsAllowedUrl(url)) return null;

        // Start one linked three-second budget before sending headers so the request, body read
        // and native decode share the same deadline.
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation);
        deadline.CancelAfter(TimeSpan.FromSeconds(3));
        using var request = new HttpRequestMessage(HttpMethod.Get, url);
        request.Headers.Accept.ParseAdd("image/jpeg, image/png");
        using var response = await Client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, deadline.Token);
        if (response.StatusCode != HttpStatusCode.OK
            || response.Content.Headers.ContentLength is > MaxBytes
            || response.Content.Headers.ContentType?.MediaType is not ("image/jpeg" or "image/png"))
            return null;

        await using var stream = await response.Content.ReadAsStreamAsync(deadline.Token);
        using var bytes = new MemoryStream(capacity: Math.Min(MaxBytes, 64 * 1024));
        var buffer = new byte[8192];
        while (true)
        {
            var count = await stream.ReadAsync(buffer.AsMemory(), deadline.Token);
            if (count == 0) break;
            if (bytes.Length + count > MaxBytes) return null;
            bytes.Write(buffer, 0, count);
        }

        deadline.Token.ThrowIfCancellationRequested();
        var payload = bytes.ToArray();
        if (!TryReadDimensions(payload, out var width, out var height)) return null;

        // BitmapImage and its decoder are apartment-bound. LoadAsync is normally entered from
        // the native UI thread; when a caller enters elsewhere, enqueue only the decode step.
        var dispatcher = DispatcherQueue.GetForCurrentThread();
        if (dispatcher is null) return null;
        try
        {
            return await DecodeOnDispatcherAsync(payload, width, height, dispatcher, deadline.Token);
        }
        catch (OperationCanceledException)
        {
            throw;
        }
        catch (Exception)
        {
            // Invalid/truncated bytes must not escape as a UI failure. The response has already
            // passed the origin, media-type, signature and dimension gates above.
            return null;
        }
    }

    private static async Task<BitmapImage?> DecodeOnDispatcherAsync(
        byte[] payload, int width, int height, DispatcherQueue dispatcher, CancellationToken cancellation)
    {
        if (dispatcher.HasThreadAccess)
            return await DecodeCoreAsync(payload, width, height, cancellation);

        var completion = new TaskCompletionSource<BitmapImage?>(TaskCreationOptions.RunContinuationsAsynchronously);
        using var registration = cancellation.Register(static state =>
        {
            ((TaskCompletionSource<BitmapImage?>)state!).TrySetCanceled();
        }, completion);
        if (!dispatcher.TryEnqueue(async () =>
        {
            try
            {
                completion.TrySetResult(await DecodeCoreAsync(payload, width, height, cancellation));
            }
            catch (OperationCanceledException)
            {
                completion.TrySetCanceled(cancellation);
            }
            catch (Exception exception)
            {
                completion.TrySetException(exception);
            }
        }))
            return null;

        return await completion.Task;
    }

    private static async Task<BitmapImage?> DecodeCoreAsync(
        byte[] payload, int width, int height, CancellationToken cancellation)
    {
        using var stream = new InMemoryRandomAccessStream();
        using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
        {
            writer.WriteBytes(payload);
            await writer.StoreAsync().AsTask(cancellation);
            await writer.FlushAsync().AsTask(cancellation);
            writer.DetachStream();
        }

        stream.Seek(0);
        var bitmap = new BitmapImage
        {
            DecodePixelWidth = width,
            DecodePixelHeight = height
        };
        await bitmap.SetSourceAsync(stream).AsTask(cancellation);
        cancellation.ThrowIfCancellationRequested();
        return bitmap;
    }

    private static bool TryReadDimensions(ReadOnlySpan<byte> data, out int width, out int height)
    {
        width = height = 0;
        if (data.Length >= 24 && data[..8].SequenceEqual(
                new byte[] { 137, 80, 78, 71, 13, 10, 26, 10 }))
            return TryReadPngDimensions(data, out width, out height);
        return data.Length >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff
            && TryReadJpegDimensions(data, out width, out height);
    }

    private static bool TryReadPngDimensions(ReadOnlySpan<byte> data, out int width, out int height)
    {
        width = height = 0;
        if (data.Length < 33 || ReadUInt32(data, 8) < 13
            || data[12] != (byte)'I' || data[13] != (byte)'H'
            || data[14] != (byte)'D' || data[15] != (byte)'R')
            return false;
        var rawWidth = ReadUInt32(data, 16);
        var rawHeight = ReadUInt32(data, 20);
        if (rawWidth == 0 || rawHeight == 0 || rawWidth > MaxDimension || rawHeight > MaxDimension)
            return false;
        width = (int)rawWidth;
        height = (int)rawHeight;
        return true;
    }

    private static bool TryReadJpegDimensions(ReadOnlySpan<byte> data, out int width, out int height)
    {
        width = height = 0;
        var offset = 2;
        while (offset + 1 < data.Length)
        {
            if (data[offset++] != 0xff) return false;
            while (offset < data.Length && data[offset] == 0xff) offset++;
            if (offset >= data.Length) return false;
            var marker = data[offset++];
            if (marker is 0xd8 or 0xd9 or 0x01) continue;
            if (marker == 0xda) return false; // Start of scan without a preceding SOF.
            if (offset + 2 > data.Length) return false;
            var segmentLength = (data[offset] << 8) | data[offset + 1];
            if (segmentLength < 2 || offset + segmentLength > data.Length) return false;
            if (marker is >= 0xc0 and <= 0xc3 or >= 0xc5 and <= 0xc7
                or >= 0xc9 and <= 0xcb or >= 0xcd and <= 0xcf)
            {
                if (segmentLength < 7) return false;
                height = (data[offset + 3] << 8) | data[offset + 4];
                width = (data[offset + 5] << 8) | data[offset + 6];
                return width > 0 && height > 0 && width <= MaxDimension && height <= MaxDimension;
            }
            offset += segmentLength;
        }
        return false;
    }

    private static uint ReadUInt32(ReadOnlySpan<byte> data, int offset)
        => ((uint)data[offset] << 24) | ((uint)data[offset + 1] << 16)
            | ((uint)data[offset + 2] << 8) | data[offset + 3];
}
