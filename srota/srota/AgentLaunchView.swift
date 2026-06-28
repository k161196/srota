import SwiftUI

private extension Color {
    static let alBg      = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let alSurface = Color(red: 0.10,  green: 0.10,  blue: 0.11)
    static let alBorder  = Color.white.opacity(0.07)
    static let alAccent  = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let alLabel   = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let alMuted   = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.40)
}

// MARK: - Popover: agent picker

struct AgentPickerPopover: View {
    let agents: [AgentItem]
    let onSelect: (AgentItem) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if agents.isEmpty {
                Text("No agents configured")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.alMuted)
                    .padding(12)
            } else {
                ForEach(agents) { agent in
                    AgentPickerRow(agent: agent) { onSelect(agent) }
                }
            }
        }
        .padding(6)
        .frame(minWidth: 220)
        .background(Color.alBg)
    }
}

private struct AgentPickerRow: View {
    let agent: AgentItem
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.name)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.alLabel)
                if !agent.description.isEmpty {
                    Text(agent.description)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.alMuted)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovered ? Color.white.opacity(0.06) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Sheet: launch config

struct AgentLaunchSheet: View {
    let agent: AgentItem
    /// systemPrompt, firstMessage, preset
    let onLaunch: (String, String, TerminalPreset?) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(AgentsStore.self)  private var agentsStore
    @Environment(PresetsStore.self) private var presetsStore

    @State private var systemPrompt  = ""
    @State private var firstMessage  = ""
    @State private var selectedPreset: TerminalPreset? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.alAccent)
                Text(agent.name)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.alLabel)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.alMuted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Rectangle().fill(Color.alBorder).frame(height: 1)

            // System prompt
            VStack(alignment: .leading, spacing: 0) {
                Text("System Prompt")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.alMuted)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                TextEditor(text: $systemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(Color.alLabel)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Color.alBorder).frame(height: 1)

            // First message
            VStack(alignment: .leading, spacing: 0) {
                Text("First Message")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.alMuted)
                    .padding(.horizontal, 16)
                    .padding(.top, 10)
                    .padding(.bottom, 4)
                TextEditor(text: $firstMessage)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.alLabel)
                    .scrollContentBackground(.hidden)
                    .background(Color.clear)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 90)

            Rectangle().fill(Color.alBorder).frame(height: 1)

            // Footer
            HStack(spacing: 12) {
                // ponytail: Menu over custom dropdown, add search if preset list grows large
                if !presetsStore.presets.isEmpty {
                    Menu {
                        ForEach(presetsStore.presets) { preset in
                            Button(preset.name) { selectedPreset = preset }
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Text(selectedPreset?.name ?? "Select preset")
                                .font(.system(size: 12))
                                .foregroundStyle(selectedPreset == nil ? Color.alMuted : Color.alLabel)
                            Image(systemName: "chevron.up.chevron.down")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.alMuted)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.alSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.alBorder))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                Spacer()

                Button("Cancel") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13))
                    .foregroundStyle(Color.alMuted)

                Button("Send") {
                    onLaunch(systemPrompt, firstMessage, selectedPreset)
                    dismiss()
                }
                .buttonStyle(.plain)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.alAccent)
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Color.alAccent.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 600, height: 480)
        .background(Color.alBg)
        .onAppear {
            systemPrompt  = agentsStore.systemPrompt(for: agent)
            firstMessage  = agentsStore.firstMessage(for: agent)
            if let pid = agent.presetID {
                selectedPreset = presetsStore.presets.first { $0.id == pid }
            }
        }
    }
}
