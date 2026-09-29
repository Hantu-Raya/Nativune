#if NATIVUNE_DISCORD_TEST_HOOKS
using System.Diagnostics;
using System.Text;
using System.Text.Json;

namespace Nativune;

// Discord bench protocol v2 diagnostics (plan .cache/tmp/discord-rpc/opt-refactor-plan.md §1, §4 item 4),
// compiled only with -p:DiscordPresenceTestHooks=true. Records numeric page state-read events in a bounded
// in-memory buffer: mode (fixed "Compact"/"Presence"), submitted script character count, QPC and UTC
// timestamps and validity. Never titles, links, script text, results or frames. Nothing touches the disk
// until WebHost.DiscordFixture.cs requests a boundary snapshot (fixed path under the root's data directory).
internal static class DiscordPresenceDiagnostics
{
    internal const int Capacity = 16384;
    private static readonly object s_gate = new();
    private static readonly Record[] s_records = new Record[Capacity];
    private static int s_count;
    private static long s_nextId;
    private static long s_dropped;

    private struct Record
    {
        public long Id;
        public string Mode;
        public int ScriptChars;
        public long StartedQpc;
        public long StartedUtcTicks;
        public long CompletedQpc;
        public bool Completed;
        public bool Valid;
    }

    internal static long RecordStateReadStarted(ReadReason reason, int scriptChars)
    {
        var normalized = reason.ToString();
        var qpc = Stopwatch.GetTimestamp();
        var utc = DateTime.UtcNow.Ticks;
        lock (s_gate)
        {
            var id = ++s_nextId;
            if (s_count >= Capacity)
            {
                s_dropped++;
                return id;
            }
            s_records[s_count++] = new Record
            {
                Id = id, Mode = normalized, ScriptChars = scriptChars, StartedQpc = qpc, StartedUtcTicks = utc,
            };
            return id;
        }
    }

    internal static void RecordStateReadCompleted(long id, bool valid)
    {
        var qpc = Stopwatch.GetTimestamp();
        lock (s_gate)
        {
            // Ids are dense and records are appended in id order, so index = id - first id.
            if (s_count == 0) return;
            var index = (int)(id - s_records[0].Id);
            if (index < 0 || index >= s_count || s_records[index].Id != id || s_records[index].Completed) return;
            s_records[index].Completed = true;
            s_records[index].Valid = valid;
            s_records[index].CompletedQpc = qpc;
        }
    }

    // Writes every record so far plus a boundary stamp. Called only from bench-mode fixture commands.
    internal static void WriteSnapshot(string path, string label)
    {
        Record[] copy;
        long dropped, issued;
        lock (s_gate)
        {
            copy = s_records.AsSpan(0, s_count).ToArray();
            dropped = s_dropped;
            issued = s_nextId;
        }
        var boundaryQpc = Stopwatch.GetTimestamp();
        var boundaryUtc = DateTime.UtcNow;
        using var buffer = new MemoryStream();
        using (var json = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = false }))
        {
            json.WriteStartObject();
            json.WriteNumber("schema", 2);
            json.WriteString("label", label);
            json.WriteString("clock", "QueryPerformanceCounter");
            json.WriteNumber("qpcFrequency", Stopwatch.Frequency);
            json.WriteNumber("boundaryQpc", boundaryQpc);
            json.WriteString("boundaryUtc", boundaryUtc.ToString("o"));
            json.WriteNumber("processId", Environment.ProcessId);
            json.WriteNumber("issued", issued);
            json.WriteNumber("dropped", dropped);
            json.WriteStartArray("reads");
            foreach (var record in copy)
            {
                json.WriteStartObject();
                json.WriteNumber("id", record.Id);
                json.WriteString("mode", record.Mode);
                json.WriteNumber("scriptChars", record.ScriptChars);
                json.WriteNumber("startQpc", record.StartedQpc);
                json.WriteString("startUtc", new DateTime(record.StartedUtcTicks, DateTimeKind.Utc).ToString("o"));
                json.WriteBoolean("completed", record.Completed);
                if (record.Completed)
                {
                    json.WriteNumber("endQpc", record.CompletedQpc);
                    json.WriteBoolean("valid", record.Valid);
                }
                json.WriteEndObject();
            }
            json.WriteEndArray();
            json.WriteEndObject();
        }
        WriteAtomically(path, buffer.ToArray());
    }

    internal static void WriteAtomically(string path, byte[] bytes)
    {
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        var temporary = path + ".tmp";
        File.WriteAllBytes(temporary, bytes);
        File.Move(temporary, path, overwrite: true);
    }

    internal static void WriteAtomically(string path, string text) => WriteAtomically(path, Encoding.UTF8.GetBytes(text));
}
#endif
