<p align="center">
  <img src="Resources/Branding/DualSpark-AppIcon-Master.svg" alt="CodexSwoop Dual Spark icon" width="88">
</p>

<h1 align="center">CodexSwoop</h1>

<p align="center"><strong>Multiple local Codex profiles. One Mac.</strong></p>

<p align="center">A native macOS menu bar app for organizing local profiles and their Codex environments.</p>

<p align="center"><sub>1.0.0 · Stable release · Build 15 · Apple Silicon arm64 · MIT License</sub></p>

<p align="center">
  <img src="docs/assets/screenshots/codexswoop-overview.png" alt="CodexSwoop menu bar popover with two fictional profiles" width="480">
</p>

<p align="center"><em>Product overview · Off-screen render with fictional profiles and state.</em></p>

## Why CodexSwoop?

Keep local Codex environments organized under profile names you choose. CodexSwoop points to environments used by the official Codex app; sign-in stays in Codex.

A profile name is only a local label and does not verify which ChatGPT account is signed in. Adding, renaming and removing profiles does not require a particular Codex version or a verified Codex installation. Metadata integrity and pending-recovery safeguards still apply.

**Add Account** and **Open Separately** perform fresh validation when clicked and remain available when older opening history needs review. Opening leaves other profiles running. **Close Others & Open** retains confirmation and recovery checks. Find the latest 500 sanitized errors under **Settings → Diagnostics → Open error log**.

## Features

- Link the standard Codex environment or prepare a separate Managed environment.
- Open a linked environment separately when its publisher, installation and ownership checks allow it.
- Use **Close Others & Open** with confirmation when running instances can be identified safely.
- Rename or remove local profile records without deleting underlying Codex authorization directories.
- Review Codex detection and Accessibility status, change the app language, and configure Launch at Login in Settings.

## Screenshots

These illustrative off-screen renders use synthetic project fixtures. Some captures show earlier UI states; they are not recordings of signed-in user accounts.

<p align="center">
  <img src="docs/assets/screenshots/settings.png" alt="CodexSwoop Settings with language, launch, Codex detection, and Accessibility sections" width="500">
</p>

<p align="center"><em>Settings · Synthetic UI fixture.</em></p>

## How It Works

CodexSwoop stores local profile and environment-reference metadata. The official Codex app remains responsible for authentication.

- **Standard External** links to the standard Codex environment already on the Mac. Linking does not copy or inspect sign-in credentials.
- **Managed** prepares separate local Codex environment directories. Sign in through the official Codex app after opening one.
- Separate directories do not guarantee complete authentication isolation; shared macOS services, browser sign-in, and Codex behavior can affect environments.

## Installation

Download **1.0.0 (build 15)** from the [v1.0.0 Release](https://github.com/cbrwvy/codexswoop/releases/tag/v1.0.0):

- `CodexSwoop-1.0.0-macos-arm64.zip`
- `CodexSwoop-1.0.0-macos-arm64.zip.sha256`

Place both files in the same directory and verify the checksum:

```sh
shasum -a 256 -c CodexSwoop-1.0.0-macos-arm64.zip.sha256
```

Extract the ZIP, move `CodexSwoop.app` to Applications, and open it from there. Its controls appear in the menu bar. Existing build 15 users already have the same production application.

**The app is ad hoc signed, has no Developer ID signature, and is not notarized. No notarization ticket is stapled. Gatekeeper may block first launch; seamless first-launch acceptance is not promised.** Review the macOS Privacy & Security message before deciding whether to allow the app. Do not disable Gatekeeper or remove quarantine attributes. See the [1.0.0 Release Notes](docs/RELEASE_NOTES_v1.0.0.md).

## Getting Started

With a verified official Codex installation, follow [Getting Started](docs/GETTING_STARTED.md) to link an existing environment or prepare a Managed one.

## Privacy & Safety

CodexSwoop does not import tokens or cookies into its profile metadata. Removing a profile removes its CodexSwoop record and active link; it does not delete underlying Codex authorization directories or close a running Codex instance. A removed Managed environment may remain available to restore in Settings.

Instance ownership checks are conservative. An unknown instance may block an operation or require review. Closing several instances is not atomic, and an uncertain result can need manual review. **Check Again** rechecks current processes and environment ownership without launching or closing Codex.

See [Security](docs/SECURITY.md) for the project's security boundaries.

<p align="center">
  <img src="docs/assets/screenshots/recovery.png" alt="CodexSwoop menu showing a previous operation review warning and Check Again" width="360">
</p>

<p align="center"><em>Recovery review · Synthetic operation-review fixture.</em></p>

## Compatibility & Limitations

- **Apple Silicon arm64 only** (M1 or newer). The app and recovery helper declare **macOS 14.0** as their minimum; macOS 14 runtime acceptance has not been performed. Intel is not supported by the downloadable artifact.
- Real acceptance used **macOS 27.0.1** and official **Codex 26.1007.71326**: two profile windows, separate opening, normal closure of the second profile while retaining the first, reopening, repeated activation and context menus. Automated CI runs on **macOS 15 / Xcode 16.4**. Clean-machine and VM acceptance are not claimed.
- Official Codex must be at **`/Applications/ChatGPT.app`** and pass publisher, canonical-path and environment-ownership checks. Version/build numbers and the app's older reference-version notice are informational; an update can still introduce untested behavior.
- ChatGPT account identity is **not technically verified**. Full authentication isolation is **not guaranteed**. Verify the signed-in account yourself inside Codex. **Live Usage is unavailable**.
- A cold launch can log an ownership-readiness or process-change diagnostic while its window starts. In real acceptance, the window opened and subsequent ownership observation and activation succeeded.
- Unknown ownership or an uncertain closing operation can require manual review. Closing several instances is sequential and can be partial; save work before confirming.
- The ZIP contains an **ad hoc-signed, non-notarized** application, with **no Developer ID or stapled ticket**. Gatekeeper acceptance is not claimed.

## Documentation

- [User Guide](docs/USER_GUIDE.md) · profile actions and their limits
- [Troubleshooting](docs/TROUBLESHOOTING.md) · common issues and recovery steps
- [Security](docs/SECURITY.md) · security boundaries

Report bugs through [GitHub Issues](https://github.com/cbrwvy/codexswoop/issues), including version/build, macOS version, Apple Silicon model, supported Codex version, action, expected result, and actual result. Issues and pull requests are welcome. Use fictional profiles in reproduction steps and remove personal information from diagnostics. Never attach credentials, cookies, authorization files, or private account data.

## Building from Source

See [BUILDING.md](docs/BUILDING.md) for build and development instructions. No account credentials are needed to compile the project.

## License & Disclaimer

CodexSwoop is distributed under the [MIT License](LICENSE). It is an independent project, not affiliated with, endorsed by, sponsored by, or officially supported by OpenAI.
