# Unified Pane Model Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the primary/secondary pane distinction — all panes live in `[PaneEntry]`, first is index 0, tab closes when empty.

**Architecture:** `TerminalTab` loses `viewState`/`primaryLayout`/`primaryExited`/`secondaryPanes`/`layouts` and gains `panes: [PaneEntry]` + `paneLayouts: [UUID: PaneLayout]`. `PaneRef` enum is deleted; all call sites use `UUID` directly. `focusedPaneID` becomes non-optional `UUID`.

**Tech Stack:** Swift, SwiftUI, AppKit, SQLite3 (via WorkspaceDB).

## Global Constraints

- `@MainActor` isolation on `TerminalTab` and `Workspace` — no DispatchQueue escaping.
- SQLite ALTER TABLE only adds columns (no DROP COLUMN needed — leave `is_primary` in schema, add `position`).
- `PaneEntry` struct unchanged — `id: UUID`, `hookPaneID: String`, `viewState: TerminalViewState`, `initialCWD: String?`.
- `PaneLayout` struct unchanged — `x, y, w, h: CGFloat`, defaults `(0,0,1,1)`.
- Build target: macOS, Xcode Swift package — no test runner, verify by building with `xcodebuild`.

---

### Task 1: WorkspaceDB — add `position` to ws_panes

**Files:**
- Modify: `srota/srota/WorkspaceDB.swift`

**Interfaces:**
- Produces: `PaneRecord` gains `position: Int`; `savePane(_:)` saves position; `loadPanes(tabID:)` returns sorted by position; `migratePanesIfNeeded()` called from `init`.

- [ ] **Step 1: Add `position` to `PaneRecord`**

In `WorkspaceDB.swift`, change the struct at line ~30:

```swift
struct PaneRecord: Identifiable {
    var id: String
    var tabID: String
    var isPrimary: Bool      // kept for legacy migration read
    var position: Int        // new: order in panes array
    var lx, ly, lw, lh: Double
    var initialCWD: String
}
```

- [ ] **Step 2: Add migration method**

After the `init` schema setup block (around line 410), add:

```swift
private func migratePanesIfNeeded() {
    // Add position column if missing (SQLite 3.x safe — no DROP COLUMN needed)
    let cols = rows("PRAGMA table_info(ws_panes)", bind: []) { stmt -> String in
        col(stmt, 1)
    }
    guard !cols.contains("position") else { return }
    exec("ALTER TABLE ws_panes ADD COLUMN position INTEGER NOT NULL DEFAULT 0")
    // Seed position: primary gets 0, others get 1 (exact order of old secondaries not recoverable)
    exec("UPDATE ws_panes SET position = 0 WHERE is_primary = 1")
    exec("UPDATE ws_panes SET position = 1 WHERE is_primary = 0")
}
```

- [ ] **Step 3: Call migration at startup**

Find the existing `init` or the setup call site. In the `WorkspaceDB` init (or wherever the schema `CREATE TABLE IF NOT EXISTS` block runs), add a call to `migratePanesIfNeeded()` immediately after:

```swift
// existing schema setup call:
setupSchema()
migratePanesIfNeeded()   // ← add this line
```

- [ ] **Step 4: Update `savePane`**

Replace the existing `savePane` at line ~470:

```swift
func savePane(_ pane: PaneRecord) {
    upsert("ws_panes", [
        "id":          pane.id,
        "tab_id":      pane.tabID,
        "is_primary":  pane.isPrimary ? "1" : "0",
        "position":    String(pane.position),
        "lx":          String(pane.lx),
        "ly":          String(pane.ly),
        "lw":          String(pane.lw),
        "lh":          String(pane.lh),
        "initial_cwd": pane.initialCWD
    ])
}
```

- [ ] **Step 5: Update `loadPanes` to read position and sort**

Replace the existing `loadPanes` at line ~487:

```swift
func loadPanes(tabID: String) -> [PaneRecord] {
    rows(sql("SELECT id,tab_id,is_primary,lx,ly,lw,lh,initial_cwd,position",
             sqlFrom, "ws_panes", sqlWhere, "tab_id=?", "ORDER BY position ASC"),
         bind: [tabID]) { stmt in
        PaneRecord(
            id:         col(stmt, 0),
            tabID:      col(stmt, 1),
            isPrimary:  sqlite3_column_int(stmt, 2) != 0,
            position:   Int(sqlite3_column_int(stmt, 8)),
            lx: sqlite3_column_double(stmt, 3),
            ly: sqlite3_column_double(stmt, 4),
            lw: sqlite3_column_double(stmt, 5),
            lh: sqlite3_column_double(stmt, 6),
            initialCWD: col(stmt, 7)
        )
    }
}
```

- [ ] **Step 6: Build to verify**

```bash
xcodebuild -project srota/srota.xcodeproj -scheme srota build 2>&1 | tail -20
```

Expected: BUILD SUCCEEDED (or only pre-existing errors unrelated to this task).

- [ ] **Step 7: Commit**

```bash
git add srota/srota/WorkspaceDB.swift
git commit -m "feat: add position column to ws_panes, migrate from is_primary"
```

---

### Task 2: TerminalTab — unified panes array

**Files:**
- Modify: `srota/srota/ContentView.swift` (TerminalTab class, lines ~138–432)

**Interfaces:**
- Consumes: `PaneEntry`, `PaneLayout`, `PaneRecord` (with `position`), `makeLauncherConfig`, `AgentNotificationState`
- Produces:
  - `panes: [PaneEntry]` — all panes, `panes[0]` is first
  - `paneLayouts: [UUID: PaneLayout]` — layout per pane ID
  - `paneNames: [UUID: String]` — name per pane ID (existing, now covers all panes)
  - `focusedPaneID: UUID` — non-optional, always valid
  - `focusedViewState: TerminalViewState`
  - `removePane(id: UUID)` — unified close for any pane
  - `addPane(colorScheme:layout:workingDirectory:)` — private, appends to `panes`
  - `restorePane(record:colorScheme:)` — appends restored pane for position > 0
  - `expandNeighbor(of id: UUID)` — expand neighbors when pane is removed

- [ ] **Step 1: Replace TerminalTab stored properties**

Find the `final class TerminalTab` block (~line 138). Replace all properties up to `init` with:

```swift
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
    @Published private var agentNotification = AgentNotificationState()
    var agentStatus: AgentRunStatus?  { agentNotification.status }
    var agentStatusUpdatedAt: Double  { agentNotification.updatedAt }
    var agentSummary: String          { agentNotification.summary }
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
```

- [ ] **Step 2: Rewrite `init`**

Replace the existing `init` (~line 170):

```swift
    init(colorScheme: ColorScheme, workingDirectory: String? = nil) {
        self.initialWorkingDirectory = workingDirectory
        // Create first pane
        let paneHookID = UUID().uuidString
        let state = TerminalViewState(
            terminalConfiguration: makeLauncherConfig(tabID: hookTabID, paneID: paneHookID)
        )
        state.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: workingDirectory)
        state.controller.setColorScheme(colorScheme == .dark ? .dark : .light)
        let first = PaneEntry(hookPaneID: paneHookID, viewState: state, initialCWD: workingDirectory)
        self.panes = [first]
        self.paneLayouts = [first.id: PaneLayout()]
        self.focusedPaneID = first.id
        bindTitleSink()
        state.onClose = { [weak self, weak first] _ in
            guard let self, let first else { return }
            self.removePane(id: first.id)
        }
    }
```

- [ ] **Step 3: Rewrite computed properties**

Replace `displayName`, `focusedViewState`, `applyAgentStatus`, `statusPath`, `splitCWD`:

```swift
    var displayName: String {
        if !customName.isEmpty { return customName }
        if let name = paneNames[focusedPaneID], !name.isEmpty { return name }
        return titleFromCWD
    }

    func applyAgentStatus(_ status: AgentRunStatus, summary: String?, at timestamp: Double, paneHookID: String?) -> Bool {
        if let paneHookID, !panes.contains(where: { $0.hookPaneID == paneHookID }) {
            return false
        }
        agentNotification.apply(status: status, summary: summary, timestamp: timestamp,
                                ownerPaneID: paneHookID ?? panes[0].hookPaneID)
        return true
    }

    func clearWorkingIfStale(before timestamp: Double) {
        agentNotification.clearWorkingIfStale(before: timestamp)
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
```

- [ ] **Step 4: Rewrite split, rename, removePane, addPane, restorePane**

```swift
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

    func removePane(id: UUID) {
        let wasFocused  = focusedPaneID == id
        let hookID      = panes.first(where: { $0.id == id })?.hookPaneID
        expandNeighbor(of: id)
        panes.removeAll { $0.id == id }
        paneLayouts.removeValue(forKey: id)
        paneNames.removeValue(forKey: id)
        if let hookID { agentNotification.clearIfOwned(byPaneID: hookID) }
        if panes.isEmpty {
            closeTabCallback?()
        } else if wasFocused {
            focusedPaneID = panes[0].id
        }
    }

    private func addPane(colorScheme: ColorScheme, layout: PaneLayout, workingDirectory: String? = nil) {
        let paneHookID = UUID().uuidString
        let state = TerminalViewState(
            terminalConfiguration: makeLauncherConfig(tabID: hookTabID, paneID: paneHookID)
        )
        state.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: workingDirectory)
        state.controller.setColorScheme(colorScheme == .dark ? .dark : .light)
        let entry = PaneEntry(hookPaneID: paneHookID, viewState: state, initialCWD: workingDirectory)
        state.onClose = { [weak self, weak entry] _ in
            guard let self, let entry else { return }
            self.removePane(id: entry.id)
        }
        paneLayouts[entry.id] = layout
        panes.append(entry)
        focusedPaneID = entry.id
    }

    func restorePane(record: PaneRecord, colorScheme: ColorScheme) {
        let cwd = record.initialCWD.isEmpty ? nil : record.initialCWD
        let paneHookID = UUID().uuidString
        let state = TerminalViewState(
            terminalConfiguration: makeLauncherConfig(tabID: hookTabID, paneID: paneHookID)
        )
        state.configuration = TerminalSurfaceOptions(backend: .exec, workingDirectory: cwd)
        state.controller.setColorScheme(colorScheme == .dark ? .dark : .light)
        let entry = PaneEntry(hookPaneID: paneHookID, viewState: state, initialCWD: cwd)
        state.onClose = { [weak self, weak entry] _ in
            guard let self, let entry else { return }
            self.removePane(id: entry.id)
        }
        paneLayouts[entry.id] = PaneLayout(
            x: CGFloat(record.lx), y: CGFloat(record.ly),
            w: CGFloat(record.lw), h: CGFloat(record.lh))
        panes.append(entry)
        focusedPaneID = entry.id
    }
```

- [ ] **Step 5: Rewrite swapLayouts, performDrop, layout helpers, expandNeighbor**

```swift
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
```

- [ ] **Step 6: Build**

```bash
xcodebuild -project srota/srota.xcodeproj -scheme srota build 2>&1 | grep -E "error:|BUILD"
```

Fix any compiler errors before continuing. Expected errors at this point: usages of removed `viewState`, `secondaryPanes`, `layouts`, `primaryLayout`, `primaryExited`, `PaneRef` in other parts of `ContentView.swift` and `KeyboardShortcuts.swift` — those are fixed in Tasks 3 and 4.

- [ ] **Step 7: Commit**

```bash
git add srota/srota/ContentView.swift
git commit -m "feat: TerminalTab unified panes array, remove primary/secondary split"
```

---

### Task 3: Delete PaneRef + update views and keyboard shortcuts

**Files:**
- Modify: `srota/srota/ContentView.swift` (PaneRef enum, PaneResizingView, TerminalContentView)
- Modify: `srota/srota/KeyboardShortcuts.swift` (focusPane extension)

**Interfaces:**
- Consumes: `TerminalTab.panes`, `TerminalTab.paneLayouts`, `TerminalTab.focusedPaneID` (UUID)
- Produces: All PaneRef references eliminated; views use UUID throughout

- [ ] **Step 1: Delete `enum PaneRef`**

Remove these lines (~line 99–102 in ContentView.swift):

```swift
// DELETE this block:
enum PaneRef: Equatable, Hashable {
    case primary
    case secondary(UUID)
}
```

- [ ] **Step 2: Rewrite `PaneResizingView` private state and helpers**

Find `private final class PaneResizingView` (~line 1668). Replace the private stored properties and the three helper methods (`allPanes`, `currentLayout`, `setLayout`):

```swift
    private var dragNegRefs: [UUID] = []
    private var dragPosRefs: [UUID] = []
    private var dragStartLayouts: [(UUID, PaneLayout)] = []

    // (keep all other stored properties: hitZone, dragIsVertical, dragStartPos, showingResizeCursor)

    private func allPanes() -> [(UUID, PaneLayout)] {
        tab.panes.compactMap { e in tab.paneLayouts[e.id].map { (e.id, $0) } }
    }

    private func currentLayout(_ id: UUID) -> PaneLayout {
        tab.paneLayouts[id] ?? PaneLayout()
    }

    private func setLayout(_ l: PaneLayout, for id: UUID) {
        tab.paneLayouts[id] = l
    }
```

- [ ] **Step 3: Fix `edgeNear` + drag methods in PaneResizingView**

The `edgeNear` method returns `(Bool, [PaneRef], [PaneRef])` — change to `(Bool, [UUID], [UUID])`. The `mouseDown` assigns to `dragNegRefs`/`dragPosRefs` — already `[UUID]` now. The `mouseDragged` iterates `dragStartLayouts` as `[(UUID, PaneLayout)]`:

The `edgeNear` signature change is purely a type substitution — the logic is identical since `allPanes()` now returns `[(UUID, PaneLayout)]` and `.map(\.0)` gives `[UUID]`. No logic changes needed.

Change return type annotation only:

```swift
    private func edgeNear(_ p: CGPoint) -> (Bool, [UUID], [UUID])? {
```

- [ ] **Step 4: Rewrite `TerminalContentView`**

Find `private struct TerminalContentView` (~line 1830). Replace the entire struct:

```swift
private struct TerminalContentView: View {
    @ObservedObject var tab: TerminalTab
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
                            id: entry.id, state: entry.viewState, layout: l,
                            onClose: { tab.removePane(id: entry.id); onPaneResizeFinished() },
                            sz: sz,
                            focused: tab.focusedPaneID == entry.id
                        )
                        .simultaneousGesture(TapGesture().onEnded {
                            tab.focusedPaneID = entry.id
                        })
                        .onAppear {
                            if tab.focusedPaneID == entry.id {
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
                if let entry = tab.panes.first(where: { $0.id == newID }) {
                    requestKeyboardFocus(for: entry.viewState)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func paneView(id: UUID, state: TerminalViewState,
                          layout l: PaneLayout, onClose: @escaping () -> Void,
                          sz: CGSize, focused: Bool) -> some View {
        let isSource = isDragging && dragSource == id
        let isTarget = isDragging && dragHover  == id && dragSource != id

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
            ReactivePaneHeader(
                state: state,
                customName: tab.paneNames[id] ?? "",
                focused: focused,
                showClose: true,
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
                window.makeFirstResponder(tv)
            }
        }
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
                    let f = Swift.max(nl.x, pl.x), t = Swift.min(nl.x + nl.w, pl.x + pl.w)
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
```

- [ ] **Step 5: Update KeyboardShortcuts.swift — focusPane extension**

Replace the `TerminalTab` extension in `KeyboardShortcuts.swift` (~line 100–149):

```swift
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
```

- [ ] **Step 6: Build clean**

```bash
xcodebuild -project srota/srota.xcodeproj -scheme srota build 2>&1 | grep -E "error:|BUILD"
```

Expected: BUILD SUCCEEDED. Fix any remaining `PaneRef` reference errors.

- [ ] **Step 7: Commit**

```bash
git add srota/srota/ContentView.swift srota/srota/KeyboardShortcuts.swift
git commit -m "feat: delete PaneRef enum, update all views to use UUID"
```

---

### Task 4: Workspace wiring + save/restore + agent routing

**Files:**
- Modify: `srota/srota/ContentView.swift` (`Workspace.addTab`, `addRestoredTab`, `saveLayout`, `restoreSessionsFromDB`, `bestMatchingTab`)

**Interfaces:**
- Consumes: `TerminalTab.panes`, `TerminalTab.paneLayouts`, `TerminalTab.removePane(id:)` (wired in `init` — no more external `onClose` wiring needed)
- Produces: correct session save/restore; correct agent routing pane snapshot

- [ ] **Step 1: Simplify `Workspace.addTab`**

Remove `tab.viewState.onClose` wiring — `init` now handles it. Replace `addTab`:

```swift
func addTab(colorScheme: ColorScheme, workingDirectory: String? = nil) {
    lastColorScheme = colorScheme
    let tab = TerminalTab(colorScheme: colorScheme, workingDirectory: workingDirectory)
    tab.closeTabCallback = { [weak self, weak tab] in
        guard let self, let tab else { return }
        self.closeTab(id: tab.id)
    }
    tabs.append(tab)
    selectedTabID = tab.id
}
```

- [ ] **Step 2: Simplify `Workspace.addRestoredTab`**

Same — remove `tab.viewState.onClose` block:

```swift
func addRestoredTab(record: TabRecord, colorScheme: ColorScheme) {
    lastColorScheme = colorScheme
    let cwd = record.initialCWD.isEmpty ? nil : record.initialCWD
    let tab = TerminalTab(colorScheme: colorScheme, workingDirectory: cwd)
    tab.closeTabCallback = { [weak self, weak tab] in
        guard let self, let tab else { return }
        self.closeTab(id: tab.id)
    }
    tabs.append(tab)
    if record.isSelected { selectedTabID = tab.id }
}
```

- [ ] **Step 3: Rewrite `saveLayout` pane loop**

Find `saveLayout` (~line 899). Replace the inner pane-saving block:

```swift
// REPLACE this block:
//   db.savePane(PaneRecord(id: "\(tab.id)_primary", ...))
//   for pane in tab.secondaryPanes { ... }
// WITH:
for (i, pane) in tab.panes.enumerated() {
    if let layout = tab.paneLayouts[pane.id] {
        db.savePane(PaneRecord(
            id: pane.id.uuidString, tabID: tab.id.uuidString,
            isPrimary: i == 0, position: i,
            lx: Double(layout.x), ly: Double(layout.y),
            lw: Double(layout.w), lh: Double(layout.h),
            initialCWD: pane.initialCWD ?? ""))
    }
}
```

- [ ] **Step 4: Rewrite `restoreSessionsFromDB` pane restore**

Find the inner tab restore block (~line 955–965). Replace:

```swift
// REPLACE:
//   for pane in panes where !pane.isPrimary { tab.restorePane(...) }
//   if let primary = panes.first(where: { $0.isPrimary }) { tab.primaryLayout = ... }
// WITH:
let sortedPanes = panes.sorted(by: { $0.position < $1.position })
// First pane (position 0) was created in init — just update its layout
if let firstRecord = sortedPanes.first {
    tab.paneLayouts[tab.panes[0].id] = PaneLayout(
        x: CGFloat(firstRecord.lx), y: CGFloat(firstRecord.ly),
        w: CGFloat(firstRecord.lw), h: CGFloat(firstRecord.lh))
    // If first pane had zero size (was collapsed), treat it as exited — remove it
    if firstRecord.lw == 0 || firstRecord.lh == 0 {
        tab.removePane(id: tab.panes[0].id)
    }
}
// Remaining panes
for record in sortedPanes.dropFirst() {
    tab.restorePane(record: record, colorScheme: colorScheme)
}
```

- [ ] **Step 5: Fix agent routing snapshot**

Find `bestMatchingTab` (~line 1014). Replace the `paneIDs` line:

```swift
// REPLACE:
//   paneIDs: Set([tab.primaryPaneHookID] + tab.secondaryPanes.map(\.hookPaneID))
// WITH:
paneIDs: Set(tab.panes.map(\.hookPaneID))
```

Full `bestMatchingTab` after change:

```swift
private func bestMatchingTab(for event: AgentHookEvent) -> TerminalTab? {
    let tabs = manager.allWorkspaces.flatMap(\.tabs)
    let snapshots = tabs.map { tab in
        AgentNotificationTabSnapshot(
            tabID: tab.hookTabID,
            cwd: tab.statusPath,
            paneIDs: Set(tab.panes.map(\.hookPaneID))
        )
    }
    guard let index = AgentNotificationRouter.bestMatchingTabIndex(
        for: AgentNotificationEvent(tabID: event.tabID, paneID: event.paneID, cwd: event.cwd),
        in: snapshots
    ) else { return nil }
    return tabs[index]
}
```

- [ ] **Step 6: Remove split pane indicator that referenced `secondaryPanes`**

Search for any remaining `secondaryPanes` references (used in tab bar UI to show split indicator). Update those to use `tab.panes.count > 1`:

```bash
grep -n "secondaryPanes" srota/srota/ContentView.swift
```

For each hit like `.active: !tab.secondaryPanes.isEmpty`, change to `.active: tab.panes.count > 1`.

- [ ] **Step 7: Final build**

```bash
xcodebuild -project srota/srota.xcodeproj -scheme srota build 2>&1 | grep -E "error:|warning:|BUILD"
```

Expected: BUILD SUCCEEDED with no errors. Warnings about unused `isPrimary` on `PaneRecord` are acceptable (it's kept for legacy read during migration).

- [ ] **Step 8: Commit**

```bash
git add srota/srota/ContentView.swift
git commit -m "feat: unified save/restore and agent routing, remove Workspace onClose wiring"
```
