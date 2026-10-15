# One-shot unresolved opening supersession

The RC 3 recovery executable implements the separately authorized proposal in
[RC_3_ACCEPTANCE.md](RC_3_ACCEPTANCE.md). It preserves the old operation as unresolved
and creates a different journal store UUID. It never calls `complete()` for the
old operation and never claims that activation, launch, switching or account
verification succeeded. The manifest records `historicalOutcome: unknown`.

This document describes the original RC 3 transition. That separately authorized
transition was completed previously; its archive remains immutable. Development
and new retirement QA use synthetic stores only. The later schema-3 launch-only
retirement has **not been performed**; see [P0_LAUNCH_FIX.md](P0_LAUNCH_FIX.md). The earlier `build/p0-live-preflight.log` is historical evidence: its
process generations and readiness must be sampled again at application time.

## Invocation and consent

The arm64 RC 3 DMG contains `Contents/MacOS/codexswoop-recovery` in the signed app.
It is a separate command, with no menu action, generic Reset, startup migration,
automatic retry or Check Again connection. `--help` reads no user metadata.

From the prepared checkout, a read-only inspection is:

```sh
build/release/CodexSwoop.app/Contents/MacOS/codexswoop-recovery --inspect
```

The helper detaches into a fresh process before observing official Codex, so its
inspection subprocesses do not contaminate Codex ancestry. The parent prints
`STARTED`; this means launch only. Wait for the child's `READY`, `BLOCKED`, or
`ALREADY_APPLIED` output. For a persistent operator record, redirect stdout/stderr
to an approved local log. Do not interpret the parent's exit status as completion.

Inspection prints the old store ID, operation ID, journal SHA-256 and exact consent
argument. It takes existing locks read-only and performs no bootstrap, repair,
archive creation, pair writes or process effects. A running Swoop reports BLOCKED.

After separate human approval to stop **only Swoop normally**, repeat `--inspect`.
If READY, the exact application syntax is:

```sh
build/release/CodexSwoop.app/Contents/MacOS/codexswoop-recovery \
  --apply \
  --consent 'supersede-unresolved:STORE_UUID:OPERATION_UUID:JOURNAL_SHA256' \
  --accept-historical-outcome-unknown
```

Replace the entire quoted argument with the exact `consent=` value from fresh
inspection. The command binds consent to both UUIDs and the original journal bytes;
a changed operation cannot inherit it. A suitable human authorization is:
“Stop only CodexSwoop normally and apply unresolved supersession for store
STORE_UUID, operation OPERATION_UUID, journal SHA256; I accept that its historical
outcome is unknown.” This documentation and QA do not provide that authorization.
The tool never stops Swoop itself. It refuses a write while Swoop is running.

Restart/installing Swoop also requires permission. The new epoch uses journal
schema **3**, retaining a hash-bound archive reference across future operations.
RC 3 reads schemas 2 and 3. An older RC 2 reader rejects schema 3; restarting RC 2
cannot complete recovery. Use the reviewed RC 3 candidate when separately authorized.
No version/build change or public release is needed for this recovery candidate.

## Preconditions and exact write scope

Both existing `opening-operation.lock` and `metadata.lock` must be owner-only,
single-link regular files and available for exclusive nonblocking locks. The tool
holds their descriptors for all observations, archival and commit; it rechecks
their identities and the private metadata root. It never creates/replaces locks.
A setup journal blocks every attempt. The process guard excludes only this exact
recovery helper PID when Launch Services associates it with the containing bundle;
an actual Swoop GUI, ambiguous matching bundle or another helper is never excluded.

Only a valid schema-2 pending pair with its matching watermark is eligible for an
initial transition. Each captured receiver, including activation/quit receivers
and their children, needs precise generation evidence. Every original PID must
be absent with kernel ESRCH; an existing PID of any generation, UID or state blocks.
An unreadable PID is reported as unproven absence, without assuming it is present
or gone. No inference from reboot or process replacement is accepted. Same boot session,
exact original build fingerprint/policy, signature, catalog digest, profile/root
identities and strict native ownership inventory are required. Inventory must
have zero unknown/unbound instances and precise current generations. Two complete
samples must agree; a third sample repeats the proof after archival, before commit.
No official Codex launch, activation, termination, retry or account operation exists
in this command.

The metadata root is `~/Library/Application Support/CodexSwoop`.
The only existing files replaced are:

- `opening-journal-watermark.json`
- `opening-journal.json`

A new private directory `UnresolvedOpeningEpoch/` contains:

- Exact old `opening-journal.json` and `opening-journal-watermark.json` bytes.
- Every existing file from `profiles.json`, `profiles.backup.json`,
  `environments.json`, `environments.backup.json`, `managed-environments.json`,
  `managed-environments.backup.json`, `retained-environments.json`,
  `retained-environments.backup.json`.
- `manifest.json`: old/new UUIDs, explicit consent, unknown historical outcome,
  SHA-256 of each allowlisted file (or explicit absence), root/Profiles identities
  and original catalog file identities.
- `epoch-commit.json`: new store ID, manifest hash and committed state.

The archive is 0700; files are 0600, owner-only, single-link regular files. It is
never overwritten with conflicting bytes. Catalog files and their identities
remain unchanged through preparation/resume; environment directories are only
stat/revalidated. Profiles contents, authorization, cookies, Keychain, preferences,
projects, logs, setup backups and account data are never traversed or copied.

## Crash protocol and reruns

1. Acquire existing locks, read the exact old pair/catalog snapshot and validate
   consent plus native proof. Any failure here writes nothing.
2. Create/fsync the private archive directory and copy each allowlisted file using
   private temporary files, file fsync, rename and directory fsync. Write/fsync the
   immutable manifest last, then verify the complete archive.
3. Recheck catalogs, locks, roots, PID absence, boot, build and inventory. Prepare a
   deterministic schema-3 idle pair derived from the manifest, with a new UUID,
   revision zero, no pending and **no settled operation**.
4. Persist/fsync the new watermark first, then the matching journal. A torn pair
   blocks ordinary reads. A full prepared pair also blocks ordinary reads because
   it lacks `epoch-commit.json`.
5. Verify the pair/archive; only after the pair's directory fsync succeeds, publish
   and directory-sync `epoch-commit.json`. Only this completed state permits normal
   schema-3 reads. Future journal writes retain archive provenance.

Before the new watermark, an interruption leaves the old pending operation active.
After the watermark, any torn or uncommitted pair remains review-required. Startup
and Check Again do not finish the transition. An explicit rerun with the same
consent performs fresh proof and resumes only this archive's exact old/torn/prepared
bytes. Unknown corruption, a different store/operation, changed catalogs/identities,
changed boot/build/processes, or a damaged archive/commit record fails closed.
Conflicting archive files are preserved, never repaired or deleted automatically.
An abrupt atomic-write interruption may leave private `.profiles-write-*` temporary
files. They grant no recovery authority and are never used as fallback evidence.

A successfully committed transition is consumed permanently. Repeating the same
request returns `ALREADY_APPLIED`, without changing bytes, UUID or revision. It
cannot discard a subsequent pending operation. Different consent is refused.
The archive/commit record must remain present for normal schema-3 reads.

Atomic rename plus fsync is tested on the local filesystem; physical power loss,
controller caches and arbitrary same-UID tampering/full-volume rollback are not
claimed to be solved. A failed final directory fsync can leave a visible complete
commit; inspect its actual state instead of inferring success from an error or
replaying any official process effect.

## Synthetic validation

`./scripts/check-epoch-recovery.sh` compiles a separate QA executable against the
testable core. Its injection interfaces are internal; the shipped tool cannot
select a mock probe, arbitrary root or fault hook. Every QA store is a fresh
`/private/tmp/codexswoop-epoch-qa-*` fixture, with no native adapter invoked.

The matrix covers every normal/resume fault hook with both thrown I/O failures and
abrupt `_exit` in a disposable worker: directory creation, allowlisted archive
copies, manifest file fsync/rename/directory fsync, archive verification, new epoch
pair publication, commit publication, explicit rerun and repeated success. It
checks exact original evidence, profile/binding preservation, no synthetic process
effects, ordinary-reader/Check Again blocking and successful idempotence. Negative
cases cover live Swoop, locks, setup journal, missing precision, PID reuse,
boot/build/signature changes, unknown/changed inventory, catalog replacement,
corrupt/future journals, cancellation and archive tampering.
