import Foundation

/// Resolves the base directory for all persisted mac-control-mcp state
/// (permission grants, audit log, agent memory, cached artifacts).
///
/// - Production: `~/.mac-control-mcp`.
/// - Overridable via the `MAC_CONTROL_MCP_HOME` environment variable
///   (absolute path) for operators who relocate the store.
/// - Under a test run the base is redirected to a per-process temp
///   directory automatically, so `swift test` can never read or clobber
///   the real user-level store. Detection keys off XCTest, which is linked
///   into the SwiftPM test bundle (it also hosts swift-testing suites on
///   macOS) but is never linked into the shipping server executable.
///
/// All four stores read `baseDirectory` at access time rather than caching
/// it in `init`, so a redirect takes effect even for the `PermissionStore`
/// singleton regardless of when it was first created.
enum StoreLocation {
    static var baseDirectory: URL {
        let env = ProcessInfo.processInfo.environment
        if let override = env["MAC_CONTROL_MCP_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if isRunningUnderTests {
            return testBaseDirectory
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mac-control-mcp", isDirectory: true)
    }

    /// True when executing inside a test host. We detect the runner
    /// *positively* (never "is this NOT the server binary") — a false
    /// positive in production would silently redirect real data to a temp
    /// dir, which is worse than the bug being fixed. Signals, in order:
    ///   - swift-testing under SwiftPM runs from `swiftpm-testing-helper`
    ///     (measured: no XCTest linkage, no XCTest env markers);
    ///   - XCTest-hosted runs use the `xctest` tool / a `*.xctest` bundle
    ///     and set `XCTestConfigurationFilePath`;
    ///   - `MAC_CONTROL_MCP_FORCE_TEST_STORE=1` is a manual escape hatch
    ///     for any runner these heuristics miss.
    /// None of these match the shipped `mac-control-mcp` executable (run
    /// directly or from inside the notarized .app), nor `swift run`.
    static var isRunningUnderTests: Bool {
        let env = ProcessInfo.processInfo.environment
        if env["MAC_CONTROL_MCP_FORCE_TEST_STORE"] == "1" { return true }
        if env["XCTestConfigurationFilePath"] != nil { return true }
        if env["XCTestSessionIdentifier"] != nil { return true }
        if NSClassFromString("XCTestCase") != nil { return true }
        let procName = ProcessInfo.processInfo.processName
        if procName == "xctest" || procName == "swiftpm-testing-helper" { return true }
        let exePath = CommandLine.arguments.first ?? ""
        if exePath.contains(".xctest") || exePath.contains("swiftpm-testing-helper") { return true }
        return false
    }

    private static let testBaseDirectory: URL =
        URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("mac-control-mcp-tests-\(getpid())", isDirectory: true)
}
