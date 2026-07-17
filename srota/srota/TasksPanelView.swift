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

    private var connectedRepos: [RepoEntry] { db.repos.filter { gitURLComponents($0.url) != nil } }
    private var query: Binding<String> { subTab == .issues ? $issueQuery : $prQuery }

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
        .alert("Error", isPresented: .init(get: { actionError != nil }, set: { if !$0 { actionError = nil } })) {
            Button("OK", role: .cancel) { actionError = nil }
        } message: { Text(actionError ?? "") }
    }

    // MARK: - Header / toolbar

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "checklist").font(.system(size: 13)).foregroundStyle(Color.mgAccent)
            Text("Tasks").font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mgLabel)
            Text("\(connectedRepos.count) \(connectedRepos.count == 1 ? "repo" : "repos")")
                .font(.system(size: 11).monospacedDigit()).foregroundStyle(Color.mgMuted)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.mgSurface).clipShape(Capsule())
            Spacer()
            if fetching {
                ProgressView().scaleEffect(0.6)
            } else {
                Button { refresh() } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mgMuted)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
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
            Color.clear.frame(width: 12)
            Text(subTab == .issues ? "ISSUE" : "PULL REQUEST")
                .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(Color.mgMuted)
            Spacer(minLength: 8)
            if subTab == .prs {
                Color.clear.frame(width: 18)
                Text("CHECKS").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Color.mgMuted).frame(width: 56)
                Text("MERGE").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Color.mgMuted).frame(width: 52)
            } else {
                Color.clear.frame(width: 34)
                Text("STATUS").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Color.mgMuted).frame(width: 70)
            }
            Text("UPDATED").font(.system(size: 9, weight: .semibold)).tracking(0.6)
                .foregroundStyle(Color.mgMuted).frame(width: 56, alignment: .trailing)
            Color.clear.frame(width: 22)
            Color.clear.frame(width: 42)
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(Color.mgBg)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        let isEmpty = subTab == .issues ? issueRows.isEmpty : prRows.isEmpty
        if let loadError, isEmpty {
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
                                onToggleState: { toggleIssueState(row) },
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
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

    private func toggleIssueState(_ row: IssueRow) {
        guard let idx = issueRows.firstIndex(where: { $0.id == row.id }) else { return }
        let closing = row.issue.state == "OPEN"
        Task {
            let result = await setIssueState(row, closed: closing)
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

// MARK: - Small toolbar controls

private struct SubTabButton: View {
    let title: String
    let isActive: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: isActive ? .semibold : .regular))
                .foregroundStyle(isActive ? Color.mgLabel : Color.mgMuted)
                .padding(.horizontal, 12).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .background(isActive ? Color.mgAccent.opacity(0.12) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
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
        .foregroundStyle(isActive ? Color.mgLabel : Color.mgMuted)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(isActive ? Color.mgSurface : Color.clear)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(isActive ? Color.mgBorder : Color.clear))
    }
}

// Filters popover (FiltersMenuView, activeFilterTokens) and row views (IssueRowView, PRRowView)
// live in TasksPanelRows.swift.
