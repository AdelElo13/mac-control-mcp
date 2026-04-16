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
            name: "MacControlMCP"
        )
    ]
)
