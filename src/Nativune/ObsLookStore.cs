using System.Text.Json;

namespace Nativune;

/// <summary>How a <see cref="ObsLookStore.SaveAsync"/> call ended. Only <c>Committed</c> means the file changed.</summary>
internal enum ObsLookSaveStatus
{
    /// <summary>The temporary file replaced the looks file (the commit point of plan §2.9).</summary>
    Committed,
    /// <summary>The state is read-only (whole-file failure, newer version, quarantine); nothing was written.</summary>
    ReadOnly,
    /// <summary>The serialised file would exceed 64 KiB, or the state broke a store invariant; nothing was written.</summary>
    TooLarge,
    /// <summary>An I/O or serialisation failure; the previous file is intact.</summary>
    Failed,
    /// <summary>The token was cancelled before the replace; the previous file is intact.</summary>
    Cancelled,
}

/// <summary>Outcome of a save. <see cref="Reason"/> is null when committed, otherwise a short path-free diagnostic.</summary>
internal readonly record struct ObsLookSaveResult(ObsLookSaveStatus Status, string? Reason)
{
    internal bool Committed => Status == ObsLookSaveStatus.Committed;
}

#if NATIVUNE_DISCORD_TEST_HOOKS
// Injected write faults (command-obs-store-fault), each armed for the next write only:
//   Tmp     the process "dies" with the temporary file half written (a stale, truncated .tmp stays behind);
//   Replace the process "dies" after the temporary file is complete, before the replace (a complete .tmp stays);
//   Slow    the write waits <delay> ms (cancellable) between the temporary file and the replace.
// The looks file itself is never touched by a Tmp or Replace fault.
internal enum ObsLookStoreFault { Tmp, Replace, Slow }
#endif

/// <summary>
/// <c>data/obs-looks.json</c> (plan §2.7): authoritative, versioned, capped at 64 KiB on read and on the serialised
/// write. Load never throws and never writes: every whole-file failure yields a read-only state with a reason and the
/// bytes untouched. Saves go through <c>.tmp</c>, flush and an atomic replace; a stale <c>.tmp</c> is ignored on load
/// and overwritten (then gone) by the next successful save.
/// </summary>
internal static class ObsLookStore
{
    internal const int MaxFileBytes = 64 * 1024;
    internal const int MaxDepth = 8;
    internal const string TooLargeMessage = "Could not save: the looks file would be too large";

    private const string LogCategory = "obs";

    /// <summary><c>&lt;root&gt;/data/obs-looks.json</c>; the temporary file is this path plus <c>.tmp</c>.</summary>
    internal static string Path(string root) =>
        System.IO.Path.Combine(System.IO.Path.GetFullPath(root), "data", "obs-looks.json");

    /// <summary>
    /// Reads the looks file. Absent: empty and writable. Whole-file failures (larger than 64 KiB; unreadable; invalid
    /// UTF-8, a BOM being accepted; malformed JSON; deeper than 8 levels; root not an object; <c>version</c> missing or
    /// not a positive integer; <c>looks</c>/<c>retired</c> present but not arrays): no looks, read-only with a reason.
    /// <c>version &gt; 1</c>: read-only, records served after v1 normalisation. Records that are not objects or have an
    /// invalid id or name are skipped (one log line each), a duplicate id keeps the first, options normalise per §4.4.
    /// <c>retired</c> keeps id-grammar strings once each and drops ids of live looks. More than 16 valid looks: the
    /// first 16 are served, the rest counted in <see cref="ObsLookState.Quarantined"/>, read-only.
    /// </summary>
    internal static ObsLookState Load(string root)
    {
        try
        {
            byte[]? file;
            try
            {
                file = ReadBounded(Path(root));
            }
            catch (Exception ex) when (ex is FileNotFoundException or DirectoryNotFoundException)
            {
                return ObsLookState.Empty;
            }
            catch (Exception ex) when (ex is IOException or UnauthorizedAccessException)
            {
                return Refuse("the file could not be read", ex.GetType().Name);
            }
            return file is null ? Refuse("the file is larger than 64 KiB") : Parse(file);
        }
        catch (Exception ex)
        {
            return Refuse("the file could not be read", ex.GetType().Name);
        }
    }

    /// <summary>
    /// Serialises <paramref name="state"/> (System.Text.Json, indented, default encoder), rejects it above 64 KiB, then
    /// writes <c>.tmp</c>, flushes it to disk and replaces the looks file. Expected failures come back as a result, not
    /// an exception. A cancellation observed after the replace still returns <c>Committed</c>. The caller serialises
    /// concurrent saves (<c>_looksSaveLock</c>). Read-only states never write.
    /// </summary>
    internal static async Task<ObsLookSaveResult> SaveAsync(string root, ObsLookState state, CancellationToken token)
    {
        ArgumentNullException.ThrowIfNull(state);
        if (state.ReadOnlyReason is { } locked)
            return new ObsLookSaveResult(ObsLookSaveStatus.ReadOnly, $"Could not save: the looks file is read-only ({locked})");
        if (token.IsCancellationRequested) return Cancelled();
        if (!TrySerialize(state, out var bytes, out var failure)) return failure;

#if NATIVUNE_DISCORD_TEST_HOOKS
        var fault = TakeFault();
        var crashed = false;
#endif
        var moved = false;
        string? temporary = null;
        try
        {
            var path = Path(root);
            temporary = path + ".tmp";
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(path)!);
            await using (var stream = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None,
                4096, FileOptions.Asynchronous | FileOptions.SequentialScan))
            {
#if NATIVUNE_DISCORD_TEST_HOOKS
                if (fault is { Kind: ObsLookStoreFault.Tmp })
                {
                    await stream.WriteAsync(bytes.AsMemory(0, bytes.Length / 2), token).ConfigureAwait(false);
                    await stream.FlushAsync(token).ConfigureAwait(false);
                    crashed = true;
                    throw new IOException("injected looks store fault (tmp)");
                }
#endif
                await stream.WriteAsync(bytes, token).ConfigureAwait(false);
                await stream.FlushAsync(token).ConfigureAwait(false);
                stream.Flush(flushToDisk: true);
            }

#if NATIVUNE_DISCORD_TEST_HOOKS
            if (fault is { Kind: ObsLookStoreFault.Replace })
            {
                crashed = true;
                throw new IOException("injected looks store fault (replace)");
            }
            if (fault is { Kind: ObsLookStoreFault.Slow, DelayMs: > 0 })
                await Task.Delay(fault.Value.DelayMs, token).ConfigureAwait(false);
#endif

            // Directly adjacent to the replace: a cancelled commit must not replace the file.
            token.ThrowIfCancellationRequested();
            File.Move(temporary, path, overwrite: true);
            moved = true; // commit point: nothing below may turn this into a failure
            return new ObsLookSaveResult(ObsLookSaveStatus.Committed, null);
        }
        catch (OperationCanceledException)
        {
            return Cancelled();
        }
        catch (Exception ex)
        {
            // Keep filesystem details (paths can contain private data) out of the result.
            AppLog.Write(LogCategory, $"looks: save failed ({ex.GetType().Name})");
            return new ObsLookSaveResult(ObsLookSaveStatus.Failed, "Could not save: the looks file could not be written");
        }
        finally
        {
#if NATIVUNE_DISCORD_TEST_HOOKS
            if (!moved && !crashed && temporary is not null) DeleteQuietly(temporary);
#else
            if (!moved && temporary is not null) DeleteQuietly(temporary);
#endif
        }
    }

#if NATIVUNE_DISCORD_TEST_HOOKS
    private readonly record struct HookFault(ObsLookStoreFault Kind, int DelayMs);

    private static int s_faultKind; // 0 = none, otherwise (int)kind + 1
    private static int s_faultDelayMs;

    /// <summary>Arms one fault for the next write that reaches the disk (later writes are normal). <paramref name="delayMs"/> is used by Slow.</summary>
    internal static void InjectFault(ObsLookStoreFault kind, int delayMs = 0)
    {
        Volatile.Write(ref s_faultDelayMs, Math.Max(0, delayMs));
        Volatile.Write(ref s_faultKind, (int)kind + 1);
    }

    internal static void ClearFault() => Volatile.Write(ref s_faultKind, 0);

    private static HookFault? TakeFault()
    {
        var kind = Interlocked.Exchange(ref s_faultKind, 0);
        return kind == 0 ? (HookFault?)null : new HookFault((ObsLookStoreFault)(kind - 1), Volatile.Read(ref s_faultDelayMs));
    }
#endif

    private static ObsLookSaveResult Cancelled() =>
        new(ObsLookSaveStatus.Cancelled, "Could not save: cancelled before the file was replaced");

    // Null when the file is longer than the cap (the caller reports it read-only without parsing).
    private static byte[]? ReadBounded(string path)
    {
        var buffer = new byte[MaxFileBytes + 1];
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read,
            FileShare.ReadWrite | FileShare.Delete, 4096, FileOptions.SequentialScan);
        var length = 0;
        while (length < buffer.Length)
        {
            var count = stream.Read(buffer, length, buffer.Length - length);
            if (count == 0) break;
            length += count;
        }
        if (length > MaxFileBytes) return null;
        Array.Resize(ref buffer, length);
        return buffer;
    }

    private static ObsLookState Parse(byte[] file)
    {
        ReadOnlyMemory<byte> memory = file;
        if (file.Length >= 3 && file[0] == 0xEF && file[1] == 0xBB && file[2] == 0xBF) memory = memory.Slice(3);
        if (!System.Text.Unicode.Utf8.IsValid(memory.Span)) return Refuse("the file is not valid UTF-8");

        JsonDocument document;
        try
        {
            document = JsonDocument.Parse(memory, new JsonDocumentOptions { MaxDepth = MaxDepth });
        }
        catch (JsonException)
        {
            return Refuse(ExceedsDepth(memory) ? "the file is nested more than 8 levels deep" : "the file is not valid JSON");
        }

        using (document)
        {
            return Read(document.RootElement);
        }
    }

    // Distinguishes "too deep" from "malformed": the same bytes parse once the depth limit is lifted.
    private static bool ExceedsDepth(ReadOnlyMemory<byte> memory)
    {
        try
        {
            using var probe = JsonDocument.Parse(memory, new JsonDocumentOptions { MaxDepth = MaxFileBytes });
            return true;
        }
        catch (JsonException)
        {
            return false;
        }
    }

    private static ObsLookState Read(JsonElement root)
    {
        if (root.ValueKind != JsonValueKind.Object) return Refuse("the file does not hold a JSON object");
        if (!root.TryGetProperty("version", out var versionElement)
            || versionElement.ValueKind != JsonValueKind.Number
            || !versionElement.TryGetInt64(out var version)
            || version < 1)
            return Refuse("the file has no valid version number");
        var hasLooks = root.TryGetProperty("looks", out var looksElement);
        if (hasLooks && looksElement.ValueKind != JsonValueKind.Array) return Refuse("its \"looks\" entry is not an array");
        var hasRetired = root.TryGetProperty("retired", out var retiredElement);
        if (hasRetired && retiredElement.ValueKind != JsonValueKind.Array) return Refuse("its \"retired\" entry is not an array");

        var looks = new List<ObsLook>();
        var known = new HashSet<string>(StringComparer.Ordinal); // ids of every valid record, served or quarantined
        var quarantined = 0;
        if (hasLooks)
        {
            var index = -1;
            foreach (var record in looksElement.EnumerateArray())
            {
                index++;
                if (!ObsLookValidation.TryReadLook(record, out var look, out var why))
                {
                    AppLog.Write(LogCategory, $"looks: record {index} skipped ({why})");
                    continue;
                }
                if (!known.Add(look.Id))
                {
                    AppLog.Write(LogCategory, $"looks: record {index} skipped (duplicate id)");
                    continue;
                }
                if (looks.Count < ObsLookState.MaxLooks) looks.Add(look);
                else quarantined++;
            }
        }

        var retired = new List<string>();
        if (hasRetired)
        {
            var seen = new HashSet<string>(StringComparer.Ordinal);
            foreach (var item in retiredElement.EnumerateArray())
            {
                var id = ObsLookValidation.AsString(item);
                if (ObsLookValidation.IsValidId(id) && !known.Contains(id) && seen.Add(id)) retired.Add(id);
            }
        }

        string? reason = null;
        if (version > 1) reason = "written by a newer Nativune";
        else if (quarantined > 0)
            reason = $"more than {ObsLookState.MaxLooks} looks; only the first {ObsLookState.MaxLooks} are used";
        if (reason is not null) AppLog.Write(LogCategory, $"looks: read-only, {reason}");
        return new ObsLookState(looks.ToArray(), retired.ToArray(), reason, quarantined);
    }

    private static ObsLookState Refuse(string reason, string? detail = null)
    {
        AppLog.Write(LogCategory, detail is null ? $"looks: read-only, {reason}" : $"looks: read-only, {reason} ({detail})");
        return new ObsLookState([], [], reason, 0);
    }

    /// <summary>
    /// The I/O-free half of a save (plan §2.9 step 1: serialise, cap-check): validates the store invariants (at most 16
    /// looks, valid unique ids, valid trimmed names, valid retired list disjoint from the live ids) and writes the v1
    /// document into <paramref name="bytes"/>. Returns false with a Failed or TooLarge result otherwise, touching nothing
    /// on disk. A state that <see cref="Load"/> or the <see cref="ObsLookState"/> mutation helpers produced always
    /// passes the invariants; the checks stop a caller bug from writing a file that would reload differently.
    /// <see cref="SaveAsync"/> calls it first; callers that only need to know whether a mutation still fits (for
    /// example a hook running many in-memory cycles) can call it without paying for a disk write.
    /// </summary>
    internal static bool TrySerialize(ObsLookState state, out byte[] bytes, out ObsLookSaveResult failure)
    {
        bytes = [];
        failure = default;
        try
        {
            if (state.Looks.Count > ObsLookState.MaxLooks)
            {
                failure = new ObsLookSaveResult(ObsLookSaveStatus.Failed,
                    $"Could not save: more than {ObsLookState.MaxLooks} looks");
                return false;
            }
            var ids = new HashSet<string>(StringComparer.Ordinal);
            foreach (var look in state.Looks)
            {
                if (!ObsLookValidation.IsValidId(look.Id) || !ids.Add(look.Id))
                {
                    failure = new ObsLookSaveResult(ObsLookSaveStatus.Failed,
                        "Could not save: a look has an invalid or duplicate id");
                    return false;
                }
                if (!ObsLookValidation.TryNormalizeName(look.Name, out var trimmed) || trimmed != look.Name)
                {
                    failure = new ObsLookSaveResult(ObsLookSaveStatus.Failed,
                        "Could not save: a look has an invalid name");
                    return false;
                }
            }
            var retired = new HashSet<string>(StringComparer.Ordinal);
            foreach (var id in state.Retired)
            {
                if (!ObsLookValidation.IsValidId(id) || ids.Contains(id) || !retired.Add(id))
                {
                    failure = new ObsLookSaveResult(ObsLookSaveStatus.Failed,
                        "Could not save: the retired id list is invalid");
                    return false;
                }
            }

            using var buffer = new MemoryStream(4096);
            using (var w = new Utf8JsonWriter(buffer, new JsonWriterOptions { Indented = true }))
            {
                w.WriteStartObject();
                w.WriteNumber("version", 1);
                w.WriteStartArray("looks");
                foreach (var look in state.Looks)
                {
                    w.WriteStartObject();
                    w.WriteString("id", look.Id);
                    w.WriteString("name", look.Name);
                    w.WritePropertyName("options");
                    ObsLookJson.WriteOptions(w, ObsLookValidation.Normalize(look.Options));
                    w.WriteEndObject();
                }
                w.WriteEndArray();
                w.WriteStartArray("retired");
                foreach (var id in state.Retired) w.WriteStringValue(id);
                w.WriteEndArray();
                w.WriteEndObject();
            }
            bytes = buffer.ToArray();
        }
        catch (Exception ex)
        {
            AppLog.Write(LogCategory, $"looks: serialisation failed ({ex.GetType().Name})");
            failure = new ObsLookSaveResult(ObsLookSaveStatus.Failed, "Could not save: the looks could not be serialised");
            return false;
        }

        if (bytes.Length > MaxFileBytes)
        {
            failure = new ObsLookSaveResult(ObsLookSaveStatus.TooLarge, TooLargeMessage);
            return false;
        }
        return true;
    }

    private static void DeleteQuietly(string path)
    {
        try
        {
            File.Delete(path);
        }
        catch (IOException)
        {
        }
        catch (UnauthorizedAccessException)
        {
        }
    }
}
