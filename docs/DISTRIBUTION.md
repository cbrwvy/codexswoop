# CodexSwoop Distribution

## Stable 1.0.0

**Application 1.0.0, build 15**, tag **`v1.0.0`**. Download from the [public Release](https://github.com/cbrwvy/codexswoop/releases/tag/v1.0.0):

- `CodexSwoop-1.0.0-macos-arm64.zip`
- `CodexSwoop-1.0.0-macos-arm64.zip.sha256`

The app and recovery helper are **Apple Silicon arm64 only** (M1 or newer), **ad hoc signed**, and **not notarized**. There is **no Developer ID signature or stapled ticket**. macOS Gatekeeper may block first launch; seamless Gatekeeper acceptance is not promised. No Gatekeeper setting or quarantine attribute is changed by this release workflow.

Both executables declare a macOS **14.0** minimum. Real two-profile acceptance used macOS **27.0.1** and official Codex **26.1007.71326**. Automated CI uses macOS **15 / Xcode 16.4**. macOS 14 runtime, Intel, clean-machine and VM acceptance are not claimed. See [Release Notes](RELEASE_NOTES_v1.0.0.md) for features, installation, authentication boundaries and known limitations.

## Artifact verification and provenance

The release reuses the already verified build 15 produced from `5ca7c8d17a25f967563dba0a50254a7e65689de3`. The final tag adds only test synchronization and documentation changes. Production sources, resources, package/project configuration and build scripts remain identical. The ZIP is copied without changing its bytes; only the filename and the filename-bearing checksum sidecar change.

SHA-256:

```text
b0b64489141418e56e7eb6731b48980c24d000f4e31e76fa81b2e6405f9b214c
```

Verify after download:

```sh
shasum -a 256 -c CodexSwoop-1.0.0-macos-arm64.zip.sha256
```

Release validation covers the ZIP CRC and allowed top-level contents, extracted app/version/build, both arm64 Mach-O executables and their minimum OS stamps, deep/strict code signatures, and byte equality with the accepted bundle. Public release assets are downloaded again to verify their SHA-256 against the original. No user environments, installed app, or official Codex processes are changed for publication.

## Separate notarized DMG workflow

The existing packager's strict `public-release` mode continues to require Developer ID Application signing, Hardened Runtime, secure timestamps, notarization/stapling and Gatekeeper validation. No signing credentials are used for the 1.0.0 ad hoc ZIP. Its stable GitHub release status does not claim those signing or clean-machine acceptance gates.

Historical [RC 2 notes](RELEASE_NOTES_v1.0.0-rc.2.md) and [validation](RC_2_VALIDATION.md) describe the older experimental DMG; they are retained as historical evidence.
