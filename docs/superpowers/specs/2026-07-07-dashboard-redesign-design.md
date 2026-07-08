# Dashboard Redesign — Layout, Visual System & Actionable Insights

**Date:** 2026-07-07
**Status:** Design approved (pending spec review)
**Scope:** Consolidated dashboard (`ConsolidatedDashboard`) only. Per-account dashboards (`AssetAccountDashboard`, `LiabilityAccountDashboard`) are out of scope beyond a shared-component refactor.

---

## Context

The current consolidated dashboard reads as "separate widgets placed on a canvas" rather than an intentional experience with hierarchy. Three concrete problems:

1. **Misaligned top zone.** The "Available Net Worth" hero card (`OverviewMetricCard prominent:true`, `minWidth: 330, maxWidth: .infinity`) sits beside a 4-card `LazyVGrid` constrained to `minWidth: 500, maxWidth: 620`. Two different sizing systems never share a retícula, and the hero is mostly empty horizontal space.
2. **Inconsistent visual language.** Most cards use `GlassCard` (`.thinMaterial`, white-0.16 edge, radius 12/16), but `LiabilityAccountDashboard`'s two header cards bypass it. "Spending by Category" bars use `color.gradient` over a saturated `CategoryPalette`, giving a glossy/plastic feel that doesn't match the matte cards.
3. **No interpretation layer.** The dashboard shows numbers but doesn't explain them. There's no credit-card pace projection, no upcoming-payments roll-up, no period-over-period delta, and the household settlement (already computed elsewhere) isn't surfaced.

**Intended outcome:** a four-section dashboard that answers in under five seconds — *where I am today → what needs my attention → how things are moving → why the numbers look the way they do* — built on a single reusable card/panel component system.

---

## Out of scope (this pass)

- **Household / Fer settlement on the dashboard.** The settlement engine exists (`HouseholdSettlementReportService.report(for:).amountToRecoverFromPartner`) but uses **calendar-month** semantics that conflict with the dashboard's **rolling-window** selector. The Insights row keeps a 4th-card slot so a "Shared Expenses" card drops in later without redesign. Tracked as a follow-up.
- Per-account dashboards' internal redesign. They inherit the new shared components where touched, but their layout is not reworked.

---

## Decisions (locked during brainstorming)

| # | Decision |
|---|---|
| D1 | **Hero:** wide hero card with a quiet inline net-worth sparkline + Liquidity/Patrimonial split + delta badge. Responsive: sparkline shrinks/disappears at narrow widths. |
| D2 | **KPI stack:** 2×2 to the right of the hero — Total Net Worth, Card Liabilities, Net Cash Flow, Interest Earned. |
| D3 | **Four sections:** Financial Snapshot → Insights → Trends → Breakdowns → (Accounts) → (Recent Transactions). Section headers subtle: small uppercase, never visually heavy. |
| D4 | **Insights trio (threshold-based, calm states):** Credit Card Pace · Upcoming Payments · Spending Anomaly. Red only when meaningful; Anomaly shows "No unusual spending detected" when clean. |
| D5 | **Period basis:** Credit Card Pace is **always calendar-month-to-date** (ignores selector). Everything else follows the rolling selector (Month = last 30 days, unchanged). |
| D6 | **Interest:** KPI tile only this pass — not an Insight card. |
| D7 | **Trends:** Cash Flow keeps an informative (non-decorative) form with Income/Out summary; Net Worth Trend stays large. Absolute/Change toggle + jump annotations are **future** (noted, not built). |
| D8 | **Composition:** Total/Available toggle sits in the card header (not floating). |
| D9 | **Spending by Category:** flat matte bars, desaturated; "Other > ~40%" → clickable warning. |
| D10 | **Reusable component system** + semantic color discipline. |
| D11 | **As-of-today vs period labels** on every tile, explicit per-card: point-in-time metrics ("As of today" / "As of {date}") = Available Net Worth, Total Net Worth, Card Liabilities. Period metrics (selected dashboard period, e.g. "Last 30 days" / "Jun 7–Jul 7") = Net Cash Flow, Interest Earned, Spending by Category, Cash Flow, Spending Anomaly. **Credit Card Pace is selector-independent**: label it "Calendar month to date" / "Jul 1–today" — never "Last 30 days". |
| D12 | **Upcoming Payments amount priority:** `paymentForNoInterest` is the primary amount (more actionable — "pay this to avoid interest"); `minimumPayment` is the fallback. If both exist, show "$X to avoid interest" with a smaller "minimum $Y". Never silently sum minimum payments when no-interest data is available. |

---

## Target layout

```
┌─────────────────────────────────────────────────────────────┐
│ FINANCIAL SNAPSHOT                              [Month▼ …]   │  ← subtle header
│ ┌───────────────────────────────┐ ┌──────┐ ┌──────┐         │
│ │ AVAILABLE NET WORTH   ▲+2.8%  │ │ TOTAL│ │ CARD │         │
│ │ $901,044                       │ │ NET  │ │ LIAB.│         │
│ │ Liquidity $347k · Patrmo $553k│ │ WORTH│ │      │         │
│ │ ╱╲╱   (sparkline, quiet)      │ └──────┘ └──────┘         │
│ │ Excludes retirement · 7 Jul   │ ┌──────┐ ┌──────┐         │
│ │                               │ │ NET   │ │INTREST│        │
│ └───────────────────────────────┘ │CASH FL│ │EARNED│         │
│                                   └──────┘ └──────┘         │
├─────────────────────────────────────────────────────────────┤
│ INSIGHTS — WHAT NEEDS YOUR ATTENTION                        │
│ ┌────────────┐ ┌────────────┐ ┌────────────┐               │
│ │CREDIT CARD │ │UPCOMING    │ │SPENDING    │               │
│ │PACE        │ │PAYMENTS    │ │ANOMALY     │               │
│ └────────────┘ └────────────┘ └────────────┘               │
├─────────────────────────────────────────────────────────────┤
│ TRENDS                                                       │
│ ┌────────────────────┐ ┌────────────────────┐              │
│ │ CASH FLOW          │ │ NET WORTH TREND    │              │
│ └────────────────────┘ └────────────────────┘              │
├─────────────────────────────────────────────────────────────┤
│ BREAKDOWNS                                                   │
│ ┌────────────────────┐ ┌────────────────────┐              │
│ │NET WORTH COMPOSIT. │ │SPENDING BY CATEGORY│              │
│ └────────────────────┘ └────────────────────┘              │
├─────────────────────────────────────────────────────────────┤
│ Accounts (unchanged) · Recent Transactions (unchanged)      │
└─────────────────────────────────────────────────────────────┘
```

---

## Reusable component system

All new components live in `FinanceTracker/Features/Dashboard/`. They wrap the existing `GlassCard` (don't replace it) so the glass material, white edge, and hover gradient stay consistent.

| Component | Role | Built on |
|---|---|---|
| `DashboardSectionHeader` | Subtle uppercase section label (`①  FINANCIAL SNAPSHOT`). `Label` style, `.caption.weight(.semibold)`, `.secondary`, small SF Symbol, never heavy. | plain `View` |
| `DashboardMetricCard` | KPI tile. Props: `title, value, subtitle, periodLabel (asOf vs period), systemImage, tone (semantic), onTap`. Compact variant for the 2×2; `prominent` variant for the hero (adds Liquidity/Patrimonial split + sparkline + delta). | `GlassCard(role: .card|.hero)` |
| `DashboardInsightCard` | Insight tile. Props: `title, primaryValue, secondaryLines, status (calm/watch/critical), action?`. Status drives tone — calm is neutral, watch is orange, critical is red. Empty/calm state supported. | `GlassCard(role: .card)` |
| `DashboardChartPanel` | Chart wrapper. Props: `title, subtitle/periodLabel, optional summaryMetrics, content, emptyState`. (This is a refined `ChartCard` — same role, adds a header-aligned accessory slot for the Composition toggle.) | `GlassCard(role: .card)` |
| `DashboardBreakdownPanel` | Alias/specialization of `DashboardChartPanel` for breakdown cards. | `GlassCard(role: .card)` |

**Shared visual contract** (enforced by routing everything through `GlassCard` + a new `DashboardCardTokens` enum):
- Radius: 12 (card), 16 (hero). Inner wells: 8. Plot strokes: 6.
- Padding: 14 (compact card), 18 (hero). Section spacing: 16 (inside dashboard), 20 (top-level stack).
- Material: `.thinMaterial` (cards), `.ultraThinMaterial` (inner wells/icon bubbles).
- Border: white 0.16 / 0.7pt (cards); `Color.primary.opacity(0.08)` / 0.5pt (inner wells).
- Typography: section title `.caption.weight(.semibold).secondary`; card title `.caption.weight(.semibold).secondary`; primary value `.system(size: 34/21, weight: .bold)` (hero/compact); chart summary `.title3.bold()`; body `.callout`; meta `.caption/.caption2`; all monetary via `Text.money()` / `.monospacedDigit()`.

**Sparkline** (`DashboardNetWorthSparkline`, new, ~40 LOC): thin-stroke `Path` + soft fill, no axes/labels/chrome. Reuses `DashboardBalanceSampler` / the existing monthly net-worth points (`netWorthOverTime`) — no new data. Low-contrast (stroke at `scopedTint.opacity(0.5)`, fill `opacity(0.10)`). Wrapped so it collapses to hidden below a width threshold (responsive guardrail).

---

## Semantic color system

A new `DashboardTone` enum centralizes the mapping (replaces ad-hoc `.green`/`.red`/`.mint` scattered today):

| Tone | Color | Use |
|---|---|---|
| `.positive` | green `DashboardChartSeriesColor.income` | healthy / growth / positive |
| `.negative` | red `DashboardChartSeriesColor.expense` | debt / negative / urgent |
| `.warning` | orange `#B26A00` (composition patrimonial token) | due soon / watch |
| `.neutral` | blue (Net Worth Trend `.blue`) | neutral info / selection |
| `.yield` | teal `.mint` / `#00796B` | interest / yield |
| `.secondary` | `.secondary` | muted/secondary |

`CategoryPalette` saturation is **reduced** for the consolidated Spending bars: cap saturation at ~0.58 (down from the cycling `[0.70, 0.62, 0.78, 0.66]`) and use flat `Capsule().fill(color)` instead of `color.gradient` to kill the gloss.

---

## Card specs

### Financial Snapshot

**Hero** (`DashboardMetricCard prominent`):
- Available Net Worth value, delta badge (▲/▼ ±X% vs previous 30d), Liquidity / Patrimonial split, quiet sparkline, "Excludes retirement · As of 7 Jul".
- Delta **requires the new previous-period net-worth computation** (see Data section).

**KPI 2×2** (`DashboardMetricCard` compact):
- Total Net Worth — "As of today" — `.neutral`
- Card Liabilities — "As of today" — `.negative`
- Net Cash Flow — "Last 30 days" — `.negative`/`.positive` by sign
- Interest Earned — "Last 30 days" — `.yield`

### Insights (each a `DashboardInsightCard`, threshold-based)

**Credit Card Pace** (always calendar-month-to-date):
- Primary: `$89,980 spent`.
- Secondary: `Daily avg $12,854 · Projected Jul 31 $132,400`.
- Status thresholds (concrete defaults, tunable):
  - `critical` (red): projected > **130%** of baseline monthly average.
  - `watch` (orange): projected between **100%–130%** of baseline.
  - `calm` (neutral): projected ≤ 100% of baseline.
  - Baseline = mean of the prior **3 calendar months** of total card charges. If < 3 months of history exist, fall back to available months; if none, status is `calm` (no projection claim).
- Progress bar: day-N-of-days-in-month.
- **New computation:** spend-to-date (calendar month, charges only, reuse `computeChargesVsPayments` exclusions), daily avg = spend / day-of-month, projection = avg × days-in-month, baseline as above.

**Upcoming Payments** (next 14 days, forward from today — selector-independent):
- Aggregate primary: total **`paymentForNoInterest`** across due cards (the actionable "pay to avoid interest" figure), with `minimumPayment` as fallback per card when no-interest is absent (D12).
- Secondary rows per card: institution, primary amount, due date. If both exist: `$24,600 to avoid interest` with smaller `minimum $18,200`.
- Label: "Calendar-relative, next 14 days" (selector-independent, like Pace).
- Status: `calm` (none due) → "No payments due soon"; `watch` (due ≤14d) orange; `critical` (due ≤3d) red.
- **New computation:** cross-account fetch of `Statement.paymentDueDate` in `[now, now+14d]`; per card, prefer `paymentForNoInterest`, fall back to `minimumPayment` (do **not** sum minimums when no-interest data exists). Fallback to `Account.paymentDayOfMonth` next-occurrence when statement due date is missing.

**Spending Anomaly** (vs previous equal-length period):
- Primary: `Transport +32%` (strongest meaningful anomaly) or calm state `No unusual spending detected`.
- Secondary: up to 2 more anomalies (e.g. `Events +22%`).
- Status: `calm` (no anomaly qualifies) / `watch`.
- Anomaly rule (concrete defaults, tunable): a category qualifies if **|Δ%| ≥ 30%** AND **absolute spend this period ≥ 5% of total period expenses** (materiality floor, so a $5→$15 jump doesn't trigger). Calm state when none qualify. Cap "strongest" to the largest absolute-Δ% qualifier; "others" up to 2 more, sorted by Δ%.
- **New computation:** per-category spend this period vs previous period (reuse `computeSpendingByCategory` on two windowed sets), %-change, materiality floor, anomaly flag.

### Trends

**Cash Flow** (`DashboardChartPanel`): header summary `Net −$28,294 · In $68.2k · Out $96.5k`, "Excludes transfers" caption. Chart keeps current behavior: `DashboardCashFlowTrendChart` for `.month`, `DashboardGroupedPeriodBarChart` otherwise. No shrink below readable — if bars compress, the period's line form is acceptable.

**Net Worth Trend** (`DashboardChartPanel`): unchanged chart (`DashboardBalanceTimeSeriesChart`), header shows current value + period delta. Absolute/Change toggle and jump annotations are **future** — stub the header accessory slot only.

### Breakdowns

**Net Worth Composition** (`DashboardChartPanel`): Total/Available **`Picker` moved into the header accessory slot** (was floating inside the panel). Donut + numeric rows; numbers carry more weight than the donut.

**Spending by Category** (`DashboardChartPanel` + redesigned `DashboardSpendingCategoryBars`): flat matte bars (desaturated, no gradient). Top N real categories, rest into "Other". If Other > ~40% of spend → clickable warning chip `⚠ 53.6% of spend is 'Other' — review transactions` → opens Transactions view filtered to uncategorized. "Other" row also tappable.

### Accounts / Recent Transactions
Unchanged. Moved below Breakdowns.

---

## Data & computation changes

All in `DashboardViewModel.swift` + `DashboardSnapshot.swift`. **No schema changes.** New pieces:

1. **Previous-period engine** (foundational — reused by hero delta + Anomaly):
   - `DashboardPeriodContext.previousRange` → `[start − duration, start)`.
   - **Transaction-metric delta** (cash-flow, per-category spend): `computeTransactionMetrics` and `computeSpendingByCategory` are run a second time over the previous-window transaction set — these are cheap, transaction-only passes.
   - **Net-worth delta** (hero badge): the *previous* net worth at the *previous period's effective date* requires balance resolution. `computeNetWorth` is `@MainActor` and needs `ModelContext` + `accounts` + the balance resolver, so it is not a cheap pure rerun. Reuse the already-built `DashboardBalanceSampler`s (cached on the VM) and the pure helper `computeMonthlyNetWorth(samplers:period:)` to sample net worth at the previous effective date — avoid re-resolving balances. The hero delta is thus "net worth at period end vs net worth at previous-period end", both point-in-time samples from the existing samplers.
   - New snapshot fields: `previousNetWorth`, `netWorthDelta`, `netWorthDeltaPercent`; per-category `previousSpendingByCategory`.
2. **`CardPaceSnapshot`** (calendar-month): `spentToDate, dailyAverage, projectedMonthEnd, baselineAverage, status`. New VM method, selector-independent, always current calendar month.
3. **`UpcomingPaymentsSnapshot`**: `[UpcomingPayment(institution, amount, dueDate, daysUntilDue)]` + aggregate. Cross-account `Statement` fetch with 14-day window.
4. **`SpendingAnomalySnapshot`**: `strongest: CategoryAnomaly?`, `others: [CategoryAnomaly]`, `isCalm: Bool`. Built on the previous-period per-category diff.
5. **Hero enrichment**: `availableNetWorth` already exists on `NetWorthComposition`; wire Liquidity/Patrimonial/delta onto the hero's view state.

All new snapshots are plain `Sendable` value types (concurrency invariant: never pass `@Model` into views/parsers — these are pre-computed values).

---

## Responsive behavior

- **Wide desktop (≥ ~860pt):** hero + 2×2 side by side (Decision A), Insights as 3-up row, Trends/Breakdowns as 2-col.
- **Medium:** hero + 2×2 stack vertically; Insights wrap 2-then-1; Trends/Breakdowns stay 2-col or drop to 1.
- **Narrow:** sparkline hides, hero compacts; everything single-column.
- Existing `ViewThatFits(in: .horizontal)` pattern in `ConsolidatedDashboard` is reused/extended.

---

## Implementation order (per user)

1. New dashboard layout & section structure (`DashboardSectionHeader`, top-level `VStack` with four sections).
2. Reusable card/panel components (`DashboardMetricCard`, `DashboardInsightCard`, `DashboardChartPanel`, `DashboardBreakdownPanel`, `DashboardTone`, `DashboardCardTokens`).
3. Financial Snapshot alignment (hero + 2×2 + sparkline + labels).
4. Previous-period engine + Insights row (Pace, Upcoming Payments, Anomaly) with threshold-based states.
5. Matte Spending by Category redesign + Other warning.
6. Trend chart cleanup (Cash Flow summary header; Composition toggle into header).
7. Tests for render-state/presenter logic.
8. Household/Fer: architecture-ready only (4th Insight slot), implementation deferred.

---

## Acceptance criteria

1. Top section no longer feels misaligned/asymmetrical.
2. All cards feel like one design system (shared radius/padding/border/material/typography/spacing; matte-vs-glossy inconsistency gone).
3. Dashboard answers in <5s: available net worth, card debt, cash flow, whether card pace is normal/high, upcoming payments, which category needs attention.
4. Spending by Category has no glossy style.
5. "Other" flagged when it dominates; warning is actionable/clickable.
6. As-of-today vs period metrics clearly labeled on every tile.
7. A Household/Fer Insight card can be added later without redesigning the layout.

---

## Verification

- **Build:** `xcodegen generate` then `xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build` (DEVELOPER_DIR set per CLAUDE.md).
- **Unit tests (required — six areas):**
  1. Credit Card Pace projection (daily avg × days-in-month) and baseline thresholds (critical >130% / watch 100–130% / calm ≤100%; calm fallback when <3 months history).
  2. Upcoming Payments amount selection (no-interest-first; minimum fallback; never sum minimums when no-interest present) and due-date status (calm/watch ≤14d/critical ≤3d).
  3. Spending Anomaly thresholds (|Δ%|≥30% AND ≥5%-of-expenses materiality) and calm state.
  4. Previous-period net-worth delta (point-in-time sample via `computeMonthlyNetWorth`, not `computeNetWorth`).
  5. Period / as-of label mapping (point-in-time vs period vs Pace "Calendar month to date").
  6. "Other" warning visibility (shown when Other > ~40%; hidden below).
  - Add to an existing `@Test` suite, not a new isolated `@MainActor` suite (per memory: isolated suites crash on launch and turn the run red). Run with `-parallel-testing-enabled NO` per CLAUDE.md.
- **Visual:** launch the app, open the consolidated dashboard, confirm the four sections render, sparkline shows/hides on window resize, Insights show calm states on a clean fixture and alert states on a loaded fixture, Composition toggle is in the header, Other-warning is clickable.
- **Invariants preserved:** transfers + credit-card payments excluded from cash flow; MSI synthesized originals excluded; liability balances signed-negative; net worth point-in-time; period semantics (Month = rolling 30d) unchanged except Pace.
