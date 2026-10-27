# Daily interest in Balance Over Time

## Problem and behavior

Income and Cash Flow already distribute positive manually recorded Interest
captures across their estimated accrual days. The per-account Balance Over Time
chart still uses the original transaction date, creating a visible jump on the
capture date instead of showing the balance growth across those days.

For this chart only, replace each eligible manual capture row with the shared
daily allocations for the same source transactions. Add estimated amounts to
the account series on their local calendar days, keeping balance anchors as
authoritative resets. Imported interest stays on its recorded date. If the
source capture is not present in the chart's valid balance history, leave the
original series untouched rather than risk counting both forms or dropping the
amount.

## Invariants and scope

- Use the existing allocator and `Decimal` values; do not calculate a second
  interest schedule or create transactions.
- Include only allocations available through the dashboard's as-of date.
- Keep the persisted transaction, snapshot, statement, and account balance
  resolver unchanged. The projected series exists only for this account chart.
- Preserve point-in-time anchor behavior and the existing investment valuation
  path.
- Do not redistribute imported interest, consolidated Net Worth, or stored
  balance history.

## Acceptance

- A capture of $2,334.33 over Oct 3–21 produces $122.86 on the first 18 days
  and $122.85 on the last; the chart's end value matches the current resolver
  when no intervening anchor resets the history.
- The source amount appears once: the capture-date lump is removed when its
  complete source group is represented by valid daily allocations.
- Imported interest changes the chart only on its recorded date.
- Changing the selected period reuses the full allocation history, so a source
  captured after the selected range can still contribute accrual days inside
  that range.
- Existing balance history and account current-balance results remain intact.

## Tests

`DashboardPeriodFilteringTests` covers daily manual allocation in the account
chart, exact endpoint consistency, and the recorded-date behavior for imported
interest. Existing resolver and dashboard tests continue to cover anchors and
period sampling.

## Performance verification

Measured with the opt-in `PR_CHAIN_PERFORMANCE=1` backend benchmark using an
in-memory account with 10,000 movements, 120 manual interest captures, and
3,650 generated allocation days. Projection from the cached balance history
took 39.80 ms median (41.58 ms maximum over 25 runs). Changing the selected
period took 23.99 ms median (85.40 ms maximum over 25 runs). The initial model
configuration took 571.48 ms median (572.79 ms maximum over 5 runs), including
history loading and other dashboard setup, and is not isolated to this chart.

These are backend timings and do not measure SwiftUI's first visible frame or
animation hitches. The required interactive UI performance check remains open;
the backend measurements alone do not establish the under-100-ms visible
response gate.
