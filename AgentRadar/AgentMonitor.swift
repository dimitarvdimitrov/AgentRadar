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
    let cwd: String
    let cmd: String
    let tty: String
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

// MARK: - Detected Agent

class DetectedAgent: ObservableObject, Identifiable {
    let id: String
    let pid: Int32
    let kind: KnownAgent
    let startTime: Date
    var workingDirectory: String
    var commandLine: String
    var tty: String
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

    var uptimeString: String {
        let seconds = Int(Date().timeIntervalSince(startTime))
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
    }

    init(pid: Int32, kind: KnownAgent, workingDirectory: String, commandLine: String, tty: String) {
        self.id = "\(pid)"
        self.pid = pid
        self.kind = kind
        self.startTime = Date()
        self.workingDirectory = workingDirectory
        self.commandLine = commandLine
        self.tty = tty
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
    private let nonGitCacheTTL: TimeInterval = 10

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

                // Get details: tty, stat, args
                let details = shell("ps -p \(pid) -o tty=,stat=,args= 2>/dev/null")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard !details.isEmpty else { continue }

                let parts = details.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
                guard parts.count >= 2 else { continue }

                let tty = String(parts[0])
                // Skip processes not on a real TTY (GUI apps show "??")
                guard tty != "??" else { continue }
                // Skip duplicate agents on the same TTY (child node workers)
                guard !seenTTYs.contains(tty) else { continue }
                seenTTYs.insert(tty)

                let cmd = parts.count >= 3 ? String(parts[2]) : agent.binaryName
                let cwd = getWorkingDirectory(for: pid)
                results.append(
                    DetectedAgentSnapshot(
                        pid: pid,
                        kind: agent,
                        cwd: cwd,
                        cmd: cmd,
                        tty: tty
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

        // Remove dead agents
        agents.removeAll { !foundPIDs.contains($0.pid) }

        // Add new agents
        for item in found {
            if !knownPIDs.contains(item.pid) {
                let agent = DetectedAgent(
                    pid: item.pid,
                    kind: item.kind,
                    workingDirectory: item.cwd,
                    commandLine: item.cmd,
                    tty: item.tty
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
            agent.workingDirectory = item.cwd
            agent.commandLine = item.cmd
            agent.tty = item.tty
            agent.gitBranch = item.gitBranch
            agent.gitRepoRoot = item.gitRepoRoot
        }

        // Update stats for all agents
        for agent in agents {
            updateStats(agent)
        }

        agents.sort {
            if $0.lastActivity != $1.lastActivity {
                return $0.lastActivity > $1.lastActivity
            }
            return $0.pid < $1.pid
        }

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

        if isStopped {
            agent.status = .idle
            agent.currentActivity = "Stopped"
            return
        }
        if !isForeground && !procState.isEmpty {
            agent.status = .idle
            agent.currentActivity = "Backgrounded"
            return
        }

        // For Claude Code: use JSONL transcript for reliable status
        if agent.kind.binaryName == "claude" {
            if let status = claudeStatusFromTranscript(agent) {
                agent.status = status.status
                agent.currentActivity = status.activity
                if status.status == .thinking {
                    agent.lastActivity = Date()
                }
                return
            }
        }

        // Codex also persists structured session logs; use them instead of CPU-only heuristics.
        if agent.kind.binaryName == "codex" {
            if let status = codexStatusFromSession(agent) {
                agent.pendingToolCall = nil
                agent.status = status.status
                agent.currentActivity = status.activity
                if status.status == .thinking || status.status == .running {
                    agent.lastActivity = Date()
                }
                return
            }
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
            agent.status = .thinking
            agent.currentActivity = bestChild
            agent.lastActivity = Date()
        } else {
            // Check CPU of the entire process tree — Node-based CLIs do all work
            // inside their own process without spawning children
            let treeCPU = totalTreeCPU(for: agent.pid)
            if treeCPU > 3.0 {
                agent.status = .thinking
                agent.currentActivity = "Thinking..."
                agent.lastActivity = Date()
            } else {
                agent.status = .idle
                agent.currentActivity = "Ready"
            }
        }
    }

    // MARK: - Claude Code Transcript-Based Status

    /// Read the Claude Code JSONL transcript to determine actual agent status.
    /// The transcript is the source of truth — if it says the agent finished its turn,
    /// the agent IS waiting for user input, regardless of how long ago that was.
    private func claudeStatusFromTranscript(_ agent: DetectedAgent) -> (status: AgentStatus, activity: String)? {
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

        // Check if the agent process tree is actively using CPU
        let treeCPU = totalTreeCPU(for: agent.pid)
        let isActive = treeCPU > 3.0

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
                return (.completed, "Task completed")
            } else if stopReason == "tool_use" {
                // Agent wants to use a tool
                if staleness < 3 || isActive {
                    // File was just updated or agent is actively working
                    agent.pendingToolCall = nil
                    return (.thinking, "Running tool...")
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
                    return (.needsAttention, "Waiting for tool approval")
                }
            } else {
                // stop_reason is null — still streaming or waiting for API
                agent.pendingToolCall = nil
                if staleness < 30 || isActive {
                    return (.thinking, "Thinking...")
                } else {
                    // Stale and no CPU — likely done or stalled
                    return (.completed, "Task completed")
                }
            }

        case "user":
            // User sent a message or tool result — agent is working
            agent.pendingToolCall = nil
            if staleness < 30 || isActive {
                return (.thinking, "Thinking...")
            } else {
                return (.running, "Active")
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

    private func codexStatusFromSession(_ agent: DetectedAgent) -> (status: AgentStatus, activity: String)? {
        let sessionsRoot = NSHomeDirectory() + "/.codex/sessions"
        guard let sessionPath = mostRecentCodexSession(in: sessionsRoot, cwd: agent.workingDirectory) else {
            return nil
        }

        return codexStatus(fromSessionFile: sessionPath)
    }

    private func mostRecentCodexSession(in root: String, cwd: String) -> String? {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root) else { return nil }

        var candidates: [(path: String, modifiedAt: Date)] = []

        for case let relativePath as String in enumerator {
            guard relativePath.hasSuffix(".jsonl") else { continue }
            let path = root + "/" + relativePath
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modifiedAt = attrs[.modificationDate] as? Date else { continue }
            candidates.append((path, modifiedAt))
        }

        for candidate in candidates.sorted(by: { $0.modifiedAt > $1.modifiedAt }).prefix(50) {
            if codexSessionWorkingDirectory(at: candidate.path) == cwd {
                return candidate.path
            }
        }

        return nil
    }

    private func codexSessionWorkingDirectory(at path: String) -> String? {
        guard let firstLine = readFirstLine(of: path),
              let data = firstLine.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String,
              type == "session_meta",
              let payload = json["payload"] as? [String: Any] else {
            return nil
        }

        return payload["cwd"] as? String
    }

    private func codexStatus(fromSessionFile path: String) -> (status: AgentStatus, activity: String)? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        guard fileSize > 0 else { return nil }

        let readSize: UInt64 = min(fileSize, 65536)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()

        guard let content = String(data: data, encoding: .utf8) else { return nil }

        let lines = content
            .components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .reversed()

        for line in lines {
            guard let lineData = line.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = json["type"] as? String,
                  type == "event_msg",
                  let payload = json["payload"] as? [String: Any],
                  let eventType = payload["type"] as? String else {
                continue
            }

            switch eventType {
            case "task_started":
                return (.thinking, "Working...")
            case "task_complete", "turn_aborted":
                return (.idle, "Ready")
            default:
                continue
            }
        }

        return nil
    }

    private func readFirstLine(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 4096)
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
