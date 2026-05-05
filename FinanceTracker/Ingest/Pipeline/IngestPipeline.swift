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
            if let doc = PDFDocument(data: data), doc.isLocked {
                Logger.pipeline.warning("PDF is encrypted: \(fileName)")
                return IngestReport(
                    fileName: fileName,
                    errorCount: 1,
                    errors: [IngestError(message: "PDF is encrypted/password-protected")]
                )
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
                errors: [IngestError(message: "Could not identify financial institution")]
            )
        }

        let account = findOrCreateAccount(for: detection)

        guard let parser = resolveParser(for: detection.issuer) else {
            return IngestReport(
                fileName: fileName,
                errorCount: 1,
                errors: [IngestError(message: "No parser available for \(detection.issuer.rawValue)")]
            )
        }

        let rawTransactions: [RawTransaction]
        do {
            rawTransactions = try await parser.parse(data: data)
        } catch {
            Logger.pipeline.error("Parse error for \(fileName): \(error)")
            return IngestReport(
                fileName: fileName,
                errorCount: 1,
                errors: [IngestError(message: "Parse error: \(error.localizedDescription)")]
            )
        }

        guard !rawTransactions.isEmpty else {
            Logger.pipeline.warning("No transactions found in \(fileName)")
            return IngestReport(fileName: fileName)
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

    private func resolveParser(for issuer: DetectedIssuer) -> (any StatementParser)? {
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
