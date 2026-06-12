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

    var isAwaitingUser: Bool {
        switch self {
        case .needsAttention, .idle, .completed:
            return true
        case .running, .thinking:
            return false
        }
    }
}

fileprivate struct AgentStatusHistory: OptionSet {
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

fileprivate struct AgentProcessIdentity: Hashable {
    let pid: Int32
    let startTime: Date

    var id: String {
        "\(pid)-\(Int64(startTime.timeIntervalSince1970.rounded()))"
    }
}

private struct DetectedAgentSnapshot {
    let processIdentity: AgentProcessIdentity
    let pid: Int32
    let kind: KnownAgent
    let startTime: Date
    let processWorkingDirectory: String
    var workingDirectory: String
    let cmd: String
    let tty: String
    let codexSessionIDHint: String?
    var codexSessionPath: String?
    var gitBranch: String?
    var gitRepoRoot: String?
}

private struct AgentDetailCacheEntry {
    let processWorkingDirectory: String
    let workingDirectory: String
    let codexSessionPath: String?
    let gitBranch: String?
    let gitRepoRoot: String?
}

private struct AgentDetailHydrationTarget {
    let processIdentity: AgentProcessIdentity
    let pid: Int32
    let kind: KnownAgent
    let startTime: Date
    let processWorkingDirectory: String
    let workingDirectory: String
    let codexSessionIDHint: String?
    let codexSessionPath: String?
}

private struct HydrationBackoff {
    let attempts: Int
    let nextAttemptAt: Date
}

private struct AgentDetailHydrationResult {
    let processIdentity: AgentProcessIdentity
    let processWorkingDirectory: String
    let workingDirectory: String
    let codexSessionPath: String?
    let gitBranch: String?
    let gitRepoRoot: String?
}

private struct RecentFileInfo {
    let path: String
    let modifiedAt: Date
    let fileSize: UInt64
}

private struct AgentCommandLineMatchCacheEntry {
    let commandLine: String
    let agentNames: Set<String>
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

private struct CodexSessionLookupContext {
    let startTime: Date
    let processWorkingDirectory: String
    let sessionIDHint: String?
    let cachedSessionPath: String?
}

private struct CodexSessionLookupResult {
    let path: String?
    let metadata: CodexSessionMetadata?
    let startDelta: TimeInterval?
    let debug: String
}

private struct CodexStatusProbe {
    let decision: StatusDecision?
    let debug: String
}

private struct CodexStatusCacheEntry {
    let fileSize: UInt64
    let modifiedAt: Date?
    let probe: CodexStatusProbe
}

private struct ClaudeTranscriptEntryCacheEntry {
    let fileSize: UInt64
    let modifiedAt: Date
    let entry: [String: Any]?
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
    fileprivate let processIdentity: AgentProcessIdentity
    let pid: Int32
    let kind: KnownAgent
    let startTime: Date
    var processWorkingDirectory: String
    @Published var workingDirectory: String
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

    private var statusHistory: AgentStatusHistory = []

    // Badge when the session did work (running/thinking) since the last popover
    // open and has since settled into a state that's waiting on the user.
    var hasChangedStateSinceLastPopoverOpen: Bool {
        statusHistory.hasVisitedActiveState && status.isAwaitingUser
    }

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
        if seconds < 3600 { return "\(seconds / 60)m" }
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

    fileprivate init(
        processIdentity: AgentProcessIdentity,
        pid: Int32,
        kind: KnownAgent,
        startTime: Date,
        processWorkingDirectory: String,
        workingDirectory: String,
        commandLine: String,
        tty: String,
        codexSessionIDHint: String?
    ) {
        self.id = processIdentity.id
        self.processIdentity = processIdentity
        self.pid = pid
        self.kind = kind
        self.startTime = startTime
        self.processWorkingDirectory = processWorkingDirectory
        self.workingDirectory = workingDirectory
        self.commandLine = commandLine
        self.tty = tty
        self.codexSessionIDHint = codexSessionIDHint
        self.status = .running
        self.lastActivity = Date()
    }

    func recordStatusVisit(_ status: AgentStatus) {
        statusHistory.insert(AgentStatusHistory.bit(for: status))
    }

    func resetStatusHistory(to status: AgentStatus) {
        statusHistory = AgentStatusHistory.bit(for: status)
    }
}

// MARK: - Agent Monitor

class AgentMonitor: ObservableObject {
    @Published var agents: [DetectedAgent] = []
    @Published var lastScan: Date = Date()
    @Published private(set) var changedSessionCount: Int = 0
    @Published private(set) var popoverChangedSessionCount: Int = 0
    @Published private(set) var popoverChangedAgentIDs: Set<String> = []

    var onUpdate: (([DetectedAgent]) -> Void)?
    private var timer: Timer?
    private var isScanInFlight = false
    private var scanRequestedWhileRunning = false
    private var isDetailRefreshInFlight = false
    private var detailRefreshRequestedWhileRunning = false
    private var knownProcessIdentities: Set<AgentProcessIdentity> = []
    private var detailCacheByIdentity: [AgentProcessIdentity: AgentDetailCacheEntry] = [:]
    private var hydrationBackoffByIdentity: [AgentProcessIdentity: HydrationBackoff] = [:]
    private let detailRefreshQueue = DispatchQueue(label: "AgentRadar.AgentMonitor.detailRefresh", qos: .utility)
    private var gitRepoCache: [String: GitRepoCacheEntry] = [:]
    private var gitLookupCache: [String: GitLookupCacheEntry] = [:]
    private var codexSessionPathCache: [String: String] = [:]
    private var claudeSessionPathCache: [String: String] = [:]
    private var claudePinnedTranscriptByIdentity: [AgentProcessIdentity: String] = [:]
    private var codexSessionMetadataCache: [String: CodexSessionMetadata] = [:]
    private var codexSessionMetadataFailureCache: [String: String] = [:]
    private var codexStatusCache: [String: CodexStatusCacheEntry] = [:]
    private var claudeTranscriptEntryCache: [String: ClaudeTranscriptEntryCacheEntry] = [:]
    private var commandLineAgentMatchCacheByPID: [Int32: AgentCommandLineMatchCacheEntry] = [:]
    private var statusDecisionLogCache: [AgentProcessIdentity: String] = [:]
    private var codexFallbackLogCache: [AgentProcessIdentity: String] = [:]
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

    func prepareForPopoverOpen() {
        popoverChangedAgentIDs = Set(
            agents
                .filter { $0.hasChangedStateSinceLastPopoverOpen }
                .map(\.id)
        )
        popoverChangedSessionCount = popoverChangedAgentIDs.count

        for agent in agents {
            agent.resetStatusHistory(to: agent.status)
        }

        refreshChangedSessionCount()
        onUpdate?(agents)
    }

    func refreshPopoverDetails() {
        if isDetailRefreshInFlight {
            detailRefreshRequestedWhileRunning = true
            return
        }

        scheduleDetailHydration(for: agents)
    }

    /// Hydrate agents that don't have full details yet (fresh detections, or
    /// agents recreated after a cache loss). Retries with backoff so agents
    /// whose details can never resolve don't burn CPU on every scan.
    private func hydrateUndetailedAgents() {
        guard !isDetailRefreshInFlight else { return }

        let now = Date()
        let pending = agents.filter { agent in
            guard !Self.isFullyHydrated(agent) else { return false }
            guard let backoff = hydrationBackoffByIdentity[agent.processIdentity] else { return true }
            return backoff.nextAttemptAt <= now
        }
        guard !pending.isEmpty else { return }

        for agent in pending {
            let attempts = (hydrationBackoffByIdentity[agent.processIdentity]?.attempts ?? 0) + 1
            hydrationBackoffByIdentity[agent.processIdentity] = HydrationBackoff(
                attempts: attempts,
                nextAttemptAt: now.addingTimeInterval(Self.hydrationRetryDelay(afterAttempts: attempts))
            )
        }

        scheduleDetailHydration(for: pending)
    }

    private func scheduleDetailHydration(for agents: [DetectedAgent]) {
        let targets = agents.map {
            AgentDetailHydrationTarget(
                processIdentity: $0.processIdentity,
                pid: $0.pid,
                kind: $0.kind,
                startTime: $0.startTime,
                processWorkingDirectory: $0.processWorkingDirectory,
                workingDirectory: $0.workingDirectory,
                codexSessionIDHint: $0.codexSessionIDHint,
                codexSessionPath: $0.codexSessionPath
            )
        }

        guard !targets.isEmpty else { return }

        isDetailRefreshInFlight = true
        detailRefreshRequestedWhileRunning = false

        detailRefreshQueue.async { [weak self] in
            guard let self = self else { return }
            let results = targets.map { self.hydrateDetails(for: $0) }

            DispatchQueue.main.async {
                defer {
                    self.isDetailRefreshInFlight = false

                    if self.detailRefreshRequestedWhileRunning {
                        self.refreshPopoverDetails()
                    }
                }

                self.applyHydratedDetails(results)
            }
        }
    }

    private static func isFullyHydrated(_ agent: DetectedAgent) -> Bool {
        guard agent.processWorkingDirectory.hasPrefix("/") else { return false }
        if agent.kind.binaryName == "codex" && agent.codexSessionPath == nil {
            return false
        }
        return true
    }

    private static func hydrationRetryDelay(afterAttempts attempts: Int) -> TimeInterval {
        // Codex writes its rollout file moments after the process starts, so
        // retry on every scan at first, then back off for agents whose
        // details never resolve (e.g. codex sessions with no rollout file).
        guard attempts > 5 else { return 0 }
        return min(60, pow(2.0, Double(attempts - 4)))
    }

    private func scan() {
        if isScanInFlight {
            scanRequestedWhileRunning = true
            return
        }

        isScanInFlight = true
        scanRequestedWhileRunning = false

        let cachedDetailsByIdentity = detailCacheByIdentity
        let existingIdentitiesByPID = Dictionary(
            uniqueKeysWithValues: agents.map { ($0.pid, $0.processIdentity) }
        )
        let commandLineAgentMatchCacheByPID = self.commandLineAgentMatchCacheByPID

        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self = self else { return }
            var updatedCommandLineAgentMatchCacheByPID = commandLineAgentMatchCacheByPID
            let processTable = ProcessInspector.snapshot()
            guard processTable.isValid else {
                DispatchQueue.main.async {
                    self.isScanInFlight = false

                    if self.scanRequestedWhileRunning {
                        self.scan()
                    }
                }
                return
            }

            let found = self.detectAgents(
                cachedDetailsByIdentity: cachedDetailsByIdentity,
                existingIdentitiesByPID: existingIdentitiesByPID,
                processTable: processTable,
                commandLineAgentMatchCacheByPID: &updatedCommandLineAgentMatchCacheByPID
            )

            DispatchQueue.main.async {
                defer {
                    self.isScanInFlight = false

                    if self.scanRequestedWhileRunning {
                        self.scan()
                    }
                }

                self.commandLineAgentMatchCacheByPID = updatedCommandLineAgentMatchCacheByPID
                self.reconcile(found, processTable: processTable)
                self.lastScan = Date()
                self.onUpdate?(self.agents)
            }
        }
    }

    private func hydrateDetails(for target: AgentDetailHydrationTarget) -> AgentDetailHydrationResult {
        let refreshedProcessWorkingDirectory = getWorkingDirectory(for: target.pid)
        let processWorkingDirectory = refreshedProcessWorkingDirectory
            ?? target.processWorkingDirectory
        var workingDirectory = refreshedProcessWorkingDirectory
            ?? target.workingDirectory
        var codexSessionPath = target.codexSessionPath
        var gitBranch: String?
        var gitRepoRoot: String?

        if target.kind.binaryName == "codex" {
            let lookup = codexSessionLookup(
                for: CodexSessionLookupContext(
                    startTime: target.startTime,
                    processWorkingDirectory: processWorkingDirectory,
                    sessionIDHint: target.codexSessionIDHint,
                    cachedSessionPath: target.codexSessionPath
                ),
                in: NSHomeDirectory() + "/.codex/sessions"
            )

            if let sessionPath = lookup.path {
                codexSessionPath = sessionPath
            }
            if let metadata = lookup.metadata {
                workingDirectory = metadata.cwd
            }
        }

        if let gitContext = gitContext(for: workingDirectory) {
            gitBranch = gitContext.branch
            gitRepoRoot = gitContext.repoRoot
        }

        return AgentDetailHydrationResult(
            processIdentity: target.processIdentity,
            processWorkingDirectory: processWorkingDirectory,
            workingDirectory: workingDirectory,
            codexSessionPath: codexSessionPath,
            gitBranch: gitBranch,
            gitRepoRoot: gitRepoRoot
        )
    }

    private func applyHydratedDetails(_ results: [AgentDetailHydrationResult]) {
        let liveIdentities = Set(agents.map { $0.processIdentity })

        for result in results where liveIdentities.contains(result.processIdentity) {
            detailCacheByIdentity[result.processIdentity] = AgentDetailCacheEntry(
                processWorkingDirectory: result.processWorkingDirectory,
                workingDirectory: result.workingDirectory,
                codexSessionPath: result.codexSessionPath,
                gitBranch: result.gitBranch,
                gitRepoRoot: result.gitRepoRoot
            )

            guard let agent = agents.first(where: { $0.processIdentity == result.processIdentity }) else {
                continue
            }

            agent.processWorkingDirectory = result.processWorkingDirectory
            agent.workingDirectory = result.workingDirectory
            agent.codexSessionPath = result.codexSessionPath
            agent.gitBranch = result.gitBranch
            agent.gitRepoRoot = result.gitRepoRoot

            if Self.isFullyHydrated(agent) {
                hydrationBackoffByIdentity.removeValue(forKey: agent.processIdentity)
            }
        }

        agents.sort(by: Self.menuSortsBefore)
        onUpdate?(agents)
    }

    // MARK: - Layer 1: Detect agents via process snapshot

    private func detectAgents(
        cachedDetailsByIdentity: [AgentProcessIdentity: AgentDetailCacheEntry],
        existingIdentitiesByPID: [Int32: AgentProcessIdentity],
        processTable: ProcessTable,
        commandLineAgentMatchCacheByPID: inout [Int32: AgentCommandLineMatchCacheEntry]
    ) -> [DetectedAgentSnapshot] {
        var results: [DetectedAgentSnapshot] = []
        let myPID = ProcessInfo.processInfo.processIdentifier
        let now = Date()
        var seenPIDs = Set<Int32>()
        let allAgentNames = Set(KnownAgent.all.map(\.binaryName))
        let agentNamesNeedingFallback = Set(
            KnownAgent.all
                .filter { processTable.rows(named: $0.binaryName).isEmpty }
                .map(\.binaryName)
        )
        var fallbackRowsByAgent: [String: [ProcessSnapshot]] = [:]

        if !agentNamesNeedingFallback.isEmpty {
            for row in processTable.byPID.values where Self.canHostAgentBinFallback(row: row, agentNames: allAgentNames) {
                let matchingAgentNames = Self.cachedAgentCommandLineMatches(
                    for: row,
                    allAgentNames: allAgentNames,
                    cache: &commandLineAgentMatchCacheByPID
                )

                for agentName in matchingAgentNames where agentNamesNeedingFallback.contains(agentName) {
                    fallbackRowsByAgent[agentName, default: []].append(row)
                }
            }
        }

        let livePIDs = Set(processTable.byPID.keys)
        commandLineAgentMatchCacheByPID = commandLineAgentMatchCacheByPID.filter { pid, entry in
            guard livePIDs.contains(pid), let row = processTable.row(for: pid) else { return false }
            return row.commandLine == entry.commandLine
        }

        for agent in KnownAgent.all {
            // Match pgrep's process-name default first, then use the full
            // command-line fallback only for wrapper processes such as node.
            let exactRows = processTable.rows(named: agent.binaryName)
            let matchedRows = exactRows.isEmpty
                ? fallbackRowsByAgent[agent.binaryName] ?? []
                : exactRows
            let rows = matchedRows.sorted { $0.pid < $1.pid }  // Lowest PID first (parent process)
            guard !rows.isEmpty else { continue }

            // Track TTYs to avoid adding child workers on the same terminal
            var seenTTYs = Set<String>()

            for row in rows {
                let pid = row.pid
                if pid == myPID || seenPIDs.contains(pid) { continue }

                let elapsedTime = Self.elapsedTime(from: row.elapsedTime)
                let tty = row.tty
                // Skip processes not on a real TTY (GUI apps show "??")
                guard tty != "??" else { continue }
                // Skip duplicate agents on the same TTY (child node workers)
                guard !seenTTYs.contains(tty) else { continue }
                seenTTYs.insert(tty)

                let cmd = row.commandLine.isEmpty ? agent.binaryName : row.commandLine
                let detectedStartTime = Self.processStartTime(now: now, elapsedTime: elapsedTime)
                let processIdentity = Self.stableProcessIdentity(
                    pid: pid,
                    detectedStartTime: detectedStartTime,
                    existingIdentity: existingIdentitiesByPID[pid]
                )
                let details = cachedDetailsByIdentity[processIdentity]
                let processWorkingDirectory = details?.processWorkingDirectory ?? "~"
                results.append(
                    DetectedAgentSnapshot(
                        processIdentity: processIdentity,
                        pid: pid,
                        kind: agent,
                        startTime: processIdentity.startTime,
                        processWorkingDirectory: processWorkingDirectory,
                        workingDirectory: details?.workingDirectory ?? processWorkingDirectory,
                        cmd: cmd,
                        tty: tty,
                        codexSessionIDHint: agent.binaryName == "codex"
                            ? Self.codexResumeSessionID(from: cmd)
                            : nil,
                        codexSessionPath: details?.codexSessionPath,
                        gitBranch: details?.gitBranch,
                        gitRepoRoot: details?.gitRepoRoot
                    )
                )
                seenPIDs.insert(pid)
            }
        }
        return results
    }

    // MARK: - Reconcile

    private func reconcile(_ found: [DetectedAgentSnapshot], processTable: ProcessTable) {
        let foundIdentities = Set(found.map { $0.processIdentity })
        let foundByIdentity = Dictionary(uniqueKeysWithValues: found.map { ($0.processIdentity, $0) })
        let deadIdentities = Set(agents.map { $0.processIdentity }).subtracting(foundIdentities)

        // Remove dead agents
        agents.removeAll { !foundIdentities.contains($0.processIdentity) }
        for identity in deadIdentities {
            statusDecisionLogCache.removeValue(forKey: identity)
            codexFallbackLogCache.removeValue(forKey: identity)
            detailCacheByIdentity.removeValue(forKey: identity)
            hydrationBackoffByIdentity.removeValue(forKey: identity)
            claudePinnedTranscriptByIdentity.removeValue(forKey: identity)
        }

        // Add new agents
        for item in found {
            if !knownProcessIdentities.contains(item.processIdentity) {
                let agent = DetectedAgent(
                    processIdentity: item.processIdentity,
                    pid: item.pid,
                    kind: item.kind,
                    startTime: item.startTime,
                    processWorkingDirectory: item.processWorkingDirectory,
                    workingDirectory: item.workingDirectory,
                    commandLine: item.cmd,
                    tty: item.tty,
                    codexSessionIDHint: item.codexSessionIDHint
                )
                agent.gitBranch = item.gitBranch
                agent.gitRepoRoot = item.gitRepoRoot
                agent.codexSessionPath = item.codexSessionPath
                agents.append(agent)
                knownProcessIdentities.insert(item.processIdentity)
            }
        }

        for agent in agents {
            guard let item = foundByIdentity[agent.processIdentity] else { continue }
            let codexSessionHintChanged = agent.codexSessionIDHint != item.codexSessionIDHint
            if codexSessionHintChanged {
                agent.codexSessionPath = nil
                if let cachedDetails = detailCacheByIdentity[agent.processIdentity] {
                    detailCacheByIdentity[agent.processIdentity] = AgentDetailCacheEntry(
                        processWorkingDirectory: cachedDetails.processWorkingDirectory,
                        workingDirectory: cachedDetails.workingDirectory,
                        codexSessionPath: nil,
                        gitBranch: cachedDetails.gitBranch,
                        gitRepoRoot: cachedDetails.gitRepoRoot
                    )
                }
            }
            if !codexSessionHintChanged, let codexSessionPath = item.codexSessionPath {
                agent.codexSessionPath = codexSessionPath
            }
            if item.processWorkingDirectory != "~" || agent.processWorkingDirectory == "~" {
                agent.processWorkingDirectory = item.processWorkingDirectory
            }
            if item.workingDirectory != "~" || agent.workingDirectory == "~" {
                agent.workingDirectory = item.workingDirectory
            }
            agent.commandLine = item.cmd
            agent.tty = item.tty
            agent.codexSessionIDHint = item.codexSessionIDHint
            if item.workingDirectory != "~"
                || item.gitBranch != nil
                || item.gitRepoRoot != nil
                || (agent.gitBranch == nil && agent.gitRepoRoot == nil) {
                agent.gitBranch = item.gitBranch
                agent.gitRepoRoot = item.gitRepoRoot
            }
        }

        for agent in agents {
            updateStats(agent, processTable: processTable)
        }

        agents.sort(by: Self.menuSortsBefore)

        // Clean up dead process identities
        knownProcessIdentities = knownProcessIdentities.intersection(foundIdentities)

        prunePopoverSnapshotToLiveAgents()
        refreshChangedSessionCount()
        hydrateUndetailedAgents()
    }

    // MARK: - Git Context

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
        let task = Process()
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = pipe
        task.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        task.arguments = ["-C", path, "rev-parse", "--show-toplevel", "--absolute-git-dir"]

        do {
            try task.run()
        } catch {
            return nil
        }

        let deadline = Date().addingTimeInterval(1.0)
        while task.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.01)
        }

        if task.isRunning {
            task.terminate()
            return nil
        }

        let output = String(
            data: pipe.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        )?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

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
        let lhsIsActive = lhs.status != .idle && lhs.status != .completed
        let rhsIsActive = rhs.status != .idle && rhs.status != .completed

        if lhsIsActive != rhsIsActive {
            return lhsIsActive
        }

        if lhsIsActive {
            let lhsBranch = normalizedBranchSortKey(for: lhs)
            let rhsBranch = normalizedBranchSortKey(for: rhs)

            if lhsBranch.isEmpty != rhsBranch.isEmpty {
                return !lhsBranch.isEmpty
            }

            let branchComparison = lhsBranch.localizedStandardCompare(rhsBranch)
            if branchComparison != .orderedSame {
                return branchComparison == .orderedAscending
            }

            let directoryComparison = lhs.directoryDisplayName.localizedStandardCompare(rhs.directoryDisplayName)
            if directoryComparison != .orderedSame {
                return directoryComparison == .orderedAscending
            }

            if lhs.startTime != rhs.startTime {
                return lhs.startTime > rhs.startTime
            }

            return lhs.pid < rhs.pid
        }

        if lhs.lastActivity != rhs.lastActivity {
            return lhs.lastActivity > rhs.lastActivity
        }

        if lhs.startTime != rhs.startTime {
            return lhs.startTime > rhs.startTime
        }

        return lhs.pid < rhs.pid
    }

    private static func normalizedBranchSortKey(for agent: DetectedAgent) -> String {
        agent.gitBranch?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""
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

    private static func processStartTime(now: Date, elapsedTime: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (now.timeIntervalSince1970 - elapsedTime).rounded())
    }

    private static func fileSize(from attrs: [FileAttributeKey: Any]) -> UInt64? {
        if let size = attrs[.size] as? UInt64 {
            return size
        }
        if let size = attrs[.size] as? NSNumber {
            return size.uint64Value
        }
        if let size = attrs[.size] as? Int {
            return UInt64(size)
        }
        return nil
    }

    private static func stableProcessIdentity(
        pid: Int32,
        detectedStartTime: Date,
        existingIdentity: AgentProcessIdentity?
    ) -> AgentProcessIdentity {
        if let existingIdentity,
           abs(existingIdentity.startTime.timeIntervalSince(detectedStartTime)) <= 2 {
            return existingIdentity
        }

        return AgentProcessIdentity(pid: pid, startTime: detectedStartTime)
    }

    private static func canHostAgentBinFallback(row: ProcessSnapshot, agentNames: Set<String>) -> Bool {
        switch row.processName {
        case "node", "python", "python3", "bun", "deno", "ruby",
             "bash", "zsh", "sh", "env", "npx", "npm", "pnpm", "yarn":
            return true
        default:
            if row.processName.hasPrefix("python") {
                return true
            }
            // Claude Code reports its version string (e.g. "2.1.170") as the
            // process name, so also accept rows launched as an agent binary.
            return agentNames.contains(firstCommandTokenBasename(row.commandLine))
        }
    }

    private static func firstCommandTokenBasename(_ commandLine: String) -> String {
        let token = commandLine.prefix { !$0.isWhitespace }
        if let slashIndex = token.lastIndex(of: "/") {
            return String(token[token.index(after: slashIndex)...])
        }
        return String(token)
    }

    private static func cachedAgentCommandLineMatches(
        for row: ProcessSnapshot,
        allAgentNames: Set<String>,
        cache: inout [Int32: AgentCommandLineMatchCacheEntry]
    ) -> Set<String> {
        if let entry = cache[row.pid],
           entry.commandLine == row.commandLine {
            return entry.agentNames
        }

        let agentNames = agentBinFallbackNames(in: row.commandLine, matching: allAgentNames)
        cache[row.pid] = AgentCommandLineMatchCacheEntry(
            commandLine: row.commandLine,
            agentNames: agentNames
        )
        return agentNames
    }

    private static func agentBinFallbackNames(in commandLine: String, matching agentNames: Set<String>) -> Set<String> {
        let needle = "bin/"
        var names = Set<String>()
        var searchRange = commandLine.startIndex..<commandLine.endIndex

        let firstToken = firstCommandTokenBasename(commandLine)
        if agentNames.contains(firstToken) {
            names.insert(firstToken)
        }

        while let range = commandLine.range(of: needle, range: searchRange) {
            let nameStart = range.upperBound
            var nameEnd = nameStart

            while nameEnd < commandLine.endIndex, !commandLine[nameEnd].isWhitespace {
                nameEnd = commandLine.index(after: nameEnd)
            }

            if nameStart < nameEnd {
                let name = String(commandLine[nameStart..<nameEnd])
                if agentNames.contains(name) {
                    names.insert(name)
                }
            }

            searchRange = nameEnd..<commandLine.endIndex
        }

        return names
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

    private func updateStats(_ agent: DetectedAgent, processTable: ProcessTable) {
        var procState = ""
        if let row = processTable.row(for: agent.pid) {
            agent.cpuPercent = row.cpuPercent
            agent.memoryMB = Double(row.rssKB) / 1024.0
            procState = row.stat
        }

        // Check if process is backgrounded or stopped first
        let isForeground = procState.contains("+")
        let isStopped = procState.contains("T")

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
                procState: procState
            )
            return
        }

        // For Claude Code: use JSONL transcript for reliable status
        if agent.kind.binaryName == "claude" {
            if let decision = claudeStatusFromTranscript(agent, procState: procState) {
                applyStatusDecision(decision, to: agent, procState: procState)
                return
            }
        }

        // Codex also persists structured session logs; use them instead of process heuristics.
        if agent.kind.binaryName == "codex" {
            if let decision = codexStatusFromSession(agent) {
                agent.pendingToolCall = nil
                applyStatusDecision(decision, to: agent, procState: procState)
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
                procState: procState
            )
            return
        }

        // Fallback for other agents: check child processes
        var hasActiveChildren = false
        var bestChild = ""

        for child in processTable.children(of: agent.pid) {
            let stat = child.stat
            let childCmd = child.commandLine

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
                procState: procState
            )
        } else {
            applyStatusDecision(
                StatusDecision(
                    status: .idle,
                    activity: "Ready",
                    source: "child_process",
                    details: "reason=no_active_children\(codexLogContext(for: agent))",
                    refreshLastActivity: false
                ),
                to: agent,
                procState: procState
            )
        }
    }

    // MARK: - Claude Code Transcript-Based Status

    /// Read the Claude Code JSONL transcript to determine actual agent status.
    /// The transcript is the source of truth — if it says the agent finished its turn,
    /// the agent IS waiting for user input, regardless of how long ago that was.
    private func claudeStatusFromTranscript(
        _ agent: DetectedAgent,
        procState: String
    ) -> StatusDecision? {
        // Convert working directory to Claude's project dir format:
        // /Users/foo/bar → -Users-foo-bar
        let projectDirName = agent.workingDirectory.replacingOccurrences(of: "/", with: "-")
        let projectDir = NSHomeDirectory() + "/.claude/projects/" + projectDirName

        // A session resumed with an explicit id (`claude --resume <uuid>`) keeps
        // writing to the project dir where it was originally created, which can
        // differ from the process cwd — resolve the id across all project dirs.
        // Otherwise, match a transcript to this process by creation time.
        let transcript: RecentFileInfo
        if let sessionID = Self.claudeSessionID(fromCommandLine: agent.commandLine),
           let pinned = claudeTranscript(forSessionID: sessionID, preferredProjectDir: projectDir) {
            claudePinnedTranscriptByIdentity[agent.processIdentity] = pinned.path
            transcript = pinned
        } else if let matched = claudeMatchedTranscript(in: projectDir, for: agent) {
            transcript = matched
        } else {
            return nil
        }

        let staleness = Date().timeIntervalSince(transcript.modifiedAt)
        let transcriptName = URL(fileURLWithPath: transcript.path).lastPathComponent

        // Read recent lines and find the last assistant/user entry
        // (skip system/progress metadata lines that Claude appends after turns)
        guard let entry = cachedLastRelevantClaudeEntry(
            of: transcript.path,
            fileSize: transcript.fileSize,
            modifiedAt: transcript.modifiedAt
        ) else {
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
                if staleness < 3 {
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
                if staleness < 30 {
                    return StatusDecision(
                        status: .thinking,
                        activity: "Thinking...",
                        source: "claude_transcript",
                        details: "entry=assistant stop_reason=nil transcript=\(transcriptName) staleness=\(Int(staleness))s",
                        refreshLastActivity: true
                    )
                } else {
                    // Stale — likely done or stalled
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
            if staleness < 30 {
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

    /// Session id explicitly pinned on the claude command line via
    /// `--resume <uuid>`, `-r <uuid>`, or `--session-id <uuid>`.
    /// Returns nil for the bare `--resume` picker form.
    private static func claudeSessionID(fromCommandLine commandLine: String) -> String? {
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

    /// Locate the transcript for a specific session id, checking the cwd-derived
    /// project dir first and then every other project dir. Found paths are cached.
    private func claudeTranscript(forSessionID sessionID: String, preferredProjectDir: String) -> RecentFileInfo? {
        if let cached = claudeSessionPathCache[sessionID], let info = fileInfo(atPath: cached) {
            return info
        }

        let fileName = sessionID + ".jsonl"
        let preferredPath = preferredProjectDir + "/" + fileName
        if let info = fileInfo(atPath: preferredPath) {
            claudeSessionPathCache[sessionID] = preferredPath
            return info
        }

        let projectsRoot = NSHomeDirectory() + "/.claude/projects"
        guard let projectDirs = try? FileManager.default.contentsOfDirectory(atPath: projectsRoot) else {
            return nil
        }
        for dir in projectDirs {
            let path = projectsRoot + "/" + dir + "/" + fileName
            if let info = fileInfo(atPath: path) {
                claudeSessionPathCache[sessionID] = path
                return info
            }
        }
        return nil
    }

    /// Covers etime rounding when comparing a transcript's creation time
    /// against the process start time derived from it.
    private static let claudeTranscriptCreationSlack: TimeInterval = 120

    /// Pick the transcript belonging to this process when no session id is
    /// pinned on the command line. A transcript created while this process was
    /// running belongs to the newest claude process (same cwd) that was already
    /// running at creation time — this covers fresh sessions and /clear, which
    /// starts a new transcript file mid-process. Transcripts that predate every
    /// live claude process in the dir are resume targets: a bare `--resume`
    /// session appends to one of those, so fall back to the newest of them.
    private func claudeMatchedTranscript(in projectDir: String, for agent: DetectedAgent) -> RecentFileInfo? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(atPath: projectDir) else { return nil }

        let pinnedByOthers = Set(
            claudePinnedTranscriptByIdentity
                .filter { $0.key != agent.processIdentity }
                .map(\.value)
        )
        let peerStartTimes = agents
            .filter {
                $0.kind.binaryName == "claude"
                    && $0.processIdentity != agent.processIdentity
                    && $0.workingDirectory == agent.workingDirectory
            }
            .map(\.startTime)

        var bestOwned: RecentFileInfo?
        var bestResumable: RecentFileInfo?

        for file in files where file.hasSuffix(".jsonl") {
            let path = projectDir + "/" + file
            guard !pinnedByOthers.contains(path),
                  let attrs = try? fm.attributesOfItem(atPath: path),
                  let modifiedAt = attrs[.modificationDate] as? Date,
                  let fileSize = Self.fileSize(from: attrs) else {
                continue
            }
            let createdAt = (attrs[.creationDate] as? Date) ?? modifiedAt
            let creationCutoff = createdAt.addingTimeInterval(Self.claudeTranscriptCreationSlack)
            let info = RecentFileInfo(path: path, modifiedAt: modifiedAt, fileSize: fileSize)

            if agent.startTime <= creationCutoff {
                // Created during this process's lifetime — ours unless a peer
                // that started later was also running at creation time.
                let newerPeerOwnsIt = peerStartTimes.contains {
                    $0 > agent.startTime && $0 <= creationCutoff
                }
                if !newerPeerOwnsIt, bestOwned == nil || modifiedAt > bestOwned!.modifiedAt {
                    bestOwned = info
                }
            } else if !peerStartTimes.contains(where: { $0 <= creationCutoff }) {
                if bestResumable == nil || modifiedAt > bestResumable!.modifiedAt {
                    bestResumable = info
                }
            }
        }

        return bestOwned ?? bestResumable
    }

    private func fileInfo(atPath path: String) -> RecentFileInfo? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let modifiedAt = attrs[.modificationDate] as? Date,
              let fileSize = Self.fileSize(from: attrs) else {
            return nil
        }
        return RecentFileInfo(path: path, modifiedAt: modifiedAt, fileSize: fileSize)
    }

    // MARK: - Codex Session-Based Status

    private func codexStatusFromSession(_ agent: DetectedAgent) -> StatusDecision? {
        guard let sessionPath = agent.codexSessionPath,
              FileManager.default.fileExists(atPath: sessionPath) else {
            logCodexFallbackIfNeeded(for: agent, reason: "status=no_cached_session")
            return nil
        }

        let statusProbe = cachedCodexStatus(fromSessionFile: sessionPath)
        guard let decision = statusProbe.decision else {
            logCodexFallbackIfNeeded(for: agent, reason: statusProbe.debug)
            return nil
        }

        codexFallbackLogCache.removeValue(forKey: agent.processIdentity)
        return decision
    }

    private func cachedCodexStatus(fromSessionFile path: String) -> CodexStatusProbe {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let fileSize = Self.fileSize(from: attrs) else {
            let probe = CodexStatusProbe(
                decision: nil,
                debug: "status=file_unreadable session=\(URL(fileURLWithPath: path).lastPathComponent)"
            )
            codexStatusCache.removeValue(forKey: path)
            return probe
        }

        let modifiedAt = attrs[.modificationDate] as? Date
        if let cached = codexStatusCache[path],
           cached.fileSize == fileSize,
           cached.modifiedAt == modifiedAt {
            return cached.probe
        }

        let probe = codexStatus(fromSessionFile: path, fileSize: fileSize)
        codexStatusCache[path] = CodexStatusCacheEntry(
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            probe: probe
        )
        return probe
    }

    private func codexSessionLookup(
        for context: CodexSessionLookupContext,
        in root: String
    ) -> CodexSessionLookupResult {
        let fm = FileManager.default

        if let path = context.cachedSessionPath, fm.fileExists(atPath: path) {
            let validation = validateCodexSessionPath(path, for: context)
            if validation.isValid {
                if let refreshed = refreshedCodexSessionLookupIfNeeded(
                    currentPath: path,
                    currentDelta: validation.startDelta,
                    for: context,
                    in: root
                ) {
                    return refreshed
                }
                return CodexSessionLookupResult(
                    path: path,
                    metadata: validation.metadata,
                    startDelta: validation.startDelta,
                    debug: validation.debug
                )
            }
        }

        if let sessionID = context.sessionIDHint,
           let path = codexSessionPath(forSessionID: sessionID, in: root) {
            return CodexSessionLookupResult(
                path: path,
                metadata: codexSessionMetadata(at: path),
                startDelta: nil,
                debug: "lookup=resume_hint hint=\(sessionID) session=\(URL(fileURLWithPath: path).lastPathComponent)"
            )
        }

        let bestMatch = bestCodexSessionPath(in: root, context: context)
        guard let path = bestMatch.path else {
            if let sessionID = context.sessionIDHint {
                return CodexSessionLookupResult(
                    path: nil,
                    metadata: nil,
                    startDelta: nil,
                    debug: "lookup=resume_hint_miss hint=\(sessionID) \(bestMatch.debug)"
                )
            }
            return bestMatch
        }

        return CodexSessionLookupResult(
            path: path,
            metadata: bestMatch.metadata,
            startDelta: bestMatch.startDelta,
            debug: bestMatch.debug
        )
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
        context: CodexSessionLookupContext
    ) -> CodexSessionLookupResult {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: root) else {
            return CodexSessionLookupResult(
                path: nil,
                metadata: nil,
                startDelta: nil,
                debug: "lookup=best_match root_unreadable root=\(root)"
            )
        }

        var candidates: [(path: String, modifiedAt: Date)] = []

        for case let relativePath as String in enumerator {
            guard relativePath.hasSuffix(".jsonl") else { continue }
            let path = root + "/" + relativePath
            guard let attrs = try? fm.attributesOfItem(atPath: path),
                  let modifiedAt = attrs[.modificationDate] as? Date else { continue }
            candidates.append((path, modifiedAt))
        }

        var bestStartMatch: (path: String, metadata: CodexSessionMetadata, modifiedAt: Date, startDelta: TimeInterval)?
        var secondBestStartMatch: (path: String, startDelta: TimeInterval)?
        var closestProcessCwdMatch: (path: String, startDelta: TimeInterval)?
        var parsedMetadataCount = 0
        var processCwdMatchCount = 0
        var startMatchCount = 0
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

            if metadata.cwd == context.processWorkingDirectory {
                processCwdMatchCount += 1
            }

            let startDelta = abs(metadata.startedAt.timeIntervalSince(context.startTime))

            if metadata.cwd == context.processWorkingDirectory,
               (closestProcessCwdMatch == nil || startDelta < closestProcessCwdMatch!.startDelta) {
                closestProcessCwdMatch = (candidate.path, startDelta)
            }

            guard startDelta <= Self.codexSessionStartDeltaTolerance else {
                continue
            }

            startMatchCount += 1

            let candidateMatchesProcessCwd = metadata.cwd == context.processWorkingDirectory
            let currentBestMatchesProcessCwd = bestStartMatch?.metadata.cwd == context.processWorkingDirectory

            if bestStartMatch == nil ||
                startDelta < bestStartMatch!.startDelta ||
                (
                    abs(startDelta - bestStartMatch!.startDelta) < 1 &&
                    candidateMatchesProcessCwd &&
                    !currentBestMatchesProcessCwd
                ) ||
                (
                    abs(startDelta - bestStartMatch!.startDelta) < 1 &&
                    candidateMatchesProcessCwd == currentBestMatchesProcessCwd &&
                    candidate.modifiedAt > bestStartMatch!.modifiedAt
                ) {
                if let currentBest = bestStartMatch {
                    secondBestStartMatch = (currentBest.path, currentBest.startDelta)
                }
                bestStartMatch = (candidate.path, metadata, candidate.modifiedAt, startDelta)
            } else if secondBestStartMatch == nil || startDelta < secondBestStartMatch!.startDelta {
                secondBestStartMatch = (candidate.path, startDelta)
            }
        }

        let failureSummary = Self.formatCountSummary(metadataFailureCounts)
        if let bestStartMatch {
            let secondDelta = secondBestStartMatch.map { Int($0.startDelta) } ?? -1
            let mode = bestStartMatch.metadata.cwd == context.processWorkingDirectory
                ? "start_time+process_cwd_tiebreak"
                : "start_only"
            return CodexSessionLookupResult(
                path: bestStartMatch.path,
                metadata: bestStartMatch.metadata,
                startDelta: bestStartMatch.startDelta,
                debug: "lookup=best_match mode=\(mode) session=\(URL(fileURLWithPath: bestStartMatch.path).lastPathComponent) delta=\(Int(bestStartMatch.startDelta))s second_delta=\(secondDelta) candidates=\(candidates.count) parsed=\(parsedMetadataCount) start_matches=\(startMatchCount) process_cwd=\(context.processWorkingDirectory) process_cwd_matches=\(processCwdMatchCount)"
            )
        }

        if let closestProcessCwdMatch {
            return CodexSessionLookupResult(
                path: nil,
                metadata: nil,
                startDelta: nil,
                debug: "lookup=best_match_too_old closest_session=\(URL(fileURLWithPath: closestProcessCwdMatch.path).lastPathComponent) delta=\(Int(closestProcessCwdMatch.startDelta))s limit=\(Int(Self.codexSessionStartDeltaTolerance))s process_cwd=\(context.processWorkingDirectory) candidates=\(candidates.count) parsed=\(parsedMetadataCount) process_cwd_matches=\(processCwdMatchCount)"
            )
        }

        let sampleSummary = metadataFailureSamples.isEmpty ? "-" : metadataFailureSamples.joined(separator: ",")
        return CodexSessionLookupResult(
            path: nil,
            metadata: nil,
            startDelta: nil,
            debug: "lookup=best_match_miss process_cwd=\(context.processWorkingDirectory) candidates=\(candidates.count) parsed=\(parsedMetadataCount) start_matches=\(startMatchCount) process_cwd_matches=\(processCwdMatchCount) metadata_failures=\(failureSummary) samples=\(sampleSummary)"
        )
    }

    private func validateCodexSessionPath(
        _ path: String,
        for context: CodexSessionLookupContext
    ) -> (isValid: Bool, metadata: CodexSessionMetadata?, startDelta: TimeInterval, debug: String) {
        let sessionName = URL(fileURLWithPath: path).lastPathComponent

        guard let metadata = codexSessionMetadata(at: path) else {
            let failure = codexSessionMetadataFailureCache[path] ?? "metadata_unavailable"
            return (false, nil, .infinity, "lookup=cached_invalid session=\(sessionName) reason=\(failure)")
        }

        let startDelta = abs(metadata.startedAt.timeIntervalSince(context.startTime))
        guard startDelta <= Self.codexSessionStartDeltaTolerance else {
            return (
                false,
                metadata,
                startDelta,
                "lookup=cached_invalid session=\(sessionName) reason=start_delta delta=\(Int(startDelta))s limit=\(Int(Self.codexSessionStartDeltaTolerance))s"
            )
        }

        return (true, metadata, startDelta, "lookup=cached session=\(sessionName) delta=\(Int(startDelta))s")
    }

    private func refreshedCodexSessionLookupIfNeeded(
        currentPath: String,
        currentDelta: TimeInterval,
        for context: CodexSessionLookupContext,
        in root: String
    ) -> CodexSessionLookupResult? {
        // Session files can appear a moment after the Codex process starts.
        // If we cached a loose match first, re-run matching until we find
        // a tighter start-time match for this process.
        guard currentDelta > Self.codexSessionPinnedStartDeltaTolerance else { return nil }

        let bestMatch = bestCodexSessionPath(in: root, context: context)
        guard let bestPath = bestMatch.path,
              let bestDelta = bestMatch.startDelta,
              bestPath != currentPath,
              bestDelta + 1 < currentDelta else {
            return nil
        }

        let previousSession = URL(fileURLWithPath: currentPath).lastPathComponent
        return CodexSessionLookupResult(
            path: bestPath,
            metadata: bestMatch.metadata,
            startDelta: bestDelta,
            debug: "lookup=cached_replaced previous_session=\(previousSession) previous_delta=\(Int(currentDelta))s \(bestMatch.debug)"
        )
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
        fromSessionFile path: String,
        fileSize knownFileSize: UInt64? = nil
    ) -> CodexStatusProbe {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return CodexStatusProbe(
                decision: nil,
                debug: "status=file_unreadable session=\(URL(fileURLWithPath: path).lastPathComponent)"
            )
        }
        defer { handle.closeFile() }

        let fileSize = knownFileSize ?? handle.seekToEndOfFile()
        guard fileSize > 0 else {
            return CodexStatusProbe(
                decision: nil,
                debug: "status=empty_file session=\(URL(fileURLWithPath: path).lastPathComponent)"
            )
        }

        // Codex can append very large response payloads after the last status event.
        // Read a larger tail window so `task_started` / `task_complete` remain visible.
        let readSize: UInt64 = min(fileSize, 1_048_576)
        handle.seek(toFileOffset: fileSize - readSize)
        let data = handle.readDataToEndOfFile()

        guard let content = String(data: data, encoding: .utf8) else {
            return CodexStatusProbe(
                decision: nil,
                debug: "status=tail_invalid_utf8 session=\(URL(fileURLWithPath: path).lastPathComponent) read_size=\(readSize)"
            )
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
                return CodexStatusProbe(
                    decision: StatusDecision(
                        status: .thinking,
                        activity: "Working...",
                        source: "codex_session",
                        details: "event=task_started session=\(URL(fileURLWithPath: path).lastPathComponent) timestamp=\(json["timestamp"] as? String ?? "-")",
                        refreshLastActivity: true
                    ),
                    debug: "status=task_started session=\(URL(fileURLWithPath: path).lastPathComponent)"
                )
            case "task_complete", "turn_aborted":
                return CodexStatusProbe(
                    decision: StatusDecision(
                        status: .idle,
                        activity: "Ready",
                        source: "codex_session",
                        details: "event=\(eventType) session=\(URL(fileURLWithPath: path).lastPathComponent) timestamp=\(json["timestamp"] as? String ?? "-")",
                        refreshLastActivity: false
                    ),
                    debug: "status=\(eventType) session=\(URL(fileURLWithPath: path).lastPathComponent)"
                )
            default:
                continue
            }
        }

        let recentEvents = recentEventTypes.isEmpty ? "-" : recentEventTypes.joined(separator: ",")
        return CodexStatusProbe(
            decision: nil,
            debug: "status=no_task_event session=\(URL(fileURLWithPath: path).lastPathComponent) event_msgs=\(eventMsgCount) recent_events=\(recentEvents) read_size=\(readSize)"
        )
    }

    private func applyStatusDecision(
        _ decision: StatusDecision,
        to agent: DetectedAgent,
        procState: String
    ) {
        agent.status = decision.status
        agent.recordStatusVisit(decision.status)
        agent.currentActivity = decision.activity
        agent.statusDebugSource = decision.source
        agent.statusDebugDetails = decision.details
        if decision.refreshLastActivity {
            agent.lastActivity = Date()
        }
        if decision.source == "codex_session" {
            codexFallbackLogCache.removeValue(forKey: agent.processIdentity)
        }
        logStatusDecisionIfNeeded(decision, for: agent, procState: procState)
    }

    private func refreshChangedSessionCount() {
        changedSessionCount = agents.filter(\.hasChangedStateSinceLastPopoverOpen).count
    }

    private func prunePopoverSnapshotToLiveAgents() {
        guard !popoverChangedAgentIDs.isEmpty else {
            popoverChangedSessionCount = 0
            return
        }

        let liveAgentIDs = Set(agents.map(\.id))
        popoverChangedAgentIDs = popoverChangedAgentIDs.intersection(liveAgentIDs)
        popoverChangedSessionCount = popoverChangedAgentIDs.count
    }

    private func logStatusDecisionIfNeeded(
        _ decision: StatusDecision,
        for agent: DetectedAgent,
        procState: String
    ) {
        let fingerprint = [
            "\(decision.status)",
            decision.activity,
            decision.source,
            decision.details,
            procState
        ].joined(separator: "|")

        guard statusDecisionLogCache[agent.processIdentity] != fingerprint else { return }
        statusDecisionLogCache[agent.processIdentity] = fingerprint

        let logLine = [
            Self.iso8601Timestamp.string(from: Date()),
            "pid=\(agent.pid)",
            "kind=\(agent.kind.binaryName)",
            "dir=\(shellSafeLogValue(agent.directoryDisplayName))",
            "status=\(String(describing: decision.status))",
            "activity=\(shellSafeLogValue(decision.activity))",
            "source=\(decision.source)",
            "proc_state=\(procState.isEmpty ? "-" : procState)",
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
            agent.processWorkingDirectory,
            agent.codexSessionIDHint ?? "-",
            reason
        ].joined(separator: "|")

        guard codexFallbackLogCache[agent.processIdentity] != fingerprint else { return }
        codexFallbackLogCache[agent.processIdentity] = fingerprint

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

    private static let codexSessionPinnedStartDeltaTolerance: TimeInterval = 10
    private static let codexSessionStartDeltaTolerance: TimeInterval = 300

    private func readFirstLine(of path: String) -> String? {
        guard let handle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { handle.closeFile() }

        let data = handle.readData(ofLength: 65536)
        guard let content = String(data: data, encoding: .utf8) else { return nil }
        return content.components(separatedBy: "\n").first
    }

    private func cachedLastRelevantClaudeEntry(
        of path: String,
        fileSize: UInt64,
        modifiedAt: Date
    ) -> [String: Any]? {
        if let cached = claudeTranscriptEntryCache[path],
           cached.fileSize == fileSize,
           cached.modifiedAt == modifiedAt {
            return cached.entry
        }

        let entry = readLastRelevantEntry(of: path)
        claudeTranscriptEntryCache[path] = ClaudeTranscriptEntryCacheEntry(
            fileSize: fileSize,
            modifiedAt: modifiedAt,
            entry: entry
        )
        return entry
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
        let folderName = URL(fileURLWithPath: agent.processWorkingDirectory).lastPathComponent

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

    private func getWorkingDirectory(for pid: Int32) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }

        let path = withUnsafePointer(to: info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
        return path.hasPrefix("/") ? path : nil
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
