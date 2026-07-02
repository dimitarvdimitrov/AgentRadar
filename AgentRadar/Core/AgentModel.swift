import Foundation

// MARK: - Agent Status

enum AgentStatus: Equatable, CaseIterable {
    case running
    case thinking
    case needsAttention
    case idle
    case completed

    var isAwaitingUser: Bool {
        switch self {
        case .needsAttention, .idle, .completed:
            return true
        case .running, .thinking:
            return false
        }
    }
}

struct AgentStatusHistory: OptionSet {
    let rawValue: UInt8

    static let running = AgentStatusHistory(rawValue: 1 << 0)
    static let thinking = AgentStatusHistory(rawValue: 1 << 1)
    static let needsAttention = AgentStatusHistory(rawValue: 1 << 2)
    static let idle = AgentStatusHistory(rawValue: 1 << 3)
    static let completed = AgentStatusHistory(rawValue: 1 << 4)

    static let activeStates: AgentStatusHistory = [.running, .thinking]

    var hasVisitedActiveState: Bool {
        !isDisjoint(with: Self.activeStates)
    }

    static func bit(for status: AgentStatus) -> AgentStatusHistory {
        switch status {
        case .running:
            return .running
        case .thinking:
            return .thinking
        case .needsAttention:
            return .needsAttention
        case .idle:
            return .idle
        case .completed:
            return .completed
        }
    }
}

// MARK: - Pending Tool Call

struct PendingToolCall {
    let toolName: String    // "Bash", "Write", "Edit", etc.
    let summary: String     // "npx tsc --noEmit", "/foo/bar.swift", etc.
}

// MARK: - Known Agent Binary

struct KnownAgent {
    let binaryName: String       // exact process name
    let displayName: String
    let icon: String             // SF Symbol
    let customIcon: String?      // Custom asset name
    let color: String            // hex

    static let all: [KnownAgent] = [
        KnownAgent(binaryName: "claude", displayName: "Claude Code", icon: "sparkles", customIcon: "claude-icon", color: "#D97706"),
        KnownAgent(binaryName: "codex", displayName: "Codex CLI", icon: "terminal.fill", customIcon: "codex-icon", color: "#10B981"),
        KnownAgent(binaryName: "gemini", displayName: "Gemini CLI", icon: "g.circle.fill", customIcon: "gemini-icon", color: "#3B82F6"),
        KnownAgent(binaryName: "aider", displayName: "Aider", icon: "hammer.fill", customIcon: nil, color: "#EC4899"),
        KnownAgent(binaryName: "continue", displayName: "Continue", icon: "arrow.triangle.2.circlepath", customIcon: nil, color: "#F59E0B"),
        KnownAgent(binaryName: "opencode", displayName: "OpenCode", icon: "chevron.left.forwardslash.chevron.right", customIcon: nil, color: "#0EA5E9"),
    ]
}

// MARK: - Status Decision

struct StatusDecision {
    let status: AgentStatus
    let activity: String
    let source: String
    let details: String
    let refreshLastActivity: Bool
}
