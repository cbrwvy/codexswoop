# CodexSwoop 1.0.0 RC 2 validation

Candidate **1.0.0 (5)** / planned **v1.0.0-rc.2**. Publication requires separate owner authorization. This change fixes release-pinned compatibility without new product features or redesign.

## Source and safety scope

Prepared on the separate public-history branch `codex/rc2-version-independent-compatibility`, based on public main `7f083fdd7e6626ed7f093f2a0c6576c4e614c663`. The divergent local development repository is preserved and is not pulled, merged or pushed. RC 1 and its assets remain unchanged.

The last-tested version is informational only. Runtime admission uses official Bundle ID, OpenAI Team ID/signing requirement, valid signature, executable, canonical path and stable installation evidence. Local metadata operations do not call the native validator. Stored profile/directory integrity and pending-operation locks remain enforced.

The native adapter records observed version/build, app.asar SHA-256, code-directory hash and bundle-generation fingerprint; these are per-operation evidence, not a version allowlist. Scoped authority is bound to that exact fingerprint before intent/dispatch. Live process signature identity is independently admitted, attached to its generation and persisted with the journal. There is no fixed hash comparison between a live process and a replacement on disk. If Security.framework cannot establish coherent live evidence, lifecycle operations fail closed; metadata setup is independent of that observation.

Durable recovery never accepts a different current installation as proof that an older operation completed. No journal reset/migration, forced termination, auth inspection or recovery replay is added. Legacy lifecycle, account identity and live Usage gates remain closed.

Build/validation input manifest: [RC_2_BUILD_INPUTS.json](RC_2_BUILD_INPUTS.json), 132 files, SHA-256 `c4d5664ba6a200924cc8ba6ef0d62f0151ea30c8ebd9965ac3ac5169f67b0a0c`. Source, resources, package/project, scripts and tests are pinned to this snapshot; documentation is excluded to avoid circular artifact hashes.

## Validation

- `./scripts/check.sh --require-xctest`: **PASS**, including `check-xcode.sh`, native Debug/Release/Archive and signatures/resources.
- **532 CoreChecks**, **110 SwiftPM XCTest** and **110 native XCTest**, **101 IsolationLab Python** tests: all passed.
- **14 new update-compatibility regression tests** passed on synthetic data; counterfeit ad hoc/tampered bundles are rejected by the native signature reader.
- **18 ReleaseTooling regression tests** passed.
- **210 offscreen UI renders** passed in EN/RU/UZ-Latn; Continue/profile setup after updated detection is covered. Live AX/menu-bar permission variants were not requested and remain unperformed.
- Read-only native bundle validation passed on the installed official **Codex 26.1007.71326 (20398)**. This used only bundle metadata/resources/signature verification; no process inventory, ProfileStore, account, auth or lifecycle API was called. It does not establish a new full runtime/identity acceptance version.
- Worktree/index security scans and `git diff --check`: PASS. No raw runtime/evidence logs are included in the public change.
- GitHub Actions: [RC 2 branch checks](https://github.com/cbrwvy/codexswoop/actions/workflows/ci.yml?query=branch%3Acodex%2Frc2-version-independent-compatibility). Release approval requires a successful exact-head run; its completed result is recorded in the local handoff.

Actual validation host: **macOS 27.0.1 (26A434)**, Apple Silicon arm64, **Xcode 27.1 (27A9275)**, **Swift 6.4**, **macOS SDK 27.0**. Deployment target: **14.0**. Sonoma runtime, VM, clean-machine, real Codex lifecycle/account acceptance and final installation are unperformed. Tests begin with synthetic installations, profiles, processes and disposable ad hoc-signed counterfeit bundles; no real Codex processes or account data are used.

## Artifact

- DMG: `CodexSwoop-1.0.0-rc.2-macos-arm64-unnotarized.dmg`.
- DMG SHA-256: `a5697032d3ddf8753eee9047c015bdf8bead07190cc3cc24ed93e0fb77a6ce03`.
- Executable SHA-256: `a29affddab5aa283cc3336843d6936943ae0c62edaafb3a494797a43256c2a45`.
- Canonical app manifest SHA-256: `1c860a7415c20674fd836b681a26972687df1e59f5f14a9da39b9be9aebbf0d0` (sorted relative paths, permission modes, type and file SHA-256; compact sorted-key JSON plus LF).
- Version **1.0.0 (5)**; only bundled Mach-O is arm64, macOS platform, minimum **14.0**, SDK **27.0**.
- App/resource/bundle metadata, deep/strict app signature, strict ad hoc DMG signature, `hdiutil verify`, exact read-only mounted contents and `/Applications` symlink, app-manifest equality and SHA-256 sidecar: **PASS**.
- The RC was assembled with `scripts/build-app.sh release arm64` from the tested input snapshot, packaged through existing local-preview mode, explicitly labeled unnotarized, ad hoc signed and revalidated. Old RC 1 artifacts were not used.

App and DMG are ad hoc signed, without Developer ID or notarization. Strict public-release signing/notarization/content checks are unchanged. No Gatekeeper setting or quarantine attribute is changed. The README design, branding and approved synthetic screenshots are preserved.
