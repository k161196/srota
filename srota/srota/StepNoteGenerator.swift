import Foundation
import FoundationModels

// Generates a session's one-time title/summary and per-step (title, description) notes —
// see ticket 01 in docs/wayfinder/agent-session-persistence/. Calls Apple's on-device
// FoundationModels directly (no apfel/ApfelCore — that library has no inference of its
// own, see the ticket's correction). Falls back to a generic label + the raw hook text
// whenever the model is unavailable or a call fails; never blocks its caller on failure.
@Generable
private struct GeneratedNote {
    @Guide(description: "A short title, a few words, no trailing punctuation")
    var title: String
    @Guide(description: "One or two plain-language sentences describing what happened")
    var description: String
}

struct StepNote {
    var title: String
    var description: String
    var source: String // "model" | "raw"
}

enum StepNoteGenerator {
    private static let genericTitles: [String: String] = [
        "Stop": "Turn complete",
        "PermissionRequest": "Blocked",
        "SessionEnd": "Session ended",
    ]

    // ponytail: naive char-count proxy for the model's 4096-token context window (ticket 01) —
    // ~2000 chars leaves ample room for the instruction text plus generated output within that
    // budget. Upgrade to a real tokenizer (FoundationModels exposes token counting) if inputs
    // start actually landing close to the ceiling.
    private static let maxInputChars = 2000

    private static func truncated(_ text: String) -> String {
        text.count > maxInputChars ? String(text.prefix(maxInputChars)) : text
    }

    static func generateStep(hookEvent: String, rawSummary: String) async -> StepNote {
        let fallbackTitle = genericTitles[hookEvent] ?? hookEvent
        guard !rawSummary.isEmpty else {
            return StepNote(title: fallbackTitle, description: "", source: "raw")
        }
        if let generated = await generate(prompt: "Summarize this into a short title and description: \(truncated(rawSummary))") {
            return StepNote(title: generated.title, description: generated.description, source: "model")
        }
        return StepNote(title: fallbackTitle, description: rawSummary, source: "raw")
    }

    // Session title/summary are set once from the first prompt (ticket 04) — same shape,
    // just no hookEvent-derived fallback label since there's no event to name here.
    static func generateSessionTitle(from firstPrompt: String) async -> StepNote {
        guard !firstPrompt.isEmpty else {
            return StepNote(title: "", description: "", source: "raw")
        }
        if let generated = await generate(prompt: "Summarize this into a short title and description: \(truncated(firstPrompt))") {
            return StepNote(title: generated.title, description: generated.description, source: "model")
        }
        return StepNote(title: String(firstPrompt.prefix(60)), description: firstPrompt, source: "raw")
    }

    @available(macOS 26.0, *)
    private static func generateViaModel(prompt: String) async -> GeneratedNote? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: GeneratedNote.self)
            return response.content
        } catch {
            return nil
        }
    }

    private static func generate(prompt: String) async -> GeneratedNote? {
        guard #available(macOS 26.0, *) else { return nil }
        return await generateViaModel(prompt: prompt)
    }
}
