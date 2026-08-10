import Foundation

#if os(macOS)

struct BackupFolderAccess {
    let url: URL
    private let didStartAccessing: Bool

    init(url: URL, didStartAccessing: Bool) {
        self.url = url
        self.didStartAccessing = didStartAccessing
    }

    func stopAccessing() {
        if didStartAccessing {
            url.stopAccessingSecurityScopedResource()
        }
    }
}

@MainActor
enum BackupFolderStore {
    private static let bookmarkKey = "FinanceTracker.restoreBackupFolderBookmark"

    static var defaultDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FinanceTracker/Backups", isDirectory: true)
    }

    static func remember(directory: URL, defaults: UserDefaults = .standard) throws {
        let didStartAccessing = directory.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                directory.stopAccessingSecurityScopedResource()
            }
        }

        guard isDirectory(directory) else { throw BackupFolderStoreError.notDirectory }
        let bookmark = try directory.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        defaults.set(bookmark, forKey: bookmarkKey)
    }

    static func accessForLatest(
        defaultDirectory: URL = defaultDirectory,
        defaults: UserDefaults = .standard
    ) -> BackupFolderAccess {
        guard let data = defaults.data(forKey: bookmarkKey) else {
            return access(directory: defaultDirectory)
        }

        var isStale = false
        guard let directory = try? URL(
            resolvingBookmarkData: data,
            options: [.withSecurityScope],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            defaults.removeObject(forKey: bookmarkKey)
            return access(directory: defaultDirectory)
        }

        let resolved = access(directory: directory)
        guard isDirectory(directory) else {
            resolved.stopAccessing()
            defaults.removeObject(forKey: bookmarkKey)
            return access(directory: defaultDirectory)
        }

        if isStale {
            try? remember(directory: directory, defaults: defaults)
        }
        return resolved
    }

    static func access(directory: URL) -> BackupFolderAccess {
        BackupFolderAccess(
            url: directory,
            didStartAccessing: directory.startAccessingSecurityScopedResource()
        )
    }

    private static func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}

private enum BackupFolderStoreError: LocalizedError {
    case notDirectory

    var errorDescription: String? {
        "The selected backup location is not a folder."
    }
}

#endif
