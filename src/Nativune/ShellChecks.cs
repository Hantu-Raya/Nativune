using System.Drawing;
using System.Reflection;
using System.Runtime.InteropServices;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using FoundationRect = Windows.Foundation.Rect;
using FoundationSize = Windows.Foundation.Size;
using WinRT.Interop;

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
            StartCompact = true,
            AutoCheckUpdates = false,
        };
        ShellSettings.SaveAsync(root, settings, CancellationToken.None).GetAwaiter().GetResult();
        var loaded = ShellSettings.Load(root, out var warning);
        Require(warning is null && loaded == settings && loaded.StartCompact && !loaded.AutoCheckUpdates,
            "Window settings or disabled automatic update checks did not survive a save and reload.");
        Require(ShellSettings.Default.TrayEnabled && ShellSettings.Default.AutoCheckUpdates,
            "New profiles did not enable tray and automatic update checks by default.");

        var area = new Rectangle(-1280, 0, 1280, 720);
        var bounds = ShellSettings.RestoreBounds(loaded, area, 144);
        Require(area.Contains(bounds) && bounds.Width >= 640 && bounds.Height >= 480,
            "Restored window is inaccessible after display/DPI change.");
        var small = new Rectangle(0, 0, 500, 350);
        Require(small.Contains(ShellSettings.RestoreBounds(loaded, small, 192)),
            "Small work area clipping failed.");

        var file = Path.Combine(root, "data", "settings.json");
        var savedSettingsText = File.ReadAllText(file);
        Require(savedSettingsText.Contains("\"Version\": 5", StringComparison.Ordinal)
            && savedSettingsText.Contains("\"StartCompact\": true", StringComparison.Ordinal)
            && savedSettingsText.Contains("\"AutoCheckUpdates\": false", StringComparison.Ordinal),
            "Current settings schema did not persist compact startup and automatic update preferences.");
        Require(loaded.StartupUri == "https://music.youtube.com/library"
            && (loaded with { RestoreSection = false }).StartupUri == "https://music.youtube.com/",
            "Section restoration ignored its opt-in boundary.");
        Require(ShellSettings.SectionFromUri(new Uri("https://music.youtube.com/library?private=value")) == "library"
            && ShellSettings.SectionFromUri(new Uri("https://music.youtube.com/playlist?list=private")) is null
            && ShellSettings.SectionFromUri(new Uri("https://music.youtube.com.evil.example/library")) is null
            && ShellSettings.SectionFromUri(new Uri("https://user@music.youtube.com/library")) is null,
            "Section classification accepted a private route or untrusted origin.");
        Require(PlayerControls.IsMusicUri("https://music.youtube.com/watch?video=synthetic")
            && !PlayerControls.IsMusicUri("https://music.youtube.com/signin")
            && !PlayerControls.IsMusicUri("https://accounts.google.com/signin")
            && !PlayerControls.IsMusicUri("https://music.youtube.com.evil.example/watch"),
            "Compact readiness route accepted an account-flow or untrusted origin.");
        Require(WebHostWindow.ShouldResumeStartupCompactAfterAccount(true, true, true, true)
            && !WebHostWindow.ShouldResumeStartupCompactAfterAccount(false, true, true, true)
            && !WebHostWindow.ShouldResumeStartupCompactAfterAccount(true, false, true, true)
            && !WebHostWindow.ShouldResumeStartupCompactAfterAccount(true, true, false, true)
            && !WebHostWindow.ShouldResumeStartupCompactAfterAccount(true, true, true, false),
            "Startup Compact resumed without a preserved opt-in, account return, and ready owned Music view.");

        ShellSettings.SaveAsync(root, settings with { LastSection = "https://evil.example/private" },
            CancellationToken.None).GetAwaiter().GetResult();
        Require(ShellSettings.Load(root, out _).LastSection == "home", "Unrecognized section was retained.");
        File.WriteAllText(file,
            "{\"Version\":1,\"X\":100,\"Y\":100,\"Width\":1234,\"Height\":800,\"Dpi\":96,\"Maximized\":false,\"Zoom\":1}");
        var previous = ShellSettings.Load(root, out warning);
        Require(warning is null && previous.Width == 1234 && !previous.TrayEnabled
            && !previous.RestoreSection && previous.Zoom == 1 && previous.SleepInBackground
            && !previous.StartCompact,
            "Existing P1 settings changed optional behavior during upgrade.");
        File.WriteAllText(file,
            "{\"Version\":2,\"X\":100,\"Y\":100,\"Width\":1234,\"Height\":800,\"Dpi\":96,\"Maximized\":false,\"Zoom\":1}");
        var previousV2 = ShellSettings.Load(root, out warning);
        Require(warning is null && previousV2.SleepInBackground && !previousV2.StartCompact,
            "Existing P2 settings did not retain optional behavior during upgrade.");
        File.WriteAllText(file,
            "{\"Version\":3,\"X\":100,\"Y\":100,\"Width\":1234,\"Height\":800,\"Dpi\":96,\"Maximized\":false,\"Zoom\":1}");
        var previousV3 = ShellSettings.Load(root, out warning);
        Require(warning is null && !previousV3.StartCompact,
            "Existing P3 settings did not default Start in Compact to off.");
        File.WriteAllText(file,
            "{\"Version\":4,\"X\":100,\"Y\":100,\"Width\":1234,\"Height\":800,\"Dpi\":96,\"Maximized\":false,\"Zoom\":1,\"StartCompact\":false}");
        var previousV4 = ShellSettings.Load(root, out warning);
        Require(warning is null && previousV4.AutoCheckUpdates,
            "Existing P4 settings without the automatic update preference did not default to true.");
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
        // Leave shared settings at full startup; the isolated native fixture covers opt-in Compact.
        ShellSettings.SaveAsync(root, settings with { StartCompact = false }, CancellationToken.None)
            .GetAwaiter().GetResult();

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

        CheckReleaseUpdateButtonPresentations();
        ShortcutChecks.Run();
        CompactViewChecks.Run();
        CompactPlaybackChecks.Run();
        CheckNativeHost(root);
        Console.WriteLine("Shell checks passed: persisted settings, DPI/off-screen repair, corrupt/oversized input, cancelled writes, timer cancellation and WinUI native lifecycle.");
    }


    private static void CheckReleaseUpdateButtonPresentations()
    {
        var version = "v0.1.17";
        var expected = new Dictionary<ReleaseUpdateButtonState, (string Icon, bool Enabled)>
        {
            [ReleaseUpdateButtonState.NotChecked] = ("update", true),
            [ReleaseUpdateButtonState.NotInstalled] = ("update", true),
            [ReleaseUpdateButtonState.Checking] = ("update", false),
            [ReleaseUpdateButtonState.Available] = ("update-available", true),
            [ReleaseUpdateButtonState.UpToDate] = ("update", true),
            [ReleaseUpdateButtonState.Failed] = ("update", true),
            [ReleaseUpdateButtonState.Downloading] = ("update-available", true),
            [ReleaseUpdateButtonState.Verifying] = ("update", false),
            [ReleaseUpdateButtonState.Launching] = ("update", false),
        };
        foreach (var (state, values) in expected)
        {
            var presentation = WebHostWindow.GetReleaseUpdateButtonPresentation(state, version);
            Require(presentation.IconName == values.Icon && presentation.IsEnabled == values.Enabled
                && !string.IsNullOrWhiteSpace(presentation.Tooltip),
                $"Update button presentation was incomplete for {state}.");
        }

        using var icons = new NativeIconCache();
        using var taskbar = new TaskbarControls(0, _ => { }, icons, 96, Color.White);
        taskbar.SetProgress(42, 100);
        taskbar.SetProgressState(TaskbarControls.TaskbarProgressState.Normal);
    }

    private static void CheckUpdateFeedback(WebHostWindow host)
    {
        const BindingFlags privateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
        const string notice = "Downloading update · 42 % · 4.1 MB/s";
        var update = new ReleaseUpdateResult(ReleaseUpdateStatus.Available, "v0.1.17",
            "https://github.com/example/Nativune-Setup.exe", null, 100, new string('0', 64), null);
        var apply = typeof(WebHostWindow).GetMethod("ApplyUpdateFeedback", privateInstance)
            ?? throw new SelfCheckException("Update feedback owner was unavailable.");
        apply.Invoke(host,
        [
            ReleaseUpdateButtonState.Downloading,
            update,
            new ReleaseUpdateProgress(ReleaseUpdatePhase.Downloading, 42, 100),
            null,
            true,
            notice,
            false
        ]);

        var bar = FindElement((DependencyObject)host.Content!, "UpdateInfoBar") as InfoBar;
        ((FrameworkElement)host.Content!).UpdateLayout();
        bar?.UpdateLayout();
        var progress = (bar?.Content as StackPanel)?.Children.OfType<ProgressBar>().FirstOrDefault();
        Require(bar is { IsOpen: true } && bar.Title.Contains("v0.1.17", StringComparison.Ordinal)
            && bar.Message.Contains("42", StringComparison.Ordinal)
            && progress is { IsIndeterminate: false } && Math.Abs(progress.Value - 42) < 0.01,
            "Download feedback did not update the InfoBar title, message, and progress.");
        var compact = FindElement((DependencyObject)host.Content!, "CompactView") as CompactPlayerView;
        var compactNotice = typeof(CompactPlayerView).GetField("_updateNotice", privateInstance)
            ?.GetValue(compact) as string;
        Require(compactNotice == notice, "Compact did not receive the persistent update notice.");

        bar!.IsOpen = false;
        compact!.SetUpdateProgress(null, false);
        var taskbar = typeof(WebHostWindow).GetField("_taskbarControls", privateInstance)
            ?.GetValue(host) as TaskbarControls;
        taskbar?.SetProgressState(TaskbarControls.TaskbarProgressState.NoProgress);
        var tray = typeof(WebHostWindow).GetField("_tray", privateInstance)
            ?.GetValue(host) as NativeTrayIcon;
        tray?.SetTooltip("Nativune");
        apply.Invoke(host,
        [
            ReleaseUpdateButtonState.NotChecked,
            null,
            null,
            null,
            false,
            null,
            false
        ]);
    }

    private static void CheckNativeIconSafety()
    {
        var cache = new NativeIconCache();
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
        try
        {
            _ = cache.CreateElement("play", 20);
            throw new SelfCheckException("Disposed native icon cache accepted a new element.");
        }
        catch (ObjectDisposedException) { }
    }

    // Setup, not a test: native checks below need the XAML tree loaded and laid out first.
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

    private static async Task PrepareHostAsync(WebHostWindow host)
    {
        if (host.Content is not FrameworkElement content)
            throw new SelfCheckException("WinUI host did not expose a XAML root.");
        await AwaitLoadedAsync(content);
        content.Measure(new FoundationSize(1200, 800));
        content.Arrange(new FoundationRect(0, 0, 1200, 800));
        content.UpdateLayout();
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
        var fixtureRoot = Path.Combine(root, "data", $".self-check-compact-startup-{Guid.NewGuid():N}");
        Directory.CreateDirectory(fixtureRoot);
        try
        {
            ShellSettings.SaveAsync(fixtureRoot, ShellSettings.Default with { StartCompact = true },
                CancellationToken.None).GetAwaiter().GetResult();
            var completion = new TaskCompletionSource<bool>(
                TaskCreationOptions.RunContinuationsAsynchronously);
            Exception? failure = null;
            Exception? threadFailure = null;
            var thread = new Thread(() =>
            {
                try
                {
                    ShellApplication.Run(() => _ = RunNativeSessionAsync(fixtureRoot, completion));
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
        finally
        {
            Directory.Delete(fixtureRoot, recursive: true);
        }
    }

    private static async Task RunNativeSessionAsync(
        string root, TaskCompletionSource<bool> completion)
    {
        WebHostWindow? host = null;
        Exception? failure = null;
        var phase = "startup";
        try
        {
            phase = "icon-safety";
            CheckNativeIconSafety();
            phase = "tray-routing";
            CheckTrayCallbackRouting();
            phase = "host-create";
            host = new WebHostWindow(root, InitialUri, initializeBrowser: false);
            host.RequestActivation();
            phase = "compact-startup";
            await PrepareHostAsync(host);
            Require(host.IsCompact, "Saved opt-in Compact startup was not applied on the native host.");
            host.SetCompact(false);
            await PrepareHostAsync(host);
            Require(!host.IsCompact, "Compact startup fixture did not return to full mode.");
            phase = "update-feedback";
            CheckUpdateFeedback(host);
            const BindingFlags privateInstance = BindingFlags.Instance | BindingFlags.NonPublic;
            foreach (var field in new[] { "_previousItem", "_playPauseItem", "_nextItem" })
            {
                var item = typeof(WebHostWindow).GetField(field, privateInstance)?.GetValue(host) as MenuFlyoutItem;
                Require(item is not null && !item.IsEnabled,
                    $"Native playback command was enabled without an available player: {field}.");
            }
            var setStatus = typeof(WebHostWindow).GetMethod("SetStatus", privateInstance)!;
            setStatus.Invoke(host, [new string('x', 8192), true]);
            var status = typeof(WebHostWindow).GetField("_statusDetailsText", privateInstance)
                ?.GetValue(host) as string;
            Require(status?.Length == 4096, "Oversized status input was not bounded.");
            var moreButton = FindElement((DependencyObject)host.Content!, "MoreButton");
            Require(moreButton is not null && AutomationProperties.GetName(moreButton)?.Contains(
                    "Application status reports an error", StringComparison.Ordinal) == true,
                "The More control did not expose error state accessibly.");
            typeof(WebHostWindow).GetMethod("OnTimerExpired", privateInstance)!.Invoke(host, null);
            Require(host.NativeHandle != 0 && IsWindow(host.NativeHandle) && host.ExitCode == 0,
                "Pause timer expiry closed or failed the native shell.");


            phase = "pause-dialog";
            await CheckPauseTimerDialogAsync(host, privateInstance);

            phase = "compact-lifecycle";
            var handle = host.NativeHandle;
            host.SetCompact(true);
            await PrepareHostAsync(host);
            Require(host.IsCompact && host.NativeHandle == handle,
                "Compact presenter changed mode or recreated the owned HWND.");
            phase = "compact-checks";
            await CompactViewChecks.RunNativeAsync(host);

            host.SetCompact(false);
            await PrepareHostAsync(host);
            Require(!host.IsCompact && host.NativeHandle == handle,
                "Returning to full mode did not restore the same native presenter.");
            phase = "full-close-to-tray";
            var setTray = host.GetType().GetMethod("SetTrayEnabled", BindingFlags.Instance | BindingFlags.NonPublic)!;
            setTray.Invoke(host, [true]);
            var tray = host.GetType().GetField("_tray", BindingFlags.Instance | BindingFlags.NonPublic)
                ?.GetValue(host) as NativeTrayIcon;
            Require(tray is { IsVisible: true }, "Full-window Close fixture had no available tray icon.");
            _ = SendMessageW(handle, 0x0010, 0, 0);
            Require(!IsWindowVisible(handle) && IsWindow(handle) && host.ExitCode == 0,
                "Full-window Close exited instead of hiding in the tray.");
            host.RequestActivation();
            for (var attempt = 0; attempt < 25 && !IsWindowVisible(handle); attempt++)
                await Task.Delay(20);
            Require(IsWindowVisible(handle) && host.NativeHandle == handle,
                "Tray-hidden full window did not restore on its original HWND.");
            setTray.Invoke(host, [false]);

            phase = "full-close-without-tray";
            _ = SendMessageW(handle, 0x0010, 0, 0);
            await host.ShutdownAsync().WaitAsync(TimeSpan.FromSeconds(5));
            Require(!IsWindow(handle), "Close without a tray icon left the native window open.");
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
            Microsoft.UI.Dispatching.DispatcherQueue.GetForCurrentThread()!.EnqueueEventLoopExit();
        }
    }

    private static async Task CheckPauseTimerDialogAsync(
        WebHostWindow host, BindingFlags privateInstance)
    {
        typeof(WebHostWindow).GetMethod("SetPauseTimer", privateInstance)!.Invoke(host, null);
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
    private static extern nint SendMessageW(nint window, uint message, nint wParam, nint lParam);

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
