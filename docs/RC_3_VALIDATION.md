# CodexSwoop 1.0.0 RC 3 validation

Candidate **1.0.0 (6)**, planned **v1.0.0-rc.3**, arm64, ad hoc signed,
non-notarized. This remains a draft candidate. No installed-store supersession,
Swoop shutdown/installation, official Codex lifecycle action, account change, tag
or GitHub Release has been performed. Real switching acceptance is still open.

## Final change

A replaced receiver generation cannot prove the old activation succeeded. Ordinary
Check Again therefore retains its block. RC 3 preserves the existing exact recovery
diagnostics and screen-bounded popover, and adds a separate native-only one-shot
`codexswoop-recovery` executable for the owner-approved recovery architecture.

The tool archives the exact unresolved pair and allowlisted Swoop catalogs in a
0700 directory, with 0600 files, SHA-256 and `historicalOutcome: unknown`. Consent
binds the original store ID, operation ID and journal hash. Locks, root/catalog
identities, precise original PID absence, boot, signature/build and complete strict
native inventory must pass fresh proof. No old `complete()` call or official
process effect is used. The initial two native samples are repeated after archival.

The watermark-first new epoch remains blocked until its separate durable commit
record exists. Its schema-3 envelope hash-binds the immutable archive; subsequent
operations retain that provenance. Consent-bound reruns can finish only the exact
prepared transition. Successful supersession is permanently consumed and cannot
discard another pending operation. Startup, Check Again and existing initializers
never perform supersession. See [P0_RECOVERY.md](P0_RECOVERY.md) for commands, exact
write scope, crash states, stopping conditions and the older-reader boundary.

## Local validation

- Full `./scripts/check.sh --require-xctest`: **PASS**, including native XCTest,
  universal native Debug/Release and Archive. Final log: `build/p0-engineering-pipeline.log`.
- **535 CoreChecks**, **110 SwiftPM XCTest**, **110 native XCTest**,
  **101 IsolationLab Python tests**, **20 ReleaseTooling tests**: zero failures.
- Final separate recovery matrix: **87 fault stages**, each tested with thrown I/O
  failures and abrupt QA-worker `_exit`; **4032 assertions** passed. Includes fsync
  of existing archived files during partial-archive resume as well as prepared-pair
  resume, manifest, watermark, journal and commit publication. Evidence:
  `build/p0-delivery-recovery.log`. Every store and adapter is synthetic.
- Negative recovery cases cover both locks, Swoop running before/after archival,
  missing-primary/available-backup catalogs, PID reuse, missing precision,
  boot/build/signature drift, unknown/changed inventory, catalog/permission/directory
  changes, corrupt/future journals, cancellation and damaged archive evidence. Synthetic integration also reproduces revision-3 launch/activation
  evidence and opens both preserved profiles through a fresh normal coordinator
  after supersession, retaining the old unresolved bytes.
- **222 setup/menu offscreen renders** and **132 Usage offscreen renders**: PASS,
  preserving EN/RU/UZ-Latn, appearance, bounded-menu and scrolling regressions.
  Live AppKit anchor/VoiceOver checks remain separate manual acceptance.
- Localization, resources/icons, plists/project configuration, shell checks,
  worktree and staged privacy scans, and `git diff --check`: PASS.
- Universal SwiftPM app and recovery helper: PASS for arm64/x86_64, minimum 14.0
  and selected SDK 27.0. The new Swift Build engine receives an explicit link tuple;
  older XCBuild keeps its existing Xcode 16.4-compatible flag path.
- Final candidate rebuild includes the recovery helper in the app bundle. App/helper
  deep/strict ad hoc signature checks pass. Release-tooling tests retain the exact
  payload allowlist and reject a non-Mach-O or wrong-architecture helper.

The final core also received an archive-ancestry check before any archive file read;
the recovery matrix and exact arm64 candidate were rebuilt after that review.
Host: Apple Silicon, macOS 27.0.1, Xcode 27.1 / Swift 6.4, SDK 27.0. Physical power
loss, Sonoma/Intel runtime, clean-machine acceptance, installed RC 3 UI,
multi-monitor runtime, VoiceOver and actual profile switching are not established
by these synthetic/build results.

## Real read-only boundary

The earlier `build/p0-live-preflight.log` reported matching pending pair, boot,
catalog/build and absent captured PIDs, but a running Swoop. It is historical and
must not substitute for a fresh proof.

An earlier prepared-tool inspection refused `processChanged`; it was preserved as
failed evidence, not treated as permission. After final builds completed, one
isolated read-only invocation of the signed delivery tool passed its journal,
original PID absence, current inventory, boot, catalog/root and fingerprint checks.
It returned **BLOCKED: Swoop is running; no metadata changed**. Evidence:
`build/p0-delivery-readonly.log`. No archive or live pair was written.
A separate consent-reference extraction reads only the current allowlisted pair
identifiers/hash and is not itself readiness evidence. Operator records are private
and excluded from Git; no account identity is asserted.

Real application still requires explicit store/operation-specific consent, normal
shutdown of only Swoop, and a fresh READY inspection/application proof. A failure
remains blocked. Starting the compatible RC 3 and actual switching acceptance are
separately authorized real actions.

## Exact prepared artifact

- DMG: `build/p0-rc3-delivery/CodexSwoop-1.0.0-rc.3-macos-arm64-unnotarized.dmg`.
- DMG SHA-256: `e65dc66a179f12eb4cb1c58f8b381bdb306ff4804588d2407e9f24adc33dfd92`.
- App executable SHA-256: `e40ec1151bfebe549012b7d3d8922aa0ca46ac45503ffefbc80dfb2d957ad23a`.
- Recovery executable SHA-256: `5e15233273d14a4a3f79791124583a81ab262b0cff4af7add1aa8ae5790cbb9e`.
- Canonical app manifest SHA-256: `f574989cb988406caef502d7e4d561a8f0627cce2cae3260558e895a1cc15eea`.
- [Source/build/test inputs](RC_3_BUILD_INPUTS.json): **135 files**,
  SHA-256 `9c24e9acd5e43fb2ab8241636bc846c1ed8fe8975d62a76413ecaa6eca9d835b`.
  Includes the project and ignore/security policy; docs are excluded to avoid circular hashes.
- Bundle ID `io.github.cbrwvy.codexswoop`, version 1.0.0, build 6, arm64-only,
  minimum macOS 14.0 and SDK 27.0: verified.
- DMG strict ad hoc signature, `hdiutil verify`, read-only mounted payload allowlist,
  Applications symlink, mounted/source app manifest equality and exact filename-bearing
  SHA-256 sidecar: PASS. The mounted helper's `--help` uses no user metadata.

The previously prepared RC 3 image and RC 1/RC 2 artifacts are unchanged; the new
candidate is in its own output directory. Packaging reuses the tested arm64 Release
bundle, without version rewriting, Developer ID, notarization or publication.

## PR and CI

The existing Draft [PR #3](https://github.com/cbrwvy/codexswoop/pull/3) is updated on
`codex/rc3-recovery-menu`; the original diagnostics/popover commit is retained.
The divergent development checkout is untouched. A branch push queues the PR
workflow; no duplicate manual workflow dispatch is needed. Stop after obtaining
its run URL. Remote CI success is not claimed or awaited.
