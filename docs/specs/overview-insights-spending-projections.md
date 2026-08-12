# Overview — Insights, Spending Analytics & Explainable Projections

**Status:** approved for phased implementation (2026-08-04). This is the
canonical Overview specification. It supersedes the recovered 2026-07-24
draft, the external phased plan, and the interpretation decisions D4/D5/D12 in
`docs/superpowers/specs/2026-07-07-dashboard-redesign-design.md`. The visual
component system remains unchanged.

**Release:** 0.13.0. This work does not change SwiftData models, migrations,
or `.ftbackup` schema.

## Product contract

The dashboard must explain current spending and credit-card obligations without
inventing amounts, joining cycles, mixing currencies, or double-counting
payments. It delivers four ordered phases: **1A → 1B → 2 → 3**. Each phase
stops at `READY FOR DEVELOPMENT VALIDATION`; the next phase requires explicit
human approval under `docs/LOOPS.md`.

### Global invariants

- **OV-01 — Money and concurrency.** Amounts, percentages, shares, and
  confidence in `Domain/` are `Decimal` (or integer basis points), never
  `Double`/`Float`. Computation uses `Sendable` value types; `@Model` objects
  remain behind `@MainActor` fetch adapters.
- **OV-02 — Credit-card scope.** Upcoming Payments considers exactly active
  credit cards (`type == .creditCard && closedAt == nil`). Loans are excluded.
  The same predicate is used for coverage, fetching, totals, and rows.
- **OV-03 — No financial side effects.** Insights and payment analysis never
  write statements, transaction amounts, balances, cash flow, net worth, or
  payment metadata as a side effect of analysis.
- **OV-04 — Period source of truth.** `PeriodInterval` is the sole query
  contract. `DashboardPeriodContext.dateRange` is an inclusive rendering/chart
  projection and no fetch accepts it.

## OV-10: periods and shared filtering (Phase 1A)

- **OV-10.1 — Rolling Month.** Month is exactly 30 local civil dates:
  `[startOfDay(today - 29 days), startOfDay(tomorrow))`. This is the current
  product decision and replaces the obsolete calendar-month-to-date wording in
  `AGENTS.md` and `README.md`; the release integrator must align those two
  references before 0.13.0 is declared ready.
- **OV-10.2 — Half-open queries.** Historical, previous-period, statement, and
  drill-down queries use `[start, endExclusive)`. A live current-period query
  may use `<= observedThrough` only as an explicit observation cap, never as a
  second inclusive period boundary. Enforce
  `start <= observedThrough <= endExclusive`.
- **OV-10.3 — Other windows.** Quarter and Year are rolling 3- and 12-month
  calendar windows; Custom is local-calendar inclusive in presentation and
  half-open in queries; All has no percent comparison. Previous windows tile
  without overlap. Calendar and time zone are injected.
- **OV-10.4 — One context.** Cards, charts, totals, breakdowns, anomaly
  comparisons, and drill-downs use the selected `DashboardPeriodContext`.

Acceptance/tests: `DashboardPeriodFilteringTests` proves 30 civil dates across
DST, non-overlap at boundaries, observed-through behavior, Custom conversion,
and that no transaction fetch is driven by `dateRange`.

## OV-20: canonical card obligation and reconciliation (Phase 1A)

- **OV-20.1 — One resolver.** `CardPaymentResolver` resolves an original
  obligation once and feeds both the card screen and Overview. It first chooses
  the billing cycle using `Account.statementDayOfMonth` (including short
  months), then applies manual-confirmed and imported values independently per
  field. A partial manual record must retain imported fields it did not replace.
  Resolution never mixes fields across cycles.
- **OV-20.2 — Explicit amounts.** `CardPaymentDetails` separates
  `fullStatementAmount`, `minimumPayment`, and `amountBasis`
  (`fullStatement`, `minimumOnly`, `unknown`). A minimum is not a known full
  obligation. Provenance is derived (`manualOverride`, `importedStatement`, or
  `mixed`) and is not persisted.
- **OV-20.3 — Multiple cycles.** `resolveAll` returns obligations ordered by
  cycle; the individual-card presentation derives its one current obligation
  from that result. There is no independent backing-statement selection path.
- **OV-20.4 — Eligible payments.** Only posted, positive, non-duplicate,
  non-voided card-side transactions with a specific payment signal count:
  explicit payment flow, a linked manual transfer, or an existing specific
  own-account payment classifier. Merchant refunds, cashback, interest or
  promotional credits, vague generic credits, and the asset-side transfer do
  not count.
- **OV-20.5 — Bounded allocation.** For a statement-backed obligation, the
  payment window is `(periodEnd, min(next cycle boundary, now)]`; payments
  inside the statement period are already represented by the balance. Allocate
  candidates chronologically to the oldest open obligation first. A payment ID
  may be applied once only, and cannot settle two cycles.
- **OV-20.6 — State and coverage.** Reconciliation separately reports
  settlement (`unpaid`, `partiallyPaid`, `settled`,
  `paymentDetectedButUnresolved`, `amountUnknown`) and due state. A minimum-only
  obligation remains partial coverage even when its minimum is met. An unknown
  full amount is never shown as settled. A settled historical fallback becomes
  `awaitingNextStatement`, not complete current coverage.
- **OV-20.7 — Fail visibly.** Fetch adapters throw; the UI renders an
  unavailable/partial section on failure instead of claiming no payments.

Acceptance/tests: extend `PaymentMetadataTests`,
`PaymentDueDisplayStateTests`, and `DashboardInsightBuilderTests` for mixed
manual/imported fields, cutoff days, two cycles and one payment, oldest-first
allocation, duplicate/transfer/refund exclusion, minimum-only, unknown amount,
historical fallback, and the Volaris settled-payment scenario.

## OV-30: Upcoming Payments presentation (Phase 1A)

- **OV-30.1 — Reconciled rows only.** Settled obligations are absent from the
  active list and totals. Partially paid rows show the remaining full amount;
  minimum-only rows say “minimum”, never “total due”. Overdue residuals remain
  critical even after a partial payment.
- **OV-30.2 — Currency safety.** `CurrencyTotals` groups by ISO currency.
  Amounts from different currencies are never summed. With unavailable visible
  amounts, the headline explicitly says “known amount due” and reports the
  unavailable count.
- **OV-30.3 — Honest coverage.** `notApplicable` hides the card only when
  there are no eligible cards. Partial coverage never says “No payments due
  soon”; it identifies cards awaiting a statement or needing details.
- **OV-30.4 — Reconciled disclosure.** Rows are ordered overdue first then due
  date. Show at most three and a “+N more payments” disclosure; the disclosed
  totals still equal all active remaining obligations per currency.

Acceptance/tests: verify per-currency totals, unknown copy, settled exclusion,
three-row disclosure, zero eligible cards, and a resolver fetch failure.

## OV-40: actionable insight feed (Phase 1B)

- **OV-40.1 — Facts and identity.** Build pure `TransactionFact` values with
  stable `CategoryIdentity` sentinels for Uncategorized and unresolved credits.
  `AnalysisCoverage` uses `Decimal` fractions.
- **OV-40.2 — Card Pace.** Pace is per card and statement cutoff cycle, not a
  calendar-month aggregate. It uses gross charges in 1B (purchases, fees,
  interest, real MSI children; excluding payments, transfers, duplicates,
  deleted transactions, and synthesized MSI parents). It requires a
  user-confirmed cutoff and at least two complete cycles; stale current activity
  is partial coverage. It is `watch` only when both the 20% and material MXN
  thresholds are met. Refund netting is deferred to OV-50.
- **OV-40.3 — Deterministic feed.** `DashboardInsight` and `InsightRanking`
  select at most three by severity, urgency, absolute impact, relative impact,
  confidence, recency, and stable ID. No reserved slots; one active Pace insight
  per card. Insufficient configuration does not occupy a slot.
- **OV-40.4 — Presets.** `TransactionFilterPreset` applies account IDs,
  category identity, interval, and inclusion consistently. Insight actions and
  drill-downs reuse the original scoped IDs rather than rebuilding filters in a
  view.

Acceptance/tests: `DashboardInsightBuilderTests` covers stable identities,
thresholds, zero baselines, ranking ties, coverage, scoped drill-downs, and
maximum-three behavior.

## OV-50: spending and refunds (Phase 2)

- **OV-50.1 — Spend facts.** Spending includes eligible regular positive spend;
  transfers, card payments, duplicates, deleted rows, synthesized MSI parents,
  and non-operational rows have no spending magnitude.
- **OV-50.2 — Conservative refunds.** `RefundLinker` is deterministic and
  one-to-one: it links a credit to the nearest prior same-account,
  same-currency, normalized-merchant purchase of the exact amount within 120
  days. Only an explicitly classified refund/reversal or such a high-confidence
  link reduces spending.
- **OV-50.3 — Unlinked credits.** A generic unlinked card credit does **not**
  reduce spending, does **not** receive a spending category, and is represented
  as unresolved/non-spending. It degrades coverage only if material to the
  analysis. This rule supersedes the recovered draft that subtracted all
  unlinkable credits.
- **OV-50.4 — Spending view.** Provide total/current-vs-previous, daily
  average, top category and merchant, count, largest transaction, category rows
  with expandable Other, and review actions. Anomalies are increases only and
  require the documented materiality and coverage thresholds; a zero baseline
  says “new material spending”, never “+100%”. Large purchases and concentration
  feed the existing ranking.

Acceptance/tests: same-account/currency/merchant/time matching, one-to-one
matching, false-match refusal, explicit and linked refunds, generic unlinked
credits, card-payment exclusion, category deltas, and Pace gross-to-net
transition.

## OV-60: forward look (Phase 3)

- **OV-60.1 — Calendar-month projection.** It is selector-independent and
  uses 3–6 complete covered months. It hides when coverage/history/day/ratio
  guards make the result unreliable. All ratios, percentiles, and confidence
  are Decimal. It is an explainable range, not cash-flow prediction.
- **OV-60.2 — Commitments.** Upcoming commitments consume the reconciled
  remaining obligations from OV-20, not raw statement values. It shows active
  remaining amounts in currency-separated 7/14/30-day buckets. It does not
  infer recurring transactions or a projected 30-day cash flow.

Acceptance/tests: hide thresholds, low/medium/high confidence, range math,
currency-separated commitments, and settled/partially-paid reconciliation.

## Non-goals and release safety

- No machine learning, generic recurrence detector, recurring-versus-variable
  classification, foreign-exchange conversion, or mutation of accounting truth.
- No new persisted property, model migration, or backup format change in
  0.13.0; AD-023 is separately specified in
  `docs/specs/schema-evolution-ad-023.md`.
- Every phase runs its focused suites, Debug build, full serial suite, Domain
  Decimal guard, and `git diff --check`, then receives a fresh-context review.
  Manual validation and explicit approval are required before the next phase.
- If a phase regresses data semantics, revert its isolated branch/commit; do
  not repair or reset production data. No release preparation or installation
  is authorized by this spec.
