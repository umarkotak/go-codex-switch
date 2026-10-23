import SwiftUI

@main
struct GoCodexBarApp: App {
    @StateObject private var model = AppModel()
    @StateObject private var stayAwake = StayAwakeController()
    @StateObject private var lidAwake = LidAwakeController()

    var body: some Scene {
        MenuBarExtra("Go Codex Bar", systemImage: self.awakeIcon) {
            ContentView()
                .environmentObject(self.model)
                .environmentObject(self.stayAwake)
                .environmentObject(self.lidAwake)
        }
        .menuBarExtraStyle(.window)
    }

    private var awakeIcon: String {
        if self.lidAwake.isEnabled == true { return "laptopcomputer" }
        return self.stayAwake.isEnabled ? "sun.max.fill" : self.model.menuBarIcon
    }
}
