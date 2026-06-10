# Implementation Plan: State Change Indicator

## Problem Statement
Track, per detected agent session, every `AgentStatus` value the session has entered since the last time the popover was opened. A session should be considered changed when its state bitmap contains more than one bit. The app must show the changed-session count in the menu bar and popover, reset tracking when the popover opens, and show a blue dot on changed session rows for the current popover opening.

## Overall Direction
Add a small status-history bitmap to the existing `DetectedAgent` model and update it from the existing `AgentMonitor.applyStatusDecision(_:to:procState:treeCPU:)` status pipeline. Keep the live interval and the popover display snapshot separate:

- The live interval answers "which currently detected sessions have visited more than one state since the last popover open?" and drives the menu bar.
- The popover snapshot captures that answer at open time, drives the blue row dots and popover count for that opening, then the live interval is reset to each session's current state.

Use the app's current session identity, `DetectedAgent.id` / `AgentProcessIdentity` (`pid` plus process start time), as the tracking key. This matches the rest of the app's lifetime model and intentionally does not persist state-change history across process exits or restarts.

The aggregate changed-session count must be derived from the current `agents` array after each reconciliation, not maintained by incremental add/remove bookkeeping. That guarantees the menu bar badge clears when changed sessions exit, including the edge case where a scan removes all agents and no status decision is applied.

## Data Model and Reset Semantics
- Add a file-private or private `AgentStatusHistory: OptionSet` in `AgentRadar/AgentMonitor.swift`, backed by `UInt8`.
- Assign one bit for each current `AgentStatus`: `running`, `thinking`, `needsAttention`, `idle`, and `completed`.
- Add a computed `hasMultipleStates` using `rawValue.nonzeroBitCount > 1`.
- Add to `DetectedAgent`:
  - `private var statusHistory: AgentStatusHistory = []`
  - `var hasChangedStateSinceLastPopoverOpen: Bool { statusHistory.hasMultipleStates }`
  - `func recordStatusVisit(_ status: AgentStatus)`
  - `func resetStatusHistory(to status: AgentStatus)`
- Do not expose `AgentStatusHistory` through any internal `DetectedAgent` property or method signature. `DetectedAgent` is an internal class, so an internal getter like `@Published private(set) var statusHistory: AgentStatusHistory` would expose a file-private/private type and fail Swift access-control checks.
- Do not make `statusHistory` `@Published` unless the bitmap type is deliberately made internal. The UI should observe aggregate monitor properties and popover snapshot IDs, not the raw bitmap.
- Do not seed the bitmap in `DetectedAgent.init`; new agents currently default to `.running` before `updateStats` applies the first real status. Seeding in init would create false positives when the first scan immediately resolves to `.idle` or `.completed`.
- In `applyStatusDecision`, after the accepted decision is known, call `agent.recordStatusVisit(decision.status)` alongside the existing `agent.status = decision.status`.
- Add to `AgentMonitor`:
  - `@Published private(set) var changedSessionCount: Int = 0`
  - `@Published private(set) var popoverChangedSessionCount: Int = 0`
  - `@Published private(set) var popoverChangedAgentIDs: Set<String> = []`
  - `func prepareForPopoverOpen()`
  - `private func refreshChangedSessionCount()`
- `prepareForPopoverOpen()` should:
  1. Build `popoverChangedAgentIDs` from agents whose bitmap has more than one bit.
  2. Set `popoverChangedSessionCount`.
  3. Reset every current agent's bitmap to exactly its current `status` bit.
  4. Recompute `changedSessionCount` to zero unless a race introduced a fresh multi-state bitmap.
  5. Leave dead sessions discarded, matching existing `reconcile` cleanup.
- `reconcile(_:processTable:)` must call `refreshChangedSessionCount()` after removing dead agents, adding new agents, applying status decisions, sorting, and cleaning `knownProcessIdentities`. This call must happen even when `found` is empty and `updateStats` never calls `applyStatusDecision`.
- The `scan()` main-queue completion should call `onUpdate?(agents)` only after `reconcile` has refreshed `changedSessionCount`, so `AppDelegate` never renders a stale badge.

## UI Changes
- In the menu bar, preserve the existing three-bar status breakdown and add a compact blue count badge only when `changedSessionCount > 0`.
- Draw the badge inside the existing AppKit composited image in `AppDelegate.makeBreakdownIcon(animated:)`; no new image assets are needed.
- Badge treatment:
  - Existing 17x18 bar icon remains unchanged when the count is zero.
  - When changed count is positive, widen the image canvas, shift the bars left, and draw a system-blue rounded pill on the right with the white count text.
  - Use exact count text where it fits; if capping is necessary for very large counts, keep the exact count in the tooltip/accessibility label.
- In the popover header, add the snapshot count from `monitor.popoverChangedSessionCount`, e.g. a compact secondary line or pill reading `N changed` next to the active-session count.
- In each row, pass `monitor.popoverChangedAgentIDs.contains(agent.id)` into `AgentAvatarTileView`.
- Add `StateChangeDotView` in `PopoverView.swift` and render it at `.topLeading` of `AgentAvatarTileView`, offset outward from the 40x40 avatar tile. The current status badge remains at `.bottomTrailing`, so the two indicators occupy opposite corners.
- Use a blue fill with a thin window-background stroke for the dot so it remains visible on light/dark materials.

## Reset Timing
- Update `AppDelegate.togglePopover()` only in the branch where `popover.isShown == false`.
- Call `monitor?.prepareForPopoverOpen()` immediately before `popover.show(...)`.
- Refresh the menu bar summary immediately after the reset. Preferred implementation: `prepareForPopoverOpen()` recomputes `changedSessionCount` and then triggers `onUpdate?(agents)`, so `AppDelegate` reuses the normal summary path.
- Keep `monitor?.refreshPopoverDetails()` after opening as it is today. Hydration updates directory/session metadata and should not clear the popover snapshot.
- Closing the popover must not reset anything. The next reset happens on the next open.

## Scope Analysis

### Files to Modify
- `AgentRadar/AgentMonitor.swift` (`AgentStatus`, new private/file-private `AgentStatusHistory`, `DetectedAgent`, `AgentMonitor.applyStatusDecision`, `AgentMonitor.reconcile`, new `AgentMonitor.prepareForPopoverOpen`, new `AgentMonitor.refreshChangedSessionCount`): add private bitmap tracking, live changed-session count, popover snapshot IDs/count, reset behavior, and explicit aggregate refresh after every reconciliation/dead-agent removal.
- `AgentRadar/AppDelegate.swift` (`MenuBarStatusSummary`, `handleAgentUpdate`, `updateStatusBar`, `makeBreakdownIcon`, `togglePopover`): include changed count from `monitor.changedSessionCount` in summary, tooltip/accessibility label, menu bar badge drawing, and popover-open reset timing.
- `AgentRadar/PopoverView.swift` (`PopoverView`, `HeaderBar`, `AgentRowView`, `AgentAvatarTileView`, new `StateChangeDotView`): display snapshot count and blue row dot on changed sessions.
- `README.md` (`Menu Bar Icons`, `What it does`): update user-facing description of the menu bar changed-session badge and popover change indicator after implementation.
- `AgentRadar.xcodeproj/project.pbxproj`: only if the implementation explicitly expands scope to add an XCTest target.

### Files to Create
- Baseline implementation: none.
- Optional test-scope expansion: `AgentRadarTests/StateChangeTrackingTests.swift` and/or `AgentRadarTests/PopoverStateSnapshotTests.swift`, but only together with an XCTest target and a deliberate access-control seam.

### Dependencies
- No new runtime dependencies.
- No new asset catalog entries; render the menu bar badge and popover dot in AppKit/SwiftUI.
- Baseline implementation does not add test dependencies.
- If adding tests, add a standard XCTest bundle target to `AgentRadar.xcodeproj`; the current project has only the app target. The project-file work must include target creation, source membership, host app/test host settings, and scheme/test action updates.

## Testing Plan

### Existing Tests to Update
- None. The repository currently has no XCTest target or checked-in test files.

### New Tests Required
- Baseline: no checked-in XCTest files are required because this repository currently has no test target.
- If adding an XCTest target, first choose one of these access-control seams:
  - Extract pure status-history logic into an internal testable type that does not require constructing `DetectedAgent`.
  - Make `AgentStatusHistory` internal and expose only test-appropriate internal helpers under `@testable import`.
  - Add an internal monitor test helper that drives status visits and popover preparation without exposing private process-inspection details.
- With that seam in place, add tests covering unique bits per `AgentStatus`, repeated same-state decisions, two-state detection, reset-to-current behavior, popover snapshot IDs/count, and aggregate count refresh after dead-agent removal.

### Benchmarks
- No benchmark required. The added work is O(number of detected agents) per scan/open and uses a single-byte bitmap per agent.

### Focused Verification Steps
1. Build:
   ```bash
   xcodebuild -project AgentRadar.xcodeproj \
     -scheme AgentRadar \
     -configuration Release \
     -derivedDataPath build \
     build
   ```
2. Because this is a user-visible app change, run:
   ```bash
   scripts/reinstall-app.sh
   ```
3. With one detected session, open the popover once to reset; verify the menu bar changed badge disappears and the popover shows `0 changed`.
4. Let that session transition across two statuses, for example `thinking` to `idle` or `idle` to `needsAttention`; verify the menu bar shows a blue count badge with `1`.
5. Open the popover; verify the header shows `1 changed`, the changed row has a blue dot at the top-left of the agent tile, and the existing current-state badge remains bottom-right.
6. Without closing the app, close and reopen the popover before any new state transition; verify the changed count resets to `0` and row dots clear.
7. Repeat with multiple sessions and confirm the count reflects sessions with more than one visited state, not the number of transitions.
8. Check empty state/no-agent behavior: no badge in the menu bar and no stale popover snapshot.

## Documentation Updates
- `README.md`: update "What it does" to mention state-change tracking since last popover open.
- `README.md`: replace or revise the stale "Menu Bar Icons" table so it describes the current three-bar breakdown plus the new blue changed-session count badge.

## Parallel Tracks

### Track 1: State Tracking Model
**Can start immediately**
- Add private/file-private `AgentStatusHistory` and `DetectedAgent` history helpers in `AgentRadar/AgentMonitor.swift`, without exposing the bitmap type through internal model API.
- Hook `recordStatusVisit(_:)` into `applyStatusDecision`.
- Add `AgentMonitor.prepareForPopoverOpen()` and changed-count recomputation.
- Add the explicit `refreshChangedSessionCount()` call at the end of `reconcile(_:processTable:)`, after dead-agent removal and status updates.
- Decide the optional test seam here if the implementation is going to add an XCTest target.
- Dependencies: None.

### Track 2: Menu Bar Summary and Badge
**Requires Track 1 completion**
- Extend `MenuBarStatusSummary` in `AgentRadar/AppDelegate.swift` with `changed: Int`.
- Compute `changed` from `AgentMonitor.changedSessionCount` or the agents' `hasChangedStateSinceLastPopoverOpen` values.
- Draw the blue count badge in `makeBreakdownIcon(animated:)`.
- Update tooltip and accessibility label.
- Dependencies: Track 1.

### Track 3: Popover Snapshot UI
**Requires Track 1 completion**
- Pass `monitor.popoverChangedSessionCount` into `HeaderBar`.
- Pass per-row snapshot membership into `AgentAvatarTileView`.
- Add `StateChangeDotView` and render it at the top-left corner opposite the current status badge.
- Dependencies: Track 1.

### Track 4: Verification and Docs
**Requires Tracks 1-3 completion**
- Build, reinstall, and run focused manual verification.
- Update README text after final UI treatment is in place.
- Add XCTest target/tests only if Track 1 already chose a testable access-control seam and the project accepts introducing a test bundle.
- Dependencies: Tracks 1-3.

## Implementation Order
1. Implement private/file-private `AgentStatusHistory` and `DetectedAgent` helper API in `AgentRadar/AgentMonitor.swift` without exposing the bitmap type from internal properties or methods.
2. Update `AgentMonitor.applyStatusDecision` to record status visits after each accepted decision.
3. Add monitor-level changed counts, `refreshChangedSessionCount()`, and `prepareForPopoverOpen()` in `AgentRadar/AgentMonitor.swift`.
4. Call `refreshChangedSessionCount()` at the end of `reconcile(_:processTable:)` after dead-agent removal, additions, status updates, sorting, and `knownProcessIdentities` cleanup.
5. Ensure every `onUpdate?(agents)` path that can affect the menu bar runs after the aggregate count is current, including the popover-open reset path.
6. Update `AppDelegate.togglePopover()` to prepare the popover snapshot before `popover.show(...)` and reset the menu bar summary immediately through the normal update path.
7. Extend `MenuBarStatusSummary` and status-bar drawing in `AgentRadar/AppDelegate.swift`.
8. Update `PopoverView`, `HeaderBar`, `AgentRowView`, and `AgentAvatarTileView` to render snapshot count and row dots.
9. Build, reinstall, and manually verify the reset and display behavior.
10. Update README once the visible treatment is final.

## Risks and Considerations
- Initial status false positives: avoid by leaving the bitmap empty until the first real `StatusDecision`.
- Swift access control: keep raw bitmap storage private or make the bitmap type internal; do not expose a file-private/private `AgentStatusHistory` through an internal `DetectedAgent` property such as `@Published private(set)`.
- Nested observation: `DetectedAgent` is an `ObservableObject` inside `AgentMonitor.agents`; keep aggregate counts as monitor-level `@Published` values so the header and menu bar do not rely on nested object changes propagating through the agents array.
- Aggregate staleness after process exit: recompute `changedSessionCount` from the current `agents` array at the end of every reconciliation, including empty `found` scans, so dead changed sessions cannot leave a stale menu bar badge.
- Popover-open race: all monitor reconciliation currently returns to the main queue before mutating agents; keep `prepareForPopoverOpen()` main-thread-only and call it from `AppDelegate.togglePopover()`.
- Hydration reorder: `refreshPopoverDetails()` can sort agents after the popover opens; snapshot row indicators should key by `agent.id`, not row index.
- Grouped view visibility: row dots appear only on visible rows. The header count still shows the snapshot count if a changed row is inside a collapsed group.
- Count semantics: count sessions with more than one distinct visited status, not total status changes.
- Dead sessions: existing reconciliation removes dead agents and their caches; the changed count should cover currently detected sessions only.
- Testability: a separate XCTest target cannot reach file-private/private monitor internals such as `AgentProcessIdentity`, `StatusDecision`, `DetectedAgent.init`, or `applyStatusDecision`; if tests are added, establish a pure internal seam before writing test files.

## Appendix
- Current status pipeline: `AgentMonitor.updateStats` decides statuses and funnels them through `applyStatusDecision`.
- Current popover open path: `AppDelegate.togglePopover()` calls `popover.show(...)`, then `monitor?.refreshPopoverDetails()`.
- Current row avatar layout: `AgentAvatarTileView` renders the status badge at bottom-right, leaving top-left available for the blue state-change dot.
