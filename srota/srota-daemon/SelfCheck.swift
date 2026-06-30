import Foundation

@discardableResult
func runDaemonSelfCheck() -> Bool {
    guard ProcessInfo.processInfo.environment["SROTA_DAEMON_SELF_CHECK"] == "1" else { return false }

    let decoder = JSONDecoder()
    let request = try! decoder.decode(
        DaemonRequest.self,
        from: Data(#"{"type":"list","requestID":"req-1"}"#.utf8)
    )
    if case .list(let requestID) = request {
        assert(requestID == "req-1")
    } else {
        assertionFailure("expected list request")
    }

    let responseData = try! JSONEncoder().encode(.created(paneID: "pane-1", requestID: "req-2") as DaemonResponse)
    let response = try! JSONSerialization.jsonObject(with: responseData) as! [String: Any]
    assert(response["paneID"] as? String == "pane-1")
    assert(response["requestID"] as? String == "req-2")

    assert(processExitCode(from: 7 << 8) == 7)
    assert(processExitCode(from: 9) == 137)
    return true
}
