using System.Drawing;
using System.Reflection;
using Microsoft.UI;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using System.Runtime.InteropServices;
using Microsoft.UI.Input;
using FoundationRect = Windows.Foundation.Rect;
using FoundationSize = Windows.Foundation.Size;

namespace Nativune;

internal static class CompactViewChecks
{
    private static readonly string[] RequiredParts =
    {
        "Artwork", "Title", "InlineStatus", "Remaining", "Duration", "Seek",
        "Previous", "PlayPause", "Next", "Like", "Dislike", "Repeat", "Shuffle",
        "Volume", "Timer", "ReturnToFull", "More", "Minimize", "Close"
    };
    private const uint WmNcHitTest = 0x0084;
    private const int HtLeft = 10;

    internal static void Run()
    {
        Require(CompactPlayerView.LogicalMinimumWidthValue == 800
            && CompactPlayerView.LogicalMinimumHeightValue == 180
            && CompactPlayerView.LogicalMinimumSize == new Size(800, 180),
            "Compact player minimum logical size changed.");

        using var outputPreference = new WebViewAudioVolume(
            Path.Combine(AppContext.BaseDirectory, "msedgewebview2.exe"));
        outputPreference.SetPreferredOutput(.4, true);
        outputPreference.SetPreferredOutput(.65, null);
        Require(!outputPreference.Available
            && !outputPreference.HasVerifiedOwnedSessions
            && Math.Abs(Convert.ToSingle(ReadField(outputPreference, "_preferredVolume")) - .65f) < .0001f
            && ReadField(outputPreference, "_hasMutePreference") is true
            && ReadField(outputPreference, "_preferredMute") is true,
            "Offline output preference was applied without a session or lost its explicit mute choice.");
        var rejectedInvalidVolume = false;
        try { outputPreference.SetPreferredOutput(double.NaN, false); }
        catch (ArgumentOutOfRangeException) { rejectedInvalidVolume = true; }
        Require(rejectedInvalidVolume
            && ReadField(outputPreference, "_preferredMute") is true,
            "Invalid offline output gain changed the queued mute preference.");

        var ownedProcessIds = new HashSet<int> { 1234, 5678 };
        Require(WebViewAudioVolume.IsMixedAudioSessionProcessResult(
                WebViewAudioVolume.AudclntSNoSingleProcess)
            && !WebViewAudioVolume.IsMixedAudioSessionProcessResult(0)
            && WebViewAudioVolume.IsOwnedWebViewProcessId(1234, ownedProcessIds)
            && !WebViewAudioVolume.IsOwnedWebViewProcessId(9876, ownedProcessIds)
            && !WebViewAudioVolume.IsOwnedWebViewProcessId(0, ownedProcessIds),
            "Mixed-process sessions were not isolated from exact WebView PID ownership checks.");

        Require(!WebViewAudioVolume.AreOutputStatesConsistent(
                Array.Empty<(float Volume, bool Muted)>())
            && WebViewAudioVolume.AreOutputStatesConsistent(
                new[] { (0.65f, false), (0.65005f, false) })
            && !WebViewAudioVolume.AreOutputStatesConsistent(
                new[] { (0.1f, false), (0.7f, false) })
            && !WebViewAudioVolume.AreOutputStatesConsistent(
                new[] { (0.65f, false), (0.65f, true) }),
            "Offline output-state consistency did not distinguish uniform from divergent owned sessions.");

        Require(WebHostWindow.CanAttemptOutputPreferenceRevision(4, 3, 4, 0, 2)
            && WebHostWindow.CanAttemptOutputPreferenceRevision(4, 3, 4, 1, 2)
            && !WebHostWindow.CanAttemptOutputPreferenceRevision(4, 3, 4, 2, 2)
            && !WebHostWindow.CanAttemptOutputPreferenceRevision(4, 4, 4, 0, 2)
            && WebHostWindow.CanAttemptOutputPreferenceRevision(5, 4, 4, 2, 2),
            "Failed output preference writes either advanced the applied revision or retried without a bound.");

        Require(WebViewAudioVolume.ShouldRetryNewSessionPreference(0)
            && WebViewAudioVolume.ShouldRetryNewSessionPreference(
                WebViewAudioVolume.MaximumNewSessionPreferenceAttempts - 1)
            && !WebViewAudioVolume.ShouldRetryNewSessionPreference(
                WebViewAudioVolume.MaximumNewSessionPreferenceAttempts)
            && !WebViewAudioVolume.ShouldRetryNewSessionPreference(-1),
            "Failed new-session default applies were not retried within the configured bound.");

        Require(CompactPlayerView.ClampSeekTarget(-2, 180) == 0
            && CompactPlayerView.ClampSeekTarget(200, 180) == 180
            && CompactPlayerView.ClampSeekTarget(42, 180) == 42,
            "Seek targets were not bounded to the known duration.");
        Require(CompactPlayerView.ClampSeekTarget(double.NaN, 180) == 0
            && CompactPlayerView.ClampSeekTarget(double.PositiveInfinity, 180) == 180,
            "Invalid seek positions were not handled fail-closed.");

        Require(CompactPlayerView.KeyboardSeekTarget(10, 180, 5) == 15
            && CompactPlayerView.KeyboardSeekTarget(178, 180, 5) == 180
            && CompactPlayerView.KeyboardSeekTarget(2, 180, -5) == 0,
            "Keyboard seek steps escaped their duration bounds.");

        var clockwise = CompactPlayerView.SeekPreviewAngle(20, 40, reduceMotion: false);
        var backward = CompactPlayerView.SeekPreviewAngle(20, -40, reduceMotion: false);
        Require(clockwise > 20 && backward < 20,
            "Seek-driven artwork rotation did not follow horizontal movement.");
        Require(CompactPlayerView.SeekPreviewAngle(20, 400, reduceMotion: true) == 20,
            "Reduced motion still changed the artwork angle.");

        Require(CompactPlayerView.ShouldAnimate(active: true, visible: true, reduceMotion: false,
                paused: false, longTitle: false),
            "Playing compact artwork did not request local animation.");
        Require(!CompactPlayerView.ShouldAnimate(active: true, visible: true, reduceMotion: false,
                paused: true, longTitle: false)
            && CompactPlayerView.ShouldAnimate(active: true, visible: true, reduceMotion: false,
                paused: true, longTitle: true),
            "Paused compact animation policy changed for short or long titles.");
        Require(!CompactPlayerView.ShouldAnimate(active: false, visible: true, reduceMotion: false,
                paused: false, longTitle: true)
            && !CompactPlayerView.ShouldAnimate(active: true, visible: false, reduceMotion: false,
                paused: false, longTitle: true)
            && !CompactPlayerView.ShouldAnimate(active: true, visible: true, reduceMotion: true,
                paused: false, longTitle: true),
            "Compact animation was not suspended for inactive, hidden or reduced-motion views.");

        Require(CompactPlayerView.ShouldCommitSeek(hasPendingTarget: true, cancelled: false),
            "A completed seek interaction did not commit.");
        Require(!CompactPlayerView.ShouldCommitSeek(hasPendingTarget: true, cancelled: true)
            && !CompactPlayerView.ShouldCommitSeek(hasPendingTarget: false, cancelled: false),
            "Cancelled or empty seek interactions committed unexpectedly.");

        var unavailableStatus = WebHostWindow.BuildStatusDetailsText(string.Empty,
            compact: true, compactPlaybackAvailable: false);
        Require(unavailableStatus.Contains("Compact playback state: unavailable", StringComparison.Ordinal)
            && unavailableStatus.Contains("does not identify a YouTube Music website error",
                StringComparison.Ordinal),
            "Unavailable Compact status did not distinguish missing state from a website error.");
        var explicitErrorStatus = WebHostWindow.BuildStatusDetailsText(
            "[!] Error: Synthetic native failure.", compact: true, compactPlaybackAvailable: false);
        Require(explicitErrorStatus.Contains("[!] Error: Synthetic native failure.", StringComparison.Ordinal),
            "Compact diagnostics replaced an explicitly observed application error.");
    }

    /// <summary>
    /// Exercises the actual WinUI Compact surface hosted by the browser-free native shell.
    /// The host owns the application lifetime; this method never starts a second XAML loop.
    /// </summary>
    internal static async Task RunNativeAsync(WebHostWindow host)
    {
        var phase = "startup";
        try
        {
            phase = "host-content";
        ArgumentNullException.ThrowIfNull(host);
        if (host.Content is not FrameworkElement root)
            throw new SelfCheckException("Compact host did not expose a XAML root.");
        phase = "root-layout";
        Prepare(root);
        var fullMute = FindPart(root, "OutputMuteButton") as Button;
        var fullFlyout = fullMute?.ContextFlyout as Flyout;
        var flyoutSurface = fullFlyout?.Content as FrameworkElement;
        var fullVolume = flyoutSurface is null ? null
            : FindPart(flyoutSurface, "OutputVolumeSlider") as CompactVolumeSlider;
        var fullReadout = flyoutSurface is null ? null
            : FindPart(flyoutSurface, "OutputVolumeValue") as TextBlock;
        Require(fullMute is not null && fullFlyout is not null && fullVolume is not null
            && fullReadout is not null && !fullFlyout.IsOpen
            && !fullFlyout.ShouldConstrainToRootBounds
            && !fullMute.IsEnabled && !fullVolume.IsEnabled
            && WebViewAudioVolume.DefaultVolume == 1f
            && fullVolume.Maximum == 1000 && fullVolume.Value == fullVolume.Maximum
            && fullReadout.Text == "100.0%"
            && AutomationProperties.GetName(fullVolume) == "WebView audio volume",
            "Full-window output button/flyout or 100% default was absent, mislabeled, or enabled without an owned audio session.");

        phase = "compact-layout";
        var view = root as CompactPlayerView ?? FindDescendant<CompactPlayerView>(root)
            ?? throw new SelfCheckException("Compact presenter did not load CompactPlayerView.");
        Prepare(view);
        Require(view.ActualWidth >= CompactPlayerView.LogicalMinimumWidthValue
            && view.ActualHeight >= CompactPlayerView.LogicalMinimumHeightValue,
            "Compact presenter did not honor its 800 by 180 DIP minimum.");

        phase = "queued-output-without-session";
        var updateOutput = FindMethod(host, "UpdateOutputAudioControls")
            ?? throw new SelfCheckException("Native output state update hook was not retained.");
        SetField(host, "_outputAudioExecutablePath", Path.Combine(AppContext.BaseDirectory, "msedgewebview2.exe"));
        updateOutput.Invoke(host, null);
        var compactOutput = FindPart(view, "Volume") as Control;
        Require(fullMute is { IsEnabled: true } && fullVolume is { IsEnabled: true }
            && compactOutput?.IsEnabled == true
            && AutomationProperties.GetHelpText(fullMute)?.Contains("pending preference", StringComparison.Ordinal) == true
            && AutomationProperties.GetHelpText(compactOutput)?.Contains("pending", StringComparison.Ordinal) == true,
            "Initialized WebView output was disabled or claimed an active audio session while paused.");
        SetField(host, "_outputAudioExecutablePath", null);
        updateOutput.Invoke(host, null);
        Require(fullMute?.IsEnabled == false && fullVolume?.IsEnabled == false
            && compactOutput?.IsEnabled == false,
            "Uninitialized WebView output did not return to its disabled state.");

        phase = "named-parts";
        var parts = RequiredParts.ToDictionary(name => name, name => FindPart(view, name),
            StringComparer.Ordinal);
        foreach (var part in parts)
        {
            var optionalStatus = part.Key == "InlineStatus";
            Require((optionalStatus || part.Value.Visibility == Visibility.Visible)
                && (optionalStatus || part.Value.ActualWidth > 0 && part.Value.ActualHeight > 0),
                $"Compact part {part.Key} was not laid out at the native minimum.");
            Require(!string.IsNullOrWhiteSpace(AutomationProperties.GetName(part.Value)),
                $"Compact part {part.Key} lost its automation name.");
        }
        phase = "compact-native-frame";
        CheckCompactNativeFrame(host, view);

        phase = "progress-row-spacing";

        foreach (var (width, height) in new[] { (800d, 180d), (814d, 253d), (1200d, 800d) })
        {
            Prepare(view, width, height);
            view.SetPreferences(reduceMotion: true, topmost: false);
            view.UpdateLayout();
            Require(Math.Abs(view.ActualWidth - width) <= 1
                && Math.Abs(view.ActualHeight - height) <= 1,
                "Compact spacing check did not receive the requested viewport.");
            var controlsBottom = Canvas.GetTop(parts["PlayPause"]) + parts["PlayPause"].Height;
            var progressRow = FindPart(view, "ProgressRow");
            var progressTop = Canvas.GetTop(progressRow);
            Require(progressTop - controlsBottom is >= 8 and <= 12,
                "Compact progress row drifted away from the playback controls when resized.");
            Require(progressTop + progressRow.ActualHeight <= view.ActualHeight,
                "Compact progress row was clipped at the minimum height.");
            var thumb = FindDescendant<Thumb>(parts["Seek"])
                ?? throw new SelfCheckException("Compact seek slider did not expose its native thumb.");
            var thumbBounds = thumb.TransformToVisual(parts["Seek"]).TransformBounds(
                new FoundationRect(0, 0, thumb.ActualWidth, thumb.ActualHeight));
            Require(thumbBounds.Top >= 2 && thumbBounds.Bottom + 2 <= parts["Seek"].ActualHeight,
                "Compact seek slider clipped its native thumb or outer border.");
            foreach (var name in new[] { "Remaining", "Duration" })
            {
                var label = parts[name];
                var labelBounds = label.TransformToVisual(progressRow).TransformBounds(
                    new FoundationRect(0, 0, label.ActualWidth, label.ActualHeight));
                // Text metrics can be fractional while DesiredSize rounds up to a DIP.
                Require(Math.Ceiling(label.ActualHeight) >= label.DesiredSize.Height
                    && labelBounds.Top >= 0 && labelBounds.Bottom <= progressRow.ActualHeight,
                    $"Compact progress timestamp {name} was clipped: actual={label.ActualHeight}, desired={label.DesiredSize.Height}, top={labelBounds.Top}, bottom={labelBounds.Bottom}, row={progressRow.ActualHeight}.");
                Require(Math.Abs(labelBounds.Top + labelBounds.Height / 2
                    - progressRow.ActualHeight / 2) <= 1,
                    "Compact progress timestamp was not vertically centered.");
            }
        }
        Prepare(view);

        phase = "playback-state";
        var state = new CompactPlaybackState(
            "Synthetic compact title", null, Paused: false, Position: 10, Duration: 120,
            Liked: true, Disliked: false, Repeat: "off",
            CanSeek: true, CanLike: true, CanDislike: true,
            CanRepeat: true, CanShuffle: true);
        var commands = new List<(string Command, double? Value)>();
        view.CommandRequested += (command, value) => commands.Add((command, value));
        view.SetOutputVolume(.5, false, true);
        view.SetPlayback(state);
        view.SetArtwork(null);
        view.SetStatus("Synthetic status", isError: false);
        view.SetTimer(TimeSpan.FromMinutes(14));
        view.SetPreferences(reduceMotion: false, topmost: false);
        Prepare(view);
        Require(parts["InlineStatus"].Visibility == Visibility.Visible
            && parts["InlineStatus"].ActualWidth > 0 && parts["InlineStatus"].ActualHeight > 0,
            "Compact status state did not reveal its native status surface.");

        Require(AutomationProperties.GetName(parts["PlayPause"])?.Contains("Pause",
                StringComparison.OrdinalIgnoreCase) == true,
            "Playing Compact state did not expose the Pause action.");
        Require(AutomationProperties.GetName(parts["Like"])?.Length > 0
            && AutomationProperties.GetName(parts["Seek"])?.Length > 0,
            "Confirmed Compact state lost control accessibility names.");
        var timerText = FindPart(view, "TimerText");
        Require(ReadProperty(timerText, "Text") is string timerValue
            && timerValue.StartsWith("Pause in ", StringComparison.Ordinal),
            "Armed Compact timer did not retain visible content.");
        var previousIcon = ReadProperty(parts["Previous"], "Content");
        var closeIcon = ReadProperty(parts["Close"], "Content");
        var playIcon = ReadProperty(parts["PlayPause"], "Content");
        var volumeIcon = ReadProperty(parts["Volume"], "Content");
        var repeatIcon = ReadProperty(FindPart(view, "RepeatIcon"), "Content");
        var timerIcon = ReadProperty(FindPart(view, "TimerIcon"), "Content");
        for (var tick = 0; tick < 4; tick++)
        {
            view.SetPlayback(state with { Position = 10 + tick });
            view.SetTimer(TimeSpan.FromMinutes(14).Add(TimeSpan.FromSeconds(tick)));
        }
        Require(ReferenceEquals(previousIcon, ReadProperty(parts["Previous"], "Content"))
            && ReferenceEquals(closeIcon, ReadProperty(parts["Close"], "Content"))
            && ReferenceEquals(playIcon, ReadProperty(parts["PlayPause"], "Content"))
            && ReferenceEquals(volumeIcon, ReadProperty(parts["Volume"], "Content"))
            && ReferenceEquals(repeatIcon, ReadProperty(FindPart(view, "RepeatIcon"), "Content"))
            && ReferenceEquals(timerIcon, ReadProperty(FindPart(view, "TimerIcon"), "Content")),
            "Repeated compact state/timer binds replaced unchanged native visuals.");

        view.SetPlayback(state with { Paused = true, Repeat = "one" });
        view.SetOutputVolume(.5, true, true);
        var changedPlayIcon = ReadProperty(parts["PlayPause"], "Content");
        var changedVolumeIcon = ReadProperty(parts["Volume"], "Content");
        var changedRepeatIcon = ReadProperty(FindPart(view, "RepeatIcon"), "Content");
        Require(!ReferenceEquals(playIcon, changedPlayIcon)
            && !ReferenceEquals(volumeIcon, changedVolumeIcon)
            && !ReferenceEquals(repeatIcon, changedRepeatIcon),
            "Changed compact playback glyphs did not replace their native visuals.");
        view.SetPlayback(state with { Paused = true, Repeat = "one" });
        Require(ReferenceEquals(changedPlayIcon, ReadProperty(parts["PlayPause"], "Content"))
            && ReferenceEquals(changedVolumeIcon, ReadProperty(parts["Volume"], "Content"))
            && ReferenceEquals(changedRepeatIcon, ReadProperty(FindPart(view, "RepeatIcon"), "Content")),
            "Repeated changed compact playback binds replaced stable glyphs.");
        Require(parts["Volume"] is Control volumeControl && volumeControl.IsEnabled,
            "Confirmed Compact state disabled the volume affordance.");
        phase = "state-markers-and-tooltip";
        var repeatMarker = FindPart(view, "RepeatMarker");
        var replacementTitle = "Synthetic replacement title with the complete native tooltip text.";
        view.SetPlayback(state with { Repeat = "all", Title = replacementTitle });
        Require(repeatMarker.Visibility == Visibility.Visible
            && ReadProperty(repeatMarker, "Text") as string == "A",
            "Confirmed Repeat All state did not show its native marker.");
        Require(ToolTipService.GetToolTip(parts["Title"]) as string == replacementTitle,
            "Replacing the full title did not update its native tooltip.");
        view.SetPlayback(state with { Repeat = "one", Title = replacementTitle });
        Require(repeatMarker.Visibility == Visibility.Visible
            && ReadProperty(repeatMarker, "Text") as string == "1",
            "Confirmed Repeat One state did not show its native marker.");
        view.SetPlayback(state with { Repeat = "off", Title = replacementTitle });
        Require(repeatMarker.Visibility == Visibility.Collapsed
            && ReadProperty(repeatMarker, "Text") as string == string.Empty,
            "Repeat Off state retained a stale native marker.");
        view.SetPlayback(null);
        Require(repeatMarker.Visibility == Visibility.Collapsed
            && ReadProperty(repeatMarker, "Text") as string == string.Empty
            && ToolTipService.GetToolTip(parts["Title"]) is null,
            "Unavailable Compact state retained repeat marker or title tooltip.");
        view.SetTimer(null);
        var unavailablePlayIcon = ReadProperty(parts["PlayPause"], "Content");
        var unavailableCloseIcon = ReadProperty(parts["Close"], "Content");
        for (var tick = 0; tick < 4; tick++)
        {
            view.SetPlayback(null);
            view.SetTimer(null);
        }
        Require(ReferenceEquals(unavailablePlayIcon, ReadProperty(parts["PlayPause"], "Content"))
            && ReferenceEquals(unavailableCloseIcon, ReadProperty(parts["Close"], "Content")),
            "Repeated unavailable compact binds replaced native visuals.");
        view.SetPlayback(state);

        phase = "automation-activation";
        FocusElement(parts["PlayPause"], "Compact Play/Pause");
        InvokeControl(parts["Previous"], "previous");
        InvokeControl(parts["PlayPause"], "play/pause");
        InvokeControl(parts["Next"], "next");
        Require(commands.Any(command => command.Command == "previous")
            && commands.Any(command => command.Command is "toggle" or "play" or "pause")
            && commands.Any(command => command.Command == "next"),
            "Native transport activation did not reach every Compact command boundary.");
        commands.Clear();
        phase = "seek-motion-and-cancel";
        var seek = parts["Seek"];
        var artwork = parts["Artwork"];
        var initialAngle = Convert.ToDouble(ReadProperty(artwork, "Angle") ?? 0d);
        BeginSeekGesture(seek);
        SetProperty(seek, "HorizontalDelta", 80d);
        RaiseEvent(seek, "DragPreview", 60d);
        var movedAngle = Convert.ToDouble(ReadProperty(artwork, "Angle") ?? initialAngle);
        Require(movedAngle != initialAngle, "Native seek preview did not update artwork motion.");
        SetField(seek, "_releaseExpected", false);
        var captureLost = FindMethod(seek, "DeferCaptureLossCancellation");
        Require(captureLost is not null, "Seek slider deferred capture-loss recovery was not retained.");
        captureLost!.Invoke(seek, null);
        Require(ReadProperty(seek, "Dragging") is true && ReadField(seek, "_releaseExpected") is true,
            "Capture loss canceled the seek before the pending release could be processed.");
        SetField(seek, "_releaseExpected", false);
        SetField(seek, "_dragging", false); // PointerReleased clears drag state before committing.
        RaiseEvent(seek, "DragCommitted", 60d);
        Require(commands.Count(command => command.Command == "seek" && command.Value == 60d) == 1,
            "Native seek release did not emit exactly one command at the selected timestamp.");
        await Task.Yield();
        Require(commands.Count(command => command.Command == "seek") == 1
            && ReadProperty(seek, "Dragging") is false,
            "Deferred capture-loss cancellation ran after the release commit.");
        view.SetPlayback(state with { Position = 11 });
        var staleSeekValue = Convert.ToDouble(ReadProperty(seek, "Value"));
        var staleSeekTime = ReadProperty(parts["Remaining"], "Text") as string;
        Require(Math.Abs(staleSeekValue - 500) <= 1 && staleSeekTime == "1:00",
            $"Stale player time replaced a just-committed seek target: slider={staleSeekValue}, remaining={staleSeekTime}.");
        view.SetPlayback(state with { Position = 60 });
        Require(Math.Abs(Convert.ToDouble(ReadProperty(seek, "Value")) - 500) <= 1,
            "Confirmed seek target did not remain at the requested timestamp.");
        view.SetPlayback(state with { Title = "Different synthetic track", Position = 10 });
        Require(Math.Abs(Convert.ToDouble(ReadProperty(seek, "Value")) - 83.33) <= 1,
            "A new track inherited the previous song's pending seek.");
        view.SetPlayback(state);
        commands.Clear();
        SetProperty(seek, "Value", 750d);
        RaiseEvent(seek, "KeyboardCommitted", 90d);
        Require(commands.Count(command => command.Command == "seek" && command.Value == 90d) == 1,
            "Keyboard seek did not emit exactly one command at the requested timestamp.");
        view.SetPlayback(state with { Position = 11 });
        Require(Math.Abs(Convert.ToDouble(ReadProperty(seek, "Value")) - 750) <= 1
            && ReadProperty(parts["Remaining"], "Text") as string == "0:30",
            "A stale player read replaced the keyboard seek target.");
        SetField(view, "_seekPendingUntil", DateTime.UtcNow.AddMilliseconds(-1));
        view.SetPlayback(state with { Position = 11 });
        Require(Math.Abs(Convert.ToDouble(ReadProperty(seek, "Value")) - 91.67) <= 1
            && ReadProperty(parts["Remaining"], "Text") as string == "1:49",
            "An expired seek target continued masking the bounded stale player read.");
        view.SetPlayback(state);

        commands.Clear();
        view.SetPreferences(reduceMotion: true, topmost: false);
        var reducedAngle = Convert.ToDouble(ReadProperty(artwork, "Angle") ?? 0d);
        BeginSeekGesture(seek);
        SetProperty(seek, "HorizontalDelta", 80d);
        RaiseEvent(seek, "DragPreview", 70d);
        Require(Convert.ToDouble(ReadProperty(artwork, "Angle") ?? reducedAngle) == reducedAngle,
            "Reduced-motion seek changed artwork angle.");
        var deferredCancel = FindMethod(seek, "DeferCaptureLossCancellation");
        Require(deferredCancel is not null, "Seek slider capture-loss fallback was not retained.");
        deferredCancel!.Invoke(seek, null);
        await Task.Delay(30);
        Require(commands.Count == 0 && ReadProperty(seek, "Dragging") is false,
            "Capture loss without a release did not cancel the seek on the next dispatcher turn.");
        view.SetPreferences(reduceMotion: false, topmost: false);

        phase = "output-volume";
        view.SetPlayerBusy(false);
        view.SetPlayback(state);
        var volumeButton = parts["Volume"] as Control
            ?? throw new SelfCheckException("Compact volume button was not a native Control.");
        var volumeSlider = FindOptionalPart(view, "VolumeSlider")
            ?? ReadField(view, "_volumeSlider") as FrameworkElement
            ?? throw new SelfCheckException("Compact volume slider was not created.");
        var nativeVolumeSlider = volumeSlider as Control
            ?? throw new SelfCheckException("Compact volume slider was not a native Control.");
        var volumePopup = ReadField(view, "_volumePopup") as FlyoutBase
            ?? throw new SelfCheckException("Compact volume popup was not created.");
        var volumeCommitTimer = ReadField(view, "_volumeCommitTimer")
            ?? throw new SelfCheckException("Compact volume commit timer was not created.");
        var hoverCloseTimer = ReadField(view, "_volumeHoverCloseTimer")
            ?? throw new SelfCheckException("Compact volume hover-close timer was not created.");
        var showVolumeOnHover = FindMethod(view, "ShowVolumePopupFromHover");
        var openVolume = FindMethod(view, "OpenVolumePopupForInteraction");
        Require(showVolumeOnHover is not null && openVolume is not null,
            "Native Compact output popup entry paths were not retained.");

        view.SetOutputVolume(0, false, false);
        Require(!volumeButton.IsEnabled && !nativeVolumeSlider.IsEnabled
            && AutomationProperties.GetHelpText(volumeSlider)?.Contains("unavailable", StringComparison.Ordinal) == true,
            "Unavailable output session left Compact volume controls enabled.");
        commands.Clear();
        showVolumeOnHover!.Invoke(view, null);
        openVolume!.Invoke(view, null);
        RaiseEvent(volumeSlider, "Committed", .65d);
        await Task.Delay(300);
        Require(commands.Count == 0 && !volumePopup.IsOpen
            && ReadProperty(volumeCommitTimer, "IsRunning") is false,
            "Unavailable output session dispatched a volume command or opened its popup.");

        view.SetPlayback(null);
        view.SetOutputVolume(.4, false, true);
        Require(volumeButton.IsEnabled && nativeVolumeSlider.IsEnabled
            && AutomationProperties.GetName(volumeButton) == "Mute app output"
            && Math.Abs(Convert.ToDouble(ReadProperty(volumeSlider, "Value")) - 400) <= 1,
            "Confirmed output session did not enable Compact volume independently of playback state.");
        InvokeControl(volumeButton, "Mute app output");
        Require(commands.Count(command => command.Command == "output-mute") == 1
            && !commands.Any(command => command.Command == "mute"),
            "Compact mute did not target app output exclusively.");
        commands.Clear();
        view.SetOutputVolume(.4, true, true);
        Require(AutomationProperties.GetName(volumeButton) == "Unmute app output",
            "Output mute state was not reflected by Compact accessibility.");
        await AwaitFlyoutOpenedAsync(volumePopup, () => openVolume.Invoke(view, null), "App output volume");
        RaiseEvent(volumeSlider, "Committed", .65d);
        Require(commands.Count(command => command.Command == "output-volume"
            && Math.Abs((command.Value ?? -1) - .65) < .001) == 1
            && !commands.Any(command => command.Command == "volume"),
            "Compact slider did not route normalized app output volume.");
        await AwaitFlyoutClosedAsync(volumePopup, () => volumePopup.Hide(), "App output volume");
        view.SetPlayback(state);
        phase = "status-menu-and-cleanup";
        var moreMenu = ReadField(view, "_moreMenu") as FlyoutBase;
        Require(moreMenu is not null, "Native More menu was not created.");
        await AwaitFlyoutOpenedAsync(moreMenu!, view.ShowMoreMenu, "More");
        var versionItem = ReadField(view, "_versionItem") as MenuFlyoutItem;
        Require(versionItem is not null && !versionItem.IsEnabled
            && versionItem.Text == AppVersion.DisplayName,
            "Compact More menu did not expose the noninteractive application version.");
        view.SetTimer(null);
        view.SetStatus("Synthetic error", isError: true);
        view.SetPreferences(reduceMotion: true, topmost: false);
        Require(!CompactPlayerView.ShouldAnimate(true, true, true, false, true),
            "Reduced-motion preference did not suspend Compact animation policy.");
        await AwaitFlyoutClosedAsync(moreMenu!, () => view.SetActive(false), "More");
        view.SetActive(true);

        phase = "unavailable-status-menu";
        var setHostStatus = FindMethod(host, "SetStatus");
        Require(setHostStatus is not null, "Native application status update hook was not retained.");
        setHostStatus!.Invoke(host, [string.Empty, false, false]);
        var invalidateCompactState = FindMethod(host, "InvalidateCompactState");
        Require(invalidateCompactState is not null,
            "Native Compact state invalidation hook was not retained.");
        invalidateCompactState!.Invoke(host, null);
        Require(host.IsCompact && ReadField(host, "_compactState") is null,
            "Unavailable Compact fixture did not clear the host-owned playback state.");
        var compactStatusItem = ReadField(view, "_statusItem") as MenuFlyoutItem;
        Require(compactStatusItem is not null && compactStatusItem.IsEnabled
            && AutomationProperties.GetHelpText(compactStatusItem)?.Contains(
                "does not identify a YouTube Music website error", StringComparison.Ordinal) == true,
            "Compact status menu was unavailable or misleading when playback state was missing.");
        var fullStatusItem = ReadField(host, "_statusDetailsItem") as MenuFlyoutItem;
        Require(fullStatusItem is not null && fullStatusItem.IsEnabled,
            "Full application status menu remained disabled without a reported message.");
        await AwaitFlyoutOpenedAsync(moreMenu!, view.ShowMoreMenu, "More with unavailable player");
        Require(compactStatusItem!.IsEnabled,
            "Compact More menu did not expose application status while the player was unavailable.");
        await AwaitFlyoutClosedAsync(moreMenu!, () => moreMenu!.Hide(), "More with unavailable player");
        var statusDetails = await ReadStatusDetailsAsync(host);
        Require(statusDetails.Contains("Compact playback state: unavailable", StringComparison.Ordinal)
            && statusDetails.Contains("does not identify a YouTube Music website error", StringComparison.Ordinal),
            "Application status details did not truthfully explain the unavailable Compact state.");
        Require(parts["PlayPause"] is Control playPauseControl && !playPauseControl.IsEnabled
            && AutomationProperties.GetName(playPauseControl)?.Contains("unavailable",
                StringComparison.OrdinalIgnoreCase) == true,
            "Unavailable Compact state left stale playback affordances enabled.");
        view.SetPlayback(state);

        phase = "return-to-full";
        var compactHandle = host.NativeHandle;
        InvokeControl(parts["ReturnToFull"], "return to full");
        await Task.Yield();
        Require(!host.IsCompact && host.NativeHandle == compactHandle,
            "Compact Return to full activation did not restore the same native presenter.");
        CheckCaptionlessRegionsCleared(host);
        var startHoverCloseTimer = FindMethod(hoverCloseTimer!, "Start");
        Require(startHoverCloseTimer is not null,
            "Native volume hover-close timer could not be restarted for disposal cleanup.");
        startHoverCloseTimer!.Invoke(hoverCloseTimer, null);
        Require(ReadProperty(hoverCloseTimer!, "IsRunning") is true,
            "Native volume hover-close timer did not start before disposal.");
        view.Dispose();
        view.Dispose();
        Require(!volumePopup!.IsOpen && ReadProperty(hoverCloseTimer!, "IsRunning") is false,
            "Disposing Compact left the volume popup or hover-close timer active.");
        }
        catch (Exception exception)
        {
            var baseException = exception.GetBaseException();
            Console.Error.WriteLine(
                $"Compact native check phase '{phase}' failed: {baseException.GetType().Name}: {baseException.Message}");
            throw;
        }
    }

    private static void CheckCompactNativeFrame(
        WebHostWindow host, CompactPlayerView view)
    {
        var dpi = GetDpiForWindow(host.NativeHandle);
        if (dpi == 0) dpi = 96;
        var scale = dpi / 96d;
        var client = default(NativeRect);
        Require(host.NativeHandle != 0 && GetClientRect(host.NativeHandle, ref client),
            "Windows did not provide the Compact client bounds.");
        var clientWidth = client.Right - client.Left;
        var clientHeight = client.Bottom - client.Top;
        Require(clientWidth >= Math.Round(CompactPlayerView.LogicalMinimumWidthValue * scale) - 1
            && Math.Abs(clientHeight - CompactPlayerView.LogicalMinimumHeightValue * scale) <= 1,
            "Compact native client stopped honoring its minimum width or fixed 180-DIP height.");
        Prepare(view, clientWidth / scale, clientHeight / scale);

        var source = InputNonClientPointerSource.GetForWindowId(
            Win32Interop.GetWindowIdFromWindow(host.NativeHandle));
        var caption = source.GetRegionRects(NonClientRegionKind.Caption);
        Require(caption.Length > 0,
            "Compact native Caption drag region was missing.");
        Require(CaptionContainsDip(caption, 320, 32, scale)
            && CaptionContainsDip(caption, 80, 154, scale),
            "Compact Caption did not cover its safe header and left-side drag points.");
        Require(!CaptionContainsDip(caption, 660, 30, scale)
            && !CaptionContainsDip(caption, 320, 140, scale),
            "Compact Caption intercepted Return to full or the seek control.");

        foreach (var border in new[]
        {
            NonClientRegionKind.TopBorder, NonClientRegionKind.LeftBorder,
            NonClientRegionKind.BottomBorder, NonClientRegionKind.RightBorder
        })
        {
            var borderRects = source.GetRegionRects(border);
            Require(borderRects.Length > 0,
                $"Compact native resize region was missing: {border}.");
            Require(!caption.Any(captionRect => borderRects.Any(
                    borderRect => RectanglesOverlap(captionRect, borderRect))),
                $"Compact Caption overlapped native resize region: {border}.");
        }

        var presenter = ReadField(host, "_presenter");
        Require(host.IsCompact && presenter is not null
            && ReadProperty(presenter, "IsMaximizable") is false,
            "Compact presenter was missing or remained maximizable.");

        var window = default(NativeRect);
        Require(GetWindowRect(host.NativeHandle, ref window),
            "Windows did not provide the Compact window bounds for resize hit testing.");
        var resizePoint = PackScreenPoint(window.Left + 1, (window.Top + window.Bottom) / 2);
        Require(NativeWindowServices.TryHandleCaptionlessResizeFrame(
                host.NativeHandle, WmNcHitTest, 0, resizePoint, out var resizeHit)
            && resizeHit.ToInt32() == HtLeft,
            "Compact left resize border did not retain native resize hit testing.");
    }

    private static bool CaptionContainsDip(
        Windows.Graphics.RectInt32[] regions, double xDip, double yDip, double scale)
    {
        var x = Math.Round(xDip * scale, MidpointRounding.AwayFromZero);
        var y = Math.Round(yDip * scale, MidpointRounding.AwayFromZero);
        return regions.Any(region => x >= region.X && x < region.X + region.Width
            && y >= region.Y && y < region.Y + region.Height);
    }

    private static bool RectanglesOverlap(
        Windows.Graphics.RectInt32 first, Windows.Graphics.RectInt32 second)
        => first.X < second.X + second.Width && first.X + first.Width > second.X
            && first.Y < second.Y + second.Height && first.Y + first.Height > second.Y;




    private static nint PackScreenPoint(int x, int y)
    {
        var packed = (uint)unchecked((ushort)(short)x)
            | ((uint)unchecked((ushort)(short)y) << 16);
        return unchecked((nint)packed);
    }

    private static void CheckCaptionlessRegionsCleared(WebHostWindow host)
    {
        var services = ReadField(host, "_nativeWindowServices");
        Require(services is not null
            && ReadField(services, "_captionlessResizeFrame") is false
            && ReadField(services, "_nonClientPointerSource") is null,
            "Returning to full mode retained Compact-owned native resize-frame or pointer-source state.");

        var presenter = ReadField(host, "_presenter");
        Require(presenter is not null
            && ReadProperty(presenter, "HasBorder") is true
            && ReadProperty(presenter, "HasTitleBar") is true
            && ReadProperty(presenter, "IsMaximizable") is true,
            "Returning to full mode did not restore the system frame and maximizable presenter.");
    }

    private static async Task<string> ReadStatusDetailsAsync(WebHostWindow host)
    {
        var showStatusDetails = FindMethod(host, "ShowStatusDetails");
        Require(showStatusDetails is not null, "Native status details action was not retained.");
        showStatusDetails!.Invoke(host, null);
        await Task.Yield();

        var dialogs = ReadField(host, "_ownedDialogs") as IEnumerable<Window>;
        var dialog = dialogs?.FirstOrDefault(window => window.Title == "Application status");
        Require(dialog?.Content is DependencyObject,
            "Application status action did not present a native details window.");
        try
        {
            var body = FindDescendant<TextBox>((DependencyObject)dialog!.Content)
                ?? throw new SelfCheckException("Application status details did not expose its text.");
            return body.Text;
        }
        finally
        {
            dialog!.Close();
            await Task.Yield();
        }
    }



    [StructLayout(LayoutKind.Sequential)]
    private struct NativeRect { public int Left, Top, Right, Bottom; }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetClientRect(nint window, ref NativeRect rect);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool GetWindowRect(nint window, ref NativeRect rect);


    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint window);

    private static void Prepare(FrameworkElement element, double width = 1200, double height = 800)
    {
        element.Measure(new FoundationSize(width, height));
        element.Arrange(new FoundationRect(0, 0, width, height));
        element.UpdateLayout();
        Require(element.ActualWidth > 0 && element.ActualHeight > 0,
            "Compact XAML element did not receive a usable layout.");
    }

    private static FrameworkElement FindPart(FrameworkElement root, string name)
        => FindPartCore(root, name)
            ?? throw new SelfCheckException($"Compact XAML part was not found: {name}.");

    private static FrameworkElement? FindOptionalPart(FrameworkElement root, string name)
        => FindPartCore(root, name);

    private static FrameworkElement? FindPartCore(FrameworkElement root, string name)
    {
        if (root.Name == name)
            return root;
        if (root.FindName(name) is FrameworkElement direct)
            return direct;
        foreach (var child in Descendants(root))
        {
            if (child.Name == name)
                return child;
            if (child.FindName(name) is FrameworkElement nested)
                return nested;
        }
        return null;
    }

    private static T? FindDescendant<T>(DependencyObject root) where T : DependencyObject
    {
        if (root is T match)
            return match;
        foreach (var child in Descendants(root))
        {
            if (child is T typed)
                return typed;
        }
        return null;
    }

    private static IEnumerable<FrameworkElement> Descendants(DependencyObject root)
    {
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var index = 0; index < count; index++)
        {
            if (VisualTreeHelper.GetChild(root, index) is FrameworkElement child)
            {
                yield return child;
                foreach (var descendant in Descendants(child))
                    yield return descendant;
            }
        }
    }

    private static void FocusElement(FrameworkElement element, string description)
    {
        Require(element.Focus(FocusState.Programmatic), $"{description} could not receive keyboard focus.");
        Require(AutomationProperties.GetName(element) is { Length: > 0 },
            $"{description} has no automation name after focus.");
    }

    private static void InvokeControl(FrameworkElement element, string description)
    {
        Require(element is Control control && control.IsEnabled,
            $"{description} is not enabled for native activation.");
        var peer = FrameworkElementAutomationPeer.CreatePeerForElement(element);
        Require(peer is not null, $"{description} has no automation peer.");
        var invoke = peer!.GetPattern(PatternInterface.Invoke) as IInvokeProvider;
        Require(invoke is not null, $"{description} has no native Invoke pattern.");
        invoke!.Invoke();
    }

    private static void InvokeOptional(FrameworkElement element, string methodName)
    {
        FindMethod(element, methodName)?.Invoke(element, null);
    }
    private static async Task AwaitFlyoutOpenedAsync(
        FlyoutBase flyout, Action open, string phase)
    {
        var completed = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        EventHandler<object> handler = (_, _) => completed.TrySetResult(true);
        flyout.Opened += handler;
        try
        {
            open();
            await completed.Task.WaitAsync(TimeSpan.FromSeconds(2));
            Require(flyout.IsOpen, $"Native {phase} flyout reported Opened before becoming open.");
        }
        catch (TimeoutException)
        {
            throw new SelfCheckException($"Native {phase} flyout did not report Opened.");
        }
        finally { flyout.Opened -= handler; }
    }

    private static async Task AwaitFlyoutClosedAsync(
        FlyoutBase flyout, Action close, string phase)
    {
        if (!flyout.IsOpen) return;
        var completed = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        EventHandler<object> handler = (_, _) => completed.TrySetResult(true);
        flyout.Closed += handler;
        try
        {
            close();
            await completed.Task.WaitAsync(TimeSpan.FromSeconds(2));
            Require(!flyout.IsOpen, $"Native {phase} flyout reported Closed while still open.");
        }
        catch (TimeoutException)
        {
            throw new SelfCheckException($"Native {phase} flyout did not report Closed.");
        }
        finally { flyout.Closed -= handler; }
    }


    private static void BeginSeekGesture(FrameworkElement seek)
    {
        RaiseEvent(seek, "DragStarted");
        SetField(seek, "_dragging", true);
    }

    private static void RaiseEvent(object instance, string eventName, params object?[] args)
    {
        var field = instance.GetType().GetField(eventName, BindingFlags.Instance | BindingFlags.NonPublic)
            ?? instance.GetType().GetField($"<{eventName}>k__BackingField",
                BindingFlags.Instance | BindingFlags.NonPublic);
        Require(field?.GetValue(instance) is Delegate,
            $"Native control event was not wired: {eventName}.");
        ((Delegate)field!.GetValue(instance)!).DynamicInvoke(args);
    }

    private static void SetProperty(object instance, string name, object value)
    {
        var property = instance.GetType().GetProperty(name,
            BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);
        Require(property is not null && property.CanWrite,
            $"Native control property was not writable: {name}.");
        property!.SetValue(instance, value);
    }
    private static void SetField(object instance, string name, object? value)
    {
        var field = instance.GetType().GetField(name,
            BindingFlags.Instance | BindingFlags.NonPublic);
        Require(field is not null, $"Native control field was not found: {name}.");
        field!.SetValue(instance, value);
    }

    private static object? ReadField(object instance, string name)
        => instance.GetType().GetField(name, BindingFlags.Instance | BindingFlags.NonPublic)?.GetValue(instance);

    private static MethodInfo? FindMethod(object instance, string name)
        => instance.GetType().GetMethod(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic);

    private static object? ReadProperty(object instance, string name)
        => instance.GetType().GetProperty(name, BindingFlags.Instance | BindingFlags.Public | BindingFlags.NonPublic)
            ?.GetValue(instance);

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new SelfCheckException(message);
    }
}
