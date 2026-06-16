import Foundation
import SwiftData

@MainActor
final class AppContainer: ObservableObject {
    let modelContainer: ModelContainer
    let modelContext: ModelContext

    init() throws {
        let container = try AppSchema.makeContainer()
        self.modelContainer = container
        self.modelContext = container.mainContext
    }
}
