# Project instructions

## Start here

Read `plan.md` before planning, setup, implementation, or changing scope. It owns the product requirements, evidence, proposed architecture, and acceptance gates.

Current authorization covers research, documentation, completed Google Cloud OAuth setup, folder-local .NET tooling, the OAuth/read-only library experiment, Windows media-session feasibility, and the minimal embedded WebView2 compatibility experiment in `plan.md`. The owner handles Google sign-in and consent. The embedded experiment may use one native window, a folder-local Fixed Version runtime and an isolated profile; it does not establish Google support. Full UI, extensions, unofficial extraction, sign-in bypasses, global installs, billing activation and production deployment remain outside scope.

This file uses the lowercase name requested by the user. On case-sensitive systems, agents must load it explicitly if their runner only discovers `AGENTS.md`; do not maintain a duplicate instruction file.

## Workspace boundary

- Keep project-owned source, downloaded tools, dependency caches, temporary files, runtime binaries, application data, logs, research, and build outputs under this repository root, currently `D:/youtube`.
- Resolve paths from the project or executable location, not the caller's working directory. Use the directory purposes in `plan.md`; create directories only when needed.
- Before running an installer or package manager, configure its download, cache, home, and temporary paths locally. Use process-local environment variables and PATH changes.
- Do not install global tools, change machine settings, add services/startup tasks, or write project state to user-profile directories without explicit approval. If a prerequisite cannot meet this boundary, report the exact exception before proceeding.
- Existing operating-system facilities and the agent harness are external prerequisites, not project-owned files. Do not promise that Windows, browser sign-in, or cloud configuration leaves no external state.
- Keep credentials, browser profiles, caches, tool downloads, and build outputs out of version control. Do not delete user data as build cleanup.

## Authentication and playback

- Treat sign-in, account/channel selection, library access, Premium entitlement, and playback as separate capabilities. Demonstrate each before calling it supported.
- Use supported Google authorization flows. Never collect passwords, import browser cookies, spoof user agents to evade sign-in restrictions, or substitute another project's OAuth client identity.
- A Google OAuth token does not create a YouTube Music web session or grant a documented native audio-stream API. Keep the feasibility gates in `plan.md` intact.
- Preserve service restrictions and branding requirements. Do not add stream extraction, ad blocking, downloads, or unofficial private API dependencies to make a failed gate appear to pass.
- Keep remote web content isolated from native file, process, and credential access. Validate origins and any native messages; expose only the capability actually needed.
- Exclude passwords, tokens, cookies, authorization headers, and private library contents from logs and research artifacts. Use supported OS-backed protection for sensitive persisted state; disclose account/machine portability limits.

## Engineering

- Prefer existing code, standard libraries, and native controls before dependencies. Add the smallest working change after tracing the affected flow.
- Keep the proof of concept in one application project. Introduce another module, database, backend, plugin system, or platform only for a demonstrated requirement.
- Study competitor behavior and architecture as inspiration. Write original code and assets. Record source links and license obligations before using any third-party dependency.
- Fix shared root causes rather than patching individual screens. Preserve accessibility, error handling, and security even when simplifying.
- Separate research facts, author claims, proposed targets, and measured results. Never turn download size or one process's memory into a total-resource claim.

## Verification and delivery

- Check the actual changed behavior: launch the app for UI/runtime changes, exercise account transitions and playback for integration changes, and keep a focused regression check where a plausible bug warrants it.
- Measure the entire app process tree, including WebView2 children, using the comparison procedure in `plan.md`.
- Stop at a failed feasibility gate. Record evidence and the decision required; do not silently replace native playback, synced library features, or folder-local setup with a weaker substitute.
- Update `plan.md` when decisions or gate outcomes change. Mark unrun checks explicitly. Report files changed, checks actually run, and remaining blockers briefly.
