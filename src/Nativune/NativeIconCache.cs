using System.Collections.Generic;
using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Buffers.Binary;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml;

namespace Nativune;

/// <summary>
/// Bounded source-resource cache for the original native raster icon family.
/// </summary>
/// <remarks>
/// WinUI icons are created as a fresh <see cref="BitmapIcon"/> on every call so
/// no <see cref="Microsoft.UI.Xaml.DependencyObject"/> is ever attached to two
/// parents. Native callers receive a newly-created, caller-owned HICON; this
/// cache never retains or destroys those handles. Call <see cref="DestroyIcon"/>
/// after the native consumer has finished with a returned handle.
/// </remarks>
internal sealed class NativeIconCache : IDisposable
{
    private const int MinimumLogicalSize = 8;
    private const int MaximumLogicalSize = 96;
    private const int MinimumPixelSize = 8;
    private const int MaximumPixelSize = 512;
    private const int MaximumResidentResources = 384;
    private const int MaximumResourceBytes = 4 * 1024 * 1024;

    private const uint IconResourceVersion = 0x00030000;
    private const uint LoadResourceDefaultColor = 0;
    private const uint DibRgbColors = 0;
    private const uint BitmapCompressionRgb = 0;

    private static readonly int[] RasterSizes = [16, 20, 24, 25, 30, 32, 40, 48, 64];
    private static readonly IReadOnlyDictionary<string, string> CanonicalNames =
        new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase)
        {
            ["app-mark"] = "app-mark",
            ["back"] = "back",
            ["cancel-timer"] = "cancel-timer",
            ["close"] = "close",
            ["compact"] = "compact",
            ["dislike"] = "dislike",
            ["error"] = "error",
            ["exit-fullscreen"] = "exit-fullscreen",
            ["forward"] = "forward",
            ["fullscreen"] = "fullscreen",
            ["hide"] = "hide",
            ["home"] = "home",
            ["like"] = "like",
            ["minimize"] = "minimize",
            ["next"] = "next",
            ["overflow"] = "overflow",
            ["pause"] = "pause",
            ["pin"] = "pin",
            ["play-pause"] = "play-pause",
            ["play"] = "play",
            ["previous"] = "previous",
            ["quit-timer"] = "quit-timer",
            ["quit"] = "quit",
            ["repeat-one"] = "repeat-one",
            ["repeat"] = "repeat",
            ["restore-section"] = "restore-section",
            ["restore-window"] = "restore-window",
            ["retry"] = "retry",
            ["settings"] = "settings",
            ["show"] = "show",
            ["shuffle"] = "shuffle",
            ["status"] = "status",
            ["tray"] = "tray",
            ["update"] = "update",
            ["update-available"] = "update-available",
            ["volume-muted"] = "volume-muted",
            ["volume"] = "volume",
            ["zoom-in"] = "zoom-in",
            ["zoom-out"] = "zoom-out",
            ["zoom-reset"] = "zoom-reset"
        };

    private readonly Dictionary<CacheKey, byte[]> _resources = new();
    private bool _disposed;

    /// <summary>
    /// Creates a new BitmapIcon backed by the original packaged raster asset.
    /// </summary>
    /// <param name="name">One of the canonical native icon names.</param>
    /// <param name="logicalSize">Requested DIP size used to choose a source raster.</param>
    internal IconElement CreateElement(string name, double logicalSize = 20)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var canonicalName = CanonicalizeName(name);
        ValidateLogicalSize(logicalSize);

        var rasterSize = SelectElementRasterSize(logicalSize);
        var icon = new BitmapIcon
        {
            UriSource = new Uri($"ms-appx:///Assets/NativeIcons/raster/{rasterSize}/{canonicalName}.png"),
            // A BitmapIcon is a FrameworkElement. Give the template an exact
            // DIP box so a wide Compact button cannot stretch the glyph.
            Width = logicalSize,
            Height = logicalSize,
            HorizontalAlignment = HorizontalAlignment.Center,
            VerticalAlignment = VerticalAlignment.Center,
            UseLayoutRounding = true,
            // The original raster files are white/alpha masks. Leaving
            // Foreground unset lets a Button/MenuFlyout template or parent
            // ContentPresenter supply its state-aware brush, including HC,
            // selected, pointer-over, pressed, and disabled states.
            ShowAsMonochrome = true
        };
        return icon;
    }

    /// <summary>
    /// Creates a caller-owned HICON from an embedded original PNG and a tint.
    /// </summary>
    /// <remarks>
    /// Windows documents that Vista-and-later RT_ICON resources may contain
    /// PNG-compressed data. The embedded PNG is therefore passed to
    /// CreateIconFromResourceEx, decoded by the OS, read through GetDIBits,
    /// tinted in a bounded 32-bpp BGRA buffer, and materialized with
    /// CreateIconIndirect. No GDI+ image API is involved.
    /// </remarks>
    internal nint CreateOwnedIcon(string name, int pixelSize, System.Drawing.Color tint)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var canonicalName = CanonicalizeName(name);
        ValidatePixelSize(pixelSize);
        if (tint.IsEmpty)
            throw new ArgumentException("A concrete tint color is required.", nameof(tint));

        var rasterSize = SelectRasterSize(pixelSize);
        var resourceName = new CacheKey(canonicalName, rasterSize);
        var png = GetResource(resourceName);
        return CreateTintedIcon(png, pixelSize, tint);
    }

    /// <summary>
    /// Destroys an HICON returned by <see cref="CreateOwnedIcon"/>.
    /// </summary>
    internal static void DestroyIcon(nint icon)
    {
        if (icon == 0)
            return;

        if (!DestroyIconNative(icon))
            throw new Win32Exception(Marshal.GetLastWin32Error(), "DestroyIcon failed.");
    }

    /// <summary>Releases bounded embedded-resource bytes; outstanding HICONs remain caller-owned.</summary>
    internal void Clear()
    {
        _resources.Clear();
    }

    public void Dispose()
    {
        if (_disposed)
            return;

        _disposed = true;
        Clear();
    }

    private byte[] GetResource(CacheKey key)
    {
        if (_resources.TryGetValue(key, out var cached))
            return cached;
        if (_resources.Count >= MaximumResidentResources)
            throw new InvalidOperationException(
                "Native icon source cache is full; unbind icons and call Clear before changing theme or DPI.");

        var resourceName = $"Nativune.NativeIcons.{key.RasterSize}.{key.Name}.png";
        using var stream = typeof(NativeIconCache).Assembly.GetManifestResourceStream(resourceName)
            ?? throw new InvalidOperationException($"Embedded native icon resource is missing: {resourceName}");
        if (!stream.CanSeek || stream.Length is <= 0 or > MaximumResourceBytes)
            throw new InvalidOperationException($"Embedded native icon resource has an invalid size: {resourceName}");

        var bytes = new byte[checked((int)stream.Length)];
        stream.ReadExactly(bytes);
        ValidatePng(bytes, key.RasterSize, resourceName);
        _resources.Add(key, bytes);
        return bytes;
    }

    private static string CanonicalizeName(string name)
    {
        if (string.IsNullOrWhiteSpace(name) ||
            !CanonicalNames.TryGetValue(name.Trim(), out var canonicalName))
        {
            throw new ArgumentException("The icon name is not part of the native icon family.", nameof(name));
        }

        return canonicalName;
    }

    private static void ValidateLogicalSize(double logicalSize)
    {
        if (!double.IsFinite(logicalSize) || logicalSize is < MinimumLogicalSize or > MaximumLogicalSize)
        {
            throw new ArgumentOutOfRangeException(nameof(logicalSize),
                $"Logical icon size must be between {MinimumLogicalSize} and {MaximumLogicalSize} DIP.");
        }
    }

    private static void ValidatePixelSize(int pixelSize)
    {
        if (pixelSize is < MinimumPixelSize or > MaximumPixelSize)
        {
            throw new ArgumentOutOfRangeException(nameof(pixelSize),
                $"Pixel icon size must be between {MinimumPixelSize} and {MaximumPixelSize}.");
        }
    }

    private static int SelectRasterSize(double desired)
    {
        var selected = RasterSizes[0];
        var distance = Math.Abs(selected - desired);
        for (var index = 1; index < RasterSizes.Length; index++)
        {
            var candidate = RasterSizes[index];
            var candidateDistance = Math.Abs(candidate - desired);
            if (candidateDistance < distance || candidateDistance == distance && candidate > selected)
            {
                selected = candidate;
                distance = candidateDistance;
            }
        }

        return selected;
    }

    // XAML has no DPI argument at creation time; use an existing 2x source so
    // 150–200% displays do not upscale a 1x raster. Native HICON selection
    // intentionally remains tied to the requested output pixel size.
    private static int SelectElementRasterSize(double logicalSize) =>
        SelectRasterSize(Math.Min(logicalSize * 2d, RasterSizes[^1]));

    private static void ValidatePng(byte[] bytes, int expectedSize, string resourceName)
    {
        if (bytes.Length < 24 ||
            bytes[0] != 0x89 || bytes[1] != 0x50 || bytes[2] != 0x4E || bytes[3] != 0x47 ||
            bytes[4] != 0x0D || bytes[5] != 0x0A || bytes[6] != 0x1A || bytes[7] != 0x0A ||
            bytes[12] != (byte)'I' || bytes[13] != (byte)'H' ||
            bytes[14] != (byte)'D' || bytes[15] != (byte)'R')
        {
            throw new InvalidOperationException($"Embedded native icon resource is not a PNG: {resourceName}");
        }

        var width = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(16, sizeof(uint)));
        var height = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(20, sizeof(uint)));
        if (width != expectedSize || height != expectedSize)
        {
            throw new InvalidOperationException(
                $"Embedded native icon resource has unexpected dimensions: {resourceName}");
        }
    }

    private static nint CreateTintedIcon(byte[] png, int pixelSize, System.Drawing.Color tint)
    {
        nint sourceIcon = 0;
        nint sourceColor = 0;
        nint sourceMask = 0;
        nint tintedColor = 0;
        nint maskForResult = 0;

        try
        {
            sourceIcon = CreateRawIcon(png, pixelSize);
            if (!GetIconInfoNative(sourceIcon, out var sourceInfo))
            {
                throw LastWin32("GetIconInfo failed.");
            }

            sourceColor = sourceInfo.HbmColor;
            sourceMask = sourceInfo.HbmMask;
            if (sourceColor == 0)
                throw new InvalidOperationException("Native icon resource did not provide a color bitmap.");

            var deviceContext = GetDCNative(0);
            if (deviceContext == 0)
                throw LastWin32("GetDC failed while creating a native icon.");

            try
            {
                var pixels = ReadBitmap(deviceContext, sourceColor, pixelSize, 32);
                if (!HasVisibleAlpha(pixels))
                {
                    if (sourceMask == 0)
                        throw new InvalidOperationException("Native icon resource did not provide an alpha mask.");
                    ApplyMaskAlpha(deviceContext, sourceMask, pixelSize, pixels);
                }

                ApplyTint(pixels, tint);
                tintedColor = CreateColorBitmap(deviceContext, pixelSize, pixels);
                maskForResult = sourceMask != 0
                    ? sourceMask
                    : CreateMaskBitmap(deviceContext, pixelSize);

                var resultInfo = new ICONINFO
                {
                    FIcon = true,
                    XHotspot = sourceInfo.XHotspot,
                    YHotspot = sourceInfo.YHotspot,
                    HbmMask = maskForResult,
                    HbmColor = tintedColor
                };
                var result = CreateIconIndirectNative(ref resultInfo);
                if (result == 0)
                    throw LastWin32("CreateIconIndirect failed while creating a native icon.");
                return result;
            }
            finally
            {
                _ = ReleaseDCNative(0, deviceContext);
            }
        }
        finally
        {
            if (tintedColor != 0)
                _ = DeleteObjectNative(tintedColor);
            if (maskForResult != 0 && maskForResult != sourceMask)
                _ = DeleteObjectNative(maskForResult);
            if (sourceColor != 0)
                _ = DeleteObjectNative(sourceColor);
            if (sourceMask != 0 && sourceMask != sourceColor)
                _ = DeleteObjectNative(sourceMask);
            if (sourceIcon != 0)
                _ = DestroyIconNative(sourceIcon);
        }
    }

    private static nint CreateRawIcon(byte[] png, int pixelSize)
    {
        var pinned = GCHandle.Alloc(png, GCHandleType.Pinned);
        try
        {
            var icon = CreateIconFromResourceExNative(
                pinned.AddrOfPinnedObject(),
                checked((uint)png.Length),
                true,
                IconResourceVersion,
                pixelSize,
                pixelSize,
                LoadResourceDefaultColor);
            if (icon == 0)
                throw LastWin32("CreateIconFromResourceEx failed while decoding the original PNG.");
            return icon;
        }
        finally
        {
            pinned.Free();
        }
    }

    private static byte[] ReadBitmap(nint deviceContext, nint bitmap, int size, ushort bitsPerPixel)
    {
        var stride = BitmapStride(size, bitsPerPixel);
        var bytes = new byte[checked(stride * size)];
        var pointer = Marshal.AllocHGlobal(bytes.Length);
        try
        {
            var info = CreateBitmapInfo(size, -size, bitsPerPixel, checked((uint)bytes.Length));
            var lines = GetDibitsNative(
                deviceContext,
                bitmap,
                0,
                checked((uint)size),
                pointer,
                ref info,
                DibRgbColors);
            if (lines != size)
                throw LastWin32("GetDIBits failed while reading a native icon bitmap.");

            Marshal.Copy(pointer, bytes, 0, bytes.Length);
            return bytes;
        }
        finally
        {
            Marshal.FreeHGlobal(pointer);
        }
    }

    private static void ApplyMaskAlpha(nint deviceContext, nint mask, int size, byte[] pixels)
    {
        byte[] maskBits;
        try
        {
            maskBits = ReadBitmap(deviceContext, mask, size, 1);
        }
        catch (Win32Exception)
        {
            throw new InvalidOperationException("Native icon mask could not be decoded.");
        }

        var maskStride = BitmapStride(size, 1);
        for (var y = 0; y < size; y++)
        {
            for (var x = 0; x < size; x++)
            {
                var maskBit = (maskBits[y * maskStride + (x >> 3)] & (0x80 >> (x & 7))) != 0;
                if (!maskBit)
                    pixels[(y * size + x) * 4 + 3] = 0xFF;
            }
        }
    }

    private static void ApplyTint(byte[] pixels, System.Drawing.Color tint)
    {
        var sourcePremultiplied = IsPremultiplied(pixels);
        for (var offset = 0; offset < pixels.Length; offset += 4)
        {
            var sourceAlpha = pixels[offset + 3];
            var outputAlpha = Multiply(sourceAlpha, tint.A);
            var blue = Multiply(pixels[offset], tint.B);
            var green = Multiply(pixels[offset + 1], tint.G);
            var red = Multiply(pixels[offset + 2], tint.R);

            // CreateIconIndirect consumes a 32-bpp alpha DIB with premultiplied
            // RGB. GetDIBits normally preserves that representation, but a
            // straight-alpha source is handled explicitly as well.
            if (!sourcePremultiplied)
            {
                blue = Multiply(blue, sourceAlpha);
                green = Multiply(green, sourceAlpha);
                red = Multiply(red, sourceAlpha);
            }

            blue = Multiply(blue, tint.A);
            green = Multiply(green, tint.A);
            red = Multiply(red, tint.A);
            pixels[offset] = blue;
            pixels[offset + 1] = green;
            pixels[offset + 2] = red;
            pixels[offset + 3] = outputAlpha;
        }
    }

    private static bool IsPremultiplied(byte[] pixels)
    {
        for (var offset = 0; offset < pixels.Length; offset += 4)
        {
            var alpha = pixels[offset + 3];
            if (alpha is 0 or 255)
                continue;
            if (pixels[offset] > alpha || pixels[offset + 1] > alpha || pixels[offset + 2] > alpha)
                return false;
        }

        return true;
    }

    private static bool HasVisibleAlpha(byte[] pixels)
    {
        for (var offset = 3; offset < pixels.Length; offset += 4)
        {
            if (pixels[offset] != 0)
                return true;
        }

        return false;
    }

    private static byte Multiply(byte value, byte factor) =>
        (byte)((value * factor + 127) / 255);

    private static nint CreateColorBitmap(nint deviceContext, int size, byte[] pixels)
    {
        var info = CreateBitmapInfo(size, -size, 32, checked((uint)pixels.Length));
        var bitmap = CreateDibSectionNative(
            deviceContext,
            ref info,
            DibRgbColors,
            out var bits,
            0,
            0);
        if (bitmap == 0 || bits == 0)
        {
            if (bitmap != 0)
                _ = DeleteObjectNative(bitmap);
            throw LastWin32("CreateDIBSection failed while creating a tinted native icon.");
        }

        try
        {
            Marshal.Copy(pixels, 0, bits, pixels.Length);
            return bitmap;
        }
        catch
        {
            _ = DeleteObjectNative(bitmap);
            throw;
        }
    }

    private static nint CreateMaskBitmap(nint deviceContext, int size)
    {
        var stride = BitmapStride(size, 1);
        var info = CreateBitmapInfo(size, -size, 1, checked((uint)(stride * size)));
        var bitmap = CreateDibSectionNative(
            deviceContext,
            ref info,
            DibRgbColors,
            out var bits,
            0,
            0);
        if (bitmap == 0 || bits == 0)
        {
            if (bitmap != 0)
                _ = DeleteObjectNative(bitmap);
            throw LastWin32("CreateDIBSection failed while creating a native icon mask.");
        }

        // Zero is the transparent-bit clear state for an AND mask. The 32-bit
        // icon color bitmap carries the actual alpha values.
        var blank = new byte[checked(stride * size)];
        try
        {
            Marshal.Copy(blank, 0, bits, blank.Length);
            return bitmap;
        }
        catch
        {
            _ = DeleteObjectNative(bitmap);
            throw;
        }
    }

    private static BITMAPINFO CreateBitmapInfo(int width, int height, ushort bitsPerPixel, uint imageSize)
    {
        var info = new BITMAPINFO
        {
            Header = new BITMAPINFOHEADER
            {
                Size = (uint)Marshal.SizeOf<BITMAPINFOHEADER>(),
                Width = width,
                Height = height,
                Planes = 1,
                BitCount = bitsPerPixel,
                Compression = BitmapCompressionRgb,
                SizeImage = imageSize
            }
        };
        if (bitsPerPixel == 1)
        {
            // BI_RGB 1-bpp DIBs carry a two-entry RGBQUAD palette. Keeping it
            // in the managed struct prevents GetDIBits/CreateDIBSection from
            // reading or writing past the native BITMAPINFO buffer.
            info.Color0 = new RGBQUAD();
            info.Color1 = new RGBQUAD { Blue = 0xFF, Green = 0xFF, Red = 0xFF };
        }
        return info;
    }

    private static int BitmapStride(int width, ushort bitsPerPixel) =>
        checked(((width * bitsPerPixel + 31) / 32) * 4);

    private static Win32Exception LastWin32(string message) =>
        new(Marshal.GetLastWin32Error(), message);

    private readonly record struct CacheKey(string Name, int RasterSize);

    [StructLayout(LayoutKind.Sequential)]
    private struct ICONINFO
    {
        [MarshalAs(UnmanagedType.Bool)]
        public bool FIcon;
        public int XHotspot;
        public int YHotspot;
        public nint HbmMask;
        public nint HbmColor;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFO
    {
        public BITMAPINFOHEADER Header;
        public RGBQUAD Color0;
        public RGBQUAD Color1;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct RGBQUAD
    {
        public byte Blue;
        public byte Green;
        public byte Red;
        public byte Reserved;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct BITMAPINFOHEADER
    {
        public uint Size;
        public int Width;
        public int Height;
        public ushort Planes;
        public ushort BitCount;
        public uint Compression;
        public uint SizeImage;
        public int XPelsPerMeter;
        public int YPelsPerMeter;
        public uint ClrUsed;
        public uint ClrImportant;
    }

    [DllImport("user32.dll", EntryPoint = "CreateIconFromResourceEx", SetLastError = true)]
    private static extern nint CreateIconFromResourceExNative(
        nint presbits,
        uint dwResSize,
        [MarshalAs(UnmanagedType.Bool)] bool fIcon,
        uint dwVer,
        int cxDesired,
        int cyDesired,
        uint flags);

    [DllImport("user32.dll", EntryPoint = "GetIconInfo", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool GetIconInfoNative(nint hIcon, out ICONINFO piconinfo);

    [DllImport("user32.dll", EntryPoint = "CreateIconIndirect", SetLastError = true)]
    private static extern nint CreateIconIndirectNative(ref ICONINFO piconinfo);

    [DllImport("user32.dll", EntryPoint = "DestroyIcon", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DestroyIconNative(nint hIcon);

    [DllImport("user32.dll", EntryPoint = "GetDC", SetLastError = true)]
    private static extern nint GetDCNative(nint hWnd);

    [DllImport("user32.dll", EntryPoint = "ReleaseDC", SetLastError = true)]
    private static extern int ReleaseDCNative(nint hWnd, nint hDc);

    [DllImport("gdi32.dll", EntryPoint = "GetDIBits", SetLastError = true)]
    private static extern int GetDibitsNative(
        nint hDc,
        nint hBitmap,
        uint start,
        uint lines,
        nint bits,
        ref BITMAPINFO bitmapInfo,
        uint usage);

    [DllImport("gdi32.dll", EntryPoint = "CreateDIBSection", SetLastError = true)]
    private static extern nint CreateDibSectionNative(
        nint hDc,
        ref BITMAPINFO bitmapInfo,
        uint usage,
        out nint bits,
        nint section,
        uint offset);

    [DllImport("gdi32.dll", EntryPoint = "DeleteObject", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool DeleteObjectNative(nint handle);
}
