import Foundation
import Observation

struct TerminalPreset: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var description: String = ""
    var commands: [String]
}

@Observable @MainActor
final class PresetsStore {
    var presets: [TerminalPreset] = []

    private static let path = NSHomeDirectory() + "/.srota/presets.json"

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.path)),
              let decoded = try? JSONDecoder().decode([TerminalPreset].self, from: data)
        else { return }
        presets = decoded
    }

    func save() {
        let dir = NSHomeDirectory() + "/.srota"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.path))
    }

    func add(_ preset: TerminalPreset) {
        presets.append(preset)
        save()
    }

    func update(_ preset: TerminalPreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[idx] = preset
        save()
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }
}
