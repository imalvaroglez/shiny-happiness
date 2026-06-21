import Foundation
import SwiftData

/// Central save point for user-initiated writes.
///
/// Every action that changes money, account semantics, deletion state, or
/// restore state must persist through here and surface a failure to the user
/// rather than failing silently with `try? modelContext.save()`. Callers wrap
/// this in `do/catch` and keep the editor open on failure — no silent success.
@MainActor
enum Persistence {
    static func save(_ context: ModelContext) throws {
        try context.save()
    }
}
