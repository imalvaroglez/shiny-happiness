# Architectural Decisions

## AD-001: Analytics Engine — SQLite deferred in favor of SwiftData
**Date:** 2025-05-05
**Context:** Spec lists DuckDB as primary, SQLite as fallback. Both add complexity.
**Decision:** Use SwiftData `FetchDescriptor` and `#Predicate` for Phase 1 queries (spending by category, cash flow, net worth). If queries exceed 200ms at 50k+ transactions, migrate to in-process SQLite with raw SQL.
**Consequence:** Zero external dependencies. Simpler codebase. Potential performance ceiling deferred to Phase 2.

## AD-002: PDFKit positional text extraction over Vision OCR for Phase 1
**Date:** 2025-05-05
**Context:** Bank statement PDFs have tabular layouts. PDFKit's `.string` property concatenates text without column awareness, making table parsing unreliable.
**Decision:** Implement a lightweight positional text extractor using PDFKit's `CGRect`-based selection API to cluster text into rows and columns. Defer Vision OCR (`VNRecognizeTextRequest`) and `TableReconstructor` to Phase 2, only needed for garbled/obfuscated PDFs (nu Mexico, etc.).
**Consequence:** Handles 7 of 14 sample PDFs cleanly. Garbled/encrypted PDFs reported as errors in Phase 1.

## AD-003: Account auto-creation on import
**Date:** 2025-05-05
**Context:** Import pipeline needs an Account to associate transactions with. No account creation UI until later commits.
**Decision:** IngestPipeline auto-creates an Account from the Detector's identified institution (name, type inferred from statement format). User can rename/merge later in Settings.
**Consequence:** Zero-friction onboarding — first import creates accounts automatically.

## AD-004: Category seed data — start small, expand with real data
**Date:** 2025-05-05
**Context:** Need initial CategoryRules so dashboard isn't 100% "Uncategorized" on first import.
**Decision:** Ship 15-20 high-confidence regex rules for common Mexican merchants (UBER, DIDI, OXXO, AMAZON, MERCADO PAGO, WALMART, STARBUCKS, etc.). Add more after ingesting real statements.
**Consequence:** Good enough for demo. Can iterate quickly.

## AD-005: Xcode project via XcodeGen
**Date:** 2025-05-05
**Context:** Creating `.xcodeproj` manually is error-prone. SPM-only doesn't produce proper `.app` bundles.
**Decision:** Use `project.yml` + XcodeGen to generate the Xcode project. Checked into git.
**Consequence:** Reproducible project generation. Easy to add targets/settings.

## AD-006: Strict concurrency (Swift 6 mode)
**Date:** 2025-05-05
**Context:** Swift 6 strict concurrency is enabled.
**Decision:** All ViewModels `@MainActor`. Heavy work (parsing, analytics) on background actors. `Sendable` types for all data crossing actor boundaries.
**Consequence:** Thread-safe by construction. No data races.

## AD-007: All money as Decimal, never Double or Float
**Date:** 2025-05-05
**Context:** Floating-point arithmetic introduces rounding errors unacceptable for financial data.
**Decision:** All monetary values stored as `Decimal`. Pre-commit hook rejects `Double`/`Float` in `Domain/` directory.
**Consequence:** Exact arithmetic. Slight performance overhead vs Double — acceptable for local single-user app.

## AD-008: StatementParser protocol — parsers are account-agnostic
**Date:** 2025-05-05
**Context:** Original protocol had `parse(data:account:)` but no parser uses the Account parameter. Passing `@Model` objects across actor boundaries triggers Swift 6 concurrency errors.
**Decision:** Remove `account` from `StatementParser.parse()`. Account assignment happens in the Normalizer step, not during parsing. Parsers only produce `[RawTransaction]`.
**Consequence:** Clean actor isolation. Parsers are pure `Sendable` computation units.
