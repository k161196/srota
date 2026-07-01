# Srota Agent Status Pipeline Handoff

Focus for next session: implement the daemon-backed agent status pipeline and Agents-tab split view from the grilled plan.

## Suggested Skills

- `ponytail:ponytail`: active by default; keep the implementation minimal, reuse existing types/paths, avoid new abstractions.
- `context-mode:context-mode`: use for large test/build output or broad file analysis.
- `grilling`: only if a new design branch appears; do not re-ask decisions below.

## Repo Context

- Workspace: `/Users/kiran/Kiran/organizations/k161196/projects/srota/branches/main`
- Indexed MCP project: `Users-kiran-Kiran-organizations-k161196-projects-srota-branches-main`
- Prefer `codebase-memory-mcp` tools for code discovery: `search_graph`, `trace_path`, `get_code_snippet`, `search_code`.
- Key files:
  - `srota/srota-daemon/DaemonProtocol.swift`
  - `srota/srota-daemon/PTYRegistry.swift`
  - `srota/srota-daemon/PTYProcess.swift`
  - `scripts/notify.sh`
  - `srota/srota/DaemonConnection.swift`
  - `srota/srota/ContentView.swift`
  - `srota/srota/ManagementView.swift`
  - `srota/srota/AgentNotificationRouting.swift`

## Existing Code Facts Observed

- `PTYProcess` already has `paneID`, `stableID`, `initialCWD`, `subscribers`, and `info`.
- `ptyEnvironment(...)` already sets `SROTA_PANE_ID = stableID` and `SROTA_SOCKET_PATH`, so `notify.sh` can route daemon events without new UI env plumbing.
- `DaemonConnection.restoreManagedSession(stableID:)` already reuses an existing live PTY from `list()` when `PTYInfo.stableID == stableID && exitCode == nil`.
- `PTYProcess.subscribers` is a list, so multiple simultaneous viewers on one PTY are already supported.
- Current UI status routing uses `TerminalTab.agentNotifications`, `applyAgentHookEvent`, `bestMatchingTab`, `AgentNotificationRouter`, and `startAgentEventMonitor`; these are to be deleted/replaced.
- Existing `AgentRunStatus` in `AgentNotificationRouting.swift` has cases/raw values:
  - `working`
  - `idle`
  - `blocked`
  - `done`
- Existing `AgentRunStatus(event:)` mapping:
  - `Start`, `SessionStart` -> `working`
  - `PermissionRequest` -> `blocked`
  - `Stop` -> `idle`
  - `SessionEnd` -> `done`

## Accepted Design Decisions

1. If `agent_event.stableID` does not resolve to a live `PTYProcess`, daemon silently ignores it.
2. Clear status on PTY exit/removal; map `SessionEnd` to `done` while PTY is still alive.
3. Protocol/UI should reuse existing status raw values: `working`, `idle`, `blocked`, `done`.
4. `notify.sh` sends raw hook event names; daemon normalizes to status before storing/broadcasting.
5. Duplicate the tiny 4-case status enum/mapping in daemon code for now; do not wire shared Swift target files.
6. Ignore out-of-order agent events where `timestamp < current.updatedAt`.
7. Equal timestamps may overwrite existing status (`>=` wins).
8. Broadcast `agentStatus` to all connected clients, including any sender.
9. `.listed()` includes agent fields while a PTY still exists, even if exited but not reaped.
10. `.agentStatus` payload includes both `paneID` and `stableID`.
11. `status` may be optional for clear events; when status is present, `agent`, `summary`, and `updatedAt` should be present.
12. Empty `summary` is allowed; UI can hide it.
13. `notify.sh` sends `agent_event` only when `SROTA_PANE_ID` is set; otherwise silent no-op.
14. Drop `agent-events.jsonl` and `last-agent-hook.json` writes.
15. Keep macOS notification dedupe file `~/.srota/last-notification.json`.
16. If `notify.sh` cannot connect to socket, daemon event is silent no-op and existing macOS notification behavior continues.
17. Daemon accepts `agent_event` from any local socket client for now; no new auth.
18. `DaemonConnection.agentStatesByStableID` clears on daemon disconnect.
19. `DaemonConnection.list()` updates `agentStatesByStableID` internally before resuming continuation.
20. A `.listed()` snapshot replaces the client dictionary exactly with statuses present in that snapshot.
21. `.agentStatus(status: nil)` removes only that stable ID from the client dictionary.
22. Agents tab default list means PTYs with current daemon agent status, not heuristic history detection.
23. `idle` and `done` stay visible in default Agents list while the PTY is live.
24. Do not persist the “show all daemon processes” toggle.
25. Manual refresh calls only `daemon.list()`; existing connection logic handles reconnect.
26. Agents split view selection: keep selected row if still present; otherwise select first visible row; otherwise show empty state.
27. If selected PTY exits while attached, terminal remains visible until selection disappears from next `.list()` snapshot or user selects another row.
28. Agents-tab inline viewer uses a separate `InMemoryTerminalSession`/`DaemonPaneRef` per selected row and attaches to same PTY.
29. Switching Agents-tab selection detaches locally but does not close the PTY.

## Implementation Outline

### Daemon Protocol

- In `DaemonProtocol.swift`:
  - Add `DaemonRequest.agentEvent(stableID:event:agent:summary:timestamp:)`.
  - Extend request decoding keys with `stableID`, `event`, `agent`, `summary`, `timestamp`.
  - Add optional fields to daemon `PTYInfo`: status, agent, summary, updatedAt.
  - Add `DaemonResponse.agentStatus(paneID:stableID:status:agent:summary:updatedAt:)`.
  - Encode type as `agent_status`.

### Daemon State

- In `PTYProcess.swift`:
  - Add in-memory fields under existing lock: status, agent, summary, updatedAt.
  - Add a small method like `applyAgentEvent(event:agent:summary:timestamp:) -> PTYInfo?` or return a status payload if changed.
  - Normalize raw events using a tiny daemon-side enum/mapping matching existing `AgentRunStatus`.
  - Ignore event if timestamp is older than current `updatedAt`.
  - Include agent fields in `info`.
  - Clear/broadcast nil status on exit/removal if needed, but avoid overbuilding. At minimum, removal from `.list()` replacement clears UI.

- In `PTYRegistry.swift`:
  - Handle `.agentEvent`: find process by `stableID` exactly. Since registry is keyed by `paneID`, either scan `processes.values.first(where: stableID)` or maintain a stableID map only if already needed. Ponytail preference: scan until proven hot.
  - On successful status change, broadcast `.agentStatus(...)` to all clients.
  - Keep unknown stable IDs silent.

### notify.sh

- Remove JSONL and `last-agent-hook.json` file writes.
- Keep hook parsing and macOS notification dedupe behavior.
- After parsing a valid raw event, if `SROTA_PANE_ID` exists, open `${SROTA_SOCKET_PATH:-$HOME/.srota/daemon.sock}` with python3 and send one JSON line:
  - `type: "agent_event"`
  - `stableID: $SROTA_PANE_ID`
  - `event`
  - `agent`
  - `summary`
  - `timestamp`
- Socket connect failure must be silent and not prevent OS notification code.

### App DaemonConnection

- Add `agentStatesByStableID: [String: AgentNotificationState]` or equivalent published/main-actor observable state.
- Parse `agent_status` broadcasts and update/remove by `stableID`.
- Extend app-side `PTYInfo` parsing with optional agent fields.
- In `.listed` handling, parse panes, replace `agentStatesByStableID` with statuses present in snapshot, then resume pending list.
- Clear `agentStatesByStableID` on disconnect.

### UI Replacement

- Delete old file-monitor/fuzzy matching path:
  - `TerminalTab.agentNotifications`
  - `TerminalTab.applyAgentStatus` if only used by old path
  - `ContentView.applyAgentHookEvent`
  - `ContentView.bestMatchingTab`
  - `ContentView.startAgentEventMonitor`
  - `AgentNotificationRouter`/routing tests if no longer used
- Pane header/sidebar widget/`collectRunningAgents` should read by `pane.daemonStableID` from `DaemonConnection.agentStatesByStableID`.
- Sidebar widget under Workspaces keeps current click behavior: jump to actual workspace pane.

### Agents Tab Split View

- In `ManagementView.swift`, change `AgentsPanel` to split view:
  - Left: list of current daemon statuses by default.
  - Overflow menu toggles “show all daemon processes” including plain shells from `.list()`.
  - Manual refresh button calls `daemon.list()`.
  - Toggle is local state only, not persisted.
  - Selection preservation as described in decision 26.
- Right side:
  - Attach inline with a separate terminal session/ref using existing `spawnOrAttach/restoreManagedSession` path and matching stable ID.
  - Do not jump to Workspaces from Agents tab clicks.
  - Switching selection should detach local viewer but not close PTY. If no explicit detach API exists, verify whether replacing `managedSessions[stableID]` would disrupt workspace viewers before using it; avoid killing PTY.

## Checks To Run

- Existing lightweight notification tests likely need updates:
  - `scripts/test-notification-hooks.sh`
  - `scripts/test-agent-notification-routing.swift` may be deleted or replaced depending on removed router.
- Add one small runnable regression check for daemon protocol/status mapping if practical. Keep it minimal.
- Build/check command to discover from repo if needed; do not assume Xcode scheme names without checking.

## Cautions

- Do not add new dependencies.
- Do not reintroduce cwd/tab fuzzy matching.
- Do not persist agent status outside daemon memory.
- Be careful with `spawnOrAttach`: current implementation stores one `ManagedSession` per stableID, so using it for both workspace pane and Agents viewer may replace the workspace managed session. Inspect before implementing inline attach; a minimal separate attach path may be safer if `spawnOrAttach` cannot support two app-side sessions for one stableID.
- Preserve validation/security/a11y basics; ponytail does not mean deleting guards.
