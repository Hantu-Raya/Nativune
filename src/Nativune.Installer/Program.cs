using System.Diagnostics;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Nativune.Installer;

internal static class Program
{
    internal const string ProductName = "Nativune";
    internal const string SetupFileName = "Nativune.Setup.exe";
    internal const string ManifestFileName = "release-manifest.json";
    internal const string AppExecutable = "app/Nativune.exe";
    internal const string DefaultInstallDirectoryName = "Nativune";

    private static readonly string HelpText = $"""
        Nativune Setup

        Usage:
          {SetupFileName} [--install-dir <absolute-path>] [--silent [--install-prerequisites]] [--no-launch]  (install or upgrade)
          {SetupFileName} --update --wait-pid <positive-pid> [--install-dir <absolute-path>] [--silent] [--no-launch]
          {SetupFileName} --update --wait-pid <pid> --expected-version <version> --delta-dir <install-dir>\updates\delta --expected-manifest-sha256 <sha256> [...]
          {SetupFileName} --uninstall [--install-dir <absolute-path>] [--silent]
          {SetupFileName} --help

        Options:
          --install-dir <path>  Absolute root under %LOCALAPPDATA%. Default: %LOCALAPPDATA%\{DefaultInstallDirectoryName}.
          --silent              Suppress dialogs; accepts third-party terms but never installs missing prerequisites unless --install-prerequisites is given.
          --install-prerequisites  With --silent: download and install missing prerequisites from their official sources without asking; package managers pass this as consent.
          --no-launch           Do not launch the installed application.
          --update              Updater handoff; replace the managed installation after --wait-pid exits.
          --wait-pid <pid>      Positive process id; wait up to 60 seconds before replacement/removal.
          --expected-version <v> With --update; the release version selected by the updater.
          --delta-dir <path>    With --update; apply downloaded changed files from <install-dir>\updates\delta.
          --expected-manifest-sha256 <hex>  Required with --delta-dir; SHA-256 of the delta release manifest.
          --uninstall           Remove manifest-owned files and shell registration, preserving data/.

        Exit codes:
          0 success; 2 usage; 3 cancelled; 10 invalid payload; 11 unsafe install root;
          12 target conflict; 13 wait timeout; 14 shell/ACL failure; 15 I/O failure;
          16 rollback failure; 17 launch failure; 18 unsupported platform; 19 prerequisite failure.

        Continuing an interactive install or update accepts the included third-party license terms.
        Missing prerequisites are downloaded and installed only after explicit interactive consent, or with --silent --install-prerequisites.
        --silent without --install-prerequisites fails closed with official links when a required prerequisite is missing. Nativune adds no application EULA.
        """;

    [STAThread]
    private static int Main(string[] args)
    {
        var silentRequested = args.Contains("--silent", StringComparer.Ordinal);
        var updateRequested = args.Contains("--update", StringComparer.Ordinal);
        SetupOptions? options = null;
        string? root = null;
        InstallerEngine? engine = null;
        try
        {
            options = SetupOptions.Parse(args);
            if (options.Help)
            {
                UserInterface.ShowHelp(HelpText);
                return (int)ExitCode.Success;
            }

            if (!OperatingSystem.IsWindows())
            {
                throw new SetupException(ExitCode.UnsupportedPlatform, "Nativune Setup runs on Windows only.");
            }

            root = InstallRoot.Resolve(options.InstallDirectory, options.TestNoShell);
            var installEngine = new InstallerEngine(root, options);
            engine = installEngine;
            if (options.Uninstall)
            {
                return (int)installEngine.Uninstall();
            }
            return RunInstallFlow(installEngine, root, options);
        }
        catch (SetupException error)
        {
            var silent = options?.Silent == true || silentRequested;
            var rootValidated = engine?.RootValidated == true && error.Code != ExitCode.UnsafeRoot;
            if (root is not null && options is { Uninstall: false } && rootValidated)
            {
                var fromVersion = InstallerEngine.TryGetInstalledVersion(root);
                var canReopen = CanReopenCurrent(options, root, fromVersion, error.Code);
                var outcome = error.Code == ExitCode.Cancelled
                    ? SetupOutcome.Cancelled(fromVersion, engine?.PayloadVersion ?? SetupVersion(), fromVersion is null, canReopen, error.Message)
                    : SetupOutcome.Failed(error, fromVersion, engine?.PayloadVersion ?? SetupVersion(), fresh: fromVersion is null, canReopen: canReopen);
                if (error.Code != ExitCode.LaunchFailure)
                {
                    UpdateOutcomeWriter.TryWrite(root, outcome);
                }
                var reopenRequested = ShowOutcome(outcome, silent);
                if (canReopen && (silent || outcome.Status == "cancelled" || reopenRequested))
                {
                    TryReopen(root, silent);
                }
            }
            else if (options?.Uninstall != true && OperatingSystem.IsWindows())
            {
                ShowOutcome(CreateEarlyFailure(error, options?.Update == true || updateRequested), silent);
            }
            else
            {
                UserInterface.ShowError(error.Message, silent);
            }
            return (int)error.Code;
        }
        catch (Exception error)
        {
            var silent = options?.Silent == true || silentRequested;
            var rootValidated = engine?.RootValidated == true;
            if (root is not null && options is { Uninstall: false } && rootValidated)
            {
                var setupError = new SetupException(ExitCode.IoFailure, "Nativune Setup failed.", error);
                var fromVersion = InstallerEngine.TryGetInstalledVersion(root);
                var canReopen = CanReopenCurrent(options, root, fromVersion, setupError.Code);
                var outcome = SetupOutcome.Failed(setupError, fromVersion, engine?.PayloadVersion ?? SetupVersion(), fresh: fromVersion is null, canReopen: canReopen);
                UpdateOutcomeWriter.TryWrite(root, outcome);
                var reopenRequested = ShowOutcome(outcome, silent);
                if (canReopen && (silent || reopenRequested))
                {
                    TryReopen(root, silent);
                }
            }
            else if (options?.Uninstall != true && OperatingSystem.IsWindows())
            {
                var setupError = new SetupException(ExitCode.IoFailure, "Nativune Setup failed.", error);
                ShowOutcome(CreateEarlyFailure(setupError, options?.Update == true || updateRequested), silent);
            }
            else
            {
                UserInterface.ShowError($"Nativune Setup failed: {error.Message}", silent);
            }
            return (int)ExitCode.IoFailure;
        }
    }

    private static int RunInstallFlow(InstallerEngine engine, string root, SetupOptions options)
    {
        ISetupReporter reporter;
        if (options.Silent)
        {
            reporter = ConsoleSetupReporter.Instance;
            reporter.Step("Checking for required Microsoft components…", cancellable: true);
        }
        else
        {
            reporter = new SetupWindow();
        }

        using var preparation = engine.PrepareInstall();
        SetupOutcome outcome;
        var reopenRequested = false;
        if (options.Silent)
        {
            _ = reporter.Confirm(preparation.Confirmation);
            outcome = Task.Run(() => engine.Execute(preparation, reporter, CancellationToken.None)).GetAwaiter().GetResult();
            reporter.Result(outcome);
        }
        else
        {
            var setupWindow = (SetupWindow)reporter;
            using (setupWindow)
            {
                outcome = setupWindow.Run(
                    preparation.Confirmation,
                    cancellationToken => engine.Execute(preparation, setupWindow, cancellationToken),
                    result => UpdateOutcomeWriter.TryWrite(root, result),
                    () => CanReopenCurrent(options, root, preparation.Confirmation.FromVersion, ExitCode.Cancelled));
                reopenRequested = setupWindow.ReopenRequested;
                if (outcome.Status == "installed" && setupWindow.OpenRequested)
                {
                    Launcher.Start(root);
                }
            }
        }

        if (!outcome.Succeeded && options.Silent)
        {
            Console.Error.WriteLine(outcome.Error?.Message ?? outcome.MainInstruction);
        }
        if (options.Update && outcome.CanReopen
            && (options.Silent || outcome.Status == "cancelled" || reopenRequested)
            && CanReopenCurrent(options, root, outcome.FromVersion, outcome.ExitCode))
        {
            TryReopen(root, options.Silent);
        }
        return (int)outcome.ExitCode;
    }

    private static bool ShowOutcome(SetupOutcome outcome, bool silent)
    {
        if (silent)
        {
            if (!outcome.Succeeded)
            {
                Console.Error.WriteLine(outcome.Error?.Message ?? outcome.MainInstruction);
            }
            return false;
        }
        try
        {
            return SetupWindow.ShowResult(outcome);
        }
        catch
        {
            UserInterface.ShowError(outcome.Error?.Message ?? outcome.MainInstruction, silent: false);
            return false;
        }
    }

    private static SetupOutcome CreateEarlyFailure(SetupException error, bool updateMode)
    {
        var displayError = updateMode
            ? new SetupException(
                error.Code,
                $"{error.Message}\n\nThe existing Nativune version was left untouched. Setup did not reopen it because it could not confirm that the install location was safe.",
                error.InnerException ?? error)
            : error;
        return error.Code == ExitCode.Cancelled
            ? SetupOutcome.Cancelled(null, SetupVersion(), fresh: true, canReopen: false, message: displayError.Message)
            : SetupOutcome.Failed(displayError, null, SetupVersion(), fresh: true, canReopen: false);
    }


    private static bool CanReopenCurrent(SetupOptions options, string root, string? fromVersion, ExitCode code)
    {
        if (!options.Update
            || options.NoLaunch
            || fromVersion is null
            || code is ExitCode.WaitTimeout or ExitCode.RollbackFailure or ExitCode.UnsafeRoot)
        {
            return false;
        }
        try
        {
            if (options.WaitPid is int waitPid)
            {
                ProcessWaiter.WaitForExit(waitPid, TimeSpan.FromSeconds(60));
            }
            return InstallerEngine.IsInstalledManifestIntact(root, fromVersion, options.TestNoShell);
        }
        catch
        {
            return false;
        }
    }

    private static void TryReopen(string root, bool silent)
    {
        try
        {
            Launcher.Start(root);
        }
        catch (Exception error)
        {
            if (silent)
            {
                Console.Error.WriteLine($"Nativune could not be reopened: {error.Message}");
            }
        }
    }

    internal static string SetupVersion()
    {
        var version = typeof(Program).Assembly.GetName().Version;
        return version is null ? "0.0.0" : $"{version.Major}.{Math.Max(0, version.Minor)}.{Math.Max(0, version.Build)}";
    }
}

internal enum ExitCode
{
    Success = 0,
    Usage = 2,
    Cancelled = 3,
    InvalidPayload = 10,
    UnsafeRoot = 11,
    TargetConflict = 12,
    WaitTimeout = 13,
    ShellFailure = 14,
    IoFailure = 15,
    RollbackFailure = 16,
    LaunchFailure = 17,
    UnsupportedPlatform = 18,
    PrerequisiteFailure = 19,
}

internal sealed class SetupException : Exception
{
    internal SetupException(ExitCode code, string message) : base(message) => Code = code;
    internal SetupException(ExitCode code, string message, Exception inner) : base(message, inner) => Code = code;
    internal ExitCode Code { get; }
}

internal sealed record SetupOptions(
    bool Help,
    bool Silent,
    bool NoLaunch,
    bool TestNoShell,
    bool Update,
    bool Uninstall,
    string? InstallDirectory,
    string? ExpectedVersion,
    string? DeltaDirectory,
    string? ExpectedManifestSha256,
    int? WaitPid,
    PrerequisiteTestScenario TestPrerequisiteScenario,
    bool InstallPrerequisites = false)
{
    internal static SetupOptions Parse(string[] args)
    {
        var help = false;
        var silent = false;
        var noLaunch = false;
        var testNoShell = false;
        var update = false;
        var uninstall = false;
        string? installDirectory = null;
        int? waitPid = null;
        var testPrerequisiteScenario = PrerequisiteTestScenario.None;
        string? expectedVersion = null;
        string? deltaDirectory = null;
        string? expectedManifestSha256 = null;
        var installPrerequisites = false;

        for (var index = 0; index < args.Length; index++)
        {
            var argument = args[index];
            switch (argument)
            {
                case "--help":
                case "-h":
                    help = true;
                    break;
                case "--silent":
                    silent = true;
                    break;
                case "--install-prerequisites":
                    installPrerequisites = true;
                    break;
                case "--no-launch":
                    noLaunch = true;
                    break;
#if INSTALLER_TEST_HOOKS
                case "--test-no-shell":
                    testNoShell = true;
                    break;
                case "--test-prerequisites":
                    if (++index >= args.Length || testPrerequisiteScenario != PrerequisiteTestScenario.None)
                    {
                        throw new SetupException(ExitCode.Usage, "--test-prerequisites requires one scenario and may be specified only once.");
                    }
                    testPrerequisiteScenario = args[index] switch
                    {
                        "present" => PrerequisiteTestScenario.Present,
                        "missing" => PrerequisiteTestScenario.Missing,
                        "declined" => PrerequisiteTestScenario.Declined,
                        "offline" => PrerequisiteTestScenario.Offline,
                        "webview2-outdated" => PrerequisiteTestScenario.WebView2Outdated,
                        "webview2-at-floor" => PrerequisiteTestScenario.WebView2AtFloor,
                        "download-check" => PrerequisiteTestScenario.DownloadCheck,
                        _ => throw new SetupException(ExitCode.Usage, "--test-prerequisites requires present, missing, declined, offline, webview2-outdated, webview2-at-floor, or download-check."),
                    };
                    break;
#endif
                case "--update":
                    update = true;
                    break;
                case "--uninstall":
                    uninstall = true;
                    break;
                case "--install-dir":
                    if (++index >= args.Length || string.IsNullOrWhiteSpace(args[index]))
                    {
                        throw new SetupException(ExitCode.Usage, "--install-dir requires an absolute path.");
                    }
                    if (installDirectory is not null)
                    {
                        throw new SetupException(ExitCode.Usage, "--install-dir may be specified only once.");
                    }
                    installDirectory = args[index];
                    break;
                case "--expected-version":
                    if (++index >= args.Length || !Manifest.IsValidVersionText(args[index]))
                    {
                        throw new SetupException(ExitCode.Usage, "--expected-version requires semantic version text.");
                    }
                    if (expectedVersion is not null)
                    {
                        throw new SetupException(ExitCode.Usage, "--expected-version may be specified only once.");
                    }
                    expectedVersion = args[index];
                    break;
                case "--delta-dir":
                    if (++index >= args.Length || string.IsNullOrWhiteSpace(args[index]) || !Path.IsPathFullyQualified(args[index]))
                    {
                        throw new SetupException(ExitCode.Usage, "--delta-dir requires an absolute path.");
                    }
                    if (deltaDirectory is not null)
                    {
                        throw new SetupException(ExitCode.Usage, "--delta-dir may be specified only once.");
                    }
                    deltaDirectory = args[index];
                    break;
                case "--expected-manifest-sha256":
                    if (++index >= args.Length || args[index].Length != 64 || !args[index].All(Uri.IsHexDigit))
                    {
                        throw new SetupException(ExitCode.Usage, "--expected-manifest-sha256 requires 64 hexadecimal characters.");
                    }
                    if (expectedManifestSha256 is not null)
                    {
                        throw new SetupException(ExitCode.Usage, "--expected-manifest-sha256 may be specified only once.");
                    }
                    expectedManifestSha256 = args[index];
                    break;
                case "--wait-pid":
                    if (++index >= args.Length || !int.TryParse(args[index], out var parsedPid) || parsedPid <= 0)
                    {
                        throw new SetupException(ExitCode.Usage, "--wait-pid requires a positive process id.");
                    }
                    if (waitPid is not null)
                    {
                        throw new SetupException(ExitCode.Usage, "--wait-pid may be specified only once.");
                    }
                    waitPid = parsedPid;
                    break;
                default:
                    throw new SetupException(ExitCode.Usage, $"Unknown option: {argument}\nUse --help for usage.");
            }
        }

        if (help && (update || uninstall || installDirectory is not null || expectedVersion is not null || deltaDirectory is not null || expectedManifestSha256 is not null || waitPid is not null || noLaunch || installPrerequisites || testNoShell || testPrerequisiteScenario != PrerequisiteTestScenario.None))
        {
            throw new SetupException(ExitCode.Usage, "--help cannot be combined with an operation.");
        }
        if (update && uninstall)
        {
            throw new SetupException(ExitCode.Usage, "--update and --uninstall are mutually exclusive.");
        }
        if (uninstall && noLaunch)
        {
            throw new SetupException(ExitCode.Usage, "--no-launch is not valid with --uninstall.");
        }
        if (uninstall && installPrerequisites)
        {
            throw new SetupException(ExitCode.Usage, "--install-prerequisites is not valid with --uninstall.");
        }
        if (installPrerequisites && !silent)
        {
            throw new SetupException(ExitCode.Usage, "--install-prerequisites is valid only with --silent.");
        }
        if (!update && waitPid is not null && !uninstall)
        {
            throw new SetupException(ExitCode.Usage, "--wait-pid is valid only with --update or --uninstall.");
        }
        if (update && waitPid is null)
        {
            throw new SetupException(ExitCode.Usage, "--update requires --wait-pid.");
        }
        if (expectedVersion is not null && !update)
        {
            throw new SetupException(ExitCode.Usage, "--expected-version is valid only with --update.");
        }
        if (deltaDirectory is not null && (!update || expectedVersion is null || expectedManifestSha256 is null))
        {
            throw new SetupException(ExitCode.Usage, "--delta-dir is valid only with --update and requires --expected-version and --expected-manifest-sha256.");
        }
        if (expectedManifestSha256 is not null && deltaDirectory is null)
        {
            throw new SetupException(ExitCode.Usage, "--expected-manifest-sha256 is valid only with --delta-dir.");
        }
#if INSTALLER_TEST_HOOKS
        // Test-hook builds may run the interactive window with --test-no-shell so the Setup UI can be
        // exercised without touching the real Start menu, desktop or uninstall registration.
        if (testPrerequisiteScenario != PrerequisiteTestScenario.None && !testNoShell)
        {
            throw new SetupException(ExitCode.Usage, "--test-prerequisites requires --test-no-shell.");
        }
#endif
        return new SetupOptions(help, silent, noLaunch, testNoShell, update, uninstall, installDirectory, expectedVersion, deltaDirectory, expectedManifestSha256, waitPid, testPrerequisiteScenario, installPrerequisites);
    }
}

internal static class UserInterface
{
    private const uint MessageBoxOk = 0x00000000;
    private const uint MessageBoxYesNo = 0x00000004;
    private const uint MessageBoxIconInformation = 0x00000040;
    private const uint MessageBoxIconError = 0x00000010;
    private const int MessageBoxYes = 6;

    internal static void ShowHelp(string text)
    {
        Console.WriteLine(text);
        _ = MessageBoxW(nint.Zero, text, $"{Program.ProductName} Setup", MessageBoxOk | MessageBoxIconInformation);
    }


    internal static void ShowError(string text, bool silent)
    {
        Console.Error.WriteLine(text);
        if (!silent && OperatingSystem.IsWindows())
        {
            _ = MessageBoxW(nint.Zero, text, $"{Program.ProductName} Setup", MessageBoxOk | MessageBoxIconError);
        }
    }

    internal static bool Confirm(string text)
    {
        return MessageBoxW(nint.Zero, text, $"{Program.ProductName} Setup", MessageBoxYesNo | MessageBoxIconInformation) == MessageBoxYes;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    private static extern int MessageBoxW(nint hWnd, string text, string caption, uint type);
}

internal sealed class InstallerEngine
{
    private static readonly TimeSpan WaitTimeout = TimeSpan.FromSeconds(60);
    private readonly string _root;
    private readonly SetupOptions _options;
    internal bool RootValidated { get; private set; }
    internal string? PayloadVersion { get; private set; }

    internal InstallerEngine(string root, SetupOptions options)
    {
        _root = root;
        _options = options;
    }

    internal InstallerPreparation PrepareInstall()
    {
        var operationLock = InstallOperationLock.Acquire(_root);
        PrerequisitePlan? prerequisitePlan = null;
        try
        {
            InstallRoot.ValidateTarget(_root);
            var manifestPath = Path.Combine(_root, Program.ManifestFileName);
            Manifest? installedManifest = null;
            if (Directory.Exists(_root) && File.Exists(manifestPath))
            {
                installedManifest = Manifest.Load(manifestPath);
                if (installedManifest.Product != Program.ProductName)
                {
                    throw new SetupException(ExitCode.TargetConflict, "The target contains a different product manifest.");
                }
            }

            if (_options.Update && installedManifest is null)
            {
                throw new SetupException(ExitCode.TargetConflict, "--update requires an existing Nativune installation manifest.");
            }
            if (installedManifest is null)
            {
                InstallRoot.ValidateFreshTarget(_root, allowUpdateArtifacts: true);
            }
            else
            {
                InstallRoot.ValidateManagedTarget(_root, installedManifest);
            }
            RootValidated = true;

            var payloadManifest = DeltaDirectory() is string deltaDir
                ? Manifest.Parse(PayloadReader.ReadDeltaManifestBytes(deltaDir, _options.ExpectedManifestSha256!))
                : PayloadReader.ReadPackagedManifest(SelfPath());
            PayloadVersion = payloadManifest.Version;
            if (payloadManifest.Product != Program.ProductName)
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release payload has an unexpected product.");
            }
            var payloadBytes = payloadManifest.Files.Sum(file => file.Length);
            prerequisitePlan = PrerequisiteInstaller.DetectForConsent(_options);
            var confirmation = new SetupConfirmation(
                installedManifest is null,
                _options.Update,
                installedManifest?.Version,
                payloadManifest.Version,
                _root,
                prerequisitePlan.Missing,
                payloadBytes);
            return new InstallerPreparation(operationLock, installedManifest, prerequisitePlan, confirmation);
        }
        catch
        {
            prerequisitePlan?.Dispose();
            if (_options.DeltaDirectory is not null && RootValidated)
            {
                InstallRoot.TryDeleteDirectory(DeltaDirectoryPath());
            }
            operationLock.Dispose();
            throw;
        }
    }

    private string DeltaDirectoryPath() => Path.Combine(_root, "updates", "delta");

    // Returns the validated delta directory, or null when this is a full-payload run.
    private string? DeltaDirectory()
    {
        if (_options.DeltaDirectory is null)
        {
            return null;
        }
        var expected = Path.GetFullPath(DeltaDirectoryPath());
        string requested;
        try
        {
            requested = Path.GetFullPath(_options.DeltaDirectory);
        }
        catch (Exception error)
        {
            throw new SetupException(ExitCode.InvalidPayload, "The update directory is not a valid path.", error);
        }
        if (!string.Equals(
                requested.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar),
                expected,
                StringComparison.OrdinalIgnoreCase))
        {
            throw new SetupException(ExitCode.InvalidPayload, "The update directory must be the install directory's updates\\delta folder.");
        }
        try
        {
            InstallRoot.EnsureNoReparseChain(expected);
        }
        catch (SetupException error)
        {
            throw new SetupException(ExitCode.InvalidPayload, "The update directory is behind a reparse point.", error);
        }
        if (!Directory.Exists(expected))
        {
            throw new SetupException(ExitCode.InvalidPayload, "The update directory is missing. Download and run the full Nativune Setup instead.");
        }
        return expected;
    }

    internal SetupOutcome Execute(InstallerPreparation preparation, ISetupReporter reporter, CancellationToken cancellationToken)
    {
        var installedManifest = preparation.InstalledManifest;
        var fromVersion = installedManifest?.Version;
        var toVersion = preparation.Confirmation.ToVersion;
        var freshInstall = installedManifest is null;
        var waitPassed = _options.WaitPid is null;
        string? stage = null;
        string? backup = null;
        ShellState? shellState = null;
        var changed = false;
        var keepBackup = false;
        SetupOutcome outcome;
        try
        {
            reporter.Step("Checking for required Microsoft components…", cancellable: true);
            if (_options.WaitPid is int waitPid)
            {
                ProcessWaiter.WaitForExit(waitPid, WaitTimeout, reporter, cancellationToken);
                waitPassed = true;
            }
            if (installedManifest is not null)
            {
                ProcessWaiter.EnsureApplicationStopped(_root);
            }
            cancellationToken.ThrowIfCancellationRequested();

            using var prerequisitePlan = PrerequisiteInstaller.PrepareAfterConsent(
                preparation.Prerequisites, _root, reporter, cancellationToken);
            PrerequisiteInstaller.InstallAndVerify(prerequisitePlan, reporter, cancellationToken);
            cancellationToken.ThrowIfCancellationRequested();

            stage = InstallRoot.CreateAdjacentDirectory(_root, ".nativune-stage");
            backup = InstallRoot.CreateAdjacentDirectory(_root, ".nativune-backup");
            var incomingManifest = DeltaDirectory() is string deltaDir
                ? PayloadReader.BuildStageFromDelta(_root, deltaDir, _options.ExpectedManifestSha256!, stage, reporter, cancellationToken)
                : PayloadReader.ExtractVerified(SelfPath(), stage, reporter, cancellationToken);
            toVersion = incomingManifest.Version;
            if (incomingManifest.Product != Program.ProductName)
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release payload has an unexpected product.");
            }
            if (_options.ExpectedVersion is not null
                && !string.Equals(incomingManifest.Version, _options.ExpectedVersion, StringComparison.Ordinal))
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release payload version does not match the version selected by the updater.");
            }
            if (installedManifest is not null && Manifest.CompareVersions(incomingManifest.Version, installedManifest.Version) <= 0)
            {
                throw new SetupException(ExitCode.TargetConflict, "The release payload must be newer than the installed version.");
            }

            var backupBytes = InstallTransaction.EstimateBackupBytes(_root, installedManifest, incomingManifest);
            reporter.Step("Checking free space…", cancellable: true);
            cancellationToken.ThrowIfCancellationRequested();
            PayloadReader.EnsureFreeSpace(_root, backupBytes);
            if (!_options.TestNoShell)
            {
                shellState = ShellManager.Capture(_root);
            }

            reporter.Step($"Installing files (0 of {incomingManifest.Files.Count:N0}) — This step can't be cancelled.", cancellable: false);
            cancellationToken.ThrowIfCancellationRequested();
            InstallTransaction.Apply(
                _root, stage, backup, installedManifest, incomingManifest,
                _options.TestNoShell, shellState, reporter);
            changed = true;

            outcome = SetupOutcome.SucceededInstall(fromVersion, incomingManifest.Version, freshInstall, _root, canOpen: !_options.NoLaunch);
            UpdateOutcomeWriter.TryWrite(_root, outcome);
            if (!_options.NoLaunch && (!freshInstall || _options.Silent))
            {
                reporter.Step("Starting Nativune…", cancellable: false);
                Launcher.Start(_root);
            }
        }
        catch (OperationCanceledException)
        {
            var canReopen = CanReopenAfterOperation(fromVersion, ExitCode.Cancelled, waitPassed);
            outcome = SetupOutcome.Cancelled(fromVersion, toVersion, freshInstall, canReopen);
            UpdateOutcomeWriter.TryWrite(_root, outcome);
        }
        catch (SetupException error)
        {
            keepBackup = error.Code == ExitCode.RollbackFailure;
            var canReopen = CanReopenAfterOperation(fromVersion, error.Code, waitPassed);
            var displayError = error;
            if (error.Code == ExitCode.UnsafeRoot && _options.Update)
            {
                var unchangedText = changed
                    ? "Setup did not reopen Nativune because the install location failed safety validation."
                    : "The existing Nativune version was left untouched. Setup did not reopen it because the install location failed safety validation.";
                displayError = new SetupException(error.Code, $"{error.Message}\n\n{unchangedText}", error.InnerException ?? error);
            }
            outcome = error.Code == ExitCode.Cancelled
                ? SetupOutcome.Cancelled(fromVersion, toVersion, freshInstall, canReopen, displayError.Message)
                : SetupOutcome.Failed(displayError, fromVersion, toVersion, freshInstall, canReopen);
            if (error.Code != ExitCode.UnsafeRoot)
            {
                if (changed && error.Code == ExitCode.LaunchFailure)
                {
                    var appliedOutcome = SetupOutcome.SucceededInstall(fromVersion, toVersion, fresh: freshInstall, root: _root, canOpen: false)
                        with { ExitCode = error.Code, ResultMessage = error.Message };
                    UpdateOutcomeWriter.TryWrite(_root, appliedOutcome);
                }
                else
                {
                    UpdateOutcomeWriter.TryWrite(_root, outcome);
                }
            }
        }
        catch (Exception error)
        {
            var setupError = new SetupException(ExitCode.IoFailure, "Nativune could not be installed.", error);
            var canReopen = CanReopenAfterOperation(fromVersion, setupError.Code, waitPassed);
            outcome = SetupOutcome.Failed(setupError, fromVersion, toVersion, freshInstall, canReopen);
            UpdateOutcomeWriter.TryWrite(_root, outcome);
        }
        finally
        {
            InstallRoot.TryDeleteDirectory(stage);
            // An incomplete rollback leaves the backup as the only copy of replaced files.
            if (!keepBackup)
            {
                InstallRoot.TryDeleteDirectory(backup);
            }
            if (_options.DeltaDirectory is not null)
            {
                InstallRoot.TryDeleteDirectory(DeltaDirectoryPath());
            }
            if (!changed && shellState is not null)
            {
                ShellManager.TryRestore(shellState);
            }
        }
        return outcome;
    }

    internal static string? TryGetInstalledVersion(string root)
    {
        try
        {
            var manifestPath = Path.Combine(root, Program.ManifestFileName);
            InstallRoot.EnsureNoReparseChain(manifestPath);
            if (!File.Exists(manifestPath) || InstallRoot.IsReparsePoint(manifestPath))
            {
                return null;
            }
            var manifest = Manifest.Load(manifestPath);
            return manifest.Product == Program.ProductName ? manifest.Version : null;
        }
        catch
        {
            return null;
        }
    }
    internal static bool IsInstalledManifestIntact(string root, string expectedVersion, bool allowTestRoot)
    {
        try
        {
            var validatedRoot = InstallRoot.Resolve(root, allowTestRoot);
            InstallRoot.ValidateTarget(validatedRoot);
            var manifestPath = Path.Combine(validatedRoot, Program.ManifestFileName);
            if (!File.Exists(manifestPath) || InstallRoot.IsReparsePoint(manifestPath))
            {
                return false;
            }
            var manifest = Manifest.Load(manifestPath);
            if (manifest.Product != Program.ProductName
                || !string.Equals(manifest.Version, expectedVersion, StringComparison.Ordinal))
            {
                return false;
            }
            InstallRoot.ValidateManagedTarget(validatedRoot, manifest);
            return ProcessWaiter.IsApplicationStopped(validatedRoot);
        }
        catch
        {
            return false;
        }
    }

    private bool CanReopenAfterOperation(string? fromVersion, ExitCode code, bool waitPassed)
    {
        if (!_options.Update
            || _options.NoLaunch
            || code is ExitCode.WaitTimeout or ExitCode.RollbackFailure or ExitCode.UnsafeRoot
            || fromVersion is null)
        {
            return false;
        }
        try
        {
            if (!waitPassed && _options.WaitPid is int waitPid)
            {
                ProcessWaiter.WaitForExit(waitPid, WaitTimeout);
            }
            return IsInstalledManifestIntact(_root, fromVersion, _options.TestNoShell);
        }
        catch
        {
            return false;
        }
    }

    internal ExitCode Uninstall()
    {
        using var operationLock = InstallOperationLock.Acquire(_root);
        InstallRoot.ValidateTarget(_root);
        var manifestPath = Path.Combine(_root, Program.ManifestFileName);
        if (!File.Exists(manifestPath))
        {
            throw new SetupException(ExitCode.TargetConflict, "Nativune's installed manifest is missing; no files were removed.");
        }
        var manifest = Manifest.Load(manifestPath);
        if (manifest.Product != Program.ProductName)
        {
            throw new SetupException(ExitCode.TargetConflict, "The target contains a different product manifest.");
        }
        InstallRoot.ValidateManagedTarget(_root, manifest);

        if (!_options.Silent && !UserInterface.Confirm($"Uninstall Nativune from:\n\n{_root}\n\nThe data folder will be preserved."))
        {
            return ExitCode.Cancelled;
        }

        var currentProcessPath = SelfPath();
        if (InstallRoot.IsWithin(_root, currentProcessPath))
        {
            return StartUninstallHandoff(currentProcessPath);
        }

        if (_options.WaitPid is int waitPid)
        {
            ProcessWaiter.WaitForExit(waitPid, WaitTimeout);
        }
        ProcessWaiter.EnsureApplicationStopped(_root);

        var backup = InstallRoot.CreateAdjacentDirectory(_root, ".nativune-uninstall-backup");
        ShellState? shellState = null;
        try
        {
            if (!_options.TestNoShell)
            {
                shellState = ShellManager.Capture(_root);
            }
            UninstallTransaction.Apply(_root, backup, manifest, _options.TestNoShell, shellState);
            TryRemoveDownloadedUpdate(_root);
            ScheduleHandoffCleanup();
            return ExitCode.Success;
        }
        finally
        {
            InstallRoot.TryDeleteDirectory(backup);
            if (shellState is not null)
            {
                // UninstallTransaction restores shell state only when its file transaction fails.
                // A completed uninstall deliberately leaves the shell registration removed.
            }
        }
    }

    private ExitCode StartUninstallHandoff(string currentProcessPath)
    {
        var handoffDirectory = Path.Combine(Path.GetTempPath(), $"Nativune-uninstall-{Guid.NewGuid():N}");
        InstallRoot.CreateSafeDirectory(handoffDirectory);
        var handoffExecutable = Path.Combine(handoffDirectory, Program.SetupFileName);
        try
        {
            File.Copy(currentProcessPath, handoffExecutable, overwrite: false);
            var arguments = new StringBuilder("--uninstall --silent --wait-pid ")
                .Append(Environment.ProcessId)
                .Append(" --install-dir ")
                .Append(ArgumentQuoter.Quote(_root));
            if (_options.TestNoShell)
            {
                arguments.Append(" --test-no-shell");
            }
            var process = Process.Start(new ProcessStartInfo
            {
                FileName = handoffExecutable,
                Arguments = arguments.ToString(),
                WorkingDirectory = handoffDirectory,
                UseShellExecute = false,
                CreateNoWindow = true,
            });
            if (process is null)
            {
                throw new SetupException(ExitCode.IoFailure, "Could not start the uninstall helper.");
            }
            return ExitCode.Success;
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new SetupException(ExitCode.IoFailure, "Could not start the uninstall helper.", error);
        }
    }

    private static void TryRemoveDownloadedUpdate(string root)
    {
        try
        {
            var updatesDirectory = Path.Combine(root, "updates");
            if (!Directory.Exists(updatesDirectory) || InstallRoot.IsReparsePoint(updatesDirectory))
            {
                return;
            }
            var setupPath = Path.Combine(updatesDirectory, "Nativune-Setup.exe");
            if (File.Exists(setupPath) && !InstallRoot.IsReparsePoint(setupPath))
            {
                File.Delete(setupPath);
            }
            var resultPath = Path.Combine(updatesDirectory, "last-update.json");
            if (File.Exists(resultPath) && !InstallRoot.IsReparsePoint(resultPath))
            {
                File.Delete(resultPath);
            }
            foreach (var stalePath in Directory.EnumerateFiles(
                updatesDirectory,
                ".Nativune-Setup.exe.*.tmp",
                SearchOption.TopDirectoryOnly))
            {
                if (!InstallRoot.IsReparsePoint(stalePath))
                {
                    File.Delete(stalePath);
                }
            }
            foreach (var stalePath in Directory.EnumerateFiles(
                updatesDirectory,
                ".last-update.*.tmp",
                SearchOption.TopDirectoryOnly))
            {
                if (!InstallRoot.IsReparsePoint(stalePath))
                {
                    File.Delete(stalePath);
                }
            }
            if (!Directory.EnumerateFileSystemEntries(updatesDirectory).Any())
            {
                Directory.Delete(updatesDirectory);
            }
        }
        catch
        {
            // The downloaded installer is a disposable cache. Never turn an otherwise
            // successful uninstall into data loss because cache cleanup was blocked.
        }
    }

    private static void ScheduleHandoffCleanup()
    {
        try
        {
            var executable = SelfPath();
            var directory = Path.GetDirectoryName(executable);
            var temporaryRoot = Path.GetFullPath(Path.GetTempPath());
            if (string.IsNullOrWhiteSpace(directory)
                || !Path.GetFileName(directory).StartsWith("Nativune-uninstall-", StringComparison.Ordinal)
                || !InstallRoot.IsWithin(temporaryRoot, directory))
            {
                return;
            }

            const uint delayUntilReboot = 0x00000004;
            _ = MoveFileExW(executable, null, delayUntilReboot);
            _ = MoveFileExW(directory, null, delayUntilReboot);
        }
        catch
        {
            // Best effort: Windows may retain the short-lived helper until reboot.
        }
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool MoveFileExW(string existingFileName, string? newFileName, uint flags);

    private static string SelfPath()
    {
        var path = Environment.ProcessPath;
        if (string.IsNullOrWhiteSpace(path))
        {
            throw new SetupException(ExitCode.IoFailure, "The setup executable path is unavailable.");
        }
        return Path.GetFullPath(path);
    }
}

internal sealed class InstallerPreparation : IDisposable
{
    private InstallOperationLock? _operationLock;

    internal InstallerPreparation(
        InstallOperationLock operationLock,
        Manifest? installedManifest,
        PrerequisitePlan prerequisites,
        SetupConfirmation confirmation)
    {
        _operationLock = operationLock;
        InstalledManifest = installedManifest;
        Prerequisites = prerequisites;
        Confirmation = confirmation;
    }

    internal Manifest? InstalledManifest { get; }
    internal PrerequisitePlan Prerequisites { get; }
    internal SetupConfirmation Confirmation { get; }

    public void Dispose()
    {
        Prerequisites.Dispose();
        Interlocked.Exchange(ref _operationLock, null)?.Dispose();
    }
}

internal sealed class InstallOperationLock : IDisposable
{
    private readonly Mutex _mutex;
    private bool _acquired;

    private InstallOperationLock(Mutex mutex, bool acquired)
    {
        _mutex = mutex;
        _acquired = acquired;
    }

    internal static InstallOperationLock Acquire(string root)
    {
        var normalized = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar).ToUpperInvariant();
        var digest = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(normalized)));
        var mutex = new Mutex(initiallyOwned: false, $"Local\\Nativune.Setup.{digest[..32]}");
        try
        {
            var acquired = false;
            try
            {
                acquired = mutex.WaitOne(TimeSpan.FromSeconds(75));
            }
            catch (AbandonedMutexException)
            {
                acquired = true;
            }
            if (!acquired)
            {
                throw new SetupException(ExitCode.TargetConflict, "Another Nativune setup operation is still running.");
            }
            return new InstallOperationLock(mutex, acquired: true);
        }
        catch
        {
            mutex.Dispose();
            throw;
        }
    }

    public void Dispose()
    {
        if (_acquired)
        {
            _mutex.ReleaseMutex();
            _acquired = false;
        }
        _mutex.Dispose();
    }
}

internal static class ProcessWaiter
{
    internal static void WaitForExit(int pid, TimeSpan timeout)
    {
        if (pid == Environment.ProcessId)
        {
            throw new SetupException(ExitCode.Usage, "--wait-pid cannot name the setup process.");
        }

        try
        {
            using var process = Process.GetProcessById(pid);
            if (process.HasExited)
            {
                return;
            }
            if (!process.WaitForExit((int)timeout.TotalMilliseconds) && !process.HasExited)
            {
                throw new SetupException(ExitCode.WaitTimeout, $"Process {pid} did not exit within {timeout.TotalSeconds:0} seconds.");
            }
        }
        catch (ArgumentException)
        {
            // A process that disappeared before GetProcessById is already stopped.
        }
        catch (InvalidOperationException)
        {
            // A process that disappeared while opening the handle is already stopped.
        }
    }

    internal static void WaitForExit(int pid, TimeSpan timeout, ISetupReporter reporter, CancellationToken cancellationToken)
    {
        if (pid == Environment.ProcessId)
        {
            throw new SetupException(ExitCode.Usage, "--wait-pid cannot name the setup process.");
        }

        try
        {
            using var process = Process.GetProcessById(pid);
            var seconds = (int)Math.Ceiling(timeout.TotalSeconds);
            for (var remaining = seconds; remaining > 0; remaining--)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (process.HasExited)
                {
                    return;
                }
                reporter.Step($"Waiting for Nativune to close… ({remaining} s remaining)", cancellable: true);
                if (process.WaitForExit(1000) || process.HasExited)
                {
                    return;
                }
            }
            if (!process.HasExited)
            {
                throw new SetupException(ExitCode.WaitTimeout, "Nativune is still running. Close it, then run Setup again.");
            }
        }
        catch (ArgumentException)
        {
            // A process that disappeared before GetProcessById is already stopped.
        }
        catch (InvalidOperationException)
        {
            // A process that disappeared while being inspected is already stopped.
        }
    }

    internal static void EnsureApplicationStopped(string root)
    {
        var processName = Path.GetFileNameWithoutExtension(Program.AppExecutable);
        var installedExecutable = Path.GetFullPath(
            Path.Combine(root, Program.AppExecutable.Replace('/', Path.DirectorySeparatorChar)));
        foreach (var process in Process.GetProcessesByName(processName))
        {
            using (process)
            {
                try
                {
                    if (process.Id == Environment.ProcessId || process.HasExited)
                    {
                        continue;
                    }
                    var processExecutable = process.MainModule?.FileName;
                    if (!string.IsNullOrWhiteSpace(processExecutable) &&
                        string.Equals(Path.GetFullPath(processExecutable), installedExecutable, StringComparison.OrdinalIgnoreCase))
                    {
                        throw new SetupException(
                            ExitCode.TargetConflict,
                            $"Close {Program.ProductName} before modifying its installation at {root}.");
                    }
                }
                catch (InvalidOperationException)
                {
                    // The process exited while it was being inspected.
                }
                catch (System.ComponentModel.Win32Exception)
                {
                    // An unrelated or higher-integrity process could not be inspected. File
                    // transaction checks still fail closed if it actually locks this install.
                }
            }
        }
    }
    internal static bool IsApplicationStopped(string root)
    {
        try
        {
            EnsureApplicationStopped(root);
            return true;
        }
        catch
        {
            return false;
        }
    }
}

internal static class Launcher
{
    internal static void Start(string root)
    {
        var executable = Path.Combine(root, Program.AppExecutable.Replace('/', Path.DirectorySeparatorChar));
        PathSafety.EnsureRegularFile(executable);
        Process? process;
        try
        {
            process = Process.Start(new ProcessStartInfo
            {
                FileName = executable,
                Arguments = $"web --root {ArgumentQuoter.Quote(root)}",
                WorkingDirectory = root,
                UseShellExecute = false,
                CreateNoWindow = false,
            });
        }
        catch (Exception error) when (error is System.ComponentModel.Win32Exception or InvalidOperationException or IOException or UnauthorizedAccessException)
        {
            throw new SetupException(ExitCode.LaunchFailure, "Nativune was installed but could not be launched.", error);
        }
        if (process is null)
        {
            throw new SetupException(ExitCode.LaunchFailure, "Nativune was installed but could not be launched.");
        }
    }
}

internal static class ArgumentQuoter
{
    internal static string Quote(string value)
    {
        var builder = new StringBuilder(value.Length + 2).Append('"');
        var backslashes = 0;
        foreach (var character in value)
        {
            if (character == '\\')
            {
                backslashes++;
                continue;
            }
            if (character == '"')
            {
                builder.Append('\\', backslashes * 2 + 1).Append('"');
                backslashes = 0;
                continue;
            }
            if (backslashes > 0)
            {
                builder.Append('\\', backslashes);
                backslashes = 0;
            }
            builder.Append(character);
        }
        if (backslashes > 0)
        {
            builder.Append('\\', backslashes * 2);
        }
        return builder.Append('"').ToString();
    }
}

internal static class UpdateOutcomeWriter
{
    private sealed record OutcomeDocument(
        [property: JsonPropertyName("schemaVersion")] int SchemaVersion,
        [property: JsonPropertyName("fromVersion")] string? FromVersion,
        [property: JsonPropertyName("toVersion")] string ToVersion,
        [property: JsonPropertyName("status")] string Status,
        [property: JsonPropertyName("exitCode")] int ExitCode,
        [property: JsonPropertyName("message")] string? Message,
        [property: JsonPropertyName("completedUtc")] string CompletedUtc);

    internal static void TryWrite(string root, SetupOutcome outcome)
    {
        string? temporaryPath = null;
        try
        {
            if (outcome.Status is not ("success" or "installed" or "cancelled" or "failed"))
            {
                return;
            }

            var fullRoot = Path.GetFullPath(root);
            if (InstallRoot.IsReparsePoint(fullRoot))
            {
                return;
            }
            InstallRoot.EnsureNoReparseChain(fullRoot);
            if (InstallRoot.PathExists(fullRoot) && !Directory.Exists(fullRoot))
            {
                return;
            }
            if (outcome.IsFreshInstall && !Directory.Exists(fullRoot))
            {
                return;
            }
            if (!Directory.Exists(fullRoot))
            {
                InstallRoot.CreateSafeDirectory(fullRoot);
            }

            var updatesDirectory = Path.Combine(fullRoot, "updates");
            if (InstallRoot.IsReparsePoint(updatesDirectory))
            {
                return;
            }
            InstallRoot.EnsureNoReparseChain(updatesDirectory);
            if (InstallRoot.PathExists(updatesDirectory) && !Directory.Exists(updatesDirectory))
            {
                return;
            }
            if (!Directory.Exists(updatesDirectory))
            {
                InstallRoot.CreateSafeDirectory(updatesDirectory);
            }
            InstallRoot.EnsureNoReparseChain(updatesDirectory);

            var resultPath = Path.Combine(updatesDirectory, "last-update.json");
            if (InstallRoot.IsReparsePoint(resultPath)
                || (InstallRoot.PathExists(resultPath) && !File.Exists(resultPath)))
            {
                return;
            }
            InstallRoot.EnsureNoReparseChain(resultPath);

            var document = new OutcomeDocument(
                1,
                outcome.FromVersion,
                outcome.ToVersion,
                outcome.Status,
                (int)outcome.ExitCode,
                outcome.ResultMessage,
                DateTimeOffset.UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", System.Globalization.CultureInfo.InvariantCulture));
            var bytes = JsonSerializer.SerializeToUtf8Bytes(document);
            if (bytes.Length > 16 * 1024)
            {
                return;
            }
            temporaryPath = Path.Combine(updatesDirectory, $".last-update.{Guid.NewGuid():N}.tmp");
            using (var stream = new FileStream(temporaryPath, FileMode.CreateNew, FileAccess.Write, FileShare.None, 4096, FileOptions.WriteThrough))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            InstallRoot.EnsureNoReparseChain(resultPath);
            if (InstallRoot.IsReparsePoint(resultPath))
            {
                return;
            }
            File.Move(temporaryPath, resultPath, overwrite: true);
            temporaryPath = null;
        }
        catch
        {
            // The result file is best-effort and must never change Setup's exit code.
        }
        finally
        {
            if (temporaryPath is not null)
            {
                try
                {
                    if (File.Exists(temporaryPath) && !InstallRoot.IsReparsePoint(temporaryPath))
                    {
                        File.Delete(temporaryPath);
                    }
                }
                catch
                {
                    // A leftover temporary result is harmless and is never followed.
                }
            }
        }
    }
}
