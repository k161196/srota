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
    @State private var activeSheet: SettingsSheet? = nil

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
            SettingsSidebar(onBack: { isPresented = false })
                .frame(width: 200)
            Rectangle().fill(Color.stBorder).frame(width: 1)
            TerminalSettingsView(
                onEdit: { activeSheet = .edit($0) },
                onAdd:  { activeSheet = .add }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
