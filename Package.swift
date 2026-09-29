// swift-tools-version:5.9
// SwiftPM manifest for AgentRadar's testable Core and AppKit popover lifecycle.
// The app target in AgentRadar.xcodeproj compiles the same sources directly.
import PackageDescription

let package = Package(
    name: "AgentRadarCore",
    platforms: [.macOS(.v13)],
    targets: [
        .target(
            name: "AgentRadarCore",
            path: "AgentRadar/Core"
        ),
        .target(
            name: "AgentRadarPopoverLifecycle",
            path: "AgentRadar/AppLifecycle"
        ),
        .testTarget(
            name: "AgentRadarCoreTests",
            dependencies: ["AgentRadarCore"],
            path: "Tests/AgentRadarCoreTests"
        ),
        .testTarget(
            name: "AgentRadarPopoverLifecycleTests",
            dependencies: ["AgentRadarPopoverLifecycle"],
            path: "Tests/AgentRadarPopoverLifecycleTests"
        ),
    ]
)
