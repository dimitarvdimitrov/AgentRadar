import XCTest
@testable import AgentRadarCore

final class ProcessInspectionTests: XCTestCase {
    // Real `ps axww -o pid=,ppid=,pcpu=,rss=,stat=,etime=,tty=,ucomm=UU…,command=`
    // output shape, including the fixed-width ucomm column and a command line
    // with spaces.
    func testParsePSOutput() {
        let output = """
          4762     1  12.4 238832 R    05:12:44 ??       AgentRadar           /Applications/AgentRadar.app/Contents/MacOS/AgentRadar
         47712 47613   0.0 512000 S+   26:41 ttys011  claude               claude --continue
         33936 33800   1.2  81920 S+   1-02:03:04 ttys004  node                 node /Users/x/.nvm/versions/node/v22.14.0/bin/claude
        """

        let table = ProcessInspector.parsePSOutput(output)

        XCTAssertEqual(table.byPID.count, 3)

        let radar = table.row(for: 4762)
        XCTAssertEqual(radar?.processName, "AgentRadar")
        XCTAssertEqual(radar?.tty, "??")
        XCTAssertEqual(radar?.cpuPercent, 12.4)

        let claude = table.row(for: 47712)
        XCTAssertEqual(claude?.processName, "claude")
        XCTAssertEqual(claude?.tty, "ttys011")
        XCTAssertEqual(claude?.stat, "S+")
        XCTAssertEqual(claude?.commandLine, "claude --continue")
        XCTAssertEqual(claude?.ppid, 47613)

        let node = table.row(for: 33936)
        XCTAssertEqual(node?.processName, "node")
        XCTAssertEqual(node?.elapsedTime, "1-02:03:04")
        XCTAssertEqual(
            node?.commandLine,
            "node /Users/x/.nvm/versions/node/v22.14.0/bin/claude"
        )
    }

    func testParsePSOutputSkipsMalformedLines() {
        let output = """
        garbage line that is not a process row
         47712 47613   0.0 512000 S+   26:41 ttys011  claude               claude
        """

        let table = ProcessInspector.parsePSOutput(output)
        XCTAssertEqual(table.byPID.count, 1)
    }

    func testChildrenAndDescendants() {
        let output = """
             1     0   0.0   1000 S    10:00 ??       launchd              /sbin/launchd
           100     1   0.0   1000 S+   09:00 ttys001  zsh                  -zsh
           200   100   0.0   1000 S+   08:00 ttys001  claude               claude
           300   200   0.0   1000 R+   07:00 ttys001  bash                 bash -c ls
        """

        let table = ProcessInspector.parsePSOutput(output)

        XCTAssertEqual(table.children(of: 100).map(\.pid), [200])
        XCTAssertEqual(Set(table.descendants(of: 100).map(\.pid)), [200, 300])
    }
}
