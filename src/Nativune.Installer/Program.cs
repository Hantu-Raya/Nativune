using System.Diagnostics;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.Text;

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
          {SetupFileName} [--install-dir <absolute-path>] [--silent] [--no-launch]
          {SetupFileName} --update --wait-pid <positive-pid> [--install-dir <absolute-path>] [--silent] [--no-launch]
          {SetupFileName} --uninstall [--install-dir <absolute-path>] [--silent]
          {SetupFileName} --help

        Options:
          --install-dir <path>  Absolute root under %LOCALAPPDATA%. Default: %LOCALAPPDATA%\{DefaultInstallDirectoryName}.
          --silent              Suppress confirmation and error dialogs. Invocation accepts included third-party terms.
          --no-launch           Do not launch the installed application.
          --update              Replace the existing managed application after --wait-pid exits.
          --wait-pid <pid>      Positive process id; wait up to 60 seconds before replacement/removal.
          --uninstall           Remove manifest-owned files and shell registration, preserving data/.

        Exit codes:
          0 success; 2 usage; 3 cancelled; 10 invalid payload; 11 unsafe install root;
          12 target conflict; 13 wait timeout; 14 shell/ACL failure; 15 I/O failure;
          16 rollback failure; 17 launch failure; 18 unsupported platform.

        Continuing an interactive install or update accepts the included third-party license terms.
        A --silent invocation signifies the same acceptance. Nativune does not add an application EULA.
        """;

    [STAThread]
    private static int Main(string[] args)
    {
        var silentRequested = args.Contains("--silent", StringComparer.Ordinal);
        SetupOptions? options = null;
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

            var root = InstallRoot.Resolve(options.InstallDirectory, options.TestNoShell);
            var engine = new InstallerEngine(root, options);
            var result = options.Uninstall ? engine.Uninstall() : engine.InstallOrUpdate();
            return (int)result;
        }
        catch (SetupException error)
        {
            var silent = options?.Silent == true || silentRequested;
            UserInterface.ShowError(error.Message, silent);
            return (int)error.Code;
        }
        catch (Exception error)
        {
            UserInterface.ShowError($"Nativune Setup failed: {error.Message}", options?.Silent == true || silentRequested);
            return (int)ExitCode.IoFailure;
        }
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
    int? WaitPid)
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
        string? expectedVersion = null;
        int? waitPid = null;

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
                case "--no-launch":
                    noLaunch = true;
                    break;
#if INSTALLER_TEST_HOOKS
                case "--test-no-shell":
                    testNoShell = true;
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

        if (help && (update || uninstall || installDirectory is not null || expectedVersion is not null || waitPid is not null || noLaunch || testNoShell))
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
#if INSTALLER_TEST_HOOKS
        if (testNoShell && !silent)
        {
            throw new SetupException(ExitCode.Usage, "--test-no-shell requires --silent.");
        }
#endif
        return new SetupOptions(help, silent, noLaunch, testNoShell, update, uninstall, installDirectory, expectedVersion, waitPid);
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

    internal InstallerEngine(string root, SetupOptions options)
    {
        _root = root;
        _options = options;
    }

    internal ExitCode InstallOrUpdate()
    {
        using var operationLock = InstallOperationLock.Acquire(_root);
        InstallRoot.ValidateTarget(_root);
        var manifestPath = Path.Combine(_root, Program.ManifestFileName);
        Manifest? installedManifest = null;
        var rootExists = Directory.Exists(_root);
        if (rootExists && File.Exists(manifestPath))
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
        if (!_options.Update && installedManifest is not null)
        {
            throw new SetupException(ExitCode.TargetConflict, "Nativune is already installed; use --update to replace it.");
        }
        if (!_options.Update)
        {
            InstallRoot.ValidateFreshTarget(_root);
        }
        else
        {
            InstallRoot.ValidateManagedTarget(_root, installedManifest!);
        }

        if (!_options.Silent)
        {
            var action = _options.Update ? "update" : "install";
            if (!UserInterface.Confirm($"Continue to {action} Nativune in:\n\n{_root}\n\nContinuing accepts the included third-party license terms."))
            {
                return ExitCode.Cancelled;
            }
        }

        if (_options.WaitPid is int waitPid)
        {
            ProcessWaiter.WaitForExit(waitPid, WaitTimeout);
        }

        var stage = InstallRoot.CreateAdjacentDirectory(_root, ".nativune-stage");
        var backup = InstallRoot.CreateAdjacentDirectory(_root, ".nativune-backup");
        ShellState? shellState = null;
        var changed = false;
        try
        {
            var incomingManifest = PayloadReader.ExtractVerified(SelfPath(), stage);
            if (incomingManifest.Product != Program.ProductName)
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release payload has an unexpected product.");
            }
            if (installedManifest is not null && Manifest.CompareVersions(incomingManifest.Version, installedManifest.Version) <= 0)
            {
                throw new SetupException(ExitCode.TargetConflict, "The release payload must be newer than the installed version.");
            }
            if (_options.ExpectedVersion is not null
                && !string.Equals(incomingManifest.Version, _options.ExpectedVersion, StringComparison.Ordinal))
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release payload version does not match the version selected by the updater.");
            }

            var backupBytes = InstallTransaction.EstimateBackupBytes(_root, installedManifest, incomingManifest);
            PayloadReader.EnsureFreeSpace(_root, backupBytes);

            if (!_options.TestNoShell)
            {
                shellState = ShellManager.Capture(_root);
            }

            InstallTransaction.Apply(_root, stage, backup, installedManifest, incomingManifest, _options.TestNoShell, shellState);
            changed = true;

            if (!_options.NoLaunch)
            {
                Launcher.Start(_root);
            }
            return ExitCode.Success;
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new SetupException(ExitCode.IoFailure, "Nativune could not be installed.", error);
        }
        finally
        {
            InstallRoot.TryDeleteDirectory(stage);
            InstallRoot.TryDeleteDirectory(backup);
            if (!changed && shellState is not null)
            {
                // InstallTransaction restores shell state when its transaction fails. This branch
                // only protects against a failure before the transaction was entered.
                ShellManager.TryRestore(shellState);
            }
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
                            $"Close {Program.ProductName} before uninstalling it from {root}.");
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
}

internal static class Launcher
{
    internal static void Start(string root)
    {
        var executable = Path.Combine(root, Program.AppExecutable.Replace('/', Path.DirectorySeparatorChar));
        PathSafety.EnsureRegularFile(executable);
        var process = Process.Start(new ProcessStartInfo
        {
            FileName = executable,
            Arguments = $"web --root {ArgumentQuoter.Quote(root)}",
            WorkingDirectory = root,
            UseShellExecute = false,
            CreateNoWindow = false,
        });
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
