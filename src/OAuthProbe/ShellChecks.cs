namespace OAuthProbe;

internal static class ShellChecks
{
    internal static void Run(string root)
    {
        var settings = new ShellSettings(4000, -2000, 1000, 700, 96, true, 1.25)
            { TrayEnabled = true, RestoreSection = true, LastSection = "library" };
        ShellSettings.SaveAsync(root, settings, CancellationToken.None).GetAwaiter().GetResult();
        var loaded = ShellSettings.Load(root, out var warning);
        Require(warning is null && loaded == settings, "Window settings did not survive a save and reload.");
        var area = new System.Drawing.Rectangle(-1280, 0, 1280, 720);
        var bounds = ShellSettings.RestoreBounds(loaded, area, 144);
        Require(area.Contains(bounds) && bounds.Width >= 640 && bounds.Height >= 480,
            "Restored window is inaccessible after display/DPI change.");
        var small = new System.Drawing.Rectangle(0, 0, 500, 350);
        Require(small.Contains(ShellSettings.RestoreBounds(loaded, small, 192)), "Small work area clipping failed.");
        var file = Path.Combine(root, "data", "settings.json");
        Require(loaded.StartupUri == "https://music.youtube.com/library"
            && (loaded with { RestoreSection = false }).StartupUri == "https://music.youtube.com/",
            "Section restoration ignored its opt-in boundary.");
        Require(ShellSettings.SectionFromUri(new Uri("https://music.youtube.com/library?private=value")) == "library"
            && ShellSettings.SectionFromUri(new Uri("https://music.youtube.com/playlist?list=private")) is null
            && ShellSettings.SectionFromUri(new Uri("https://music.youtube.com.evil.example/library")) is null
            && ShellSettings.SectionFromUri(new Uri("https://user@music.youtube.com/library")) is null,
            "Section classification accepted a private route or untrusted origin.");
        ShellSettings.SaveAsync(root, settings with { LastSection = "https://evil.example/private" }, CancellationToken.None).GetAwaiter().GetResult();
        Require(ShellSettings.Load(root, out _).LastSection == "home", "Unrecognized section was retained.");
        File.WriteAllText(file, """{"Version":1,"X":100,"Y":100,"Width":1280,"Height":800,"Dpi":96,"Maximized":false,"Zoom":1}""");
        var previous = ShellSettings.Load(root, out warning);
        Require(warning is null && !previous.TrayEnabled && !previous.RestoreSection && previous.Zoom == 1,
            "Existing P1 settings enabled optional features during upgrade.");
        File.WriteAllText(file, "{broken");
        _ = ShellSettings.Load(root, out warning);
        Require(warning is not null, "Corrupt settings were silently accepted.");
        File.WriteAllText(file, new string(' ', 16385));
        _ = ShellSettings.Load(root, out warning);
        Require(warning is not null, "Oversized settings were accepted.");
        ShellSettings.SaveAsync(root, settings, CancellationToken.None).GetAwaiter().GetResult();
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        try
        {
            ShellSettings.SaveAsync(root, settings with { Zoom = 1 }, cancelled.Token).GetAwaiter().GetResult();
            throw new SelfCheckException("Cancelled settings save was accepted.");
        }
        catch (OperationCanceledException) { }
        Require(ShellSettings.Load(root, out _) == settings, "Cancelled save replaced existing settings.");
        using var timer = new SleepDeadline(() => throw new SelfCheckException("Cancelled timer fired."), new SynchronizationContext());
        timer.Arm(TimeSpan.FromMinutes(1));
        Require(timer.IsArmed, "Quit timer did not arm.");
        timer.Cancel();
        timer.CheckOnResume();
        Require(!timer.IsArmed, "Cancelled timer stayed armed after resume.");
        try
        {
            timer.Arm(TimeSpan.Zero);
            throw new SelfCheckException("Invalid quit duration was accepted.");
        }
        catch (ArgumentOutOfRangeException) { }
        Console.WriteLine("Shell checks passed: persisted settings, DPI/off-screen repair, corrupt/oversized input, cancelled writes and timer cancellation.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition) throw new SelfCheckException(message);
    }
}
