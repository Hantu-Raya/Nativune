using System.Runtime.InteropServices.WindowsRuntime;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Automation;
using Windows.Graphics;
using Microsoft.Web.WebView2.Core;
using WinRT.Interop;
using Microsoft.UI;

namespace Nativune;

internal static class OutputAudioFixture
{
    private const string ProfileDirectoryName = "output-audio-fixture";
    private const string RuntimeManifestRelativePath = ".tools/webview2/runtime-path.txt";
    private const int CleanupAttemptCount = 5;
    private static readonly TimeSpan CleanupRetryDelay = TimeSpan.FromMilliseconds(200);

    internal static int Run(string root)
    {
        var projectRoot = ValidateProjectRoot(root);
        var runtimeDirectory = ResolveRuntimeDirectory(projectRoot);
        var browserExecutable = Path.Combine(runtimeDirectory, "msedgewebview2.exe");
        var temporaryDirectory = PrepareProcessTempDirectory(projectRoot);
        var previousTemp = Environment.GetEnvironmentVariable("TEMP");
        var previousTmp = Environment.GetEnvironmentVariable("TMP");
        var exitCode = 1;
        var temporaryDataMayBeRemoved = true;
        try
        {
            Environment.SetEnvironmentVariable("TEMP", temporaryDirectory);
            Environment.SetEnvironmentVariable("TMP", temporaryDirectory);
            var result = RunFixture(projectRoot, runtimeDirectory, browserExecutable);
            exitCode = result.ExitCode;
            temporaryDataMayBeRemoved = result.TemporaryDataMayBeRemoved;
        }
        catch (Exception exception) when (exception is ArgumentException or UnauthorizedAccessException or InvalidOperationException)
        {
            throw new UsageException("Output audio fixture could not use its repository-local process temporary directory.");
        }
        finally
        {
            try
            {
                Environment.SetEnvironmentVariable("TEMP", previousTemp);
                Environment.SetEnvironmentVariable("TMP", previousTmp);
            }
            finally
            {
                if (!RemoveTemporaryDirectory(projectRoot, temporaryDirectory, temporaryDataMayBeRemoved))
                    exitCode = 1;
            }
        }

        return exitCode;
    }

    private static (int ExitCode, bool TemporaryDataMayBeRemoved) RunFixture(
        string projectRoot, string runtimeDirectory, string browserExecutable)
    {
        var profilePath = CreateProfileDirectory(projectRoot);
        OutputAudioFixtureWindow? window = null;
        Exception? startupFailure = null;
        var exitCode = 1;
        var profileMayBeRemoved = true;
        var thread = new Thread(() =>
        {
            try
            {
                ShellApplication.Run(() =>
                {
                    window = new OutputAudioFixtureWindow(runtimeDirectory, browserExecutable, profilePath);
                    window.Activate();
                });
                exitCode = window?.ExitCode ?? 1;
                profileMayBeRemoved = window?.ProfileMayBeRemoved ?? true;
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
            profileMayBeRemoved = window is null;
            Console.Error.WriteLine("Output audio fixture failed: the local WinUI/WebView2 window could not start.");
            exitCode = 1;
        }

        if (!RemoveTemporaryProfile(projectRoot, profilePath, profileMayBeRemoved))
            exitCode = 1;

        return (exitCode, profileMayBeRemoved);
    }

    private static string PrepareProcessTempDirectory(string root)
    {
        var parent = Path.Combine(root, ".cache", "tmp");
        try
        {
            RootLocator.EnsureNoReparsePath(root, parent);
            Directory.CreateDirectory(parent);
            RootLocator.EnsureNoReparsePath(root, parent);
            for (var attempt = 0; attempt < 5; attempt++)
            {
                var temporaryDirectory = Path.Combine(parent, "output-audio-fixture-" + Guid.NewGuid().ToString("N"));
                if (Path.Exists(temporaryDirectory))
                    continue;
                Directory.CreateDirectory(temporaryDirectory);
                RootLocator.EnsureNoReparseTree(root, temporaryDirectory);
                if (Directory.EnumerateFileSystemEntries(temporaryDirectory).Any())
                    throw new UsageException("Output audio fixture refused a process temporary directory that was not freshly empty.");
                return temporaryDirectory;
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException)
        {
            throw new UsageException("Output audio fixture requires a safe writable repository-local .cache/tmp directory.");
        }

        throw new UsageException("Output audio fixture could not allocate a fresh repository-local process temporary directory.");
    }

    private static bool RemoveTemporaryDirectory(string root, string temporaryDirectory, bool mayBeRemoved)
    {
        if (!mayBeRemoved)
        {
            Console.Error.WriteLine("Output audio fixture cleanup incomplete: WebView2 may still be using its unique process temporary directory; it was left untouched.");
            return false;
        }

        return RemoveOwnedDirectory(root, temporaryDirectory, "process temporary directory");
    }

    private static bool RemoveOwnedDirectory(string root, string directory, string description)
    {
        for (var attempt = 0; attempt < CleanupAttemptCount; attempt++)
        {
            try
            {
                if (!Directory.Exists(directory))
                    return true;
                RootLocator.EnsureNoReparseTree(root, directory);
                Directory.Delete(directory, recursive: true);
                return true;
            }
            catch (InvalidOperationException)
            {
                Console.Error.WriteLine($"Output audio fixture cleanup refused for its unique {description}: path-safety validation failed; it was left untouched.");
                return false;
            }
            catch (IOException) when (attempt + 1 < CleanupAttemptCount)
            {
                Thread.Sleep(CleanupRetryDelay);
            }
            catch (UnauthorizedAccessException) when (attempt + 1 < CleanupAttemptCount)
            {
                Thread.Sleep(CleanupRetryDelay);
            }
            catch (IOException)
            {
                Console.Error.WriteLine($"Output audio fixture cleanup failed after {CleanupAttemptCount} bounded retries: I/O error removing its unique {description}.");
                return false;
            }
            catch (UnauthorizedAccessException)
            {
                Console.Error.WriteLine($"Output audio fixture cleanup failed after {CleanupAttemptCount} bounded retries: access denied removing its unique {description}.");
                return false;
            }
        }

        return false;
    }

    private static string ValidateProjectRoot(string root)
    {
        string projectRoot;
        try
        {
            projectRoot = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
            RootLocator.EnsureNoReparsePath(projectRoot, projectRoot);
        }
        catch (Exception exception) when (exception is ArgumentException or IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            throw new UsageException("Output audio fixture requires a safe repository-local project root.");
        }

        var repositoryRoot = FindRepositoryRoot();
        if (!projectRoot.Equals(repositoryRoot, StringComparison.OrdinalIgnoreCase))
            throw new UsageException("Output audio fixture only runs against the repository root containing this executable.");

        if (!File.Exists(Path.Combine(projectRoot, "agents.md"))
            || !File.Exists(Path.Combine(projectRoot, "global.json")))
            throw new UsageException("Output audio fixture requires the repository-local agents.md and global.json markers.");

        return projectRoot;
    }

    private static string FindRepositoryRoot()
    {
        var directory = new DirectoryInfo(AppContext.BaseDirectory);
        while (directory is not null)
        {
            if (File.Exists(Path.Combine(directory.FullName, "global.json"))
                && File.Exists(Path.Combine(directory.FullName, "agents.md")))
                return Path.TrimEndingDirectorySeparator(Path.GetFullPath(directory.FullName));
            directory = directory.Parent;
        }

        throw new UsageException("Output audio fixture requires an executable located under this repository.");
    }

    private static string ResolveRuntimeDirectory(string root)
    {
        var manifest = Path.Combine(root, RuntimeManifestRelativePath.Replace('/', Path.DirectorySeparatorChar));
        try
        {
            RootLocator.EnsureRegularFile(root, manifest);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            throw new UsageException("Output audio fixture prerequisite missing: the project-local pinned WebView2 runtime-path.txt file.");
        }

        string relativeDirectory;
        try
        {
            relativeDirectory = File.ReadAllText(manifest).Trim();
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            throw new UsageException("Output audio fixture prerequisite unavailable: the pinned WebView2 runtime manifest could not be read.");
        }

        if (relativeDirectory.Length == 0 || relativeDirectory is "." or ".."
            || relativeDirectory != Path.GetFileName(relativeDirectory)
            || relativeDirectory.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
            throw new UsageException("Output audio fixture prerequisite invalid: runtime-path.txt must name one local runtime directory.");

        var runtimeRoot = Path.GetFullPath(Path.Combine(root, ".tools", "webview2"));
        var runtimeDirectory = Path.GetFullPath(Path.Combine(runtimeRoot, relativeDirectory));
        var runtimePrefix = runtimeRoot + Path.DirectorySeparatorChar;
        if (!runtimeDirectory.StartsWith(runtimePrefix, StringComparison.OrdinalIgnoreCase))
            throw new UsageException("Output audio fixture refused a pinned WebView2 runtime path outside .tools/webview2.");

        try
        {
            RootLocator.EnsureNoReparseTree(root, runtimeDirectory);
            RootLocator.EnsureRegularFile(root, Path.Combine(runtimeDirectory, "msedgewebview2.exe"));
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException)
        {
            throw new UsageException("Output audio fixture prerequisite unavailable: the pinned local WebView2 runtime is missing or unsafe.");
        }

        return runtimeDirectory;
    }

    private static string CreateProfileDirectory(string root)
    {
        var parent = Path.Combine(root, "data", ProfileDirectoryName);
        try
        {
            RootLocator.EnsureNoReparsePath(root, parent);
            Directory.CreateDirectory(parent);
            RootLocator.EnsureNoReparsePath(root, parent);

            for (var attempt = 0; attempt < 5; attempt++)
            {
                var profile = Path.Combine(parent, "profile-" + Guid.NewGuid().ToString("N"));
                if (Path.Exists(profile))
                    continue;

                Directory.CreateDirectory(profile);
                RootLocator.EnsureNoReparseTree(root, profile);
                if (Directory.EnumerateFileSystemEntries(profile).Any())
                    throw new UsageException("Output audio fixture refused a profile directory that was not freshly empty.");
                return profile;
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or InvalidOperationException or ArgumentException)
        {
            throw new UsageException("Output audio fixture prerequisite unavailable: a safe fresh profile could not be created under repository-local data/.");
        }

        throw new UsageException("Output audio fixture could not allocate a fresh isolated profile directory.");
    }

    private static bool RemoveTemporaryProfile(string root, string profile, bool mayBeRemoved)
    {
        if (!mayBeRemoved)
        {
            Console.Error.WriteLine("Output audio fixture cleanup incomplete: WebView2 may still be using its unique temporary profile; it was left untouched.");
            return false;
        }

        var removed = RemoveOwnedDirectory(root, profile, "temporary profile");
        if (removed)
            Console.WriteLine("Output audio fixture: isolated temporary profile removed.");
        return removed;
    }
}

internal sealed class OutputAudioFixtureWindow : Window
{
    private const string FixtureTitle = "Nativune Output Audio Fixture";
    private static readonly TimeSpan RuntimeInitializationTimeout = TimeSpan.FromSeconds(30);
    private static readonly TimeSpan NavigationTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan SessionDiscoveryTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan ProcessExitTimeout = TimeSpan.FromSeconds(8);
    private static readonly TimeSpan FixtureLifetime = TimeSpan.FromMinutes(3);
    private static readonly TimeSpan VolumeSettleTime = TimeSpan.FromMilliseconds(500);
    private const double ScalarTolerance = 0.001;

    private readonly string _runtimeDirectory;
    private readonly string _browserExecutable;
    private readonly string _profileDirectory;
    private readonly CancellationTokenSource _lifetime = new();
    private readonly SemaphoreSlim _audioGate = new(1, 1);
    private readonly DispatcherQueue _dispatcher;
    private readonly DispatcherQueueTimer _closeTimer;
    private readonly Border _webViewSlot;
    private readonly TextBlock _status;
    private readonly nint _windowHandle;
    private readonly AppWindow _appWindow;
    private CoreWebView2Environment? _environment;
    private NativeBrowserHost? _browserHost;
    private WebViewAudioVolume? _audioVolume;
    private Task<CoreWebView2Environment>? _environmentCreationTask;
    private Task? _lateControllerCleanup;
    private Task? _initializationTask;
    private Task? _verificationTask;
    private CancellationTokenSource? _verificationCancellation;
    private bool _processEnumerationFailed;
    private long _generation = 1;
    private bool _loaded;
    private bool _toneActive;
    private bool _fixtureStoppingTone;
    private bool _closing;
    private bool _allowClose;
    private bool _shutdownStarted;
    private bool _disposed;
    private bool _volumeTouched;
    private bool _profileMayBeRemoved = true;

    internal int ExitCode { get; private set; } = 1;
    internal bool ProfileMayBeRemoved => _profileMayBeRemoved;

    internal OutputAudioFixtureWindow(string runtimeDirectory, string browserExecutable, string profileDirectory)
    {
        _runtimeDirectory = runtimeDirectory;
        _browserExecutable = browserExecutable;
        _profileDirectory = profileDirectory;
        _dispatcher = DispatcherQueue.GetForCurrentThread()
            ?? throw new InvalidOperationException("Output audio fixture requires a WinUI dispatcher.");

        Title = FixtureTitle;
        var layout = new Grid
        {
            Padding = new Thickness(12),
            RowSpacing = 8,
            Background = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Transparent)
        };
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });
        layout.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        layout.RowDefinitions.Add(new RowDefinition { Height = GridLength.Auto });

        var instructions = new TextBlock
        {
            Text = "Account-free local test. The embedded page plays a quiet 440 Hz tone only after you press Start. No Music site, account, credentials, or network content is used.",
            TextWrapping = TextWrapping.Wrap,
            Margin = new Thickness(0, 0, 0, 4)
        };
        Grid.SetRow(instructions, 0);
        layout.Children.Add(instructions);

        _webViewSlot = new Border
        {
            MinHeight = 180,
            BorderThickness = new Thickness(1),
            BorderBrush = new Microsoft.UI.Xaml.Media.SolidColorBrush(Microsoft.UI.Colors.Gray),
            HorizontalAlignment = HorizontalAlignment.Stretch,
            VerticalAlignment = VerticalAlignment.Stretch
        };
        Grid.SetRow(_webViewSlot, 1);
        layout.Children.Add(_webViewSlot);

        _status = new TextBlock
        {
            Text = "Starting the pinned project-local WebView2 runtime…",
            TextWrapping = TextWrapping.Wrap
        };
        AutomationProperties.SetName(_status, "Output audio fixture status");
        Grid.SetRow(_status, 2);
        layout.Children.Add(_status);
        Content = layout;

        _windowHandle = WindowNative.GetWindowHandle(this);
        if (_windowHandle == 0)
            throw new InvalidOperationException("Output audio fixture requires a native window handle.");
        _appWindow = AppWindow.GetFromWindowId(Win32Interop.GetWindowIdFromWindow(_windowHandle))
            ?? throw new InvalidOperationException("Output audio fixture could not acquire its native window.");
        _appWindow.Closing += OnAppWindowClosing;

        _closeTimer = _dispatcher.CreateTimer();
        _closeTimer.Interval = FixtureLifetime;
        _closeTimer.IsRepeating = false;
        _closeTimer.Tick += (_, _) => RequestClose();
        _closeTimer.Start();

        layout.Loaded += OnLoaded;
        Closed += OnClosed;
        _appWindow.Resize(new SizeInt32(760, 430));
    }

    private void OnLoaded(object sender, RoutedEventArgs args)
    {
        if (_loaded)
            return;
        _loaded = true;
        _initializationTask = InitializeAsync();
    }

    private async Task InitializeAsync()
    {
        try
        {
            SetStatus("Creating a fresh isolated profile and pinned local WebView2 environment…");
            var options = new CoreWebView2EnvironmentOptions
            {
                AreBrowserExtensionsEnabled = false
            };
            _environmentCreationTask = CoreWebView2Environment.CreateWithOptionsAsync(
                    _runtimeDirectory, _profileDirectory, options)
                .AsTask();
            var environment = await _environmentCreationTask
                .WaitAsync(RuntimeInitializationTimeout, _lifetime.Token);
            _environment = environment;

            var host = await NativeBrowserHost.CreateAsync(
                environment,
                _windowHandle,
                _webViewSlot,
                _lifetime.Token,
                task => _lateControllerCleanup = task);
            _browserHost = host;
            var core = host.Core;
            core.Settings.AreHostObjectsAllowed = false;
            core.Settings.IsWebMessageEnabled = false;
            core.Settings.AreDefaultContextMenusEnabled = false;
            core.Settings.AreDefaultScriptDialogsEnabled = false;
            core.Settings.IsStatusBarEnabled = false;
            core.NewWindowRequested += (_, eventArgs) => eventArgs.Handled = true;
            core.PermissionRequested += (_, eventArgs) => eventArgs.State = CoreWebView2PermissionState.Deny;
            core.DownloadStarting += (_, eventArgs) => eventArgs.Cancel = true;
            core.LaunchingExternalUriScheme += (_, eventArgs) => eventArgs.Cancel = true;
            core.DocumentTitleChanged += OnDocumentTitleChanged;
            host.SetVisible(true);

            var localPageReady = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
            CoreWebView2WebErrorStatus? lastNavigationError = null;
            void OnLocalDocumentTitleChanged(CoreWebView2 sender, object eventArgs)
            {
                if (sender.DocumentTitle == FixtureTitle)
                    localPageReady.TrySetResult(true);
            }
            void OnNavigationCompletedForDiagnostics(CoreWebView2 sender, CoreWebView2NavigationCompletedEventArgs eventArgs)
            {
                if (!eventArgs.IsSuccess)
                    lastNavigationError = eventArgs.WebErrorStatus;
            }

            // This single NavigateToString call supplies the only initial document. Once its
            // fixed local title is observed, every subsequent top-level navigation is denied.
            core.DocumentTitleChanged += OnLocalDocumentTitleChanged;
            core.NavigationCompleted += OnNavigationCompletedForDiagnostics;
            try
            {
                core.NavigateToString(FixtureHtml);
                await localPageReady.Task.WaitAsync(NavigationTimeout, _lifetime.Token);
            }
            catch (TimeoutException) when (lastNavigationError.HasValue)
            {
                throw new FixtureFailure($"The embedded local page did not become ready; the latest WebView2 navigation error was {lastNavigationError.Value}.");
            }
            finally
            {
                core.DocumentTitleChanged -= OnLocalDocumentTitleChanged;
                core.NavigationCompleted -= OnNavigationCompletedForDiagnostics;
            }

            core.NavigationStarting += OnNavigationStarting;
            _audioVolume = new WebViewAudioVolume(_browserExecutable);
            SetStatus("Ready. Click Start test tone in the embedded page to run the 100% → 25% → 0% → 100% session-scalar check.");
            Report("Ready; waiting for the explicit Start test tone gesture.");
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested)
        {
            _profileMayBeRemoved = _environmentCreationTask?.IsCompleted != false
                && _lateControllerCleanup?.IsCompleted != false;
        }
        catch (TimeoutException)
        {
            _profileMayBeRemoved = _environmentCreationTask?.IsCompleted != false
                && _lateControllerCleanup?.IsCompleted != false;
            Fail("Pinned WebView2 initialization or local page navigation timed out.");
            ScheduleClose();
        }
        catch (FixtureFailure exception)
        {
            Fail(exception.Message);
            ScheduleClose();
        }
        catch (Exception)
        {
            _profileMayBeRemoved = _environmentCreationTask?.IsCompleted != false
                && _lateControllerCleanup?.IsCompleted != false;
            Fail("Pinned WebView2 initialization failed; verify the project-local runtime and data-folder access.");
            ScheduleClose();
        }
    }

    private void OnNavigationStarting(CoreWebView2 sender, CoreWebView2NavigationStartingEventArgs args)
    {
        args.Cancel = true;
        var category = Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri)
            ? uri.Scheme.ToLowerInvariant() switch
            {
                "about" => "about",
                "data" => "data",
                "file" => "file",
                "http" => "http",
                "https" => "https",
                _ => "other"
            }
            : "invalid";
        SetStatus($"Blocked unexpected {category} navigation after loading the local test page.");
        Report($"Blocked navigation category: {category}.");
    }

    private void OnDocumentTitleChanged(CoreWebView2 sender, object args)
    {
        switch (sender.DocumentTitle)
        {
            case "Nativune Output Audio Fixture: tone-started":
                if (_closing || _toneActive)
                    return;
                _toneActive = true;
                SetStatus("Web Audio tone is running. Checking only this isolated WebView2 environment’s output session…");
                _verificationCancellation = CancellationTokenSource.CreateLinkedTokenSource(_lifetime.Token);
                var generation = Interlocked.Read(ref _generation);
                _verificationTask = VerifyOutputVolumeAsync(generation, _verificationCancellation.Token);
                break;
            case string stopTitle when stopTitle.StartsWith("Nativune Output Audio Fixture: stop-requested-", StringComparison.Ordinal):
                if (_fixtureStoppingTone)
                    return;
                if (!_toneActive)
                {
                    _toneActive = true;
                    if (_verificationTask is null || _verificationTask.IsCompleted)
                        _volumeTouched = false;
                }
                Interlocked.Increment(ref _generation);
                _verificationCancellation?.Cancel();
                if (_verificationTask is null || _verificationTask.IsCompleted)
                    _verificationTask = HandleUnverifiedStopAsync();
                break;
            case "Nativune Output Audio Fixture: tone-stopped":
                _toneActive = false;
                break;
            case "Nativune Output Audio Fixture: audio-error":
                _toneActive = false;
                _verificationCancellation?.Cancel();
                Fail("The embedded Web Audio test tone could not start; no volume verification was reported.");
                break;
        }
    }

    private async Task VerifyOutputVolumeAsync(long generation, CancellationToken cancellationToken)
    {
        _volumeTouched = false;
        try
        {
            var deadline = DateTime.UtcNow + SessionDiscoveryTimeout;
            AudioState? baseline = null;
            while (DateTime.UtcNow < deadline)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var processIds = CaptureEnvironmentProcessIds();
                if (processIds.Count > 0)
                {
                    baseline = await RunAudioOperationAsync<AudioState?>(() =>
                    {
                        _audioVolume!.Refresh(processIds, () => IsCurrentGeneration(generation));
                        return _audioVolume.Available
                            ? new AudioState(_audioVolume.Volume, _audioVolume.Muted)
                            : null;
                    }, cancellationToken);
                    if (baseline is not null)
                        break;
                }
                await Task.Delay(250, cancellationToken);
            }

            if (baseline is null)
                throw new FixtureFailure("No safe, consistent owned WebView2 output-audio session could be read within 15 seconds; check that an output device is available.");
            if (baseline.Value.Muted)
                throw new FixtureFailure("The owned WebView2 output session is muted; the fixture will not change mute state.");
            if (Math.Abs(baseline.Value.Volume - 1d) > ScalarTolerance)
            {
                var processIds = CaptureEnvironmentProcessIds();
                if (processIds.Count == 0)
                    throw new FixtureFailure("The isolated WebView2 environment no longer reports its owned process IDs.");
                _volumeTouched = true;
                baseline = await RunAudioOperationAsync<AudioState?>(() =>
                {
                    if (!_audioVolume!.TrySetVolume(1d, () => IsCurrentGeneration(generation)))
                        return null;
                    return _audioVolume.Available
                        ? new AudioState(_audioVolume.Volume, _audioVolume.Muted)
                        : null;
                }, cancellationToken);
                if (baseline is null || baseline.Value.Muted)
                    throw new FixtureFailure("The owned WebView2 session could not be set to the required initial 100% scalar.");
            }
            RequireScalar(baseline.Value.Volume, 1d, "initial 100% session scalar");
            ReportReadback(1d);

            foreach (var target in new[] { 0.25d, 0d, 1d })
            {
                cancellationToken.ThrowIfCancellationRequested();
                var processIds = CaptureEnvironmentProcessIds();
                if (processIds.Count == 0)
                    throw new FixtureFailure("The isolated WebView2 environment no longer reports its owned process IDs.");

                _volumeTouched = true;
                var immediate = await RunAudioOperationAsync<AudioState?>(() =>
                {
                    if (!_audioVolume!.Available)
                        _audioVolume.Refresh(processIds, () => IsCurrentGeneration(generation));
                    if (!_audioVolume.Available || _audioVolume.Muted
                        || !_audioVolume.TrySetVolume(target, () => IsCurrentGeneration(generation)))
                        return null;
                    return new AudioState(_audioVolume.Volume, _audioVolume.Muted);
                }, cancellationToken);
                if (immediate is null)
                    throw new FixtureFailure("The owned WebView2 audio session rejected the requested scalar or could not be read back.");
                RequireScalar(immediate.Value.Volume, target, "immediate session-scalar readback");

                await Task.Delay(VolumeSettleTime, cancellationToken);
                var processIdsAfterSettle = CaptureEnvironmentProcessIds();
                if (processIdsAfterSettle.Count == 0)
                    throw new FixtureFailure("The isolated WebView2 environment stopped reporting its owned process IDs during the tone.");
                var settled = await RunAudioOperationAsync<AudioState?>(() =>
                {
                    _audioVolume!.Refresh(processIdsAfterSettle, () => IsCurrentGeneration(generation));
                    return _audioVolume.Available
                        ? new AudioState(_audioVolume.Volume, _audioVolume.Muted)
                        : null;
                }, cancellationToken);
                if (settled is null || settled.Value.Muted)
                    throw new FixtureFailure("The owned WebView2 output session was unavailable for settled readback.");
                RequireScalar(settled.Value.Volume, target, "settled session-scalar readback");
                ReportReadback(target);
            }

            if (!IsCurrentGeneration(generation))
                throw new OperationCanceledException(cancellationToken);

            _fixtureStoppingTone = true;
            await StopToneOnPageAsync();
            _fixtureStoppingTone = false;
            _toneActive = false;
            ExitCode = 0;
            SetStatus("PASS: owned WebView2 session scalar read back 100% → 25% → 0% → 100% while the local tone was running. Tone stopped after the final 100% readback.");
            Report("PASS: owned-session scalar readback 100% → 25% → 0% → 100% while the local Web Audio tone was running; tone stopped.");
        }
        catch (OperationCanceledException)
        {
            var restored = await RestoreOutputAndStopToneAsync();
            ExitCode = 1;
            SetStatus($"Fixture cancelled. {RestorationMessage(restored)} {ToneStopMessage()} No other session or system volume was changed.");
            Report("Fixture cancelled; no pass reported.");
        }
        catch (FixtureFailure exception)
        {
            var restored = await RestoreOutputAndStopToneAsync();
            ExitCode = 1;
            SetStatus($"FAIL: {exception.Message} {RestorationMessage(restored)} {ToneStopMessage()}");
            Report("FAIL: " + exception.Message);
        }
        catch (Exception)
        {
            var restored = await RestoreOutputAndStopToneAsync();
            ExitCode = 1;
            const string failure = "The owned-session scalar verification stopped unexpectedly; no pass was reported.";
            SetStatus($"FAIL: {failure} {RestorationMessage(restored)} {ToneStopMessage()}");
            Report($"FAIL: {failure} {RestorationMessage(restored)} {ToneStopMessage()}");
        }
        finally
        {
            _verificationCancellation?.Dispose();
            _verificationCancellation = null;
        }
    }

    private async Task HandleUnverifiedStopAsync()
    {
        var restored = await RestoreOutputAndStopToneAsync();
        SetStatus($"Tone stop requested. {RestorationMessage(restored)} No scalar test pass was claimed.");
    }

    private async Task<bool> RestoreOutputAndStopToneAsync()
    {
        var restored = !_volumeTouched;
        if (_volumeTouched)
        {
            restored = false;
            if (_toneActive && _audioVolume is not null)
            {
                var restoreGeneration = Interlocked.Increment(ref _generation);
                try
                {
                    var ids = CaptureEnvironmentProcessIds();
                    if (ids.Count > 0)
                    {
                        restored = await RunAudioOperationAsync(() =>
                        {
                            _audioVolume!.Refresh(ids, () => IsCurrentGeneration(restoreGeneration));
                            if (!_audioVolume.Available || _audioVolume.Muted)
                                return false;
                            if (Math.Abs(_audioVolume.Volume - 1d) <= ScalarTolerance)
                                return true;
                            if (!_audioVolume.TrySetVolume(1d, () => IsCurrentGeneration(restoreGeneration)))
                                return false;
                            return _audioVolume.Available && !_audioVolume.Muted
                                && Math.Abs(_audioVolume.Volume - 1d) <= ScalarTolerance;
                        }, CancellationToken.None);
                    }
                }
                catch (Exception)
                {
                    restored = false;
                }
            }
        }

        if (restored)
        {
            try
            {
                await StopToneOnPageAsync();
            }
            catch (Exception)
            {
                restored = false;
                _profileMayBeRemoved = false;
            }
        }
        _fixtureStoppingTone = false;
        return restored;
    }

    private string RestorationMessage(bool restored)
        => !_volumeTouched
            ? "No fixture session-volume write was made."
            : restored
                ? "The owned WebView2 output scalar is confirmed at 100%."
                : "The owned WebView2 output scalar could not be restored and read back at 100%.";

    private string ToneStopMessage()
        => _toneActive ? "The local tone stop could not be confirmed." : "The local tone is stopped.";

    private async Task<T> RunAudioOperationAsync<T>(Func<T> operation, CancellationToken cancellationToken)
    {
        await _audioGate.WaitAsync(cancellationToken);
        try
        {
            var task = Task.Run(operation);
            return await task;
        }
        finally
        {
            _audioGate.Release();
        }
    }


    private bool IsCurrentGeneration(long generation)
        => !_disposed && Interlocked.Read(ref _generation) == generation && Volatile.Read(ref _toneActive);

    private HashSet<int> CaptureEnvironmentProcessIds()
    {
        if (_environment is null)
        {
            _processEnumerationFailed = false;
            return [];
        }

        try
        {
            var processInfos = _environment.GetProcessInfos();
            _processEnumerationFailed = false;
            return processInfos?
                .Select(static info => info.ProcessId)
                .Where(static id => id > 0)
                .ToHashSet() ?? [];
        }
        catch (Exception)
        {
            _processEnumerationFailed = true;
            return [];
        }
    }

    private async Task StopToneOnPageAsync()
    {
        if (!_toneActive)
            return;
        var host = _browserHost ?? throw new FixtureFailure("The WebView2 host is unavailable while the test tone is active.");
        _fixtureStoppingTone = true;
        var result = await host.Core.ExecuteScriptAsync("window.finishFixtureTone ? window.finishFixtureTone() : true")
            .AsTask().WaitAsync(TimeSpan.FromSeconds(2));
        if (!string.Equals(result.Trim(), "true", StringComparison.Ordinal))
            throw new FixtureFailure("The local Web Audio tone did not acknowledge its stop request.");
        _toneActive = false;
        _fixtureStoppingTone = false;
    }

    private async Task ShutdownAsync()
    {
        if (_shutdownStarted)
            return;
        _shutdownStarted = true;
        _closing = true;
        Interlocked.Increment(ref _generation);
        _lifetime.Cancel();
        _verificationCancellation?.Cancel();

        try
        {
            if (_verificationTask is not null)
                await _verificationTask.WaitAsync(TimeSpan.FromSeconds(20));
            if (_initializationTask is not null)
                await _initializationTask.WaitAsync(TimeSpan.FromSeconds(35));
            if (_environmentCreationTask is not null)
                _environment ??= await _environmentCreationTask.WaitAsync(TimeSpan.FromSeconds(10));
            if (_lateControllerCleanup is not null)
                await _lateControllerCleanup.WaitAsync(TimeSpan.FromSeconds(10));
        }
        catch (TimeoutException)
        {
            _shutdownStarted = false;
            ExitCode = 1;
            _profileMayBeRemoved = false;
            SetStatus("Close paused: WebView2 or audio cleanup did not finish within its timeout. The temporary profile will be left untouched for safety; retry Close after the operation ends.");
            return;
        }
        catch (Exception)
        {
            ExitCode = 1;
            _profileMayBeRemoved = false;
            SetStatus("WebView2 cleanup failed; the temporary profile will be left untouched for safety.");
        }

        if (_toneActive)
        {
            var restored = await RestoreOutputAndStopToneAsync();
            if (!restored || _toneActive)
            {
                _shutdownStarted = false;
                _closing = false;
                ExitCode = 1;
                _profileMayBeRemoved = false;
                SetStatus($"Close paused. {RestorationMessage(restored)} {ToneStopMessage()} The tone remains active; retry Stop or Close after resolving the owned session.");
                return;
            }
        }
        _closeTimer.Stop();
        try { _browserHost?.Dispose(); }
        catch (Exception)
        {
            ExitCode = 1;
            _profileMayBeRemoved = false;
        }
        _browserHost = null;

        var deadline = DateTime.UtcNow + ProcessExitTimeout;
        while (DateTime.UtcNow < deadline)
        {
            var processIds = CaptureEnvironmentProcessIds();
            if (!_processEnumerationFailed && processIds.Count == 0)
                break;
            await Task.Delay(200);
        }
        var remainingProcessIds = CaptureEnvironmentProcessIds();
        if (_processEnumerationFailed || remainingProcessIds.Count != 0)
        {
            _profileMayBeRemoved = false;
            ExitCode = 1;
            Report("Cleanup incomplete: owned WebView2 process exit could not be confirmed; the temporary profile was left untouched.");
        }
        else
        {
            _profileMayBeRemoved =
                (_environmentCreationTask is null || _environmentCreationTask.IsCompletedSuccessfully)
                && (_lateControllerCleanup is null || _lateControllerCleanup.IsCompletedSuccessfully);
            if (!_profileMayBeRemoved)
            {
                ExitCode = 1;
                Report("Cleanup incomplete: WebView2 initialization or controller cleanup did not complete successfully; its temporary profile was left untouched.");
            }
        }

        _audioVolume?.Dispose();
        _audioVolume = null;
        _environment = null;
        _allowClose = true;
        try { Close(); }
        catch (Exception)
        {
            ExitCode = 1;
            _profileMayBeRemoved = false;
            Report("Cleanup incomplete: the native fixture window could not close safely.");
        }
    }

    private void OnAppWindowClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_allowClose)
            return;
        args.Cancel = true;
        if (!_shutdownStarted)
            _ = ShutdownAsync();
    }

    private void OnClosed(object sender, WindowEventArgs args)
    {
        if (_disposed)
            return;
        _disposed = true;
        _closeTimer.Stop();
        _appWindow.Closing -= OnAppWindowClosing;
        _lifetime.Cancel();
        _audioVolume?.Dispose();
        _audioVolume = null;
        try { _audioGate.Dispose(); }
        catch (Exception) { ExitCode = 1; }
        try { _lifetime.Dispose(); }
        catch (Exception) { ExitCode = 1; }
    }

    private void RequestClose()
    {
        if (!_allowClose && !_shutdownStarted)
            _ = ShutdownAsync();
    }

    private void ScheduleClose()
        => _dispatcher.TryEnqueue(RequestClose);

    private void Fail(string message)
    {
        ExitCode = 1;
        SetStatus("FAIL: " + message);
        Console.Error.WriteLine("Output audio fixture failed: " + message);
    }

    private void SetStatus(string message)
    {
        _status.Text = message;
    }

    private static void ReportReadback(double scalar)
    {
        var percent = scalar * 100d;
        Report($"Session scalar readback: {percent:0}% (local tone active).");
    }

    private static void Report(string message)
        => Console.WriteLine("Output audio fixture: " + message);

    private static void RequireScalar(double actual, double expected, string stage)
    {
        if (!double.IsFinite(actual) || Math.Abs(actual - expected) > ScalarTolerance)
            throw new FixtureFailure($"The {stage} did not match the requested value.");
    }

    private static string FixtureHtml => """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'none'; img-src 'none'; media-src 'none'; frame-src 'none'; font-src 'none'; form-action 'none'; object-src 'none'; base-uri 'none'">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>Nativune Output Audio Fixture</title>
          <style>
            body { font: 16px "Segoe UI", sans-serif; color: #202124; margin: 16px; }
            button { font: inherit; margin-right: 8px; padding: 8px 14px; }
            #state { margin-top: 12px; }
          </style>
        </head>
        <body>
          <h1>Local WebView2 output audio check</h1>
          <p>This page is embedded in the fixture. It does not sign in, load Music, or request remote content. Start plays a quiet 440 Hz tone while the app checks only this WebView2 environment's session scalar.</p>
          <button id="start" type="button">Start test tone</button>
          <button id="stop" type="button" disabled>Stop test tone</button>
          <p id="state" role="status" aria-live="polite">Ready. Start the tone to begin verification.</p>
          <script>
            let context = null;
            let oscillator = null;
            let gain = null;
            let stopRequestCount = 0;
            const startButton = document.getElementById('start');
            const stopButton = document.getElementById('stop');
            const state = document.getElementById('state');
            const setTitle = value => { document.title = 'Nativune Output Audio Fixture: ' + value; };
            function finishFixtureTone() {
              const oldContext = context;
              context = null;
              oscillator = null;
              gain = null;
              startButton.disabled = false;
              stopButton.disabled = true;
              state.textContent = 'Tone stopped.';
              if (oldContext) {
                try { oldContext.close(); } catch (_) { }
              }
              setTitle('tone-stopped');
              return true;
            }
            window.finishFixtureTone = finishFixtureTone;
            startButton.addEventListener('click', async () => {
              if (context) return;
              try {
                context = new AudioContext();
                oscillator = context.createOscillator();
                gain = context.createGain();
                oscillator.type = 'sine';
                oscillator.frequency.value = 440;
                gain.gain.value = 0;
                oscillator.connect(gain);
                gain.connect(context.destination);
                oscillator.start();
                gain.gain.setTargetAtTime(0.05, context.currentTime, 0.04);
                await context.resume();
                if (context.state !== 'running') throw new Error('audio-context-not-running');
                startButton.disabled = true;
                stopButton.disabled = false;
                state.textContent = 'Quiet 440 Hz tone is running. Stop remains available.';
                setTitle('tone-started');
              } catch (_) {
                finishFixtureTone();
                state.textContent = 'Web Audio could not start in this runtime.';
                setTitle('audio-error');
              }
            });
            stopButton.addEventListener('click', () => {
              if (!context) return;
              state.textContent = 'The app is restoring the owned session before stopping the tone. You can retry Stop if needed.';
              setTitle('stop-requested-' + (++stopRequestCount));
            });
          </script>
        </body>
        </html>
        """;

    private readonly record struct AudioState(double Volume, bool Muted);

    private sealed class FixtureFailure : Exception
    {
        internal FixtureFailure(string message) : base(message) { }
    }
}
