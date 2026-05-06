import Foundation
import SwiftData
import PDFKit
import CryptoKit
import os

@MainActor
final class IngestPipeline {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func ingest(files: [URL]) async -> [IngestReport] {
        var reports: [IngestReport] = []
        for file in files {
            let report = await ingestFile(file)
            reports.append(report)
        }
        return reports
    }

    private func ingestFile(_ url: URL) async -> IngestReport {
        let fileName = url.lastPathComponent
        Logger.pipeline.info("Starting ingest for \(fileName)")

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            Logger.pipeline.error("Failed to read file: \(error)")
            return IngestReport(
                fileName: fileName,
                errorCount: 1,
                errors: [IngestError(message: "Cannot read file: \(error.localizedDescription)")]
            )
        }

        let ext = url.pathExtension

        if ext.lowercased() == "pdf" {
            if let doc = PDFDocument(data: data) {
                if doc.isLocked && doc.page(at: 0)?.string == nil {
                    Logger.pipeline.warning("PDF is encrypted and unreadable: \(fileName)")
                    return IngestReport(
                        fileName: fileName,
                        errorCount: 1,
                        errors: [IngestError(message: "PDF is encrypted/password-protected and text cannot be extracted")]
                    )
                }

                if isGarbledText(document: doc) {
                    Logger.pipeline.warning("PDF has garbled text (likely custom font encoding): \(fileName)")
                    return IngestReport(
                        fileName: fileName,
                        errorCount: 1,
                        errors: [IngestError(message: "PDF text is garbled — custom font encoding without Unicode mapping. This requires OCR (planned for Phase 2)")]
                    )
                }
            }
        }

        let hash = computeHash(data)
        if let existingStatement = findStatement(byHash: hash) {
            Logger.pipeline.info("Statement already imported: \(fileName)")
            return IngestReport(
                fileName: fileName,
                duplicateTransactions: existingStatement.transactions.count,
                errors: [IngestError(message: "Statement already imported")]
            )
        }

        let detection = Detector.detect(data: data, fileExtension: ext)
        guard detection.issuer != .unknown else {
            Logger.pipeline.warning("Unknown issuer: \(fileName)")
            return IngestReport(
                fileName: fileName,
                errorCount: 1,
                errors: [IngestError(message: "Could not identify financial institution. If this is a valid bank statement, please file a support request")]
            )
        }

        let account = findOrCreateAccount(for: detection)

        let rawTransactions = await parseWithFallback(data: data, fileName: fileName, detection: detection)

        guard !rawTransactions.isEmpty else {
            Logger.pipeline.warning("No transactions found in \(fileName)")
            return IngestReport(
                fileName: fileName,
                errorCount: 1,
                errors: [IngestError(message: "No transactions could be extracted from this PDF. The format may not yet be supported")]
            )
        }

        let statement = createStatement(
            account: account,
            rawTransactions: rawTransactions,
            hash: hash
        )

        let transactions = Normalizer.normalizeAll(rawTransactions, account: account, statement: statement)

        let existingTransactions = fetchExistingTransactions(for: account)
        let dedupResult = Deduplicator.deduplicate(incoming: transactions, existing: existingTransactions)

        let rules = fetchCategoryRules()
        let catResult = Categorizer.categorize(transactions: dedupResult.unique, rules: rules)
        let _ = Categorizer.categorize(transactions: dedupResult.duplicates, rules: rules)

        persist(account: account, statement: statement, transactions: dedupResult.unique + dedupResult.duplicates)

        do {
            try context.save()
        } catch {
            Logger.pipeline.error("Save error: \(error)")
            return IngestReport(
                fileName: fileName,
                errorCount: 1,
                errors: [IngestError(message: "Save error: \(error.localizedDescription)")]
            )
        }

        Logger.pipeline.info("Ingested \(fileName): \(dedupResult.unique.count) new, \(dedupResult.duplicates.count) dupes, \(catResult.categorized) categorized")

        return IngestReport(
            fileName: fileName,
            newTransactions: dedupResult.unique.count,
            duplicateTransactions: dedupResult.duplicates.count,
            uncategorizedCount: catResult.uncategorized
        )
    }

    private func parseWithFallback(data: Data, fileName: String, detection: DetectionResult) async -> [RawTransaction] {
        if let structural = StructuralParser() {
            Logger.pipeline.info("Attempting structural parse for \(fileName)")
            do {
                let rawTxns = try await structural.parse(data: data)
                if !rawTxns.isEmpty {
                    Logger.pipeline.info("Structural parse succeeded for \(fileName): \(rawTxns.count) transactions")
                    return rawTxns
                }
                Logger.pipeline.info("Structural parse returned 0 transactions for \(fileName), trying legacy parser")
            } catch {
                Logger.pipeline.warning("Structural parse failed for \(fileName): \(error), trying legacy parser")
            }
        } else {
            Logger.pipeline.info("StructuralParser unavailable (knowledge JSONs not found), using legacy parser for \(fileName)")
        }

        guard let legacyParser = resolveLegacyParser(for: detection.issuer) else {
            Logger.pipeline.warning("No parser available for \(detection.issuer.rawValue)")
            return []
        }

        do {
            let rawTxns = try await legacyParser.parse(data: data)
            Logger.pipeline.info("Legacy parse for \(fileName): \(rawTxns.count) transactions")
            return rawTxns
        } catch {
            Logger.pipeline.error("Legacy parse error for \(fileName): \(error)")
            return []
        }
    }

    private func isGarbledText(document: PDFDocument) -> Bool {
        var totalChars = 0
        var badChars = 0

        let pagesToCheck = min(3, document.pageCount)
        for i in 0..<pagesToCheck {
            guard let page = document.page(at: i) else { continue }
            guard let text = page.string else { continue }

            for scalar in text.unicodeScalars {
                totalChars += 1
                let v = scalar.value
                if v == 0xFFFD || (v < 0x20 && v != 0x0A && v != 0x0D && v != 0x09) {
                    badChars += 1
                }
            }
        }

        guard totalChars > 50 else { return false }

        let ratio = Double(badChars) / Double(totalChars)
        Logger.pipeline.debug("Garbled text check: \(badChars)/\(totalChars) bad chars (\(String(format: "%.1f", ratio * 100))%)")
        return ratio > 0.30
    }

    private func computeHash(_ data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }

    private func findStatement(byHash hash: String) -> Statement? {
        let descriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.sourceFileHash == hash }
        )
        return try? context.fetch(descriptor).first
    }

    private func findOrCreateAccount(for detection: DetectionResult) -> Account {
        let institutionName = detection.issuer.rawValue
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.institution == institutionName }
        )

        if let existing = try? context.fetch(descriptor).first {
            return existing
        }

        Logger.pipeline.info("Auto-creating account for \(institutionName)")
        let account = Account(
            institution: institutionName,
            type: detection.suggestedAccountType,
            currency: "MXN"
        )
        context.insert(account)
        return account
    }

    private func resolveLegacyParser(for issuer: DetectedIssuer) -> (any StatementParser)? {
        switch issuer {
        case .openbankMexico:
            return OpenbankMexicoParser()
        case .amexMexico:
            return AmexMexicoParser()
        default:
            return nil
        }
    }

    private func createStatement(
        account: Account,
        rawTransactions: [RawTransaction],
        hash: String
    ) -> Statement {
        let dates = rawTransactions.map(\.postedAt)
        let periodStart = dates.min() ?? .now
        let periodEnd = dates.max() ?? .now

        let statement = Statement(
            account: account,
            periodStart: periodStart,
            periodEnd: periodEnd,
            sourceFileHash: hash
        )
        return statement
    }

    private func fetchExistingTransactions(for account: Account) -> [Transaction] {
        let accountId = account.id
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.account?.id == accountId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchCategoryRules() -> [CategoryRule] {
        let descriptor = FetchDescriptor<CategoryRule>()
        return (try? context.fetch(descriptor)) ?? []
    }

    private func persist(account: Account, statement: Statement, transactions: [Transaction]) {
        context.insert(account)
        context.insert(statement)
        for tx in transactions {
            context.insert(tx)
        }
    }
}
