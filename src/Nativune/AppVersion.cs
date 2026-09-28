using System.Reflection;

namespace Nativune;

internal static class AppVersion
{
    internal static string Number { get; } = ReadNumber();
    internal static string DisplayName => $"Nativune {Number}";

    // Owner's Ko-fi page (More > Donate on Ko-fi, Settings > About). Opened in the default browser, never in the WebView.
    internal static readonly Uri DonationUri = new("https://ko-fi.com/hanturaya");
    internal const string DonationFailedMessage =
        "The donation page could not be opened. Visit ko-fi.com/hanturaya in your browser.";

    internal static async Task<bool> TryOpenDonationPageAsync()
    {
        try { return await Windows.System.Launcher.LaunchUriAsync(DonationUri); }
        catch (Exception) { return false; }
    }

    private static string ReadNumber()
    {
        var assembly = typeof(AppVersion).Assembly;
        var informational = assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()
            ?.InformationalVersion;
        if (!string.IsNullOrWhiteSpace(informational))
        {
            var metadata = informational.IndexOf('+', StringComparison.Ordinal);
            return metadata < 0 ? informational : informational[..metadata];
        }

        return assembly.GetName().Version?.ToString(3) ?? "unknown";
    }
}
