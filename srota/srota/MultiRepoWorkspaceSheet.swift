import SwiftUI

// MARK: - Worktree ensure helper

struct WorktreeEnsureError: Error { let message: String }

// Resolves the on-disk checkout for (repo, branch), reusing it if it already exists instead of
// erroring — git refuses to check out the same branch into two worktrees of the same repo.
func ensureWorktree(base: String, repo: RepoEntry, branch: String) async -> Result<String, WorktreeEnsureError> {
    let path = repoBranchPath(base: base, repoURL: repo.url, repoName: repo.name, branch: branch)
    if FileManager.default.fileExists(atPath: path) { return .success(path) }

    let isDefault = branch == repo.defaultBranch
    let defaultBranch = repo.defaultBranch
    let mainPath = repoBranchPath(base: base, repoURL: repo.url, repoName: repo.name, branch: defaultBranch)
    let hasMainClone = FileManager.default.fileExists(atPath: mainPath)
    let repoURL = repo.url

    return await Task.detached { () -> Result<String, WorktreeEnsureError> in
        func run(_ args: [String]) -> String? {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = args
            let errPipe = Pipe()
            p.standardError = errPipe
            do { try p.run() } catch { return error.localizedDescription }
            p.waitUntilExit()
            if p.terminationStatus == 0 { return nil }
            let msg = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return msg.isEmpty ? "git command failed" : msg
        }

        if isDefault {
            if let err = run(["clone", "--branch", defaultBranch, repoURL, path]) { return .failure(.init(message: err)) }
            return .success(path)
        }
        if !hasMainClone, let err = run(["clone", "--branch", defaultBranch, repoURL, mainPath]) {
            return .failure(.init(message: err))
        }
        if let err = run(["-C", mainPath, "worktree", "add", "-b", branch, path, defaultBranch]) {
            // Branch already exists (attaching to prior work) — check it out instead of creating it.
            guard err.localizedCaseInsensitiveContains("already exists") else { return .failure(.init(message: err)) }
            if let err2 = run(["-C", mainPath, "worktree", "add", path, branch]) { return .failure(.init(message: err2)) }
        }
        return .success(path)
    }.value
}

private func slugify(_ s: String) -> String {
    let replaced = s.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
    var result = String(replaced)
    while result.contains("--") { result = result.replacingOccurrences(of: "--", with: "-") }
    return result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

// MARK: - Sheet

private struct RepoBranchRow: Identifiable {
    let id = UUID()
    var repo: RepoEntry?
    var branch: String
}

private extension Color {
    static let mrBg      = Color(red: 0.067, green: 0.067, blue: 0.075)
    static let mrSurface = Color(red: 0.10,  green: 0.10,  blue: 0.11)
    static let mrBorder  = Color.white.opacity(0.07)
    static let mrAccent  = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let mrLabel   = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let mrMuted   = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.40)
}

struct MultiRepoWorkspaceSheet: View {
    let repos: [RepoEntry]
    let baseWorkingDirectory: String?
    /// name, primary directory, additional directories
    let onCreate: (String, String, [String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var featureName = ""
    @State private var notes = ""
    @State private var rows: [RepoBranchRow] = [RepoBranchRow(repo: nil, branch: "")]
    @State private var isCreating = false
    @State private var error: String?

    private var canCreate: Bool {
        !featureName.trimmingCharacters(in: .whitespaces).isEmpty
            && !rows.isEmpty
            && rows.allSatisfy { $0.repo != nil && !$0.branch.trimmingCharacters(in: .whitespaces).isEmpty }
            && baseWorkingDirectory != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("New Cross-Repo Workspace")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Color.mrLabel)
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.mrMuted)
                }
                .buttonStyle(.plain)
            }

            TextField("Feature name", text: $featureName)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(10)
                .background(Color.mrSurface)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.mrBorder))

            TextEditor(text: $notes)
                .font(.system(size: 12))
                .scrollContentBackground(.hidden)
                .frame(height: 70)
                .padding(6)
                .background(Color.mrSurface)
                .clipShape(RoundedRectangle(cornerRadius: 7))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.mrBorder))
                .overlay(alignment: .topLeading) {
                    if notes.isEmpty {
                        Text("Notes (optional)")
                            .font(.system(size: 12))
                            .foregroundStyle(Color.mrMuted)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 14)
                            .allowsHitTesting(false)
                    }
                }

            VStack(spacing: 8) {
                ForEach($rows) { $row in
                    RepoBranchRowView(
                        row: $row,
                        repos: repos,
                        isPrimary: rows.first?.id == row.id,
                        onRemove: rows.count > 1 ? { rows.removeAll { $0.id == row.id } } : nil
                    )
                }
            }

            Button {
                let defaultBranch = slugify(featureName)
                rows.append(RepoBranchRow(repo: nil, branch: defaultBranch))
            } label: {
                Label("Add another repo + branch", systemImage: "plus")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.mrMuted)
            }
            .buttonStyle(.plain)

            if let error {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button {
                    create()
                } label: {
                    if isCreating {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Create")
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.mrAccent)
                .disabled(!canCreate || isCreating)
            }
        }
        .padding(20)
        .frame(width: 480)
        .background(Color.mrBg)
        .onChange(of: featureName) { _, newValue in
            // Only steer rows still holding the auto-filled name — leave rows the user
            // has already customized alone.
            let newSlug = slugify(newValue)
            for i in rows.indices where rows[i].branch.isEmpty {
                rows[i].branch = newSlug
            }
        }
    }

    private func create() {
        guard let base = baseWorkingDirectory else { return }
        isCreating = true
        error = nil
        Task {
            var paths: [String] = []
            for row in rows {
                guard let repo = row.repo else { continue }
                switch await ensureWorktree(base: base, repo: repo, branch: row.branch) {
                case .success(let path): paths.append(path)
                case .failure(let err):
                    isCreating = false
                    error = "\(repo.name): \(err.message)"
                    return
                }
            }
            guard let primary = paths.first else { isCreating = false; return }
            isCreating = false
            onCreate(featureName, primary, Array(paths.dropFirst()))
            dismiss()
        }
    }
}

private struct RepoBranchRowView: View {
    @Binding var row: RepoBranchRow
    let repos: [RepoEntry]
    let isPrimary: Bool
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            if isPrimary {
                Image(systemName: "star.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(Color.mrAccent)
                    .help("Primary — this repo becomes the launch directory")
            }
            Menu {
                ForEach(repos) { repo in
                    Button(repo.name) { row.repo = repo }
                }
            } label: {
                Text(row.repo?.name ?? "Select repo")
                    .font(.system(size: 12))
                    .foregroundStyle(row.repo == nil ? Color.mrMuted : Color.mrLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(Color.mrSurface)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            TextField("branch", text: $row.branch)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(width: 160)
                .background(Color.mrSurface)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            if let onRemove {
                Button(action: onRemove) {
                    Image(systemName: "minus.circle")
                        .foregroundStyle(Color.mrMuted)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
