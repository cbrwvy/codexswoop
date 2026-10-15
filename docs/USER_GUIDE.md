# User Guide

Applies to stable **1.0.0 (build 15)** / `v1.0.0`, distributed for Apple Silicon arm64. Both executables declare macOS 14.0 as their minimum. Real two-profile acceptance used macOS 27.0.1 and official Codex **26.1007.71326**; automated CI uses macOS 15 / Xcode 16.4. macOS 14 runtime, Intel, clean-machine and VM acceptance are not claimed. Official Codex at `/Applications/ChatGPT.app` must pass current publisher, installation and environment-ownership checks. Version/build numbers and the older reference-version notice are informational. The app is **ad hoc signed and not notarized**, with no Developer ID or stapled ticket; Gatekeeper may block first launch. Technical ChatGPT identity verification and full authentication isolation are not guaranteed. Live Usage is unavailable. See [Release Notes](RELEASE_NOTES_v1.0.0.md) for installation and limitations.

## Local profiles and ChatGPT accounts

A profile is a local CodexSwoop record: a name you choose and, when linked, a reference to a Codex environment. It is not an authenticated account record. CodexSwoop does not guarantee that the ChatGPT account you expect is signed in to that environment. Confirm identity in the official Codex app.

## Standard External and Managed environments

| Type | What it refers to | What it does not mean |
| --- | --- | --- |
| **Standard External** | The standard Codex environment already on this Mac. | CodexSwoop has not copied its credentials or verified its ChatGPT identity. |
| **Managed** | A separate set of local Codex environment directories prepared for a profile. | Separate directories do not prove complete authentication isolation across macOS, browser, or Codex services. |

Sign in only through the official Codex app. CodexSwoop does not import tokens or cookies into its profile metadata.

## Profile actions

- **Open Separately** activates or launches Codex using the selected environment without an extra confirmation. Identity is not verified by the profile label or by successful opening.
- **Close Others & Open** requests normal closure of other identified Codex instances one at a time, then opens the selected environment. The action can stop when an instance is unknown or checks change. It is not atomic; some instances may already have closed if a later step fails.
- **Recheck** validates the saved environment reference.
- **Confirm account manually** records your own visual check as a local note. It does not prove account identity or unlock account verification.
- **Disconnect** removes the active link from the profile while retaining the environment data.
- **Rename** changes the local display label only.
- **Remove** deletes the profile record and active link. It does not delete the underlying Codex authorization directories, projects, or a running Codex instance. A removed Managed environment can remain in Settings for restoration. Metadata backups may retain an earlier profile name.

## Opening behavior and confirmation

Each opening attempt uses the supported-build and environment-ownership checks available in the current build. Open Separately starts from the profile menu without an extra confirmation. Closing other instances requires its own confirmation. Cancel when you cannot review the affected instances or their state.

Activity status may be **Unknown** because CodexSwoop cannot establish complete activity information. Unknown is not idle. A user confirmation is per attempt and does not change the status. An instance with unknown ownership can block **Close Others & Open** altogether.

## Warnings and recovery

If CodexSwoop says a previous operation needs review, stop and check Codex and any unsaved work. Select **Check Again** only after reviewing the situation. It checks current process and environment evidence without launching or closing Codex or replaying the previous operation.

Older opening history does not block Add Account or Open Separately. These actions perform fresh validation on each click. Closing other instances still requires resolving unfinished closing operations and explicit confirmation. Do not edit recovery metadata. Errors are recorded locally; open **Settings → Diagnostics → Open error log** to review the latest 500 entries, containing a timestamp, action and sanitized error code.

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
- The release artifact is Apple Silicon arm64 only (M1 or newer), with a declared macOS 14.0 minimum. Runtime acceptance covers macOS 27.0.1; macOS 14 and Intel acceptance are not claimed.

For implementation and security details, see [BUILDING.md](BUILDING.md) and [SECURITY.md](SECURITY.md).
