using Microsoft.Win32;
using System.Diagnostics;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;

namespace Nativune.Installer;

internal sealed record ShortcutState(string Path, bool Exists, byte[]? Bytes);

internal sealed class ShellState
{
    internal ShellState(
        IReadOnlyList<ShortcutState> shortcuts,
        bool registryExists,
        IReadOnlyDictionary<string, (object Value, RegistryValueKind Kind)> registryValues)
    {
        Shortcuts = shortcuts;
        RegistryExists = registryExists;
        RegistryValues = registryValues;
    }

    internal IReadOnlyList<ShortcutState> Shortcuts { get; }
    internal bool RegistryExists { get; }
    internal IReadOnlyDictionary<string, (object Value, RegistryValueKind Kind)> RegistryValues { get; }
}

internal static class InstallTransaction
{
    internal static long EstimateBackupBytes(string root, Manifest? installed, Manifest incoming)
    {
        var oldPaths = installed?.Files.Select(file => file.Path).ToHashSet(StringComparer.OrdinalIgnoreCase)
            ?? new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long bytes = installed?.Files.Sum(file => file.Length) ?? 0;
        var installedManifestPath = Path.Combine(root, Program.ManifestFileName);
        if (File.Exists(installedManifestPath) && !InstallRoot.IsReparsePoint(installedManifestPath))
        {
            bytes = checked(bytes + new FileInfo(installedManifestPath).Length);
        }
        foreach (var file in incoming.Files)
        {
            if (oldPaths.Contains(file.Path))
            {
                continue;
            }
            var target = InstallRoot.ResolvePayloadPath(root, file.Path);
            if (File.Exists(target) && !InstallRoot.IsReparsePoint(target))
            {
                bytes = checked(bytes + new FileInfo(target).Length);
            }
        }
        return bytes;
    }

    internal static void Apply(
        string root,
        string stage,
        string backup,
        Manifest? installed,
        Manifest incoming,
        bool noShell,
        ShellState? shellState,
        ISetupReporter? reporter = null)
    {
        var oldPaths = installed?.Files.Select(file => file.Path).ToHashSet(StringComparer.OrdinalIgnoreCase)
            ?? new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var newPaths = incoming.Files.Select(file => file.Path).ToHashSet(StringComparer.OrdinalIgnoreCase);
        var allPaths = oldPaths.Union(newPaths, StringComparer.OrdinalIgnoreCase).Append(Program.ManifestFileName).ToArray();
        foreach (var path in allPaths)
        {
            var target = string.Equals(path, Program.ManifestFileName, StringComparison.Ordinal)
                ? Path.Combine(root, Program.ManifestFileName)
                : InstallRoot.ResolvePayloadPath(root, path);
            InstallRoot.EnsureNoReparseChain(target);
            if (InstallRoot.PathExists(target) && Directory.Exists(target))
            {
                throw new SetupException(ExitCode.TargetConflict, $"The managed target {path} is a directory.");
            }
            if (newPaths.Contains(path) && !oldPaths.Contains(path) && InstallRoot.PathExists(target))
            {
                var incomingFile = incoming.Files.First(file => string.Equals(file.Path, path, StringComparison.OrdinalIgnoreCase));
                if (!MatchesIncomingFile(target, incomingFile))
                {
                    throw new SetupException(ExitCode.TargetConflict, $"The target already contains an unmanaged file at {path}.");
                }
            }
        }

        var shellApplied = false;
        var backedUpPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var changedPaths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var manifestInstalled = false;
        try
        {
            InstallRoot.CreateSafeDirectory(root);
            foreach (var path in oldPaths.Union(newPaths, StringComparer.OrdinalIgnoreCase).Append(Program.ManifestFileName))
            {
                if (CopyToBackup(root, backup, path))
                {
                    backedUpPaths.Add(path);
                }
            }
            var obsoletePaths = oldPaths.Except(newPaths, StringComparer.OrdinalIgnoreCase).ToArray();
            foreach (var path in obsoletePaths)
            {
                if (backedUpPaths.Contains(path))
                {
                    if (RemoveManagedTarget(root, path))
                    {
                        changedPaths.Add(path);
                    }
                }
                else
                {
                    EnsureManagedTargetAbsent(root, path);
                }
            }
            var completedFiles = 0;
            foreach (var file in incoming.Files.OrderBy(file => file.Path, StringComparer.Ordinal))
            {
                MoveStagedToTarget(root, stage, file.Path, backedUpPaths);
                changedPaths.Add(file.Path);
                completedFiles++;
                reporter?.Step($"Installing files ({completedFiles:N0} of {incoming.Files.Count:N0}) — This step can't be cancelled.", cancellable: false);
                reporter?.Progress(completedFiles, incoming.Files.Count);
            }

            reporter?.Step(
                noShell ? "Checking Start menu and desktop shortcuts…" : "Adding Start menu and desktop shortcuts…",
                cancellable: false);
            reporter?.Progress(0, 0);

            if (!noShell)
            {
                // Mark before invocation so a partial COM/registry mutation is restored.
                shellApplied = true;
                ShellManager.Apply(root, incoming.Version);
            }
            foreach (var path in obsoletePaths)
            {
                EnsureManagedTargetAbsent(root, path);
            }
            MoveStagedToTarget(root, stage, Program.ManifestFileName, backedUpPaths);
            manifestInstalled = true;
            UninstallTransaction.RemoveEmptyManagedDirectories(root, obsoletePaths);
        }
        catch (Exception error)
        {
            Exception? rollbackError = null;
            try
            {
                if (shellApplied && shellState is not null)
                {
                    ShellManager.Restore(shellState);
                }
                Rollback(root, backup, backedUpPaths, changedPaths, manifestInstalled);
                UninstallTransaction.RemoveEmptyManagedDirectories(
                    root, newPaths.Except(oldPaths, StringComparer.OrdinalIgnoreCase));
            }
            catch (Exception rollback)
            {
                rollbackError = rollback;
            }
            if (rollbackError is not null)
            {
                throw new SetupException(ExitCode.RollbackFailure, "Nativune installation failed and rollback was incomplete.", rollbackError);
            }
            if (error is SetupException setup)
            {
                throw setup;
            }
            throw new SetupException(ExitCode.IoFailure, "Nativune installation failed; all managed files were rolled back.", error);
        }
    }

    private static bool CopyToBackup(string root, string backup, string relativePath)
    {
        var source = string.Equals(relativePath, Program.ManifestFileName, StringComparison.Ordinal)
            ? Path.Combine(root, Program.ManifestFileName)
            : InstallRoot.ResolvePayloadPath(root, relativePath);
        if (!InstallRoot.PathExists(source))
        {
            return false;
        }
        if (Directory.Exists(source))
        {
            throw new SetupException(ExitCode.TargetConflict, $"The managed target {relativePath} is a directory.");
        }
        InstallRoot.EnsureRegularFile(source);
        var destination = Path.Combine(backup, relativePath.Replace('/', Path.DirectorySeparatorChar));
        InstallRoot.EnsureDirectoryChain(backup, Path.GetDirectoryName(destination)!);
        File.Copy(source, destination, overwrite: false);
        return true;
    }

    private static void MoveStagedToTarget(
        string root,
        string stage,
        string relativePath,
        HashSet<string> backedUpPaths)
    {
        var source = string.Equals(relativePath, Program.ManifestFileName, StringComparison.Ordinal)
            ? Path.Combine(stage, Program.ManifestFileName)
            : InstallRoot.ResolvePayloadPath(stage, relativePath);
        PathSafety.EnsureRegularFile(source);
        var destination = string.Equals(relativePath, Program.ManifestFileName, StringComparison.Ordinal)
            ? Path.Combine(root, Program.ManifestFileName)
            : InstallRoot.ResolvePayloadPath(root, relativePath);
        InstallRoot.EnsureDirectoryChain(root, Path.GetDirectoryName(destination)!);
        if (InstallRoot.PathExists(destination))
        {
            if (Directory.Exists(destination) || InstallRoot.IsReparsePoint(destination))
            {
                throw new SetupException(ExitCode.TargetConflict, $"The destination became unsafe while installing {relativePath}.");
            }
            if (!backedUpPaths.Contains(relativePath))
            {
                throw new SetupException(ExitCode.TargetConflict, $"The destination became occupied while installing {relativePath}.");
            }
        }
        File.Move(source, destination, overwrite: true);
    }

    private static bool RemoveManagedTarget(string root, string relativePath)
    {
        var target = InstallRoot.ResolvePayloadPath(root, relativePath);
        if (!InstallRoot.PathExists(target))
        {
            return false;
        }
        if (Directory.Exists(target) || InstallRoot.IsReparsePoint(target))
        {
            throw new SetupException(ExitCode.TargetConflict, $"The obsolete managed target became unsafe: {relativePath}");
        }
        File.Delete(target);
        return true;
    }

    private static void EnsureManagedTargetAbsent(string root, string relativePath)
    {
        var target = InstallRoot.ResolvePayloadPath(root, relativePath);
        if (InstallRoot.PathExists(target))
        {
            throw new SetupException(ExitCode.TargetConflict, $"The obsolete managed target became occupied during update: {relativePath}");
        }
    }

    private static bool MatchesIncomingFile(string path, PayloadFile incoming)
    {
        if (!File.Exists(path) || Directory.Exists(path) || InstallRoot.IsReparsePoint(path))
        {
            return false;
        }
        var info = new FileInfo(path);
        if (info.Length != incoming.Length)
        {
            return false;
        }
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return Convert.ToHexString(SHA256.HashData(stream)).Equals(incoming.Sha256, StringComparison.OrdinalIgnoreCase);
    }

    private static void Rollback(
        string root,
        string backup,
        HashSet<string> backedUpPaths,
        HashSet<string> changedPaths,
        bool manifestInstalled)
    {
        foreach (var path in changedPaths.Append(manifestInstalled ? Program.ManifestFileName : string.Empty)
                     .Where(path => !string.IsNullOrEmpty(path)))
        {
            var target = string.Equals(path, Program.ManifestFileName, StringComparison.Ordinal)
                ? Path.Combine(root, Program.ManifestFileName)
                : InstallRoot.ResolvePayloadPath(root, path);
            if (InstallRoot.PathExists(target))
            {
                if (Directory.Exists(target) || InstallRoot.IsReparsePoint(target))
                {
                    throw new IOException($"Rollback found an unsafe target at {target}.");
                }
                File.Delete(target);
            }
        }
        foreach (var path in backedUpPaths)
        {
            var source = Path.Combine(backup, path.Replace('/', Path.DirectorySeparatorChar));
            if (!File.Exists(source))
            {
                throw new IOException($"Rollback backup is unexpectedly missing: {source}");
            }
            var target = string.Equals(path, Program.ManifestFileName, StringComparison.Ordinal)
                ? Path.Combine(root, Program.ManifestFileName)
                : InstallRoot.ResolvePayloadPath(root, path);
            InstallRoot.EnsureDirectoryChain(root, Path.GetDirectoryName(target)!);
            if (InstallRoot.PathExists(target))
            {
                if (!changedPaths.Contains(path) && !(manifestInstalled && string.Equals(path, Program.ManifestFileName, StringComparison.Ordinal)))
                {
                    continue;
                }
                throw new IOException($"Rollback target is unexpectedly occupied: {target}");
            }
            File.Move(source, target, overwrite: false);
        }
    }
}

internal static class UninstallTransaction
{
    internal static void Apply(string root, string backup, Manifest manifest, bool noShell, ShellState? shellState)
    {
        var managedPaths = manifest.Files.Select(file => file.Path).Append(Program.ManifestFileName).ToArray();
        foreach (var relativePath in managedPaths)
        {
            var target = string.Equals(relativePath, Program.ManifestFileName, StringComparison.Ordinal)
                ? Path.Combine(root, Program.ManifestFileName)
                : InstallRoot.ResolvePayloadPath(root, relativePath);
            InstallRoot.EnsureNoReparseChain(target);
            if (InstallRoot.PathExists(target) && Directory.Exists(target))
            {
                throw new SetupException(ExitCode.TargetConflict, $"The managed target {relativePath} is a directory.");
            }
        }

        var shellMutated = false;
        try
        {
            foreach (var relativePath in managedPaths)
            {
                var source = string.Equals(relativePath, Program.ManifestFileName, StringComparison.Ordinal)
                    ? Path.Combine(root, Program.ManifestFileName)
                    : InstallRoot.ResolvePayloadPath(root, relativePath);
                if (!InstallRoot.PathExists(source))
                {
                    continue;
                }
                InstallRoot.EnsureRegularFile(source);
                var destination = Path.Combine(backup, relativePath.Replace('/', Path.DirectorySeparatorChar));
                InstallRoot.EnsureDirectoryChain(backup, Path.GetDirectoryName(destination)!);
                File.Move(source, destination, overwrite: false);
            }
            if (!noShell)
            {
                shellMutated = true;
                ShellManager.Remove(root);
            }
            RemoveEmptyManagedDirectories(root, manifest.Files.Select(file => file.Path));
        }
        catch (Exception error)
        {
            Exception? rollbackError = null;
            try
            {
                if (shellMutated && shellState is not null)
                {
                    ShellManager.Restore(shellState);
                }
                foreach (var relativePath in managedPaths)
                {
                    var source = Path.Combine(backup, relativePath.Replace('/', Path.DirectorySeparatorChar));
                    if (!File.Exists(source))
                    {
                        continue;
                    }
                    var target = string.Equals(relativePath, Program.ManifestFileName, StringComparison.Ordinal)
                        ? Path.Combine(root, Program.ManifestFileName)
                        : InstallRoot.ResolvePayloadPath(root, relativePath);
                    InstallRoot.EnsureDirectoryChain(root, Path.GetDirectoryName(target)!);
                    if (InstallRoot.PathExists(target))
                    {
                        throw new IOException($"Uninstall rollback target is occupied: {target}");
                    }
                    File.Move(source, target, overwrite: false);
                }
            }
            catch (Exception rollback)
            {
                rollbackError = rollback;
            }
            if (rollbackError is not null)
            {
                throw new SetupException(ExitCode.RollbackFailure, "Uninstall failed and rollback was incomplete.", rollbackError);
            }
            if (error is SetupException setup)
            {
                throw setup;
            }
            throw new SetupException(ExitCode.IoFailure, "Uninstall failed; managed files were restored.", error);
        }
    }

    internal static void RemoveEmptyManagedDirectories(string root, IEnumerable<string> paths)
    {
        var directories = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var path in paths)
        {
            var separator = path.LastIndexOf('/');
            while (separator > 0)
            {
                var directory = path[..separator];
                directories.Add(directory);
                separator = directory.LastIndexOf('/');
            }
        }

        foreach (var relativeDirectory in directories
            .OrderByDescending(path => path.Count(character => character == '/')))
        {
            var directory = Path.Combine(root, relativeDirectory.Replace('/', Path.DirectorySeparatorChar));
            InstallRoot.EnsureNoReparseChain(directory);
            if (Directory.Exists(directory) && !Directory.EnumerateFileSystemEntries(directory).Any())
            {
                Directory.Delete(directory);
            }
        }
    }
}

internal static class ShellManager
{
    private const string UninstallKeyPath = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\Nativune";
    private static readonly string StartMenuShortcutPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.StartMenu), "Programs", "Nativune.lnk");
    private static readonly string DesktopShortcutPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Nativune.lnk");
    private static readonly string LegacyDesktopShortcutPath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "Nativune.exe.lnk");
    private static readonly string[] ManagedShortcutPaths =
    {
        StartMenuShortcutPath,
        DesktopShortcutPath,
        LegacyDesktopShortcutPath,
    };
    internal static ShellState Capture(string root)
    {
        var shortcuts = new List<ShortcutState>(ManagedShortcutPaths.Length);
        foreach (var path in ManagedShortcutPaths)
        {
            var exists = File.Exists(path);
            if (exists)
            {
                InstallRoot.EnsureNoReparseChain(path);
            }
            shortcuts.Add(new ShortcutState(path, exists, exists ? File.ReadAllBytes(path) : null));
        }

        var values = new Dictionary<string, (object Value, RegistryValueKind Kind)>(StringComparer.Ordinal);
        using var key = Registry.CurrentUser.OpenSubKey(UninstallKeyPath, writable: false);
        if (key is null)
        {
            return new ShellState(shortcuts, false, values);
        }
        foreach (var name in key.GetValueNames())
        {
            var value = key.GetValue(name, null, RegistryValueOptions.DoNotExpandEnvironmentNames);
            if (value is not null)
            {
                values[name] = (value, key.GetValueKind(name));
            }
        }
        return new ShellState(shortcuts, true, values);
    }

    internal static void Apply(string root, string version)
    {
        try
        {
            foreach (var shortcutPath in new[] { StartMenuShortcutPath, DesktopShortcutPath })
            {
                var shortcutDirectory = Path.GetDirectoryName(shortcutPath);
                if (string.IsNullOrWhiteSpace(shortcutDirectory))
                {
                    throw new IOException("A current-user shortcut directory is unavailable.");
                }
                InstallRoot.EnsureNoReparseChain(shortcutPath);
                Directory.CreateDirectory(shortcutDirectory);
                InstallRoot.EnsureNoReparseChain(shortcutDirectory);
                if (File.Exists(shortcutPath) && !IsShortcutForRoot(shortcutPath, root))
                {
                    throw new SetupException(ExitCode.TargetConflict, $"Another shortcut already occupies {shortcutPath}.");
                }
                CreateShortcut(shortcutPath, root);
            }
            if (File.Exists(LegacyDesktopShortcutPath) && IsShortcutForRoot(LegacyDesktopShortcutPath, root))
            {
                InstallRoot.EnsureNoReparseChain(LegacyDesktopShortcutPath);
                File.Delete(LegacyDesktopShortcutPath);
            }
            using var key = Registry.CurrentUser.CreateSubKey(UninstallKeyPath, writable: true)
                ?? throw new UnauthorizedAccessException("Could not open the current-user uninstall key.");
            key.SetValue("DisplayName", Program.ProductName, RegistryValueKind.String);
            key.SetValue("DisplayVersion", version, RegistryValueKind.String);
            key.SetValue("Publisher", Program.ProductName, RegistryValueKind.String);
            key.SetValue("InstallLocation", root, RegistryValueKind.String);
            key.SetValue("DisplayIcon", Path.Combine(root, Program.AppExecutable.Replace('/', Path.DirectorySeparatorChar)), RegistryValueKind.String);
            key.SetValue("UninstallString", $"{ArgumentQuoter.Quote(Path.Combine(root, "installer", Program.SetupFileName))} --uninstall --install-dir {ArgumentQuoter.Quote(root)}", RegistryValueKind.String);
            key.SetValue("NoModify", 1, RegistryValueKind.DWord);
            key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new SetupException(ExitCode.ShellFailure, "Current-user shortcut or uninstall registration failed.", error);
        }
    }

    internal static void Remove(string root)
    {
        try
        {
            foreach (var shortcutPath in ManagedShortcutPaths)
            {
                if (File.Exists(shortcutPath) && IsShortcutForRoot(shortcutPath, root))
                {
                    InstallRoot.EnsureNoReparseChain(shortcutPath);
                    File.Delete(shortcutPath);
                }
            }
            using var key = Registry.CurrentUser.OpenSubKey(UninstallKeyPath, writable: false);
            var installLocation = key?.GetValue("InstallLocation", null, RegistryValueOptions.DoNotExpandEnvironmentNames) as string;
            if (key is not null && string.Equals(Normalize(installLocation), Normalize(root), StringComparison.OrdinalIgnoreCase))
            {
                key.Dispose();
                Registry.CurrentUser.DeleteSubKeyTree(UninstallKeyPath, throwOnMissingSubKey: false);
            }
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new SetupException(ExitCode.ShellFailure, "Current-user shortcut or uninstall registration could not be removed.", error);
        }
    }

    internal static void Restore(ShellState state)
    {
        try
        {
            foreach (var shortcut in state.Shortcuts)
            {
                InstallRoot.EnsureNoReparseChain(shortcut.Path);
                if (shortcut.Exists && shortcut.Bytes is not null)
                {
                    Directory.CreateDirectory(Path.GetDirectoryName(shortcut.Path)!);
                    File.WriteAllBytes(shortcut.Path, shortcut.Bytes);
                }
                else if (File.Exists(shortcut.Path))
                {
                    File.Delete(shortcut.Path);
                }
            }

            if (!state.RegistryExists)
            {
                Registry.CurrentUser.DeleteSubKeyTree(UninstallKeyPath, throwOnMissingSubKey: false);
            }
            else
            {
                using var key = Registry.CurrentUser.CreateSubKey(UninstallKeyPath, writable: true)
                    ?? throw new UnauthorizedAccessException("Could not restore the current-user uninstall key.");
                foreach (var value in key.GetValueNames())
                {
                    key.DeleteValue(value, throwOnMissingValue: false);
                }
                foreach (var pair in state.RegistryValues)
                {
                    key.SetValue(pair.Key, pair.Value.Value, pair.Value.Kind);
                }
            }
        }
        catch (Exception error)
        {
            throw new SetupException(ExitCode.RollbackFailure, "Shell registration rollback failed.", error);
        }
    }

    internal static void TryRestore(ShellState state)
    {
        try { Restore(state); } catch { }
    }

    private static bool IsShortcutForRoot(string shortcutPath, string root)
    {
        object? shell = null;
        object? shortcut = null;
        try
        {
            var shellType = Type.GetTypeFromProgID("WScript.Shell") ?? throw new COMException("WScript.Shell is unavailable.");
            shell = Activator.CreateInstance(shellType);
            shortcut = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { shortcutPath });
            var target = shortcut?.GetType().InvokeMember("TargetPath", BindingFlags.GetProperty, null, shortcut, null) as string;
            var appPath = Path.Combine(root, Program.AppExecutable.Replace('/', Path.DirectorySeparatorChar));
            return !string.IsNullOrWhiteSpace(target) && string.Equals(Normalize(target), Normalize(appPath), StringComparison.OrdinalIgnoreCase);
        }
        finally
        {
            if (shortcut is not null && Marshal.IsComObject(shortcut)) Marshal.FinalReleaseComObject(shortcut);
            if (shell is not null && Marshal.IsComObject(shell)) Marshal.FinalReleaseComObject(shell);
        }
    }

    private static void CreateShortcut(string shortcutPath, string root)
    {
        object? shell = null;
        object? shortcut = null;
        try
        {
            var shellType = Type.GetTypeFromProgID("WScript.Shell") ?? throw new COMException("WScript.Shell is unavailable.");
            shell = Activator.CreateInstance(shellType);
            shortcut = shellType.InvokeMember("CreateShortcut", BindingFlags.InvokeMethod, null, shell, new object[] { shortcutPath });
            if (shortcut is null) throw new COMException("Could not create the Nativune shortcut.");
            var type = shortcut.GetType();
            var appPath = Path.Combine(root, Program.AppExecutable.Replace('/', Path.DirectorySeparatorChar));
            type.InvokeMember("TargetPath", BindingFlags.SetProperty, null, shortcut, new object[] { appPath });
            type.InvokeMember("Arguments", BindingFlags.SetProperty, null, shortcut, new object[] { $"web --root {ArgumentQuoter.Quote(root)}" });
            type.InvokeMember("WorkingDirectory", BindingFlags.SetProperty, null, shortcut, new object[] { root });
            type.InvokeMember("Description", BindingFlags.SetProperty, null, shortcut, new object[] { Program.ProductName });
            type.InvokeMember("IconLocation", BindingFlags.SetProperty, null, shortcut, new object[] { $"{appPath},0" });
            type.InvokeMember("Save", BindingFlags.InvokeMethod, null, shortcut, null);
        }
        finally
        {
            if (shortcut is not null && Marshal.IsComObject(shortcut)) Marshal.FinalReleaseComObject(shortcut);
            if (shell is not null && Marshal.IsComObject(shell)) Marshal.FinalReleaseComObject(shell);
        }
    }

    private static string Normalize(string? path)
    {
        if (string.IsNullOrWhiteSpace(path)) return string.Empty;
        try { return Path.GetFullPath(path).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar); }
        catch { return path.TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar); }
    }
}
