# Original Nativune functional icons

This repository contains original functional shell glyphs for Nativune's native surfaces. They are not copied YouTube/Google branding, Material Symbols, competitor artwork, or a font. The official service branding remains inside the unchanged website.

## Files and active inventory

`masters/` contains 45 SVG masters: 43 active canonical icons and two retained historical song-notification masters (`notifications.svg` and `notifications-off.svg`). The active names are:

`app-mark`, `back`, `cancel-timer`, `close`, `compact`, `dislike`, `dislike-filled`, `error`, `exit-fullscreen`, `forward`, `fullscreen`, `hide`, `home`, `like`, `like-filled`, `minimize`, `next`, `overflow`, `pause`, `pin`, `play-pause`, `play`, `playlist`, `previous`, `quit-timer`, `quit`, `repeat-one`, `repeat`, `restore-section`, `restore-window`, `retry`, `settings`, `show`, `shuffle`, `status`, `tray`, `update`, `update-available`, `volume-muted`, `volume`, `zoom-in`, `zoom-out`, `zoom-reset`.

`states/mask/` contains exactly the 43 active white-mask SVG inputs used by the build-time renderer. The two historical notification masks are retained under `states/historical/mask/` and are not renderer inputs, embedded resources, cache names, or native commands. The existing `states/{normal,hover,pressed,disabled,checked,focus}/` directories retain the original historical state gallery, including notification files; new first-slice glyphs intentionally provide only masks because native controls draw state backgrounds and focus rings. This is an explicit historical-variant boundary, not an active-state count.

`tokens.json` records the shared 24-unit geometry, two-unit rounded strokes, color and size choices. Runtime requests remain limited to logical sizes 16, 20 and 32; the renderer emits the nine documented raster sizes (16, 20, 24, 25, 30, 32, 40, 48 and 64 pixels).

## Runtime pipeline

The native shell uses embedded PNG resources and never parses SVG at runtime. The checked-in pipeline converts the active white masks to transparent PNGs with the pinned repository-local resvg 0.47.0 executable, then embeds those PNGs as ordinary resources. `NativeIconCache` validates the unchanged logical-size/DPI/color API, uses the 43 active canonical names, bounds resident images and theme colors, and disposes owned tinted images on `Clear`/`Dispose`. Consumers detach borrowed images before appearance/DPI cache clears; consumers do not dispose cache entries.

The renderer performs bounded XML parsing and static element/attribute checks, rejects DTDs, scripts and external values, verifies the pinned executable SHA-256 sidecar, emits all nine sizes, and writes a manifest with resource names, dimensions and output hashes. The renderer is a build-time tool only; ordinary builds embed PNGs and do not add a runtime SVG dependency. Regenerate with `pwsh -NoProfile -File scripts/render-native-icons.ps1`; run its focused safety checks with `python scripts/check-native-icons.py`.

## Provenance and license

The ten active additions (`volume`, `volume-muted`, `like`, `dislike`, `repeat`, `repeat-one`, `shuffle`, `settings`, `minimize`, `close`) were supplied in `quiet-player-review-package.zip` under `quiet-player-review/icons/{masters,masks}/`. The package's offline structural review reported them as original designs and recorded source hashes.

On 20 September 2026, the project owner confirmed ownership or permission to distribute these additions publicly and selected the repository's MIT License for Nativune. No Google trademark or third-party brand license is asserted by this provenance statement. The supplied review ZIP has SHA-256 `d8f967cd5882a3846f8ac519c20e2f0942f002626a31e96384c385907ac485fb`; the ten master/mask pairs retain the supplied geometry and colors unchanged.

`update` and `update-available` were designed for Nativune in September 2026 as original glyphs under the repository's MIT License. `playlist` (three list lines and a play triangle, for the Compact Playlists button), `like-filled` and `dislike-filled` (solid thumbs shown when a song is liked or disliked) were added in the same way on 25 September 2026.

The two notification masters and historical variants remain as evidence/inventory only. They are deliberately excluded from the active renderer list, project resource glob, cache registry, and native checks. No notification canonical resources are generated or bundled.

## Validation scope

The supplied review performed offline XML/allowlist/size inspection of the ten additions. Integration has regenerated 387 active PNGs with the pinned renderer. That establishes raster generation, not native optical, accessibility, DPI, high-contrast or playback acceptance. Current application verification and its remaining limits are recorded with the project.
