import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var loginEnabled = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    var body: some View {
        @Bindable var preferences = model.preferences
        TabView {
            Form {
                Picker("Selected device", selection: $model.selectedID) {
                    Text("Choose an already-paired device").tag("")
                    ForEach(model.devices) { device in
                        Text("\(device.reference.name) — \(device.classicConnected ? "connected" : "disconnected")").tag(device.id)
                    }
                }
                .disabled(model.isBusy)
                Button("Request Bluetooth Access / Inspect Paired Devices") { Task { await model.inspectPairedDevices() } }
                    .disabled(model.isBusy)
                if model.status == .unauthorized {
                    Button("Open Bluetooth Privacy Settings") { openBluetoothSettings(privacy: true) }
                } else if model.status == .poweredOff {
                    Button("Turn on Bluetooth in macOS") { openBluetoothSettings() }
                }
                Toggle("Launch at login", isOn: $loginEnabled)
                    .onChange(of: loginEnabled) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                            loginError = nil
                        } catch {
                            loginError = "macOS could not change the login item."
                            loginEnabled = SMAppService.mainApp.status == .enabled
                        }
                    }
                if let loginError { Text(loginError).foregroundStyle(.red) }
                Toggle("Show battery percentage in the menu bar", isOn: $preferences.menuBarPercentage)
                Text("Login launch does not acquire controls. Opening the menu or window may acquire captured telemetry only while the selected device is already connected. Release Controls stays in effect until explicit Refresh. Intel builds are untested.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .formStyle(.grouped).tabItem { Label("General", systemImage: "gearshape") }
            Form {
                Stepper("Low-battery threshold: \(preferences.lowBatteryThreshold == 0 ? "Off" : "\(preferences.lowBatteryThreshold)%")",
                        value: $preferences.lowBatteryThreshold, in: 0...50, step: 1)
                Button("Enable Low-Battery Notifications…") { Task { await model.notifications.requestPermission() } }
                Text(model.notifications.permissionDescription).font(.caption).foregroundStyle(.secondary)
                Text("Default threshold: 15%. Zero disables alerts. Alerts re-arm five points above the threshold and use fresh readings only while controls are active. Continuous background monitoring is not provided.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Allow changes on experimental models", isOn: $preferences.allowExperimentalChanges)
                Text("Experimental models still require reviewed operations and evidence. AA and P4 remain post-v1.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Record diagnostic metadata for this app session", isOn: Binding(
                    get: { preferences.recordDiagnostics },
                    set: { enabled in Task { await model.setDiagnosticRecording(enabled) } }
                ))
            }
            .formStyle(.grouped).tabItem { Label("Notifications & Safety", systemImage: "bell.badge") }
            VStack(spacing: 16) {
                Image(systemName: "earbuds").font(.system(size: 48))
                Text("OpenJBL").font(.title)
                Text("Independent, open-source interoperability research.")
                Text("Not affiliated with, endorsed by, or sponsored by JBL or Harman. JBL is a trademark of its respective owner.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("MIT • Capture-gated development build • Intel untested").font(.caption)
                Text("Full parity has not been achieved. See the published feature inventory and release gates.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(28).tabItem { Label("About", systemImage: "info.circle") }
        }
    }
}
