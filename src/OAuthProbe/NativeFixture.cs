using System.Diagnostics;
using System.Reflection;
using System.Text;
using System.Text.Json;
using System.Runtime.InteropServices;
using Microsoft.UI;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Windows.Graphics;
using WinRT.Interop;

namespace OAuthProbe;

internal static class NativeFixture
{
    private const string CandidateOutputRelativePath = "artifacts/winui3-candidate/native-interactions.json";

    internal static int Run(string root, bool measureInteractions)
    {
        var validatedRoot = ValidateRoot(root);
        var outputPath = measureInteractions ? GetCandidateOutputPath(validatedRoot) : null;
        if (outputPath is not null && (File.Exists(outputPath) || Directory.Exists(outputPath)))
            throw new UsageException("native-interactions output already exists; pass a fresh --root.");

        Exception? startupFailure = null;
        NativeFixtureWindow? window = null;
        var exitCode = 1;
        var thread = new Thread(() =>
        {
            try
            {
                ShellApplication.Run(() =>
                {
                    window = new NativeFixtureWindow(measureInteractions, outputPath);
                    window.Activate();
                });
                exitCode = window?.ExitCode ?? 1;
            }
            catch (Exception exception)
            {
                startupFailure = exception;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();

        if (startupFailure is not null)
        {
            Console.Error.WriteLine("Native fixture could not start.");
            return 1;
        }

        return exitCode;
    }

    private static string GetCandidateOutputPath(string root)
    {
        var projectRoot = Path.GetFullPath(root);
        var output = Path.GetFullPath(Path.Combine(projectRoot,
            CandidateOutputRelativePath.Replace('/', Path.DirectorySeparatorChar)));
        var prefix = Path.TrimEndingDirectorySeparator(projectRoot) + Path.DirectorySeparatorChar;
        if (!output.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            throw new UsageException("native-interactions output must stay under the project root.");
        return output;
    }
    private static string ValidateRoot(string root)
    {
        var projectRoot = Path.GetFullPath(root);
        var repositoryRoot = FindRepositoryRoot();
        var prefix = Path.TrimEndingDirectorySeparator(repositoryRoot) + Path.DirectorySeparatorChar;
        if (!projectRoot.Equals(repositoryRoot, StringComparison.OrdinalIgnoreCase)
            && !projectRoot.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            throw new UsageException("Native fixture root must stay under the executable-derived project root.");
        return projectRoot;
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "global.json"))
                && File.Exists(Path.Combine(directory.FullName, "agents.md")))
                return directory.FullName;
            directory = directory.Parent;
        }

        throw new UsageException("Could not locate the executable-derived project root.");
    }
}

internal sealed class NativeFixtureWindow : Window
{
    private const int InitialWidthDip = 800;
    private const int InitialHeightDip = 180;
    private const int ResizeWidthDip = 920;
    private const int ResizeHeightDip = 220;
    private const int DefaultDpi = 96;
    private static readonly TimeSpan FixtureLifetime = TimeSpan.FromSeconds(60);
    private static readonly TimeSpan MeasurementWatchdog = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan MenuEndpointTimeout = TimeSpan.FromSeconds(2);
    private const int MeasurementRepeats = 3;
    private const int SamplesPerRepeat = 10;

    private readonly bool _measureInteractions;
    private readonly string? _measurementOutputPath;
    private readonly CompactPlayerView _view;
    private readonly DispatcherQueue _dispatcherQueue;
    private readonly DispatcherQueueTimer _closeTimer;
    private readonly HashSet<SettingsDialog> _ownedSettings = new();
    private readonly MenuFlyout _moreMenu;
    private AppWindow? _appWindow;
    private OverlappedPresenter? _presenter;
    private NativeWindowServices? _nativeWindowServices;
    private nint _nativeHandle;
    private bool _started;
    private bool _measurementStarted;
    private bool _resizeLarge;
    private bool _closing;
    private bool _disposed;
    internal int ExitCode { get; private set; }

    internal NativeFixtureWindow(bool measureInteractions, string? measurementOutputPath)
    {
        _measureInteractions = measureInteractions;
        _measurementOutputPath = measurementOutputPath;
        Title = "Synthetic native WinUI fixture";
        _view = new CompactPlayerView();
        Content = _view;
        _dispatcherQueue = DispatcherQueue.GetForCurrentThread()
            ?? throw new InvalidOperationException("Native fixture requires a dispatcher queue.");
        _closeTimer = _dispatcherQueue.CreateTimer();
        _closeTimer.Interval = FixtureLifetime;
        _closeTimer.IsRepeating = false;
        _closeTimer.Tick += (_, _) => RequestClose();
        _closeTimer.Start();
        _moreMenu = GetMoreMenu(_view);

        _view.SetPlayback(new CompactPlaybackState(
            "Synthetic paused baseline track",
            null,
            Paused: true,
            Position: 10,
            Duration: 120,
            Volume: 0.5,
            Muted: false,
            Liked: false,
            Disliked: false,
            Repeat: "off",
            CanSeek: true,
            CanVolume: true,
            CanLike: true,
            CanDislike: true,
            CanRepeat: true,
            CanShuffle: true));
        _view.SetPreferences(reduceMotion: true, topmost: false);
        _view.SetStatus("Synthetic account-free paused workload", isError: false);
        _view.SetShortcutDescriptions(0, 0, 0, 0);
        _view.CloseRequested += RequestClose;
        _view.MinimizeRequested += Minimize;
        _view.SettingsRequested += OpenSettings;
        _view.ToggleTopmostRequested += ToggleTopmost;
        _view.Loaded += OnLoaded;
        Closed += OnClosed;

        ShellTheme.ApplyToWindow(this);
        TryInitializeNativeWindow();
    }

    private bool TryInitializeNativeWindow()
    {
        if (_appWindow is not null)
            return true;

        try
        {
            _nativeHandle = WindowNative.GetWindowHandle(this);
            if (_nativeHandle == 0)
                return false;

            var windowId = Win32Interop.GetWindowIdFromWindow(_nativeHandle);
            _appWindow = AppWindow.GetFromWindowId(windowId);
            if (_appWindow is null)
                return false;
            _presenter = _appWindow.Presenter as OverlappedPresenter;
            if (_presenter is null)
            {
                _presenter = OverlappedPresenter.Create();
                _appWindow.SetPresenter(_presenter);
            }

            _presenter.IsResizable = true;
            _presenter.IsMinimizable = true;
            _presenter.IsMaximizable = false;
            _nativeWindowServices = new NativeWindowServices(_nativeHandle, HandleNativeMessage);
            _nativeWindowServices.SetCaptionlessResizeFrame(true);
            _presenter.SetBorderAndTitleBar(false, false);
            ResizeSurface(InitialWidthDip, InitialHeightDip);

            var display = DisplayArea.GetFromWindowId(windowId, DisplayAreaFallback.Nearest);
            var workArea = display.WorkArea;
            var size = _appWindow.Size;
            _appWindow.Move(new PointInt32(
                workArea.X + Math.Max(0, (workArea.Width - size.Width) / 2),
                workArea.Y + Math.Max(0, (workArea.Height - size.Height) / 2)));
            ShellTheme.ApplyToWindow(this);
            return true;
        }
        catch (Exception exception) when (exception is COMException or InvalidOperationException or ArgumentException)
        {
            try { _nativeWindowServices?.Dispose(); }
            catch (Exception) { }
            _nativeWindowServices = null;
            _nativeHandle = 0;
            _appWindow = null;
            _presenter = null;
            return false;
        }
    }

    private void OnLoaded(object sender, RoutedEventArgs args)
    {
        if (_started)
            return;
        if (!TryInitializeNativeWindow())
        {
            ExitCode = 1;
            RequestClose();
            return;
        }
        _started = true;
        _view.Loaded -= OnLoaded;
        if (_measureInteractions)
            _ = BeginInteractionMeasurementAsync();
    }

    private bool HandleNativeMessage(
        uint message,
        nint wParam,
        nint lParam,
        out nint result)
        => NativeWindowServices.TryHandleCaptionlessResizeFrame(
            _nativeHandle, message, wParam, lParam, out result);

    private void Minimize()
    {
        if (!_closing)
            _presenter?.Minimize();
    }

    private void ToggleTopmost()
    {
        if (_closing || _presenter is null)
            return;
        var topmost = !_presenter.IsAlwaysOnTop;
        _presenter.IsAlwaysOnTop = topmost;
        _view.SetPreferences(reduceMotion: true, topmost);
    }

    private void OpenSettings()
    {
        if (_closing || _disposed || _ownedSettings.Count != 0)
            return;

        var dialog = new SettingsDialog(ShellSettings.Default, _ => null);
        TrackSettings(dialog);
        _ = ShowSettingsAsync(dialog);
    }

    private async Task ShowSettingsAsync(SettingsDialog dialog)
    {
        try
        {
            if (await dialog.ShowAsync(this))
            {
                _view.SetPreferences(dialog.Result.ReduceMotion, _presenter?.IsAlwaysOnTop == true);
                _view.SetShortcutDescriptions(0, 0, 0, 0);
            }
        }
        catch (Exception) when (!_closing && !_disposed)
        {
            _view.SetStatus("Settings could not be opened.", isError: true);
        }
        finally
        {
            try { dialog.Close(); }
            catch (Exception) { }
            UntrackSettings(dialog);
        }
    }

    private void TrackSettings(SettingsDialog dialog)
    {
        _ownedSettings.Add(dialog);
        dialog.Closed += (_, _) => UntrackSettings(dialog);
    }

    private void UntrackSettings(SettingsDialog dialog)
    {
        _ownedSettings.Remove(dialog);
    }

    private async Task BeginInteractionMeasurementAsync()
    {
        if (_measurementStarted)
            return;
        _measurementStarted = true;
        var watchdog = Stopwatch.StartNew();
        try
        {
            ResizeSurface(InitialWidthDip, InitialHeightDip);
            _view.InvalidateArrange();
            var interactions = new[]
            {
                await MeasureInteraction(
                    "settings-shown-layout",
                    "new SettingsDialog + ShowAsync(this), endpoint captured after Loaded and a layout pass before cleanup",
                    MeasureSettingsOpenAsync,
                    watchdog),
                await MeasureInteraction(
                    "resize",
                    "AppWindow.Resize + CompactPlayerView LayoutUpdated, endpoint captured on child LayoutUpdated before handler cleanup",
                    MeasureResizeAsync,
                    watchdog),
                await MeasureInteraction(
                    "more-menu",
                    "CompactPlayerView.ShowMoreMenu(), endpoint requires MenuFlyout.Opened + IsOpen + visible nonempty item bounds before cleanup",
                    MeasureMoreMenuAsync,
                    watchdog)
            };
            WriteMeasurementReport(interactions, fatalFailure: null);
        }
        catch (Exception exception)
        {
            ExitCode = 1;
            WriteMeasurementReport(Array.Empty<InteractionMeasurement>(), exception.GetType().Name);
        }
        finally
        {
            RequestClose();
        }
    }

    private async Task<InteractionMeasurement> MeasureInteraction(
        string name,
        string endpoint,
        Func<Stopwatch, Task<double>> operation,
        Stopwatch watchdog)
    {
        var samples = new List<InteractionSample>(MeasurementRepeats * SamplesPerRepeat);
        for (var repeat = 1; repeat <= MeasurementRepeats; repeat++)
        {
            for (var sample = 1; sample <= SamplesPerRepeat; sample++)
            {
                try
                {
                    EnsureMeasurementBudget(watchdog);
                    samples.Add(new InteractionSample(
                        repeat,
                        sample,
                        await operation(watchdog),
                        null));
                }
                catch (Exception exception)
                {
                    samples.Add(new InteractionSample(
                        repeat,
                        sample,
                        null,
                        exception.GetType().Name));
                }
            }
        }

        return new InteractionMeasurement(name, endpoint, samples);
    }

    private static void EnsureMeasurementBudget(Stopwatch watchdog)
    {
        if (watchdog.Elapsed >= MeasurementWatchdog)
            throw new TimeoutException("measurement-watchdog-exceeded");
    }

    private static async Task AwaitWithinBudget(
        Task endpoint,
        Stopwatch watchdog,
        TimeSpan? endpointTimeout = null)
    {
        var remaining = MeasurementWatchdog - watchdog.Elapsed;
        if (remaining <= TimeSpan.Zero)
            throw new TimeoutException("measurement-watchdog-exceeded");
        if (endpointTimeout is { } timeout && timeout < remaining)
            remaining = timeout;
        await endpoint.WaitAsync(remaining);
    }

    private async Task<double> MeasureSettingsOpenAsync(Stopwatch watchdog)
    {
        var stopwatch = Stopwatch.StartNew();
        var dialog = new SettingsDialog(ShellSettings.Default, _ => null);
        TrackSettings(dialog);
        if (dialog.Content is not FrameworkElement root)
            throw new InvalidOperationException("settings-content-missing");

        var shown = false;
        var layout = false;
        var endpoint = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        void ObserveEndpoint()
        {
            if (shown && layout)
                endpoint.TrySetResult(true);
        }

        RoutedEventHandler loadedHandler = (_, _) =>
        {
            shown = true;
            ObserveEndpoint();
        };
        EventHandler<object> layoutHandler = (_, _) =>
        {
            if (shown)
                layout = true;
            ObserveEndpoint();
        };
        root.Loaded += loadedHandler;
        root.LayoutUpdated += layoutHandler;
        Task<bool>? showTask = null;
        try
        {
            showTask = dialog.ShowAsync(this);
            await AwaitWithinBudget(endpoint.Task, watchdog);
            if (!shown || !layout)
                throw new InvalidOperationException("settings-shown-layout-endpoint-not-reached");
            return stopwatch.Elapsed.TotalMilliseconds;
        }
        finally
        {
            root.Loaded -= loadedHandler;
            root.LayoutUpdated -= layoutHandler;
            try { dialog.Close(); }
            catch (Exception) { }
            if (showTask is not null)
            {
                try { await showTask.WaitAsync(TimeSpan.FromSeconds(2)); }
                catch (Exception) { }
            }
            if (showTask is null || showTask.IsCompleted)
                UntrackSettings(dialog);
        }
    }

    private async Task<double> MeasureResizeAsync(Stopwatch watchdog)
    {
        var targetWidth = _resizeLarge ? InitialWidthDip : ResizeWidthDip;
        var targetHeight = _resizeLarge ? InitialHeightDip : ResizeHeightDip;
        _resizeLarge = !_resizeLarge;
        var endpoint = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var stopwatch = Stopwatch.StartNew();
        EventHandler<object> layoutHandler = (_, _) =>
        {
            if (HasExpectedSurfaceSize(targetWidth, targetHeight))
                endpoint.TrySetResult(true);
        };
        _view.LayoutUpdated += layoutHandler;
        try
        {
            ResizeSurface(targetWidth, targetHeight);
            _view.InvalidateArrange();
            if (HasExpectedSurfaceSize(targetWidth, targetHeight))
                endpoint.TrySetResult(true);
            await AwaitWithinBudget(endpoint.Task, watchdog);
            if (!HasExpectedSurfaceSize(targetWidth, targetHeight))
                throw new InvalidOperationException("resize-layout-endpoint-not-reached");
            return stopwatch.Elapsed.TotalMilliseconds;
        }
        finally
        {
            _view.LayoutUpdated -= layoutHandler;
        }
    }

    private async Task<double> MeasureMoreMenuAsync(Stopwatch watchdog)
    {
        if (_closing || _disposed || _view.Visibility != Visibility.Visible)
            throw new InvalidOperationException("more-menu-host-not-visible");

        var menuItems = _moreMenu.Items.OfType<FrameworkElement>().ToArray();
        if (menuItems.Length == 0)
            throw new InvalidOperationException("more-menu-items-missing");

        var stopwatch = Stopwatch.StartNew();
        var opened = false;
        var endpoint = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        var closedEndpoint = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        void ObserveEndpoint()
        {
            if (opened && _moreMenu.IsOpen && _view.Visibility == Visibility.Visible
                && menuItems.Any(item => item.Visibility == Visibility.Visible
                    && item.ActualWidth > 0 && item.ActualHeight > 0))
                endpoint.TrySetResult(true);
        }

        EventHandler<object> openedHandler = (_, _) =>
        {
            opened = true;
            ObserveEndpoint();
        };
        EventHandler<object> layoutHandler = (_, _) => ObserveEndpoint();
        EventHandler<object> closedHandler = (_, _) => closedEndpoint.TrySetResult(true);
        _moreMenu.Opened += openedHandler;
        _moreMenu.Closed += closedHandler;
        foreach (var item in menuItems)
            item.LayoutUpdated += layoutHandler;
        try
        {
            _view.ShowMoreMenu();
            await AwaitWithinBudget(endpoint.Task, watchdog, MenuEndpointTimeout);
            if (!opened)
                throw new TimeoutException("more-menu-opened-timeout");
            if (!_moreMenu.IsOpen || !menuItems.Any(item => item.Visibility == Visibility.Visible
                && item.ActualWidth > 0 && item.ActualHeight > 0))
                throw new InvalidOperationException("more-menu-visible-bounds-endpoint-not-reached");
            return stopwatch.Elapsed.TotalMilliseconds;
        }
        finally
        {
            var wasOpen = opened || _moreMenu.IsOpen;
            _moreMenu.Opened -= openedHandler;
            foreach (var item in menuItems)
                item.LayoutUpdated -= layoutHandler;
            try
            {
                _moreMenu.Hide();
                _view.SetActive(false);
                _view.SetActive(true);
                if (wasOpen)
                    await closedEndpoint.Task.WaitAsync(MenuEndpointTimeout);
            }
            finally
            {
                _moreMenu.Closed -= closedHandler;
            }
        }
    }

    private bool HasExpectedSurfaceSize(int widthDip, int heightDip)
        => Math.Abs(_view.ActualWidth - widthDip) <= 0.5
            && Math.Abs(_view.ActualHeight - heightDip) <= 0.5;

    private void ResizeSurface(int widthDip, int heightDip)
    {
        if (_appWindow is null)
            throw new InvalidOperationException("native-fixture-app-window-missing");
        _appWindow.Resize(new SizeInt32(ToPixels(widthDip), ToPixels(heightDip)));
    }

    private int ToPixels(int dip)
    {
        var dpi = _nativeHandle == 0 ? DefaultDpi : (int)GetDpiForWindow(_nativeHandle);
        return Math.Max(1, (int)Math.Round(dip * dpi / (double)DefaultDpi, MidpointRounding.AwayFromZero));
    }

    private void RequestClose()
    {
        if (_closing)
            return;
        _closing = true;
        _closeTimer.Stop();
        foreach (var dialog in _ownedSettings.ToArray())
        {
            try { dialog.Close(); }
            catch (Exception) { }
        }
        try { Close(); }
        catch (Exception) { ExitCode = 1; }
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        if (_disposed)
            return;
        _disposed = true;
        _closeTimer.Stop();
        try { _nativeWindowServices?.Dispose(); }
        catch (Exception) { ExitCode = 1; }
        _nativeWindowServices = null;
        foreach (var dialog in _ownedSettings.ToArray())
        {
            try { dialog.Close(); }
            catch (Exception) { }
        }
        _ownedSettings.Clear();
        _view.CloseRequested -= RequestClose;
        _view.MinimizeRequested -= Minimize;
        _view.SettingsRequested -= OpenSettings;
        _view.ToggleTopmostRequested -= ToggleTopmost;
        _view.Loaded -= OnLoaded;
        _view.Dispose();
    }

    private static MenuFlyout GetMoreMenu(CompactPlayerView view)
    {
        const BindingFlags flags = BindingFlags.Instance | BindingFlags.NonPublic;
        var field = typeof(CompactPlayerView).GetField("_moreMenu", flags);
        return field?.GetValue(view) as MenuFlyout
            ?? throw new InvalidOperationException("native-fixture-more-menu-seam-missing");
    }

    private void WriteMeasurementReport(
        IReadOnlyList<InteractionMeasurement> interactions,
        string? fatalFailure)
    {
        var failures = interactions
            .SelectMany(interaction => interaction.Samples)
            .Where(sample => sample.Failure is not null)
            .ToArray();
        var output = new
        {
            schemaVersion = 1,
            ok = fatalFailure is null && failures.Length == 0,
            mode = "winui3-candidate-native-interactions",
            fixture = "src/OAuthProbe/NativeFixture.cs",
            preservedSource = "src/OAuthProbe/CompactPlayerView.cs;src/OAuthProbe/SettingsDialog.cs;src/OAuthProbe/ShellTheme.cs;src/OAuthProbe/ShellSettings.cs;src/OAuthProbe/ShortcutBindings.cs;src/OAuthProbe/NativeIconCache.cs",
            repeats = MeasurementRepeats,
            samplesPerRepeat = SamplesPerRepeat,
            protocol = new
            {
                totalWatchdogSeconds = MeasurementWatchdog.TotalSeconds,
                menuEndpointTimeoutSeconds = MenuEndpointTimeout.TotalSeconds,
                menuOpenedEventRequired = true,
                menuVisibleRequired = true,
                menuBoundsMinimum = new { width = 1, height = 1 }
            },
            totalRequestedSamples = interactions.Count * MeasurementRepeats * SamplesPerRepeat,
            totalCompletedSamples = interactions.Sum(interaction => interaction.Samples.Count(sample => sample.Failure is null)),
            totalFailures = failures.Length + (fatalFailure is null ? 0 : 1),
            fatalFailure,
            notMeasured = new[]
            {
                "full-shell full/Compact transition; this fixture represents only the preserved native Compact surface",
                "WinUI SettingsDialog uses Loaded/LayoutUpdated rather than WinForms Shown/PerformLayout",
                "WinUI MoreMenu uses MenuFlyout Opened/IsOpen and visible item ActualWidth/ActualHeight rather than ContextMenuStrip.Bounds"
            },
            interactions = interactions.Select(interaction => new
            {
                interaction.Name,
                interaction.Endpoint,
                attempted = interaction.Samples.Count,
                completed = interaction.Samples.Count(sample => sample.Failure is null),
                failures = interaction.Samples
                    .Where(sample => sample.Failure is not null)
                    .Select(sample => new { sample.Repeat, sample.Sample, error = sample.Failure })
                    .ToArray(),
                samples = interaction.Samples
            }).ToArray()
        };

        try
        {
            var outputPath = _measurementOutputPath
                ?? throw new InvalidOperationException("measurement-output-path-missing");
            var directory = Path.GetDirectoryName(outputPath)
                ?? throw new InvalidOperationException("measurement-output-directory-missing");
            Directory.CreateDirectory(directory);
            var json = JsonSerializer.Serialize(output, new JsonSerializerOptions
            {
                WriteIndented = true,
                PropertyNamingPolicy = JsonNamingPolicy.CamelCase
            });
            WriteAtomically(outputPath, json);
            if (!output.ok)
                ExitCode = 1;
        }
        catch (Exception exception)
        {
            ExitCode = 1;
            Console.Error.WriteLine($"Interaction measurement output failed: {exception.GetType().Name}.");
        }
    }

    private static void WriteAtomically(string outputPath, string json)
    {
        var temporary = outputPath + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            var bytes = new UTF8Encoding(encoderShouldEmitUTF8Identifier: false).GetBytes(json);
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                4096, FileOptions.SequentialScan))
            {
                stream.Write(bytes, 0, bytes.Length);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, outputPath);
        }
        finally
        {
            try { File.Delete(temporary); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
    private static extern uint GetDpiForWindow(nint window);
}

internal sealed record InteractionSample(
    int Repeat,
    int Sample,
    double? DurationMs,
    string? Failure);

internal sealed record InteractionMeasurement(
    string Name,
    string Endpoint,
    IReadOnlyList<InteractionSample> Samples);
