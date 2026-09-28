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
// Lyrics problems never throw while Lyrics is on, so Music and uBO Lite continue. While it is off, a copy that
// cannot be confirmed disabled or removed throws, so Music is not loaded (fail closed, like uBO Lite).
internal static class BrowserLyrics
{
    internal const string ExtensionName = "Barebones Better Lyrics";
    internal const string ExtensionVersion = "2.4.1.2";
    private const string InstalledVersionFile = "better-lyrics-extension.version";
    private const string PendingPrefix = "pending ";
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
            // Off must mean nothing is sent: confirm disabled, else remove it, else fail closed before Music loads.
            try
            {
                await DisableExpectedAsync(core, operationToken);
            }
            catch (Exception exception)
            {
                AppLog.Write("lyrics", "disable-failed " + exception.GetType().Name);
                await RemoveExpectedAsync(core, token);
                AppLog.Write("lyrics", "removed");
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
            // Chromium keeps serving an unpacked extension from the directory it was added from, and the ID is the same
            // across bundle versions. Without a record of this version, remove the old copy (losing its saved
            // settings) and add the bundled directory. Before the removal the record is set to "pending <version>",
            // which never matches: a removal or add that fails is retried next launch instead of the old copy being
            // taken for the new version. If even that write fails, removing now would repeat on every launch and wipe
            // the settings each time, so the existing copy is kept (disabled) and the failure is surfaced instead.
            var recordCurrent = string.Equals(ReadRecordedVersion(projectRoot), ExtensionVersion, StringComparison.Ordinal);
            if (extension is not null && !recordCurrent)
            {
                if (!RecordInstalledVersion(projectRoot, PendingPrefix + ExtensionVersion))
                {
                    AppLog.Write("lyrics", "failed record");
                    await TryDisableAfterFailureAsync(core, token);
                    return BrowserLyricsState.Failed("record");
                }
                AppLog.Write("lyrics", "reinstall " + ExtensionVersion);
                await BrowserPrivacy.AwaitBoundedAsync(extension.RemoveAsync().AsTask(), ExtensionOperationTimeout, operationToken);
                operationToken.ThrowIfCancellationRequested();
                extension = null;
            }
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

            // Only Nativune adds extensions here, so a same-name copy with another ID is an obsolete registration. Two
            // enabled copies would both inject content scripts, so every one must end up disabled or removed.
            foreach (var stale in installed.Where(candidate =>
                string.Equals(candidate.Name, ExtensionName, StringComparison.Ordinal)
                && !string.Equals(candidate.Id, ExpectedExtensionId, StringComparison.Ordinal)))
            {
                await TryDisableOrRemoveAsync(stale, operationToken);
            }
            var afterCleanup = await BrowserPrivacy.AwaitBoundedAsync(
                core.Profile.GetBrowserExtensionsAsync().AsTask(), ExtensionOperationTimeout, operationToken);
            if (afterCleanup.Any(candidate => candidate.IsEnabled
                && string.Equals(candidate.Name, ExtensionName, StringComparison.Ordinal)
                && !string.Equals(candidate.Id, ExpectedExtensionId, StringComparison.Ordinal)))
            {
                AppLog.Write("lyrics", "failed stale");
                await TryDisableAfterFailureAsync(core, token);
                return BrowserLyricsState.Failed("stale");
            }
            // Record the version only when it is not already current. If that write fails, Lyrics stays off for this
            // session (so no lyric settings accrue) and the next launch's reinstall has nothing of the user's to reset.
            if (!recordCurrent && !RecordInstalledVersion(projectRoot, ExtensionVersion))
            {
                AppLog.Write("lyrics", "failed record");
                await TryDisableAfterFailureAsync(core, token);
                return BrowserLyricsState.Failed("record");
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

    // Runtime off: disables the expected extension only (uBO Lite and anything else is left alone); if that cannot be
    // confirmed, removes it (same sequence as startup). Returns true only when no enabled copy is confirmed to remain.
    internal static async Task<bool> DisableNowAsync(CoreWebView2 core, CancellationToken token)
    {
        try
        {
            using var cancellation = CancellationTokenSource.CreateLinkedTokenSource(token);
            cancellation.CancelAfter(ConfigurationTimeout);
            await DisableExpectedAsync(core, cancellation.Token);
            AppLog.Write("lyrics", "disabled");
            return true;
        }
        catch (Exception exception)
        {
            AppLog.Write("lyrics", "disable-failed " + exception.GetType().Name);
        }
        try
        {
            await RemoveExpectedAsync(core, token);
            AppLog.Write("lyrics", "removed");
            return true;
        }
        catch (Exception exception)
        {
            AppLog.Write("lyrics", "remove-failed " + exception.GetType().Name);
            return false;
        }
    }

    // Only Nativune adds extensions to its profile, so a copy with the managed name but another ID is an obsolete
    // Barebones Better Lyrics registration; the off state must cover it too.
    private static bool IsManagedLyrics(CoreWebView2BrowserExtension candidate)
        => string.Equals(candidate.Id, ExpectedExtensionId, StringComparison.Ordinal)
            || string.Equals(candidate.Name, ExtensionName, StringComparison.Ordinal);

    // Throws unless every managed lyrics copy ends up disabled.
    private static async Task DisableExpectedAsync(CoreWebView2 core, CancellationToken operationToken)
    {
        var installed = await BrowserPrivacy.AwaitBoundedAsync(
            core.Profile.GetBrowserExtensionsAsync().AsTask(), ExtensionOperationTimeout, operationToken);
        foreach (var extension in installed.Where(candidate => IsManagedLyrics(candidate) && candidate.IsEnabled))
        {
            await BrowserPrivacy.AwaitBoundedAsync(
                extension.EnableAsync(false).AsTask(), ExtensionOperationTimeout, operationToken);
            if (extension.IsEnabled)
                throw new InvalidOperationException("Lyrics extension stayed enabled.");
        }
    }

    // Last resort for the off state (loses the extension's saved settings). Throws, so Music is not loaded,
    // unless no enabled managed lyrics copy remains.
    private static async Task RemoveExpectedAsync(CoreWebView2 core, CancellationToken token)
    {
        using var removal = CancellationTokenSource.CreateLinkedTokenSource(token);
        removal.CancelAfter(ExtensionOperationTimeout);
        var installed = await BrowserPrivacy.AwaitBoundedAsync(
            core.Profile.GetBrowserExtensionsAsync().AsTask(), ExtensionOperationTimeout, removal.Token);
        foreach (var extension in installed.Where(IsManagedLyrics))
        {
            await BrowserPrivacy.AwaitBoundedAsync(extension.RemoveAsync().AsTask(), ExtensionOperationTimeout, removal.Token);
        }
        var remaining = await BrowserPrivacy.AwaitBoundedAsync(
            core.Profile.GetBrowserExtensionsAsync().AsTask(), ExtensionOperationTimeout, removal.Token);
        if (remaining.Any(candidate => IsManagedLyrics(candidate) && candidate.IsEnabled))
            throw new InvalidOperationException("Lyrics could not be turned off; Music was not loaded.");
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

    private static string RecordedVersionPath(string root)
        => Path.Combine(RootLocator.WebViewProfilePath(root), InstalledVersionFile);

    // File content: the bundle version last added to this profile. Missing/unreadable means "unknown": the caller
    // reinstalls only after it has persisted the current version, so an unwritable record never loops.
    private static string? ReadRecordedVersion(string root)
    {
        try
        {
            var path = RecordedVersionPath(root);
            if (!File.Exists(path)) return null;
            RootLocator.EnsureRegularFile(root, path);
            if (new FileInfo(path).Length > 64) return null;
            return File.ReadAllText(path).Trim();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or InvalidOperationException)
        {
            return null;
        }
    }

    private static bool RecordInstalledVersion(string root, string value)
    {
        var path = RecordedVersionPath(root);
        var temporary = path + ".tmp";
        try
        {
            var directory = Path.GetDirectoryName(path)!;
            RootLocator.EnsureNoReparsePath(root, directory);
            Directory.CreateDirectory(directory);
            RootLocator.EnsureNoReparsePath(root, temporary);
            File.WriteAllText(temporary, value);
            File.Move(temporary, path, overwrite: true);
            return true;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or InvalidOperationException)
        {
            AppLog.Write("lyrics", "record-failed " + exception.GetType().Name);
            return false;
        }
        finally
        {
            try { File.Delete(temporary); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
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
