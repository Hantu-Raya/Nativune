using Microsoft.UI.Dispatching;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Media.Imaging;

namespace Nativune;

public sealed partial class WebHostWindow
{
    private const int CompactReadinessProbeLimit = 8;
    private const string CompactReadinessFallbackStatus =
        "Website playback controls are not ready. Compact controls will stay unavailable until they load; use Return to full to continue browsing.";
    private const string CompactReadinessCheckingStatus =
        "Checking the website playback controls before opening Compact.";
    private DispatcherQueueTimer _compactReadTimer = null!;
    private bool _compactActivity;
    private bool _compactReadPending;
    private int _compactGeneration;
    private long _lastCompactReadAt = -1000;
    private long _lastCompactStateAt;
    private CompactPlaybackState? _compactState;
    private bool _compactReadinessProbePending;
    private CancellationTokenSource? _compactArtworkCancellation;
    private string? _compactArtworkUrl;

    private bool CompactActive => _compact && _appWindow?.IsVisible == true
        && _presenter?.State != Microsoft.UI.Windowing.OverlappedPresenterState.Minimized
        && !_closing && !_disposed && !_playerSuspended;

    private void InitializeCompactSurface()
    {
        _compactReadTimer = _dispatcherQueue.CreateTimer();
        _compactReadTimer.Interval = TimeSpan.FromSeconds(1);
        _compactReadTimer.IsRepeating = true;
        _compactReadTimer.Tick += async (_, _) =>
        {
            UpdateCompactTimer();
            await ReadCompactStateAsync();
        };

        CompactView.CommandRequested += (command, value) => _ = ExecuteCompactCommandAsync(command, value);
        CompactView.ReturnToFullRequested += () => SetCompact(false);
        CompactView.SettingsRequested += ShowSettings;
        CompactView.TimerRequested += SetPauseTimer;
        CompactView.CancelTimerRequested += CancelPauseTimer;
        CompactView.StatusRequested += ShowStatusDetails;
        CompactView.MinimizeRequested += () => _presenter?.Minimize();
        CompactView.CloseRequested += () => _ = ShutdownAsync();
        CompactView.ToggleTopmostRequested += () => SetTopmost(!(_presenter?.IsAlwaysOnTop == true));
        CompactView.SetPreferences(_settings.ReduceMotion, _presenter?.IsAlwaysOnTop == true);
    }

    private async Task ProbeForCompactTransportAsync()
    {
        if (!_initializeBrowser || !_compactWhenReady || _compactReadinessProbePending) return;
        _compactReadinessProbePending = true;
        var cancellation = _lifetime.Token;
        try
        {
            for (var attempt = 0; attempt < CompactReadinessProbeLimit; attempt++)
            {
                if (!_compactWhenReady || _closing || _disposed) return;
                var controls = _playerControls;
                if (controls?.IsAvailable == true
                    && await controls.AreCompactTransportControlsReadyAsync())
                {
                    if (_compactWhenReady && !_closing && !_disposed
                        && ReferenceEquals(controls, _playerControls) && !_compact)
                    {
                        if (_statusDetailsText.StartsWith(CompactReadinessCheckingStatus,
                                StringComparison.Ordinal))
                            SetStatus(string.Empty);
                        _compactWhenReady = false;
                        ToggleCompactCore();
                    }
                    return;
                }

                if (attempt + 1 < CompactReadinessProbeLimit && _compactWhenReady)
                    await Task.Delay(TimeSpan.FromSeconds(1), cancellation);
            }

            EnterCompactWithUnavailableControls();
        }
        catch (OperationCanceledException) when (cancellation.IsCancellationRequested || _closing || _disposed)
        {
        }
        catch (Exception)
        {
            EnterCompactWithUnavailableControls();
        }
        finally
        {
            _compactReadinessProbePending = false;
        }
    }

    private void EnterCompactWithUnavailableControls()
    {
        if (!_compactWhenReady || _closing || _disposed || _compact) return;
        _compactWhenReady = false;
        SetStatus(CompactReadinessFallbackStatus, isError: true);
        ToggleCompactCore();
    }


    private void ApplyCompactSurface()
    {
        if (_compact) CloseOutputVolumeFlyout();
        CompactView.Visibility = _compact ? Visibility.Visible : Visibility.Collapsed;
        ToolbarHost.Visibility = _compact ? Visibility.Collapsed : Visibility.Visible;
        ToolbarRow.Height = _compact ? new GridLength(0) : GridLength.Auto;
        WebViewSlot.Visibility = _compact ? Visibility.Collapsed : Visibility.Visible;
        UpdateBrowserVisibility();
        if (_compact)
        {
            StatusHost.Visibility = Visibility.Collapsed;
            StatusRow.Height = new GridLength(0);
        }
        else
        {
            StatusHost.Visibility = _statusIsPersistent || _statusDetailsText.Length != 0
                ? Visibility.Visible : Visibility.Collapsed;
            StatusRow.Height = StatusHost.Visibility == Visibility.Visible ? GridLength.Auto : new GridLength(0);
        }
        CompactView.SetPreferences(_settings.ReduceMotion, _presenter?.IsAlwaysOnTop == true);
        CompactView.SetStatus(_statusDetailsText, _statusIsError);
        UpdateCompactTimer();
        RefreshCompactActivity();
    }

    private void RefreshCompactActivity()
    {
        var active = CompactActive;
        if (_compactActivity == active) return;
        _compactActivity = active;
        _compactReadTimer?.Stop();
        InvalidateCompactState();
        CompactView.SetActive(active);
        if (active)
        {
            _compactReadTimer!.Start();
            _ = ReadCompactStateAsync();
        }
    }

    private void InvalidateCompactState()
    {
        _compactGeneration++;
        _compactState = null;
        _compactArtworkUrl = null;
        _compactArtworkCancellation?.Cancel();
        _compactArtworkCancellation?.Dispose();
        _compactArtworkCancellation = null;
        if (!_disposed)
        {
            CompactView.SetPlayback(null);
            CompactView.SetArtwork(null);
        }
    }

    private async Task ReadCompactStateAsync()
    {
        if (!CompactActive) return;
        if (_compactState is not null && Environment.TickCount64 - _lastCompactStateAt > 2500)
            InvalidateCompactState();
        if (_compactReadPending || Environment.TickCount64 - _lastCompactReadAt < 1000) return;
        var controls = _playerControls;
        if (_playerBusy || controls?.IsAvailable != true)
        {
            if (_compactState is not null && Environment.TickCount64 - _lastCompactStateAt > 2500)
                InvalidateCompactState();
            return;
        }
        _compactReadPending = true;
        _lastCompactReadAt = Environment.TickCount64;
        var generation = _compactGeneration;
        try
        {
            var state = await controls.ReadCompactStateAsync();
            if (!CompactActive || generation != _compactGeneration) return;
            _compactState = state;
            if (state is not null)
            {
                _compactStartupPending = false;
                _compactResumeAfterAccount = false;
            }
            _lastCompactStateAt = Environment.TickCount64;
            CompactView.SetPlayback(state);
            UpdateCompactArtwork(state?.ArtworkUrl);
            if (state is not null
                && _statusDetailsText.StartsWith("[!] Error: " + CompactReadinessFallbackStatus,
                    StringComparison.Ordinal))
                SetStatus(string.Empty);
        }
        catch (Exception)
        {
            if (CompactActive && generation == _compactGeneration)
                InvalidateCompactState();
        }
        finally
        {
            _compactReadPending = false;
        }
    }


    private void UpdateCompactArtwork(string? url)
    {
        if (string.Equals(url, _compactArtworkUrl, StringComparison.Ordinal)) return;
        _compactArtworkUrl = url;
        _compactArtworkCancellation?.Cancel();
        _compactArtworkCancellation?.Dispose();
        _compactArtworkCancellation = null;
        CompactView.SetArtwork(null);
        if (url is null) return;
        var cancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
        _compactArtworkCancellation = cancellation;
        _ = LoadCompactArtworkAsync(url, _compactGeneration, cancellation.Token);
    }

    private async Task LoadCompactArtworkAsync(string url, int generation, CancellationToken cancellation)
    {
        try
        {
            var artwork = await CompactArtwork.LoadAsync(url, cancellation);
            if (!cancellation.IsCancellationRequested && CompactActive && generation == _compactGeneration
                && string.Equals(url, _compactArtworkUrl, StringComparison.Ordinal))
                CompactView.SetArtwork(artwork);
        }
        catch (Exception)
        {
            // Leave the neutral disc; never log URLs or retry automatically.
        }
    }

    private async Task ExecuteCompactCommandAsync(string command, double? value)
    {
        if (!CompactActive) return;
        if (command == "output-volume")
        {
            if (value is { } volume && double.IsFinite(volume) && volume >= 0 && volume <= 1)
                SetOutputVolume(volume);
            return;
        }
        if (command == "output-mute")
        {
            ToggleOutputMute();
            return;
        }
        if (command is "toggle" or "previous" or "next")
        {
            await ExecutePlayerCommandAsync(command);
            return;
        }
        if (_compactState is null || _playerBusy) return;
        var controls = _playerControls;
        if (controls?.IsAvailable != true)
        {
            SetStatus("Playback controls are busy or unavailable; no action was sent.", isError: true);
            return;
        }
        _playerBusy = true;
        UpdatePlayerControls();
        try
        {
            var status = await controls.ExecuteCompactAsync(command, value);
            if (!_closing && !_disposed) SetStatus(status);
        }
        catch (Exception)
        {
            if (!_closing && !_disposed) SetStatus("Player action outcome unknown; no retry.", isError: true);
        }
        finally
        {
            _playerBusy = false;
            if (!_closing && !_disposed) UpdatePlayerControls();
        }
    }

    private void UpdateCompactTimer()
    {
        if (!_disposed) CompactView.SetTimer(_sleep?.TimeRemaining);
    }

    private void DisposeCompactSurface()
    {
        _compactReadTimer?.Stop();
        _compactArtworkCancellation?.Cancel();
        _compactArtworkCancellation?.Dispose();
        _compactArtworkCancellation = null;
        InvalidateCompactState();
        CompactView.SetActive(false);
        CompactView.Dispose();
    }
}
