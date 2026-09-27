using System.Text.Json;
using Microsoft.Web.WebView2.Core;

namespace Nativune;

internal enum BrowserLyricsStatus
{
    Disabled,
    Installed,
    Missing,
    Failed
}

// Outcome of the optional lyrics setup. Category is a fixed word, never page or song data.
internal sealed record BrowserLyricsState(BrowserLyricsStatus Status, string? Version = null, string? Category = null)
{
    internal static BrowserLyricsState Disabled { get; } = new(BrowserLyricsStatus.Disabled);
    internal static BrowserLyricsState Missing { get; } = new(BrowserLyricsStatus.Missing);
    internal static BrowserLyricsState Installed(string version) => new(BrowserLyricsStatus.Installed, version);
    internal static BrowserLyricsState Failed(string category) => new(BrowserLyricsStatus.Failed, Category: category);
    internal bool IsInstalled => Status == BrowserLyricsStatus.Installed;
}

// Barebones Better Lyrics (GPL-3.0 fork of Better Lyrics 2.4.1), opt-in and off by default.
// Lyrics problems never throw to the caller: Music and uBO Lite setup continue regardless.
internal static class BrowserLyrics
{
    internal const string ExtensionName = "Barebones Better Lyrics";
    internal const string ExtensionVersion = "2.4.1.1";
    internal const string ExpectedExtensionId = "ogodmldcmpbfeekmejkeppchklblochl";
    private const long MaxManifestBytes = 256 * 1024;
    private static readonly TimeSpan ExtensionOperationTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ConfigurationTimeout = TimeSpan.FromSeconds(45);
    private static readonly TimeSpan CleanupTimeout = TimeSpan.FromSeconds(5);

    internal static async Task<BrowserLyricsState> ConfigureAsync(
        CoreWebView2 core,
        string projectRoot,
        bool enabled,
        CancellationToken token)
    {
        if (core is null || string.IsNullOrWhiteSpace(projectRoot))
            return BrowserLyricsState.Failed("arguments");

        using var configurationCancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
        configurationCancellation.CancelAfter(ConfigurationTimeout);
        var operationToken = configurationCancellation.Token;

        if (!enabled)
        {
            try
            {
                await DisableExpectedAsync(core, operationToken);
            }
            catch (Exception exception)
            {
                AppLog.Write("lyrics", "disable-failed " + exception.GetType().Name);
            }
            return BrowserLyricsState.Disabled;
        }

        string directory;
        try
        {
            directory = Path.Combine(projectRoot, ".tools", "better-lyrics", ExtensionVersion);
            if (!File.Exists(Path.Combine(directory, "manifest.json")))
            {
                AppLog.Write("lyrics", "missing");
                await TryDisableAfterFailureAsync(core, token);
                return BrowserLyricsState.Missing;
            }
            RootLocator.EnsureNoReparseTree(projectRoot, directory);
            var manifest = Path.Combine(directory, "manifest.json");
            RootLocator.EnsureRegularFile(projectRoot, manifest);
            if (!ManifestMatches(manifest))
            {
                AppLog.Write("lyrics", "failed manifest");
                await TryDisableAfterFailureAsync(core, token);
                return BrowserLyricsState.Failed("manifest");
            }
        }
        catch (Exception exception)
        {
            AppLog.Write("lyrics", "failed payload " + exception.GetType().Name);
            await TryDisableAfterFailureAsync(core, token);
            return BrowserLyricsState.Failed("payload");
        }

        try
        {
            var installed = await BrowserPrivacy.AwaitBoundedAsync(
                core.Profile.GetBrowserExtensionsAsync().AsTask(), ExtensionOperationTimeout, operationToken);
            var extension = installed.FirstOrDefault(candidate =>
                string.Equals(candidate.Id, ExpectedExtensionId, StringComparison.Ordinal));
            if (extension is null)
            {
                extension = await BrowserPrivacy.AwaitBoundedAsync(
                    core.Profile.AddBrowserExtensionAsync(directory).AsTask(), ExtensionOperationTimeout, operationToken);
                operationToken.ThrowIfCancellationRequested();
            }
            if (!string.Equals(extension.Id, ExpectedExtensionId, StringComparison.Ordinal))
            {
                AppLog.Write("lyrics", "failed id");
                await TryDisableOrRemoveAsync(extension, token);
                await TryDisableAfterFailureAsync(core, token);
                return BrowserLyricsState.Failed("id");
            }
            if (!extension.IsEnabled)
            {
                await BrowserPrivacy.AwaitBoundedAsync(
                    extension.EnableAsync(true).AsTask(), ExtensionOperationTimeout, operationToken);
                operationToken.ThrowIfCancellationRequested();
            }
            if (!extension.IsEnabled)
            {
                AppLog.Write("lyrics", "failed enable");
                await TryDisableAfterFailureAsync(core, token);
                return BrowserLyricsState.Failed("enable");
            }

            foreach (var stale in installed.Where(candidate =>
                string.Equals(candidate.Name, ExtensionName, StringComparison.Ordinal)
                && !string.Equals(candidate.Id, ExpectedExtensionId, StringComparison.Ordinal)))
            {
                await TryDisableOrRemoveAsync(stale, operationToken);
            }

            AppLog.Write("lyrics", "installed " + ExtensionVersion);
            return BrowserLyricsState.Installed(ExtensionVersion);
        }
        catch (Exception exception)
        {
            var category = exception is OperationCanceledException or TimeoutException ? "timeout" : "extension";
            AppLog.Write("lyrics", "failed " + category + " " + exception.GetType().Name);
            await TryDisableAfterFailureAsync(core, token);
            return BrowserLyricsState.Failed(category);
        }
    }

    // Disables the expected extension only; uBO Lite and anything else is left alone. Never throws.
    internal static async Task DisableNowAsync(CoreWebView2 core, CancellationToken token)
    {
        try
        {
            using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
            cancellation.CancelAfter(ConfigurationTimeout);
            await DisableExpectedAsync(core, cancellation.Token);
            AppLog.Write("lyrics", "disabled");
        }
        catch (Exception exception)
        {
            AppLog.Write("lyrics", "disable-failed " + exception.GetType().Name);
        }
    }

    private static async Task DisableExpectedAsync(CoreWebView2 core, CancellationToken operationToken)
    {
        var installed = await BrowserPrivacy.AwaitBoundedAsync(
            core.Profile.GetBrowserExtensionsAsync().AsTask(), ExtensionOperationTimeout, operationToken);
        foreach (var extension in installed.Where(candidate =>
            string.Equals(candidate.Id, ExpectedExtensionId, StringComparison.Ordinal) && candidate.IsEnabled))
        {
            await BrowserPrivacy.AwaitBoundedAsync(
                extension.EnableAsync(false).AsTask(), ExtensionOperationTimeout, operationToken);
        }
    }

    private static async Task TryDisableAfterFailureAsync(CoreWebView2 core, CancellationToken token)
    {
        try
        {
            using var cleanup = CancellationTokenSource.CreateLinkedTokenSource(token);
            cleanup.CancelAfter(CleanupTimeout);
            await DisableExpectedAsync(core, cleanup.Token);
        }
        catch (Exception exception)
        {
            AppLog.Write("lyrics", "cleanup-failed " + exception.GetType().Name);
        }
    }

    private static async Task TryDisableOrRemoveAsync(CoreWebView2BrowserExtension extension, CancellationToken token)
    {
        try
        {
            if (extension.IsEnabled)
                await BrowserPrivacy.AwaitBoundedAsync(extension.EnableAsync(false).AsTask(), CleanupTimeout, token);
            await BrowserPrivacy.AwaitBoundedAsync(extension.RemoveAsync().AsTask(), CleanupTimeout, token);
        }
        catch (Exception exception)
        {
            AppLog.Write("lyrics", "stale-cleanup-failed " + exception.GetType().Name);
        }
    }

    private static bool ManifestMatches(string path)
    {
        if (new FileInfo(path).Length > MaxManifestBytes) return false;
        using var document = JsonDocument.Parse(File.ReadAllBytes(path));
        var root = document.RootElement;
        return root.ValueKind == JsonValueKind.Object
            && root.TryGetProperty("name", out var name) && name.ValueKind == JsonValueKind.String
            && string.Equals(name.GetString(), ExtensionName, StringComparison.Ordinal)
            && root.TryGetProperty("version", out var version) && version.ValueKind == JsonValueKind.String
            && string.Equals(version.GetString(), ExtensionVersion, StringComparison.Ordinal);
    }
}
