import SwiftUI
import SwiftData

struct SettingsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]
    @Query private var transactions: [Transaction]
    @State private var showDeleteConfirmation = false

    var body: some View {
        Form {
            accountsSection
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
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(account.institution)
                                .font(.body)
                            Text("\(account.type.rawValue) · \(account.currency)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        let txCount = transactions.filter { $0.account?.id == account.id }.count
                        Text("\(txCount) txns")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
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
