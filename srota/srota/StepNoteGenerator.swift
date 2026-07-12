import Foundation
import FoundationModels

// Generates a session's one-time title/summary and per-step (title, description) notes —
// see ticket 01 in docs/wayfinder/agent-session-persistence/. Calls Apple's on-device
// FoundationModels directly (no apfel/ApfelCore — that library has no inference of its
// own, see the ticket's correction). Falls back to a generic label + the raw hook text
// whenever the model is unavailable or a call fails; never blocks its caller on failure.
@Generable
private struct GeneratedNote {
    @Guide(description: "A few words naming exactly what this message says, no invented topics, no trailing punctuation, at most 60 characters")
    var title: String
    @Guide(description: "One plain sentence describing exactly what this specific message says or does — nothing broader, at most 200 characters")
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
        "Start": "New prompt", // user-tagged — see SessionRecorder.stepTagByHookEvent
    ]

    // ponytail: naive char-count proxy for the model's 4096-token context window (ticket 01) —
    // ~2000 chars leaves ample room for the instruction text plus generated output within that
    // budget. Upgrade to a real tokenizer (FoundationModels exposes token counting) if inputs
    // start actually landing close to the ceiling.
    private static let maxInputChars = 2000

    // Below this, generation is skipped entirely and the raw text is used as-is. The on-device
    // 3B model tends to *invent* a broader topic when given too little to work with (observed:
    // "hi" alone produced a title about "note-taking techniques") rather than admit there's
    // nothing to summarize — trivial input isn't worth that risk, and there's nothing to gain
    // by summarizing something already shorter than a summary would be.
    private static let minCharsForGeneration = 12

    private static func truncated(_ text: String) -> String {
        text.count > maxInputChars ? String(text.prefix(maxInputChars)) : text
    }

    // Explicitly grounds the model in whose message this is and forbids inventing content
    // beyond it — the generic "summarize this" phrasing let the model drift into describing
    // "the conversation" in the abstract instead of this specific message. Length limits are
    // stated here AND in GeneratedNote's @Guide descriptions above (no code-level truncation —
    // @Guide has no string-length constraint, .count is collection-only, so the prompt/schema
    // wording is the only lever; this is instruction, not a hard guarantee, by design).
    private static func prompt(tag: String, text: String) -> String {
        let speaker = tag == "user"
            ? "The user sent this message to a coding assistant"
            : "A coding assistant sent this message"
        return """
        \(speaker). Message: "\(text)"

        Write a title (at most 60 characters) and description (at most 200 characters, one \
        plain sentence) that describe ONLY the exact content of this message. Do not invent \
        details that are not present in it. Do not describe the conversation in general terms \
        or speculate about context — describe specifically and only what this message itself \
        says.
        """
    }

    static func generateStep(hookEvent: String, tag: String, rawSummary: String) async -> StepNote {
        let fallbackTitle = genericTitles[hookEvent] ?? hookEvent
        guard !rawSummary.isEmpty else {
            return StepNote(title: fallbackTitle, description: "", source: "raw")
        }
        let text = truncated(rawSummary)
        guard text.count >= minCharsForGeneration else {
            return StepNote(title: text, description: "", source: "raw")
        }
        if let generated = await generate(prompt: prompt(tag: tag, text: text)) {
            return StepNote(title: generated.title, description: generated.description, source: "model")
        }
        return StepNote(title: fallbackTitle, description: rawSummary, source: "raw")
    }

    // Session title/summary are set once from the first prompt (ticket 04) — same shape,
    // just no hookEvent-derived fallback label since there's no event to name here. Always
    // tag: "user" — this only ever runs on a prompt-submission event's own text.
    static func generateSessionTitle(from firstPrompt: String) async -> StepNote {
        guard !firstPrompt.isEmpty else {
            return StepNote(title: "", description: "", source: "raw")
        }
        let text = truncated(firstPrompt)
        guard text.count >= minCharsForGeneration else {
            return StepNote(title: text, description: text, source: "raw")
        }
        if let generated = await generate(prompt: prompt(tag: "user", text: text)) {
            return StepNote(title: generated.title, description: generated.description, source: "model")
        }
        return StepNote(title: firstPrompt, description: firstPrompt, source: "raw")
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
