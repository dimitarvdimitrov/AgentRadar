# Agent Instructions

## Repo Overview

- Native macOS menu bar app built with Xcode and SwiftUI.
- Main target: `AgentRadar`
- Project file: `AgentRadar.xcodeproj`
- `AgentRadar/Core/` holds the pure decision logic (status rules, session
  matching, count summaries) with no file, process, or UI dependencies.
  `AgentMonitor.swift` does the I/O around it; `AppDelegate.swift` and
  `PopoverView.swift` render it.

## Code Structure Rules

- Keep decision logic pure and in `AgentRadar/Core/`. Functions there take
  values (a parsed transcript entry, a process row, a list of statuses) and
  return values. File reads, `ps` snapshots, git shell-outs, timers, and
  caches stay in `AgentMonitor.swift`.
- Every user-facing count (menu bar icon, tooltip, popover header) must
  derive from `SessionStatusSummary`. Never count agents ad hoc in a view —
  that is how the "done sessions shown as active" bug happened.
- New Core source files must be added both to the app target in
  `project.pbxproj` and picked up by `Package.swift` (automatic — it
  compiles everything under `AgentRadar/Core/`).

## Testing

- `swift test` from the repo root runs the core test suite in
  `Tests/AgentRadarCoreTests/`. It compiles `AgentRadar/Core/` as a SwiftPM
  package, independent of Xcode.
- CI (`.github/workflows/ci.yml`) runs `swift test` plus a Release
  `xcodebuild` on every push and PR.
- `scripts/reinstall-app.sh` also runs `swift test` before building, and
  smoke-checks the relaunched app.

## How to Approach Bugs

1. **Find the root cause before changing code.** The main evidence source is
   `~/Library/Logs/AgentRadar/status.log`: every status decision is logged
   with its source (`claude_transcript`, `codex_session`, `proc_state`,
   `child_process`), the transcript/session file it came from, and staleness.
   Hovering a row's timestamp in the popover shows the same debug details.
   The log rotates at 50MB to `status.log.1`.
2. **Capture the offending input as a fixture first.** Before fixing,
   reproduce the bug in `Tests/AgentRadarCoreTests/` with the real input that
   triggered it — a transcript JSONL snippet, a codex session tail, a `ps`
   row, or a status mix. Watch the test fail. Past bugs pinned this way:
   done sessions counted as active (`SessionStatusSummaryTests`), Claude.app
   GUI helpers suppressing session detection (`SessionMatchingTests`),
   status flapping (`ClaudeStatusRulesTests`).
3. **Fix in the Core rules, not at the call site.** If the buggy logic is
   still inside `AgentMonitor.swift` (I/O-entangled), extract the decision
   into `AgentRadar/Core/` first, then fix it under test.
4. **Verify end to end.** Run `swift test`, then `scripts/reinstall-app.sh`,
   then confirm against real sessions via `status.log` and the popover.

## Git Workflow

- The fork remote is `fork` and points at `dimitarvdimitrov/AgentRadar`.
- The default branch is `main`.
- When feature work should be merged into the fork, merge or fast-forward it into `fork/main`, push that branch, and leave the local checkout on `main`.
- After merging feature work, continue working from the default branch unless the user asks for a separate branch.

## Build

- Requires full Xcode, not just Command Line Tools.
- If Xcode has not been initialized yet, run:
  - `xcodebuild -runFirstLaunch`
- After every user-visible app change, run `scripts/reinstall-app.sh` from the repo root. The script builds the release app, quits the installed app, copies the new bundle into `/Applications`, and relaunches it.

- Build a local unsigned release app from the repo root:

```bash
xcodebuild -project AgentRadar.xcodeproj \
  -scheme AgentRadar \
  -configuration Release \
  -derivedDataPath build \
  build
```

- Output app bundle:
  - `build/Build/Products/Release/AgentRadar.app`

## Run

- Launch the local build:
  - `open build/Build/Products/Release/AgentRadar.app`

## Install

- Install the local build into `/Applications`:

```bash
ditto build/Build/Products/Release/AgentRadar.app /Applications/AgentRadar.app
open /Applications/AgentRadar.app
```

- Preferred workflow for user-visible app changes:

```bash
scripts/reinstall-app.sh
```

## Notes

- No paid Apple developer account is required for the local build above.
- The project is configured for local ad-hoc signing (`CODE_SIGN_IDENTITY = -`), so the built app keeps a stable macOS identity without a paid Apple developer account.
