# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

The end-to-end change workflow (request → verification → independent review → human approval → release → install → rollback) and the approval gates live in [`docs/LOOPS.md`](docs/LOOPS.md). For non-trivial changes, prefer an orchestrated multi-agent workflow: parallel read-only exploration, scoped implementation, and fresh-context independent review. See `docs/LOOPS.md` for role boundaries and approval gates.

## Build & Run

```bash
# Regenerate Xcode project after editing project.yml or adding new files
xcodegen generate

# Build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build

# Run all tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests \
  -destination 'platform=macOS' -parallel-testing-enabled NO
# Pass -parallel-testing-enabled NO. Swift Testing's parallel runner
# intermittently hangs on macOS PDFKit/Vision teardown for the
# StructuralParser / Openbank tests. Serial runs finish in ~15s and
# always green. If you have a reason to run in parallel, restart Xcode
# and the test agent first.

# Run a single test class
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests \
  -destination 'platform=macOS' -only-testing:FinanceTrackerTests/CategorizerTests
```

Run `xcodegen generate` after adding or moving Swift files — the `.xcodeproj` is derived from `project.yml`.

## Architecture

Native macOS app (Swift 6, SwiftUI, SwiftData, Swift Charts). No external dependencies.

### Ingest pipeline (file imports)

PDF / CSV imports flow through a two-stage parse strategy before being persisted:

1. **`StructuralParser`** (preferred) — institution-agnostic, knowledge-driven PDF parser. Loads three JSON files at runtime from the app bundle (`Knowledge/header_vocabulary.json`, `date_patterns.json`, `amount_conventions.json`). Uses PDFKit positional extraction to cluster text into rows/columns, then maps column roles (date, amount, description) to `RawTransaction`. Returns `nil` from `init?()` if knowledge JSONs are missing.

2. **Legacy parsers** (`OpenbankMexicoParser`, `AmexMexicoParser`) — institution-specific fallbacks. Used when `StructuralParser` produces zero transactions or is unavailable.

`IngestPipeline.ingest(files:)` orchestrates: detect institution → try structural parse → fall back to legacy → normalize → deduplicate → categorize → persist.

### Paste-text imports (HSBC 2Now)

Some issuers ship PDFs with custom fonts and no ToUnicode CMap; PDFKit returns empty strings and OCR is fragile on dense tables. Those imports go through a separate path:

- `IngestPipeline.ingestPastedText(_:sourceLabel:)` consumes raw text the user copies from the bank portal.
- `Detector.detectFromPastedText(_:)` classifies the issuer.
- `PastedHsbc2NowParser` parses the HSBC 2Now header (period, due date, balances, credit limit), the MSI table, and the per-card transaction sections. Sign-recovery hints from prior manual fixes are consulted before falling back to the strict regex.
- Lines the parser can't confidently decode become `PendingImport` rows attached to the same `Statement` — the user resolves them inline from the Transactions view. Each resolution feeds the learning hooks.

### Data flow

```
File URL  →  Detector  →  StructuralParser (or legacy)  →  [RawTransaction]
Pasted txt → Detector  →  PastedHsbc2NowParser           →  [RawTransaction] + [PendingImport]
                                                       ↓
                                                  Normalizer → [Transaction] (linked to Account + Statement)
                                                       ↓
                                                  Deduplicator (fuzzy match against existing)
                                                       ↓
                                                  Categorizer (regex rules by priority)
                                                       ↓
                                                  ModelContext.save()
                                                       ↓
                                                  linkInstallmentPlans (MSI cuotas → InstallmentPlan)
```

### Manual review + learning

- Editable `TransactionsView` lets the user fix any field on any row. Unresolved `PendingImport` rows surface as a "needs review" card above the table.
- `LearningHooks.recordCategorization` promotes a manual category assignment to a `CategoryRule(source: "user_correction", priority: 90)`.
- `LearningHooks.recordSignRecovery` records a `SignRecoveryHint` whenever a resolved pending row's raw text lacked an explicit `+/-` sign; the parser consults these hints on the next paste.

### Dashboard architecture

- `DashboardScope` selects what's rendered: `.consolidated` aggregates across every account; `.account(UUID)` zooms into one. Sidebar's Accounts section drives the scope.
- `DashboardViewModel` produces a typed `DashboardSnapshot` (`.consolidated | .asset | .liability | .empty`) from one canonical `DashboardPeriodContext`.
- Three view variants render the snapshot: `ConsolidatedDashboard`, `AssetAccountDashboard`, `LiabilityAccountDashboard`. They share chrome via `DashboardChrome.swift`.
- `BreakdownSheet` drills into every aggregate (summary tiles, cash-flow bars, net-worth points, donut sectors) so the user can see which rows produced a number.

Aggregation invariants:
- Transfers (`category?.kind == .transfer`) AND credit-card payments (`.creditCardPayment`) are excluded from income / expense / cash-flow totals.
- Synthesized "original purchase" MSI rows (where `installmentPlan != nil` and `amount == plan.originalAmount`) are excluded from cash flow — the cash impact lives in the monthly cuotas.
- Liability balances are stored signed-negative (`Statement.closingBalance < 0` for credit cards); consolidated net worth is a plain sum.
- `dateRange` and `effectiveNetWorthDate` are financial semantics. `plotDomain`, grouped-bar content width, bucket-center positions, and hover state are rendering semantics only.
- Net Worth is point-in-time, not period activity. The Net Worth card, final visible Net Worth chart point, and breakdown total must match the same effective date.
- Cash Flow and Charges vs Payments are compact grouped period-comparison charts. `All` skips inactive buckets; bounded periods trim inactive edges and preserve internal zero buckets as subtle placeholders. Sparse charts must remain centered and compact at wide desktop widths.
- Net Worth and Balance charts remain date-based line/area charts; do not convert them to grouped bars.

### Domain models (SwiftData `@Model`)

- `Account` — institution + type + currency + optional `creditLimit` + statement / payment day-of-month. Auto-created on first import (AD-003).
- `Transaction` — posted date, amount (`Decimal`), description, merchant, category link, optional `cardLast4` (titular vs supplementary), optional `installmentPlan`.
- `Statement` — SHA-256 hash of source file or pasted text (dedup guard), period, balances, plus credit-card extras (minimum payment, no-interest amount, due date, interest, fees, IVA).
- `Category` / `CategoryRule` — seeded from `SeedData/categories.json` + `category_rules.json`. `CategoryRule.source` distinguishes `"seed"` vs `"user_correction"`.
- `InstallmentPlan` — MSI tracking (Home Depot 02 de 12 …).
- `PendingImport` — line the parser couldn't confidently decode; linked to a Transaction once resolved.
- `SignRecoveryHint` — learned pattern→sign mapping consulted by the paste parser.

### Concurrency

Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`). All ViewModels are `@MainActor`. `IngestPipeline` is `@MainActor` (uses `ModelContext`). Parsers are `Sendable` structs doing work with `async` methods but no actor isolation. Data crossing actor boundaries must be `Sendable` — never pass `@Model` objects into parsers.

### Key invariants

- **All monetary values are `Decimal`** — never `Double` or `Float`, anywhere in `Domain/`.
- `StatementParser.parse(data:)` returns `[RawTransaction]` only — account assignment happens in `Normalizer`, not parsers (AD-008).
- `StructuralParser.init?()` returns `nil` if knowledge JSON bundle resources are missing — always handle this nil case.

### Backup architecture

- `.ftbackup` folder bundles under `~/Library/Application Support/FinanceTracker/Backups/`. Each bundle contains `Info.plist`, `manifest.json`, per-model JSON snapshots under `models/`, and verbatim copies of imported statement files under `statements/`.
- `BackupScheduler.runIfNeeded()` called from DashboardView's `.task` on launch. Writes a snapshot if the last one is >24h old, then prunes to retain 7 daily / 4 weekly / 12 monthly snapshots.
- `BackupArchive.export(to:from:)` and `BackupArchive.restore(from:into:strategy:)` are the I/O entry points. Two restore strategies: `replaceAll` (wipe + import) and `mergeKeepingNewer` (per-row `lastModifiedAt` comparison).
- Soft-delete via `Transaction.deletedAt`; "Recently Deleted" toggle in TransactionsView. Soft-deleted rows are included in exports.
- Deduplicator surfaces soft-deleted matches as `PendingImport` with "Matches a deleted transaction" reason and Restore/Keep-Deleted actions (AD-018).

## Adding a New Parser

1. Create `FinanceTracker/Ingest/Parsers/CSV/YourBankParser.swift`, conform to `StatementParser`.
2. Add detection keywords in `Detector.swift` (`detectPDF` or `detectCSV`).
3. Register in `IngestPipeline.resolveLegacyParser(for:)`.
4. Add sample PDF/CSV to `samples/` and tests under `FinanceTrackerTests/ParserTests/`.
5. Run `xcodegen generate`.

## Architectural Decisions

Full rationale in `DECISIONS.md`. Key points:

- SwiftData instead of SQLite/DuckDB until queries exceed 200ms at 50k+ transactions (AD-001).
- PDFKit positional extraction; Vision OCR deferred (AD-002). HSBC 2Now uses paste-text instead.
- Statement dedup via SHA-256 hash of the source (file bytes or pasted text), checked before any parsing.
- `project.yml` + XcodeGen; never edit `.xcodeproj` directly (AD-005).
- Manual review + learning over heuristics (AD-009). Liability balances stored signed-negative (AD-010). Supplementary cards as `cardLast4` not separate Accounts (AD-011). MSI: both original + monthly installments (AD-012). `SU PAGO GRACIAS SPEI` is `.creditCardPayment` and excluded from cash flow (AD-013). Manual fixes feed `CategoryRule` + `SignRecoveryHint` (AD-014). Soft-delete via `Transaction.deletedAt` (AD-015). Local backup primary durability, CloudKit deferred (AD-016). `findOrCreateAccount` never falls back when sectionNumber is supplied (AD-017). Deduplicator surfaces soft-deleted matches for manual review (AD-018).
