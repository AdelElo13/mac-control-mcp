import Testing
import Foundation
@testable import MacControlMCP

@Suite("Subprocess — deadlock + timeout safety")
struct SubprocessTests {

    @Test("captures output larger than the pipe buffer without deadlocking")
    func largeOutputNoDeadlock() throws {
        // ~512 KB, far past the ~64 KB pipe buffer that used to wedge the
        // read-after-wait pattern. If the drain regressed this would hang
        // (and the test would time out) rather than fail cleanly.
        let bytes = 512 * 1024
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mcp-subproc-\(UUID().uuidString).txt")
        try Data(repeating: UInt8(ascii: "x"), count: bytes).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let r = Subprocess.run(executable: "/bin/cat", arguments: [tmp.path], timeout: 10)
        #expect(r.ok)
        #expect(r.timedOut == false)
        #expect(r.stdout.utf8.count == bytes)
    }

    @Test("terminates a hung child at the timeout instead of blocking forever")
    func hungChildIsKilled() {
        let start = Date()
        // `sleep 30` writes nothing and never exits within the window.
        let r = Subprocess.run(executable: "/bin/sleep", arguments: ["30"], timeout: 1)
        let elapsed = Date().timeIntervalSince(start)
        #expect(r.timedOut)
        #expect(r.ok == false)
        // Should return shortly after the 1s deadline, well under sleep's 30s.
        #expect(elapsed < 8)
    }

    @Test("a normal command returns stdout and a clean exit")
    func happyPath() {
        let r = Subprocess.run(executable: "/bin/echo", arguments: ["hello"], timeout: 5)
        #expect(r.ok)
        #expect(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
    }
}
