using System.Text;

namespace Nativune;

/// <summary>
/// Appends errors, WebView2 process failures and unhandled exceptions to data/nativune.log. Everything
/// already written to Console.Error is captured, so existing type-only diagnostics land here too.
/// Only error text is written: no page content, cookies, titles or URLs beyond what an error names.
/// </summary>
internal static class AppLog
{
    private const long MaxBytes = 1024 * 1024; // ponytail: one rotation (.old.log); add more if 2 MiB proves too little
    private static readonly object Gate = new();
    private static string? _path;

    internal static string? FilePath => _path;

    internal static void Start(string root)
    {
        try
        {
            var directory = Path.Combine(Path.GetFullPath(root), "data");
            Directory.CreateDirectory(directory);
            RootLocator.EnsureNoReparsePath(root, directory);
            _path = Path.Combine(directory, "nativune.log");
            Console.SetError(new ErrorWriter(Console.Error));
            AppDomain.CurrentDomain.UnhandledException += (_, e) =>
                Write("crash", e.ExceptionObject?.ToString() ?? "Unknown unhandled exception.");
            TaskScheduler.UnobservedTaskException += (_, e) => Write("unobserved-task", e.Exception.ToString());
            Write("start", $"Nativune {AppVersion.Number} on {Environment.OSVersion.VersionString}");
        }
        catch (Exception)
        {
            _path = null; // Logging must never stop the app.
        }
    }

    internal static void Write(string category, string message)
    {
        var path = _path;
        if (path is null) return;
        var line = $"{DateTimeOffset.Now:yyyy-MM-dd HH:mm:ss.fff zzz} [{category}] {message.ReplaceLineEndings(Environment.NewLine + "    ")}{Environment.NewLine}";
        lock (Gate)
        {
            try
            {
                var file = new FileInfo(path);
                if (file.Exists && file.Length > MaxBytes)
                    File.Move(path, Path.ChangeExtension(path, ".old.log"), overwrite: true);
                File.AppendAllText(path, line, new UTF8Encoding(false));
            }
            catch (Exception) { }
        }
    }

    private sealed class ErrorWriter(TextWriter inner) : TextWriter
    {
        public override Encoding Encoding => inner.Encoding;
        public override void Write(char value) => inner.Write(value);
        public override void WriteLine(string? value)
        {
            inner.WriteLine(value);
            AppLog.Write("error", value ?? "");
        }
    }
}
