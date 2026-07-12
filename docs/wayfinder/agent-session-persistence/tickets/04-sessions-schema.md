---
title: Sessions & steps schema
type: grilling
status: closed
assignee: claude
blocked_by: [01-apfel-fit, 02-codex-resume, 03-pty-read-mode]
---

## Question

Decide the concrete schema, additive to `WorkspaceDB.swift`'s existing `SQLite3` tables:

- A `sessions` table: columns should cover id, linkage to `ws_panes`/`ws_tabs`, provider, external/resumable session id (shape depends on [[02-codex-resume]]'s answer), title, status, timestamps.
- A `session_steps` table: one row per hook event — title, description, hook event type, timestamp, and a `source` field if [[03-pty-read-mode]] concludes PTY-derived notes are worth storing alongside hook-derived ones.
- Whether step-note text is the raw hook `summary`, an apfel-produced summary, or both (raw + summarized) — depends on [[01-apfel-fit]]'s recommendation.
- Session lifecycle relative to a pane: is it strictly 1:1 (one session per pane, ever), or can a pane run multiple sessions over its lifetime (agent restarted, resumed under a new external id)?

Use `/grilling` and `/domain-modeling` — this determines terminology (e.g. is a "step" the same thing as a hook event, or a distinct summarized artifact?) as much as it determines columns.

## Answer

Terminology and schema resolved via grilling (terms recorded in the repo's new [`CONTEXT.md`](../../../../CONTEXT.md)):

- **Pane → sessions is one-to-many.** A pane can host many sessions over its life (agent restarts, or resumes under a fresh external id). `sessions.pane_id` is a plain FK-by-string (matching the existing loose-FK style in `WorkspaceDB.swift` — no `FOREIGN KEY` constraints declared there either).
- **Session title/summary are set once**, from the first user prompt, then fixed — like a commit message, not a live status field (that's what `PTYProcess.agentStatus`/`agentSummary` already do, transiently). Populated asynchronously after apfel (or the raw fallback) finishes processing the first prompt — `title`/`summary` start `''` and get a single backfill.
- **Only content-bearing hook events become `session_steps` rows**: `Stop`, `PermissionRequest`, `SessionEnd`. `SessionStart` and `Start`/`UserPromptSubmit` are skipped — `notify.sh`'s `extract_summary` never has anything to return for them today, so a row would just be noise.
- **Fallback shape**: `title`/`description` are always populated, no nullable apfel-only columns. When apfel is unavailable, `title` gets a fixed label derived from the event (`"Turn complete"`, `"Blocked"`, `"Session ended"`) and `description` gets the raw hook summary verbatim. A `source` column (`'apfel'` | `'raw'`) records which path produced it.

### Schema (additive to `WorkspaceDB.swift`, matching its existing style — `TEXT PRIMARY KEY` UUIDs, `INTEGER` epoch timestamps, no declared FK constraints)

```sql
CREATE TABLE IF NOT EXISTS sessions (
    id                  TEXT PRIMARY KEY,
    pane_id             TEXT NOT NULL,
    provider            TEXT NOT NULL,              -- 'claude' | 'codex'
    external_session_id TEXT NOT NULL DEFAULT '',    -- from the hook payload's session_id; may be empty until the first hook fires
    title               TEXT NOT NULL DEFAULT '',    -- backfilled once, from the first prompt
    summary             TEXT NOT NULL DEFAULT '',
    created_at          INTEGER NOT NULL,
    ended_at            INTEGER                      -- NULL while active; a session is "active" iff this is NULL, not a separate status column
);

CREATE TABLE IF NOT EXISTS session_steps (
    id          TEXT PRIMARY KEY,
    session_id  TEXT NOT NULL,
    hook_event  TEXT NOT NULL,                       -- 'Stop' | 'PermissionRequest' | 'SessionEnd'
    title       TEXT NOT NULL,
    description TEXT NOT NULL,
    source      TEXT NOT NULL DEFAULT 'raw',          -- 'model' | 'raw' (see 01-apfel-fit's correction: FoundationModels directly, not apfel)
    created_at  INTEGER NOT NULL
);
```

No separate `status` column on `sessions` — deriving "active" from `ended_at IS NULL` avoids a second source of truth that could drift from it.

**Correction (2026-07-12):** `source` values are `'model'` | `'raw'`, not `'apfel'` | `'raw'` as originally written above — see [[01-apfel-fit]]'s correction (apfel/`ApfelCore` dropped in favor of calling `FoundationModels` directly).
