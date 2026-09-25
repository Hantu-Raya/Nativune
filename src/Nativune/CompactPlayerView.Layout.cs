using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Automation.Provider;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;

namespace Nativune;

/// <summary>Compact size classes, chosen from the client height first and then the width.</summary>
internal enum CompactSizeClass
{
    /// <summary>Height below 96 DIP: one row with artwork, title, transport and, when wide enough, seek.</summary>
    Strip,
    /// <summary>Height 96–143 DIP: artwork | title | transport row above a full-width seek row.</summary>
    Compact,
    /// <summary>Height 144 DIP and up: the 800×180 arrangement (artwork column, title, controls, seek).</summary>
    Standard,
    /// <summary>Standard arrangement at 1100 DIP and wider: secondary actions align right, title/seek stretch.</summary>
    Wide,
    /// <summary>Height 300 DIP and up with a near-square aspect: large centered artwork above stacked rows.</summary>
    Tall
}

/// <summary>Controls that move into the More menu when a row cannot fit them.</summary>
internal enum CompactOverflowControl { Like, Dislike, Playlists, Repeat, Shuffle, Volume, Timer, Minimize }

internal readonly record struct LayoutRect(double X, double Y, double Width, double Height)
{
    public double Right => X + Width;
    public double Bottom => Y + Height;
    public bool IsEmpty => Width <= 0 || Height <= 0;
    public bool Contains(double x, double y) => x >= X && x < Right && y >= Y && y < Bottom;
    public bool Overlaps(LayoutRect other)
        => X < other.Right && Right > other.X && Y < other.Bottom && Bottom > other.Y;
    public static LayoutRect FromEdges(double left, double top, double right, double bottom)
        => new(left, top, Math.Max(0, right - left), Math.Max(0, bottom - top));
}

/// <summary>
/// One resolved Compact layout in DIPs, snapped to the physical pixel grid of <see cref="Scale"/>.
/// A null rect means the control is hidden at this size; hidden actions are listed in <see cref="Overflow"/>.
/// </summary>
internal sealed record CompactLayoutPlan(
    CompactSizeClass SizeClass,
    double Width,
    double Height,
    double Scale,
    LayoutRect? Artwork,
    LayoutRect? Title,
    LayoutRect? Status,
    LayoutRect? Progress,
    bool ProgressShowsTimes,
    LayoutRect Previous,
    LayoutRect PlayPause,
    LayoutRect Next,
    LayoutRect? Like,
    LayoutRect? Dislike,
    LayoutRect? Playlists,
    LayoutRect? Repeat,
    LayoutRect? Shuffle,
    LayoutRect? Volume,
    LayoutRect? Timer,
    bool TimerShowsText,
    LayoutRect ReturnToFull,
    LayoutRect More,
    LayoutRect? Minimize,
    LayoutRect Close,
    IReadOnlyList<LayoutRect> CaptionRegions,
    IReadOnlyList<CompactOverflowControl> Overflow)
{
    /// <summary>Every pointer/keyboard target that is visible in this plan.</summary>
    public IEnumerable<(string Name, LayoutRect Rect)> InteractiveRects()
    {
        yield return ("Previous", Previous);
        yield return ("PlayPause", PlayPause);
        yield return ("Next", Next);
        if (Progress is { } progress) yield return ("ProgressRow", progress);
        if (Like is { } like) yield return ("Like", like);
        if (Dislike is { } dislike) yield return ("Dislike", dislike);
        if (Playlists is { } playlists) yield return ("Playlists", playlists);
        if (Repeat is { } repeat) yield return ("Repeat", repeat);
        if (Shuffle is { } shuffle) yield return ("Shuffle", shuffle);
        if (Volume is { } volume) yield return ("Volume", volume);
        if (Timer is { } timer) yield return ("Timer", timer);
        yield return ("ReturnToFull", ReturnToFull);
        yield return ("More", More);
        if (Minimize is { } minimize) yield return ("Minimize", minimize);
        yield return ("Close", Close);
    }
}

public sealed partial class CompactPlayerView
{
    // Window minimum (client DIPs). 360 keeps the Standard title row (title ≥ 80 + four 36-DIP window
    // buttons) and a Strip with a scrolling title and Return/More/Close; 56 fits one 40-DIP button row.
    private const int LogicalMinimumWidth = 360;
    private const int LogicalMinimumHeight = 56;

    // Size-class breakpoints in DIPs (see notes/plan.md research: MS breakpoints/command-bar overflow,
    // Spotify slim/wide/square shapes, Apple Music artwork/controls-only MiniPlayer, AIMP min-width hiding).
    internal const double StripMaxHeight = 96;
    internal const double CompactMaxHeight = 144;
    internal const double TallMinHeight = 300;
    internal const double TallMinAspect = 0.45;
    internal const double WideMinWidth = 1100;

    private const double EdgeMargin = 12;
    private const double ItemGap = 8;
    private const double PairGap = 4;
    private const double GroupGap = 16;
    private const double SmallButton = 40;
    private const double PlayButton = 48;
    private const double TransportWidth = SmallButton * 2 + PlayButton + ItemGap * 2;
    private const double UtilityButton = 36;
    private const double UtilityGap = 4;
    private const double UtilityWidth = UtilityButton * 4 + UtilityGap * 3;
    private const double UtilityWidthWithoutMinimize = UtilityButton * 3 + UtilityGap * 2;
    private const double TimerTextWidth = 148;
    private const double TitleHeight = 32;
    private const double StatusHeight = 16;
    private const double TitleBlockHeight = TitleHeight + StatusHeight;
    private const double TitleMinWidth = 80;
    private const double StripTitleMinWidth = 48;
    private const double TitleMaxWidth = 720;
    private const double ProgressHeight = 40;
    private const double ProgressTimesWidth = 52 + 8 + 48;
    private const double SeekMinWidth = 80;
    private const double ProgressMinWidthWithTimes = ProgressTimesWidth + SeekMinWidth;
    private const double StripSeekMinWidth = 120;
    private const double StandardArtwork = 112;
    private const double ArtworkMargin = 20;

    private readonly List<(CompactOverflowControl Control, MenuFlyoutItem Item)> _overflowItems = new();
    private MenuFlyoutSeparator? _overflowSeparator;
    private CompactLayoutPlan? _layoutPlan;
    // Volume's own click only mutes; the slider needs its own entry while Volume sits in More.
    private MenuFlyoutItem? _overflowVolumeLevelItem;

    internal static int LogicalMinimumWidthValue => LogicalMinimumWidth;
    internal static int LogicalMinimumHeightValue => LogicalMinimumHeight;
    internal static System.Drawing.Size LogicalMinimumSize => new(LogicalMinimumWidth, LogicalMinimumHeight);

    /// <summary>The plan applied by the last layout pass; null until the view has been laid out.</summary>
    internal CompactLayoutPlan? CurrentLayoutPlan => _layoutPlan;

    internal static CompactSizeClass ClassifySize(double width, double height)
    {
        if (height < StripMaxHeight) return CompactSizeClass.Strip;
        if (height < CompactMaxHeight) return CompactSizeClass.Compact;
        if (height >= TallMinHeight && height >= width * TallMinAspect && TallArtworkDiameter(width, height) >= 64)
            return CompactSizeClass.Tall;
        return width >= WideMinWidth ? CompactSizeClass.Wide : CompactSizeClass.Standard;
    }

    /// <summary>
    /// Pure layout planner. <paramref name="width"/>/<paramref name="height"/> are client DIPs,
    /// <paramref name="scale"/> the rasterization scale used to snap edges onto device pixels.
    /// The caption regions do not depend on <paramref name="statusVisible"/>, so the native window
    /// code can plan from the client rectangle alone.
    /// </summary>
    internal static CompactLayoutPlan PlanLayout(double width, double height, double scale, bool statusVisible)
    {
        width = double.IsFinite(width) ? Math.Max(LogicalMinimumWidth, width) : LogicalMinimumWidth;
        height = double.IsFinite(height) ? Math.Max(LogicalMinimumHeight, height) : LogicalMinimumHeight;
        scale = double.IsFinite(scale) && scale > 0 ? scale : 1;
        var builder = new PlanBuilder(width, height, scale, statusVisible);
        switch (ClassifySize(width, height))
        {
            case CompactSizeClass.Strip: PlanStrip(builder); break;
            case CompactSizeClass.Compact: PlanCompact(builder); break;
            case CompactSizeClass.Tall: PlanTall(builder); break;
            case CompactSizeClass.Wide: PlanStandard(builder, wide: true); break;
            default: PlanStandard(builder, wide: false); break;
        }
        return builder.Build();
    }

    private static void PlanStrip(PlanBuilder b)
    {
        var centerY = b.Height / 2;
        b.SizeClass = CompactSizeClass.Strip;
        var fixedWidth = EdgeMargin * 2 + TransportWidth + ItemGap + UtilityWidth;
        var available = b.Width - fixedWidth;
        if (available < StripTitleMinWidth + ItemGap)
        {
            // Minimize is the only window button the More menu can replace; the title is the drag handle.
            b.HideMinimize();
            available += UtilityWidth - UtilityWidthWithoutMinimize;
        }

        var titleWidth = 0d;
        if (available >= StripTitleMinWidth + ItemGap)
        {
            titleWidth = StripTitleMinWidth;
            available -= StripTitleMinWidth + ItemGap;
        }
        var seekWidth = 0d;
        if (available >= StripSeekMinWidth + ItemGap)
        {
            seekWidth = StripSeekMinWidth;
            available -= StripSeekMinWidth + ItemGap;
        }
        // Actions before decoration: Like/Dislike, Volume, the Playlists/Repeat/Shuffle group, the timer
        // and the progress times all claim space first; artwork only uses what is left.
        var extras = FitExtras(ref available);
        var showTimes = false;
        if (seekWidth > 0 && available >= ProgressTimesWidth)
        {
            showTimes = true;
            available -= ProgressTimesWidth;
        }
        if (extras.Timer && available >= TimerTextWidth - SmallButton)
        {
            extras.TimerText = true;
            available -= TimerTextWidth - SmallButton;
        }
        var artwork = Math.Clamp(b.Height - 16, 32, 80);
        var showArtwork = available >= artwork + ItemGap;
        if (showArtwork) available -= artwork + ItemGap;
        if (titleWidth > 0 && seekWidth > 0)
        {
            var titleExtra = Math.Min(available * 0.4, TitleMaxWidth - titleWidth);
            titleWidth += titleExtra;
            seekWidth += available - titleExtra;
        }
        else if (titleWidth > 0)
            titleWidth += Math.Min(available, TitleMaxWidth - titleWidth);
        else if (seekWidth > 0)
            seekWidth += available;

        var x = EdgeMargin;
        if (showArtwork)
        {
            b.Artwork = new LayoutRect(x, centerY - artwork / 2, artwork, artwork);
            x += artwork + ItemGap;
        }
        if (titleWidth > 0)
        {
            b.PlaceTitleBlock(x, centerY - TitleBlockHeight / 2, titleWidth);
            x += titleWidth + ItemGap;
        }
        var transportLeft = x;
        b.PlaceTransport(x, centerY - PlayButton / 2);
        x += TransportWidth;
        if (seekWidth > 0)
        {
            x += ItemGap;
            b.Progress = new LayoutRect(x, centerY - ProgressHeight / 2, seekWidth, ProgressHeight);
            b.ProgressShowsTimes = showTimes && seekWidth >= ProgressMinWidthWithTimes;
            x += seekWidth;
        }
        x = b.PlaceExtras(x, centerY - SmallButton / 2, extras, rightAligned: false);
        var utilityLeft = b.PlaceUtility(centerY - UtilityButton / 2);
        b.AddCaption(LayoutRect.FromEdges(0, 0, transportLeft - ItemGap / 2, b.Height));
        if (utilityLeft - x >= 24)
            b.AddCaption(LayoutRect.FromEdges(x + PairGap, 0, utilityLeft - PairGap, b.Height));
    }

    private static void PlanCompact(PlanBuilder b)
    {
        b.SizeClass = CompactSizeClass.Compact;
        var margin = Math.Clamp((b.Height - (PlayButton + ProgressHeight)) / 2, 4, 16);
        var row1Top = margin;
        var row1Bottom = row1Top + PlayButton;
        var progressTop = Math.Max(row1Bottom + PairGap, b.Height - margin - ProgressHeight);

        var fixedWidth = EdgeMargin * 2 + TransportWidth + ItemGap + UtilityWidth;
        var available = b.Width - fixedWidth;
        if (available < TitleMinWidth + ItemGap)
        {
            b.HideMinimize();
            available += UtilityWidth - UtilityWidthWithoutMinimize;
        }
        var titleWidth = Math.Clamp(available - ItemGap, StripTitleMinWidth, TitleMinWidth);
        available = Math.Max(0, available - titleWidth - ItemGap);
        var extras = FitExtras(ref available);
        var artwork = Math.Clamp(b.Height - margin * 2, 48, 96);
        var showArtwork = available >= artwork + ItemGap;
        if (showArtwork) available -= artwork + ItemGap;
        if (extras.Timer && available >= TimerTextWidth - SmallButton)
        {
            extras.TimerText = true;
            available -= TimerTextWidth - SmallButton;
        }
        titleWidth += Math.Min(available, TitleMaxWidth - titleWidth);

        var x = EdgeMargin;
        var progressLeft = EdgeMargin;
        if (showArtwork)
        {
            b.Artwork = new LayoutRect(x, (b.Height - artwork) / 2, artwork, artwork);
            x += artwork + ItemGap;
            progressLeft = x;
        }
        b.PlaceTitleBlock(x, row1Top, titleWidth);
        x += titleWidth + ItemGap;
        var transportLeft = x;
        b.PlaceTransport(x, row1Top);
        x += TransportWidth;
        b.PlaceExtras(x, row1Top + (PlayButton - SmallButton) / 2, extras, rightAligned: false);
        b.PlaceUtility(row1Top + (PlayButton - UtilityButton) / 2);
        b.Progress = new LayoutRect(progressLeft, progressTop, b.Width - EdgeMargin - progressLeft, ProgressHeight);
        b.ProgressShowsTimes = b.Progress.Value.Width >= ProgressMinWidthWithTimes;

        b.AddCaption(LayoutRect.FromEdges(0, 0, transportLeft - ItemGap / 2, row1Bottom));
        if (showArtwork)
            b.AddCaption(LayoutRect.FromEdges(0, 0, progressLeft - ItemGap / 2, b.Height));
        if (progressTop - row1Bottom >= 8)
            b.AddCaption(LayoutRect.FromEdges(0, row1Bottom, b.Width, progressTop));
    }

    private static void PlanStandard(PlanBuilder b, bool wide)
    {
        b.SizeClass = wide ? CompactSizeClass.Wide : CompactSizeClass.Standard;
        var artwork = StandardArtworkDiameter(b.Width, b.Height);
        var column = artwork > 0 ? ArtworkMargin * 2 + artwork : EdgeMargin;
        var gap1 = Math.Clamp((b.Height - 180) / 4, 0, 16);
        var gap2 = Math.Clamp(8 + (b.Height - 180) / 4, 0, 16);
        var block = TitleBlockHeight + gap1 + PlayButton + gap2 + ProgressHeight;
        var top = Math.Max(4, (b.Height - block) / 2);
        var controlsTop = top + TitleBlockHeight + gap1;
        var progressTop = controlsTop + PlayButton + gap2;

        if (artwork > 0)
            b.Artwork = new LayoutRect(ArtworkMargin, (b.Height - artwork) / 2, artwork, artwork);
        var utilityLeft = b.PlaceUtility(Math.Max(4, top - 2));
        b.PlaceTitleBlock(column, top, Math.Max(TitleMinWidth, utilityLeft - ItemGap - column));
        b.PlaceTransport(column, controlsTop);
        var available = b.Width - EdgeMargin - (column + TransportWidth);
        var extras = FitExtras(ref available);
        if (extras.Timer && available >= TimerTextWidth - SmallButton)
        {
            extras.TimerText = true;
            available -= TimerTextWidth - SmallButton;
        }
        b.PlaceExtras(column + TransportWidth, controlsTop + (PlayButton - SmallButton) / 2, extras, rightAligned: wide);
        b.Progress = new LayoutRect(column, progressTop, b.Width - EdgeMargin - column, ProgressHeight);
        b.ProgressShowsTimes = b.Progress.Value.Width >= ProgressMinWidthWithTimes;

        b.AddCaption(LayoutRect.FromEdges(0, 0, utilityLeft - ItemGap / 2, controlsTop));
        if (artwork > 0)
            b.AddCaption(LayoutRect.FromEdges(0, 0, column, b.Height));
        var progressBottom = progressTop + ProgressHeight;
        if (b.Height - progressBottom >= 8)
            b.AddCaption(LayoutRect.FromEdges(0, progressBottom, b.Width, b.Height));
    }

    private static void PlanTall(PlanBuilder b)
    {
        b.SizeClass = CompactSizeClass.Tall;
        const double utilityTop = 8;
        const double bandBottom = utilityTop + UtilityButton + ItemGap;
        var progressTop = b.Height - EdgeMargin - ProgressHeight;
        var controlsTop = progressTop - ItemGap - PlayButton;
        var titleTop = controlsTop - ItemGap - TitleBlockHeight;
        var artwork = TallArtworkDiameter(b.Width, b.Height);
        var artworkTop = bandBottom + (titleTop - ItemGap - bandBottom - artwork) / 2;
        b.Artwork = new LayoutRect((b.Width - artwork) / 2, artworkTop, artwork, artwork);
        var utilityLeft = b.PlaceUtility(utilityTop);
        b.PlaceTitleBlock(EdgeMargin, titleTop, b.Width - EdgeMargin * 2);
        var available = b.Width - EdgeMargin * 2 - TransportWidth;
        var extras = FitExtras(ref available);
        if (extras.Timer && available >= TimerTextWidth - SmallButton)
        {
            extras.TimerText = true;
            available -= TimerTextWidth - SmallButton;
        }
        var clusterWidth = TransportWidth + extras.Width;
        var x = Math.Max(EdgeMargin, (b.Width - clusterWidth) / 2);
        b.PlaceTransport(x, controlsTop);
        b.PlaceExtras(x + TransportWidth, controlsTop + (PlayButton - SmallButton) / 2, extras, rightAligned: false);
        b.Progress = new LayoutRect(EdgeMargin, progressTop, b.Width - EdgeMargin * 2, ProgressHeight);
        b.ProgressShowsTimes = b.Progress.Value.Width >= ProgressMinWidthWithTimes;

        b.AddCaption(LayoutRect.FromEdges(0, 0, utilityLeft - ItemGap / 2, bandBottom));
        b.AddCaption(LayoutRect.FromEdges(0, bandBottom, b.Width, controlsTop - ItemGap / 2));
    }

    private static double StandardArtworkDiameter(double width, double height)
    {
        if (width < 400) return 0;
        var diameter = Math.Clamp(StandardArtwork - (640 - width) * 0.4, 40, StandardArtwork);
        if (width >= 640) diameter += Math.Clamp((height - 180) * 0.5, 0, 88);
        diameter = Math.Min(diameter, height - 32);
        return diameter >= 40 ? Math.Floor(diameter) : 0;
    }

    private static double TallArtworkDiameter(double width, double height)
    {
        var titleTop = height - EdgeMargin - ProgressHeight - ItemGap - PlayButton - ItemGap - TitleBlockHeight;
        var bandBottom = 8 + UtilityButton + ItemGap;
        return Math.Floor(Math.Min(width - ArtworkMargin * 2, titleTop - ItemGap - bandBottom));
    }

    /// <summary>
    /// Includes secondary actions in priority order (Like/Dislike, Volume, Repeat/Shuffle, Timer) while
    /// they fit; the first action that does not fit stops the sequence so lower priorities never
    /// jump ahead of a hidden higher one.
    /// </summary>
    private static ExtrasFit FitExtras(ref double available)
    {
        var fit = new ExtrasFit();
        var lead = GroupGap;
        var pair = SmallButton * 2 + PairGap;
        var triple = SmallButton * 3 + PairGap * 2;
        if (available >= lead + pair) { fit.Like = true; available -= lead + pair; lead = PairGap; } else return fit;
        if (available >= lead + SmallButton) { fit.Volume = true; available -= lead + SmallButton; lead = PairGap; } else return fit;
        if (available >= lead + triple) { fit.Playlists = true; available -= lead + triple; } else return fit;
        if (available >= GroupGap + SmallButton) { fit.Timer = true; available -= GroupGap + SmallButton; }
        return fit;
    }

    private struct ExtrasFit
    {
        public bool Like, Volume, Playlists, Timer, TimerText;

        public readonly double Width
        {
            get
            {
                var width = 0d;
                var first = true;
                foreach (var (present, size) in new[]
                {
                    (Like, SmallButton * 2 + PairGap), (Playlists, SmallButton * 3 + PairGap * 2), (Volume, SmallButton)
                })
                {
                    if (!present) continue;
                    width += (first ? GroupGap : PairGap) + size;
                    first = false;
                }
                if (Timer) width += GroupGap + (TimerText ? TimerTextWidth : SmallButton);
                return width;
            }
        }
    }

    private sealed class PlanBuilder
    {
        private readonly List<LayoutRect> _caption = new();
        private readonly List<CompactOverflowControl> _overflow = new();
        private bool _minimizeHidden;

        public PlanBuilder(double width, double height, double scale, bool statusVisible)
        {
            Width = width;
            Height = height;
            Scale = scale;
            StatusVisible = statusVisible;
        }

        public double Width { get; }
        public double Height { get; }
        public double Scale { get; }
        public bool StatusVisible { get; }
        public CompactSizeClass SizeClass { get; set; }
        public LayoutRect? Artwork { get; set; }
        public LayoutRect? Title { get; set; }
        public LayoutRect? Status { get; set; }
        public LayoutRect? Progress { get; set; }
        public bool ProgressShowsTimes { get; set; }
        public LayoutRect Previous { get; set; }
        public LayoutRect PlayPause { get; set; }
        public LayoutRect Next { get; set; }
        public LayoutRect? Like { get; set; }
        public LayoutRect? Dislike { get; set; }
        public LayoutRect? Playlists { get; set; }
        public LayoutRect? Repeat { get; set; }
        public LayoutRect? Shuffle { get; set; }
        public LayoutRect? Volume { get; set; }
        public LayoutRect? Timer { get; set; }
        public bool TimerShowsText { get; set; }
        public LayoutRect ReturnToFull { get; set; }
        public LayoutRect More { get; set; }
        public LayoutRect? Minimize { get; set; }
        public LayoutRect Close { get; set; }

        public void HideMinimize() => _minimizeHidden = true;

        public void PlaceTitleBlock(double x, double top, double width)
        {
            // InlineStatus always sits directly under the title at the full title width; when it is
            // collapsed the title alone is centered within the same 48-DIP block.
            Title = new LayoutRect(x, StatusVisible ? top : top + StatusHeight / 2, width, TitleHeight);
            Status = new LayoutRect(x, top + TitleHeight, width, StatusHeight);
        }

        public void PlaceTransport(double x, double rowTop)
        {
            var smallTop = rowTop + (PlayButton - SmallButton) / 2;
            Previous = new LayoutRect(x, smallTop, SmallButton, SmallButton);
            PlayPause = new LayoutRect(x + SmallButton + ItemGap, rowTop, PlayButton, PlayButton);
            Next = new LayoutRect(x + SmallButton + ItemGap + PlayButton + ItemGap, smallTop, SmallButton, SmallButton);
        }

        /// <summary>
        /// Places fitted extras after <paramref name="x"/> (or right-aligned) in visual order
        /// Like, Dislike, Playlists, Repeat, Shuffle, Volume, Timer and returns the next free x. The run
        /// steps 44 DIP between neighbours; the run itself and the timer start 16 DIP after the previous item.
        /// </summary>
        public double PlaceExtras(double x, double top, ExtrasFit fit, bool rightAligned)
        {
            if (rightAligned)
                x = Math.Max(x, Width - EdgeMargin - fit.Width);
            var first = true;
            double Lead() { var lead = first ? GroupGap : PairGap; first = false; return lead; }
            if (fit.Like)
            {
                x += Lead();
                Like = new LayoutRect(x, top, SmallButton, SmallButton);
                x += SmallButton + PairGap;
                Dislike = new LayoutRect(x, top, SmallButton, SmallButton);
                x += SmallButton;
            }
            else
                _overflow.AddRange(new[] { CompactOverflowControl.Like, CompactOverflowControl.Dislike });
            if (fit.Playlists)
            {
                x += Lead();
                Playlists = new LayoutRect(x, top, SmallButton, SmallButton);
                x += SmallButton + PairGap;
                Repeat = new LayoutRect(x, top, SmallButton, SmallButton);
                x += SmallButton + PairGap;
                Shuffle = new LayoutRect(x, top, SmallButton, SmallButton);
                x += SmallButton;
            }
            else
                _overflow.AddRange(new[] { CompactOverflowControl.Playlists, CompactOverflowControl.Repeat, CompactOverflowControl.Shuffle });
            if (fit.Volume)
            {
                x += Lead();
                Volume = new LayoutRect(x, top, SmallButton, SmallButton);
                x += SmallButton;
            }
            else
                _overflow.Add(CompactOverflowControl.Volume);
            if (fit.Timer)
            {
                x += GroupGap;
                var width = fit.TimerText ? TimerTextWidth : SmallButton;
                Timer = new LayoutRect(x, top, width, SmallButton);
                TimerShowsText = fit.TimerText;
                x += width;
            }
            else
                _overflow.Add(CompactOverflowControl.Timer);
            return x;
        }

        /// <summary>Right-aligns Return/More/[Minimize]/Close and returns the cluster's left edge.</summary>
        public double PlaceUtility(double top)
        {
            var x = Width - EdgeMargin - UtilityButton;
            Close = new LayoutRect(x, top, UtilityButton, UtilityButton);
            if (_minimizeHidden)
                _overflow.Add(CompactOverflowControl.Minimize);
            else
            {
                x -= UtilityButton + UtilityGap;
                Minimize = new LayoutRect(x, top, UtilityButton, UtilityButton);
            }
            x -= UtilityButton + UtilityGap;
            More = new LayoutRect(x, top, UtilityButton, UtilityButton);
            x -= UtilityButton + UtilityGap;
            ReturnToFull = new LayoutRect(x, top, UtilityButton, UtilityButton);
            return x;
        }

        public void AddCaption(LayoutRect rect)
        {
            if (!rect.IsEmpty) _caption.Add(rect);
        }

        public CompactLayoutPlan Build()
        {
            var order = new[]
            {
                CompactOverflowControl.Like, CompactOverflowControl.Dislike, CompactOverflowControl.Playlists,
                CompactOverflowControl.Repeat, CompactOverflowControl.Shuffle, CompactOverflowControl.Volume,
                CompactOverflowControl.Timer, CompactOverflowControl.Minimize
            };
            return new CompactLayoutPlan(
                SizeClass, Width, Height, Scale,
                Snap(Artwork), Snap(Title), Snap(Status), Snap(Progress), ProgressShowsTimes,
                Snap(Previous), Snap(PlayPause), Snap(Next),
                Snap(Like), Snap(Dislike), Snap(Playlists), Snap(Repeat), Snap(Shuffle), Snap(Volume), Snap(Timer), TimerShowsText,
                Snap(ReturnToFull), Snap(More), Snap(Minimize), Snap(Close),
                _caption.Select(Snap).ToArray(),
                order.Where(_overflow.Contains).ToArray());
        }

        private LayoutRect? Snap(LayoutRect? rect) => rect is { } value ? Snap(value) : null;

        private LayoutRect Snap(LayoutRect rect)
        {
            // Client sizes come from whole device pixels, so snapping stays inside them; clamp anyway
            // so a fractional-pixel size can never push an edge past the client.
            var left = Math.Max(0, Math.Round(rect.X * Scale) / Scale);
            var top = Math.Max(0, Math.Round(rect.Y * Scale) / Scale);
            var right = Math.Min(Width, Math.Round(rect.Right * Scale) / Scale);
            var bottom = Math.Min(Height, Math.Round(rect.Bottom * Scale) / Scale);
            return LayoutRect.FromEdges(left, top, right, bottom);
        }
    }

    private void InitializeLayout()
    {
        var index = 0;
        foreach (var control in new[]
        {
            CompactOverflowControl.Like, CompactOverflowControl.Dislike, CompactOverflowControl.Playlists,
            CompactOverflowControl.Repeat, CompactOverflowControl.Shuffle, CompactOverflowControl.Volume,
            CompactOverflowControl.Timer, CompactOverflowControl.Minimize
        })
        {
            var item = new MenuFlyoutItem { Visibility = Visibility.Collapsed, Text = control.ToString() };
            var captured = control;
            // The menu closes on click; the control's own click path runs on the next dispatcher turn
            // so the flyout's close sequence is never interrupted.
            item.Click += (_, _) => DispatcherQueue.TryEnqueue(() => InvokeOverflowTarget(captured));
            _overflowItems.Add((control, item));
            _moreMenu.Items.Insert(index++, item);
            if (control == CompactOverflowControl.Volume)
            {
                var level = new MenuFlyoutItem { Visibility = Visibility.Collapsed, Text = "App volume…" };
                level.Click += (_, _) => DispatcherQueue.TryEnqueue(OpenVolumePopupForInteraction);
                _overflowVolumeLevelItem = level;
                _moreMenu.Items.Insert(index++, level);
            }
        }
        _overflowSeparator = new MenuFlyoutSeparator { Visibility = Visibility.Collapsed };
        _moreMenu.Items.Insert(index, _overflowSeparator);
        _moreMenu.Opening += (_, _) => RefreshOverflowMenuItems();
        _inlineStatus.RegisterPropertyChangedCallback(VisibilityProperty, (_, _) => LayoutControls());
    }

    private void LayoutControls()
    {
        if (_disposed) return;
        var width = ActualWidth > 0 ? ActualWidth : ShellSettings.Default.CompactWidth;
        var height = ActualHeight > 0 ? ActualHeight : ShellSettings.Default.CompactHeight;
        var scale = XamlRoot?.RasterizationScale is > 0 and double rasterization ? rasterization : 1;
        var plan = PlanLayout(width, height, scale, _inlineStatus.Visibility == Visibility.Visible);
        _layoutPlan = plan;

        ApplyBounds(_artwork, plan.Artwork);
        ApplyBounds(_title, plan.Title);
        // InlineStatus visibility belongs to the status logic; layout only positions it.
        if (plan.Status is { } status) SetBounds(_inlineStatus, status);
        ApplyBounds(ProgressRow, plan.Progress);
        var timesVisibility = plan.ProgressShowsTimes ? Visibility.Visible : Visibility.Collapsed;
        ProgressRow.ColumnDefinitions[0].Width = new GridLength(plan.ProgressShowsTimes ? 52 : 0);
        ProgressRow.ColumnDefinitions[2].Width = new GridLength(plan.ProgressShowsTimes ? 8 : 0);
        ProgressRow.ColumnDefinitions[3].Width = new GridLength(plan.ProgressShowsTimes ? 48 : 0);
        if (_elapsed.Visibility != timesVisibility) _elapsed.Visibility = timesVisibility;
        if (_duration.Visibility != timesVisibility) _duration.Visibility = timesVisibility;
        ApplyBounds(_previous, plan.Previous);
        ApplyBounds(_playPause, plan.PlayPause);
        ApplyBounds(_next, plan.Next);
        ApplyBounds(_like, plan.Like);
        ApplyBounds(_dislike, plan.Dislike);
        if (PlaylistsButton is { } playlistsButton) ApplyBounds(playlistsButton, plan.Playlists);
        ApplyBounds(_repeat, plan.Repeat);
        ApplyBounds(_shuffle, plan.Shuffle);
        ApplyBounds(_volume, plan.Volume);
        if (plan.Volume is null && _volumePopup.IsOpen) _volumePopup.Hide();
        ApplyBounds(_timer, plan.Timer);
        var timerTextVisibility = plan.TimerShowsText ? Visibility.Visible : Visibility.Collapsed;
        if (_timerText.Visibility != timerTextVisibility) _timerText.Visibility = timerTextVisibility;
        ApplyBounds(_returnToFull, plan.ReturnToFull);
        ApplyBounds(_more, plan.More);
        ApplyBounds(_minimize, plan.Minimize);
        ApplyBounds(_close, plan.Close);
        RefreshOverflowMenuItems();
    }

    private static void ApplyBounds(FrameworkElement element, LayoutRect? rect)
    {
        if (rect is { } bounds)
        {
            SetBounds(element, bounds);
            if (element.Visibility != Visibility.Visible) element.Visibility = Visibility.Visible;
        }
        else if (element.Visibility != Visibility.Collapsed)
            element.Visibility = Visibility.Collapsed;
    }

    private static void SetBounds(FrameworkElement element, LayoutRect rect)
    {
        Canvas.SetLeft(element, rect.X);
        Canvas.SetTop(element, rect.Y);
        element.Width = rect.Width;
        element.Height = rect.Height;
    }

    /// <summary>The optional Playlists button (XAML x:Name="Playlists"); null when the surface has none.</summary>
    private ButtonBase? PlaylistsButton => FindName("Playlists") as ButtonBase;

    private ButtonBase? OverflowTarget(CompactOverflowControl control) => control switch
    {
        CompactOverflowControl.Like => _like,
        CompactOverflowControl.Dislike => _dislike,
        CompactOverflowControl.Playlists => PlaylistsButton,
        CompactOverflowControl.Repeat => _repeat,
        CompactOverflowControl.Shuffle => _shuffle,
        CompactOverflowControl.Volume => _volume,
        CompactOverflowControl.Timer => _timer,
        _ => _minimize
    };

    private string OverflowIconName(CompactOverflowControl control) => control switch
    {
        CompactOverflowControl.Like => _likeIconName ?? "like",
        CompactOverflowControl.Dislike => _dislikeIconName ?? "dislike",
        CompactOverflowControl.Playlists => "playlist",
        CompactOverflowControl.Repeat => _repeatIconName ?? "repeat",
        CompactOverflowControl.Shuffle => "shuffle",
        CompactOverflowControl.Volume => _volumeIconName ?? "volume",
        CompactOverflowControl.Timer => _timerIconName ?? "quit-timer",
        _ => "minimize"
    };

    /// <summary>
    /// Mirrors hidden controls as More-menu entries. Labels, help text, enabled state and glyphs come from
    /// the hidden button itself, so the menu follows whatever playback state the button currently shows.
    /// </summary>
    private void RefreshOverflowMenuItems()
    {
        if (_disposed || _layoutPlan is not { } plan) return;
        var any = false;
        foreach (var (control, item) in _overflowItems)
        {
            var target = OverflowTarget(control);
            var visible = target is not null && plan.Overflow.Contains(control);
            var visibility = visible ? Visibility.Visible : Visibility.Collapsed;
            if (item.Visibility != visibility) item.Visibility = visibility;
            if (!visible) continue;
            any = true;
            var name = AutomationProperties.GetName(target);
            var text = string.IsNullOrWhiteSpace(name) ? control.ToString() : name;
            if (control == CompactOverflowControl.Playlists && !text.EndsWith('…')) text += "…";
            if (!string.Equals(item.Text, text, StringComparison.Ordinal)) item.Text = text;
            if (item.IsEnabled != target!.IsEnabled) item.IsEnabled = target.IsEnabled;
            // The Volume button's help describes hover and Down-key gestures a menu entry can't offer.
            var help = control == CompactOverflowControl.Volume
                ? $"{text}. Use App volume… to change the level."
                : AutomationProperties.GetHelpText(target) ?? text;
            SetAccessible(item, text, help);
            try
            {
                var icon = OverflowIconName(control);
                if (item.Tag as string != icon)
                {
                    item.Icon = _iconCache.CreateElement(icon, 16);
                    item.Tag = icon;
                }
            }
            catch (Exception)
            {
                item.Icon = null;
                item.Tag = null;
            }
        }
        if (_overflowVolumeLevelItem is { } levelItem)
        {
            var levelVisible = plan.Overflow.Contains(CompactOverflowControl.Volume);
            var levelVisibility = levelVisible ? Visibility.Visible : Visibility.Collapsed;
            if (levelItem.Visibility != levelVisibility) levelItem.Visibility = levelVisibility;
            var levelEnabled = _volume.IsEnabled && _volumeSlider.IsEnabled;
            if (levelItem.IsEnabled != levelEnabled) levelItem.IsEnabled = levelEnabled;
            SetAccessible(levelItem, "App volume…", "Open the app output volume slider.");
            if (levelItem.Tag as string != "volume")
            {
                try { levelItem.Icon = _iconCache.CreateElement("volume", 16); levelItem.Tag = "volume"; }
                catch (Exception) { levelItem.Icon = null; }
            }
        }
        if (_overflowSeparator is { } separator)
        {
            var separatorVisibility = any ? Visibility.Visible : Visibility.Collapsed;
            if (separator.Visibility != separatorVisibility) separator.Visibility = separatorVisibility;
        }
    }

    /// <summary>
    /// Activates the hidden control through its own automation pattern, so the menu entry runs exactly
    /// the button's click path (including any state handling the button performs) without duplicating it.
    /// </summary>
    private void InvokeOverflowTarget(CompactOverflowControl control)
    {
        if (_disposed || !_active) return;
        if (OverflowTarget(control) is not { IsEnabled: true } target) return;
        // A collapsed button ignores programmatic clicks, so it is revealed only for the synchronous
        // click and collapsed again before the next frame; its layout slot is unchanged.
        var wasCollapsed = target.Visibility == Visibility.Collapsed;
        if (wasCollapsed)
        {
            target.Visibility = Visibility.Visible;
            target.UpdateLayout();
        }
        try
        {
            var peer = FrameworkElementAutomationPeer.CreatePeerForElement(target)
                ?? FrameworkElementAutomationPeer.FromElement(target);
            if (peer?.GetPattern(PatternInterface.Toggle) is IToggleProvider toggle)
                toggle.Toggle();
            else if (peer?.GetPattern(PatternInterface.Invoke) is IInvokeProvider invoke)
                invoke.Invoke();
        }
        finally
        {
            if (wasCollapsed && !_disposed) target.Visibility = Visibility.Collapsed;
        }
    }
}
