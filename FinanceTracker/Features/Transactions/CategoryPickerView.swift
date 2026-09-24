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
    @State private var groupedCategories: [CategoryPickerSection] = []

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

    var body: some View {
        VStack(spacing: 0) {
            Text("Choose Category")
                .font(.headline)
                .padding()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(groupedCategories) { group in
                        Text(group.kind.rawValue.capitalized)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal)
                            .padding(.top, 8)

                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(group.rows) { row in
                                categoryRow(row.category, depth: row.depth)
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
        .onChange(of: categoryIndexRevision, initial: true) { _, _ in
            groupedCategories = CategoryPickerIndex.build(categories: categories, allowedKinds: allowedKinds)
        }
    }

    private var categoryIndexRevision: CategoryPickerIndexRevision {
        CategoryPickerIndexRevision(
            categories: categories.map {
                CategoryPickerCategoryRevision(id: $0.id, name: $0.name, parentID: $0.parent?.id, kind: $0.kind.rawValue)
            },
            allowedKinds: allowedKinds?.map(\.rawValue).sorted()
        )
    }

    private func categoryRow(_ category: Category, depth: Int) -> some View {
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

struct CategoryPickerRow: Identifiable {
    let category: Category
    let depth: Int

    var id: UUID { category.id }
}

struct CategoryPickerSection: Identifiable {
    let kind: CategoryKind
    let rows: [CategoryPickerRow]

    var id: CategoryKind { kind }
}

private struct CategoryPickerCategoryRevision: Equatable {
    let id: UUID
    let name: String
    let parentID: UUID?
    let kind: String
}

private struct CategoryPickerIndexRevision: Equatable {
    let categories: [CategoryPickerCategoryRevision]
    let allowedKinds: [String]?
}

enum CategoryPickerIndex {
    private static let kindOrder: [CategoryKind] = [.expense, .income, .transfer, .investment, .creditCardPayment]

    static func build(categories: [Category], allowedKinds: Set<CategoryKind>?) -> [CategoryPickerSection] {
        let visible = deduplicated(categories)
        var parentsByKind: [CategoryKind: [Category]] = [:]
        var childrenByParentID: [UUID: [Category]] = [:]

        for category in visible {
            if let parentID = category.parent?.id {
                childrenByParentID[parentID, default: []].append(category)
            } else if allowedKinds?.contains(category.kind) ?? true {
                parentsByKind[category.kind, default: []].append(category)
            }
        }

        for parentID in Array(childrenByParentID.keys) {
            childrenByParentID[parentID]?.sort { $0.name < $1.name }
        }

        return kindOrder.compactMap { kind in
            guard let parents = parentsByKind[kind], !parents.isEmpty else { return nil }
            let sortedParents = parents.sorted { $0.name < $1.name }
            let rows = sortedParents.flatMap { parent in
                [CategoryPickerRow(category: parent, depth: 0)]
                    + (childrenByParentID[parent.id] ?? []).map { CategoryPickerRow(category: $0, depth: 1) }
            }
            return CategoryPickerSection(kind: kind, rows: rows)
        }
    }

    private static func deduplicated(_ categories: [Category]) -> [Category] {
        var seen = Set<String>()
        return categories.sorted(by: displaySort).filter { category in
            seen.insert(displayKey(category)).inserted
        }
    }

    private static func displayKey(_ category: Category) -> String {
        let parentID = category.parent?.id.uuidString ?? "root"
        let name = category.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(parentID)|\(category.kind.rawValue)|\(name)"
    }

    private static func displaySort(_ lhs: Category, _ rhs: Category) -> Bool {
        let lhsName = lhs.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let rhsName = rhs.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if lhsName != rhsName { return lhsName < rhsName }
        if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}
