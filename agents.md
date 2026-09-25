# Project workflow

## Find the relevant context

For planning, setup, implementation or scope changes, read [Current state](notes/plan.md#current-state) first, then follow its task-specific links. `notes/` is a private, git-ignored maintainer clone; public contributors without it should follow README and ROADMAP. `notes/plan.md` owns product decisions and evidence; this file owns execution. A wording-only correction needs only its surrounding text. Historical approvals apply to their stated task, not every future run. If current instructions conflict with a recorded decision, resolve the affected boundary before acting.

Keep this filename lowercase. Runners that discover only `AGENTS.md` must load `agents.md` explicitly rather than create a duplicate.

## Complete the requested work

For substantive work, define the result, affected behavior and completion evidence before editing. Use the request and existing acceptance criteria; ask only for a missing decision that changes scope, risk or user experience. Trace the affected flow, then prefer existing code, standard libraries and native controls. Keep one application project; add architecture or dependencies only for a demonstrated need. Preserve accessibility, security and failure handling.

Within an authorized task, continue through implementation, focused verification and fixes without stopping for approval at each local step. Delegate only independent work with clear file ownership and shared interfaces; one integration owner checks the combined result. A failed feasibility gate stops dependent work, not unrelated authorized work. Report the missing decision rather than substitute a weaker feature.

Choose evidence for the change. Documentation needs consistency/link checks, not an app launch. Code follows [Test](#test); UI/runtime changes need the actual native app. Account or playback checks require the appropriate authorized session. Owner-reported outcomes stand as reported evidence; distinguish them from independently observed results.

Finish with changed files, checks actually run and remaining blockers. Remove temporary instrumentation, preserve user work and update the current-state index plus relevant decision record when an outcome changes. A partial run is not a passed gate.

## Test

- Never write unit tests after you write code.
- Highly prefer E2E tests as the sole testing mechanism. Use them to verify complex features work. At the end of an E2E test, produce a verifiable and repeatable artifact (for example a JSON report or screenshots under `artifacts/`, plus the exact command that regenerates it).
- If you must test a system in isolation, first write down all the ways it could fail, then write the code.

E2E here means driving the actual native app: `scripts/probe.ps1 native-fixture`, `output-audio-fixture`, or a scripted run on a disposable profile under `.cache/`. Tests exist to catch plausible behavioral failures, not to prove that code ran.

## Keep project state local

Keep project-owned tools, downloads, dependencies, caches, temporary files, runtime/profile data, logs and outputs under this repository. Resolve paths from the project or executable, not the caller's directory. Use the existing local launchers and [Folder plan](notes/plan.md#folder-plan) for setup/environment details. Configure package-manager paths before invocation; PATH and environment changes are process-local.

Credentials, profiles and generated files stay out of version control. User data is not build cleanup. Windows facilities, the existing harness and browser/cloud state are external prerequisites, not proof of zero external writes. New global installs, machine settings, services/startup tasks or outside-root writes need explicit approval for the exact exception. Prior exceptions are not general permission. Commit, push, publishing, billing and deployment require the corresponding user request.

## Protect accounts and playback

The owner performs Google sign-in and consent. No password collection, sign-in evasion, substituted OAuth identity, downloads or ad blocking.

Keep remote content isolated from native file, process and credential access. Preserve exact-origin validation and the disabled native bridge. Existing public-UI commands target the owned view, fail closed and do not automatically retry or switch players. Their compatibility is not a documented Google playback API.

Use supported OS-backed protection for sensitive persisted state and disclose account/machine portability limits. Exclude credentials, cookies, authorization headers and private library/listening contents from logs and research. Verify sign-in, channel selection, library, Premium and playback separately; OAuth tokens establish neither a Music web session nor native streaming access.

## Keep instructions small

Use task prompts to state the outcome, constraints, evidence and stopping boundary, not a tool-by-tool itinerary. Add a skill only for reusable task-specific knowledge; give it a short, narrow trigger and disclose branch-specific guidance through links. Keep each rule in one place, and remove stale or conflicting guidance when decisions change. Repository instructions do not override system/tool rules or modify global skills.

Record dependency sources and license obligations before adoption. Keep research claims, hypotheses and measured results distinct. For performance work, follow the linked workload protocol and count the complete process tree, including WebView2 children and separately identified launchers; host-only memory and download size are not total resource use.
