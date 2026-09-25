using System.Diagnostics;
using System.Globalization;
using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Nativune;

internal enum ReleaseUpdateStatus
{
    None,
    NotInstalled,
    Available,
    Cancelled,
    Error,
}
internal sealed record ReleaseUpdateResult(
    ReleaseUpdateStatus Status,
    string? Version,
    string? DownloadUrl,
    string? SetupPath,
    long Size,
    string? Sha256,
    string? Error)
{
    internal bool IsAvailable => Status == ReleaseUpdateStatus.Available
        && Version is not null
        && DownloadUrl is not null
        && Size > 0
        && Sha256 is not null;

    // Offered release's own notes (fallback) and the installed version, for the change summary.
    internal string? ReleaseNotes { get; init; }
    internal string? InstalledVersion { get; init; }

    internal static ReleaseUpdateResult None()
        => new(ReleaseUpdateStatus.None, null, null, null, 0, null, null);

    internal static ReleaseUpdateResult NotInstalled()
        => new(ReleaseUpdateStatus.NotInstalled, null, null, null, 0, null, null);

    internal static ReleaseUpdateResult Cancelled()
        => new(ReleaseUpdateStatus.Cancelled, null, null, null, 0, null, null);

    internal static ReleaseUpdateResult ErrorResult()
        => new(ReleaseUpdateStatus.Error, null, null, null, 0, null, "Update check unavailable.");
}

internal enum ReleaseSelectionDisposition
{
    None,
    Ready,
    Error,
}

internal readonly struct ReleaseVersion : IComparable<ReleaseVersion>
{
    private readonly string[] _preRelease;
    private readonly string[] _buildMetadata;

    internal ReleaseVersion(int major, int minor, int patch, string[] preRelease, string[] buildMetadata)
    {
        Major = major;
        Minor = minor;
        Patch = patch;
        _preRelease = preRelease;
        _buildMetadata = buildMetadata;
    }

    internal int Major { get; }
    internal int Minor { get; }
    internal int Patch { get; }
    internal bool IsPrerelease => _preRelease is { Length: > 0 };

    public int CompareTo(ReleaseVersion other)
    {
        var result = Major.CompareTo(other.Major);
        if (result != 0) return result;
        result = Minor.CompareTo(other.Minor);
        if (result != 0) return result;
        result = Patch.CompareTo(other.Patch);
        if (result != 0) return result;

        var left = _preRelease ?? Array.Empty<string>();
        var right = other._preRelease ?? Array.Empty<string>();
        if (left.Length == 0 && right.Length == 0) return 0;
        if (left.Length == 0) return 1;
        if (right.Length == 0) return -1;

        var count = Math.Min(left.Length, right.Length);
        for (var index = 0; index < count; index++)
        {
            var leftNumeric = IsNumericIdentifier(left[index]);
            var rightNumeric = IsNumericIdentifier(right[index]);
            if (leftNumeric && rightNumeric)
            {
                result = CompareNumericIdentifiers(left[index], right[index]);
            }
            else if (leftNumeric != rightNumeric)
            {
                result = leftNumeric ? -1 : 1;
            }
            else
            {
                result = string.CompareOrdinal(left[index], right[index]);
            }

            if (result != 0) return result;
        }

        return left.Length.CompareTo(right.Length);
    }

    internal string ToTagString()
    {
        var value = $"{Major.ToString(CultureInfo.InvariantCulture)}.{Minor.ToString(CultureInfo.InvariantCulture)}.{Patch.ToString(CultureInfo.InvariantCulture)}";
        if (_preRelease is { Length: > 0 })
            value += "-" + string.Join('.', _preRelease);
        if (_buildMetadata is { Length: > 0 })
            value += "+" + string.Join('.', _buildMetadata);
        return "v" + value;
    }

    internal string ToManifestString() => ToTagString()[1..];

    internal static bool TryParse(string? value, bool requireVPrefix, out ReleaseVersion version)
    {
        version = default;
        if (string.IsNullOrEmpty(value)) return false;
        if (value.Any(static character => character > 0x7f || char.IsWhiteSpace(character))) return false;

        if (value[0] == 'v')
        {
            if (!requireVPrefix) return false;
            value = value[1..];
        }
        else if (requireVPrefix)
        {
            return false;
        }

        string[] buildMetadata = Array.Empty<string>();
        var plus = value.IndexOf('+');
        if (plus >= 0)
        {
            var buildMetadataText = value[(plus + 1)..];
            if (value.IndexOf('+', plus + 1) >= 0 || !ValidateIdentifiers(buildMetadataText, allowNumericLeadingZero: true))
                return false;
            buildMetadata = buildMetadataText.Split('.', StringSplitOptions.None);
            value = value[..plus];
        }

        string[] preRelease = Array.Empty<string>();
        var hyphen = value.IndexOf('-');
        if (hyphen >= 0)
        {
            var preReleaseText = value[(hyphen + 1)..];
            if (!ValidateIdentifiers(preReleaseText, allowNumericLeadingZero: false)) return false;
            preRelease = preReleaseText.Split('.', StringSplitOptions.None);
            value = value[..hyphen];
        }

        var core = value.Split('.', StringSplitOptions.None);
        if (core.Length != 3
            || !TryParseCoreNumber(core[0], out var major)
            || !TryParseCoreNumber(core[1], out var minor)
            || !TryParseCoreNumber(core[2], out var patch))
            return false;

        version = new ReleaseVersion(major, minor, patch, preRelease, buildMetadata);
        return true;
    }

    private static bool TryParseCoreNumber(string value, out int number)
    {
        number = 0;
        if (value.Length == 0 || (value.Length > 1 && value[0] == '0')) return false;
        foreach (var character in value)
            if (character is < '0' or > '9') return false;
        return int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out number);
    }

    private static bool ValidateIdentifiers(string value, bool allowNumericLeadingZero)
    {
        if (value.Length == 0) return false;
        var identifiers = value.Split('.', StringSplitOptions.None);
        foreach (var identifier in identifiers)
        {
            if (identifier.Length == 0) return false;
            if (identifier.All(static character => character is >= '0' and <= '9')
                && !allowNumericLeadingZero
                && identifier.Length > 1
                && identifier[0] == '0')
                return false;
            foreach (var character in identifier)
                if (!IsIdentifierCharacter(character)) return false;
        }
        return true;
    }

    private static bool IsIdentifierCharacter(char character)
        => character is >= '0' and <= '9'
            or >= 'A' and <= 'Z'
            or >= 'a' and <= 'z'
            or '-';

    private static bool IsNumericIdentifier(string value)
        => value.All(static character => character is >= '0' and <= '9');

    private static int CompareNumericIdentifiers(string left, string right)
    {
        if (left.Length != right.Length) return left.Length.CompareTo(right.Length);
        return string.CompareOrdinal(left, right);
    }
}

internal sealed record ReleaseSelection(
    ReleaseVersion Version,
    string DownloadUrl,
    long Size,
    string Sha256)
{
    internal string VersionText => Version.ToTagString();
}

internal readonly record struct InstalledBuild(ReleaseVersion Version);
internal readonly record struct InstalledManifest(ReleaseVersion Version);

internal static class ReleaseUpdater
{
    private const string Product = "Nativune";
    private const string Executable = "app/Nativune.exe";
    private const string SetupName = "Nativune-Setup.exe";
    private const string GitHubApiVersion = "2022-11-28";
    private static string UserAgent => $"{Product}/{AppVersion.Number}";
    private const long MaxReleaseMetadataBytes = 1 * 1024 * 1024;
    private const long MaxAssetBytes = 1024L * 1024 * 1024;
    private static readonly Uri LatestReleaseUri = new("https://api.github.com/repos/Hantu-Raya/Nativune/releases/latest");
    private static readonly TimeSpan MetadataTimeout = TimeSpan.FromSeconds(15);
    private static readonly TimeSpan DownloadTimeout = TimeSpan.FromMinutes(30);

    internal static async Task<ReleaseUpdateResult> CheckAsync(string root, CancellationToken cancellationToken)
    {
        if (!IsInstalledBuild(root, out var installed))
            return ReleaseUpdateResult.NotInstalled();

        try
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
                return ReleaseUpdateResult.ErrorResult();

            var body = await ReadBoundedAsync(
                await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false),
                MaxReleaseMetadataBytes,
                timeout.Token).ConfigureAwait(false);
            using var document = JsonDocument.Parse(body, new JsonDocumentOptions { MaxDepth = 32 });
            var disposition = SelectRelease(document.RootElement, installed.Version, out var selection);
            if (disposition == ReleaseSelectionDisposition.None)
                return ReleaseUpdateResult.None();
            if (disposition != ReleaseSelectionDisposition.Ready || selection is null)
                return ReleaseUpdateResult.ErrorResult();

            return new ReleaseUpdateResult(
                ReleaseUpdateStatus.Available,
                selection.VersionText,
                selection.DownloadUrl,
                null,
                selection.Size,
                selection.Sha256,
                null)
            {
                ReleaseNotes = TryGetString(document.RootElement, "body", out var notes) ? notes : null,
                InstalledVersion = installed.Version.ToTagString(),
            };
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ReleaseUpdateResult.Cancelled();
        }
        catch (Exception)
        {
            return ReleaseUpdateResult.ErrorResult();
        }
    }

#if NATIVUNE_UPDATER_TEST_HOOKS
    private static Uri ResolveTestReleaseMetadataUri()
    {
        const string uriPrefix = "http://127.0.0.1:";
        var value = Environment.GetEnvironmentVariable("NATIVUNE_TEST_RELEASE_METADATA_URL");
        if (string.IsNullOrEmpty(value)
            || !value.StartsWith(uriPrefix, StringComparison.OrdinalIgnoreCase)
            || !Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || !uri.Scheme.Equals(Uri.UriSchemeHttp, StringComparison.OrdinalIgnoreCase)
            || !uri.Host.Equals("127.0.0.1", StringComparison.Ordinal)
            || uri.UserInfo.Length != 0)
            return LatestReleaseUri;

        var authorityEnd = value.IndexOfAny(new[] { '/', '?', '#' }, uriPrefix.Length);
        var portText = authorityEnd < 0
            ? value[uriPrefix.Length..]
            : value[uriPrefix.Length..authorityEnd];
        if (!int.TryParse(portText, NumberStyles.None, CultureInfo.InvariantCulture, out var port)
            || port is < 1 or > 65535
            || uri.Port != port)
            return LatestReleaseUri;
        return uri;
    }
#endif

    private static readonly Uri ReleaseListUri = new("https://api.github.com/repos/Hantu-Raya/Nativune/releases?per_page=30");
    private const int MaxSummaryCharactersPerRelease = 6000;

    // Notes for every stable release after the installed version up to the offered one, newest first.
    // One extra anonymous request, made only when the update dialog opens; falls back to the offered
    // release's own notes. The text is only displayed as plain text, never interpreted as markup.
    internal static async Task<string> GetChangeSummaryAsync(ReleaseUpdateResult update, CancellationToken cancellationToken)
    {
        var fallback = BuildChangeSummary(null, update.InstalledVersion, update.Version, update.ReleaseNotes);
        try
        {
            using var client = CreateHttpClient();
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(MetadataTimeout);
            var listUri = ReleaseListUri;
#if NATIVUNE_UPDATER_TEST_HOOKS
            listUri = ResolveTestReleaseMetadataUri() is var testUri && testUri != LatestReleaseUri ? testUri : ReleaseListUri;
#endif
            using var request = new HttpRequestMessage(HttpMethod.Get, listUri);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            if (response.StatusCode != HttpStatusCode.OK)
                return fallback;
            var body = await ReadBoundedAsync(
                await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false),
                MaxReleaseMetadataBytes,
                timeout.Token).ConfigureAwait(false);
            return BuildChangeSummary(Encoding.UTF8.GetString(body), update.InstalledVersion, update.Version, update.ReleaseNotes);
        }
        catch (Exception)
        {
            return fallback;
        }
    }

    internal static string BuildChangeSummary(string? releasesJson, string? installedVersion, string? targetVersion, string? fallbackNotes)
    {
        var hasInstalled = ReleaseVersion.TryParse(installedVersion ?? "", requireVPrefix: true, out var installed);
        var hasTarget = ReleaseVersion.TryParse(targetVersion ?? "", requireVPrefix: true, out var target);
        var releases = new List<(ReleaseVersion Version, string Tag, string Notes)>();
        if (releasesJson is not null && hasInstalled && hasTarget)
        {
            try
            {
                using var document = JsonDocument.Parse(releasesJson, new JsonDocumentOptions { MaxDepth = 32 });
                var items = document.RootElement.ValueKind == JsonValueKind.Array
                    ? document.RootElement.EnumerateArray().ToList()
                    : new List<JsonElement> { document.RootElement };
                foreach (var release in items)
                {
                    if (release.ValueKind != JsonValueKind.Object
                        || !TryGetBoolean(release, "draft", out var draft) || draft
                        || !TryGetBoolean(release, "prerelease", out var prerelease) || prerelease
                        || !TryGetString(release, "tag_name", out var tag)
                        || !ReleaseVersion.TryParse(tag, requireVPrefix: true, out var version)
                        || version.IsPrerelease
                        || version.CompareTo(installed) <= 0
                        || version.CompareTo(target) > 0)
                        continue;
                    releases.Add((version, tag, TryGetString(release, "body", out var notes) ? notes : ""));
                }
            }
            catch (JsonException)
            {
                releases.Clear();
            }
        }
        if (releases.Count == 0)
            releases.Add((target, targetVersion ?? "", fallbackNotes ?? ""));
        releases.Sort((left, right) => right.Version.CompareTo(left.Version));

        var text = new StringBuilder();
        foreach (var release in releases)
        {
            if (text.Length > 0) text.Append("\n\n");
            text.Append(release.Tag);
            var summary = SummarizeReleaseNotes(release.Notes);
            text.Append('\n').Append(summary.Length == 0 ? "No release notes were published for this version." : summary);
        }
        return text.ToString();
    }

    // Keeps the "What's new/fixed/changed" sections of a release body and drops the intro, install and
    // build boilerplate. Markdown emphasis, code and links are reduced to plain text; bullets become "•".
    internal static string SummarizeReleaseNotes(string? markdown)
    {
        if (string.IsNullOrWhiteSpace(markdown)) return "";
        var lines = markdown.Replace("\r\n", "\n", StringComparison.Ordinal).Split('\n');
        var hasSections = lines.Any(static line => line.StartsWith("## ", StringComparison.Ordinal));
        var keep = !hasSections;
        var output = new StringBuilder();
        foreach (var raw in lines)
        {
            var line = raw.TrimEnd();
            if (line.StartsWith("# ", StringComparison.Ordinal)) continue;
            if (line.StartsWith("## ", StringComparison.Ordinal))
            {
                var heading = line[3..].Trim();
                keep = !heading.StartsWith("Install", StringComparison.OrdinalIgnoreCase)
                    && !heading.StartsWith("Build", StringComparison.OrdinalIgnoreCase);
                if (keep) output.Append(output.Length > 0 ? "\n\n" : "").Append(PlainText(heading));
                continue;
            }
            if (!keep || line.Length == 0) continue;
            var trimmed = line.TrimStart();
            var bullet = trimmed.StartsWith("- ", StringComparison.Ordinal) || trimmed.StartsWith("* ", StringComparison.Ordinal);
            output.Append('\n').Append(bullet ? "• " + PlainText(trimmed[2..]) : PlainText(trimmed));
            if (output.Length > MaxSummaryCharactersPerRelease)
            {
                output.Length = MaxSummaryCharactersPerRelease;
                output.Append('…');
                break;
            }
        }
        return output.ToString().Trim('\n');
    }

    private static string PlainText(string markdown)
    {
        var text = System.Text.RegularExpressions.Regex.Replace(markdown, @"\[([^\]]*)\]\([^)]*\)", "$1");
        return text.Replace("**", "", StringComparison.Ordinal)
            .Replace("__", "", StringComparison.Ordinal)
            .Replace("`", "", StringComparison.Ordinal);
    }

    internal static async Task<ReleaseUpdateResult> DownloadAsync(
        string root,
        ReleaseUpdateResult update,
        CancellationToken cancellationToken)
    {
        if (!update.IsAvailable
            || update.Version is null
            || update.DownloadUrl is null
            || update.Sha256 is null
            || !ReleaseVersion.TryParse(update.Version, requireVPrefix: true, out var version)
            || version.IsPrerelease
            || !IsTrustedDownloadUri(update.DownloadUrl)
            || !IsDigestSha256(update.Sha256)
            || update.Size <= 0
            || update.Size > MaxAssetBytes)
            return ReleaseUpdateResult.ErrorResult();

        try
        {
            using var client = CreateHttpClient();
            var selection = new ReleaseSelection(version, update.DownloadUrl, update.Size, update.Sha256);
            var setupPath = await DownloadVerifiedAsync(root, selection, client, cancellationToken).ConfigureAwait(false);
            return setupPath is null
                ? ReleaseUpdateResult.ErrorResult()
                : update with { SetupPath = setupPath };
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return ReleaseUpdateResult.None();
        }
        catch (Exception)
        {
            return ReleaseUpdateResult.ErrorResult();
        }
    }

    internal static bool IsInstalledBuild(string root, string? baseDirectoryOverride = null)
        => IsInstalledBuild(root, out _, baseDirectoryOverride);

    private static bool IsInstalledBuild(string root, out InstalledBuild installed, string? baseDirectoryOverride = null)
    {
        installed = default;
        try
        {
            var rootPath = Path.GetFullPath(root);
            if (baseDirectoryOverride is null)
            {
                var localAppData = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                if (string.IsNullOrWhiteSpace(localAppData) || !IsContained(localAppData, rootPath))
                    return false;
            }
            if (!Directory.Exists(rootPath) || HasReparsePointInChain(rootPath)) return false;
            var appPath = Path.GetFullPath(Path.Combine(rootPath, "app"));
            var basePath = Path.GetFullPath(baseDirectoryOverride ?? AppContext.BaseDirectory);
            if (!PathsEqual(basePath, appPath) || !Directory.Exists(appPath) || HasReparsePointInChain(appPath)) return false;

            var manifestPath = Path.Combine(rootPath, "release-manifest.json");
            if (!TryReadInstalledManifest(manifestPath, out var manifest)) return false;
            var executablePath = Path.Combine(rootPath, Executable.Replace('/', Path.DirectorySeparatorChar));
            if (!IsRegularFile(executablePath)) return false;
            installed = new InstalledBuild(manifest.Version);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    internal static ReleaseSelectionDisposition SelectReleaseForChecks(
        string json,
        string installedVersion,
        out ReleaseSelection? selection)
    {
        selection = null;
        try
        {
            if (!ReleaseVersion.TryParse(installedVersion, requireVPrefix: false, out var current))
                return ReleaseSelectionDisposition.Error;
            using var document = JsonDocument.Parse(json, new JsonDocumentOptions { MaxDepth = 32 });
            return SelectRelease(document.RootElement, current, out selection);
        }
        catch (Exception)
        {
            return ReleaseSelectionDisposition.Error;
        }
    }

    internal static bool IsDigestSha256(string? digest)
    {
        if (digest is null || digest.Length != "sha256:".Length + 64
            || !digest.StartsWith("sha256:", StringComparison.Ordinal))
            return false;
        for (var index = "sha256:".Length; index < digest.Length; index++)
        {
            var character = digest[index];
            if (character is not (>= '0' and <= '9')
                and not (>= 'a' and <= 'f')
                and not (>= 'A' and <= 'F'))
                return false;
        }
        return true;
    }

    internal static bool HashMatches(ReadOnlySpan<byte> bytes, string? digest)
    {
        if (!IsDigestSha256(digest)) return false;
        Span<byte> hash = stackalloc byte[32];
        SHA256.HashData(bytes, hash);
        return CryptographicOperations.FixedTimeEquals(
            hash,
            Convert.FromHexString(digest!["sha256:".Length..]));
    }

    internal static string[] BuildUpdateArguments(string root, int waitPid, string expectedVersion)
    {
        if (waitPid <= 0) throw new ArgumentOutOfRangeException(nameof(waitPid));
        if (!ReleaseVersion.TryParse(expectedVersion, requireVPrefix: true, out var version) || version.IsPrerelease)
            throw new ArgumentException("The expected update version must be a stable v-prefixed semantic version.", nameof(expectedVersion));
        var rootPath = Path.GetFullPath(root);
        if (!Path.IsPathFullyQualified(rootPath)) throw new ArgumentException("The install root must be absolute.", nameof(root));
        return
        [
            "--update",
            "--wait-pid",
            waitPid.ToString(CultureInfo.InvariantCulture),
            "--install-dir",
            rootPath,
            "--expected-version",
            version.ToManifestString(),
        ];
    }

    internal static async Task<bool> LaunchVerifiedSetupAsync(
        ReleaseUpdateResult update,
        string root,
        int waitPid,
        CancellationToken cancellationToken)
    {
        if (!update.IsAvailable || update.SetupPath is null || update.Sha256 is null || update.Size <= 0 || waitPid <= 0)
            return false;

        try
        {
            var rootPath = Path.GetFullPath(root);
            if (!IsInstalledBuild(rootPath, out var installed)
                || !ReleaseVersion.TryParse(update.Version, requireVPrefix: true, out var selectedVersion)
                || selectedVersion.IsPrerelease
                || selectedVersion.CompareTo(installed.Version) <= 0)
                return false;
            var updatesPath = Path.Combine(rootPath, "updates");
            if (!Directory.Exists(updatesPath) || HasReparsePointInChain(updatesPath))
                return false;
            var expectedPath = Path.Combine(updatesPath, SetupName);
            if (!PathsEqual(update.SetupPath, expectedPath) || !IsRegularFile(expectedPath))
                return false;
            if (!await VerifyFileAsync(expectedPath, update.Size, update.Sha256, cancellationToken).ConfigureAwait(false))
                return false;

            var startInfo = new ProcessStartInfo
            {
                FileName = expectedPath,
                UseShellExecute = false,
                CreateNoWindow = true,
                WorkingDirectory = rootPath,
            };
            foreach (var argument in BuildUpdateArguments(rootPath, waitPid, update.Version!))
                startInfo.ArgumentList.Add(argument);
            using var process = Process.Start(startInfo);
            return process is not null;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
        {
            return false;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static ReleaseSelectionDisposition SelectRelease(
        JsonElement release,
        ReleaseVersion current,
        out ReleaseSelection? selection)
    {
        selection = null;
        if (release.ValueKind != JsonValueKind.Object
            || !TryGetBoolean(release, "draft", out var draft)
            || !TryGetBoolean(release, "prerelease", out var prerelease)
            || draft
            || prerelease
            || !TryGetString(release, "tag_name", out var tag)
            || !ReleaseVersion.TryParse(tag, requireVPrefix: true, out var version)
            || version.IsPrerelease)
            return ReleaseSelectionDisposition.Error;

        var comparison = version.CompareTo(current);
        if (comparison <= 0)
            return ReleaseSelectionDisposition.None;
        if (!release.TryGetProperty("assets", out var assets) || assets.ValueKind != JsonValueKind.Array)
            return ReleaseSelectionDisposition.Error;

        JsonElement selectedAsset = default;
        var found = false;
        foreach (var asset in assets.EnumerateArray())
        {
            if (asset.ValueKind != JsonValueKind.Object
                || !TryGetString(asset, "name", out var name)
                || !name.Equals(SetupName, StringComparison.Ordinal))
                continue;
            if (found) return ReleaseSelectionDisposition.Error;
            found = true;
            selectedAsset = asset;
        }

        if (!found
            || !TryGetString(selectedAsset, "state", out var state)
            || !state.Equals("uploaded", StringComparison.Ordinal)
            || !TryGetInt64(selectedAsset, "size", out var size)
            || size <= 0
            || size > MaxAssetBytes
            || !TryGetString(selectedAsset, "browser_download_url", out var downloadUrl)
            || !IsTrustedDownloadUri(downloadUrl)
            || !TryGetString(selectedAsset, "digest", out var digest)
            || !IsDigestSha256(digest))
            return ReleaseSelectionDisposition.Error;

        selection = new ReleaseSelection(version, downloadUrl, size, digest);
        return ReleaseSelectionDisposition.Ready;
    }

    private static HttpClient CreateHttpClient()
    {
        var handler = new HttpClientHandler
        {
            AllowAutoRedirect = true,
            AutomaticDecompression = DecompressionMethods.GZip | DecompressionMethods.Deflate | DecompressionMethods.Brotli,
            UseCookies = false,
            Credentials = null,
            PreAuthenticate = false,
            MaxAutomaticRedirections = 5,
        };
        var client = new HttpClient(handler)
        {
            Timeout = Timeout.InfiniteTimeSpan,
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd(UserAgent);
        client.DefaultRequestHeaders.Accept.Add(new MediaTypeWithQualityHeaderValue("application/vnd.github+json"));
        client.DefaultRequestHeaders.TryAddWithoutValidation("X-GitHub-Api-Version", GitHubApiVersion);
        return client;
    }

    private static async Task<string?> DownloadVerifiedAsync(
        string root,
        ReleaseSelection selection,
        HttpClient client,
        CancellationToken cancellationToken)
    {
        string? stagingPath = null;
        try
        {
            if (!TryPrepareUpdateDirectory(root, out var updatesDirectory, out var finalPath))
                return null;
            stagingPath = Path.Combine(updatesDirectory, $".{SetupName}.{Guid.NewGuid():N}.tmp");
            if (!IsContained(updatesDirectory, stagingPath)) return null;

            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            timeout.CancelAfter(DownloadTimeout);
            using var request = new HttpRequestMessage(HttpMethod.Get, selection.DownloadUrl);
            using var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, timeout.Token).ConfigureAwait(false);
            if (!response.IsSuccessStatusCode)
                return null;
            if (response.Content.Headers.ContentLength is { } contentLength && contentLength != selection.Size)
                return null;

            await using (var input = await response.Content.ReadAsStreamAsync(timeout.Token).ConfigureAwait(false))
            await using (var output = new FileStream(
                stagingPath,
                FileMode.CreateNew,
                FileAccess.Write,
                FileShare.None,
                64 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan))
            using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                var buffer = new byte[64 * 1024];
                long total = 0;
                while (true)
                {
                    var read = await input.ReadAsync(buffer.AsMemory(), timeout.Token).ConfigureAwait(false);
                    if (read == 0) break;
                    if (read > selection.Size - total)
                        return null;
                    await output.WriteAsync(buffer.AsMemory(0, read), timeout.Token).ConfigureAwait(false);
                    hash.AppendData(buffer, 0, read);
                    total += read;
                }

                if (total != selection.Size)
                    return null;
                var actual = Convert.ToHexString(hash.GetHashAndReset());
                if (!CryptographicOperations.FixedTimeEquals(
                        Encoding.ASCII.GetBytes(actual),
                        Encoding.ASCII.GetBytes(selection.Sha256["sha256:".Length..].ToUpperInvariant())))
                    return null;
                await output.FlushAsync(timeout.Token).ConfigureAwait(false);
                output.Flush(flushToDisk: true);
            }

            if (!AtomicInstall(stagingPath, finalPath))
                return null;
            stagingPath = null;
            return await VerifyFileAsync(finalPath, selection.Size, selection.Sha256, timeout.Token).ConfigureAwait(false)
                ? finalPath
                : null;
        }
        catch (Exception) when (cancellationToken.IsCancellationRequested)
        {
            return null;
        }
        catch (Exception)
        {
            return null;
        }
        finally
        {
            if (stagingPath is not null)
            {
                try
                {
                    if (IsRegularFile(stagingPath)) File.Delete(stagingPath);
                }
                catch (Exception) { }
            }
            TryRemoveEmptyUpdateDirectory(root);
        }
    }

    private static bool TryPrepareUpdateDirectory(string root, out string updatesDirectory, out string finalPath)
    {
        updatesDirectory = string.Empty;
        finalPath = string.Empty;
        try
        {
            var rootPath = Path.GetFullPath(root);
            if (!Directory.Exists(rootPath) || HasReparsePointInChain(rootPath)) return false;
            updatesDirectory = Path.GetFullPath(Path.Combine(rootPath, "updates"));
            if (!IsContained(rootPath, updatesDirectory)) return false;
            if (Directory.Exists(updatesDirectory))
            {
                if (HasReparsePointInChain(updatesDirectory)) return false;
            }
            else
            {
                Directory.CreateDirectory(updatesDirectory);
                if (!Directory.Exists(updatesDirectory) || HasReparsePointInChain(updatesDirectory)) return false;
            }

            RemoveStaleDownloadFiles(updatesDirectory);
            finalPath = Path.GetFullPath(Path.Combine(updatesDirectory, SetupName));
            if (!IsContained(updatesDirectory, finalPath) || HasReparsePointInChain(finalPath)) return false;
            if (TryGetAttributes(finalPath, out var attributes))
            {
                if ((attributes & FileAttributes.ReparsePoint) != 0
                    || (attributes & FileAttributes.Directory) != 0)
                    return false;
            }
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool AtomicInstall(string stagingPath, string finalPath)
    {
        try
        {
            if (!IsRegularFile(stagingPath)) return false;
            if (TryGetAttributes(finalPath, out var attributes))
            {
                if ((attributes & (FileAttributes.ReparsePoint | FileAttributes.Directory)) != 0)
                    return false;
                File.Replace(stagingPath, finalPath, destinationBackupFileName: null, ignoreMetadataErrors: true);
            }
            else
            {
                File.Move(stagingPath, finalPath);
            }
            return IsRegularFile(finalPath);
        }
        catch (PlatformNotSupportedException)
        {
            try
            {
                if (!IsRegularFile(stagingPath)) return false;
                File.Move(stagingPath, finalPath, overwrite: true);
                return IsRegularFile(finalPath);
            }
            catch (Exception) { return false; }
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static async Task<bool> VerifyFileAsync(
        string path,
        long expectedSize,
        string expectedDigest,
        CancellationToken cancellationToken)
    {
        if (!IsRegularFile(path) || !IsDigestSha256(expectedDigest) || expectedSize <= 0 || expectedSize > MaxAssetBytes)
            return false;
        try
        {
            await using var stream = new FileStream(
                path,
                FileMode.Open,
                FileAccess.Read,
                FileShare.Read,
                64 * 1024,
                FileOptions.Asynchronous | FileOptions.SequentialScan);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[64 * 1024];
            long total = 0;
            while (true)
            {
                var read = await stream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
                if (read == 0) break;
                total += read;
                if (total > expectedSize) return false;
                hash.AppendData(buffer, 0, read);
            }
            if (total != expectedSize) return false;
            var actual = Convert.ToHexString(hash.GetHashAndReset());
            return actual.Equals(expectedDigest["sha256:".Length..], StringComparison.OrdinalIgnoreCase);
        }
        catch (Exception) when (cancellationToken.IsCancellationRequested)
        {
            return false;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool TryReadInstalledManifest(string path, out InstalledManifest manifest)
    {
        manifest = default;
        try
        {
            if (!IsRegularFile(path)) return false;
            var bytes = ReadBoundedFile(path, MaxReleaseMetadataBytes);
            using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 32 });
            var root = document.RootElement;
            if (root.ValueKind != JsonValueKind.Object
                || !TryGetInt32(root, "schemaVersion", out var schemaVersion)
                || schemaVersion != 1
                || !TryGetString(root, "product", out var product)
                || !product.Equals(Product, StringComparison.Ordinal)
                || !TryGetString(root, "version", out var versionText)
                || !ReleaseVersion.TryParse(versionText, requireVPrefix: false, out var version)
                || version.IsPrerelease
                || !TryGetString(root, "executable", out var executable)
                || !executable.Equals(Executable, StringComparison.Ordinal)
                || !root.TryGetProperty("files", out var files)
                || files.ValueKind != JsonValueKind.Array)
                return false;

            var paths = new HashSet<string>(StringComparer.Ordinal);
            var executableFound = false;
            foreach (var file in files.EnumerateArray())
            {
                if (file.ValueKind != JsonValueKind.Object
                    || !TryGetString(file, "path", out var relativePath)
                    || !IsSafeManifestPath(relativePath)
                    || relativePath.Equals("release-manifest.json", StringComparison.Ordinal)
                    || !paths.Add(relativePath)
                    || !TryGetInt64(file, "length", out var length)
                    || length < 0
                    || !TryGetString(file, "sha256", out var digest)
                    || !IsHexSha256(digest))
                    return false;
                executableFound |= relativePath.Equals(Executable, StringComparison.Ordinal);
            }

            if (!executableFound) return false;
            manifest = new InstalledManifest(version);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    private static bool IsSafeManifestPath(string path)
    {
        if (string.IsNullOrEmpty(path) || path.Contains('\\') || path.StartsWith("/", StringComparison.Ordinal)
            || path.Contains("//", StringComparison.Ordinal))
            return false;
        var segments = path.Split('/');
        foreach (var segment in segments)
            if (segment.Length == 0 || segment is "." or "..") return false;
        return true;
    }

    private static bool IsHexSha256(string? digest)
    {
        if (digest is null || digest.Length != 64) return false;
        foreach (var character in digest)
            if (character is not (>= '0' and <= '9')
                and not (>= 'a' and <= 'f')
                and not (>= 'A' and <= 'F'))
                return false;
        return true;
    }

    private static bool IsTrustedDownloadUri(string value)
    {
        if (!Uri.TryCreate(value, UriKind.Absolute, out var uri)
            || uri.Scheme != Uri.UriSchemeHttps
            || !uri.IsDefaultPort
            || uri.UserInfo.Length != 0
            || !uri.Host.Equals("github.com", StringComparison.OrdinalIgnoreCase)
            || string.IsNullOrEmpty(uri.AbsolutePath))
            return false;
        return true;
    }

    private static bool TryGetString(JsonElement element, string property, out string value)
    {
        value = string.Empty;
        return element.TryGetProperty(property, out var propertyValue)
            && propertyValue.ValueKind == JsonValueKind.String
            && (value = propertyValue.GetString() ?? string.Empty).Length > 0;
    }

    private static bool TryGetBoolean(JsonElement element, string property, out bool value)
    {
        value = false;
        if (!element.TryGetProperty(property, out var propertyValue)
            || propertyValue.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            return false;
        value = propertyValue.GetBoolean();
        return true;
    }

    private static bool TryGetInt64(JsonElement element, string property, out long value)
    {
        value = 0;
        return element.TryGetProperty(property, out var propertyValue)
            && propertyValue.ValueKind == JsonValueKind.Number
            && propertyValue.TryGetInt64(out value);
    }

    private static bool TryGetInt32(JsonElement element, string property, out int value)
    {
        value = 0;
        return element.TryGetProperty(property, out var propertyValue)
            && propertyValue.ValueKind == JsonValueKind.Number
            && propertyValue.TryGetInt32(out value);
    }

    private static async Task<byte[]> ReadBoundedAsync(Stream stream, long maxBytes, CancellationToken cancellationToken)
    {
        await using var ownedStream = stream;
        using var output = new MemoryStream();
        var buffer = new byte[16 * 1024];
        long total = 0;
        while (true)
        {
            var read = await ownedStream.ReadAsync(buffer.AsMemory(), cancellationToken).ConfigureAwait(false);
            if (read == 0) break;
            total += read;
            if (total > maxBytes) throw new InvalidDataException("Response exceeded the bounded size.");
            output.Write(buffer, 0, read);
        }
        return output.ToArray();
    }

    private static byte[] ReadBoundedFile(string path, long maxBytes)
    {
        var info = new FileInfo(path);
        if (info.Length < 0 || info.Length > maxBytes || info.Length > int.MaxValue)
            throw new InvalidDataException("Manifest exceeded the bounded size.");
        return File.ReadAllBytes(path);
    }

    private static bool IsRegularFile(string path)
        => !HasReparsePointInChain(path)
            && TryGetAttributes(path, out var attributes)
            && (attributes & (FileAttributes.Directory | FileAttributes.ReparsePoint)) == 0;

    private static bool IsReparsePoint(string path)
        => TryGetAttributes(path, out var attributes)
            && (attributes & FileAttributes.ReparsePoint) != 0;

    private static bool HasReparsePointInChain(string path)
    {
        var current = Path.GetFullPath(path);
        while (true)
        {
            try
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    return true;
            }
            catch (Exception error) when (error is FileNotFoundException or DirectoryNotFoundException)
            {
            }
            catch
            {
                return true;
            }

            var parent = Directory.GetParent(current)?.FullName;
            if (string.IsNullOrWhiteSpace(parent) || PathsEqual(parent, current))
                return false;
            current = parent;
        }
    }

    private static void RemoveStaleDownloadFiles(string updatesDirectory)
    {
        foreach (var path in Directory.EnumerateFiles(updatesDirectory, $".{SetupName}.*.tmp", SearchOption.TopDirectoryOnly))
        {
            if (IsRegularFile(path))
                File.Delete(path);
        }
    }

    private static void TryRemoveEmptyUpdateDirectory(string root)
    {
        try
        {
            var updatesDirectory = Path.Combine(Path.GetFullPath(root), "updates");
            if (Directory.Exists(updatesDirectory)
                && !HasReparsePointInChain(updatesDirectory)
                && !Directory.EnumerateFileSystemEntries(updatesDirectory).Any())
                Directory.Delete(updatesDirectory);
        }
        catch
        {
        }
    }

    private static bool TryGetAttributes(string path, out FileAttributes attributes)
    {
        try
        {
            attributes = File.GetAttributes(path);
            return true;
        }
        catch (FileNotFoundException)
        {
            attributes = default;
            return false;
        }
        catch (DirectoryNotFoundException)
        {
            attributes = default;
            return false;
        }
        catch (UnauthorizedAccessException)
        {
            attributes = default;
            return false;
        }
    }

    private static bool PathsEqual(string left, string right)
        => string.Equals(TrimDirectorySeparator(Path.GetFullPath(left)), TrimDirectorySeparator(Path.GetFullPath(right)), StringComparison.OrdinalIgnoreCase);

    private static bool IsContained(string root, string child)
    {
        var rootPath = TrimDirectorySeparator(Path.GetFullPath(root));
        var childPath = TrimDirectorySeparator(Path.GetFullPath(child));
        return childPath.StartsWith(rootPath + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase);
    }

    private static string TrimDirectorySeparator(string value)
    {
        while (value.Length > 3
            && (value[^1] == Path.DirectorySeparatorChar || value[^1] == Path.AltDirectorySeparatorChar))
            value = value[..^1];
        return value;
    }
}

internal static class ReleaseUpdaterChecks
{
    internal static void Run(string root)
    {
        if (!ReleaseVersion.TryParse("v1.2.3", requireVPrefix: true, out var oneTwoThree)
            || !ReleaseVersion.TryParse("v1.2.4", requireVPrefix: true, out var oneTwoFour)
            || oneTwoFour.CompareTo(oneTwoThree) <= 0
            || ReleaseVersion.TryParse("1.2.3", requireVPrefix: true, out _)
            || ReleaseVersion.TryParse("v01.2.3", requireVPrefix: true, out _)
            || !ReleaseVersion.TryParse("v1.2.3-alpha.1", requireVPrefix: true, out var prerelease)
            || oneTwoThree.CompareTo(prerelease) <= 0)
            throw new SelfCheckException("Release SemVer ordering or strict parsing failed.");

        const string digest = "sha256:0000000000000000000000000000000000000000000000000000000000000000";
        var validDigest = "sha256:" + Convert.ToHexString(SHA256.HashData("offline-check"u8));
        if (!ReleaseUpdater.IsDigestSha256(digest)
            || !ReleaseUpdater.IsDigestSha256(validDigest)
            || !ReleaseUpdater.HashMatches("offline-check"u8, validDigest)
            || ReleaseUpdater.IsDigestSha256("sha256:000000000000000000000000000000000000000000000000000000000000000")
            || ReleaseUpdater.IsDigestSha256("sha256:00000000000000000000000000000000000000000000000000000000000000xz")
            || ReleaseUpdater.HashMatches("offline-check"u8, digest)
            || ReleaseUpdater.HashMatches("offline-check"u8, "sha256:ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"))
            throw new SelfCheckException("Release digest or hash rejection failed.");

        var releaseJson = $$"""
            {
              "tag_name": "v0.1.1",
              "draft": false,
              "prerelease": false,
              "assets": [
                {
                  "name": "Nativune-Setup.exe",
                  "state": "uploaded",
                  "size": 12,
                  "browser_download_url": "https://github.com/Hantu-Raya/Nativune/releases/download/v0.1.1/Nativune-Setup.exe",
                  "digest": "{{digest}}"
                }
              ]
            }
            """;
        if (ReleaseUpdater.SelectReleaseForChecks(releaseJson, "0.1.0", out var selection) != ReleaseSelectionDisposition.Ready
            || selection is null
            || selection.VersionText != "v0.1.1"
            || ReleaseUpdater.SelectReleaseForChecks(releaseJson.Replace("\"state\": \"uploaded\"", "\"state\": \"new\"", StringComparison.Ordinal), "0.1.0", out _) != ReleaseSelectionDisposition.Error
            || ReleaseUpdater.SelectReleaseForChecks(releaseJson.Replace("\"draft\": false", "\"draft\": true", StringComparison.Ordinal), "0.1.0", out _) != ReleaseSelectionDisposition.Error
            || ReleaseUpdater.SelectReleaseForChecks(releaseJson.Replace("github.com", "example.com", StringComparison.Ordinal), "0.1.0", out _) != ReleaseSelectionDisposition.Error
            || ReleaseUpdater.SelectReleaseForChecks(releaseJson.Replace(digest, "sha256:bad", StringComparison.Ordinal), "0.1.0", out _) != ReleaseSelectionDisposition.Error
            || ReleaseUpdater.SelectReleaseForChecks(releaseJson, "0.1.1", out _) != ReleaseSelectionDisposition.None)
            throw new SelfCheckException("Release or asset selection checks failed.");

        const string notes = "# Nativune 0.1.11\n\nIntro boilerplate.\n\n## What's fixed\n\n- **Title bar** after [Compact](https://x.test).\n\n## Install\n\n1. Download `Nativune-Setup.exe`.\n\n## Build and known limits\n\nCI run.";
        if (ReleaseUpdater.SummarizeReleaseNotes(notes) != "What's fixed\n• Title bar after Compact.")
            throw new SelfCheckException("Release-note summary did not keep only the change sections as plain text.");
        var listJson = """
            [
              { "tag_name": "v0.1.12", "draft": false, "prerelease": false, "body": "## New\n- twelve" },
              { "tag_name": "v0.1.11", "draft": false, "prerelease": false, "body": "## Fixed\n- eleven" },
              { "tag_name": "v0.1.11-beta.1", "draft": false, "prerelease": true, "body": "## Beta\n- beta" },
              { "tag_name": "v0.1.10", "draft": false, "prerelease": false, "body": "## New\n- ten" },
              { "tag_name": "v0.1.9", "draft": false, "prerelease": false, "body": "## Old\n- nine" }
            ]
            """;
        if (ReleaseUpdater.BuildChangeSummary(listJson, "v0.1.9", "v0.1.11", "fallback") != "v0.1.11\nFixed\n• eleven\n\nv0.1.10\nNew\n• ten"
            || ReleaseUpdater.BuildChangeSummary("not json", "v0.1.9", "v0.1.11", "## Fixed\n- eleven") != "v0.1.11\nFixed\n• eleven")
            throw new SelfCheckException("Update change summary did not cover exactly the installed-to-offered release range.");

        var available = new ReleaseUpdateResult(
            ReleaseUpdateStatus.Available,
            selection!.VersionText,
            selection.DownloadUrl,
            null,
            selection.Size,
            selection.Sha256,
            null);
        if (!available.IsAvailable || available.SetupPath is not null)
            throw new SelfCheckException("Update availability must be reported before downloading the installer.");

        var directory = Path.Combine(root, "release-updater-check-" + Guid.NewGuid().ToString("N"));
        try
        {
            var app = Path.Combine(directory, "app");
            Directory.CreateDirectory(app);
            File.WriteAllText(Path.Combine(app, "Nativune.exe"), "stub");
            var manifest = $$"""
                {
                  "schemaVersion": 1,
                  "product": "Nativune",
                  "version": "0.1.0",
                  "executable": "app/Nativune.exe",
                  "files": [{ "path": "app/Nativune.exe", "length": 4, "sha256": "{{new string('0', 64)}}" }]
                }
                """;
            File.WriteAllText(Path.Combine(directory, "release-manifest.json"), manifest);
            var nonInstalledResult = ReleaseUpdater.CheckAsync(directory, CancellationToken.None)
                .GetAwaiter().GetResult();
            if (!ReleaseUpdater.IsInstalledBuild(directory, app)
                || ReleaseUpdater.IsInstalledBuild(directory, Path.Combine(directory, "source"))
                || ReleaseUpdater.IsInstalledBuild(directory, app + Path.DirectorySeparatorChar + "nested")
                || nonInstalledResult.Status != ReleaseUpdateStatus.NotInstalled)
                throw new SelfCheckException("Installed-mode gating failed.");
        }
        finally
        {
            try { if (Directory.Exists(directory)) Directory.Delete(directory, recursive: true); }
            catch (Exception) { throw new SelfCheckException("Release updater check data could not be removed."); }
        }

        var arguments = ReleaseUpdater.BuildUpdateArguments(Path.Combine(root, "installed root"), 1234, "v0.1.1");
        var expectedArguments = new[]
        {
            "--update", "--wait-pid", "1234", "--install-dir", Path.GetFullPath(Path.Combine(root, "installed root")),
            "--expected-version", "0.1.1",
        };
        if (!arguments.SequenceEqual(expectedArguments, StringComparer.Ordinal))
            throw new SelfCheckException("Update command arguments failed.");
    }
}
