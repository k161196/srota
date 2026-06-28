import Foundation
import Observation

struct PromptItem: Codable, Identifiable {
    var id: UUID
    var name: String
    var description: String
    var content: String

    init(id: UUID = UUID(), name: String, description: String = "", content: String = "") {
        self.id = id; self.name = name; self.description = description; self.content = content
    }
}

@Observable @MainActor
final class PromptsStore {
    var items: [PromptItem] = []

    private static let path = NSHomeDirectory() + "/.srota/prompts.json"

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.path)),
              let decoded = try? JSONDecoder().decode([PromptItem].self, from: data)
        else { return }
        items = decoded
    }

    func save() {
        let dir = NSHomeDirectory() + "/.srota"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(items) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.path))
    }

    func add(_ item: PromptItem) { items.append(item); save() }

    func update(_ item: PromptItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        items[idx] = item; save()
    }

    func delete(id: UUID) { items.removeAll { $0.id == id }; save() }
}
