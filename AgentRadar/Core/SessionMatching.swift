import Foundation

struct AgentCommandLineMatchCacheEntry {
    let commandLine: String
    let agentNames: Set<String>
}

/// A process row that qualifies as an agent session, paired with the agent
/// kind it matched.
struct SessionCandidate {
    let kind: KnownAgent
    let row: ProcessSnapshot
}

/// Pure session-matching rules: given a process table, decide which rows are
/// agent sessions. Only rows on a real TTY can become sessions, so GUI
/// processes that share an agent's binary name (e.g. Claude.app's embedded
/// claude-code helpers) must neither satisfy the exact-name match nor
/// suppress the command-line fallback.
enum SessionMatching {
    static func sessionCandidates(
        in processTable: ProcessTable,
        agents: [KnownAgent] = KnownAgent.all,
        excludingPID myPID: Int32,
        commandLineMatchCache: inout [Int32: AgentCommandLineMatchCacheEntry]
    ) -> [SessionCandidate] {
        var results: [SessionCandidate] = []
        var seenPIDs = Set<Int32>()
        let allAgentNames = Set(agents.map(\.binaryName))

        func sessionEligibleRows(named name: String) -> [ProcessSnapshot] {
            processTable.rows(named: name).filter { $0.tty != "??" }
        }

        let agentNamesNeedingFallback = Set(
            agents
                .filter { sessionEligibleRows(named: $0.binaryName).isEmpty }
                .map(\.binaryName)
        )
        var fallbackRowsByAgent: [String: [ProcessSnapshot]] = [:]

        if !agentNamesNeedingFallback.isEmpty {
            for row in processTable.byPID.values where canHostAgentBinFallback(row: row, agentNames: allAgentNames) {
                let matchingAgentNames = cachedAgentCommandLineMatches(
                    for: row,
                    allAgentNames: allAgentNames,
                    cache: &commandLineMatchCache
                )

                for agentName in matchingAgentNames where agentNamesNeedingFallback.contains(agentName) {
                    fallbackRowsByAgent[agentName, default: []].append(row)
                }
            }
        }

        let livePIDs = Set(processTable.byPID.keys)
        commandLineMatchCache = commandLineMatchCache.filter { pid, entry in
            guard livePIDs.contains(pid), let row = processTable.row(for: pid) else { return false }
            return row.commandLine == entry.commandLine
        }

        for agent in agents {
            // Match pgrep's process-name default first, then use the full
            // command-line fallback only for wrapper processes such as node.
            let exactRows = sessionEligibleRows(named: agent.binaryName)
            let matchedRows = exactRows.isEmpty
                ? fallbackRowsByAgent[agent.binaryName] ?? []
                : exactRows
            let rows = matchedRows.sorted { $0.pid < $1.pid }  // Lowest PID first (parent process)
            guard !rows.isEmpty else { continue }

            // Track TTYs to avoid adding child workers on the same terminal
            var seenTTYs = Set<String>()

            for row in rows {
                if row.pid == myPID || seenPIDs.contains(row.pid) { continue }
                // Skip processes not on a real TTY (GUI apps show "??")
                guard row.tty != "??" else { continue }
                // Skip duplicate agents on the same TTY (child node workers)
                guard !seenTTYs.contains(row.tty) else { continue }
                seenTTYs.insert(row.tty)

                results.append(SessionCandidate(kind: agent, row: row))
                seenPIDs.insert(row.pid)
            }
        }
        return results
    }

    static func canHostAgentBinFallback(row: ProcessSnapshot, agentNames: Set<String>) -> Bool {
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

    static func firstCommandTokenBasename(_ commandLine: String) -> String {
        let token = commandLine.prefix { !$0.isWhitespace }
        if let slashIndex = token.lastIndex(of: "/") {
            return String(token[token.index(after: slashIndex)...])
        }
        return String(token)
    }

    static func cachedAgentCommandLineMatches(
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

    static func agentBinFallbackNames(in commandLine: String, matching agentNames: Set<String>) -> Set<String> {
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

    static func elapsedTime(from value: String) -> TimeInterval {
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

    static func processStartTime(now: Date, elapsedTime: TimeInterval) -> Date {
        Date(timeIntervalSince1970: (now.timeIntervalSince1970 - elapsedTime).rounded())
    }
}
