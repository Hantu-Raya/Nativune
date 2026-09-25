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
        "Artwork", "Title", "InlineStatus", "Elapsed", "Duration", "Seek", "SeekProgress",
        "Previous", "PlayPause", "Next", "Like", "Dislike", "Repeat", "Shuffle",
        "Volume", "Timer", "ReturnToFull", "More", "Minimize", "Close"
    };
    private const uint WmNcHitTest = 0x0084;
    private const int HtLeft = 10;

    internal static void Run()
    {
        Require(CompactPlayerView.LogicalMinimumWidthValue == 360
            && CompactPlayerView.LogicalMinimumHeightValue == 56
            && CompactPlayerView.LogicalMinimumSize == new Size(360, 56),
            "Compact player minimum logical size changed.");
        CheckLayoutPlans();

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

    private static readonly (double Width, double Height, CompactSizeClass SizeClass)[] LayoutSamples =
    {
        (360, 56, CompactSizeClass.Strip), (440, 56, CompactSizeClass.Strip), (800, 64, CompactSizeClass.Strip),
        (1400, 80, CompactSizeClass.Strip), (360, 92, CompactSizeClass.Strip),
        (360, 96, CompactSizeClass.Compact), (420, 108, CompactSizeClass.Compact), (640, 120, CompactSizeClass.Compact),
        (800, 128, CompactSizeClass.Compact), (1200, 140, CompactSizeClass.Compact),
        (360, 144, CompactSizeClass.Standard), (400, 160, CompactSizeClass.Standard), (520, 180, CompactSizeClass.Standard),
        (800, 180, CompactSizeClass.Standard), (800, 220, CompactSizeClass.Standard), (1000, 260, CompactSizeClass.Standard),
        (1100, 180, CompactSizeClass.Wide), (1600, 240, CompactSizeClass.Wide),
        (360, 300, CompactSizeClass.Tall), (400, 400, CompactSizeClass.Tall), (640, 300, CompactSizeClass.Tall),
        (800, 600, CompactSizeClass.Tall), (1000, 1000, CompactSizeClass.Tall)
    };
    private static readonly double[] LayoutScales = { 1, 1.25, 1.5, 1.75, 2 };

    /// <summary>
    /// Pure geometry contract for every size class at 100–200 % scale: controls stay inside the client,
    /// never overlap, keep 32-DIP hit targets, land on device pixels, and the drag (caption) regions
    /// never cover an interactive control while still offering a usable drag area.
    /// </summary>
    private static void CheckLayoutPlans()
    {
        foreach (var (width, height, expectedClass) in LayoutSamples)
        foreach (var scale in LayoutScales)
        foreach (var statusVisible in new[] { false, true })
        {
            var label = $"{width}x{height}@{scale:0.00}{(statusVisible ? "+status" : "")}";
            var plan = CompactPlayerView.PlanLayout(width, height, scale, statusVisible);
            Require(plan.SizeClass == expectedClass,
                $"Compact {label} resolved to {plan.SizeClass} instead of {expectedClass}.");
            var interactive = plan.InteractiveRects().ToList();
            foreach (var (name, rect) in interactive)
            {
                Require(rect.X >= -0.001 && rect.Y >= -0.001 && rect.Right <= width + 0.001 && rect.Bottom <= height + 0.001,
                    $"Compact {label}: {name} left the client area ({rect}).");
                Require(rect.Width >= 32 && rect.Height >= 32,
                    $"Compact {label}: {name} is smaller than a 32-DIP hit target ({rect}).");
                RequireSnapped(rect, scale, $"{label}: {name}");
            }
            for (var first = 0; first < interactive.Count; first++)
                for (var second = first + 1; second < interactive.Count; second++)
                    Require(!interactive[first].Rect.Overlaps(interactive[second].Rect),
                        $"Compact {label}: {interactive[first].Name} overlaps {interactive[second].Name}.");
            foreach (var (name, rect) in new[] { ("Artwork", plan.Artwork), ("Title", plan.Title), ("Status", plan.Status) })
            {
                if (rect is not { } passive) continue;
                Require(passive.X >= -0.001 && passive.Y >= -0.001 && passive.Right <= width + 0.001
                    && passive.Bottom <= height + 0.001, $"Compact {label}: {name} left the client area.");
                RequireSnapped(passive, scale, $"{label}: {name}");
                foreach (var (other, otherRect) in interactive)
                    Require(!passive.Overlaps(otherRect), $"Compact {label}: {name} overlaps {other}.");
            }
            Require(plan.Title is { } title && plan.Status is { } status
                && Math.Abs(status.X - title.X) < 0.001 && Math.Abs(status.Width - title.Width) < 0.001
                && Math.Abs(status.Height - 16) < 0.5 && status.Y >= title.Y
                && (statusVisible
                    ? Math.Abs(status.Y - title.Bottom) < 0.001
                    : status.Bottom - title.Y >= 40 - 0.5 && status.Bottom - title.Y <= 48 + 0.5),
                $"Compact {label}: InlineStatus is not one line directly under the title at the title width.");
            Require(plan.Progress is null && plan.SizeClass == CompactSizeClass.Strip
                || plan.Progress is { } progressRect && Math.Abs(progressRect.Height - 40) < 0.01 && progressRect.Width >= 119,
                $"Compact {label}: progress row is missing or too small.");
            Require(!plan.ProgressShowsTimes || plan.Progress is { Width: >= 187 },
                $"Compact {label}: timestamps shown without room for them.");
            Require(!plan.TimerShowsText || plan.Timer is { Width: >= 147 },
                $"Compact {label}: timer label shown without room for it.");
            foreach (var control in Enum.GetValues<CompactOverflowControl>())
            {
                LayoutRect? rect = control switch
                {
                    CompactOverflowControl.Like => plan.Like,
                    CompactOverflowControl.Dislike => plan.Dislike,
                    CompactOverflowControl.Playlists => plan.Playlists,
                    CompactOverflowControl.Repeat => plan.Repeat,
                    CompactOverflowControl.Shuffle => plan.Shuffle,
                    CompactOverflowControl.Volume => plan.Volume,
                    CompactOverflowControl.Timer => plan.Timer,
                    _ => plan.Minimize
                };
                Require(rect.HasValue != plan.Overflow.Contains(control),
                    $"Compact {label}: {control} is neither shown nor offered in the More menu (or both).");
            }

            Require(plan.CaptionRegions.Count > 0 && plan.CaptionRegions.Any(region => region.Width >= 24 && region.Height >= 24),
                $"Compact {label}: no usable drag region.");
            foreach (var region in plan.CaptionRegions)
            {
                Require(region.X >= -0.001 && region.Y >= -0.001 && region.Right <= width + 0.001 && region.Bottom <= height + 0.001,
                    $"Compact {label}: drag region left the client area.");
                foreach (var (name, rect) in interactive)
                    Require(!region.Overlaps(rect), $"Compact {label}: drag region covers {name}.");
            }
            var dpi = (uint)Math.Round(96 * scale);
            var pixelWidth = (int)Math.Round(width * scale);
            var pixelHeight = (int)Math.Round(height * scale);
            var nativeCaption = NativeWindowServices.CompactCaptionRegions(pixelWidth, pixelHeight, dpi);
            Require(nativeCaption.Count == plan.CaptionRegions.Count,
                $"Compact {label}: native drag regions did not follow the layout plan.");
            foreach (var region in nativeCaption)
            {
                Require(region.X >= 0 && region.Y >= 0 && region.X + region.Width <= pixelWidth
                    && region.Y + region.Height <= pixelHeight,
                    $"Compact {label}: native drag region left the client pixels.");
                foreach (var (name, rect) in interactive)
                {
                    var pixelRect = new LayoutRect(
                        Math.Round(rect.X * scale), Math.Round(rect.Y * scale),
                        Math.Round(rect.Right * scale) - Math.Round(rect.X * scale),
                        Math.Round(rect.Bottom * scale) - Math.Round(rect.Y * scale));
                    Require(!pixelRect.Overlaps(new LayoutRect(region.X, region.Y, region.Width, region.Height)),
                        $"Compact {label}: native drag region covers {name}.");
                }
            }
        }

        var standard = CompactPlayerView.PlanLayout(800, 180, 1, statusVisible: false);
        Require(standard.Artwork is { Width: 112, Height: 112 } && standard.Like is { X: 312 } && standard.Dislike is { X: 356 }
            && standard.Playlists is { X: 400 } && standard.Repeat is { X: 444 } && standard.Shuffle is { X: 488 }
            && standard.Volume is { X: 532 } && standard.Timer is { X: 588, Width: 148 } && standard.TimerShowsText
            && standard.Minimize is not null && standard.Overflow.Count == 0 && standard.ProgressShowsTimes
            && standard.Previous.X == 152 && standard.Progress is { X: 152 },
            "The 800x180 Standard layout no longer shows the full control set at its agreed positions with the 112-DIP artwork column.");
        var narrow = CompactPlayerView.PlanLayout(360, 180, 1, statusVisible: false);
        Require(narrow.Like is not null && narrow.Volume is not null && narrow.Playlists is null && narrow.Repeat is null
            && narrow.Timer is null
            && narrow.Overflow.SequenceEqual(new[]
            {
                CompactOverflowControl.Playlists, CompactOverflowControl.Repeat, CompactOverflowControl.Shuffle,
                CompactOverflowControl.Timer
            }),
            "The narrow Standard layout did not move Playlists/Repeat/Shuffle/Timer into the More menu in priority order.");
        var strip = CompactPlayerView.PlanLayout(360, 56, 1, statusVisible: false);
        Require(strip.Title is not null && strip.Progress is null && strip.Artwork is null && strip.Minimize is null
            && strip.Overflow.Contains(CompactOverflowControl.Minimize),
            "The minimum Strip layout did not keep a title drag handle with Minimize in the More menu.");
        var wideStrip = CompactPlayerView.PlanLayout(1400, 80, 1, statusVisible: false);
        Require(wideStrip.Artwork is not null && wideStrip.Progress is not null && wideStrip.ProgressShowsTimes
            && wideStrip.Like is not null && wideStrip.Timer is not null,
            "A wide Strip did not reveal artwork, timestamps and secondary actions.");
        var wide = CompactPlayerView.PlanLayout(1600, 240, 1, statusVisible: false);
        Require(wide.Timer is { } wideTimer && Math.Abs(wideTimer.Right - (1600 - 12)) < 0.001
            && wide.Like is { } wideLike && wideLike.X > wide.Next.Right + 100,
            "The Wide layout did not right-align the secondary actions.");
        var tall = CompactPlayerView.PlanLayout(400, 400, 1, statusVisible: false);
        Require(tall.Artwork is { Width: >= 120 } tallArtwork && Math.Abs(tallArtwork.X + tallArtwork.Width / 2 - 200) < 1
            && tall.Title is { } tallTitle && tallTitle.Y > tallArtwork.Bottom
            && tall.PlayPause.Y > tallTitle.Bottom && tall.Progress is { } tallProgress && tallProgress.Y > tall.PlayPause.Bottom,
            "The Tall layout did not stack centered artwork above title, controls and seek.");
    }

    private static void RequireSnapped(LayoutRect rect, double scale, string label)
    {
        foreach (var edge in new[] { rect.X, rect.Y, rect.Right, rect.Bottom })
            Require(Math.Abs(edge * scale - Math.Round(edge * scale)) < 0.001,
                $"Compact {label} edge {edge} is not on the {scale:0.00}x pixel grid.");
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
            "Compact presenter did not honor its 360 by 56 DIP minimum.");

        phase = "queued-output-without-session";
        var updateOutput = FindMethod(host, "UpdateOutputAudioControls")
            ?? throw new SelfCheckException("Native output state update hook was not retained.");
        SetField(host, "_outputAudioExecutablePath", Path.Combine(AppContext.BaseDirectory, "msedgewebview2.exe"));
        SetField(host, "_outputAudioPathVerified", true); // Fixture bypasses process discovery, not production.
        updateOutput.Invoke(host, null);
        var compactOutput = FindPart(view, "Volume") as Control;
        Require(fullMute is { IsEnabled: true } && fullVolume is { IsEnabled: true }
            && compactOutput?.IsEnabled == true
            && AutomationProperties.GetHelpText(fullMute)?.Contains("pending preference", StringComparison.Ordinal) == true
            && AutomationProperties.GetHelpText(compactOutput)?.Contains("pending", StringComparison.Ordinal) == true,
            "Initialized WebView output was disabled or claimed an active audio session while paused.");
        SetField(host, "_outputAudioExecutablePath", null);
        SetField(host, "_outputAudioPathVerified", false);
        updateOutput.Invoke(host, null);
        Require(fullMute?.IsEnabled == false && fullVolume?.IsEnabled == false
            && compactOutput?.IsEnabled == false,
            "Uninitialized WebView output did not return to its disabled state.");

        phase = "named-parts";
        var parts = RequiredParts.ToDictionary(name => name, name => FindPart(view, name),
            StringComparer.Ordinal);
        foreach (var part in parts)
        {
            var optionalStatus = part.Key is "InlineStatus" or "SeekProgress";
            Require((optionalStatus || part.Value.Visibility == Visibility.Visible)
                && (optionalStatus || part.Value.ActualWidth > 0 && part.Value.ActualHeight > 0),
                $"Compact part {part.Key} was not laid out at the native minimum.");
            Require(!string.IsNullOrWhiteSpace(AutomationProperties.GetName(part.Value)),
                $"Compact part {part.Key} lost its automation name.");
        }
        phase = "compact-native-frame";
        CheckCompactNativeFrame(host, view);

        phase = "size-classes";
        CheckNativeSizeClasses(view, parts);
        Prepare(view);

        phase = "marquee-narrow";
        view.SetPlayback(new CompactPlaybackState(
            "Synthetic marquee title that is definitely wider than a narrow Compact title slot", null,
            Paused: true, Position: 0, Duration: 100, Liked: false, Disliked: false, Repeat: "off",
            CanSeek: true, CanLike: true, CanDislike: true, CanRepeat: true, CanShuffle: true, Shuffle: false,
            VideoId: "AbCdEfGhI01", ClockConfirmed: true));
        view.SetPreferences(reduceMotion: false, topmost: false);
        PrepareViewSize(view, 400, 180);
        var marquee = parts["Title"];
        var primaryCopy = ReadField(marquee, "_primary") as TextBlock
            ?? throw new SelfCheckException("Compact title marquee did not expose its primary copy.");
        var secondaryCopy = ReadField(marquee, "_secondary") as TextBlock
            ?? throw new SelfCheckException("Compact title marquee did not expose its secondary copy.");
        var textWidth = Convert.ToDouble(ReadField(marquee, "_textWidth"));
        Require(ReadField(marquee, "_overflow") is true && textWidth > marquee.ActualWidth,
            $"A long title did not overflow the narrow 400-DIP title slot (text={textWidth}, slot={marquee.ActualWidth}).");
        var primaryBounds = primaryCopy.TransformToVisual(marquee).TransformBounds(
            new FoundationRect(0, 0, primaryCopy.ActualWidth, primaryCopy.ActualHeight));
        Require(Math.Abs(primaryBounds.Left) <= 0.5 && primaryBounds.Width >= textWidth - 2
            && primaryCopy.TextTrimming == TextTrimming.None && secondaryCopy.Visibility == Visibility.Visible,
            $"The scrolling title copy was centered or trimmed by its slot instead of laid out from the left at its natural width (left={primaryBounds.Left}, width={primaryBounds.Width}, text={textWidth}).");
        view.SetPreferences(reduceMotion: true, topmost: false);
        view.UpdateLayout();
        Require(primaryCopy.TextTrimming == TextTrimming.CharacterEllipsis
            && primaryCopy.ActualWidth <= marquee.ActualWidth + 0.5 && secondaryCopy.Visibility == Visibility.Collapsed,
            "The reduced-motion title did not fall back to an ellipsis within its slot.");
        view.SetPreferences(reduceMotion: false, topmost: false);
        view.SetPlayback(null);
        ReleaseViewSize(view);
        Prepare(view);

        phase = "playback-state";
        var state = new CompactPlaybackState(
            "Synthetic compact title", null, Paused: false, Position: 10, Duration: 120,
            Liked: true, Disliked: false, Repeat: "off",
            CanSeek: true, CanLike: true, CanDislike: true,
            CanRepeat: true, CanShuffle: true, Shuffle: true,
            VideoId: "AbCdEfGhI01", ClockConfirmed: true);
        var commands = new List<(string Command, double? Value)>();
        view.CommandRequested += (command, value) => commands.Add((command, value));
        view.SetOutputVolume(.5, false, true);
        view.SetPlayback(state);
        view.SetArtwork(null);
        view.SetStatus("Synthetic status", isError: false);
        view.SetTimer(TimeSpan.FromMinutes(14));
        view.SetPreferences(reduceMotion: false, topmost: false);
        Prepare(view);
        Require(parts["InlineStatus"].Visibility == Visibility.Collapsed
            && AutomationProperties.GetHelpText(parts["More"])?.Contains(
                "Synthetic status", StringComparison.Ordinal) == true,
            "Routine Compact status remained as debug text or disappeared from More.");

        Require(AutomationProperties.GetName(parts["PlayPause"])?.Contains("Pause",
                StringComparison.OrdinalIgnoreCase) == true,
            "Playing Compact state did not expose the Pause action.");
        Require(AutomationProperties.GetName(parts["Like"])?.Length > 0
            && AutomationProperties.GetName(parts["Seek"])?.Length > 0,
            "Confirmed Compact state lost control accessibility names.");
        phase = "busy-controls";
        view.SetPlayerBusy(true);
        Require(parts["Previous"] is Control { IsEnabled: false }
            && parts["PlayPause"] is Control { IsEnabled: false }
            && parts["Next"] is Control { IsEnabled: false }
            && parts["Like"] is Control { IsEnabled: false }
            && parts["Repeat"] is Control { IsEnabled: false }
            && parts["Shuffle"] is Control { IsEnabled: false }
            && parts["Seek"] is Control { IsEnabled: false }
            && parts["Volume"] is Control { IsEnabled: true }
            && parts["More"] is Control { IsEnabled: true }
            && parts["Close"] is Control { IsEnabled: true },
            "In-flight Compact action left duplicate playback controls active or blocked independent shell actions.");
        view.SetPlayerBusy(false);
        Require(parts["PlayPause"] is Control { IsEnabled: true }
            && parts["Shuffle"] is Control { IsEnabled: true }
            && parts["Seek"] is Control { IsEnabled: true },
            "Confirmed playback controls did not recover after the in-flight request completed.");

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
        var shuffleMarker = FindPart(view, "ShuffleMarker");
        Require(shuffleMarker.Visibility == Visibility.Visible
            && AutomationProperties.GetName(parts["Shuffle"]) == "Shuffle on",
            "Confirmed Shuffle-on state did not show the active dot or accessible state.");
        view.SetPlayback(state with { Shuffle = false });
        Require(shuffleMarker.Visibility == Visibility.Collapsed
            && AutomationProperties.GetName(parts["Shuffle"]) == "Shuffle off",
            "Confirmed Shuffle-off state retained an active marker.");
        view.SetPlayback(state with { Shuffle = null });
        Require(shuffleMarker.Visibility == Visibility.Collapsed
            && AutomationProperties.GetName(parts["Shuffle"]) == "Shuffle state unconfirmed",
            "Unknown Shuffle state falsely displayed an active indicator.");
        view.SetPlayback(null);
        Require(repeatMarker.Visibility == Visibility.Collapsed
            && shuffleMarker.Visibility == Visibility.Collapsed
            && ReadProperty(repeatMarker, "Text") as string == string.Empty
            && ToolTipService.GetToolTip(parts["Title"]) is null,
            "Unavailable Compact state retained a stale Shuffle/Repeat marker or title tooltip.");
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

        phase = "unavailable-seek-progress-and-duration-correction";
        view.SetPlayback(state with { Position = 120, Duration = 138, CanSeek = false });
        var progress = (ProgressBar)parts["SeekProgress"];
        Require(progress.Visibility == Visibility.Visible && parts["Seek"].Visibility == Visibility.Collapsed
            && Math.Abs(progress.Value - 120d / 138 * 1000) < 1
            && ReadProperty(parts["Elapsed"], "Text") as string == "2:00",
            "Unreadable gray seek slider replaced visible playback progress.");
        view.SetPlayback(state with { Position = 132, Duration = 250, CanSeek = false });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "2:12"
            && ReadProperty(parts["Duration"], "Text") as string == "4:10"
            && progress.Value < 600,
            "A same-track duration correction made the left playback clock count backward.");
        view.SetPlayback(state with { Position = 121, Duration = 120, CanSeek = false,
            ClockMismatch = true, ClockConfirmed = false });
        Require(parts["Seek"].Visibility == Visibility.Collapsed && progress.Visibility == Visibility.Visible
            && parts["Seek"] is Control { IsEnabled: false }
            && progress.Value == progress.Maximum
            && ReadProperty(parts["Elapsed"], "Text") as string == "~2:00"
            && ReadProperty(parts["Duration"], "Text") as string == "2:00"
            && AutomationProperties.GetHelpText(progress)?.Contains("Approximate media time",
                StringComparison.Ordinal) == true,
            "Current bounded media time was blanked by a disagreeing website slider.");
        // Signed-in cumulative media timeline: the coherent website clock stays interactive.
        var signedInTimeline = state with
        {
            Position = 156, Duration = 180, MediaDuration = 378, MediaPosition = 354, WebsiteClock = true,
            CanSeek = true, ClockMismatch = false, ClockConfirmed = true
        };
        view.SetPlayback(signedInTimeline);
        view.SetPlayback(signedInTimeline with { MediaDuration = 402, MediaPosition = 355 });
        Require(parts["Seek"] is Control { IsEnabled: true }
            && parts["Seek"].Visibility == Visibility.Visible
            && progress.Visibility == Visibility.Collapsed
            && ReadProperty(parts["Elapsed"], "Text") as string == "2:36"
            && ReadProperty(parts["Duration"], "Text") as string == "3:00"
            && !CompactPlayerView.CanDisplayCurrentMediaClock(signedInTimeline),
            "A longer cumulative media timeline disabled the website-clock seek slider.");
        view.SetPlayback(state with { Position = 118, Duration = 120 });
        view.SetPlayback(state with { Position = 119, Duration = 120, CanSeek = false,
            ClockMismatch = true, ClockConfirmed = false });
        Require(parts["Seek"] is Control { IsEnabled: false }
            && Math.Abs(progress.Value - 119d / 120 * 1000) < 1
            && ReadProperty(parts["Elapsed"], "Text") as string == "~1:59",
            "A mismatched slider displayed an old confirmed position instead of the current media time.");
        view.SetPlayback(state with { Position = 126, Duration = 120, CanSeek = false,
            ClockMismatch = true, ClockConfirmed = false });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "--:--"
            && progress.Value == 0,
            "A media overrun beyond two seconds displayed implausible progress.");
        view.SetPlayback(state with { Position = 10, Duration = 120 });
        view.SetPlayback(state with { Position = 119, Duration = 120, CanSeek = false,
            ClockMismatch = true, ClockConfirmed = false });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "~1:59",
            "A valid current media sample depended on proximity to an earlier sample.");
        view.SetPlayback(state with { Title = "New item", Position = 4, Duration = 120,
            CanSeek = false, ClockMismatch = true, ClockConfirmed = false });
        Require(Math.Abs(progress.Value - 4d / 120 * 1000) < 1
            && ReadProperty(parts["Elapsed"], "Text") as string == "~0:04",
            "A changed item inherited the previous item's progress instead of its own current clock.");
        view.SetPlayback(state with { Position = 118, Duration = 120 });
        view.SetPlayback(state with { Position = 2, Duration = 120, CanSeek = false,
            ClockMismatch = true, ClockConfirmed = false });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "~0:02"
            && Math.Abs(progress.Value - 2d / 120 * 1000) < 1,
            "A reset media clock inherited near-end progress.");
        view.SetPlayback(state with { Position = 118, Duration = 120 });
        view.SetPlayback(null);
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "--:--",
            "An unavailable playback snapshot kept stale progress visible.");
        view.SetPlayback(state with { Position = 119, Duration = 120, CanSeek = false,
            ClockMismatch = true, ClockConfirmed = false });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "~1:59",
            "A fresh media snapshot following an unavailable read stayed blank.");
        view.SetPlayback(state with { Position = 119, Duration = 120 });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "1:59"
            && parts["Seek"] is Control { IsEnabled: true },
            "Coherent playback did not recover timing and seek after a mismatch.");
        view.SetPlayback(state with { Position = 118, Duration = 120, VideoId = null });
        view.SetPlayback(state with { Position = 119, Duration = 120, VideoId = null,
            CanSeek = false, ClockMismatch = true, ClockConfirmed = false });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "~1:59"
            && parts["Seek"] is Control { IsEnabled: false },
            "Current media time was hidden solely because a validated watch ID is absent.");
        view.SetPlayback(state with { Position = 10, Duration = 0, CanSeek = false,
            ClockConfirmed = false });
        Require(progress.Visibility == Visibility.Collapsed && double.IsFinite(progress.Value)
            && parts["Seek"].Visibility == Visibility.Visible
            && parts["Seek"] is Control { IsEnabled: false },
            "Unknown duration produced an invalid or interactive progress indicator.");
        view.SetPlayback(state);
        Require(progress.Visibility == Visibility.Collapsed && parts["Seek"].Visibility == Visibility.Visible
            && parts["Seek"] is Control { IsEnabled: true },
            "The seek slider did not recover after public controls became coherent.");

        phase = "read-only-current-media-clock-without-prior";
        var unlinked = state with { VideoId = null, Position = 40 };
        var skew = unlinked with { Position = 112, CanSeek = false,
            ClockMismatch = true, ClockConfirmed = false };
        view.SetPlayback(null);
        view.SetPlayback(skew);
        Require(parts["Seek"] is Control { IsEnabled: false }
            && parts["Seek"].Visibility == Visibility.Collapsed
            && ReadProperty(parts["Elapsed"], "Text") as string == "~1:52"
            && ReadProperty(parts["Duration"], "Text") as string == "2:00"
            && Math.Abs(progress.Value - 112d / 120 * 1000) < 1
            && AutomationProperties.GetHelpText(progress)?.Contains(
                "Approximate media time", StringComparison.Ordinal) == true,
            "A valid first mismatched media snapshot after unavailable playback stayed blank.");
        view.SetPlayback(skew with { Position = 113 });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "~1:53"
            && Math.Abs(progress.Value - 113d / 120 * 1000) < 1,
            "Current mismatched media time did not advance progress independently of the website slider.");
        view.SetPlayback(skew with { Position = 113, Paused = true });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "~1:53"
            && parts["Seek"] is Control { IsEnabled: false },
            "A stable paused current media clock was hidden during website-slider disagreement.");
        view.SetPlayback(skew with { Position = 2 });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "~0:02"
            && Math.Abs(progress.Value - 2d / 120 * 1000) < 1,
            "A reset current media clock reused near-end progress.");
        view.SetPlayback(skew with { Title = "Changed item", Position = 4 });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "~0:04",
            "A changed item reused the previous item's elapsed time.");
        view.SetPlayback(skew with { VideoId = "ZbCdEfGhI01", Position = 7 });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "~0:07",
            "A changed public video identity prevented displaying its own media time.");
        view.SetPlayback(null);
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "--:--",
            "An unavailable media snapshot retained old progress.");
        view.SetPlayback(skew with { Position = 121 });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "~2:00"
            && progress.Value == progress.Maximum,
            "A bounded media-time overrun failed to clamp the read-only end clock.");
        view.SetPlayback(skew with { Position = 122.1 });
        Require(ReadProperty(parts["Elapsed"], "Text") as string == "--:--"
            && progress.Value == 0,
            "An overrun outside the bounded media clock displayed implausible timing.");
        Require(!CompactPlayerView.CanDisplayCurrentMediaClock(skew with { Position = double.NaN })
            && !CompactPlayerView.CanDisplayCurrentMediaClock(skew with { Position = double.PositiveInfinity })
            && !CompactPlayerView.CanDisplayCurrentMediaClock(skew with { Duration = 0 }),
            "Invalid media timing was accepted as read-only progress.");
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
        view.SetPlayback(state with { MediaDuration = 777, MediaPosition = 10 });
        Require(ReadProperty(seek, "Dragging") is true,
            "A growing media timeline on the same item canceled an in-progress seek drag.");
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
        var staleSeekTime = ReadProperty(parts["Elapsed"], "Text") as string;
        Require(Math.Abs(staleSeekValue - 500) <= 1 && staleSeekTime == "1:00",
            $"Stale player time replaced a just-committed seek target: slider={staleSeekValue}, elapsed={staleSeekTime}.");
        view.SetPlayback(state with { Position = 11, MediaDuration = 999 });
        Require(Math.Abs(Convert.ToDouble(ReadProperty(seek, "Value")) - 500) <= 1,
            "A growing media timeline on the same item discarded the pending seek target.");
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
            && ReadProperty(parts["Elapsed"], "Text") as string == "1:30",
            "A stale player read replaced the keyboard seek target.");
        SetField(view, "_seekPendingUntil", DateTime.UtcNow.AddMilliseconds(-1));
        view.SetPlayback(state with { Position = 11 });
        Require(Math.Abs(Convert.ToDouble(ReadProperty(seek, "Value")) - 91.67) <= 1
            && ReadProperty(parts["Elapsed"], "Text") as string == "0:11",
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
        Require(parts["InlineStatus"].Visibility == Visibility.Visible
            && ReadProperty(parts["InlineStatus"], "Text") as string == "Synthetic error",
            "Actionable Compact error disappeared with routine debug text.");
        view.SetPreferences(reduceMotion: true, topmost: false);
        Require(!CompactPlayerView.ShouldAnimate(true, true, true, false, true),
            "Reduced-motion preference did not suspend Compact animation policy.");
        await AwaitFlyoutClosedAsync(moreMenu!, () => view.SetActive(false), "More");
        view.SetActive(true);

        phase = "overflow-menu";
        view.SetStatus(string.Empty, isError: false);
        view.SetPlayback(state);
        PrepareViewSize(view, 360, 180);
        var narrowPlan = view.CurrentLayoutPlan
            ?? throw new SelfCheckException("Narrow Compact layout did not publish a plan.");
        Require(narrowPlan.SizeClass == CompactSizeClass.Standard
            && narrowPlan.Overflow.Contains(CompactOverflowControl.Repeat)
            && narrowPlan.Overflow.Contains(CompactOverflowControl.Timer)
            && !narrowPlan.Overflow.Contains(CompactOverflowControl.Like)
            && parts["Repeat"].Visibility == Visibility.Collapsed
            && parts["Timer"].Visibility == Visibility.Collapsed
            && parts["Like"].Visibility == Visibility.Visible,
            $"The 360-DIP Standard layout did not move Repeat and the pause timer into the More menu (class={narrowPlan.SizeClass}, size={narrowPlan.Width}x{narrowPlan.Height}, overflow=[{string.Join(",", narrowPlan.Overflow)}], repeat={parts["Repeat"].Visibility}, timer={parts["Timer"].Visibility}, like={parts["Like"].Visibility}, view={view.ActualWidth}x{view.ActualHeight}).");
        var overflowItems = (ReadField(view, "_overflowItems")
                as IEnumerable<(CompactOverflowControl Control, MenuFlyoutItem Item)>)?.ToList()
            ?? throw new SelfCheckException("Compact overflow menu items were not created.");
        await AwaitFlyoutOpenedAsync(moreMenu!, view.ShowMoreMenu, "More with overflow");
        var repeatItem = overflowItems.First(entry => entry.Control == CompactOverflowControl.Repeat).Item;
        var likeItem = overflowItems.First(entry => entry.Control == CompactOverflowControl.Like).Item;
        var timerItem = overflowItems.First(entry => entry.Control == CompactOverflowControl.Timer).Item;
        Require(repeatItem.Visibility == Visibility.Visible && repeatItem.IsEnabled
            && repeatItem.Text == AutomationProperties.GetName(parts["Repeat"])
            && AutomationProperties.GetHelpText(repeatItem) == AutomationProperties.GetHelpText(parts["Repeat"])
            && timerItem.Visibility == Visibility.Visible
            && timerItem.Text == AutomationProperties.GetName(parts["Timer"])
            && likeItem.Visibility == Visibility.Collapsed
            && moreMenu is MenuFlyout menuWithOverflow
            && menuWithOverflow.Items.IndexOf(repeatItem) < menuWithOverflow.Items.IndexOf(ReadField(view, "_settingsItem") as MenuFlyoutItem),
            "More-menu overflow entries did not mirror the hidden controls' names, help text and state.");
        commands.Clear();
        var invokeOverflow = FindMethod(view, "InvokeOverflowTarget")
            ?? throw new SelfCheckException("Compact overflow invocation hook was not retained.");
        invokeOverflow.Invoke(view, [CompactOverflowControl.Repeat]);
        Require(commands.Count(command => command.Command == "repeat") == 1,
            $"Invoking the hidden Repeat button through its automation pattern did not raise its command (commands=[{string.Join(",", commands.Select(c => c.Command))}]).");
        commands.Clear();
        InvokeControl(repeatItem, "More-menu Repeat");
        for (var attempt = 0; attempt < 25 && !commands.Any(command => command.Command == "repeat"); attempt++)
            await Task.Delay(20);
        Require(commands.Count(command => command.Command == "repeat") == 1,
            "Activating the More-menu Repeat entry did not run the hidden Repeat button's command path.");
        await AwaitFlyoutClosedAsync(moreMenu!, () => moreMenu!.Hide(), "More with overflow");
        commands.Clear();
        ReleaseViewSize(view);
        Prepare(view);
        Require(parts["Repeat"].Visibility == Visibility.Visible && parts["Timer"].Visibility == Visibility.Visible
            && repeatItem.Visibility == Visibility.Collapsed,
            "Restoring room did not move Repeat and the pause timer back out of the More menu.");

        phase = "shuffle-during-compact-read";
        Require(ReadProperty(host, "CompactActive") is true,
            "Compact command overlap fixture did not enter the active native presenter.");
        var executeCompact = FindMethod(host, "ExecuteCompactCommandAsync")
            ?? throw new SelfCheckException("Compact command dispatcher was not retained.");
        var readFinished = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        SetField(host, "_compactState", state);
        SetField(host, "_compactReadPending", true);
        SetField(host, "_compactReadCompleted", readFinished);
        var shuffleRequest = executeCompact.Invoke(host, ["shuffle", null]) as Task;
        Require(shuffleRequest is { IsCompleted: false } && ReadField(host, "_playerBusy") is true,
            "Shuffle was rejected as busy instead of awaiting the existing Compact state read.");
        readFinished.TrySetResult(true);
        SetField(host, "_compactReadPending", false);
        await shuffleRequest!.WaitAsync(TimeSpan.FromSeconds(2));
        SetField(host, "_compactReadCompleted", null);
        Require(ReadField(host, "_playerBusy") is false
            && (ReadField(host, "_statusDetailsText") as string)?.Contains(
                "Playback controls unavailable; no action was sent.", StringComparison.Ordinal) == true,
            "Unavailable dispatcher did not fail closed after the in-flight read completed.");
        view.SetPlayback(state);

        phase = "unavailable-status-menu";
        var setHostStatus = FindMethod(host, "SetStatus");
        Require(setHostStatus is not null, "Native application status update hook was not retained.");
        setHostStatus!.Invoke(host, ["Synthetic Compact status", false]);
        var rootGrid = FindPart(root, "RootGrid") as Grid;
        Require(rootGrid?.RowDefinitions.Count == 2 && FindPartCore(root, "StatusHost") is null
            && parts["InlineStatus"].Visibility == Visibility.Collapsed
            && AutomationProperties.GetHelpText(parts["More"])?.Contains(
                "Synthetic Compact status", StringComparison.Ordinal) == true,
            "Compact retained the lower strip or hid routine status from More.");
        setHostStatus.Invoke(host, [string.Empty, false]);
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

        phase = "compact-close-to-tray";
        var setTray = FindMethod(host, "SetTrayEnabled")
            ?? throw new SelfCheckException("Native tray preference hook was not retained.");
        setTray.Invoke(host, [true]);
        var tray = ReadField(host, "_tray") as NativeTrayIcon;
        var appWindow = ReadField(host, "_appWindow") as Microsoft.UI.Windowing.AppWindow
            ?? throw new SelfCheckException("Compact fixture has no native app window.");
        Require(tray is { IsVisible: true } && appWindow.IsVisible,
            "Tray-enabled Compact close fixture has no visible icon or window.");
        var trayHandle = host.NativeHandle;
        InvokeControl(parts["Close"], "Compact close");
        Require(appWindow.IsVisible == false && host.NativeHandle == trayHandle
            && ReadField(host, "_shutdownTask") is null,
            "Compact Close exited instead of hiding in the available tray.");
        host.RequestActivation();
        for (var attempt = 0; attempt < 25 && !appWindow.IsVisible; attempt++)
            await Task.Delay(20);
        Require(appWindow.IsVisible && host.NativeHandle == trayHandle,
            "Tray-hidden Compact window did not restore on the same HWND.");
        setTray.Invoke(host, [false]);
        Require(ReadField(host, "_tray") is null,
            "Disabling the tray icon left the fixture's icon registered.");

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
        Require(Math.Abs(clientWidth - ShellSettings.Default.CompactWidth * scale) <= 1
            && Math.Abs(clientHeight - ShellSettings.Default.CompactHeight * scale) <= 1,
            "Compact native client did not open at the saved/default 800 by 180 DIP client size.");
        Prepare(view, clientWidth / scale, clientHeight / scale);
        var plan = view.CurrentLayoutPlan
            ?? throw new SelfCheckException("Compact view did not publish its layout plan.");
        Require(plan.SizeClass == CompactSizeClass.Standard,
            $"Compact native client at 800x180 resolved to {plan.SizeClass} instead of Standard.");

        var source = InputNonClientPointerSource.GetForWindowId(
            Win32Interop.GetWindowIdFromWindow(host.NativeHandle));
        var caption = source.GetRegionRects(NonClientRegionKind.Caption);
        Require(caption.Length > 0,
            "Compact native Caption drag region was missing.");
        foreach (var region in plan.CaptionRegions)
            Require(CaptionContainsDip(caption, region.X + region.Width / 2, region.Y + region.Height / 2, scale),
                $"Compact Caption did not cover the planned drag region {region}.");
        Require(plan.Title is { } titleRect && CaptionContainsDip(caption, titleRect.X + titleRect.Width / 2, titleRect.Y + titleRect.Height / 2, scale)
            && plan.Artwork is { } artworkRect && CaptionContainsDip(caption, artworkRect.X + artworkRect.Width / 2, artworkRect.Y + artworkRect.Height / 2, scale),
            "Compact Caption did not cover the title and artwork drag areas.");
        foreach (var (name, rect) in plan.InteractiveRects())
        {
            Require(!CaptionContainsDip(caption, rect.X + rect.Width / 2, rect.Y + rect.Height / 2, scale)
                && !CaptionContainsDip(caption, rect.X + 1, rect.Y + 1, scale)
                && !CaptionContainsDip(caption, rect.Right - 1, rect.Bottom - 1, scale),
                $"Compact Caption intercepted {name}.");
        }

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

    private static readonly (double Width, double Height, CompactSizeClass SizeClass)[] NativeSizeSamples =
    {
        (360, 56, CompactSizeClass.Strip), (800, 64, CompactSizeClass.Strip),
        (800, 120, CompactSizeClass.Compact), (360, 180, CompactSizeClass.Standard),
        (800, 180, CompactSizeClass.Standard), (1200, 200, CompactSizeClass.Wide),
        (480, 420, CompactSizeClass.Tall)
    };

    /// <summary>
    /// Lays the real XAML surface out at one sample per size class and verifies the arranged controls
    /// match the plan: hidden controls are collapsed, visible ones sit at their planned bounds without
    /// overlap, InlineStatus stays under the title, and the seek row keeps its thumb and timestamps.
    /// </summary>
    private static void CheckNativeSizeClasses(CompactPlayerView view, IReadOnlyDictionary<string, FrameworkElement> parts)
    {
        var scale = view.XamlRoot?.RasterizationScale is > 0 and double rasterization ? rasterization : 1;
        foreach (var (width, height, expectedClass) in NativeSizeSamples)
        {
            var label = $"{width}x{height}";
            PrepareViewSize(view, width, height);
            view.SetPreferences(reduceMotion: true, topmost: false);
            view.UpdateLayout();
            Require(Math.Abs(view.ActualWidth - width) <= 1 && Math.Abs(view.ActualHeight - height) <= 1,
                $"Compact {label} check did not receive the requested viewport.");
            var plan = view.CurrentLayoutPlan
                ?? throw new SelfCheckException($"Compact {label} did not publish a layout plan.");
            Require(plan.SizeClass == expectedClass && Math.Abs(plan.Width - width) <= 1
                && Math.Abs(plan.Height - height) <= 1 && Math.Abs(plan.Scale - scale) < 0.001,
                $"Compact {label} applied {plan.SizeClass} at {plan.Width}x{plan.Height}@{plan.Scale} instead of {expectedClass}.");

            var arranged = new List<(string Name, FoundationRect Bounds)>();
            foreach (var (name, rect) in plan.InteractiveRects())
            {
                var element = FindOptionalPart(view, name);
                if (element is null && name == "Playlists") continue;
                if (element is null) throw new SelfCheckException($"Compact XAML part was not found: {name}.");
                Require(element.Visibility == Visibility.Visible
                    && Math.Abs(Canvas.GetLeft(element) - rect.X) < 0.01 && Math.Abs(Canvas.GetTop(element) - rect.Y) < 0.01
                    && Math.Abs(element.ActualWidth - rect.Width) < 0.01 && Math.Abs(element.ActualHeight - rect.Height) < 0.01,
                    $"Compact {label}: {name} was not arranged at its planned bounds {rect}.");
                var bounds = element.TransformToVisual(view).TransformBounds(
                    new FoundationRect(0, 0, element.ActualWidth, element.ActualHeight));
                Require(bounds.Left >= -0.01 && bounds.Top >= -0.01
                    && bounds.Right <= width + 0.01 && bounds.Bottom <= height + 0.01,
                    $"Compact {label}: {name} was arranged outside the client area.");
                Require(bounds.Width >= 32 && bounds.Height >= 32,
                    $"Compact {label}: {name} lost its 32-DIP hit target.");
                arranged.Add((name, bounds));
            }
            for (var first = 0; first < arranged.Count; first++)
                for (var second = first + 1; second < arranged.Count; second++)
                {
                    var a = arranged[first].Bounds;
                    var b = arranged[second].Bounds;
                    Require(!(a.Left < b.Right && a.Right > b.Left && a.Top < b.Bottom && a.Bottom > b.Top),
                        $"Compact {label}: {arranged[first].Name} overlaps {arranged[second].Name} on screen.");
                }
            foreach (var control in Enum.GetValues<CompactOverflowControl>())
            {
                // Playlists is an optional surface part (added by the host tree); the plan reserves its slot regardless.
                var element = parts.TryGetValue(control.ToString(), out var known) ? known
                    : FindOptionalPart(view, control.ToString());
                if (element is null) continue;
                Require((element.Visibility == Visibility.Collapsed) == plan.Overflow.Contains(control),
                    $"Compact {label}: {control} visibility disagrees with the More-menu overflow list.");
            }
            Require(parts["Artwork"].Visibility == (plan.Artwork is null ? Visibility.Collapsed : Visibility.Visible)
                && parts["Title"].Visibility == (plan.Title is null ? Visibility.Collapsed : Visibility.Visible),
                $"Compact {label}: artwork/title visibility disagrees with the plan.");

            if (plan.Title is { } titleRect && parts["InlineStatus"].Visibility == Visibility.Visible)
            {
                var status = parts["InlineStatus"];
                // TextBlock.ActualWidth/ActualHeight report rendered text metrics; the layout slot is Width/Height.
                Require(Math.Abs(Canvas.GetLeft(status) - titleRect.X) < 0.01
                    && Math.Abs(status.Width - titleRect.Width) < 0.01
                    && Math.Abs(Canvas.GetTop(status) - (titleRect.Y + titleRect.Height)) < 0.01
                    && Math.Abs(status.Height - 16) < 0.01 && status.ActualHeight <= 16.01,
                    $"Compact {label}: InlineStatus is not one line directly under the title (status left={Canvas.GetLeft(status)}, top={Canvas.GetTop(status)}, slot={status.Width}x{status.Height}; title={titleRect}).");
            }

            var timerText = FindPart(view, "TimerText");
            Require(plan.Timer is null || timerText.Visibility == (plan.TimerShowsText ? Visibility.Visible : Visibility.Collapsed),
                $"Compact {label}: pause-timer label visibility disagrees with the plan.");

            var progressRow = FindPart(view, "ProgressRow");
            if (plan.Progress is null)
            {
                Require(progressRow.Visibility == Visibility.Collapsed,
                    $"Compact {label}: seek row was not collapsed although the plan hides it.");
                continue;
            }
            Require(progressRow.Visibility == Visibility.Visible
                && Canvas.GetTop(progressRow) + progressRow.ActualHeight <= height + 0.01,
                $"Compact {label}: seek row was clipped.");
            var thumb = FindDescendant<Thumb>(parts["Seek"])
                ?? throw new SelfCheckException("Compact seek slider did not expose its native thumb.");
            var thumbBounds = thumb.TransformToVisual(parts["Seek"]).TransformBounds(
                new FoundationRect(0, 0, thumb.ActualWidth, thumb.ActualHeight));
            Require(thumbBounds.Top >= 2 && thumbBounds.Bottom + 2 <= parts["Seek"].ActualHeight,
                $"Compact {label}: seek slider clipped its native thumb or outer border.");
            Require(parts["Seek"].ActualWidth >= 80,
                $"Compact {label}: seek slider narrower than 80 DIP.");
            foreach (var name in new[] { "Elapsed", "Duration" })
            {
                var timeLabel = parts[name];
                Require(timeLabel.Visibility == (plan.ProgressShowsTimes ? Visibility.Visible : Visibility.Collapsed),
                    $"Compact {label}: timestamp {name} visibility disagrees with the plan.");
                if (!plan.ProgressShowsTimes) continue;
                var labelBounds = timeLabel.TransformToVisual(progressRow).TransformBounds(
                    new FoundationRect(0, 0, timeLabel.ActualWidth, timeLabel.ActualHeight));
                // Text metrics can be fractional while DesiredSize rounds up to a DIP.
                Require(Math.Ceiling(timeLabel.ActualHeight) >= timeLabel.DesiredSize.Height
                    && labelBounds.Top >= 0 && labelBounds.Bottom <= progressRow.ActualHeight,
                    $"Compact {label}: timestamp {name} was clipped.");
                Require(Math.Abs(labelBounds.Top + labelBounds.Height / 2 - progressRow.ActualHeight / 2) <= 1,
                    $"Compact {label}: timestamp {name} was not vertically centered.");
            }
        }
        ReleaseViewSize(view);
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

        Require(ReadField(host, "_appWindow") is not Microsoft.UI.Windowing.AppWindow appWindow
            || !Microsoft.UI.Windowing.AppWindowTitleBar.IsCustomizationSupported()
            || !appWindow.TitleBar.ExtendsContentIntoTitleBar,
            "Returning to full mode left content extended into the title bar, hiding the caption row.");
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

    /// <summary>
    /// Pins the view to an explicit size so later parent layout passes cannot re-arrange it while a
    /// size-class assertion runs; <see cref="ReleaseViewSize"/> hands sizing back to the host.
    /// </summary>
    private static void PrepareViewSize(CompactPlayerView view, double width, double height)
    {
        view.Width = width;
        view.Height = height;
        view.UpdateLayout();
        Require(Math.Abs(view.ActualWidth - width) <= 1 && Math.Abs(view.ActualHeight - height) <= 1,
            $"Compact view did not take the requested {width}x{height} viewport (got {view.ActualWidth}x{view.ActualHeight}).");
    }

    private static void ReleaseViewSize(CompactPlayerView view)
    {
        view.ClearValue(FrameworkElement.WidthProperty);
        view.ClearValue(FrameworkElement.HeightProperty);
        view.UpdateLayout();
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
