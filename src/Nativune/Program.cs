namespace Nativune;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            var options = CommandLine.Parse(args);
            if (options.Help || options.Command == "help")
            {
                PrintHelp();
                return 0;
            }
            if (options.Command is not ("self-check" or "media" or "media-control" or "web" or "native-fixture" or "native-interactions" or "output-audio-fixture"))
                throw new UsageException("Unknown command. Use help for usage.");
            if ((options.Command is "native-fixture" or "native-interactions") && options.Root is null)
                throw new UsageException($"{options.Command} requires an existing --root <repository-root>.");
            var root = options.Command == "output-audio-fixture"
                ? ResolveOutputAudioFixtureRoot(options.Root)
                : RootLocator.Resolve(options.Root);
            using var cancellation = new CancellationController();
            return options.Command switch
            {
                "self-check" => SelfCheck.Run(root),
                "media" => await MediaProbe.RunAsync(false, cancellation.Cancellation),
                "media-control" => await MediaProbe.RunAsync(true, cancellation.Cancellation),
                "web" => WebHost.Run(root, options.Autostart),
                "native-fixture" => NativeFixture.Run(root, measureInteractions: false),
                "native-interactions" => NativeFixture.Run(root, measureInteractions: true),
                "output-audio-fixture" => OutputAudioFixture.Run(root),
                _ => throw new UsageException("Unknown command. Use help for usage.")
            };
        }
        catch (UsageException ex)
        {
            Console.Error.WriteLine(ex.Message);
            return 2;
        }
        catch (OperationCanceledException)
        {
            Console.Error.WriteLine("Operation cancelled or timed out.");
            return 130;
        }
        catch (SelfCheckException ex)
        {
            Console.Error.WriteLine($"Self-check failed: {ex.Message}");
            return 6;
        }
        catch (Exception)
        {
            Console.Error.WriteLine("Operation failed.");
            return 1;
        }
    }

    private static string ResolveOutputAudioFixtureRoot(string? explicitRoot)
    {
        if (explicitRoot is not null)
        {
            var root = Path.GetFullPath(explicitRoot);
            if (!Directory.Exists(root))
                throw new UsageException("output-audio-fixture requires an existing repository root.");
            return root;
        }

        return RootLocator.FindRepositoryFixtureRoot()
            ?? throw new UsageException(
                "output-audio-fixture needs a repository fixture with its project-local .tools/webview2/runtime-path.txt; pass --root <repository-root>.");
    }

    private static void PrintHelp()
    {
        Console.WriteLine("Nativune - Windows media and native shell capability probe");
        Console.WriteLine();
        Console.WriteLine("Usage: Nativune [--root <project-root>] <command>");
        Console.WriteLine("       Nativune web --root <install-root> --autostart   (used by the Windows sign-in entry)");
        Console.WriteLine();
        Console.WriteLine("Commands:");
        Console.WriteLine("  help       Show this help (the default command)");
        Console.WriteLine("  self-check Verify shell settings, WebView navigation origins, and release updater checks");
        Console.WriteLine("  media      List Windows media sessions and supported controls (read-only)");
        Console.WriteLine("  media-control Select a session and interactively inspect/control it");
        Console.WriteLine("  web        Open official YouTube Music in an isolated WebView2 profile");
        Console.WriteLine("  native-fixture Show the account-free native Compact/Settings fixture for 60 seconds");
        Console.WriteLine("  native-interactions Measure the account-free native Compact/Settings interactions");
        Console.WriteLine("  output-audio-fixture Explicitly run the account-free local WebView2 audio-session check");
        Console.WriteLine();
        Console.WriteLine("The web command stores its separate WebView2 profile only under data/webview2.");
        Console.WriteLine("Media commands inspect Windows media sessions and never close the browser.");
        Console.WriteLine("Media output omits track titles/artists; exit 7 means no/removed session, 8 means Windows access failed.");
        Console.WriteLine("native-fixture and native-interactions require an existing --root and run local native UI checks only.");
        Console.WriteLine("output-audio-fixture uses a fresh temporary profile under repository-local data/; click Start test tone when ready. It never runs during self-check.");
    }
}

internal sealed record CliOptions(string Command, string? Root, bool Help, bool Autostart = false);

internal static class CommandLine
{
    public static CliOptions Parse(string[] args)
    {
        if (args.Length == 0)
            return new CliOptions("help", null, true);

        string? command = null;
        string? root = null;
        var help = false;
        var autostart = false;
        for (var i = 0; i < args.Length; i++)
        {
            var arg = args[i];
            if (arg is "--help" or "-h")
            {
                help = true;
                continue;
            }

            if (arg == "--autostart")
            {
                autostart = true;
                continue;
            }

            if (arg == "--root")
            {
                if (++i >= args.Length || string.IsNullOrWhiteSpace(args[i]))
                    throw new UsageException("--root requires a project root.");
                root = args[i];
                continue;
            }

            if (arg.StartsWith("--root=", StringComparison.Ordinal))
            {
                root = arg[7..];
                if (string.IsNullOrWhiteSpace(root))
                    throw new UsageException("--root requires a project root.");
                continue;
            }

            if (arg.StartsWith("-", StringComparison.Ordinal))
                throw new UsageException($"Unknown option '{arg}'. Use help for usage.");
            if (command is not null)
                throw new UsageException("Only one command may be supplied.");
            command = arg.ToLowerInvariant();
        }

        if (autostart && command is not "web")
            throw new UsageException("--autostart is only valid with the web command.");
        return new CliOptions(command ?? "help", root, help, autostart);
    }
}

internal static class RootLocator
{
    public static string Resolve(string? explicitRoot)
    {
        if (explicitRoot is not null)
        {
            var root = Path.GetFullPath(explicitRoot);
            if (!Directory.Exists(root))
                throw new UsageException("The specified project root does not exist.");
            return root;
        }

        var installedRoot = FindInstalledRoot();
        if (installedRoot is null)
            throw new UsageException(
                "Could not locate a verified per-user Nativune installation beside this executable. Specify --root <installation-or-project-root>.");
        return installedRoot;
    }

    public static string? FindInstalledRoot()
    {
        var appDirectory = Path.TrimEndingDirectorySeparator(Path.GetFullPath(AppContext.BaseDirectory));
        var root = Directory.GetParent(appDirectory);
        return root is not null && ReleaseUpdater.IsInstalledBuild(root.FullName)
            ? root.FullName
            : null;
    }

    public static string? FindRepositoryFixtureRoot()
    {
        var current = new DirectoryInfo(Path.GetFullPath(AppContext.BaseDirectory));
        while (current is not null)
        {
            var root = current.FullName;
            if (File.Exists(Path.Combine(root, "src", "Nativune", "Nativune.csproj"))
                && File.Exists(WebViewRuntimeManifestPath(root)))
                return root;
            current = current.Parent;
        }
        return null;
    }

    public static string WebViewRuntimeManifestPath(string root) => Path.Combine(root, ".tools", "webview2", "runtime-path.txt");
    public static string WebViewProfilePath(string root) => Path.Combine(root, "data", "webview2");

    public static void EnsureNoReparsePath(string root, string path)
    {
        var fullRoot = Path.GetFullPath(root).TrimEnd(Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar);
        var fullPath = Path.GetFullPath(path);
        var prefix = fullRoot + Path.DirectorySeparatorChar;
        if (!fullPath.Equals(fullRoot, StringComparison.OrdinalIgnoreCase) &&
            !fullPath.StartsWith(prefix, StringComparison.OrdinalIgnoreCase))
            throw new InvalidOperationException("A runtime path escaped the Nativune root.");

        var current = fullRoot;
        EnsureNotReparse(current);
        var relative = Path.GetRelativePath(fullRoot, fullPath);
        if (relative == ".") return;
        foreach (var component in relative.Split(
            new[] { Path.DirectorySeparatorChar, Path.AltDirectorySeparatorChar },
            StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, component);
            if (!Path.Exists(current)) break;
            EnsureNotReparse(current);
        }
    }

    public static void EnsureNoReparseTree(string root, string directory)
    {
        EnsureNoReparsePath(root, directory);
        if (!Directory.Exists(directory))
            throw new DirectoryNotFoundException($"Required directory is missing: {directory}");
        var pending = new Stack<string>();
        pending.Push(directory);
        while (pending.Count > 0)
        {
            var current = pending.Pop();
            foreach (var entry in Directory.EnumerateFileSystemEntries(current))
            {
                EnsureNotReparse(entry);
                if (Directory.Exists(entry)) pending.Push(entry);
            }
        }
    }

    public static void EnsureRegularFile(string root, string path)
    {
        EnsureNoReparsePath(root, path);
        if (!File.Exists(path) || Directory.Exists(path))
            throw new FileNotFoundException("A required Nativune file is missing.", path);
    }

    private static void EnsureNotReparse(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidOperationException($"Nativune refuses to use a reparse-point path: {path}");
    }
}

internal static class SelfCheck
{
    public static int Run(string root)
    {
        var directory = Path.Combine(root, "data", ".self-check-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        try
        {
            var isolatedRoot = Path.Combine(directory, "root");
            Directory.CreateDirectory(Path.Combine(isolatedRoot, "data"));
            ShellChecks.Run(isolatedRoot);

            if (!WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://music.youtube.com/"))
                || !WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://www.youtube.com/"))
                || !WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://accounts.google.com/"))
                || !WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://accounts.youtube.com/"))
                || !WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://accounts.google.com.my/"))
                || WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://accounts.google.com.my.evil.example/"))
                || WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://accounts.youtube.com.evil.example/"))
                || WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("http://music.youtube.com/"))
                || WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://music.youtube.com.evil.example/"))
                || WebHostPolicy.IsAllowedMainFrameNavigation(new Uri("https://music.youtube.com:444/")))
            {
                throw new SelfCheckException("Web navigation origin boundary failed.");
            }

            ReleaseUpdaterChecks.Run(root);
            Console.WriteLine("Self-check passed: shell settings, WebView navigation origin boundary, and release updater checks.");
            return 0;
        }
        finally
        {
            try
            {
                if (Directory.Exists(directory))
                    Directory.Delete(directory, recursive: true);
            }
            catch (Exception)
            {
                throw new SelfCheckException("Self-check temporary data could not be removed.");
            }
        }
    }
}

internal sealed class CancellationController : IDisposable
{
    private readonly CancellationTokenSource _source = new();
    private readonly ConsoleCancelEventHandler _handler;
    public CancellationToken Cancellation => _source.Token;

    public CancellationController()
    {
        _handler = (_, args) =>
        {
            args.Cancel = true;
            _source.Cancel();
        };
        Console.CancelKeyPress += _handler;
    }

    public void Dispose()
    {
        Console.CancelKeyPress -= _handler;
        _source.Dispose();
    }
}

internal class ProbeException : Exception
{
    public ProbeException(string message) : base(message) { }
}

internal sealed class UsageException : ProbeException
{
    public UsageException(string message) : base(message) { }
}

internal sealed class SelfCheckException : ProbeException
{
    public SelfCheckException(string message) : base(message) { }
}
