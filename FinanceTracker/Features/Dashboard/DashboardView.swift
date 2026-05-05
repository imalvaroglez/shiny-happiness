import SwiftUI
import SwiftData

struct DashboardView: View {
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        NavigationSplitView {
            List {
                NavigationLink("Dashboard", destination: Text("Dashboard"))
                NavigationLink("Transactions", destination: Text("Transactions"))
                NavigationLink("Import Statements", destination: ImportView(modelContext: modelContext))
                NavigationLink("Settings", destination: Text("Settings"))
            }
            .navigationTitle("FinanceTracker")
            .listStyle(.sidebar)
        } detail: {
            Text("Select a section")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .task {
            SeedDataLoader.bootstrapIfNeeded(context: modelContext)
        }
    }
}

#Preview {
    DashboardView()
}
