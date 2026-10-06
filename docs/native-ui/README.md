# Native UI exploration (Plan A)

Status: **research, not a decision.** Nothing here changes how Nativune works today. This folder records an exploratory discussion (6 October 2026) about giving Nativune a fully native interface. It also holds the brief handed to another AI model for independent research and criticism. The research response will be reconciled here before any code changes.

- [research-prompt.md](research-prompt.md): the self-contained research brief to paste into another model.
- Research response: _pending_.

Claims below are labelled where it matters: **verified** (checked against a primary source or this repo), **reported** (from third-party issues, docs or articles found in searches) or **estimate** (reasoning, not measured).

## 1. Starting question

Is there a [librespot](https://github.com/librespot-org/librespot)-style library for YouTube Music, so Nativune could drop WebView2 entirely? The inspiration was [Spotifast](https://github.com/crmne/spotifast), a native Rust/egui Spotify client with no browser engine.

## 2. Findings

### No librespot equivalent exists for YouTube Music
- Playing YouTube audio outside the website needs stream extraction plus **PO tokens** (proof-of-origin tokens from BotGuard, which needs a real JS engine and DOM), and increasingly the **SABR** streaming protocol. *(reported)*
- yt-dlp now needs an external JS runtime such as Deno for full YouTube support ([yt-dlp #15012](https://github.com/yt-dlp/yt-dlp/issues/15012)). *(reported)*
- **8 September 2026:** bgutil-ytdlp-pot-provider 2.0.0 shipped as a mandatory fix for an RCE (GHSA-qpv9-8xfj-xx9m) in its local token server, which now binds to localhost by default ([release](https://newreleases.io/project/github/Brainicism/bgutil-ytdlp-pot-provider/release/2.0.0)). Music Assistant broke while the versions were mismatched ([#6326](https://github.com/music-assistant/server/pull/6326), [#6390](https://github.com/music-assistant/support/issues/6390)). *(reported)*
- SABR + PO token failures were still open in that period ([bgutil-rs #108](https://github.com/jim60105/bgutil-ytdlp-pot-provider-rs/issues/108), [yt-dlp #14390](https://github.com/yt-dlp/yt-dlp/issues/14390)). *(reported)*

### Libraries surveyed
| Project | Language | Notes |
|---|---|---|
| [YouTubeMusicAPI](https://github.com/IcySnex/YouTubeMusicAPI) | C# | 3.0.10 (17 July 2026); v4 rewrite planned with playback support, not shipped *(reported)* |
| [YouTubeSessionGenerator](https://github.com/IcySnex/YouTubeSessionGenerator) | C# + Node | PO tokens/visitorData; last release 1.0.3, 19 December 2025, so stale *(reported)* |
| [YoutubeExplode](https://github.com/Tyrrrz/YoutubeExplode) | C# | 6.6.0; avoids 403s by switching to clients that don't need PO tokens yet ([#933](https://github.com/Tyrrrz/YoutubeExplode/issues/933)) *(reported)* |
| [RustyPipe](https://docs.rs/rustypipe) | Rust | Full Innertube client with YouTube Music support; SABR work in progress *(reported)* |
| [YouTube.js](https://github.com/LuanRT/YouTube.js) + [BgUtils](https://github.com/LuanRT/BgUtils) | TS/JS | Most active on PO tokens and SABR (v18.x, 2026) *(reported)* |

### Comparable apps
- **[SimpMusic](https://github.com/maxrave-dev/SimpMusic)** (Kotlin/Compose Multiplatform): fully native, Innertube metadata, NewPipeExtractor audio. *(reported)*
- **[Kaset](https://github.com/sozercan/kaset)** (Swift, macOS): native UI with **one hidden WebView for playback**, citing Widevine DRM for Premium content ([playback.md](https://github.com/sozercan/kaset/blob/main/docs/playback.md)). The closest model for Plan A. *(reported)*
- **youtube-music-native** (C#/WPF): mpv + yt-dlp, no browser. *(reported)*

### What Spotifast actually relies on *(verified from its docs)*
1. Spotify's **official Web API** through a developer-registered **shared app**, plus an optional user-supplied "personal app".
2. **librespot** for audio, Premium only, through Spotify's normal DRM.
3. A legal position that is **tolerated, not permitted**. Its FAQ says the developers are "not aware of any confirmed account bans" and "cannot guarantee Spotify's future decisions."

YouTube has no equivalent split. The official **Data API v3** covers playlists, ratings, subscriptions and search, but not YouTube Music home recommendations, radio or library shelves. Its policies forbid separating audio from video, and there is no sanctioned native audio path.

## 3. Options considered

| | Approach | Verdict |
|---|---|---|
| **A** | Native WinUI screens + **one hidden official WebView2 player** | **Chosen for research** |
| B | Fully native: extraction + PO-token sidecar + libmpv (SimpMusic style) | Possible, but frequent breakage, ToS and takedown risk, and it reverses the README's "no private playback API" stance |
| C | Official APIs only | Compliant, but no recommendations or radio, and the official player is still a web embed |

## 4. Decisions so far

- **Sign-in stays inside WebView2** (the website's own Google sign-in, shown once in a sign-in sheet, then hidden). It creates the Music web session that actually plays. Per agents.md, OAuth tokens don't create one.
- **No Google OAuth client and no BYOK.** Without verification, Google caps sensitive-scope apps (the `youtube` scope) at **100 new users in total** and shows an unverified-app screen ([Google Cloud help](https://support.google.com/cloud/answer/7454865)). Verification removes both, but needs a verified domain, a privacy policy, scope justifications and usually a demo video. The **Data API quota** (about 10,000 units a day per project, shared by all users; one search costs 100) is separate, and raising it means a YouTube compliance audit. BYOK (each user makes their own Google Cloud project) avoids all of that but is too much hassle. Spotifast's simplicity comes from its developer registering a shared app once. Plan A gets the same one-click sign-in with no registration. *(policy facts reported from Google docs)*
- **Never borrow Google's own client IDs** (e.g. the YouTube TV client). agents.md forbids a substituted OAuth identity, and Google blocked yt-dlp's use of it in late 2024. *(reported)*
- **Native mode would require Premium** (proposal). On the free tier, hiding the page hides the ads.
- **"Show website" stays available** as an escape hatch.

## 5. Plan A outline

Full detail is in [research-prompt.md](research-prompt.md) §3.

- `IPlaybackEngine` → `HiddenWebViewEngine`: the existing WebView2 hosted out of view. It plays by navigating to public URLs and reuses the `PlayerControls` command path (`ExecuteScriptAsync` against the public UI; the web-message bridge and host objects stay disabled).
- **Data for native screens (open question).** Options: (1) read the rendered page, (2) observe the page's own `youtubei/v1/*` responses, (3) make internal calls from inside the page's context, (4) official Data API (ruled out). Whether (2) or (3) conflicts with the "no private playback APIs" non-goal is for the owner to decide.
- **Phases:** 0. feasibility gates (hidden playback for 8+ hours, navigation-to-play, data path, memory); 1. Library, playlist/album and Now Playing + queue; 2. Home, search, artists, radio; 3. polish.

## 6. Memory

Baseline from the README (full process tree, private working set, median, while playing): **348 MiB** in full view and **124 MiB** hidden to the tray (v0.1.28). *(verified in repo)*

| Plan A state | Estimate |
|---|---:|
| Just listening (Compact or tray) | ~130–150 MiB |
| Browsing native screens | ~170–250 MiB |
| Worst case: hidden page loads each screen for data | 300+ MiB |

For comparison, Spotifast reports 100–250 MB. Plan B might save another 50–100 MiB, but adds a JS runtime sidecar and libmpv. *(estimates)*

Proposed Phase 0 targets: **under 150 MiB listening** and **under 200 MiB browsing**, measured with `scripts/bench-perf.ps1` extended with a Plan A mode.

## 7. Next steps

1. Run the brief through another model; paste its response here and reconcile it.
2. Owner decisions: the data path (A3), Premium-only native mode, and whether the README and ROADMAP non-goals change.
3. Phase 0 prototype on this branch, only after the above.

This is not legal advice.
