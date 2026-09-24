using System.Buffers.Binary;
using System.Diagnostics;
using System.Net;
using System.Security.Cryptography.X509Certificates;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Windows.ApplicationModel;
using Windows.Management.Deployment;
using Windows.System;

namespace Nativune.Installer;

internal enum PrerequisiteTestScenario
{
    None,
    Present,
    Missing,
    Declined,
    Offline,
}

internal sealed record PrerequisiteDefinition(
    string Id,
    string Name,
    string Version,
    Uri DownloadUri,
    Uri InformationUri,
    string[] Arguments,
    long MaxDownloadBytes,
    bool RequireX64Executable,
    int InstallOrder);

internal sealed record MissingPrerequisite(PrerequisiteDefinition Definition, string Reason);

internal sealed class PrerequisitePlan : IDisposable
{
    internal PrerequisitePlan(
        IReadOnlyList<MissingPrerequisite> missing,
        string? downloadDirectory,
        PrerequisiteTestScenario testScenario = PrerequisiteTestScenario.None)
    {
        Missing = missing;
        DownloadDirectory = downloadDirectory;
        TestScenario = testScenario;
    }

    internal IReadOnlyList<MissingPrerequisite> Missing { get; }
    internal string? DownloadDirectory { get; }
    internal PrerequisiteTestScenario TestScenario { get; }

    internal string GetInstallerPath(MissingPrerequisite item)
    {
        if (DownloadDirectory is null)
        {
            throw new SetupException(ExitCode.PrerequisiteFailure, "The prerequisite download is unavailable.");
        }
        return Path.Combine(DownloadDirectory, $"{item.Definition.Id}.exe");
    }

    public void Dispose() => InstallRoot.TryDeleteDirectory(DownloadDirectory);
}

internal static class PrerequisiteInstaller
{
    private const long MaxDownloadBytes = 256L * 1024 * 1024;
    private const int MaxRedirects = 8;
    private const int MaxPeHeaderOffset = 16 * 1024 * 1024;
    private static readonly TimeSpan InstallerTimeout = TimeSpan.FromMinutes(10);
    private static readonly Version RequiredDotNetMajorVersion = new(10, 0, 0);
    private static readonly Version MinimumVcRuntimeVersion = new(14, 0, 0, 0);
    private static readonly Version MinimumWebView2Version = new(152, 0, 4191, 62);
    private static readonly Guid WebView2RuntimeClientId = new("F3017226-FE2A-4295-8BDF-00C3A9A7E4C5");
    private static readonly Version WindowsAppSdkMinimumVersion = new(2, 5, 1, 0);
    private static readonly Version WindowsAppSdkSingletonMinimumVersion = new(8002, 5, 1, 0);

    private static readonly PrerequisiteDefinition[] Definitions =
    [
        new(
            "vcredist-x64",
            "Microsoft Visual C++ v14 Redistributable (x64, latest supported)",
            "latest supported v14 x64",
            new Uri("https://aka.ms/vc14/vc_redist.x64.exe"),
            new Uri("https://learn.microsoft.com/en-us/cpp/windows/latest-supported-vc-redist?view=msvc-170"),
            ["/install", "/quiet", "/norestart"],
            MaxDownloadBytes,
            RequireX64Executable: true,
            InstallOrder: 0),
        new(
            "dotnet-runtime-x64",
            ".NET 10 Runtime (x64)",
            "10.0.x x64",
            new Uri("https://builds.dotnet.microsoft.com/dotnet/Runtime/10.0.12/dotnet-runtime-10.0.12-win-x64.exe"),
            new Uri("https://dotnet.microsoft.com/en-us/download/dotnet/thank-you/runtime-10.0.12-windows-x64-installer"),
            ["/install", "/quiet", "/norestart"],
            MaxDownloadBytes,
            RequireX64Executable: true,
            InstallOrder: 1),
        new(
            "webview2-evergreen-x64",
            "Microsoft Edge WebView2 Evergreen Runtime (x64)",
            $"at least {MinimumWebView2Version}",
            new Uri("https://go.microsoft.com/fwlink/?LinkId=2124703"),
            new Uri("https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution"),
            ["/silent", "/install"],
            MaxDownloadBytes,
            RequireX64Executable: false,
            InstallOrder: 2),
        new(
            "windows-app-sdk-2-5-1-x64",
            "Windows App SDK Runtime 2.5.1 (x64)",
            "2.5.1.0 x64 runtime package set",
            new Uri("https://aka.ms/windowsappsdk/2.5/2.5.1/windowsappruntimeinstall-x64.exe"),
            new Uri("https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/downloads"),
            ["--quiet"],
            MaxDownloadBytes,
            RequireX64Executable: true,
            InstallOrder: 3),
    ];

    private static readonly HashSet<string> DownloadHosts = new(StringComparer.OrdinalIgnoreCase)
    {
        "aka.ms",
        "go.microsoft.com",
        "download.microsoft.com",
        "builds.dotnet.microsoft.com",
        "download.visualstudio.microsoft.com",
        "msedge.sf.dl.delivery.mp.microsoft.com",
    };

    internal static PrerequisitePlan Prepare(SetupOptions options, string installRoot)
    {
#if INSTALLER_TEST_HOOKS
        if (options.TestPrerequisiteScenario != PrerequisiteTestScenario.None)
        {
            return PrepareInjected(options.TestPrerequisiteScenario);
        }
#endif

        IReadOnlyList<MissingPrerequisite> missing;
        try
        {
            missing = DetectMissing();
        }
        catch (SetupException)
        {
            throw;
        }
        catch (Exception error)
        {
            throw new SetupException(
                ExitCode.PrerequisiteFailure,
                "Nativune Setup could not verify the required Windows prerequisites. No Nativune files were changed. " +
                "Check that Windows package information is available, then try again. Official sources:\n\n" +
                FormatLinks(Definitions.Select(definition => new MissingPrerequisite(definition, "availability could not be verified"))),
                error);
        }

        if (missing.Count == 0)
        {
            return new PrerequisitePlan(missing, downloadDirectory: null);
        }
        if (options.Silent)
        {
            throw new SetupException(ExitCode.PrerequisiteFailure, BuildSilentFailure(missing));
        }

        var consent =
            "Nativune requires the following prerequisite(s), which are missing or below the required version. " +
            "Setup will download and install only the listed items, after validating each Microsoft Authenticode signature. " +
            "Prerequisites already installed will not be run again. Nativune will not be changed if you decline, a download fails, or an installer fails.\n\n" +
            FormatLinks(missing) +
            "\n\nDownload and install only these prerequisites now?";
        if (!UserInterface.Confirm(consent))
        {
            throw new SetupException(
                ExitCode.Cancelled,
                "Prerequisite installation was declined. Nativune was not changed. Run Setup interactively and explicitly approve these prerequisites, or install them yourself from the official sources:\n\n" +
                FormatLinks(missing));
        }

        string? downloadDirectory = null;
        try
        {
            IReadOnlyList<MissingPrerequisite> currentMissing;
            try
            {
                currentMissing = DetectMissing();
            }
            catch (Exception error)
            {
                throw new SetupException(
                    ExitCode.PrerequisiteFailure,
                    "Nativune Setup could not recheck prerequisite availability after consent. No Nativune files were changed. Official sources:\n\n" +
                    FormatLinks(missing),
                    error);
            }
            var approvedIds = missing.Select(item => item.Definition.Id).ToHashSet(StringComparer.Ordinal);
            if (currentMissing.Any(item => !approvedIds.Contains(item.Definition.Id)))
            {
                throw new SetupException(
                    ExitCode.PrerequisiteFailure,
                    "A different prerequisite became missing after approval. Nativune was not changed. Restart Setup to review and explicitly approve the updated list:\n\n" +
                    FormatLinks(currentMissing));
            }
            if (currentMissing.Count == 0)
            {
                return new PrerequisitePlan(currentMissing, downloadDirectory: null);
            }

            downloadDirectory = CreateDownloadDirectory(installRoot);
            foreach (var item in currentMissing.OrderBy(value => value.Definition.InstallOrder))
            {
                var path = Path.Combine(downloadDirectory, $"{item.Definition.Id}.exe");
                try
                {
                    Download(item.Definition, path);
                    using var verifiedFile = ValidateInstaller(item.Definition, path);
                }
                catch (Exception error)
                {
                    var reason = error is SetupException setupError ? setupError.Message : "The Microsoft download could not be retrieved or checked.";
                    throw new SetupException(
                        ExitCode.PrerequisiteFailure,
                        $"The {item.Definition.Name} download or signature check failed ({reason}). No installer was run and Nativune was not changed. Verify the network connection or use this official source:\n\n" +
                        FormatLinks([item]),
                        error);
                }
            }
            return new PrerequisitePlan(currentMissing, downloadDirectory);
        }
        catch
        {
            InstallRoot.TryDeleteDirectory(downloadDirectory);
            throw;
        }
    }

    internal static void InstallAndVerify(PrerequisitePlan plan)
    {
#if INSTALLER_TEST_HOOKS
        if (plan.TestScenario == PrerequisiteTestScenario.Present)
        {
            return;
        }
#endif
        if (plan.Missing.Count == 0)
        {
            return;
        }

        IReadOnlyList<MissingPrerequisite> currentMissing;
        try
        {
            currentMissing = DetectMissing();
        }
        catch (Exception error)
        {
            throw new SetupException(
                ExitCode.PrerequisiteFailure,
                "Nativune Setup could not recheck prerequisite availability. No Nativune files were changed. Official sources:\n\n" +
                FormatLinks(plan.Missing),
                error);
        }

        var currentIds = currentMissing.Select(item => item.Definition.Id).ToHashSet(StringComparer.Ordinal);
        var installersToRun = plan.Missing
            .Where(item => currentIds.Contains(item.Definition.Id))
            .OrderBy(item => item.Definition.InstallOrder)
            .ToArray();
        foreach (var item in installersToRun)
        {
            var installerPath = plan.GetInstallerPath(item);
            try
            {
                using var verifiedFile = ValidateInstaller(item.Definition, installerPath);
                RunInstaller(item.Definition, installerPath);
            }
            catch (SetupException error)
            {
                throw new SetupException(
                    ExitCode.PrerequisiteFailure,
                    $"The {item.Definition.Name} could not be installed ({error.Message}). Nativune was not changed. Setup did not request administrator elevation. If Microsoft requires administrator rights, install this prerequisite from the official source after choosing whether to elevate:\n\n" +
                    FormatLinks([item]),
                    error);
            }
            catch (Exception error)
            {
                throw new SetupException(
                    ExitCode.PrerequisiteFailure,
                    $"The {item.Definition.Name} installer failed. Nativune was not changed. Setup did not request administrator elevation. If Microsoft requires administrator rights, install this prerequisite from the official source after choosing whether to elevate:\n\n" +
                    FormatLinks([item]),
                    error);
            }
        }

        IReadOnlyList<MissingPrerequisite> remaining;
        try
        {
            remaining = DetectMissing();
        }
        catch (Exception error)
        {
            throw new SetupException(
                ExitCode.PrerequisiteFailure,
                "Nativune Setup could not verify that the prerequisite installers completed successfully. Nativune was not changed. Official sources:\n\n" +
                FormatLinks(plan.Missing),
                error);
        }
        if (remaining.Count > 0)
        {
            throw new SetupException(
                ExitCode.PrerequisiteFailure,
                "One or more required prerequisites are still missing or below the required version after installation. Nativune was not changed. Restart Windows if requested, or install the following from the official sources:\n\n" +
                FormatLinks(remaining));
        }
    }

#if INSTALLER_TEST_HOOKS
    private static PrerequisitePlan PrepareInjected(PrerequisiteTestScenario scenario)
    {
        var injectedMissing = Definitions
            .Select(definition => new MissingPrerequisite(definition, "injected test state"))
            .ToArray();
        return scenario switch
        {
            PrerequisiteTestScenario.Present => new PrerequisitePlan([], downloadDirectory: null, testScenario: scenario),
            PrerequisiteTestScenario.Missing => throw new SetupException(
                ExitCode.PrerequisiteFailure,
                BuildSilentFailure(injectedMissing)),
            PrerequisiteTestScenario.Declined => throw new SetupException(
                ExitCode.Cancelled,
                "Prerequisite installation was declined (test hook). Nativune was not changed."),
            PrerequisiteTestScenario.Offline => throw new SetupException(
                ExitCode.PrerequisiteFailure,
                "The prerequisite sources are unavailable (offline test hook). No prerequisite installer was run and Nativune was not changed. Verify the network connection or use the official sources:\n\n" +
                FormatLinks(injectedMissing)),
            _ => throw new SetupException(ExitCode.Usage, "The prerequisite test scenario is invalid."),
        };
    }
#endif

    private static IReadOnlyList<MissingPrerequisite> DetectMissing()
    {
        var missing = new List<MissingPrerequisite>();
        if (!HasDotNetRuntime())
        {
            missing.Add(new MissingPrerequisite(
                Definitions[1],
                ".NET 10 Runtime x64 was not found in the standard machine-wide .NET runtime location."));
        }
        if (!HasVcRuntime())
        {
            missing.Add(new MissingPrerequisite(
                Definitions[0],
                "The x64 Microsoft Visual C++ v14 runtime is missing or its installed version could not be verified."));
        }

        var webViewVersions = ReadWebView2Versions();
        var supportedWebView = webViewVersions
            .Where(version => version >= MinimumWebView2Version)
            .OrderByDescending(version => version)
            .FirstOrDefault();
        if (supportedWebView is null)
        {
            var detected = webViewVersions.Count == 0
                ? "No Evergreen runtime version was found in the documented HKCU/HKLM EdgeUpdate registry locations."
                : $"Detected Evergreen version(s) {string.Join(", ", webViewVersions.OrderByDescending(version => version))}, below the required {MinimumWebView2Version}.";
            missing.Add(new MissingPrerequisite(Definitions[2], detected));
        }

        if (!HasWindowsAppSdkRuntime())
        {
            missing.Add(new MissingPrerequisite(
                Definitions[3],
                "One or more required Windows App SDK 2.5.1 framework, main, singleton, or DDLM packages are missing, have the wrong architecture, or are too old."));
        }

        return missing;
    }

    private static bool HasDotNetRuntime()
    {
        var programFiles = Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles);
        if (string.IsNullOrWhiteSpace(programFiles))
        {
            return false;
        }

        var runtimeRoot = Path.Combine(programFiles, "dotnet", "shared", "Microsoft.NETCore.App");
        if (!Directory.Exists(runtimeRoot) || InstallRoot.IsReparsePoint(runtimeRoot))
        {
            return false;
        }

        foreach (var directory in Directory.EnumerateDirectories(runtimeRoot))
        {
            var name = Path.GetFileName(directory);
            if (!Version.TryParse(name, out var version)
                || version.Major != RequiredDotNetMajorVersion.Major
                || version < RequiredDotNetMajorVersion
                || InstallRoot.IsReparsePoint(directory))
            {
                continue;
            }

            if (File.Exists(Path.Combine(directory, "System.Private.CoreLib.dll"))
                && File.Exists(Path.Combine(directory, "System.Runtime.dll")))
            {
                return true;
            }
        }
        return false;
    }

    private static bool HasVcRuntime()
    {
        using var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64);
        using var key = machine.OpenSubKey("SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x64");
        if (key is null || Convert.ToInt32(key.GetValue("Installed", 0), System.Globalization.CultureInfo.InvariantCulture) != 1)
        {
            return false;
        }

        var versionText = key.GetValue("Version") as string;
        if (versionText is null)
        {
            return false;
        }
        versionText = versionText.Trim().TrimStart('v', 'V');
        return Version.TryParse(versionText, out var version) && version >= MinimumVcRuntimeVersion;
    }

    private static List<Version> ReadWebView2Versions()
    {
        var versions = new List<Version>();
        var registryPath = $"SOFTWARE\\WOW6432Node\\Microsoft\\EdgeUpdate\\Clients\\{{{WebView2RuntimeClientId:D}}}";
        using (var machine = RegistryKey.OpenBaseKey(RegistryHive.LocalMachine, RegistryView.Registry64))
        using (var key = machine.OpenSubKey(registryPath))
        {
            AddWebView2Version(key, versions);
        }
        using (var user = RegistryKey.OpenBaseKey(RegistryHive.CurrentUser, RegistryView.Registry64))
        using (var key = user.OpenSubKey($"Software\\Microsoft\\EdgeUpdate\\Clients\\{{{WebView2RuntimeClientId:D}}}"))
        {
            AddWebView2Version(key, versions);
        }
        return versions;
    }

    private static void AddWebView2Version(RegistryKey? key, ICollection<Version> versions)
    {
        if (key?.GetValue("pv") is not string value
            || !Version.TryParse(value.Trim(), out var version)
            || version <= new Version(0, 0, 0, 0))
        {
            return;
        }
        versions.Add(version);
    }

    private static bool HasWindowsAppSdkRuntime()
    {
        var manager = new PackageManager();
        var packageRequirements = new (string FamilyName, Version MinimumVersion, ProcessorArchitecture Architecture, PackageTypes Type)[]
        {
            ("Microsoft.WindowsAppRuntime.2_8wekyb3d8bbwe", WindowsAppSdkMinimumVersion, ProcessorArchitecture.X64, PackageTypes.Framework),
            ("MicrosoftCorporationII.WinAppRuntime.Main.2_8wekyb3d8bbwe", WindowsAppSdkMinimumVersion, ProcessorArchitecture.X64, PackageTypes.Main),
            ("MicrosoftCorporationII.WinAppRuntime.Singleton_8wekyb3d8bbwe", WindowsAppSdkSingletonMinimumVersion, ProcessorArchitecture.X64, PackageTypes.Main),
            ("Microsoft.WinAppRuntime.DDLM.2.5.1.0-x6_8wekyb3d8bbwe", WindowsAppSdkMinimumVersion, ProcessorArchitecture.X64, PackageTypes.Main),
        };

        foreach (var requirement in packageRequirements)
        {
            var found = false;
            foreach (var package in manager.FindPackagesForUserWithPackageTypes(
                string.Empty,
                requirement.FamilyName,
                requirement.Type))
            {
                if (package.Id.Architecture == requirement.Architecture
                    && ToVersion(package.Id.Version) >= requirement.MinimumVersion)
                {
                    found = true;
                    break;
                }
            }
            if (!found)
            {
                return false;
            }
        }
        return true;
    }

    private static Version ToVersion(PackageVersion version)
        => new(version.Major, version.Minor, version.Build, version.Revision);

    private static string CreateDownloadDirectory(string installRoot)
        => InstallRoot.CreateAdjacentDirectory(installRoot, ".nativune-prerequisites");

    private static void Download(PrerequisiteDefinition definition, string destination)
    {
        using var handler = new HttpClientHandler
        {
            AllowAutoRedirect = false,
            UseDefaultCredentials = false,
            PreAuthenticate = false,
        };
        using var client = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromMinutes(5),
        };

        var currentUri = definition.DownloadUri;
        for (var redirectCount = 0; redirectCount <= MaxRedirects; redirectCount++)
        {
            ValidateDownloadUri(currentUri);
            using var request = new HttpRequestMessage(HttpMethod.Get, currentUri);
            using var response = client.Send(request, HttpCompletionOption.ResponseHeadersRead);
            if (IsRedirect(response.StatusCode))
            {
                if (redirectCount == MaxRedirects || response.Headers.Location is null)
                {
                    throw new IOException("The official download source redirected too many times or omitted its destination.");
                }
                currentUri = response.Headers.Location.IsAbsoluteUri
                    ? response.Headers.Location
                    : new Uri(currentUri, response.Headers.Location);
                ValidateDownloadUri(currentUri);
                continue;
            }
            if (!response.IsSuccessStatusCode)
            {
                throw new IOException("The official download source returned an unsuccessful response.");
            }
            if (response.Content.Headers.ContentLength is long contentLength
                && (contentLength <= 0 || contentLength > definition.MaxDownloadBytes))
            {
                throw new IOException("The downloaded installer size is outside the allowed range.");
            }

            using var source = response.Content.ReadAsStream();
            using var target = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            var buffer = new byte[1024 * 128];
            long written = 0;
            while (true)
            {
                var count = source.Read(buffer, 0, buffer.Length);
                if (count == 0)
                {
                    break;
                }
                written = checked(written + count);
                if (written > definition.MaxDownloadBytes)
                {
                    throw new IOException("The downloaded installer exceeded the allowed size.");
                }
                target.Write(buffer, 0, count);
            }
            target.Flush(flushToDisk: true);
            if (written == 0)
            {
                throw new IOException("The official download source returned an empty file.");
            }
            return;
        }
        throw new IOException("The official download source could not be reached safely.");
    }

    private static void ValidateDownloadUri(Uri uri)
    {
        if (!uri.IsAbsoluteUri
            || !string.Equals(uri.Scheme, Uri.UriSchemeHttps, StringComparison.OrdinalIgnoreCase)
            || uri.Port != 443
            || uri.UserInfo.Length != 0
            || !DownloadHosts.Contains(uri.IdnHost))
        {
            throw new IOException("The download URL or redirect is not an approved HTTPS Microsoft source.");
        }
    }

    private static bool IsRedirect(HttpStatusCode statusCode)
        => statusCode is HttpStatusCode.MovedPermanently
            or HttpStatusCode.Redirect
            or HttpStatusCode.SeeOther
            or HttpStatusCode.TemporaryRedirect
            or HttpStatusCode.PermanentRedirect;

    private static FileStream ValidateInstaller(PrerequisiteDefinition definition, string path)
    {
        InstallRoot.EnsureNoReparseChain(path);
        if (!File.Exists(path) || InstallRoot.IsReparsePoint(path))
        {
            throw new SetupException(ExitCode.PrerequisiteFailure, "The downloaded prerequisite installer is missing or unsafe.");
        }

        var lockedFile = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        try
        {
            if (lockedFile.Length <= 0 || lockedFile.Length > definition.MaxDownloadBytes)
            {
                throw new SetupException(ExitCode.PrerequisiteFailure, "The downloaded prerequisite installer has an invalid size.");
            }
            if (definition.RequireX64Executable && !IsX64Executable(lockedFile))
            {
                throw new SetupException(ExitCode.PrerequisiteFailure, "The downloaded prerequisite installer is not an x64 PE executable.");
            }

            VerifyMicrosoftAuthenticode(path);
            return lockedFile;
        }
        catch
        {
            lockedFile.Dispose();
            throw;
        }
    }

    private static bool IsX64Executable(Stream stream)
    {
        if (stream.Length < 64)
        {
            return false;
        }
        Span<byte> dosHeader = stackalloc byte[64];
        stream.Position = 0;
        if (stream.Read(dosHeader) != dosHeader.Length || dosHeader[0] != (byte)'M' || dosHeader[1] != (byte)'Z')
        {
            return false;
        }
        var peOffset = BinaryPrimitives.ReadInt32LittleEndian(dosHeader[0x3c..]);
        if (peOffset < dosHeader.Length || peOffset > MaxPeHeaderOffset || peOffset > stream.Length - 6)
        {
            return false;
        }
        stream.Position = peOffset;
        Span<byte> header = stackalloc byte[6];
        return stream.Read(header) == header.Length
            && header[0] == (byte)'P'
            && header[1] == (byte)'E'
            && header[2] == 0
            && header[3] == 0
            && BinaryPrimitives.ReadUInt16LittleEndian(header[4..]) == 0x8664;
    }

    private static void VerifyMicrosoftAuthenticode(string path)
    {
        var action = GenericVerifyV2;
        var fileInfo = new WinTrustFileInfo(path);
        var data = new WinTrustData(fileInfo);
        var status = -1;
        try
        {
            status = WinVerifyTrust(nint.Zero, ref action, ref data);
            data.StateAction = WinTrustStateActionClose;
            _ = WinVerifyTrust(nint.Zero, ref action, ref data);
        }
        finally
        {
            data.Free();
        }

        if (status != 0)
        {
            throw new SetupException(ExitCode.PrerequisiteFailure, "Windows Authenticode verification failed; the installer was not run.");
        }

        using var certificate = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
        var publisher = certificate.GetNameInfo(X509NameType.SimpleName, forIssuer: false);
        if (!string.Equals(publisher, "Microsoft Corporation", StringComparison.OrdinalIgnoreCase))
        {
            throw new SetupException(ExitCode.PrerequisiteFailure, "The installer is not signed by the expected Microsoft Corporation publisher.");
        }
    }

    private static void RunInstaller(PrerequisiteDefinition definition, string path)
    {
        var startInfo = new ProcessStartInfo
        {
            FileName = path,
            WorkingDirectory = Path.GetDirectoryName(path)!,
            UseShellExecute = false,
            CreateNoWindow = true,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        foreach (var argument in definition.Arguments)
        {
            startInfo.ArgumentList.Add(argument);
        }

        using var process = Process.Start(startInfo)
            ?? throw new SetupException(ExitCode.PrerequisiteFailure, "Windows could not start the signed prerequisite installer.");
        if (!process.WaitForExit((int)InstallerTimeout.TotalMilliseconds))
        {
            try
            {
                process.Kill(entireProcessTree: true);
                _ = process.WaitForExit((int)TimeSpan.FromSeconds(30).TotalMilliseconds);
            }
            catch
            {
                // The setup still fails closed; it never continues the Nativune transaction.
            }
            throw new SetupException(ExitCode.PrerequisiteFailure, "The prerequisite installer timed out.");
        }
        if (process.ExitCode is 3010 or 1641)
        {
            throw new SetupException(
                ExitCode.PrerequisiteFailure,
                "The prerequisite installer requested a Windows restart. Nativune was not changed. Restart Windows, then run Setup again.");
        }
        if (process.ExitCode != 0)
        {
            throw new SetupException(
                ExitCode.PrerequisiteFailure,
                $"The prerequisite installer exited with code 0x{unchecked((uint)process.ExitCode):X8}.");
        }
    }

    private static string BuildSilentFailure(IReadOnlyList<MissingPrerequisite> missing)
        => "Required prerequisites are missing or below the required version. In --silent mode Setup never downloads or installs prerequisites. " +
           "Nativune was not changed. Run Setup interactively and explicitly approve the listed prerequisites, or install them yourself from the official sources:\n\n" +
           FormatLinks(missing);

    private static string FormatLinks(IEnumerable<MissingPrerequisite> items)
        => string.Join(
            "\n\n",
            items.Select(item => $"{item.Definition.Name} — required {item.Definition.Version}\nStatus: {item.Reason}\nOfficial download: {item.Definition.DownloadUri}\nInformation: {item.Definition.InformationUri}"));

    private static readonly Guid GenericVerifyV2 = new("00AAC56B-CD44-11d0-8CC2-00C04FC295EE");
    private const uint WinTrustUiNone = 2;
    private const uint WinTrustChoiceFile = 1;
    private const uint WinTrustStateActionVerify = 1;
    private const uint WinTrustStateActionClose = 2;
    private const uint WinTrustRevocationChainExcludeRoot = 0x80;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WinTrustFileInfo
    {
        internal uint StructSize;
        internal IntPtr FilePath;
        internal IntPtr FileHandle;
        internal IntPtr KnownSubject;

        internal WinTrustFileInfo(string path)
        {
            StructSize = (uint)Marshal.SizeOf<WinTrustFileInfo>();
            FilePath = Marshal.StringToCoTaskMemUni(path);
            FileHandle = IntPtr.Zero;
            KnownSubject = IntPtr.Zero;
        }

        internal void Free() => Marshal.FreeCoTaskMem(FilePath);
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct WinTrustData
    {
        internal uint StructSize;
        internal IntPtr PolicyCallbackData;
        internal IntPtr SipClientData;
        internal uint UiChoice;
        internal uint RevocationChecks;
        internal uint UnionChoice;
        internal IntPtr FileInfo;
        internal uint StateAction;
        internal IntPtr StateData;
        internal IntPtr UrlReference;
        internal uint ProviderFlags;
        internal uint UiContext;
        internal IntPtr SignatureSettings;

        internal WinTrustData(WinTrustFileInfo fileInfo)
        {
            StructSize = (uint)Marshal.SizeOf<WinTrustData>();
            PolicyCallbackData = IntPtr.Zero;
            SipClientData = IntPtr.Zero;
            UiChoice = WinTrustUiNone;
            RevocationChecks = 0;
            UnionChoice = WinTrustChoiceFile;
            FileInfo = Marshal.AllocCoTaskMem(Marshal.SizeOf<WinTrustFileInfo>());
            Marshal.StructureToPtr(fileInfo, FileInfo, fDeleteOld: false);
            StateAction = WinTrustStateActionVerify;
            StateData = IntPtr.Zero;
            UrlReference = IntPtr.Zero;
            ProviderFlags = WinTrustRevocationChainExcludeRoot;
            UiContext = 0;
            SignatureSettings = IntPtr.Zero;
        }

        internal void Free()
        {
            if (FileInfo != IntPtr.Zero)
            {
                var fileInfo = Marshal.PtrToStructure<WinTrustFileInfo>(FileInfo);
                fileInfo.Free();
                Marshal.DestroyStructure<WinTrustFileInfo>(FileInfo);
                Marshal.FreeCoTaskMem(FileInfo);
                FileInfo = IntPtr.Zero;
            }
        }
    }

    [DllImport("wintrust.dll", ExactSpelling = true, PreserveSig = true)]
    private static extern int WinVerifyTrust(nint windowHandle, ref Guid actionId, ref WinTrustData trustData);
}
