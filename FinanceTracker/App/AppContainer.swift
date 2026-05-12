import Foundation
import SwiftData

@MainActor
final class AppContainer: ObservableObject {
    let modelContainer: ModelContainer
    let modelContext: ModelContext

    init() throws {
        let schema = Schema([
            Account.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
            InstallmentPlan.self,
        ])
        let config = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            groupContainer: .none,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: schema, configurations: [config])
        self.modelContainer = container
        self.modelContext = container.mainContext
    }
}
