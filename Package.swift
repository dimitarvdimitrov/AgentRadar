// swift-tools-version:5.9
// SwiftPM manifest for the testable core of AgentRadar. The app target in
// AgentRadar.xcodeproj compiles the same AgentRadar/Core sources directly;
// this package exists so `swift test` can exercise them without Xcode.
import PackageDescription

let package = Package(
    name: "AgentRadarCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "AgentRadarCore",
            path: "AgentRadar/Core"
        ),
        .testTarget(
            name: "AgentRadarCoreTests",
            dependencies: ["AgentRadarCore"],
            path: "Tests/AgentRadarCoreTests"
        ),
    ]
)
