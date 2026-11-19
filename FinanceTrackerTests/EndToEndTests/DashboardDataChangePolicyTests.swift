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

    @Test("Dashboard-relevant entities trigger a refresh")
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
        let sourceID = UUID()
        let targetID = UUID()
        let link = TransactionLink(
            id: UUID(),
            identityKey: "refund:\(sourceID.uuidString.lowercased())",
            kind: .refund,
            sourceTransactionID: sourceID,
            targetTransactionID: targetID,
            lastModifiedAt: Date(timeIntervalSince1970: 0)
        )

        #expect(DashboardDataChangePolicy.isDashboardRelevant(changedObjects: [transaction]))
        #expect(DashboardDataChangePolicy.isDashboardRelevant(changedObjects: [account]))
        #expect(DashboardDataChangePolicy.isDashboardRelevant(changedObjects: [snapshot]))
        #expect(DashboardDataChangePolicy.isDashboardRelevant(changedObjects: [statement]))
        #expect(DashboardDataChangePolicy.isDashboardRelevant(changedObjects: [link]))
        #expect(DashboardDataChangePolicy.containsOnlyTransactionLinks(changedObjects: [link]))
        #expect(!DashboardDataChangePolicy.containsOnlyTransactionLinks(changedObjects: [link, transaction]))
    }

    @Test("Objects unrelated to dashboard data are ignored")
    func irrelevantObjectsAreIgnored() {
        #expect(!DashboardDataChangePolicy.isDashboardRelevant(changedObjects: []))
        #expect(!DashboardDataChangePolicy.isDashboardRelevant(changedObjects: ["string", 42]))
    }

    @Test("Notifications without readable userInfo fail open")
    func notificationWithoutUserInfoFailsOpen() {
        let notification = Notification(name: ModelContext.didSave, object: nil)
        #expect(DashboardDataChangePolicy.isDashboardRelevant(notification))
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
        #expect(DashboardDataChangePolicy.isDashboardRelevant(notification, container: container))
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
        #expect(!DashboardDataChangePolicy.isDashboardRelevant(notification, container: own))
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
        #expect(DashboardDataChangePolicy.isDashboardRelevant(relevant))

        let link = TransactionLink(
            id: UUID(), identityKey: "refund:test", kind: .refund,
            sourceTransactionID: UUID(), targetTransactionID: UUID(),
            lastModifiedAt: Date(timeIntervalSince1970: 0)
        )
        let linkOnly = Notification(
            name: ModelContext.didSave,
            object: nil,
            userInfo: ["insertedObjects": [link]]
        )
        #expect(DashboardDataChangePolicy.containsOnlyTransactionLinks(linkOnly))
        #expect(!DashboardDataChangePolicy.containsOnlyTransactionLinks(relevant))

        // Concrete irrelevant models prove irrelevance at the notification
        // layer too. Opaque payloads (strings, IDs) fail open by design.
        let irrelevant = Notification(
            name: ModelContext.didSave,
            object: nil,
            userInfo: ["changedObjects": ["seed"]]
        )
        #expect(DashboardDataChangePolicy.isDashboardRelevant(irrelevant))
    }
}
