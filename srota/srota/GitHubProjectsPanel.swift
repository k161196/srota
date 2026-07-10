import SwiftUI
import AppKit

// Mirrors ManagementView.swift's private Color.mg* palette — duplicated here
// since that extension is file-private and this view lives in a different file.
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

// v1: flat list of GitHub Projects (v2) for the authenticated user, drill into one for a
// flat item list. `gh project` CLI only exposes flat items — no board/view/grouping
// fidelity. Add `gh api graphql` later if that's needed; not worth it for a first cut.

private struct GHProject: Identifiable, Decodable, Hashable {
    struct Owner: Decodable, Hashable { let login: String }
    let id: String
    let number: Int
    let title: String
    let url: String
    let closed: Bool
    let shortDescription: String
    let owner: Owner
}

private struct GHProjectListResponse: Decodable {
    let projects: [GHProject]
}

private struct GHProjectItem: Identifiable, Decodable {
    let id: String
    let title: String
    let status: String?
    let assignees: [String]?
}

private struct GHProjectItemListResponse: Decodable {
    let items: [GHProjectItem]
}

private struct GHCommandError: Error { let message: String }

private func runGHProjectCommand(_ arguments: [String]) -> Result<Data, GHCommandError> {
    guard let ghPath = resolveGHPath() else {
        return .failure(GHCommandError(message: "gh CLI not found — install from https://cli.github.com"))
    }
    let p = Process(); let outPipe = Pipe(); let errPipe = Pipe()
    p.executableURL = URL(fileURLWithPath: ghPath)
    p.arguments = arguments
    p.standardOutput = outPipe; p.standardError = errPipe
    do { try p.run() } catch { return .failure(GHCommandError(message: error.localizedDescription)) }
    p.waitUntilExit()
    let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
    if p.terminationStatus != 0 {
        let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return .failure(GHCommandError(message: msg.isEmpty ? "gh project command failed" : msg))
    }
    return .success(outData)
}

struct GitHubProjectsPanel: View {
    @State private var projects: [GHProject] = []
    @State private var selected: GHProject?
    @State private var fetching = false
    @State private var error: String?

    var body: some View {
        HSplitView {
            projectListPanel
                .frame(minWidth: 220, maxWidth: 300)
            if let selected {
                GitHubProjectDetailView(project: selected)
            } else {
                Color.mgBg
                    .overlay(Text("Select a project").font(.system(size: 13)).foregroundStyle(Color.mgMuted))
            }
        }
        .onAppear { if projects.isEmpty { fetchProjects() } }
    }

    @ViewBuilder
    private var projectListPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.mgLabel)
                Text("\(projects.count)")
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Color.mgMuted)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Color.mgSurface).clipShape(Capsule())
                Spacer()
                if fetching {
                    ProgressView().scaleEffect(0.6)
                } else {
                    Button { fetchProjects() } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mgMuted)
                    }
                    .buttonStyle(.plain)
                    .help("Refresh")
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .background(Color.mgBg)
            .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }

            ScrollView {
                LazyVStack(spacing: 0) {
                    if let error {
                        Text(error)
                            .font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                            .padding(14)
                    } else if projects.isEmpty && !fetching {
                        Text("No GitHub Projects found")
                            .font(.system(size: 13)).foregroundStyle(Color.mgMuted)
                            .frame(maxWidth: .infinity).padding(.vertical, 40)
                    } else {
                        ForEach(projects) { project in
                            GHProjectRow(
                                project: project,
                                isSelected: selected?.id == project.id,
                                onSelect: { selected = project }
                            )
                        }
                    }
                }
            }
            .background(Color.mgBg)
        }
    }

    private func fetchProjects() {
        fetching = true
        error = nil
        Task.detached {
            let result = runGHProjectCommand(["project", "list", "--format", "json", "--limit", "100"])
            await MainActor.run {
                fetching = false
                switch result {
                case .failure(let err):
                    error = err.message
                case .success(let data):
                    projects = (try? JSONDecoder().decode(GHProjectListResponse.self, from: data))?.projects ?? []
                }
            }
        }
    }
}

private struct GHProjectRow: View {
    let project: GHProject
    let isSelected: Bool
    let onSelect: () -> Void
    @State private var hovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(project.title)
                .font(.system(size: 13, weight: .medium)).foregroundStyle(Color.mgLabel).lineLimit(1)
            Text("\(project.owner.login) · #\(project.number)")
                .font(.system(size: 11)).foregroundStyle(Color.mgMuted)
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .onHover { hovered = $0 }
        .glassCard(
            fill: isSelected ? Color.mgAccent.opacity(0.12) : hovered ? Color.mgRowHover : Color.mgRow,
            borderTop: isSelected ? Color.mgAccent.opacity(0.4) : Color.white.opacity(0.08),
            borderBottom: isSelected ? Color.mgAccent.opacity(0.22) : Color.white.opacity(0.04),
            radius: 7
        )
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
    }
}

private struct GitHubProjectDetailView: View {
    let project: GHProject
    @State private var items: [GHProjectItem] = []
    @State private var fetching = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(project.title)
                            .font(.system(size: 20, weight: .semibold)).foregroundStyle(Color.mgLabel)
                        Spacer()
                        Button {
                            if let url = URL(string: project.url) { NSWorkspace.shared.open(url) }
                        } label: {
                            Image(systemName: "arrow.up.forward.square")
                                .font(.system(size: 12)).foregroundStyle(Color.mgAccent)
                        }
                        .buttonStyle(.plain)
                        .help("Open on GitHub")
                    }
                    if !project.shortDescription.isEmpty {
                        Text(project.shortDescription)
                            .font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("ITEMS")
                            .font(.system(size: 10, weight: .medium)).tracking(0.8).foregroundStyle(Color.mgMuted)
                        Spacer()
                        if fetching {
                            ProgressView().scaleEffect(0.6)
                        } else {
                            Button("Fetch") { fetchItems() }
                                .buttonStyle(.plain)
                                .font(.system(size: 11)).foregroundStyle(Color.mgAccent)
                        }
                    }
                    if let error {
                        Text(error).font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                    } else if items.isEmpty && !fetching {
                        Text("No items").font(.system(size: 12)).foregroundStyle(Color.mgMuted)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(items) { item in
                                HStack(spacing: 8) {
                                    Text(item.title)
                                        .font(.system(size: 12)).foregroundStyle(Color.mgLabel).lineLimit(1)
                                    Spacer()
                                    if let status = item.status, !status.isEmpty {
                                        Text(status)
                                            .font(.system(size: 10, weight: .medium)).foregroundStyle(Color.mgMuted)
                                            .padding(.horizontal, 7).padding(.vertical, 3)
                                            .background(Color.mgMuted.opacity(0.15))
                                            .clipShape(Capsule())
                                    }
                                }
                                .padding(.horizontal, 10).padding(.vertical, 7)
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
        .onAppear { fetchItems() }
        .onChange(of: project.id) { items = []; fetchItems() }
    }

    private func fetchItems() {
        fetching = true
        error = nil
        let number = project.number
        let owner = project.owner.login
        Task.detached {
            let result = runGHProjectCommand(["project", "item-list", String(number), "--owner", owner, "--format", "json", "--limit", "100"])
            await MainActor.run {
                fetching = false
                switch result {
                case .failure(let err):
                    error = err.message
                case .success(let data):
                    items = (try? JSONDecoder().decode(GHProjectItemListResponse.self, from: data))?.items ?? []
                }
            }
        }
    }
}
