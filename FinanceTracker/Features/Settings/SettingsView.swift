import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]
    @Query private var transactions: [Transaction]
    @State private var showDeleteConfirmation = false
    @State private var showRestoreConfirmation = false
    @State private var isExporting = false
    @State private var isRestoring = false
    @State private var backupStatus = ""

    var body: some View {
        Form {
            accountsSection
            backupSection
            dataSection
            aboutSection
        }
        .navigationTitle("Settings")
    }

    private var accountsSection: some View {
        Section("Accounts") {
            if accounts.isEmpty {
                Text("No accounts imported yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(accounts) { account in
                    accountEditorRow(for: account)
                }
            }
        }
    }

    @ViewBuilder
    private func accountEditorRow(for account: Account) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(account.displayName)
                    .font(.headline)
                Spacer()
                Text("\(account.type.rawValue) · \(account.currency)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            TextField("Nickname", text: Binding(
                get: { account.nickname },
                set: { account.nickname = $0 }
            ))
            .textFieldStyle(.roundedBorder)

            HStack {
                ColorPicker("Identity color", selection: Binding(
                    get: { account.tintHex.flatMap { Color(hex: $0) } ?? AccountIdentity.color(for: account) },
                    set: { account.tintHex = $0.hexString }
                ))
            }

            if account.type == .creditCard {
                TextField("Credit limit", value: Binding(
                    get: { account.creditLimit ?? 0 },
                    set: { account.creditLimit = $0 }
                ), format: .currency(code: account.currency))
                .textFieldStyle(.roundedBorder)
            }

            let txCount = transactions.filter { $0.account?.id == account.id }.count
            Text("\(txCount) transactions")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var backupSection: some View {
        Section("Backup & Restore") {
            if !backupStatus.isEmpty {
                Text(backupStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                if let lastSnapshot = lastBackupDate {
                    LabeledContent("Last snapshot", value: lastSnapshot)
                } else {
                    Text("No snapshots yet")
                        .foregroundStyle(.secondary)
                }
            }

            LabeledContent("Snapshots on disk", value: "\(snapshotCount)")

            HStack(spacing: 12) {
                Button("Export backup…") { exportBackup() }
                    .disabled(isExporting)
                Button("Restore from backup…") { restoreBackup() }
                    .disabled(isRestoring)
                Button("Reveal in Finder") { revealBackupsFolder() }
            }

            Text("Backups include items in Recently Deleted.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private var lastBackupDate: String? {
        let fm = FileManager.default
        let dir = backupsDirectory
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let backups = files.filter { $0.pathExtension == "ftbackup" }
            .sorted(by: { $0.lastPathComponent > $1.lastPathComponent })
        guard let latest = backups.first else { return nil }
        let formatter = RelativeDateTimeFormatter()
        let date = backupDateFromFilename(latest.lastPathComponent)
        return formatter.localizedString(for: date ?? .distantPast, relativeTo: .now)
    }

    private var snapshotCount: Int {
        let fm = FileManager.default
        let dir = backupsDirectory
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return 0 }
        return files.filter { $0.pathExtension == "ftbackup" }.count
    }

    private var backupsDirectory: URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("FinanceTracker/Backups", isDirectory: true)
    }

    private func backupDateFromFilename(_ name: String) -> Date? {
        let base = name.replacingOccurrences(of: ".ftbackup", with: "")
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate, .withTime, .withDashSeparatorInDate]
        let normalized = base.replacingOccurrences(of: "-", with: "T", options: .literal, range: base.range(of: "-", options: .literal, range: base.index(base.startIndex, offsetBy: 10)..<base.endIndex))
        return formatter.date(from: normalized)
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "FinanceTracker-\(ISO8601DateFormatter().string(from: .now).replacingOccurrences(of: ":", with: "-")).ftbackup"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isExporting = true
        Task {
            do {
                try await BackupArchive.export(to: url, from: modelContext)
                backupStatus = "Export complete"
            } catch {
                backupStatus = "Export failed: \(error.localizedDescription)"
            }
            isExporting = false
        }
    }

    private func restoreBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isRestoring = true
        Task {
            do {
                try await BackupArchive.restore(from: url, into: modelContext, strategy: .mergeKeepingNewer)
                backupStatus = "Restore complete"
            } catch {
                backupStatus = "Restore failed: \(error.localizedDescription)"
            }
            isRestoring = false
        }
    }

    private func revealBackupsFolder() {
        let dir = backupsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
    }

    private var dataSection: some View {
        Section("Data") {
            LabeledContent("Accounts", value: "\(accounts.count)")
            LabeledContent("Transactions", value: "\(transactions.count)")

            Button(role: .destructive) {
                showDeleteConfirmation = true
            } label: {
                Text("Delete All Data")
            }
        }
        .alert("Delete All Data?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteAllData()
            }
        } message: {
            Text("This will permanently delete all accounts, transactions, and categories. This cannot be undone.")
        }
    }

    private var aboutSection: some View {
        Section("About") {
            LabeledContent("App", value: "FinanceTracker")
            LabeledContent("Version", value: appVersion)
        }
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func deleteAllData() {
        do {
            try modelContext.delete(model: Account.self)
            try modelContext.delete(model: Transaction.self)
            try modelContext.delete(model: Statement.self)
            try modelContext.delete(model: Category.self)
            try modelContext.delete(model: CategoryRule.self)
            try modelContext.save()
        } catch {
            NSLog("Failed to delete all data: %@", error.localizedDescription)
        }
    }
}

private extension Color {
    var hexString: String {
        #if os(macOS)
        let ns = NSColor(self).usingColorSpace(.deviceRGB) ?? .controlAccentColor
        let r = Int(round(ns.redComponent * 255))
        let g = Int(round(ns.greenComponent * 255))
        let b = Int(round(ns.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
        #else
        return "#000000"
        #endif
    }
}
