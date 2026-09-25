using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Input;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using Microsoft.UI.Xaml.Shapes;
using Windows.Foundation;
using Windows.System;

namespace Nativune;

/// <summary>
/// Native-only compact playback surface. It owns presentation state and gestures, never a WebView
/// or service state. The host remains the sole owner of playback reads and command dispatch.
/// </summary>
public sealed partial class CompactPlayerView : UserControl, IDisposable
{
    private const double DegreesPerScrubDip = 0.35;
    private const double DegreesPerSecond = 12;
    private const string CompactVolumeUnavailableHelp = "App output control is unavailable.";

    private readonly NativeIconCache _iconCache = new();
    private IconElement? _previousIconElement;
    private IconElement? _playPauseIconElement;
    private IconElement? _nextIconElement;
    private IconElement? _likeIconElement;
    private IconElement? _dislikeIconElement;
    private IconElement? _playlistsIconElement;
    private IconElement? _volumeIconElement;
    private IconElement? _repeatIconElement;
    private IconElement? _shuffleIconElement;
    private IconElement? _returnToFullIconElement;
    private IconElement? _moreIconElement;
    private IconElement? _minimizeIconElement;
    private IconElement? _closeIconElement;
    private IconElement? _timerIconElement;
    private IconElement? _settingsMenuIconElement;
    private IconElement? _statusMenuIconElement;
    private IconElement? _topmostMenuIconElement;
    private string? _playPauseIconName;
    private string? _volumeIconName;
    private string? _repeatIconName;
    private string? _timerIconName;
    private string? _likeIconName;
    private string? _dislikeIconName;
    private bool _playVisualInitialized;
    private bool _lastPlayVisualEnabled;
    private bool _lastPlayPointerOver;
    private bool _lastPlayPressed;
    private bool _lastPlayHighContrast;
    private bool _repeatMarkerThemeInitialized;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _animationTimer;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _volumeCommitTimer;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _volumeHoverCloseTimer;
    // A short notice under the title (e.g. "Disliked … · skipping to the next song").
    private const double NoticeSeconds = 5;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _noticeTimer;
    private string _notice = string.Empty;
    private string? _pendingDislikeTitle;
    private readonly CompactArtworkCanvas _artwork;
    private readonly CompactMarqueeText _title;
    private readonly TextBlock _inlineStatus;
    private readonly TextBlock _elapsed;
    private readonly TextBlock _duration;
    private readonly CompactSeekSlider _seek;
    private readonly ProgressBar _seekProgress;
    private readonly Button _previous;
    private readonly Button _playPause;
    private readonly Button _next;
    private readonly ToggleButton _like;
    private readonly ToggleButton _dislike;
    private readonly Button _volume;
    private readonly Button _repeat;
    private readonly ContentControl _repeatIcon;
    private readonly TextBlock _repeatMarker;
    private readonly Button _shuffle;
    private readonly ContentControl _shuffleIcon;
    private readonly Ellipse _shuffleMarker;
    private readonly Button _timer;
    private readonly Button _returnToFull;
    private readonly Button _more;
    private readonly Button _minimize;
    private readonly Button _close;
    private readonly MenuFlyout _moreMenu;
    private readonly MenuFlyoutItem _settingsItem;
    private readonly MenuFlyoutItem _statusItem;
    private readonly ToggleMenuFlyoutItem _topmostItem;
    private readonly MenuFlyoutItem _versionItem;
    private readonly Flyout _volumePopup;
    private readonly Grid _volumePopupSurface;
    private readonly CompactVolumeSlider _volumeSlider;
    private readonly TextBlock _volumeValue;
    private readonly ContentControl _timerIcon;
    private readonly TextBlock _timerText;
    private readonly Canvas _layoutCanvas;

    private CompactPlaybackState? _state;
    private readonly CompactRatingGate _ratingGate = new();
    private bool _reduceMotion;
    private bool _active = true;
    private bool _disposed;
    private bool _updatingControls;
    private bool _dragging;
    private bool _playPointerOver;
    private bool _playPressed;
    private double _dragStartAngle;
    private DateTime _lastAnimation;
    private double _outputVolume;
    private bool _outputMuted;
    private bool _outputAvailable;
    private bool _outputSessionActive;
    private double? _pendingOutputVolume;
    private DateTime _outputPendingUntil;
    private double? _pendingSeek;
    private DateTime _seekPendingUntil;
    private CompactPlaybackState? _seekPendingState;
    private TimeSpan? _timerRemaining;
    private string _statusMessage = string.Empty;
    private bool _statusIsError;
    private FrameworkElement? _popupInvoker;
    private bool _volumeButtonPointerOver;
    private bool _volumePopupPointerOver;
    private bool _volumeOpeningFromHover;
    private bool _volumePinnedOpen;
    private bool _volumeFocusSliderOnOpen;
    private bool _restoreVolumeFocusOnClose;
    private ShortcutBindings _shortcutBindings = ShortcutBindings.Default;
    // Playlists: the website's own sidebar playlists, read on demand and never logged.
    private readonly Button _playlists;
    private readonly MenuFlyout _playlistMenu;
    private string? _pendingPlaylistTitle;

    internal event Action<string, double?>? CommandRequested;
    internal event Action? ReturnToFullRequested;
    internal event Action? SettingsRequested;
    internal event Action? StatusRequested;
    internal event Action? TimerRequested;
    internal event Action? CancelTimerRequested;
    internal event Action? ToggleTopmostRequested;
    internal event Action? MinimizeRequested;
    internal event Action? CloseRequested;
    internal event Action? PlaylistsRequested;
    internal event Action<int, string>? PlaylistChosen;

    public CompactPlayerView()
    {
        InitializeComponent();

        _layoutCanvas = LayoutCanvas;
        _artwork = Artwork;
        _title = Title;
        _inlineStatus = InlineStatus;
        _elapsed = Elapsed;
        _duration = Duration;
        _seek = Seek;
        _seekProgress = SeekProgress;
        _previous = Previous;
        _playPause = PlayPause;
        _next = Next;
        _like = Like;
        _dislike = Dislike;
        _volume = Volume;
        _repeat = Repeat;
        _repeatIcon = RepeatIcon;
        _repeatMarker = RepeatMarker;
        _shuffle = Shuffle;
        _shuffleIcon = ShuffleIcon;
        _shuffleMarker = ShuffleMarker;
        _timer = Timer;
        _returnToFull = ReturnToFull;
        _more = More;
        _minimize = Minimize;
        _close = Close;
        _playlists = Playlists;
        _playlistMenu = PlaylistMenu;
        _moreMenu = MoreMenu;
        _settingsItem = SettingsItem;
        _statusItem = StatusItem;
        _topmostItem = TopmostItem;
        _versionItem = VersionItem;
        _versionItem.Text = AppVersion.DisplayName;
        AutomationProperties.SetName(_versionItem, $"About {AppVersion.DisplayName}");
        _volumePopup = VolumePopup;
        _volumePopupSurface = VolumePopupSurface;
        _volumeSlider = VolumeSlider;
        _volumeValue = VolumeValue;
        _timerIcon = TimerIcon;
        _timerText = TimerText;

        var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread()
            ?? throw new InvalidOperationException("Compact player requires a DispatcherQueue.");
        _animationTimer = dispatcher.CreateTimer();
        _animationTimer.Interval = TimeSpan.FromMilliseconds(33);
        _animationTimer.IsRepeating = true;
        _animationTimer.Tick += (_, _) => AnimationTick();
        _volumeCommitTimer = dispatcher.CreateTimer();
        _volumeCommitTimer.Interval = TimeSpan.FromMilliseconds(200);
        _volumeCommitTimer.Tick += (_, _) =>
        {
            _volumeCommitTimer.Stop();
            var pending = _pendingOutputVolume;
            if (!_disposed && _active && _volumeSlider.IsEnabled
                && !_volumeSlider.Dragging && pending.HasValue)
                RaiseCommand("output-volume", pending.Value);
        };
        _volumeHoverCloseTimer = dispatcher.CreateTimer();
        _volumeHoverCloseTimer.Interval = TimeSpan.FromMilliseconds(550);
        _volumeHoverCloseTimer.IsRepeating = false;
        _volumeHoverCloseTimer.Tick += (_, _) => CloseHoverVolumePopup();
        _noticeTimer = dispatcher.CreateTimer();
        _noticeTimer.Interval = TimeSpan.FromSeconds(NoticeSeconds);
        _noticeTimer.IsRepeating = false;
        _noticeTimer.Tick += (_, _) => ClearNotice();

        ConfigureControls();
        InitializeLayout();
        SetOutputVolume(0, false, false);
        SetPlayback(null);
        SetPreferences(false, false);
        SetActive(true);
        ApplyAppearance();
        SizeChanged += (_, _) =>
        {
            LayoutControls();
            _title.RecalculateOverflow();
            UpdateAnimationTimer();
        };
        Loaded += (_, _) =>
        {
            ApplyAppearance();
            LayoutControls();
            UpdateAnimationTimer();
        };
        Unloaded += (_, _) =>
        {
            if (!_disposed) _animationTimer.Stop();
        };
    }

    internal static double ClampSeekTarget(double position, double duration)
    {
        if (!double.IsFinite(duration) || duration <= 0) return 0;
        if (!double.IsFinite(position)) return position > 0 ? duration : 0;
        return Math.Clamp(position, 0, duration);
    }

    internal static double KeyboardSeekTarget(double position, double duration, int deltaSeconds)
        => ClampSeekTarget(position + deltaSeconds, duration);

    internal static double SeekPreviewAngle(double startAngle, double horizontalDeltaDip, bool reduceMotion)
        => reduceMotion ? NormalizeAngle(startAngle) : NormalizeAngle(startAngle + horizontalDeltaDip * DegreesPerScrubDip);

    internal static bool ShouldAnimate(bool active, bool visible, bool reduceMotion, bool paused, bool longTitle)
        => active && visible && !reduceMotion && (!paused || longTitle);

    internal static bool ShouldCommitSeek(bool hasPendingTarget, bool cancelled)
        => hasPendingTarget && !cancelled;



    internal void SetPlayback(CompactPlaybackState? state)
    {
        if (_disposed) return;
        var previousState = _state;
        var previousTitle = DisplayTitle(previousState);
        var nextTitle = DisplayTitle(state);
        if (_seek.Dragging && (state is null || _state is null
            || CompactPlayback.ComputeSignature(state) != CompactPlayback.ComputeSignature(_state)
            || state.WebsiteClock != _state.WebsiteClock))
            _seek.CancelDrag();

        _state = state;
        _ratingGate.Observe(state is null ? null : CompactPlayback.ComputeSignature(state),
            state?.Liked, state?.Disliked, Environment.TickCount64);
        if (_pendingSeek.HasValue && (state is null || _seekPendingState is null
            || CompactPlayback.ComputeSignature(state) != CompactPlayback.ComputeSignature(_seekPendingState)
            || state.WebsiteClock != _seekPendingState.WebsiteClock))
            ClearPendingSeek();
        _updatingControls = true;
        try
        {
            if (state is null)
                BindUnavailableState();
            else
                BindPlaybackState(state);
        }
        finally
        {
            _updatingControls = false;
        }

        UpdateInlineStatus();
        RefreshShortcutDescriptions();
        RefreshBoundIcons();
        if (!string.Equals(previousTitle, nextTitle, StringComparison.Ordinal))
            _title.RecalculateOverflow();
        UpdateAnimationTimer();
    }

    internal void SetOutputVolume(double value, bool muted, bool available, bool sessionActive = true)
    {
        if (_disposed) return;
        _outputVolume = Math.Clamp(double.IsFinite(value) ? value : 0, 0, 1);
        _outputMuted = muted;
        _outputAvailable = available;
        _outputSessionActive = sessionActive;
        if (!available || _pendingOutputVolume is { } pending
            && (Math.Abs(value - pending) <= 0.0005 || DateTime.UtcNow >= _outputPendingUntil))
        {
            _pendingOutputVolume = null;
            if (!available) _volumeCommitTimer.Stop();
        }
        var sliderStep = Math.Round(_outputVolume * _volumeSlider.Maximum, MidpointRounding.AwayFromZero);
        _updatingControls = true;
        try
        {
            if (!_volumeSlider.Dragging && !_pendingOutputVolume.HasValue)
                _volumeSlider.Value = sliderStep;
            SetTextIfChanged(_volumeValue, FormatVolumePercent(_volumeSlider.Value));
        }
        finally { _updatingControls = false; }
        UpdateVolumeAvailability();
        RefreshBoundIcons();
    }
    private void ClearPendingSeek()
    {
        _pendingSeek = null;
        _seekPendingState = null;
    }

    public void SetArtwork(BitmapImage? artwork)
    {
        if (_disposed) return;
        _artwork.SetImage(artwork);
    }

    public void ApplyAppearance()
    {
        if (_disposed) return;
        _playVisualInitialized = false;
        _repeatMarkerThemeInitialized = false;
        ShellTheme.Apply(this);
        _artwork.ApplyTheme();
        _title.ApplyTheme();
        RootGrid.Background = ShellTheme.Brush("CanvasBrush", ColorHelper.FromArgb(0xFF, 0x03, 0x03, 0x03));
        _inlineStatus.Foreground = ShellTheme.Brush("SecondaryTextBrush", ColorHelper.FromArgb(0xFF, 0xAA, 0xAA, 0xAA));
        _elapsed.Foreground = _inlineStatus.Foreground;
        _duration.Foreground = _inlineStatus.Foreground;
        BindButtonTheme();
        ApplySecondaryVisuals();
        RefreshBoundIcons();
        SetRepeatAccessibility(_state?.Repeat is { } repeat ? FormatRepeat(repeat) : null, _state?.CanRepeat == true);
        _shuffleMarker.Fill = ShellTheme.Brush("FocusStrokeBrush", Colors.White);
        LayoutControls();
        _title.RecalculateOverflow();
        InvalidateArrange();
    }

    public void SetShortcutDescriptions(int toggle, int previous, int next, int compact)
    {
        if (_disposed) return;
        _shortcutBindings = new ShortcutBindings(toggle, previous, next, compact);
        RefreshShortcutDescriptions();
    }

    public void SetPreferences(bool reduceMotion, bool topmost)
    {
        if (_disposed) return;
        if (_reduceMotion != reduceMotion && reduceMotion && _seek.Dragging)
            _seek.CancelDrag();
        _reduceMotion = reduceMotion;
        _topmostItem.IsChecked = topmost;
        _title.ReduceMotion = reduceMotion;
        _title.RecalculateOverflow();
        UpdateAnimationTimer();
    }

    public void SetTimer(TimeSpan? remaining)
    {
        if (_disposed) return;
        TimeSpan? next = remaining is { } value && value > TimeSpan.Zero ? value : null;
        var wasActive = _timerRemaining.HasValue;
        _timerRemaining = next;
        UpdateTimerVisual();
        if (wasActive != next.HasValue)
            RefreshBoundIcons();
    }

    public void SetStatus(string message, bool isError = false)
    {
        if (_disposed) return;
        _statusMessage = message ?? string.Empty;
        _statusIsError = isError;
        // A newer error takes the line under the title over from a notice.
        if (isError && _statusMessage.Length != 0) ClearNotice(update: false);
        SetAccessible(_more, "More", _statusMessage.Length == 0
            ? "More settings and application status."
            : $"More settings and application status. Current status: {_statusMessage}");
        UpdateInlineStatus();
    }

    private void UpdateStatusMenuItem()
    {
        _statusItem.IsEnabled = true;
        _statusItem.Text = _statusIsError ? "Application status (error)" : "Application status";
        SetAccessible(_statusItem, "Read application status",
            BuildStatusMenuDescription(_statusMessage, _state is not null));
    }

    internal static string BuildStatusMenuDescription(string status, bool playbackAvailable)
    {
        var current = string.IsNullOrWhiteSpace(status)
            ? "No current application status has been reported."
            : status;
        return playbackAvailable
            ? current
            : current + " Player unavailable: Nativune has not confirmed a current playback state. "
                + "This status alone does not identify a YouTube Music website error; return to full view to continue.";
    }

    public void ShowMoreMenu()
    {
        if (_disposed || !_active || Visibility != Visibility.Visible) return;
        _popupInvoker = _more;
        _moreMenu.ShowAt(_more);
    }

    public void SetActive(bool active)
    {
        if (_disposed) return;
        _active = active;
        if (!active)
        {
            _volumeCommitTimer.Stop();
            _volumeHoverCloseTimer.Stop();
            _volumeButtonPointerOver = false;
            _volumePopupPointerOver = false;
            _volumePinnedOpen = false;
            _volumeFocusSliderOnOpen = false;
            _restoreVolumeFocusOnClose = false;
            ClearPendingSeek();
            _pendingOutputVolume = null;
            _volumeSlider.CancelDrag();
            _moreMenu.Hide();
            _playlistMenu.Hide();
            _volumePopup.Hide();
            _seek.CancelDrag();
            _animationTimer.Stop();
            ClearNotice();
        }
        else
            UpdateAnimationTimer();
    }
    // The host reports how a Compact command ended. Nothing reached the website for NotSent/Changed,
    // so a pending rating or seek preview is released instead of waiting for a result that won't come.
    internal void CommandFinished(string command, PlayerCommandOutcome outcome)
    {
        if (_disposed) return;
        if (command == "dislike" && outcome == PlayerCommandOutcome.Sent && _pendingDislikeTitle is { } disliked)
            ShowNotice($"Disliked \u201C{disliked}\u201D \u00B7 skipping to the next song");
        if (command == "dislike") _pendingDislikeTitle = null;
        if (command == "play-playlist" && outcome == PlayerCommandOutcome.Sent && _pendingPlaylistTitle is { } playlist)
            ShowNotice($"Playing \u201C{playlist}\u201D");
        if (outcome is not (PlayerCommandOutcome.NotSent or PlayerCommandOutcome.Changed)) return;
        if (command is "like" or "dislike") _ratingGate.NotSent();
        else if (command == "seek") ClearPendingSeek();
        else if (command == "play-playlist")
        {
            _pendingPlaylistTitle = null;
            return;
        }
        else return;
        SetPlayback(_state);
    }

    // Opens the playlist menu with what the host read from the website (null = could not read).
    internal void ShowPlaylists(IReadOnlyList<CompactPlayback.PlaylistEntry>? playlists)
    {
        if (_disposed || !_active || Visibility != Visibility.Visible) return;
        _playlistMenu.Items.Clear();
        if (playlists is null || playlists.Count == 0)
        {
            _playlistMenu.Items.Add(new MenuFlyoutItem
            {
                IsEnabled = false,
                Text = playlists is null
                    ? "Couldn't read playlists from the website. Try again."
                    : "No playlists found. Sign in to YouTube Music to see yours."
            });
        }
        else
        {
            _playlistMenu.Items.Add(new MenuFlyoutItem { IsEnabled = false, Text = "Play a playlist" });
            _playlistMenu.Items.Add(new MenuFlyoutSeparator());
            for (var index = 0; index < playlists.Count; index++)
            {
                var (title, subtitle) = (playlists[index].Title, playlists[index].Subtitle);
                var position = index;
                var item = new MenuFlyoutItem { Text = title };
                var help = subtitle.Length == 0 ? $"Play {title}." : $"Play {title}, {subtitle}.";
                AutomationProperties.SetHelpText(item, help);
                if (subtitle.Length != 0) ToolTipService.SetToolTip(item, subtitle);
                item.Click += (_, _) =>
                {
                    _pendingPlaylistTitle = title;
                    PlaylistChosen?.Invoke(position, title);
                };
                _playlistMenu.Items.Add(item);
            }
        }
        // When the layout has moved Playlists into More, anchor the menu at More instead.
        var anchor = _playlists.Visibility == Visibility.Visible ? (FrameworkElement)_playlists : _more;
        _popupInvoker = anchor;
        // ShowAt instead of letting a click open it: the list is read from the website first.
        _playlistMenu.ShowAt(anchor);
    }

    private void RequestRating(ToggleButton button, string command)
    {
        var state = _state;
        RestoreRatingState(button, command == "like" ? state?.Liked : state?.Disliked);
        var now = Environment.TickCount64;
        if (state is null || !_ratingGate.Allows(now)) return;
        _ratingGate.Sent(state.Liked, state.Disliked, now);
        // Only a new dislike makes YouTube Music skip; removing one does not.
        _pendingDislikeTitle = command == "dislike" && state.Disliked == false ? state.Title : null;
        SetPlayback(state);
        RaiseCommand(command);
    }

    private void ShowNotice(string notice)
    {
        _notice = notice;
        _noticeTimer.Stop();
        _noticeTimer.Start();
        UpdateInlineStatus();
        // Screen readers hear the notice without focus moving.
        Microsoft.UI.Xaml.Automation.Peers.FrameworkElementAutomationPeer.FromElement(_inlineStatus)
            ?.RaiseAutomationEvent(Microsoft.UI.Xaml.Automation.Peers.AutomationEvents.LiveRegionChanged);
    }

    private void ClearNotice(bool update = true)
    {
        _noticeTimer.Stop();
        if (_notice.Length == 0) return;
        _notice = string.Empty;
        if (update) UpdateInlineStatus();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _animationTimer.Stop();
        _volumeCommitTimer.Stop();
        _volumeHoverCloseTimer.Stop();
        _noticeTimer.Stop();
        _pendingOutputVolume = null;
        ClearPendingSeek();
        _moreMenu.Hide();
        _playlistMenu.Hide();
        _volumePopup.Hide();
        _seek.CancelDrag();
        _volumeSlider.CancelDrag();
        _artwork.SetImage(null);
        _iconCache.Dispose();
        CommandRequested = null;
        ReturnToFullRequested = null;
        SettingsRequested = null;
        StatusRequested = null;
        TimerRequested = null;
        CancelTimerRequested = null;
        ToggleTopmostRequested = null;
        MinimizeRequested = null;
        CloseRequested = null;
        PlaylistsRequested = null;
        PlaylistChosen = null;
    }


    private void ConfigureControls()
    {
        ConfigureButton(_previous, "Previous item", "Previous item.");
        ConfigureButton(_playPause, "Playback controls unavailable", "Playback controls unavailable.");
        ConfigureButton(_next, "Next item", "Next item.");
        ConfigureButton(_volume, "App output mute", "Activate to mute or unmute app output. Hover to adjust app output; press Down or open the context menu for touch and keyboard access to the slider.");
        ConfigureButton(_repeat, "Repeat unavailable", "Repeat state is unavailable until playback controls recover.");
        ConfigureButton(_shuffle, "Shuffle unavailable", "Shuffle is unavailable until playback controls recover.");
        ConfigureButton(_playlists, "Playlists", "Show your YouTube Music playlists and play one.");
        ConfigureButton(_returnToFull, "Return to full", "Return to the full app.");
        ConfigureButton(_more, "More", "More settings and application status.");
        ConfigureButton(_minimize, "Minimize", "Minimize window.");
        ConfigureButton(_close, "Close", "Close app and stop playback.");
        ConfigureButton(_timer, "Set pause timer", "Set a pause timer; the app stays open.");
        ConfigureButton(_like, "Like unavailable", "Like state is unavailable until playback controls recover.");
        ConfigureButton(_dislike, "Dislike unavailable", "Dislike state is unavailable until playback controls recover.");

        _title.IsTabStop = true;
        SetAccessible(_title, "Track title", "Track title.");
        SetAccessible(_artwork, "Album artwork", "Circular album artwork. Artwork is decorative.");
        SetAccessible(_inlineStatus, "Application status", "Application status.");
        AutomationProperties.SetLiveSetting(_inlineStatus, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        SetAccessible(_elapsed, "Elapsed time", "Elapsed playback time.");
        SetAccessible(_duration, "Total duration", "Total duration.");
        SetAccessible(_seek, "Playback position unavailable", "Playback position unavailable.");
        SetAccessible(_seekProgress, "Playback progress unavailable", "Seeking unavailable.");
        SetAccessible(_volumeSlider, "App output volume", "App output volume from zero to one hundred percent. Use Left and Right or Up and Down for 0.1 percent steps, Page Up and Page Down for 1 percent, Home for 0 percent and End for 100 percent.");
        _elapsed.Text = "--:--";
        _duration.Text = "--:--";
        _inlineStatus.Visibility = Visibility.Collapsed;
        _seek.DragStarted += BeginSeekDrag;
        _seek.DragPreview += PreviewSeekDrag;
        _seek.DragCommitted += CommitSeekDrag;
        _seek.KeyboardCommitted += CommitKeyboardSeek;
        _seek.DragCancelled += CancelSeekDrag;
        _volumeSlider.ValueChanged += VolumeSliderChanged;
        _volumeSlider.Committed += VolumeSliderCommitted;
        _volume.PointerEntered += VolumePointerEntered;
        _volume.PointerExited += VolumePointerExited;
        _volumePopupSurface.PointerEntered += VolumePopupPointerEntered;
        _volumePopupSurface.PointerExited += VolumePopupPointerExited;
        _volumePopupSurface.AddHandler(UIElement.PointerPressedEvent,
            new PointerEventHandler(PinVolumePopupFromPointer), true);
        _volumePopupSurface.GotFocus += (_, _) => PinVolumePopupFromInteraction();

        _previous.Click += (_, _) => RaiseCommand("previous");
        _next.Click += (_, _) => RaiseCommand("next");
        _playPause.Click += (_, _) => RaiseCommand("toggle");
        _playPause.PointerEntered += (_, _) =>
        {
            _playPointerOver = true;
            ApplyPlayVisual();
        };
        _playPause.PointerExited += (_, _) =>
        {
            _playPointerOver = false;
            _playPressed = false;
            ApplyPlayVisual();
        };
        _playPause.PointerPressed += (_, _) =>
        {
            _playPressed = true;
            ApplyPlayVisual();
        };
        _playPause.PointerReleased += (_, _) =>
        {
            _playPressed = false;
            ApplyPlayVisual();
        };
        _playPause.GotFocus += (_, _) =>
            _playPause.BorderBrush = ShellTheme.Brush("FocusStrokeBrush", Colors.White);
        _playPause.LostFocus += (_, _) =>
            _playPause.BorderBrush = ShellTheme.Brush("RaisedBrush", Colors.Transparent);
        _like.Click += (_, _) => RequestRating(_like, "like");
        _dislike.Click += (_, _) => RequestRating(_dislike, "dislike");
        _volume.Click += (_, _) =>
        {
            _volumeHoverCloseTimer.Stop();
            _volumePopup.Hide();
            RaiseCommand("output-mute");
        };
        _volume.ContextRequested += (_, e) =>
        {
            if (!_volume.IsEnabled || !_active) return;
            e.Handled = true;
            OpenVolumePopupForInteraction();
        };
        _volume.KeyDown += (_, e) =>
        {
            if (e.Key != VirtualKey.Down || !_volume.IsEnabled || !_active) return;
            e.Handled = true;
            OpenVolumePopupForInteraction();
        };
        _volumePopup.Closed += VolumePopupClosed;
        _volumePopup.Opened += (_, _) =>
        {
            if (_volumeFocusSliderOnOpen && _volumeSlider.IsEnabled)
                _volumeSlider.Focus(FocusState.Programmatic);
            _volumeFocusSliderOnOpen = false;
        };
        _repeat.Click += (_, _) => RaiseCommand("repeat");
        _shuffle.Click += (_, _) => RaiseCommand("shuffle");
        _timer.Click += (_, _) =>
        {
            if (_timerRemaining.HasValue) CancelTimerRequested?.Invoke();
            else TimerRequested?.Invoke();
        };
        _returnToFull.Click += (_, _) => ReturnToFullRequested?.Invoke();
        _more.Click += (_, _) => ShowMoreMenu();
        _minimize.Click += (_, _) => MinimizeRequested?.Invoke();
        _close.Click += (_, _) => CloseRequested?.Invoke();
        _playlists.Click += (_, _) =>
        {
            if (_active) PlaylistsRequested?.Invoke();
        };
        // Right-click and touch-hold also read a fresh list rather than showing the previous one.
        _playlists.ContextRequested += (_, e) =>
        {
            e.Handled = true;
            if (_active) PlaylistsRequested?.Invoke();
        };
        _playlistMenu.Closed += (_, _) => RestorePopupFocus();
        foreach (var button in new ButtonBase[]
        {
            _previous, _next, _like, _dislike, _playlists, _repeat, _shuffle, _volume, _timer,
            _returnToFull, _more, _minimize, _close, _playPause
        })
            button.IsEnabledChanged += (_, _) => ApplySecondaryVisuals();

        _settingsItem.Click += (_, _) => SettingsRequested?.Invoke();
        _statusItem.Click += (_, _) => StatusRequested?.Invoke();
        _topmostItem.Click += (_, _) => ToggleTopmostRequested?.Invoke();
        _moreMenu.Closed += (_, _) => RestorePopupFocus();

    }

    private void BindUnavailableState()
    {
        ClearPendingSeek();
        var title = DisplayTitle(null);
        _title.SetText(title);
        SetToolTipIfChanged(_title, null);
        SetAccessible(_title, title, "Player unavailable. Return to the full app remains available.");
        _artwork.SetImage(null);
        SetTextIfChanged(_elapsed, "--:--");
        SetTextIfChanged(_duration, "--:--");
        if (_seek.IsEnabled) _seek.IsEnabled = false;
        _seek.Visibility = Visibility.Visible;
        _seekProgress.Visibility = Visibility.Collapsed;
        _seek.SetPositionSeconds(0, 0);
        SetAccessible(_seek, "Playback position unavailable", "Playback position unavailable. Return to the full app remains available.");
        SetEnabled(_previous, false, "Previous item unavailable", "Previous item is unavailable until playback controls recover.");
        SetEnabled(_playPause, false, "Playback controls unavailable", "Playback controls unavailable. Return to the full app remains available.");
        SetEnabled(_next, false, "Next item unavailable", "Next item is unavailable until playback controls recover.");
        if (_like.IsEnabled) _like.IsEnabled = false;
        if (_like.IsChecked != null) _like.IsChecked = null;
        SetAccessible(_like, "Like unavailable", "Like state is unavailable until playback controls recover.");
        if (_dislike.IsEnabled) _dislike.IsEnabled = false;
        if (_dislike.IsChecked != null) _dislike.IsChecked = null;
        SetAccessible(_dislike, "Dislike unavailable", "Dislike state is unavailable until playback controls recover.");
        // Playback state availability does not determine whether app output is controllable.
        if (_repeat.IsEnabled) _repeat.IsEnabled = false;
        SetRepeatAccessibility(null, false);
        if (_shuffle.IsEnabled) _shuffle.IsEnabled = false;
        SetShuffleAccessibility(null, false);
    }

    // Without a coherent website clock, the bounded media clock remains explicitly
    // approximate and read-only.
    internal static bool CanDisplayCurrentMediaClock(CompactPlaybackState state)
        => !state.WebsiteClock && state.ClockMismatch && double.IsFinite(state.Position)
            && double.IsFinite(state.Duration) && state.Duration > 0
            && state.Position >= 0 && state.Position <= state.Duration + 2;

    private void BindPlaybackState(CompactPlaybackState state)
    {
        var title = DisplayTitle(state);
        _title.SetText(title);
        SetToolTipIfChanged(_title, title);
        var mediaClock = CanDisplayCurrentMediaClock(state);
        var displayPosition = mediaClock ? Math.Min(state.Position, state.Duration) : state.Position;
        var clockMismatch = state.ClockMismatch;
        SetAccessible(_title, title, title);
        var canSeek = !clockMismatch && state.CanSeek
            && state.Duration > 0 && double.IsFinite(state.Duration);
        if (!canSeek) ClearPendingSeek();
        if (_seek.Dragging && !canSeek) _seek.CancelDrag();
        if (!double.Equals(_seek.DurationSeconds, state.Duration))
            _seek.DurationSeconds = state.Duration;
        if (_seek.IsEnabled != canSeek) _seek.IsEnabled = canSeek;
        _seek.Visibility = canSeek || state.Duration <= 0 ? Visibility.Visible : Visibility.Collapsed;
        _seekProgress.Visibility = canSeek || state.Duration <= 0 ? Visibility.Collapsed : Visibility.Visible;
        if (!canSeek && state.Duration > 0)
        {
            _seekProgress.Value = Math.Clamp(
                (clockMismatch && !mediaClock ? 0 : displayPosition)
                    / state.Duration * _seekProgress.Maximum, 0, _seekProgress.Maximum);
            SetAccessible(_seekProgress, "Playback progress",
                mediaClock
                    ? $"Approximate media time {FormatTime(displayPosition)} of {FormatTime(state.Duration)}. Website seek slider disagrees; seeking is unavailable."
                    : clockMismatch
                        ? "Playback timing is updating; elapsed position is unavailable. Seeking is unavailable."
                        : $"Elapsed {FormatTime(state.Position)} of {FormatTime(state.Duration)}. Seeking is temporarily unavailable.");
        }
        if (_pendingSeek.HasValue
            && (Math.Abs(state.Position - _pendingSeek.Value) <= 2
                || DateTime.UtcNow >= _seekPendingUntil))
            ClearPendingSeek();
        if (!_seek.Dragging)
        {
            var position = _pendingSeek ?? state.Position;
            _seek.SetPositionSeconds(clockMismatch ? 0 : position,
                clockMismatch ? 0 : state.Duration);
            SetTextIfChanged(_elapsed, clockMismatch
                ? mediaClock ? "~" + FormatElapsed(displayPosition) : "--:--"
                : FormatElapsed(position));
        }
        SetTextIfChanged(_duration, FormatTime(state.ClockMismatch
            ? mediaClock ? state.Duration : null : state.Duration <= 0 ? null : state.Duration));
        SetAccessible(_seek, canSeek ? "Playback position" : "Playback position unavailable",
            clockMismatch
                ? "Playback timing is updating; seeking is unavailable until the website seek slider and playback clock agree."
                : canSeek
                    ? $"Playback position {FormatTime(state.Position)} of {FormatTime(state.Duration)}. Use Left and Right for five-second steps, Page Up and Page Down for thirty-second steps, Home for the beginning and End for the end."
                    : "Seeking unavailable; track duration or public seek control is unknown.");

        // Transport never depends on metadata freshness or another command being in flight;
        // the host sends one website command at a time and ignores extra clicks meanwhile.
        SetEnabled(_previous, true, "Previous item", "Previous item.");
        SetEnabled(_playPause, true, state.Paused ? "Play" : "Pause",
            state.Paused ? "Play website playback." : "Pause website playback.");
        SetEnabled(_next, true, "Next item", "Next item.");

        var ratingReady = _ratingGate.Allows(Environment.TickCount64);
        var liked = state.CanLike ? state.Liked : null;
        var likeEnabled = ratingReady && state.CanLike && liked.HasValue;
        if (_like.IsEnabled != likeEnabled) _like.IsEnabled = likeEnabled;
        if (_like.IsChecked != liked) _like.IsChecked = liked;
        SetRatingAccessibility(_like, "Like", liked, state.CanLike);
        var disliked = state.CanDislike ? state.Disliked : null;
        var dislikeEnabled = ratingReady && state.CanDislike && disliked.HasValue;
        if (_dislike.IsEnabled != dislikeEnabled) _dislike.IsEnabled = dislikeEnabled;
        if (_dislike.IsChecked != disliked) _dislike.IsChecked = disliked;
        SetRatingAccessibility(_dislike, "Dislike", disliked, state.CanDislike);

        // Output volume is synchronized separately through SetOutputVolume.

        var repeat = state.Repeat is null ? null : FormatRepeat(state.Repeat);
        if (_repeat.IsEnabled != (state.CanRepeat && repeat is not null))
            _repeat.IsEnabled = state.CanRepeat && repeat is not null;
        SetRepeatAccessibility(repeat, state.CanRepeat);
        if (_shuffle.IsEnabled != state.CanShuffle)
            _shuffle.IsEnabled = state.CanShuffle;
        SetShuffleAccessibility(state.Shuffle, state.CanShuffle);
    }
    private void UpdateVolumeAvailability()
    {
        var sliderStep = Math.Round(_outputVolume * _volumeSlider.Maximum, MidpointRounding.AwayFromZero);
        if (_volume.IsEnabled != _outputAvailable) _volume.IsEnabled = _outputAvailable;
        if (_volumeSlider.IsEnabled != _outputAvailable) _volumeSlider.IsEnabled = _outputAvailable;
        var name = _outputMuted ? "Unmute app output" : "Mute app output";
        var help = !_outputAvailable
            ? CompactVolumeUnavailableHelp
            : $"Activate to {(_outputMuted ? "unmute" : "mute")} app output. Hover to adjust app output; press Down or open the context menu for touch and keyboard access to the slider. App output {sliderStep / 10:0.0} percent; {(_outputMuted ? "muted" : "unmuted")}."
                + (_outputSessionActive ? "" : " Preference pending until an owned WebView audio session starts.");
        SetAccessible(_volume, name, help);
        SetAccessible(_volumeSlider, "App output volume", !_outputAvailable
            ? CompactVolumeUnavailableHelp
            : "App output volume from zero to one hundred percent. Use Left and Right or Up and Down for 0.1 percent steps, Page Up and Page Down for 1 percent, Home for 0 percent and End for 100 percent."
                + (_outputSessionActive ? "" : " Preference pending until an owned WebView audio session starts."));
    }


    private void ShowVolumePopup()
    {
        if (_disposed || !_volume.IsEnabled || !_volumeSlider.IsEnabled || !_active || Visibility != Visibility.Visible) return;
        var volume = _pendingOutputVolume ?? _outputVolume;
        _updatingControls = true;
        try
        {
            _volumeSlider.Value = Math.Round(
                Math.Clamp(double.IsFinite(volume) ? volume : 0, 0, 1) * _volumeSlider.Maximum,
                MidpointRounding.AwayFromZero);
            _volumeValue.Text = FormatVolumePercent(_volumeSlider.Value);
        }
        finally
        {
            _updatingControls = false;
        }
        // When the layout has moved Volume into More, the popup opens from More instead.
        var anchor = _volume.Visibility == Visibility.Visible ? (FrameworkElement)_volume : _more;
        if (!_volumeOpeningFromHover)
            _popupInvoker = anchor;
        _volumePinnedOpen = !_volumeOpeningFromHover;
        _volumeFocusSliderOnOpen = !_volumeOpeningFromHover;
        _restoreVolumeFocusOnClose = !_volumeOpeningFromHover;
        _volumePopup.ShowMode = _volumeOpeningFromHover
            ? FlyoutShowMode.Transient : FlyoutShowMode.Standard;
        _volumePopup.ShowAt(anchor);
    }

    private void ShowVolumePopupFromHover()
    {
        if (_disposed || !_volume.IsEnabled || !_volumeSlider.IsEnabled || !_active || Visibility != Visibility.Visible
            || _volumePopup.IsOpen)
            return;
        _volumeOpeningFromHover = true;
        try { ShowVolumePopup(); }
        finally { _volumeOpeningFromHover = false; }
    }

    private void OpenVolumePopupForInteraction()
    {
        _volumeHoverCloseTimer.Stop();
        if (_disposed || !_volume.IsEnabled || !_volumeSlider.IsEnabled || !_active) return;
        if (!_volumePopup.IsOpen)
        {
            ShowVolumePopup();
            return;
        }
        PinVolumePopupFromInteraction();
        if (_volumeSlider.IsEnabled && _volumeSlider.FocusState == FocusState.Unfocused)
            _volumeSlider.Focus(FocusState.Programmatic);
    }

    private void PinVolumePopupFromPointer(object sender, PointerRoutedEventArgs e)
        => PinVolumePopupFromInteraction();

    private void PinVolumePopupFromInteraction()
    {
        if (_disposed || !_volumePopup.IsOpen) return;
        _volumeHoverCloseTimer.Stop();
        _volumePinnedOpen = true;
        _restoreVolumeFocusOnClose = true;
        _popupInvoker = _volume;
    }

    private void VolumePointerEntered(object sender, PointerRoutedEventArgs e)
    {
        if (!IsHoverPointer(e, _volume)) return;
        _volumeButtonPointerOver = true;
        _volumeHoverCloseTimer.Stop();
        if (!_volumePopup.IsOpen) ShowVolumePopupFromHover();
    }

    private void VolumePointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (!IsHoverPointer(e, _volume)) return;
        _volumeButtonPointerOver = false;
        ScheduleHoverVolumePopupClose();
    }

    private void VolumePopupPointerEntered(object sender, PointerRoutedEventArgs e)
    {
        if (!IsHoverPointer(e, _volumePopupSurface)) return;
        _volumePopupPointerOver = true;
        _volumeHoverCloseTimer.Stop();
    }

    private void VolumePopupPointerExited(object sender, PointerRoutedEventArgs e)
    {
        if (!IsHoverPointer(e, _volumePopupSurface)) return;
        _volumePopupPointerOver = false;
        ScheduleHoverVolumePopupClose();
    }

    private static bool IsHoverPointer(PointerRoutedEventArgs e, UIElement element)
        => e.GetCurrentPoint(element).PointerDeviceType is PointerDeviceType.Mouse or PointerDeviceType.Pen;

    private void ScheduleHoverVolumePopupClose()
    {
        if (_disposed || !_volumePopup.IsOpen || _volumePinnedOpen) return;
        _volumeHoverCloseTimer.Stop();
        _volumeHoverCloseTimer.Start();
    }

    private void CloseHoverVolumePopup()
    {
        _volumeHoverCloseTimer.Stop();
        if (!_disposed && _active && !_volumePinnedOpen
            && !_volumeButtonPointerOver && !_volumePopupPointerOver
            && _volumePopup.IsOpen)
            _volumePopup.Hide();
    }

    private void VolumePopupClosed(object? sender, object e)
    {
        _volumeHoverCloseTimer.Stop();
        _volumeButtonPointerOver = false;
        _volumePopupPointerOver = false;
        _volumePinnedOpen = false;
        _volumeFocusSliderOnOpen = false;
        var restoreFocus = _restoreVolumeFocusOnClose;
        _restoreVolumeFocusOnClose = false;
        if (restoreFocus)
            RestorePopupFocus();
        else if (ReferenceEquals(_popupInvoker, _volume))
            _popupInvoker = null;
    }
    private static string FormatVolumePercent(double sliderValue) => $"{sliderValue / 10:0.0}%";


    private void RestorePopupFocus()
    {
        if (_disposed) return;
        var invoker = _popupInvoker;
        _popupInvoker = null;
        if (_active && Visibility == Visibility.Visible)
            (invoker ?? _more).Focus(FocusState.Programmatic);
    }

    private void UpdateInlineStatus()
    {
        if (_disposed) return;
        var fallback = _state is null
            ? "Player unavailable — no current playback state is confirmed. More → Application status for details."
            : string.Empty;
        var error = _statusIsError && _statusMessage.Length != 0;
        var notice = !error && _notice.Length != 0;
        var text = error ? _statusMessage : notice ? _notice : fallback;
        SetTextIfChanged(_inlineStatus, text);
        var visibility = text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (_inlineStatus.Visibility != visibility) _inlineStatus.Visibility = visibility;
        _inlineStatus.Foreground = notice
            ? ShellTheme.Brush("PrimaryTextBrush", Colors.White)
            : ShellTheme.Brush("SecondaryTextBrush", ColorHelper.FromArgb(0xFF, 0xAA, 0xAA, 0xAA));
        SetAccessible(_inlineStatus, notice ? "Notice" : "Application status", notice
            ? _notice
            : BuildStatusMenuDescription(_statusMessage, _state is not null));
        UpdateStatusMenuItem();
    }

    private void UpdateTimerVisual()
    {
        if (_timerRemaining is { } active)
        {
            var formatted = FormatTimer(active);
            SetTextIfChanged(_timerText, $"Pause in {formatted}");
            SetAccessible(_timer, "Cancel pause timer", $"Cancel pause timer; {formatted} remaining.");
        }
        else
        {
            SetTextIfChanged(_timerText, "Pause timer");
            SetAccessible(_timer, "Set pause timer", "Set a pause timer; the app stays open.");
        }
    }

    private void BindButtonTheme()
    {
        var transparent = new SolidColorBrush(Colors.Transparent);
        var primary = ShellTheme.Brush("PrimaryTextBrush", Colors.White);
        var secondary = ShellTheme.Brush("SecondaryTextBrush", ColorHelper.FromArgb(0xFF, 0xAA, 0xAA, 0xAA));
        foreach (var button in new ButtonBase[]
        {
            _previous, _next, _like, _dislike, _playlists, _repeat, _shuffle, _volume, _timer,
            _returnToFull, _more, _minimize, _close
        })
        {
            button.Background = transparent;
            button.Foreground = primary;
            button.BorderBrush = transparent;
            button.BorderThickness = new Thickness(0);
            button.Padding = new Thickness(0);
            button.HorizontalContentAlignment = HorizontalAlignment.Center;
            button.VerticalContentAlignment = VerticalAlignment.Center;
        }
        _timer.Foreground = secondary;
        _playPause.BorderThickness = new Thickness(0);
        _playPause.Padding = new Thickness(0);
        _playPause.HorizontalContentAlignment = HorizontalAlignment.Center;
        _playPause.VerticalContentAlignment = VerticalAlignment.Center;
        ApplyPlayVisual();
    }
    private void ApplySecondaryVisuals()
    {
        if (_disposed) return;
        var primary = ShellTheme.Brush("PrimaryTextBrush", Colors.White);
        var secondary = ShellTheme.Brush("SecondaryTextBrush", ColorHelper.FromArgb(0xFF, 0xAA, 0xAA, 0xAA));
        foreach (var button in new ButtonBase[]
        {
            _previous, _next, _like, _dislike, _playlists, _repeat, _shuffle, _volume, _timer,
            _returnToFull, _more, _minimize, _close
        })
            button.Foreground = button.IsEnabled ? primary : secondary;
        _timer.Foreground = _timer.IsEnabled ? secondary : primary;
        ApplyPlayVisual();
    }

    private void ApplyPlayVisual()
    {
        if (_disposed) return;
        var enabled = _playPause.IsEnabled;
        var highContrast = ShellTheme.IsHighContrast;
        if (_playVisualInitialized
            && _lastPlayVisualEnabled == enabled
            && _lastPlayPointerOver == _playPointerOver
            && _lastPlayPressed == _playPressed
            && _lastPlayHighContrast == highContrast)
            return;

        _playVisualInitialized = true;
        _lastPlayVisualEnabled = enabled;
        _lastPlayPointerOver = _playPointerOver;
        _lastPlayPressed = _playPressed;
        _lastPlayHighContrast = highContrast;
        if (!enabled)
        {
            _playPause.ClearValue(Control.BackgroundProperty);
            _playPause.Foreground = ShellTheme.Brush("SecondaryTextBrush", ColorHelper.FromArgb(0xFF, 0xAA, 0xAA, 0xAA));
            return;
        }

        var background = highContrast
            ? ShellTheme.Brush("PrimaryTextBrush", Colors.White)
            : new SolidColorBrush(ColorHelper.FromArgb(0xFF,
                _playPressed ? (byte)0xCC : _playPointerOver ? (byte)0xF1 : (byte)0xFF,
                _playPressed ? (byte)0xCC : _playPointerOver ? (byte)0xF1 : (byte)0xFF,
                _playPressed ? (byte)0xCC : _playPointerOver ? (byte)0xF1 : (byte)0xFF));
        _playPause.Background = background;
        _playPause.Foreground = ShellTheme.Brush("CanvasBrush", Colors.Black);
    }

    private void RefreshBoundIcons()
    {
        if (_disposed) return;
        try
        {
            BindFixedIcon(_previous, ref _previousIconElement, "previous", 20);
            BindStatefulIcon(_playPause, ref _playPauseIconElement, ref _playPauseIconName,
                _state is null ? "play-pause" : _state.Paused ? "play" : "pause", 24);
            BindFixedIcon(_next, ref _nextIconElement, "next", 20);
            // A liked or disliked song shows the solid thumb; the button itself keeps its plain look.
            BindStatefulIcon(_like, ref _likeIconElement, ref _likeIconName,
                _like.IsChecked == true ? "like-filled" : "like", 20);
            BindStatefulIcon(_dislike, ref _dislikeIconElement, ref _dislikeIconName,
                _dislike.IsChecked == true ? "dislike-filled" : "dislike", 20);
            var volumeIcon = _outputMuted || _outputVolume <= 0 ? "volume-muted" : "volume";
            BindStatefulIcon(_volume, ref _volumeIconElement, ref _volumeIconName, volumeIcon, 20);
            BindStatefulIcon(_repeatIcon, ref _repeatIconElement, ref _repeatIconName,
                IsRepeatOne(_state?.Repeat) ? "repeat-one" : "repeat", 20);
            BindFixedIcon(_shuffleIcon, ref _shuffleIconElement, "shuffle", 20);
            BindFixedIcon(_returnToFull, ref _returnToFullIconElement, "restore-window", 16);
            BindFixedIcon(_more, ref _moreIconElement, "overflow", 16);
            BindFixedIcon(_playlists, ref _playlistsIconElement, "playlist", 20);
            BindFixedIcon(_minimize, ref _minimizeIconElement, "minimize", 16);
            BindFixedIcon(_close, ref _closeIconElement, "close", 16);
            BindStatefulIcon(_timerIcon, ref _timerIconElement, ref _timerIconName,
                _timerRemaining.HasValue ? "cancel-timer" : "quit-timer", 16);
            BindMenuIcon(_settingsItem, ref _settingsMenuIconElement, "settings");
            BindMenuIcon(_statusItem, ref _statusMenuIconElement, "status");
            BindMenuIcon(_topmostItem, ref _topmostMenuIconElement, "pin");
            ApplyPlayVisual();
        }
        catch (Exception)
        {
            SetStatus("Native compact icons could not be loaded.", isError: true);
        }
    }

    private void BindFixedIcon(ContentControl target, ref IconElement? current, string name, double logicalSize)
    {
        if (current is not null && ReferenceEquals(target.Content, current)) return;
        current = _iconCache.CreateElement(name, logicalSize);
        target.Content = current;
    }

    private void BindStatefulIcon(
        ContentControl target,
        ref IconElement? current,
        ref string? currentName,
        string name,
        double logicalSize)
    {
        if (current is not null
            && string.Equals(currentName, name, StringComparison.Ordinal)
            && ReferenceEquals(target.Content, current))
            return;
        current = _iconCache.CreateElement(name, logicalSize);
        currentName = name;
        target.Content = current;
    }

    private void BindMenuIcon(MenuFlyoutItem target, ref IconElement? current, string name)
    {
        if (current is not null && ReferenceEquals(target.Icon, current)) return;
        current = _iconCache.CreateElement(name, 16);
        target.Icon = current;
    }

    private static bool IsRepeatOne(string? repeat)
        => string.Equals(repeat, "one", StringComparison.OrdinalIgnoreCase)
            || string.Equals(repeat, "repeatone", StringComparison.OrdinalIgnoreCase);

    private void RefreshShortcutDescriptions()
    {
        const string unavailable = "Playback controls unavailable. Return to the full app";
        SetButtonShortcut(_playPause, _state is null
            ? unavailable : _state.Paused ? "Play website playback" : "Pause website playback", _shortcutBindings.Toggle);
        SetButtonShortcut(_previous, _state is null ? unavailable : "Previous item", _shortcutBindings.Previous);
        SetButtonShortcut(_next, _state is null ? unavailable : "Next item", _shortcutBindings.Next);
        SetButtonShortcut(_returnToFull, "Return to the full app", _shortcutBindings.Compact);
    }

    private static void SetButtonShortcut(ButtonBase button, string action, int binding)
    {
        var suffix = binding == 0 ? " No shortcut assigned." : $" Shortcut: {ShortcutBindings.Format(binding)} when session shortcuts are enabled.";
        SetAccessible(button, AutomationProperties.GetName(button) ?? string.Empty, action + "." + suffix);
    }

    private void BeginSeekDrag()
    {
        if (!_seek.IsEnabled || _state is null) return;
        _dragging = true;
        _dragStartAngle = _artwork.Angle;
    }

    private void PreviewSeekDrag(double position)
    {
        if (!_dragging || _state is null) return;
        _elapsed.Text = FormatElapsed(position);
        _artwork.Angle = SeekPreviewAngle(_dragStartAngle, _seek.HorizontalDelta, _reduceMotion);
    }

    private void CommitSeekDrag(double position)
    {
        var wasDragging = _dragging;
        _dragging = false;
        if (_state is null || !_seek.IsEnabled) return;
        var target = ClampSeekTarget(position, _state.Duration);
        _elapsed.Text = FormatElapsed(target);
        if (ShouldCommitSeek(wasDragging, false))
        {
            _pendingSeek = target;
            _seekPendingUntil = DateTime.UtcNow.AddSeconds(2);
            _seekPendingState = _state;
            RaiseCommand("seek", target);
        }
        UpdateAnimationTimer();
    }

    private void CommitKeyboardSeek(double position)
    {
        if (_state is null || !_seek.IsEnabled) return;
        var target = ClampSeekTarget(position, _state.Duration);
        _elapsed.Text = FormatElapsed(target);
        _pendingSeek = target;
        _seekPendingUntil = DateTime.UtcNow.AddSeconds(2);
        _seekPendingState = _state;
        if (ShouldCommitSeek(true, false)) RaiseCommand("seek", target);
        UpdateAnimationTimer();
    }

    private void CancelSeekDrag()
    {
        if (!_dragging) return;
        _dragging = false;
        _artwork.Angle = _dragStartAngle;
        if (_state is { } state)
        {
            _elapsed.Text = FormatElapsed(state.Position);
            _seek.SetPositionSeconds(state.Position, state.Duration);
        }
        UpdateAnimationTimer();
    }
    private void VolumeSliderChanged(object? sender, RangeBaseValueChangedEventArgs e)
    {
        _volumeValue.Text = FormatVolumePercent(_volumeSlider.Value);
        var help = !_outputAvailable
            ? CompactVolumeUnavailableHelp
            : $"App output volume {_volumeSlider.Value / 10:0.0} percent. Use Left and Right or Up and Down for 0.1 percent steps, Page Up and Page Down for 1 percent, Home for 0 percent and End for 100 percent."
                + (_outputSessionActive ? "" : " Preference pending until an owned WebView audio session starts.");
        SetAccessible(_volumeSlider, "App output volume", help);
        if (_updatingControls || !_active || !_volumePopup.IsOpen || !_volumeSlider.IsEnabled) return;
        _pendingOutputVolume = Math.Clamp(e.NewValue / Math.Max(1, _volumeSlider.Maximum), 0, 1);
        _outputPendingUntil = DateTime.UtcNow.AddSeconds(2);
        _volumeCommitTimer.Stop();
        _volumeCommitTimer.Start();
    }

    private void VolumeSliderCommitted(double normalized)
    {
        _volumeCommitTimer.Stop();
        if (!_updatingControls && _volumePopup.IsOpen && _volumeSlider.IsEnabled)
        {
            _pendingOutputVolume = Math.Clamp(normalized, 0, 1);
            _outputPendingUntil = DateTime.UtcNow.AddSeconds(2);
            RaiseCommand("output-volume", _pendingOutputVolume.Value);
        }
    }



    private void AnimationTick()
    {
        if (_disposed || !_active || Visibility != Visibility.Visible || _reduceMotion || _state is null)
        {
            _animationTimer.Stop();
            return;
        }
        var now = DateTime.UtcNow;
        var elapsed = _lastAnimation == default ? TimeSpan.Zero : now - _lastAnimation;
        _lastAnimation = now;
        if (elapsed < TimeSpan.Zero || elapsed > TimeSpan.FromMilliseconds(200))
            elapsed = TimeSpan.FromMilliseconds(33);
        if (!_state.Paused && !_seek.Dragging)
            _artwork.Angle = NormalizeAngle(_artwork.Angle + elapsed.TotalSeconds * DegreesPerSecond);
        _title.Advance(elapsed);
        UpdateAnimationTimer();
    }

    private void UpdateAnimationTimer()
    {
        if (_disposed) return;
        var needed = _state is not null && ShouldAnimate(_active, Visibility == Visibility.Visible,
            _reduceMotion, _state.Paused, _title.NeedsAnimation);
        if (!needed)
        {
            _animationTimer.Stop();
            return;
        }
        if (!_animationTimer.IsRunning) _lastAnimation = DateTime.UtcNow;
        _animationTimer.Start();
    }



    private void RaiseCommand(string command, double? value = null)
    {
        if (!_disposed) CommandRequested?.Invoke(command, value);
    }

    private static string DisplayTitle(CompactPlaybackState? state)
        => state is null
            ? "Player unavailable"
            : string.IsNullOrWhiteSpace(state.Title) ? "Unknown title" : state.Title;

    private static void SetTextIfChanged(TextBlock element, string value)
    {
        if (!string.Equals(element.Text, value, StringComparison.Ordinal))
            element.Text = value;
    }

    private static void SetToolTipIfChanged(DependencyObject element, string? value)
    {
        var current = ToolTipService.GetToolTip(element);
        if (value is null ? current is null : current is string text
                && string.Equals(text, value, StringComparison.Ordinal))
            return;
        ToolTipService.SetToolTip(element, value);
    }

    private static void SetEnabled(Control control, bool enabled, string name, string description)
    {
        if (control.IsEnabled != enabled) control.IsEnabled = enabled;
        SetAccessible(control, name, description);
    }

    private static void SetAccessible(DependencyObject element, string name, string description)
    {
        if (!string.Equals(AutomationProperties.GetName(element), name, StringComparison.Ordinal))
            AutomationProperties.SetName(element, name);
        if (!string.Equals(AutomationProperties.GetHelpText(element), description, StringComparison.Ordinal))
            AutomationProperties.SetHelpText(element, description);
    }

    private static void ConfigureButton(ButtonBase button, string name, string description)
    {
        SetAccessible(button, name, description);
        button.IsTabStop = true;
    }

    private static void SetRatingAccessibility(ToggleButton button, string action, bool? confirmed, bool available)
    {
        var lower = action.ToLowerInvariant();
        if (!available || !confirmed.HasValue)
        {
            SetAccessible(button, $"{action} unavailable", $"{action} state is unavailable until playback controls recover.");
            return;
        }
        var verb = confirmed.Value ? $"Remove {lower}" : action == "Dislike" ? "Dislike and skip" : action;
        SetAccessible(button, verb, confirmed.Value
            ? $"Confirmed {lower} state. Activate to remove {lower}."
            : action == "Dislike"
                ? "Dislike the current song. YouTube Music then skips to the next song."
                : $"Not {lower}d. Activate to {lower} the current track.");
    }

    private void SetRepeatAccessibility(string? repeat, bool available)
    {
        if (!available || repeat is null)
        {
            SetTextIfChanged(_repeatMarker, string.Empty);
            if (_repeatMarker.Visibility != Visibility.Collapsed)
                _repeatMarker.Visibility = Visibility.Collapsed;
            _repeatMarkerThemeInitialized = false;
            SetAccessible(_repeat, "Repeat unavailable", "Repeat state is unavailable until playback controls recover.");
            return;
        }
        var next = repeat switch { "Off" => "all", "All" => "one", _ => "off" };
        var marker = repeat switch { "All" => "A", "One" => "1", _ => string.Empty };
        SetTextIfChanged(_repeatMarker, marker);
        var visibility = marker.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (_repeatMarker.Visibility != visibility) _repeatMarker.Visibility = visibility;
        if (!_repeatMarkerThemeInitialized)
        {
            _repeatMarker.Foreground = ShellTheme.Brush("FocusStrokeBrush", Colors.White);
            _repeatMarkerThemeInitialized = true;
        }
        SetAccessible(_repeat, $"Repeat {repeat.ToLowerInvariant()}", $"Repeat is {repeat}. Activate to set repeat {next}.");
    }

    private void SetShuffleAccessibility(bool? shuffle, bool available)
    {
        var visibility = available && shuffle == true ? Visibility.Visible : Visibility.Collapsed;
        if (_shuffleMarker.Visibility != visibility) _shuffleMarker.Visibility = visibility;
        if (!available)
            SetAccessible(_shuffle, "Shuffle unavailable", "Shuffle is unavailable until playback controls recover.");
        else if (shuffle is null)
            SetAccessible(_shuffle, "Shuffle state unconfirmed", "Toggle shuffle; the website has not exposed its current state.");
        else
            SetAccessible(_shuffle, shuffle.Value ? "Shuffle on" : "Shuffle off",
                shuffle.Value ? "Shuffle is on. Activate to turn it off." : "Shuffle is off. Activate to turn it on.");
    }

    private static void RestoreRatingState(ToggleButton button, bool? state)
    {
        button.IsChecked = state;
    }

    private static string FormatRepeat(string repeat) => repeat.Trim().ToLowerInvariant() switch
    {
        "all" or "repeatall" => "All",
        "one" or "repeatone" => "One",
        _ => "Off"
    };

    private static string FormatTime(double? seconds)
    {
        if (seconds is not { } value || !double.IsFinite(value) || value < 0) return "--:--";
        var total = (long)Math.Clamp(Math.Round(value, MidpointRounding.AwayFromZero), 0, 99 * 3600 + 59 * 60 + 59);
        var hours = total / 3600;
        var minutes = total / 60 % 60;
        var remaining = total % 60;
        return hours > 0 ? $"{hours}:{minutes:00}:{remaining:00}" : $"{minutes}:{remaining:00}";
    }

    private static string FormatElapsed(double position)
        => FormatTime(position);

    private static string FormatTimer(TimeSpan value)
    {
        var seconds = Math.Max(0, (long)Math.Round(value.TotalSeconds, MidpointRounding.AwayFromZero));
        var hours = seconds / 3600;
        var minutes = seconds / 60 % 60;
        var remaining = seconds % 60;
        return hours > 0 ? $"{hours}:{minutes:00}:{remaining:00}" : $"{minutes}:{remaining:00}";
    }

    private static double NormalizeAngle(double value)
    {
        if (!double.IsFinite(value)) return 0;
        value %= 360;
        return value < 0 ? value + 360 : value;
    }

}
public sealed class CompactArtworkCanvas : Grid
{
    private readonly Image _image;
    private readonly TextBlock _placeholder;
    private readonly RotateTransform _rotation = new();
    private double _angle;

    public CompactArtworkCanvas()
    {
        HorizontalAlignment = HorizontalAlignment.Stretch;
        VerticalAlignment = VerticalAlignment.Stretch;
        RenderTransform = _rotation;
        Children.Add(new Border
        {
            Background = ShellTheme.Brush("RaisedBrush", ColorHelper.FromArgb(0xFF, 0x21, 0x21, 0x21)),
            CornerRadius = new CornerRadius(64),
            Child = _image = new Image { Stretch = Stretch.UniformToFill, Visibility = Visibility.Collapsed }
        });
        Children.Add(_placeholder = new TextBlock
        {
            Text = "♪",
            FontSize = 44,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextAlignment = TextAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            Foreground = ShellTheme.Brush("SecondaryTextBrush", ColorHelper.FromArgb(0xFF, 0xAA, 0xAA, 0xAA))
        });
        SizeChanged += (_, _) => UpdateClip();
        UpdateClip();
    }

    internal double Angle
    {
        get => _angle;
        set
        {
            _angle = Normalize(value);
            _rotation.Angle = _angle;
            _rotation.CenterX = ActualWidth / 2;
            _rotation.CenterY = ActualHeight / 2;
        }
    }

    internal void SetImage(BitmapImage? image)
    {
        var imageVisible = image is not null;
        if (ReferenceEquals(_image.Source, image)
            && _image.Visibility == (imageVisible ? Visibility.Visible : Visibility.Collapsed)
            && _placeholder.Visibility == (imageVisible ? Visibility.Collapsed : Visibility.Visible))
            return;
        _image.Source = image;
        _image.Visibility = imageVisible ? Visibility.Visible : Visibility.Collapsed;
        _placeholder.Visibility = imageVisible ? Visibility.Collapsed : Visibility.Visible;
    }

    internal void ApplyTheme()
    {
        if (Children[0] is Border border)
            border.Background = ShellTheme.Brush("RaisedBrush", ColorHelper.FromArgb(0xFF, 0x21, 0x21, 0x21));
        _placeholder.Foreground = ShellTheme.Brush("SecondaryTextBrush", ColorHelper.FromArgb(0xFF, 0xAA, 0xAA, 0xAA));
    }

    private void UpdateClip()
    {
        var diameter = Math.Max(0, Math.Min(ActualWidth, ActualHeight));
        if (Children[0] is Border border)
            border.CornerRadius = new CornerRadius(diameter / 2);
        Angle = _angle;
    }

    private static double Normalize(double value)
    {
        if (!double.IsFinite(value)) return 0;
        value %= 360;
        return value < 0 ? value + 360 : value;
    }

}
public sealed class CompactMarqueeText : UserControl
{
    private const double GapDip = 48;
    private static readonly TimeSpan TitlePause = TimeSpan.FromMilliseconds(900);
    private readonly Canvas _content = new();
    private readonly TextBlock _primary;
    private readonly TextBlock _secondary;
    private readonly TranslateTransform _primaryTransform = new();
    private readonly TranslateTransform _secondaryTransform = new();
    private TimeSpan _pause = TitlePause;
    private double _offset;
    private double _textWidth;
    private bool _overflow;
    private bool _reduceMotion;

    public CompactMarqueeText()
    {
        IsTabStop = true;
        Clip = new RectangleGeometry();
        _primary = CreateTextBlock(_primaryTransform);
        _secondary = CreateTextBlock(_secondaryTransform);
        _content.Children.Add(_primary);
        _content.Children.Add(_secondary);
        Content = _content;
        SizeChanged += (_, _) => RecalculateOverflow();
    }

    internal bool ReduceMotion
    {
        get => _reduceMotion;
        set
        {
            if (_reduceMotion == value) return;
            _reduceMotion = value;
            _offset = 0;
            _pause = TitlePause;
            UpdateVisuals();
        }
    }

    internal bool NeedsAnimation => _overflow && !_reduceMotion;

    internal void SetText(string text)
    {
        text ??= string.Empty;
        if (string.Equals(_primary.Text, text, StringComparison.Ordinal)) return;
        _primary.Text = text;
        _secondary.Text = text;
        _offset = 0;
        _pause = TitlePause;
        RecalculateOverflow();
    }

    internal void RecalculateOverflow()
    {
        // Measure the text at its natural width (an explicit scrolling width would mask it).
        _primary.Width = double.NaN;
        _primary.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
        _textWidth = _primary.DesiredSize.Width;
        var wasOverflow = _overflow;
        _overflow = _textWidth > Math.Max(0, ActualWidth - 2);
        if (!_overflow) _offset = 0;
        else if (!wasOverflow)
        {
            _offset = 0;
            _pause = TitlePause;
        }
        UpdateVisuals();
    }

    internal void Advance(TimeSpan elapsed)
    {
        if (!NeedsAnimation || elapsed <= TimeSpan.Zero) return;
        if (_pause > TimeSpan.Zero)
        {
            _pause -= elapsed;
            if (_pause > TimeSpan.Zero) return;
            elapsed = -_pause;
            _pause = TimeSpan.Zero;
        }
        _offset += elapsed.TotalSeconds * 34;
        var period = _textWidth + GapDip;
        if (period > 0) _offset %= period;
        UpdateVisuals();
    }

    internal void ApplyTheme()
    {
        var brush = ShellTheme.Brush("PrimaryTextBrush", Colors.White);
        _primary.Foreground = brush;
        _secondary.Foreground = brush;
    }

    private void UpdateVisuals()
    {
        if (Clip is RectangleGeometry rectangle)
            rectangle.Rect = new Rect(0, 0, ActualWidth, ActualHeight);
        // Canvas children are never constrained or clipped by the slot: the copies are laid out at
        // their natural width from the left edge and this control's clip trims them.
        var top = Math.Max(0, (ActualHeight - _primary.DesiredSize.Height) / 2);
        Canvas.SetTop(_primary, top);
        Canvas.SetTop(_secondary, top);
        if (!_overflow || _reduceMotion)
        {
            _primary.TextTrimming = TextTrimming.CharacterEllipsis;
            _primary.Width = Math.Max(0, ActualWidth);
            _primaryTransform.X = 0;
            _secondary.Visibility = Visibility.Collapsed;
        }
        else
        {
            _primary.TextTrimming = TextTrimming.None;
            _primary.Width = double.NaN;
            _secondary.Visibility = Visibility.Visible;
            _primaryTransform.X = -_offset;
            _secondaryTransform.X = -_offset + _textWidth + GapDip;
        }
    }

    private static TextBlock CreateTextBlock(TranslateTransform transform)
        => new()
        {
            FontSize = 16,
            FontWeight = Microsoft.UI.Text.FontWeights.SemiBold,
            TextWrapping = TextWrapping.NoWrap,
            RenderTransform = transform
        };
}

public sealed class CompactSeekSlider : Slider
{
    private bool _dragging;
    private bool _releaseExpected;
    private int _captureLossGeneration;
    private Pointer? _pointer;
    private double _originalValue;
    private double _durationSeconds;
    private double _dragStartX;

    internal event Action? DragStarted;
    internal event Action<double>? DragPreview;
    internal event Action<double>? DragCommitted;
    internal event Action<double>? KeyboardCommitted;
    internal event Action? DragCancelled;

    internal bool Dragging => _dragging;
    internal double HorizontalDelta { get; private set; }
    internal double DurationSeconds
    {
        get => _durationSeconds;
        set => _durationSeconds = value;
    }

    public CompactSeekSlider()
    {
        // Slider handles these routed events internally, so observe handled events to retain
        // the native single-release command boundary.
        AddHandler(PointerPressedEvent, new PointerEventHandler(OnPointerPressedInternal), true);
        AddHandler(PointerMovedEvent, new PointerEventHandler(OnPointerMovedInternal), true);
        AddHandler(PointerReleasedEvent, new PointerEventHandler(OnPointerReleasedInternal), true);
        PointerCanceled += (_, _) => CancelDrag();
        PointerCaptureLost += OnPointerCaptureLost;
    }

    private void OnPointerCaptureLost(object sender, PointerRoutedEventArgs e)
    {
        if (_pointer is null || e.Pointer.PointerId != _pointer.PointerId) return;
        DeferCaptureLossCancellation();
    }

    internal void DeferCaptureLossCancellation()
    {
        if (!_dragging || _releaseExpected) return;
        _releaseExpected = true;
        var generation = ++_captureLossGeneration;
        var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread();
        if (dispatcher?.TryEnqueue(() =>
            {
                if (generation == _captureLossGeneration && _dragging && _releaseExpected)
                    CancelDrag();
            }) != true)
            CancelDrag();
    }

    internal void SetPositionSeconds(double position, double duration)
    {
        var target = CompactPlayerView.ClampSeekTarget(position, duration);
        var next = duration > 0 ? Math.Clamp(target / duration * 1000, Minimum, Maximum) : 0;
        if (double.Equals(_durationSeconds, duration) && double.Equals(Value, next))
            return;
        _durationSeconds = duration;
        if (!double.Equals(Value, next)) Value = next;
    }

    internal void CancelDrag()
    {
        if (!_dragging) return;
        _dragging = false;
        _releaseExpected = false;
        _captureLossGeneration++;
        _pointer = null;
        Value = _originalValue;
        HorizontalDelta = 0;
        DragCancelled?.Invoke();
    }

    protected override void OnKeyDown(KeyRoutedEventArgs e)
    {
        if (!IsEnabled)
        {
            base.OnKeyDown(e);
            return;
        }
        var delta = e.Key switch
        {
            VirtualKey.Left or VirtualKey.Down => -5,
            VirtualKey.Right or VirtualKey.Up => 5,
            VirtualKey.PageDown => -30,
            VirtualKey.PageUp => 30,
            VirtualKey.Home => int.MinValue,
            VirtualKey.End => int.MaxValue,
            VirtualKey.Escape => int.MinValue + 1,
            _ => 0
        };
        if (delta == int.MinValue + 1)
        {
            CancelDrag();
            e.Handled = true;
            return;
        }
        if (delta == 0)
        {
            base.OnKeyDown(e);
            return;
        }
        var current = _durationSeconds > 0 ? Value / 1000 * _durationSeconds : 0;
        var target = delta == int.MinValue ? 0 : delta == int.MaxValue
            ? _durationSeconds : CompactPlayerView.KeyboardSeekTarget(current, _durationSeconds, delta);
        SetPositionSeconds(target, _durationSeconds);
        KeyboardCommitted?.Invoke(target);
        e.Handled = true;
    }

    private void OnPointerPressedInternal(object sender, PointerRoutedEventArgs e)
    {
        if (!IsEnabled || _dragging) return;
        var point = e.GetCurrentPoint(this);
        if (point.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Mouse
            && !point.Properties.IsLeftButtonPressed) return;
        _dragging = true;
        _releaseExpected = false;
        _pointer = e.Pointer;
        _originalValue = Value;
        _dragStartX = point.Position.X;
        HorizontalDelta = 0;
        // WinUI may update the value before this handled-event observer runs.
        SetValueFromX(point.Position.X);
        DragStarted?.Invoke();
        DragPreview?.Invoke(SecondsFromValue());
        e.Handled = true;
    }

    private void OnPointerMovedInternal(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging || _pointer is null || e.Pointer.PointerId != _pointer.PointerId) return;
        var point = e.GetCurrentPoint(this);
        HorizontalDelta = point.Position.X - _dragStartX;
        SetValueFromX(point.Position.X);
        DragPreview?.Invoke(SecondsFromValue());
        e.Handled = true;
    }

    private void OnPointerReleasedInternal(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging || _pointer is null || e.Pointer.PointerId != _pointer.PointerId) return;
        SetValueFromX(e.GetCurrentPoint(this).Position.X);
        var target = SecondsFromValue();
        _dragging = false;
        _releaseExpected = false;
        _captureLossGeneration++;
        _pointer = null;
        DragCommitted?.Invoke(target);
        e.Handled = true;
    }
    private void SetValueFromX(double x)
    {
        var width = Math.Max(1, ActualWidth);
        Value = Math.Clamp(Math.Round(x / width * (Maximum - Minimum) + Minimum), Minimum, Maximum);
    }

    private double SecondsFromValue() => _durationSeconds > 0 ? Value / 1000 * _durationSeconds : 0;
}
public sealed class CompactVolumeSlider : Slider
{
    private bool _dragging;
    private Pointer? _pointer;
    private double _originalValue;

    internal event Action<double>? Committed;
    internal bool Dragging => _dragging;

    public CompactVolumeSlider()
    {
        AddHandler(PointerPressedEvent, new PointerEventHandler(OnPointerPressedInternal), true);
        AddHandler(PointerReleasedEvent, new PointerEventHandler(OnPointerReleasedInternal), true);
        PointerCanceled += (_, _) => CancelDrag();
    }

    internal void CancelDrag()
    {
        if (!_dragging) return;
        _dragging = false;
        _pointer = null;
        Value = _originalValue;
    }

    protected override void OnKeyDown(KeyRoutedEventArgs e)
    {
        if (!IsEnabled)
        {
            base.OnKeyDown(e);
            return;
        }
        var delta = e.Key switch
        {
            VirtualKey.Left or VirtualKey.Down => -1,
            VirtualKey.Right or VirtualKey.Up => 1,
            VirtualKey.PageDown => -10,
            VirtualKey.PageUp => 10,
            VirtualKey.Home => int.MinValue,
            VirtualKey.End => int.MaxValue,
            _ => 0
        };
        if (delta == 0)
        {
            base.OnKeyDown(e);
            return;
        }
        Value = delta == int.MinValue ? Minimum : delta == int.MaxValue
            ? Maximum : Math.Clamp(Value + delta, Minimum, Maximum);
        Committed?.Invoke(Value / Math.Max(1, Maximum));
        e.Handled = true;
    }

    private void OnPointerPressedInternal(object sender, PointerRoutedEventArgs e)
    {
        if (!IsEnabled || _dragging) return;
        var point = e.GetCurrentPoint(this);
        if (point.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Mouse
            && !point.Properties.IsLeftButtonPressed) return;
        _dragging = true;
        _pointer = e.Pointer;
        _originalValue = Value;
    }

    private void OnPointerReleasedInternal(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging || _pointer is null || e.Pointer.PointerId != _pointer.PointerId) return;
        _dragging = false;
        _pointer = null;
        Committed?.Invoke(Value / Math.Max(1, Maximum));
    }
}
