using System.ComponentModel;
using Microsoft.UI;
using System.Runtime.InteropServices;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Automation.Peers;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.ApplicationModel.DataTransfer;
using Windows.Graphics;
using Windows.System;
using Windows.UI.Core;
using WinRT.Interop;

namespace Nativune;

// Registry change requested by Save; the caller applies it with StartupRegistration.
internal enum StartupChange { None, Enable, Disable, RemoveStale }

// Status the host computes; the dialog owns the wording.
internal enum ObsOverlayStatus { Off, Waiting, Connected, PrefixInUse, AccessDenied, Failed }

public sealed partial class SettingsDialog : Window
{
    private static readonly (string Command, string Label)[] Actions =
    [
        ("toggle", "Play/Pause"),
        ("previous", "Previous"),
        ("next", "Next"),
        ("compact", "Compact/Full toggle")
    ];

    private const int GwlpHwndParent = -8;
    private const double DialogWidthDip = 720;
    private const double DialogHeightDip = 580;

    private readonly ShellSettings _initial;
    private readonly Func<ShortcutBindings, string?> _applyBindings;
    private readonly TextBox[] _bindingFields;
    private readonly int[] _values;
    private readonly bool _isInstalledBuild;
    private readonly StartupEntryState _startupState;
    private readonly Func<string>? _statusText;
    private StartupChange _staleAction;
    private TaskCompletionSource<bool>? _completion;
    private Control? _ownerFocus;
    private Window? _owner;
    private nint _ownerHandle;
    private nint _dialogHandle;
    private nint _previousNativeOwner;
    private int _focusedBinding = -1;
    private bool _ownerWasEnabled;
    private bool _ownerClosed;
    private bool _nativeOwnerSet;
    private bool _saved;
    private bool _closed;
    private bool _closeRequested;
    private DiscordPresenceStatus _discordStatus = DiscordPresenceStatus.Off;
    private ObsOverlayStatus _obsStatus = ObsOverlayStatus.Off;
    private int _obsStreams;
    private EqualizerSettings _equalizer = EqualizerSettings.Default;
    private Func<EqualizerApply, Task>? _previewEqualizer;
    private Func<EqualizerStatus>? _equalizerStatus;
    private Action? _unsubscribeEqualizer;
    private Func<Task>? _reloadWithoutEqualizer;
    private readonly Slider[] _eqSliders = new Slider[EqualizerBands.Count];
    private readonly NumberBox[] _eqBoxes = new NumberBox[EqualizerBands.Count];
    private readonly DispatcherTimer _eqPreviewTimer = new() { Interval = TimeSpan.FromMilliseconds(75) };
    private bool _eqUpdating;
    private bool _eqEdited;
    private bool _eqRecoveryOff;
    private string? _eqNameOperation;


    internal SettingsDialog(ShellSettings initial, Func<ShortcutBindings, string?> applyBindings,
        bool isInstalledBuild = false, StartupEntryState startupState = StartupEntryState.Off,
        Func<string>? statusText = null, string? installRoot = null,
        Func<EqualizerApply, Task>? previewEqualizer = null, Func<EqualizerStatus>? equalizerStatus = null,
        Func<Action, Action>? subscribeEqualizerStatus = null, Func<Task>? reloadWithoutEqualizer = null)
    {
        _isInstalledBuild = isInstalledBuild;
        _startupState = startupState;
        _statusText = statusText;
        _initial = initial ?? throw new ArgumentNullException(nameof(initial));
        _applyBindings = applyBindings ?? throw new ArgumentNullException(nameof(applyBindings));
        _values =
        [
            initial.Shortcuts.Toggle,
            initial.Shortcuts.Previous,
            initial.Shortcuts.Next,
            initial.Shortcuts.Compact
        ];
        Result = initial;

        InitializeComponent();
        ShellTheme.ApplyToWindow(this);

        _bindingFields = [ToggleField, PreviousField, NextField, CompactField];
        ReduceMotionCheckBox.IsChecked = initial.ReduceMotion;
        SleepInBackgroundCheckBox.IsChecked = initial.SleepInBackground;
        StartCompactCheckBox.IsChecked = initial.StartCompact;
        AutoCheckUpdatesCheckBox.IsChecked = initial.AutoCheckUpdates;
        BlockAdsCheckBox.IsChecked = initial.BlockAds;
        TrayEnabledCheckBox.IsChecked = initial.TrayEnabled;
        RestoreSectionCheckBox.IsChecked = initial.RestoreSection;
        VersionText.Text = AppVersion.DisplayName;
        AutomationProperties.SetName(VersionText, $"Application version {AppVersion.Number}");
        InstallKindText.Text = isInstalledBuild
            ? (installRoot is null ? "Installed build" : $"Installed at {installRoot}") : "Development build";
        AutomationProperties.SetName(InstallKindText, InstallKindText.Text);
        CopyStatusButton.IsEnabled = statusText is not null;
        CopyStatusButton.Click += (_, _) => CopyStatus();
        DonateButton.Click += async (_, _) => await OpenDonationPageAsync();
        StartWithWindows = startupState is StartupEntryState.On or StartupEntryState.DisabledByUser;
        InitializeUpdatesAndStartup(initial);
        InitializeDiscord(initial);
        InitializeLyrics(initial);
        InitializeObs(initial);
        InitializeEqualizer(initial.Equalizer, previewEqualizer, equalizerStatus, subscribeEqualizerStatus, reloadWithoutEqualizer);

        for (var i = 0; i < _bindingFields.Length; i++)
        {
            var index = i;
            _bindingFields[index].Text = ShortcutBindings.Format(_values[index]);
            _bindingFields[index].GotFocus += (_, _) => _focusedBinding = index;
            _bindingFields[index].LostFocus += (_, _) =>
            {
                if (_focusedBinding == index)
                    _focusedBinding = -1;
            };
            _bindingFields[index].KeyDown += OnBindingKeyDown;
        }

        ClearToggle.Click += (_, _) => SetBinding(0, 0);
        ClearPrevious.Click += (_, _) => SetBinding(1, 0);
        ClearNext.Click += (_, _) => SetBinding(2, 0);
        ClearCompact.Click += (_, _) => SetBinding(3, 0);
        RestoreButton.Click += (_, _) => RestoreDefaults();
        Nav.SelectionChanged += OnNavSelectionChanged;
        SaveButton.Click += (_, _) => Save();
        CancelButton.Click += (_, _) => CloseWithoutSaving();
        Root.Loaded += OnRootLoaded;
        Root.KeyDown += OnRootKeyDown;
        Closed += OnDialogClosed;
    }

    internal void SelectEqualizerPage() => Nav.SelectedItem = EqualizerNavItem;

    private void InitializeEqualizer(EqualizerSettings settings, Func<EqualizerApply, Task>? preview,
        Func<EqualizerStatus>? status, Func<Action, Action>? subscribe, Func<Task>? reload)
    {
        _equalizer = settings;
        _previewEqualizer = preview;
        _equalizerStatus = status;
        _reloadWithoutEqualizer = reload;
        for (var i = 0; i < EqualizerBands.Count; i++)
        {
            var index = i;
            var panel = new StackPanel { Spacing = 6, Width = 56 };
            var slider = new Slider
            {
                Orientation = Orientation.Vertical, Height = 160, HorizontalAlignment = HorizontalAlignment.Center,
                Minimum = -12, Maximum = 12, StepFrequency = 0.5, SmallChange = 0.5, LargeChange = 3
            };
            var box = new NumberBox
            {
                Minimum = -12, Maximum = 12, SmallChange = 0.5, LargeChange = 3,
                MinWidth = 0, Width = 56, Padding = new Thickness(4), FontSize = 12,
                SpinButtonPlacementMode = NumberBoxSpinButtonPlacementMode.Hidden
            };
            AutomationProperties.SetAutomationId(slider, $"EqBand{i}");
            AutomationProperties.SetAutomationId(box, $"EqBandBox{i}");
            AutomationProperties.SetName(box, $"{EqualizerBands.CentresHz[i]:0.#} hertz gain in decibels");
            panel.Children.Add(new TextBlock { Text = EqualizerBands.Labels[i], HorizontalAlignment = HorizontalAlignment.Center });
            panel.Children.Add(slider);
            panel.Children.Add(box);
            EqBandsPanel.Children.Add(panel);
            _eqSliders[i] = slider;
            _eqBoxes[i] = box;
            slider.ValueChanged += (_, args) => SetEqualizerBand(index, args.NewValue);
            box.ValueChanged += (_, args) => SetEqualizerBand(index, args.NewValue);
        }
        EqEnabled.Toggled += (_, _) =>
        {
            if (!_eqUpdating) ChangeEqualizer(_equalizer with { Enabled = EqEnabled.IsOn });
        };
        EqAutoHeadroom.Toggled += (_, _) =>
        {
            if (!_eqUpdating) ChangeEqualizer(_equalizer with { AutoHeadroom = EqAutoHeadroom.IsOn, SelectedPresetId = null });
        };
        EqPreamp.ValueChanged += (_, args) => SetEqualizerPreamp(args.NewValue);
        EqPreampBox.ValueChanged += (_, args) => SetEqualizerPreamp(args.NewValue);
        EqPreset.SelectionChanged += (_, _) =>
        {
            if (_eqUpdating || EqPreset.SelectedItem is not ComboBoxItem { Tag: EqualizerPreset preset }) return;
            _eqInPresetSelection = true;
            try
            {
                ChangeEqualizer(_equalizer with
                {
                    SelectedPresetId = preset.Id, GainsDb = preset.GainsDb.ToArray(),
                    ManualPreampDb = preset.PreampDb, AutoHeadroom = preset.AutoHeadroom
                });
            }
            finally { _eqInPresetSelection = false; }
        };
        EqResetBands.Click += (_, _) => ChangeEqualizer(_equalizer with { GainsDb = new double[10], SelectedPresetId = null });
        EqResetPreamp.Click += (_, _) => ChangeEqualizer(_equalizer with { ManualPreampDb = 0, SelectedPresetId = null });
        EqSaveNew.Click += (_, _) => BeginEqualizerName("new");
        EqRename.Click += (_, _) => BeginEqualizerName("rename");
        EqDuplicate.Click += (_, _) => BeginEqualizerName("duplicate");
        EqDelete.Click += (_, _) =>
        {
            var selected = EqualizerPresets.Find(_equalizer, _equalizer.SelectedPresetId);
            if (selected is null || selected.BuiltIn) return;
            ChangeEqualizer(_equalizer with
            {
                SelectedPresetId = null, CustomPresets = _equalizer.CustomPresets.Where(p => p.Id != selected.Id).ToArray()
            });
        };
        EqNameConfirm.Click += (_, _) => KeepEqualizerPreset();
        EqNameCancel.Click += (_, _) => { _eqNameOperation = null; EqNameEditor.Visibility = Visibility.Collapsed; };
        EqCopy.Click += (_, _) => CopyEqualizerPreset();
        EqPaste.Click += async (_, _) => await PasteEqualizerPresetAsync();
        EqBypass.Checked += (_, _) => QueueEqualizerPreview();
        EqBypass.Unchecked += (_, _) => QueueEqualizerPreview();
        EqReload.IsEnabled = reload is not null;
        EqReload.Click += async (_, _) =>
        {
            if (_reloadWithoutEqualizer is null) return;
            _eqPreviewTimer.Stop();
            EqReload.IsEnabled = false;
            try
            {
                await _reloadWithoutEqualizer();
                _eqRecoveryOff = true;
                _equalizer = _equalizer with { Enabled = false };
                _eqPreviewTimer.Stop();
                RefreshEqualizerControls();
            }
            catch (Exception) { EqError.Text = "Reload without EQ could not be completed."; }
            finally { if (!_closed) EqReload.IsEnabled = true; }
        };
        EqCurveCanvas.SizeChanged += (_, _) => DrawEqualizerCurve();
        // NumberBox/Slider templates may handle wheel input; keep vertical page navigation available.
        EqualizerPage.AddHandler(UIElement.PointerWheelChangedEvent, new PointerEventHandler((_, args) =>
        {
            var properties = args.GetCurrentPoint(EqualizerPage).Properties;
            if (properties.IsHorizontalMouseWheel || properties.MouseWheelDelta == 0) return;
            var offset = Math.Clamp(PageScroller.VerticalOffset - properties.MouseWheelDelta / 120.0 * 48,
                0, PageScroller.ScrollableHeight);
            PageScroller.ChangeView(null, offset, null, disableAnimation: true);
            args.Handled = true;
        }), handledEventsToo: true);
        _eqPreviewTimer.Tick += async (_, _) =>
        {
            _eqPreviewTimer.Stop();
            if (_closed || _previewEqualizer is null) return;
            var apply = EqualizerApply.From(_equalizer, EqBypass.IsChecked == true);
            try { await _previewEqualizer(apply); }
            catch (Exception) { if (!_closed) EqError.Text = "Equalizer preview is unavailable."; }
        };
        RefreshEqualizerControls();
        RefreshEqualizerStatus();
        _unsubscribeEqualizer = subscribe?.Invoke(() => { if (!_closed) RefreshEqualizerStatus(); });
    }

    private void SetEqualizerBand(int index, double value)
    {
        if (_eqUpdating || !double.IsFinite(value)) return;
        var gains = _equalizer.GainsDb.ToArray();
        gains[index] = EqualizerBands.QuantizeGain(value);
        ChangeEqualizer(_equalizer with { GainsDb = gains, SelectedPresetId = null });
    }

    private void SetEqualizerPreamp(double value)
    {
        if (_eqUpdating || !double.IsFinite(value)) return;
        ChangeEqualizer(_equalizer with { ManualPreampDb = EqualizerBands.QuantizePreamp(value), SelectedPresetId = null });
    }

    private void ChangeEqualizer(EqualizerSettings settings)
    {
        if (_closed) return;
        _equalizer = settings;
        EqError.Text = string.Empty;
        RefreshEqualizerControls();
        QueueEqualizerPreview();
    }

    private void QueueEqualizerPreview()
    {
        if (_eqUpdating || _closed) return;
        _eqEdited = true;
        _eqPreviewTimer.Stop();
        _eqPreviewTimer.Start();
    }

    private void RefreshEqualizerControls()
    {
        _eqUpdating = true;
        try
        {
            EqEnabled.IsOn = _equalizer.Enabled;
            EqAutoHeadroom.IsOn = _equalizer.AutoHeadroom;
            EqPreamp.Value = EqPreampBox.Value = _equalizer.ManualPreampDb;
            EqPreamp.IsEnabled = EqPreampBox.IsEnabled = !_equalizer.AutoHeadroom;
            EqEffectivePreamp.Text = $"Effective preamp: {EqualizerMath.EffectivePreampDb(_equalizer):+0.#;-0.#;0} dB";
            EqMayClip.Visibility = EqualizerMath.MayClip(_equalizer) ? Visibility.Visible : Visibility.Collapsed;
            for (var i = 0; i < EqualizerBands.Count; i++)
            {
                var gain = _equalizer.GainsDb[i];
                _eqSliders[i].Value = _eqBoxes[i].Value = gain;
                var sign = gain > 0 ? "plus " : gain < 0 ? "minus " : "";
                AutomationProperties.SetName(_eqSliders[i], $"{EqualizerBands.CentresHz[i]:0.#} hertz, {sign}{Math.Abs(gain):0.#} decibels");
            }
            SyncEqualizerPresetItems();
            var selected = EqualizerPresets.Find(_equalizer, _equalizer.SelectedPresetId);
            EqRename.IsEnabled = EqDelete.IsEnabled = selected is { BuiltIn: false };
            EqSaveNew.IsEnabled = selected?.BuiltIn != true && _equalizer.CustomPresets.Count < EqualizerBands.MaxCustomPresets;
            EqDuplicate.IsEnabled = _equalizer.CustomPresets.Count < EqualizerBands.MaxCustomPresets;
            DrawEqualizerCurve();
        }
        finally { _eqUpdating = false; }
    }

    // Rebuilding a ComboBox's Items from inside its own SelectionChanged throws E_UNEXPECTED (0x8000FFFF,
    // "Catastrophic failure") in WinUI. Only rebuild when the list itself changes, and then outside the
    // selection event; a plain preset switch only moves the selection.
    private string? _eqPresetSignature;
    private bool _eqInPresetSelection;

    private void SyncEqualizerPresetItems()
    {
        var presets = EqualizerPresets.BuiltIns.Concat(_equalizer.CustomPresets).ToArray();
        var unsaved = _equalizer.SelectedPresetId is null;
        var signature = string.Join('\u001f', presets.Select(preset => preset.Id + '\u001e' + preset.Name)) + (unsaved ? "\u001funsaved" : "");
        if (signature == _eqPresetSignature)
        {
            var target = EqPreset.Items.OfType<ComboBoxItem>().FirstOrDefault(item =>
                unsaved ? item.Tag is null : item.Tag is EqualizerPreset preset && preset.Id == _equalizer.SelectedPresetId);
            if (!ReferenceEquals(EqPreset.SelectedItem, target)) EqPreset.SelectedItem = target;
            return;
        }
        if (_eqInPresetSelection)
        {
            DispatcherQueue.TryEnqueue(() =>
            {
                if (_closed) return;
                _eqUpdating = true;
                try { SyncEqualizerPresetItems(); }
                finally { _eqUpdating = false; }
            });
            return;
        }
        _eqPresetSignature = signature;
        EqPreset.Items.Clear();
        ComboBoxItem? selectedItem = null;
        foreach (var preset in presets)
        {
            var item = new ComboBoxItem { Content = preset.Name, Tag = preset };
            AutomationProperties.SetName(item, preset.Name);
            EqPreset.Items.Add(item);
            if (preset.Id == _equalizer.SelectedPresetId) selectedItem = item;
        }
        if (unsaved)
        {
            selectedItem = new ComboBoxItem { Content = "Unsaved custom" };
            AutomationProperties.SetName(selectedItem, "Unsaved custom");
            EqPreset.Items.Add(selectedItem);
        }
        EqPreset.SelectedItem = selectedItem;
    }

    private void DrawEqualizerCurve()
    {
        var width = EqCurveCanvas.ActualWidth;
        var height = EqCurveCanvas.ActualHeight;
        if (width <= 0 || height <= 0) return;
        var frequencies = Enumerable.Range(0, 201).Select(i => 20 * Math.Pow(1000, i / 200.0)).ToArray();
        var sampleRate = _equalizerStatus?.Invoke().SampleRate ?? 48000;
        var response = EqualizerMath.ResponseDb(_equalizer.GainsDb, sampleRate, frequencies);
        var preamp = EqualizerMath.EffectivePreampDb(_equalizer, sampleRate);
        var points = new Microsoft.UI.Xaml.Media.PointCollection();
        for (var i = 0; i < response.Length; i++)
        {
            var x = width * Math.Log(frequencies[i] / 20) / Math.Log(1000);
            var y = height / 2 - height * Math.Clamp(response[i] + preamp, -15, 15) / 30;
            points.Add(new Windows.Foundation.Point(x, y));
        }
        EqCurve.Width = EqZeroLine.Width = width;
        EqCurve.Height = EqZeroLine.Height = height;
        EqZeroLine.X1 = 0;
        EqZeroLine.X2 = width;
        EqZeroLine.Y1 = EqZeroLine.Y2 = height / 2;
        EqCurve.Points = points;
    }

#if NATIVUNE_DISCORD_TEST_HOOKS
    internal object EqualizerCurveHookSnapshot() => new
    {
        width = EqCurveCanvas.ActualWidth, height = EqCurveCanvas.ActualHeight,
        points = EqCurve.Points.Select(point => new { x = point.X, y = point.Y }).ToArray()
    };
#endif


    private void BeginEqualizerName(string operation)
    {
        _eqNameOperation = operation;
        var selected = EqualizerPresets.Find(_equalizer, _equalizer.SelectedPresetId);
        EqName.Text = operation == "rename" ? selected?.Name ?? "" : "";
        EqError.Text = string.Empty;
        EqNameEditor.Visibility = Visibility.Visible;
        EqName.Focus(FocusState.Programmatic);
    }

    private void KeepEqualizerPreset()
    {
        if (_eqNameOperation is null) return;
        if (!EqualizerPresets.TryValidateName(EqName.Text, out var name, out var error))
        {
            EqError.Text = error;
            return;
        }
        var selected = EqualizerPresets.Find(_equalizer, _equalizer.SelectedPresetId);
        var renaming = _eqNameOperation == "rename";
        if (renaming && selected is not { BuiltIn: false }) return;
        if (EqualizerPresets.BuiltIns.Concat(_equalizer.CustomPresets).Any(p =>
            string.Equals(p.Name, name, StringComparison.OrdinalIgnoreCase) && (!renaming || p.Id != selected!.Id)))
        {
            EqError.Text = "A preset with that name already exists. Choose another name.";
            return;
        }
        if (!renaming && _equalizer.CustomPresets.Count >= EqualizerBands.MaxCustomPresets)
        {
            EqError.Text = "You can keep at most 20 custom presets. Delete one first.";
            return;
        }
        var preset = renaming ? selected! with { Name = name } : new EqualizerPreset(
            "c-" + Guid.NewGuid().ToString("N")[..8], name, _equalizer.GainsDb.ToArray(),
            _equalizer.ManualPreampDb, _equalizer.AutoHeadroom, false);
        var custom = renaming ? _equalizer.CustomPresets.Select(p => p.Id == preset.Id ? preset : p).ToArray()
            : _equalizer.CustomPresets.Append(preset).ToArray();
        _eqNameOperation = null;
        EqNameEditor.Visibility = Visibility.Collapsed;
        ChangeEqualizer(_equalizer with { SelectedPresetId = preset.Id, CustomPresets = custom });
    }

    private void CopyEqualizerPreset()
    {
        try
        {
            var name = EqualizerPresets.Find(_equalizer, _equalizer.SelectedPresetId)?.Name ?? "Unsaved custom";
            var package = new DataPackage();
            package.SetText(EqualizerSharing.Export(new EqualizerPreset("unsaved", name, _equalizer.GainsDb,
                _equalizer.ManualPreampDb, _equalizer.AutoHeadroom, false)));
            Clipboard.SetContent(package);
        }
        catch (Exception) { EqError.Text = "The preset could not be copied."; }
    }

    private async Task PasteEqualizerPresetAsync()
    {
        try
        {
            var content = Clipboard.GetContent();
            if (!content.Contains(StandardDataFormats.Text)) { EqError.Text = "The clipboard does not contain a preset."; return; }
            var text = await content.GetTextAsync();
            if (_closed) return;
            if (!EqualizerSharing.TryImport(text, out var preset, out var error)) { EqError.Text = error; return; }
            ChangeEqualizer(_equalizer with
            {
                SelectedPresetId = null, GainsDb = preset!.GainsDb.ToArray(),
                ManualPreampDb = preset.PreampDb, AutoHeadroom = preset.AutoHeadroom
            });
        }
        catch (Exception) { if (!_closed) EqError.Text = "The preset could not be pasted."; }
    }

    private void RefreshEqualizerStatus()
    {
        var status = _equalizerStatus?.Invoke();
        EqStatus.Text = status?.State switch
        {
            EqualizerState.Off => "Off",
            EqualizerState.Waiting => "Waiting for a click on the page",
            EqualizerState.NotApplied => "Not applied",
            EqualizerState.Active => "Active",
            EqualizerState.Bypassed => "Bypassed",
            EqualizerState.Interrupted or EqualizerState.ReloadNeeded => "Interrupted — Reload needed",
            EqualizerState.ProtectedMedia => "Protected media",
            _ => "Unavailable"
        };
        AutomationProperties.SetName(EqStatus, $"Equalizer status: {EqStatus.Text}");
        AutomationProperties.SetLiveSetting(EqStatus, AutomationLiveSetting.Polite);
        EqReload.Visibility = status?.State is EqualizerState.Interrupted or EqualizerState.ReloadNeeded or EqualizerState.ProtectedMedia
            ? Visibility.Visible : Visibility.Collapsed;
        DrawEqualizerCurve();
    }

    internal ShellSettings Result { get; private set; }
    internal FrameworkElement ObsDesignerInvoker => ObsDesignerButton;

    // Desired start-with-Windows state after Save (registry is the source of truth, not settings.json).
    internal bool StartWithWindows { get; private set; }

    internal StartupChange StartupChange { get; private set; }

    internal async Task<bool> ShowAsync(Window owner)
    {
        ArgumentNullException.ThrowIfNull(owner);
        if (_completion is not null)
            throw new InvalidOperationException("Settings can only be shown once.");
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        _completion = completion;

        _owner = owner;
        _ownerHandle = WindowNative.GetWindowHandle(owner);
        if (_ownerHandle == 0 || !IsWindow(_ownerHandle))
            throw new InvalidOperationException("The owner window is no longer available.");
        CaptureOwnerFocus(owner);
        if (IsWindowEnabled(_ownerHandle))
        {
            _ownerWasEnabled = true;
            EnableWindow(_ownerHandle, false);
        }

        owner.Closed += OnOwnerClosed;
        try
        {
            Activate();
            _dialogHandle = WindowNative.GetWindowHandle(this);
            SetNativeOwner();
            SizeAndCenter();
            if (_ownerClosed)
                CloseWithoutSaving();
        }
        catch
        {
            CleanupModal();
            throw;
        }

        return await completion.Task;
    }

    internal bool CaptureRegisteredShortcut(int binding)
    {
        if (_closed || _focusedBinding < 0)
            return false;

        var index = _focusedBinding;
        if (!ShortcutBindings.TryDecode(binding, out _, out _, out var reason))
        {
            ShowError($"{Actions[index].Label}: {reason}.");
            return false;
        }
        if (IsDuplicate(index, binding))
        {
            ShowError($"{Actions[index].Label}: that combination is already assigned. Clear the other action first.");
            return false;
        }

        SetBinding(index, binding);
        HideError();
        return true;
    }


    private void OnRootLoaded(object sender, RoutedEventArgs args)
    {
        Root.Loaded -= OnRootLoaded;
        if (_focusedBinding < 0)
        {
            if (ReferenceEquals(Nav.SelectedItem, EqualizerNavItem)) EqEnabled.Focus(FocusState.Programmatic);
            else TrayEnabledCheckBox.Focus(FocusState.Programmatic);
        }
    }

    private void OnRootKeyDown(object sender, KeyRoutedEventArgs args)
    {
        if (args.Key == VirtualKey.Escape)
        {
            args.Handled = true;
            CloseWithoutSaving();
            return;
        }
        if (args.Key == VirtualKey.Enter
            && args.OriginalSource is not (Button or HyperlinkButton or ComboBox or ComboBoxItem or NavigationViewItem or TextBox or NumberBox or Slider))
        {
            args.Handled = true;
            Save();
        }
    }

    private void OnBindingKeyDown(object sender, KeyRoutedEventArgs args)
    {
        // Escape and Tab are navigation commands, not shortcut captures.
        if (args.Key is VirtualKey.Escape or VirtualKey.Tab)
            return;

        var control = IsDown(VirtualKey.Control);
        var alt = IsDown(VirtualKey.Menu);
        var shift = IsDown(VirtualKey.Shift);
        if (args.Key == VirtualKey.Enter && !control && !alt && !shift)
        {
            args.Handled = true;
            Save();
            return;
        }

        args.Handled = true;
        if (IsModifierKey(args.Key))
            return;

        var index = Array.IndexOf(_bindingFields, sender as TextBox);
        if (index < 0)
            return;

        if (IsDown(VirtualKey.LeftWindows) || IsDown(VirtualKey.RightWindows))
        {
            ShowError($"{Actions[index].Label}: Windows and other unsupported modifiers are not available.");
            return;
        }

        var encoded = ShortcutBindings.Encode(
            (uint)args.Key,
            control,
            alt,
            shift);
        TryAssign(index, encoded);
    }

    private void SetBinding(int index, int value)
    {
        _values[index] = value;
        _bindingFields[index].Text = ShortcutBindings.Format(value);
        HideError();
    }

    private void TryAssign(int index, int value)
    {
        if (!ShortcutBindings.TryDecode(value, out _, out _, out var reason))
        {
            ShowError($"{Actions[index].Label}: {reason}.");
            return;
        }
        if (IsDuplicate(index, value))
        {
            ShowError($"{Actions[index].Label}: that combination is already assigned. Clear the other action first.");
            return;
        }

        SetBinding(index, value);
    }

    private bool IsDuplicate(int index, int value)
    {
        for (var other = 0; other < _values.Length; other++)
        {
            if (other != index && _values[other] == value)
                return true;
        }
        return false;
    }

    private void RestoreDefaults()
    {
        var defaults = ShortcutBindings.Default;
        SetBinding(0, defaults.Toggle);
        SetBinding(1, defaults.Previous);
        SetBinding(2, defaults.Next);
        SetBinding(3, defaults.Compact);
    }

    private void Save()
    {
        var bindings = new ShortcutBindings(_values[0], _values[1], _values[2], _values[3]);
        if (!bindings.Validate(out var validationError))
        {
            ShowError(validationError);
            return;
        }

        string? applyError;
        try
        {
            applyError = _applyBindings(bindings);
        }
        catch (Exception ex) when (ex is InvalidOperationException or Win32Exception)
        {
            applyError = "The shortcut registration could not be changed.";
        }
        if (applyError is not null)
        {
            ShowError(applyError);
            return;
        }

        Result = _initial with
        {
            ReduceMotion = ReduceMotionCheckBox.IsChecked == true,
            SleepInBackground = SleepInBackgroundCheckBox.IsChecked == true,
            StartCompact = StartCompactCheckBox.IsChecked == true,
            AutoCheckUpdates = AutoCheckUpdatesCheckBox.IsChecked == true,
            BlockAds = BlockAdsCheckBox.IsChecked == true,
            TrayEnabled = TrayEnabledCheckBox.IsChecked == true,
            RestoreSection = RestoreSectionCheckBox.IsChecked == true,
            AutostartMode = SelectedAutostartMode(),
            Discord = new DiscordPresenceOptions(DiscordPresenceCheckBox.IsChecked == true,
                SelectedDiscordStatusLine(), DiscordOpenButtonCheckBox.IsChecked == true,
                DiscordShowAuthorCheckBox.IsChecked == true),
            BetterLyricsEnabled = LyricsEnabledCheckBox.IsChecked == true,
            ObsOverlay = ObsOverlayCheckBox.IsChecked == true,
            ObsHidePaused = ObsHidePausedCheckBox.IsChecked == true,
            Equalizer = _equalizer,
            Shortcuts = bindings
        };
        (StartWithWindows, StartupChange) = ResolveStartupChange();
        _saved = true;
        Close();
    }

    private void InitializeUpdatesAndStartup(ShellSettings initial)
    {
        if (!_isInstalledBuild)
        {
            AutoCheckUpdatesCheckBox.IsEnabled = false;
            AutoCheckUpdatesCaption.Visibility = Visibility.Visible;
            AutomationProperties.SetHelpText(AutoCheckUpdatesCheckBox, AutoCheckUpdatesCaption.Text);

            StartWithWindowsCheckBox.IsEnabled = false;
            StartWithWindowsCheckBox.IsChecked = false;
            StartWithWindowsCaption.Visibility = Visibility.Visible;
            AutomationProperties.SetHelpText(StartWithWindowsCheckBox, StartWithWindowsCaption.Text);
        }
        else
        {
            StartWithWindowsCheckBox.IsChecked = StartWithWindows;
        }

        AutostartModeComboBox.SelectedIndex = (int)(Enum.IsDefined(initial.AutostartMode)
            ? initial.AutostartMode : ShellSettings.DefaultAutostartMode(initial.TrayEnabled));
        UpdateStartupControls(announce: false);

        StartWithWindowsCheckBox.Checked += (_, _) => UpdateStartupControls(announce: true);
        StartWithWindowsCheckBox.Unchecked += (_, _) => UpdateStartupControls(announce: true);
        TrayEnabledCheckBox.Checked += (_, _) => UpdateStartupControls(announce: false);
        TrayEnabledCheckBox.Unchecked += (_, _) => UpdateStartupControls(announce: false);
        OpenStartupAppsButton.Click += async (_, _) =>
            await Launcher.LaunchUriAsync(new Uri("ms-settings:startupapps"));
        FixStartupButton.Click += (_, _) => ChooseStaleAction(StartupChange.Enable);
        RemoveStartupButton.Click += (_, _) => ChooseStaleAction(StartupChange.RemoveStale);
    }

    private void ChooseStaleAction(StartupChange action)
    {
        _staleAction = action;
        if (action == StartupChange.Enable)
            StartWithWindowsCheckBox.IsChecked = true;
        UpdateStartupControls(announce: true);
    }

    private void UpdateStartupControls(bool announce)
    {
        var parentOn = _isInstalledBuild && StartWithWindowsCheckBox.IsChecked == true;
        var trayOn = TrayEnabledCheckBox.IsChecked == true;
        AutostartModeComboBox.IsEnabled = parentOn;
        AutostartTrayItem.IsEnabled = trayOn;
        AutostartTrayCaption.Visibility = trayOn ? Visibility.Collapsed : Visibility.Visible;
        AutomationProperties.SetHelpText(AutostartTrayItem, trayOn ? string.Empty : "Requires Show tray icon");
        if (!trayOn && AutostartModeComboBox.SelectedIndex == (int)AutostartMode.Tray)
            AutostartModeComboBox.SelectedIndex = (int)AutostartMode.Full;

        var stale = _startupState == StartupEntryState.Stale && _isInstalledBuild;
        FixStartupButton.Visibility = stale && _staleAction == StartupChange.None ? Visibility.Visible : Visibility.Collapsed;
        RemoveStartupButton.Visibility = FixStartupButton.Visibility;

        var (desired, _) = ResolveStartupChange();
        StartupStatusText.Text = _startupState switch
        {
            StartupEntryState.DisabledByUser when desired
                => "Startup entry: Turned off in Task Manager or Windows Settings — turn it back on there.",
            StartupEntryState.Stale when desired || _staleAction == StartupChange.Enable
                => "Startup entry points to another location; it will be fixed when you save.",
            StartupEntryState.Stale when _staleAction == StartupChange.RemoveStale
                => "Startup entry points to another location; it will be removed when you save.",
            StartupEntryState.Stale when !desired => "Startup entry points to another location",
            _ => (_startupState is StartupEntryState.On or StartupEntryState.DisabledByUser, desired) switch
            {
                (true, true) => "Startup entry: on",
                (false, false) => "Startup entry: off",
                (false, true) => "Startup entry: off — will be added when you save.",
                (true, false) => "Startup entry: on — will be removed when you save."
            }
        };
        if (!_isInstalledBuild)
            StartupStatusText.Text = "Startup entry: off";
        AutomationProperties.SetName(StartupStatusText, StartupStatusText.Text);
        if (announce && FrameworkElementAutomationPeer.FromElement(StartupStatusText) is { } peer)
            peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private (bool Desired, StartupChange Change) ResolveStartupChange()
    {
        if (!_isInstalledBuild)
            return (false, StartupChange.None);
        var wanted = StartWithWindowsCheckBox.IsChecked == true;
        return _startupState switch
        {
            StartupEntryState.Stale when _staleAction == StartupChange.RemoveStale && !wanted
                => (false, StartupChange.RemoveStale),
            StartupEntryState.Stale => wanted ? (true, StartupChange.Enable) : (false, StartupChange.None),
            StartupEntryState.Off => wanted ? (true, StartupChange.Enable) : (false, StartupChange.None),
            _ => wanted ? (true, StartupChange.None) : (false, StartupChange.Disable)
        };
    }

    private AutostartMode SelectedAutostartMode()
    {
        var mode = AutostartModeComboBox.SelectedIndex is >= 0 and <= 2
            ? (AutostartMode)AutostartModeComboBox.SelectedIndex
            : ShellSettings.DefaultAutostartMode(TrayEnabledCheckBox.IsChecked == true);
        return mode == AutostartMode.Tray && TrayEnabledCheckBox.IsChecked != true ? AutostartMode.Full : mode;
    }

    private void InitializeDiscord(ShellSettings initial)
    {
        DiscordPresenceCheckBox.IsChecked = initial.Discord.Enabled;
        DiscordStatusLineComboBox.SelectedIndex = (int)(Enum.IsDefined(initial.Discord.StatusLine)
            ? initial.Discord.StatusLine : DiscordStatusLine.Artist);
        DiscordOpenButtonCheckBox.IsChecked = initial.Discord.ShowOpenButton;
        DiscordShowAuthorCheckBox.IsChecked = initial.Discord.ShowAuthor;
        _discordStatus = initial.Discord.Enabled ? DiscordPresenceStatus.Connecting : DiscordPresenceStatus.Off;
        UpdateDiscordControls(announce: false);
        DiscordPresenceCheckBox.Checked += (_, _) => UpdateDiscordControls(announce: true);
        DiscordPresenceCheckBox.Unchecked += (_, _) => UpdateDiscordControls(announce: true);
    }

    internal void SelectDiscordPage() => Nav.SelectedItem = DiscordNavItem;

    internal event EventHandler? OpenLyricsSettingsRequested;

    private void InitializeLyrics(ShellSettings initial)
    {
        LyricsEnabledCheckBox.IsChecked = initial.BetterLyricsEnabled;
        OpenLyricsSettingsButton.Click += (_, _) => OpenLyricsSettingsRequested?.Invoke(this, EventArgs.Empty);
    }

    internal void SetLyricsStatus(string text, bool canOpenSettings)
    {
        OpenLyricsSettingsButton.IsEnabled = canOpenSettings;
        LyricsStatusText.Text = canOpenSettings ? text : text + " Enable, save and restart Nativune first.";
    }

    // Called by the owner with the live presence state; the text never contains track data.
    internal void SetDiscordStatus(DiscordPresenceStatus status)
    {
        if (_discordStatus == status)
            return;
        _discordStatus = status;
        UpdateDiscordControls(announce: true);
    }

    private void UpdateDiscordControls(bool announce)
    {
        var on = DiscordPresenceCheckBox.IsChecked == true;
        DiscordStatusLineComboBox.IsEnabled = on;
        DiscordOpenButtonCheckBox.IsEnabled = on;
        DiscordShowAuthorCheckBox.IsEnabled = on;
        var text = on == _initial.Discord.Enabled
            ? DiscordStatusMessage(_discordStatus)
            : on ? "Turns on after Save" : "Turns off after Save";
        if (DiscordStatusText.Text == text)
            return;
        DiscordStatusText.Text = text;
        AutomationProperties.SetName(DiscordStatusText, text.Length == 0 ? "Discord connection status" : text);
        if (announce && FrameworkElementAutomationPeer.FromElement(DiscordStatusText) is { } peer)
            peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private static string DiscordStatusMessage(DiscordPresenceStatus status) => status switch
    {
        DiscordPresenceStatus.Unavailable => "Not available in this build.",
        DiscordPresenceStatus.Connecting => "Connecting to Discord...",
        DiscordPresenceStatus.Connected => "Connected to Discord.",
        DiscordPresenceStatus.DiscordAbsent => "Discord isn't running. Nativune will connect when it starts.",
        DiscordPresenceStatus.Error => "Couldn't update Discord. Playback is unaffected.",
        _ => string.Empty
    };

    private static string DiscordStatusCopyName(DiscordPresenceStatus status) => status switch
    {
        DiscordPresenceStatus.Unavailable => "unavailable",
        DiscordPresenceStatus.Connecting => "connecting",
        DiscordPresenceStatus.Connected => "connected",
        DiscordPresenceStatus.DiscordAbsent => "not running",
        DiscordPresenceStatus.Error => "error",
        _ => "off"
    };

    private DiscordStatusLine SelectedDiscordStatusLine()
        => DiscordStatusLineComboBox.SelectedIndex is >= 0 and <= 2
            ? (DiscordStatusLine)DiscordStatusLineComboBox.SelectedIndex : DiscordStatusLine.Artist;

    internal event EventHandler? OpenObsGuideRequested;
    internal event EventHandler? OpenObsDesignerRequested;

    private void InitializeObs(ShellSettings initial)
    {
        ObsOverlayCheckBox.IsChecked = initial.ObsOverlay;
        ObsHidePausedCheckBox.IsChecked = initial.ObsHidePaused;
        _obsStatus = initial.ObsOverlay ? ObsOverlayStatus.Waiting : ObsOverlayStatus.Off;
        UpdateObsControls(announce: false);
        ObsOverlayCheckBox.Checked += (_, _) => UpdateObsControls(announce: true);
        ObsOverlayCheckBox.Unchecked += (_, _) => UpdateObsControls(announce: true);
        ObsCopyLinkButton.Click += (_, _) => CopyObsLink();
        ObsGuideButton.Click += (_, _) => OpenObsGuideRequested?.Invoke(this, EventArgs.Empty);
        ObsDesignerButton.Click += (_, _) => OpenObsDesignerRequested?.Invoke(this, EventArgs.Empty);
        // Navigation only: the Block ads value is changed on the Privacy page, never here.
        ObsOpenBlockAdsButton.Click += (_, _) => Nav.SelectedItem = PrivacyNavItem;
    }

    internal void SetObsDesignerAvailable(bool available)
    {
        if (_closed) return;
        ObsDesignerButton.IsEnabled = available;
    }

    internal void SetObsDesignerResult(string message)
    {
        if (_closed) return;
        ObsDesignerResult.Text = message;
        if (FrameworkElementAutomationPeer.FromElement(ObsDesignerResult) is { } peer)
            peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    internal void SelectObsPage() => Nav.SelectedItem = ObsNavItem;

    // Called by the owner with the live overlay state; the text never contains track data.
    internal void SetObsStatus(ObsOverlayStatus status, int streams)
    {
        if (_obsStatus == status && _obsStreams == streams)
            return;
        _obsStatus = status;
        _obsStreams = streams;
        UpdateObsControls(announce: true);
    }

    internal void SetObsGuideResult(string text)
    {
        if (_closed)
            return;
        ObsGuideResult.Text = text;
        if (FrameworkElementAutomationPeer.FromElement(ObsGuideResult) is { } peer)
            peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private void UpdateObsControls(bool announce)
    {
        var on = ObsOverlayCheckBox.IsChecked == true;
        ObsHidePausedCheckBox.IsEnabled = on;
        var text = on == _initial.ObsOverlay
            ? ObsStatusMessage(_obsStatus, _obsStreams)
            : on ? "Turns on after Save" : "Turns off after Save";
        if (ObsStatusText.Text == text)
            return;
        ObsStatusText.Text = text;
        AutomationProperties.SetName(ObsStatusText, text.Length == 0 ? "OBS overlay status" : text);
        if (announce && FrameworkElementAutomationPeer.FromElement(ObsStatusText) is { } peer)
            peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private static string ObsStatusMessage(ObsOverlayStatus status, int n) => status switch
    {
        ObsOverlayStatus.Waiting => "Waiting for OBS",
        ObsOverlayStatus.Connected => $"Connected to {n} source{(n == 1 ? "" : "s")}",
        ObsOverlayStatus.PrefixInUse => "Couldn't start: another app, or another Nativune, is using the overlay link.",
        ObsOverlayStatus.AccessDenied => "Couldn't start: Windows blocked the overlay link.",
        ObsOverlayStatus.Failed => "Couldn't start the overlay.",
        _ => "Off"
    };

    private void CopyObsLink()
    {
        try
        {
            var package = new DataPackage();
            package.SetText(ObsLinkTextBox.Text);
            Clipboard.SetContent(package);
            ObsCopyLinkResult.Text = "Link copied.";
        }
        catch (Exception ex) when (ex is COMException or UnauthorizedAccessException)
        {
            ObsCopyLinkResult.Text = "The clipboard is not available right now.";
        }
        if (FrameworkElementAutomationPeer.FromElement(ObsCopyLinkResult) is { } peer)
            peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private void OnNavSelectionChanged(NavigationView sender, NavigationViewSelectionChangedEventArgs args)
    {
        var tag = (args.SelectedItem as NavigationViewItem)?.Tag as string ?? "General";
        GeneralPage.Visibility = tag == "General" ? Visibility.Visible : Visibility.Collapsed;
        StartupPage.Visibility = tag == "Startup" ? Visibility.Visible : Visibility.Collapsed;
        ShortcutsPage.Visibility = tag == "Shortcuts" ? Visibility.Visible : Visibility.Collapsed;
        PrivacyPage.Visibility = tag == "Privacy" ? Visibility.Visible : Visibility.Collapsed;
        DiscordPage.Visibility = tag == "Discord" ? Visibility.Visible : Visibility.Collapsed;
        ObsPage.Visibility = tag == "Obs" ? Visibility.Visible : Visibility.Collapsed;
        LyricsPage.Visibility = tag == "Lyrics" ? Visibility.Visible : Visibility.Collapsed;
        EqualizerPage.Visibility = tag == "Equalizer" ? Visibility.Visible : Visibility.Collapsed;
        AboutPage.Visibility = tag == "About" ? Visibility.Visible : Visibility.Collapsed;
        RestoreButton.Visibility = tag == "Shortcuts" ? Visibility.Visible : Visibility.Collapsed;
        PageScroller.ChangeView(null, 0, null, disableAnimation: true);
    }

    private void CopyStatus()
    {
        if (_statusText is null)
            return;
        try
        {
            var package = new DataPackage();
            package.SetText(_statusText().TrimEnd() + Environment.NewLine + "Discord: " + DiscordStatusCopyName(_discordStatus));
            Clipboard.SetContent(package);
            CopyStatusResult.Text = "Application status copied.";
        }
        catch (Exception ex) when (ex is COMException or UnauthorizedAccessException)
        {
            CopyStatusResult.Text = "The clipboard is not available right now.";
        }
        if (FrameworkElementAutomationPeer.FromElement(CopyStatusResult) is { } peer)
            peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    // Opens the Ko-fi page in the default browser; only a failure is announced (in the About page's result line).
    private async Task OpenDonationPageAsync()
    {
        if (await AppVersion.TryOpenDonationPageAsync() || _closed)
            return;
        CopyStatusResult.Text = AppVersion.DonationFailedMessage;
        if (FrameworkElementAutomationPeer.FromElement(CopyStatusResult) is { } peer)
            peer.RaiseAutomationEvent(AutomationEvents.LiveRegionChanged);
    }

    private void CloseWithoutSaving()
    {
        if (_closed || _closeRequested)
            return;
        _closeRequested = true;
        Close();
    }

    private void ShowError(string message)
    {
        ErrorText.Text = message;
        ErrorHost.Visibility = Visibility.Visible;
        AutomationProperties.SetHelpText(ErrorText, message);
    }

    private void HideError()
    {
        ErrorText.Text = string.Empty;
        ErrorHost.Visibility = Visibility.Collapsed;
        AutomationProperties.SetHelpText(ErrorText, string.Empty);
    }

    private void CaptureOwnerFocus(Window owner)
    {
        if (owner.Content is not FrameworkElement root || root.XamlRoot is null)
            return;
        _ownerFocus = FocusManager.GetFocusedElement(root.XamlRoot) as Control;
    }

    private void OnOwnerClosed(object sender, WindowEventArgs args)
    {
        _ownerClosed = true;
        CloseWithoutSaving();
    }

    private async void OnDialogClosed(object sender, WindowEventArgs args)
    {
        if (_closed)
            return;
        _closed = true;
        _eqPreviewTimer.Stop();
        _unsubscribeEqualizer?.Invoke();
        try
        {
            // The final host revision supersedes every dispatched preview, including one still in flight.
            if ((_eqEdited || _eqRecoveryOff) && _previewEqualizer is not null)
            {
                var committed = _eqRecoveryOff ? _initial.Equalizer with { Enabled = false } : _initial.Equalizer;
                await _previewEqualizer(EqualizerApply.From(_saved ? _equalizer : committed, bypass: false));
            }
        }
        catch (Exception) { /* The host owns unavailable/interrupted status; closing must still finish. */ }
        CleanupModal();
        _completion?.TrySetResult(_saved);
    }

    private void CleanupModal()
    {
        if (_owner is not null)
            _owner.Closed -= OnOwnerClosed;

        if (_nativeOwnerSet && _dialogHandle != 0 && IsWindow(_dialogHandle))
        {
            SetWindowLongPtr(_dialogHandle, GwlpHwndParent, _previousNativeOwner);
            _nativeOwnerSet = false;
        }

        var owner = _owner;
        if (owner is null || _ownerClosed || !_ownerWasEnabled
            || _ownerHandle == 0 || !IsWindow(_ownerHandle))
            return;

        EnableWindow(_ownerHandle, true);
        if (!IsWindowVisible(_ownerHandle))
            return;

        try
        {
            owner.Activate();
            RestoreOwnerFocus(owner);
        }
        catch (Exception ex) when (ex is COMException or InvalidOperationException)
        {
            // The owner may be in its own shutdown callback. It is already
            // safe to leave focus to the shell in that case.
        }
    }

    private void RestoreOwnerFocus(Window owner)
    {
        if (owner.Content is not FrameworkElement root || root.XamlRoot is not { } xamlRoot)
            return;

        if (TryFocus(_ownerFocus, xamlRoot))
            return;

        var first = FocusManager.FindFirstFocusableElement(root);
        TryFocus(first, xamlRoot);
    }

    private static bool TryFocus(DependencyObject? candidate, XamlRoot xamlRoot)
    {
        if (candidate is not Control control
            || !control.IsLoaded
            || !control.IsEnabled
            || control.XamlRoot != xamlRoot)
            return false;

        return control.Focus(FocusState.Programmatic);
    }
    private void SetNativeOwner()
    {
        if (_dialogHandle == 0 || _ownerHandle == 0)
            return;

        _previousNativeOwner = GetWindowLongPtr(_dialogHandle, GwlpHwndParent);
        SetWindowLongPtr(_dialogHandle, GwlpHwndParent, _ownerHandle);
        _nativeOwnerSet = true;
    }

    private void SizeAndCenter()
    {
        if (_dialogHandle == 0)
            return;

        var dialogId = Win32Interop.GetWindowIdFromWindow(_dialogHandle);
        var appWindow = AppWindow.GetFromWindowId(dialogId);
        var targetId = _ownerHandle == 0
            ? dialogId
            : Win32Interop.GetWindowIdFromWindow(_ownerHandle);
        var targetHandle = _ownerHandle == 0 ? _dialogHandle : _ownerHandle;
        var scale = Math.Max(1d, GetDpiForWindow(targetHandle) / 96d);
        var requestedWidth = Math.Max(1, (int)Math.Round(DialogWidthDip * scale, MidpointRounding.AwayFromZero));
        var requestedHeight = Math.Max(1, (int)Math.Round(DialogHeightDip * scale, MidpointRounding.AwayFromZero));
        var workArea = DisplayArea.GetFromWindowId(targetId, DisplayAreaFallback.Nearest).WorkArea;
        var width = Math.Min(requestedWidth, Math.Max(1, workArea.Width));
        var height = Math.Min(requestedHeight, Math.Max(1, workArea.Height));
        appWindow.ResizeClient(new SizeInt32(width, height));

        var ownerWindow = _ownerHandle == 0
            ? null
            : AppWindow.GetFromWindowId(targetId);
        var ownerPosition = ownerWindow?.Position ?? new PointInt32(workArea.X, workArea.Y);
        var ownerSize = ownerWindow?.Size ?? new SizeInt32(width, height);
        var x = ownerPosition.X + (ownerSize.Width - width) / 2;
        var y = ownerPosition.Y + (ownerSize.Height - height) / 2;
        var maxX = workArea.X + Math.Max(0, workArea.Width - width);
        var maxY = workArea.Y + Math.Max(0, workArea.Height - height);
        appWindow.Move(new PointInt32(
            Math.Clamp(x, workArea.X, maxX),
            Math.Clamp(y, workArea.Y, maxY)));
    }

    private static bool IsDown(VirtualKey key)
        => (InputKeyboardSource.GetKeyStateForCurrentThread(key) & CoreVirtualKeyStates.Down) != 0;

    private static bool IsModifierKey(VirtualKey key)
        => (uint)key is 0x10 or 0x11 or 0x12 or 0xA0 or 0xA1 or 0xA2 or 0xA3 or 0xA4 or 0xA5;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetDpiForWindow(nint hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool IsWindow(nint hWnd);
    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool IsWindowVisible(nint hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool IsWindowEnabled(nint hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern bool EnableWindow(nint hWnd, bool enable);

    [DllImport("user32.dll", EntryPoint = "GetWindowLongPtrW", SetLastError = true)]
    private static extern nint GetWindowLongPtr(nint hWnd, int index);

    [DllImport("user32.dll", EntryPoint = "SetWindowLongPtrW", SetLastError = true)]
    private static extern nint SetWindowLongPtr(nint hWnd, int index, nint value);
}
