# Unified Pane Model

**Date:** 2026-06-25  
**Status:** Approved

## Goal

Remove the "primary pane" special case from `TerminalTab`. All panes live in one `[PaneEntry]` array. First pane = index 0. Tab closes when array is empty.

## Model Changes

### TerminalTab — remove

| Property / Method | Replacement |
|---|---|
| `let viewState: TerminalViewState` | `panes[0].viewState` |
| `let primaryPaneHookID: String` | `panes[0].hookPaneID` |
| `@Published var primaryLayout: PaneLayout` | `paneLayouts[panes[0].id]` |
| `@Published var primaryExited: Bool` | deleted — no longer needed |
| `@Published var primaryPaneName: String` | `paneNames[panes[0].id]` |
| `@Published var secondaryPanes: [PaneEntry]` | merged into `panes` |
| `@Published var layouts: [UUID: PaneLayout]` | renamed `paneLayouts` |
| `func closePrimaryPane()` | `removePane(id: panes[0].id)` |
| `func collapsePrimary()` | deleted |

### TerminalTab — add / rename

```swift
@Published var panes: [PaneEntry]               // index 0 = first pane
@Published var paneLayouts: [UUID: PaneLayout]  // renamed from layouts
@Published var focusedPaneID: UUID              // non-optional; always valid
```

`paneNames: [UUID: String]` stays, now covers all panes including first.

### PaneRef — deleted

`enum PaneRef { case primary; case secondary(UUID) }` is removed.  
All call sites use `UUID` directly. `focusedPaneID` is non-optional `UUID`.

### focusedPaneID semantics

- Non-optional `UUID`. Init sets it to `panes[0].id`.
- `removePane`: if removed pane was focused, set to `panes[0].id` (after removal).
- No nil = primary special case.

## removePane — unified

```swift
func removePane(id: UUID) {
    let wasFocused = focusedPaneID == id
    expandNeighbor(of: id)            // expand before removing
    panes.removeAll { $0.id == id }
    paneLayouts.removeValue(forKey: id)
    paneNames.removeValue(forKey: id)
    agentNotification.clearIfOwned(byPaneID: /* hookPaneID for id */)
    if panes.isEmpty {
        closeTabCallback?()
    } else if wasFocused {
        focusedPaneID = panes[0].id
    }
}
```

All panes — including first — use this path. No separate `closePrimaryPane`.

## Rendering

```swift
ForEach(tab.panes) { entry in
    if let l = tab.paneLayouts[entry.id] {
        paneView(ref: entry.id, state: entry.viewState, layout: l,
                 onClose: { tab.removePane(id: entry.id) }, ...)
    }
}
```

No special branch for index 0.

## DB: `is_primary` → `position`

### PaneRecord

```swift
struct PaneRecord {
    var id: String
    var tabID: String
    var position: Int       // replaces isPrimary
    var lx, ly, lw, lh: Double
    var initialCWD: String
}
```

### Schema migration

On open: check if `position` column exists in `ws_panes`.  
If missing (legacy DB): ALTER TABLE to add `position INTEGER DEFAULT 0`, then UPDATE to set `position = 0` WHERE `is_primary = 1`, and `position = 1` for others (rough, positional ordering of secondaries not preserved — acceptable, they'll just reorder).

Save: write `position` = index in `panes` array.  
Load: `SELECT ... ORDER BY position ASC`.

Drop `is_primary` column: recreate table without it (SQLite has no DROP COLUMN before 3.35). Check `sqlite3_libversion()` at runtime; if ≥ 3.35 use `ALTER TABLE DROP COLUMN`, else recreate.

## onClose wiring

Currently primary's `onClose` is set separately in `addTab`/`addRestoredTab`.  
After: `addPane` sets `onClose` for every pane identically:

```swift
entry.viewState.onClose = { [weak self, weak entry] _ in
    guard let self, let entry else { return }
    self.removePane(id: entry.id)
}
```

`addTab` creates first pane via `addPane`, no separate wiring needed.

## KeyboardShortcuts.swift

- `kbAllPaneRefs: [PaneRef]` → `kbAllPaneIDs: [UUID]` = `tab.panes.map(\.id)`
- `kbLayout(for ref: PaneRef)` → `kbLayout(for id: UUID)` = `tab.paneLayouts[id]`
- `focusedPaneID == nil` (primary) checks → `focusedPaneID == tab.panes[0].id`

## AgentNotificationRouting.swift

`primaryPaneHookID` references → `panes[0].hookPaneID`.  
`paneIDs: Set([tab.primaryPaneHookID] + tab.secondaryPanes.map(\.hookPaneID))` → `Set(tab.panes.map(\.hookPaneID))`.

## Files touched

| File | Change scope |
|---|---|
| `ContentView.swift` | Model (TerminalTab), rendering, save/restore, all PaneRef sites |
| `KeyboardShortcuts.swift` | kbAllPaneRefs, kbLayout, focusToward |
| `WorkspaceDB.swift` | PaneRecord, savePane, loadPanes, schema migration |
| `AgentNotificationRouting.swift` | hookPaneID lookups |

## Out of scope

- No changes to `PaneEntry` struct itself.
- No changes to layout/resize logic beyond PaneRef → UUID substitution.
- No changes to UI appearance.
