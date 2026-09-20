using System.Security.AccessControl;
using System.Security.Principal;

namespace Nativune.Installer;

internal static class InstallRoot
{
    internal static string Resolve(string? requested, bool allowTestRoot = false)
    {
        var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
        if (string.IsNullOrWhiteSpace(localAppData))
        {
            throw new SetupException(ExitCode.UnsafeRoot, "The per-user LocalAppData directory is unavailable.");
        }
        localAppData = Path.GetFullPath(localAppData)
            .TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);

        var value = string.IsNullOrWhiteSpace(requested)
            ? Path.Combine(localAppData, Program.DefaultInstallDirectoryName)
            : requested;
        if (!Path.IsPathFullyQualified(value) || value.StartsWith("\\\\", StringComparison.Ordinal) || value.StartsWith("\\\\?\\", StringComparison.Ordinal) || value.StartsWith("\\\\.\\", StringComparison.Ordinal))
        {
            throw new SetupException(ExitCode.UnsafeRoot, "--install-dir must be a fully qualified local Windows path.");
        }

        string full;
        try
        {
            full = Path.GetFullPath(value).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        }
        catch (Exception error) when (error is ArgumentException or NotSupportedException or PathTooLongException)
        {
            throw new SetupException(ExitCode.UnsafeRoot, "The install directory path is invalid.", error);
        }
        if (string.IsNullOrWhiteSpace(full) || Path.GetPathRoot(full) is null || string.Equals(full, Path.GetPathRoot(full)!.TrimEnd(Path.DirectorySeparatorChar), StringComparison.OrdinalIgnoreCase))
        {
            throw new SetupException(ExitCode.UnsafeRoot, "The install directory cannot be a drive root.");
        }
        if (!allowTestRoot && !IsWithin(localAppData, full))
        {
            throw new SetupException(ExitCode.UnsafeRoot, "The install directory must be inside the current user's LocalAppData directory.");
        }
        if (string.Equals(Path.GetFileName(full), "data", StringComparison.OrdinalIgnoreCase))
        {
            throw new SetupException(ExitCode.UnsafeRoot, "The install directory cannot itself be named data.");
        }
        RejectProtectedLocation(full);
        EnsureNoReparseChain(full);
        EnsurePrivateAcl(full);
        return full;
    }

    internal static void ValidateTarget(string root)
    {
        EnsureNoReparseChain(root);
        if (PathExists(root) && !Directory.Exists(root))
        {
            throw new SetupException(ExitCode.TargetConflict, "The install path is an existing file.");
        }
        var data = Path.Combine(root, "data");
        if (PathExists(data))
        {
            if (!Directory.Exists(data) || IsReparsePoint(data))
            {
                throw new SetupException(ExitCode.UnsafeRoot, "The install data directory is not a normal directory.");
            }
            EnsureNoReparseChain(data);
        }
    }

    internal static void ValidateFreshTarget(string root)
    {
        if (!Directory.Exists(root))
        {
            return;
        }
        foreach (var child in Directory.EnumerateFileSystemEntries(root))
        {
            var name = Path.GetFileName(child);
            if (string.Equals(name, "data", StringComparison.OrdinalIgnoreCase))
            {
                if (!Directory.Exists(child) || IsReparsePoint(child))
                {
                    throw new SetupException(ExitCode.UnsafeRoot, "The existing data directory is not safe.");
                }
                continue;
            }
            throw new SetupException(ExitCode.TargetConflict, "The existing install directory contains unmanaged files.");
        }
    }

    internal static void ValidateManagedTarget(string root, Manifest manifest)
    {
        var paths = new HashSet<string>(manifest.Files.Select(file => file.Path), StringComparer.OrdinalIgnoreCase)
        {
            Program.ManifestFileName,
        };
        foreach (var path in paths)
        {
            var target = path.Equals(Program.ManifestFileName, StringComparison.Ordinal)
                ? Path.Combine(root, Program.ManifestFileName)
                : ResolvePayloadPath(root, path);
            EnsureNoReparseChain(target);
            if (PathExists(target) && Directory.Exists(target))
            {
                throw new SetupException(ExitCode.TargetConflict, $"The managed target {path} is a directory.");
            }
        }
    }

    internal static string CreateAdjacentDirectory(string root, string prefix)
    {
        var parent = Directory.GetParent(root)?.FullName;
        if (string.IsNullOrWhiteSpace(parent))
        {
            throw new SetupException(ExitCode.UnsafeRoot, "The install directory has no writable parent.");
        }
        EnsureNoReparseChain(parent);
        try
        {
            Directory.CreateDirectory(parent);
            for (var attempt = 0; attempt < 5; attempt++)
            {
                var candidate = Path.Combine(parent, $"{prefix}-{Guid.NewGuid():N}");
                if (PathExists(candidate))
                {
                    continue;
                }
                CreateSafeDirectory(candidate);
                return candidate;
            }
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new SetupException(ExitCode.IoFailure, "The setup staging directory could not be created.", error);
        }
        throw new SetupException(ExitCode.IoFailure, "The setup staging directory name could not be allocated.");
    }

    internal static void CreateSafeDirectory(string path)
    {
        EnsureNoReparseChain(path);
        if (!Directory.Exists(path))
        {
            var security = CreatePrivateDirectorySecurity();
            FileSystemAclExtensions.Create(new DirectoryInfo(path), security);
        }
        EnsureNoReparseChain(path);
        EnsurePrivateAcl(path);
    }

    internal static void EnsureDirectory(string path)
    {
        if (!Directory.Exists(path) || IsReparsePoint(path))
        {
            throw new SetupException(ExitCode.InvalidPayload, $"The payload directory is missing or is a reparse point: {path}");
        }
    }

    internal static void EnsureDirectoryChain(string root, string directory)
    {
        var fullRoot = Path.GetFullPath(root);
        var fullDirectory = Path.GetFullPath(directory);
        if (!IsWithin(fullRoot, fullDirectory))
        {
            throw new SetupException(ExitCode.InvalidPayload, "A payload path escaped its staging directory.");
        }
        EnsureNoReparseChain(fullDirectory);
        Directory.CreateDirectory(fullDirectory);
        EnsureNoReparseChain(fullDirectory);
    }

    internal static string ResolvePayloadPath(string root, string relativePath)
    {
        Manifest.ValidateRelativePath(relativePath, requireAllowedRoot: true);
        var combined = Path.Combine(root, relativePath.Replace('/', Path.DirectorySeparatorChar));
        var full = Path.GetFullPath(combined);
        if (!IsWithin(root, full))
        {
            throw new SetupException(ExitCode.InvalidPayload, "A payload path escaped the install root.");
        }
        return full;
    }

    internal static void EnsureRegularFile(string path)
    {
        EnsureNoReparseChain(path);
        if (!File.Exists(path) || Directory.Exists(path))
        {
            throw new SetupException(ExitCode.InvalidPayload, $"Required file is missing: {path}");
        }
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
        {
            throw new SetupException(ExitCode.InvalidPayload, $"Required file is a reparse point: {path}");
        }
    }

    internal static void EnsureNoReparseTree(string root)
    {
        EnsureDirectory(root);
        var pending = new Stack<string>();
        pending.Push(root);
        while (pending.Count > 0)
        {
            var current = pending.Pop();
            if (IsReparsePoint(current))
            {
                throw new SetupException(ExitCode.InvalidPayload, $"A payload tree contains a reparse point: {current}");
            }
            foreach (var child in Directory.EnumerateFileSystemEntries(current))
            {
                if (IsReparsePoint(child))
                {
                    throw new SetupException(ExitCode.InvalidPayload, $"A payload tree contains a reparse point: {child}");
                }
                if (Directory.Exists(child))
                {
                    pending.Push(child);
                }
            }
        }
    }

    internal static void EnsureNoReparseChain(string path)
    {
        var full = Path.GetFullPath(path);
        var current = full;
        while (true)
        {
            if (PathExists(current) && IsReparsePoint(current))
            {
                throw new SetupException(ExitCode.UnsafeRoot, $"The path contains a reparse point: {current}");
            }
            var parent = Directory.GetParent(current)?.FullName;
            if (string.IsNullOrEmpty(parent) || string.Equals(parent, current, StringComparison.OrdinalIgnoreCase))
            {
                break;
            }
            current = parent;
        }
    }

    internal static bool IsWithin(string root, string candidate)
    {
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullCandidate = Path.GetFullPath(candidate).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        return string.Equals(fullRoot, fullCandidate, StringComparison.OrdinalIgnoreCase) ||
               fullCandidate.StartsWith(fullRoot + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) ||
               fullCandidate.StartsWith(fullRoot + Path.AltDirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    internal static bool PathExists(string path)
    {
        return File.Exists(path) || Directory.Exists(path);
    }

    internal static bool IsReparsePoint(string path)
    {
        try
        {
            return (File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0;
        }
        catch (FileNotFoundException)
        {
            return false;
        }
        catch (DirectoryNotFoundException)
        {
            return false;
        }
        catch (IOException)
        {
            throw new SetupException(ExitCode.UnsafeRoot, $"Could not inspect path safety: {path}");
        }
        catch (UnauthorizedAccessException error)
        {
            throw new SetupException(ExitCode.UnsafeRoot, $"Could not inspect path safety: {path}", error);
        }
    }

    internal static void TryDeleteDirectory(string? path)
    {
        if (string.IsNullOrWhiteSpace(path) || !Directory.Exists(path))
        {
            return;
        }
        try
        {
            EnsureNoReparseChain(path);
            Directory.Delete(path, recursive: true);
        }
        catch
        {
            // A leftover adjacent staging directory is safer than following or deleting
            // an unexpected path after a failed transaction.
        }
    }

    private static void EnsurePrivateAcl(string path)
    {
        try
        {
            var exactDirectoryExists = Directory.Exists(path);
            var existing = path;
            while (!Directory.Exists(existing))
            {
                var parent = Directory.GetParent(existing)?.FullName;
                if (string.IsNullOrWhiteSpace(parent))
                {
                    throw new SetupException(ExitCode.UnsafeRoot, "The install directory has no existing security boundary.");
                }
                existing = parent;
            }

            var currentUser = CurrentUserSid();
            var system = new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null);
            var administrators = new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null);
            var creatorOwner = new SecurityIdentifier(WellKnownSidType.CreatorOwnerSid, null);
            var ownerRights = new SecurityIdentifier("S-1-3-4");
            var security = FileSystemAclExtensions.GetAccessControl(
                new DirectoryInfo(existing),
                AccessControlSections.Access | AccessControlSections.Owner);
            var owner = security.GetOwner(typeof(SecurityIdentifier)) as SecurityIdentifier;
            if (owner is null || (!owner.Equals(currentUser) && !owner.Equals(administrators)))
            {
                throw new SetupException(ExitCode.UnsafeRoot, "The install directory is not owned by the current user.");
            }

            // A missing install directory inherits only briefly while it is being created.
            // CreateSafeDirectory installs a protected DACL before any payload is written.
            // Extra writers on LocalAppData itself therefore do not become install writers.
            if (!exactDirectoryExists)
            {
                return;
            }

            const FileSystemRights writeRights =
                FileSystemRights.Write |
                FileSystemRights.Modify |
                FileSystemRights.FullControl |
                FileSystemRights.Delete |
                FileSystemRights.DeleteSubdirectoriesAndFiles |
                FileSystemRights.ChangePermissions |
                FileSystemRights.TakeOwnership;
            foreach (FileSystemAccessRule rule in security.GetAccessRules(
                includeExplicit: true,
                includeInherited: true,
                targetType: typeof(SecurityIdentifier)))
            {
                if (rule.AccessControlType != AccessControlType.Allow
                    || (rule.FileSystemRights & writeRights) == 0)
                {
                    continue;
                }

                var identity = (SecurityIdentifier)rule.IdentityReference;
                if (!identity.Equals(currentUser)
                    && !identity.Equals(system)
                    && !identity.Equals(administrators)
                    && !identity.Equals(creatorOwner)
                    && !identity.Equals(ownerRights))
                {
                    throw new SetupException(ExitCode.UnsafeRoot, "The install directory grants write access to another Windows principal.");
                }
            }
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new SetupException(ExitCode.UnsafeRoot, "The install directory security could not be verified.", error);
        }
    }

    private static DirectorySecurity CreatePrivateDirectorySecurity()
    {
        var security = new DirectorySecurity();
        security.SetAccessRuleProtection(isProtected: true, preserveInheritance: false);
        security.SetOwner(CurrentUserSid());
        const FileSystemRights rights = FileSystemRights.FullControl;
        const InheritanceFlags inheritance = InheritanceFlags.ContainerInherit | InheritanceFlags.ObjectInherit;
        security.AddAccessRule(new FileSystemAccessRule(
            CurrentUserSid(), rights, inheritance, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.LocalSystemSid, null),
            rights, inheritance, PropagationFlags.None, AccessControlType.Allow));
        security.AddAccessRule(new FileSystemAccessRule(
            new SecurityIdentifier(WellKnownSidType.BuiltinAdministratorsSid, null),
            rights, inheritance, PropagationFlags.None, AccessControlType.Allow));
        return security;
    }

    private static SecurityIdentifier CurrentUserSid()
        => WindowsIdentity.GetCurrent().User
            ?? throw new SetupException(ExitCode.UnsafeRoot, "The current Windows user SID is unavailable.");

    private static void RejectProtectedLocation(string full)
    {
        var protectedRoots = new[]
        {
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            Environment.GetFolderPath(Environment.SpecialFolder.System),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonProgramFiles),
            Environment.GetFolderPath(Environment.SpecialFolder.CommonProgramFilesX86),
        };
        foreach (var protectedRoot in protectedRoots.Where(path => !string.IsNullOrWhiteSpace(path)))
        {
            var normalized = Path.GetFullPath(protectedRoot).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
            if (string.Equals(full, normalized, StringComparison.OrdinalIgnoreCase) ||
                full.StartsWith(normalized + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
            {
                throw new SetupException(ExitCode.UnsafeRoot, "The install directory is inside a protected Windows root.");
            }
        }
    }
}

internal static class PathSafety
{
    internal static void EnsureRegularFile(string path) => InstallRoot.EnsureRegularFile(path);
    internal static void EnsureDirectory(string path) => InstallRoot.EnsureDirectory(path);
    internal static void EnsureNoReparseTree(string path) => InstallRoot.EnsureNoReparseTree(path);
    internal static string ResolvePayloadPath(string root, string path) => InstallRoot.ResolvePayloadPath(root, path);
    internal static void EnsureDirectoryChain(string root, string directory) => InstallRoot.EnsureDirectoryChain(root, directory);
}
