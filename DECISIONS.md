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

## AD-009: Manual-review-first parsing — `PendingImport` over heuristics
**Date:** 2026-05-11
**Context:** Some issuers (HSBC 2Now) emit PDFs with a custom font and no ToUnicode CMap, so PDFKit returns empty strings and OCR is fragile on dense tables. Adding heuristics to "guess" a row's date/amount/sign multiplies edge-case bugs.
**Decision:** Whenever the parser cannot confidently decode a line, persist it as a `PendingImport` row attached to the same `Statement`. The user reviews and resolves these inline from the editable Transactions view. Each manual resolution feeds the learning hooks (AD-014).
**Consequence:** The system stays correct by default and gets sharper over time. No transaction is silently dropped; no transaction is silently wrong.

## AD-010: Liability balances stored signed-negative
**Date:** 2026-05-11
**Context:** `Statement.closingBalance` was assumed positive for asset accounts. With credit cards a "balance" is debt. We need consolidated net worth to be a simple sum.
**Decision:** Credit-card `Statement.closingBalance` is stored as a **negative** Decimal. Asset closing balances stay positive. The HSBC paste parser flips the documented "Saldo deudor total" sign during normalization.
**Consequence:** `Sum(latest closing balance across accounts) == net worth` — no per-type sign-flipping anywhere in the dashboard logic.

## AD-011: Supplementary cards as `cardLast4` on `Transaction`, not separate Accounts
**Date:** 2026-05-11
**Context:** HSBC 2Now bills primary + supplementary cards together under one statement with one credit limit. Modeling each supplementary card as its own `Account` doubles the rows in summaries, splits the credit-limit logic, and forces accounts to know about each other.
**Decision:** Each `Transaction` carries an optional `cardLast4: String?` tag. The `Account` represents the card *account* (one credit limit, one due date). Supplementary card filtering is a query, not a separate row.
**Consequence:** Sidebar shows one HSBC entry; charges-vs-payments and utilization treat the account as a single unit. Tests filter by `cardLast4` when needed.

## AD-012: MSI — both original purchase and per-month installments as separate `Transaction`s
**Date:** 2026-05-11
**Context:** A "Meses Sin Intereses" purchase shows up on the statement as a one-time event AND as a monthly cuota. Storing only the original misses the periodic cash impact; storing only the cuotas hides the underlying purchase.
**Decision:** The parser emits one `Transaction` for the original purchase (linked to an `InstallmentPlan`) AND one `Transaction` per monthly cuota. Cash-flow aggregates skip the original-purchase rows (their cash impact lives in the cuotas) but `spendingByCategory` and the merchant-level history keep the original.
**Consequence:** The Charges-vs-Payments chart and dashboard totals reflect what the user actually pays this month, while the Installment Plans card shows the multi-month commitment.

## AD-013: `SU PAGO GRACIAS SPEI` payments classify as `.creditCardPayment` and are excluded from cash flow
**Date:** 2026-05-11
**Context:** The same money appears as an outgoing SPEI from the user's checking account and as an incoming payment on the credit card. Naively, both sides land in dashboard aggregates and double-count.
**Decision:** Add `CategoryKind.creditCardPayment` and a seed rule that classifies the HSBC SPEI payment line. `DashboardViewModel` excludes `.creditCardPayment` AND `.transfer` kinds from cash flow / spending-by-category aggregates. Net worth uses signed-stored balances (AD-010) so the payment naturally moves the right amount between asset and liability accounts.
**Consequence:** Importing both sides of a transfer doesn't double-count. The Transactions view still shows both rows so the user can reconcile.

## AD-014: Learning hooks — every manual fix teaches the system
**Date:** 2026-05-12
**Context:** Manual review of ambiguous rows is acceptable once; doing it on every import is not.
**Decision:** Two hooks fire from the manual-review surfaces:
- `LearningHooks.recordCategorization` writes a `CategoryRule(source: "user_correction", priority: 90)` whenever the user assigns a category, idempotent on `(pattern, category)`.
- `LearningHooks.recordSignRecovery` writes a `SignRecoveryHint(source: "user_correction")` whenever a resolved `PendingImport`'s raw text lacked an explicit `+/-` glyph. The parser consults these hints on the next paste import.
**Consequence:** The same merchant or sign-quirk never needs to be fixed twice. Rules and hints accumulate; their `createdFrom` keeps provenance.

## AD-015: Soft-delete via `Transaction.deletedAt`; permanent deletion is the backup retention's job
**Date:** 2026-05-13
**Context:** Users delete transactions by accident. Permanent deletion (`context.delete`) is irreversible.
**Decision:** Add `Transaction.deletedAt: Date?` (default nil). All `FetchDescriptor<Transaction>` queries filter `deletedAt == nil` by default. The "Recently Deleted" chip surfaces soft-deleted rows with a Restore action. Actual data removal happens via backup retention pruning.
**Consequence:** Two recovery paths: in-app trash for short-term mistakes, `.ftbackup` archives for everything older.

## AD-016: Local `.ftbackup` folder bundle is the primary durability story; CloudKit sync deferred to backlog
**Date:** 2026-05-13
**Context:** SwiftData's default container at `~/Library/Application Support/` has no export, backup, or sync. A single container corruption loses everything.
**Decision:** Implement a local backup pipeline: `BackupArchive` exports to a `.ftbackup` folder bundle (JSON snapshots + manifest + statement file copies). `BackupScheduler` writes a snapshot every 24h on launch with 7/4/12 daily/weekly/monthly retention. CloudKit sync requires entitlements and the InstallmentPlan inverse-relationship loosening — both deferred per stakeholder.
**Consequence:** Durable, vendor-neutral, point-in-time archives that survive any Apple-ID / schema / SwiftData incident. `lastModifiedAt` on every model (added in the same stage) provides the merge conflict signal for when CloudKit eventually ships.

## AD-017: `findOrCreateAccount` never falls back to `(institution, type)` when a `sectionNumber` is supplied
**Date:** 2026-05-13
**Context:** Two HSBC 2Now accounts (different physical card numbers) were being merged into one Account because `findOrCreateAccount` fell back to `(institution, type)` matching when the second account's number didn't match the first.
**Decision:** When the parser supplies a `sectionNumber` and no existing Account matches, always create a new Account. The `(institution, type)` fallback only fires when `sectionNumber` is nil (legacy `ParsedSection.single` path).
**Consequence:** Distinct card accounts stay distinct. The HSBC parser now uses the titular card's `last4` as `accountNumber` for all sections (titular + adicional), so both card types share one Account per physical card.

## AD-018: Deduplicator never silently suppresses or re-imports against a soft-deleted row
**Date:** 2026-05-13
**Context:** When re-importing a statement after the user deleted some transactions, the Deduplicator would either silently suppress (treating deleted rows as duplicates) or silently re-import (ignoring the deletion).
**Decision:** The Deduplicator's `Result` includes a `matchedDeleted` list. For each match, the IngestPipeline creates a `PendingImport` with the reason "Matches a deleted transaction" and the deleted row's UUID. The user sees Restore / Keep Deleted actions in the review card.
**Consequence:** Honors the user's deletion intent without making a silent wrong choice. Aligns with AD-009 (manual-review-first).
