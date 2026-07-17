import SwiftUI
import AppKit

// Mirrors ManagementView.swift's private Color.mg* palette — duplicated here since that
// extension is file-private and this view lives in a different file (same convention GitHubProjectsPanel.swift uses).
private extension Color {
    static let mgSurface   = Color(red: 0.10,  green: 0.10,  blue: 0.11)
    static let mgBorder    = Color.white.opacity(0.07)
    static let mgAccent    = Color(red: 1.0, green: 0.45, blue: 0.15)
    static let mgLabel     = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let mgMuted     = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.40)
    static let mgRowHover  = Color.white.opacity(0.065)
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

struct FiltersMenuView: View {
    let subTab: TasksPanel.SubTab
    @Binding var query: String
    let assigneeSuggestions: [String]
    let authorSuggestions: [String]
    let labelSuggestions: [String]
    let reviewerSuggestions: [String]
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusSection
            FilterPickerSection(title: "Author", prefix: "author:", suggestions: authorSuggestions, query: $query, onApply: onApply)
            if subTab == .issues {
                FilterPickerSection(title: "Assignee", prefix: "assignee:", suggestions: assigneeSuggestions, query: $query, onApply: onApply)
            } else {
                FilterPickerSection(title: "Review from", prefix: "review-requested:", suggestions: reviewerSuggestions, query: $query, onApply: onApply)
            }
            FilterPickerSection(title: "Label", prefix: "label:", suggestions: labelSuggestions, query: $query, onApply: onApply)
        }
        .padding(14)
        .frame(width: 260)
    }

    private func statusIsSelected(_ option: String) -> Bool {
        let tokens = Set(query.split(separator: " ").map(String.init))
        switch option {
        case "Open": return tokens.contains("is:open")
        case "Closed": return tokens.contains("is:closed")
        default: return !tokens.contains("is:open") && !tokens.contains("is:closed")
        }
    }

    private func setStatus(_ option: String) {
        var tokens = query.split(separator: " ").map(String.init).filter { $0 != "is:open" && $0 != "is:closed" }
        if option == "Open" { tokens.append("is:open") }
        else if option == "Closed" { tokens.append("is:closed") }
        query = tokens.joined(separator: " ")
        onApply()
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("STATUS").font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(Color.mgMuted)
            HStack(spacing: 6) {
                ForEach(["Open", "Closed", "All"], id: \.self) { option in
                    let isSelected = statusIsSelected(option)
                    Button(option) { setStatus(option) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        .foregroundStyle(isSelected ? Color.mgLabel : Color.mgMuted)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(isSelected ? Color.mgAccent.opacity(0.15) : Color.mgSurface)
                        .clipShape(Capsule())
                }
            }
        }
    }
}

private struct FilterPickerSection: View {
    let title: String
    let prefix: String
    let suggestions: [String]
    @Binding var query: String
    let onApply: () -> Void
    @State private var customValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(Color.mgMuted)
                Spacer()
                if queryValue(prefix, in: query) != nil {
                    Button("Clear") { query = queryRemoving(prefix, from: query); onApply() }
                        .buttonStyle(.plain).font(.system(size: 9)).foregroundStyle(Color.mgAccent)
                }
            }
            FlowChips(items: ["@me"] + suggestions, selected: queryValue(prefix, in: query)) { value in
                query = querySetting(prefix, value: value, in: query)
                onApply()
            }
            TextField("Custom \(title.lowercased())…", text: $customValue)
                .textFieldStyle(.plain).font(.system(size: 11)).foregroundStyle(Color.mgLabel)
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Color.mgSurface).clipShape(RoundedRectangle(cornerRadius: 5))
                .onSubmit {
                    guard !customValue.isEmpty else { return }
                    query = querySetting(prefix, value: customValue, in: query)
                    customValue = ""
                    onApply()
                }
        }
    }
}

private struct FlowChips: View {
    let items: [String]
    let selected: String?
    let onSelect: (String) -> Void
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                ForEach(items, id: \.self) { item in
                    Button(item) { onSelect(item) }
                        .buttonStyle(.plain)
                        .font(.system(size: 10, weight: selected == item ? .semibold : .regular))
                        .foregroundStyle(selected == item ? Color.mgLabel : Color.mgMuted)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(selected == item ? Color.mgAccent.opacity(0.15) : Color.mgSurface)
                        .clipShape(Capsule())
                }
            }
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
    let onToggleState: () -> Void
    let onAssigneeAction: (String, Bool) -> Void

    @State private var hovered = false
    private var isOpen: Bool { row.issue.state == "OPEN" }
    private static let openColor = Color(red: 0.35, green: 0.85, blue: 0.55)
    private static let closedColor = Color(red: 0.65, green: 0.45, blue: 0.95)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isOpen ? "circle" : "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(isOpen ? Self.openColor : Self.closedColor)
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(row.issue.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mgLabel).lineLimit(1)
                    if let label = row.issue.labels.first {
                        Text(label.name).font(.system(size: 9, weight: .medium)).foregroundStyle(Color.mgMuted)
                            .padding(.horizontal, 5).padding(.vertical, 1)
                            .background(Color.mgMuted.opacity(0.15)).clipShape(Capsule())
                    }
                }
                Text("#\(row.issue.number) · \(row.repo.name)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.mgMuted).lineLimit(1)
            }
            Spacer(minLength: 8)

            Menu {
                ForEach(row.issue.assignees, id: \.login) { a in
                    Button("Remove \(a.login)") { onAssigneeAction(a.login, false) }
                }
                if !row.issue.assignees.isEmpty { Divider() }
                Button("Assign myself (@me)") { onAssigneeAction("@me", true) }
            } label: {
                HStack(spacing: 2) {
                    Image(systemName: row.issue.assignees.isEmpty ? "person.crop.circle" : "person.crop.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(row.issue.assignees.isEmpty ? Color.mgMuted : Color.mgAccent)
                    Image(systemName: "chevron.down").font(.system(size: 7)).foregroundStyle(Color.mgMuted)
                }
            }
            .menuStyle(.borderlessButton)
            .frame(width: 34)
            .help(row.issue.assignees.isEmpty ? "Unassigned" : row.issue.assignees.map(\.login).joined(separator: ", "))

            Menu {
                Button(isOpen ? "Close issue" : "Reopen issue") { onToggleState() }
            } label: {
                HStack(spacing: 3) {
                    Text(isOpen ? "Open" : "Closed").font(.system(size: 10, weight: .medium))
                    Image(systemName: "chevron.down").font(.system(size: 7))
                }
                .foregroundStyle(isOpen ? Self.openColor : Color.mgMuted)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background((isOpen ? Self.openColor : Color.mgMuted).opacity(0.15))
                .clipShape(Capsule())
            }
            .menuStyle(.borderlessButton)
            .frame(width: 70)

            Text(taskRelativeTime(row.issue.updatedAt))
                .font(.system(size: 10)).foregroundStyle(Color.mgMuted)
                .frame(width: 56, alignment: .trailing)

            Button { onOpenGitHub() } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 10)).foregroundStyle(Color.mgAccent)
                    .frame(width: 22, height: 22)
                    .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 4)
            }
            .buttonStyle(.plain)
            .help("Open on GitHub")

            if isBusy {
                ProgressView().scaleEffect(0.6).frame(width: 42)
            } else {
                Button(hasWorkspace ? "Open" : "Start") { onStart() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(canStart ? Color.mgAccent : Color.mgMuted.opacity(0.5))
                    .disabled(!canStart)
                    .help(canStart ? "" : "Clone \(row.repo.defaultBranch) first in Repos")
                    .frame(width: 42)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovered ? Color.mgRowHover : Color.clear)
        .onHover { hovered = $0 }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
    }
}

struct PRRowView: View {
    let row: PRRow
    let isBusy: Bool
    let canStart: Bool
    let hasWorkspace: Bool
    let onStart: () -> Void
    let onOpenGitHub: () -> Void

    @State private var hovered = false
    private static let openColor = Color(red: 0.35, green: 0.85, blue: 0.55)
    private static let mergedColor = Color(red: 0.6, green: 0.4, blue: 0.9)

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 11))
                .foregroundStyle(row.pr.state == "MERGED" ? Self.mergedColor : (row.pr.state == "OPEN" ? Self.openColor : Color.mgMuted))
                .frame(width: 12)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.pr.title).font(.system(size: 12, weight: .medium)).foregroundStyle(Color.mgLabel).lineLimit(1)
                Text("#\(row.pr.number) · \(row.repo.name) · \(row.pr.headRefName)")
                    .font(.system(size: 10, design: .monospaced)).foregroundStyle(Color.mgMuted).lineLimit(1)
            }
            Spacer(minLength: 8)

            Group {
                if !row.pr.reviewRequests.isEmpty {
                    Image(systemName: "person.crop.circle.badge.questionmark")
                        .font(.system(size: 13)).foregroundStyle(Color.mgMuted)
                        .help(row.pr.reviewRequests.map(\.displayName).joined(separator: ", "))
                } else {
                    Color.clear
                }
            }
            .frame(width: 18)

            let checks = row.checksSummary
            Text(checks.label)
                .font(.system(size: 10, weight: .medium)).foregroundStyle(checks.color)
                .frame(width: 56)

            Text(row.pr.isDraft ? "Draft" : "Merge")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(row.pr.isDraft ? Color.mgMuted : Color.mgAccent)
                .padding(.horizontal, 7).padding(.vertical, 3)
                .background((row.pr.isDraft ? Color.mgMuted : Color.mgAccent).opacity(0.15))
                .clipShape(Capsule())
                .frame(width: 52)

            Text(taskRelativeTime(row.pr.updatedAt))
                .font(.system(size: 10)).foregroundStyle(Color.mgMuted)
                .frame(width: 56, alignment: .trailing)

            Button { onOpenGitHub() } label: {
                Image(systemName: "arrow.up.forward.square").font(.system(size: 10)).foregroundStyle(Color.mgAccent)
                    .frame(width: 22, height: 22)
                    .glassCard(fill: Color.mgAccent.opacity(0.12), borderTop: Color.mgAccent.opacity(0.4), borderBottom: Color.mgAccent.opacity(0.22), radius: 4)
            }
            .buttonStyle(.plain)
            .help("Open on GitHub")

            if isBusy {
                ProgressView().scaleEffect(0.6).frame(width: 42)
            } else {
                Button(hasWorkspace ? "Open" : "Start") { onStart() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(canStart ? Color.mgAccent : Color.mgMuted.opacity(0.5))
                    .disabled(!canStart)
                    .help(canStart ? "" : "Clone \(row.repo.defaultBranch) first in Repos")
                    .frame(width: 42)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(hovered ? Color.mgRowHover : Color.clear)
        .onHover { hovered = $0 }
        .overlay(alignment: .bottom) { Rectangle().fill(Color.mgBorder).frame(height: 1) }
    }
}
