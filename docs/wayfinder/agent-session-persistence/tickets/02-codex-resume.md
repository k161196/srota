---
title: Codex session resume support & identifiers
type: research
status: closed
assignee: claude
blocked_by: []
---

## Question

Claude Code sessions can be resumed via `claude --resume <session_id>`, and the `session_id` field is already present (but discarded) in the hook payloads `scripts/notify.sh` receives.

Does the `codex` CLI support an equivalent resume-by-id flow? If so:
- What's the flag/mechanism (e.g. `codex resume <id>`, `--resume`, something else)?
- What field in Codex's hook payload or rollout JSONL (see the `event_msg`/`response_item` parsing already in `scripts/notify.sh`) uniquely and stably identifies a session usable for that resume?
- Is that identifier stable across the life of a session, or does it change per-turn?

Compare directly against Claude's `session_id` semantics so the two providers can share one `sessions` table shape rather than needing provider-specific schemas.

## Answer

**Yes — Codex mirrors Claude closely enough that both providers can share one `sessions` shape.**

- Resume flow: `codex resume <session_id>` (a UUID), or `codex resume --last` to skip the picker. Equivalent in spirit to `claude --resume <session_id>`.
- Codex's hooks.json payload already includes a top-level **`session_id`** field on every hook event — the same field name Claude uses, not a differently-named equivalent. Confirmed against real hook-payload docs (developers.openai.com/codex/hooks) and cross-checked against Kiran's own local rollout files.
- Verified directly against a real local file: `~/.codex/sessions/2026/07/01/rollout-2026-07-01T10-41-39-019f1c17-08bc-74f0-8aa0-7e6817a78e1e.jsonl` opens with a `session_meta` record containing `"session_id":"019f1c17-08bc-74f0-8aa0-7e6817a78e1e"` — the exact same UUID embedded in the rollout filename, and the id `codex resume <uuid>` expects.
- **Stability:** the id is set once at session start (`session_meta`, first line of the rollout file) and never changes for the life of that session — same stability guarantee as Claude's `session_id`.

**Design implication for [[04-sessions-schema]] and [[05-provider-resume-modeling]]:** no provider-specific identifier schema is needed. A single `external_session_id: TEXT` column plus a `provider` column covers both — `scripts/notify.sh` already receives `session_id` in both providers' hook payloads, it's just currently discarded rather than forwarded over the daemon socket. The only per-provider difference is the resume *command shape* (`claude --resume <id>` vs `codex resume <id>`), which [[05-provider-resume-modeling]] should encapsulate behind the `AgentProvider` model, not the schema.

Sources: [Hooks | ChatGPT Learn](https://developers.openai.com/codex/hooks), [How to Resume a Codex CLI Session](https://inventivehq.com/knowledge-base/openai/how-to-resume-sessions), and direct inspection of a local `~/.codex/sessions/` rollout file.
