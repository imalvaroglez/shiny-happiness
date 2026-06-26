import SwiftData
import SwiftUI

struct PositionsEditSheet: View {
    let account: Account
    let context: ModelContext
    var onChanged: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var positions: [StockPosition] = []
    @State private var adding = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            List {
                if positions.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No positions yet. Add the first stock for this brokerage account.")
                        if !PortfolioService.canAddPositions(account: account, context: context) {
                            Text("This account has existing non-portfolio activity. Create a separate brokerage account to track stocks.")
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }

                ForEach(positions) { position in
                    PositionRowView(
                        position: position,
                        account: account,
                        context: context,
                        onError: { errorText = $0 },
                        onChanged: didChange
                    )
                }
            }
            .navigationTitle("Stock Positions")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        adding = true
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .disabled(!PortfolioService.canAddPositions(account: account, context: context))
                }
            }
            .sheet(isPresented: $adding) {
                AddPositionSheet(
                    account: account,
                    context: context,
                    onError: { errorText = $0 },
                    onSaved: didChange
                )
            }
            .alert("Portfolio", isPresented: errorPresented) {
                Button("OK") { errorText = nil }
            } message: {
                Text(errorText ?? "")
            }
        }
        .frame(minWidth: 620, minHeight: 520)
        .task { reload() }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )
    }

    private func didChange() {
        reload()
        onChanged()
    }

    private func reload() {
        positions = PortfolioService.allPositions(accountID: account.id, context: context)
            .sorted { $0.emisoraSerie < $1.emisoraSerie }
    }
}

private struct AddPositionSheet: View {
    let account: Account
    let context: ModelContext
    var onError: (String) -> Void
    var onSaved: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var ticker = ""
    @State private var name = ""
    @State private var shares: Decimal = 0
    @State private var averageCost: Decimal = 0
    @State private var errorText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Position")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .center)

            Form {
                TextField("Ticker (for example, VOO or GFNORTEO)", text: $ticker)
                TextField("Name (optional)", text: $name)
                TextField("Shares", value: $shares, format: .number)
                TextField("Average cost", value: $averageCost, format: .number)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.glassProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
        .alert("Couldn't save", isPresented: errorPresented) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )
    }

    private func save() {
        do {
            try PortfolioService.addPosition(
                account: account,
                emisoraSerie: ticker,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                shares: shares,
                averageCost: averageCost,
                context: context
            )
            onSaved()
            dismiss()
        } catch {
            errorText = error.localizedDescription
            onError(error.localizedDescription)
        }
    }
}

private struct PositionRowView: View {
    let position: StockPosition
    let account: Account
    let context: ModelContext
    var onError: (String) -> Void
    var onChanged: () -> Void

    @State private var name: String
    @State private var shares: Decimal
    @State private var averageCost: Decimal
    @State private var buyShares: Decimal = 0
    @State private var buyPrice: Decimal = 0
    @State private var confirmingDelete = false

    init(
        position: StockPosition,
        account: Account,
        context: ModelContext,
        onError: @escaping (String) -> Void,
        onChanged: @escaping () -> Void
    ) {
        self.position = position
        self.account = account
        self.context = context
        self.onError = onError
        self.onChanged = onChanged
        _name = State(initialValue: position.name ?? "")
        _shares = State(initialValue: position.shares)
        _averageCost = State(initialValue: position.averageCost)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(position.emisoraSerie)
                        .font(.headline)
                    Text(position.name.flatMap { $0.nilIfEmpty } ?? "Unnamed position")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(positionValue)
                        .font(.callout.monospacedDigit())
                    Text(lastPriceText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text("Name")
                    TextField("Optional", text: $name)
                }
                GridRow {
                    Text("Shares")
                    TextField("Shares", value: $shares, format: .number)
                }
                GridRow {
                    Text("Avg cost")
                    TextField("Average cost", value: $averageCost, format: .number)
                }
            }
            .textFieldStyle(.roundedBorder)

            HStack {
                Button("Save Changes") { saveEdit() }
                Spacer()
                Button("Delete", role: .destructive) { confirmingDelete = true }
            }

            DisclosureGroup("Buy More") {
                HStack {
                    TextField("Added shares", value: $buyShares, format: .number)
                    TextField("Buy price", value: $buyPrice, format: .number)
                    Button("Record Buy") { buyMore() }
                }
                .textFieldStyle(.roundedBorder)
                .padding(.top, 6)
            }
            .font(.caption)
        }
        .padding(.vertical, 8)
        .confirmationDialog(
            "Delete \(position.emisoraSerie)?",
            isPresented: $confirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete Position", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("If this is the final active position, the portfolio valuation will be reset to zero.")
        }
    }

    private var positionValue: String {
        guard let lastPrice = position.lastPrice else { return "Not priced" }
        return MoneyFormat.string(position.shares * lastPrice, code: account.currency)
    }

    private var lastPriceText: String {
        guard let lastPrice = position.lastPrice else { return "No last price" }
        return "Last \(MoneyFormat.string(lastPrice, code: account.currency))"
    }

    private func saveEdit() {
        guard shares > 0 else {
            onError("Use Delete to remove a position so the portfolio valuation is cleared correctly.")
            return
        }

        do {
            try PortfolioService.edit(
                position: position,
                shares: shares,
                averageCost: averageCost,
                name: name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty,
                context: context
            )
            onChanged()
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func buyMore() {
        do {
            try PortfolioService.buyMore(
                position: position,
                addedShares: buyShares,
                buyPrice: buyPrice,
                context: context
            )
            shares = position.shares
            averageCost = position.averageCost
            buyShares = 0
            buyPrice = 0
            onChanged()
        } catch {
            onError(error.localizedDescription)
        }
    }

    private func delete() {
        do {
            try PortfolioService.delete(position: position, account: account, context: context)
            onChanged()
        } catch {
            onError(error.localizedDescription)
        }
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
