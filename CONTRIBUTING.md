# Contributing to Nativune

Bug reports and feature ideas are welcome as [GitHub issues](https://github.com/Hantu-Raya/Nativune/issues). Before opening a pull request, please open an issue to discuss the change.

## Ground rules

These are project non-goals, and pull requests that add them will not be accepted:

- downloading media or blocking ads
- private or undocumented playback APIs, stream extraction or native audio playback of YouTube content
- collecting passwords, importing browser cookies or automating Google sign-in
- a native bridge that lets web content call into the app

Keep the existing security boundaries: one owned WebView2 view, the navigation allow-list, and controls that fail closed without automatic retries. Do not include account data, cookies, private library contents or listening history in issues, logs or screenshots.

## Build and run

Follow [Build from source](README.md#build-from-source) in the README. All tools and caches stay inside the repository (`.tools/`, `.cache/`, `artifacts/`, `data/`); no global installation is required.

## Development checks

Run the focused source checks:

```powershell
node scripts/check-player-controls.cjs
node scripts/check-compact-player.cjs
python scripts/check-native-icons.py
python scripts/check-launcher.py
```

For the app checks, publish the app to the path expected by `scripts/probe.ps1`, then run:

```powershell
pwsh -NoProfile -File scripts/dotnet.ps1 publish src/Nativune/Nativune.csproj --runtime win-x64 --self-contained false -o artifacts/winui3/publish
pwsh -NoProfile -File scripts/probe.ps1 self-check
pwsh -NoProfile -File scripts/probe.ps1 native-fixture
```

UI changes also need a check in the running app.

Before adding a test, read the testing rules in [agents.md](agents.md#test): prefer end-to-end tests that leave a repeatable artifact, and don't add unit tests after the code is written.

### Testing the updater

Start the local metadata server with `python scripts/updater-test-server.py --scenario available`. Build the app with `-p:UpdaterTestHooks=true`, then set `NATIVUNE_TEST_RELEASE_METADATA_URL` to the URL the server prints. The test hook accepts only loopback `http://127.0.0.1` addresses and is not compiled into release builds.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
