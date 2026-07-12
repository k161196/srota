import Foundation

// Turns agent_status broadcasts into sessions/session_steps rows (tickets 04/05). Owns no
// socket/transport knowledge itself — DaemonConnection just calls handle() per event.
// Also the live source for the pane-header timeline icon + right sidebar: stepsByPaneID
// mirrors the DB for whichever panes a view has asked about, kept in sync in-memory rather
// than making the UI poll SQLite.
@MainActor
@Observable
final class SessionRecorder {
    private let db: WorkspaceDB
    private(set) var stepsByPaneID: [String: [SessionStepRecord]] = [:]
    // Which pane's timeline the right sidebar is currently showing, if any — toggled by the
    // pane-header icon, read directly by SessionTimelineSidebar. Living here (rather than
    // threaded as a callback through WorkspaceContent → TerminalContentView → paneView →
    // PaneHeader) avoids widening five view inits for one piece of UI state, since
    // SessionRecorder is already environment-injected everywhere those views sit.
    var timelinePaneID: String? = nil
    // Per-(pane, external session) write ordering, same shape as WorkspaceDB.enqueueWrite —
    // needed because a busy agent can fire Stop/PermissionRequest in quick succession, and
    // "find-or-create the session row" isn't atomic without serializing per session.
    // ponytail: dict entries are never evicted, so this grows for the app's lifetime, one
    // entry per (pane, session) ever seen — fine at real session counts; add eviction on
    // session end if a long-running instance's memory ever actually shows it matters.
    private var tailBySessionKey: [String: Task<Void, Never>] = [:]

    // hookEvent -> tag for every event that produces a session_step row. SessionStart is
    // deliberately absent — it fires once, before any prompt exists, and never carries content
    // (see promptEvents below, which it's still a candidate for, just for title backfill).
    private static let stepTagByHookEvent: [String: String] = [
        "Stop": "agent",
        "PermissionRequest": "agent",
        "SessionEnd": "agent",
        "Start": "user",
    ]
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

    // Called once per pane (e.g. from the steps bar's onAppear) to seed stepsByPaneID from the
    // DB. A no-op after the first call for a given pane — from then on the cache stays current
    // via recordEvent's own appends, no re-fetch needed.
    func loadIfNeeded(paneID: String) {
        guard stepsByPaneID[paneID] == nil else { return }
        stepsByPaneID[paneID] = []
        Task { [weak self] in
            let steps = await self?.db.currentSessionSteps(paneID: paneID)
            guard let steps, !steps.isEmpty else { return }
            // Don't clobber a step that arrived live (via recordEvent) while this DB fetch
            // was in flight — only apply the fetched history onto an still-empty cache.
            guard let self, self.stepsByPaneID[paneID]?.isEmpty ?? true else { return }
            self.stepsByPaneID[paneID] = steps
        }
    }

    // Unconditional re-fetch for one pane — unlike loadIfNeeded, always hits the DB regardless
    // of what's already cached. Backs both refreshTrackedPanes() below and the timeline
    // sidebar's manual refresh button (belt-and-suspenders alongside the automatic
    // onExternalWrite path, for whenever that's not enough to trust blindly).
    func refresh(paneID: String) {
        Task { [weak self] in
            guard let steps = await self?.db.currentSessionSteps(paneID: paneID) else { return }
            self?.stepsByPaneID[paneID] = steps
        }
    }

    // Re-fetches every currently-tracked pane's steps from the DB — wired to
    // WorkspaceDB.onExternalWrite so agent-initiated notes (written directly to SQLite by the
    // srota-mcp server's add_session_note tool, a separate process, not through this class)
    // show up live instead of only after the pane is reopened.
    // ponytail: fires on every DB write, not just session-relevant ones — same cost the repos
    // list refresh already accepts today; add debouncing if this ever shows up as measurably slow.
    func refreshTrackedPanes() {
        for paneID in stepsByPaneID.keys {
            refresh(paneID: paneID)
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
            // A fresh session starts a fresh steps bar — don't keep the previous session's
            // steps around once this pane has moved on to a new one.
            stepsByPaneID[event.stableID] = []
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

        guard let hookEvent = event.hookEvent, let tag = Self.stepTagByHookEvent[hookEvent] else { return }
        // User-tagged steps need actual prompt text to be worth showing (a Start with nothing
        // captured is noise) — but agent-tagged ones still get a step even with an empty
        // summary, same as before: generateStep already falls back to a generic label.
        guard tag != "user" || !event.summary.isEmpty else { return }
        let note = await StepNoteGenerator.generateStep(hookEvent: hookEvent, rawSummary: event.summary)
        let step = SessionStepRecord(
            id: UUID().uuidString,
            sessionID: record.id,
            hookEvent: hookEvent,
            title: note.title,
            description: note.description,
            source: note.source,
            tag: tag,
            createdAt: Int(event.timestamp)
        )
        db.appendSessionStep(step)
        stepsByPaneID[event.stableID, default: []].append(step)

        if hookEvent == "SessionEnd" {
            record.endedAt = Int(event.timestamp)
            db.upsertSession(record)
        }
    }
}
