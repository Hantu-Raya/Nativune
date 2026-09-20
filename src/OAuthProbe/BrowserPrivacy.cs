using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Windows.Foundation;

namespace OAuthProbe;

internal static class BrowserPrivacy
{
    private const string ExtensionVersion = "2026.907.2003";
    private static readonly TimeSpan ExtensionOperationTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan NavigationTimeout = TimeSpan.FromSeconds(20);
    private static readonly TimeSpan DevToolsTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan ConfigurationTimeout = TimeSpan.FromSeconds(45);
    private static readonly TimeSpan CleanupTimeout = TimeSpan.FromSeconds(5);

    public static async Task ConfigureAsync(
        CoreWebView2 core,
        string projectRoot,
        Action<string?> setTrustedSetupUri,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(core);
        ArgumentException.ThrowIfNullOrWhiteSpace(projectRoot);
        ArgumentNullException.ThrowIfNull(setTrustedSetupUri);

        var directory = Path.Combine(projectRoot, ".tools", "ubol", ExtensionVersion);
        if (!File.Exists(Path.Combine(directory, "manifest.json")))
            throw new FileNotFoundException("Run scripts/setup-ubol.ps1 to install the pinned privacy extension.");

        using var configurationCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        configurationCancellation.CancelAfter(ConfigurationTimeout);
        var operationToken = configurationCancellation.Token;
        CoreWebView2BrowserExtension? extension = null;
        try
        {
            var extensionCreation = core.Profile.AddBrowserExtensionAsync(directory).AsTask();
            extension = await AwaitBoundedAsync(
                extensionCreation, ExtensionOperationTimeout, operationToken);
            operationToken.ThrowIfCancellationRequested();

            var extensionEnable = extension.EnableAsync(true).AsTask();
            await AwaitBoundedAsync(extensionEnable, ExtensionOperationTimeout, operationToken);
            operationToken.ThrowIfCancellationRequested();

            var setupUri = $"chrome-extension://{extension.Id}/dashboard.html";
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

                const string expression = """
                    (async () => {
                        if (chrome.runtime.getManifest().version !== '2026.907.2003')
                            throw new Error('Unexpected uBO Lite version');
                        const send = message => chrome.runtime.sendMessage(message);
                        await send({what:'getOptionsPageData'});
                        await send({what:'setStrictBlockMode',state:false});
                        await send({what:'setPopupBlockMode',state:false});
                        await send({what:'applyRulesets',enabledRulesets:['easyprivacy']});
                        const modes = {none:['all-urls'],basic:['music.youtube.com'],optimal:[],complete:[]};
                        await send({what:'setFilteringModeDetails',modes});
                        const config = await send({what:'getOptionsPageData'});
                        const enabled = await chrome.declarativeNetRequest.getEnabledRulesets();
                        const actualModes = await send({what:'getFilteringModeDetails'});
                        const scripts = await chrome.scripting.getRegisteredContentScripts();
                        return enabled.length === 1 && enabled[0] === 'easyprivacy'
                            && config.enabledRulesets.length === 1 && config.enabledRulesets[0] === 'easyprivacy'
                            && !config.strictBlockMode && !config.popupBlockMode
                            && JSON.stringify(actualModes) === JSON.stringify(modes)
                            // The upstream toolbar-state notifier does not filter page content.
                            && scripts.every(s => s.id === 'toolbar-icon');
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
                    throw new InvalidOperationException(
                        "uBO Lite privacy-only configuration could not be verified; Music was not loaded.");
                }
            }
            finally
            {
                core.NavigationStarting -= onStarting;
                core.NavigationCompleted -= onCompleted;
                setTrustedSetupUri(null);
            }
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
