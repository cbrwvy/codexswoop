# Troubleshooting

Applies to experimental **1.0.0 (5)** / `v1.0.0-rc.2`: Apple Silicon arm64 only, deployment target macOS 14.0 (Sonoma runtime acceptance not performed). Automated checks run on macOS 27.0.1 (26A434); final installer/first-launch acceptance is untested. Official Codex at `/Applications/ChatGPT.app` is checked dynamically by publisher signature and installation/process evidence. Ordinary version/build updates are accepted without a CodexSwoop update. Last individually tested: **26.1007.21159 (20052)**; newer versions are informationally untested. Other installation paths remain unsupported for opening. The app is ad hoc signed and not notarized. Technical ChatGPT identity verification is absent, full authentication isolation is not guaranteed, and Live Usage is disabled (identity/Usage deferred to 1.1). See [Release Notes](RELEASE_NOTES_v1.0.0-rc.2.md) for installation and Gatekeeper guidance.

## Codex installation not detected

Open Settings and select **Refresh**. Confirm official Codex is at **`/Applications/ChatGPT.app`**. Ordinary version/build updates are supported after dynamic publisher/installation validation; the application picker does not bypass signature, executable or canonical-path checks. Detection can take a moment. If CodexSwoop still reports that no compatible installation is available, preserve your profiles and wait for a supported setup; do not try to bypass the check.

## Codex updated

A new version/build is informational and does not require a new CodexSwoop release or compatibility allowlist. RC 2 verifies the current official publisher and installation dynamically. Select Refresh if the installation was changing while it was checked. You can add, rename and remove local profiles while opening is unavailable, subject to metadata integrity and pending-operation protections.

If an older process remains running after the app on disk was replaced, CodexSwoop checks its live signature, generation and environment ownership independently. When macOS cannot provide coherent evidence, an opening/closing action stops rather than guessing. Review and save work in official Codex yourself; do not bypass ownership checks or clear recovery files. An update cannot silently settle a previous unfinished operation.

## Opening is blocked

Read the message beside the profile and in Settings. Recheck that the profile is linked and the Codex installation is verified. A profile label or manual confirmation does not verify the signed-in ChatGPT account. Some account-switching and window-specific features remain unavailable in this pre-release build.

If CodexSwoop reports unknown ownership, a changed environment, unverifiable signature/installation evidence, or a previous operation needing review, stop and follow that message. Do not repeat the action to force it through.

## Previous operation needs review

Review the visible Codex instances and any unsaved work. Then select **Check Again** and confirm the read-only review. Check Again does not launch or close Codex and does not retry the operation. If the warning remains, keep the state unchanged and contact the maintainers with a short, redacted description. Do not remove or edit recovery files, bypass recovery, or delete account data.

## Unknown running instances

**Close Others & Open** may stop if a running Codex instance cannot be tied to a linked environment. Review the open Codex windows and the profiles you have linked. If you cannot identify an instance or confirm that it is safe to interrupt, cancel and leave it as it is. The app cannot promise automatic switching while an instance is unknown.

## Accessibility permission

Account opening through the verified process does not require Accessibility. Settings only reads and displays the current permission status. A window-specific feature may require permission; use its **Open Accessibility Settings** control only if you intend to use that feature, then return to Settings and select **Check Status**.

## Launch at Login

Launch at Login is optional. If Settings says approval is required, open **System Settings → General → Login Items**, approve CodexSwoop, then return to the app and select **Check Status**. If the setting is unavailable or reports an error, CodexSwoop can still be opened manually.

## Usage unavailable

Live Codex usage limits are not supported by the current version. CodexSwoop does not have verified usage data to show. Check the official Codex app for account and plan information.

## Still stuck?

Include your macOS version, CodexSwoop version, the exact on-screen message, and steps to reproduce. Use fictional profile names and redact paths or other personal details. Never share tokens, cookies, authorization files, or account data. See [SECURITY.md](SECURITY.md) for security reporting guidance.
