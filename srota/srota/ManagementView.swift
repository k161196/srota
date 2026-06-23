import SwiftUI

extension Notification.Name {
    static let srotaOpenWorkspace = Notification.Name("srota.openWorkspace")
}

// MARK: - Top-level tab enum

enum ManagementTab: String, CaseIterable {
    case workspaces    = "Workspaces"
    case organizations = "Organizations"
    case projects      = "Projects"
    case features      = "Features"
    case repos         = "Repos"
    case issues        = "Issues"

    var icon: String {
        switch self {
        case .workspaces:    return "terminal"
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
    var onPresetLaunch: (TerminalPreset) -> Void = { _ in }
    @Environment(PresetsStore.self) private var presetsStore

    var body: some View {
        HStack(spacing: 0) {
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

            Button(action: onSettings) {
                Image(systemName: "gear")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.mgMuted)
                    .frame(width: 32, height: 36)
            }
            .buttonStyle(.plain)
            .padding(.trailing, 4)
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
            .padding(.horizontal, 14)
            .frame(height: 36)
            .overlay(alignment: .bottom) {
                if isActive {
                    Rectangle().fill(Color.mgAccent).frame(height: 2)
                }
            }
        }
        .buttonStyle(.plain)
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
        case .workspaces:    EmptyView()  // handled by ContentView
        case .organizations: OrganizationsPanel()
        case .projects:      ProjectsPanel()
        case .features:      FeaturesPanel()
        case .repos:         ReposPanel()
        case .issues:        IssuesPanel()
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
                        .background(Color.mgAccent.opacity(0.12))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
            .background(Color.mgBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }

            ScrollView {
                LazyVStack(spacing: 0) {
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
                        .padding(.horizontal, 20)
                        .frame(maxWidth: .infinity, minHeight: 40)
                        .background(hovered == item ? Color.mgRowHover : Color.mgRow)
                        .onHover { hovered = $0 ? item : nil }
                        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
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

// MARK: - Organizations panel

private struct OrganizationsPanel: View {
    @Environment(WorkspaceDB.self) var db
    @State private var newName = ""
    @State private var newPath = ""

    var body: some View {
        EntityList(
            title: "Organizations",
            items: db.organizations,
            onDelete: { db.deleteOrganization(id: $0.id) }
        ) { org in
            VStack(alignment: .leading, spacing: 2) {
                RowPrimary(text: org.name)
                if !org.path.isEmpty { RowSecondary(text: org.path) }
            }
            .padding(.vertical, 8)
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
        .background(isSelected ? Color.mgAccent.opacity(0.12) : hovered ? Color.mgRowHover : Color.mgRow)
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Color.mgAccent).frame(width: 2) }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
    }
}

private struct BranchRow: Identifiable, Sendable {
    let id = UUID()
    let gitName: String          // from git branch -a
    let isCurrent: Bool
    let localPath: String?       // from DB checkout if matched
    let gitIsWorktree: Bool      // git "+" prefix = checked out in another worktree

    nonisolated init(gitName: String, isCurrent: Bool, localPath: String?, gitIsWorktree: Bool = false) {
        self.gitName = gitName
        self.isCurrent = isCurrent
        self.localPath = localPath
        self.gitIsWorktree = gitIsWorktree
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

private struct ProjectDetailView: View {
    let project: Project
    let db: WorkspaceDB
    let manager: TerminalManager
    @State private var editDesc = ""

    var openWorkspaceNames: Set<String> {
        let all = manager.folders.flatMap(\.workspaces) + manager.workspaces
        return Set(all.map(\.name))
    }
    @State private var branches: [BranchRow] = []
    @State private var branchSearch = ""
    @State private var loadingBranches = false

    var filteredBranches: [BranchRow] {
        let filtered = branchSearch.isEmpty ? branches
            : branches.filter { $0.gitName.localizedCaseInsensitiveContains(branchSearch) }
        return filtered.sorted { a, b in
            if a.isWorktree != b.isWorktree { return a.isWorktree }
            if a.localPath != nil && b.localPath == nil { return true }
            if a.localPath == nil && b.localPath != nil { return false }
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
                                    let branchShortName = branch.gitName.components(separatedBy: "/").last ?? branch.gitName
                                    let isOpen = openWorkspaceNames.contains(branchShortName)
                                    Image(systemName: isOpen ? "terminal.fill" : "circle")
                                        .font(.system(size: 10))
                                        .foregroundStyle(isOpen ? Color.mgAccent : Color.mgMuted.opacity(0.4))
                                    Text(branch.gitName)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(isOpen ? Color.mgLabel : Color.mgMuted)
                                        .lineLimit(1)
                                    Spacer()
                                    if branch.isWorktree {
                                        Text("worktree")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(Color.purple)
                                            .padding(.horizontal, 5).padding(.vertical, 2)
                                            .background(Color.purple.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                    // Open button for every branch
                                    let branchShort = branch.gitName.components(separatedBy: "/").last ?? branch.gitName
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
                                                "projectPath":     branch.localPath ?? project.path,
                                                "branchRef":       branchRef
                                            ]
                                        )
                                    } label: {
                                        Image(systemName: hasLocal ? "terminal" : "plus.rectangle")
                                            .font(.system(size: 10))
                                            .foregroundStyle(Color.mgAccent)
                                            .frame(width: 22, height: 22)
                                            .background(Color.mgAccent.opacity(0.12))
                                            .clipShape(RoundedRectangle(cornerRadius: 4))
                                    }
                                    .buttonStyle(.plain)
                                    .help(hasLocal ? "Open in workspace" : "Create worktree & open")
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
            fetchBranches()
        }
        .onChange(of: project.id) {
            editDesc = project.description
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

            let rows: [BranchRow] = lines.compactMap { line in
                let (name, isCurrent, isGitWorktree) = parseLine(line)
                // drop remote tracking branch if a local branch with same name exists
                if name.hasPrefix("remotes/origin/") {
                    let localEquiv = String(name.dropFirst("remotes/origin/".count))
                    if localNames.contains(localEquiv) { return nil }
                }
                let shortName = name.components(separatedBy: "/").last ?? name
                // git "+" prefix means checked out in another worktree — honour that too
                let path = nameToPath[shortName]
                return BranchRow(gitName: name, isCurrent: isCurrent,
                                 localPath: path, gitIsWorktree: isGitWorktree)
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
    @State private var newName = ""
    @State private var newDesc = ""
    @State private var selectedProject: Project?

    var body: some View {
        EntityList(
            title: "Features",
            items: db.features,
            onDelete: { db.deleteFeature(id: $0.id) }
        ) { feature in
            VStack(alignment: .leading, spacing: 2) {
                RowPrimary(text: feature.name)
                let projName = db.projects.first { $0.id == feature.projectID }?.name ?? feature.projectID
                RowSecondary(text: feature.description.isEmpty ? projName : "\(projName) · \(feature.description)")
            }
            .padding(.vertical, 8)
        } addForm: { isPresented in
            AddSheet(title: "New Feature", isPresented: isPresented) {
                db.addFeature(name: newName, projectID: selectedProject?.id ?? "", description: newDesc)
                newName = ""; newDesc = ""; selectedProject = nil
            } content: {
                MGField(label: "Name", text: $newName)
                MGPicker(label: "Project", items: db.projects, displayName: \.name, selected: $selectedProject)
                MGField(label: "Description (optional)", text: $newDesc)
            }
        }
    }
}

// MARK: - Repos panel

private struct ReposPanel: View {
    @Environment(WorkspaceDB.self) var db
    @State private var newName = ""
    @State private var newURL  = ""
    @State private var newPath = ""
    @State private var selectedFeature: Feature?

    var body: some View {
        EntityList(
            title: "Repos",
            items: db.repos,
            onDelete: { db.deleteRepo(id: $0.id) }
        ) { repo in
            VStack(alignment: .leading, spacing: 2) {
                RowPrimary(text: repo.name)
                let sub = [repo.url, repo.localPath].filter { !$0.isEmpty }.first ?? ""
                if !sub.isEmpty { RowSecondary(text: sub) }
            }
            .padding(.vertical, 8)
        } addForm: { isPresented in
            AddSheet(title: "New Repo", isPresented: isPresented) {
                db.addRepo(name: newName, url: newURL, localPath: newPath, featureID: selectedFeature?.id ?? "")
                newName = ""; newURL = ""; newPath = ""; selectedFeature = nil
            } content: {
                MGField(label: "Name", text: $newName)
                MGField(label: "Git URL", text: $newURL)
                MGField(label: "Local path (optional)", text: $newPath)
                MGPicker(label: "Feature (optional)", items: db.features, displayName: \.name, selected: $selectedFeature)
            }
        }
    }
}

// MARK: - Issues panel

private struct IssuesPanel: View {
    @Environment(WorkspaceDB.self) var db
    @State private var newTitle = ""
    @State private var newBody  = ""
    @State private var selectedOrg:     Organization?
    @State private var selectedFeature: Feature?

    var body: some View {
        EntityList(
            title: "Issues",
            items: db.issues,
            onDelete: { db.deleteIssue(id: $0.id) }
        ) { issue in
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    RowPrimary(text: issue.title)
                    let ctx = contextLabel(issue)
                    if !ctx.isEmpty { RowSecondary(text: ctx) }
                }
                .padding(.vertical, 8)
                Spacer()
                StatusBadge(status: issue.status)
            }
        } addForm: { isPresented in
            AddSheet(title: "New Issue", isPresented: isPresented) {
                db.addIssue(title: newTitle, body: newBody, orgID: selectedOrg?.id ?? "", featureID: selectedFeature?.id ?? "")
                newTitle = ""; newBody = ""; selectedOrg = nil; selectedFeature = nil
            } content: {
                MGField(label: "Title", text: $newTitle)
                MGField(label: "Body (optional)", text: $newBody)
                MGPicker(label: "Organization (optional)", items: db.organizations, displayName: \.name, selected: $selectedOrg)
                MGPicker(label: "Feature (optional)", items: db.features, displayName: \.name, selected: $selectedFeature)
            }
        }
    }

    private func contextLabel(_ issue: Issue) -> String {
        var parts: [String] = []
        if !issue.orgID.isEmpty,
           let org = db.organizations.first(where: { $0.id == issue.orgID }) {
            parts.append(org.name)
        }
        if !issue.featureID.isEmpty,
           let f = db.features.first(where: { $0.id == issue.featureID }) {
            parts.append(f.name)
        }
        return parts.joined(separator: " · ")
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
