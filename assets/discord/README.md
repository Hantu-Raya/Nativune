# Discord Rich Presence assets

Art assets for the Nativune application in the Discord Developer Portal (Rich Presence → Art Assets). Upload each file under the asset key shown; the app refers to them only by key.

| File | Size | Asset key | Use |
| --- | --- | --- | --- |
| `nativune-1024.png` | 1024×1024 | `nativune` | Large image: the Nativune mark on its white tile with a safe margin, because Discord crops large images to a rounded square. |
| `pause-512.png` | 512×512 | `pause` | Small image while paused: white pause glyph in an accent (`#FF0033`) disc, transparent outside the disc. |
| `repeat-one-512.png` | 512×512 | `repeat-one` | Small image while repeat-one is on: same disc style as `pause`. |

Badge glyphs fit within 60% of the image width so they survive Discord's circular mask.

## Provenance

Derived from the original Nativune icon set under the repository's MIT License: `assets/app-icon/nativune-icon.svg` for the large image and `assets/native-icons/masters/pause.svg` and `repeat-one.svg` for the badges (see `assets/native-icons/README.md`). The accent colour is `AccentBrush` from `src/Nativune/ShellTheme.xaml`. No Discord, Google or YouTube artwork is used.

## Regeneration

```powershell
pwsh -NoProfile -File scripts/render-discord-assets.ps1
```

The script uses the pinned project-local resvg 0.47.0 (`.tools/resvg`, checksum-verified), writes intermediate SVGs to `.cache/discord-assets`, and checks the output dimensions.

## Approval

The project owner must review and approve these images before anyone uploads them to the Discord Developer Portal.
