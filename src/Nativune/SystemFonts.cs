using System.Globalization;
using System.Runtime.InteropServices;
using System.Text;

namespace Nativune;

/// <summary>System font lookups and enumeration through owned DirectWrite COM interop.</summary>
internal static class SystemFonts
{
    private const int FactoryTypeShared = 0;
    private static readonly Guid FactoryId = new("b859ee5a-d838-4b5b-a2e8-1adc7d93db48");

    internal sealed record FontFamily(string Canonical, string Display, IReadOnlyList<string> Aliases);
    internal sealed record FontEnumerationResult(IReadOnlyList<FontFamily> Families, bool Truncated, bool Failed);

#if NATIVUNE_DISCORD_TEST_HOOKS
    private static string? s_forcedAvailable;

    /// <summary>
    /// Test seam (A-STORE-1.fontEscape, command-obs-font-force-available): <see cref="IsInstalled"/> returns true for
    /// exactly this string, ordinal comparison, and consults nothing else for it. Each assignment replaces the last.
    /// </summary>
    internal static string? HookForceAvailable
    {
        get => Volatile.Read(ref s_forcedAvailable);
        set => Volatile.Write(ref s_forcedAvailable, value);
    }

    private static int s_forcedEnumerationFailure;
    internal static bool HookForceEnumerationFailure
    {
        get => Volatile.Read(ref s_forcedEnumerationFailure) != 0;
        set => Volatile.Write(ref s_forcedEnumerationFailure, value ? 1 : 0);
    }

#endif

    /// <summary>
    /// Enumerate installed families once per designer window. Canonical prefers en-us; Display prefers the UI locale.
    /// A failed DirectWrite call discards partial results so the designer can offer only the saved value and default.
    /// </summary>
    internal static FontEnumerationResult Enumerate()
    {
        var empty = new FontEnumerationResult(Array.Empty<FontFamily>(), false, true);
#if NATIVUNE_DISCORD_TEST_HOOKS
        if (HookForceEnumerationFailure) return empty;
#endif
        IDWriteFactory? factory = null;
        IDWriteFontCollection? collection = null;
        try
        {
            var factoryId = FactoryId;
            if (DWriteCreateFactory(FactoryTypeShared, ref factoryId, out factory) < 0 || factory is null) return empty;
            if (factory.GetSystemFontCollection(out collection, true) < 0 || collection is null) return empty;

            var families = new List<FontFamily>();
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var uiLocale = CultureInfo.CurrentUICulture.Name;
            var truncated = false;
            for (uint i = 0, count = collection.GetFontFamilyCount(); i < count; i++)
            {
                IDWriteFontFamily? family = null;
                IDWriteLocalizedStrings? names = null;
                try
                {
                    Marshal.ThrowExceptionForHR(collection.GetFontFamily(i, out family));
                    if (family is null) throw new COMException("DirectWrite returned no font family.");
                    Marshal.ThrowExceptionForHR(family.GetFamilyNames(out names));
                    if (names is null) throw new COMException("DirectWrite returned no family names.");

                    var aliases = new List<string>();
                    var unique = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
                    for (uint j = 0, n = names.GetCount(); j < n; j++)
                    {
                        var candidate = ReadName(names, j);
                        if (candidate is not null && unique.Add(candidate)) aliases.Add(candidate);
                    }
                    if (aliases.Count == 0) continue;

                    var canonical = LocaleName(names, "en-us", unique) ?? aliases[0];
                    if (!seen.Add(canonical)) continue;
                    if (families.Count == 2000)
                    {
                        truncated = true;
                        break;
                    }
                    var display = LocaleName(names, uiLocale, unique) ?? aliases[0];
                    aliases.RemoveAll(name => string.Equals(name, canonical, StringComparison.OrdinalIgnoreCase));
                    families.Add(new FontFamily(canonical, display, aliases));
                }
                finally
                {
                    Release(names);
                    Release(family);
                }
            }
            families.Sort((a, b) => StringComparer.CurrentCultureIgnoreCase.Compare(a.Display, b.Display));
            return new FontEnumerationResult(families, truncated, false);
        }
        catch (Exception)
        {
            return empty; // COM, DLL, marshalling or locale failure: never mistake a partial list for a complete one.
        }
        finally
        {
            Release(collection);
            Release(factory);
        }
    }

    private static string? LocaleName(IDWriteLocalizedStrings names, string locale, HashSet<string> valid)
    {
        if (string.IsNullOrEmpty(locale)) return null;
        Marshal.ThrowExceptionForHR(names.FindLocaleName(locale, out var index, out var found));
        var value = found ? ReadName(names, index) : null;
        return value is not null && valid.Contains(value) ? value : null;
    }

    private static string? ReadName(IDWriteLocalizedStrings names, uint index)
    {
        Marshal.ThrowExceptionForHR(names.GetStringLength(index, out var length));
        if (length is 0 or > 64) return null;
        var buffer = new StringBuilder(checked((int)length + 1));
        Marshal.ThrowExceptionForHR(names.GetString(index, buffer, length + 1));
        var value = buffer.ToString();
        return ObsLookValidation.IsValidFont(value) ? value : null;
    }

    /// <summary>
    /// One-family DirectWrite lookup (<c>FindFamilyName</c> on the system collection, updates checked): true when a
    /// family with that name, in any locale, is installed. Names that could not be a saved font value (empty, over 64
    /// UTF-16 units, control characters) are never installed. Any DirectWrite or interop failure answers false, so a
    /// look then renders with the fixed fallback stack. The persisted value is never touched.
    /// </summary>
    internal static bool IsInstalled(string? name)
    {
#if NATIVUNE_DISCORD_TEST_HOOKS
        if (name is not null && string.Equals(name, HookForceAvailable, StringComparison.Ordinal)) return true;
#endif
        if (!ObsLookValidation.IsValidFont(name)) return false;

        IDWriteFactory? factory = null;
        IDWriteFontCollection? collection = null;
        try
        {
            var factoryId = FactoryId;
            if (DWriteCreateFactory(FactoryTypeShared, ref factoryId, out factory) < 0 || factory is null) return false;
            if (factory.GetSystemFontCollection(out collection, true) < 0 || collection is null) return false;
            return collection.FindFamilyName(name, out _, out var exists) >= 0 && exists;
        }
        catch (Exception)
        {
            return false; // COMException, DllNotFoundException, EntryPointNotFoundException, marshalling errors
        }
        finally
        {
            Release(collection);
            Release(factory);
        }
    }

    private static void Release(object? instance)
    {
        try
        {
            if (instance is not null && Marshal.IsComObject(instance)) Marshal.ReleaseComObject(instance);
        }
        catch (Exception)
        {
            // Cleanup must not mask the lookup result.
        }
    }

    [DllImport("dwrite.dll", ExactSpelling = true)]
    [DefaultDllImportSearchPaths(DllImportSearchPath.System32)]
    private static extern int DWriteCreateFactory(
        int factoryType,
        [In] ref Guid iid,
        [MarshalAs(UnmanagedType.Interface)] out IDWriteFactory factory);

    // IDWriteFactory: only the first vtable slot after IUnknown is declared; later slots are never called.
    [ComImport]
    [Guid("b859ee5a-d838-4b5b-a2e8-1adc7d93db48")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDWriteFactory
    {
        [PreserveSig]
        int GetSystemFontCollection(
            [MarshalAs(UnmanagedType.Interface)] out IDWriteFontCollection fontCollection,
            [MarshalAs(UnmanagedType.Bool)] bool checkForUpdates);
    }

    // IDWriteFontCollection in dwrite.h order: GetFontFamilyCount, GetFontFamily, FindFamilyName.
    [ComImport]
    [Guid("a84cee02-3eea-4eee-a827-87c1a02a0fcc")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDWriteFontCollection
    {
        [PreserveSig]
        uint GetFontFamilyCount();

        [PreserveSig]
        int GetFontFamily(uint index, [MarshalAs(UnmanagedType.Interface)] out IDWriteFontFamily fontFamily);

        [PreserveSig]
        int FindFamilyName(
            [MarshalAs(UnmanagedType.LPWStr)] string familyName,
            out uint index,
            [MarshalAs(UnmanagedType.Bool)] out bool exists);
    }

    // IDWriteFontFamily inherits IDWriteFontList's three methods before GetFamilyNames.
    [ComImport]
    [Guid("da20d8ef-812a-4c43-9802-62ec4abd7add")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDWriteFontFamily
    {
        [PreserveSig] int GetFontCollection(out nint collection);
        [PreserveSig] uint GetFontCount();
        [PreserveSig] int GetFont(uint index, out nint font);
        [PreserveSig] int GetFamilyNames([MarshalAs(UnmanagedType.Interface)] out IDWriteLocalizedStrings names);
    }

    [ComImport]
    [Guid("08256209-099a-4b34-b86d-c22b110e7771")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDWriteLocalizedStrings
    {
        [PreserveSig] uint GetCount();
        [PreserveSig] int FindLocaleName([MarshalAs(UnmanagedType.LPWStr)] string locale,
            out uint index, [MarshalAs(UnmanagedType.Bool)] out bool exists);
        [PreserveSig] int GetLocaleNameLength(uint index, out uint length);
        [PreserveSig] int GetLocaleName(uint index, [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder locale, uint size);
        [PreserveSig] int GetStringLength(uint index, out uint length);
        [PreserveSig] int GetString(uint index, [Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder value, uint size);
    }
}
