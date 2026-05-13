import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

@Suite("Multi-HSBC isolation")
@MainActor
struct MultiHSBCAccountTests {

    private func makeContainer() throws -> ModelContainer {
        let schema = Schema([
            Account.self, Transaction.self, Statement.self,
            Category.self, CategoryRule.self, InstallmentPlan.self,
            PendingImport.self, SignRecoveryHint.self,
        ])
        let config = ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [config])
    }

    private func loadFixture(_ filename: String) throws -> String {
        let url = URL(fileURLWithPath: "/Users/developer/Documents/GitHub/shiny-happiness/samples/\(filename)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("Pasting two distinct HSBC accounts creates two distinct Accounts")
    func twoAccountsRemainDistinct() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)
        let pipeline = IngestPipeline(context: context)

        _ = await pipeline.ingestPastedText(try loadFixture("2026-05-08_HSBC_2Now_paste.txt"),
                                            sourceLabel: "HSBC A")
        _ = await pipeline.ingestPastedText(try loadFixture("2026-05-08_HSBC_2Now_paste_accountB.txt"),
                                            sourceLabel: "HSBC B")

        let accounts = try context.fetch(FetchDescriptor<Account>())
        let hsbcAccounts = accounts.filter { $0.institution == "HSBC 2Now" }
        #expect(hsbcAccounts.count == 2,
                "Expected exactly 2 HSBC accounts after two distinct pastes, got \(hsbcAccounts.count)")

        let numbers = Set(hsbcAccounts.compactMap(\.accountNumber))
        #expect(numbers == ["1111", "2222"],
                "Expected accountNumbers {1111, 2222}, got \(numbers)")
    }

    @Test("Each HSBC account holds only its own cards' transactions")
    func transactionsDoNotCrossAccounts() async throws {
        let container = try makeContainer()
        let context = container.mainContext
        SeedDataLoader.bootstrapIfNeeded(context: context)
        let pipeline = IngestPipeline(context: context)

        _ = await pipeline.ingestPastedText(try loadFixture("2026-05-08_HSBC_2Now_paste.txt"),
                                            sourceLabel: "HSBC A")
        _ = await pipeline.ingestPastedText(try loadFixture("2026-05-08_HSBC_2Now_paste_accountB.txt"),
                                            sourceLabel: "HSBC B")

        let txns = try context.fetch(FetchDescriptor<Transaction>())
        let byAccount = Dictionary(grouping: txns, by: { $0.account?.accountNumber ?? "?" })

        for (acctNumber, list) in byAccount where acctNumber != "?" {
            let cardSet = Set(list.compactMap(\.cardLast4))
            switch acctNumber {
            case "1111":
                #expect(cardSet.isSubset(of: ["1111", "1112"]),
                        "Account 1111 has transactions tagged with foreign cards: \(cardSet)")
            case "2222":
                #expect(cardSet.isSubset(of: ["2222", "2223"]),
                        "Account 2222 has transactions tagged with foreign cards: \(cardSet)")
            default:
                Issue.record("Unexpected account number: \(acctNumber)")
            }
        }
    }

    @Test("AccountIdentity assigns distinct hues to two HSBC accounts")
    func identityColorsDiffer() async throws {
        let a = Account(institution: "HSBC 2Now", type: .creditCard, accountNumber: "1111")
        let b = Account(institution: "HSBC 2Now", type: .creditCard, accountNumber: "2222")
        let colorA = AccountIdentity.color(for: a)
        let colorB = AccountIdentity.color(for: b)
        #expect(colorA != colorB,
                "Two same-institution accounts must receive distinct colors")
    }
}
