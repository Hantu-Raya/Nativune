using Microsoft.UI;
using UiDispatcherQueue = Microsoft.UI.Dispatching.DispatcherQueue;
using UiDispatcherQueueTimer = Microsoft.UI.Dispatching.DispatcherQueueTimer;
using UiWindowId = Microsoft.UI.WindowId;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Input;
using Microsoft.Web.WebView2.Core;
using Microsoft.Win32;
using Microsoft.Win32.SafeHandles;
using System.ComponentModel;
using System.Drawing;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using System.Text.Json;
using Windows.Graphics;
using VirtualKey = Windows.System.VirtualKey;
using Windows.UI.Core;
using WinRT.Interop;

namespace Nativune;

internal static class WebHost
{
    private const string InitialUri = "https://music.youtube.com/";

    public static int Run(string root)
    {
        AppLog.Start(root);
        Exception? startupFailure = null;
        var exitCode = 0;
        var thread = new Thread(() =>
        {
            try
            {
                using var instance = SingleInstance.Acquire(root);
                if (instance is null)
                    return;

                WebHostWindow? window = null;
                ShellApplication.Run(() =>
                {
                    window = new WebHostWindow(root, InitialUri);
                    instance.StartListening(window.RequestActivation);
                    window.Activate();
                });
                exitCode = window?.ExitCode ?? 0;
            }
            catch (Exception ex)
            {
                startupFailure = ex;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();

        if (startupFailure is not null)
        {
            AppLog.Write("crash", startupFailure.ToString());
            Console.Error.WriteLine("Web host could not start. Check the local runtime and whether this profile is already in use.");
            return 1;
        }

        return exitCode;
    }
}

internal static class WebHostPolicy
{
    private const string MusicHost = "music.youtube.com";
    private const string AccountsHost = "accounts.google.com";

    internal static bool IsAllowedMainFrameNavigation(Uri uri)
    {
        if (!uri.IsAbsoluteUri || uri.Scheme != Uri.UriSchemeHttps || !uri.IsDefaultPort || uri.UserInfo.Length != 0)
            return false;

        return uri.Host.Equals(MusicHost, StringComparison.OrdinalIgnoreCase)
            || uri.Host.Equals("www.youtube.com", StringComparison.OrdinalIgnoreCase)
            || uri.Host.Equals(AccountsHost, StringComparison.OrdinalIgnoreCase)
            || uri.Host.Equals("accounts.google.com.my", StringComparison.OrdinalIgnoreCase)
            || uri.Host.Equals("accounts.youtube.com", StringComparison.OrdinalIgnoreCase);
    }
}

internal enum ReleaseUpdateButtonState
{
    NotChecked,
    NotInstalled,
    Checking,
    Available,
    UpToDate,
    Failed,
    Downloading,
    Verifying,
    Launching
}

internal readonly record struct ReleaseUpdateButtonPresentation(
    string IconName, string Tooltip, bool IsEnabled);


public sealed partial class WebHostWindow : Window
{
    // Keep equal to Setup's floor (src/Nativune.Installer/Prerequisites.cs); scripts/installer-fixture.ps1 checks this.
    private const string MinimumWebView2RuntimeVersionText = "152.0.4191.53";
    private const string WebView2RuntimeDownloadUrl = "https://developer.microsoft.com/microsoft-edge/webview2/";
    private static readonly Version MinimumWebView2RuntimeVersion = new(152, 0, 4191, 53);
    private const uint WmClose = 0x0010;
    private const uint WmCommand = 0x0111;
    private const uint WmPowerBroadcast = 0x0218;
    private const uint WmHotKey = 0x0312;
    private const uint WmDisplayChange = 0x007e;
    private const uint WmSettingChange = 0x001a;
    private const uint WmThemeChanged = 0x031a;
    private const uint WmGetMinMaxInfo = 0x0024;
    private const uint PbtApmsuspend = 4;
    private const uint PbtApmresume = 7;
    private const uint PbtApmresumesuspend = 18;
    private const int DefaultDpi = 96;
    private const string MemoryBrowserArguments =
        "--enable-low-end-device-mode " +
        "--process-per-site " +
        "--renderer-process-limit=2 " +
        "--force_low_power_gpu " +
        "--disk-cache-size=67108864 " +
        "--skia-resource-cache-limit-mb=64 " +
        "--enable-features=CalculateNativeWinOcclusion,msWebView2SimulateMemoryPressureWhenInactive";
    private const string KeepRunningInBackgroundArguments =
        "--disable-background-timer-throttling " +
        "--disable-renderer-backgrounding " +
        "--disable-backgrounding-occluded-windows";

    internal static string BrowserArguments(bool sleepInBackground)
        => sleepInBackground
            ? MemoryBrowserArguments
            : MemoryBrowserArguments + " " + KeepRunningInBackgroundArguments;

    private readonly string _root;
    private readonly string _initialUri;
    private readonly bool _initializeBrowser;
    private readonly UiDispatcherQueue _dispatcherQueue;
    private readonly NativeIconCache _iconCache = new();
    private readonly CancellationTokenSource _lifetime = new();
    private readonly CancellationTokenSource _saveCancellation = new();
    private readonly UiDispatcherQueueTimer _saveTimer;
    private readonly UiDispatcherQueueTimer _releaseUpdateTimer;
    private ShellSettings _settings;
    private ShellSettings? _pendingSettings;
    private Task _saveTask = Task.CompletedTask;
    private SleepDeadline? _sleep;
    private PlayerControls? _playerControls;
    private TaskbarControls? _taskbarControls;
    private NativeTrayIcon? _tray;
    private NativeWindowServices? _nativeWindowServices;
    private CoreWebView2Environment? _environment;
    private NativeBrowserHost? _browserHost;
    private SettingsDialog? _settingsDialog;
    private Task? _shutdownTask;
    private Task? _initializationTask;
    private Task? _lateBrowserCleanupTask;
    private static readonly TimeSpan InitializationShutdownTimeout = TimeSpan.FromSeconds(5);
    private static readonly TimeSpan ReleaseUpdateCheckInterval = TimeSpan.FromHours(24);
    private static readonly TimeSpan LateCleanupShutdownTimeout = TimeSpan.FromSeconds(5);
    private AppWindow? _appWindow;
    private OverlappedPresenter? _presenter;
    private UiWindowId _windowId;
    private bool _nativeWindowReady;
    private bool _loaded;
    private bool _windowClosed;
    private bool _closeReady;
    private bool _disposed;
    private bool _browserFailed;
    private bool _navigationFailed;
    private bool _configuringPrivacy = true;
    private bool _playerBusy;
    private bool _playerSuspended;
    private bool _closing;
    private bool _fullscreen;
    private bool _compact;
    private bool _compactWhenReady;
    private bool _compactStartupPending;
    private bool _compactResumeAfterAccount;
    private int _compactModeGeneration;
    private bool _fullMaximized;
    private bool _windowMaximized;
    private bool _lastMaximized;
    private bool _settingsDialogOpen;
    private bool _shortcutsEnabled;
    private SessionShortcuts? _sessionShortcuts;
    private ReleaseUpdateResult? _availableReleaseUpdate;
    private DateTimeOffset? _lastReleaseUpdateCheckUtc;
    private ReleaseUpdateButtonState _releaseUpdateButtonState = ReleaseUpdateButtonState.NotChecked;
    private bool _releaseUpdateCheckRunning;
    private bool _releaseUpdatePromptOpen;
    private bool _skipUpdatePrompt;
    private readonly HashSet<Window> _ownedDialogs = new();
    private bool _timerDialogOpen;
    private ulong? _activeNavigation;
    private ulong? _blockedNavigation;
    private string? _privacySetupUri;
    private string? _settingsWarning;
    private string _statusDetailsText = string.Empty;
    private bool _statusIsError;
    private int _activationPending;
    private CancellationTokenSource? _updateDownloadCancellation;
    private readonly UiDispatcherQueueTimer _gcOnHideTimer;
    private readonly UiDispatcherQueueTimer _trimOnHideTimer;
    private bool? _windowWasVisible;
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
    private DrawingBounds _fullBounds;
    private bool _updateCloseHandlerRegistered;
    private ReleaseUpdatePhase? _updateCurrentPhase;
    private DrawingBounds _windowBounds;
    private int _fullDpi = DefaultDpi;
    private bool _appearanceRefreshPending;
    private static readonly int TaskbarCreated = RegisterWindowMessage("TaskbarCreated");
    private static readonly int TaskbarButtonCreated = RegisterWindowMessage("TaskbarButtonCreated");

    private MenuFlyout _moreFlyout = null!;
    private MenuFlyout _timerFlyout = null!;
    private MenuFlyoutItem _retryItem = null!;
    private MenuFlyoutItem _playPauseItem = null!;
    private MenuFlyoutItem _playItem = null!;
    private MenuFlyoutItem _pauseItem = null!;
    private MenuFlyoutItem _previousItem = null!;
    private MenuFlyoutItem _nextItem = null!;
    private ToggleMenuFlyoutItem _shortcutsItem = null!;
    private MenuFlyoutItem _zoomInItem = null!;
    private MenuFlyoutItem _zoomOutItem = null!;
    private MenuFlyoutItem _zoomResetItem = null!;
    private MenuFlyoutItem _fullscreenItem = null!;
    private MenuFlyoutItem _compactItem = null!;
    private ToggleMenuFlyoutItem _topmostItem = null!;
    private ToggleMenuFlyoutItem _trayItem = null!;
    private ToggleMenuFlyoutItem _restoreItem = null!;
    private MenuFlyoutItem _setTimerItem = null!;
    private MenuFlyoutItem _cancelTimerItem = null!;
    private MenuFlyoutItem _statusDetailsItem = null!;
    private MenuFlyoutItem _settingsItem = null!;
    private MenuFlyoutItem _quitItem = null!;
    private MenuFlyoutItem _versionItem = null!;

    public int ExitCode { get; private set; }
    public nint NativeHandle { get; private set; }
    public bool IsCompact => _compact;
    internal bool IsTimerDialogOpenForChecks => _timerDialogOpen;
    internal Window? TimerDialogForChecks
        => _ownedDialogs.FirstOrDefault(dialog => dialog.Title == "Pause playback in...");
    private readonly struct DrawingBounds
    {
        internal DrawingBounds(int x, int y, int width, int height)
        {
            X = x;
            Y = y;
            Width = width;
            Height = height;
        }

        internal int X { get; }
        internal int Y { get; }
        internal int Width { get; }
        internal int Height { get; }
        internal bool IsValid => Width > 0 && Height > 0;
    }

    public WebHostWindow(string root, string initialUri, bool initializeBrowser = true)
    {
        _root = Path.GetFullPath(root);
        _initialUri = initialUri;
        _initializeBrowser = initializeBrowser;
        _settings = ShellSettings.Load(_root, out _settingsWarning);
        InitializeComponent();

        _dispatcherQueue = UiDispatcherQueue.GetForCurrentThread()
            ?? throw new InvalidOperationException("Web host requires a dispatcher queue.");
        _saveTimer = _dispatcherQueue.CreateTimer();
        _saveTimer.Interval = TimeSpan.FromSeconds(1);
        _saveTimer.IsRepeating = false;
        _saveTimer.Tick += (_, _) => CaptureSettings();
        _releaseUpdateTimer = _dispatcherQueue.CreateTimer();
        _releaseUpdateTimer.Interval = ReleaseUpdateCheckInterval;
        _releaseUpdateTimer.IsRepeating = true;
        _releaseUpdateTimer.Tick += (_, _) => _ = CheckForReleaseUpdateAsync(manual: false);
        _gcOnHideTimer = _dispatcherQueue.CreateTimer();
        _gcOnHideTimer.Interval = TimeSpan.FromSeconds(3);
        _gcOnHideTimer.IsRepeating = false;
        _gcOnHideTimer.Tick += (_, _) =>
        {
            if (WindowIsVisible || _closing || _disposed) return;
            GC.Collect(2, GCCollectionMode.Aggressive, blocking: true, compacting: true);
        };
        _trimOnHideTimer = _dispatcherQueue.CreateTimer();
        _trimOnHideTimer.Interval = TimeSpan.FromSeconds(5);
        _trimOnHideTimer.IsRepeating = false;
        _trimOnHideTimer.Tick += (_, _) =>
        {
            if (WindowIsVisible || _closing || _disposed) return;
            if (!SetProcessWorkingSetSizeEx(GetCurrentProcess(), (nint)(-1), (nint)(-1), 0))
                Console.Error.WriteLine($"Hidden host working-set trim failed: {new Win32Exception(Marshal.GetLastWin32Error()).Message}");
        };
        BenchInitialize();

        TryInitializeNativeWindow();
        BuildMenus();
        WireSurface();
        InitializeOutputAudio();
        InitializeCompactSurface();
        ApplyAppearance();
        CompactButton.Click += (_, _) => ToggleCompact();
        _sleep = new SleepDeadline(OnTimerExpired, SynchronizationContext.Current!);

        RootGrid.Loaded += OnLoaded;
        Closed += OnClosed;
        AppWindowChanged += OnAppWindowChanged;
    }

    private event EventHandler? AppWindowChanged;

    private void OnLoaded(object sender, RoutedEventArgs args)
    {
        if (_loaded) return;
        _loaded = true;
        TryInitializeNativeWindow();
        UpdateWindowVisibilityPolicy();
        BenchWindowShown();
        if (_settings.TrayEnabled)
            SetTrayEnabled(true);
        ApplyCompactSurface();
        if (_settings.StartCompact)
        {
            _compactStartupPending = true;
            SetCompact(true);
        }
        if (_initializeBrowser)
            _initializationTask = InitializeAsync();
        ConfigureAutomaticReleaseUpdateChecks();
        if (ReleaseUpdater.IsInstalledBuild(_root))
        {
            ShowUpdateOutcomeOnStartup();
            StartDownloadedSetupCleanup();
        }
    }

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
        {
            if (state == ReleaseUpdateButtonState.Failed)
                AppLog.Write("update", $"{failure ?? update?.Failure ?? ReleaseUpdateFailure.InvalidMetadata} (HTTP {update?.HttpStatus?.ToString() ?? "unknown"})");
            return;
        }
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
                $"Download is {ReleaseUpdater.FormatBytes(update.Size)}.", "See what's new and update",
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

    private async Task CheckForReleaseUpdateAsync(bool manual)
    {
        if (_releaseUpdateCheckRunning || _closing || _disposed || _lifetime.IsCancellationRequested
            || _releaseUpdateButtonState is ReleaseUpdateButtonState.Downloading
                or ReleaseUpdateButtonState.Verifying or ReleaseUpdateButtonState.Launching
            || (!manual && !_settings.AutoCheckUpdates))
            return;

        _releaseUpdateCheckRunning = true;
        var previousCheckUtc = _lastReleaseUpdateCheckUtc;
        _lastReleaseUpdateCheckUtc = DateTimeOffset.UtcNow;
        var previousState = _releaseUpdateButtonState;
        ApplyUpdateFeedback(ReleaseUpdateButtonState.Checking, manual: manual);
        try
        {
            var update = await ReleaseUpdater.CheckAsync(_root, _lifetime.Token);
            if (update.Status == ReleaseUpdateStatus.Cancelled)
            {
                _lastReleaseUpdateCheckUtc = previousCheckUtc;
                if (!_closing && !_disposed)
                {
                    ApplyUpdateFeedback(previousState);
                    CompactView.SetUpdateProgress(null, false);
                }
                return;
            }
            if (_closing || _disposed || _lifetime.IsCancellationRequested)
                return;

            _availableReleaseUpdate = update.IsAvailable ? update : null;
            var state = update.Status switch
            {
                ReleaseUpdateStatus.Available when update.IsAvailable => ReleaseUpdateButtonState.Available,
                ReleaseUpdateStatus.NotInstalled => ReleaseUpdateButtonState.NotInstalled,
                ReleaseUpdateStatus.None => ReleaseUpdateButtonState.UpToDate,
                _ => ReleaseUpdateButtonState.Failed
            };
            ApplyUpdateFeedback(state, update, failure: update.Failure, manual: manual);

        }
        catch (OperationCanceledException) when (_closing || _disposed || _lifetime.IsCancellationRequested)
        {
        }
        catch (Exception)
        {
            if (!_closing && !_disposed)
            {
                _availableReleaseUpdate = null;
                ApplyUpdateFeedback(ReleaseUpdateButtonState.Failed,
                    failure: ReleaseUpdateFailure.InvalidMetadata, manual: manual);
            }
        }
        finally
        {
            _releaseUpdateCheckRunning = false;
        }
    }

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
        try
        {
            if (!_skipUpdatePrompt)
            {
            var version = update.Version ?? "the latest version";
            var message = new TextBlock
            {
                Text = $"Nativune {version} is available ({ReleaseUpdater.FormatBytes(update.Size)}). Update now downloads and checks Setup, then closes Nativune and reopens it after the upgrade. Setup confirms the upgrade first; if you cancel, {update.InstalledVersion ?? "the current version"} stays installed and reopens.",
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
                new ReleaseUpdateProgress(ReleaseUpdatePhase.Connecting, 0, update.Size),
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
            var downloaded = await ReleaseUpdater.DownloadAsync(
                _root, update, progress, cancellation.Token);
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
            if (!downloaded.IsAvailable || downloaded.SetupPath is null)
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
            var launched = await ReleaseUpdater.LaunchVerifiedSetupAsync(
                downloaded, _root, Environment.ProcessId, _lifetime.Token);
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
            _releaseUpdatePromptOpen = false;
        }
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
        finally { _releaseUpdatePromptOpen = false; }
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        _windowClosed = true;
        if (!_closeReady && !_disposed)
            _ = ShutdownAsync();
    }

    private void TryInitializeNativeWindow()
    {
        if (_nativeWindowReady || _disposed) return;
        try
        {
            NativeHandle = WindowNative.GetWindowHandle(this);
            if (NativeHandle == 0) return;
            _windowId = Win32Interop.GetWindowIdFromWindow(NativeHandle);
            _appWindow = AppWindow.GetFromWindowId(_windowId)
                ?? throw new InvalidOperationException("The Web host AppWindow could not be resolved.");
            AppIcon.Apply(_appWindow);
            _presenter = _appWindow.Presenter as OverlappedPresenter;
            if (_presenter is null)
            {
                _presenter = OverlappedPresenter.Create();
                _appWindow.SetPresenter(_presenter);
            }
            _presenter.IsResizable = true;
            _presenter.IsMinimizable = true;
            _presenter.IsMaximizable = true;
            _presenter.SetBorderAndTitleBar(true, true);
            _nativeWindowServices = new NativeWindowServices(NativeHandle, HandleNativeMessage);
            _appWindow.Changed += (_, _) => AppWindowChanged?.Invoke(this, EventArgs.Empty);
            _nativeWindowReady = true;
            RestoreFullGeometry();
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException or Win32Exception)
        {
            NativeHandle = 0;
            _nativeWindowReady = false;
            Console.Error.WriteLine($"Native window integration unavailable: {ex.Message}");
        }
    }

    private void OnAppWindowChanged(object? sender, EventArgs args)
    {
        if (_disposed || _closing) return;
        UpdateWindowVisibilityPolicy();
        BenchWindowShown();
        _windowMaximized = _presenter?.State == OverlappedPresenterState.Maximized;
        if (!_fullscreen)
            ScheduleSettings();
        try
        {
            _browserHost?.NotifyParentWindowPositionChanged();
            UpdateBrowserVisibility();
        }
        catch (Exception) { }
        RefreshCompactActivity();
    }








    private void BuildMenus()
    {
        _moreFlyout = new MenuFlyout();
        _timerFlyout = new MenuFlyout();

        _retryItem = CreateMenuItem("Retry failed navigation", "retry", RetryNavigation);
        _playPauseItem = CreatePlayerItem("Play or pause", "toggle", "play-pause");
        _playItem = CreatePlayerItem("Start website playback", "play", "play");
        _pauseItem = CreatePlayerItem("Pause website playback", "pause", "pause");
        _previousItem = CreatePlayerItem("Previous item", "previous", "previous");
        _nextItem = CreatePlayerItem("Next item", "next", "next");
        _zoomInItem = CreateMenuItem("Zoom page in", "zoom-in", () => SetZoom(_settings.Zoom + 0.1));
        _zoomOutItem = CreateMenuItem("Zoom page out", "zoom-out", () => SetZoom(_settings.Zoom - 0.1));
        _zoomResetItem = CreateMenuItem("Reset page zoom", "zoom-reset", () => SetZoom(1));
        _fullscreenItem = CreateMenuItem("Enter fullscreen", "fullscreen", ToggleFullscreen);
        _compactItem = CreateMenuItem("Compact window", "compact", ToggleCompact);
        _shortcutsItem = CreateToggleItem("Enable session playback shortcuts", "settings", value => SetShortcutsEnabled(value));
        _topmostItem = CreateToggleItem("Keep window on top", "pin", value => SetTopmost(value));
        _trayItem = CreateToggleItem("Enable tray icon", "tray", value => { SetTrayEnabled(value); CaptureSettings(); });
        _restoreItem = CreateToggleItem("Start on last Home or Library section", "restore-section", value =>
        {
            _settings = _settings with { RestoreSection = value, LastSection = "home" };
            CaptureSettings();
            SetStatus(value
                ? "Remembering Home or Library only. The website still owns account, queue and autoplay behavior."
                : "Section restore disabled. Startup returns to Home.");
        });
        _setTimerItem = CreateMenuItem("Set pause timer", "quit-timer", SetPauseTimer);
        _cancelTimerItem = CreateMenuItem("Cancel pause timer", "cancel-timer", CancelPauseTimer);
        _statusDetailsItem = CreateMenuItem("Read application status", "status", ShowStatusDetails);
        _settingsItem = CreateMenuItem("Settings", "settings", ShowSettings);
        _quitItem = CreateMenuItem("Quit Nativune", "quit", () => _ = ShutdownAsync());
        _versionItem = new MenuFlyoutItem
        {
            Text = AppVersion.DisplayName,
            IsEnabled = false
        };
        AutomationProperties.SetName(_versionItem, $"About {AppVersion.DisplayName}");

        // Grouped by importance: recovery, playback (now only here in the full window), window, timer, app.
        AddRange(_moreFlyout, _retryItem, new MenuFlyoutSeparator(),
            _playPauseItem, _playItem, _pauseItem, _previousItem, _nextItem, _shortcutsItem,
            new MenuFlyoutSeparator(), _compactItem, _fullscreenItem, _topmostItem,
            _zoomInItem, _zoomOutItem, _zoomResetItem, new MenuFlyoutSeparator(),
            _setTimerItem, _cancelTimerItem, new MenuFlyoutSeparator(),
            _trayItem, _restoreItem, _settingsItem, _statusDetailsItem,
            new MenuFlyoutSeparator(), _versionItem, new MenuFlyoutSeparator(), _quitItem);
        AddRange(_timerFlyout, _setTimerItem, _cancelTimerItem);
        MoreButton.Flyout = _moreFlyout;
        TimerButton.Flyout = _timerFlyout;
        _retryItem.IsEnabled = false;
        _statusDetailsItem.IsEnabled = true;
    }

    private MenuFlyoutItem CreateMenuItem(string text, string icon, Action action)
    {
        var item = new MenuFlyoutItem { Text = text, Icon = _iconCache.CreateElement(icon, 16) };
        AutomationProperties.SetName(item, text);
        item.Click += (_, _) => action();
        return item;
    }

    private MenuFlyoutItem CreatePlayerItem(string text, string command, string icon)
    {
        var item = CreateMenuItem(text, icon, () => _ = ExecutePlayerCommandAsync(command));
        item.Tag = command;
        return item;
    }

    private ToggleMenuFlyoutItem CreateToggleItem(string text, string icon, Action<bool> action)
    {
        var item = new ToggleMenuFlyoutItem { Text = text, Icon = _iconCache.CreateElement(icon, 16) };
        AutomationProperties.SetName(item, text);
        item.IsChecked = false;
        item.Click += (_, _) => action(item.IsChecked);
        return item;
    }

    private static void AddRange(MenuFlyout flyout, params MenuFlyoutItemBase[] items)
    {
        foreach (var item in items)
            flyout.Items.Add(item);
    }

    private void WireSurface()
    {
        BackButton.Click += (_, _) => { if (CanNavigate && _browserHost?.Core.CanGoBack == true) _browserHost.Core.GoBack(); };
        ForwardButton.Click += (_, _) => { if (CanNavigate && _browserHost?.Core.CanGoForward == true) _browserHost.Core.GoForward(); };
        HomeButton.Click += (_, _) => { if (CanNavigate) _browserHost?.Core.Navigate(_initialUri); };
        UpdateButton.Click += (_, _) => OnUpdateButtonClick();
        RootGrid.KeyDown += OnRootKeyDown;
        WebViewSlot.GotFocus += (_, _) =>
        {
            if (BrowserShouldBeVisible) _browserHost?.Focus();
        };
        _shortcutsItem.IsChecked = false;
        _restoreItem.IsChecked = _settings.RestoreSection;
        _trayItem.IsChecked = _settings.TrayEnabled;
        _topmostItem.IsChecked = _presenter?.IsAlwaysOnTop == true;
        RefreshShortcutDescriptions();
        UpdateNavigation();
        UpdateTimerPresentation();
    }

    internal void ApplyAppearance()
    {
        if (_disposed) return;
        ShellTheme.Apply(RootGrid);
        ShellTheme.ApplyToWindow(this);
        CompactView.ApplyAppearance();
        SetButtonIcons();
        SetMenuIcons();
        _taskbarControls?.UpdateAppearance(CurrentDpi(), ToDrawingColor(ShellTheme.ForegroundColor));
        try { _tray?.Recreate(); }
        catch (Exception) { SetStatus("Tray icon could not be refreshed for the current theme.", isError: true); }
    }

    private void SetButtonIcons()
    {
        BackButton.Content = _iconCache.CreateElement("back", 20);
        ForwardButton.Content = _iconCache.CreateElement("forward", 20);
        HomeButton.Content = _iconCache.CreateElement("home", 20);
        MoreButton.Content = _iconCache.CreateElement("overflow", 20);
        SetTimerButtonContent(TimerBadge);
        CompactButton.Content = _iconCache.CreateElement(_compact ? "restore-window" : "compact", 20);
        SetReleaseUpdateButtonState(
            _releaseUpdateButtonState, _availableReleaseUpdate?.Version);
    }

    private void SetMenuIcons()
    {
        _retryItem.Icon = _iconCache.CreateElement("retry", 16);
        _playPauseItem.Icon = _iconCache.CreateElement("play-pause", 16);
        _playItem.Icon = _iconCache.CreateElement("play", 16);
        _pauseItem.Icon = _iconCache.CreateElement("pause", 16);
        _previousItem.Icon = _iconCache.CreateElement("previous", 16);
        _nextItem.Icon = _iconCache.CreateElement("next", 16);
        _shortcutsItem.Icon = _iconCache.CreateElement("settings", 16);
        _zoomInItem.Icon = _iconCache.CreateElement("zoom-in", 16);
        _zoomOutItem.Icon = _iconCache.CreateElement("zoom-out", 16);
        _zoomResetItem.Icon = _iconCache.CreateElement("zoom-reset", 16);
        _fullscreenItem.Icon = _iconCache.CreateElement(_fullscreen ? "exit-fullscreen" : "fullscreen", 16);
        _compactItem.Icon = _iconCache.CreateElement(_compact ? "restore-window" : "compact", 16);
        _topmostItem.Icon = _iconCache.CreateElement("pin", 16);
        _trayItem.Icon = _iconCache.CreateElement("tray", 16);
        _restoreItem.Icon = _iconCache.CreateElement("restore-section", 16);
        _setTimerItem.Icon = _iconCache.CreateElement("quit-timer", 16);
        _cancelTimerItem.Icon = _iconCache.CreateElement("cancel-timer", 16);
        _statusDetailsItem.Icon = _iconCache.CreateElement("status", 16);
        _settingsItem.Icon = _iconCache.CreateElement("settings", 16);
        _quitItem.Icon = _iconCache.CreateElement("quit", 16);
    }

    private void SetTopmost(bool value)
    {
        if (_presenter is not null)
            _presenter.IsAlwaysOnTop = value;
        CompactView.SetPreferences(_settings.ReduceMotion, value);
        _topmostItem.IsChecked = value;
    }

    // Busy is not part of availability: controls stay enabled while one command runs, and clicks
    // meanwhile are ignored, so taskbar/tray/menu/Compact buttons don't flicker every poll.
    private bool PlayerAvailable => !_playerSuspended && !_closing && !_disposed
        && _playerControls?.IsAvailable == true;

    private void UpdatePlayerControls()
    {
        var enabled = PlayerAvailable;
        _playPauseItem.IsEnabled = enabled;
        _playItem.IsEnabled = enabled;
        _pauseItem.IsEnabled = enabled;
        _previousItem.IsEnabled = enabled;
        _nextItem.IsEnabled = enabled;
        _shortcutsItem.IsEnabled = !_closing && !_disposed && NativeHandle != 0;
        _taskbarControls?.SetEnabled(enabled);
        _tray?.SetPlaybackEnabled(enabled);
    }

    private bool CanNavigate => !_disposed && !_closing && !_configuringPrivacy && !_browserFailed
        && _browserHost is not null;
    private bool BrowserShouldBeVisible
        => _appWindow?.IsVisible == true
            && !_compact && !_configuringPrivacy && !_browserFailed
            && _presenter?.State != OverlappedPresenterState.Minimized
            && !_closing && !_disposed;

    private void UpdateBrowserVisibility()
    {
        if (_browserHost is null) return;
        try { _browserHost.SetVisible(BrowserShouldBeVisible); }
        catch (Exception) when (_closing || _disposed) { }
    }
    private bool WindowIsVisible
        => _appWindow?.IsVisible == true && _presenter?.State != OverlappedPresenterState.Minimized;

    // After a genuine hide (tray or minimize) the host runs one aggressive GC and one working-set trim;
    // showing the window again stops both. Visible Compact is a visible window and never qualifies.
    private void UpdateWindowVisibilityPolicy()
    {
        var visible = WindowIsVisible;
        var wasVisible = _windowWasVisible;
        _windowWasVisible = visible;
        if (wasVisible == visible) return;
        _gcOnHideTimer.Stop();
        _trimOnHideTimer.Stop();
        if (visible || wasVisible != true) return;
        _gcOnHideTimer.Start();
        _trimOnHideTimer.Start();
    }

    private void UpdateNavigation()
    {
        if (_closing || _disposed) return;
        var canNavigate = CanNavigate;
        BackButton.IsEnabled = canNavigate && _browserHost?.Core.CanGoBack == true;
        ForwardButton.IsEnabled = canNavigate && _browserHost?.Core.CanGoForward == true;
        HomeButton.IsEnabled = canNavigate;
        _retryItem.IsEnabled = canNavigate && _navigationFailed;
        _statusDetailsItem.IsEnabled = true;
        UpdatePlayerControls();
    }

    private async Task ExecutePlayerCommandAsync(string command)
    {
        if (_closing || _disposed) return;
        var controls = _playerControls;
        if (controls is null || !controls.IsAvailable || _playerSuspended)
        {
            SetStatus("Playback controls unavailable.", isError: true);
            UpdatePlayerControls();
            return;
        }
        if (_playerBusy) return;

        _playerBusy = true;
        var result = new PlayerCommandResult(PlayerCommandOutcome.Unknown, "Playback command failed; playback outcome is unknown.");
        try
        {
            result = await controls.ExecuteAsync(command);
        }
        catch (OperationCanceledException) when (_closing || _disposed || _lifetime.IsCancellationRequested) { return; }
        catch (Exception) { }
        finally
        {
            _playerBusy = false;
        }
        if (_closing || _disposed) return;
        _lastCompactReadAt = 0;
        ReportPlayerResult(result);
    }

    private async Task InitializeAsync()
    {
        var lifetimeToken = _lifetime.Token;
        if (!CanContinueInitialization(lifetimeToken))
            return;

        try
        {
            var runtimeDirectory = ResolveRuntimeDirectory(_root);
            var browserArguments = BrowserArguments(_settings.SleepInBackground);
            BenchStart(ref browserArguments);
            var options = new CoreWebView2EnvironmentOptions
            {
                AreBrowserExtensionsEnabled = true,
                AdditionalBrowserArguments = browserArguments
            };
            if (runtimeDirectory is null)
                options.ReleaseChannels = CoreWebView2ReleaseChannels.Stable;
            EnsureSupportedWebViewRuntime(runtimeDirectory, options);
            var profileDirectory = RootLocator.WebViewProfilePath(_root);
            RootLocator.EnsureNoReparsePath(_root, profileDirectory);
            Directory.CreateDirectory(profileDirectory);
            RootLocator.EnsureNoReparsePath(_root, profileDirectory);
            SetStatus(runtimeDirectory is null
                ? "Starting shared WebView2 Evergreen runtime..."
                : "Starting repository-local fixed WebView2 runtime...");
            var environmentCreation = runtimeDirectory is null
                ? CoreWebView2Environment.CreateWithOptionsAsync(null, profileDirectory, options).AsTask()
                : CoreWebView2Environment.CreateWithOptionsAsync(runtimeDirectory, profileDirectory, options).AsTask();
            var environment = await AwaitBoundedAsync(
                environmentCreation, TimeSpan.FromSeconds(30), lifetimeToken);
            BenchEnvironmentCreated();
            if (!CanContinueInitialization(lifetimeToken))
                return;

            _environment = environment;
            if (NativeHandle == 0)
                throw new InvalidOperationException("A native host window is required before creating WebView2.");

            var host = await NativeBrowserHost.CreateAsync(
                environment, NativeHandle, WebViewSlot, lifetimeToken,
                cleanup => _lateBrowserCleanupTask = cleanup);
            BenchControllerCreated();
            if (!CanContinueInitialization(lifetimeToken))
            {
                host.Dispose();
                return;
            }

            _browserHost = host;
            host.SetVisible(false);
            host.AcceleratorKeyPressed += OnBrowserAcceleratorKeyPressed;
            host.MoveFocusRequested += OnBrowserMoveFocusRequested;
            if (!CanContinueInitialization(lifetimeToken))
                return;

            var core = host.Core;
            core.MemoryUsageTargetLevel = CoreWebView2MemoryUsageTargetLevel.Low;
            core.Settings.AreHostObjectsAllowed = false;
            core.Settings.IsWebMessageEnabled = false;
            host.ZoomFactor = _settings.Zoom;
            environment.ProcessInfosChanged += (_, _) => OnProcessInfosChanged();
            BenchMuteOutput();
            StartOutputAudio();
            OnProcessInfosChanged();
            core.HistoryChanged += (_, _) => UpdateNavigation();
            core.SourceChanged += (_, _) => ObserveSection();
            core.NavigationStarting += (_, args) => OnNavigationStarting(args);
            core.NewWindowRequested += (_, args) => OnNewWindowRequested(args);
            core.PermissionRequested += (_, args) => OnPermissionRequested(args);
            core.DownloadStarting += (_, args) => OnDownloadStarting(args);
            core.LaunchingExternalUriScheme += (_, args) => OnLaunchingExternalUriScheme(args);
            core.ProcessFailed += (_, args) => OnProcessFailed(args);

            await BrowserPrivacy.ConfigureAsync(core, _root, setupUri =>
            {
                if (!CanContinueInitialization(lifetimeToken))
                    return;
                _privacySetupUri = setupUri;
                _configuringPrivacy = setupUri is not null;
            }, _settings.BlockAds, lifetimeToken);
            if (!CanContinueInitialization(lifetimeToken))
                return;

            _configuringPrivacy = false;
            core.NavigationCompleted += (_, args) => OnNavigationCompleted(args);
            _playerControls = new PlayerControls(core, () => CanNavigate && !_navigationFailed, lifetimeToken);
            _playerControls.StateChanged += (_, _) =>
            {
                UpdatePlayerControls();
                if ((_compactWhenReady || _compactResumeAfterAccount) && _playerControls.IsAvailable)
                    _dispatcherQueue.TryEnqueue(() =>
                    {
                        if (_playerControls?.IsAvailable != true) return;
                        if (_compactResumeAfterAccount && !_settings.StartCompact)
                            _compactResumeAfterAccount = false;
                        if (ShouldResumeStartupCompactAfterAccount(_compactStartupPending,
                                _settings.StartCompact, _compactResumeAfterAccount, controlsReady: true))
                        {
                            _compactResumeAfterAccount = false;
                            if (!_compact && !_compactWhenReady)
                            {
                                _compactStartupPending = true;
                                SetCompact(true);
                                return;
                            }
                        }
                        if (_compactWhenReady)
                            _ = ProbeForCompactTransportAsync();
                    });
            };
            CreateTaskbarControls();
            UpdatePlayerControls();
            if (!CanContinueInitialization(lifetimeToken))
                return;

            SetStatus("Loading official YouTube Music...");
            UpdateBrowserVisibility();
            if (!CanContinueInitialization(lifetimeToken))
                return;
            var startupUri = _settings.StartupUri;
            BenchStartUri(ref startupUri);
            core.Navigate(startupUri);
            UpdateNavigation();
        }
        catch (OperationCanceledException) when (lifetimeToken.IsCancellationRequested || _closing || _disposed) { }
        catch (WebView2RuntimeRequirementException ex)
        {
            if (!CanContinueInitialization(lifetimeToken))
                return;
            ExitCode = 1;
            _browserFailed = true;
            SetStatus(ex.Message, isError: true);
            Console.Error.WriteLine(ex.Message);
            UpdateNavigation();
        }
        catch (Exception)
        {
            if (!CanContinueInitialization(lifetimeToken))
                return;
            ExitCode = 1;
            _browserFailed = true;
            SetStatus(_configuringPrivacy
                ? "Startup or privacy verification failed. Close and relaunch after checking the local setup."
                : "Browser initialization failed. Close and relaunch.", isError: true);
            Console.Error.WriteLine("Browser startup failed; Music availability was not established.");
            UpdateNavigation();
        }
    }

    private bool CanContinueInitialization(CancellationToken lifetimeToken)
        => !_closing && !_disposed && !lifetimeToken.IsCancellationRequested;

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

    private static async Task ObserveCompletionAsync(Task operation)
    {
        try { await operation.ConfigureAwait(false); }
        catch (Exception) { }
    }

    private async Task WaitForInitializationAsync()
    {
        var initialization = _initializationTask;
        var cleanup = _lateBrowserCleanupTask;
        if (initialization is null && cleanup is null)
            return;

        Exception? failure = null;
        if (initialization is not null && !initialization.IsCompleted)
        {
            try { await initialization.WaitAsync(InitializationShutdownTimeout); }
            catch (Exception ex) { failure = ex; }
        }

        cleanup = _lateBrowserCleanupTask;
        if (cleanup is not null && !cleanup.IsCompleted)
        {
            try { await cleanup.WaitAsync(LateCleanupShutdownTimeout); }
            catch (Exception ex) { failure ??= ex; }
        }

        if (failure is not null)
            throw failure;
    }

    private async Task DisposeLifetimeAfterInitializationAsync(Task initialization)
    {
        try { await initialization.ConfigureAwait(false); }
        catch (Exception) { }
        try { _lifetime.Dispose(); }
        catch (Exception) { }
    }

    private void CreateTaskbarControls()
    {
        if (_taskbarControls is not null || _playerControls is null || NativeHandle == 0) return;
        _taskbarControls = new TaskbarControls(NativeHandle,
            message => SetStatus(message, isError: true), _iconCache, CurrentDpi(), ToDrawingColor(ShellTheme.ForegroundColor));
    }

    private void OnNavigationStarting(CoreWebView2NavigationStartingEventArgs args)
    {
        if (_closing || _disposed || _browserFailed)
        {
            args.Cancel = true;
            return;
        }
        InvalidateCompactState();
        if (_configuringPrivacy)
        {
            args.Cancel = !string.Equals(args.Uri, _privacySetupUri, StringComparison.Ordinal);
            return;
        }

        _activeNavigation = args.NavigationId;
        _navigationFailed = false;
        SetStatus("Loading page...");
        UpdateNavigation();
        if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) || !WebHostPolicy.IsAllowedMainFrameNavigation(uri))
        {
            args.Cancel = true;
            _blockedNavigation = args.NavigationId;
            var destination = uri is null ? "invalid address" : uri.Host;
            SetStatus($"Navigation blocked to {destination}. Only Music and Google account pages are allowed.", isError: true);
            Console.WriteLine($"Blocked navigation origin: {destination}");
        }
        else if (!PlayerControls.IsMusicUri(args.Uri))
        {
            var preserveStartupIntent = _compactStartupPending && _settings.StartCompact;
            if (_compact || _compactWhenReady || preserveStartupIntent)
            {
                if (preserveStartupIntent) _compactResumeAfterAccount = true;
                SetCompact(false, preserveStartupIntent);
            }
            _settings = _settings with { LastSection = "home" };
            CaptureSettings();
        }
    }

    private void OnNavigationCompleted(CoreWebView2NavigationCompletedEventArgs args)
    {
        if (_closing || _disposed || _browserFailed || args.NavigationId != _activeNavigation
            || args.NavigationId == _blockedNavigation)
            return;
        _navigationFailed = !args.IsSuccess;
        UpdateNavigation();
        if (!args.IsSuccess)
            SetStatus($"Page navigation failed: {args.WebErrorStatus}. Use Retry.", isError: true);
        else
        {
            SetStatus("Navigation completed. Account and playback remain website-owned.");
            ObserveSection();
            Console.WriteLine("Embedded web page ready.");
            BenchNavigationCompleted();
        }
    }

    // Perf bench seam: WebHost.Bench.cs implements these only under NATIVUNE_PERF_BENCH_HOOKS.
    // Without an implementation the compiler removes the declarations and every call site.
    partial void BenchInitialize();
    partial void BenchStart(ref string browserArguments);
    partial void BenchEnvironmentCreated();
    partial void BenchControllerCreated();
    partial void BenchMuteOutput();
    partial void BenchStartUri(ref string uri);
    partial void BenchWindowShown();
    partial void BenchNavigationCompleted();
    partial void BenchCompactRequested(bool compact);
    partial void BenchPresentationChanged();
    partial void BenchStopTimers();

    private void OnNewWindowRequested(CoreWebView2NewWindowRequestedEventArgs args)
    {
        args.Handled = true;
        if (_closing || _disposed || _configuringPrivacy) return;
        if (Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) && WebHostPolicy.IsAllowedMainFrameNavigation(uri))
        {
            _browserHost?.Core.Navigate(uri.ToString());
            return;
        }
        SetStatus("New window blocked: only Music and Google account pages are allowed.", isError: true);
    }

    private void OnPermissionRequested(CoreWebView2PermissionRequestedEventArgs args)
    {
        args.State = CoreWebView2PermissionState.Deny;
        args.Handled = true;
        SetStatus("Permission request denied.", isError: true);
    }

    private void OnDownloadStarting(CoreWebView2DownloadStartingEventArgs args)
    {
        args.Cancel = true;
        SetStatus("Downloads are disabled.", isError: true);
    }

    private void OnLaunchingExternalUriScheme(CoreWebView2LaunchingExternalUriSchemeEventArgs args)
    {
        args.Cancel = true;
        SetStatus("External URI launch blocked.", isError: true);
    }

    private void OnProcessFailed(CoreWebView2ProcessFailedEventArgs args)
    {
        string description;
        try
        {
            description = $"{args.ProcessFailedKind}, reason {args.Reason}, exit code {args.ExitCode}";
            if (!string.IsNullOrEmpty(args.ProcessDescription)) description += $", {args.ProcessDescription}";
        }
        catch (Exception) { description = args.ProcessFailedKind.ToString(); }
        AppLog.Write("process-failed", description);
        if (_closing || _disposed) return;

        switch (args.ProcessFailedKind)
        {
            case CoreWebView2ProcessFailedKind.BrowserProcessExited:
                try { _browserHost?.SetVisible(false); } catch (Exception) { }
                _playerControls?.Invalidate();
                InvalidateCompactState();
                _browserFailed = true;
                ExitCode = 1;
                UpdateNavigation();
                SetStatus("Browser process failed. Close and relaunch the app.", isError: true);
                break;
            case CoreWebView2ProcessFailedKind.RenderProcessExited:
                // Microsoft's documented recovery: reload the main frame. Guard against a crash loop.
                InvalidateCompactState();
                if (Environment.TickCount64 - _lastRendererReloadAt < 60_000)
                {
                    SetStatus("The page stopped again. Use Retry, or close and relaunch the app.", isError: true);
                    break;
                }
                _lastRendererReloadAt = Environment.TickCount64;
                SetStatus("The page stopped unexpectedly and is reloading. Playback stopped with it.", isError: true);
                try { _browserHost?.Core.Reload(); }
                catch (Exception ex) when (ex is COMException or InvalidOperationException) { }
                break;
            case CoreWebView2ProcessFailedKind.RenderProcessUnresponsive:
                SetStatus("The page is not responding right now; waiting for it to recover.", isError: true);
                break;
            // GPU, utility, subframe and helper exits are recovered automatically by WebView2; logged only.
        }
    }

    private long _lastRendererReloadAt = -60_000;

    private void ObserveSection()
    {
        if (_closing || !CanNavigate || !_settings.RestoreSection || _browserHost is null
            || !Uri.TryCreate(_browserHost.Core.Source, UriKind.Absolute, out var uri)) return;
        var section = ShellSettings.SectionFromUri(uri);
        if (section is not null && section != _settings.LastSection)
        {
            _settings = _settings with { LastSection = section };
            CaptureSettings();
        }
    }

    private void RetryNavigation()
    {
        if (!CanNavigate || !_navigationFailed) return;
        _navigationFailed = false;
        UpdateNavigation();
        _browserHost?.Core.Reload();
    }

    private void SetZoom(double zoom)
    {
        _settings = _settings with { Zoom = Math.Clamp(Math.Round(zoom, 2), 0.75, 1.5) };
        if (!_disposed && !_closing && _browserHost is not null)
            _browserHost.ZoomFactor = _settings.Zoom;
        ScheduleSettings();
        SetStatus($"Zoom: {_settings.Zoom:P0}.");
    }

    private void SetStatus(string text, bool isError = false)
    {
        if (_disposed || _closing) return;
        if (!isError && _statusIsError && (_browserFailed || _navigationFailed)) return;
        var warning = _settingsWarning is not null && text != _settingsWarning ? " " + _settingsWarning : string.Empty;
        _statusIsError = isError;
        _statusDetailsText = (isError ? "[!] Error: " : string.Empty) + text + warning;
        if (isError) AppLog.Write("status", text);
        if (_statusDetailsText.Length > 4096)
            _statusDetailsText = _statusDetailsText[..4096];
        _statusDetailsItem.Text = isError ? "Read application status (error)" : "Read application status";
        AutomationProperties.SetName(MoreButton, isError
            ? "More commands and settings. Application status reports an error."
            : "More commands and settings");
        _statusDetailsItem.IsEnabled = true;
        CompactView.SetStatus(_statusDetailsText, _statusIsError);
    }

    private void ShowStatusDetails()
    {
        if (_disposed || _closing) return;
        var body = new TextBox
        {
            IsReadOnly = true,
            TextWrapping = TextWrapping.Wrap,
            AcceptsReturn = true,
            Text = BuildStatusDetailsText(
                _statusDetailsText, _compact, _compactState is not null),
        };
        ScrollViewer.SetVerticalScrollBarVisibility(body, ScrollBarVisibility.Auto);
        ScrollViewer.SetHorizontalScrollBarVisibility(body, ScrollBarVisibility.Disabled);
        AutomationProperties.SetName(body, "Current application status");
        var close = new Button { Content = "Close", HorizontalAlignment = HorizontalAlignment.Right };
        AutomationProperties.SetName(close, "Close application status");
        var panel = new Grid { Padding = new Thickness(16), RowSpacing = 12 };
        panel.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        panel.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        Grid.SetRow(body, 0);
        Grid.SetRow(close, 1);
        panel.Children.Add(body);
        panel.Children.Add(close);
        try
        {
            var dialog = CreateDialogWindow("Application status", panel, 480, 240);
            close.Click += (_, _) => dialog.Close();
            dialog.Activate();
        }
        catch (Exception)
        {
            HandleDialogFailure("Status dialog");
        }
    }

    internal static string BuildStatusDetailsText(
        string status,
        bool compact,
        bool compactPlaybackAvailable)
    {
        var current = string.IsNullOrWhiteSpace(status)
            ? "No current application status has been reported."
            : status;
        if (!compact)
            return current;

        var playback = compactPlaybackAvailable
            ? "Compact playback state: available."
            : "Compact playback state: unavailable. Nativune has not confirmed a current state. "
                + "This status alone does not identify a YouTube Music website error; return to full view to continue using the website.";
        return current + " " + playback;
    }



    private void SetPauseTimer() => _ = SetPauseTimerAsync();

    private async Task SetPauseTimerAsync()
    {
        if (_sleep is null || _closing || _settingsDialogOpen || _timerDialogOpen) return;
        _timerDialogOpen = true;
        Window? dialog = null;
        try
        {
            var hours = new NumberBox { Header = "Hours", Minimum = 0, Maximum = 4, SmallChange = 1, Value = 0,
                SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
            AutomationProperties.SetName(hours, "Hours until pause");
            var minutes = new NumberBox { Header = "Minutes", Minimum = 0, Maximum = 59, SmallChange = 1, Value = 30,
                SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
            AutomationProperties.SetName(minutes, "Minutes until pause");
            var seconds = new NumberBox { Header = "Seconds", Minimum = 0, Maximum = 59, SmallChange = 1, Value = 0,
                SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Compact };
            AutomationProperties.SetName(seconds, "Seconds until pause");
            var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Visibility = Visibility.Collapsed,
                Foreground = new Microsoft.UI.Xaml.Media.SolidColorBrush(ShellTheme.ForegroundColor) };
            var set = new Button { Content = "Set timer" };
            AutomationProperties.SetName(set, "Set pause timer");
            var cancel = new Button { Content = "Cancel" };
            AutomationProperties.SetName(cancel, "Cancel timer setup");
            var fields = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 10 };
            fields.Children.Add(hours); fields.Children.Add(minutes); fields.Children.Add(seconds);
            var panel = new StackPanel { Padding = new Thickness(16), Spacing = 12 };
            panel.Children.Add(new TextBlock { Text = "Pauses playback; keeps this app open. Choose 1 second to 4 hours.", TextWrapping = TextWrapping.Wrap });
            panel.Children.Add(fields); panel.Children.Add(error);
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Spacing = 8 };
            buttons.Children.Add(set); buttons.Children.Add(cancel); panel.Children.Add(buttons);
            var pauseDialog = CreateDialogWindow("Pause playback in...", panel, 460, 260);
            dialog = pauseDialog;
            var result = new TaskCompletionSource<TimeSpan?>(TaskCreationOptions.RunContinuationsAsynchronously);
            set.Click += (_, _) =>
            {
                var hoursValue = hours.Value;
                var minutesValue = minutes.Value;
                var secondsValue = seconds.Value;
                if (!double.IsFinite(hoursValue) || !double.IsFinite(minutesValue) || !double.IsFinite(secondsValue)
                    || hoursValue != Math.Truncate(hoursValue) || minutesValue != Math.Truncate(minutesValue)
                    || secondsValue != Math.Truncate(secondsValue)
                    || hoursValue is < 0 or > 4 || minutesValue is < 0 or > 59 || secondsValue is < 0 or > 59)
                {
                    error.Text = "Enter whole hours, minutes and seconds from 0 through the allowed range.";
                    error.Visibility = Visibility.Visible;
                    return;
                }
                var duration = new TimeSpan((int)hoursValue, (int)minutesValue, (int)secondsValue);
                if (duration < TimeSpan.FromSeconds(1) || duration > TimeSpan.FromHours(4))
                {
                    error.Text = "Choose a duration from 1 second through 4 hours.";
                    error.Visibility = Visibility.Visible;
                    return;
                }
                result.TrySetResult(duration);
                pauseDialog.Close();
            };
            cancel.Click += (_, _) => { result.TrySetResult(null); pauseDialog.Close(); };
            dialog.Closed += (_, _) =>
            {
                _timerDialogOpen = false;
                result.TrySetResult(null);
            };
            pauseDialog.Activate();
            var durationResult = await result.Task;
            if (_closing || _disposed || durationResult is null) return;
            _sleep.Arm(durationResult.Value);
            UpdateTimerPresentation();
            SetStatus("Pause timer armed. It includes sleep time and is not restored after restart.");
        }
        catch (Exception)
        {
            try { dialog?.Close(); }
            catch (Exception) { }
            if (!_closing && !_disposed)
                HandleDialogFailure("Pause timer dialog");
        }
        finally
        {
            _timerDialogOpen = false;
        }
    }

    private void HandleDialogFailure(string label)
    {
        if (_closing || _disposed) return;
        try { SetStatus($"{label} could not be opened.", isError: true); }
        catch (Exception) { }
    }

    private void CancelPauseTimer()
    {
        if (_sleep is null || _closing) return;
        _sleep.Cancel();
        UpdateTimerPresentation();
        SetStatus("Pause timer cancelled.");
    }

    private string TimerBadge
        => _sleep?.IsArmed == true && _sleep.DisplayDeadline is { } deadline
            ? deadline.ToLocalTime().ToString("T") : string.Empty;

    // Idle: the timer icon at the shared toolbar button size. Armed: the deadline text as a wider chip.
    private void SetTimerButtonContent(string badge)
    {
        if (badge.Length == 0)
        {
            TimerButton.Content = _iconCache.CreateElement("quit-timer", 20);
            TimerButton.ClearValue(FrameworkElement.WidthProperty);
        }
        else
        {
            TimerButton.Content = badge;
            TimerButton.Width = Math.Max(80, 36 + badge.Length * 8);
        }
    }

    private void UpdateTimerPresentation()
    {
        var armed = _sleep?.IsArmed == true;
        var badge = TimerBadge;
        SetTimerButtonContent(badge);
        ToolTipService.SetToolTip(TimerButton, badge.Length == 0
            ? "Set pause timer. The app stays open." : $"Pause timer deadline {badge}. The app stays open.");
        TimerButton.SetValue(AutomationProperties.NameProperty, badge.Length == 0
            ? "Set pause timer" : $"Pause timer deadline {badge}");
        _cancelTimerItem.IsEnabled = armed;
        _setTimerItem.IsEnabled = !_closing && !_disposed;
        UpdateCompactTimer();
    }

    private void OnTimerExpired()
    {
        if (_closing || _disposed) return;
        UpdateTimerPresentation();
        _ = ExecutePlayerCommandAsync("pause");
    }

    private void ShowSettings()
    {
        if (_closing || _disposed || _settingsDialogOpen) return;
        _settingsDialogOpen = true;
        var dialog = new SettingsDialog(_settings, bindings =>
        {
            if (!bindings.Validate(out var error)) return error;
            if (!_shortcutsEnabled) return null;
            var applied = _sessionShortcuts?.TryApply(bindings, out error) == true;
            _shortcutsItem.IsChecked = _shortcutsEnabled;
            return applied ? null : error;
        });
        _settingsDialog = dialog;
        _ = ShowSettingsAsync(dialog);
    }

    private async Task ShowSettingsAsync(SettingsDialog dialog)
    {
        try
        {
            if (await dialog.ShowAsync(this))
            {
                var sleepSettingChanged = _settings.SleepInBackground != dialog.Result.SleepInBackground;
                var adSettingChanged = _settings.BlockAds != dialog.Result.BlockAds;
                _settings = _settings with
                {
                    Shortcuts = dialog.Result.Shortcuts,
                    ReduceMotion = dialog.Result.ReduceMotion,
                    SleepInBackground = dialog.Result.SleepInBackground,
                    StartCompact = dialog.Result.StartCompact,
                    AutoCheckUpdates = dialog.Result.AutoCheckUpdates,
                    BlockAds = dialog.Result.BlockAds
                };
                ConfigureAutomaticReleaseUpdateChecks();
                if (!_settings.StartCompact)
                {
                    _compactStartupPending = false;
                    _compactResumeAfterAccount = false;
                }
                RefreshShortcutDescriptions();
                CompactView.SetPreferences(_settings.ReduceMotion, _presenter?.IsAlwaysOnTop == true);
                CaptureSettings();
                SetStatus(sleepSettingChanged || adSettingChanged
                    ? "Settings saved. Restart Nativune to apply the background sleeping or ad-blocking change."
                    : _shortcutsEnabled
                        ? "Settings saved. Updated global shortcuts are active for this session."
                        : "Settings saved. Global shortcuts remain off until enabled for this session.");
            }
        }
        catch (Exception) when (!_closing && !_disposed)
        {
            SetStatus("Settings could not be opened.", isError: true);
        }
        finally
        {
            _settingsDialog = null;
            _settingsDialogOpen = false;
        }
    }

    private static string ShortcutDescription(string action, int binding)
        => binding == 0 ? action + ". No shortcut assigned."
            : $"{action}. Shortcut: {ShortcutBindings.Format(binding)} when session shortcuts are enabled.";

    // Website transport lives in the More menu in the full window (the site has its own player bar),
    // so the custom shortcut descriptions go there: help text and tooltip always, and the
    // accelerator column only while the session hotkeys are actually registered.
    private void RefreshShortcutDescriptions()
    {
        SetPlayerItemShortcut(_playPauseItem, "Play or pause website playback", _settings.Shortcuts.Toggle);
        SetPlayerItemShortcut(_previousItem, "Previous item", _settings.Shortcuts.Previous);
        SetPlayerItemShortcut(_nextItem, "Next item", _settings.Shortcuts.Next);
        ToolTipService.SetToolTip(CompactButton, ShortcutDescription("Switch compact and full window", _settings.Shortcuts.Compact));
        CompactView.SetShortcutDescriptions(_settings.Shortcuts.Toggle, _settings.Shortcuts.Previous,
            _settings.Shortcuts.Next, _settings.Shortcuts.Compact);
    }

    private void SetPlayerItemShortcut(MenuFlyoutItem item, string action, int binding)
    {
        var description = ShortcutDescription(action, binding);
        ToolTipService.SetToolTip(item, description);
        AutomationProperties.SetHelpText(item, description);
        item.KeyboardAcceleratorTextOverride = binding != 0 && _shortcutsEnabled
            ? ShortcutBindings.Format(binding) : string.Empty;
    }

    private void SetShortcutsEnabled(bool enabled)
    {
        if (!enabled)
        {
            UnregisterSessionShortcuts();
            if (!_closing && !_disposed && _sessionShortcuts?.CleanupFailed != true)
                SetStatus("Session shortcuts disabled.");
            return;
        }
        if (NativeHandle == 0 || _closing || _disposed)
        {
            _shortcutsItem.IsChecked = false;
            return;
        }
        _sessionShortcuts ??= new SessionShortcuts(NativeHandle);
        if (_sessionShortcuts.CleanupFailed)
        {
            _shortcutsItem.IsChecked = false;
            SetStatus("Close and restart the app to recover shortcut registrations.", isError: true);
            return;
        }
        if (!_sessionShortcuts.TryApply(_settings.Shortcuts, out var error))
        {
            _shortcutsItem.IsChecked = _shortcutsEnabled;
            SetStatus(error, isError: true);
            return;
        }
        _shortcutsEnabled = true;
        _shortcutsItem.IsChecked = true;
        RefreshShortcutDescriptions();
        SetStatus("Saved global shortcuts enabled for this session. Disable them here or close the app to release them.");
    }

    private void UnregisterSessionShortcuts()
    {
        _sessionShortcuts?.Dispose();
        if (_sessionShortcuts?.CleanupFailed == true)
        {
            if (!_closing && !_disposed)
                SetStatus("Shortcut cleanup failed. Close and restart the app before enabling shortcuts again.", isError: true);
        }
        else
        {
            _sessionShortcuts = null;
            _shortcutsEnabled = false;
        }
        _shortcutsItem.IsChecked = false;
        if (!_closing && !_disposed)
            RefreshShortcutDescriptions();
    }

    private void SetTrayEnabled(bool enabled)
    {
        if (!enabled)
        {
            if (_appWindow?.IsVisible == false && !_closing) RequestActivation();
            try { _tray?.SetVisible(false); }
            catch (Exception) { SetStatus("Tray icon could not be removed cleanly.", isError: true); }
            try { _tray?.Dispose(); }
            catch (Exception) { SetStatus("Tray icon cleanup failed; restart the app before enabling it again.", isError: true); }
            _tray = null;
        }
        else if (_tray is null && NativeHandle != 0)
        {
            try
            {
                _tray = new NativeTrayIcon(NativeHandle, _iconCache, OnTrayCommand);
                SetDesiredTrayTooltip(_releaseUpdateButtonState,
                    _availableReleaseUpdate?.Version, null);
                _tray.SetVisible(true);
                _tray.SetPlaybackEnabled(PlayerAvailable);
            }
            catch (Exception ex) when (ex is Win32Exception or ArgumentException or ExternalException or InvalidOperationException)
            {
                _tray?.Dispose();
                _tray = null;
                enabled = false;
                SetStatus("Tray icon could not be created. The window remains available.", isError: true);
            }
        }
        _trayItem.IsChecked = enabled;
        _settings = _settings with { TrayEnabled = enabled };
        if (enabled)
            SetStatus("Tray enabled. Close hides to the tray and keeps playback running; use Quit to exit.");
        UpdateNavigation();
    }

    private void OnTrayCommand(string command)
    {
        if (_closing || _disposed) return;
        switch (command)
        {
            case "show": RequestActivation(); break;
            case "toggle": _ = ExecutePlayerCommandAsync("toggle"); break;
            case "previous": _ = ExecutePlayerCommandAsync("previous"); break;
            case "next": _ = ExecutePlayerCommandAsync("next"); break;
            case "timer": SetPauseTimer(); break;
            case "quit": _ = ShutdownAsync(); break;
        }
    }


    private bool TryHideToTray()
    {
        if (_tray is not { IsVisible: true } || NativeHandle == 0 || _appWindow is null
            || _closing || _disposed)
            return false;
        try
        {
            CaptureSettings();
            _appWindow.Hide();
            UpdateWindowVisibilityPolicy();
            UpdateBrowserVisibility();
            return !_appWindow.IsVisible;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private void CloseOrHideToTray()
    {
        if (!TryHideToTray())
            _ = ShutdownAsync();
    }

    public void RequestActivation()
    {
        if (Interlocked.Exchange(ref _activationPending, 1) != 0) return;
        if (_disposed || _closing) return;
        _dispatcherQueue.TryEnqueue(() =>
        {
            Interlocked.Exchange(ref _activationPending, 0);
            if (_disposed || _closing) return;
            TryInitializeNativeWindow();
            _appWindow?.Show();
            Activate();
            BenchWindowShown();
            UpdateBrowserVisibility();
            if (NativeHandle != 0) FlashWindow(NativeHandle, true);
        });
    }

    public void SetCompact(bool compact) => SetCompact(compact, preserveStartupIntent: false);

    private void SetCompact(bool compact, bool preserveStartupIntent)
    {
        if (_closing || _disposed) return;
        BenchCompactRequested(compact);
        if (!compact)
        {
            _compactWhenReady = false;
            if (!preserveStartupIntent)
            {
                _compactStartupPending = false;
                _compactResumeAfterAccount = false;
            }
            if (_statusDetailsText.StartsWith(CompactReadinessCheckingStatus, StringComparison.Ordinal))
                SetStatus(string.Empty);
        }
        if (compact == _compact) return;
        if (compact && _initializeBrowser)
        {
            _compactWhenReady = true;
            SetStatus(CompactReadinessCheckingStatus);
            _ = ProbeForCompactTransportAsync();
            return;
        }
        _compactWhenReady = false;
        ToggleCompactCore();
    }
    internal static bool ShouldResumeStartupCompactAfterAccount(bool startupPending,
        bool savedOptIn, bool returnedToMusic, bool controlsReady)
        => startupPending && savedOptIn && returnedToMusic && controlsReady;

    private void ToggleCompact() => SetCompact(!(_compact || _compactWhenReady));

    private void ToggleCompactCore()
    {
        if (_closing) return;
        if (_fullscreen) ToggleFullscreen();
        if (!_compact)
        {
            CloseOutputVolumeFlyout();
        }
        if (!_compact)
        {
            _fullBounds = GetAppBounds();
            _fullMaximized = _presenter?.State == OverlappedPresenterState.Maximized || _settings.Maximized;
            _fullDpi = CurrentDpi();
            _presenter?.Restore();
            _compact = true;
            if (_presenter is not null)
                _presenter.IsMaximizable = false;
            _presenter?.SetBorderAndTitleBar(false, false);
            ResizeCompact();
            _nativeWindowServices?.SetCompactUpdateVisible(
                _releaseUpdateButtonState is ReleaseUpdateButtonState.Available
                    or ReleaseUpdateButtonState.Downloading or ReleaseUpdateButtonState.Verifying);
            _nativeWindowServices?.SetCaptionlessResizeFrame(true);
        }
        else
        {
            CaptureCompactGeometry();
            _compact = false;
            _nativeWindowServices?.SetCaptionlessResizeFrame(false);
            if (_presenter is not null)
                _presenter.IsMaximizable = true;
            RestoreSystemFrame();
            MoveResize(_fullBounds.IsValid ? _fullBounds : GetDefaultBounds());
            if (_fullMaximized) _presenter?.Maximize();
        }
        ApplyCompactSurface();
        _compactModeGeneration++;
        UpdateWindowPresentation();
        CaptureSettings();
        BenchPresentationChanged();
    }

    private void ToggleFullscreen()
    {
        if (_closing) return;
        if (!_fullscreen)
        {
            _windowBounds = GetAppBounds();
            _windowMaximized = _presenter?.State == OverlappedPresenterState.Maximized;
            _presenter?.Restore();
            _fullscreen = true;
            _presenter?.SetBorderAndTitleBar(false, false);
            var area = GetWorkArea();
            if (area.IsValid) MoveResize(area);
        }
        else
        {
            _fullscreen = false;
            RestoreSystemFrame();
            MoveResize(_windowBounds.IsValid ? _windowBounds : GetDefaultBounds());
            if (_windowMaximized) _presenter?.Maximize();
        }
        UpdateWindowPresentation();
    }

    // SetBorderAndTitleBar(false, false) also sets AppWindow.TitleBar.ExtendsContentIntoTitleBar, and
    // SetBorderAndTitleBar(true, true) does not clear it. Left extended, the full window loses its
    // caption row and the system caption buttons cover the right end of the toolbar.
    private void RestoreSystemFrame()
    {
        _presenter?.SetBorderAndTitleBar(true, true);
        if (_appWindow is not null && AppWindowTitleBar.IsCustomizationSupported())
            _appWindow.TitleBar.ExtendsContentIntoTitleBar = false;
    }

    private void UpdateWindowPresentation()
    {
        _fullscreenItem.Text = _fullscreen ? "Exit fullscreen" : "Enter fullscreen";
        AutomationProperties.SetName(_fullscreenItem, _fullscreen ? "Exit fullscreen" : "Enter fullscreen");
        _compactItem.Text = _compact ? "Restore full-size window" : "Compact window";
        AutomationProperties.SetName(_compactItem, _compact ? "Restore full-size window" : "Compact window");
        AutomationProperties.SetName(CompactButton, _compact ? "Restore full-size window" : "Compact window");
        ToolTipService.SetToolTip(CompactButton, ShortcutDescription(_compact ? "Restore full-size window" : "Compact window", _settings.Shortcuts.Compact));
        UpdateInfoBar.Visibility = _compact || _fullscreen ? Visibility.Collapsed : Visibility.Visible;
        UpdateInfoRow.Height = _compact || _fullscreen ? new GridLength(0) : GridLength.Auto;
        SetButtonIcons();
        SetMenuIcons();
    }


    private void RestoreFullGeometry()
    {
        if (_appWindow is null) return;
        var bounds = ShellSettings.RestoreBounds(_settings,
            ToDrawingRectangle(GetWorkArea()), CurrentDpi());
        MoveResize(ToDrawingBounds(bounds));
        if (_settings.Maximized) _presenter?.Maximize();
        _lastMaximized = _settings.Maximized;
    }

    private void ResizeCompact()
    {
        if (_appWindow is null) return;
        var restored = ShellSettings.RestoreCompactBounds(_settings,
            ToDrawingRectangle(GetWorkArea()), CurrentDpi());
        if (restored.Width <= 0 || restored.Height <= 0) return;
        // Saved Compact geometry is the client size; the window may be resized in both directions.
        var delta = GetNonClientDelta();
        var width = Math.Max(restored.Width, Dip(CompactPlayerView.LogicalMinimumWidthValue) + delta.X);
        var height = Math.Max(restored.Height, Dip(CompactPlayerView.LogicalMinimumHeightValue)) + delta.Y;
        _appWindow.Resize(new SizeInt32(width, height));
        _appWindow.Move(new PointInt32(restored.X, restored.Y));
    }

    private DrawingBounds GetAppBounds()
    {
        if (_appWindow is null) return default;
        var position = _appWindow.Position;
        var size = _appWindow.Size;
        return new DrawingBounds(position.X, position.Y, size.Width, size.Height);
    }
    private SizeInt32 GetClientSize()
    {
        if (NativeHandle != 0)
        {
            var client = default(NativeRect);
            if (GetClientRect(NativeHandle, ref client))
                return new SizeInt32(Math.Max(0, client.Right - client.Left), Math.Max(0, client.Bottom - client.Top));
        }
        return _appWindow?.Size ?? default;
    }

    private PointI GetNonClientDelta()
    {
        if (NativeHandle == 0) return default;
        var window = default(NativeRect);
        var client = default(NativeRect);
        if (!GetWindowRect(NativeHandle, ref window) || !GetClientRect(NativeHandle, ref client))
            return default;
        return new PointI(
            Math.Max(0, (window.Right - window.Left) - (client.Right - client.Left)),
            Math.Max(0, (window.Bottom - window.Top) - (client.Bottom - client.Top)));
    }

    private DrawingBounds GetDefaultBounds()
        => new(_settings.X, _settings.Y, _settings.Width, _settings.Height);

    private DrawingBounds GetWorkArea()
    {
        if (!_nativeWindowReady) return new DrawingBounds(0, 0, 1920, 1080);
        var area = DisplayArea.GetFromWindowId(_windowId, DisplayAreaFallback.Nearest).WorkArea;
        return new DrawingBounds(area.X, area.Y, area.Width, area.Height);
    }

    private static DrawingBounds ToDrawingBounds(Rectangle bounds)
        => new(bounds.X, bounds.Y, bounds.Width, bounds.Height);

    private static Rectangle ToDrawingRectangle(DrawingBounds bounds)
        => new(bounds.X, bounds.Y, bounds.Width, bounds.Height);

    private void MoveResize(DrawingBounds bounds)
    {
        if (_appWindow is null || !bounds.IsValid) return;
        _appWindow.MoveAndResize(new RectInt32 { X = bounds.X, Y = bounds.Y, Width = bounds.Width, Height = bounds.Height });
    }

    private void ScheduleSettings()
    {
        if (_closing || _fullscreen || !_nativeWindowReady) return;
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private void CaptureCompactGeometry()
    {
        if (!_compact || _appWindow is null || !_appWindow.IsVisible) return;
        var bounds = GetAppBounds();
        var clientSize = GetClientSize();
        if (!bounds.IsValid || clientSize.Width <= 0 || clientSize.Height <= 0) return;
        _settings = _settings with
        {
            CompactX = bounds.X, CompactY = bounds.Y, CompactWidth = clientSize.Width,
            CompactHeight = clientSize.Height, CompactDpi = CurrentDpi()
        };
    }

    private void CaptureSettings()
    {
        CaptureCompactGeometry();
        var bounds = _compact ? _fullBounds : _fullscreen ? _windowBounds : GetAppBounds();
        if (!bounds.IsValid) return;
        _settings = _settings with
        {
            X = bounds.X, Y = bounds.Y, Width = bounds.Width, Height = bounds.Height,
            Dpi = _compact ? _fullDpi : CurrentDpi(),
            Maximized = _compact ? _fullMaximized : _fullscreen ? _windowMaximized : _presenter?.State == OverlappedPresenterState.Maximized
        };
        _pendingSettings = _settings;
        if (_saveTask.IsCompleted) _saveTask = SaveSettingsAsync();
    }

    private async Task SaveSettingsAsync()
    {
        while (_pendingSettings is { } snapshot && !_saveCancellation.IsCancellationRequested)
        {
            _pendingSettings = null;
            try { await Task.Run(() => ShellSettings.SaveAsync(_root, snapshot, _saveCancellation.Token)); }
            catch (OperationCanceledException) { break; }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                _settingsWarning = "Settings could not be saved. Changes apply to this session only.";
                SetStatus(_settingsWarning, true);
            }
        }
    }

    private bool HandleNativeMessage(uint message, nint wParam, nint lParam, out nint result)
    {
        result = 0;
        try
        {
            if (_tray?.HandleMessage(message, wParam, lParam, out result) == true)
                return true;
        }
        catch (Exception)
        {
            SetStatus("Tray menu could not be opened.", isError: true);
            return true;
        }
        if (message == WmClose && !_closeReady)
        {
            CloseOrHideToTray();
            return true;
        }
        if (message == WmHotKey && _shortcutsEnabled)
        {
            var command = _sessionShortcuts?.CommandForHotkey(wParam);
            if (_settingsDialog is not null)
            {
                var binding = command switch
                {
                    "toggle" => _settings.Shortcuts.Toggle,
                    "previous" => _settings.Shortcuts.Previous,
                    "next" => _settings.Shortcuts.Next,
                    "compact" => _settings.Shortcuts.Compact,
                    _ => 0
                };
                if (binding != 0) _settingsDialog.CaptureRegisteredShortcut(binding);
                return true;
            }
            if (command is not null)
            {
                if (command == "compact") ToggleCompact();
                else _ = ExecutePlayerCommandAsync(command);
                return true;
            }
        }
        if (message == WmCommand && TaskbarControls.TryGetCommand(wParam, out var taskbarCommand))
        {
            if (!_closing && !_disposed) _ = ExecutePlayerCommandAsync(taskbarCommand);
            return true;
        }
        if (message == WmPowerBroadcast)
        {
            var powerEvent = wParam.ToInt64();
            if (powerEvent == PbtApmsuspend) _playerSuspended = true;
            else if (powerEvent is PbtApmresume or PbtApmresumesuspend) { _playerSuspended = false; _sleep?.CheckOnResume(); }
            if (powerEvent is PbtApmsuspend or PbtApmresume or PbtApmresumesuspend)
            {
                _playerControls?.Invalidate();
                RefreshCompactActivity();
                UpdatePlayerControls();
            }
        }
        if (message is WmSettingChange or WmThemeChanged)
            QueueShellAppearanceRefresh();
        if (TaskbarButtonCreated != 0 && message == TaskbarButtonCreated && !_closing && !_disposed)
        {
            _taskbarControls?.Recreate();
            _taskbarControls?.UpdateAppearance(CurrentDpi(), ToDrawingColor(ShellTheme.ForegroundColor));
            UpdatePlayerControls();
            return false;
        }
        if (TaskbarCreated != 0 && message == TaskbarCreated && !_closing && !_disposed)
        {
            _taskbarControls?.Recreate();
            try
            {
                _tray?.Recreate();
            }
            catch (Exception)
            {
                SetStatus("Tray icon could not be recreated after a shell restart.", isError: true);
            }
            _taskbarControls?.UpdateAppearance(CurrentDpi(), ToDrawingColor(ShellTheme.ForegroundColor));
            UpdatePlayerControls();
            if (_appWindow?.IsVisible == false) RequestActivation();
        }
        if (message == WmDisplayChange && !_fullscreen && !_closing)
        {
            if (_compact) { CaptureCompactGeometry(); ResizeCompact(); }
            else if (!_windowMaximized) MoveResize(GetAppBounds());
        }
        if (_compact && NativeWindowServices.TryHandleCaptionlessResizeFrame(
                NativeHandle, message, wParam, lParam, out result))
            return true;
        if (message == WmGetMinMaxInfo && _compact && lParam != 0)
        {
            var info = Marshal.PtrToStructure<MinMaxInfo>(lParam);
            var delta = GetNonClientDelta();
            info.MinTrackSize = new PointI(
                Dip(CompactPlayerView.LogicalMinimumSize.Width) + delta.X,
                Dip(CompactPlayerView.LogicalMinimumSize.Height) + delta.Y);
            Marshal.StructureToPtr(info, lParam, false);
            return true;
        }
        return false;
    }

    private void OnRootKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key is VirtualKey.F10 or VirtualKey.F11 or VirtualKey.F6)
        {
            args.Handled = true;
            ExecuteShellKey(args.Key, IsKeyDown(VirtualKey.Menu), IsKeyDown(VirtualKey.Shift));
        }
    }

    private void OnBrowserAcceleratorKeyPressed(
        CoreWebView2Controller sender,
        CoreWebView2AcceleratorKeyPressedEventArgs args)
    {
        if (args.KeyEventKind is not (CoreWebView2KeyEventKind.KeyDown or CoreWebView2KeyEventKind.SystemKeyDown)
            || args.PhysicalKeyStatus.WasKeyDown != 0)
            return;
        var key = (VirtualKey)args.VirtualKey;
        var alt = IsKeyDown(VirtualKey.Menu);
        var shift = IsKeyDown(VirtualKey.Shift);
        var shellKey = key is VirtualKey.F6 or VirtualKey.F10 or VirtualKey.F11
            || alt && (key is VirtualKey.Left or VirtualKey.Right or VirtualKey.M)
            || key == VirtualKey.Escape && _fullscreen;
        if (!shellKey) return;
        args.Handled = true;
        if (_closing) return;
        _dispatcherQueue.TryEnqueue(() => ExecuteShellKey(key, alt, shift));
    }

    private void OnBrowserMoveFocusRequested(
        CoreWebView2Controller sender,
        CoreWebView2MoveFocusRequestedEventArgs args)
    {
        args.Handled = true;
        var reverse = args.Reason == CoreWebView2MoveFocusReason.Previous;
        _dispatcherQueue.TryEnqueue(() =>
        {
            if (_closing || _disposed) return;
            if (reverse) MoreButton.Focus(FocusState.Keyboard);
            else FocusRail(false);
        });
    }

    private void ExecuteShellKey(VirtualKey key, bool alt, bool shift)
    {
        if (_compact)
        {
            if (key == VirtualKey.F10 || alt && key == VirtualKey.M) { CompactView.ShowMoreMenu(); return; }
            if (alt && (key == VirtualKey.Left || key == VirtualKey.Right)) return;
        }
        if (key == VirtualKey.F6) { CycleFocus(shift); return; }
        if (key == VirtualKey.F10 || alt && key == VirtualKey.M) { _moreFlyout.ShowAt(MoreButton); return; }
        if (key == VirtualKey.F11 || key == VirtualKey.Escape && _fullscreen) { ToggleFullscreen(); return; }
        if (alt && key == VirtualKey.Left && CanNavigate) _browserHost?.Core.GoBack();
        else if (alt && key == VirtualKey.Right && CanNavigate) _browserHost?.Core.GoForward();
    }

    private void CycleFocus(bool reverse)
    {
        if (_compact) { CompactView.Focus(FocusState.Keyboard); return; }
        var focused = RootGrid.XamlRoot is { } root ? FocusManager.GetFocusedElement(root) : null;
        if (focused is DependencyObject element && IsDescendantOf(element, Toolbar))
        {
            _browserHost?.Focus();
            return;
        }
        FocusRail(reverse);
    }

    private void FocusRail(bool reverse)
    {
        if (reverse)
        {
            MoreButton.Focus(FocusState.Keyboard);
            return;
        }
        if (BackButton.IsEnabled) BackButton.Focus(FocusState.Keyboard);
        else if (ForwardButton.IsEnabled) ForwardButton.Focus(FocusState.Keyboard);
        else HomeButton.Focus(FocusState.Keyboard);
    }

    private static bool IsDescendantOf(DependencyObject element, DependencyObject ancestor)
    {
        for (var current = element; current is not null; current = VisualTreeHelper.GetParent(current))
            if (ReferenceEquals(current, ancestor)) return true;
        return false;
    }

    private static bool IsKeyDown(VirtualKey key)
        => (InputKeyboardSource.GetKeyStateForCurrentThread(key) & CoreVirtualKeyStates.Down) != 0;
    private void QueueShellAppearanceRefresh()
    {
        if (_disposed || _appearanceRefreshPending) return;
        _appearanceRefreshPending = true;
        _dispatcherQueue.TryEnqueue(() =>
        {
            _appearanceRefreshPending = false;
            ApplyAppearance();
        });
    }
    private async Task ShutdownCoreAsync()
    {
        if (_disposed) return;
        CloseOutputVolumeFlyout();
        _closing = true;
        Exception? firstFailure = null;
        void RememberFailure(Exception ex) => firstFailure ??= ex;

        try { _releaseUpdateTimer.Stop(); } catch (Exception ex) { RememberFailure(ex); }
        try { _updateInfoCloseTimer?.Stop(); } catch (Exception ex) { RememberFailure(ex); }
        try { _compactUpdateNoticeTimer?.Stop(); } catch (Exception ex) { RememberFailure(ex); }
        try { _taskbarErrorTimer?.Stop(); } catch (Exception ex) { RememberFailure(ex); }
        try { _setupCleanupTimer?.Stop(); } catch (Exception ex) { RememberFailure(ex); }
        try { _gcOnHideTimer.Stop(); } catch (Exception ex) { RememberFailure(ex); }
        try { _trimOnHideTimer.Stop(); } catch (Exception ex) { RememberFailure(ex); }
        BenchStopTimers();
        try { _lifetime.Cancel(); } catch (Exception ex) { RememberFailure(ex); }
        try { await WaitForInitializationAsync(); }
        catch (Exception ex) { RememberFailure(ex); }

        try
        {
            foreach (var dialog in _ownedDialogs.ToArray())
                dialog.Close();
            _ownedDialogs.Clear();
            _settingsDialog?.Close();
        }
        catch (Exception ex) { RememberFailure(ex); }
        _settingsDialog = null;

        RootGrid.Loaded -= OnLoaded;
        try { RefreshCompactActivity(); } catch (Exception ex) { RememberFailure(ex); }
        try { _saveTimer.Stop(); } catch (Exception ex) { RememberFailure(ex); }
        try { UnregisterSessionShortcuts(); } catch (Exception ex) { RememberFailure(ex); }
        try { _playerControls?.Invalidate(); } catch (Exception ex) { RememberFailure(ex); }
        try { _playerControls?.Dispose(); } catch (Exception ex) { RememberFailure(ex); }
        _playerControls = null;
        try { DisposeOutputAudio(); } catch (Exception ex) { RememberFailure(ex); }
        try { _taskbarControls?.Dispose(); } catch (Exception ex) { RememberFailure(ex); }
        _taskbarControls = null;
        try { _sleep?.Cancel(); } catch (Exception ex) { RememberFailure(ex); }
        try { _tray?.SetVisible(false); } catch (Exception ex) { RememberFailure(ex); }
        try { _tray?.Dispose(); } catch (Exception ex) { RememberFailure(ex); }
        _tray = null;
        try { CaptureSettings(); } catch (Exception ex) { RememberFailure(ex); }
        try { _browserHost?.Dispose(); } catch (Exception ex) { RememberFailure(ex); }
        _browserHost = null;
        try { await _saveTask.WaitAsync(TimeSpan.FromMilliseconds(250)); }
        catch (TimeoutException) { try { _saveCancellation.Cancel(); } catch (Exception ex) { RememberFailure(ex); } }
        catch (OperationCanceledException) { }
        catch (Exception ex) { RememberFailure(ex); }

        try { DisposeCompactSurface(); } catch (Exception ex) { RememberFailure(ex); }
        try { _nativeWindowServices?.Dispose(); } catch (Exception ex) { RememberFailure(ex); }
        _nativeWindowServices = null;
        try { _sleep?.Dispose(); } catch (Exception ex) { RememberFailure(ex); }
        _sleep = null;
        try { _saveCancellation.Cancel(); } catch (Exception ex) { RememberFailure(ex); }
        try { _saveCancellation.Dispose(); } catch (Exception ex) { RememberFailure(ex); }

        var initialization = _initializationTask;
        if (initialization is null || initialization.IsCompleted)
        {
            try { _lifetime.Dispose(); } catch (Exception ex) { RememberFailure(ex); }
        }
        else
        {
            _ = DisposeLifetimeAfterInitializationAsync(initialization);
        }

        try { _iconCache.Dispose(); } catch (Exception ex) { RememberFailure(ex); }
        _environment = null;
        _disposed = true;
        if (firstFailure is not null)
        {
            ExitCode = ExitCode == 0 ? 1 : ExitCode;
            Console.Error.WriteLine("Native shell shutdown cleanup encountered an error.");
        }
    }

    public Task ShutdownAsync()
    {
        if (_shutdownTask is not null) return _shutdownTask;
        _shutdownTask = ShutdownAndCloseAsync();
        return _shutdownTask;
    }

    private async Task ShutdownAndCloseAsync()
    {
        try { await ShutdownCoreAsync(); }
        finally
        {
            _closeReady = true;
            if (!_windowClosed)
                Close();
        }
    }

    private int CurrentDpi()
    {
        if (NativeHandle == 0) return DefaultDpi;
        try { return (int)GetDpiForWindow(NativeHandle); }
        catch { return DefaultDpi; }
    }

    private int Dip(int logical) => Math.Max(1, (int)Math.Round(logical * CurrentDpi() / 96d));

    private static Color ToDrawingColor(Windows.UI.Color color)
        => Color.FromArgb(color.A, color.R, color.G, color.B);

    private static string? ResolveRuntimeDirectory(string root)
    {
        var fullRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        var installedRoot = RootLocator.FindInstalledRoot();
        if (installedRoot is not null
            && fullRoot.Equals(Path.TrimEndingDirectorySeparator(installedRoot), StringComparison.OrdinalIgnoreCase))
            return null;
        var manifestPath = RootLocator.WebViewRuntimeManifestPath(root);
        var runtimeRoot = Path.GetFullPath(Path.Combine(root, ".tools", "webview2"));
        if (!File.Exists(manifestPath))
        {
            if (Directory.Exists(runtimeRoot))
                throw new InvalidOperationException("The repository-local WebView2 runtime directory has no runtime-path.txt marker.");
            return null;
        }

        RootLocator.EnsureRegularFile(root, manifestPath);
        string relativeDirectory;
        try { relativeDirectory = File.ReadAllText(manifestPath).Trim(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        { throw new InvalidOperationException("The WebView2 runtime-path.txt file could not be read.", ex); }
        if (relativeDirectory.Length == 0 || relativeDirectory is "." or ".."
            || relativeDirectory != Path.GetFileName(relativeDirectory)
            || relativeDirectory.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            throw new InvalidOperationException("The WebView2 runtime-path.txt file must contain one relative version directory name.");
        var runtimeDirectory = Path.GetFullPath(Path.Combine(runtimeRoot, relativeDirectory));
        var runtimePrefix = runtimeRoot + Path.DirectorySeparatorChar;
        if (!runtimeDirectory.StartsWith(runtimePrefix, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The WebView2 runtime path escapes .tools/webview2.");
        RootLocator.EnsureNoReparseTree(root, runtimeDirectory);
        RootLocator.EnsureRegularFile(root, Path.Combine(runtimeDirectory, "msedgewebview2.exe"));
        return runtimeDirectory;
    }

    private static void EnsureSupportedWebViewRuntime(string? runtimeDirectory, CoreWebView2EnvironmentOptions options)
    {
        if (runtimeDirectory is null)
        {
            var registeredVersion = GetRegisteredEvergreenRuntimeVersion();
            if (registeredVersion is null || registeredVersion < MinimumWebView2RuntimeVersion)
            {
                var detected = registeredVersion is null
                    ? "The Microsoft WebView2 Evergreen Runtime was not registered or its version could not be verified."
                    : $"Microsoft WebView2 Evergreen Runtime {registeredVersion} is too old.";
                throw new WebView2RuntimeRequirementException(
                    $"{detected} Nativune requires {MinimumWebView2RuntimeVersionText} or later; Edge Beta/Dev/Canary does not satisfy this prerequisite. Install or update the Evergreen Runtime from {WebView2RuntimeDownloadUrl}");
            }
        }

        string versionText;
        try
        {
            versionText = CoreWebView2Environment.GetAvailableBrowserVersionString(runtimeDirectory, options);
        }
        catch (Exception ex)
        {
            throw new WebView2RuntimeRequirementException(
                $"Microsoft WebView2 Evergreen Runtime {MinimumWebView2RuntimeVersionText} or later is required. Install it from {WebView2RuntimeDownloadUrl}",
                ex);
        }

        if (!Version.TryParse(versionText, out var version))
            throw new WebView2RuntimeRequirementException(
                $"The available WebView2 runtime version could not be verified or resolved to a preview channel. Nativune requires the stable {MinimumWebView2RuntimeVersionText} or later from {WebView2RuntimeDownloadUrl}");
        if (version < MinimumWebView2RuntimeVersion)
            throw new WebView2RuntimeRequirementException(
                $"WebView2 Runtime {version} is too old. Nativune requires {MinimumWebView2RuntimeVersionText} or later; install or update it from {WebView2RuntimeDownloadUrl}");
    }

    private static Version? GetRegisteredEvergreenRuntimeVersion()
    {
        var locations = new (RegistryHive Hive, string SubKey)[]
        {
            (RegistryHive.LocalMachine,
                @"SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"),
            (RegistryHive.LocalMachine,
                @"SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"),
            (RegistryHive.CurrentUser,
                @"SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}")
        };
        Version? highestVersion = null;
        foreach (var (hive, subKey) in locations)
        {
            try
            {
                using var registry = RegistryKey.OpenBaseKey(hive, RegistryView.Default);
                using var client = registry.OpenSubKey(subKey, writable: false);
                if (client?.GetValue("pv", null, RegistryValueOptions.DoNotExpandEnvironmentNames) is not string value
                    || !Version.TryParse(value, out var version))
                    continue;
                if (highestVersion is null || version > highestVersion)
                    highestVersion = version;
            }
            catch (Exception)
            {
                // Check the other per-user or machine registration and fail closed if none verify.
            }
        }
        return highestVersion;
    }

    private sealed class WebView2RuntimeRequirementException : InvalidOperationException
    {
        public WebView2RuntimeRequirementException(string message, Exception? innerException = null)
            : base(message, innerException) { }
    }

    private void OnProcessInfosChanged()
    {
        if (_closing || _disposed || _environment is null) return;
        RefreshOutputAudio();
        try
        {
            using var snapshot = CreateToolhelp32Snapshot(2, 0);
            var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>() };
            if (snapshot.IsInvalid || !Process32First(snapshot, ref entry))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var processes = new List<(int Id, int Parent)>();
            do { processes.Add(((int)entry.ProcessId, (int)entry.ParentProcessId)); }
            while (Process32Next(snapshot, ref entry));
            var owned = new HashSet<int> { Environment.ProcessId };
            bool added;
            do
            {
                added = false;
                foreach (var process in processes)
                    if (owned.Contains(process.Parent) && owned.Add(process.Id)) added = true;
            } while (added);
            // Children inherit the Idle class of the WebView2 browser process. Chromium re-prioritises renderers
            // itself (Normal while visible, Idle+EcoQoS when hidden) but never utility services, so the network
            // and audio services would stay Idle and could starve audio fetch/output under system load.
            // Leave renderers to Chromium and give utility services normal, system-managed scheduling.
            var renderers = new HashSet<int>();
            var utilities = new HashSet<int>();
            foreach (var info in _environment.GetProcessInfos())
                if (info.Kind == CoreWebView2ProcessKind.Renderer) renderers.Add(info.ProcessId);
                else if (info.Kind == CoreWebView2ProcessKind.Utility) utilities.Add(info.ProcessId);
            foreach (var id in owned)
                if (utilities.Contains(id)) ApplyEfficiencyMode(id, efficient: false);
                else if (!renderers.Contains(id)) ApplyEfficiencyMode(id, efficient: true);
        }
        catch (Exception ex) when (ex is Win32Exception or COMException)
        {
            Console.Error.WriteLine($"Efficiency process discovery failed: {ex.Message}");
            SetStatus("Could not apply efficiency mode to the full process tree.", isError: true);
        }
    }

    private static void ApplyEfficiencyMode(int processId, bool efficient)
    {
        const uint processSetInformation = 0x0200;
        const uint idlePriorityClass = 0x0040;
        const uint normalPriorityClass = 0x0020;
        const int processPowerThrottling = 4;
        using var handle = OpenProcess(processSetInformation, false, processId);
        // ControlMask 0 hands execution-speed throttling back to Windows' own audible/visible classification.
        var state = new PowerThrottlingState { Version = 1, ControlMask = efficient ? 1u : 0u, StateMask = efficient ? 1u : 0u };
        if (handle.IsInvalid || !SetProcessInformation(handle, processPowerThrottling, ref state, Marshal.SizeOf<PowerThrottlingState>())
            || !SetPriorityClass(handle, efficient ? idlePriorityClass : normalPriorityClass))
        {
            var error = Marshal.GetLastWin32Error();
            if (error == 87 && handle.IsInvalid) return;
            Console.Error.WriteLine($"Efficiency mode failed for process {processId}: {new Win32Exception(error).Message}");
        }
    }

#pragma warning disable CS0649
    [StructLayout(LayoutKind.Sequential)]
    private struct MinMaxInfo
    {
        internal PointI Reserved;
        internal PointI MaxSize;
        internal PointI MaxPosition;
        internal PointI MinTrackSize;
        internal PointI MaxTrackSize;
    }
#pragma warning restore CS0649

    [StructLayout(LayoutKind.Sequential)]
    private struct PointI { public int X, Y; public PointI(int x, int y) { X = x; Y = y; } }
    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }
    [StructLayout(LayoutKind.Sequential)] private struct PowerThrottlingState { public uint Version, ControlMask, StateMask; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size, Usage, ProcessId; public UIntPtr DefaultHeapId; public uint ModuleId, Threads, ParentProcessId;
        public int BasePriority; public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string Executable;
    }

    private Window CreateDialogWindow(string title, FrameworkElement content, int width, int height)
    {
        var dialog = new Window { Title = title, Content = content };
        _ownedDialogs.Add(dialog);
        dialog.Closed += (_, _) =>
        {
            _ownedDialogs.Remove(dialog);
            if (NativeHandle != 0)
                EnableWindow(NativeHandle, true);
            if (!_closing && !_disposed)
                Activate();
        };

        if (NativeHandle != 0)
            EnableWindow(NativeHandle, false);
        try
        {
            var handle = WindowNative.GetWindowHandle(dialog);
            if (handle == 0)
            {
                dialog.Activate();
                handle = WindowNative.GetWindowHandle(dialog);
            }
            if (handle != 0 && NativeHandle != 0)
                SetWindowLongPtr(handle, -8, NativeHandle);
            ShellTheme.ApplyToWindow(dialog);
            var id = Win32Interop.GetWindowIdFromWindow(handle);
            var app = AppWindow.GetFromWindowId(id)
                ?? throw new InvalidOperationException("The dialog AppWindow could not be resolved.");
            app.Resize(new SizeInt32(DipForDialog(width), DipForDialog(height)));
            var owner = GetAppBounds();
            var size = app.Size;
            app.Move(new PointInt32(owner.X + Math.Max(0, (owner.Width - size.Width) / 2),
                owner.Y + Math.Max(0, (owner.Height - size.Height) / 2)));
            return dialog;
        }
        catch
        {
            _ownedDialogs.Remove(dialog);
            if (NativeHandle != 0)
                EnableWindow(NativeHandle, true);
            throw;
        }
    }

    private int DipForDialog(int value) => Math.Max(1, (int)Math.Round(value * CurrentDpi() / 96d));

    [DllImport("user32.dll")] private static extern bool FlashWindow(nint window, bool invert);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] private static extern int RegisterWindowMessage(string message);
    [DllImport("user32.dll")] private static extern uint GetDpiForWindow(nint window);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetClientRect(nint window, ref NativeRect rect);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(nint window, ref NativeRect rect);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnableWindow(nint window, bool enable);
    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern nint SetWindowLongPtr(nint window, int index, nint value);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern SafeFileHandle CreateToolhelp32Snapshot(uint flags, uint processId);
    [DllImport("kernel32.dll", EntryPoint = "Process32FirstW", SetLastError = true)] private static extern bool Process32First(SafeFileHandle snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", EntryPoint = "Process32NextW", SetLastError = true)] private static extern bool Process32Next(SafeFileHandle snapshot, ref ProcessEntry entry);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern SafeProcessHandle OpenProcess(uint access, bool inheritHandle, int processId);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetProcessInformation(SafeProcessHandle process, int informationClass, ref PowerThrottlingState information, int informationSize);
    [DllImport("kernel32.dll", SetLastError = true)] private static extern bool SetPriorityClass(SafeProcessHandle process, uint priorityClass);
    [DllImport("kernel32.dll")] private static extern nint GetCurrentProcess();
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessWorkingSetSizeEx(nint process, nint minimumWorkingSetSize, nint maximumWorkingSetSize, uint flags);

}
