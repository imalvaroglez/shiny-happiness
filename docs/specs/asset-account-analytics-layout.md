# Asset account analytics layout

## Goal

Reduce vertical scrolling in checking, savings, and investment account dashboards
so users can see account activity and recent transactions together more easily.

## Behavior

- Place Cash Flow, Balance Over Time, and Spending by Category inside one full-
  width chart card.
- Show all three panels in one row when each has at least 300 points of width.
  If three do not fit, show only Cash Flow and Spending by Category, side by
  side when possible and stacked on narrow windows. Balance Over Time appears
  only in the three-panel row; there is no extra row for the third chart.
  Use the same minimum width and shared spacing across both row variants.
- Keep each panel's existing period, amounts, hover details, and drill-downs.
- Cash Flow keeps every daily group and exact tooltip amount, while showing only
  a readable sample of x-axis labels. If one value is at least four times the
  90th-percentile activity and there are enough positive observations, cap the
  plotted scale at twice that percentile, mark overflow on the bar, and retain
  the actual value in its tooltip.
- Balance Over Time retains its point-in-time step line and selection behavior.
  In the compact account panel, omit the large area fill and intermediate point
  markers, and leave headroom above the latest balance for the y-axis label.
- Spending by Category uses a compact donut with the leading categories plus an
  aggregated Other slice. Selecting Other opens the full category breakdown.
- Show up to 15 recent transactions below the shared chart card.

## Acceptance and verification

- A 31-day Cash Flow series fits within a 245-point panel, has readable sampled
  date labels, and preserves access to every day's tooltip and breakdown.
- A single large daily movement does not make ordinary daily bars appear flat;
  the outlier remains identifiable and its exact amount remains available.
- A high balance near the top of the range does not clip the y-axis label.
- All three panels preserve their existing drill-down behavior, including the
  Other category path to the full category list.
- With at least 958 points of chart content width (excluding card padding),
  the three panels share one row. Below that, Cash Flow and Spending by Category
  share a row when at least 629 points are available, then stack if narrower.
  Balance Over Time is absent from both fallback layouts.
- Source previews cover dashboard widths 1280, 820, and 540 points with synthetic
  daily activity. Native visual checks and visible response latency remain
  pending until the user confirms screen availability.
- Run focused DashboardPeriodFilteringTests, the complete serial suite, and the
  canonical Debug build. Record an interactive UI response measurement with
  representative data before marking ready for development validation.

## Verification recorded — 2026-10-25

- Focused DashboardPeriodFilteringTests: 62 tests passed.
- Full serial suite: 656 tests in 74 suites passed, 13.564 seconds.
- Canonical Debug build: BUILD SUCCEEDED. Whitespace check clean.
- This change updates layout selection and preview widths; period resolution,
  financial values, chart scales, and drill-down callbacks retain their existing code.
- Native wide/narrow appearance, keyboard/VoiceOver and visible response latency
  remain pending screen availability; no readiness claim or production installation.

Local logs: `/private/tmp/asset-chart-row-focused.log`,
`/private/tmp/asset-chart-row-full.log`, `/private/tmp/asset-chart-row-build.log`.
