import SwiftUI
import JBLKit

struct DiagnosticsView: View {
    @Bindable var model: AppModel
    @State private var requestedSuite: ValidationSuiteID?
    @State private var prerequisitesConfirmed = false
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Toggle("Record diagnostic frame metadata for this app session", isOn: Binding(
                get: { model.preferences.recordDiagnostics },
                set: { enabled in Task { await model.setDiagnosticRecording(enabled) } }
            ))
            Text("Opt-in memory ring: at most 2,000 entries, displayed at most four times per second. Raw payloads, addresses and personalization data are withheld.")
                .font(.caption).foregroundStyle(.secondary)
            if model.developerTools {
                GroupBox("Named validation suites") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            ForEach(ValidationSuiteID.allCases, id: \.self) { suite in
                                Button(suite.title) {
                                    prerequisitesConfirmed = false
                                    requestedSuite = suite
                                }
                            }
                        }.disabled(model.isBusy || model.selected == nil)
                        Text("Each suite uses the production catalog and guarded transport, then releases control. Settings suites stop on a mismatch; none restores or retries a write automatically.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(8)
                }
            } else {
                Text("Named hardware suites are available only when launched with --developer-tools.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.reports.isEmpty {
                Picker("Retained run", selection: $model.selectedReportID) {
                    ForEach(model.reports.reversed()) { report in
                        Text("\(report.startedAt.formatted(date: .omitted, time: .standard)) · \(report.suite.title) · \(report.passed ? "passed" : "incomplete/failed")")
                            .tag(Optional(report.id))
                    }
                }
                Text("The latest 20 runs stay in memory, including failures. Export reports before quitting.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let report = model.selectedReport {
                Text(report.text(redactor: model.redactor))
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    .accessibilityIdentifier("validation-report")
                HStack {
                    Button("Copy Diagnostics") { model.copyDiagnostics() }
                    Button("Export JSON…") { model.exportDiagnostics() }
                    Button("Export Transcript…") { model.exportDiagnostics(json: false) }
                }
                if report.suite.changesSettings && report.observation == nil {
                    GroupBox("Listening observation") {
                        HStack {
                            Button("Audible as expected") { model.recordObservation(.audibleAsExpected) }
                            Button("No audible change") { model.recordObservation(.noAudibleChange) }
                            Button("Uncertain") { model.recordObservation(.uncertain) }
                        }.padding(8)
                    }
                    Text("Your observation is recorded once and does not replace the device protocol result.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("No validation run recorded", systemImage: "waveform.path.ecg",
                    description: Text("Reports preserve protocol results and listening observations separately."))
            }
            if let diagnostics = model.liveDiagnostics, model.preferences.recordDiagnostics {
                DisclosureGroup("Diagnostic metadata (\(diagnostics.entries.count) entries)") {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(diagnostics.entries, id: \.sequence) { entry in
                            Text(entryText(entry)).font(.system(.caption, design: .monospaced))
                        }
                    }.textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Button("Release Controls / Stop Current Suite") { Task { await model.releaseControls() } }
        }
        .sheet(item: $requestedSuite) { suite in
            VStack(alignment: .leading, spacing: 16) {
                Text(suite.title).font(.title2.bold())
                ForEach(suite.preconditions, id: \.self) { requirement in
                    Label(requirement, systemImage: "checklist")
                }
                if suite.changesSettings {
                    Text("This requests the selected audible mode. The suite does not automatically restore the previous mode.")
                        .foregroundStyle(.secondary)
                }
                Toggle("I confirm these prerequisites", isOn: $prerequisitesConfirmed)
                HStack {
                    Spacer()
                    Button("Cancel") { requestedSuite = nil }.keyboardShortcut(.cancelAction)
                    Button("Run Suite") {
                        requestedSuite = nil
                        Task { await model.runSuite(suite, prerequisitesConfirmed: true) }
                    }
                    .disabled(!prerequisitesConfirmed).keyboardShortcut(.defaultAction)
                }
            }.padding(24).frame(width: 470)
        }
    }
    private func entryText(_ entry: DiagnosticEntry) -> String {
        var result = "+\(entry.elapsedMilliseconds) ms g\(entry.generation) \(entry.operation ?? "session") \(entry.stage.rawValue): \(entry.result.rawValue)"
        if let frame = entry.frame {
            result += String(format: " type=%02X id=%04X <%d bytes>", frame.type, frame.identifier, frame.payloadLength)
        }
        if let rule = entry.rule { result += " \(rule.rawValue)" }
        return result
    }
}

extension ValidationSuiteID: @retroactive Identifiable {
    public var id: String { rawValue }
}
