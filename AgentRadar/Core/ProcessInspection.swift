import Foundation

struct ProcessSnapshot {
    let pid: Int32
    let ppid: Int32
    let processName: String
    let cpuPercent: Double
    let rssKB: Int
    let stat: String
    let elapsedTime: String
    let tty: String
    let commandLine: String
}

struct ProcessTable {
    let byPID: [Int32: ProcessSnapshot]
    let byProcessName: [String: [ProcessSnapshot]]
    let childrenByPPID: [Int32: [ProcessSnapshot]]
    let isValid: Bool

    init(snapshots: [ProcessSnapshot], isValid: Bool = true) {
        self.byPID = Dictionary(uniqueKeysWithValues: snapshots.map { ($0.pid, $0) })
        self.byProcessName = Dictionary(grouping: snapshots, by: \.processName)
        self.childrenByPPID = Dictionary(grouping: snapshots, by: \.ppid)
        self.isValid = isValid
    }

    func row(for pid: Int32) -> ProcessSnapshot? {
        byPID[pid]
    }

    func children(of pid: Int32) -> [ProcessSnapshot] {
        childrenByPPID[pid] ?? []
    }

    func rows(named processName: String) -> [ProcessSnapshot] {
        byProcessName[processName] ?? []
    }

    func descendants(of pid: Int32) -> [ProcessSnapshot] {
        var descendants: [ProcessSnapshot] = []
        var stack = Array(children(of: pid).reversed())
        var visited = Set<Int32>()
        visited.insert(pid)

        while let process = stack.popLast() {
            guard !visited.contains(process.pid) else { continue }
            visited.insert(process.pid)
            descendants.append(process)

            for child in children(of: process.pid).reversed() {
                stack.append(child)
            }
        }

        return descendants
    }

}

enum ProcessInspector {
    private static let processNameColumnWidth = 20

    static func snapshot() -> ProcessTable {
        let task = Process()
        let outputPipe = Pipe()
        let processNameHeader = String(repeating: "U", count: processNameColumnWidth)

        task.executableURL = URL(fileURLWithPath: "/bin/ps")
        task.arguments = [
            "axww",
            "-o",
            "pid=,ppid=,pcpu=,rss=,stat=,etime=,tty=,ucomm=\(processNameHeader),command="
        ]
        task.standardOutput = outputPipe
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            return ProcessTable(snapshots: [], isValid: false)
        }

        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        guard task.terminationStatus == 0 else {
            return ProcessTable(snapshots: [], isValid: false)
        }

        let output = String(decoding: data, as: UTF8.self)
        let table = parsePSOutput(output)
        guard table.row(for: ProcessInfo.processInfo.processIdentifier) != nil else {
            return ProcessTable(snapshots: [], isValid: false)
        }
        return table
    }

    static func parsePSOutput(_ output: String) -> ProcessTable {
        let snapshots = output
            .split(whereSeparator: \.isNewline)
            .compactMap(parsePSLine)

        return ProcessTable(snapshots: snapshots)
    }

    private static func parsePSLine(_ line: Substring) -> ProcessSnapshot? {
        var fields: [Substring] = []
        var index = line.startIndex

        while fields.count < 7 {
            while index < line.endIndex, line[index].isWhitespace {
                index = line.index(after: index)
            }

            guard index < line.endIndex else { break }

            let fieldStart = index
            while index < line.endIndex, !line[index].isWhitespace {
                index = line.index(after: index)
            }
            fields.append(line[fieldStart..<index])
        }

        guard fields.count == 7,
              let pid = Int32(fields[0]),
              let ppid = Int32(fields[1]),
              let cpuPercent = Double(fields[2]),
              let rssKB = Int(fields[3]) else {
            return nil
        }

        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }

        guard index < line.endIndex else { return nil }
        let processNameStart = index
        var processNameEnd = index
        var remainingProcessNameColumns = processNameColumnWidth
        while processNameEnd < line.endIndex, remainingProcessNameColumns > 0 {
            processNameEnd = line.index(after: processNameEnd)
            remainingProcessNameColumns -= 1
        }

        let processName = String(line[processNameStart..<processNameEnd])
            .trimmingCharacters(in: .whitespaces)

        index = processNameEnd
        while index < line.endIndex, line[index].isWhitespace {
            index = line.index(after: index)
        }

        let commandLine = index < line.endIndex ? String(line[index...]) : ""

        return ProcessSnapshot(
            pid: pid,
            ppid: ppid,
            processName: processName,
            cpuPercent: cpuPercent,
            rssKB: rssKB,
            stat: String(fields[4]),
            elapsedTime: String(fields[5]),
            tty: String(fields[6]),
            commandLine: commandLine
        )
    }
}
