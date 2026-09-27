namespace Nativune;

internal sealed record DiscordPresenceEnvironment(string? ApplicationId, string PipePrefix, TimeSpan PauseTimeout, TimeSpan MinWriteInterval, int ProcessId)
{
    private const string ProductionPipePrefix = "discord-ipc-";

    internal static DiscordPresenceEnvironment FromProcess()
    {
        var production = new DiscordPresenceEnvironment(
            DiscordPresence.ApplicationId, ProductionPipePrefix, TimeSpan.FromMinutes(10), TimeSpan.FromSeconds(15), Environment.ProcessId);
#if NATIVUNE_DISCORD_TEST_HOOKS
        var prefix = Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_PIPE_PREFIX");
        if (prefix is null) return production;
        if (!IsValidTestPrefix(prefix))
            return production with { ApplicationId = null, PipePrefix = "nativune-test-invalid-" }; // Unavailable; never real pipes
        var clientId = Environment.GetEnvironmentVariable("NATIVUNE_TEST_DISCORD_CLIENT_ID");
        var result = production with
        {
            PipePrefix = prefix,
            ApplicationId = clientId is { Length: > 0 and <= 32 } && clientId.All(char.IsAsciiDigit) ? clientId : production.ApplicationId
        };
        if (ReadSeconds("NATIVUNE_TEST_DISCORD_PAUSE_SECONDS") is int pause) result = result with { PauseTimeout = TimeSpan.FromSeconds(pause) };
        if (ReadSeconds("NATIVUNE_TEST_DISCORD_MIN_WRITE_SECONDS") is int write) result = result with { MinWriteInterval = TimeSpan.FromSeconds(write) };
        return result;
#else
        return production;
#endif
    }

#if NATIVUNE_DISCORD_TEST_HOOKS
    // ^nativune-test-[0-9a-f]{32}-discord-ipc-$
    private static bool IsValidTestPrefix(string value)
    {
        const string head = "nativune-test-", tail = "-discord-ipc-";
        if (value.Length != head.Length + 32 + tail.Length
            || !value.StartsWith(head, StringComparison.Ordinal) || !value.EndsWith(tail, StringComparison.Ordinal)) return false;
        foreach (var c in value.AsSpan(head.Length, 32))
            if (!(c is >= '0' and <= '9' or >= 'a' and <= 'f')) return false;
        return true;
    }

    private static int? ReadSeconds(string name)
        => int.TryParse(Environment.GetEnvironmentVariable(name), System.Globalization.NumberStyles.None,
            System.Globalization.CultureInfo.InvariantCulture, out var value) && value is >= 0 and <= 86_400 ? value : null;
#endif
}
