import Foundation

// MARK: - Requests

struct CreateParams: Decodable {
    let cmd: [String]       // empty = default shell
    let cwd: String
    let stableID: String    // SROTA_PANE_ID — the app-side UUID, stable across daemon restarts
    let env: [String: String]
}

enum DaemonRequest: Decodable {
    case create(CreateParams)
    case attach(paneID: String)
    case input(paneID: String, data: String)            // data is base64
    case resize(paneID: String, rows: UInt16, cols: UInt16)
    case list
    case close(paneID: String)

    private enum CodingKeys: String, CodingKey { case type, paneID, data, rows, cols }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        switch try c.decode(String.self, forKey: .type) {
        case "create":
            self = .create(try CreateParams(from: decoder))
        case "attach":
            self = .attach(paneID: try c.decode(String.self, forKey: .paneID))
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
            self = .list
        case "close":
            self = .close(paneID: try c.decode(String.self, forKey: .paneID))
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
    let cwd: String         // initial CWD — live CWD comes from shell hooks
    let exitCode: Int32?    // nil = still running
}

enum DaemonResponse: Encodable {
    case created(paneID: String)
    case ringBuffer(paneID: String, data: String)   // base64, replayed on attach
    case live(paneID: String, data: String)         // base64, streaming output
    case listed([PTYInfo])
    case dead(paneID: String, exitCode: Int32)
    case ok
    case error(String)

    private enum CodingKeys: String, CodingKey { case type, paneID, data, panes, message, exitCode }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .created(let id):
            try c.encode("created", forKey: .type)
            try c.encode(id, forKey: .paneID)
        case .ringBuffer(let id, let d):
            try c.encode("ring_buffer", forKey: .type)
            try c.encode(id, forKey: .paneID)
            try c.encode(d, forKey: .data)
        case .live(let id, let d):
            try c.encode("live", forKey: .type)
            try c.encode(id, forKey: .paneID)
            try c.encode(d, forKey: .data)
        case .listed(let ps):
            try c.encode("listed", forKey: .type)
            try c.encode(ps, forKey: .panes)
        case .dead(let id, let code):
            try c.encode("dead", forKey: .type)
            try c.encode(id, forKey: .paneID)
            try c.encode(code, forKey: .exitCode)
        case .ok:
            try c.encode("ok", forKey: .type)
        case .error(let m):
            try c.encode("error", forKey: .type)
            try c.encode(m, forKey: .message)
        }
    }
}
