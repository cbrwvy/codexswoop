# User Guide

Applies to experimental **1.0.0 (5)** / `v1.0.0-rc.2`: Apple Silicon arm64 only, deployment target macOS 14.0 (Sonoma runtime acceptance not performed). Automated checks run on macOS 27.0.1 (26A434); final installer/first-launch acceptance is untested. Official Codex at `/Applications/ChatGPT.app` is checked dynamically by publisher signature and installation/process evidence. Ordinary version/build updates are accepted without a CodexSwoop update. Last individually tested: **26.1007.21159 (20052)**; newer versions are informationally untested. Other installation paths remain unsupported for opening. The app is ad hoc signed and not notarized. Technical ChatGPT identity verification is absent, full authentication isolation is not guaranteed, and Live Usage is disabled (identity/Usage deferred to 1.1). See [Release Notes](RELEASE_NOTES_v1.0.0-rc.2.md) for installation and Gatekeeper guidance.

## Local profiles and ChatGPT accounts

A profile is a local CodexSwoop record: a name you choose and, when linked, a reference to a Codex environment. It is not an authenticated account record. CodexSwoop does not guarantee that the ChatGPT account you expect is signed in to that environment. Confirm identity in the official Codex app.

## Standard External and Managed environments

| Type | What it refers to | What it does not mean |
| --- | --- | --- |
| **Standard External** | The standard Codex environment already on this Mac. | CodexSwoop has not copied its credentials or verified its ChatGPT identity. |
| **Managed** | A separate set of local Codex environment directories prepared for a profile. | Separate directories do not prove complete authentication isolation across macOS, browser, or Codex services. |

Sign in only through the official Codex app. CodexSwoop does not import tokens or cookies into its profile metadata.

## Profile actions

- **Open Separately** asks for confirmation and attempts to activate or launch Codex using the selected environment. Identity is not verified by the profile label or by successful opening.
- **Close Others & Open** requests normal closure of other identified Codex instances one at a time, then opens the selected environment. The action can stop when an instance is unknown or checks change. It is not atomic; some instances may already have closed if a later step fails.
- **Recheck** validates the saved environment reference.
- **Confirm account manually** records your own visual check as a local note. It does not prove account identity or unlock account verification.
- **Disconnect** removes the active link from the profile while retaining the environment data.
- **Rename** changes the local display label only.
- **Remove** deletes the profile record and active link. It does not delete the underlying Codex authorization directories, projects, or a running Codex instance. A removed Managed environment can remain in Settings for restoration. Metadata backups may retain an earlier profile name.

## Opening behavior and confirmation

Each opening attempt uses the supported-build and environment-ownership checks available in the current build. Confirmation is required before opening, and closing other instances has its own confirmation. Cancel when you cannot review the affected instances or their state.

Activity status may be **Unknown** because CodexSwoop cannot establish complete activity information. Unknown is not idle. A user confirmation is per attempt and does not change the status. An instance with unknown ownership can block **Close Others & Open** altogether.

## Warnings and recovery

If CodexSwoop says a previous operation needs review, stop and check Codex and any unsaved work. Select **Check Again** only after reviewing the situation. It checks current process and environment evidence without launching or closing Codex or replaying the previous operation.

If the warning remains, new actions may stay blocked. Follow the on-screen details and contact the project maintainers with a redacted description if needed. Do not retry repeatedly, edit recovery metadata, or bypass the review.

## Settings

Settings includes:

- App language: System, English, Russian, or Uzbek (Latin).
- **Launch at Login**, which is optional and may require approval under macOS Login Items.
- Codex detection, **Refresh**, and an application picker.
- Read-only Accessibility status. The current account-opening path does not require Accessibility; window-specific features may need it.
- Saved Managed environments that can be restored, plus sanitized diagnostics when available.

Live Codex usage limits are not available in the current version.

## Limitations

- Profile names and environment references do not establish ChatGPT account identity.
- Opening requires a currently verified official Codex installation and coherent process/environment evidence. Ordinary updates are supported without a new CodexSwoop release; a not-individually-tested version notice is informational.
- Unknown process ownership or an uncertain operation can block more actions and require review.
- Closing multiple Codex instances is a series of normal-quit requests, not one atomic or reversible action.
- Managed directories do not guarantee complete authentication separation because services may be shared outside those directories.
- The planned public release targets Apple Silicon M1 or newer and macOS 14 Sonoma or later, pending runtime confirmation. Intel Macs are outside that target.

For implementation and security details, see [BUILDING.md](BUILDING.md) and [SECURITY.md](SECURITY.md).
