import SwiftUI

// Mirrors ManagementView.swift's private Color.mg* palette — duplicated here
// since that extension is file-private and this view lives in a different file.
private extension Color {
    static let mgBg      = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let mgSurface = Color(red: 0.10,  green: 0.10,  blue: 0.11)
    static let mgBorder  = Color.white.opacity(0.07)
    static let mgAccent  = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let mgLabel   = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let mgMuted   = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.40)
}

// PaneIssueButton (in ContentView.swift, next to PaneHeader's editor-open button) is the
// entry point — it's per-pane since each pane can have its own cwd/branch, unlike a single
// workspace-level toggle. See PaneIssueButton for the "issue/<n>" branch detection.

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

@MainActor
private final class GHIssueCache {
    static var details: [Int: GHIssueDetail] = [:]
}

struct GitHubIssueSidebar: View {
    let issueNumber: Int
    let repoPath: String
    let onDismiss: () -> Void

    @State private var detail: GHIssueDetail? = nil
    @State private var loading = false
    @State private var errorMessage: String? = nil
    @State private var showFullBody = false
    @State private var commentText = ""
    @State private var commenting = false

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
        .task(id: issueNumber) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("ISSUE #\(issueNumber)")
                    .font(.system(size: 11, weight: .semibold)).tracking(0.6)
                    .foregroundStyle(Color.mgMuted)
                Spacer()
                Button { Task { await load(force: true) } } label: {
                    Image(systemName: "arrow.clockwise").font(.system(size: 11))
                }
                .buttonStyle(.plain).foregroundStyle(Color.mgAccent)
                Button(action: onDismiss) {
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
            Text(showFullBody || detail.body.count < 240 ? detail.body : String(detail.body.prefix(240)) + "…")
                .font(.system(size: 12)).foregroundStyle(Color.mgLabel)
            if detail.body.count >= 240 {
                Button(showFullBody ? "show less" : "show more") { showFullBody.toggle() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.mgAccent)
            }
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
                    Text(comment.body).font(.system(size: 12)).foregroundStyle(Color.mgLabel)
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
        if !force, let cached = GHIssueCache.details[issueNumber] {
            detail = cached
        } else {
            loading = true
            errorMessage = nil
            guard let org = repoOrg() else {
                loading = false
                errorMessage = "Not a GitHub repo"
                return
            }
            let (org2, repo) = org
            let (detailData, fetchError) = await Task.detached { fetchIssueDetailData(number: issueNumber, org: org2, repo: repo) }.value
            loading = false
            if let detailData, let fetchedDetail = try? JSONDecoder().decode(GHIssueDetail.self, from: detailData) {
                detail = fetchedDetail
                GHIssueCache.details[issueNumber] = fetchedDetail
            } else {
                errorMessage = fetchError ?? "Could not load issue"
            }
        }
    }

    private func addComment() async {
        commenting = true
        guard let org = repoOrg() else {
            commenting = false
            return
        }
        let (org2, repo) = org
        let number = issueNumber
        let text = commentText
        let ok = await Task.detached { postComment(number: number, org: org2, repo: repo, body: text) }.value
        commenting = false
        if ok {
            commentText = ""
            await load(force: true)
        }
    }

    private func repoOrg() -> (String, String)? {
        guard let remote = runGit(["-C", repoPath, "remote", "get-url", "origin"]) else { return nil }
        return gitURLComponents(remote)
    }
}

nonisolated private func fetchIssueDetailData(number: Int, org: String, repo: String) -> (Data?, String?) {
    guard let ghPath = resolveGHPath() else {
        return (nil, "gh CLI not found — install from https://cli.github.com")
    }
    let p = Process(); let outPipe = Pipe(); let errPipe = Pipe()
    p.executableURL = URL(fileURLWithPath: ghPath)
    p.arguments = ["issue", "view", String(number), "--repo", "\(org)/\(repo)",
                   "--json", "title,body,state,url,labels,author,comments"]
    p.standardOutput = outPipe; p.standardError = errPipe
    do { try p.run() } catch { return (nil, error.localizedDescription) }
    p.waitUntilExit()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    guard p.terminationStatus == 0 else {
        let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (nil, msg.isEmpty ? "gh issue view failed" : msg)
    }
    return (outData, nil)
}

nonisolated private func postComment(number: Int, org: String, repo: String, body: String) -> Bool {
    guard let ghPath = resolveGHPath() else { return false }
    let p = Process(); let errPipe = Pipe()
    p.executableURL = URL(fileURLWithPath: ghPath)
    p.arguments = ["issue", "comment", String(number), "--repo", "\(org)/\(repo)", "--body", body]
    p.standardError = errPipe
    do { try p.run() } catch { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
}
