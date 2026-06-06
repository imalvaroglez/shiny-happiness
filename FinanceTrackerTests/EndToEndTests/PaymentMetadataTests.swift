import Foundation
import SwiftData
import Testing
@testable import FinanceTracker

@Suite("Payment Metadata")
@MainActor
struct PaymentMetadataTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self,
            AccountBalanceSnapshot.self,
            Transaction.self,
            Statement.self,
            FinanceTracker.Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    @Test("Upsert creates statement with nil closing balance")
    func upsertCreatesNilClosingBalance() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "Issuer", type: .creditCard, currency: "MXN", nickname: "Card")
        context.insert(card)
        try context.save()

        let mayDue = dateFromComponents(year: 2026, month: 5, day: 20)
        try PaymentMetadataService.upsert(
            account: card,
            billingMonth: dateFromComponents(year: 2026, month: 5, day: 1),
            dueDate: mayDue,
            paymentForNoInterest: 5_000,
            context: context
        )

        let hash = PaymentMetadataService.metadataHash(accountId: card.id, year: 2026, month: 5)
        let metaDescriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.sourceFileHash == hash }
        )
        let meta = try context.fetch(metaDescriptor).first
        #expect(meta != nil, "Metadata statement should exist")
        #expect(meta?.closingBalance == nil, "Metadata statement should have nil closingBalance")
        #expect(meta?.paymentDueDate == mayDue)
        #expect(meta?.paymentForNoInterest == 5_000)
    }

    @Test("Metadata statement is not a balance anchor")
    func metadataStatementIsNotBalanceAnchor() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "Issuer", type: .creditCard, currency: "MXN", nickname: "Card")
        context.insert(card)
        try context.save()

        try PaymentMetadataService.upsert(
            account: card,
            billingMonth: dateFromComponents(year: 2026, month: 5, day: 1),
            dueDate: dateFromComponents(year: 2026, month: 5, day: 20),
            paymentForNoInterest: 3_000,
            context: context
        )

        let anchors = AccountBalanceResolver.allAnchors(accountId: card.id, context: context)
        let statementAnchors = anchors.filter {
            if case .statement = $0.source { return true }
            return false
        }
        #expect(statementAnchors.isEmpty, "Metadata statement should not be a balance anchor")
    }

    @Test("Same account and month updates existing metadata")
    func sameMonthUpdatesExisting() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "Issuer", type: .creditCard, currency: "MXN", nickname: "Card")
        context.insert(card)
        try context.save()

        let may1 = dateFromComponents(year: 2026, month: 5, day: 1)
        try PaymentMetadataService.upsert(
            account: card,
            billingMonth: may1,
            dueDate: dateFromComponents(year: 2026, month: 5, day: 15),
            paymentForNoInterest: 3_000,
            context: context
        )
        try PaymentMetadataService.upsert(
            account: card,
            billingMonth: may1,
            dueDate: dateFromComponents(year: 2026, month: 5, day: 20),
            paymentForNoInterest: 4_000,
            context: context
        )

        let hash = PaymentMetadataService.metadataHash(accountId: card.id, year: 2026, month: 5)
        let metaDescriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.sourceFileHash == hash }
        )
        let metaStatements = try context.fetch(metaDescriptor)
        #expect(metaStatements.count == 1, "Should have one metadata statement for the month")
        #expect(metaStatements.first?.paymentDueDate == dateFromComponents(year: 2026, month: 5, day: 20))
        #expect(metaStatements.first?.paymentForNoInterest == 4_000)
    }

    @Test("Different billing months preserve separate metadata")
    func differentMonthsPreservedSeparately() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "Issuer", type: .creditCard, currency: "MXN", nickname: "Card")
        context.insert(card)
        try context.save()

        try PaymentMetadataService.upsert(
            account: card,
            billingMonth: dateFromComponents(year: 2026, month: 4, day: 1),
            dueDate: dateFromComponents(year: 2026, month: 4, day: 20),
            paymentForNoInterest: 2_000,
            context: context
        )
        try PaymentMetadataService.upsert(
            account: card,
            billingMonth: dateFromComponents(year: 2026, month: 5, day: 1),
            dueDate: dateFromComponents(year: 2026, month: 5, day: 20),
            paymentForNoInterest: 5_000,
            context: context
        )

        let aprHash = PaymentMetadataService.metadataHash(accountId: card.id, year: 2026, month: 4)
        let mayHash = PaymentMetadataService.metadataHash(accountId: card.id, year: 2026, month: 5)
        let aprDescriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.sourceFileHash == aprHash }
        )
        let mayDescriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.sourceFileHash == mayHash }
        )
        let aprMeta = try context.fetch(aprDescriptor).first
        let mayMeta = try context.fetch(mayDescriptor).first

        #expect(aprMeta != nil, "April metadata should exist")
        #expect(mayMeta != nil, "May metadata should exist")
        #expect(aprMeta?.id != mayMeta?.id, "April and May should be separate statements")
        #expect(aprMeta?.paymentForNoInterest == 2_000)
        #expect(aprMeta?.paymentDueDate == dateFromComponents(year: 2026, month: 4, day: 20))
        #expect(mayMeta?.paymentForNoInterest == 5_000)
        #expect(mayMeta?.paymentDueDate == dateFromComponents(year: 2026, month: 5, day: 20))
    }

    @Test("Metadata-only statements excluded from source summaries")
    func metadataExcludedFromSourceSummaries() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "Issuer", type: .creditCard, currency: "MXN", nickname: "Card")
        context.insert(card)
        try context.save()

        let realStatement = Statement(
            account: card,
            periodStart: dateFromComponents(year: 2026, month: 4, day: 1),
            periodEnd: dateFromComponents(year: 2026, month: 4, day: 30),
            sourceFileHash: "real-statement-hash",
            sourceFileName: "april.pdf",
            closingBalance: -5_000,
            paymentForNoInterest: 4_500,
            paymentDueDate: dateFromComponents(year: 2026, month: 5, day: 15)
        )
        context.insert(realStatement)
        try context.save()

        try PaymentMetadataService.upsert(
            account: card,
            billingMonth: dateFromComponents(year: 2026, month: 5, day: 1),
            dueDate: dateFromComponents(year: 2026, month: 6, day: 15),
            paymentForNoInterest: 3_000,
            context: context
        )

        let viewModel = DashboardViewModel()
        viewModel.dateRange = DateRange(start: .distantPast, end: .distantFuture)
        viewModel.scope = .account(card.id)
        viewModel.configure(context: context)

        guard case .liability(let snap) = viewModel.snapshot else {
            Issue.record("Expected liability snapshot"); return
        }

        #expect(snap.sourceStatements.count == 1, "Should only show real statement, got \(snap.sourceStatements.count)")
        #expect(snap.sourceStatements.first?.sourceFileName == "april.pdf")
    }

    private func dateFromComponents(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return Calendar(identifier: .gregorian).date(from: components)!
    }
}
