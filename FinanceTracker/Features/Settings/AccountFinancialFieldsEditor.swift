import SwiftUI
import SwiftData

/// Edits the high-impact (financial-identity) fields of an account through a
/// draft → Save/Cancel model, so a change to credit limit, classification,
/// liquidity, or reporting-inclusion toggles is never persisted silently on
/// toggle. Low-risk fields (nickname, identity color) stay autosaved in the
/// parent row and are intentionally not handled here.
///
/// High-impact fields, per the Trust & Recovery boundary:
/// credit limit, investment/retirement classification, retirement type,
/// liquidity, include-in-net-worth / cash-flow / regular-income, tax tracking.
struct AccountFinancialFieldsEditor: View {
    @Environment(\.modelContext) private var modelContext
    let account: Account

    @State private var draftCreditLimit: Decimal
    @State private var draftType: AccountType
    @State private var draftRetirementKind: RetirementKind
    @State private var draftLiquidity: AccountLiquidity
    @State private var draftIncludeInNetWorth: Bool
    @State private var draftIncludeInCashFlow: Bool
    @State private var draftIncludeInRegularIncome: Bool
    @State private var draftTaxTracking: Bool

    @State private var saveError: String?
    @State private var didSeed = false

    init(account: Account) {
        self.account = account
        // Seed from the live account so Cancel can always return to the persisted state.
        _draftCreditLimit = State(initialValue: account.creditLimit ?? 0)
        _draftType = State(initialValue: account.type)
        _draftRetirementKind = State(initialValue: account.retirementKind ?? .other)
        _draftLiquidity = State(initialValue: account.liquidity)
        _draftIncludeInNetWorth = State(initialValue: account.effectiveIncludeInNetWorth)
        _draftIncludeInCashFlow = State(initialValue: account.effectiveIncludeInCashFlow)
        _draftIncludeInRegularIncome = State(initialValue: account.effectiveIncludeInRegularIncome)
        _draftTaxTracking = State(initialValue: account.taxTrackingEnabled ?? (account.retirementKind == .ppr))
    }

    private var hasHighImpactFields: Bool {
        account.type == .creditCard || account.type == .investment || account.type == .retirement
    }

    private var isDirty: Bool {
        guard hasHighImpactFields else { return false }
        if account.type == .creditCard && (account.creditLimit ?? 0) != draftCreditLimit { return true }
        if draftType != account.type { return true }
        if account.type == .retirement || draftType == .retirement {
            if draftRetirementKind != (account.retirementKind ?? .other) { return true }
        }
        if draftLiquidity != account.liquidity { return true }
        if draftIncludeInNetWorth != account.effectiveIncludeInNetWorth { return true }
        if draftIncludeInCashFlow != account.effectiveIncludeInCashFlow { return true }
        if draftIncludeInRegularIncome != account.effectiveIncludeInRegularIncome { return true }
        if (account.type == .retirement || draftType == .retirement),
           draftTaxTracking != (account.taxTrackingEnabled ?? (account.retirementKind == .ppr)) {
            return true
        }
        return false
    }

    var body: some View {
        // Only accounts with high-impact fields render an editor at all.
        if hasHighImpactFields {
            VStack(alignment: .leading, spacing: 8) {
                fields
                if isDirty {
                    saveControls
                }
                if let saveError {
                    Text(saveError)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
    }

    @ViewBuilder
    private var fields: some View {
        if draftType == .creditCard {
            TextField("Credit limit", value: $draftCreditLimit, format: .currency(code: account.currency))
                .textFieldStyle(.roundedBorder)
        }

        if account.type == .investment || account.type == .retirement {
            Picker("Classification", selection: $draftType) {
                Text("Investment").tag(AccountType.investment)
                Text("Retirement").tag(AccountType.retirement)
            }
            .pickerStyle(.segmented)
        }

        if draftType == .retirement {
            Picker("Retirement type", selection: $draftRetirementKind) {
                ForEach(RetirementKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }
            .labelsHidden()

            Text("Retirement accounts are included in Total Net Worth but excluded from regular Cash Flow by default.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }

        if draftType == .retirement || draftType == .investment {
            Picker("Liquidity", selection: $draftLiquidity) {
                ForEach(AccountLiquidity.allCases, id: \.self) { value in
                    Text(value.displayName).tag(value)
                }
            }
            .labelsHidden()

            Toggle("Include in Net Worth", isOn: $draftIncludeInNetWorth)
            Toggle("Include in Cash Flow", isOn: $draftIncludeInCashFlow)
            Toggle("Include in Regular Income", isOn: $draftIncludeInRegularIncome)
        }

        if draftType == .retirement {
            Toggle("Track for PPR/tax purposes", isOn: $draftTaxTracking)
        }
    }

    private var saveControls: some View {
        HStack(spacing: 10) {
            Button("Save changes") { save() }
                .buttonStyle(.glassProminent)
                .controlSize(.small)
            Button("Cancel") { resetDrafts() }
                .controlSize(.small)
        }
    }

    private func resetDrafts() {
        draftCreditLimit = account.creditLimit ?? 0
        draftType = account.type
        draftRetirementKind = account.retirementKind ?? .other
        draftLiquidity = account.liquidity
        draftIncludeInNetWorth = account.effectiveIncludeInNetWorth
        draftIncludeInCashFlow = account.effectiveIncludeInCashFlow
        draftIncludeInRegularIncome = account.effectiveIncludeInRegularIncome
        draftTaxTracking = account.taxTrackingEnabled ?? (account.retirementKind == .ppr)
        saveError = nil
    }

    private func save() {
        if account.type == .creditCard {
            account.creditLimit = draftCreditLimit
        }
        if account.type == .investment || account.type == .retirement {
            account.setInvestmentRetirementClassification(draftType)
        }
        if draftType == .retirement {
            account.retirementKind = draftRetirementKind
        }
        if draftType == .retirement || draftType == .investment {
            account.liquidity = draftLiquidity
            account.includeInNetWorth = draftIncludeInNetWorth
            account.includeInCashFlow = draftIncludeInCashFlow
            account.includeInRegularIncome = draftIncludeInRegularIncome
        }
        if draftType == .retirement {
            account.taxTrackingEnabled = draftTaxTracking
        }
        account.touch()

        do {
            try Persistence.save(modelContext)
            // Re-seed drafts from the now-persisted account so isDirty clears.
            resetDrafts()
        } catch {
            saveError = "Couldn't save changes: \(error.localizedDescription)"
        }
    }
}
