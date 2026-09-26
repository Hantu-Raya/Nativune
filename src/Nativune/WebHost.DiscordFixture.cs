#if NATIVUNE_DISCORD_TEST_HOOKS
using Microsoft.Web.WebView2.Core;
using System.Buffers.Binary;
using System.IO.Compression;
using Windows.Storage.Streams;

namespace Nativune;

// Discord presence E2E seam (contract: .cache/tmp/discord-rpc/contract.md), compiled only with
// -p:DiscordPresenceTestHooks=true. It serves the embedded synthetic Music page for
// scripts/discord-rpc-e2e.ps1 and blocks every other network request, so the fixture never reaches
// YouTube, Google or Discord. It does not change IsMusicUri, host objects or web messages.
public sealed partial class WebHostWindow
{
    private const string DiscordFixtureResourceName = "Nativune.DiscordFixturePage.html";
    private const string DiscordFixtureArtworkHost = "lh3.googleusercontent.com";
    private static byte[]? s_discordFixturePage;

    private void InstallDiscordFixturePage(CoreWebView2 core)
    {
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_FIXTURE_PAGE") != "1") return;
        using (var stream = typeof(WebHostWindow).Assembly.GetManifestResourceStream(DiscordFixtureResourceName)
            ?? throw new InvalidOperationException("The Discord fixture page resource is missing."))
        using (var buffer = new MemoryStream())
        {
            stream.CopyTo(buffer);
            s_discordFixturePage = buffer.ToArray();
        }
        // Only http(s) is intercepted so chrome-extension:// (uBO Lite dashboard/resources) loads normally.
        core.AddWebResourceRequestedFilter("https://*", CoreWebView2WebResourceContext.All);
        core.AddWebResourceRequestedFilter("http://*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += OnDiscordFixtureResourceRequested;
    }

    private static void OnDiscordFixtureResourceRequested(CoreWebView2 sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        Uri? uri = Uri.TryCreate(args.Request.Uri, UriKind.Absolute, out var parsed) ? parsed : null;
        if (uri is not null && uri.Scheme != Uri.UriSchemeHttps && uri.Scheme != Uri.UriSchemeHttp)
            return;
        var https = uri is not null && uri.Scheme == Uri.UriSchemeHttps && uri.IsDefaultPort && uri.UserInfo.Length == 0;
        if (https && uri!.Host.Equals("music.youtube.com", StringComparison.OrdinalIgnoreCase))
        {
            args.Response = args.ResourceContext == CoreWebView2WebResourceContext.Document
                ? DiscordFixtureResponse(sender, s_discordFixturePage!, 200, "OK", "text/html; charset=utf-8")
                : DiscordFixtureResponse(sender, null, 204, "No Content", null);
            return;
        }
        // The reader accepts only loaded artwork from allowed hosts, so the two fixture pictures are
        // generated locally under their allowed URLs; nothing is fetched from Google.
        if (https && uri!.Host.Equals(DiscordFixtureArtworkHost, StringComparison.OrdinalIgnoreCase)
            && args.ResourceContext == CoreWebView2WebResourceContext.Image
            && uri.AbsolutePath is "/fixture-a=w544-h544" or "/fixture-b=w544-h544")
        {
            var png = uri.AbsolutePath.StartsWith("/fixture-a", StringComparison.Ordinal)
                ? DiscordFixturePng(0xE0, 0x3E, 0x52)
                : DiscordFixturePng(0x2E, 0x7D, 0xD7);
            args.Response = DiscordFixtureResponse(sender, png, 200, "OK", "image/png");
            return;
        }
        args.Response = DiscordFixtureResponse(sender, null, 403, "Forbidden", null);
    }

    private static CoreWebView2WebResourceResponse DiscordFixtureResponse(CoreWebView2 core, byte[]? body,
        int status, string reason, string? contentType)
    {
        IRandomAccessStream? content = null;
        if (body is not null)
        {
            var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
            {
                writer.WriteBytes(body);
                writer.StoreAsync().AsTask().GetAwaiter().GetResult();
                writer.FlushAsync().AsTask().GetAwaiter().GetResult();
                writer.DetachStream();
            }
            stream.Seek(0);
            content = stream;
        }
        var headers = "Cache-Control: no-store"
            + (contentType is null ? "" : "\r\nContent-Type: " + contentType);
        return core.Environment.CreateWebResourceResponse(content, status, reason, headers);
    }

    // Solid 64x64 RGB PNG; small enough for every reader size bound.
    private static byte[] DiscordFixturePng(byte red, byte green, byte blue)
    {
        const int size = 64;
        var raw = new byte[size * (1 + size * 3)];
        for (var y = 0; y < size; y++)
        {
            var row = y * (1 + size * 3);
            for (var x = 0; x < size; x++)
            {
                raw[row + 1 + x * 3] = red;
                raw[row + 2 + x * 3] = green;
                raw[row + 3 + x * 3] = blue;
            }
        }
        byte[] compressed;
        using (var buffer = new MemoryStream())
        {
            using (var zlib = new ZLibStream(buffer, CompressionLevel.Optimal, leaveOpen: true)) zlib.Write(raw);
            compressed = buffer.ToArray();
        }
        var header = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(0), size);
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), size);
        header[8] = 8; // bit depth
        header[9] = 2; // truecolour
        using var png = new MemoryStream();
        png.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        WriteDiscordFixtureChunk(png, "IHDR", header);
        WriteDiscordFixtureChunk(png, "IDAT", compressed);
        WriteDiscordFixtureChunk(png, "IEND", []);
        return png.ToArray();
    }

    private static void WriteDiscordFixtureChunk(Stream output, string type, byte[] data)
    {
        Span<byte> number = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(number, data.Length);
        output.Write(number);
        var typeBytes = System.Text.Encoding.ASCII.GetBytes(type);
        output.Write(typeBytes);
        output.Write(data);
        var crc = 0xFFFFFFFFu;
        foreach (var b in typeBytes.Concat(data))
        {
            crc ^= b;
            for (var k = 0; k < 8; k++) crc = (crc & 1) != 0 ? 0xEDB88320u ^ (crc >> 1) : crc >> 1;
        }
        BinaryPrimitives.WriteUInt32BigEndian(number, crc ^ 0xFFFFFFFFu);
        output.Write(number);
    }
}
#endif
