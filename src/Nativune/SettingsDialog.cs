using System.ComponentModel;
using Microsoft.UI;
using System.Runtime.InteropServices;
using Microsoft.UI.Input;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Windows.Graphics;
using Windows.System;
using Windows.UI.Core;
using WinRT.Interop;

namespace Nativune;

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
    private const double DialogWidthDip = 640;
    private const double DialogHeightDip = 520;

    private readonly ShellSettings _initial;
    private readonly Func<ShortcutBindings, string?> _applyBindings;
    private readonly TextBox[] _bindingFields;
    private readonly int[] _values;
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

    internal SettingsDialog(ShellSettings initial, Func<ShortcutBindings, string?> applyBindings)
    {
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
        VersionText.Text = AppVersion.DisplayName;
        AutomationProperties.SetName(VersionText, $"Application version {AppVersion.Number}");

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
        SaveButton.Click += (_, _) => Save();
        CancelButton.Click += (_, _) => CloseWithoutSaving();
        Root.Loaded += OnRootLoaded;
        Root.KeyDown += OnRootKeyDown;
        Closed += OnDialogClosed;
    }

    internal ShellSettings Result { get; private set; }

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
            ToggleField.Focus(FocusState.Programmatic);
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
            && args.OriginalSource is not Button)
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
            Shortcuts = bindings
        };
        _saved = true;
        Close();
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

    private void OnDialogClosed(object sender, WindowEventArgs args)
    {
        if (_closed)
            return;
        _closed = true;
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
