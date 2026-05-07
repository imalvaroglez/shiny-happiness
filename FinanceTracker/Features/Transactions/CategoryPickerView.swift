import SwiftUI
import SwiftData

struct CategoryPickerView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query private var categories: [Category]
    let transaction: Transaction
    let onCategorySelected: (Category, String?) -> Void

    @State private var showingNewCategory = false
    @State private var newCategoryName = ""
    @State private var newCategoryKind: CategoryKind = .expense

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

                Button {
                    showingNewCategory = true
                } label: {
                    HStack {
                        Image(systemName: "plus.circle.fill")
                        Text("New Category")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.blue)
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }

            .sheet(isPresented: $showingNewCategory) {
                newCategoryForm
            }
        }
        .frame(minWidth: 300, minHeight: 400)
    }

    private var newCategoryForm: some View {
        VStack(spacing: 16) {
            Text("New Category")
                .font(.headline)

            TextField("Category name", text: $newCategoryName)
                .textFieldStyle(.roundedBorder)

            Picker("Kind", selection: $newCategoryKind) {
                Text("Expense").tag(CategoryKind.expense)
                Text("Income").tag(CategoryKind.income)
                Text("Transfer").tag(CategoryKind.transfer)
            }
            .pickerStyle(.segmented)

            HStack {
                Button("Cancel") {
                    showingNewCategory = false
                }
                .keyboardShortcut(.cancelAction)

                Button("Create & Apply") {
                    guard !newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
                    let category = Category(name: newCategoryName.trimmingCharacters(in: .whitespaces), kind: newCategoryKind)
                    modelContext.insert(category)
                    try? modelContext.save()

                    let keyword = MerchantExtractor.extractMerchant(from: transaction.descriptionRaw)
                    onCategorySelected(category, keyword)
                    showingNewCategory = false
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.glassProminent)
                .tint(.blue)
                .disabled(newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 320)
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
