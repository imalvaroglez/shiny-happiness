import SwiftData
import SwiftUI

@main
struct FinanceTrackerApp: App {
    private let modelContainer: ModelContainer

    init() {
        StoreFileResetService.performHardResetIfNeeded()
        do {
            modelContainer = try AppSchema.makeContainer()
        } catch {
            fatalError("Failed to open FinanceTracker store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ZStack {
                AppBackdrop()
                DashboardView()
            }
        }
        .modelContainer(modelContainer)
    }
}
