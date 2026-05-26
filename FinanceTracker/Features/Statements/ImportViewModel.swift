import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import CryptoKit

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
            let inputs = copyToStorage(pdfCsvURLs)
            let newReports = await pipeline.ingest(inputs: inputs)
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

    private func copyToStorage(_ urls: [URL]) -> [IngestFileInput] {
        guard let statementsDirectory else {
            return urls.map { IngestFileInput(url: $0, originalFileName: $0.lastPathComponent, archivedRelativePath: nil) }
        }
        let fm = FileManager()

        return urls.map { url in
            let accessing = url.startAccessingSecurityScopedResource()
            defer {
                if accessing { url.stopAccessingSecurityScopedResource() }
            }

            guard let data = try? Data(contentsOf: url) else {
                return IngestFileInput(url: url, originalFileName: url.lastPathComponent, archivedRelativePath: nil)
            }

            let hash = Self.computeHashPrefix(data)
            let sanitizedName = url.lastPathComponent
            let archiveName = "\(hash)_\(sanitizedName)"
            let destination = statementsDirectory.appendingPathComponent(archiveName)

            if !fm.fileExists(atPath: destination.path) {
                try? fm.createDirectory(at: statementsDirectory, withIntermediateDirectories: true)
                try? fm.copyItem(at: url, to: destination)
            }

            let relativePath = "FinanceTracker/Statements/\(archiveName)"
            return IngestFileInput(url: destination, originalFileName: url.lastPathComponent, archivedRelativePath: relativePath)
        }
    }

    private static func computeHashPrefix(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.prefix(8).joined()
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
