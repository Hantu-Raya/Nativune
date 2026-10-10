using System.Diagnostics.CodeAnalysis;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Nativune;

// OBS overlay designer, P0 domain model (plan v5 §§3.1-3.2, 4.1-4.4, 9): the look options with their defaults and
// capability table, the one normaliser every layer shares (file load, Save, publication), the box/source formulas,
// the `look` stream event and the id helpers. Everything here is pure and thread-safe; the file store is in
// ObsLookStore.cs and the font probe in SystemFonts.cs.

internal enum ObsLookTheme { Pill, Matte, MatteLight, Standard, Classic, Simple, AlbumArt, Card }

internal enum ObsLookAlign { Left, Center, Right }

internal enum ObsLookColours { Auto, Custom }

internal enum ObsLookPaused { Hide, Dim }

internal enum ObsLookAnimation { Fade, SlideUp, SlideDown, SlideLeft, SlideRight, None }

// The 18 option names of §4.1; drives the capability table (which control applies to which theme).
internal enum ObsLookOption
{
    Theme, Font, Scale, Width, Align, Colours, Text, Background, BackgroundOpacity, Accent,
    TextShadow, ShowArt, ShowArtist, ShowProgress, ShowTimes, Paused, ShowAnimation, HideAnimation
}

/// <summary>
/// Wire/store spellings of the option enums: lower case, exact match. Anything else is unknown and normalises to
/// the default. Callers of <c>TryParse</c> must declare a typed out variable (the overloads differ only by it).
/// </summary>
internal static class ObsLookWire
{
    internal static string ToWire(this ObsLookTheme value) => value switch
    {
        ObsLookTheme.Matte => "matte",
        ObsLookTheme.MatteLight => "matte-light",
        ObsLookTheme.Standard => "standard",
        ObsLookTheme.Classic => "classic",
        ObsLookTheme.Simple => "simple",
        ObsLookTheme.AlbumArt => "album-art",
        ObsLookTheme.Card => "card",
        _ => "pill",
    };

    internal static string ToWire(this ObsLookAlign value) => value switch
    {
        ObsLookAlign.Center => "center",
        ObsLookAlign.Right => "right",
        _ => "left",
    };

    internal static string ToWire(this ObsLookColours value) => value == ObsLookColours.Custom ? "custom" : "auto";

    internal static string ToWire(this ObsLookPaused value) => value == ObsLookPaused.Dim ? "dim" : "hide";

    internal static string ToWire(this ObsLookAnimation value) => value switch
    {
        ObsLookAnimation.SlideUp => "slide-up",
        ObsLookAnimation.SlideDown => "slide-down",
        ObsLookAnimation.SlideLeft => "slide-left",
        ObsLookAnimation.SlideRight => "slide-right",
        ObsLookAnimation.None => "none",
        _ => "fade",
    };

    internal static bool TryParse(string? value, out ObsLookTheme result)
    {
        switch (value)
        {
            case "pill": result = ObsLookTheme.Pill; return true;
            case "matte": result = ObsLookTheme.Matte; return true;
            case "matte-light": result = ObsLookTheme.MatteLight; return true;
            case "standard": result = ObsLookTheme.Standard; return true;
            case "classic": result = ObsLookTheme.Classic; return true;
            case "simple": result = ObsLookTheme.Simple; return true;
            case "album-art": result = ObsLookTheme.AlbumArt; return true;
            case "card": result = ObsLookTheme.Card; return true;
            default: result = ObsLookTheme.Pill; return false;
        }
    }

    internal static bool TryParse(string? value, out ObsLookAlign result)
    {
        switch (value)
        {
            case "left": result = ObsLookAlign.Left; return true;
            case "center": result = ObsLookAlign.Center; return true;
            case "right": result = ObsLookAlign.Right; return true;
            default: result = ObsLookAlign.Left; return false;
        }
    }

    internal static bool TryParse(string? value, out ObsLookColours result)
    {
        switch (value)
        {
            case "auto": result = ObsLookColours.Auto; return true;
            case "custom": result = ObsLookColours.Custom; return true;
            default: result = ObsLookColours.Auto; return false;
        }
    }

    internal static bool TryParse(string? value, out ObsLookPaused result)
    {
        switch (value)
        {
            case "hide": result = ObsLookPaused.Hide; return true;
            case "dim": result = ObsLookPaused.Dim; return true;
            default: result = ObsLookPaused.Hide; return false;
        }
    }

    internal static bool TryParse(string? value, out ObsLookAnimation result)
    {
        switch (value)
        {
            case "fade": result = ObsLookAnimation.Fade; return true;
            case "slide-up": result = ObsLookAnimation.SlideUp; return true;
            case "slide-down": result = ObsLookAnimation.SlideDown; return true;
            case "slide-left": result = ObsLookAnimation.SlideLeft; return true;
            case "slide-right": result = ObsLookAnimation.SlideRight; return true;
            case "none": result = ObsLookAnimation.None; return true;
            default: result = ObsLookAnimation.Fade; return false;
        }
    }
}

/// <summary>
/// One look's presentation options (§4.1). Colours are always stored (lower-case <c>#rrggbb</c>) even when
/// <see cref="Colours"/> is auto; inapplicable options are retained, not cleared. Run
/// <see cref="ObsLookValidation.Normalize(ObsLookOptions)"/> after building or editing one.
/// </summary>
internal sealed record ObsLookOptions(
    ObsLookTheme Theme,
    string? Font,
    int Scale,
    int Width,
    ObsLookAlign Align,
    ObsLookColours Colours,
    string Text,
    string Background,
    int BackgroundOpacity,
    string Accent,
    bool TextShadow,
    bool ShowArt,
    bool ShowArtist,
    bool ShowProgress,
    bool ShowTimes,
    ObsLookPaused Paused,
    ObsLookAnimation ShowAnimation,
    ObsLookAnimation HideAnimation)
{
    /// <summary>Song-art background blur in logical pixels (0-32); null uses the theme default.</summary>
    public int? BackgroundBlur { get; init; }

    /// <summary>Played-progress brightness in percent (0-200, step 5); null uses the theme default.</summary>
    public int? PlayedBrightness { get; init; }

    /// <summary>Unplayed-progress brightness in percent (0-100, step 5); null uses the theme default.</summary>
    public int? UnplayedBrightness { get; init; }

    /// <summary>Song-art background brightness in percent (0-200, step 5); null uses the theme default.</summary>
    public int? BackgroundBrightness { get; init; }

    internal const int MinScale = 50;
    internal const int MaxScale = 200;
    internal const int ScaleStep = 5;
    internal const int DefaultScale = 100;
    internal const int WidthStep = 10;
    internal const string DefaultAccent = "#8a8a95";

    /// <summary>
    /// Saved-look defaults (§4.1, §13 O1 option b: text shadow everywhere except matte and matte-light; O2 option a:
    /// show slide-up, hide fade) at scale 100 with the theme's effective default width. Pill and simple do not use a
    /// background, so they store the pill base <c>#202020</c> at 100 %.
    /// </summary>
    internal static ObsLookOptions Defaults(ObsLookTheme theme = ObsLookTheme.Pill)
    {
        if (!Enum.IsDefined(theme)) theme = ObsLookTheme.Pill;
        return new ObsLookOptions(
            theme,
            null,
            DefaultScale,
            ObsLookValidation.DefaultWidth(theme, DefaultScale),
            DefaultAlign(theme),
            ObsLookColours.Auto,
            DefaultText(theme),
            DefaultBackground(theme),
            DefaultBackgroundOpacity(theme),
            DefaultAccent,
            DefaultTextShadow(theme),
            true,
            true,
            true,
            true,
            ObsLookPaused.Hide,
            ObsLookAnimation.SlideUp,
            ObsLookAnimation.Fade);
    }

    /// <summary>
    /// The compatibility preset (§3.1) sent to the plain link and to every missing-fallback stream: the pill defaults
    /// with <c>paused</c> following the global hide-when-paused setting. The saved Pill's defaults differ from it in
    /// nothing but that pause rule.
    /// </summary>
    internal static ObsLookOptions Preset(bool hidePaused) =>
        Defaults(ObsLookTheme.Pill) with { Paused = hidePaused ? ObsLookPaused.Hide : ObsLookPaused.Dim };

    internal static bool Applies(ObsLookTheme theme, ObsLookOption option) => option switch
    {
        ObsLookOption.Background or ObsLookOption.BackgroundOpacity => theme is not (ObsLookTheme.Pill or ObsLookTheme.Simple),
        ObsLookOption.Accent or ObsLookOption.ShowArt => theme != ObsLookTheme.Pill,
        ObsLookOption.ShowTimes => theme is not (ObsLookTheme.Pill or ObsLookTheme.AlbumArt),
        _ => true,
    };

    internal static ObsLookAlign DefaultAlign(ObsLookTheme theme) =>
        theme == ObsLookTheme.Pill ? ObsLookAlign.Center : ObsLookAlign.Left;

    internal static string DefaultText(ObsLookTheme theme) => theme == ObsLookTheme.MatteLight ? "#141414" : "#ffffff";

    internal static string DefaultBackground(ObsLookTheme theme) => theme switch
    {
        ObsLookTheme.Matte => "#1c1c1e",
        ObsLookTheme.MatteLight => "#f5f5f7",
        ObsLookTheme.Standard or ObsLookTheme.Classic or ObsLookTheme.Card => "#1a1a1a",
        ObsLookTheme.AlbumArt => "#000000",
        _ => "#202020",
    };

    internal static int DefaultBackgroundOpacity(ObsLookTheme theme) => theme switch
    {
        ObsLookTheme.AlbumArt => 80,
        ObsLookTheme.Matte or ObsLookTheme.MatteLight or ObsLookTheme.Standard
            or ObsLookTheme.Classic or ObsLookTheme.Card => 94,
        _ => 100,
    };

    internal static bool DefaultTextShadow(ObsLookTheme theme) =>
        theme is not (ObsLookTheme.Matte or ObsLookTheme.MatteLight);
}

/// <summary>Theme effect defaults: logical-pixel blur and played, unplayed and background brightness percentages.</summary>
internal readonly record struct ObsLookFxDefaults(int Blur, int Played, int Unplayed, int Background)
{
    /// <summary>Returns the theme defaults used for null overrides; unknown themes use Pill defaults.</summary>
    internal static ObsLookFxDefaults Resolve(ObsLookTheme theme) => theme switch
    {
        ObsLookTheme.Matte => new(0, 100, 100, 100),
        ObsLookTheme.MatteLight or ObsLookTheme.Simple => new(0, 100, 0, 100),
        ObsLookTheme.Standard or ObsLookTheme.Classic => new(14, 100, 100, 40),
        ObsLookTheme.AlbumArt => new(0, 100, 100, 100),
        ObsLookTheme.Card => new(16, 100, 100, 35),
        _ => new(14, 115, 45, 100),
    };

    /// <summary>Whether the theme supports song-art blur and brightness; progress brightness is supported by all themes.</summary>
    internal static bool SupportsBackgroundFx(ObsLookTheme theme) =>
        theme is ObsLookTheme.Pill or ObsLookTheme.Standard or ObsLookTheme.Classic or ObsLookTheme.AlbumArt or ObsLookTheme.Card;

    /// <summary>Whether background effects currently apply; inactive overrides are retained for later mode changes.</summary>
    internal static bool BackgroundFxActive(ObsLookOptions options) => options.Theme switch
    {
        ObsLookTheme.Pill => true,
        ObsLookTheme.Standard or ObsLookTheme.Classic or ObsLookTheme.Card => options.Colours != ObsLookColours.Custom,
        ObsLookTheme.AlbumArt => options.ShowArt,
        _ => false,
    };
}

/// <summary>A saved look: id (<c>[a-z0-9]{8}</c>), display name (native text only, never on the wire) and options.</summary>
internal sealed record ObsLook(string Id, string Name, ObsLookOptions Options);

/// <summary>
/// The looks file as loaded (§2.7). <see cref="ReadOnlyReason"/> is non-null for every state that blocks writes:
/// whole-file failures (no looks), a newer file version (looks served, normalised as v1) and quarantine
/// (<see cref="Quarantined"/> valid looks beyond <see cref="MaxLooks"/> were left in the file and are served as
/// missing). Instances are immutable; mutation helpers return copies. <see cref="Retired"/> holds the ids of deleted
/// looks, which are never reused.
/// </summary>
internal sealed record ObsLookState(
    IReadOnlyList<ObsLook> Looks,
    IReadOnlyList<string> Retired,
    string? ReadOnlyReason,
    int Quarantined)
{
    internal const int MaxLooks = 16;

    internal static ObsLookState Empty { get; } = new([], [], null, 0);

    internal bool IsReadOnly => ReadOnlyReason is not null;

    internal ObsLook? Find(string id)
    {
        foreach (var look in Looks)
            if (look.Id == id) return look;
        return null;
    }

    internal bool IsRetired(string id)
    {
        foreach (var retired in Retired)
            if (retired == id) return true;
        return false;
    }

    /// <summary>
    /// Replaces the look with the same id (keeping its position) or appends a new one, storing its name trimmed
    /// (when valid) and its options normalised. The caller enforces <see cref="MaxLooks"/> and id allocation
    /// (<see cref="ObsLookIds.New(ObsLookState)"/>).
    /// </summary>
    internal ObsLookState WithLook(ObsLook look)
    {
        var name = ObsLookValidation.TryNormalizeName(look.Name, out var trimmed) ? trimmed : look.Name;
        var stored = look with { Name = name, Options = ObsLookValidation.Normalize(look.Options) };
        var next = new List<ObsLook>(Looks.Count + 1);
        var replaced = false;
        foreach (var existing in Looks)
        {
            if (existing.Id == stored.Id)
            {
                next.Add(stored);
                replaced = true;
            }
            else
            {
                next.Add(existing);
            }
        }
        if (!replaced) next.Add(stored);
        return this with { Looks = next.ToArray() };
    }

    /// <summary>Removes the look and tombstones its id in <see cref="Retired"/> (unchanged when the id is unknown).</summary>
    internal ObsLookState Without(string id)
    {
        if (Find(id) is null) return this;
        var kept = new List<ObsLook>(Looks.Count);
        foreach (var look in Looks)
            if (look.Id != id) kept.Add(look);
        IReadOnlyList<string> retired = IsRetired(id) ? Retired : [.. Retired, id];
        return this with { Looks = kept.ToArray(), Retired = retired };
    }
}

// Server construction options (§2.5). Looks must not be null.
internal readonly record struct ObsOverlayOptions(bool HidePaused, bool ReduceMotion, ObsLookState Looks);

/// <summary>
/// Validation and normalisation (§4.3-4.4), applied identically on load, Save and publication. Order: theme, scale,
/// derive the width range, width, then the independent fields. A missing, wrong-type, non-finite or out-of-range
/// value becomes its default (width: the effective default <c>snap(clamp(themeDefault, min, max))</c>); an in-range
/// off-step number snaps to the nearest step (ties up). The result is idempotent.
/// </summary>
internal static class ObsLookValidation
{
    internal const int MaxNameUnits = 40;
    internal const int MaxFontUnits = 64;
    internal const int IdLength = 8;

    // Base width range and theme default width (§3.2, §4.1). Horizontal = matte, matte-light, standard, classic, simple.
    private static (int Min, int Max, int Default) BaseWidths(ObsLookTheme theme) => theme switch
    {
        ObsLookTheme.Pill => (320, 800, 400),
        ObsLookTheme.AlbumArt => (160, 600, 200),
        ObsLookTheme.Card => (200, 600, 280),
        _ => (360, 1200, 440),
    };

    /// <summary>
    /// Dependent width range: <c>min = ceil10(baseMin * max(k, 1))</c> (never below the base, rising with the scale),
    /// <c>max</c> = the base maximum. Computed in integers; <paramref name="scale"/> is clamped to 50-200 first.
    /// </summary>
    internal static (int Min, int Max) WidthRange(ObsLookTheme theme, int scale)
    {
        var (baseMin, max, _) = BaseWidths(theme);
        scale = Math.Clamp(scale, ObsLookOptions.MinScale, ObsLookOptions.MaxScale);
        var scaled = checked(baseMin * Math.Max(scale, 100)); // baseMin * max(k, 1) * 100
        return ((scaled + 999) / 1000 * 10, max);
    }

    /// <summary>Effective default width: <c>snap(clamp(themeDefault, min, max))</c> for the scale.</summary>
    internal static int DefaultWidth(ObsLookTheme theme, int scale)
    {
        var (min, max) = WidthRange(theme, scale);
        var (_, _, themeDefault) = BaseWidths(theme);
        return Snap(Math.Clamp(themeDefault, min, max), ObsLookOptions.WidthStep);
    }

    /// <summary>Normalises typed options (designer edits, publication, Save). Never throws for out-of-domain values.</summary>
    internal static ObsLookOptions Normalize(ObsLookOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        return Apply(new Raw
        {
            Theme = Defined(options.Theme),
            Font = options.Font,
            Scale = options.Scale,
            Width = options.Width,
            Align = Defined(options.Align),
            Colours = Defined(options.Colours),
            Text = options.Text,
            Background = options.Background,
            BackgroundOpacity = options.BackgroundOpacity,
            Accent = options.Accent,
            TextShadow = options.TextShadow,
            ShowArt = options.ShowArt,
            ShowArtist = options.ShowArtist,
            ShowProgress = options.ShowProgress,
            ShowTimes = options.ShowTimes,
            Paused = Defined(options.Paused),
            ShowAnimation = Defined(options.ShowAnimation),
            HideAnimation = Defined(options.HideAnimation),
            BackgroundBlur = options.BackgroundBlur,
            PlayedBrightness = options.PlayedBrightness,
            UnplayedBrightness = options.UnplayedBrightness,
            BackgroundBrightness = options.BackgroundBrightness,
        });
    }

    /// <summary>
    /// Normalises an untyped JSON <c>options</c> object (file records, hook payloads): known fields only, unknown
    /// fields ignored, wrong types and unknown enum spellings (including wrong case) become defaults. A missing or
    /// non-object value yields all defaults.
    /// </summary>
    internal static ObsLookOptions Normalize(JsonElement options)
    {
        var raw = new Raw();
        if (options.ValueKind == JsonValueKind.Object)
        {
            raw.Theme = ParseTheme(ReadString(options, "theme"));
            raw.Font = ReadString(options, "font");
            raw.Scale = ReadNumber(options, "scale");
            raw.Width = ReadNumber(options, "width");
            raw.Align = ParseAlign(ReadString(options, "align"));
            raw.Colours = ParseColours(ReadString(options, "colours"));
            raw.Text = ReadString(options, "text");
            raw.Background = ReadString(options, "background");
            raw.BackgroundOpacity = ReadNumber(options, "backgroundOpacity");
            raw.Accent = ReadString(options, "accent");
            raw.TextShadow = ReadBool(options, "textShadow");
            raw.ShowArt = ReadBool(options, "showArt");
            raw.ShowArtist = ReadBool(options, "showArtist");
            raw.ShowProgress = ReadBool(options, "showProgress");
            raw.ShowTimes = ReadBool(options, "showTimes");
            raw.Paused = ParsePaused(ReadString(options, "paused"));
            raw.ShowAnimation = ParseAnimation(ReadString(options, "showAnimation"));
            raw.HideAnimation = ParseAnimation(ReadString(options, "hideAnimation"));
            raw.BackgroundBlur = ReadNumber(options, "backgroundBlur");
            raw.PlayedBrightness = ReadNumber(options, "playedBrightness");
            raw.UnplayedBrightness = ReadNumber(options, "unplayedBrightness");
            raw.BackgroundBrightness = ReadNumber(options, "backgroundBrightness");
        }
        return Apply(raw);
    }

    /// <summary>
    /// Reads one file/hook record <c>{ id, name, options }</c>. Fails (record skipped) for a non-object, an invalid
    /// id or an invalid name; missing or malformed options fall back to defaults.
    /// </summary>
    internal static bool TryReadLook(JsonElement record, [NotNullWhen(true)] out ObsLook? look, out string reason)
    {
        look = null;
        if (record.ValueKind != JsonValueKind.Object)
        {
            reason = "not an object";
            return false;
        }
        var id = ReadString(record, "id");
        if (!IsValidId(id))
        {
            reason = "invalid id";
            return false;
        }
        if (!TryNormalizeName(ReadString(record, "name"), out var name))
        {
            reason = "invalid name";
            return false;
        }
        var options = record.TryGetProperty("options", out var raw) ? Normalize(raw) : ObsLookOptions.Defaults();
        look = new ObsLook(id, name, options);
        reason = "";
        return true;
    }

    /// <summary>The literal id of the designer's draft stream (§2.1); it is not a saved-look id and fails <see cref="IsValidId"/>.</summary>
    internal const string DraftId = "draft";

    /// <summary>
    /// Reads a draft look record <c>{ name, options }</c> (hook payloads, the designer): the id is always
    /// <see cref="DraftId"/>, the name is trimmed (empty when invalid) and the options are normalised, so a draft never
    /// carries anything a saved look could not.
    /// </summary>
    internal static ObsLook ReadDraft(JsonElement record)
    {
        var name = TryNormalizeName(ReadString(record, "name"), out var trimmed) ? trimmed : "";
        var options = record.ValueKind == JsonValueKind.Object && record.TryGetProperty("options", out var raw)
            ? Normalize(raw)
            : ObsLookOptions.Defaults();
        return new ObsLook(DraftId, name, options);
    }

    /// <summary><c>[a-z0-9]{8}</c>.</summary>
    internal static bool IsValidId([NotNullWhen(true)] string? id)
    {
        if (id is not { Length: IdLength }) return false;
        foreach (var c in id)
            if (!(c is >= 'a' and <= 'z' or >= '0' and <= '9')) return false;
        return true;
    }

    /// <summary>
    /// Trims <paramref name="name"/> and checks it (§4.1): at most 40 UTF-16 units, no control (U+0000-001F,
    /// U+007F-009F), line/paragraph separator (U+2028/2029) or bidi-format (U+200E/F, U+202A-E, U+2066-9) character,
    /// no unpaired surrogate (the store could not serialise one), and at least one character after trimming. Drafts
    /// fall back to an empty name when this fails.
    /// </summary>
    internal static bool TryNormalizeName(string? name, out string trimmed)
    {
        trimmed = "";
        if (name is null) return false;
        var value = name.Trim();
        if (value.Length == 0 || value.Length > MaxNameUnits || !IsWellFormed(value)) return false;
        foreach (var c in value)
        {
            if (IsControl(c)
                || c is '\u2028' or '\u2029' or '\u200e' or '\u200f'
                || c is >= '\u202a' and <= '\u202e'
                || c is >= '\u2066' and <= '\u2069')
                return false;
        }
        trimmed = value;
        return true;
    }

    /// <summary>A font family value (§4.1): 1-64 UTF-16 units, no control character, not blank, no unpaired surrogate.</summary>
    internal static bool IsValidFont([NotNullWhen(true)] string? font)
    {
        if (font is null || font.Length is 0 or > MaxFontUnits || string.IsNullOrWhiteSpace(font)) return false;
        foreach (var c in font)
            if (IsControl(c)) return false;
        return IsWellFormed(font);
    }

    /// <summary>The font when valid, else null (§4.4). Whether it is installed is <see cref="SystemFonts.IsInstalled"/>'s question.</summary>
    internal static string? NormalizeFont(string? font) => IsValidFont(font) ? font : null;

    /// <summary><c>^#[0-9a-fA-F]{6}$</c> to lower case, else null.</summary>
    internal static string? NormalizeColour(string? value)
    {
        if (value is not { Length: 7 } || value[0] != '#') return null;
        for (var i = 1; i < 7; i++)
            if (!char.IsAsciiHexDigit(value[i])) return null;
        return value.ToLowerInvariant();
    }

    /// <summary>Preview backdrop: <c>checker</c>, <c>dark</c>, <c>light</c> or a <c>#rrggbb</c> colour; anything else is <c>checker</c>.</summary>
    internal static string NormalizeBackdrop(string? backdrop)
    {
        switch (backdrop)
        {
            case "dark": return "dark";
            case "light": return "light";
            default: return NormalizeColour(backdrop) ?? "checker";
        }
    }

    // JSON readers that never throw: wrong type or an undecodable string is "missing".
    internal static string? ReadString(JsonElement container, string name) =>
        container.ValueKind == JsonValueKind.Object && container.TryGetProperty(name, out var value) ? AsString(value) : null;

    internal static string? AsString(JsonElement value)
    {
        if (value.ValueKind != JsonValueKind.String) return null;
        try
        {
            return value.GetString();
        }
        catch (InvalidOperationException)
        {
            return null; // e.g. a lone \ud800 escape
        }
    }

    private static double? ReadNumber(JsonElement container, string name)
    {
        if (!container.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Number) return null;
        return value.TryGetDouble(out var number) && double.IsFinite(number) ? (double?)number : null;
    }

    private static bool? ReadBool(JsonElement container, string name)
    {
        if (!container.TryGetProperty(name, out var value)) return null;
        return value.ValueKind switch
        {
            JsonValueKind.True => (bool?)true,
            JsonValueKind.False => (bool?)false,
            _ => null,
        };
    }

    private static ObsLookTheme? ParseTheme(string? value) =>
        ObsLookWire.TryParse(value, out ObsLookTheme parsed) ? (ObsLookTheme?)parsed : null;

    private static ObsLookAlign? ParseAlign(string? value) =>
        ObsLookWire.TryParse(value, out ObsLookAlign parsed) ? (ObsLookAlign?)parsed : null;

    private static ObsLookColours? ParseColours(string? value) =>
        ObsLookWire.TryParse(value, out ObsLookColours parsed) ? (ObsLookColours?)parsed : null;

    private static ObsLookPaused? ParsePaused(string? value) =>
        ObsLookWire.TryParse(value, out ObsLookPaused parsed) ? (ObsLookPaused?)parsed : null;

    private static ObsLookAnimation? ParseAnimation(string? value) =>
        ObsLookWire.TryParse(value, out ObsLookAnimation parsed) ? (ObsLookAnimation?)parsed : null;

    private static T? Defined<T>(T value) where T : struct, Enum => Enum.IsDefined(value) ? (T?)value : null;

    // Raw option values before validation; null = missing or wrong type. Typed and JSON input share Apply, so the
    // two paths cannot drift apart.
    private struct Raw
    {
        internal ObsLookTheme? Theme;
        internal string? Font;
        internal double? Scale;
        internal double? Width;
        internal ObsLookAlign? Align;
        internal ObsLookColours? Colours;
        internal string? Text;
        internal string? Background;
        internal double? BackgroundOpacity;
        internal string? Accent;
        internal bool? TextShadow;
        internal bool? ShowArt;
        internal bool? ShowArtist;
        internal bool? ShowProgress;
        internal bool? ShowTimes;
        internal ObsLookPaused? Paused;
        internal ObsLookAnimation? ShowAnimation;
        internal ObsLookAnimation? HideAnimation;
        internal double? BackgroundBlur;
        internal double? PlayedBrightness;
        internal double? UnplayedBrightness;
        internal double? BackgroundBrightness;
    }

    private static ObsLookOptions Apply(in Raw raw)
    {
        var theme = raw.Theme ?? ObsLookTheme.Pill;
        var scale = InRange(raw.Scale, ObsLookOptions.MinScale, ObsLookOptions.MaxScale, ObsLookOptions.ScaleStep)
            ?? ObsLookOptions.DefaultScale;
        var (minWidth, maxWidth) = WidthRange(theme, scale);
        var width = InRange(raw.Width, minWidth, maxWidth, ObsLookOptions.WidthStep) ?? DefaultWidth(theme, scale);
        var opacity = InRange(raw.BackgroundOpacity, 0, 100, 1) ?? ObsLookOptions.DefaultBackgroundOpacity(theme);
        return new ObsLookOptions(
            theme,
            NormalizeFont(raw.Font),
            scale,
            width,
            raw.Align ?? ObsLookOptions.DefaultAlign(theme),
            raw.Colours ?? ObsLookColours.Auto,
            NormalizeColour(raw.Text) ?? ObsLookOptions.DefaultText(theme),
            NormalizeColour(raw.Background) ?? ObsLookOptions.DefaultBackground(theme),
            opacity,
            NormalizeColour(raw.Accent) ?? ObsLookOptions.DefaultAccent,
            raw.TextShadow ?? ObsLookOptions.DefaultTextShadow(theme),
            raw.ShowArt ?? true,
            raw.ShowArtist ?? true,
            raw.ShowProgress ?? true,
            raw.ShowTimes ?? true,
            raw.Paused ?? ObsLookPaused.Hide,
            raw.ShowAnimation ?? ObsLookAnimation.SlideUp,
            raw.HideAnimation ?? ObsLookAnimation.Fade)
        {
            BackgroundBlur = InRange(raw.BackgroundBlur, 0, 32, 1),
            PlayedBrightness = InRange(raw.PlayedBrightness, 0, 200, 5),
            UnplayedBrightness = InRange(raw.UnplayedBrightness, 0, 100, 5),
            BackgroundBrightness = InRange(raw.BackgroundBrightness, 0, 200, 5),
        };
    }

    // In [min, max] (bounds are multiples of step, so snapping stays in range) -> snapped; else null = use the default.
    private static int? InRange(double? value, int min, int max, int step)
    {
        if (value is not { } number || !double.IsFinite(number) || number < min || number > max) return null;
        return Snap(number, step);
    }

    private static int Snap(double value, int step) =>
        checked((int)(Math.Round(value / step, MidpointRounding.AwayFromZero) * step));

    private static bool IsControl(char c) => c <= '\u001f' || c is >= '\u007f' and <= '\u009f';

    private static bool IsWellFormed(string value)
    {
        for (var i = 0; i < value.Length; i++)
        {
            var c = value[i];
            if (char.IsHighSurrogate(c))
            {
                if (i + 1 >= value.Length || !char.IsLowSurrogate(value[i + 1])) return false;
                i++;
            }
            else if (char.IsLowSurrogate(c))
            {
                return false;
            }
        }
        return true;
    }
}

/// <summary>
/// The single native box formula (§3.2). Pass normalised options. Boxes are CSS px: the width is a CSS value while
/// every internal metric scales with <c>k = scale / 100</c>, so heights can be fractional. All arithmetic is IEEE
/// double in exactly the written order (<c>k = scale / 100.0</c>, pill height <c>56 * k</c>), which the page and the
/// PowerShell oracle repeat, so results compare bit-for-bit.
/// </summary>
internal static class ObsLookLayout
{
    // CSS px of transparent margin the source keeps on each side of the box.
    internal const int SourceMargin = 20;

    /// <summary>Box size in CSS px: pill 56k; matte/matte-light/standard/classic/simple 80k; album-art = width; card per <c>T</c> rows.</summary>
    internal static (double W, double H) Box(ObsLookOptions options)
    {
        var k = options.Scale / 100.0;
        double width = options.Width;
        var height = options.Theme switch
        {
            ObsLookTheme.Pill => 56 * k,
            ObsLookTheme.AlbumArt => width,
            ObsLookTheme.Card => CardHeight(options, width, k),
            _ => 80 * k,
        };
        return (width, height);
    }

    /// <summary>OBS Browser Source size in pixels: box plus 20 on each side, each dimension rounded up to even.</summary>
    internal static (int W, int H) SourceSize(ObsLookOptions options)
    {
        var (width, height) = Box(options);
        return (RoundUpToEven(width + 2 * SourceMargin), RoundUpToEven(height + 2 * SourceMargin));
    }

    // (showArt ? width - 32k : 0) + 16k + T; T = 96k with times, 72k without, 56k without progress, minus 20k without artist.
    private static double CardHeight(ObsLookOptions options, double width, double k)
    {
        var text = !options.ShowProgress ? 56 * k : options.ShowTimes ? 96 * k : 72 * k;
        if (!options.ShowArtist) text -= 20 * k;
        var cover = options.ShowArt ? width - 32 * k : 0;
        return cover + 16 * k + text;
    }

    private static int RoundUpToEven(double value) => checked((int)(Math.Ceiling(value / 2.0) * 2));
}

/// <summary>
/// Everything one <c>look</c> event carries (§2.3). <paramref name="Id"/> is null for the plain stream and the literal
/// id otherwise (including <c>draft</c>); <paramref name="Sample"/> selects <c>kind: "sample"</c>. The preview object
/// is written only when <paramref name="PreviewBackdrop"/> is set. <paramref name="FontAvailable"/> null means "ask
/// <see cref="SystemFonts.IsInstalled"/> now"; pass a value to reuse one lookup across several streams. Construct
/// with named arguments: the bools are easy to swap.
/// </summary>
internal readonly record struct ObsLookEvent(
    string Epoch,
    long Seq,
    string? Id,
    bool Missing,
    bool Sample,
    ObsLookOptions Options,
    bool ReduceMotion,
    bool HidePaused,
    string? PreviewBackdrop = null,
    bool? FontAvailable = null);

/// <summary>Explicit look serialisation (System.Text.Json writer, default encoder): the wire and store names are fixed here.</summary>
internal static class ObsLookJson
{
    /// <summary>
    /// The JSON payload of a <c>look</c> event, without SSE framing. Options are normalised again first so nothing
    /// unvalidated is ever published; <c>box</c> and <c>source</c> come from <see cref="ObsLookLayout"/>. The display
    /// name never appears on the wire.
    /// </summary>
    internal static string WriteLookEvent(in ObsLookEvent e)
    {
        var options = ObsLookValidation.Normalize(e.Options);
        var (boxWidth, boxHeight) = ObsLookLayout.Box(options);
        var (sourceWidth, sourceHeight) = ObsLookLayout.SourceSize(options);
        var fontAvailable = e.FontAvailable ?? (options.Font is not null && SystemFonts.IsInstalled(options.Font));

        using var buffer = new MemoryStream(1024);
        using (var w = new Utf8JsonWriter(buffer))
        {
            w.WriteStartObject();
            w.WriteNumber("v", 1);
            w.WriteString("epoch", e.Epoch);
            w.WriteNumber("seq", e.Seq);
            if (e.Id is null) w.WriteNull("id");
            else w.WriteString("id", e.Id);
            w.WriteBoolean("missing", e.Missing);
            w.WriteString("kind", e.Sample ? "sample" : "real");
            w.WriteString("theme", options.Theme.ToWire());
            w.WriteStartObject("box");
            w.WriteNumber("w", boxWidth);
            w.WriteNumber("h", boxHeight);
            w.WriteEndObject();
            w.WriteStartObject("source");
            w.WriteNumber("w", sourceWidth);
            w.WriteNumber("h", sourceHeight);
            w.WriteEndObject();
            w.WriteBoolean("reduceMotion", e.ReduceMotion);
            w.WriteBoolean("fontAvailable", fontAvailable);
            w.WriteBoolean("hidePaused", e.HidePaused);
            w.WritePropertyName("options");
            WriteOptions(w, options);
            if (e.PreviewBackdrop is not null)
            {
                w.WriteStartObject("preview");
                w.WriteString("backdrop", ObsLookValidation.NormalizeBackdrop(e.PreviewBackdrop));
                w.WriteEndObject();
            }
            w.WriteEndObject();
        }
        return Encoding.UTF8.GetString(buffer.GetBuffer(), 0, (int)buffer.Length);
    }

    /// <summary>
    /// Flat form of <see cref="WriteLookEvent(in ObsLookEvent)"/> for the stream server: <paramref name="kind"/> is
    /// <c>"sample"</c> or anything else for <c>"real"</c>; <paramref name="fontAvailable"/> is the caller's lookup
    /// result; a null <paramref name="previewBackdrop"/> omits the <c>preview</c> member.
    /// </summary>
    internal static string WriteLookEvent(
        string epoch,
        int seq,
        string? id,
        bool missing,
        string kind,
        ObsLookOptions options,
        bool reduceMotion,
        bool fontAvailable,
        bool hidePaused,
        string? previewBackdrop)
        => WriteLookEvent(new ObsLookEvent(
            Epoch: epoch,
            Seq: seq,
            Id: id,
            Missing: missing,
            Sample: kind == "sample",
            Options: options,
            ReduceMotion: reduceMotion,
            HidePaused: hidePaused,
            PreviewBackdrop: previewBackdrop,
            FontAvailable: fontAvailable));

    /// <summary>Options as a JSON object in the canonical order shared by the look event and the store file.</summary>
    internal static void WriteOptions(Utf8JsonWriter w, ObsLookOptions o)
    {
        w.WriteStartObject();
        w.WriteString("theme", o.Theme.ToWire());
        if (o.Font is null) w.WriteNull("font");
        else w.WriteString("font", o.Font);
        w.WriteNumber("scale", o.Scale);
        w.WriteNumber("width", o.Width);
        w.WriteString("align", o.Align.ToWire());
        w.WriteString("colours", o.Colours.ToWire());
        w.WriteString("text", o.Text);
        w.WriteString("background", o.Background);
        w.WriteNumber("backgroundOpacity", o.BackgroundOpacity);
        w.WriteString("accent", o.Accent);
        w.WriteBoolean("textShadow", o.TextShadow);
        w.WriteBoolean("showArt", o.ShowArt);
        w.WriteBoolean("showArtist", o.ShowArtist);
        w.WriteBoolean("showProgress", o.ShowProgress);
        w.WriteBoolean("showTimes", o.ShowTimes);
        w.WriteString("paused", o.Paused.ToWire());
        w.WriteString("showAnimation", o.ShowAnimation.ToWire());
        w.WriteString("hideAnimation", o.HideAnimation.ToWire());
        if (o.BackgroundBlur is { } blur) w.WriteNumber("backgroundBlur", blur);
        else w.WriteNull("backgroundBlur");
        if (o.PlayedBrightness is { } played) w.WriteNumber("playedBrightness", played);
        else w.WriteNull("playedBrightness");
        if (o.UnplayedBrightness is { } unplayed) w.WriteNumber("unplayedBrightness", unplayed);
        else w.WriteNull("unplayedBrightness");
        if (o.BackgroundBrightness is { } background) w.WriteNumber("backgroundBrightness", background);
        else w.WriteNull("backgroundBrightness");
        w.WriteEndObject();
    }
}

/// <summary>Look ids (§2.7), stream epochs and preview nonces: CSPRNG draws, no modulo bias.</summary>
internal static class ObsLookIds
{
    internal const int Attempts = 8;
    private const string Alphabet = "abcdefghijklmnopqrstuvwxyz0123456789";

    /// <summary>
    /// A fresh <c>[a-z0-9]{8}</c> id that is in neither the state's looks nor its retired list, or null after
    /// <see cref="Attempts"/> collisions (the mutation then fails).
    /// </summary>
    internal static string? New(ObsLookState state) => Pick(state, null);

    internal static bool IsValid([NotNullWhen(true)] string? id) => ObsLookValidation.IsValidId(id);

    /// <summary>Eight lower-case hex digits: the per-server-instance <c>epoch</c> of the look event.</summary>
    internal static string NewEpoch() => Convert.ToHexStringLower(RandomNumberGenerator.GetBytes(4));

#if NATIVUNE_DISCORD_TEST_HOOKS
    /// <summary>
    /// Test seam for the forced retired-id collision: <paramref name="testCandidates"/> are tried in order before any
    /// random draw. Each candidate still has to pass the id grammar and the looks-union-retired rule, and every
    /// candidate or draw counts toward the <see cref="Attempts"/> limit.
    /// </summary>
    internal static string? New(ObsLookState state, IReadOnlyList<string>? testCandidates) => Pick(state, testCandidates);
#endif

    private static string? Pick(ObsLookState state, IReadOnlyList<string>? candidates)
    {
        for (var attempt = 0; attempt < Attempts; attempt++)
        {
            var id = candidates is not null && attempt < candidates.Count ? candidates[attempt] : Draw();
            if (!ObsLookValidation.IsValidId(id)) continue;
            if (state.Find(id) is not null || state.IsRetired(id)) continue;
            return id;
        }
        return null;
    }

    private static string Draw() => RandomNumberGenerator.GetString(Alphabet, ObsLookValidation.IdLength);
}
