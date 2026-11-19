import Foundation
import SwiftData
import Testing
@testable import FinanceTracker

/// Compatibilidad de restauración contra un respaldo REAL del usuario.
///
/// Se activa solo con la variable de entorno `FTBACKUP_PATH` apuntando a un
/// bundle `.ftbackup`; sin ella el test queda skip (la suite serial normal no
/// depende de datos externos). El respaldo original solo se lee: se trabaja
/// sobre una copia temporal y contenedores en disco temporales — jamás sobre
/// datos de producción.
///
/// Uso (nota: el host de pruebas corre con sandbox; un respaldo dentro de
/// ~/Documents bloquea en el diálogo de TCC sin nadie que lo conteste — copia
/// primero el bundle a una ruta no protegida, p. ej. /tmp, y apunta ahí):
///   cp -R ~/Documents/finanzas/FinanceTracker/X.ftbackup /tmp/real.ftbackup
///   TEST_RUNNER_FTBACKUP_PATH=/tmp/real.ftbackup xcodebuild test … \
///     -only-testing:FinanceTrackerTests/RealBackupRestoreCompatibilityTests
@Suite("Real backup restore compatibility")
@MainActor
struct RealBackupRestoreCompatibilityTests {
    nonisolated private static var backupPath: String? {
        ProcessInfo.processInfo.environment["FTBACKUP_PATH"]
    }

    @Test("User's real .ftbackup restores cleanly under the current schema and re-exports",
          .enabled(if: RealBackupRestoreCompatibilityTests.backupPath != nil,
                   .some("Set FTBACKUP_PATH to a real .ftbackup bundle to run this test")))
    func realBackupRestoresUnderCurrentSchema() async throws {
        let originalURL = URL(fileURLWithPath: try #require(Self.backupPath))
        #expect(FileManager.default.fileExists(atPath: originalURL.path),
                "\(originalURL.path) does not exist")

        // Copia temporal: el original jamás se abre en modo escritura.
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ftbackup-compat-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let bundle = work.appendingPathComponent("copy.ftbackup", isDirectory: true)
        try FileManager.default.copyItem(at: originalURL, to: bundle)

        // 1. El bundle real valida con las reglas actuales del lector.
        let summary = try #require(BackupArchive.summary(at: bundle), "Real bundle failed validation")
        print("REAL_BACKUP_COMPAT manifest_schema=\(summary.schemaVersion)")

        // 2. replaceAll sobre un contenedor en disco temporal (sin tocar el
        //    almacén de producción ni el Application Support real).
        let storeURL = work.appendingPathComponent("restore.store")
        let config = ModelConfiguration(schema: AppSchema.schema, url: storeURL)
        let container = try ModelContainer(
            for: AppSchema.schema,
            migrationPlan: FinanceTrackerMigrationPlan.self,
            configurations: [config]
        )
        let context = container.mainContext
        let support = work.appendingPathComponent("app-support", isDirectory: true)
        try FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        _ = try await BackupArchive.restore(
            from: bundle,
            into: context,
            strategy: .replaceAll,
            promotionLedgerURL: support.appendingPathComponent("PromotionLedger.json"),
            spendRequirementsURL: support.appendingPathComponent("SpendRequirement.json"),
            categoryCustomizationURL: support.appendingPathComponent("CategoryCustomization.json"),
            statementsDestination: support.appendingPathComponent("Statements", isDirectory: true),
            propertyLedgerURL: support.appendingPathComponent("PropertyLedger.json")
        )

        let accountCount = try context.fetchCount(FetchDescriptor<Account>())
        let transactionCount = try context.fetchCount(FetchDescriptor<Transaction>())
        #expect(accountCount > 0, "A real backup must restore at least one account")
        #expect(transactionCount > 0, "A real backup must restore at least one transaction")
        let linkCount = try context.fetchCount(FetchDescriptor<TransactionLink>())
        if summary.schemaVersion < 15 {
            #expect(linkCount == 0, "Pre-v15 backups must restore with zero refund links")
        }
        print("REAL_BACKUP_COMPAT restored accounts=\(accountCount) transactions=\(transactionCount) links=\(linkCount)")

        // 3. Round-trip: el almacén restaurado re-exporta y valida como v15.
        // Todas las fuentes sidecar apuntan al temporal — nada lee el
        // Application Support real.
        let reexport = work.appendingPathComponent("reexport.ftbackup", isDirectory: true)
        try await BackupArchive.export(
            to: reexport,
            from: context,
            promotionLedgerURL: support.appendingPathComponent("PromotionLedger.json"),
            spendRequirementsURL: support.appendingPathComponent("SpendRequirement.json"),
            categoryCustomizationURL: support.appendingPathComponent("CategoryCustomization.json"),
            statementsSource: support.appendingPathComponent("Statements", isDirectory: true),
            propertyLedgerURL: support.appendingPathComponent("PropertyLedger.json")
        )
        let reexportSummary = try #require(BackupArchive.summary(at: reexport), "Re-exported bundle failed validation")
        #expect(reexportSummary.schemaVersion == 15)
        print("REAL_BACKUP_COMPAT reexport_schema=\(reexportSummary.schemaVersion)")
    }
}
