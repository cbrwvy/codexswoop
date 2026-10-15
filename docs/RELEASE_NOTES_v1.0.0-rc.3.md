# CodexSwoop 1.0.0 RC 3 — candidate

- Keep the menu within the current display's available height. Profiles and the
  complete menu, including warning blocks and controls, remain scrollable; screen,
  status-button movement and backing-scale changes recalculate the height budget.
- Explain why opening recovery is blocked: distinguish journal format/pair errors,
  legacy metadata without a journal, storage/lock failures, changed target generations
  and changed boot sessions. Preserve the specific failed proof in Details.
- Verify clean-store initialization with preserved unused environments, two-profile
  persistence, repeated opening and unresolved recorded launch/activation evidence.
- Retain RC 2 compatibility with official Codex updates using publisher signatures,
  dynamic installation evidence and generation-aware operations, without version pins.

The diagnosed installed RC 2 has a consistent pending journal whose activation
receiver has been replaced. This candidate preserves that unresolved evidence;
it does not claim a false startup recovery fix or historical activation success.
A separately authorized metadata transition is required for that store.

Real Open Separately / Close Others & Open acceptance is **NOT YET VERIFIED**.
Version 1.0.0, build 6. Apple Silicon arm64, macOS 14 minimum. App and DMG are ad hoc
signed and not notarized. Account identity and Live Usage limitations remain.
This candidate is not published; merge and GitHub Release need separate approval.
