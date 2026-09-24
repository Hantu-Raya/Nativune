# Nativune

Nativune is an experimental native Windows shell for the official YouTube Music website. It combines a WinUI 3 window with an isolated, fixed-version WebView2 runtime and native desktop controls.

Nativune is unofficial and is not affiliated with or endorsed by Google, YouTube, or Microsoft.

## Current status

Nativune is pre-release software for Windows x64. Core packaging, install, update, rollback, uninstall, and account-free self-check flows are implemented, but broad device, accessibility, long-session, and resource-target acceptance is not complete.

## Features

- Native WinUI 3 shell around the official `music.youtube.com` experience
- Full and Compact player views in the same native window
- Native tray, taskbar, keyboard-shortcut, playback, volume, seek, rating, repeat, shuffle, and pause-timer surfaces
- Fail-closed commands against the single owned Music view, without a native web bridge
- Isolated WebView2 profile and a bundled fixed-version WebView2 runtime
- Privacy-only uBlock Origin Lite configuration
- Per-user installation without administrator access
- Prompted, SHA-256-verified updates from the official GitHub release channel

Website-backed controls depend on the public YouTube Music interface and can become unavailable when that interface changes. Nativune does not download music or block YouTube ads.

## Requirements

- 64-bit Windows 10 version 2004 (build 19041) or later
- Enough disk space for the large bundled app and browser runtime plus installation and update staging. The local 0.1.2 setup artifact was 634.44 MB; that is not an installed-size measurement. See the [footprint plan](plan.md#installer-footprint-baseline-and-debloat-plan).
- A network connection for YouTube Music and release update checks

The verified local 0.1.2 package is self-contained and does not require a global .NET, Windows App SDK, or WebView2 installation. The 0.1.3 source has not been packaged; the proposed footprint work has not changed this prerequisite.

## Install

1. Download `Nativune-Setup.exe` and `SHA256SUMS.txt` from the same GitHub release.
2. Verify the installer hash in PowerShell:

   ```powershell
   Get-FileHash .\Nativune-Setup.exe -Algorithm SHA256
   Get-Content .\SHA256SUMS.txt
   ```

   The reported SHA-256 value must match the `Nativune-Setup.exe` entry exactly.
3. Run `Nativune-Setup.exe` and review the bundled third-party terms shown by Setup.

The default install location is `%LOCALAPPDATA%\Nativune`. Setup registers Nativune for the current Windows user and adds correctly parameterized Start menu and desktop shortcuts.

### Unsigned-build warning

The current release artifacts are not Authenticode-signed. Windows can therefore show **Unknown publisher** or a Microsoft Defender SmartScreen warning even when the SHA-256 value is correct. Do not continue unless the file came from the official release and its hash matches.

## Updates and uninstall

Nativune checks the official `Hantu-Raya/Nativune` GitHub release channel. When a newer stable release is available, the app asks before downloading it, verifies GitHub's SHA-256 digest, and then starts Setup. It does not silently download an installer at startup.

Uninstall Nativune from **Windows Settings > Apps > Installed apps**, or run the installed Setup program with `--uninstall`. Uninstall removes manifest-owned application files and shell registration but deliberately preserves the `data` directory. To remove the WebView profile, cookies, preferences, and locally protected OAuth state too, delete `%LOCALAPPDATA%\Nativune\data` after uninstalling.

## Privacy and account boundaries

- Google sign-in and consent remain user-operated.
- Nativune does not collect passwords, import cookies from another browser, or bypass Google's sign-in controls.
- The embedded site profile is isolated under the installation's `data` directory.
- OAuth token state used by console/API experiments is protected with Windows DPAPI and is tied to the Windows user and machine.
- OAuth/API access does not establish a YouTube Music website session or native streaming entitlement.
- Playback and account-library behavior remain subject to YouTube's terms and the capabilities of the official website.

## Build from source

The repository keeps its toolchain and caches under the repository. Current source and the release-script default are **0.1.3**; local 0.1.2 artifacts predate this source, and the version number does not mean a 0.1.3 package has been built or accepted. On a fresh Windows checkout, prepare the pinned local inputs and restore both projects:

```powershell
pwsh -NoProfile -File scripts/setup.ps1
pwsh -NoProfile -File scripts/setup-webview2.ps1
pwsh -NoProfile -File scripts/setup-ubol.ps1
pwsh -NoProfile -File scripts/dotnet.ps1 restore src/Nativune/Nativune.csproj --runtime win-x64
pwsh -NoProfile -File scripts/dotnet.ps1 restore src/Nativune.Installer/Nativune.Installer.csproj --runtime win-x64
pwsh -NoProfile -File scripts/build-release.ps1 -Version 0.1.3 -Configuration Release
```

These setup and restore scripts keep downloaded toolchain, browser, extension and NuGet inputs in repository-local `.tools` and `.cache` directories; they do not install a global SDK or WebView2 runtime. `build-release.ps1` verifies the pinned SDK/runtime/extension inputs, publishes the app and installer, scans the public payload, and writes these files under `artifacts/release`:

- `Nativune-Setup.exe`
- `Nativune-Setup.zip`
- `release-manifest.json`
- `SHA256SUMS.txt`

### Private CI artifact

The planned private [installer workflow](.github/workflows/build-installer.yml) will build on every push to `main` and also supports a manual workflow dispatch, once the workflow is committed there. It will use the committed app/installer version, the repository-local setup/restore scripts, the existing source regression checks, and the integrity-checked release script. Its private run artifact contains only the four files above and expires after 14 days. It does not push, create a tag or GitHub Release, or test signed-in playback; no GitHub run has yet been verified. A future manual tag/release remains separate and only follows package and compatibility acceptance. See the [CI and footprint plan](plan.md#private-ci-artifact-build).

For development commands and project constraints, see [agents.md](agents.md) and the current-state index in [plan.md](plan.md#current-state).

## Limitations

- Windows x64 only
- Large download and installed footprint because the fixed WebView2 runtime is bundled
- No Authenticode signature yet
- Website-backed commands are compatibility behavior, not a documented Google playback API
- Full saved-library parity, Premium behavior, mixed-DPI/high-contrast coverage, long-session stability, and the complete-process resource target remain unverified
- The public updater works only after the GitHub repository and release channel are public

## License

Nativune source and original assets are available under the [MIT License](LICENSE). Bundled dependencies retain their own licenses. See [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt); release packages include the complete referenced license and notice files.
