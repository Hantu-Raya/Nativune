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
    WebView2Outdated,
    WebView2AtFloor,
    DownloadCheck,
}

internal sealed record PrerequisiteDefinition(
    string Id,
    string Name,
    string Version,
    Uri DownloadUri,
    Uri InformationUri,
    string[] Arguments,
    long MaxDownloadBytes,
    int InstallOrder,
    // Machine-wide installers (VC++ and the .NET runtime) cannot install from this asInvoker
    // Setup; after the user's consent Windows shows its own administrator (UAC) prompt for them.
    bool RequiresAdministrator = false);

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
    // Keep equal to the app's floor (src/Nativune/WebHost.cs); scripts/installer-fixture.ps1 checks this.
    // 152.0.4191.53 is the runtime that WebView2 SDK 1.0.4191.47 documents for full API compatibility.
    private static readonly Version MinimumWebView2Version = new(152, 0, 4191, 53);
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
            InstallOrder: 0,
            RequiresAdministrator: true),
        new(
            "dotnet-runtime-x64",
            ".NET 10 Runtime (x64)",
            "10.0.x x64",
            new Uri("https://builds.dotnet.microsoft.com/dotnet/Runtime/10.0.12/dotnet-runtime-10.0.12-win-x64.exe"),
            new Uri("https://dotnet.microsoft.com/en-us/download/dotnet/thank-you/runtime-10.0.12-windows-x64-installer"),
            ["/install", "/quiet", "/norestart"],
            MaxDownloadBytes,
            InstallOrder: 1,
            RequiresAdministrator: true),
        new(
            "webview2-evergreen-x64",
            "Microsoft Edge WebView2 Evergreen Runtime (x64)",
            $"at least {MinimumWebView2Version}",
            new Uri("https://go.microsoft.com/fwlink/?LinkId=2124703"),
            new Uri("https://learn.microsoft.com/en-us/microsoft-edge/webview2/concepts/distribution"),
            ["/silent", "/install"],
            MaxDownloadBytes,
            InstallOrder: 2),
        new(
            "windows-app-sdk-2-5-1-x64",
            "Windows App SDK Runtime 2.5.1 (x64)",
            "2.5.1.0 x64 runtime package set",
            new Uri("https://aka.ms/windowsappsdk/2.5/2.5.1/windowsappruntimeinstall-x64.exe"),
            new Uri("https://learn.microsoft.com/en-us/windows/apps/windows-app-sdk/downloads"),
            ["--quiet"],
            MaxDownloadBytes,
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

    internal static PrerequisitePlan DetectForConsent(SetupOptions options)
    {
#if INSTALLER_TEST_HOOKS
        if (options.TestPrerequisiteScenario != PrerequisiteTestScenario.None)
        {
            return PrepareInjectedForDetection(options.TestPrerequisiteScenario, options.InstallPrerequisites);
        }
#endif
        IReadOnlyList<MissingPrerequisite> missing;
        Version? outdatedWebView;
        try
        {
            outdatedWebView = FindOutdatedWebView2(ReadWebView2Versions());
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

        // The WebView2 bootstrapper cannot update an existing Evergreen runtime (it reports "already installed"),
        // so stop before consent instead of downloading and installing other prerequisites only to fail at the end.
        if (outdatedWebView is not null)
        {
            throw new SetupException(ExitCode.PrerequisiteFailure, BuildOutdatedWebView2Failure(outdatedWebView));
        }

        if (options.Silent && !options.InstallPrerequisites && missing.Count > 0)
        {
            throw new SetupException(ExitCode.PrerequisiteFailure, BuildSilentFailure(missing));
        }
        return new PrerequisitePlan(missing, downloadDirectory: null);
    }

    internal static PrerequisitePlan PrepareAfterConsent(
        PrerequisitePlan approvedPlan,
        string installRoot,
        ISetupReporter reporter,
        CancellationToken cancellationToken)
    {
#if INSTALLER_TEST_HOOKS
        if (approvedPlan.TestScenario == PrerequisiteTestScenario.Present)
        {
            return new PrerequisitePlan([], downloadDirectory: null, testScenario: PrerequisiteTestScenario.Present);
        }
        if (approvedPlan.TestScenario == PrerequisiteTestScenario.DownloadCheck)
        {
            // Real downloads, size/PE/Authenticode checks of every official installer; nothing is run.
            var all = Definitions.Select(definition => new MissingPrerequisite(definition, "download check (test hook)")).ToArray();
            using (new PrerequisitePlan(all, DownloadAndValidate(all, installRoot, reporter, cancellationToken)))
            {
            }
            return new PrerequisitePlan([], downloadDirectory: null, testScenario: PrerequisiteTestScenario.Present);
        }
#endif
        cancellationToken.ThrowIfCancellationRequested();
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
                FormatLinks(approvedPlan.Missing),
                error);
        }

        var approvedIds = approvedPlan.Missing.Select(item => item.Definition.Id).ToHashSet(StringComparer.Ordinal);
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

        return new PrerequisitePlan(currentMissing, DownloadAndValidate(currentMissing, installRoot, reporter, cancellationToken));
    }

    private static string DownloadAndValidate(
        IReadOnlyList<MissingPrerequisite> items,
        string installRoot,
        ISetupReporter reporter,
        CancellationToken cancellationToken)
    {
        string? downloadDirectory = null;
        try
        {
            downloadDirectory = CreateDownloadDirectory(installRoot);
            var ordered = items.OrderBy(value => value.Definition.InstallOrder).ToArray();
            for (var index = 0; index < ordered.Length; index++)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var item = ordered[index];
                var path = Path.Combine(downloadDirectory, $"{item.Definition.Id}.exe");
                try
                {
                    Download(item.Definition, path, reporter, index + 1, ordered.Length, cancellationToken);
                    using var verifiedFile = ValidateInstaller(item.Definition, path);
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
                {
                    throw;
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
            return downloadDirectory;
        }
        catch
        {
            InstallRoot.TryDeleteDirectory(downloadDirectory);
            throw;
        }
    }

    internal static void InstallAndVerify(
        PrerequisitePlan plan,
        ISetupReporter reporter,
        CancellationToken cancellationToken)
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

        cancellationToken.ThrowIfCancellationRequested();
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
        for (var index = 0; index < installersToRun.Length; index++)
        {
            cancellationToken.ThrowIfCancellationRequested();
            var item = installersToRun[index];
            var installerPath = plan.GetInstallerPath(item);
            try
            {
                using var verifiedFile = ValidateInstaller(item.Definition, installerPath);
                cancellationToken.ThrowIfCancellationRequested();
                reporter.Step(
                    $"Installing prerequisite {item.Definition.Name} ({index + 1} of {installersToRun.Length})… Windows may ask for permission.",
                    cancellable: false);
                reporter.Progress(0, 0);
                cancellationToken.ThrowIfCancellationRequested();
                RunInstaller(item.Definition, installerPath);
            }
            catch (OperationCanceledException)
            {
                throw;
            }
            catch (SetupException error) when (error.Code == ExitCode.Cancelled)
            {
                throw;
            }
            catch (SetupException error)
            {
                throw new SetupException(
                    ExitCode.PrerequisiteFailure,
                    $"The {item.Definition.Name} could not be installed ({error.Message}). Nativune was not changed. Run Setup again, or install this prerequisite from the official source:\n\n" +
                    FormatLinks([item]),
                    error);
            }
            catch (Exception error)
            {
                throw new SetupException(
                    ExitCode.PrerequisiteFailure,
                    $"The {item.Definition.Name} installer failed. Nativune was not changed. Run Setup again, or install this prerequisite from the official source:\n\n" +
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
    private static PrerequisitePlan PrepareInjectedForDetection(PrerequisiteTestScenario scenario, bool installPrerequisites)
    {
        var injectedMissing = Definitions
            .Select(definition => new MissingPrerequisite(definition, "injected test state"))
            .ToArray();
        return scenario switch
        {
            PrerequisiteTestScenario.Present or PrerequisiteTestScenario.DownloadCheck => new PrerequisitePlan([], downloadDirectory: null, testScenario: scenario),
            PrerequisiteTestScenario.WebView2Outdated or PrerequisiteTestScenario.WebView2AtFloor =>
                FindOutdatedWebView2([scenario == PrerequisiteTestScenario.WebView2AtFloor
                    ? MinimumWebView2Version
                    : new Version(MinimumWebView2Version.Major, MinimumWebView2Version.Minor, MinimumWebView2Version.Build, MinimumWebView2Version.Revision - 1)])
                is { } outdated
                    ? throw new SetupException(ExitCode.PrerequisiteFailure, BuildOutdatedWebView2Failure(outdated))
                    : new PrerequisitePlan([], downloadDirectory: null, testScenario: PrerequisiteTestScenario.Present),
            // --install-prerequisites would take the download-and-install path; the test hook never runs real installers.
            PrerequisiteTestScenario.Missing when installPrerequisites => throw new SetupException(
                ExitCode.PrerequisiteFailure,
                "Prerequisite installation was requested with --install-prerequisites (test hook). No prerequisite installer was run and Nativune was not changed."),
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

    // Installed (any valid pv) but every registered version is below the floor; null when absent or supported.
    private static Version? FindOutdatedWebView2(IReadOnlyCollection<Version> versions)
        => versions.Count > 0 && versions.Max()! < MinimumWebView2Version ? versions.Max() : null;

    private static string BuildOutdatedWebView2Failure(Version detected)
        => $"Microsoft Edge WebView2 Runtime {detected} is installed, but Nativune needs {MinimumWebView2Version} or later. " +
           "Nothing was installed and Nativune was not changed.\n\n" +
           "Windows updates WebView2 automatically in the background through Microsoft Edge Update; its own installer cannot update an existing copy. " +
           "Leave the PC online for a while (restarting Windows can help), then run Setup again.\n\n" +
           "Information: https://developer.microsoft.com/microsoft-edge/webview2/";

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

    private static void Download(
        PrerequisiteDefinition definition,
        string destination,
        ISetupReporter reporter,
        int itemNumber,
        int itemCount,
        CancellationToken cancellationToken)
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
            using var response = client.Send(request, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
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
            var contentLength = response.Content.Headers.ContentLength ?? 0;
            if (contentLength < 0 || contentLength > definition.MaxDownloadBytes)
            {
                throw new IOException("The downloaded installer size is outside the allowed range.");
            }

            using var source = response.Content.ReadAsStream(cancellationToken);
            using var target = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            var buffer = new byte[1024 * 128];
            long written = 0;
            ReportDownloadProgress(reporter, definition, itemNumber, itemCount, written, contentLength);
            while (true)
            {
                cancellationToken.ThrowIfCancellationRequested();
                var count = source.ReadAsync(buffer.AsMemory(), cancellationToken).AsTask().GetAwaiter().GetResult();
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
                ReportDownloadProgress(reporter, definition, itemNumber, itemCount, written, contentLength);
            }
            target.Flush(flushToDisk: true);
            cancellationToken.ThrowIfCancellationRequested();
            if (written == 0)
            {
                throw new IOException("The official download source returned an empty file.");
            }
            ReportDownloadProgress(reporter, definition, itemNumber, itemCount, written, contentLength);
            return;
        }
        throw new IOException("The official download source could not be reached safely.");
    }

    private static void ReportDownloadProgress(
        ISetupReporter reporter,
        PrerequisiteDefinition definition,
        int itemNumber,
        int itemCount,
        long downloaded,
        long total)
    {
        var text = total > 0
            ? $"Downloading prerequisite {itemNumber} of {itemCount}: {definition.Name} — {FormatBytes(downloaded)} of {FormatBytes(total)}"
            : $"Downloading prerequisite {itemNumber} of {itemCount}: {definition.Name} — {FormatBytes(downloaded)} downloaded";
        reporter.Step(text, cancellable: true);
        reporter.Progress(downloaded, total);
    }

    private static string FormatBytes(long bytes)
    {
        if (bytes >= 1_000_000)
        {
            var megabytes = bytes / 1_000_000d;
            return megabytes < 100 ? $"{megabytes:0.0} MB" : $"{megabytes:0} MB";
        }
        return bytes >= 1_000 ? $"{bytes / 1_000d:0.0} KB" : $"{bytes} B";
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
            // Official installers are x86 (the VC++ and .NET WiX Burn bundles, the WebView2 bootstrapper) or x64
            // PE files; the installed architecture is enforced by the x64-specific detection after installation.
            if (!IsWindowsExecutable(lockedFile))
            {
                throw new SetupException(ExitCode.PrerequisiteFailure, "The downloaded prerequisite installer is not an x86 or x64 Windows executable.");
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

    private static bool IsWindowsExecutable(Stream stream)
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
            && BinaryPrimitives.ReadUInt16LittleEndian(header[4..]) is 0x014c or 0x8664;
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

        // Microsoft signs these with different common names (the .NET installer's is ".NET"), so check the
        // CA-validated organization of the signer and of its issuing Microsoft code-signing CA instead.
        using var certificate = new X509Certificate2(X509Certificate.CreateFromSignedFile(path));
        if (!IsMicrosoftOrganization(certificate.SubjectName) || !IsMicrosoftOrganization(certificate.IssuerName))
        {
            throw new SetupException(ExitCode.PrerequisiteFailure, "The installer is not signed by the expected Microsoft Corporation publisher.");
        }
    }

    private static bool IsMicrosoftOrganization(X500DistinguishedName name)
    {
        var organizations = name.EnumerateRelativeDistinguishedNames()
            .Where(rdn => !rdn.HasMultipleElements && rdn.GetSingleElementType().Value == "2.5.4.10")
            .Select(rdn => rdn.GetSingleElementValue())
            .ToArray();
        return organizations.Length == 1 && string.Equals(organizations[0], "Microsoft Corporation", StringComparison.Ordinal);
    }

    private static void RunInstaller(PrerequisiteDefinition definition, string path)
    {
        const int ErrorCancelled = 1223; // The user declined the Windows UAC prompt.
        var startInfo = new ProcessStartInfo
        {
            FileName = path,
            WorkingDirectory = Path.GetDirectoryName(path)!,
            WindowStyle = ProcessWindowStyle.Hidden,
        };
        if (definition.RequiresAdministrator)
        {
            // "runas" asks Windows to show its administrator prompt; only the verified Microsoft
            // installer is elevated, never Setup or Nativune itself.
            startInfo.UseShellExecute = true;
            startInfo.Verb = "runas";
            startInfo.Arguments = string.Join(' ', definition.Arguments);
        }
        else
        {
            startInfo.UseShellExecute = false;
            startInfo.CreateNoWindow = true;
            foreach (var argument in definition.Arguments)
            {
                startInfo.ArgumentList.Add(argument);
            }
        }

        Process? started;
        try
        {
            started = Process.Start(startInfo);
        }
        catch (System.ComponentModel.Win32Exception error) when (error.NativeErrorCode == ErrorCancelled)
        {
            throw new SetupException(
                ExitCode.Cancelled,
                $"Administrator permission for the {definition.Name} was not given, so it was not installed and Nativune was not changed. " +
                "Run Setup again and choose Yes when Windows asks, or install it yourself from the official source:\n\n" +
                FormatLinks([new MissingPrerequisite(definition, "administrator permission was declined")]),
                error);
        }
        using var process = started
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
        if (definition.Id == "vcredist-x64" && process.ExitCode == 1638)
        {
            return;
        }
        if (process.ExitCode is 3010 or 1641)
        {
            throw new SetupException(
                ExitCode.PrerequisiteFailure,
                "The prerequisite installer requested a Windows restart. Nativune was not changed. Restart Windows, then run Setup again.");
        }
        if (process.ExitCode is 1602 or unchecked((int)0x800704C7))
        {
            throw new SetupException(
                ExitCode.Cancelled,
                $"The {definition.Name} installation was cancelled. Nativune was not changed. Run Setup again to install it.");
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
