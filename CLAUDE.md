# AgentRadar development checks

- Run `swift test` from the repository root after code changes. It runs the pure
  Core tests and the AppKit popover lifecycle tests. The lifecycle test guards
  against retaining a hidden SwiftUI popover after it closes.
- After any user-visible app change, run `scripts/reinstall-app.sh`. It runs
  `swift test`, builds the Release app, reinstalls it, and checks that it stays
  running and resumes status logging. If Command Line Tools are selected,
  prefix the command with
  `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
- For changes to timers, animations, status scans, or popover presentation,
  also profile the Release app with Xcode's Instruments Time Profiler. Open and
  close the popover while an agent is working, then record its closed state.
  The main thread should sleep between scans rather than continuously lay out
  SwiftUI views. Compare runs on the same Mac with a similar session workload.

Use XCTest performance tests with `XCTCPUMetric` for repeatable CPU measurements
and `XCTClockMetric` for latency measurements. Run performance tests with a
Release build and a per-machine baseline; shared CI timing alone is too noisy
to use as a strict CPU budget. Use Instruments to identify the hot call stacks
when a measurement regresses. `swift test` execution time is not a substitute
for app CPU measurement.
