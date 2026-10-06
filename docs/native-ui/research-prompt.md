# Research brief: a native-UI YouTube Music client for Windows ("Plan A")

You are being handed an architecture idea to research, stress-test and improve. Treat the plan below as a hypothesis, not a decision. **If you disagree with any part of it, say so plainly, explain why, and propose something better.** Agreement without evidence is not useful; a well-argued "this is the wrong approach" is.

---

## 1. Context

**Project:** Nativune, an unofficial, open-source (MIT) Windows desktop app for YouTube Music. Repo: https://github.com/Hantu-Raya/Nativune

**Stack today:** C# on .NET 10, WinUI 3 (Windows App SDK 2.5.1), Microsoft Edge WebView2 (shared Evergreen runtime). Windows 10 2004+ and Windows 11, x64.

**How it works today:**
- The official `https://music.youtube.com` website runs inside a single isolated WebView2. The user signs in to Google inside that view, so the website's own session handles the account, Premium, ads and playback.
- Native features wrap the page: a native **Compact mini player** (artwork, title, seek bar, play/pause/next/previous, like/dislike, playlists menu, repeat, shuffle, volume), tray icon, taskbar buttons, pause timer, equalizer, Discord status, an OBS "now playing" overlay and time-synced lyrics.
- Native controls drive the page by running small scripts against the page's **public UI and media element** (`CoreWebView2.ExecuteScriptAsync`), with timeouts and fail-closed behaviour. The web→native message bridge is **disabled** (`IsWebMessageEnabled = false`, `AreHostObjectsAllowed = false`) and navigation is restricted by exact-origin checks.

**Project rules the plan must respect** (from the repo's README, ROADMAP and agents.md). Challenge them if you think one should change, but say so explicitly and don't quietly design around them:
- Non-goals: downloading media, **using private playback APIs**, collecting credentials, blocking ads by default.
- The owner does Google sign-in and consent; the app never sees a password, never evades sign-in and never substitutes another OAuth identity.
- "OAuth tokens establish neither a Music web session nor native streaming access." Sign-in, channel selection, library, Premium and playback must each be verified separately.
- Keep remote content isolated from native file, process and credential access. Keep the disabled native bridge and exact-origin validation.
- Keep **one application project**; add architecture or dependencies only for a demonstrated need.
- Performance claims must count the complete process tree, including WebView2 child processes.
- Testing is E2E against the real native app (scripted runs on disposable profiles), producing a repeatable artifact.

## 2. The goal

The owner wants a client that **feels fully native**, inspired by Spotifast (https://github.com/crmne/spotifast, a Rust/egui Spotify client using Spotify's official Web API plus librespot for audio, with no browser engine). The user should browse **Home recommendations, Library, playlists, albums, artists, search and the queue** in native WinUI screens, with every existing Nativune feature still working, and without looking at the website.

### What earlier research found (verify; don't just trust it)
- No librespot equivalent exists for YouTube Music. Native playback needs stream extraction, **PO tokens** (BotGuard attestation, which needs a real JS engine and DOM) and increasingly the **SABR** streaming protocol. All of these break often. In September 2026 the most popular token provider (bgutil-ytdlp-pot-provider) shipped 2.0.0 as a mandatory RCE fix (GHSA-qpv9-8xfj-xx9m).
- Spotify has an official Web API covering library, playlists and recommendations. YouTube's official **Data API v3** covers playlists, ratings, subscriptions and search, but **not** YouTube Music home recommendations, radio/Up Next, or YouTube Music library shelves. It also has a tight shared quota (about 10,000 units/day per project; one search costs 100). YouTube's API policies forbid separating audio from video.
- Spotifast's own docs don't claim legality. They say the developers "are not aware of" bans and "cannot guarantee" Spotify's decisions. It is a tolerated position, not a permitted one.
- **Kaset** (https://github.com/sozercan/kaset), a native Swift/SwiftUI macOS client, uses a native UI and keeps **one hidden WebView** for playback, citing Widevine DRM for Premium content. **SimpMusic** (Kotlin/Compose Multiplatform) is fully native, using Innertube for metadata and NewPipeExtractor for audio.

## 3. The plan to evaluate: Plan A, "native shell, hidden official player"

**Core idea:** keep the official website as the *engine* (session, Premium, ads, DRM, playback) and replace it as the *interface*. Every surface the user sees is native WinUI; the WebView2 becomes an off-screen player that native screens command.

### A1. Playback engine
- Keep the existing WebView2 and its signed-in profile, but host it **out of view** (collapsed, off-screen or zero-size; to be determined) in "native mode".
- Native screens start playback by **navigating the hidden page to public URLs** (`/watch?v=…&list=…`, `/playlist?list=…`, `/browse/…`), then use the existing `PlayerControls` command path. The page's own Up Next queue is the queue of record.
- Put an `IPlaybackEngine` interface (play item, pause, seek, next, queue read, state events) in front of it, so a future native audio engine could replace it without touching UI code. The only implementation now: `HiddenWebViewEngine`.

### A2. Sign-in
- **Keep Google sign-in inside the WebView2.** It creates the Music web session that actually plays, and the project rules say OAuth tokens don't create one. Show the view in a dedicated one-time "Sign in" sheet, then hide it.
- **Decided: no Google OAuth client and no bring-your-own-key (BYOK) option.** The owner doesn't want to register with Google, go through OAuth verification (Google caps unverified sensitive-scope apps at 100 new users in total and shows an "unverified app" screen), file YouTube API quota requests or audits, or ask users to create their own Google Cloud projects. Signing in to the website gives a Spotifast-like one-click experience without any of that. Spotifast itself relies on a developer-registered shared Spotify app with an optional personal-app (BYOK) path. Challenge this decision only if a must-have feature can't be built without the official API.

### A3. Data for native screens (the most contested part, so rank these)
1. **Read what the page already shows:** parse the rendered DOM, or the page's initial data, for shelves, playlists and queue. Read-only, and it stays within the current "public UI" approach. Fragile when the UI changes, and it requires navigating the hidden page to each screen.
2. **Observe the page's own network responses** (e.g. `CoreWebView2.WebResourceResponseReceived` on `youtubei/v1/browse|next|search`) and render them natively. Structured and read-only, but couples the app to private response formats.
3. **Issue the same internal (Innertube) calls from inside the page's context.** Most flexible (paging, search-as-you-type, radio), but this is actively using a private API. Does that break the project's "no private playback APIs" non-goal, given these are *data*, not playback endpoints?
4. **Official Data API v3 via OAuth** in the system browser. Compliant, but it's a second identity, has a quota, and lacks recommendations and radio. **Ruled out for now** (see A2); include it only as a comparison baseline.

### A4. Free vs Premium
- Proposed: **native mode requires YouTube Music Premium** (as Spotifast requires Spotify Premium). Free accounts keep the current visible website. Reason: on the free tier, hiding the page hides the ads, which likely conflicts with YouTube's terms and with the project's ad-blocking stance.
- Optional: in native mode, if an ad is detected, show the website surface until the ad ends.

### A5. Escape hatch
- A permanent **"Show website"** toggle for anything not built natively (account settings, uploads, comments, podcasts, edge cases), and as a fallback when a native screen fails to parse.

### A6. Rollout
- **Phase 0, feasibility gates (stop if any fail):**
  - Hidden WebView2 keeps playing reliably for 8+ hours: no throttling, no suspension, gapless, media keys and SMTC still work.
  - Navigation-to-play works for songs, albums, playlists and radio.
  - Data path chosen and proven for Home and Library.
  - Process-tree memory and CPU measured against today's visible mode with `scripts/bench-perf.ps1`. Proposed targets (private working set, full process tree): **under 150 MiB while just listening** and **under 200 MiB while browsing native screens**. Today's baseline: 348 MiB in full view and 124 MiB hidden to the tray, both playing (README, v0.1.28). Estimated Plan A range: about 130–150 MiB listening and about 170–250 MiB browsing, rising toward 300+ MiB if the hidden page must load each screen to get its data.
- **Phase 1:** Library, Playlist/Album detail and Now Playing + Queue, native, plus the escape hatch.
- **Phase 2:** Home recommendations, search, artist pages, radio.
- **Phase 3:** Polish: offline metadata cache, keyboard and screen-reader pass, theming.

Expectation to verify or refute: the WebView2 still runs, so the savings are modest. Plan A should use less than today's visible full view but no less than today's hidden-to-tray state, and only if the native screens get their data without making the hidden page render each screen. The main win is UX and native integration, not RAM.

## 4. What I want from you

Work through these, citing primary sources (docs, source code, issue trackers, changelogs) with dates. Label each point as **verified fact**, **reported by others** or **your hypothesis**.

**Technical feasibility**
1. WebView2 hidden-player behaviour: what does `CoreWebView2Controller.IsVisible = false`, a collapsed WinUI `WebView2`, or an off-screen window actually do to timers, media playback, autoplay policy, `TrySuspendAsync`, Memory Usage Target Level and background throttling? Is there a supported way to keep media playing reliably while not visible? Cite Microsoft docs and Chromium behaviour.
2. Does YouTube Music's web player behave differently when not visible (Page Visibility API, "Are you still listening?" prompts, Premium background play vs free-tier pausing)?
3. Is the Widevine/DRM claim for YouTube Music Premium audio correct? Which content, if any, is DRM-protected on the web?
4. Compare data paths A3.1–A3.4 on stability over the last 12 months (how often each broke for projects like ytmusicapi, YouTube.js, Kaset, SimpMusic, Pear Desktop/th-ch, ytmdesktop), effort, latency and policy risk. Recommend one, or a hybrid.
5. How does Kaset map native screens to its hidden WebView (queue sync, gapless, state)? What can be learned or reused (respect its license)?
6. WinUI 3 specifics: virtualized lists for 5,000-track playlists, artwork caching, SMTC integration when the WebView isn't visible.

**Policy and risk**
7. Read the current YouTube Terms of Service, YouTube API Services Terms and Developer Policies, and YouTube Paid Service Terms. Which parts of Plan A (hidden player, DOM parsing, response observation, in-page Innertube calls, Premium-only native mode) are clearly allowed, clearly prohibited, or grey? Quote the exact clauses.
8. Has Google taken action (takedowns, account bans, API key revocations) against wrapper or third-party YouTube Music clients in 2024–2026? List concrete cases.
9. Is "native mode requires Premium" enough to address the ad-visibility concern, or is there a better design?

**Product**
10. What would users lose compared with the visible website, and is it worth it? What would they gain that they can't get today?
11. Are there better alternatives I haven't considered? Examples: improving the existing visible mode instead, a "theater" layout that restyles the page, contributing to an existing client, or something else entirely.

## 5. Deliverables
1. **Verdict:** agree, agree with changes, or disagree, in one paragraph with your top 3 reasons.
2. **Revised plan:** your version of sections A1–A6, with every change marked and justified.
3. **Risk register:** risk, likelihood, impact, mitigation and an early signal to watch.
4. **Feasibility-gate test designs:** for each Phase 0 gate, an E2E test against the real app with a pass/fail threshold and the artifact it produces.
5. **Open questions** only the project owner can answer.
6. **Sources:** every URL you relied on, with the date you accessed it.

## 6. Ground rules
- Don't propose anything that collects passwords, evades sign-in, downloads media, strips DRM or blocks ads by default. If you think a fully native audio path (Plan B: extraction + PO tokens + libmpv) is better, argue for it, but cover its legal and maintenance cost honestly.
- Prefer primary sources over blog summaries. Flag anything you couldn't verify.
- Be concrete: name APIs, classes, settings, file formats and versions.
- Disagreement is welcome. If Plan A is a bad idea, the most useful thing you can do is explain why.
