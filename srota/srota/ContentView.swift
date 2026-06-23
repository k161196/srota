import Combine
import SwiftUI
import AppKit
import GhosttyTerminal
import UniformTypeIdentifiers

// MARK: - Helpers

/// Ghostty may hand back a "file://host/path" URI from OSC 7; extract the path.
private func resolveCWD(_ raw: String?) -> String? {
    guard let raw else { return nil }
    if raw.hasPrefix("file://") { return URL(string: raw)?.path }
    return raw
}

private func makeLauncherConfig() -> TerminalConfiguration {
    let launcher = NSHomeDirectory() + "/.srota/zsh-launcher.sh"
    return TerminalConfiguration(configure: { b in b.withCustom("command", launcher) })
}

/// Smart tab/pane title from CWD:
///   - git repo  → "reponame/branch"
///   - otherwise → "…/parent/dir"
private func smartTitle(for path: String?) -> String {
    guard let path, !path.isEmpty else { return "Terminal" }
    var url = URL(fileURLWithPath: path)
    while url.path != "/" {
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
            let name = gitRepoName(at: url) ?? url.lastPathComponent
            if let branch = gitBranch(at: url) { return "\(name)/\(branch)" }
            return name
        }
        let parent = url.deletingLastPathComponent()
        if parent == url { break }
        url = parent
    }
    let comps = URL(fileURLWithPath: path).pathComponents.filter { $0 != "/" && !$0.isEmpty }
    switch comps.count {
    case 0: return "Terminal"
    case 1: return comps[0]
    case 2: return "\(comps[0])/\(comps[1])"
    default: return "…/\(comps[comps.count-2])/\(comps[comps.count-1])"
    }
}

private func gitBranch(at url: URL) -> String? {
    guard let head = try? String(contentsOf: url.appendingPathComponent(".git/HEAD"), encoding: .utf8) else { return nil }
    let t = head.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.hasPrefix("ref: refs/heads/") { return String(t.dropFirst(16)) }
    return t.count >= 7 ? String(t.prefix(7)) : nil
}

private func gitRepoName(at url: URL) -> String? {
    guard let cfg = try? String(contentsOf: url.appendingPathComponent(".git/config"), encoding: .utf8) else { return nil }
    for line in cfg.components(separatedBy: "\n") {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("url = ") else { continue }
        let remote = String(t.dropFirst(6))
        // last path component handles both https://…/repo.git and git@host:user/repo.git
        let raw = remote.components(separatedBy: "/").last ?? remote
        return raw.hasSuffix(".git") ? String(raw.dropLast(4)) : raw
    }
    return nil
}

/// Transparent overlay that intercepts double-clicks natively via NSView.
/// Single-clicks pass through to SwiftUI gestures underneath.
private struct DoubleClickOverlay: NSViewRepresentable {
    var action: () -> Void
    func makeNSView(context: Context) -> DCView { DCView() }
    func updateNSView(_ v: DCView, context: Context) { v.action = action }

    class DCView: NSView {
        var action: (() -> Void)?
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { action?() } else { super.mouseDown(with: event) }
        }
    }
}

// MARK: - Model

enum PaneRef: Equatable {
    case primary
    case secondary(UUID)
}

enum DropSide { case left, right, top, bottom }

struct PaneLayout {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var w: CGFloat = 1
    var h: CGFloat = 1
}

final class PaneEntry: Identifiable {
    let id = UUID()
    let viewState: TerminalViewState
    var initialCWD: String?
    init(viewState: TerminalViewState, initialCWD: String? = nil) {
        self.viewState  = viewState
        self.initialCWD = initialCWD
    }
}

// Each pane owns a fractional rect (0–1) of the content area.
// Splitting right/bottom halves the focused pane and places the new one adjacent.
@MainActor
final class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var customName: String = "" {
        didSet { if customName.isEmpty { titleFromCWD = smartTitle(for: resolveCWD(focusedViewState.workingDirectory)) } }
    }
    let viewState: TerminalViewState
    @Published var secondaryPanes: [PaneEntry] = []
    @Published var layouts:      [UUID: PaneLayout] = [:]
    @Published var primaryPaneName: String = ""
    @Published var paneNames:    [UUID: String]     = [:]
    @Published var primaryLayout = PaneLayout()
    @Published var focusedPaneID: UUID? = nil {
        didSet {
            if customName.isEmpty {
                titleFromCWD = smartTitle(for: resolveCWD(focusedViewState.workingDirectory))
            }
            bindTitleSink()
        }
    }
    @Published var primaryExited = false
    @Published private(set) var titleFromCWD: String = "Terminal"
    private var titleSink: AnyCancellable?
    var closeTabCallback: (() -> Void)?
    let initialWorkingDirectory: String?
    private var paneCount = 0

    init(colorScheme: ColorScheme, workingDirectory: String? = nil) {
        self.initialWorkingDirectory = workingDirectory
        let state = TerminalViewState(terminalConfiguration: makeLauncherConfig())
        state.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: workingDirectory)
        state.controller.setColorScheme(colorScheme == .dark ? .dark : .light)
        viewState = state
        bindTitleSink()
    }

    private func bindTitleSink() {
        titleSink = focusedViewState.$workingDirectory
            .receive(on: RunLoop.main)
            .sink { [weak self] cwd in
                guard let self, self.customName.isEmpty else { return }
                self.titleFromCWD = smartTitle(for: resolveCWD(cwd))
            }
    }

    var displayName: String {
        if !customName.isEmpty { return customName }
        if let fid = focusedPaneID {
            if let name = paneNames[fid], !name.isEmpty { return name }
        } else if !primaryPaneName.isEmpty {
            return primaryPaneName
        }
        return titleFromCWD
    }

    var focusedViewState: TerminalViewState {
        if let fid = focusedPaneID,
           let entry = secondaryPanes.first(where: { $0.id == fid }) {
            return entry.viewState
        }
        return viewState
    }

    private func splitCWD() -> String? {
        resolveCWD(focusedViewState.workingDirectory) ?? initialWorkingDirectory
    }

    func splitRight(colorScheme: ColorScheme) {
        guard let fl = focusedLayout else { return }
        let half = fl.w / 2
        setFocusedLayout(PaneLayout(x: fl.x, y: fl.y, w: half, h: fl.h))
        addPane(colorScheme: colorScheme,
                layout: PaneLayout(x: fl.x + half, y: fl.y, w: half, h: fl.h),
                workingDirectory: splitCWD())
    }

    func splitBottom(colorScheme: ColorScheme) {
        guard let fl = focusedLayout else { return }
        let half = fl.h / 2
        setFocusedLayout(PaneLayout(x: fl.x, y: fl.y, w: fl.w, h: half))
        addPane(colorScheme: colorScheme,
                layout: PaneLayout(x: fl.x, y: fl.y + half, w: fl.w, h: half),
                workingDirectory: splitCWD())
    }

    func rename(ref: PaneRef, to name: String) {
        switch ref {
        case .primary:           primaryPaneName = name
        case .secondary(let id): paneNames[id] = name
        }
    }

    func removePane(id: UUID) {
        expandNeighbor(of: .secondary(id))
        secondaryPanes.removeAll { $0.id == id }
        layouts.removeValue(forKey: id)
        if focusedPaneID == id { focusedPaneID = nil }
        if secondaryPanes.isEmpty {
            if primaryExited { closeTabCallback?() }
            else { primaryLayout = PaneLayout() }
        }
    }

    func collapsePrimary() {
        expandNeighbor(of: .primary)
        primaryLayout = PaneLayout(x: 0, y: 0, w: 0, h: 0)
        primaryExited = true
    }

    func closePrimaryPane() {
        if secondaryPanes.isEmpty { closeTabCallback?() }
        else { collapsePrimary() }
    }

    func swapLayouts(_ a: PaneRef, _ b: PaneRef) {
        guard a != b else { return }
        let la = layout(for: a), lb = layout(for: b)
        setLayout(lb, for: a)
        setLayout(la, for: b)
    }

    func performDrop(source: PaneRef, target: PaneRef, side: DropSide) {
        guard source != target else { return }
        // Expand first — target may absorb source's old space, giving a larger split area
        expandNeighbor(of: source)
        let tl = layout(for: target)   // re-read AFTER expansion
        var newTarget: PaneLayout
        var newSource: PaneLayout
        switch side {
        case .left:
            let half = tl.w / 2
            newSource = PaneLayout(x: tl.x, y: tl.y, w: half, h: tl.h)
            newTarget = PaneLayout(x: tl.x + half, y: tl.y, w: half, h: tl.h)
        case .right:
            let half = tl.w / 2
            newTarget = PaneLayout(x: tl.x, y: tl.y, w: half, h: tl.h)
            newSource = PaneLayout(x: tl.x + half, y: tl.y, w: half, h: tl.h)
        case .top:
            let half = tl.h / 2
            newSource = PaneLayout(x: tl.x, y: tl.y, w: tl.w, h: half)
            newTarget = PaneLayout(x: tl.x, y: tl.y + half, w: tl.w, h: half)
        case .bottom:
            let half = tl.h / 2
            newTarget = PaneLayout(x: tl.x, y: tl.y, w: tl.w, h: half)
            newSource = PaneLayout(x: tl.x, y: tl.y + half, w: tl.w, h: half)
        }
        setLayout(newTarget, for: target)
        setLayout(newSource, for: source)
    }

    // MARK: - Private

    private func layout(for ref: PaneRef) -> PaneLayout {
        switch ref {
        case .primary:           return primaryLayout
        case .secondary(let id): return layouts[id] ?? PaneLayout()
        }
    }

    private func setLayout(_ l: PaneLayout, for ref: PaneRef) {
        switch ref {
        case .primary:           primaryLayout = l
        case .secondary(let id): layouts[id]   = l
        }
    }

    private var focusedLayout: PaneLayout? {
        if let fid = focusedPaneID { return layouts[fid] }
        return primaryLayout
    }

    private func setFocusedLayout(_ l: PaneLayout) {
        if let fid = focusedPaneID { layouts[fid] = l }
        else { primaryLayout = l }
    }

    /// Restore a saved secondary pane at its last known CWD.
    func restorePane(record: PaneRecord, colorScheme: ColorScheme) {
        let cwd = record.initialCWD.isEmpty ? nil : record.initialCWD
        let state = TerminalViewState(terminalConfiguration: makeLauncherConfig())
        state.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: cwd)
        state.controller.setColorScheme(colorScheme == .dark ? .dark : .light)
        let entry = PaneEntry(viewState: state, initialCWD: cwd)
        state.onClose = { [weak self, weak entry] _ in
            guard let self, let entry else { return }
            self.removePane(id: entry.id)
        }
        let layout = PaneLayout(x: CGFloat(record.lx), y: CGFloat(record.ly),
                                w: CGFloat(record.lw), h: CGFloat(record.lh))
        layouts[entry.id] = layout
        secondaryPanes.append(entry)
        focusedPaneID = entry.id
    }

    private func addPane(colorScheme: ColorScheme, layout: PaneLayout, workingDirectory: String? = nil) {
        let state = TerminalViewState(terminalConfiguration: makeLauncherConfig())
        state.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: workingDirectory)
        state.controller.setColorScheme(colorScheme == .dark ? .dark : .light)
        let entry = PaneEntry(viewState: state, initialCWD: workingDirectory)
        state.onClose = { [weak self, weak entry] _ in
            guard let self, let entry else { return }
            self.removePane(id: entry.id)
        }
        layouts[entry.id] = layout
        secondaryPanes.append(entry)
        focusedPaneID = entry.id
    }

    // Expand a neighbor into ref's vacated space. Checks all 4 directions.
    private func expandNeighbor(of ref: PaneRef) {
        let rl = layout(for: ref)
        let eps: CGFloat = 0.001

        var others: [(PaneRef, PaneLayout)] = []
        if ref != .primary { others.append((.primary, primaryLayout)) }
        for e in secondaryPanes {
            if case .secondary(let eid) = ref, eid == e.id { continue }
            guard let l = layouts[e.id] else { continue }
            others.append((.secondary(e.id), l))
        }

        for (otherRef, var nl) in others {
            // left neighbor
            if abs(nl.x + nl.w - rl.x) < eps && abs(nl.y - rl.y) < eps && abs(nl.h - rl.h) < eps {
                nl.w += rl.w; setLayout(nl, for: otherRef); return
            }
            // top neighbor
            if abs(nl.y + nl.h - rl.y) < eps && abs(nl.x - rl.x) < eps && abs(nl.w - rl.w) < eps {
                nl.h += rl.h; setLayout(nl, for: otherRef); return
            }
            // right neighbor
            if abs(nl.x - (rl.x + rl.w)) < eps && abs(nl.y - rl.y) < eps && abs(nl.h - rl.h) < eps {
                nl.x = rl.x; nl.w += rl.w; setLayout(nl, for: otherRef); return
            }
            // bottom neighbor
            if abs(nl.y - (rl.y + rl.h)) < eps && abs(nl.x - rl.x) < eps && abs(nl.w - rl.w) < eps {
                nl.y = rl.y; nl.h += rl.h; setLayout(nl, for: otherRef); return
            }
        }
    }
}

@MainActor
final class Workspace: Identifiable, ObservableObject {
    let id: UUID
    @Published var name: String
    @Published var tabs: [TerminalTab] = []
    @Published var selectedTabID: UUID?
    private var lastColorScheme: ColorScheme = .dark

    init(id: UUID = UUID(), name: String) {
        self.id   = id
        self.name = name
    }

    var selectedTab: TerminalTab? { tabs.first { $0.id == selectedTabID } }

    var currentWorkingDirectory: String? {
        resolveCWD(selectedTab?.focusedViewState.workingDirectory)
    }

    func addTab(colorScheme: ColorScheme, workingDirectory: String? = nil) {
        lastColorScheme = colorScheme
        let tab = TerminalTab(colorScheme: colorScheme, workingDirectory: workingDirectory)
        tab.closeTabCallback = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.closeTab(id: tab.id)
        }
        tab.viewState.onClose = { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            if tab.secondaryPanes.isEmpty {
                self.closeTab(id: tab.id)
            } else {
                tab.collapsePrimary()
            }
        }
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func addRestoredTab(record: TabRecord, colorScheme: ColorScheme) {
        lastColorScheme = colorScheme
        let cwd = record.initialCWD.isEmpty ? nil : record.initialCWD
        let tab = TerminalTab(colorScheme: colorScheme, workingDirectory: cwd)
        tab.closeTabCallback = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.closeTab(id: tab.id)
        }
        tab.viewState.onClose = { [weak self, weak tab] _ in
            guard let self, let tab else { return }
            if tab.secondaryPanes.isEmpty { self.closeTab(id: tab.id) }
            else { tab.collapsePrimary() }
        }
        tabs.append(tab)
        if record.isSelected { selectedTabID = tab.id }
    }

    func closeTab(id: UUID) {
        if selectedTabID == id {
            if let idx = tabs.firstIndex(where: { $0.id == id }) {
                let next = tabs.indices.contains(idx + 1) ? tabs[idx + 1].id
                         : idx > 0 ? tabs[idx - 1].id : nil
                selectedTabID = next
            }
        }
        tabs.removeAll { $0.id == id }
    }
}

@MainActor
final class WorkspaceFolder: Identifiable, ObservableObject {
    let id = UUID()
    @Published var name: String
    @Published var tag: String = ""
    @Published var workspaces: [Workspace] = []
    @Published var isExpanded: Bool = true
    init(name: String, tag: String = "") { self.name = name; self.tag = tag }
}

@MainActor
final class TerminalManager: ObservableObject {
    @Published var workspaces: [Workspace] = []   // unfiled
    @Published var folders: [WorkspaceFolder] = [] {
        didSet { rebindFolderSinks() }
    }
    @Published var selectedWorkspaceID: UUID?

    private var folderSinks: [AnyCancellable] = []

    private func rebindFolderSinks() {
        folderSinks = folders.map { folder in
            folder.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    var allWorkspaces: [Workspace] { workspaces + folders.flatMap(\.workspaces) }

    var selectedWorkspace: Workspace? {
        allWorkspaces.first { $0.id == selectedWorkspaceID }
    }

    func folderID(containingWorkspace wsID: UUID) -> UUID? {
        folders.first { $0.workspaces.contains { $0.id == wsID } }?.id
    }

    func addWorkspace(colorScheme: ColorScheme, inFolder folderID: UUID? = nil, workingDirectory: String? = nil, name: String? = nil) {
        let wsName = name ?? "Workspace \(allWorkspaces.count + 1)"
        let ws = Workspace(name: wsName)
        ws.addTab(colorScheme: colorScheme, workingDirectory: workingDirectory)
        if let folderID, let folder = folders.first(where: { $0.id == folderID }) {
            folder.workspaces.append(ws)
        } else {
            workspaces.append(ws)
        }
        selectedWorkspaceID = ws.id
    }

    /// Find existing folder by name or create one with optional tag.
    func folder(named name: String, tag: String = "") -> WorkspaceFolder {
        if let existing = folders.first(where: { $0.name == name }) {
            if !tag.isEmpty { existing.tag = tag }
            return existing
        }
        let f = WorkspaceFolder(name: name, tag: tag)
        folders.append(f)
        return f
    }

    func closeWorkspace(id: UUID) {
        if selectedWorkspaceID == id {
            let all = allWorkspaces
            if let idx = all.firstIndex(where: { $0.id == id }) {
                selectedWorkspaceID = all.indices.contains(idx + 1) ? all[idx + 1].id
                                    : idx > 0 ? all[idx - 1].id : nil
            }
        }
        let beforeCount = workspaces.count
        workspaces.removeAll { $0.id == id }
        if workspaces.count < beforeCount { return }
        for folder in folders { folder.workspaces.removeAll { $0.id == id } }
    }

    func addFolder(name: String) -> WorkspaceFolder {
        let f = WorkspaceFolder(name: name)
        folders.append(f)
        return f
    }

    func deleteFolder(id: UUID) {
        guard folders.first(where: { $0.id == id })?.workspaces.isEmpty == true else { return }
        folders.removeAll { $0.id == id }
    }

    func moveWorkspace(id wsID: UUID, toFolder folderID: UUID?) {
        var ws: Workspace?
        if let idx = workspaces.firstIndex(where: { $0.id == wsID }) {
            ws = workspaces.remove(at: idx)
        } else {
            for folder in folders {
                if let idx = folder.workspaces.firstIndex(where: { $0.id == wsID }) {
                    ws = folder.workspaces.remove(at: idx); break
                }
            }
        }
        guard let ws else { return }
        if let folderID, let folder = folders.first(where: { $0.id == folderID }) {
            folder.workspaces.append(ws)
        } else {
            workspaces.append(ws)
        }
    }
}

// MARK: - Design tokens

private extension Color {
    static let tabBarBg     = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let tabActiveBg  = Color(red: 0.17, green: 0.17, blue: 0.19)
    static let tabHoverBg   = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let accentOrange = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let labelPrimary = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let labelMuted   = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.40)
}

// MARK: - Sidebar divider

private struct SidebarDivider: View {
    let sidebarVisible: Bool
    @Binding var width: CGFloat
    @State private var isHovered = false

    var body: some View {
        Rectangle()
            .fill(isHovered ? Color.accentOrange.opacity(0.6) : Color.white.opacity(0.06))
            .frame(width: isHovered ? 3 : 1)
            .opacity(sidebarVisible ? 1 : 0)
            .onHover { isHovered = $0 }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { v in
                        width = max(150, min(500, width + v.translation.width))
                    }
            )
            .animation(.easeOut(duration: 0.12), value: isHovered)
            .help("Drag to resize sidebar")
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var manager = TerminalManager()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings
    @Environment(WorkspaceDB.self) private var db
    @State private var sidebarVisible = true
    @State private var sidebarWidth: CGFloat = 220
    @State private var showBaseDirectoryPicker = false
    @State private var managementTab: ManagementTab = .workspaces

    var body: some View {
        VStack(spacing: 0) {
        TopNavBar(selected: $managementTab)
        ZStack {
        HStack(spacing: 0) {
            SidebarView(
                manager: manager,
                onAdd: {
                    let fid = manager.selectedWorkspaceID.flatMap { manager.folderID(containingWorkspace: $0) }
                    manager.addWorkspace(colorScheme: colorScheme, inFolder: fid)
                    saveLayout()
                }
            )
            .frame(width: sidebarVisible ? sidebarWidth : 0)
            .clipped()
            .allowsHitTesting(sidebarVisible)

            SidebarDivider(sidebarVisible: sidebarVisible, width: $sidebarWidth)

            VStack(spacing: 0) {
                if let ws = manager.selectedWorkspace {
                    TabBarView(workspace: ws, colorScheme: colorScheme, sidebarVisible: $sidebarVisible,
                               onMutation: { saveLayout() })
                } else {
                    HStack {
                        Button(action: { sidebarVisible.toggle() }) {
                            Image(systemName: "sidebar.left")
                                .font(.system(size: 13))
                                .foregroundStyle(Color.labelMuted)
                                .frame(width: 32, height: 32)
                        }
                        .buttonStyle(.plain)
                        .padding(.leading, 6)
                        Spacer()
                    }
                    .frame(height: 38)
                    .background(Color.tabBarBg)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
                    }
                }

                ZStack {
                    Color.black.ignoresSafeArea()
                    if manager.allWorkspaces.isEmpty {
                        Text("No workspace open")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    ForEach(manager.allWorkspaces) { ws in
                        WorkspaceContent(workspace: ws,
                                         selectedWorkspaceID: manager.selectedWorkspaceID)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.spring(duration: 0.22, bounce: 0.0), value: sidebarVisible)
        .onAppear {
            restoreSessionsFromDB(colorScheme: colorScheme)
            if settings.baseWorkingDirectory == nil { showBaseDirectoryPicker = true }
            NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
                                                   object: nil, queue: .main) { _ in saveLayout() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .srotaOpenWorkspace)) { note in
            guard let path     = note.userInfo?["path"]       as? String else { return }
            let wsName         = note.userInfo?["name"]        as? String
            let folderName     = note.userInfo?["folderName"]  as? String
            let needsWorktree  = note.userInfo?["createWorktree"] as? Bool ?? false
            let projectPath    = note.userInfo?["projectPath"] as? String ?? ""
            let branchRef      = note.userInfo?["branchRef"]   as? String ?? (wsName ?? "")

            let folderTag  = note.userInfo?["folderTag"] as? String ?? ""
            let folder = folderName.map { manager.folder(named: $0, tag: folderTag) }
            let folderID = folder?.id

            // if workspace with same name already exists in that folder, just select it
            let candidatePool = folder?.workspaces ?? manager.workspaces
            if let existing = candidatePool.first(where: { $0.name == wsName }) {
                manager.selectedWorkspaceID = existing.id
                managementTab = .workspaces
                return
            }

            if needsWorktree {
                Task.detached {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    p.arguments = ["-C", projectPath, "worktree", "add", path, branchRef]
                    p.standardError = Pipe()
                    try? p.run(); p.waitUntilExit()
                    await MainActor.run { [folderID] in
                        manager.addWorkspace(colorScheme: colorScheme, inFolder: folderID,
                                             workingDirectory: path, name: wsName)
                        db.saveWorkspaceSession(WorkspaceSession(
                            id: manager.allWorkspaces.last?.id.uuidString ?? UUID().uuidString,
                            name: wsName ?? "", folderName: folderName ?? "",
                            folderTag: folderTag, position: 0,
                            lastCWD: path,
                            lastAccessed: Int(Date().timeIntervalSince1970)))
                        managementTab = .workspaces
                        saveLayout()
                        if let baseDir = settings.baseWorkingDirectory { db.scan(baseDir: baseDir) }
                    }
                }
            } else {
                manager.addWorkspace(colorScheme: colorScheme, inFolder: folderID,
                                     workingDirectory: path, name: wsName)
                if let ws = manager.allWorkspaces.last {
                    db.saveWorkspaceSession(WorkspaceSession(
                        id: ws.id.uuidString, name: ws.name,
                        folderName: folderName ?? "", folderTag: folderTag,
                        position: candidatePool.count,
                        lastCWD: path, lastAccessed: Int(Date().timeIntervalSince1970)))
                }
                managementTab = .workspaces
                saveLayout()
            }
        }
        .sheet(isPresented: $showBaseDirectoryPicker) {
            BaseDirectorySheet { url in
                settings.baseWorkingDirectory = url.path
                settings.save()
                db.scan(baseDir: url.path)
                showBaseDirectoryPicker = false
            }
        }
        if managementTab != .workspaces {
            ManagementPanel(tab: managementTab)
                .environment(db)
                .environmentObject(manager)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.067, green: 0.067, blue: 0.075))
        }
        } // end ZStack
        } // end VStack
    }

    private func saveLayout() {
        let allFolders  = manager.folders
        let unfiledWSes = manager.workspaces
        func save(ws: Workspace, folderName: String, folderTag: String, position: Int) {
            db.saveWorkspaceSession(WorkspaceSession(
                id: ws.id.uuidString, name: ws.name,
                folderName: folderName, folderTag: folderTag, position: position,
                lastCWD: ws.currentWorkingDirectory ?? "",
                lastAccessed: Int(Date().timeIntervalSince1970)))
            db.deleteTabs(workspaceID: ws.id.uuidString)
            for (ti, tab) in ws.tabs.enumerated() {
                db.saveTab(TabRecord(
                    id: tab.id.uuidString, workspaceID: ws.id.uuidString,
                    position: ti,
                    initialCWD: tab.initialWorkingDirectory ?? "",
                    isSelected: tab.id == ws.selectedTabID))
                db.savePane(PaneRecord(
                    id: "\(tab.id)_primary", tabID: tab.id.uuidString, isPrimary: true,
                    lx: Double(tab.primaryLayout.x), ly: Double(tab.primaryLayout.y),
                    lw: Double(tab.primaryLayout.w), lh: Double(tab.primaryLayout.h),
                    initialCWD: tab.initialWorkingDirectory ?? ""))
                for pane in tab.secondaryPanes {
                    if let layout = tab.layouts[pane.id] {
                        db.savePane(PaneRecord(
                            id: pane.id.uuidString, tabID: tab.id.uuidString, isPrimary: false,
                            lx: Double(layout.x), ly: Double(layout.y),
                            lw: Double(layout.w), lh: Double(layout.h),
                            initialCWD: pane.initialCWD ?? ""))
                    }
                }
            }
        }
        for (i, ws) in unfiledWSes.enumerated() { save(ws: ws, folderName: "", folderTag: "", position: i) }
        for folder in allFolders {
            for (i, ws) in folder.workspaces.enumerated() {
                save(ws: ws, folderName: folder.name, folderTag: folder.tag, position: i)
            }
        }
    }

    private func restoreSessionsFromDB(colorScheme: ColorScheme) {
        let saved = db.loadWorkspaceSessions()
        guard !saved.isEmpty else {
            manager.addWorkspace(colorScheme: colorScheme)
            return
        }
        for session in saved {
            let folder = session.folderName.isEmpty
                ? nil
                : manager.folder(named: session.folderName, tag: session.folderTag)
            let wsID = UUID(uuidString: session.id) ?? UUID()
            let ws = Workspace(id: wsID, name: session.name)
            let cwd = session.lastCWD.isEmpty ? nil : session.lastCWD
            let tabs = db.loadTabs(workspaceID: session.id)
            if tabs.isEmpty {
                ws.addTab(colorScheme: colorScheme, workingDirectory: cwd)
            } else {
                for tabRecord in tabs.sorted(by: { $0.position < $1.position }) {
                    ws.addRestoredTab(record: tabRecord, colorScheme: colorScheme)
                    if let tab = ws.tabs.last {
                        let panes = db.loadPanes(tabID: tabRecord.id)
                        for pane in panes where !pane.isPrimary {
                            tab.restorePane(record: pane, colorScheme: colorScheme)
                        }
                        if let primary = panes.first(where: { $0.isPrimary }) {
                            tab.primaryLayout = PaneLayout(
                                x: CGFloat(primary.lx), y: CGFloat(primary.ly),
                                w: CGFloat(primary.lw), h: CGFloat(primary.lh))
                        }
                    }
                }
                if ws.selectedTabID == nil { ws.selectedTabID = ws.tabs.first?.id }
            }
            if let folder {
                folder.workspaces.append(ws)
            } else {
                manager.workspaces.append(ws)
            }
        }
        if manager.selectedWorkspaceID == nil {
            manager.selectedWorkspaceID = manager.allWorkspaces.first?.id
        }
    }
}

// MARK: - Sidebar

private extension Color {
    static let sidebarBg      = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let rowSelected    = Color(red: 1, green: 1, blue: 1).opacity(0.06)
    static let rowHover       = Color(red: 1, green: 1, blue: 1).opacity(0.035)
    static let accentRail     = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let dotRunning     = Color(red: 0.24, green: 0.84, blue: 0.55)
    static let labelSecondary = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.45)
    static let sectionHeader  = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.28)
}

private struct SidebarView: View {
    @ObservedObject var manager: TerminalManager
    let onAdd: () -> Void
    @State private var newFolderID: UUID? = nil
    @State private var isDragTargetUnfiled = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: onAdd) {
                    HStack(spacing: 7) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .semibold))
                        Text("New Workspace")
                            .font(.system(size: 13, weight: .regular))
                    }
                    .foregroundStyle(Color.labelSecondary)
                    .padding(.leading, 16)
                    .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                Spacer()
                Button {
                    let f = manager.addFolder(name: "New Folder")
                    newFolderID = f.id
                } label: {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 12))
                        .foregroundStyle(Color.labelSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.plain)
                .help("New Folder")
            }

            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text("WORKSPACES")
                    .font(.system(size: 11, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(isDragTargetUnfiled ? Color.accentOrange : Color.sectionHeader)
                Spacer()
                Text("\(manager.allWorkspaces.count)")
                    .font(.system(size: 11, weight: .regular).monospacedDigit())
                    .foregroundStyle(Color.sectionHeader.opacity(0.7))
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 5)
            .background(isDragTargetUnfiled ? Color.accentOrange.opacity(0.08) : Color.clear)
            .onDrop(of: [UTType.plainText], isTargeted: $isDragTargetUnfiled) { providers in
                dropWorkspace(providers, toFolder: nil, manager: manager)
            }

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(manager.workspaces) { ws in
                        WorkspaceRow(
                            workspace: ws,
                            manager: manager,
                            isSelected: manager.selectedWorkspaceID == ws.id,
                            onSelect: { manager.selectedWorkspaceID = ws.id },
                            onClose:  { manager.closeWorkspace(id: ws.id) }
                        )
                    }
                    ForEach(manager.folders) { folder in
                        FolderRow(
                            folder: folder,
                            manager: manager,
                            startRenaming: newFolderID == folder.id,
                            onRenameHandled: { newFolderID = nil }
                        )
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .background(Color.sidebarBg)
    }
}

private struct FolderRow: View {
    @ObservedObject var folder: WorkspaceFolder
    @ObservedObject var manager: TerminalManager
    let startRenaming: Bool
    let onRenameHandled: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered    = false
    @State private var isDragTarget = false
    @State private var isRenaming   = false
    @State private var editText     = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            // Folder header row
            HStack(spacing: 0) {
                Rectangle().fill(Color.clear).frame(width: 3)
                HStack(spacing: 8) {
                    Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.sectionHeader)
                        .frame(width: 10)
                    Image(systemName: isDragTarget ? "folder.fill" : "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(isDragTarget ? Color.accentOrange : Color.labelSecondary)
                    if isRenaming {
                        TextField("", text: $editText)
                            .font(.system(size: 13))
                            .foregroundStyle(Color.labelPrimary)
                            .textFieldStyle(.plain)
                            .focused($fieldFocused)
                            .onSubmit { commitRename() }
                            .onExitCommand { isRenaming = false }
                    } else {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(folder.name)
                                .font(.system(size: 13))
                                .foregroundStyle(isDragTarget ? Color.accentOrange : Color.labelSecondary)
                                .lineLimit(1)
                            if !folder.tag.isEmpty {
                                Text(folder.tag)
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Color.accentOrange.opacity(0.7))
                                    .lineLimit(1)
                            }
                        }
                    }
                    Spacer(minLength: 4)
                    if isHovered && !isRenaming {
                        Button {
                            manager.addWorkspace(colorScheme: colorScheme, inFolder: folder.id)
                            folder.isExpanded = true
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.labelSecondary)
                        }
                        .buttonStyle(.plain)
                        .help("Add workspace to folder")
                    } else {
                        Text("\(folder.workspaces.count)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Color.sectionHeader.opacity(0.7))
                    }
                }
                .padding(.leading, 10)
                .padding(.trailing, 10)
                .padding(.vertical, 7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                isDragTarget ? Color.accentOrange.opacity(0.12) :
                isHovered    ? Color.rowHover : Color.clear
            )
            .overlay(
                isDragTarget ? RoundedRectangle(cornerRadius: 4)
                    .stroke(Color.accentOrange.opacity(0.5), lineWidth: 1)
                    .padding(.horizontal, 4) : nil
            )
            .contentShape(Rectangle())
            .onTapGesture { if !isRenaming { folder.isExpanded.toggle() } }
            .onHover { isHovered = $0 }
            .onDrop(of: [UTType.plainText], isTargeted: $isDragTarget) { providers in
                dropWorkspace(providers, toFolder: folder.id, manager: manager)
            }
            .contextMenu {
                Button("Rename") { beginRename() }
                Divider()
                if folder.workspaces.isEmpty {
                    Button("Delete Folder", role: .destructive) { manager.deleteFolder(id: folder.id) }
                }
            }

            if folder.isExpanded {
                ForEach(folder.workspaces) { ws in
                    WorkspaceRow(
                        workspace: ws,
                        manager: manager,
                        isSelected: manager.selectedWorkspaceID == ws.id,
                        onSelect: { manager.selectedWorkspaceID = ws.id },
                        onClose:  { manager.closeWorkspace(id: ws.id) },
                        indented: true
                    )
                }
            }
        }
        .onAppear {
            if startRenaming { beginRename(); onRenameHandled() }
        }
    }

    private func beginRename() {
        editText = folder.name
        isRenaming = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fieldFocused = true }
    }

    private func commitRename() {
        let t = editText.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { folder.name = t }
        isRenaming = false
    }
}

private func dropWorkspace(_ providers: [NSItemProvider], toFolder folderID: UUID?, manager: TerminalManager) -> Bool {
    guard let provider = providers.first else { return false }
    provider.loadObject(ofClass: NSString.self) { obj, _ in
        guard let str = obj as? String, let wsID = UUID(uuidString: str) else { return }
        DispatchQueue.main.async { manager.moveWorkspace(id: wsID, toFolder: folderID) }
    }
    return true
}

private struct WorkspaceRow: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var manager: TerminalManager
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    var indented: Bool = false

    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var editText = ""
    @FocusState private var fieldFocused: Bool

    private func startRename() {
        editText = workspace.name
        isRenaming = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { fieldFocused = true }
    }

    private func commitRename() {
        let t = editText.trimmingCharacters(in: .whitespaces)
        if !t.isEmpty { workspace.name = t }
        isRenaming = false
    }

    private var currentFolderID: UUID? {
        manager.folders.first { $0.workspaces.contains { $0.id == workspace.id } }?.id
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(isSelected ? Color.accentRail : .clear)
                .frame(width: 3)

            HStack(spacing: 9) {
                if indented { Spacer().frame(width: 14) }
                Image(systemName: "square.stack")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.accentOrange : Color.labelSecondary)

                if isRenaming {
                    TextField("", text: $editText)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(Color.labelPrimary)
                        .textFieldStyle(.plain)
                        .focused($fieldFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { isRenaming = false }
                } else {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(workspace.name)
                            .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                            .foregroundStyle(isSelected ? Color.labelPrimary : Color.labelSecondary)
                            .lineLimit(1)
                        Text("\(workspace.tabs.count) tab\(workspace.tabs.count == 1 ? "" : "s")")
                            .font(.system(size: 10))
                            .foregroundStyle(Color.sectionHeader)
                    }
                }

                Spacer(minLength: 4)

                if isHovered && !isRenaming {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.labelSecondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 12)
            .padding(.trailing, 10)
            .padding(.vertical, 9)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isSelected ? Color.rowSelected : isHovered ? Color.rowHover : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { onSelect() } }
        .onHover { isHovered = $0 }
        .onDrag { NSItemProvider(object: workspace.id.uuidString as NSString) }
        .contextMenu {
            Button("Rename") { startRename() }

            if !manager.folders.isEmpty {
                Menu("Move to Folder") {
                    if currentFolderID != nil {
                        Button("Remove from Folder") { manager.moveWorkspace(id: workspace.id, toFolder: nil) }
                        Divider()
                    }
                    ForEach(manager.folders) { folder in
                        if folder.id != currentFolderID {
                            Button(folder.name) { manager.moveWorkspace(id: workspace.id, toFolder: folder.id) }
                        }
                    }
                }
            }

            Divider()
            Button("Close Workspace", role: .destructive) { onClose() }
        }
    }
}

// MARK: - Tab bar

private struct TabBarView: View {
    @ObservedObject var workspace: Workspace
    let colorScheme: ColorScheme
    @Binding var sidebarVisible: Bool
    var onMutation: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            Button(action: { sidebarVisible.toggle() }) {
                Image(systemName: "sidebar.left")
                    .font(.system(size: 13))
                    .foregroundStyle(sidebarVisible ? Color.labelPrimary : Color.labelMuted)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .padding(.leading, 6)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 1) {
                    ForEach(workspace.tabs) { tab in
                        TabChip(
                            tab: tab,
                            isActive: workspace.selectedTabID == tab.id,
                            onSelect: { workspace.selectedTabID = tab.id },
                            onClose:  { workspace.closeTab(id: tab.id) }
                        )
                    }

                    Button(action: { workspace.addTab(colorScheme: colorScheme, workingDirectory: workspace.currentWorkingDirectory); onMutation() }) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color.labelMuted)
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
                .padding(.horizontal, 6)
            }

            Spacer(minLength: 0)

            if let tab = workspace.selectedTab {
                HStack(spacing: 2) {
                    SplitButton(icon: "rectangle.split.2x1", tooltip: "Split Right",
                                active: !tab.secondaryPanes.isEmpty) {
                        tab.splitRight(colorScheme: colorScheme); onMutation()
                    }
                    SplitButton(icon: "rectangle.split.1x2", tooltip: "Split Bottom",
                                active: !tab.secondaryPanes.isEmpty) {
                        tab.splitBottom(colorScheme: colorScheme); onMutation()
                    }
                }
                .padding(.trailing, 12)
            }
        }
        .frame(height: 38)
        .background(Color.tabBarBg)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
        }
    }
}

private struct WorkspaceContent: View {
    @ObservedObject var workspace: Workspace
    let selectedWorkspaceID: UUID?

    var body: some View {
        ForEach(workspace.tabs) { tab in
            TerminalContentView(tab: tab)
                .opacity(workspace.id == selectedWorkspaceID && tab.id == workspace.selectedTabID ? 1 : 0)
        }
    }
}

private struct TabChip: View {
    @ObservedObject var tab: TerminalTab
    let isActive: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered   = false
    @State private var isRenaming  = false
    @State private var editText    = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "terminal")
                .font(.system(size: 10.5))
                .foregroundStyle(isActive ? Color.accentOrange : Color.labelMuted)

            if isRenaming {
                TextField("", text: $editText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(Color.labelPrimary)
                    .focused($fieldFocused)
                    .onSubmit { commit() }
                    .onExitCommand { isRenaming = false }
                    .onAppear { DispatchQueue.main.async { fieldFocused = true } }
            } else {
                Text(tab.displayName)
                    .font(.system(size: 12, weight: isActive ? .medium : .regular))
                    .foregroundStyle(isActive ? Color.labelPrimary : Color.labelMuted)
                    .lineLimit(1)
            }

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(Color.labelMuted)
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
            .opacity(isHovered || isActive ? 1 : 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isActive ? Color.tabActiveBg : (isHovered ? Color.tabHoverBg : Color.clear))
        )
        .overlay(alignment: .bottom) {
            if isActive {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentOrange)
                    .frame(height: 2)
                    .padding(.horizontal, 6)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .contextMenu {
            Button("Rename") { startRename() }
            Divider()
            Button("Close", role: .destructive) { onClose() }
        }
        .onHover { isHovered = $0 }
    }

    private func startRename() {
        onSelect()
        editText = tab.customName
        isRenaming = true
    }

    private func commit() {
        tab.customName = editText
        isRenaming = false
    }
}

private struct SplitButton: View {
    let icon: String
    let tooltip: String
    let active: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(active ? Color.accentOrange : (isHovered ? Color.labelPrimary : Color.labelMuted))
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 5)
                        .fill(active ? Color.accentOrange.opacity(0.12) :
                              isHovered ? Color.white.opacity(0.06) : Color.clear)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
        .help(tooltip)
    }
}

// MARK: - Terminal content (split-aware)
// Primary is always ZStack child 0. Named coordinate space "panes" lets drag gestures
// report absolute positions — no manual offset math needed.

private struct TerminalContentView: View {
    @ObservedObject var tab: TerminalTab
    @State private var isDragging  = false
    @State private var dragSource: PaneRef? = nil
    @State private var dragHover:  PaneRef? = nil
    @State private var dropSide:   DropSide? = nil

    var body: some View {
        GeometryReader { geo in
            let sz = geo.size
            let pl = tab.primaryLayout

            ZStack(alignment: .topLeading) {
                // Primary — always child 0
                paneView(
                    ref: .primary, state: tab.viewState, layout: pl,
                    onClose: { tab.closePrimaryPane() }, sz: sz,
                    focused: tab.focusedPaneID == nil
                )
                .simultaneousGesture(TapGesture().onEnded { tab.focusedPaneID = nil })

                ForEach(tab.secondaryPanes) { entry in
                    if let l = tab.layouts[entry.id] {
                        paneView(
                            ref: .secondary(entry.id), state: entry.viewState, layout: l,
                            onClose: { tab.removePane(id: entry.id) }, sz: sz,
                            focused: tab.focusedPaneID == entry.id
                        )
                        .simultaneousGesture(TapGesture().onEnded {
                            tab.focusedPaneID = entry.id
                        })
                    }
                }
            }
            .coordinateSpace(name: "panes")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func paneView(ref: PaneRef, state: TerminalViewState,
                          layout l: PaneLayout, onClose: (() -> Void)?,
                          sz: CGSize, focused: Bool) -> some View {
        let isSource = isDragging && dragSource == ref
        let isTarget = isDragging && dragHover  == ref && dragSource != ref

        ZStack(alignment: .top) {
            Color.black
            TerminalSurfaceView(context: state)
                .padding(.top, 30)
                .opacity(isSource ? 0.45 : 1)
            if isTarget {
                switch dropSide {
                case .left:
                    HStack(spacing: 0) { Color.accentOrange.opacity(0.22); Color.clear }
                case .right:
                    HStack(spacing: 0) { Color.clear; Color.accentOrange.opacity(0.22) }
                case .top:
                    VStack(spacing: 0) { Color.accentOrange.opacity(0.22); Color.clear }
                case .bottom:
                    VStack(spacing: 0) { Color.clear; Color.accentOrange.opacity(0.22) }
                case nil:
                    Color.accentOrange.opacity(0.18)
                }
                Rectangle().strokeBorder(Color.accentOrange, lineWidth: 2)
            }
        }
        .overlay(alignment: .top) {
            let customName: String = {
                switch ref {
                case .primary:           return tab.primaryPaneName
                case .secondary(let id): return tab.paneNames[id] ?? ""
                }
            }()
            ReactivePaneHeader(
                state: state,
                customName: customName,
                focused: focused,
                showClose: onClose != nil,
                onClose: onClose ?? {},
                onRename: { tab.rename(ref: ref, to: $0) },
                onDragChanged: { loc in
                    isDragging = true
                    dragSource = ref
                    let h = paneAt(loc, in: sz)
                    if let h = h, h != ref {
                        dragHover = h
                        dropSide = sideOf(loc, pane: h, in: sz)
                    } else {
                        dragHover = nil
                        dropSide  = nil
                    }
                },
                onDragEnded: { loc in
                    let t = paneAt(loc, in: sz)
                    if let t = t, t != ref {
                        if let side = dropSide { tab.performDrop(source: ref, target: t, side: side) }
                        else                   { tab.swapLayouts(ref, t) }
                    }
                    isDragging = false; dragSource = nil; dragHover = nil; dropSide = nil
                }
            )
        }
        .overlay(
            Rectangle()
                .strokeBorder(
                    focused ? Color.accentOrange.opacity(0.55) : Color.white.opacity(0.06),
                    lineWidth: focused ? 1.5 : 1
                )
        )
        .frame(width: sz.width * l.w, height: sz.height * l.h)
        .offset(x: sz.width * l.x, y: sz.height * l.y)
    }

    private func paneAt(_ p: CGPoint, in sz: CGSize) -> PaneRef? {
        for entry in tab.secondaryPanes.reversed() {
            if let l = tab.layouts[entry.id] {
                if CGRect(x: sz.width * l.x, y: sz.height * l.y,
                          width: sz.width * l.w, height: sz.height * l.h).contains(p) {
                    return .secondary(entry.id)
                }
            }
        }
        let pl = tab.primaryLayout
        if CGRect(x: sz.width * pl.x, y: sz.height * pl.y,
                  width: sz.width * pl.w, height: sz.height * pl.h).contains(p) {
            return .primary
        }
        return nil
    }

    private func sideOf(_ p: CGPoint, pane: PaneRef, in sz: CGSize) -> DropSide? {
        let l: PaneLayout
        switch pane {
        case .primary: l = tab.primaryLayout
        case .secondary(let id):
            guard let ll = tab.layouts[id] else { return nil }
            l = ll
        }
        let cx = sz.width  * (l.x + l.w / 2)
        let cy = sz.height * (l.y + l.h / 2)
        let dx = abs(p.x - cx) / (sz.width  * l.w)
        let dy = abs(p.y - cy) / (sz.height * l.h)
        if dx > dy { return p.x < cx ? .left : .right }
        return p.y < cy ? .top : .bottom
    }
}

/// Wraps PaneHeader, observing TerminalViewState so the title reacts to CWD changes.
private struct ReactivePaneHeader: View {
    @ObservedObject var state: TerminalViewState
    let customName: String
    let focused: Bool
    let showClose: Bool
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded:   (CGPoint) -> Void

    var body: some View {
        let title = customName.isEmpty ? smartTitle(for: resolveCWD(state.workingDirectory)) : customName
        PaneHeader(
            title: title,
            focused: focused,
            showClose: showClose,
            onClose: onClose,
            onRename: onRename,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded
        )
    }
}

private struct PaneHeader: View {
    let title: String
    let focused: Bool
    let showClose: Bool
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded:   (CGPoint) -> Void

    @State private var isHovered  = false
    @State private var isRenaming = false
    @State private var editText   = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        ZStack(alignment: .bottom) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .font(.system(size: 10.5))
                    .foregroundStyle(focused ? Color.accentOrange : Color.labelMuted)

                if isRenaming {
                    TextField("", text: $editText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.labelPrimary)
                        .focused($fieldFocused)
                        .onSubmit { commitRename() }
                        .onExitCommand { isRenaming = false }
                        .onAppear { fieldFocused = true }
                } else {
                    Text(title)
                        .font(.system(size: 12, weight: focused ? .medium : .regular))
                        .foregroundStyle(focused ? Color.labelPrimary : Color.labelMuted)
                        .lineLimit(1)
                }

                Spacer(minLength: 0)

                if showClose && !isRenaming {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.labelMuted)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered ? 1 : 0)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(Color.tabBarBg)
            .contentShape(Rectangle())
            .onHover { isHovered = $0 }
            .gesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("panes"))
                .onChanged { onDragChanged($0.location) }
                .onEnded   { onDragEnded($0.location)   })
            .contextMenu {
                Button("Rename") { startRename() }
                if showClose {
                    Divider()
                    Button("Close", role: .destructive) { onClose() }
                }
            }

            Rectangle()
                .fill(focused ? Color.accentOrange : Color.white.opacity(0.05))
                .frame(height: focused ? 2 : 1)
        }
        .frame(height: 30)
    }

    private func startRename() {
        editText = title
        isRenaming = true
    }

    private func commitRename() {
        let name = editText.trimmingCharacters(in: .whitespaces)
        onRename(name)
        isRenaming = false
    }
}

private struct SplitDivider: View {
    let vertical: Bool
    @State private var hovering = false

    var body: some View {
        ZStack {
            Color.clear
            Rectangle()
                .fill(hovering ? Color.white.opacity(0.18) : Color.white.opacity(0.07))
                .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
        }
        .onHover { h in
            hovering = h
            if vertical { h ? NSCursor.resizeLeftRight.push() : NSCursor.pop() }
            else        { h ? NSCursor.resizeUpDown.push()    : NSCursor.pop() }
        }
    }
}

// MARK: - Base directory picker sheet

private struct BaseDirectorySheet: View {
    let onSelect: (URL) -> Void

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Text("Choose Base Directory")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.labelPrimary)
                Text("Srota will scan this folder for organizations, projects, and branches.")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.labelMuted)
                    .multilineTextAlignment(.center)
            }

            Button {
                let panel = NSOpenPanel()
                panel.canChooseFiles = false
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.prompt = "Select"
                panel.message = "Select your base working directory"
                if panel.runModal() == .OK, let url = panel.url {
                    onSelect(url)
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 13))
                    Text("Select Directory")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundStyle(Color.black)
                .padding(.horizontal, 20)
                .padding(.vertical, 10)
                .background(Color.accentOrange)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
        }
        .padding(40)
        .frame(width: 380)
        .background(Color.sidebarBg)
    }
}

