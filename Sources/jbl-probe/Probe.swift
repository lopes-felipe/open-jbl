import Foundation
import ArgumentParser
import JBLKit
import JBLBluetooth

@main
struct Probe: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "jbl-probe",
        abstract: "Capture-gated OpenJBL research tools. No pairing, paging or raw writes.",
        subcommands: [List.self, Read.self, Write.self, Validate.self, Decode.self]
    )
}

struct List: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "List reviewed operation names (offline by default).")
    @Flag(help: "Also inspect already-paired devices. Does not open a connection.")
    var devices = false
    mutating func run() async throws {
        let names = OperationCatalog.production.names
        print(names.isEmpty ? "No captured operations enabled. M1 is pending." : names.joined(separator: "\n"))
        if devices {
            try await requireBluetoothPermission()
            let paired = try await ClassicDeviceMonitor.pairedDevices()
            for device in paired {
                print("\(device.reference.name): Classic \(device.classicConnected ? "connected" : "disconnected")")
            }
            if paired.isEmpty {
                print("No supported paired devices are visible to this process. Check Bluetooth privacy access and the exact device name.")
            }
        }
    }
}

struct Read: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Read one reviewed spec from an existing Classic connection.")
    @Argument var spec: String
    @Option(help: "Exact address of the selected, already-paired device.") var device: String
    mutating func run() async throws {
        try await runOperation(spec, args: .none, device: device, write: false, confirmation: nil)
    }
}

struct Write: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Submit a reviewed write after a y/N prompt.")
    @Argument var spec: String
    @Argument(help: "Typed value: true, false, or an integer; omit for a no-argument spec.") var value: String?
    @Option(help: "Exact address of the selected, already-paired device.") var device: String
    mutating func run() async throws {
        guard OperationCatalog.production[spec] != nil else {
            throw ValidationError("No captured, enabled operation named '\(spec)'.")
        }
        let args: OpArgs
        if value == nil { args = .none }
        else if value == "true" || value == "false" { args = .bool(value == "true") }
        else if let value, let integer = Int(value) { args = .int(integer) }
        else { throw ValidationError("Expected true, false or an integer.") }
        print("Apply \(spec) to the selected device? [y/N] ", terminator: "")
        guard readLine()?.lowercased() == "y" else { throw CancellationError() }
        try await runOperation(spec, args: args, device: device, write: true,
                               confirmation: ConfirmationToken(userConfirmed: spec))
    }
}

private func runOperation(_ name: String, args: OpArgs, device: String, write: Bool,
                          confirmation: ConfirmationToken?) async throws {
    guard let spec = OperationCatalog.production[name] else {
        throw ValidationError("No captured operation '\(name)'. Capture review is required before hardware traffic.")
    }
    if !write {
        guard case .read = spec.kind else { throw ValidationError("The read command accepts read specs only.") }
    } else {
        switch spec.kind {
        case .write, .action: break
        default: throw ValidationError("The write command accepts write/action specs only.")
        }
    }
    try await requireBluetoothPermission()
    guard let selected = try await ClassicDeviceMonitor.pairedDevices().first(where: { $0.id == device }),
          selected.classicConnected else { throw ValidationError("Selected paired device has no Classic ACL. Connect in macOS first.") }
    guard selected.reference.name == ModelCatalog.tourPro3.name else {
        throw ValidationError("These captured reads apply only to the exact paired JBL Tour Pro 3 model.")
    }
    let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
    let link = RFCOMMLink(selected: selected.reference, generation: 1, permit: permit)
    let session = GuardedSession(link: link, permit: permit, context: PolicyContext())
    do {
        try await session.start()
        if write { _ = try await session.perform(OperationRequest("earbud-firmware")) }
        let result = try await session.perform(OperationRequest(name, args: args, confirmation: confirmation))
        if case .response(let frames) = result { frames.forEach { print(Redactor().frame($0)) } }
        if case .confirmedMode(let mode, let changed) = result {
            print("\(mode == .anc ? "ANC" : "Ambient"): confirmed by device readback; changed=\(changed)")
        }
        await session.stop()
    } catch { await session.stop(); throw error }
}

private func requireBluetoothPermission() async throws {
    let permission = BluetoothPermission()
    let status = try await permission.requestStatus()
    switch status {
    case .poweredOn: return
    case .unauthorized:
        throw ValidationError("Bluetooth access is denied. Allow the probe or its launching app in System Settings → Privacy & Security → Bluetooth.")
    case .poweredOff:
        throw ValidationError("Bluetooth is powered off. Turn it on in macOS first.")
    case .notDetermined, .unavailable:
        throw ValidationError("Bluetooth adapter state is unavailable to this process. No device connection was attempted.")
    }
}

struct Validate: AsyncParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Run a finite captured suite; 'list' is offline.")
    @Argument(help: "list, telemetry, ambient, or anc.") var suite: String
    @Option(help: "Exact selected paired address; required for hardware suites.") var device: String?
    @Flag(help: "Opt into at most 2,000 payload-free diagnostic events.") var recordDiagnostics = false
    @Option(help: "Save a redacted JSON report to a new file (never overwrite).") var output: String?

    mutating func run() async throws {
        if suite == "list" {
            for id in ValidationSuiteID.allCases {
                print("\(id.rawValue): \(id.operations.joined(separator: ", "))")
                print("  " + id.preconditions.joined(separator: "; "))
                print("  Automatic restoration: none")
            }
            return
        }
        guard let id = ValidationSuiteID(rawValue: suite), let device else {
            throw ValidationError("Choose a named suite and pass --device. Use 'validate list' offline.")
        }
        let outputURL = output.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        if let outputURL {
            guard (try? FileManager.default.attributesOfItem(atPath: outputURL.path)) == nil,
                  FileManager.default.isWritableFile(atPath: outputURL.deletingLastPathComponent().path) else {
                throw ValidationError("Report output must be a new file in a writable directory.")
            }
        }
        if id.changesSettings {
            print(id.preconditions.joined(separator: "\n"))
            print("Run \(id.title)? No automatic restoration. [y/N] ", terminator: "")
            guard readLine()?.lowercased() == "y" else { throw CancellationError() }
        }
        try await requireBluetoothPermission()
        guard let selected = try await ClassicDeviceMonitor.pairedDevices().first(where: { $0.id == device }),
              selected.reference.name == ModelCatalog.tourPro3.name, selected.classicConnected else {
            throw ValidationError("Select an already-paired Tour Pro 3 with its Classic connection up.")
        }
        let permit = AcquisitionPermit(AcquisitionContext(selectedAndPaired: true, classicConnected: true, controlNeeded: true))
        let link = RFCOMMLink(selected: selected.reference, generation: 1, permit: permit)
        let session = GuardedSession(link: link, permit: permit, context: PolicyContext(),
                                     recordDiagnostics: recordDiagnostics)
        var report = try await ValidationRunner().run(id, session: session, build: BuildIdentity.current(),
                                                      prerequisitesConfirmed: id.changesSettings)
        let redactor = Redactor(secrets: [device, selected.reference.name, Host.current().localizedName ?? ""])
        if id.changesSettings {
            print("Suite \(report.passed ? "passed protocol checks" : "failed or incomplete"). Observation is recorded separately.")
            print("Audible result (y=expected mode, n=no change, u=uncertain; Enter=not observed): ", terminator: "")
            let answer = readLine()?.lowercased()
            let observation: ValidationObservation = answer == "y" ? .audibleAsExpected :
                (answer == "n" ? .noAudibleChange : (answer == "u" ? .uncertain : .notObserved))
            try report.recordObservation(observation)
        }
        print(report.text(redactor: redactor))
        if let outputURL {
            try report.json(redactor: redactor).write(to: outputURL, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: outputURL.path)
            print("Redacted report saved.")
        }
        if !report.passed { throw ExitCode.failure }
    }
}

struct Decode: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Decode an extract-race TSV offline. Payloads are redacted.")
    @Argument var tsv: String
    func run() throws {
        let url = URL(fileURLWithPath: tsv)
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 64 * 1024 * 1024 else { throw ValidationError("Split captures larger than 64 MiB first.") }
        let records = try CaptureDecoder.decode(String(contentsOf: url, encoding: .utf8))
        for record in records {
            print("\(record.timestamp)\t\(record.direction)\t\(record.source)\t\(Redactor().frame(record.frame))")
        }
        print("\(records.count) RACE frames. No data transmitted.")
    }
}
