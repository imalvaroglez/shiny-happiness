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
    var showingPasteSheet = false
    var pasteBuffer = ""

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

        var pdfCsvURLs: [URL] = []
        var txtURLs: [URL] = []
        for url in urls {
            switch url.pathExtension.lowercased() {
            case "pdf", "csv":
                pdfCsvURLs.append(url)
            case "txt":
                txtURLs.append(url)
            default:
                continue
            }
        }

        if !pdfCsvURLs.isEmpty {
            let storedURLs = copyToStorage(pdfCsvURLs)
            let newReports = await pipeline.ingest(files: storedURLs)
            reports.append(contentsOf: newReports)
        }

        for url in txtURLs {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                reports.append(IngestReport(
                    fileName: url.lastPathComponent,
                    errorCount: 1,
                    errors: [IngestError(message: "Could not read text file.")]
                ))
                continue
            }
            let report = await pipeline.ingestPastedText(text, sourceLabel: url.lastPathComponent)
            reports.append(report)
        }
    }

    /// Detection signal for the paste sheet's status chip.
    var pasteDetection: DetectionResult {
        Detector.detectFromPastedText(pasteBuffer)
    }

    /// Run the pasted text through `IngestPipeline.ingestPastedText`. The label uses
    /// the detected issuer + today's date so reports stay distinguishable.
    func importPastedText() async {
        guard !pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        isImporting = true
        defer { isImporting = false }

        let detection = Detector.detectFromPastedText(pasteBuffer)
        let label: String
        if detection.issuer == .unknown {
            label = "Pasted statement (\(Self.shortDate()))"
        } else {
            label = "\(detection.issuer.rawValue) paste (\(Self.shortDate()))"
        }
        let report = await pipeline.ingestPastedText(pasteBuffer, sourceLabel: label)
        reports.append(report)
        pasteBuffer = ""
        showingPasteSheet = false
    }

    private static func shortDate() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: .now)
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

            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
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
