# Settings + Terminal Presets — Design Spec

**Date:** 2026-06-23  
**Scope:** Settings overlay with Terminal Presets management and quick-launch strip in TopNavBar.

---

## Overview

Add a Settings gear icon to `TopNavBar`. Clicking it overlays a two-column Settings panel. The Terminal section lets users create/edit/delete terminal presets (name, description, commands). Presets also appear as quick-launch buttons in `TopNavBar`; clicking one sends the preset's commands to the currently focused terminal pane.

---

## Data Model

```swift
struct TerminalPreset: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var description: String = ""
    var commands: [String]   // one per row, joined with \n on launch
}
```

Persisted to `~/.srota/presets.json`.

---

## New Files

### `PresetsStore.swift`

```swift
@Observable @MainActor
final class PresetsStore {
    var presets: [TerminalPreset] = []

    private static let path = NSHomeDirectory() + "/.srota/presets.json"

    init() { load() }

    func load()    // decode from path, silently no-op if missing
    func save()    // encode to path, create ~/.srota dir if needed
    func add(_ preset: TerminalPreset)
    func update(_ preset: TerminalPreset)
    func delete(id: UUID)
}
```

Injected into the environment via `srotaApp.swift` alongside `AppSettings`.

### `SettingsView.swift`

Contains:
- `SettingsPanel` — full-screen ZStack overlay, two-column HStack
- `SettingsSidebar` — left column (~200px), "Settings" title, single "Terminal" nav row (selected state)
- `TerminalSettingsView` — right column, preset list + Add/Import buttons
- `PresetEditSheet` — sheet for create/edit: Name field, Description field, dynamic Commands list, Delete button

---

## Modified Files

### `ManagementView.swift` — `TopNavBar`

- Add `onSettings: () -> Void` callback parameter.
- Add gear `Button` on the **trailing** side (right of existing tabs).
- After existing management tab buttons, render `ForEach(presetsStore.presets)` as quick-launch `Button`s. Each shows `Image(systemName: "terminal")` + `Text(preset.name)`.
- `TopNavBar` receives `presetsStore` and `onPresetLaunch: (TerminalPreset) -> Void` callbacks.

### `ContentView.swift`

- Add `@State private var showSettings = false`.
- Pass `onSettings: { showSettings.toggle() }` to `TopNavBar`.
- Pass `onPresetLaunch:` to `TopNavBar` — implementation: `manager.selectedWorkspace?.selectedTab?.focusedViewState.send(preset.commands.joined(separator: "\n") + "\n")`.
- In the ZStack (same level as `ManagementPanel`): when `showSettings`, show `SettingsPanel`.

### `srotaApp.swift`

- Instantiate `PresetsStore` and inject via `.environment(presetsStore)`.

---

## UI Behaviour

### Settings panel
- Overlays the full content area (same z-level pattern as `ManagementPanel`).
- Back/close: gear icon toggles it off, or a "← Back" button in the sidebar header.
- Only "Terminal" is a functional nav item for now. Others are placeholders (greyed out, no action).

### Preset list (TerminalSettingsView)
- Rows show: icon (`terminal`) + name (bold) + first command (monospaced, muted) + "All projects · New tab" label (muted, right-aligned).
- Click row → opens `PresetEditSheet` in edit mode.
- `+ Add Preset` button (top-right) → opens `PresetEditSheet` in create mode.
- `+ Import agent` button (below header) — placeholder for now, no-op with a TODO comment.

### PresetEditSheet
- Title = preset name (or "New Preset" for create).
- Name `TextField`.
- Description `TextField`.
- Commands: `ForEach(commands)` of `TextField` rows + `+ Add command` button below. Each row has an `×` to remove.
- Bottom-left: "Delete preset" destructive button (hidden in create mode).
- Bottom-right: "Done" button saves and dismisses.

### Quick-launch strip
- Preset buttons render after the last management tab in `TopNavBar`.
- Active preset (if name matches a focused terminal's running command) could be highlighted later — out of scope now.
- Click sends `preset.commands.joined(separator: "\n") + "\n"` to `focusedViewState.send()`.

---

## Out of Scope (this iteration)

- Applies-to (all vs specific projects)
- Directory field
- Launch mode (current tab vs new tab)
- Auto-run toggles
- Import agent functionality
- Preset icons (custom per-preset)
- Settings categories beyond Terminal
