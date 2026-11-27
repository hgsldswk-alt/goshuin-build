import SwiftUI

@main
@MainActor
struct GoshuinApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var purchases = Purchases()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(purchases)
                .preferredColorScheme(.light)
                .task { await model.start() }
                .task { await purchases.start() }
        }
    }
}
