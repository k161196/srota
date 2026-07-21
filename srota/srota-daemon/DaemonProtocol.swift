import Foundation

// MARK: - Requests

struct CreateParams: Decodable {
    let requestID: String?
    let cmd: [String] // empty = default shell
    let cwd: String
    let stableID: String // SROTA_PANE_ID — app-side UUID, stable across daemon restarts
    let env: [String: String]
    let rows: UInt16?
    let cols: UInt16?
    let replayBufferBytes: Int?
}

struct AgentEventParams: Decodable {
    let stableID: String
    let event: String
    let agent: String?
    let summary: String?
    let timestamp: Double?
    let sessionID: String?
}

enum DaemonRequest: Decodable {
    case create(CreateParams)
    case attach(paneID: String, replayBufferBytes: Int?)
    case input(paneID: String, data: String) // data is base64
    case resize(paneID: String, rows: UInt16, cols: UInt16)
    case list(requestID: String?)
    case close(paneID: String)
    case agentEvent(AgentEventParams)

    private enum CodingKeys: String, CodingKey {
        case type
        case requestID
        case paneID
        case data
        case rows
        case cols
        case replayBufferBytes
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "create":
            self = .create(try CreateParams(from: decoder))
        case "attach":
            self = .attach(
                paneID: try c.decode(String.self, forKey: .paneID),
                replayBufferBytes: try c.decodeIfPresent(Int.self, forKey: .replayBufferBytes)
            )
        case "input":
            self = .input(
                paneID: try c.decode(String.self, forKey: .paneID),
                data: try c.decode(String.self, forKey: .data)
            )
        case "resize":
            self = .resize(
                paneID: try c.decode(String.self, forKey: .paneID),
                rows: try c.decode(UInt16.self, forKey: .rows),
                cols: try c.decode(UInt16.self, forKey: .cols)
            )
        case "list":
            self = .list(requestID: try c.decodeIfPresent(String.self, forKey: .requestID))
        case "close":
            self = .close(paneID: try c.decode(String.self, forKey: .paneID))
        case "agent_event":
            self = .agentEvent(try AgentEventParams(from: decoder))
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: c, debugDescription: "unknown type")
        }
    }
}

// MARK: - Responses

struct PTYInfo: Encodable {
    let paneID: String
    let stableID: String
    let pid: Int32
    let cwd: String // initial CWD
    let exitCode: Int32?
    let agentStatus: String?
    let agent: String?
    let agentSummary: String?
    let agentUpdatedAt: Double?
    let agentSessionID: String?
}

struct AgentStatusPayload: Encodable {
    let paneID: String
    let stableID: String
    let status: String?
    let agent: String?
    let summary: String?
    let updatedAt: Double?
    let sessionID: String?
    // The original hook event name (e.g. "Stop", "SessionStart") — status alone can't tell
    // content-bearing events (Stop/PermissionRequest/SessionEnd) apart from lifecycle-only ones
    // (Start/SessionStart both collapse to "idle"/"working" via PTYProcess.status(for:)).
    let hookEvent: String?
}

enum DaemonResponse: Encodable {
    case created(paneID: String, requestID: String?)
    case ringBuffer(paneID: String, data: String)
    case ringBufferDone(paneID: String)
    case live(paneID: String, data: String)
    case listed([PTYInfo], requestID: String?)
    case dead(paneID: String, exitCode: Int32)
    case agentStatus(AgentStatusPayload)
    case ok
    case error(String, requestID: String?)

    private enum CodingKeys: String, CodingKey {
        case type
        case requestID
        case paneID
        case data
        case panes
        case message
        case exitCode
        case stableID
        case status
        case agent
        case summary
        case updatedAt
        case sessionID
        case hookEvent
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .created(let id, let requestID):
            try c.encode("created", forKey: .type)
            try c.encodeIfPresent(requestID, forKey: .requestID)
            try c.encode(id, forKey: .paneID)
        case .ringBuffer(let id, let d):
            try c.encode("ring_buffer", forKey: .type)
            try c.encode(id, forKey: .paneID)
            try c.encode(d, forKey: .data)
        case .ringBufferDone(let id):
            try c.encode("ring_buffer_done", forKey: .type)
            try c.encode(id, forKey: .paneID)
        case .live(let id, let d):
            try c.encode("live", forKey: .type)
            try c.encode(id, forKey: .paneID)
            try c.encode(d, forKey: .data)
        case .listed(let ps, let requestID):
            try c.encode("listed", forKey: .type)
            try c.encodeIfPresent(requestID, forKey: .requestID)
            try c.encode(ps, forKey: .panes)
        case .dead(let id, let code):
            try c.encode("dead", forKey: .type)
            try c.encode(id, forKey: .paneID)
            try c.encode(code, forKey: .exitCode)
        case .agentStatus(let payload):
            try c.encode("agent_status", forKey: .type)
            try c.encode(payload.paneID, forKey: .paneID)
            try c.encode(payload.stableID, forKey: .stableID)
            try c.encodeIfPresent(payload.status, forKey: .status)
            try c.encodeIfPresent(payload.agent, forKey: .agent)
            try c.encodeIfPresent(payload.summary, forKey: .summary)
            try c.encodeIfPresent(payload.updatedAt, forKey: .updatedAt)
            try c.encodeIfPresent(payload.sessionID, forKey: .sessionID)
            try c.encodeIfPresent(payload.hookEvent, forKey: .hookEvent)
        case .ok:
            try c.encode("ok", forKey: .type)
        case .error(let m, let requestID):
            try c.encode("error", forKey: .type)
            try c.encodeIfPresent(requestID, forKey: .requestID)
            try c.encode(m, forKey: .message)
        }
    }
}
