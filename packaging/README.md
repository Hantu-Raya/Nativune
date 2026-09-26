# Package manager packaging

Nativune's winget manifests and Chocolatey package are prepared here but not yet published. The first publishable version is 0.1.27: the switches both package managers need (`--install-prerequisites` and the `QuietUninstallString`) ship with Setup 1.0.2, and older Setups exit 2 on the unknown switch. The workflow only submits 0.1.27 or later; rendering older releases is fine for template validation.

## Layout

- `winget/`: multi-file manifest templates (schema 1.12.0) for `Nativune.Nativune`: version, default locale (en-US) and installer.
- `chocolatey/`: the `nativune` package: `nativune.nuspec` plus `tools/chocolateyinstall.ps1` and `tools/chocolateyuninstall.ps1`.

Templates use `{{VERSION}}`, `{{SETUP_SHA256}}` (uppercase hex) and `{{RELEASE_DATE}}` (`yyyy-MM-dd`). Both package managers run `Nativune-Setup.exe --silent --no-launch --install-prerequisites`. Setup registers a `QuietUninstallString` (`"<root>\installer\Nativune.Setup.exe" --uninstall --silent --install-dir "<root>"`), which winget uses to uninstall.

## Render locally

Download `Nativune-Setup.exe` and `SHA256SUMS.txt` from a release into one directory, then:

```powershell
./scripts/render-package-manifests.ps1 -Version 0.1.26 -ReleaseDirectory artifacts/release-download
```

The script checks that the Setup hash matches `SHA256SUMS.txt` and writes to `artifacts/package-managers/<version>/`:

- `winget/manifests/n/Nativune/Nativune/<version>/` (the winget-pkgs layout)
- `chocolatey/nativune/` (pack with `choco pack chocolatey/nativune/nativune.nuspec`)

## Validate

```powershell
winget validate --manifest <out>/winget/manifests/n/Nativune/Nativune/<version>
winget settings --enable LocalManifestFiles   # once, from an elevated shell
winget install --manifest <out>/winget/manifests/n/Nativune/Nativune/<version>
choco install nativune --source <out>/chocolatey
```

Install tests change the machine; run them on a disposable Windows account or VM.

## Automation

`.github/workflows/package-managers.yml` renders and packs on every published release, on manual dispatch (with a tag) and on pull requests that touch this folder (against the latest release). It uploads the result as an artifact. It submits only for release or dispatch runs, and only when the matching secret exists:

- `WINGET_TOKEN`: opens a winget-pkgs pull request with `vedantmgoyal9/winget-releaser`.
- `CHOCO_API_KEY`: runs `choco push` to the Chocolatey Community Repository.

## Owner-only first steps

winget:

1. Sign the Microsoft CLA when the first winget-pkgs pull request asks for it.
2. Fork `microsoft/winget-pkgs` under the owner account (winget-releaser pushes branches to that fork).
3. Create a classic personal access token with `public_repo` (add `workflow` if the fork requires it) and store it as the `WINGET_TOKEN` repository secret.
4. Submit the first version manually: render it, run `winget validate`, and open a pull request adding `manifests/n/Nativune/Nativune/<version>/`. winget-releaser only updates packages that already exist in winget-pkgs.

Chocolatey:

1. Create a community.chocolatey.org account and copy its API key into the `CHOCO_API_KEY` repository secret.
2. Push the first version (from the workflow or `choco push`) and wait for automated validation, verification and human moderation. Later versions still pass moderation until the package is trusted.

## Known gaps

- **Windows App Runtime 2.5.1.** winget's `Microsoft.WindowsAppRuntime.2` only reaches 2.3.1 and Chocolatey has no 2.x package, so neither manifest declares it. Setup installs it through `--install-prerequisites`. The other prerequisites are declared as dependencies (VC++ 2015+ x64, .NET 10 runtime, WebView2 Runtime 152.0.4191.53 or later).
- **Chocolatey elevation.** Chocolatey runs elevated, and Nativune installs per user, so it lands in the profile of the account that runs `choco`. When that differs from the signed-in user, the install script warns; install from the GitHub release as the intended user instead.
- **Unsigned installer.** winget allows unsigned installers, but SmartScreen and antivirus scans during validation may still flag it.
