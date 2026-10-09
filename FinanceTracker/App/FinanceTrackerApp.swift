import SwiftData
import SwiftUI

@main
struct FinanceTrackerApp: App {
    private let modelContainer: ModelContainer

    init() {
        let isRunningTests = StoreFileResetService.isRunningTests
        StoreFileResetService.performHardResetIfNeeded()
        if !isRunningTests {
            // Migración única del V1 de promociones: el store de overrides del
            // evaluador automático se retira a una copia legible; nunca se
            // reinterpreta como adjudicaciones (AD-025).
            try? PromotionLedgerStore.retireLegacyOverridesIfNeeded()
        }
        do {
            modelContainer = try AppSchema.makeContainer(isStoredInMemoryOnly: isRunningTests)
        } catch {
            fatalError("Failed to open FinanceTracker store: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if StoreFileResetService.isRunningTests {
                    Color.clear
                } else {
                    ZStack {
                        AppBackdrop()
                        DashboardView()
                    }
                }
            }
            .environment(\.locale, Locale(identifier: "es-MX"))
        }
        .modelContainer(modelContainer)
    }
}
