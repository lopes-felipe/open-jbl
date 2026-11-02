import Foundation
import Observation
import UserNotifications
import JBLKit

/// Notifications consume the same snapshot as the views. No background polling
/// or control connection is started for notifications.
@MainActor @Observable
final class BatteryNotifications {
    private(set) var permissionDescription = "Notifications are off until you enable them."
    private var armed: [String: Bool] = [:]
    private var lastThreshold: Int?
    private var enabled = false

    func refreshAuthorization() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        enabled = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        if enabled { permissionDescription = "Low-battery notifications are enabled." }
    }

    func requestPermission() async {
        do {
            enabled = try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
            permissionDescription = enabled ? "Low-battery notifications are enabled." :
                "Allow notifications for OpenJBL in macOS Settings."
        } catch {
            permissionDescription = "macOS could not enable notifications."
        }
    }

    func consume(_ readings: [(String, BatteryReading)], active: Bool, threshold: Int) {
        guard enabled, active, threshold > 0 else { return }
        if lastThreshold != threshold { armed.removeAll(); lastThreshold = threshold }
        for (component, reading) in readings {
            guard case .level(let percent, _, let observedAt) = reading,
                  (0..<120).contains(Date().timeIntervalSince(observedAt)) else { continue }
            if percent >= threshold + 5 { armed[component] = true }
            guard percent <= threshold, armed[component, default: true] else { continue }
            armed[component] = false
            let content = UNMutableNotificationContent()
            content.title = "OpenJBL battery"
            content.body = "\(component): \(percent)% remaining."
            content.sound = .default
            let request = UNNotificationRequest(identifier: "battery-\(component)", content: content, trigger: nil)
            UNUserNotificationCenter.current().add(request)
        }
    }

    func resetForDevice() { armed.removeAll() }
}
