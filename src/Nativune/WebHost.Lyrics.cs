using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.Web.WebView2.Core;
using VirtualKey = Windows.System.VirtualKey;

namespace Nativune;

// Barebones Better Lyrics: status text and the one host-owned lyric settings window.
// The Music view's origin policy is untouched; this window only shows the extension's own options page.
public sealed partial class WebHostWindow
{
    private const string LyricsOptionsPrefix = "chrome-extension://" + BrowserLyrics.ExpectedExtensionId + "/";
    private const string LyricsOptionsUri = LyricsOptionsPrefix + "options/index.html";

    private BrowserLyricsState _lyricsState = BrowserLyricsState.Disabled;
    private Window? _lyricsWindow;
    private NativeBrowserHost? _lyricsHost;
    private bool _lyricsWindowOpening;

    internal CoreWebView2? LyricsSettingsCore
    {
        get
        {
            try { return _lyricsHost?.Core; }
            catch (Exception) { return null; }
        }
    }

    internal string LyricsStatusText
    {
        get
        {
            if (!_settings.BetterLyricsEnabled) return "Off";
            return _lyricsState.Status switch
            {
                BrowserLyricsStatus.Installed => $"On ({BrowserLyrics.ExtensionName} {BrowserLyrics.ExtensionVersion})",
                BrowserLyricsStatus.Missing => "Lyrics files are missing",
                BrowserLyricsStatus.Failed => "Lyrics could not start",
                _ => "Turns on after restart"
            };
        }
    }

    internal async Task OpenLyricsSettingsAsync()
    {
        if (_closing || _disposed || _environment is null) return;
        if (!_lyricsState.IsInstalled || !_settings.BetterLyricsEnabled) return;
        if (_lyricsWindow is { } existing)
        {
            try { existing.Activate(); } catch (Exception) { }
            return;
        }
        if (_lyricsWindowOpening) return;
        _lyricsWindowOpening = true;

        var grid = new Grid();
        var window = new Window { Content = grid, Title = "Lyric settings" };
        NativeBrowserHost? host = null;
        try
        {
            window.AppWindow.Resize(new Windows.Graphics.SizeInt32(900, 820));
            window.Closed += (_, _) => OnLyricsWindowClosed(window);
            grid.KeyDown += (_, args) =>
            {
                if (args.Key != VirtualKey.Escape) return;
                args.Handled = true;
                CloseLyricsSettingsWindow();
            };
            _lyricsWindow = window;
            window.Activate();

            var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(window);
            host = await NativeBrowserHost.CreateAsync(_environment, hwnd, grid, _lifetime.Token, _ => { });
            if (_closing || _disposed || !ReferenceEquals(_lyricsWindow, window))
            {
                host.Dispose();
                return;
            }
            var core = host.Core;
            core.Settings.AreHostObjectsAllowed = false;
            core.Settings.IsWebMessageEnabled = false;
            core.NavigationStarting += (_, args) =>
            {
                if (!(args.Uri ?? string.Empty).StartsWith(LyricsOptionsPrefix, StringComparison.Ordinal))
                    args.Cancel = true;
            };
            core.NewWindowRequested += (_, args) => args.Handled = true;
            core.DownloadStarting += (_, args) => args.Cancel = true;
            core.PermissionRequested += (_, args) => args.State = CoreWebView2PermissionState.Deny;
            core.LaunchingExternalUriScheme += (_, args) => args.Cancel = true;
            core.ProcessFailed += (_, _) =>
            {
                AppLog.Write("lyrics", "settings-process-failed");
                _dispatcherQueue.TryEnqueue(() => { if (ReferenceEquals(_lyricsWindow, window)) CloseLyricsSettingsWindow(); });
            };
            host.AcceleratorKeyPressed += (_, args) =>
            {
                if (args.KeyEventKind == CoreWebView2KeyEventKind.KeyDown && args.VirtualKey == (uint)VirtualKey.Escape)
                {
                    args.Handled = true;
                    _dispatcherQueue.TryEnqueue(() => { if (ReferenceEquals(_lyricsWindow, window)) CloseLyricsSettingsWindow(); });
                }
            };
            _lyricsHost = host;
            host.SetVisible(true);
            core.Navigate(LyricsOptionsUri);
            host = null;
        }
        catch (Exception exception)
        {
            AppLog.Write("lyrics", "settings-open-failed " + exception.GetType().Name);
            try { host?.Dispose(); } catch (Exception) { }
            if (ReferenceEquals(_lyricsWindow, window))
                CloseLyricsSettingsWindow();
            if (!_closing && !_disposed)
                SetStatus("Lyric settings could not be opened.", isError: true);
        }
        finally
        {
            _lyricsWindowOpening = false;
        }
    }

    private void OnLyricsWindowClosed(Window window)
    {
        if (!ReferenceEquals(_lyricsWindow, window)) return;
        _lyricsWindow = null;
        var host = _lyricsHost;
        _lyricsHost = null;
        try { host?.Dispose(); } catch (Exception) { }
    }

    private void CloseLyricsSettingsWindow()
    {
        var window = _lyricsWindow;
        var host = _lyricsHost;
        _lyricsWindow = null;
        _lyricsHost = null;
        try { host?.Dispose(); } catch (Exception) { }
        try { window?.Close(); } catch (Exception) { }
    }

    private async Task DisableLyricsNowAsync()
    {
        CloseLyricsSettingsWindow();
        if (_browserHost is not { } host) return;
        CoreWebView2 core;
        try { core = host.Core; }
        catch (Exception) { return; }
        await BrowserLyrics.DisableNowAsync(core, _lifetime.Token);
        if (_lyricsState.IsInstalled)
            _lyricsState = BrowserLyricsState.Disabled;
    }
}
