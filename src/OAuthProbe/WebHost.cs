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
        var exitCode = 0;
        var thread = new Thread(() =>
        {
            try
            {
                using var instance = SingleInstance.Acquire(root);
                if (instance is null)
                    return;
                ApplicationConfiguration.Initialize();
                using var form = new WebHostForm(root, InitialUri);
                instance.StartListening(() => form.RequestActivation());
                Application.Run(form);
                exitCode = form.ExitCode;
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
            Console.Error.WriteLine("Web host could not start. Check the local runtime and whether this profile is already in use.");
            return 1;
        }

        return exitCode;
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
    private readonly CancellationTokenSource _lifetime = new();
    private readonly MenuStrip _menu = new();
    private readonly ToolStripMenuItem _back = new("&Back");
    private readonly ToolStripMenuItem _forward = new("&Forward");
    private readonly ToolStripMenuItem _home = new("&Home");
    private readonly ToolStripMenuItem _retry = new("&Retry");
    private readonly ToolStripMenuItem _timerMenu = new("Quit &timer");
    private readonly ToolStripMenuItem _compactItem = new("&Compact window");
    private readonly ToolStripMenuItem _topmostItem = new("Always on &top") { CheckOnClick = true };
    private readonly ToolStripMenuItem _trayItem = new("Enable &tray icon") { CheckOnClick = true };
    private readonly ToolStripMenuItem _hideItem = new("&Hide to tray (keeps playing)");
    private readonly ToolStripMenuItem _restoreItem = new("Start on last &section") { CheckOnClick = true };
    private NotifyIcon? _tray;
    private ContextMenuStrip? _trayMenu;
    private Icon? _trayIcon;
    private bool _compact;
    private Rectangle _fullBounds;
    private FormWindowState _fullState;
    private int _fullDpi;
    private static readonly int TaskbarCreated = RegisterWindowMessage("TaskbarCreated");
    private readonly System.Windows.Forms.Timer _saveTimer = new() { Interval = 1000 };
    private readonly CancellationTokenSource _saveCancellation = new();
    private ShellSettings _settings;
    private ShellSettings? _pendingSettings;
    private Task _saveTask = Task.CompletedTask;
    private SleepDeadline? _sleep;
    private bool _browserFailed, _navigationFailed, _closing, _closeReady, _fullscreen;
    private int _activationPending;
    private Rectangle _windowBounds;
    private FormWindowState _windowState;
    private FormWindowState _lastWindowState;
    private string? _settingsWarning;
    internal int ExitCode { get; private set; }

    public WebHostForm(string root, string initialUri)
    {
        _root = root;
        _initialUri = initialUri;
        _settings = ShellSettings.Load(root, out _settingsWarning);
        Text = "Music Desktop";
        StartPosition = FormStartPosition.Manual;
        var desired = new Rectangle(_settings.X, _settings.Y, _settings.Width, _settings.Height);
        var workArea = Screen.FromRectangle(desired).WorkingArea;
        Bounds = ShellSettings.RestoreBounds(_settings, workArea, DeviceDpi);
        MinimumSize = new System.Drawing.Size(Math.Min(640, workArea.Width), Math.Min(480, workArea.Height));
        if (_settings.Maximized)
            WindowState = FormWindowState.Maximized;
        _lastWindowState = WindowState;

        _status.AutoSize = false;
        _status.Dock = DockStyle.Bottom;
        _status.Height = 48;
        _status.Padding = new Padding(8, 6, 8, 4);
        _status.Text = "Preparing embedded Music window...";

        _webView.Dock = DockStyle.Fill;
        _webView.Visible = false;
        Controls.Add(_webView);
        Controls.Add(_status);
        BuildMenu();
        _saveTimer.Tick += (_, _) => { _saveTimer.Stop(); CaptureSettings(); };
        Shown += async (_, _) =>
        {
            _sleep = new SleepDeadline(OnTimerExpired, SynchronizationContext.Current!);
            if (_settings.TrayEnabled) SetTrayEnabled(true);
            if (Volatile.Read(ref _activationPending) != 0)
                ActivateWindow();
            await InitializeAsync();
        };
        ResizeEnd += (_, _) => ScheduleSettings();
        SizeChanged += (_, _) =>
        {
            if (!_closing && WindowState != FormWindowState.Minimized && _webView.ZoomFactor != 1)
                SetZoom(1);
            else
                ScheduleSettings();
        };
        DpiChanged += (_, _) => ScheduleSettings();
    }

    private void BuildMenu()
    {
        _back.Click += (_, _) => { if (CanNavigate && _webView.CanGoBack) _webView.GoBack(); };
        _forward.Click += (_, _) => { if (CanNavigate && _webView.CanGoForward) _webView.GoForward(); };
        _home.Click += (_, _) => { if (CanNavigate) _webView.CoreWebView2.Navigate(_initialUri); };
        _retry.Click += (_, _) =>
        {
            if (!CanNavigate || !_navigationFailed) return;
            _navigationFailed = false;
            UpdateNavigation();
            _webView.Reload();
        };
        var view = new ToolStripMenuItem("&View");
        view.DropDownItems.Add("Zoom &in", null, (_, _) => SetZoom(_settings.Zoom + 0.1));
        view.DropDownItems.Add("Zoom &out", null, (_, _) => SetZoom(_settings.Zoom - 0.1));
        view.DropDownItems.Add("&Reset zoom", null, (_, _) => SetZoom(1));
        view.DropDownItems.Add("&Fullscreen (F11)", null, (_, _) => ToggleFullscreen());
        _compactItem.Click += (_, _) => ToggleCompact();
        _topmostItem.CheckedChanged += (_, _) => TopMost = _topmostItem.Checked;
        _trayItem.Checked = _settings.TrayEnabled;
        _trayItem.Click += (_, _) => { SetTrayEnabled(_trayItem.Checked); CaptureSettings(); };
        _hideItem.Click += (_, _) => HideToTray();
        _restoreItem.Checked = _settings.RestoreSection;
        _restoreItem.Click += (_, _) =>
        {
            _settings = _settings with { RestoreSection = _restoreItem.Checked, LastSection = "home" };
            ObserveSection();
            CaptureSettings();
            SetStatus(_restoreItem.Checked
                ? "Remembering Home or Library only. The website still owns account, queue and autoplay behavior."
                : "Section restore disabled. Startup returns to Home.");
        };
        view.DropDownItems.Add(new ToolStripSeparator());
        view.DropDownItems.AddRange([_compactItem, _topmostItem, _trayItem, _hideItem, _restoreItem]);
        _timerMenu.DropDownItems.Add("&Set quit timer...", null, (_, _) => SetQuitTimer());
        _timerMenu.DropDownItems.Add("&Cancel timer", null, (_, _) =>
        {
            _sleep?.Cancel();
            _timerMenu.Text = "Quit &timer";
            SetStatus("Quit timer cancelled.");
        });
        var quit = new ToolStripMenuItem("&Quit", null, (_, _) => Close());
        _menu.Items.AddRange([_back, _forward, _home, _retry, view, _timerMenu, quit]);
        MainMenuStrip = _menu;
        Controls.Add(_menu);
        UpdateNavigation();
    }

    private bool CanNavigate => !_disposed && !_closing && !_configuringPrivacy && !_browserFailed;

    private void UpdateNavigation()
    {
        _back.Enabled = CanNavigate && _webView.CanGoBack;
        _forward.Enabled = CanNavigate && _webView.CanGoForward;
        _home.Enabled = CanNavigate;
        _hideItem.Enabled = CanNavigate && _tray is not null && GetShellWindow() != IntPtr.Zero;
        _retry.Enabled = CanNavigate && _navigationFailed;
    }

    private void ToggleCompact()
    {
        if (_closing) return;
        if (_fullscreen) ToggleFullscreen();
        if (!_compact)
        {
            CaptureSettings();
            _fullBounds = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
            _fullState = WindowState == FormWindowState.Minimized ? _lastWindowState : WindowState;
            _fullDpi = DeviceDpi;
            _compact = true;
            _compactItem.Text = "&Restore full size";
            WindowState = FormWindowState.Normal;
            ResizeCompact();
        }
        else
        {
            var saved = _settings with { X = _fullBounds.X, Y = _fullBounds.Y, Width = _fullBounds.Width,
                Height = _fullBounds.Height, Dpi = _fullDpi };
            WindowState = FormWindowState.Normal;
            Bounds = ShellSettings.RestoreBounds(saved, Screen.FromRectangle(_fullBounds).WorkingArea, DeviceDpi);
            WindowState = _fullState;
            _compact = false;
            _lastWindowState = _fullState;
            _compactItem.Text = "&Compact window";
        }
    }

    private void ResizeCompact()
    {
        var scale = DeviceDpi / 96d;
        var area = Screen.FromControl(this).WorkingArea;
        Bounds = ShellSettings.RestoreBounds(_settings with { X = Left, Y = Top,
            Width = (int)(640 * scale), Height = (int)(480 * scale), Dpi = DeviceDpi }, area, DeviceDpi);
    }

    private void SetTrayEnabled(bool enabled)
    {
        if (!enabled)
        {
            if (!Visible && !_closing) ActivateWindow();
            DisposeTray();
        }
        else if (_tray is null)
        {
            try
            {
                using var bitmap = new Bitmap(32, 32);
                using (var graphics = Graphics.FromImage(bitmap))
                using (var pen = new Pen(Color.MediumSeaGreen, 4))
                {
                    graphics.Clear(Color.Transparent);
                    graphics.DrawLine(pen, 13, 8, 13, 23);
                    graphics.DrawLine(pen, 13, 8, 25, 5);
                    graphics.DrawLine(pen, 25, 5, 25, 20);
                    graphics.FillEllipse(Brushes.MediumSeaGreen, 5, 20, 10, 8);
                    graphics.FillEllipse(Brushes.MediumSeaGreen, 17, 17, 10, 8);
                }
                var handle = bitmap.GetHicon();
                try { _trayIcon = (Icon)Icon.FromHandle(handle).Clone(); }
                finally { DestroyIcon(handle); }
                _trayMenu = new ContextMenuStrip();
                _trayMenu.Items.Add("Show", null, (_, _) => ActivateWindow());
                _trayMenu.Items.Add("Hide (keeps playing)", null, (_, _) => HideToTray());
                _trayMenu.Items.Add("Disable tray icon", null, (_, _) => { SetTrayEnabled(false); CaptureSettings(); });
                _trayMenu.Items.Add("Quit", null, (_, _) => Close());
                _tray = new NotifyIcon { Icon = _trayIcon, Text = "Music Desktop", ContextMenuStrip = _trayMenu, Visible = true };
                _tray.DoubleClick += (_, _) => ActivateWindow();
            }
            catch (Exception ex) when (ex is Win32Exception or ArgumentException or ExternalException)
            {
                DisposeTray();
                enabled = false;
                SetStatus("Tray icon could not be created. The window remains available.", true);
            }
        }
        _trayItem.Checked = enabled;
        _settings = _settings with { TrayEnabled = enabled };
        if (enabled) SetStatus("Tray enabled. Hide keeps playback running; Close and Quit exit. Launch again or use the tray to restore.");
        UpdateNavigation();
    }

    private void DisposeTray()
    {
        _tray?.Dispose();
        _tray = null;
        _trayMenu?.Dispose();
        _trayMenu = null;
        _trayIcon?.Dispose();
        _trayIcon = null;
    }

    private void HideToTray()
    {
        if (_tray is null || !CanNavigate || GetShellWindow() == IntPtr.Zero) return;
        CaptureSettings();
        Hide();
    }

    private void ObserveSection()
    {
        if (!CanNavigate || !_settings.RestoreSection
            || !Uri.TryCreate(_webView.CoreWebView2.Source, UriKind.Absolute, out var uri)) return;
        var section = ShellSettings.SectionFromUri(uri);
        if (section is not null && section != _settings.LastSection)
        {
            _settings = _settings with { LastSection = section };
            CaptureSettings();
        }
    }

    private void SetZoom(double zoom)
    {
        _settings = _settings with { Zoom = Math.Clamp(Math.Round(zoom, 2), 0.75, 1.5) };
        if (!_disposed && !_closing)
            _webView.ZoomFactor = _settings.Zoom;
        ScheduleSettings();
        SetStatus($"Zoom: {_settings.Zoom:P0}.");
    }

    private void ScheduleSettings()
    {
        if (_closing || _fullscreen || _compact || !IsHandleCreated || !Visible) return;
        if (WindowState != FormWindowState.Minimized)
            _lastWindowState = WindowState;
        _saveTimer.Stop();
        _saveTimer.Start();
    }

    private void CaptureSettings()
    {
        var bounds = _compact ? _fullBounds : _fullscreen ? _windowBounds : WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
        if (bounds.Width <= 0 || bounds.Height <= 0) return;
        _settings = _settings with
        {
            X = bounds.X, Y = bounds.Y, Width = bounds.Width, Height = bounds.Height, Dpi = _compact ? _fullDpi : DeviceDpi,
            Maximized = (_compact ? _fullState : _fullscreen ? _windowState : _lastWindowState) == FormWindowState.Maximized
        };
        _pendingSettings = _settings;
        if (_saveTask.IsCompleted)
            _saveTask = SaveSettingsAsync();
    }

    private async Task SaveSettingsAsync()
    {
        while (_pendingSettings is { } snapshot && !_saveCancellation.IsCancellationRequested)
        {
            _pendingSettings = null;
            try { await Task.Run(() => ShellSettings.SaveAsync(_root, snapshot, _saveCancellation.Token)); }
            catch (OperationCanceledException) { break; }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                _settingsWarning = "Settings could not be saved. Changes apply to this session only.";
                SetStatus(_settingsWarning, true);
            }
        }
    }

    protected override async void OnFormClosing(FormClosingEventArgs e)
    {
        if (_closeReady) { base.OnFormClosing(e); return; }
        e.Cancel = true;
        base.OnFormClosing(e);
        if (_closing) return;
        _closing = true;
        _saveTimer.Stop();
        _sleep?.Cancel();
        DisposeTray();
        CaptureSettings();
        _lifetime.Cancel();
        if (_environment is not null)
            _environment.ProcessInfosChanged -= OnProcessInfosChanged;
        _webView.Dispose();
        try { await _saveTask.WaitAsync(TimeSpan.FromMilliseconds(250)); }
        catch (TimeoutException) { _saveCancellation.Cancel(); }
        _closeReady = true;
        Close();
    }

    internal void RequestActivation()
    {
        if (Interlocked.Exchange(ref _activationPending, 1) != 0) return;
        if (_disposed || _closing || !IsHandleCreated) return;
        try { BeginInvoke(ActivateWindow); }
        catch (InvalidOperationException) { }
    }

    private void ActivateWindow()
    {
        if (_disposed || _closing) return;
        Interlocked.Exchange(ref _activationPending, 0);
        Show();
        if (WindowState == FormWindowState.Minimized) WindowState = _lastWindowState;
        Activate();
        if (!ContainsFocus) FlashWindow(Handle, true);
    }

    private void ToggleFullscreen()
    {
        if (_closing) return;
        if (_compact) ToggleCompact();
        if (!_fullscreen)
        {
            _windowState = WindowState;
            _windowBounds = WindowState == FormWindowState.Normal ? Bounds : RestoreBounds;
            _fullscreen = true;
            WindowState = FormWindowState.Normal;
            FormBorderStyle = FormBorderStyle.None;
            Bounds = Screen.FromControl(this).Bounds;
        }
        else
        {
            _fullscreen = false;
            FormBorderStyle = FormBorderStyle.Sizable;
            Bounds = ShellSettings.RestoreBounds(_settings with
            { X = _windowBounds.X, Y = _windowBounds.Y, Width = _windowBounds.Width, Height = _windowBounds.Height, Dpi = DeviceDpi },
                Screen.FromRectangle(_windowBounds).WorkingArea, DeviceDpi);
            WindowState = _windowState;
        }
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.F11) { ToggleFullscreen(); return true; }
        if (keyData == Keys.Escape && _fullscreen) { ToggleFullscreen(); return true; }
        if (keyData == (Keys.Alt | Keys.Left)) { if (_back.Enabled) _back.PerformClick(); return true; }
        if (keyData == (Keys.Alt | Keys.Right)) { if (_forward.Enabled) _forward.PerformClick(); return true; }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    private Keys _handledBrowserKey;

    private void OnBrowserKeyDown(object? sender, KeyEventArgs e)
    {
        var key = e.KeyData;
        Action? action = key switch
        {
            Keys.F11 => ToggleFullscreen,
            Keys.Escape when _fullscreen => ToggleFullscreen,
            (Keys.Alt | Keys.Left) when _back.Enabled => () => _back.PerformClick(),
            (Keys.Alt | Keys.Right) when _forward.Enabled => () => _forward.PerformClick(),
            _ => null
        };
        if (action is null) return;
        e.Handled = true;
        if (_handledBrowserKey == key || _closing) return;
        _handledBrowserKey = key;
        BeginInvoke(action);
    }

    private void SetQuitTimer()
    {
        if (_sleep is null || _closing) return;
        using var dialog = new Form { Text = "Quit this app in...", FormBorderStyle = FormBorderStyle.FixedDialog,
            StartPosition = FormStartPosition.CenterParent, ClientSize = new Size(420, 150), MinimizeBox = false, MaximizeBox = false };
        var label = new Label { Text = "Minutes (1-240). Quits this app and stops local playback.\nDoes not stop a remote cast or put Windows to sleep.",
            AutoSize = false, Bounds = new Rectangle(12, 12, 396, 48) };
        var minutes = new NumericUpDown { Minimum = 1, Maximum = 240, Value = 30, Bounds = new Rectangle(12, 68, 110, 28), AccessibleName = "Minutes until quit" };
        var set = new Button { Text = "Set timer", DialogResult = DialogResult.OK, Bounds = new Rectangle(212, 106, 94, 30) };
        var cancel = new Button { Text = "Cancel", DialogResult = DialogResult.Cancel, Bounds = new Rectangle(312, 106, 94, 30) };
        dialog.Controls.AddRange([label, minutes, set, cancel]);
        dialog.AcceptButton = set;
        dialog.CancelButton = cancel;
        if (dialog.ShowDialog(this) != DialogResult.OK || _closing) return;
        _sleep.Arm(TimeSpan.FromMinutes((double)minutes.Value));
        _timerMenu.Text = $"Quit &timer: {_sleep.DisplayDeadline:t}";
        SetStatus("Quit timer armed. It includes sleep time and is not restored after restart.");
    }

    private void OnTimerExpired()
    {
        if (!_closing && !_disposed) Close();
    }

    protected override void WndProc(ref Message m)
    {
        const int wmPowerBroadcast = 0x0218, wmDisplayChange = 0x007e;
        if (m.Msg == wmPowerBroadcast && (m.WParam == 7 || m.WParam == 18))
            _sleep?.CheckOnResume();
        if (TaskbarCreated != 0 && m.Msg == TaskbarCreated && !_closing && !_disposed && !Visible)
            ActivateWindow();
        if (m.Msg == wmDisplayChange && !_fullscreen && !_closing)
        {
            var area = Screen.FromRectangle(Bounds).WorkingArea;
            MinimumSize = new Size(Math.Min(640, area.Width), Math.Min(480, area.Height));
            if (WindowState == FormWindowState.Normal)
                Bounds = ShellSettings.RestoreBounds(_settings with { X = Left, Y = Top, Width = Width, Height = Height, Dpi = DeviceDpi }, area, DeviceDpi);
        }
        base.WndProc(ref m);
    }

    [DllImport("user32.dll")]
    private static extern bool FlashWindow(IntPtr window, bool invert);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern int RegisterWindowMessage(string message);
    [DllImport("user32.dll")]
    private static extern IntPtr GetShellWindow();
    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr icon);

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _disposed = true;
            _lifetime.Cancel();
            _sleep?.Dispose();
            DisposeTray();
            _saveTimer.Dispose();
            _saveCancellation.Cancel();
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
            var environment = await CoreWebView2Environment.CreateAsync(runtimeDirectory, profileDirectory,
                new CoreWebView2EnvironmentOptions { AreBrowserExtensionsEnabled = true });
            _lifetime.Token.ThrowIfCancellationRequested();
            _environment = environment;
            await _webView.EnsureCoreWebView2Async(environment);
            _lifetime.Token.ThrowIfCancellationRequested();
            if (_disposed)
                return;

            var core = _webView.CoreWebView2;
            core.MemoryUsageTargetLevel = CoreWebView2MemoryUsageTargetLevel.Low;
            Console.WriteLine($"Default memory policy: {core.MemoryUsageTargetLevel}");
            _environment.ProcessInfosChanged += OnProcessInfosChanged;
            OnProcessInfosChanged(null, EventArgs.Empty);
            core.Settings.AreHostObjectsAllowed = false;
            core.Settings.IsWebMessageEnabled = false;
            _webView.ZoomFactor = _settings.Zoom;
            core.HistoryChanged += (_, _) => UpdateNavigation();
            core.SourceChanged += (_, _) => ObserveSection();
            _webView.KeyDown += OnBrowserKeyDown;
            _webView.KeyUp += (_, _) => _handledBrowserKey = Keys.None;
            _webView.LostFocus += (_, _) => _handledBrowserKey = Keys.None;
            core.NavigationStarting += OnNavigationStarting;
            core.NewWindowRequested += OnNewWindowRequested;
            core.PermissionRequested += OnPermissionRequested;
            core.DownloadStarting += OnDownloadStarting;
            core.LaunchingExternalUriScheme += OnLaunchingExternalUriScheme;
            core.ProcessFailed += OnProcessFailed;
            await ConfigurePrivacyAsync(core);
            _lifetime.Token.ThrowIfCancellationRequested();
            if (_disposed)
                return;
            _configuringPrivacy = false;
            core.NavigationCompleted += OnNavigationCompleted;
            _webView.Visible = true;
            SetStatus("Loading official YouTube Music...");
            core.Navigate(_settings.StartupUri);
            UpdateNavigation();
        }
        catch (OperationCanceledException) when (_lifetime.IsCancellationRequested) { }
        catch (Exception)
        {
            if (_closing || _disposed) return;
            ExitCode = 1;
            _browserFailed = true;
            SetStatus(_configuringPrivacy
                ? "Startup or privacy verification failed. Close and relaunch after checking the local setup."
                : "Browser initialization failed. Close and relaunch.", isError: true);
            Console.Error.WriteLine("Browser startup failed; Music availability was not established.");
            UpdateNavigation();
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
        _lifetime.Token.ThrowIfCancellationRequested();
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
            _lifetime.Token.ThrowIfCancellationRequested();
            _privacySetupUri = $"chrome-extension://{extension.Id}/dashboard.html";
            core.Navigate(_privacySetupUri);
            await loaded.Task.WaitAsync(TimeSpan.FromSeconds(20), _lifetime.Token);
            _lifetime.Token.ThrowIfCancellationRequested();
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
                .WaitAsync(TimeSpan.FromSeconds(30), _lifetime.Token));
            _lifetime.Token.ThrowIfCancellationRequested();
            if (result.RootElement.TryGetProperty("exceptionDetails", out _)
                || !result.RootElement.GetProperty("result").TryGetProperty("value", out var value)
                || value.ValueKind != JsonValueKind.True)
                throw new InvalidOperationException("uBO Lite privacy-only configuration could not be verified; Music was not loaded.");
            Console.WriteLine("uBO Lite verified: EasyPrivacy only, Music Basic mode, no cosmetic filters or scriptlets.");
        }
        catch
        {
            if (!_closing && !_disposed)
            {
                core.Stop();
                await extension.EnableAsync(false);
            }
            throw;
        }
        finally
        {
            if (!_closing && !_disposed)
                core.NavigationCompleted -= OnLoaded;
            _privacySetupUri = null;
        }
    }

    private void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs args)
    {
        if (_closing || _disposed || _browserFailed) { args.Cancel = true; return; }
        if (_configuringPrivacy)
        {
            args.Cancel = !string.Equals(args.Uri, _privacySetupUri, StringComparison.Ordinal);
            return;
        }
        _activeNavigation = args.NavigationId;
        _navigationFailed = false;
        SetStatus("Loading page...");
        UpdateNavigation();
        if (!Uri.TryCreate(args.Uri, UriKind.Absolute, out var uri) || !WebHostPolicy.IsAllowedMainFrameNavigation(uri))
        {
            args.Cancel = true;
            _blockedNavigation = args.NavigationId;
            var destination = uri is null ? "invalid address" : uri.GetComponents(UriComponents.SchemeAndServer, UriFormat.SafeUnescaped);
            SetStatus($"Navigation blocked to {destination}. Only Music and Google account pages are allowed.", isError: true);
            Console.WriteLine($"Blocked navigation origin: {destination}");
        }
        else if (!uri.Host.Equals("music.youtube.com", StringComparison.OrdinalIgnoreCase))
        {
            if (_compact) ToggleCompact();
            _settings = _settings with { LastSection = "home" };
            CaptureSettings();
        }
    }

    private void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs args)
    {
        if (_closing || _disposed || _browserFailed || args.NavigationId != _activeNavigation || args.NavigationId == _blockedNavigation)
            return;
        _navigationFailed = !args.IsSuccess;
        UpdateNavigation();
        if (!args.IsSuccess)
            SetStatus($"Page navigation failed: {args.WebErrorStatus}. Use Retry.", isError: true);
        else
        {
            SetStatus("Navigation completed. Account and playback remain website-owned.");
            ObserveSection();
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
        if (_closing || _disposed) return;
        _browserFailed = true;
        ExitCode = 1;
        UpdateNavigation();
        SetStatus("Browser process failed. Close and relaunch the app.", isError: true);
    }

    private void SetStatus(string text, bool isError = false)
    {
        if (_disposed || IsDisposed)
            return;
        _status.ForeColor = System.Drawing.SystemColors.ControlText;
        _status.Text = (isError ? "Error: " : "") + text
            + (_settingsWarning is not null && text != _settingsWarning ? " " + _settingsWarning : "");
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
