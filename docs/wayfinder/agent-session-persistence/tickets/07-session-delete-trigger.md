---
title: What actually triggers a session getting deleted
type: grilling
status: closed
assignee: claude
blocked_by: [06-step-cascade-delete]
---

## Question

Graduated from the map's "Not yet specified" note, narrowed by [[06-step-cascade-delete]] to just cascade *mechanics*. This ticket is the remaining half: what event actually causes a `sessions` row (and, via [[06-step-cascade-delete]], its `session_steps`) to be deleted in the first place?

## Answer

**Both, per Kiran's call:** cascade-delete a session when its pane is genuinely closed for good, *and* separately allow manual delete once a session-history UI exists. No time-based retention window for v1.

The session-history UI itself stays **out of scope of this map** (Kiran confirmed: keep this destination as a persistence design, start a fresh wayfinder map for the UI later) — that part of the "Out of scope" section is unchanged. This ticket only locks in the automatic half.

**Important correction caught while wiring this up** — the obvious-looking trigger is wrong. `ws_panes` rows are **not** a reliable "this pane is closed" signal: `saveTabsAndPanes`/`saveLayoutSnapshot` (`WorkspaceDB.swift:419,432`) both call `deleteTabs(workspaceID:)`, which bulk-deletes **every** `ws_panes` row for the workspace and reinserts the current set — on every routine layout save, not just when a pane is actually closed. Cascading session deletion off that `DELETE FROM ws_panes` would wipe session history for panes still open and in active use, every time the layout persists.

The real "this pane is gone for good" signal is the daemon `close` request — sent from exactly two call sites in `DaemonConnection.swift` (lines 458, 583), distinct from the layout-save path, and the point at which the daemon actually terminates the PTY (`PTYRegistry.handle(.close)` → `PTYProcess.terminate()`). **Cascade session deletion from wherever the app sends `{"type": "close", "paneID": ...}`** — alongside that call, run `deleteSession`-style cleanup for every `sessions` row with that `pane_id` (which itself cascades to `session_steps` per [[06-step-cascade-delete]]) — not from the `ws_panes` table's own delete/reinsert churn.

## Updated map note

- [Sessions & steps schema](04-sessions-schema.md)'s `sessions.pane_id` FK is stable across ordinary layout saves (those never touch `sessions`); it's only invalidated when the daemon `close` path actually fires.
