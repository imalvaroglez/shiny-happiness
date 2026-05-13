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
