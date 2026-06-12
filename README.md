# FinanceTracker

Native macOS personal finance tracker built with SwiftUI, SwiftData, Swift Charts, PDFKit, and a small custom chart layer for dashboard period comparisons. It imports bank statements, categorizes transactions, tracks account balances, and gives period-aware views of cash flow, net worth, spending, and liability activity.

## Requirements

- macOS 26.0+
- Apple Silicon (arm64)
- Xcode 26.0+
- XcodeGen 2.40+ (`brew install xcodegen`)

No external runtime dependencies are required.

## Build, Test, And Run

```bash
# Regenerate the Xcode project after adding/moving/removing Swift files
# or after editing project.yml.
xcodegen generate

# Debug build. This produces "FinanceTracker Dev" with a separate bundle id.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build

# Full serial test suite. Always keep parallel testing disabled.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests \
  -destination 'platform=macOS' -parallel-testing-enabled NO

# Release build used during release prep.
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker \
  -configuration Release build

# Or open in Xcode.
open FinanceTracker.xcodeproj
```

The Debug configuration installs as `FinanceTracker Dev` with bundle id `com.financeTracker.app.dev`. The Release configuration builds the production app name and bundle id. Keep development and testing in the dev build unless you are explicitly doing a production release.

## Production Data Safety

The installed production app is `~/Applications/FinanceTracker.app`, and production financial data is treated as read-only during normal development.

- Do not launch, overwrite, smoke-test, or debug the production app during ordinary development.
- Use in-memory containers, fixtures, DerivedData build products, or temporary app-support paths for tests and experiments.
- Before a release install or production smoke test, create or confirm a fresh `.ftbackup` that is newer than the latest production data change.
- Schema or persistence changes must be backward-compatible, idempotent, and covered by focused tests plus the full serial suite.

## How It Works

1. **Import** — PDF/CSV files go through institution detection, the knowledge-driven structural parser, legacy parser fallback when needed, normalization, deduplication, categorization, and SwiftData persistence. HSBC 2Now paste-text imports have a dedicated parser for bank-portal copied text.
2. **Review and learn** — Transactions can be edited manually. Pending import rows surface when a parser cannot confidently recover a transaction. User fixes feed category rules and sign-recovery hints.
3. **Dashboard** — Overview and account dashboards resolve a single selected period context, then render summary cards, compact grouped-bar cash-flow comparisons, point-in-time net worth or balance charts, category spending, source statements, and recent transactions.
4. **Category repair** — On bootstrap, `SeedDataLoader` repairs stale category kinds (e.g. old `.transfer` credit-card-payment categories) and canonicalizes duplicate active categories by deterministic UUID sort, reassigning transactions, rules, and children before soft-deleting duplicates. Category picker and settings views defensively hide any remaining duplicates from display.
5. **Back up and restore** — `.ftbackup` folder bundles contain schema metadata, model snapshots, and copied statement files. Restore supports replace-all and merge-keeping-newer strategies.

## Dashboard Semantics

The dashboard is built around one canonical `DashboardPeriodContext` for Month, Quarter, Year, All, and Custom. Cards, charts, and breakdown sheets use that same context so numbers and visuals do not drift.

- **Month**: current calendar month to date, daily buckets.
- **Quarter**: current calendar quarter to date, monthly buckets.
- **Year**: current calendar year to date, monthly buckets.
- **All**: all available non-future financial data.
- **Custom**: selected local-calendar range, capped at today unless future data is explicitly supported.

Income, expenses, interest, and cash-flow charts filter transactions inside the selected date range. Transfers, credit-card payments, duplicates, and synthesized MSI original-purchase rows are excluded from cash flow.

Net Worth is point-in-time, not period activity. It is assets minus liabilities as of the selected effective date, using the latest available balance snapshot or balance reconstruction. The Net Worth card, final Net Worth chart point, and Net Worth breakdown total are expected to match.

Cash Flow and Charges vs Payments are compact grouped period-comparison charts. Sparse `All` views skip inactive buckets; bounded periods trim inactive edges while preserving internal zero buckets as subtle placeholders. Net Worth and account Balance remain date-based line/area charts.

## Supported Import Paths

| Institution / Source | Type | Format | Notes |
|---|---|---|---|
| Openbank Mexico | Debit / savings sections | PDF | Structural parser extracts multi-account sections and balances. |
| American Express Mexico | Credit card | PDF | Structural parser extracts transactions and payment metadata. |
| HSBC 2Now | Credit card | Pasted text | Handles primary/supplementary cards, MSI rows, payments, and pending-review fallbacks. |
| Banamex / other known layouts | Mixed | PDF | Structural-parser knowledge and tests cover several layouts; unsupported files fail safely. |

Additional institutions and layout refinements live in `specs/` and the parser tests.

## Architecture

```
FinanceTracker/
  App/                    # @main entry and SwiftData ModelContainer setup
  Domain/
    Models/               # SwiftData @Model classes
    Services/             # AccountBalanceResolver and domain services
    ValueObjects/         # AccountType, CategoryKind, DateRange, Money, etc.
    Learning/             # LearningHooks
  Ingest/
    Parsers/              # Detector, parser protocols, PDF/CSV/Text parsers
    Pipeline/             # Normalizer, Deduplicator, Categorizer, IngestPipeline
    SeedData/             # Seed categories and rules
    StructuralParser/     # Knowledge-driven PDF table parser
  Features/
    Dashboard/            # Period resolver, snapshots, dashboards, breakdowns, charts
    Statements/           # Import and paste flows
    Transactions/         # Ledger, editing, pending review
    Settings/             # Backup/restore, categories, account management, About
    Backup/               # BackupArchive and BackupScheduler
    Shared/               # Reusable UI components
  Utilities/              # Logger, Decimal and Date helpers, reset/store safety
```

Key invariants:

- Money is stored and calculated as `Decimal`.
- Parsers return account-agnostic `RawTransaction` values; account assignment happens in normalization.
- Liability balances are signed-negative so consolidated net worth is a plain sum.
- Swift 6 strict concurrency is enabled. ViewModels and SwiftData context work stay on the main actor; parser value types are `Sendable`.
- Statement deduplication uses SHA-256 hashes of file bytes or pasted text before parsing.

## Testing

The suite uses real fixtures and in-memory SwiftData containers. Always run serially with `-parallel-testing-enabled NO`; parallel test runs can hang on macOS PDFKit/Vision teardown.

Useful focused targets:

```bash
# Dashboard period, net worth, grouped bar rendering data
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:FinanceTrackerTests/DashboardPeriodFilteringTests

# Dashboard snapshots and liability fixtures
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -only-testing:FinanceTrackerTests/DashboardSnapshotTests
```

The full suite currently covers dashboard calculations and rendering data, backup/restore, reset safety, manual ledger flows, parsers, ingest, categorization, structural parser knowledge, source-file tracking, and payment metadata.

## Release Prep

For a user-visible release:

1. Update `CHANGELOG.md`.
2. Update `latestReleaseHighlights` in `SettingsView`.
3. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
4. Run `xcodegen generate`.
5. Run focused tests for touched areas, then the full serial suite.
6. Run a Release build.
7. Before installing or smoke-testing the production app, confirm a fresh `.ftbackup` exists and is newer than the latest production data change.

## License

Private project. All rights reserved.
