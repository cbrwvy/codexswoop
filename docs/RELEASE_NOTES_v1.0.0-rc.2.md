# CodexSwoop 1.0.0 RC 2

**Experimental Pre-release — application 1.0.0, build 5.** RC 2 fixes ordinary official Codex auto-updates blocking profile setup and environment opening.

## Compatibility fix

RC 1 admitted only one exact Codex version/build/archive hash. After an official update, its Continue and opening actions could become unavailable. RC 2 separates local metadata management from native trust checks and removes that release allowlist.

- **Use Existing Codex**, **Sign In to Another Account**, rename and removal operate on local metadata without validating a specific Codex version, reading authorization or performing lifecycle actions. Directory/metadata integrity, overlap checks and pending-recovery protections remain enforced.
- **Open Separately** and **Close Others & Open** admit the current official installation using Bundle ID, valid OpenAI signature and Team ID/signing requirement, executable, canonical path, live process generations and environment ownership. No CodexSwoop update is needed solely because Codex's version/build changed.
- The last individually tested Codex is **26.1007.21159 (20052)**. A newer version, including **26.1007.71326**, displays an informational untested notice and does not disable Continue merely because its version differs. Synthetic regression coverage does not constitute a new live account/runtime acceptance claim.
- A live process is independently checked against the official publisher, not required to have the same code hash as the replacement on disk. If macOS cannot provide coherent live signature/ownership evidence after an update, unsafe lifecycle operations stop. Local profile management remains available unless a pending operation or metadata-integrity problem independently prevents mutation.
- Durable intent records retain the actual installation version/build/hash/generation and live process signature/generation evidence. An installation change during an operation stops dispatch or completion; an update cannot rewrite or silently settle older pending recovery.

## Configuration and limitations

Apple Silicon **arm64 only**, deployment target **macOS 14.0**. Sonoma runtime acceptance has **not** been performed. Automated checks run on **macOS 27.0.1 (26A434)**. Opening currently requires official Codex at **`/Applications/ChatGPT.app`**, Bundle ID **`com.openai.codex`**, verified OpenAI publisher Team ID **`2DC432GLL2`**, expected executable and safe canonical paths. An arbitrary app named Codex is not trusted.

The application and DMG are **ad hoc signed**, have **no Developer ID**, and are **not notarized**. Gatekeeper may require manual per-app approval. Technical ChatGPT account identity verification and **Live Usage are unavailable** (deferred to 1.1). Full authentication isolation is **not guaranteed**. Sequential closing can be partial; unknown ownership and PID reuse remain blockers for lifecycle operations. VM/clean-machine, Sonoma, real account switching and final downloaded-install acceptance are not performed for this candidate.

## Installation

After publication, download `CodexSwoop-1.0.0-rc.2-macos-arm64-unnotarized.dmg` and its `.sha256` file from the [GitHub Pre-release](https://github.com/cbrwvy/codexswoop/releases/tag/v1.0.0-rc.2).

```sh
shasum -a 256 -c CodexSwoop-1.0.0-rc.2-macos-arm64-unnotarized.dmg.sha256
```

Open the DMG, drag CodexSwoop to Applications and eject the image. macOS may block first launch because the developer is not identified/notarized. If you trust the source and verified the checksum, follow Apple's per-app **System Settings → Privacy & Security → Open Anyway** flow, if offered, after attempting launch. See [Apple's guidance](https://support.apple.com/en-us/102445). Do not disable Gatekeeper or remove quarantine attributes. Stop if macOS reports damage or malicious content. The maintainer did not install this candidate or operate real Codex processes during preparation.

## Validation and bug reports

DMG SHA-256: `a5697032d3ddf8753eee9047c015bdf8bead07190cc3cc24ed93e0fb77a6ce03`

See [RC 2 validation](RC_2_VALIDATION.md) for source/toolchain/checksums, local tests and GitHub Actions evidence. Report bugs through [GitHub Issues](https://github.com/cbrwvy/codexswoop/issues), including app/OS/Codex versions, checksum, steps, expected result and actual result. Use fictional profile names and sanitized diagnostics. Never attach credentials, cookies, tokens, authorization files, private conversations or environment exports.

CodexSwoop is independent and not affiliated with or officially supported by OpenAI.
