import SwiftUI

@main
struct OHScreenApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
        }
        .defaultSize(width: 1040, height: 740)
        .windowResizability(.contentMinSize)
    }
}
