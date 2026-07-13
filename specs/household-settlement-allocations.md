# Household Settlement Allocations

## Goal

Household-eligible expenses use exactly four assignments: User, Shared, Fer,
and Custom split. Assignment is report metadata only and never changes the
underlying bank transaction, account balance, statement, treatment, or sign.

New eligible expenses default to User. Missing, legacy Unassigned, and unknown
assignment values also resolve to User. Income, transfers, duplicate rows,
excluded treatments, and synthesized MSI purchases remain outside Household
Settlement according to `TransactionClassifier`.

## Assignment semantics

- **User:** the user is responsible for the full eligible amount and Fer owes
  nothing.
- **Shared:** uses the live month-level split. In the default configuration this
  is proportional to the user and Fer income values.
- **Fer:** Fer is responsible for the full eligible amount.
- **Custom split:** Fer is responsible for an exact stored currency amount. The
  user amount is always the original eligible amount minus Fer's amount.

Custom amounts are stored as `Decimal`. Percentages are derived for display
only. A zero Fer amount normalizes to User; a Fer amount equal to the original
eligible amount normalizes to Fer. Negative, over-total, and sub-cent values
are invalid. Changing away from Custom clears obsolete custom allocation data.

## Totals semantics clarification

“Total paid by you” includes every Household-eligible expense paid from the
user’s accounts during the selected period:

- User
- Shared
- Custom split
- Fer

User-only expenses must be included.

“Your final cost” is:

    Total paid by you - Total recoverable from Fer

As a result:

- User expenses remain fully in Your final cost.
- Shared expenses contribute the user’s income-proportional portion.
- Custom split expenses contribute the exact stored user portion.
- Fer expenses contribute zero after the corresponding receivable is applied.

The totals continue following the app’s existing signed-amount, refund, credit,
and treatment rules.

## Migration of existing Shared overrides

Preserve the intent of all existing transaction-level allocation overrides.

Migration mapping:

- Existing income-proportional/default Shared migrates to Shared.
- Existing explicit 50/50 Shared migrates to Custom split with Fer’s exact
  amount equal to 50% of the eligible transaction amount, using the existing
  currency-rounding convention.
- Existing custom-percentage Shared migrates to Custom split by converting
  Fer’s stored percentage into an exact currency amount using the transaction’s
  eligible amount and existing currency-rounding convention.
- Existing override with Fer responsibility of 0% normalizes to User.
- Existing override with Fer responsibility of 100% normalizes to Fer.

Any percentage strictly between 0% and 100%, including 50/50, becomes Custom
split. An explicit override never becomes normal Shared merely because it
happens to equal the current income-proportional split. It remains fixed when
household income values change later.

After migration:

- `customFerAmount` is the calculation source of truth.
- The user amount is derived as original eligible amount minus
  `customFerAmount`.
- User amount plus Fer amount equals the original eligible amount exactly.
- Legacy percentages do not drive settlement calculations.
- Migration is idempotent: once an exact amount is stored, later launches do
  not derive or round it again.

## Report and interaction

The report renders three collapsed native disclosure sections in this order:

1. Fer-only expenses
2. Shared expenses
3. User-only expenses

Every header shows its transaction count and original-amount subtotal, even
when empty. Expanded rows retain the compact Mine, Shared, and Fer actions.
Custom split is edited in Transaction Details through an exact Fer currency
field; the user amount and both percentages are derived live. Invalid values
are shown inline and disable Save.

`To recover from Fer` equals Fer's live share of Shared expenses plus Fer's
exact share of Custom splits plus Fer-only expenses. Custom rows appear once in
Shared and never in Fer-only.

## Persistence and compatibility

The existing optional Decimal transaction allocation column backs the
`customFerAmount` domain property when assignment is Custom. The Custom
assignment discriminator separates exact amounts from legacy percentage data,
avoiding a SwiftData schema checksum change.

Backup schema v5 exports `customFerAmount`. Backup schemas v1-v4 remain
restorable and pass through the same deterministic legacy conversion. Repair
and restore never operate on production data during development or testing.
