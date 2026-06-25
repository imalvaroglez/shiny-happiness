# Stocks Portfolio Tracking — Revised Design (post-review)

## Context

The user wants to track a personal stock portfolio (mostly BMV/Mexican market) as an
account: per-stock positions, current value, and growth % vs cost basis, counting toward
Net Worth. A first spec (`specs/stocks-portfolio.md`) was written and committed, then went
through five rigorous review rounds. This plan is the **fully revised design** addressing
every blocker and correction. All reviewer claims were independently verified against the
official API docs and the codebase — every one is correct.

- **Round 1:** obsolete v1 provider contract; "no history" contradicting Net Worth; missing
  persistence-safety coverage.
- **Round 2:** V2 schema not frozen; old-backup restoration; unverified provider contract
  details; holdings edits producing a misleading "current value."
- **Round 3:** "refresh required" needs a persisted representation (fingerprint); the
  resolver can't stay unchanged (authoritative valuation); deleting the last position leaves
  phantom Net Worth + portfolio-mode gating; the dashboard UI data flow is unspecified;
  backup correction (v3 must require `StockPosition.json`).
- **Round 4:** resolution lacks snapshot provenance (dashboard can't read the fingerprint
  reliably); existing investment accounts can still be accidentally converted; backup merge
  can overwrite holdings with cached-quote updates.
- **Round 5** (this revision): an emptied portfolio cannot be restarted (deadlock); the
  authoritative resolver rule must not depend on current portfolio mode; plus canonical
  fingerprint decimals (`NSDecimalNumber.stringValue`), migration-stage decision, pre-first-
  valuation UI wording, token-URL redaction, and removal of duplicated sections.

All are fixed below.

On plan approval, this design is mirrored into `specs/stocks-portfolio.md` (replacing the
current content) and committed, then the writing-plans skill produces the step-by-step
implementation plan.

### What is now verified (rounds 1–4)

- **Provider:** V2 is current; v1 *obsoleta*. Endpoint `/v2/cotizaciones`, **up to 50
  tickers per request**, quota **200,000** credits/month. (Round 1.)
- **History:** `AccountBalanceResolver.allAnchors()`
  (`Domain/Services/AccountBalanceResolver.swift:194-206`) already turns
  `AccountBalanceSnapshot` rows into `.manualSnapshot` anchors for **all** account types —
  so portfolio total written as a snapshot flows into Net Worth. **But** `resolution()`
  (lines 41-107) rolls transactions forward over the latest anchor (`base + deltas`,
  90-94), which would corrupt a market-value valuation — so the resolver needs the
  authoritative-valuation rule. (Round 1 + Round 3.)
- **Resolution has no provenance:** `AccountBalanceResolution` (lines 15-27) returns
  `amount`/`sourceKind`/`sourceDate` but **not which snapshot** produced it — the dashboard
  can't reliably read the selected valuation's fingerprint, and a later statement/manual
  snapshot could be mistaken for a portfolio valuation. Needs snapshot provenance fields.
  (Round 4, blocker 1.)
- **V2 schema is NOT frozen:** `FinanceTrackerSchemaV2.models { AppSchema.modelTypes }`
  (`App/AppSchema.swift:214-217`) dynamically references the shared list — V1 is the only
  frozen (explicit-literal) version. "Freeze V2" means **freezing its model *list*** (which
  types belong to that version), not the model *definitions*. Adding a model to
  `AppSchema.modelTypes` today would retroactively mutate V2's list. (Round 2, blocker 1.)
- **Backup versioning is explicit:** `BackupArchive.schemaVersion = 2` + allow-list
  (`BackupArchive.swift:14,107-108`), and `loadOptionalJSON` already exists and is used for
  `AccountBalanceSnapshot` (`BackupArchive.swift:118,133`). Old backups omit models not yet
  invented. (Round 2, blocker 2.)
- **Backup merge is whole-row by `lastModifiedAt`:** every `resolveOrInsert…` does
  `if snap.lastModifiedAt > existing.lastModifiedAt { existing.apply(snap) }` — a single
  `apply()` overwrites **all** fields. `lastModifiedAt` is a plain `var … = Date.now`
  conventionally re-stamped on any mutation. So if quote refresh re-stamped it, a backup
  row with a newer quote-stamp but older shares/cost would clobber a newer holding. →
  StockPosition merge must be **field-selective** and quote refresh must **not** touch
  `lastModifiedAt`. (Round 4, blocker 3.)
- **`Account` has NO inverse collection properties** — all children are fetched by
  `accountId` via `FetchDescriptor` (see `AccountDeletionService.collectLinkedObjects`).
  An inverse `[StockPosition]` would add migration surface for no value. (Round 2.)
- **`AccountBalanceSnapshotKind`** is a raw-value `Codable` enum with only
  `manualOpening`/`manualAdjustment` (`Domain/ValueObjects/AccountBalanceSnapshotKind.swift`);
  a new `.portfolioValuation` case is backward-compatible. (Round 2.) The resolver treats
  it as **authoritative**, not identically.
- **Dashboard can't act:** `AssetAccountDashboard` is built with only an immutable
  `AssetAccountSnapshot` + `onTransactionTap` (`DashboardView.swift:300-303`) — it cannot
  fetch/edit/refresh. `DashboardView` already owns action closures for the liability
  dashboard (`onEditPaymentDetails`, 304-315) — same seam for portfolio actions. (Round 3,
  blocker 4.)
- **Existing non-stock investment accounts:** CETES / CI Banco are real `.investment`
  accounts (`Detector.swift`, `AccountIdentity.swift`, `ManualAccountSheet`); portfolio UI
  must be opt-in per account. (Round 3 + Round 4, blocker 2.)
- **No `AppSettings`, no Keychain usage today.** Token needs a new Keychain helper, kept
  out of `.ftbackup`. (Round 1.)
- **Provider contract unverified points:** the official `/v2/cotizaciones` docs list valid
  `concepto` values as `u,p,a,x,n,c,m,v,o,i` — **`F` is not among them** — yet the response
  table lists an `f` key ("Fecha de los precios"). The example response is an image only, so
  the actual JSON nesting (and whether `f` is always present / its exact format for
  *cotizaciones*) is **not confirmable from docs**. Validate live before finalizing the
  Codable structs. (Round 2, blocker 3.)

---

## Pre-implementation gated step: validate the live v2 response

MUST happen before the `DataBursatilClient` Codable structs are finalized. Using the user's
token:

```
curl 'https://api.databursatil.com/v2/cotizaciones?token=…&concepto=U&emisora_serie=FEMSAUBD,BIMBOA&bolsa=BMV,BIVA'
```

Capture the real JSON and confirm:
- The response always includes `f` even though `F` isn't a requestable `concepto` (if not,
  drop timestamp parsing; `lastPriceAt` becomes the fetch time).
- The exact `f` date format for cotizaciones and its **timezone** (docs elsewhere say
  `YYYY-MM-DD hh:mm:ss`; treat timezone as unverified — pin the parser to a fixed locale
  and an explicitly chosen timezone, defaulting to America/Mexico_City, and confirm).
- The real nesting: ticker-keyed object whose value contains a per-bolsa structure (resolve
  the docs' self-contradictory `"BIVA"` key — is `BIVA` a peer of the ticker keys, or a
  nested field?).
- BMV-vs-BIVA precedence and the shape returned for a ticker with no quote.
- That JSON numbers decode straight into `Decimal` (no `Float`).

Adjust the Codable structs + date formatter to match before writing anything downstream.

---

## Provider: DataBursatil V2

- **Base:** `https://api.databursatil.com/v2/`
- **Endpoint:** `GET /cotizaciones?token={TOKEN}&emisora_serie={T1,T2,…}&concepto=U&bolsa=BMV,BIVA`
  - `emisora_serie`: **up to 50** tickers, comma-separated — **one batched request** for the
    whole portfolio.
  - `concepto=U` only — `u` (último = last price) is the only concept we need. (`c` =
    intraday % change vs open is **not** our growth metric.) `f` is returned automatically;
    it is **not** requestable, so it is NOT added to `concepto`.
  - `bolsa=BMV,BIVA`. GET only; non-GET → HTTP 403.
- **Response** (shape to be confirmed live; per docs, keyed by emisora_serie with `u` and
  `f`): prefer the `BMV` quote; fall back to `BIVA` only if BMV absent or `u` missing/zero.
  Price = `u`; timestamp = `f` (format/timezone pinned during the gated step).
- **>50 active positions:** DataBursatil caps a request at 50. **Cap active positions at 50
  per account** (enforced in the panel — reject add/buy-more that would exceed 50 active
  tickers). Do not implement multi-request paging in v1.
- **Auth:** personal 30-char `token` (query param), stored in **Keychain**.
- **Quota:** 200,000 credits/month, ~1 credit per KiB. Negligible for a small portfolio
  fetched on demand.

---

## Data model

### New `@Model StockPosition` — one row per stock held

| Field | Type | Notes |
| --- | --- | --- |
| `id` | `UUID` | |
| `account` | `Account?` | `@Relationship(deleteRule: .nullify)` back-reference. **No inverse collection on `Account`** (fetched by `accountId`, matching existing children). |
| `emisoraSerie` | `String` | DataBursatil ticker, e.g. `FEMSAUBD`. Uppercased on save. |
| `name` | `String?` | human label, typed manually (no `/emisoras` lookup in v1) |
| `shares` | `Decimal` | quantity held; **active = `shares > 0`** |
| `averageCost` | `Decimal` | cost basis per share; updates only on "buy more" |
| `lastPrice` | `Decimal?` | most recent fetched `u`, cached (positions table only) |
| `lastPriceAt` | `Date?` | timestamp from `f` (or fetch time if `f` absent) |
| `createdAt` | `Date` | |
| `lastModifiedAt` | `Date` | **touched only on ticker/shares/cost/name edits — NOT on quote refresh.** Used by `.ftbackup` mergeKeepingNewer for holding fields. See backup-merge rule. |

**Derived (computed, not stored):** position value = `shares * lastPrice` (`nil` if no
price); position cost = `shares * averageCost`; position growth % = `(value − cost) / cost`
(**undefined/`nil` when `cost == 0`**). Portfolio totals sum **active** positions only;
portfolio growth % = `(totalValue − totalCost) / totalCost` (undefined when totalCost 0).

**Net Worth value lives in `AccountBalanceSnapshot`, NOT in StockPosition.** After a
complete successful refresh, the refresher writes **one** `AccountBalanceSnapshot` onto the
investment account: `kind: .portfolioValuation` (new case), `date: now`, `amount:
totalValue`, and `note` carrying a **holdings fingerprint** (see below). Per-position
`lastPrice`/`lastPriceAt` are display-only and are NOT summed into anything.

### Holdings fingerprint — persisted "refresh required" + historical-growth guard

The "holdings changed — refresh required" state must survive edits, deletion, relaunch,
backup, and restore. `lastModifiedAt` can't do it (quote refreshes also touch positions;
deletion drops the timestamp). Instead, store a **SHA-256 fingerprint of the sorted
`(emisoraSerie, shares, averageCost)` tuples of active positions** inside the
`.portfolioValuation` snapshot's `note` (a structured prefix, e.g. `"Portfolio valuation
|fp=<hex>"`). The fingerprint is recomputed from current holdings and compared:

- **Refresh-required:** if the current-holdings fingerprint ≠ the latest valuation's
  fingerprint → holdings changed since that valuation → show "refresh required", total
  growth unavailable.
- **Historical growth:** total growth for a selected period is shown **only when that
  period's resolved valuation fingerprint matches current holdings**; otherwise unavailable
  (you can't compute growth against a valuation of different holdings). The fingerprint is
  read from the **resolution's provenance** (`sourceSnapshotNote`) — see the resolver change
  below — and only when `sourceSnapshotKind == .portfolioValuation`.
- No new model field. Survives restore because it lives in the snapshot's `note`, which is
  already backed up.

**Canonical fingerprint serialization (minor fix):** the fingerprint input is built from
**normalized** fields so it is stable across locales and formatting: tickers uppercased and
trimmed, then sorted ascending; `shares` and `averageCost` serialized canonically via
`NSDecimalNumber(decimal:).stringValue` (locale-independent, no grouping separators —
verified: `19.86` → `"19.86"`, `100` → `"100"`); tuples joined by a delimiter that can't
appear in the fields (e.g. `\u{1F}` ). Active positions only (`shares > 0`).

### New enum case

`AccountBalanceSnapshotKind.portfolioValuation` — raw-value `Codable` enum, so existing
rows (`.manualOpening`/`.manualAdjustment`) decode unchanged. Gives backups, UI, and future
repairs honest provenance.

### `AccountBalanceResolver` — TWO narrow, required changes

**(a) Authoritative valuation — UNCONDITIONAL on anchor kind.** Today `resolution()`
(`Domain/Services/AccountBalanceResolver.swift:41-107`) takes the latest anchor through the
as-of date and **rolls transactions forward over it** (`base + deltas`, lines 90-94; also
the `manualOpening` branch 53-78). For a market-value valuation that is **wrong**: a manual
transaction posted after a portfolio valuation would silently change its market value. Rule:
when the latest anchor at-or-before the as-of date is a `.manualSnapshot` whose
`kind == .portfolioValuation`, return its `amount` verbatim — **no roll-forward, no
reconstruction**. Earlier anchors / other account types are unaffected. **This rule is based
solely on the anchor's kind — it applies whether or not the account currently has positions.**
Tying it to live portfolio mode would corrupt historical valuation resolution after the
portfolio is emptied (the still-existing `.portfolioValuation` history must remain
authoritative). Current positions control only which **UI** is shown, never the resolver.

**(b) Resolution provenance (blocker 1).** `AccountBalanceResolution` (lines 15-27) returns
`amount`/`sourceKind`/`sourceDate` but **not which snapshot produced it**. The dashboard
needs the selected valuation's fingerprint to decide whether total growth is available, and
a later statement/`.manualAdjustment` must not be mistaken for a portfolio valuation. Add
provenance fields to `AccountBalanceResolution`: `sourceSnapshotID: UUID?`,
`sourceSnapshotKind: AccountBalanceSnapshotKind?` (also expose statement vs. snapshot at
the anchor level), and `sourceSnapshotNote: String?`. The portfolio dashboard reads the
fingerprint out of `sourceSnapshotNote` **only when `sourceSnapshotKind ==
.portfolioValuation`**; otherwise (statement / other snapshot) it treats growth as
unavailable for that period.

### Reused, otherwise unchanged

- `Account` + `AccountType.investment` (already exists; defaults `includeInNetWorth = true`,
  `includeInCashFlow = false`). **No inverse `[StockPosition]` property added.**
- `AccountBalanceSnapshot` — unchanged structure (the fingerprint rides in the existing
  `note` field).

### Not built (YAGNI, named seams)

- `PriceQuote` time series — subsumed by `AccountBalanceSnapshot` history.
- `Lot` model / realized gains / first-class sell / FX / broker CSV / `PriceProvider`
  abstraction / `/emisoras` autocomplete / multi-request paging beyond 50 tickers.

---

## Concurrency & token storage

- **Keychain helper** (new, Security framework): store/retrieve/delete the DataBursatil
  token under a service+account key. **Not** in SwiftData, **not** exported in `.ftbackup`.
- **Settings UI:** a `SecureField` for the token with explicit **Save** and **Clear**
  controls + a link to `databursatil.com/nuevo_usuario.php`. Until a token is set,
  positions show but the summary reads "enter token to fetch prices."
- `DataBursatilClient`: **`struct`, `Sendable`**, takes an **injected transport**
  (`URLSession` or a small `requesting` protocol) for testability. Reads token from
  Keychain. Method `func quotes(for tickers: [String]) async throws -> [String: PriceSnapshot]`
  where `PriceSnapshot: Sendable { price: Decimal; timestamp: Date? }` — **one batched
  call**. Typed errors: `missingToken`, `requestFailed`, `http(Int)` (401/403/402),
  `noQuotes`, `decodeFailed`. **JSON numbers decode directly to `Decimal` — no `Float`,
  no `Double` enters `Domain/`.** **Error messages must never include the request URL or
  token** — the URL contains the token as a query param; redact it in any surfaced error.
  tickers (`shares > 0`), calls the client once, writes **only `lastPrice`/`lastPriceAt`**
  onto each `StockPosition` — **it does NOT touch `lastModifiedAt`** (see backup-merge rule
  below). Then — **only if every active ticker was returned with a usable quote in this
  request** — it writes the `.portfolioValuation` `AccountBalanceSnapshot` (`amount =
  totalValue`, `note` carrying the current **holdings fingerprint**) and saves once.
  "Complete" means every active ticker succeeded *in this fetch*, not merely that a cached
  price exists. On partial: keep the prior snapshot, still persist the per-position prices
  that did arrive, return a `partial` result. **Triggered only by the "Refresh prices"
  button** (no auto-fetch, no throttle, no timers). Offline/failure: show cached prices
  with a "stale · {timestamp}" subtitle; never blends days into Net Worth. Before the first
  successful quote, show **"Not priced yet"** (not blank, not zero).
- **Deleting the last position → zero valuation (no refresh needed):** when an edit leaves
  the account with **zero active positions**, the panel/refresher immediately writes a
  `.portfolioValuation` snapshot with `amount = 0` and the (empty) fingerprint. This
  retires the previous non-zero valuation so Net Worth doesn't carry phantom value. An
  empty portfolio is definitively worth zero — no provider call required.

---

## Positions panel (data entry) — plain list + edit sheet

- **Owned by `DashboardView`** (not the dashboard struct — see Data flow). An "Edit
  Positions" button opens a sheet (no search/filter — portfolios are small).
- List per `StockPosition`: ticker, name, shares, avg cost, last price, value, growth %.
- **Add:** `emisoraSerie`, optional `name`, `shares` (>0), `averageCost` (>= 0). Reject if
  the ticker already exists in the account → route to "buy more" (**one ticker per
  account**). Reject if it would exceed **50 active positions**.
- **Buy more (existing):** added shares (>0) + buy price →
  `newAvgCost = (oldShares·oldAvg + addedShares·buyPrice) / (oldShares + addedShares)`,
  `shares += addedShares` (all `Decimal`).
- **Edit/delete:** fix typos; editing `shares` **to 0 deletes the position**; removing a
  sold-off position deletes it. If the edit leaves zero active positions, write the **zero
  `.portfolioValuation`** (see Refresher). No realized-gain tracking in v1.
- **Validation (trust boundary):** on add/buy-more, `shares > 0` (reject zero or negative)
  and `averageCost >= 0`; `emisoraSerie` must be non-empty and is uppercased on save. After
  any successful edit, the owner calls
  `viewModel.refresh()` so the snapshot/fingerprint recompute — "refresh required" is then
  derived from the fingerprint, not set as a flag.
- No ingest/parser changes.

---

## Portfolio mode (don't hijack existing investment accounts)

The codebase already has non-stock `.investment` accounts (CETES, CI Banco — see
`Detector.swift`, `AccountIdentity.swift`, `ManualAccountSheet.investmentMetadataRows`).
A CETES account that already carries statements/transactions/balance snapshots must not
enter incompatible portfolio semantics.

- **First-position creation is gated (blocker 1 — emptied-portfolio restart).** "Add stock
  positions" is enabled on a `.investment` account when **all** of:
  (1) no statements, (2) no transactions, and (3) **every** existing balance snapshot is
  `.portfolioValuation` (an emptied portfolio retains only valuation snapshots, which are
  compatible) — **or** the account already contains stock positions. A `.manualOpening` /
  `.manualAdjustment` snapshot (the kind a CETES/CI Banco account carries) blocks conversion.
  Otherwise the action is disabled with guidance to create a separate brokerage account.
  This both stops accidental conversion of in-use accounts **and** lets an emptied stock
  portfolio be restarted.
- **Portfolio mode (UI only) = positions currently exist** (active `shares > 0` rows), **not**
  "a valuation ever existed." The portfolio-specific summary + positions table render **only
  while the account has active positions**. **Note:** the authoritative-valuation resolver
  rule is NOT gated on portfolio mode — see the resolver change (it is unconditional on
  anchor kind, so emptied-portfolio history stays correct).
- **Deleting the final position returns the UI to normal investment behavior.** When the
  last active position is removed, write the zero `.portfolioValuation` (retires phantom
  value), then the account leaves portfolio mode — the UI resumes the normal asset dashboard.
  **Historical `.portfolioValuation` snapshots are retained** (they still anchor Net Worth
  history honestly and remain authoritative in the resolver); they just no longer trigger
  portfolio UI while no positions remain.

---

## Dashboard display & data flow — valuation-vs-holdings semantics

**Data flow (blocker 4 — `AssetAccountDashboard` can't fetch/edit/refresh today):**
`AssetAccountDashboard` is constructed with only an immutable `AssetAccountSnapshot` + an
`onTransactionTap` closure (`DashboardView.swift:300-303`). It has no view-model access and
cannot fetch, edit, or refresh. Therefore:

- **`AssetAccountSnapshot` gains optional value-type portfolio data** — a plain `struct
  PortfolioViewData`: `inPortfolioMode` (positions currently exist), the resolved valuation
  `amount` + `sourceDate` ("Valued as of …"), `sourceSnapshotKind` (provenance, blocker 1),
  `holdingsFingerprintMatches` (current vs. the selected valuation's fingerprint → drives
  refresh-required + growth availability), `totalInvested`, `totalGrowth` (or nil),
  `isPartialOrStale`, and an array of value-type position rows `[PositionRow]`
  (ticker/name/shares/avgCost/lastPrice/lastPriceAt/value/growthOrNil). **No live
  `StockPosition` `@Model` objects in the snapshot** — only snapshots of their fields. The
  fingerprint match is computed in the view model from the resolution's provenance, not
  stored on the snapshot.
- **`DashboardView` owns the edit sheet and the refresh action**, passing closures down to
  `AssetAccountDashboard` exactly as it already does for `LiabilityAccountDashboard`
  (`onEditPaymentDetails`, lines 304-315) — add `onRefreshPrices` and `onEditPositions`.
- **Successful edits/refreshes call `viewModel.refresh()`**, which rebuilds the
  `AssetAccountSnapshot` (incl. recomputing the fingerprint comparison) — the dashboard
  never mutates state directly.
- **Refresh progress / errors live in local `AssetAccountDashboard` `@State`** around its
  `onRefreshPrices` async callback (a spinner while fetching, a one-line error/partial banner
  after) — no new global state, no view-model plumbing beyond the existing `refresh()`.

**Semantics:**

- **Summary uses the resolved snapshot for the selected period.** When the resolved source
  is a `.portfolioValuation`, label it **"Valued as of {snapshot date}"** — the amount the
  resolver returns verbatim for the effective date (authoritative rule, no roll-forward).
  **For dates before the first valuation (no `.portfolioValuation` anchor exists for that
  period), show "No portfolio valuation for this period"** — not "Valued as of" with a stale
  or zero value. Historical-period-correct: an older period with a matching anchor shows
  that period's valuation.
- **"Holdings changed — refresh required":** derived from the fingerprint (via provenance) —
  when current holdings' fingerprint ≠ the selected valuation's fingerprint, show the
  affordance and **total growth is unavailable**. Clears after the next complete refresh
  writes a matching fingerprint. If the resolved source is **not** a `.portfolioValuation`
  (e.g. a statement or other snapshot is latest), growth is also unavailable for that period.
- **Positions table is always latest holdings + latest cached quotes**, labeled **"Latest
  positions / quotes"** — cannot reconcile to a historical period. Per-position growth uses
  each row's `lastPrice` vs `averageCost` (undefined when `averageCost == 0`).
- **Total invested** (Σ active shares·avgCost) is always live and independent of valuation.
- **Add Transaction / Add Balance hidden while in portfolio mode** (active positions exist),
  since manual entries would collide with the authoritative valuation. (Recording a
  contribution is a holdings edit / buy-more, not a free-floating transaction.)
- **Headline metric = total growth vs cost basis**, not the day-over-day Balance Change
  card, not DataBursatil's intraday `c`.
- `includeInNetWorth = true` / `includeInCashFlow = false` already default correctly.

---

## Persistence-safety coverage (first-class — release-blocking if missed)

Adding `StockPosition` touches these existing seams (all verified to exist):

1. **Schema: freeze V2, add frozen V3** — `FinanceTracker/App/AppSchema.swift`:
   - **Freeze V2:** replace `FinanceTrackerSchemaV2.models { AppSchema.modelTypes }`
     (lines 214-217) with an **explicit 9-model literal** identical to V1's (lines 6-18).
     This stops V2 from silently tracking future `AppSchema.modelTypes` changes.
   - **Add V3:** new `FinanceTrackerSchemaV3: VersionedSchema` with
     `versionIdentifier = Schema.Version(0, 6, 0)` and an **explicit 10-model literal**
     (the 9 + `StockPosition.self`) — NOT `AppSchema.modelTypes`.
   - `AppSchema.modelTypes` (lines 321-333) gains `StockPosition.self` (this is the
     live/current list used by `makeContainer`).
   - `FinanceTrackerMigrationPlan.schemas` (lines 220-222) adds V3; `stages` (224-226) adds
     a `migrateV2toV3` stage. **Use `MigrationStage.lightweight`** (new model, no existing
     row transforms) — switch to `MigrationStage.custom` only if the migration test proves
     lightweight is unsupported for this change.
2. **`.ftbackup` — bump schema to 3, keep back-compat** —
   `FinanceTracker/Features/Backup/BackupArchive.swift` + `BackupModels.swift`:
   - `private static let schemaVersion = 3` (line 14).
   - Restore allow-list accepts **1, 2, and 3** as an explicit set — change line 107 to
     `[1, 2, 3].contains(manifest.schemaVersion)` (mirrors the existing explicit
     `== 1 || == schemaVersion` style; do not use `<=`, which would silently accept unknown
     future lower versions).
   - `StockPositionSnapshot` Codable struct + `init(_ snap:)` / `apply(_ snap:)`.
   - Export: `writeJSON("StockPosition", …)`.
   - **Restore — version-conditional loader (NOT blanket `loadOptionalJSON`):**
     `loadOptionalJSON` for **v1/v2** backups (the file legitimately doesn't exist →
     positions default to `[]`), but for **v3** backups `StockPosition.json` is
     **required** via `loadJSON` and its absence is a restore error. (Blanket optional
     would silently accept a damaged/truncated v3 backup as "zero positions.")
   - **`resolveOrInsertStockPosition` — field-selective merge (blocker 3).** Unlike the
     other models' uniform whole-row `apply()` by `lastModifiedAt`, StockPosition merge
     splits the fields: **holding fields** (`emisoraSerie`, `name`, `shares`,
     `averageCost`) are taken from the row with the newer `lastModifiedAt`; **cached-quote
     fields** (`lastPrice`, `lastPriceAt`) are taken independently from whichever side has
     the newer `lastPriceAt`. This prevents a backup row whose only freshness is a newer
     quote stamp from overwriting newer shares/cost. `// ponytail: StockPosition merge is
     field-selective by design — do NOT normalize it back to whole-row apply().`
   - Token is Keychain-only → not in backup (correct by construction).
3. **`AppDataResetService`** — `Utilities/AppDataResetService.swift`: add `StockPosition.self`
   to `allModelTypesInDeleteOrder` (before `Account.self`) **and** to the verification
   count check (lines 101-118).
4. **`AccountDeletionService`** — `Features/Settings/AccountDeletionService.swift`: add
   `stockPositions` to `LinkedObjects` + a `fetchStockPositions` helper (by `accountId`,
   matching the existing `fetchBalanceSnapshots` pattern) + a delete loop, and a
   `stockPositionCount` to `DeletionPreview` (drives the confirmation UI). Valuation
   `AccountBalanceSnapshot`s are already cascaded by the existing snapshot fetch — no extra
   work.
5. **Tests — keep store migration and backup restoration separate** (round-2 blocker 2):
   extend existing end-to-end suites (do **not** create a new isolated `@MainActor` suite —
   project memory: a new isolated suite crashes on launch; add `@Test` to existing suites):
   - **Store migration test:** a V2 store on disk opens and migrates to V3 under the new
     plan (separate from any backup file).
   - **Backup restoration tests:** (a) a **v3 backup** round-trips StockPosition incl.
     `mergeKeepingNewer`; (b) a **v1/v2 backup (no StockPosition file)** restores cleanly
     under schema 3 with zero positions; (c) a **v3 backup with `StockPosition.json`
     missing fails to restore** (proves it's required, not silently zeroed).
   - **Quote-vs-holdings merge conflict test (blocker 3):** local row has newer
     `lastModifiedAt` (recent shares/cost edit) but older `lastPriceAt`; backup row has
     older `lastModifiedAt` but newer `lastPriceAt`. After `mergeKeepingNewer`, result keeps
     the local shares/cost **and** the newer quote — proving the merge is field-selective,
     not whole-row.
   - **Resolution-provenance test (blocker 1):** resolving an account whose latest anchor is
     a `.portfolioValuation` returns `sourceSnapshotKind == .portfolioValuation` + the
     fingerprint from `sourceSnapshotNote`; when the latest anchor is a statement or other
     snapshot, `sourceSnapshotKind` is not `.portfolioValuation` (and growth is unavailable).
   - **Authoritative-valuation resolver test:** after a `.portfolioValuation` snapshot, a
     later manual transaction does **not** change the resolved market value (the deltas
     roll-forward is suppressed).
   - **Final-position deletion test:** deleting the last active position writes a zero
     `.portfolioValuation` and Net Worth drops to zero (no phantom value).
   - **Fingerprint mismatch test:** after a holdings edit, the current fingerprint ≠ the
     valuation fingerprint → total growth unavailable / "refresh required"; after refresh,
     they match → growth available.
   - `AppDataResetServiceTests` (verification count includes StockPosition);
     `AccountDeletionServiceTests` (cascade deletes positions, preview accurate).
   - Update `makeContainer()` schema arrays and `seedFullDataset()` in test helpers.
   - **Network client testability:** `DataBursatilClient` takes an injected transport
     (`URLSession` or a small `requesting` protocol) so tests fixture-feed responses
     without the network.
   - Run serial: `xcodebuild test … -parallel-testing-enabled NO`.
   - `xcodegen generate` after adding new Swift files.

---

## Release hygiene

- Add a release-visible entry to `CHANGELOG.md` (new Stocks Portfolio / investment-account
  positions feature; notes the schema V3 bump + backup v3).
- Add SwiftUI `#Preview` for the portfolio summary + positions table (using the value-type
  `PortfolioViewData`, not live models).

---

## Verification (end-to-end)

1. `xcodegen generate`, then build (`-scheme FinanceTracker build`).
2. **Gated provider validation** (above) produces a captured live-JSON fixture; client
   (injected transport) Codable + date formatter round-trip against it; JSON numbers →
   `Decimal` directly.
3. Unit/integration: refresher writes `.portfolioValuation` snapshot (with fingerprint)
   **only when every active ticker returned a usable quote in that fetch**; refresher does
   **not** touch `lastModifiedAt` on quote writes; on partial, prior snapshot retained +
   arrived per-position prices persisted + `partial` result; weighted-average-cost math;
   growth undefined at zero cost.
4. **Resolver (two changes):** (a) with a `.portfolioValuation` as latest anchor, resolved
   market value = snapshot amount verbatim even when a later transaction exists — and this
   holds **even after the portfolio is emptied** (rule is unconditional on anchor kind, not
   gated on live positions); (b) resolution provenance — `sourceSnapshotKind ==
   .portfolioValuation` + fingerprint in `sourceSnapshotNote` when the anchor is a portfolio
   valuation, and not otherwise. Earlier anchors / non-portfolio accounts unchanged.
5. Holdings-staleness: after an add/delete/shares edit, fingerprint mismatch (read via
   provenance) → "Valued as of {old date} · refresh required", total growth unavailable;
   after a complete refresh, fingerprints match, new total dated now. Deleting the last
   position → zero valuation, Net Worth zero (no phantom), account leaves portfolio mode.
6. **Portfolio mode + restart (blockers 1 & 2):** "Add stock positions" is **disabled** on a
   `.investment` account that has statements/transactions or a non-`.portfolioValuation`
   snapshot and no positions; **enabled** on an empty investment account, one with only
   `.portfolioValuation` snapshots (incl. an emptied portfolio), or one that already has
   positions. After deleting the last position, the UI resumes the normal asset dashboard,
   historical valuations are retained and remain authoritative, **and the first position can
   be re-added**. Add-Transaction/Add-Balance hidden in portfolio mode.
7. Historical period: selecting an older dashboard period with a `.portfolioValuation` shows
   that period's resolved valuation in the summary; selecting a period **before the first
   valuation** shows "No portfolio valuation for this period." The positions table always
   stays "Latest positions / quotes"; total growth available only if the resolved source is
   `.portfolioValuation` **and** its fingerprint matches current holdings.
   valuation in the summary while the positions table stays "Latest positions / quotes";
   total growth available only if the resolved source is `.portfolioValuation` **and** its
   fingerprint matches current holdings.
8. Persistence suite: v3 backup round-trips StockPosition + field-selective mergeKeepingNewer
   (quote-vs-holdings conflict keeps newer shares/cost AND newer quote); v1/v2 backup
   restores with zero positions; v3 backup missing `StockPosition.json` fails; reset deletes
   StockPosition; account cascade deletes positions + preview accurate; V2 store migrates
   to V3.
9. Manual: create an investment account, add 2-3 positions, paste token, Refresh →
   valuation dated now + growth update; confirm the portfolio total appears in consolidated
   Net Worth at the refresh timestamp (not smeared across history). Kill network
   mid-refresh → "Not priced yet"/stale subtitle, prior snapshot intact, no partial
   snapshot written.
10. All tests run serial and green before claiming done.

---

## Open questions already resolved with user

- Refresh→snapshot strictness: **all-or-nothing** — a `.portfolioValuation` snapshot is
  written only when every active ticker returned a usable quote **in that fetch**.
