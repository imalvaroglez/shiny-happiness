import Foundation

struct HouseholdSettlementPresentationFormatters {
    var monthTitle: (Date) -> String
    var currency: (Decimal, String) -> String
    var percent: (Decimal) -> String

    static var live: HouseholdSettlementPresentationFormatters {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return make(locale: .current, calendar: calendar, timeZone: .current)
    }

    static var stableForTests: HouseholdSettlementPresentationFormatters {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return make(
            locale: Locale(identifier: "en_US_POSIX"),
            calendar: calendar,
            timeZone: calendar.timeZone,
            currencySymbol: "$"
        )
    }

    static func make(
        locale: Locale,
        calendar: Calendar,
        timeZone: TimeZone,
        currencySymbol: String? = nil
    ) -> HouseholdSettlementPresentationFormatters {
        HouseholdSettlementPresentationFormatters(
            monthTitle: { date in
                let formatter = DateFormatter()
                formatter.locale = locale
                formatter.calendar = calendar
                formatter.timeZone = timeZone
                formatter.setLocalizedDateFormatFromTemplate("MMMM yyyy")
                return formatter.string(from: date)
            },
            currency: { amount, code in
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .currency
                formatter.currencyCode = code
                if let currencySymbol {
                    formatter.currencySymbol = currencySymbol
                    formatter.positiveFormat = "¤#,##0.00"
                    formatter.negativeFormat = "-¤#,##0.00"
                }
                formatter.usesGroupingSeparator = true
                formatter.minimumFractionDigits = 2
                formatter.maximumFractionDigits = 2
                return formatter.string(from: amount as NSDecimalNumber) ?? "$0.00"
            },
            percent: { share in
                let formatter = NumberFormatter()
                formatter.locale = locale
                formatter.numberStyle = .decimal
                formatter.minimumFractionDigits = 2
                formatter.maximumFractionDigits = 2
                let value = share * Decimal(100)
                return "\(formatter.string(from: value as NSDecimalNumber) ?? "0.00")%"
            }
        )
    }
}

struct HouseholdSettlementValidationState: Equatable {
    var missingUserSalary: Bool
    var missingPartnerIncomeEstimate: Bool
    var zeroTotalHouseholdIncome: Bool
    var invalidCustomSplit: Bool
    var canSave: Bool

    static func make(
        setup: HouseholdSettlementSetup,
        report: HouseholdSettlementReport,
        customSplitIsValid: Bool = true,
        canSave: Bool = true
    ) -> HouseholdSettlementValidationState {
        HouseholdSettlementValidationState(
            missingUserSalary: report.detectedUserSalaryIncome == 0 && !setup.useUserIncomeManualOverride,
            missingPartnerIncomeEstimate: setup.splitMethod == .monthlyDefault
                && report.partnerIncomeEstimate == 0
                && report.userSalaryIncome > 0,
            zeroTotalHouseholdIncome: setup.splitMethod == .monthlyDefault
                && report.userSalaryIncome + report.partnerIncomeEstimate == 0,
            invalidCustomSplit: setup.splitMethod == .customPercent && !customSplitIsValid,
            canSave: canSave
        )
    }
}

struct HouseholdSettlementScreenState {
    let navigationTitle: String
    let reportMonthTitle: String
    let subtitle: String
    let selectedYearMonth: YearMonth
    let monthlySetup: HouseholdMonthlySetupState
    let warning: HouseholdWarningState?
    let summary: HouseholdSettlementSummaryState
    let transactionSections: [HouseholdTransactionSectionState]

    func transactionSection(_ id: HouseholdTransactionSectionState.ID) -> HouseholdTransactionSectionState {
        transactionSections.first { $0.id == id }!
    }
}

struct HouseholdMonthlySetupState {
    let title: String
    let rowLabels: [String]
    let userSalaryLabel: String
    let userSalaryValue: String
    let userSalaryHelper: String
    let manualSalaryLabel: String
    let manualSalaryHelper: String
    let partnerIncomeLabel: String
    let partnerIncomeHelper: String
    let splitLabel: String
    let splitValue: String
    let customSplitLabel: String
    let customSplitError: String?
    let notesLabel: String
    let copyPreviousTitle: String
    let clearTitle: String
    let setupStatusText: String
    let showsManualSalaryOverrideButton: Bool
    let showsManualSalaryInput: Bool
}

struct HouseholdWarningState {
    let title: String
    let messages: [String]
}

struct HouseholdSettlementSummaryState {
    struct Line: Identifiable {
        enum ID: String {
            case totalPaidByUser = "household.summary.totalPaidByUser"
            case sharedExpenses = "household.summary.sharedExpenses"
            case partnerSharedPortion = "household.summary.ferSharedPortion"
            case partnerOnlyPaidByUser = "household.summary.ferOnlyPaidByYou"
            case userFinalCost = "household.summary.yourFinalCost"
            case userSalary
            case partnerIncome
            case split
        }

        let id: ID
        let label: String
        let value: String
    }

    let resultLabel: String
    let recoverAmount: String
    let resultDescription: String
    let breakdownTitle: String
    let breakdownLines: [Line]
}

struct HouseholdTransactionSectionState: Identifiable {
    enum ID: String {
        case partnerOnly = "household.ferOnly.section"
        case shared = "household.shared.section"
        case userOnly = "household.userOnly.section"
    }

    let id: ID
    let title: String
    let countText: String
    let subtotal: String
    let initiallyExpanded: Bool
    let rows: [HouseholdTransactionRowState]
}

struct HouseholdTransactionRowState: Identifiable {
    let row: HouseholdSettlementRow
    let amount: String
    let metadata: String
    let status: String

    var id: UUID { row.id }
}

struct HouseholdSettlementPresenter {
    static let navigationTitle = "Household Settlement"

    let formatters: HouseholdSettlementPresentationFormatters

    init(formatters: HouseholdSettlementPresentationFormatters = .live) {
        self.formatters = formatters
    }

    func state(
        selectedMonth: YearMonth,
        setup: HouseholdSettlementSetup,
        report: HouseholdSettlementReport,
        validation: HouseholdSettlementValidationState,
        saveStatus: String
    ) -> HouseholdSettlementScreenState {
        let monthTitle = formatters.monthTitle(selectedMonth.startDate)
        let splitText = splitLabel(report)
        return HouseholdSettlementScreenState(
            navigationTitle: Self.navigationTitle,
            reportMonthTitle: monthTitle,
            subtitle: "Review Household expenses you explicitly included — Mine, Shared, and Fer.",
            selectedYearMonth: selectedMonth,
            monthlySetup: monthlySetup(
                setup: setup,
                report: report,
                validation: validation,
                saveStatus: saveStatus,
                splitText: splitText
            ),
            warning: warning(report: report, validation: validation),
            summary: summary(report: report, splitText: splitText),
            transactionSections: transactionSections(report: report)
        )
    }

    private func monthlySetup(
        setup: HouseholdSettlementSetup,
        report: HouseholdSettlementReport,
        validation: HouseholdSettlementValidationState,
        saveStatus: String,
        splitText: String
    ) -> HouseholdMonthlySetupState {
        let rows = [
            "Your salary income",
            setup.useUserIncomeManualOverride ? "Manual salary override" : nil,
            "Fer income estimate",
            "Split",
            setup.splitMethod == .customPercent ? "Custom split" : nil,
            "Notes"
        ].compactMap { $0 }
        return HouseholdMonthlySetupState(
            title: "Monthly Setup",
            rowLabels: rows,
            userSalaryLabel: "Your salary income",
            userSalaryValue: formatters.currency(report.detectedUserSalaryIncome, "MXN"),
            userSalaryHelper: validation.missingUserSalary
                ? "No salary income detected for this month."
                : "Detected from salary/compensation transactions only.",
            manualSalaryLabel: "Manual salary override",
            manualSalaryHelper: "Used only for this settlement report.",
            partnerIncomeLabel: "Fer income estimate",
            partnerIncomeHelper: "Manual monthly estimate. Used only for this report.",
            splitLabel: "Split",
            splitValue: splitText,
            customSplitLabel: "Custom split",
            customSplitError: validation.invalidCustomSplit ? "Custom split must add to 100%." : nil,
            notesLabel: "Notes",
            copyPreviousTitle: "Copy Previous Month",
            clearTitle: "Clear",
            setupStatusText: validation.canSave ? saveStatus : "Fix setup to save",
            showsManualSalaryOverrideButton: validation.missingUserSalary,
            showsManualSalaryInput: setup.useUserIncomeManualOverride
        )
    }

    private func summary(report: HouseholdSettlementReport, splitText: String) -> HouseholdSettlementSummaryState {
        let count = report.includedTransactionCount
        let resultDescription = count == 0
            ? "Based only on transactions included in Household Settlement."
            : "Based only on \(count) transaction\(count == 1 ? "" : "s") included in Household Settlement."
        return HouseholdSettlementSummaryState(
            resultLabel: "To recover from Fer",
            recoverAmount: formatters.currency(report.amountToRecoverFromPartner, "MXN"),
            resultDescription: resultDescription,
            breakdownTitle: "Breakdown",
            breakdownLines: [
                .init(id: .totalPaidByUser, label: "Total household expenses paid by you", value: formatters.currency(report.totalPaidByUser, "MXN")),
                .init(id: .sharedExpenses, label: "Shared household expenses", value: formatters.currency(report.totalSharedExpenses, "MXN")),
                .init(id: .partnerSharedPortion, label: "Fer shared portion", value: formatters.currency(report.partnerFairShare, "MXN")),
                .init(id: .partnerOnlyPaidByUser, label: "Fer-only paid by you", value: formatters.currency(report.partnerOnlyTotal, "MXN")),
                .init(id: .userFinalCost, label: "Your final household cost", value: formatters.currency(report.userFinalCost, "MXN")),
                .init(id: .userSalary, label: "Your salary income", value: formatters.currency(report.userSalaryIncome, "MXN")),
                .init(id: .partnerIncome, label: "Fer income estimate", value: formatters.currency(report.partnerIncomeEstimate, "MXN")),
                .init(id: .split, label: "Split", value: splitText),
            ]
        )
    }

    private func warning(
        report: HouseholdSettlementReport,
        validation: HouseholdSettlementValidationState
    ) -> HouseholdWarningState? {
        var messages: [String] = []
        if validation.missingUserSalary {
            messages.append("No salary income detected for this month. Add a salary transaction or use a manual override to calculate a proportional split.")
        }
        if validation.zeroTotalHouseholdIncome {
            messages.append("Income assumptions are incomplete. Add your salary income or Fer's estimate to calculate the proportional split.")
        } else {
            if validation.missingUserSalary, report.partnerIncomeEstimate > 0 {
                messages.append("Your salary income is missing. Use a manual override, 50/50, or custom split before assigning Fer 100%.")
            }
            if validation.missingPartnerIncomeEstimate {
                messages.append("Fer income estimate is missing. Proportional split assigns 100% to you.")
            }
        }
        if validation.invalidCustomSplit {
            messages.append("Custom split must total 100%.")
        }

        let uniqueMessages = Array(Set(messages)).sorted()
        guard !uniqueMessages.isEmpty else { return nil }
        return HouseholdWarningState(
            title: "Income assumptions need attention",
            messages: uniqueMessages
        )
    }

    private func transactionSections(report: HouseholdSettlementReport) -> [HouseholdTransactionSectionState] {
        [
            HouseholdTransactionSectionState(
                id: .partnerOnly,
                title: "Fer-only expenses",
                countText: countText(report.ferRows.count),
                subtotal: subtotal(report.ferRows),
                initiallyExpanded: false,
                rows: rowStates(report.ferRows, report: report)
            ),
            HouseholdTransactionSectionState(
                id: .shared,
                title: "Shared expenses",
                countText: countText(report.sharedRows.count),
                subtotal: subtotal(report.sharedRows),
                initiallyExpanded: false,
                rows: rowStates(report.sharedRows, report: report)
            ),
            HouseholdTransactionSectionState(
                id: .userOnly,
                title: "Your household expenses",
                countText: countText(report.userRows.count),
                subtotal: subtotal(report.userRows),
                initiallyExpanded: false,
                rows: rowStates(report.userRows, report: report)
            ),
        ]
    }

    private func countText(_ count: Int) -> String {
        "\(count) transaction\(count == 1 ? "" : "s")"
    }

    private func subtotal(_ rows: [HouseholdSettlementRow]) -> String {
        let total = rows.reduce(Decimal.zero) { $0 + $1.amount }
        return formatters.currency(total, rows.first?.transaction.currency ?? "MXN")
    }

    private func rowStates(
        _ rows: [HouseholdSettlementRow],
        report: HouseholdSettlementReport
    ) -> [HouseholdTransactionRowState] {
        rows.map { row in
            let transaction = row.transaction
            let currency = transaction.currency
            let allocation = transaction.resolvedHouseholdAllocation
            var metadata = [
                transaction.account?.displayName ?? "No account",
                transaction.category?.name ?? "Uncategorized",
            ]
            let status: String
            switch allocation {
            case .user:
                metadata.append("User")
                status = "Your cost: \(formatters.currency(row.userShare, currency))"
            case .shared:
                metadata.append(contentsOf: ["Shared", report.splitMethod.displayName])
                status = "Fer \(formatters.currency(row.partnerShare, currency)) / You \(formatters.currency(row.userShare, currency))"
            case .partner:
                metadata.append("Fer")
                status = "Recoverable: 100%"
            case .custom:
                let userPercent = row.amount == 0 ? Decimal.zero : row.userShare / row.amount
                let ferPercent = row.amount == 0 ? Decimal.zero : row.partnerShare / row.amount
                metadata.append(contentsOf: [
                    "Shared",
                    "Custom split",
                    "You \(formatters.percent(userPercent)) / Fer \(formatters.percent(ferPercent))",
                ])
                status = "Fer \(formatters.currency(row.partnerShare, currency)) / You \(formatters.currency(row.userShare, currency))"
            }
            if let notes = transaction.settlementNotes, !notes.isEmpty {
                metadata.append(notes)
            }
            return HouseholdTransactionRowState(
                row: row,
                amount: formatters.currency(row.amount, currency),
                metadata: metadata.joined(separator: " · "),
                status: status
            )
        }
    }

    private func splitLabel(_ report: HouseholdSettlementReport) -> String {
        guard report.splitAvailable else { return "Unavailable" }
        return "You \(formatters.percent(report.userIncomeShare)) / Fer \(formatters.percent(report.partnerIncomeShare))"
    }
}
