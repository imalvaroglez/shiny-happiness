import SwiftUI
import SwiftData
import UniformTypeIdentifiers

@MainActor
@Observable
final class ImportViewModel {
    var reports: [IngestReport] = []
    var isImporting = false
    var dragTargeted = false
    var showFilePicker = false

    private let pipeline: IngestPipeline
    private let statementsDirectory: URL?

    init(modelContext: ModelContext) {
        self.pipeline = IngestPipeline(context: modelContext)
        self.statementsDirectory = Self.createStatementsDirectory()
    }

    func importFiles(_ urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }

        let validURLs = urls.filter { url in
            let ext = url.pathExtension.lowercased()
            return ext == "pdf" || ext == "csv"
        }

        guard !validURLs.isEmpty else { return }

        let storedURLs = copyToStorage(validURLs)
        let newReports = await pipeline.ingest(files: storedURLs)
        reports.append(contentsOf: newReports)
    }

    func clearReports() {
        reports.removeAll()
    }

    var totalNewTransactions: Int {
        reports.reduce(0) { $0 + $1.newTransactions }
    }

    var totalDuplicates: Int {
        reports.reduce(0) { $0 + $1.duplicateTransactions }
    }

    var totalErrors: Int {
        reports.reduce(0) { $0 + $1.errorCount }
    }

    private func copyToStorage(_ urls: [URL]) -> [URL] {
        guard let statementsDirectory else { return urls }
        let fm = FileManager.default

        return urls.map { url in
            let destination = statementsDirectory.appendingPathComponent(url.lastPathComponent)

            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }

            do {
                try fm.copyItem(at: url, to: destination)
                return destination
            } catch {
                return url
            }
        }
    }

    private static func createStatementsDirectory() -> URL? {
        let fm = FileManager.default
        guard let appSupport = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = appSupport.appendingPathComponent("FinanceTracker/Statements", isDirectory: true)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
