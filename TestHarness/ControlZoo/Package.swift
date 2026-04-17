// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ControlZoo",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ControlZoo", targets: ["ControlZoo"])
    ],
    targets: [
        .executableTarget(name: "ControlZoo")
    ]
)
