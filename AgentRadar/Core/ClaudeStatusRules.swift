import Foundation

/// Pure decision rules for Claude Code sessions: given the last relevant
/// transcript entry and its staleness, decide the session status. All file
/// and process I/O stays in AgentMonitor; everything here is testable with
/// in-memory fixtures.
enum ClaudeStatusRules {
    struct Outcome {
        let decision: StatusDecision
        let pendingToolCall: PendingToolCall?
    }

    /// The last assistant or user entry in a JSONL transcript tail.
    /// Skips system/progress metadata lines that Claude appends after turns.
    static func lastRelevantEntry(inTranscriptTail content: String) -> [String: Any]? {
        let lines = content.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .reversed()

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String else { continue }
            if type == "assistant" || type == "user" {
                return json
            }
        }
        return nil
    }

    /// The transcript is the source of truth — if it says the agent finished
    /// its turn, the agent IS waiting for user input, regardless of how long
    /// ago that was.
    static func decision(
        entry: [String: Any],
        staleness: TimeInterval,
        transcriptName: String
    ) -> Outcome? {
        let msgType = entry["type"] as? String ?? ""
        let message = entry["message"] as? [String: Any]
        let stopReason = message?["stop_reason"] as? String

        switch msgType {
        case "assistant":
            if stopReason == "end_turn" {
                return Outcome(
                    decision: StatusDecision(
                        status: .completed,
                        activity: "Task completed",
                        source: "claude_transcript",
                        details: "entry=assistant stop_reason=end_turn transcript=\(transcriptName) staleness=\(Int(staleness))s",
                        refreshLastActivity: false
                    ),
                    pendingToolCall: nil
                )
            } else if stopReason == "tool_use" {
                // Agent wants to use a tool
                if staleness < 3 {
                    // File was just updated or agent is actively working
                    return Outcome(
                        decision: StatusDecision(
                            status: .thinking,
                            activity: "Running tool...",
                            source: "claude_transcript",
                            details: "entry=assistant stop_reason=tool_use transcript=\(transcriptName) staleness=\(Int(staleness))s",
                            refreshLastActivity: true
                        ),
                        pendingToolCall: nil
                    )
                } else {
                    // Tool call sitting there — waiting for user approval
                    var pendingToolCall: PendingToolCall?
                    if let contentArray = message?["content"] as? [[String: Any]] {
                        for block in contentArray {
                            if block["type"] as? String == "tool_use" {
                                let name = block["name"] as? String ?? "Tool"
                                let input = block["input"] as? [String: Any] ?? [:]
                                let summary = toolSummary(name: name, input: input)
                                pendingToolCall = PendingToolCall(toolName: name, summary: summary)
                                break
                            }
                        }
                    }
                    return Outcome(
                        decision: StatusDecision(
                            status: .needsAttention,
                            activity: "Waiting for tool approval",
                            source: "claude_transcript",
                            details: "entry=assistant stop_reason=tool_use transcript=\(transcriptName) staleness=\(Int(staleness))s",
                            refreshLastActivity: false
                        ),
                        pendingToolCall: pendingToolCall
                    )
                }
            } else {
                // stop_reason is null — still streaming or waiting for API
                if staleness < 30 {
                    return Outcome(
                        decision: StatusDecision(
                            status: .thinking,
                            activity: "Thinking...",
                            source: "claude_transcript",
                            details: "entry=assistant stop_reason=nil transcript=\(transcriptName) staleness=\(Int(staleness))s",
                            refreshLastActivity: true
                        ),
                        pendingToolCall: nil
                    )
                } else {
                    // Stale — likely done or stalled
                    return Outcome(
                        decision: StatusDecision(
                            status: .completed,
                            activity: "Task completed",
                            source: "claude_transcript",
                            details: "entry=assistant stop_reason=nil transcript=\(transcriptName) staleness=\(Int(staleness))s",
                            refreshLastActivity: false
                        ),
                        pendingToolCall: nil
                    )
                }
            }

        case "user":
            // User sent a message or tool result — agent is working
            if staleness < 30 {
                return Outcome(
                    decision: StatusDecision(
                        status: .thinking,
                        activity: "Thinking...",
                        source: "claude_transcript",
                        details: "entry=user transcript=\(transcriptName) staleness=\(Int(staleness))s",
                        refreshLastActivity: true
                    ),
                    pendingToolCall: nil
                )
            } else {
                return Outcome(
                    decision: StatusDecision(
                        status: .running,
                        activity: "Active",
                        source: "claude_transcript",
                        details: "entry=user transcript=\(transcriptName) staleness=\(Int(staleness))s",
                        refreshLastActivity: true
                    ),
                    pendingToolCall: nil
                )
            }

        default:
            return nil
        }
    }

    /// Session id explicitly pinned on the claude command line via
    /// `--resume <uuid>`, `-r <uuid>`, or `--session-id <uuid>`.
    /// Returns nil for the bare `--resume` picker form.
    static func sessionID(fromCommandLine commandLine: String) -> String? {
        let parts = commandLine.split(separator: " ")

        for (index, part) in parts.enumerated() {
            var candidate: Substring?

            if part == "--resume" || part == "-r" || part == "--session-id" {
                if index + 1 < parts.count {
                    candidate = parts[index + 1]
                }
            } else if let equalsIndex = part.firstIndex(of: "="),
                      part[..<equalsIndex] == "--resume" || part[..<equalsIndex] == "--session-id" {
                candidate = part[part.index(after: equalsIndex)...]
            }

            guard let candidate else { continue }
            let value = String(candidate).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if UUID(uuidString: value) != nil {
                return value.lowercased()
            }
        }

        return nil
    }

    /// Generate a human-readable summary for a pending tool call
    static func toolSummary(name: String, input: [String: Any]) -> String {
        switch name {
        case "Bash":
            if let cmd = input["command"] as? String {
                return String(cmd.prefix(60))
            }
        case "Write", "Read", "Edit":
            if let path = input["file_path"] as? String {
                return URL(fileURLWithPath: path).lastPathComponent
            }
        case "Glob":
            if let pattern = input["pattern"] as? String {
                return pattern
            }
        case "Grep":
            if let query = input["query"] as? String {
                return query
            }
        default:
            break
        }
        return name
    }
}
