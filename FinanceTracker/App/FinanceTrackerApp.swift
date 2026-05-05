import SwiftUI
import SwiftData

@main
struct FinanceTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            DashboardView()
        }
        .modelContainer(for: [
            Account.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
        ])
    }
}
