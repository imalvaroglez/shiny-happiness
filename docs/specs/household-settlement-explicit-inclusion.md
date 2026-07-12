# Household Settlement — Explicit Inclusion

Status: planning iteration. Supersedes the inclusion assumption in
`specs/household-settlement-allocations.md` (which remains authoritative for
assignment + exact Custom allocation semantics). This spec adds one new concept
— **explicit Household inclusion** — as a field separate from assignment.

## Problem

Every technically eligible expense is currently treated as a Household
Settlement transaction. Because a never-assigned eligible expense resolves to
assignment `User` (`Transaction.resolvedHouseholdAllocation`, `Transaction.swift:136`),
personal expenses inflate:

- Total paid by you
- Your final cost
- the "User-only expenses" section

Household Settlement must become **opt-in**: only transactions explicitly
included by the user participate. Assignment and inclusion are separate
concerns and must be stored in separate fields.

## Conceptual model (three independent layers)

1. **General reporting eligibility** — existing `TransactionClassifier.countsAsRegularExpense`
   (income, transfers, duplicates, MSI purchases, semantic treatments, etc. are
   excluded). Unchanged.
2. **Household inclusion** — new: `excluded` | `included`. Only `included`
   transactions participate in the Household report.
3. **Household allocation** — existing assignment `user | shared | fer | custom`
   (+ exact `customFerAmount`). Decides how an *included* expense is divided.

A personal expense (excluded) and a household expense paid entirely by the user
(included + Mine) are not the same thing. `User`/`Mine` must never mean
"outside Household Settlement".

## Persistence representation

### Before (current)

```
Transaction.expenseAssignmentRaw: String?   // nil | "user" | "shared" | "partner" | "custom" | "unassigned"
// nil / "user" / "unassigned"  → resolvedHouseholdAllocation == .user  (inflates report)
```

`.user` is persisted as `nil` (`Transaction.setExpenseAssignment`, `Transaction.swift:197`).
There is therefore **no persisted representation that distinguishes an explicit
User choice from the automatic default**.

### After (chosen)

Reuse the existing (previously unused) `settlementPaidByRaw` column to store
scope — no new persisted property, no schema-version change (see "SwiftData
schema" below for why a new column is not viable here):

```
Transaction.settlementPaidByRaw: String?    // nil | "excluded" | "included"  (repurposed; was dead SettlementPaidBy storage)
// householdScopeRaw is a computed alias over settlementPaidByRaw.
```

- `HouseholdScope` enum: `excluded`, `included` (rawValue String, Codable).
- Computed `var householdScope: HouseholdScope` resolves `nil` / unknown → `.excluded`
  (**`nil` decodes as excluded**, never included — core invariant + persistence
  requirement). `nil` means *legacy / missing / unmigrated only*.
- **Canonical writes always persist an explicit raw value** (`"excluded"` or
  `"included"`). `setHouseholdScope`, imports, manual creation, pending-review
  resolution, migration output, and backup restoration must never write `nil`
  for scope. This is required for idempotency and reversible exclusion: an
  excluded-but-previously-Shared tx persists `"excluded"` plus its latent
  assignment, so a later repair pass (which only migrates `nil`-scope rows) will
  not re-include it.
- A Boolean `isIncludedInHouseholdSettlement: Bool` is provided for call-site
  readability and #Predicate use; it is `householdScope == .included`.
- `expenseAssignment`, `customFerAmount`, `splitMethodOverride` keep their
  existing storage and semantics untouched.

Why a separate field and not a new assignment case: the spec forbids
representing "excluded" as an assignment case, and forbids `Mine`/`User`
meaning "outside Household". A dedicated scope field keeps allocation semantics
intact and makes exclusion reversible (the latent assignment is preserved).

### SwiftData schema — column reuse, NOT a new property

Household scope is persisted in the **existing, previously-unused**
`settlementPaidByRaw` column on `Transaction` (repurposed; the original
`SettlementPaidBy` concept was never used for behavior, and the column was
verified `NULL` for every row in production before repurpose). The domain
exposes it through the usual `householdScope` / `settlementPaidByRaw` /
`setHouseholdScope(_:)` API; `householdScopeRaw` is a computed alias over
`settlementPaidByRaw`.

**No new persisted property, no new `VersionedSchema`, no migration stage.**
This is required because both alternatives proved unviable on real on-disk
stores (verified during implementation against a copy of production data):

- **Adding an optional `householdScopeRaw` property + a V6 stage** fails:
  SwiftData computes identical version checksums for two schemas that differ
  only by an additive-optional attribute ("Duplicate version checksums
  detected"), so the stage cannot be registered for the on-disk migration path.
- **Redefining the V5 model in place** (add the optional property, keep the
  plan's terminal at V5) fails: an existing on-disk store written under the
  pre-scope V5 model carries a different model hash than the redefined live
  model, and with an explicit migration plan SwiftData refuses to open it
  (fatalError at launch).

Because the schema is byte-identical to the previous release, existing
on-disk stores open with **no migration**; the new column simply decodes as
`nil` (→ excluded) until the semantic repair pass runs.

The *semantic* one-time mapping (Shared/Fer/Custom → included, default-User →
excluded) is **not** a schema migration — it runs in the idempotent repair
service (below). The **backup** format (`.ftbackup`) version bumps v5 → v6 to
carry scope explicitly; on restore/merge, an explicit live scope always wins
over a legacy (nil-scope) snapshot (see Persistence).

### Shared legacy-mapping function

One pure function derives scope from legacy state, used by **both** the live
repair service and backup restore so their behavior cannot diverge:

```swift
// HouseholdScopeResolver (in Domain, near Transaction/HouseholdSettlementKind)
static func resolveScope(assignmentRaw: String?) -> HouseholdScope {
    switch assignmentRaw {
    case ExpenseAssignment.shared.rawValue,
         ExpenseAssignment.partner.rawValue,
         ExpenseAssignment.custom.rawValue: return .included
    default: return .excluded   // nil, "user", "unassigned", unknown
    }
}
```

Custom exact amounts are preserved by the caller (never recomputed). An
already-explicit v6 scope (`householdScopeRaw != nil`) always wins and is never
re-derived.

### Backup

Bump `BackupArchive.schemaVersion` `5 → 6`; extend the allowlist to include `6`.
Add `householdScopeRaw: String?` (optional, nil-defaulted) to `TransactionSnapshot`
so v5 backups decode without a custom `init(from:)`. Thread it through
`Transaction.init(_ snap:)`, `apply(_:)`, `TransactionSnapshot.init(_:)`.

**Restore does not blanket-backfill missing scope to excluded.** For a snapshot
with no `householdScopeRaw`, derive scope from its legacy `expenseAssignmentRaw`
via the shared `HouseholdScopeResolver.resolveScope` (nil/User/Unassigned/unknown
→ excluded+User; Shared → included+Shared; Fer/Partner → included+Fer; Custom →
included+Custom, preserving exact `customFerAmount`). An explicit v6 scope on the
snapshot is preserved verbatim. This runs in the post-insert restore loop
(`BackupArchive.swift:390-403`).

## Default behavior

### Newly imported transactions
`Normalizer.normalize` constructs with `householdScopeRaw = HouseholdScope.excluded.rawValue`
(explicit). Imported eligible expenses do **not** appear in Household Settlement
until the user includes them.

### Newly created manual transactions
`ManualTransactionService.create` (and the transfer/mirror constructors in
`ManualAccountServices.swift`) default to excluded. `ManualTransactionSheet`'s
default `expenseAssignment = .user` stays, but scope starts excluded.

### Income / transfers / ineligible transactions
Eligibility unchanged. Inclusion controls are hidden/disabled for ineligible
transactions (the existing `isSettlementEditable` gate in `TransactionDetailSheet`
already hides the whole section).

## Migration (one-time, versioned, idempotent)

Vehicle: `HouseholdAllocationRepairService.repairIfNeeded(context:)`, already
called on every launch at `DashboardView.swift:60` after seed repair, before
dashboard configure. It is idempotent (`repair(transactions:) -> Bool`) and
operates on all transactions — the deterministic, resumable, launch-safe hook
the spec requires. No production data is touched during development/testing
(AGENTS.md).

Mapping (applies only to technically eligible expenses;
`HouseholdSettlementReportService.isSettlementEligible`):

| Existing state | → scope | → assignment | notes |
|---|---|---|---|
| `expenseAssignmentRaw == nil` (old automatic default-User) | **excluded** | `user` (latent) | no provenance distinguishes explicit User from default |
| `"unassigned"` / unknown | **excluded** | `user` | |
| `"shared"` (income-proportional) | **included** | `shared` | explicit decision |
| `"partner"` (Fer) | **included** | `fer` | explicit decision |
| `"custom"` + exact `customFerAmount` | **included** | `custom` | exact amount preserved, not recalculated |
| previously-migrated 50/50 / custom-percent (now Custom) | **included** | `custom` | already exact; preserved |

Idempotency guard: a transaction is migrated **only when `householdScopeRaw == nil`**.
The migration then writes the **explicit** raw value (`"excluded"` or `"included"`)
via the shared `HouseholdScopeResolver`. Once scope is set to either explicit
value, subsequent launches never recompute it and never re-round `customFerAmount`.
This makes the migration run-once and safe across repeated launches and historical
months. Ineligible transactions are also written `"excluded"` (so the column is
fully populated and never re-derived) but never participate regardless.

Explicit-User handling: because the persisted representation cannot
deterministically distinguish explicit User from the nil default, **all** User
rows migrate to excluded, per the user's decision criterion. This is documented
in the spec and the changelog as intended behavior.

## Calculator (source of truth)

`HouseholdSettlementCalculator.build` (`HouseholdSettlementReport.swift:336`):
the eligibility filter at line 350 gains an inclusion gate —

```swift
let expenseRows = transactions.filter {
    classifier.classify(transaction: $0).countsAsRegularExpense
        && $0.householdScope == .included
}
```

No other calculator change. The existing section-membership `switch` on
`resolvedHouseholdAllocation` (line 371) already routes correctly; excluded rows
simply never reach it. Totals (`totalPaidByUser`, `amountToRecoverFromPartner`,
`userFinalCost`, subtotals) are computed only from included rows as a direct
consequence. The view/presenter must not duplicate this filter.

`HouseholdSettlementReportService.isSettlementEligible` keeps meaning
*technically eligible* (classifier only). A separate
`isIncludedInHouseholdSettlement` is the participation gate. The Transactions
filter bar composes both: technical eligibility (for showing controls) and scope
(for the Included/NotIncluded filter).

## Report sections (order + membership)

Order unchanged: 1) Fer-only, 2) Shared, 3) **Your household expenses** (renamed
from "User-only expenses"). Membership is now and enforced by the calculator:

- Fer-only: included + assignment `fer`
- Shared: included + assignment `shared` OR `custom`
- Your household expenses: included + assignment `user`

Excluded rows never appear, even with a latent shared/fer/custom assignment.

## Presenter changes

- Section title "User-only expenses" → **"Your household expenses"**
  (`HouseholdSettlementPresentation.swift:330`).
- Subtitle (`:206`) → copy making clear totals reflect included Household
  transactions only.
- `resultDescription` (`:265`) → e.g. "Based only on transactions included in
  Household Settlement." with an included-count when available.
- Breakdown labels gain "household" where it removes ambiguity
  (`:268-272`): "Total household expenses paid by you", "Shared household
  expenses", "Fer shared portion", "Fer-only paid by you", "Your final
  household cost".
- **Empty state**: when zero transactions are included for the month, the
  presenter/view renders a compact Household empty state ("No household expenses
  included for this month.") with a single **Review transactions** action,
  instead of three all-zero cards. (The current `body` renders the full report
  even when empty — add an `includedRowCount == 0` branch.)

The presenter never filters excluded rows itself (calculator owns that); it only
labels and formats what it receives.

## Transaction Details UI

`TransactionDetailSheet.settlementRows` (`:279`) gains an inclusion toggle above
the assignment picker, inside the existing `isSettlementEditable` section:

```
Household Settlement
  [ ✓ Include in Household Settlement ]
  Assignment:   [ Mine | Shared | Fer | Custom split ]   // hidden/disabled when excluded
  Custom split fields                                       // hidden when excluded
  helper: "Only included transactions appear in Household Settlement…"
```

- Excluded: toggle off, assignment picker + custom fields hidden/disabled,
  helper shown. Saving preserves any stored assignment as inactive metadata
  (do not clear `expenseAssignmentRaw`/`customFerAmount` on exclude).
- Included: show assignment + custom as today; preserve exact currency +
  validation + normalization.

Save path (`:491-503`) writes scope via a new `Transaction.setHouseholdScope(_:)`
setter, then the existing assignment/custom setters.

### ManualTransactionSheet
Do not expose an apparently-active Household assignment while scope is excluded.
Add the same **Include in Household Settlement** toggle there. When off, hide or
disable the assignment picker and custom allocation UI. (If the manual sheet is
to stay minimal, omit the assignment controls entirely and let Transaction
Details be the editor — but never show an active assignment for an excluded tx.)
New manual expenses still default to excluded regardless.

### Inclusion transitions (domain setters on `Transaction`)
- `setHouseholdScope(.included)` on a never-included tx → scope included,
  assignment stays whatever it is (latent `.user` reads as Mine). Per spec
  invariant #4 the *first* include of a never-included tx presents as Mine —
  satisfied because latent assignment is `.user` and the report treats
  included+user as "Your household expenses".
- `setHouseholdScope(.included)` on a previously-excluded tx → restore last
  assignment/custom (they were preserved).
- `setHouseholdScope(.excluded)` → scope excluded; **do not** clear assignment or
  `customFerAmount` (preserved as inactive metadata); no compensating tx; bank
  tx untouched.

Assignment transitions while included keep existing rules (Custom→Mine/Shared/Fer
clears obsolete custom data; Custom zero→Mine; Custom full→Fer) — unchanged from
the allocations spec.

## Transaction list visibility + controls

### Included indicator
`TransactionLedgerRow` shows a small house icon / "Household" badge for included
transactions only (accessibility label "Included in Household Settlement").
Excluded rows get no badge. The existing passive assignment chip
(`metadataParts`, `:89`) stays for non-user assignments.

### Household filter (TransactionsView)
New `HouseholdInclusionFilter { all, included, notIncluded }`, mirroring the
existing `AssignmentFilter` pattern. Composes with existing filters
(account, category, search, assignment, recently-deleted, sort) inside
`recomputeDisplay()` (`TransactionsView.swift:108`). The `notIncluded` branch
filters to technically-eligible expenses with `householdScope == .excluded`
(composes with `isSettlementEligible`). Picker in `TransactionFilterBar`,
active-filter chip, count, and reset all extended.

### Quick actions
Per-row quick controls for eligible transactions:
- excluded → **Add to Household** (scope included; assignment = stored or Mine)
- included → **Remove from Household** (scope excluded; preserve assignment)

**Any explicit quick assignment on an excluded transaction includes it** —
including Mine. Selecting Mine is not a no-op just because `User` is also the
latent default; the explicit user action proves Household intent. The
inclusion signal is the now-explicit `householdScope == .included` (assignment
stays whatever was chosen; an explicit Mine persists `expenseAssignmentRaw = nil`
but scope `.included`, which the report treats as "Your household expenses").
So: Excluded+Mine → Included+Mine; Excluded+Shared → Included+Shared;
Excluded+Fer → Included+Fer. Custom stays detail-sheet-only (no fourth inline
button). Report-row Mine/Shared/Fer controls remain naturally included (only
included rows appear there).

Bulk assignment menu (`TransactionsView.applyAssignment`, `:361`) is updated so
that any explicit assignment (Mine/Shared/Fer) on an excluded tx also sets scope
`.included`.

## "Review transactions" navigation

`HouseholdSettlementView` gains `onReviewTransactions: (YearMonth) -> Void`.
`DashboardView` owns the transition (precedent: `onViewAllTransactions` at
`:342`): it stashes a typed `TransactionFilterPreset` (selected month +
`notIncluded` + technical-eligibility) and switches `sidebarSelection = .transactions`.

`TransactionFilterPreset` is modeled as an **explicit one-shot navigation event**,
not a bare optional init value consumed in `onAppear`. Each preset carries a
unique identity/token (a `UUID`). `TransactionsView` consumes a preset exactly
once via a consumption mechanism (`onPresetConsumed: (UUID) -> Void` callback or
equivalent binding back to `DashboardView`), then the user can edit filters
freely. The preset must not reapply on later appearances, reset signals, or
direct sidebar navigation. The Household report's selected month is preserved
when navigating back.

## Core invariants (summary)

1. Contributes to Household iff `countsAsRegularExpense && householdScope == .included`.
2. Assignment has no report effect while excluded.
3. Never-included tx: scope excluded, latent assignment user (does not cause inclusion).
4. First include of never-included tx presents as Mine.
5. Exclude removes from all sections/totals immediately.
6. Exclude preserves assignment + exact custom as inactive metadata; re-include restores.
7. Assignment transition rules while included unchanged.
8. Toggling inclusion never touches amount/description/account/category/date/kind/treatment/transfer/statement metadata.
9. No floating-point currency.
10. All money via existing Decimal / currency-rounding conventions.

## Decoding safety
Unknown / missing `householdScopeRaw` → `.excluded` (never included). Applies to
SwiftData load, backup restore, and the `householdScope` computed getter.

## Non-goals
Auto merchant/category inclusion, recurring detection, ML classification,
receipt splitting, synthetic/reimbursement transactions, new budgeting, new
account type, batch editing beyond existing, cloud, third-party deps, a large
"in-review" section inside the report.
