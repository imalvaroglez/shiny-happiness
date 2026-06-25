# Stocks Portfolio Tracking

Track a personal stock portfolio (mostly BMV / Mexican market) as an `investment`
account: per-stock positions, current value, and growth percentage versus cost basis.

## Goal

Add the user's stock holdings as an account so the app shows, per position and in
aggregate:

- **Current value** — live, fetched from DataBursatil on demand.
- **Total invested** — cost basis, always known.
- **Growth %** — `(current value − total invested) / total invested`.

The portfolio counts toward consolidated Net Worth, consistent with how retirement
balances are treated.

## Decisions (from brainstorming)

| Decision | Choice |
| --- | --- |
| Tracking granularity | **Per-stock positions** (ticker + shares + average cost) |
| Price source | **Automatic fetch** from DataBursatil (BMV + BIVA) |
| Cost basis | **One position per stock**; "buy more" updates shares + weighted-average cost. No lots. |
| History chart | **None.** Current value + growth % only. No persisted price time series. |
| Data entry | **Manual positions panel** (sheet), like the category-management sheet. No broker CSV/parser. |
| Fetch trigger | **On-demand button only.** No automatic fetch, no throttle, no background refresh. |
| Net Worth integration | **Option 1 — through `AccountBalanceResolver`** (single path for "account value as-of date"). |
| Headline metric | **Total growth vs cost basis**, not intraday `cambio%`. |

## Provider: DataBursatil

Purpose-built for the Mexican market (BMV + BIVA). Chosen over Yahoo (unofficial,
crumb/cookie fragility) and Stooq (unverified BMV ticker coverage).

- **Base URL:** `https://api.databursatil.com/v1/`
- **Endpoint:** `/precios?emisora_serie={SERIES}&token={TOKEN}&bolsa=BMV,BIVA`
- **Method:** GET only. HTTP redirects to HTTPS.
- **Auth:** single personal `token` query param. Stored in app Settings; never logged.
  Sign up / retrieve at `https://databursatil.com/nuevo_usuario.php`.
- **Quota:** 250,000 credits/month per user. A handful of tickers fetched on demand is
  negligible usage. No per-call rate-limit handling needed beyond the on-demand trigger.
- **Response** (keyed by exchange):
  ```json
  {
    "BMV": { "ultimo": 19.86, "ppp": 19.81, "cambio%": -0.25, "cambio$": -0.05, "tiempo": "2022-03-10 03:00:00" },
    "BIVA": { "ultimo": 19.85, "ppp": 0.0,  "cambio%": -0.05, "cambio$": -0.01, "tiempo": "2022-03-10 03:00:00" }
  }
  ```
  - Prefer `BMV`; fall back to `BIVA` if BMV is absent or `ultimo` is 0/missing.
  - Price = `ultimo`. Timestamp = `tiempo` parsed from `YYYY-MM-DD hh:mm:ss`.
  - `cambio%` here is **intraday change vs the day's open** — NOT used for our growth
    metric. We compute growth locally from cost basis. DataBursatil only supplies the
    live `ultimo` price per holding.

## Data Model

Two new SwiftData `@Model` types under the existing `Account`. Reuses
`AccountType.investment` (already defined; defaults `includeInNetWorth = true`,
`includeInCashFlow = false`).

### `Security` — one row per stock held

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `UUID` | |
| `account` | `Account?` | inverse relationship |
| `emisoraSerie` | `String` | DataBursatil ticker, e.g. `FEMSAUBD`, `BIMBOA`. Uppercased on save. The full Yahoo-style `FEMSAUBD.MX` is display-only; we store the canonical BMV series. |
| `name` | `String?` | human label, typed manually (no `/emisoras` lookup in v1) |
| `shares` | `Decimal` | quantity held (all-Decimal invariant) |
| `averageCost` | `Decimal` | cost basis per share; updates on "buy more" |
| `lastPrice` | `Decimal?` | most recent fetched `ultimo`, cached |
| `lastPriceAt` | `Date?` | timestamp of that price (the `tiempo` field) |
| `createdAt` | `Date` | |
| `lastModifiedAt` | `Date` | matches existing soft-touch pattern |

### Not built (YAGNI)

- **`PriceQuote` time series** — would persist historical quotes for a balance-over-time
  chart. Out of scope: no history chart requested. `Security.lastPrice` + `lastPriceAt`
  suffices. This is the seam to add later.
- **`Lot` model** — per-purchase lots. Out of scope: single position per stock.
- **Realized-gain / sell tracking** — selling is not a first-class action in v1.

### Derived values (computed, not stored)

- Position value = `shares * lastPrice` (or `nil` if no price yet)
- Position cost = `shares * averageCost`
- Position growth % = `(value − cost) / cost`
- Portfolio totals = sum across the account's `Security` rows
- Portfolio growth % = `(totalValue − totalCost) / totalCost`

**Why `Security` is the only position model:** it holds both the ticker+price concern
(written by the fetch layer) and the holding concern (written by the panel). Splitting
into Security + Lot later is trivial; collapsing a future split is also trivial. One
model per clear responsibility.

## Price-fetch layer

Isolated so the rest of the app never touches networking.

### `DataBursatilClient` (`@MainActor`)

- Reads token from Settings (`AppSettings.databursatilToken: String`).
- `func currentPrice(emisoraSerie: String) async throws -> PriceSnapshot`
  where `PriceSnapshot` is a `Sendable` struct `{ price: Decimal, timestamp: Date }`.
- Request: `GET .../precios?emisora_serie={series}&token={token}&bolsa=BMV,BIVA`.
- Parsing: prefer BMV, fall back to BIVA; read `ultimo` + `tiempo`.
- **Decimal discipline:** API returns Float; parse to `Decimal` at this boundary (one
  place). No Double flows into `Domain/`.
- **Typed errors:** `missingToken`, `requestFailed`, `http(Int)` (401 bad/disabled token,
  402/credits), `noQuoteForTicker`, `decodeFailed`. Surfaced as one-line UI status, never
  a crash.

### `PortfolioPriceRefresher`

- `func refreshAll(in account: Account, context: ModelContext) async` — iterates the
  account's `Security` rows, calls the client per row, writes `lastPrice` / `lastPriceAt`
  back, saves once at the end.
- **Triggered only by the "Refresh prices" button.** No `.task` auto-fetch, no throttle,
  no timers.
- **Failure behavior:** if a fetch fails, keep showing the cached `lastPrice` with a
  "stale · {timestamp}" subtitle. Current value never goes blank — degrades to last-known.

### Token in Settings

Settings view gains a field to paste the token (link to
`databursatil.com/nuevo_usuario.php`). Until set, the portfolio shows cost basis and
positions but current value reads "enter token to fetch prices."

### `PriceProvider` protocol — deferred

DataBursatil covers BMV cleanly and is the only provider. A protocol with one
implementation is premature; the client is the single seam. Add a protocol + second
implementation only if DataBursatil becomes unreliable or US-markets coverage is needed.
`// ponytail: single provider; add PriceProvider protocol if a second source is needed.`

## Positions panel (data entry)

Follows the existing **category-management sheet** pattern (search/filter, sheet-based,
inline edit).

- **Location:** the portfolio account's `AssetAccountDashboard` gains a Positions section
  + "Add / Edit Positions" button opening a sheet. One investment account = one set of
  positions; multiple brokerages = separate investment accounts.
- **List:** each `Security` — ticker, name, shares, average cost, last price, current
  value, growth %.
- **Add position:** `emisoraSerie`, optional `name`, `shares`, `averageCost` (per share).
- **Buy more** (existing position): enter added shares + buy price; recompute
  `newAverageCost = (oldShares·oldAvg + addedShares·buyPrice) / (oldShares + addedShares)`
  and `shares += addedShares`. All `Decimal`. Only place cost basis changes.
- **Edit / delete:** fix typos in shares/cost, or remove a sold-off position. Selling is
  not first-class — to reflect a sale, edit `shares` down (and the cost basis per share is
  left as the running average). Realized-gain tracking deferred.
  `// ponytail: no realized-gain tracking; add when tax reporting matters.`
- **Validation (trust boundary):** `shares >= 0`, `averageCost >= 0`, `emisoraSerie`
  non-empty and uppercased. Reject negatives — "buy more" must always add a positive
  share count.
- **Ticker entry:** plain text, uppercased on save. No autocomplete vs `/emisoras` in v1.

No ingest/parser changes — positions are manual only; the bank/credit-card pipeline is
untouched.

## Dashboard display

Reuse over new build. The portfolio is an `investment` account, so it already routes to
`AssetAccountDashboard`.

**Added to the investment dashboard:**

- **Summary block** (existing summary-card style):
  - **Current value** — Σ(shares · lastPrice). "Refresh prices" button beside it.
  - **Total invested** — Σ(shares · averageCost). Always known.
  - **Total growth** — `(current − invested) / invested`, formatted `%+` like the existing
    balance-change card.
- **Positions table:** ticker, name, shares, avg cost, last price, value, per-position
  growth %. Same row styling as the Transactions table. For an investment account this
  stands in for the transactions section (investment accounts have no statement
  transactions by default).

**Net Worth integration — Option 1 (resolver):** `AccountBalanceResolver` returns
Σ(shares · lastPrice) as the investment account's balance as-of the effective date. Net
Worth then includes it automatically via the existing aggregator — no special-casing in
`computeNetWorth`, and the existing Net Worth chart would show a point for it.

**Headline metric:** total growth vs cost basis, not the day-over-day "Balance Change"
card other asset accounts show, and not DataBursatil's intraday `cambio%`.

`includeInNetWorth = true` / `includeInCashFlow = false` already default correctly for
`investment` accounts — portfolio counts toward net worth, never pollutes cash flow.

## Concurrency & invariants (per CLAUDE.md)

- Swift 6 strict concurrency. Client/refresher are `@MainActor` (use `ModelContext`).
  Values crossing boundaries are `Sendable`; never pass `@Model` objects into networking.
- **All monetary values are `Decimal`** — Float from the API is converted to `Decimal` at
  the one parse boundary, nowhere else in `Domain/`.
- Follows existing patterns: `@Model` for persistence, sheet-based management UI,
  summary-card / table-row styling, resolver-based account value.

## Testing

- `DataBursatilClient` parsing: fixture JSON (BMV-only, BIVA-fallback, missing/zero BMV),
  `tiempo` parsing, Decimal conversion, typed-error cases (401, 402, no quote, decode).
- `PortfolioPriceRefresher`: writes `lastPrice`/`lastPriceAt` across multiple positions,
  single save, leaves positions unchanged on failure (degrades to last-known).
- Weighted-average-cost math on "buy more" (Decimal precision).
- Derived-value computations: position value/cost/growth, portfolio totals, growth %.
- `AccountBalanceResolver` investment branch: returns Σ(shares·lastPrice); falls back
  gracefully when a position has no price yet.
- Add to an existing `@MainActor` test suite (do NOT create a new isolated suite — see
  project memory: a new isolated suite crashes on launch). Serial run
  (`-parallel-testing-enabled NO`).
- `xcodegen generate` after adding new Swift files.

## Out of scope (deferred)

- Per-position price history + balance-over-time chart (`PriceQuote` seam).
- Per-purchase lots / exact cost basis / realized & unrealized gains per lot.
- First-class sell action + realized-gain reporting.
- Multi-currency / FX (portfolio is MXN; app has no FX today).
- Broker CSV import.
- `PriceProvider` abstraction / second data source.
- Autocomplete tickers via `/emisoras`.
