# CodexSwoop RC 3 acceptance and unresolved recovery

Candidate: 1.0.0 (6), planned tag `v1.0.0-rc.3`, Apple Silicon arm64,
ad hoc signing, non-notarized. No installation, tag, merge, or publication is authorized
by candidate preparation. Real lifecycle acceptance is **NOT YET VERIFIED**.

## Confirmed installed RC 2 diagnosis

A one-shot read-only inspection found two profiles and two current associations.
The opening journal schema is 2; watermark schema is 1. Store IDs, revision (3),
and the SHA-256 of the exact journal bytes agree. State is pending, with launch
and activation evidence, no settled record, and no setup journal. Both files are
owner-only regular files. No environment or credential contents were opened.

The captured boot session, catalog digest, current official installation fingerprint,
policy, and version match. A detached native read-only observation found one owned
current instance and no confirmed zombies. The recorded activation receiver does
**not** match that instance: main generation, GUI launch date and related generations
differ; signature identity matches. The other current association is not running.
The detached helper prevents its own subprocesses from contaminating Codex ancestry.

The current blocker is a genuine pending journal, followed by failure of the exact
receiver-generation recovery proof. It is not `legacyUninitialized`, a torn pair,
or a clean-store initialization failure. `restoreOpeningRecovery()` restores the
coordinator latch; `ProfileManager.reload()` disables opening while it is latched.
Check Again cannot prove that a replacement process completed the recorded activation.
The journal does not contain the original error, so the original failure after
launch/activation cannot be determined from this evidence. Historical success is
unproven. The older pre-journal operation is also not declared completed.

RC 3 makes the generation/boot mismatch and each journal error distinguishable in
Details and preserves the failed reason after unrelated messages are dismissed.
It retains all proof requirements. It will **not** automatically unblock this real
store. Fresh stores, including retained unused environment directories, remain idle;
regressions verify initialization, two-profile persistence and repeated opening.

## Part A: no official process effects

- [ ] Verify the candidate shows version 1.0.0, build 6, correct bundle ID/signature.
- [ ] Compare journal/watermark and all profile/association metadata with the reviewed
      backup; preserve pending evidence. Do not run a bootstrap as a diagnostic.
- [ ] Verify both profiles and bindings survive Swoop restart.
- [ ] In a fresh synthetic store, no false review appears and both commands are enabled
      when installation/association checks pass.
- [ ] In the real unresolved store, review remains visible and both actions remain
      blocked with an accurate reason. This is a blocker for working-switch acceptance.
- [ ] Verify the menu stays within visible bounds, profiles scroll, warnings, Add Account,
      Settings and Quit remain reachable on small screens and after display/scale changes.
- [ ] Verify installed official Codex version/build and signature status are current;
      last-tested version remains informational.

Only RC 2 version/storage/native observations above have been performed on the real
installation. Candidate installed UI and multi-display behavior are **NOT YET VERIFIED**.
Synthetic rendering/bounds evidence is recorded separately in RC_3_VALIDATION.md.

## Separately authorized metadata recovery proposal

This is a concrete proposal, **not performed** and not a declaration of prior success.
A normal Check Again must remain blocked when the exact recorded receiver is gone.

1. Obtain explicit consent to archive this unresolved opening and establish a new
   store epoch, accepting that its historical result cannot be proven. Merely clicking
   Check Again or confirming account identity does not authorize this intervention.
2. Stop only CodexSwoop normally with separate operation-specific permission. Do not
   start, activate, close or restart official Codex. Acquire the existing metadata and
   opening-operation locks; abort on a live owner, setup journal or changing catalogs.
3. Revalidate official signature/build, root identities and complete native inventory
   twice. Require every captured original process PID to be absent with no PID reuse,
   no unknown/unbound instances, and stable current ownership. If these conditions
   fail, preserve the block and change nothing.
4. Make an owner-only backup of the allowlisted Swoop metadata and exact journal pair,
   verifying byte hashes. Do not traverse/copy Profiles, auth, cookies or credentials.
5. Preserve the original pair in an unresolved evidence archive with a manifest that
   explicitly records unknown historical outcome and user-authorized supersession.
   Establish a fresh journal/watermark store ID only under a reviewed one-shot
   transition. Do not label the old pending record settled or feed it to `complete()`.
   Existing automatic/fresh/legacy initializers are not authorization for this step.
6. Require profile, association, managed and retained catalog bytes and directory
   identities to remain unchanged. Verify the new pair and archive before restarting
   only Swoop. An interrupted or inconsistent transition must fail closed.

The app has no generic reset or history-discarding control. This transition is held
for a separate explicit authorization and reviewed implementation; no migration
or replay is part of this PR. If authorization is not given, retain the installed
store and pending journal unchanged.

## Part B: real lifecycle operations

Requires separate explicit user permission after Part A and recovery are resolved.
All items currently **NOT YET VERIFIED**.

- [ ] Open Separately for the first profile; verify the expected environment visually.
- [ ] Open Separately for the second; verify both environments remain distinct.
- [ ] Reopen an already-running environment; verify exact-instance foregrounding.
- [ ] Close Others & Open with fresh explicit consent; verify only allowed instances
      exit normally, complete exit is observed, and the selected environment opens.
- [ ] Restart only Swoop; verify profiles/bindings and an idle consistent journal.
- [ ] Repeat switching in both directions; no stale latch or false success.

Manual visual account confirmation is operator evidence, not technical ChatGPT
identity or Live Usage verification. Automated fixtures do not close these gates.
