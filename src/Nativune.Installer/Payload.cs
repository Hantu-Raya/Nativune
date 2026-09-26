using System.Buffers.Binary;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Text;

namespace Nativune.Installer;

internal sealed record PayloadFile(string Path, long Length, string Sha256);

internal sealed class Manifest
{
    internal const int MaxManifestBytes = 16 * 1024 * 1024;
    internal const int MaxFileCount = 10_000;
    internal const long MaxFileBytes = 1L * 1024 * 1024 * 1024;
    internal const long MaxTotalBytes = 2L * 1024 * 1024 * 1024;
    internal const long MaxArchiveBytes = 1L * 1024 * 1024 * 1024;
    private static readonly Regex Semver = new(
        "^(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)\\.(0|[1-9][0-9]*)(?:-[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?(?:\\+[0-9A-Za-z-]+(?:\\.[0-9A-Za-z-]+)*)?$",
        RegexOptions.CultureInvariant | RegexOptions.NonBacktracking);
    private static readonly HashSet<string> AllowedRoots = new(StringComparer.OrdinalIgnoreCase)
    {
        "app", ".tools", "installer", "licenses",
    };

    private Manifest(int schemaVersion, string product, string version, string executable, IReadOnlyList<PayloadFile> files)
    {
        SchemaVersion = schemaVersion;
        Product = product;
        Version = version;
        Executable = executable;
        Files = files;
    }

    internal int SchemaVersion { get; }
    internal string Product { get; }
    internal string Version { get; }
    internal string Executable { get; }
    internal IReadOnlyList<PayloadFile> Files { get; }

    internal static bool IsValidVersionText(string? value)
        => value is not null && Semver.IsMatch(value);

    internal static int CompareVersions(string left, string right)
    {
        var leftParts = SplitVersion(left);
        var rightParts = SplitVersion(right);
        for (var index = 0; index < 3; index++)
        {
            var comparison = CompareNumericText(leftParts.Core[index], rightParts.Core[index]);
            if (comparison != 0)
            {
                return comparison;
            }
        }

        if (leftParts.PreRelease.Length == 0 && rightParts.PreRelease.Length == 0)
        {
            return 0;
        }
        if (leftParts.PreRelease.Length == 0)
        {
            return 1;
        }
        if (rightParts.PreRelease.Length == 0)
        {
            return -1;
        }

        var count = Math.Min(leftParts.PreRelease.Length, rightParts.PreRelease.Length);
        for (var index = 0; index < count; index++)
        {
            var leftIdentifier = leftParts.PreRelease[index];
            var rightIdentifier = rightParts.PreRelease[index];
            var leftNumeric = leftIdentifier.All(character => character is >= '0' and <= '9');
            var rightNumeric = rightIdentifier.All(character => character is >= '0' and <= '9');
            int comparison;
            if (leftNumeric && rightNumeric)
            {
                comparison = CompareNumericText(leftIdentifier, rightIdentifier);
            }
            else if (leftNumeric != rightNumeric)
            {
                comparison = leftNumeric ? -1 : 1;
            }
            else
            {
                comparison = string.CompareOrdinal(leftIdentifier, rightIdentifier);
            }
            if (comparison != 0)
            {
                return comparison;
            }
        }
        return leftParts.PreRelease.Length.CompareTo(rightParts.PreRelease.Length);
    }

    private static (string[] Core, string[] PreRelease) SplitVersion(string value)
    {
        var withoutBuild = value.Split('+', 2)[0];
        var pieces = withoutBuild.Split('-', 2);
        return (
            pieces[0].Split('.', StringSplitOptions.None),
            pieces.Length == 2 ? pieces[1].Split('.', StringSplitOptions.None) : Array.Empty<string>());
    }

    private static int CompareNumericText(string left, string right)
    {
        left = left.TrimStart('0');
        right = right.TrimStart('0');
        if (left.Length == 0) left = "0";
        if (right.Length == 0) right = "0";
        var comparison = left.Length.CompareTo(right.Length);
        return comparison != 0 ? comparison : string.CompareOrdinal(left, right);
    }

    internal static Manifest Parse(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length > MaxManifestBytes)
        {
            throw new SetupException(ExitCode.InvalidPayload, "The release manifest is too large.");
        }

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(bytes.ToArray());
        }
        catch (Exception error) when (error is JsonException or ArgumentException)
        {
            throw new SetupException(ExitCode.InvalidPayload, "The release manifest is malformed.", error);
        }

        using (document)
        {
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release manifest must be a JSON object.");
            }

            var properties = ReadProperties(document.RootElement, "manifest");
            RequireExact(properties, "schemaVersion", "product", "version", "executable", "files");
            var schemaVersion = ReadInt32(properties["schemaVersion"], "schemaVersion");
            var product = ReadString(properties["product"], "product", maxLength: 128);
            var version = ReadString(properties["version"], "version", maxLength: 128);
            var executable = ReadString(properties["executable"], "executable", maxLength: 512);
            if (schemaVersion != 1 || !string.Equals(product, Program.ProductName, StringComparison.Ordinal))
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release manifest has an unsupported schema or product.");
            }
            if (!Semver.IsMatch(version))
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release manifest version is not valid semantic version text.");
            }
            ValidateRelativePath(executable, requireAllowedRoot: true);
            if (!string.Equals(executable, Program.AppExecutable, StringComparison.Ordinal))
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release manifest executable is not app/Nativune.exe.");
            }

            var filesElement = properties["files"];
            if (filesElement.ValueKind != JsonValueKind.Array || filesElement.GetArrayLength() == 0 || filesElement.GetArrayLength() > MaxFileCount)
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release manifest file list is missing or too large.");
            }

            var files = new List<PayloadFile>(filesElement.GetArrayLength());
            var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            long totalLength = 0;
            foreach (var fileElement in filesElement.EnumerateArray())
            {
                if (fileElement.ValueKind != JsonValueKind.Object)
                {
                    throw new SetupException(ExitCode.InvalidPayload, "A release manifest file entry is not an object.");
                }
                var fileProperties = ReadProperties(fileElement, "file entry");
                RequireExact(fileProperties, "path", "length", "sha256");
                var path = ReadString(fileProperties["path"], "file path", maxLength: 512);
                ValidateRelativePath(path, requireAllowedRoot: true);
                if (string.Equals(path, Program.ManifestFileName, StringComparison.OrdinalIgnoreCase))
                {
                    throw new SetupException(ExitCode.InvalidPayload, "The release manifest cannot list itself as a payload file.");
                }
                if (!paths.Add(path))
                {
                    throw new SetupException(ExitCode.InvalidPayload, "The release manifest contains duplicate or case-colliding paths.");
                }
                var length = ReadInt64(fileProperties["length"], "file length");
                if (length < 0 || length > MaxFileBytes)
                {
                    throw new SetupException(ExitCode.InvalidPayload, "A release manifest file length is outside the permitted range.");
                }
                totalLength = checked(totalLength + length);
                if (totalLength > MaxTotalBytes)
                {
                    throw new SetupException(ExitCode.InvalidPayload, "The release manifest payload is too large.");
                }
                var hash = ReadString(fileProperties["sha256"], "file hash", maxLength: 64);
                if (hash.Length != 64 || hash.Any(character => !Uri.IsHexDigit(character)))
                {
                    throw new SetupException(ExitCode.InvalidPayload, "A release manifest SHA-256 value is invalid.");
                }
                files.Add(new PayloadFile(path, length, hash.ToLowerInvariant()));
            }

            RequirePath(paths, Program.AppExecutable);
            RequirePath(paths, "installer/Nativune.Setup.exe");
            RequirePath(paths, ".tools/ubol/2026.907.2003/LICENSE.txt");
            RequirePath(paths, ".tools/ubol/2026.907.2003/manifest.json");
            RequirePath(paths, "licenses/Microsoft-WindowsAppSDK.txt");
            RequirePath(paths, "licenses/Microsoft-DotNet-LICENSE.txt");
            RequirePath(paths, "licenses/Microsoft-DotNet-ThirdPartyNotices.txt");
            RequirePath(paths, "licenses/Microsoft-WebView2-SDK-LICENSE.txt");
            RequirePath(paths, "licenses/Microsoft-WebView2-SDK-NOTICE.txt");

            RequirePath(paths, "licenses/Nativune-LICENSE.txt");
            RequirePath(paths, "licenses/THIRD-PARTY-NOTICES.txt");
            return new Manifest(schemaVersion, product, version, executable, files);
        }
    }

    internal static Manifest Load(string path)
    {
        try
        {
            PathSafety.EnsureRegularFile(path);
            var info = new FileInfo(path);
            if (info.Length > MaxManifestBytes)
            {
                throw new SetupException(ExitCode.TargetConflict, "The installed release manifest is too large.");
            }
            return Parse(File.ReadAllBytes(path));
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new SetupException(ExitCode.TargetConflict, "The installed release manifest could not be read.", error);
        }
    }

    internal static void ValidateExtractedTools(string stage)
    {
        var ubolRoot = Path.Combine(stage, ".tools", "ubol", "2026.907.2003");
        PathSafety.EnsureRegularFile(Path.Combine(ubolRoot, "LICENSE.txt"));
        PathSafety.EnsureRegularFile(Path.Combine(ubolRoot, "manifest.json"));
    }

    private static Dictionary<string, JsonElement> ReadProperties(JsonElement element, string label)
    {
        var result = new Dictionary<string, JsonElement>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
        {
            if (!result.TryAdd(property.Name, property.Value))
            {
                throw new SetupException(ExitCode.InvalidPayload, $"The release manifest contains a duplicate {label} property.");
            }
        }
        return result;
    }

    private static void RequireExact(Dictionary<string, JsonElement> properties, params string[] names)
    {
        if (properties.Count != names.Length || names.Any(name => !properties.ContainsKey(name)))
        {
            throw new SetupException(ExitCode.InvalidPayload, "The release manifest contains unexpected or missing properties.");
        }
    }

    private static string ReadString(JsonElement value, string label, int maxLength)
    {
        if (value.ValueKind != JsonValueKind.String)
        {
            throw new SetupException(ExitCode.InvalidPayload, $"The release manifest {label} is not text.");
        }
        var text = value.GetString();
        if (string.IsNullOrEmpty(text) || text.Length > maxLength)
        {
            throw new SetupException(ExitCode.InvalidPayload, $"The release manifest {label} is empty or too long.");
        }
        return text;
    }

    private static int ReadInt32(JsonElement value, string label)
    {
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt32(out var number))
        {
            throw new SetupException(ExitCode.InvalidPayload, $"The release manifest {label} is not a 32-bit integer.");
        }
        return number;
    }

    private static long ReadInt64(JsonElement value, string label)
    {
        if (value.ValueKind != JsonValueKind.Number || !value.TryGetInt64(out var number))
        {
            throw new SetupException(ExitCode.InvalidPayload, $"The release manifest {label} is not a 64-bit integer.");
        }
        return number;
    }

    private static void RequirePath(HashSet<string> paths, string expected)
    {
        if (!paths.Contains(expected))
        {
            throw new SetupException(ExitCode.InvalidPayload, $"The release manifest is missing required file {expected}.");
        }
    }

    internal static void ValidateRelativePath(string path, bool requireAllowedRoot)
    {
        if (string.IsNullOrEmpty(path) || path.Length > 512 || path.Contains('\\') || path.Contains(':') ||
            path.StartsWith('/') || path.EndsWith('/') || Path.IsPathRooted(path))
        {
            throw new SetupException(ExitCode.InvalidPayload, "A release manifest path is absolute, malformed, or uses a backslash.");
        }
        var segments = path.Split('/');
        if (segments.Length == 0 || segments.Any(segment => segment.Length == 0 || segment is "." or ".."))
        {
            throw new SetupException(ExitCode.InvalidPayload, "A release manifest path contains traversal or an empty component.");
        }
        if (requireAllowedRoot && !AllowedRoots.Contains(segments[0]))
        {
            throw new SetupException(ExitCode.InvalidPayload, "A release manifest path uses an unexpected top-level directory.");
        }
        if (segments.Any(segment => string.Equals(segment, "data", StringComparison.OrdinalIgnoreCase)))
        {
            throw new SetupException(ExitCode.InvalidPayload, "A release manifest path may not enter the data directory.");
        }
    }
}

internal static class PayloadReader
{
    private const int FooterSize = 32;
    private const uint FooterVersion = 1;
    private static readonly byte[] FooterMagic = "NATIVN01"u8.ToArray();
    internal static Manifest ReadPackagedManifest(string setupPath)
    {
        try
        {
            PathSafety.EnsureRegularFile(setupPath);
            using var file = new FileStream(setupPath, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, FileOptions.SequentialScan);
            var (offset, length) = ReadFooter(file);

            using var bounded = new BoundedReadStream(file, offset, length);
            using var archive = new ZipArchive(bounded, ZipArchiveMode.Read, leaveOpen: false, entryNameEncoding: Encoding.UTF8);
            if (archive.Entries.Count == 0 || archive.Entries.Count > Manifest.MaxFileCount + 1)
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release archive has an invalid entry count.");
            }
            ZipArchiveEntry? manifestEntry = null;
            foreach (var entry in archive.Entries)
            {
                if (!string.Equals(entry.FullName, Program.ManifestFileName, StringComparison.Ordinal))
                {
                    continue;
                }
                if (manifestEntry is not null)
                {
                    throw new SetupException(ExitCode.InvalidPayload, "The release archive contains duplicate manifests.");
                }
                var mode = (entry.ExternalAttributes >> 16) & 0xF000;
                if (mode == 0xA000 || (entry.ExternalAttributes & (int)FileAttributes.ReparsePoint) != 0)
                {
                    throw new SetupException(ExitCode.InvalidPayload, "The release manifest is a link or reparse-point entry.");
                }
                manifestEntry = entry;
            }
            if (manifestEntry is null)
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release archive has no release manifest.");
            }
            return Manifest.Parse(ReadEntry(manifestEntry, Manifest.MaxManifestBytes));
        }
        catch (SetupException)
        {
            throw;
        }
        catch (InvalidDataException error)
        {
            throw new SetupException(ExitCode.InvalidPayload, "The release archive is not a valid ZIP payload.", error);
        }
        catch (Exception error)
        {
            throw new SetupException(ExitCode.IoFailure, "The release payload could not be read.", error);
        }
    }

    internal static Manifest ExtractVerified(
        string setupPath,
        string stage,
        ISetupReporter? reporter = null,
        CancellationToken cancellationToken = default)
    {
        try
        {
            PathSafety.EnsureRegularFile(setupPath);
            using var file = new FileStream(setupPath, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, FileOptions.SequentialScan);
            var (offset, length) = ReadFooter(file);

            using var bounded = new BoundedReadStream(file, offset, length);
            using var archive = new ZipArchive(bounded, ZipArchiveMode.Read, leaveOpen: false, entryNameEncoding: Encoding.UTF8);
            if (archive.Entries.Count == 0 || archive.Entries.Count > Manifest.MaxFileCount + 1)
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release archive has an invalid entry count.");
            }

            var entries = new Dictionary<string, ZipArchiveEntry>(StringComparer.OrdinalIgnoreCase);
            ZipArchiveEntry? manifestEntry = null;
            foreach (var entry in archive.Entries)
            {
                if (entry.FullName.Length == 0 || entry.FullName.EndsWith('/') || entry.FullName.Contains('\\'))
                {
                    throw new SetupException(ExitCode.InvalidPayload, "The release archive contains a directory or malformed path entry.");
                }
                Manifest.ValidateRelativePath(entry.FullName, requireAllowedRoot: false);
                if (!entries.TryAdd(entry.FullName, entry))
                {
                    throw new SetupException(ExitCode.InvalidPayload, "The release archive contains duplicate or case-colliding paths.");
                }
                var mode = (entry.ExternalAttributes >> 16) & 0xF000;
                if (mode == 0xA000 || (entry.ExternalAttributes & (int)FileAttributes.ReparsePoint) != 0)
                {
                    throw new SetupException(ExitCode.InvalidPayload, "The release archive contains a link or reparse-point entry.");
                }
                if (string.Equals(entry.FullName, Program.ManifestFileName, StringComparison.Ordinal))
                {
                    manifestEntry = entry;
                }
            }
            if (manifestEntry is null)
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release archive has no release manifest.");
            }
            var manifestBytes = ReadEntry(manifestEntry, Manifest.MaxManifestBytes);
            var manifest = Manifest.Parse(manifestBytes);
            if (manifest.Files.Any(file => file.Path.StartsWith(".tools/webview2/", StringComparison.OrdinalIgnoreCase)))
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release payload must use the shared WebView2 runtime and cannot bundle a fixed runtime.");
            }
            if (entries.Count != manifest.Files.Count + 1)
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release archive contains unexpected entries.");
            }
            InstallRoot.CreateSafeDirectory(stage);
            EnsureFreeSpace(stage, manifest.Files.Sum(payloadFile => payloadFile.Length));
            var stagedManifestPath = Path.Combine(stage, Program.ManifestFileName);
            File.WriteAllBytes(stagedManifestPath, manifestBytes);
            var completedFiles = 0;
            reporter?.Step($"Unpacking Nativune v{manifest.Version} (0 of {manifest.Files.Count:N0} files)", cancellable: true);
            reporter?.Progress(0, manifest.Files.Count);
            foreach (var payloadFile in manifest.Files)
            {
                cancellationToken.ThrowIfCancellationRequested();
                if (!entries.TryGetValue(payloadFile.Path, out var entry))
                {
                    throw new SetupException(ExitCode.InvalidPayload, "The release archive is missing a file listed in its manifest.");
                }
                var destination = PathSafety.ResolvePayloadPath(stage, payloadFile.Path);
                PathSafety.EnsureDirectoryChain(stage, Path.GetDirectoryName(destination)!);
                ExtractAndHash(entry, destination, payloadFile);
                completedFiles++;
                reporter?.Step($"Unpacking Nativune v{manifest.Version} ({completedFiles:N0} of {manifest.Files.Count:N0} files)", cancellable: true);
                reporter?.Progress(completedFiles, manifest.Files.Count);
            }
            cancellationToken.ThrowIfCancellationRequested();
            Manifest.ValidateExtractedTools(stage);
            return manifest;
        }
        catch (SetupException)
        {
            InstallRoot.TryDeleteDirectory(stage);
            throw;
        }
        catch (OperationCanceledException)
        {
            InstallRoot.TryDeleteDirectory(stage);
            throw;
        }
        catch (InvalidDataException error)
        {
            InstallRoot.TryDeleteDirectory(stage);
            throw new SetupException(ExitCode.InvalidPayload, "The release archive is not a valid ZIP payload.", error);
        }
        catch (Exception error)
        {
            InstallRoot.TryDeleteDirectory(stage);
            throw new SetupException(ExitCode.IoFailure, "The release payload could not be staged.", error);
        }
    }

    internal static byte[] ReadDeltaManifestBytes(string deltaDir, string expectedManifestSha256)
    {
        try
        {
            InstallRoot.EnsureNoReparseTree(deltaDir);
            var manifestPath = Path.Combine(deltaDir, Program.ManifestFileName);
            if (!File.Exists(manifestPath) || Directory.Exists(manifestPath) || InstallRoot.IsReparsePoint(manifestPath))
            {
                throw new SetupException(ExitCode.InvalidPayload, DeltaFailure("The update has no regular release manifest."));
            }
            using var file = new FileStream(manifestPath, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (file.Length <= 0 || file.Length > Manifest.MaxManifestBytes)
            {
                throw new SetupException(ExitCode.InvalidPayload, DeltaFailure("The update release manifest has an invalid size."));
            }
            var bytes = new byte[file.Length];
            file.ReadExactly(bytes);
            if (file.ReadByte() != -1
                || !Convert.ToHexString(SHA256.HashData(bytes)).Equals(expectedManifestSha256, StringComparison.OrdinalIgnoreCase))
            {
                throw new SetupException(ExitCode.InvalidPayload, DeltaFailure("The update release manifest does not match the expected SHA-256."));
            }
            return bytes;
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new SetupException(ExitCode.InvalidPayload, DeltaFailure("The update release manifest could not be read."), error);
        }
    }

    // Builds a stage identical to ExtractVerified's from downloaded delta files plus unchanged installed files.
    internal static Manifest BuildStageFromDelta(
        string root,
        string deltaDir,
        string expectedManifestSha256,
        string stage,
        ISetupReporter? reporter = null,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var manifestBytes = ReadDeltaManifestBytes(deltaDir, expectedManifestSha256);
            var manifest = Manifest.Parse(manifestBytes);
            if (manifest.Files.Any(file => file.Path.StartsWith(".tools/webview2/", StringComparison.OrdinalIgnoreCase)))
            {
                throw new SetupException(ExitCode.InvalidPayload, "The release payload must use the shared WebView2 runtime and cannot bundle a fixed runtime.");
            }
            var targets = new Dictionary<string, PayloadFile>(StringComparer.OrdinalIgnoreCase);
            foreach (var payloadFile in manifest.Files)
            {
                if (!targets.TryAdd(payloadFile.Path, payloadFile))
                {
                    throw new SetupException(ExitCode.InvalidPayload, "The release manifest contains duplicate or case-colliding paths.");
                }
            }

            var fullDelta = Path.GetFullPath(deltaDir).TrimEnd(Path.DirectorySeparatorChar);
            var present = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            foreach (var entry in Directory.EnumerateFileSystemEntries(fullDelta, "*", SearchOption.AllDirectories))
            {
                if (InstallRoot.IsReparsePoint(entry))
                {
                    throw new SetupException(ExitCode.InvalidPayload, DeltaFailure("The update contains a reparse point."));
                }
                if (Directory.Exists(entry))
                {
                    continue;
                }
                var relative = Path.GetRelativePath(fullDelta, entry).Replace(Path.DirectorySeparatorChar, '/');
                if (string.Equals(relative, Program.ManifestFileName, StringComparison.Ordinal))
                {
                    continue;
                }
                if (!File.Exists(entry) || !targets.TryGetValue(relative, out var target)
                    || !string.Equals(target.Path, relative, StringComparison.Ordinal))
                {
                    throw new SetupException(ExitCode.InvalidPayload, DeltaFailure("The update contains a file that is not in the release manifest."));
                }
                present.Add(relative);
            }

            InstallRoot.CreateSafeDirectory(stage);
            EnsureFreeSpace(stage, manifest.Files.Sum(payloadFile => payloadFile.Length));
            File.WriteAllBytes(Path.Combine(stage, Program.ManifestFileName), manifestBytes);
            var completedFiles = 0;
            reporter?.Step($"Preparing Nativune v{manifest.Version} (0 of {manifest.Files.Count:N0} files)", cancellable: true);
            reporter?.Progress(0, manifest.Files.Count);
            foreach (var payloadFile in manifest.Files)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var destination = PathSafety.ResolvePayloadPath(stage, payloadFile.Path);
                PathSafety.EnsureDirectoryChain(stage, Path.GetDirectoryName(destination)!);
                if (present.Contains(payloadFile.Path))
                {
                    var source = PathSafety.ResolvePayloadPath(fullDelta, payloadFile.Path);
                    RequireRegularDeltaFile(source, payloadFile.Path);
                    File.Move(source, destination);
                    // Verified after the move so the staged bytes are the ones checked.
                    if (!FileMatches(destination, payloadFile))
                    {
                        throw new SetupException(ExitCode.InvalidPayload, DeltaFailure($"The downloaded file {payloadFile.Path} does not match its manifest."));
                    }
                }
                else
                {
                    var installed = PathSafety.ResolvePayloadPath(root, payloadFile.Path);
                    RequireRegularDeltaFile(installed, payloadFile.Path);
                    using (var input = new FileStream(installed, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, FileOptions.SequentialScan))
                    using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, FileOptions.SequentialScan))
                    {
                        if (!CopyAndHash(input, output, payloadFile))
                        {
                            throw new SetupException(ExitCode.InvalidPayload, DeltaFailure($"The installed file {payloadFile.Path} does not match the new release."));
                        }
                    }
                }
                completedFiles++;
                reporter?.Step($"Preparing Nativune v{manifest.Version} ({completedFiles:N0} of {manifest.Files.Count:N0} files)", cancellable: true);
                reporter?.Progress(completedFiles, manifest.Files.Count);
            }
            cancellationToken.ThrowIfCancellationRequested();
            Manifest.ValidateExtractedTools(stage);
            return manifest;
        }
        catch (SetupException)
        {
            InstallRoot.TryDeleteDirectory(stage);
            throw;
        }
        catch (OperationCanceledException)
        {
            InstallRoot.TryDeleteDirectory(stage);
            throw;
        }
        catch (Exception error)
        {
            InstallRoot.TryDeleteDirectory(stage);
            throw new SetupException(ExitCode.IoFailure, "The update payload could not be staged.", error);
        }
    }

    private static string DeltaFailure(string reason) =>
        $"{reason}\n\nThe update could not be applied from its downloaded changes. Download and run the full Nativune Setup instead.";

    private static void RequireRegularDeltaFile(string path, string relative)
    {
        if (!File.Exists(path) || Directory.Exists(path) || InstallRoot.IsReparsePoint(path))
        {
            throw new SetupException(ExitCode.InvalidPayload, DeltaFailure($"The file {relative} is missing or is not a regular file."));
        }
        try
        {
            InstallRoot.EnsureNoReparseChain(path);
        }
        catch (SetupException error)
        {
            throw new SetupException(ExitCode.InvalidPayload, DeltaFailure($"The file {relative} is behind a reparse point."), error);
        }
    }

    private static bool FileMatches(string path, PayloadFile expected)
    {
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, FileOptions.SequentialScan);
        return CopyAndHash(input, Stream.Null, expected);
    }

    private static bool CopyAndHash(Stream source, Stream output, PayloadFile expected)
    {
        if (source.Length != expected.Length)
        {
            return false;
        }
        using var hash = SHA256.Create();
        var buffer = new byte[128 * 1024];
        long total = 0;
        while (true)
        {
            var read = source.Read(buffer, 0, buffer.Length);
            if (read == 0)
            {
                break;
            }
            total = checked(total + read);
            if (total > expected.Length)
            {
                return false;
            }
            output.Write(buffer, 0, read);
            hash.TransformBlock(buffer, 0, read, buffer, 0);
        }
        hash.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
        return total == expected.Length && Convert.ToHexString(hash.Hash!).Equals(expected.Sha256, StringComparison.OrdinalIgnoreCase);
    }

    private static byte[] ReadEntry(ZipArchiveEntry entry, int maxLength)
    {
        if (entry.Length < 0 || entry.Length > maxLength)
        {
            throw new SetupException(ExitCode.InvalidPayload, "A release archive entry is too large.");
        }
        using var source = entry.Open();
        using var destination = new MemoryStream((int)entry.Length);
        var buffer = new byte[Math.Min(128 * 1024, Math.Max(1, maxLength))];
        long total = 0;
        while (true)
        {
            var read = source.Read(buffer, 0, buffer.Length);
            if (read == 0)
            {
                break;
            }
            total += read;
            if (total > maxLength)
            {
                throw new SetupException(ExitCode.InvalidPayload, "A release archive entry expands beyond its permitted size.");
            }
            destination.Write(buffer, 0, read);
        }
        if (total != entry.Length)
        {
            throw new SetupException(ExitCode.InvalidPayload, "A release archive entry ended at an unexpected length.");
        }
        return destination.ToArray();
    }
    private static void ExtractAndHash(ZipArchiveEntry entry, string destination, PayloadFile expected)
    {
        using var source = entry.Open();
        using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 128 * 1024, FileOptions.SequentialScan);
        using var hash = SHA256.Create();
        var buffer = new byte[128 * 1024];
        long total = 0;
        while (true)
        {
            var read = source.Read(buffer, 0, buffer.Length);
            if (read == 0)
            {
                break;
            }
            total = checked(total + read);
            if (total > expected.Length)
            {
                throw new SetupException(ExitCode.InvalidPayload, $"The archive entry {expected.Path} is longer than its manifest.");
            }
            output.Write(buffer, 0, read);
            hash.TransformBlock(buffer, 0, read, buffer, 0);
        }
        hash.TransformFinalBlock(Array.Empty<byte>(), 0, 0);
        if (total != expected.Length || !Convert.ToHexString(hash.Hash!).Equals(expected.Sha256, StringComparison.OrdinalIgnoreCase))
        {
            throw new SetupException(ExitCode.InvalidPayload, $"The SHA-256 or length for {expected.Path} does not match its manifest.");
        }
    }

    internal static void EnsureFreeSpace(string path, long payloadBytes)
    {
        const long reserveBytes = 256L * 1024 * 1024;
        try
        {
            var root = Path.GetPathRoot(Path.GetFullPath(path));
            if (string.IsNullOrWhiteSpace(root))
            {
                throw new IOException("The staging drive could not be determined.");
            }
            var available = new DriveInfo(root).AvailableFreeSpace;
            if (available < checked(payloadBytes + reserveBytes))
            {
                throw new SetupException(
                    ExitCode.IoFailure,
                    $"Nativune Setup needs at least {(payloadBytes + reserveBytes) / (1024 * 1024)} MiB of free space for this operation.");
            }
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new SetupException(ExitCode.IoFailure, "Available disk space could not be verified.", error);
        }
    }

    // Leaves file positioned after the footer; callers own the stream and map exceptions.
    private static (long Offset, long Length) ReadFooter(FileStream file)
    {
        if (file.Length < FooterSize)
        {
            throw new SetupException(ExitCode.InvalidPayload, "The setup executable has no release payload footer.");
        }

        file.Position = file.Length - FooterSize;
        Span<byte> footer = stackalloc byte[FooterSize];
        try
        {
            file.ReadExactly(footer);
        }
        catch (EndOfStreamException)
        {
            throw new SetupException(ExitCode.InvalidPayload, "The setup payload footer is truncated.");
        }
        if (!footer[..FooterMagic.Length].SequenceEqual(FooterMagic))
        {
            throw new SetupException(ExitCode.InvalidPayload, "The setup payload footer is invalid.");
        }
        var version = BinaryPrimitives.ReadUInt32LittleEndian(footer[8..12]);
        var offset = BinaryPrimitives.ReadInt64LittleEndian(footer[12..20]);
        var length = BinaryPrimitives.ReadInt64LittleEndian(footer[20..28]);
        var reserved = BinaryPrimitives.ReadUInt32LittleEndian(footer[28..32]);
        if (version != FooterVersion || reserved != 0 || offset < 0 || length <= 0
            || length > Manifest.MaxArchiveBytes
            || offset > file.Length - FooterSize
            || length > file.Length - FooterSize - offset
            || offset + length != file.Length - FooterSize)
        {
            throw new SetupException(ExitCode.InvalidPayload, "The setup payload footer bounds are invalid.");
        }
        return (offset, length);
    }

    private sealed class BoundedReadStream : Stream
    {
        private readonly Stream _inner;
        private readonly long _start;
        private readonly long _length;
        private long _position;

        internal BoundedReadStream(Stream inner, long start, long length)
        {
            _inner = inner;
            _start = start;
            _length = length;
            _inner.Position = start;
        }

        public override bool CanRead => true;
        public override bool CanSeek => true;
        public override bool CanWrite => false;
        public override long Length => _length;
        public override long Position
        {
            get => _position;
            set => Seek(value, SeekOrigin.Begin);
        }

        public override int Read(byte[] buffer, int offset, int count)
        {
            var allowed = (int)Math.Min(count, _length - _position);
            if (allowed <= 0)
            {
                return 0;
            }
            _inner.Position = _start + _position;
            var read = _inner.Read(buffer, offset, allowed);
            _position += read;
            return read;
        }

        public override int Read(Span<byte> buffer)
        {
            var allowed = (int)Math.Min(buffer.Length, _length - _position);
            if (allowed <= 0)
            {
                return 0;
            }
            _inner.Position = _start + _position;
            var read = _inner.Read(buffer[..allowed]);
            _position += read;
            return read;
        }

        public override long Seek(long offset, SeekOrigin origin)
        {
            var target = origin switch
            {
                SeekOrigin.Begin => offset,
                SeekOrigin.Current => _position + offset,
                SeekOrigin.End => _length + offset,
                _ => throw new ArgumentOutOfRangeException(nameof(origin)),
            };
            if (target < 0 || target > _length)
            {
                throw new IOException("ZIP reader seek escaped the payload bounds.");
            }
            _position = target;
            return target;
        }

        public override void Flush() => throw new NotSupportedException();
        public override void SetLength(long value) => throw new NotSupportedException();
        public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    }
}
