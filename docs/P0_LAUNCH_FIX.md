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
version and short status. Geometry is resampled on native events without timer polling.

## Existing launch-only pending operation

The real pair and prior recovery archive were inspected without mutation. The old
GUI generation is absent; the currently running GUI is a different generation.
An unrelated present instance, old socket error or missing historical process cannot
prove settlement. RC 3's original supersession is already consumed, so rerunning it
cannot retire this later operation. Do not replay, clear, complete or reinitialize it.

Build 7 implements a separately invoked, one-shot retirement for this exact shape:
schema 3, Open Separately, no target receiver or other instances, and one launch
intent without a receipt. `--inspect-launch-only --operation OPERATION_UUID` is
read-only. Applying requires separate human authorization and the exact token:

```sh
codexswoop-recovery --retire-launch-only \
  --consent 'retire-launch-only:STORE_UUID:OPERATION_UUID:JOURNAL_SHA256' \
  --accept-historical-outcome-unknown
```

Both existing locks span fresh strict native inventory, boot/build/signature and
catalog/root proof, archival verification and commit. Swoop must be stopped normally
by separate consent. This old launch has no captured receiver; accepting its unknown
historical outcome does not prove absence of a delayed dispatch or grant a retry.
Unknown/unbound current ownership still blocks. No process effect is performed.

The only replaced files are the active journal and watermark. A separate private
`UnresolvedLaunchOpening-<operation UUID>/` archive preserves their exact bytes and
the allowlisted catalogs. Its manifest chains the prior recovery provenance and
archive directory identity. `UnresolvedOpeningEpoch/`, catalog files and environment
directories are preserved. The same durable watermark-first protocol publishes a
schema-4 idle epoch with no settled operation and `historicalOutcome: unknown`.
Older readers reject schema 4. Only the same consent can resume exact prepared
bytes; a committed rerun cannot erase subsequent results or pending operations.
There is no startup migration or Reset. No real retirement was applied.

Real two-profile opening/activation/repetition after restart remains an acceptance
gate requiring separate recovery, installation and lifecycle authorization.

## CI and UI regression correction

The missing-bundle guard remains in place and its negative launch test passes.
The positive test compiles the unchanged production request source into a
physical-main-thread AppKit worker, checking the actual disposable receiver and
both roots. The build-7 CI failure reported worker status 5 without distinguishing
exit from signal. Explicit stderr capture and termination-reason checks reproduced
a separate SIGTRAP locally after LaunchServices returned: the worker force-unwrapped a nil
`NSRunningApplication(processIdentifier:)`. The probe's fixed two-second self-exit
could race the subsequent receiver lookup.

The focused macOS-15 diagnostic run traps earlier, after the request but before
its completion body. Apple's NSWorkspace header documents a concurrent callback
queue. The callback now explicitly declares `@Sendable`, preventing older SDK/compiler
imports from inheriting the caller's MainActor isolation. Its only captured state is
the existing lock-protected one-shot continuation; configuration, receiver validation,
timeout, ownership and lifecycle authorization stay unchanged. Remote validation of
this correction is recorded in the PR handoff.

The probe now stays alive until the worker verifies the receiver and writes an
acknowledgement into the disposable home; it always self-exits after 15 seconds if
unacknowledged. The worker checks exact bundle/date, records its receipt, acknowledges,
and requires self-exit within three seconds. The probe also reports its own PID,
which must equal the LaunchServices receiver. Failure remains a test failure with
explicit signal/exit and allowlisted stage/error diagnostics; missing receipt is
not treated as a secondary successful/ignored condition. No real Codex is controlled.
The test stays enabled in both full CI and an optional focused macOS-15 dispatch.

Native menu updates previously replaced NSMenu on every SwiftUI update. Window
observers also reasserted popover.show with an unchanged anchor. Menu identity is now
retained, updates defer during tracking, and an unchanged anchor is not reasserted.
Measured SwiftUI height and native size/frame updates defer until tracking ends,
including the intrinsic hosting-view resize path. The document measures its natural
height from a minimal bootstrap rather than a 560-point initial viewport.

## Local validation

Focused checks cover actual LaunchServices delivery to a disposable app, 222 setup
renders, native menu dispatch/identity, actual status-item movement, bounded scrolling,
diagnostic growth/shrink and unchanged geometry during tracking. Recovery checks
exercise 87 write stages with thrown errors and abrupt worker exits for each recovery
mode, preserving both profiles, catalogs and the prior archive.

The final validation totals and candidate hashes are recorded in the PR handoff.
Build 7 is version 1.0.0, arm64, ad hoc signed and unnotarized, with the embedded
recovery helper. The candidate manifest binds it to the exact source commit.
No real opening/activation/quit, pending retirement, app replacement or account
operation was performed. Real switching remains NOT TESTED; product acceptance
requires separately authorized recovery, installation and real lifecycle checks.
