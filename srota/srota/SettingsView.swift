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

private enum SettingsSection { case terminal, shortcuts, agents, mcp, daemon }

struct SettingsPanel: View {
    @Binding var isPresented: Bool
    @Environment(PresetsStore.self) private var store
    @State private var activeSheet: SettingsSheet? = nil
    @State private var section: SettingsSection = .terminal

    enum SettingsSheet: Identifiable {
        case add
        case edit(TerminalPreset)
        var id: String {
            switch self {
            case .add: return "add"
            case .edit(let p): return p.id.uuidString
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSidebar(onBack: { isPresented = false }, section: $section)
                .frame(width: 200)
            Rectangle().fill(Color.stBorder).frame(width: 1)
            switch section {
            case .terminal:
                TerminalSettingsView(
                    onEdit: { activeSheet = .edit($0) },
                    onAdd:  { activeSheet = .add }
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .shortcuts:
                ShortcutsSettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .agents:
                AgentsSettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .mcp:
                MCPSettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .daemon:
                DaemonSettingsView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.stBg)
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add:
                PresetEditSheet(
                    preset: TerminalPreset(name: "", commands: [""]),
                    isNew: true,
                    onSave:   { if !$0.name.isEmpty { store.add($0) } },
                    onDelete: nil
                )
            case .edit(let preset):
                PresetEditSheet(
                    preset: preset,
                    isNew: false,
                    onSave:   { store.update($0) },
                    onDelete: { store.delete(id: preset.id) }
                )
            }
        }
    }
}

// MARK: - Sidebar

private struct SettingsSidebar: View {
    let onBack: () -> Void
    @Binding var section: SettingsSection

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

            SidebarRow(label: "Terminal", icon: "terminal", isSelected: section == .terminal)
                .onTapGesture { section = .terminal }
            SidebarRow(label: "Shortcuts", icon: "keyboard", isSelected: section == .shortcuts)
                .onTapGesture { section = .shortcuts }
            SidebarRow(label: "Agents", icon: "sparkles", isSelected: section == .agents)
                .onTapGesture { section = .agents }
            SidebarRow(label: "MCP", icon: "network", isSelected: section == .mcp)
                .onTapGesture { section = .mcp }
            SidebarRow(label: "Processes", icon: "square.stack.3d.up", isSelected: section == .daemon)
                .onTapGesture { section = .daemon }

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

// MARK: - Shortcuts settings

private struct ShortcutsSettingsView: View {
    @Environment(AppSettings.self) private var settings

    private let bindings: [(key: String, action: String)] = [
        ("c",   "New tab"),
        ("x",   "Close tab"),
        ("n",   "Next tab"),
        ("p",   "Previous tab"),
        ("1–9", "Select tab by number"),
        ("v",   "Split right"),
        ("s",   "Split down"),
        ("h",   "Focus pane left"),
        ("j",   "Focus pane down"),
        ("k",   "Focus pane up"),
        ("l",   "Focus pane right"),
    ]

    var body: some View {
        @Bindable var settings = settings
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Keyboard Shortcuts")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.stLabel)
                    Text("Tmux-style prefix key. Press prefix, then a key to trigger an action.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.stMuted)
                }
                .padding(.bottom, 28)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Prefix Key")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.stLabel)
                    Text("Click to record a new shortcut. Press Escape to cancel.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.stMuted)
                    PrefixKeyRecorder(value: $settings.shortcutPrefix)
                        .frame(width: 120, height: 36)
                        .onChange(of: settings.shortcutPrefix) { _, _ in settings.save() }
                }
                .padding(.bottom, 28)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Default Bindings")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.stLabel)
                    VStack(spacing: 0) {
                        ForEach(bindings, id: \.key) { b in
                            HStack {
                                Text(b.action)
                                    .font(.system(size: 13))
                                    .foregroundStyle(Color.stLabel)
                                Spacer()
                                Text(b.key)
                                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                                    .foregroundStyle(Color.stAccent)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 3)
                                    .background(Color.stAccent.opacity(0.1))
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            if b.key != bindings.last?.key {
                                Rectangle().fill(Color.stBorder).frame(height: 1)
                            }
                        }
                    }
                    .background(Color.stSurface)
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.stBorder))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(28)
        }
        .background(Color.stBg)
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
                            HStack(spacing: 8) {
                                TextField("", text: $draft.commands[i])
                                    .textFieldStyle(.plain)
                                    .font(.system(size: 13, design: .monospaced))
                                    .foregroundStyle(Color.stLabel)
                                    .padding(10)
                                    .background(Color.stSurface)
                                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.stBorder))
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                                if draft.commands.count > 1 {
                                    Button {
                                        draft.commands.remove(at: i)
                                    } label: {
                                        Image(systemName: "minus.circle")
                                            .font(.system(size: 14))
                                            .foregroundStyle(Color.stMuted)
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
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

                    VStack(alignment: .leading, spacing: 6) {
                        Text("System Prompt")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.stMuted)
                        Text("Appended at launch. Shown read-only in the Prompts panel.")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.stMuted.opacity(0.7))
                        TextEditor(text: $draft.systemPrompt)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.stLabel)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(minHeight: 80)
                            .background(Color.stSurface)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.stBorder))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("System Prompt Flag")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.stMuted)
                        Text("Flag to pass the prompt (e.g. --system-prompt). Empty = positional first arg (e.g. codex 'PROMPT').")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.stMuted.opacity(0.7))
                        TextField("--system-prompt", text: $draft.systemPromptFlag)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.stLabel)
                            .padding(10)
                            .background(Color.stSurface)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.stBorder))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
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
                let nameIsEmpty = draft.name.trimmingCharacters(in: .whitespaces).isEmpty
                Button("Done") {
                    onSave(draft)
                    dismiss()
                }
                .disabled(nameIsEmpty)
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(nameIsEmpty ? Color.black.opacity(0.4) : Color.black)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(nameIsEmpty ? Color.stAccent.opacity(0.4) : Color.stAccent)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 500)
        .background(Color.stBg)
    }
}

// MARK: - MCP settings

private struct MCPSettingsView: View {
    @Environment(AppSettings.self) private var settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("MCP Server")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.stLabel)
                    Text("The srota MCP server is installed automatically and kept up to date with the app.")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.stMuted)
                }
                .padding(.bottom, 28)

                if let path = settings.resolvedMCPServerPath {
                    MCPPromptBlock(
                        title: "MCP Setup",
                        subtitle: "bun \"\(path)\"",
                        content: "The srota MCP server is located at:\n\(path)\n\nTo run it:\nbun \"\(path)\"\n\nAdd it as an MCP server in your agent config with:\n  command: bun\n  args: [\"\(path)\"]"
                    )
                } else {
                    Text("Not installed yet — relaunch the app to trigger installation.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.red.opacity(0.7))
                }
            }
            .padding(28)
        }
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

// MARK: - Agents settings

private struct AgentsSettingsView: View {
    @Environment(AgentsStore.self)  private var store
    @Environment(PresetsStore.self) private var presetsStore

    @State private var selectedID:   UUID? = nil
    @State private var pendingNewID: UUID? = nil
    @State private var editName         = ""
    @State private var editDescription  = ""
    @State private var editSystemPrompt  = ""
    @State private var editFirstMessage  = ""
    @State private var editPresetID:    UUID? = nil
    @State private var editRunInTempDir = false
    private var isNew: Bool { pendingNewID == selectedID && selectedID != nil }

    private var selected: AgentItem? { store.agents.first { $0.id == selectedID } }

    var body: some View {
        HStack(spacing: 0) {
            // Agent list
            VStack(spacing: 0) {
                HStack {
                    Text("Agents")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.stLabel)
                    Spacer()
                    Button(action: startNew) {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.stAccent)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)

                Rectangle().fill(Color.stBorder).frame(height: 1)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(store.agents) { agent in
                            AgentListRow(agent: agent, isSelected: selectedID == agent.id) {
                                load(agent)
                            }
                        }
                    }
                    .padding(8)
                }
            }
            .frame(width: 200)

            Rectangle().fill(Color.stBorder).frame(width: 1)

            // Detail / editor
            if selectedID != nil {
                VStack(alignment: .leading, spacing: 0) {
                    TextField("Name", text: $editName)
                        .textFieldStyle(.plain)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.stLabel)
                        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 4)

                    TextField("Short description…", text: $editDescription)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.stMuted)
                        .padding(.horizontal, 20).padding(.bottom, 10)

                    Rectangle().fill(Color.stBorder).frame(height: 1)

                    // System Prompt
                    HStack {
                        Text("System Prompt")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.stMuted)
                        Spacer()
                        if selected?.isBuiltIn == true {
                            Button("Reset to default") {
                                if let agent = selected {
                                    store.resetToDefault(agent: agent)
                                    editSystemPrompt = store.systemPrompt(for: agent)
                                    editFirstMessage = store.firstMessage(for: agent)
                                }
                            }
                            .buttonStyle(.plain)
                            .font(.system(size: 11))
                            .foregroundStyle(Color.stAccent)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)
                    .padding(.bottom, 2)

                    TextEditor(text: $editSystemPrompt)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.stLabel)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    Rectangle().fill(Color.stBorder).frame(height: 1)

                    // First Message
                    Text("First Message")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.stMuted)
                        .padding(.horizontal, 14)
                        .padding(.top, 10)
                        .padding(.bottom, 2)

                    TextEditor(text: $editFirstMessage)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.stLabel)
                        .scrollContentBackground(.hidden)
                        .background(Color.clear)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity)
                        .frame(height: 80)

                    Rectangle().fill(Color.stBorder).frame(height: 1)

                    HStack(spacing: 10) {
                        // Preset picker
                        if !presetsStore.presets.isEmpty {
                            Menu {
                                ForEach(presetsStore.presets) { p in
                                    Button(p.name) { editPresetID = p.id }
                                }
                            } label: {
                                HStack(spacing: 4) {
                                    Text(presetsStore.presets.first { $0.id == editPresetID }?.name ?? "Select preset")
                                        .font(.system(size: 12))
                                        .foregroundStyle(editPresetID == nil ? Color.stMuted : Color.stLabel)
                                    Image(systemName: "chevron.up.chevron.down")
                                        .font(.system(size: 9))
                                        .foregroundStyle(Color.stMuted)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.stSurface)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.stBorder))
                            }
                            .menuStyle(.borderlessButton).fixedSize()
                        }

                        Toggle("Temp dir", isOn: $editRunInTempDir)
                            .toggleStyle(.switch)
                            .font(.system(size: 12))
                            .foregroundStyle(Color.stMuted)
                            .fixedSize()

                        Spacer()

                        if !isNew && selected?.isBuiltIn != true {
                            Button("Delete") {
                                if let id = selectedID { store.delete(id: id); selectedID = nil }
                            }
                            .buttonStyle(.plain).font(.system(size: 12))
                            .foregroundStyle(Color.red.opacity(0.7))
                        }

                        Button("Save", action: saveEdit)
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.stAccent)
                            .padding(.horizontal, 14).padding(.vertical, 5)
                            .background(Color.stAccent.opacity(0.12))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .padding(.horizontal, 20).padding(.vertical, 12)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack {
                    Text("Select or add an agent")
                        .font(.system(size: 13)).foregroundStyle(Color.stMuted)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Color.stBg)
    }

    private func load(_ agent: AgentItem) {
        pendingNewID    = nil
        selectedID      = agent.id
        editName        = agent.name
        editDescription = agent.description
        editSystemPrompt = store.systemPrompt(for: agent)
        editFirstMessage = store.firstMessage(for: agent)
        editPresetID     = agent.presetID
        editRunInTempDir = agent.runInTempDir
    }

    private func startNew() {
        let id       = UUID()
        pendingNewID = id
        selectedID   = id
        editName = ""; editDescription = ""
        editSystemPrompt = ""; editFirstMessage = ""
        editPresetID = nil; editRunInTempDir = false
    }

    private func saveEdit() {
        guard let id = selectedID else { return }
        let label = editName.isEmpty ? id.uuidString : editName
        let existing = store.agents.first { $0.id == id }
        let sysPath   = existing?.instructionsPath  ?? store.newSystemPromptPath(for: label)
        let firstPath = existing?.firstMessagePath  ?? (editFirstMessage.isEmpty ? nil : store.newFirstMessagePath(for: label))
        store.saveSystemPrompt(editSystemPrompt, to: sysPath)
        if let fp = firstPath { store.saveFirstMessage(editFirstMessage, to: fp) }
        let item = AgentItem(id: id, name: editName, description: editDescription,
                             instructionsPath: sysPath,
                             firstMessagePath: editFirstMessage.isEmpty ? nil : (firstPath ?? store.newFirstMessagePath(for: label)),
                             presetID: editPresetID,
                             runInTempDir: editRunInTempDir,
                             isBuiltIn: existing?.isBuiltIn ?? false)
        if isNew { store.add(item); pendingNewID = nil } else { store.update(item) }
    }
}

private struct AgentListRow: View {
    let agent: AgentItem
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name.isEmpty ? "Untitled" : agent.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.stLabel).lineLimit(1)
                if !agent.description.isEmpty {
                    Text(agent.description)
                        .font(.system(size: 11)).foregroundStyle(Color.stMuted).lineLimit(1)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(isSelected ? Color.stAccent.opacity(0.12)
                        : hovered  ? Color.white.opacity(0.05) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Daemon process list

private struct LaunchdStatus {
    var pid: Int32?          // nil = not running
    var lastExitStatus: Int?
    var plistInstalled: Bool
    var binaryPath: String?
}

private func loadLaunchdStatus() -> LaunchdStatus {
    let plistPath = "\(NSHomeDirectory())/Library/LaunchAgents/\(daemonLabel).plist"
    let plistInstalled = FileManager.default.fileExists(atPath: plistPath)

    // Find binary (mirrors DaemonLifecycle.findDaemonBinary logic)
    let fm = FileManager.default
    let bundleExe = Bundle.main.executableURL?
        .deletingLastPathComponent().appendingPathComponent("srota-daemon").path
    let devExe = Bundle.main.executableURL?
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("srota-daemon").path
    let binaryPath = [bundleExe, devExe].compactMap { $0 }.first { fm.fileExists(atPath: $0) }

    // launchctl list <daemonLabel> → "<PID|->\t<exit>\t<label>"
    var pid: Int32? = nil
    var lastExitStatus: Int? = nil
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    task.arguments = ["list", daemonLabel]
    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = Pipe()
    if (try? task.run()) != nil {
        task.waitUntilExit()
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let cols = out.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\t")
        if cols.count >= 2 {
            pid = Int32(cols[0])
            lastExitStatus = Int(cols[1])
        }
    }

    return LaunchdStatus(pid: pid, lastExitStatus: lastExitStatus,
                         plistInstalled: plistInstalled, binaryPath: binaryPath)
}

private func restartDaemon() {
    let domain = "gui/\(getuid())"
    let label  = daemonLabel
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    // kickstart -k kills the running instance and starts a fresh one
    task.arguments = ["kickstart", "-k", "\(domain)/\(label)"]
    try? task.run()
    task.waitUntilExit()
}

private struct DaemonSettingsView: View {
    @Environment(DaemonConnection.self) private var daemon
    @State private var panes: [PTYInfo] = []
    @State private var launchd = LaunchdStatus(pid: nil, lastExitStatus: nil,
                                               plistInstalled: false, binaryPath: nil)
    @State private var isLoading = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {

                // ── Header ──────────────────────────────────────
                HStack(alignment: .top) {
                    Text("PTY Daemon")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.stLabel)
                    Spacer()
                    Button { Task { await refresh() } } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(isLoading ? Color.stMuted.opacity(0.4) : Color.stMuted)
                    }
                    .buttonStyle(.plain)
                    .disabled(isLoading)
                }
                .padding(.bottom, 20)

                // ── Status card ──────────────────────────────────
                VStack(alignment: .leading, spacing: 0) {
                    StatusRow(label: "Launchd agent",
                              ok: launchd.plistInstalled,
                              value: launchd.plistInstalled ? "Installed" : "Not installed")
                    Divider().background(Color.stBorder)
                    StatusRow(label: "Daemon process",
                              ok: launchd.pid != nil || daemon.isConnected,
                              value: launchd.pid.map { "Running (PID \($0))" }
                                  ?? (daemon.isConnected ? "Running" :
                                      launchd.lastExitStatus.map { "Stopped (exit \($0))" } ?? "Not running"))
                    Divider().background(Color.stBorder)
                    StatusRow(label: "Socket",
                              ok: daemon.isConnected,
                              value: daemon.isConnected ? "Connected" : "Not connected")
                    Divider().background(Color.stBorder)
                    StatusRow(label: "Binary",
                              ok: launchd.binaryPath != nil,
                              value: launchd.binaryPath.map { URL(fileURLWithPath: $0).lastPathComponent + " found" }
                                  ?? "Not found")
                }
                .background(Color.stSurface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.stBorder))
                .padding(.bottom, 12)

                // ── Restart button ───────────────────────────────
                Button {
                    Task.detached { restartDaemon() }
                    Task {
                        try? await Task.sleep(nanoseconds: 600_000_000)
                        await refresh()
                    }
                } label: {
                    Text("Restart Daemon")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.stLabel)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.stSurface)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.stBorder))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.bottom, 28)

                // ── Process list ─────────────────────────────────
                Text("Processes")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.stLabel)
                    .padding(.bottom, 10)

                if panes.isEmpty {
                    Text(isLoading ? "Loading…" : daemon.isConnected ? "No active PTY processes" : "Daemon not connected")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.stMuted)
                } else {
                    VStack(spacing: 1) {
                        ForEach(panes, id: \.paneID) { pane in
                            PTYProcessRow(pane: pane) {
                                daemon.killPane(paneID: pane.paneID)
                                Task { try? await Task.sleep(nanoseconds: 1_200_000_000); await refresh() }
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.stBorder))
                }
            }
            .padding(24)
        }
        .task { await refresh() }
    }

    private func refresh() async {
        launchd = loadLaunchdStatus()
        guard daemon.isConnected else { return }
        isLoading = true
        defer { isLoading = false }
        panes = (try? await daemon.list()) ?? []
    }
}

private struct StatusRow: View {
    let label: String
    let ok: Bool
    let value: String

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(ok ? Color.green.opacity(0.8) : Color(red: 0.7, green: 0.2, blue: 0.2).opacity(0.8))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Color.stMuted)
            Spacer()
            Text(value)
                .font(.system(size: 12).monospaced())
                .foregroundStyle(Color.stLabel)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct PTYProcessRow: View {
    let pane: PTYInfo
    let onKill: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(pane.exitCode == nil ? Color.green.opacity(0.75) : Color.stMuted.opacity(0.4))
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 10) {
                    Text("PID \(pane.pid)")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.stLabel)
                    if let code = pane.exitCode {
                        Text("exited(\(code))")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.stMuted)
                    }
                }
                Text(pane.cwd.isEmpty ? "—" : pane.cwd)
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(Color.stMuted)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            if pane.exitCode == nil {
                Button(action: onKill) {
                    Text("Kill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.stMuted)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Color.stSurface)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.stBorder))
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.stSurface)
    }
}
