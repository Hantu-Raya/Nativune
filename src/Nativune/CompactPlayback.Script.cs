using System.Text;

namespace Nativune;

// Compact reads also compute action capabilities; presence needs only the observation.
internal enum PlaybackReadMode { Compact, Presence }

internal static partial class CompactPlayback
{
    private const string CompactOnlyBegin = "// @compact-only-begin";
    private const string CompactOnlyEnd = "// @compact-only-end";

    // The presence read is the Compact script with its marked action-only regions removed (like,
    // dislike and shuffle scans, seek hit-target geometry, ready/playlist/command code). Every guard,
    // acquisition, clock, artwork and details helper is the same source text, re-checked per call.
    private static readonly string PresenceJavaScript = StripCompactOnly(CompactJavaScript);

    internal static string BuildStateScript(PlaybackReadMode mode, string href, long notAfterUnixMs)
        => ComposeScript(mode == PlaybackReadMode.Presence ? PresenceJavaScript : CompactJavaScript,
            "state", null, href, notAfterUnixMs, null, null);

    private static string StripCompactOnly(string source)
    {
        var builder = new StringBuilder(source.Length);
        var skipping = false;
        foreach (var rawLine in source.Split('\n'))
        {
            var marker = rawLine.Trim();
            if (marker == CompactOnlyBegin)
            {
                if (skipping) throw new InvalidOperationException("Nested compact-only region.");
                skipping = true;
                continue;
            }
            if (marker == CompactOnlyEnd)
            {
                if (!skipping) throw new InvalidOperationException("Unopened compact-only region.");
                skipping = false;
                continue;
            }
            if (!skipping) builder.Append(rawLine).Append('\n');
        }
        if (skipping) throw new InvalidOperationException("Unclosed compact-only region.");
        return builder.ToString().TrimEnd('\n');
    }
}
