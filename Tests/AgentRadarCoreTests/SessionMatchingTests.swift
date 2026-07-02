import XCTest
@testable import AgentRadarCore

final class SessionMatchingTests: XCTestCase {
    private let myPID: Int32 = 999

    private func row(
        pid: Int32,
        name: String,
        tty: String,
        commandLine: String,
        ppid: Int32 = 1
    ) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid,
            ppid: ppid,
            processName: name,
            cpuPercent: 0,
            rssKB: 1024,
            stat: "S+",
            elapsedTime: "05:00",
            tty: "ttys0\(tty)",
            commandLine: commandLine
        )
    }

    /// A GUI row (tty "??") exactly as Claude.app's embedded helpers appear.
    private func guiRow(pid: Int32, name: String, commandLine: String) -> ProcessSnapshot {
        ProcessSnapshot(
            pid: pid,
            ppid: 1,
            processName: name,
            cpuPercent: 0,
            rssKB: 1024,
            stat: "S",
            elapsedTime: "05:00",
            tty: "??",
            commandLine: commandLine
        )
    }

    private func candidates(
        _ rows: [ProcessSnapshot],
        cache: inout [Int32: AgentCommandLineMatchCacheEntry]
    ) -> [SessionCandidate] {
        SessionMatching.sessionCandidates(
            in: ProcessTable(snapshots: rows),
            excludingPID: myPID,
            commandLineMatchCache: &cache
        )
    }

    private func candidates(_ rows: [ProcessSnapshot]) -> [SessionCandidate] {
        var cache: [Int32: AgentCommandLineMatchCacheEntry] = [:]
        return candidates(rows, cache: &cache)
    }

    func testExactNameRowOnRealTTYBecomesSession() {
        let matched = candidates([row(pid: 10, name: "claude", tty: "1", commandLine: "claude")])

        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched.first?.kind.binaryName, "claude")
        XCTAssertEqual(matched.first?.row.pid, 10)
    }

    func testGUIProcessesAreNotSessions() {
        let matched = candidates([
            guiRow(pid: 20, name: "claude", commandLine: "/Applications/Claude.app/Contents/Helpers/claude"),
        ])

        XCTAssertTrue(matched.isEmpty)
    }

    // Regression for 2864e2b: Claude.app's embedded helpers (ucomm "claude",
    // tty "??") must not suppress the command-line fallback that detects
    // terminal sessions wrapped by node.
    func testGUIProcessDoesNotSuppressCommandLineFallback() {
        let matched = candidates([
            guiRow(pid: 20, name: "claude", commandLine: "/Applications/Claude.app/Contents/Helpers/claude"),
            row(pid: 30, name: "node", tty: "2", commandLine: "node /Users/x/.nvm/bin/claude"),
        ])

        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched.first?.row.pid, 30)
        XCTAssertEqual(matched.first?.kind.binaryName, "claude")
    }

    func testExactMatchSuppressesFallbackRows() {
        let matched = candidates([
            row(pid: 10, name: "claude", tty: "1", commandLine: "claude"),
            row(pid: 30, name: "node", tty: "2", commandLine: "node /usr/local/bin/claude"),
        ])

        XCTAssertEqual(matched.map(\.row.pid), [10])
    }

    // Claude Code sometimes reports its version string as the process name;
    // the command line still identifies it.
    func testVersionStringProcessNameMatchedViaCommandLine() {
        let matched = candidates([
            row(pid: 40, name: "2.1.170", tty: "3", commandLine: "claude --continue"),
        ])

        XCTAssertEqual(matched.count, 1)
        XCTAssertEqual(matched.first?.kind.binaryName, "claude")
    }

    func testChildWorkersOnSameTTYAreDeduplicated() {
        let matched = candidates([
            row(pid: 10, name: "claude", tty: "1", commandLine: "claude"),
            row(pid: 11, name: "claude", tty: "1", commandLine: "claude", ppid: 10),
        ])

        XCTAssertEqual(matched.map(\.row.pid), [10])
    }

    func testSessionsOnDistinctTTYsAllMatch() {
        let matched = candidates([
            row(pid: 10, name: "claude", tty: "1", commandLine: "claude"),
            row(pid: 11, name: "claude", tty: "2", commandLine: "claude"),
            row(pid: 12, name: "codex", tty: "3", commandLine: "codex"),
        ])

        XCTAssertEqual(matched.count, 3)
        XCTAssertEqual(Set(matched.map(\.row.pid)), [10, 11, 12])
    }

    func testOwnPIDIsExcluded() {
        let matched = candidates([row(pid: myPID, name: "claude", tty: "1", commandLine: "claude")])

        XCTAssertTrue(matched.isEmpty)
    }

    func testCommandLineMatchCachePrunedToLiveMatchingRows() {
        var cache: [Int32: AgentCommandLineMatchCacheEntry] = [
            77: AgentCommandLineMatchCacheEntry(commandLine: "node bin/claude", agentNames: ["claude"]),
        ]

        _ = candidates([row(pid: 30, name: "node", tty: "2", commandLine: "node bin/claude")], cache: &cache)

        XCTAssertNil(cache[77], "dead PID must be pruned")
        XCTAssertEqual(cache[30]?.agentNames, ["claude"])
    }

    func testAgentBinFallbackNamesFindsBinPathsAndFirstToken() {
        let names = SessionMatching.agentBinFallbackNames(
            in: "node /Users/x/.local/bin/codex exec --json",
            matching: ["claude", "codex"]
        )
        XCTAssertEqual(names, ["codex"])

        let direct = SessionMatching.agentBinFallbackNames(
            in: "claude --continue",
            matching: ["claude", "codex"]
        )
        XCTAssertEqual(direct, ["claude"])

        let none = SessionMatching.agentBinFallbackNames(
            in: "vim notes.md",
            matching: ["claude", "codex"]
        )
        XCTAssertTrue(none.isEmpty)
    }

    func testElapsedTimeParsing() {
        XCTAssertEqual(SessionMatching.elapsedTime(from: "05:30"), 330)
        XCTAssertEqual(SessionMatching.elapsedTime(from: "01:02:03"), 3723)
        XCTAssertEqual(SessionMatching.elapsedTime(from: "2-01:02:03"), 176_523)
        XCTAssertEqual(SessionMatching.elapsedTime(from: "garbage"), 0)
    }
}
