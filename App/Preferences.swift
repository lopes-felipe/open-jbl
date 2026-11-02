import Foundation
import Observation

@MainActor @Observable
final class Preferences {
    var lowBatteryThreshold: Int {
        didSet { UserDefaults.standard.set(lowBatteryThreshold, forKey: "lowBatteryThreshold") }
    }
    var menuBarPercentage: Bool {
        didSet { UserDefaults.standard.set(menuBarPercentage, forKey: "menuBarPercentage") }
    }
    var allowExperimentalChanges: Bool {
        didSet { UserDefaults.standard.set(allowExperimentalChanges, forKey: "allowExperimentalChanges") }
    }
    var recordDiagnostics = false

    init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: ["lowBatteryThreshold": 15, "menuBarPercentage": true,
                                     "allowExperimentalChanges": false])
        lowBatteryThreshold = min(50, max(0, defaults.integer(forKey: "lowBatteryThreshold")))
        menuBarPercentage = defaults.bool(forKey: "menuBarPercentage")
        allowExperimentalChanges = defaults.bool(forKey: "allowExperimentalChanges")
    }
}
