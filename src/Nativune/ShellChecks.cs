using System.Drawing;
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using FoundationRect = Windows.Foundation.Rect;
using FoundationSize = Windows.Foundation.Size;
using WinRT.Interop;
using UiColor = Windows.UI.Color;

namespace Nativune;

internal static class ShellChecks
{
    private const string InitialUri = "https://music.youtube.com/";

    internal static void Run(string root)
    {
        var settings = new ShellSettings(4000, -2000, 1000, 700, 96, true, 1.25)
        {
            TrayEnabled = true,
            RestoreSection = true,
            LastSection = "library",
            SleepInBackground = false,
        };
        ShellSettings.SaveAsync(root, settings, CancellationToken.None).GetAwaiter().GetResult();
        var loaded = ShellSettings.Load(root, out var warning);
        Require(warning is null && loaded == settings, "Window settings did not survive a save and reload.");

        var area = new Rectangle(-1280, 0, 1280, 720);
        var bounds = ShellSettings.RestoreBounds(loaded, area, 144);
        Require(area.Contains(bounds) && bounds.Width >= 640 && bounds.Height >= 480,
            "Restored window is inaccessible after display/DPI change.");
        var small = new Rectangle(0, 0, 500, 350);
        Require(small.Contains(ShellSettings.RestoreBounds(loaded, small, 192)),
            "Small work area clipping failed.");

        var file = Path.Combine(root, "data", "settings.json");
        Require(loaded.StartupUri == "https://music.youtube.com/library"
            && (loaded with { RestoreSection = false }).StartupUri == "https://music.youtube.com/",
            "Section restoration ignored its opt-in boundary.");
        Require(ShellSettings.SectionFromUri(new Uri("https://music.youtube.com/library?private=value")) == "library"
            && ShellSettings.SectionFromUri(new Uri("https://music.youtube.com/playlist?list=private")) is null
            && ShellSettings.SectionFromUri(new Uri("https://music.youtube.com.evil.example/library")) is null
            && ShellSettings.SectionFromUri(new Uri("https://user@music.youtube.com/library")) is null,
            "Section classification accepted a private route or untrusted origin.");

        ShellSettings.SaveAsync(root, settings with { LastSection = "https://evil.example/private" },
            CancellationToken.None).GetAwaiter().GetResult();
        Require(ShellSettings.Load(root, out _).LastSection == "home", "Unrecognized section was retained.");
        File.WriteAllText(file,
            "{\"Version\":1,\"X\":100,\"Y\":100,\"Width\":1234,\"Height\":800,\"Dpi\":96,\"Maximized\":false,\"Zoom\":1}");
        var previous = ShellSettings.Load(root, out warning);
        Require(warning is null && previous.Width == 1234 && !previous.TrayEnabled
            && !previous.RestoreSection && previous.Zoom == 1 && previous.SleepInBackground,
            "Existing P1 settings changed optional behavior during upgrade.");
        File.WriteAllText(file,
            "{\"Version\":2,\"X\":100,\"Y\":100,\"Width\":1234,\"Height\":800,\"Dpi\":96,\"Maximized\":false,\"Zoom\":1}");
        var previousV2 = ShellSettings.Load(root, out warning);
        Require(warning is null && previousV2.SleepInBackground,
            "Existing P2 settings did not retain background sleeping during upgrade.");
        var sleepingArguments = WebHostWindow.BrowserArguments(sleepInBackground: true);
        var activeArguments = WebHostWindow.BrowserArguments(sleepInBackground: false);
        Require(!sleepingArguments.Contains("--disable-background-timer-throttling", StringComparison.Ordinal)
            && activeArguments.Contains("--disable-background-timer-throttling", StringComparison.Ordinal)
            && activeArguments.Contains("--disable-renderer-backgrounding", StringComparison.Ordinal)
            && activeArguments.Contains("--disable-backgrounding-occluded-windows", StringComparison.Ordinal),
            "Background sleeping did not map to Chromium throttling arguments.");
        File.WriteAllText(file, "{broken");
        _ = ShellSettings.Load(root, out warning);
        Require(warning is not null, "Corrupt settings were silently accepted.");
        File.WriteAllText(file, new string(' ', 16385));
        _ = ShellSettings.Load(root, out warning);
        Require(warning is not null, "Oversized settings were accepted.");
        ShellSettings.SaveAsync(root, settings, CancellationToken.None).GetAwaiter().GetResult();

        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        try
        {
            ShellSettings.SaveAsync(root, settings with { Zoom = 1 }, cancelled.Token)
                .GetAwaiter().GetResult();
            throw new SelfCheckException("Cancelled settings save was accepted.");
        }
        catch (OperationCanceledException) { }
        Require(ShellSettings.Load(root, out _) == settings, "Cancelled save replaced existing settings.");

        using var timer = new SleepDeadline(() => throw new SelfCheckException("Cancelled timer fired."),
            new SynchronizationContext());
        timer.Arm(TimeSpan.FromSeconds(1));
        Require(timer.TimeRemaining is { } remaining && remaining > TimeSpan.Zero
            && remaining <= TimeSpan.FromSeconds(1),
            "Pause timer remaining time escaped its monotonic deadline.");
        Require(timer.IsArmed, "Pause timer did not arm.");
        timer.Cancel();
        timer.CheckOnResume();
        Require(!timer.IsArmed && timer.TimeRemaining is null,
            "Cancelled pause timer stayed armed after resume.");
        try
        {
            timer.Arm(TimeSpan.Zero);
            throw new SelfCheckException("Invalid pause duration was accepted.");
        }
        catch (ArgumentOutOfRangeException) { }

        ShortcutChecks.Run();
        CompactViewChecks.Run();
        CompactPlaybackChecks.Run();
        CheckNativeHost(root);
        Console.WriteLine("Shell checks passed: persisted settings, DPI/off-screen repair, corrupt/oversized input, cancelled writes, timer cancellation and WinUI native lifecycle.");
    }


    private static void CheckNativeIconResources()
    {
        var names = new[]
        {
            "app-mark", "back", "cancel-timer", "close", "compact", "dislike",
            "error", "exit-fullscreen", "forward", "fullscreen", "hide", "home",
            "like", "minimize", "next", "overflow", "pause", "pin", "play-pause",
            "play", "previous", "quit-timer", "quit", "repeat-one", "repeat",
            "restore-section", "restore-window", "retry", "settings", "show",
            "shuffle", "status", "tray", "volume-muted", "volume", "zoom-in",
            "zoom-out", "zoom-reset"
        };
        Require(names.Length == 38, "Native icon registry must contain exactly 38 active canonical names.");

        var resources = typeof(ShellChecks).Assembly.GetManifestResourceNames();
        Require(!resources.Any(name => name.Contains(".notifications", StringComparison.Ordinal)),
            "Removed song-notification icons are still bundled.");
        foreach (var rasterSize in new[] { 16, 20, 24, 25, 30, 32, 40, 48, 64 })
        {
            foreach (var name in names)
                Require(resources.Contains($"Nativune.NativeIcons.{rasterSize}.{name}.png", StringComparer.Ordinal),
                    $"Native icon resource is missing: {rasterSize}/{name}.");
        }

        using var cache = new NativeIconCache();
        foreach (var name in names)
        {
            var element = cache.CreateElement(name, 20);
            Require(element is not null, $"Native icon element was not created: {name}.");
            var handle = cache.CreateOwnedIcon(name, 20, Color.FromArgb(0xF1, 0xF1, 0xF1));
            Require(handle != 0, $"Native icon handle was not created: {name}.");
            NativeIconCache.DestroyIcon(handle);
        }
        try
        {
            _ = cache.CreateElement("unknown-native-icon", 20);
            throw new SelfCheckException("Unknown native icon name was accepted.");
        }
        catch (ArgumentException) { }
        try
        {
            _ = cache.CreateOwnedIcon("play", 7, Color.White);
            throw new SelfCheckException("Undersized native icon request was accepted.");
        }
        catch (ArgumentOutOfRangeException) { }

        cache.Dispose();
        cache.Dispose();
        try
        {
            _ = cache.CreateElement("play", 20);
            throw new SelfCheckException("Disposed native icon cache accepted a new element.");
        }
        catch (ObjectDisposedException) { }
    }
    private static void CheckNativeAccentResources()
    {
        var resources = Application.Current?.Resources
            ?? throw new SelfCheckException("Application resources were unavailable for native accent checks.");
        var highContrast = ShellTheme.IsHighContrast;
        var expectedAccent = highContrast
            ? ResolveColorResource(resources, "SystemColorHighlightColor")
            : Microsoft.UI.ColorHelper.FromArgb(0xFF, 0xFF, 0x00, 0x33);

        if (!highContrast)
            Require(ColorsEqual(ResolveColorResource(resources, "SystemAccentColorLight2"), expectedAccent),
                "WinUI derived SystemAccentColorLight2 did not resolve to the active native accent.");
        foreach (var key in new[]
        {
            "CheckBoxCheckBackgroundFillChecked",
            "CheckBoxCheckBackgroundStrokeChecked",
            "SliderTrackValueFill",
            "TextControlBorderBrushFocused"
        })
            Require(BrushContainsColor(ResolveResource(resources, key), expectedAccent),
                $"Native accent resource {key} did not resolve through the app accent.");

        var expectedThumb = highContrast
            ? ResolveColorResource(resources, "SystemColorButtonTextColor")
            : expectedAccent;
        Require(BrushContainsColor(ResolveResource(resources, "SliderThumbBackground"), expectedThumb),
            "Native slider thumb did not resolve to the active theme color.");

        if (!highContrast)
            Require(IsDark(ResolveSolidBrushColor(resources, "TextOnAccentFillColorPrimaryBrush")),
                "Normal text/glyph resources must remain dark on the red native accent.");
    }

    private static object ResolveResource(ResourceDictionary resources, string key)
    {
        Require(resources.ContainsKey(key), $"Native resource is missing: {key}.");
        var value = resources[key];
        return value ?? throw new SelfCheckException($"Native resource resolved to null: {key}.");
    }

    private static UiColor ResolveColorResource(ResourceDictionary resources, string key)
    {
        var value = ResolveResource(resources, key);
        if (value is UiColor color)
            return color;
        if (value is SolidColorBrush brush)
            return brush.Color;
        throw new SelfCheckException($"Native color resource has unexpected type: {key}.");
    }

    private static UiColor ResolveSolidBrushColor(ResourceDictionary resources, string key)
    {
        var value = ResolveResource(resources, key);
        Require(value is SolidColorBrush, $"Native brush resource has unexpected type: {key}.");
        return ((SolidColorBrush)value).Color;
    }

    private static bool BrushContainsColor(object value, UiColor expected)
        => value switch
        {
            SolidColorBrush brush => ColorsEqual(brush.Color, expected),
            LinearGradientBrush gradient => gradient.GradientStops.Any(
                stop => ColorsEqual(stop.Color, expected)),
            _ => false
        };

    private static bool IsDark(UiColor color)
        => color.R < 0x80 && color.G < 0x80 && color.B < 0x80;

    private static bool ColorsEqual(UiColor left, UiColor right)
        => left.A == right.A && left.R == right.R && left.G == right.G && left.B == right.B;


    private static void CheckTrayCallbackRouting()
    {
        const uint trayIconId = 1;
        const uint wmRButtonUp = 0x0205;
        var window = CreateWindowEx(
            0, "Static", string.Empty, 0, 0, 0, 1, 1, 0, 0, 0, 0);
        if (window == 0)
            throw new SelfCheckException(
                $"Tray routing check could not create its native owner ({Marshal.GetLastWin32Error()}).");

        try
        {
            using var icons = new NativeIconCache();
            var commandCount = 0;
            var tray = new NativeTrayIcon(window, icons, _ => commandCount++);
            try
            {
                tray.SetVisible(true);
                tray.SetPlaybackEnabled(false);
                var packedNotification = unchecked((nint)((trayIconId << 16) | wmRButtonUp));
                var handled = tray.HandleMessage(
                    NativeTrayIcon.CallbackMessage, 0, packedNotification, out var result);
                Require(handled && result == 0 && commandCount == 0,
                    "Tray WM_RBUTTONUP callback opened or dispatched a menu.");
            }
            finally
            {
                tray.Dispose();
            }
        }
        finally
        {
            if (!DestroyWindow(window) && IsWindow(window))
                throw new SelfCheckException("Tray routing check did not destroy its native owner.");
        }
    }

    private static void CheckNativeHost(string root)
    {
        var completion = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        Exception? failure = null;
        Exception? threadFailure = null;
        var thread = new Thread(() =>
        {
            try
            {
                ShellApplication.Run(() => _ = RunNativeSessionAsync(root, completion));
            }
            catch (Exception exception)
            {
                threadFailure = exception;
                completion.TrySetException(exception);
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();

        failure = threadFailure;
        if (failure is null && !completion.Task.IsCompleted)
            failure = new SelfCheckException("Native STA session returned without signaling completion.");
        if (failure is null)
        {
            try { completion.Task.GetAwaiter().GetResult(); }
            catch (Exception exception) { failure = exception; }
        }

        if (failure is not null)
            throw new SelfCheckException(
                $"Native WinUI startup/disposal contract failed: {failure.GetBaseException().GetType().Name}: {failure.GetBaseException().Message}");
    }

    private static async Task RunNativeSessionAsync(
        string root, TaskCompletionSource<bool> completion)
    {
        WebHostWindow? host = null;
        Exception? failure = null;
        var phase = "startup";
        try
        {
            // IconElement creation needs the initialized XAML application and stays in this
            // single STA session with the rest of the native checks.
            phase = "icon-resources";
            CheckNativeIconResources();
            phase = "tray-routing";
            CheckTrayCallbackRouting();
            phase = "host-create";
            host = new WebHostWindow(root, InitialUri, initializeBrowser: false);
            host.RequestActivation();
            if (host.Content is not FrameworkElement content)
                throw new SelfCheckException("WinUI host did not expose a FrameworkElement root.");
            phase = "full-layout";
            await AwaitLoadedAsync(content);
            PrepareContent(content);
            phase = "accent-resources";
            CheckNativeAccentResources();
            Require(host.NativeHandle != 0, "WinUI host did not create a native HWND.");
            Require(!host.IsCompact, "WinUI host entered Compact mode during full startup.");
            Require(content.XamlRoot is not null, "WinUI root was not loaded before native checks.");
            foreach (var name in new[] { "PreviousButton", "PlayPauseButton", "NextButton" })
            {
                var control = FindElement(content, name) as Control;
                Require(control is not null && !control.IsEnabled,
                    $"Native transport became available without a website player: {name}.");
            }

            phase = "full-state";
            const BindingFlags privateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
            var versionItem = typeof(WebHostWindow).GetField("_versionItem", privateInstance)
                ?.GetValue(host) as MenuFlyoutItem;
            Require(versionItem is not null && !versionItem.IsEnabled
                && versionItem.Text == AppVersion.DisplayName,
                "Full More commands menu did not expose the noninteractive application version.");
            var setStatus = typeof(WebHostWindow).GetMethod("SetStatus", privateInstance);
            Require(setStatus is not null, "WinUI host status method was not retained.");
            setStatus!.Invoke(host, [new string('x', 8192), true, false]);
            var status = FindElement(content, "StatusText") as TextBlock;
            Require(status?.Text.Length == 4096,
                "Oversized native status was not bounded before presentation.");

            var timerExpired = typeof(WebHostWindow).GetMethod("OnTimerExpired", privateInstance);
            Require(timerExpired is not null, "WinUI pause timer expiry hook was not retained.");
            timerExpired!.Invoke(host, null);
            Require(host.NativeHandle != 0 && IsWindow(host.NativeHandle) && host.ExitCode == 0,
                "Pause timer expiry closed or failed the native shell.");

            phase = "pause-dialog";
            await CheckPauseTimerDialogAsync(host, privateInstance);

            phase = "compact-lifecycle";
            var handle = host.NativeHandle;
            host.SetCompact(true);
            if (host.Content is not FrameworkElement compactContent)
                throw new SelfCheckException("Compact presenter did not expose a XAML root.");
            await AwaitLoadedAsync(compactContent);
            PrepareContent(compactContent);
            Require(host.IsCompact && host.NativeHandle == handle,
                "Compact presenter changed mode or recreated the owned HWND.");
            phase = "compact-checks";
            await CompactViewChecks.RunNativeAsync(host);

            host.SetCompact(false);
            if (host.Content is not FrameworkElement fullContent)
                throw new SelfCheckException("Full presenter did not expose a XAML root.");
            await AwaitLoadedAsync(fullContent);
            PrepareContent(fullContent);
            Require(!host.IsCompact && host.NativeHandle == handle,
                "Returning to full mode did not restore the same native presenter.");
            phase = "shutdown";
            await host.ShutdownAsync().WaitAsync(TimeSpan.FromSeconds(5));
            host = null;
        }
        catch (Exception exception)
        {
            failure = exception;
            var baseException = exception.GetBaseException();
            Console.Error.WriteLine(
                $"Native shell check phase '{phase}' failed: {baseException.GetType().Name}: {baseException.Message}");
        }
        finally
        {
            if (host is not null)
            {
                try { await host.ShutdownAsync().WaitAsync(TimeSpan.FromSeconds(5)); }
                catch (Exception exception) { failure ??= exception; }
            }

            if (failure is not null)
                completion.TrySetException(failure);
            else
                completion.TrySetResult(true);
            var dispatcher = Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread()
                ?? throw new InvalidOperationException("Native shell dispatcher queue was unavailable.");
            dispatcher.EnqueueEventLoopExit();
        }
    }

    private static async Task CheckPauseTimerDialogAsync(
        WebHostWindow host, BindingFlags privateInstance)
    {
        var openTimer = typeof(WebHostWindow).GetMethod("SetPauseTimer", privateInstance);
        Require(openTimer is not null, "WinUI pause timer dialog entry point was not retained.");
        openTimer!.Invoke(host, null);

        Window? dialog = null;
        for (var attempt = 0; attempt < 250; attempt++)
        {
            dialog = host.TimerDialogForChecks;
            if (dialog is not null)
                break;
            await Task.Delay(20);
        }

        var pauseDialog = dialog
            ?? throw new SelfCheckException("Pause timer dialog did not open in the native check.");
        Require(host.IsTimerDialogOpenForChecks,
            "Pause timer dialog did not retain its active lifecycle state.");
        Require(!IsWindowEnabled(host.NativeHandle),
            "Pause timer dialog did not disable its native owner.");
        var dialogHandle = WindowNative.GetWindowHandle(pauseDialog);
        Require(dialogHandle != 0 && IsWindow(dialogHandle) && IsWindowVisible(dialogHandle),
            "Pause timer dialog HWND was not visible after activation.");
        if (pauseDialog.Content is not FrameworkElement dialogContent)
            throw new SelfCheckException("Pause timer dialog did not expose a XAML content root.");

        await AwaitLoadedAsync(dialogContent);
        dialogContent.UpdateLayout();
        Require(dialogContent.ActualWidth > 0 && dialogContent.ActualHeight > 0,
            "Pause timer dialog content did not receive its actual layout.");
        var numberBoxes = FindElements<NumberBox>(dialogContent)
            .Where(numberBox => numberBox.Header is not null)
            .ToArray();
        Require(numberBoxes.Length == 3
            && numberBoxes.Select(numberBox => numberBox.Header?.ToString())
                .SequenceEqual(new[] { "Hours", "Minutes", "Seconds" }),
            "Pause timer dialog did not retain all three NumberBox fields.");
        Require(numberBoxes.All(numberBox =>
                numberBox.ActualWidth > 0 && numberBox.ActualHeight > 0
                && VisualTreeHelper.GetChildrenCount(numberBox) > 0),
            "Pause timer NumberBox templates did not load and lay out.");
        var setButton = FindElements<Button>(dialogContent)
            .FirstOrDefault(button => string.Equals(button.Content?.ToString(), "Set timer", StringComparison.Ordinal));
        var cancelButton = FindElements<Button>(dialogContent)
            .FirstOrDefault(button => string.Equals(button.Content?.ToString(), "Cancel", StringComparison.Ordinal));
        Require(setButton is not null && cancelButton is not null
            && setButton.IsEnabled && cancelButton.IsEnabled,
            "Pause timer dialog actions did not load as enabled native buttons.");

        pauseDialog.Close();
        for (var attempt = 0; attempt < 250; attempt++)
        {
            if (host.TimerDialogForChecks is null && !host.IsTimerDialogOpenForChecks)
                break;
            await Task.Delay(20);
        }
        Require(host.TimerDialogForChecks is null && !host.IsTimerDialogOpenForChecks,
            "Pause timer dialog did not complete its close lifecycle.");
        Require(IsWindowEnabled(host.NativeHandle),
            "Pause timer dialog did not restore its native owner.");
    }

    private static IEnumerable<T> FindElements<T>(DependencyObject root)
        where T : DependencyObject
    {
        if (root is T match)
            yield return match;
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var index = 0; index < count; index++)
        {
            foreach (var child in FindElements<T>(VisualTreeHelper.GetChild(root, index)))
                yield return child;
        }
    }

    private static async Task AwaitLoadedAsync(FrameworkElement element)
    {
        if (element.XamlRoot is not null && element.ActualWidth > 0 && element.ActualHeight > 0)
            return;

        var loaded = new TaskCompletionSource<bool>(
            TaskCreationOptions.RunContinuationsAsynchronously);
        RoutedEventHandler handler = (_, _) => loaded.TrySetResult(true);
        element.Loaded += handler;
        try
        {
            element.UpdateLayout();
            if (element.XamlRoot is not null && element.ActualWidth > 0 && element.ActualHeight > 0)
                return;
            await loaded.Task.WaitAsync(TimeSpan.FromSeconds(5));
        }
        finally { element.Loaded -= handler; }
    }

    private static void PrepareContent(FrameworkElement content)
    {
        content.Measure(new FoundationSize(1200, 800));
        content.Arrange(new FoundationRect(0, 0, 1200, 800));
        content.UpdateLayout();
        Require(content.ActualWidth > 0 && content.ActualHeight > 0,
            "WinUI root did not receive a usable layout before native checks.");
    }

    private static FrameworkElement? FindElement(DependencyObject root, string name)
    {
        if (root is FrameworkElement element && element.Name == name)
            return element;
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var index = 0; index < count; index++)
        {
            var found = FindElement(VisualTreeHelper.GetChild(root, index), name);
            if (found is not null) return found;
        }
        return null;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern nint CreateWindowEx(
        uint extendedStyle,
        string className,
        string windowName,
        uint style,
        int x,
        int y,
        int width,
        int height,
        nint parent,
        nint menu,
        nint instance,
        nint parameter);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyWindow(nint window);

    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern bool IsWindow(nint window);
    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern bool IsWindowEnabled(nint window);
    [DllImport("user32.dll", ExactSpelling = true)]
    private static extern bool IsWindowVisible(nint window);
    private static void Require(bool condition, string message)
    {
        if (!condition) throw new SelfCheckException(message);
    }
}
