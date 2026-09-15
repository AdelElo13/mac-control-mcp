import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#endif
@testable import MacControlMCP

/// v0.8.3 lifecycle regressions (bug 7 + request isolation):
///   - v0.8.2 handled requests one at a time, so a slow tool blocked every
///     other request and the server never noticed stdin EOF → zombies.
///   - processes outlived a dead parent.
@Suite("v0.8.3 server lifecycle", .serialized, .timeLimit(.minutes(1)))
struct ServerLifecycleTests {

    // MARK: - Unit

    @Test("tool timeout honours defaults, per-tool limits, requested durations and the env override")
    func toolTimeoutLimits() {
        #expect(ToolTimeouts.limit(for: "list_windows", arguments: [:], environment: [:]) == 10)
        #expect(ToolTimeouts.limit(for: "record_screen", arguments: ["seconds": .number(120)], environment: [:]) == 135)
        #expect(ToolTimeouts.limit(for: "wait_for_app", arguments: ["timeout_seconds": .number(5)], environment: [:]) == 20)
        let env = [ToolTimeouts.environmentKey: "30"]
        #expect(ToolTimeouts.limit(for: "list_windows", arguments: [:], environment: env) == 30)
        #expect(ToolTimeouts.limit(for: "wait_for_app", arguments: ["timeout_seconds": .number(40)], environment: env) == 55)
        #expect(ToolTimeouts.limit(for: "list_windows", arguments: [:], environment: [ToolTimeouts.environmentKey: "nonsense"]) == 10)
    }

    // MARK: - v0.9 review follow-up (MEDIUM, #8): batch outer/inner timeout race

    @Test("the outer batch timeout always exceeds the summed inner per-call budgets")
    func batchOuterTimeoutExceedsInnerSum() {
        let calls: JSONValue = .array([
            .object(["name": .string("list_apps")]),
            .object(["name": .string("list_windows")]),
            .object(["name": .string("wait_for_app"), "arguments": .object(["timeout_seconds": .number(40)])])
        ])
        let arguments: [String: JSONValue] = ["calls": calls]

        let outer = ToolTimeouts.limit(for: "batch", arguments: arguments, environment: [:])

        let innerSum = (calls.arrayValue ?? []).reduce(TimeInterval(0)) { total, call in
            guard let object = call.objectValue, let name = object["name"]?.stringValue else { return total }
            let subArguments = object["arguments"]?.objectValue ?? [:]
            return total + ToolTimeouts.limit(for: name, arguments: subArguments, environment: [:])
        }

        #expect(innerSum > 0)
        #expect(outer > innerSum, "the outer wrapper must never be tighter than (or equal to) the work it wraps")
        #expect(outer == innerSum + ToolTimeouts.batchHandlerSlack)
    }

    @Test("a batch exactly at the cap boundary (sum == batchCap - slack) is accepted")
    func batchAtCapBoundaryIsAccepted() async {
        // 5 calls at 59s each (via the test-only override) sum to
        // EXACTLY `batchCap - batchHandlerSlack` (300 - 5 = 295 = 5 * 59):
        // the documented boundary is inclusive ("reject ... > batchCap -
        // 5s"), so this must still be accepted.
        let effectiveCap = ToolTimeouts.batchCap - ToolTimeouts.batchHandlerSlack
        let perCall = effectiveCap / 5
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array((0..<5).map { _ in .object(["name": .string("list_apps")]) })

        let result = await registry.callTool(
            name: "batch",
            arguments: [
                "calls": calls,
                "__test_override_call_timeout_seconds": .number(perCall)
            ]
        )
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("batch did not return an object payload")
            return
        }
        #expect(result.isError == false)
        #expect(payload["completed"]?.doubleValue == 5)
    }

    @Test("a batch one second past the cap boundary is rejected up front")
    func batchJustPastCapBoundaryIsRejected() async {
        // Same 5 calls, but 1s over the boundary in total (60s each = 300
        // summed > 295 effective cap) — must now be rejected, proving the
        // reserved slack is actually enforced, not just cosmetic.
        let effectiveCap = ToolTimeouts.batchCap - ToolTimeouts.batchHandlerSlack
        let perCall = (effectiveCap / 5) + 1
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array((0..<5).map { _ in .object(["name": .string("list_apps")]) })

        let result = await registry.callTool(
            name: "batch",
            arguments: [
                "calls": calls,
                "__test_override_call_timeout_seconds": .number(perCall)
            ]
        )
        #expect(result.isError == true)
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("batch did not return an object payload")
            return
        }
        #expect(payload["error_code"]?.stringValue == "invalid_argument")
        #expect(payload["results"] == nil, "must be rejected up front, before anything ran")
    }

    @Test("timeout result is a structured timeout error")
    func timeoutResultShape() {
        let r = ToolTimeouts.timeoutResult(name: "browser_list_tabs", limit: 90)
        #expect(r.isError)
        guard case .object(let payload) = r.structuredContent else { Issue.record("not an object"); return }
        #expect(payload["error_code"] == .string("timeout"))
        #expect(payload["tool"] == .string("browser_list_tabs"))
    }

    @Test("AsyncTimeout returns nil for a slow operation without waiting for it, and the value for a fast one")
    func asyncTimeout() async {
        let start = Date()
        let slow: Int? = await AsyncTimeout.run(timeout: 0.2) {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return 1
        }
        #expect(slow == nil)
        #expect(Date().timeIntervalSince(start) < 1.5)
        let fast: Int? = await AsyncTimeout.run(timeout: 2) { 7 }
        #expect(fast == 7)
    }

    @Test("parent watchdog fires when the watched process exits")
    func watchdogFiresOnExit() async throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        let box = FiredBox()
        // Poll path disabled (60s, always "alive"): only kqueue NOTE_EXIT can fire.
        let watchdog = ParentWatchdog.start(
            parentPID: child.processIdentifier,
            pollInterval: 60,
            isParentAlive: { true },
            onParentExit: { box.mark() }
        )
        #expect(watchdog != nil)
        #expect(!box.value, "fired before the process exited")
        child.terminate()
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !box.value {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(box.value, "NOTE_EXIT did not fire for the exited process")
        watchdog?.cancel()
    }

    @Test("parent watchdog ignores pid 1 and the poll path fires when the parent is gone")
    func watchdogPollPath() async {
        #expect(ParentWatchdog.start(parentPID: 1, onParentExit: {}) == nil)
        let box = FiredBox()
        let watchdog = ParentWatchdog.start(
            parentPID: getpid(),            // alive for the whole test: kqueue never fires
            pollInterval: 0.1,
            isParentAlive: { false },
            onParentExit: { box.mark() }
        )
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !box.value {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(box.value)
        watchdog?.cancel()
    }

    // MARK: - End to end against the built server

    static func serverBinary() -> String {
        let dir = (#filePath as NSString).deletingLastPathComponent
        let root = URL(fileURLWithPath: dir).deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent(".build/debug/mac-control-mcp").path
    }

    final class Server {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        var buffer = Data()

        init() throws {
            process.executableURL = URL(fileURLWithPath: ServerLifecycleTests.serverBinary())
            process.standardInput = stdin
            process.standardOutput = stdout
            process.standardError = FileHandle.nullDevice
            try process.run()
            let fd = stdout.fileHandleForReading.fileDescriptor
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        }

        func send(_ json: String) {
            stdin.fileHandleForWriting.write(Data((json + "\n").utf8))
        }

        /// Seconds until a response with `id` shows up, or nil on timeout.
        func waitFor(id: Int, timeout: TimeInterval) -> TimeInterval? {
            let start = Date()
            let needle = "\"id\":\(id)"
            while Date().timeIntervalSince(start) < timeout {
                var chunk = [UInt8](repeating: 0, count: 65536)
                let n = chunk.withUnsafeMutableBytes { Darwin.read(stdout.fileHandleForReading.fileDescriptor, $0.baseAddress, $0.count) }
                if n > 0 { buffer.append(contentsOf: chunk[0..<n]) }
                if String(decoding: buffer, as: UTF8.self).contains(needle) {
                    return Date().timeIntervalSince(start)
                }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return nil
        }

        func hasResponse(id: Int) -> Bool {
            String(decoding: buffer, as: UTF8.self).contains("\"id\":\(id)")
        }

        func terminate() {
            if process.isRunning { process.terminate() }
        }
    }

    static let initialize = #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}"#
    static func slowCall(id: Int, seconds: Int) -> String {
        #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"wait_for_app","arguments":{"bundle_id":"dev.macmcp.nonexistent.lifecycle-test","timeout_seconds":\#(seconds)}}}"#
    }

    @Test("a slow tool call does not block other requests")
    func slowCallDoesNotBlock() throws {
        let server = try Server()
        defer { server.terminate() }
        server.send(Self.initialize)
        #expect(server.waitFor(id: 1, timeout: 5) != nil)

        server.send(Self.slowCall(id: 2, seconds: 4))
        server.send(#"{"jsonrpc":"2.0","id":3,"method":"ping"}"#)
        let pingLatency = server.waitFor(id: 3, timeout: 3)
        #expect(pingLatency != nil, "ping was blocked behind the slow wait_for_app call")
        #expect(!server.hasResponse(id: 2), "slow call should still be running when ping is answered")
        #expect(server.waitFor(id: 2, timeout: 8) != nil, "slow call never answered")
    }

    @Test("closing stdin during a slow call exits the server promptly")
    func stdinEOFExitsDespiteSlowCall() throws {
        let server = try Server()
        defer { server.terminate() }
        server.send(Self.initialize)
        #expect(server.waitFor(id: 1, timeout: 5) != nil)
        server.send(Self.slowCall(id: 2, seconds: 30))
        Thread.sleep(forTimeInterval: 0.3)
        try server.stdin.fileHandleForWriting.close()

        // Server grace for in-flight requests is 2s; allow 3s margin.
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline && server.process.isRunning {
            Thread.sleep(forTimeInterval: 0.05)
        }
        #expect(!server.process.isRunning, "server still running after stdin EOF")
    }

    @Test("server exits when its parent dies while stdin stays open")
    func exitsWhenParentDies() throws {
        // sh is the parent; `sleep 8` keeps the server's stdin open so only
        // the parent-death watchdog can end it.
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 8 | \"$1\" >/dev/null 2>&1 & echo $!; wait", "sh", Self.serverBinary()]
        let out = Pipe()
        shell.standardOutput = out
        try shell.run()

        var pidText = ""
        let readDeadline = Date().addingTimeInterval(3)
        while Date() < readDeadline && !pidText.contains("\n") {
            pidText += String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        }
        let serverPID = try #require(Int32(pidText.trimmingCharacters(in: .whitespacesAndNewlines)))
        Thread.sleep(forTimeInterval: 0.5)
        #expect(kill(serverPID, 0) == 0, "server did not start")

        kill(shell.processIdentifier, SIGKILL)
        let deadline = Date().addingTimeInterval(5)
        var alive = true
        while Date() < deadline {
            if kill(serverPID, 0) != 0 { alive = false; break }
            Thread.sleep(forTimeInterval: 0.05)
        }
        if alive { kill(serverPID, SIGKILL) }
        #expect(!alive, "server outlived its parent")
    }
}

final class FiredBox: @unchecked Sendable {
    private let lock = NSLock()
    private var fired = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return fired }
    func mark() { lock.lock(); fired = true; lock.unlock() }
}
