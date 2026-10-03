import Foundation

/// Stages JSON mutations without publishing changes. Originals are kept byte for
/// byte until the accompanying SwiftData save commits.
final class SidecarFileTransaction {
    private let originals: [(url: URL, data: Data?)]
    let directory: URL
    private var published: [URL] = []
    private var addedStatements: [URL] = []

    init(urls: [URL]) throws {
        originals = try urls.map { url in
            (url, FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil)
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("FinanceTracker-restore-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (index, original) in originals.enumerated() {
            if let data = original.data {
                try data.write(to: stagedURL(for: original.url), options: .atomic)
                try data.write(to: directory.appendingPathComponent("original-\(index)-\(original.url.lastPathComponent)"), options: .atomic)
            }
        }
    }

    func stagedURL(for url: URL) -> URL { directory.appendingPathComponent(url.lastPathComponent) }

    func publish(_ url: URL) throws {
        let staged = stagedURL(for: url)
        // Include the attempted write even when the OS reports a partial failure.
        if !published.contains(url) { published.append(url) }
        if FileManager.default.fileExists(atPath: staged.path) {
            let data = try Data(contentsOf: staged)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    func prepareStatements(from source: URL, into destination: URL) throws {
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        var enumerationError: Error?
        guard let files = FileManager.default.enumerator(at: source, includingPropertiesForKeys: Array(keys),
            errorHandler: { _, error in enumerationError = error; return false }) else {
            throw CocoaError(.fileReadUnknown)
        }
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: keys)
            guard values.isSymbolicLink != true else { throw CocoaError(.fileReadUnsupportedScheme) }
            guard values.isRegularFile == true else { continue }
            let relative = file.pathComponents.dropFirst(source.pathComponents.count).joined(separator: "/")
            let target = destination.appendingPathComponent(relative)
            guard !FileManager.default.fileExists(atPath: target.path) else { continue }
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            addedStatements.append(target)
            try FileManager.default.copyItem(at: file, to: target)
        }
        if let enumerationError { throw enumerationError }
    }

    func rollback() throws {
        var failures: [String] = []
        for original in originals where published.contains(original.url) {
            do {
                if let data = original.data { try data.write(to: original.url, options: .atomic) }
                else if FileManager.default.fileExists(atPath: original.url.path) {
                    try FileManager.default.removeItem(at: original.url)
                }
            } catch { failures.append("\(original.url.lastPathComponent): \(error.localizedDescription)") }
        }
        for file in addedStatements {
            do {
                if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
            }
            catch { failures.append(error.localizedDescription) }
        }
        if !failures.isEmpty {
            // Keep a durable, readable recovery copy instead of suppressing a
            // compensation failure or removing the only originals.
            throw RecoveryError(path: directory.path, failures: failures)
        }
        discard()
    }

    func discard() { try? FileManager.default.removeItem(at: directory) }

    struct RecoveryError: LocalizedError {
        let path: String
        let failures: [String]
        var errorDescription: String? {
            "Falló la recuperación: \(failures.joined(separator: "; ")). Copias recuperables: \(path)"
        }
    }
}

enum PersistedMutationClock {
    /// Keep new edits ordered at the precision supported by existing backups.
    static func next(after previous: Date?, now: Date = .now) -> Date {
        let second = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down))
        return previous.map { max(second, $0.addingTimeInterval(1)) } ?? second
    }
}
