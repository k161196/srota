import SwiftUI
import AppKit

// Mirrors ManagementView.swift's private Color.mg* palette — duplicated here since that extension
// is file-private and this view lives in a different file.
private extension Color {
    static let mgBg      = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let mgSurface = Color(red: 0.10,  green: 0.10,  blue: 0.11)
    static let mgBorder  = Color.white.opacity(0.07)
    static let mgAccent  = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let mgLabel   = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let mgMuted   = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.40)
}

// PaneIssueButton (in ContentView.swift, next to PaneHeader's editor-open button) is the entry
// point — it's per-pane since each pane can have its own cwd/branch, unlike a single
// workspace-level toggle. See PaneIssueButton for repo/Branch Issue detection.
//
// Navigation (Issue List vs. a selected issue) is remembered per-Pane for the lifetime of the
// app session — see IssuePopoverNavigationStore below. See IssuePopoverLogic.swift for the pure
// list-composition/navigation-restore rules this view just wires up.

private struct GHIssueDetail: Decodable, Sendable {
    let title: String
    let body: String
    let state: String
    let url: String
    let labels: [Label]
    let author: Author
    let comments: [GHComment]
    struct Label: Decodable, Sendable { let name: String }
    struct Author: Decodable, Sendable { let login: String }
}

private struct GHComment: Identifiable, Decodable, Sendable {
    let id: String
    let author: Author
    let body: String
    let createdAt: String
    struct Author: Decodable, Sendable { let login: String }
}

private func relativeTime(_ iso: String) -> String {
    guard let date = ISO8601DateFormatter().date(from: iso) else { return "" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .abbreviated
    return formatter.localizedString(for: date, relativeTo: Date())
}

// Renders GitHub-flavored Markdown via SwiftUI's native AttributedString(markdown:) support,
// falling back to plain text if parsing fails (e.g. malformed input) rather than showing nothing.
private func markdownText(_ raw: String) -> Text {
    if let attributed = try? AttributedString(markdown: raw) {
        return Text(attributed)
    }
    return Text(raw)
}

@MainActor
private final class GHIssueDetailCache {
    static var details: [IssueDetailCacheKey: GHIssueDetail] = [:]
}

// IssuePopoverNavigationStore lives in IssuePopoverLogic.swift — it wraps a pure logic function
// but has no SwiftUI/AppKit dependency itself, so it's kept in the plain Foundation file that
// the swiftc self-check compiles (see scripts/test-issue-popover-logic.swift).

struct IssuePopoverView: View {
    let paneID: String
    let repoPath: String
    let repo: IssueRepoIdentity
    let branchIssueNumber: Int?
    let onDismiss: () -> Void

    @State private var destination: IssuePopoverDestination = .list
    @State private var openIssues: [GHIssueListItem] = []
    @State private var branchIssue: GHIssueListItem? = nil
    @State private var loading = false
    @State private var errorMessage: String? = nil
    @State private var isAdding = false

    var body: some View {
        Group {
            switch destination {
            case .list:
                IssueListPane(
                    branchIssue: branchIssue,
                    openIssues: openIssues,
                    loading: loading,
                    errorMessage: errorMessage,
                    isAdding: $isAdding,
                    repo: repo,
                    onSelect: select,
                    onRefresh: { Task { await load(force: true) } },
                    onCreated: created,
                    onClose: close
                )
            case .detail(let number):
                IssueDetailPane(
                    issueNumber: number,
                    repo: repo,
                    repoPath: repoPath,
                    onBack: back,
                    onClose: close
                )
            }
        }
        .background(Color.mgBg)
        .task(id: repo) {
            destination = IssuePopoverNavigationStore.shared.destination(paneID: paneID, repo: repo)
            await load()
        }
    }

    private func select(_ number: Int) {
        destination = .detail(number)
        IssuePopoverNavigationStore.shared.setDestination(paneID: paneID, .detail(number))
    }

    private func created(_ number: Int) {
        Task { await load(force: true) }
        select(number)
    }

    private func back() {
        destination = .list
        IssuePopoverNavigationStore.shared.setDestination(paneID: paneID, .list)
    }

    // Close never changes the remembered destination itself — EXCEPT an in-progress Add draft,
    // which must be discarded and never mistaken for remembered navigation (story 27).
    private func close() {
        let resolved = IssuePopoverLogic.destinationAfterClose(wasAdding: isAdding, current: destination)
        if isAdding {
            isAdding = false
            destination = resolved
            IssuePopoverNavigationStore.shared.setDestination(paneID: paneID, resolved)
        }
        onDismiss()
    }

    private func load(force: Bool = false) async {
        loading = true
        errorMessage = nil
        let repoSnapshot = repo
        let branchNumber = branchIssueNumber
        let (openResult, fetchedBranchIssue) = await Task.detached {
            (fetchOpenIssuesData(repo: repoSnapshot), branchNumber.flatMap { fetchBranchIssueListItem(number: $0, repo: repoSnapshot) })
        }.value
        loading = false
        switch openResult {
        case .success(let issues):
            openIssues = IssuePopoverLogic.composeOpenIssues(issues, branchIssueNumber: branchNumber)
            branchIssue = fetchedBranchIssue
        case .failure(let err):
            errorMessage = err.message
        }
    }
}

// MARK: - Issue List

private struct IssueListPane: View {
    let branchIssue: GHIssueListItem?
    let openIssues: [GHIssueListItem]
    let loading: Bool
    let errorMessage: String?
    @Binding var isAdding: Bool
    let repo: IssueRepoIdentity
    let onSelect: (Int) -> Void
    let onRefresh: () -> Void
    let onCreated: (Int) -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.mgBorder)
            if isAdding {
                AddIssueInlineForm(repo: repo, isAdding: $isAdding, onCreated: onCreated)
            } else {
                listBody
            }
        }
    }

    private var header: some View {
        HStack {
            Text("ISSUES").font(.system(size: 11, weight: .semibold)).tracking(0.6).foregroundStyle(Color.mgMuted)
            Spacer()
            if !isAdding {
                Button { isAdding = true } label: {
                    Image(systemName: "plus").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Color.mgAccent).help("New issue")
                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Color.mgAccent).help("Refresh")
            }
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(Color.mgMuted)
        }
        .padding(12)
    }

    @ViewBuilder
    private var listBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let errorMessage {
                    Text(errorMessage).font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                } else if loading && branchIssue == nil && openIssues.isEmpty {
                    Text("Loading…").font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                } else if branchIssue == nil && openIssues.isEmpty {
                    Text("No open issues").font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                } else {
                    if let branchIssue {
                        section(title: "BRANCH ISSUE") {
                            IssueListRow(item: branchIssue, onSelect: { onSelect(branchIssue.number) })
                        }
                    }
                    if !openIssues.isEmpty {
                        section(title: "OPEN ISSUES") {
                            ForEach(openIssues) { item in
                                IssueListRow(item: item, onSelect: { onSelect(item.number) })
                            }
                        }
                    }
                }
            }
            .padding(12)
        }
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.system(size: 10, weight: .medium)).tracking(0.8).foregroundStyle(Color.mgMuted)
            content()
        }
    }
}

private struct IssueListRow: View {
    let item: GHIssueListItem
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Circle().fill(item.state == "OPEN" ? Color.green : Color.purple).frame(width: 6, height: 6)
                    Text("#\(item.number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.mgMuted)
                    Text(item.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mgLabel).lineLimit(1)
                }
                if !item.labels.isEmpty {
                    Text(item.labels.map(\.name).joined(separator: ", "))
                        .font(.system(size: 10)).foregroundStyle(Color.mgMuted).lineLimit(1)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Add Issue (inline — the popover's own transient Add mode, not a separate sheet)

private struct AddIssueInlineForm: View {
    let repo: IssueRepoIdentity
    @Binding var isAdding: Bool
    let onCreated: (Int) -> Void

    @State private var title = ""
    @State private var issueBody = ""
    @State private var submitting = false
    @State private var errorMessage: String? = nil

    private var canSubmit: Bool { !title.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("New Issue").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mgLabel)

                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12)).foregroundStyle(Color.mgLabel)
                    .padding(8).background(Color.mgSurface)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                // Plain raw-Markdown editor — no formatting toolbar or preview by design.
                TextEditor(text: $issueBody)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(Color.mgLabel)
                    .scrollContentBackground(.hidden)
                    .padding(6).frame(height: 140)
                    .background(Color.mgSurface)
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                if let errorMessage {
                    Text(errorMessage).font(.system(size: 11)).foregroundStyle(.red)
                }

                HStack {
                    Spacer()
                    Button("Cancel") { cancel() }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                    if submitting {
                        ProgressView().scaleEffect(0.6).frame(width: 28)
                    } else {
                        Button("Create") { Task { await submit() } }
                            .buttonStyle(.plain)
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(.black)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .background(canSubmit ? Color.mgAccent : Color.mgMuted)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .disabled(!canSubmit)
                    }
                }
            }
            .padding(12)
        }
    }

    private func cancel() {
        title = ""; issueBody = ""; errorMessage = nil
        isAdding = false
    }

    private func submit() async {
        submitting = true
        errorMessage = nil
        let repoEntry = RepoEntry(
            id: "\(repo.org)/\(repo.name)", name: repo.name,
            url: "https://github.com/\(repo.org)/\(repo.name)", defaultBranch: ""
        )
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)
        let result = await createIssue(repo: repoEntry, title: trimmedTitle, body: issueBody)
        submitting = false
        switch result {
        case .success(let number):
            title = ""; issueBody = ""
            isAdding = false
            onCreated(number)
        case .failure(let err):
            errorMessage = err.message
        }
    }
}

// MARK: - Issue Detail

private struct IssueDetailPane: View {
    let issueNumber: Int
    let repo: IssueRepoIdentity
    let repoPath: String
    let onBack: () -> Void
    let onClose: () -> Void

    @State private var detail: GHIssueDetail? = nil
    @State private var loading = false
    @State private var errorMessage: String? = nil
    @State private var commentText = ""
    @State private var commenting = false

    private var cacheKey: IssueDetailCacheKey { IssueDetailCacheKey(repo: repo, number: issueNumber) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Color.mgBorder)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    if let errorMessage {
                        Text(errorMessage).font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                    } else if let detail {
                        issueBodySection(detail)
                        Divider().background(Color.mgBorder)
                        commentsSection(detail)
                    } else {
                        Text(loading ? "Loading…" : "").font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                    }
                }
                .padding(12)
            }
            Divider().background(Color.mgBorder)
            commentComposer
        }
        .background(Color.mgBg)
        .task(id: cacheKey) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Color.mgAccent).help("Back to Issue List")
                Text("ISSUE #\(issueNumber)")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Color.mgMuted)
                Spacer()
                Button { Task { await load(force: true) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Color.mgAccent).help("Refresh")
                Button(action: onClose) {
                    Image(systemName: "xmark").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Color.mgMuted)
            }
            if let detail {
                Text(detail.title).font(.system(size: 13, weight: .medium)).foregroundStyle(Color.mgLabel)
                HStack(spacing: 6) {
                    Circle().fill(detail.state == "OPEN" ? Color.green : Color.purple).frame(width: 6, height: 6)
                    Text(detail.state.lowercased()).font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                    Spacer()
                    Button("open in gh") { if let url = URL(string: detail.url) { NSWorkspace.shared.open(url) } }
                        .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.mgAccent)
                }
            }
        }
        .padding(12)
    }

    @ViewBuilder
    private func issueBodySection(_ detail: GHIssueDetail) -> some View {
        if !detail.labels.isEmpty {
            Text("Labels: \(detail.labels.map(\.name).joined(separator: ", "))")
                .font(.system(size: 11)).foregroundStyle(Color.mgMuted)
        }
        Text("Author: @\(detail.author.login)")
            .font(.system(size: 11)).foregroundStyle(Color.mgMuted)
        if !detail.body.isEmpty {
            markdownText(detail.body)
                .font(.system(size: 12)).foregroundStyle(Color.mgLabel)
        }
    }

    @ViewBuilder
    private func commentsSection(_ detail: GHIssueDetail) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("COMMENTS").font(.system(size: 10, weight: .medium)).tracking(0.8).foregroundStyle(Color.mgMuted)
            if detail.comments.isEmpty {
                Text("No comments yet").font(.system(size: 12)).foregroundStyle(Color.mgMuted)
            }
            ForEach(detail.comments) { comment in
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text("@\(comment.author.login)").font(.system(size: 11, weight: .medium)).foregroundStyle(Color.mgLabel)
                        Text(relativeTime(comment.createdAt)).font(.system(size: 10)).foregroundStyle(Color.mgMuted)
                    }
                    markdownText(comment.body).font(.system(size: 12)).foregroundStyle(Color.mgLabel)
                }
                if comment.id != detail.comments.last?.id { Divider().background(Color.mgBorder) }
            }
        }
    }

    private var commentComposer: some View {
        VStack(alignment: .leading, spacing: 6) {
            TextEditor(text: $commentText)
                .font(.system(size: 12)).foregroundStyle(Color.mgLabel)
                .scrollContentBackground(.hidden)
                .padding(6).frame(height: 54)
                .background(Color.mgSurface)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.mgBorder))
                .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer()
                if commenting {
                    ProgressView().scaleEffect(0.6).frame(width: 28)
                } else {
                    Button("Add Comment") { Task { await addComment() } }
                        .buttonStyle(.plain)
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.black)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(commentText.isEmpty ? Color.mgMuted : Color.mgAccent)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .disabled(commentText.isEmpty)
                }
            }
        }
        .padding(12)
    }

    private func load(force: Bool = false) async {
        if !force, let cached = GHIssueDetailCache.details[cacheKey] {
            detail = cached
            return
        }
        loading = true
        errorMessage = nil
        let repoSnapshot = repo
        let number = issueNumber
        let (detailData, fetchError) = await Task.detached { fetchIssueDetailData(number: number, repo: repoSnapshot) }.value
        loading = false
        if let detailData, let fetchedDetail = try? JSONDecoder().decode(GHIssueDetail.self, from: detailData) {
            detail = fetchedDetail
            GHIssueDetailCache.details[cacheKey] = fetchedDetail
        } else {
            errorMessage = fetchError ?? "Could not load issue"
        }
    }

    private func addComment() async {
        commenting = true
        let repoSnapshot = repo
        let number = issueNumber
        let text = commentText
        let ok = await Task.detached { postComment(number: number, repo: repoSnapshot, body: text) }.value
        commenting = false
        if ok {
            commentText = ""
            await load(force: true)
        }
    }
}

// MARK: - gh CLI plumbing (all four share TasksPanel.swift's runGH — one Process/Pipe/exit-status
// implementation instead of a hand-rolled copy per call site)

nonisolated private func fetchOpenIssuesData(repo: IssueRepoIdentity) -> Result<[GHIssueListItem], TaskGHError> {
    let args = ["issue", "list", "--repo", "\(repo.org)/\(repo.name)", "--state", "open",
                "--json", "number,title,state,url,labels,updatedAt", "--limit", String(IssuePopoverLogic.openIssuesLimit)]
    return runGH(args).flatMap { data in
        guard let issues = try? JSONDecoder().decode([GHIssueListItem].self, from: data) else {
            return .failure(TaskGHError(message: "Could not parse issue list"))
        }
        return .success(issues)
    }
}

// Fetched independently of the open-issues list (rather than derived from it) so a closed issue,
// or an open issue outside the 50-row recent working set, can still be promoted as the Branch Issue.
nonisolated private func fetchBranchIssueListItem(number: Int, repo: IssueRepoIdentity) -> GHIssueListItem? {
    let args = ["issue", "view", String(number), "--repo", "\(repo.org)/\(repo.name)",
                "--json", "number,title,state,url,labels,updatedAt"]
    guard case .success(let data) = runGH(args) else { return nil }
    return try? JSONDecoder().decode(GHIssueListItem.self, from: data)
}

nonisolated private func fetchIssueDetailData(number: Int, repo: IssueRepoIdentity) -> (Data?, String?) {
    let args = ["issue", "view", String(number), "--repo", "\(repo.org)/\(repo.name)",
                "--json", "title,body,state,url,labels,author,comments"]
    switch runGH(args) {
    case .success(let data): return (data, nil)
    case .failure(let err): return (nil, err.message)
    }
}

nonisolated private func postComment(number: Int, repo: IssueRepoIdentity, body: String) -> Bool {
    let args = ["issue", "comment", String(number), "--repo", "\(repo.org)/\(repo.name)", "--body", body]
    if case .success = runGH(args) { return true }
    return false
}
