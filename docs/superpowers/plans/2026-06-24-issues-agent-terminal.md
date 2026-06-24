# Issues Agent Terminal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Refactor `IssuesPanel` from a simple split-list into a 3-column agent terminal panel mirroring `FeaturesPanel` — issue list | tabbed terminal center | issue detail sidebar.

**Architecture:** Add `IssueAgentTab` + `IssueAgentFocus` state types (mirrors of `FeatureAgentTab`/`FeatureAgentFocus`), wire them into the environment, keep `IssuesPanel` always alive in `ManagementPanel`'s ZStack so terminals survive tab switches, then replace the existing `IssuesPanel` body with the full 3-column implementation including context injection.

**Tech Stack:** Swift 5.9+, SwiftUI, GhosttyTerminal (TerminalTab, TerminalSurfaceView, TerminalViewState)

## Global Constraints

- All new code goes into `srota/srota/ManagementView.swift` and `srota/srota/srotaApp.swift` — no new files
- Design tokens (`Color.mgBg`, `Color.mgAccent`, etc.) are already defined in `ManagementView.swift` and must be reused — do not add new color definitions
- Private helper views (`SelectableRow`, `FeatureTabChip`, `RowPrimary`, `RowSecondary`, `AddSheet`, `MGField`, `MGPicker`, `DetailRow`, `StatusBadge`, `issueStatuses`) are already defined in `ManagementView.swift` as file-private — all new code in the same file can use them directly
- `FeatureTabChip`, `FeatureTerminalStack` are reused as-is — do not duplicate or rename them
- Context injection block markers: `<!-- srota:start -->` / `<!-- srota:end -->` (same as features)
- TOML block markers: `# srota:start` / `# srota:end` (same as features)

---

## File Map

| File | Change |
|------|--------|
| `srota/srota/ManagementView.swift` | Add `IssueAgentTab` + `IssueAgentFocus` types; update `ManagementPanel` ZStack; add `IssueInfoSidebar`; replace `IssuesPanel` body; delete `IssueDetailView` |
| `srota/srota/srotaApp.swift` | Add `@State private var issueAgentFocus = IssueAgentFocus()` and `.environment(issueAgentFocus)` |

---

### Task 1: Add IssueAgentTab + IssueAgentFocus types; wire into environment

**Files:**
- Modify: `srota/srota/ManagementView.swift` (after line 15, after `FeatureAgentFocus` closing brace)
- Modify: `srota/srota/srotaApp.swift` (lines 8 and 18)

**Interfaces:**
- Produces: `IssueAgentTab` struct, `IssueAgentFocus` class — consumed by Tasks 2, 3, 4

- [ ] **Step 1: Add IssueAgentTab and IssueAgentFocus to ManagementView.swift**

In `srota/srota/ManagementView.swift`, after the closing brace of `FeatureAgentFocus` (currently ends at line 15), insert:

```swift
struct IssueAgentTab: Identifiable {
    let id: String        // "global" or issue.id
    let issueID: String?  // nil = global tab
    let tab: TerminalTab
}

@Observable @MainActor
final class IssueAgentFocus {
    var activeViewState: TerminalViewState?
    var agentTabs: [IssueAgentTab] = []
    var activeTabID: String = "global"
}
```

- [ ] **Step 2: Wire IssueAgentFocus into srotaApp.swift**

In `srota/srota/srotaApp.swift`, after line 8 (`@State private var agentFocus = FeatureAgentFocus()`), add:

```swift
@State private var issueAgentFocus = IssueAgentFocus()
```

Then in the `.environment` chain (after `.environment(agentFocus)`), add:

```swift
.environment(issueAgentFocus)
```

The `body` block should look like:

```swift
ContentView()
    .preferredColorScheme(.dark)
    .environment(settings)
    .environment(db)
    .environment(presetsStore)
    .environment(agentFocus)
    .environment(issueAgentFocus)
    .onAppear { ... }
```

- [ ] **Step 3: Build and verify no errors**

Build in Xcode (⌘B). Expected: build succeeds with 0 errors.

- [ ] **Step 4: Commit**

```bash
git add srota/srota/ManagementView.swift srota/srota/srotaApp.swift
git commit -m "feat: add IssueAgentTab + IssueAgentFocus state types"
```

---

### Task 2: Keep IssuesPanel alive in ManagementPanel's ZStack

**Files:**
- Modify: `srota/srota/ManagementView.swift` — `ManagementPanel.body` (currently lines 161–178)

**Interfaces:**
- Consumes: `IssueAgentFocus` (from Task 1, already in environment — no direct reference needed here)
- Produces: `IssuesPanel` always instantiated in hierarchy (terminals never destroyed)

- [ ] **Step 1: Replace ManagementPanel body**

Find `ManagementPanel.body` in `ManagementView.swift`. The current body is:

```swift
var body: some View {
    ZStack {
        // Always in hierarchy — TerminalSurfaceView must never be destroyed
        FeaturesPanel()
            .opacity(tab == .features ? 1 : 0)
            .allowsHitTesting(tab == .features)

        if tab != .features {
            switch tab {
            case .workspaces:    EmptyView()  // handled by ContentView
            case .organizations: OrganizationsPanel()
            case .projects:      ProjectsPanel()
            case .features:      EmptyView()
            case .repos:         ReposPanel()
            case .issues:        IssuesPanel()
            }
        }
    }
}
```

Replace with:

```swift
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
            case .organizations: OrganizationsPanel()
            case .projects:      ProjectsPanel()
            case .features:      EmptyView()
            case .repos:         ReposPanel()
            case .issues:        EmptyView()
            }
        }
    }
}
```

- [ ] **Step 2: Build and verify no errors**

Build in Xcode (⌘B). Expected: build succeeds. Issues tab still shows existing list (unchanged until Task 4).

- [ ] **Step 3: Commit**

```bash
git add srota/srota/ManagementView.swift
git commit -m "feat: keep IssuesPanel persistent in ManagementPanel ZStack"
```

---

### Task 3: Add IssueInfoSidebar

**Files:**
- Modify: `srota/srota/ManagementView.swift` — add `IssueInfoSidebar` after the existing `IssueDetailView` struct (currently ends around line 1804)

**Interfaces:**
- Consumes: `Issue`, `WorkspaceDB`, `issueStatuses: [String]`, `DetailRow`, `Color.mg*` tokens — all already in `ManagementView.swift`
- Produces: `IssueInfoSidebar(issue: Issue, db: WorkspaceDB)` — consumed by Task 4

- [ ] **Step 1: Add IssueInfoSidebar struct**

In `srota/srota/ManagementView.swift`, after the closing brace of `IssueDetailView`, insert:

```swift
private struct IssueInfoSidebar: View {
    let issue: Issue
    let db: WorkspaceDB
    @State private var title = ""
    @State private var issueBody = ""
    @State private var status = "open"

    var linkedFeature: Feature? { db.features.first { $0.id == issue.featureID } }
    var linkedOrg: Organization? { db.organizations.first { $0.id == issue.orgID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
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
```

- [ ] **Step 2: Build and verify no errors**

Build in Xcode (⌘B). Expected: build succeeds. `IssueInfoSidebar` is defined but not yet referenced — that's fine.

- [ ] **Step 3: Commit**

```bash
git add srota/srota/ManagementView.swift
git commit -m "feat: add IssueInfoSidebar view"
```

---

### Task 4: Replace IssuesPanel with 3-column layout + context injection

**Files:**
- Modify: `srota/srota/ManagementView.swift` — replace `IssuesPanel` struct body (currently lines 1706–1750); delete `IssueDetailView` struct (currently lines 1752–1804)

**Interfaces:**
- Consumes: `IssueAgentTab`, `IssueAgentFocus` (Task 1); `IssueInfoSidebar` (Task 3); `FeatureTabChip`, `TerminalSurfaceView`, `SelectableRow`, `RowPrimary`, `RowSecondary`, `StatusBadge`, `AddSheet`, `MGField`, `MGPicker`, `issueStatuses`, `Color.mg*` — all in `ManagementView.swift`
- Produces: fully functional 3-column Issues panel

- [ ] **Step 1: Replace IssuesPanel struct**

Find and replace the entire `private struct IssuesPanel: View { ... }` in `ManagementView.swift` with:

```swift
private struct IssuesPanel: View {
    @Environment(WorkspaceDB.self) var db
    @Environment(\.colorScheme) var colorScheme
    @Environment(AppSettings.self) var settings
    @Environment(IssueAgentFocus.self) var agentFocus

    @State private var showAdd = false
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
    }

    // MARK: - Tab management

    private func ensureGlobalTab() {
        guard !agentFocus.agentTabs.contains(where: { $0.id == "global" }) else { return }
        agentFocus.agentTabs.insert(
            IssueAgentTab(id: "global", issueID: nil, tab: TerminalTab(colorScheme: colorScheme)),
            at: 0
        )
    }

    private func openTab(for issue: Issue) {
        if agentFocus.agentTabs.contains(where: { $0.id == issue.id }) {
            agentFocus.activeTabID = issue.id
        } else {
            let cwds = repoPaths(for: issue)
            agentFocus.agentTabs.append(IssueAgentTab(
                id: issue.id, issueID: issue.id,
                tab: TerminalTab(colorScheme: colorScheme, workingDirectory: cwds.first)
            ))
            agentFocus.activeTabID = issue.id
            cwds.forEach { injectContext(issue: issue, into: $0) }
        }
    }

    private func closeTab(_ id: String) {
        if let agentTab = agentFocus.agentTabs.first(where: { $0.id == id }),
           let iid = agentTab.issueID {
            repoPaths(forID: iid).forEach { removeContext(from: $0) }
        }
        agentFocus.agentTabs.removeAll { $0.id == id }
        if agentFocus.activeTabID == id { agentFocus.activeTabID = "global" }
    }

    private func repoPaths(for issue: Issue) -> [String] {
        guard !issue.featureID.isEmpty else { return [] }
        return db.featureRepos
            .filter { $0.featureID == issue.featureID }
            .compactMap { fr in db.repos.first { $0.id == fr.repoID }?.localPath }
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
            MCP server `srota` is available:
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
        if let mcpPath = settings.mcpServerPath, !mcpPath.isEmpty {
            injectMCPConfig(into: dir, mcpPath: mcpPath)
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
        removeMCPConfig(from: dir)
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

    private func injectMCPConfig(into dir: String, mcpPath: String) {
        // Claude
        let settingsDir = dir + "/.claude"
        try? FileManager.default.createDirectory(atPath: settingsDir, withIntermediateDirectories: true)
        let settingsPath = settingsDir + "/settings.json"
        var s = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: settingsPath))) as? [String: Any]) ?? [:]
        var mcpServers = s["mcpServers"] as? [String: Any] ?? [:]
        mcpServers["srota"] = ["command": "bun", "args": [mcpPath]]
        s["mcpServers"] = mcpServers
        if let data = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: settingsPath))
        }
        // Codex
        let configDir = dir + "/.codex"
        try? FileManager.default.createDirectory(atPath: configDir, withIntermediateDirectories: true)
        let configPath = configDir + "/config.toml"
        var toml = (try? String(contentsOfFile: configPath, encoding: .utf8)) ?? ""
        let block = """
            # srota:start
            [[mcp_servers]]
            name = "srota"
            command = "bun"
            args = ["\(mcpPath)"]
            # srota:end
            """
        toml = toml.contains("# srota:start")
            ? replaceTomlBlock(in: toml, with: block)
            : (toml.isEmpty ? block : toml + "\n\n" + block)
        try? toml.write(toFile: configPath, atomically: true, encoding: .utf8)
    }

    private func removeMCPConfig(from dir: String) {
        let settingsPath = dir + "/.claude/settings.json"
        if var s = (try? JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: settingsPath))) as? [String: Any]) {
            var mcpServers = s["mcpServers"] as? [String: Any] ?? [:]
            mcpServers.removeValue(forKey: "srota")
            s["mcpServers"] = mcpServers.isEmpty ? nil : mcpServers
            if let data = try? JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: settingsPath))
            }
        }
        let codexPath = dir + "/.codex/config.toml"
        if var toml = try? String(contentsOfFile: codexPath, encoding: .utf8) {
            toml = replaceTomlBlock(in: toml, with: nil)
            try? toml.write(toFile: codexPath, atomically: true, encoding: .utf8)
        }
    }

    private func replaceTomlBlock(in content: String, with replacement: String?) -> String {
        let start = "# srota:start"; let end = "# srota:end"
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
                Button { showAdd = true } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mgAccent)
                        .frame(width: 28, height: 28)
                        .background(Color.mgAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
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
                            onDelete: { db.deleteIssue(id: issue.id) }
                        ) {
                            HStack(spacing: 8) {
                                VStack(alignment: .leading, spacing: 2) {
                                    RowPrimary(text: issue.title)
                                    let ctx = contextLabel(issue)
                                    if !ctx.isEmpty { RowSecondary(text: ctx) }
                                }
                                Spacer()
                                StatusBadge(status: issue.status)
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
                    TerminalSurfaceView(context: agentTab.tab.viewState)
                        .opacity(agentFocus.activeTabID == agentTab.id ? 1 : 0)
                }
            }
        }
        .onChange(of: agentFocus.activeTabID) {
            agentFocus.activeViewState = agentFocus.agentTabs
                .first { $0.id == agentFocus.activeTabID }?.tab.viewState
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
}
```

- [ ] **Step 2: Delete IssueDetailView**

Find and delete the entire `private struct IssueDetailView: View { ... }` block from `ManagementView.swift`. It is no longer referenced — `IssueInfoSidebar` replaces it.

- [ ] **Step 3: Build and verify no errors**

Build in Xcode (⌘B). Expected: build succeeds with 0 errors and 0 warnings about `IssueDetailView`.

- [ ] **Step 4: Smoke test — issue list**

Run the app (⌘R). Open the Issues tab. Verify:
- Left column shows the issue list with title, context label (org · feature), status badge
- `+` button opens the add-issue sheet
- "No issues — press +" shows when list is empty

- [ ] **Step 5: Smoke test — terminal tab**

Click an issue in the list. Verify:
- A tab chip appears in the center column header labelled with the issue title
- A terminal opens in the center (global "Issues" tab also present)
- The issue row is highlighted in the list (orange accent rail)
- Right column shows `IssueInfoSidebar` with issue title, status picker, body editor

- [ ] **Step 6: Smoke test — sidebar save**

In `IssueInfoSidebar`, edit the title or body and press Save. Switch away and back — verify the edit persisted.

- [ ] **Step 7: Smoke test — context injection**

Open an issue that is linked to a feature with a repo that has a `localPath`. Check that `CLAUDE.md` and `AGENTS.md` in that repo's path now contain the `<!-- srota:start -->` block with the issue's title, ID, status. Close the tab — verify the block is removed.

- [ ] **Step 8: Smoke test — tab switching survives ManagementTab change**

Open an issue terminal, switch to the Features tab, switch back to Issues — verify the terminal is still alive (no crash, same session).

- [ ] **Step 9: Commit**

```bash
git add srota/srota/ManagementView.swift
git commit -m "feat: Issues panel — 3-column layout with agent terminal center and context injection"
```
