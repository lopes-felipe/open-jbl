import SwiftUI
import Charts
import JBLKit

struct EqualizerView: View {
    @Bindable var model: AppModel
    @State private var selectedPreset: UUID?
    @State private var name = ""
    @State private var gains = Array(repeating: 0.0, count: 10)
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            GroupBox("Device equalizer") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(model.unavailableReason(.equalizer))
                    Text("Device presets, EQ on/off and curve transfer require captured operations. The device gain range is not yet established.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(8).frame(maxWidth: .infinity, alignment: .leading)
            }
            GroupBox("Local curve library") {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Edit and save curves on this Mac. Local edits are not sent to the earbuds.")
                        .foregroundStyle(.secondary)
                    Picker("Preset", selection: $selectedPreset) {
                        Text("New local curve").tag(Optional<UUID>.none)
                        ForEach(model.presets.presets) { preset in Text(preset.name).tag(Optional(preset.id)) }
                    }
                    .onChange(of: selectedPreset) { _, id in
                        if let preset = model.presets.presets.first(where: { $0.id == id }) {
                            name = preset.name; gains = preset.gains
                        } else { name = ""; gains = Array(repeating: 0, count: 10) }
                    }
                    Chart(Array(EQPresetStore.frequencies.enumerated()).filter {
                        gains[$0.offset].isFinite && (-24...24).contains(gains[$0.offset])
                    }, id: \.offset) { band in
                        LineMark(x: .value("Frequency (Hz)", band.element), y: .value("Gain (dB)", gains[band.offset]))
                        PointMark(x: .value("Frequency (Hz)", band.element), y: .value("Gain (dB)", gains[band.offset]))
                    }
                    .chartXScale(type: .log).chartYScale(domain: -24...24)
                    .chartXAxisLabel("Frequency (Hz)").chartYAxisLabel("Local gain (dB)")
                    .frame(height: 180)
                    .accessibilityLabel("Local ten-band equalizer curve")
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: 12) {
                        ForEach(0..<10) { index in
                            VStack(spacing: 5) {
                                Text(frequencyLabel(EQPresetStore.frequencies[index])).font(.caption)
                                TextField("Gain", value: $gains[index], format: .number)
                                    .textFieldStyle(.roundedBorder)
                                    .accessibilityLabel("\(frequencyLabel(EQPresetStore.frequencies[index])) gain in decibels")
                            }
                        }
                    }
                    Text("The local file accepts −24…+24 dB. This is a storage limit, not a verified device range.")
                        .font(.caption).foregroundStyle(.secondary)
                    TextField("Local preset name", text: $name).textFieldStyle(.roundedBorder)
                    HStack {
                        Button("Save Local Preset") {
                            let replacing = selectedPreset
                            if model.presets.save(name: name, gains: gains, replacing: selectedPreset) {
                                selectedPreset = replacing ?? model.presets.presets.last?.id
                            }
                        }
                        .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                  !gains.allSatisfy { $0.isFinite && (-24...24).contains($0) })
                        Button("New") { selectedPreset = nil; name = ""; gains = Array(repeating: 0, count: 10) }
                        if let id = selectedPreset {
                            Button("Delete Local Preset", role: .destructive) {
                                model.presets.remove(id); selectedPreset = nil
                            }
                        }
                    }
                    if let error = model.presets.error { Text(error).foregroundStyle(.red).font(.caption) }
                }.padding(8)
            }
        }
    }
    private func frequencyLabel(_ value: Double) -> String {
        value >= 1_000 ? "\(Int(value / 1_000)) kHz" : "\(Int(value)) Hz"
    }
}
