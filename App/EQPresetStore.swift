import Foundation
import Observation

struct LocalEQPreset: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var gains: [Double]
}

/// Local curves are independent of a device's unverified wire format and range.
/// Storage never marks a curve applied or transmits it.
@MainActor @Observable
final class EQPresetStore {
    static let frequencies: [Double] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    private struct Document: Codable {
        let version: Int
        var presets: [LocalEQPreset]
    }
    private(set) var presets: [LocalEQPreset] = []
    private(set) var error: String?
    private var canSave = true
    private let url: URL

    init() {
        url = URL.applicationSupportDirectory.appending(path: "OpenJBL/eq-presets.json")
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let bytes = try Data(contentsOf: url)
            guard bytes.count <= 1_048_576 else { throw CocoaError(.fileReadCorruptFile) }
            let document = try JSONDecoder().decode(Document.self, from: bytes)
            guard document.version == 1, document.presets.count <= 128,
                  Set(document.presets.map(\.id)).count == document.presets.count,
                  document.presets.allSatisfy(Self.valid) else { throw CocoaError(.fileReadCorruptFile) }
            presets = document.presets
        } catch {
            self.error = "The local preset file could not be read. It has been preserved."
            canSave = false
        }
    }

    @discardableResult
    func save(name: String, gains: [Double], replacing id: UUID? = nil) -> Bool {
        guard canSave else { return false }
        let preset = LocalEQPreset(id: id ?? UUID(), name: name.trimmingCharacters(in: .whitespacesAndNewlines), gains: gains)
        guard Self.valid(preset), presets.count < 128 || presets.contains(where: { $0.id == id }) else {
            error = "Enter a name and ten finite gain values between −24 and +24 dB. At most 128 presets can be stored."
            return false
        }
        var updated = presets
        if let index = updated.firstIndex(where: { $0.id == preset.id }) { updated[index] = preset }
        else { updated.append(preset) }
        return persist(updated)
    }

    func remove(_ id: UUID) { _ = persist(presets.filter { $0.id != id }) }

    private static func valid(_ preset: LocalEQPreset) -> Bool {
        !preset.name.isEmpty && preset.name.count <= 80 && preset.gains.count == frequencies.count &&
            preset.gains.allSatisfy { $0.isFinite && (-24...24).contains($0) }
    }

    private func persist(_ updated: [LocalEQPreset]) -> Bool {
        guard canSave else { return false }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(Document(version: 1, presets: updated)).write(to: url, options: .atomic)
            presets = updated
            error = nil
            return true
        } catch {
            self.error = "Could not save local presets."
            return false
        }
    }
}
