# CodexSwoop 1.0.0

**Stable release · application 1.0.0, build 15 · macOS Apple Silicon (arm64, M1 or newer).**

**This build is ad hoc signed, has no Developer ID signature, and is not notarized. No notarization ticket is stapled. macOS Gatekeeper may block first launch; seamless Gatekeeper acceptance is not promised.**

## Features

- Add a profile linked to the existing Codex environment, or prepare a separate environment and sign in through official Codex.
- **Open Separately** launches the selected profile environment or activates its running Codex without closing other profiles.
- **Close Others & Open** confirms the affected instances, requests normal closure, and opens or activates the selected environment.
- Rename, disconnect and remove local profile records while retaining underlying Codex data and authorization directories.
- English, Russian and Uzbek (Latin) interface, optional Launch at Login, environment checks and sanitized error logs.
- Stable menu sizing during installation rechecks and correct GUI-generation tracking while Electron helpers start or exit.

## Installation

1. Download `CodexSwoop-1.0.0-macos-arm64.zip` and its `.sha256` file from this release.
2. In the download directory, verify the archive:

   ```sh
   shasum -a 256 -c CodexSwoop-1.0.0-macos-arm64.zip.sha256
   ```

3. Extract the ZIP, move `CodexSwoop.app` to Applications, and open it. Its controls appear in the menu bar. Existing build 15 users already have the same production application.
4. Keep official Codex at `/Applications/ChatGPT.app`. Add an existing or separate profile through **Add Account**; authentication remains in Codex.

The app has a valid local ad hoc signature, not a verified Developer ID publisher signature. If macOS blocks the downloaded app, review its Privacy & Security message before deciding whether to allow it. Do not disable Gatekeeper or remove quarantine attributes.

## Compatibility and known limitations

- The downloadable app and recovery helper are arm64 only and declare macOS 14.0 as their minimum. Real two-profile acceptance was performed on macOS 27.0.1 with official Codex 26.1007.71326; automated CI runs on macOS 15 with Xcode 16.4. macOS 14 runtime, Intel, clean-machine and VM acceptance are not claimed.
- Opening requires current official Codex publisher, path and environment-ownership checks. Codex version/build numbers are informational; an update can still introduce an untested behavior.
- Profile labels and separate storage roots do not technically verify ChatGPT account identity or guarantee complete authentication isolation. Verify the signed-in account inside Codex. Live Usage is unavailable.
- Unknown ownership or an uncertain closing operation can require manual **Check Again** review. Multi-instance closure is sequential and can be partial; save work before confirming. The app does not replay failed native actions automatically.
- A cold launch can log an ownership-readiness or process-change diagnostic while its GUI starts. In real acceptance, the window opened and subsequent strict ownership observation and activation succeeded.

## Verification and artifact provenance

The user confirmed two independent profile windows. Real acceptance covered separate opening, normal closure of only the second profile while retaining the first, reopening, repeated activation and context menus. The CI regression fix changes only the test's child-process synchronization; production code is unchanged.

The attached ZIP is the already verified build 15 produced from `5ca7c8d17a25f967563dba0a50254a7e65689de3`. The release tag adds only the test fix and documentation. Sources, resources, package/build configuration and build scripts match the artifact's production source baseline. The released artifact is reused without rebuilding or reinstalling it.

SHA-256 (`CodexSwoop-1.0.0-macos-arm64.zip`):

```text
b0b64489141418e56e7eb6731b48980c24d000f4e31e76fa81b2e6405f9b214c
```

Local full pipeline: PASS. [GitHub Actions for the test-fix commit](https://github.com/cbrwvy/codexswoop/actions/runs/38789220693): PASS, source `c2b2f97e265f47a88973e88e95f6046f5b16b452`. The release tag adds documentation only to that validated commit. Its documentation-commit CI is not awaited for publication; the production source is identical.

Independent project, not affiliated with OpenAI. Report sanitized reproduction steps through [GitHub Issues](https://github.com/cbrwvy/codexswoop/issues); never upload authorization files, credentials or private conversations.
