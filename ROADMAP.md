# Roadmap

This roadmap names areas for future work; it is not a release schedule or a promise.

## Near term

- Add Authenticode signing for the installer.
- Validate installation on clean Windows systems and establish a supported installation matrix.
- Measure long-session stability and complete-process resource use.
- Review accessibility, keyboard and screen-reader use, and high-contrast appearance.

## Known limitations

- Compatibility depends on YouTube Music's public website UI, which may change.
- The installer is unsigned; SmartScreen may continue to warn about new releases until reputation is established.
- Nativune has no native audio backend; playback remains hosted by the official website.

## Non-goals

- Downloading media
- Blocking ads by default (an opt-in, off-by-default setting exists)
- Using private playback APIs
- Collecting credentials
