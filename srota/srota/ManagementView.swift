import SwiftUI
import AppKit
import GhosttyTerminal

extension Notification.Name {
    static let srotaOpenWorkspace    = Notification.Name("srota.openWorkspace")
    static let srotaWorkspaceClosed  = Notification.Name("srota.workspaceClosed")
    static let srotaTabClosed        = Notification.Name("srota.tabClosed")
}

// MARK: - Top-level tab enum

enum ManagementTab: String, CaseIterable {
    case tasks           = "Tasks"
    case workspaces      = "Workspaces"
    case agents          = "Agents"
    case repos           = "Repos"
    case githubProjects  = "Projects"

    var icon: String {
        switch self {
        case .tasks:          return "checklist"
        case .workspaces:     return "terminal"
        case .agents:         return "bolt.fill"
        case .repos:          return "square.and.arrow.down"
        case .githubProjects: return "folder"
        }
    }
}

// MARK: - Design tokens (local, matching app palette)

private extension Color {
    static let mgBg        = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let mgSurface   = Color(red: 0.10,  green: 0.10,  blue: 0.11)
    static let mgBorder    = Color.white.opacity(0.07)
    static let mgAccent    = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let mgLabel     = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let mgMuted     = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.40)
    static let mgRow       = Color.white.opacity(0.035)
    static let mgRowHover  = Color.white.opacity(0.065)
}

// MARK: - Top nav bar

struct TopNavBar: View {
    @Binding var selected: ManagementTab
    var onSettings: () -> Void = {}
    var onPrompts: () -> Void = {}
    var onPresetLaunch: (TerminalPreset) -> Void = { _ in }
    var onAgentSelected: (AgentItem) -> Void = { _ in }
    @Environment(PresetsStore.self) private var presetsStore
    @Environment(AgentsStore.self)  private var agentsStore
    @State private var showAgentPicker = false

    // Below this nav-bar width, the "Srota" wordmark is dropped to leave room for tabs.
    private static let wordmarkMinWidth: CGFloat = 640

    var body: some View {
        GeometryReader { geo in
        HStack(spacing: 0) {
            Color.clear.frame(width: 78) // ponytail: reserves space for traffic-light buttons (hiddenTitleBar overlays them here)

            HStack(spacing: 6) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 18, height: 18)
                if geo.size.width > Self.wordmarkMinWidth {
                    Text("Srota")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.mgLabel)
                        .fixedSize()
                }
            }
            .padding(.trailing, 12)

            Rectangle()
                .fill(Color.white.opacity(0.08))
                .frame(width: 1)
                .padding(.vertical, 9)
                .padding(.trailing, 8)

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

            Button(action: { showAgentPicker.toggle() }) {
                Image(systemName: "sparkles")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mgMuted)
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showAgentPicker, arrowEdge: .bottom) {
                AgentPickerPopover(agents: agentsStore.agents) { agent in
                    showAgentPicker = false
                    onAgentSelected(agent)
                }
            }

            Button(action: onPrompts) {
                Image(systemName: "note.text")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mgMuted)
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.plain)

            Button(action: onSettings) {
                Image(systemName: "gear")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mgMuted)
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
        }
        }
        .frame(height: 36)
        .background(Color(red: 0.05, green: 0.05, blue: 0.06))
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
        }
    }
}

private struct TabButton: View {
    let tab: ManagementTab
    let isActive: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: tab.icon)
                    .font(.system(size: 11))
                Text(tab.rawValue)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
            }
            .foregroundStyle(isActive ? Color.mgAccent : (hovered ? Color.mgLabel : Color.mgMuted))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(
            fill: isActive ? Color.mgAccent.opacity(0.12) : Color.clear,
            borderTop: isActive ? Color.mgAccent.opacity(0.4) : Color.clear,
            borderBottom: isActive ? Color.mgAccent.opacity(0.22) : Color.clear,
            radius: 7
        )
        .padding(.horizontal, 2)
        .onHover { hovered = $0 }
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
                    .lineLimit(1)
                    .fixedSize()
            }
            .foregroundStyle(hovered ? Color.mgLabel : Color.mgMuted)
            .padding(.horizontal, 12)
            .frame(height: 36)
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
    }
}

// MARK: - Management panel router

struct ManagementPanel: View {
    let tab: ManagementTab
    @Environment(WorkspaceDB.self) var db

    var body: some View {
        switch tab {
        case .tasks:          TasksPanel()
        case .workspaces:     EmptyView()  // handled by ContentView
        case .agents:         AgentsPanel()
        case .repos:          ReposPanel()
        case .githubProjects: GitHubProjectsPanel()
        }
    }
}

// MARK: - Agents panel (split view: daemon-tracked agents on the left, an attached live terminal on the right)

private struct DaemonAgentRow: Identifiable {
    let stableID: String
    let cwd: String
    let title: String
    let status: AgentRunStatus?
    let agentName: String
    let updatedAt: Double
    let workspaceID: UUID?
    let folderName: String?
    let folderTag: String?
    var id: String { stableID }
}

// A PTY has exactly one live owner at a time (see DaemonConnection.spawnOrAttach). Attaching from
// the Agents tab never jumps to Workspaces — it either attaches directly (nothing else owns this
// PTY) or, if a workspace pane already owns it, shows a "Use Here" button to claim it explicitly,
// mirroring the same button an unstarted pane shows. Claiming here flips the workspace pane back
// to its own "Use Here" overlay via the onStolen callback, and vice versa.
private struct AgentsPanel: View {
    @EnvironmentObject var manager: TerminalManager
    @Environment(DaemonConnection.self) private var daemon
    @Environment(\.colorScheme) private var colorScheme

    @State private var allPanes: [PTYInfo] = []
    @State private var showAllProcesses = false
    @State private var selectedStableID: String?
    @State private var attachment: AgentAttachment?

    private var rows: [DaemonAgentRow] {
        let states = daemon.agentStatesByStableID
        let openTitles = Dictionary(uniqueKeysWithValues: manager.allWorkspaces.flatMap { ws in
            ws.tabs.flatMap { tab in
                tab.panes.compactMap { pane -> (String, String)? in
                    guard let name = tab.paneNames[pane.id], !name.isEmpty else { return nil }
                    return (pane.daemonStableID, name)
                }
            }
        })
        let workspaceIDsByStableID = Dictionary(uniqueKeysWithValues: manager.allWorkspaces.flatMap { ws in
            ws.tabs.flatMap { tab in tab.panes.map { ($0.daemonStableID, ws.id) } }
        })
        return allPanes
            .filter { $0.exitCode == nil }
            .compactMap { pane -> DaemonAgentRow? in
                let state = states[pane.stableID]
                guard showAllProcesses || (state?.status != nil && state?.status != .done) else { return nil }
                let fallbackTitle = smartTitle(for: pane.cwd)
                let workspaceID = workspaceIDsByStableID[pane.stableID]
                let folder = workspaceID.flatMap { wsID in manager.folders.first { $0.workspaces.contains { $0.id == wsID } } }
                return DaemonAgentRow(
                    stableID: pane.stableID, cwd: pane.cwd,
                    title: openTitles[pane.stableID] ?? fallbackTitle,
                    status: state?.status, agentName: state?.agent ?? "", updatedAt: state?.updatedAt ?? 0,
                    workspaceID: workspaceID, folderName: folder?.name, folderTag: folder?.tag
                )
            }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var claimedElsewhereStableIDs: Set<String> {
        Set(manager.allWorkspaces.flatMap { ws in
            ws.tabs.flatMap { tab in tab.panes.filter(\.isStarted).map(\.daemonStableID) }
        })
    }

    private var selectedRow: DaemonAgentRow? { rows.first { $0.stableID == selectedStableID } }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                header
                Rectangle().fill(Color.mgBorder).frame(height: 1)
                if rows.isEmpty {
                    Spacer()
                    Text(showAllProcesses ? "No terminals running" : "No agents running")
                        .font(.system(size: 13))
                        .foregroundStyle(Color.mgMuted)
                    Spacer()
                } else {
                    ScrollView {
                        VStack(spacing: 2) {
                            ForEach(rows) { row in
                                DaemonAgentRowView(
                                    row: row,
                                    isSelected: row.stableID == selectedStableID
                                ) {
                                    selectedStableID = row.stableID
                                    attachment = nil
                                }
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                    }
                }
            }
            .frame(width: 280)

            Rectangle().fill(Color.mgBorder).frame(width: 1)

            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear { refresh() }
        .onChange(of: daemon.agentStatesByStableID.count) { _, _ in refresh() }
        .onChange(of: rows.map(\.stableID)) { _, ids in
            guard selectedStableID == nil || !ids.contains(selectedStableID!) else { return }
            selectedStableID = rows.first?.stableID
            attachment = nil
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let row = selectedRow {
            if let attachment, attachment.stableID == row.stableID {
                TerminalSurfaceView(context: attachment.viewState)
            } else if claimedElsewhereStableIDs.contains(row.stableID) {
                PaneStartOverlay(cwd: row.cwd, label: "Use Here") { attach(row) }
            } else {
                Color.clear.id(row.stableID).onAppear { attach(row) }
            }
        } else {
            VStack {
                Spacer()
                Text("Select an agent")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mgMuted)
                Spacer()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Text("Agents")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.mgLabel)
            Text("\(rows.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Color.mgMuted)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.mgSurface)
                .clipShape(Capsule())
            Spacer()
            Button { refresh() } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.mgMuted)
            }
            .buttonStyle(.plain)
            .help("Refresh from daemon")
            Menu {
                Toggle("Show all terminals", isOn: $showAllProcesses)
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mgMuted)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func refresh() {
        Task {
            if let panes = try? await daemon.list() { allPanes = panes }
        }
    }

    private func attach(_ row: DaemonAgentRow) {
        let token = UUID()
        let attachmentBinding = $attachment
        attachment = AgentAttachment(stableID: row.stableID, cwd: row.cwd, colorScheme: colorScheme, daemon: daemon, token: token) {
            // Only clear if `attachment` is still THIS instance — re-selecting a previously-viewed
            // agent steals from its own stale claim, and that old callback fires async afterward;
            // without this check it would wipe out the brand-new attachment it just raced against.
            if attachmentBinding.wrappedValue?.token == token {
                attachmentBinding.wrappedValue = nil
            }
        }
    }
}

// Mirrors TerminalTab's own pane-attach pattern exactly — this is just another consumer of
// spawnOrAttach, not a separate "secondary" mechanism. Note: switching the Agents-tab selection
// away doesn't currently release this claim (no explicit detach primitive exists yet), so the
// underlying PTY keeps streaming to this now-unviewed session until something else steals it —
// harmless (no corruption), just an unclaimed background listener.
private final class AgentAttachment {
    let stableID: String
    let token: UUID
    let viewState: TerminalViewState

    init(stableID: String, cwd: String, colorScheme: ColorScheme, daemon: DaemonConnection, token: UUID, onStolen: @escaping () -> Void) {
        self.stableID = stableID
        self.token = token
        let state = TerminalViewState(terminalConfiguration: TerminalConfiguration())
        let ref = DaemonPaneRef()
        let session = InMemoryTerminalSession(
            write: { [weak daemon, ref] data in
                guard let paneID = ref.id, !ref.isReplayingBuffer else { return }
                daemon?.sendInput(paneID: paneID, data: data)
            },
            resize: { [weak daemon, ref] vp in
                guard let paneID = ref.id else {
                    ref.storePendingResize(rows: vp.rows, cols: vp.columns)
                    return
                }
                daemon?.resize(paneID: paneID, rows: vp.rows, cols: vp.columns)
            }
        )
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session), workingDirectory: cwd.isEmpty ? nil : cwd)
        state.setTheme(.default)
        state.controller.setColorScheme(colorScheme == .dark ? .dark : .light)
        viewState = state
        daemon.spawnOrAttach(
            stableID: stableID, cwd: cwd.isEmpty ? NSHomeDirectory() : cwd, env: [:],
            session: session, into: ref, onStolen: onStolen
        )
    }
}

private struct DaemonAgentRowView: View {
    let row: DaemonAgentRow
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var isHovered = false

    var body: some View {
        let statusColor = row.status?.color ?? Color.mgMuted
        Button(action: onSelect) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(row.title)
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(Color.mgLabel)
                            .lineLimit(1)
                        if isSelected {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.mgAccent)
                        }
                    }
                    if let status = row.status {
                        Text("\(status.label.lowercased()) · \(row.agentName)")
                            .font(.system(size: 11))
                            .foregroundStyle(status.color)
                            .lineLimit(1)
                    } else {
                        Text("no agent")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.mgMuted)
                            .lineLimit(1)
                    }
                    if let folderName = row.folderName, !folderName.isEmpty {
                        HStack(spacing: 4) {
                            Text(folderName)
                            if let folderTag = row.folderTag, !folderTag.isEmpty {
                                Text("· \(folderTag)")
                                    .truncationMode(.tail)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mgMuted)
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Circle()
                    .fill(row.status?.color ?? Color.mgMuted.opacity(0.4))
                    .frame(width: 7, height: 7)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(
            fill: isSelected ? Color.mgAccent.opacity(0.14) : statusColor.opacity(isHovered ? 0.1 : 0.06),
            borderTop: statusColor.opacity(0.35),
            borderBottom: statusColor.opacity(0.18),
            radius: 6
        )
        .onHover { isHovered = $0 }
    }
}

// MARK: - Shared list scaffold

private struct EntityList<T: Identifiable & Hashable, Row: View, Form: View>: View {
    let title: String
    let items: [T]
    let onDelete: (T) -> Void
    @ViewBuilder var rowContent: (T) -> Row
    @ViewBuilder var addForm: (Binding<Bool>) -> Form

    @State private var showAdd = false
    @State private var hovered: T?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mgLabel)
                Text("\(items.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.mgMuted)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.mgSurface)
                    .clipShape(Capsule())
                Spacer()
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.mgAccent)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 6)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.mgBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(items) { item in
                        HStack(spacing: 0) {
                            rowContent(item)
                            Spacer()
                            if hovered == item {
                                Button { onDelete(item) } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.red.opacity(0.7))
                                        .frame(width: 28, height: 28)
                                }
                                .buttonStyle(.plain)
                                .padding(.trailing, 12)
                            }
                        }
                        .padding(.horizontal, 14)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .contentShape(Rectangle())
                        .onHover { hovered = $0 ? item : nil }
                        .glassCard(
                            fill: hovered == item ? Color.mgRowHover : Color.mgRow,
                            borderTop: Color.white.opacity(0.08),
                            borderBottom: Color.white.opacity(0.04),
                            radius: 7
                        )
                        .padding(.horizontal, 20)
                    }
                    if items.isEmpty {
                        Text("No items yet — press + to add")
                            .font(.system(size: 13))
                            .foregroundStyle(Color.mgMuted)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 40)
                    }
                }
            }
            .background(Color.mgBg)
        }
        .sheet(isPresented: $showAdd) { addForm($showAdd) }
    }
}

// MARK: - Row helpers

private struct RowPrimary: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(Color.mgLabel)
            .lineLimit(1)
    }
}

private struct RowSecondary: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(Color.mgMuted)
            .lineLimit(1)
    }
}

// MARK: - Add form scaffold

private struct AddSheet<Content: View>: View {
    let title: String
    @Binding var isPresented: Bool
    let onSave: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(title)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Color.mgLabel)

            content()

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.mgMuted)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)

                Button("Add") { onSave(); isPresented = false }
                    .buttonStyle(.plain)
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Color.mgAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(28)
        .frame(width: 380)
        .background(Color.mgBg)
    }
}

private struct MGField: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.mgMuted)
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(Color.mgLabel)
                .padding(8)
                .background(Color.mgSurface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

private struct MGPicker<T: Identifiable & Hashable>: View {
    let label: String
    let items: [T]
    let displayName: (T) -> String
    @Binding var selected: T?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.mgMuted)
            Picker("", selection: $selected) {
                Text("None").tag(T?.none)
                ForEach(items) { item in
                    Text(displayName(item)).tag(T?.some(item))
                }
            }
            .pickerStyle(.menu)
            .padding(4)
            .background(Color.mgSurface)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}

// MARK: - Shared split-panel scaffold

private struct SelectableRow<T: Identifiable & Hashable, Content: View>: View {
    let item: T
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @ViewBuilder var content: () -> Content
    @State private var hovered = false

    var body: some View {
        HStack {
            content()
                .padding(.vertical, 8)
            Spacer()
            if hovered {
                Button(action: onDelete) {
                    Image(systemName: "trash").font(.system(size: 10))
                        .foregroundStyle(Color.red.opacity(0.7)).frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, minHeight: 40)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .glassCard(
            fill: isSelected ? Color.mgAccent.opacity(0.12) : hovered ? Color.mgRowHover : Color.mgRow,
            borderTop: isSelected ? Color.mgAccent.opacity(0.4) : Color.white.opacity(0.08),
            borderBottom: isSelected ? Color.mgAccent.opacity(0.22) : Color.white.opacity(0.04),
            radius: 7
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

private struct SplitPanel<T: Identifiable & Hashable, Row: View, Detail: View, Form: View>: View {
    let title: String
    let items: [T]
    let emptyHint: String
    let onDelete: (T) -> Void
    var onRefresh: (() -> Void)? = nil
    var onImport: (() -> Void)? = nil
    @ViewBuilder var rowContent: (T) -> Row
    @ViewBuilder var detail: (T) -> Detail
    @ViewBuilder var addForm: (Binding<Bool>) -> Form

    @State private var selected: T?
    @State private var showAdd = false

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.mgLabel)
                    Text("\(items.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.mgMuted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.mgSurface).clipShape(Capsule())
                    Spacer()
                    if let onRefresh {
                        Button { onRefresh() } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.mgAccent)
                                .frame(width: 28, height: 28)
                                .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 6)
                        }
                        .buttonStyle(.plain)
                        .help("Refresh")
                    }
                    if let onImport {
                        Button { onImport() } label: {
                            Image(systemName: "arrow.down.circle")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.mgAccent)
                                .frame(width: 28, height: 28)
                                .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 6)
                        }
                        .buttonStyle(.plain)
                        .help("Import from GitHub")
                    }
                    Button { showAdd = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.mgAccent)
                            .frame(width: 28, height: 28)
                            .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 6)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.mgBg)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(items) { item in
                            SelectableRow(
                                item: item,
                                isSelected: selected?.id == item.id,
                                onSelect: { selected = item },
                                onDelete: {
                                    onDelete(item)
                                    if selected?.id == item.id { selected = nil }
                                }
                            ) { rowContent(item) }
                        }
                        if items.isEmpty {
                            Text(emptyHint).font(.system(size: 13))
                                .foregroundStyle(Color.mgMuted).frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                    }
                }
                .background(Color.mgBg)
            }
            .frame(minWidth: 200, maxWidth: 280)

            if let sel = selected, items.contains(where: { $0.id == sel.id }) {
                detail(sel)
            } else {
                Color.mgBg.overlay(
                    Text("Select an item").font(.system(size: 13)).foregroundStyle(Color.mgMuted)
                )
            }
        }
        .sheet(isPresented: $showAdd) { addForm($showAdd) }
        .onChange(of: items) { selected = items.first { $0.id == selected?.id } }
    }
}

private struct EditDetailScaffold<Content: View>: View {
    let heading: String
    let onSave: () -> Void
    @ViewBuilder var content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(heading)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.mgLabel)
                content()
                HStack {
                    Spacer()
                    Button("Save", action: onSave)
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(Color.mgAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
            }
            .padding(24)
        }
        .background(Color.mgBg)
    }
}

private struct BranchTag: View {
    enum Kind { case db, local, remote }
    let kind: Kind

    private var label: String {
        switch kind { case .db: "db"; case .local: "local"; case .remote: "remote" }
    }
    private var icon: String {
        switch kind { case .db: "cylinder"; case .local: "laptopcomputer"; case .remote: "cloud" }
    }
    // db = amber fill, local = green outline, remote = blue fill
    private var fg: Color {
        switch kind {
        case .db:     Color(red: 0.96, green: 0.74, blue: 0.24)
        case .local:  Color(red: 0.35, green: 0.85, blue: 0.55)
        case .remote: Color(red: 0.40, green: 0.70, blue: 1.00)
        }
    }
    private var bg: Color {
        switch kind {
        case .db:     fg.opacity(0.18)
        case .local:  Color.clear
        case .remote: fg.opacity(0.18)
        }
    }
    private var strokeColor: Color {
        switch kind {
        case .local: fg.opacity(0.55)
        default:     Color.clear
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 7, weight: .medium))
            Text(label).font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(fg)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(bg)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(strokeColor, lineWidth: 0.8))
    }
}

private struct FeatureTabChip: View {
    let label: String
    let isActive: Bool
    let isCloseable: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.mgLabel : Color.mgMuted)
                .lineLimit(1)
            if isCloseable {
                Button { onClose() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(Color.mgMuted)
                        .frame(width: 14, height: 14)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .glassCard(
            fill: isActive ? Color.mgAccent.opacity(0.1) : Color.clear,
            borderTop: isActive ? Color.mgAccent.opacity(0.45) : Color.clear,
            borderBottom: isActive ? Color.mgAccent.opacity(0.25) : Color.clear,
            radius: 6
        )
    }
}


private struct PullRequestEntry: Identifiable, Decodable {
    let number: Int
    let title: String
    let headRefName: String
    let baseRefName: String
    let author: Author
    let state: String  // "OPEN", "CLOSED", or "MERGED"
    struct Author: Decodable { let login: String }
    var id: Int { number }
}

private struct IssueEntry: Identifiable, Decodable {
    let number: Int
    let title: String
    let state: String
    let url: String
    let labels: [Label]
    let author: Author
    struct Label: Decodable { let name: String }
    struct Author: Decodable { let login: String }
    var id: Int { number }
}

// MARK: - Repos panel

// Per-repo fetched data (branches/PRs/issues), kept only while the Repos tab stays
// mounted. `ManagementPanel` tears the whole subtree down on tab switch, so the
// @State store below is released then — no explicit cache-clearing needed.
@Observable
private final class RepoCache {
    var hasFetchedBranches = false
    var branches: [String] = []
    var remoteBranchNames: Set<String> = []
    var localBranchNames: Set<String> = []
    var pullRequests: [PullRequestEntry] = []
    var issueEntries: [IssueEntry] = []
}

private final class RepoCacheStore {
    private var entries: [String: RepoCache] = [:]
    func cache(for repoID: String) -> RepoCache {
        if let existing = entries[repoID] { return existing }
        let created = RepoCache()
        entries[repoID] = created
        return created
    }
}

private struct ReposPanel: View {
    @Environment(WorkspaceDB.self) var db
    @State private var newName          = ""
    @State private var newURL           = ""
    @State private var newDefaultBranch = "main"
    @State private var cacheStore = RepoCacheStore()
    @State private var showGitHubImport = false

    var body: some View {
        SplitPanel(
            title: "Repos",
            items: db.repos,
            emptyHint: "No repos — press + or import from GitHub",
            onDelete: { db.deleteRepo(id: $0.id) },
            onRefresh: { Task { await db.refresh() } },
            onImport: { showGitHubImport = true }
        ) { repo in
            VStack(alignment: .leading, spacing: 2) {
                RowPrimary(text: repo.name)
                let sub = repo.url.isEmpty ? repo.defaultBranch : repo.url
                if !sub.isEmpty { RowSecondary(text: sub) }
            }
        } detail: { repo in
            RepoDetailView(repo: repo, db: db, cache: cacheStore.cache(for: repo.id))
        } addForm: { isPresented in
            AddSheet(title: "New Repo", isPresented: isPresented) {
                db.addRepo(name: newName, url: newURL, defaultBranch: newDefaultBranch)
                newName = ""; newURL = ""; newDefaultBranch = "main"
            } content: {
                MGField(label: "Name", text: $newName)
                MGField(label: "Git URL", text: $newURL)
                MGField(label: "Default branch", text: $newDefaultBranch)
            }
        }
        .sheet(isPresented: $showGitHubImport) {
            GitHubRepoImportSheet(db: db, isPresented: $showGitHubImport)
        }
    }
}

private struct GHRepoListing: Identifiable, Decodable, Hashable {
    struct DefaultBranchRef: Decodable, Hashable { let name: String }
    let nameWithOwner: String
    let url: String
    let isPrivate: Bool
    let defaultBranchRef: DefaultBranchRef?
    var id: String { nameWithOwner }
}

private struct GitHubRepoImportSheet: View {
    let db: WorkspaceDB
    @Binding var isPresented: Bool
    @State private var owner = ""
    @State private var orgs: [String] = []
    @State private var repos: [GHRepoListing] = []
    @State private var repoSearch = ""
    @State private var fetching = false
    @State private var fetchError: String? = nil

    private func isAdded(_ listing: GHRepoListing) -> Bool {
        guard let listingParts = gitURLComponents(listing.url) else {
            return db.repos.contains { $0.url == listing.url }
        }
        return db.repos.contains { gitURLComponents($0.url).map { $0 == listingParts } ?? false }
    }

    private var filteredRepos: [GHRepoListing] {
        repoSearch.isEmpty ? repos : repos.filter { $0.nameWithOwner.localizedCaseInsensitiveContains(repoSearch) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Import from GitHub")
                    .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.mgLabel)
                Spacer()
                if fetching {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Button("Fetch") { fetchRepos() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mgAccent)
                }
            }

            Menu {
                Button("Your repos") { owner = "" }
                ForEach(orgs, id: \.self) { org in
                    Button(org) { owner = org }
                }
            } label: {
                HStack {
                    Text(owner.isEmpty ? "Your repos" : owner)
                        .font(.system(size: 13))
                        .foregroundStyle(Color.mgLabel)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10))
                        .foregroundStyle(Color.mgMuted)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.mgSurface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .menuStyle(.borderlessButton)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                TextField("Filter repos…", text: $repoSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mgLabel)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.mgSurface)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let fetchError {
                Text(fetchError).font(.system(size: 12)).foregroundStyle(Color.mgMuted)
            } else if repos.isEmpty && !fetching {
                Text("No repos fetched yet — press Fetch")
                    .font(.system(size: 12)).foregroundStyle(Color.mgMuted)
            } else if filteredRepos.isEmpty {
                Text("No repos match “\(repoSearch)”")
                    .font(.system(size: 12)).foregroundStyle(Color.mgMuted)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(filteredRepos) { listing in
                            HStack(spacing: 8) {
                                Text(listing.nameWithOwner)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(Color.mgLabel).lineLimit(1)
                                if listing.isPrivate {
                                    Text("private")
                                        .font(.system(size: 9, weight: .medium)).foregroundStyle(Color.mgMuted)
                                }
                                Spacer()
                                if isAdded(listing) {
                                    Text("Added").font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                                } else {
                                    Button("Add") {
                                        let name = listing.nameWithOwner.split(separator: "/").last.map(String.init) ?? listing.nameWithOwner
                                        db.addRepo(name: name, url: listing.url, defaultBranch: listing.defaultBranchRef?.name ?? "main")
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.mgAccent)
                                }
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
                        }
                    }
                }
                .frame(maxHeight: 320)
            }

            HStack {
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.plain).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Color.mgAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 7))
            }
        }
        .padding(28).frame(width: 460)
        .background(Color.mgBg)
        .onAppear { fetchOrgs() }
        .onChange(of: owner) { fetchRepos() }
    }

    private func fetchOrgs() {
        Task.detached {
            guard let ghPath = resolveGHPath() else { return }
            let p = Process(); let outPipe = Pipe(); let errPipe = Pipe()
            p.executableURL = URL(fileURLWithPath: ghPath)
            p.arguments = ["api", "user/orgs", "--jq", ".[].login"]
            p.standardOutput = outPipe; p.standardError = errPipe
            try? p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { return }
            let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            let names = out.split(separator: "\n").map(String.init)
            await MainActor.run { orgs = names }
        }
    }

    private func fetchRepos() {
        fetching = true
        fetchError = nil
        let ownerArg = owner
        Task.detached {
            guard let ghPath = resolveGHPath() else {
                await MainActor.run {
                    fetchError = "gh CLI not found — install from https://cli.github.com"
                    fetching = false
                }
                return
            }
            let p = Process(); let outPipe = Pipe(); let errPipe = Pipe()
            p.executableURL = URL(fileURLWithPath: ghPath)
            var arguments = ["repo", "list"]
            if !ownerArg.isEmpty { arguments.append(ownerArg) }
            arguments += ["--json", "nameWithOwner,url,isPrivate,defaultBranchRef", "--limit", "200"]
            p.arguments = arguments
            p.standardOutput = outPipe; p.standardError = errPipe
            do { try p.run() } catch {
                await MainActor.run { fetchError = error.localizedDescription; fetching = false }
                return
            }
            p.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            if p.terminationStatus != 0 {
                let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run { fetchError = msg.isEmpty ? "gh repo list failed" : msg; fetching = false }
                return
            }
            let decoded = (try? JSONDecoder().decode([GHRepoListing].self, from: outData)) ?? []
            await MainActor.run { repos = decoded; fetching = false }
        }
    }
}

private struct RepoDetailView: View {
    let repo: RepoEntry
    let db: WorkspaceDB
    let cache: RepoCache
    @Environment(AppSettings.self) var settings
    @Environment(PresetsStore.self) var presetsStore
    @State private var agentPickerPRNumber: Int? = nil
    @State private var agentPickerIssueNumber: Int? = nil
    @State private var name          = ""
    @State private var repoURL       = ""
    @State private var defaultBranch = ""
    @State private var showAddBranch = false
    @State private var cloningBranch: String? = nil
    @State private var branchSearch = ""
    @State private var showBasePicker = false
    @State private var pendingBranch = ""
    @State private var pendingPath = ""
    @State private var checkoutError: String? = nil
    @State private var fetchingBranches = false
    @State private var detailTab: RepoDetailTab = .branches
    @State private var prSearch = ""
    @State private var showClosedPRs = false
    @State private var fetchingPRs = false
    @State private var prError: String? = nil
    @State private var checkingOutPR: Int? = nil
    @State private var issueSearch = ""
    @State private var fetchingIssues = false
    @State private var issueError: String? = nil
    @State private var checkingOutIssue: Int? = nil
    @State private var showIssueSheet = false
    @State private var editingIssue: IssueEntry? = nil

    enum RepoDetailTab { case branches, prs, issues }

    // Proxies onto the per-repo cache so the rest of this view's code (and the
    // async fetch callbacks) can read/write `branches`/`pullRequests`/etc. as before.
    private var hasFetchedBranches: Bool {
        get { cache.hasFetchedBranches }
        nonmutating set { cache.hasFetchedBranches = newValue }
    }
    private var branches: [String] {
        get { cache.branches }
        nonmutating set { cache.branches = newValue }
    }
    private var remoteBranchNames: Set<String> {
        get { cache.remoteBranchNames }
        nonmutating set { cache.remoteBranchNames = newValue }
    }
    private var localBranchNames: Set<String> {
        get { cache.localBranchNames }
        nonmutating set { cache.localBranchNames = newValue }
    }
    private var pullRequests: [PullRequestEntry] {
        get { cache.pullRequests }
        nonmutating set { cache.pullRequests = newValue }
    }
    private var issueEntries: [IssueEntry] {
        get { cache.issueEntries }
        nonmutating set { cache.issueEntries = newValue }
    }

    var githubComponents: (org: String, repo: String)? { gitURLComponents(repoURL) }

    var filteredPRs: [PullRequestEntry] {
        prSearch.isEmpty ? pullRequests : pullRequests.filter {
            $0.title.localizedCaseInsensitiveContains(prSearch)
                || $0.headRefName.localizedCaseInsensitiveContains(prSearch)
                || $0.author.login.localizedCaseInsensitiveContains(prSearch)
                || String($0.number).contains(prSearch)
        }
    }

    var filteredIssues: [IssueEntry] {
        issueSearch.isEmpty ? issueEntries : issueEntries.filter {
            $0.title.localizedCaseInsensitiveContains(issueSearch)
                || $0.author.login.localizedCaseInsensitiveContains(issueSearch)
                || String($0.number).contains(issueSearch)
        }
    }

    var sortedFilteredBranches: [String] {
        let filtered = branchSearch.isEmpty ? branches
            : branches.filter { $0.localizedCaseInsensitiveContains(branchSearch) }
        func rank(_ branch: String) -> Int {
            if branch == defaultBranch { return 0 }             // main/default branch
            let cloned = branchPath(branch).map { FileManager.default.fileExists(atPath: $0) } ?? false
            if cloned { return 1 }                              // workspace
            if localBranchNames.contains(branch) { return 2 }   // local
            return 3                                            // remote only
        }
        return filtered.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a < b
        }
    }

    var body: some View {
        EditDetailScaffold(heading: repo.name) {
            var updated = repo
            updated.name = name; updated.url = repoURL; updated.defaultBranch = defaultBranch
            db.updateRepo(updated)
        } content: {
            MGField(label: "Name", text: $name)
            MGField(label: "Git URL", text: $repoURL)
            MGField(label: "Default branch", text: $defaultBranch)

            if githubComponents != nil {
                HStack(spacing: 4) {
                    FeatureTabChip(label: "Branches", isActive: detailTab == .branches, isCloseable: false,
                                   onSelect: {
                                       detailTab = .branches
                                       if !hasFetchedBranches && !fetchingBranches { fetchBranches() }
                                   }, onClose: {})
                    FeatureTabChip(label: "PRs", isActive: detailTab == .prs, isCloseable: false,
                                   onSelect: {
                                       detailTab = .prs
                                       if pullRequests.isEmpty && !fetchingPRs { fetchPRs() }
                                   }, onClose: {})
                    FeatureTabChip(label: "Issues", isActive: detailTab == .issues, isCloseable: false,
                                   onSelect: {
                                       detailTab = .issues
                                       if issueEntries.isEmpty && !fetchingIssues { fetchIssues() }
                                   }, onClose: {})
                }
            }

            if detailTab == .prs && githubComponents != nil {
                prSection
            } else if detailTab == .issues && githubComponents != nil {
                issueSection
            } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("BRANCHES")
                        .font(.system(size: 10, weight: .medium)).tracking(0.8)
                        .foregroundStyle(Color.mgMuted)
                    Spacer()
                    if !repoURL.isEmpty {
                        if fetchingBranches {
                            ProgressView().scaleEffect(0.6).frame(width: 32)
                        } else {
                            Button("Fetch") { fetchBranches() }
                                .buttonStyle(.plain)
                                .font(.system(size: 11)).foregroundStyle(Color.mgAccent)
                                .help("Fetch branches from remote")
                        }
                    }
                    Button { showAddBranch = true } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.mgAccent)
                            .frame(width: 22, height: 22)
                            .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 4)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                    TextField("Filter branches…", text: $branchSearch)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mgLabel)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(Color.mgSurface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                .clipShape(RoundedRectangle(cornerRadius: 6))

                if branches.isEmpty {
                    Text("No branches — press + or Fetch")
                        .font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                } else {
                    VStack(spacing: 0) {
                        ForEach(sortedFilteredBranches, id: \.self) { branch in
                            let clonePath = branchPath(branch)
                            let isCloned = clonePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(branch)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(Color.mgLabel).lineLimit(1)
                                    if let p = clonePath {
                                        Text(p)
                                            .font(.system(size: 10))
                                            .foregroundStyle(isCloned ? Color.mgAccent : Color.mgMuted)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                HStack(spacing: 4) {
                                    if isCloned || localBranchNames.contains(branch) { BranchTag(kind: .local) }
                                    if remoteBranchNames.contains(branch) { BranchTag(kind: .remote) }
                                }
                                if cloningBranch == branch {
                                    ProgressView().scaleEffect(0.6).frame(width: 28)
                                } else if isCloned {
                                    Button {
                                        NotificationCenter.default.post(
                                            name: .srotaOpenWorkspace,
                                            object: nil,
                                            userInfo: [
                                                "path":           clonePath!,
                                                "name":           branch,
                                                "folderName":     repo.name,
                                                "folderTag":      "",
                                                "createWorktree": false,
                                                "projectPath":    clonePath!,
                                                "branchRef":      branch
                                            ]
                                        )
                                    } label: {
                                        Image(systemName: "terminal")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.mgAccent)
                                            .frame(width: 22, height: 22)
                                            .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 4)
                                    }
                                    .buttonStyle(.plain)
                                    .help("Open in workspace")
                                } else if clonePath != nil {
                                    let isDefault = branch == defaultBranch
                                    let canCheckout = isDefault || isMainCloned
                                    Button(isDefault ? "Clone" : "Worktree") {
                                        if isDefault || remoteBranchNames.contains(branch) || localBranchNames.contains(branch) {
                                            checkout(branch: branch, into: clonePath!)
                                        } else {
                                            pendingBranch = branch
                                            pendingPath = clonePath!
                                            showBasePicker = true
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(canCheckout ? Color.mgAccent : Color.mgMuted.opacity(0.5))
                                    .disabled(!canCheckout)
                                    .help(canCheckout ? "" : "Clone \(defaultBranch) first")
                                    .frame(width: 55)
                                }
                                Button {
                                    if isCloned, let path = clonePath {
                                        removeBranch(name: branch, worktreePath: path)
                                    } else {
                                        branches.removeAll { $0 == branch }
                                    }
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 9)).foregroundStyle(Color.red.opacity(0.6))
                                        .frame(width: 20, height: 20)
                                }
                                .buttonStyle(.plain)
                                .help(isCloned ? "Remove worktree & delete" : "Delete")
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
                        }
                    }
                    .background(Color.mgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                }
            }
            }
        }
        .sheet(isPresented: $showAddBranch) {
            RepoBranchSheet(isPresented: $showAddBranch) { name in
                if !branches.contains(name) { branches.append(name) }
            }
        }
        .sheet(isPresented: $showBasePicker) {
            BaseBranchPicker(
                newBranch: pendingBranch,
                remoteBranches: remoteBranchNames.sorted(),
                isPresented: $showBasePicker
            ) { base in
                checkout(branch: pendingBranch, baseBranch: base, into: pendingPath)
            }
        }
        .alert("Error", isPresented: .init(
            get: { checkoutError != nil },
            set: { if !$0 { checkoutError = nil } }
        )) {
            Button("OK", role: .cancel) { checkoutError = nil }
        } message: {
            Text(checkoutError ?? "")
        }
        .onAppear { load() }
        .onChange(of: repo.id) { load() }
        .onChange(of: showClosedPRs) { fetchPRs() }
    }

    private func load() {
        name = repo.name; repoURL = repo.url; defaultBranch = repo.defaultBranch
        detailTab = .branches; prError = nil; issueError = nil
        if !hasFetchedBranches && !fetchingBranches { fetchBranches() }
    }

    private func branchPath(_ branchName: String) -> String? {
        guard let base = settings.baseWorkingDirectory else { return nil }
        return repoBranchPath(base: base, repoURL: repoURL, repoName: repo.name, branch: branchName)
    }

    private var mainClonePath: String? { branchPath(defaultBranch) }
    private var isMainCloned: Bool {
        guard let p = mainClonePath else { return false }
        return FileManager.default.fileExists(atPath: p)
    }

    private func checkout(branch: String, baseBranch: String = "", into path: String) {
        cloningBranch = branch
        let isDefault = branch == defaultBranch
        let mainPath = mainClonePath ?? ""
        let repoURL = self.repoURL
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            let errPipe = Pipe()
            p.standardError = errPipe
            if !isDefault && !mainPath.isEmpty {
                if baseBranch.isEmpty {
                    p.arguments = ["-C", mainPath, "worktree", "add", path, branch]
                } else {
                    p.arguments = ["-C", mainPath, "worktree", "add", "-b", branch, path, baseBranch]
                }
            } else {
                p.arguments = ["clone", "--branch", branch, repoURL, path]
            }
            do { try p.run() } catch {
                await MainActor.run { cloningBranch = nil; checkoutError = error.localizedDescription }
                return
            }
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run {
                    cloningBranch = nil
                    checkoutError = msg.isEmpty ? "git command failed" : msg
                }
            } else {
                await MainActor.run { cloningBranch = nil }
            }
        }
    }

    private func removeBranch(name: String, worktreePath: String) {
        let runFrom = mainClonePath ?? worktreePath  // fall back to the worktree itself
        Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", runFrom, "worktree", "remove", "--force", worktreePath]
            let errPipe = Pipe()
            p.standardError = errPipe
            do { try p.run() } catch {
                await MainActor.run { checkoutError = error.localizedDescription }
                return
            }
            p.waitUntilExit()
            if p.terminationStatus != 0 {
                let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run { checkoutError = msg.isEmpty ? "git worktree remove failed" : msg }
            } else {
                await MainActor.run { branches.removeAll { $0 == name } }
            }
        }
    }

    private func fetchBranches() {
        fetchingBranches = true
        let url = repoURL
        let localRoot = mainClonePath
        Task.detached {
            // remote branches via ls-remote
            var remoteNames: Set<String> = []
            if !url.isEmpty {
                let p = Process(); let pipe = Pipe()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["ls-remote", "--heads", url]
                p.standardOutput = pipe; p.standardError = Pipe()
                try? p.run(); p.waitUntilExit()
                let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                remoteNames = Set(out.split(separator: "\n").compactMap { line -> String? in
                    guard let ref = line.split(separator: "\t").last else { return nil }
                    return String(ref).replacingOccurrences(of: "refs/heads/", with: "")
                })
            }
            // local branches from main clone
            var localNames: Set<String> = []
            if let root = localRoot, FileManager.default.fileExists(atPath: root) {
                let p2 = Process(); let pipe2 = Pipe()
                p2.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p2.arguments = ["-C", root, "branch", "--format=%(refname:short)"]
                p2.standardOutput = pipe2; p2.standardError = Pipe()
                try? p2.run(); p2.waitUntilExit()
                let out2 = String(data: pipe2.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                localNames = Set(out2.split(separator: "\n")
                    .map { String($0).trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty })
            }
            let resolvedRemoteNames = remoteNames
            let resolvedLocalNames = localNames
            await MainActor.run {
                remoteBranchNames = resolvedRemoteNames
                localBranchNames = resolvedLocalNames
                // Union with what's already there so a just-created (not-yet-pushed) branch
                // or a manually-added placeholder name doesn't disappear on refetch.
                branches = Array(Set(branches).union(resolvedRemoteNames).union(resolvedLocalNames))
                fetchingBranches = false
                hasFetchedBranches = true
            }
        }
    }

    private func fetchPRs() {
        guard let (org, repoName) = githubComponents else { return }
        fetchingPRs = true
        prError = nil
        let state = showClosedPRs ? "all" : "open"
        Task.detached {
            guard let ghPath = resolveGHPath() else {
                await MainActor.run {
                    prError = "gh CLI not found — install from https://cli.github.com"
                    fetchingPRs = false
                }
                return
            }
            let p = Process(); let outPipe = Pipe(); let errPipe = Pipe()
            p.executableURL = URL(fileURLWithPath: ghPath)
            p.arguments = ["pr", "list", "--repo", "\(org)/\(repoName)", "--state", state,
                           "--json", "number,title,headRefName,baseRefName,author,state", "--limit", "100"]
            p.standardOutput = outPipe; p.standardError = errPipe
            do { try p.run() } catch {
                await MainActor.run { prError = error.localizedDescription; fetchingPRs = false }
                return
            }
            p.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            if p.terminationStatus != 0 {
                let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run {
                    prError = msg.isEmpty ? "gh pr list failed" : msg
                    fetchingPRs = false
                }
                return
            }
            let decoded = try? JSONDecoder().decode([PullRequestEntry].self, from: outData)
            await MainActor.run {
                pullRequests = decoded ?? []
                fetchingPRs = false
            }
        }
    }

    private func fetchIssues() {
        guard let (org, repoName) = githubComponents else { return }
        fetchingIssues = true
        issueError = nil
        Task.detached {
            guard let ghPath = resolveGHPath() else {
                await MainActor.run {
                    issueError = "gh CLI not found — install from https://cli.github.com"
                    fetchingIssues = false
                }
                return
            }
            let p = Process(); let outPipe = Pipe(); let errPipe = Pipe()
            p.executableURL = URL(fileURLWithPath: ghPath)
            p.arguments = ["issue", "list", "--repo", "\(org)/\(repoName)", "--state", "open",
                           "--json", "number,title,state,url,labels,author", "--limit", "100"]
            p.standardOutput = outPipe; p.standardError = errPipe
            do { try p.run() } catch {
                await MainActor.run { issueError = error.localizedDescription; fetchingIssues = false }
                return
            }
            p.waitUntilExit()
            let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            if p.terminationStatus != 0 {
                let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run {
                    issueError = msg.isEmpty ? "gh issue list failed" : msg
                    fetchingIssues = false
                }
                return
            }
            let decoded = try? JSONDecoder().decode([IssueEntry].self, from: outData)
            await MainActor.run {
                issueEntries = decoded ?? []
                fetchingIssues = false
            }
        }
    }

    private func submitIssue(number: Int?, title: String, body: String) {
        guard let (org, repoName) = githubComponents else { return }
        Task.detached {
            guard let ghPath = resolveGHPath() else { return }
            let p = Process(); let errPipe = Pipe()
            p.executableURL = URL(fileURLWithPath: ghPath)
            if let number {
                p.arguments = ["issue", "edit", String(number), "--repo", "\(org)/\(repoName)",
                               "--title", title, "--body", body]
            } else {
                p.arguments = ["issue", "create", "--repo", "\(org)/\(repoName)",
                               "--title", title, "--body", body]
            }
            p.standardError = errPipe
            try? p.run()
            p.waitUntilExit()
            await MainActor.run { fetchIssues() }
        }
    }

    private func checkoutPR(_ pr: PullRequestEntry) {
        guard let path = branchPath(pr.headRefName), let mainPath = mainClonePath, isMainCloned else { return }
        checkingOutPR = pr.number
        let headRef = pr.headRefName
        Task.detached {
            // Fetch into FETCH_HEAD rather than directly into the branch ref: if headRef
            // is already checked out in another worktree, git refuses to update it directly.
            let fetchP = Process(); let fetchErrPipe = Pipe()
            fetchP.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            fetchP.arguments = ["-C", mainPath, "fetch", "origin", "pull/\(pr.number)/head"]
            fetchP.standardError = fetchErrPipe
            do { try fetchP.run() } catch {
                await MainActor.run { checkingOutPR = nil; checkoutError = error.localizedDescription }
                return
            }
            fetchP.waitUntilExit()
            if fetchP.terminationStatus != 0 {
                let msg = String(data: fetchErrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run { checkingOutPR = nil; checkoutError = msg.isEmpty ? "git fetch failed" : msg }
                return
            }
            let branchExistsP = Process()
            branchExistsP.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            branchExistsP.arguments = ["-C", mainPath, "show-ref", "--verify", "--quiet", "refs/heads/\(headRef)"]
            try? branchExistsP.run()
            branchExistsP.waitUntilExit()
            let branchExists = branchExistsP.terminationStatus == 0

            // A same-named local branch can be left dangling (e.g. its worktree was
            // removed via the trash button, which never deletes the branch ref itself).
            // Force it to what we just fetched so re-checkout always reflects the PR's
            // latest commits rather than silently reusing a stale pointer. Safe to force:
            // this button only shows when the branch has no live worktree (see !isCloned above).
            if branchExists {
                let moveP = Process(); let moveErrPipe = Pipe()
                moveP.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                moveP.arguments = ["-C", mainPath, "branch", "-f", headRef, "FETCH_HEAD"]
                moveP.standardError = moveErrPipe
                do { try moveP.run() } catch {
                    await MainActor.run { checkingOutPR = nil; checkoutError = error.localizedDescription }
                    return
                }
                moveP.waitUntilExit()
                if moveP.terminationStatus != 0 {
                    let msg = String(data: moveErrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    await MainActor.run { checkingOutPR = nil; checkoutError = msg.isEmpty ? "git branch update failed" : msg }
                    return
                }
            }

            let worktreeP = Process(); let worktreeErrPipe = Pipe()
            worktreeP.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            worktreeP.arguments = branchExists
                ? ["-C", mainPath, "worktree", "add", path, headRef]
                : ["-C", mainPath, "worktree", "add", path, "-b", headRef, "FETCH_HEAD"]
            worktreeP.standardError = worktreeErrPipe
            do { try worktreeP.run() } catch {
                await MainActor.run { checkingOutPR = nil; checkoutError = error.localizedDescription }
                return
            }
            worktreeP.waitUntilExit()
            if worktreeP.terminationStatus != 0 {
                let msg = String(data: worktreeErrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run { checkingOutPR = nil; checkoutError = msg.isEmpty ? "git worktree add failed" : msg }
            } else {
                await MainActor.run {
                    if !branches.contains(headRef) { branches.append(headRef) }
                    checkingOutPR = nil
                }
            }
        }
    }

    private func checkoutIssue(_ issue: IssueEntry) {
        let branchName = "issue/\(issue.number)"
        guard let path = branchPath(branchName), let mainPath = mainClonePath, isMainCloned else { return }
        checkingOutIssue = issue.number
        let base = defaultBranch
        Task.detached {
            let worktreeP = Process(); let errPipe = Pipe()
            worktreeP.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            worktreeP.arguments = ["-C", mainPath, "worktree", "add", path, "-b", branchName, base]
            worktreeP.standardError = errPipe
            do { try worktreeP.run() } catch {
                await MainActor.run { checkingOutIssue = nil; checkoutError = error.localizedDescription }
                return
            }
            worktreeP.waitUntilExit()
            if worktreeP.terminationStatus != 0 {
                let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                await MainActor.run { checkingOutIssue = nil; checkoutError = msg.isEmpty ? "git worktree add failed" : msg }
            } else {
                await MainActor.run {
                    if !branches.contains(branchName) { branches.append(branchName) }
                    checkingOutIssue = nil
                }
            }
        }
    }

    private func launchReviewAgent(_ preset: TerminalPreset, pr: PullRequestEntry, path: String) {
        NotificationCenter.default.post(
            name: .srotaOpenWorkspace,
            object: nil,
            userInfo: [
                "path":                 path,
                "name":                 pr.headRefName,
                "folderName":           repo.name,
                "folderTag":            "",
                "createWorktree":       false,
                "projectPath":          path,
                "branchRef":            pr.headRefName,
                "launchAgentName":      "GitHub PR Review Agent",
                "launchAgentContext":   "Review PR #\(pr.number): \(pr.title) (base: \(pr.baseRefName)).",
                "launchAgentPresetID":  preset.id.uuidString
            ]
        )
    }

    private func launchIssueAgent(_ preset: TerminalPreset, issue: IssueEntry, path: String) {
        let branchName = "issue/\(issue.number)"
        NotificationCenter.default.post(
            name: .srotaOpenWorkspace,
            object: nil,
            userInfo: [
                "path":                 path,
                "name":                 branchName,
                "folderName":           repo.name,
                "folderTag":            "",
                "createWorktree":       false,
                "projectPath":          path,
                "branchRef":            branchName,
                "launchAgentName":      "GitHub Issue Agent",
                "launchAgentContext":   "Work on issue #\(issue.number): \(issue.title).",
                "launchAgentPresetID":  preset.id.uuidString
            ]
        )
    }

    @ViewBuilder
    private var prSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("PULL REQUESTS")
                    .font(.system(size: 10, weight: .medium)).tracking(0.8)
                    .foregroundStyle(Color.mgMuted)
                Spacer()
                Toggle("Show closed", isOn: $showClosedPRs)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                if fetchingPRs {
                    ProgressView().scaleEffect(0.6).frame(width: 32)
                } else {
                    Button("Fetch") { fetchPRs() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(Color.mgAccent)
                        .help("Fetch PRs from GitHub")
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                TextField("Filter PRs…", text: $prSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mgLabel)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.mgSurface)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let prError {
                Text(prError)
                    .font(.system(size: 12)).foregroundStyle(Color.mgMuted)
            } else if filteredPRs.isEmpty {
                Text(fetchingPRs ? "Loading…" : (showClosedPRs ? "No PRs" : "No open PRs"))
                    .font(.system(size: 12)).foregroundStyle(Color.mgMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredPRs) { pr in
                        let clonePath = branchPath(pr.headRefName)
                        let isCloned = clonePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("#\(pr.number) \(pr.title)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.mgLabel).lineLimit(1)
                                Text("by \(pr.author.login) (\(pr.headRefName))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(isCloned ? Color.mgAccent : Color.mgMuted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if pr.state != "OPEN" {
                                Text(pr.state.capitalized)
                                    .font(.system(size: 9, weight: .medium)).foregroundStyle(Color.mgMuted)
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.mgMuted.opacity(0.15))
                                    .clipShape(Capsule())
                            }
                            if isCloned { BranchTag(kind: .local) }
                            Button {
                                if let (org, repoName) = githubComponents,
                                   let url = URL(string: "https://github.com/\(org)/\(repoName)/pull/\(pr.number)") {
                                    NSWorkspace.shared.open(url)
                                }
                            } label: {
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.mgAccent)
                                    .frame(width: 22, height: 22)
                                    .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 4)
                            }
                            .buttonStyle(.plain)
                            .help("Open on GitHub")
                            if checkingOutPR == pr.number {
                                ProgressView().scaleEffect(0.6).frame(width: 28)
                            } else if isCloned, let path = clonePath {
                                Button {
                                    NotificationCenter.default.post(
                                        name: .srotaOpenWorkspace,
                                        object: nil,
                                        userInfo: [
                                            "path":           path,
                                            "name":           pr.headRefName,
                                            "folderName":     repo.name,
                                            "folderTag":      "",
                                            "createWorktree": false,
                                            "projectPath":    path,
                                            "branchRef":      pr.headRefName
                                        ]
                                    )
                                } label: {
                                    Image(systemName: "terminal")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.mgAccent)
                                        .frame(width: 22, height: 22)
                                        .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 4)
                                }
                                .buttonStyle(.plain)
                                .help("Open in workspace")
                                Button {
                                    agentPickerPRNumber = pr.number
                                } label: {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.mgAccent)
                                        .frame(width: 22, height: 22)
                                        .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 4)
                                }
                                .buttonStyle(.plain)
                                .help("Review with Agent")
                                .popover(isPresented: Binding(
                                    get: { agentPickerPRNumber == pr.number },
                                    set: { if !$0 { agentPickerPRNumber = nil } }
                                ), arrowEdge: .bottom) {
                                    PresetPickerPopover(presets: presetsStore.presets.filter { $0.isAgent }) { preset in
                                        agentPickerPRNumber = nil
                                        launchReviewAgent(preset, pr: pr, path: path)
                                    }
                                }
                            } else {
                                Button("Worktree") { checkoutPR(pr) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(isMainCloned ? Color.mgAccent : Color.mgMuted.opacity(0.5))
                                    .disabled(!isMainCloned)
                                    .help(isMainCloned ? "" : "Clone \(defaultBranch) first")
                                    .frame(width: 55)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
                    }
                }
                .background(Color.mgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
            }
        }
    }

    @ViewBuilder
    private var issueSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("ISSUES")
                    .font(.system(size: 10, weight: .medium)).tracking(0.8)
                    .foregroundStyle(Color.mgMuted)
                Spacer()
                if fetchingIssues {
                    ProgressView().scaleEffect(0.6).frame(width: 32)
                } else {
                    Button("Fetch") { fetchIssues() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(Color.mgAccent)
                        .help("Fetch open issues from GitHub")
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                TextField("Filter issues…", text: $issueSearch)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mgLabel)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.mgSurface)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            if let issueError {
                Text(issueError)
                    .font(.system(size: 12)).foregroundStyle(Color.mgMuted)
            } else if filteredIssues.isEmpty {
                Text(fetchingIssues ? "Loading…" : "No open issues")
                    .font(.system(size: 12)).foregroundStyle(Color.mgMuted)
            } else {
                VStack(spacing: 0) {
                    ForEach(filteredIssues) { issue in
                        let branchName = "issue/\(issue.number)"
                        let clonePath = branchPath(branchName)
                        let isCloned = clonePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                        HStack(spacing: 8) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("#\(issue.number) \(issue.title)")
                                    .font(.system(size: 12))
                                    .foregroundStyle(Color.mgLabel).lineLimit(1)
                                Text(issue.labels.isEmpty
                                     ? "by \(issue.author.login)"
                                     : "by \(issue.author.login) · \(issue.labels.map(\.name).joined(separator: ", "))")
                                    .font(.system(size: 10, design: .monospaced))
                                    .foregroundStyle(isCloned ? Color.mgAccent : Color.mgMuted)
                                    .lineLimit(1)
                            }
                            Spacer()
                            if isCloned { BranchTag(kind: .local) }
                            Button {
                                editingIssue = issue
                                showIssueSheet = true
                            } label: {
                                Image(systemName: "pencil")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.mgAccent)
                                    .frame(width: 22, height: 22)
                                    .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 4)
                            }
                            .buttonStyle(.plain)
                            .help("Edit issue")
                            Button {
                                if let url = URL(string: issue.url) { NSWorkspace.shared.open(url) }
                            } label: {
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.mgAccent)
                                    .frame(width: 22, height: 22)
                                    .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 4)
                            }
                            .buttonStyle(.plain)
                            .help("Open on GitHub")
                            if checkingOutIssue == issue.number {
                                ProgressView().scaleEffect(0.6).frame(width: 28)
                            } else if isCloned, let path = clonePath {
                                Button {
                                    NotificationCenter.default.post(
                                        name: .srotaOpenWorkspace,
                                        object: nil,
                                        userInfo: [
                                            "path":           path,
                                            "name":           branchName,
                                            "folderName":     repo.name,
                                            "folderTag":      "",
                                            "createWorktree": false,
                                            "projectPath":    path,
                                            "branchRef":      branchName
                                        ]
                                    )
                                } label: {
                                    Image(systemName: "terminal")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.mgAccent)
                                        .frame(width: 22, height: 22)
                                        .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 4)
                                }
                                .buttonStyle(.plain)
                                .help("Open in workspace")
                                Button {
                                    agentPickerIssueNumber = issue.number
                                } label: {
                                    Image(systemName: "sparkles")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.mgAccent)
                                        .frame(width: 22, height: 22)
                                        .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 4)
                                }
                                .buttonStyle(.plain)
                                .help("Work on issue with Agent")
                                .popover(isPresented: Binding(
                                    get: { agentPickerIssueNumber == issue.number },
                                    set: { if !$0 { agentPickerIssueNumber = nil } }
                                ), arrowEdge: .bottom) {
                                    PresetPickerPopover(presets: presetsStore.presets.filter { $0.isAgent }) { preset in
                                        agentPickerIssueNumber = nil
                                        launchIssueAgent(preset, issue: issue, path: path)
                                    }
                                }
                            } else {
                                Button("Worktree") { checkoutIssue(issue) }
                                    .buttonStyle(.plain)
                                    .font(.system(size: 11, weight: .medium))
                                    .foregroundStyle(isMainCloned ? Color.mgAccent : Color.mgMuted.opacity(0.5))
                                    .disabled(!isMainCloned)
                                    .help(isMainCloned ? "" : "Clone \(defaultBranch) first")
                                    .frame(width: 55)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
                    }
                }
                .background(Color.mgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
            }

            HStack {
                Spacer()
                Button("+ New Issue") {
                    editingIssue = nil
                    showIssueSheet = true
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .medium)).foregroundStyle(Color.mgAccent)
            }
        }
        .sheet(isPresented: $showIssueSheet) {
            GHIssueFormSheet(existing: editingIssue, isPresented: $showIssueSheet) { title, body in
                submitIssue(number: editingIssue?.number, title: title, body: body)
            }
        }
    }
}

private struct GHIssueFormSheet: View {
    let existing: IssueEntry?
    @Binding var isPresented: Bool
    let onSubmit: (String, String) -> Void
    @State private var title = ""
    @State private var issueBody = ""

    var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isEditing ? "Edit Issue" : "New Issue")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.mgLabel)
            MGField(label: "Title", text: $title)
            VStack(alignment: .leading, spacing: 4) {
                Text("BODY (optional)")
                    .font(.system(size: 11, weight: .medium)).tracking(0.8).foregroundStyle(Color.mgMuted)
                TextEditor(text: $issueBody)
                    .font(.system(size: 13)).foregroundStyle(Color.mgLabel)
                    .scrollContentBackground(.hidden)
                    .padding(8).frame(minHeight: 100)
                    .background(Color.mgSurface)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain).foregroundStyle(Color.mgMuted)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Button(isEditing ? "Save" : "Create") {
                    onSubmit(title, issueBody)
                    isPresented = false
                }
                .buttonStyle(.plain).foregroundStyle(.black)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(title.isEmpty ? Color.mgMuted : Color.mgAccent)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .disabled(title.isEmpty)
            }
        }
        .padding(28).frame(width: 380).background(Color.mgBg)
        .onAppear {
            title = existing?.title ?? ""
        }
    }
}

private struct BaseBranchPicker: View {
    let newBranch: String
    let remoteBranches: [String]
    @Binding var isPresented: Bool
    let onConfirm: (String) -> Void
    @State private var search = ""
    @State private var selected = ""

    private var filtered: [String] {
        search.isEmpty ? remoteBranches : remoteBranches.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create \"\(newBranch)\"")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.mgLabel)
            Text("Branch not found in remote. Select a base branch:")
                .font(.system(size: 12)).foregroundStyle(Color.mgMuted)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                TextField("Search branches…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.mgLabel)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(Color.mgSurface)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(filtered, id: \.self) { branch in
                        HStack {
                            Text(branch)
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(Color.mgLabel)
                            Spacer()
                            if selected == branch {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.mgAccent)
                            }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(selected == branch ? Color.mgAccent.opacity(0.1) : Color.clear)
                        .contentShape(Rectangle())
                        .onTapGesture { selected = branch }
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
                    }
                }
            }
            .frame(maxHeight: 220)
            .background(Color.mgSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain).foregroundStyle(Color.mgMuted)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Button("Create & Worktree") {
                    onConfirm(selected)
                    isPresented = false
                }
                .buttonStyle(.plain).foregroundStyle(.black)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(selected.isEmpty ? Color.mgMuted : Color.mgAccent)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .disabled(selected.isEmpty)
            }
        }
        .padding(24).frame(width: 380).background(Color.mgBg)
        .onAppear { selected = remoteBranches.first ?? "" }
    }
}

private struct RepoBranchSheet: View {
    @Binding var isPresented: Bool
    let onAdd: (String) -> Void
    @State private var branchName = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Add Branch")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.mgLabel)

            MGField(label: "Branch name", text: $branchName)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain).foregroundStyle(Color.mgMuted)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Button("Add") {
                    onAdd(branchName)
                    isPresented = false
                }
                .buttonStyle(.plain).foregroundStyle(.black)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(branchName.isEmpty ? Color.mgMuted : Color.mgAccent)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .disabled(branchName.isEmpty)
            }
        }
        .padding(28).frame(width: 360).background(Color.mgBg)
    }
}

struct MCPPromptBlock: View {
    let title: String
    let subtitle: String
    let content: String
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.mgLabel)
                    Text(subtitle)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(Color.mgMuted)
                }
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(content, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 11))
                        Text(copied ? "Copied" : "Copy prompt")
                            .font(.system(size: 12))
                    }
                    .foregroundStyle(copied ? Color.mgAccent : Color.mgMuted)
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.mgSurface)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                }
                .buttonStyle(.plain)
            }
            Text(content)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(Color.mgLabel)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.mgSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                .textSelection(.enabled)
        }
    }
}
