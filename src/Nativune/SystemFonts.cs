using System.Runtime.InteropServices;

namespace Nativune;

/// <summary>
/// System font questions answered by DirectWrite through owned COM interop over <c>dwrite.dll</c> (plan §4.2; no new
/// dependency). P0 needs one: is this family name installed? <c>Enumerate</c> arrives with the designer (P2) and will
/// extend the same interface declarations.
/// </summary>
internal static class SystemFonts
{
    private const int FactoryTypeShared = 0;
    private static readonly Guid FactoryId = new("b859ee5a-d838-4b5b-a2e8-1adc7d93db48");

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
#endif

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

    // IDWriteFontCollection in dwrite.h order: GetFontFamilyCount, GetFontFamily, FindFamilyName. The first two only
    // keep FindFamilyName at its vtable position (GetFontFamily's IDWriteFontFamily** is a raw pointer nobody reads).
    [ComImport]
    [Guid("a84cee02-3eea-4eee-a827-87c1a02a0fcc")]
    [InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IDWriteFontCollection
    {
        [PreserveSig]
        uint GetFontFamilyCount();

        [PreserveSig]
        int GetFontFamily(uint index, out nint fontFamily);

        [PreserveSig]
        int FindFamilyName(
            [MarshalAs(UnmanagedType.LPWStr)] string familyName,
            out uint index,
            [MarshalAs(UnmanagedType.Bool)] out bool exists);
    }
}
