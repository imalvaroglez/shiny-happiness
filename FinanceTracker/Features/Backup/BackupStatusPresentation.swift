import Foundation

#if os(macOS)

/// The small, user-facing subset of backup state shown in Settings.
/// It intentionally does not expose the number of retained bundles: that is
/// an implementation detail of the retention policy, not a data-health metric.
struct BackupStatusPresentation: Equatable {
    let latestPath: String?
    let managedDirectoryPath: String
    let createdAt: Date?

    init(latestBackup: BackupSummary?, managedDirectory: URL) {
        latestPath = latestBackup?.url.path
        managedDirectoryPath = managedDirectory.path
        createdAt = latestBackup?.createdAt
    }

    var hasVerifiedSnapshot: Bool {
        latestPath != nil && createdAt != nil
    }
}

#endif
