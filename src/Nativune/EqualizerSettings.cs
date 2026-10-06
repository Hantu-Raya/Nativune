using System.Text;
using System.Text.Json;

namespace Nativune;

internal static class EqualizerBands
{
    public static readonly double[] CentresHz = { 31.5, 63, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 };
    public static readonly string[] Labels = { "31.5 Hz", "63 Hz", "125 Hz", "250 Hz", "500 Hz", "1 kHz", "2 kHz", "4 kHz", "8 kHz", "16 kHz" };
    public const int Count = 10;
    public const double Q = 1.4142135623730951;
    public const double MinGainDb = -12, MaxGainDb = 12, StepDb = 0.5;
    public const double MinPreampDb = -24, MaxPreampDb = 6;
    public const double AutoHeadroomMarginDb = 1.0;
    public const int MaxCustomPresets = 20, MaxNameLength = 40, MaxShareBytes = 2048;

    public static double QuantizeGain(double value) => Quantize(value, MinGainDb, MaxGainDb);
    public static double QuantizePreamp(double value) => Quantize(value, MinPreampDb, MaxPreampDb);

    private static double Quantize(double value, double minimum, double maximum)
    {
        if (!double.IsFinite(value))
            throw new ArgumentOutOfRangeException(nameof(value), "Equalizer values must be finite.");
        return Math.Clamp(Math.Round(value / StepDb, MidpointRounding.AwayFromZero) * StepDb, minimum, maximum);
    }
}

internal sealed record EqualizerPreset(string Id, string Name, IReadOnlyList<double> GainsDb, double PreampDb, bool AutoHeadroom, bool BuiltIn);

internal sealed record EqualizerSettings(
    bool Enabled, string? SelectedPresetId, IReadOnlyList<double> GainsDb,
    double ManualPreampDb, bool AutoHeadroom, IReadOnlyList<EqualizerPreset> CustomPresets)
{
    public static EqualizerSettings Default { get; } = new(false, "flat", Array.AsReadOnly(new double[10]),
        0, true, Array.Empty<EqualizerPreset>());
    public bool IsFlat => GainsDb.All(gain => gain == 0) && EqualizerMath.EffectivePreampDb(this) == 0;
}

internal static class EqualizerPresets
{
    public static IReadOnlyList<EqualizerPreset> BuiltIns { get; } = Array.AsReadOnly(new[]
    {
        BuiltIn("flat", "Flat", 0, 0, 0, 0, 0, 0, 0, 0, 0, 0),
        BuiltIn("bass-boost", "Bass boost", 6, 5, 4, 2, 0, 0, 0, 0, 0, 0),
        BuiltIn("bass-reducer", "Bass reducer", -6, -5, -4, -2, 0, 0, 0, 0, 0, 0),
        BuiltIn("treble-boost", "Treble boost", 0, 0, 0, 0, 0, 0, 2, 4, 5, 6),
        BuiltIn("treble-reducer", "Treble reducer", 0, 0, 0, 0, 0, 0, -2, -4, -5, -6),
        BuiltIn("vocal", "Vocal", -2, -2, -1, 0, 2, 3, 3, 2, 0, -1),
        BuiltIn("loudness", "Loudness", 5, 4, 2, 0, -1, -1, 0, 2, 3, 4),
        BuiltIn("spoken-word", "Spoken word", -6, -5, -3, 0, 2, 3, 3, 2, 0, -2)
    });

    private static EqualizerPreset BuiltIn(string id, string name, params double[] gains)
        => new(id, name, Array.AsReadOnly(gains), 0, true, true);

    public static EqualizerPreset? Find(EqualizerSettings settings, string? id)
        => BuiltIns.FirstOrDefault(preset => preset.Id == id)
            ?? settings.CustomPresets.FirstOrDefault(preset => preset.Id == id);

    public static bool TryValidateName(string name, out string trimmed, out string error)
    {
        trimmed = name.Trim();
        error = string.Empty;
        if (trimmed.Length is < 1 or > EqualizerBands.MaxNameLength || name.Any(char.IsControl))
        {
            error = "Preset names must be 1–40 characters and contain no control characters.";
            return false;
        }
        return true;
    }

    internal static bool IsCustomId(string id)
        => id.Length == 10 && id.StartsWith("c-", StringComparison.Ordinal)
            && id.AsSpan(2).IndexOfAnyExcept("0123456789abcdef") < 0;
}

internal static class EqualizerMath
{
    public const double MinimumSampleRate = 8000;

    public static double[] ResponseDb(IReadOnlyList<double> gainsDb, double sampleRate, IReadOnlyList<double> frequenciesHz)
    {
        if (gainsDb.Count != EqualizerBands.Count || gainsDb.Any(gain => !double.IsFinite(gain)))
            throw new ArgumentException("Exactly ten finite equalizer gains are required.", nameof(gainsDb));
        // Output devices can run the AudioContext below 40 kHz (e.g. 16 kHz Bluetooth hands-free).
        if (!double.IsFinite(sampleRate) || sampleRate < MinimumSampleRate)
            throw new ArgumentOutOfRangeException(nameof(sampleRate));
        if (frequenciesHz.Any(frequency => !double.IsFinite(frequency) || frequency < 0 || frequency > sampleRate / 2))
            throw new ArgumentOutOfRangeException(nameof(frequenciesHz));
        var response = new double[frequenciesHz.Count];
        for (var band = 0; band < EqualizerBands.Count; band++)
        {
            if (gainsDb[band] == 0)
                continue; // Flat remains exactly unity, without floating-point residue.
            // Web Audio clamps a BiquadFilter's frequency to Nyquist, where a peaking filter is unity
            // (sin(pi) = 0 makes alpha 0), so a band at or above Nyquist does not shape the output.
            if (EqualizerBands.CentresHz[band] >= sampleRate / 2)
                continue;
            var amplitude = Math.Pow(10, gainsDb[band] / 40);
            var omega = 2 * Math.PI * EqualizerBands.CentresHz[band] / sampleRate;
            var alpha = Math.Sin(omega) / (2 * EqualizerBands.Q);
            var b0 = 1 + alpha * amplitude;
            var b1 = -2 * Math.Cos(omega);
            var b2 = 1 - alpha * amplitude;
            var a0 = 1 + alpha / amplitude;
            var a1 = b1;
            var a2 = 1 - alpha / amplitude;
            for (var index = 0; index < response.Length; index++)
            {
                var frequency = frequenciesHz[index];
                var angle = 2 * Math.PI * frequency / sampleRate;
                var cosine = Math.Cos(angle);
                var sine = Math.Sin(angle);
                var cosine2 = Math.Cos(2 * angle);
                var sine2 = Math.Sin(2 * angle);
                var numeratorReal = b0 + b1 * cosine + b2 * cosine2;
                var numeratorImaginary = -b1 * sine - b2 * sine2;
                var denominatorReal = a0 + a1 * cosine + a2 * cosine2;
                var denominatorImaginary = -a1 * sine - a2 * sine2;
                response[index] += 10 * Math.Log10((numeratorReal * numeratorReal + numeratorImaginary * numeratorImaginary)
                    / (denominatorReal * denominatorReal + denominatorImaginary * denominatorImaginary));
            }
        }
        return response;
    }

    public static double EstimatedPeakDb(IReadOnlyList<double> gainsDb, double sampleRate)
    {
        const int points = 4096;
        var upper = Math.Min(20000, 0.45 * sampleRate);
        var centres = EqualizerBands.CentresHz.Where(centre => centre < sampleRate / 2).ToArray();
        var frequencies = new double[points + centres.Length];
        for (var index = 0; index < points; index++)
            frequencies[index] = 20 * Math.Pow(upper / 20, (double)index / (points - 1));
        Array.Copy(centres, 0, frequencies, points, centres.Length);
        return ResponseDb(gainsDb, sampleRate, frequencies).Max();
    }

    public static double EffectivePreampDb(EqualizerSettings settings, double sampleRate = 48000)
    {
        var preamp = settings.ManualPreampDb;
        if (settings.AutoHeadroom)
        {
            var peak = EstimatedPeakDb(settings.GainsDb, sampleRate);
            preamp = peak > 0 ? -(peak + EqualizerBands.AutoHeadroomMarginDb) : 0;
        }
        return Math.Clamp(preamp, EqualizerBands.MinPreampDb, EqualizerBands.MaxPreampDb);
    }

    public static bool MayClip(EqualizerSettings settings, double sampleRate = 48000)
        => EstimatedPeakDb(settings.GainsDb, sampleRate) + EffectivePreampDb(settings, sampleRate) > 0;
}

internal static class EqualizerSharing
{
    public static string Export(EqualizerPreset preset)
        => JsonSerializer.Serialize(new
        {
            format = "nativune-eq", version = 1, name = preset.Name, gainsDb = preset.GainsDb,
            preampDb = preset.PreampDb, autoHeadroom = preset.AutoHeadroom
        });

    public static bool TryImport(string text, out EqualizerPreset? staged, out string error)
    {
        staged = null;
        error = "The clipboard does not contain a valid Nativune equalizer preset.";
        if (Encoding.UTF8.GetByteCount(text) > EqualizerBands.MaxShareBytes)
        {
            error = "Equalizer presets must be no larger than 2 KiB.";
            return false;
        }
        try
        {
            using var document = JsonDocument.Parse(text);
            var root = document.RootElement;
            if (!HasFields(root, "format", "version", "name", "gainsDb", "preampDb", "autoHeadroom")
                || root.GetProperty("format").ValueKind != JsonValueKind.String
                || root.GetProperty("format").GetString() != "nativune-eq"
                || !root.GetProperty("version").TryGetInt32(out var version) || version != 1
                || !TryReadPreset(root, "unsaved", out staged))
                return false;
            error = string.Empty;
            return true;
        }
        catch (Exception ex) when (ex is JsonException or InvalidOperationException or FormatException)
        {
            return false;
        }
    }

    internal static bool HasFields(JsonElement element, params string[] fields)
    {
        if (element.ValueKind != JsonValueKind.Object)
            return false;
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
            if (!fields.Contains(property.Name, StringComparer.Ordinal) || !seen.Add(property.Name))
                return false;
        return seen.Count == fields.Length;
    }

    internal static bool TryReadNumber(JsonElement element, double minimum, double maximum, out double value)
    {
        value = 0;
        if (element.ValueKind != JsonValueKind.Number || !element.TryGetDouble(out value)
            || !double.IsFinite(value) || value < minimum || value > maximum)
            return false;
        value = Math.Clamp(Math.Round(value / EqualizerBands.StepDb, MidpointRounding.AwayFromZero)
            * EqualizerBands.StepDb, minimum, maximum);
        return true;
    }

    internal static bool TryReadGains(JsonElement element, out IReadOnlyList<double> gains)
    {
        gains = Array.Empty<double>();
        if (element.ValueKind != JsonValueKind.Array || element.GetArrayLength() != EqualizerBands.Count)
            return false;
        var result = new double[EqualizerBands.Count];
        var index = 0;
        foreach (var item in element.EnumerateArray())
            if (!TryReadNumber(item, EqualizerBands.MinGainDb, EqualizerBands.MaxGainDb, out result[index++]))
                return false;
        gains = Array.AsReadOnly(result);
        return true;
    }

    internal static bool TryReadPreset(JsonElement root, string id, out EqualizerPreset? preset)
    {
        preset = null;
        if (root.GetProperty("name").ValueKind != JsonValueKind.String
            || !EqualizerPresets.TryValidateName(root.GetProperty("name").GetString()!, out var name, out _)
            || !TryReadGains(root.GetProperty("gainsDb"), out var gains)
            || !TryReadNumber(root.GetProperty("preampDb"), EqualizerBands.MinPreampDb, EqualizerBands.MaxPreampDb, out var preamp)
            || root.GetProperty("autoHeadroom").ValueKind is not (JsonValueKind.True or JsonValueKind.False))
            return false;
        preset = new(id, name, gains, preamp, root.GetProperty("autoHeadroom").GetBoolean(), false);
        return true;
    }

    internal static bool TryReadSettings(JsonElement root, out EqualizerSettings settings)
    {
        settings = EqualizerSettings.Default;
        if (!HasFields(root, "enabled", "selectedPresetId", "gainsDb", "manualPreampDb", "autoHeadroom", "customPresets")
            || root.GetProperty("enabled").ValueKind is not (JsonValueKind.True or JsonValueKind.False)
            || root.GetProperty("autoHeadroom").ValueKind is not (JsonValueKind.True or JsonValueKind.False)
            || root.GetProperty("selectedPresetId").ValueKind is not (JsonValueKind.String or JsonValueKind.Null)
            || !TryReadGains(root.GetProperty("gainsDb"), out var gains)
            || !TryReadNumber(root.GetProperty("manualPreampDb"), EqualizerBands.MinPreampDb, EqualizerBands.MaxPreampDb, out var preamp))
            return false;
        var custom = root.GetProperty("customPresets");
        if (custom.ValueKind != JsonValueKind.Array || custom.GetArrayLength() > EqualizerBands.MaxCustomPresets)
            return false;
        var ids = new HashSet<string>(StringComparer.Ordinal);
        var names = new HashSet<string>(EqualizerPresets.BuiltIns.Select(preset => preset.Name), StringComparer.OrdinalIgnoreCase);
        var presets = new List<EqualizerPreset>();
        foreach (var item in custom.EnumerateArray())
        {
            if (!HasFields(item, "id", "name", "gainsDb", "preampDb", "autoHeadroom")
                || item.GetProperty("id").ValueKind != JsonValueKind.String)
                return false;
            var id = item.GetProperty("id").GetString()!;
            if (!EqualizerPresets.IsCustomId(id) || !ids.Add(id) || !TryReadPreset(item, id, out var preset)
                || !names.Add(preset!.Name))
                return false;
            presets.Add(preset!);
        }
        var selected = root.GetProperty("selectedPresetId").GetString();
        if (!string.IsNullOrEmpty(selected) && !ids.Contains(selected)
            && !EqualizerPresets.BuiltIns.Any(preset => preset.Id == selected))
            return false;
        settings = new(root.GetProperty("enabled").GetBoolean(), selected, gains, preamp,
            root.GetProperty("autoHeadroom").GetBoolean(), presets.AsReadOnly());
        if (!settings.Enabled && settings.SelectedPresetId == "flat" && settings.GainsDb.All(gain => gain == 0)
            && settings.ManualPreampDb == 0 && settings.AutoHeadroom && presets.Count == 0)
            settings = EqualizerSettings.Default;
        return true;
    }

    internal static JsonElement WriteSettings(EqualizerSettings settings)
        => JsonSerializer.SerializeToElement(new
        {
            enabled = settings.Enabled, selectedPresetId = settings.SelectedPresetId, gainsDb = settings.GainsDb,
            manualPreampDb = settings.ManualPreampDb, autoHeadroom = settings.AutoHeadroom,
            customPresets = settings.CustomPresets.Select(preset => new
            {
                id = preset.Id, name = preset.Name, gainsDb = preset.GainsDb,
                preampDb = preset.PreampDb, autoHeadroom = preset.AutoHeadroom
            })
        });
}

internal sealed record EqualizerApply(bool Enabled, double[] GainsDb, double PreampDb, bool Bypass)
{
    public static EqualizerApply From(EqualizerSettings settings, bool bypass, double sampleRate = 48000)
        => new(settings.Enabled, settings.GainsDb.ToArray(), EqualizerMath.EffectivePreampDb(settings, sampleRate), bypass);
}
