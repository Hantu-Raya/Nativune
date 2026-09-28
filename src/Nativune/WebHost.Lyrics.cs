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

    // Runtime Lyrics off, shared by the Settings save path and the bench `lyrics-off-now` action.
    // Returns true when Lyrics is confirmed off; false when it could not be confirmed and the app is closing.
    private async Task<bool> TurnLyricsOffAsync()
    {
        // Persist Off first through the serialized save path, so a hang or crash below still starts with Lyrics off.
        _settings = _settings with { BetterLyricsEnabled = false };
        CaptureSettings();
        CloseLyricsSettingsWindow();
        CoreWebView2? core = null;
        var off = false;
        try
        {
            if (_browserHost is { } host)
            {
                core = host.Core;
                off = await BrowserLyrics.DisableNowAsync(core, _lifetime.Token);
            }
            else
            {
                // No Music view: nothing is loaded, and the next start reads the saved Off.
                off = true;
            }
            if (off && core is not null)
            {
                _lyricsState = BrowserLyricsState.Disabled;
                // Chromium keeps already-injected content scripts running until the page reloads; drop them.
                off = await ReloadMusicAfterLyricsOffAsync(core);
            }
        }
        catch (Exception exception)
        {
            AppLog.Write("lyrics", "off-failed " + exception.GetType().Name);
            off = false;
        }
        if (off)
        {
            _lyricsState = BrowserLyricsState.Disabled;
            return true;
        }
        if (_closing || _disposed) return false;

        // Fail closed: Lyrics cannot be confirmed off in this session, so close. Off is already saved; give that save a
        // bounded moment (at most 2 s) before the controlled shutdown, which clears Discord (about 1 s) before it
        // disposes the browser. The page can keep running for that bounded delay.
        AppLog.Write("lyrics", "off-unconfirmed closing");
        ExitCode = 1;
        SetStatus("Lyrics could not be confirmed off. Nativune is closing; it starts with Lyrics off.", isError: true);
        try { await _saveTask.WaitAsync(TimeSpan.FromSeconds(2)); }
        catch (Exception) { }
        _ = ShutdownAsync();
        return false;
    }

    // Reloads the Music view and waits (bounded) for the new document, so a declined leave-page prompt or a stalled
    // reload is treated as "not confirmed off".
    private async Task<bool> ReloadMusicAfterLyricsOffAsync(CoreWebView2 core)
    {
        var loading = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void OnContentLoading(CoreWebView2 sender, CoreWebView2ContentLoadingEventArgs args) => loading.TrySetResult();
        core.ContentLoading += OnContentLoading;
        try
        {
            core.Reload();
            await loading.Task.WaitAsync(TimeSpan.FromSeconds(15), _lifetime.Token);
            AppLog.Write("lyrics", "reloaded");
            return true;
        }
        catch (Exception exception)
        {
            AppLog.Write("lyrics", "reload-failed " + exception.GetType().Name);
            return false;
        }
        finally
        {
            core.ContentLoading -= OnContentLoading;
        }
    }
}
