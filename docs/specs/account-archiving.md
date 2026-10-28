# Account archiving

## Behavior

Archiving is a reversible organization state stored as Account.archivedAt.
It is independent from closedAt and updates lastModifiedAt. It never edits
or deletes transactions, statements, balances, investment positions, pending
imports, or installment plans.

Archived accounts disappear from the dashboard account navigation and selectors
that create new account-linked records. They remain available in transaction
history filters and continue to contribute to existing financial calculations.
Settings → Accounts lists archived accounts with Restore and the existing
confirmed permanent Delete action. Archiving the selected dashboard account
returns navigation to Overview.

## Persistence and backups

The app schema advances from V6 to V7 with a lightweight optional-field
migration. Existing accounts therefore start active. Backup schema 12 includes
archivedAt; replace-all restores from older backups create active accounts,
and merging an older backup preserves each local account's archive state.

## Verification

Tests cover archival and restoration without changing linked data, V6 on-disk
migration, backup schema 12 round-trip, and schema 11 replacement/merge
compatibility. An archived-account dashboard test confirms those accounts
remain in financial totals. On 2026-10-22, the focused migration, backup,
settings, and dashboard tests passed; the full serial suite passed with 594
tests across 72 suites, and the canonical Debug build succeeded.

The opt-in performance fixture ran 25 iterations against 10,000 cached
accounts and 10,000 transaction rows. Active-account projection measured
9.49 ms median / 10.75 ms maximum; archive plus restore saves measured
12.18 ms median / 13.89 ms maximum. These are backend measurements and do not
measure SwiftUI's first visible frame. A separate fresh-context independent
review remains outstanding when a reviewer thread is available.
