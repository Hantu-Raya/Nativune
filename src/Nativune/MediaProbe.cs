using System.Runtime.InteropServices;
using System.Text.Json;
using Windows.Media.Control;

namespace Nativune;

internal static class MediaProbe
{
    public static async Task<int> RunAsync(bool interactive, CancellationToken cancellationToken)
    {
        try
        {
            var manager = await GlobalSystemMediaTransportControlsSessionManager.RequestAsync()
                .AsTask(cancellationToken).WaitAsync(TimeSpan.FromSeconds(10), cancellationToken);
            var sessions = manager.GetSessions().ToArray();
            Console.WriteLine($"Windows media sessions: {sessions.Length}.");
            for (var i = 0; i < sessions.Length; i++)
            {
                Console.WriteLine($"[{i + 1}] Source: {JsonSerializer.Serialize(sessions[i].SourceAppUserModelId)}");
                PrintState(sessions[i]);
            }
            if (sessions.Length == 0)
            {
                Console.WriteLine("No session is exposed. Play a song in the official Music site in your desktop browser, then retry.");
                return 7;
            }
            if (!interactive)
                return 0;

            Console.WriteLine("Select the Music browser session number (0 cancels). No player is selected automatically.");
            var input = await Console.In.ReadLineAsync(cancellationToken);
            if (input is null || input.Trim() == "0")
                return 0;
            if (!int.TryParse(input, out var index) || index < 1 || index > sessions.Length)
                throw new UsageException("Invalid session number; no control was sent.");
            var selected = sessions[index - 1];
            string? previousTitle = null;
            string? previousArtist = null;
            Console.WriteLine("Selected session stays fixed. Commands: inspect, watch, play, pause, next, previous, quit.");
            while (true)
            {
                if (!manager.GetSessions().Contains(selected))
                {
                    Console.WriteLine("Selected session disappeared; no other player was selected.");
                    return 7;
                }
                var metadata = await selected.TryGetMediaPropertiesAsync().AsTask(cancellationToken)
                    .WaitAsync(TimeSpan.FromSeconds(10), cancellationToken);
                var changed = previousTitle is not null && (metadata.Title != previousTitle || metadata.Artist != previousArtist);
                Console.WriteLine($"Track metadata: titlePresent={!string.IsNullOrEmpty(metadata.Title)}, artistPresent={!string.IsNullOrEmpty(metadata.Artist)}, changed={changed}.");
                previousTitle = metadata.Title;
                previousArtist = metadata.Artist;
                PrintState(selected);
                Console.Write("media> ");
                var command = (await Console.In.ReadLineAsync(cancellationToken))?.Trim().ToLowerInvariant();
                if (command is null or "quit")
                    return 0;
                if (command == "inspect")
                    continue;
                if (command == "watch")
                {
                    // Bounded observation, not the eventual companion's event-driven UI.
                    for (var sample = 0; sample < 20; sample++)
                    {
                        await Task.Delay(TimeSpan.FromSeconds(1), cancellationToken);
                        if (!manager.GetSessions().Contains(selected))
                        {
                            Console.WriteLine("Selected session disappeared; no other player was selected.");
                            return 7;
                        }
                        PrintState(selected);
                    }
                    continue;
                }
                var controls = selected.GetPlaybackInfo().Controls;
                var supported = command switch
                {
                    "play" => controls.IsPlayEnabled,
                    "pause" => controls.IsPauseEnabled,
                    "next" => controls.IsNextEnabled,
                    "previous" => controls.IsPreviousEnabled,
                    _ => false
                };
                if (!supported)
                {
                    Console.WriteLine("Unknown or unsupported command; no control was sent.");
                    continue;
                }
                var operation = command switch
                {
                    "play" => selected.TryPlayAsync(),
                    "pause" => selected.TryPauseAsync(),
                    "next" => selected.TrySkipNextAsync(),
                    "previous" => selected.TrySkipPreviousAsync(),
                    _ => throw new UsageException("Unknown media command.")
                };
                var accepted = await operation.AsTask(cancellationToken)
                    .WaitAsync(TimeSpan.FromSeconds(10), cancellationToken);
                Console.WriteLine(accepted
                    ? "Control accepted by the session; inspect subsequent state to verify its effect."
                    : "Control rejected by the session; no retry or fallback player was used.");
                await Task.Delay(TimeSpan.FromMilliseconds(300), cancellationToken);
            }
        }
        catch (Exception ex) when (ex is COMException or UnauthorizedAccessException or TimeoutException)
        {
            Console.Error.WriteLine($"Windows media access failed ({ex.GetType().Name}, HRESULT 0x{ex.HResult:X8}). No fallback player was used.");
            return 8;
        }
    }

    private static void PrintState(GlobalSystemMediaTransportControlsSession session)
    {
        var info = session.GetPlaybackInfo();
        var controls = info.Controls;
        var timeline = session.GetTimelineProperties();
        Console.WriteLine($"State: {info.PlaybackStatus}; position={timeline.Position.TotalSeconds:F1}s; end={timeline.EndTime.TotalSeconds:F1}s.");
        Console.WriteLine($"Controls: play={controls.IsPlayEnabled}, pause={controls.IsPauseEnabled}, next={controls.IsNextEnabled}, previous={controls.IsPreviousEnabled}, seek={controls.IsPlaybackPositionEnabled}.");
    }
}
