import SwiftUI

@main
struct GoCodexBarApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var stayAwake = StayAwakeController()

    var body: some Scene {
        MenuBarExtra("Go Codex Bar", systemImage: self.stayAwake.isEnabled ? "sun.max.fill" : self.model.menuBarIcon) {
            ContentView()
                .environmentObject(self.model)
                .environmentObject(self.stayAwake)
        }
        .menuBarExtraStyle(.window)
    }
}
