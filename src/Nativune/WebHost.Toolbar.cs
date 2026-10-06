using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Shapes;

namespace Nativune;

// Narrow full windows: the toolbar needs about 600 DIP with every button, so the lowest-priority buttons collapse
// into More (owner decision, 28 September 2026) instead of sliding under the caption buttons. Order: Forward,
// Update, Discord and OBS (More already has their toggles and settings), Timer, app volume, then Home. Compact, Back and More stay,
// and the full window's minimum width is that non-collapsible footprint plus the drag area and caption buttons.
public sealed partial class WebHostWindow
{
    private const double ToolbarSpacing = 4;
    private const double ToolbarDragMinimum = 40;
    private MenuFlyoutItem _forwardOverflowItem = null!;
    private MenuFlyoutItem _volumeOverflowItem = null!;
    private MenuFlyoutItem _setTimerOverflowItem = null!;
    private MenuFlyoutItem _cancelTimerOverflowItem = null!;
    private MenuFlyoutItem _updateOverflowItem = null!;
    private MenuFlyoutItem _homeOverflowItem = null!;
    private ToggleMenuFlyoutItem _equalizerMenuItem = null!;
    private bool _openEqualizerSettings;

    private MenuFlyoutItemBase[] CreateToolbarOverflowItems()
    {
        _forwardOverflowItem = CreateMenuItem("Forward", "forward",
            () => { if (CanNavigate && _browserHost?.Core.CanGoForward == true) _browserHost.Core.GoForward(); });
        _volumeOverflowItem = CreateMenuItem("App volume…", "volume", () => DispatcherQueue.TryEnqueue(() =>
        {
            if (!_disposed) { _outputFlyoutCloseTimer?.Stop(); ShowOutputFlyout(fromHover: false, anchor: MoreButton); }
        }));
        _setTimerOverflowItem = CreateMenuItem("Set pause timer", "quit-timer", SetPauseTimer);
        _cancelTimerOverflowItem = CreateMenuItem("Cancel pause timer", "cancel-timer", CancelPauseTimer);
        _updateOverflowItem = CreateMenuItem("Check for Nativune updates", "update", OnUpdateButtonClick);
        _homeOverflowItem = CreateMenuItem("Open Music Home", "home", () => { if (CanNavigate) _browserHost?.Core.Navigate(_initialUri); });
        _equalizerMenuItem = new ToggleMenuFlyoutItem { Text = "Equalizer", IsChecked = _settings.Equalizer.Enabled };
        AutomationProperties.SetName(_equalizerMenuItem, "Equalizer");
        _equalizerMenuItem.Click += async (_, _) =>
        {
            if (_closing || _disposed) return;
            _equalizerMenuItem.IsEnabled = false;
            try
            {
                _settings = _settings with { Equalizer = _settings.Equalizer with { Enabled = _equalizerMenuItem.IsChecked } };
                var apply = ApplyEqualizerFromSettingsAsync();
                var persisted = await SaveSettingsConfirmedAsync();
                await apply;
                if (!persisted) SetStatus("Equalizer applies for this session only; the setting could not be saved.", isError: true);
            }
            catch (Exception) { if (!_closing && !_disposed) SetStatus("Equalizer could not be applied.", isError: true); }
            finally { _equalizerMenuItem.IsEnabled = !_closing && !_disposed; }
        };
        var equalizerSettingsItem = new MenuFlyoutItem { Text = "Equalizer settings…" };
        AutomationProperties.SetName(equalizerSettingsItem, "Equalizer settings");
        equalizerSettingsItem.Click += (_, _) =>
        {
            if (_closing || _disposed || _settingsDialogOpen) return;
            _openEqualizerSettings = true;
            ShowSettings();
        };
        EqualizerStatusChanged += (_, _) => CompactView.SetEqualizerStatus(EqualizerStatus);
        CompactView.SetEqualizerStatus(EqualizerStatus);
        _moreFlyout.Opening += (_, _) => RefreshToolbarOverflowItems();
        // The host, not the Grid: an overfull Grid keeps its desired width, so its own size never shrinks.
        ToolbarHost.SizeChanged += (_, _) => UpdateToolbarOverflow();
        RefreshToolbarOverflowItems();
        return [_homeOverflowItem, _forwardOverflowItem, _volumeOverflowItem, _setTimerOverflowItem, _cancelTimerOverflowItem, _updateOverflowItem,
            _equalizerMenuItem, equalizerSettingsItem];
    }

    private void SetToolbarOverflowIcons()
    {
        _forwardOverflowItem.Icon = _iconCache.CreateElement("forward", 16);
        _volumeOverflowItem.Icon = _iconCache.CreateElement("volume", 16);
        _setTimerOverflowItem.Icon = _iconCache.CreateElement("quit-timer", 16);
        _cancelTimerOverflowItem.Icon = _iconCache.CreateElement("cancel-timer", 16);
        _updateOverflowItem.Icon = _iconCache.CreateElement("update", 16);
        _homeOverflowItem.Icon = _iconCache.CreateElement("home", 16);
    }

    // Hides buttons, lowest priority first, until the toolbar fits beside the caption buttons with a drag area.
    private void UpdateToolbarOverflow()
    {
        if (_disposed || ToolbarHost.ActualWidth <= 0) return;
        var available = ToolbarHost.ActualWidth - Toolbar.Margin.Left - Toolbar.Margin.Right
            - CaptionButtonsColumn.Width.Value - ToolbarDragMinimum;
        var order = CollapseOrder();
        var hidden = 0;
        while (hidden < order.Length && ToolbarWidth(order, hidden) > available)
            hidden++;
        for (var i = 0; i < order.Length; i++)
            SetVisible(order[i], i >= hidden);
        SetVisible(DiscordSeparator, DiscordButton.Visibility == Visibility.Visible || UpdateButton.Visibility == Visibility.Visible);
        if (_moreFlyout?.IsOpen == true) RefreshToolbarOverflowItems();
    }

    private UIElement[] CollapseOrder()
        => [ForwardButton, UpdateButton, DiscordButton, ObsButton, TimerButton, OutputMuteButton, HomeButton];

    // Width in DIP below which the fixed toolbar controls would slide under the caption buttons; 0 before layout.
    private double FullToolbarMinimumDip()
    {
        if (ToolbarHost.ActualWidth <= 0) return 0;
        var order = CollapseOrder();
        return Toolbar.Margin.Left + Toolbar.Margin.Right + ToolbarWidth(order, order.Length)
            + ToolbarDragMinimum + CaptionButtonsColumn.Width.Value;
    }

    private double ToolbarWidth(UIElement[] order, int hidden)
    {
        bool Shown(UIElement e) => Array.IndexOf(order, e) is var i && (i < 0 || i >= hidden);
        double Row(params FrameworkElement[] items)
        {
            var shown = items.Where(Shown).ToArray();
            return shown.Sum(ItemWidth) + ToolbarSpacing * Math.Max(0, shown.Length - 1);
        }
        var separatorShown = Shown(DiscordButton) || Shown(UpdateButton);
        var right = Row(OutputMuteButton, TimerButton, MoreButton, DiscordButton, UpdateButton)
            + (separatorShown ? ItemWidth(DiscordSeparator) + ToolbarSpacing : 0);
        var left = Row(CompactButton, BackButton, ForwardButton, HomeButton, ObsButton)
            + ItemWidth(ToolbarLeftSeparator) + ToolbarSpacing;
        return left + right;
    }

    private static double ItemWidth(FrameworkElement element)
        => (double.IsFinite(element.Width) ? element.Width : element.ActualWidth)
            + (element is Rectangle ? element.Margin.Left + element.Margin.Right : 0);

    private static void SetVisible(UIElement element, bool visible)
    {
        var value = visible ? Visibility.Visible : Visibility.Collapsed;
        if (element.Visibility != value) element.Visibility = value;
    }

    // More shows an item only while its toolbar button is collapsed, with the button's current state.
    private void RefreshToolbarOverflowItems()
    {
        _equalizerMenuItem.IsChecked = _settings.Equalizer.Enabled;
        _homeOverflowItem.Visibility = HomeButton.Visibility == Visibility.Collapsed ? Visibility.Visible : Visibility.Collapsed;
        _homeOverflowItem.IsEnabled = HomeButton.IsEnabled;
        _forwardOverflowItem.Visibility = ForwardButton.Visibility == Visibility.Collapsed ? Visibility.Visible : Visibility.Collapsed;
        _forwardOverflowItem.IsEnabled = ForwardButton.IsEnabled;
        var volumeHidden = OutputMuteButton.Visibility == Visibility.Collapsed;
        _volumeOverflowItem.Visibility = volumeHidden ? Visibility.Visible : Visibility.Collapsed;
        _volumeOverflowItem.IsEnabled = OutputMuteButton.IsEnabled;
        var timerHidden = TimerButton.Visibility == Visibility.Collapsed;
        _setTimerOverflowItem.Visibility = timerHidden ? Visibility.Visible : Visibility.Collapsed;
        _setTimerOverflowItem.IsEnabled = _setTimerItem.IsEnabled;
        _cancelTimerOverflowItem.Visibility = timerHidden && _cancelTimerItem.IsEnabled ? Visibility.Visible : Visibility.Collapsed;
        _updateOverflowItem.Visibility = UpdateButton.Visibility == Visibility.Collapsed ? Visibility.Visible : Visibility.Collapsed;
        _updateOverflowItem.IsEnabled = UpdateButton.IsEnabled;
        var updateName = AutomationProperties.GetName(UpdateButton);
        _updateOverflowItem.Text = string.IsNullOrWhiteSpace(updateName) ? "Check for Nativune updates" : updateName;
        AutomationProperties.SetName(_updateOverflowItem, _updateOverflowItem.Text);
    }
}
