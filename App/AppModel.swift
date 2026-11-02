import Foundation
import Observation
import AppKit
import JBLKit
import JBLBluetooth

/// One complete snapshot stream feeds every window, menu and notification.
/// Views submit commands; only DeviceSession changes confirmed device values.
@MainActor @Observable
final class AppModel {
    private(set) var devices: [PairedDevice] = []
    private(set) var status: BluetoothStatus = .notDetermined
    private(set) var refreshing = false
    private(set) var testing = false
    private(set) var snapshot = DeviceSnapshot()
    private(set) var reports: [ValidationReport] = []
    private(set) var liveDiagnostics: DiagnosticSnapshot?
    var selectedReportID: UUID?
    var message = "Choose an already-paired Tour Pro 3 in Settings."
    let preferences = Preferences()
    let presets = EQPresetStore()
    let notifications = BatteryNotifications()
    let developerTools = ProcessInfo.processInfo.arguments.contains("--developer-tools")
    let uiTestPresentation = UITestPresentation.requested
    var selectedID: String {
        didSet {
            guard oldValue != selectedID else { return }
            UserDefaults.standard.set(selectedID, forKey: "selectedDevice")
            controlRevision &+= 1
            revokePermit()
            explicitlyReleased = false
            notifications.resetForDevice()
            let requestedID = selectedID
            let revision = controlRevision
            Task { [weak self] in
                guard let self else { return }
                await self.pauseControls()
                guard self.controlRevision == revision, self.selectedID == requestedID else { return }
                await self.deviceSession.selectDevice(self.selected?.reference)
                await self.replaceClassicObserver()
                await self.updateDiscovery(restart: .interfaceOpened)
            }
        }
    }
    private let permission = BluetoothPermission()
    private let deviceSession = DeviceSession()
    private let runner = ValidationRunner()
    private var discovery: DiscoveryCoordinator?
    private var classicObserver: ClassicConnectionObserver?
    private var observedReference: DeviceReference?
    private var observationEpoch: UInt64 = 0
    private var classicTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var controlSession: GuardedSession?
    private var activePermit: AcquisitionPermit?
    private var generation: UInt64 = 0
    private var storeTask: Task<Void, Never>?
    private var diagnosticTask: Task<Void, Never>?
    private var idleTask: Task<Void, Never>?
    private var visibleControls: Set<String> = []
    private var awake = true
    private var wakeNotBefore: ContinuousClock.Instant?
    private var controlDemand = false
    /// Last explicit cancellation wins across MainActor suspension points.
    private var controlRevision: UInt64 = 0
    private var explicitlyReleased = false
    private var launchCompleted = false
    private var loginInteractionRequired = false
    private var observers: [NSObjectProtocol] = []

    init() {
        selectedID = UserDefaults.standard.string(forKey: "selectedDevice") ?? ""
        if let uiTestPresentation {
            launchCompleted = true
            snapshot = uiTestPresentation.snapshot
            message = "Synthetic UI fixture: \(uiTestPresentation.rawValue). Bluetooth and device commands are disabled."
            return
        }
        discovery = DiscoveryCoordinator(session: deviceSession) { [weak self] reference, permit in
            guard let self else { throw LinkError.disconnected }
            return try await self.makeCoordinatedSession(for: reference, permit: permit)
        }
        statusTask = Task { [weak self, permission] in
            for await status in permission.updates {
                guard let self, !Task.isCancelled else { return }
                let previous = self.status
                self.status = status
                if status != .poweredOn {
                    self.controlRevision &+= 1
                    self.revokePermit()
                    await self.pauseControls()
                } else if previous != .poweredOn, self.isVisible {
                    await self.inspectPairedDevices()
                    await self.updateDiscovery(restart: .poweredOn)
                }
            }
        }
        Task { await notifications.refreshAuthorization() }
        storeTask = Task { [weak self, deviceSession] in
            do {
                let stream = try await deviceSession.attachStore()
                for await replacement in stream {
                    guard let self, !Task.isCancelled else { return }
                    self.snapshot = replacement
                    if !self.testing {
                        switch replacement.phase {
                        case .telemetryReady: self.message = "Captured telemetry available. Required controls await verification."
                        case .controlsUnavailable: self.message = "Controls unavailable. Explicit Retry is available while the earbuds remain connected."
                        default: break
                        }
                    }
                    self.notifications.consume(
                        [("Agent earbud", replacement.batteryAgentStale ? .unknown : replacement.batteryAgent),
                         ("Partner earbud", replacement.batteryPartnerStale ? .unknown : replacement.batteryPartner),
                         ("Case", replacement.caseBatteryStale ? .unknown : replacement.caseBattery)],
                        active: replacement.phase == .ready || replacement.phase == .telemetryReady,
                        threshold: self.preferences.lowBatteryThreshold
                    )
                }
            } catch { self?.message = "The device state store could not be attached." }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.awake = false
                self.controlRevision &+= 1
                self.revokePermit()
                await self.pauseControls()
                await self.deviceSession.setAwake(false)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.wakeNotBefore = ContinuousClock.now.advanced(by: .seconds(2))
                self.awake = true
                self.controlDemand = self.isVisible
                await self.deviceSession.setAwake(true)
                if self.isVisible {
                    await self.inspectPairedDevices()
                    await self.updateDiscovery(restart: .wake)
                }
            }
        })
    }

    var selected: PairedDevice? { devices.first { $0.id == selectedID } }
    var selectedReport: ValidationReport? { reports.first { $0.id == selectedReportID } ?? reports.last }
    var isVisible: Bool { !visibleControls.isEmpty }
    var isBusy: Bool {
        testing || refreshing || snapshot.isRefreshing || snapshot.phase == .connecting || snapshot.workflow != nil
    }
    var redactor: Redactor {
        Redactor(secrets: devices.flatMap { [$0.id, $0.reference.name] } + [Host.current().localizedName ?? ""])
    }
    var phaseDescription: String {
        switch snapshot.phase {
        case .idle: "Choose a device"
        case .connecting: "Acquiring controls"
        case .telemetryReady: "Telemetry available · controls await verification"
        case .ready: "Ready"
        case .controlsUnavailable: "Controls unavailable"
        case .released: "Controls released"
        case .sleeping: "Mac asleep"
        }
    }

    func completeLaunch(atLogin: Bool) {
        guard !launchCompleted else { return }
        launchCompleted = true
        loginInteractionRequired = atLogin
        if atLogin {
            controlDemand = false
            NSApp.windows.filter { $0.title == "OpenJBL" }.forEach { $0.close() }
            return
        }
        if isVisible {
            controlDemand = true
            Task { [weak self] in
                guard let self else { return }
                await self.deviceSession.setVisibility(true)
                await self.inspectPairedDevices()
                await self.updateDiscovery(restart: .interfaceOpened)
            }
        }
    }

    func availability(_ feature: FeatureKey) -> FeatureAvailability {
        snapshot.capabilities[feature] ?? .unknown
    }
    func unavailableReason(_ feature: FeatureKey) -> String {
        if let workflow = snapshot.workflow { return "Busy with \(workflow). Stop that workflow first." }
        switch availability(feature) {
        case .supported: return snapshot.phase == .ready ? "" : "Acquire controls while the earbuds are connected."
        case .readOnly: return "Device state is available for reading only."
        case .temporarilyUnavailable: return "Temporarily unavailable. Refresh when both earbuds are connected."
        case .unsupported: return "This model does not support this feature."
        case .unknown: return "Awaiting official-app capture and hardware verification."
        case .indeterminate: return "Verification failed repeatedly. Explicit Retry is required."
        }
    }
    func canChange(_ feature: FeatureKey) -> Bool {
        availability(feature) == .supported && snapshot.phase == .ready && !isBusy
    }

    func setVisible(_ visible: Bool, source: String) {
        if visible {
            guard visibleControls.insert(source).inserted else { return }
        } else { visibleControls.remove(source) }
        guard uiTestPresentation == nil else { return }
        guard launchCompleted else { return }
        if visible && source == "menu" { loginInteractionRequired = false }
        if loginInteractionRequired {
            if source == "window" {
                NSApp.windows.filter { $0.title == "OpenJBL" }.forEach { $0.close() }
            }
            return
        }
        idleTask?.cancel()
        let anyVisible = isVisible
        Task { await deviceSession.setVisibility(anyVisible) }
        if anyVisible {
            controlDemand = true
            // Closing one surface while another stays open is not a restart
            // trigger and must not replenish the connection retry budget.
            guard visible else { return }
            Task { [weak self] in
                guard let self else { return }
                await self.inspectPairedDevices()
                await self.updateDiscovery(restart: .interfaceOpened)
            }
            return
        }
        idleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            guard let self, !self.isVisible, !self.testing else { return }
            self.controlDemand = false
            await self.pauseControls()
        }
    }

    func inspectPairedDevices(startObserver: Bool = true) async {
        guard uiTestPresentation == nil else { return }
        guard !refreshing, !testing else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            status = try await permission.requestStatus()
            guard status == .poweredOn else {
                revokePermit()
                await pauseControls()
                devices = []
                message = status == .unauthorized ? "Allow OpenJBL in Privacy & Security → Bluetooth." :
                    "Turn on Bluetooth in macOS to inspect paired devices."
                return
            }
            devices = try await ClassicDeviceMonitor.pairedDevices()
            await deviceSession.selectDevice(selected?.reference)
            if startObserver { await replaceClassicObserver() }
            message = devices.isEmpty ? "Pair your Tour Pro 3 in macOS, then refresh." :
                "Paired devices refreshed. Select your device in Settings."
        } catch {
            message = "Bluetooth inspection did not finish. Try again."
        }
    }

    /// Explicit Retry clears sticky Release Controls. Healthy links refresh in place.
    func refreshControls() async {
        guard uiTestPresentation == nil else { return }
        guard !isBusy else { return }
        let revision = controlRevision
        loginInteractionRequired = false
        await inspectPairedDevices()
        guard revision == controlRevision else { return }
        guard let selected, selected.reference.name == ModelCatalog.tourPro3.name,
              selected.classicConnected, status == .poweredOn, awake, isVisible else {
            message = "Select an already-paired Tour Pro 3 connected in macOS, then Retry."
            return
        }
        refreshing = true
        defer { refreshing = false }
        explicitlyReleased = false
        controlDemand = true
        guard selectedID == selected.id, awake, status == .poweredOn else { return }
        await deviceSession.retry()
        guard revision == controlRevision else { return }
        if snapshot.phase == .ready || snapshot.phase == .telemetryReady {
            await deviceSession.refresh()
            guard revision == controlRevision else { return }
            message = "Captured telemetry refreshed. Unverified controls remain unavailable."
        } else {
            message = "Acquiring captured telemetry…"
            await updateDiscovery(restart: .retry)
        }
    }

    func setMode(_ mode: TourPro3Sound.ListeningMode) async {
        guard uiTestPresentation == nil else { return }
        guard canChange(.listeningMode) else { return }
        do {
            let outcome = try await deviceSession.set(.listeningMode(mode))
            message = "Listening mode: \(outcome)"
        } catch { message = "Listening mode: \(redactor.text(String(describing: error)))" }
    }

    func set(_ feature: FeatureKey, value: DeviceValue) async {
        guard uiTestPresentation == nil else { return }
        guard canChange(feature) else { return }
        do {
            let outcome = try await deviceSession.set(.setting(feature: feature, value: value))
            message = "\(feature.rawValue): \(outcome)"
        } catch { message = "\(feature.rawValue): \(redactor.text(String(describing: error)))" }
    }

    func releaseControls() async {
        guard uiTestPresentation == nil else { return }
        controlRevision &+= 1
        explicitlyReleased = true
        await pauseControls()
        message = "Controls released. Press Refresh to acquire again. Audio connections are managed by macOS."
    }

    private func pauseControls() async {
        revokePermit()
        diagnosticTask?.cancel()
        diagnosticTask = nil
        let retiring = controlSession
        let retiringPermit = activePermit
        controlSession = nil
        await discovery?.update(acquisitionContext(controlNeeded: false))
        await retiring?.stop()
        if activePermit === retiringPermit { activePermit = nil }
    }

    private func revokePermit() {
        activePermit?.update(AcquisitionContext(selectedAndPaired: false, classicConnected: false,
                                               controlNeeded: false, released: true))
    }
    private func makeSession(for device: PairedDevice) -> GuardedSession {
        generation &+= 1
        let permit = AcquisitionPermit(AcquisitionContext(
            selectedAndPaired: true, classicConnected: device.classicConnected,
            controlNeeded: true, awake: awake, permitted: status == .poweredOn))
        activePermit = permit
        return GuardedSession(link: RFCOMMLink(selected: device.reference, generation: generation, permit: permit),
                              permit: permit,
                              context: PolicyContext(allowExperimentalChanges: preferences.allowExperimentalChanges),
                              recordDiagnostics: preferences.recordDiagnostics)
    }

    private func makeCoordinatedSession(for reference: DeviceReference, permit: AcquisitionPermit) throws -> GuardedSession {
        guard launchCompleted, !loginInteractionRequired, !testing, !explicitlyReleased, awake, controlDemand, status == .poweredOn,
              wakeNotBefore.map({ ContinuousClock.now >= $0 }) ?? true,
              selected?.reference == reference, selected?.classicConnected == true,
              observedReference == reference, classicObserver != nil,
              permit.allowsAcquisition else { throw PolicyError.connectionGuard }
        generation &+= 1
        activePermit = permit
        let candidate = GuardedSession(
            link: RFCOMMLink(selected: reference, generation: generation, permit: permit), permit: permit,
            context: PolicyContext(allowExperimentalChanges: preferences.allowExperimentalChanges),
            recordDiagnostics: preferences.recordDiagnostics)
        controlSession = candidate
        startDiagnosticUpdates(for: candidate)
        return candidate
    }

    private func acquisitionContext(controlNeeded: Bool? = nil) -> AcquisitionContext {
        AcquisitionContext(
            selectedAndPaired: selected?.reference.name == ModelCatalog.tourPro3.name &&
                observedReference == selected?.reference && classicObserver != nil,
            classicConnected: selected?.classicConnected == true,
            controlNeeded: controlNeeded ?? (launchCompleted && !loginInteractionRequired && controlDemand && !testing),
            awake: awake, permitted: status == .poweredOn, released: explicitlyReleased)
    }
    private func updateDiscovery(restart: ControlRestartTrigger? = nil) async {
        guard uiTestPresentation == nil else { return }
        await discovery?.update(acquisitionContext(), restart: restart)
    }

    private func replaceClassicObserver() async {
        let reference = selected?.reference
        guard observedReference != reference || (reference != nil && classicObserver == nil) else { return }
        observationEpoch &+= 1
        let epoch = observationEpoch
        classicTask?.cancel()
        classicTask = nil
        let previous = classicObserver
        classicObserver = nil
        observedReference = nil
        await previous?.stop()
        guard epoch == observationEpoch, let reference, selected?.reference == reference else { return }
        let observer = ClassicConnectionObserver(selected: reference)
        do { try await observer.ready() }
        catch {
            await observer.stop()
            message = "Classic connection notifications are unavailable. Press Refresh to retry."
            return
        }
        guard epoch == observationEpoch, selected?.reference == reference else {
            await observer.stop()
            return
        }
        classicObserver = observer
        observedReference = reference
        classicTask = Task { [weak self] in
            do {
                for try await event in observer.events {
                    guard let self, !Task.isCancelled, self.observationEpoch == epoch,
                          self.selectedID == reference.id else { return }
                    let wasConnected = self.selected?.classicConnected == true
                    if let device = event.device {
                        if let index = self.devices.firstIndex(where: { $0.id == device.id }) { self.devices[index] = device }
                        else { self.devices.append(device) }
                    } else { self.devices.removeAll { $0.id == reference.id } }
                    if event.device?.classicConnected != true {
                        self.controlRevision &+= 1
                        self.revokePermit()
                        await self.controlSession?.stop()
                    }
                    await self.updateDiscovery(
                        restart: event.device?.classicConnected == true && !wasConnected ? .classicConnected : nil)
                }
            } catch {
                guard let self, !Task.isCancelled, self.observationEpoch == epoch else { return }
                // Overflow/failed subscription invalidates the entire observer.
                // Re-inspect once without silently restarting a failing observer.
                self.revokePermit()
                self.controlRevision &+= 1
                self.classicObserver = nil
                self.observedReference = nil
                await self.pauseControls()
                await self.inspectPairedDevices(startObserver: false)
                self.message = "Classic connection monitoring stopped. Controls were released; press Refresh to retry."
            }
        }
    }

    func runSuite(_ suite: ValidationSuiteID, prerequisitesConfirmed: Bool) async {
        guard uiTestPresentation == nil else { return }
        guard developerTools, !testing, !refreshing else { return }
        guard let selected, selected.reference.name == ModelCatalog.tourPro3.name,
              selected.classicConnected, status == .poweredOn, awake else {
            message = "Refresh paired devices and connect the selected Tour Pro 3 in macOS first."
            return
        }
        testing = true
        let revision = controlRevision
        defer {
            diagnosticTask?.cancel()
            diagnosticTask = nil
            testing = false
            if !isVisible { setVisible(false, source: "suite") }
        }
        await pauseControls()
        guard revision == controlRevision, selectedID == selected.id, awake, status == .poweredOn else { return }
        let candidate = makeSession(for: selected)
        controlSession = candidate
        liveDiagnostics = nil
        startDiagnosticUpdates(for: candidate)
        message = "Running \(suite.title)…"
        do {
            let report = try await runner.run(suite, session: candidate, build: BuildIdentity.current(),
                                              prerequisitesConfirmed: prerequisitesConfirmed)
            reports.append(report)
            if reports.count > 20 { reports.removeFirst(reports.count - 20) }
            selectedReportID = report.id
            liveDiagnostics = report.diagnostics
            if revision == controlRevision {
                message = report.passed ? "Suite protocol checks passed. Record your observation separately." :
                    "Suite stopped or failed. Its diagnostic report is retained."
            } else {
                message = "Controls were interrupted or released. The suite's protocol report is retained."
            }
        } catch {
            message = "Suite did not run: \(redactor.text(String(describing: error)))"
        }
        revokePermit()
        await candidate.stop()
        controlSession = nil
        activePermit = nil
    }

    func recordObservation(_ observation: ValidationObservation) {
        guard let id = selectedReport?.id, let index = reports.firstIndex(where: { $0.id == id }) else { return }
        do { try reports[index].recordObservation(observation) }
        catch { message = "An observation has already been recorded for this run." }
    }

    func setDiagnosticRecording(_ enabled: Bool) async {
        preferences.recordDiagnostics = enabled
        await controlSession?.setDiagnosticRecording(enabled)
        diagnosticTask?.cancel()
        diagnosticTask = nil
        if enabled, let controlSession { startDiagnosticUpdates(for: controlSession) }
        else { liveDiagnostics = nil }
    }

    private func startDiagnosticUpdates(for session: GuardedSession) {
        diagnosticTask?.cancel()
        guard preferences.recordDiagnostics else { return }
        diagnosticTask = Task { [weak self] in
            while !Task.isCancelled {
                let replacement = await session.diagnosticSnapshot()
                guard !Task.isCancelled else { return }
                self?.liveDiagnostics = replacement
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            }
        }
    }

    func copyDiagnostics() {
        let text = selectedReport?.text(redactor: redactor) ?? "OpenJBL\nNo validation run recorded."
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(redactor.text(text), forType: .string)
    }

    func exportDiagnostics(json: Bool = true) {
        guard let report = selectedReport else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "openjbl-\(report.suite.rawValue)-\(report.id.uuidString.prefix(8)).\(json ? "json" : "txt")"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try json ? report.json(redactor: redactor) : Data(report.text(redactor: redactor).utf8)
            try data.write(to: url, options: .atomic)
        } catch { message = "Could not save the redacted validation report." }
    }
}
