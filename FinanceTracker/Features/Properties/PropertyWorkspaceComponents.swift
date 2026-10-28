import AppKit
import SwiftUI

struct HouseholdSetupDraft: Equatable {
    var partnerIncome: Decimal
    var useManualSalary: Bool
    var manualSalary: Decimal
    var splitMethod: HouseholdSplitMethod
    var userPercent: Decimal
    var partnerPercent: Decimal
    var notes: String
}

struct PropertyFormSection<Content: View>: View {
    var title: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                if let title { PropertySectionHeading(title: title).padding(.horizontal, 14).padding(.top, 14) }
                content()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Ends interaction signposts at the first AppKit draw, rather than at the end of a calculation.
struct PropertyWorkspaceRenderProbe: NSViewRepresentable {
    var workspace: PropertyWorkspaceModel
    var destination: PropertyDestination
    var section: PropertyWorkspaceSection
    var month: Date

    func makeNSView(context: Context) -> ProbeView { ProbeView() }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.workspace = workspace
        view.needsDisplay = true
    }

    final class ProbeView: NSView {
        weak var workspace: PropertyWorkspaceModel?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func draw(_ dirtyRect: NSRect) { workspace?.didDraw() }
        override func accessibilityIsIgnored() -> Bool { true }
    }
}

struct PropertyMetricValue: Identifiable {
    var title: String
    var amount: Decimal
    var note: String
    var id: String { title }
}

struct PropertyPersonValue: Identifiable {
    var id: String
    var name: String
    var detail: String
    var amount: Decimal?
    var amountLabel: String
}

struct PropertyFactValue: Identifiable {
    var title: String
    var value: String
    var id: String { title }
}

struct PropertySummaryPresentation {
    var metrics: [PropertyMetricValue]
    var people: [PropertyPersonValue]
    var composition: [PropertyFactValue]
    var status: [PropertyFactValue]
    var warnings: [String]
}

/// Both sources feed the same view values; calculators and persisted records stay intact.
@MainActor
enum PropertyPresentationAdapter {
    static func household(_ report: HouseholdSettlementReport) -> PropertySummaryPresentation {
        PropertySummaryPresentation(metrics: [
            .init(title: "Registered expenses", amount: report.totalPaidByUser, note: "Paid by you this month"),
            .init(title: "Your final cost", amount: report.userFinalCost, note: "After Fer's contribution"),
            .init(title: "Fer's contribution", amount: report.amountToRecoverFromPartner, note: "Shared and individual"),
            .init(title: "To recover", amount: report.amountToRecoverFromPartner, note: "Fer's obligation this month"),
        ], people: [
            .init(id: "user", name: String(localized: "You"), detail: String(format: String(localized: "You paid %@ this month"), propertyMoneyText(report.totalPaidByUser)),
                  amount: report.userFinalCost, amountLabel: "Final cost"),
            .init(id: "partner", name: "Fer", detail: report.splitAvailable ? report.splitLabel : "Review this month's income",
                  amount: report.blockedReason == nil ? report.amountToRecoverFromPartner : nil, amountLabel: "To contribute"),
        ], composition: [
            .init(title: "Shared expenses", value: propertyMoneyText(report.totalSharedExpenses)),
            .init(title: "Fer's individual expenses", value: propertyMoneyText(report.partnerOnlyTotal)),
            .init(title: "Your individual expenses", value: propertyMoneyText(report.userOnlyTotal)),
            .init(title: "For upcoming months", value: propertyMoneyText(report.pendingForUpcomingMonths)),
        ], status: [
            .init(title: "Distribution", value: report.splitLabel),
            .init(title: "Your income for the split", value: propertyMoneyText(report.userSalaryIncome)),
            .init(title: "Fer's reference income", value: propertyMoneyText(report.partnerIncomeEstimate)),
        ], warnings: report.warnings.map { String(localized: String.LocalizationValue($0)) })
    }

    static func property(_ report: PropertyMonthlyReport) -> PropertySummaryPresentation {
        let pending = report.residents.reduce(Decimal.zero) { $0 + max(0, $1.balance) }
        return PropertySummaryPresentation(metrics: [
            .init(title: "Rent generated", amount: report.rent, note: "Obligation of the month"),
            .init(title: "Actual expenses", amount: report.expenses, note: "Attributed transactions"),
            .init(title: "Collected", amount: report.collected, note: "Applied to obligations"),
            .init(title: "To collect", amount: pending, note: "Rent, expenses and adjustments"),
        ], people: report.residents.map {
            .init(id: $0.id.uuidString, name: $0.name,
                  detail: $0.confirmed ? "Income confirmed" : "Estimated reference",
                  amount: $0.balance, amountLabel: $0.balance < 0 ? "Credit balance" : "To contribute")
        }, composition: [
            .init(title: "Rent for the month", value: propertyMoneyText(report.rent)),
            .init(title: "Operating expenses", value: propertyMoneyText(report.operatingExpenses)),
            .init(title: "Maintenance", value: propertyMoneyText(report.maintenanceExpenses)),
            .init(title: "Prior debt", value: propertyMoneyText(report.priorBalance)),
        ], status: [
            .init(title: "Collected operating result", value: propertyMoneyText(report.operatingResult)),
            .init(title: "After maintenance", value: propertyMoneyText(report.afterMaintenanceResult)),
            .init(title: "Advances available", value: propertyMoneyText(report.advanceAvailable)),
        ], warnings: report.warnings)
    }
}

struct PropertyMetricGrid: View {
    var values: [PropertyMetricValue]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 24) {
                ForEach(values) { value in metric(value).frame(minWidth: 130, maxWidth: .infinity, alignment: .leading) }
            }
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      alignment: .leading, spacing: 20) {
                ForEach(values) { value in metric(value) }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func metric(_ value: PropertyMetricValue) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 7) {
                Text(LocalizedStringKey(value.title)).font(.caption).foregroundStyle(.secondary)
                Text(propertyMoneyText(value.amount))
                    .font(.title.weight(.semibold)).monospacedDigit()
                    .fixedSize(horizontal: true, vertical: false)
                Text(LocalizedStringKey(value.note)).font(.caption).foregroundStyle(.secondary)
            }
            .padding(DashboardCardTokens.compactPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
        }
    }
}

struct PropertySectionHeading: View {
    var title: String
    var actionTitle: String?
    var action: (() -> Void)?
    var trailing: (any View)? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(title)).font(.headline)
            Spacer(minLength: 12)
            if let actionTitle, let action {
                Button(LocalizedStringKey(actionTitle), action: action).buttonStyle(.link).font(.caption)
            }
            if let trailing {
                AnyView(trailing)
            }
        }
    }
}

struct PropertyPeopleList: View {
    var people: [PropertyPersonValue]

    var body: some View {
        GlassCard {
            VStack(spacing: 0) {
                if people.isEmpty {
                    Text("Add members to calculate their contributions.")
                        .font(.callout).foregroundStyle(.secondary).padding(16)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                ForEach(people) { person in
                    HStack(spacing: 12) {
                        Text(String(person.name.prefix(1))).font(.caption).foregroundStyle(.secondary)
                            .frame(width: 30, height: 30).background(.quaternary.opacity(0.35), in: Circle())
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(person.name).font(.callout.weight(.medium))
                            Text(LocalizedStringKey(person.detail)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 12)
                        VStack(alignment: .trailing, spacing: 3) {
                            if let amount = person.amount {
                                Text(propertyMoneyText(amount))
                                    .font(.callout.weight(.medium)).monospacedDigit()
                            } else {
                                Text("Pending calculation")
                                    .font(.callout.weight(.medium)).monospacedDigit()
                            }
                            Text(LocalizedStringKey(person.amountLabel)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(14).accessibilityElement(children: .combine)
                    if person.id != people.last?.id { Divider().padding(.horizontal, 14) }
                }
            }
        }
    }
}

struct PropertyFacts: View {
    var title: String
    var values: [PropertyFactValue]
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PropertySectionHeading(title: title, actionTitle: actionTitle, action: action)
            PropertyTableCard {
                VStack(spacing: 12) {
                    ForEach(values) { value in
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Text(LocalizedStringKey(value.title)).foregroundStyle(.secondary)
                            Spacer(minLength: 8)
                            Text(value.value).monospacedDigit().multilineTextAlignment(.trailing)
                        }
                        .font(.callout).accessibilityElement(children: .combine)
                        if value.id != values.last?.id { Divider() }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

struct PropertySummaryPanel: View {
    var presentation: PropertySummaryPresentation
    var onOpenSettlement: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 26) {
            PropertyMetricGrid(values: presentation.metrics)
            VStack(alignment: .leading, spacing: 12) {
                PropertySectionHeading(title: "Contributions this month", actionTitle: "View detail", action: onOpenSettlement)
                PropertyPeopleList(people: presentation.people)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 28) {
                    PropertyFacts(title: "Month composition", values: presentation.composition).frame(minWidth: 240)
                    PropertyFacts(title: "Period status", values: presentation.status).frame(minWidth: 240)
                }
                VStack(alignment: .leading, spacing: 24) {
                    PropertyFacts(title: "Month composition", values: presentation.composition)
                    PropertyFacts(title: "Period status", values: presentation.status)
                }
            }
            ForEach(presentation.warnings, id: \.self) { warning in
                Label(warning, systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            HStack {
                Label("The calculation uses this period's transactions", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("View settlement", action: onOpenSettlement).buttonStyle(.link).font(.caption)
            }
        }
    }
}

/// Table/list content only. Section headings stay on the exterior content margin.
struct PropertyTableCard<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        GlassCard {
            content().padding(DashboardCardTokens.compactPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
