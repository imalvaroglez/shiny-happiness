# Repository Guidelines

## Project Structure & Module Organization

`FinanceTracker/` contains the macOS SwiftUI application. Key areas:
- `App/` — `@main` entry, SwiftData `ModelContainer` setup.
- `Domain/` — SwiftData `@Model` classes (`Models/`), value objects (`ValueObjects/`), learning hooks (`Learning/`), and domain extensions (`Extensions/`).
- `Ingest/` — statement detection, parsing, normalization, deduplication, categorization, seed data, and the structural parser. Parsers live in `Ingest/Parsers/` with subdirectories `CSV/`, `PDF/`, and `Text/` (paste-text parsers like `PastedHsbc2NowParser`). JSON resources: `Ingest/SeedData/` and `Ingest/StructuralParser/Knowledge/`.
- `Features/` — SwiftUI screens: `Dashboard/`, `Statements/`, `Transactions/`, `Settings/`, `Backup/`, `Shared/`.
- `Utilities/` — shared helpers (Logger, Decimal+Money, Date+Period) plus persistence safety services such as `AppDataResetService` and `StoreFileResetService`.

`FinanceTrackerTests/` mirrors behavior by area: `ParserTests/`, `PipelineTests/`, `StructuralParserTests/`, `EndToEndTests/`, `IngestTests/`, `AnalyticsTests/`, `KnowledgeLoaderTests/`. Sample PDFs and paste inputs used by tests live in `samples/`. Architecture decisions are documented in `DECISIONS.md`; planned work lives in `specs/`.

No external dependencies — pure Apple frameworks (SwiftUI, SwiftData, Swift Charts, PDFKit).

## Build, Test, and Development Commands

- `xcodegen generate` regenerates `FinanceTracker.xcodeproj` from `project.yml`; **run after adding, moving, or deleting any Swift file**. Never edit `.xcodeproj` directly (AD-005).
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build` builds the app.
- `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' -parallel-testing-enabled NO` runs the full test suite serially. **Always pass `-parallel-testing-enabled NO`** — Swift Testing's parallel runner intermittently hangs on macOS PDFKit/Vision teardown. Serial runs finish in ~15s and are always green.
- `xcodebuild test ... -only-testing:FinanceTrackerTests/CategorizerTests` runs one test class.
- `open FinanceTracker.xcodeproj` opens the generated project in Xcode.

Deployment target is **macOS 26.0** (set in `project.yml`).

## Architecture

### Ingest pipeline — two import paths

**PDF / CSV imports:**
```
File URL → Detector → StructuralParser (preferred, knowledge-driven)
                      → legacy parser fallback (OpenbankMexicoParser, AmexMexicoParser)
                      → [RawTransaction]
                      → Normalizer → [Transaction] (linked to Account + Statement)
                      → Deduplicator (fuzzy match against existing)
                      → Categorizer (regex rules by priority)
                      → ModelContext.save()
                      → linkInstallmentPlans (MSI cuotas → InstallmentPlan)
```

`IngestPipeline.ingest(files:)` orchestrates: detect institution → try structural parse → fall back to legacy → normalize → deduplicate → categorize → persist.

**Paste-text imports (HSBC 2Now):**
```
Pasted text → Detector → PastedHsbc2NowParser → [RawTransaction] + [PendingImport]
```
`IngestPipeline.ingestPastedText(_:sourceLabel:)` handles this path. Lines the parser can't confidently decode become `PendingImport` rows — the user resolves them inline. Each resolution feeds `LearningHooks`.

### Key invariants

- **All monetary values are `Decimal`** — never `Double` or `Float` anywhere in `Domain/` (AD-007).
- **Parsers are account-agnostic** — `StatementParser.parse(data:)` returns `[RawTransaction]` only; account assignment happens in `Normalizer` (AD-008).
- **Liability balances stored signed-negative** — `Statement.closingBalance < 0` for credit cards so net worth is a plain sum across accounts (AD-010).
- **Transfers and credit-card payments excluded from cash flow** — `CategoryKind.transfer` and `.creditCardPayment` are filtered from income/expense/cash-flow totals.
- **Synthesized MSI original-purchase rows excluded from cash flow** — the cash impact lives in the monthly cuotas (AD-012).
- **`StructuralParser.init?()` returns `nil` if knowledge JSONs are missing** — always handle this nil case.
- **Statement dedup via SHA-256 hash** of source file bytes or pasted text, checked before any parsing.

### Concurrency

Swift 6 strict concurrency (`SWIFT_STRICT_CONCURRENCY = complete`). All ViewModels are `@MainActor`. `IngestPipeline` is `@MainActor` (uses `ModelContext`). Parsers are `Sendable` structs with `async` methods. **Never pass `@Model` objects into parsers** — cross actor boundaries with `Sendable` value types only.

### Backup

`.ftbackup` folder bundles under `~/Library/Application Support/FinanceTracker/Backups/`. `BackupScheduler` writes snapshots if >24h old, prunes to 7 daily / 4 weekly / 12 monthly. Two restore strategies: `replaceAll` and `mergeKeepingNewer`. Soft-delete via `Transaction.deletedAt`; deduplicator surfaces soft-deleted matches as `PendingImport` for manual review (AD-018).

### Manual ledger and balance resolution

Manual accounts use `Account.manuallyCreatedAt` to distinguish user-created accounts from import-created accounts. Opening balances and later corrections live in `AccountBalanceSnapshot`; do not fabricate `Statement` rows for manual balances. Manual transactions use `Transaction.source`, and paired transfers use a shared `transferGroupID` across the source and destination rows.

`AccountBalanceResolver` computes account balances from the latest imported statement or manual balance snapshot anchor, then rolls forward only later non-deleted, non-duplicate transactions. Asset accounts store positive balances; liabilities store debt as signed-negative balances, with payments reducing debt as positive transactions.

### Fresh-start reset and SwiftData safety

`AppDataResetService` is the single owner of model deletion order. Normal reset uses object-level deletion (`fetch` + `context.delete(obj)`) so SwiftData relationship rules run; do not replace it with broad `context.delete(model:)` in the healthy reset path, because batch delete can violate cascade/nullify constraints in this model graph. `BackupArchive` should delegate to the same service instead of keeping a second deletion list.

Startup repair must avoid faulting corrupted `Transaction` rows. `DashboardView` startup order must remain: `AppDataResetService.repairIncompleteResetIfNeeded` → `SeedDataLoader.bootstrapIfNeeded` → `viewModel.configure(context:)`. Do not add eager dashboard refreshes before repair.

Do not add broad `@Query<Transaction>` to views that can appear when there are zero accounts. Gate transaction fetches on account existence first; a corrupted enum column such as `Transaction.source` can crash during materialization before app code can inspect the row. If SwiftData cannot repair a broken fresh-start store, `StoreFileResetService` quarantines `default.store`, `default.store-wal`, and `default.store-shm` under `Application Support/FinanceTracker/ResetBackups/` before the model container opens on the next launch.

## Adding a New Parser

1. Create parser in `FinanceTracker/Ingest/Parsers/CSV/` (or `PDF/`/`Text/`), conform to `StatementParser`.
2. Add detection keywords in `Detector.swift`.
3. Register in `IngestPipeline.resolveLegacyParser(for:)`.
4. Add sample file to `samples/` and tests under `FinanceTrackerTests/ParserTests/`.
5. Run `xcodegen generate`.

## Coding Style & Naming Conventions

Use Swift 6 with strict concurrency. Keep ViewModels and SwiftData `ModelContext` work on `@MainActor`; keep parsers as `Sendable` structs with async parsing methods. Store money as `Decimal`; do not introduce `Double` or `Float` in `FinanceTracker/Domain/`. Follow existing Swift naming: types in `PascalCase`, methods/properties in `camelCase`, test files ending in `Tests.swift`.

## Testing Guidelines

Use XCTest-style unit and end-to-end tests under `FinanceTrackerTests/`. Add focused tests when changing parsers, normalization, categorization, dashboard snapshots, or backup behavior. Prefer real fixtures from `samples/` for statement parsing. Run the serial full-suite command before handing off changes that touch ingest, persistence, or shared domain logic.

Any change touching reset, SwiftData model deletion, dashboard startup, transaction fetching, or backup restore must run focused reset/dashboard coverage plus the serial full suite. Tests involving store-file reset must inject a temporary app-support path (for example via `StoreFileResetService.appSupportOverride`) and must never operate on real user data.

When using an in-memory SwiftData test container, keep the `ModelContainer` alive for the full test. Never write `let context = try makeContainer().mainContext`; the temporary container can be deallocated immediately, leaving `mainContext` invalid and causing SwiftData signal-trap crashes. Use `let container = try makeContainer(); let context = container.mainContext`.

## Commit & Pull Request Guidelines

Git history uses conventional commit prefixes such as `feat:`, `fix:`, `test:`, `docs:`, and `perf:`. Keep commits scoped and imperative, for example `test: add HSBC paste parser reconciliation cases`. Pull requests should include a short problem statement, implementation summary, test results, linked issues or specs, and screenshots for visible SwiftUI changes.

## Security & Configuration Tips

This is a private finance app. Do not commit personal statements, generated stores, secrets, or unredacted financial data. Keep entitlements and sandbox settings aligned with `project.yml`, especially user-selected file access for imports and backups.

## Release Notes & About Updates

- For every release-visible change, update `CHANGELOG.md` under `[Unreleased]`.
- When preparing a new version, update the `latestReleaseHighlights` array in `SettingsView` with 3–5 short user-facing bullets for that version.
- `CHANGELOG.md` is the detailed technical record for contributors. The About "What's New" copy is product-focused and non-technical.
- Internal-only, test-only, or refactor-only changes belong in `CHANGELOG.md` but not in About unless users will notice them.
- Do not ship a version bump unless both `CHANGELOG.md` and the About highlights have been reviewed.
