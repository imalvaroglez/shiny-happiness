import Testing
import Foundation
import SwiftData
@testable import FinanceTracker

/// Pure decision layer for `ModelContext.didSave` → dashboard refresh wiring.
/// No ModelContainer: models are constructed standalone, never inserted.
@Suite("Dashboard Data Change Policy")
struct DashboardDataChangePolicyTests {
    private func bareAccount() -> Account {
        Account(institution: "Test Bank", type: .checking, openedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("Balance-relevant entities trigger a refresh")
    func relevantEntitiesTriggerRefresh() {
        let account = bareAccount()
        let transaction = Transaction(
            account: account,
            postedAt: Date(timeIntervalSince1970: 0),
            amount: 100,
            descriptionRaw: "Tx"
        )
        let snapshot = AccountBalanceSnapshot(
            account: account,
            date: Date(timeIntervalSince1970: 0),
            amount: 100,
            kind: .manualAdjustment
        )
        let statement = Statement(
            account: account,
            periodStart: Date(timeIntervalSince1970: 0),
            periodEnd: Date(timeIntervalSince1970: 1),
            sourceFileHash: "hash"
        )

        #expect(DashboardDataChangePolicy.isBalanceRelevant(changedObjects: [transaction]))
        #expect(DashboardDataChangePolicy.isBalanceRelevant(changedObjects: [account]))
        #expect(DashboardDataChangePolicy.isBalanceRelevant(changedObjects: [snapshot]))
        #expect(DashboardDataChangePolicy.isBalanceRelevant(changedObjects: [statement]))
    }

    @Test("Objects that never move balances are ignored")
    func irrelevantObjectsAreIgnored() {
        #expect(!DashboardDataChangePolicy.isBalanceRelevant(changedObjects: []))
        #expect(!DashboardDataChangePolicy.isBalanceRelevant(changedObjects: ["string", 42]))
    }

    @Test("Notifications without readable userInfo fail open")
    func notificationWithoutUserInfoFailsOpen() {
        let notification = Notification(name: ModelContext.didSave, object: nil)
        #expect(DashboardDataChangePolicy.isBalanceRelevant(notification))
    }

    @Test("Saves from side contexts of the same container are relevant — the restore path")
    func sideContextSavesOfSameContainerAreRelevant() throws {
        let schema = Schema([
            Account.self, AccountBalanceSnapshot.self, Transaction.self,
            Statement.self,
            FinanceTracker.Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ])
        let container = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        // BackupArchive.restore saves on a private context of the same
        // container; the dashboard must still react to it.
        let sideContext = ModelContext(container)
        let account = bareAccount()
        sideContext.insert(account)
        try sideContext.save()

        let notification = Notification(name: ModelContext.didSave, object: sideContext)
        #expect(DashboardDataChangePolicy.isBalanceRelevant(notification, container: container))
    }

    @Test("Saves from a different container are ignored")
    func foreignContainerSavesAreIgnored() throws {
        let schema = Schema([Account.self, Transaction.self])
        let foreign = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let own = try ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true)
        )
        let foreignContext = ModelContext(foreign)
        let account = bareAccount()
        foreignContext.insert(account)
        try foreignContext.save()

        let notification = Notification(name: ModelContext.didSave, object: foreignContext)
        #expect(!DashboardDataChangePolicy.isBalanceRelevant(notification, container: own))
    }

    @Test("Notification userInfo is inspected when present")
    func notificationWithRelevantUserInfoIsDetected() {
        let account = bareAccount()
        let transaction = Transaction(
            account: account,
            postedAt: Date(timeIntervalSince1970: 0),
            amount: 100,
            descriptionRaw: "Tx"
        )
        let relevant = Notification(
            name: ModelContext.didSave,
            object: nil,
            userInfo: ["insertedObjects": [transaction]]
        )
        #expect(DashboardDataChangePolicy.isBalanceRelevant(relevant))

        // Concrete irrelevant models prove irrelevance at the notification
        // layer too. Opaque payloads (strings, IDs) fail open by design.
        let irrelevant = Notification(
            name: ModelContext.didSave,
            object: nil,
            userInfo: ["changedObjects": ["seed"]]
        )
        #expect(DashboardDataChangePolicy.isBalanceRelevant(irrelevant))
    }
}
