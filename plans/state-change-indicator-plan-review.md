# Plan Review: State Change Indicator

## Verdict: NEEDS REVISION

## Critical Concerns
- `AgentRadar/AgentMonitor.swift`: The proposed `fileprivate AgentStatusHistory` conflicts with `@Published private(set) var statusHistory: AgentStatusHistory` on `DetectedAgent`. `private(set)` leaves the getter at the property's default access level, so an internal model property would expose a file-private type and fail to compile. Either make the history type internal, or keep the bitmap storage private/file-private and expose only internal helpers such as `hasChangedStateSinceLastPopoverOpen`, `recordStatusVisit`, and `resetStatusHistory`.
- `AgentRadar/AgentMonitor.swift`: The plan does not explicitly require `changedSessionCount` to be recomputed after reconciliation removes dead agents, especially when the scan removes all agents and `updateStats` never calls `applyStatusDecision`. Since `scan()` still calls `onUpdate?(agents)` after `reconcile`, a stale changed-session badge could remain in the menu bar after changed sessions exit. `reconcile` should refresh the aggregate count after removal/addition/status updates, or otherwise guarantee the count always reflects the current `agents` array.

## Missing Scope
- `AgentRadar/AgentMonitor.swift`: If the optional XCTest path is taken, the plan needs an access-control/testing seam. `AgentStatusHistory`, `AgentProcessIdentity`, `StatusDecision`, `DetectedAgent.init`, and `applyStatusDecision` are currently private/file-private in the app target, so the proposed tests cannot directly exercise the bitmap or popover snapshot semantics from a separate `AgentRadarTests` target unless the implementation deliberately exposes testable internal API or extracts pure logic.
- `AgentRadar.xcodeproj/project.pbxproj`: The plan says tests are optional in one section but "New Tests Required" in another. Adding any checked-in XCTest files is not optional from the project-file perspective; the test target, source membership, host app, and scheme/test action must be in scope if those tests are expected to run.

## Parallel Track Issues
- Track 4 cannot independently add the proposed tests after Track 1 unless Track 1 first settles the access-level problem. Otherwise the tests will either be unable to compile or will force late production API changes.
