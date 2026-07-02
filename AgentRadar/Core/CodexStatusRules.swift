import Foundation

struct CodexStatusProbe {
    let decision: StatusDecision?
    let debug: String
}

/// Pure decision rules for Codex CLI sessions: given the tail of a rollout
/// session file, decide the session status from its `event_msg` entries.
enum CodexStatusRules {
    static func probe(
        fromSessionTail content: String,
        sessionName: String,
        readSize: UInt64
    ) -> CodexStatusProbe {
        let lines = content
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .reversed()
        var recentEventTypes: [String] = []
        var eventMsgCount = 0

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else {
                continue
            }

            eventMsgCount += 1
            if recentEventTypes.count < 8 {
                recentEventTypes.append(eventType)
            }

            switch eventType {
            case "task_started":
                return CodexStatusProbe(
                    decision: StatusDecision(
                        status: .thinking,
                        activity: "Working...",
                        source: "codex_session",
                        details: "event=task_started session=\(sessionName) timestamp=\(json["timestamp"] as? String ?? "-")",
                        refreshLastActivity: true
                    ),
                    debug: "status=task_started session=\(sessionName)"
                )
            case "task_complete", "turn_aborted":
                return CodexStatusProbe(
                    decision: StatusDecision(
                        status: .idle,
                        activity: "Ready",
                        source: "codex_session",
                        details: "event=\(eventType) session=\(sessionName) timestamp=\(json["timestamp"] as? String ?? "-")",
                        refreshLastActivity: false
                    ),
                    debug: "status=\(eventType) session=\(sessionName)"
                )
            default:
                continue
            }
        }

        let recentEvents = recentEventTypes.isEmpty ? "-" : recentEventTypes.joined(separator: ",")
        return CodexStatusProbe(
            decision: nil,
            debug: "status=no_task_event session=\(sessionName) event_msgs=\(eventMsgCount) recent_events=\(recentEvents) read_size=\(readSize)"
        )
    }

    static func resumeSessionID(from commandLine: String) -> String? {
        let parts = commandLine.split(separator: " ")
        guard let resumeIndex = parts.firstIndex(where: { $0 == "resume" }) else { return nil }

        let sessionIndex = parts.index(after: resumeIndex)
        guard sessionIndex < parts.endIndex else { return nil }

        let sessionID = String(parts[sessionIndex]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return sessionID.isEmpty ? nil : sessionID
    }
}
