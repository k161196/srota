---
label: wayfinder:map
---

# Map: Agent Session Persistence

## Destination

A locked design for persisting agent sessions in Srota's database: the sessions/steps schema (provider, resumable session id, title, per-hook step notes), a decision on whether apfel is the right summarizer, and a decision on whether PTY screen-reading pulls its weight over hook-sourced data alone. Handed off ready to build from — this map produces no implementation itself.

## Notes

Domain: Srota, the macOS terminal/agent tool this repo builds. Grounding facts, confirmed by reading the code (2026-07-12):

- `srota/srota/WorkspaceDB.swift` — raw `SQLite3` C API (no ORM). Tables today: `repos`, `ws_workspaces`, `ws_tabs`, `ws_panes` — layout only, no `sessions`/`steps` table.
- Provider detection is currently a string check: `agent.name.localizedCaseInsensitiveContains("codex")` (`ContentView.swift`) — no `AgentProvider` enum/protocol exists.
- `scripts/notify.sh` receives Claude/Codex hook JSON (stdin for Claude, `$1` for Codex), already extracts a per-turn `summary` (`last_assistant_message`, or scrapes the transcript file), and posts it over the daemon Unix socket — but it discards `session_id` and never persists anything; the socket payload is transient.
- `srota/srota-daemon/PTYProcess.swift` + `RingBuffer.swift` hold only raw PTY bytes for redraw/scrollback — no parsing. The existing Agent Status Pipeline (working/idle/blocked/done) is driven entirely by hook events + a process-tree polling fallback, **not** by reading the terminal screen.
- Hooks are already fully wired for both providers via `HookSetup.swift` / `check-agent-hooks.sh` (Claude: SessionStart, UserPromptSubmit, Stop, SessionEnd, Notification, PreToolUse/PostToolUse; Codex: SessionStart, Stop, UserPromptSubmit, PermissionRequest).

Skills to consult: `grilling` and `domain-modeling` for the schema/provider tickets.

## Decisions so far

- [Does apfel fit as the step-note summarizer?](tickets/01-apfel-fit.md) — **revised during implementation**: skip apfel/`ApfelCore` entirely — it's "FoundationModels-free by design" (no inference capability of its own) — and call Apple's `FoundationModels` (`@Generable` + `LanguageModelSession`) directly instead. Same on-device/no-API-key properties, zero new external dependencies. Async off the hook path and raw-summary fallback still hold.
- [Codex session resume support & identifiers](tickets/02-codex-resume.md) — Codex mirrors Claude: `codex resume <session_id>`, and Codex's hook payload already carries a stable top-level `session_id` field, same name as Claude's. One `external_session_id` column covers both providers; only the resume command shape differs.
- [Does PTY screen-reading add context value over hooks alone?](tickets/03-pty-read-mode.md) — no, skip it for this design. A live spike (read-only attach + ANSI strip) produced garbled, unusable text — the ring buffer has no cursor/redraw awareness, so real screen-reading needs a full terminal-emulator layer that doesn't exist yet. Not worth building for step notes when hooks already give clean structured data for free.
- [Sessions & steps schema](tickets/04-sessions-schema.md) — `sessions` (pane_id FK, one-to-many; title/summary set once from the first prompt; `ended_at IS NULL` = active, no separate status column) and `session_steps` (one row per content-bearing hook event only — Stop/PermissionRequest/SessionEnd; title+description always populated, generic label + raw text as fallback when apfel didn't run, `source` column records which). Terms recorded in the new root `CONTEXT.md`.
- [Provider & resume modeling + session-id capture wiring](tickets/05-provider-resume-modeling.md) — `AgentProvider` protocol (`ClaudeProvider`/`CodexProvider`) replacing name-sniffing; presets store an explicit `providerID` string. `session_id` threaded from the hook payload → `notify.sh` → a new optional `sessionID` field on the daemon's `AgentEventParams`/`AgentStatusPayload`. Daemon stays DB-free (confirmed it has zero SQLite access today) and forwards to the app, which remains the sole writer of `WorkspaceDB` — and the natural place to run apfel summarization.
- [session_steps cascade-delete with their session](tickets/06-step-cascade-delete.md) — app-level cascade (`deleteSession` deletes `session_steps` before `sessions`), matching the existing `deleteWorkspaceSession`/`deleteTabs` pattern already in `WorkspaceDB.swift`. Deliberately no SQL `FOREIGN KEY`/`PRAGMA foreign_keys` — that would change enforcement codebase-wide, not just for these two tables.
- [What actually triggers a session getting deleted](tickets/07-session-delete-trigger.md) — cascade-delete when the daemon's `close` request actually fires for that pane_id (the two real call sites in `DaemonConnection.swift`), **not** off `ws_panes`' own delete/reinsert churn — `saveTabsAndPanes`/`saveLayoutSnapshot` bulk-delete-and-reinsert `ws_panes` on every routine layout save, which would otherwise wipe sessions for panes still open. Manual delete via a future history UI supplements this, doesn't replace it. No time-based retention window for v1.

## Not yet specified
- A real terminal-emulator layer over the PTY ring buffer (cursor/redraw-aware, not ANSI-stripping) — deliberately not built for this effort ([[03-pty-read-mode]]); if one ever gets built for other reasons, screen content becomes worth reconsidering as a step-note source.

## Out of scope

- A session-history browser UI for surfacing past sessions — beyond this design effort; revisit once the schema exists as its own effort.
