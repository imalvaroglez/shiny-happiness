# Backlog

A running list of small UX bugs, polish items, and follow-ups discovered
during manual testing. Newest entries on top. Cross off (`~~strike~~`)
when shipped and reference the commit.

## Features

- **CloudKit sync** — entitlements + `cloudKitDatabase: .private(…)`; requires the InstallmentPlan inverse-relationship loosening described in the original plan. Deferred per stakeholder. `lastModifiedAt` (AD-016) is already in place so future CloudKit work doesn't need a model migration.

- **Account deletion UX** — out of scope for the soft-delete stage; needs UI to surface soft-deletion of an entire account and its transaction cascade. Individual transaction deletion is supported via `deletedAt`.

- **Currency conversion** — multi-currency dashboards still display per-account currency; no conversion. Future.

- ~~**Drill-down "show me the math" for every dashboard aggregate**~~ —
  shipped in `7376c36` (Stage 3). `BreakdownSheet` opens from summary
  tiles, donut sectors, cash-flow bars, and net-worth points. Interest
  drill-down was bugged (only saw recent 20 rows); fixed in `4b4b869`.

- ~~**Interactive dashboard charts**~~ — shipped in `7376c36` (Stage 3).
  Every dashboard chart has hover tooltips via `chartXSelection`; the
  cash-flow chart has an Income/Expenses series filter.

## UX bugs

- ~~**CategoryPicker doesn't show subcategories**~~ — fixed in `99cd605`.
  Replaced the unmaterialized `cat.subcategories` lookup with an
  explicit filter over the existing `@Query<Category>`.

- ~~**Import sheet (Dashboard floating button) has no close affordance**~~ —
  fixed in `99cd605`. Wrapped in a `NavigationStack` with a toolbar
  Done button.
