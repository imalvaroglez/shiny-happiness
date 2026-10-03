import Foundation

/// A UI preference, not financial history. Editing an old transaction never
/// writes this value; only a successful new manual capture does.
@MainActor
enum ManualCaptureDateStore {
    private static let prefix = "manualCaptureDate.v1."

    private static var defaults: UserDefaults {
        if StoreFileResetService.isRunningTests {
            return UserDefaults(suiteName: "FinanceTrackerTests.manualCapture.\(ProcessInfo.processInfo.processIdentifier)")!
        }
        // The Dev and production app have separate bundle identifiers/domains.
        return .standard
    }

    static func suggestedDate(accountID: UUID, defaults: UserDefaults? = nil) -> Date? {
        (defaults ?? Self.defaults).object(forKey: prefix + accountID.uuidString) as? Date
    }

    static func recordSuccessfulCapture(accountID: UUID, date: Date, defaults: UserDefaults? = nil) {
        (defaults ?? Self.defaults).set(date, forKey: prefix + accountID.uuidString)
    }

    static func reset(defaults: UserDefaults? = nil) {
        let defaults = defaults ?? Self.defaults
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
