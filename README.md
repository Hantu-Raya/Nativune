# Nativune

Nativune is an experimental native Windows shell for the official YouTube Music website. It combines a WinUI 3 window with an isolated WebView2 profile and native desktop controls.

Nativune is unofficial and is not affiliated with or endorsed by Google, YouTube, or Microsoft.

## Current status

Nativune is pre-release software for Windows x64. Core packaging, install, update, rollback, uninstall, and account-free self-check flows are implemented, but broad device, accessibility, long-session, and resource-target acceptance is not complete.

## Features

- Native WinUI 3 shell around the official `music.youtube.com` experience
- Full and Compact player views in the same native window
- Native tray, taskbar, keyboard-shortcut, playback, volume, seek, rating, repeat, shuffle, and pause-timer surfaces; new profiles enable the tray by default, Close hides when its icon is available, and Quit exits
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

The verified local 0.1.2 package and private CI-built 0.1.3 package are self-contained. The private, unsigned 0.1.4 shared-runtime prerelease passed an isolated per-user install and account-free native guest startup on this workstation, but not a clean Windows VM or supported-platform compatibility matrix; it is not a publicly supported release.

## Install

1. Repository collaborators can download `Nativune-Setup.exe` and `SHA256SUMS.txt` from the same [private v0.1.9 GitHub prerelease](https://github.com/Hantu-Raya/youtube/releases/tag/v0.1.9). This is not a public download. An installed 0.1.4 or unpublished local 0.1.5–0.1.8 build upgrades in place with `data/` kept.
2. Verify the installer hash in PowerShell:

   ```powershell
   Get-FileHash .\Nativune-Setup.exe -Algorithm SHA256
   Get-Content .\SHA256SUMS.txt
   ```

   The reported SHA-256 value must match the `Nativune-Setup.exe` entry exactly.
3. Run `Nativune-Setup.exe`, review the bundled third-party terms, and if a prerequisite is missing review its named Microsoft download link before choosing whether Setup should install it.

The default install location is `%LOCALAPPDATA%\Nativune`. Setup registers Nativune for the current Windows user and adds correctly parameterized Start menu and desktop shortcuts.

The earlier owner-approved local 0.1.5 **v12** was installed at the default per-user root with `data/` preserved; no source was pushed. The owner reported Compact progress **still blank** in earlier v11 despite working in 0.1.2, then reported **extended duration and unavailable seek** in v12 (`~3:42 / 4:29` in Compact). V12 therefore has **not passed signed-in acceptance**. Full and Compact have no bottom status strip; routine Compact statuses are available through **More → Application status**, while actionable errors remain visible inline. Compact playback controls disable during an in-flight command. A website-slider/media-clock mismatch disables seeking; v12 displays validated current media time as `~`-prefixed read-only progress when duration is known and overrun bounded, but that media duration is not proven to equal the site's song duration. The Shuffle active dot follows a bounded observed dark-site style only while a separate Repeat Off button confirms the inactive color; other contexts remain unconfirmed. Setup's interactive completion notice was not independently observed during an earlier local reinstall; silent installs, cancellations, failures and uninstalls do not show that notice.

The earlier v10 temporary clock probe was opt-in through a process-local flag and showed only in-memory cause categories in the explicitly opened native Application status; it did not log track details. That owner-approved diagnostic found absent watch identity, a transient unavailable state, and persistent public-slider/media-clock disagreement after a near-end seek. The temporary probe is **absent from installed v12 and current source**.

Installed v11's last-confirmed/three-sample mismatch fallback left progress blank for the owner's reported case; which guard failed remains unverified. **Installed v12** displays current media time immediately as approximate read-only progress during website-slider disagreement, bounded by media duration plus two seconds; seeking stays disabled. Invalid/unavailable snapshots remain blank and progress is never carried over from another item. Focused DOM scripts, native Compact regressions, account-free WinUI fixture, package integrity, installed payload hashes/shortcuts and the installed executable's account-free self-check passed, but the owner's v12 screenshot shows an extended total and no seek. A subsequent paired live observation confirmed website and Compact time disagree; its cause and a safe correction remain unverified, so these checks do not establish signed-in acceptance or authorize a push.

Further owner screenshots show a read-only `~3:07 / 3:52` state and, after full-view rewind, an interactive `2:35 / 3:16` state with apparently the same item. A separate direct test of installed v12 observed the website at `2:15 / 2:31` and `2:17 / 2:31` immediately around Compact's read-only `~4:37 / 4:52` on a playing item. The website seek bar worked during playback on an earlier item, but was **not verified on the mismatched item**. This confirms a displayed-clock discrepancy, not a safe alternate timeline or the provider slider's numeric units. Seeking remains disabled when clocks disagree; see the [live observation and limitations](plan.md#compact-reliability-and-startup-follow-up).

A repeat live test beginning near 86% of the website timeline showed Compact already read-only at `~3:10 / 3:35`; while it kept playing, its media total grew to `4:09` and the progress fraction fell from 88% to 82%. On another item, the website's `2:35 / 3:00` and `2:49 / 3:00` bracketed Compact's non-seekable `~5:54–5:58 / 6:18`. This reproduces the reported near-end failure, but does not identify the provider's slider units or a safe seek target; the website seek could not be verified on that mismatched item.

The local **0.1.6 playbar package**, built from the 0.1.5 source candidate, displays the corroborated website clock instead of the longer media clock. Its unsigned installer is `artifacts/near-end-playbar-016-candidate/Nativune-Setup.exe` (SHA-256 `821b4101e1bcd0d8c4c66b71d80f63f5f29eb9632da9196655e9f1fe184102b7`); checksums, embedded ZIP, all 1,322 payload hashes, packaged-app self-check and account-free native fixture passed. With exact owner approval, it replaced installed 0.1.5 v12 at the default root; `data/` remained and all installed managed hashes matched. In the signed-in session, the owner reports the displayed duration now follows the song but the Compact playbar cannot be dragged near the end of the first item. A bounded native accessibility read confirmed website time `1:30 / 3:16` on a read-only bar explicitly reporting a media-timeline mismatch. The fix is **not accepted**: seek remains disabled rather than guessing an unsafe offset. See [live evidence and next gate](plan.md#compact-reliability-and-startup-follow-up).

With separate exact owner approval, the **0.1.7 numeric diagnostic** at `artifacts/near-end-clock-probe-017/Nativune-Setup.exe` (SHA-256 `d4d53ab863266720f86623bc1ad1f4469321168f189f0bcd155a565a8339f13c`) replaced 0.1.6, preserved `data/` and passed installed payload hashes and self-check. Its process-local, explicitly opened **Application status** exposed only numeric clocks and seek flags. On one website item, site/media positions were `20/290.1` then `94/364.1` seconds (offset 270.1 seconds), while media duration advanced only `381.7→389.2` seconds and could not contain a mapped seek to the website's 193-second end. Later at website 171/193 and media 441.2/462.4 seconds, the existing seek slider became enabled. This establishes a changing media-duration ceiling, not safe whole-song seeking earlier in the item. No private track/account details were printed or logged; the then-installed 0.1.7 was diagnostic, not an accepted playbar fix.

With a further exact owner choice, the reviewed **0.1.8 guarded-seek candidate** at `artifacts/near-end-buffered-018-reviewed/Nativune-Setup.exe` (SHA-256 `a3c90d702d19d46d2a3e64a8609735b7bab8008a025671a3ab1a71ac050b8135`) replaced 0.1.7 at the default root, preserving `data/` and 56 unmanaged uBO Lite cache files. Its manifest, all 1,322 managed hashes and installed account-free self-check passed. It confirms a local position offset from two advancing same-item website/media samples, then refuses targets outside the current media duration or seekable range. In the signed-in Compact trial, startup showed `0:00 / 2:35`; later, a `2:58`-duration item was read-only at `1:32` and again near its end at `2:56`. The item identity across the duration change was not checked. On a subsequent `3:01`-duration item, the old duration-based slider briefly enabled; one five-second key seek reported dispatch without website confirmation. No offset-guarded near-end action was possible because the bar was read-only. Playback was paused. **Near-end drag remains unaccepted.** The earlier package under `artifacts/near-end-buffered-018-candidate/` predates a parser-bound fix and must not be installed.

The Compact website-slider seek route ships in 0.1.9. It commits through Music's own `tp-yt-paper-slider#progress-bar`: it sets the website-time value and dispatches one `change`, letting the site's handler map it to its media timeline; Nativune no longer writes `HTMLMediaElement.currentTime` or derives an offset. A coherent visible website clock governs display and seek eligibility; media time/duration are diagnostic only, and growing media duration no longer stales an item or cancels a drag/pending seek. Origin, document, unique visible enabled slider, item signature, bounds and in-flight seeking are revalidated before one dispatch, with no retry. The backup remains at `%LOCALAPPDATA%\Nativune-before-clean-test-20260925` for the owner to restore or delete. A temporary Release publish (since removed), its account-free `self-check`, a 60-second native fixture and both focused playback scripts passed; a frozen-rubric Jevify sweep of 412 seek/clock source lines found and corrected one obsolete outcome check. In an earlier clean 0.1.8 comparison, seeking worked while **signed out**, which did not establish old profile data as the cause. In the owner's later signed-in test of the uninstalled route build using a repository-local profile (not the installed app), one first Compact drag was refused with “Playback changed; no action was sent.” After a full-view website seek and Compact re-entry, the owner reports seeking worked near the end and on the next song; after restart, the first Compact click or drag worked without the full-view step. The first refusal's cause was not captured, and whether the full-view click was needed is unknown.

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

The repository keeps its toolchain and caches under the repository. Current source and the release-script default are **0.1.9**. The latest private prerelease is 0.1.9: the [private, unsigned v0.1.9 prerelease](https://github.com/Hantu-Raya/youtube/releases/tag/v0.1.9) was published from [CI run 36072281560](https://github.com/Hantu-Raya/youtube/actions/runs/36072281560) on commit `f7b1f89`. Its four assets were independently reverified after download (checksums, 0.1.9 manifest, all 1,322 ZIP entry hashes, appended ZIP) and match the release downloads byte-for-byte; installer SHA-256 `30ec328e8e75c842ef28c4e9d3432e1c767a50923916db192414d202aa481288`. It is unsigned, manual-only (the updater cannot see this private repository), and not a public or clean-Windows-accepted release. Local 0.1.2 artifacts and the private CI-built 0.1.3 package predate the latest prerelease and have not been accepted as public releases. On a fresh Windows checkout, prepare the pinned local inputs and restore both projects:

```powershell
pwsh -NoProfile -File scripts/setup.ps1
pwsh -NoProfile -File scripts/setup-webview2.ps1
pwsh -NoProfile -File scripts/setup-ubol.ps1
pwsh -NoProfile -File scripts/dotnet.ps1 restore src/Nativune/Nativune.csproj --runtime win-x64
pwsh -NoProfile -File scripts/dotnet.ps1 restore src/Nativune.Installer/Nativune.Installer.csproj --runtime win-x64
pwsh -NoProfile -File scripts/build-release.ps1 -Version 0.1.9 -Configuration Release
```

These setup and restore scripts keep downloaded toolchain, development browser, extension and NuGet inputs in repository-local `.tools` and `.cache` directories; they do not install a global SDK or WebView2 runtime. The shared-runtime release candidate does not include the development fixed-version browser. `build-release.ps1` verifies pinned local inputs, publishes the app and installer, scans the public payload, and writes these files under `artifacts/release`:

- `Nativune-Setup.exe`
- `Nativune-Setup.zip`
- `release-manifest.json`
- `SHA256SUMS.txt`

### Private CI artifact

The private installer workflow's first run (35951546259) failed on the old uBO source fingerprint; the corrected [0.1.3 CI run](https://github.com/Hantu-Raya/youtube/actions/runs/35952514474) passed packaging, integrity checks and artifact upload. Its private run artifact was not a release or an installed-size measurement. The workflow itself does not push, create a tag or GitHub Release, or test signed-in playback. The [private 0.1.4 prerelease](https://github.com/Hantu-Raya/youtube/releases/tag/v0.1.4) manually publishes assets from [passing CI run 35964031761](https://github.com/Hantu-Raya/youtube/actions/runs/35964031761); it does not establish clean-Windows compatibility or public release acceptance. See the [CI and footprint plan](plan.md#private-ci-artifact-build).

For development commands and project constraints, see [agents.md](agents.md) and the current-state index in [plan.md](plan.md#current-state).

## Limitations

- Windows x64 only
- The smaller candidate relies on shared Microsoft runtimes; clean-Windows installation, total shared-prerequisite footprint, and the supported-Windows compatibility matrix remain unverified. See [measured local candidate and limits](plan.md#shared-runtime-installer-candidate-24-september-2026).
- No Authenticode signature yet; signing will identify the publisher, but new releases may still trigger SmartScreen until reputation is established
- Website-backed commands are compatibility behavior, not a documented Google playback API
- Full saved-library parity, Premium behavior, mixed-DPI/high-contrast coverage, long-session stability, and the complete-process resource target remain unverified
- Source now lives in the private `Hantu-Raya/Nativune` repository (history mirrored from the archived `Hantu-Raya/youtube`, which keeps the v0.1.4/v0.1.9 release pages). The updater cannot see private releases; making the repository public needs a separate history-privacy decision.

## License

Nativune source and original assets are available under the [MIT License](LICENSE). Bundled dependencies retain their own licenses. See [THIRD-PARTY-NOTICES.txt](THIRD-PARTY-NOTICES.txt); release packages include the complete referenced license and notice files.
