#if NATIVUNE_DISCORD_TEST_HOOKS
using Microsoft.UI.Windowing;
using Microsoft.Web.WebView2.Core;
using System.Buffers.Binary;
using System.Diagnostics;
using System.IO.Compression;
using System.Text;
using System.Text.Json;
using Windows.Storage.Streams;

namespace Nativune;

// Discord presence E2E seam (contract: .cache/tmp/discord-rpc/contract.md), compiled only with
// -p:DiscordPresenceTestHooks=true. It serves the embedded synthetic Music page for
// scripts/discord-rpc-e2e.ps1 and blocks every other network request, so the fixture never reaches
// YouTube, Google or Discord. It does not change IsMusicUri, host objects or web messages.
public sealed partial class WebHostWindow
{
    private const string DiscordFixtureResourceName = "Nativune.DiscordFixturePage.html";
    private const string DiscordFixtureArtworkHost = "lh3.googleusercontent.com";
    private static byte[]? s_discordFixturePage;

    // The fixture plays unmuted silent PCM: Chromium pauses muted media while the page is hidden (tray),
    // which audible YouTube Music playback never hits. Unmuted autoplay needs this policy; fixture runs only.
    private static void DiscordFixtureBrowserArguments(ref string browserArguments)
    {
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_FIXTURE_PAGE") != "1") return;
        browserArguments = string.IsNullOrWhiteSpace(browserArguments)
            ? "--autoplay-policy=no-user-gesture-required"
            : browserArguments + " --autoplay-policy=no-user-gesture-required";
    }

    private void InstallDiscordFixturePage(CoreWebView2 core)
    {
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_FIXTURE_PAGE") != "1") return;
        using (var stream = typeof(WebHostWindow).Assembly.GetManifestResourceStream(DiscordFixtureResourceName)
            ?? throw new InvalidOperationException("The Discord fixture page resource is missing."))
        using (var buffer = new MemoryStream())
        {
            stream.CopyTo(buffer);
            s_discordFixturePage = buffer.ToArray();
        }
        StartDiscordBench();
        // Only http(s) is intercepted so chrome-extension:// (uBO Lite dashboard/resources) loads normally.
        core.AddWebResourceRequestedFilter("https://*", CoreWebView2WebResourceContext.All);
        core.AddWebResourceRequestedFilter("http://*", CoreWebView2WebResourceContext.All);
        core.WebResourceRequested += OnDiscordFixtureResourceRequested;
    }

    private static void OnDiscordFixtureResourceRequested(CoreWebView2 sender, CoreWebView2WebResourceRequestedEventArgs args)
    {
        Uri? uri = Uri.TryCreate(args.Request.Uri, UriKind.Absolute, out var parsed) ? parsed : null;
        if (uri is not null && uri.Scheme != Uri.UriSchemeHttps && uri.Scheme != Uri.UriSchemeHttp)
            return;
        var https = uri is not null && uri.Scheme == Uri.UriSchemeHttps && uri.IsDefaultPort && uri.UserInfo.Length == 0;
        if (https && uri!.Host.Equals("music.youtube.com", StringComparison.OrdinalIgnoreCase))
        {
            args.Response = args.ResourceContext == CoreWebView2WebResourceContext.Document
                ? DiscordFixtureResponse(sender, s_discordFixturePage!, 200, "OK", "text/html; charset=utf-8")
                : DiscordFixtureResponse(sender, null, 204, "No Content", null);
            return;
        }
        // The reader accepts only loaded artwork from allowed hosts, so the two fixture pictures are
        // generated locally under their allowed URLs; nothing is fetched from Google.
        if (https && uri!.Host.Equals(DiscordFixtureArtworkHost, StringComparison.OrdinalIgnoreCase)
            && args.ResourceContext == CoreWebView2WebResourceContext.Image
            && uri.AbsolutePath is "/fixture-a=w544-h544" or "/fixture-b=w544-h544")
        {
            var png = uri.AbsolutePath.StartsWith("/fixture-a", StringComparison.Ordinal)
                ? DiscordFixturePng(0xE0, 0x3E, 0x52)
                : DiscordFixturePng(0x2E, 0x7D, 0xD7);
            args.Response = DiscordFixtureResponse(sender, png, 200, "OK", "image/png");
            return;
        }
        args.Response = DiscordFixtureResponse(sender, null, 403, "Forbidden", null);
    }

    private static CoreWebView2WebResourceResponse DiscordFixtureResponse(CoreWebView2 core, byte[]? body,
        int status, string reason, string? contentType)
    {
        IRandomAccessStream? content = null;
        if (body is not null)
        {
            var stream = new InMemoryRandomAccessStream();
            using (var writer = new DataWriter(stream.GetOutputStreamAt(0)))
            {
                writer.WriteBytes(body);
                writer.StoreAsync().AsTask().GetAwaiter().GetResult();
                writer.FlushAsync().AsTask().GetAwaiter().GetResult();
                writer.DetachStream();
            }
            stream.Seek(0);
            content = stream;
        }
        var headers = "Cache-Control: no-store"
            + (contentType is null ? "" : "\r\nContent-Type: " + contentType);
        return core.Environment.CreateWebResourceResponse(content, status, reason, headers);
    }

    // Solid 64x64 RGB PNG; small enough for every reader size bound.
    private static byte[] DiscordFixturePng(byte red, byte green, byte blue)
    {
        const int size = 64;
        var raw = new byte[size * (1 + size * 3)];
        for (var y = 0; y < size; y++)
        {
            var row = y * (1 + size * 3);
            for (var x = 0; x < size; x++)
            {
                raw[row + 1 + x * 3] = red;
                raw[row + 2 + x * 3] = green;
                raw[row + 3 + x * 3] = blue;
            }
        }
        byte[] compressed;
        using (var buffer = new MemoryStream())
        {
            using (var zlib = new ZLibStream(buffer, CompressionLevel.Optimal, leaveOpen: true)) zlib.Write(raw);
            compressed = buffer.ToArray();
        }
        var header = new byte[13];
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(0), size);
        BinaryPrimitives.WriteInt32BigEndian(header.AsSpan(4), size);
        header[8] = 8; // bit depth
        header[9] = 2; // truecolour
        using var png = new MemoryStream();
        png.Write([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);
        WriteDiscordFixtureChunk(png, "IHDR", header);
        WriteDiscordFixtureChunk(png, "IDAT", compressed);
        WriteDiscordFixtureChunk(png, "IEND", []);
        return png.ToArray();
    }

    private static void WriteDiscordFixtureChunk(Stream output, string type, byte[] data)
    {
        Span<byte> number = stackalloc byte[4];
        BinaryPrimitives.WriteInt32BigEndian(number, data.Length);
        output.Write(number);
        var typeBytes = System.Text.Encoding.ASCII.GetBytes(type);
        output.Write(typeBytes);
        output.Write(data);
        var crc = 0xFFFFFFFFu;
        foreach (var b in typeBytes.Concat(data))
        {
            crc ^= b;
            for (var k = 0; k < 8; k++) crc = (crc & 1) != 0 ? 0xEDB88320u ^ (crc >> 1) : crc >> 1;
        }
        BinaryPrimitives.WriteUInt32BigEndian(number, crc ^ 0xFFFFFFFFu);
        output.Write(number);
    }

    // ---- Bench protocol v2 native setup (plan .cache/tmp/discord-rpc/opt-refactor-plan.md §1, §4 item 5). ----
    // Active only when NATIVUNE_TEST_DISCORD_BENCH_PROFILE and _STATE are both set to valid values, the fixture
    // page is enabled and the pipe prefix is a valid nativune-test prefix. All files live at fixed paths under
    // <root>/data/discord-bench; nothing is read from or written to an environment-controlled path. The page
    // profile is written into the served fixture document; the state uses the normal TryHideToTray/SetCompact
    // paths. Files:
    //   ready.json / failed.json        written once after native page + state confirmation (or failure)
    //   command-snapshot-<label>        harness request -> diagnostics-<label>.json + state-<label>.json
    //                                   (label: 1-32 of [a-z0-9-]; start/end/final plus scenario labels)
    //   command-quit                    harness request -> diagnostics-quit.json, then the normal Quit path
    //   command-resume                  run the page's own play control (media.play()) via ExecuteScriptAsync
    //   command-discord-off / -on       ApplyDiscordOptions with Enabled false/true (Settings Save path)
    //   command-power-suspend / -resume the WM_POWERBROADCAST suspend / resume-suspend handling (HandlePowerEvent)
    //   command-compact / command-full  SetCompact(true) + RequestActivation / SetCompact(false)
    // Commands are honoured in every fixture run with a valid test prefix, not only bench state runs.
    private const string DiscordBenchProfileMeta = "<meta name=\"nativune-discord-bench-profile\" content=\"\">";
    private static readonly TimeSpan DiscordBenchSetupTimeout = TimeSpan.FromSeconds(50);
    private const string DiscordBenchResumeScript =
        "(() => { const v = document.querySelector('video'); if (!v) return 'no-media';"
        + " if (v.paused) v.play().catch(() => {}); return 'ok'; })()";
    private const string DiscordBenchProbeScript =
        "(() => { const m = document.querySelector('meta[name=\"nativune-discord-bench-profile\"]');"
        + " const v = document.querySelector('video');"
        + " return JSON.stringify({ fixture: !!document.querySelector('meta[name=\"nativune-discord-fixture\"]'),"
        + " profile: m ? m.content : null, ready: document.readyState, paused: v ? v.paused : null }); })()";

    private Microsoft.UI.Dispatching.DispatcherQueueTimer? _discordBenchTimer;
    private string? _discordBenchProfile;
    private string? _discordBenchState;
    private string? _discordBenchDirectory;
    private long _discordBenchStartedAt;
    private int _discordBenchProbes;
    private bool _discordBenchBusy, _discordBenchPageReady, _discordBenchStateRequested, _discordBenchDone;

    private void StartDiscordBench()
    {
        var profile = Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_BENCH_PROFILE");
        var state = Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_BENCH_STATE");
        if (profile is null && state is null)
        {
            // Command-only mode: fixture page + valid prefix, no bench state setup.
            if (!IsDiscordBenchTestPrefix(Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_PIPE_PREFIX")))
                return;
            _discordBenchDirectory = Path.Combine(_root, "data", "discord-bench");
            _discordBenchDone = true;
            _discordBenchTimer = _dispatcherQueue.CreateTimer();
            _discordBenchTimer.Interval = TimeSpan.FromMilliseconds(250);
            _discordBenchTimer.IsRepeating = true;
            _discordBenchTimer.Tick += OnDiscordBenchTick;
            _discordBenchTimer.Start();
            return;
        }
        _discordBenchDirectory = Path.Combine(_root, "data", "discord-bench");
        _discordBenchStartedAt = Stopwatch.GetTimestamp();
        try
        {
            DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(_discordBenchDirectory, "started.json"),
                DiscordBenchJson(("schema", 2), ("processId", Environment.ProcessId), ("qpc", _discordBenchStartedAt),
                    ("qpcFrequency", Stopwatch.Frequency), ("utc", DateTime.UtcNow.ToString("o"))));
        }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
        {
        }
        string? error = null;
        if (profile is not ("Playing" or "Paused" or "Empty" or "ArtGap")) error = "invalid-profile";
        else if (state is not ("Full" or "Hidden" or "Compact")) error = "invalid-state";
        else if (!IsDiscordBenchTestPrefix(Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_PIPE_PREFIX")))
            error = "invalid-prefix";
        else
        {
            var page = Encoding.UTF8.GetString(s_discordFixturePage!);
            if (!page.Contains(DiscordBenchProfileMeta, StringComparison.Ordinal)) error = "profile-slot-missing";
            else s_discordFixturePage = Encoding.UTF8.GetBytes(page.Replace(DiscordBenchProfileMeta,
                "<meta name=\"nativune-discord-bench-profile\" content=\"" + profile + "\">", StringComparison.Ordinal));
        }
        if (error is not null)
        {
            FailDiscordBench(error);
            return;
        }
        _discordBenchProfile = profile;
        _discordBenchState = state;
        _discordBenchTimer = _dispatcherQueue.CreateTimer();
        _discordBenchTimer.Interval = TimeSpan.FromMilliseconds(250);
        _discordBenchTimer.IsRepeating = true;
        _discordBenchTimer.Tick += OnDiscordBenchTick;
        _discordBenchTimer.Start();
    }

    // Same shape as DiscordPresenceEnvironment's test-prefix check: ^nativune-test-[0-9a-f]{32}-discord-ipc-$
    private static bool IsDiscordBenchTestPrefix(string? value)
    {
        const string head = "nativune-test-", tail = "-discord-ipc-";
        if (value is null || value.Length != head.Length + 32 + tail.Length
            || !value.StartsWith(head, StringComparison.Ordinal) || !value.EndsWith(tail, StringComparison.Ordinal))
            return false;
        foreach (var c in value.AsSpan(head.Length, 32))
            if (c is not ((>= '0' and <= '9') or (>= 'a' and <= 'f'))) return false;
        return true;
    }

    private async void OnDiscordBenchTick(object? sender, object args)
    {
        if (_discordBenchBusy || _closing || _disposed) return;
        _discordBenchBusy = true;
        try
        {
            if (!_discordBenchDone) await AdvanceDiscordBenchSetupAsync();
            await ProcessDiscordBenchCommandsAsync();
        }
        catch (Exception ex)
        {
            if (!_discordBenchDone) FailDiscordBench("exception-" + ex.GetType().Name);
        }
        finally
        {
            _discordBenchBusy = false;
        }
    }

    private async Task AdvanceDiscordBenchSetupAsync()
    {
        if (Stopwatch.GetElapsedTime(_discordBenchStartedAt) > DiscordBenchSetupTimeout)
        {
            FailDiscordBench(_discordBenchPageReady ? "state-timeout" : "page-timeout");
            return;
        }
        if (!_discordBenchPageReady)
        {
            if (_awaitingFirstPage || _browserHost is not { } host) return;
            if (!Uri.TryCreate(host.Core.Source, UriKind.Absolute, out var source)
                || !source.Host.Equals("music.youtube.com", StringComparison.OrdinalIgnoreCase))
                return;
            _discordBenchProbes++;
            var raw = await host.Core.ExecuteScriptAsync(DiscordBenchProbeScript);
            if (_closing || _disposed) return;
            using var outer = JsonDocument.Parse(raw);
            if (outer.RootElement.ValueKind != JsonValueKind.String) return;
            using var probe = JsonDocument.Parse(outer.RootElement.GetString()!);
            var root = probe.RootElement;
            var paused = root.TryGetProperty("paused", out var p) && p.ValueKind is JsonValueKind.True or JsonValueKind.False
                ? p.GetBoolean() : (bool?)null;
            if (!root.TryGetProperty("fixture", out var f) || f.ValueKind != JsonValueKind.True) return;
            if (!root.TryGetProperty("profile", out var pr) || pr.ValueKind != JsonValueKind.String
                || pr.GetString() != _discordBenchProfile) return;
            if (!root.TryGetProperty("ready", out var r) || r.GetString() != "complete") return;
            if (_discordBenchProfile is "Playing" or "ArtGap" && paused != false) return;
            if (_discordBenchProfile == "Paused" && paused != true) return;
            _discordBenchPageReady = true;
        }

        var fullVisible = WindowIsVisible && !_compact;
        switch (_discordBenchState)
        {
            case "Full":
                if (!fullVisible) return;
                break;
            case "Compact":
                if (!_discordBenchStateRequested)
                {
                    _discordBenchStateRequested = true;
                    SetCompact(true);
                }
                if (!(_compact && WindowIsVisible)) return;
                break;
            case "Hidden":
                if (!_discordBenchStateRequested)
                {
                    // Start Full, wait for the tray, then one normal tray hide; false fails the run.
                    if (!fullVisible || _tray is not { IsVisible: true }) return;
                    _discordBenchStateRequested = true;
                    if (!TryHideToTray())
                    {
                        FailDiscordBench("try-hide-to-tray-false");
                        return;
                    }
                }
                if (_appWindow is not { IsVisible: false } || _tray is not { IsVisible: true } || _compact) return;
                break;
            default:
                return;
        }
        _discordBenchDone = true;
        _discordBenchTimer!.Interval = TimeSpan.FromMilliseconds(500);
        DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(_discordBenchDirectory!, "ready.json"),
            DiscordBenchStateJson("ready"));
    }

    private void FailDiscordBench(string reason)
    {
        _discordBenchDone = true;
        if (_discordBenchDirectory is null) return;
        try
        {
            DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(_discordBenchDirectory, "failed.json"),
                DiscordBenchJson(("schema", 2), ("reason", reason), ("qpc", Stopwatch.GetTimestamp()),
                    ("utc", DateTime.UtcNow.ToString("o")), ("processId", Environment.ProcessId)));
        }
        catch (Exception)
        {
        }
        // Commands (snapshot/quit) stay available after a failure for cancellation-safe collection.
        if (_discordBenchTimer is null && _discordBenchProfile is null)
        {
            _discordBenchTimer = _dispatcherQueue.CreateTimer();
            _discordBenchTimer.Interval = TimeSpan.FromMilliseconds(500);
            _discordBenchTimer.IsRepeating = true;
            _discordBenchTimer.Tick += OnDiscordBenchTick;
            _discordBenchTimer.Start();
        }
    }

    private static bool IsDiscordBenchLabel(string label)
    {
        if (label.Length is < 1 or > 32) return false;
        foreach (var c in label)
            if (c is not ((>= 'a' and <= 'z') or (>= '0' and <= '9') or '-')) return false;
        return true;
    }

    private bool TakeDiscordBenchCommand(string name)
    {
        var path = Path.Combine(_discordBenchDirectory!, name);
        if (!File.Exists(path)) return false;
        File.Delete(path);
        return true;
    }

    private async Task ProcessDiscordBenchCommandsAsync()
    {
        var directory = _discordBenchDirectory!;
        if (!Directory.Exists(directory)) return;
        foreach (var command in Directory.GetFiles(directory, "command-snapshot-*"))
        {
            var label = Path.GetFileName(command)["command-snapshot-".Length..];
            File.Delete(command);
            if (!IsDiscordBenchLabel(label)) continue;
            DiscordPresenceDiagnostics.WriteSnapshot(Path.Combine(directory, "diagnostics-" + label + ".json"), label);
            DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(directory, "state-" + label + ".json"),
                DiscordBenchStateJson(label));
        }
        if (TakeDiscordBenchCommand("command-discord-off"))
        {
            _settings = _settings with { Discord = _settings.Discord with { Enabled = false } };
            ApplyDiscordOptions(_settings.Discord);
        }
        if (TakeDiscordBenchCommand("command-discord-on"))
        {
            _settings = _settings with { Discord = _settings.Discord with { Enabled = true } };
            ApplyDiscordOptions(_settings.Discord);
        }
        if (TakeDiscordBenchCommand("command-compact"))
        {
            SetCompact(true);
            RequestActivation();
        }
        if (TakeDiscordBenchCommand("command-full")) SetCompact(false);
        if (TakeDiscordBenchCommand("command-power-suspend")) HandlePowerEvent(PbtApmsuspend);
        if (TakeDiscordBenchCommand("command-power-resume")) HandlePowerEvent(PbtApmresumesuspend);
        if (TakeDiscordBenchCommand("command-resume") && _browserHost is { } host)
            await host.Core.ExecuteScriptAsync(DiscordBenchResumeScript);
        if (_closing || _disposed) return;
        if (!TakeDiscordBenchCommand("command-quit")) return;
        DiscordPresenceDiagnostics.WriteSnapshot(Path.Combine(directory, "diagnostics-quit.json"), "quit");
        _discordBenchTimer?.Stop();
        _ = ShutdownAsync();
    }

    private string DiscordBenchStateJson(string label)
    {
        var size = _appWindow?.Size;
        var client = GetClientSize();
        return DiscordBenchJson(("schema", 2), ("label", label), ("profile", _discordBenchProfile),
            ("state", _discordBenchState), ("compact", _compact), ("windowVisible", WindowIsVisible),
            ("appWindowVisible", _appWindow?.IsVisible), ("minimized", _presenter?.State == OverlappedPresenterState.Minimized),
            ("trayVisible", _tray?.IsVisible), ("width", size?.Width), ("height", size?.Height),
            ("clientWidth", client.Width), ("clientHeight", client.Height), ("probes", _discordBenchProbes),
            ("qpc", Stopwatch.GetTimestamp()), ("qpcFrequency", Stopwatch.Frequency),
            ("utc", DateTime.UtcNow.ToString("o")), ("processId", Environment.ProcessId));
    }

    private static string DiscordBenchJson(params (string Name, object? Value)[] fields)
    {
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer))
        {
            json.WriteStartObject();
            foreach (var (name, value) in fields)
            {
                switch (value)
                {
                    case null: json.WriteNull(name); break;
                    case bool b: json.WriteBoolean(name, b); break;
                    case int i: json.WriteNumber(name, i); break;
                    case long l: json.WriteNumber(name, l); break;
                    default: json.WriteString(name, value.ToString()); break;
                }
            }
            json.WriteEndObject();
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }
}
#endif
