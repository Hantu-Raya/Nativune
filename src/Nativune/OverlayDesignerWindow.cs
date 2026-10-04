using System.Globalization;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using Microsoft.Web.WebView2.Core;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI;
using Windows.UI.Core;
using Microsoft.UI.Input;

namespace Nativune;

public sealed partial class OverlayDesignerWindow : Window
{
    private readonly WebHostWindow _owner;
    private readonly FrameworkElement? _invoker;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _draftTimer;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _sizeTimer;
    private readonly Microsoft.UI.Dispatching.DispatcherQueueTimer _statusTimer;
    private readonly NativeWindowServices _native;
    private NativeBrowserHost? _host;
    private bool _loading, _closed, _closeReady, _actionInFlight, _dialogActive, _hostOpening, _processFailed;
    private int _popupCount;
    private Task<bool>? _saveTask;
    private Guid _draftKey = Guid.NewGuid();
    private int _draftRev, _lastSavedRev;
    private string? _sourceId, _nonce;
    private string _backdrop = "checker";
    private string _customBackdrop = "#202020";
    private ObsLookOptions _options = ObsLookOptions.Defaults();
    private string _sizeSuffix = "";
    private bool _accentSeeded;
    private bool _shadowTouched;
    private SystemFonts.FontEnumerationResult _fonts;
    private Flyout? _colourFlyout;
    private ContentDialog? _activeDialog;
    private bool _overlayRunning;
    private bool _overlayOffPending;
    private string? _fontShown = "__initial__";
#if NATIVUNE_DISCORD_TEST_HOOKS
    private readonly List<object> _navigationDecisions = [];
#endif
    private bool Dirty => _draftRev > _lastSavedRev;
    internal CoreWebView2? Core
    {
        get { try { return _host?.Core; } catch (Exception) { return null; } }
    }

    public OverlayDesignerWindow(WebHostWindow owner, FrameworkElement? invoker)
    {
        InitializeComponent();
        _owner = owner;
        _overlayRunning = owner.DesignerOverlayRunning;
        _invoker = invoker;
        _fonts = SystemFonts.Enumerate();
        ShellTheme.ApplyToWindow(this);
        var hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        _native = new NativeWindowServices(hwnd, HandleNativeMessage);
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1280, 800));
        AppWindow.Closing += (sender, args) =>
        {
            if (_closeReady) return;
            args.Cancel = true;
            _ = RequestCloseAsync();
        };
        Closed += (_, _) =>
        {
            DisposePreview();
            _owner.DesignerReturnFocus(_invoker);
        };
        _draftTimer = DispatcherQueue.CreateTimer();
        _draftTimer.Interval = TimeSpan.FromMilliseconds(100);
        _draftTimer.IsRepeating = false;
        _draftTimer.Tick += (_, _) => PublishDraft();
        _sizeTimer = DispatcherQueue.CreateTimer();
        _sizeTimer.Interval = TimeSpan.FromMilliseconds(300);
        _sizeTimer.IsRepeating = false;
        _sizeTimer.Tick += (_, _) =>
        {
            var previous = SourceSizeText.Text;
            UpdateSize();
            if (SourceSizeText.Text != previous) Announce(SourceSizeText);
        };
        _statusTimer = DispatcherQueue.CreateTimer();
        _statusTimer.Interval = TimeSpan.FromMilliseconds(500);
        _statusTimer.Tick += (_, _) => RefreshPreviewStatus();
        Root.Loaded += (_, _) =>
        {
            if (SavedLooksList.Items.Count > 0) SavedLooksList.Focus(FocusState.Programmatic);
            else NewLookButton.Focus(FocusState.Programmatic);
        };
        Root.KeyDown += OnKeyDown;
        ConfigureControls();
        RefreshSavedLooks();
        var first = _owner.DesignerLooks.Looks.FirstOrDefault();
        LoadDraft(first);
    }

    private void ConfigureControls()
    {
        Fill(ThemePicker, Enum.GetValues<ObsLookTheme>().Select(x => (x.ToWire(), ThemeName(x))));
        Fill(AlignPicker, [("left", "Left"), ("center", "Centre"), ("right", "Right")]);
        Fill(ColoursPicker, [("auto", "Automatic"), ("custom", "Custom")]);
        Fill(PausedPicker, [("hide", "Hide"), ("dim", "Dim")]);
        foreach (var picker in new[] { ShowAnimationPicker, HideAnimationPicker })
            Fill(picker, Enum.GetValues<ObsLookAnimation>().Select(x => (x.ToWire(), x.ToWire().Replace('-', ' '))));
        Fill(PreviewSongSourcePicker, [("sample", "Sample song"), ("real", "Current song")]);
        Fill(PreviewStatePicker, [("playing", "Playing"), ("paused", "Paused"), ("noart", "No artwork")]);
        Fill(PreviewBackgroundPicker, [("checker", "Checkerboard"), ("dark", "Dark"), ("light", "Light"), ("custom", "Choose colour…")]);
        _loading = true;
        PreviewSongSourcePicker.SelectedIndex = PreviewStatePicker.SelectedIndex = PreviewBackgroundPicker.SelectedIndex = 0;
        _loading = false;
        foreach (var picker in new[] { ThemePicker, FontPicker, AlignPicker, ColoursPicker, PausedPicker,
            ShowAnimationPicker, HideAnimationPicker, PreviewSongSourcePicker, PreviewStatePicker, PreviewBackgroundPicker })
        {
            picker.DropDownOpened += (_, _) => PopupOpened();
            picker.DropDownClosed += (_, _) => PopupClosed();
        }
        NewLookButton.Click += async (_, _) => await AbandonAsync(() => LoadDraft(null));
        DuplicateLookButton.Click += async (_, _) =>
        {
            var selected = SelectedSaved();
            if (selected is null) return;
            await AbandonAsync(() =>
            {
                var units = Math.Min(33, selected.Name.Length);
                if (units < selected.Name.Length && char.IsHighSurrogate(selected.Name[units - 1])) units--;
                var name = selected.Name[..units] + " (copy)";
                LoadDraft(selected with { Name = name }, duplicate: true);
            });
        };
        RenameLookButton.Click += (_, _) => { LookNameBox.Focus(FocusState.Programmatic); LookNameBox.SelectAll(); };
        DeleteLookButton.Click += async (_, _) => await DeleteAsync();
        RevertChangesButton.Click += async (_, _) => await RevertAsync();
        SaveLookButton.Click += async (_, _) => await SaveAsync();
        CopyLinkButton.Click += (_, _) => CopyLink();
        ReloadLooksButton.Click += async (_, _) =>
        {
            if (!await SettleCommitAsync()) return;
            await _owner.DesignerReloadAsync();
            RefreshSavedLooks();
        };
        SavedLooksList.SelectionChanged += async (_, _) =>
        {
            if (_loading || _closed || _actionInFlight) return;
            var selected = SelectedSaved();
            if (selected?.Id == _sourceId) return;
            if (!await AbandonAsync(() => LoadDraft(selected))) RestoreSelection();
        };
        LookNameBox.TextChanged += (_, _) => { if (!_loading) Edited(); };
        LookNameBox.LostFocus += (_, _) => ValidateName(false);
        ThemePicker.SelectionChanged += (_, _) =>
        {
            if (_loading || !ObsLookWire.TryParse(Value(ThemePicker), out ObsLookTheme theme)) return;
            var old = _options;
            _options = old with
            {
                Theme = theme,
                Width = ObsLookValidation.DefaultWidth(theme, old.Scale),
                Align = old.Align == ObsLookOptions.DefaultAlign(old.Theme) ? ObsLookOptions.DefaultAlign(theme) : old.Align,
                TextShadow = !_shadowTouched && old.TextShadow == ObsLookOptions.DefaultTextShadow(old.Theme) ? ObsLookOptions.DefaultTextShadow(theme) : old.TextShadow,
            };
            _sizeSuffix = _options.Width != old.Width ? $" Width set to {_options.Width} for this text size." : "";
            SyncEditor(); Edited();
        };
        FontPicker.SelectionChanged += (_, _) =>
        {
            if (_loading) return;
            _options = _options with { Font = Value(FontPicker) is "" ? null : Value(FontPicker) };
            _fontShown = _options.Font;
            UpdateFontStatus(); Edited();
        };
        AlignPicker.SelectionChanged += (_, _) => { if (!_loading && ObsLookWire.TryParse(Value(AlignPicker), out ObsLookAlign x)) { _options = _options with { Align = x }; Edited(); } };
        ColoursPicker.SelectionChanged += async (_, _) =>
        {
            if (_loading || !ObsLookWire.TryParse(Value(ColoursPicker), out ObsLookColours mode)) return;
            var seed = mode == ObsLookColours.Custom && !_accentSeeded
                && _options.Text == ObsLookOptions.DefaultText(_options.Theme)
                && _options.Background == ObsLookOptions.DefaultBackground(_options.Theme)
                && _options.Accent == ObsLookOptions.DefaultAccent;
            _options = _options with { Colours = mode }; SyncEditor(); Edited();
            if (!seed) return;
            _accentSeeded = true;
            var key = _draftKey; var rev = _draftRev;
            try
            {
                if (_host is { } host)
                {
                    var json = await host.Core.ExecuteScriptAsync("window.__state && window.__state.accent");
                    var sampled = System.Text.Json.JsonSerializer.Deserialize<string>(json);
                    if (!_closed && key == _draftKey && rev == _draftRev && ObsLookValidation.NormalizeColour(sampled) is { } colour)
                    {
                        _options = _options with { Accent = colour }; SyncEditor(); Edited();
                    }
                }
            }
            catch (Exception) { }
        };
        PausedPicker.SelectionChanged += (_, _) => { if (!_loading && ObsLookWire.TryParse(Value(PausedPicker), out ObsLookPaused x)) { _options = _options with { Paused = x }; Edited(); } };
        ShowAnimationPicker.SelectionChanged += (_, _) => { if (!_loading && ObsLookWire.TryParse(Value(ShowAnimationPicker), out ObsLookAnimation x)) { _options = _options with { ShowAnimation = x }; Edited(); } };
        HideAnimationPicker.SelectionChanged += (_, _) => { if (!_loading && ObsLookWire.TryParse(Value(HideAnimationPicker), out ObsLookAnimation x)) { _options = _options with { HideAnimation = x }; Edited(); } };
        WireNumber(ScaleSlider, ScaleBox, 5, x =>
        {
            var range = ObsLookValidation.WidthRange(_options.Theme, x);
            var width = Math.Clamp(_options.Width, range.Min, range.Max);
            _sizeSuffix = width != _options.Width ? $" Width set to {width} for this text size." : "";
            _options = _options with { Scale = x, Width = width }; SyncEditor(); Edited();
        });
        WireNumber(WidthSlider, WidthBox, 10, x => { _sizeSuffix = ""; _options = _options with { Width = x }; SyncEditor(); Edited(); });
        WireNumber(OpacitySlider, OpacityBox, 1, x => { _options = _options with { BackgroundOpacity = x }; SyncEditor(); Edited(); });
        WireToggle(TextShadowToggle, x => { _shadowTouched = true; return _options with { TextShadow = x }; });
        WireToggle(ShowArtToggle, x => _options with { ShowArt = x });
        WireToggle(ShowArtistToggle, x => _options with { ShowArtist = x });
        WireToggle(ShowProgressToggle, x => _options with { ShowProgress = x });
        WireToggle(ShowTimesToggle, x => _options with { ShowTimes = x });
        WireColour(TextHexBox, TextColourError, ChooseTextColourButton, () => _options.Text, x => _options = _options with { Text = x });
        WireColour(BackgroundHexBox, BackgroundColourError, ChooseBackgroundColourButton, () => _options.Background, x => _options = _options with { Background = x });
        WireColour(AccentHexBox, AccentColourError, ChooseAccentColourButton, () => _options.Accent, x => _options = _options with { Accent = x });
        PreviewSongSourcePicker.SelectionChanged += (_, _) => { if (!_loading) { PreviewStatePicker.Visibility = Value(PreviewSongSourcePicker) == "sample" ? Visibility.Visible : Visibility.Collapsed; NavigatePreview(); } };
        PreviewStatePicker.SelectionChanged += (_, _) => { if (!_loading) NavigatePreview(); };
        PreviewBackgroundPicker.SelectionChanged += (_, _) =>
        {
            if (_loading) return;
            var value = Value(PreviewBackgroundPicker);
            if (value == "custom")
            {
                _loading = true;
                Select(PreviewBackgroundPicker, _backdrop.StartsWith('#') ? "selected-custom" : _backdrop);
                _loading = false;
                OpenColourFlyout(PreviewBackgroundPicker, _customBackdrop, colour =>
                {
                    _backdrop = _customBackdrop = colour;
                    var item = PreviewBackgroundPicker.Items.OfType<ComboBoxItem>().FirstOrDefault(x => (string)x.Tag == "selected-custom");
                    if (item is null) { item = new ComboBoxItem { Tag = "selected-custom" }; PreviewBackgroundPicker.Items.Add(item); }
                    item.Content = $"Custom ({colour})";
                    _loading = true; PreviewBackgroundPicker.SelectedItem = item; _loading = false;
                    PublishDraft();
                });
            }
            else { _backdrop = value == "selected-custom" ? _customBackdrop : value; PublishDraft(); }
        };
        OverlayPreviewEntry.Click += (_, _) =>
        {
            if (!_processFailed && _owner.DesignerOverlayRunning) _host?.MoveFocus(CoreWebView2MoveFocusReason.Next);
        };
        RetryPreviewButton.Click += async (_, _) =>
        {
            if (_processFailed)
            {
                _host?.Dispose(); _host = null; _processFailed = false;
                await InitializePreviewAsync();
            }
            else NavigatePreview();
        };
        foreach (var control in new Control[] { SavedLooksList, NewLookButton, DuplicateLookButton, RenameLookButton,
            DeleteLookButton, LookNameBox, ThemePicker, FontPicker, ScaleSlider, ScaleBox, WidthSlider, WidthBox,
            AlignPicker, ColoursPicker, TextHexBox, ChooseTextColourButton, BackgroundHexBox, ChooseBackgroundColourButton,
            OpacitySlider, OpacityBox, AccentHexBox, ChooseAccentColourButton, TextShadowToggle, ShowArtToggle,
            ShowArtistToggle, ShowProgressToggle, ShowTimesToggle, PausedPicker, ShowAnimationPicker, HideAnimationPicker,
            CopyLinkButton, SaveLookButton, RevertChangesButton, PreviewSongSourcePicker, PreviewStatePicker,
            PreviewBackgroundPicker, OverlayPreviewEntry, RetryPreviewButton, ReloadLooksButton })
        {
            if (!string.IsNullOrEmpty(control.Name)) AutomationProperties.SetAutomationId(control, control.Name);
            if (string.IsNullOrEmpty(AutomationProperties.GetHelpText(control)))
                AutomationProperties.SetHelpText(control, $"Edit {AutomationProperties.GetName(control)}. Changes appear in the preview; choose Save look to update OBS sources.");
        }
        AutomationProperties.SetHelpText(OverlayPreviewEntry, "Enter or Space enters the preview. Escape returns here; Tab past the preview returns to Saved looks.");
        AutomationProperties.SetHelpText(CopyLinkButton, "Copy this saved look's localhost OBS Browser Source link. Save a new look first.");
        AutomationProperties.SetHelpText(SaveLookButton, "Save this look locally and notify its connected OBS sources. Ctrl+S also saves.");
    }

    private void WireNumber(Slider slider, NumberBox box, int step, Action<int> set)
    {
        slider.SmallChange = step;
        slider.LargeChange = step * 5;
        int Snap(double value) => (int)Math.Clamp(Math.Round(value / step, MidpointRounding.AwayFromZero) * step, slider.Minimum, slider.Maximum);
        slider.ValueChanged += (_, args) => { if (!_loading) set(Snap(args.NewValue)); };
        box.ValueChanged += (_, args) => { if (!_loading && double.IsFinite(args.NewValue)) set(Snap(args.NewValue)); };
        slider.KeyDown += (_, args) =>
        {
            if (args.Key is not (VirtualKey.PageUp or VirtualKey.PageDown)) return;
            args.Handled = true;
            slider.Value = Snap(slider.Value + (args.Key == VirtualKey.PageUp ? 5 : -5) * step);
        };
    }
    private void WireToggle(CheckBox box, Func<bool, ObsLookOptions> change)
    {
        box.Checked += (_, _) => { if (!_loading) { _options = change(true); Edited(); } };
        box.Unchecked += (_, _) => { if (!_loading) { _options = change(false); Edited(); } };
    }
    private void WireColour(TextBox box, TextBlock error, Button choose, Func<string> get, Action<string> set)
    {
        box.TextChanged += (_, _) =>
        {
            if (_loading) return;
            if (ObsLookValidation.NormalizeColour(box.Text) is { } valid) set(valid);
            Edited();
        };
        box.LostFocus += (_, _) => ValidateColour(box, error, false);
        choose.Click += (_, _) => OpenColourFlyout(choose, get(), colour =>
        {
            set(colour); _loading = true; box.Text = colour; _loading = false;
            ClearError(box, error); SyncEditor(); Edited();
        });
    }
    private void OpenColourFlyout(FrameworkElement anchor, string initial, Action<string> apply)
    {
        _colourFlyout?.Hide();
        var picker = new ColorPicker { Color = ParseColour(initial), IsAlphaEnabled = false, IsAlphaSliderVisible = false, IsAlphaTextInputVisible = false };
        AutomationProperties.SetName(picker, "Colour picker"); AutomationProperties.SetAutomationId(picker, "ColourPicker");
        var ok = new Button { Content = "Apply" }; var cancel = new Button { Content = "Cancel" };
        AutomationProperties.SetName(ok, "Apply colour"); AutomationProperties.SetAutomationId(ok, "ColourApplyButton");
        AutomationProperties.SetName(cancel, "Cancel colour"); AutomationProperties.SetAutomationId(cancel, "ColourCancelButton");
        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
        buttons.Children.Add(ok); buttons.Children.Add(cancel);
        var panel = new StackPanel { Spacing = 12 }; panel.Children.Add(picker); panel.Children.Add(buttons);
        var flyout = new Flyout { Content = panel };
        _colourFlyout = flyout;
        ok.Click += (_, _) => { apply($"#{picker.Color.R:x2}{picker.Color.G:x2}{picker.Color.B:x2}"); flyout.Hide(); };
        cancel.Click += (_, _) => flyout.Hide();
        panel.KeyDown += (_, args) => { if (args.Key == VirtualKey.Escape) { args.Handled = true; flyout.Hide(); } };
        flyout.Opening += (_, _) => PopupOpened();
        flyout.Closed += (_, _) => { if (ReferenceEquals(_colourFlyout, flyout)) _colourFlyout = null; PopupClosed(); if (anchor is Control c) c.Focus(FocusState.Programmatic); };
        flyout.ShowAt(anchor);
    }

    private void LoadDraft(ObsLook? saved, bool duplicate = false)
    {
        _draftKey = Guid.NewGuid(); _draftRev = duplicate ? 1 : 0; _lastSavedRev = 0;
        _sourceId = duplicate ? null : saved?.Id;
        _options = saved?.Options ?? ObsLookOptions.Defaults();
        _sizeSuffix = ""; _accentSeeded = false; _shadowTouched = false;
        _loading = true; LookNameBox.Text = saved?.Name ?? "New look"; _loading = false;
        ClearError(LookNameBox, NameError);
        foreach (var (box, error) in ColourFields()) ClearError(box, error);
        SyncEditor(resetColours: true); RestoreSelection(); PublishDraft();
    }
    private void SyncEditor(bool resetColours = false)
    {
        _options = ObsLookValidation.Normalize(_options);
        _loading = true;
        Select(ThemePicker, _options.Theme.ToWire());
        if (_fontShown != _options.Font) { PopulateFonts(); _fontShown = _options.Font; }
        Select(AlignPicker, _options.Align.ToWire()); Select(ColoursPicker, _options.Colours.ToWire());
        Select(PausedPicker, _options.Paused.ToWire()); Select(ShowAnimationPicker, _options.ShowAnimation.ToWire()); Select(HideAnimationPicker, _options.HideAnimation.ToWire());
        ScaleSlider.Value = ScaleBox.Value = _options.Scale;
        var range = ObsLookValidation.WidthRange(_options.Theme, _options.Scale);
        WidthSlider.Minimum = WidthBox.Minimum = range.Min; WidthSlider.Maximum = WidthBox.Maximum = range.Max;
        WidthSlider.Value = WidthBox.Value = _options.Width;
        OpacitySlider.Value = OpacityBox.Value = _options.BackgroundOpacity;
        if (resetColours || ObsLookValidation.NormalizeColour(TextHexBox.Text) is not null) TextHexBox.Text = _options.Text;
        if (resetColours || ObsLookValidation.NormalizeColour(BackgroundHexBox.Text) is not null) BackgroundHexBox.Text = _options.Background;
        if (resetColours || ObsLookValidation.NormalizeColour(AccentHexBox.Text) is not null) AccentHexBox.Text = _options.Accent;
        TextShadowToggle.IsChecked = _options.TextShadow; ShowArtToggle.IsChecked = _options.ShowArt;
        ShowArtistToggle.IsChecked = _options.ShowArtist; ShowProgressToggle.IsChecked = _options.ShowProgress; ShowTimesToggle.IsChecked = _options.ShowTimes;
        var custom = _options.Colours == ObsLookColours.Custom;
        TextColourRow.Visibility = custom ? Visibility.Visible : Visibility.Collapsed;
        BackgroundColourRow.Visibility = custom && ObsLookOptions.Applies(_options.Theme, ObsLookOption.Background) ? Visibility.Visible : Visibility.Collapsed;
        OpacityRow.Visibility = BackgroundColourRow.Visibility;
        AccentColourRow.Visibility = custom && ObsLookOptions.Applies(_options.Theme, ObsLookOption.Accent) ? Visibility.Visible : Visibility.Collapsed;
        ShowArtToggle.Visibility = ObsLookOptions.Applies(_options.Theme, ObsLookOption.ShowArt) ? Visibility.Visible : Visibility.Collapsed;
        ShowTimesToggle.Visibility = ObsLookOptions.Applies(_options.Theme, ObsLookOption.ShowTimes) ? Visibility.Visible : Visibility.Collapsed;
        SmallTextWarning.Visibility = _options.Scale < 80 ? Visibility.Visible : Visibility.Collapsed;
        TextSwatch.Background = new SolidColorBrush(ParseColour(_options.Text));
        BackgroundSwatch.Background = new SolidColorBrush(ParseColour(_options.Background));
        AccentSwatch.Background = new SolidColorBrush(ParseColour(_options.Accent));
        ColourModeHelp.Text = custom && _options.Theme is ObsLookTheme.Standard or ObsLookTheme.Classic or ObsLookTheme.Card
            ? "Custom colours use a flat panel instead of blurred artwork." : "";
        _loading = false;
        if (resetColours) UpdateSize();
        UpdateContrast(); RefreshButtons();
    }
    private void PopulateFonts()
    {
        FontPicker.Items.Clear();
        FontPicker.Items.Add(new ComboBoxItem { Content = "Theme default", Tag = "" });
        foreach (var font in _fonts.Families) FontPicker.Items.Add(new ComboBoxItem { Content = font.Display, Tag = font.Canonical });
        if (_options.Font is { } saved && !_fonts.Families.Any(x => x.Canonical == saved))
            FontPicker.Items.Add(new ComboBoxItem { Content = saved, Tag = saved });
        Select(FontPicker, _options.Font ?? "");
        UpdateFontStatus();
    }
    private void UpdateFontStatus()
    {
        FontStatusText.Text = _fonts.Failed ? "Installed fonts could not be listed" : _fonts.Truncated ? "Some fonts are not listed" : "";
        if (_options.Font is { } fontName && !SystemFonts.IsInstalled(fontName))
            FontStatusText.Text += (FontStatusText.Text.Length > 0 ? ". " : "") + "Font unavailable; using the theme's default";
    }
    private void Edited()
    {
        if (_loading || _closed) return;
        _draftRev++;
        _draftTimer.Stop(); _draftTimer.Start(); _sizeTimer.Stop(); _sizeTimer.Start();
        UpdateContrast(); RefreshButtons();
    }
    private void UpdateSize()
    {
        var (w, h) = ObsLookLayout.SourceSize(_options);
        SourceSizeText.Text = $"Set OBS source size to {w} by {h} pixels." + _sizeSuffix;
        AutomationProperties.SetName(SourceSizeText, SourceSizeText.Text);
    }
    private void UpdateContrast()
    {
        var theme = _options.Theme;
        if (theme == ObsLookTheme.Simple)
        {
            ContrastText.Text = "No background: contrast depends on your OBS scene; Text shadow is on by default";
            return;
        }
        var custom = _options.Colours == ObsLookColours.Custom;
        var foreground = custom ? _options.Text : ObsLookOptions.DefaultText(theme);
        var background = theme == ObsLookTheme.Pill ? "#202020" : custom ? _options.Background : ObsLookOptions.DefaultBackground(theme);
        var a = Luminance(ParseColour(foreground)); var b = Luminance(ParseColour(background));
        var ratio = (Math.Max(a, b) + .05) / (Math.Min(a, b) + .05);
        ContrastText.Text = $"Contrast {ratio.ToString("0.0", CultureInfo.InvariantCulture)}:1";
        if (ratio < 4.5) ContrastText.Text += " — below 4.5:1; consider Text shadow or other colours";
        if (theme == ObsLookTheme.Pill) ContrastText.Text += ". Depends on the artwork";
        if (theme is ObsLookTheme.Standard or ObsLookTheme.Classic or ObsLookTheme.Card or ObsLookTheme.AlbumArt
            || _options.BackgroundOpacity < 100 || _options.Paused == ObsLookPaused.Dim)
            ContrastText.Text += ". Contrast depends on the artwork, transparency, paused dimming and your OBS scene; this is not a contrast guarantee over video.";
        ContrastText.Text += " Secondary text is lighter.";
    }
    private static double Luminance(Color c)
    {
        static double Linear(byte x) { var s = x / 255d; return s <= .04045 ? s / 12.92 : Math.Pow((s + .055) / 1.055, 2.4); }
        return .2126 * Linear(c.R) + .7152 * Linear(c.G) + .0722 * Linear(c.B);
    }
    private static Color ParseColour(string value) => Color.FromArgb(255,
        byte.Parse(value.AsSpan(1, 2), NumberStyles.HexNumber), byte.Parse(value.AsSpan(3, 2), NumberStyles.HexNumber), byte.Parse(value.AsSpan(5, 2), NumberStyles.HexNumber));
    private void RefreshButtons()
    {
        SaveLookButton.IsEnabled = _saveTask is not { IsCompleted: false } && !_owner.DesignerCommitInFlight;
        CopyLinkButton.IsEnabled = _sourceId is not null;
        DuplicateLookButton.IsEnabled = RenameLookButton.IsEnabled = DeleteLookButton.IsEnabled = SelectedSaved() is not null;
    }
    internal void RefreshSavedLooks()
    {
        if (_closed) return;
        _loading = true;
        SavedLooksList.Items.Clear();
        foreach (var look in _owner.DesignerLooks.Looks)
        {
            var count = _owner.DesignerCounts?.ByLook.GetValueOrDefault(look.Id) ?? 0;
            var row = new ListViewItem { Content = $"{look.Name} — {count} connected", Tag = look.Id };
            AutomationProperties.SetName(row, $"{look.Name}, {ThemeName(look.Options.Theme)}, {count} connected");
            AutomationProperties.SetHelpText(row, "Select this saved look to edit it.");
            SavedLooksList.Items.Add(row);
        }
        _loading = false; RestoreSelection(); RefreshButtons();
        StoreStatusText.Text = _owner.DesignerLooks.ReadOnlyReason ?? "";
        ReloadLooksButton.Visibility = _owner.DesignerLooks.IsReadOnly ? Visibility.Visible : Visibility.Collapsed;
        var missing = _owner.DesignerCounts?.MissingLooks ?? 0;
        MissingLooksText.Text = missing == 0 ? "" : missing == 1 ? "1 source uses a deleted look" : $"{missing} sources use a deleted look";
    }
    private ObsLook? SelectedSaved() => SavedLooksList.SelectedItem is ListViewItem { Tag: string id } ? _owner.DesignerLooks.Find(id) : null;
    private void RestoreSelection()
    {
        _loading = true;
        SavedLooksList.SelectedItem = SavedLooksList.Items.OfType<ListViewItem>().FirstOrDefault(x => (string)x.Tag == _sourceId);
        _loading = false;
    }
    private IEnumerable<(TextBox Box, TextBlock Error)> ColourFields()
    {
        yield return (TextHexBox, TextColourError); yield return (BackgroundHexBox, BackgroundColourError); yield return (AccentHexBox, AccentColourError);
    }
    private bool ValidateName(bool focus)
    {
        if (ObsLookValidation.TryNormalizeName(LookNameBox.Text, out _)) { ClearError(LookNameBox, NameError); return true; }
        SetError(LookNameBox, NameError, "Enter a look name of 1 to 40 characters without control or formatting characters.", focus); return false;
    }
    private static bool ValidateColour(TextBox box, TextBlock error, bool focus)
    {
        if (ObsLookValidation.NormalizeColour(box.Text) is not null) { ClearError(box, error); return true; }
        SetError(box, error, "Enter a colour as #RRGGBB", focus); return false;
    }
    private static void ClearError(Control box, TextBlock error)
    {
        error.Text = ""; error.Visibility = Visibility.Collapsed;
        AutomationProperties.GetDescribedBy(box).Clear();
    }
    private static void SetError(Control box, TextBlock error, string message, bool focus)
    {
        error.Text = message; error.Visibility = Visibility.Visible;
        AutomationProperties.GetDescribedBy(box).Clear(); AutomationProperties.GetDescribedBy(box).Add(error);
        if (focus) box.Focus(FocusState.Programmatic);
    }
    private bool ValidateDraft()
    {
        if (!ValidateName(true)) return false;
        foreach (var (box, error) in ColourFields())
            if (box.Visibility == Visibility.Visible && box.Parent is FrameworkElement { Visibility: Visibility.Visible } && !ValidateColour(box, error, true)) return false;
        return true;
    }
    internal void RefreshCommitState() { if (!_closed) RefreshButtons(); }
    private Task<bool> SaveAsync()
    {
        if (_saveTask is { IsCompleted: false }) return _saveTask;
        if (_owner.DesignerCommitInFlight || _closed) return Task.FromResult(false);
        if (!ValidateDraft()) return Task.FromResult(false);
        // Start synchronously disabling the button; only this task captures the revision and owns this Save.
        SaveLookButton.IsEnabled = false;
        _saveTask = SaveCoreAsync();
        return _saveTask;
    }
    private async Task<bool> SaveCoreAsync()
    {
        var key = _draftKey; var rev = _draftRev; var id = _sourceId; var options = _options; var name = LookNameBox.Text;
        try
        {
            var result = await _owner.DesignerSaveAsync(id, name, options);
            if (_closed) return result.Committed;
            if (result.Committed && key == _draftKey) { _sourceId = result.Id; _lastSavedRev = rev; }
            RefreshSavedLooks(); ReportCommitResult(result);
            return result.Committed;
        }
        finally { if (!_closed) SaveLookButton.IsEnabled = true; }
    }
    private async Task<bool> SettleCommitAsync()
    {
        if (!_owner.DesignerCommitInFlight && _saveTask is not { IsCompleted: false }) return true;
        var ownSave = _saveTask is { IsCompleted: false } ? _saveTask : null;
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "Saving…", Content = "Waiting for the look to finish saving." };
        _activeDialog = dialog; _dialogActive = true; UpdateHostVisibility();
        var shown = dialog.ShowAsync();
        try
        {
            var settled = await _owner.DesignerWaitForCommitAsync();
            if (ownSave is { } saving) await saving;
            if (!settled && ownSave is null) Report("Could not save; OBS sources are unchanged.");
            return settled;
        }
        finally { dialog.Hide(); await shown; if (ReferenceEquals(_activeDialog, dialog)) _activeDialog = null; _dialogActive = false; UpdateHostVisibility(); }
    }
    private async Task<bool> AbandonAsync(Action action)
    {
        if (_actionInFlight || _closed) return false;
        _actionInFlight = true;
        try
        {
            if (!await SettleCommitAsync()) return false;
            while (Dirty && !_closed)
            {
                var choice = await PromptAsync($"Save changes to '{LookNameBox.Text}'?", "Save", "Discard", "Cancel");
                if (choice == ContentDialogResult.None) return false;
                if (choice == ContentDialogResult.Secondary) break;
                if (!await SaveAsync()) return false;
                // An edit made during this Save belongs to the live draft, not the committed revision.
            }
            if (_closed) return false;
            action(); return true;
        }
        finally { FinishAction(); }
    }
    private async Task RevertAsync()
    {
        if (_actionInFlight || _closed) return;
        _actionInFlight = true;
        try
        {
            if (!await SettleCommitAsync()) return;
            if (Dirty && await PromptAsync($"Discard changes to '{LookNameBox.Text}'?", "Discard", "", "Cancel") != ContentDialogResult.Primary) return;
            LoadDraft(_sourceId is { } id ? _owner.DesignerLooks.Find(id) : null);
        }
        finally { FinishAction(); }
    }
    private async Task DeleteAsync()
    {
        var target = SelectedSaved();
        if (target is null || _actionInFlight || _closed) return;
        _actionInFlight = true;
        try
        {
            if (!await SettleCommitAsync()) return;
            while (target.Id != _sourceId && Dirty && !_closed)
            {
                var choice = await PromptAsync($"Save changes to '{LookNameBox.Text}'?", "Save", "Discard", "Cancel");
                if (choice == ContentDialogResult.None) return;
                if (choice == ContentDialogResult.Secondary) break;
                if (!await SaveAsync()) return;
            }
            var suffix = target.Id == _sourceId && Dirty ? " Unsaved changes will be discarded." : "";
            if (await PromptAsync($"Delete '{target.Name}'?{suffix}", "Delete", "", "Cancel") != ContentDialogResult.Primary) return;
            if (_closed) return;
            EditorScroll.IsEnabled = false; LookNameBox.IsReadOnly = true;
            var deleting = new ContentDialog { XamlRoot = Root.XamlRoot, Title = "Deleting…", Content = "Waiting for the look to finish deleting." };
            _activeDialog = deleting; _dialogActive = true; UpdateHostVisibility();
            var shown = deleting.ShowAsync();
            WebHostWindow.DesignerCommitResult result;
            try { result = await _owner.DesignerDeleteAsync(target.Id); }
            finally
            {
                deleting.Hide(); await shown;
                if (ReferenceEquals(_activeDialog, deleting)) _activeDialog = null;
                _dialogActive = false;
                if (!_closed) { EditorScroll.IsEnabled = true; LookNameBox.IsReadOnly = false; UpdateHostVisibility(); }
            }
            if (_closed) return;
            if (result.Committed)
            {
                RefreshSavedLooks(); LoadDraft(_owner.DesignerLooks.Looks.FirstOrDefault());
                if (SavedLooksList.Items.Count == 0) NewLookButton.Focus(FocusState.Programmatic);
                else SavedLooksList.Focus(FocusState.Programmatic);
            }
            ReportCommitResult(result);
        }
        finally { FinishAction(); if (!_closed) RefreshButtons(); }
    }
    private void ReportCommitResult(WebHostWindow.DesignerCommitResult result)
    {
        Report(result.Message);
        if (!result.Committed && result.Detail is { } detail)
        {
            StoreStatusText.Text = detail;
        }
    }
    private async Task<ContentDialogResult> PromptAsync(string title, string primary, string secondary, string close)
    {
        if (_closed) return ContentDialogResult.None;
        _dialogActive = true; UpdateHostVisibility();
        var dialog = new ContentDialog { XamlRoot = Root.XamlRoot, Title = title, PrimaryButtonText = primary,
            SecondaryButtonText = secondary, CloseButtonText = close, DefaultButton = ContentDialogButton.Close };
        _activeDialog = dialog;
        try { return await dialog.ShowAsync(); }
        finally { if (ReferenceEquals(_activeDialog, dialog)) _activeDialog = null; _dialogActive = false; UpdateHostVisibility(); }
    }
    private void CopyLink()
    {
        if (_sourceId is null) return;
        try { var data = new DataPackage(); data.SetText($"http://localhost:47813/?look={_sourceId}"); Clipboard.SetContent(data); Report("Link copied."); }
        catch (Exception) { Report("Could not copy the link."); }
    }
    private void Report(string text)
    {
        if (_closed) return;
        DesignerResult.Text = text;
        AutomationProperties.SetName(DesignerResult, text);
        Announce(DesignerResult);
    }
    private static void Announce(FrameworkElement element) => (FrameworkElementAutomationPeer.FromElement(element)
        ?? FrameworkElementAutomationPeer.CreatePeerForElement(element))?.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);

    internal async Task InitializePreviewAsync()
    {
        if (_closed || _hostOpening || !_owner.DesignerOverlayRunning || _owner.DesignerEnvironment is not { } environment) return;
        _hostOpening = true;
        NativeBrowserHost? created = null;
        try
        {
#if NATIVUNE_DISCORD_TEST_HOOKS
            if (int.TryParse(Environment.GetEnvironmentVariable("NATIVUNE_TEST_OBS_DESIGNER_HOST_DELAY_MS"), out var delay))
                await Task.Delay(Math.Clamp(delay, 0, 30000), _lifetime.Token);
#endif
            created = await NativeBrowserHost.CreateAsync(environment, WinRT.Interop.WindowNative.GetWindowHandle(this), PreviewSlot, _lifetime.Token, task => _ = ObserveCleanupAsync(task));
            if (_closed || !_owner.DesignerOverlayRunning) { created.Dispose(); created = null; return; }
            var core = created.Core;
            core.Settings.AreHostObjectsAllowed = false; core.Settings.IsWebMessageEnabled = false;
            core.MemoryUsageTargetLevel = CoreWebView2MemoryUsageTargetLevel.Low;
            core.NavigationStarting += (_, args) =>
            {
                var allowed = IsAllowedPreviewNavigation(args.Uri);
                args.Cancel = !allowed;
                RecordDecision("navigation", args.Uri, allowed);
            };
            core.NewWindowRequested += (_, args) => { args.Handled = true; RecordDecision("new-window", args.Uri, false); };
            core.DownloadStarting += (_, args) => { args.Cancel = true; RecordDecision("download", null, false); };
            core.PermissionRequested += (_, args) => { args.State = CoreWebView2PermissionState.Deny; RecordDecision("permission", null, false); };
            core.LaunchingExternalUriScheme += (_, args) => { args.Cancel = true; RecordDecision("external-scheme", args.Uri, false); };
            var attachedHost = created;
            core.ProcessFailed += (_, _) => DispatcherQueue.TryEnqueue(() =>
            {
                if (_closed || !ReferenceEquals(_host, attachedHost)) return;
                _processFailed = true;
                _owner.DesignerPreviewStopped(_nonce);
                RefreshPreviewStatus();
            });
            created.MoveFocusRequested += (_, args) =>
            {
                args.Handled = true;
                if (args.Reason == CoreWebView2MoveFocusReason.Previous) OverlayPreviewEntry.Focus(FocusState.Programmatic);
                else SavedLooksList.Focus(FocusState.Programmatic);
            };
            created.AcceleratorKeyPressed += (_, args) =>
            {
                if (args.KeyEventKind != CoreWebView2KeyEventKind.KeyDown) return;
                if (args.VirtualKey == (uint)VirtualKey.Escape)
                {
                    args.Handled = true;
                    DispatcherQueue.TryEnqueue(() => OverlayPreviewEntry.Focus(FocusState.Programmatic));
                }
                else if (args.VirtualKey == (uint)VirtualKey.S && IsControlDown())
                {
                    args.Handled = true; DispatcherQueue.TryEnqueue(async () => await SaveAsync());
                }
            };
            created.SetVisible(false);
            _host = created; created = null;
            UpdateHostVisibility(); NavigatePreview(); _statusTimer.Start();
        }
        catch (OperationCanceledException) { }
        catch (Exception) { if (!_closed) { _processFailed = true; RefreshPreviewStatus(); } }
        finally { created?.Dispose(); _hostOpening = false; }
    }
    private static async Task ObserveCleanupAsync(Task task) { try { await task; } catch (Exception) { } }
    private bool IsAllowedPreviewNavigation(string? text)
    {
        if (_nonce is null || !Uri.TryCreate(text, UriKind.Absolute, out var uri)) return false;
        if (uri.Scheme != "http" || uri.Host != "localhost" || uri.Port != 47813 || uri.UserInfo.Length != 0 || uri.AbsolutePath != "/" || uri.Fragment.Length != 0) return false;
        var exact = $"?look=draft&preview=1&pv={_nonce}";
        return uri.Query == exact || uri.Query == exact + "&sample=playing" || uri.Query == exact + "&sample=paused" || uri.Query == exact + "&sample=noart";
    }
    private void NavigatePreview()
    {
        if (_closed || _processFailed || !_owner.DesignerOverlayRunning || _host is null) return;
        _nonce = Convert.ToHexString(RandomNumberGenerator.GetBytes(4)).ToLowerInvariant();
        PublishDraft();
        var sample = Value(PreviewSongSourcePicker) == "sample" ? "&sample=" + Value(PreviewStatePicker) : "";
        try { _host.Core.Navigate($"http://localhost:47813/?look=draft&preview=1&pv={_nonce}{sample}"); }
        catch (Exception)
        {
            _processFailed = true;
            _owner.DesignerPreviewStopped(_nonce);
        }
        RefreshPreviewStatus();
    }
    private void PublishDraft()
    {
        if (!_closed) _owner.DesignerSetDraft(new ObsLook("draft", LookNameBox.Text, _options), _backdrop, _nonce);
    }
    private void RefreshPreviewStatus()
    {
        if (_closed) return;
        var state = !_owner.DesignerOverlayRunning ? "Off" : _processFailed ? "Stopped" : _owner.DesignerPreviewState(_nonce);
        DesignerPreviewStatus.Text = state switch
        {
            "Open" => "Preview connected",
            "Refused503" => "The preview can't connect: 8 sources are already connected to the overlay. Close one in OBS, then choose Retry.",
            "Stopped" => "The preview stopped.", "Off" => "Overlay off", _ => "Connecting…",
        };
        RetryPreviewButton.Visibility = state is "Refused503" or "Stopped" ? Visibility.Visible : Visibility.Collapsed;
        UpdateHostVisibility();
    }
    internal void OverlayAvailabilityChanged()
    {
        if (_closed) return;
        RefreshPreviewStatus();
        if (_overlayRunning == _owner.DesignerOverlayRunning) return;
        _overlayRunning = _owner.DesignerOverlayRunning;
        if (_owner.DesignerOverlayRunning)
        {
            _overlayOffPending = false;
            if (_host is null) _ = InitializePreviewAsync(); else NavigatePreview();
        }
        else { _overlayOffPending = true; _ = OverlayOffAsync(); }
    }
    private async Task OverlayOffAsync()
    {
        if (_actionInFlight || _closed) return;
        _actionInFlight = true;
        _overlayOffPending = false;
        try
        {
            if (!await SettleCommitAsync() || _closed || _owner.DesignerOverlayRunning) return;
            do
            {
                var choice = await PromptAsync("The overlay was turned off.", "Save", "Discard", "Cancel");
                if (choice == ContentDialogResult.None) return;
                if (choice == ContentDialogResult.Secondary) { CloseNow(); return; }
                if (!await SaveAsync()) return;
            } while (Dirty && !_closed);
            if (!_closed) CloseNow();
        }
        finally { FinishAction(); }
    }
    private void FinishAction()
    {
        _actionInFlight = false;
        if (_overlayOffPending && !_closed && !_owner.DesignerOverlayRunning)
            DispatcherQueue.TryEnqueue(() => { _ = OverlayOffAsync(); });
    }
    internal async Task RequestCloseAsync()
    {
        if (_colourFlyout is { } flyout) { flyout.Hide(); return; }
        await AbandonAsync(CloseNow);
    }
    private void CloseNow() { _closeReady = true; DisposePreview(); Close(); }
    internal void Shutdown() { if (!_closed) CloseNow(); }
    private void DisposePreview()
    {
        if (_closed) return;
        _closed = true;
        _activeDialog?.Hide(); _activeDialog = null;
        _lifetime.Cancel();
        _draftTimer.Stop(); _sizeTimer.Stop(); _statusTimer.Stop();
        _owner.DesignerSetDraft(null, "checker", null);
        _host?.Dispose(); _host = null; _native.Dispose(); _lifetime.Dispose();
    }
    private void PopupOpened() { _popupCount++; UpdateHostVisibility(); }
    private void PopupClosed() { _popupCount = Math.Max(0, _popupCount - 1); UpdateHostVisibility(); }
    private void UpdateHostVisibility()
    {
        if (_closed || _host is not { } host) return;
        var visible = _owner.DesignerOverlayRunning && !_processFailed && !_dialogActive && _popupCount == 0;
        try { if (host.IsVisible != visible) host.SetVisible(visible); }
        catch (Exception)
        {
            if (!_processFailed) { _processFailed = true; _owner.DesignerPreviewStopped(_nonce); }
            DesignerPreviewStatus.Text = "The preview stopped.";
            RetryPreviewButton.Visibility = Visibility.Visible;
        }
    }
    private async void OnKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Escape && !_dialogActive) { args.Handled = true; await RequestCloseAsync(); }
        else if (args.Key == VirtualKey.S && IsControlDown()) { args.Handled = true; await SaveAsync(); }
    }
    private static bool IsControlDown() => (InputKeyboardSource.GetKeyStateForCurrentThread(VirtualKey.Control) & CoreVirtualKeyStates.Down) != 0;
    private static void Fill(ComboBox picker, IEnumerable<(string Value, string Label)> values)
    {
        foreach (var (value, label) in values) picker.Items.Add(new ComboBoxItem { Content = label, Tag = value });
    }
    private static string Value(ComboBox picker) => (picker.SelectedItem as ComboBoxItem)?.Tag as string ?? "";
    private static void Select(ComboBox picker, string value) => picker.SelectedItem = picker.Items.OfType<ComboBoxItem>().FirstOrDefault(x => (string)x.Tag == value);
    private static string ThemeName(ObsLookTheme theme) => theme switch { ObsLookTheme.MatteLight => "Matte light", ObsLookTheme.AlbumArt => "Album art", _ => theme.ToString() };
    private bool HandleNativeMessage(uint message, nint wParam, nint lParam, out nint result)
    {
        result = 0;
        if (message == 0x24 && lParam != 0)
        {
            var info = Marshal.PtrToStructure<MinMaxInfo>(lParam);
            var scale = Math.Max(1, GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)) / 96d);
            info.MinTrack.X = (int)Math.Ceiling(960 * scale); info.MinTrack.Y = (int)Math.Ceiling(640 * scale);
            Marshal.StructureToPtr(info, lParam, false); return true;
        }
        return false;
    }
    [StructLayout(LayoutKind.Sequential)] private struct Point { public int X, Y; }
    [StructLayout(LayoutKind.Sequential)] private struct MinMaxInfo { public Point Reserved, MaxSize, MaxPosition, MinTrack, MaxTrack; }
    [DllImport("user32.dll", ExactSpelling = true)] [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern uint GetDpiForWindow(nint hwnd);
    private void RecordDecision(string kind, string? uri, bool allowed)
    {
#if NATIVUNE_DISCORD_TEST_HOOKS
        _navigationDecisions.Add(new { kind, uri, allowed });
#endif
    }
#if NATIVUNE_DISCORD_TEST_HOOKS
    internal void NavigateForHook(string url) => _host?.Core.Navigate(url);
    internal object SnapshotForHook()
    {
        var visible = false; var navigated = false;
        bool? hostObjects = null, webMessages = null;
        try
        {
            visible = _host?.IsVisible ?? false;
            if (Core is { } core)
            {
                navigated = _nonce is not null && IsAllowedPreviewNavigation(core.Source);
                hostObjects = core.Settings.AreHostObjectsAllowed; webMessages = core.Settings.IsWebMessageEnabled;
            }
        }
        catch (Exception) { } // A dead browser must not prevent the native failure-state dump.
        return new { open = !_closed, visible, navigated, dirty = Dirty, draftKey = _draftKey, draftRev = _draftRev,
            dpi = GetDpiForWindow(WinRT.Interop.WindowNative.GetWindowHandle(this)),
            lastSavedRev = _lastSavedRev, sourceId = _sourceId, nonce = _nonce,
            state = _processFailed ? "Stopped" : _owner.DesignerPreviewState(_nonce),
            navigation = _navigationDecisions.ToArray(), hostVisible = visible,
            settings = new { hostObjects, webMessages }, options = _options, size = SourceSizeText.Text, result = DesignerResult.Text };
    }
#endif
}
