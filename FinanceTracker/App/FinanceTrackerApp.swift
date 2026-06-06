import SwiftUI
import SwiftData

@main
struct FinanceTrackerApp: App {
    init() {
        StoreFileResetService.performHardResetIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppBackdrop()
                DashboardView()
            }
        }
        // Must list every @Model the app reads or writes. Missing models silently
        // create a "shadow" empty container at runtime — paste imports lose
        // PendingImport rows, MSI plans never link, and learning hooks have nowhere
        // to persist. Keep this list in sync with `AppContainer.swift`.
        .modelContainer(for: [
            Account.self,
            AccountBalanceSnapshot.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
            PendingImport.self,
            SignRecoveryHint.self,
        ])
    }
}
