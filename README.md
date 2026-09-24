# Nativune

Nativune is an experimental native Windows shell for the official YouTube Music website. It combines a WinUI 3 window with an isolated WebView2 profile and native desktop controls.

Nativune is unofficial and is not affiliated with or endorsed by Google, YouTube, or Microsoft.

## Current status

Nativune is pre-release software for Windows x64. Core packaging, install, update, rollback, uninstall, and account-free self-check flows are implemented, but broad device, accessibility, long-session, and resource-target acceptance is not complete.

## Features

- Native WinUI 3 shell around the official `music.youtube.com` experience
- Full and Compact player views in the same native window
- Native tray, taskbar, keyboard-shortcut, playback, volume, seek, rating, repeat, shuffle, and pause-timer surfaces
- Fail-closed commands against the single owned Music view, without a native web bridge
- Isolated WebView2 profile using the shared Evergreen WebView2 Runtime (in the new local installer candidate)
- Privacy-only uBlock Origin Lite configuration
- Per-user installation without administrator access
- Prompted, SHA-256-verified updates from the official GitHub release channel

Website-backed controls depend on the public YouTube Music interface and can become unavailable when that interface changes. Nativune does not download music or block YouTube ads.

## Requirements

- 64-bit Windows 10 version 2004 (build 19041) or later
- The new framework-dependent candidate requires the x64 .NET 10 Runtime (not the Desktop Runtime), Windows App SDK 2.5.1 runtime, Evergreen WebView2 Runtime, and x64 Visual C++ v14 Redistributable. Setup checks for these before changing Nativune files; if one is missing, it shows its official Microsoft link and asks before downloading or installing it. Declining, being offline, or using `--silent` without the prerequisite leaves the installation unchanged. Shared components use machine storage outside the Nativune folder and may require administrator rights or an organization policy change; Setup must not bypass those restrictions.
- A network connection for YouTube Music and release update checks; installing missing prerequisites also needs a connection.

The verified local 0.1.2 package and private CI-built 0.1.3 package are self-contained. The newer 0.1.4 shared-runtime candidate passed an isolated per-user install and account-free native guest startup on this workstation, but not a clean Windows VM or supported-platform compatibility matrix; a private release is not a publicly supported release.

## Install

1. Repository collaborators can download `Nativune-Setup.exe` and `SHA256SUMS.txt` from the same [private GitHub release](https://github.com/Hantu-Raya/youtube/releases). This release is not a public download.
2. Verify the installer hash in PowerShell:

   ```powershell
   Get-FileHash .\Nativune-Setup.exe -Algorithm SHA256
   Get-Content .\SHA256SUMS.txt
   ```

   The reported SHA-256 value must match the `Nativune-Setup.exe` entry exactly.
3. Run `Nativune-Setup.exe`, review the bundled third-party terms, and if a prerequisite is missing review its named Microsoft download link before choosing whether Setup should install it.

The default install location is `%LOCALAPPDATA%\Nativune`. Setup registers Nativune for the current Windows user and adds correctly parameterized Start menu and desktop shortcuts.

### Unsigned-build warning

The private release installer is not Authenticode-signed. Windows can therefore show **Unknown publisher** or a Microsoft Defender SmartScreen warning even when the SHA-256 value is correct. Do not continue unless the file came from this repository's release and its hash matches.

## Updates and uninstall

Nativune checks the planned public `Hantu-Raya/Nativune` GitHub release channel. When a newer stable release is available there, the app asks before downloading it, verifies GitHub's SHA-256 digest, and then starts interactive Setup. Setup asks before upgrading and separately before installing any missing Microsoft prerequisite; cancelling preserves the current version, though you may need to reopen the app. It does not silently download an installer at startup. A private release under `Hantu-Raya/youtube` is **manual only**: the updater cannot discover it.

Uninstall Nativune from **Windows Settings > Apps > Installed apps**, or run the installed Setup program with `--uninstall`. Uninstall removes manifest-owned application files and shell registration but deliberately preserves the `data` directory. To remove the WebView profile, cookies, preferences, and locally protected OAuth state too, delete `%LOCALAPPDATA%\Nativune\data` after uninstalling.

## Privacy and account boundaries

- Google sign-in and consent remain user-operated.
- Nativune does not collect passwords, import cookies from another browser, or bypass Google's sign-in controls.
- The embedded site profile is isolated under the installation's `data` directory.
- OAuth token state used by console/API experiments is protected with Windows DPAPI and is tied to the Windows user and machine.
- OAuth/API access does not establish a YouTube Music website session or native streaming entitlement.
- Playback and account-library behavior remain subject to YouTube's terms and the capabilities of the official website.

## Build from source

The repository keeps its toolchain and caches under the repository. Current source and the release-script default are **0.1.4**; local 0.1.2 artifacts and the private CI-built 0.1.3 package predate this candidate and have not been accepted as public releases. On a fresh Windows checkout, prepare the pinned local inputs and restore both projects:

```powershell
pwsh -NoProfile -File scripts/setup.ps1
pwsh -NoProfile -File scripts/setup-webview2.ps1
pwsh -NoProfile -File scripts/setup-ubol.ps1
pwsh -NoProfile -File scripts/dotnet.ps1 restore src/Nativune/Nativune.csproj --runtime win-x64
pwsh -NoProfile -File scripts/dotnet.ps1 restore src/Nativune.Installer/Nativune.Installer.csproj --runtime win-x64
pwsh -NoProfile -File scripts/build-release.ps1 -Version 0.1.4 -Configuration Release
```

These setup and restore scripts keep downloaded toolchain, development browser, extension and NuGet inputs in repository-local `.tools` and `.cache` directories; they do not install a global SDK or WebView2 runtime. The shared-runtime release candidate does not include the development fixed-version browser. `build-release.ps1` verifies pinned local inputs, publishes the app and installer, scans the public payload, and writes these files under `artifacts/release`:

- `Nativune-Setup.exe`
- `Nativune-Setup.zip`
- `release-manifest.json`
- `SHA256SUMS.txt`

### Private CI artifact

The private installer workflow's first run (35951546259) failed on the old uBO source fingerprint; the corrected [0.1.3 CI run](https://github.com/Hantu-Raya/youtube/actions/runs/35952514474) passed packaging, integrity checks and artifact upload. Its private run artifact is not a release or an installed-size measurement. The workflow does not push, create a tag or GitHub Release, or test signed-in playback. A manually published private 0.1.4 installer is separate from CI and does not establish clean-Windows compatibility or public release acceptance. See the [CI and footprint plan](plan.md#private-ci-artifact-build).

For development commands and project constraints, see [agents.md](agents.md) and the current-state index in [plan.md](plan.md#current-state).

## Limitations

- Windows x64 only
- The smaller candidate relies on shared Microsoft runtimes; clean-Windows installation, total shared-prerequisite footprint, and the supported-Windows compatibility matrix remain unverified. See [measured local candidate and limits](plan.md#shared-runtime-installer-candidate-24-september-2026).
- No Authenticode signature yet
- Website-backed commands are compatibility behavior, not a documented Google playback API
- Full saved-library parity, Premium behavior, mixed-DPI/high-contrast coverage, long-session stability, and the complete-process resource target remain unverified
- The updater does not see this repository's private release; a future public channel needs a separate visibility/history decision.

## License

Nativune source and original assets are available under the [MIT License](LICENSE). Bundled dependencies retain their own licenses. See [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt); release packages include the complete referenced license and notice files.
