# Roadmap

This roadmap names areas for future work; it is not a release schedule or a promise.

## Near term

- Add Authenticode signing for the installer.
- Validate installation on clean Windows systems and establish a supported installation matrix.
- Measure long-session stability and complete-process resource use. A short benchmark (`scripts/bench-perf.ps1`) exists; long sessions and signed-in use are not yet measured.
- Review accessibility, keyboard and screen-reader use, and high-contrast appearance.

## Planned features

- **OBS overlay.** Released in 0.1.34 as an early preview, so it will change: themes, options and the designer's preview CPU use are still being improved. It is an optional "now playing" overlay that OBS Studio adds as a Browser source, showing the current song, artist, artwork and progress. It is served only on this PC, off by default (Settings › OBS), and shares only the song details the Discord status already reads. See the [setup guide](docs/obs-overlay.md).
- **Time-synced lyrics.** Implemented as Barebones Better Lyrics, a GPL-3.0 fork of [Better Lyrics](https://github.com/better-lyrics/better-lyrics) 2.4.1 stripped to synced lyrics and translation, shipped separately from the MIT app with its source beside each release. On by default (Settings › Lyrics turns it off); released in 0.1.32.

## Known limitations

- Compatibility depends on YouTube Music's public website UI, which may change.
- The installer is unsigned; SmartScreen may continue to warn about new releases until reputation is established.
- Nativune has no native audio backend; playback remains hosted by the official website.

## Non-goals

- Downloading media
- Blocking ads by default (an opt-in, off-by-default setting exists)
- Using private playback APIs
- Collecting credentials
