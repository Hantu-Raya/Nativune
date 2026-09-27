using System.Buffers;
using System.Text;
using System.Text.Json;

namespace Nativune;

/// <summary>
/// Stateless Discord activity renderer: normalized SET_ACTIVITY activity JSON from an observation, options,
/// effective artwork and anchor. No clock reads, IPC, logging or options mutation.
/// </summary>
internal static class DiscordActivity
{
    private const int MaxTextChars = 128, MaxTextBytes = 128, MaxLinkChars = 512;
    private const string ButtonLabel = "Open in YouTube Music";
    private const string FallbackLargeImage = "nativune";
    // Discord rejects the whole SET_ACTIVITY when large_image is too long (the Social SDK documents 300
    // characters); longer artwork URLs fall back to the app asset. 256 leaves margin.
    private const int MaxLargeImageChars = 256;
    private const string RepositoryUrl = "https://github.com/Hantu-Raya/Nativune"; // fixed constant, not page data
    // App hover captions: immutable for the process, so normalized once.
    private static readonly string? LargeTextWithAuthor = NormalizeText(AppVersion.DisplayName + " · by Hantu-Raya", "");
    private static readonly string? LargeTextAppOnly = NormalizeText(AppVersion.DisplayName, "");

    internal static string? BuildActivityJson(DiscordTrackObservation o, DiscordPresenceOptions options, string? artwork, DateTimeOffset? start, double durationSeconds)
    {
        var details = NormalizeText(o.Title, "Track: ");
        if (details is null) return null; // a missing title clears rather than manufacturing a song
        var state = NormalizeText(o.Artist, "Artist: ");
        var trackUrl = IsAllowedMusicLink(o.TrackUrl) ? o.TrackUrl : null;
        var artistUrl = state is not null && IsAllowedMusicLink(o.ArtistUrl) ? o.ArtistUrl : null;
        var largeText = options.ShowAuthor ? LargeTextWithAuthor : LargeTextAppOnly;
        var displayType = options.StatusLine switch
        {
            DiscordStatusLine.Title => 2,
            DiscordStatusLine.AppName => 0,
            _ => state is null ? 0 : 1
        };

        var buffer = new ArrayBufferWriter<byte>(1024);
        using (var w = new Utf8JsonWriter(buffer))
        {
            w.WriteStartObject();
            w.WriteNumber("type", 2);
            w.WriteNumber("status_display_type", displayType);
            w.WriteString("details", details);
            if (trackUrl is not null) w.WriteString("details_url", trackUrl);
            if (state is not null) w.WriteString("state", state);
            if (artistUrl is not null) w.WriteString("state_url", artistUrl);
            if (start is DateTimeOffset s && durationSeconds > 0)
            {
                w.WriteStartObject("timestamps");
                w.WriteNumber("start", ToDiscordWireTimestamp(s));
                w.WriteNumber("end", ToDiscordWireTimestamp(s + TimeSpan.FromSeconds(durationSeconds)));
                w.WriteEndObject();
            }
            w.WriteStartObject("assets");
            w.WriteString("large_image", artwork is { Length: <= MaxLargeImageChars } ? artwork : FallbackLargeImage);
            if (largeText is not null) w.WriteString("large_text", largeText);
            w.WriteString("large_url", RepositoryUrl);
            if (o.Paused)
            {
                w.WriteString("small_image", "pause");
                w.WriteString("small_text", "Paused");
            }
            else if (o.RepeatOne)
            {
                w.WriteString("small_image", "repeat-one");
                w.WriteString("small_text", "Repeat one");
            }
            w.WriteEndObject();
            if (options.ShowOpenButton && trackUrl is not null)
            {
                w.WriteStartArray("buttons");
                w.WriteStartObject();
                w.WriteString("label", ButtonLabel);
                w.WriteString("url", trackUrl);
                w.WriteEndObject();
                w.WriteEndArray();
            }
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(buffer.WrittenSpan);
    }

    // Single place that decides Discord's wire time unit. Unix seconds per the current RPC example;
    // unverified against the real client (release prerequisite).
    internal static long ToDiscordWireTimestamp(DateTimeOffset instant) => instant.ToUnixTimeSeconds();

    // Trim, collapse whitespace, drop control characters and invalid UTF-16; 2..128 chars and <= 128 UTF-8
    // bytes without splitting surrogate pairs. A genuine 1-character value gets a readable role prefix.
    internal static string? NormalizeText(string? raw, string rolePrefix)
    {
        if (string.IsNullOrEmpty(raw)) return null;
        var cleaned = Clean(raw);
        if (cleaned.Length == 0) return null;
        if (cleaned.EnumerateRunes().Count() < 2) cleaned = rolePrefix + cleaned;

        var sb = new StringBuilder(Math.Min(cleaned.Length, MaxTextChars));
        var bytes = 0;
        foreach (var rune in cleaned.EnumerateRunes())
        {
            if (sb.Length + rune.Utf16SequenceLength > MaxTextChars || bytes + rune.Utf8SequenceLength > MaxTextBytes) break;
            sb.Append(rune.ToString());
            bytes += rune.Utf8SequenceLength;
        }
        var result = sb.ToString().TrimEnd();
        return result.Length >= 2 ? result : null;

        static string Clean(string value)
        {
            var sb = new StringBuilder(Math.Min(value.Length, 1024));
            var pendingSpace = false;
            var index = 0;
            while (index < value.Length && sb.Length < 1024)
            {
                if (Rune.DecodeFromUtf16(value.AsSpan(index), out var rune, out var consumed) != OperationStatus.Done)
                {
                    index += Math.Max(consumed, 1); // drop lone surrogates
                    continue;
                }
                index += consumed;
                if (Rune.IsWhiteSpace(rune)) { pendingSpace = sb.Length > 0; continue; }
                if (Rune.IsControl(rune)) continue;
                var category = Rune.GetUnicodeCategory(rune);
                if (category is System.Globalization.UnicodeCategory.LineSeparator or System.Globalization.UnicodeCategory.ParagraphSeparator) continue;
                if (pendingSpace) { sb.Append(' '); pendingSpace = false; }
                sb.Append(rune.ToString());
            }
            return sb.ToString();
        }
    }

    // Absolute https://music.youtube.com (default port, no userinfo/fragment) with /watch?v=<11> or
    // /channel/<id> or /browse/<id>. Never truncated or rewritten.
    internal static bool IsAllowedMusicLink(string? value)
    {
        if (value is not { Length: > 0 and <= MaxLinkChars } || value.Contains('#')) return false;
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)) return false;
        if (uri.Scheme != Uri.UriSchemeHttps || !uri.IsDefaultPort || uri.UserInfo.Length != 0 || uri.Fragment.Length != 0) return false;
        if (!string.Equals(uri.Host, "music.youtube.com", StringComparison.OrdinalIgnoreCase)) return false;
        var path = uri.AbsolutePath;
        var query = uri.Query;
        if (path == "/watch")
            return query.Length == 14 && query.StartsWith("?v=", StringComparison.Ordinal) && IsIdChars(query.AsSpan(3), 11, 11);
        if (query.Length != 0) return false;
        if (path.StartsWith("/channel/", StringComparison.Ordinal)) return IsIdChars(path.AsSpan(9), 1, 128);
        if (path.StartsWith("/browse/", StringComparison.Ordinal)) return IsIdChars(path.AsSpan(8), 1, 128);
        return false;

        static bool IsIdChars(ReadOnlySpan<char> id, int min, int max)
        {
            if (id.Length < min || id.Length > max) return false;
            foreach (var c in id)
                if (!(char.IsAsciiLetterOrDigit(c) || c is '-' or '_')) return false;
            return true;
        }
    }
}
