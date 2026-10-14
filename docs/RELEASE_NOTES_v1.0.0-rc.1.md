# CodexSwoop 1.0.0-rc.1

**Experimental GitHub Pre-release — application version 1.0.0, build 4.** This is the first distribution candidate, not a fully validated stable release.

CodexSwoop is a native macOS menu bar app for organizing local profile labels and Codex environments. Link the standard environment or prepare a Managed environment, use confirmed environment-scoped opening actions when safety checks pass, and manage local profile records. This candidate packages the current implementation; it adds no new features and retains all production safety gates.

## Supported configuration

| Component | Requirement / evidence |
| --- | --- |
| Hardware | Apple Silicon M1 or newer; arm64 only. Intel is unsupported. |
| Deployment target | macOS 14.0. Sonoma runtime acceptance has **not** been performed. |
| Actual validation host | macOS **27.0.1 (26A434)**; automated build/test/artifact validation only. |
| Official Codex | **26.1007.21159 (20052)** at **`/Applications/ChatGPT.app`** only. Other versions and locations are unsupported. |
| Signature | Enclosed app: **ad hoc**, no Developer ID. DMG container: **ad hoc signed**. **Not notarized**; Gatekeeper acceptance is not claimed. |

## Installation and Gatekeeper

Download `CodexSwoop-1.0.0-rc.1-macos-arm64-unnotarized.dmg` and its `.sha256` file from [GitHub Pre-release v1.0.0-rc.1](https://github.com/cbrwvy/codexswoop/releases/tag/v1.0.0-rc.1).

1. Verify the download in Terminal from the directory containing both files:

   ```sh
   shasum -a 256 -c CodexSwoop-1.0.0-rc.1-macos-arm64-unnotarized.dmg.sha256
   ```

2. Open the DMG and drag **CodexSwoop.app** to **Applications**, then eject the image.
3. Open CodexSwoop from Applications. It appears in the menu bar.
4. **macOS may block this unnotarized app because Apple cannot verify its developer or check it for malicious software.** Only if you trust this repository and have verified the checksum, use Apple's per-app **System Settings → Privacy & Security → Open Anyway** flow after attempting launch, if macOS offers it, then review the confirmation. Organizational policy may prevent this. Do not disable Gatekeeper or remove quarantine attributes. If macOS reports that the app will damage your computer or is damaged, stop and report the exact message instead of overriding it.
5. Follow the [Getting Started guide](https://github.com/cbrwvy/codexswoop/blob/v1.0.0-rc.1/docs/GETTING_STARTED.md). Sign in only inside official Codex and visually confirm the intended account there.

Apple documents the current per-app approval flow in [Safely open apps on your Mac](https://support.apple.com/en-us/102445). This RC has not been installed or first-launched during preparation; a downloaded/quarantined copy can behave differently from a local build.

## Known limitations

- No technical verification of ChatGPT account identity. Profile names and manual notes are local labels; successful environment opening does not prove who is signed in.
- Full authentication isolation is not guaranteed. Separate directories do not establish isolation of macOS services, browser sign-in or Codex authentication behavior.
- **Live Usage is disabled**. Live Usage and technical identity verification are deferred to **1.1**.
- Only the exact Codex version/build/path above is supported. An automatic Codex update can block opening until a compatibility review.
- Sonoma runtime acceptance, VM and clean-machine tests are not performed. Automated checks on macOS 27.0.1 do not establish compatibility across macOS versions or final installer/first-launch acceptance.
- The app is ad hoc signed, the DMG is ad hoc signed, and neither is notarized. There is no Developer ID assurance, secure signing timestamp or claimed Gatekeeper acceptance.
- **Close Others & Open** is sequential and can complete partially. Unknown ownership or changed checks can block an operation; unknown activity is not idle. Review affected instances and save work before confirming. An uncertain result requires manual review; no force quit or automatic retry is promised.
- Final Finder window placement, real Login Items behavior and VoiceOver speech acceptance are not established by the RC's automated checks.

## Checksums and validation

DMG SHA-256: `9aad2ad6944f7b49125240d667e485038cb5de6ea5540ea56b9155b03a331ab4`

Executable SHA-256: `063c64688fa6178b201fa65ea57bbd1e066043fdeab8e09fd4c9e8267e094266`

Application bundle SHA-256 (canonical per-file manifest, including paths/modes/symlinks): `f0a0bc6b4c16a4e41f8b4ce5e2d9742e5393c04e58cede425e6f14fbe53446f1`. An application is a directory, so this digest is defined by the manifest in the [RC validation report](https://github.com/cbrwvy/codexswoop/blob/v1.0.0-rc.1/docs/RC_1_VALIDATION.md); it is not the DMG file checksum.

The downloadable `.sha256` sidecar is the authoritative file verification input. See the [RC validation report](https://github.com/cbrwvy/codexswoop/blob/v1.0.0-rc.1/docs/RC_1_VALIDATION.md) for toolchain, source identifier, exact automated results and remaining acceptance limits.

## Bug reports

Open an issue in [GitHub Issues](https://github.com/cbrwvy/codexswoop/issues). Include CodexSwoop version/build, DMG checksum, macOS version/build, Apple Silicon model, exact Codex version/build/path, steps to reproduce, expected behavior, actual behavior, and any sanitized error message. State whether it occurred after downloading the Pre-release or in a source build. Use fictional profile names. Do not attach credentials, cookies, tokens, authorization files, private conversations, environment exports or personal account data. Crop and redact screenshots before uploading.

CodexSwoop is independent and is not affiliated with, endorsed by or officially supported by OpenAI.
