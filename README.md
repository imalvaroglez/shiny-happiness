# FinanceTracker

Native macOS personal finance tracker built with SwiftUI, SwiftData, and Swift Charts. Ingests bank account statements (PDF/CSV), categorizes transactions, and renders an analytics dashboard for spending, savings, and net worth.

## Requirements

- macOS 15.0+ (Sequoia)
- Apple Silicon (arm64)
- Xcode 16.0+
- XcodeGen 2.40+ (`brew install xcodegen`)

## Build & Run

```bash
# Generate Xcode project from project.yml
xcodegen generate

# Build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build

# Run tests
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS'

# Or open in Xcode
open FinanceTracker.xcodeproj
```

## How It Works

1. **Import** — Drop PDF bank statements onto the Import view (or browse files). The pipeline detects the institution, extracts transactions, and persists them to SwiftData.
2. **Categorize** — Transactions are matched against 20 regex rules for common Mexican merchants (Uber, OXXO, Amazon, etc.). Uncategorized transactions can be manually assigned later.
3. **Dashboard** — Swift Charts render cash flow bars, net worth line, and spending donut. Time range picker filters by month/quarter/year.

## Supported Institutions

| Institution | Type | Format |
|---|---|---|
| Openbank Mexico | Debit | PDF |
| American Express Mexico | Credit card | PDF |

Additional institutions detected but not yet parsed: Banorte POR Ti, Mercado Pago, DiDi Cuenta, Skandia, CI Banco, Suburbia. Vision OCR for garbled PDFs (nu Mexico) is deferred to Phase 2.

## Adding a New Parser

1. Create `FinanceTracker/Ingest/Parsers/CSV/YourBankParser.swift`
2. Conform to `StatementParser` protocol:

```swift
struct YourBankParser: StatementParser {
    static var supportedIssuers: [String] { ["Your Bank Name"] }
    static var supportedFormats: [FileFormat] { [.pdf] }

    func parse(data: Data) async throws -> [RawTransaction] {
        // Extract transactions from data
        // Return array of RawTransaction
    }
}
```

3. Add detection keywords in `Detector.swift` (`detectPDF` or `detectCSV`)
4. Register the parser in `IngestPipeline.resolveParser(for:)`
5. Add tests in `FinanceTrackerTests/ParserTests/`
6. Run `xcodegen generate` to update the project

## Architecture

```
FinanceTracker/
  App/                    # @main entry, ModelContainer setup
  Domain/
    Models/               # SwiftData @Model classes (Account, Transaction, Statement, Category, CategoryRule)
    ValueObjects/         # AccountType, CategoryKind, DateRange, FileFormat, Money
  Ingest/
    Parsers/
      ParserProtocol.swift
      Detector.swift      # Keyword-based institution detection
      PDF/PDFTextExtractor.swift
      CSV/OpenbankMexicoParser.swift
      CSV/AmexMexicoParser.swift
    Pipeline/
      Normalizer.swift    # RawTransaction → Transaction
      Deduplicator.swift  # Fuzzy duplicate detection
      Categorizer.swift   # Regex rule matching
      IngestPipeline.swift  # Orchestrator
    SeedData/             # categories.json, category_rules.json
  Features/
    Dashboard/            # DashboardView + DashboardViewModel (Swift Charts)
    Statements/           # ImportView + ImportViewModel + IngestReport
  Utilities/              # Logger, Decimal+Money, Date+Period
```

**Key decisions** documented in `DECISIONS.md` (AD-001 through AD-008):
- SwiftData for queries (no SQLite/DuckDB until >200ms at 50k transactions)
- PDFKit positional extraction (Vision OCR deferred to Phase 2)
- Account auto-creation on import
- All money as `Decimal`, never `Double`/`Float`
- Swift 6 strict concurrency: `@MainActor` ViewModels, `Sendable` types

## Testing

31 tests across 6 suites, running against real PDF bank statements:

- **Openbank Mexico Parser** (6 tests) — detection, parsing, amounts, dates, transfers, formats
- **Amex Mexico Parser** (4 tests) — detection, crash safety, formats, protocol conformance
- **Normalizer** (2 tests) — single and batch normalization
- **Deduplicator** (6 tests) — exact match, substring, date tolerance, mixed scenarios
- **Categorizer** (6 tests) — regex match, priority, case insensitive, empty rules
- **Ingest Pipeline** (7 tests) — full import, encrypted PDF, statement dedup, account auto-creation

## License

Private project. All rights reserved.
