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
    case tasks           = "Flow"
    case workspaces      = "Workspaces"
    case agents          = "Agents"

    var icon: String {
        switch self {
        case .tasks:          return "checklist"
        case .workspaces:     return "terminal"
        case .agents:         return "bolt.fill"
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
        }
    }
}

// MARK: - Agents panel (split view: daemon-tracked agents on the left, an attached live terminal on the right)

// Even 50/50 splits only — no per-split resize fraction. "Add to split" always splits the
// currently-focused leaf's slot in the chosen direction; minimizing a leaf collapses its slot
// back into its sibling, and collapsing to a single leaf drops `splitRoot` to nil entirely so
// AgentsPanel falls back to the plain single-`detail` path instead of a 1-leaf tree.
private enum AgentSplitNode {
    case leaf(String)
    indirect case split(Axis, AgentSplitNode, AgentSplitNode)

    var containedStableIDs: Set<String> {
        switch self {
        case .leaf(let id): return [id]
        case .split(_, let a, let b): return a.containedStableIDs.union(b.containedStableIDs)
        }
    }

    func replacingLeaf(_ target: String, addingInDirection axis: Axis, newID: String) -> AgentSplitNode {
        switch self {
        case .leaf(let id):
            return id == target ? .split(axis, .leaf(id), .leaf(newID)) : self
        case .split(let a, let first, let second):
            return .split(a, first.replacingLeaf(target, addingInDirection: axis, newID: newID),
                           second.replacingLeaf(target, addingInDirection: axis, newID: newID))
        }
    }

    // Swaps which agent occupies a leaf's slot without changing the tree shape — this is how
    // plain (left-)clicking a non-split agent "switches" the focused pane instead of adding one.
    func replacingLeafID(_ target: String, with newID: String) -> AgentSplitNode {
        switch self {
        case .leaf(let id):
            return id == target ? .leaf(newID) : self
        case .split(let axis, let first, let second):
            return .split(axis, first.replacingLeafID(target, with: newID), second.replacingLeafID(target, with: newID))
        }
    }

    // nil means the whole tree became empty (only relevant when called on a lone `.leaf`).
    func removingLeaf(_ target: String) -> AgentSplitNode? {
        switch self {
        case .leaf(let id):
            return id == target ? nil : self
        case .split(let axis, let first, let second):
            switch (first.removingLeaf(target), second.removingLeaf(target)) {
            case (nil, nil): return nil
            case (nil, let s?): return s
            case (let f?, nil): return f
            case (let f?, let s?): return .split(axis, f, s)
            }
        }
    }
}

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
    @State private var listWidth: CGFloat = 280
    @State private var listVisible = true
    @State private var splitRoot: AgentSplitNode?
    @State private var focusedSplitStableID: String?
    @State private var attachments: [String: AgentAttachment] = [:]

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
        VStack(spacing: 0) {
            header
            Rectangle().fill(Color.mgBorder).frame(height: 1)
            HStack(spacing: 0) {
                VStack(spacing: 0) {
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
                                        isSelected: splitRoot != nil ? row.stableID == focusedSplitStableID : row.stableID == selectedStableID,
                                        // Disables "Add to split" not just for agents already inside an
                                        // active split, but also for the lone agent currently shown via
                                        // the plain single-detail view — otherwise right-clicking it
                                        // wraps that same agent in a redundant, confusing one-pane split.
                                        isInSplit: splitRoot != nil
                                            ? splitRoot!.containedStableIDs.contains(row.stableID)
                                            : row.stableID == selectedStableID,
                                        onSelect: { selectOrSwitch(to: row) },
                                        onAddToSplit: { direction in addToSplit(row, direction: direction) }
                                    )
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                        }
                    }
                }
                .frame(width: listVisible ? listWidth : 0, alignment: .leading)
                .clipped()
                .allowsHitTesting(listVisible)

                SidebarDivider(sidebarVisible: listVisible, width: $listWidth)

                Group {
                    if let splitRoot {
                        AgentSplitTreeView(node: splitRoot) { AnyView(splitPane(for: $0)) }
                    } else {
                        detail
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.spring(duration: 0.22, bounce: 0.0), value: listVisible)
        .onAppear { refresh() }
        .onChange(of: focusedSplitStableID) { _, newID in
            if let newID, let attach = attachments[newID] { focusTerminalSurface(for: attach.viewState) }
        }
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
                // Without this, SwiftUI treats consecutive attachments as the SAME view identity
                // (same type/position in the tree) and reuses the underlying NSView + its
                // long-lived TerminalSurfaceCoordinator across agent switches, just calling
                // updateNSView with the new context — reconfiguring one live coordinator from
                // agent A's session straight to agent B's. tearDownSurface then reads
                // `configuration.inMemorySession` AFTER it's already been overwritten by B's
                // config, so it gates the free against the wrong (empty) session, skips its
                // safety wait, and frees the surface while A's session can still be mid-write
                // (the os_unfair_lock corruption crash). Forcing a new identity per attachment
                // makes SwiftUI dismantle the old NSView and build a fresh one per agent, so each
                // coordinator only ever owns one session for its whole lifetime.
                TerminalSurfaceView(context: attachment.viewState)
                    .id(attachment.token)
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
            Button { listVisible.toggle() } label: {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 12))
                    .foregroundStyle(listVisible ? Color.mgLabel : Color.mgMuted)
            }
            .buttonStyle(.plain)
            .help(listVisible ? "Hide agent list" : "Show agent list")

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

    // MARK: - Split view (multiple agents side by side)

    // Plain click on a row: if it's already showing in the split, just focus that pane. Otherwise,
    // while a split is active, "select" means switch the focused pane's agent to this one (there's
    // no separate single-detail view visible to fall back to once any split exists). Only when no
    // split is active at all does this touch the old single-detail `selectedStableID`/`attachment`.
    private func selectOrSwitch(to row: DaemonAgentRow) {
        guard let root = splitRoot else {
            selectedStableID = row.stableID
            attachment = nil
            return
        }
        if root.containedStableIDs.contains(row.stableID) {
            focusedSplitStableID = row.stableID
            return
        }
        let target = focusedSplitStableID.flatMap { root.containedStableIDs.contains($0) ? $0 : nil }
            ?? root.containedStableIDs.first
        guard let target else { return }
        attachments[target] = nil
        splitRoot = root.replacingLeafID(target, with: row.stableID)
        focusedSplitStableID = row.stableID
    }

    private func addToSplit(_ row: DaemonAgentRow, direction: Axis) {
        guard splitRoot?.containedStableIDs.contains(row.stableID) != true else { return }
        if let root = splitRoot {
            let target = focusedSplitStableID.flatMap { root.containedStableIDs.contains($0) ? $0 : nil }
                ?? root.containedStableIDs.first
            guard let target else { return }
            splitRoot = root.replacingLeaf(target, addingInDirection: direction, newID: row.stableID)
        } else if let current = selectedStableID {
            // Same agent as the one already shown alone — nothing to split, so no-op instead of
            // wrapping it in a redundant one-pane split (the menu item is disabled for this case
            // too, but guard here as well rather than relying solely on the UI).
            guard current != row.stableID else { return }
            // Drop the old single-detail attachment rather than moving it into `attachments` —
            // moving the SAME AgentAttachment into splitPane's view-tree position doesn't actually
            // preserve its terminal surface (SwiftUI still builds a new NSView there since the
            // structural position changed), so it just showed a blank pane with no daemon replay.
            // Letting splitPane's own onAppear→attachSplit path create a fresh attachment (like
            // re-selecting an agent already does) is simpler and actually renders content. The
            // daemon's existing steal/onStolen handshake resolves the brief dual ownership safely.
            attachment = nil
            splitRoot = .split(direction, .leaf(current), .leaf(row.stableID))
        } else {
            splitRoot = .leaf(row.stableID)
        }
        focusedSplitStableID = row.stableID
    }

    private func minimizeFromSplit(_ stableID: String) {
        attachments[stableID] = nil
        guard let root = splitRoot else { return }
        let updated = root.removingLeaf(stableID)
        splitRoot = updated
        if focusedSplitStableID == stableID { focusedSplitStableID = updated?.containedStableIDs.first }
    }

    private func attachSplit(_ row: DaemonAgentRow) {
        let token = UUID()
        let stableID = row.stableID
        let attachmentsBinding = $attachments
        attachmentsBinding.wrappedValue[stableID] = AgentAttachment(
            stableID: stableID, cwd: row.cwd, colorScheme: colorScheme, daemon: daemon, token: token
        ) {
            // Same re-entrancy guard as `attach(_:)`'s onStolen — only clear if still this instance.
            if attachmentsBinding.wrappedValue[stableID]?.token == token {
                attachmentsBinding.wrappedValue[stableID] = nil
            }
        }
        // Focus was already requested (e.g. by addToSplit) before this attachment existed to focus.
        if focusedSplitStableID == stableID, let attach = attachmentsBinding.wrappedValue[stableID] {
            focusTerminalSurface(for: attach.viewState)
        }
    }

    @ViewBuilder
    private func splitPane(for stableID: String) -> some View {
        let row = rows.first { $0.stableID == stableID }
        // Header as an .overlay ON TOP of the content, not stacked before it in a plain VStack —
        // mirrors TerminalContentView.paneView exactly. TerminalSurfaceView is AppKit-backed and can
        // win hit-testing over plain SwiftUI siblings stacked above it, which silently swallowed
        // clicks on this pane's minimize button; .overlay guarantees the header paints and
        // hit-tests on top regardless of any AppKit view z-order quirks underneath.
        Group {
            if let row {
                if let attach = attachments[stableID] {
                    TerminalSurfaceView(context: attach.viewState)
                        .id(attach.token)
                } else if claimedElsewhereStableIDs.contains(stableID) {
                    PaneStartOverlay(cwd: row.cwd, label: "Use Here") { attachSplit(row) }
                } else {
                    Color.clear.onAppear { attachSplit(row) }
                }
            } else {
                // Row disappeared (e.g. the agent's process exited) — nothing left to show.
                Color.clear.onAppear { minimizeFromSplit(stableID) }
            }
        }
        .padding(.top, 29)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            VStack(spacing: 0) {
                splitPaneHeader(stableID: stableID, row: row)
                Rectangle().fill(Color.mgBorder).frame(height: 1)
            }
        }
        // Covers the terminal content area too, not just the header — clicking into the terminal
        // to type should also move the focus highlight, matching workspace panes' own behavior
        // (TerminalContentView.paneView attaches its equivalent gesture over the whole pane).
        .simultaneousGesture(TapGesture().onEnded { focusedSplitStableID = stableID })
    }

    @ViewBuilder
    private func splitPaneHeader(stableID: String, row: DaemonAgentRow?) -> some View {
        let focused = focusedSplitStableID == stableID
        ZStack(alignment: .bottom) {
            HStack(spacing: 6) {
                Text(row?.title ?? stableID)
                    .font(.system(size: 12, weight: focused ? .medium : .regular))
                    .foregroundStyle(focused ? Color.mgLabel : Color.mgMuted)
                    .lineLimit(1)
                if let status = row?.status {
                    AgentStatusBadge(status: status)
                }
                Spacer(minLength: 0)
                Button { minimizeFromSplit(stableID) } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Color.mgMuted)
                        .frame(width: 20, height: 20)
                        // .buttonStyle(.plain) on macOS hit-tests the label's drawn content, not
                        // its frame, unless the hit shape is stated explicitly — without this the
                        // tappable area shrank to roughly the "minus" glyph's own pixels.
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Minimize (agent keeps running in the background)")
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .contentShape(Rectangle())

            Rectangle()
                .fill(focused ? Color.mgAccent : Color.mgBorder)
                .frame(height: focused ? 2 : 1)
        }
    }
}

// Recursive on purpose: each `.split` level is its own view instance with its own local `width`
// state (exactly like ResizableSidebar owns its width) — no fraction lives in AgentSplitNode
// itself, so resizing one split doesn't re-render sibling splits elsewhere in the tree. Reuses
// SidebarDivider/SidebarResizeLogic (the same mechanism the app sidebar resizes with) rather than
// inventing a second drag-resize implementation.
private struct AgentSplitTreeView: View {
    let node: AgentSplitNode
    let renderLeaf: (String) -> AnyView
    // nil until the user actually drags — defaults to 50% of whatever space is currently
    // available (measured below) instead of a fixed guess, and locks to an explicit value once set.
    @State private var size: CGFloat?

    var body: some View {
        switch node {
        case .leaf(let stableID):
            renderLeaf(stableID)
        case .split(let axis, let first, let second):
            GeometryReader { geo in
                let total = axis == .horizontal ? geo.size.width : geo.size.height
                let resolvedSize = size ?? total / 2
                let sizeBinding = Binding(get: { resolvedSize }, set: { size = $0 })
                if axis == .horizontal {
                    HStack(spacing: 0) {
                        AgentSplitTreeView(node: first, renderLeaf: renderLeaf)
                            .frame(width: resolvedSize)
                        // No maxWidth cap: unlike the app sidebar, a split pane's sibling is
                        // flexible (maxWidth: .infinity), so it should be draggable up to most of
                        // the available space, not the sidebar's fixed 500pt ceiling.
                        SidebarDivider(sidebarVisible: true, width: sizeBinding, axis: .horizontal, maxWidth: .greatestFiniteMagnitude)
                        AgentSplitTreeView(node: second, renderLeaf: renderLeaf)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    VStack(spacing: 0) {
                        AgentSplitTreeView(node: first, renderLeaf: renderLeaf)
                            .frame(height: resolvedSize)
                        SidebarDivider(sidebarVisible: true, width: sizeBinding, axis: .vertical, maxWidth: .greatestFiniteMagnitude)
                        AgentSplitTreeView(node: second, renderLeaf: renderLeaf)
                            .frame(maxHeight: .infinity)
                    }
                }
            }
        }
    }
}

// Mirrors TerminalTab's own pane-attach pattern exactly — this is just another consumer of
// spawnOrAttach, not a separate "secondary" mechanism. Switching the Agents-tab selection away
// drops this instance (see `attachment = nil` above), which deallocates `viewState` and tears
// down its terminal surface synchronously on the main thread. `deinit` calls `detachViewer` first
// so the daemon stops routing background PTY output into a surface that's mid-teardown — without
// it, a background write can race the surface's deallocation and corrupt its internal lock (crash:
// "os_unfair_lock is corrupt" in Termio.processOutput vs. drawFrame).
private final class AgentAttachment {
    let stableID: String
    let token: UUID
    let viewState: TerminalViewState
    private weak var daemon: DaemonConnection?

    init(stableID: String, cwd: String, colorScheme: ColorScheme, daemon: DaemonConnection, token: UUID, onStolen: @escaping () -> Void) {
        self.stableID = stableID
        self.token = token
        self.daemon = daemon
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

    deinit {
        daemon?.detachViewer(stableID: stableID)
    }
}

private struct DaemonAgentRowView: View {
    let row: DaemonAgentRow
    let isSelected: Bool
    let isInSplit: Bool
    let onSelect: () -> Void
    let onAddToSplit: (Axis) -> Void
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
        .contextMenu {
            Button("Add to split → Horizontally") { onAddToSplit(.horizontal) }
                .disabled(isInSplit)
            Button("Add to split → Vertically") { onAddToSplit(.vertical) }
                .disabled(isInSplit)
        }
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
