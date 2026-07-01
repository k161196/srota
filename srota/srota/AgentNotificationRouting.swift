import Foundation

enum AgentRunStatus: String, Codable {
    case working
    case idle
    case blocked
    case done

    init?(event: String) {
        switch event {
        case "Start", "SessionStart":
            self = .working
        case "PermissionRequest":
            self = .blocked
        case "Stop":
            self = .idle
        case "SessionEnd":
            self = .done
        default:
            return nil
        }
    }

    var label: String {
        switch self {
        case .working: return "Working"
        case .idle: return "Idle"
        case .blocked: return "Blocked"
        case .done: return "Done"
        }
    }
}

// A status snapshot for one daemon PTY (keyed by stableID in DaemonConnection.agentStatesByStableID).
struct AgentNotificationState {
    private(set) var status: AgentRunStatus?
    private(set) var agent: String = ""
    private(set) var summary: String = ""
    private(set) var updatedAt: Double = 0

    mutating func apply(status: AgentRunStatus, agent: String, summary: String?, timestamp: Double) {
        self.status = status
        self.agent = agent
        if let summary, !summary.isEmpty, !summary.contains("<") {
            self.summary = summary
        }
        updatedAt = timestamp
    }

}
