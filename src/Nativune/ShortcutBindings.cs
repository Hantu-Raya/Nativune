using Windows.System;

namespace Nativune;

internal sealed record ShortcutBindings(int Toggle, int Previous, int Next, int Compact)
{
    // The historical settings encoding stores these three modifier flags above
    // the low 16-bit virtual-key code. Keep that representation byte-for-byte
    // compatible with the persisted settings file while using Win32/WinUI
    // virtual-key values directly.
    private const uint ShiftModifier = 0x10000;
    private const uint ControlModifier = 0x20000;
    private const uint AltModifier = 0x40000;
    private const uint AllowedModifiers = ShiftModifier | ControlModifier | AltModifier;
    private const uint RequiredModifiers = ControlModifier | AltModifier;
    private const uint KeyMask = 0xFFFF;

    internal static ShortcutBindings Default { get; } = new(
        Encode((uint)VirtualKey.P, control: true, alt: true, shift: true),
        Encode((uint)VirtualKey.Left, control: true, alt: true, shift: true),
        Encode((uint)VirtualKey.Right, control: true, alt: true, shift: true),
        0);

    internal int this[int index] => index switch
    {
        0 => Toggle,
        1 => Previous,
        2 => Next,
        3 => Compact,
        _ => throw new ArgumentOutOfRangeException(nameof(index))
    };

    internal IEnumerable<(string Command, int Binding)> Enumerate()
    {
        yield return ("toggle", Toggle);
        yield return ("previous", Previous);
        yield return ("next", Next);
        yield return ("compact", Compact);
    }

    internal bool Validate(out string error)
    {
        var values = new[] { Toggle, Previous, Next, Compact };
        var names = new[] { "Play/Pause", "Previous", "Next", "Compact/Full" };
        var seen = new Dictionary<int, string>();

        for (var i = 0; i < values.Length; i++)
        {
            if (values[i] == 0)
                continue;
            if (!TryDecode(values[i], out _, out _, out var reason))
            {
                error = $"{names[i]} shortcut is not supported: {reason}";
                return false;
            }
            if (seen.TryGetValue(values[i], out var existing))
            {
                error = $"{names[i]} shortcut duplicates {existing}. Choose a different combination or clear one binding.";
                return false;
            }
            seen.Add(values[i], names[i]);
        }

        error = string.Empty;
        return true;
    }

    internal static string Format(int encoded)
    {
        if (encoded == 0)
            return "Unbound";
        if (!TryDecode(encoded, out _, out var key, out _))
            return "Unsupported";

        var modifiers = (uint)encoded & AllowedModifiers;
        var parts = new List<string>(4);
        if ((modifiers & ControlModifier) != 0)
            parts.Add("Ctrl");
        if ((modifiers & AltModifier) != 0)
            parts.Add("Alt");
        if ((modifiers & ShiftModifier) != 0)
            parts.Add("Shift");
        parts.Add(KeyName(key));
        return string.Join("+", parts);
    }

    // modifiers is returned in RegisterHotKey's native 1/2/4 bit layout.
    internal static bool TryDecode(int encoded, out uint modifiers, out uint key, out string reason)
    {
        modifiers = 0;
        key = 0;
        reason = string.Empty;
        if (encoded <= 0)
        {
            reason = "choose a key combination or clear this binding";
            return false;
        }

        var value = (uint)encoded;
        var modifierBits = value & AllowedModifiers;
        var unsupportedBits = value & ~KeyMask & ~AllowedModifiers;
        var keyCode = value & KeyMask;
        if (unsupportedBits != 0)
        {
            reason = "contains an unsupported modifier";
            return false;
        }
        if ((modifierBits & RequiredModifiers) == 0)
        {
            reason = "use Ctrl or Alt, with optional Shift; naked keys are not registered";
            return false;
        }
        if (keyCode == 0 || IsModifierKey(keyCode))
        {
            reason = "a modifier by itself is not a shortcut";
            return false;
        }
        if (IsFunctionKey(keyCode))
        {
            reason = "function keys are reserved by Windows or the host";
            return false;
        }
        if (IsMediaOrSystemKey(keyCode))
        {
            reason = "media, Windows, browser and system keys are not supported";
            return false;
        }
        if (!IsAllowlistedKey(keyCode))
        {
            reason = "this virtual key is not an ordinary keyboard key";
            return false;
        }
        if (IsReservedCombination(modifierBits, keyCode))
        {
            reason = "this Windows or application-reserved combination is not available";
            return false;
        }

        if ((modifierBits & ControlModifier) != 0)
            modifiers |= 0x0002;
        if ((modifierBits & AltModifier) != 0)
            modifiers |= 0x0001;
        if ((modifierBits & ShiftModifier) != 0)
            modifiers |= 0x0004;
        key = keyCode;
        return true;
    }

    // Keep the persisted representation explicit instead of depending on a
    // framework enum's modifier layout.
    internal static int Encode(uint virtualKey, bool control, bool alt, bool shift)
    {
        var encoded = virtualKey & KeyMask;
        if (control)
            encoded |= ControlModifier;
        if (alt)
            encoded |= AltModifier;
        if (shift)
            encoded |= ShiftModifier;
        return checked((int)encoded);
    }

    private static bool IsModifierKey(uint key) => key is
        0x10 or 0x11 or 0x12 or 0xA0 or 0xA1 or 0xA2 or 0xA3 or 0xA4 or 0xA5;

    private static bool IsFunctionKey(uint key) => key is >= 0x70 and <= 0x87;

    private static bool IsMediaOrSystemKey(uint key) => key is
        0x5B or 0x5C or 0x5D or 0x5F or 0xA6 or 0xA7 or 0xA8 or 0xA9 or 0xAA
        or 0xAB or 0xAC or 0xAD or 0xAE or 0xAF or 0xB0 or 0xB1 or 0xB2 or 0xB3
        or 0x2C or 0x13 or 0x90 or 0x91 or 0x14 or 0x29 or 0x2B or 0x2F or 0x6C;

    private static bool IsReservedCombination(uint modifiers, uint key)
    {
        return ((key is 0x09 or 0x1B)
                && (modifiers & (AltModifier | ControlModifier)) != 0)
            || (key == 0x20 && (modifiers & AltModifier) != 0)
            || (key == 0x2E && (modifiers & (AltModifier | ControlModifier)) == (AltModifier | ControlModifier))
            || (modifiers == AltModifier && key is 0x4D or 0x25 or 0x27);
    }

    private static bool IsAllowlistedKey(uint key)
    {
        return key is >= 0x30 and <= 0x39 // digits
            or >= 0x41 and <= 0x5A // letters
            or >= 0x60 and <= 0x69 // numeric keypad
            or >= 0x21 and <= 0x2E // navigation, Insert and Delete
            or 0x08 or 0x0D or 0x20 // Backspace, Enter and Space
            or >= 0x6A and <= 0x6F // keypad punctuation
            or >= 0xBA and <= 0xC0 // OEM punctuation
            or >= 0xDB and <= 0xE2; // OEM punctuation
    }

    private static string KeyName(uint key) => key switch
    {
        0x25 => "Left",
        0x26 => "Up",
        0x27 => "Right",
        0x28 => "Down",
        0x0D => "Enter",
        0x08 => "Backspace",
        0x20 => "Space",
        0x21 => "PageUp",
        0x22 => "PageDown",
        0x24 => "Home",
        0x23 => "End",
        0x2D => "Insert",
        0x2E => "Delete",
        >= 0x30 and <= 0x39 => ((char)key).ToString(),
        >= 0x41 and <= 0x5A => ((char)key).ToString(),
        >= 0x60 and <= 0x69 => $"NumPad{key - 0x60}",
        0x6A => "Multiply",
        0x6B => "Add",
        0x6C => "Separator",
        0x6D => "Subtract",
        0x6E => "Decimal",
        0x6F => "Divide",
        0xBA => "Oem1",
        0xBB => "OemPlus",
        0xBC => "OemComma",
        0xBD => "OemMinus",
        0xBE => "OemPeriod",
        0xBF => "Oem2",
        0xC0 => "Oem3",
        0xDB => "Oem4",
        0xDC => "Oem5",
        0xDD => "Oem6",
        0xDE => "Oem7",
        0xDF => "Oem8",
        0xE2 => "Oem102",
        _ => $"VK 0x{key:X2}"
    };
}
