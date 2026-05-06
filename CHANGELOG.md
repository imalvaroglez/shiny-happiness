# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

**Structural Parser (Commits A-D)**
- Knowledge JSON files: `header_vocabulary.json`, `date_patterns.json`, `amount_conventions.json` encoding patterns from Openbank and Amex Mexico PDFs
- `KnowledgeLoader.swift` — typed Swift wrappers (`HeaderVocabulary`, `DatePatterns`, `AmountConventions`) loading from JSON
- `SemanticNormalizer` — date parsing (DD/MM/YY, DD-MMM-YYYY, inline Spanish, multi-line `dd de\nMonth`), amount parsing (CR suffix, signed, comma thousands), year inference from statement context
- `ColumnDetector` — scans PDF text rows for header vocabulary matches, assigns column roles (date/description/amount/debit/credit/balance), detects table layout (grid vs flow), identifies amount conventions
- `StructuralParser` — integrates ColumnDetector + SemanticNormalizer, conforms to `StatementParser` protocol, produces `[RawTransaction]` from any PDF using structural detection
  - Flow table parsing: cell-by-cell state machine for Amex-style tables (date + description + amount + CR on same/adjacent rows)
  - Grid table parsing: column proximity-based cell role assignment for Openbank-style tables with separate columns
  - Wide header fallback: content-based parsing when all columns come from a single header cell (e.g. "Fecha Concepto Depósito Retiro Saldo")
  - Multi-page support: iterates all PDF pages, accumulates transactions, extracts statement context from first page
- `tryCombinedHeader` fix: requires at least one combined header pattern match (prevents false positives from generic keyword matches like "Fecha" in non-table rows)
- `findNextTable` fix: scans ahead from section start markers for actual column headers (handles cases like "Detalle de tus transacciones" followed by the real header row)
- 31 new tests (64 total, all passing): SemanticNormalizer (17), ColumnDetector (5), StructuralParser integration (9)

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
