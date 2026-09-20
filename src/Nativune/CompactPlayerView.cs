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
using Windows.Foundation;
using Windows.System;

namespace Nativune;

/// <summary>
/// Native-only compact playback surface. It owns presentation state and gestures, never a WebView
/// or service state. The host remains the sole owner of playback reads and command dispatch.
/// </summary>
public sealed partial class CompactPlayerView : UserControl, IDisposable
{
    private const int LogicalMinimumWidth = 800;
    private const int LogicalMinimumHeight = 180;
    private const double DegreesPerScrubDip = 0.35;
    private const double DegreesPerSecond = 12;

    private readonly NativeIconCache _iconCache = new();
    private IconElement? _previousIconElement;
    private IconElement? _playPauseIconElement;
    private IconElement? _nextIconElement;
    private IconElement? _likeIconElement;
    private IconElement? _dislikeIconElement;
    private IconElement? _volumeIconElement;
    private IconElement? _repeatIconElement;
    private IconElement? _shuffleIconElement;
    private IconElement? _returnToFullIconElement;
    private IconElement? _moreIconElement;
    private IconElement? _minimizeIconElement;
    private IconElement? _closeIconElement;
    private IconElement? _muteIconElement;
    private IconElement? _timerIconElement;
    private IconElement? _settingsMenuIconElement;
    private IconElement? _statusMenuIconElement;
    private IconElement? _topmostMenuIconElement;
    private string? _playPauseIconName;
    private string? _volumeIconName;
    private string? _repeatIconName;
    private string? _muteIconName;
    private string? _timerIconName;
    private bool _playVisualInitialized;
    private bool _lastPlayVisualEnabled;
    private bool _lastPlayPointerOver;
    private bool _lastPlayPressed;
    private bool _lastPlayHighContrast;
    private bool _repeatMarkerThemeInitialized;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _animationTimer;
    private readonly CompactArtworkCanvas _artwork;
    private readonly CompactMarqueeText _title;
    private readonly TextBlock _inlineStatus;
    private readonly TextBlock _remaining;
    private readonly TextBlock _duration;
    private readonly CompactSeekSlider _seek;
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
    private readonly Button _timer;
    private readonly Button _returnToFull;
    private readonly Button _more;
    private readonly Button _minimize;
    private readonly Button _close;
    private readonly MenuFlyout _moreMenu;
    private readonly MenuFlyoutItem _settingsItem;
    private readonly MenuFlyoutItem _statusItem;
    private readonly ToggleMenuFlyoutItem _topmostItem;
    private readonly Flyout _volumePopup;
    private readonly CompactVolumeSlider _volumeSlider;
    private readonly Button _muteButton;
    private readonly TextBlock _volumeValue;
    private readonly ContentControl _timerIcon;
    private readonly TextBlock _timerText;
    private readonly Canvas _layoutCanvas;

    private CompactPlaybackState? _state;
    private bool _reduceMotion;
    private bool _active = true;
    private bool _disposed;
    private bool _updatingControls;
    private bool _dragging;
    private bool _playPointerOver;
    private bool _playPressed;
    private double _dragStartAngle;
    private DateTime _lastAnimation;
    private TimeSpan? _timerRemaining;
    private string _statusMessage = string.Empty;
    private bool _statusIsError;
    private FrameworkElement? _popupInvoker;
    private ShortcutBindings _shortcutBindings = ShortcutBindings.Default;

    internal event Action<string, double?>? CommandRequested;
    internal event Action? ReturnToFullRequested;
    internal event Action? SettingsRequested;
    internal event Action? StatusRequested;
    internal event Action? TimerRequested;
    internal event Action? CancelTimerRequested;
    internal event Action? ToggleTopmostRequested;
    internal event Action? MinimizeRequested;
    internal event Action? CloseRequested;
    internal event Action? DragWindowRequested;

    public CompactPlayerView()
    {
        InitializeComponent();

        _layoutCanvas = LayoutCanvas;
        _artwork = Artwork;
        _title = Title;
        _inlineStatus = InlineStatus;
        _remaining = Remaining;
        _duration = Duration;
        _seek = Seek;
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
        _timer = Timer;
        _returnToFull = ReturnToFull;
        _more = More;
        _minimize = Minimize;
        _close = Close;
        _moreMenu = MoreMenu;
        _settingsItem = SettingsItem;
        _statusItem = StatusItem;
        _topmostItem = TopmostItem;
        _volumePopup = VolumePopup;
        _volumeSlider = VolumeSlider;
        _muteButton = MuteButton;
        _volumeValue = VolumeValue;
        _timerIcon = TimerIcon;
        _timerText = TimerText;

        var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread()
            ?? throw new InvalidOperationException("Compact player requires a DispatcherQueue.");
        _animationTimer = dispatcher.CreateTimer();
        _animationTimer.Interval = TimeSpan.FromMilliseconds(33);
        _animationTimer.IsRepeating = true;
        _animationTimer.Tick += (_, _) => AnimationTick();

        ConfigureControls();
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

    internal static int LogicalMinimumWidthValue => LogicalMinimumWidth;
    internal static int LogicalMinimumHeightValue => LogicalMinimumHeight;
    internal static System.Drawing.Size LogicalMinimumSize => new(LogicalMinimumWidth, LogicalMinimumHeight);

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
        if (_seek.Dragging && (state is null || _state is null || state.Title != _state.Title
            || state.ArtworkUrl != _state.ArtworkUrl || state.Duration != _state.Duration))
            _seek.CancelDrag();

        _state = state;
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
        _remaining.Foreground = _inlineStatus.Foreground;
        _duration.Foreground = _inlineStatus.Foreground;
        BindButtonTheme();
        ApplySecondaryVisuals();
        RefreshBoundIcons();
        SetRepeatAccessibility(_state?.Repeat is { } repeat ? FormatRepeat(repeat) : null, _state?.CanRepeat == true);
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
        _statusItem.IsEnabled = _statusMessage.Length != 0;
        _statusItem.Text = isError ? "Application status (error)" : "Application status";
        SetAccessible(_statusItem, "Read application status", _statusMessage);
        SetAccessible(_more, "More", _statusMessage.Length == 0
            ? "More settings and application status."
            : $"More settings and application status. Current status: {_statusMessage}");
        UpdateInlineStatus();
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
            _volumeSlider.CancelDrag();
            _moreMenu.Hide();
            _volumePopup.Hide();
            _seek.CancelDrag();
            _animationTimer.Stop();
        }
        else
            UpdateAnimationTimer();
    }

    public void Dispose()
    {
        if (_disposed) return;
        _disposed = true;
        _animationTimer.Stop();
        _moreMenu.Hide();
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
        DragWindowRequested = null;
    }

    private void ConfigureControls()
    {
        ConfigureButton(_previous, "Previous item", "Previous item.");
        ConfigureButton(_playPause, "Playback controls unavailable", "Playback controls unavailable.");
        ConfigureButton(_next, "Next item", "Next item.");
        ConfigureButton(_volume, "Volume controls", "Open volume control.");
        ConfigureButton(_repeat, "Repeat unavailable", "Repeat state is unavailable until playback controls recover.");
        ConfigureButton(_shuffle, "Shuffle unavailable", "Shuffle is unavailable until playback controls recover.");
        ConfigureButton(_returnToFull, "Return to full", "Return to the full app.");
        ConfigureButton(_more, "More", "More settings and application status.");
        ConfigureButton(_minimize, "Minimize", "Minimize window.");
        ConfigureButton(_close, "Close", "Close app and stop playback.");
        ConfigureButton(_timer, "Set pause timer", "Set a pause timer; the app stays open.");
        ConfigureButton(_muteButton, "Mute unavailable", "Mute state is unavailable until playback controls recover.");
        ConfigureButton(_like, "Like unavailable", "Like state is unavailable until playback controls recover.");
        ConfigureButton(_dislike, "Dislike unavailable", "Dislike state is unavailable until playback controls recover.");

        _title.IsTabStop = true;
        SetAccessible(_title, "Track title", "Track title.");
        SetAccessible(_artwork, "Album artwork", "Circular album artwork. Artwork is decorative.");
        SetAccessible(_inlineStatus, "Application status", "Application status.");
        SetAccessible(_remaining, "Remaining time", "Remaining time.");
        SetAccessible(_duration, "Total duration", "Total duration.");
        SetAccessible(_seek, "Playback position unavailable", "Playback position unavailable.");
        SetAccessible(_volumeSlider, "Volume", "Volume from zero to one hundred percent.");
        _remaining.Text = "--:--";
        _duration.Text = "--:--";
        _inlineStatus.Visibility = Visibility.Collapsed;
        _seek.DragStarted += BeginSeekDrag;
        _seek.DragPreview += PreviewSeekDrag;
        _seek.DragCommitted += CommitSeekDrag;
        _seek.KeyboardCommitted += CommitKeyboardSeek;
        _seek.DragCancelled += CancelSeekDrag;
        _volumeSlider.ValueChanged += VolumeSliderChanged;
        _volumeSlider.Committed += VolumeSliderCommitted;

        _previous.Click += (_, _) => RaiseCommand("previous");
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
        _like.Click += (_, _) =>
        {
            RestoreRatingState(_like, _state?.Liked);
            RaiseCommand("like");
        };
        _dislike.Click += (_, _) =>
        {
            RestoreRatingState(_dislike, _state?.Disliked);
            RaiseCommand("dislike");
        };
        _volume.Click += (_, _) => ShowVolumePopup();
        _muteButton.Click += (_, _) => RaiseCommand("mute");
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
        foreach (var button in new ButtonBase[]
        {
            _previous, _next, _like, _dislike, _repeat, _shuffle, _volume, _timer,
            _returnToFull, _more, _minimize, _close, _muteButton, _playPause
        })
            button.IsEnabledChanged += (_, _) => ApplySecondaryVisuals();

        _settingsItem.Click += (_, _) => SettingsRequested?.Invoke();
        _statusItem.Click += (_, _) => StatusRequested?.Invoke();
        _topmostItem.Click += (_, _) => ToggleTopmostRequested?.Invoke();
        _moreMenu.Closed += (_, _) => RestorePopupFocus();
        _volumePopup.Closed += (_, _) => RestorePopupFocus();
        _volumePopup.Opened += (_, _) =>
        {
            if (_volumeSlider.IsEnabled)
                _volumeSlider.Focus(FocusState.Programmatic);
        };

        foreach (var surface in new FrameworkElement[]
        {
            _layoutCanvas, _artwork, _title, _inlineStatus, _remaining, _duration
        })
            surface.PointerPressed += DragSurfacePointerPressed;
    }

    private void BindUnavailableState()
    {
        var title = DisplayTitle(null);
        _title.SetText(title);
        SetToolTipIfChanged(_title, null);
        SetAccessible(_title, title, "Player unavailable. Return to the full app remains available.");
        _artwork.SetImage(null);
        SetTextIfChanged(_remaining, "--:--");
        SetTextIfChanged(_duration, "--:--");
        if (_seek.IsEnabled) _seek.IsEnabled = false;
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
        if (_volume.IsEnabled) _volume.IsEnabled = false;
        SetAccessible(_volume, "Volume controls unavailable", "Volume controls are unavailable until playback controls recover.");
        _volumeSlider.CancelDrag();
        if (_volumeSlider.IsEnabled) _volumeSlider.IsEnabled = false;
        if (_volumePopup.IsOpen) _volumePopup.Hide();
        if (_muteButton.IsEnabled) _muteButton.IsEnabled = false;
        SetAccessible(_muteButton, "Mute unavailable", "Mute state is unavailable until playback controls recover.");
        if (_repeat.IsEnabled) _repeat.IsEnabled = false;
        SetRepeatAccessibility(null, false);
        if (_shuffle.IsEnabled) _shuffle.IsEnabled = false;
        SetAccessible(_shuffle, "Shuffle unavailable", "Shuffle is unavailable until playback controls recover.");
    }

    private void BindPlaybackState(CompactPlaybackState state)
    {
        var title = DisplayTitle(state);
        _title.SetText(title);
        SetToolTipIfChanged(_title, title);
        SetAccessible(_title, title, title);
        var canSeek = state.CanSeek && state.Duration > 0 && double.IsFinite(state.Duration);
        if (_seek.Dragging && !canSeek) _seek.CancelDrag();
        if (!double.Equals(_seek.DurationSeconds, state.Duration))
            _seek.DurationSeconds = state.Duration;
        if (_seek.IsEnabled != canSeek) _seek.IsEnabled = canSeek;
        if (!_seek.Dragging)
        {
            _seek.SetPositionSeconds(state.Position, state.Duration);
            SetTextIfChanged(_remaining, FormatRemaining(state.Position, state.Duration));
        }
        SetTextIfChanged(_duration, FormatTime(state.Duration > 0 ? state.Duration : null));
        SetAccessible(_seek, canSeek ? "Playback position" : "Playback position unavailable",
            canSeek
                ? $"Playback position {FormatTime(state.Position)} of {FormatTime(state.Duration)}. Use Left and Right for five-second steps, Page Up and Page Down for thirty-second steps, Home for the beginning and End for the end."
                : "Seeking unavailable; track duration or public seek control is unknown.");

        SetEnabled(_previous, true, "Previous item", "Previous item.");
        SetEnabled(_playPause, true, state.Paused ? "Play" : "Pause",
            state.Paused ? "Play website playback." : "Pause website playback.");
        SetEnabled(_next, true, "Next item", "Next item.");

        var liked = state.CanLike ? state.Liked : null;
        var likeEnabled = state.CanLike && liked.HasValue;
        if (_like.IsEnabled != likeEnabled) _like.IsEnabled = likeEnabled;
        if (_like.IsChecked != liked) _like.IsChecked = liked;
        SetRatingAccessibility(_like, "Like", liked, state.CanLike);
        var disliked = state.CanDislike ? state.Disliked : null;
        var dislikeEnabled = state.CanDislike && disliked.HasValue;
        if (_dislike.IsEnabled != dislikeEnabled) _dislike.IsEnabled = dislikeEnabled;
        if (_dislike.IsChecked != disliked) _dislike.IsChecked = disliked;
        SetRatingAccessibility(_dislike, "Dislike", disliked, state.CanDislike);

        if (_volume.IsEnabled != state.CanVolume) _volume.IsEnabled = state.CanVolume;
        var percent = Math.Round(Math.Clamp(double.IsFinite(state.Volume) ? state.Volume : 0, 0, 1) * 100);
        SetAccessible(_volume, state.CanVolume ? "Volume controls" : "Volume controls unavailable",
            state.CanVolume ? $"Open volume control. {percent:0} percent; {(state.Muted ? "muted" : "unmuted")}."
                : "Volume controls are unavailable until playback controls recover.");
        if (_muteButton.IsEnabled != state.CanVolume) _muteButton.IsEnabled = state.CanVolume;
        SetAccessible(_muteButton, state.CanVolume ? (state.Muted ? "Unmute" : "Mute") : "Mute unavailable",
            state.CanVolume ? $"{(state.Muted ? "Unmute" : "Mute")} playback." : "Mute state is unavailable until playback controls recover.");
        if (_volumeSlider.IsEnabled != state.CanVolume) _volumeSlider.IsEnabled = state.CanVolume;
        if (!state.CanVolume)
        {
            _volumeSlider.CancelDrag();
            if (_volumePopup.IsOpen) _volumePopup.Hide();
        }
        if (!_volumeSlider.Dragging && !double.Equals(_volumeSlider.Value, percent))
            _volumeSlider.Value = percent;
        SetTextIfChanged(_volumeValue, $"{_volumeSlider.Value:0}%");

        var repeat = state.Repeat is null ? null : FormatRepeat(state.Repeat);
        if (_repeat.IsEnabled != (state.CanRepeat && repeat is not null))
            _repeat.IsEnabled = state.CanRepeat && repeat is not null;
        SetRepeatAccessibility(repeat, state.CanRepeat);
        if (_shuffle.IsEnabled != state.CanShuffle) _shuffle.IsEnabled = state.CanShuffle;
        SetAccessible(_shuffle, state.CanShuffle ? "Shuffle queue once" : "Shuffle unavailable",
            state.CanShuffle ? "Shuffle the queue once." : "Shuffle is unavailable until playback controls recover.");
    }


    private void LayoutControls()
    {
        if (_disposed) return;
        var width = Math.Max(LogicalMinimumWidth, ActualWidth > 0 ? ActualWidth : LogicalMinimumWidth);
        var horizontalExtra = Math.Max(0, width - LogicalMinimumWidth);
        var utilityShift = horizontalExtra;
        const double seekY = 120;

        SetBounds(_artwork, 20, 26, 112, 112);
        SetBounds(_title, 152, 16, 452 + horizontalExtra, 32);
        SetBounds(_inlineStatus, 152, 48, 452 + horizontalExtra, 16);
        SetBounds(_returnToFull, 640 + utilityShift, 12, 36, 36);
        SetBounds(_more, 680 + utilityShift, 12, 36, 36);
        SetBounds(_minimize, 720 + utilityShift, 12, 36, 36);
        SetBounds(_close, 760 + utilityShift, 12, 36, 36);
        SetBounds(_previous, 152, 68, 40, 40);
        SetBounds(_playPause, 200, 64, 48, 48);
        SetBounds(_next, 256, 68, 40, 40);
        SetBounds(_like, 312, 68, 40, 40);
        SetBounds(_dislike, 356, 68, 40, 40);
        SetBounds(_repeat, 424, 68, 40, 40);
        SetBounds(_shuffle, 468, 68, 40, 40);
        SetBounds(_volume, 512, 68, 40, 40);
        SetBounds(_timer, 568, 68, 148, 40);
        SetBounds(ProgressRow, 152, seekY, 632 + horizontalExtra, 40);
    }

    private static void SetBounds(FrameworkElement element, double left, double top, double width, double height)
    {
        Canvas.SetLeft(element, left);
        Canvas.SetTop(element, top);
        element.Width = width;
        element.Height = height;
    }

    private void ShowVolumePopup()
    {
        if (_disposed || !_volume.IsEnabled || !_active) return;
        var volume = _state?.Volume ?? 0;
        _updatingControls = true;
        try
        {
            _volumeSlider.Value = Math.Round(Math.Clamp(double.IsFinite(volume) ? volume : 0, 0, 1) * 100,
                MidpointRounding.AwayFromZero);
            _volumeValue.Text = $"{_volumeSlider.Value:0}%";
        }
        finally
        {
            _updatingControls = false;
        }
        _popupInvoker = _volume;
        _volumePopup.ShowAt(_volume);
    }

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
        var fallback = _state is null ? "Controls unavailable — More → Application status." : string.Empty;
        var text = _statusMessage.Length == 0 ? fallback : _statusMessage;
        SetTextIfChanged(_inlineStatus, text);
        var visibility = text.Length == 0 ? Visibility.Collapsed : Visibility.Visible;
        if (_inlineStatus.Visibility != visibility) _inlineStatus.Visibility = visibility;
        SetAccessible(_inlineStatus, "Application status", _statusMessage.Length == 0 ? fallback : _statusMessage);
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
            _previous, _next, _like, _dislike, _repeat, _shuffle, _volume, _timer,
            _returnToFull, _more, _minimize, _close, _muteButton
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
            _previous, _next, _like, _dislike, _repeat, _shuffle, _volume, _timer,
            _returnToFull, _more, _minimize, _close, _muteButton
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
            BindFixedIcon(_like, ref _likeIconElement, "like", 20);
            BindFixedIcon(_dislike, ref _dislikeIconElement, "dislike", 20);
            var volumeIcon = _state?.Muted == true ? "volume-muted" : "volume";
            BindStatefulIcon(_volume, ref _volumeIconElement, ref _volumeIconName, volumeIcon, 20);
            BindStatefulIcon(_repeatIcon, ref _repeatIconElement, ref _repeatIconName,
                IsRepeatOne(_state?.Repeat) ? "repeat-one" : "repeat", 20);
            BindFixedIcon(_shuffle, ref _shuffleIconElement, "shuffle", 20);
            BindFixedIcon(_returnToFull, ref _returnToFullIconElement, "restore-window", 16);
            BindFixedIcon(_more, ref _moreIconElement, "overflow", 16);
            BindFixedIcon(_minimize, ref _minimizeIconElement, "minimize", 16);
            BindFixedIcon(_close, ref _closeIconElement, "close", 16);
            BindStatefulIcon(_muteButton, ref _muteIconElement, ref _muteIconName, volumeIcon, 16);
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
        _remaining.Text = FormatRemaining(position, _state.Duration);
        _artwork.Angle = SeekPreviewAngle(_dragStartAngle, _seek.HorizontalDelta, _reduceMotion);
    }

    private void CommitSeekDrag(double position)
    {
        var wasDragging = _dragging;
        _dragging = false;
        if (_state is null || !_seek.IsEnabled) return;
        var target = ClampSeekTarget(position, _state.Duration);
        _remaining.Text = FormatRemaining(target, _state.Duration);
        if (ShouldCommitSeek(wasDragging, false)) RaiseCommand("seek", target);
        UpdateAnimationTimer();
    }

    private void CommitKeyboardSeek(double position)
    {
        if (_state is null || !_seek.IsEnabled) return;
        var target = ClampSeekTarget(position, _state.Duration);
        _remaining.Text = FormatRemaining(target, _state.Duration);
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
            _remaining.Text = FormatRemaining(state.Position, state.Duration);
            _seek.SetPositionSeconds(state.Position, state.Duration);
        }
        UpdateAnimationTimer();
    }

    private void VolumeSliderChanged(object? sender, RangeBaseValueChangedEventArgs e)
    {
        _volumeValue.Text = $"{_volumeSlider.Value:0}%";
        SetAccessible(_volumeSlider, "Volume", $"Volume {_volumeSlider.Value:0} percent. Use Left and Right for five-percent steps.");
    }

    private void VolumeSliderCommitted(double normalized)
    {
        if (!_updatingControls && _volumePopup.IsOpen)
            RaiseCommand("volume", Math.Clamp(normalized, 0, 1));
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

    private void DragSurfacePointerPressed(object sender, PointerRoutedEventArgs e)
    {
        if (_disposed || !_active) return;
        if (ReferenceEquals(sender, _layoutCanvas) && !ReferenceEquals(e.OriginalSource, _layoutCanvas)) return;
        var point = e.GetCurrentPoint((UIElement)sender);
        if (point.PointerDeviceType == Microsoft.UI.Input.PointerDeviceType.Mouse
            && !point.Properties.IsLeftButtonPressed)
            return;
        DragWindowRequested?.Invoke();
        e.Handled = true;
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
        var verb = confirmed.Value ? $"Remove {lower}" : action;
        SetAccessible(button, verb, confirmed.Value
            ? $"Confirmed {lower} state. Activate to remove {lower}."
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

    private static string FormatRemaining(double position, double duration)
        => !double.IsFinite(duration) || duration <= 0 || !double.IsFinite(position)
            ? "--:--" : FormatTime(Math.Max(0, duration - position));

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
    private readonly Grid _content = new();
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
        if (!_overflow || _reduceMotion)
        {
            _primary.TextTrimming = TextTrimming.CharacterEllipsis;
            _primaryTransform.X = 0;
            _secondary.Visibility = Visibility.Collapsed;
        }
        else
        {
            _primary.TextTrimming = TextTrimming.None;
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
            VerticalAlignment = VerticalAlignment.Center,
            TextWrapping = TextWrapping.NoWrap,
            RenderTransform = transform
        };
}

public sealed class CompactSeekSlider : Slider
{
    private bool _dragging;
    private bool _releaseExpected;
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
    internal double DragStartX => _dragStartX;
    internal double HorizontalDelta { get; private set; }
    internal double DurationSeconds
    {
        get => _durationSeconds;
        set => _durationSeconds = value;
    }

    public CompactSeekSlider()
    {
        PointerPressed += OnPointerPressedInternal;
        PointerMoved += OnPointerMovedInternal;
        PointerReleased += OnPointerReleasedInternal;
        PointerCanceled += (_, _) => CancelDrag();
        PointerCaptureLost += (_, _) =>
        {
            if (_dragging && !_releaseExpected) CancelDrag();
        };
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
        _releaseExpected = true;
        if (_pointer is not null) ReleasePointerCapture(_pointer);
        _releaseExpected = false;
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
        Focus(FocusState.Pointer);
        CapturePointer(e.Pointer);
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
        var point = e.GetCurrentPoint(this);
        SetValueFromX(point.Position.X);
        var target = SecondsFromValue();
        _dragging = false;
        _releaseExpected = true;
        ReleasePointerCapture(e.Pointer);
        _releaseExpected = false;
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
    private bool _releaseExpected;
    private Pointer? _pointer;
    private double _originalValue;

    internal event Action<double>? Committed;
    internal bool Dragging => _dragging;

    public CompactVolumeSlider()
    {
        PointerPressed += OnPointerPressedInternal;
        PointerMoved += OnPointerMovedInternal;
        PointerReleased += OnPointerReleasedInternal;
        PointerCanceled += (_, _) => CancelDrag();
        PointerCaptureLost += (_, _) =>
        {
            if (_dragging && !_releaseExpected) CancelDrag();
        };
    }

    internal void CancelDrag()
    {
        if (!_dragging) return;
        _dragging = false;
        _releaseExpected = true;
        if (_pointer is not null) ReleasePointerCapture(_pointer);
        _releaseExpected = false;
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
            VirtualKey.Left or VirtualKey.Down => -5,
            VirtualKey.Right or VirtualKey.Up => 5,
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
        _releaseExpected = false;
        _pointer = e.Pointer;
        _originalValue = Value;
        Focus(FocusState.Pointer);
        CapturePointer(e.Pointer);
        SetValueFromX(point.Position.X);
        e.Handled = true;
    }

    private void OnPointerMovedInternal(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging || _pointer is null || e.Pointer.PointerId != _pointer.PointerId) return;
        SetValueFromX(e.GetCurrentPoint(this).Position.X);
        e.Handled = true;
    }

    private void OnPointerReleasedInternal(object sender, PointerRoutedEventArgs e)
    {
        if (!_dragging || _pointer is null || e.Pointer.PointerId != _pointer.PointerId) return;
        SetValueFromX(e.GetCurrentPoint(this).Position.X);
        _dragging = false;
        _releaseExpected = true;
        ReleasePointerCapture(e.Pointer);
        _releaseExpected = false;
        _pointer = null;
        Committed?.Invoke(Value / Math.Max(1, Maximum));
        e.Handled = true;
    }

    private void SetValueFromX(double x)
    {
        var width = Math.Max(1, ActualWidth);
        Value = Math.Clamp(Math.Round(x / width * (Maximum - Minimum) + Minimum), Minimum, Maximum);
    }
}
