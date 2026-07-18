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

    enum SubTab { case repos, issues, prs }

    @State private var subTab: SubTab = .issues
    @State private var issueRows: [IssueRow] = []
    @State private var prRows: [PRRow] = []
    @State private var hasFetchedIssues = false
    @State private var hasFetchedPRs = false
    @State private var fetching = false
    @State private var loadError: String? = nil
    @State private var issueQuery = "is:issue is:open"
    @State private var prQuery = "is:pr is:open"
    @State private var browseSearch = ""
    @State private var showFilters = false
    @State private var busyRowID: String? = nil
    @State private var actionError: String? = nil
    @State private var projectFilter: Set<String> = []
    @State private var showProjectFilter = false
    @State private var ghRepoListings: [TaskGHRepoListing] = []
    @State private var fetchingGHRepos = false
    @State private var showAddRepo = false
    @State private var showAddBranch = false
    @State private var showAddIssue = false
    @State private var showAddPR = false

    // Repos tab: master-detail — selecting a repo on the left loads its branches on the right.
    @State private var selectedRepoID: String? = nil
    @State private var selectedRepoBranches: [BranchRow] = []
    @State private var selectedRepoBranchesFetchedFor: String? = nil
    @State private var fetchingSelectedRepoBranches = false
    @State private var branchSearch = ""

    private var allConnectedRepos: [RepoEntry] { db.repos.filter { gitURLComponents($0.url) != nil } }

    private var connectedRepos: [RepoEntry] {
        guard !projectFilter.isEmpty else { return allConnectedRepos }
        return allConnectedRepos.filter { projectFilter.contains($0.id) }
    }
    private var query: Binding<String> {
        switch subTab {
        case .issues: return $issueQuery
        case .prs: return $prQuery
        case .repos: return $browseSearch
        }
    }
    private var defaultQueryValue: String {
        switch subTab {
        case .issues: return "is:issue is:open"
        case .prs: return "is:pr is:open"
        case .repos: return ""
        }
    }

    private var filteredRepoRows: [RepoEntry] {
        browseSearch.isEmpty ? connectedRepos : connectedRepos.filter { $0.name.localizedCaseInsensitiveContains(browseSearch) }
    }

    private var selectedRepo: RepoEntry? {
        guard let id = selectedRepoID else { return nil }
        return allConnectedRepos.first { $0.id == id }
    }
    private var filteredSelectedRepoBranches: [BranchRow] {
        branchSearch.isEmpty ? selectedRepoBranches : selectedRepoBranches.filter { $0.name.localizedCaseInsensitiveContains(branchSearch) }
    }

    private var projectFilterLabel: String {
        if projectFilter.isEmpty { return "All repos" }
        if projectFilter.count == 1, let repo = allConnectedRepos.first(where: { projectFilter.contains($0.id) }) {
            return repo.name
        }
        return "\(projectFilter.count) repos"
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
        refreshGHRepoListings()
    }

    private func refreshGHRepoListings() {
        guard !fetchingGHRepos else { return }
        fetchingGHRepos = true
        Task {
            let listings = await Task.detached { fetchTaskGHRepoListings() }.value
            ghRepoListings = listings
            fetchingGHRepos = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Color.mgBorder).frame(height: 1)
            if subTab == .repos {
                repoSplitView
            } else {
                tableHeaderRow
                content
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Color.mgBg)
        .onAppear { fetchIfNeeded() }
        .onChange(of: subTab) { fetchIfNeeded() }
        .onChange(of: projectFilter) { refresh() }
        .alert("Error", isPresented: .init(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
        .sheet(isPresented: $showAddRepo) {
            AddRepoSheet(
                db: db,
                listings: ghRepoListings,
                isFetching: fetchingGHRepos,
                isPresented: $showAddRepo,
                onAppear: fetchTaskGHRepoListingsIfNeeded
            )
        }
        .sheet(isPresented: $showAddBranch) {
            if let repo = selectedRepo {
                AddBranchSheet(repo: repo, isPresented: $showAddBranch) { name in
                    addBranch(repo: repo, name: name)
                }
            }
        }
        .sheet(isPresented: $showAddIssue) {
            AddIssueSheet(repos: connectedRepos, isPresented: $showAddIssue) { repo, title, body in
                submitNewIssue(repo: repo, title: title, body: body)
            }
        }
        .sheet(isPresented: $showAddPR) {
            AddPRSheet(repos: connectedRepos, isPresented: $showAddPR) { repo, title, head, base, body in
                submitNewPR(repo: repo, title: title, head: head, base: base, body: body)
            }
        }
    }

    // MARK: - Toolbar

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                SubTabButton(title: "Repos", isActive: subTab == .repos) { subTab = .repos }
                SubTabButton(title: "Issues", isActive: subTab == .issues) { subTab = .issues }
                SubTabButton(title: "PRs", isActive: subTab == .prs) { subTab = .prs }
                Spacer()
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
                        selected: $projectFilter,
                        settings: settings,
                        onToggle: toggleProject
                    )
                }
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mgMuted)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            if subTab != .repos {
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
                                query.wrappedValue = defaultQueryValue
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

                    ToolbarIconButton(systemName: "plus") {
                        if subTab == .issues { showAddIssue = true } else { showAddPR = true }
                    }
                    ToolbarIconButton(systemName: "arrow.clockwise") { refresh() }
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

    // MARK: - Content (Issues / PRs)

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
                                onOpenGitHub: { openPROnGitHub(row) },
                                onReviewerAction: { login, add in toggleReviewer(row, login: login, add: add) }
                            )
                        }
                    }
                }
            }
            .id("\(subTab)-\(query.wrappedValue)")
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    // MARK: - Repos tab (master-detail: repo list + selected repo's branches)

    private var repoSplitView: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("REPOS").font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(Color.mgMuted)
                    HStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                            TextField("Search…", text: $browseSearch)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12))
                                .foregroundStyle(Color.mgLabel)
                            if !browseSearch.isEmpty {
                                Button { browseSearch = "" } label: {
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

                        ToolbarIconButton(systemName: "plus") { showAddRepo = true }
                        ToolbarIconButton(systemName: "arrow.clockwise") { refreshGHRepoListings() }
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                .background(Color.mgBg)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }

                if filteredRepoRows.isEmpty {
                    VStack { Spacer(); Text("No matching repos").font(.system(size: 12)).foregroundStyle(Color.mgMuted); Spacer() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredRepoRows) { repo in
                                RepoSidebarRow(
                                    repo: repo,
                                    isBusy: busyRowID == repo.id,
                                    isCloned: isMainCloned(for: repo, settings: settings),
                                    isSelected: repo.id == selectedRepoID,
                                    onStart: { startRepo(repo) },
                                    onSelect: { selectRepo(repo) }
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(width: 300)

            Rectangle().fill(Color.mgBorder).frame(width: 1)

            repoDetailPane
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    @ViewBuilder
    private var repoDetailPane: some View {
        if let repo = selectedRepo {
            VStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(repo.name).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mgLabel)
                    HStack(spacing: 6) {
                        HStack(spacing: 6) {
                            Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                            TextField("Search branches…", text: $branchSearch)
                                .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.mgLabel)
                            if !branchSearch.isEmpty {
                                Button { branchSearch = "" } label: {
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

                        ToolbarIconButton(systemName: "plus") { showAddBranch = true }
                        ToolbarIconButton(systemName: "arrow.clockwise") { refreshSelectedRepoBranches() }
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .background(Color.mgBg)

                Rectangle().fill(Color.mgBorder).frame(height: 1)

                HStack(spacing: 10) {
                    Color.clear.frame(width: TaskRowMetrics.idWidth)
                    Text("BRANCH").font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(Color.mgMuted)
                    Spacer(minLength: 8)
                    Text("STATUS").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                        .foregroundStyle(Color.mgMuted).frame(width: TaskRowMetrics.branchStatusWidth, alignment: .leading)
                    Color.clear.frame(width: TaskRowMetrics.updatedWidth)
                    Color.clear.frame(width: TaskRowMetrics.actionWidth)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color.mgBg)
                .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }

                if fetchingSelectedRepoBranches && filteredSelectedRepoBranches.isEmpty {
                    VStack { Spacer(); ProgressView(); Spacer() }.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if filteredSelectedRepoBranches.isEmpty {
                    VStack { Spacer(); Text("No matching branches").font(.system(size: 12)).foregroundStyle(Color.mgMuted); Spacer() }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(filteredSelectedRepoBranches) { row in
                                BranchRowView(
                                    row: row,
                                    isBusy: busyRowID == row.id,
                                    isCloned: hasExistingWorkspace(branch: row),
                                    canStart: row.name == row.repo.defaultBranch || isMainCloned(for: row.repo, settings: settings),
                                    onStart: { startBranch(row) },
                                    onOpenGitHub: { openBranchOnGitHub(row) },
                                    onRemove: { removeBranch(row) }
                                )
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        } else {
            VStack {
                Spacer()
                Text("Select a repo to view its branches").font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        switch subTab {
        case .repos:
            refreshGHRepoListings()
            if selectedRepo != nil { refreshSelectedRepoBranches() }
        case .issues: refreshIssues()
        case .prs: refreshPRs()
        }
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

    private func hasExistingWorkspace(branch row: BranchRow) -> Bool {
        guard let path = worktreePath(for: row.repo, branch: row.name, settings: settings) else { return false }
        return FileManager.default.fileExists(atPath: path)
    }

    private func startRepo(_ repo: RepoEntry) {
        busyRowID = repo.id
        Task {
            let result = await startRepoWorkspace(repo, settings: settings)
            busyRowID = nil
            if case .failure(let err) = result { actionError = err.message }
        }
    }

    private func selectRepo(_ repo: RepoEntry) {
        selectedRepoID = repo.id
        branchSearch = ""
        if selectedRepoBranchesFetchedFor != repo.id { refreshSelectedRepoBranches(for: repo) }
    }

    private func refreshSelectedRepoBranches(for explicitRepo: RepoEntry? = nil) {
        guard let repo = explicitRepo ?? selectedRepo else { return }
        fetchingSelectedRepoBranches = true
        Task {
            let rows = await fetchBranchesAcrossRepos([repo], settings: settings)
            guard selectedRepoID == repo.id else { return }
            selectedRepoBranches = rows
            selectedRepoBranchesFetchedFor = repo.id
            fetchingSelectedRepoBranches = false
        }
    }

    private func startBranch(_ row: BranchRow) {
        busyRowID = row.id
        Task {
            let result = await startBranchWorkspace(row, settings: settings)
            busyRowID = nil
            if case .failure(let err) = result { actionError = err.message }
        }
    }

    private func removeBranch(_ row: BranchRow) {
        busyRowID = row.id
        Task {
            let result = await removeBranchWorkspace(row, settings: settings)
            busyRowID = nil
            if case .failure(let err) = result { actionError = err.message }
        }
    }

    // Adds a not-yet-existing branch name to the selected repo's list — neither remote nor local,
    // so startBranchWorkspace creates it fresh (off the default branch) the first time it's opened.
    private func addBranch(repo: RepoEntry, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, repo.id == selectedRepoID,
              !selectedRepoBranches.contains(where: { $0.name == trimmed }) else { return }
        selectedRepoBranches.append(BranchRow(repo: repo, name: trimmed, isRemote: false, isLocal: false))
        selectedRepoBranchesFetchedFor = repo.id
    }

    private func submitNewIssue(repo: RepoEntry, title: String, body: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty else { return }
        Task {
            let result = await createIssue(repo: repo, title: trimmedTitle, body: body)
            switch result {
            case .success: refreshIssues()
            case .failure(let err): actionError = err.message
            }
        }
    }

    private func submitNewPR(repo: RepoEntry, title: String, head: String, base: String, body: String) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let trimmedHead = head.trimmingCharacters(in: .whitespaces)
        guard !trimmedTitle.isEmpty, !trimmedHead.isEmpty else { return }
        let resolvedBase = base.trimmingCharacters(in: .whitespaces).isEmpty ? repo.defaultBranch : base
        Task {
            let result = await createPR(repo: repo, title: trimmedTitle, head: trimmedHead, base: resolvedBase, body: body)
            switch result {
            case .success: refreshPRs()
            case .failure(let err): actionError = err.message
            }
        }
    }

    private func openRepoOnGitHub(_ repo: RepoEntry) {
        guard let (org, name) = gitURLComponents(repo.url),
              let url = URL(string: "https://github.com/\(org)/\(name)")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func openBranchOnGitHub(_ row: BranchRow) {
        guard let (org, name) = gitURLComponents(row.repo.url),
              let url = URL(string: "https://github.com/\(org)/\(name)/tree/\(row.name)")
        else { return }
        NSWorkspace.shared.open(url)
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

    private func toggleReviewer(_ row: PRRow, login: String, add: Bool) {
        guard let idx = prRows.firstIndex(where: { $0.id == row.id }) else { return }
        Task {
            let result = await setPRReviewer(row, login: login, add: add)
            switch result {
            case .success:
                if add {
                    if !prRows[idx].pr.reviewRequests.contains(where: { $0.login == login }) {
                        prRows[idx].pr.reviewRequests.append(TaskReviewRequest(login: login, name: nil))
                    }
                } else {
                    prRows[idx].pr.reviewRequests.removeAll { $0.login == login }
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

// Only lists already-connected repos — browsing/adding repos not yet in the workspace is the
// dedicated "+" flow (AddRepoSheet) now, not this filter.
private struct ProjectFilterMenu: View {
    let recent: [RepoEntry]
    @Binding var selected: Set<String>
    let settings: AppSettings
    let onToggle: (String) -> Void

    @State private var search = ""

    private var filtered: [RepoEntry] {
        search.isEmpty ? recent : recent.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    private func isChecked(_ repo: RepoEntry) -> Bool {
        selected.isEmpty || selected.contains(repo.id)
    }

    private func subtitle(for repo: RepoEntry) -> String {
        mainClonePath(for: repo, settings: settings) ?? repo.url
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(Color.mgMuted)
                TextField("Search repos", text: $search).textFieldStyle(.plain).font(.system(size: 14)).foregroundStyle(Color.mgLabel)
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
                    ForEach(filtered) { repo in
                        ProjectFilterRow(title: repo.name, subtitle: subtitle(for: repo), isChecked: isChecked(repo)) {
                            onToggle(repo.id)
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.bottom, 8)
            }
            .frame(maxHeight: 360)
        }
        .frame(width: 320)
        .background(Color.mgBg)
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

// The square icon buttons (add / refresh) next to the Repos & Branches search fields.
private struct ToolbarIconButton: View {
    let systemName: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mgLabel)
                .frame(width: 30, height: 30)
        }
        .buttonStyle(.plain)
        .background(Color.mgSurface)
        .overlay(RoundedRectangle(cornerRadius: 7).stroke(Color.mgBorder))
        .clipShape(RoundedRectangle(cornerRadius: 7))
    }
}

// MARK: - Add Repo / Add Branch sheets

private struct AddRepoSheet: View {
    let db: WorkspaceDB
    let listings: [TaskGHRepoListing]
    let isFetching: Bool
    @Binding var isPresented: Bool
    let onAppear: () -> Void

    @State private var search = ""

    private var alreadyAddedKeys: Set<String> {
        Set(db.repos.compactMap { gitURLComponents($0.url) }.map { "\($0.0)/\($0.1)".lowercased() })
    }
    private var filtered: [TaskGHRepoListing] {
        let base = listings.filter { listing in
            guard let parts = gitURLComponents(listing.url) else { return true }
            return !alreadyAddedKeys.contains("\(parts.0)/\(parts.1)".lowercased())
        }
        return search.isEmpty ? base : base.filter { $0.nameWithOwner.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Add Repo").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.mgLabel)
                Spacer()
                Button("Done") { isPresented = false }
                    .buttonStyle(.plain).foregroundStyle(Color.mgAccent)
            }
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                TextField("Search your GitHub repos…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 13)).foregroundStyle(Color.mgLabel)
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(Color.mgSurface).clipShape(RoundedRectangle(cornerRadius: 6))

            if isFetching && listings.isEmpty {
                ProgressView().frame(maxWidth: .infinity).padding(20)
            } else if filtered.isEmpty {
                Text("No matching repos").font(.system(size: 12)).foregroundStyle(Color.mgMuted).padding(20)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(filtered) { listing in
                            Button {
                                let name = listing.nameWithOwner.split(separator: "/").last.map(String.init) ?? listing.nameWithOwner
                                db.addRepo(name: name, url: listing.url, defaultBranch: listing.defaultBranchRef?.name ?? "main")
                            } label: {
                                HStack {
                                    Text(listing.nameWithOwner).font(.system(size: 13)).foregroundStyle(Color.mgLabel).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "plus.circle").font(.system(size: 13)).foregroundStyle(Color.mgAccent)
                                }
                                .padding(.horizontal, 8).padding(.vertical, 7)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .padding(20).frame(width: 360).background(Color.mgBg)
        .onAppear(perform: onAppear)
    }
}

private struct AddBranchSheet: View {
    let repo: RepoEntry
    @Binding var isPresented: Bool
    let onAdd: (String) -> Void

    @State private var branchName = ""
    private var trimmedName: String { branchName.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Branch").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.mgLabel)
            Text(repo.name).font(.system(size: 12)).foregroundStyle(Color.mgMuted)

            TextField("Branch name", text: $branchName)
                .textFieldStyle(.roundedBorder)

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
                .background(trimmedName.isEmpty ? Color.mgMuted : Color.mgAccent)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .disabled(trimmedName.isEmpty)
            }
        }
        .padding(28).frame(width: 360).background(Color.mgBg)
    }
}

private struct AddIssueSheet: View {
    let repos: [RepoEntry]
    @Binding var isPresented: Bool
    let onAdd: (RepoEntry, String, String) -> Void

    @State private var selectedRepoID: String?
    @State private var title = ""
    @State private var issueBody = ""

    private var selectedRepo: RepoEntry? { repos.first { $0.id == selectedRepoID } }
    private var canSubmit: Bool { selectedRepo != nil && !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Issue").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.mgLabel)

            Picker("Repo", selection: $selectedRepoID) {
                ForEach(repos) { repo in Text(repo.name).tag(Optional(repo.id)) }
            }
            .labelsHidden()

            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Description (optional)", text: $issueBody, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain).foregroundStyle(Color.mgMuted)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Button("Create") {
                    if let repo = selectedRepo { onAdd(repo, title, issueBody) }
                    isPresented = false
                }
                .buttonStyle(.plain).foregroundStyle(.black)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(canSubmit ? Color.mgAccent : Color.mgMuted)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .disabled(!canSubmit)
            }
        }
        .padding(28).frame(width: 400).background(Color.mgBg)
        .onAppear { if selectedRepoID == nil { selectedRepoID = repos.first?.id } }
    }
}

private struct AddPRSheet: View {
    let repos: [RepoEntry]
    @Binding var isPresented: Bool
    let onAdd: (RepoEntry, String, String, String, String) -> Void  // repo, title, head, base, body

    @State private var selectedRepoID: String?
    @State private var title = ""
    @State private var head = ""
    @State private var base = ""
    @State private var prBody = ""

    private var selectedRepo: RepoEntry? { repos.first { $0.id == selectedRepoID } }
    private var canSubmit: Bool {
        selectedRepo != nil
            && !title.trimmingCharacters(in: .whitespaces).isEmpty
            && !head.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Pull Request").font(.system(size: 16, weight: .semibold)).foregroundStyle(Color.mgLabel)

            Picker("Repo", selection: $selectedRepoID) {
                ForEach(repos) { repo in Text(repo.name).tag(Optional(repo.id)) }
            }
            .labelsHidden()
            .onChange(of: selectedRepoID) {
                if base.isEmpty { base = selectedRepo?.defaultBranch ?? "" }
            }

            TextField("Title", text: $title).textFieldStyle(.roundedBorder)
            TextField("Head branch (source)", text: $head).textFieldStyle(.roundedBorder)
            TextField("Base branch", text: $base).textFieldStyle(.roundedBorder)
            TextField("Description (optional)", text: $prBody, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(3...6)

            HStack {
                Spacer()
                Button("Cancel") { isPresented = false }
                    .buttonStyle(.plain).foregroundStyle(Color.mgMuted)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                Button("Create") {
                    if let repo = selectedRepo { onAdd(repo, title, head, base, prBody) }
                    isPresented = false
                }
                .buttonStyle(.plain).foregroundStyle(.black)
                .padding(.horizontal, 14).padding(.vertical, 8)
                .background(canSubmit ? Color.mgAccent : Color.mgMuted)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .disabled(!canSubmit)
            }
        }
        .padding(28).frame(width: 420).background(Color.mgBg)
        .onAppear {
            if selectedRepoID == nil { selectedRepoID = repos.first?.id }
            if base.isEmpty { base = selectedRepo?.defaultBranch ?? "" }
        }
    }
}

// Filters popover (FiltersMenuView, activeFilterTokens) and row views (IssueRowView, PRRowView)
// live in TasksPanelRows.swift.
