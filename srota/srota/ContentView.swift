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


private func makeToolLauncher(name: String, command: String) -> String {
    let dir = NSHomeDirectory() + "/\(Srota.dir)/launchers"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/\(name).sh"
    let script = "#!/bin/sh\nexport PATH=\"/opt/homebrew/bin:/usr/local/bin:$PATH\"\nexec \(command)\n"
    try? script.write(toFile: path, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    return path
}


/// Smart tab/pane title from CWD:
///   - git repo  → "reponame/branch"
///   - otherwise → "…/parent/dir"
func smartTitle(for path: String?) -> String {
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

enum DropSide { case left, right, top, bottom }

struct PaneLayout {
    var x: CGFloat = 0
    var y: CGFloat = 0
    var w: CGFloat = 1
    var h: CGFloat = 1
}

@Observable
final class PaneEntry: Identifiable {
    let id = UUID()
    let hookPaneID: String
    let daemonStableID: String
    let viewState: TerminalViewState
    var initialCWD: String?
    var isStarted: Bool = true
    // True when isStarted was flipped back to false because something else claimed this pane's
    // PTY (see DaemonConnection.spawnOrAttach's onStolen), as opposed to never having started —
    // the overlay shows "Use Here" instead of "Start" for this case.
    var wasStolen: Bool = false
    var startAction: (() -> Void)? = nil
    init(hookPaneID: String, daemonStableID: String, viewState: TerminalViewState, initialCWD: String? = nil, isStarted: Bool = true) {
        self.hookPaneID = hookPaneID
        self.daemonStableID = daemonStableID
        self.viewState = viewState
        self.initialCWD = initialCWD
        self.isStarted = isStarted
    }
}

// Each pane owns a fractional rect (0–1) of the content area.
// Splitting right/bottom halves the focused pane and places the new one adjacent.
@MainActor
final class TerminalTab: Identifiable, ObservableObject {
    let id = UUID()
    @Published var customName: String = "" {
        didSet {
            if customName.isEmpty {
                titleFromCWD = smartTitle(for: resolveCWD(focusedViewState.workingDirectory))
            }
        }
    }
    @Published var panes: [PaneEntry] = []
    @Published var paneLayouts: [UUID: PaneLayout] = [:]
    @Published var paneNames:   [UUID: String]     = [:]
    let hookTabID = UUID().uuidString
    @Published var focusedPaneID: UUID {
        didSet {
            if customName.isEmpty {
                titleFromCWD = smartTitle(for: resolveCWD(focusedViewState.workingDirectory))
            }
            bindTitleSink()
        }
    }
    @Published private(set) var titleFromCWD: String = "Terminal"
    private var titleSink: AnyCancellable?
    var closeTabCallback: (() -> Void)?
    let initialWorkingDirectory: String?
    private var daemon: DaemonConnection?

    init(colorScheme: ColorScheme, workingDirectory: String? = nil, daemon: DaemonConnection? = nil, firstPaneStableID: String? = nil, autoStart: Bool = true) {
        self.initialWorkingDirectory = workingDirectory
        self.daemon = daemon
        let paneHookID = UUID().uuidString
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
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session), workingDirectory: workingDirectory)
        state.controller.setColorScheme(colorScheme == .dark ? .dark : .light)
        let stableID = firstPaneStableID ?? UUID().uuidString
        let first = PaneEntry(
            hookPaneID: stableID,
            daemonStableID: stableID,
            viewState: state,
            initialCWD: workingDirectory
        )
        self.panes = [first]
        self.paneLayouts = [first.id: PaneLayout()]
        self.focusedPaneID = first.id
        bindTitleSink()
        let firstID = first.id
        state.onClose = { [weak self, ref] _ in
            guard let self else { return }
            self.daemon?.closeSession(stableID: stableID, paneID: ref.id)
            self.removePane(id: firstID, closeDaemon: false)
        }
        if autoStart {
            attachWithReclaim(entry: first, stableID: stableID, cwd: workingDirectory,
                               env: ["ZDOTDIR": "\(NSHomeDirectory())/\(Srota.dir)"], session: session, ref: ref)
        } else {
            first.isStarted = false
            first.startAction = { [weak self] in
                self?.attachWithReclaim(entry: first, stableID: stableID, cwd: workingDirectory,
                                         env: ["ZDOTDIR": "\(NSHomeDirectory())/\(Srota.dir)"], session: session, ref: ref)
            }
        }
    }

    // A PTY has exactly one live owner at a time. If some other viewer (another pane, or the
    // Agents tab) later steals this stableID, entry flips back to the "Start"-style overlay with
    // a reclaim action wired to attach again — see DaemonConnection.spawnOrAttach's onStolen.
    private func attachWithReclaim(entry: PaneEntry, stableID: String, cwd: String?, env: [String: String],
                                    session: InMemoryTerminalSession, ref: DaemonPaneRef) {
        entry.wasStolen = false
        daemon?.spawnOrAttach(
            stableID: stableID, cwd: cwd ?? NSHomeDirectory(), env: env, session: session, into: ref,
            onStolen: { [weak self, weak entry] in
                guard let self, let entry else { return }
                entry.isStarted = false
                entry.wasStolen = true
                entry.startAction = { [weak self] in
                    self?.attachWithReclaim(entry: entry, stableID: stableID, cwd: cwd, env: env, session: session, ref: ref)
                }
            }
        )
    }

    var displayName: String {
        if !customName.isEmpty { return customName }
        if let name = paneNames[focusedPaneID], !name.isEmpty { return name }
        return titleFromCWD
    }

    var statusPath: String? {
        resolveCWD(focusedViewState.workingDirectory) ?? initialWorkingDirectory
    }

    var focusedViewState: TerminalViewState {
        panes.first(where: { $0.id == focusedPaneID })?.viewState ?? panes[0].viewState
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

    func rename(id: UUID, to name: String) {
        paneNames[id] = name
    }

    func removePane(id: UUID, closeDaemon: Bool = true) {
        let wasFocused  = focusedPaneID == id
        let pane = panes.first { $0.id == id }
        if closeDaemon, let pane { daemon?.closeSession(stableID: pane.daemonStableID) }
        expandNeighbor(of: id)
        panes.removeAll { $0.id == id }
        paneLayouts.removeValue(forKey: id)
paneNames.removeValue(forKey: id)
if panes.isEmpty {
closeTabCallback?()
} else if wasFocused {
focusedPaneID = panes[0].id
}
}

func shutdown() {
for pane in panes {
daemon?.closeSession(stableID: pane.daemonStableID)
}
}

private func addPane(colorScheme: ColorScheme, layout: PaneLayout, workingDirectory: String? = nil) {
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
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session), workingDirectory: workingDirectory)
        state.controller.setColorScheme(colorScheme == .dark ? .dark : .light)
let stableID = UUID().uuidString
let entry = PaneEntry(hookPaneID: stableID, daemonStableID: stableID, viewState: state, initialCWD: workingDirectory)
let entryID = entry.id
state.onClose = { [weak self, ref] _ in
guard let self else { return }
self.daemon?.closeSession(stableID: stableID, paneID: ref.id)
self.removePane(id: entryID, closeDaemon: false)
}
        paneLayouts[entry.id] = layout
        panes.append(entry)
        focusedPaneID = entry.id
        attachWithReclaim(entry: entry, stableID: stableID, cwd: workingDirectory,
                           env: ["ZDOTDIR": "\(NSHomeDirectory())/\(Srota.dir)"], session: session, ref: ref)
    }

    func restorePane(record: PaneRecord, colorScheme: ColorScheme) {
        let cwd = record.initialCWD.isEmpty ? nil : record.initialCWD
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
        state.configuration = TerminalSurfaceOptions(backend: .inMemory(session), workingDirectory: cwd)
        state.controller.setColorScheme(colorScheme == .dark ? .dark : .light)
 let entry = PaneEntry(hookPaneID: record.id, daemonStableID: record.id, viewState: state, initialCWD: cwd)
 let entryID = entry.id
 state.onClose = { [weak self, ref] _ in
 guard let self else { return }
 self.daemon?.closeSession(stableID: record.id, paneID: ref.id)
 self.removePane(id: entryID, closeDaemon: false)
 }
        paneLayouts[entry.id] = PaneLayout(
            x: CGFloat(record.lx), y: CGFloat(record.ly),
            w: CGFloat(record.lw), h: CGFloat(record.lh))
        panes.append(entry)
        focusedPaneID = entry.id
        entry.isStarted = false
        entry.startAction = { [weak self] in
            self?.attachWithReclaim(entry: entry, stableID: record.id, cwd: cwd,
                                     env: ["ZDOTDIR": "\(NSHomeDirectory())/\(Srota.dir)"], session: session, ref: ref)
        }
    }

    func swapLayouts(_ a: UUID, _ b: UUID) {
        guard a != b else { return }
        let la = paneLayouts[a] ?? PaneLayout()
        let lb = paneLayouts[b] ?? PaneLayout()
        paneLayouts[a] = lb
        paneLayouts[b] = la
    }

    func performDrop(source: UUID, target: UUID, side: DropSide) {
        guard source != target else { return }
        expandNeighbor(of: source)
        let tl = paneLayouts[target] ?? PaneLayout()
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
        paneLayouts[target] = newTarget
        paneLayouts[source] = newSource
    }

    // MARK: - Private

    private var focusedLayout: PaneLayout? { paneLayouts[focusedPaneID] }

    private func setFocusedLayout(_ l: PaneLayout) { paneLayouts[focusedPaneID] = l }

    private func bindTitleSink() {
        titleSink = focusedViewState.$workingDirectory
            .receive(on: RunLoop.main)
            .sink { [weak self] cwd in
                guard let self, self.customName.isEmpty else { return }
                self.titleFromCWD = smartTitle(for: resolveCWD(cwd))
            }
    }

    private func expandNeighbor(of id: UUID) {
        guard let rl = paneLayouts[id] else { return }
        let eps: CGFloat = 0.001
        let others: [(UUID, PaneLayout)] = panes.compactMap { e in
            guard e.id != id, let l = paneLayouts[e.id] else { return nil }
            return (e.id, l)
        }

        for (otherID, var nl) in others {
            if abs(nl.x + nl.w - rl.x) < eps && abs(nl.y - rl.y) < eps && abs(nl.h - rl.h) < eps {
                nl.w += rl.w; paneLayouts[otherID] = nl; return
            }
            if abs(nl.y + nl.h - rl.y) < eps && abs(nl.x - rl.x) < eps && abs(nl.w - rl.w) < eps {
                nl.h += rl.h; paneLayouts[otherID] = nl; return
            }
            if abs(nl.x - (rl.x + rl.w)) < eps && abs(nl.y - rl.y) < eps && abs(nl.h - rl.h) < eps {
                nl.x = rl.x; nl.w += rl.w; paneLayouts[otherID] = nl; return
            }
            if abs(nl.y - (rl.y + rl.h)) < eps && abs(nl.x - rl.x) < eps && abs(nl.w - rl.w) < eps {
                nl.y = rl.y; nl.h += rl.h; paneLayouts[otherID] = nl; return
            }
        }

        func overlapsY(_ nl: PaneLayout) -> Bool { nl.y + nl.h > rl.y + eps && nl.y < rl.y + rl.h - eps }
        func overlapsX(_ nl: PaneLayout) -> Bool { nl.x + nl.w > rl.x + eps && nl.x < rl.x + rl.w - eps }

        let rightNeighbors = others.filter { abs($0.1.x - (rl.x + rl.w)) < eps && overlapsY($0.1) }
        if !rightNeighbors.isEmpty {
            for (r, var nl) in rightNeighbors { nl.x = rl.x; nl.w += rl.w; paneLayouts[r] = nl }; return
        }
        let leftNeighbors = others.filter { abs($0.1.x + $0.1.w - rl.x) < eps && overlapsY($0.1) }
        if !leftNeighbors.isEmpty {
            for (r, var nl) in leftNeighbors { nl.w += rl.w; paneLayouts[r] = nl }; return
        }
        let bottomNeighbors = others.filter { abs($0.1.y - (rl.y + rl.h)) < eps && overlapsX($0.1) }
        if !bottomNeighbors.isEmpty {
            for (r, var nl) in bottomNeighbors { nl.y = rl.y; nl.h += rl.h; paneLayouts[r] = nl }; return
        }
        let topNeighbors = others.filter { abs($0.1.y + $0.1.h - rl.y) < eps && overlapsX($0.1) }
        if !topNeighbors.isEmpty {
            for (r, var nl) in topNeighbors { nl.h += rl.h; paneLayouts[r] = nl }
        }
    }
}

@MainActor
final class Workspace: Identifiable, ObservableObject {
    let id: UUID
    @Published var name: String
    @Published var isPinned: Bool = false
    @Published var directory: String = ""
    var daemon: DaemonConnection? = nil
    var lastAccessed: Date = Date()
    var isActive: Bool { isPinned || lastAccessed > Date(timeIntervalSinceNow: -172800) }
    @Published var tabs: [TerminalTab] = [] {
        didSet { rebindTabSinks() }
    }
    @Published var selectedTabID: UUID?
    private var lastColorScheme: ColorScheme = .dark
    private var tabSinks: [AnyCancellable] = []

    private func rebindTabSinks() {
        tabSinks = tabs.map { tab in
            tab.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        }
    }

    init(id: UUID = UUID(), name: String) {
        self.id   = id
        self.name = name
    }

    var selectedTab: TerminalTab? { tabs.first { $0.id == selectedTabID } }

    var displayStatus: AgentRunStatus? {
        guard let daemon else { return nil }
        return tabs
            .flatMap(\.panes)
            .compactMap { daemon.agentStatesByStableID[$0.daemonStableID] }
            .max { $0.updatedAt < $1.updatedAt }?
            .status
    }

    var currentWorkingDirectory: String? {
        resolveCWD(selectedTab?.focusedViewState.workingDirectory)
    }

    func addTab(colorScheme: ColorScheme, workingDirectory: String? = nil) {
        lastColorScheme = colorScheme
        let cwd = workingDirectory ?? (directory.isEmpty ? nil : directory)
        let tab = TerminalTab(colorScheme: colorScheme, workingDirectory: cwd, daemon: daemon)
        tab.closeTabCallback = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.closeTab(id: tab.id)
        }
        tabs.append(tab)
        selectedTabID = tab.id
    }

    func addRestoredTab(record: TabRecord, colorScheme: ColorScheme, firstPaneStableID: String? = nil) {
        lastColorScheme = colorScheme
        let cwd = record.initialCWD.isEmpty ? nil : record.initialCWD
        let tab = TerminalTab(colorScheme: colorScheme, workingDirectory: cwd, daemon: daemon, firstPaneStableID: firstPaneStableID, autoStart: false)
        tab.closeTabCallback = { [weak self, weak tab] in
            guard let self, let tab else { return }
            self.closeTab(id: tab.id)
        }
        tabs.append(tab)
        if record.isSelected { selectedTabID = tab.id }
    }

func closeTab(id: UUID) {
 if let tab = tabs.first(where: { $0.id == id }) {
 tab.shutdown()
 }
 if selectedTabID == id {
 if let idx = tabs.firstIndex(where: { $0.id == id }) {
 let next = tabs.indices.contains(idx + 1) ? tabs[idx + 1].id
                         : idx > 0 ? tabs[idx - 1].id : nil
                selectedTabID = next
            }
        }
        tabs.removeAll { $0.id == id }
        NotificationCenter.default.post(name: .srotaTabClosed, object: nil,
                                        userInfo: ["workspaceID": self.id.uuidString])
    }
}

@MainActor
final class WorkspaceFolder: Identifiable, ObservableObject {
    let id = UUID()
    @Published var name: String
    @Published var tag: String = ""
    @Published var workspaces: [Workspace] = [] {
        didSet { rebindWorkspaceSinks() }
    }
    @Published var isExpanded: Bool = true
    init(name: String, tag: String = "") { self.name = name; self.tag = tag }

    private var workspaceSinks: [AnyCancellable] = []

    private func rebindWorkspaceSinks() {
        // Forwards e.g. isPinned toggles so folder/manager list filters (pinned section,
        // per-folder counts) refresh immediately instead of on the next unrelated redraw.
        workspaceSinks = workspaces.map { ws in
            ws.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }
}

@MainActor
final class TerminalManager: ObservableObject {
    var daemon: DaemonConnection? = nil
    @Published var workspaces: [Workspace] = [] {   // unfiled
        didSet { rebindWorkspaceSinks() }
    }
    @Published var folders: [WorkspaceFolder] = [] {
        didSet { rebindFolderSinks() }
    }
    @Published var selectedWorkspaceID: UUID?

    // Transient (unpersisted) drag-reorder UI state, shared across rows so exactly one
    // row is ever "the" insertion target — a per-row @State bool let two adjacent rows
    // disagree about who's highlighted when the array reorders mid-drag (see moveWorkspace).
    @Published var reorderDropTargetID: UUID?
    @Published var reorderDropEdge: VerticalEdge?
    private var reorderDropAutoClear: DispatchWorkItem?

    // Set synchronously in the source row's .onDrag closure, which always runs before any
    // destination sees the drag — plain in-process state, not carried on the NSItemProvider
    // itself. That distinction matters: NSItemProvider.suggestedName looked like a valid
    // synchronous "kind" marker but doesn't survive AppKit's actual pasteboard-mediated drag
    // transfer (it's meant for file-promise naming), so every drop's kind check silently
    // failed and nothing moved at all.
    var draggedKind: DragKind?

    // ponytail: self-expiring safety net. dropUpdated fires continuously (many times/sec)
    // while a drag is actually hovering, re-arming this before it ever fires — so in the
    // normal case this never triggers. It only fires when dropUpdated calls stop without a
    // matching dropExited/performDrop, which macOS does intermittently here for reasons not
    // pinned down; upgrade path is finding and fixing that root cause if it recurs elsewhere.
    func noteReorderDropUpdate(targetID: UUID?, edge: VerticalEdge?) {
        reorderDropAutoClear?.cancel()
        // dropUpdated fires on every mouse-move tick; skip the write (and its animation)
        // when nothing actually changed so hovering the same row doesn't keep re-triggering
        // a fade and reads as jitter instead of a settled highlight.
        if targetID != reorderDropTargetID || edge != reorderDropEdge {
            withAnimation(.easeOut(duration: 0.12)) {
                reorderDropTargetID = targetID
                reorderDropEdge = edge
            }
        }
        guard targetID != nil else { return }
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.12)) {
                self?.reorderDropTargetID = nil
                self?.reorderDropEdge = nil
            }
        }
        reorderDropAutoClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    func clearReorderDrop() {
        reorderDropAutoClear?.cancel()
        reorderDropAutoClear = nil
        draggedKind = nil
        guard reorderDropTargetID != nil else { return }
        withAnimation(.easeOut(duration: 0.12)) {
            reorderDropTargetID = nil
            reorderDropEdge = nil
        }
    }

    private var folderSinks: [AnyCancellable] = []
    private var workspaceSinks: [AnyCancellable] = []

    private func rebindFolderSinks() {
        folderSinks = folders.map { folder in
            folder.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    private func rebindWorkspaceSinks() {
        workspaceSinks = workspaces.map { ws in
            ws.objectWillChange.sink { [weak self] _ in
                self?.objectWillChange.send()
            }
        }
    }

    var allWorkspaces: [Workspace] { workspaces + folders.flatMap(\.workspaces) }
    var pinnedWorkspaces: [Workspace] { allWorkspaces.filter(\.isPinned) }

    var selectedWorkspace: Workspace? {
        allWorkspaces.first { $0.id == selectedWorkspaceID }
    }

    func folderID(containingWorkspace wsID: UUID) -> UUID? {
        folders.first { $0.workspaces.contains { $0.id == wsID } }?.id
    }

    func addWorkspace(colorScheme: ColorScheme, inFolder folderID: UUID? = nil, workingDirectory: String? = nil, name: String? = nil) {
        let wsName = name ?? "Workspace \(allWorkspaces.count + 1)"
        let ws = Workspace(name: wsName)
        ws.directory = workingDirectory ?? ""
        ws.daemon = daemon
        ws.addTab(colorScheme: colorScheme, workingDirectory: workingDirectory)
        if let folderID, let folder = folders.first(where: { $0.id == folderID }) {
            folder.workspaces.append(ws)
        } else {
            workspaces.append(ws)
        }
        selectedWorkspaceID = ws.id
    }

    func selectWorkspace(id: UUID) {
        selectedWorkspaceID = id
        selectedWorkspace?.lastAccessed = Date()
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
if let workspace = allWorkspaces.first(where: { $0.id == id }) {
for tab in workspace.tabs { tab.shutdown() }
}
if selectedWorkspaceID == id {
let all = allWorkspaces
if let idx = all.firstIndex(where: { $0.id == id }) {
                selectedWorkspaceID = all.indices.contains(idx + 1) ? all[idx + 1].id
                                    : idx > 0 ? all[idx - 1].id : nil
            }
        }
        let beforeCount = workspaces.count
        workspaces.removeAll { $0.id == id }
        if workspaces.count < beforeCount {
            NotificationCenter.default.post(name: .srotaWorkspaceClosed, object: nil,
                                            userInfo: ["id": id.uuidString])
            return
        }
        for folder in folders { folder.workspaces.removeAll { $0.id == id } }
        NotificationCenter.default.post(name: .srotaWorkspaceClosed, object: nil,
                                        userInfo: ["id": id.uuidString])
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

    func moveWorkspace(id wsID: UUID, toFolder folderID: UUID?, before beforeID: UUID? = nil, after afterID: UUID? = nil) {
        clearReorderDrop()
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
        func insert(into list: inout [Workspace]) {
            if let beforeID, let idx = list.firstIndex(where: { $0.id == beforeID }) {
                list.insert(ws, at: idx)
            } else if let afterID, let idx = list.firstIndex(where: { $0.id == afterID }) {
                list.insert(ws, at: idx + 1)
            } else {
                list.append(ws)
            }
        }
        if let folderID, let folder = folders.first(where: { $0.id == folderID }) {
            insert(into: &folder.workspaces)
        } else {
            insert(into: &workspaces)
        }
    }

    func moveFolder(id folderID: UUID, before beforeID: UUID? = nil, after afterID: UUID? = nil) {
        clearReorderDrop()
        guard let idx = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let folder = folders.remove(at: idx)
        if let beforeID, let targetIdx = folders.firstIndex(where: { $0.id == beforeID }) {
            folders.insert(folder, at: targetIdx)
        } else if let afterID, let targetIdx = folders.firstIndex(where: { $0.id == afterID }) {
            folders.insert(folder, at: targetIdx + 1)
        } else {
            folders.append(folder)
        }
    }
}

// MARK: - Design tokens

private extension Color {
    static let tabBarBg     = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let tabHoverBg   = Color(red: 0.13, green: 0.13, blue: 0.15)
    static let accentOrange = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let labelPrimary = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let labelMuted   = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.40)
}

// MARK: - Sidebar resize handle (AppKit-driven, same technique as PaneResizingView)

// A SwiftUI DragGesture on a 1-3pt Rectangle loses tracking on fast mouse
// moves because gesture recognition needs the cursor to stay inside that
// thin hit area every frame. AppKit gives a view that receives mouseDown
// implicit capture of all mouseDragged/mouseUp events until release, even
// once the cursor leaves its bounds - the same mechanism PaneResizingView
// relies on for jitter-free dragging.
private final class SidebarResizeHandleView: NSView {
    var onDragChanged: (CGFloat) -> Void = { _ in }
    var onDragEnded: () -> Void = {}
    var onHoverChanged: (Bool) -> Void = { _ in }

    private var dragStartWindowX: CGFloat?

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged(true) }

    override func mouseExited(with event: NSEvent) {
        if dragStartWindowX == nil { onHoverChanged(false) }
    }

    override func mouseDown(with event: NSEvent) {
        dragStartWindowX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let startX = dragStartWindowX else { return }
        onDragChanged(event.locationInWindow.x - startX)
    }

    override func mouseUp(with event: NSEvent) {
        guard dragStartWindowX != nil else { return }
        dragStartWindowX = nil
        onDragEnded()
        if !bounds.contains(convert(event.locationInWindow, from: nil)) {
            onHoverChanged(false)
        }
    }
}

private struct SidebarResizeHandle: NSViewRepresentable {
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> SidebarResizeHandleView {
        let v = SidebarResizeHandleView()
        v.onDragChanged = onDragChanged
        v.onDragEnded = onDragEnded
        v.onHoverChanged = onHoverChanged
        return v
    }

    func updateNSView(_ v: SidebarResizeHandleView, context: Context) {
        v.onDragChanged = onDragChanged
        v.onDragEnded = onDragEnded
        v.onHoverChanged = onHoverChanged
    }
}

// MARK: - Sidebar divider

private struct SidebarDivider: View {
    let sidebarVisible: Bool
    @Binding var width: CGFloat
    @State private var isHovered = false
    @State private var dragStartWidth: CGFloat? = nil

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color.white.opacity(0.06))
                .frame(width: 1)
            if isHovered {
                Image(systemName: "arrow.left.and.right")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(Color.accentOrange)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(Color.tabBarBg))
                    .overlay(Circle().stroke(Color.white.opacity(0.1), lineWidth: 1))
                    .transition(.opacity)
            }
            SidebarResizeHandle(
                onDragChanged: { dx in
                    let startWidth = dragStartWidth ?? width
                    dragStartWidth = startWidth
                    width = SidebarResizeLogic.updatedWidth(startWidth: startWidth, translationWidth: dx)
                },
                onDragEnded: { dragStartWidth = nil },
                onHoverChanged: { isHovered = $0 }
            )
        }
        .frame(width: 9)
        .opacity(sidebarVisible ? 1 : 0)
        .allowsHitTesting(sidebarVisible)
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .help("Drag to resize sidebar")
    }
}

// MARK: - Resizable sidebar container

// Owns `width` locally so dragging only re-renders this subtree, not the
// whole ContentView.body (same reasoning as the pane resizer, which scopes
// its drag state to the small per-tab TerminalTab instead of the root view).
private struct ResizableSidebar: View {
    @ObservedObject var manager: TerminalManager
    let sidebarVisible: Bool
    let keyboardFocusedWorkspaceID: UUID?
    let onAdd: () -> Void
    let onSelectWorkspace: (UUID) -> Void
    let onSelectAgentTab: (UUID, UUID, UUID) -> Void
    let onShowAllAgents: () -> Void

    @State private var width: CGFloat = 220

    var body: some View {
        SidebarView(
            manager: manager,
            keyboardFocusedWorkspaceID: keyboardFocusedWorkspaceID,
            onAdd: onAdd,
            onSelectWorkspace: onSelectWorkspace,
            onSelectAgentTab: onSelectAgentTab,
            onShowAllAgents: onShowAllAgents
        )
        .frame(width: width, alignment: .leading) // pin inner layout so it doesn't reflow every animation frame
        .frame(width: sidebarVisible ? width : 0, alignment: .leading)
        .clipped()
        .allowsHitTesting(sidebarVisible)

        SidebarDivider(sidebarVisible: sidebarVisible, width: $width)
    }
}

// MARK: - Root

struct ContentView: View {
    @StateObject private var manager = TerminalManager()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppSettings.self) private var settings
    @Environment(DaemonConnection.self) private var daemon
    @Environment(WorkspaceDB.self) private var db
    @Environment(FeatureAgentFocus.self) private var agentFocus
    @Environment(KeyboardShortcutManager.self) private var shortcuts
    @Environment(PresetsStore.self) private var presetsStore
    @Environment(AgentsStore.self) private var agentsStore
    @State private var sidebarVisible = true
    @State private var showBaseDirectoryPicker = false
    @State private var managementTab: ManagementTab = .workspaces
    @State private var restoredSessions = false
    @State private var showSettings = false
    @State private var showPrompts = false
    @State private var agentToLaunch: AgentItem? = nil
    @State private var worktreeError: String? = nil
    @State private var workspaceSwitcherModel: SwitcherModel? = nil
    @State private var sidebarKeyboardFocus = false
    @State private var sidebarHighlightedWorkspaceID: UUID? = nil
    @State private var sidebarReturnFocusState: TerminalViewState? = nil

    var body: some View {
        VStack(spacing: 0) {
        TopNavBar(
            selected: $managementTab,
            onSettings: { showSettings.toggle() },
            onPrompts: { showPrompts.toggle() },
            onPresetLaunch: { preset in
                let filtered = preset.commands.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                guard !filtered.isEmpty else { return }
                let args = preset.arguments.trimmingCharacters(in: .whitespaces)
                let lastCmd = (preset.isAgent && !args.isEmpty)
                    ? "\(filtered.last!) \(args)"
                    : filtered.last!
                let cmd: String
                if preset.isAgent && !preset.systemPrompt.isEmpty {
                    let hex = String(UUID().uuidString.filter { $0.isHexDigit }.prefix(6).lowercased())
                    let launchersDir = NSHomeDirectory() + "/\(Srota.dir)/launchers"
                    try? FileManager.default.createDirectory(atPath: launchersDir, withIntermediateDirectories: true)
                    let promptFile = launchersDir + "/preset-prompt-\(hex).txt"
                    try? preset.systemPrompt.write(toFile: promptFile, atomically: true, encoding: .utf8)
                    let spVar = "__SROTA_SP=$(cat '\(promptFile)')"
                    let launch = preset.systemPromptFlag.isEmpty
                        ? "\(spVar); \(lastCmd) \"$__SROTA_SP\""
                        : "\(spVar); \(lastCmd) \(preset.systemPromptFlag) \"$__SROTA_SP\""
                    cmd = filtered.dropLast().map { $0 + "\n" }.joined() + launch + "\n"
                } else {
                    cmd = (filtered.dropLast() + [lastCmd]).joined(separator: "\n") + "\n"
                }
                if let featureState = agentFocus.activeViewState, managementTab == .features {
                    featureState.send(cmd)
                } else {
                    manager.selectedWorkspace?.selectedTab?.focusedViewState.send(cmd)
                }
            },
            onAgentSelected: { agentToLaunch = $0 }
        )
        ZStack {
        HStack(spacing: 0) {
                ResizableSidebar(
                    manager: manager,
                    sidebarVisible: sidebarVisible,
                    keyboardFocusedWorkspaceID: sidebarKeyboardFocus ? sidebarHighlightedWorkspaceID : nil,
                    onAdd: {
                        clearSidebarKeyboardFocus()
                        let fid = manager.selectedWorkspaceID.flatMap { manager.folderID(containingWorkspace: $0) }
                        manager.addWorkspace(colorScheme: colorScheme, inFolder: fid)
                        saveLayout()
                    },
                    onSelectWorkspace: { id in
                        clearSidebarKeyboardFocus()
                        manager.selectWorkspace(id: id)
                    },
                    onSelectAgentTab: { workspaceID, tabID, paneID in
                        clearSidebarKeyboardFocus()
                        focusAgentPane(workspaceID: workspaceID, tabID: tabID, paneID: paneID)
                    },
                    onShowAllAgents: { managementTab = .agents }
                )

                VStack(spacing: 0) {
                    if let ws = manager.selectedWorkspace {
                        TabBarView(workspace: ws, colorScheme: colorScheme, sidebarVisible: $sidebarVisible,
                                   onUserInteraction: { clearSidebarKeyboardFocus() },
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
                                         selectedWorkspaceID: manager.selectedWorkspaceID,
                                         onPaneActivated: { clearSidebarKeyboardFocus() },
                                         onPaneResizeFinished: saveLayout)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .animation(.spring(duration: 0.22, bounce: 0.0), value: sidebarVisible)
        .onChange(of: sidebarVisible) { _, visible in
            guard !visible else { return }
            clearSidebarKeyboardFocus(restorePane: true)
        }
        .onChange(of: daemon.isConnected) { _, connected in
            guard connected else { return }
            Task {
                guard let running = try? await daemon.list() else { return }
                let ids = Set(running.filter { $0.exitCode == nil }.map(\.stableID))
                for ws in manager.allWorkspaces {
                    for tab in ws.tabs {
                        for pane in tab.panes where !pane.isStarted {
                            if ids.contains(pane.daemonStableID) {
                                pane.startAction?()
                                pane.isStarted = true
                            }
                        }
                    }
                }
            }
        }
        .onAppear {
            if !restoredSessions {
                restoredSessions = true
                restoreSessionsFromDB(colorScheme: colorScheme)
            }
            if settings.baseWorkingDirectory == nil { showBaseDirectoryPicker = true }
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

            let launchAgentName     = note.userInfo?["launchAgentName"] as? String
            let launchAgentContext  = note.userInfo?["launchAgentContext"] as? String
            let launchAgentPresetID = note.userInfo?["launchAgentPresetID"] as? String
            @MainActor func launchAgentIfRequested() {
                guard let launchAgentName,
                      let agent = agentsStore.agents.first(where: { $0.name == launchAgentName }) else { return }
                let systemPrompt = agentsStore.systemPrompt(for: agent)
                let firstMessage = (launchAgentContext?.isEmpty == false) ? launchAgentContext! : agentsStore.firstMessage(for: agent)
                let preset = launchAgentPresetID.flatMap { id in presetsStore.presets.first { $0.id.uuidString == id } }
                launchAgent(agent: agent, systemPrompt: systemPrompt, firstMessage: firstMessage, preset: preset)
            }

            // if workspace with same name already exists in that folder, just select it
            let candidatePool = folder?.workspaces ?? manager.workspaces
            if let existing = candidatePool.first(where: { $0.name == wsName }) {
                manager.selectWorkspace(id: existing.id)
                managementTab = .workspaces
                launchAgentIfRequested()
                return
            }

            if needsWorktree {
                Task.detached {
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                    p.arguments = ["-C", projectPath, "worktree", "add", path, branchRef]
                    let errPipe = Pipe()
                    p.standardError = errPipe
                    do {
                        try p.run()
                        p.waitUntilExit()
                    } catch {
                        let msg = error.localizedDescription
                        await MainActor.run { worktreeError = msg }
                        return
                    }
                    guard p.terminationStatus == 0 else {
                        let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "git worktree add failed"
                        await MainActor.run { worktreeError = msg.isEmpty ? "git worktree add failed" : msg }
                        return
                    }
                await MainActor.run { [folderID] in
                        manager.addWorkspace(colorScheme: colorScheme, inFolder: folderID,
                                             workingDirectory: path, name: wsName)
                        db.saveWorkspaceSession(WorkspaceSession(
                            id: manager.allWorkspaces.last?.id.uuidString ?? UUID().uuidString,
                            name: wsName ?? "", folderName: folderName ?? "",
                            folderTag: folderTag, position: 0,
                            lastCWD: path,
                            lastAccessed: Int(Date().timeIntervalSince1970),
                            isPinned: false,
                            directory: path))
                        managementTab = .workspaces
                        saveLayout()
                        if let baseDir = settings.baseWorkingDirectory { db.scan(baseDir: baseDir) }
                        launchAgentIfRequested()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            manager.selectedWorkspace?.selectedTab?.focusedViewState.send("pwd\n")
                        }
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
                        lastCWD: path, lastAccessed: Int(Date().timeIntervalSince1970),
                        isPinned: false, directory: path))
                }
                managementTab = .workspaces
                saveLayout()
                launchAgentIfRequested()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    manager.selectedWorkspace?.selectedTab?.focusedViewState.send("pwd\n")
                }
            }
        }
        .onAppear {
            registerShortcutActions()
            shortcuts.start()
        }
        .onChange(of: shortcuts.showWorkspaceSwitcher) { _, isShowing in
            workspaceSwitcherModel = isShowing ? makeWorkspaceSwitcherModel() : nil
        }
        .onDisappear {
            shortcuts.plainKeyHandler = nil
            shortcuts.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            saveLayout()
        }
        .onReceive(NotificationCenter.default.publisher(for: .srotaWorkspaceClosed)) { note in
            guard let wsID = note.userInfo?["id"] as? String else { return }
            db.deleteWorkspaceSession(id: wsID)
        }
        .onReceive(NotificationCenter.default.publisher(for: .srotaTabClosed)) { _ in
            saveLayout()
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
        if showSettings {
            SettingsPanel(isPresented: $showSettings)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.067, green: 0.067, blue: 0.075))
        }
        if showPrompts {
            PromptsPanel(isPresented: $showPrompts)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.067, green: 0.067, blue: 0.075))
        }
        VStack {
            Spacer()
            if shortcuts.awaitingChord {
                ChordIndicator(display: KeyCombo(shortcuts.prefixKey)?.display ?? shortcuts.prefixKey)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
                .padding(.bottom, 20)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: shortcuts.awaitingChord)
        .allowsHitTesting(false)
        if shortcuts.showLazygit {
            LazygitOverlay(cwd: shortcuts.lazygitCWD, launcherPath: makeToolLauncher(name: "lazygit", command: "lazygit")) {
                let prevState = manager.selectedWorkspace?.selectedTab?.focusedViewState
                withAnimation(.easeInOut(duration: 0.15)) { shortcuts.showLazygit = false }
                if let prevState {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        focusTerminalView(for: prevState)
                    }
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
        if shortcuts.showHunk {
            LazygitOverlay(cwd: shortcuts.hunkCWD, title: "hunk", icon: "square.split.diagonal.2x2", launcherPath: makeToolLauncher(name: "hunk", command: "hunk diff")) {
                let prevState = manager.selectedWorkspace?.selectedTab?.focusedViewState
                withAnimation(.easeInOut(duration: 0.15)) { shortcuts.showHunk = false }
                if let prevState {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        focusTerminalView(for: prevState)
                    }
                }
            }
            .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
                if shortcuts.showWorkspaceSwitcher, let workspaceSwitcherModel {
                    let dismissWorkspaceSwitcher = {
                        withAnimation(.easeInOut(duration: 0.15)) { shortcuts.showWorkspaceSwitcher = false }
                        if let state = manager.selectedWorkspace?.selectedTab?.focusedViewState {
                            DispatchQueue.main.async { focusTerminalView(for: state) }
                        }
                    }
                    WorkspaceSwitcherOverlay(
                        model: workspaceSwitcherModel,
                        onSelectWorkspace: { id in
                            manager.selectWorkspace(id: id)
                            dismissWorkspaceSwitcher()
                        },
                        onSelectTab: { wsID, tabID in
                            manager.selectWorkspace(id: wsID)
                            manager.allWorkspaces.first(where: { $0.id == wsID })?.selectedTabID = tabID
                            dismissWorkspaceSwitcher()
                        },
                        onSelectPane: { wsID, tabID, paneID in
                            manager.selectWorkspace(id: wsID)
                            if let ws = manager.allWorkspaces.first(where: { $0.id == wsID }) {
                                ws.selectedTabID = tabID
                                ws.tabs.first(where: { $0.id == tabID })?.focusedPaneID = paneID
                            }
                            dismissWorkspaceSwitcher()
                        },
                        onDismiss: dismissWorkspaceSwitcher
                    )
                    .transition(.opacity.combined(with: .scale(scale: 0.97)))
                }
        } // end ZStack
        } // end VStack
        .ignoresSafeArea(.container, edges: .top)
        .alert("Worktree Error", isPresented: .init(
            get: { worktreeError != nil },
            set: { if !$0 { worktreeError = nil } }
        )) {
            Button("OK", role: .cancel) { worktreeError = nil }
        } message: {
            Text(worktreeError ?? "")
        }
        .sheet(item: $agentToLaunch) { agent in
            AgentLaunchSheet(agent: agent) { systemPrompt, firstMessage, preset in
                launchAgent(agent: agent, systemPrompt: systemPrompt, firstMessage: firstMessage, preset: preset)
            }
        }
    }

    private func launchAgent(agent: AgentItem, systemPrompt: String, firstMessage: String, preset: TerminalPreset?) {
        // sheet preset wins; fall back to agent's saved presetID so it applies even if user didn't touch the picker
        let resolvedPreset = preset ?? presetsStore.presets.first { $0.id == agent.presetID }
        let base = resolvedPreset?.commands.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                         .joined(separator: " ")
            ?? (agent.name.localizedCaseInsensitiveContains("codex") ? "codex" : "claude")
        // Empty flag = agent takes prompt positionally (e.g. codex) — no separate system-prompt flag,
        // so fold the system prompt into the user prompt instead of dropping it.
        let flag = resolvedPreset?.systemPromptFlag ?? "--system-prompt"
        let promptContent = flag.isEmpty
            ? [systemPrompt, firstMessage].filter { !$0.isEmpty }.joined(separator: "\n\n")
            : systemPrompt
        // Write prompt to file — send() treats \n as Enter, so inlining a multiline prompt breaks the command
        let hex = String(UUID().uuidString.filter { $0.isHexDigit }.prefix(6).lowercased())
        let launchersDir = NSHomeDirectory() + "/\(Srota.dir)/launchers"
        try? FileManager.default.createDirectory(atPath: launchersDir, withIntermediateDirectories: true)
        let promptFile = launchersDir + "/agent-prompt-\(hex).txt"
        try? promptContent.write(toFile: promptFile, atomically: true, encoding: .utf8)

        // ponytail: first message uses echo with basic escaping; use file approach if messages contain $vars/backticks
        let escapedFirst = firstMessage
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let cmd: String
        if flag.isEmpty {
            cmd = "__SROTA_SP=$(cat '\(promptFile)'); \(base) \"$__SROTA_SP\"\n"
        } else {
            cmd = firstMessage.isEmpty
                ? "__SROTA_SP=$(cat '\(promptFile)'); \(base) \(flag) \"$__SROTA_SP\"\n"
                : "__SROTA_SP=$(cat '\(promptFile)'); echo \"\(escapedFirst)\" | \(base) \(flag) \"$__SROTA_SP\"\n"
        }

        if agent.runInTempDir {
            let df = DateFormatter(); df.dateFormat = "yyyy_MM_dd"
            let dateStr = df.string(from: Date())
            let slug = agent.name.lowercased().replacingOccurrences(of: " ", with: "_")
            let sessionDir = NSHomeDirectory() + "/\(Srota.dir)/sessions/agents/\(slug)/\(dateStr)_\(hex)"
            try? FileManager.default.createDirectory(atPath: sessionDir, withIntermediateDirectories: true)

            struct Meta: Encodable {
                var agentName: String; var systemPrompt: String; var firstMessage: String
                var presetName: String?; var launchedAt: String
            }
            let meta = Meta(agentName: agent.name, systemPrompt: systemPrompt, firstMessage: firstMessage,
                            presetName: resolvedPreset?.name,
                            launchedAt: ISO8601DateFormatter().string(from: Date()))
            if let data = try? JSONEncoder().encode(meta) {
                try? data.write(to: URL(fileURLWithPath: sessionDir + "/agent.json"))
            }

            let displayDate = dateStr.replacingOccurrences(of: "_", with: "-")
            let wsName = "\(agent.name), \(displayDate), \(hex)"
            let folder = manager.folder(named: "Agents", tag: "agents")
            manager.addWorkspace(colorScheme: colorScheme, inFolder: folder.id,
                                 workingDirectory: sessionDir, name: wsName)
            saveLayout()
        } else {
            let cwd = resolveCWD(manager.selectedWorkspace?.selectedTab?.focusedViewState.workingDirectory)
                ?? manager.selectedWorkspace?.selectedTab?.statusPath
            manager.selectedWorkspace?.addTab(colorScheme: colorScheme, workingDirectory: cwd)
            manager.selectedWorkspace?.selectedTab?.customName = agent.name
            saveLayout()
        }

        // ponytail: fixed delay for shell init; replace with terminal-ready signal if flaky
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            manager.selectedWorkspace?.selectedTab?.focusedViewState.send(cmd)
        }
    }

    private func makeWorkspaceSwitcherModel() -> SwitcherModel {
        let folderNamesByWorkspaceID = Dictionary(
            uniqueKeysWithValues: manager.folders.flatMap { folder in
                folder.workspaces.map { ($0.id, folder.name) }
            }
        )
        let allWorkspaces = manager.allWorkspaces
        let switcherWorkspaces = allWorkspaces.map { ws in
            SwitcherWorkspace(
                id: ws.id,
                name: ws.name,
                folder: folderNamesByWorkspaceID[ws.id],
                tabs: ws.tabs.map { tab in
                    SwitcherTab(
                        id: tab.id,
                        title: tab.customName.isEmpty ? tab.titleFromCWD : tab.customName,
                        cwd: tab.statusPath,
                        panes: tab.panes.map { pane in
                            let paneCWD = resolveCWD(pane.viewState.workingDirectory) ?? pane.initialCWD
                            let paneName = tab.paneNames[pane.id].flatMap { $0.isEmpty ? nil : $0 }
                                ?? smartTitle(for: paneCWD)
                            return SwitcherPane(id: pane.id, name: paneName, cwd: paneCWD)
                        },
                        isSelected: tab.id == ws.selectedTabID
                    )
                },
                isSelected: ws.id == manager.selectedWorkspaceID,
                isPinned: ws.isPinned,
                isActive: ws.isActive
            )
        }
        return SwitcherModel(
            workspaceByID: Dictionary(uniqueKeysWithValues: switcherWorkspaces.map { ($0.id, $0) }),
            allWorkspaceIDs: switcherWorkspaces.map(\.id),
            activeWorkspaceIDs: switcherWorkspaces.filter(\.isActive).map(\.id),
            selectedWorkspaceID: manager.selectedWorkspaceID,
            selectedTabIDByWorkspaceID: Dictionary(uniqueKeysWithValues: allWorkspaces.compactMap { ws in
                ws.selectedTabID.map { (ws.id, $0) }
            }),
            selectedPaneIDByTabID: Dictionary(uniqueKeysWithValues: allWorkspaces.flatMap { ws in
                ws.tabs.map { ($0.id, $0.focusedPaneID) }
            })
        )
    }

    private func registerShortcutActions() {
        shortcuts.actions["c"] = { manager.selectedWorkspace?.addTab(colorScheme: .dark) }
        shortcuts.actions["x"] = {
            guard let ws = manager.selectedWorkspace, let tab = ws.selectedTab else { return }
            ws.closeTab(id: tab.id)
        }
        shortcuts.actions["n"] = { manager.selectedWorkspace?.selectNextTab() }
        shortcuts.actions["p"] = { manager.selectedWorkspace?.selectPrevTab() }
        for i in 1...9 {
            let idx = i - 1
            shortcuts.actions["\(i)"] = { manager.selectedWorkspace?.selectTab(at: idx) }
        }
        shortcuts.actions["s"] = {
            withAnimation(.easeInOut(duration: 0.15)) { shortcuts.showWorkspaceSwitcher = true }
        }
        shortcuts.actions["%"] = { manager.selectedWorkspace?.selectedTab?.splitRight(colorScheme: .dark); saveLayout() }
        shortcuts.actions["\""] = { manager.selectedWorkspace?.selectedTab?.splitBottom(colorScheme: .dark); saveLayout() }
        shortcuts.actions["h"] = {
            if sidebarKeyboardFocus { return }
            guard manager.selectedWorkspace?.selectedTab?.focusPane(direction: .left) != true else { return }
            enterSidebarKeyboardFocus()
        }
        shortcuts.actions["j"] = {
            guard !sidebarKeyboardFocus else {
                moveSidebarKeyboardHighlight(step: 1)
                return
            }
            manager.selectedWorkspace?.selectedTab?.focusPane(direction: .down)
        }
        shortcuts.actions["k"] = {
            guard !sidebarKeyboardFocus else {
                moveSidebarKeyboardHighlight(step: -1)
                return
            }
            manager.selectedWorkspace?.selectedTab?.focusPane(direction: .up)
        }
        shortcuts.actions["l"] = {
            guard !sidebarKeyboardFocus else {
                activateSidebarSelection()
                return
            }
            manager.selectedWorkspace?.selectedTab?.focusPane(direction: .right)
        }
        shortcuts.actions["g"] = {
            shortcuts.lazygitCWD = manager.selectedWorkspace?.selectedTab?.statusPath
            withAnimation(.easeInOut(duration: 0.15)) { shortcuts.showLazygit = true }
        }
        shortcuts.actions["d"] = {
            shortcuts.hunkCWD = manager.selectedWorkspace?.selectedTab?.statusPath
            withAnimation(.easeInOut(duration: 0.15)) { shortcuts.showHunk = true }
        }
        shortcuts.plainKeyHandler = { event in
            handleSidebarPlainKey(event)
        }
    }

    private var sidebarWorkspaceIDs: [UUID] {
        manager.allWorkspaces.map(\.id)
    }

    private func enterSidebarKeyboardFocus() {
        guard sidebarVisible else { return }
        let workspaceIDs = sidebarWorkspaceIDs
        guard !workspaceIDs.isEmpty else { return }
        sidebarReturnFocusState = manager.selectedWorkspace?.selectedTab?.focusedViewState
        sidebarHighlightedWorkspaceID = manager.selectedWorkspaceID ?? workspaceIDs.first
        sidebarKeyboardFocus = true
    }

    private func moveSidebarKeyboardHighlight(step: Int) {
        let workspaceIDs = sidebarWorkspaceIDs
        guard !workspaceIDs.isEmpty else { return }
        let currentID = sidebarHighlightedWorkspaceID ?? manager.selectedWorkspaceID ?? workspaceIDs[0]
        let currentIndex = workspaceIDs.firstIndex(of: currentID) ?? 0
        let nextIndex = min(max(currentIndex + step, 0), workspaceIDs.count - 1)
        sidebarHighlightedWorkspaceID = workspaceIDs[nextIndex]
    }

    private func activateSidebarSelection() {
        let workspaceIDs = sidebarWorkspaceIDs
        guard let workspaceID = sidebarHighlightedWorkspaceID ?? manager.selectedWorkspaceID ?? workspaceIDs.first else { return }
        sidebarKeyboardFocus = false
        sidebarHighlightedWorkspaceID = nil
        sidebarReturnFocusState = nil
        manager.selectWorkspace(id: workspaceID)
        DispatchQueue.main.async {
            guard let state = manager.selectedWorkspace?.selectedTab?.focusedViewState else { return }
            focusTerminalView(for: state)
        }
    }

    private func clearSidebarKeyboardFocus(restorePane: Bool = false) {
        let state = restorePane ? sidebarReturnFocusState : nil
        sidebarKeyboardFocus = false
        sidebarHighlightedWorkspaceID = nil
        sidebarReturnFocusState = nil
        guard restorePane, let state else { return }
        DispatchQueue.main.async {
            focusTerminalView(for: state)
        }
    }

    private func focusAgentPane(workspaceID: UUID, tabID: UUID, paneID: UUID) {
        guard let ws = manager.allWorkspaces.first(where: { $0.id == workspaceID }) else { return }
        manager.selectWorkspace(id: workspaceID)
        ws.selectedTabID = tabID
        if let tab = ws.tabs.first(where: { $0.id == tabID }), tab.panes.contains(where: { $0.id == paneID }) {
            tab.focusedPaneID = paneID
        }
        managementTab = .workspaces
    }

    private func handleSidebarPlainKey(_ event: NSEvent) -> Bool {
        guard sidebarKeyboardFocus else { return false }
        let modifiers = event.modifierFlags.intersection([.control, .command, .option, .shift])
        guard modifiers.isEmpty else { return false }
        switch event.keyCode {
        case 36, 76, 124:
            activateSidebarSelection()
            return true
        case 123:
            return true
        case 53:
            clearSidebarKeyboardFocus(restorePane: true)
            return true
        case 125:
            moveSidebarKeyboardHighlight(step: 1)
            return true
        case 126:
            moveSidebarKeyboardHighlight(step: -1)
            return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() ?? "" {
        case "j":
            moveSidebarKeyboardHighlight(step: 1)
            return true
        case "k":
            moveSidebarKeyboardHighlight(step: -1)
            return true
        case "l":
            activateSidebarSelection()
            return true
        case "h":
            return true
        default:
            return false
        }
    }

    private func saveLayout() {
        let allFolders  = manager.folders
        let unfiledWSes = manager.workspaces
        func save(ws: Workspace, folderName: String, folderTag: String, position: Int, folderPosition: Int) {
            db.saveWorkspaceSession(WorkspaceSession(
                id: ws.id.uuidString, name: ws.name,
                folderName: folderName, folderTag: folderTag, position: position,
                lastCWD: ws.currentWorkingDirectory ?? "",
                lastAccessed: Int(Date().timeIntervalSince1970),
                isPinned: ws.isPinned,
                directory: ws.directory,
                folderPosition: folderPosition))
            db.deleteTabs(workspaceID: ws.id.uuidString)
            for (ti, tab) in ws.tabs.enumerated() {
                db.saveTab(TabRecord(
                    id: tab.id.uuidString, workspaceID: ws.id.uuidString,
                    position: ti,
                    initialCWD: tab.initialWorkingDirectory ?? "",
                    isSelected: tab.id == ws.selectedTabID))
                for (i, pane) in tab.panes.enumerated() {
                    if let layout = tab.paneLayouts[pane.id] {
                        db.savePane(PaneRecord(
                            id: pane.daemonStableID, tabID: tab.id.uuidString,
                            isPrimary: i == 0,
                            lx: Double(layout.x), ly: Double(layout.y),
                            lw: Double(layout.w), lh: Double(layout.h),
                            initialCWD: resolveCWD(pane.viewState.workingDirectory) ?? pane.initialCWD ?? "",
                            position: i))
                    }
                }
            }
        }
        for (i, ws) in unfiledWSes.enumerated() { save(ws: ws, folderName: "", folderTag: "", position: i, folderPosition: -1) }
        for (fi, folder) in allFolders.enumerated() {
            for (i, ws) in folder.workspaces.enumerated() {
                save(ws: ws, folderName: folder.name, folderTag: folder.tag, position: i, folderPosition: fi)
            }
        }
    }

    private func restoreSessionsFromDB(colorScheme: ColorScheme) {
        manager.daemon = daemon
        let saved = db.loadWorkspaceSessions()
        guard !saved.isEmpty else { return }
        for session in saved {
            let folder = session.folderName.isEmpty
                ? nil
                : manager.folder(named: session.folderName, tag: session.folderTag)
            let wsID = UUID(uuidString: session.id) ?? UUID()
            let ws = Workspace(id: wsID, name: session.name)
            ws.daemon = daemon
            ws.isPinned = session.isPinned
            ws.directory = session.directory
            ws.lastAccessed = Date(timeIntervalSince1970: TimeInterval(session.lastAccessed))
            let cwd = session.lastCWD.isEmpty ? nil : session.lastCWD
            let tabs = db.loadTabs(workspaceID: session.id)
            if tabs.isEmpty {
                ws.addTab(colorScheme: colorScheme, workingDirectory: cwd)
            } else {
                for tabRecord in tabs.sorted(by: { $0.position < $1.position }) {
                    let sortedPanes = db.loadPanes(tabID: tabRecord.id)
                        .sorted(by: { $0.position < $1.position })
                    ws.addRestoredTab(record: tabRecord, colorScheme: colorScheme,
                                      firstPaneStableID: sortedPanes.first?.id)
                    if let tab = ws.tabs.last {
                        if let firstRecord = sortedPanes.first, !tab.panes.isEmpty {
                            tab.paneLayouts[tab.panes[0].id] = PaneLayout(
                                x: CGFloat(firstRecord.lx), y: CGFloat(firstRecord.ly),
                                w: CGFloat(firstRecord.lw), h: CGFloat(firstRecord.lh))
                            if firstRecord.lw == 0 || firstRecord.lh == 0 {
                                tab.removePane(id: tab.panes[0].id)
                            }
                        }
                        for record in sortedPanes.dropFirst() {
                            tab.restorePane(record: record, colorScheme: colorScheme)
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
    static let dotIdle        = Color(red: 0.24, green: 0.84, blue: 0.55)
    static let dotBlocked     = Color(red: 0.94, green: 0.31, blue: 0.31)
    static let dotDone        = Color(red: 0.31, green: 0.55, blue: 0.94)
    static let labelSecondary = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.45)
    static let sectionHeader  = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.28)
}

/// Liquid-glass card chrome: translucent fill + a top-to-bottom border gradient
/// that fakes the light bevel a real glass surface would catch.
extension View {
    func glassCard(fill: Color, borderTop: Color, borderBottom: Color, radius: CGFloat = 8) -> some View {
        self
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay(
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(LinearGradient(colors: [borderTop, borderBottom], startPoint: .top, endPoint: .bottom), lineWidth: 1)
            )
    }
}

extension AgentRunStatus {
    var color: Color {
        switch self {
        case .working: return .accentOrange
        case .idle: return .dotIdle
        case .blocked: return .dotBlocked
        case .done: return .dotDone
        }
    }
}

struct AgentStatusBadge: View {
    let status: AgentRunStatus

    var body: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(status.color)
                .frame(width: 6, height: 6)
            Text(status.label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(status.color)
                .lineLimit(1)
        }
    }
}

// MARK: - Agents list (shared by sidebar widget and the Agents tab)

// One row per pane (not per tab) — a split tab with two panes each running
// its own agent shows up as two separate agents here.
struct RunningAgent: Identifiable {
    let workspaceID: UUID
    let tabID: UUID
    let paneID: UUID
    let stableID: String
    let title: String
    let status: AgentRunStatus
    let agentName: String
    let updatedAt: Double
    var id: String { stableID }
}

func collectRunningAgents(_ manager: TerminalManager) -> [RunningAgent] {
    let states = manager.daemon?.agentStatesByStableID ?? [:]
    return manager.allWorkspaces
        .flatMap { ws in
            ws.tabs.flatMap { tab in
                tab.panes.compactMap { pane -> RunningAgent? in
                    guard let state = states[pane.daemonStableID],
                          let status = state.status else { return nil }
                    let paneCWD = resolveCWD(pane.viewState.workingDirectory) ?? pane.initialCWD
                    let title = tab.paneNames[pane.id].flatMap { $0.isEmpty ? nil : $0 }
                        ?? smartTitle(for: paneCWD)
                    return RunningAgent(
                        workspaceID: ws.id, tabID: tab.id, paneID: pane.id, stableID: pane.daemonStableID,
                        title: title, status: status, agentName: state.agent, updatedAt: state.updatedAt
                    )
                }
            }
        }
        .sorted { $0.updatedAt > $1.updatedAt }
}

struct AgentRow: View {
    let agent: RunningAgent
    let isWorkspaceOpen: Bool
    let folderName: String?
    let folderTag: String?
    let onSelect: () -> Void
    @State private var isHovered = false
    @State private var isPulsing = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(agent.status.color)
                    .frame(width: 28, height: 28)
                    .background(LinearGradient(colors: [agent.status.color.opacity(0.3), agent.status.color.opacity(0.15)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .clipShape(RoundedRectangle(cornerRadius: 7))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(agent.status.color.opacity(0.3), lineWidth: 1))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(agent.title)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(Color.labelPrimary.opacity(0.9))
                            .lineLimit(1)
                        if isWorkspaceOpen {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.accentOrange)
                        }
                    }
                    Text("\(agent.status.label.lowercased()) · \(agent.agentName)")
                        .font(.system(size: 10))
                        .foregroundStyle(agent.status.color)
                        .lineLimit(1)
                    if let folderName, !folderName.isEmpty {
                        HStack(spacing: 4) {
                            Text(folderName)
                            if let folderTag, !folderTag.isEmpty {
                                Text("· \(folderTag)")
                                    .truncationMode(.tail)
                            }
                        }
                        .font(.system(size: 10))
                        .foregroundStyle(Color.sectionHeader)
                        .lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                Circle()
                    .fill(agent.status.color)
                    .frame(width: 7, height: 7)
                    .shadow(color: agent.status.color.opacity(isPulsing ? 0.9 : 0.4), radius: isPulsing ? 6 : 2)
                    .onAppear {
                        withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                            isPulsing = true
                        }
                    }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(
            fill: agent.status.color.opacity(isHovered ? 0.12 : 0.08),
            borderTop: agent.status.color.opacity(0.38),
            borderBottom: agent.status.color.opacity(0.22)
        )
        .onHover { isHovered = $0 }
    }
}

private struct SidebarView: View {
    @ObservedObject var manager: TerminalManager
    let keyboardFocusedWorkspaceID: UUID?
    let onAdd: () -> Void
    let onSelectWorkspace: (UUID) -> Void
    let onSelectAgentTab: (UUID, UUID, UUID) -> Void
    let onShowAllAgents: () -> Void
    @State private var newFolderID: UUID? = nil
    @State private var isDragTargetUnfiled = false
    @State private var pinnedExpanded = true
    @State private var workspacesExpanded = true
    @State private var folderFrames: [UUID: CGRect] = [:]
    @State private var workspaceFrames: [UUID: WorkspaceFrameInfo] = [:]

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
                    .padding(.leading, 10)
                    .padding(.vertical, 8)
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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
                .help("New Folder")
            }
            .glassCard(fill: Color.white.opacity(0.04), borderTop: Color.white.opacity(0.14), borderBottom: Color.white.opacity(0.07))
            .padding(.horizontal, 8)
            .padding(.top, 10)
            .padding(.bottom, 6)

            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    if !manager.pinnedWorkspaces.isEmpty {
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: pinnedExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .medium))
                                .foregroundStyle(Color.sectionHeader)
                            Image(systemName: "pin.fill")
                                .font(.system(size: 9))
                                .foregroundStyle(Color.accentOrange.opacity(0.7))
                            Text("PINNED")
                                .font(.system(size: 11, weight: .medium))
                                .tracking(0.8)
                                .foregroundStyle(Color.sectionHeader)
                            Spacer()
                            Text("\(manager.pinnedWorkspaces.count)")
                                .font(.system(size: 11, weight: .regular).monospacedDigit())
                                .foregroundStyle(Color.sectionHeader.opacity(0.7))
                        }
                        .padding(.horizontal, 12)
                        .padding(.bottom, 5)
                        .contentShape(Rectangle())
                        .onTapGesture { pinnedExpanded.toggle() }

                        if pinnedExpanded {
                            ForEach(manager.pinnedWorkspaces) { ws in
                                PinnedWorkspaceCard(
                                    workspace: ws,
                                    manager: manager,
                                    isSelected: manager.selectedWorkspaceID == ws.id,
                                    onSelect: { onSelectWorkspace(ws.id) },
                                    onClose:  { manager.closeWorkspace(id: ws.id) },
                                    folderName: manager.folders.first { $0.workspaces.contains { $0.id == ws.id } }?.name,
                                    folderTag: manager.folders.first { $0.workspaces.contains { $0.id == ws.id } }?.tag
                                )
                            }
                        }
                    }

                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: workspacesExpanded ? "chevron.down" : "chevron.right")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.sectionHeader)
                        Text("WORKSPACES")
                            .font(.system(size: 11, weight: .medium))
                            .tracking(0.8)
                            .foregroundStyle(isDragTargetUnfiled ? Color.accentOrange : Color.sectionHeader)
                        Spacer()
                        Text("\(manager.allWorkspaces.count)")
                            .font(.system(size: 11, weight: .regular).monospacedDigit())
                            .foregroundStyle(Color.sectionHeader.opacity(0.7))
                    }
                    .padding(.horizontal, 12)
                    .padding(.bottom, 5)
                    .background(isDragTargetUnfiled ? Color.accentOrange.opacity(0.08) : Color.clear)
                    .contentShape(Rectangle())
                    .onTapGesture { workspacesExpanded.toggle() }
                    .onDrop(of: [.plainText], isTargeted: $isDragTargetUnfiled) { providers in
                        isDragTargetUnfiled = false
                        return dropWorkspace(providers, toFolder: nil, manager: manager)
                    }

                    if workspacesExpanded {
                        VStack(spacing: 5) {
                            let unfiled = manager.workspaces.filter { !$0.isPinned }
                            VStack(spacing: 5) {
                                ForEach(unfiled) { ws in
                                    WorkspaceSidebarItem(
                                        workspace: ws,
                                        manager: manager,
                                        isSelected: manager.selectedWorkspaceID == ws.id,
                                        isKeyboardFocused: keyboardFocusedWorkspaceID == ws.id,
                                        onSelect: { onSelectWorkspace(ws.id) },
                                        onClose:  { manager.closeWorkspace(id: ws.id) }
                                    )
                                    .background(GeometryReader { geo in
                                        Color.clear.preference(
                                            key: WorkspaceFramePreferenceKey.self,
                                            value: [ws.id: WorkspaceFrameInfo(frame: geo.frame(in: .named("sidebarDrag")), folderID: nil)])
                                    })
                                }
                            }
                            VStack(spacing: 5) {
                                ForEach(manager.folders) { folder in
                                    FolderRow(
                                        folder: folder,
                                        manager: manager,
                                        keyboardFocusedWorkspaceID: keyboardFocusedWorkspaceID,
                                        onSelectWorkspace: onSelectWorkspace,
                                        startRenaming: newFolderID == folder.id,
                                        onRenameHandled: { newFolderID = nil }
                                    )
                                    .background(GeometryReader { geo in
                                        Color.clear.preference(
                                            key: FolderFramePreferenceKey.self,
                                            value: [folder.id: geo.frame(in: .named("sidebarDrag"))])
                                    })
                                }
                            }
                        }
                        .padding(.top, 2)
                        .coordinateSpace(name: "sidebarDrag")
                        .onPreferenceChange(WorkspaceFramePreferenceKey.self) { workspaceFrames = $0 }
                        .onPreferenceChange(FolderFramePreferenceKey.self) { folderFrames = $0 }
                        .onDrop(of: [.plainText], delegate: SidebarReorderDropDelegate(
                            workspaceFrames: workspaceFrames, folderFrames: folderFrames, manager: manager))
                    }
                }
            }

            AgentsSidebarSection(manager: manager, onSelect: onSelectAgentTab, onShowAll: onShowAllAgents)

            Spacer(minLength: 0)
        }
        .frame(maxHeight: .infinity)
        .background(Color.sidebarBg)
    }
}

private struct AgentsSidebarSection: View {
    @ObservedObject var manager: TerminalManager
    let onSelect: (UUID, UUID, UUID) -> Void
    let onShowAll: () -> Void

    private static let cap = 5

    var body: some View {
        let agents = collectRunningAgents(manager)
        if !agents.isEmpty {
            VStack(spacing: 0) {
                Rectangle().fill(Color.white.opacity(0.07)).frame(height: 1)

                HStack {
                    Text("AGENTS")
                        .font(.system(size: 11, weight: .medium))
                        .tracking(0.8)
                        .foregroundStyle(Color.sectionHeader)
                    Spacer()
                    Button("All", action: onShowAll)
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.sectionHeader)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 1)
                        .glassCard(fill: Color.white.opacity(0.05), borderTop: Color.white.opacity(0.1), borderBottom: Color.white.opacity(0.06), radius: 4)
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

                VStack(spacing: 6) {
                    ForEach(agents.prefix(Self.cap)) { agent in
                        let folder = manager.folders.first { $0.workspaces.contains { $0.id == agent.workspaceID } }
                        AgentRow(
                            agent: agent,
                            isWorkspaceOpen: manager.selectedWorkspaceID == agent.workspaceID,
                            folderName: folder?.name,
                            folderTag: folder?.tag
                        ) {
                            onSelect(agent.workspaceID, agent.tabID, agent.paneID)
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 8)
            }
        }
    }
}

private struct FolderRow: View {
    @ObservedObject var folder: WorkspaceFolder
    @ObservedObject var manager: TerminalManager
    let keyboardFocusedWorkspaceID: UUID?
    let onSelectWorkspace: (UUID) -> Void
    let startRenaming: Bool
    let onRenameHandled: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovered    = false
    @State private var isRenaming   = false
    @State private var editText     = ""
    @FocusState private var fieldFocused: Bool

    private var isDropTarget: Bool { manager.reorderDropTargetID == folder.id }
    // A workspace drag hovering here means "file into this folder" (whole-header highlight);
    // a folder drag means "reorder" (insertion line) — both drive the same isDropTarget flag,
    // set by the single SidebarReorderDropDelegate on the sidebar's drag surface.
    private var isFilingTarget: Bool { isDropTarget && manager.draggedKind == .workspace }
    private var isReorderTarget: Bool { isDropTarget && manager.draggedKind == .folder }

    var body: some View {
        VStack(spacing: 0) {
            // Folder header row
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: folder.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.sectionHeader)
                        .frame(width: 10)
                    Image(systemName: isFilingTarget ? "folder.fill" : "folder")
                        .font(.system(size: 10))
                        .foregroundStyle(isFilingTarget ? Color.accentOrange : Color.labelSecondary)
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
                                .foregroundStyle(isFilingTarget ? Color.accentOrange : Color.labelSecondary)
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
                        Text("\(folder.workspaces.filter { !$0.isPinned }.count)")
                            .font(.system(size: 10).monospacedDigit())
                            .foregroundStyle(Color.sectionHeader.opacity(0.7))
                    }
                }
                .padding(.leading, 8)
                .padding(.trailing, 8)
                .padding(.vertical, 6)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture { if !isRenaming { folder.isExpanded.toggle() } }
            .onHover { isHovered = $0 }
            .onDrag { manager.draggedKind = .folder; return idProvider(folder.id) }
            .glassCard(
                fill: isFilingTarget ? Color.accentOrange.opacity(0.12) : isHovered ? Color.rowHover : Color.white.opacity(0.04),
                borderTop: isFilingTarget ? Color.accentOrange.opacity(0.5) : Color.white.opacity(0.1),
                borderBottom: isFilingTarget ? Color.accentOrange.opacity(0.5) : Color.white.opacity(0.06),
                radius: 7
            )
            .padding(.horizontal, 4)
            .contextMenu {
                Button("Rename") { beginRename() }
                Divider()
                if folder.workspaces.isEmpty {
                    Button("Delete Folder", role: .destructive) { manager.deleteFolder(id: folder.id) }
                }
            }

            if folder.isExpanded {
                let filed = folder.workspaces.filter { !$0.isPinned }
                VStack(spacing: 1) {
                    ForEach(filed) { ws in
                        WorkspaceSidebarItem(
                            workspace: ws,
                            manager: manager,
                            isSelected: manager.selectedWorkspaceID == ws.id,
                            isKeyboardFocused: keyboardFocusedWorkspaceID == ws.id,
                            onSelect: { onSelectWorkspace(ws.id) },
                            onClose:  { manager.closeWorkspace(id: ws.id) }
                        )
                        .background(GeometryReader { geo in
                            Color.clear.preference(
                                key: WorkspaceFramePreferenceKey.self,
                                value: [ws.id: WorkspaceFrameInfo(frame: geo.frame(in: .named("sidebarDrag")), folderID: folder.id)])
                        })
                    }
                }
                .padding(.leading, 12)
                .overlay(alignment: .leading) {
                    Rectangle().fill(Color.white.opacity(0.08)).frame(width: 1)
                        .padding(.leading, 16)
                }
                .padding(.top, 2)
            }
        }
        .overlay(alignment: manager.reorderDropEdge == .bottom ? .bottom : .top) {
            if isReorderTarget {
                Rectangle().fill(Color.accentOrange).frame(height: 2)
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

// Workspace and folder drags carry only a UUID string — kind discrimination lives on
// manager.draggedKind (set synchronously in the source row's .onDrag, before any destination
// can see the drag), not on the NSItemProvider. NSItemProvider.suggestedName looked like a
// valid synchronous "kind" marker but doesn't survive AppKit's actual pasteboard-mediated drag
// transfer (it's meant for file-promise naming), so every drop's kind check silently failed.
// A dedicated UTType per kind would be the idiomatic way to let `.onDrop(of:)` filter before
// any delegate runs, but that requires declaring the type in Info.plist, which this target
// doesn't have (GENERATE_INFOPLIST_FILE with no backing file) — upgrade path if that changes.
enum DragKind: Equatable { case workspace, folder }

private func idProvider(_ id: UUID) -> NSItemProvider {
    NSItemProvider(object: id.uuidString as NSString)
}

private func loadDraggedID(from providers: [NSItemProvider], _ completion: @escaping (UUID?) -> Void) {
    guard let provider = providers.first else { return completion(nil) }
    provider.loadObject(ofClass: NSString.self) { obj, _ in
        let id = (obj as? String).flatMap(UUID.init(uuidString:))
        DispatchQueue.main.async { completion(id) }
    }
}

private func dropWorkspace(_ providers: [NSItemProvider], toFolder folderID: UUID?, manager: TerminalManager) -> Bool {
    guard manager.draggedKind == .workspace else { return false }
    loadDraggedID(from: providers) { wsID in
        guard let wsID else { return }
        manager.moveWorkspace(id: wsID, toFolder: folderID)
    }
    return true
}

private struct WorkspaceFrameInfo: Equatable {
    var frame: CGRect
    var folderID: UUID?   // nil for unfiled
}

private struct WorkspaceFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: WorkspaceFrameInfo] = [:]
    static func reduce(value: inout [UUID: WorkspaceFrameInfo], nextValue: () -> [UUID: WorkspaceFrameInfo]) {
        value.merge(nextValue()) { $1 }
    }
}

private struct FolderFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Single delegate for the entire sidebar drag-reorder surface — unfiled workspaces, folders,
/// and workspaces nested inside an expanded folder. This used to be three separate onDrop
/// registrations at different nesting levels (one per workspace list, one for the folders
/// block); SwiftUI's onDrop regions don't compose reliably when nested — whichever
/// registration wins a hit-test claims the drag exclusively for its whole bounds, so a more
/// specific descendant region (a folder's own row list) could never receive its turn once an
/// ancestor already claimed the same screen area. Fixing that pairwise (which interaction wins)
/// only moved the bug around three times in a row. One delegate for the whole surface, resolving
/// the target itself from measured frames instead of leaning on SwiftUI's hit-testing, removes
/// the ambiguity structurally rather than patching each collision as it's found.
private struct SidebarReorderDropDelegate: DropDelegate {
    let workspaceFrames: [UUID: WorkspaceFrameInfo]
    let folderFrames: [UUID: CGRect]
    let manager: TerminalManager

    private func workspaceTarget(for location: CGPoint) -> (id: UUID, folderID: UUID?, edge: VerticalEdge)? {
        for (id, info) in workspaceFrames {
            guard info.frame.minY <= location.y, location.y < info.frame.maxY else { continue }
            let midY = info.frame.minY + info.frame.height / 2
            return (id, info.folderID, location.y < midY ? .top : .bottom)
        }
        return nil
    }

    private func folderTarget(for location: CGPoint) -> (id: UUID, edge: VerticalEdge)? {
        for (id, frame) in folderFrames {
            guard frame.minY <= location.y, location.y < frame.maxY else { continue }
            let midY = frame.minY + frame.height / 2
            return (id, location.y < midY ? .top : .bottom)
        }
        return nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        switch manager.draggedKind {
        case .workspace:
            if let wt = workspaceTarget(for: info.location) {
                manager.noteReorderDropUpdate(targetID: wt.id, edge: wt.edge)
            } else if let ft = folderTarget(for: info.location) {
                manager.noteReorderDropUpdate(targetID: ft.id, edge: nil)
            } else {
                manager.noteReorderDropUpdate(targetID: nil, edge: nil)
            }
        case .folder:
            let ft = folderTarget(for: info.location)
            manager.noteReorderDropUpdate(targetID: ft?.id, edge: ft?.edge)
        case nil:
            return nil
        }
        return DropProposal(operation: .move)
    }

    func dropExited(info: DropInfo) {
        manager.clearReorderDrop()
    }

    func performDrop(info: DropInfo) -> Bool {
        switch manager.draggedKind {
        case .workspace:
            // A specific row wins over the folder it lives in — a row is a strictly more
            // precise target than "somewhere in this folder", so it only falls back to filing
            // into the folder itself when the drop isn't over any specific row.
            let wt = workspaceTarget(for: info.location)
            let ft = wt == nil ? folderTarget(for: info.location) : nil
            manager.clearReorderDrop()
            loadDraggedID(from: info.itemProviders(for: [.plainText])) { wsID in
                guard let wsID else { return }
                if let wt, wt.id != wsID {
                    if wt.edge == .bottom {
                        manager.moveWorkspace(id: wsID, toFolder: wt.folderID, after: wt.id)
                    } else {
                        manager.moveWorkspace(id: wsID, toFolder: wt.folderID, before: wt.id)
                    }
                } else if let ft {
                    manager.moveWorkspace(id: wsID, toFolder: ft.id)
                }
            }
            return true
        case .folder:
            let ft = folderTarget(for: info.location)
            manager.clearReorderDrop()
            loadDraggedID(from: info.itemProviders(for: [.plainText])) { folderID in
                guard let folderID, let ft, ft.id != folderID else { return }
                if ft.edge == .bottom {
                    manager.moveFolder(id: folderID, after: ft.id)
                } else {
                    manager.moveFolder(id: folderID, before: ft.id)
                }
            }
            return true
        case nil:
            return false
        }
    }
}

private struct PinnedWorkspaceCard: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var manager: TerminalManager
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    var folderName: String? = nil
    var folderTag: String? = nil

    @Environment(WorkspaceDB.self) private var db
    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(workspace.name)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.labelPrimary)
                            .lineLimit(1)
                        if isSelected {
                            Image(systemName: "bolt.fill")
                                .font(.system(size: 10))
                                .foregroundStyle(Color.accentOrange)
                        }
                    }
                    HStack(spacing: 4) {
                        if let folderName, !folderName.isEmpty {
                            Text(folderName)
                        }
                        if let folderTag, !folderTag.isEmpty {
                            Text("· \(folderTag)")
                                .truncationMode(.tail)
                        }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(Color.sectionHeader)
                    .lineLimit(1)
                }

                Spacer(minLength: 4)

                if isHovered {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(Color.labelSecondary)
                    }
                    .buttonStyle(.plain)
                } else {
                    Text("\(workspace.tabs.count)")
                        .font(.system(size: 10).monospacedDigit())
                        .foregroundStyle(Color.sectionHeader.opacity(0.7))
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .glassCard(
            fill: isSelected ? Color.accentOrange.opacity(0.1) : Color.white.opacity(0.045),
            borderTop: isSelected ? Color.accentOrange.opacity(0.5) : Color.white.opacity(0.14),
            borderBottom: isSelected ? Color.accentOrange.opacity(0.3) : Color.white.opacity(0.07),
            radius: 10
        )
        .padding(.horizontal, 8)
        .padding(.bottom, 6)
        .onHover { isHovered = $0 }
        .contextMenu {
            Button("Unpin") {
                workspace.isPinned.toggle()
                db.toggleWorkspacePin(id: workspace.id.uuidString)
            }
            Divider()
            Button("Close Workspace", role: .destructive) { onClose() }
        }
    }
}

private struct WorkspaceRow: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var manager: TerminalManager
    let isSelected: Bool
    let isKeyboardFocused: Bool
    let onSelect: () -> Void
    let onClose: () -> Void
    var isExpanded: Bool? = nil
    var onToggleExpand: (() -> Void)? = nil

    @Environment(WorkspaceDB.self) private var db
    @State private var isHovered = false
    @State private var isRenaming = false
    @State private var editText = ""
    @FocusState private var fieldFocused: Bool

    private var isDropTarget: Bool { manager.reorderDropTargetID == workspace.id }

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

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Set Directory"
        let startPath = workspace.currentWorkingDirectory ?? (workspace.directory.isEmpty ? nil : workspace.directory)
        if let p = startPath { panel.directoryURL = URL(fileURLWithPath: p) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.directory = url.path
        db.updateWorkspaceDirectory(id: workspace.id.uuidString, directory: url.path)
    }

    private var currentFolderID: UUID? {
        manager.folders.first { $0.workspaces.contains { $0.id == workspace.id } }?.id
    }

    var body: some View {
        HStack(spacing: 9) {
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
                HStack(spacing: 4) {
                    Text(workspace.name)
                        .font(.system(size: 13, weight: isSelected ? .medium : .regular))
                        .foregroundStyle(isSelected ? Color.labelPrimary : Color.labelSecondary)
                        .lineLimit(1)
                    if workspace.isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(Color.accentOrange.opacity(0.7))
                    }
                }
            }

            Spacer(minLength: 4)

            if let expanded = isExpanded, let toggle = onToggleExpand {
                Button(action: toggle) {
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(Color.sectionHeader)
                }
                .buttonStyle(.plain)
            } else if isHovered && !isRenaming {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Color.labelSecondary)
                }
                .buttonStyle(.plain)
            } else {
                Text("\(workspace.tabs.count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(Color.sectionHeader.opacity(0.7))
            }
        }
        .padding(.leading, 8)
        .padding(.trailing, 8)
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(isDropTarget ? Color.accentOrange.opacity(0.15) : isSelected ? Color.rowSelected : isKeyboardFocused ? Color.accentOrange.opacity(0.12) : isHovered ? Color.rowHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .stroke(isDropTarget ? Color.accentOrange.opacity(0.6) : isSelected ? Color.accentOrange.opacity(0.5) : isKeyboardFocused ? Color.accentOrange.opacity(0.55) : Color.clear, lineWidth: 1)
        )
        .overlay(alignment: manager.reorderDropEdge == .bottom ? .bottom : .top) {
            if isDropTarget {
                Rectangle().fill(Color.accentOrange).frame(height: 2)
            }
        }
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture { if !isRenaming { onSelect() } }
        .onHover { isHovered = $0 }
        .onDrag { manager.draggedKind = .workspace; return idProvider(workspace.id) }
        .contextMenu {
            Button(workspace.isPinned ? "Unpin" : "Pin") {
                workspace.isPinned.toggle()
                db.toggleWorkspacePin(id: workspace.id.uuidString)
            }
            Divider()
            Button("Rename") { startRename() }
            Button(workspace.directory.isEmpty ? "Set Directory…" : "Change Directory…") {
                pickDirectory()
            }

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

private struct WorkspaceSidebarItem: View {
    @ObservedObject var workspace: Workspace
    @ObservedObject var manager: TerminalManager
    let isSelected: Bool
    let isKeyboardFocused: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        WorkspaceRow(
            workspace: workspace,
            manager: manager,
            isSelected: isSelected,
            isKeyboardFocused: isKeyboardFocused,
            onSelect: onSelect,
            onClose: onClose,
            isExpanded: nil,
            onToggleExpand: nil
        )
    }
}

// MARK: - Tab bar

private struct TabBarView: View {
    @ObservedObject var workspace: Workspace
    let colorScheme: ColorScheme
    @Binding var sidebarVisible: Bool
    var onUserInteraction: () -> Void = {}
    var onMutation: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            Button(action: {
                onUserInteraction()
                sidebarVisible.toggle()
            }) {
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
                        onSelect: {
                            onUserInteraction()
                            workspace.selectedTabID = tab.id
                        },
                            onClose:  { workspace.closeTab(id: tab.id) }
                        )
                    }

                Button(action: {
                    onUserInteraction()
                    workspace.addTab(colorScheme: colorScheme, workingDirectory: workspace.currentWorkingDirectory)
                    onMutation()
                }) {
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
                                active: tab.panes.count > 1) {
                        tab.splitRight(colorScheme: colorScheme); onMutation()
                    }
                    SplitButton(icon: "rectangle.split.1x2", tooltip: "Split Bottom",
                                active: tab.panes.count > 1) {
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
    let onPaneActivated: () -> Void
    let onPaneResizeFinished: () -> Void

    var body: some View {
        ForEach(workspace.tabs) { tab in
            let isSelected = workspace.id == selectedWorkspaceID && tab.id == workspace.selectedTabID
        TerminalContentView(tab: tab, isSelected: isSelected, onPaneActivated: onPaneActivated, onPaneResizeFinished: onPaneResizeFinished)
                .opacity(isSelected ? 1 : 0)
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

 Spacer(minLength: 0)
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
        .glassCard(
            fill: isActive ? Color.accentOrange.opacity(0.1) : (isHovered ? Color.tabHoverBg : Color.clear),
            borderTop: isActive ? Color.accentOrange.opacity(0.45) : Color.clear,
            borderBottom: isActive ? Color.accentOrange.opacity(0.25) : Color.clear,
            radius: 6
        )
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

// MARK: - Pane resize overlay

private final class PaneResizingView: NSView {
    var tab: TerminalTab
    var onResizeFinished: () -> Void

    private let hitZone: CGFloat = 5
    private var dragIsVertical: Bool? = nil
    private var dragStartPos: CGPoint = .zero
    private var dragNegRefs: [UUID] = []
    private var dragPosRefs: [UUID] = []
    private var dragStartLayouts: [(UUID, PaneLayout)] = []
    private var showingResizeCursor = false

    init(tab: TerminalTab, onResizeFinished: @escaping () -> Void) {
        self.tab = tab
        self.onResizeFinished = onResizeFinished
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.activeInActiveApp, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        edgeNear(point) != nil ? self : nil
    }

    private func edgeNear(_ p: CGPoint) -> (Bool, [UUID], [UUID])? {
        let sz = bounds.size
        guard sz.width > 0, sz.height > 0 else { return nil }
        let eps: CGFloat = 0.005
        let all = allPanes()
        for (_, l) in all {
            let ex = l.x + l.w
            if ex > eps && ex < 1 - eps, abs(p.x - sz.width * ex) < hitZone {
                let py = p.y / sz.height
                // Validate cursor is inside an actual shared-edge segment at this y
                let negAtY = all.filter { abs($0.1.x + $0.1.w - ex) < eps && py >= $0.1.y && py <= $0.1.y + $0.1.h }
                let posAtY = all.filter { abs($0.1.x - ex) < eps         && py >= $0.1.y && py <= $0.1.y + $0.1.h }
                if !negAtY.isEmpty && !posAtY.isEmpty {
                    // Move ALL panes sharing this edge so the full divider stays straight
                    let neg = all.filter { abs($0.1.x + $0.1.w - ex) < eps }.map(\.0)
                    let pos = all.filter { abs($0.1.x - ex) < eps }.map(\.0)
                    return (true, neg, pos)
                }
            }
            let ey = l.y + l.h
            if ey > eps && ey < 1 - eps, abs(p.y - sz.height * ey) < hitZone {
                let px = p.x / sz.width
                let negAtX = all.filter { abs($0.1.y + $0.1.h - ey) < eps && px >= $0.1.x && px <= $0.1.x + $0.1.w }
                let posAtX = all.filter { abs($0.1.y - ey) < eps          && px >= $0.1.x && px <= $0.1.x + $0.1.w }
                if !negAtX.isEmpty && !posAtX.isEmpty {
                    let neg = all.filter { abs($0.1.y + $0.1.h - ey) < eps }.map(\.0)
                    let pos = all.filter { abs($0.1.y - ey) < eps }.map(\.0)
                    return (false, neg, pos)
                }
            }
        }
        return nil
    }

    override func mouseMoved(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        if let (isV, _, _) = edgeNear(p) {
            if !showingResizeCursor {
                (isV ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                showingResizeCursor = true
            }
        } else if showingResizeCursor {
            NSCursor.pop()
            showingResizeCursor = false
        }
    }

    override func mouseExited(with event: NSEvent) {
        if showingResizeCursor {
            NSCursor.pop()
            showingResizeCursor = false
        }
    }

    override func mouseDown(with event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        guard let (isV, neg, pos) = edgeNear(p) else { return }
        if showingResizeCursor {
            NSCursor.pop()
            showingResizeCursor = false
        }
        dragIsVertical   = isV
        dragStartPos     = p
        dragNegRefs      = neg
        dragPosRefs      = pos
        dragStartLayouts = (neg + pos).map { ($0, currentLayout($0)) }
        (isV ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let isV = dragIsVertical else { return }
        let p  = convert(event.locationInWindow, from: nil)
        let sz = bounds.size
        let translation = isV ? (p.x - dragStartPos.x) / sz.width
                              : (p.y - dragStartPos.y) / sz.height
        let startSizes = dragStartLayouts.map { isV ? $0.1.w : $0.1.h }
        let negIndices = Set(dragStartLayouts.enumerated().compactMap { dragNegRefs.contains($0.element.0) ? $0.offset : nil })
        guard let delta = PaneResizeLogic.clampedDelta(startSizes: startSizes, negativeIndices: negIndices, translation: translation) else { return }
        for (ref, sl) in dragStartLayouts {
            var l = sl
            if dragNegRefs.contains(ref) {
                if isV { l.w = sl.w + delta } else { l.h = sl.h + delta }
            } else {
                if isV { l.x = sl.x + delta; l.w = sl.w - delta }
                else   { l.y = sl.y + delta; l.h = sl.h - delta }
            }
            setLayout(l, for: ref)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard dragIsVertical != nil else { return }
        NSCursor.pop()
        dragIsVertical   = nil
        dragStartLayouts = []
        dragNegRefs      = []
        dragPosRefs      = []
        onResizeFinished()
    }

    private func allPanes() -> [(UUID, PaneLayout)] {
        tab.panes.compactMap { e in tab.paneLayouts[e.id].map { (e.id, $0) } }
    }

    private func currentLayout(_ id: UUID) -> PaneLayout {
        tab.paneLayouts[id] ?? PaneLayout()
    }

    private func setLayout(_ l: PaneLayout, for id: UUID) {
        tab.paneLayouts[id] = l
    }
}

private struct PaneResizeOverlay: NSViewRepresentable {
    @ObservedObject var tab: TerminalTab
    let onResizeFinished: () -> Void
    func makeNSView(context: Context) -> PaneResizingView { PaneResizingView(tab: tab, onResizeFinished: onResizeFinished) }
    func updateNSView(_ v: PaneResizingView, context: Context) { v.tab = tab; v.onResizeFinished = onResizeFinished }
}

// MARK: - Terminal content (split-aware)
// Primary is always ZStack child 0. Named coordinate space "panes" lets drag gestures
// report absolute positions — no manual offset math needed.

struct PaneStartOverlay: View {
    let cwd: String?
    var label: String = "Start"
    let onStart: () -> Void

    var body: some View {
        ZStack {
            Color.black.opacity(0.88)
            VStack(spacing: 14) {
                Image(systemName: "terminal")
                    .font(.system(size: 28))
                    .foregroundStyle(Color.labelMuted)
                if let cwd, !cwd.isEmpty {
                    Text(URL(fileURLWithPath: cwd).lastPathComponent)
                        .font(.system(size: 12).monospaced())
                        .foregroundStyle(Color.labelMuted)
                        .lineLimit(1)
                }
                Button(action: onStart) {
                    Text(label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Color.labelPrimary)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 7)
                        .background(Color.accentOrange.opacity(0.15))
                        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.accentOrange.opacity(0.45)))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
        }
        .ignoresSafeArea()
    }
}

private struct TerminalContentView: View {
    @Environment(DaemonConnection.self) private var daemon
    @ObservedObject var tab: TerminalTab
    var isSelected: Bool = false
    let onPaneActivated: () -> Void
    let onPaneResizeFinished: () -> Void
    @State private var isDragging  = false
    @State private var dragSource: UUID? = nil
    @State private var dragHover:  UUID? = nil
    @State private var dropSide:   DropSide? = nil

    var body: some View {
        GeometryReader { geo in
            let sz = geo.size

            ZStack(alignment: .topLeading) {
                ForEach(tab.panes) { entry in
                    if let l = tab.paneLayouts[entry.id] {
                        paneView(
                            entry: entry, layout: l,
                            onClose: { tab.removePane(id: entry.id); onPaneResizeFinished() },
                            sz: sz,
                            focused: tab.focusedPaneID == entry.id
                        )
            .simultaneousGesture(TapGesture().onEnded {
                onPaneActivated()
                tab.focusedPaneID = entry.id
            })
                        .onAppear {
                            if tab.focusedPaneID == entry.id && entry.isStarted {
                                requestKeyboardFocus(for: entry.viewState)
                            }
                        }
                    }
                }

                ForEach(Array(dividerSegments().enumerated()), id: \.offset) { _, seg in
                    if seg.isVertical {
                        Rectangle().fill(Color.white.opacity(0.1))
                            .frame(width: 1, height: sz.height * (seg.to - seg.from))
                            .offset(x: sz.width * seg.at - 0.5, y: sz.height * seg.from)
                            .allowsHitTesting(false)
                    } else {
                        Rectangle().fill(Color.white.opacity(0.1))
                            .frame(width: sz.width * (seg.to - seg.from), height: 1)
                            .offset(x: sz.width * seg.from, y: sz.height * seg.at - 0.5)
                            .allowsHitTesting(false)
                    }
                }

                PaneResizeOverlay(tab: tab, onResizeFinished: onPaneResizeFinished)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .coordinateSpace(name: "panes")
            .onChange(of: tab.focusedPaneID) { _, newID in
                if let entry = tab.panes.first(where: { $0.id == newID }), entry.isStarted {
                    requestKeyboardFocus(for: entry.viewState)
                }
            }
            .onChange(of: isSelected) { _, selected in
                guard selected, let entry = tab.panes.first(where: { $0.id == tab.focusedPaneID }), entry.isStarted else { return }
                requestKeyboardFocus(for: entry.viewState)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func paneView(entry: PaneEntry,
                          layout l: PaneLayout, onClose: @escaping () -> Void,
                          sz: CGSize, focused: Bool) -> some View {
        let id = entry.id
        let state = entry.viewState
        let isSource = isDragging && dragSource == id
        let isTarget = isDragging && dragHover  == id && dragSource != id

        ZStack(alignment: .top) {
            Color.black
            TerminalSurfaceView(context: state)
                .padding(.top, 30)
                .opacity(isSource ? 0.45 : 1)
            if !entry.isStarted {
                PaneStartOverlay(cwd: entry.initialCWD, label: entry.wasStolen ? "Use Here" : "Start") {
                    entry.startAction?()
                    entry.isStarted = true
                    // The pane's SwiftUI frame doesn't change just because it becomes visible
                    // again, so the terminal never re-measures and the daemon gets whatever
                    // rows/cols were buffered from the original (possibly stale) layout pass.
                    // Nudging the fractional layout forces a real frame change, same as manually
                    // dragging the pane divider does to "fix" this.
                    nudgeLayout(for: id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                        requestKeyboardFocus(for: entry.viewState)
                    }
                }
                .padding(.top, 30)
            }
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
            ReactivePaneHeader(
                state: state,
                customName: tab.paneNames[id] ?? "",
                focused: focused,
                showClose: true,
                status: daemon.agentStatesByStableID[entry.daemonStableID]?.status,
                onClose: onClose,
                onRename: { tab.rename(id: id, to: $0) },
                onDragChanged: { loc in
                    isDragging = true
                    dragSource = id
                    let h = paneAt(loc, in: sz)
                    if let h = h, h != id {
                        dragHover = h
                        dropSide  = sideOf(loc, paneID: h, in: sz)
                    } else {
                        dragHover = nil
                        dropSide  = nil
                    }
                },
                onDragEnded: { loc in
                    let t = paneAt(loc, in: sz)
                    if let t = t, t != id {
                        if let side = dropSide { tab.performDrop(source: id, target: t, side: side) }
                        else                   { tab.swapLayouts(id, t) }
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

    private func nudgeLayout(for id: UUID) {
        guard let current = tab.paneLayouts[id] else { return }
        var nudged = current
        nudged.w *= 0.999
        tab.paneLayouts[id] = nudged
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            tab.paneLayouts[id] = current
        }
    }

    private func paneAt(_ p: CGPoint, in sz: CGSize) -> UUID? {
        for entry in tab.panes.reversed() {
            if let l = tab.paneLayouts[entry.id],
               CGRect(x: sz.width * l.x, y: sz.height * l.y,
                      width: sz.width * l.w, height: sz.height * l.h).contains(p) {
                return entry.id
            }
        }
        return nil
    }

    private func sideOf(_ p: CGPoint, paneID: UUID, in sz: CGSize) -> DropSide? {
        guard let l = tab.paneLayouts[paneID] else { return nil }
        let cx = sz.width  * (l.x + l.w / 2)
        let cy = sz.height * (l.y + l.h / 2)
        let dx = abs(p.x - cx) / (sz.width  * l.w)
        let dy = abs(p.y - cy) / (sz.height * l.h)
        if dx > dy { return p.x < cx ? .left : .right }
        return p.y < cy ? .top : .bottom
    }

    private func requestKeyboardFocus(for state: TerminalViewState) {
        DispatchQueue.main.async {
            guard let window = NSApp.keyWindow, let root = window.contentView else { return }
            if let tv = Self.findTerminalView(for: state, in: root) {
                Self.configureTerminalView(tv)
                window.makeFirstResponder(tv)
            }
        }
    }

    private static func configureTerminalView(_ view: NSView) {
        // ponytail: Ghostty's AppKit layer is transparent; make it opaque so cleared cells don't show stale glyphs.
        view.layer?.isOpaque = true
        view.layer?.backgroundColor = NSColor.black.cgColor
    }

    private static func findTerminalView(for state: TerminalViewState, in view: NSView) -> NSView? {
        if let v = view as? TerminalView,
           let del = v.delegate,
           ObjectIdentifier(del) == ObjectIdentifier(state) { return v }
        for sub in view.subviews {
            if let found = findTerminalView(for: state, in: sub) { return found }
        }
        return nil
    }

    private struct DividerSegment { let isVertical: Bool; let at: CGFloat; let from: CGFloat; let to: CGFloat }

    private func dividerSegments() -> [DividerSegment] {
        let all = tab.panes.compactMap { e in tab.paneLayouts[e.id].map { (e.id, $0) } }
        let eps: CGFloat = 0.005
        var vSeen = Set<String>(), hSeen = Set<String>()
        var result: [DividerSegment] = []
        for (_, l) in all {
            let ex = l.x + l.w
            if ex > eps && ex < 1 - eps, vSeen.insert(String(format: "%.4f", ex)).inserted {
                let neg = all.filter { abs($0.1.x + $0.1.w - ex) < eps }.map(\.1)
                let pos = all.filter { abs($0.1.x - ex) < eps }.map(\.1)
                for nl in neg { for pl in pos {
                    let f = Swift.max(nl.y, pl.y), t = Swift.min(nl.y + nl.h, pl.y + pl.h)
                    if t > f + eps { result.append(.init(isVertical: true,  at: ex, from: f, to: t)) }
                }}
            }
            let ey = l.y + l.h
            if ey > eps && ey < 1 - eps, hSeen.insert(String(format: "%.4f", ey)).inserted {
                let neg = all.filter { abs($0.1.y + $0.1.h - ey) < eps }.map(\.1)
                let pos = all.filter { abs($0.1.y - ey) < eps }.map(\.1)
                for nl in neg { for pl in pos {
                    let f = Swift.max(nl.x, pl.x), t = Swift.min(nl.x + nl.w, pl.x + pl.w)
                    if t > f + eps { result.append(.init(isVertical: false, at: ey, from: f, to: t)) }
                }}
            }
        }
        return result
    }
}

/// Wraps PaneHeader, observing TerminalViewState so the title reacts to CWD changes.
private struct ReactivePaneHeader: View {
    @ObservedObject var state: TerminalViewState
    let customName: String
    let focused: Bool
    let showClose: Bool
    let status: AgentRunStatus?
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded:   (CGPoint) -> Void

    var body: some View {
        let cwd = resolveCWD(state.workingDirectory)
        let title = customName.isEmpty ? smartTitle(for: cwd) : customName
        PaneHeader(
            title: title,
            cwd: cwd,
            focused: focused,
            showClose: showClose,
            status: status,
            onClose: onClose,
            onRename: onRename,
            onDragChanged: onDragChanged,
            onDragEnded: onDragEnded
        )
    }
}

private struct PaneHeader: View {
    let title: String
    let cwd: String?
    let focused: Bool
    let showClose: Bool
    let status: AgentRunStatus?
    let onClose: () -> Void
    let onRename: (String) -> Void
    let onDragChanged: (CGPoint) -> Void
    let onDragEnded:   (CGPoint) -> Void

    @Environment(EditorsStore.self) private var editorsStore
    @State private var isHovered  = false
    @State private var isRenaming = false
    @State private var editText   = ""
    @State private var issuePopoverOpen = false
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

                if let status {
                    AgentStatusBadge(status: status)
                }

                Spacer(minLength: 0)

                if !isRenaming {
                    PaneIssueButton(cwd: cwd, isOpen: $issuePopoverOpen)
                        .opacity(isHovered || issuePopoverOpen ? 1 : 0)
                }

                if let defaultEditor = editorsStore.defaultEditor, !isRenaming {
                    HStack(spacing: 3) {
                        Button {
                            if let cwd { editorsStore.open(defaultEditor, at: cwd) }
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "arrow.up.forward.app")
                                    .font(.system(size: 9.5))
                                Text(defaultEditor.name.isEmpty ? defaultEditor.command : defaultEditor.name)
                                    .font(.system(size: 11))
                                    .lineLimit(1)
                            }
                            .foregroundStyle(Color.labelMuted)
                            .frame(height: 14)
                        }
                        .buttonStyle(.plain)
                        .help("Open in \(defaultEditor.name.isEmpty ? defaultEditor.command : defaultEditor.name)")

                        if editorsStore.editors.count > 1 {
                            Menu {
                                ForEach(editorsStore.editors) { editor in
                                    Button {
                                        if let cwd { editorsStore.open(editor, at: cwd) }
                                    } label: {
                                        if editor.id == defaultEditor.id {
                                            Label(editor.name.isEmpty ? editor.command : editor.name, systemImage: "checkmark")
                                        } else {
                                            Text(editor.name.isEmpty ? editor.command : editor.name)
                                        }
                                    }
                                }
                            } label: {
                                Image(systemName: "chevron.down")
                                    .font(.system(size: 9.5))
                                    .foregroundStyle(Color.labelMuted)
                                    .frame(width: 10, height: 14)
                            }
                            .menuStyle(.button)
                            .buttonStyle(.plain)
                            .menuIndicator(.hidden)
                            .fixedSize()
                        }
                    }
                    .disabled(cwd == nil)
                    .opacity(isHovered || issuePopoverOpen ? 1 : 0)
                }

                if showClose && !isRenaming {
                    Button(action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 8.5, weight: .semibold))
                            .foregroundStyle(Color.labelMuted)
                            .frame(width: 14, height: 14)
                    }
                    .buttonStyle(.plain)
                    .opacity(isHovered || issuePopoverOpen ? 1 : 0)
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

// isOpen is a binding owned by PaneHeader (not local state) so PaneHeader can keep this
// button — and the other header icons — visible together while the popover is open;
// otherwise the moment the mouse leaves the header for the popover, everything but this
// button would vanish, or vice versa, leaving a lone icon with a detached-looking popover.
// Each pane can be on a different directory/branch, so detection runs against this
// pane's own live `cwd`, not the workspace's. Ephemeral — no DB persistence.
private struct PaneIssueButton: View {
    let cwd: String?
    @Binding var isOpen: Bool
    @State private var issueNumber: Int? = nil
    @State private var repoPath: String = ""
    @State private var statusMessage: String? = nil

    var body: some View {
        Button(action: toggle) {
            Image(systemName: "exclamationmark.circle")
                .font(.system(size: 10.5))
                .foregroundStyle(isOpen ? Color.accentOrange : Color.labelMuted)
                .frame(width: 14, height: 14)
        }
        .buttonStyle(.plain)
        .disabled(cwd == nil)
        .help("Open issue for this pane's branch")
        .popover(isPresented: $isOpen, arrowEdge: .bottom) {
            let windowSize = NSApp.keyWindow?.frame.size ?? CGSize(width: 640, height: 550)
            let popoverSize = CGSize(width: windowSize.width * 0.5, height: windowSize.height * 0.8)
            if let issueNumber {
                GitHubIssueSidebar(issueNumber: issueNumber, repoPath: repoPath) { isOpen = false }
                    .frame(width: popoverSize.width, height: popoverSize.height)
            } else {
                Text(statusMessage ?? "Checking…")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(width: popoverSize.width, height: popoverSize.height)
                    .padding(12)
            }
        }
    }

    private func toggle() {
        issueNumber = nil
        statusMessage = "Checking…"
        isOpen = true
        Task { await detectIssue() }
    }

    private func detectIssue() async {
        guard let path = cwd, !path.isEmpty else {
            statusMessage = "Issue not found"
            return
        }
        let branch = await Task.detached { runGit(["-C", path, "rev-parse", "--abbrev-ref", "HEAD"]) }.value
        guard let branch, let number = extractIssueNumber(fromBranch: branch) else {
            statusMessage = "Issue not found"
            return
        }
        repoPath = path
        issueNumber = number
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

// MARK: - Lazygit overlay

private func focusTerminalView(for state: TerminalViewState) {
    guard let window = NSApp.keyWindow, let root = window.contentView else { return }
    func find(_ v: NSView) -> NSView? {
        if let tv = v as? TerminalView,
           let del = tv.delegate,
           ObjectIdentifier(del) == ObjectIdentifier(state) { return tv }
        for sub in v.subviews { if let f = find(sub) { return f } }
        return nil
    }
    if let tv = find(root) { window.makeFirstResponder(tv) }
}

private final class LazygitState: ObservableObject {
    let viewState: TerminalViewState
    init(cwd: String?, launcherPath: String) {
        let config = TerminalConfiguration(configure: { b in b.withCustom("command", launcherPath) })
        viewState = TerminalViewState(terminalConfiguration: config)
        viewState.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: cwd)
        viewState.controller.setColorScheme(.dark)
    }
}

private struct LazygitOverlay: View {
    let cwd: String?
    let title: String
    let icon: String
    let launcherPath: String
    let onDismiss: () -> Void
    @StateObject private var lazygit: LazygitState

    init(cwd: String?, title: String = "lazygit", icon: String = "arrow.triangle.branch", launcherPath: String, onDismiss: @escaping () -> Void) {
        self.cwd = cwd
        self.title = title
        self.icon = icon
        self.launcherPath = launcherPath
        self.onDismiss = onDismiss
        _lazygit = StateObject(wrappedValue: LazygitState(cwd: cwd, launcherPath: launcherPath))
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.65)
                .ignoresSafeArea()
                .onTapGesture { onDismiss() }

            GeometryReader { geo in
                VStack(spacing: 0) {
                    HStack(spacing: 8) {
                        Image(systemName: icon)
                            .font(.system(size: 10))
                            .foregroundStyle(Color.accentOrange)
                        Text(title)
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .foregroundStyle(Color.labelPrimary)
                        if let cwd {
                            Text(cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(Color.labelMuted)
                                .lineLimit(1)
                                .truncationMode(.head)
                        }
                        Spacer()
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(Color.labelMuted)
                                .frame(width: 14, height: 14)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Color.tabBarBg)
                    .overlay(alignment: .bottom) {
                        Rectangle().fill(Color.accentOrange.opacity(0.5)).frame(height: 1)
                    }

                    TerminalSurfaceView(context: lazygit.viewState)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(width: geo.size.width * 0.9, height: geo.size.height * 0.9)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentOrange.opacity(0.2)))
                .shadow(color: .black.opacity(0.7), radius: 40, y: 12)
                .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .onAppear {
            lazygit.viewState.onClose = { _ in onDismiss() }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { focusTerminal() }
        }
    }

    private func focusTerminal() {
        focusTerminalView(for: lazygit.viewState)
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
