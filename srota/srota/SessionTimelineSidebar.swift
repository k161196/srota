import SwiftUI

// Right-side docked panel showing the current pane's session as a vertical timeline —
// opened via the "list.bullet.clipboard" icon in PaneHeader (ContentView.swift). Owns its
// width and renders its own resize divider, same shape as ContentView.swift's ResizableSidebar
// on the left — reuses that file's SidebarDivider/SidebarResizeLogic (mirrored: true, since
// dragging left should grow a right-docked sidebar, the opposite sign from the left one).
struct SessionTimelineSidebar: View {
    @Environment(SessionRecorder.self) private var sessionRecorder
    @State private var width: CGFloat = 280

    var body: some View {
        let visible = sessionRecorder.timelinePaneID != nil

        SidebarDivider(sidebarVisible: visible, width: $width, mirrored: true)

        content
            .frame(width: width, alignment: .leading) // pin inner layout so it doesn't reflow every animation frame
            .frame(width: visible ? width : 0, alignment: .leading)
            .clipped()
            .allowsHitTesting(visible)
    }

    private var content: some View {
        let paneID = sessionRecorder.timelinePaneID
        let steps = paneID.map { sessionRecorder.stepsByPaneID[$0] ?? [] } ?? []

        return VStack(spacing: 0) {
            header
            Rectangle().fill(Color.white.opacity(0.06)).frame(height: 1)
            if steps.isEmpty {
                Spacer()
                Text("No steps yet")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.timelineMuted)
                Spacer()
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                            TimelineRow(step: step, isLast: index == steps.count - 1)
                        }
                    }
                    .padding(16)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.timelineBg)
    }

    private var header: some View {
        HStack {
            Text("Session Timeline")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.timelineLabel)
            Spacer()
            if let paneID = sessionRecorder.timelinePaneID {
                Button {
                    sessionRecorder.refresh(paneID: paneID)
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(Color.timelineMuted)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Refresh")
            }
            Button {
                sessionRecorder.timelinePaneID = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.timelineMuted)
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .frame(height: 38)
    }
}

private struct TimelineRow: View {
    let step: SessionStepRecord
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 0) {
                Circle()
                    .strokeBorder(Color.white.opacity(0.15), lineWidth: 1)
                    .background(Circle().fill(Color.timelineBg))
                    .frame(width: 22, height: 22)
                    .overlay(
                        Image(systemName: icon(for: step))
                            .font(.system(size: 9.5))
                            .foregroundStyle(Color.timelineMuted)
                    )
                if !isLast {
                    Rectangle()
                        .fill(Color.white.opacity(0.1))
                        .frame(width: 1)
                        .frame(maxHeight: .infinity)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .top, spacing: 6) {
                    Text(step.title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.timelineLabel)
                        .textSelection(.enabled)
                    TagBadge(tag: step.tag)
                    Spacer(minLength: 8)
                    Text(formattedTime(step.createdAt))
                        .font(.system(size: 10))
                        .foregroundStyle(Color.timelineMuted)
                        .lineLimit(1)
                }
                if !step.description.isEmpty {
                    Text(step.description)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.timelineMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            .padding(.bottom, isLast ? 0 : 16)
        }
    }

    // Icon is tag-first (user/mcp get one fixed icon each), refined by the specific hook event
    // only for agent-tagged steps, where Stop/PermissionRequest/SessionEnd read as genuinely
    // different things.
    private func icon(for step: SessionStepRecord) -> String {
        switch step.tag {
        case "user": return "person.fill"
        case "mcp": return "text.bubble"
        default:
            switch step.hookEvent {
            case "Stop": return "checkmark"
            case "PermissionRequest": return "hand.raised"
            case "SessionEnd": return "flag.checkered"
            default: return "circle"
            }
        }
    }

    private func formattedTime(_ epoch: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(epoch))
        let formatter = DateFormatter()
        formatter.dateFormat = "d MMM, HH:mm"
        return formatter.string(from: date)
    }
}

// Small colored capsule showing who/what a step is attributed to — user (what you asked),
// agent (what it did), or mcp (what it self-reported via add_session_note).
private struct TagBadge: View {
    let tag: String

    private var label: String {
        switch tag {
        case "user": return "User"
        case "mcp": return "MCP"
        default: return "Agent"
        }
    }

    private var color: Color {
        switch tag {
        case "user": return Color(red: 0.42, green: 0.62, blue: 0.95)
        case "mcp": return Color(red: 0.68, green: 0.5, blue: 0.95)
        default: return Color(red: 0.5, green: 0.82, blue: 0.6)
        }
    }

    var body: some View {
        Text(label)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1.5)
            .background(color.opacity(0.15))
            .clipShape(Capsule())
    }
}

// Matches this codebase's per-file design-token convention (see ContentView.swift's and
// SettingsView.swift's own private Color extensions).
private extension Color {
    static let timelineBg    = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let timelineLabel = Color(red: 0.92, green: 0.92, blue: 0.93)
    static let timelineMuted = Color(red: 0.92, green: 0.92, blue: 0.93).opacity(0.40)
}
