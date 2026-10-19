import Combine
import Foundation
import IOKit.pwr_mgt

@MainActor
final class StayAwakeController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var errorMessage: String?

    private var assertionID: IOPMAssertionID?
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.bool(forKey: "stayAwake") {
            self.setEnabled(true)
        }
    }

    deinit {
        if let assertionID {
            IOPMAssertionRelease(assertionID)
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != self.isEnabled else { return }
        self.errorMessage = nil

        let result: IOReturn
        if enabled {
            var newID: IOPMAssertionID = 0
            // Preventing display idle sleep also prevents system idle sleep.
            result = IOPMAssertionCreateWithName(
                kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                IOPMAssertionLevel(kIOPMAssertionLevelOn),
                "Go Codex Bar: Stay Awake" as CFString,
                &newID)
            if result == kIOReturnSuccess {
                self.assertionID = newID
            }
        } else if let assertionID {
            result = IOPMAssertionRelease(assertionID)
            if result == kIOReturnSuccess {
                self.assertionID = nil
            }
        } else {
            return
        }

        guard result == kIOReturnSuccess else {
            self.errorMessage = "Could not \(enabled ? "enable" : "disable") Stay Awake (macOS error \(result))."
            return
        }
        self.isEnabled = enabled
        self.defaults.set(enabled, forKey: "stayAwake")
    }
}
