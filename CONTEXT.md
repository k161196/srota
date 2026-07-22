# Srota

Srota is a macOS terminal/agent tool: a daemon runs PTYs for shell and coding-agent (Claude, Codex) processes, and a SwiftUI app renders them as panes/tabs/workspaces.

## Language

**Session**:
A single run of a coding agent (Claude or Codex) inside a pane, identified by that provider's own resumable id (`session_id` for both providers today). A pane can host many sessions over its lifetime — the agent restarting, or being resumed under a fresh id, each start a new one.
_Avoid_: Conversation, run, thread.

**Step**:
A `title` + `description` note recorded within a session. Two independent columns describe it: `session_steps.tag` is who/what it's attributed to (`"user"` — what was asked, from a `Start`/`UserPromptSubmit` event's captured prompt text; `"agent"` — what the agent did, from `Stop`/`PermissionRequest`/`SessionEnd`; `"mcp"` — what the agent self-reported via the `add_session_note` MCP tool, `hook_event = "AgentReported"`); `session_steps.source` is how the text was produced (`"model"` — generated on-device via FoundationModels; `"raw"` — literal text, either a hook's fallback summary or an MCP note's own wording, never AI-summarized). `SessionStart` never produces a step — it fires before any prompt exists and never carries content.
_Avoid_: Event (that's the underlying hook event itself, not its summarized record), turn.

**Flow View State**:
The durable user choices that restore the Flow view's navigation and filters, including its selected tab, repository scope, queries, selected repository, and searches. Fetched GitHub data and transient presentation or operation state are not Flow View State.
_Avoid_: Flow State, cache.

**Repository Filter**:
The repository scope whose issues and pull requests are shown: all repositories, no repositories, or an explicitly selected subset.
_Avoid_: Project selection, project filter.
