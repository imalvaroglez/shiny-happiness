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

## Production App Isolation

The installed production app is `~/Applications/FinanceTracker.app`. Treat it and its real user data as off-limits during normal development and testing.

- Do **not** overwrite, delete, move, launch, smoke-test, debug, or otherwise operate on `~/Applications/FinanceTracker.app` unless the user explicitly asks for a production release/install/smoke-test action.
- Do **not** use the production app or production SwiftData store for parser, UI, backup, reset, migration, or ingest testing. Use Xcode build products, temporary app-support paths, in-memory containers, fixtures, or sandboxed test data instead.
- Before any requested action that may touch the production app or production data, require a fresh manual `.ftbackup` export or an explicit user confirmation that a current backup already exists.
- Experimental/dev builds must stay in Xcode DerivedData or another clearly non-production location and must not be copied over the production app without an explicit release step.

## Production Data Safety & Release Gates

Production financial data is sacred. Data loss, corruption, unintended rewrites, unsafe migrations, or silent resets are worse than shipping nothing. If a change is not clearly safe for production data, stop and ask before proceeding.

- Treat production data as read-only by default. Never use live production storage for development, parser work, UI testing, backup/restore experiments, reset testing, migrations, normalization, cleanup, or data repair.
- Run all experiments against mock data, seeded fixtures, in-memory SwiftData containers, temporary app-support paths, or a cloned copy restored from backup. Never experiment on the live source.
- Never auto-clean, normalize, repair, migrate, delete, reset, or rewrite user data unless the user explicitly requested that operation and the safety checks below are satisfied.
- Code defensively against missing, legacy, partial, duplicated, corrupted, or inconsistent data. Do not assume existing stores match the newest model or happy-path invariants.
- Schema changes must be backward-compatible by default. Do not delete existing fields without a deprecation phase. Destructive migrations are forbidden unless a full backup exists, a rollback plan exists, and data preservation is explicitly proven.
- Migrations must be idempotent, resumable, and fail safely without partial writes. If this cannot be guaranteed, block the release.
- Backups must be versioned, immutable once created, and include schema plus all user data: accounts, transactions, categories, rules, statements, pending imports, installment plans, metadata, and related records needed for deterministic restore.
- Restore must be tested and deterministic. Do not accept “backup exists” or “backup probably works” as proof; untested backups do not satisfy the release gate.
- Before any release, confirm a fresh, verifiable `.ftbackup` exists and its timestamp is later than the last data change. If this cannot be confirmed, do not release.
- A release is blocked unless all are true: latest backup confirmed, restore path reviewed/tested, no code path unintentionally deletes or rewrites existing data, existing user data loads after update, the app launches with real production data without errors, and there are no silent failures or resets.
- No feature, refactor, UX improvement, or speed goal outranks production data safety.

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

### Dashboard period, net worth, and chart semantics

Dashboard work must preserve a clear split between financial semantics and rendering semantics:

- Period selection resolves to one `DashboardPeriodContext`. Cards, charts, drill-downs, and breakdown sheets must use that context instead of recomputing local ranges.
- `dateRange` and `effectiveNetWorthDate` are the source of truth for filtering, totals, and balance resolution. `plotDomain`, bucket centers, grouped-bar layout, and hover state are rendering-only.
- Month uses the current calendar month to date with daily buckets. Quarter and Year use current calendar windows to date with monthly buckets. All uses all available non-future data. Custom uses the selected local-calendar range capped at today unless future data is explicitly supported.
- Income, expenses, interest, cash flow, and chart buckets must exclude transfers, credit-card payments, duplicate rows, and synthesized MSI original-purchase rows according to the existing dashboard filters.
- Net Worth is never a transaction sum. It is a point-in-time balance as of `effectiveNetWorthDate`, using historical snapshots or resolver reconstruction. The Net Worth card, final visible chart point, and breakdown total must match.
- Net Worth breakdown rows explain account balance provenance, not period activity. Wording must not imply that prior snapshots or reconstruction anchors are transactions inside the selected period.
- Cash Flow and Charges vs Payments are period-comparison charts, not date-scale charts. Render them through the shared grouped-period bar renderer: `All` skips inactive buckets; bounded Month/Quarter/Year/Custom trim inactive edges but preserve inactive buckets between active buckets as subtle zero placeholders.
- Sparse grouped-bar charts must stay compact and centered at wide dashboard widths. Do not allow a few active months to stretch across the full card. Hover should resolve to the nearest rendered group id and update only when the group changes.
- Net Worth and Balance charts remain date-based point-in-time line/area charts. Do not convert them to grouped bars.

### Fresh-start reset and SwiftData safety

`AppDataResetService` is the single owner of model deletion order. Normal reset uses object-level deletion (`fetch` + `context.delete(obj)`) so SwiftData relationship rules run; do not replace it with broad `context.delete(model:)` in the healthy reset path, because batch delete can violate cascade/nullify constraints in this model graph. `BackupArchive` should delegate to the same service instead of keeping a second deletion list.

Startup repair must avoid faulting corrupted `Transaction` rows. `DashboardView` startup order must remain: `AppDataResetService.repairIncompleteResetIfNeeded` → `SeedDataLoader.bootstrapIfNeeded` → `viewModel.configure(context:)`. Do not add eager dashboard refreshes before repair.

Do not add broad `@Query<Transaction>` to views that can appear when there are zero accounts. Gate transaction fetches on account existence first; a corrupted enum column such as `Transaction.source` can crash during materialization before app code can inspect the row. If SwiftData cannot repair a broken fresh-start store, `StoreFileResetService` quarantines `default.store`, `default.store-wal`, and `default.store-shm` under `Application Support/FinanceTracker/ResetBackups/` before the model container opens on the next launch.

### Bootstrap category repair order

`SeedDataLoader.bootstrapIfNeeded` runs repairs in this order — do not rearrange without updating `CategoryRepairTests`:

1. `buildExistingMap` — builds name→Category lookup, preferring active (non-deleted) categories.
2. `loadCategoriesIfNeeded` — inserts seed categories and subcategories that don't already exist.
3. `repairStaleCategoryKinds` — fixes legacy `Credit Card Payments` categories created with wrong `kind`, promotes to top-level, deduplicates.
4. `repairDuplicateActiveCategories` — canonicalizes any remaining duplicate active categories by deterministic sort `(normalizedCategoryName, kind, id)` where lowest UUID wins. Reassigns transactions, rules, and child categories to the canonical. Soft-deletes (`deletedAt = .now`) all duplicates. Runs in a loop until no duplicate groups remain; must be idempotent.
5. Rebuild `categoriesByName` after repair so `syncRules` sees the canonicalized map.
6. `syncRules` — links category rules to existing categories by name. **`syncRules` must not create categories**; it only links rules to categories already in the store.

### Category duplicate canonicalization

- `repairDuplicateActiveCategories` groups active categories by key `(parentID|kind|normalizedName)` and picks the canonical as the one with the lowest `id.uuidString`.
- Transactions (`tx.category`), rules (`rule.category`), and children (`child.parent`) pointing to a duplicate are reassigned to the canonical before soft-delete.
- The repair loop re-fetches on each iteration so SwiftData fault resolution stays consistent.
- Display guards in `SettingsView.displayCategories` and `CategoryPickerView.displayCategories` provide an additional safety net: they sort by `(name, kind, id)` and filter out same-key duplicates so the UI never shows duplicate rows even if the store is temporarily dirty. These are display-only; `SeedDataLoader` owns actual repair.

### Category UI constraints

- Subcategory creation is inline only (within the category list), never via a separate sheet.
- Parent category creation may use a sheet (e.g. the "New Category" modal in Settings).
- Category deletion blocks when children exist; user must move or delete children first. Confirmation dialogs explain what will happen.
- `CategoryPickerView` and `SettingsView` category sections use `displayCategories` to hide soft-deleted and duplicate rows from the rendered list.

### Chart rendering

- Cash Flow and Charges vs Payments bar charts use centered `BarMark(x:y:)` with explicit `.barWidth(...)`. Never use `BarMark(xStart:xEnd:y:)` horizontal interval marks for these period-comparison charts.
- Bar width scales by populated bucket count via `barWidth(for:bucketCount:)` so charts stay compact when data is sparse.
- Cash Flow trims the x-axis domain to the first and last populated bucket; inactive leading/trailing months are excluded.
- Net Worth and account Balance charts remain date-based line/area charts — never convert them to grouped bars.

### Focused test commands

```bash
# Category repair (stale kinds + duplicate canonicalization + idempotency)
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:FinanceTrackerTests/CategoryRepairTests

# Full serial suite
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests \
  -destination 'platform=macOS' -parallel-testing-enabled NO
```

### SwiftLint status

`initial-prompt.md` §14 references a SwiftLint rule to flag `Double`/`Float` in `FinanceTracker/Domain/`, but no `.swiftlint.yml` configuration file was found in the repository. A pre-commit hook in `.git/hooks/` may provide this check instead. If SwiftLint is intended, add and commit a `.swiftlint.yml` config; otherwise update `initial-prompt.md` to reflect the actual enforcement mechanism.

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

Dashboard calculation or rendering changes must include focused coverage for the data shape that drives the UI: selected period context, transaction filtering, bucket membership, point-in-time balance resolution, grouped-bar trimming, compact layout behavior, and hover/breakdown mapping back to the original bucket start. Add SwiftUI previews for meaningful visual states when the defect is visual: sparse All, dense Year, current Month, historical Custom, liability Charges vs Payments, and empty states.

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
- Release prep means: bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`, run `xcodegen generate`, run focused dashboard tests when dashboard behavior changed, run `DashboardSnapshotTests`, run the full serial suite, and run a Release build.
- Installing or smoke-testing the production app is a separate explicit step after release prep. It requires confirmation that a fresh, verifiable `.ftbackup` exists and is newer than the latest production data change.

### Release Hygiene

For any versioned release or release-candidate task, the work is not complete until:

1. `git status --short` has been reviewed.
2. All intended release changes are committed.
3. The commit is pushed to the active branch.
4. The final working tree is clean, except for explicitly documented unrelated user-owned dirty files.
5. The final response reports the commit hash, branch name, push status, and remaining dirty files, if any.

Do not claim a release is closed, done, or ready while intended release files remain uncommitted. Preserve unrelated dirty files, exclude them from the release commit, and report them clearly. If the release commit cannot be pushed, do not claim completion; report the reason and exact next step.
