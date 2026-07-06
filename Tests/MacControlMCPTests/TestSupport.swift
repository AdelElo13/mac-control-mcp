import Foundation
import Testing
@testable import MacControlMCP

/// Shared helpers for keeping the test suite from mutating real user state.
enum TestSupport {
    /// Real HID posting (mouse clicks, key presses) is disabled by default
    /// so `swift test` never fires synthetic events into whatever app is
    /// frontmost on the developer's machine. Set `MAC_CONTROL_MCP_TEST_HID=1`
    /// to opt in on a dedicated/CI machine.
    static var hidTestingEnabled: Bool {
        ProcessInfo.processInfo.environment["MAC_CONTROL_MCP_TEST_HID"] == "1"
    }
}

@Suite("Store isolation safety net")
struct StoreLocationTests {
    @Test("test runs never resolve to the real ~/.mac-control-mcp store")
    func redirectsAwayFromRealHome() {
        let base = StoreLocation.baseDirectory.standardizedFileURL.path
        let realHome = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".mac-control-mcp", isDirectory: true)
            .standardizedFileURL.path
        #expect(StoreLocation.isRunningUnderTests)
        #expect(base != realHome,
                "Persisted-store base must be redirected during tests, got \(base)")
    }
}
