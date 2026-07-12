---
title: Provider & resume modeling + session-id capture wiring
type: grilling
status: closed
assignee: claude
blocked_by: [02-codex-resume]
---

## Question

Decide how to replace the current stringly-typed provider check (`agent.name.localizedCaseInsensitiveContains("codex")` in `ContentView.swift`) with a real `AgentProvider` model (enum or protocol) that covers:

- Resume-flag construction per provider (Claude's `--resume <session_id>`, and Codex's equivalent per [[02-codex-resume]]'s findings).
- Where the external session id is captured from the hook payload for each provider, and how it's threaded through the existing pipeline: `scripts/notify.sh` → daemon Unix socket (`agent_event` message) → `PTYRegistry` → the eventual `sessions` row.
- Whether this capture requires changes to the JSON payload shape sent over the socket (currently `stableID`, `event`, `agent`, `summary`, `timestamp` — no session id field).

Use `/grilling` — this is a design/naming decision, not implementation, even though it names exact fields and call sites.

## Answer

### AgentProvider: protocol, not enum

Chosen over a simpler enum — anticipates providers beyond the current two:

```swift
protocol AgentProvider {
    var id: String { get }                              // persisted string: "claude" | "codex"
    func resumeArgs(sessionID: String) -> [String]
}

struct ClaudeProvider: AgentProvider {
    let id = "claude"
    func resumeArgs(sessionID: String) -> [String] { ["--resume", sessionID] }
}

struct CodexProvider: AgentProvider {
    let id = "codex"
    func resumeArgs(sessionID: String) -> [String] { ["resume", sessionID] }
}

enum AgentProviderRegistry {
    static func resolve(id: String) -> AgentProvider? {
        switch id {
        case "claude": return ClaudeProvider()
        case "codex": return CodexProvider()
        default: return nil
        }
    }
}
```

**Persistence note:** `TerminalPreset`/`AgentItem` are `Codable`, persisted as JSON (`~/.srota/presets.json`/`agents.json`) — a protocol existential can't round-trip through `Codable` directly. Presets store a plain `providerID: String` field (set explicitly when a preset is created/edited, replacing today's `agent.name.localizedCaseInsensitiveContains("codex")` sniffing), resolved to the concrete `AgentProvider` via `AgentProviderRegistry.resolve(id:)` wherever behavior (resume args) is needed.

### Session-id capture wiring

1. `scripts/notify.sh`'s Python parser already receives `session_id` in the hook payload for both providers (confirmed in [[02-codex-resume]]) but discards it. Add it to the JSON posted over the daemon socket: `payload.get("session_id")`, included only when present.
2. `DaemonProtocol.swift`: `AgentEventParams` gains `let sessionID: String?` — optional, best-effort, no validation. A missing `session_id` on some future/unexpected hook payload shape must not break the existing working/idle/blocked/done status pipeline, which doesn't depend on it.
3. `PTYProcess.applyAgentEvent` threads `sessionID` through to whatever gets broadcast to app clients — recommend extending the existing `AgentStatusPayload` (already broadcast to every connected client on every event) with the same optional `sessionID` field, rather than inventing a second parallel broadcast type. This is an implementation-level call, not a design fork — flag it for the build ticket to confirm, not worth re-litigating here.

### DB writer: the app, not the daemon

Checked directly: `WorkspaceDB` (`srota/srota/WorkspaceDB.swift`) is only ever referenced inside the main app target (`srota/srota/*`) — the daemon (`srota/srota-daemon/*`) has **zero** SQLite access today, only the Unix socket.

**Decision: keep it that way.** The daemon does not open its own connection to `srota.db`. It forwards session/step-relevant data (pane_id, provider, sessionID, hook event, summary) to the app over the existing socket, piggybacking on the `AgentStatusPayload` broadcast per above. The **app** — which already owns `WorkspaceDB`'s single `sqlite3` connection — is the one and only writer of `sessions`/`session_steps`, exactly as it's the only writer of `ws_panes`/`ws_tabs` today. This avoids introducing a second process writing to the same SQLite file (which would otherwise require WAL mode and concurrent-writer handling the codebase has never needed to reason about).

**Consequence:** since the app is already the async job runner + DB writer, it's also the natural place to invoke `ApfelCore` ([[01-apfel-fit]]) for step-note summarization — not the daemon. The daemon's role stays exactly what it is today: a thin PTY/event relay, no new heavy dependency added to that binary.

### What creates a `sessions` row vs. a `session_steps` row

- A `sessions` row is created the first time the app sees a given `(pane_id, sessionID)` pair it doesn't already have a session for — typically on `SessionStart`/first `Start` event, even though (per [[04-sessions-schema]]) those events never produce a `session_steps` row themselves.
- A `session_steps` row is appended only for the content-bearing events (`Stop`, `PermissionRequest`, `SessionEnd`) already decided in [[04-sessions-schema]].
