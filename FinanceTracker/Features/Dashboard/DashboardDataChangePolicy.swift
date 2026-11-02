import Foundation
import SwiftData

/// Decides whether a `ModelContext.didSave` notification should rebuild the
/// dashboard snapshot. Kept as a pure, testable seam between the notification
/// wiring in `DashboardView` and the refresh entry point in `DashboardViewModel`.
enum DashboardDataChangePolicy {
    /// Model types whose persistence changes what the dashboard computes.
    /// `PendingImport` resolution, for example, inserts a `Transaction`, so it
    /// is covered transitively; `Category` matters because renames change the
    /// labels the donut and category cards render.
    private static let relevantTypes: [AnyClass] = [
        Transaction.self,
        Account.self,
        Statement.self,
        AccountBalanceSnapshot.self,
        InstallmentPlan.self,
        FinanceTracker.Category.self,
    ]

    /// Pure decision over explicitly changed objects: relevant only when one
    /// of them is a balance-relevant model (or a subclass of one).
    static func isBalanceRelevant(changedObjects: [Any]) -> Bool {
        changedObjects.contains { object in
            guard let model = object as? any PersistentModel else { return false }
            var current: AnyClass? = Swift.type(of: model) as AnyClass
            while let candidate = current {
                if relevantTypes.contains(where: { ObjectIdentifier($0) == ObjectIdentifier(candidate) }) {
                    return true
                }
                current = candidate.superclass()
            }
            return false
        }
    }

    /// Notification-level entry. SwiftData does not guarantee typed userInfo
    /// on `didSave` — payloads may be model objects, opaque persistent IDs, or
    /// absent entirely. Only concrete models can prove irrelevance; anything
    /// else fails open to a refresh, which is always safe: the refresh is a
    /// pure recompute and the caller throttles bursts.
    ///
    /// `container` scopes the decision: saves from side contexts of the same
    /// container (backup restores, the settings editor) must refresh too;
    /// anything from a different container is ignored.
    static func isBalanceRelevant(_ notification: Notification, container: ModelContainer? = nil) -> Bool {
        if let container,
           let savingContext = notification.object as? ModelContext,
           savingContext.container !== container {
            return false
        }
        guard let userInfo = notification.userInfo, !userInfo.isEmpty else {
            return true
        }
        var changed: [Any] = []
        for value in userInfo.values {
            collect(value, into: &changed)
        }
        let models = changed.filter { $0 is any PersistentModel }
        // Opaque payloads (persistent IDs, tokens) can't be classified.
        guard !models.isEmpty else { return true }
        return isBalanceRelevant(changedObjects: models)
    }

    /// Flattens the handful of collection shapes a notification payload may
    /// take; anything else is kept as a single element.
    private static func collect(_ value: Any, into sink: inout [Any]) {
        if let array = value as? [Any] {
            array.forEach { collect($0, into: &sink) }
        } else if let set = value as? Set<AnyHashable> {
            set.forEach { sink.append($0) }
        } else if let foundationArray = value as? NSArray {
            foundationArray.forEach { sink.append($0) }
        } else if let foundationSet = value as? NSSet {
            foundationSet.forEach { sink.append($0) }
        } else {
            sink.append(value)
        }
    }
}
