# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

**Scroll performance — GlassCard hover refactor**
- `GlassCard`: replaced `.repeatForever` AngularGradient rotation with a static 35° stroke that fades in on hover (0.25s easeInOut). Multiple interactive cards no longer saturate the GPU during scroll.

**Drill-down completeness fix**
- `DashboardViewModel`: removed `Array(transactions.prefix(20))` from `buildConsolidated`, `buildAsset`, and `buildLiability`. Snapshots now carry the full filtered set so `BreakdownSheet` sees all matching rows for every aggregate (interest earned, income, expenses, category spending). Dashboard "Recent Transactions" panels already cap at `.prefix(10)` at the render site.
- New `DashboardSnapshotTests.interestDrilldownIsComplete` test asserting both row visibility and `totalInterestEarned` accuracy.

**Multi-HSBC account isolation**
- `IngestPipeline.findOrCreateAccount`: when `sectionNumber` is supplied and doesn't match an existing account, creates a new Account instead of falling through to the `(institution, type)` fallback. Closes the multi-HSBC merge bug where two physical card accounts were merged into one.
- `PastedHsbc2NowParser`: both titular and adicional sections now share the titular card's `last4` as `accountNumber`, so one Account is created per physical card (not per `cardLast4`).
- `StructuralParser.extractAccountNumber`: tightened to match only labeled account numbers (CLABE/Cuenta/No./contrato), avoiding false positives on random 4-digit numbers. Returns nil when no labeled number found, so Openbank accounts still merge via the `(institution, type)` fallback.
- `AccountIdentity`: deterministic hue offset (±20°) derived from `Account.id` so two same-institution accounts receive visibly distinct colors.
- New `MultiHSBCAccountTests` with 3 tests: two accounts remain distinct after two pastes, transactions don't cross accounts, identity colors differ.
- New fixture `samples/2026-05-08_HSBC_2Now_paste_accountB.txt` simulating a second HSBC 2Now account.

**Account.displayName + per-account editor**
- `Account.displayName` computed property: prefers user-set nickname, then `"<institution> ····<last4>"`, then institution name. Replaced every `.nickname` call site across dashboards, sidebar, breakdown sheet, and transactions table.
- `AccountSummary.displayName` replaces the old `nickname` field.
- `SettingsView`: accounts section now includes per-account nickname `TextField`, identity-color `ColorPicker` (round-trips through `Account.tintHex`), and credit-limit field (credit cards only).

**Data safety: lastModifiedAt + soft-delete + local backup**
- `lastModifiedAt: Date = Date.now` added to all 8 `@Model` classes. `PersistentModel.touch()` extension centralizes timestamp updates. Every mutation path (editable cells, pending-import resolution, learning hooks, apply-to-similar, installment plan updates) stamps the field before save.
- `Transaction.deletedAt: Date? = nil` for soft-delete. All `FetchDescriptor<Transaction>` filters default to `deletedAt == nil`. Context-menu delete sets `deletedAt = Date.now`. "Recently Deleted" toggle in Transactions toolbar swaps the `@Query` to show soft-deleted rows with a Restore action.
- `Deduplicator` returns `matchedDeleted` entries when an incoming row matches a soft-deleted transaction. The pipeline creates `PendingImport` rows with "Matches a deleted transaction" reason. `PendingReviewSection` shows Restore / Keep Deleted actions.
- `BackupArchive.export(to:from:)` writes a `.ftbackup` folder bundle (Info.plist + manifest.json with SHA-256 content hashes + per-model JSON snapshots + verbatim copies of imported statement files).
- `BackupArchive.restore(from:into:strategy:)` reads the bundle and materializes rows. Two strategies: `mergeKeepingNewer` (per-row `lastModifiedAt` comparison) and `replaceAll` (wipe-then-import).
- `BackupScheduler.runIfNeeded()` writes a snapshot on launch if the last one is >24h old, then prunes to 7 daily / 4 weekly / 12 monthly snapshots under `~/Library/Application Support/FinanceTracker/Backups/`.
- Settings → Backup section: last-snapshot timestamp, snapshot count, Export / Restore / Reveal in Finder buttons.
- New `BackupArchiveTests` with 3 tests: round-trip replaceAll, mergeKeepingNewer, manifest hash integrity.

### Architectural decisions

- **AD-015** Soft-delete via `Transaction.deletedAt`; permanent deletion is the backup retention's job.
- **AD-016** Local `.ftbackup` folder bundle is the primary durability story; CloudKit sync deferred to backlog.
- **AD-017** `findOrCreateAccount` never falls back to `(institution, type)` when `sectionNumber` is supplied.
- **AD-018** Deduplicator never silently suppresses or re-imports against a soft-deleted row.

### Added

**Per-account dashboards + interactive charts + drill-downs (Stage 3)**
- New `DashboardScope` (`.consolidated | .account(UUID)`) and `DashboardSnapshot` union (`.consolidated | .asset | .liability | .empty`); the dashboard view dispatches on the snapshot so consolidated, asset, and liability cases get purpose-built presentations
- Sidebar now lists every `Account` with a type-appropriate icon under an `Accounts` section; selecting one drives the scope
- New `LiabilityAccountDashboard` for credit-card accounts: `UtilizationCard` (gauge + limit + % indicator), `PaymentDueCard` (date + days-until + minimum / no-interest), `ChargesVsPaymentsChart`, `InstallmentsCard` with per-plan progress, `InterestAndFeesCard` (hidden when both zero), spending donut, recent transactions
- New `AssetAccountDashboard` mirrors the consolidated layout scoped to one checking/savings account
- Interactive charts: every time-series chart now has hover tooltips via `chartXSelection`; the consolidated cash-flow chart has an Income/Expenses series filter
- New `BreakdownSheet` drills into every aggregate. Summary tiles, cash-flow bars, net-worth points, and donut sectors all open a sheet listing the rows that produced the headline number, with a Total at the bottom
- `DashboardViewModel` correctly excludes `.creditCardPayment` and synthesized MSI parent-purchase rows from cash-flow aggregates (closes the AD-C5 + AD-C3 gaps)
- New `DECISIONS.md` entries AD-009..AD-014 documenting the manual-review-first parser, signed liability balances, the supplementary-card model, MSI handling, credit-card payment classification, and the learning hooks

**Bug fixes (post-smoke-test, pre-Stage 3)**
- `CategoryPickerView` now shows subcategories. The previous code iterated `cat.subcategories` which isn't reliably materialized; switched to filtering the existing `@Query<Category>` for children. Manual category triage now writes proper subcategory rules.
- Import sheet opened from the Dashboard floating button gained a Done button; previously it had no dismiss affordance.

**Learning hooks: merchant→category + description→sign-recovery (Stage 4)**
- New `SignRecoveryHint` `@Model`: pattern + implicitSign (+1 / -1) + source + createdFrom; registered in `AppContainer` and every in-memory test container
- New `LearningHooks` namespace with two idempotent helpers: `recordCategorization(...)` and `recordSignRecovery(...)`. Both skip when an equivalent rule already exists; sign-recovery only fires when the raw line truly lacks a sign glyph
- `TransactionsView` calls `recordCategorization` in the `CategoryPicker` callback so every manual assignment promotes to a `CategoryRule` with `source = "user_correction"` (priority 90)
- `PendingReviewSection.resolve()` calls `recordSignRecovery` after creating the Transaction so future paste imports get the sign right automatically
- `PastedHsbc2NowParser` gains a `SignHint` init param: strict pattern still requires a sign glyph but a matched hint can override HSBC's `+/-` convention; loose pattern (no sign glyph) is accepted only when a hint matches the description
- `IngestPipeline.ingestPastedText` fetches live `SignRecoveryHint`s and passes them to the parser

**Editable Transactions view + inline pending-import review (Stage 2)**
- `TransactionsView` rows are now editable in place: tap any of Date / Description / Amount to open a popover and commit a change; the existing Category column is unchanged
- New `EditableCells.swift` with `EditableTextCell`, `EditableDateCell`, and `EditableAmountCell` — tap-to-edit popovers that mutate the bound `@Model` object and let the caller persist
- New `PendingReviewSection`: a collapsible "N rows need review" card above the table that lists every unresolved `PendingImport`. Each pending row pre-seeds its inputs from the parser's best-effort partial parse; clicking **Resolve** creates a real `Transaction`, links `PendingImport.resolvedTransaction`, runs `Categorizer` against current rules, and saves
- `TransactionsView` adds `@Query<PendingImport>` filtered by `resolvedTransaction == nil`, so resolved rows disappear from the card automatically

**HSBC paste import — Stage 1 UI**
- `ImportView`: new "Paste Text" button next to "Browse Files"; `.plainText` (`.txt`) added to the file importer's allowed types; sheet wired up
- `ImportViewModel`: `showingPasteSheet`, `pasteBuffer`, `pasteDetection`, `importPastedText() async`. `importFiles` now branches PDF/CSV vs TXT and routes TXT through `IngestPipeline.ingestPastedText`
- New `PasteImportSheet.swift`: monospaced `TextEditor` + a detection chip that consults `Detector.detectFromPastedText` as the buffer changes (green when HSBC 2Now is detected, orange otherwise); Import is disabled until detection succeeds

**HSBC 2Now credit card support (Phases 1 + 2)**
- `Account`: gained `creditLimit`, `statementDayOfMonth`, `paymentDayOfMonth` (all optional, lightweight migration)
- `Statement`: gained `minimumPayment`, `paymentForNoInterest`, `paymentDueDate`, `interestCharged`, `feesCharged`, `ivaCharged`. Explicit `inverse: \Transaction.statement` to keep the relationship deterministic alongside the new `InstallmentPlan` inverse
- `Transaction`: gained `cardLast4` (disambiguate titular vs supplementary card) and `installmentPlan` relationship
- New `@Model InstallmentPlan` for Meses Sin Intereses (MSI) tracking — original amount, total months, current month, monthly amount, rate
- `CategoryKind.creditCardPayment` to keep card payments out of generic `.transfer` aggregates
- Seed data: promoted "Credit Card Payments" to a top-level category; new HSBC rules for `SU PAGO GRACIAS SPEI`, interest, and annual fee
- New `PastedHsbc2NowParser`: ingests statement text the user copies from the HSBC portal. Extracts statement header (period, due date, balances, credit limit), MSI table (Home Depot 02 de 12), and per-card transaction sections. Tolerates OCR-style number artifacts (dot/space thousands separators)
- New `@Model PendingImport`: records lines the parser couldn't confidently decode, with best-effort partial parse fields and a nullable link to the resolved `Transaction`. Forms the basis of the manual-review + learning flow
- `IngestPipeline.ingestPastedText(...)`: paste-text entry point; confident rows persist as usual, ambiguous rows become `PendingImport` attached to the same `Statement`. Dedup hash is SHA-256 of the pasted text
- `Detector.detectFromPastedText(...)`: HSBC 2Now classifier for paste payloads (matches "HSBC" + "2Now")
- 6 new tests covering header extraction, MSI parsing, both card sections, combined-card reconciliation against documented totals, SU PAGO classification as payment, and PendingImport creation for a broken row

### Architectural decisions

- **AD-C1** Supplementary cards modeled as a `cardLast4` field on `Transaction`, not as separate Accounts
- **AD-C2** Liability balances stored signed-negative so consolidated net worth = simple sum
- **AD-C3** MSI installments produce both an original-purchase Transaction and per-month installment Transactions, linked through `InstallmentPlan`
- **AD-C4** Credit-card storage convention: negative = money out, positive = money in. HSBC's "+" (charge) is flipped during parsing
- **AD-C5** `SU PAGO GRACIAS SPEI` payments categorize as `.creditCardPayment` and are excluded from cash-flow aggregates everywhere

### Changed

**Liquid Glass adoption — removed all opaque backgrounds**
- `DashboardView.swift`: Replaced opaque `.background()` + `.clipShape()` on chart/recent cards with `.glassEffect(.regular, in: .rect(cornerRadius: 10))`. SummaryCard uses `.glassEffect(.regular, in: .rect(cornerRadius: 12))` with no tint. Cards wrapped in `GlassEffectContainer`. Floating import button uses `.buttonStyle(.glassProminent)` with no tint.
- `FinanceTrackerApp.swift`: Added `MeshGradient` background (3×3 subtle dark blues/greens/purples) behind all content — gives glass material color to refract
- `DashboardView.swift`: Chart backgrounds set to `.chartBackground { _ in Color.clear }`. Spending donut uses vivid per-category color map instead of hash-based index colors
- `TransactionsView.swift`: Category badges use `.glassEffect(.regular, in: .capsule)` — no tint
- `ApplyToSimilarView.swift`: Pattern label uses `.glassEffect(.regular, in: .rect(cornerRadius: 6))`. "Apply to Selected" uses `.buttonStyle(.glassProminent)` — no tint
- `ImportView.swift`: Drop zone uses `.glassEffect(.regular, in: .rect(cornerRadius: 12))`. Report badges use `.glassEffect(.regular, in: .capsule)` with `.foregroundStyle()` for text color. "Browse Files" uses `.buttonStyle(.glassProminent)` — no tint
- `CategoryPickerView.swift`: "Create & Apply" uses `.buttonStyle(.glassProminent)` — no tint
- All `.borderedProminent` buttons → `.glassProminent`. All `.tint()` removed from glass effects and buttons. Zero `.background()` / `.tint()` calls in any view file.

**Fixed SeedDataLoader crash on duplicate category names**
- `SeedDataLoader.swift`: Replaced `Dictionary(uniqueKeysWithValues:)` with safe loop to avoid crash when categories share names (e.g. subcategory "Insurance" under different parents)

### Changed

**SPEI destination-specific categorization**
- `categories.json`: Replaced "SPEI Transfer" / "International Transfer" subcategories with "To Own Accounts" and "Credit Card Payments" under Transfers
- `category_rules.json`: Removed all catch-all SPEI rules; added 8 destination-specific rules at priority 87 (Priority, 2now/HSBC, Nu, TDC Explora, INVEX Volaris, BBVA 7777, Explora/BANAMEX, Moneypool)
- Unknown SPEI destinations now fall to Uncategorized — visible signal that a new destination appeared

**Dashboard excludes ALL transfer subcategories**
- `DashboardViewModel.swift`: Changed 3 occurrences of `category?.name == "Internal Transfer"` to `category?.kind == .transfer` — now correctly excludes To Own Accounts, Credit Card Payments, and Internal Transfer from income/expense totals

**SeedDataLoader incremental subcategory sync**
- `SeedDataLoader.swift`: New `syncCategories` method compares JSON subcategory names against existing DB for each parent, inserts missing ones without requiring a full store wipe

### Added

- 6 new tests in `SPEIDestinationRulesTests`: SPEI to 2now, Priority, Nu, Volaris, cash flow exclusion, unknown destination fallback

### Fixed

**Deduplicator requires exact same day**
- `Deduplicator.swift`: Changed `abs(daysDiff) <= 1` to `daysDiff == 0` — if a transaction didn't happen the same day, it's not a duplicate

### Changed

**Spending donut uses vivid per-category colors**
- `DashboardView.swift`: Replaced hash-based `colorForCategory` with explicit map (Food=orange, Transport=blue, Shopping=purple, etc). Uncategorized shows as dark gray.
- Description column now sortable (alphabetical) via `value: \.descriptionRaw`
- Category column now sortable via `value: \.categoryName` on new computed property
- Date and Amount columns were already sortable

**Filter transactions by category**
- New category Picker in filter bar next to account Picker
- Hierarchical menu: parent categories as section headers, subcategories indented below
- Selecting a parent category matches transactions with that parent OR any of its subcategories
- "All Categories" default shows everything

### Changed

**Apply to Similar — review matching transactions before applying**
- `ApplyToSimilarView.swift`: Replaced simple count+confirm sheet with scrollable list of all matching transactions showing date, description (80 chars), and amount per row
- Each row has a checkbox (default: checked); user can uncheck transactions they don't want recategorized
- Footer: "Just This One" (left) + "Apply to Selected (N)" (right, shows checked count, disabled when N=0)
- CategoryRule is only created if at least one transaction beyond the original is selected
- Pattern shown at top for user review

### Fixed

**Apartado (savings) deposit parsing — interest, ISR, deposits now extracted**
- `StructuralParser.swift`: `parseWideHeaderTable` now detects cells that start with a date prefix but contain inline amounts (e.g. `02/01/26 Abono de intereses $ 214.80 $ 378,956.66`) and splits them via `parseSingleTransactionSegment` instead of discarding them
- `StructuralParser.swift`: New `startsWithDatePrefix` check using unanchored regex for cells like `02/01/26 Retiro a Cuenta Débito` where the date is followed by description text
- `StructuralParser.swift`: Added ISR to withdrawal keywords in wide-header parser so tax withholdings are correctly signed as negative
- `StructuralParser.swift`: Split-column regex in `parseSingleTransactionSegment` now handles optional `+`/`-` signs before `$` amounts
- `parseRows` falls through to `parseLineByLine` when `parseWideHeaderTable` and flow/grid return empty
- Test: January Apartado now parses 40+ transactions including interest, ISR, deposits, and withdrawals

**Category picker uses Button in Table column**
- `TransactionsView.swift`: Category badge in Table column now uses `Button` instead of `.onTapGesture` — SwiftUI Table swallows tap gestures on cell content

**New Category creation from picker**
- `CategoryPickerView.swift`: Added "+" button that opens a sheet with name TextField + kind segmented Picker (Expense/Income/Transfer). "Create & Apply" creates the Category in ModelContext, applies it, and dismisses

**Volaris INVEX rule corrected — credit card payment, not flight**
- `category_rules.json`: Changed "SPEI enviada a.*INVEX Volaris" from `Travel.Flights` to `Transfers.SPEI Transfer` — this is a credit card payment, not a flight purchase

**Account deduplication fix — no more duplicate accounts per PDF**
- `IngestPipeline.swift`: `findOrCreateAccount` now falls back to matching by institution + type when account number doesn't match, preventing duplicate Account records across PDF imports
- Test: importing 01.pdf + 02.pdf produces exactly 2 accounts (not 4)

**Category picker save fix**
- `TransactionsView.swift`: Fixed dual-sheet flow — category is now always saved immediately on selection. "Apply to Similar" sheet presents after first sheet dismisses via `onChange`, avoiding SwiftUI's simultaneous sheet limitation

**Interest earned fix — $0.00 → correct totals**
- `category_rules.json`: Removed `^...$` anchors from "Abono de intereses" rule so partial matches work on normalized descriptions

**Spending chart fix — distinct colors, single Uncategorized**
- `DashboardView.swift`: Donut chart now uses index-based color assignment (10-color palette) instead of hash-based
- `DashboardViewModel.swift`: Uncategorized transactions now aggregate into a single "Uncategorized" entry using a fixed sentinel key

**Interest rule fix**
- `category_rules.json`: Removed `^...$` anchors from "Abono de intereses" rule

### Changed

**TransactionsView rewritten with native Table layout**
- Full `descriptionRaw` displayed — never truncated or replaced by `merchantNormalized`
- 4-column SwiftUI Table: Date (DD MMM YYYY), Description (multi-line + account nickname subtitle), Amount (green/red, right-aligned), Category (tappable badge)
- Sortable by date (default) and amount via column headers
- Account filter dropdown: view all accounts or filter by Débito/Apartado
- Category badge tap still opens CategoryPicker → ApplyToSimilar flow
- Search bar preserved

### Added

**Interest earned tracking on dashboard**
- `DashboardViewModel`: New `totalInterestEarned` property, sums all `Income.Interest` transactions for selected period
- `DashboardView`: New "Interest Earned" summary card (teal) alongside Net Worth, Income, Expenses

**Custom date range picker**
- `DashboardView`: Added "Custom" option to period selector. Shows popover with From/To DatePickers and Apply button for arbitrary date ranges

**Dashboard accuracy fix — expenses $831→~$100K, net worth -$2M→~$462K→$49K**
- `SeedDataLoader.swift`: Replaced early-return when categories exist with incremental rule sync — now compares JSON rules against DB by `patternRegex` and inserts only new rules, so added rules load on next app launch
- `StructuralParser.swift`: Wired `MerchantExtractor` into all 5 `RawTransaction` creation sites (was hardcoded `""`). SPEI descriptions containing "; Transferencia SPEI" extract text before semicolon as merchant
- `category_rules.json`: Added 7 SPEI destination-specific rules (2now, Priority, Nu, INVEX Volaris, Moneypool, TDC Explora, BBVA 7777) at priority 85

**SPEI transfers counted as real income/expenses**
- `DashboardViewModel.swift`: `computeTotals`, `computeMonthlyCashFlow`, and `computeSpendingByCategory` now only exclude "Internal Transfer" (Débito↔Apartado sweeps), not all transfers. SPEI transfers are counted based on amount sign — outgoing SPEI as expenses, incoming SPEI as income. This reflects the Openbank-only perspective where money leaving via SPEI is a real outflow.
- Updated `OpenbankMultiAccountTests` to verify SPEI transfers appear in income/expenses while internal transfers remain excluded

**Net worth anchored to statement closing balances**
- `StructuralParser.swift`: New `extractStatementSummary` method parses "Saldo final" and "Saldo inicial" from "Resumen del periodo" sections in Openbank PDFs
- `ParsedSection.swift`: Added `openingBalance: Decimal?` and `closingBalance: Decimal?` fields
- `Statement.swift`: Added `openingBalance: Decimal?` and `closingBalance: Decimal?` — stored on each Statement during ingest
- `IngestPipeline.swift`: Passes balance data from `ParsedSection` to `Statement` on creation
- `DashboardViewModel.swift`: `computeNetWorth` completely rewritten — now fetches all `Statement` records, finds latest per account, sums their `closingBalance` values. Time series plots each month's total using each account's most recent closing balance. No transaction summation
- `DashboardView.swift`: Summary cards now show "Net Worth" (from statements) instead of "Net" (income + expenses)
- 6 new tests: balance extraction from Jan/Feb/Mar PDFs, persistence verification, net worth accuracy ($49,371.09 for March 2026)

### Added

**Multi-account PDF parsing — Openbank Débito + Apartados**
- `ParsedSection.swift`: New struct representing a section of a PDF with account hint, type, number, nickname, and transactions
- `StructuralParser.parseSections(data:)`: New method that detects account section boundaries in multi-section PDFs by checking for account header patterns (e.g., "Cuenta Débito Open", "Apartados Open +") on each page. Groups transactions per section. Backward-compatible `parse(data:)` wraps it by flattening.
- `IngestPipeline.ingestFile()`: Now iterates `ParsedSection` results, creating separate Account + Statement per section. Each section gets its own dedup, categorization, and persist cycle.
- `Account.accountNumber`: New optional field for matching accounts by institution + number (not just institution). Enables two Openbank accounts.
- `findOrCreateAccount`: Matches by institution + accountNumber when available, falls back to institution-only.

### Fixed

**REGRESSION: SwiftData schema migration failure caused empty app**
- Adding `source`/`matchCount`/`createdFrom` to `CategoryRule` broke the existing SwiftData store — lightweight migration failed with "Validation error missing attribute values on mandatory destination attribute" for `matchCount`. Store fell back to empty in-memory, making all views show 0 transactions.
- Fix: deleted incompatible store. App creates fresh database with new schema on next launch.
- Removed all NSLog diagnostics from DashboardViewModel, ImportViewModel, IngestPipeline, SettingsView

**Dashboard excludes transfers from income/expenses**
- `DashboardViewModel.swift`: `computeTotals`, `computeMonthlyCashFlow`, and `computeSpendingByCategory` now use `category.kind` when available (fall back to amount-sign heuristic for uncategorized), always exclude `.transfer` transactions
- Prevents credit card payments (PAGO RECIBIDO) from inflating income totals

### Added

### Added (Part 3)

**Transaction category editing with learning rules**
- `MerchantExtractor.swift`: Extracts merchant keyword from raw descriptions — strips RFC patterns, /REF patterns, trailing digits, punctuation; returns first all-alpha token >= 4 chars
- `CategoryPickerView.swift`: Category picker sheet grouped by kind (expense/income/transfer/investment) with subcategory nesting
- `ApplyToSimilarView.swift`: "Apply to similar?" confirmation — shows extracted keyword, preview count of matching transactions, "Just This One" or "All Matching" options
- `TransactionsView.swift`: Tap any transaction row to open category picker → apply-to-similar flow. Uncategorized transactions show gray "Uncategorized" badge
- User corrections create `CategoryRule` with `source: "user_correction"`, `priority: 100`, `createdFrom: originalDescription`
- All matching transactions retroactively re-categorized when user chooses "All Matching"

**MerchantExtractor tests (9 tests)**
- Strips CINEPOLIS numbers, RFC patterns, /REF patterns, compound names, URL-like descriptions
- Returns nil for short/numeric inputs

**Category correction tests (2 tests)**
- User correction creates rule and applies retroactively to 5 CINEPOLIS transactions
- "Just this one" applies category without creating rule

**Seed rule: MONTO A DIFERIR**
- `category_rules.json`: Added `(?i)MONTO\s*A\s*DIFERIR` → Transfers.Internal Transfer at priority 90 for Amex installment notation

**Transfer categorization tests (5 tests)**
- `CategorizerTransferTests.swift`: PAGO RECIBIDO, MONTO A DIFERIR, SPEI transfers all classified as transfer; dashboard logic verified to exclude transfers; uncategorized positive amounts fall back to income heuristic

### Added (Part 2)

**CategoryRule source tracking**
- `CategoryRule.swift`: Added `source: String` ("seed"/"user_correction"), `matchCount: Int`, `createdFrom: String?` — lightweight SwiftData migration with defaults
- `CategoryRule.loadSeedRulesFromBundle()`: Static method for test access to bundled seed rules
- `Categorizer.swift`: `Result` now includes `matchedRules: [UUID: Int]` tracking which rules matched and how many times — Categorizer stays pure, caller (IngestPipeline) increments matchCount
- `IngestPipeline.swift`: Increments `rule.matchCount` for each matched rule after categorization, persisted on save
- `SeedDataLoader.swift`: Explicitly sets `source: "seed"` on loaded rules

**Source tracking tests (5 tests)**
- `CategoryRuleSourceTrackingTests.swift`: seed rules have source="seed" and matchCount=0, matchCount increments on categorize, user correction rules have source="user_correction", user correction rules take priority over seed rules

**Dashboard shows $0 even with imported transactions**
- `DashboardView.swift`: Changed "All" date range from 2020-01-01 start to `Date.distantPast` — Amex PDF has 2018-2019 transactions that fell outside the hardcoded range
- `DashboardView.swift`: Default selected period changed from `.year` (2026 only) to `.all` so newly imported data appears immediately
- `DashboardView.swift`: Added `.onAppear` to refresh data when navigating back to dashboard
- `DashboardViewModel.swift`: Added diagnostic NSLog in `refresh()` logging transaction count and date range

### Added

**Transactions View**
- `TransactionsView.swift`: Real transaction list replacing placeholder — `@Query` sorted by date desc, searchable by description/merchant, amount colored green (positive) / default (negative), category badge pills per row

**Settings View**
- `SettingsView.swift`: Real settings replacing placeholder — Accounts section listing all `Account` records with type/currency/transaction count, Data section with stats and delete-all button with confirmation, About section with app version

### Removed

- All NSLog diagnostic calls from `StructuralParser.swift` (5 locations) and `IngestPipeline.swift` (3 locations) — no longer needed after root cause was identified and fixed

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

**Structural Parser (Commit E)**
- `LayoutFingerprint` — `Sendable` value type capturing a successful parse configuration (institution hint, header pattern, layout mode, amount convention, column roles, source file hash, transaction count)
- `LayoutStore` — `@MainActor` in-memory store for layout fingerprints, supports save/query-by-key/query-by-institution/list/remove/count
- 4 new tests (66 total, all passing): LayoutStore save+query, query-by-institution, remove, list-all

**Pipeline Integration (Commit F)**
- `StructuralParser` wired into `IngestPipeline` as primary parser with legacy fallback — structural parse attempted first, falls back to institution-specific parsers (Openbank, Amex) if structural returns 0 transactions or fails
- Fixed `isLocked` gate: PDFs with `isLocked=true` are now only rejected if text extraction actually fails (`page.string == nil`), allowing restricted-but-readable PDFs (e.g., Amex Mexico) through the pipeline
- Garbled-text detection heuristic: rejects PDFs where >30% of characters are Unicode replacement characters (U+FFFD) or non-printable control characters, with clear error message pointing to OCR (Phase 2)
- Diagnostic `os.log` entries throughout parse pipeline: page row counts, detected table layout/convention, transaction counts per page, parser selection (structural vs legacy), garbled-text ratio
- Improved error messages for unsupported/unknown PDFs with actionable guidance
- `StructuralParser` logs: page count, rows per page, transactions per page, table detection details (layout, columns, convention, data row count)

**Banorte POR Ti Support (Commit G)**
- Added knowledge patterns for Banorte POR Ti credit card statements (EdoCta 202208.pdf)
- `header_vocabulary.json`: section markers (`Detalle de movimientos del Titular en M.N.`, `Detalle de movimientos de TDC Digital`), combined header (`Fecha Concepto RFC/CURP Tipo de transacción Importe`), end markers for installment/noise sections
- `date_patterns.json`: `dd_mm_no_year` pattern (dates like `14/07` with year inferred from statement context), `dd_mm_yyyy_slash_full` (DiDi dates), `dd_mon_yyyy_with_time` (DiDi/Stori dates), Banorte period/cutoff patterns
- `amount_conventions.json`: `trailing_minus` convention (bare `$` = charge, `$X-` = payment), `mxn_trailing_minus` regex pattern
- `SemanticNormalizer`: `trailing_minus` amount handling, Banorte period context extraction (`13 Julio al 12 Agosto, 2022`), Banorte cutoff date extraction
- `StructuralParser`: line-based fallback parser (`parseLineByLine`) for PDFs where text blocks aren't split into individual cells — splits rows on date patterns and parses each segment independently
- When table detection succeeds but produces 0 transactions, falls back to line-based parsing
- 4 new tests (70 total, all passing): Banorte transaction extraction, date validation, payment detection, charge detection

**Suburbia Support (Commit K)**
- Added knowledge patterns for Suburbia department store credit card (201607.pdf)
- `date_patterns.json`: `suburbia_period` pattern for `DD/MMM/YY - DD/MMM/YY` period format, case-insensitive month lookup in period context extraction
- `SemanticNormalizer`: `lookupMonth` helper for case-insensitive month name matching, `extractSuburbiaPeriodContext` handler
- `StructuralParser`: pending-amount mechanism in line-based parser — when a date+description row has no amount, stores as pending and associates with the next amount-only row; handles `$ -amount` format (leading minus between `$` and digits)
- 3 new tests (73 total, all passing): Suburbia transaction extraction, date validation, payment detection

**Remaining Institution Patterns (Commits H,I,J,L)**
- Added knowledge patterns for DiDi Cuenta (julio.pdf), DiDi/Stori (202509.pdf), CETES/CI Banco (202102.pdf), Skandia (2023.pdf)
- `date_patterns.json`: `didi_period` (numeric DD/MM/YYYY range), `cetes_period` (numeric DD/MM/YYYY range), `dd_mm_yyyy_slash_full` and `dd_mon_yyyy_with_time` date patterns
- `header_vocabulary.json`: section markers (`Detalles de movimientos`, `Movimientos del período`), end markers (`Solución Factible`, `Resumen del portafolio`)
- `SemanticNormalizer`: generic `extractNumericPeriodContext` for purely numeric date ranges
- 4 new tests (77 total, all passing): smoke tests for each institution (parses without crashing, MXN currency)
- Note: DiDi Cuenta and DiDi/Stori have complex multi-line transaction formats requiring future parser enhancements for full extraction

### Changed

**Pipeline Improvements (Commit F)**
- `StructuralParser` wired into `IngestPipeline` as primary parser with legacy fallback — structural parse attempted first, falls back to institution-specific parsers (Openbank, Amex) if structural returns 0 transactions or fails
- Fixed `isLocked` gate: PDFs with `isLocked=true` are now only rejected if text extraction actually fails (`page.string == nil`), allowing restricted-but-readable PDFs (e.g., Amex Mexico) through the pipeline
- Garbled-text detection heuristic: rejects PDFs where >30% of characters are Unicode replacement characters (U+FFFD) or non-printable control characters, with clear error message pointing to OCR (Phase 2)
- Diagnostic `os.log` entries throughout parse pipeline: page row counts, detected table layout/convention, transaction counts per page, parser selection (structural vs legacy), garbled-text ratio
- Improved error messages for unsupported/unknown PDFs with actionable guidance
- `StructuralParser` logs: page count, rows per page, transactions per page, table detection details (layout, columns, convention, data row count)

### Added

**Layout Infrastructure (Commit E)**
- `LayoutFingerprint` — `Sendable` value type capturing a successful parse configuration (institution hint, header pattern, layout mode, amount convention, column roles, source file hash, transaction count)
- `LayoutStore` — `@MainActor` in-memory store for layout fingerprints, supports save/query-by-key/query-by-institution/list/remove/count
- 4 new tests (66 total, all passing): LayoutStore save+query, query-by-institution, remove, list-all

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
