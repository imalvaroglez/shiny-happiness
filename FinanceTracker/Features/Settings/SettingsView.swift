import SwiftUI
import SwiftData

private struct AccountDeletionTarget {
    let id: UUID
    let displayName: String
    let preview: AccountDeletionService.DeletionPreview
}

private enum SettingsFocusField: Hashable {
    case newCategoryName
    case newSubcategoryName
}

struct SettingsView: View {
    var onAccountDeleted: (UUID) -> Void = { _ in }
    var onAccountCreated: (Account) -> Void = { _ in }
    var onDataReset: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]
    @Query private var transactions: [Transaction]
    @Query(filter: #Predicate<Category> { $0.deletedAt == nil }) private var categories: [Category]
    @Query(filter: #Predicate<PendingImport> { $0.resolvedTransaction == nil })
    private var pendingImports: [PendingImport]
    @Query private var installmentPlans: [InstallmentPlan]

    @State private var showDeleteConfirmation = false
    @State private var isExporting = false
    @State private var isRestoring = false
    @State private var backupStatus = ""
    @State private var resetErrorMessage: String?

    @State private var accountDeletionTarget: AccountDeletionTarget?
    @State private var showingAddAccount = false
    @State private var balanceSnapshotAccount: Account?

    @State private var showingNewCategory = false
    @State private var newCategoryName = ""
    @State private var newCategoryKind: CategoryKind = .expense
    @State private var subcategoryParent: Category?
    @State private var newSubcategoryName = ""
    @State private var categoryErrorMessage: String?

    @FocusState private var focusedField: SettingsFocusField?

    private var transactionCountsByAccountID: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for account in accounts {
            let accountId = account.id
            let descriptor = FetchDescriptor<Transaction>(
                predicate: #Predicate<Transaction> { $0.account?.id == accountId }
            )
            counts[accountId] = ((try? modelContext.fetch(descriptor)) ?? []).count
        }
        return counts
    }

    private func fetchAccount(id: UUID) -> Account? {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 16) {
                accountsSection
                categoriesSection
                adaptiveGridRow
                aboutSection
            }
            .frame(maxWidth: 1180)
            .frame(maxWidth: .infinity)
            .padding()
        }
        .navigationTitle("Settings")
        .alert("Delete Account?", isPresented: Binding(
            get: { accountDeletionTarget != nil },
            set: { if !$0 { accountDeletionTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                accountDeletionTarget = nil
            }
            Button("Delete", role: .destructive) {
                if let target = accountDeletionTarget,
                   let account = fetchAccount(id: target.id) {
                    do {
                        balanceSnapshotAccount = nil
                        try AccountDeletionService.delete(account: account, context: modelContext)
                        onAccountDeleted(target.id)
                    } catch {
                        NSLog("Failed to delete account: %@", error.localizedDescription)
                    }
                }
                accountDeletionTarget = nil
            }
        } message: {
            if let target = accountDeletionTarget {
                Text("Permanently delete \"\(target.displayName)\"? This will remove \(target.preview.statementCount) statement(s), \(target.preview.transactionCount) transaction(s), \(target.preview.balanceSnapshotCount) balance snapshot(s), \(target.preview.pendingImportCount) pending import(s), and \(target.preview.installmentPlanCount) installment plan(s). This cannot be undone.")
            } else {
                Text("Are you sure?")
            }
        }
        .alert("Reset Error", isPresented: Binding(
            get: { resetErrorMessage != nil },
            set: { if !$0 { resetErrorMessage = nil } }
        )) {
            Button("OK") { resetErrorMessage = nil }
        } message: {
            Text(resetErrorMessage ?? "An unknown error occurred.")
        }
        .alert("Category Error", isPresented: Binding(
            get: { categoryErrorMessage != nil },
            set: { if !$0 { categoryErrorMessage = nil } }
        )) {
            Button("OK") { categoryErrorMessage = nil }
        } message: {
            Text(categoryErrorMessage ?? "An unknown error occurred.")
        }
        .sheet(isPresented: $showingNewCategory) {
            newCategorySheet
        }
        .sheet(item: $subcategoryParent) { _ in
            newSubcategorySheet
        }
        .sheet(isPresented: $showingAddAccount) {
            ManualAccountSheet { account in
                onAccountCreated(account)
            }
        }
        .sheet(item: $balanceSnapshotAccount) { account in
            BalanceSnapshotSheet(account: account) {}
        }
    }

    @ViewBuilder
    private var adaptiveGridRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) {
                backupSection
                    .frame(maxWidth: .infinity)
                dataSection
                    .frame(maxWidth: .infinity)
            }
            VStack(spacing: 16) {
                backupSection
                dataSection
            }
        }
    }

    private var accountsSection: some View {
        SectionCard(title: "Accounts") {
            VStack(spacing: 0) {
                HStack {
                    Text(accounts.isEmpty ? "Create your first account manually or import a statement." : "Manage account details and manual balance snapshots.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        showingAddAccount = true
                    } label: {
                        Label("Add Account", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                if !accounts.isEmpty {
                    Divider().padding(.leading, 16)
                    VStack(spacing: 0) {
                        ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                            accountEditorRow(for: account)
                            if index < accounts.count - 1 {
                                Divider().padding(.leading, 16)
                            }
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func accountEditorRow(for account: Account) -> some View {
        let txCount = transactionCountsByAccountID[account.id] ?? 0

        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(account.displayName)
                    .font(.callout.weight(.medium))
                Text("\(account.type.displayName) · \(account.currency)")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text("\(txCount) transactions")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .frame(width: 180, alignment: .topLeading)

            VStack(alignment: .leading, spacing: 8) {
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

                Button {
                    balanceSnapshotAccount = account
                } label: {
                    Label("Add Balance Snapshot", systemImage: "chart.line.uptrend.xyaxis")
                        .font(.caption)
                }

                Button(role: .destructive) {
                    accountDeletionTarget = AccountDeletionTarget(
                        id: account.id,
                        displayName: account.displayName,
                        preview: AccountDeletionService.preview(account: account, context: modelContext)
                    )
                } label: {
                    Label("Delete Account", systemImage: "trash")
                        .font(.caption)
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var categoriesSection: some View {
        SectionCard(title: "Categories") {
            VStack(spacing: 0) {
                let parents = categories.filter { $0.parent == nil }
                let kinds: [CategoryKind] = [.expense, .income, .transfer, .investment, .creditCardPayment]
                let grouped = kinds.compactMap { kind -> (CategoryKind, [Category])? in
                    let cats = parents.filter { $0.kind == kind }.sorted { $0.name < $1.name }
                    return cats.isEmpty ? nil : (kind, cats)
                }

                if grouped.isEmpty {
                    Text("No categories yet")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(16)
                } else {
                    ForEach(grouped, id: \.0) { kind, parentsInSection in
                        Text(kind.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                            .padding(.bottom, 4)

                        ForEach(parentsInSection) { parent in
                            categoryParentRow(parent)
                            let subs = categories
                                .filter { $0.parent?.id == parent.id }
                                .sorted { $0.name < $1.name }
                            ForEach(subs) { sub in
                                categorySubcategoryRow(sub, parent: parent)
                            }
                        }
                    }
                }

                Divider()
                    .padding(.leading, 16)

                Button {
                    newCategoryName = ""
                    newCategoryKind = .expense
                    showingNewCategory = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("Add Category")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func categoryParentRow(_ parent: Category) -> some View {
        let activeChildren = categories.filter { $0.parent?.id == parent.id }
        let canDelete = activeChildren.isEmpty

        return HStack {
            Text(parent.name)
                .font(.callout.weight(.medium))
            Spacer()
            Button {
                newSubcategoryName = ""
                subcategoryParent = parent
            } label: {
                Image(systemName: "plus.circle")
                    .font(.caption)
            }
            .buttonStyle(.plain)
            .help("Add subcategory")

            Button(role: .destructive) {
                do {
                    try CategoryManagementActions.deleteParent(parent, context: modelContext)
                } catch {
                    NSLog("Failed to delete parent category: %@", error.localizedDescription)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(canDelete ? .red : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(!canDelete)
            .help(canDelete ? "Delete category" : "Delete subcategories first")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    private func categorySubcategoryRow(_ sub: Category, parent: Category) -> some View {
        HStack {
            Spacer().frame(width: 20)
            Text(sub.name)
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button(role: .destructive) {
                do {
                    try CategoryManagementActions.deleteSubcategory(sub, context: modelContext)
                } catch {
                    NSLog("Failed to delete subcategory: %@", error.localizedDescription)
                }
            } label: {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    private var newCategorySheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Category")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            TextField("Category name", text: $newCategoryName)
                .textFieldStyle(.roundedBorder)
                .focused($focusedField, equals: .newCategoryName)
                .onSubmit(createNewCategoryIfValid)

            VStack(alignment: .leading, spacing: 8) {
                Text("Category Type")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Category Type", selection: $newCategoryKind) {
                    ForEach(categoryKindOrder, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .controlSize(.regular)
                .frame(maxWidth: .infinity)
            }

            HStack {
                Spacer()
                Button("Cancel") { cancelNewCategory() }
                    .keyboardShortcut(.cancelAction)
                Button("Create", action: createNewCategoryIfValid)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .disabled(!canCreateNewCategory)
                Spacer()
            }
        }
        .padding(24)
        .frame(width: 540)
        .onAppear {
            focusedField = .newCategoryName
        }
        .onDisappear {
            if focusedField == .newCategoryName {
                focusedField = nil
            }
        }
    }

    private var newSubcategorySheet: some View {
        VStack(spacing: 16) {
            if let parent = subcategoryParent {
                Text("New Subcategory under \(parent.name)")
                    .font(.headline)

                TextField("Subcategory name", text: $newSubcategoryName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focusedField, equals: .newSubcategoryName)
                    .onSubmit(createSubcategoryIfValid)

                let trimmed = newSubcategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                let isDuplicate = CategoryManagementActions.isDuplicate(
                    name: trimmed, kind: parent.kind, parent: parent, context: modelContext
                )

                HStack {
                    Button("Cancel") { cancelSubcategory() }
                        .keyboardShortcut(.cancelAction)
                    Button("Create", action: createSubcategoryIfValid)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.glassProminent)
                    .disabled(trimmed.isEmpty || isDuplicate)
                }
            }
        }
        .padding(24)
        .frame(width: 380)
        .onAppear {
            focusedField = .newSubcategoryName
        }
        .onDisappear {
            if focusedField == .newSubcategoryName {
                focusedField = nil
            }
        }
    }

    private var categoryKindOrder: [CategoryKind] {
        [.income, .expense, .transfer, .investment, .creditCardPayment]
    }

    private var trimmedNewCategoryName: String {
        newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var canCreateNewCategory: Bool {
        !trimmedNewCategoryName.isEmpty && !CategoryManagementActions.isDuplicate(
            name: trimmedNewCategoryName,
            kind: newCategoryKind,
            parent: nil,
            context: modelContext
        )
    }

    private func createNewCategoryIfValid() {
        guard canCreateNewCategory else { return }
        do {
            _ = try CategoryManagementActions.createParent(
                name: trimmedNewCategoryName,
                kind: newCategoryKind,
                context: modelContext
            )
            cancelNewCategory()
        } catch {
            categoryErrorMessage = error.localizedDescription
            NSLog("Failed to create category: %@", error.localizedDescription)
        }
    }

    private func cancelNewCategory() {
        newCategoryName = ""
        newCategoryKind = .expense
        focusedField = nil
        showingNewCategory = false
    }

    private func createSubcategoryIfValid() {
        guard let parent = subcategoryParent else { return }
        let trimmed = newSubcategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDuplicate = CategoryManagementActions.isDuplicate(
            name: trimmed,
            kind: parent.kind,
            parent: parent,
            context: modelContext
        )
        guard !trimmed.isEmpty, !isDuplicate else { return }

        do {
            _ = try CategoryManagementActions.createSubcategory(
                parent: parent,
                name: trimmed,
                context: modelContext
            )
            cancelSubcategory()
        } catch {
            categoryErrorMessage = error.localizedDescription
            NSLog("Failed to create subcategory: %@", error.localizedDescription)
        }
    }

    private func cancelSubcategory() {
        newSubcategoryName = ""
        focusedField = nil
        subcategoryParent = nil
    }

    private var backupSection: some View {
        SectionCard(title: "Backup & Restore") {
            VStack(alignment: .leading, spacing: 10) {
                if !backupStatus.isEmpty {
                    Text(backupStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 24) {
                    if let lastSnapshot = lastBackupDate {
                        MetricChip(label: "Last snapshot", value: lastSnapshot)
                    } else {
                        Text("No snapshots yet")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    MetricChip(label: "On disk", value: "\(snapshotCount)")
                }

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
            .padding(16)
        }
    }

    private var dataSection: some View {
        SectionCard(title: "Data") {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 24) {
                    MetricChip(label: "Accounts", value: "\(accounts.count)")
                    MetricChip(label: "Transactions", value: "\(transactions.count)")
                    MetricChip(label: "Pending Review", value: "\(pendingImports.count)")
                    MetricChip(label: "Installment Plans", value: "\(installmentPlans.count)")
                }

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Text("Delete All Data")
                }
            }
            .padding(16)
        }
        .alert("Delete All Data?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                deleteAllData()
            }
        } message: {
            Text("This will permanently delete all accounts, transactions, and categories. Default categories will be recreated. This cannot be undone.")
        }
    }

    private var aboutSection: some View {
        SectionCard(title: "About") {
            VStack(alignment: .leading, spacing: 12) {
                if !Self.latestReleaseHighlights.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("What's New")
                            .font(.subheadline.weight(.semibold))
                        ForEach(Self.latestReleaseHighlights, id: \.self) { bullet in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                Text(bullet)
                            }
                            .font(.callout)
                            .foregroundStyle(.secondary)
                        }
                    }

                    Divider()
                }

                HStack {
                    LabeledContent("App", value: "FinanceTracker")
                    Spacer()
                    LabeledContent("Version", value: appVersion)
                }
            }
            .padding(16)
        }
    }

    private static let latestReleaseHighlights: [String] = [
        "Creating categories from Settings is reliable again.",
        "The category name field is focused automatically when the sheet opens.",
        "Category creation now supports keyboard submit and cancel actions.",
        "Production release steps now require verified backup safety gates.",
    ]

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
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowedContentTypes = []
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard url.pathExtension == "ftbackup",
              FileManager.default.fileExists(atPath: url.appendingPathComponent("manifest.json").path) else {
            backupStatus = "Restore failed: choose a .ftbackup bundle"
            return
        }
        isRestoring = true
        Task {
            do {
                let strategy: RestoreStrategy = hasFinancialRows ? .mergeKeepingNewer : .replaceAll
                try await BackupArchive.restore(from: url, into: modelContext, strategy: strategy)
                backupStatus = "Restore complete"
            } catch {
                backupStatus = "Restore failed: \(error.localizedDescription)"
            }
            isRestoring = false
        }
    }

    private var hasFinancialRows: Bool {
        let accountCount = (try? modelContext.fetchCount(FetchDescriptor<Account>())) ?? 0
        let balanceSnapshotCount = (try? modelContext.fetchCount(FetchDescriptor<AccountBalanceSnapshot>())) ?? 0
        let statementCount = (try? modelContext.fetchCount(FetchDescriptor<Statement>())) ?? 0
        let transactionCount = (try? modelContext.fetchCount(FetchDescriptor<Transaction>())) ?? 0
        let installmentPlanCount = (try? modelContext.fetchCount(FetchDescriptor<InstallmentPlan>())) ?? 0
        let pendingImportCount = (try? modelContext.fetchCount(FetchDescriptor<PendingImport>())) ?? 0
        let signRecoveryHintCount = (try? modelContext.fetchCount(FetchDescriptor<SignRecoveryHint>())) ?? 0

        return accountCount > 0
            || balanceSnapshotCount > 0
            || statementCount > 0
            || transactionCount > 0
            || installmentPlanCount > 0
            || pendingImportCount > 0
            || signRecoveryHintCount > 0
    }

    private func revealBackupsFolder() {
        let dir = backupsDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
    }

    private var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    private func deleteAllData() {
        do {
            try AppDataResetService.resetAllData(context: modelContext)
            resetErrorMessage = nil
            onDataReset()
        } catch {
            resetErrorMessage = error.localizedDescription
        }
    }
}

extension Color {
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

private extension CategoryKind {
    var displayName: String {
        switch self {
        case .income:
            "Income"
        case .expense:
            "Expense"
        case .transfer:
            "Transfer"
        case .investment:
            "Investment"
        case .creditCardPayment:
            "Credit Card Payment"
        }
    }
}
