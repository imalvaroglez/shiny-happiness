import Foundation
import SwiftData
import Testing
@testable import FinanceTracker

@Suite("Transaction Links")
@MainActor
struct TransactionLinkTests {
    private func makeContainer() throws -> ModelContainer {
        let schema = AppSchema.schema
        return try ModelContainer(for: schema, configurations: [
            ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        ])
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(identifier: "America/Mexico_City")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    @Test("Refund received in a different account reduces the original purchase")
    func refundProjectionUsesPurchaseAndRefundAcrossAccounts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "American Express", type: .creditCard, currency: "MXN", nickname: "Platinum")
        let checking = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        let purchases = Category(name: "Purchases", kind: .expense)
        let refundIncome = Category(name: "Refund", kind: .income)
        let purchase = Transaction(
            account: card,
            postedAt: date(2026, 10, 4),
            amount: -1_200,
            descriptionRaw: "Mercado Libre",
            category: purchases,
            flowKindRaw: TransactionFlowKind.charge.rawValue,
            movementKindRaw: TransactionMovementKind.expense.rawValue
        )
        let refund = Transaction(
            account: checking,
            postedAt: date(2026, 11, 2),
            amount: 340,
            descriptionRaw: "Mercado Libre refund",
            category: refundIncome,
            flowKindRaw: TransactionFlowKind.income.rawValue,
            movementKindRaw: TransactionMovementKind.income.rawValue
        )
        [card, checking].forEach(context.insert)
        [purchases, refundIncome].forEach(context.insert)
        [purchase, refund].forEach(context.insert)
        try context.save()

        try TransactionLinkService.linkRefund(refund: refund, purchase: purchase, context: context, at: date(2026, 11, 2))

        let projection = try TransactionLinkService.refundProjection(
            for: purchase,
            context: context,
            asOf: date(2026, 11, 3)
        )
        #expect(projection.isValid)
        #expect(projection.refundedAmount == 340)
        #expect(projection.netExpenseAmount == 860)
        #expect(try TransactionLinkService.isAppliedRefund(refund, context: context, asOf: date(2026, 11, 3)))
    }

    @Test("Changing a purchase so it is smaller than its linked refunds suspends all adjustments")
    func editedPurchaseInvalidatesRefundProjection() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "American Express", type: .creditCard, currency: "MXN", nickname: "Platinum")
        let bank = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        let category = Category(name: "Purchases", kind: .expense)
        let purchase = Transaction(account: card, postedAt: date(2026, 10, 1), amount: -300,
                                   descriptionRaw: "Purchase", category: category,
                                   flowKindRaw: TransactionFlowKind.charge.rawValue,
                                   movementKindRaw: TransactionMovementKind.expense.rawValue)
        let refund = Transaction(account: bank, postedAt: date(2026, 10, 2), amount: 250,
                                 descriptionRaw: "Refund", flowKindRaw: TransactionFlowKind.income.rawValue,
                                 movementKindRaw: TransactionMovementKind.income.rawValue)
        [card, bank].forEach(context.insert)
        context.insert(category)
        [purchase, refund].forEach(context.insert)
        try context.save()
        try TransactionLinkService.linkRefund(refund: refund, purchase: purchase, context: context, at: date(2026, 10, 2))

        purchase.amount = -200
        try context.save()

        let projection = try TransactionLinkService.refundProjection(for: purchase, context: context, asOf: date(2026, 10, 3))
        #expect(!projection.isValid)
        #expect(projection.refundedAmount == 0)
        #expect(projection.netExpenseAmount == 200)
        let dashboardData = try TransactionLinkService.dashboardRefundData(
            for: [purchase, refund], context: context, asOf: date(2026, 10, 3)
        )
        #expect(dashboardData.refundedAmountByPurchaseID.isEmpty)
        #expect(dashboardData.linkedRefundIDs.isEmpty,
                "An invalid suspended link must not hide the credit from regular income")
    }

    @Test("Draft validation rejects refunds that cannot link before any movement is saved")
    func refundDraftValidationRejectsInvalidDrafts() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "American Express", type: .creditCard, currency: "MXN", nickname: "Platinum")
        let bank = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        let category = Category(name: "Purchases", kind: .expense)
        let purchase = Transaction(account: card, postedAt: date(2026, 10, 1), amount: -500,
                                   descriptionRaw: "Purchase", category: category,
                                   flowKindRaw: TransactionFlowKind.charge.rawValue,
                                   movementKindRaw: TransactionMovementKind.expense.rawValue)
        let partial = Transaction(account: bank, postedAt: date(2026, 10, 2), amount: 300,
                                  descriptionRaw: "Partial refund", flowKindRaw: TransactionFlowKind.income.rawValue,
                                  movementKindRaw: TransactionMovementKind.income.rawValue)
        context.insert(card)
        context.insert(bank)
        context.insert(category)
        context.insert(purchase)
        context.insert(partial)
        try context.save()
        try TransactionLinkService.linkRefund(refund: partial, purchase: purchase, context: context, at: date(2026, 10, 3))

        func draftError(amount: Decimal, currency: String = "MXN", postedAt: Date) -> TransactionLinkError? {
            do {
                try TransactionLinkService.validateRefundDraft(
                    amount: amount, currency: currency, postedAt: postedAt,
                    purchase: purchase, context: context
                )
                return nil
            } catch let error as TransactionLinkError {
                return error
            } catch {
                Issue.record("Unexpected draft validation error: \(error)")
                return nil
            }
        }

        #expect(draftError(amount: 200, postedAt: date(2026, 10, 4)) == nil)
        #expect(draftError(amount: 201, postedAt: date(2026, 10, 4)) == .refundExceedsPurchase)
        #expect(draftError(amount: 200, currency: "USD", postedAt: date(2026, 10, 4)) == .invalidRefund)
        #expect(draftError(amount: 200, postedAt: date(2026, 9, 30)) == .invalidRefund)
        #expect(draftError(amount: 0, postedAt: date(2026, 10, 4)) == .invalidRefund)
    }

    @Test("Refund link summary tracks remaining amounts, linked refunds, and current targets")
    func refundLinkSummaryFeedsPickerCandidates() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "American Express", type: .creditCard, currency: "MXN", nickname: "Platinum")
        let bank = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        let category = Category(name: "Purchases", kind: .expense)
        let partiallyRefunded = Transaction(account: card, postedAt: date(2026, 10, 1), amount: -500,
                                            descriptionRaw: "Partial", category: category,
                                            flowKindRaw: TransactionFlowKind.charge.rawValue,
                                            movementKindRaw: TransactionMovementKind.expense.rawValue)
        let fullyRefunded = Transaction(account: card, postedAt: date(2026, 10, 2), amount: -200,
                                        descriptionRaw: "Full", category: category,
                                        flowKindRaw: TransactionFlowKind.charge.rawValue,
                                        movementKindRaw: TransactionMovementKind.expense.rawValue)
        let laterPurchase = Transaction(account: card, postedAt: date(2026, 11, 5), amount: -800,
                                        descriptionRaw: "Later", category: category,
                                        flowKindRaw: TransactionFlowKind.charge.rawValue,
                                        movementKindRaw: TransactionMovementKind.expense.rawValue)
        let firstRefund = Transaction(account: bank, postedAt: date(2026, 10, 3), amount: 300,
                                      descriptionRaw: "First", flowKindRaw: TransactionFlowKind.income.rawValue,
                                      movementKindRaw: TransactionMovementKind.income.rawValue)
        let secondRefund = Transaction(account: bank, postedAt: date(2026, 10, 4), amount: 200,
                                       descriptionRaw: "Second", flowKindRaw: TransactionFlowKind.income.rawValue,
                                       movementKindRaw: TransactionMovementKind.income.rawValue)
        [card, bank].forEach(context.insert)
        context.insert(category)
        [partiallyRefunded, fullyRefunded, laterPurchase, firstRefund, secondRefund].forEach(context.insert)
        try context.save()
        try TransactionLinkService.linkRefund(refund: firstRefund, purchase: partiallyRefunded, context: context, at: date(2026, 10, 5))
        try TransactionLinkService.linkRefund(refund: secondRefund, purchase: fullyRefunded, context: context, at: date(2026, 10, 5))

        let summary = try TransactionLinkService.refundLinkSummary(context: context, asOf: date(2026, 11, 17))
        #expect(summary.remainingByPurchaseID[partiallyRefunded.id] == 200)
        #expect(summary.remainingByPurchaseID[fullyRefunded.id] == 0)
        #expect(summary.linkedRefundIDs == [firstRefund.id, secondRefund.id])
        #expect(summary.activeTargetByRefundID[firstRefund.id] == partiallyRefunded.id)
        #expect(summary.activeTargetByRefundID[secondRefund.id] == fullyRefunded.id)

        // Candidate pipeline: a draft refund (nov 2, MXN) may link to the
        // partially refunded purchase only — the full one has no room left and
        // the later purchase postdates the draft.
        let candidates = TransactionLinkCandidates.purchaseDraftCandidates(
            from: [partiallyRefunded, fullyRefunded, laterPurchase],
            context: .init(
                currency: "MXN",
                postedAt: date(2026, 11, 2),
                remainingByPurchaseID: summary.remainingByPurchaseID
            )
        )
        #expect(candidates.map(\.id) == [partiallyRefunded.id])

        // Refunds already linked elsewhere are not offered to another purchase.
        let refundCandidates = TransactionLinkCandidates.refunds(
            forPurchase: laterPurchase,
            from: [firstRefund, secondRefund],
            excludingRefundIDs: summary.linkedRefundIDs
        )
        #expect(refundCandidates.isEmpty)
    }

    @Test("Picker pipeline applies account filter, search, and sort modes deterministically")
    func pickerPipelineFiltersSortsAndSearches() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let bank = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        let card = Account(institution: "American Express", type: .creditCard, currency: "MXN", nickname: "Platinum")
        let alfa = Transaction(account: card, postedAt: date(2026, 10, 1), amount: -100,
                               descriptionRaw: "Alfa purchase", merchantNormalized: "alfa",
                               flowKindRaw: TransactionFlowKind.charge.rawValue,
                               movementKindRaw: TransactionMovementKind.expense.rawValue)
        let beta = Transaction(account: bank, postedAt: date(2026, 10, 5), amount: -900,
                               descriptionRaw: "Beta purchase", merchantNormalized: "beta",
                               flowKindRaw: TransactionFlowKind.expense.rawValue,
                               movementKindRaw: TransactionMovementKind.expense.rawValue)
        let gamma = Transaction(account: card, postedAt: date(2026, 9, 20), amount: -500,
                                descriptionRaw: "Gamma purchase", merchantNormalized: "gamma",
                                flowKindRaw: TransactionFlowKind.charge.rawValue,
                                movementKindRaw: TransactionMovementKind.expense.rawValue)
        [bank, card].forEach(context.insert)
        [alfa, beta, gamma].forEach(context.insert)
        try context.save()

        let all = [alfa, beta, gamma]
        #expect(TransactionLinkCandidates.apply(searchText: "", accountFilterID: nil, sort: .dateDesc, to: all).map(\.id)
                == [beta.id, alfa.id, gamma.id], "Default order is newest → oldest")
        #expect(TransactionLinkCandidates.apply(searchText: "", accountFilterID: nil, sort: .dateAsc, to: all).map(\.id)
                == [gamma.id, alfa.id, beta.id])
        #expect(TransactionLinkCandidates.apply(searchText: "", accountFilterID: nil, sort: .amountDesc, to: all).map(\.id)
                == [beta.id, gamma.id, alfa.id], "Amount compares absolute magnitude")
        #expect(TransactionLinkCandidates.apply(searchText: "", accountFilterID: nil, sort: .amountAsc, to: all).map(\.id)
                == [alfa.id, gamma.id, beta.id])
        #expect(TransactionLinkCandidates.apply(searchText: "", accountFilterID: nil, sort: .conceptAsc, to: all).map(\.id)
                == [alfa.id, beta.id, gamma.id])
        #expect(TransactionLinkCandidates.apply(searchText: "beta", accountFilterID: nil, sort: .dateDesc, to: all).map(\.id)
                == [beta.id], "Search matches the description")
        #expect(TransactionLinkCandidates.apply(searchText: "", accountFilterID: card.id, sort: .dateDesc, to: all).map(\.id)
                == [alfa.id, gamma.id], "Account filter narrows to the card")
    }

    @Test("Dashboard assigns a linked refund to purchase spending while cash flow keeps the refund date")
    func dashboardAttributesRefundToPurchaseMonth() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "American Express", type: .creditCard, currency: "MXN", nickname: "Platinum")
        let checking = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        let purchases = Category(name: "Purchases", kind: .expense)
        let refundIncome = Category(name: "Refund", kind: .income)
        let purchase = Transaction(account: card, postedAt: date(2026, 10, 4), amount: -1_200,
                                   descriptionRaw: "Mercado Libre", category: purchases,
                                   flowKindRaw: TransactionFlowKind.charge.rawValue,
                                   movementKindRaw: TransactionMovementKind.expense.rawValue)
        let refund = Transaction(account: checking, postedAt: date(2026, 11, 2), amount: 340,
                                 descriptionRaw: "Mercado Libre refund", category: refundIncome,
                                 flowKindRaw: TransactionFlowKind.income.rawValue,
                                 movementKindRaw: TransactionMovementKind.income.rawValue)
        [card, checking].forEach(context.insert)
        [purchases, refundIncome].forEach(context.insert)
        [purchase, refund].forEach(context.insert)
        try context.save()

        let viewModel = DashboardViewModel()
        viewModel.configure(context: context)
        viewModel.setPeriod(.custom, customRange: DateRange(start: date(2026, 10, 1), end: date(2026, 10, 31)), now: date(2026, 11, 17))
        viewModel.refresh()
        guard case .consolidated(let beforeLink) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot before linking")
            return
        }
        #expect(beforeLink.totalExpenses == -1_200)

        try TransactionLinkService.linkRefund(refund: refund, purchase: purchase, context: context, at: date(2026, 11, 3))
        viewModel.refreshAfterDataChange(now: date(2026, 11, 17))
        guard case .consolidated(let purchaseMonth) = viewModel.snapshot else {
            Issue.record("Expected consolidated purchase-month snapshot")
            return
        }
        #expect(purchaseMonth.totalExpenses == -860)
        #expect(purchaseMonth.spendingByCategory.first { $0.category.id == purchases.id }?.amount == 860)
        #expect(purchaseMonth.refundsByPurchaseID[purchase.id]?.map(\.id) == [refund.id])

        let travel = Category(name: "Travel", kind: .expense)
        context.insert(travel)
        purchase.category = travel
        try context.save()
        viewModel.refreshAfterDataChange(now: date(2026, 11, 17))
        guard case .consolidated(let recategorizedPurchaseMonth) = viewModel.snapshot else {
            Issue.record("Expected consolidated snapshot after purchase recategorization")
            return
        }
        #expect(recategorizedPurchaseMonth.totalExpenses == -860)
        #expect(recategorizedPurchaseMonth.spendingByCategory.first?.category.id == travel.id)

        viewModel.setPeriod(.custom, customRange: DateRange(start: date(2026, 11, 1), end: date(2026, 11, 30)), now: date(2026, 11, 17))
        viewModel.refresh()
        guard case .consolidated(let refundMonth) = viewModel.snapshot else {
            Issue.record("Expected consolidated refund-month snapshot")
            return
        }
        #expect(refundMonth.totalIncome == 0)
        #expect(refundMonth.cashFlowIncome == 340)
    }

    @Test("Multiple partial refunds may equal but never exceed the purchase amount")
    func multiplePartialRefundsRespectPurchaseAmount() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "American Express", type: .creditCard, currency: "MXN", nickname: "Platinum")
        let checking = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        let category = Category(name: "Purchases", kind: .expense)
        let purchase = Transaction(account: card, postedAt: date(2026, 10, 1), amount: -1_200,
                                   descriptionRaw: "Purchase", category: category,
                                   flowKindRaw: TransactionFlowKind.charge.rawValue,
                                   movementKindRaw: TransactionMovementKind.expense.rawValue)
        let firstRefund = Transaction(account: checking, postedAt: date(2026, 10, 2), amount: 500,
                                      descriptionRaw: "First refund", flowKindRaw: TransactionFlowKind.income.rawValue,
                                      movementKindRaw: TransactionMovementKind.income.rawValue)
        let secondRefund = Transaction(account: checking, postedAt: date(2026, 10, 3), amount: 700,
                                       descriptionRaw: "Second refund", flowKindRaw: TransactionFlowKind.income.rawValue,
                                       movementKindRaw: TransactionMovementKind.income.rawValue)
        let excessRefund = Transaction(account: checking, postedAt: date(2026, 10, 4), amount: 1,
                                       descriptionRaw: "Excess refund", flowKindRaw: TransactionFlowKind.income.rawValue,
                                       movementKindRaw: TransactionMovementKind.income.rawValue)
        [card, checking].forEach(context.insert)
        context.insert(category)
        [purchase, firstRefund, secondRefund, excessRefund].forEach(context.insert)
        try context.save()

        try TransactionLinkService.linkRefund(refund: firstRefund, purchase: purchase, context: context, at: date(2026, 10, 5))
        try TransactionLinkService.linkRefund(refund: secondRefund, purchase: purchase, context: context, at: date(2026, 10, 5))
        #expect(throws: TransactionLinkError.refundExceedsPurchase) {
            try TransactionLinkService.linkRefund(refund: excessRefund, purchase: purchase, context: context, at: date(2026, 10, 5))
        }
        let projection = try TransactionLinkService.refundProjection(for: purchase, context: context, asOf: date(2026, 10, 5))
        #expect(projection.isValid)
        #expect(projection.refundedAmount == 1_200)
        #expect(projection.netExpenseAmount == 0)

        try TransactionLinkService.removeRefund(refund: secondRefund, context: context, at: date(2026, 10, 6))
        let afterRemoval = try TransactionLinkService.refundProjection(for: purchase, context: context, asOf: date(2026, 10, 6))
        #expect(afterRemoval.refundedAmount == 500)
        #expect(afterRemoval.netExpenseAmount == 700)
    }

    @Test("A credit posted to the same card qualifies as a refund")
    func sameCardRefundIsEligible() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "American Express", type: .creditCard, currency: "MXN", nickname: "Platinum")
        let category = Category(name: "Purchases", kind: .expense)
        let purchase = Transaction(account: card, postedAt: date(2026, 10, 1), amount: -500,
                                   descriptionRaw: "Purchase", category: category,
                                   flowKindRaw: TransactionFlowKind.charge.rawValue,
                                   movementKindRaw: TransactionMovementKind.expense.rawValue)
        let refund = Transaction(account: card, postedAt: date(2026, 10, 4), amount: 125,
                                 descriptionRaw: "Card credit",
                                 flowKindRaw: TransactionFlowKind.cardCredit.rawValue,
                                 movementKindRaw: TransactionMovementKind.adjustment.rawValue)
        context.insert(card)
        context.insert(category)
        context.insert(purchase)
        context.insert(refund)
        try context.save()

        try TransactionLinkService.linkRefund(refund: refund, purchase: purchase, context: context, at: date(2026, 10, 5))
        let projection = try TransactionLinkService.refundProjection(for: purchase, context: context, asOf: date(2026, 10, 5))
        #expect(projection.isValid)
        #expect(projection.netExpenseAmount == 375)
        #expect(try TransactionLinkService.isAppliedRefund(refund, context: context, asOf: date(2026, 10, 5)))
    }

    @Test("A refund can be reassigned to a different purchase using its stable identity")
    func refundCanChangeLinkedPurchase() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "American Express", type: .creditCard, currency: "MXN", nickname: "Platinum")
        let bank = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        let category = Category(name: "Purchases", kind: .expense)
        let firstPurchase = Transaction(account: card, postedAt: date(2026, 10, 1), amount: -500,
                                        descriptionRaw: "First purchase", category: category,
                                        flowKindRaw: TransactionFlowKind.charge.rawValue,
                                        movementKindRaw: TransactionMovementKind.expense.rawValue)
        let secondPurchase = Transaction(account: card, postedAt: date(2026, 10, 2), amount: -700,
                                         descriptionRaw: "Second purchase", category: category,
                                         flowKindRaw: TransactionFlowKind.charge.rawValue,
                                         movementKindRaw: TransactionMovementKind.expense.rawValue)
        let refund = Transaction(account: bank, postedAt: date(2026, 10, 3), amount: 300,
                                 descriptionRaw: "Refund", flowKindRaw: TransactionFlowKind.income.rawValue,
                                 movementKindRaw: TransactionMovementKind.income.rawValue)
        [card, bank].forEach(context.insert)
        context.insert(category)
        [firstPurchase, secondPurchase, refund].forEach(context.insert)
        try context.save()

        try TransactionLinkService.linkRefund(refund: refund, purchase: firstPurchase, context: context, at: date(2026, 10, 4))
        let originalID = try #require(try context.fetch(FetchDescriptor<TransactionLink>()).first?.id)
        try TransactionLinkService.linkRefund(refund: refund, purchase: secondPurchase, context: context, at: date(2026, 10, 5))

        let links = try context.fetch(FetchDescriptor<TransactionLink>())
        #expect(links.count == 1)
        #expect(links.first?.id == originalID)
        #expect(links.first?.targetTransactionID == secondPurchase.id)
        #expect(try TransactionLinkService.refundProjection(for: firstPurchase, context: context, asOf: date(2026, 10, 6)).refundedAmount == 0)
        #expect(try TransactionLinkService.refundProjection(for: secondPurchase, context: context, asOf: date(2026, 10, 6)).refundedAmount == 300)
    }

    @Test("Soft deletion suspends an applied refund until both movements are restored")
    func deletedLinkedMovementsSuspendRefunds() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "American Express", type: .creditCard, currency: "MXN", nickname: "Platinum")
        let bank = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        let category = Category(name: "Purchases", kind: .expense)
        let purchase = Transaction(account: card, postedAt: date(2026, 10, 1), amount: -500,
                                   descriptionRaw: "Purchase", category: category,
                                   flowKindRaw: TransactionFlowKind.charge.rawValue,
                                   movementKindRaw: TransactionMovementKind.expense.rawValue)
        let refund = Transaction(account: bank, postedAt: date(2026, 10, 2), amount: 100,
                                 descriptionRaw: "Refund", flowKindRaw: TransactionFlowKind.income.rawValue,
                                 movementKindRaw: TransactionMovementKind.income.rawValue)
        [card, bank].forEach(context.insert)
        context.insert(category)
        [purchase, refund].forEach(context.insert)
        try context.save()
        try TransactionLinkService.linkRefund(refund: refund, purchase: purchase, context: context, at: date(2026, 10, 3))

        refund.deletedAt = date(2026, 10, 4)
        try context.save()
        let deletedRefundProjection = try TransactionLinkService.refundProjection(for: purchase, context: context, asOf: date(2026, 10, 5))
        #expect(!deletedRefundProjection.isValid)
        #expect(deletedRefundProjection.refundedAmount == 0)

        refund.deletedAt = nil
        purchase.deletedAt = date(2026, 10, 6)
        try context.save()
        let deletedPurchaseProjection = try TransactionLinkService.refundProjection(for: purchase, context: context, asOf: date(2026, 10, 7))
        #expect(!deletedPurchaseProjection.isValid)
        #expect(deletedPurchaseProjection.refundedAmount == 0)

        purchase.deletedAt = nil
        try context.save()
        let restoredProjection = try TransactionLinkService.refundProjection(for: purchase, context: context, asOf: date(2026, 10, 8))
        #expect(restoredProjection.isValid)
        #expect(restoredProjection.refundedAmount == 100)
    }

    @Test("A duplicated active refund identity cannot reduce two purchases")
    func duplicateActiveRefundLinkIsSuspended() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "American Express", type: .creditCard, currency: "MXN", nickname: "Platinum")
        let bank = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        let category = Category(name: "Purchases", kind: .expense)
        let firstPurchase = Transaction(account: card, postedAt: date(2026, 10, 1), amount: -500,
                                        descriptionRaw: "First", category: category,
                                        flowKindRaw: TransactionFlowKind.charge.rawValue,
                                        movementKindRaw: TransactionMovementKind.expense.rawValue)
        let secondPurchase = Transaction(account: card, postedAt: date(2026, 10, 2), amount: -500,
                                         descriptionRaw: "Second", category: category,
                                         flowKindRaw: TransactionFlowKind.charge.rawValue,
                                         movementKindRaw: TransactionMovementKind.expense.rawValue)
        let refund = Transaction(account: bank, postedAt: date(2026, 10, 3), amount: 100,
                                 descriptionRaw: "Refund", flowKindRaw: TransactionFlowKind.income.rawValue,
                                 movementKindRaw: TransactionMovementKind.income.rawValue)
        [card, bank].forEach(context.insert)
        context.insert(category)
        [firstPurchase, secondPurchase, refund].forEach(context.insert)
        let identityKey = TransactionLinkService.refundIdentityKey(refundID: refund.id)
        context.insert(TransactionLink(id: UUID(), identityKey: identityKey, kind: .refund,
                                       sourceTransactionID: refund.id, targetTransactionID: firstPurchase.id,
                                       lastModifiedAt: date(2026, 10, 4)))
        context.insert(TransactionLink(id: UUID(), identityKey: identityKey, kind: .refund,
                                       sourceTransactionID: refund.id, targetTransactionID: secondPurchase.id,
                                       lastModifiedAt: date(2026, 10, 5)))
        try context.save()

        let data = try TransactionLinkService.dashboardRefundData(
            for: [firstPurchase, secondPurchase, refund], context: context, asOf: date(2026, 10, 6)
        )
        #expect(data.refundedAmountByPurchaseID.isEmpty)
        #expect(data.linkedRefundIDs.isEmpty)
        #expect(!(try TransactionLinkService.refundProjection(for: firstPurchase, context: context, asOf: date(2026, 10, 6)).isValid))
        #expect(!(try TransactionLinkService.refundProjection(for: secondPurchase, context: context, asOf: date(2026, 10, 6)).isValid))
    }

    @Test("Selector and dashboard refund calculations stay responsive on a representative ledger")
    func refundFeaturePerformanceOnRepresentativeLedger() throws {
        let container = try makeContainer()
        let context = container.mainContext
        let card = Account(institution: "American Express", type: .creditCard, currency: "MXN", nickname: "Platinum")
        let bank = Account(institution: "Bank", type: .checking, currency: "MXN", nickname: "Checking")
        let purchaseCategory = Category(name: "Purchases", kind: .expense)
        let incomeCategory = Category(name: "Refunds", kind: .income)
        context.insert(card)
        context.insert(bank)
        context.insert(purchaseCategory)
        context.insert(incomeCategory)

        let baseDate = date(2023, 1, 1)
        var movements: [Transaction] = []
        var links: [TransactionLink] = []
        for index in 0..<400 {
            let purchaseDate = baseDate.addingTimeInterval(TimeInterval(index * 86_400))
            let purchase = Transaction(account: card, postedAt: purchaseDate, amount: -1_200,
                                       descriptionRaw: "Mercado Libre order \(index)", category: purchaseCategory,
                                       flowKindRaw: TransactionFlowKind.charge.rawValue,
                                       movementKindRaw: TransactionMovementKind.expense.rawValue)
            let refund = Transaction(account: bank, postedAt: purchaseDate.addingTimeInterval(86_400), amount: 340,
                                     descriptionRaw: "Mercado Libre refund \(index)", category: incomeCategory,
                                     flowKindRaw: TransactionFlowKind.income.rawValue,
                                     movementKindRaw: TransactionMovementKind.income.rawValue)
            movements.append(contentsOf: [purchase, refund])
            let identityKey = TransactionLinkService.refundIdentityKey(refundID: refund.id)
            links.append(TransactionLink(
                id: TransactionLink.stableID(for: identityKey),
                identityKey: identityKey,
                kind: .refund,
                sourceTransactionID: refund.id,
                targetTransactionID: purchase.id,
                lastModifiedAt: purchaseDate.addingTimeInterval(2 * 86_400)
            ))
        }
        movements.forEach(context.insert)
        links.forEach(context.insert)
        try context.save()

        let selectorStart = ContinuousClock.now
        let selectorRows = try context.fetch(FetchDescriptor<Transaction>(
            predicate: #Predicate { $0.deletedAt == nil && $0.account != nil },
            sortBy: [SortDescriptor(\.postedAt, order: .reverse)]
        ))
        let selectorPurchase = try #require(selectorRows.filter { $0.amount < 0 }.min { $0.postedAt < $1.postedAt })
        let selectorOpenStart = ContinuousClock.now
        let purchaseIsEligible = TransactionLinkService.isEligiblePurchaseCandidate(selectorPurchase)
        let openCandidates = selectorRows.filter {
            $0.id != selectorPurchase.id
                && purchaseIsEligible
                && TransactionLinkService.isEligibleRefundCandidate($0, for: selectorPurchase, purchaseIsEligible: true)
        }
        let selectorOpenDuration = selectorOpenStart.duration(to: .now)
        let selectorSearchStart = ContinuousClock.now
        let searchResults = selectorRows.filter {
            $0.descriptionRaw.localizedCaseInsensitiveContains("Mercado Libre refund 399")
                && purchaseIsEligible
                && TransactionLinkService.isEligibleRefundCandidate($0, for: selectorPurchase, purchaseIsEligible: true)
        }
        let selectorSearchDuration = selectorSearchStart.duration(to: .now)
        let selectorDuration = selectorStart.duration(to: .now)

        let board = DashboardViewModel()
        board.setPeriod(.all, now: date(2026, 11, 17))
        let dashboardStart = ContinuousClock.now
        board.configure(context: context)
        let dashboardDuration = dashboardStart.duration(to: .now)
        let dashboardUpdateStart = ContinuousClock.now
        board.refreshAfterTransactionLinksChanged(now: date(2026, 11, 17))
        let dashboardUpdateDuration = dashboardUpdateStart.duration(to: .now)
        board.scope = .account(card.id)
        let liabilityStart = ContinuousClock.now
        board.refresh()
        let liabilityDuration = liabilityStart.duration(to: .now)
        board.scope = .account(bank.id)
        let assetStart = ContinuousClock.now
        board.refresh()
        let assetDuration = assetStart.duration(to: .now)
        let projectionStart = ContinuousClock.now
        let refundData = try TransactionLinkService.dashboardRefundData(
            for: selectorRows,
            context: context,
            asOf: date(2026, 11, 17)
        )
        let projectionDuration = projectionStart.duration(to: .now)
        let summaryStart = ContinuousClock.now
        let linkSummary = try TransactionLinkService.refundLinkSummary(context: context, asOf: date(2026, 11, 17))
        let summaryDuration = summaryStart.duration(to: .now)

        func milliseconds(_ duration: Duration) -> Double {
            let parts = duration.components
            return Double(parts.seconds) * 1_000 + Double(parts.attoseconds) / 1_000_000_000_000_000
        }
        let refundCount = refundData.refundedAmountByPurchaseID.count
        #expect(selectorRows.count == 800)
        #expect(openCandidates.count == 400)
        #expect(searchResults.count == 1)
        #expect(refundCount == 400)
        #expect(linkSummary.remainingByPurchaseID.count == 400)
        print("TRANSACTION_LINK_PERF selector_fetch_ms=\(milliseconds(selectorDuration)) selector_open_filter_ms=\(milliseconds(selectorOpenDuration)) selector_search_ms=\(milliseconds(selectorSearchDuration)) refund_projection_ms=\(milliseconds(projectionDuration)) link_summary_ms=\(milliseconds(summaryDuration)) consolidated_refresh_ms=\(milliseconds(dashboardDuration)) link_only_update_ms=\(milliseconds(dashboardUpdateDuration)) liability_refresh_ms=\(milliseconds(liabilityDuration)) asset_refresh_ms=\(milliseconds(assetDuration)) rows=800 links=400")
    }
}
