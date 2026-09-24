import SwiftData
import SwiftUI

@main
struct FinanceTrackerApp: App {
    private let modelContainer: ModelContainer

    init() {
        let isRunningTests = StoreFileResetService.isRunningTests
        StoreFileResetService.performHardResetIfNeeded()
        do {
            modelContainer = try AppSchema.makeContainer(isStoredInMemoryOnly: isRunningTests)
        } catch {
            fatalError("Failed to open FinanceTracker store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            if StoreFileResetService.isRunningTests {
                Color.clear
            } else {
                ZStack {
                    AppBackdrop()
                    DashboardView()
                }
            }
        }
        .modelContainer(modelContainer)
    }
}
