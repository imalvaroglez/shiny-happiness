import SwiftUI
import SwiftData

private struct AccountDeletionTarget {
    let id: UUID
    let displayName: String
    let preview: AccountDeletionService.DeletionPreview
}

private enum CategoryDeletionTarget {
    case parent(Category)
    case subcategory(Category, parent: Category)
}

private enum SettingsFocusField: Hashable {
    case newCategoryName
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
    @State private var selectedCategoryID: UUID?
    @State private var categorySearchText = ""
    @State private var categoryKindFilter: CategoryKindFilter = .all
    @State private var newSubcategoryName = ""
    @State private var subcategoryFocusRequest = 0
    @State private var categoryErrorMessage: String?
    @State private var categoryDeletionTarget: CategoryDeletionTarget?

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
        .alert(categoryDeletionTitle, isPresented: Binding(
            get: { categoryDeletionTarget != nil },
            set: { if !$0 { categoryDeletionTarget = nil } }
        )) {
            Button("Cancel", role: .cancel) {
                categoryDeletionTarget = nil
            }
            Button("Delete", role: .destructive) {
                confirmCategoryDeletion()
            }
        } message: {
            Text(categoryDeletionMessage)
        }
        .sheet(isPresented: $showingNewCategory) {
            newCategorySheet
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

                if account.type == .retirement {
                    Picker("Retirement type", selection: Binding(
                        get: { account.retirementKind ?? .other },
                        set: { account.retirementKind = $0 }
                    )) {
                        ForEach(RetirementKind.allCases, id: \.self) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    .labelsHidden()

                    Text("Retirement accounts are included in Total Net Worth but excluded from regular Cash Flow by default.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if account.type == .retirement || account.type == .investment {
                    Picker("Liquidity", selection: Binding(
                        get: { account.liquidity },
                        set: { account.liquidity = $0 }
                    )) {
                        ForEach(AccountLiquidity.allCases, id: \.self) { value in
                            Text(value.displayName).tag(value)
                        }
                    }
                    .labelsHidden()

                    Toggle("Include in Net Worth", isOn: Binding(
                        get: { account.effectiveIncludeInNetWorth },
                        set: { account.includeInNetWorth = $0 }
                    ))
                    Toggle("Include in Cash Flow", isOn: Binding(
                        get: { account.effectiveIncludeInCashFlow },
                        set: { account.includeInCashFlow = $0 }
                    ))
                    Toggle("Include in Regular Income", isOn: Binding(
                        get: { account.effectiveIncludeInRegularIncome },
                        set: { account.includeInRegularIncome = $0 }
                    ))
                }

                if account.type == .retirement {
                    Toggle("Track for PPR/tax purposes", isOn: Binding(
                        get: { account.taxTrackingEnabled ?? (account.retirementKind == .ppr) },
                        set: { account.taxTrackingEnabled = $0 }
                    ))
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
            CategoryManagementPanel(
                categories: categories,
                selectedCategoryID: $selectedCategoryID,
                searchText: $categorySearchText,
                kindFilter: $categoryKindFilter,
                newSubcategoryName: $newSubcategoryName,
                focusRequest: subcategoryFocusRequest,
                onNewCategory: prepareNewCategory,
                onCreateSubcategory: createSubcategoryIfValid,
                onDeleteParent: requestDeleteParent,
                onDeleteSubcategory: requestDeleteSubcategory
            )
        }
    }

    private func prepareNewCategory() {
        newCategoryName = ""
        newCategoryKind = .expense
        showingNewCategory = true
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
            let category = try CategoryManagementActions.createParent(
                name: trimmedNewCategoryName,
                kind: newCategoryKind,
                context: modelContext
            )
            selectedCategoryID = category.id
            cancelNewCategory()
            requestSubcategoryFocus()
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

    private func createSubcategoryIfValid(parent: Category) {
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
            newSubcategoryName = ""
            requestSubcategoryFocus()
        } catch {
            categoryErrorMessage = error.localizedDescription
            NSLog("Failed to create subcategory: %@", error.localizedDescription)
        }
    }

    private func requestSubcategoryFocus() {
        Task { @MainActor in
            await Task.yield()
            await Task.yield()
            subcategoryFocusRequest += 1
        }
    }

    private func requestDeleteParent(_ parent: Category) {
        let tree = CategoryManagementTree(categories: categories)
        guard tree.subcategories(for: parent).isEmpty else {
            categoryErrorMessage = "Delete subcategories before deleting this parent category."
            return
        }
        categoryDeletionTarget = .parent(parent)
    }

    private func requestDeleteSubcategory(_ subcategory: Category, parent: Category) {
        categoryDeletionTarget = .subcategory(subcategory, parent: parent)
    }

    private var categoryDeletionTitle: String {
        switch categoryDeletionTarget {
        case .parent:
            "Delete Category?"
        case .subcategory:
            "Delete Subcategory?"
        case nil:
            "Delete Category?"
        }
    }

    private var categoryDeletionMessage: String {
        guard let categoryDeletionTarget else { return "" }
        switch categoryDeletionTarget {
        case .parent(let parent):
            let usage = categoryUsageSummary(for: parent)
            return "Delete \"\(parent.name)\"? Existing transactions and rules assigned to this category will become uncategorized.\(usage) This cannot be undone."
        case .subcategory(let subcategory, let parent):
            let usage = categoryUsageSummary(for: subcategory)
            return "Delete \"\(subcategory.name)\"? Existing transactions and rules assigned to it will move to \"\(parent.name)\".\(usage) This cannot be undone."
        }
    }

    private func categoryUsageSummary(for category: Category) -> String {
        let txCount = transactions.filter { $0.category?.id == category.id }.count
        let ruleCount = ((try? modelContext.fetch(FetchDescriptor<CategoryRule>())) ?? [])
            .filter { $0.category?.id == category.id }
            .count
        guard txCount > 0 || ruleCount > 0 else { return "" }
        return " This affects \(txCount) transaction(s) and \(ruleCount) rule(s)."
    }

    private func confirmCategoryDeletion() {
        guard let target = categoryDeletionTarget else { return }
        defer { categoryDeletionTarget = nil }

        do {
            switch target {
            case .parent(let parent):
                try CategoryManagementActions.deleteParent(parent, context: modelContext)
                if selectedCategoryID == parent.id {
                    selectedCategoryID = nil
                }
            case .subcategory(let subcategory, _):
                try CategoryManagementActions.deleteSubcategory(subcategory, context: modelContext)
            }
        } catch {
            categoryErrorMessage = error.localizedDescription
            NSLog("Failed to delete category: %@", error.localizedDescription)
        }
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
        "The Net Worth card now splits out Liquid Net Worth and Retirement Assets at a glance.",
        "The Net Worth breakdown groups accounts into Liabilities, Retirement, Liquid, and Other sections with subtotals.",
        "Manual transactions can be tagged with a treatment (retirement contribution, employer-funded, investment return, fee, valuation adjustment).",
        "Retirement account settings now read more clearly for PPR, AFORE, and employer plans.",
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

private enum CategoryPanelFocus: Hashable {
    case newSubcategoryName
}

private struct CategoryManagementPanel: View {
    let categories: [Category]
    @Binding var selectedCategoryID: UUID?
    @Binding var searchText: String
    @Binding var kindFilter: CategoryKindFilter
    @Binding var newSubcategoryName: String
    let focusRequest: Int
    let onNewCategory: () -> Void
    let onCreateSubcategory: (Category) -> Void
    let onDeleteParent: (Category) -> Void
    let onDeleteSubcategory: (Category, Category) -> Void

    @FocusState private var focusedField: CategoryPanelFocus?

    private var tree: CategoryManagementTree {
        CategoryManagementTree(categories: categories)
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 0) {
                browserPane
                    .frame(width: 340)
                Divider()
                detailPane
                    .frame(minWidth: 520, maxWidth: .infinity, minHeight: 420, alignment: .topLeading)
            }

            VStack(spacing: 0) {
                browserPane
                    .frame(maxWidth: .infinity)
                Divider()
                detailPane
                    .frame(maxWidth: .infinity, minHeight: 360, alignment: .topLeading)
            }
        }
        .onAppear(perform: reconcileSelection)
        .onChange(of: tree.selectionSignature) { _, _ in reconcileSelection() }
        .onChange(of: searchText) { _, _ in reconcileSelection() }
        .onChange(of: kindFilter) { _, _ in reconcileSelection() }
        .onChange(of: selectedCategoryID) { _, _ in
            newSubcategoryName = ""
        }
        .onChange(of: focusRequest) { _, _ in
            focusedField = .newSubcategoryName
        }
    }

    private var browserPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                TextField("Search categories", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Picker("Type", selection: $kindFilter) {
                    ForEach(CategoryKindFilter.allCases, id: \.self) { filter in
                        Text(filter.displayName).tag(filter)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 112)
            }

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Category Families")
                        .font(.callout.weight(.semibold))
                    Text("\(tree.visibleParents(searchText: searchText, kindFilter: kindFilter).count) shown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button(action: onNewCategory) {
                    Label("New Category", systemImage: "plus")
                }
                .buttonStyle(.bordered)
                .help("Create category")
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    let visibleParents = tree.visibleParents(searchText: searchText, kindFilter: kindFilter)

                    if !tree.hasCategories {
                        browserEmptyState(
                            title: "No categories yet",
                            systemImage: "tag",
                            actionTitle: "New Category"
                        )
                    } else if visibleParents.isEmpty {
                        browserEmptyState(
                            title: "No matching categories",
                            systemImage: "magnifyingglass",
                            actionTitle: "Create Category"
                        )
                    } else {
                        ForEach(visibleParents) { parent in
                            CategoryParentBrowserRow(
                                category: parent,
                                subcategoryCount: tree.subcategories(for: parent).count,
                                isSelected: parent.id == selectedCategoryID
                            ) {
                                selectedCategoryID = parent.id
                            }
                        }
                    }
                }
                .padding(.vertical, 2)
            }
            .frame(minHeight: 280)
        }
        .padding(16)
    }

    private func browserEmptyState(title: String, systemImage: String, actionTitle: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.title3)
                .foregroundStyle(.secondary)
            Text(title)
                .font(.callout.weight(.medium))
            Button(actionTitle, action: onNewCategory)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .foregroundStyle(.secondary)
    }

    @ViewBuilder
    private var detailPane: some View {
        let visibleSelectionID = tree.resolvedSelectionID(
            current: selectedCategoryID,
            searchText: searchText,
            kindFilter: kindFilter
        )

        if let parent = tree.parent(id: visibleSelectionID) {
            categoryDetail(parent)
        } else {
            VStack(spacing: 10) {
                Image(systemName: tree.hasCategories ? "sidebar.left" : "tag")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(tree.hasCategories ? "Select a category" : "Create a category to get started")
                    .font(.headline)
                    .foregroundStyle(.secondary)
                Button("New Category", action: onNewCategory)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, minHeight: 360)
            .padding(24)
        }
    }

    private func categoryDetail(_ parent: Category) -> some View {
        let subcategories = tree.subcategories(for: parent)
        let canDeleteParent = subcategories.isEmpty
        let trimmedSubcategoryName = newSubcategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        let isDuplicate = tree.isDuplicateSubcategoryName(trimmedSubcategoryName, parent: parent)
        let canCreateSubcategory = !trimmedSubcategoryName.isEmpty && !isDuplicate

        return VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .center, spacing: 12) {
                Circle()
                    .fill(CategoryPalette.color(for: parent.name))
                    .frame(width: 13, height: 13)

                VStack(alignment: .leading, spacing: 3) {
                    Text(parent.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        Text(parent.kind.displayName)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        Text("\(subcategories.count) subcategories")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                Button(role: .destructive) {
                    onDeleteParent(parent)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(canDeleteParent ? .red : .secondary)
                .disabled(!canDeleteParent)
                .help(canDeleteParent ? "Delete category" : "Delete subcategories first")
            }

            Divider()

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Subcategories")
                        .font(.callout.weight(.semibold))
                    Spacer()
                    Text("\(subcategories.count)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                if subcategories.isEmpty {
                    HStack(spacing: 10) {
                        Image(systemName: "tray")
                            .foregroundStyle(.secondary)
                        Text("No subcategories")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 18)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(subcategories) { subcategory in
                            subcategoryRow(subcategory, parent: parent)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    TextField("New subcategory", text: $newSubcategoryName)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .newSubcategoryName)
                        .onSubmit {
                            if canCreateSubcategory {
                                onCreateSubcategory(parent)
                            }
                        }

                    Button {
                        onCreateSubcategory(parent)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .font(.title3)
                    .disabled(!canCreateSubcategory)
                    .help("Add subcategory")
                }

                if isDuplicate {
                    Text("A subcategory with this name already exists.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(20)
    }

    private func subcategoryRow(_ subcategory: Category, parent: Category) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(CategoryPalette.color(for: subcategory.name))
                .frame(width: 5, height: 22)

            Text(subcategory.name)
                .font(.body)
                .lineLimit(1)

            Spacer()

            Button(role: .destructive) {
                onDeleteSubcategory(subcategory, parent)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.red)
            .help("Delete subcategory")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private func reconcileSelection() {
        let resolved = tree.resolvedSelectionID(
            current: selectedCategoryID,
            searchText: searchText,
            kindFilter: kindFilter
        )
        if selectedCategoryID != resolved {
            selectedCategoryID = resolved
        }
    }
}

private struct CategoryParentBrowserRow: View {
    let category: Category
    let subcategoryCount: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Circle()
                    .fill(CategoryPalette.color(for: category.name))
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 3) {
                    Text(category.name)
                        .font(.body.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    Text(category.kind.displayName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Text("\(subcategoryCount)")
                    .font(.caption.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 24)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.quaternary, in: Capsule())
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? Color.accentColor.opacity(0.18) : Color.clear)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(isSelected ? Color.accentColor.opacity(0.35) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("\(category.name), \(subcategoryCount) subcategories")
    }
}

#if DEBUG
private struct CategoryManagementPanelPreviewHost: View {
    let categories: [Category]
    @State private var selectedCategoryID: UUID?
    @State private var searchText: String
    @State private var kindFilter: CategoryKindFilter
    @State private var newSubcategoryName = ""

    init(
        categories: [Category],
        selectedCategoryID: UUID? = nil,
        searchText: String = "",
        kindFilter: CategoryKindFilter = .all
    ) {
        self.categories = categories
        _selectedCategoryID = State(initialValue: selectedCategoryID)
        _searchText = State(initialValue: searchText)
        _kindFilter = State(initialValue: kindFilter)
    }

    var body: some View {
        SectionCard(title: "Categories") {
            CategoryManagementPanel(
                categories: categories,
                selectedCategoryID: $selectedCategoryID,
                searchText: $searchText,
                kindFilter: $kindFilter,
                newSubcategoryName: $newSubcategoryName,
                focusRequest: 0,
                onNewCategory: {},
                onCreateSubcategory: { _ in },
                onDeleteParent: { _ in },
                onDeleteSubcategory: { _, _ in }
            )
        }
        .frame(width: 980)
        .padding()
    }
}

private enum CategoryManagementPreviewData {
    static var dense: [Category] {
        let food = Category(name: "Food & Drink", kind: .expense)
        let restaurants = Category(name: "Restaurants", parent: food, kind: .expense)
        let groceries = Category(name: "Groceries", parent: food, kind: .expense)
        let coffee = Category(name: "Coffee", parent: food, kind: .expense)

        let transport = Category(name: "Transport", kind: .expense)
        let rideshare = Category(name: "Rideshare", parent: transport, kind: .expense)
        let gas = Category(name: "Gas", parent: transport, kind: .expense)

        let salary = Category(name: "Salary", kind: .income)
        let investments = Category(name: "Investment", kind: .investment)
        let payments = Category(name: "Credit Card Payments", kind: .creditCardPayment)

        return [
            food, restaurants, groceries, coffee,
            transport, rideshare, gas,
            salary, investments, payments,
        ]
    }
}

#Preview("Category Manager Dense") {
    CategoryManagementPanelPreviewHost(categories: CategoryManagementPreviewData.dense)
}

#Preview("Category Manager Empty") {
    CategoryManagementPanelPreviewHost(categories: [])
}

#Preview("Category Manager No Results") {
    CategoryManagementPanelPreviewHost(
        categories: CategoryManagementPreviewData.dense,
        searchText: "medical"
    )
}

#Preview("Category Manager Selected") {
    let categories = CategoryManagementPreviewData.dense
    CategoryManagementPanelPreviewHost(
        categories: categories,
        selectedCategoryID: categories.first { $0.name == "Food & Drink" }?.id
    )
}

#Preview("Category Manager Delete Disabled") {
    let categories = CategoryManagementPreviewData.dense
    CategoryManagementPanelPreviewHost(
        categories: categories,
        selectedCategoryID: categories.first { $0.name == "Transport" }?.id
    )
}
#endif

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
