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
    // ArtGap profile: a loadable artwork URL whose total length exceeds Discord's large_image limit.
    private static readonly string DiscordFixtureLongArtworkPath = "/fixture-a" + new string('x', 300) + "=w544-h544";
    private static byte[]? s_discordFixturePage;

    // The fixture plays unmuted silent PCM: Chromium pauses muted media while the page is hidden (tray),
    // which audible YouTube Music playback never hits. Unmuted autoplay needs this policy; fixture runs only.
    private static void DiscordFixtureBrowserArguments(ref string browserArguments)
    {
        // Resume probe (hook builds only): run the real site under an explicit Chromium autoplay policy.
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_AUTOPLAY_POLICY") is { } policy
            && policy is "document-user-activation-required" or "no-user-gesture-required" or "user-gesture-required")
            browserArguments = (browserArguments + " --autoplay-policy=" + policy).Trim();
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_FIXTURE_PAGE") != "1") return;
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_EQ_FIXTURE") != "1")
            browserArguments = string.IsNullOrWhiteSpace(browserArguments)
                ? "--autoplay-policy=no-user-gesture-required"
                : browserArguments + " --autoplay-policy=no-user-gesture-required";
        // Bench-only startup stabilisation, not a product CPU fix: run Chromium's DX12 info collection at startup
        // instead of 120 s later, so its short-lived GPU process cannot exit inside a Designer bench window.
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_OVERLAY_EAGER_GPU_INFO") == "1")
        {
            browserArguments += " --no-delay-for-dx12-vulkan-info-collection";
            AppLog.Write("designer-bench-browser-args", browserArguments);
        }
    }

    private void InstallDiscordFixturePage(CoreWebView2 core)
    {
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_EQ_REAL_MUSIC") == "1")
        {
            if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_EQ_FIXTURE") == "1" &&
                IsDiscordBenchTestPrefix(Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_PIPE_PREFIX")))
                StartDiscordBench(commandOnly: true);
            return; // Command-only: no synthetic page or request interception.
        }
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_FIXTURE_PAGE") != "1") return;
        using (var stream = typeof(WebHostWindow).Assembly.GetManifestResourceStream(DiscordFixtureResourceName)
            ?? throw new InvalidOperationException("The Discord fixture page resource is missing."))
        using (var buffer = new MemoryStream())
        {
            stream.CopyTo(buffer);
            s_discordFixturePage = buffer.ToArray();
        }
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_EQ_FIXTURE") == "1")
            s_discordFixturePage = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(s_discordFixturePage)
                .Replace("<meta name=\"nativune-eq-fixture\" content=\"\">",
                    "<meta name=\"nativune-eq-fixture\" content=\"1\">", StringComparison.Ordinal));
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_RESUME_FIXTURE") == "1")
        {
            var resumeFixture = JsonSerializer.Serialize(new {
                ad = Environment.GetEnvironmentVariable("NATIVUNE_TEST_RESUME_AD") == "1",
                badLink = Environment.GetEnvironmentVariable("NATIVUNE_TEST_RESUME_BAD_LINK") == "1",
                stall = Environment.GetEnvironmentVariable("NATIVUNE_TEST_RESUME_STALL") == "1",
                homeMedia = Environment.GetEnvironmentVariable("NATIVUNE_TEST_RESUME_HOME_MEDIA") == "1",
                delay = int.TryParse(Environment.GetEnvironmentVariable("NATIVUNE_TEST_RESUME_DELAY"), out var delay)
                    ? Math.Clamp(delay, 0, 16000) : 0
            });
            s_discordFixturePage = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(s_discordFixturePage)
                .Replace("<meta name=\"nativune-resume-fixture\" content=\"\">",
                    "<meta name=\"nativune-resume-fixture\" content='" + resumeFixture + "'>", StringComparison.Ordinal));
        }
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_EQ_FIXTURE") == "1" &&
            Environment.GetEnvironmentVariable("NATIVUNE_TEST_EQ_DEFER_MEDIA") == "1")
            s_discordFixturePage = Encoding.UTF8.GetBytes(Encoding.UTF8.GetString(s_discordFixturePage)
                .Replace("profile('tones-48000');", "// Media is loaded by the Settings-open attachment row.", StringComparison.Ordinal));
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
        if (https && Environment.GetEnvironmentVariable("NATIVUNE_TEST_RESUME_REDIRECT") == "1"
            && args.ResourceContext == CoreWebView2WebResourceContext.Document)
        {
            if (uri!.Host == "accounts.google.com")
            {
                args.Response = DiscordFixtureResponse(sender, Encoding.UTF8.GetBytes("<html lang='en'><body>Fixture account document</body></html>"),
                    200, "OK", "text/html; charset=utf-8");
                return;
            }
            if (uri!.Host == "music.youtube.com" && uri.Query.Contains("fixtureSngB", StringComparison.Ordinal))
            {
                args.Response = sender.Environment.CreateWebResourceResponse(null, 302, "Found",
                    "Cache-Control: no-store\r\nLocation: https://accounts.google.com/ServiceLogin");
                return;
            }
        }
        if (https && uri!.Host == "eq-fixture.invalid" && uri.AbsolutePath == "/tone.wav" &&
            Environment.GetEnvironmentVariable("NATIVUNE_TEST_EQ_FIXTURE") == "1")
        {
            // Same-origin restrictions are deliberately NOT relaxed: the original element can play
            // this cross-origin WAV, but the production source guard must reject it before attachment.
            args.Response = DiscordFixtureResponse(sender, EqualizerForeignWav(), 200, "OK", "audio/wav");
            return;
        }
        if (https && uri!.Host.Equals("music.youtube.com", StringComparison.OrdinalIgnoreCase))
        {
            if (args.ResourceContext == CoreWebView2WebResourceContext.Document &&
                uri.AbsolutePath == "/__nativune_eq_redirect" &&
                Environment.GetEnvironmentVariable("NATIVUNE_TEST_EQ_FIXTURE") == "1")
            {
                args.Response = sender.Environment.CreateWebResourceResponse(null, 302, "Found",
                    "Cache-Control: no-store\r\nLocation: https://example.com/");
                return;
            }
            args.Response = args.ResourceContext == CoreWebView2WebResourceContext.Document
                ? DiscordFixtureResponse(sender, s_discordFixturePage!, 200, "OK", "text/html; charset=utf-8")
                : DiscordFixtureResponse(sender, null, 204, "No Content", null);
            return;
        }
        // The reader accepts only loaded artwork from allowed hosts, so the two fixture pictures are
        // generated locally under their allowed URLs; nothing is fetched from Google.
        if (https && uri!.Host.Equals(DiscordFixtureArtworkHost, StringComparison.OrdinalIgnoreCase)
            && args.ResourceContext == CoreWebView2WebResourceContext.Image
            && (System.Text.RegularExpressions.Regex.Match(uri.AbsolutePath,
                    "^/fixture-([abc])=w544-h544(?:-d[0-9]{1,4})?$") is { Success: true }
                || uri.AbsolutePath == DiscordFixtureLongArtworkPath))
        {
            // fixture-c and the -d<ms> delay suffix serve the OBS overlay fixture; the delay applies only on
            // the overlay server (ObsOverlay.Hooks.cs), never here.
            var png = uri.AbsolutePath.StartsWith("/fixture-a", StringComparison.Ordinal)
                ? DiscordFixturePng(0xE0, 0x3E, 0x52)
                : uri.AbsolutePath.StartsWith("/fixture-c", StringComparison.Ordinal)
                    ? DiscordFixturePng(0x3A, 0xB0, 0x5E)
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

    internal static void WriteDiscordFixtureChunk(Stream output, string type, byte[] data)
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
    //   command-locale-fr / -en         set the fixture page's <html lang> (the page reader accepts only English)
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

    private void StartDiscordBench(bool commandOnly = false)
    {
        var profile = commandOnly ? null : Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_BENCH_PROFILE");
        var state = commandOnly ? null : Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_BENCH_STATE");
        if (profile is null && state is null)
        {
            // Command-only mode: validated hook launch, no fixture profile or bench state setup.
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
        if (profile is not ("Playing" or "PlayingLong" or "Paused" or "Empty" or "ArtGap" or "SameTitle" or "ReaderGap"
            or "ShortGap" or "IdOnly" or "Text" or "ArtSwap" or "DomGap" or "PausedSeek" or "AdFallback" or "TimelineCompact"))
            error = "invalid-profile";
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
            if (_discordBenchProfile is "Playing" or "PlayingLong" or "ArtGap" && paused != false) return;
            if (_discordBenchProfile is "Paused" or "SameTitle" or "ReaderGap" && paused != true) return;
            if (_discordBenchProfile is "ShortGap" or "IdOnly" or "Text" or "ArtSwap" or "DomGap" or "AdFallback" or "TimelineCompact"
                && paused != false) return;
            if (_discordBenchProfile is "PausedSeek" && paused != true) return;
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
        if (TakeDiscordBenchCommand("command-locale-fr") && _browserHost is { } frHost)
            await frHost.Core.ExecuteScriptAsync("document.documentElement.lang = 'fr'");
        if (TakeDiscordBenchCommand("command-locale-en") && _browserHost is { } enHost)
            await enHost.Core.ExecuteScriptAsync("document.documentElement.lang = 'en'");
        await ProcessObsBenchCommandsAsync();
        await ProcessEqualizerBenchCommandsAsync();
        if (_closing || _disposed) return;
        if (!TakeDiscordBenchCommand("command-quit")) return;
        DiscordPresenceDiagnostics.WriteSnapshot(Path.Combine(directory, "diagnostics-quit.json"), "quit");
        _discordBenchTimer?.Stop();
        _ = ShutdownAsync();
    }

    private static byte[] EqualizerForeignWav()
    {
        const int rate = 48000, frames = rate * 4;
        var bytes = new byte[44 + frames * 4];
        using var writer = new BinaryWriter(new MemoryStream(bytes));
        writer.Write(Encoding.ASCII.GetBytes("RIFF")); writer.Write(bytes.Length - 8);
        writer.Write(Encoding.ASCII.GetBytes("WAVEfmt ")); writer.Write(16);
        writer.Write((short)1); writer.Write((short)2); writer.Write(rate); writer.Write(rate * 4);
        writer.Write((short)4); writer.Write((short)16);
        writer.Write(Encoding.ASCII.GetBytes("data")); writer.Write(frames * 4);
        for (var i = 0; i < frames; i++)
        {
            writer.Write((short)(2000 * Math.Sin(2 * Math.PI * 250 * i / rate)));
            writer.Write((short)(1500 * Math.Sin(2 * Math.PI * 500 * i / rate)));
        }
        return bytes;
    }

    // A labelled, bounded request is consumed once; results always land under the disposable root.
    // Only EQ fixture mode + the existing validated test prefix can reach this command surface.
    private async Task ProcessEqualizerBenchCommandsAsync()
    {
        if (Environment.GetEnvironmentVariable("NATIVUNE_TEST_EQ_FIXTURE") != "1" ||
            !IsDiscordBenchTestPrefix(Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_PIPE_PREFIX")) ||
            _discordBenchDirectory is null || _browserHost is not { } host) return;
        foreach (var path in Directory.GetFiles(_discordBenchDirectory, "command-eq-*.json"))
        {
            var label = Path.GetFileName(path)["command-eq-".Length..^5];
            if (!IsDiscordBenchLabel(label)) { File.Delete(path); continue; }
            object result;
            try
            {
                if (new FileInfo(path).Length > 8192) throw new InvalidDataException("request-size");
                string text;
                // A just-renamed request can be briefly locked (e.g. by a scanner). Reading is idempotent, so leave it
                // for the next tick on a sharing/lock violation; the harness's own deadline bounds the wait.
                try { text = File.ReadAllText(path); }
                catch (IOException ex) when ((ex.HResult & 0xffff) is 32 or 33) { continue; }
                File.Delete(path);
                using var request = JsonDocument.Parse(text);
                var root = request.RootElement;
                var command = root.GetProperty("command").GetString();
                var value = root.TryGetProperty("value", out var v) ? v : default;
                switch (command)
                {
                    case "resume-state":
                        var resumeRaw = await host.Core.ExecuteScriptAsync("(()=>{const v=document.querySelector('video,audio'),q=new URL(location.href).searchParams;return {" +
                            "isB:q.get('v')==='fixtureSngB',isC:q.get('v')==='fixtureSngC',home:location.pathname==='/'," +
                            "paused:v?.paused??true,position:v?.currentTime??0,duration:Number.isFinite(v?.duration)?v.duration:0," +
                            "timeParameter:/^[0-9]+$/.test(q.get('t')||'')?Number(q.get('t')):null,mediaNetworkFailed:v?.error?.code===2," +
                            "readyState:v?.readyState??0,...globalThis.__nativuneFixture?.resumeState?.()}})()");
                        using (var resumeJson = JsonDocument.Parse(resumeRaw))
                            result = new { ready = _playerControls?.IsAvailable == true, restoreState = _resumeState, diag = _resumeDiag,
                                status = _statusDetailsText, networkFailed = _navigationFailed || resumeJson.RootElement.GetProperty("mediaNetworkFailed").GetBoolean(),
                                otherDocument = !IsEqualizerMusicOrigin(host.Core.Source), compact = _compact,
                                visible = _appWindow?.IsVisible == true, tray = _tray?.IsVisible == true,
                                destination = (int)_settings.StartupDestination, launch = (int)_settings.ResumeLaunch,
                                safetyMuted = _resumeSafetyMuted, coreMuted = host.Core.IsMuted,
                                checkpointExists = File.Exists(Path.Combine(_root, "data", "resume.dat")),
                                isB = resumeJson.RootElement.GetProperty("isB").GetBoolean(),
                                isC = resumeJson.RootElement.GetProperty("isC").GetBoolean(),
                                home = resumeJson.RootElement.GetProperty("home").GetBoolean(),
                                paused = resumeJson.RootElement.GetProperty("paused").GetBoolean(),
                                position = resumeJson.RootElement.GetProperty("position").GetDouble(),
                                duration = resumeJson.RootElement.GetProperty("duration").GetDouble(),
                                timeParameter = resumeJson.RootElement.GetProperty("timeParameter").Clone(),
                                stallApplied = resumeJson.RootElement.TryGetProperty("stallApplied", out var stall) && stall.GetBoolean(),
                                isAd = resumeJson.RootElement.TryGetProperty("isAd", out var ad) && ad.GetBoolean(),
                                seekCount = resumeJson.RootElement.TryGetProperty("seekCount", out var seeks) ? seeks.GetInt32() : 0,
                                firstPlayingPosition = resumeJson.RootElement.TryGetProperty("firstPlayingPosition", out var first)
                                    ? (object)first.Clone() : _resumeInitialPosition };
                        break;
                    case "resume-visit":
                        await NavigateAfterResumeAsync(() => host.Core.Navigate("https://music.youtube.com/watch?v=fixtureSngC"));
                        result = new { requested = true };
                        break;
                    case "resume-settings":
                        ShowSettings();
                        var destination = value.ValueKind == JsonValueKind.Object ? value.GetProperty("destination").GetInt32() : (int?)null;
                        var launch = value.ValueKind == JsonValueKind.Object ? value.GetProperty("launch").GetInt32() : (int?)null;
                        if (destination is < 0 or > 2 || launch is < 0 or > 1) throw new InvalidDataException("resume-setting");
                        result = _settingsDialog?.ResumeHookSnapshot(destination, launch)
                            ?? throw new InvalidOperationException("settings-not-open");
                        if (destination is not null)
                            for (var attempt = 0; attempt < 100 && _settingsDialogOpen; attempt++) await Task.Delay(25);
                        break;
                    case "resume-fixture":
                        if (value.ValueKind != JsonValueKind.Object) throw new InvalidDataException("resume-value");
                        result = await host.Core.ExecuteScriptAsync($"globalThis.__nativuneFixture.resumeSet({value.GetRawText()})");
                        break;
                    case "resume-compact":
                        SetCompact(true);
                        for (var attempt = 0; attempt < 30 && !CompactActive; attempt++) await Task.Delay(50);
                        _lastCompactReadAt = 0;
                        await ReadPlaybackStateAsync();
                        var resumeCommand = value.GetProperty("command").GetString();
                        if (resumeCommand is not ("toggle" or "next" or "previous" or "seek"))
                            throw new InvalidDataException("resume-command");
                        await ExecuteCompactCommandAsync(resumeCommand,
                            value.TryGetProperty("value", out var resumeValue) ? resumeValue.GetDouble() : null);
                        result = new { dispatched = true };
                        break;
                    case "resume-show":
                        OnTrayCommand("show"); // The tray icon's Show path.
                        result = new { dispatched = true };
                        break;
                    case "resume-page-play":
                        // key=true sends a trusted CDP key press first, then plays as the site's shortcut handler would;
                        // false is a late site autoplay with no input.
                        var key = value.ValueKind == JsonValueKind.Object && value.TryGetProperty("key", out var k) && k.GetBoolean();
                        if (key)
                            foreach (var type in new[] { "keyDown", "keyUp" })
                                await host.Core.CallDevToolsProtocolMethodAsync("Input.dispatchKeyEvent", JsonSerializer.Serialize(new {
                                    type, key = "k", code = "KeyK", windowsVirtualKeyCode = 75, nativeVirtualKeyCode = 75 }));
                        await host.Core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new {
                            expression = "document.querySelector('audio,video')?.play().catch(()=>{}); true" }));
                        result = new { dispatched = true, key };
                        break;
                    case "resume-audio":
                        var resumeProcesses = CaptureOutputAudioProcesses();
                        var resumeExecutable = _outputAudioExecutablePath;
                        if (!_outputAudioPathVerified || resumeExecutable is null)
                            throw new InvalidOperationException("session-path-unverified");
                        result = await Task.Run(() => {
                            using var reader = new WebViewAudioVolume(resumeExecutable);
                            return reader.ReadEqualizerHookSessions(resumeProcesses, measurePeak: true);
                        });
                        break;
                    case "eq-block-activation":
                        if (_equalizerContext is null)
                        {
                            _equalizerInstall ??= InstallEqualizerAsync(host.Core, _equalizerGeneration);
                            await _equalizerInstall.WaitAsync(EqualizerDeadline, _lifetime.Token);
                        }
                        // Await the REAL suspend before the production synchronous constructor path
                        // can inspect state; its next new AudioContext receives this prepared instance.
                        result = await EqualizerHookEvaluateAsync("(async()=>{if(__nativuneEq.__graph().ctx||globalThis.__nativuneEqPreparedContext)throw new Error('already created');" +
                            "__nativuneEqActivation.blocked=true;const c=new AudioContext({latencyHint:'playback'});" +
                            "await c.__eqSuspended;globalThis.__nativuneEqPreparedContext=c;return {blocked:true,contextState:c.state}})()");
                        break;
                    case "eq-synthetic-event":
                        result = await host.Core.ExecuteScriptAsync("(()=>{document.dispatchEvent(new PointerEvent('pointerdown',{bubbles:true}));return {dispatched:true,trusted:false}})()");
                        break;
                    case "eq-ui-curve":
                        result = _settingsDialog?.EqualizerCurveHookSnapshot()
                            ?? throw new InvalidOperationException("settings-not-open");
                        break;
                    case "eq-open-settings":
                        var settingsPage = value.GetString();
                        if (settingsPage is not ("General" or "Discord" or "OBS" or "Equalizer"))
                            throw new InvalidDataException("settings-page");
                        ShowSettings(discordPage: settingsPage == "Discord", obsPage: settingsPage == "OBS");
                        if (settingsPage == "Equalizer") _settingsDialog?.SelectEqualizerPage();
                        result = new { open = _settingsDialogOpen, page = settingsPage };
                        break;
                    case "eq-settings-open":
                        result = new { open = _settingsDialogOpen };
                        break;
                    case "eq-settings-file":
                        using (var persisted = JsonDocument.Parse(File.ReadAllText(Path.Combine(_root, "data", "settings.json"))))
                        {
                            result = new { version = persisted.RootElement.GetProperty("Version").GetInt32(),
                                equalizer = persisted.RootElement.TryGetProperty("Equalizer", out var eqFile)
                                    ? eqFile.Clone() : EqualizerSharing.WriteSettings(EqualizerSettings.Default) };
                        }
                        break;
                    case "eq-math":
                        var mathGains = value.GetProperty("gains").EnumerateArray().Select(x => x.GetDouble()).ToArray();
                        if (mathGains.Length != EqualizerBands.Count ||
                            mathGains.Any(x => !double.IsFinite(x) || x < -12 || x > 12))
                            throw new InvalidDataException("math-gains");
                        var mathSettings = EqualizerSettings.Default with { GainsDb = mathGains,
                            ManualPreampDb = value.TryGetProperty("preampDb", out var mathPreamp) ? mathPreamp.GetDouble() : 0,
                            AutoHeadroom = !value.TryGetProperty("autoHeadroom", out var mathAuto) || mathAuto.GetBoolean() };
                        if (!double.IsFinite(mathSettings.ManualPreampDb) || mathSettings.ManualPreampDb is < -24 or > 6)
                            throw new InvalidDataException("math-preamp");
                        result = new { effectivePreampDb = EqualizerMath.EffectivePreampDb(mathSettings,
                                value.TryGetProperty("sampleRate", out var mathRate) ? mathRate.GetDouble() : 48000),
                            mayClip = EqualizerMath.MayClip(mathSettings) };
                        break;
                    case "eq-session":
                        var sessionProcesses = CaptureOutputAudioProcesses();
                        var sessionExecutable = _outputAudioExecutablePath;
                        if (!_outputAudioPathVerified || sessionExecutable is null)
                            throw new InvalidOperationException("session-path-unverified");
                        result = await Task.Run(() =>
                        {
                            using var reader = new WebViewAudioVolume(sessionExecutable);
                            return reader.ReadEqualizerHookSessions(sessionProcesses);
                        });
                        break;
                    case "eq-set-volume":
                        var outputVolume = value.GetDouble();
                        if (!double.IsFinite(outputVolume) || outputVolume is < 0 or > 1)
                            throw new InvalidDataException("output-volume");
                        SetOutputVolume(outputVolume);
                        result = new { requested = outputVolume };
                        break;
                    case "eq-set-mute":
                        var outputMute = value.GetBoolean();
                        var currentOutputMute = _outputAudioState.Available && DateTime.UtcNow >= _pendingOutputMuteDisplayUntil
                            ? _outputAudioState.Muted : _desiredOutputMute ?? false;
                        if (currentOutputMute != outputMute) ToggleOutputMute();
                        result = new { requested = outputMute };
                        break;
                    case "eq-playback":
                        await host.Core.ExecuteScriptAsync(
                            "globalThis.__nativuneEqPlaybackResult=null;(async()=>{try{const v=document.querySelector('video');" +
                            (value.GetBoolean() ? "await v.play();" : "v.pause();") +
                            "globalThis.__nativuneEqPlaybackResult={paused:v.paused,currentTime:v.currentTime,readyState:v.readyState," +
                            "fixture:!!globalThis.__nativuneFixture?.eqProfile,loop:v.loop};" +
                            "}catch{globalThis.__nativuneEqPlaybackResult={error:'playback-rejected'}}})()");
                        var playbackRaw = "null";
                        for (var attempt = 0; attempt < 100 && playbackRaw == "null"; attempt++)
                        {
                            playbackRaw = await host.Core.ExecuteScriptAsync("globalThis.__nativuneEqPlaybackResult");
                            if (playbackRaw == "null") await Task.Delay(50, _lifetime.Token);
                        }
                        using (var playbackJson = JsonDocument.Parse(playbackRaw))
                        {
                            if (playbackJson.RootElement.ValueKind != JsonValueKind.Object ||
                                playbackJson.RootElement.TryGetProperty("error", out _))
                                throw new InvalidOperationException("playback-rejected");
                            result = playbackJson.RootElement.Clone();
                        }
                        break;
                    case "eq-hang-next-apply":
                        result = await EqualizerHookEvaluateAsync("(()=>{const eq=__nativuneEq,apply=eq.apply;" +
                            "eq.apply=(value)=>{eq.apply=apply;apply(value);return new Promise(()=>{})};return {armed:true}})()");
                        break;
                    case "eq-overlap-apply":
                        if (_equalizerDesired is not { } overlapApply || EqualizerStatus.State != EqualizerState.Active)
                            throw new InvalidOperationException("overlap-not-active");
                        await EqualizerHookEvaluateAsync("(()=>{const eq=__nativuneEq,apply=eq.apply;" +
                            "globalThis.__nativuneEqOverlapEntered=false;" +
                            "eq.apply=(value)=>{eq.apply=apply;globalThis.__nativuneEqOverlapEntered=true;" +
                            "apply(value);return new Promise(()=>{})};return {armed:true}})()");
                        var olderApply = ApplyEqualizerAsync(overlapApply with { PreampDb = -6 }, _lifetime.Token);
                        // A must enter Runtime.evaluate before B supersedes it; do not rely on a scheduling delay.
                        var overlapEntered = false;
                        for (var attempt = 0; attempt < 20 && !overlapEntered && !olderApply.IsCompleted; attempt++)
                        {
                            var receipt = await EqualizerHookEvaluateAsync("({entered:globalThis.__nativuneEqOverlapEntered===true})");
                            overlapEntered = receipt.GetProperty("entered").GetBoolean();
                            if (!overlapEntered) await Task.Delay(25, _lifetime.Token);
                        }
                        if (!overlapEntered || olderApply.IsCompleted)
                        {
                            await olderApply;
                            throw new InvalidOperationException("overlap-not-pending");
                        }
                        await ApplyEqualizerAsync(overlapApply, _lifetime.Token);
                        var newerState = EqualizerStatus.State;
                        var olderPendingAfterNewer = !olderApply.IsCompleted;
                        await olderApply;
                        result = new { state = EqualizerStatus.State.ToString().ToLowerInvariant(),
                            reason = EqualizerStatus.Reason, attached = EqualizerStatus.Attached,
                            sampleRate = EqualizerStatus.SampleRate, preampDb = _equalizerDesired?.PreampDb,
                            newerState = newerState.ToString().ToLowerInvariant(), olderPendingAfterNewer };
                        break;
                    case "eq-reload-document":
                        var reloadGeneration = _equalizerGeneration;
                        var reloadRevision = _equalizerRevision;
                        var reloadCompleted = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
                        void OnEqReloadCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs args) =>
                            reloadCompleted.TrySetResult(args.IsSuccess);
                        host.Core.NavigationCompleted += OnEqReloadCompleted;
                        try
                        {
                            host.Core.Reload();
                            if (!await reloadCompleted.Task.WaitAsync(TimeSpan.FromSeconds(10), _lifetime.Token))
                                throw new InvalidOperationException("eq-reload-navigation-failed");
                            for (var attempt = 0; attempt < 100 &&
                                (_equalizerGeneration <= reloadGeneration || _equalizerRevision <= reloadRevision); attempt++)
                                await Task.Delay(25, _lifetime.Token);
                            if (_equalizerGeneration <= reloadGeneration || _equalizerRevision <= reloadRevision)
                                throw new InvalidOperationException("eq-reload-apply-timeout");
                            result = new { generation = _equalizerGeneration, revision = _equalizerRevision };
                        }
                        finally { host.Core.NavigationCompleted -= OnEqReloadCompleted; }
                        break;
                    case "eq-host-status":
                        result = new { state = EqualizerStatus.State.ToString().ToLowerInvariant(),
                            reason = EqualizerStatus.Reason, attached = EqualizerStatus.Attached,
                            sampleRate = EqualizerStatus.SampleRate, preampDb = _equalizerDesired?.PreampDb,
                            gains = _equalizerDesired?.GainsDb, generation = _equalizerGeneration, revision = _equalizerRevision };
                        break;
                    case "eq-applied-preamp":
                        result = await EqualizerHookEvaluateAsync("(()=>{const g=__nativuneEq.__graph();return " +
                            "{sampleRate:g.ctx?.sampleRate??0,preampDb:g.preamp?20*Math.log10(g.preamp.gain.value):null," +
                            "gains:g.filters.map(f=>f.gain.value)}})()");
                        break;
                    case "eq-apply":
                        var apply = new EqualizerApply(value.GetProperty("enabled").GetBoolean(),
                            value.GetProperty("gains").EnumerateArray().Select(x => x.GetDouble()).ToArray(),
                            value.GetProperty("preampDb").GetDouble(), value.GetProperty("bypass").GetBoolean());
                        await ApplyEqualizerAsync(apply, _lifetime.Token);
                        result = _equalizerContext is null
                            ? JsonSerializer.SerializeToElement(new { state = EqualizerStatus.State.ToString().ToLowerInvariant(),
                                attached = EqualizerStatus.Attached, ctx = false })
                            : await EqualizerHookEvaluateAsync("({...__nativuneEq.status(), ctx:!!__nativuneEq.__graph().ctx," +
                                "contextState:__nativuneEq.__graph().ctx?.state??null,activation:{...__nativuneEqActivation}})");
                        break;
                    case "eq-status":
                        result = _equalizerContext is null
                            ? JsonSerializer.SerializeToElement(new { state = EqualizerStatus.State.ToString().ToLowerInvariant(),
                                attached = EqualizerStatus.Attached, ctx = false, generation = _equalizerGeneration })
                            : await EqualizerHookEvaluateAsync("({...__nativuneEq.status(),ctx:!!__nativuneEq.__graph().ctx," +
                                "contextState:__nativuneEq.__graph().ctx?.state??null,activation:{...__nativuneEqActivation}," +
                                "rejectedResumeConsumed:globalThis.__nativuneEqRejectedResumeConsumed===true})");
                        break;
                    case "eq-media":
                        var mediaRaw = await host.Core.ExecuteScriptAsync("(()=>{const v=document.querySelector('video');return {paused:v.paused,currentTime:v.currentTime,currentSrc:v.currentSrc,readyState:v.readyState,fixture:!!globalThis.__nativuneFixture?.eqProfile,trustedClicks:globalThis.__nativuneFixture?.eqTrustedClicks??0}})()");
                        using (var mediaJson = JsonDocument.Parse(mediaRaw)) result = mediaJson.RootElement.Clone();
                        break;
                    case "tray-state":
                        result = new { exists = _tray is not null, wanted = _tray?.IsWanted, visible = _tray?.IsVisible,
                            shellHasIcon = _tray?.TestShellHasIcon(), retryAttempt = _trayRetryAttempt };
                        break;
                    case "tray-fail-version":
                        NativeTrayIcon.TestFailVersions = 1;
                        result = new { armed = true };
                        break;
                    case "tray-shell-restart":
                        // Explorer restart as the app sees it: the icon vanishes from the shell, then the registered
                        // TaskbarCreated message arrives through the real window procedure. value = adds to fail first.
                        NativeTrayIcon.TestFailAdds = value.ValueKind == JsonValueKind.Number ? value.GetInt32() : 0;
                        _tray?.TestDropFromShell();
                        if (!TrayHookPostMessage(NativeHandle, (uint)TaskbarCreated, 0, 0))
                            throw new InvalidOperationException("post-failed");
                        result = new { posted = true };
                        break;
                    case "eq-response":
                        var gains = value.GetProperty("gains").EnumerateArray().Select(x => x.GetDouble()).ToArray();
                        var frequencies = value.GetProperty("frequencies").EnumerateArray().Select(x => x.GetDouble()).ToArray();
                        var sampleRate = value.GetProperty("sampleRate").GetDouble();
                        if (gains.Length != 10 || gains.Any(x => !double.IsFinite(x) || Math.Abs(x) > 12) ||
                            frequencies.Length is < 1 or > 64 || frequencies.Any(x => !double.IsFinite(x) || x <= 0 || x >= sampleRate / 2) ||
                            sampleRate is not (44100 or 48000)) throw new InvalidDataException("response-values");
                        result = new { responseDb = EqualizerMath.ResponseDb(gains, sampleRate, frequencies) };
                        break;
                    case "eq-profile":
                        var profile = value.GetString();
                        if (profile is not ("tones-48000" or "tones-44100" or "tones-16000" or "transient-48000" or
                            "transient-44100" or "click-48000" or "click-44100" or "foreign-source"))
                            throw new InvalidDataException("profile");
                        result = await host.Core.ExecuteScriptAsync($"globalThis.__nativuneFixture.eqProfile({JsonSerializer.Serialize(profile)})");
                        break;
                    case "eq-blocked-navigate":
                    case "eq-redirect-navigate":
                        var blockedNavigationBefore = _blockedNavigation;
                        await host.Core.ExecuteScriptAsync(command == "eq-redirect-navigate"
                            ? "location.href='https://music.youtube.com/__nativune_eq_redirect'"
                            : "location.href='https://example.com/'");
                        for (var attempt = 0; attempt < 100 && _blockedNavigation == blockedNavigationBefore; attempt++)
                            await Task.Delay(50, _lifetime.Token);
                        if (_blockedNavigation == blockedNavigationBefore)
                            throw new InvalidOperationException("Blocked navigation was not observed.");
                        result = new { blocked = true };
                        break;
                    case "eq-replace-element":
                        result = await host.Core.ExecuteScriptAsync("globalThis.__nativuneFixture.eqReplaceElement()");
                        break;
                    case "eq-navigate":
                        host.Core.Navigate("https://music.youtube.com/?eq=1&world=" + Guid.NewGuid().ToString("N"));
                        result = new { navigating = true };
                        break;
                    case "eq-suspend":
                        result = await EqualizerHookEvaluateAsync("(async()=>{await __nativuneEq.__graph().ctx.suspend();return __nativuneEq.status()})()");
                        break;
                    case "eq-reject-resume":
                        result = await EqualizerHookEvaluateAsync("(()=>{const c=__nativuneEq.__graph().ctx;const r=c.resume.bind(c);globalThis.__nativuneEqRejectedResumeConsumed=false;" +
                            "c.resume=()=>{c.resume=r;globalThis.__nativuneEqRejectedResumeConsumed=true;return Promise.resolve()};return {armed:true}})()");
                        break;
                    case "eq-collect-reset":
                        await InstallEqualizerCollectorAsync();
                        result = await EqualizerHookEvaluateAsync($"__nativuneEqCollect.reset({(value.ValueKind == JsonValueKind.Object ? value.GetRawText() : "{}")})");
                        break;
                    case "eq-collect-read":
                        result = await EqualizerHookEvaluateAsync("__nativuneEqCollect.read()");
                        break;
                    case "eq-rms":
                        // Real Music's CSP can block the AudioWorklet module, so the real-site smoke uses a
                        // temporary AnalyserNode on the post-preamp output: RMS numbers only, no samples kept.
                        result = await EqualizerHookEvaluateAsync("(async()=>{const g=__nativuneEq.__graph();if(!g.ctx||!g.preamp)return {ok:false};" +
                            "const a=g.ctx.createAnalyser();a.fftSize=2048;g.preamp.connect(a);const b=new Float32Array(a.fftSize);let max=0,sum=0;" +
                            "for(let i=0;i<20;i++){await new Promise(r=>setTimeout(r,50));a.getFloatTimeDomainData(b);let s=0;for(const v of b)s+=v*v;" +
                            "const rms=Math.sqrt(s/b.length);sum+=rms;if(rms>max)max=rms;}g.preamp.disconnect(a);" +
                            "return {ok:true,meanRms:sum/20,maxRms:max,contextState:g.ctx.state}})()");
                        break;
                    case "eq-mutant":
                        var mutant = value.GetString();
                        if (mutant is not ("none" or "parallel" or "zero-ramp" or "preamp-ignored" or "duplicate-path"))
                            throw new InvalidDataException("mutant");
                        await InstallEqualizerCollectorAsync();
                        result = await EqualizerHookEvaluateAsync($"__nativuneEqCollect.mutant({JsonSerializer.Serialize(mutant)})");
                        break;
                    case "eq-stale":
                        // The late request uses the current epoch but a strictly older revision.
                        result = await EqualizerHookEvaluateAsync($"__nativuneEq.apply({{rev:{_equalizerRevision - 1},epoch:{_equalizerGeneration},enabled:false,gains:Array(10).fill(0),preampDb:0,bypass:false}})");
                        break;
                    default: throw new InvalidDataException("command");
                }
                DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(_discordBenchDirectory, "eq-" + label + ".json"),
                    JsonSerializer.Serialize(new { ok = true, result, generation = _equalizerGeneration }));
            }
            catch (Exception ex)
            {
                File.Delete(path);
                DiscordPresenceDiagnostics.WriteAtomically(Path.Combine(_discordBenchDirectory, "eq-" + label + ".json"),
                    JsonSerializer.Serialize(new { ok = false, error = ex.GetType().Name, hresult = ex.HResult, detail = ex.Message }));
            }
        }
    }

    private async Task<JsonElement> EqualizerHookEvaluateAsync(string expression)
    {
        if (_equalizerContext is not int context || _browserHost is not { } host)
            throw new InvalidOperationException("No equalizer world.");
        var raw = await host.Core.CallDevToolsProtocolMethodAsync("Runtime.evaluate", JsonSerializer.Serialize(new {
            expression, contextId = context, returnByValue = true, awaitPromise = true, timeout = 5000
        })).AsTask().WaitAsync(TimeSpan.FromSeconds(6), _lifetime.Token);
        using var json = JsonDocument.Parse(raw);
        if (json.RootElement.TryGetProperty("exceptionDetails", out _)) throw new InvalidDataException("EQ hook evaluation.");
        return json.RootElement.GetProperty("result").GetProperty("value").Clone();
    }

    private async Task InstallEqualizerCollectorAsync()
    {
        using var stream = typeof(WebHostWindow).Assembly.GetManifestResourceStream("Nativune.EqualizerCollector.js")
            ?? throw new InvalidOperationException("Missing EQ collector.");
        using var reader = new StreamReader(stream);
        await EqualizerHookEvaluateAsync(await reader.ReadToEndAsync());
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
            ("utc", DateTime.UtcNow.ToString("o")), ("processId", Environment.ProcessId),
            ("overlay", ObsBenchStateJson()));
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
                    case double d: json.WriteNumber(name, d); break;
                    case DiscordBenchRawJson raw: json.WritePropertyName(name); json.WriteRawValue(raw.Json); break;
                    default: json.WriteString(name, value.ToString()); break;
                }
            }
            json.WriteEndObject();
        }
        return Encoding.UTF8.GetString(buffer.ToArray());
    }

    [System.Runtime.InteropServices.DllImport("user32.dll", EntryPoint = "PostMessageW", SetLastError = true)]
    [return: System.Runtime.InteropServices.MarshalAs(System.Runtime.InteropServices.UnmanagedType.Bool)]
    private static extern bool TrayHookPostMessage(nint window, uint message, nint wParam, nint lParam);
}

// Pre-serialised JSON value for DiscordBenchJson (nested objects such as the OBS overlay bench state).
internal readonly record struct DiscordBenchRawJson(string Json);
#endif
