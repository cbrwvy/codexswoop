# CodexSwoop Distribution

## Experimental first GitHub Pre-release

Approved candidate: **1.0.0 (build 4)**, tag **`v1.0.0-rc.1`**. The artifact is **`CodexSwoop-1.0.0-rc.1-macos-arm64-unnotarized.dmg`**. It contains an **ad hoc-signed** app, has no Developer ID signature, and is **not notarized**. It is an experimental Pre-release, not an accepted stable release. The release is explicitly marked as a GitHub Pre-release, with Latest disabled.

Apple Silicon **arm64 only** (M1 or newer). The deployment target is **macOS 14.0**, but Sonoma runtime acceptance is **not performed**. Automated checks run on **macOS 27.0.1 (26A434)**. Final installer/first-launch acceptance, VM and clean-machine testing are not performed. Only official **Codex 26.1007.21159 (20052)** at **`/Applications/ChatGPT.app`** is supported; other versions and paths are unsupported. ChatGPT identity is not technically verified, full authentication isolation is not guaranteed, and Live Usage is disabled. Identity verification and Live Usage are deferred to 1.1.

See [Release Notes](RELEASE_NOTES_v1.0.0-rc.1.md) for user installation, Gatekeeper warnings, limitations and bug reports, and [RC evidence](RC_1_VALIDATION.md) for exact hashes and checks.

## Existing local-preview workflow

The packager accepts a prebuilt app and never rewrites version/build metadata or builds it. The RC uses this existing experimental workflow without changing its validation or the separate public-release mode:

```sh
./scripts/build-app.sh release arm64
./scripts/package-release-dmg.sh \
  --mode local-preview \
  --app build/release-arm64/CodexSwoop.app \
  --expected-version 1.0.0 \
  --output-dir build/rc1
```

The workflow produces `CodexSwoop-1.0.0-macos-arm64-local-preview.dmg` and its SHA-256 sidecar. For this owner-approved experimental Pre-release, label the completed image explicitly, ad hoc sign the container, regenerate the filename-bearing sidecar, and validate it again:

```sh
mv build/rc1/CodexSwoop-1.0.0-macos-arm64-local-preview.dmg \
  build/rc1/CodexSwoop-1.0.0-rc.1-macos-arm64-unnotarized.dmg
codesign --sign - --timestamp=none \
  build/rc1/CodexSwoop-1.0.0-rc.1-macos-arm64-unnotarized.dmg
codesign --verify --strict --verbose=2 \
  build/rc1/CodexSwoop-1.0.0-rc.1-macos-arm64-unnotarized.dmg
(cd build/rc1 && shasum -a 256 \
  CodexSwoop-1.0.0-rc.1-macos-arm64-unnotarized.dmg \
  > CodexSwoop-1.0.0-rc.1-macos-arm64-unnotarized.dmg.sha256)
./scripts/validate-release-artifact.sh \
  --dmg build/rc1/CodexSwoop-1.0.0-rc.1-macos-arm64-unnotarized.dmg \
  --mode local-preview --expected-version 1.0.0
```

The old filename's sidecar is intermediate evidence, not a release asset. The local-preview CLI warning describes its lack of notarized public-release acceptance. This explicitly labeled experimental Pre-release does not acquire public-release validation status. Both the DMG container and enclosed app are ad hoc signed; neither has Developer ID or notarization.

The validator reads every nested Mach-O's architecture, macOS platform and exact 14.0 deployment target. It verifies bundle metadata, mandatory resources, deep/strict app signature, image integrity, read-only mounted contents, the absolute `/Applications` symlink, and checksum. The exact allowlist permits only the app, Applications link, generated PNG background and optional nonempty regular `.DS_Store`. Unknown bundle resources are rejected. The app includes Info.plist, executable, icon resources and signature seal only; localization is compiled into the executable.

No Gatekeeper setting is changed and no quarantine attribute is removed. Local-preview does not claim Gatekeeper acceptance, Developer ID, secure timestamp, notarization or stapling.

## Strict public-release mode — unchanged

The separate `public-release` mode remains fixed to version 1.0.0 and `CodexSwoop-1.0.0-macos-arm64.dmg`. It requires a Developer ID Application identity and externally configured notarytool Keychain profile. It signs a staged app with Hardened Runtime and secure timestamp, submits and staples it, signs/notarizes/staples the DMG, and validates Developer ID authority, Team Identifier, timestamp, runtime flag, stapling, Gatekeeper, contents and checksum. Ad hoc signatures are rejected in this mode. No signing credentials are used for the experimental RC.

```sh
# Future separate owner-authorized operation only:
./scripts/package-release-dmg.sh \
  --mode public-release --app path/to/CodexSwoop.app \
  --identity "Developer ID Application: Example Organization (TEAMID)" \
  --notary-profile "CodexSwoop-notary"
```

The existing `scripts/package-dmg.sh` is a separate development tool and is not used for this RC.

## DMG presentation

The generated background preserves the approved charcoal `#17191D` and coral `#FF5A36` palette, arrow, `Drag to Applications` instruction and `local-preview - not notarized` label. The packager does not synthesize Finder `.DS_Store` placement. Automatic content validation does not establish Finder background visibility or icon positioning; manual Finder presentation acceptance remains unperformed for this RC. README design and approved screenshots are preserved.
