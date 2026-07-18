import SwiftUI
import AppKit

private extension Color {
    static let mgBg = tasksBg
    static let mgSurface = tasksSurface
    static let mgBorder = tasksBorder
    static let mgAccent = tasksAccent
    static let mgLabel = tasksLabel
    static let mgMuted = tasksMuted
    static let mgRowHover = tasksRowHover
}

// MARK: - Filters popover

struct FilterToken: Identifiable {
    let prefix: String
    let label: String
    let value: String
    var id: String { prefix + value }
}

func activeFilterTokens(_ query: String, subTab: TasksPanel.SubTab) -> [FilterToken] {
    var tokens: [FilterToken] = []
    if let v = queryValue("assignee:", in: query) { tokens.append(FilterToken(prefix: "assignee:", label: "Assignee", value: v)) }
    if let v = queryValue("author:", in: query) { tokens.append(FilterToken(prefix: "author:", label: "Author", value: v)) }
    if let v = queryValue("label:", in: query) { tokens.append(FilterToken(prefix: "label:", label: "Label", value: v)) }
    if subTab == .prs, let v = queryValue("review-requested:", in: query) {
        tokens.append(FilterToken(prefix: "review-requested:", label: "Review from", value: v))
    }
    return tokens
}

// Reference shows a nested flyout: a main list of filter kinds (Status/Author/Label/Assignee),
// each drilling into its own search+list sub-panel with a "Back" header — not inline sections.
private enum FilterSection { case status, author, label, assigneeOrReviewer }

struct FiltersMenuView: View {
    let subTab: TasksPanel.SubTab
    @Binding var query: String
    let assigneeSuggestions: [String]
    let authorSuggestions: [String]
    let labelSuggestions: [String]
    let reviewerSuggestions: [String]
    let onApply: () -> Void

    @State private var section: FilterSection? = nil

    private func statusIsSelected(_ option: String) -> Bool {
        let tokens = Set(query.split(separator: " ").map(String.init))
        switch option {
        case "Open": return tokens.contains("is:open")
        case "Closed": return tokens.contains("is:closed")
        default: return !tokens.contains("is:open") && !tokens.contains("is:closed")
        }
    }

    private var statusSummary: String {
        statusIsSelected("Open") ? "Open" : (statusIsSelected("Closed") ? "Closed" : "All")
    }

    private func setStatus(_ option: String) {
        var tokens = query.split(separator: " ").map(String.init).filter { $0 != "is:open" && $0 != "is:closed" }
        if option == "Open" { tokens.append("is:open") }
        else if option == "Closed" { tokens.append("is:closed") }
        query = tokens.joined(separator: " ")
        onApply()
    }

    var body: some View {
        Group {
            if let section { sectionDetail(section) } else { mainList }
        }
        .frame(width: 260)
    }

    private var mainList: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(subTab == .issues ? "FILTER ISSUES" : "FILTER PULL REQUESTS")
                .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(Color.mgMuted)
                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
            FilterMainRow(title: "Status", value: statusSummary) { section = .status }
            FilterMainRow(title: "Author", value: queryValue("author:", in: query) ?? "Any") { section = .author }
            FilterMainRow(title: "Label", value: queryValue("label:", in: query) ?? "Any") { section = .label }
            FilterMainRow(
                title: subTab == .issues ? "Assignee" : "Review from",
                value: queryValue(subTab == .issues ? "assignee:" : "review-requested:", in: query) ?? "Any"
            ) { section = .assigneeOrReviewer }
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func sectionDetail(_ section: FilterSection) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            FilterBackRow { self.section = nil }
            switch section {
            case .status:
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(["Open", "Closed", "All"], id: \.self) { option in
                        FilterValueRow(title: option, subtitle: nil, isSelected: statusIsSelected(option)) { setStatus(option) }
                    }
                }
                .padding(.bottom, 4)
            case .author:
                FilterValuePicker(prefix: "author:", suggestions: authorSuggestions, query: $query, onApply: onApply)
            case .label:
                FilterValuePicker(prefix: "label:", suggestions: labelSuggestions, query: $query, onApply: onApply, showCurrentUser: false)
            case .assigneeOrReviewer:
                FilterValuePicker(
                    prefix: subTab == .issues ? "assignee:" : "review-requested:",
                    suggestions: subTab == .issues ? assigneeSuggestions : reviewerSuggestions,
                    query: $query, onApply: onApply
                )
            }
        }
    }
}

private struct FilterMainRow: View {
    let title: String
    let value: String
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).font(.system(size: 12)).foregroundStyle(Color.mgLabel)
                Spacer()
                Text(value).font(.system(size: 11)).foregroundStyle(Color.mgMuted).lineLimit(1)
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.mgMuted)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovered ? Color.mgRowHover : Color.clear)
        .onHover { hovered = $0 }
    }
}

private struct FilterBackRow: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                Text("Back").font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.mgMuted)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .buttonStyle(.plain)
    }
}

private struct FilterValueRow: View {
    let title: String
    let subtitle: String?
    let isSelected: Bool
    let action: () -> Void
    @State private var hovered = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.system(size: 12)).foregroundStyle(Color.mgLabel)
                    if let subtitle {
                        Text(subtitle).font(.system(size: 9)).foregroundStyle(Color.mgMuted)
                    }
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(Color.mgAccent)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovered ? Color.mgRowHover : Color.clear)
        .onHover { hovered = $0 }
    }
}

private struct FilterValuePicker: View {
    let prefix: String
    let suggestions: [String]
    @Binding var query: String
    let onApply: () -> Void
    var showCurrentUser: Bool = true
    @State private var search = ""

    private var selected: String? { queryValue(prefix, in: query) }
    private var options: [String] { showCurrentUser ? ["@me"] + suggestions : suggestions }
    private var filtered: [String] {
        search.isEmpty ? options : options.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                TextField(showCurrentUser ? "Filter or type a login…" : "Filter labels…", text: $search)
                    .textFieldStyle(.plain).font(.system(size: 12)).foregroundStyle(Color.mgLabel)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(Color.mgSurface).clipShape(RoundedRectangle(cornerRadius: 6))
            .padding(10)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered, id: \.self) { value in
                        FilterValueRow(
                            title: value,
                            subtitle: (showCurrentUser && value == "@me") ? "Current user" : nil,
                            isSelected: selected == value
                        ) {
                            query = querySetting(prefix, value: value, in: query)
                            onApply()
                        }
                    }
                }
            }
            .frame(maxHeight: 220)

            if selected != nil {
                Button("Clear") { query = queryRemoving(prefix, from: query); onApply() }
                    .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.mgAccent)
                    .padding(.horizontal, 12).padding(.vertical, 8)
            }
        }
        .padding(.bottom, 4)
    }
}

// MARK: - Shared row components (avatar, ID badge, action buttons)

// Row-level width constants shared with TasksPanelView's tableHeaderRow so columns line up.
enum TaskRowMetrics {
    static let idWidth: CGFloat = 54
    static let personWidth: CGFloat = 64
    static let statusWidth: CGFloat = 78
    // Branches can show both the "local" and "remote" tags side by side (unlike Issues'/Repos'
    // single-badge status column), so it gets its own, wider column.
    static let branchStatusWidth: CGFloat = 130
    static let checksWidth: CGFloat = 68
    static let mergeWidth: CGFloat = 68
    static let updatedWidth: CGFloat = 56
    // Wide enough for the longest action-pill title ("Worktree") or, alternately, "Open" plus
    // the branch row's extra trash button — the two never appear together (trash only shows once
    // cloned, at which point the title is back down to "Open").
    static let actionWidth: CGFloat = 140
}

private struct AvatarView: View {
    let url: URL?
    var size: CGFloat = 18

    private var placeholder: some View {
        Circle().fill(Color.mgMuted.opacity(0.15))
            .overlay(Image(systemName: "person.fill").font(.system(size: size * 0.45)).foregroundStyle(Color.mgMuted))
    }

    var body: some View {
        Group {
            if let url {
                AsyncImage(url: url) { phase in
                    if case .success(let image) = phase {
                        image.resizable().aspectRatio(contentMode: .fill)
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }
}

// The reference's issue-state glyph is an octicon-style ring with a filled center dot —
// closest built-in SF Symbol doesn't quite match, so it's drawn directly.
private struct DotRingIcon: View {
    let color: Color
    var diameter: CGFloat = 12
    var body: some View {
        ZStack {
            Circle().strokeBorder(color, lineWidth: 1.3)
            Circle().fill(color).frame(width: diameter * 0.32, height: diameter * 0.32)
        }
        .frame(width: diameter, height: diameter)
    }
}

// The white pill "Start →" / "Open →" / "Worktree →" action — the one shared primary-action
// button used by every row (Issues, PRs, Branches), always paired with RowMoreMenu.
private struct RowActionPill: View {
    let title: String
    let enabled: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).font(.system(size: 11, weight: .semibold)).lineLimit(1).fixedSize()
                Image(systemName: "arrow.right").font(.system(size: 9, weight: .semibold))
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? Color.black.opacity(0.85) : Color.mgMuted)
        .background(enabled ? Color.white.opacity(0.92) : Color.mgSurface)
        .clipShape(Capsule())
        .disabled(!enabled)
    }
}

// The "⋮" icon-only overflow menu paired with RowActionPill — the one shared "primary action +
// more" component used by every row (Issues, PRs, Branches). `onRemove` is only passed by
// Branches (worktree cleanup); everyone else leaves it nil and just gets "Open in browser".
private struct RowMoreMenu: View {
    let onOpenGitHub: () -> Void
    var onRemove: (() -> Void)? = nil
    @State private var hovered = false
    var body: some View {
        Menu {
            Button("Open in browser") { onOpenGitHub() }
            if let onRemove {
                Button("Remove worktree", role: .destructive) { onRemove() }
            }
        } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(Color.mgMuted)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 22, height: 22)
        .background(hovered ? Color.mgRowHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .onHover { hovered = $0 }
    }
}

private struct RepoTag: View {
    let name: String
    var body: some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(Color.mgMuted.opacity(0.5)).frame(width: 7, height: 7)
            Text(name).font(.system(size: 10)).foregroundStyle(Color.mgMuted)
        }
    }
}

// MARK: - Row views

struct IssueRowView: View {
    let row: IssueRow
    let isBusy: Bool
    let canStart: Bool
    let hasWorkspace: Bool
    let onStart: () -> Void
    let onOpenGitHub: () -> Void
    let onToggleState: (String?) -> Void
    let onAssigneeAction: (String, Bool) -> Void

    @State private var hovered = false
    private var isOpen: Bool { row.issue.state == "OPEN" }
    private static let openColor = Color(red: 0.35, green: 0.85, blue: 0.55)
    private static let closedColor = Color(red: 0.65, green: 0.45, blue: 0.95)

    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 5) {
                if isOpen {
                    DotRingIcon(color: Self.openColor, diameter: 13)
                } else {
                    Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Self.closedColor)
                }
                Text("#\(row.issue.number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.mgMuted)
            }
            .frame(width: TaskRowMetrics.idWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.issue.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mgLabel).lineLimit(1)
                    RepoTag(name: row.repo.name)
                }
                HStack(spacing: 6) {
                    Text(row.issue.author.login).font(.system(size: 10)).foregroundStyle(Color.mgMuted).lineLimit(1)
                    ForEach(row.issue.labels, id: \.name) { label in
                        Text(label.name).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.mgMuted)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.mgMuted.opacity(0.15)).clipShape(Capsule())
                    }
                }
            }
            Spacer(minLength: 8)

            AssigneeMenu(repo: row.repo, assignees: row.issue.assignees, onAssigneeAction: onAssigneeAction)
                .frame(width: TaskRowMetrics.personWidth, alignment: .leading)

            StatusMenu(isOpen: isOpen, onSelect: onToggleState)
                .frame(width: TaskRowMetrics.statusWidth)

            Text(taskRelativeTime(row.issue.updatedAt))
                .font(.system(size: 10)).foregroundStyle(Color.mgMuted)
                .frame(width: TaskRowMetrics.updatedWidth, alignment: .trailing)

            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().scaleEffect(0.6)
                } else {
                    RowActionPill(title: hasWorkspace ? "Open" : "Start", enabled: canStart, action: onStart)
                        .help(canStart ? "" : "Clone \(row.repo.defaultBranch) first in Repos")
                }
                RowMoreMenu(onOpenGitHub: onOpenGitHub)
            }
            .frame(width: TaskRowMetrics.actionWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 14)
        .background(hovered ? Color.mgRowHover : Color.clear)
        .onHover { hovered = $0 }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
    }
}

// The assignee dropdown needs a real avatar image in its label. Wrapping AsyncImage in a
// Menu's custom label is unreliable on macOS — the menu button relayouts around the image's
// native pixel size once it loads (blowing up the row) and can double the disclosure chevron.
// A plain Button + .popover sidesteps both: it's an ordinary view tree with no NSPopUpButton
// relayout quirks.
private struct AssigneeMenu: View {
    let repo: RepoEntry
    let assignees: [TaskActor]
    let onAssigneeAction: (String, Bool) -> Void

    @State private var showMenu = false
    @State private var candidates: [TaskActor] = []
    @State private var loading = false

    private func isAssigned(_ login: String) -> Bool {
        assignees.contains { $0.login == login }
    }

    private func fetchIfNeeded() {
        guard candidates.isEmpty, !loading else { return }
        loading = true
        Task {
            candidates = await fetchAssignableUsers(repo: repo)
            loading = false
        }
    }

    var body: some View {
        Button { showMenu = true } label: {
            HStack(spacing: 3) {
                AvatarView(url: assignees.first?.avatarURL, size: 20)
                Image(systemName: "chevron.down").font(.system(size: 7)).foregroundStyle(Color.mgMuted)
            }
        }
        .buttonStyle(.plain)
        .help(assignees.isEmpty ? "Unassigned" : assignees.map(\.login).joined(separator: ", "))
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            Group {
                if loading && candidates.isEmpty {
                    ProgressView().padding(20)
                } else if candidates.isEmpty {
                    Text("Couldn't load assignees").font(.system(size: 12)).foregroundStyle(Color.mgMuted).padding(16)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(candidates, id: \.login) { user in
                                AssigneeRow(user: user, isAssigned: isAssigned(user.login)) {
                                    onAssigneeAction(user.login, !isAssigned(user.login))
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 280)
                }
            }
            .frame(width: 220)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .onAppear(perform: fetchIfNeeded)
        }
    }
}

private struct AssigneeRow: View {
    let user: TaskActor
    let isAssigned: Bool
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                ZStack {
                    if isAssigned {
                        Circle().fill(Color.mgLabel)
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Color.mgBg)
                    } else {
                        RoundedRectangle(cornerRadius: 4).stroke(Color.mgMuted.opacity(0.5), lineWidth: 1.3)
                    }
                }
                .frame(width: 16, height: 16)

                AvatarView(url: user.avatarURL, size: 20)
                Text(user.login).font(.system(size: 12)).foregroundStyle(Color.mgLabel).lineLimit(1)
                Spacer(minLength: 4)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(hovered ? Color.mgRowHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }
}

// PR reviewers cell, same Button + .popover shape as AssigneeMenu above (candidates come from the
// same "assignees" endpoint — GitHub has no separate "requestable reviewers" list — and the same
// AssigneeRow renders each candidate, just checked against reviewRequests instead of assignees).
private struct ReviewerMenu: View {
    let repo: RepoEntry
    let reviewRequests: [TaskReviewRequest]
    let onReviewerAction: (String, Bool) -> Void

    @State private var showMenu = false
    @State private var candidates: [TaskActor] = []
    @State private var loading = false

    private func isRequested(_ login: String) -> Bool {
        reviewRequests.contains { $0.login == login }
    }

    private func fetchIfNeeded() {
        guard candidates.isEmpty, !loading else { return }
        loading = true
        Task {
            candidates = await fetchAssignableUsers(repo: repo)
            loading = false
        }
    }

    var body: some View {
        Button { showMenu = true } label: {
            HStack(spacing: 3) {
                if let first = reviewRequests.first {
                    AvatarView(url: first.avatarURL, size: 18)
                } else {
                    Image(systemName: "person.crop.circle.badge.plus").font(.system(size: 15)).foregroundStyle(Color.mgMuted)
                }
                Image(systemName: "chevron.down").font(.system(size: 7)).foregroundStyle(Color.mgMuted)
            }
        }
        .buttonStyle(.plain)
        .help(reviewRequests.isEmpty ? "No reviewers requested" : reviewRequests.map(\.displayName).joined(separator: ", "))
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            Group {
                if loading && candidates.isEmpty {
                    ProgressView().padding(20)
                } else if candidates.isEmpty {
                    Text("Couldn't load reviewers").font(.system(size: 12)).foregroundStyle(Color.mgMuted).padding(16)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 1) {
                            ForEach(candidates, id: \.login) { user in
                                AssigneeRow(user: user, isAssigned: isRequested(user.login)) {
                                    onReviewerAction(user.login, !isRequested(user.login))
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                    .frame(maxHeight: 280)
                }
            }
            .frame(width: 220)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
            .onAppear(perform: fetchIfNeeded)
        }
    }
}

// A native `Menu`'s plain text items can't match the reference's icon+row list, so this is a
// custom Button + .popover like AssigneeMenu above. `onSelect(nil)` reopens; a non-nil string is
// the GitHub close reason ("completed" / "not planned") passed straight to `gh issue close --reason`.
private struct StatusMenu: View {
    let isOpen: Bool
    let onSelect: (String?) -> Void
    @State private var showMenu = false
    private static let openColor = Color(red: 0.35, green: 0.85, blue: 0.55)

    var body: some View {
        Button { showMenu = true } label: {
            HStack(spacing: 4) {
                DotRingIcon(color: isOpen ? Self.openColor : Color.mgMuted, diameter: 9)
                Text(isOpen ? "Open" : "Closed").font(.system(size: 10, weight: .medium))
                Image(systemName: "chevron.down").font(.system(size: 7))
            }
            .foregroundStyle(isOpen ? Self.openColor : Color.mgMuted)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background((isOpen ? Self.openColor : Color.mgMuted).opacity(0.12))
            .overlay(Capsule().stroke((isOpen ? Self.openColor : Color.mgMuted).opacity(0.4), lineWidth: 1))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $showMenu, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 1) {
                StatusMenuRow(systemIcon: nil, title: "Open", isSelected: isOpen) {
                    if !isOpen { onSelect(nil) }
                    showMenu = false
                }
                StatusMenuRow(systemIcon: "checkmark.circle", title: "Close as completed", isSelected: false) {
                    onSelect("completed")
                    showMenu = false
                }
                StatusMenuRow(systemIcon: "nosign", title: "Close as not planned", isSelected: false) {
                    onSelect("not planned")
                    showMenu = false
                }
                // GitHub's real "close as duplicate" links to a target issue — a materially
                // different flow (issue picker), not a plain state change, so left disabled here
                // rather than faking an action that doesn't do anything.
                StatusMenuRow(systemIcon: "square.on.square", title: "Close as duplicate", isSelected: false, showsChevron: true, enabled: false) {}
                    .help("Not yet supported")
            }
            .padding(.vertical, 4)
            .frame(width: 230)
            .background(.ultraThinMaterial)
            .environment(\.colorScheme, .dark)
        }
    }
}

private struct StatusMenuRow: View {
    let systemIcon: String?  // nil renders the ring+dot "Open" glyph instead of an SF Symbol
    let title: String
    let isSelected: Bool
    var showsChevron: Bool = false
    var enabled: Bool = true
    let action: () -> Void
    @State private var hovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Group {
                    if let systemIcon {
                        Image(systemName: systemIcon).font(.system(size: 14))
                    } else {
                        DotRingIcon(color: Color.mgMuted, diameter: 13)
                    }
                }
                .foregroundStyle(Color.mgMuted)
                .frame(width: 16, height: 16)

                Text(title).font(.system(size: 13)).foregroundStyle(enabled ? Color.mgLabel : Color.mgMuted)
                Spacer(minLength: 4)
                if showsChevron {
                    Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold)).foregroundStyle(Color.mgMuted)
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .background(isSelected || hovered ? Color.mgRowHover : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onHover { hovered = $0 }
    }
}

struct PRRowView: View {
    let row: PRRow
    let isBusy: Bool
    let canStart: Bool
    let hasWorkspace: Bool
    let onStart: () -> Void
    let onOpenGitHub: () -> Void
    let onReviewerAction: (String, Bool) -> Void

    @State private var hovered = false
    private static let openColor = Color(red: 0.35, green: 0.85, blue: 0.55)
    private static let mergedColor = Color(red: 0.6, green: 0.4, blue: 0.9)

    var body: some View {
        HStack(spacing: 9) {
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 11))
                    .foregroundStyle(row.pr.state == "MERGED" ? Self.mergedColor : (row.pr.state == "OPEN" ? Self.openColor : Color.mgMuted))
                Text("#\(row.pr.number)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.mgMuted)
            }
            .frame(width: TaskRowMetrics.idWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.pr.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.mgLabel).lineLimit(1)
                    RepoTag(name: row.repo.name)
                }
                HStack(spacing: 6) {
                    Text(row.pr.author.login).font(.system(size: 10)).foregroundStyle(Color.mgMuted).lineLimit(1)
                    if row.pr.isDraft {
                        Text("· Draft").font(.system(size: 10)).foregroundStyle(Color.mgMuted)
                    }
                }
            }
            Spacer(minLength: 8)

            ReviewerMenu(repo: row.repo, reviewRequests: row.pr.reviewRequests, onReviewerAction: onReviewerAction)
                .frame(width: TaskRowMetrics.personWidth, alignment: .leading)

            let checks = row.checksSummary
            HStack(spacing: 4) {
                Image(systemName: checks.icon).font(.system(size: 9))
                Text(checks.label).font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(checks.color)
            .frame(width: TaskRowMetrics.checksWidth, alignment: .leading)

            HStack(spacing: 4) {
                Image(systemName: row.pr.isDraft ? "pencil.circle" : "arrow.triangle.merge").font(.system(size: 9))
                Text(row.pr.isDraft ? "Draft" : "Merge").font(.system(size: 10, weight: .medium))
            }
            .foregroundStyle(Color.mgLabel)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .overlay(Capsule().stroke(Color.mgBorder, lineWidth: 1))
            .clipShape(Capsule())
            .frame(width: TaskRowMetrics.mergeWidth)

            Text(taskRelativeTime(row.pr.updatedAt))
                .font(.system(size: 10)).foregroundStyle(Color.mgMuted)
                .frame(width: TaskRowMetrics.updatedWidth, alignment: .trailing)

            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().scaleEffect(0.6)
                } else {
                    RowActionPill(title: hasWorkspace ? "Open" : "Start", enabled: canStart, action: onStart)
                        .help(canStart ? "" : "Clone \(row.repo.defaultBranch) first in Repos")
                }
                RowMoreMenu(onOpenGitHub: onOpenGitHub)
            }
            .frame(width: TaskRowMetrics.actionWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 14)
        .background(hovered ? Color.mgRowHover : Color.clear)
        .onHover { hovered = $0 }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
    }
}

// The Repos tab's left-hand sidebar row (name + clone status + a quick-clone button) — narrower
// than the flat Issues/PRs rows since branches now live in the right-hand detail pane instead of
// their own tab, so this only needs to identify the repo and its clone state, not act on branches.
struct RepoSidebarRow: View {
    let repo: RepoEntry
    let isBusy: Bool
    let isCloned: Bool
    let isSelected: Bool
    let onStart: () -> Void
    let onSelect: () -> Void

    @State private var hovered = false
    private static let clonedColor = Color(red: 0.35, green: 0.85, blue: 0.55)

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "folder").font(.system(size: 12)).foregroundStyle(Color.mgMuted)

            VStack(alignment: .leading, spacing: 2) {
                Text(repo.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.mgLabel).lineLimit(1)
                HStack(spacing: 4) {
                    Circle().fill(isCloned ? Self.clonedColor : Color.mgMuted).frame(width: 5, height: 5)
                    Text(isCloned ? "Cloned" : "Not cloned").font(.system(size: 9)).foregroundStyle(Color.mgMuted)
                }
            }
            Spacer(minLength: 6)

            if isBusy {
                ProgressView().scaleEffect(0.5).frame(width: 20)
            } else if !isCloned {
                Button(action: onStart) {
                    Image(systemName: "square.and.arrow.down").font(.system(size: 11)).foregroundStyle(Color.mgAccent)
                }
                .buttonStyle(.plain)
                .help("Clone \(repo.defaultBranch)")
            }
            Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Color.mgMuted.opacity(0.6))
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .contentShape(Rectangle())
        .background(isSelected ? Color.mgAccent.opacity(0.14) : (hovered ? Color.mgRowHover : Color.clear))
        .onHover { hovered = $0 }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
        .onTapGesture(perform: onSelect)
    }
}

// Mirrors RepoDetailView's BranchTag (ManagementView.swift) — duplicated rather than shared
// since that one is file-private and scoped to a single-repo view.
private struct TaskBranchTag: View {
    enum Kind { case local, remote }
    let kind: Kind
    private var label: String { kind == .local ? "local" : "remote" }
    private var icon: String { kind == .local ? "laptopcomputer" : "cloud" }
    private var color: Color {
        kind == .local ? Color(red: 0.35, green: 0.85, blue: 0.55) : Color(red: 0.40, green: 0.70, blue: 1.00)
    }
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 8))
            Text(label).font(.system(size: 9, weight: .medium)).lineLimit(1)
        }
        .fixedSize()
        .foregroundStyle(color)
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(color.opacity(0.15))
        .clipShape(Capsule())
    }
}

struct BranchRowView: View {
    let row: BranchRow
    let isBusy: Bool
    let isCloned: Bool
    let canStart: Bool
    let onStart: () -> Void
    let onOpenGitHub: () -> Void
    let onRemove: () -> Void

    @State private var hovered = false
    private var isDefault: Bool { row.name == row.repo.defaultBranch }
    private var actionTitle: String { isCloned ? "Open" : (isDefault ? "Clone" : "Worktree") }

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 11)).foregroundStyle(Color.mgMuted)
                .frame(width: TaskRowMetrics.idWidth, alignment: .leading)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(row.name).font(.system(size: 13, weight: .semibold, design: .monospaced)).foregroundStyle(Color.mgLabel).lineLimit(1)
                    if isDefault {
                        Text("default").font(.system(size: 9, weight: .medium)).foregroundStyle(Color.mgMuted)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.mgMuted.opacity(0.15)).clipShape(Capsule())
                    }
                }
                RepoTag(name: row.repo.name)
            }
            Spacer(minLength: 8)

            HStack(spacing: 4) {
                if row.isLocal { TaskBranchTag(kind: .local) }
                if row.isRemote { TaskBranchTag(kind: .remote) }
            }
            .frame(width: TaskRowMetrics.branchStatusWidth, alignment: .leading)

            Color.clear.frame(width: TaskRowMetrics.updatedWidth)

            HStack(spacing: 6) {
                if isBusy {
                    ProgressView().scaleEffect(0.6)
                } else {
                    RowActionPill(title: actionTitle, enabled: canStart, action: onStart)
                        .help(canStart ? "" : "Clone \(row.repo.defaultBranch) first")
                }
                RowMoreMenu(onOpenGitHub: onOpenGitHub, onRemove: (isCloned && !isDefault) ? onRemove : nil)
            }
            .frame(width: TaskRowMetrics.actionWidth, alignment: .trailing)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(hovered ? Color.mgRowHover : Color.clear)
        .onHover { hovered = $0 }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
    }
}
