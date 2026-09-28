# Security policy

## Supported versions

Only the latest [release](https://github.com/Hantu-Raya/Nativune/releases/latest) gets security fixes. Nativune checks for updates itself; please update before reporting.

## Reporting a vulnerability

Do not open a public issue. Report it privately through [Report a vulnerability](https://github.com/Hantu-Raya/Nativune/security/advisories/new) on the Security tab; only the maintainer can read it.

Include:

- the Nativune version and install type (Settings > About)
- what an attacker can do, and the steps to reproduce it
- any proof of concept, logs or screenshots

Leave out passwords, cookies, authorization headers, account details, and private library or listening history.

The maintainer aims to reply within a week. Nativune is maintained by one person in their spare time, so fixes may take longer; you'll be kept updated in the report.

## Scope

In scope: the Nativune app, its installer and updater, and the release and package-manager files in this repository. This includes breaking the app's boundaries: web content reaching native files, processes or credentials, navigation outside the allowed sites, or tampered updates being accepted.

Out of scope: YouTube, YouTube Music and Google services themselves. Report those to [Google](https://bughunters.google.com/).
