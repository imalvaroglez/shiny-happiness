import SwiftUI
import SwiftData

struct CategoryPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var categories: [Category]
    let transaction: Transaction
    let onCategorySelected: (Category, String?) -> Void

    private var groupedCategories: [(kind: CategoryKind, categories: [Category])] {
        let parents = categories.filter { $0.parent == nil }
        let kinds: [CategoryKind] = [.expense, .income, .transfer, .investment]
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
                            let subs = cat.subcategories.sorted { $0.name < $1.name }
                            if !subs.isEmpty {
                                ForEach(subs) { sub in
                                    categoryRow(sub, depth: 1)
                                }
                            }
                        }
                    }
                }
            }
        }
        .frame(minWidth: 300, minHeight: 400)
    }

    private func categoryRow(_ category: Category, depth: Int = 0) -> some View {
        Button {
            let keyword = MerchantExtractor.extractMerchant(from: transaction.descriptionRaw)
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
                if transaction.category?.id == category.id {
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
