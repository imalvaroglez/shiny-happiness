# AD-023 — Safe Transaction Schema Evolution

**Status:** approved for a gated 0.14.0 implementation. **Release state:**
`BLOCKED` until every compatibility proof in this document succeeds.

## Objective and constraints

The current migration history couples V4–V6 schema checksums to live models.
This makes adding a property to `Transaction` unsafe. Release 0.14.0 repairs
that architecture and adds one real field only:
`Transaction.settlementDueDate: Date?`.

- **SC-01 — Scope.** Do not consolidate `settlementPaidByRaw` or
  `customPartnerPercent`. Do not use column repurposing, implicit migration,
  a metadata catch-all table, or a dummy schema marker.
- **SC-02 — Historical immutability.** V4, V5, and V6 must each contain their
  complete released `@Model` graph as frozen nested schema types. Only V7 may
  reference live models. The frozen definitions are byte-for-behavior copies of
  their released shapes, not aliases to current model types.
- **SC-03 — Candidate schema.** Add `AppSchemaV7` with
  `Schema.Version(0, 10, 0)` and register an explicit V6→V7 migration. V7 is
  the only live terminal schema.

## Due-date migration and runtime contract

- **SC-04 — Deterministic backfill.** The custom V6→V7 stage resolves
  `SettlementDueDateOverride` rows using the existing transaction-ID,
  `lastModifiedAt`, and tombstone ordering. A winning active override fills
  `settlementDueDate`; a winning tombstone produces `nil`; no row also remains
  `nil`. It must be idempotent and save-or-fail without partial completion.
- **SC-05 — Canonical runtime value.** After migration, transaction due date is
  canonical. `SettlementDueDateOverride` remains a compatibility mirror. Set,
  clear, and purge update both representations inside one `ModelContext` and
  one save boundary. Reads use the canonical field and never fall back in a way
  that resurrects a tombstone.
- **SC-06 — Backup compatibility.** `.ftbackup` manifest schema remains 7:
  the existing sidecar snapshot is lossless for this field. Export validates
  that canonical and mirror values agree and fails visibly on drift; it never
  silently repairs production data. Restore and merge apply the sidecar's
  timestamp/tombstone semantics and reconstruct the canonical field before the
  final save. Missing 0.12-era override files still mean the transaction's
  default posted-month behavior.

## Required proof before integration

- **SC-07 — Reproducible spike.** In a non-shipping worktree, recreate the
  historical-shape problem and generate synthetic, non-personal stores from
  the actual released V4/V5/V6 commits (`ed84ce2`, `d013af6`, and `04710b2` or
  the exact verified release equivalent). Migrate copies only. Compare model
  counts, IDs, relationships, `Decimal` values, raw enums, soft deletes, active
  sidecars, and tombstones before and after.
- **SC-08 — Automated coverage.** Add on-disk migration tests for V1–V6→V7,
  active/tombstone/duplicate/tie backfill, set/clear/purge atomicity, save
  rollback, backup round-trip, backup merge, reset, account deletion, and
  reopen after read/write. Keep the `ModelContainer` alive for each test.
- **SC-09 — Disposable production-shaped proof.** After release preparation
  approval and confirmation of a fresh backup, migrate a disposable copy of a
  representative store; never open, migrate, reset, or repair the live store
  during development.

## BLOCKED policy and rollback

- **SC-10 — Fail closed.** If any historical or production-shaped copy fails
  to open, changes a preserved value/relationship, or cannot satisfy reopen
  tests, 0.14.0 remains `BLOCKED`. Do not substitute a reset, destructive
  migration, silent fallback, or app-only rollback claim.
- **SC-11 — Release gate.** A release requires focused migration/backup/reset
  tests, full serial suite, Debug and Release builds, a specialized data review,
  a fresh verifiable pre-migration `.ftbackup`, and an explicit user approval
  for release preparation. This spec alone authorizes none of those gates.
- **SC-12 — Rollback.** After V7 writes a store, an older app is not a complete
  rollback route. Recovery requires the previous app plus a compatible
  pre-migration backup restored with `replaceAll`. The release report must say
  this explicitly before any installation.

## Deliverables and test mapping

| ID | Deliverable | Evidence |
| --- | --- | --- |
| SC-02/03 | Frozen V4–V6 graphs, V7 and migration plan | source review plus synthetic historical-store open test |
| SC-04/05 | Transaction field and dual-write due-date service | migration and service atomicity tests |
| SC-06 | schema-7 backup round trip and merge reconstruction | `BackupArchiveTests` with active and tombstone rows |
| SC-07/09 | temporary stores and representative-copy report | exact commands, before/after comparison, no committed data |
| SC-08 | persistence/reset/deletion/reopen coverage | focused suites plus full serial suite |
| SC-10–12 | blocked decision and rollback record | data review and release handoff |

No production install, app launch, backup creation, store copy, or release PR is
authorized until the relevant `docs/LOOPS.md` human gates are independently met.
