using System.Drawing;
using Windows.System;

namespace Nativune;

internal static class ShortcutChecks
{
    internal static void Run()
    {
        CheckBindings();
        CheckSettingsMigrationAndRoundTrip();
        CheckRegistrationAtomicity();
    }

    private static void CheckBindings()
    {
        var defaults = ShortcutBindings.Default;
        Require(defaults.Toggle == Encode(VirtualKey.P, control: true, alt: true, shift: true)
            && defaults.Previous == Encode(VirtualKey.Left, control: true, alt: true, shift: true)
            && defaults.Next == Encode(VirtualKey.Right, control: true, alt: true, shift: true)
            && defaults.Compact == 0, "Shortcut defaults changed.");
        Require(defaults.Validate(out var defaultError) && defaultError.Length == 0,
            "Shortcut defaults did not validate.");
        Require(ShortcutBindings.TryDecode(defaults.Toggle, out var nativeModifiers, out var nativeKey, out _)
            && nativeModifiers == 7 && nativeKey == (uint)VirtualKey.P,
            "Shortcut modifiers were not translated to RegisterHotKey's native layout.");
        Require(ShortcutBindings.Format(defaults.Toggle) == "Ctrl+Alt+Shift+P"
            && ShortcutBindings.Format(defaults.Previous) == "Ctrl+Alt+Shift+Left"
            && ShortcutBindings.Format(0) == "Unbound",
            "Shortcut formatting changed.");

        ExpectInvalid(new ShortcutBindings(Encode(VirtualKey.P), 0, 0, 0), "naked key");
        ExpectInvalid(new ShortcutBindings(Encode(VirtualKey.Control), 0, 0, 0), "bare modifier");
        ExpectInvalid(new ShortcutBindings(Encode(VirtualKey.F1, control: true, alt: true), 0, 0, 0), "function key");
        ExpectInvalid(new ShortcutBindings(ShortcutBindings.Encode(0xB3, control: true, alt: false, shift: false), 0, 0, 0), "media key");
        ExpectInvalid(new ShortcutBindings(defaults.Toggle, defaults.Toggle, 0, 0), "duplicate key");
        ExpectInvalid(new ShortcutBindings(
            Encode(VirtualKey.P, control: true) | 0x80000, 0, 0, 0), "Windows modifier");

        ExpectInvalid(new ShortcutBindings(Encode(VirtualKey.M, alt: true), 0, 0, 0), "Alt+M");
        ExpectInvalid(new ShortcutBindings(Encode(VirtualKey.Left, alt: true), 0, 0, 0), "Alt+Left");
        ExpectInvalid(new ShortcutBindings(Encode(VirtualKey.Right, alt: true), 0, 0, 0), "Alt+Right");
    }

    private static void CheckSettingsMigrationAndRoundTrip()
    {
        var root = Path.Combine(Path.GetTempPath(), "nativune-shortcuts-" + Guid.NewGuid().ToString("N"));
        var file = Path.Combine(root, "data", "settings.json");
        Directory.CreateDirectory(Path.GetDirectoryName(file)!);
        try
        {
            File.WriteAllText(file,
                "{\"Version\":1,\"X\":4000,\"Y\":-2000,\"Width\":1000,\"Height\":700,\"Dpi\":96,\"Maximized\":true,\"Zoom\":1.25,\"TrayEnabled\":true,\"RestoreSection\":true,\"LastSection\":\"library\"}");
            var migrated = ShellSettings.Load(root, out var warning);
            Require(warning is null && migrated.TrayEnabled && migrated.RestoreSection
                && migrated.Shortcuts == ShortcutBindings.Default && !migrated.ReduceMotion
                && migrated.CompactWidth == 800 && migrated.CompactHeight == 180,
                "Version 1 settings did not migrate without enabling new preferences.");

            var compact = Encode(VirtualKey.C, control: true, alt: true, shift: true);
            var custom = migrated with
            {
                ReduceMotion = true,
                Shortcuts = migrated.Shortcuts with { Compact = compact },
                CompactX = -1200,
                CompactY = 80,
                CompactWidth = 960,
                CompactHeight = 210,
                CompactDpi = 144
            };
            ShellSettings.SaveAsync(root, custom, CancellationToken.None).GetAwaiter().GetResult();
            var loaded = ShellSettings.Load(root, out warning);
            Require(warning is null && loaded == custom, "Settings did not survive a v2 shortcut/compact round-trip.");

            File.WriteAllText(file,
                "{\"Version\":2,\"X\":100,\"Y\":100,\"Width\":1280,\"Height\":800,\"Dpi\":96,\"Maximized\":false,\"Zoom\":1,\"CompactWidth\":2,\"CompactHeight\":2,\"CompactDpi\":999,\"Shortcuts\":{\"Toggle\":80,\"Previous\":0,\"Next\":0,\"Compact\":0}}");
            var repaired = ShellSettings.Load(root, out warning);
            Require(warning is null && repaired.Width == 1280 && repaired.CompactWidth == 800
                && repaired.CompactHeight == 180 && repaired.CompactDpi == 96
                && repaired.Shortcuts == ShortcutBindings.Default,
                "Invalid new settings fields were not safely defaulted.");

            File.WriteAllText(file,
                "{\"Version\":2,\"X\":100,\"Y\":100,\"Width\":1,\"Height\":800,\"Dpi\":96,\"Maximized\":false,\"Zoom\":1}");
            var invalid = ShellSettings.Load(root, out warning);
            Require(warning is not null && invalid == ShellSettings.Default,
                "Invalid core settings were accepted instead of migrating to defaults.");

            var clipped = ShellSettings.RestoreCompactBounds(custom, new Rectangle(0, 0, 640, 300), 192);
            Require(new Rectangle(0, 0, 640, 300).Contains(clipped),
                "Compact geometry was not safely clipped to the available display.");
        }
        finally
        {
            try { Directory.Delete(root, recursive: true); }
            catch (IOException) { }
            catch (UnauthorizedAccessException) { }
        }
    }

    private static void CheckRegistrationAtomicity()
    {
        var fake = new FakeHotKeyRegistrar();
        using var manager = new SessionShortcuts((nint)42, fake);
        var defaults = ShortcutBindings.Default;
        Require(manager.TryApply(defaults, out var error) && manager.Enabled && error.Length == 0,
            "Default shortcuts could not be registered with the test registrar.");
        var originalIds = fake.Active.Keys.ToArray();
        Require(originalIds.Length == 3 && originalIds.All(id => manager.CommandForHotkey(id) is not null),
            "Registered shortcut identifiers did not dispatch.");

        var conflict = Encode(VirtualKey.O, control: true, alt: true, shift: true);
        fake.Conflicts.Add((7, (uint)VirtualKey.O));
        Require(!manager.TryApply(defaults with { Toggle = conflict }, out error)
            && error.Contains("already use", StringComparison.OrdinalIgnoreCase)
            && manager.Enabled && originalIds.All(id => manager.CommandForHotkey(id) is not null)
            && fake.Active.Count == 3,
            "Registration conflict did not preserve the prior working set.");

        fake.Conflicts.Clear();
        fake.Calls.Clear();
        Require(manager.TryApply(defaults with { Toggle = conflict }, out error),
            "A non-conflicting replacement was rejected.");
        var firstUnregister = fake.Calls.FindIndex(call => call.StartsWith("unregister:", StringComparison.Ordinal));
        var lastRegister = fake.Calls.FindLastIndex(call => call.StartsWith("register:", StringComparison.Ordinal));
        Require(firstUnregister >= 0 && lastRegister >= 0 && lastRegister < firstUnregister,
            "New registrations were not acquired before old registrations were released.");

        var toggleId = fake.Active.Single(pair => manager.CommandForHotkey(pair.Key) == "toggle").Key;
        var previousId = fake.Active.Single(pair => manager.CommandForHotkey(pair.Key) == "previous").Key;
        var swapped = new ShortcutBindings(defaults.Previous, conflict, defaults.Next, defaults.Compact);
        fake.Calls.Clear();
        Require(manager.TryApply(swapped, out error)
            && manager.CommandForHotkey(toggleId) == "previous"
            && manager.CommandForHotkey(previousId) == "toggle"
            && fake.Calls.Count == 0,
            "Shortcut swaps did not reuse existing registrations atomically.");

        fake.FailNextUnregister = true;
        var failedReplacement = Encode(VirtualKey.Q, control: true, alt: true, shift: true);
        Require(!manager.TryApply(swapped with { Toggle = failedReplacement }, out error)
            && manager.Enabled && error.Contains("could not be replaced", StringComparison.OrdinalIgnoreCase),
            "A failed release was not reported.");
        Require(fake.Active.Count == 3 && fake.Active.Keys.All(id => manager.CommandForHotkey(id) is not null),
            "A failed replacement lost the prior registrations.");
        manager.Disable();
        Require(!manager.Enabled && fake.Active.Count == 0, "Disabling shortcuts did not unregister all IDs.");
        manager.Disable();
        CheckRollbackFailures();
    }

    private static void CheckRollbackFailures()
    {
        var registerFake = new FakeHotKeyRegistrar { FailRegisterKey = (uint)VirtualKey.Q, FailNextUnregister = true };
        using (var manager = new SessionShortcuts((nint)43, registerFake))
        {
            var defaults = ShortcutBindings.Default;
            var candidate = defaults with
            {
                Toggle = Encode(VirtualKey.O, control: true, alt: true, shift: true),
                Previous = Encode(VirtualKey.Q, control: true, alt: true, shift: true)
            };
            Require(!manager.TryApply(candidate, out _)
                && manager.CleanupFailed && !manager.Enabled
                && registerFake.Active.Keys.All(id => manager.CommandForHotkey(id) is null),
                "A failed registration rollback did not fail closed or left a falsely active map.");
            registerFake.FailNextUnregister = false;
            manager.Dispose();
            Require(registerFake.Active.Count == 0, "An acquired registration was lost from final cleanup tracking.");
        }

        var restoreFake = new FakeHotKeyRegistrar();
        using (var manager = new SessionShortcuts((nint)44, restoreFake))
        {
            var defaults = ShortcutBindings.Default;
            Require(manager.TryApply(defaults, out _), "Restore-failure setup could not register defaults.");
            var oldPreviousId = restoreFake.Active.Single(pair => manager.CommandForHotkey(pair.Key) == "previous").Key;
            var oldToggleId = restoreFake.Active.Single(pair => manager.CommandForHotkey(pair.Key) == "toggle").Key;
            restoreFake.FailUnregisterId = oldPreviousId;
            restoreFake.FailRegisterId = oldToggleId;
            var candidate = defaults with { Toggle = Encode(VirtualKey.O, control: true, alt: true, shift: true), Previous = 0 };
            Require(!manager.TryApply(candidate, out var restoreError)
                && manager.CleanupFailed && !manager.Enabled
                && restoreError.Contains("restart", StringComparison.OrdinalIgnoreCase)
                && manager.CommandForHotkey(oldToggleId) is null,
                "A failed old-registration restore was not fail-closed.");
            Require(restoreFake.Active.Count == 2, "Restore failure left an unexpected active registration set.");
            restoreFake.FailUnregisterId = null;
            manager.Dispose();
            Require(restoreFake.Active.Count == 0, "Final cleanup did not release known restore-failure IDs.");
        }
    }

    private static int Encode(VirtualKey key, bool control = false, bool alt = false, bool shift = false)
        => ShortcutBindings.Encode((uint)key, control, alt, shift);

    private static void ExpectInvalid(ShortcutBindings bindings, string label)
    {
        Require(!bindings.Validate(out _), $"Unsupported {label} was accepted.");
    }

    private static void Require(bool condition, string message)
    {
        if (!condition)
            throw new InvalidOperationException(message);
    }

    private sealed class FakeHotKeyRegistrar : IHotKeyRegistrar
    {
        internal readonly Dictionary<int, (uint Modifiers, uint Key)> Active = new();
        internal readonly HashSet<(uint Modifiers, uint Key)> Conflicts = new();
        internal readonly List<string> Calls = new();
        internal bool FailNextUnregister;
        internal int? FailUnregisterId;
        internal int? FailRegisterId;
        internal uint? FailRegisterKey;

        public bool Register(nint windowHandle, int id, uint modifiers, uint key)
        {
            Calls.Add($"register:{id}");
            if ((FailRegisterId == id && FailRegisterId is not null)
                || (FailRegisterKey == key && FailRegisterKey is not null)
                || Conflicts.Contains((modifiers & ~0x4000u, key))
                || Active.Any(item => item.Value.Modifiers == modifiers && item.Value.Key == key))
                return false;
            Active[id] = (modifiers, key);
            return true;
        }

        public bool Unregister(nint windowHandle, int id)
        {
            Calls.Add($"unregister:{id}");
            if (FailUnregisterId == id
                || FailNextUnregister)
            {
                FailNextUnregister = false;
                return false;
            }
            return Active.Remove(id);
        }
    }
}
