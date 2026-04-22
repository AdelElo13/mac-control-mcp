// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "mac-control-mcp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "mac-control-mcp",
            targets: ["MacControlMCP"]
        )
    ],
    targets: [
        .executableTarget(
            name: "MacControlMCP",
            // v0.8.0: link EventKit for direct Calendar/Reminders access
            // (replaces slow AppleScript `every event of c whose ...` path
            // in listCalendarEvents which took 15s for a 2-day horizon).
            linkerSettings: [
                .linkedFramework("EventKit")
            ]
        ),
        .testTarget(
            name: "MacControlMCPTests",
            dependencies: ["MacControlMCP"]
        )
    ]
)
