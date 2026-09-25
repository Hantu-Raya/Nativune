# Nativune

A native WinUI 3 shell for the official YouTube Music website, with an isolated WebView2 profile and native desktop controls.

## Notice

Nativune is an unofficial project. It is not affiliated with, endorsed by or sponsored by Google or YouTube. It displays the official YouTube Music website; it does not download media, block ads, or use a private playback API.

YouTube and YouTube Music are trademarks of Google LLC.

## Features

- Full and Compact player views in one native window
- Native tray, taskbar, keyboard shortcuts and playback, volume, seek, rating, repeat, shuffle and pause-timer controls
- Fail-closed controls for the single owned YouTube Music view, without a native web bridge
- Isolated WebView2 profile using the shared Evergreen WebView2 Runtime
- Privacy-only uBlock Origin Lite configuration
- Per-user installation
- Full-window toolbar update status for manual checks or prompted updates; automatic checks are optional

Website-backed controls depend on the public YouTube Music interface and may change when the site changes.

## Requirements

- 64-bit Windows 10, version 2004 (build 19041) or later
- .NET 10 Runtime (not the Desktop Runtime), Windows App SDK 2.5.1 runtime, Evergreen WebView2 Runtime and x64 Visual C++ v14 Redistributable
- Internet access for YouTube Music, update checks and downloading missing prerequisites

Setup checks for missing shared prerequisites and asks before installing them. Shared components may require administrator rights or an organization policy change.

## Install

1. Download `Nativune-Setup.exe` and `SHA256SUMS.txt` from the [Nativune GitHub Releases page](https://github.com/Hantu-Raya/Nativune/releases).
2. In PowerShell, calculate the installer's SHA-256 hash and display the checksum file:

   ```powershell
   Get-FileHash .\Nativune-Setup.exe -Algorithm SHA256
   Get-Content .\SHA256SUMS.txt
   ```

   Compare the reported hash with the `Nativune-Setup.exe` entry in `SHA256SUMS.txt`. Do not run the installer if they differ.
3. Run `Nativune-Setup.exe` and follow Setup.

The default install location is `%LOCALAPPDATA%\Nativune`. In-place upgrades keep the existing `data/` directory.

## Unsigned-build warning

The installer is not yet Authenticode-signed. Windows may show an Unknown publisher or SmartScreen warning. Signing will identify the publisher, but new releases may still trigger SmartScreen until reputation is established.

## Updates

The app never opens an update dialog on its own and never downloads an update without a click. In the full-window top toolbar, the button at the far right shows:

- `update-available` (accent-tinted) when a newer stable release is available
- `update` otherwise, including when a check fails

Compact mode has no update button. Click `update-available` to open the confirmation dialog; choose **Update now** to download, verify the SHA-256 digest and start Setup, or choose **Later** to defer. Setup asks again before upgrading.

Click `update` to run a manual check and show the result in its tooltip/status. If checking fails, the button keeps `update` and its tooltip reads: “Couldn't check for updates. Click to try again.”

When **Check for updates automatically** is enabled in Settings, the app checks at startup and every 24 hours while it is running. Turn off that checkbox to disable automatic checks. Automatic checks only report availability; they do not open a dialog or download anything.

Each check makes one anonymous GitHub API request. The updater considers only the latest stable, non-prerelease release from `Hantu-Raya/Nativune`, and only when it is newer than the installed version.

## Uninstall

Uninstall Nativune from **Windows Settings > Apps > Installed apps**, or run the installed Setup program with `--uninstall`. Uninstall removes application files and shell registration but preserves `data/`. After uninstalling, delete the installation's `data/` directory yourself if you also want to remove the isolated WebView2 profile and its site data.

## Privacy and account boundaries

- You sign in to Google yourself through the embedded official YouTube Music site.
- Nativune does not collect passwords or import cookies from another browser.
- The isolated WebView2 profile lives under the installation's `data/` directory.
- Playback and account features remain subject to the official website and its terms.

## Build from source

The current source version is **0.1.10**. The repository-local setup scripts prepare the toolchain and pinned development inputs; restore and build the application and installer with:

```powershell
pwsh -NoProfile -File scripts/setup.ps1
pwsh -NoProfile -File scripts/setup-webview2.ps1
pwsh -NoProfile -File scripts/setup-ubol.ps1
pwsh -NoProfile -File scripts/dotnet.ps1 restore src/Nativune/Nativune.csproj --runtime win-x64
pwsh -NoProfile -File scripts/dotnet.ps1 restore src/Nativune.Installer/Nativune.Installer.csproj --runtime win-x64
pwsh -NoProfile -File scripts/build-release.ps1 -Version 0.1.10 -Configuration Release
```

Setup and restore scripts keep downloaded tools, browser inputs, extension inputs and NuGet packages in repository-local `.tools/` and `.cache/` directories. The release build writes its output under `artifacts/release/`:

- `Nativune-Setup.exe`
- `Nativune-Setup.zip`
- `release-manifest.json`
- `SHA256SUMS.txt`

## Development checks

Run the focused source checks:

```powershell
node scripts/check-player-controls.cjs
node scripts/check-compact-player.cjs
python scripts/check-native-icons.py
```

For the app checks, publish the app to the path expected by `scripts/probe.ps1`, then run:

```powershell
pwsh -NoProfile -File scripts/dotnet.ps1 publish src/Nativune/Nativune.csproj --runtime win-x64 --self-contained false -o artifacts/winui3/publish
pwsh -NoProfile -File scripts/probe.ps1 self-check
pwsh -NoProfile -File scripts/probe.ps1 native-fixture
```

## Limitations

- Windows x64 only
- Unsigned installer; SmartScreen warnings may persist until signing reputation is established
- Website-UI compatibility can change when YouTube Music changes
- Clean-Windows installation matrix, Premium and saved-library parity, and long-session resource targets remain unverified

## License

Nativune source and original assets are available under the [MIT License](LICENSE). Bundled dependencies retain their own licenses; see [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt).
