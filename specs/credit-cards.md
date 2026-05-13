SPEC: HSBC 2Now credit-card support + per-account dashboards

  Context

  FinanceTracker is a SwiftUI/SwiftData macOS app that ingests bank-statement PDFs. The current model assumes asset accounts (checking/savings) where positive Statement.closingBalance = money on hand. We are
  adding credit-card support (issuer: HSBC México, product: 2Now Oro) and restructuring the dashboard so each account has its own view, with a consolidated overview when no account is selected.

  Reference PDF: samples/2026-05-08_Estado_de_cuenta.pdf (HSBC 2Now Oro, period 10-Abr-2026 → 09-May-2026, card 5470 7480 3160 7827). All work in this spec must be validated against this fixture.

  Architectural decisions already made

  These are non-negotiable starting points — do not relitigate:

  - AD-C1 Supplementary cards (e.g. 5470...7801) are modeled as a cardLast4: String? field on Transaction, NOT as separate Account rows.
  - AD-C2 Liability balances are stored signed: Statement.closingBalance for a credit-card account is a negative Decimal. Consolidated net worth = simple sum of latest closing balances across all accounts.
  - AD-C3 MSI (Meses Sin Intereses) installments produce both records: (a) the original full-amount purchase as a Transaction in its purchase month, and (b) each monthly installment as a separate Transaction
  linked through a new InstallmentPlan model. The original purchase carries installmentPlan so it is excluded from cash-flow aggregates (because its cash impact is realized through the monthly installments).
  - AD-C4 Credit-card transaction signs in storage follow the existing convention: negative = money out (charge), positive = money in (payment/refund). The parser flips the HSBC +/- convention during
  normalization.
  - AD-C5 "SU PAGO GRACIAS SPEI" payments are categorized as CategoryKind.creditCardPayment and are excluded from both income and expense aggregates everywhere (treated like internal transfers).

  Document these in DECISIONS.md as AD-009 through AD-013.

  Out of scope

  - Other HSBC products (debit, Premier, etc.). Only 2Now for now.
  - OCR for fully garbled PDFs.
  - Editing InstallmentPlan from the UI (read-only display).
  - Multi-currency credit cards (the HSBC sample is MXN-only).

  Phase 1 — Domain model & migration

  1.1 Extend Account

  Add (all optional, lightweight migration):
  - creditLimit: Decimal?
  - statementDayOfMonth: Int?
  - paymentDayOfMonth: Int?

  1.2 Extend Statement

  Add (all optional):
  - minimumPayment: Decimal?
  - paymentForNoInterest: Decimal?
  - paymentDueDate: Date?
  - interestCharged: Decimal?
  - feesCharged: Decimal?
  - ivaCharged: Decimal?

  1.3 Extend Transaction

  Add cardLast4: String?.

  1.4 New InstallmentPlan model

  @Model final class InstallmentPlan {
      var id: UUID
      @Relationship(deleteRule: .nullify) var account: Account?
      @Relationship(deleteRule: .nullify) var originalPurchase: Transaction?
      @Relationship(deleteRule: .cascade, inverse: \Transaction.installmentPlan) var installments: [Transaction] = []
      var originalAmount: Decimal     // signed: negative (expense)
      var totalMonths: Int
      var currentMonth: Int            // 1-based, latest known
      var monthlyAmount: Decimal       // signed: negative
      var ratePercent: Decimal         // 0 for MSI
      var firstChargeDate: Date
      var merchantDescription: String
  }
  Add inverse relationship Transaction.installmentPlan: InstallmentPlan? (nullify on delete).

  1.5 CategoryKind

  Add case creditCardPayment. Seed a "Credit Card Payments" category with this kind in categories.json. Update category_rules.json to include SU PAGO GRACIAS SPEI → that category (high priority).

  1.6 Register the new model in AppContainer.modelContainer schema.

  1.7 SwiftData lightweight migration

  All new fields are optional. Verify on launch with an existing store from a previous build.

  Phase 2 — HSBC parser

  2.1 Garbled-text guard

  In IngestPipeline.isGarbledText, change behavior so that PDFs whose page 1 metadata is custom-font-encoded but whose transaction-detail pages are readable still pass.

  Recommended implementation: compute the bad-char ratio per page. Reject the PDF only if every page exceeds 60% bad chars. The HSBC sample has garbled cover/summary pages but legible transaction tables (Página
   3-4).

  2.2 Detector

  Add case hsbcMexico2Now = "HSBC 2Now" to DetectedIssuer. Detect when sample text contains both "HSBC" and ("2Now" or "2NOW"). suggestedAccountType = .creditCard. Confidence 0.95. Guard against generic "HSBC"
  matches that aren't 2Now — those should remain .unknown for Phase 1.

  2.3 HsbcMexico2NowParser: StatementParser

  Conforms to the existing protocol. Parses the legible transaction pages directly (do NOT rely on StructuralParser until knowledge JSONs are extended).

  Must extract:

  a) Statement-level header data (page 1):
  - Period start/end, payment due date.
  - paymentForNoInterest, minimumPayment, opening balance (Adeudo del periodo anterior), closing balance (Saldo deudor total, stored negative per AD-C2).
  - interestCharged, feesCharged, ivaCharged (each is 0.00 in this sample, but must be parsed).
  - Credit limit (for the account row, not the statement) — write through to Account.creditLimit on create/update.

  Wire these into ParsedSection (extend the struct as needed) so IngestPipeline.createStatement can populate them.

  b) MSI installments table (section COMPRAS Y CARGOS DIFERIDOS A MESES SIN INTERESES):
  - One row per active plan.
  - Columns: Fecha operación, Descripción, Monto original, Saldo pendiente, Pago requerido, Núm de pago (02 de 12), Tasa.
  - Produce one InstallmentPlan per row. Set currentMonth from the XX de YY cell, totalMonths from YY.

  c) Regular transactions (sections CARGOS, ABONOS Y COMPRAS REGULARES (NO A MESES)):
  - Two sub-sections in this PDF: titular 5470...7827 and tarjeta adicional 5470...7801. Tag each parsed row with cardLast4 (last 4 of the card identifier in the section header).
  - Columns: Fecha operación, Fecha de cargo, Descripción, Monto. The sign symbol (+ or -) appears immediately before the amount.
  - Sign flip per AD-C4: HSBC + → storage - (expense), HSBC - → storage + (payment/refund).
  - Recognize the SPEI payment line so it can be categorized correctly downstream.

  d) Reconciliation guard
  After parsing, the parser MUST verify the totals: sum of + charges ≈ Total cargos, sum of - abonos ≈ Total abonos, and opening + cargos + abonos ≈ closing (within 1 peso for rounding). If reconciliation
  fails, log a warning and include it in IngestReport.errors but still persist what was parsed.

  2.4 Pipeline wiring

  - IngestPipeline.resolveLegacyParser → return HsbcMexico2NowParser for .hsbcMexico2Now.
  - Normalizer must propagate cardLast4 from RawTransaction to Transaction.
  - After normalization, for each MSI row from section (b): create the InstallmentPlan and link a synthesized "original purchase" Transaction dated on the plan's first-charge date (purchase date) with
  installmentPlan set. If the original purchase already exists from a prior import, link instead of duplicating (match on account + amount + merchant + ~3-day window).
  - The current period's monthly installment must be added as a regular Transaction and linked to the same InstallmentPlan.

  2.5 Categorizer

  - SU PAGO GRACIAS SPEI → "Credit Card Payments" (CategoryKind.creditCardPayment), priority high.
  - HSBC fee/interest descriptions ("MONTO DE INTERESES", "COMISION ANUAL") → seed rules even though zero in this sample, so future statements categorize correctly.

  Phase 3 — Dashboard scope refactor

  3.1 Scope type

  enum DashboardScope: Hashable {
      case consolidated
      case account(UUID)  // Account.id
  }

  3.2 Snapshot model

  Replace the flat fields on DashboardViewModel with a @Observable that produces a DashboardSnapshot:

  enum DashboardSnapshot {
      case consolidated(ConsolidatedSnapshot)
      case asset(AssetAccountSnapshot)
      case liability(LiabilityAccountSnapshot)
      case empty
  }

  Asset and liability variants share many fields; keep them separate types — do not over-unify.

  ConsolidatedSnapshot
  - netWorth: Decimal (sum of signed latest closing balances)
  - netWorthOverTime: [NetWorthPoint]
  - monthlyCashFlow: [MonthlyCashFlow] — excludes transactions where category?.kind ∈ {.transfer, .creditCardPayment} AND excludes original MSI purchases (installmentPlan != nil && amount matches
  plan.originalAmount)
  - spendingByCategory: [CategorySpending]
  - totalIncome, totalExpenses, totalInterestEarned, totalInterestCharged
  - accountSummaries: [AccountSummary] — small per-account rows for the sidebar/overview

  AssetAccountSnapshot
  - Same shape as the current dashboard, scoped to one account.

  LiabilityAccountSnapshot
  - account, currentBalance (negative Decimal), creditLimit, utilizationPercent
  - latestStatement: minimumPayment, paymentForNoInterest, paymentDueDate, days until due
  - chargesVsPaymentsByMonth: [(month, charges, payments)]
  - spendingByCategory (exclude .creditCardPayment and .transfer)
  - totalCharges, totalPayments, interestCharged, feesCharged
  - activeInstallmentPlans: [InstallmentPlan]
  - recentTransactions

  3.3 Sidebar

  Replace the static NavigationLink list with:
  Overview                                  ← scope = .consolidated
  Accounts
    ⤷ <Account.nickname>  <balance>        ← scope = .account(id)
    ...
  Transactions
  Import Statements
  Settings
  Account rows use @Query<Account> (filter out closed accounts). For credit-card accounts, show a small utilization bar.

  3.4 Views

  - ConsolidatedDashboardView — close to the current dashboardDetail, but with a small "Accounts" panel listing each account + balance.
  - AccountDashboardView(account:) — dispatches to AssetDashboardSections or LiabilityDashboardSections based on account.type.

  3.5 Liability-only sections (new components)

  - UtilizationCard — gauge + numeric breakdown ($45,054.70 / $465,000.00 = 9.7%).
  - PaymentDueCard — minimum, pay-no-interest, due date, days remaining; visual urgency when ≤7 days.
  - InstallmentsCard — list of active InstallmentPlans with progress (02 de 12).
  - ChargesVsPaymentsChart — replaces cashFlowChart for liabilities. Bars: charges (red), payments (green).
  - InterestAndFeesCard — interest, commissions, IVA. Hide when all zero this period.

  3.6 Aggregation correctness

  A single integration-test-level invariant: importing both the HSBC statement and the corresponding debit statement (with the matching outgoing SPEI to CLABE ...7134) must NOT produce double counted income or
  expense in ConsolidatedSnapshot.monthlyCashFlow or spendingByCategory. The two sides of the transfer cancel.

  Phase 4 — Tests

  Use Swift Testing (@Test, not XCTest) consistent with existing test style in FinanceTrackerTests/.

  4.1 HsbcMexico2NowParserTests

  - detection_identifies2NowFromPDFText
  - parses_periodHeader_extractsBalancesAndDueDate
  - parses_msiTable_producesInstallmentPlans — verify Home Depot row: original 16995, saldo 15578.75, payment 1416.25, month 2 of 12.
  - parses_regularTransactions_titularSection — non-empty, count > 50 for this fixture.
  - parses_regularTransactions_supplementaryCard_tagsCardLast4 — verify rows tagged "7801".
  - signFlip_hsbcPlusBecomesNegativeStorage
  - reconciliation_periodTotalsMatch — sum of charges ≈ 29491.46, sum of abonos ≈ 26001.00, signed closing ≈ -45054.70.

  4.2 InstallmentPlanTests

  - Importing the same statement twice does not create duplicate InstallmentPlans; currentMonth updates.

  4.3 ConsolidatedDashboardTests

  - Given one credit-card statement + one debit statement with a matching SPEI on the same date, monthlyCashFlow shows zero net effect from the pair.
  - creditCardPayment transactions are absent from spendingByCategory.
  - Net worth = debit closing balance − credit-card debt.

  4.4 LiabilityDashboardTests

  - utilizationPercent computed correctly.
  - activeInstallmentPlans excludes plans with currentMonth >= totalMonths.
  - ChargesVsPaymentsChart totals match the parsed period totals.

  4.5 End-to-end

  - EndToEndTests/HsbcStatementImportTests — runs the full pipeline against samples/2026-05-08_Estado_de_cuenta.pdf, asserts: 1 Account created with type=.creditCard, creditLimit=465000; 1 Statement with the
  documented period totals; ≥ 80 Transactions including 1 marked as .creditCardPayment; 1 InstallmentPlan for HOME DEPOT.

  Phase 5 — Documentation

  - Update README.md: HSBC 2Now in the supported-institutions table; mention per-account dashboards.
  - Update CLAUDE.md: note the asset/liability split in dashboard snapshots and the sign convention for credit-card balances.
  - Append DECISIONS.md entries AD-009..AD-013 (one per AD-C1..AD-C5).
  - Update CHANGELOG.md.

  Phase 6 — Verification checklist

  Run before declaring done:
  1. xcodegen generate after any new file additions.
  2. xcodebuild -project FinanceTracker.xcodeproj -scheme FinanceTracker build — clean build.
  3. xcodebuild test -project FinanceTracker.xcodeproj -scheme FinanceTrackerTests -destination 'platform=macOS' — all existing tests still pass + new ones pass.
  4. Manually: launch app, import samples/2026-05-08_Estado_de_cuenta.pdf, switch sidebar scope to the HSBC account, verify: utilization shows ~9.7%, payment due 30-May-2026, Home Depot installment plan visible
   with 02 de 12, charges-vs-payments chart non-empty. Switch back to Overview: consolidated dashboard renders without duplicate transfers.

  Implementation order (recommended)

  Do these phases in sequence — each is shippable on its own:

  1. Phase 1 (model + migration) → smoke test the existing app still launches.
  2. Phase 2 (parser) → import the HSBC PDF, verify totals via tests, but UI may show liability oddly.
  3. Phase 3 (dashboard scope refactor) → introduce scope plumbing without splitting views yet (consolidated stays default).
  4. Phase 3.3–3.5 (liability views) → the user-visible payoff.
  5. Phase 4 (tests) — write as you go; the end-to-end test caps the work.
  6. Phase 5 (docs).

  Stop after each phase and report progress. Do not bundle phases into a single commit.