using System.Collections.Concurrent;
using System.Runtime.InteropServices;
using System.Text;
using System.Globalization;

namespace Nativune.Installer;

internal sealed record SetupConfirmation(
    bool IsFreshInstall,
    bool IsUpdaterHandoff,
    string? FromVersion,
    string ToVersion,
    string InstallRoot,
    IReadOnlyList<MissingPrerequisite> MissingPrerequisites,
    long PayloadBytes);

internal sealed record SetupOutcome(
    ExitCode ExitCode,
    string Status,
    string? FromVersion,
    string ToVersion,
    string? ResultMessage,
    SetupException? Error,
    bool IsFreshInstall,
    bool CanReopen)
{
    internal bool Succeeded => ExitCode == ExitCode.Success;

    internal string MainInstruction => Status switch
    {
        "installed" => $"Nativune v{ToVersion} is installed.",
        "success" => $"Nativune was updated to v{ToVersion}.",
        "cancelled" => "Setup was cancelled.",
        _ => DescribeFailure(ExitCode),
    };

    internal string Content => Status switch
    {
        "installed" => $"Shortcuts were added to the Start menu and desktop. Installed in {InstallRootDisplay}.",
        "success" => $"Nativune was updated from v{FromVersion ?? "an earlier version"} to v{ToVersion}.",
        "cancelled" => Error?.Message ?? "Nothing was changed.",
        _ => Error?.Message ?? "Nativune was not changed. Run Setup again or contact support.",
    };

    // Replaced by the host with the validated install root for the fresh-install result page.
    internal string InstallRootDisplay { get; init; } = "%LOCALAPPDATA%\\Nativune";
    internal bool CanOpen { get; init; } = true;

    // Includes the messages so a pasted report names the failed step, component and installer exit code.
    internal string Details
        => $"Exit code: {(int)ExitCode}\r\nException type: {Error?.InnerException?.GetType().Name ?? Error?.GetType().Name ?? "none"}"
            + (Error is null ? "" : $"\r\nMessage: {Error.Message.Replace("\n", "\r\n")}")
            + (Error?.InnerException is { } inner ? $"\r\nInner message: {inner.Message}" : "");

    internal static SetupOutcome Cancelled(string? fromVersion, string toVersion, bool fresh, bool canReopen, string? message = null)
        => new(ExitCode.Cancelled, "cancelled", fromVersion, toVersion,
            "Setup was cancelled. Nothing was changed.",
            message is null ? null : new SetupException(ExitCode.Cancelled, message), fresh, canReopen);

    internal static SetupOutcome Failed(SetupException error, string? fromVersion, string toVersion, bool fresh, bool canReopen)
        => new(error.Code, "failed", fromVersion, toVersion, DescribeFailure(error.Code), error, fresh, canReopen);

    internal static SetupOutcome SucceededInstall(string? fromVersion, string toVersion, bool fresh, string root, bool canOpen)
        => new(ExitCode.Success, fresh ? "installed" : "success", fromVersion, toVersion, null, null, fresh, false)
        {
            InstallRootDisplay = root,
            CanOpen = canOpen,
        };

    private static string DescribeFailure(ExitCode code) => code switch
    {
        ExitCode.InvalidPayload => "The Setup file is damaged or incomplete. Download it again from GitHub Releases.",
        ExitCode.UnsafeRoot => "This location can't be used for Nativune.",
        ExitCode.TargetConflict => "This location already contains files that Setup can't safely replace.",
        ExitCode.WaitTimeout => "Nativune is still running. Close it, then run Setup again.",
        ExitCode.ShellFailure => "Shortcuts or the uninstall entry couldn't be written.",
        ExitCode.IoFailure => "A file couldn't be written. Check free space and antivirus, then try again.",
        ExitCode.RollbackFailure => "The upgrade failed and could not be rolled back safely.",
        ExitCode.LaunchFailure => "Nativune was installed, but it could not be started.",
        ExitCode.UnsupportedPlatform => "Nativune Setup runs on Windows only.",
        ExitCode.PrerequisiteFailure => "A required Microsoft component is missing or out of date.",
        _ => "Nativune Setup could not complete.",
    };
}

internal interface ISetupReporter
{
    void Step(string text, bool cancellable);
    void Progress(long done, long total);
    bool Confirm(SetupConfirmation confirmation);
    void Result(SetupOutcome outcome);
}

internal sealed class ConsoleSetupReporter : ISetupReporter
{
    internal static readonly ConsoleSetupReporter Instance = new();

    private ConsoleSetupReporter() { }

    public void Step(string text, bool cancellable) => Console.WriteLine(text);
    public void Progress(long done, long total) { }
    public bool Confirm(SetupConfirmation confirmation) => true;
    public void Result(SetupOutcome outcome) { }
}

internal sealed class SetupWindow : ISetupReporter, IDisposable
{
    private const uint TdfAllowDialogCancellation = 0x0008;
    private const uint TdfShowMarqueeProgressBar = 0x0200;
    private const uint TdfCallbackTimer = 0x0800;
    private const uint TdnCreated = 0;
    private const uint TdnButtonClicked = 2;
    private const uint TdnTimer = 4;
    private const uint TdnDestroyed = 5;
    private const uint TdnNavigated = 7;
    private const uint TdmNavigatePage = 0x0400 + 101;
    private const uint TdmSetMarqueeProgressBar = 0x0400 + 103;
    private const uint TdmSetProgressBarMarquee = 0x0400 + 107;
    private const uint TdmUpdateElementText = 0x0400 + 114;
    private const uint TdmEnableButton = 0x0400 + 111;
    private const uint TdmSetProgressBarRange = 0x0400 + 105;
    private const uint TdmSetProgressBarPosition = 0x0400 + 106;
    private const int TdeContent = 0;
    private const int WmClose = 0x0010;
    private const int SFalse = 1;
    private const int ButtonInstall = 1001;
    private const int ButtonCancel = 1002;
    private const int ButtonOpen = 1003;
    private const int ButtonClose = 1004;
    private const int ButtonCopyDetails = 1005;
    private const int ButtonReopen = 1006;
    private const long ProgressMaximum = 1000;

    private readonly TaskDialogCallback _callback;
    private readonly List<NativePage> _pages = [];
    private readonly ConcurrentQueue<Action> _pendingUiActions = new();
    private SetupConfirmation? _confirmation;
    private Func<CancellationToken, SetupOutcome>? _work;
    private Action<SetupOutcome>? _recordOutcome;
    private Func<bool>? _canReopenAfterCancel;
    private CancellationTokenSource? _cancellation;
    private Task? _worker;
    private nint _dialog;
    private volatile DialogPage _page;
    private SetupOutcome? _outcome;
    private volatile bool _confirmed;
    private volatile bool _canCancel;
    private volatile bool _allowClose;
    private bool _navigationCompleted;
    private bool _openRequested;
    private bool _reopenRequested;

    internal SetupWindow() => _callback = OnTaskDialogNotification;

    internal bool OpenRequested => _openRequested;
    internal bool ReopenRequested => _reopenRequested;
    internal SetupOutcome Run(
        SetupConfirmation confirmation,
        Func<CancellationToken, SetupOutcome> work,
        Action<SetupOutcome> recordOutcome,
        Func<bool> canReopenAfterCancel)
    {
        _confirmation = confirmation;
        _work = work;
        _recordOutcome = recordOutcome;
        _canReopenAfterCancel = canReopenAfterCancel;
        _cancellation = new CancellationTokenSource();
        _pages.Add(BuildConfirmationPage(confirmation));
        _pages.Add(BuildProgressPage());
        _page = DialogPage.Confirmation;
        Show(_pages[0]);
        _worker?.GetAwaiter().GetResult();
        return _outcome ?? SetupOutcome.Cancelled(
            confirmation.FromVersion,
            confirmation.ToVersion,
            confirmation.IsFreshInstall,
            canReopen: false);
    }

    internal static bool ShowResult(SetupOutcome outcome)
    {
        using var window = new SetupWindow();
        window._outcome = outcome;
        window._pages.Add(window.BuildResultPage(outcome));
        window._page = DialogPage.Result;
        window.Show(window._pages[0]);
        return window._reopenRequested;
    }

    public bool Confirm(SetupConfirmation confirmation)
        => _confirmed && ReferenceEquals(confirmation, _confirmation);


    public void Step(string text, bool cancellable)
    {
        _canCancel = cancellable;
        EnqueueUi(() =>
        {
            if (_page != DialogPage.Progress)
            {
                return;
            }
            _canCancel = cancellable;
            SendText(text);
            var determinateText = text.StartsWith("Installing files (", StringComparison.Ordinal)
                || text.StartsWith("Unpacking Nativune", StringComparison.Ordinal)
                || (text.StartsWith("Downloading prerequisite ", StringComparison.Ordinal)
                    && !text.EndsWith(" downloaded", StringComparison.Ordinal));
            if (!determinateText)
            {
                SetMarquee(true);
            }
            if (_dialog != nint.Zero)
            {
                SendMessage(_dialog, TdmEnableButton, ButtonCancel, cancellable ? 1 : 0);
            }
        });
    }

    public void Progress(long done, long total)
    {
        EnqueueUi(() =>
        {
            if (total <= 0)
            {
                SetMarquee(true);
                return;
            }
            var boundedDone = Math.Clamp(done, 0, total);
            var position = (int)Math.Clamp((double)boundedDone / total * ProgressMaximum, 0, ProgressMaximum);
            SetMarquee(false);
            SendMessage(_dialog, TdmSetProgressBarRange, 0, (nint)(ProgressMaximum << 16));
            SendMessage(_dialog, TdmSetProgressBarPosition, position, 0);
        });
    }

    public void Result(SetupOutcome outcome)
    {
        _outcome = outcome;
        EnqueueUi(() => CompleteResult(outcome));
    }

    private void EnqueueUi(Action action) => _pendingUiActions.Enqueue(action);

    private void DrainPendingUiActions(nint hwnd)
    {
        while (_pendingUiActions.TryDequeue(out var action))
        {
            try
            {
                action();
            }
            catch (Exception error)
            {
                FailAndClose(hwnd, error);
                return;
            }
        }
    }

    private void CompleteResult(SetupOutcome outcome)
    {
        if (_dialog == nint.Zero)
        {
            return;
        }
        try
        {
            if (outcome.Succeeded && !outcome.IsFreshInstall)
            {
                _allowClose = true;
                if (!PostMessage(_dialog, WmClose, 0, 0))
                {
                    FailAndClose(_dialog, new InvalidOperationException("The Setup dialog could not be closed."));
                }
                return;
            }
            Navigate(BuildResultPage(outcome), DialogPage.Result);
        }
        catch (Exception error)
        {
            FailAndClose(_dialog, error);
        }
    }

    private void FailAndClose(nint hwnd, Exception error)
    {
        var confirmation = _confirmation;
        if (confirmation is not null)
        {
            _outcome = SetupOutcome.Failed(
                new SetupException(ExitCode.IoFailure, "Nativune Setup could not display its result.", error),
                confirmation.FromVersion,
                confirmation.ToVersion,
                confirmation.IsFreshInstall,
                canReopen: false);
        }
        _allowClose = true;
        if (hwnd != nint.Zero)
        {
            _ = PostMessage(hwnd, WmClose, 0, 0);
        }
    }

    private NativePage BuildConfirmationPage(SetupConfirmation confirmation)
    {
        var target = $"v{confirmation.ToVersion}";
        var instruction = confirmation.IsFreshInstall
            ? $"Install Nativune {target}?"
            : $"Upgrade Nativune v{confirmation.FromVersion} to {target}?";
        var content = new StringBuilder();
        if (confirmation.IsFreshInstall)
        {
            var payloadMegabytes = confirmation.PayloadBytes / 1_000_000d;
            var payloadSize = payloadMegabytes < 100
                ? payloadMegabytes.ToString("0.0", CultureInfo.InvariantCulture)
                : payloadMegabytes.ToString("0", CultureInfo.InvariantCulture);
            content.Append("Location: ").Append(confirmation.InstallRoot).Append($" (about {payloadSize} MB on disk).")
                .Append("\n\nStart menu and desktop shortcuts will be added.");
        }
        else if (confirmation.IsUpdaterHandoff)
        {
            content.Append("Nativune will close, be upgraded in place and reopen. Your settings, sign-in and data folder are kept.");
        }
        else
        {
            content.Append("Your settings, sign-in and data folder are kept.");
        }

        if (confirmation.MissingPrerequisites.Count > 0)
        {
            content.Append("\n\nSetup will also download and install from Microsoft:");
            foreach (var item in confirmation.MissingPrerequisites)
            {
                content.Append("\n• ").Append(item.Definition.Name).Append(" (required ").Append(item.Definition.Version).Append(')');
            }
            content.Append("\n\nEach download will be checked against its Microsoft Authenticode signature. Prerequisites already installed will not be run again. Nativune will not be changed if you decline or a prerequisite download or installation fails.");
            var administrators = confirmation.MissingPrerequisites
                .Where(item => item.Definition.RequiresAdministrator)
                .Select(item => item.Definition.Name)
                .ToArray();
            if (administrators.Length > 0)
            {
                content.Append("\n\nWindows will ask for administrator permission to install ")
                    .Append(string.Join(" and ", administrators)).Append(" for all users.");
            }
        }
        content.Append("\n\nContinuing accepts the included third-party license terms.");
        return NativePage.Create(
            "Nativune Setup",
            instruction,
            content.ToString(),
            TdfAllowDialogCancellation,
            [(ButtonInstall, confirmation.IsFreshInstall ? "Install" : "Upgrade"), (ButtonCancel, "Cancel")],
            ButtonInstall,
            _callback);
    }

    private NativePage BuildProgressPage()
        => NativePage.Create(
            "Nativune Setup",
            "Installing Nativune",
            "Checking for required Microsoft components…",
            TdfAllowDialogCancellation | TdfShowMarqueeProgressBar | TdfCallbackTimer,
            [(ButtonCancel, "Cancel")],
            ButtonCancel,
            _callback);

    private NativePage BuildResultPage(SetupOutcome outcome)
    {
        var buttons = new List<(int Id, string Text)>();
        int defaultButton;
        if (outcome.Status == "installed")
        {
            if (outcome.CanOpen)
            {
                buttons.Add((ButtonOpen, "Open Nativune"));
                buttons.Add((ButtonClose, "Close"));
                defaultButton = ButtonOpen;
            }
            else
            {
                buttons.Add((ButtonClose, "Close"));
                defaultButton = ButtonClose;
            }
        }
        else if (outcome.Status == "failed")
        {
            buttons.Add((ButtonCopyDetails, "Copy details"));
            buttons.Add((ButtonClose, "Close"));
            if (outcome.CanReopen)
            {
                buttons.Add((ButtonReopen, "Reopen Nativune"));
            }
            defaultButton = outcome.CanReopen ? ButtonReopen : ButtonClose;
        }
        else
        {
            buttons.Add((ButtonClose, "Close"));
            defaultButton = ButtonClose;
        }

        var content = outcome.Content;
        if (outcome.Status == "cancelled" && outcome.CanReopen)
        {
            content += $"\n\nReopening Nativune v{outcome.FromVersion}.";
        }
        if (outcome.Status == "failed")
        {
            content += "\n\nSelect Copy details to copy the exit code and full error text.";
        }
        return NativePage.Create(
            "Nativune Setup",
            outcome.MainInstruction,
            content,
            TdfAllowDialogCancellation,
            buttons,
            defaultButton,
            _callback);
    }

    // A managed exception must never unwind through comctl32's native frames: that leaves an orphaned,
    // unresponsive dialog and a Windows "Unknown Hard Error" popup. Fail the operation and close instead.
    private int OnTaskDialogNotification(nint hwnd, uint notification, nint wParam, nint lParam, nint data)
    {
        try
        {
            return HandleNotification(hwnd, notification, wParam);
        }
        catch (Exception error)
        {
            try
            {
                FailAndClose(hwnd, error);
            }
            catch
            {
                // Nothing else can be done inside a native callback.
            }
            return 0;
        }
    }

    private int HandleNotification(nint hwnd, uint notification, nint wParam)
    {
        if (notification == TdnDestroyed)
        {
            _dialog = nint.Zero;
            return 0;
        }
        _dialog = hwnd;
        if (notification == TdnNavigated)
        {
            _navigationCompleted = true;
        }
        if (notification is TdnCreated or TdnNavigated)
        {
            if (_page == DialogPage.Progress)
            {
                SetMarquee(true);
                SendMessage(hwnd, TdmEnableButton, ButtonCancel, _canCancel ? 1 : 0);
            }
            return 0;
        }
        if (notification == TdnTimer)
        {
            DrainPendingUiActions(hwnd);
            return 0;
        }
        if (notification != TdnButtonClicked)
        {
            return 0;
        }

        var button = unchecked((int)wParam);
        if (_allowClose && button == 2)
        {
            // WM_CLOSE posted by CompleteResult/FailAndClose: close on any page, keeping the recorded outcome.
            return 0;
        }
        if (_page == DialogPage.Confirmation)
        {
            if (button == ButtonInstall)
            {
                var confirmation = _confirmation!;
                _confirmed = true;
                if (!Confirm(confirmation))
                {
                    return SFalse;
                }
                _canCancel = true;
                try
                {
                    Navigate(_pages[1], DialogPage.Progress);
                    StartWorker();
                }
                catch (Exception error)
                {
                    FailAndClose(hwnd, error);
                }
                return SFalse;
            }
            if (button == ButtonCancel || button == 2)
            {
                var confirmation = _confirmation!;
                if (confirmation.IsUpdaterHandoff)
                {
                    _canCancel = false;
                    try
                    {
                        Navigate(_pages[1], DialogPage.Progress);
                        EnqueueUi(() => SendText("Waiting for Nativune to close before reopening…"));
                        StartOutcomeWorker(() =>
                        {
                            var canReopen = _canReopenAfterCancel?.Invoke() == true;
                            var outcome = SetupOutcome.Cancelled(
                                confirmation.FromVersion,
                                confirmation.ToVersion,
                                confirmation.IsFreshInstall,
                                canReopen);
                            _recordOutcome?.Invoke(outcome);
                            return outcome;
                        });
                    }
                    catch (Exception error)
                    {
                        FailAndClose(hwnd, error);
                    }
                    return SFalse;
                }
                var cancelled = SetupOutcome.Cancelled(
                    confirmation.FromVersion,
                    confirmation.ToVersion,
                    confirmation.IsFreshInstall,
                    canReopen: false);
                _outcome = cancelled;
                _recordOutcome?.Invoke(cancelled);
                try
                {
                    Navigate(BuildResultPage(cancelled), DialogPage.Result);
                }
                catch (Exception error)
                {
                    FailAndClose(hwnd, error);
                }
                return SFalse;
            }
        }
        else if (_page == DialogPage.Progress)
        {
            if (button == ButtonCancel || button == 2)
            {
                if (_allowClose)
                {
                    return 0;
                }
                if (_canCancel)
                {
                    _canCancel = false;
                    _cancellation?.Cancel();
                    SendMessage(hwnd, TdmEnableButton, ButtonCancel, 0);
                    SendText("Cancelling and removing temporary files…");
                }
                return SFalse;
            }
        }
        else
        {
            if (button == ButtonOpen)
            {
                _openRequested = true;
            }
            else if (button == ButtonReopen)
            {
                _reopenRequested = true;
            }
            else if (button == ButtonCopyDetails && _outcome is not null)
            {
                var copied = ClipboardText.TrySet(_outcome.Details, hwnd);
                var feedback = copied ? "Details copied to the clipboard." : "Details could not be copied to the clipboard.";
                UpdateContent($"{_outcome.Content}\n\n{feedback}");
                return SFalse;
            }
        }
        return 0;
    }

    private void StartWorker()
        => StartOutcomeWorker(() => _work!(_cancellation!.Token));

    private void StartOutcomeWorker(Func<SetupOutcome> work)
    {
        var confirmation = _confirmation!;
        _worker = Task.Run(() =>
        {
            SetupOutcome outcome;
            var unexpectedFailure = false;
            try
            {
                outcome = work();
            }
            catch (Exception error)
            {
                unexpectedFailure = true;
                var canReopen = false;
                if (confirmation.IsUpdaterHandoff)
                {
                    try
                    {
                        canReopen = _canReopenAfterCancel?.Invoke() == true;
                    }
                    catch
                    {
                        // A failed safety check means no relaunch.
                    }
                }
                outcome = SetupOutcome.Failed(
                    new SetupException(ExitCode.IoFailure, "Nativune Setup failed.", error),
                    confirmation.FromVersion,
                    confirmation.ToVersion,
                    confirmation.IsFreshInstall,
                    canReopen);
            }
            if (unexpectedFailure)
            {
                try
                {
                    _recordOutcome?.Invoke(outcome);
                }
                catch
                {
                    // Outcome recording is best effort.
                }
            }
            try
            {
                Result(outcome);
            }
            catch (Exception error)
            {
                FailAndClose(_dialog, error);
            }
        });
    }

    private void Show(NativePage page)
    {
        var result = TaskDialogIndirect(page.Pointer, out _, out _, out _);
        if (result < 0)
        {
            throw new SetupException(ExitCode.IoFailure, "The Nativune Setup window could not be displayed.", Marshal.GetExceptionForHR(result) ?? new InvalidOperationException());
        }
    }

    private void Navigate(NativePage page, DialogPage target)
    {
        if (!_pages.Contains(page))
        {
            _pages.Add(page);
        }
        _page = target;
        _navigationCompleted = false;
        if (_dialog == nint.Zero)
        {
            throw new InvalidOperationException("The Setup dialog is no longer available.");
        }
        _ = SendMessage(_dialog, TdmNavigatePage, 0, page.Pointer);
        if (!_navigationCompleted)
        {
            throw new InvalidOperationException("The Setup dialog did not complete its page navigation.");
        }
    }

    private void SendText(string text)
    {
        if (_dialog == nint.Zero || _page != DialogPage.Progress)
        {
            return;
        }
        var textPointer = Marshal.StringToHGlobalUni(text);
        try
        {
            _ = SendMessage(_dialog, TdmUpdateElementText, TdeContent, textPointer);
        }
        finally
        {
            Marshal.FreeHGlobal(textPointer);
        }
    }

    private void UpdateContent(string text)
    {
        if (_dialog == nint.Zero)
        {
            return;
        }
        var textPointer = Marshal.StringToHGlobalUni(text);
        try
        {
            _ = SendMessage(_dialog, TdmUpdateElementText, TdeContent, textPointer);
        }
        finally
        {
            Marshal.FreeHGlobal(textPointer);
        }
    }

    private void SetMarquee(bool enabled)
    {
        if (_dialog != nint.Zero)
        {
            SendMessage(_dialog, TdmSetMarqueeProgressBar, enabled ? 1 : 0, 0);
            SendMessage(_dialog, TdmSetProgressBarMarquee, enabled ? 1 : 0, 0);
        }
    }


    private static nint SendMessage(nint hwnd, uint message, nint wParam, nint lParam)
        => SendMessageW(hwnd, message, wParam, lParam);

    public void Dispose()
    {
        _cancellation?.Dispose();
        foreach (var page in _pages)
        {
            page.Dispose();
        }
        _pages.Clear();
        GC.KeepAlive(_callback);
    }

    private enum DialogPage
    {
        Confirmation,
        Progress,
        Result,
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int TaskDialogCallback(nint hwnd, uint notification, nint wParam, nint lParam, nint data);

    [DllImport("comctl32.dll", ExactSpelling = true, PreserveSig = true)]
    private static extern int TaskDialogIndirect(nint config, out int button, out int radioButton, [MarshalAs(UnmanagedType.Bool)] out bool verificationFlagChecked);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern nint SendMessageW(nint hwnd, uint message, nint wParam, nint lParam);

    [DllImport("user32.dll", EntryPoint = "PostMessageW", ExactSpelling = true, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostMessage(nint hwnd, int message, nint wParam, nint lParam);

    [StructLayout(LayoutKind.Sequential, Pack = 1)] // commctrl.h declares TASKDIALOGCONFIG under pshpack1.h
    private struct TaskDialogConfig
    {
        internal uint Size;
        internal nint Parent;
        internal nint Instance;
        internal uint Flags;
        internal uint CommonButtons;
        internal nint WindowTitle;
        internal nint MainIcon;
        internal nint MainInstruction;
        internal nint Content;
        internal uint ButtonCount;
        internal nint Buttons;
        internal int DefaultButton;
        internal uint RadioButtonCount;
        internal nint RadioButtons;
        internal int DefaultRadioButton;
        internal nint VerificationText;
        internal nint ExpandedInformation;
        internal nint ExpandedControlText;
        internal nint CollapsedControlText;
        internal nint FooterIcon;
        internal nint Footer;
        internal nint Callback;
        internal nint CallbackData;
        internal uint Width;
    }

    [StructLayout(LayoutKind.Sequential, Pack = 1)]
    private struct TaskDialogButton
    {
        internal int Id;
        internal nint Text;
    }

    private sealed class NativePage : IDisposable
    {
        private readonly List<nint> _strings = [];
        private nint _buttons;
        private nint _config;

        private NativePage() { }

        internal nint Pointer => _config;

        internal static NativePage Create(
            string title,
            string instruction,
            string content,
            uint flags,
            IReadOnlyList<(int Id, string Text)> buttons,
            int defaultButton,
            TaskDialogCallback callback)
        {
            var page = new NativePage();
            try
            {
                var titlePointer = page.AllocateString(title);
                var instructionPointer = page.AllocateString(instruction);
                var contentPointer = page.AllocateString(content);
                var buttonSize = Marshal.SizeOf<TaskDialogButton>();
                page._buttons = Marshal.AllocHGlobal(checked(buttonSize * buttons.Count));
                for (var index = 0; index < buttons.Count; index++)
                {
                    var button = new TaskDialogButton
                    {
                        Id = buttons[index].Id,
                        Text = page.AllocateString(buttons[index].Text),
                    };
                    Marshal.StructureToPtr(button, IntPtr.Add(page._buttons, checked(index * buttonSize)), fDeleteOld: false);
                }
                var config = new TaskDialogConfig
                {
                    Size = (uint)Marshal.SizeOf<TaskDialogConfig>(),
                    Flags = flags,
                    WindowTitle = titlePointer,
                    MainInstruction = instructionPointer,
                    Content = contentPointer,
                    ButtonCount = (uint)buttons.Count,
                    Buttons = page._buttons,
                    DefaultButton = defaultButton,
                    Callback = Marshal.GetFunctionPointerForDelegate(callback),
                    Width = 0,
                };
                page._config = Marshal.AllocHGlobal(Marshal.SizeOf<TaskDialogConfig>());
                Marshal.StructureToPtr(config, page._config, fDeleteOld: false);
                return page;
            }
            catch
            {
                page.Dispose();
                throw;
            }
        }

        private nint AllocateString(string value)
        {
            var pointer = Marshal.StringToHGlobalUni(value);
            _strings.Add(pointer);
            return pointer;
        }

        public void Dispose()
        {
            if (_config != nint.Zero)
            {
                Marshal.FreeHGlobal(_config);
                _config = nint.Zero;
            }
            if (_buttons != nint.Zero)
            {
                Marshal.FreeHGlobal(_buttons);
                _buttons = nint.Zero;
            }
            foreach (var pointer in _strings)
            {
                Marshal.FreeHGlobal(pointer);
            }
            _strings.Clear();
        }
    }
}

internal static class ClipboardText
{
    private const uint GmemMoveable = 0x0002;
    private const uint CfUnicodeText = 13;

    internal static bool TrySet(string text, nint owner)
    {
        if (!OpenClipboard(owner))
        {
            return false;
        }
        nint memory = nint.Zero;
        try
        {
            var bytes = Encoding.Unicode.GetBytes(text + '\0');
            memory = GlobalAlloc(GmemMoveable, (nuint)bytes.Length);
            if (memory == nint.Zero)
            {
                return false;
            }
            var pointer = GlobalLock(memory);
            if (pointer == nint.Zero)
            {
                return false;
            }
            try
            {
                Marshal.Copy(bytes, 0, pointer, bytes.Length);
            }
            finally
            {
                _ = GlobalUnlock(memory);
            }
            if (!EmptyClipboard() || SetClipboardData(CfUnicodeText, memory) == nint.Zero)
            {
                return false;
            }
            memory = nint.Zero;
            return true;
        }
        catch
        {
            // Copying details is best-effort and never changes the Setup result.
            return false;
        }
        finally
        {
            if (memory != nint.Zero)
            {
                _ = GlobalFree(memory);
            }
            _ = CloseClipboard();
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool OpenClipboard(nint owner);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CloseClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool EmptyClipboard();

    [DllImport("user32.dll", SetLastError = true)]
    private static extern nint SetClipboardData(uint format, nint memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint GlobalAlloc(uint flags, nuint bytes);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint GlobalLock(nint memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GlobalUnlock(nint memory);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern nint GlobalFree(nint memory);
}
