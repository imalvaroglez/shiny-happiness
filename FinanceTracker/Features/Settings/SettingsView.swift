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

private enum SettingsPane: String, Hashable {
    case accounts
    case categories
    case promotions
    case backupData
    case integrations
    case about

    var title: String {
        switch self {
        case .accounts:
            "Accounts"
        case .categories:
            "Categories"
        case .promotions:
            "Promotions"
        case .backupData:
            "Backup & Data"
        case .integrations:
            "Integrations"
        case .about:
            "About"
        }
    }

    var systemImage: String {
        switch self {
        case .accounts:
            "creditcard"
        case .categories:
            "tag"
        case .promotions:
            "tag.circle"
        case .backupData:
            "externaldrive"
        case .integrations:
            "key"
        case .about:
            "info.circle"
        }
    }
}

struct SettingsView: View {
    var onAccountDeleted: (UUID) -> Void = { _ in }
    var onAccountArchived: (UUID) -> Void = { _ in }
    var onAccountCreated: (Account) -> Void = { _ in }
    var onDataReset: () -> Void = {}
    var onSpendRequirementChanged: () -> Void = {}

    @Environment(\.modelContext) private var modelContext
    @Query private var accounts: [Account]
    @Query(filter: #Predicate<Category> { $0.deletedAt == nil }) private var categories: [Category]

    @State private var showDeleteConfirmation = false
    @State private var isExporting = false
    @State private var isRestoring = false
    @State private var backupStatus = ""
    @State private var latestBackupSummary: BackupSummary?
    @State private var didLoadLatestBackup = false
    @State private var dataHealthRefreshToken = 0
    @State private var pendingRestore: BackupSummary?
    @State private var pendingRestoreDirectory: URL?
    @State private var showingRestoreConfirmation = false
    @State private var resetErrorMessage: String?
    @State private var tokenDraft = ""
    @State private var tokenStatusMessage: String?

    @State private var accountDeletionTarget: AccountDeletionTarget?
    @State private var accountActionError: String?
    @State private var showingAddAccount = false
    @State private var balanceSnapshotAccount: Account?
    @State private var positionsAccount: Account?
    @State private var accountSettingsRefreshToken = 0

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
    @State private var categoryRecoveryBackupURL: URL?
    @State private var categoryRecoveryPreview: CategoryRecoveryService.Preview?
    @State private var categoryRecoveryStatus = ""
    @State private var categoryEditError: String?
    @State private var categoryRecoveryIsBusy = false
    @State private var categoryRecoveryAccessActive = false
    @State private var showingCategoryRecoveryConfirmation = false
    @State private var includeAmbiguousCategoryDeletions = false

    @FocusState private var focusedField: SettingsFocusField?
    @SceneStorage("SettingsView.selectedPane") private var selectedPaneRawValue = SettingsPane.backupData.rawValue

    private func fetchAccount(id: UUID) -> Account? {
        let descriptor = FetchDescriptor<Account>(
            predicate: #Predicate<Account> { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private var selectedPane: Binding<SettingsPane> {
        Binding {
            SettingsPane(rawValue: selectedPaneRawValue) ?? .accounts
        } set: { pane in
            selectedPaneRawValue = pane.rawValue
        }
    }

    var body: some View {
        let currentPane = SettingsPane(rawValue: selectedPaneRawValue) ?? .accounts

        TabView(selection: selectedPane) {
            settingsPane(.backupData, isSelected: currentPane == .backupData) {
                backupSection
                dataSection
                resetSection
            }

            settingsPane(.accounts, isSelected: currentPane == .accounts) {
                accountsSection
            }

            settingsPane(.categories, isSelected: currentPane == .categories) {
                categoriesSection
            }

            settingsPane(.promotions, isSelected: currentPane == .promotions) {
                promotionsSection
            }

            settingsPane(.integrations, isSelected: currentPane == .integrations) {
                dataBursatilSection
            }

            settingsPane(.about, isSelected: currentPane == .about) {
                aboutSection
            }
        }
.navigationTitle("Settings")
        .task(id: currentPane) {
            guard currentPane == .backupData, !didLoadLatestBackup else { return }
            await Task.yield()
            let directory = backupsDirectory
            let summary = await Task.detached(priority: .utility) {
                BackupArchive.latestBackup(in: directory)
            }.value
            guard !Task.isCancelled else { return }
            latestBackupSummary = summary
            didLoadLatestBackup = true
        }
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
                        let spendURL = try SpendRequirementStore.defaultURL()
                        let oldSpendSettings = try SpendRequirementStore.read(fileURL: spendURL)
                        let hadSpendSettings = FileManager.default.fileExists(atPath: spendURL.path)
                        try SpendRequirementStore.disable(accountID: target.id, at: spendURL)
                        do {
                            try AccountDeletionService.delete(account: account, context: modelContext)
                        } catch {
                            if hadSpendSettings {
                                try? SpendRequirementStore.replace(with: oldSpendSettings, at: spendURL)
                            } else {
                                try? SpendRequirementStore.reset(fileURL: spendURL)
                            }
                            throw error
                        }
                        onAccountDeleted(target.id)
                    } catch {
                        NSLog("Failed to delete account: %@", error.localizedDescription)
                    }
                }
                accountDeletionTarget = nil
            }
        } message: {
            if let target = accountDeletionTarget {
                Text("¿Eliminar permanentemente «\(target.displayName)»? Se quitarán \(target.preview.statementCount) estados de cuenta, \(target.preview.transactionCount) movimientos, \(target.preview.balanceSnapshotCount) registros de saldo, \(target.preview.stockPositionCount) posiciones, \(target.preview.pendingImportCount) importaciones pendientes y \(target.preview.installmentPlanCount) planes de mensualidades. No se puede deshacer.")
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
        .alert("Account Error", isPresented: Binding(
            get: { accountActionError != nil },
            set: { if !$0 { accountActionError = nil } }
        )) {
            Button("OK") { accountActionError = nil }
        } message: {
            Text(accountActionError ?? "The account change could not be saved.")
        }
        .alert("Restore backup?", isPresented: $showingRestoreConfirmation) {
            Button("Cancel", role: .cancel) {
                pendingRestore = nil
                pendingRestoreDirectory = nil
            }
            Button("Restore", role: .destructive) {
                performPendingRestore()
            }
        } message: {
            if let pendingRestore {
                let strategy = hasFinancialRows ? "combinarlo con tus datos actuales" : "reemplazar el almacenamiento vacío"
                Text("¿Cargar el respaldo \(pendingRestore.url.path), creado el \(pendingRestore.createdAt.formattedMX(date: .abbreviated, time: .shortened)), y \(strategy)?")
            } else {
                Text("Choose a valid FinanceTracker backup.")
            }
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
                accountSettingsRefreshToken += 1
                onAccountCreated(account)
            }
        }
        .sheet(item: $balanceSnapshotAccount) { account in
            BalanceSnapshotSheet(account: account) {
                accountSettingsRefreshToken += 1
            }
        }
        .sheet(item: $positionsAccount) { account in
            PositionsEditSheet(account: account, context: modelContext) {
                accountSettingsRefreshToken += 1
            }
        }
    }

    @ViewBuilder
    private func settingsPane<Content: View>(
        _ pane: SettingsPane,
        isSelected: Bool,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        ScrollView {
            if isSelected {
                LazyVStack(spacing: 16) {
                    content()
                }
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
                .padding()
            }
        }
        .tabItem {
            Label(pane.title, systemImage: pane.systemImage)
        }
        .tag(pane)
    }

    private var accountsSection: some View {
        VStack(spacing: 16) {
            SectionCard(title: "Accounts") {
                let activeAccounts = AccountArchiveService.activeAccounts(from: accounts)
                VStack(spacing: 0) {
                    HStack {
                        Text(activeAccounts.isEmpty
                             ? "No active accounts. Add an account or restore one from the archived list."
                             : "Manage account details and manual balance snapshots.")
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

                    if !activeAccounts.isEmpty {
                        Divider().padding(.leading, 16)
                        AccountRowsView(
                            accounts: activeAccounts,
                            refreshToken: accountSettingsRefreshToken,
                            onSpendRequirementChanged: onSpendRequirementChanged,
                            onEditPositions: { positionsAccount = $0 },
                            onAddBalanceSnapshot: { balanceSnapshotAccount = $0 },
                            onArchive: archiveAccount,
                            onDelete: requestAccountDeletion
                        )
                    }
                }
            }

            let archivedAccounts = AccountArchiveService.archivedAccounts(from: accounts)
            if !archivedAccounts.isEmpty {
                SectionCard(title: "Archived Accounts") {
                    ArchivedAccountRowsView(
                        accounts: archivedAccounts,
                        onRestore: restoreAccount,
                        onDelete: requestAccountDeletion
                    )
                }
            }
        }
    }

    private func archiveAccount(_ account: Account) {
        do {
            try AccountArchiveService.archive(account: account, context: modelContext)
            accountActionError = nil
            onAccountArchived(account.id)
        } catch {
            accountActionError = "Could not archive \(account.displayName): \(error.localizedDescription)"
        }
    }

    private func restoreAccount(_ account: Account) {
        do {
            try AccountArchiveService.restore(account: account, context: modelContext)
            accountActionError = nil
        } catch {
            accountActionError = "Could not restore \(account.displayName): \(error.localizedDescription)"
        }
    }

    private func requestAccountDeletion(_ account: Account) {
        accountDeletionTarget = AccountDeletionTarget(
            id: account.id,
            displayName: account.displayName,
            preview: AccountDeletionService.preview(account: account, context: modelContext)
        )
    }

    private var promotionsSection: some View {
        PromotionSettingsSection()
    }

    private var categoriesSection: some View {
        VStack(spacing: 16) {
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
                    onDeleteSubcategory: requestDeleteSubcategory,
                    onRename: { category, newName in
                        do {
                            try CategoryManagementActions.rename(category, to: newName, context: modelContext)
                            categoryEditError = nil
                        } catch {
                            categoryEditError = "No se pudo renombrar: \(error.localizedDescription)"
                        }
                    },
                    onTintChange: { category, color in
                        do {
                            if let color {
                                try CategoryCustomizationStore.setTint(categoryID: category.id,
                                                                        hex: color.hexString)
                            } else {
                                try CategoryCustomizationStore.clearTint(categoryID: category.id)
                            }
                            categoryEditError = nil
                        } catch {
                            categoryEditError = "No se pudo guardar el color: \(error.localizedDescription)"
                        }
                    }
                )
                if let categoryEditError {
                    Text(categoryEditError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            SectionCard(title: "Recover categories") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Restore the category tree from an earlier verified backup and reconnect transactions that point to duplicate categories.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let preview = categoryRecoveryPreview {
                        Text("Respaldo del \(preview.backupDate.formattedMX(date: .abbreviated, time: .shortened)): se recuperarán \(preview.categoriesToRestore) categorías, se recrearán \(preview.missingCategories), se unirán \(preview.duplicateCategoriesToMerge) duplicados y se volverán a vincular \(preview.transactionsToRelink) movimientos.")
                            .font(.callout)
                        if !preview.ambiguousDeletedCategories.isEmpty {
                            Text("Estas categorías del respaldo están eliminadas y no tienen movimientos, reglas ni duplicados activos que indiquen que deban recuperarse: \(preview.ambiguousDeletedCategories.joined(separator: ", ")).")
                                .font(.caption).foregroundStyle(.orange)
                            Toggle("Reactivar también estas categorías", isOn: $includeAmbiguousCategoryDeletions)
                        }
                        HStack {
                            Button("Choose another backup…", action: chooseCategoryRecoveryBackup)
                            Button("Apply recovery", role: .destructive) {
                                showingCategoryRecoveryConfirmation = true
                            }
                            .disabled(categoryRecoveryIsBusy)
                        }
                    } else {
                        Button("Choose an earlier backup…", action: chooseCategoryRecoveryBackup)
                            .disabled(categoryRecoveryIsBusy)
                    }
                    if categoryRecoveryIsBusy { ProgressView() }
                    if !categoryRecoveryStatus.isEmpty {
                        Text(categoryRecoveryStatus).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(16)
            }
        }
        .confirmationDialog("Apply category recovery?", isPresented: $showingCategoryRecoveryConfirmation) {
            Button("Create backup and recover", role: .destructive, action: applyCategoryRecovery)
            Button("Cancel", role: .cancel) { }
        } message: {
            if let preview = categoryRecoveryPreview {
                Text("Primero se creará un respaldo de seguridad. Después se recuperarán o recrearán \(preview.categoriesToRestore + preview.missingCategories + (includeAmbiguousCategoryDeletions ? preview.ambiguousDeletedCategories.count : 0)) categorías y se volverán a vincular \(preview.transactionsToRelink) movimientos.")
            }
        }
    }

    private func chooseCategoryRecoveryBackup() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowedContentTypes = []
        panel.directoryURL = backupsDirectory
        guard panel.runModal() == .OK, let url = panel.url else {
            categoryRecoveryStatus = "Selecciona un paquete .ftbackup válido."
            return
        }
        endCategoryRecoveryAccess()
        let accessActive = url.startAccessingSecurityScopedResource()
        guard let summary = BackupArchive.summary(at: url) else {
            if accessActive { url.stopAccessingSecurityScopedResource() }
            categoryRecoveryStatus = "Selecciona un paquete .ftbackup válido."
            return
        }
        let backupURL = summary.url
        categoryRecoveryAccessActive = accessActive
        categoryRecoveryBackupURL = backupURL
        includeAmbiguousCategoryDeletions = false
        do {
            categoryRecoveryPreview = try CategoryRecoveryService.preview(backupURL: backupURL, context: modelContext)
            categoryRecoveryStatus = ""
        } catch {
            endCategoryRecoveryAccess()
            categoryRecoveryBackupURL = nil
            categoryRecoveryPreview = nil
            categoryRecoveryStatus = "No se pudo revisar el respaldo: \(error.localizedDescription)"
        }
    }

    private func endCategoryRecoveryAccess() {
        if categoryRecoveryAccessActive, let url = categoryRecoveryBackupURL {
            url.stopAccessingSecurityScopedResource()
        }
        categoryRecoveryAccessActive = false
    }

    private func applyCategoryRecovery() {
        guard let backupURL = categoryRecoveryBackupURL else { return }
        categoryRecoveryIsBusy = true
        Task {
            var partialSafetyCopy: URL?
            do {
                try FileManager.default.createDirectory(at: backupsDirectory, withIntermediateDirectories: true)
                let stamp = BackupArchive.filenameTimestamp()
                let safetyCopy = backupsDirectory.appendingPathComponent("FinanceTracker-before-category-recovery-\(stamp)-\(UUID().uuidString.prefix(8)).ftbackup")
                partialSafetyCopy = safetyCopy
                try await BackupArchive.export(to: safetyCopy, from: modelContext)
                guard BackupArchive.summary(at: safetyCopy) != nil else {
                    throw NSError(domain: "CategoryRecovery", code: 1,
                                  userInfo: [NSLocalizedDescriptionKey: "El respaldo de seguridad no pasó la verificación de integridad."])
                }
                partialSafetyCopy = nil
                let result = try CategoryRecoveryService.recover(backupURL: backupURL, context: modelContext,
                    includeAmbiguousDeletions: includeAmbiguousCategoryDeletions)
                categoryRecoveryStatus = "Recuperación lista: \(result.categoriesRestored) categorías reactivadas, \(result.categoriesAdded) recreadas, \(result.duplicateCategoriesMerged) duplicados unidos y \(result.transactionsRelinked) movimientos revinculados. Respaldo previo: \(safetyCopy.lastPathComponent)."
                dataHealthRefreshToken += 1
                categoryRecoveryPreview = nil
                endCategoryRecoveryAccess()
                categoryRecoveryBackupURL = nil
            } catch {
                if let partialSafetyCopy { try? FileManager.default.removeItem(at: partialSafetyCopy) }
                categoryRecoveryStatus = "Falló la recuperación: \(error.localizedDescription)"
            }
            categoryRecoveryIsBusy = false
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
            return "¿Eliminar «\(parent.localizedName)»? Los movimientos y reglas asignados quedarán sin categoría.\(usage) Esta acción no se puede deshacer."
        case .subcategory(let subcategory, let parent):
            let usage = categoryUsageSummary(for: subcategory)
            return "¿Eliminar «\(subcategory.localizedName)»? Los movimientos y reglas asignados pasarán a «\(parent.localizedName)».\(usage) Esta acción no se puede deshacer."
        }
    }

    private func categoryUsageSummary(for category: Category) -> String {
        let categoryID = category.id
        let txCount = (try? modelContext.fetchCount(FetchDescriptor<Transaction>(
            predicate: #Predicate<Transaction> { $0.category?.id == categoryID }
        ))) ?? 0
        let ruleCount = (try? modelContext.fetchCount(FetchDescriptor<CategoryRule>(
            predicate: #Predicate<CategoryRule> { $0.category?.id == categoryID }
        ))) ?? 0
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
            let presentation = backupPresentation

            VStack(alignment: .leading, spacing: 16) {
                if !backupStatus.isEmpty {
                    Text(backupStatus)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                VStack(alignment: .leading, spacing: 8) {
                    Label("Automatic backups", systemImage: "checkmark.shield")
                        .font(.subheadline.weight(.semibold))

                    Text("FinanceTracker creates automatic snapshots when the app runs, at most once per day, and keeps recent daily, weekly, and monthly copies.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    if !didLoadLatestBackup {
                        Text("Checking for automatic backups…")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    } else if presentation.hasVerifiedSnapshot,
                       let createdAt = presentation.createdAt,
                       let latestPath = presentation.latestPath {
                        LabeledContent("Last verified snapshot") {
                            Text(createdAt.formattedMX(date: .abbreviated, time: .shortened))
                                .font(.callout.weight(.semibold).monospacedDigit())
                        }

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Backup bundle")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.secondary)
                            Text(latestPath)
                                .font(.caption2.monospaced())
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    } else {
                        Text("No verified automatic backup found yet.")
                            .font(.callout.weight(.medium))
                            .foregroundStyle(.secondary)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Managed folder (FinanceTracker)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.secondary)
                        Text(presentation.managedDirectoryPath)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    HStack(spacing: 10) {
                        Button("Copy path") {
                            ClipboardWriter.copyText(presentation.latestPath ?? presentation.managedDirectoryPath)
                            backupStatus = "Path copied"
                        }
                        Button("Reveal backup folder") { revealBackupsFolder() }
                    }
                }

                HStack(spacing: 12) {
                    Button("Save a copy…") { exportBackup() }
                        .disabled(isExporting)
                    Button("Restore from file…") { restoreBackup() }
                        .disabled(isRestoring)
                    Button("Load latest backup") { restoreLatestBackup() }
                        .disabled(isRestoring)
                }

                Text("Backups include items in Recently Deleted. Save a copy is optional and can be used for an external safety copy.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(16)
        }
    }

    private var dataBursatilSection: some View {
        SectionCard(title: "DataBursatil (BMV prices)") {
            VStack(alignment: .leading, spacing: 10) {
                SecureField("API token", text: $tokenDraft)
                    .textFieldStyle(.roundedBorder)
                Text("Saved tokens are hidden. Paste a token to replace it, or use Clear to remove it.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Button("Save") { saveDataBursatilToken() }
                    Button("Clear", role: .destructive) {
                        KeychainTokenStore.clear()
                        tokenDraft = ""
                        tokenStatusMessage = "Token cleared."
                    }
                    Link("Get a token", destination: URL(string: "https://databursatil.com/nuevo_usuario.php")!)
                }

                if let tokenStatusMessage {
                    Text(tokenStatusMessage)
                        .font(.caption)
                        .foregroundStyle(tokenStatusMessage.contains("failed") ? Color.red : Color.secondary)
                }
            }
            .padding(16)
        }
    }

    private var dataSection: some View {
        DataHealthSection(
            accounts: accounts,
            activeCategoryCount: categories.count,
            refreshToken: dataHealthRefreshToken
        )
    }

    private var resetSection: some View {
        SectionCard(title: "Reset data") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Delete all financial data")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.red)
                Text("Export a fresh backup before deleting financial data.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)

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

    private func saveDataBursatilToken() {
        let trimmed = tokenDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            tokenStatusMessage = "Paste a token to save, or use Clear to remove the saved token."
            return
        }

        do {
            try KeychainTokenStore.setToken(trimmed)
            tokenDraft = trimmed
            tokenStatusMessage = "Saved to Keychain."
        } catch {
            tokenStatusMessage = "Save failed: \(error.localizedDescription)"
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
        "Consulta la cuenta de cada integrante: un desglose que suma a mano hasta el saldo y sugiere el pago neto.",
        "Registra pagos sin bloqueos: una referencia dañada nunca detiene un cobro nuevo ni cuenta como dinero.",
        "Recupera cobros a medio vincular aunque cierres la app: la recuperación viaja con el movimiento.",
        "Clasifica gastos suyos y compartidos por integrante, con Sankey al 80 % y colores de alto contraste.",
        "Cuentas archivadas o cerradas fuera de la captura, con validación fresca al guardar en todas las rutas.",
    ]

    private var backupsDirectory: URL {
        BackupFolderStore.defaultDirectory
    }

    private var backupPresentation: BackupStatusPresentation {
        BackupStatusPresentation(latestBackup: latestBackupSummary, managedDirectory: backupsDirectory)
    }

    private func exportBackup() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = []
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "FinanceTracker-\(BackupArchive.filenameTimestamp()).ftbackup"
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
        // A .ftbackup bundle is a directory, so the picker must allow choosing
        // directories. Accept either the bundle itself or a folder that contains
        // one or more bundles (the folder is resolved to its latest backup).
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowedContentTypes = []
        panel.directoryURL = backupsDirectory
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let containingDirectory: URL
        if let direct = BackupArchive.summary(at: url) {
            // The user selected a .ftbackup bundle directly.
            containingDirectory = direct.url.deletingLastPathComponent()
            pendingRestore = direct
        } else if let latest = BackupArchive.latestBackup(in: url) {
            // The user selected a folder that contains one or more bundles.
            containingDirectory = url
            pendingRestore = latest
        } else {
            backupStatus = "Restore failed: choose a .ftbackup bundle or a folder that contains one."
            return
        }
        do {
            try BackupFolderStore.remember(directory: containingDirectory)
        } catch {
            backupStatus = "Backup selected; its folder could not be remembered for Load latest."
        }
        pendingRestoreDirectory = containingDirectory
        showingRestoreConfirmation = true
    }

    private func restoreLatestBackup() {
        let access = BackupFolderStore.accessForLatest(defaultDirectory: backupsDirectory)
        defer { access.stopAccessing() }
        guard let summary = BackupArchive.latestBackup(in: access.url) else {
            backupStatus = "No valid backup found in the saved folder. Use Restore from file… to choose one."
            return
        }
        pendingRestoreDirectory = access.url
        pendingRestore = summary
        showingRestoreConfirmation = true
    }

    private func performPendingRestore() {
        guard let summary = pendingRestore else { return }
        let directory = pendingRestoreDirectory ?? summary.url.deletingLastPathComponent()
        pendingRestore = nil
        pendingRestoreDirectory = nil
        isRestoring = true
        Task {
            let access = BackupFolderStore.access(directory: directory)
            defer { access.stopAccessing() }
            do {
                let strategy: RestoreStrategy = hasFinancialRows ? .mergeKeepingNewer : .replaceAll
                let warnings = try await BackupArchive.restore(from: summary.url, into: modelContext, strategy: strategy)
                backupStatus = "Respaldo restaurado: \(summary.createdAt.formattedMX(date: .abbreviated, time: .shortened))"
                if !warnings.isEmpty { backupStatus += " · " + warnings.joined(separator: " · ") }
                dataHealthRefreshToken += 1
                onSpendRequirementChanged()
            } catch {
                backupStatus = "No se pudo restaurar el respaldo: \(error.localizedDescription)"
            }
            isRestoring = false
        }
    }

    private var hasFinancialRows: Bool {
        let counts: [Int?] = [
            try? modelContext.fetchCount(FetchDescriptor<Account>()),
            try? modelContext.fetchCount(FetchDescriptor<AccountBalanceSnapshot>()),
            try? modelContext.fetchCount(FetchDescriptor<Statement>()),
            try? modelContext.fetchCount(FetchDescriptor<Transaction>()),
            try? modelContext.fetchCount(FetchDescriptor<Category>()),
            try? modelContext.fetchCount(FetchDescriptor<CategoryRule>()),
            try? modelContext.fetchCount(FetchDescriptor<InstallmentPlan>()),
            try? modelContext.fetchCount(FetchDescriptor<PendingImport>()),
            try? modelContext.fetchCount(FetchDescriptor<SignRecoveryHint>()),
            try? modelContext.fetchCount(FetchDescriptor<StockPosition>()),
            try? modelContext.fetchCount(FetchDescriptor<HouseholdPartnerIncomeEstimate>()),
            try? modelContext.fetchCount(FetchDescriptor<SettlementDueDateOverride>()),
        ]

        // An unreadable count is treated as existing data so a detection failure
        // can never select the destructive replaceAll strategy.
        if counts.contains(where: { $0 == nil }) { return true }
        return counts.compactMap { $0 }.contains(where: { $0 > 0 })
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
            dataHealthRefreshToken += 1
            onDataReset()
        } catch {
            resetErrorMessage = error.localizedDescription
        }
    }
}

struct SettingsAccountState: Equatable {
    let transactionCount: Int
    let canAddPositions: Bool
}

@MainActor
enum SettingsAccountStateLoader {
    static func load(accounts: [Account], context: ModelContext) -> [UUID: SettingsAccountState] {
        var states: [UUID: SettingsAccountState] = [:]
        for account in accounts {
            let accountID = account.id
            let transactionCount = (try? context.fetchCount(FetchDescriptor<Transaction>(
                predicate: #Predicate<Transaction> { $0.account?.id == accountID }
            ))) ?? 0
            states[accountID] = SettingsAccountState(
                transactionCount: transactionCount,
                canAddPositions: account.type == .investment
                    && PortfolioService.canAddPositions(account: account, context: context)
            )
        }
        return states
    }
}

private struct AccountRowsView: View {
    @Environment(\.modelContext) private var modelContext

    let accounts: [Account]
    let refreshToken: Int
    let onSpendRequirementChanged: () -> Void
    let onEditPositions: (Account) -> Void
    let onAddBalanceSnapshot: (Account) -> Void
    let onArchive: (Account) -> Void
    let onDelete: (Account) -> Void

    @State private var accountStates: [UUID: SettingsAccountState] = [:]
    @State private var isLoading = true

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                AccountEditorRow(
                    accounts: accounts,
                    account: account,
                    state: accountStates[account.id],
                    isLoading: isLoading,
                    onSpendRequirementChanged: onSpendRequirementChanged,
                    onEditPositions: { onEditPositions(account) },
                    onAddBalanceSnapshot: { onAddBalanceSnapshot(account) },
                    onArchive: { onArchive(account) },
                    onDelete: { onDelete(account) }
                )
                if index < accounts.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
        }
        .task(id: refreshRevision) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            accountStates = SettingsAccountStateLoader.load(accounts: accounts, context: modelContext)
            isLoading = false
        }
    }

    private var refreshRevision: Int {
        var hasher = Hasher()
        hasher.combine(refreshToken)
        for account in accounts {
            hasher.combine(account.id)
            hasher.combine(account.type.rawValue)
        }
        return hasher.finalize()
    }
}

private struct ArchivedAccountRowsView: View {
    let accounts: [Account]
    let onRestore: (Account) -> Void
    let onDelete: (Account) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(accounts.enumerated()), id: \.element.id) { index, account in
                HStack(spacing: 16) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(account.displayName)
                            .font(.callout.weight(.medium))
                        Text("\(account.type.displayName) · \(account.currency) · \(String(localized: "Archived"))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    Button {
                        onRestore(account)
                    } label: {
                        Label("Restore", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)

                    Button(role: .destructive) {
                        onDelete(account)
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                if index < accounts.count - 1 {
                    Divider().padding(.leading, 16)
                }
            }
        }
    }
}

private struct AccountEditorRow: View {
    @Environment(\.modelContext) private var modelContext
    let accounts: [Account]
    let account: Account
    let state: SettingsAccountState?
    let isLoading: Bool
    let onSpendRequirementChanged: () -> Void
    let onEditPositions: () -> Void
    let onAddBalanceSnapshot: () -> Void
    let onArchive: () -> Void
    let onDelete: () -> Void

    @State private var showingSpendRequirementEditor = false
    @State private var editingDraft: Account?
    @State private var savedSnapshot: Account?
    @State private var editRevision: Date?
    @State private var editError: String?
    private var displayedAccount: Account { savedSnapshot ?? account }

    var body: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 4) {
                Text(displayedAccount.displayName).font(.callout.weight(.medium))
                Text("\(displayedAccount.type.displayName) · \(displayedAccount.currency)").font(.caption2).foregroundStyle(.secondary)
                if let state { Text("\(state.transactionCount) movimientos").font(.caption2).foregroundStyle(.secondary) }
                else if isLoading { ProgressView("Loading account summary…").controlSize(.small).font(.caption2) }
            }.frame(width: 180, alignment: .topLeading)
            VStack(alignment: .leading, spacing: 8) {
                if let draft = editingDraft {
                    TextField("Nickname", text: Binding(get: { draft.nickname }, set: { draft.nickname = $0 }))
                        .textFieldStyle(.roundedBorder)
                    ColorPicker("Identity color", selection: Binding(
                        get: { draft.tintHex.flatMap { Color(hex: $0) } ?? AccountIdentity.color(for: draft) },
                        set: { draft.tintHex = $0.hexString }))
                    if draft.type == .creditCard {
                        TextField("Credit limit", value: Binding(get: { draft.creditLimit ?? 0 },
                            set: { draft.creditLimit = $0 }), format: .currency(code: draft.currency))
                            .textFieldStyle(.roundedBorder)
                    }
                    if draft.type == .investment || draft.type == .retirement {
                        Picker("Classification", selection: Binding(get: { draft.type },
                            set: { draft.setInvestmentRetirementClassification($0) })) {
                            Text("Investment").tag(AccountType.investment)
                            Text("Retirement").tag(AccountType.retirement)
                        }.pickerStyle(.segmented)
                        if draft.type == .retirement {
                            Picker("Retirement type", selection: Binding(get: { draft.retirementKind ?? .other },
                                set: { draft.retirementKind = $0 })) {
                                ForEach(RetirementKind.allCases, id: \.self) { Text($0.displayName).tag($0) }
                            }
                        }
                        Picker("Liquidity", selection: Binding(get: { draft.liquidity }, set: { draft.liquidity = $0 })) {
                            ForEach(AccountLiquidity.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        Toggle("Include in Net Worth", isOn: Binding(get: { draft.effectiveIncludeInNetWorth },
                            set: { draft.includeInNetWorth = $0 }))
                        Toggle("Include in Cash Flow", isOn: Binding(get: { draft.effectiveIncludeInCashFlow },
                            set: { draft.includeInCashFlow = $0 }))
                        Toggle("Include in Regular Income", isOn: Binding(get: { draft.effectiveIncludeInRegularIncome },
                            set: { draft.includeInRegularIncome = $0 }))
                        if draft.type == .retirement {
                            Toggle("Track for PPR/tax purposes", isOn: Binding(
                                get: { draft.taxTrackingEnabled ?? (draft.retirementKind == .ppr) },
                                set: { draft.taxTrackingEnabled = $0 }))
                        }
                    }
                    if let editError { Label(editError, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange) }
                    HStack {
                        Button("Cancel") { editingDraft = nil; editError = nil }
                        Button("Save") { saveDraft(draft) }.buttonStyle(.borderedProminent)
                    }
                } else {
                    if let limit = displayedAccount.creditLimit, displayedAccount.type == .creditCard {
                        LabeledContent("Credit limit", value: MoneyFormat.string(limit, code: displayedAccount.currency))
                            .font(.caption).monospacedDigit()
                    }
                    if displayedAccount.type == .investment || displayedAccount.type == .retirement {
                        if let kind = displayedAccount.retirementKind, displayedAccount.type == .retirement {
                            LabeledContent("Retirement type", value: kind.displayName).font(.caption)
                        }
                        LabeledContent("Liquidity", value: displayedAccount.liquidity.displayName).font(.caption)
                        Label("Include in Net Worth", systemImage: displayedAccount.effectiveIncludeInNetWorth ? "checkmark.circle" : "circle")
                        Label("Include in Cash Flow", systemImage: displayedAccount.effectiveIncludeInCashFlow ? "checkmark.circle" : "circle")
                        Label("Include in Regular Income", systemImage: displayedAccount.effectiveIncludeInRegularIncome ? "checkmark.circle" : "circle")
                        if displayedAccount.type == .retirement {
                            Label("Track for PPR/tax purposes", systemImage: (displayedAccount.taxTrackingEnabled ?? (displayedAccount.retirementKind == .ppr)) ? "checkmark.circle" : "circle")
                        }
                    }
                    Button("Edit") { beginEditing() }.buttonStyle(.bordered)
                }
                if displayedAccount.type == .creditCard {
                    Button { showingSpendRequirementEditor = true } label: {
                        Label("Configurar gasto mínimo", systemImage: "target")
                    }.buttonStyle(.bordered).disabled(editingDraft != nil)
                }
                if displayedAccount.type == .investment {
                    Button(action: onEditPositions) { Label("Edit Stock Positions", systemImage: "chart.line.uptrend.xyaxis").font(.caption) }
                        .disabled(editingDraft != nil || state?.canAddPositions != true)
                    if let state, !state.canAddPositions {
                        Text("Create a separate brokerage account to track stocks.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Button(action: onAddBalanceSnapshot) { Label("Add Balance Snapshot", systemImage: "chart.line.uptrend.xyaxis").font(.caption) }
                    .disabled(editingDraft != nil)
                Button(action: onArchive) { Label("Archive Account", systemImage: "archivebox").font(.caption) }
                    .disabled(editingDraft != nil)
                Button(role: .destructive, action: onDelete) { Label("Delete Account", systemImage: "trash").font(.caption) }
                    .disabled(editingDraft != nil)
            }.frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .sheet(isPresented: $showingSpendRequirementEditor) {
            SpendRequirementEditorSheet(account: account, accounts: accounts, onSave: onSpendRequirementChanged)
        }
        .onChange(of: account.lastModifiedAt) {
            if let savedSnapshot, account.lastModifiedAt >= savedSnapshot.lastModifiedAt {
                self.savedSnapshot = nil
            }
        }
    }

    private func beginEditing() {
        editingDraft = AccountConfigurationEditor.makeDraft(from: displayedAccount)
        editRevision = displayedAccount.lastModifiedAt
        editError = nil
    }

    private func saveDraft(_ draft: Account) {
        do {
            savedSnapshot = try AccountConfigurationEditor.save(draft: draft, accountID: account.id,
                                                               expectedRevision: editRevision, container: modelContext.container)
            editingDraft = nil
            editError = nil
            onSpendRequirementChanged()
        } catch { editError = error.localizedDescription }
    }
}

@MainActor
enum AccountConfigurationEditor {
    enum SaveError: LocalizedError {
        case unavailable, changed
        var errorDescription: String? {
            switch self {
            case .unavailable: String(localized: "Account unavailable")
            case .changed: String(localized: "This account changed. Cancel and reopen it before saving.")
            }
        }
    }

    static func makeDraft(from account: Account) -> Account {
        let draft = Account(id: account.id, institution: account.institution, type: account.type, currency: account.currency,
            nickname: account.nickname, accountNumber: account.accountNumber, openedAt: account.openedAt,
            closedAt: account.closedAt, archivedAt: account.archivedAt, creditLimit: account.creditLimit,
            statementDayOfMonth: account.statementDayOfMonth, paymentDayOfMonth: account.paymentDayOfMonth,
            tintHex: account.tintHex, manuallyCreatedAt: account.manuallyCreatedAt)
        draft.retirementKindRaw = account.retirementKindRaw
        draft.liquidityRaw = account.liquidityRaw
        draft.includeInNetWorth = account.includeInNetWorth
        draft.includeInCashFlow = account.includeInCashFlow
        draft.includeInRegularIncome = account.includeInRegularIncome
        draft.taxTrackingEnabled = account.taxTrackingEnabled
        draft.lastModifiedAt = account.lastModifiedAt
        return draft
    }

    @discardableResult
    static func save(draft: Account, accountID: UUID, expectedRevision: Date?, container: ModelContainer,
                     commit: (ModelContext) throws -> Void = { try $0.save() }) throws -> Account {
        let context = ModelContext(container)
        context.autosaveEnabled = false
        let id = accountID
        guard let target = try context.fetch(FetchDescriptor<Account>(predicate: #Predicate<Account> { $0.id == id })).first else {
            throw SaveError.unavailable
        }
        guard target.lastModifiedAt == expectedRevision else { throw SaveError.changed }
        target.nickname = draft.nickname
        target.tintHex = draft.tintHex
        target.creditLimit = draft.creditLimit
        target.type = draft.type
        target.retirementKindRaw = draft.retirementKindRaw
        target.liquidityRaw = draft.liquidityRaw
        target.includeInNetWorth = draft.includeInNetWorth
        target.includeInCashFlow = draft.includeInCashFlow
        target.includeInRegularIncome = draft.includeInRegularIncome
        target.taxTrackingEnabled = draft.taxTrackingEnabled
        target.touch()
        try commit(context)
        return makeDraft(from: target)
    }
}

private struct DataHealthSection: View {
    let accounts: [Account]
    let activeCategoryCount: Int
    let refreshToken: Int

    @State private var isReady = false

    var body: some View {
        if accounts.isEmpty {
            DataHealthSummaryPanel(summary: DataHealthSummary(
                accounts: [],
                transactions: [],
                pendingImports: [],
                activeCategoryCount: activeCategoryCount,
                importedStatementCount: 0
            ))
        } else if isReady {
            DataHealthLoadedSection(
                accounts: accounts,
                activeCategoryCount: activeCategoryCount,
                refreshToken: refreshToken
            )
        } else {
            SectionCard(title: "Your data") {
                ProgressView("Calculating data summary…")
                    .frame(maxWidth: .infinity, minHeight: 100)
                    .padding(16)
            }
            .task {
                await Task.yield()
                isReady = true
            }
        }
    }
}

private struct DataHealthLoadedSection: View {
    @Environment(\.modelContext) private var modelContext

    let accounts: [Account]
    let activeCategoryCount: Int
    let refreshToken: Int

    @State private var summary: DataHealthSummary?
    @State private var loadError: String?

    var body: some View {
        Group {
            if let summary {
                DataHealthSummaryPanel(summary: summary)
            } else if let loadError {
                SectionCard(title: "Your data") {
                    Label("Resumen de datos no disponible: \(loadError)", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, minHeight: 100)
                        .padding(16)
                }
            } else {
                SectionCard(title: "Your data") {
                    ProgressView("Calculating data summary…")
                        .frame(maxWidth: .infinity, minHeight: 100)
                        .padding(16)
                }
            }
        }
        .task(id: refreshRevision) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            do {
                let loader = DataHealthSnapshotLoader(modelContainer: modelContext.container)
                let calculatedSummary = try await loader.load(activeCategoryCount: activeCategoryCount)
                guard !Task.isCancelled else { return }
                summary = calculatedSummary
                loadError = nil
            } catch {
                guard !Task.isCancelled else { return }
                loadError = error.localizedDescription
            }
        }
    }

    private var refreshRevision: Int {
        var hasher = Hasher()
        for account in accounts {
            hasher.combine(account.id)
            hasher.combine(account.closedAt)
            hasher.combine(account.archivedAt)
            hasher.combine(account.currency)
        }
        hasher.combine(refreshToken)
        hasher.combine(activeCategoryCount)
        return hasher.finalize()
    }
}

private struct DataHealthSummaryPanel: View {
    let summary: DataHealthSummary

    var body: some View {
        SectionCard(title: "Your data") {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    DataHealthCard(label: "Active accounts", value: "\(summary.activeAccountCount)", detail: "closed and archived accounts excluded")
                    DataHealthCard(label: "History", value: historyValue, detail: summary.hasTransactionHistory ? "active transaction range" : "No transaction history yet")
                    DataHealthCard(label: "Último movimiento", value: summary.lastActivity?.formattedMX() ?? "—", detail: summary.lastActivity == nil ? "Aún no hay actividad" : "movimiento activo más reciente")
                    DataHealthCard(label: "Needs attention", value: "\(summary.unresolvedPendingCount)", detail: summary.unresolvedPendingCount == 0 ? "Nothing needs attention" : "pending imports", tint: summary.unresolvedPendingCount == 0 ? .green : .orange)
                }

                let currencySummary = summary.currenciesInUse.isEmpty ? "none" : summary.currenciesInUse.joined(separator: ", ")
                Text("\(summary.importedStatementCount) estados de cuenta importados · \(summary.activeCategoryCount) categorías activas · Monedas: \(currencySummary)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)
        }
    }

    private var historyValue: String {
        guard let start = summary.historyStart, let end = summary.historyEnd else { return "—" }
        let calendar = Calendar.current
        if calendar.isDate(start, inSameDayAs: end) {
            return start.formattedMX()
        }
        return "\(start.formattedMX()) – \(end.formattedMX())"
    }
}

private struct DataHealthCard: View {
    let label: String
    let value: String
    let detail: String
    var tint: Color = .primary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .foregroundStyle(tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 88, alignment: .topLeading)
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
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
    let onRename: (Category, String) -> Void
    let onTintChange: (Category, Color?) -> Void

    @FocusState private var focusedField: CategoryPanelFocus?
    @State private var tree: CategoryManagementTree
    @State private var isTreeReady = false
    @State private var renamingSubcategoryID: UUID?
    @State private var renameDraft = ""
    @State private var renameOriginal = ""
    @State private var tintTick = 0

    init(
        categories: [Category],
        selectedCategoryID: Binding<UUID?>,
        searchText: Binding<String>,
        kindFilter: Binding<CategoryKindFilter>,
        newSubcategoryName: Binding<String>,
        focusRequest: Int,
        onNewCategory: @escaping () -> Void,
        onCreateSubcategory: @escaping (Category) -> Void,
        onDeleteParent: @escaping (Category) -> Void,
        onDeleteSubcategory: @escaping (Category, Category) -> Void,
        onRename: @escaping (Category, String) -> Void,
        onTintChange: @escaping (Category, Color?) -> Void
    ) {
        self.categories = categories
        self._selectedCategoryID = selectedCategoryID
        self._searchText = searchText
        self._kindFilter = kindFilter
        self._newSubcategoryName = newSubcategoryName
        self.focusRequest = focusRequest
        self.onNewCategory = onNewCategory
        self.onCreateSubcategory = onCreateSubcategory
        self.onDeleteParent = onDeleteParent
        self.onDeleteSubcategory = onDeleteSubcategory
        self.onRename = onRename
        self.onTintChange = onTintChange
        self._tree = State(initialValue: CategoryManagementTree(categories: []))
    }

    var body: some View {
        let categoryRevision = CategoryManagementTree.revision(from: categories)

        Group {
            if isTreeReady {
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
            } else {
                ProgressView("Loading categories…")
                    .frame(maxWidth: .infinity, minHeight: 420)
            }
        }
        .task(id: categoryRevision) {
            await Task.yield()
            guard !Task.isCancelled else { return }
            tree = CategoryManagementTree(categories: categories)
            isTreeReady = true
            reconcileSelection()
        }
        .onChange(of: searchText) { _, _ in if isTreeReady { reconcileSelection() } }
        .onChange(of: kindFilter) { _, _ in if isTreeReady { reconcileSelection() } }
        .onChange(of: selectedCategoryID) { _, _ in
            newSubcategoryName = ""
        }
        .onChange(of: focusRequest) { _, _ in
            focusedField = .newSubcategoryName
        }
        .onReceive(NotificationCenter.default.publisher(for: CategoryCustomizationStore.didChangeNotification)) { _ in
            CategoryBadgeColor.refresh()
            tintTick &+= 1
        }
    }

    private var browserPane: some View {
        let visibleParents = tree.visibleParents(searchText: searchText, kindFilter: kindFilter)

        return VStack(alignment: .leading, spacing: 12) {
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
                    Text("\(visibleParents.count) visibles")
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
                    .fill(CategoryBadgeColor.color(for: parent))
                    .frame(width: 13, height: 13)

                VStack(alignment: .leading, spacing: 3) {
                    editableName(for: parent, fontSize: .title3.weight(.semibold))
                    HStack(spacing: 8) {
                        Text(parent.kind.displayName)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        Text("\(subcategories.count) subcategorías")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                tintPicker(for: parent)

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
                .fill(CategoryBadgeColor.color(for: subcategory))
                .frame(width: 5, height: 22)

            if renamingSubcategoryID == subcategory.id {
                TextField("Nombre", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { commitRename(subcategory) }
                Button { commitRename(subcategory) } label: { Image(systemName: "checkmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.green)
                    .help("Guardar nombre")
                Button { renamingSubcategoryID = nil } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancelar")
            } else {
                Text(subcategory.localizedName)
                    .font(.body)
                    .lineLimit(1)
            }

            Spacer()

            Button {
                renameDraft = subcategory.localizedName
                renameOriginal = subcategory.localizedName
                renamingSubcategoryID = subcategory.id
            } label: {
                Image(systemName: "pencil")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Rename subcategory")

            tintPicker(for: subcategory)

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

    /// Nombre del padre: texto o campo según el modo de edición.
    @ViewBuilder
    private func editableName(for parent: Category, fontSize: Font) -> some View {
        if renamingSubcategoryID == parent.id {
            HStack(spacing: 6) {
                TextField("Nombre", text: $renameDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(fontSize)
                    .onSubmit { commitRename(parent) }
                Button { commitRename(parent) } label: { Image(systemName: "checkmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.green)
                    .help("Guardar nombre")
                Button { renamingSubcategoryID = nil } label: { Image(systemName: "xmark.circle") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancelar")
            }
        } else {
            HStack(spacing: 6) {
                Text(parent.localizedName)
                    .font(fontSize)
                    .lineLimit(1)
                Button {
                    renameDraft = parent.localizedName
                    renameOriginal = parent.localizedName
                    renamingSubcategoryID = parent.id
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help("Rename category")
            }
        }
    }

    private func commitRename(_ category: Category) {
        defer { renamingSubcategoryID = nil }
        let trimmed = renameDraft.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // Confirmar sin cambios es CANCELACIÓN: sin write, sin touch(), sin
        // registrar seedName — un seed no se personaliza por abrir el editor.
        guard trimmed != renameOriginal else { return }
        onRename(category, trimmed)
    }

    /// ColorPicker del tinte con botón de volver al color automático.
    private func tintPicker(for category: Category) -> some View {
        HStack(spacing: 10) {
            ColorPicker("", selection: Binding(
                get: { CategoryBadgeColor.color(for: category) },
                set: { onTintChange(category, $0) }
            ), supportsOpacity: false)
            .labelsHidden()
            .fixedSize()
            .frame(width: 44)
            .help("Color del badge")
            Button {
                onTintChange(category, nil)
            } label: {
                Image(systemName: "paintpalette")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("Usar color automático")
        }
    }

    private func reconcileSelection() {
        guard isTreeReady else { return }
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
                    .fill(CategoryBadgeColor.color(for: category))
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 3) {
                    Text(category.localizedName)
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
        .help("\(category.localizedName), \(subcategoryCount) subcategorías")
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
                onDeleteSubcategory: { _, _ in },
                onRename: { _, _ in },
                onTintChange: { _, _ in }
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

private struct BackupStatusPreviewCard: View {
    let presentation: BackupStatusPresentation

    var body: some View {
        SectionCard(title: "Backup & Restore") {
            VStack(alignment: .leading, spacing: 10) {
                Label("Automatic backups", systemImage: "checkmark.shield")
                    .font(.subheadline.weight(.semibold))
                if let createdAt = presentation.createdAt, let latestPath = presentation.latestPath {
                    Text("Último respaldo verificado · \(createdAt.formattedMX(date: .abbreviated, time: .shortened))")
                        .font(.callout.weight(.medium))
                    Text(latestPath)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("No verified automatic backup found yet.")
                        .foregroundStyle(.secondary)
                }
                Text("Carpeta administrada (FinanceTracker): \(presentation.managedDirectoryPath)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)
        }
        .frame(width: 760)
        .padding()
    }
}

private struct DataHealthPreviewPanel: View {
    let summary: DataHealthSummary

    var body: some View {
        SectionCard(title: "Your data") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                DataHealthCard(label: "Active accounts", value: "\(summary.activeAccountCount)", detail: "closed and archived accounts excluded")
                DataHealthCard(label: "History", value: historyValue, detail: summary.hasTransactionHistory ? "active transaction range" : "No transaction history yet")
                DataHealthCard(label: "Último movimiento", value: summary.lastActivity?.formattedMX() ?? "—", detail: summary.lastActivity == nil ? "Aún no hay actividad" : "movimiento activo más reciente")
                DataHealthCard(label: "Needs attention", value: "\(summary.unresolvedPendingCount)", detail: summary.unresolvedPendingCount == 0 ? "Nothing needs attention" : "pending imports", tint: summary.unresolvedPendingCount == 0 ? .green : .orange)
            }
            .padding(16)
        }
        .frame(width: 900)
        .padding()
    }

    private var historyValue: String {
        guard let start = summary.historyStart, let end = summary.historyEnd else { return "—" }
        return "\(start.formattedMX()) – \(end.formattedMX())"
    }
}

#Preview("Settings Backup — verified") {
    BackupStatusPreviewCard(
        presentation: BackupStatusPresentation(
            latestBackup: BackupSummary(
                url: URL(fileURLWithPath: "/Users/example/Library/Application Support/FinanceTracker/Backups/FinanceTracker-2026-08-10T11-47-00.ftbackup"),
                createdAt: .now,
                schemaVersion: 7
            ),
            managedDirectory: URL(fileURLWithPath: "/Users/example/Library/Application Support/FinanceTracker/Backups")
        )
    )
}

#Preview("Settings Backup — no snapshot") {
    BackupStatusPreviewCard(
        presentation: BackupStatusPresentation(
            latestBackup: nil,
            managedDirectory: URL(fileURLWithPath: "/Users/example/Library/Application Support/FinanceTracker/Backups")
        )
    )
}

#Preview("Settings Data — pending imports") {
    DataHealthPreviewPanel(
        summary: DataHealthSummary(
            accounts: [DataHealthAccountInput(closedAt: nil, currency: "MXN")],
            transactions: [DataHealthTransactionInput(postedAt: .now, deletedAt: nil, isDuplicate: false, currency: "MXN")],
            pendingImports: [DataHealthPendingInput(isResolved: false)],
            activeCategoryCount: 12,
            importedStatementCount: 8
        )
    )
}

#Preview("Settings Data — healthy") {
    DataHealthPreviewPanel(
        summary: DataHealthSummary(
            accounts: [
                DataHealthAccountInput(closedAt: nil, currency: "MXN"),
                DataHealthAccountInput(closedAt: nil, currency: "USD"),
            ],
            transactions: [DataHealthTransactionInput(postedAt: .now, deletedAt: nil, isDuplicate: false, currency: "MXN")],
            pendingImports: [],
            activeCategoryCount: 18,
            importedStatementCount: 24
        )
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
