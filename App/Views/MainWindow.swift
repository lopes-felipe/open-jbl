import SwiftUI
import AppKit
import JBLKit

private enum AppSection: String, CaseIterable, Identifiable {
    case overview = "Overview", sound = "Sound Control", equalizer = "Equalizer"
    case spatial = "Spatial Sound", touch = "Touch Controls", calls = "Calls & Voice"
    case chargingCase = "Charging Case", settings = "Device Settings"
    case sources = "Connected Devices", maintenance = "Maintenance", diagnostics = "Diagnostics"
    var id: String { rawValue }
    var features: [FeatureKey] {
        switch self {
        case .sound: [.listeningMode, .ambientLevel, .smartTalk, .silentNow, .lowVolumeEQ]
        case .equalizer: [.equalizer, .customEQ]
        case .spatial: [.spatial, .headTracking]
        case .touch: [.gestures]
        case .calls: [.voicePrompts]
        case .chargingCase: [.caseSettings, .caseTime]
        case .settings: [.autoOff, .autoPlayPause, .hiRes, .personiFi, .findMyBuds]
        case .sources: [.sources]
        default: []
        }
    }
    var symbol: String {
        switch self {
        case .overview: "earbuds"
        case .sound: "waveform"
        case .equalizer: "slider.vertical.3"
        case .spatial: "spatialaudio"
        case .touch: "hand.tap"
        case .calls: "phone"
        case .chargingCase: "battery.100percent"
        case .settings: "gearshape"
        case .sources: "desktopcomputer"
        case .maintenance: "wrench.and.screwdriver"
        case .diagnostics: "waveform.path.ecg"
        }
    }
}

struct MainWindow: View {
    @Bindable var model: AppModel
    @State private var selection: AppSection? = .overview
    @State private var menuPreview = false
    private var sections: [AppSection] {
        AppSection.allCases.filter { $0.features.isEmpty || $0.features.contains { model.availability($0) != .unsupported } }
    }
    var body: some View {
        NavigationSplitView {
            List(sections, selection: $selection) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .accessibilityIdentifier("section-sidebar")
            .navigationTitle("OpenJBL")
            .navigationSplitViewColumnWidth(min: 190, ideal: 210)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    permissionBanner
                    Text((selection ?? .overview).rawValue).font(.largeTitle.bold())
                    if model.uiTestPresentation != nil {
                        Text("Synthetic UI fixture — no hardware access").font(.caption).foregroundStyle(.orange)
                        ListeningModeControl(model: model)
                        Button("Show Menu Preview") { menuPreview = true }.accessibilityIdentifier("show-menu-preview")
                    }
                    switch selection {
                    case .overview, nil: overview
                    case .sound:
                        ListeningModeControl(model: model)
                        featureToggle("Smart Talk", feature: .smartTalk)
                        featureToggle("Silent Now", feature: .silentNow)
                        featureToggle("Low-volume EQ", feature: .lowVolumeEQ)
                        unavailable("ANC and Ambient levels", feature: .ambientLevel)
                    case .equalizer: EqualizerView(model: model)
                    case .spatial:
                        featureToggle("Spatial sound", feature: .spatial)
                        featureToggle("Head tracking", feature: .headTracking)
                        Text("Device spatial settings do not enable host spatial audio or an unavailable macOS recentering API.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .touch:
                        unavailable("Left and right earbud gestures", feature: .gestures)
                        Text("Gesture changes require captured NV write, successful acknowledgement and bounded reload.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .calls:
                        featureToggle("Voice prompts", feature: .voicePrompts)
                        Text("VoiceAware has not been mapped. Call processing controls await capture.")
                            .foregroundStyle(.secondary)
                    case .chargingCase:
                        unavailable("Brightness, screen timeout, tap to wake and clock format", feature: .caseSettings)
                        unavailable("Synchronize case time", feature: .caseTime)
                    case .settings:
                        featureToggle("Auto play/pause", feature: .autoPlayPause)
                        featureToggle("Hi-Res preference", feature: .hiRes)
                        featureToggle("Personi-Fi", feature: .personiFi)
                        unavailable("Auto power-off", feature: .autoOff)
                        unavailable("Find My Buds — start and stop", feature: .findMyBuds)
                        Text("A device-side Hi-Res preference does not mean macOS sends LDAC. Existing Personi-Fi profiles are preserved; profile generation is outside v1.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .sources:
                        unavailable("Connected sources", feature: .sources)
                        Text("Sources are read-only. Multipoint management, unpairing and Auracast are outside v1.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .maintenance: maintenance
                    case .diagnostics: DiagnosticsView(model: model)
                    }
                }
                .padding(28).frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(.background)
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                if model.isBusy { ProgressView().controlSize(.small) }
                else { Image(systemName: "info.circle") }
                Text(model.message).font(.callout).textSelection(.enabled)
                    .accessibilityIdentifier("session-message")
                Spacer()
            }.padding(12).background(.bar)
        }
        .toolbar {
            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.refreshControls() } }
                .disabled(model.isBusy).accessibilityIdentifier("refresh-controls")
            Button("Release Controls") { Task { await model.releaseControls() } }
            SettingsLink { Label("Settings", systemImage: "gearshape") }
        }
        .onAppear { model.setVisible(true, source: "window") }
        .onDisappear { model.setVisible(false, source: "window") }
        .sheet(isPresented: $menuPreview) {
            VStack {
                MenuPanel(model: model)
                Button("Close Menu Preview") { menuPreview = false }
            }.padding()
        }
    }

    @ViewBuilder private var permissionBanner: some View {
        if model.status == .unauthorized {
            GroupBox {
                HStack {
                    Label("Bluetooth access is denied.", systemImage: "lock.shield")
                    Spacer()
                    Button("Open Privacy Settings") { openBluetoothSettings(privacy: true) }
                }
            }
        } else if model.status == .poweredOff {
            GroupBox {
                HStack {
                    Label("Bluetooth is turned off.", systemImage: "antenna.radiowaves.left.and.right.slash")
                    Spacer()
                    Button("Bluetooth Settings") { openBluetoothSettings() }
                }
            }
        }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 20) {
                Image(systemName: "earbuds").font(.system(size: 64, weight: .light)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.snapshot.selectedDevice?.name ?? model.selected?.reference.name ?? "Choose your Tour Pro 3").font(.title2.bold())
                    Text(model.phaseDescription).foregroundStyle(.secondary)
                    Text("Capture-gated development build").font(.callout)
                }
            }
            GroupBox("Battery") {
                HStack {
                    BatteryView(title: "Agent", reading: model.snapshot.batteryAgent, stale: model.snapshot.batteryAgentStale)
                    Divider()
                    BatteryView(title: "Partner", reading: model.snapshot.batteryPartner, stale: model.snapshot.batteryPartnerStale)
                    Divider()
                    BatteryView(title: "Case", reading: model.snapshot.caseBattery, stale: model.snapshot.caseBatteryStale, caseReading: true)
                }.padding(12).frame(minHeight: 75)
            }
            Text("Agent/partner roles can switch. Left/right mapping and charging state are not yet verified.")
                .font(.caption).foregroundStyle(.secondary)
            GroupBox("Connection") {
                Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 10) {
                    GridRow { Text("Classic connection"); Text(model.selected?.classicConnected == true ? "Connected at last inspection" : "Not observed") }
                    GridRow { Text("Audio route"); Text("Managed by macOS; not monitored") }
                    GridRow {
                        Text("Control transport")
                        Text(model.snapshot.phase == .ready || model.snapshot.phase == .telemetryReady ? "RFCOMM active" : "Released or unavailable")
                    }
                    GridRow {
                        Text("Cached Airoha SPP")
                        Text(model.selected?.cachedControlChannel.map { "RFCOMM channel \($0)" } ?? "Not found in cached SDP")
                    }
                    GridRow { Text("Identity"); Text("Paired address/name fallback; PID layout remains unmapped") }
                    GridRow { Text("Earbud firmware"); Text(model.snapshot.earbudFirmware ?? "Unknown") }
                    GridRow { Text("Case firmware"); Text(model.snapshot.caseFirmware ?? "Unknown") }
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            }
            if model.snapshot.phase != .ready && model.snapshot.phase != .telemetryReady {
                Text("Device values are cached while controls are released. Refresh to obtain current readings.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Inspect Paired Devices") { Task { await model.inspectPairedDevices() } }.disabled(model.isBusy)
                Button("Connect in macOS") { openBluetoothSettings() }
            }
            Text("OpenJBL works offline without an account or analytics. Closing this window leaves the menu bar app running; hidden controls are released after 30 seconds.")
                .foregroundStyle(.secondary)
        }
    }
    private var maintenance: some View {
        VStack(alignment: .leading, spacing: 14) {
            LabeledContent("Earbuds", value: model.snapshot.earbudFirmware ?? "Unknown")
            LabeledContent("Charging case", value: model.snapshot.caseFirmware ?? "Unknown")
            Link("JBL product support and official updates", destination: URL(string: "https://support.jbl.com/")!)
            Text("Firmware installation is outside v1. Use the official app.")
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func unavailable(_ title: String, feature: FeatureKey) -> some View {
        if model.availability(feature) != .unsupported {
            GroupBox(title) {
                Text(model.unavailableReason(feature)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(8)
            }
        }
    }
    @ViewBuilder private func featureToggle(_ title: String, feature: FeatureKey) -> some View {
        if model.availability(feature) != .unsupported {
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle(title, isOn: Binding(
                        get: {
                            let value = model.snapshot.intents[feature]?.value ?? model.snapshot.confirmed[feature]?.value
                            if case .bool(let enabled) = value { return enabled }
                            return false
                        },
                        set: { value in Task { await model.set(feature, value: .bool(value)) } }
                    ))
                    .disabled(!model.canChange(feature))
                    if !model.canChange(feature) {
                        Text(model.unavailableReason(feature)).font(.caption).foregroundStyle(.secondary)
                    }
                    FeatureValueStatus(model: model, feature: feature)
                }.padding(8)
            }
        }
    }
}

struct BatteryView: View {
    let title: String
    let reading: BatteryReading
    var stale = false
    var caseReading = false
    var body: some View {
        VStack(spacing: 5) {
            Text(title).font(.headline)
            switch reading {
            case .level(let percent, let charging, let date):
                HStack(spacing: 4) {
                    Text("\(percent)%").monospacedDigit()
                    if charging && !caseReading && !stale { Image(systemName: "bolt.fill").accessibilityLabel("Charging") }
                }
                if stale || caseReading {
                    Text("Last reported \(date, style: .relative) ago").font(.caption2).foregroundStyle(.secondary)
                }
            case .inCase: Text("In case")
            case .notConnected: Text("Not connected")
            case .unknown: Text("Unknown").foregroundStyle(.secondary)
            }
            if stale {
                switch reading {
                case .inCase, .notConnected:
                    Text("Last reported · stale").font(.caption2).foregroundStyle(.secondary)
                default: EmptyView()
                }
            }
        }.frame(maxWidth: .infinity).accessibilityElement(children: .combine)
    }
}

struct ListeningModeControl: View {
    @Bindable var model: AppModel
    var body: some View {
        GroupBox("Listening mode") {
            VStack(alignment: .leading, spacing: 10) {
                Picker("Listening mode", selection: Binding(
                    get: {
                        let value = model.snapshot.intents[.listeningMode]?.value ?? model.snapshot.confirmed[.listeningMode]?.value
                        if case .mode(let mode) = value { return mode.rawValue }
                        return UInt8(0)
                    },
                    set: { raw in
                        if let mode = TourPro3Sound.ListeningMode(rawValue: raw) { Task { await model.setMode(mode) } }
                    }
                )) {
                    Text("Unknown").tag(UInt8(0))
                    Text("ANC").tag(TourPro3Sound.ListeningMode.anc.rawValue)
                    Text("Ambient").tag(TourPro3Sound.ListeningMode.ambient.rawValue)
                }
                .pickerStyle(.segmented).disabled(!model.canChange(.listeningMode))
                .accessibilityIdentifier("listening-mode")
                if model.snapshot.intents[.listeningMode] != nil {
                    FeatureValueStatus(model: model, feature: .listeningMode)
                } else {
                    Text("Confirmed: \(deviceValueDescription(model.snapshot.confirmed[.listeningMode]?.value))\(model.snapshot.confirmed[.listeningMode]?.isStale == true ? " · stale" : "")")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !model.canChange(.listeningMode) {
                    Text(model.unavailableReason(.listeningMode)).font(.caption).foregroundStyle(.secondary)
                }
                Text("TalkThru and Off require captured operations before they can be offered.")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(8)
        }
    }
}

private struct FeatureValueStatus: View {
    let model: AppModel
    let feature: FeatureKey
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let confirmed = model.snapshot.confirmed[feature] {
                Text("Confirmed: \(deviceValueDescription(confirmed.value))\(confirmed.isStale ? " · stale" : "")")
                    .foregroundStyle(.secondary)
            } else { Text("Confirmed: Unknown").foregroundStyle(.secondary) }
            if let intent = model.snapshot.intents[feature] {
                if intent.status == .unconfirmed {
                    Label("May not have applied: \(deviceValueDescription(intent.value))", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                } else {
                    Label("Pending: \(deviceValueDescription(intent.value))", systemImage: "clock")
                }
            }
            if let error = model.snapshot.errors[feature] {
                Text("Device result: \(String(describing: error))").foregroundStyle(.red)
            }
        }.font(.caption)
    }
}

private func deviceValueDescription(_ value: DeviceValue?) -> String {
    switch value {
    case .mode(let mode): mode == .anc ? "ANC" : "Ambient"
    case .bool(let enabled): enabled ? "On" : "Off"
    case .integer(let number): String(number)
    case .text(let text): text
    case nil: "Unknown"
    }
}

func openBluetoothSettings(privacy: Bool = false) {
    let pane = privacy ? "com.apple.preference.security?Privacy_Bluetooth" : "com.apple.BluetoothSettings"
    if let url = URL(string: "x-apple.systempreferences:\(pane)") { NSWorkspace.shared.open(url) }
}
