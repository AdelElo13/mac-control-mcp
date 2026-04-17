import Testing
import Foundation
import ApplicationServices
@testable import MacControlMCP

@Suite("Security + correctness hardening (Codex review follow-up)", .serialized)
struct HardeningTests {
    // MARK: - PathValidator

    @Test("PathValidator allows temp dir")
    func allowsTempDir() throws {
        let path = NSTemporaryDirectory().appending("mcp-test-\(UUID().uuidString).png")
        let resolved = try PathValidator.validate(path)
        #expect(resolved.contains("mcp-test-"))
    }

    @Test("PathValidator rejects arbitrary system paths")
    func rejectsSystemPaths() {
        #expect(throws: PathValidator.ValidationError.self) {
            try PathValidator.validate("/etc/hosts")
        }
        #expect(throws: PathValidator.ValidationError.self) {
            try PathValidator.validate("/System/Library/foo.png")
        }
        #expect(throws: PathValidator.ValidationError.self) {
            try PathValidator.validate("/root/secret.png")
        }
    }

    @Test("PathValidator rejects traversal via ..")
    func rejectsTraversal() {
        let sneaky = NSTemporaryDirectory().appending("../../etc/hosts.png")
        #expect(throws: PathValidator.ValidationError.self) {
            try PathValidator.validate(sneaky)
        }
    }

    @Test("PathValidator rejects missing parent")
    func rejectsMissingParent() {
        #expect(throws: PathValidator.ValidationError.self) {
            try PathValidator.validate("/tmp/this-parent-does-not-exist-\(UUID().uuidString)/foo.png")
        }
    }

    @Test("capture_screen rejects arbitrary output_path")
    func captureRejectsArbitraryPath() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(
            name: "capture_screen",
            arguments: ["output_path": .string("/etc/hosts")]
        )
        #expect(result.isError == true)
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("no payload"); return
        }
        #expect(payload["ok"] == .bool(false))
    }

    // MARK: - ElementCache LRU behaviour

    @Test("resolve refreshes the access timestamp (hot entries survive eviction)")
    func resolveRefreshesTimestamp() async throws {
        let cache = ElementCache(ttl: 60, maxEntries: 3)
        let hot = await cache.store(AXUIElementCreateSystemWide(), pid: 1)
        _ = await cache.store(AXUIElementCreateSystemWide(), pid: 2)

        // Wait a bit so lastAccess timestamps actually differ.
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = await cache.resolve(hot) // refresh the "hot" entry

        // Now insert two more to force eviction beyond capacity.
        try await Task.sleep(nanoseconds: 5_000_000)
        _ = await cache.store(AXUIElementCreateSystemWide(), pid: 3)
        _ = await cache.store(AXUIElementCreateSystemWide(), pid: 4)

        // The hot entry should still be resolvable because it was the most
        // recently accessed. Under the old FIFO policy it would have been
        // evicted first.
        let still = await cache.resolve(hot)
        #expect(still != nil)
    }

    @Test("IDs use 8 random bytes (16 hex chars after el_)")
    func idLength() async {
        let cache = ElementCache()
        let id = await cache.store(AXUIElementCreateSystemWide(), pid: 1)
        #expect(id.hasPrefix("el_"))
        // el_ + 16 hex chars expected (except the UUID-fallback path, which
        // is ~19 chars — we only verify the happy path here).
        #expect(id.count == 19)
    }

    // MARK: - list_windows argument validation

    @Test("list_windows with malformed pid returns an error instead of 'all apps'")
    func listWindowsMalformedPID() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(
            name: "list_windows",
            arguments: ["pid": .string("not-a-number")]
        )
        #expect(result.isError == true)
    }

    @Test("list_windows without pid still works (lists all apps)")
    func listWindowsNoPID() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "list_windows", arguments: [:])
        #expect(result.isError == false)
    }

    // MARK: - OsascriptRunner stderr capture

    @Test("OsascriptRunner captures stderr on script failure")
    func osascriptStderrCapture() {
        // This script forces an error; stderr should contain the error text.
        let result = OsascriptRunner.run("error \"mcp-test-error-marker\" number -128")
        #expect(result.ok == false)
        #expect(result.stderr.contains("mcp-test-error-marker"))
    }
}
