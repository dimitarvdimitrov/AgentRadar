import XCTest
@testable import AgentRadarCore

final class SessionStatusSummaryTests: XCTestCase {
    // Regression: completed/idle sessions must never be counted as active.
    func testDoneSessionsAreNotCountedAsActive() {
        let summary = SessionStatusSummary(
            statuses: [.completed, .completed, .completed, .idle, .running]
        )

        XCTAssertEqual(summary.working, 1)
        XCTAssertEqual(summary.ready, 4)
        XCTAssertEqual(summary.headline, "1 active • 4 ready")
        XCTAssertTrue(summary.tooltip().contains("In Progress: 1"))
    }

    func testBucketsPartitionTotal() {
        let allStatuses = AgentStatus.allCases
        // Every mix of 4 statuses must partition exactly into the buckets.
        for a in allStatuses {
            for b in allStatuses {
                for c in allStatuses {
                    for d in allStatuses {
                        let statuses = [a, b, c, d]
                        let summary = SessionStatusSummary(statuses: statuses)
                        XCTAssertEqual(
                            summary.attention + summary.working + summary.completed + summary.idle,
                            statuses.count,
                            "statuses=\(statuses)"
                        )
                        XCTAssertEqual(summary.total, statuses.count)
                    }
                }
            }
        }
    }

    func testHeadlineListsOnlyNonZeroBuckets() {
        XCTAssertEqual(SessionStatusSummary(statuses: []).headline, "No agents")
        XCTAssertEqual(SessionStatusSummary(statuses: [.running]).headline, "1 active")
        XCTAssertEqual(
            SessionStatusSummary(statuses: [.needsAttention]).headline,
            "1 needs input"
        )
        XCTAssertEqual(
            SessionStatusSummary(statuses: [.needsAttention, .needsAttention]).headline,
            "2 need input"
        )
        XCTAssertEqual(
            SessionStatusSummary(statuses: [.thinking, .running, .needsAttention, .completed, .idle]).headline,
            "2 active • 1 needs input • 2 ready"
        )
    }

    func testTooltip() {
        XCTAssertEqual(SessionStatusSummary.empty.tooltip(), "No sessions detected")

        let summary = SessionStatusSummary(
            statuses: [.needsAttention, .running, .completed],
            changed: 2
        )
        XCTAssertEqual(
            summary.tooltip(),
            "Needs Input: 1 • In Progress: 1 • Ready: 1 • Changed: 2"
        )
    }

    // The menu bar icon and the popover header both consume this type, so
    // agreement between the two surfaces is structural. This pins the shared
    // derivation for the exact scenario from the original bug report: done
    // sessions showing green in the list while "8 active" appeared above.
    func testEightDoneSessionsReadAsReadyNotActive() {
        let summary = SessionStatusSummary(statuses: Array(repeating: .completed, count: 8))

        XCTAssertEqual(summary.headline, "8 ready")
        XCTAssertEqual(summary.working, 0)
        XCTAssertEqual(summary.tooltip(), "Needs Input: 0 • In Progress: 0 • Ready: 8 • Changed: 0")
    }

    func testChangedStateBadgeRequiresVisitingAnActiveState() {
        // A session that did work and settled: badge-eligible.
        var history: AgentStatusHistory = [.thinking]
        history.insert(AgentStatusHistory.bit(for: .completed))
        XCTAssertTrue(history.hasVisitedActiveState)

        // A session that has only ever been waiting: not badge-eligible.
        let idleOnly = AgentStatusHistory.bit(for: .idle)
        XCTAssertFalse(idleOnly.hasVisitedActiveState)

        XCTAssertTrue(AgentStatus.completed.isAwaitingUser)
        XCTAssertTrue(AgentStatus.idle.isAwaitingUser)
        XCTAssertTrue(AgentStatus.needsAttention.isAwaitingUser)
        XCTAssertFalse(AgentStatus.running.isAwaitingUser)
        XCTAssertFalse(AgentStatus.thinking.isAwaitingUser)
    }
}
