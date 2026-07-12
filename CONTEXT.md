# Srota

Srota is a macOS terminal/agent tool: a daemon runs PTYs for shell and coding-agent (Claude, Codex) processes, and a SwiftUI app renders them as panes/tabs/workspaces.

## Language

**Session**:
A single run of a coding agent (Claude or Codex) inside a pane, identified by that provider's own resumable id (`session_id` for both providers today). A pane can host many sessions over its lifetime — the agent restarting, or being resumed under a fresh id, each start a new one.
_Avoid_: Conversation, run, thread.

**Step**:
A summarized record of one content-bearing hook event (`Stop`, `PermissionRequest`, `SessionEnd`) within a session — a `title` + `description` note, either generated on-device via FoundationModels or the raw hook summary used as a fallback (`session_steps.source` records which: `"model"` | `"raw"`). Lifecycle-only events (`SessionStart`, `Start`/`UserPromptSubmit`) don't produce steps; they never carry a summary to begin with.
_Avoid_: Event (that's the underlying hook event itself, not its summarized record), turn.
