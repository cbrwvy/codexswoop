# P0: newly launched receiver continuity (build 8)

## Evidence and limits

The read-only incident inspection found a schema-2, revision-5 pending
`closeOthersAndOpen` operation with no other instances and no pre-existing target.
The journal and watermark agree, retain a LaunchServices receiver and a launch plus
activation intent, and record `processChanged`. The failure was written at
13:21:35.120 +05:00 on 15 October 2026. The journal has no stage field or dispatch
acknowledgement; an activation intent does not prove native activation occurred.

The receiver's microsecond GUI generation, native launch date and live signing
identity still matched. Three successful strict ownership observations confirmed
the target roots under this same GUI, while full snapshot equality against the
recorded activation instance returned false. Its early direct backend was no
longer present; later direct backends and Electron helpers were present. The
later sampled helpers/backends started after the recorded failure. These later
snapshots establish receiver continuity and tree change, not the exact tree at
the historical failing instruction.

The old code compares the entire `DesktopInstance`, including `related`, in native
activation preflight, foreground ownership postflight, driver verification and
sequential inventory comparison. That makes a freshly validated descendant-tree
change indistinguishable from a GUI replacement. A regression on the unchanged
code reproduces `opening(processChanged)` after a successful synthetic launch
and activation with zero other instances and a new descendant under the same
signed, precisely identified GUI. The direct failing driver check in that
reproduction is `verifyEnvironmentAccount`'s observation equality guard.

The historical build-7 throw cannot be uniquely assigned to one of these guards,
or to an observation's transient generation/ancestry check: build 7 did not
record that distinction. Do not label the synthetic throw site as an observed
historical stack trace. Safe, optional closed-vocabulary failure stages now
separate native activation preflight/dispatch/postflight and driver verification,
inventory, foreground and journal completion for future operations.

## Fix boundary

Only a target launched by the current confirmed scope can retain receiver
continuity across descendant-tree changes. The match requires the full GUI
`DesktopGeneration` (including UID and microsecond start time), native launch
date and signing identity. Differing snapshots without precise generation and
signature evidence are rejected. Every observation still goes through strict
root, direct backend, ancestry, publisher, directory and default-root checks.
Read-only post-launch target observations use the existing bounded readiness
wait and require two consecutive complete snapshots tied to the exact receiver.

Sequential complete inventories may differ in that newly launched target's
validated descendants. Other entries, association identities, entry counts and
unknown-instance rejection remain strict. Full `DesktopInstance.Equatable`,
normal-quit groups, existing-target operations, durable recovery reconciliation,
IPC routing and lifecycle consent remain unchanged. No new GUI generation may
replace the LaunchServices receiver. No effect is retried by the observation
wait. Unconfirmed results retain the durable pending journal.

## Regression coverage

- Zero-other Close Others & Open completes launch, activation, postflight and journal.
- Delayed backend and transient incomplete snapshots wait for a stable exact receiver.
- New target inventory continuity accepts tree growth only for the intended association.
- Same-PID generation reuse, changed native launch date, changed signature and absent signature fail closed.
- Unknown/foreign inventories and existing-target tree changes remain rejected.
- Generation failure retains receiver, failure stage and journal bytes after restart without effects.
- Existing synthetic LaunchServices receiver and IPC alias tests remain enabled.

The installed build and the live pending record were not modified. Real lifecycle
acceptance of build 8 is **NOT YET VERIFIED**; local synthetic/native checks do not
establish a successful real profile opening, account identity or isolation.

## Local validation

The new regression failed with `opening(processChanged)` before the fix. All 16
focused P0 tests pass after it. One complete `scripts/check.sh --require-xctest`
run passed: 535 CoreChecks, 127 SwiftPM XCTest, 127 native XCTest, 101 isolation
Python tests, 20 release-tooling tests, recovery-helper checks, universal native
Debug/Release/Archive, bundle/resource checks and local ad hoc signatures.
The separately packaged arm64 build 8 DMG, bundle and helper were validated.
No CI result or real profile-opening acceptance is implied by these local checks.
