# Building CodexSwoop

The Swift package and shared Xcode project/scheme are the build authorities. The application is **1.0.0 (build 6)**, Swift language mode 6, deployment target **macOS 14.0**. The experimental distribution is **Apple Silicon arm64 only**. Building another architecture does not establish supported runtime compatibility.

No account credentials, official Codex launch or installation is needed to compile or run the automated suites. Use disposable fixtures for tests; do not point test storage at real account data.

## RC 2 toolchain

Automated validation ran on **macOS 27.0.1 (26A434)** with **Xcode 27.1 (27A9275)**, **Apple Swift 6.4**, and **macOS SDK 27.0**. Sonoma runtime acceptance has not been performed. Remote CI uses a separate macOS 15 / Xcode 16.4 lane; local RC acceptance does not establish remote CI success.

Select Xcode per command without changing the global developer directory:

```sh
env DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./scripts/check.sh --require-xctest
```

This runs lint, localization/project validation, worktree and index privacy scans, startup regression, Python and CoreChecks suites, SwiftPM XCTest, local Debug/Release bundles, and the native Xcode workflow. A missing full Xcode fails the required command. Hostless XCTest uses disposable fixtures and does not launch the application as a test host.

The native workflow can also be run independently:

```sh
./scripts/check-xcode.sh
```

It runs XCTest, universal native Debug/Release builds and an unsigned Archive. Separate disposable QA copies receive verified local ad hoc signatures. These QA products are not the distributed RC and do not establish Intel runtime support.

## Local builds

```sh
./scripts/build-app.sh debug
./scripts/build-app.sh release arm64
```

The arm64 app is written to `build/release-arm64/CodexSwoop.app`. These commands do not install or launch the bundle. Generated outputs are ignored by Git.

The build script pins the selected SDK and explicit linker platform metadata, checks the minimum OS and SDK stamps, copies only allowlisted resources, strips Release debug information and signs locally with an ad hoc identity. Localization is compiled into the core from `Resources/Localization/catalog.json`; no runtime JSON copy is required.

Additional architecture builds are available for development only:

```sh
./scripts/build-app.sh release x86_64
./scripts/build-app.sh release universal
```

## Resource and UI checks

```sh
python3 scripts/check-project.py --bundle build/release-arm64/CodexSwoop.app
swift scripts/check-icons.swift --bundle build/release-arm64/CodexSwoop.app
./scripts/check-account-setup-ui.sh
./scripts/check-usage-ui.sh
python3 -m unittest discover -s Tests/ReleaseTooling -v
```

UI rendering uses synthetic data. Optional accessibility/menu-bar variants require a logged-in GUI session and can display disposable test windows. Automated checks do not establish VoiceOver speech, real Login Items, first-launch, actual Codex account identity or authentication isolation.

## Packaging

See [Distribution](DISTRIBUTION.md) for the experimental `local-preview` workflow and the separate strict `public-release` workflow. The experimental RC app and DMG are ad hoc signed and not notarized. Strict public-release mode continues to require Developer ID, Hardened Runtime, secure timestamps, notarization/stapling and Gatekeeper acceptance.

[RC 2 validation](RC_2_VALIDATION.md) records the exact source fingerprint, artifact checksums, test counts and remaining acceptance limits. No VM or clean-machine testing is claimed for this Pre-release.
