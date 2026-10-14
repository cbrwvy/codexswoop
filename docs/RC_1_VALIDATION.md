# CodexSwoop 1.0.0-rc.1 validation

Application **1.0.0 (build 4)**, experimental Pre-release, **Apple Silicon arm64 only**, deployment target **macOS 14.0**. Automated validation was completed on 2026-10-14. This report does not claim stable-release, Sonoma runtime, downloaded-app installation, first-launch or official Codex lifecycle acceptance.

## Source and toolchain

Build/validation input manifest SHA-256:

```text
85eb7f60d3926eb5210a457f89309123257313f97c048a9251d136fac8e082cb
```

The reviewed [build input manifest](RC_1_BUILD_INPUTS.json) contains 131 relative file paths, permission modes and SHA-256 values. It covers source, resources, project/package configuration, scripts, tests, CI and ignore rules. Its exact encoding is JSON with sorted object keys, compact separators, and one trailing LF. Hash the UTF-8 manifest bytes to reproduce the identifier.

Every listed file in the public source snapshot is byte-for-byte and mode-for-mode identical to the inputs recorded for the RC build. Public documentation and the reviewed synthetic screenshots are outside this input fingerprint. Publication edits change documentation only; the RC is not rebuilt or repackaged. Public history starts from the reviewed source snapshot and does not include internal development history or raw research/evidence logs.

Validation host/toolchain:

- **macOS 27.0.1 (26A434)**, arm64.
- **Xcode 27.1 (27A9275)**.
- **Apple Swift 6.4**, `swiftlang-6.4.0.34.1`, `clang-2100.3.34.1`.
- **macOS SDK 27.0**; Mach-O deployment target **14.0**.

The RC executable was compiled from scratch into a previously nonexistent SwiftPM scratch directory with Release optimization and explicit arm64/SDK/minimum-OS options. The bundle was assembled from the resource allowlist, stripped, and ad hoc signed with Hardened Runtime and no timestamp. Old build/release products were not used as its payload. The existing local-preview workflow created the DMG, which was explicitly labeled as unnotarized and ad hoc signed. Strict public-release tooling remained unchanged.

## Automated results

| Check | Result |
| --- | --- |
| `./scripts/check.sh --require-xctest` | PASS, exit 0 on permitted rerun |
| `./scripts/check-xcode.sh`, invoked by check.sh | PASS: hostless XCTest, universal Debug/Release QA builds and Archive |
| CoreChecks | 532 passed, 0 failed |
| SwiftPM XCTest / native XCTest | 96 passed, 0 failed in each runner |
| IsolationLab Python | 101 passed |
| ReleaseTooling regression | All 18 passed |
| Project/plist/localization | PASS; 380 keys and 1145 translation forms, EN/RU/UZ-Latn |
| Fresh arm64 Release / resources / app signature | PASS |
| Final DMG integrity, content, signature and checksum | PASS |
| Strict public-mode rejection of the actual ad hoc app | PASS; real Developer ID is still required in that mode |
| Worktree and index privacy scans | Zero findings at RC preparation and publication preflight |
| `git diff --check` | PASS |

An initial sandboxed run stopped after 531 passing CoreChecks because libproc could not read generation metadata for the synthetic QA process itself. The full command passed after rerunning with the permitted execution boundary. No test assertion or production gate was weakened. Raw local logs are retained privately and are not public release assets.

The distributed bundle has only one Mach-O, `Contents/MacOS/CodexSwoop`: arm64, macOS platform, minimum 14.0, SDK 27.0. Bundle metadata, mandatory icons and localization declarations were validated. Localization is compiled into the executable. The app in the read-only mounted final image matched the original bundle's file manifest exactly. DMG contents are only the app, the absolute `/Applications` symlink and generated background. Both signatures and the final checksum were verified.

## Artifact identifiers

| Item | SHA-256 |
| --- | --- |
| `CodexSwoop-1.0.0-rc.1-macos-arm64-unnotarized.dmg` | `9aad2ad6944f7b49125240d667e485038cb5de6ea5540ea56b9155b03a331ab4` |
| `Contents/MacOS/CodexSwoop` | `063c64688fa6178b201fa65ea57bbd1e066043fdeab8e09fd4c9e8267e094266` |
| Application bundle manifest | `f0a0bc6b4c16a4e41f8b4ce5e2d9742e5393c04e58cede425e6f14fbe53446f1` |

The bundle digest is SHA-256 of canonical JSON plus LF containing sorted relative file paths, permission modes, entry types and each file's SHA-256 (or symlink target). A directory has no single file checksum; the DMG checksum and downloadable `.sha256` sidecar are the download-verification inputs.

The app is ad hoc signed with Hardened Runtime; the DMG container is also ad hoc signed. Neither has Developer ID, a secure timestamp, notarization or stapling. Gatekeeper acceptance is not claimed. No Gatekeeper setting or quarantine attribute was changed.

## Supported configuration and limitations

Only official **Codex 26.1007.21159 (20052)** at **`/Applications/ChatGPT.app`** is supported. Other builds/locations and Intel Macs are unsupported. macOS 14.0 is the deployment target; Sonoma runtime acceptance is unperformed. The actual automated validation host is macOS 27.0.1.

Technical ChatGPT identity verification is absent. Full authentication isolation is not guaranteed. Live Usage is disabled; technical identity verification and Live Usage are deferred to 1.1. VM and clean-machine tests were excluded. No RC installation, real first-launch/account lifecycle, Finder visual placement, real Login Items or VoiceOver speech acceptance is established by these checks. Remote CI success is not inferred from local validation.

See [Release Notes and installation](RELEASE_NOTES_v1.0.0-rc.1.md), [Distribution](DISTRIBUTION.md), and [Security](SECURITY.md). The RC is explicitly experimental and is not a fully validated stable release.
