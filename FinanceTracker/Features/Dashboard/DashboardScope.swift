import Foundation

/// Which slice of data the dashboard renders right now. `consolidated` aggregates
/// across every Account; `account(id)` zooms into a single Account's view. The
/// view dispatches between asset and liability presentations based on the account's
/// `AccountType`.
enum DashboardScope: Hashable, Sendable {
    case consolidated
    case account(UUID)
}
