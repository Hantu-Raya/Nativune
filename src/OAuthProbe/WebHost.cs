using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32.SafeHandles;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Text.Json;
using System.Windows.Forms;

namespace OAuthProbe;

internal static class WebHost
{
    private const string InitialUri = "https://music.youtube.com/";

    public static int Run(string root)
    {
        Exception? startupFailure = null;
        var thread = new Thread(() =>
        {
            try
            {
                ApplicationConfiguration.Initialize();
                using var form = new WebHostForm(root, InitialUri);
                Application.Run(form);
            }
            catch (Exception ex)
            {
                startupFailure = ex;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();

        if (startupFailure is not null)
        {
            Console.Error.WriteLine($"Web host failed to start: {startupFailure.Message}");
            return 1;
        }

        return 0;
    }
}

internal static class WebHostPolicy
{
    private const string MusicHost = "music.youtube.com";
    private const string AccountsHost = "accounts.google.com";

    internal static bool IsAllowedMainFrameNavigation(Uri uri)
    {
        if (!uri.IsAbsoluteUri || uri.Scheme != Uri.UriSchemeHttps || !uri.IsDefaultPort || uri.UserInfo.Length != 0)
            return false;

        return uri.Host.Equals(MusicHost, StringComparison.OrdinalIgnoreCase)
            || uri.Host.Equals("www.youtube.com", StringComparison.OrdinalIgnoreCase)
            || uri.Host.Equals(AccountsHost, StringComparison.OrdinalIgnoreCase)
            || uri.Host.Equals("accounts.google.com.my", StringComparison.OrdinalIgnoreCase)
            || uri.Host.Equals("accounts.youtube.com", StringComparison.OrdinalIgnoreCase);
    }
}

internal sealed class WebHostForm : Form
{
    private readonly string _root;
    private readonly string _initialUri;
    private readonly Label _status = new();
    private readonly WebView2 _webView = new();
    private CoreWebView2Environment? _environment;
    private bool _disposed;
    private ulong? _activeNavigation;
    private ulong? _blockedNavigation;
    private bool _configuringPrivacy = true;
    private string? _privacySetupUri;

    public WebHostForm(string root, string initialUri)
    {
        _root = root;
        _initialUri = initialUri;
        Text = "Music Desktop — Compatibility Test";
        Width = 1280;
        Height = 800;
        MinimumSize = new System.Drawing.Size(640, 480);

        _status.AutoSize = false;
        _status.Dock = DockStyle.Top;
        _status.Height = 30;
        _status.Padding = new Padding(8, 6, 8, 4);
        _status.Text = "Preparing embedded Music window...";

        _webView.Dock = DockStyle.Fill;
        _webView.Visible = false;
        Controls.Add(_webView);
        Controls.Add(_status);
        Shown += async (_, _) => await InitializeAsync();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _disposed = true;
            if (_environment is not null)
                _environment.ProcessInfosChanged -= OnProcessInfosChanged;
            _webView.Dispose();
        }
        base.Dispose(disposing);
    }

    private async Task InitializeAsync()
    {
        try
        {
            var runtimeDirectory = ResolveRuntimeDirectory(_root);
            var profileDirectory = RootLocator.WebViewProfilePath(_root);
            Directory.CreateDirectory(profileDirectory);
            SetStatus("Starting pinned WebView2 runtime...");
            _environment = await CoreWebView2Environment.CreateAsync(runtimeDirectory, profileDirectory,
                new CoreWebView2EnvironmentOptions { AreBrowserExtensionsEnabled = true });
            await _webView.EnsureCoreWebView2Async(_environment);
            if (_disposed)
                return;

            var core = _webView.CoreWebView2;
            core.MemoryUsageTargetLevel = CoreWebView2MemoryUsageTargetLevel.Low;
            Console.WriteLine($"Default memory policy: {core.MemoryUsageTargetLevel}");
            _environment.ProcessInfosChanged += OnProcessInfosChanged;
            OnProcessInfosChanged(null, EventArgs.Empty);
            core.Settings.AreHostObjectsAllowed = false;
            core.Settings.IsWebMessageEnabled = false;
            core.NavigationStarting += OnNavigationStarting;
            core.NewWindowRequested += OnNewWindowRequested;
            core.PermissionRequested += OnPermissionRequested;
            core.DownloadStarting += OnDownloadStarting;
            core.LaunchingExternalUriScheme += OnLaunchingExternalUriScheme;
            core.ProcessFailed += OnProcessFailed;
            await ConfigurePrivacyAsync(core);
            if (_disposed)
                return;
            _configuringPrivacy = false;
            core.NavigationCompleted += OnNavigationCompleted;
            _webView.Visible = true;
            SetStatus("Loading official YouTube Music...");
            core.Navigate(_initialUri);
        }
        catch (Exception ex)
        {
            SetStatus($"WebView2 runtime error: {ex.Message}", isError: true);
        }
    }

    private void OnProcessInfosChanged(object? sender, object args)
    {
        if (_disposed || _environment is null)
            return;
        try
        {
            // SDK process infos omit helpers such as Crashpad. Walk the owned tree instead.
            using var snapshot = CreateToolhelp32Snapshot(2, 0);
            var entry = new ProcessEntry { Size = (uint)Marshal.SizeOf<ProcessEntry>() };
            if (snapshot.IsInvalid || !Process32First(snapshot, ref entry))
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var processes = new List<(int Id, int Parent)>();
            do { processes.Add(((int)entry.ProcessId, (int)entry.ParentProcessId)); }
            while (Process32Next(snapshot, ref entry));
            if (Marshal.GetLastWin32Error() != 18) // ERROR_NO_MORE_FILES
                throw new Win32Exception(Marshal.GetLastWin32Error());
            var owned = new HashSet<int> { Environment.ProcessId };
            bool added;
            do
            {
                added = false;
                foreach (var process in processes)
                    if (owned.Contains(process.Parent) && owned.Add(process.Id))
                        added = true;
            } while (added);
            foreach (var id in owned)
                ApplyEfficiencyMode(id);
        }
        catch (Win32Exception ex)
        {
            Console.Error.WriteLine($"Efficiency process discovery failed: {ex.Message}");
            SetStatus("Could not apply efficiency mode to the full process tree.", isError: true);
        }
    }

    private void ApplyEfficiencyMode(int processId)
    {
        const uint processSetInformation = 0x0200;
        const uint idlePriorityClass = 0x0040;
        const int processPowerThrottling = 4;
        using var handle = OpenProcess(processSetInformation, false, processId);
        var state = new PowerThrottlingState { Version = 1, ControlMask = 1, StateMask = 1 };
        if (handle.IsInvalid
            || !SetProcessInformation(handle, processPowerThrottling, ref state, Marshal.SizeOf<PowerThrottlingState>())
            || !SetPriorityClass(handle, idlePriorityClass))
        {
            var error = Marshal.GetLastWin32Error();
            // A runtime process can exit between the SDK snapshot and OpenProcess.
            if (error == 87 && handle.IsInvalid)
                return;
            var message = $"Efficiency mode failed for process {processId}: {new Win32Exception(error).Message}";
            Console.Error.WriteLine(message);
            SetStatus(message, isError: true);
        }
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PowerThrottlingState
    {
        public uint Version;
        public uint ControlMask;
        public uint StateMask;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct ProcessEntry
    {
        public uint Size, Usage, ProcessId;
        public UIntPtr DefaultHeapId;
        public uint ModuleId, Threads, ParentProcessId;
        public int BasePriority;
        public uint Flags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)]
        public string Executable;
    }

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeFileHandle CreateToolhelp32Snapshot(uint flags, uint processId);

    [DllImport("kernel32.dll", EntryPoint = "Process32FirstW", SetLastError = true)]
    private static extern bool Process32First(SafeFileHandle snapshot, ref ProcessEntry entry);

    [DllImport("kernel32.dll", EntryPoint = "Process32NextW", SetLastError = true)]
    private static extern bool Process32Next(SafeFileHandle snapshot, ref ProcessEntry entry);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern SafeProcessHandle OpenProcess(uint access, bool inheritHandle, int processId);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetProcessInformation(SafeProcessHandle process, int informationClass,
        ref PowerThrottlingState information, int informationSize);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetPriorityClass(SafeProcessHandle process, uint priorityClass);

    private async Task ConfigurePrivacyAsync(CoreWebView2 core)
    {
        const string version = "2026.907.2003";
        var directory = Path.Combine(_root, ".tools", "ubol", version);
        if (!File.Exists(Path.Combine(directory, "manifest.json")))
            throw new FileNotFoundException("Run scripts/setup-ubol.ps1 to install the pinned privacy extension.");

        SetStatus("Configuring uBO Lite privacy protection...");
        var extension = await core.Profile.AddBrowserExtensionAsync(directory);
        var loaded = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        void OnLoaded(object? sender, CoreWebView2NavigationCompletedEventArgs args)
        {
            if (args.IsSuccess && core.Source == _privacySetupUri)
                loaded.TrySetResult();
            else
                loaded.TrySetException(new InvalidOperationException("Could not load the uBO Lite configuration page."));
        }
        core.NavigationCompleted += OnLoaded;
        try
        {
            await extension.EnableAsync(true);
            _privacySetupUri = $"chrome-extension://{extension.Id}/dashboard.html";
            core.Navigate(_privacySetupUri);
            await loaded.Task.WaitAsync(TimeSpan.FromSeconds(20));
            if (core.Source != _privacySetupUri)
                throw new InvalidOperationException("Privacy configuration origin changed.");

            // Configure the original pinned extension through its own trusted-page messages.
            // Remote Music content never gets this capability or a native bridge.
            const string expression = """
                (async () => {
                    if (chrome.runtime.getManifest().version !== '2026.907.2003')
                        throw new Error('Unexpected uBO Lite version');
                    const send = message => chrome.runtime.sendMessage(message);
                    await send({what:'getOptionsPageData'});
                    await send({what:'setStrictBlockMode',state:false});
                    await send({what:'setPopupBlockMode',state:false});
                    await send({what:'applyRulesets',enabledRulesets:['easyprivacy']});
                    const modes = {none:['all-urls'],basic:['music.youtube.com'],optimal:[],complete:[]};
                    await send({what:'setFilteringModeDetails',modes});
                    const config = await send({what:'getOptionsPageData'});
                    const enabled = await chrome.declarativeNetRequest.getEnabledRulesets();
                    const actualModes = await send({what:'getFilteringModeDetails'});
                    const scripts = await chrome.scripting.getRegisteredContentScripts();
                    return enabled.length === 1 && enabled[0] === 'easyprivacy'
                        && config.enabledRulesets.length === 1 && config.enabledRulesets[0] === 'easyprivacy'
                        && !config.strictBlockMode && !config.popupBlockMode
                        && JSON.stringify(actualModes) === JSON.stringify(modes)
                        // The upstream toolbar-state notifier does not filter page content.
                        && scripts.every(s => s.id === 'toolbar-icon');
                })()
                """;
            var parameters = JsonSerializer.Serialize(new { expression, awaitPromise = true, returnByValue = true });
            using var result = JsonDocument.Parse(await core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", parameters)
                .WaitAsync(TimeSpan.FromSeconds(30)));
            if (result.RootElement.TryGetProperty("exceptionDetails", out _)
                || !result.RootElement.GetProperty("result").TryGetProperty("value", out var value)
                || value.ValueKind != JsonValueKind.True)
                throw new InvalidOperationException("uBO Lite privacy-only configuration could not be verified; Music was not loaded.");
            Console.WriteLine("uBO Lite verified: EasyPrivacy only, Music Basic mode, no cosmetic filters or scriptlets.");
        }
        catch
        {
            core.Stop();
            await extension.EnableAsync(false);
            throw;
        }
        finally
        {
            core.NavigationCompleted -= OnLoaded;
            _privacySetupUri = null;
        }
    }

    private void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs args)
    {
        if (_configuringPrivacy)
        {
            args.Cancel = !string.Equals(args.Uri, _privacySetupUri, StringComparison.Ordinal);
            return;
        }
        _activeNavigation = args.NavigationId;
        if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) || !WebHostPolicy.IsAllowedMainFrameNavigation(uri))
        {
            args.Cancel = true;
            _blockedNavigation = args.NavigationId;
            var destination = uri is null ? "invalid address" : uri.GetComponents(UriComponents.SchemeAndServer, UriFormat.SafeUnescaped);
            SetStatus($"Navigation blocked to {destination}. Only Music and Google account pages are allowed.", isError: true);
            Console.WriteLine($"Blocked navigation origin: {destination}");
        }
    }

    private void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        if (args.NavigationId != _activeNavigation || args.NavigationId == _blockedNavigation)
            return;
        if (!args.IsSuccess)
            SetStatus($"Page navigation failed: {args.WebErrorStatus}.", isError: true);
        else
        {
            SetStatus("Page ready. Sign in directly to Google to test your account.");
            Console.WriteLine("Embedded web page ready.");
        }
    }

    private void OnNewWindowRequested(object? sender, CoreWebView2NewWindowRequestedEventArgs args)
    {
        args.Handled = true;
        if (_configuringPrivacy)
            return;
        if (Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) && WebHostPolicy.IsAllowedMainFrameNavigation(uri))
        {
            _webView.CoreWebView2.Navigate(uri.ToString());
            return;
        }

        SetStatus("New window blocked: only Music and Google account pages are allowed.", isError: true);
    }

    private void OnPermissionRequested(object? sender, CoreWebView2PermissionRequestedEventArgs args)
    {
        args.State = CoreWebView2PermissionState.Deny;
        args.Handled = true;
        SetStatus("Permission request denied.", isError: true);
    }

    private void OnDownloadStarting(object? sender, CoreWebView2DownloadStartingEventArgs args)
    {
        args.Cancel = true;
        SetStatus("Downloads are disabled.", isError: true);
    }

    private void OnLaunchingExternalUriScheme(object? sender, CoreWebView2LaunchingExternalUriSchemeEventArgs args)
    {
        args.Cancel = true;
        SetStatus("External URI launch blocked.", isError: true);
    }

    private void OnProcessFailed(object? sender, CoreWebView2ProcessFailedEventArgs args)
    {
        SetStatus($"WebView2 process failed: {args.ProcessFailedKind}.", isError: true);
    }

    private void SetStatus(string text, bool isError = false)
    {
        if (_disposed || IsDisposed)
            return;
        _status.ForeColor = isError ? System.Drawing.Color.DarkRed : System.Drawing.SystemColors.ControlText;
        _status.Text = text;
    }

    private static string ResolveRuntimeDirectory(string root)
    {
        var manifestPath = RootLocator.WebViewRuntimeManifestPath(root);
        if (!File.Exists(manifestPath))
            throw new FileNotFoundException("The WebView2 runtime-path.txt file is missing; run the local runtime setup first.", manifestPath);

        string relativeDirectory;
        try
        {
            relativeDirectory = File.ReadAllText(manifestPath).Trim();
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
            throw new InvalidOperationException("The WebView2 runtime-path.txt file could not be read.", ex);
        }

        if (relativeDirectory.Length == 0
            || relativeDirectory is "." or ".."
            || relativeDirectory != Path.GetFileName(relativeDirectory)
            || relativeDirectory.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
        {
            throw new InvalidOperationException("The WebView2 runtime-path.txt file must contain one relative version directory name.");
        }

        var runtimeRoot = Path.GetFullPath(Path.Combine(root, ".tools", "webview2"));
        var runtimeDirectory = Path.GetFullPath(Path.Combine(runtimeRoot, relativeDirectory));
        var runtimePrefix = runtimeRoot + Path.DirectorySeparatorChar;
        if (!runtimeDirectory.StartsWith(runtimePrefix, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("The WebView2 runtime path escapes .tools/webview2.");
        if (!Directory.Exists(runtimeDirectory) || !File.Exists(Path.Combine(runtimeDirectory, "msedgewebview2.exe")))
            throw new FileNotFoundException("The pinned WebView2 runtime executable is missing.", runtimeDirectory);

        return runtimeDirectory;
    }
}
