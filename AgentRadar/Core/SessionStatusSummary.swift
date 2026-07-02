import Foundation

/// The single source of truth for status counts shown in the menu bar icon,
/// its tooltip, and the popover header. Every surface derives its numbers
/// from this type so they cannot drift apart.
struct SessionStatusSummary: Equatable {
    let attention: Int
    let working: Int
    let completed: Int
    let idle: Int
    let changed: Int

    static let empty = Self(statuses: [])

    init(statuses: [AgentStatus], changed: Int = 0) {
        attention = statuses.filter { $0 == .needsAttention }.count
        working = statuses.filter { $0 == .running || $0 == .thinking }.count
        completed = statuses.filter { $0 == .completed }.count
        idle = statuses.filter { $0 == .idle }.count
        self.changed = changed
    }

    var total: Int {
        attention + working + completed + idle
    }

    var ready: Int {
        completed + idle
    }

    /// Compact one-line summary for the popover header, listing only the
    /// non-zero buckets: "1 active • 2 need input • 5 ready".
    var headline: String {
        guard total > 0 else { return "No agents" }

        var parts: [String] = []
        if working > 0 { parts.append("\(working) active") }
        if attention > 0 {
            parts.append(attention == 1 ? "1 needs input" : "\(attention) need input")
        }
        if ready > 0 { parts.append("\(ready) ready") }
        return parts.joined(separator: " • ")
    }

    func tooltip() -> String {
        guard total > 0 else { return "No sessions detected" }
        return "Needs Input: \(attention) • In Progress: \(working) • Ready: \(ready) • Changed: \(changed)"
    }
}
