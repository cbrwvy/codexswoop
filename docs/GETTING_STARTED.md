# Getting Started

This guide describes the current pre-release interface. Local profile management is independent of the Codex version. Opening requires a verified official installation and coherent process/environment evidence.

## What is CodexSwoop?

CodexSwoop is a macOS menu bar app for keeping local profile names and Codex environment references together. Authentication takes place in the official Codex app. A profile name does not confirm which ChatGPT account is signed in.

## Requirements

- CodexSwoop **1.0.0 (5)**, experimental `v1.0.0-rc.2`, **Apple Silicon arm64 only**.
- Deployment target **macOS 14.0**; Sonoma runtime acceptance is not performed. Automated checks run on **macOS 27.0.1 (26A434)**; final installer/first-launch acceptance remains untested.
- Official Codex at **`/Applications/ChatGPT.app`**, with valid OpenAI publisher signature, Bundle ID, Team ID, executable and canonical path. Ordinary updates require no new version allowlist. Last individually tested: **26.1007.21159 (20052)**; other versions show an informational untested notice. Other installation locations remain unsupported for opening.
- No technical ChatGPT identity verification or guarantee of full authentication isolation. Live Usage is disabled; identity verification and Live Usage are deferred to 1.1.
- The first DMG contains an **ad hoc-signed** app and is **not notarized**. Read the [installation and Gatekeeper instructions](RELEASE_NOTES_v1.0.0-rc.2.md). RC 2 publication is pending approval.

For development builds, use [BUILDING.md](BUILDING.md).

## First launch

1. Open CodexSwoop. Its controls are in the macOS menu bar.
2. Select **Add Account** and choose a setup method.
3. If CodexSwoop reports that Codex is missing or unverified, open Settings and select **Refresh** or **Check Again**. Confirm official Codex is at `/Applications/ChatGPT.app`; a different version alone is not a blocker. A different path, invalid publisher signature or incoherent installation can still block opening. You can prepare local profiles while Codex is absent or unverified.
4. CodexSwoop does not ask for Accessibility permission automatically. Launch at Login is optional.

## Use Existing Codex

1. Select **Add Account** and choose **Use Existing Codex**.
2. Enter a profile name, such as `Personal`, and continue.
3. CodexSwoop links the profile to the standard Codex environment already on this Mac. It does not sign in again or copy credentials.

The name is only a label in CodexSwoop. Check the signed-in account in the official Codex app whenever identity matters.

## Sign In to Another Account

1. Select **Add Account** and choose **Sign In to Another Account**.
2. Enter a profile name, such as `Work`, and continue. CodexSwoop prepares a Managed environment; it does not authenticate for you.
3. Open the profile menu and choose **Open Separately**. Review and accept the confirmation to open its environment.
4. Complete sign-in inside the official Codex app.

Separate local directories are not a guarantee that every macOS or browser authentication service is isolated.

## Managing profiles

Use the profile's **More** menu to recheck its environment link, add a manual account note, disconnect the link, rename the profile, or remove it. A manual note is not technical account verification and does not prove ChatGPT identity.

## Open Separately

Open the profile menu and choose **Open Separately**. CodexSwoop asks you to confirm, then attempts to activate the linked running environment or launch Codex with that environment. This does not confirm the ChatGPT account identity. The action can be unavailable when the current Codex signature, installation or environment evidence cannot be verified; a version mismatch alone does not block it.

## Close Others & Open

Choose **Close Others & Open** only after reviewing the confirmation and the listed instances. CodexSwoop requests normal closure one instance at a time. If an instance cannot be attributed to a linked environment, the operation can stop. Activity can also be **Unknown**; accepting a warning does not turn unknown activity into idle activity. Closing several instances is not atomic, so an operation can be partial.

Cancel if you cannot confirm that it is safe to continue. If an operation has an uncertain result, use **Check Again** before attempting another opening action.

## Removing profiles safely

1. Open the profile's **More** menu and select **Remove**.
2. Read and confirm the removal prompt.

Removal deletes the CodexSwoop profile record and active link only. It does not sign out, delete Codex authorization directories or project files, or close an already running Codex instance. A removed Managed environment may be listed in Settings so it can be restored.

Continue with the [User Guide](USER_GUIDE.md) or [Troubleshooting](TROUBLESHOOTING.md) for more detail.
