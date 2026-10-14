# P0 launch and menu correction

## Confirmed fault and limits of the historical evidence

The historical official desktop application log reports repeated `IpcRouterManager`
`listen EINVAL` errors for `$CODEX_HOME/ipc/ipc.sock`. The affected managed home
produces a 125-byte socket pathname; Darwin's `sockaddr_un.sun_path` has 104 bytes,
including its terminator. A disposable long-path socket bind reproduces the failure;
a short alias to the same empty directory binds successfully.

LaunchServices created the GUI. Application logs also record a connected stdio
app-server and a window `ready-to-show`. They do not establish which window the
operator saw, historical descriptor ownership, or the exit status of `/usr/bin/open`.
The old journal records only launch intent, without a receiver or failure cause.
The exact historical ownership/readiness refusal cannot be reconstructed. Generic
XPC/certificate messages are not evidence of this fault's cause.

The installed application code explicitly honors `CODEX_ELECTRON_USER_DATA_PATH`,
sets Electron `userData` from it, preserves the supplied `CODEX_HOME` across shell
environment loading, and uses the same paired flags in its own isolated demo launch.
The IPC socket path is formed lexically under `CODEX_HOME`; there is no IPC-path
configuration override in that code. These are implementation observations for the
inspected installation, not a future compatibility or account identity guarantee.

## Correction

For an overlong home, `DesktopLaunchPaths` supplies stable short home/Electron links
in an owner-only runtime directory under `/private/tmp`. Names bind both original
paths and directory identities. Existing entries must be exact owner-owned links;
parents must be real private directories. Each link's target and actual directory
device/inode/owner/mode are checked. Links are not redirected, cleaned up, or adopted
from conflicting entries. Original data directories and association metadata stay
in place. Alias creation occurs only after the existing operation confirmation;
read-only observations never create them. After a reboot missing aliases can be
recreated for a separately confirmed launch. No authorization files are inspected.

Native launch now uses `NSWorkspace.openApplication` with a new-instance,
nonactivating configuration and explicit paired environment/argument values. Its
bounded completion identifies the exact GUI receiver. The receiver's precise kernel
generation, native launch date and publisher signature are recorded durably before
backend readiness. A matching PID alone is insufficient. Two stable strict snapshots
must prove Electron ownership by the GUI and home ownership by its direct backend,
exclusive lineage, unchanged generations, publisher trust and no default-root mixing.
A GUI home descriptor is no longer additionally required: transient file reads and
failed socket binds do not guarantee that the GUI keeps such a descriptor open.

Activation and journal completion still require the original postflight checks.
Readiness cannot substitute a different receiver. Allowlisted failure codes survive
restart; no raw command stderr, application log payload, path or account data is
written to diagnostic records. Restored receipt evidence can reconcile only the
same freshly owned generation, same boot, build, catalogs and roots. It grants no
process effect or account claim. Missing old receipts remain unresolved.

The menu uses one scroll view with a measured, explicitly bounded content height.
The anchor derives the space below the actual status button from `visibleFrame`,
explicitly hands measured height to native contentSize after the SwiftUI layout
transaction (preferredContentSize alone was observed to stay unapplied), measures
native chrome after showing, tracks content resizing and clamps positioning
below the menu bar. Compatibility details stay in Settings; the footer retains
version and short status. No screen coordinates are cached or polled.

## Existing launch-only pending operation

The real pair and prior recovery archive were inspected without mutation. The old
GUI generation is absent; the currently running GUI is a different generation.
An unrelated present instance, old socket error or missing historical process cannot
prove settlement. RC 3's original supersession is already consumed, so rerunning it
cannot retire this later operation. Do not replay, clear, complete or reinitialize it.

A separately approved one-shot retirement must first preserve the exact current
pair AND existing archive, all allowlisted metadata, hashes, directory identities
and `historicalOutcome: unknown` in a new immutable archive. Consent must name the
current store, operation and pair hash. Both existing locks must span fresh native
inventory/signature/boot/catalog proof, archival verification and any pair change;
Swoop must be stopped normally by separate consent. Original receiver absence and
lack of delayed dispatch must be established, or the operator must explicitly accept
an unresolved historical outcome. A distinct retirement provenance/commit record
must bind the new pair to both archives; it must never call historical `complete()`
or overwrite the old archive. This is the exact recovery write scope for separate
review, not an enabled Reset or permission to run it. The shipped RC 3 helper
intentionally refuses this later launch-only case. No retirement was applied.

Real two-profile opening/activation/repetition after restart remains an acceptance
gate requiring separate recovery, installation and lifecycle authorization.

## Local validation

- The socket-path XCTest first failed against RC 3, then passed after correction.
- `scripts/check.sh --require-xctest`: 535 CoreChecks, 101 IsolationLab tests,
  87 recovery fault stages / 4032 assertions, 20 ReleaseTooling tests, 121 SwiftPM
  XCTest and 121 native XCTest; universal native Debug/Release and Archive passed.
- 222 account/setup renders passed. After the final menu-only sizing correction,
  24 focused menu renders passed; final Debug and Release app bundles were rebuilt.
- Native AppKit QA exercises actual status items, anchor movement, screen containment,
  a 240-point menu budget, footer scrolling and diagnostic size changes.
- Computer Use confirmed the installed RC 3 clipping and both disabled opening menus.
  The corrected isolated GUI displays two linked fictional profiles, both enabled
  context menus, full header/footer and concrete diagnostics. Its adapter is synthetic.
- No real opening/activation/quit, pending retirement, app replacement or account
  operation was performed. Real switching remains NOT TESTED.

The final local candidate remains version 1.0.0 build 6, labeled P0 Final in its
packaging directory and bundle metadata. Its source commit, file hashes and DMG
checksum are supplied in the local candidate manifest and PR handoff. It is ad hoc
signed and unnotarized; it is not a GitHub Release or real runtime acceptance.
