import SwiftUI

@main
struct OHScreenApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 980, height: 720)
        .windowResizability(.contentMinSize)
    }
}
