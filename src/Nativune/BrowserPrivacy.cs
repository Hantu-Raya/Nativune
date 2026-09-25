using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Windows.Foundation;

namespace Nativune;

internal static class BrowserPrivacy
{
    private const string ExtensionName = "uBlock Origin Lite";
    private const string ExtensionVersion = "2026.907.2003";
    // A file beside the WebView2 profile remembers the extension Id installed in that profile for the
    // pinned version, so later launches reuse it instead of AddBrowserExtensionAsync (measured Music
    // navigation 2.86 s -> 1.62 s). The full configuration check still runs, and fails closed, every launch.
    private const string InstalledExtensionIdFile = "ubol-lite-extension.id";
    private static readonly TimeSpan ExtensionOperationTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan NavigationTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan DevToolsTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ConfigurationTimeout = TimeSpan.FromSeconds(45);
    private static readonly TimeSpan CleanupTimeout = TimeSpan.FromSeconds(5);

    // blockAds is the owner-approved opt-in (Settings > Block ads, off by default). Off keeps the
    // privacy-only configuration: EasyPrivacy network rules on music.youtube.com and nothing else.
    // On adds uBO Lite's ad lists and its "optimal" mode (cosmetic filters and scriptlets such as the
    // YouTube ad-payload pruning) for music.youtube.com only.
    public static async Task ConfigureAsync(
        CoreWebView2 core,
        string projectRoot,
        Action<string?> setTrustedSetupUri,
        bool blockAds,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentException.ThrowIfNullOrWhiteSpace(projectRoot);
        ArgumentNullException.ThrowIfNull(setTrustedSetupUri);

        var directory = Path.Combine(projectRoot, ".tools", "ubol", ExtensionVersion);
        RootLocator.EnsureNoReparseTree(projectRoot, directory);
        RootLocator.EnsureRegularFile(projectRoot, Path.Combine(directory, "manifest.json"));

        using var configurationCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        configurationCancellation.CancelAfter(ConfigurationTimeout);
        var operationToken = configurationCancellation.Token;
        CoreWebView2BrowserExtension? extension = null;
        try
        {
            extension = await FindRecordedExtensionAsync(core, projectRoot, operationToken);
            var reused = extension is not null;
            if (extension is null)
            {
                var extensionCreation = core.Profile.AddBrowserExtensionAsync(directory).AsTask();
                extension = await AwaitBoundedAsync(
                    extensionCreation, ExtensionOperationTimeout, operationToken);
                operationToken.ThrowIfCancellationRequested();
                RecordInstalledExtensionId(projectRoot, extension.Id);
            }

            if (!reused || !extension.IsEnabled)
            {
                var extensionEnable = extension.EnableAsync(true).AsTask();
                await AwaitBoundedAsync(extensionEnable, ExtensionOperationTimeout, operationToken);
                operationToken.ThrowIfCancellationRequested();
            }

            var setupUri = $"chrome-extension://{extension.Id}/dashboard.html";
            await NavigateToDashboardAsync(core, setupUri, setTrustedSetupUri, operationToken);
            var rulesets = blockAds
                ? new[] { "easyprivacy", "easylist", "ublock-filters" }
                : new[] { "easyprivacy" };
            var modes = blockAds
                ? new Dictionary<string, string[]> { ["none"] = ["all-urls"], ["basic"] = [], ["optimal"] = ["music.youtube.com"], ["complete"] = [] }
                : new Dictionary<string, string[]> { ["none"] = ["all-urls"], ["basic"] = ["music.youtube.com"], ["optimal"] = [], ["complete"] = [] };
            var expression = $$"""
                (async () => {
                    if (chrome.runtime.getManifest().version !== '{{ExtensionVersion}}')
                        throw new Error('Unexpected uBO Lite version');
                    const wanted = {{JsonSerializer.Serialize(rulesets)}};
                    const modes = {{JsonSerializer.Serialize(modes)}};
                    const blockAds = {{(blockAds ? "true" : "false")}};
                    const send = message => chrome.runtime.sendMessage(message);
                    await send({what:'getOptionsPageData'});
                    await send({what:'setStrictBlockMode',state:false});
                    await send({what:'setPopupBlockMode',state:false});
                    await send({what:'applyRulesets',enabledRulesets:wanted});
                    await send({what:'setFilteringModeDetails',modes});
                    const config = await send({what:'getOptionsPageData'});
                    const enabled = await chrome.declarativeNetRequest.getEnabledRulesets();
                    const actualModes = await send({what:'getFilteringModeDetails'});
                    const scripts = await chrome.scripting.getRegisteredContentScripts();
                    const same = list => JSON.stringify([...list].sort()) === JSON.stringify([...wanted].sort());
                    return same(enabled) && same(config.enabledRulesets)
                        && !config.strictBlockMode && !config.popupBlockMode
                        && JSON.stringify(actualModes) === JSON.stringify(modes)
                        // Privacy-only: the upstream toolbar-state notifier is the only content script.
                        // Ad blocking registers uBO Lite's own filtering scripts for music.youtube.com.
                        && (blockAds || scripts.every(s => s.id === 'toolbar-icon'));
                })()
                """;
            var parameters = JsonSerializer.Serialize(new { expression, awaitPromise = true, returnByValue = true });
            var responseTask = core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", parameters).AsTask();
            var response = await AwaitBoundedAsync(
                responseTask, DevToolsTimeout, operationToken);
            operationToken.ThrowIfCancellationRequested();
            using var result = JsonDocument.Parse(response);
            if (result.RootElement.TryGetProperty("exceptionDetails", out _)
                || !result.RootElement.GetProperty("result").TryGetProperty("value", out var value)
                || value.ValueKind != JsonValueKind.True)
            {
                throw new InvalidOperationException(blockAds
                    ? "uBO Lite ad-filter configuration could not be verified; Music was not loaded."
                    : "uBO Lite privacy-only configuration could not be verified; Music was not loaded.");
            }
            // The trusted setup URI stays in force on failure so WebHost keeps Music navigation blocked.
            setTrustedSetupUri(null);
        }
        catch
        {
            try
            {
                core.Stop();
            }
            catch
            {
                // Stopping is best effort while failing closed.
            }

            if (extension is not null && !cancellationToken.IsCancellationRequested)
            {
                try
                {
                    using var cleanupCancellation =
                        CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
                    cleanupCancellation.CancelAfter(CleanupTimeout);
                    var disableTask = extension.EnableAsync(false).AsTask();
                    await AwaitBoundedAsync(
                        disableTask, CleanupTimeout, cleanupCancellation.Token);
                }
                catch
                {
                    // Disable is bounded best effort; the original failure remains authoritative.
                }
            }

            throw;
        }
    }

    private static async Task NavigateToDashboardAsync(
        CoreWebView2 core,
        string setupUri,
        Action<string?> setTrustedSetupUri,
        CancellationToken operationToken)
    {
        var navigation = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        ulong? expectedNavigationId = null;
        TypedEventHandler<CoreWebView2, CoreWebView2NavigationStartingEventArgs> onStarting = (_, args) =>
        {
            if (!string.Equals(args.Uri, setupUri, StringComparison.Ordinal))
            {
                navigation.TrySetException(
                    new InvalidOperationException("Privacy configuration navigation origin changed."));
                return;
            }

            expectedNavigationId = args.NavigationId;
        };
        TypedEventHandler<CoreWebView2, CoreWebView2NavigationCompletedEventArgs> onCompleted = (_, args) =>
        {
            if (!expectedNavigationId.HasValue || args.NavigationId != expectedNavigationId.Value)
                return;

            if (args.IsSuccess)
                navigation.TrySetResult(true);
            else
                navigation.TrySetException(
                    new InvalidOperationException("Could not load the uBO Lite configuration page."));
        };

        core.NavigationStarting += onStarting;
        core.NavigationCompleted += onCompleted;
        try
        {
            operationToken.ThrowIfCancellationRequested();
            setTrustedSetupUri(setupUri);
            operationToken.ThrowIfCancellationRequested();
            core.Navigate(setupUri);
            await navigation.Task.WaitAsync(NavigationTimeout, operationToken);
            operationToken.ThrowIfCancellationRequested();
            if (!string.Equals(core.Source, setupUri, StringComparison.Ordinal))
                throw new InvalidOperationException("Privacy configuration origin changed.");
        }
        finally
        {
            core.NavigationStarting -= onStarting;
            core.NavigationCompleted -= onCompleted;
        }
    }

    private static async Task<CoreWebView2BrowserExtension?> FindRecordedExtensionAsync(
        CoreWebView2 core,
        string projectRoot,
        CancellationToken operationToken)
    {
        var recordedId = ReadRecordedExtensionId(projectRoot);
        if (recordedId is null) return null;
        try
        {
            var installedExtensionsTask = core.Profile.GetBrowserExtensionsAsync().AsTask();
            var installedExtensions = await AwaitBoundedAsync(
                installedExtensionsTask, ExtensionOperationTimeout, operationToken);
            return installedExtensions.FirstOrDefault(installed =>
                string.Equals(installed.Id, recordedId, StringComparison.Ordinal)
                && string.Equals(installed.Name, ExtensionName, StringComparison.Ordinal));
        }
        catch (Exception exception) when (exception is TimeoutException or InvalidOperationException
            or System.Runtime.InteropServices.COMException)
        {
            operationToken.ThrowIfCancellationRequested();
            return null;
        }
    }

    private static string RecordedExtensionIdPath(string root)
        => Path.Combine(RootLocator.WebViewProfilePath(root), InstalledExtensionIdFile);

    // File content: "<ExtensionVersion> <extension Id>". A record for another version is ignored,
    // so an upgraded bundle installs from its new directory instead of reusing the old extension.
    private static string? ReadRecordedExtensionId(string root)
    {
        try
        {
            var path = RecordedExtensionIdPath(root);
            if (!File.Exists(path)) return null;
            RootLocator.EnsureRegularFile(root, path);
            if (new FileInfo(path).Length > 128) return null;
            var parts = File.ReadAllText(path).Split(' ', StringSplitOptions.TrimEntries);
            return parts.Length == 2 && parts[0] == ExtensionVersion && IsValidExtensionId(parts[1])
                ? parts[1]
                : null;
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or InvalidOperationException)
        {
            return null;
        }
    }

    private static void RecordInstalledExtensionId(string root, string extensionId)
    {
        if (!IsValidExtensionId(extensionId)) return;
        var path = RecordedExtensionIdPath(root);
        var temporary = path + ".tmp";
        try
        {
            var directory = Path.GetDirectoryName(path)!;
            RootLocator.EnsureNoReparsePath(root, directory);
            Directory.CreateDirectory(directory);
            RootLocator.EnsureNoReparsePath(root, temporary);
            File.WriteAllText(temporary, $"{ExtensionVersion} {extensionId}");
            File.Move(temporary, path, overwrite: true);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException
            or InvalidOperationException)
        {
            // Recording is an optimisation only; the next launch installs again.
        }
        finally
        {
            try { File.Delete(temporary); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    // Chromium extension Ids are 32 characters from the a-p alphabet.
    private static bool IsValidExtensionId(string extensionId)
        => extensionId.Length == 32 && extensionId.All(character => character is >= 'a' and <= 'p');

    private static async Task<T> AwaitBoundedAsync<T>(
        Task<T> operation,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        try
        {
            return await operation.WaitAsync(timeout, cancellationToken);
        }
        catch
        {
            _ = ObserveCompletionAsync(operation);
            throw;
        }
    }

    private static async Task AwaitBoundedAsync(
        Task operation,
        TimeSpan timeout,
        CancellationToken cancellationToken)
    {
        try
        {
            await operation.WaitAsync(timeout, cancellationToken);
        }
        catch
        {
            _ = ObserveCompletionAsync(operation);
            throw;
        }
    }

    private static async Task ObserveCompletionAsync(Task operation)
    {
        try { await operation.ConfigureAwait(false); }
        catch (Exception) { }
    }
}
