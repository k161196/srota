import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAIL: \(message)\n", stderr)
        exit(1)
    }
}

@main
struct AgentNotificationStateTests {
    static func main() {
        expect(AgentRunStatus(event: "SessionStart") == .working, "SessionStart should map to working")
        expect(AgentRunStatus(event: "Start") == .working, "Start should map to working")
        expect(AgentRunStatus(event: "Stop") == .idle, "Stop should map to idle")
        expect(AgentRunStatus(event: "SessionEnd") == .done, "SessionEnd should map to done")
        expect(AgentRunStatus(event: "PermissionRequest") == .blocked, "PermissionRequest should map to blocked")
        expect(AgentRunStatus(event: "SomeUnknownEvent") == nil, "unrecognized events should not map to a status")

        var state = AgentNotificationState()
        expect(state.status == nil, "a fresh state should start with no status")

        state.apply(status: .working, agent: "claude", summary: "doing the thing", timestamp: 10)
        expect(state.status == .working, "apply should set status")
        expect(state.agent == "claude", "apply should set the agent name")
        expect(state.summary == "doing the thing", "apply should set a plain-text summary")
        expect(state.updatedAt == 10, "apply should set the timestamp")

        state.apply(status: .blocked, agent: "claude", summary: nil, timestamp: 11)
        expect(state.status == .blocked, "apply should update status")
        expect(state.summary == "doing the thing", "a nil summary should not clear the previous one")

        state.apply(status: .idle, agent: "claude", summary: "<tool_result>raw xml</tool_result>", timestamp: 12)
        expect(state.summary == "doing the thing", "summaries that look like markup should be rejected")

        state.apply(status: .done, agent: "codex", summary: "wrapped up", timestamp: 13)
        expect(state.agent == "codex", "apply should allow switching the reported agent")
        expect(state.summary == "wrapped up", "a clean summary should replace the previous one")

        print("PASS")
    }
}
