# CodexSwoop 1.0.0 RC 3 validation

Candidate **1.0.0 (6)**, planned **v1.0.0-rc.3**. This is a draft candidate,
not acceptance of real profile switching. See [acceptance and recovery](RC_3_ACCEPTANCE.md).

## Diagnosis and change

The installed RC 2 has a semantically valid pending journal and consistent watermark,
revision 3, with launch and activation evidence. Current boot/catalog/build match,
but the recorded activation receiver has been replaced. This is genuine unresolved
recovery; the original failure reason is not persisted. No false initialization
cause or historical activation success is claimed. Real metadata and official
processes were not modified. Current recovery remains blocked.

RC 3 distinguishes journal access/format/conflict/legacy errors and boot/target
replacement failures, retaining the exact failed proof in Details. It bounds the
menu using the actual status button and current screen visible frame. SwiftUI
ViewThatFits keeps normal menus compact and selects an outer ScrollView when needed;
the existing profile scroller remains. Display/backing-scale changes recalculate
the height budget. The compact footer includes the detected Codex version.
No proof requirement, journal schema, version-update compatibility policy, identity
or Usage gate is weakened. Fresh-store behavior was already correct and is now
explicitly covered with preserved unused environment directories and two profiles.

## Local checks

- One `./scripts/check.sh --require-xctest`: **PASS**, including
  `./scripts/check-xcode.sh`; it was not invoked again separately.
- **535 CoreChecks**, **110 SwiftPM XCTest**, **110 native XCTest**,
  **101 IsolationLab Python** tests: zero failures.
- **43 targeted durable-opening checks**: PASS. The existing self-process generation
  fixture now obtains its exact kernel executable path rather than guessing macOS
  tmp-alias spelling. Production exact-path/generation validation is unchanged.
- **18 ReleaseTooling regressions**: PASS.
- **222 final offscreen UI renders**, EN/RU/UZ-Latn and light/dark: PASS.
  Small-screen geometry and actual scrolling to warnings/Check Again/Quit are checked.
  The rendering harness attaches hosts to disposable hidden AppKit windows; this
  prevents the former windowless outer ScrollView from producing blank screenshots.
- Native universal Debug/Release and Archive: PASS. Disposable copies passed ad hoc
  hardened-runtime signature checks. SwiftPM candidate is arm64-only.
- Localization, resources/icons, project/plist/shell checks, worktree/index privacy
  scans and `git diff --check`: PASS.

Validation host: Apple Silicon, macOS 27.0.1, Xcode 27.1, Swift 6.4, SDK 27.0.
Sonoma runtime, clean-machine, real installed RC 3 UI, multi-monitor/scale runtime,
live accessibility, and real lifecycle Part B: **NOT YET VERIFIED**. No official
Codex was launched, activated, closed or restarted by development/QA commands.
Automated success does not make the real pending store usable.

## Exact artifact and inputs

- DMG: `CodexSwoop-1.0.0-rc.3-macos-arm64-unnotarized.dmg`.
- DMG SHA-256: `e529f0f349e287f84137eaa6ebc47c43218654996334f49499e01f489ca68285`.
- Executable SHA-256: `a5d8a1d5ae73c75a9bcac939ec93d4c012a4345a69b7aa646b2e30451f5ea75e`.
- Canonical app manifest SHA-256: `9b8bd1a37bd1371c03023738eebc3b68aa98638eff7909d8daec08579486c116`.
- [Source/build/test inputs](RC_3_BUILD_INPUTS.json): 130 files,
  SHA-256 `de98d253dba13d63a67ffdaae5f46503b68207858bc521b76639b77ce02b4b1a`; docs excluded to avoid circular hashes.
- Bundle ID `io.github.cbrwvy.codexswoop`, version 1.0.0, build 6, arm64-only,
  minimum macOS 14.0, SDK 27.0: verified.
- App deep/strict ad hoc signature, DMG strict ad hoc signature, `hdiutil verify`,
  read-only mounted content allowlist, Applications symlink, mounted/source app
  manifest equality and exact SHA-256 sidecar: **PASS**.

Candidate packaging reuses the full pipeline's arm64 SwiftPM Release bundle; no
redundant application build was run for packaging. Existing local-preview tooling
was used, followed by the explicit RC filename, ad hoc DMG signature and revalidation.
No Developer ID/notarization, installation, tag or GitHub Release was performed.
RC 1/RC 2 and their assets are unchanged.

## Git and CI boundary

The separate checkout is based on public main `2238c51865db2e06ee7adeb71d7fde09e0f157d9`.
The divergent development checkout and its staged/unstaged/untracked status are
preserved. Only the focused RC 3 change is committed and submitted as a draft PR.
PR CI runs once: branch pushes are filtered out; pushes to main retain coverage.
No manual workflow is dispatched. Stop immediately after confirming a PR workflow
was queued/started; remote CI success is **NOT YET VERIFIED** in this report.
