import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

/// 0.6.0 retirement-aware dashboard math and breakdown partitioning.
///
/// The Liquid Net Worth / Retirement Assets formulas live inline in
/// `DashboardViewModel.computeNetWorth`; these tests mirror those formulas over
/// hand-built `AccountSummary` values and exercise the pure
/// `AccountSummarySection.bucket(for:)` partition directly.
@Suite("Retirement Dashboard")
@MainActor
struct RetirementDashboardTests {
    private func date(_ year: Int = 2026, _ month: Int = 6, _ day: Int = 1) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(identifier: "America/Mexico_City")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func summary(
        type: AccountType,
        latestBalance: Decimal,
        liquidity: AccountLiquidity = .liquid,
        retirementKind: RetirementKind? = nil,
        sourceKind: AccountBalanceResolution.SourceKind = .reconstructedBalance
    ) -> AccountSummary {
        AccountSummary(
            id: UUID(),
            displayName: "Account",
            institution: "Bank",
            type: type,
            currency: "MXN",
            latestBalance: latestBalance,
            balanceAsOf: date(),
            balanceSourceKind: sourceKind,
            balanceSourceDate: nil,
            creditLimit: nil,
            utilizationPercent: nil,
            liquidity: liquidity,
            retirementKind: retirementKind
        )
    }

    /// Mirrors `DashboardViewModel.computeNetWorth`'s scalar formulas.
    private func retirementAssets(_ summaries: [AccountSummary]) -> Decimal {
        summaries
            .filter { $0.balanceSourceKind != .insufficientHistory && $0.type == .retirement }
            .reduce(Decimal.zero) { $0 + $1.latestBalance }
    }

    private func liquidNetWorth(_ summaries: [AccountSummary]) -> Decimal {
        summaries
            .filter { $0.balanceSourceKind != .insufficientHistory }
            .filter { $0.isLiability || (!$0.isLiability && $0.type != .retirement && $0.liquidity == .liquid) }
            .reduce(Decimal.zero) { $0 + $1.latestBalance }
    }

    private func netWorth(_ summaries: [AccountSummary]) -> Decimal {
        summaries
            .filter { $0.balanceSourceKind != .insufficientHistory }
            .reduce(Decimal.zero) { $0 + $1.latestBalance }
    }

    @Test("Liquid/Retirement math across four buckets")
    func liquidRetirementMath() throws {
        // checking (liquid +1000), retirement (+5000), credit-card liability (−300),
        // restricted investment (+800 → Other Assets).
        let summaries = [
            summary(type: .checking, latestBalance: 1000),
            summary(type: .retirement, latestBalance: 5000, liquidity: .restricted, retirementKind: .ppr),
            summary(type: .creditCard, latestBalance: -300),
            summary(type: .investment, latestBalance: 800, liquidity: .restricted)
        ]

        #expect(retirementAssets(summaries) == 5000)
        #expect(liquidNetWorth(summaries) == 700)            // 1000 + (−300)
        #expect(netWorth(summaries) == 6500)                 // 1000 + 5000 − 300 + 800

        // liquid + retirement omits the 800 Other-Assets term, so it is NOT net worth.
        #expect(liquidNetWorth(summaries) + retirementAssets(summaries) == 5700)
        #expect(liquidNetWorth(summaries) + retirementAssets(summaries) != netWorth(summaries))
    }

    @Test("Insufficient-history retirement row contributes zero to retirement assets")
    func insufficientHistoryRetirement() throws {
        let summaries = [
            summary(type: .checking, latestBalance: 1000),
            summary(type: .retirement, latestBalance: 5000, liquidity: .restricted, retirementKind: .ppr,
                    sourceKind: .insufficientHistory)
        ]
        #expect(retirementAssets(summaries) == 0)
        #expect(netWorth(summaries) == 1000)
    }

    @Test("Breakdown partition subtotals sum to net worth; insufficient row is unbucketed")
    func partitionSumsToNetWorth() throws {
        let summaries = [
            summary(type: .checking, latestBalance: 1000),
            summary(type: .retirement, latestBalance: 5000, liquidity: .restricted, retirementKind: .ppr),
            summary(type: .creditCard, latestBalance: -300),
            summary(type: .investment, latestBalance: 800, liquidity: .restricted),
            summary(type: .savings, latestBalance: 999, sourceKind: .insufficientHistory)
        ]

        // Mirror BreakdownSheet: bucket only known (non-insufficient) summaries.
        let known = summaries.filter { AccountSummarySection.bucket(for: $0) != nil }
        let bucketed = Dictionary(grouping: known) { AccountSummarySection.bucket(for: $0)! }
        let subtotals = bucketed.values.flatMap { $0 }.reduce(Decimal.zero) { $0 + $1.latestBalance }
        #expect(subtotals == netWorth(summaries))            // identity holds
        #expect(bucketed[.liabilities]?.count == 1)
        #expect(bucketed[.retirement]?.count == 1)
        #expect(bucketed[.liquidAssets]?.count == 1)
        #expect(bucketed[.otherAssets]?.count == 1)

        // The insufficient-history row is in no bucket.
        let insufficient = summaries.filter { AccountSummarySection.bucket(for: $0) == nil }
        #expect(insufficient.count == 1)
    }

    @Test("Restricted retirement lands in Retirement; restricted non-retirement in Other Assets")
    func bucketOrdering() throws {
        let restrictedRetirement = summary(type: .retirement, latestBalance: 5000,
                                           liquidity: .lockedUntilRetirement, retirementKind: .afore)
        let restrictedInvestment = summary(type: .investment, latestBalance: 800, liquidity: .restricted)
        let liquidChecking = summary(type: .checking, latestBalance: 1000, liquidity: .liquid)
        let creditCard = summary(type: .creditCard, latestBalance: -300)

        #expect(AccountSummarySection.bucket(for: restrictedRetirement) == .retirement)
        #expect(AccountSummarySection.bucket(for: restrictedInvestment) == .otherAssets)
        #expect(AccountSummarySection.bucket(for: liquidChecking) == .liquidAssets)
        #expect(AccountSummarySection.bucket(for: creditCard) == .liabilities)
    }

    @Test("Insufficient-history bucket is nil")
    func insufficientBucketIsNil() throws {
        let insufficient = summary(type: .retirement, latestBalance: 5000, sourceKind: .insufficientHistory)
        #expect(AccountSummarySection.bucket(for: insufficient) == nil)
    }

    // MARK: - Treatment persistence (regression for §7)

    @Test("Treatment edit on a transfer changes treatment only")
    func treatmentPersistenceDoesNotDisturbFlowOrTransfer() throws {
        let container = try ModelContainer(
            for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext

        let account = Account(institution: "Checking", type: .checking)
        context.insert(account)
        let tx = Transaction(
            account: account,
            postedAt: date(),
            amount: 1000,
            descriptionRaw: "Transfer to PPR",
            isTransfer: true,
            source: .manual
        )
        context.insert(tx)

        let originalFlow = tx.flowKindRaw
        let originalMovement = tx.movementKindRaw

        // Mirror TransactionDetailSheet.save()'s treatment write exactly.
        let draft: TransactionTreatmentKind = .retirementContributionUserFunded
        tx.treatmentKindRaw = draft == .regular ? nil : draft.rawValue
        try context.save()

        #expect(tx.treatmentKind == .retirementContributionUserFunded)
        #expect(tx.flowKindRaw == originalFlow)
        #expect(tx.movementKindRaw == originalMovement)
        #expect(tx.isTransfer == true)
    }

    @Test("Regular treatment stores nil")
    func regularTreatmentStoresNil() throws {
        let container = try ModelContainer(
            for: AppSchema.schema,
            configurations: [ModelConfiguration(schema: AppSchema.schema, isStoredInMemoryOnly: true)]
        )
        let context = container.mainContext

        let account = Account(institution: "Checking", type: .checking)
        context.insert(account)
        let tx = Transaction(
            account: account,
            postedAt: date(),
            amount: -50,
            descriptionRaw: "Coffee",
            source: .manual
        )
        context.insert(tx)

        let draft: TransactionTreatmentKind = .regular
        tx.treatmentKindRaw = draft == .regular ? nil : draft.rawValue
        try context.save()

        #expect(tx.treatmentKindRaw == nil)
        #expect(tx.treatmentKind == .regular)
    }

    // MARK: - Account-edit defaults (0.6.0 view-relevant subset)

    @Test("Retirement kinds produce expected liquidity for breakdown bucketing")
    func retirementKindLiquidityDefaults() throws {
        let ppr = Account(institution: "PPR", type: .retirement, retirementKindRaw: RetirementKind.ppr.rawValue)
        #expect(ppr.liquidity == .restricted)

        let afore = Account(institution: "AFORE", type: .retirement, retirementKindRaw: RetirementKind.afore.rawValue)
        #expect(afore.liquidity == .lockedUntilRetirement)

        let employer = Account(institution: "Employer", type: .retirement,
                               retirementKindRaw: RetirementKind.employerRetirementPlan.rawValue)
        #expect(employer.liquidity == .lockedUntilRetirement)

        // All three are retirement-type, so they bucket into Retirement regardless of liquidity.
        for account in [ppr, afore, employer] {
            let s = summary(type: account.type, latestBalance: 1000, liquidity: account.liquidity, retirementKind: account.retirementKind)
            #expect(AccountSummarySection.bucket(for: s) == .retirement)
        }
    }
}
