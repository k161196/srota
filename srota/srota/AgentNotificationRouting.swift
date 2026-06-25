import Foundation

enum AgentRunStatus: String, Codable {
    case working
    case waitingForResponse
    case completed

    init?(event: String) {
        switch event {
        case "Start", "SessionStart", "Attached", "PreToolUse", "PostToolUse":
            self = .working
        case "PermissionRequest":
            self = .waitingForResponse
        case "Stop", "SessionEnd", "Detached":
            self = .completed
        default:
            return nil
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .waitingForResponse: return "Waiting for response"
        case .completed: return "Completed"
        }
    }
}

struct AgentNotificationState {
    private(set) var status: AgentRunStatus?
    private(set) var summary: String = ""
    private(set) var updatedAt: Double = 0
    private var ownerPaneID: String?

    mutating func apply(status: AgentRunStatus, summary: String?, timestamp: Double, ownerPaneID: String?) {
        self.status = status
        if let summary, !summary.isEmpty, !summary.contains("<") {
            self.summary = summary
        }
        updatedAt = timestamp
        self.ownerPaneID = ownerPaneID
    }

    mutating func clearIfOwned(byPaneID paneID: String) {
        guard ownerPaneID == paneID else { return }
        status = nil
        summary = ""
        updatedAt = 0
        ownerPaneID = nil
    }

}

struct AgentNotificationEvent {
    var tabID: String?
    var paneID: String?
    var cwd: String
}

struct AgentNotificationTabSnapshot {
    var tabID: String
    var cwd: String?
    var paneIDs: Set<String>
}

enum AgentNotificationRouter {
    static func bestMatchingTabIndex(
        for event: AgentNotificationEvent,
        in tabs: [AgentNotificationTabSnapshot]
    ) -> Int? {
        if let tabID = event.tabID {
            return tabs.firstIndex { $0.tabID == tabID }
        }
        if let paneID = event.paneID {
            return tabs.firstIndex { $0.paneIDs.contains(paneID) }
        }

        let target = URL(fileURLWithPath: event.cwd).standardizedFileURL.path
        return tabs
            .enumerated()
            .compactMap { index, tab -> (Int, Int)? in
                guard let path = tab.cwd else { return nil }
                let base = URL(fileURLWithPath: path).standardizedFileURL.path
                let score: Int
                if target == base {
                    score = Int.max
                } else if target.hasPrefix(base + "/") {
                    score = base.count
                } else if base.hasPrefix(target + "/") {
                    score = target.count
                } else {
                    return nil
                }
                return (index, score)
            }
            .max(by: { $0.1 < $1.1 })?
            .0
    }
}
