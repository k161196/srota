import SwiftUI
import AppKit
import GhosttyTerminal

struct FeatureAgentTab: Identifiable {
    let id: String         // "global" or feature.id
    let featureID: String? // nil = global
    let tab: TerminalTab
}

@Observable @MainActor
final class FeatureAgentFocus {
    var activeViewState: TerminalViewState?
    var agentTabs: [FeatureAgentTab] = []
    var activeTabID: String = "global" {
        didSet {
            recentOrder.removeAll { $0 == activeTabID }
            recentOrder.append(activeTabID)
        }
    }
    // MRU order of tabIDs, used to pick an eviction candidate — kept separate from
    // `agentTabs` so the visible tab bar order stays stable as you click between tabs.
    var recentOrder: [String] = []
}

struct IssueAgentTab: Identifiable {
    let id: String        // "global" or issue.id
    let issueID: String?  // nil = global tab
    let tab: TerminalTab
}

@Observable @MainActor
final class IssueAgentFocus {
    var activeViewState: TerminalViewState?
    var agentTabs: [IssueAgentTab] = []
    var activeTabID: String = "global" {
        didSet {
            recentOrder.removeAll { $0 == activeTabID }
            recentOrder.append(activeTabID)
        }
    }
    var recentOrder: [String] = []
}

extension Notification.Name {
    static let srotaOpenWorkspace    = Notification.Name("srota.openWorkspace")
    static let srotaWorkspaceClosed  = Notification.Name("srota.workspaceClosed")
    static let srotaTabClosed        = Notification.Name("srota.tabClosed")
}

// ponytail: each open Feature/Issue tab keeps a live Ghostty (Metal) terminal surface
// resident even while hidden — cap how many stay open at once, raise if too aggressive.
private let maxOpenAgentTabs = 6

// MARK: - Top-level tab enum

enum ManagementTab: String, CaseIterable {
    case workspaces    = "Workspaces"
    case agents        = "Agents"
    case organizations = "Organizations"
    case projects      = "Projects"
    case features      = "Features"
    case repos         = "Repos"
    case issues        = "Issues"

    var icon: String {
        switch self {
        case .workspaces:    return "terminal"
        case .agents:        return "bolt.fill"
        case .organizations: return "building.2"
        case .projects:      return "folder"
        case .features:      return "sparkles"
        case .repos:         return "square.and.arrow.down"
        case .issues:        return "exclamationmark.circle"
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
        ZStack {
            // Always in hierarchy — TerminalSurfaceView must never be destroyed
            FeaturesPanel()
                .opacity(tab == .features ? 1 : 0)
                .allowsHitTesting(tab == .features)
            IssuesPanel()
                .opacity(tab == .issues ? 1 : 0)
                .allowsHitTesting(tab == .issues)

            if tab != .features && tab != .issues {
                switch tab {
                case .workspaces:    EmptyView()  // handled by ContentView
                case .agents:        AgentsPanel()
                case .organizations: OrganizationsPanel()
                case .projects:      ProjectsPanel()
                case .features:      EmptyView()
                case .repos:         ReposPanel()
                case .issues:        EmptyView()
                }
            }
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

// MARK: - Organizations panel

private struct OrganizationsPanel: View {
    @Environment(WorkspaceDB.self) var db
    @State private var newName = ""
    @State private var newPath = ""

    var body: some View {
        SplitPanel(
            title: "Organizations",
            items: db.organizations,
            emptyHint: "No organizations — press +",
            onDelete: { db.deleteOrganization(id: $0.id) }
        ) { org in
            VStack(alignment: .leading, spacing: 2) {
                RowPrimary(text: org.name)
                if !org.path.isEmpty { RowSecondary(text: org.path) }
            }
        } detail: { org in
            OrganizationDetailView(org: org, db: db)
        } addForm: { isPresented in
            AddSheet(title: "New Organization", isPresented: isPresented) {
                db.addOrganization(name: newName, path: newPath)
                newName = ""; newPath = ""
            } content: {
                MGField(label: "Name", text: $newName)
                MGField(label: "Path (optional)", text: $newPath)
            }
        }
    }
}

private struct OrganizationDetailView: View {
    let org: Organization
    let db: WorkspaceDB
    @State private var name = ""
    @State private var path = ""

    var body: some View {
        EditDetailScaffold(heading: org.name) {
            var updated = org; updated.name = name; updated.path = path
            db.updateOrganization(updated)
        } content: {
            MGField(label: "Name", text: $name)
            MGField(label: "Path", text: $path)
        }
        .onAppear { name = org.name; path = org.path }
        .onChange(of: org.id) { name = org.name; path = org.path }
    }
}

// MARK: - Projects panel (split view)

private struct ProjectsPanel: View {
    @Environment(WorkspaceDB.self) var db
    @EnvironmentObject var manager: TerminalManager
    @State private var selected: Project?
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newPath = ""
    @State private var newOrg: Organization?

    var body: some View {
        HSplitView {
            // Left: list
            VStack(spacing: 0) {
                HStack {
                    Text("Projects")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.mgLabel)
                    Text("\(db.projects.count)")
                        .font(.system(size: 11).monospacedDigit())
                        .foregroundStyle(Color.mgMuted)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Color.mgSurface).clipShape(Capsule())
                    Spacer()
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
                        ForEach(db.projects) { proj in
                            ProjectListRow(
                                proj: proj,
                                orgName: db.organizations.first { $0.id == proj.orgID }?.name ?? proj.orgID,
                                isSelected: selected?.id == proj.id,
                                onSelect: { selected = proj },
                                onDelete: { db.deleteProject(id: proj.id); if selected?.id == proj.id { selected = nil } }
                            )
                        }
                        if db.projects.isEmpty {
                            Text("No projects — press +").font(.system(size: 13))
                                .foregroundStyle(Color.mgMuted).frame(maxWidth: .infinity).padding(.vertical, 40)
                        }
                    }
                }
                .background(Color.mgBg)
            }
            .frame(minWidth: 200, maxWidth: 280)

            // Right: detail
            if let proj = selected, db.projects.contains(where: { $0.id == proj.id }) {
                ProjectDetailView(project: proj, db: db, manager: manager)
            } else {
                Color.mgBg
                    .overlay(Text("Select a project").font(.system(size: 13)).foregroundStyle(Color.mgMuted))
            }
        }
        .sheet(isPresented: $showAdd) {
            AddSheet(title: "New Project", isPresented: $showAdd) {
                db.addProject(name: newName, orgID: newOrg?.id ?? "", path: newPath)
                newName = ""; newPath = ""; newOrg = nil
            } content: {
                MGField(label: "Name", text: $newName)
                MGPicker(label: "Organization", items: db.organizations, displayName: \.name, selected: $newOrg)
                MGField(label: "Path (optional)", text: $newPath)
            }
        }
        // keep selected in sync after refresh
        .onChange(of: db.projects) { selected = db.projects.first { $0.id == selected?.id } }
    }
}

private struct ProjectListRow: View {
    let proj: Project
    let orgName: String
    let isSelected: Bool
    let onSelect: () -> Void
    let onDelete: () -> Void
    @State private var hovered = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                RowPrimary(text: proj.name)
                RowSecondary(text: orgName)
            }
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

private struct BranchRow: Identifiable, Sendable {
    let id = UUID()
    let gitName: String          // from git branch -a
    let isCurrent: Bool
    let localPath: String?       // from DB checkout if matched
    let gitIsWorktree: Bool      // git "+" prefix = checked out in another worktree
    let hasRemote: Bool          // local branch has a remote tracking counterpart

    nonisolated init(gitName: String, isCurrent: Bool, localPath: String?, gitIsWorktree: Bool = false, hasRemote: Bool = false) {
        self.gitName = gitName
        self.isCurrent = isCurrent
        self.localPath = localPath
        self.gitIsWorktree = gitIsWorktree
        self.hasRemote = hasRemote
    }

    var isWorktree: Bool {
        if gitIsWorktree { return true }
        guard let p = localPath else { return false }
        let gitFile = p + "/.git"
        var isDir: ObjCBool = false
        FileManager.default.fileExists(atPath: gitFile, isDirectory: &isDir)
        return !isDir.boolValue   // .git file = linked worktree, .git dir = primary checkout
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

private struct ProjectDetailView: View {
    let project: Project
    let db: WorkspaceDB
    let manager: TerminalManager
    @State private var editDesc = ""
    @State private var editPath = ""

    var openWorkspaceNames: Set<String> {
        let all = manager.folders.flatMap(\.workspaces) + manager.workspaces
        return Set(all.map(\.name))
    }

    var isBaseCloned: Bool {
        guard !project.path.isEmpty else { return false }
        return FileManager.default.fileExists(atPath: project.path + "/.git")
    }
    @State private var branches: [BranchRow] = []
    @State private var branchSearch = ""
    @State private var loadingBranches = false
    @State private var gitRoot: String = ""

    var filteredBranches: [BranchRow] {
        let filtered = branchSearch.isEmpty ? branches
            : branches.filter { $0.gitName.localizedCaseInsensitiveContains(branchSearch) }
        return filtered.sorted { a, b in
            let aLocal = a.localPath != nil
            let bLocal = b.localPath != nil
            if aLocal != bLocal { return aLocal }
            if aLocal && bLocal { return a.isWorktree && !b.isWorktree }
            return false
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // Header
                VStack(alignment: .leading, spacing: 4) {
                    Text(project.name)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(Color.mgLabel)
                    if !project.path.isEmpty {
                        Text(project.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Color.mgMuted)
                    }
                }

                // Organization (read-only)
                DetailRow(label: "Organization") {
                    Text(db.organizations.first { $0.id == project.orgID }?.name ?? project.orgID)
                        .font(.system(size: 13)).foregroundStyle(Color.mgLabel)
                }

                // Description (editable markdown)
                VStack(alignment: .leading, spacing: 8) {
                    Text("DESCRIPTION")
                        .font(.system(size: 10, weight: .medium)).tracking(0.8)
                        .foregroundStyle(Color.mgMuted)
                    TextEditor(text: $editDesc)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(Color.mgLabel)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 120)
                        .background(Color.mgSurface)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    HStack {
                        Spacer()
                        Button("Save") {
                            var p = project; p.description = editDesc
                            db.updateProject(p)
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.mgAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                // Base path
                VStack(alignment: .leading, spacing: 8) {
                    Text("BASE PATH")
                        .font(.system(size: 10, weight: .medium)).tracking(0.8)
                        .foregroundStyle(Color.mgMuted)
                    TextField("Cloned repo path…", text: $editPath)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color.mgLabel)
                        .padding(8)
                        .background(Color.mgSurface)
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    HStack {
                        if !editPath.isEmpty && !isBaseCloned {
                            Text("No .git found at this path")
                                .font(.system(size: 11))
                                .foregroundStyle(Color.orange.opacity(0.8))
                        }
                        Spacer()
                        Button("Save") {
                            var p = project; p.path = editPath
                            db.updateProject(p)
                            branches = []
                            fetchBranches()
                        }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                        .background(Color.mgAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    }
                }

                // Branches
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("BRANCHES")
                            .font(.system(size: 10, weight: .medium)).tracking(0.8)
                            .foregroundStyle(Color.mgMuted)
                        Spacer()
                        if loadingBranches {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Button { fetchBranches() } label: {
                                Image(systemName: "arrow.clockwise")
                                    .font(.system(size: 10)).foregroundStyle(Color.mgMuted)
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    // Search
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

                    if filteredBranches.isEmpty && !loadingBranches {
                        Text("No branches found")
                            .font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(filteredBranches) { branch in
                                HStack(spacing: 8) {
                                    let branchShortName = branch.gitName.replacingOccurrences(of: "/", with: "-")
                                    let isOpen = openWorkspaceNames.contains(branchShortName)
                                    Image(systemName: isOpen ? "terminal.fill" : "circle")
                                        .font(.system(size: 10))
                                        .foregroundStyle(isOpen ? Color.mgAccent : Color.mgMuted.opacity(0.4))
                                    Text(branch.gitName)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(isOpen ? Color.mgLabel : Color.mgMuted)
                                        .lineLimit(1)
                                    Spacer()
                                    HStack(spacing: 4) {
                                        if branch.localPath != nil { BranchTag(kind: .db) }
                                        if !branch.gitName.hasPrefix("remotes/") { BranchTag(kind: .local) }
                                        if branch.gitName.hasPrefix("remotes/") || branch.hasRemote { BranchTag(kind: .remote) }
                                    }
                                    // Open button for every branch
                                    let branchShort = branch.gitName.replacingOccurrences(of: "/", with: "-")
                                    let orgName = db.organizations.first { $0.id == project.orgID }?.name ?? ""
                                    let localPath = branch.localPath ?? (project.path + "/branches/" + branchShort)
                                    let hasLocal = branch.localPath != nil
                                    // strip remotes/origin prefix for git ref
                                    let branchRef = branch.gitName.hasPrefix("remotes/origin/")
                                        ? String(branch.gitName.dropFirst("remotes/origin/".count))
                                        : branch.gitName

                                    Button {
                                        NotificationCenter.default.post(
                                            name: .srotaOpenWorkspace,
                                            object: nil,
                                            userInfo: [
                                                "path":            localPath,
                                                "name":            branchShort,
                                                "folderName":      project.name,
                                                "folderTag":       orgName,
                                                "createWorktree":  !hasLocal,
                                                "projectPath":     project.path,
                                                "branchRef":       branchRef
                                            ]
                                        )
                                    } label: {
                                        Image(systemName: hasLocal ? "terminal" : "plus.rectangle")
                                            .font(.system(size: 10))
                                            .foregroundStyle(isBaseCloned ? Color.mgAccent : Color.mgMuted.opacity(0.4))
                                            .frame(width: 22, height: 22)
                                            .background((isBaseCloned ? Color.mgAccent : Color.mgMuted).opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    .buttonStyle(.plain)
                                    .disabled(!isBaseCloned && !hasLocal)
                                    .help(hasLocal ? "Open in workspace" : isBaseCloned ? "Create worktree & open" : "Set base path first")
                                }
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
                            }
                        }
                        .background(Color.mgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                    }
                }
            }
            .padding(24)
        }
        .background(Color.mgBg)
        .onAppear {
            editDesc = project.description
            editPath = project.path
            fetchBranches()
        }
        .onChange(of: project.id) {
            editDesc = project.description
            editPath = project.path
            branches = []
            fetchBranches()
        }
    }

    private func fetchBranches() {
        let dbBranches = db.branches(projectID: project.id)
        // Build a name→path map from DB checkouts (folder name = branch name)
        var nameToPath: [String: String] = [:]
        for b in dbBranches { nameToPath[b.name] = b.path }

        let gitRoot = dbBranches.first?.path ?? project.path
        self.gitRoot = gitRoot
        guard !gitRoot.isEmpty else {
            // No git root, just show DB branches
            branches = dbBranches.map { BranchRow(gitName: $0.name, isCurrent: false, localPath: $0.path) }
            return
        }
        loadingBranches = true
        branches = []
        Task.detached {
            let raw = Self.runGit(["branch", "-a"], in: gitRoot)
            let lines = raw
                .components(separatedBy: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.contains(" -> ") } // drop HEAD pointer lines

            // strip git prefix (* current, + worktree) to get plain name
            func parseLine(_ line: String) -> (name: String, isCurrent: Bool, isGitWorktree: Bool) {
                if line.hasPrefix("* ") { return (String(line.dropFirst(2)), true,  false) }
                if line.hasPrefix("+ ") { return (String(line.dropFirst(2)), false, true)  }
                return (line, false, false)
            }

            // collect all local branch names (non-remote) for dedup
            let localNames: Set<String> = Set(lines.compactMap { line -> String? in
                let (name, _, _) = parseLine(line)
                return name.hasPrefix("remotes/") ? nil : name
            })
            // collect remote branch short-names to detect local+remote overlap
            let remoteNames: Set<String> = Set(lines.compactMap { line -> String? in
                let (name, _, _) = parseLine(line)
                guard name.hasPrefix("remotes/origin/") else { return nil }
                return String(name.dropFirst("remotes/origin/".count))
            })

            let rows: [BranchRow] = lines.compactMap { line in
                let (name, isCurrent, isGitWorktree) = parseLine(line)
                // drop remote tracking branch if a local branch with same name exists
                if name.hasPrefix("remotes/origin/") {
                    let localEquiv = String(name.dropFirst("remotes/origin/".count))
                    if localNames.contains(localEquiv) { return nil }
                }
                let shortName = name.components(separatedBy: "/").last ?? name
                let path = nameToPath[shortName]
                let hasRemote = !name.hasPrefix("remotes/") && remoteNames.contains(name)
                return BranchRow(gitName: name, isCurrent: isCurrent,
                                 localPath: path, gitIsWorktree: isGitWorktree, hasRemote: hasRemote)
            }
            await MainActor.run {
                branches = rows
                loadingBranches = false
            }
        }
    }

    nonisolated private static func runGit(_ args: [String], in path: String) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = args
        p.currentDirectoryURL = URL(fileURLWithPath: path)
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}

private struct DetailRow<V: View>: View {
    let label: String
    @ViewBuilder var value: () -> V
    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .medium)).tracking(0.8)
                .foregroundStyle(Color.mgMuted)
                .frame(width: 90, alignment: .trailing)
            value()
            Spacer()
        }
    }
}

// MARK: - Features panel

private struct FeaturesPanel: View {
    @Environment(WorkspaceDB.self) var db
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppSettings.self) var settings
    @Environment(FeatureAgentFocus.self) var agentFocus

    @State private var showAdd      = false
    @State private var showMCPSetup = false
    @State private var newName = ""
    @State private var newDesc = ""
    @State private var selectedProject: Project?

    var activeFeature: Feature? {
        guard agentFocus.activeTabID != "global" else { return nil }
        return db.features.first { $0.id == agentFocus.activeTabID }
    }

    var body: some View {
        HSplitView {
            featureListPanel
                .frame(minWidth: 200, maxWidth: 260)
            featureAgentCenter
            if let feature = activeFeature {
                FeatureInfoSidebar(feature: feature, db: db)
                    .frame(minWidth: 300, maxWidth: 480)
            }
        }
        .onAppear { ensureGlobalTab() }
        .onChange(of: db.features) { reinjectOpenTabs() }
        .onChange(of: db.issues) { reinjectOpenTabs() }
        .sheet(isPresented: $showAdd) {
            AddSheet(title: "New Feature", isPresented: $showAdd) {
                db.addFeature(name: newName, projectID: selectedProject?.id ?? "", description: newDesc)
                newName = ""; newDesc = ""; selectedProject = nil
            } content: {
                MGField(label: "Name", text: $newName)
                MGPicker(label: "Project", items: db.projects, displayName: \.name, selected: $selectedProject)
                MGField(label: "Description (optional)", text: $newDesc)
            }
        }
    }

    private func ensureGlobalTab() {
        guard !agentFocus.agentTabs.contains(where: { $0.id == "global" }) else { return }
        agentFocus.agentTabs.insert(FeatureAgentTab(id: "global", featureID: nil, tab: TerminalTab(colorScheme: colorScheme, workingDirectory: agentSessionDir(type: "features", id: "global"))), at: 0)
    }

    private func repoClonePath(repoID: String) -> String? {
        guard let base = settings.baseWorkingDirectory,
              let repo = db.repos.first(where: { $0.id == repoID }) else { return nil }
        let safeBranch = repo.defaultBranch.replacingOccurrences(of: "/", with: "-")
        if let (org, repoName) = gitURLComponents(repo.url) {
            let safeOrg = org.replacingOccurrences(of: "/", with: "-")
            let safeRepo = repoName.replacingOccurrences(of: "/", with: "-")
            return "\(base)/organizations/\(safeOrg)/projects/\(safeRepo)/branches/\(safeBranch)"
        }
        let safeRepo = repo.name.replacingOccurrences(of: "/", with: "-")
        return "\(base)/repos/\(safeRepo)/branches/\(safeBranch)"
    }

    private func openTab(for feature: Feature) {
        if agentFocus.agentTabs.contains(where: { $0.id == feature.id }) {
            agentFocus.activeTabID = feature.id
        } else {
            let cwds = db.featureRepos
                .filter { $0.featureID == feature.id }
                .compactMap { fr -> String? in repoClonePath(repoID: fr.repoID) }
            let cwd = agentSessionDir(type: "features", id: String(feature.number))
            agentFocus.agentTabs.append(FeatureAgentTab(id: feature.id, featureID: feature.id, tab: TerminalTab(colorScheme: colorScheme, workingDirectory: cwd)))
            agentFocus.activeTabID = feature.id
            cwds.forEach { injectContext(feature: feature, into: $0) }
            if settings.resolvedMCPServerPath != nil && !UserDefaults.standard.bool(forKey: "mcpSetupDismissed") {
                showMCPSetup = true
            }
            evictLeastRecentTabIfNeeded()
        }
    }

    private func evictLeastRecentTabIfNeeded() {
        let closable = agentFocus.agentTabs.filter { $0.id != "global" }
        guard closable.count > maxOpenAgentTabs else { return }
        guard let lru = agentFocus.recentOrder.first(where: { id in
            id != agentFocus.activeTabID && closable.contains { $0.id == id }
        }) else { return }
        closeTab(lru)
    }

    private func closeTab(_ id: String) {
        if let tab = agentFocus.agentTabs.first(where: { $0.id == id }),
           let fid = tab.featureID {
            let cwds = db.featureRepos
                .filter { $0.featureID == fid }
                .compactMap { fr -> String? in repoClonePath(repoID: fr.repoID) }
            cwds.forEach { removeContext(from: $0) }
        }
        agentFocus.agentTabs.removeAll { $0.id == id }
        agentFocus.recentOrder.removeAll { $0 == id }
        if agentFocus.activeTabID == id { agentFocus.activeTabID = "global" }
    }

    private func reinjectOpenTabs() {
        for agentTab in agentFocus.agentTabs where agentTab.featureID != nil {
            guard let feature = db.features.first(where: { $0.id == agentTab.featureID }) else { continue }
            let cwds = db.featureRepos
                .filter { $0.featureID == feature.id }
                .compactMap { fr -> String? in repoClonePath(repoID: fr.repoID) }
            cwds.forEach { injectContext(feature: feature, into: $0) }
        }
    }


    private func injectContext(feature: Feature, into dir: String) {
        let proj = db.projects.first { $0.id == feature.projectID }?.name ?? feature.projectID
        let issues = db.issues.filter { $0.featureID == feature.id }
        let issueList = issues.isEmpty ? "None" : issues.map { "- [\($0.status)] \($0.title)" }.joined(separator: "\n")
        let block = """
            <!-- srota:start -->
            ## Feature Context (srota)
            **Feature:** \(feature.name)
            **ID:** `\(feature.id)`
            **Project:** \(proj)
            **Description:** \(feature.description.isEmpty ? "_(none yet)_" : feature.description)

            **Linked Issues:**
            \(issueList)

            ## srota MCP Tools
            If Srota MCP is configured, use these tools to update this feature:
            - `srota:update_feature_description(id, description)` — write markdown description, visible in the UI
            - `srota:add_issue(title, body?, status?, feature_id?)` — create issue linked to this feature
            - `srota:update_issue(id, title?, body?, status?)` — update an issue
            - `srota:link_issue_to_feature(issue_id, feature_id)` — link existing issue
            - `srota:list_features()` / `srota:list_issues(feature_id?)`

            Current feature ID for MCP calls: `\(feature.id)`
            <!-- srota:end -->
            """
        for filename in ["CLAUDE.md", "AGENTS.md"] {
            let path = dir + "/" + filename
            var content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            if content.contains("<!-- srota:start -->") {
                content = replaceBlock(in: content, with: block)
            } else {
                content = content.isEmpty ? block : content + "\n\n" + block
            }
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func removeContext(from dir: String) {
        for filename in ["CLAUDE.md", "AGENTS.md"] {
            let path = dir + "/" + filename
            guard var content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            content = replaceBlock(in: content, with: nil)
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? FileManager.default.removeItem(atPath: path)
            } else {
                try? content.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    private func replaceBlock(in content: String, with replacement: String?) -> String {
        let start = "<!-- srota:start -->"
        let end = "<!-- srota:end -->"
        guard let s = content.range(of: start), let e = content.range(of: end) else {
            return replacement.map { content + "\n\n" + $0 } ?? content
        }
        let before = String(content[content.startIndex..<s.lowerBound]).trimmingCharacters(in: .newlines)
        let after = String(content[e.upperBound...]).trimmingCharacters(in: .newlines)
        guard let block = replacement else {
            return [before, after].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return [before, block, after].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    @ViewBuilder
    var featureListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Features")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mgLabel)
                Text("\(db.features.count)")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.mgMuted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.mgSurface).clipShape(Capsule())
                Spacer()
                Button { db.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mgMuted)
                        .frame(width: 28, height: 28)
                        .background(Color.mgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Refresh")
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mgAccent)
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
                    ForEach(db.features) { feature in
                        SelectableRow(
                            item: feature,
                            isSelected: agentFocus.activeTabID == feature.id,
                            onSelect: { openTab(for: feature) },
                            onDelete: { db.deleteFeature(id: feature.id) }
                        ) {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack(spacing: 4) {
                                    Text("#\(feature.number)")
                                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                                        .foregroundStyle(Color.mgAccent)
                                    RowPrimary(text: feature.name)
                                }
                                let proj = db.projects.first { $0.id == feature.projectID }?.name ?? feature.projectID
                                RowSecondary(text: proj)
                            }
                        }
                    }
                    if db.features.isEmpty {
                        Text("No features — press +")
                            .font(.system(size: 13)).foregroundStyle(Color.mgMuted)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
            }
            .background(Color.mgBg)
        }
        .sheet(isPresented: $showMCPSetup) {
            MCPSetupSheet(mcpPath: settings.resolvedMCPServerPath ?? "")
        }
    }

    @ViewBuilder
    var featureAgentCenter: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(agentFocus.agentTabs) { agentTab in
                        let label = agentTab.id == "global"
                            ? "Features"
                            : (db.features.first { $0.id == agentTab.featureID }?.name ?? "Feature")
                        FeatureTabChip(
                            label: label,
                            isActive: agentFocus.activeTabID == agentTab.id,
                            isCloseable: agentTab.id != "global",
                            onSelect: { agentFocus.activeTabID = agentTab.id },
                            onClose: { closeTab(agentTab.id) }
                        )
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .background(Color.mgBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }

            FeatureTerminalStack(tabs: agentFocus.agentTabs, activeTabID: agentFocus.activeTabID)
        }
        .onChange(of: agentFocus.activeTabID) {
            agentFocus.activeViewState = agentFocus.agentTabs.first { $0.id == agentFocus.activeTabID }?.tab.focusedViewState
        }
    }
}

private struct FeatureTerminalStack: View {
    let tabs: [FeatureAgentTab]
    let activeTabID: String

    var body: some View {
        ZStack {
            Color.black
            ForEach(tabs) { tab in
                TerminalSurfaceView(context: tab.tab.focusedViewState)
                    .opacity(activeTabID == tab.id ? 1 : 0)
            }
        }
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

private struct FeatureInfoSidebar: View {
    let feature: Feature
    let db: WorkspaceDB
    @State private var name = ""
    @State private var desc = ""
    @State private var showAddIssue = false

    var linkedIssues: [Issue] { db.issues.filter { $0.featureID == feature.id } }
    var linkedRepos: [(repo: RepoEntry, branch: String)] {
        db.featureRepos
            .filter { $0.featureID == feature.id }
            .compactMap { fr in
                guard let repo = db.repos.first(where: { $0.id == fr.repoID }) else { return nil }
                return (repo, fr.branch)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("#\(feature.number)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.mgAccent)
                    .padding(.trailing, 6)
                TextField("Feature name", text: $name)
                    .font(.system(size: 14, weight: .semibold))
                    .textFieldStyle(.plain)
                    .onSubmit { saveFeature() }
                Button { db.refresh(); load() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.mgMuted)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.mgBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("DESCRIPTION")
                            .font(.system(size: 10, weight: .medium)).tracking(0.8)
                            .foregroundStyle(Color.mgMuted)
                        TextEditor(text: $desc)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.mgLabel)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 200)
                            .background(Color.mgSurface)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    let repos = linkedRepos
                    if !repos.isEmpty {
                        DetailRow(label: "Repos") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(repos, id: \.repo.id) { link in
                                    HStack(spacing: 6) {
                                        Text(link.repo.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.mgLabel)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 4)
                                        if !link.branch.isEmpty {
                                            Text(link.branch)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(Color.mgMuted)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .background(Color.mgSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text("ISSUES")
                                .font(.system(size: 10, weight: .medium)).tracking(0.8)
                                .foregroundStyle(Color.mgMuted)
                            Spacer()
                            Button { showAddIssue = true } label: {
                                Image(systemName: "plus")
                                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.mgAccent)
                                    .frame(width: 22, height: 22)
                                    .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 4)
                            }
                            .buttonStyle(.plain)
                        }
                        if linkedIssues.isEmpty {
                            Text("No issues linked")
                                .font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                        } else {
                            VStack(spacing: 0) {
                                ForEach(linkedIssues) { issue in
                                    HStack(spacing: 8) {
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(issue.title)
                                                .font(.system(size: 13)).foregroundStyle(Color.mgLabel).lineLimit(1)
                                            if !issue.body.isEmpty {
                                                Text(issue.body)
                                                    .font(.system(size: 11)).foregroundStyle(Color.mgMuted).lineLimit(1)
                                            }
                                        }
                                        Spacer()
                                        StatusBadge(status: issue.status)
                                    }
                                    .padding(.horizontal, 10).padding(.vertical, 8)
                                    .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
                                }
                            }
                            .background(Color.mgSurface)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                        }
                    }
                }
                .padding(14)
            }

            HStack {
                Spacer()
                Button("Save") { saveFeature() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.mgAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.mgBg)
            .overlay(alignment: .top) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
        }
        .background(Color.mgBg)
        .onAppear { load() }
        .onChange(of: feature.id) { load() }
        .onChange(of: feature.description) { load() }
        .onChange(of: feature.name) { load() }
        .sheet(isPresented: $showAddIssue) {
            AddIssueToFeatureSheet(feature: feature, db: db, isPresented: $showAddIssue)
        }
    }

    private func load() {
        let fresh = db.features.first { $0.id == feature.id } ?? feature
        name = fresh.name
        desc = fresh.description
    }
    private func saveFeature() {
        var f = feature; f.name = name; f.description = desc; db.updateFeature(f)
    }
}

private struct AddIssueToFeatureSheet: View {
    let feature: Feature
    let db: WorkspaceDB
    @Binding var isPresented: Bool
    @State private var title = ""
    @State private var issueBody = ""
    @State private var status = "open"

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("New Issue")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.mgLabel)
            MGField(label: "Title", text: $title)
            VStack(alignment: .leading, spacing: 4) {
                Text("STATUS")
                    .font(.system(size: 11, weight: .medium)).tracking(0.8).foregroundStyle(Color.mgMuted)
                Picker("", selection: $status) {
                    ForEach(issueStatuses, id: \.self) { Text($0).tag($0) }
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("BODY (optional)")
                    .font(.system(size: 11, weight: .medium)).tracking(0.8).foregroundStyle(Color.mgMuted)
                TextEditor(text: $issueBody)
                    .font(.system(size: 13)).foregroundStyle(Color.mgLabel)
                    .scrollContentBackground(.hidden)
                    .padding(8).frame(minHeight: 80)
                    .background(Color.mgSurface)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain).foregroundStyle(Color.mgMuted)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Button("Add") {
                    db.addIssue(title: title, body: issueBody, status: status, featureID: feature.id)
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
    }
}

private struct PullRequestEntry: Identifiable, Decodable {
    let number: Int
    let title: String
    let headRefName: String
    let author: Author
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

private struct ReposPanel: View {
    @Environment(WorkspaceDB.self) var db
    @State private var newName          = ""
    @State private var newURL           = ""
    @State private var newDefaultBranch = "main"

    var body: some View {
        SplitPanel(
            title: "Repos",
            items: db.repos,
            emptyHint: "No repos — press +",
            onDelete: { db.deleteRepo(id: $0.id) },
            onRefresh: { db.refresh() }
        ) { repo in
            VStack(alignment: .leading, spacing: 2) {
                RowPrimary(text: repo.name)
                let sub = repo.url.isEmpty ? repo.defaultBranch : repo.url
                if !sub.isEmpty { RowSecondary(text: sub) }
            }
        } detail: { repo in
            RepoDetailView(repo: repo, db: db)
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
    }
}

private struct RepoDetailView: View {
    let repo: RepoEntry
    let db: WorkspaceDB
    @Environment(AppSettings.self) var settings
    @Environment(PresetsStore.self) var presetsStore
    @State private var agentPickerPRNumber: Int? = nil
    @State private var name          = ""
    @State private var repoURL       = ""
    @State private var defaultBranch = ""
    @State private var showAddBranch = false
    @State private var cloningBranch: String? = nil
    @State private var branchSearch = ""
    @State private var remoteBranchNames: Set<String> = []
    @State private var localBranchNames: Set<String> = []
    @State private var showBasePicker = false
    @State private var pendingBranch = ""
    @State private var pendingPath = ""
    @State private var checkoutError: String? = nil
    @State private var fetchingBranches = false
    @State private var detailTab: RepoDetailTab = .branches
    @State private var pullRequests: [PullRequestEntry] = []
    @State private var prSearch = ""
    @State private var fetchingPRs = false
    @State private var prError: String? = nil
    @State private var checkingOutPR: Int? = nil
    @State private var issueEntries: [IssueEntry] = []
    @State private var issueSearch = ""
    @State private var fetchingIssues = false
    @State private var issueError: String? = nil
    @State private var checkingOutIssue: Int? = nil
    @State private var showIssueSheet = false
    @State private var editingIssue: IssueEntry? = nil

    enum RepoDetailTab { case branches, prs, issues }

    var branches: [RepoBranch] { db.repoBranches.filter { $0.repoID == repo.id } }

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

    var sortedFilteredBranches: [RepoBranch] {
        let filtered = branchSearch.isEmpty ? branches
            : branches.filter { $0.name.localizedCaseInsensitiveContains(branchSearch) }
        func rank(_ branch: RepoBranch) -> Int {
            let cloned = branchPath(branch.name).map { FileManager.default.fileExists(atPath: $0) } ?? false
            if cloned { return 0 }                              // workspace
            if localBranchNames.contains(branch.name) { return 1 } // local
            return 2                                            // remote only
        }
        return filtered.sorted { a, b in
            let ra = rank(a), rb = rank(b)
            return ra != rb ? ra < rb : a.name < b.name
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
                                   onSelect: { detailTab = .branches }, onClose: {})
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
                        ForEach(sortedFilteredBranches) { branch in
                            let clonePath = branchPath(branch.name)
                            let isCloned = clonePath.map { FileManager.default.fileExists(atPath: $0) } ?? false
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(branch.name)
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
                                    BranchTag(kind: .db)
                                    if isCloned || localBranchNames.contains(branch.name) { BranchTag(kind: .local) }
                                    if remoteBranchNames.contains(branch.name) { BranchTag(kind: .remote) }
                                }
                                if cloningBranch == branch.name {
                                    ProgressView().scaleEffect(0.6).frame(width: 28)
                                } else if isCloned {
                                    Button {
                                        NotificationCenter.default.post(
                                            name: .srotaOpenWorkspace,
                                            object: nil,
                                            userInfo: [
                                                "path":           clonePath!,
                                                "name":           branch.name,
                                                "folderName":     repo.name,
                                                "folderTag":      "",
                                                "createWorktree": false,
                                                "projectPath":    clonePath!,
                                                "branchRef":      branch.name
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
                                    let isDefault = branch.name == defaultBranch
                                    let canCheckout = isDefault || isMainCloned
                                    Button(isDefault ? "Clone" : "Worktree") {
                                        if isDefault || remoteBranchNames.contains(branch.name) || localBranchNames.contains(branch.name) {
                                            checkout(branch: branch.name, into: clonePath!)
                                        } else {
                                            pendingBranch = branch.name
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
                                        removeBranch(id: branch.id, worktreePath: path)
                                    } else {
                                        db.deleteRepoBranch(id: branch.id)
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
            RepoBranchSheet(repoID: repo.id, existing: nil, db: db, isPresented: $showAddBranch)
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
    }

    private func load() {
        name = repo.name; repoURL = repo.url; defaultBranch = repo.defaultBranch
        detailTab = .branches; pullRequests = []; prError = nil; issueEntries = []; issueError = nil
    }

    private func branchPath(_ branchName: String) -> String? {
        guard let base = settings.baseWorkingDirectory else { return nil }
        let safeName = branchName.replacingOccurrences(of: "/", with: "-")
        if let (org, repoName) = gitURLComponents(repoURL) {
            let safeOrg = org.replacingOccurrences(of: "/", with: "-")
            let safeRepo = repoName.replacingOccurrences(of: "/", with: "-")
            return "\(base)/organizations/\(safeOrg)/projects/\(safeRepo)/branches/\(safeName)"
        }
        let safeRepo = repo.name.replacingOccurrences(of: "/", with: "-")
        return "\(base)/repos/\(safeRepo)/branches/\(safeName)"
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

    private func removeBranch(id: String, worktreePath: String) {
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
                await MainActor.run { db.deleteRepoBranch(id: id) }
            }
        }
    }

    private func fetchBranches() {
        fetchingBranches = true
        let url = repoURL
        let repoID = repo.id
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
            let allNames = remoteNames.union(localNames)
            let resolvedRemoteNames = remoteNames
            let resolvedLocalNames = localNames
            await MainActor.run {
                remoteBranchNames = resolvedRemoteNames
                localBranchNames = resolvedLocalNames
                let existing = Set(db.repoBranches.filter { $0.repoID == repoID }.map { $0.name })
                for n in allNames where !existing.contains(n) {
                    db.addRepoBranch(repoID: repoID, name: n)
                }
                fetchingBranches = false
            }
        }
    }

    private func fetchPRs() {
        guard let (org, repoName) = githubComponents else { return }
        fetchingPRs = true
        prError = nil
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
            p.arguments = ["pr", "list", "--repo", "\(org)/\(repoName)", "--state", "open",
                           "--json", "number,title,headRefName,author", "--limit", "100"]
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
        let repoID = repo.id
        let headRef = pr.headRefName
        Task.detached {
            let fetchP = Process(); let fetchErrPipe = Pipe()
            fetchP.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            fetchP.arguments = ["-C", mainPath, "fetch", "origin", "pull/\(pr.number)/head:\(headRef)"]
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
            let worktreeP = Process(); let worktreeErrPipe = Pipe()
            worktreeP.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            worktreeP.arguments = ["-C", mainPath, "worktree", "add", path, headRef]
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
                    db.addRepoBranch(repoID: repoID, name: headRef)
                    checkingOutPR = nil
                }
            }
        }
    }

    private func checkoutIssue(_ issue: IssueEntry) {
        let branchName = "issue/\(issue.number)"
        guard let path = branchPath(branchName), let mainPath = mainClonePath, isMainCloned else { return }
        checkingOutIssue = issue.number
        let repoID = repo.id
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
                    db.addRepoBranch(repoID: repoID, name: branchName)
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
                "launchAgentContext":   "Review PR #\(pr.number): \(pr.title) (base: \(defaultBranch)).",
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
                if fetchingPRs {
                    ProgressView().scaleEffect(0.6).frame(width: 32)
                } else {
                    Button("Fetch") { fetchPRs() }
                        .buttonStyle(.plain)
                        .font(.system(size: 11)).foregroundStyle(Color.mgAccent)
                        .help("Fetch open PRs from GitHub")
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
                Text(fetchingPRs ? "Loading…" : "No open PRs")
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
    let repoID: String
    let existing: RepoBranch?
    let db: WorkspaceDB
    @Binding var isPresented: Bool
    @State private var branchName = ""

    var isEditing: Bool { existing != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(isEditing ? "Edit Branch" : "Add Branch")
                .font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.mgLabel)

            MGField(label: "Branch name", text: $branchName)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain).foregroundStyle(Color.mgMuted)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Button(isEditing ? "Save" : "Add") {
                    if let b = existing {
                        var updated = b; updated.name = branchName
                        db.updateRepoBranch(updated)
                    } else {
                        db.addRepoBranch(repoID: repoID, name: branchName)
                    }
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
        .onAppear { branchName = existing?.name ?? "" }
    }
}

// MARK: - Issues panel

private func agentSessionDir(type: String, id: String) -> String {
    let dir = NSHomeDirectory() + "/\(Srota.dir)/sessions/\(type)/\(id)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
}

private let issueStatuses = ["open", "in_progress", "closed"]

private struct IssuesPanel: View {
    @Environment(WorkspaceDB.self) var db
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppSettings.self) var settings
    @Environment(IssueAgentFocus.self) var agentFocus

    @State private var showAdd      = false
    @State private var showMCPSetup = false
    @State private var newTitle = ""
    @State private var newBody  = ""
    @State private var selectedOrg:     Organization?
    @State private var selectedFeature: Feature?

    var activeIssue: Issue? {
        guard agentFocus.activeTabID != "global" else { return nil }
        return db.issues.first { $0.id == agentFocus.activeTabID }
    }

    var body: some View {
        HSplitView {
            issueListPanel
                .frame(minWidth: 200, maxWidth: 260)
            issueAgentCenter
            if let issue = activeIssue {
                IssueInfoSidebar(issue: issue, db: db)
                    .frame(minWidth: 300, maxWidth: 480)
            }
        }
        .onAppear { ensureGlobalTab() }
        .onChange(of: db.issues) { reinjectOpenTabs() }
        .sheet(isPresented: $showAdd) {
            AddSheet(title: "New Issue", isPresented: $showAdd) {
                db.addIssue(title: newTitle, body: newBody,
                            orgID: selectedOrg?.id ?? "", featureID: selectedFeature?.id ?? "")
                newTitle = ""; newBody = ""; selectedOrg = nil; selectedFeature = nil
            } content: {
                MGField(label: "Title", text: $newTitle)
                MGField(label: "Body (optional)", text: $newBody)
                MGPicker(label: "Organization (optional)", items: db.organizations,
                         displayName: \.name, selected: $selectedOrg)
                MGPicker(label: "Feature (optional)", items: db.features,
                         displayName: \.name, selected: $selectedFeature)
            }
        }
        .sheet(isPresented: $showMCPSetup) {
            MCPSetupSheet(mcpPath: settings.resolvedMCPServerPath ?? "")
        }
    }

    // MARK: - Tab management

    private func ensureGlobalTab() {
        guard !agentFocus.agentTabs.contains(where: { $0.id == "global" }) else { return }
        agentFocus.agentTabs.insert(
            IssueAgentTab(id: "global", issueID: nil, tab: TerminalTab(colorScheme: colorScheme, workingDirectory: agentSessionDir(type: "issues", id: "global"))),
            at: 0
        )
    }

    private func openTab(for issue: Issue) {
        if agentFocus.agentTabs.contains(where: { $0.id == issue.id }) {
            agentFocus.activeTabID = issue.id
        } else {
            let cwds = repoPaths(for: issue)
            let cwd = agentSessionDir(type: "issues", id: String(issue.number))
            agentFocus.agentTabs.append(IssueAgentTab(
                id: issue.id, issueID: issue.id,
                tab: TerminalTab(colorScheme: colorScheme, workingDirectory: cwd)
            ))
            agentFocus.activeTabID = issue.id
            cwds.forEach { injectContext(issue: issue, into: $0) }
            if settings.resolvedMCPServerPath != nil && !UserDefaults.standard.bool(forKey: "mcpSetupDismissed") {
                showMCPSetup = true
            }
            evictLeastRecentTabIfNeeded()
        }
    }

    private func evictLeastRecentTabIfNeeded() {
        let closable = agentFocus.agentTabs.filter { $0.id != "global" }
        guard closable.count > maxOpenAgentTabs else { return }
        guard let lru = agentFocus.recentOrder.first(where: { id in
            id != agentFocus.activeTabID && closable.contains { $0.id == id }
        }) else { return }
        closeTab(lru)
    }

    private func closeTab(_ id: String) {
        if let agentTab = agentFocus.agentTabs.first(where: { $0.id == id }),
           let iid = agentTab.issueID {
            repoPaths(forID: iid).forEach { removeContext(from: $0) }
        }
        agentFocus.agentTabs.removeAll { $0.id == id }
        agentFocus.recentOrder.removeAll { $0 == id }
        if agentFocus.activeTabID == id { agentFocus.activeTabID = "global" }
    }

    private func repoClonePath(repoID: String) -> String? {
        guard let base = settings.baseWorkingDirectory,
              let repo = db.repos.first(where: { $0.id == repoID }) else { return nil }
        let safeBranch = repo.defaultBranch.replacingOccurrences(of: "/", with: "-")
        if let (org, repoName) = gitURLComponents(repo.url) {
            let safeOrg = org.replacingOccurrences(of: "/", with: "-")
            let safeRepo = repoName.replacingOccurrences(of: "/", with: "-")
            return "\(base)/organizations/\(safeOrg)/projects/\(safeRepo)/branches/\(safeBranch)"
        }
        let safeRepo = repo.name.replacingOccurrences(of: "/", with: "-")
        return "\(base)/repos/\(safeRepo)/branches/\(safeBranch)"
    }

    private func repoPaths(for issue: Issue) -> [String] {
        guard !issue.featureID.isEmpty else { return [] }
        return db.featureRepos
            .filter { $0.featureID == issue.featureID }
            .compactMap { fr -> String? in repoClonePath(repoID: fr.repoID) }
    }

    private func repoPaths(forID issueID: String) -> [String] {
        guard let issue = db.issues.first(where: { $0.id == issueID }) else { return [] }
        return repoPaths(for: issue)
    }

    private func reinjectOpenTabs() {
        for agentTab in agentFocus.agentTabs where agentTab.issueID != nil {
            guard let issue = db.issues.first(where: { $0.id == agentTab.issueID }) else { continue }
            repoPaths(for: issue).forEach { injectContext(issue: issue, into: $0) }
        }
    }

    // MARK: - Context injection

    private func injectContext(issue: Issue, into dir: String) {
        let featureName = db.features.first { $0.id == issue.featureID }?.name ?? "none"
        let orgName = db.organizations.first { $0.id == issue.orgID }?.name ?? "none"
        let block = """
            <!-- srota:start -->
            ## Issue Context (srota)
            **Issue:** \(issue.title)
            **ID:** `\(issue.id)`
            **Status:** \(issue.status)
            **Feature:** \(featureName)
            **Org:** \(orgName)

            **Body:**
            \(issue.body.isEmpty ? "_(none yet)_" : issue.body)

            ## srota MCP Tools
            If Srota MCP is configured:
            - `srota:update_issue(id, title?, body?, status?)` — update this issue
            - `srota:list_issues(feature_id?)` — list issues
            - `srota:list_features()` — list features
            - `srota:link_issue_to_feature(issue_id, feature_id)` — link to feature

            Current issue ID for MCP calls: `\(issue.id)`
            <!-- srota:end -->
            """
        for filename in ["CLAUDE.md", "AGENTS.md"] {
            let path = dir + "/" + filename
            var content = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            content = content.contains("<!-- srota:start -->")
                ? replaceBlock(in: content, with: block)
                : (content.isEmpty ? block : content + "\n\n" + block)
            try? content.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    private func removeContext(from dir: String) {
        for filename in ["CLAUDE.md", "AGENTS.md"] {
            let path = dir + "/" + filename
            guard var content = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            content = replaceBlock(in: content, with: nil)
            if content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try? FileManager.default.removeItem(atPath: path)
            } else {
                try? content.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
    }

    private func replaceBlock(in content: String, with replacement: String?) -> String {
        let start = "<!-- srota:start -->"; let end = "<!-- srota:end -->"
        guard let s = content.range(of: start), let e = content.range(of: end) else {
            return replacement.map { content + "\n\n" + $0 } ?? content
        }
        let before = String(content[content.startIndex..<s.lowerBound]).trimmingCharacters(in: .newlines)
        let after  = String(content[e.upperBound...]).trimmingCharacters(in: .newlines)
        guard let block = replacement else {
            return [before, after].filter { !$0.isEmpty }.joined(separator: "\n\n")
        }
        return [before, block, after].filter { !$0.isEmpty }.joined(separator: "\n\n")
    }


    // MARK: - Sub-views

    @ViewBuilder
    var issueListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Issues")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mgLabel)
                Text("\(db.issues.count)")
                    .font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.mgMuted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.mgSurface).clipShape(Capsule())
                Spacer()
                Button { db.refresh() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mgMuted)
                        .frame(width: 28, height: 28)
                        .background(Color.mgSurface)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .help("Refresh")
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mgAccent)
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
                    ForEach(db.issues) { issue in
                        SelectableRow(
                            item: issue,
                            isSelected: agentFocus.activeTabID == issue.id,
                            onSelect: { openTab(for: issue) },
                            onDelete: { closeTab(issue.id); db.deleteIssue(id: issue.id) }
                        ) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 4) {
                                        Text("#\(issue.number)")
                                            .font(.system(size: 11, weight: .medium, design: .monospaced))
                                            .foregroundStyle(Color.mgAccent)
                                        RowPrimary(text: issue.title)
                                    }
                                    let ctx = contextLabel(issue)
                                    if !ctx.isEmpty { RowSecondary(text: ctx) }
                                }
                                Spacer()
                                StatusBadge(status: issue.status)
                                Button { launchIssueWorkspace(issue) } label: {
                                    Image(systemName: "terminal")
                                        .font(.system(size: 10))
                                        .foregroundStyle(Color.mgAccent)
                                        .frame(width: 22, height: 22)
                                        .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 4)
                                }
                                .buttonStyle(.plain)
                                .help("Open workspace")
                            }
                        }
                    }
                    if db.issues.isEmpty {
                        Text("No issues — press +")
                            .font(.system(size: 13)).foregroundStyle(Color.mgMuted)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    }
                }
            }
            .background(Color.mgBg)
        }
    }

    @ViewBuilder
    var issueAgentCenter: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(agentFocus.agentTabs) { agentTab in
                        let label = agentTab.id == "global"
                            ? "Issues"
                            : (db.issues.first { $0.id == agentTab.issueID }?.title ?? "Issue")
                        FeatureTabChip(
                            label: label,
                            isActive: agentFocus.activeTabID == agentTab.id,
                            isCloseable: agentTab.id != "global",
                            onSelect: { agentFocus.activeTabID = agentTab.id },
                            onClose: { closeTab(agentTab.id) }
                        )
                    }
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
            }
            .background(Color.mgBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }

            ZStack {
                Color.black
                ForEach(agentFocus.agentTabs) { agentTab in
                    TerminalSurfaceView(context: agentTab.tab.focusedViewState)
                        .opacity(agentFocus.activeTabID == agentTab.id ? 1 : 0)
                }
            }
        }
        .onChange(of: agentFocus.activeTabID) {
            agentFocus.activeViewState = agentFocus.agentTabs
                .first { $0.id == agentFocus.activeTabID }?.tab.focusedViewState
        }
    }

    private func contextLabel(_ issue: Issue) -> String {
        var parts: [String] = []
        if !issue.orgID.isEmpty,
           let org = db.organizations.first(where: { $0.id == issue.orgID }) { parts.append(org.name) }
        if !issue.featureID.isEmpty,
           let f = db.features.first(where: { $0.id == issue.featureID }) { parts.append(f.name) }
        return parts.joined(separator: " · ")
    }

    private func launchIssueWorkspace(_ issue: Issue) {
        // Prefer issue-specific branches; fall back to feature repos if none linked yet
        let issueRepoLinks = db.issueRepos.filter { $0.issueID == issue.id }
        let sourceLinks: [(repoID: String, branch: String)] = issueRepoLinks.isEmpty && !issue.featureID.isEmpty
            ? db.featureRepos.filter { $0.featureID == issue.featureID }.map { ($0.repoID, $0.branch) }
            : issueRepoLinks.map { ($0.repoID, $0.branch) }
        let repoDetails: [(localPath: String, branch: String, name: String)] = sourceLinks.compactMap { link in
            guard let path = repoClonePath(repoID: link.repoID),
                  FileManager.default.fileExists(atPath: path),
                  let repo = db.repos.first(where: { $0.id == link.repoID }) else { return nil }
            return (path, link.branch, repo.name)
        }
        let worktreeBase = NSHomeDirectory() + "/\(Srota.dir)/worktrees/issues/\(issue.id)"
        let number = issue.number
        let title = issue.title

        Task.detached {
            let fm = FileManager.default
            try? fm.createDirectory(atPath: worktreeBase, withIntermediateDirectories: true)
            for detail in repoDetails {
                let worktreePath = worktreeBase + "/" + detail.name
                guard !fm.fileExists(atPath: worktreePath) else { continue }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                p.arguments = ["worktree", "add", worktreePath, detail.branch]
                p.currentDirectoryURL = URL(fileURLWithPath: detail.localPath)
                try? p.run(); p.waitUntilExit()
            }
            await MainActor.run {
                NotificationCenter.default.post(
                    name: .srotaOpenWorkspace,
                    object: nil,
                    userInfo: [
                        "path": worktreeBase,
                        "name": "issue #\(number)",
                        "folderName": title,
                        "folderTag": "Issues",
                        "createWorktree": false
                    ]
                )
            }
        }
    }
}

private struct IssueInfoSidebar: View {
    let issue: Issue
    let db: WorkspaceDB
    @State private var title = ""
    @State private var issueBody = ""
    @State private var status = "open"

    var linkedFeature: Feature? { db.features.first { $0.id == issue.featureID } }
    var linkedOrg: Organization? { db.organizations.first { $0.id == issue.orgID } }
    var linkedRepos: [(repo: RepoEntry, branch: String)] {
        db.issueRepos
            .filter { $0.issueID == issue.id }
            .compactMap { ir in
                guard let repo = db.repos.first(where: { $0.id == ir.repoID }) else { return nil }
                return (repo, ir.branch)
            }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Text("#\(issue.number)")
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.mgAccent)
                    .padding(.trailing, 6)
                TextField("Issue title", text: $title)
                    .font(.system(size: 14, weight: .semibold))
                    .textFieldStyle(.plain)
                    .foregroundStyle(Color.mgLabel)
                    .onSubmit { save() }
                Button { db.refresh(); load() } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.mgMuted)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.mgBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("STATUS")
                            .font(.system(size: 10, weight: .medium)).tracking(0.8)
                            .foregroundStyle(Color.mgMuted)
                        Picker("", selection: $status) {
                            ForEach(issueStatuses, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("BODY")
                            .font(.system(size: 10, weight: .medium)).tracking(0.8)
                            .foregroundStyle(Color.mgMuted)
                        TextEditor(text: $issueBody)
                            .font(.system(size: 13, design: .monospaced))
                            .foregroundStyle(Color.mgLabel)
                            .scrollContentBackground(.hidden)
                            .padding(10)
                            .frame(minHeight: 120)
                            .background(Color.mgSurface)
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    if let feature = linkedFeature {
                        DetailRow(label: "Feature") {
                            Text(feature.name)
                                .font(.system(size: 13)).foregroundStyle(Color.mgLabel)
                        }
                    }

                    if let org = linkedOrg {
                        DetailRow(label: "Org") {
                            Text(org.name)
                                .font(.system(size: 13)).foregroundStyle(Color.mgLabel)
                        }
                    }

                    let repos = linkedRepos
                    if !repos.isEmpty {
                        DetailRow(label: "Repos") {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(repos, id: \.repo.id) { link in
                                    HStack(spacing: 6) {
                                        Text(link.repo.name)
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(Color.mgLabel)
                                            .lineLimit(1)
                                            .truncationMode(.middle)
                                        Spacer(minLength: 4)
                                        if !link.branch.isEmpty {
                                            Text(link.branch)
                                                .font(.system(size: 10, design: .monospaced))
                                                .foregroundStyle(Color.mgMuted)
                                                .lineLimit(1)
                                                .truncationMode(.middle)
                                        }
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 6)
                                    .background(Color.mgSurface)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))
                                }
                            }
                        }
                    }
                }
                .padding(14)
            }

            HStack {
                Spacer()
                Button("Save") { save() }
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.mgAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.mgBg)
            .overlay(alignment: .top) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
        }
        .background(Color.mgBg)
        .onAppear { load() }
        .onChange(of: issue.id) { load() }
        .onChange(of: issue.title) { load() }
        .onChange(of: issue.status) { load() }
        .onChange(of: issue.body) { load() }
    }

    private func load() {
        let fresh = db.issues.first { $0.id == issue.id } ?? issue
        title = fresh.title
        issueBody = fresh.body
        status = fresh.status
    }

    private func save() {
        var i = issue; i.title = title; i.body = issueBody; i.status = status
        db.updateIssue(i)
    }
}

private struct StatusBadge: View {
    let status: String
    var body: some View {
        Text(status)
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(status == "open" ? Color.green : Color.mgMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background((status == "open" ? Color.green : Color.mgMuted).opacity(0.15))
            .clipShape(Capsule())
    }
}

// MARK: - MCP setup popup

struct MCPSetupSheet: View {
    let mcpPath: String
    @Environment(\.dismiss) private var dismiss
    @State private var dontShowAgain = UserDefaults.standard.bool(forKey: "mcpSetupDismissed")

    private var setupPrompt: String {
        "The srota MCP server is located at:\n\(mcpPath)\n\nTo run it:\nbun \"\(mcpPath)\"\n\nAdd it as an MCP server in your agent config with:\n  command: bun\n  args: [\"\(mcpPath)\"]"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Set up srota MCP")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.mgLabel)
                    Text("Copy and paste this prompt into your agent to configure MCP.")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mgMuted)
                }
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.mgMuted)
                        .frame(width: 22, height: 22)
                        .background(Color.mgSurface)
                        .clipShape(Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(20)

            Rectangle().fill(Color.mgBorder).frame(height: 1)

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    MCPPromptBlock(title: "MCP Setup", subtitle: "bun \(mcpPath)", content: setupPrompt)
                }
                .padding(20)
            }

            Rectangle().fill(Color.mgBorder).frame(height: 1)

            HStack {
                Toggle("Don't show again", isOn: $dontShowAgain)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mgMuted)
                    .onChange(of: dontShowAgain) { _, val in
                        UserDefaults.standard.set(val, forKey: "mcpSetupDismissed")
                    }
                Spacer()
                Button("Close") { dismiss() }
                    .buttonStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 14).padding(.vertical, 7)
                    .background(Color.mgAccent)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
            .padding(20)
        }
        .frame(width: 560)
        .background(Color.mgBg)
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
