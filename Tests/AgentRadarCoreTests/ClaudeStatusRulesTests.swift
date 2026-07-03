import XCTest
@testable import AgentRadarCore

final class ClaudeStatusRulesTests: XCTestCase {
    private func decision(
        _ entryJSON: String,
        staleness: TimeInterval
    ) -> ClaudeStatusRules.Outcome? {
        let entry = try! JSONSerialization.jsonObject(
            with: Data(entryJSON.utf8)
        ) as! [String: Any]
        return ClaudeStatusRules.decision(entry: entry, staleness: staleness, transcriptName: "t.jsonl")
    }

    // Regression: a finished turn is completed no matter how stale the
    // transcript is — done sessions must never read as active.
    func testAssistantEndTurnIsCompletedRegardlessOfStaleness() {
        let entry = #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#

        for staleness: TimeInterval in [0, 5, 600, 86_400] {
            let outcome = decision(entry, staleness: staleness)
            XCTAssertEqual(outcome?.decision.status, .completed, "staleness=\(staleness)")
            XCTAssertNil(outcome?.pendingToolCall)
            XCTAssertEqual(outcome?.decision.refreshLastActivity, false)
        }
    }

    func testAssistantFreshToolUseIsThinking() {
        let entry = #"{"type":"assistant","message":{"stop_reason":"tool_use"}}"#

        let outcome = decision(entry, staleness: 1)
        XCTAssertEqual(outcome?.decision.status, .thinking)
        XCTAssertNil(outcome?.pendingToolCall)
    }

    func testAssistantStaleToolUseNeedsAttentionWithPendingToolCall() {
        let entry = #"""
        {"type":"assistant","message":{"stop_reason":"tool_use","content":[
            {"type":"text","text":"Let me run that."},
            {"type":"tool_use","name":"Bash","input":{"command":"rm -rf build && xcodebuild"}}
        ]}}
        """#

        let outcome = decision(entry, staleness: 10)
        XCTAssertEqual(outcome?.decision.status, .needsAttention)
        XCTAssertEqual(outcome?.pendingToolCall?.toolName, "Bash")
        XCTAssertEqual(outcome?.pendingToolCall?.summary, "rm -rf build && xcodebuild")
    }

    func testAssistantStreamingIsThinkingThenCompletedWhenStale() {
        let entry = #"{"type":"assistant","message":{"stop_reason":null}}"#

        XCTAssertEqual(decision(entry, staleness: 5)?.decision.status, .thinking)
        XCTAssertEqual(decision(entry, staleness: 31)?.decision.status, .completed)
    }

    func testUserEntryIsThinkingThenRunningWhenStale() {
        let entry = #"{"type":"user","message":{"role":"user"}}"#

        XCTAssertEqual(decision(entry, staleness: 5)?.decision.status, .thinking)
        XCTAssertEqual(decision(entry, staleness: 60)?.decision.status, .running)
    }

    func testUnknownEntryTypeYieldsNoDecision() {
        XCTAssertNil(decision(#"{"type":"system"}"#, staleness: 5))
        XCTAssertNil(decision(#"{"no_type":true}"#, staleness: 5))
    }

    // Regression guard for flapping: the same entry at the same staleness
    // must always produce the same status.
    func testDecisionIsDeterministic() {
        let entry = #"{"type":"assistant","message":{"stop_reason":"end_turn"}}"#

        let statuses = (0..<50).map { _ in decision(entry, staleness: 40)?.decision.status }
        XCTAssertTrue(statuses.allSatisfy { $0 == .completed })
    }

    func testLastRelevantEntrySkipsTrailingMetadataLines() {
        let tail = """
        {"type":"user","message":{"role":"user"}}
        {"type":"assistant","message":{"stop_reason":"end_turn"}}
        {"type":"summary","summary":"compacted"}
        {"type":"system","subtype":"turn_duration"}

        {"type":"progress","data":{}}
        """

        let entry = ClaudeStatusRules.lastRelevantEntry(inTranscriptTail: tail)
        XCTAssertEqual(entry?["type"] as? String, "assistant")
        let message = entry?["message"] as? [String: Any]
        XCTAssertEqual(message?["stop_reason"] as? String, "end_turn")
    }

    func testLastRelevantEntryIgnoresPartialFirstLineFromTailRead() {
        // Reading a fixed-size tail can slice the first line mid-JSON.
        let tail = """
        son","message":{"stop_reason":"tool_use"}}
        {"type":"user","message":{"role":"user"}}
        """

        let entry = ClaudeStatusRules.lastRelevantEntry(inTranscriptTail: tail)
        XCTAssertEqual(entry?["type"] as? String, "user")
    }

    func testLastRelevantEntryEmptyTail() {
        XCTAssertNil(ClaudeStatusRules.lastRelevantEntry(inTranscriptTail: ""))
        XCTAssertNil(ClaudeStatusRules.lastRelevantEntry(inTranscriptTail: "\n\n"))
    }

    // A session spawned in one directory can move to another (e.g. into a
    // worktree) — the process cwd stays at the spawn dir, but Claude stamps
    // every transcript entry with the session's live cwd. The display
    // directory must come from the entry, not the process.
    func testSessionWorkingDirectoryComesFromLastRelevantEntry() {
        let tail = """
        {"type":"user","cwd":"/Users/dimitar/documents/spiraldb","message":{"role":"user"}}
        {"type":"assistant","cwd":"/Users/dimitar/Documents/fix-empty-block-sizes-deserialize","message":{"stop_reason":"end_turn"}}
        {"type":"system","subtype":"turn_duration"}
        """

        let entry = ClaudeStatusRules.lastRelevantEntry(inTranscriptTail: tail)!
        XCTAssertEqual(
            ClaudeStatusRules.sessionWorkingDirectory(fromEntry: entry),
            "/Users/dimitar/Documents/fix-empty-block-sizes-deserialize"
        )
    }

    func testSessionWorkingDirectoryRejectsMissingOrRelativeCwd() {
        XCTAssertNil(ClaudeStatusRules.sessionWorkingDirectory(fromEntry: ["type": "user"]))
        XCTAssertNil(ClaudeStatusRules.sessionWorkingDirectory(fromEntry: ["type": "user", "cwd": ""]))
        XCTAssertNil(ClaudeStatusRules.sessionWorkingDirectory(fromEntry: ["type": "user", "cwd": "relative/path"]))
        XCTAssertNil(ClaudeStatusRules.sessionWorkingDirectory(fromEntry: ["type": "user", "cwd": 42]))
    }

    func testSessionIDParsing() {
        let uuid = "e60e9da2-8e36-413e-a9e6-57c6596d1f62"

        XCTAssertEqual(ClaudeStatusRules.sessionID(fromCommandLine: "claude --resume \(uuid)"), uuid)
        XCTAssertEqual(ClaudeStatusRules.sessionID(fromCommandLine: "claude -r \(uuid)"), uuid)
        XCTAssertEqual(ClaudeStatusRules.sessionID(fromCommandLine: "claude --session-id=\(uuid)"), uuid)
        XCTAssertEqual(
            ClaudeStatusRules.sessionID(fromCommandLine: "claude --resume \"\(uuid.uppercased())\""),
            uuid
        )
        // Bare `--resume` picker form and non-UUID values must not match.
        XCTAssertNil(ClaudeStatusRules.sessionID(fromCommandLine: "claude --resume"))
        XCTAssertNil(ClaudeStatusRules.sessionID(fromCommandLine: "claude --resume not-a-uuid"))
        XCTAssertNil(ClaudeStatusRules.sessionID(fromCommandLine: "claude chat"))
    }

    func testToolSummaries() {
        XCTAssertEqual(
            ClaudeStatusRules.toolSummary(name: "Bash", input: ["command": "ls -la"]),
            "ls -la"
        )
        XCTAssertEqual(
            ClaudeStatusRules.toolSummary(name: "Edit", input: ["file_path": "/a/b/File.swift"]),
            "File.swift"
        )
        XCTAssertEqual(
            ClaudeStatusRules.toolSummary(name: "Glob", input: ["pattern": "**/*.swift"]),
            "**/*.swift"
        )
        XCTAssertEqual(ClaudeStatusRules.toolSummary(name: "Mystery", input: [:]), "Mystery")
    }
}
