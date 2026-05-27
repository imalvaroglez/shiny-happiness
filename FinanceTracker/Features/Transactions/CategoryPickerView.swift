import SwiftUI
import SwiftData

struct CategoryPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(filter: #Predicate<Category> { $0.deletedAt == nil }) private var categories: [Category]

    private let transaction: Transaction?
    private let selectedCategoryID: UUID?
    private let allowedKinds: Set<CategoryKind>?
    private let onCategorySelected: (Category, String?) -> Void

    init(
        transaction: Transaction,
        allowedKinds: Set<CategoryKind>? = nil,
        onCategorySelected: @escaping (Category, String?) -> Void
    ) {
        self.transaction = transaction
        self.selectedCategoryID = transaction.category?.id
        self.allowedKinds = allowedKinds
        self.onCategorySelected = onCategorySelected
    }

    init(
        selectedCategoryID: UUID?,
        allowedKinds: Set<CategoryKind>? = nil,
        onCategorySelected: @escaping (Category) -> Void
    ) {
        self.transaction = nil
        self.selectedCategoryID = selectedCategoryID
        self.allowedKinds = allowedKinds
        self.onCategorySelected = { category, _ in onCategorySelected(category) }
    }

    private var groupedCategories: [(kind: CategoryKind, categories: [Category])] {
        let parents = categories.filter { category in
            category.parent == nil && (allowedKinds?.contains(category.kind) ?? true)
        }
        let kinds: [CategoryKind] = [.expense, .income, .transfer, .investment, .creditCardPayment]
        return kinds.compactMap { kind in
            let cats = parents.filter { $0.kind == kind }.sorted { $0.name < $1.name }
            return cats.isEmpty ? nil : (kind, cats)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Text("Choose Category")
                .font(.headline)
                .padding()

            ScrollView {
                ForEach(groupedCategories, id: \.kind) { group in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(group.kind.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.top, 8)

                        ForEach(group.categories) { cat in
                            categoryRow(cat)
                            let subs = categories
                                .filter { $0.parent?.id == cat.id }
                                .sorted { $0.name < $1.name }
                            if !subs.isEmpty {
                                ForEach(subs) { sub in
                                    categoryRow(sub, depth: 1)
                                }
                            }
                        }
                    }
                }
            }

            Text("Manage categories in Settings.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.bottom, 12)
        }
        .frame(minWidth: 300, minHeight: 400)
    }

    private func categoryRow(_ category: Category, depth: Int = 0) -> some View {
        Button {
            let keyword = transaction.flatMap { MerchantExtractor.extractMerchant(from: $0.descriptionRaw) }
            onCategorySelected(category, keyword)
            dismiss()
        } label: {
            HStack {
                if depth > 0 {
                    Spacer().frame(width: CGFloat(depth) * 20)
                }
                Text(category.name)
                    .foregroundStyle(.primary)
                Spacer()
                if selectedCategoryID == category.id {
                    Image(systemName: "checkmark")
                        .foregroundStyle(.blue)
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
