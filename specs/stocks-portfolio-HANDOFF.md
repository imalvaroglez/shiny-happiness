# Stocks Portfolio — Handoff to Álvaro (checksum fix + remaining tasks)

**Branch:** `feat/stocks-portfolio` (off `main`)
**Date:** 2026-06-25
**Status:** YOU ARE TAKING OVER. Implementation paused after a SwiftData migration crash.

---

## TL;DR

3 of 15 tasks are committed and reviewed. **Task 2 introduced a SwiftData runtime crash
("Duplicate version checksums across stages detected") that breaks the entire test suite.**
You (Álvaro) are fixing that yourself. Once the container boots again, the remaining 12 tasks
resume from the plan.

The working tree is **clean**. All work is committed.

---

## The blocker you're fixing

### Symptom
Every test run crashes at app bootstrap, before any test executes:

```
*** Terminating app due to uncaught exception 'NSInvalidArgumentException',
    reason: 'Duplicate version checksums across stages detected.'
  … NSStagedMigrationManager _findCurrentMigrationStageFromModelChecksum: …
  … FinanceTracker … AppSchema.makeContainer …
```

Reproduce:
```bash
cd /Users/imalvaroglez/Documents/GitHub/shiny-happiness
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests \
  -destination 'platform=macOS' -only-testing:FinanceTrackerTests/HoldingsFingerprintTests \
  -parallel-testing-enabled NO 2>&1 | grep -iE "error|crash|fatal|checksum|reason" | head
```
(Even a pure, no-SwiftData suite like `HoldingsFingerprintTests` crashes, because the app
host boots the SwiftData container before the test bundle connects.)

### What changed (commit `d86c03c`, Task 2)
`FinanceTracker/App/AppSchema.swift`:

1. `FinanceTrackerSchemaV2` was **frozen**: changed from
   `static var models: [any PersistentModel.Type] { AppSchema.modelTypes }`
   to an **explicit 9-model literal** referencing the live `Account.self`, `Transaction.self`, etc.
2. Added `FinanceTrackerSchemaV3` (`Schema.Version(0, 6, 0)`): explicit 10-model literal
   (the 9 + `StockPosition.self`).
3. Added `migrateV2toV3 = MigrationStage.lightweight(fromVersion: V2, toVersion: V3)`.
4. `FinanceTrackerMigrationPlan.stages` is now `[migrateV1toV2, migrateV2toV3]`.

Build **succeeds**; the crash is runtime-only, in the migration manager.

### Key facts about this codebase's schema wiring
- `FinanceTrackerSchemaV1` (`AppSchema.swift:4-212`) is frozen at 0.4.0 and defines its own
  **nested** `@Model` classes (`Account`, `Transaction`, …) *inside the enum* — these are
  genuinely distinct types from the app-wide live models.
- `FinanceTrackerSchemaV2` and `FinanceTrackerSchemaV3` (after Task 2) both reference the
  **same app-wide live model types** (`Account.self`, …) — they differ only by V3 also
  including `StockPosition.self`.
- `migrateV1toV2` is a `MigrationStage.custom` (runs `backfillAccountMetadata` /
  `backfillTransactionSemantics`). It worked before Task 2, when V2 was
  `{ AppSchema.modelTypes }`.

### My best diagnosis (not yet confirmed — verify before fixing)
SwiftData computes a `versionChecksum` per `VersionedSchema` from its model definitions.
"Duplicate version checksums across **stages**" means two stages' version checksums collide.
Most likely cause: **V1 ≡ V2 by checksum** — V1's nested frozen classes hash identically to
the live classes (stored properties match), so the V1→V2 and V2→V3 stages share the V2
checksum and the manager rejects them as duplicates.

> Before Task 2, V2 was `{ AppSchema.modelTypes }` and the plan worked. The change that
> likely introduced the duplicate is **freezing V2 to the explicit list** — but freezing V2
> is the whole architectural point (stop V2 silently tracking future `modelTypes`). So the
> fix should preserve the freeze.

### Things to try (in rough order of likelihood)
1. **Confirm the checksum collision** — does V1's checksum equal V2's? Print
   `FinanceTrackerSchemaV1.versionIdentifier` vs the resolved checksums. (A throwaway diag
   test was created and removed during the earlier attempt — you can recreate one.)
2. **The classic SwiftData gotcha:** a `VersionedSchema`'s checksum is derived from its
   model *definitions*. Because V2 and V3 reference the same *live types* (which evolve over
   time), V2 is not really "frozen" — its checksum drifts with the live code. The truly
   correct pattern is for each `VersionedSchema` to reference **frozen model definitions as
   they were at that version** (the way V1 uses nested classes). Options:
   - (a) Give V3 its own nested `StockPosition` (and have the live `StockPosition` be the
     "current" one) so V2 and V3 reference structurally distinct snapshots. But V2 still
     points at live types, so V1≡V2 may still collide.
   - (b) The real fix may be: **V2 must NOT reference live types either** — it needs frozen
     definitions like V1. That's a bigger change (nested classes for V2 mirroring the 0.5.0
     shape) but it's how SwiftData versioning is *meant* to work.
   - (c) Simpler stopgap if V1≡V2 is the collision: since V1→V2 is a `custom` stage that
     only backfills metadata, investigate whether the codebase ever actually had V1 stores
     in the wild (if not, dropping V1 and making V2 the baseline may be acceptable — but
     that loses migration for any existing user on 0.4.0). Get Álvaro's call on this.
3. Research current (2026) SwiftData behavior on this error — the API has evolved. Search
   the Apple forums / SwiftData docs for "Duplicate version checksums across stages".

### Constraints for the fix
- Don't change model definitions (`StockPosition` or others) — only the schema wiring in
  `AppSchema.swift`.
- Preserve the intent: V1 frozen (0.4.0), V2 frozen (0.5.0, 9 models), V3 adds StockPosition
  (0.6.0). If you conclude freezing V2 is fundamentally incompatible, document why with
  evidence and pick the least-bad alternative.
- Prefer `MigrationStage.lightweight` for V2→V3 (additive model). Switch to `.custom` only
  if genuinely required.
- Success criterion: `xcodebuild build` succeeds AND a test suite runs without the bootstrap
  crash (ideally a SwiftData-touching one like `BackupArchiveTests`).

### Once fixed
- Commit on `feat/stocks-portfolio` with a clear message (e.g.
  `fix(schema): resolve duplicate version-checksum migration crash`).
- Tell me (Claude) the SHA, and I'll: re-run T3's tests to confirm green, finish T3's
  spec + quality review, and resume T4.

---

## What's done (3 commits, reviewed)

| Commit | Task | What | Reviews |
| --- | --- | --- | --- |
| `f14398f` | T1 | `.portfolioValuation` snapshot kind | (trivial, skipped) |
| `d86c03c` | T2 | `StockPosition` model + froze V2 + V3 + lightweight stage | ✅ spec, ✅ quality (static only — **did not catch the runtime crash**) |
| `787dc25` | T3 | `HoldingsFingerprint` (locale-independent SHA-256) | code self-reviewed; **tests couldn't run due to the crash** |

> **Lesson for the rest of the work:** a successful `xcodebuild build` is NOT sufficient —
> the review gate passed on T2 because both reviewers only read the code statically. A task
> is only "done" when **a test actually runs** against it. Apply that bar to T4 onward.

---

## Remaining tasks (12) — full text in `specs/stocks-portfolio-plan.md`

Resume in this order. T7 depends on T8's `PortfolioService.activePositions`, so do T8 before T7.

- [ ] **Finish T3** (HoldingsFingerprint): once the crash is fixed, re-run
  `HoldingsFingerprintTests`, do spec + quality review, mark complete.
- [ ] **T4** — Resolver: authoritative `.portfolioValuation` short-circuit (no roll-forward,
  unconditional on kind) + `AccountBalanceResolution` provenance fields. TDD. (plan §Task 4)
- [ ] **T5** — `KeychainTokenStore` (Security framework; never in SwiftData/backup). (plan §Task 5)
- [ ] **T6** — `DataBursatilClient` (Sendable, injected transport, v2 `/cotizaciones` batched,
  Decimal decode, **no token in errors**). TDD. **Gated pre-req:** live `curl` with Álvaro's
  token to lock the Codable shape before finalizing. (plan §Task 6)
- [ ] **T8** — `PortfolioService` (CRUD, weighted-avg buy-more, portfolio-mode eligibility
  incl. emptied-portfolio restart, zero-snapshot on final delete). TDD. (plan §Task 8)
- [ ] **T7** — `PortfolioPriceRefresher` (@MainActor; writes lastPrice/lastPriceAt only —
  NOT lastModifiedAt; writes `.portfolioValuation` snapshot on full success). Depends on T8.
  (plan §Task 7)
- [ ] **T9** — `PortfolioViewData` + `PositionRow` value types (no live models). (plan §Task 9)
- [ ] **T10** — Backup: `StockPositionSnapshot`, `schemaVersion=3`, allow-list `{1,2,3}`,
  version-conditional loader, **field-selective** `resolveOrInsertStockPosition`. TDD.
  (plan §Task 10)
- [ ] **T11** — `AppDataResetService` + `AccountDeletionService` cover StockPosition. TDD.
  (plan §Task 11)
- [ ] **T12** — Dashboard ViewModel computes `PortfolioViewData` in `buildAsset`; add
  `portfolio: PortfolioViewData?` to `AssetAccountSnapshot`. (plan §Task 12)
- [ ] **T13** — `AssetAccountDashboard` renders portfolio summary + positions table;
  `onRefreshPrices`/`onEditPositions` closures; `DashboardView` owns sheet + refresh. (plan §Task 13)
- [ ] **T14** — `PositionsEditSheet` + `AddPositionSheet` + `PositionRowView`; Settings
  `SecureField` token UI; `ManualAccountSheet` eligibility-gated affordance. (plan §Task 14)
- [ ] **T15** — V2→V3 store migration test (confirm lightweight works); full serial test run;
  CHANGELOG entry. (plan §Task 15)

---

## Reference docs (all committed on `main` before the branch)
- **Spec (decision-complete, 5 review rounds):** `specs/stocks-portfolio.md`
- **Implementation plan (15 TDD tasks, file:line-grounded):** `specs/stocks-portfolio-plan.md`

## Standing instructions from Álvaro (apply to all remaining work)
1. **Never change the model** across subagents — keep every implementer/reviewer on the same model tier.
2. **Effort = ultra** at all times.

## Resume protocol
When you're ready to hand back: tell me the checksum-fix SHA (or that you fixed it). I'll
verify the suite runs, close out T3, and continue T4 → T15 via subagent-driven development
with the "a test must actually run" bar applied.
