import AppKit
import Observation
import SwiftUI

// MARK: - Key combo

struct KeyCombo: Equatable {
    let modifiers: NSEvent.ModifierFlags
    let key: String

    init?(_ string: String) {
        let parts = string.lowercased().components(separatedBy: "+")
        guard let k = parts.last, !k.isEmpty else { return nil }
        var mods: NSEvent.ModifierFlags = []
        for part in parts.dropLast() {
            switch part {
            case "ctrl", "control":      mods.insert(.control)
            case "cmd", "command":       mods.insert(.command)
            case "opt", "option", "alt": mods.insert(.option)
            case "shift":                mods.insert(.shift)
            default: return nil
            }
        }
        self.modifiers = mods
        self.key = k
    }

    func matches(_ event: NSEvent) -> Bool {
        let relevant: NSEvent.ModifierFlags = [.control, .command, .option, .shift]
        guard event.modifierFlags.intersection(relevant) == modifiers else { return false }
        return (event.charactersIgnoringModifiers?.lowercased() ?? "") == key
    }

    var display: String {
        var parts: [String] = []
        if modifiers.contains(.control) { parts.append("⌃") }
        if modifiers.contains(.option)  { parts.append("⌥") }
        if modifiers.contains(.shift)   { parts.append("⇧") }
        if modifiers.contains(.command) { parts.append("⌘") }
        parts.append(key.uppercased())
        return parts.joined()
    }
}

// MARK: - Manager

@Observable @MainActor
final class KeyboardShortcutManager {
    var prefixKey: String = "ctrl+b" {
        didSet { prefixCombo = KeyCombo(prefixKey) }
    }
    private(set) var awaitingChord = false
    var showWorkspaceSwitcher = false
    var showLazygit = false
    var lazygitCWD: String? = nil
    var actions: [String: () -> Void] = [:]

    private var prefixCombo: KeyCombo? = KeyCombo("ctrl+b")
    private var monitor: Any?
    private var chordResetTask: Task<Void, Never>?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            guard Thread.isMainThread else { return event }
            return self.handle(event) ? nil : event
        }
    }

    func stop() {
        if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
        chordResetTask?.cancel()
        chordResetTask = nil
        awaitingChord = false
    }

    private func handle(_ event: NSEvent) -> Bool {
        if showWorkspaceSwitcher || showLazygit { return false }
        // Don't intercept when user is editing text
        if let responder = NSApp.keyWindow?.firstResponder,
           responder is NSTextView || responder is NSTextField {
            return false
        }

        guard let combo = prefixCombo else { return false }

        if awaitingChord {
            chordResetTask?.cancel()
            chordResetTask = nil
            awaitingChord = false
            if event.keyCode == 53 { return true } // ESC cancels chord
            let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
            if let action = actions[key] { action(); return true }
            return false
        }

        if combo.matches(event) {
            awaitingChord = true
            chordResetTask?.cancel()
            chordResetTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled else { return }
                self?.awaitingChord = false
            }
            return true
        }
        return false
    }
}

// MARK: - TerminalTab pane focus (directional)

extension TerminalTab {
    enum FocusDirection { case left, right, up, down }

    func focusPane(direction: FocusDirection) {
        let currentID = focusedPaneID
        guard let cl = paneLayouts[currentID] else { return }
        var bestID:   UUID?    = nil
        var bestDist: CGFloat  = .infinity

        for entry in panes where entry.id != currentID {
            guard let l = paneLayouts[entry.id] else { continue }
            let dist: CGFloat
            switch direction {
            case .left:
                guard l.x + l.w <= cl.x + 0.01 else { continue }
                dist = cl.x - (l.x + l.w)
            case .right:
                guard l.x >= cl.x + cl.w - 0.01 else { continue }
                dist = l.x - (cl.x + cl.w)
            case .up:
                guard l.y + l.h <= cl.y + 0.01 else { continue }
                dist = cl.y - (l.y + l.h)
            case .down:
                guard l.y >= cl.y + cl.h - 0.01 else { continue }
                dist = l.y - (cl.y + cl.h)
            }
            if dist < bestDist { bestDist = dist; bestID = entry.id }
        }

        if let bestID { focusedPaneID = bestID }
    }
}

// MARK: - Workspace tab navigation

extension Workspace {
    func selectNextTab() {
        guard !tabs.isEmpty else { return }
        guard let id = selectedTabID,
              let idx = tabs.firstIndex(where: { $0.id == id }) else {
            selectedTabID = tabs.first?.id; return
        }
        selectedTabID = tabs[(idx + 1) % tabs.count].id
    }

    func selectPrevTab() {
        guard !tabs.isEmpty else { return }
        guard let id = selectedTabID,
              let idx = tabs.firstIndex(where: { $0.id == id }) else {
            selectedTabID = tabs.last?.id; return
        }
        selectedTabID = tabs[(idx - 1 + tabs.count) % tabs.count].id
    }

    func selectTab(at index: Int) {
        guard tabs.indices.contains(index) else { return }
        selectedTabID = tabs[index].id
    }
}

// MARK: - Chord indicator overlay

struct ChordIndicator: View {
    let display: String

    var body: some View {
        HStack(spacing: 8) {
            Text(display)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color(red: 1.0, green: 0.45, blue: 0.15))
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color(red: 1.0, green: 0.45, blue: 0.15).opacity(0.15))
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.35))
            Text("waiting for key…")
                .font(.system(size: 12))
                .foregroundStyle(Color.white.opacity(0.45))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.ultraThinMaterial)
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(Color(red: 1.0, green: 0.45, blue: 0.15).opacity(0.3)))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.5), radius: 16, y: 6)
    }
}

// MARK: - Workspace switcher data

struct SwitcherPane {
    let id: UUID
    let name: String?
    let cwd: String?
}

struct SwitcherTab {
    let id: UUID
    let title: String
    let cwd: String?
    let panes: [SwitcherPane]
    let isSelected: Bool
}

struct SwitcherWorkspace {
    let id: UUID
    let name: String
    let folder: String?
    let tabs: [SwitcherTab]
    let isSelected: Bool
    let isPinned: Bool
    let isActive: Bool
}

struct SwitcherModel {
    let workspaceByID: [UUID: SwitcherWorkspace]
    let allWorkspaceIDs: [UUID]
    let activeWorkspaceIDs: [UUID]
    let selectedWorkspaceID: UUID?
    let selectedTabIDByWorkspaceID: [UUID: UUID]
    let selectedPaneIDByTabID: [UUID: UUID]

    func visibleWorkspaceIDs(showAll: Bool) -> [UUID] {
        if showAll || activeWorkspaceIDs.isEmpty { return allWorkspaceIDs }
        return activeWorkspaceIDs
    }
}

// MARK: - Workspace switcher overlay

struct WorkspaceSwitcherOverlay: View {
    let model: SwitcherModel
    let onSelectWorkspace: (UUID) -> Void
    let onSelectTab: (UUID, UUID) -> Void
    let onSelectPane: (UUID, UUID, UUID) -> Void
    let onDismiss: () -> Void

    private enum Panel { case workspaces, tabs, panes }

    @State private var highlighted: Int = 0    // workspace index
    @State private var tabHighlighted: Int = 0  // tab index within selected workspace
    @State private var paneHighlighted: Int = 0 // pane index within highlighted tab
    @State private var panel: Panel = .workspaces
    @State private var showAll = false
    private let accent = Color(red: 1.0, green: 0.45, blue: 0.15)

    private var visibleWorkspaceIDs: [UUID] { model.visibleWorkspaceIDs(showAll: showAll) }

    private var workspaces: [SwitcherWorkspace] {
        visibleWorkspaceIDs.compactMap { model.workspaceByID[$0] }
    }

    private var selectedWorkspace: SwitcherWorkspace? {
        workspaces.indices.contains(highlighted) ? workspaces[highlighted] : nil
    }

    private var selectedTab: SwitcherTab? {
        guard let ws = selectedWorkspace, ws.tabs.indices.contains(tabHighlighted) else { return nil }
        return ws.tabs[tabHighlighted]
    }

    // MARK: - Keyboard actions

    private func navUp() {
        switch panel {
        case .workspaces:
            let c = max(workspaces.count, 1)
            highlighted = (highlighted - 1 + c) % c
            tabHighlighted = 0; paneHighlighted = 0
        case .tabs:
            let c = max(selectedWorkspace?.tabs.count ?? 1, 1)
            tabHighlighted = (tabHighlighted - 1 + c) % c
            paneHighlighted = 0
        case .panes:
            let c = max(selectedTab?.panes.count ?? 1, 1)
            paneHighlighted = (paneHighlighted - 1 + c) % c
        }
    }

    private func navDown() {
        switch panel {
        case .workspaces:
            let c = max(workspaces.count, 1)
            highlighted = (highlighted + 1) % c
            tabHighlighted = 0; paneHighlighted = 0
        case .tabs:
            let c = max(selectedWorkspace?.tabs.count ?? 1, 1)
            tabHighlighted = (tabHighlighted + 1) % c
            paneHighlighted = 0
        case .panes:
            let c = max(selectedTab?.panes.count ?? 1, 1)
            paneHighlighted = (paneHighlighted + 1) % c
        }
    }

    private func navRight() {
        switch panel {
        case .workspaces:
            if selectedWorkspace?.tabs.isEmpty == false { panel = .tabs; tabHighlighted = 0 }
        case .tabs:
            if (selectedTab?.panes.count ?? 0) > 1 { panel = .panes; paneHighlighted = 0 }
        case .panes:
            break
        }
    }

    private func navLeft() {
        switch panel {
        case .workspaces: onDismiss()
        case .tabs: panel = .workspaces
        case .panes: panel = .tabs
        }
    }

    private func navEnter() {
        guard let ws = selectedWorkspace else { return }
        switch panel {
        case .workspaces:
            onSelectWorkspace(ws.id)
        case .tabs:
            guard ws.tabs.indices.contains(tabHighlighted) else { return }
            onSelectTab(ws.id, ws.tabs[tabHighlighted].id)
        case .panes:
            guard let tab = selectedTab, tab.panes.indices.contains(paneHighlighted) else { return }
            onSelectPane(ws.id, tab.id, tab.panes[paneHighlighted].id)
        }
    }

    private func normalizeSelection(preferredWorkspaceID: UUID? = nil) {
        let workspaceIDs = visibleWorkspaceIDs
        guard !workspaceIDs.isEmpty else {
            highlighted = 0
            tabHighlighted = 0
            paneHighlighted = 0
            panel = .workspaces
            return
        }

        if let preferredWorkspaceID,
           let idx = workspaceIDs.firstIndex(of: preferredWorkspaceID) {
            highlighted = idx
        } else if !workspaceIDs.indices.contains(highlighted) {
            if let selectedWorkspaceID = model.selectedWorkspaceID,
               let idx = workspaceIDs.firstIndex(of: selectedWorkspaceID) {
                highlighted = idx
            } else {
                highlighted = min(highlighted, workspaceIDs.count - 1)
            }
        }

        guard let ws = selectedWorkspace else {
            highlighted = 0
            tabHighlighted = 0
            paneHighlighted = 0
            panel = .workspaces
            return
        }

        guard !ws.tabs.isEmpty else {
            tabHighlighted = 0
            paneHighlighted = 0
            panel = .workspaces
            return
        }

        if !ws.tabs.indices.contains(tabHighlighted) {
            if let selectedTabID = model.selectedTabIDByWorkspaceID[ws.id],
               let idx = ws.tabs.firstIndex(where: { $0.id == selectedTabID }) {
                tabHighlighted = idx
            } else {
                tabHighlighted = min(tabHighlighted, ws.tabs.count - 1)
            }
        }

        guard let tab = selectedTab else {
            tabHighlighted = 0
            paneHighlighted = 0
            panel = .workspaces
            return
        }

        if tab.panes.isEmpty {
            paneHighlighted = 0
            if panel == .panes { panel = .tabs }
            return
        }

        if !tab.panes.indices.contains(paneHighlighted) {
            if let selectedPaneID = model.selectedPaneIDByTabID[tab.id],
               let idx = tab.panes.firstIndex(where: { $0.id == selectedPaneID }) {
                paneHighlighted = idx
            } else {
                paneHighlighted = min(paneHighlighted, tab.panes.count - 1)
            }
        }

        if tab.panes.count <= 1, panel == .panes {
            panel = .tabs
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.opacity(0.001)
                    .ignoresSafeArea()
                    .onTapGesture { onDismiss() }

                HStack(spacing: 0) {
                    workspaceList
                    Rectangle().fill(Color.white.opacity(0.07)).frame(width: 1)
                    tabsPanel
                }
                .frame(width: geo.size.width * 0.7, height: geo.size.height * 0.7)
                .background(.ultraThinMaterial)
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(accent.opacity(0.2)))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.65), radius: 32, y: 10)
                .overlay(
                    WorkspaceSwitcherKeyCapture(
                        count: workspaces.count,
                        onUp: navUp,
                        onDown: navDown,
                        onLeft: navLeft,
                        onRight: navRight,
                        onEnter: navEnter,
                        onNumber: { n in
                            let idx = n - 1
                            guard idx < workspaces.count else { return }
                            highlighted = idx; panel = .workspaces
                            tabHighlighted = 0; paneHighlighted = 0
                            onSelectWorkspace(workspaces[idx].id)
                        },
                        onDismiss: onDismiss
                    )
                    .frame(width: 0, height: 0)
                )
            }
        }
        .onAppear { normalizeSelection() }
        .onChange(of: showAll) { _, _ in
            normalizeSelection(preferredWorkspaceID: selectedWorkspace?.id)
        }
    }

    // MARK: - Left panel: workspace list

    @ViewBuilder private var workspaceList: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Workspaces")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(panel == .workspaces ? accent.opacity(0.8) : Color.white.opacity(0.3))
                Spacer()
                Button(showAll ? "Active" : "All") {
                    let preferredWorkspaceID = selectedWorkspace?.id
                    showAll.toggle()
                    panel = .workspaces
                    normalizeSelection(preferredWorkspaceID: preferredWorkspaceID)
                }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(showAll ? Color.white.opacity(0.6) : accent.opacity(0.7))
                    .buttonStyle(.plain)
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            Divider().opacity(0.1)

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let groups = groupedWorkspaces()
                    ForEach(groups.indices, id: \.self) { gi in
                        let (folderName, items) = groups[gi]
                        if gi > 0 { Divider().opacity(0.08).padding(.vertical, 4) }
                        if let name = folderName {
                            HStack(spacing: 5) {
                                Image(systemName: "folder").font(.system(size: 9))
                                    .foregroundStyle(Color.white.opacity(0.25))
                                Text(name).font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Color.white.opacity(0.3))
                            }
                            .padding(.horizontal, 12).padding(.bottom, 2)
                        }
                        ForEach(items, id: \.0) { (i, ws) in wsRow(i: i, ws: ws) }
                    }
                }
                .padding(.vertical, 8).padding(.horizontal, 4)
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    // MARK: - Right panel: tabs + panes

    @ViewBuilder private var tabsPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 4) {
                if let ws = selectedWorkspace {
                    Text(ws.name)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(panel == .workspaces ? Color.white.opacity(0.3) : Color.white.opacity(0.5))
                        .lineLimit(1)
                    if panel == .tabs || panel == .panes {
                        Image(systemName: "chevron.right").font(.system(size: 8))
                            .foregroundStyle(Color.white.opacity(0.2))
                        Text("tabs").font(.system(size: 10))
                            .foregroundStyle(panel == .tabs ? accent.opacity(0.8) : Color.white.opacity(0.3))
                    }
                    if panel == .panes, let tab = selectedTab {
                        Image(systemName: "chevron.right").font(.system(size: 8))
                            .foregroundStyle(Color.white.opacity(0.2))
                        Text(tab.title).font(.system(size: 10))
                            .foregroundStyle(accent.opacity(0.8))
                            .lineLimit(1)
                    }
                } else {
                    Text("Tabs")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.3))
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 12)

            Divider().opacity(0.1)

            if let ws = selectedWorkspace, !ws.tabs.isEmpty {
                ScrollView {
                    VStack(spacing: 8) {
                        ForEach(Array(ws.tabs.enumerated()), id: \.offset) { i, tab in
                            tabCard(tab: tab, tabIdx: i, wsID: ws.id)
                        }
                    }
                    .padding(12)
                }
            } else {
                Spacer()
                Text("No tabs")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.white.opacity(0.2))
                    .frame(maxWidth: .infinity)
                Spacer()
            }
        }
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private func tabCard(tab: SwitcherTab, tabIdx: Int, wsID: UUID) -> some View {
        let isTabFocused = (panel == .tabs || panel == .panes) && tabIdx == tabHighlighted
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: tab.isSelected ? "terminal.fill" : "terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(isTabFocused ? accent : tab.isSelected ? accent.opacity(0.6) : Color.white.opacity(0.35))
                Text(tab.title)
                    .font(.system(size: 12, weight: isTabFocused ? .semibold : .regular))
                    .foregroundStyle(isTabFocused ? Color.white : Color.white.opacity(0.65))
                    .lineLimit(1)
                Spacer()
                if let cwd = tab.cwd, !cwd.isEmpty {
                    Text(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.2))
                        .lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: 160, alignment: .trailing)
                }
            }
            if tab.panes.count > 1 {
                VStack(spacing: 3) {
                    ForEach(Array(tab.panes.enumerated()), id: \.offset) { j, pane in
                        paneChip(pane: pane, index: j, tabIdx: tabIdx, wsID: wsID, tabID: tab.id)
                    }
                }
                .padding(.leading, 4)
            }
        }
        .padding(10)
        .background(isTabFocused ? accent.opacity(0.12) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(
            isTabFocused ? accent.opacity(0.3) : Color.white.opacity(0.06)
        ))
        .contentShape(Rectangle())
        .onTapGesture {
            tabHighlighted = tabIdx; panel = .tabs
            onSelectTab(wsID, tab.id)
        }
    }

    private func paneChip(pane: SwitcherPane, index: Int, tabIdx: Int, wsID: UUID, tabID: UUID) -> some View {
        let isPaneFocused = panel == .panes && tabIdx == tabHighlighted && index == paneHighlighted
        let label = pane.name.flatMap { $0.isEmpty ? nil : $0 }
            ?? pane.cwd.map { $0.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
            ?? "pane \(index + 1)"
        return HStack {
            Text(label)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(isPaneFocused ? Color.white : Color.white.opacity(0.4))
                .lineLimit(1).truncationMode(.head)
            Spacer()
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(isPaneFocused ? accent.opacity(0.15) : Color.white.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).stroke(
            isPaneFocused ? accent.opacity(0.3) : Color.white.opacity(0.08)
        ))
        .contentShape(Rectangle())
        .onTapGesture { onSelectPane(wsID, tabID, pane.id) }
    }

    // MARK: - Workspace row

    private func wsRow(i: Int, ws: SwitcherWorkspace) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(i < 9 ? "\(i + 1)" : "·")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(i == highlighted ? accent : accent.opacity(0.4))
                .frame(width: 16, alignment: .trailing)
            VStack(alignment: .leading, spacing: 2) {
                Text(ws.name)
                    .font(.system(size: 13, weight: i == highlighted ? .semibold : .regular))
                    .foregroundStyle(i == highlighted ? Color.white : Color.white.opacity(0.7))
                    .lineLimit(1)
                Text("\(ws.tabs.count) tab\(ws.tabs.count == 1 ? "" : "s")")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.white.opacity(0.25))
            }
            Spacer()
            HStack(spacing: 5) {
                if ws.isPinned {
                    Image(systemName: "pin.fill").font(.system(size: 8))
                        .foregroundStyle(accent.opacity(0.6))
                }
                if ws.isSelected { Circle().fill(accent).frame(width: 5, height: 5) }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(i == highlighted ? accent.opacity(0.15) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .contentShape(Rectangle())
        .onHover { if $0 { highlighted = i; panel = .workspaces; tabHighlighted = 0; paneHighlighted = 0 } }
        .onTapGesture { onSelectWorkspace(ws.id) }
    }

    // MARK: - Grouping

    private func groupedWorkspaces() -> [(String?, [(Int, SwitcherWorkspace)])] {
        var result: [(String?, [(Int, SwitcherWorkspace)])] = []
        var indexMap: [String: Int] = [:]
        var noFolderIdx: Int? = nil
        for (i, ws) in workspaces.enumerated() {
            if let folder = ws.folder {
                if let ri = indexMap[folder] {
                    result[ri].1.append((i, ws))
                } else {
                    indexMap[folder] = result.count
                    result.append((folder, [(i, ws)]))
                }
            } else {
                if let ri = noFolderIdx {
                    result[ri].1.append((i, ws))
                } else {
                    noFolderIdx = result.count
                    result.append((nil, [(i, ws)]))
                }
            }
        }
        return result
    }
}

private struct WorkspaceSwitcherKeyCapture: NSViewRepresentable {
    var count: Int
    var onUp: () -> Void
    var onDown: () -> Void
    var onLeft: () -> Void
    var onRight: () -> Void
    var onEnter: () -> Void
    var onNumber: (Int) -> Void
    var onDismiss: () -> Void

    func makeNSView(context: Context) -> CaptureView { CaptureView(rep: self) }
    func updateNSView(_ v: CaptureView, context: Context) { v.rep = self }

    final class CaptureView: NSView {
        var rep: WorkspaceSwitcherKeyCapture
        init(rep: WorkspaceSwitcherKeyCapture) { self.rep = rep; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError() }
        override var acceptsFirstResponder: Bool { true }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            DispatchQueue.main.async { window.makeFirstResponder(self) }
        }
        override func keyDown(with event: NSEvent) {
            switch event.keyCode {
            case 123: rep.onLeft()
            case 124: rep.onRight()
            case 125: rep.onDown()
            case 126: rep.onUp()
            case 36, 76: rep.onEnter()
            case 53: rep.onDismiss()
            default:
                let chars = event.charactersIgnoringModifiers ?? ""
                if let n = Int(chars), (1...9).contains(n) { rep.onNumber(n) }
                else if chars == "j" { rep.onDown() }
                else if chars == "k" { rep.onUp() }
                else if chars == "h" { rep.onLeft() }
                else if chars == "l" { rep.onRight() }
            }
        }
    }
}

// MARK: - PrefixKeyRecorder

struct PrefixKeyRecorder: NSViewRepresentable {
    @Binding var value: String

    func makeNSView(context: Context) -> KeyRecorderView {
        let v = KeyRecorderView()
        v.onCapture = { [context] combo in
            context.coordinator.parent.value = combo
        }
        v.update(display: KeyCombo(value)?.display ?? value, recording: false)
        return v
    }

    func updateNSView(_ v: KeyRecorderView, context: Context) {
        if !v.isRecording {
            v.update(display: KeyCombo(value)?.display ?? value, recording: false)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }
    class Coordinator { var parent: PrefixKeyRecorder; init(parent: PrefixKeyRecorder) { self.parent = parent } }

    // MARK: NSView
    class KeyRecorderView: NSView {
        var onCapture: ((String) -> Void)?
        var isRecording = false
        private var lastDisplay = ""
        private let label = NSTextField(labelWithString: "")

        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.borderWidth = 1
            addSubview(label)
            label.translatesAutoresizingMaskIntoConstraints = false
            label.alignment = .center
            label.font = .monospacedSystemFont(ofSize: 13, weight: .semibold)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
                label.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 4),
                label.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -4),
            ])
            addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(clicked)))
        }

        required init?(coder: NSCoder) { fatalError() }

        func update(display: String, recording: Bool) {
            isRecording = recording
            if !recording { lastDisplay = display }
            if recording {
                label.stringValue = "Type shortcut…"
                label.textColor = .white.withAlphaComponent(0.4)
                layer?.borderColor = NSColor(red: 1.0, green: 0.45, blue: 0.15, alpha: 1).cgColor
            } else {
                label.stringValue = display.isEmpty ? "–" : display
                label.textColor = NSColor(red: 0.92, green: 0.92, blue: 0.93, alpha: 1)
                layer?.borderColor = NSColor.white.withAlphaComponent(0.07).cgColor
            }
            layer?.backgroundColor = NSColor(red: 0.10, green: 0.10, blue: 0.11, alpha: 1).cgColor
        }

        override var acceptsFirstResponder: Bool { true }

        override func becomeFirstResponder() -> Bool {
            guard super.becomeFirstResponder() else { return false }
            update(display: "", recording: true)
            return true
        }

        override func resignFirstResponder() -> Bool {
            guard super.resignFirstResponder() else { return false }
            if isRecording { update(display: lastDisplay, recording: false) }
            return true
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }
            if event.keyCode == 53 { window?.makeFirstResponder(nil); return } // Escape
            let relevant: NSEvent.ModifierFlags = [.control, .command, .option, .shift]
            let mods = event.modifierFlags.intersection(relevant)
            guard !mods.isEmpty else { return }
            guard let k = event.charactersIgnoringModifiers?.lowercased(), !k.isEmpty else { return }
            var parts: [String] = []
            if mods.contains(.control) { parts.append("ctrl") }
            if mods.contains(.option)  { parts.append("opt") }
            if mods.contains(.shift)   { parts.append("shift") }
            if mods.contains(.command) { parts.append("cmd") }
            parts.append(k)
            onCapture?(parts.joined(separator: "+"))
            window?.makeFirstResponder(nil)
        }

        @objc private func clicked() { window?.makeFirstResponder(self) }
    }
}
