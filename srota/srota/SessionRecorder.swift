import Foundation

// Turns agent_status broadcasts into sessions/session_steps rows (tickets 04/05). Owns no
// socket/transport knowledge itself — DaemonConnection just calls handle() per event.
@MainActor
final class SessionRecorder {
    private let db: WorkspaceDB
    // Per-(pane, external session) write ordering, same shape as WorkspaceDB.enqueueWrite —
    // needed because a busy agent can fire Stop/PermissionRequest in quick succession, and
    // "find-or-create the session row" isn't atomic without serializing per session.
    // ponytail: dict entries are never evicted, so this grows for the app's lifetime, one
    // entry per (pane, session) ever seen — fine at real session counts; add eviction on
    // session end if a long-running instance's memory ever actually shows it matters.
    private var tailBySessionKey: [String: Task<Void, Never>] = [:]

    private static let contentBearingEvents: Set<String> = ["Stop", "PermissionRequest", "SessionEnd"]
    // The prompt-submission events — the only ones whose summary can plausibly be "the first
    // prompt" rather than the agent's own reply (ticket 04: title/summary come from the prompt,
    // not from what the agent said back).
    private static let promptEvents: Set<String> = ["Start", "SessionStart"]

    init(db: WorkspaceDB) {
        self.db = db
    }

    func handle(_ event: AgentHookEvent) {
        guard let sessionID = event.sessionID, !sessionID.isEmpty else { return }
        let key = "\(event.stableID)|\(sessionID)"
        let previous = tailBySessionKey[key]
        tailBySessionKey[key] = Task { [weak self] in
            await previous?.value
            await self?.recordEvent(event, sessionID: sessionID)
        }
    }

    private func recordEvent(_ event: AgentHookEvent, sessionID: String) async {
        var session = await db.findSession(paneID: event.stableID, externalSessionID: sessionID)
        if session == nil {
            let created = SessionRecord(
                id: UUID().uuidString, paneID: event.stableID, provider: event.provider,
                externalSessionID: sessionID, createdAt: Int(event.timestamp)
            )
            db.upsertSession(created)
            session = created
        }
        guard var record = session else { return }

        // Title/summary are set once, from the first prompt (ticket 04) — never overwritten
        // once non-empty, and only from a prompt event, not from the agent's own reply.
        if record.title.isEmpty, !event.summary.isEmpty,
           let hookEvent = event.hookEvent, Self.promptEvents.contains(hookEvent) {
            let note = await StepNoteGenerator.generateSessionTitle(from: event.summary)
            record.title = note.title
            record.summary = note.description
            db.upsertSession(record)
        }

        guard let hookEvent = event.hookEvent, Self.contentBearingEvents.contains(hookEvent) else { return }
        let note = await StepNoteGenerator.generateStep(hookEvent: hookEvent, rawSummary: event.summary)
        db.appendSessionStep(SessionStepRecord(
            id: UUID().uuidString,
            sessionID: record.id,
            hookEvent: hookEvent,
            title: note.title,
            description: note.description,
            source: note.source,
            createdAt: Int(event.timestamp)
        ))

        if hookEvent == "SessionEnd" {
            record.endedAt = Int(event.timestamp)
            db.upsertSession(record)
        }
    }
}
