using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO.Compression;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Nativune;

internal sealed record ReleaseAsset(string Name, string DownloadUrl, long Size, string Digest);
internal sealed record DeltaAssets(ReleaseAsset Manifest, ReleaseAsset Zip, ReleaseAsset Descriptor);
internal sealed record DeltaFile(string Path, long Length, string Sha256);
internal sealed record DeltaManifest(ReleaseVersion Version, IReadOnlyList<DeltaFile> Files);

// Everything needed to stage and hand off a verified delta update for one offered release.
internal sealed record DeltaPlan(
    ReleaseVersion Version,
    byte[] ManifestBytes,
    string ManifestSha256,
    IReadOnlyList<DeltaFile> Needed,
    long NeededBytes,
    ReleaseAsset Zip,
    string DescriptorDigest,
    DeltaFile Installer);

internal static partial class ReleaseUpdater
{
    internal const string DeltaManifestName = "release-manifest.json";
    internal const string DeltaZipName = "Nativune-Setup.zip";
    internal const string DeltaDescriptorName = "delta-update.json";
    private const string InstallerPath = "installer/Nativune.Setup.exe";
    private const string DeltaAttemptName = "delta-attempt.json";
    private const long MaxDeltaManifestBytes = 16 * 1024 * 1024;
    private const long MaxDeltaDescriptorBytes = 64 * 1024;
    private const int MaxManifestFiles = 10_000;
    private const long MaxManifestFileBytes = 1L * 1024 * 1024 * 1024;
    private const long MaxManifestTotalBytes = 2L * 1024 * 1024 * 1024;
    private static readonly TimeSpan DeltaPrepareTimeout = TimeSpan.FromMinutes(2);
    private static readonly string[] AllowedManifestRoots = ["app", ".tools", "installer", "licenses"];
    private static readonly string[] RequiredManifestPaths =
    [
        Executable,
        InstallerPath,
        ".tools/ubol/2026.907.2003/LICENSE.txt",
        ".tools/ubol/2026.907.2003/manifest.json",
        "licenses/Microsoft-WindowsAppSDK.txt",
        "licenses/Microsoft-DotNet-LICENSE.txt",
        "licenses/Microsoft-DotNet-ThirdPartyNotices.txt",
        "licenses/Microsoft-WebView2-SDK-LICENSE.txt",
        "licenses/Microsoft-WebView2-SDK-NOTICE.txt",
        "licenses/Nativune-LICENSE.txt",
        "licenses/THIRD-PARTY-NOTICES.txt",
    ];

    // A missing, duplicated or malformed delta asset only disables delta, never the update.
    private static DeltaAssets? SelectDeltaAssets(JsonElement assets)
    {
        var manifest = SelectOptionalAsset(assets, DeltaManifestName, MaxDeltaManifestBytes);
        var zip = SelectOptionalAsset(assets, DeltaZipName, MaxAssetBytes);
        var descriptor = SelectOptionalAsset(assets, DeltaDescriptorName, MaxDeltaDescriptorBytes);
        return manifest is null || zip is null || descriptor is null ? null : new DeltaAssets(manifest, zip, descriptor);
    }

    private static ReleaseAsset? SelectOptionalAsset(JsonElement assets, string assetName, long maxBytes)
    {
        JsonElement selected = default;
        var found = false;
        foreach (var asset in assets.EnumerateArray())
        {
            if (asset.ValueKind != JsonValueKind.Object
                || !TryGetString(asset, "name", out var name)
                || !name.Equals(assetName, StringComparison.Ordinal))
                continue;
            if (found) return null;
            found = true;
            selected = asset;
        }
        if (!found
            || !TryGetString(selected, "state", out var state)
            || !state.Equals("uploaded", StringComparison.Ordinal)
            || !TryGetInt64(selected, "size", out var size)
            || size <= 0
            || size > maxBytes
            || !TryGetString(selected, "browser_download_url", out var downloadUrl)
            || !IsTrustedDownloadUri(downloadUrl)
            || !TryGetString(selected, "digest", out var digest)
            || !IsDigestSha256(digest))
            return null;
        return new ReleaseAsset(assetName, downloadUrl, size, digest);
    }

    // C7: remembers a delta attempt so a failed quick update is not retried for the same version.
    private static bool DeltaAttemptBlocks(string root, ReleaseVersion installed, ReleaseVersion offered)
    {
        try
        {
            var updates = Path.Combine(Path.GetFullPath(root), "updates");
            var marker = Path.Combine(updates, DeltaAttemptName);
            if (!Directory.Exists(updates) || HasReparsePointInChain(updates) || !TryGetAttributes(marker, out _))
                return false;
            if (!IsRegularFile(marker))
                return true;
            ReleaseVersion attempted;
            try
            {
                using var document = JsonDocument.Parse(ReadBoundedFile(marker, 4096), new JsonDocumentOptions { MaxDepth = 4 });
                var element = document.RootElement;
                if (element.ValueKind != JsonValueKind.Object
                    || element.EnumerateObject().Count() != 1
                    || !TryGetString(element, "version", out var text)
                    || !ReleaseVersion.TryParse(text, requireVPrefix: false, out attempted))
                {
                    File.Delete(marker);
                    return false;
                }
            }
            catch (JsonException)
            {
                File.Delete(marker);
                return false;
            }
            if (installed.CompareTo(attempted) >= 0)
            {
                File.Delete(marker);
                return false;
            }
            return attempted.CompareTo(offered) == 0;
        }
        catch (Exception)
        {
            return true;
        }
    }

    private static async Task<DeltaPlan?> TryPrepareDeltaAsync(
        string root,
        ReleaseSelection selection,
        CancellationToken cancellationToken)
    {
        if (selection.Delta is not { } assets)
            return null;
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(DeltaPrepareTimeout);
        try
        {
            return await Task.Run(() => PrepareDelta(root, selection.Version, assets, timeout.Token), timeout.Token)
                .ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            throw;
        }
        catch (Exception error)
        {
            AppLog.Write("update", $"delta ineligible: {error.GetType().Name}");
            return null;
        }
    }

    private static DeltaPlan? PrepareDelta(string root, ReleaseVersion offered, DeltaAssets assets, CancellationToken token)
    {
        var rootPath = Path.GetFullPath(root);
        if (!IsInstalledBuild(rootPath, out var installed)
            || offered.CompareTo(installed.Version) <= 0
            || DeltaAttemptBlocks(rootPath, installed.Version, offered))
            return null;

        using var client = CreateAssetHttpClient();
        var descriptorBytes = DownloadVerifiedAsset(client, assets.Descriptor, IsTrustedAssetUri, token);
        if (!TryParseDeltaDescriptor(descriptorBytes, offered, out var installerSha256))
            return null;
        var manifestBytes = DownloadVerifiedAsset(client, assets.Manifest, IsTrustedAssetUri, token);
        if (!TryParseStrictManifest(manifestBytes, out var target) || target.Version.CompareTo(offered) != 0)
            return null;
        var installedManifestPath = Path.Combine(rootPath, "release-manifest.json");
        if (!IsRegularFile(installedManifestPath)
            || !TryParseStrictManifest(ReadBoundedFile(installedManifestPath, MaxDeltaManifestBytes), out var current)
            || current.Version.CompareTo(installed.Version) != 0)
            return null;

        var targetInstaller = target.Files.Single(file => file.Path.Equals(InstallerPath, StringComparison.Ordinal));
        var currentInstaller = current.Files.Single(file => file.Path.Equals(InstallerPath, StringComparison.Ordinal));
        if (!targetInstaller.Sha256.Equals(installerSha256, StringComparison.Ordinal)
            || !currentInstaller.Sha256.Equals(installerSha256, StringComparison.Ordinal)
            || targetInstaller.Length != currentInstaller.Length)
            return null;

        var installedFiles = current.Files.ToDictionary(file => file.Path, StringComparer.Ordinal);
        var needed = new List<DeltaFile>();
        long neededBytes = 0;
        foreach (var file in target.Files)
        {
            token.ThrowIfCancellationRequested();
            var unchanged = installedFiles.TryGetValue(file.Path, out var old)
                && old.Length == file.Length
                && old.Sha256.Equals(file.Sha256, StringComparison.Ordinal)
                && InstalledFileMatches(rootPath, file, token);
            if (unchanged)
                continue;
            // The handoff copies the installed Setup, so it must already be intact on disk.
            if (file.Path.Equals(InstallerPath, StringComparison.Ordinal))
                return null;
            needed.Add(file);
            neededBytes = checked(neededBytes + file.Length);
        }

        return new DeltaPlan(
            offered,
            manifestBytes,
            Convert.ToHexString(SHA256.HashData(manifestBytes)).ToLowerInvariant(),
            needed,
            neededBytes,
            assets.Zip,
            assets.Descriptor.Digest,
            targetInstaller);
    }

    private static bool InstalledFileMatches(string rootPath, DeltaFile file, CancellationToken token)
    {
        var path = ResolveRelativePath(rootPath, file.Path);
        if (path is null || !IsRegularFile(path))
            return false;
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 128 * 1024, FileOptions.SequentialScan);
        if (stream.Length != file.Length)
            return false;
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        var buffer = new byte[128 * 1024];
        long total = 0;
        while (true)
        {
            token.ThrowIfCancellationRequested();
            var read = stream.Read(buffer, 0, buffer.Length);
            if (read == 0) break;
            total += read;
            if (total > file.Length) return false;
            hash.AppendData(buffer, 0, read);
        }
        return total == file.Length
            && Convert.ToHexString(hash.GetHashAndReset()).Equals(file.Sha256, StringComparison.OrdinalIgnoreCase);
    }

    private static string? ResolveRelativePath(string rootPath, string relativePath)
    {
        var full = Path.GetFullPath(Path.Combine(rootPath, relativePath.Replace('/', Path.DirectorySeparatorChar)));
        return IsContained(rootPath, full) ? full : null;
    }

    internal static bool TryParseDeltaDescriptor(byte[] bytes, ReleaseVersion offered, out string installerSha256)
    {
        installerSha256 = string.Empty;
        try
        {
            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 4 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object || !TryReadExactProperties(root,
                    ["schemaVersion", "product", "version", "enabled", "applyProtocol", "installerSha256", "installerSourceSha256"]))
                return false;
            if (!TryGetInt32(root, "schemaVersion", out var schemaVersion) || schemaVersion != 1
                || !TryGetString(root, "product", out var product) || !product.Equals(Product, StringComparison.Ordinal)
                || !TryGetString(root, "version", out var versionText)
                || !ReleaseVersion.TryParse(versionText, requireVPrefix: false, out var version)
                || version.CompareTo(offered) != 0
                || !TryGetBoolean(root, "enabled", out var enabled) || !enabled
                || !TryGetInt32(root, "applyProtocol", out var applyProtocol) || applyProtocol != 1
                || !TryGetString(root, "installerSha256", out var installer) || !IsLowerHexSha256(installer)
                || !TryGetString(root, "installerSourceSha256", out var source) || !IsLowerHexSha256(source))
                return false;
            installerSha256 = installer;
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    // Mirrors the installer's Manifest.Parse so a delta is only offered for a manifest Setup accepts.
    internal static bool TryParseStrictManifest(byte[] bytes, out DeltaManifest manifest)
    {
        manifest = null!;
        try
        {
            if (bytes.Length > MaxDeltaManifestBytes) return false;
            using var document = JsonDocument.Parse(bytes);
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !TryReadExactProperties(root, ["schemaVersion", "product", "version", "executable", "files"])
                || !TryGetInt32(root, "schemaVersion", out var schemaVersion) || schemaVersion != 1
                || !TryGetString(root, "product", out var product) || !product.Equals(Product, StringComparison.Ordinal)
                || !TryGetString(root, "version", out var versionText) || versionText.Length > 128
                || !ReleaseVersion.TryParse(versionText, requireVPrefix: false, out var version)
                || !TryGetString(root, "executable", out var executable) || !executable.Equals(Executable, StringComparison.Ordinal))
                return false;
            var filesElement = root.GetProperty("files");
            if (filesElement.ValueKind != JsonValueKind.Array
                || filesElement.GetArrayLength() == 0
                || filesElement.GetArrayLength() > MaxManifestFiles)
                return false;
            var files = new List<DeltaFile>(filesElement.GetArrayLength());
            var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            long total = 0;
            foreach (var file in filesElement.EnumerateArray())
            {
                if (file.ValueKind != JsonValueKind.Object
                    || !TryReadExactProperties(file, ["path", "length", "sha256"])
                    || !TryGetString(file, "path", out var path)
                    || !IsStrictManifestPath(path)
                    || path.Equals(DeltaManifestName, StringComparison.OrdinalIgnoreCase)
                    || path.StartsWith(".tools/webview2/", StringComparison.OrdinalIgnoreCase)
                    || !paths.Add(path)
                    || !TryGetInt64(file, "length", out var length)
                    || length is < 0 or > MaxManifestFileBytes
                    || (total = checked(total + length)) > MaxManifestTotalBytes
                    || !TryGetString(file, "sha256", out var sha256)
                    || !IsHexSha256(sha256))
                    return false;
                files.Add(new DeltaFile(path, length, sha256.ToLowerInvariant()));
            }
            if (RequiredManifestPaths.Any(required => !files.Any(file => file.Path.Equals(required, StringComparison.Ordinal))))
                return false;
            manifest = new DeltaManifest(version, files);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool TryReadExactProperties(JsonElement element, string[] names)
    {
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
            if (!seen.Add(property.Name) || !names.Contains(property.Name, StringComparer.Ordinal))
                return false;
        return seen.Count == names.Length;
    }

    private static bool IsStrictManifestPath(string path)
    {
        if (string.IsNullOrEmpty(path) || path.Length > 512 || path.Contains('\\') || path.Contains(':')
            || path.StartsWith('/') || path.EndsWith('/') || Path.IsPathRooted(path))
            return false;
        var segments = path.Split('/');
        if (segments.Any(segment => segment.Length == 0 || segment is "." or ".."
                || segment.Equals("data", StringComparison.OrdinalIgnoreCase)))
            return false;
        return AllowedManifestRoots.Contains(segments[0], StringComparer.OrdinalIgnoreCase);
    }

    private static bool IsLowerHexSha256(string value)
        => value.Length == 64 && value.All(static character => character is >= '0' and <= '9' or >= 'a' and <= 'f');

    internal static HttpClient CreateAssetHttpClient()
    {
        var handler = new HttpClientHandler
        {
            AllowAutoRedirect = false,
            AutomaticDecompression = DecompressionMethods.None,
            UseCookies = false,
            Credentials = null,
            PreAuthenticate = false,
        };
        var client = new HttpClient(handler) { Timeout = Timeout.InfiniteTimeSpan };
        client.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/octet-stream"));
        client.DefaultRequestHeaders.AcceptEncoding.Add(new StringWithQualityHeaderValue("identity"));
        return client;
    }

    internal static bool IsTrustedAssetUri(Uri uri)
    {
        if (uri.UserInfo.Length != 0)
            return false;
#if NATIVUNE_UPDATER_TEST_HOOKS
        if (IsTrustedDownloadUri(uri.AbsoluteUri)
            && uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase))
            return true;
#endif
        return uri.Scheme.Equals(Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            && uri.IsDefaultPort
            && (uri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase)
                || uri.Host.Equals("release-assets.githubusercontent.com", StringComparison.OrdinalIgnoreCase)
                || uri.Host.Equals("objects.githubusercontent.com", StringComparison.OrdinalIgnoreCase));
    }

    // Follows at most five redirects, each re-validated; a Range header is repeated on every hop.
    internal static HttpResponseMessage SendAssetRequest(
        HttpClient client,
        Uri origin,
        string? range,
        Func<Uri, bool> isAllowed,
        CancellationToken token)
    {
        var current = origin;
        for (var hop = 0; hop <= 5; hop++)
        {
            if (!isAllowed(current))
                throw new InvalidDataException("An update asset URL is not trusted.");
            using var request = new HttpRequestMessage(HttpMethod.Get, current);
            if (range is not null)
                request.Headers.TryAddWithoutValidation("Range", range);
            var response = client.Send(request, HttpCompletionOption.ResponseHeadersRead, token);
            if ((int)response.StatusCode is 301 or 302 or 303 or 307 or 308)
            {
                var location = response.Headers.Location;
                response.Dispose();
                if (location is null)
                    throw new InvalidDataException("An update asset redirect has no location.");
                current = location.IsAbsoluteUri ? location : new Uri(current, location);
                continue;
            }
            return response;
        }
        throw new InvalidDataException("An update asset redirected too many times.");
    }

    // Downloads a small asset completely and verifies size and digest before anything parses it.
    private static byte[] DownloadVerifiedAsset(HttpClient client, ReleaseAsset asset, Func<Uri, bool> isAllowed, CancellationToken token)
    {
        using var response = SendAssetRequest(client, new Uri(asset.DownloadUrl), null, isAllowed, token);
        if (response.StatusCode != HttpStatusCode.OK)
            throw new DeltaUpdateException($"HTTP {(int)response.StatusCode} for {asset.Name}.");
        if (response.Content.Headers.ContentEncoding.Count != 0
            || response.Content.Headers.ContentLength is { } length && length != asset.Size)
            throw new DeltaUpdateException($"Unexpected encoding or length for {asset.Name}.");
        using var stream = response.Content.ReadAsStream(token);
        var bytes = new byte[asset.Size];
        var total = 0;
        while (total < bytes.Length)
        {
            var read = stream.Read(bytes, total, bytes.Length - total);
            if (read == 0) throw new DeltaUpdateException($"{asset.Name} was truncated.");
            total += read;
        }
        if (stream.Read(new byte[1], 0, 1) != 0 || !HashMatches(bytes, asset.Digest))
            throw new DeltaUpdateException($"{asset.Name} did not match its published digest.");
        return bytes;
    }

    internal static async Task<ReleaseUpdateResult> DownloadDeltaAsync(
        string root,
        ReleaseUpdateResult update,
        IProgress<ReleaseUpdateProgress>? progress,
        CancellationToken cancellationToken)
    {
        if (cancellationToken.IsCancellationRequested)
            return ReleaseUpdateResult.Cancelled();
        if (!update.IsAvailable || update.Delta is not { } plan)
            return ReleaseUpdateResult.ErrorResult();

        var throttle = new ReleaseUpdateProgressThrottle(progress);
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(DownloadTimeout);
        var staged = false;
        try
        {
            if (!TryPrepareUpdateDirectory(root, out var updatesDirectory, out _, out var prepareFailure))
                return ReleaseUpdateResult.ErrorResult(prepareFailure);
            await Task.Run(() =>
            {
                throttle.Report(new ReleaseUpdateProgress(ReleaseUpdatePhase.Connecting, 0, plan.NeededBytes), force: true);
                var deltaDirectory = RecreateDeltaDirectory(updatesDirectory);
                File.WriteAllBytes(Path.Combine(deltaDirectory, DeltaManifestName), plan.ManifestBytes);
                if (plan.Needed.Count > 0)
                {
                    using var client = CreateAssetHttpClient();
                    using var zip = HttpRangeReadStream.Open(client, new Uri(plan.Zip.DownloadUrl), plan.Zip.Size, IsTrustedAssetUri, timeout.Token);
                    throttle.Report(new ReleaseUpdateProgress(ReleaseUpdatePhase.Downloading, 0, plan.NeededBytes), force: true);
                    StageDeltaEntries(zip, plan.Needed, deltaDirectory,
                        bytes => throttle.Report(new ReleaseUpdateProgress(ReleaseUpdatePhase.Downloading, bytes, plan.NeededBytes)),
                        timeout.Token);
                }
                throttle.Report(new ReleaseUpdateProgress(ReleaseUpdatePhase.Verifying, plan.NeededBytes, plan.NeededBytes), force: true);
            }, timeout.Token).ConfigureAwait(false);
            staged = true;
            return update;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ReleaseUpdateResult.Cancelled();
        }
        catch (Exception error)
        {
            AppLog.Write("update", $"delta staging failed: {error.GetType().Name}: {error.Message}");
            var failure = error is DeltaUpdateException or InvalidDataException
                ? ReleaseUpdateFailure.DigestMismatch
                : ClassifyDownloadBodyException(error);
            return ReleaseUpdateResult.ErrorResult(failure);
        }
        finally
        {
            throttle.Flush();
            if (!staged)
                TryDeleteDeltaDirectory(root);
        }
    }

    private static string RecreateDeltaDirectory(string updatesDirectory)
    {
        var deltaDirectory = Path.GetFullPath(Path.Combine(updatesDirectory, "delta"));
        if (!IsContained(updatesDirectory, deltaDirectory) || HasReparsePointInChain(updatesDirectory))
            throw new DeltaUpdateException("The delta staging folder is not safe.");
        if (TryGetAttributes(deltaDirectory, out var attributes))
        {
            if ((attributes & FileAttributes.ReparsePoint) != 0)
                throw new DeltaUpdateException("The delta staging folder is a link.");
            if ((attributes & FileAttributes.Directory) != 0)
                Directory.Delete(deltaDirectory, recursive: true);
            else
                File.Delete(deltaDirectory);
        }
        Directory.CreateDirectory(deltaDirectory);
        if (HasReparsePointInChain(deltaDirectory) || Directory.EnumerateFileSystemEntries(deltaDirectory).Any())
            throw new DeltaUpdateException("The delta staging folder could not be recreated.");
        return deltaDirectory;
    }

    internal static void TryDeleteDeltaDirectory(string root)
    {
        try
        {
            var updatesDirectory = Path.Combine(Path.GetFullPath(root), "updates");
            var deltaDirectory = Path.Combine(updatesDirectory, "delta");
            if (Directory.Exists(deltaDirectory) && !HasReparsePointInChain(deltaDirectory))
                Directory.Delete(deltaDirectory, recursive: true);
        }
        catch (Exception)
        {
        }
        TryRemoveEmptyUpdateDirectory(root);
    }

    // Extracts only the needed entries, verifying length and SHA-256 while streaming.
    internal static void StageDeltaEntries(
        HttpRangeReadStream zip,
        IReadOnlyList<DeltaFile> needed,
        string deltaDirectory,
        Action<long>? progress,
        CancellationToken token)
    {
        using var archive = new ZipArchive(zip, ZipArchiveMode.Read, leaveOpen: true, entryNameEncoding: Encoding.UTF8);
        if (archive.Entries.Count == 0 || archive.Entries.Count > MaxManifestFiles + 1)
            throw new DeltaUpdateException("The release archive has an invalid entry count.");
        var wanted = needed.ToDictionary(file => file.Path, StringComparer.Ordinal);
        var names = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (var entry in archive.Entries)
            if (!names.Add(entry.FullName))
                throw new DeltaUpdateException("The release archive contains case-colliding paths.");

        var staged = new HashSet<string>(StringComparer.Ordinal);
        long written = 0;
        var buffer = new byte[64 * 1024];
        foreach (var entry in archive.Entries)
        {
            if (!wanted.TryGetValue(entry.FullName, out var file))
                continue;
            token.ThrowIfCancellationRequested();
            var mode = (entry.ExternalAttributes >> 16) & 0xF000;
            if (mode == 0xA000 || (entry.ExternalAttributes & (int)FileAttributes.ReparsePoint) != 0
                || entry.Length != file.Length || !staged.Add(file.Path))
                throw new DeltaUpdateException("A release archive entry does not match the manifest.");
            var destination = ResolveRelativePath(deltaDirectory, file.Path)
                ?? throw new DeltaUpdateException("A release archive path escapes the staging folder.");
            Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
            if (HasReparsePointInChain(Path.GetDirectoryName(destination)!))
                throw new DeltaUpdateException("The delta staging folder contains a link.");

            zip.ReadAheadHint = entry.CompressedLength + 64 * 1024;
            using (var input = entry.Open())
            using (var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None, 64 * 1024))
            using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                long total = 0;
                while (true)
                {
                    token.ThrowIfCancellationRequested();
                    var read = input.Read(buffer, 0, buffer.Length);
                    if (read == 0) break;
                    total += read;
                    if (total > file.Length)
                        throw new DeltaUpdateException("A release archive entry is longer than the manifest says.");
                    hash.AppendData(buffer, 0, read);
                    output.Write(buffer, 0, read);
                    written += read;
                    progress?.Invoke(written);
                }
                if (total != file.Length
                    || !Convert.ToHexString(hash.GetHashAndReset()).Equals(file.Sha256, StringComparison.OrdinalIgnoreCase))
                    throw new DeltaUpdateException($"{file.Path} did not match the release manifest.");
                output.Flush(flushToDisk: true);
            }
            zip.ReadAheadHint = 0;
        }
        if (staged.Count != wanted.Count)
            throw new DeltaUpdateException("The release archive is missing a needed file.");
    }

    internal static string[] BuildDeltaUpdateArguments(string root, int waitPid, string expectedVersion, string manifestSha256)
    {
        if (!IsLowerHexSha256(manifestSha256))
            throw new ArgumentException("The manifest hash must be lowercase SHA-256 hex.", nameof(manifestSha256));
        var arguments = BuildUpdateArguments(root, waitPid, expectedVersion);
        var rootPath = Path.GetFullPath(root);
        string[] delta =
        [
            .. arguments,
            "--delta-dir",
            Path.Combine(rootPath, "updates", "delta"),
            "--expected-manifest-sha256",
            manifestSha256,
        ];
#if NATIVUNE_UPDATER_TEST_HOOKS
        // Test-hook fixtures install an INSTALLER_TEST_HOOKS Setup; keep it away from the real shortcuts and
        // uninstall entry, which share fixed names with the owner's installed Nativune.
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_SETUP_NO_SHELL") == "1")
            delta = [.. delta, "--test-no-shell"];
#endif
        return delta;
    }

    // Hands the staged delta to the installed Setup copy (C4). Every check before Process.Start fails closed.
    internal static async Task<ReleaseLaunchResult> LaunchDeltaSetupAsync(
        ReleaseUpdateResult update,
        string root,
        int waitPid,
        CancellationToken cancellationToken)
    {
        if (!update.IsAvailable || update.Delta is not { } plan || update.Version is null || waitPid <= 0)
            return new ReleaseLaunchResult(false, null);
        string? markerPath = null;
        try
        {
            var rootPath = Path.GetFullPath(root);
            if (!IsInstalledBuild(rootPath, out var installed)
                || plan.Version.CompareTo(installed.Version) <= 0
                || !await DescriptorStillPublishedAsync(installed.Version, plan, cancellationToken).ConfigureAwait(false))
                return new ReleaseLaunchResult(false, null);

            var updatesPath = Path.Combine(rootPath, "updates");
            var deltaPath = Path.Combine(updatesPath, "delta");
            var stagedManifest = Path.Combine(deltaPath, DeltaManifestName);
            if (!Directory.Exists(deltaPath) || HasReparsePointInChain(deltaPath) || !IsRegularFile(stagedManifest)
                || !Convert.ToHexString(SHA256.HashData(ReadBoundedFile(stagedManifest, MaxDeltaManifestBytes)))
                    .Equals(plan.ManifestSha256, StringComparison.OrdinalIgnoreCase))
                return new ReleaseLaunchResult(false, null);

            var source = Path.Combine(rootPath, InstallerPath.Replace('/', Path.DirectorySeparatorChar));
            var setupPath = Path.Combine(updatesPath, SetupName);
            var digest = "sha256:" + plan.Installer.Sha256;
            if (!await VerifyFileAsync(source, plan.Installer.Length, digest, cancellationToken).ConfigureAwait(false))
                return new ReleaseLaunchResult(false, null);
            var temporary = Path.Combine(updatesPath, $".{SetupName}.{Guid.NewGuid():N}.tmp");
            try
            {
                File.Copy(source, temporary);
                if (!AtomicInstall(temporary, setupPath))
                    return new ReleaseLaunchResult(false, null);
            }
            finally
            {
                if (File.Exists(temporary) && IsRegularFile(temporary)) File.Delete(temporary);
            }
            if (!await VerifyFileAsync(setupPath, plan.Installer.Length, digest, cancellationToken).ConfigureAwait(false))
                return new ReleaseLaunchResult(false, null);

            markerPath = Path.Combine(updatesPath, DeltaAttemptName);
            if (TryGetAttributes(markerPath, out var markerAttributes)
                && (markerAttributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) != 0)
                return new ReleaseLaunchResult(false, null);
            File.WriteAllText(markerPath,
                JsonSerializer.Serialize(new Dictionary<string, string> { ["version"] = plan.Version.ToManifestString() }),
                new UTF8Encoding(false));

            var startInfo = new ProcessStartInfo
            {
                FileName = setupPath,
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = rootPath,
            };
            foreach (var argument in BuildDeltaUpdateArguments(rootPath, waitPid, update.Version, plan.ManifestSha256))
                startInfo.ArgumentList.Add(argument);
            using var process = Process.Start(startInfo);
            if (process is null)
            {
                TryDeleteFile(markerPath);
                return new ReleaseLaunchResult(false, null);
            }
            return new ReleaseLaunchResult(true, null);
        }
        catch (Win32Exception error)
        {
            TryDeleteFile(markerPath);
            return new ReleaseLaunchResult(false, error.NativeErrorCode);
        }
        catch (Exception error)
        {
            TryDeleteFile(markerPath);
            return new ReleaseLaunchResult(false, cancellationToken.IsCancellationRequested ? null : FindWin32Error(error));
        }
    }

    private static void TryDeleteFile(string? path)
    {
        try
        {
            if (path is not null && IsRegularFile(path)) File.Delete(path);
        }
        catch (Exception)
        {
        }
    }

    // The owner's kill switch: the descriptor must still be published, unchanged, right before handoff.
    private static async Task<bool> DescriptorStillPublishedAsync(ReleaseVersion installed, DeltaPlan plan, CancellationToken cancellationToken)
    {
        using var client = CreateHttpClient();
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        timeout.CancelAfter(MetadataTimeout);
        var metadataUri = LatestReleaseUri;
#if NATIVUNE_UPDATER_TEST_HOOKS
        metadataUri = ResolveTestReleaseMetadataUri();
#endif
        using var request = new HttpRequestMessage(HttpMethod.Get, metadataUri);
        using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
        if (response.StatusCode != HttpStatusCode.OK)
            return false;
        var body = await ReadBoundedAsync(
            await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false),
            MaxReleaseMetadataBytes,
            timeout.Token).ConfigureAwait(false);
        using var document = JsonDocument.Parse(body, new JsonDocumentOptions { MaxDepth = 32 });
        return SelectRelease(document.RootElement, installed, out var selection) == ReleaseSelectionDisposition.Ready
            && selection is { Delta: { } assets }
            && selection.Version.CompareTo(plan.Version) == 0
            && assets.Descriptor.Digest.Equals(plan.DescriptorDigest, StringComparison.OrdinalIgnoreCase);
    }
}

internal sealed class DeltaUpdateException(string message) : Exception(message);

// Read-only seekable view of a remote file built from explicit HTTP byte ranges (never suffix ranges).
internal sealed class HttpRangeReadStream : Stream
{
    internal const int MinimumRequestBytes = 64 * 1024;
    private const int DefaultRequestBytes = 256 * 1024;
    private const int MaximumRequestBytes = 16 * 1024 * 1024;
    private const int MaximumRequests = 16_384;
    private readonly HttpClient _client;
    private readonly Uri _origin;
    private readonly Func<Uri, bool> _isAllowed;
    private readonly CancellationToken _token;
    private readonly long _length;
    private readonly long _maximumBytes;
    private long _position;
    private long _blockStart = -1;
    private byte[] _block = [];
    private int _requests;
    private long _transferred;

    private HttpRangeReadStream(HttpClient client, Uri origin, long length, Func<Uri, bool> isAllowed, CancellationToken token)
    {
        _client = client;
        _origin = origin;
        _length = length;
        _isAllowed = isAllowed;
        _token = token;
        _maximumBytes = checked(length * 2 + 32L * 1024 * 1024);
    }

    internal long ReadAheadHint { get; set; }
    internal int Requests => _requests;

    internal static HttpRangeReadStream Open(HttpClient client, Uri origin, long expectedLength, Func<Uri, bool> isAllowed, CancellationToken token)
    {
        if (expectedLength <= 0)
            throw new DeltaUpdateException("The release archive size is invalid.");
        var stream = new HttpRangeReadStream(client, origin, expectedLength, isAllowed, token);
        stream.Fetch(0, 0);
        return stream;
    }

    public override bool CanRead => true;
    public override bool CanSeek => true;
    public override bool CanWrite => false;
    public override long Length => _length;

    public override long Position
    {
        get => _position;
        set => _position = value >= 0 ? value : throw new ArgumentOutOfRangeException(nameof(value));
    }

    public override int Read(byte[] buffer, int offset, int count) => Read(buffer.AsSpan(offset, count));

    public override int Read(Span<byte> buffer)
    {
        if (buffer.Length == 0 || _position >= _length)
            return 0;
        if (_blockStart < 0 || _position < _blockStart || _position >= _blockStart + _block.Length)
        {
            var wanted = Math.Max(buffer.Length, ReadAheadHint > 0 ? ReadAheadHint : DefaultRequestBytes);
            var size = Math.Min(_length, Math.Clamp(wanted, MinimumRequestBytes, MaximumRequestBytes));
            var start = Math.Max(0, Math.Min(_position, _length - size));
            _block = Fetch(start, start + size - 1);
            _blockStart = start;
        }
        var available = (int)Math.Min(buffer.Length, _blockStart + _block.Length - _position);
        _block.AsSpan((int)(_position - _blockStart), available).CopyTo(buffer);
        _position += available;
        return available;
    }

    public override long Seek(long offset, SeekOrigin origin)
    {
        Position = origin switch
        {
            SeekOrigin.Begin => offset,
            SeekOrigin.Current => _position + offset,
            SeekOrigin.End => _length + offset,
            _ => throw new ArgumentOutOfRangeException(nameof(origin)),
        };
        return _position;
    }

    public override void Flush() { }
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();

    private byte[] Fetch(long start, long end)
    {
        var count = end - start + 1;
        if (++_requests > MaximumRequests || (_transferred += count) > _maximumBytes)
            throw new DeltaUpdateException("The release archive needed too many range requests.");
        using var response = ReleaseUpdater.SendAssetRequest(
            _client, _origin, $"bytes={start.ToString(CultureInfo.InvariantCulture)}-{end.ToString(CultureInfo.InvariantCulture)}",
            _isAllowed, _token);
        if (response.StatusCode != HttpStatusCode.PartialContent)
            throw new DeltaUpdateException($"The release archive range request returned HTTP {(int)response.StatusCode}.");
        var range = response.Content.Headers.ContentRange;
        if (range is null
            || !string.Equals(range.Unit, "bytes", StringComparison.OrdinalIgnoreCase)
            || range.From != start || range.To != end || range.Length != _length
            || response.Content.Headers.ContentEncoding.Count != 0
            || response.Content.Headers.ContentLength is { } length && length != count)
            throw new DeltaUpdateException("The release archive range response did not match the request.");
        using var body = response.Content.ReadAsStream(_token);
        var bytes = new byte[count];
        var total = 0;
        while (total < bytes.Length)
        {
            var read = body.Read(bytes, total, bytes.Length - total);
            if (read == 0)
                throw new DeltaUpdateException("The release archive range response was truncated.");
            total += read;
        }
        if (body.Read(new byte[1], 0, 1) != 0)
            throw new DeltaUpdateException("The release archive range response was too long.");
        return bytes;
    }
}
