# Personal Finance Tracker — Native macOS Specification

## 1. Goal
A native macOS application for local-first personal finance tracking.
Ingests account statements, categorizes transactions, and renders an
analytics dashboard for spending, savings, and net worth.

## 2. Target Environment (HARD CONSTRAINT)
- Hardware: Apple M1 Pro
- OS: macOS 26.4.1 (Sequoia) — arm64 only
- Xcode: 16+ (latest stable)
- Minimum deployment target: macOS 15.0
- Distribution: Direct .app download, Developer ID signed + notarized
  (no App Store, no Rosetta, no Intel slice)

## 3. Tech Stack

| Layer            | Choice                          | Reason                                          |
|------------------|---------------------------------|-------------------------------------------------|
| Language         | Swift 6                         | Strict concurrency, full framework access       |
| UI framework     | SwiftUI                         | Declarative, native, M1-optimized               |
| Persistence      | SwiftData                       | @Model macros, async, CoreData-backed           |
| Analytics engine | DuckDB Swift package OR         | Columnar, arm64 native, sub-ms aggregates       |
|                  | in-process SQLite + custom SQL  | Fallback if DuckDB Swift pkg immature           |
| Charts           | Swift Charts                    | Native, animated, accessible, zero deps         |
| OCR              | Vision framework                | Neural Engine, zero install, best accuracy      |
| PDF rendering    | PDFKit                          | Native PDF parsing + text extraction            |
| Concurrency      | Swift Concurrency (actors)      | Structured, M1 efficiency-core aware            |
| Crypto/Security  | CryptoKit + Keychain            | Secure local storage, no third-party            |
| HTTP (FX/prices) | URLSession + async/await        | Native, no Alamofire needed                     |
| Testing          | Swift Testing (new) + XCTest   | First-party, fast                               |
| Package manager  | Swift Package Manager           | No CocoaPods/Carthage                           |

## 4. Application Architecture

MVVM + domain layer:

```
Sources/
  App/
    FinanceTrackerApp.swift      # @main, scene setup
    AppContainer.swift           # dependency injection root
  Domain/
    Models/                      # @Model classes (SwiftData)
      Account.swift
      Transaction.swift
      Statement.swift
      Holding.swift
      Category.swift
      CategoryRule.swift
      Budget.swift
    ValueObjects/
      Money.swift                # Decimal + currency, no floats
      DateRange.swift
  Features/
    Dashboard/
      DashboardView.swift
      DashboardViewModel.swift
    Transactions/
      TransactionListView.swift
      TransactionDetailView.swift
      CategoryPickerView.swift
    Statements/
      ImportView.swift           # drag-drop landing zone
      ImportViewModel.swift
      IngestReport.swift
    NetWorth/
      NetWorthView.swift
      NetWorthViewModel.swift
    Budgets/
      BudgetView.swift
    Settings/
      SettingsView.swift
  Ingest/
    Pipeline/
      IngestPipeline.swift       # orchestrator actor
      Detector.swift             # format/issuer detection
      Normalizer.swift
      Deduplicator.swift
      Categorizer.swift
    Parsers/
      ParserProtocol.swift       # protocol all parsers conform to
      CSV/
        CSVParser.swift
        BBVAMexicoParser.swift   # first reference impl
      PDF/
        PDFTextExtractor.swift   # PDFKit path
        VisionOCRExtractor.swift # Vision fallback
        TableReconstructor.swift # bounding-box row clustering
  Analytics/
    AnalyticsEngine.swift        # DuckDB or SQLite queries
    SpendingQueries.swift
    NetWorthQueries.swift
    CashFlowQueries.swift
  Services/
    FXService.swift              # exchange rate fetching + cache
    PriceService.swift           # equity/crypto prices
  Utilities/
    Decimal+Money.swift
    Date+Period.swift
    Logger.swift                 # os.log wrappers
Tests/
  IngestTests/
  AnalyticsTests/
  ParserTests/                   # fixture CSVs + PDFs per institution
```

## 5. Domain Model

All money stored as `Decimal` (never `Double` or `Float`).
SwiftData `@Model` classes:

- `Account`: id, institution, type (enum), currency, nickname,
  openedAt, closedAt
- `Transaction`: id, account, statement, postedAt, amount (Decimal),
  currency, descriptionRaw, merchantNormalized, category,
  fxRateToBase, isTransfer, isDuplicate
- `Statement`: id, account, periodStart, periodEnd,
  sourceFileHash (SHA-256), importedAt, ocrUsed
- `Holding`: id, account, symbol, quantity (Decimal),
  costBasis (Decimal), asOf
- `PriceSnapshot`: symbol, currency, price (Decimal), asOf
- `Category`: id, name, parent, kind (income/expense/transfer/investment)
- `CategoryRule`: id, patternRegex, merchantMatch, category, priority
- `Budget`: id, category, period, amountBase (Decimal)

Base currency: `MXN` (configurable in Settings, stored in UserDefaults).

## 6. Ingest Pipeline

Actor-based pipeline (each stage is isolated):

```swift
actor IngestPipeline {
  // 1. Dedupe by SHA-256 of file content
  // 2. Detect format + issuer
  // 3. Extract: PDFKit text layer, fall back to Vision OCR
  // 4. Parse into [RawTransaction]
  // 5. Normalize: dates, signs, merchants
  // 6. Dedupe against existing transactions
  // 7. Categorize via CategoryRule table
  // 8. Persist in a single ModelContext transaction
  // 9. Return IngestReport (new/duplicate/error/uncategorized counts)
}
```

Vision OCR configuration per page:
- `VNRecognizeTextRequest` with `.accurate` recognition level
- `recognitionLanguages = ["es-MX", "en-US"]`
- `usesLanguageCorrection = true`
- Capture `boundingBox` per observation for table reconstruction
- Cache results by `(fileHash, pageIndex)` to a local directory

PDFKit first: if extracted string length > 50 chars per page, use it.
Fall back to Vision if PDFKit yields sparse or no text.

## 7. Dashboard Views (MVP)

1. **Net Worth** — Swift Charts line chart, stacked area by account type,
   monthly buckets. Animate on appear.
2. **Cash Flow** — Bar chart, income vs expense per month + savings rate %.
3. **Spending Breakdown** — Pie/donut by category, tap to drill into subcategory.
   Swift Charts doesn't have sunburst natively — use a custom Shape or
   a two-level donut.
4. **Top Merchants** — Horizontal bar chart, configurable period.
5. **Asset Allocation** — Donut by asset class with holdings list below.
6. **Recent Transactions** — List with inline swipe-to-recategorize.
7. **Budget vs Actual** — Gauge or progress bars per category.

Use `NavigationSplitView` for sidebar + detail layout.
Sidebar: account list + section links.
Toolbar: date range picker, account filter, import button.

## 8. OCR & Table Parsing

For credit card PDFs with tabular layouts:

```swift
struct TableReconstructor {
  // Cluster VNRecognizedTextObservation by normalized Y coordinate
  // Tolerance: 1% of page height groups observations into the same row
  // Sort each row by X coordinate to get column order
  // Return [[String]] — array of rows, each row is array of cell strings
}
```

This reconstruction is the key to reliably parsing bank statement tables
without brittle regex on concatenated strings.

## 9. Security & Privacy

- All data in SwiftData store: `~/Library/Application Support/FinanceTracker/`
- Protected by FileVault (document this; no in-app encryption initially)
- Source files stored in `~/Documents/FinanceTracker/Statements/` — user-visible
- Optional: app-level PIN via `LocalAuthentication` (Face ID / Touch ID)
- No telemetry, no analytics, no network calls except FX/price APIs
- FX API key stored in Keychain, never in UserDefaults or bundled plist
- App bound entitlements: `com.apple.security.files.user-selected.read-write`
  and network client only

## 10. Performance Targets (M1 Pro)

- App cold launch to interactive dashboard: < 1.5s
- Statement import of 5k-row CSV: < 1s
- Vision OCR per page: < 500ms
- Dashboard chart render with 50k transactions: < 200ms
- Memory ceiling normal use: < 200 MB
- Use `TaskGroup` for parallel page OCR
- Analytics queries run on a background actor, never block main actor

## 11. Parser Protocol

```swift
protocol StatementParser {
  static var supportedIssuers: [String] { get }
  static var supportedFormats: [FileFormat] { get }
  func parse(data: Data, account: Account) async throws -> [RawTransaction]
}
```

Each parser ships with:
- Fixture file (CSV or PDF) in `Tests/Fixtures/`
- Parametrized Swift Testing test covering happy path + edge cases
- A `README` explaining the format quirks of that institution

## 12. Out of Scope (v1)

- iOS / iPadOS (use same SwiftData store later via CloudKit sync)
- Bank API integrations (Plaid, Belvo, BBVA Open Banking)
- Real-time price streaming
- Tax reporting
- Multi-user
- Widgets / Menu Bar extra (add later trivially)

## 13. Phase 1 Deliverables

1. Xcode project scaffold with SPM dependencies, folder structure,
   SwiftData schema + first migration.
2. Domain models fully defined.
3. `BBVAMexicoParser` (or whichever institution you have a sample from)
   as the reference CSV parser with tests.
4. Ingest pipeline end-to-end wired to a placeholder UI showing IngestReport.
5. Dashboard with Net Worth + Cash Flow charts pulling from SwiftData.
6. README: setup, how to add a new parser, how to run tests.

## 14. Working Agreement for the Agent

- Ask before adding any SPM dependency not listed in §3.
- Prefer Apple frameworks over third-party packages.
- Never use Double or Float for money. A SwiftLint rule should flag this.
- Every parser ships with fixtures and tests.
- Commit in logical units; each commit must build and pass tests.
- Surface architectural decisions as comments in a `DECISIONS.md`.
- Use `os.log` with subsystem/category for all logging — no print().
- All ViewModels must be `@MainActor`. All heavy work on background actors.