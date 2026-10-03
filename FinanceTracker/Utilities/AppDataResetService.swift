import Foundation
import SwiftData
import os

enum ResetRepairOutcome {
    case noRepairNeeded
    case repaired
    case hardResetRequested
}

enum ResetError: Error, LocalizedError {
    case verificationFailed(remaining: String)

    var errorDescription: String? {
        switch self {
        case .verificationFailed(let remaining):
            "Reset verification failed — rows remain: \(remaining)"
        }
    }
}

@MainActor
struct AppDataResetService {
    private static let logger = Logger(subsystem: "com.financeTracker.app", category: "AppDataResetService")

    static let allModelTypesInDeleteOrder: [any PersistentModel.Type] = [
        PendingImport.self,
        AccountBalanceSnapshot.self,
        StockPosition.self,
        HouseholdPartnerIncomeEstimate.self,
        SettlementDueDateOverride.self,
        Transaction.self,
        CategoryRule.self,
        InstallmentPlan.self,
        SignRecoveryHint.self,
        Statement.self,
        FinanceTracker.Category.self,
        Account.self,
    ]

    static func deletePersistentModels(from context: ModelContext) throws {
        try deleteAllObjects(of: PendingImport.self, from: context)
        try deleteAllObjects(of: AccountBalanceSnapshot.self, from: context)
        try deleteAllObjects(of: StockPosition.self, from: context)
        try deleteAllObjects(of: HouseholdPartnerIncomeEstimate.self, from: context)
        try deleteAllObjects(of: SettlementDueDateOverride.self, from: context)
        try deleteAllObjects(of: Transaction.self, from: context)
        try deleteAllObjects(of: CategoryRule.self, from: context)
        try deleteAllObjects(of: InstallmentPlan.self, from: context)
        try deleteAllObjects(of: SignRecoveryHint.self, from: context)
        try deleteAllObjects(of: Statement.self, from: context)
        try deleteAllObjects(of: FinanceTracker.Category.self, from: context)
        try deleteAllObjects(of: Account.self, from: context)
    }

    static func resetAllData(context: ModelContext, spendRequirementsURL: URL? = nil,
                             promotionLedgerURL: URL? = nil, categoryCustomizationURL: URL? = nil) throws {
        try deletePersistentModels(from: context)
        try context.save()
        try verifyCleanSlate(context: context)
        try SeedDataLoader.bootstrapIfNeeded(context: context)
        try SpendRequirementStore.reset(fileURL: spendRequirementsURL)
        try PromotionLedgerStore.reset(fileURL: promotionLedgerURL)
        try CategoryCustomizationStore.reset(fileURL: categoryCustomizationURL)
    }

    static func repairIncompleteResetIfNeeded(context: ModelContext) throws -> ResetRepairOutcome {
        let accountCount = try context.fetchCount(FetchDescriptor<Account>())
        guard accountCount == 0 else { return .noRepairNeeded }

        let txCount = try context.fetchCount(FetchDescriptor<Transaction>())
        let stmtCount = try context.fetchCount(FetchDescriptor<Statement>())
        let snapCount = try context.fetchCount(FetchDescriptor<AccountBalanceSnapshot>())
        let pendingCount = try context.fetchCount(FetchDescriptor<PendingImport>())
        let planCount = try context.fetchCount(FetchDescriptor<InstallmentPlan>())
        let hintCount = try context.fetchCount(FetchDescriptor<SignRecoveryHint>())
        let stockPositionCount = try context.fetchCount(FetchDescriptor<StockPosition>())
        let partnerEstimateCount = try context.fetchCount(FetchDescriptor<HouseholdPartnerIncomeEstimate>())
        let dueDateOverrideCount = try context.fetchCount(FetchDescriptor<SettlementDueDateOverride>())

        let totalOrphans = txCount + stmtCount + snapCount + pendingCount + planCount + hintCount + stockPositionCount + partnerEstimateCount + dueDateOverrideCount
        guard totalOrphans > 0 else { return .noRepairNeeded }

        logger.info("Repairing incomplete reset: \(totalOrphans) orphan rows (tx=\(txCount), stmt=\(stmtCount), snap=\(snapCount), pending=\(pendingCount), plan=\(planCount), hint=\(hintCount), stock=\(stockPositionCount), partnerEstimate=\(partnerEstimateCount))")

        try repairDeleteAll(from: context)
        try context.save()

        let remainingTx = try context.fetchCount(FetchDescriptor<Transaction>())
        let remainingStmt = try context.fetchCount(FetchDescriptor<Statement>())
        let remainingSnap = try context.fetchCount(FetchDescriptor<AccountBalanceSnapshot>())
        let remainingPending = try context.fetchCount(FetchDescriptor<PendingImport>())
        let remainingPlan = try context.fetchCount(FetchDescriptor<InstallmentPlan>())
        let remainingHint = try context.fetchCount(FetchDescriptor<SignRecoveryHint>())
        let remainingStockPosition = try context.fetchCount(FetchDescriptor<StockPosition>())
        let remainingPartnerEstimate = try context.fetchCount(FetchDescriptor<HouseholdPartnerIncomeEstimate>())
        let remainingDueDateOverride = try context.fetchCount(FetchDescriptor<SettlementDueDateOverride>())
        let remainingTotal = remainingTx + remainingStmt + remainingSnap + remainingPending + remainingPlan + remainingHint + remainingStockPosition + remainingPartnerEstimate + remainingDueDateOverride

        if remainingTotal > 0 {
            logger.error("Batch repair left \(remainingTotal) rows (tx=\(remainingTx), stmt=\(remainingStmt), snap=\(remainingSnap), pending=\(remainingPending), plan=\(remainingPlan), hint=\(remainingHint), stock=\(remainingStockPosition), partnerEstimate=\(remainingPartnerEstimate)) — requesting hard reset")
            StoreFileResetService.requestHardReset(reason: "Batch repair left \(remainingTotal) rows")
            return .hardResetRequested
        }

        try SeedDataLoader.bootstrapIfNeeded(context: context)
        logger.info("Repair complete")
        return .repaired
    }

    private static func repairDeleteAll(from context: ModelContext) throws {
        for type in allModelTypesInDeleteOrder {
            try context.delete(model: type)
        }
    }

    private static func verifyCleanSlate(context: ModelContext) throws {
        let checks: [(String, Int)] = [
            ("Account", try context.fetchCount(FetchDescriptor<Account>())),
            ("AccountBalanceSnapshot", try context.fetchCount(FetchDescriptor<AccountBalanceSnapshot>())),
            ("StockPosition", try context.fetchCount(FetchDescriptor<StockPosition>())),
            ("HouseholdPartnerIncomeEstimate", try context.fetchCount(FetchDescriptor<HouseholdPartnerIncomeEstimate>())),
            ("SettlementDueDateOverride", try context.fetchCount(FetchDescriptor<SettlementDueDateOverride>())),
            ("Transaction", try context.fetchCount(FetchDescriptor<Transaction>())),
            ("Statement", try context.fetchCount(FetchDescriptor<Statement>())),
            ("CategoryRule", try context.fetchCount(FetchDescriptor<CategoryRule>())),
            ("InstallmentPlan", try context.fetchCount(FetchDescriptor<InstallmentPlan>())),
            ("PendingImport", try context.fetchCount(FetchDescriptor<PendingImport>())),
            ("SignRecoveryHint", try context.fetchCount(FetchDescriptor<SignRecoveryHint>())),
            ("Category", try context.fetchCount(FetchDescriptor<FinanceTracker.Category>())),
        ]
        let remaining = checks.filter { $0.1 > 0 }
        if !remaining.isEmpty {
            let details = remaining.map { "\($0.0): \($0.1)" }.joined(separator: ", ")
            throw ResetError.verificationFailed(remaining: details)
        }
    }

    private static func deleteAllObjects<T: PersistentModel>(of type: T.Type, from context: ModelContext) throws {
        let objects = try context.fetch(FetchDescriptor<T>())
        for obj in objects {
            context.delete(obj)
        }
    }
}
