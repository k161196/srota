import SwiftUI
import AppKit

// Mirrors ManagementView.swift's private Color.mg* palette — duplicated here since that
// extension is file-private and this view lives in a different file (same convention GitHubProjectsPanel.swift uses).
private extension Color {
    static let mgBg        = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let mgSurface   = Color(red: 0.10,  green: 0.10,  blue: 0.11)
    static let mgBorder    = Color.white.opacity(0.07)
    static let mgAccent    = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let mgLabel     = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let mgMuted     = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.40)
    static let mgRowHover  = Color.white.opacity(0.065)
}

struct TasksPanel: View {
    @Environment(WorkspaceDB.self) private var db
    @Environment(AppSettings.self) private var settings

    enum SubTab { case issues, prs }

    @State private var subTab: SubTab = .issues
    @State private var issueRows: [IssueRow] = []
    @State private var prRows: [PRRow] = []
    @State private var hasFetchedIssues = false
    @State private var hasFetchedPRs = false
    @State private var fetching = false
    @State private var loadError: String? = nil
    @State private var issueQuery = "is:issue is:open"
    @State private var prQuery = "is:pr is:open"
    @State private var showFilters = false
    @State private var busyRowID: String? = nil
    @State private var actionError: String? = nil
    @State private var projectFilter: Set<String> = []
    @State private var showProjectFilter = false
    @State private var ghRepoListings: [TaskGHRepoListing] = []
    @State private var fetchingGHRepos = false

    private var allConnectedRepos: [RepoEntry] { db.repos.filter { gitURLComponents($0.url) != nil } }

    // Every repo you could scope to: your connected (Srota) repos plus anything else on your
    // GitHub account discovered via `gh repo list`, so you can filter to a repo before adding it.
    private var allProjectOptions: [RepoEntry] {
        var result = allConnectedRepos
        let existingKeys = Set(result.compactMap { gitURLComponents($0.url) }.map { "\($0.0)/\($0.1)".lowercased() })
        for listing in ghRepoListings {
            guard let parts = gitURLComponents(listing.url) else { continue }
            let key = "\(parts.0)/\(parts.1)".lowercased()
            guard !existingKeys.contains(key) else { continue }
            let name = listing.nameWithOwner.split(separator: "/").last.map(String.init) ?? listing.nameWithOwner
            result.append(RepoEntry(id: listing.url, name: name, url: listing.url, defaultBranch: listing.defaultBranchRef?.name ?? "main"))
        }
        return result
    }

    private var connectedRepos: [RepoEntry] {
        guard !projectFilter.isEmpty else { return allConnectedRepos }
        return allProjectOptions.filter { projectFilter.contains($0.id) }
    }
    private var query: Binding<String> { subTab == .issues ? $issueQuery : $prQuery }

    private var projectFilterLabel: String {
        if projectFilter.isEmpty { return "All projects" }
        if projectFilter.count == 1, let repo = allProjectOptions.first(where: { projectFilter.contains($0.id) }) {
            return repo.name
        }
        return "\(projectFilter.count) projects"
    }

    // Selecting toggles from the "all connected repos" baseline, not the full GitHub account —
    // otherwise unchecking one repo out of hundreds would scope every fetch to the other 199.
    private func toggleProject(_ id: String) {
        let connectedIDs = Set(allConnectedRepos.map(\.id))
        var current = projectFilter.isEmpty ? connectedIDs : projectFilter
        if current.contains(id) { current.remove(id) } else { current.insert(id) }
        projectFilter = (current.isEmpty || current == connectedIDs) ? [] : current
    }

    private func fetchTaskGHRepoListingsIfNeeded() {
        guard ghRepoListings.isEmpty, !fetchingGHRepos else { return }
        fetchingGHRepos = true
        Task {
            let listings = await Task.detached { fetchTaskGHRepoListings() }.value
            ghRepoListings = listings
            fetchingGHRepos = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            toolbar
            Rectangle().fill(Color.mgBorder).frame(height: 1)
            tableHeaderRow
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.mgBg)
        .onAppear { fetchIfNeeded() }
        .onChange(of: subTab) { fetchIfNeeded() }
        .onChange(of: projectFilter) { refresh() }
        .alert("Error", isPresented: .init(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

    // MARK: - Header / toolbar

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist").font(.system(size: 13)).foregroundStyle(Color.mgAccent)
            Text("Tasks").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mgLabel)
            Button { showProjectFilter = true } label: {
                HStack(spacing: 4) {
                    Text(projectFilterLabel).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.mgLabel)
                    Image(systemName: "chevron.up.chevron.down").font(.system(size: 8)).foregroundStyle(Color.mgMuted)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
            .buttonStyle(.plain)
            .background(Color.mgSurface)
            .overlay(Capsule().stroke(Color.mgBorder, lineWidth: 1))
            .clipShape(Capsule())
            .popover(isPresented: $showProjectFilter, arrowEdge: .bottom) {
                ProjectFilterMenu(
                    recent: allConnectedRepos,
                    others: allProjectOptions.filter { repo in !allConnectedRepos.contains { $0.id == repo.id } },
                    selected: $projectFilter,
                    settings: settings,
                    isFetchingOthers: fetchingGHRepos,
                    onToggle: toggleProject,
                    onAppear: fetchTaskGHRepoListingsIfNeeded
                )
            }
            Spacer()
            Button { refresh() } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mgMuted)
            }
            .buttonStyle(.plain)
            .help("Refresh")
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.mgBg)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SubTabButton(title: "Issues", isActive: subTab == .issues) { subTab = .issues }
                SubTabButton(title: "PRs", isActive: subTab == .prs) { subTab = .prs }
                Spacer()
            }
            HStack(spacing: 6) {
                if subTab == .issues {
                    QuickChip(title: "Open", isActive: issueQuery == "is:issue is:open") {
                        issueQuery = "is:issue is:open"; refreshIssues()
                    }
                    QuickChip(title: "Assigned to me", isActive: issueQuery.contains("assignee:@me")) {
                        issueQuery = "is:issue is:open assignee:@me"; refreshIssues()
                    }
                } else {
                    QuickChip(title: "Open", isActive: prQuery == "is:pr is:open") {
                        prQuery = "is:pr is:open"; refreshPRs()
                    }
                    QuickChip(title: "Mine", isActive: prQuery.contains("author:@me")) {
                        prQuery = "is:pr is:open author:@me"; refreshPRs()
                    }
                    QuickChip(title: "Needs review", isActive: prQuery.contains("review-requested:@me")) {
                        prQuery = "is:pr is:open review-requested:@me"; refreshPRs()
                    }
                }

                Button { showFilters = true } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease").font(.system(size: 10))
                        Text("Filters").font(.system(size: 11, weight: .medium))
                        let count = activeFilterTokens(query.wrappedValue, subTab: subTab).count
                        if count > 0 {
                            Text("\(count)").font(.system(size: 9, weight: .semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.mgAccent.opacity(0.2)).foregroundStyle(Color.mgAccent)
                                .clipShape(Capsule())
                        }
                    }
                    .foregroundStyle(Color.mgMuted)
                    .padding(.horizontal, 9).padding(.vertical, 5)
                }
                .buttonStyle(.plain)
                .background(Color.mgSurface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .popover(isPresented: $showFilters, arrowEdge: .bottom) {
                    FiltersMenuView(
                        subTab: subTab,
                        query: query,
                        assigneeSuggestions: distinctAssignees,
                        authorSuggestions: distinctAuthors,
                        labelSuggestions: distinctLabels,
                        reviewerSuggestions: distinctReviewers,
                        onApply: { refresh() }
                    )
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                    TextField("Search…", text: query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.mgLabel)
                        .onSubmit { refresh() }
                    if !query.wrappedValue.isEmpty {
                        Button {
                            query.wrappedValue = subTab == .issues ? "is:issue is:open" : "is:pr is:open"
                            refresh()
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 5)
                .frame(maxWidth: .infinity)
                .background(Color.mgSurface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }

            let tokens = activeFilterTokens(query.wrappedValue, subTab: subTab)
            if !tokens.isEmpty {
                HStack(spacing: 6) {
                    ForEach(tokens) { token in
                        HStack(spacing: 4) {
                            Text("\(token.label): \(token.value)").font(.system(size: 10, weight: .medium))
                            Button {
                                query.wrappedValue = queryRemoving(token.prefix, from: query.wrappedValue)
                                refresh()
                            } label: {
                                Image(systemName: "xmark").font(.system(size: 7, weight: .bold))
                            }
                            .buttonStyle(.plain)
                        }
                        .foregroundStyle(Color.mgLabel)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.mgAccent.opacity(0.12))
                        .clipShape(Capsule())
                    }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(Color.mgBg)
    }

    private var tableHeaderRow: some View {
        HStack(spacing: 10) {
            Text("ID").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Color.mgMuted).frame(width: TaskRowMetrics.idWidth, alignment: .leading)
            Text("TITLE / CONTEXT")
                .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(Color.mgMuted)
            Spacer(minLength: 8)
            if subTab == .prs {
                Text("REVIEWERS").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Color.mgMuted).frame(width: TaskRowMetrics.personWidth, alignment: .leading)
                Text("CHECKS").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Color.mgMuted).frame(width: TaskRowMetrics.checksWidth, alignment: .leading)
                Text("MERGE").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Color.mgMuted).frame(width: TaskRowMetrics.mergeWidth, alignment: .leading)
            } else {
                Text("ASSIGNEES").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Color.mgMuted).frame(width: TaskRowMetrics.personWidth, alignment: .leading)
                Text("STATUS").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Color.mgMuted).frame(width: TaskRowMetrics.statusWidth, alignment: .leading)
            }
            Text("UPDATED").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Color.mgMuted).frame(width: TaskRowMetrics.updatedWidth, alignment: .trailing)
            Color.clear.frame(width: TaskRowMetrics.actionWidth)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .fixedSize(horizontal: false, vertical: true)
        .background(Color.mgBg)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let isEmpty = subTab == .issues ? issueRows.isEmpty : prRows.isEmpty
        if fetching && isEmpty {
            skeletonList
        } else if let loadError, isEmpty {
            VStack { Spacer(); Text(loadError).font(.system(size: 12)).foregroundStyle(Color.mgMuted); Spacer() }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if isEmpty && !fetching {
            VStack {
                Spacer()
                Text(subTab == .issues ? "No matching issues" : "No matching PRs")
                    .font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    if subTab == .issues {
                        ForEach(issueRows) { row in
                            IssueRowView(
                                row: row,
                                isBusy: busyRowID == row.id,
                                canStart: isMainCloned(for: row.repo, settings: settings),
                                hasWorkspace: hasExistingWorkspace(issue: row),
                                onStart: { startIssue(row) },
                                onOpenGitHub: { openOnGitHub(row.issue.url) },
                                onToggleState: { reason in toggleIssueState(row, reason: reason) },
                                onAssigneeAction: { login, add in toggleAssignee(row, login: login, add: add) }
                            )
                        }
                    } else {
                        ForEach(prRows) { row in
                            PRRowView(
                                row: row,
                                isBusy: busyRowID == row.id,
                                canStart: isMainCloned(for: row.repo, settings: settings),
                                hasWorkspace: hasExistingWorkspace(pr: row),
                                onStart: { startPR(row) },
                                onOpenGitHub: { openPROnGitHub(row) }
                            )
                        }
                    }
                }
            }
            .id("\(subTab)-\(query.wrappedValue)")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var skeletonList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(0..<10, id: \.self) { _ in SkeletonRow(isPR: subTab == .prs) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }

    // MARK: - Distinct-value suggestions (no extra gh calls — derived from already-fetched rows)

    private var distinctAssignees: [String] {
        Array(Set(issueRows.flatMap { $0.issue.assignees.map(\.login) })).sorted()
    }
    private var distinctAuthors: [String] {
        subTab == .issues
            ? Array(Set(issueRows.map { $0.issue.author.login })).sorted()
            : Array(Set(prRows.map { $0.pr.author.login })).sorted()
    }
    private var distinctLabels: [String] {
        subTab == .issues
            ? Array(Set(issueRows.flatMap { $0.issue.labels.map(\.name) })).sorted()
            : Array(Set(prRows.flatMap { $0.pr.labels.map(\.name) })).sorted()
    }
    private var distinctReviewers: [String] {
        Array(Set(prRows.flatMap { $0.pr.reviewRequests.map(\.displayName) })).sorted()
    }

    // MARK: - Fetch

    private func fetchIfNeeded() {
        if subTab == .issues, !hasFetchedIssues { refreshIssues() }
        if subTab == .prs, !hasFetchedPRs { refreshPRs() }
    }

    private func refresh() {
        if subTab == .issues { refreshIssues() } else { refreshPRs() }
    }

    private func refreshIssues() {
        fetching = true; loadError = nil
        let repos = connectedRepos; let q = issueQuery
        Task {
            let (rows, err) = await fetchIssuesAcrossRepos(repos, query: q)
            issueRows = rows; loadError = err; fetching = false; hasFetchedIssues = true
        }
    }

    private func refreshPRs() {
        fetching = true; loadError = nil
        let repos = connectedRepos; let q = prQuery
        Task {
            let (rows, err) = await fetchPRsAcrossRepos(repos, query: q)
            prRows = rows; loadError = err; fetching = false; hasFetchedPRs = true
        }
    }

    // MARK: - Row actions

    private func hasExistingWorkspace(issue row: IssueRow) -> Bool {
        guard let path = worktreePath(for: row.repo, branch: "issue/\(row.issue.number)", settings: settings) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func hasExistingWorkspace(pr row: PRRow) -> Bool {
        guard let path = worktreePath(for: row.repo, branch: row.pr.headRefName, settings: settings) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func startIssue(_ row: IssueRow) {
        busyRowID = row.id
        Task {
            let result = await startIssueWorkspace(row, settings: settings)
            busyRowID = nil
            if case .failure(let err) = result { actionError = err.message }
        }
    }

    private func startPR(_ row: PRRow) {
        busyRowID = row.id
        Task {
            let result = await startPRWorkspace(row, settings: settings)
            busyRowID = nil
            if case .failure(let err) = result { actionError = err.message }
        }
    }

    private func toggleIssueState(_ row: IssueRow, reason: String? = nil) {
        guard let idx = issueRows.firstIndex(where: { $0.id == row.id }) else { return }
        let closing = row.issue.state == "OPEN"
        Task {
            let result = await setIssueState(row, closed: closing, reason: reason)
            switch result {
            case .success: issueRows[idx].issue.state = closing ? "CLOSED" : "OPEN"
            case .failure(let err): actionError = err.message
            }
        }
    }

    private func toggleAssignee(_ row: IssueRow, login: String, add: Bool) {
        guard let idx = issueRows.firstIndex(where: { $0.id == row.id }) else { return }
        Task {
            let result = await setIssueAssignee(row, login: login, add: add)
            switch result {
            case .success:
                if add {
                    if !issueRows[idx].issue.assignees.contains(where: { $0.login == login }) {
                        issueRows[idx].issue.assignees.append(TaskActor(login: login))
                    }
                } else {
                    issueRows[idx].issue.assignees.removeAll { $0.login == login }
                }
            case .failure(let err): actionError = err.message
            }
        }
    }

    private func openOnGitHub(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }

    private func openPROnGitHub(_ row: PRRow) {
        guard let (org, name) = gitURLComponents(row.repo.url),
              let url = URL(string: "https://github.com/\(org)/\(name)/pull/\(row.pr.number)")
        else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Projects filter popover

private struct ProjectFilterMenu: View {
    let recent: [RepoEntry]           // your connected Srota repos
    let others: [RepoEntry]           // rest of your GitHub account, not yet connected
    @Binding var selected: Set<String>
    let settings: AppSettings
    let isFetchingOthers: Bool
    let onToggle: (String) -> Void
    let onAppear: () -> Void

    @State private var search = ""

    private var searching: Bool { !search.isEmpty }
    private var allRepos: [RepoEntry] { recent + others }
    private var searchMatches: [RepoEntry] {
        allRepos.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func isChecked(_ repo: RepoEntry) -> Bool {
        selected.isEmpty ? recent.contains { $0.id == repo.id } : selected.contains(repo.id)
    }

    private func subtitle(for repo: RepoEntry) -> String {
        if recent.contains(where: { $0.id == repo.id }) {
            return mainClonePath(for: repo, settings: settings) ?? repo.url
        }
        return gitURLComponents(repo.url).map { $0.0 } ?? repo.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Color.mgMuted)
                TextField("Search projects", text: $search).textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Color.mgLabel)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(Color.mgSurface)
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.mgBorder, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .padding(10)

            if !selected.isEmpty {
                HStack {
                    Text("\(selected.count) selected").font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                    Spacer()
                    Button("Show all") { selected = [] }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .medium)).foregroundStyle(Color.mgAccent)
                }
                .padding(.horizontal, 12).padding(.bottom, 6)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if searching {
                        ForEach(searchMatches) { repo in
                            ProjectFilterRow(title: repo.name, subtitle: subtitle(for: repo), isChecked: isChecked(repo)) {
                                onToggle(repo.id)
                            }
                        }
                    } else {
                        if !recent.isEmpty {
                            ProjectFilterSectionHeader(title: "RECENT")
                            ForEach(recent) { repo in
                                ProjectFilterRow(title: repo.name, subtitle: subtitle(for: repo), isChecked: isChecked(repo)) {
                                    onToggle(repo.id)
                                }
                            }
                        }
                        ProjectFilterSectionHeader(title: "BROWSE ALL")
                        if isFetchingOthers && others.isEmpty {
                            Text("Loading your GitHub repos…").font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                                .padding(.horizontal, 12).padding(.vertical, 8)
                        } else {
                            ForEach(others) { repo in
                                ProjectFilterRow(title: repo.name, subtitle: subtitle(for: repo), isChecked: isChecked(repo)) {
                                    onToggle(repo.id)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 320)
        .background(Color.mgBg)
        .onAppear(perform: onAppear)
    }
}

private struct ProjectFilterSectionHeader: View {
    let title: String
    var body: some View {
        Text(title).font(.system(size: 10, weight: .semibold)).tracking(0.6).foregroundStyle(Color.mgMuted)
            .padding(.horizontal, 6).padding(.top, 10).padding(.bottom, 4)
    }
}

private struct ProjectFilterRow: View {
    let title: String
    let subtitle: String
    let isChecked: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 14, weight: .semibold)).foregroundStyle(Color.mgLabel).lineLimit(1)
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(Color.mgMuted).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if isChecked {
                    Image(systemName: "checkmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mgAccent)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovered ? Color.mgRowHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .onHover { hovered = $0 }
    }
}

// MARK: - Small toolbar controls

private struct SubTabButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.black.opacity(0.85) : Color.mgMuted)
                .padding(.horizontal, 12).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(isActive ? Color.white.opacity(0.92) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

private struct SkeletonRow: View {
    let isPR: Bool
    @State private var pulse = false

    private var fill: Color { Color.white.opacity(pulse ? 0.10 : 0.05) }

    var body: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(fill).frame(width: TaskRowMetrics.idWidth, height: 11)
            VStack(alignment: .leading, spacing: 6) {
                RoundedRectangle(cornerRadius: 3).fill(fill).frame(width: 220, height: 11)
                RoundedRectangle(cornerRadius: 3).fill(fill).frame(width: 120, height: 9)
            }
            Spacer(minLength: 8)
            Circle().fill(fill).frame(width: 20, height: 20).frame(width: TaskRowMetrics.personWidth)
            if isPR {
                Capsule().fill(fill).frame(width: TaskRowMetrics.checksWidth, height: 16)
                Capsule().fill(fill).frame(width: TaskRowMetrics.mergeWidth, height: 16)
            } else {
                Capsule().fill(fill).frame(width: TaskRowMetrics.statusWidth, height: 16)
            }
            RoundedRectangle(cornerRadius: 3).fill(fill).frame(width: TaskRowMetrics.updatedWidth, height: 9)
            Capsule().fill(fill).frame(width: TaskRowMetrics.actionWidth, height: 16)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
        .onAppear {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { pulse = true }
        }
    }
}

private struct QuickChip: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 11, weight: isActive ? .semibold : .regular))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isActive ? Color.black.opacity(0.85) : Color.mgMuted)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isActive ? Color.white.opacity(0.92) : Color.clear)
        .clipShape(Capsule())
    }
}

// Filters popover (FiltersMenuView, activeFilterTokens) and row views (IssueRowView, PRRowView)
// live in TasksPanelRows.swift.
