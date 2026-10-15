# Security and privacy

CodexSwoop is an independent local macOS menu bar application. Official Codex handles authentication. CodexSwoop does not import tokens or cookies into its profile metadata and does not technically verify ChatGPT account identity.

## Profile and environment data

Local profile labels and environment references are metadata, not authenticated account records. Managed environments use separate local directories. Separate paths, process ownership, successful opening and manual account notes do not prove ChatGPT identity or complete authentication isolation. macOS services, browser sign-in and official Codex behavior may affect multiple environments.

Profile storage uses owner-only permissions, validated metadata, atomic replacement, locking and symlink checks. These controls reduce accidental interference; they do not protect against malicious software running as the same user, root, or every filesystem race. Corrupt or unknown metadata must not silently become an empty writable catalog.

Removing a profile removes its record and active link, without deleting underlying Codex authorization directories or closing a running Codex instance. Metadata backups may retain earlier profile labels. This is not secure erasure.

## Opening and activity boundaries

Environment-scoped opening actions require current path, publisher signature, Team ID, executable, process-generation and environment-ownership checks. Closing other instances also requires explicit confirmation. Open-only actions and local AccountSetup transactions serialize through the existing operation lock without settling or replacing older opening history. Official Codex at **`/Applications/ChatGPT.app`** is admitted independently of version/build numbers. Last individually tested: **26.1007.21159 (20052)**. Metadata alone never establishes signature trust. Local profile creation/rename/removal does not require an installed or verified Codex app; metadata integrity and pending-operation protections still apply.

Unknown activity is not idle. Unknown process ownership can block an operation. **Close Others & Open** requests normal closure sequentially and can complete partially. An uncertain outcome requires review; users must save work and review affected instances before confirming. Production safety gates are retained. Do not bypass them to force an unsupported installation or ambiguous process through.

Technical account identity verification and **Live Usage are unavailable** and deferred to 1.1. Manual visual confirmation inside Codex does not unlock technical verification or Usage.

## Experimental distribution

Version **1.0.0 (5)** / **v1.0.0-rc.2** is an experimental Pre-release for Apple Silicon arm64. The deployment target is macOS 14.0; Sonoma runtime acceptance has not been performed. Automated checks ran on macOS 27.0.1 (26A434). Installation/first-launch, VM and clean-machine acceptance are not claimed.

Both the application and DMG have **ad hoc signatures**, with **no Developer ID or notarization**. Gatekeeper may block first launch. Verify the published SHA-256 and follow the [Release Notes](RELEASE_NOTES_v1.0.0-rc.2.md). Do not disable Gatekeeper or remove quarantine attributes. The separate strict public-release mode retains Developer ID, notarization, stapling and Gatekeeper checks.

## Reports and repository hygiene

Use [GitHub Issues](https://github.com/cbrwvy/codexswoop/issues) for sanitized bug reports. Include version/build, OS version, supported Codex version, reproduction steps and controlled error messages. Use fictional profile names and redact screenshots. Never post credentials, cookies, tokens, authorization files, private conversations, environment exports or personal account data. No separate private disclosure channel is advertised; do not submit sensitive material to public Issues.

Git ignore rules exclude local account data, credentials, editor state, backups and build products. The repository audit checks both working-tree candidates and actual staged blobs without printing matched secret values. Automated scanning is heuristic and does not prove the absence of every possible secret. Internal development reports and raw runtime/research evidence are not included in the public source snapshot.
