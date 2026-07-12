---
title: Does PTY screen-reading add context value over hooks alone?
type: prototype
status: closed
assignee: claude
blocked_by: []
---

## Question

Srota's PTY layer (`srota/srota-daemon/PTYProcess.swift`, `RingBuffer.swift`) currently stores only raw bytes for terminal redraw — nothing reads it for semantic context. The existing Agent Status Pipeline gets everything it needs from hook events plus process-tree polling.

Build a rough spike: read a running pane's `RingBuffer` content, strip ANSI escape sequences, and produce a plain-text snapshot of "what's currently on screen." Show the actual output to Kiran and discuss:

- Does this surface anything hooks don't already give us (e.g. mid-turn tool output, content between hook events)?
- What's the cost — perf overhead of scanning the ring buffer, complexity of ANSI stripping / terminal-state reconstruction (cursor position, alt-screen, etc.)?
- Is it worth being a first-class context/step-note source, or is it noise next to what hooks already provide?

This is a HITL prototype ticket — resolve it by showing Kiran the spike output and reaching a judgment together, not by deciding unilaterally.

## Answer

**Skip PTY screen-reading for this design; revisit only if a real terminal-emulator layer gets built for other reasons.**

Ran the spike live against a real running pane (read-only `attach` over `~/.srota/daemon.sock` — the daemon's subscriber model is a genuine fanout list (`PTYProcess.subscribers: [ClientSession]`), so attaching a second read-only listener does **not** steal or disrupt the real UI's connection; the "single-owner claim/steal" behavior noted elsewhere in project memory is a separate, higher-level UI-ownership concept, not this raw subscriber mechanism):

- Pulled the full 256KB ring buffer for an active `claude` pane, stripped ANSI escape sequences with a regex.
- Result was **garbled, not usable as-is**: words ran together with missing spaces (`"witing only on this"`), text was misread (`"Des PTY"` for "Does PTY"), and UI chrome/spinner text (`⏺`, `❯`, "Contemplating…") interleaved with real content. Stripping escape codes only removes the codes — it does not reconstruct what a cursor-aware redraw actually left on screen.
- **Root cause:** `RingBuffer.swift` is deliberately dumb, append-only bytes for scrollback replay — there is no VT/terminal-emulation layer anywhere in the daemon that tracks cursor position, line wrapping, or overwrites. Getting genuinely readable "current screen" text requires building that emulator layer, not just a better regex.

**Decision:** the cost (build a real terminal emulator) doesn't clear the bar next to what hooks already provide for free — clean, structured, zero-parsing-cost data (event name, session_id, summary). PTY screen-reading is **not** part of this design's step-note pipeline. Kiran chose to note it as a future option rather than rule it out permanently — see the map's "Not yet specified" section.
