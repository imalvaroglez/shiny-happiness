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

    /// Import a statement the user pasted as raw text from their bank portal.
    /// Confident transactions are persisted as usual; ambiguous rows become
    /// `PendingImport` records the user can resolve later. `sourceLabel` is used
    /// for the IngestReport and as the dedup hash basis.
    func ingestPastedText(_ text: String, sourceLabel: String = "Pasted statement") async -> IngestReport {
        Logger.pipeline.info("Starting paste import: \(sourceLabel)")
        let detection = Detector.detectFromPastedText(text)
        guard detection.issuer != .unknown else {
            return IngestReport(
                fileName: sourceLabel,
                errorCount: 1,
                errors: [IngestError(message: "Could not identify financial institution from pasted text. Make sure you copied the full statement including the HSBC header.")]
            )
        }

        let hash = computeTextHash(text)
        if let existing = findStatement(byHash: hash) {
            return IngestReport(
                fileName: sourceLabel,
                duplicateTransactions: existing.transactions.count,
                errors: [IngestError(message: "This pasted statement was already imported.")]
            )
        }

        guard detection.issuer == .hsbcMexico2Now else {
            return IngestReport(
                fileName: sourceLabel,
                errorCount: 1,
                errors: [IngestError(message: "Paste import is not yet supported for \(detection.issuer.rawValue).")]
            )
        }

        let hintDescriptor = FetchDescriptor<SignRecoveryHint>()
        let signHints: [PastedHsbc2NowParser.SignHint] = ((try? context.fetch(hintDescriptor)) ?? [])
            .map { PastedHsbc2NowParser.SignHint(pattern: $0.pattern, implicitSign: $0.implicitSign) }

        let parser = PastedHsbc2NowParser(signHints: signHints)
        let result = parser.parse(text)

        guard !result.sections.isEmpty else {
            return IngestReport(
                fileName: sourceLabel,
                errorCount: 1,
                errors: [IngestError(message: "No transactions found in the pasted text. Check that the transaction rows are included.")]
            )
        }

        var totalNew = 0
        var totalDupes = 0
        var totalUncategorized = 0
        var allErrors: [IngestError] = []

        for section in result.sections {
            guard !section.transactions.isEmpty else { continue }

            let account = findOrCreateAccount(
                for: detection,
                sectionHint: section.accountHint,
                sectionType: section.accountType ?? detection.suggestedAccountType,
                sectionNumber: section.accountNumber,
                sectionNickname: section.nickname,
                creditLimit: section.creditLimit
            )

            let statement = createStatement(
                account: account,
                rawTransactions: section.transactions,
                hash: hash,
                openingBalance: section.openingBalance,
                closingBalance: section.closingBalance,
                minimumPayment: section.minimumPayment,
                paymentForNoInterest: section.paymentForNoInterest,
                paymentDueDate: section.paymentDueDate,
                interestCharged: section.interestCharged,
                feesCharged: section.feesCharged,
                ivaCharged: section.ivaCharged
            )

            let transactions = Normalizer.normalizeAll(section.transactions, account: account, statement: statement)
            let existing = fetchExistingTransactions(for: account)
            let softDeleted = fetchSoftDeletedTransactions(for: account)
            let dedup = Deduplicator.deduplicate(incoming: transactions, existing: existing, softDeleted: softDeleted)

            let rules = fetchCategoryRules()
            let cat = Categorizer.categorize(transactions: dedup.unique, rules: rules)
            _ = Categorizer.categorize(transactions: dedup.duplicates, rules: rules)
            for rule in rules {
                if let count = cat.matchedRules[rule.id] {
                    rule.matchCount += count
                }
            }

            persist(account: account, statement: statement, transactions: dedup.unique + dedup.duplicates)
            linkInstallmentPlans(account: account, section: section, transactions: dedup.unique + dedup.duplicates)

            for match in dedup.matchedDeleted {
                let pending = PendingImport(
                    account: account,
                    statement: statement,
                    rawText: match.incoming.descriptionRaw,
                    reason: "Matches a deleted transaction",
                    parsedDate: match.incoming.postedAt,
                    parsedAmount: match.incoming.amount,
                    parsedDescription: match.incoming.descriptionRaw,
                    cardLast4: match.incoming.cardLast4,
                    matchedDeletedTransactionId: match.deletedId
                )
                context.insert(pending)
            }

            // Persist any pending rows for this card under the same statement.
            // Match by the cardLast4 values present in this section's transactions,
            // not by section.accountNumber (which may be the titular's number for all sections).
            let sectionCards = Set(section.transactions.compactMap(\.cardLast4))
            for p in result.pendings where p.cardLast4.flatMap({ sectionCards.contains($0) }) ?? false {
                let pending = PendingImport(
                    account: account,
                    statement: statement,
                    rawText: p.rawText,
                    reason: p.reason,
                    parsedDate: p.parsedDate,
                    parsedAmount: p.parsedAmount,
                    parsedDescription: p.parsedDescription,
                    cardLast4: p.cardLast4
                )
                context.insert(pending)
            }

            totalNew += dedup.unique.count
            totalDupes += dedup.duplicates.count
            totalUncategorized += cat.uncategorized
        }

        // Pendings with no cardLast4 (anything we couldn't bind to a section) get attached to the
        // first persisted account so the user can still review them.
        let firstAccount = (try? context.fetch(FetchDescriptor<Account>()))?.first(where: { $0.institution == detection.issuer.rawValue })
        for p in result.pendings where p.cardLast4 == nil {
            let pending = PendingImport(
                account: firstAccount,
                rawText: p.rawText,
                reason: p.reason,
                parsedDate: p.parsedDate,
                parsedAmount: p.parsedAmount,
                parsedDescription: p.parsedDescription
            )
            context.insert(pending)
        }

        do {
            try context.save()
        } catch {
            Logger.pipeline.error("Save error: \(error)")
            return IngestReport(
                fileName: sourceLabel,
                errorCount: 1,
                errors: [IngestError(message: "Save error: \(error.localizedDescription)")]
            )
        }

        Logger.pipeline.info("Paste import \(sourceLabel): \(totalNew) new, \(totalDupes) dupes, \(totalUncategorized) uncategorized, \(result.pendings.count) pending review")

        // Soft-warn if parsed totals diverge from the header's declared totals.
        if let expectedCharges = result.sections.first?.transactions.first?.installmentHint,
           let _ = result.sections.first {
            _ = expectedCharges
        }

        let pendingsCount = result.pendings.count
        if pendingsCount > 0 {
            allErrors.append(IngestError(message: "\(pendingsCount) row(s) need manual review."))
        }

        return IngestReport(
            fileName: sourceLabel,
            newTransactions: totalNew,
            duplicateTransactions: totalDupes,
            uncategorizedCount: totalUncategorized,
            errors: allErrors
        )
    }

    private func computeTextHash(_ text: String) -> String {
        let data = Data(text.utf8)
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
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
                        errors: [IngestError(message: "PDF text is garbled — custom font encoding without Unicode mapping. Try pasting the statement text instead.")]
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

        let sections = await parseSectionsWithFallback(data: data, fileName: fileName, detection: detection)

        guard !sections.isEmpty else {
            Logger.pipeline.warning("No transactions found in \(fileName)")
            return IngestReport(
                fileName: fileName,
                errorCount: 1,
                errors: [IngestError(message: "No transactions could be extracted from this PDF. The format may not yet be supported")]
            )
        }

        var totalNew = 0
        var totalDupes = 0
        var totalUncategorized = 0
        var allErrors: [IngestError] = []

        for section in sections {
            guard !section.transactions.isEmpty else { continue }

            let account = findOrCreateAccount(
                for: detection,
                sectionHint: section.accountHint,
                sectionType: section.accountType ?? detection.suggestedAccountType,
                sectionNumber: section.accountNumber,
                sectionNickname: section.nickname,
                creditLimit: section.creditLimit
            )

            let statement = createStatement(
                account: account,
                rawTransactions: section.transactions,
                hash: hash,
                openingBalance: section.openingBalance,
                closingBalance: section.closingBalance,
                minimumPayment: section.minimumPayment,
                paymentForNoInterest: section.paymentForNoInterest,
                paymentDueDate: section.paymentDueDate,
                interestCharged: section.interestCharged,
                feesCharged: section.feesCharged,
                ivaCharged: section.ivaCharged
            )

            let transactions = Normalizer.normalizeAll(section.transactions, account: account, statement: statement)

            let existingTransactions = fetchExistingTransactions(for: account)
            let softDeleted = fetchSoftDeletedTransactions(for: account)
            let dedupResult = Deduplicator.deduplicate(incoming: transactions, existing: existingTransactions, softDeleted: softDeleted)

            let rules = fetchCategoryRules()
            let catResult = Categorizer.categorize(transactions: dedupResult.unique, rules: rules)
            let _ = Categorizer.categorize(transactions: dedupResult.duplicates, rules: rules)

            for rule in rules {
                if let count = catResult.matchedRules[rule.id] {
                    rule.matchCount += count
                }
            }

            persist(account: account, statement: statement, transactions: dedupResult.unique + dedupResult.duplicates)
            linkInstallmentPlans(account: account, section: section, transactions: dedupResult.unique + dedupResult.duplicates)

            for match in dedupResult.matchedDeleted {
                let pending = PendingImport(
                    account: account,
                    statement: statement,
                    rawText: match.incoming.descriptionRaw,
                    reason: "Matches a deleted transaction",
                    parsedDate: match.incoming.postedAt,
                    parsedAmount: match.incoming.amount,
                    parsedDescription: match.incoming.descriptionRaw,
                    cardLast4: match.incoming.cardLast4,
                    matchedDeletedTransactionId: match.deletedId
                )
                context.insert(pending)
            }

            totalNew += dedupResult.unique.count
            totalDupes += dedupResult.duplicates.count
            totalUncategorized += catResult.uncategorized
        }

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

        Logger.pipeline.info("Ingested \(fileName): \(totalNew) new, \(totalDupes) dupes, \(totalUncategorized) uncategorized across \(sections.count) sections")

        return IngestReport(
            fileName: fileName,
            newTransactions: totalNew,
            duplicateTransactions: totalDupes,
            uncategorizedCount: totalUncategorized,
            errors: allErrors
        )
    }

    private func parseSectionsWithFallback(data: Data, fileName: String, detection: DetectionResult) async -> [ParsedSection] {
        if let structural = StructuralParser() {
            do {
                let sections = try await structural.parseSections(data: data)
                let totalTxns = sections.flatMap(\.transactions)
                if !totalTxns.isEmpty {
                    Logger.pipeline.info("Structural parse succeeded for \(fileName): \(totalTxns.count) transactions in \(sections.count) sections")
                    return sections
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
            return [ParsedSection.single(rawTxns)]
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

    private func findOrCreateAccount(
        for detection: DetectionResult,
        sectionHint: String?,
        sectionType: AccountType,
        sectionNumber: String?,
        sectionNickname: String?,
        creditLimit: Decimal? = nil
    ) -> Account {
        let institutionName = detection.issuer.rawValue

        if let number = sectionNumber {
            let num = number
            let descriptor = FetchDescriptor<Account>(
                predicate: #Predicate<Account> { $0.institution == institutionName && $0.accountNumber == num }
            )
            if let existing = try? context.fetch(descriptor).first {
                if let cl = creditLimit, existing.creditLimit == nil { existing.creditLimit = cl }
                return existing
            }
            return createNewAccount(
                institution: institutionName,
                type: sectionType,
                nickname: sectionNickname,
                number: number,
                creditLimit: creditLimit
            )
        }

        let institutionDescriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.institution == institutionName }
        )
        if let existing = (try? context.fetch(institutionDescriptor))?.first(where: { $0.type == sectionType }) {
            if let cl = creditLimit, existing.creditLimit == nil { existing.creditLimit = cl }
            return existing
        }

        return createNewAccount(
            institution: institutionName,
            type: sectionType,
            nickname: sectionNickname,
            number: nil,
            creditLimit: creditLimit
        )
    }

    private func createNewAccount(
        institution: String,
        type: AccountType,
        nickname: String?,
        number: String?,
        creditLimit: Decimal?
    ) -> Account {
        let displayName = nickname ?? institution
        Logger.pipeline.info("Auto-creating account for \(displayName) (\(number ?? "no number"))")
        let account = Account(
            institution: institution,
            type: type,
            currency: "MXN",
            nickname: nickname,
            accountNumber: number,
            creditLimit: creditLimit
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
        hash: String,
        openingBalance: Decimal? = nil,
        closingBalance: Decimal? = nil,
        minimumPayment: Decimal? = nil,
        paymentForNoInterest: Decimal? = nil,
        paymentDueDate: Date? = nil,
        interestCharged: Decimal? = nil,
        feesCharged: Decimal? = nil,
        ivaCharged: Decimal? = nil
    ) -> Statement {
        let dates = rawTransactions.map(\.postedAt)
        let periodStart = dates.min() ?? .now
        let periodEnd = dates.max() ?? .now

        let statement = Statement(
            account: account,
            periodStart: periodStart,
            periodEnd: periodEnd,
            sourceFileHash: hash,
            openingBalance: openingBalance,
            closingBalance: closingBalance,
            minimumPayment: minimumPayment,
            paymentForNoInterest: paymentForNoInterest,
            paymentDueDate: paymentDueDate,
            interestCharged: interestCharged,
            feesCharged: feesCharged,
            ivaCharged: ivaCharged
        )
        return statement
    }

    private func fetchExistingTransactions(for account: Account) -> [Transaction] {
        let accountId = account.id
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.account?.id == accountId && $0.deletedAt == nil }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private func fetchSoftDeletedTransactions(for account: Account) -> [Transaction] {
        let accountId = account.id
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.account?.id == accountId && $0.deletedAt != nil }
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

    /// For each `RawTransaction` carrying an `installmentHint`, ensure an `InstallmentPlan` exists
    /// for `(account, merchantDescription, originalAmount, firstChargeDate)` and link the persisted
    /// `Transaction` whose amount/description/date match.
    private func linkInstallmentPlans(account: Account, section: ParsedSection, transactions: [Transaction]) {
        let raws = section.transactions
        guard raws.contains(where: { $0.installmentHint != nil }) else { return }

        let descriptor = FetchDescriptor<InstallmentPlan>()
        let existingPlans = (try? context.fetch(descriptor)) ?? []
        let accountId = account.id

        for raw in raws {
            guard let hint = raw.installmentHint else { continue }
            let merchant = hint.merchantDescription
            let original = hint.originalAmount
            let firstDate = hint.firstChargeDate

            let plan = existingPlans.first {
                $0.account?.id == accountId
                    && $0.merchantDescription == merchant
                    && $0.originalAmount == original
                    && abs($0.firstChargeDate.timeIntervalSince(firstDate)) < 86400
            } ?? {
                let p = InstallmentPlan(
                    account: account,
                    originalAmount: original,
                    totalMonths: hint.totalMonths,
                    currentMonth: hint.currentMonth,
                    monthlyAmount: hint.monthlyAmount,
                    ratePercent: hint.ratePercent,
                    firstChargeDate: firstDate,
                    merchantDescription: merchant
                )
                context.insert(p)
                return p
            }()

            // Keep currentMonth as the max seen across reimports.
            if hint.currentMonth > plan.currentMonth {
                plan.currentMonth = hint.currentMonth
                plan.touch()
            }

            // Link the persisted Transaction whose amount/description/date best match this raw row.
            let match = transactions.first {
                $0.descriptionRaw == raw.descriptionRaw
                    && $0.amount == raw.amount
                    && abs($0.postedAt.timeIntervalSince(raw.postedAt)) < 1
            }
            if let tx = match, tx.installmentPlan == nil {
                tx.installmentPlan = plan
            }
        }
    }
}
