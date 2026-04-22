import Foundation
import Combine
import AppKit

// MARK: - Agent Status

enum AgentStatus: Equatable {
    case running
    case thinking
    case needsAttention
    case idle
    case completed
}

// MARK: - Pending Tool Call

struct PendingToolCall {
    let toolName: String    // "Bash", "Write", "Edit", etc.
    let summary: String     // "npx tsc --noEmit", "/foo/bar.swift", etc.
}

// MARK: - Known Agent Binary

struct KnownAgent {
    let binaryName: String       // exact name for pgrep -x
    let displayName: String
    let icon: String             // SF Symbol
    let customIcon: String?      // Custom asset name
    let color: String            // hex

    static let all: [KnownAgent] = [
        KnownAgent(binaryName: "claude", displayName: "Claude Code", icon: "sparkles", customIcon: "claude-icon", color: "#D97706"),
        KnownAgent(binaryName: "codex", displayName: "Codex CLI", icon: "terminal.fill", customIcon: nil, color: "#10B981"),
        KnownAgent(binaryName: "gemini", displayName: "Gemini CLI", icon: "g.circle.fill", customIcon: "gemini-icon", color: "#3B82F6"),
        KnownAgent(binaryName: "aider", displayName: "Aider", icon: "hammer.fill", customIcon: nil, color: "#EC4899"),
        KnownAgent(binaryName: "continue", displayName: "Continue", icon: "arrow.triangle.2.circlepath", customIcon: nil, color: "#F59E0B"),
        KnownAgent(binaryName: "opencode", displayName: "OpenCode", icon: "chevron.left.forwardslash.chevron.right", customIcon: nil, color: "#0EA5E9"),
    ]
}

private struct DetectedAgentSnapshot {
    let pid: Int32
    let kind: KnownAgent
    let startTime: Date
    let cwd: String
    let cmd: String
    let tty: String
    let codexSessionIDHint: String?
    var gitBranch: String?
    var gitRepoRoot: String?
}

private struct GitRepoCacheEntry {
    let repoRoot: String
    let gitDir: String
    var branch: String?
    var headSignature: String?
    var lastCheckedAt: Date
}

private struct GitLookupCacheEntry {
    let repoKey: String?
    let isNonGit: Bool
    let expiresAt: Date?
}

private struct CodexSessionMetadata {
    let id: String
    let cwd: String
    let startedAt: Date
}

private struct StatusDecision {
    let status: AgentStatus
    let activity: String
    let source: String
    let details: String
    let refreshLastActivity: Bool
}

// MARK: - Detected Agent

class DetectedAgent: ObservableObject, Identifiable {
    let id: String
    let pid: Int32
    let kind: KnownAgent
    let startTime: Date
    var workingDirectory: String
    var commandLine: String
    var tty: String
    var codexSessionIDHint: String?
    var codexSessionPath: String?
    var ownerAppPID: pid_t?      // PID of the .app that owns this agent's terminal

    @Published var status: AgentStatus
    @Published var lastActivity: Date
    @Published var cpuPercent: Double = 0
    @Published var memoryMB: Double = 0
    @Published var currentActivity: String = ""
    @Published var childCommand: String = ""
    @Published var appIcon: NSImage?
    @Published var appName: String?
    @Published var pendingToolCall: PendingToolCall?
    @Published var gitBranch: String?
    @Published var gitRepoRoot: String?
    @Published var statusDebugSource: String = ""
    @Published var statusDebugDetails: String = ""

    var displayName: String {
        let dir = URL(fileURLWithPath: workingDirectory).lastPathComponent
        return dir.isEmpty ? kind.displayName : "\(kind.displayName) — \(dir)"
    }

    var directoryDisplayName: String {
        URL(fileURLWithPath: workingDirectory).lastPathComponent
    }

    var branchDisplayLabel: String {
        gitBranch ?? ""
    }

    var lastActivityString: String {
        let seconds = Int(Date().timeIntervalSince(lastActivity))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 600 {
            return "\(seconds / 60)m\(seconds % 60)s"
        }
        if seconds < 86400 {
            return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
        }
        return lastActivity.formatted(date: .abbreviated, time: .shortened)
    }

    var uptimeString: String {
        let seconds = Int(Date().timeIntervalSince(startTime))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    init(
        pid: Int32,
        kind: KnownAgent,
        startTime: Date,
        workingDirectory: String,
        commandLine: String,
        tty: String,
        codexSessionIDHint: String?
    ) {
        self.id = "\(pid)"
        self.pid = pid
        self.kind = kind
        self.startTime = startTime
        self.workingDirectory = workingDirectory
        self.commandLine = commandLine
        self.tty = tty
        self.codexSessionIDHint = codexSessionIDHint
        self.status = .running
        self.lastActivity = Date()
    }
}

// MARK: - Agent Monitor

class AgentMonitor: ObservableObject {
    @Published var agents: [DetectedAgent] = []
    @Published var lastScan: Date = Date()

    var onUpdate: (([DetectedAgent]) -> Void)?
    private var timer: Timer?
    private var knownPIDs: Set<Int32> = []
    private var gitRepoCache: [String: GitRepoCacheEntry] = [:]
    private var gitLookupCache: [String: GitLookupCacheEntry] = [:]
    private var codexSessionPathCache: [String: String] = [:]
    private var codexSessionMetadataCache: [String: CodexSessionMetadata] = [:]
    private var codexSessionMetadataFailureCache: [String: String] = [:]
    private var statusDecisionLogCache: [Int32: String] = [:]
    private var codexFallbackLogCache: [Int32: String] = [:]
    private let nonGitCacheTTL: TimeInterval = 10
    private lazy var statusLogURL: URL = {
        let logsDirectory = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Logs/AgentRadar", isDirectory: true)
        try? FileManager.default.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
        return logsDirectory.appendingPathComponent("status.log")
    }()

    func start() {
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.scan()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func scan() {
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            let found = self.resolveGitContext(for: self.detectAgents())

            DispatchQueue.main.async {
                self.reconcile(found)
                self.lastScan = Date()
                self.onUpdate?(self.agents)
            }
        }
    }

    // MARK: - Layer 1: Detect agents via pgrep

    private func detectAgents() -> [DetectedAgentSnapshot] {
        var results: [DetectedAgentSnapshot] = []
        let myPID = ProcessInfo.processInfo.processIdentifier
        let now = Date()
        var seenPIDs = Set<Int32>()

        for agent in KnownAgent.all {
            // Try exact binary match first (compiled CLIs like claude),
            // then fall back to command-line match (Node/Python CLIs like gemini, codex)
            var pgrepOutput = shell("pgrep -x \(agent.binaryName) 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if pgrepOutput.isEmpty {
                pgrepOutput = shell("pgrep -f 'bin/\(agent.binaryName)($| )' 2>/dev/null")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !pgrepOutput.isEmpty else { continue }

            let pids = pgrepOutput.components(separatedBy: "\n")
                .compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
                .sorted()  // Lowest PID first (parent process)

            // Track TTYs to avoid adding child workers on the same terminal
            var seenTTYs = Set<String>()

            for pid in pids {
                if pid == myPID || seenPIDs.contains(pid) { continue }

                // Get details: elapsed runtime, tty, stat, args
                let details = shell("ps -p \(pid) -o etime=,tty=,stat=,args= 2>/dev/null")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !details.isEmpty else { continue }

                let parts = details.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
                guard parts.count >= 3 else { continue }

                let elapsedTime = Self.elapsedTime(from: String(parts[0]))
                let tty = String(parts[1])
                // Skip processes not on a real TTY (GUI apps show "??")
                guard tty != "??" else { continue }
                // Skip duplicate agents on the same TTY (child node workers)
                guard !seenTTYs.contains(tty) else { continue }
                seenTTYs.insert(tty)

                let cmd = parts.count >= 4 ? String(parts[3]) : agent.binaryName
                let cwd = getWorkingDirectory(for: pid)
                results.append(
                    DetectedAgentSnapshot(
                        pid: pid,
                        kind: agent,
                        startTime: now.addingTimeInterval(-elapsedTime),
                        cwd: cwd,
                        cmd: cmd,
                        tty: tty,
                        codexSessionIDHint: agent.binaryName == "codex"
                            ? Self.codexResumeSessionID(from: cmd)
                            : nil
                    )
                )
                seenPIDs.insert(pid)
            }
        }
        return results
    }

    // MARK: - Reconcile

    private func reconcile(_ found: [DetectedAgentSnapshot]) {
        let foundPIDs = Set(found.map { $0.pid })
        let foundByPID = Dictionary(uniqueKeysWithValues: found.map { ($0.pid, $0) })
        let deadPIDs = Set(agents.map { $0.pid }).subtracting(foundPIDs)

        // Remove dead agents
        agents.removeAll { !foundPIDs.contains($0.pid) }
        for pid in deadPIDs {
            statusDecisionLogCache.removeValue(forKey: pid)
            codexFallbackLogCache.removeValue(forKey: pid)
        }

        // Add new agents
        for item in found {
            if !knownPIDs.contains(item.pid) {
                let agent = DetectedAgent(
                    pid: item.pid,
                    kind: item.kind,
                    startTime: item.startTime,
                    workingDirectory: item.cwd,
                    commandLine: item.cmd,
                    tty: item.tty,
                    codexSessionIDHint: item.codexSessionIDHint
                )
                // Layer 2: find the owning app for this agent
                agent.ownerAppPID = findOwnerAppPID(pid: item.pid)
                if let ownerPID = agent.ownerAppPID, let app = NSRunningApplication(processIdentifier: ownerPID) {
                    agent.appIcon = app.icon
                    agent.appName = app.localizedName
                } else if let appName = findOwnerAppName(pid: item.pid) {
                    agent.appName = appName
                    let workspace = NSWorkspace.shared
                    if let path = workspace.fullPath(forApplication: appName) {
                        agent.appIcon = workspace.icon(forFile: path)
                    }
                }
                agent.gitBranch = item.gitBranch
                agent.gitRepoRoot = item.gitRepoRoot
                agents.append(agent)
                knownPIDs.insert(item.pid)
            }
        }

        for agent in agents {
            guard let item = foundByPID[agent.pid] else { continue }
            if agent.codexSessionIDHint != item.codexSessionIDHint || agent.workingDirectory != item.cwd {
                agent.codexSessionPath = nil
            }
            agent.workingDirectory = item.cwd
            agent.commandLine = item.cmd
            agent.tty = item.tty
            agent.codexSessionIDHint = item.codexSessionIDHint
            agent.gitBranch = item.gitBranch
            agent.gitRepoRoot = item.gitRepoRoot
        }

        // Update stats for all agents
        for agent in agents {
            updateStats(agent)
        }

        agents.sort(by: Self.menuSortsBefore)

        // Clean up dead PIDs
        knownPIDs = knownPIDs.intersection(foundPIDs)
    }

    // MARK: - Git Context

    private func resolveGitContext(for detections: [DetectedAgentSnapshot]) -> [DetectedAgentSnapshot] {
        detections.map { detection in
            var detection = detection
            if let gitContext = gitContext(for: detection.cwd) {
                detection.gitBranch = gitContext.branch
                detection.gitRepoRoot = gitContext.repoRoot
            }
            return detection
        }
    }

    private func gitContext(for workingDirectory: String) -> (branch: String?, repoRoot: String)? {
        let normalizedPath = normalizePath(workingDirectory)
        guard normalizedPath.hasPrefix("/") else { return nil }

        let now = Date()

        if let lookup = gitLookupCache[normalizedPath] {
            if lookup.isNonGit {
                if let expiresAt = lookup.expiresAt, expiresAt > now {
                    return nil
                }
                gitLookupCache.removeValue(forKey: normalizedPath)
            } else if let repoKey = lookup.repoKey,
                      var repoEntry = gitRepoCache[repoKey] {
                refreshGitBranch(for: &repoEntry)
                gitRepoCache[repoKey] = repoEntry
                return (repoEntry.branch, repoEntry.repoRoot)
            }
        }

        if let repoKey = cachedRepoKey(containing: normalizedPath),
           var repoEntry = gitRepoCache[repoKey] {
            gitLookupCache[normalizedPath] = GitLookupCacheEntry(repoKey: repoKey, isNonGit: false, expiresAt: nil)
            refreshGitBranch(for: &repoEntry)
            gitRepoCache[repoKey] = repoEntry
            return (repoEntry.branch, repoEntry.repoRoot)
        }

        guard let repoIdentity = bootstrapGitRepo(for: normalizedPath) else {
            gitLookupCache[normalizedPath] = GitLookupCacheEntry(
                repoKey: nil,
                isNonGit: true,
                expiresAt: now.addingTimeInterval(nonGitCacheTTL)
            )
            return nil
        }

        var repoEntry = gitRepoCache[repoIdentity.gitDir] ?? GitRepoCacheEntry(
            repoRoot: repoIdentity.repoRoot,
            gitDir: repoIdentity.gitDir,
            branch: nil,
            headSignature: nil,
            lastCheckedAt: now
        )
        repoEntry.lastCheckedAt = now
        refreshGitBranch(for: &repoEntry)
        gitRepoCache[repoIdentity.gitDir] = repoEntry
        gitLookupCache[normalizedPath] = GitLookupCacheEntry(repoKey: repoIdentity.gitDir, isNonGit: false, expiresAt: nil)
        gitLookupCache[repoIdentity.repoRoot] = GitLookupCacheEntry(repoKey: repoIdentity.gitDir, isNonGit: false, expiresAt: nil)

        return (repoEntry.branch, repoEntry.repoRoot)
    }

    private func cachedRepoKey(containing path: String) -> String? {
        gitRepoCache.values
            .filter { entry in
                path == entry.repoRoot || path.hasPrefix(entry.repoRoot + "/")
            }
            .max { lhs, rhs in
                lhs.repoRoot.count < rhs.repoRoot.count
            }?
            .gitDir
    }

    private func bootstrapGitRepo(for path: String) -> (repoRoot: String, gitDir: String)? {
        let output = shell(
            "git -C \(shellQuoted(path)) rev-parse --show-toplevel --absolute-git-dir 2>/dev/null"
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let lines = output
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= 2 else { return nil }
        return (normalizePath(lines[0]), normalizePath(lines[1]))
    }

    private func refreshGitBranch(for entry: inout GitRepoCacheEntry) {
        entry.lastCheckedAt = Date()

        let headPath = entry.gitDir + "/HEAD"
        guard let signature = try? String(contentsOfFile: headPath, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) else {
            entry.branch = nil
            entry.headSignature = nil
            return
        }

        entry.headSignature = signature
        entry.branch = Self.branchName(fromHeadSignature: signature)
    }

    private static func menuSortsBefore(_ lhs: DetectedAgent, _ rhs: DetectedAgent) -> Bool {
        let lhsIsReady = lhs.status == .idle || lhs.status == .completed
        let rhsIsReady = rhs.status == .idle || rhs.status == .completed

        if lhsIsReady != rhsIsReady {
            return !lhsIsReady
        }

        if lhs.lastActivity != rhs.lastActivity {
            return lhs.lastActivity > rhs.lastActivity
        }

        if lhs.startTime != rhs.startTime {
            return lhs.startTime > rhs.startTime
        }

        return lhs.pid < rhs.pid
    }

    private static func elapsedTime(from value: String) -> TimeInterval {
        let parts = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: true)

        let dayCount: Int
        let clockPart: Substring

        if parts.count == 2 {
            dayCount = Int(parts[0]) ?? 0
            clockPart = parts[1]
        } else {
            dayCount = 0
            clockPart = parts[0]
        }

        let clockComponents = clockPart
            .split(separator: ":")
            .compactMap { Int($0) }

        switch clockComponents.count {
        case 2:
            let minutes = clockComponents[0]
            let seconds = clockComponents[1]
            return TimeInterval((dayCount * 24 * 60 * 60) + (minutes * 60) + seconds)
        case 3:
            let hours = clockComponents[0]
            let minutes = clockComponents[1]
            let seconds = clockComponents[2]
            return TimeInterval((dayCount * 24 * 60 * 60) + (hours * 60 * 60) + (minutes * 60) + seconds)
        default:
            return 0
        }
    }

    private static func codexResumeSessionID(from commandLine: String) -> String? {
        let parts = commandLine.split(separator: " ")
        guard let resumeIndex = parts.firstIndex(where: { $0 == "resume" }) else { return nil }

        let sessionIndex = parts.index(after: resumeIndex)
        guard sessionIndex < parts.endIndex else { return nil }

        let sessionID = String(parts[sessionIndex]).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return sessionID.isEmpty ? nil : sessionID
    }

    private func normalizePath(_ path: String) -> String {
        guard path.hasPrefix("/") else { return path }
        return (path as NSString).standardizingPath
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }

    private static func branchName(fromHeadSignature signature: String) -> String? {
        if signature.hasPrefix("ref: ") {
            let ref = String(signature.dropFirst(5))
            guard ref.hasPrefix("refs/heads/") else { return nil }
            let branch = String(ref.dropFirst("refs/heads/".count))
            return branch.isEmpty ? nil : branch
        }

        let hexCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEF")
        guard signature.count >= 7,
              signature.rangeOfCharacter(from: hexCharacters.inverted) == nil else {
            return nil
        }
        return String(signature.prefix(7))
    }

    // MARK: - Status Detection

    private func updateStats(_ agent: DetectedAgent) {
        // Get CPU and memory
        let statsOutput = shell("ps -p \(agent.pid) -o %cpu=,rss=,stat= 2>/dev/null")
        let statsParts = statsOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)

        var procState = ""
        if statsParts.count >= 2 {
            agent.cpuPercent = Double(statsParts[0]) ?? 0
            agent.memoryMB = (Double(statsParts[1]) ?? 0) / 1024.0
        }
        if statsParts.count >= 3 {
            procState = String(statsParts[2])
        }

        // Check if process is backgrounded or stopped first
        let isForeground = procState.contains("+")
        let isStopped = procState.contains("T")
        let treeCPU = totalTreeCPU(for: agent.pid)

        if isStopped {
            applyStatusDecision(
                StatusDecision(
                    status: .idle,
                    activity: "Stopped",
                    source: "proc_state",
                    details: "reason=stopped",
                    refreshLastActivity: false
                ),
                to: agent,
                procState: procState,
                treeCPU: treeCPU
            )
            return
        }

        // For Claude Code: use JSONL transcript for reliable status
        if agent.kind.binaryName == "claude" {
            if let decision = claudeStatusFromTranscript(agent, procState: procState, treeCPU: treeCPU) {
                applyStatusDecision(decision, to: agent, procState: procState, treeCPU: treeCPU)
                return
            }
        }

        // Codex also persists structured session logs; use them instead of CPU-only heuristics.
        if agent.kind.binaryName == "codex" {
            if let decision = codexStatusFromSession(agent) {
                agent.pendingToolCall = nil
                applyStatusDecision(decision, to: agent, procState: procState, treeCPU: treeCPU)
                return
            }
        }

        if !isForeground && !procState.isEmpty {
            applyStatusDecision(
                StatusDecision(
                    status: .idle,
                    activity: "Backgrounded",
                    source: "proc_state",
                    details: "reason=not_foreground\(codexLogContext(for: agent))",
                    refreshLastActivity: false
                ),
                to: agent,
                procState: procState,
                treeCPU: treeCPU
            )
            return
        }

        // Fallback for other agents: check child processes
        let childPids = shell("pgrep -P \(agent.pid) 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var hasActiveChildren = false
        var bestChild = ""

        if !childPids.isEmpty {
            let pidList = childPids.components(separatedBy: "\n").joined(separator: ",")
            let childOutput = shell("ps -o stat=,args= -p \(pidList) 2>/dev/null")

            for childLine in childOutput.components(separatedBy: "\n") {
                let trimmed = childLine.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                let cParts = trimmed.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
                guard cParts.count >= 2 else { continue }
                let stat = String(cParts[0])
                let childCmd = String(cParts[1])

                if childCmd.contains("pgrep") || childCmd.contains("ps -o") || childCmd.contains("ps -p") { continue }
                // Skip child processes that are the agent's own worker (e.g. node re-spawning gemini)
                if childCmd.contains("bin/\(agent.kind.binaryName)") { continue }
                let cmdLower = childCmd.lowercased()
                if cmdLower.hasPrefix("caffeinate") || cmdLower.hasPrefix("sleep") { continue }

                if stat.contains("R") || (stat.contains("S") && stat.contains("+") && !stat.contains("T")) {
                    hasActiveChildren = true
                    if bestChild.isEmpty {
                        bestChild = Self.readableCommand(childCmd)
                    }
                }
            }
        }

        agent.childCommand = bestChild

        if hasActiveChildren {
            applyStatusDecision(
                StatusDecision(
                    status: .thinking,
                    activity: bestChild,
                    source: "child_process",
                    details: bestChild.isEmpty ? "child=unknown" : "child=\(bestChild)",
                    refreshLastActivity: true
                ),
                to: agent,
                procState: procState,
                treeCPU: treeCPU
            )
        } else {
            if treeCPU > 3.0 {
                applyStatusDecision(
                    StatusDecision(
                        status: .thinking,
                        activity: "Thinking...",
                        source: "tree_cpu",
                        details: "reason=cpu_threshold",
                        refreshLastActivity: true
                    ),
                    to: agent,
                    procState: procState,
                    treeCPU: treeCPU
                )
            } else {
                applyStatusDecision(
                    StatusDecision(
                        status: .idle,
                        activity: "Ready",
                        source: "tree_cpu",
                        details: "reason=cpu_below_threshold\(codexLogContext(for: agent))",
                        refreshLastActivity: false
                    ),
                    to: agent,
                    procState: procState,
                    treeCPU: treeCPU
                )
            }
        }
    }

    // MARK: - Claude Code Transcript-Based Status

    /// Read the Claude Code JSONL transcript to determine actual agent status.
    /// The transcript is the source of truth — if it says the agent finished its turn,
    /// the agent IS waiting for user input, regardless of how long ago that was.
    private func claudeStatusFromTranscript(
        _ agent: DetectedAgent,
        procState: String,
        treeCPU: Double
    ) -> StatusDecision? {
        // Convert working directory to Claude's project dir format:
        // /Users/foo/bar → -Users-foo-bar
        let projectDirName = agent.workingDirectory.replacingOccurrences(of: "/", with: "-")
        let projectDir = NSHomeDirectory() + "/.claude/projects/" + projectDirName

        // Find the most recently modified .jsonl file
        guard let jsonlPath = mostRecentFile(in: projectDir, extension: "jsonl") else { return nil }

        // Check file modification time
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: jsonlPath),
              let mtime = attrs[.modificationDate] as? Date else { return nil }

        let staleness = Date().timeIntervalSince(mtime)
        let isActive = treeCPU > 3.0
        let transcriptName = URL(fileURLWithPath: jsonlPath).lastPathComponent

        // Read recent lines and find the last assistant/user entry
        // (skip system/progress metadata lines that Claude appends after turns)
        guard let entry = readLastRelevantEntry(of: jsonlPath) else {
            return nil
        }

        let msgType = entry["type"] as? String ?? ""
        let message = entry["message"] as? [String: Any]
        let stopReason = message?["stop_reason"] as? String

        switch msgType {
        case "assistant":
            if stopReason == "end_turn" {
                agent.pendingToolCall = nil
                return StatusDecision(
                    status: .completed,
                    activity: "Task completed",
                    source: "claude_transcript",
                    details: "entry=assistant stop_reason=end_turn transcript=\(transcriptName) staleness=\(Int(staleness))s",
                    refreshLastActivity: false
                )
            } else if stopReason == "tool_use" {
                // Agent wants to use a tool
                if staleness < 3 || isActive {
                    // File was just updated or agent is actively working
                    agent.pendingToolCall = nil
                    return StatusDecision(
                        status: .thinking,
                        activity: "Running tool...",
                        source: "claude_transcript",
                        details: "entry=assistant stop_reason=tool_use transcript=\(transcriptName) staleness=\(Int(staleness))s",
                        refreshLastActivity: true
                    )
                } else {
                    // Tool call sitting there — waiting for user approval
                    if let contentArray = message?["content"] as? [[String: Any]] {
                        for block in contentArray {
                            if block["type"] as? String == "tool_use" {
                                let name = block["name"] as? String ?? "Tool"
                                let input = block["input"] as? [String: Any] ?? [:]
                                let summary = Self.toolSummary(name: name, input: input)
                                agent.pendingToolCall = PendingToolCall(toolName: name, summary: summary)
                                break
                            }
                        }
                    }
                    return StatusDecision(
                        status: .needsAttention,
                        activity: "Waiting for tool approval",
                        source: "claude_transcript",
                        details: "entry=assistant stop_reason=tool_use transcript=\(transcriptName) staleness=\(Int(staleness))s",
                        refreshLastActivity: false
                    )
                }
            } else {
                // stop_reason is null — still streaming or waiting for API
                agent.pendingToolCall = nil
                if staleness < 30 || isActive {
                    return StatusDecision(
                        status: .thinking,
                        activity: "Thinking...",
                        source: "claude_transcript",
                        details: "entry=assistant stop_reason=nil transcript=\(transcriptName) staleness=\(Int(staleness))s",
                        refreshLastActivity: true
                    )
                } else {
                    // Stale and no CPU — likely done or stalled
                    return StatusDecision(
                        status: .completed,
                        activity: "Task completed",
                        source: "claude_transcript",
                        details: "entry=assistant stop_reason=nil transcript=\(transcriptName) staleness=\(Int(staleness))s",
                        refreshLastActivity: false
                    )
                }
            }

        case "user":
            // User sent a message or tool result — agent is working
            agent.pendingToolCall = nil
            if staleness < 30 || isActive {
                return StatusDecision(
                    status: .thinking,
                    activity: "Thinking...",
                    source: "claude_transcript",
                    details: "entry=user transcript=\(transcriptName) staleness=\(Int(staleness))s",
                    refreshLastActivity: true
                )
            } else {
                return StatusDecision(
                    status: .running,
                    activity: "Active",
                    source: "claude_transcript",
                    details: "entry=user transcript=\(transcriptName) staleness=\(Int(staleness))s",
                    refreshLastActivity: true
                )
            }

        default:
            return nil
        }
    }

    /// Find the most recently modified file with the given extension in a directory
    private func mostRecentFile(in directory: String, extension ext: String) -> String? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: directory) else { return nil }

        var bestPath: String?
        var bestDate: Date?

        for file in files where file.hasSuffix(".\(ext)") {
            let path = directory + "/" + file
            if let attrs = try? fm.attributesOfItem(atPath: path),
               let mtime = attrs[.modificationDate] as? Date {
                if bestDate == nil || mtime > bestDate! {
                    bestDate = mtime
                    bestPath = path
                }
            }
        }
        return bestPath
    }

    // MARK: - Codex Session-Based Status

    private func codexStatusFromSession(_ agent: DetectedAgent) -> StatusDecision? {
        let sessionsRoot = NSHomeDirectory() + "/.codex/sessions"
        let sessionLookup = codexSessionPath(for: agent, in: sessionsRoot)
        guard let sessionPath = sessionLookup.path else {
            logCodexFallbackIfNeeded(for: agent, reason: sessionLookup.debug)
            return nil
        }

        let statusProbe = codexStatus(fromSessionFile: sessionPath)
        guard let decision = statusProbe.decision else {
            logCodexFallbackIfNeeded(for: agent, reason: statusProbe.debug)
            return nil
        }

        codexFallbackLogCache.removeValue(forKey: agent.pid)
        return decision
    }

    private func codexSessionPath(
        for agent: DetectedAgent,
        in root: String
    ) -> (path: String?, debug: String) {
        let fm = FileManager.default

        if let path = agent.codexSessionPath, fm.fileExists(atPath: path) {
            if agent.codexSessionIDHint != nil {
                return (path, "lookup=cached session=\(URL(fileURLWithPath: path).lastPathComponent)")
            }

            let validation = validateCodexSessionPath(path, for: agent)
            if validation.isValid {
                return (path, validation.debug)
            }

            agent.codexSessionPath = nil
        }

        if let sessionID = agent.codexSessionIDHint,
           let path = codexSessionPath(forSessionID: sessionID, in: root) {
            agent.codexSessionPath = path
            return (path, "lookup=resume_hint hint=\(sessionID) session=\(URL(fileURLWithPath: path).lastPathComponent)")
        }

        let bestMatch = bestCodexSessionPath(in: root, agent: agent)
        guard let path = bestMatch.path else {
            if let sessionID = agent.codexSessionIDHint {
                return (nil, "lookup=resume_hint_miss hint=\(sessionID) \(bestMatch.debug)")
            }
            return (nil, bestMatch.debug)
        }

        agent.codexSessionPath = path
        return (path, bestMatch.debug)
    }

    private func codexSessionPath(forSessionID sessionID: String, in root: String) -> String? {
        let fm = FileManager.default

        if let cachedPath = codexSessionPathCache[sessionID], fm.fileExists(atPath: cachedPath) {
            return cachedPath
        }

        guard let enumerator = fm.enumerator(atPath: root) else { return nil }

        for case let relativePath as String in enumerator {
            guard relativePath.hasSuffix("\(sessionID).jsonl") else { continue }
            let path = root + "/" + relativePath
            codexSessionPathCache[sessionID] = path
            return path
        }

        return nil
    }

    private func bestCodexSessionPath(
        in root: String,
        agent: DetectedAgent
    ) -> (path: String?, debug: String) {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root) else {
            return (nil, "lookup=best_match root_unreadable root=\(root)")
        }

        var candidates: [(path: String, modifiedAt: Date)] = []

        for case let relativePath as String in enumerator {
            guard relativePath.hasSuffix(".jsonl") else { continue }
            let path = root + "/" + relativePath
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modifiedAt = attrs[.modificationDate] as? Date else { continue }
            candidates.append((path, modifiedAt))
        }

        var bestMatch: (path: String, modifiedAt: Date, startDelta: TimeInterval)?
        var closestCwdMatch: (path: String, startDelta: TimeInterval)?
        var parsedMetadataCount = 0
        var cwdMatchCount = 0
        var metadataFailureCounts: [String: Int] = [:]
        var metadataFailureSamples: [String] = []

        for candidate in candidates.sorted(by: { $0.modifiedAt > $1.modifiedAt }) {
            guard let metadata = codexSessionMetadata(at: candidate.path) else {
                let failure = codexSessionMetadataFailureCache[candidate.path] ?? "metadata_unavailable"
                metadataFailureCounts[failure, default: 0] += 1
                if metadataFailureSamples.count < 3 {
                    metadataFailureSamples.append("\(URL(fileURLWithPath: candidate.path).lastPathComponent):\(failure)")
                }
                continue
            }

            parsedMetadataCount += 1

            guard metadata.cwd == agent.workingDirectory else {
                continue
            }

            cwdMatchCount += 1
            let startDelta = abs(metadata.startedAt.timeIntervalSince(agent.startTime))

            if closestCwdMatch == nil || startDelta < closestCwdMatch!.startDelta {
                closestCwdMatch = (candidate.path, startDelta)
            }

            guard startDelta <= Self.codexSessionStartDeltaTolerance else {
                continue
            }

            if bestMatch == nil ||
                startDelta < bestMatch!.startDelta ||
                (startDelta == bestMatch!.startDelta && candidate.modifiedAt > bestMatch!.modifiedAt) {
                bestMatch = (candidate.path, candidate.modifiedAt, startDelta)
            }
        }

        let failureSummary = Self.formatCountSummary(metadataFailureCounts)
        if let bestMatch {
            return (
                bestMatch.path,
                "lookup=best_match session=\(URL(fileURLWithPath: bestMatch.path).lastPathComponent) delta=\(Int(bestMatch.startDelta))s candidates=\(candidates.count) parsed=\(parsedMetadataCount) cwd_matches=\(cwdMatchCount)"
            )
        }

        if let closestCwdMatch {
            return (
                nil,
                "lookup=best_match_too_old closest_session=\(URL(fileURLWithPath: closestCwdMatch.path).lastPathComponent) delta=\(Int(closestCwdMatch.startDelta))s limit=\(Int(Self.codexSessionStartDeltaTolerance))s cwd=\(agent.workingDirectory) candidates=\(candidates.count) parsed=\(parsedMetadataCount) cwd_matches=\(cwdMatchCount)"
            )
        }

        let sampleSummary = metadataFailureSamples.isEmpty ? "-" : metadataFailureSamples.joined(separator: ",")
        return (
            nil,
            "lookup=best_match_miss cwd=\(agent.workingDirectory) candidates=\(candidates.count) parsed=\(parsedMetadataCount) cwd_matches=\(cwdMatchCount) metadata_failures=\(failureSummary) samples=\(sampleSummary)"
        )
    }

    private func validateCodexSessionPath(
        _ path: String,
        for agent: DetectedAgent
    ) -> (isValid: Bool, debug: String) {
        let sessionName = URL(fileURLWithPath: path).lastPathComponent

        guard let metadata = codexSessionMetadata(at: path) else {
            let failure = codexSessionMetadataFailureCache[path] ?? "metadata_unavailable"
            return (false, "lookup=cached_invalid session=\(sessionName) reason=\(failure)")
        }

        guard metadata.cwd == agent.workingDirectory else {
            return (
                false,
                "lookup=cached_invalid session=\(sessionName) reason=cwd_mismatch session_cwd=\(metadata.cwd) cwd=\(agent.workingDirectory)"
            )
        }

        let startDelta = abs(metadata.startedAt.timeIntervalSince(agent.startTime))
        guard startDelta <= Self.codexSessionStartDeltaTolerance else {
            return (
                false,
                "lookup=cached_invalid session=\(sessionName) reason=start_delta delta=\(Int(startDelta))s limit=\(Int(Self.codexSessionStartDeltaTolerance))s"
            )
        }

        return (true, "lookup=cached session=\(sessionName) delta=\(Int(startDelta))s")
    }

    private func codexSessionMetadata(at path: String) -> CodexSessionMetadata? {
        if let cached = codexSessionMetadataCache[path] {
            return cached
        }

        guard let firstLine = readFirstLine(of: path) else {
            codexSessionMetadataFailureCache[path] = "first_line_unreadable"
            return nil
        }

        guard let data = firstLine.data(using: .utf8) else {
            codexSessionMetadataFailureCache[path] = "first_line_invalid_utf8"
            return nil
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            codexSessionMetadataFailureCache[path] = "first_line_invalid_json"
            return nil
        }

        guard let type = json["type"] as? String, type == "session_meta" else {
            codexSessionMetadataFailureCache[path] = "missing_session_meta"
            return nil
        }

        guard let payload = json["payload"] as? [String: Any] else {
            codexSessionMetadataFailureCache[path] = "missing_payload"
            return nil
        }

        guard let id = payload["id"] as? String, !id.isEmpty else {
            codexSessionMetadataFailureCache[path] = "missing_id"
            return nil
        }

        guard let cwd = payload["cwd"] as? String, !cwd.isEmpty else {
            codexSessionMetadataFailureCache[path] = "missing_cwd"
            return nil
        }

        guard let timestamp = payload["timestamp"] as? String, !timestamp.isEmpty else {
            codexSessionMetadataFailureCache[path] = "missing_timestamp"
            return nil
        }

        guard let startedAt = Self.codexTimestampFormatter.date(from: timestamp)
            ?? Self.codexTimestampFormatterWithoutFractionalSeconds.date(from: timestamp) else {
            codexSessionMetadataFailureCache[path] = "invalid_timestamp"
            return nil
        }

        let metadata = CodexSessionMetadata(id: id, cwd: cwd, startedAt: startedAt)
        codexSessionMetadataCache[path] = metadata
        codexSessionPathCache[id] = path
        codexSessionMetadataFailureCache.removeValue(forKey: path)
        return metadata
    }

    private func codexStatus(
        fromSessionFile path: String
    ) -> (decision: StatusDecision?, debug: String) {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return (nil, "status=file_unreadable session=\(URL(fileURLWithPath: path).lastPathComponent)")
        }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize > 0 else {
            return (nil, "status=empty_file session=\(URL(fileURLWithPath: path).lastPathComponent)")
        }

        // Codex can append very large response payloads after the last status event.
        // Read a larger tail window so `task_started` / `task_complete` remain visible.
        let readSize: UInt64 = min(fileSize, 1_048_576)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()

        guard let content = String(data: data, encoding: .utf8) else {
            return (nil, "status=tail_invalid_utf8 session=\(URL(fileURLWithPath: path).lastPathComponent) read_size=\(readSize)")
        }

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
                return (
                    StatusDecision(
                        status: .thinking,
                        activity: "Working...",
                        source: "codex_session",
                        details: "event=task_started session=\(URL(fileURLWithPath: path).lastPathComponent) timestamp=\(json["timestamp"] as? String ?? "-")",
                        refreshLastActivity: true
                    ),
                    "status=task_started session=\(URL(fileURLWithPath: path).lastPathComponent)"
                )
            case "task_complete", "turn_aborted":
                return (
                    StatusDecision(
                        status: .idle,
                        activity: "Ready",
                        source: "codex_session",
                        details: "event=\(eventType) session=\(URL(fileURLWithPath: path).lastPathComponent) timestamp=\(json["timestamp"] as? String ?? "-")",
                        refreshLastActivity: false
                    ),
                    "status=\(eventType) session=\(URL(fileURLWithPath: path).lastPathComponent)"
                )
            default:
                continue
            }
        }

        let recentEvents = recentEventTypes.isEmpty ? "-" : recentEventTypes.joined(separator: ",")
        return (
            nil,
            "status=no_task_event session=\(URL(fileURLWithPath: path).lastPathComponent) event_msgs=\(eventMsgCount) recent_events=\(recentEvents) read_size=\(readSize)"
        )
    }

    private func applyStatusDecision(
        _ decision: StatusDecision,
        to agent: DetectedAgent,
        procState: String,
        treeCPU: Double
    ) {
        agent.status = decision.status
        agent.currentActivity = decision.activity
        agent.statusDebugSource = decision.source
        agent.statusDebugDetails = decision.details
        if decision.refreshLastActivity {
            agent.lastActivity = Date()
        }
        if decision.source == "codex_session" {
            codexFallbackLogCache.removeValue(forKey: agent.pid)
        }
        logStatusDecisionIfNeeded(decision, for: agent, procState: procState, treeCPU: treeCPU)
    }

    private func logStatusDecisionIfNeeded(
        _ decision: StatusDecision,
        for agent: DetectedAgent,
        procState: String,
        treeCPU: Double
    ) {
        let fingerprint = [
            "\(decision.status)",
            decision.activity,
            decision.source,
            decision.details,
            procState,
            String(format: "%.1f", treeCPU)
        ].joined(separator: "|")

        guard statusDecisionLogCache[agent.pid] != fingerprint else { return }
        statusDecisionLogCache[agent.pid] = fingerprint

        let logLine = [
            Self.iso8601Timestamp.string(from: Date()),
            "pid=\(agent.pid)",
            "kind=\(agent.kind.binaryName)",
            "dir=\(shellSafeLogValue(agent.directoryDisplayName))",
            "status=\(String(describing: decision.status))",
            "activity=\(shellSafeLogValue(decision.activity))",
            "source=\(decision.source)",
            "proc_state=\(procState.isEmpty ? "-" : procState)",
            String(format: "tree_cpu=%.1f", treeCPU),
            "details=\(shellSafeLogValue(decision.details))"
        ].joined(separator: " ")

        appendStatusLog(logLine + "\n")
    }

    private func appendStatusLog(_ line: String) {
        let data = Data(line.utf8)
        let fileManager = FileManager.default

        if !fileManager.fileExists(atPath: statusLogURL.path) {
            fileManager.createFile(atPath: statusLogURL.path, contents: data)
            return
        }

        guard let handle = try? FileHandle(forWritingTo: statusLogURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            return
        }
    }

    private func logCodexFallbackIfNeeded(for agent: DetectedAgent, reason: String) {
        let fingerprint = [
            agent.workingDirectory,
            agent.codexSessionIDHint ?? "-",
            reason
        ].joined(separator: "|")

        guard codexFallbackLogCache[agent.pid] != fingerprint else { return }
        codexFallbackLogCache[agent.pid] = fingerprint

        let logLine = [
            Self.iso8601Timestamp.string(from: Date()),
            "pid=\(agent.pid)",
            "kind=\(agent.kind.binaryName)",
            "dir=\(shellSafeLogValue(agent.directoryDisplayName))",
            "source=codex_fallback",
            "reason=\(shellSafeLogValue(reason))",
            "session_hint=\(agent.codexSessionIDHint ?? "-")",
            "cached_session=\(shellSafeLogValue(agent.codexSessionPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-"))"
        ].joined(separator: " ")

        appendStatusLog(logLine + "\n")
    }

    private func codexLogContext(for agent: DetectedAgent) -> String {
        guard agent.kind.binaryName == "codex" else { return "" }
        let sessionName = agent.codexSessionPath.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "-"
        let sessionHint = agent.codexSessionIDHint ?? "-"
        return " session_hint=\(sessionHint) session=\(sessionName)"
    }

    private static func formatCountSummary(_ counts: [String: Int]) -> String {
        guard !counts.isEmpty else { return "-" }
        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value {
                    return lhs.key < rhs.key
                }
                return lhs.value > rhs.value
            }
            .prefix(4)
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ",")
    }

    private func shellSafeLogValue(_ value: String) -> String {
        let sanitized = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return "\"\(sanitized)\""
    }

    private static let iso8601Timestamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let codexTimestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let codexTimestampFormatterWithoutFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let codexSessionStartDeltaTolerance: TimeInterval = 300

    private func readFirstLine(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 65536)
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        return content.components(separatedBy: "\n").first
    }

    /// Read the last assistant or user entry from a JSONL file.
    /// Skips system/progress metadata lines that Claude appends after turns.
    private func readLastRelevantEntry(of path: String) -> [String: Any]? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        // Read up to 32KB from the end — enough for several JSONL entries
        let readSize: UInt64 = min(fileSize, 32768)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()

        guard let content = String(data: data, encoding: .utf8) else { return nil }
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

    /// Extract a human-readable command from a full command path
    private static func readableCommand(_ cmd: String) -> String {
        let parts = cmd.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let first = parts.first else { return cmd }
        let binary = URL(fileURLWithPath: String(first)).lastPathComponent
        if parts.count > 1 {
            let args = String(parts[1]).prefix(60)
            return "\(binary) \(args)"
        }
        return binary
    }

    /// Generate a human-readable summary for a pending tool call
    private static func toolSummary(name: String, input: [String: Any]) -> String {
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

    // MARK: - Layer 2: Walk parent chain to find owning .app

    /// Walk the parent process chain to find the PID of the .app bundle that owns this terminal
    private func findOwnerAppPID(pid: Int32) -> pid_t? {
        var current = pid
        var bestMatch: pid_t?

        for _ in 0..<15 {
            if let app = activatableApp(for: current) {
                bestMatch = app.processIdentifier
            }

            let info = shell("ps -p \(current) -o ppid=,args= 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !info.isEmpty else { return bestMatch }
            let parts = info.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return bestMatch }
            guard let ppid = Int32(parts[0].trimmingCharacters(in: .whitespaces)) else { return bestMatch }
            let cmd = String(parts[1])

            // Terminal apps like Warp can insert helper processes (for example
            // terminal-server) between the CLI and the actual focusable app.
            // Prefer a real activatable NSRunningApplication when we hit the
            // bundle boundary, otherwise fall back to the nearest match found
            // higher in the chain.
            if cmd.contains(".app/") || cmd.contains(".app ") {
                if let app = activatableApp(for: current) {
                    return app.processIdentifier
                }
                if let app = activatableApp(for: ppid) {
                    return app.processIdentifier
                }
                return bestMatch
            }
            if ppid <= 1 { return bestMatch }
            current = ppid
        }
        return bestMatch
    }

    // MARK: - Window Activation

    func activateAgent(_ agent: DetectedAgent) {
        let ownerPID = agent.ownerAppPID ?? findOwnerAppPID(pid: agent.pid)
        let folderName = URL(fileURLWithPath: agent.workingDirectory).lastPathComponent

        guard let appPID = ownerPID,
              let app = NSRunningApplication(processIdentifier: appPID) else {
            if let name = findOwnerAppName(pid: agent.pid) {
                shell("open -a \"\(name)\"")
            }
            return
        }

        guard !folderName.isEmpty else {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }

        // Check Accessibility permission — prompt user if not granted
        if !AXIsProcessTrusted() {
            // Activate the app anyway (best we can do without AX)
            app.activate(options: [.activateIgnoringOtherApps])
            // Prompt user to grant Accessibility — opens System Settings
            promptForAccessibility()
            return
        }

        // Use AX to raise the exact window
        raiseWindowViaAX(appPID: appPID, folderName: folderName, app: app)
    }

    /// Prompt the user to grant Accessibility permission using Apple's native dialog.
    /// Only shows the system prompt if not already trusted.
    private func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Raise a specific window using the Accessibility API
    private func raiseWindowViaAX(appPID: pid_t, folderName: String, app: NSRunningApplication) {
        let axApp = AXUIElementCreateApplication(appPID)

        // Set app as frontmost via AX + NSRunningApplication
        AXUIElementSetAttributeValue(axApp, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        app.activate(options: [.activateIgnoringOtherApps])

        let windows = axWindows(for: axApp)
        if let window = windows.first(where: { windowMatches($0, folderName: folderName) }) ?? windows.first {
            raiseAXWindow(window)
        }
    }

    /// Walk parent chain and return the human-readable app name (e.g. "Cursor", "Terminal")
    private func findOwnerAppName(pid: Int32) -> String? {
        var current = pid
        var bestMatch: String?

        for _ in 0..<15 {
            if let app = activatableApp(for: current), let name = app.localizedName {
                bestMatch = name
            }

            let info = shell("ps -p \(current) -o ppid=,args= 2>/dev/null")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !info.isEmpty else { return bestMatch }
            let parts = info.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count >= 2 else { return bestMatch }
            guard let ppid = Int32(parts[0].trimmingCharacters(in: .whitespaces)) else { return bestMatch }
            let cmd = String(parts[1])

            if cmd.contains(".app/") || cmd.contains(".app ") {
                if let app = activatableApp(for: current), let name = app.localizedName {
                    return name
                }
                if let app = activatableApp(for: ppid), let name = app.localizedName {
                    return name
                }
                // Extract "AppName" from "/Applications/AppName.app/..."
                if let range = cmd.range(of: #"[^/]+\.app"#, options: .regularExpression) {
                    return String(cmd[range]).replacingOccurrences(of: ".app", with: "")
                }
                return bestMatch
            }
            if ppid <= 1 { return bestMatch }
            current = ppid
        }
        return bestMatch
    }

    // MARK: - Helpers

    private func activatableApp(for pid: pid_t) -> NSRunningApplication? {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return nil }
        guard app.bundleURL?.pathExtension == "app" else { return nil }
        return app
    }

    private func axWindows(for app: AXUIElement) -> [AXUIElement] {
        var windows: [AXUIElement] = []

        for attribute in [kAXWindowsAttribute, kAXMainWindowAttribute, kAXFocusedWindowAttribute] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(app, attribute as CFString, &value) == .success else { continue }

            if let elements = value as? [AXUIElement] {
                for element in elements where !windows.contains(where: { CFEqual($0, element) }) {
                    windows.append(element)
                }
            } else if CFGetTypeID(value) == AXUIElementGetTypeID() {
                let element = unsafeBitCast(value, to: AXUIElement.self)
                guard !windows.contains(where: { CFEqual($0, element) }) else { continue }
                windows.append(element)
            }
        }

        return windows
    }

    private func windowMatches(_ window: AXUIElement, folderName: String) -> Bool {
        let attributes = [kAXTitleAttribute, kAXDocumentAttribute]
        for attribute in attributes {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, attribute as CFString, &value) == .success,
                  let text = value as? String else { continue }
            if text.localizedCaseInsensitiveContains(folderName) {
                return true
            }
        }
        return false
    }

    private func raiseAXWindow(_ window: AXUIElement) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Sum CPU% for a process and all its descendants
    private func totalTreeCPU(for pid: Int32) -> Double {
        let output = shell("ps -p \(pid) -o %cpu= 2>/dev/null")
        var total = Double(output.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0

        let childPids = shell("pgrep -P \(pid) 2>/dev/null")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !childPids.isEmpty {
            for line in childPids.components(separatedBy: "\n") {
                if let childPid = Int32(line.trimmingCharacters(in: .whitespaces)) {
                    total += totalTreeCPU(for: childPid)
                }
            }
        }
        return total
    }

    private func getWorkingDirectory(for pid: Int32) -> String {
        let output = shell("lsof -p \(pid) -a -d cwd -Fn 2>/dev/null")
        for line in output.components(separatedBy: "\n") {
            if line.hasPrefix("n") {
                return String(line.dropFirst())
            }
        }
        return "~"
    }

    @discardableResult
    private func shell(_ command: String) -> String {
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = Pipe()
        task.launchPath = "/bin/bash"
        task.arguments = ["-c", command]
        do {
            try task.run()
        } catch {
            return ""
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
