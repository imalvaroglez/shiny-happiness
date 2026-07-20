# Household Settlement — Due Dates

Status: approved. Extends `specs/household-settlement-explicit-inclusion.md`
(assignment + inclusion) with one new concept — a **settlement due date** — so a
charge made in one month but payable later (e.g. a credit-card purchase that cuts
the following month) is billed to Fer in the month it is actually due, without
losing visibility of why an amount is owed.

## Problem

The report is a live total over the selected month's transactions by `postedAt`
(`HouseholdSettlementReportService.transactions(for:)`). A Fer purchase made July 13
on a card that cuts Aug 11 / pay-by ~Aug 31 is currently billed to Fer in **July**.
That is wrong: she won't pay it until August, and billing it in July loses tracking
of what is still owed and why. The report must defer it to August while keeping it
visible (and explained) in both months.

## Scope

Due dates are per-transaction and **only meaningful for `.partner` (Fer) rows**.
Shared / User / Custom / salary rows participate only in their posted month. This
sidesteps the proportional-split / income-estimate month-anchoring question entirely.

## Semantics

- **Default** (no override): due month == `postedAt` month. Zero historical migration.
- A Fer tx made in month P with a due date in future month D:
  - **P report**: appears marked **"Pasa a `<D>`"**, does **not** sum to recovery;
    cash **does** count in "Total paid by you" (money left the account in P).
  - **D report**: appears and **sums** to recovery.
  - Visible in **both** months. A deferred-only month is **not** the empty state.
- **Recovery** (`amountToRecoverFromPartner`) = Fer rows **due** in the selected month.
- New breakdown line **"Pending for upcoming months"** = deferred Fer rows posted this
  month. "Fer-only paid by you" is renamed **"Fer-only due this month"**.
- **Example invariant** (July MXN 1,000 Fer purchase due in August):
  July: paid = 1,000, recovery = 0. August: paid = 0, recovery = 1,000, final = −1,000.
- Reassigning a tx **away from Fer** clears its due-date override. Exclusion alone
  preserves a latent override.
- Due dates normalize to the local calendar day and cannot precede the purchase day;
  an invalid stored earlier date defensively resolves to the purchase month.

## Persistence — sidecar model + schema V6

Due dates are **not** stored on `Transaction`. Adding an additive-optional `Date?` to
the live `Transaction` changes the terminal V5 model hash (every `VersionedSchema`
references `Transaction.self` live), so existing stores fail to open — the same wall
documented in `household-settlement-explicit-inclusion.md` (and the repo CHANGELOG:
"adding an additive-optional property is not migratable under this app's explicit
migration plan"). `settlementNotes` is not a precedent: it and V5 shipped in the same
commit, so it never demonstrated a *post-terminal* addition.

Instead: a new sidecar `SettlementDueDateOverride` `@Model`
(`transactionID: UUID`, `dueDate: Date?`, `lastModifiedAt`) added via a lightweight
V5→V6 stage — the one schema-evolution technique proven here (how
`HouseholdPartnerIncomeEstimate` was added V3→V4). A new model type changes only its
own checksum, never `Transaction`'s. `Transaction` and V5 stay byte-identical.

- **Active date** = explicit override (`dueDate != nil`).
- **`nil` row** = merge-safe tombstone recording that an earlier override was cleared.
- **Missing row** = default to the transaction's purchase month.

Override rows are keyed by `transactionID` (no inverse `@Relationship`), so cleanup on
transaction/account deletion is explicit (see `AppDataResetService`, account deletion).

### Fetching

`transactions(for:)` becomes a report-input builder: transactions posted in the
selected half-open month interval, **plus** older transactions referenced by active
overrides whose due date falls in that interval, plus a `[UUID: Date]` active-due-date
map. Overrides are fetched separately and resolved in Swift (no force-unwrap of
optionals inside `#Predicate`, no cross-model join — SwiftData can't translate either).

### Calculator

`ferRows` means "due this month → sums". Shared/User/Custom/salary rows are unchanged
(posted month only). For Fer rows: purchase month + future due month → `deferredFerRows`
(no sum, marked); due month → `ferRows` (sums). Stored date before purchase → resolves
to purchase month.

### Backup

`.ftbackup` schema bumps 6 → 7 with a dedicated override snapshot/file. Schema 7
requires the file; schemas 1–6 treat it as empty. Restore overrides only for existing
transactions. Merge by `transactionID` + `lastModifiedAt`, including tombstones (a
cleared date defeats an older active date). Orphan overrides (no matching tx) are skipped.
