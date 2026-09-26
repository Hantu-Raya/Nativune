using UiDispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Nativune;

public sealed partial class WebHostWindow
{
    private ReleaseUpdateResult? _availableReleaseUpdate;
    private DateTimeOffset? _lastReleaseUpdateCheckUtc;
    private ReleaseUpdateButtonState _releaseUpdateButtonState = ReleaseUpdateButtonState.NotChecked;
    private bool _releaseUpdateCheckRunning;
    private bool _releaseUpdatePromptOpen;
    private bool _skipUpdatePrompt;
    private CancellationTokenSource? _updateDownloadCancellation;
    private UiDispatcherQueueTimer? _setupCleanupTimer;
    private long _updateProgressLastBytes;
    private long _updateProgressLastTicks;
    private long _updateStartedTicks;
    private double _updateSpeedEma;
    private int _updateLastAnnouncedPercent;
    private long _updateLastTextTicks;
    private string? _sessionTrayTooltip;
    private string? _updateButtonIconName;
    private string? _infoBarActionLabel;
    private Action? _infoBarActionHandler;
    private Button? _infoBarActionButton;
    private bool CompactUpdateSurfaceVisible => _compact && _appWindow?.IsVisible == true
        && !_closing && !_disposed;
    private string? _pendingWhatsNewVersion;
    private string? _pendingWhatsNewFromVersion;
    private UiDispatcherQueueTimer? _updateInfoCloseTimer;
    private UiDispatcherQueueTimer? _compactUpdateNoticeTimer;
    private bool _compactUpdateNoticeHandlerRegistered;
    private UiDispatcherQueueTimer? _taskbarErrorTimer;
    private bool _taskbarErrorHandlerRegistered;
    private bool _updateCloseHandlerRegistered;
    private ReleaseUpdatePhase? _updateCurrentPhase;

    // A downloaded Setup is never reused by a later session (a retry downloads again), so any
    // leftover is removed at startup. After an update, Setup starts Nativune before it exits and
    // its file is still in use, so deletion is retried until it succeeds or a new download starts.
    private void StartDownloadedSetupCleanup()
    {
        if (ReleaseUpdater.CleanupDownloadedSetup(_root)) return;
        var attempts = 0;
        _setupCleanupTimer = _dispatcherQueue.CreateTimer();
        _setupCleanupTimer.Interval = TimeSpan.FromSeconds(5);
        _setupCleanupTimer.IsRepeating = true;
        _setupCleanupTimer.Tick += (timer, _) =>
        {
            attempts++;
            var downloading = _updateDownloadCancellation is not null
                || _releaseUpdateButtonState is ReleaseUpdateButtonState.Downloading
                    or ReleaseUpdateButtonState.Verifying or ReleaseUpdateButtonState.Launching;
            if (_closing || _disposed || downloading
                || ReleaseUpdater.CleanupDownloadedSetup(_root) || attempts >= 36)
                timer.Stop();
        };
        _setupCleanupTimer.Start();
    }

    private void SetDesiredTrayTooltip(
        ReleaseUpdateButtonState state, string? version, ReleaseUpdateProgress? progress)
    {
        if (state == ReleaseUpdateButtonState.UpToDate)
            _sessionTrayTooltip = null;
        var tooltip = state switch
        {
            ReleaseUpdateButtonState.Available => $"Nativune — update {version} available",
            ReleaseUpdateButtonState.Downloading => progress is { Total: > 0 } value
                ? $"Nativune — downloading update {(int)(100d * value.Bytes / value.Total)} %"
                : "Nativune — downloading update",
            ReleaseUpdateButtonState.Verifying => "Nativune — checking update",
            ReleaseUpdateButtonState.UpToDate => "Nativune",
            _ => _sessionTrayTooltip ?? "Nativune"
        };
        _tray?.SetTooltip(tooltip);
    }

    internal static ReleaseUpdateButtonPresentation GetReleaseUpdateButtonPresentation(
        ReleaseUpdateButtonState state, string? version)
        => state switch
        {
            ReleaseUpdateButtonState.NotChecked => new("update", "Click to check for Nativune updates.", true),
            ReleaseUpdateButtonState.NotInstalled => new("update", "Update checks are available only in installed Nativune builds.", true),
            ReleaseUpdateButtonState.Available => new("update-available",
                $"Nativune {version ?? "the latest version"} is available. Click to update.", true),
            ReleaseUpdateButtonState.UpToDate => new("update", "Nativune is up to date. Click to check for updates.", true),
            ReleaseUpdateButtonState.Failed => new("update", "Couldn't check for updates. Click to try again.", true),
            ReleaseUpdateButtonState.Checking => new("update", "Checking for updates…", false),
            ReleaseUpdateButtonState.Downloading => new("update-available", $"Downloading Nativune {version}…", true),
            ReleaseUpdateButtonState.Verifying => new("update", "Checking the downloaded Setup…", false),
            ReleaseUpdateButtonState.Launching => new("update", "Starting the verified Setup…", false),
            _ => new("update", "Couldn't check for updates. Click to try again.", true)
        };

    private void ApplyUpdateFeedback(
        ReleaseUpdateButtonState state,
        ReleaseUpdateResult? update = null,
        ReleaseUpdateProgress? progress = null,
        ReleaseUpdateFailure? failure = null,
        bool manual = false,
        string? message = null,
        bool announce = false)
    {
        _releaseUpdateButtonState = state;
        var version = update?.Version ?? _availableReleaseUpdate?.Version;
        var presentation = GetReleaseUpdateButtonPresentation(state, version);
        var downloading = state == ReleaseUpdateButtonState.Downloading;
        var updateAvailable = state is ReleaseUpdateButtonState.Available
            or ReleaseUpdateButtonState.Downloading or ReleaseUpdateButtonState.Verifying;
        var iconName = downloading ? "close" : presentation.IconName;
        if (!string.Equals(_updateButtonIconName, iconName, StringComparison.Ordinal))
        {
            UpdateButton.Content = _iconCache.CreateElement(iconName, 20);
            _updateButtonIconName = iconName;
        }
        SetDesiredTrayTooltip(state, version, progress);
        UpdateButton.Foreground = state == ReleaseUpdateButtonState.Available
            ? ShellTheme.Brush("AccentBrush", ShellTheme.ForegroundColor)
            : ShellTheme.Brush("PrimaryTextBrush", ShellTheme.ForegroundColor);
        var buttonName = downloading
            ? "Cancel the Nativune update download"
            : state switch
            {
                ReleaseUpdateButtonState.Available => $"Update Nativune to {version ?? "the latest version"}",
                ReleaseUpdateButtonState.Checking => "Checking for Nativune updates",
                ReleaseUpdateButtonState.Verifying => "Checking the downloaded Setup",
                ReleaseUpdateButtonState.Launching => "Starting the verified Setup",
                ReleaseUpdateButtonState.Failed => "Retry checking for Nativune updates",
                _ => "Check for Nativune updates"
            };
        AutomationProperties.SetName(UpdateButton, buttonName);
        AutomationProperties.SetHelpText(UpdateButton, presentation.Tooltip);
        ToolTipService.SetToolTip(UpdateButton, presentation.Tooltip);
        UpdateButton.IsEnabled = (downloading || presentation.IsEnabled) && !_closing && !_disposed;
        var compactHelp = downloading ? "Cancel downloading the Nativune update." : presentation.Tooltip;
        CompactView.SetUpdate(downloading ? "close" : presentation.IconName,
            buttonName, compactHelp, UpdateButton.IsEnabled, updateAvailable);
        _nativeWindowServices?.SetCompactUpdateVisible(updateAvailable);

        if (!manual && state is not (ReleaseUpdateButtonState.Downloading
            or ReleaseUpdateButtonState.Verifying or ReleaseUpdateButtonState.Launching))
            return;
        if (state == ReleaseUpdateButtonState.Checking)
        {
            CloseUpdateInfo();
            StopCompactUpdateNoticeTimer();
            CompactView.SetUpdateProgress("Checking for Nativune updates…", false);
            return;
        }
        if (state is ReleaseUpdateButtonState.Downloading or ReleaseUpdateButtonState.Verifying)
        {
            StopCompactUpdateNoticeTimer();
            _taskbarErrorTimer?.Stop();
            UpdateInfoBar.Visibility = _compact || _fullscreen ? Visibility.Collapsed : Visibility.Visible;
            UpdateInfoBar.Severity = InfoBarSeverity.Informational;
            UpdateInfoBar.IconSource = new FontIconSource { Glyph = "\uE946" };
            UpdateInfoBar.IsClosable = false;
            UpdateInfoBar.IsOpen = true;
            UpdateInfoBar.Title = state == ReleaseUpdateButtonState.Verifying
                ? "Checking the download" : $"Downloading Nativune {version}";
            UpdateInfoBar.Message = state == ReleaseUpdateButtonState.Verifying
                ? $"Comparing with the checksum published for {version}…"
                : progress?.Phase == ReleaseUpdatePhase.Connecting
                    ? "Connecting to GitHub…"
                    : progress is { Total: > 0 } p
                        ? $"{ReleaseUpdater.FormatBytes(p.Bytes)} of {ReleaseUpdater.FormatBytes(p.Total)} · {(int)(100d * p.Bytes / p.Total)} %"
                        : "Connecting to GitHub…";
            UpdateProgressBar.Visibility = Visibility.Visible;
            UpdateProgressBar.IsIndeterminate = state == ReleaseUpdateButtonState.Verifying
                || progress?.Phase == ReleaseUpdatePhase.Connecting || progress is not { Total: > 0 };
            if (progress is { Total: > 0 } measured)
                UpdateProgressBar.Value = Math.Clamp(100d * measured.Bytes / measured.Total, 0, 100);
            SetInfoBarAction(state == ReleaseUpdateButtonState.Downloading ? "Cancel" : null,
                state == ReleaseUpdateButtonState.Downloading ? CancelUpdateDownload : null);
            CompactView.SetUpdateProgress(state == ReleaseUpdateButtonState.Verifying
                ? "Checking the downloaded Setup…" : message ?? "Downloading update · connecting…",
                announce && CompactUpdateSurfaceVisible);
            if (announce && !CompactUpdateSurfaceVisible)
                UpdateLiveAnnouncement.Text = message ?? (state == ReleaseUpdateButtonState.Verifying
                    ? "Checking the downloaded Setup." : "Downloading the Nativune update.");
            _taskbarControls?.SetProgressState(state == ReleaseUpdateButtonState.Verifying
                || progress?.Phase == ReleaseUpdatePhase.Connecting || progress is not { Total: > 0 }
                    ? TaskbarControls.TaskbarProgressState.Indeterminate
                    : TaskbarControls.TaskbarProgressState.Normal);
            if (state == ReleaseUpdateButtonState.Downloading && progress is { Total: > 0 } value)
                _taskbarControls?.SetProgress((ulong)Math.Max(0, value.Bytes), (ulong)value.Total);
            return;
        }

        _taskbarControls?.SetProgressState(TaskbarControls.TaskbarProgressState.NoProgress);
        CompactView.SetUpdateProgress(null, false);
        if (state == ReleaseUpdateButtonState.Available && manual && update is not null)
        {
            ShowUpdateInfo(InfoBarSeverity.Informational, $"Nativune {version} is available.",
                update.Delta is { } quick
                    ? $"Quick update is about {ReleaseUpdater.FormatBytes(quick.NeededBytes)}."
                    : $"Download is {ReleaseUpdater.FormatBytes(update.Size)}.", "See what's new and update",
                () => _ = ShowReleaseUpdatePromptAsync(update), true);
            CompactView.SetUpdateProgress($"Nativune {version} is available · Update button",
                CompactUpdateSurfaceVisible);
            ClearCompactUpdateNoticeAfter(TimeSpan.FromSeconds(8));
        }
        else if (state == ReleaseUpdateButtonState.UpToDate && manual)
        {
            var text = $"Nativune v{AppVersion.Number} is up to date.";
            ShowUpdateInfo(InfoBarSeverity.Informational, text, "Checked just now.", null, null, true);
            CloseUpdateInfoAfter(TimeSpan.FromSeconds(6));
            CompactView.SetUpdateProgress(text, CompactUpdateSurfaceVisible);
            ClearCompactUpdateNoticeAfter(TimeSpan.FromSeconds(5));
        }
        else if (state == ReleaseUpdateButtonState.NotInstalled && manual)
        {
            const string text = "Update checks are available only in installed Nativune builds.";
            ShowUpdateInfo(InfoBarSeverity.Informational, text, null, null, null, true);
            CompactView.SetUpdateProgress(text, CompactUpdateSurfaceVisible);
            ClearCompactUpdateNoticeAfter(TimeSpan.FromSeconds(5));
        }
        else if (state == ReleaseUpdateButtonState.Failed && manual)
        {
            var described = ReleaseUpdater.DescribeFailure(failure ?? update?.Failure
                ?? ReleaseUpdateFailure.InvalidMetadata, false, version, update?.HttpStatus,
                update?.RateLimitResetUtc);
            ShowUpdateInfo(InfoBarSeverity.Warning, described.Title, described.Message, null, null, true);
            CompactView.SetUpdateProgress($"{described.Title}: {described.Message}", CompactUpdateSurfaceVisible);
            ClearCompactUpdateNoticeAfter(TimeSpan.FromSeconds(30));
            AppLog.Write("update", $"{described.Title} (HTTP {update?.HttpStatus?.ToString() ?? "unknown"})");
        }
        else if (message is not null)
            CompactView.SetUpdateProgress(message, announce && CompactUpdateSurfaceVisible);
    }

    private void ShowUpdateInfo(InfoBarSeverity severity, string title, string? message,
        string? action, Action? actionHandler, bool closable)
    {
        _updateInfoCloseTimer?.Stop();
        UpdateInfoBar.Severity = severity;
        UpdateInfoBar.IconSource = severity == InfoBarSeverity.Informational
            ? new FontIconSource { Glyph = "\uE946" }
            : null;
        UpdateInfoBar.Title = title;
        UpdateInfoBar.Message = message;
        UpdateInfoBar.IsClosable = closable;
        UpdateInfoBar.IsOpen = true;
        UpdateProgressBar.Visibility = Visibility.Collapsed;
        SetInfoBarAction(action, actionHandler);
        UpdateInfoBar.Visibility = _compact || _fullscreen ? Visibility.Collapsed : Visibility.Visible;
        if (!CompactUpdateSurfaceVisible)
            UpdateLiveAnnouncement.Text = message is null ? title : $"{title}. {message}";
    }

    private void SetInfoBarAction(string? label, Action? handler)
    {
        if (string.Equals(_infoBarActionLabel, label, StringComparison.Ordinal)
            && _infoBarActionHandler == handler
            && (label is null && handler is null
                ? _infoBarActionButton is null
                : _infoBarActionButton is not null
                    && ReferenceEquals(UpdateInfoBar.ActionButton, _infoBarActionButton)))
            return;
        _infoBarActionLabel = label;
        _infoBarActionHandler = handler;
        if (label is null || handler is null)
        {
            _infoBarActionButton = null;
            UpdateInfoBar.ActionButton = null;
            return;
        }
        var button = new Button { Content = label };
        AutomationProperties.SetName(button, label);
        button.Click += (_, _) => _infoBarActionHandler?.Invoke();
        _infoBarActionButton = button;
        UpdateInfoBar.ActionButton = button;
    }

    private void CloseUpdateInfo()
    {
        _updateInfoCloseTimer?.Stop();
        UpdateInfoBar.IsOpen = false;
    }

    private void CloseUpdateInfoAfter(TimeSpan delay)
    {
        _updateInfoCloseTimer ??= _dispatcherQueue.CreateTimer();
        _updateInfoCloseTimer.Stop();
        _updateInfoCloseTimer.Interval = delay;
        _updateInfoCloseTimer.IsRepeating = false;
        if (!_updateCloseHandlerRegistered)
        {
            _updateInfoCloseTimer.Tick += (_, _) => CloseUpdateInfo();
            _updateCloseHandlerRegistered = true;
        }
        _updateInfoCloseTimer.Start();
    }
    private void ClearCompactUpdateNoticeAfter(TimeSpan delay)
    {
        _compactUpdateNoticeTimer ??= _dispatcherQueue.CreateTimer();
        _compactUpdateNoticeTimer.Stop();
        _compactUpdateNoticeTimer.Interval = delay;
        _compactUpdateNoticeTimer.IsRepeating = false;
        if (!_compactUpdateNoticeHandlerRegistered)
        {
            _compactUpdateNoticeTimer.Tick += (_, _) => CompactView.SetUpdateProgress(null, false);
            _compactUpdateNoticeHandlerRegistered = true;
        }
        _compactUpdateNoticeTimer.Start();
    }

    private void StopCompactUpdateNoticeTimer() => _compactUpdateNoticeTimer?.Stop();

    private void CancelUpdateDownload()
    {
        if (_releaseUpdateButtonState == ReleaseUpdateButtonState.Downloading)
            _updateDownloadCancellation?.Cancel();
    }

    private void ConfigureAutomaticReleaseUpdateChecks()
    {
        if (_settings.AutoCheckUpdates && !_closing && !_disposed)
        {
            if (!_releaseUpdateTimer.IsRunning)
                _releaseUpdateTimer.Start();
            if (_lastReleaseUpdateCheckUtc is not { } lastCheck
                || DateTimeOffset.UtcNow - lastCheck >= ReleaseUpdateCheckInterval)
                _ = CheckForReleaseUpdateAsync(manual: false);
            return;
        }

        _releaseUpdateTimer.Stop();
    }

    // Automatic checks are quiet: no Checking state and no banner. They only change the Update
    // button (and Compact/tray) when they get a definite answer; a failed automatic check is logged
    // and leaves what is shown, so a known available update stays marked.
    private async Task CheckForReleaseUpdateAsync(bool manual)
    {
        if (_releaseUpdateCheckRunning || _closing || _disposed || _lifetime.IsCancellationRequested
            || _releaseUpdateButtonState is ReleaseUpdateButtonState.Downloading
                or ReleaseUpdateButtonState.Verifying or ReleaseUpdateButtonState.Launching
            || (!manual && (!_settings.AutoCheckUpdates || _releaseUpdatePromptOpen)))
            return;

        _releaseUpdateCheckRunning = true;
        var previousCheckUtc = _lastReleaseUpdateCheckUtc;
        _lastReleaseUpdateCheckUtc = DateTimeOffset.UtcNow;
        // Every check restarts the countdown, so a resume catch-up (or a manual check) is not
        // followed by a tick left over from before it.
        if (_releaseUpdateTimer.IsRunning)
        {
            _releaseUpdateTimer.Stop();
            _releaseUpdateTimer.Start();
        }
        var previousState = _releaseUpdateButtonState;
        if (manual) ApplyUpdateFeedback(ReleaseUpdateButtonState.Checking, manual: true);
        try
        {
            var update = await ReleaseUpdater.CheckAsync(_root, _lifetime.Token);
            if (update.Status == ReleaseUpdateStatus.Cancelled)
            {
                _lastReleaseUpdateCheckUtc = previousCheckUtc;
                if (manual && !_closing && !_disposed)
                {
                    ApplyUpdateFeedback(previousState);
                    CompactView.SetUpdateProgress(null, false);
                }
                return;
            }
            if (_closing || _disposed || _lifetime.IsCancellationRequested)
                return;

            var state = update.Status switch
            {
                ReleaseUpdateStatus.Available when update.IsAvailable => ReleaseUpdateButtonState.Available,
                ReleaseUpdateStatus.NotInstalled => ReleaseUpdateButtonState.NotInstalled,
                ReleaseUpdateStatus.None => ReleaseUpdateButtonState.UpToDate,
                _ => ReleaseUpdateButtonState.Failed
            };
            if (!manual && state == ReleaseUpdateButtonState.Failed)
            {
                LogAutomaticUpdateFailure(update.Failure, update.HttpStatus);
                return;
            }
            _availableReleaseUpdate = update.IsAvailable ? update : null;
            ApplyUpdateFeedback(state, update, failure: update.Failure, manual: manual);
        }
        catch (OperationCanceledException) when (_closing || _disposed || _lifetime.IsCancellationRequested)
        {
        }
        catch (Exception)
        {
            if (!manual)
                LogAutomaticUpdateFailure(ReleaseUpdateFailure.InvalidMetadata, null);
            else if (!_closing && !_disposed)
            {
                _availableReleaseUpdate = null;
                ApplyUpdateFeedback(ReleaseUpdateButtonState.Failed,
                    failure: ReleaseUpdateFailure.InvalidMetadata, manual: true);
            }
        }
        finally
        {
            _releaseUpdateCheckRunning = false;
        }
    }

    // Automatic checks are skipped while an update dialog is open; run one that came due meanwhile.
    private void EndReleaseUpdatePrompt()
    {
        _releaseUpdatePromptOpen = false;
        ConfigureAutomaticReleaseUpdateChecks();
    }

    private static void LogAutomaticUpdateFailure(ReleaseUpdateFailure failure, int? httpStatus)
        => AppLog.Write("update", $"{failure} (HTTP {httpStatus?.ToString() ?? "unknown"})");

    private void OnUpdateButtonClick()
    {
        if (_closing || _disposed)
            return;
        if (_releaseUpdateButtonState == ReleaseUpdateButtonState.Downloading)
        {
            CancelUpdateDownload();
            return;
        }
        if (_releaseUpdateCheckRunning) return;
        if (_releaseUpdateButtonState == ReleaseUpdateButtonState.Available
            && _availableReleaseUpdate is { IsAvailable: true } update)
        {
            _ = ShowReleaseUpdatePromptAsync(update);
            return;
        }

        _ = CheckForReleaseUpdateAsync(manual: true);
    }

    private void SetReleaseUpdateButtonState(ReleaseUpdateButtonState state, string? version = null)
        => ApplyUpdateFeedback(state, version is null ? null : _availableReleaseUpdate);

    private async Task ShowReleaseUpdatePromptAsync(ReleaseUpdateResult update)
    {
        if (_releaseUpdatePromptOpen || _closing || _disposed || !update.IsAvailable)
            return;

        _releaseUpdatePromptOpen = true;
        Window? dialog = null;
        var choice = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        ReleaseUpdateResult? deltaFallback = null;
        try
        {
            if (!_skipUpdatePrompt)
            {
            var version = update.Version ?? "the latest version";
            var message = new TextBlock
            {
                Text = $"Nativune {version} is available ({DescribeDownloadSize(update)}). Update now downloads and checks the update, then closes Nativune and reopens it after the upgrade. Setup confirms the upgrade first; if you cancel, {update.InstalledVersion ?? "the current version"} stays installed and reopens.",
                TextWrapping = TextWrapping.Wrap,
            };
            AutomationProperties.SetName(message, "Nativune update information");

            var updateNow = new Button { Content = "Update now" };
            AutomationProperties.SetName(updateNow, "Update Nativune now");
            var later = new Button { Content = "Later" };
            AutomationProperties.SetName(later, "Install Nativune update later");
            var buttons = new StackPanel
            {
                Orientation = Orientation.Horizontal,
                HorizontalAlignment = HorizontalAlignment.Right,
                Spacing = 8,
            };
            buttons.Children.Add(updateNow);
            buttons.Children.Add(later);
            var playingNote = new TextBlock
            {
                Text = "Nativune keeps playing while the update downloads.",
                TextWrapping = TextWrapping.Wrap,
                Foreground = ShellTheme.Brush("SecondaryTextBrush", ShellTheme.ForegroundColor)
            };

            var changesHeading = new TextBlock
            {
                Text = update.InstalledVersion is { } installedVersion
                    ? $"Changes from {installedVersion} to {version}"
                    : $"Changes in {version}",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            };
            var changes = new TextBlock
            {
                Text = "Loading the changes in this update...",
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true,
            };
            var changesScroller = new ScrollViewer
            {
                Content = changes,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                IsTabStop = true,
                Padding = new Thickness(0, 0, 12, 0),
            };
            AutomationProperties.SetName(changesScroller, changesHeading.Text);

            var panel = new Grid { Padding = new Thickness(16), RowSpacing = 12 };
            panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(changesHeading, 1);
            Grid.SetRow(changesScroller, 2);
            Grid.SetRow(playingNote, 4);
            Grid.SetRow(buttons, 3);
            panel.Children.Add(message);
            panel.Children.Add(changesHeading);
            panel.Children.Add(changesScroller);
            panel.Children.Add(buttons);
            panel.Children.Add(playingNote);
            var updateDialog = CreateDialogWindow($"Nativune update available ({version})", panel, 560, 520);
            dialog = updateDialog;
            _ = LoadChangesAsync();

            async Task LoadChangesAsync()
            {
                var summary = await ReleaseUpdater.GetChangeSummaryAsync(update, _lifetime.Token);
                if (choice.Task.IsCompleted || _closing || _disposed)
                    return;
                // Version tags and section headings (lines that follow a blank line or a version tag) stand out;
                // bullets and paragraphs stay regular. The text is remote, so it is only ever shown as runs.
                changes.Inlines.Clear();
                var previous = "";
                foreach (var line in summary.Split('\n'))
                {
                    if (changes.Inlines.Count > 0) changes.Inlines.Add(new Microsoft.UI.Xaml.Documents.LineBreak());
                    var isVersion = line.Length > 1 && line[0] == 'v' && char.IsAsciiDigit(line[1]);
                    var isHeading = !isVersion && line.Length > 0 && !line.StartsWith("• ", StringComparison.Ordinal)
                        && (previous.Length == 0 || previous[0] == 'v' && previous.Length > 1 && char.IsAsciiDigit(previous[1]));
                    changes.Inlines.Add(new Microsoft.UI.Xaml.Documents.Run
                    {
                        Text = line,
                        FontWeight = isVersion ? Microsoft.UI.Text.FontWeights.Bold
                            : isHeading ? Microsoft.UI.Text.FontWeights.SemiBold : Microsoft.UI.Text.FontWeights.Normal,
                        FontSize = isVersion ? 16 : changes.FontSize,
                    });
                    previous = line;
                }
            }

            updateNow.Click += (_, _) =>
            {
                choice.TrySetResult(true);
                updateDialog.Close();
            };
            later.Click += (_, _) =>
            {
                choice.TrySetResult(false);
                updateDialog.Close();
            };
            updateDialog.Closed += (_, _) => choice.TrySetResult(false);
            updateDialog.Activate();
            updateNow.Focus(FocusState.Programmatic);

            if (!await choice.Task || _closing || _disposed || _lifetime.IsCancellationRequested)
                return;
            }
            else
                _skipUpdatePrompt = false;

            var useDelta = update.Delta is not null;
            var downloadTotal = update.Delta?.NeededBytes ?? update.Size;
            _updateDownloadCancellation?.Dispose();
            _updateDownloadCancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
            _updateProgressLastBytes = 0;
            _updateProgressLastTicks = Environment.TickCount64;
            _updateStartedTicks = _updateProgressLastTicks;
            _updateCurrentPhase = ReleaseUpdatePhase.Connecting;
            _updateSpeedEma = 0;
            _updateLastAnnouncedPercent = 0;
            _updateLastTextTicks = 0;
            ApplyUpdateFeedback(ReleaseUpdateButtonState.Downloading, update,
                new ReleaseUpdateProgress(ReleaseUpdatePhase.Connecting, 0, downloadTotal),
                message: "Downloading update · connecting…", announce: true);
            var cancellation = _updateDownloadCancellation!;
            var progress = new Progress<ReleaseUpdateProgress>(value =>
            {
                if (_closing || _disposed || cancellation.IsCancellationRequested) return;
                if (value.Phase == ReleaseUpdatePhase.Verifying)
                {
                    var phaseChanged = _updateCurrentPhase != value.Phase;
                    _updateCurrentPhase = value.Phase;
                    ApplyUpdateFeedback(ReleaseUpdateButtonState.Verifying, update, value,
                        message: "Checking the downloaded Setup…", announce: phaseChanged);
                    return;
                }
                var now = Environment.TickCount64;
                var elapsedMs = Math.Max(1, now - _updateProgressLastTicks);
                if (value.Bytes > _updateProgressLastBytes)
                {
                    var instant = (value.Bytes - _updateProgressLastBytes) * 1000d / elapsedMs;
                    _updateSpeedEma = _updateSpeedEma == 0 ? instant : _updateSpeedEma * 0.75 + instant * 0.25;
                    _updateProgressLastBytes = value.Bytes;
                    _updateProgressLastTicks = now;
                }
                var percent = value.Total > 0 ? (int)(100d * value.Bytes / value.Total) : 0;
                var phaseChangedNow = _updateCurrentPhase != value.Phase;
                _updateCurrentPhase = value.Phase;
                var boundary = percent >= 25 && percent / 25 > _updateLastAnnouncedPercent / 25;
                var announce = phaseChangedNow || boundary;
                if (boundary) _updateLastAnnouncedPercent = percent / 25 * 25;
                var compactProgress = _updateSpeedEma > 0
                    ? $"Downloading update · {percent} % · {ReleaseUpdater.FormatSpeed(_updateSpeedEma)}"
                    : $"Downloading update · {percent} %";
                if (announce)
                {
                    if (!CompactUpdateSurfaceVisible)
                        UpdateLiveAnnouncement.Text = compactProgress;
                    CompactView.SetUpdateProgress(compactProgress, CompactUpdateSurfaceVisible);
                }
                if (now - _updateLastTextTicks < 250) return;
                _updateLastTextTicks = now;
                var parts = new List<string>
                {
                    $"{ReleaseUpdater.FormatBytes(value.Bytes)} of {ReleaseUpdater.FormatBytes(value.Total)}",
                    $"{percent} %"
                };
                if (_updateSpeedEma > 0)
                    parts.Add(ReleaseUpdater.FormatSpeed(_updateSpeedEma));
                if (now - _updateStartedTicks >= 2000 && _updateSpeedEma > 0)
                    parts.Add(ReleaseUpdater.FormatEta(TimeSpan.FromSeconds(
                        Math.Max(0, value.Total - value.Bytes) / _updateSpeedEma)) ?? string.Empty);
                ApplyUpdateFeedback(ReleaseUpdateButtonState.Downloading, update, value,
                    message: compactProgress, announce: false);
                UpdateInfoBar.Message = string.Join(" · ", parts.Where(part => part.Length > 0));
            });
            var downloaded = useDelta
                ? await ReleaseUpdater.DownloadDeltaAsync(_root, update, progress, cancellation.Token)
                : await ReleaseUpdater.DownloadAsync(_root, update, progress, cancellation.Token);
            if (_closing || _disposed || _lifetime.IsCancellationRequested) return;
            if (downloaded.Status == ReleaseUpdateStatus.Cancelled
                || cancellation.IsCancellationRequested && downloaded.IsAvailable)
            {
                ApplyUpdateFeedback(ReleaseUpdateButtonState.Available, update,
                    message: "Update download cancelled.");
                _taskbarControls?.SetProgressState(TaskbarControls.TaskbarProgressState.NoProgress);
                ShowUpdateInfo(InfoBarSeverity.Informational, "Update download cancelled.",
                    "Nothing was changed. Click Update when you want to try again.", null, null, true);
                CloseUpdateInfoAfter(TimeSpan.FromSeconds(6));
                CompactView.SetUpdateProgress("Update download cancelled.", CompactUpdateSurfaceVisible);
                ClearCompactUpdateNoticeAfter(TimeSpan.FromSeconds(5));
                return;
            }
            if (useDelta && !downloaded.IsAvailable)
            {
                AppLog.Write("update", $"quick update failed before handoff: {downloaded.Failure}");
                deltaFallback = update;
                return;
            }
            if (!downloaded.IsAvailable || (!useDelta && downloaded.SetupPath is null))
            {
                ShowUpdateDownloadFailure(downloaded, update);
                return;
            }

            ApplyUpdateFeedback(ReleaseUpdateButtonState.Launching, update,
                message: "Setup is starting. Nativune will close now and reopen after the upgrade.");
            ShowUpdateInfo(InfoBarSeverity.Success, "Update verified",
                $"Setup is starting. Nativune will close now and reopen as {update.Version} when the upgrade finishes.",
                null, null, false);
            CompactView.SetUpdateProgress(
                $"Update verified. Setup is starting and Nativune will reopen as {update.Version}.",
                CompactUpdateSurfaceVisible);
            var launched = useDelta
                ? await ReleaseUpdater.LaunchDeltaSetupAsync(update, _root, Environment.ProcessId, _lifetime.Token)
                : await ReleaseUpdater.LaunchVerifiedSetupAsync(downloaded, _root, Environment.ProcessId, _lifetime.Token);
            if (!launched.Started && useDelta)
            {
                AppLog.Write("update", $"quick update handoff failed (Win32 {launched.Win32Error?.ToString() ?? "none"})");
                ReleaseUpdater.TryDeleteDeltaDirectory(_root);
                deltaFallback = update;
                return;
            }
            if (!launched.Started)
            {
                ShowUpdateDownloadFailure(ReleaseUpdateResult.ErrorResult(ReleaseUpdateFailure.LaunchFailed),
                    update, launched.Win32Error);
                return;
            }

            await ShutdownAsync();
        }
        catch (OperationCanceledException) when (_closing || _disposed || _lifetime.IsCancellationRequested)
        {
        }
        catch (Exception)
        {
            if (!_closing && !_disposed)
                ShowUpdateDownloadFailure(ReleaseUpdateResult.ErrorResult(ReleaseUpdateFailure.LaunchFailed), update);
            try { dialog?.Close(); }
            catch (Exception) { }
        }
        finally
        {
            _updateDownloadCancellation?.Dispose();
            _updateDownloadCancellation = null;
            _skipUpdatePrompt = false;
            EndReleaseUpdatePrompt();
            if (deltaFallback is not null && !_closing && !_disposed && !_lifetime.IsCancellationRequested)
                _ = OfferFullSetupAfterQuickUpdateFailureAsync(deltaFallback);
        }
    }

    private static string DescribeDownloadSize(ReleaseUpdateResult update)
        => update.Delta is { } delta
            ? $"quick update about {ReleaseUpdater.FormatBytes(delta.NeededBytes)}; full Setup is {ReleaseUpdater.FormatBytes(update.Size)}"
            : $"download is {ReleaseUpdater.FormatBytes(update.Size)}";

    // A quick update that failed before handoff never falls back silently: the user decides on the full download.
    private async Task OfferFullSetupAfterQuickUpdateFailureAsync(ReleaseUpdateResult update)
    {
        if (_releaseUpdatePromptOpen || _closing || _disposed) return;
        var full = update with { Delta = null };
        if (_availableReleaseUpdate?.Version == update.Version)
            _availableReleaseUpdate = full;
        ApplyUpdateFeedback(ReleaseUpdateButtonState.Available, full);
        var size = ReleaseUpdater.FormatBytes(full.Size);
        ShowUpdateInfo(InfoBarSeverity.Warning, "Quick update failed",
            $"Nothing was changed. You can download the full installer ({size}) instead.",
            "Download full installer", () => _ = RetryUpdateDownloadAsync(full), true);

        _releaseUpdatePromptOpen = true;
        var accepted = false;
        try
        {
            var choice = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            var message = new TextBlock
            {
                Text = $"The quick update to Nativune {full.Version} couldn't be completed. Nothing was changed. Download the full installer ({size}) instead?",
                TextWrapping = TextWrapping.Wrap,
            };
            AutomationProperties.SetName(message, "Quick update failed");
            var download = new Button { Content = $"Download full installer ({size})" };
            AutomationProperties.SetName(download, $"Download the full Nativune installer, {size}");
            var notNow = new Button { Content = "Not now" };
            AutomationProperties.SetName(notNow, "Do not download the full installer now");
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 8 };
            buttons.Children.Add(download);
            buttons.Children.Add(notNow);
            var panel = new Grid { Padding = new Thickness(16), RowSpacing = 12 };
            panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            Grid.SetRow(buttons, 1);
            panel.Children.Add(message);
            panel.Children.Add(buttons);
            var dialog = CreateDialogWindow("Quick update failed", panel, 480, 220);
            download.Click += (_, _) => { choice.TrySetResult(true); dialog.Close(); };
            notNow.Click += (_, _) => { choice.TrySetResult(false); dialog.Close(); };
            dialog.Closed += (_, _) => choice.TrySetResult(false);
            dialog.Activate();
            download.Focus(FocusState.Programmatic);
            accepted = await choice.Task;
        }
        catch (Exception)
        {
        }
        finally
        {
            EndReleaseUpdatePrompt();
        }
        if (accepted && !_closing && !_disposed && !_lifetime.IsCancellationRequested)
            await RetryUpdateDownloadAsync(full);
    }

    private async Task RetryUpdateDownloadAsync(ReleaseUpdateResult update)
    {
        if (_releaseUpdatePromptOpen || _closing || _disposed) return;
        _skipUpdatePrompt = true;
        await ShowReleaseUpdatePromptAsync(update);
    }

    private void ShowUpdateDownloadFailure(
        ReleaseUpdateResult result, ReleaseUpdateResult update, int? launchWin32Error = null)
    {
        var failure = result.Failure == ReleaseUpdateFailure.None
            ? ReleaseUpdateFailure.InvalidMetadata : result.Failure;
        var description = ReleaseUpdater.DescribeFailure(failure, true, update.Version,
            result.HttpStatus, result.RateLimitResetUtc,
            downloadBytes: update.Size, updatesPath: Path.Combine(_root, "updates"));
        var setupPath = Path.Combine(_root, "updates", "Nativune-Setup.exe");
        var message = failure == ReleaseUpdateFailure.LaunchFailed
            ? launchWin32Error is { } win32Error
                ? $"Windows refused to start Nativune Setup (error {win32Error}). The verified Setup is saved at {setupPath}."
                : $"Nativune Setup could not be started. The verified Setup is saved at {setupPath}."
            : description.Message;
        ApplyUpdateFeedback(ReleaseUpdateButtonState.Available, update);
        ShowUpdateInfo(InfoBarSeverity.Error, description.Title, message,
            "Try again", () => _ = RetryUpdateDownloadAsync(update), true);
        CompactView.SetUpdateProgress($"{description.Title}: {message}", CompactUpdateSurfaceVisible);
        ClearCompactUpdateNoticeAfter(TimeSpan.FromSeconds(30));
        _taskbarControls?.SetProgressState(TaskbarControls.TaskbarProgressState.Error);
        _taskbarErrorTimer ??= _dispatcherQueue.CreateTimer();
        _taskbarErrorTimer.Stop();
        _taskbarErrorTimer.Interval = TimeSpan.FromSeconds(5);
        _taskbarErrorTimer.IsRepeating = false;
        if (!_taskbarErrorHandlerRegistered)
        {
            _taskbarErrorTimer.Tick += (_, _) =>
                _taskbarControls?.SetProgressState(TaskbarControls.TaskbarProgressState.NoProgress);
            _taskbarErrorHandlerRegistered = true;
        }
        _taskbarErrorTimer.Start();
        AppLog.Write("update", $"{failure} (HTTP {result.HttpStatus?.ToString() ?? "unknown"})");
        if (_tray?.IsVisible == true && _appWindow?.IsVisible == false)
            _tray.ShowBalloon("Nativune update failed", description.Title);
    }


    private void ShowUpdateOutcomeOnStartup()
    {
        var outcome = ReleaseUpdater.TryReadUpdateOutcome(_root);
        if (outcome is null) return;
        var version = $"v{outcome.ToVersion}";
        if (outcome.Status == "success")
        {
            var from = outcome.FromVersion is { Length: > 0 } old ? $"v{old}" : null;
            ShowUpdateInfo(InfoBarSeverity.Success,
                $"Nativune was updated to {version}",
                from is null ? null : $"Updated from {from}.", "What's new",
                () => _ = ShowWhatsNewAsync(version, from), true);
            CompactView.SetUpdateProgress(
                $"Updated to Nativune {version} · What's new in More", CompactUpdateSurfaceVisible);
            ClearCompactUpdateNoticeAfter(TimeSpan.FromSeconds(30));
            _pendingWhatsNewVersion = version;
            _pendingWhatsNewFromVersion = from;
            CompactView.SetWhatsNew($"What's new in {version}");
            _sessionTrayTooltip = $"Nativune {version}";
            SetDesiredTrayTooltip(_releaseUpdateButtonState, _availableReleaseUpdate?.Version, null);
            AppLog.Write("update",
                $"updated {outcome.FromVersion ?? "unknown"} → {outcome.ToVersion} (setup exit {outcome.ExitCode})");
        }
        else if (outcome.Status is "failed" or "cancelled")
        {
            var message = string.IsNullOrWhiteSpace(outcome.Message)
                ? "Setup did not complete the update."
                : outcome.Message;
            if (outcome.FromVersion is { Length: > 0 } installed)
                message += $" Nativune v{installed} is unchanged.";
            ShowUpdateInfo(InfoBarSeverity.Warning,
                $"The update to {version} didn't finish", message,
                "Try again", () => _ = CheckForReleaseUpdateAsync(manual: true), true);
            CompactView.SetUpdateProgress(
                $"The update to {version} didn't finish: {message}", CompactUpdateSurfaceVisible);
            ClearCompactUpdateNoticeAfter(TimeSpan.FromSeconds(30));
            AppLog.Write("update",
                $"{outcome.Status} {outcome.ToVersion} (setup exit {outcome.ExitCode})");
        }
        else if (outcome.Status == "installed")
            AppLog.Write("update", $"installed {outcome.ToVersion} (setup exit {outcome.ExitCode})");
    }

    private async Task ShowWhatsNewAsync(string version, string? fromVersion)
    {
        if (_releaseUpdatePromptOpen || _closing || _disposed) return;
        _releaseUpdatePromptOpen = true;
        try
        {
            var update = new ReleaseUpdateResult(ReleaseUpdateStatus.Available, version,
                null, null, 1, null, null) { InstalledVersion = fromVersion };
            var heading = new TextBlock
            {
                Text = fromVersion is null ? $"Changes in {version}" : $"Changes from {fromVersion} to {version}",
                FontWeight = Microsoft.UI.Text.FontWeights.SemiBold
            };
            var changes = new TextBlock
            {
                Text = await ReleaseUpdater.GetChangeSummaryAsync(update, _lifetime.Token),
                TextWrapping = TextWrapping.Wrap,
                IsTextSelectionEnabled = true
            };
            var close = new Button { Content = "Close" };
            AutomationProperties.SetName(close, "Close What's new");
            var panel = new Grid { Padding = new Thickness(16), RowSpacing = 12 };
            panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
            panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
            var scroller = new ScrollViewer
            {
                Content = changes,
                VerticalScrollBarVisibility = ScrollBarVisibility.Auto,
                HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled,
                IsTabStop = true
            };
            Grid.SetRow(heading, 0);
            Grid.SetRow(scroller, 1);
            Grid.SetRow(close, 2);
            close.HorizontalAlignment = HorizontalAlignment.Right;
            panel.Children.Add(heading);
            panel.Children.Add(scroller);
            panel.Children.Add(close);
            var dialog = CreateDialogWindow($"What's new in {version}", panel, 560, 460);
            close.Click += (_, _) => dialog.Close();
            dialog.Activate();
            close.Focus(FocusState.Programmatic);
        }
        catch (OperationCanceledException) { }
        catch (Exception) { }
        finally { EndReleaseUpdatePrompt(); }
    }
}
