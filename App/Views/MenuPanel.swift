import SwiftUI
import AppKit
import JBLKit

struct MenuPanel: View {
    @Bindable var model: AppModel
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label(model.snapshot.selectedDevice?.name ?? model.selected?.reference.name ?? "OpenJBL", systemImage: "earbuds").font(.headline)
            HStack {
                Text(model.phaseDescription).font(.caption).foregroundStyle(.secondary)
                Spacer()
                if model.isBusy { ProgressView().controlSize(.small) }
            }
            HStack {
                BatteryView(title: "Agent", reading: model.snapshot.batteryAgent, stale: model.snapshot.batteryAgentStale)
                BatteryView(title: "Partner", reading: model.snapshot.batteryPartner, stale: model.snapshot.batteryPartnerStale)
                BatteryView(title: "Case", reading: model.snapshot.caseBattery, stale: model.snapshot.caseBatteryStale, caseReading: true)
            }.font(.caption)
            Text("Left/right role mapping is unverified.").font(.caption2).foregroundStyle(.secondary)
            if model.availability(.listeningMode) != .unsupported { ListeningModeControl(model: model) }
            if model.availability(.equalizer) != .unsupported {
                Menu("Device EQ Preset") { Text(model.unavailableReason(.equalizer)) }
                    .disabled(true)
            }
            Divider()
            Button("Refresh Controls") { Task { await model.refreshControls() } }.disabled(model.isBusy)
            Button("Open OpenJBL…") {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            SettingsLink { Text("Settings…") }
            Button("Release Controls") { Task { await model.releaseControls() } }
            Divider()
            Button("Quit") {
                Task {
                    await model.releaseControls()
                    NSApp.terminate(nil)
                }
            }.keyboardShortcut("q")
        }
        .padding(18).frame(width: 350)
        .onAppear { model.setVisible(true, source: "menu") }
        .onDisappear { model.setVisible(false, source: "menu") }
    }
}
