import Foundation
import SwiftData

enum TransactionLinkError: Error, LocalizedError, Equatable {
    case invalidRefund
    case refundExceedsPurchase

    var errorDescription: String? {
        switch self {
        case .invalidRefund: String(localized: "Choose an eligible purchase and a matching refund in the same currency.")
        case .refundExceedsPurchase: String(localized: "The refund is greater than the remaining purchase amount.")
        }
    }
}

struct TransactionRefundProjection {
    let linkedRefunds: [Transaction]
    let appliedRefunds: [Transaction]
    let refundedAmount: Decimal
    let netExpenseAmount: Decimal
    let isValid: Bool
    let invalidReason: String?
}

struct DashboardRefundData {
    let refundedAmountByPurchaseID: [UUID: Decimal]
    let refundsByPurchaseID: [UUID: [Transaction]]
    let linkedRefundIDs: Set<UUID>
    let classificationsByTransactionID: [UUID: TransactionClassification]
}

/// One-pass snapshot of active refund links, sized for picker candidate lists.
struct RefundLinkSummary: Equatable {
    /// Remaining refundable amount per purchase that has active links
    /// (purchases without links keep their full amount refundable).
    var remainingByPurchaseID: [UUID: Decimal] = [:]
    /// Refund IDs with an active link to any purchase.
    var linkedRefundIDs: Set<UUID> = []
    /// Current link target (purchase) per refund ID.
    var activeTargetByRefundID: [UUID: UUID] = [:]
}

@MainActor
enum TransactionLinkService {
    static func refundIdentityKey(refundID: UUID) -> String {
        "refund:\(refundID.uuidString.lowercased())"
    }

    static func isEligiblePurchaseCandidate(
        _ transaction: Transaction,
        classification: TransactionClassification? = nil
    ) -> Bool {
        isEligiblePurchase(transaction, classification: classification)
    }

    static func isEligibleRefundCandidate(
        _ refund: Transaction,
        for purchase: Transaction,
        purchaseIsEligible: Bool? = nil,
        refundClassification: TransactionClassification? = nil
    ) -> Bool {
        guard refund.postedAt >= purchase.postedAt,
              isEligibleRefund(refund, for: purchase, classification: refundClassification) else { return false }
        return purchaseIsEligible ?? isEligiblePurchase(purchase)
    }

    static func linkRefund(refund: Transaction, purchase: Transaction, context: ModelContext, at date: Date = .now) throws {
        guard refund.id != purchase.id,
              isEligiblePurchase(purchase),
              isEligibleRefund(refund, for: purchase),
              refund.postedAt >= purchase.postedAt else {
            throw TransactionLinkError.invalidRefund
        }

        let identityKey = refundIdentityKey(refundID: refund.id)
        let refundLinks = try activeRefundLinks(forRefundIDs: Set([refund.id]), context: context)
        guard refundLinks.count <= 1,
              refundLinks.allSatisfy({ $0.identityKey == identityKey }) else {
            throw TransactionLinkError.invalidRefund
        }
        let existingRefunds = try activeRefundLinks(for: purchase.id, context: context)
            .filter { $0.sourceTransactionID != refund.id }
        let refundMap = try transactions(withIDs: Set(existingRefunds.map(\.sourceTransactionID)), context: context)
        let alreadyRefunded = existingRefunds.compactMap { refundMap[$0.sourceTransactionID] }
            .filter { isEligibleRefund($0, for: purchase) && $0.postedAt >= purchase.postedAt && $0.postedAt <= date }
            .reduce(Decimal.zero) { $0 + $1.amount }
        let newRefundAmount = refund.postedAt <= date ? refund.amount : Decimal.zero
        guard alreadyRefunded + newRefundAmount <= abs(purchase.amount) else {
            throw TransactionLinkError.refundExceedsPurchase
        }

        let link = try linkForIdentity(identityKey, context: context)
        if let link {
            let previous = (link.sourceTransactionID, link.targetTransactionID, link.kindRaw, link.deletedAt, link.lastModifiedAt)
            link.sourceTransactionID = refund.id
            link.targetTransactionID = purchase.id
            link.kindRaw = TransactionLinkKind.refund.rawValue
            link.deletedAt = nil
            link.lastModifiedAt = date
            do {
                try context.save()
            } catch {
                link.sourceTransactionID = previous.0
                link.targetTransactionID = previous.1
                link.kindRaw = previous.2
                link.deletedAt = previous.3
                link.lastModifiedAt = previous.4
                throw error
            }
        } else {
            let link = TransactionLink(
                id: TransactionLink.stableID(for: identityKey),
                identityKey: identityKey,
                kind: .refund,
                sourceTransactionID: refund.id,
                targetTransactionID: purchase.id,
                lastModifiedAt: date
            )
            context.insert(link)
            do {
                try context.save()
            } catch {
                context.delete(link)
                throw error
            }
        }
    }

    static func removeRefund(refund: Transaction, context: ModelContext, at date: Date = .now) throws {
        try removeRefund(refundID: refund.id, context: context, at: date)
    }

    static func removeRefund(refundID: UUID, context: ModelContext, at date: Date = .now) throws {
        guard let link = try linkForIdentity(refundIdentityKey(refundID: refundID), context: context),
              link.deletedAt == nil else { return }
        let previousDeletedAt = link.deletedAt
        let previousModifiedAt = link.lastModifiedAt
        link.deletedAt = date
        link.lastModifiedAt = date
        do {
            try context.save()
        } catch {
            link.deletedAt = previousDeletedAt
            link.lastModifiedAt = previousModifiedAt
            throw error
        }
    }

    static func refundProjection(for purchase: Transaction, context: ModelContext, asOf date: Date = .now) throws -> TransactionRefundProjection {
        let links = try activeRefundLinks(for: purchase.id, context: context)
        let refunds = try transactions(withIDs: Set(links.map(\.sourceTransactionID)), context: context)
        let linkedRefunds = links.compactMap { refunds[$0.sourceTransactionID] }
        let missingRefundCount = links.count - linkedRefunds.count
        let linksByRefund = Dictionary(grouping: try activeRefundLinks(
            forRefundIDs: Set(links.map(\.sourceTransactionID)), context: context
        ), by: \.sourceTransactionID)
        let appliedCandidates = linkedRefunds.filter { $0.postedAt <= date }
        let valid = isEligiblePurchase(purchase)
            && missingRefundCount == 0
            && links.allSatisfy { linksByRefund[$0.sourceTransactionID]?.count == 1 }
            && Set(links.map(\.sourceTransactionID)).count == links.count
            && linkedRefunds.allSatisfy { isEligibleRefund($0, for: purchase) && $0.postedAt >= purchase.postedAt }
            && appliedCandidates.reduce(Decimal.zero) { $0 + $1.amount } <= abs(purchase.amount)
        let reason: String?
        if valid {
            reason = nil
        } else if missingRefundCount > 0 {
            reason = String(localized: "A linked refund is unavailable.")
        } else if appliedCandidates.reduce(Decimal.zero, { $0 + $1.amount }) > abs(purchase.amount) {
            reason = String(localized: "Linked refunds exceed the current purchase amount.")
        } else {
            reason = String(localized: "A linked movement no longer qualifies as a purchase or refund.")
        }
        let appliedRefunds = valid ? appliedCandidates : []
        let refundedAmount = appliedRefunds.reduce(Decimal.zero) { $0 + $1.amount }
        return TransactionRefundProjection(
            linkedRefunds: linkedRefunds,
            appliedRefunds: appliedRefunds,
            refundedAmount: refundedAmount,
            netExpenseAmount: max(Decimal.zero, abs(purchase.amount) - refundedAmount),
            isValid: valid,
            invalidReason: reason
        )
    }

    static func isAppliedRefund(_ refund: Transaction, context: ModelContext, asOf date: Date = .now) throws -> Bool {
        guard let link = try linkForIdentity(refundIdentityKey(refundID: refund.id), context: context),
              link.deletedAt == nil,
              let purchase = try transactions(withIDs: [link.targetTransactionID], context: context)[link.targetTransactionID] else {
            return false
        }
        let projection = try refundProjection(for: purchase, context: context, asOf: date)
        return projection.isValid && projection.appliedRefunds.contains { $0.id == refund.id }
    }

    static func dashboardRefundData(
        for transactionsInPeriod: [Transaction],
        context: ModelContext,
        asOf date: Date = .now,
        classificationFor: ((Transaction) -> TransactionClassification?)? = nil
    ) throws -> DashboardRefundData {
        guard !transactionsInPeriod.isEmpty else {
            return DashboardRefundData(
                refundedAmountByPurchaseID: [:],
                refundsByPurchaseID: [:],
                linkedRefundIDs: [],
                classificationsByTransactionID: [:]
            )
        }
        let refundKind = TransactionLinkKind.refund.rawValue
        let links = try context.fetch(FetchDescriptor<TransactionLink>(
            predicate: #Predicate { $0.kindRaw == refundKind && $0.deletedAt == nil }
        ))
        let refundLinkCounts = Dictionary(grouping: links, by: \.sourceTransactionID).mapValues { $0.count }
        let periodIDs = Set(transactionsInPeriod.map(\.id))
        let relevantLinks = links.filter { periodIDs.contains($0.sourceTransactionID) || periodIDs.contains($0.targetTransactionID) }
        let relevantPurchaseIDs = Set(relevantLinks.map(\.targetTransactionID))
        let purchaseLinks = links.filter { relevantPurchaseIDs.contains($0.targetTransactionID) }
        let endpointIDs = Set(purchaseLinks.flatMap { [$0.sourceTransactionID, $0.targetTransactionID] })
        var endpointMap = Dictionary(
            transactionsInPeriod.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let endpointIDsOutsidePeriod = endpointIDs.subtracting(endpointMap.keys)
        endpointMap.merge(try transactions(withIDs: endpointIDsOutsidePeriod, context: context)) { first, _ in first }
        var refundsByPurchase: [UUID: Decimal] = [:]
        var refundTransactionsByPurchase: [UUID: [Transaction]] = [:]
        var linkedRefundIDs: Set<UUID> = []
        var classificationsByTransactionID: [UUID: TransactionClassification] = [:]
        let classifier = TransactionClassifier()
        func classification(for transaction: Transaction) -> TransactionClassification {
            if let cached = classificationsByTransactionID[transaction.id] { return cached }
            let value = classificationFor?(transaction) ?? classifier.classify(transaction: transaction)
            classificationsByTransactionID[transaction.id] = value
            return value
        }
        let byPurchase = Dictionary(grouping: purchaseLinks, by: \.targetTransactionID)
        for (purchaseID, group) in byPurchase {
            guard let purchase = endpointMap[purchaseID] else { continue }
            let refunds = group.compactMap { endpointMap[$0.sourceTransactionID] }
            let valid = group.count == refunds.count
                && Set(group.map(\.sourceTransactionID)).count == group.count
                && group.allSatisfy { refundLinkCounts[$0.sourceTransactionID] == 1 }
                && isEligiblePurchase(purchase, classification: classification(for: purchase))
                && refunds.allSatisfy {
                    isEligibleRefund($0, for: purchase, classification: classification(for: $0))
                        && $0.postedAt >= purchase.postedAt
                }
                && refunds.filter { $0.postedAt <= date }.reduce(Decimal.zero) { $0 + $1.amount } <= abs(purchase.amount)
            guard valid else { continue }
            for refund in refunds where refund.postedAt <= date {
                refundsByPurchase[purchaseID, default: 0] += refund.amount
                refundTransactionsByPurchase[purchaseID, default: []].append(refund)
                linkedRefundIDs.insert(refund.id)
            }
        }
        return DashboardRefundData(
            refundedAmountByPurchaseID: refundsByPurchase,
            refundsByPurchaseID: refundTransactionsByPurchase,
            linkedRefundIDs: linkedRefundIDs,
            classificationsByTransactionID: classificationsByTransactionID
        )
    }

    static func hasActiveRefundLinks(context: ModelContext) throws -> Bool {
        let refundKind = TransactionLinkKind.refund.rawValue
        var descriptor = FetchDescriptor<TransactionLink>(
            predicate: #Predicate { $0.kindRaw == refundKind && $0.deletedAt == nil }
        )
        descriptor.fetchLimit = 1
        let links = try context.fetch(descriptor)
        return !links.isEmpty
    }

    static func refundLinkSummary(context: ModelContext, asOf date: Date = .now) throws -> RefundLinkSummary {
        let refundKind = TransactionLinkKind.refund.rawValue
        let links = try context.fetch(FetchDescriptor<TransactionLink>(
            predicate: #Predicate { $0.kindRaw == refundKind && $0.deletedAt == nil }
        ))
        var summary = RefundLinkSummary()
        guard !links.isEmpty else { return summary }
        let purchaseMap = try transactions(withIDs: Set(links.map(\.targetTransactionID)), context: context)
        let refundMap = try transactions(withIDs: Set(links.map(\.sourceTransactionID)), context: context)
        let byPurchase = Dictionary(grouping: links, by: \.targetTransactionID)
        for (purchaseID, group) in byPurchase {
            for link in group {
                summary.linkedRefundIDs.insert(link.sourceTransactionID)
                summary.activeTargetByRefundID[link.sourceTransactionID] = link.targetTransactionID
            }
            guard let purchase = purchaseMap[purchaseID], isEligiblePurchase(purchase) else { continue }
            let refunded = group.compactMap { refundMap[$0.sourceTransactionID] }
                .filter { isEligibleRefund($0, for: purchase) && $0.postedAt >= purchase.postedAt && $0.postedAt <= date }
                .reduce(Decimal.zero) { $0 + $1.amount }
            summary.remainingByPurchaseID[purchaseID] = max(Decimal.zero, abs(purchase.amount) - refunded)
        }
        return summary
    }

    static func refundLinks(for transaction: Transaction, context: ModelContext) throws -> [TransactionLink] {
        let id = transaction.id
        let refundKind = TransactionLinkKind.refund.rawValue
        return try context.fetch(FetchDescriptor<TransactionLink>(
            predicate: #Predicate {
                $0.kindRaw == refundKind
                    && $0.deletedAt == nil
                    && ($0.sourceTransactionID == id || $0.targetTransactionID == id)
            },
            sortBy: [SortDescriptor(\.lastModifiedAt, order: .reverse)]
        ))
    }

    /// Importe de la compra aún sin reembolsar: lo que un reembolso nuevo puede
    /// cubrir sin exceder la compra. Solo cuenta reembolsos activos vigentes.
    static func remainingRefundAmount(for purchase: Transaction, context: ModelContext, asOf date: Date = .now) throws -> Decimal {
        guard isEligiblePurchase(purchase) else { return Decimal.zero }
        let links = try activeRefundLinks(for: purchase.id, context: context)
        let refundMap = try transactions(withIDs: Set(links.map(\.sourceTransactionID)), context: context)
        let alreadyRefunded = links.compactMap { refundMap[$0.sourceTransactionID] }
            .filter { isEligibleRefund($0, for: purchase) && $0.postedAt >= purchase.postedAt && $0.postedAt <= date }
            .reduce(Decimal.zero) { $0 + $1.amount }
        return max(Decimal.zero, abs(purchase.amount) - alreadyRefunded)
    }

    /// Pre-validación del formulario de captura: comprueba el borrador del
    /// reembolso contra la compra elegida ANTES de persistir el movimiento.
    /// Lanza `TransactionLinkError` cuando el vínculo no es viable; un fallo de
    /// lectura del almacén se propaga como tal, sin disfrazarse de validación.
    static func validateRefundDraft(
        amount: Decimal,
        currency: String,
        postedAt: Date,
        purchase: Transaction,
        context: ModelContext
    ) throws {
        guard isEligiblePurchase(purchase) else { throw TransactionLinkError.invalidRefund }
        guard amount > 0, currency == purchase.currency, postedAt >= purchase.postedAt else {
            throw TransactionLinkError.invalidRefund
        }
        let remaining = try remainingRefundAmount(for: purchase, context: context, asOf: postedAt)
        guard amount <= remaining else { throw TransactionLinkError.refundExceedsPurchase }
    }

    private static func activeRefundLinks(for purchaseID: UUID, context: ModelContext) throws -> [TransactionLink] {
        let refundKind = TransactionLinkKind.refund.rawValue
        return try context.fetch(FetchDescriptor<TransactionLink>(
            predicate: #Predicate {
                $0.kindRaw == refundKind
                    && $0.targetTransactionID == purchaseID
                    && $0.deletedAt == nil
            }
        ))
    }

    private static func activeRefundLinks(forRefundIDs refundIDs: Set<UUID>, context: ModelContext) throws -> [TransactionLink] {
        guard !refundIDs.isEmpty else { return [] }
        let refundKind = TransactionLinkKind.refund.rawValue
        return try context.fetch(FetchDescriptor<TransactionLink>(
            predicate: #Predicate {
                $0.kindRaw == refundKind
                    && $0.deletedAt == nil
                    && refundIDs.contains($0.sourceTransactionID)
            }
        ))
    }

    private static func linkForIdentity(_ identityKey: String, context: ModelContext) throws -> TransactionLink? {
        try context.fetch(FetchDescriptor<TransactionLink>(
            predicate: #Predicate { $0.identityKey == identityKey },
            sortBy: [SortDescriptor(\.lastModifiedAt, order: .reverse)]
        )).first
    }

    static func transactions(withIDs ids: Set<UUID>, context: ModelContext) throws -> [UUID: Transaction] {
        guard !ids.isEmpty else { return [:] }
        let rows = try context.fetch(FetchDescriptor<Transaction>(predicate: #Predicate { ids.contains($0.id) }))
        return Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    static func transactions(withIDs ids: [UUID], context: ModelContext) throws -> [UUID: Transaction] {
        try transactions(withIDs: Set(ids), context: context)
    }

    private static func isEligiblePurchase(
        _ transaction: Transaction,
        classification: TransactionClassification? = nil
    ) -> Bool {
        transaction.deletedAt == nil
            && !transaction.isDuplicate
            && !transaction.isTransfer
            && (classification ?? TransactionClassifier().classify(transaction: transaction)).countsAsRegularExpense
    }

    private static func isEligibleRefund(
        _ refund: Transaction,
        for purchase: Transaction,
        classification: TransactionClassification? = nil
    ) -> Bool {
        guard refund.deletedAt == nil,
              !refund.isDuplicate,
              !refund.isTransfer,
              refund.amount > 0,
              refund.currency == purchase.currency,
              !TransactionClassifier.isSynthesizedMSIPurchase(refund) else { return false }
        if refund.account?.type == .creditCard {
            return refund.flowKind == .cardCredit && refund.movementKind == .adjustment
        }
        return refund.account?.type.isLiability == false
            && refund.movementKind == .income
            && (classification ?? TransactionClassifier().classify(transaction: refund)).countsAsRegularIncome
    }
}
