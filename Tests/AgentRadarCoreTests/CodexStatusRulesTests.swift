import XCTest
@testable import AgentRadarCore

final class CodexStatusRulesTests: XCTestCase {
    private func probe(_ tail: String) -> CodexStatusProbe {
        CodexStatusRules.probe(fromSessionTail: tail, sessionName: "rollout.jsonl", readSize: 1024)
    }

    func testTaskStartedIsThinking() {
        let tail = """
        {"type":"event_msg","timestamp":"2026-07-02T10:00:00.000Z","payload":{"type":"task_started"}}
        {"type":"response_item","payload":{"type":"message"}}
        """

        let result = probe(tail)
        XCTAssertEqual(result.decision?.status, .thinking)
        XCTAssertEqual(result.decision?.refreshLastActivity, true)
    }

    func testTaskCompleteIsIdle() {
        let tail = """
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"event_msg","timestamp":"2026-07-02T10:05:00.000Z","payload":{"type":"task_complete"}}
        """

        let result = probe(tail)
        XCTAssertEqual(result.decision?.status, .idle)
        XCTAssertEqual(result.decision?.refreshLastActivity, false)
    }

    func testTurnAbortedIsIdle() {
        let tail = #"{"type":"event_msg","payload":{"type":"turn_aborted"}}"#

        XCTAssertEqual(probe(tail).decision?.status, .idle)
    }

    // The newest task event wins even when non-status events follow it.
    func testMostRecentTaskEventWins() {
        let tail = """
        {"type":"event_msg","payload":{"type":"task_complete"}}
        {"type":"event_msg","payload":{"type":"task_started"}}
        {"type":"event_msg","payload":{"type":"agent_message"}}
        {"type":"response_item","payload":{"type":"function_call_output"}}
        """

        XCTAssertEqual(probe(tail).decision?.status, .thinking)
    }

    func testNoTaskEventYieldsNoDecisionWithDebugContext() {
        let tail = """
        {"type":"event_msg","payload":{"type":"agent_message"}}
        {"type":"session_meta","payload":{"id":"abc"}}
        not json at all
        """

        let result = probe(tail)
        XCTAssertNil(result.decision)
        XCTAssertTrue(result.debug.contains("status=no_task_event"), result.debug)
        XCTAssertTrue(result.debug.contains("recent_events=agent_message"), result.debug)
    }

    func testResumeSessionIDParsing() {
        XCTAssertEqual(
            CodexStatusRules.resumeSessionID(from: "codex resume 0197f9a1"),
            "0197f9a1"
        )
        XCTAssertEqual(
            CodexStatusRules.resumeSessionID(from: "codex resume \"0197f9a1\""),
            "0197f9a1"
        )
        XCTAssertNil(CodexStatusRules.resumeSessionID(from: "codex resume"))
        XCTAssertNil(CodexStatusRules.resumeSessionID(from: "codex exec 'do things'"))
    }
}
