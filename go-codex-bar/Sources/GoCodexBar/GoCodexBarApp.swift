import SwiftUI

@main
struct GoCodexBarApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("Go Codex Bar", systemImage: self.model.menuBarIcon) {
            ContentView()
                .environmentObject(self.model)
        }
        .menuBarExtraStyle(.window)
    }
}
