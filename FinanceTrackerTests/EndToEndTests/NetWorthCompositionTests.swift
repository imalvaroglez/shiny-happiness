import Testing
import Foundation
@testable import FinanceTracker

@Suite("Net Worth Composition")
struct NetWorthCompositionTests {
    private let testDate = Date(timeIntervalSince1970: 0)

    @Test("Sample fixture derives total and available views")
    func sampleFixture() throws {
        let composition = NetWorthComposition.calculate(from: sampleFixtureSummaries())
        let total = composition.display(mode: .total)
        let available = composition.display(mode: .available)

        #expect(composition.grossLiquidity == d("522150.08"))
        #expect(composition.totalLiabilities == d("163002.53"))
        #expect(composition.netLiquidity == d("359147.55"))
        #expect(composition.patrimonial == d("239033.33"))
        #expect(composition.retirement == d("1588448.09"))
        #expect(composition.totalNetWorth == d("2186628.97"))

        #expect(total.total == d("2186628.97"))
        #expect(total.chartSlices.map(\.bucket) == [.liquidity, .patrimonial, .retirement])
        #expect(total.footerTitle == "Total net worth")
        #expect(total.helperText == "Liabilities reduce liquidity.")

        let totalLiquidityPercent = try #require(total.percentage(for: .liquidity))
        let totalPatrimonialPercent = try #require(total.percentage(for: .patrimonial))
        let totalRetirementPercent = try #require(total.percentage(for: .retirement))
        #expect(abs(totalLiquidityPercent - 16.4) < 0.05)
        #expect(abs(totalPatrimonialPercent - 10.9) < 0.05)
        #expect(abs(totalRetirementPercent - 72.6) < 0.05)

        #expect(available.total == d("598180.88"))
        #expect(available.chartSlices.map(\.bucket) == [.liquidity, .patrimonial])
        #expect(available.footerTitle == "Available net worth")
        #expect(available.helperText == "Excludes retirement assets.")
        #expect(available.percentage(for: .retirement) == nil)

        let availableLiquidityPercent = try #require(available.percentage(for: .liquidity))
        let availablePatrimonialPercent = try #require(available.percentage(for: .patrimonial))
        #expect(abs(availableLiquidityPercent - 60.0) < 0.05)
        #expect(abs(availablePatrimonialPercent - 40.0) < 0.05)
    }

    @Test("Liabilities reduce liquidity first")
    func liabilitiesReduceLiquidity() throws {
        let composition = NetWorthComposition.calculate(from: [
            summary(type: .checking, amount: 1_000),
            summary(type: .creditCard, amount: -250),
        ])

        #expect(composition.grossLiquidity == 1_000)
        #expect(composition.totalLiabilities == 250)
        #expect(composition.netLiquidity == 750)
        #expect(composition.totalNetWorth == 750)
        #expect(composition.chartSlices.map(\.amount) == [750])
        #expect(composition.chartSlices.first?.bucket == .liquidity)
        #expect(composition.display(mode: .available).chartSlices.map(\.bucket) == [.liquidity])
    }

    @Test("Contributor accounts are grouped by bucket")
    func contributorAccountsGroupedByBucket() {
        let composition = NetWorthComposition.calculate(from: [
            summary("Checking", type: .checking, amount: 1_000),
            summary("Liquid Fund", type: .investment, amount: 200, liquidity: .liquid),
            summary("Brokerage", type: .investment, amount: 500, liquidity: .restricted),
            summary("AFORE", type: .retirement, amount: 700, liquidity: .lockedUntilRetirement),
            summary("Card", type: .creditCard, amount: -300),
            summary("Mystery", type: .other, amount: 40),
        ])

        #expect(composition.liquidAssetAccounts.map(\.displayName) == ["Checking", "Liquid Fund"])
        #expect(composition.liabilityAccounts.map(\.displayName) == ["Card"])
        #expect(composition.patrimonialAccounts.map(\.displayName) == ["Brokerage"])
        #expect(composition.retirementAccounts.map(\.displayName) == ["AFORE"])
        #expect(composition.uncategorizedAccounts.map(\.displayName) == ["Mystery"])
    }

    @Test("Negative net liquidity is detailed but omitted from chart")
    func negativeNetLiquidity() {
        let composition = NetWorthComposition.calculate(from: [
            summary(type: .checking, amount: 100),
            summary(type: .creditCard, amount: -250),
            summary(type: .investment, amount: 500, liquidity: .restricted),
        ])
        let available = composition.display(mode: .available)

        #expect(composition.netLiquidity == -150)
        #expect(composition.totalNetWorth == 350)
        #expect(composition.liabilitiesExceedLiquidAssets)
        #expect(!available.chartSlices.contains { $0.bucket == .liquidity })
        #expect(available.chartSlices.map(\.bucket) == [.patrimonial])
        #expect(available.percentage(for: .liquidity) == nil)
        #expect(available.percentage(for: .patrimonial) == 100)
    }

    @Test("Liquid investments remain liquidity and restricted investments are patrimonial")
    func investmentLiquidityClassification() {
        let composition = NetWorthComposition.calculate(from: [
            summary("Liquid Fund", type: .investment, amount: 200, liquidity: .liquid),
            summary("Brokerage", type: .investment, amount: 500, liquidity: .restricted),
        ])

        #expect(composition.grossLiquidity == 200)
        #expect(composition.patrimonial == 500)
        #expect(composition.liquidAssetAccounts.map(\.displayName) == ["Liquid Fund"])
        #expect(composition.patrimonialAccounts.map(\.displayName) == ["Brokerage"])
        #expect(composition.chartSlices.map(\.bucket) == [.liquidity, .patrimonial])
    }

    @Test("Zero and negative totals do not divide by zero")
    func zeroBalances() {
        let zeroComposition = NetWorthComposition.calculate(from: [
            summary(type: .checking, amount: 0),
            summary(type: .investment, amount: 0, liquidity: .restricted),
            summary(type: .retirement, amount: 0, liquidity: .restricted),
        ])
        let negativeComposition = NetWorthComposition.calculate(from: [
            summary(type: .checking, amount: 100),
            summary(type: .creditCard, amount: -250),
        ])

        #expect(zeroComposition.totalNetWorth == 0)
        #expect(zeroComposition.display(mode: .total).percentage(for: .liquidity) == nil)
        #expect(zeroComposition.display(mode: .total).chartSlices.isEmpty)
        #expect(negativeComposition.display(mode: .total).total == -150)
        #expect(negativeComposition.display(mode: .total).chartSlices.isEmpty)
    }

    @Test("Uncategorized accounts are included in total and flagged")
    func uncategorizedAccounts() {
        let composition = NetWorthComposition.calculate(from: [
            summary(type: .checking, amount: 100),
            summary("Mystery", type: .other, amount: 42),
        ])

        #expect(composition.grossLiquidity == 100)
        #expect(composition.uncategorized == 42)
        #expect(composition.totalNetWorth == 142)
        #expect(composition.display(mode: .total).total == 100)
        #expect(composition.hasUncategorized)
        #expect(composition.uncategorizedAccounts.map(\.displayName) == ["Mystery"])
        #expect(composition.chartSlices.map(\.bucket) == [.liquidity])
        #expect(composition.display(mode: .total).percentage(for: .liquidity) == 100)
    }

    @Test("Insufficient history accounts are ignored")
    func insufficientHistoryIgnored() {
        let composition = NetWorthComposition.calculate(from: [
            summary(type: .checking, amount: 100, sourceKind: .insufficientHistory),
            summary(type: .checking, amount: 50),
        ])

        #expect(composition.grossLiquidity == 50)
        #expect(composition.totalNetWorth == 50)
        #expect(composition.chartSlices.map(\.amount) == [50])
        #expect(composition.liquidAssetAccounts.count == 1)
    }

    private func sampleFixtureSummaries() -> [AccountSummary] {
        [
            summary("Openbank / BBVA / BONDDIA", type: .savings, amount: d("522150.08")),
            summary("Investment / GBM", type: .investment, amount: d("239033.33"), liquidity: .restricted),
            summary("AFORE / Banamex", type: .retirement, amount: d("630254.49"), liquidity: .lockedUntilRetirement, retirementKind: .afore),
            summary("Plan para el Retiro / Skandia", type: .retirement, amount: d("825721.69"), liquidity: .lockedUntilRetirement, retirementKind: .employerRetirementPlan),
            summary("PPR / Fintual", type: .retirement, amount: d("132471.91"), liquidity: .restricted, retirementKind: .ppr),
            summary("Credit cards", type: .creditCard, amount: -d("163002.53")),
        ]
    }

    private func summary(
        _ name: String = "Account",
        type: AccountType,
        amount: Decimal,
        liquidity: AccountLiquidity = .liquid,
        retirementKind: RetirementKind? = nil,
        sourceKind: AccountBalanceResolution.SourceKind = .reconstructedBalance
    ) -> AccountSummary {
        AccountSummary(
            id: UUID(),
            displayName: name,
            institution: "Bank",
            type: type,
            currency: "MXN",
            latestBalance: amount,
            balanceAsOf: testDate,
            balanceSourceKind: sourceKind,
            balanceSourceDate: testDate,
            creditLimit: nil,
            utilizationPercent: nil,
            liquidity: liquidity,
            retirementKind: retirementKind
        )
    }

    private func d(_ value: String) -> Decimal {
        Decimal(string: value) ?? 0
    }
}
