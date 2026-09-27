# Barebones Better Lyrics E2E: protocol (thresholds frozen 28 September 2026)

These thresholds are frozen before the first full run. They are never loosened after data is collected. Any failure is reported as a failure. A scenario that cannot be measured is reported as **blocked**, never as a pass.

## Setup
- **Build:** `-p:PerfBenchHooks=true -o .cache/build/lyrics-e2e`. The seam (`BenchHooks.cs`, `WebHost.Bench.cs`, `WebHost.LyricsBench.cs`) is compiled only under `NATIVUNE_PERF_BENCH_HOOKS`.
- **Extension:** production loads it from the root's `.tools/better-lyrics/2.4.1.1`, a copy of the published tree. Expected ID: `ogodmldcmpbfeekmejkeppchklblochl`.
- **Roots:** each arm is a disposable root under `.cache/lyrics-e2e/runs/<stamp>/<root>`. It holds a copy of the signed-out profile template `.cache/perf/template/webview2`, pinned `.tools/ubol` and `.tools/better-lyrics`.
- **Settings:** `data/settings.json` sets `BetterLyricsEnabled`, `BlockAds` per arm, `AutoCheckUpdates=false` and `SleepInBackground=false`. Lyrics are switched on or off only there.
- **Playback:** muted, with autoplay. The start URI is the Radio of `dQw4w9WgXcQ` (`list=RDAMVMdQw4w9WgXcQ`).
- **Network log:** `--log-net-log=<runs>/<arm>.netlog.json --net-log-capture-mode=Default`. The analyzer parses the NetLog as JSON (`constants` + `events`, tolerant of a truncated tail) and takes hosts only from structured fields (`url`, `host`, `group_id`, …) of URL-request, host-resolver/DNS and connect-job/socket events, never from headers or free text. It keeps only real host names (dotted names or `localhost`; IP literals, bare `http`/`https` and single-label names such as `wpad` are dropped), first-seen times and request-source counts for lyric hosts. Raw netlogs and roots are deleted afterwards unless `-KeepRaw` is given.
- **Privacy:** lyric text and page titles are hashed, never logged. Only the `lyrics` category of the app log is copied.
- **Concurrency:** at most 3 app instances at once. The control arm `C` starts in the first wave, together with `R1` and `I`.

## Arms (schedules in seconds after playback starts)
| Arm | Root | Lyrics | Block ads | Schedule |
| --- | --- | --- | --- | --- |
| R1 | R | on | off | `lyrics@8;pause@70;play@76;seekfwd@95;seekback@115;next@135;options@175;quit@215`; writes nonces |
| R2 | R (restart) | on | on | `lyrics@8;options@60;quit@80`; reads nonces |
| C | C | off | off | the R1 schedule without `options` (host attribution only); `lyrics@8;quit@60` when only Smoke is selected |
| I | I | on | off | `lyrics@8;options@600;quit@620` |
| T1 | T | on | off | `lyrics@8;options@20;translate-on@25;capture:translate-on@45;translate-off@110;quit@120` |
| T2 | T (restart) | on | off | `lyrics@8;options@60;quit@90` |
| S1 | S | on | off | `lyrics@8;options@20;offset-set@70;translate-off@75;quit@125` (`translate-off` also sets the language to `de`; moved from `offset-set@45;translate-off@50;quit@100` after run `20260927T230031Z` for a longer clean before-window) |
| S2 | S (restart) | on | off | `lyrics@8;options@30;quit@45` |
| O1 | O (fresh) | off | off | `lyrics@8;quit@60` |
| P1, P2, P3 | P | on, then off, off | off | `lyrics@8;quit@40` each |
| V | V | on | off | `lyrics@8`, then `nav:<id>` every 30 s from 10 s over the 20 frozen tracks, then quit |
| G | G | on | off | `lyrics@8;next@60;quit@110`, start URI with `&hl=de`, browser started with `--lang=de` (amendment) |
| N | N | on | off | `lyrics@8;nav:<NoLyricsTrack>@10;quit@80`; default track `4Tr0otuiQuU` (public instrumental classical recording) |
| M | M | on | off | `lyrics@8;quit@60` (Smoke) |
| S, C2, C3 | SS, SC2, SC3 | on, off, off | off | `lyrics@8;style-probe:player@25;capture:style-lyrics-<on\|off\|off3>-player@26;next@30;style-probe:player2@55;home@58;style-probe:home@64;capture:style-lyrics-<state>-home@65;quit@70`; queued first so all three run in parallel |

**Frozen coverage tracks:** `dQw4w9WgXcQ, JGwWNGJdvx8, kJQP7kiw5Fk, 9bZkp7q19f0, fJ9rUzIMcZQ, YQHsXMglC9A, gdZLi9oWNZg, IHNzOHi8sJs, hT_nvWreIhg, 60ItHLz5WEA, RgKAFK5djSk, OPf0YbXqDm0, CevxZvSJLk8, pRpeEdMmmQ0, lp-EO5I60KA, DyDfgMOUjCI, ZRtdQ81jPUQ, oiKj0Z_Xnjc, W3q8Od5qJio, hcm55lU9knw`.

**Sampler:** runs every 0.5 s after `lyrics`. It records `currentTime`, paused, video id, the active `.blyrics--line` `data-time`, the next line's time, the line count, the first line's time, `.blyrics-container` `data-sync`, the count of `blyrics` elements, and a hash of the line texts, the count of lines with `data-time` and `<html lang>`. It also records a translated flag: any element whose class contains `translat` inside `.blyrics-container`.

**Options probe:** runs in the production lyric settings window, opened with `OpenLyricsSettingsAsync()` and read through `LyricsSettingsCore`. It records:
- `typeof` checks for the `chrome.*` APIs, including `chrome.alarms`;
- `navigator.serviceWorker.getRegistration()`;
- the presence and values of `#translate`, `#translationLanguage`, `#uiLanguage`, `#globalLyricOffset` and `#clear-cache`;
- the stored `isTranslateEnabled`, `translationLanguage`, `globalLyricOffset` and `uiLanguage`;
- storage key names;
- the nonces;
- a PNG capture.

## Rules (spike rules, same numbers)
1. **Load:** profile enumeration shows the extension `ogodmldcmpbfeekmejkeppchklblochl` enabled in R1 and R2. *Adapted:* production loads the extension, so the bench can no longer time the load against the first Music navigation.
2. **Lyrics:** `.blyrics--line` elements appear within **20 s** of the Lyrics-tab click, with `data-sync` other than none/unsynced/plain.
3. **Timing:** checked on each synced track, over eligible samples (playing, and more than 2 s away from any pause, seek, track change, nav or offset change). The active line time must be ≤ `currentTime` + 1 s, and the next line time > `currentTime` − 1 s, in at least **95 %** of samples. A missing active line counts as a fail. After each seek, the correct line must appear within **2 s**.
4. **Pause:** while paused, `currentTime` stays within **0.3 s** and the active line does not change.
5. **Track change:** the previous track's line hash is gone no more than **2 s** after the video id changes.
6. **Options:** the options page loads in the host-owned window, and its capture is larger than 10 000 bytes. R1's storage writes succeed, and R2 reads the same nonces. All five contract controls are present.
7. **Worker (inverted):** there is **no** service-worker registration (`getRegistration()` returns nothing).
8. **Containment:** none of these occur: a download, an external URI launch, `ProcessFailed` in either view, or a harness kill.
9. **Ad blocking on:** R2 meets rules 1–2 with Block ads on.

## Scenarios
| Scenario | Pass condition |
| --- | --- |
| Smoke | Rules 1–2 on M, and no `ProcessFailed`. M's hosts minus the hosts of control arm C (run in parallel, lyrics off) must be within {`api.betterlyrics.org`, `lrclib.net`, `a.nel.cloudflare.com`}; googlevideo shards are ignored. Blocked without C. |
| Core | Rules 1–9 above on R1/R2. |
| HostAllowlist | For each of R1, R2, I, T1 and T2: its hosts minus C's hosts must be within {`api.betterlyrics.org`, `lrclib.net`, `a.nel.cloudflare.com`}. T1 may also use `translate.googleapis.com`. `*.googlevideo.com` shards are ignored because they differ per track. Blocked without C. |
| Idle | I's final probe shows no service-worker registration, and `typeof chrome.alarms` is `undefined`. No new host appears more than 60 s after the anchor, except hosts also seen in C and googlevideo shards. |
| TranslateOn | The UI toggle leaves `#translate` checked with `#translationLanguage` = `de`. A translated element appears under lines within **10 s**. `translate.googleapis.com` is seen, and no other host beyond the lyric hosts (`api.betterlyrics.org`, `lrclib.net`, `a.nel.cloudflare.com`). |
| TranslateOff | T2 (after T1 turned translation off in the UI): the stored state is off, no `translate.googleapis.com` request, no translated elements, and lyrics are still shown. |
| SettingsPersist | S2 reads `translationLanguage` = `de` and `globalLyricOffset` = 1.5. In S1, the offset is applied live without a restart: measured from active-line changes, see **SettingsPersist offset** under Post-data amendments. The original first-line `data-time` rule could not see a clock offset. |
| Off | O1: the extension was never installed. P1: it loaded. O1, P2 and P3 show all of the following: no enabled extension, no navigation to the lyrics extension's id (amendment), no lyric host, and no `blyrics` elements. |
| NonEnglish | G starts on the Radio URI plus `hl=de`. Synced lyrics must appear for track A within 20 s of the tab click, and for track 2 (after Next). The sampled `<html lang>` must start with `de`; otherwise the scenario is **blocked** ("hl=de not honoured"). |
| NoLyrics | For `-NoLyricsTrack` (default `4Tr0otuiQuU`), all three must hold: no synced lines within 20 s of the `nav`; an honest empty state (amended: `data-no-lyrics="true"` appears, with at most the one not-found line while shown and no timed line otherwise); and at most **3** requests per lyric host within 60 s of the `nav`, counted as distinct NetLog sources of `URL_REQUEST_START_JOB` events for `getLyrics`, `/api/get` or `translate_a` URLs. If synced lines appear, the result is `fail` with the reason "track unexpectedly has synced lyrics". |
| Coverage | A track counts when synced lines (`data-sync` not none/unsynced/plain, lines > 0) appear within **20 s** of its `nav`. Passes at **≥ 16/20**. The report lists each track's result: synced, plain or none. |
| StyleIsolation | Added 28 Sep 2026 after the owner reported YouTube Music panel colour changes; added before its first data. `style-probe` records, in the main view, the computed `background-color`, `background-image`, `color`, `opacity`, `filter`, `backdrop-filter`, `border-color`, `font-family`, `display` and `visibility` of `html`, `body`, `ytmusic-app`, `#layout`, `ytmusic-nav-bar`, `#nav-bar-background`, `#guide-wrapper`, `#mini-guide-background`, `ytmusic-player-bar`, `#player-bar-background`, `ytmusic-player-page`, `#main-panel`, `#side-panel`, `tp-yt-paper-tabs`, the first 3 `tp-yt-paper-tab`, `ytmusic-player`, `#player`, `ytmusic-player-queue` and `#tab-renderer` (null while its `page-type` is `MUSIC_PAGE_TYPE_TRACK_LYRICS`); missing elements are null. It also records `html`/`body` classes and attributes, every `:root` custom property starting with `--yt`, and `chrome-extension://` stylesheet hrefs (evidence only). `home` clicks the Home guide entry. **Pass** iff, for each of `player`, `player2` and `home`, every probed value, element null-ness, `--yt*` property and the `html`/`body` classes and attributes are exactly equal between S and C2. **Exclusions:** none are fixed in advance; the only keys ignored are `html`/`body` *attributes* that also differ between C2 and C3 (two lyrics-off runs) for that probe; the report lists them under `ignoredVolatileKeys`. Computed properties, custom properties and classes are never excluded. The report lists every differing key with both values; captures are `style-lyrics-on-<name>.png` / `style-lyrics-off-<name>.png` in the report directory. Blocked when S or C2 lacks a probe. |

StyleIsolation exclusion (28 Sep 2026, before any StyleIsolation data; the first run was blocked with no probe data because the schedule parser dropped `style-probe`/`home`): before comparing, `--blyrics-*` declarations are removed from the html/body inline `style` attribute. `@braccato/core` (`engine.js`, a bundled dependency) writes `--blyrics-padding-top`/`--blyrics-padding-bottom` there. Only fork elements read them, and they cannot change YouTube Music's rendering. Nothing else is excluded.

StyleIsolation amendment **after** the first red run (28 Sep 2026, run `style-red/20260927T220149Z` on the unfixed fork `20a7f32`): `#tab-renderer` keys are dropped when either arm's tab renderer is on the lyrics page type. With lyrics on, that element hosts the fork's lyrics by design, and YouTube leaves the Lyrics tab disabled in the lyrics-off arm, so the two can't be compared. Re-analysed with this rule, that red run still fails: 20 player, 20 player2 and 11 home differences. They include `#guide-wrapper`, `#nav-bar-background`, `#mini-guide-background`, `#player-bar-background`, `#player`, `ytmusic-player(-bar)`, `html` class `no-focus-outline` with four `--ytmusic-*focus*` variables, and the `data-extjs-extension-base` attribute on `html`. The first report is kept as `report.first.json`.

Second amendment, after the first run on the fixed fork (`style-green/20260927T220422Z`), which left 10 differences per probe and no panel, background or player differences:
- (a) The `tp-yt-paper-tab[n]` colour keys fall under the same lyrics-page rule as `#tab-renderer`, because they only show which tab is selected.
- (b) `html` attribute `data-extjs-extension-base` is excluded by name. The extension.js bundler runtime writes it so MAIN-world scripts can find the extension URL; no CSS reads it.
- (c) The harness Lyrics-tab click now sends mousemove, pointerdown, mousedown, pointerup, mouseup and click at the tab's centre coordinates, as a real mouse click does. This applies to every arm. Reason:
  - YouTube Music's input-modality code (`music_polymer_inlined_html.js`, build `1dea707a`) starts in keyboard mode (no `no-focus-outline`). It switches to mouse mode (adds `no-focus-outline`) only on a window `click`/`mousemove` with `clientX`/`clientY` > 0.
  - The earlier `click()` had coordinates 0,0, so the class depended on the physical pointer position over each window.
  - Diagnostic run `style-diag/20260927T220920Z`: S lacked the class at 6 s, before any action, while C2 and C3 had it.
  - The fork has no mouse, keyboard or focus writes outside its own lyric elements.
- The remaining `html.no-focus-outline` and `--ytmusic-*focus*` differences are **not** excluded; they must match or the scenario fails.

`a.nel.cloudflare.com` rationale (pre-freeze amendment, 28 Sep 2026): it is Chromium's Network Error Logging endpoint, triggered by NEL headers on the Cloudflare-hosted `api.betterlyrics.org` responses, which the extension cannot control.

**Post-data amendments after the first full matrix (run `20260927T221658Z` on fork `78819c7`).** Each one fixes a harness defect that the evidence identified; no threshold changes.
- **Host baseline:** the union of all lyrics-off control arms (C, C2, C3); C must still exist.
- **Ad hosts:** `*.doubleclick.net`, `*.googlesyndication.com` and `*.googleadservices.com` count as page traffic only if the staged lyrics tree contains none of these names. The analyzer checks this and reports it as `bundleMentionsAds`.
  - Why: YouTube's own ads appeared at random in R1 and I and not in C.
  - Offline check: re-applying this rule to that run's `hosts.json` leaves only allowed lyric hosts, plus translate in T1.
- **Idle:** `a.nel.cloudflare.com` is not a "new host after minute 1". Chromium sends NEL reports late, for earlier `api.betterlyrics.org` requests.
- **Off:** `noExtensionNav` counts only navigation to the lyrics extension's id. Nativune opens uBOL's own page (`chbeldoehhanckmmpebanijlakhcafpl`) at every start, in every arm.
- **`nav` action:** a full navigation while playing raised YouTube Music's leave-page (`beforeunload`) prompt and blocked the page; in that run, Coverage and NoLyrics had only timeouts after their first `nav`, and no navigation started. The bench build now disables WebView2's default script dialogs on the Music view before its first navigation, logs every dialog as `lyrics-dialog`, and accepts only leave-page prompts. An in-page listener tried first did not stop the prompt.
- **NonEnglish:** the G arm starts with `--lang=de`, because YouTube Music ignored `hl=de` (`<html lang>` stayed `en`).
- **NoLyrics empty state:** upstream v2.4.1 and the fork render "not found" as one message line with `data-time` 0 (`lyrics.ts`, `startTimeMs: 0`) and mark the container `data-no-lyrics="true"` with sync `none`. The frozen "no line with `data-time`" rule described a different DOM. The rule is now: the marker appears within 20 s; while it is shown, at most that one line; without it, no timed line. "No synced lines" is unchanged.
- **Ads in timing checks:** each sample records `ad` (whether `ytmusic-player-bar[is-advertisement]` is present), and ad samples are not timing-eligible.
  - Why: during an ad the `<video>` element is the ad, and the fork, like upstream, skips highlighting (`lyricsHost.ts:33-40`, `engine.js:1824-1826`).
  - R1's track 2 in that run showed ad-like durations and time resets. Its line-synced path works in arm I (active line in 376/410 and 389/401 samples).
- **SettingsPersist offset:** the fork applies `globalLyricOffset` to the playback clock (`engine.js:1843`, `currentTime -= globalLyricOffset + lyricOffset`) and never rewrites `data-time`, so the old `data-time` check could not see it.
  - **Estimator:** each forward active-line change between consecutive non-ad samples p and s (at most 1.5 s apart, not within 3 s of any other action including options-window events) bounds the engine's lead to `[activeTime - s.t, activeTime - p.t)`. Intersecting these gives the lead before the change and the lead minus the offset after it, and hence a shift range.
  - **Pass:** at least 3 changes per side, and the **whole** range lies within 1.5 s ± 0.25 (same tolerance). An empty intersection fails.
  - **History:** a first version used the difference of midpoint medians. It gave 1.419 s on run `20260927T221658Z` and then 1.226 s on run `20260927T230031Z`. With 0.5 s sampling and 9–12 changes it is biased, and options-window events contaminated the before window. The exact bounds give [1.395, 1.687] and [1.274, 1.629] on those runs.

**Not covered:**
- signed-in or Premium playback;
- real ads;
- traffic after 10 minutes;
- Narrator and high contrast (the manual Accessibility checklist);
- the release build (`ProductionBuild`).

## Regenerate
```
dotnet build src/Nativune -c Release -p:PerfBenchHooks=true -o .cache/build/lyrics-e2e
pwsh -NoProfile -File scripts/lyrics-e2e.ps1 -Scenario All -OutputDirectory artifacts/lyrics-e2e
```
Output: `artifacts/lyrics-e2e/<stamp>/report.json`, with `summary.json`, `hosts.json`, `config.json`, `*.bench.jsonl`, `*.lyrics.log` and PNG captures. The exit code is nonzero if any selected scenario fails or is blocked. To re-analyze kept raw data: `python scripts/lyrics-e2e-analyze.py artifacts/lyrics-e2e/<stamp> .cache/lyrics-e2e/runs/<stamp>` (needs `-KeepRaw`).
