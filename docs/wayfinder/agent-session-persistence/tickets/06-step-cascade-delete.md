---
title: session_steps cascade-delete with their session
type: grilling
status: closed
assignee: claude
blocked_by: [04-sessions-schema]
---

## Question

Graduated from the map's "Not yet specified" retention-policy note. Narrowed scope (per Kiran): not the full retention/deletion-trigger question (when a session itself gets deleted — pane close, TTL, manual — still open), just referential integrity — when a `sessions` row is deleted, should its `session_steps` rows always go with it, and how is that enforced given this codebase's existing conventions?

## Answer

**App-level cascade, matching the existing convention — no SQL `FOREIGN KEY`/`ON DELETE CASCADE`.**

Checked `WorkspaceDB.swift`: the codebase already has this exact shape today. `deleteWorkspaceSession(id:)` calls `deleteTabs(workspaceID:)` first, which deletes `ws_panes WHERE tab_id = ?` before deleting `ws_tabs`, before finally deleting the `ws_workspaces` row itself — sequential, explicit `DELETE` statements at the app level. No `FOREIGN KEY` constraints are declared anywhere in `createTables()`, and `PRAGMA foreign_keys` is never turned on (it's off by default in SQLite).

Follow the same shape for sessions:

```swift
func deleteSession(id: String) {
    open()
    exec(sql("DELETE", sqlFrom, "session_steps", sqlWhere, "session_id = ?"), [id])
    exec(sql("DELETE", sqlFrom, "sessions", sqlWhere, "id = ?"), [id])
}
```

Deliberately not introducing a real SQL `FOREIGN KEY ... ON DELETE CASCADE` here: turning on `PRAGMA foreign_keys` would start enforcing referential integrity connection-wide, including on the existing `repos`/`ws_workspaces`/`ws_tabs`/`ws_panes` tables that have never had it — a behavior change to unrelated tables this ticket has no business making. Staying consistent with the app-level pattern keeps the blast radius to just the two new tables.

**Still open** (unchanged from the map's original fog note, now narrower): *when* a session actually gets deleted in the first place — on pane close, a time-based retention window, manual only — is a separate question, not resolved here.
