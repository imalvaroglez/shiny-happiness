import Foundation
import os

@MainActor
struct StoreFileResetService {
    private static let logger = Logger(subsystem: "com.financeTracker.app", category: "StoreFileResetService")

    internal static var appSupportOverride: URL?
    internal static var skipTestGuard = false

    private static let flagURL: URL = {
        let base = appSupportOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = base.appendingPathComponent("FinanceTracker", isDirectory: true)
        return dir.appendingPathComponent("hard_reset_requested")
    }()

    private static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || ProcessInfo.processInfo.environment["XCInjectBundleInto"] != nil
    }

    static var isHardResetRequested: Bool {
        FileManager.default.fileExists(atPath: flagURL.path)
    }

    static func requestHardReset(reason: String) {
        logger.critical("Hard reset requested: \(reason)")
        let dir = flagURL.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(reason.utf8).write(to: flagURL)
    }

    static func performHardResetIfNeeded() {
        guard skipTestGuard || !isRunningTests else { return }
        guard isHardResetRequested else { return }
        logger.info("Performing hard store file quarantine")

        let appSupport = appSupportOverride
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!

        let timestamp = ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")
        let quarantineDir = appSupport
            .appendingPathComponent("FinanceTracker/ResetBackups/\(timestamp)", isDirectory: true)
        try? FileManager.default.createDirectory(at: quarantineDir, withIntermediateDirectories: true)

        let storeBase = appSupport.appendingPathComponent("default.store")
        for ext in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: storeBase.path + ext)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dst = quarantineDir.appendingPathComponent(src.lastPathComponent)
            try? FileManager.default.moveItem(at: src, to: dst)
        }

        let fallbackBase = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/default.store")
        for ext in ["", "-wal", "-shm"] {
            let src = URL(fileURLWithPath: fallbackBase.path + ext)
            guard FileManager.default.fileExists(atPath: src.path) else { continue }
            let dst = quarantineDir.appendingPathComponent(src.lastPathComponent)
            guard !FileManager.default.fileExists(atPath: dst.path) else { continue }
            try? FileManager.default.moveItem(at: src, to: dst)
        }

        try? FileManager.default.removeItem(at: flagURL)
        logger.info("Hard reset complete — store files quarantined to \(quarantineDir.path)")
    }
}
