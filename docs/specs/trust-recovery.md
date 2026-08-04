# Trust Recovery — Reimplementation Contract

**Status:** approved for implementation (2026-08-04).

This spec reimplements the eight behavior changes unique to the stale
`trust-recovery-0.7.0` branch on current `main`. The old commits are evidence
of desired behavior, not patches to cherry-pick. Work belongs to release 0.13.0
and introduces no schema or backup-format change.

## Boundaries

- **TR-00 — Current architecture wins.** Reuse current services and data models;
  do not restore obsolete persistence wrappers or UI structure from the old
  branch. `SettingsView` has one sequential owner. Transaction work starts only
  after Overview Phase 3 validates the current Transactions contract.
- **TR-00.1 — Failure safety.** A failed user-initiated money write reports the
  error, rolls back the attempted context change when applicable, preserves the
  editor/draft for correction, and never presents success.
- **TR-00.2 — Data safety.** Tests use in-memory containers or temporary
  application-support paths. No task here touches a production store or app.

## Acceptance requirements

| ID | Behavior | Automated evidence | Manual evidence |
| --- | --- | --- | --- |
| **TR-01** | Import reports show each failed row with its actionable reason, rather than one opaque failure. | `IngestPipelineTests` with multiple independently invalid rows. | Import a disposable malformed file and inspect all rows. |
| **TR-02** | Unsupported paste import explains why it is unavailable and offers an accessible semantic `Button`; keyboard and VoiceOver can reach and activate it. | `PastedHsbc2NowParserTests` for supported/unsupported routing. | Keyboard focus and VoiceOver navigation in Paste Import. |
| **TR-03** | Restore requires explicit confirmation, supports Cancel, progress, and visible failure. Existing user data selects `mergeKeepingNewer`; an empty store alone selects `replaceAll`. The preflight recognizes all persisted financial rows, including `SettlementDueDateOverride`. | `BackupArchiveTests`, `AccountDeletionServiceTests`, temporary-path reset coverage. | Cancel, merge, replace, invalid archive, and failing archive with disposable data. |
| **TR-04** | Financial identity edits use a draft with explicit Save/Cancel. Save uses direct `context.save()`; failure uses `rollback()` and leaves the draft/editor visible. Existing stock-position controls remain. | Focused account/portfolio/retirement tests plus a save-failure seam. | Edit, cancel, successful save, and forced failure. |
| **TR-05** | Transaction and pending-import money writes surface failures. A failed save leaves the editor/review state usable and does not claim completion. | Focused pending-resolution and Household inclusion tests. | Force a save failure in a disposable store. |
| **TR-06** | Soft-delete requires confirmation and explains Recently Deleted recovery. | Transaction state test. | Delete, cancel, confirm, and restore. |
| **TR-07** | “Keep Deleted” links the existing soft-deleted row and removes the pending review; it never fabricates a zero-amount transaction. Transaction mutation and due-date purge share one save boundary. | Pending-resolution, `HouseholdInclusionTests`, and due-date purge tests. | Resolve a matched-deleted import. |
| **TR-08** | The ledger shows a duplicate badge and filters active matched duplicates. Recently Deleted disables that active-only filter; Clear/reset restores both controls. | `DeduplicatorTests` and pure filter-state test. | Toggle duplicate, deleted, and clear controls. |

## Implementation order

1. Implement TR-01 and TR-02 in `codex/trust-import-diagnostics`.
2. Implement TR-03, then TR-04, on the single `codex/trust-settings-safety`
   branch; do not edit `SettingsView` concurrently elsewhere.
3. After Overview Phase 3 is approved, implement TR-05 through TR-07 in
   `codex/trust-transaction-recovery`.
4. Implement TR-08 in `codex/trust-duplicate-observability` after TR-05–07.

`Persistence` must not grow a new generic abstraction solely for these paths.
For the pending-import path, extract only the mutation that needs direct unit
testing. Account drafts are value-state, not a second persistence model.

## Verification, rollback, and handoff

- Each branch runs its named focused tests, relevant reset/dashboard coverage,
  Debug build, full serial suite, Domain Decimal guard, and `git diff --check`.
- The first independent review checks error states, accessibility, rollback,
  deletion recovery, and stale-state behavior against TR IDs.
- Restore work additionally receives a data-safety review. A restore failure
  leaves the original store intact; no automatic replace, cleanup, or reset is
  permitted.
- Transaction soft-delete remains reversible through Recently Deleted and the
  existing `.ftbackup` process. This spec does not authorize a production
  restore, release, install, or merge.
