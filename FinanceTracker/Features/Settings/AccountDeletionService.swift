import Foundation
import SwiftData

@MainActor
struct AccountDeletionService {
    struct DeletionPreview {
        let statementCount: Int
        let transactionCount: Int
        let balanceSnapshotCount: Int
        let pendingImportCount: Int
        let installmentPlanCount: Int
    }

    private struct LinkedObjects {
        let statements: [Statement]
        let transactions: [Transaction]
        let balanceSnapshots: [AccountBalanceSnapshot]
        let pendingImports: [PendingImport]
        let installmentPlans: [InstallmentPlan]
    }

    static func preview(account: Account, context: ModelContext) -> DeletionPreview {
        let linked = collectLinkedObjects(account: account, context: context)
        return DeletionPreview(
            statementCount: linked.statements.count,
            transactionCount: linked.transactions.count,
            balanceSnapshotCount: linked.balanceSnapshots.count,
            pendingImportCount: linked.pendingImports.count,
            installmentPlanCount: linked.installmentPlans.count
        )
    }

    static func delete(account: Account, context: ModelContext) throws {
        let linked = collectLinkedObjects(account: account, context: context)

        for plan in linked.installmentPlans { context.delete(plan) }
        for pending in linked.pendingImports { context.delete(pending) }
        for tx in linked.transactions { context.delete(tx) }
        for snapshot in linked.balanceSnapshots { context.delete(snapshot) }
        for stmt in linked.statements { context.delete(stmt) }
        context.delete(account)
        try context.save()
    }

    private static func collectLinkedObjects(account: Account, context: ModelContext) -> LinkedObjects {
        let accountId = account.id

        let statements = fetchWhere(context: context, accountId: accountId)
        let statementIDs = Set(statements.map(\.id))

        let directTransactions = fetchTransactions(context: context, accountId: accountId)
        let balanceSnapshots = fetchBalanceSnapshots(context: context, accountId: accountId)
        let statementTransactions = statements.flatMap(\.transactions)
        let allTransactions = mergeUnique(directTransactions, statementTransactions)
        let transactionIDs = Set(allTransactions.map(\.id))

        let directInstallments = fetchInstallmentPlans(context: context, accountId: accountId)
        let allInstallments = directInstallments.filter { plan in
            guard plan.account?.id == accountId else { return true }
            if let purchaseId = plan.originalPurchase?.id, transactionIDs.contains(purchaseId) { return true }
            if plan.installments.contains(where: { transactionIDs.contains($0.id) }) { return true }
            return true
        }

        let directPending = fetchPendingImports(context: context, accountId: accountId)
        let allPending = directPending.filter { pending in
            guard pending.account?.id == accountId else { return true }
            if let stmtId = pending.statement?.id, statementIDs.contains(stmtId) { return true }
            if let txId = pending.resolvedTransaction?.id, transactionIDs.contains(txId) { return true }
            return true
        }

        return LinkedObjects(
            statements: statements,
            transactions: allTransactions,
            balanceSnapshots: balanceSnapshots,
            pendingImports: allPending,
            installmentPlans: allInstallments
        )
    }

    private static func fetchWhere(context: ModelContext, accountId: UUID) -> [Statement] {
        let descriptor = FetchDescriptor<Statement>(
            predicate: #Predicate<Statement> { $0.account?.id == accountId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchTransactions(context: ModelContext, accountId: UUID) -> [Transaction] {
        let descriptor = FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.account?.id == accountId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchBalanceSnapshots(context: ModelContext, accountId: UUID) -> [AccountBalanceSnapshot] {
        let descriptor = FetchDescriptor<AccountBalanceSnapshot>(
            predicate: #Predicate<AccountBalanceSnapshot> { $0.account?.id == accountId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchInstallmentPlans(context: ModelContext, accountId: UUID) -> [InstallmentPlan] {
        let descriptor = FetchDescriptor<InstallmentPlan>(
            predicate: #Predicate<InstallmentPlan> { $0.account?.id == accountId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func fetchPendingImports(context: ModelContext, accountId: UUID) -> [PendingImport] {
        let descriptor = FetchDescriptor<PendingImport>(
            predicate: #Predicate<PendingImport> { $0.account?.id == accountId }
        )
        return (try? context.fetch(descriptor)) ?? []
    }

    private static func mergeUnique(_ a: [Transaction], _ b: [Transaction]) -> [Transaction] {
        var seen = Set<UUID>()
        var result: [Transaction] = []
        for tx in a + b {
            if seen.insert(tx.id).inserted {
                result.append(tx)
            }
        }
        return result
    }
}
