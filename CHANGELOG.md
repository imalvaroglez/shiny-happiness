# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Fixed

- **Delete All Data crash.** "Delete All Data" now removes all 9 model types in dependency-safe order (previously missed `PendingImport`, `InstallmentPlan`, and `SignRecoveryHint`), re-bootstraps seed categories and rules, and resets all UI state (sidebar, filters, sheets). `AppDataResetService` owns the deletion order as a single source of truth, used by both Settings and backup restore. Transaction category filters are now ID-based to avoid stale model references.
- **Fresh-start reset repair.** Startup repair now detects and cleans the "zero accounts but financial rows remain" state left by earlier partial resets. `resetAllData` verifies all model counts reach zero before restoring seed data, and surfaces a visible error if verification fails. Dashboard and Transactions defensively skip rendering when no accounts exist, preventing stale relationship access.

### Added

- **Manual accounts.** Users can now create debit, investment, credit-card, and loan accounts directly from Settings or the sidebar. Manual accounts store their creation provenance and always start with an opening balance snapshot.
- **Manual balance snapshots.** New `AccountBalanceSnapshot` model supports opening balances and later manual adjustments, letting users correct account balances without fabricating statement rows.
- **Manual transactions and transfers.** Transactions can now be added manually from the Transactions view. Paired transfers create linked source/destination transactions with a shared `transferGroupID` and consistent asset/liability signs.
- **Hybrid balance resolver.** Account dashboards now resolve balances from the latest imported statement or manual balance snapshot, then roll forward only later non-deleted, non-duplicate transactions.
- **Loan account support.** `AccountType.loan` routes through liability dashboards with loan-specific copy and hides credit-card-only payment due, utilization, source statement, and installment sections.
- **Source file tracking.** `Statement` now stores `sourceFileName` and `sourceArchivedPath` alongside the existing hash. Imported files are archived with content-addressed names (`<hash-prefix>_<original-name>.pdf`) to prevent same-name overwrites. Liability dashboards show a "Source Statements" section listing each statement's file name, period, import date, and metadata completeness status.
- **Category repair on bootstrap.** `SeedDataLoader` now repairs stale `Credit Card Payments` categories that were created with `kind = .transfer` in older stores. Repairs kind to `.creditCardPayment`, promotes to top-level, deduplicates if both old and new categories exist, and reassigns transactions/rules to the canonical.
- **Payment due card states.** The credit-card payment-due card now distinguishes "no statement" from "statement exists but due date unavailable" from "due date present but payment amounts missing." Missing amounts show "Unavailable" instead of hiding the row.

- **Settings: Account deletion.** Per-account destructive delete with confirmation alert showing data counts. `AccountDeletionService` manually cascades through statements, transactions, pending imports, and installment plans (all Account relationships use `.nullify` delete rules). Dashboard receives an `onAccountDeleted` callback that resets sidebar selection to Overview.
- **Settings: Category manager.** Inline "Categories" section grouped by `CategoryKind`, with add parent, add subcategory, and delete actions. `CategoryManagementActions` service handles validation (empty/duplicate names), subcategory→parent reassignment on delete, and parent-deletion blocking when children exist.
- **Category soft-delete.** `Category.deletedAt: Date?` for soft-delete. Categorizer, `IngestPipeline`, and `SeedDataLoader` all filter out rules pointing to nil or soft-deleted categories. `@Query<Category>` in picker and transactions view filters to active only. Seed bootstrap treats soft-deleted names as "exists" to prevent recreation.
- **Backup compatibility.** `CategorySnapshot.deletedAt` round-trips through backup export/restore. Optional field decodes as `nil` from old backups.
- **Per-account dashboards.** `DashboardScope` (`.consolidated | .account(UUID)`) dispatches to purpose-built `AssetAccountDashboard` (checking/savings) or `LiabilityAccountDashboard` (credit cards). Sidebar lists accounts with type-appropriate icons.
- **Interactive charts and drill-downs.** Hover tooltips on time-series charts. `BreakdownSheet` drills into every aggregate (income, expenses, interest, net worth, category spending) showing the rows behind each number.
- **Account display name.** `Account.displayName` prefers nickname, then `"<institution> ····<last4>"`, then institution name. Per-account editor in Settings: nickname, identity color, credit limit.
- **Data safety.** `lastModifiedAt` on all 8 `@Model` classes. `Transaction.deletedAt` soft-delete with "Recently Deleted" toggle. `.ftbackup` folder-bundle export/restore with `mergeKeepingNewer` and `replaceAll` strategies. Automatic backup scheduler (daily/weekly/monthly pruning).
- **Learning hooks.** `LearningHooks.recordCategorization` and `.recordSignRecovery` create idempotent rules from user corrections. Sign-recovery hints improve future paste-import accuracy.
- **HSBC 2Now paste import.** `PasteImportSheet` with live detection chip. `PastedHsbc2NowParser` extracts statement header, MSI table, and per-card transaction sections. Multi-HSBC account isolation via `sectionNumber`.
- **Editable transactions.** Inline date/description/amount editing via popover. `PendingReviewSection` for resolving parser ambiguities.
- **Transaction category editing.** Tap any row to open category picker → apply-to-similar flow. User corrections create `CategoryRule` with `source: "user_correction"`.
- **SPEI destination-specific categorization.** Rules for 8 destinations (Priority, 2now, Nu, TDC Explora, INVEX Volaris, BBVA 7777, Explora/BANAMEX, Moneypool). Unknown destinations fall to Uncategorized.
- **Custom date range picker.** From/To DatePickers for arbitrary dashboard periods.
- **Multi-account PDF parsing.** `StructuralParser.parseSections` detects account boundaries in multi-section PDFs (e.g., Openbank Débito + Apartados). Separate Account + Statement per section.
- **Net worth from statement balances.** `computeNetWorth` sums latest `closingBalance` per account. Time series anchored to actual statement data.
- **Structural parser.** Knowledge-driven PDF parsing: `ColumnDetector`, `SemanticNormalizer`, `LayoutFingerprint`/`LayoutStore`. Supports Openbank, Amex, Banorte, Suburbia, DiDi, CETES, Skandia.
- **Liquid Glass UI.** All opaque backgrounds replaced with `.glassEffect` materials. `MeshGradient` background for glass refraction.

### Changed

- **Manual transaction category picker.** Manual transaction creation now uses the same grouped category picker as transaction editing, filtered to income categories for income and expense categories for expenses/charges.
- **Import account matching protects manual accounts.** Imported statements attach to manually created accounts only when account/card numbers match. Numberless imports no longer attach to manual accounts by loose institution/type matching.
- **Liability payment computation is sign-based.** Credit-card dashboard totals and charges-vs-payments chart no longer exclude transactions by category kind. Positive amounts count as payments/credits regardless of whether categorized as transfer, credit-card payment, refund, or uncategorized. Consolidated cash flow still excludes both `.transfer` and `.creditCardPayment`.
- **Charges vs Payments chart legend.** Added explicit color-coded legend (Charges red, Payments & Credits green). Relabeled "Payments" to "Payments & Credits" in tooltip and totals.
- **Amex metadata extraction uses statement-summary semantics.** Gold Elite statements now parse the arithmetic summary row and credit summary directly. `closingBalance` represents total outstanding debt from credit limit minus available credit, while `paymentForNoInterest` stores the statement balance / saldo a pagar.
- **Transactions filter bar.** Account, category, and recently-deleted controls now live behind a compact Filters popover with active filter chips. Sorting is a separate icon menu without the extra "Sort" label.

- **Credit-card dashboard: removed Interest & Fees card.** Statement metadata preserved in snapshot/model; visual card removed for all credit-card types.
- **Category picker: removed inline creation.** Replaced with passive "Manage categories in Settings" hint. Creation now lives in the Settings category manager.
- **Spending donut uses vivid per-category colors.** Explicit color map (Food=orange, Transport=blue, etc.) replaces hash-based assignment.
- **Dashboard excludes all transfer/cash-flow categories.** Uses `category?.kind` to exclude `.transfer` and `.creditCardPayment` from income/expense aggregates.
- **Apply to Similar: review before applying.** Scrollable list of matching transactions with per-row checkboxes instead of simple count+confirm.
- **TransactionsView: native Table layout.** 4-column sortable Table replacing list view. Full `descriptionRaw` displayed.
- **GlassCard hover performance.** Static 35° stroke fading in on hover replaces `.repeatForever` rotation.
- **Drill-down completeness.** Snapshots carry full filtered transaction set (removed `prefix(20)` cap).
- **SeedDataLoader incremental sync.** Compares JSON subcategory names and rule patterns against existing DB, inserts only missing entries.

### Fixed

- **SwiftData invalidated account crash.** Dashboard account snapshots and account deletion confirmation state now capture value identities instead of retaining live `Account` models after deletion. Dashboard startup also avoids stale account/category relationship reads that could trap when SwiftData invalidates backing rows.
- **Credit-card payments hidden from liability dashboard.** Transfer-kind credit-card payments (e.g., Explora "Credit Card Payments" with kind `.transfer`) now appear in liability payment totals and charges-vs-payments chart. Root cause: category-kind filter excluded `.transfer` from liability aggregates.
- **Amex Gold Elite utilization understated.** Gold Elite no longer treats the previous payment amount as the statement balance. Re-importing the same PDF repairs stale non-nil metadata without duplicating transactions.
- **Amex Gold Elite due-date not parsed.** Date format `dd de MMMM yyyy` (e.g., "31 de Marzo 2026" without second "de") now parses correctly. Added regex alternative and DateFormatter entry.
- **Pago Mínimo collision with installments line.** Exact-colon parsing prevents "Pago mínimo mas meses sin intereses" from overriding the actual "Pago Mínimo" value.

- **Deduplicator requires exact same day.** Changed `abs(daysDiff) <= 1` to `daysDiff == 0`.
- **Category picker shows subcategories.** Switched from `cat.subcategories` (unreliably materialized) to filtering `@Query` results.
- **REGRESSION: SwiftData schema migration failure.** `CategoryRule` `matchCount` default caused store fallback to empty. Deleted incompatible store; fresh database created on next launch.
- **Volaris INVEX rule corrected.** SPEI to INVEX Volaris is a credit card payment, not a flight purchase.
- **Account deduplication.** `findOrCreateAccount` falls back to institution+type matching when account number doesn't match.
- **Category picker save flow.** Category saved immediately on selection; "Apply to Similar" presents after first sheet dismisses.
- **Interest earned $0.00 fix.** Removed `^...$` anchors from "Abono de intereses" rule.
- **Apartado deposit parsing.** Interest, ISR, and deposits now extracted from wide-header table cells with inline amounts.
- **Dashboard shows data on first import.** Date range changed from hardcoded 2020 start to `Date.distantPast`; default period changed to `.all`.
- **Import sheet dismiss.** Added Done button to paste-import sheet opened from floating button.
- **SeedDataLoader crash.** Replaced `Dictionary(uniqueKeysWithValues:)` with safe loop for duplicate category names.

### Removed

- **Interest & Fees card** from credit-card dashboards (data preserved in model).
- **Inline category creation** from `CategoryPickerView` (moved to Settings).
- All NSLog diagnostic calls from `StructuralParser` and `IngestPipeline`.

### Architectural decisions

- **AD-009..AD-014** Manual-review-first parser, signed liability balances, supplementary-card model, MSI handling, credit-card payment classification, learning hooks.
- **AD-015..AD-018** `Transaction.deletedAt` soft-delete, local `.ftbackup` bundles, `findOrCreateAccount` section-number isolation, deduplicator behavior with soft-deleted rows.
- **AD-019..AD-021** Account deletion as permanent purge with manual cascade, category soft-delete preventing seed recreation, categorizer rejection of nil/deleted-category rules.

## [0.2.0] - 2025-05-05

### Added

**Ingest Pipeline (Commit 6)**
- `Normalizer` — converts `RawTransaction` to SwiftData `Transaction` with Account/Statement relationships
- `Deduplicator` — fuzzy duplicate detection by (amount, date ±1 day, similar description)
- `Categorizer` — priority-sorted regex rule matching, assigns Category relationships
- `IngestPipeline` — `@MainActor` orchestrator: detect → parse → normalize → dedupe → categorize → persist
- SHA-256 statement hash deduplication prevents re-importing the same file
- Account auto-creation from `DetectionResult` with institution name lookup
- Encrypted PDF detection via `PDFDocument.isLocked`
- `StatementParser` protocol simplified: removed `Account` parameter (parsers are account-agnostic)
- 21 new tests (31 total, all passing): Normalizer, Deduplicator, Categorizer, IngestPipeline integration

**Import UI (Commit 7)**
- `ImportView` — drag-drop zone for PDF/CSV bank statements with visual feedback
- `ImportViewModel` — `@Observable`, `@MainActor`, orchestrates pipeline calls
- File browser via `fileImporter` (PDF + CSV content types)
- `IngestReport` results list with per-file status badges (new/duplicate/error)
- Summary stats (total new, duplicates, errors) with clear history
- Files copied to Application Support/FinanceTracker/Statements for archiving
- DashboardView sidebar links to ImportView

**Dashboard Queries + UI (Commits 8-9)**
- `DashboardViewModel` — aggregates monthly cash flow, net worth over time, spending by category, recent transactions
- `MonthlyCashFlow` — income vs expenses per month with savings rate
- `CategorySpending` — top spending categories with amounts
- `NetWorthPoint` — cumulative balance by month
- Time range picker: month, quarter, year, all
- Summary cards: income (green), expenses (red), net (blue)
- Swift Charts: cash flow bar chart, net worth line chart with area fill, spending donut chart
- Recent transactions list with merchant, date, amount, color-coded sign
- Empty state when no transactions imported
- In-memory aggregation (per AD-001: migrate to SQLite/DuckDB if >200ms at 50k transactions)

## [0.1.0] - 2025-05-05

### Added

**Project Scaffold**
- Xcode project generated via XcodeGen (`project.yml`) targeting macOS 15.0, arm64 only
- Swift 6 strict concurrency enabled (`SWIFT_STRICT_CONCURRENCY: complete`)
- App Sandbox with user-selected file read/write + network client entitlements
- Pre-commit hook rejecting `Double`/`Float` in `FinanceTracker/Domain/`
- `.gitignore` for Xcode, macOS, and SPM artifacts
- `DECISIONS.md` recording architectural decisions (AD-001 through AD-007)

**Domain Models (SwiftData)**
- `Account` — institution, type (checking/savings/creditCard/investment/wallet/retirement/other), currency, nickname, dates
- `Transaction` — account, statement, postedAt, amount (Decimal), currency, descriptionRaw, merchantNormalized, category, fxRateToBase, isTransfer, isDuplicate
- `Statement` — account, periodStart/End, sourceFileHash (SHA-256), importedAt, ocrUsed
- `Category` — name, parent (self-referencing), kind (income/expense/transfer/investment), subcategories
- `CategoryRule` — patternRegex, merchantMatch, category (relationship), priority
- Value objects: `Money` (Decimal + currency, never Double/Float), `DateRange`, `AccountType`, `CategoryKind`, `FileFormat`
- Utility extensions: `Decimal+Money` (parsing from Mexican currency strings), `Date+Period` (startOfMonth, yearMonth), `Logger` (os.log subsystem categories)
- `AppContainer` — dependency injection root with ModelContainer/ModelContext setup
- `Holding`, `PriceSnapshot`, `Budget` — deferred to Phase 2 (stub comments only)

**Parser Infrastructure**
- `StatementParser` protocol — `supportedIssuers`, `supportedFormats`, `parse(data:account:) async throws -> [RawTransaction]`
- `RawTransaction` — Sendable intermediate type (pre-persistence), id, postedAt, amount, currency, descriptionRaw, merchantNormalized, fxRateToBase, isTransfer
- `IngestReport` + `IngestError` — value types for pipeline result reporting (new/duplicate/error/uncategorized counts)
- `ParserError` enum — invalidData, encrypted, unsupportedFormat, parseFailure

**PDF Extraction**
- `PDFTextExtractor` — PDFKit-based positional text extraction using `selectionsByLine()` with CGRect bounds
- `extractRows(from:yTolerance:)` — clusters text blocks by Y-coordinate into table rows, sorts cells by X-coordinate
- `extractAllText(from:)` — full document text concatenation for line-by-line parsing

**Institution Detection**
- `Detector` — identifies issuer from PDF content via keyword heuristics
- `DetectionResult` — issuer, format, confidence score, suggestedAccountType
- Supported: Openbank Mexico (debit), American Express Mexico (credit card), Banorte POR Ti (credit card), Mercado Pago (wallet), DiDi Cuenta (savings), Skandia (retirement), CI Banco (investment), Suburbia (store credit card)
- Uses `PDFDocument.isLocked` (not `isEncrypted`) to correctly handle restricted-but-readable PDFs

**Parsers**
- `OpenbankMexicoParser` — parses Openbank Mexico debit account PDFs
  - Extracts transactions from multi-page tabular layout (Date | Concept | Deposit | Withdrawal | Balance)
  - Date format: `DD/MM/YY`
  - Handles SPEI transfers, internal transfers, traspasos
  - Merchant extraction from description text
  - Sign convention: deposits positive, withdrawals negative
  - 6/6 tests passing against real `202508.pdf` (12 pages)
- `AmexMexicoParser` — parses American Express Mexico credit card PDFs
  - Handles restricted-but-readable PDFs (isEncrypted=true, isLocked=false)
  - Spanish date parsing: `DD-MMM-YYYY` with month name translation (Ene→Jan, etc.)
  - Detail section detection via keyword triggers
  - 4/4 tests passing (detection, protocol conformance, crash-safety)

**Seed Data**
- `categories.json` — 14 top-level categories with subcategories (Food & Drink, Transport, Shopping, Entertainment, Bills & Utilities, Health, Home, Education, Transfers, Income, Investment, Fees & Charges, Travel, Subscriptions)
- `category_rules.json` — 20 regex rules for common Mexican merchants (Uber, DiDi, OXXO, Amazon, Mercado Pago, Walmart, Starbucks, Netflix, Spotify, Apple, Google, SPEI transfers, bank commissions, salary deposits, La Comer, 7-Eleven)
- `SeedDataLoader` — bootstraps categories and rules into SwiftData on first launch (idempotent, checks for existing categories)

**UI Shell**
- `FinanceTrackerApp` — @main with WindowGroup, SwiftData ModelContainer, NavigationSplitView layout
- `DashboardView` — sidebar with navigation links (Dashboard, Transactions, Import, Settings), triggers seed data bootstrap on appear
