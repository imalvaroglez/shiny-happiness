import SwiftUI
import SwiftData

@main
struct FinanceTrackerApp: App {
    var body: some Scene {
        WindowGroup {
            ZStack {
                MeshGradient(
                    width: 3, height: 3,
                    points: [
                        [0.0, 0.0], [0.5, 0.0], [1.0, 0.0],
                        [0.0, 0.5], [0.5, 0.5], [1.0, 0.5],
                        [0.0, 1.0], [0.5, 1.0], [1.0, 1.0]
                    ],
                    colors: [
                        .black, Color(red: 0.05, green: 0.05, blue: 0.15), .black,
                        Color(red: 0.05, green: 0.1, blue: 0.05), .black, Color(red: 0.15, green: 0.05, blue: 0.1),
                        .black, Color(red: 0.05, green: 0.05, blue: 0.1), .black
                    ]
                )
                .ignoresSafeArea()
                .opacity(0.6)

                DashboardView()
            }
        }
        .modelContainer(for: [
            Account.self,
            Transaction.self,
            Statement.self,
            Category.self,
            CategoryRule.self,
        ])
    }
}
