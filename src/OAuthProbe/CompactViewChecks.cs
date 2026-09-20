using System.Drawing;
using System.Reflection;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Media;
using FoundationRect = Windows.Foundation.Rect;
using FoundationSize = Windows.Foundation.Size;

namespace OAuthProbe;

internal static class CompactViewChecks
{
    private static readonly string[] RequiredParts =
    {
        "Artwork", "Title", "InlineStatus", "Remaining", "Duration", "Seek",
        "Previous", "PlayPause", "Next", "Like", "Dislike", "Repeat", "Shuffle",
        "Volume", "Timer", "ReturnToFull", "More", "Minimize", "Close"
    };

    internal static void Run()
    {
        Require(CompactPlayerView.LogicalMinimumWidthValue == 800
            && CompactPlayerView.LogicalMinimumHeightValue == 180
            && CompactPlayerView.LogicalMinimumSize == new Size(800, 180),
            "Compact player minimum logical size changed.");

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

        phase = "compact-layout";
        var view = root as CompactPlayerView ?? FindDescendant<CompactPlayerView>(root)
            ?? throw new SelfCheckException("Compact presenter did not load CompactPlayerView.");
        Prepare(view);
        Require(view.ActualWidth >= CompactPlayerView.LogicalMinimumWidthValue
            && view.ActualHeight >= CompactPlayerView.LogicalMinimumHeightValue,
            "Compact presenter did not honor its 800 by 180 DIP minimum.");

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

        phase = "playback-state";
        var state = new CompactPlaybackState(
            "Synthetic compact title", null, Paused: false, Position: 10, Duration: 120,
            Volume: 0.5, Muted: false, Liked: true, Disliked: false, Repeat: "off",
            CanSeek: true, CanVolume: true, CanLike: true, CanDislike: true,
            CanRepeat: true, CanShuffle: true);
        var commands = new List<(string Command, double? Value)>();
        view.CommandRequested += (command, value) => commands.Add((command, value));
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

        view.SetPlayback(state with { Paused = true, Muted = true, Repeat = "one" });
        var changedPlayIcon = ReadProperty(parts["PlayPause"], "Content");
        var changedVolumeIcon = ReadProperty(parts["Volume"], "Content");
        var changedRepeatIcon = ReadProperty(FindPart(view, "RepeatIcon"), "Content");
        Require(!ReferenceEquals(playIcon, changedPlayIcon)
            && !ReferenceEquals(volumeIcon, changedVolumeIcon)
            && !ReferenceEquals(repeatIcon, changedRepeatIcon),
            "Changed compact playback glyphs did not replace their native visuals.");
        view.SetPlayback(state with { Paused = true, Muted = true, Repeat = "one" });
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
        InvokeControl(parts["PlayPause"], "play/pause");
        Require(commands.Any(command => command.Command is "toggle" or "play" or "pause"),
            "Native Play/Pause activation did not reach the Compact command boundary.");
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
        RaiseEvent(seek, "DragCommitted", 60d);
        Require(commands.Any(command => command.Command == "seek"),
            "Native seek gesture did not reach the Compact command boundary.");

        commands.Clear();
        view.SetPreferences(reduceMotion: true, topmost: false);
        var reducedAngle = Convert.ToDouble(ReadProperty(artwork, "Angle") ?? 0d);
        BeginSeekGesture(seek);
        SetProperty(seek, "HorizontalDelta", 80d);
        RaiseEvent(seek, "DragPreview", 70d);
        Require(Convert.ToDouble(ReadProperty(artwork, "Angle") ?? reducedAngle) == reducedAngle,
            "Reduced-motion seek changed artwork angle.");
        InvokeOptional(seek, "CancelDrag");
        Require(commands.Count == 0, "Cancelled native seek emitted a stale command.");
        view.SetPreferences(reduceMotion: false, topmost: false);

        phase = "volume-gesture";
        commands.Clear();
        var showVolume = FindMethod(view, "ShowVolumePopup");
        Require(showVolume is not null, "Native volume popup activation was not retained.");
        var volumePopup = ReadField(view, "_volumePopup") as FlyoutBase;
        Require(volumePopup is not null, "Native volume popup was not created.");
        await AwaitFlyoutOpenedAsync(volumePopup!, () => showVolume!.Invoke(view, null), "volume");
        var volumeSlider = FindOptionalPart(view, "VolumeSlider")
            ?? ReadField(view, "_volumeSlider") as FrameworkElement;
        Require(volumeSlider is not null, "Native volume slider was not created.");
        SetProperty(volumeSlider!, "Value", 75d);
        RaiseEvent(volumeSlider!, "Committed", 0.75d);
        Require(commands.Any(command => command.Command == "volume"),
            "Native volume gesture did not reach the Compact command boundary.");
        await AwaitFlyoutClosedAsync(volumePopup!, volumePopup!.Hide, "volume");

        phase = "status-menu-and-cleanup";
        var moreMenu = ReadField(view, "_moreMenu") as FlyoutBase;
        Require(moreMenu is not null, "Native More menu was not created.");
        await AwaitFlyoutOpenedAsync(moreMenu!, view.ShowMoreMenu, "More");
        view.SetTimer(null);
        view.SetStatus("Synthetic error", isError: true);
        view.SetPreferences(reduceMotion: true, topmost: false);
        Require(!CompactPlayerView.ShouldAnimate(true, true, true, false, true),
            "Reduced-motion preference did not suspend Compact animation policy.");
        await AwaitFlyoutClosedAsync(moreMenu!, () => view.SetActive(false), "More");
        view.SetActive(true);

        view.SetPlayback(null);
        Require(parts["PlayPause"] is Control playPauseControl && !playPauseControl.IsEnabled
            && AutomationProperties.GetName(playPauseControl)?.Contains("unavailable",
                StringComparison.OrdinalIgnoreCase) == true,
            "Unavailable Compact state left stale playback affordances enabled.");
        view.SetPlayback(state);
        view.Dispose();
        view.Dispose();
        }
        catch (Exception exception)
        {
            var baseException = exception.GetBaseException();
            Console.Error.WriteLine(
                $"Compact native check phase '{phase}' failed: {baseException.GetType().Name}: {baseException.Message}");
            throw;
        }
    }

    private static void Prepare(FrameworkElement element)
    {
        element.Measure(new FoundationSize(1200, 800));
        element.Arrange(new FoundationRect(0, 0, 1200, 800));
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
    private static void SetField(object instance, string name, object value)
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
