# Settings + Terminal Presets Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a Settings overlay (gear icon in TopNavBar) with a Terminal Presets section, plus quick-launch preset buttons in the nav bar that send commands to the focused terminal pane.

**Architecture:** New `PresetsStore` (`@Observable`) persists `[TerminalPreset]` to `~/.srota/presets.json`. New `SettingsView.swift` contains the full settings UI. `TopNavBar` gains a gear button and a preset quick-launch strip. `ContentView` wires it all together via a `showSettings` state flag.

**Tech Stack:** SwiftUI (macOS), `@Observable` macro (requires macOS 14+), `GhosttyTerminal` `TerminalViewState.send(_:)` for PTY injection.

## Global Constraints

- macOS 14+ (`@Observable` macro, Swift 5.9)
- All UI uses existing design tokens: `Color(red: 0.067, green: 0.067, blue: 0.075)` bg, accent `Color(red: 1.0, green: 0.45, blue: 0.15)`, label `Color(red: 0.92, green: 0.92, blue: 0.93)`, muted = label at 0.40 opacity, surface `Color(red: 0.10, green: 0.10, blue: 0.11)`, border `Color.white.opacity(0.07)`
- Project root: `/Users/kiran/Kiran/organizations/k161196/projects/srota/branches/main`
- Build: `xcodebuild -project srota/srota.xcodeproj -scheme srota -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "error:|BUILD"`

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `srota/srota/PresetsStore.swift` | **Create** | `TerminalPreset` model + `PresetsStore` (load/save JSON) |
| `srota/srota/SettingsView.swift` | **Create** | `SettingsPanel`, sidebar, `TerminalSettingsView`, `PresetEditSheet` |
| `srota/srota/srotaApp.swift` | **Modify** | Instantiate + inject `PresetsStore` into environment |
| `srota/srota/ManagementView.swift` | **Modify** | `TopNavBar` — gear button + preset quick-launch strip |
| `srota/srota/ContentView.swift` | **Modify** | `showSettings` state, wire `TopNavBar` callbacks, overlay `SettingsPanel` |

---

## Task 1: PresetsStore — model + persistence

**Files:**
- Create: `srota/srota/PresetsStore.swift`

**Interfaces:**
- Produces:
  - `struct TerminalPreset: Codable, Identifiable` with `id: UUID`, `name: String`, `description: String`, `commands: [String]`
  - `@Observable @MainActor final class PresetsStore` with `var presets: [TerminalPreset]`, `func add(_:)`, `func update(_:)`, `func delete(id:)`

- [ ] **Step 1: Create `PresetsStore.swift`**

```swift
import Foundation
import Observation

struct TerminalPreset: Codable, Identifiable {
    var id: UUID = UUID()
    var name: String
    var description: String = ""
    var commands: [String]
}

@Observable @MainActor
final class PresetsStore {
    var presets: [TerminalPreset] = []

    private static let path = NSHomeDirectory() + "/.srota/presets.json"

    init() { load() }

    func load() {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: Self.path)),
              let decoded = try? JSONDecoder().decode([TerminalPreset].self, from: data)
        else { return }
        presets = decoded
    }

    func save() {
        let dir = NSHomeDirectory() + "/.srota"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(presets) else { return }
        try? data.write(to: URL(fileURLWithPath: Self.path))
    }

    func add(_ preset: TerminalPreset) {
        presets.append(preset)
        save()
    }

    func update(_ preset: TerminalPreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[idx] = preset
        save()
    }

    func delete(id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }
}
```

- [ ] **Step 2: Build verify**

```bash
xcodebuild -project srota/srota.xcodeproj -scheme srota -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED` with no errors.

- [ ] **Step 3: Commit**

```bash
git add srota/srota/PresetsStore.swift
git commit -m "feat: add TerminalPreset model and PresetsStore"
```

---

## Task 2: Inject PresetsStore into app environment

**Files:**
- Modify: `srota/srota/srotaApp.swift`

**Interfaces:**
- Consumes: `PresetsStore` from Task 1
- Produces: `PresetsStore` available as `@Environment(PresetsStore.self)` in all views

- [ ] **Step 1: Add `presetsStore` to `srotaApp`**

Open `srota/srota/srotaApp.swift`. Add `@State private var presetsStore = PresetsStore()` and `.environment(presetsStore)`:

```swift
import SwiftUI

@main
struct srotaApp: App {
    @State private var settings = AppSettings()
    @State private var db = WorkspaceDB()
    @State private var presetsStore = PresetsStore()

    var body: some Scene {
        WindowGroup("Srota - स्रोत") {
            ContentView()
                .preferredColorScheme(.dark)
                .environment(settings)
                .environment(db)
                .environment(presetsStore)
                .onAppear {
                    setupShellIntegration()
                    if let dir = settings.baseWorkingDirectory { db.scan(baseDir: dir) }
                }
        }
    }
}
```

(Leave `setupShellIntegration()` function unchanged below.)

- [ ] **Step 2: Build verify**

```bash
xcodebuild -project srota/srota.xcodeproj -scheme srota -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add srota/srota/srotaApp.swift
git commit -m "feat: inject PresetsStore into app environment"
```

---

## Task 3: SettingsView — full settings UI

**Files:**
- Create: `srota/srota/SettingsView.swift`

**Interfaces:**
- Consumes: `PresetsStore` (via `@Environment(PresetsStore.self)`), `TerminalPreset` from Task 1
- Produces: `struct SettingsPanel: View` — takes `isPresented: Binding<Bool>`

- [ ] **Step 1: Create `SettingsView.swift`**

```swift
import SwiftUI

// MARK: - Design tokens

private extension Color {
    static let stBg      = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let stSurface = Color(red: 0.10,  green: 0.10,  blue: 0.11)
    static let stBorder  = Color.white.opacity(0.07)
    static let stAccent  = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let stLabel   = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let stMuted   = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.40)
}

// MARK: - Panel

struct SettingsPanel: View {
    @Binding var isPresented: Bool
    @Environment(PresetsStore.self) private var store
    @State private var editingPreset: TerminalPreset? = nil
    @State private var showAdd = false

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(onBack: { isPresented = false })
                .frame(width: 200)
            Rectangle().fill(Color.stBorder).frame(width: 1)
            TerminalSettingsView(
                onEdit: { editingPreset = $0 },
                onAdd:  { showAdd = true }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.stBg)
        .sheet(item: $editingPreset) { preset in
            PresetEditSheet(
                preset: preset,
                isNew: false,
                onSave:   { store.update($0) },
                onDelete: { store.delete(id: preset.id) }
            )
        }
        .sheet(isPresented: $showAdd) {
            PresetEditSheet(
                preset: TerminalPreset(name: "", commands: [""]),
                isNew: true,
                onSave:   { if !$0.name.isEmpty { store.add($0) } },
                onDelete: nil
            )
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: onBack) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 11, weight: .medium))
                    Text("Back")
                        .font(.system(size: 13))
                }
                .foregroundStyle(Color.stMuted)
            }
            .buttonStyle(.plain)
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 6)

            Text("Settings")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Color.stLabel)
                .padding(.horizontal, 16)
                .padding(.bottom, 12)

            SidebarRow(label: "Terminal", icon: "terminal", isSelected: true)

            Spacer()
        }
        .frame(maxHeight: .infinity)
        .background(Color.stBg)
    }
}

private struct SidebarRow: View {
    let label: String
    let icon: String
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? Color.stAccent : Color.stMuted)
                .frame(width: 16)
            Text(label)
                .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? Color.stLabel : Color.stMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.stAccent.opacity(0.12) : Color.clear)
        .overlay(alignment: .leading) {
            if isSelected {
                Rectangle().fill(Color.stAccent).frame(width: 2)
            }
        }
    }
}

// MARK: - Terminal settings

private struct TerminalSettingsView: View {
    @Environment(PresetsStore.self) private var store
    let onEdit: (TerminalPreset) -> Void
    let onAdd: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Terminal")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.stLabel)
                    Text("Configure terminal behavior and presets")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.stMuted)
                }
                .padding(.bottom, 28)

                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Terminal Presets")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.stLabel)
                        Text("Presets let you quickly launch terminals with pre-configured commands.")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.stMuted)
                    }
                    Spacer()
                    Button(action: onAdd) {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text("Add Preset")
                                .font(.system(size: 13, weight: .medium))
                        }
                        .foregroundStyle(Color.stLabel)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.stSurface)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.stBorder))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.bottom, 12)

                // ponytail: import agent placeholder, wire later
                Button {} label: {
                    HStack(spacing: 6) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("Import agent")
                            .font(.system(size: 13))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10))
                    }
                    .foregroundStyle(Color.stLabel)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.stSurface)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.stBorder))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 12)

                if !store.presets.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(store.presets) { preset in
                            PresetRow(preset: preset)
                                .contentShape(Rectangle())
                                .onTapGesture { onEdit(preset) }
                            if preset.id != store.presets.last?.id {
                                Rectangle().fill(Color.stBorder).frame(height: 1)
                            }
                        }
                    }
                    .background(Color.stSurface)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.stBorder))
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                    Text("Click a preset row to edit details.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.stMuted)
                        .padding(.top, 8)
                }
            }
            .padding(28)
        }
        .background(Color.stBg)
    }
}

private struct PresetRow: View {
    let preset: TerminalPreset
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 13))
                .foregroundStyle(Color.stAccent)
                .frame(width: 30, height: 30)
                .background(Color.stAccent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 2) {
                Text(preset.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.stLabel)
                if let cmd = preset.commands.first(where: { !$0.isEmpty }) {
                    Text(cmd)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.stMuted)
                        .lineLimit(1)
                }
            }

            Spacer()

            Text("All projects · New tab")
                .font(.system(size: 12))
                .foregroundStyle(Color.stMuted)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(hovered ? Color.white.opacity(0.04) : Color.clear)
        .onHover { hovered = $0 }
    }
}

// MARK: - Edit sheet

struct PresetEditSheet: View {
    @State private var draft: TerminalPreset
    let isNew: Bool
    let onSave: (TerminalPreset) -> Void
    let onDelete: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    init(preset: TerminalPreset, isNew: Bool,
         onSave: @escaping (TerminalPreset) -> Void,
         onDelete: (() -> Void)?) {
        _draft = State(initialValue: preset)
        self.isNew   = isNew
        self.onSave  = onSave
        self.onDelete = onDelete
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(isNew ? "New Preset" : draft.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.stLabel)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.stMuted)
                        .frame(width: 22, height: 22)
                        .background(Color.stSurface)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 20)

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    STField(label: "Name", text: $draft.name)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Description")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.stMuted)
                        Text("Optional context shown in the presets list.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.stMuted.opacity(0.7))
                        TextField("", text: $draft.description)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.stLabel)
                            .padding(10)
                            .background(Color.stSurface)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.stBorder))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("Commands")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.stMuted)
                        Text("One command per row. Add multiple to launch a grouped preset.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.stMuted.opacity(0.7))
                        ForEach(draft.commands.indices, id: \.self) { i in
                            TextField("", text: $draft.commands[i])
                                .textFieldStyle(.plain)
                                .font(.system(size: 13, design: .monospaced))
                                .foregroundStyle(Color.stLabel)
                                .padding(10)
                                .background(Color.stSurface)
                                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.stBorder))
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        Button {
                            draft.commands.append("")
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: "plus")
                                    .font(.system(size: 10))
                                Text("Add command")
                                    .font(.system(size: 12))
                            }
                            .foregroundStyle(Color.stMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 20)
            }

            Rectangle().fill(Color.stBorder).frame(height: 1)

            HStack {
                if onDelete != nil {
                    Button(role: .destructive) {
                        onDelete?()
                        dismiss()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash")
                                .font(.system(size: 11))
                            Text("Delete preset")
                                .font(.system(size: 13))
                        }
                        .foregroundStyle(Color.red.opacity(0.8))
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
                Button("Done") {
                    onSave(draft)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(Color.stAccent)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 500)
        .background(Color.stBg)
    }
}

private struct STField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.stMuted)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.stLabel)
                .padding(10)
                .background(Color.stSurface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.stBorder))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
```

- [ ] **Step 2: Build verify**

```bash
xcodebuild -project srota/srota.xcodeproj -scheme srota -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add srota/srota/SettingsView.swift
git commit -m "feat: add SettingsPanel, TerminalSettingsView, and PresetEditSheet"
```

---

## Task 4: TopNavBar — gear icon + preset quick-launch strip

**Files:**
- Modify: `srota/srota/ManagementView.swift`

**Interfaces:**
- Consumes: `TerminalPreset`, `PresetsStore` (via `@Environment`)
- Produces: `TopNavBar` with new `onSettings: () -> Void` and `onPresetLaunch: (TerminalPreset) -> Void` parameters

- [ ] **Step 1: Add `PresetQuickLaunchButton` and update `TopNavBar`**

In `ManagementView.swift`, replace the `TopNavBar` struct (lines 44–62) with:

```swift
struct TopNavBar: View {
    @Binding var selected: ManagementTab
    var onSettings: () -> Void = {}
    var onPresetLaunch: (TerminalPreset) -> Void = { _ in }
    @Environment(PresetsStore.self) private var presetsStore

    var body: some View {
        HStack(spacing: 0) {
            ForEach(ManagementTab.allCases, id: \.self) { tab in
                TabButton(tab: tab, isActive: selected == tab) {
                    selected = tab
                }
            }

            if !presetsStore.presets.isEmpty {
                Rectangle()
                    .fill(Color.white.opacity(0.08))
                    .frame(width: 1)
                    .padding(.vertical, 9)
                ForEach(presetsStore.presets) { preset in
                    PresetQuickLaunchButton(preset: preset) {
                        onPresetLaunch(preset)
                    }
                }
            }

            Spacer()

            Button(action: onSettings) {
                Image(systemName: "gear")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mgMuted)
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        .frame(height: 36)
        .background(Color(red: 0.05, green: 0.05, blue: 0.06))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }
}

private struct PresetQuickLaunchButton: View {
    let preset: TerminalPreset
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "terminal")
                    .font(.system(size: 10))
                Text(preset.name)
                    .font(.system(size: 12))
            }
            .foregroundStyle(hovered ? Color.mgLabel : Color.mgMuted)
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}
```

Leave `TabButton` struct unchanged.

- [ ] **Step 2: Build verify**

```bash
xcodebuild -project srota/srota.xcodeproj -scheme srota -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 3: Commit**

```bash
git add srota/srota/ManagementView.swift
git commit -m "feat: add gear icon and preset quick-launch buttons to TopNavBar"
```

---

## Task 5: Wire ContentView — showSettings + SettingsPanel overlay + onPresetLaunch

**Files:**
- Modify: `srota/srota/ContentView.swift`

**Interfaces:**
- Consumes: `SettingsPanel` (Task 3), `TopNavBar` with new params (Task 4), `TerminalPreset` (Task 1)
- Produces: fully wired settings flow

- [ ] **Step 1: Add `showSettings` state to `ContentView`**

In `ContentView.swift`, the `ContentView` struct has these `@State` properties (around lines 562–569). Add `showSettings` after `restoredSessions`:

```swift
@State private var sidebarVisible = true
@State private var sidebarWidth: CGFloat = 220
@State private var showBaseDirectoryPicker = false
@State private var managementTab: ManagementTab = .workspaces
@State private var restoredSessions = false
@State private var showSettings = false
```

- [ ] **Step 2: Update `TopNavBar` call in `ContentView.body`**

Find the line (around line 574):
```swift
TopNavBar(selected: $managementTab)
```

Replace with:
```swift
TopNavBar(
    selected: $managementTab,
    onSettings: { showSettings.toggle() },
    onPresetLaunch: { preset in
        let cmd = preset.commands.filter { !$0.isEmpty }.joined(separator: "\n") + "\n"
        manager.selectedWorkspace?.selectedTab?.focusedViewState.send(cmd)
    }
)
```

- [ ] **Step 3: Add `SettingsPanel` overlay in the ZStack**

Find the block (around lines 703–710):
```swift
if managementTab != .workspaces {
    ManagementPanel(tab: managementTab)
        .environment(db)
        .environmentObject(manager)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.067, green: 0.067, blue: 0.075))
}
```

Add the settings overlay directly after it (still inside the ZStack, before `} // end ZStack`):
```swift
if showSettings {
    SettingsPanel(isPresented: $showSettings)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(red: 0.067, green: 0.067, blue: 0.075))
}
```

- [ ] **Step 4: Build verify**

```bash
xcodebuild -project srota/srota.xcodeproj -scheme srota -destination 'platform=macOS,arch=arm64' build 2>&1 | grep -E "error:|BUILD"
```
Expected: `BUILD SUCCEEDED`.

- [ ] **Step 5: Manual smoke test**

Run the app. Verify:
1. Gear icon appears on the right side of the top nav bar
2. Clicking gear opens the settings panel overlay
3. "← Back" in sidebar closes it
4. "Add Preset" opens the edit sheet; entering name + command and pressing Done saves the preset
5. Saved preset appears in the top nav bar quick-launch strip
6. Clicking the quick-launch button sends the command to the focused terminal (verify by seeing it typed in the active pane)
7. Clicking an existing preset row in the settings list opens it for editing
8. Delete preset button removes it

- [ ] **Step 6: Commit**

```bash
git add srota/srota/ContentView.swift
git commit -m "feat: wire settings overlay and preset quick-launch into ContentView"
```
