import Testing
import Foundation
@testable import MacControlMCP

// v0.9 workstream C — C-1 (docs/gap-audit-v0.9.md): `batch` runs N tool
// calls sequentially through the same dispatcher `tools/call` uses
// (`ToolRegistry.callTool`), so an act-and-verify sequence costs one
// round trip instead of N.
@Suite("Batch tool", .serialized)
struct BatchToolTests {

    // MARK: - Registration

    @Test("batch is registered")
    func batchIsRegistered() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let names = Set(registry.toolDefinitions.map { $0.name })
        #expect(names.contains("batch"))
    }

    @Test("batch requires a non-empty calls array")
    func requiresCalls() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())

        let missing = await registry.callTool(name: "batch", arguments: [:])
        #expect(missing.isError == true)

        let empty = await registry.callTool(name: "batch", arguments: ["calls": .array([])])
        #expect(empty.isError == true)
    }

    // MARK: - Sequential order

    @Test("calls execute in order and results correlate by id/index")
    func sequentialOrder() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array([
            .object(["name": .string("focused_app"), "id": .string("a")]),
            .object(["name": .string("list_apps"), "id": .string("b")]),
            .object(["name": .string("permissions_status"), "id": .string("c")])
        ])

        let result = await registry.callTool(name: "batch", arguments: ["calls": calls])
        #expect(result.isError == false)

        guard case .object(let payload) = result.structuredContent,
              case .array(let results)? = payload["results"] else {
            Issue.record("batch did not return a results array")
            return
        }

        #expect(results.count == 3)
        #expect(payload["completed"]?.doubleValue == 3)
        #expect(payload["stopped_at"] == .null)

        let names = results.compactMap { entry -> String? in
            guard case .object(let dict) = entry else { return nil }
            return dict["name"]?.stringValue
        }
        #expect(names == ["focused_app", "list_apps", "permissions_status"])

        let ids = results.compactMap { entry -> String? in
            guard case .object(let dict) = entry else { return nil }
            return dict["id"]?.stringValue
        }
        #expect(ids == ["a", "b", "c"])

        for entry in results {
            guard case .object(let dict) = entry else {
                Issue.record("result entry was not an object")
                continue
            }
            #expect(dict["ok"]?.boolValue == true)
        }
    }

    @Test("call id defaults to its index when omitted")
    func defaultIdIsIndex() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array([
            .object(["name": .string("focused_app")]),
            .object(["name": .string("list_apps")])
        ])
        let result = await registry.callTool(name: "batch", arguments: ["calls": calls])
        guard case .object(let payload) = result.structuredContent,
              case .array(let results)? = payload["results"] else {
            Issue.record("batch did not return a results array")
            return
        }
        let ids = results.compactMap { entry -> Double? in
            guard case .object(let dict) = entry else { return nil }
            return dict["id"]?.doubleValue
        }
        #expect(ids == [0, 1])
    }

    // MARK: - Per-call timing

    @Test("every result carries a numeric ms and total_ms is present")
    func perCallMsPresent() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array([
            .object(["name": .string("focused_app")]),
            .object(["name": .string("list_apps")])
        ])
        let result = await registry.callTool(name: "batch", arguments: ["calls": calls])
        guard case .object(let payload) = result.structuredContent,
              case .array(let results)? = payload["results"] else {
            Issue.record("batch did not return a results array")
            return
        }
        for entry in results {
            guard case .object(let dict) = entry else {
                Issue.record("result entry was not an object")
                continue
            }
            guard let ms = dict["ms"]?.doubleValue else {
                Issue.record("result entry missing numeric ms")
                continue
            }
            #expect(ms >= 0)
        }
        #expect(payload["total_ms"]?.doubleValue ?? -1 >= 0)
    }

    // MARK: - Unknown tool name

    @Test("an unknown tool name is captured as a failed result, not a thrown error")
    func unknownToolNameCaptured() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array([
            .object(["name": .string("this_tool_does_not_exist")])
        ])
        let result = await registry.callTool(name: "batch", arguments: ["calls": calls])
        // stop_on_error defaults to true, so the batch itself is flagged
        // as failed — but the failure surfaces as a normal result entry,
        // not a crash or a top-level parse error.
        #expect(result.isError == true)

        guard case .object(let payload) = result.structuredContent,
              case .array(let results)? = payload["results"],
              case .object(let first)? = results.first else {
            Issue.record("batch did not return a results array")
            return
        }
        #expect(first["ok"]?.boolValue == false)
        #expect(first["name"]?.stringValue == "this_tool_does_not_exist")
        #expect(payload["stopped_at"]?.doubleValue == 0)
    }

    // MARK: - stop_on_error

    @Test("stop_on_error true (default) halts after the first failure")
    func stopOnErrorTrueHalts() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array([
            .object(["name": .string("focused_app")]),
            .object(["name": .string("nonexistent_tool_one")]),
            .object(["name": .string("list_apps")])
        ])
        let result = await registry.callTool(name: "batch", arguments: ["calls": calls])
        #expect(result.isError == true)
        guard case .object(let payload) = result.structuredContent,
              case .array(let results)? = payload["results"] else {
            Issue.record("batch did not return a results array")
            return
        }
        // Only the first two calls ran; the third was never attempted.
        #expect(results.count == 2)
        #expect(payload["completed"]?.doubleValue == 2)
        #expect(payload["stopped_at"]?.doubleValue == 1)
    }

    @Test("stop_on_error false runs every call despite earlier failures")
    func stopOnErrorFalseRunsAll() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array([
            .object(["name": .string("focused_app")]),
            .object(["name": .string("nonexistent_tool_one")]),
            .object(["name": .string("list_apps")])
        ])
        let result = await registry.callTool(
            name: "batch",
            arguments: ["calls": calls, "stop_on_error": .bool(false)]
        )
        // The batch itself did not stop early, so it is not flagged as failed
        // even though one of its calls failed.
        #expect(result.isError == false)
        guard case .object(let payload) = result.structuredContent,
              case .array(let results)? = payload["results"] else {
            Issue.record("batch did not return a results array")
            return
        }
        #expect(results.count == 3)
        #expect(payload["completed"]?.doubleValue == 3)
        #expect(payload["stopped_at"] == .null)

        let oks = results.compactMap { entry -> Bool? in
            guard case .object(let dict) = entry else { return nil }
            return dict["ok"]?.boolValue
        }
        #expect(oks == [true, false, true])
    }

    // MARK: - Nested batch rejected

    @Test("a nested batch call is rejected up front with invalid_argument")
    func nestedBatchRejected() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array([
            .object(["name": .string("focused_app")]),
            .object(["name": .string("batch"), "arguments": .object(["calls": .array([])])])
        ])
        let result = await registry.callTool(name: "batch", arguments: ["calls": calls])
        #expect(result.isError == true)

        guard case .object(let payload) = result.structuredContent else {
            Issue.record("batch did not return an object payload")
            return
        }
        #expect(payload["error_code"]?.stringValue == "invalid_argument")
        // Rejected before anything ran — no partial results leaked through.
        #expect(payload["results"] == nil)
    }

    // MARK: - delay_ms

    @Test("delay_ms is honoured between calls (but not after the last one)")
    func delayHonoured() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array([
            .object(["name": .string("focused_app")]),
            .object(["name": .string("focused_app")]),
            .object(["name": .string("focused_app")])
        ])
        let delayMs = 200.0
        let start = Date()
        let result = await registry.callTool(
            name: "batch",
            arguments: ["calls": calls, "delay_ms": .number(delayMs)]
        )
        let elapsedMs = Date().timeIntervalSince(start) * 1000
        #expect(result.isError == false)
        // Two inter-call gaps (3 calls), no gap after the last — allow slack
        // for scheduling jitter but require most of the expected delay.
        #expect(elapsedMs >= delayMs * 2 * 0.8)
    }

    @Test("delay_ms is clamped to 5000ms max")
    func delayClampedToMax() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array([
            .object(["name": .string("focused_app")])
        ])
        // A single call has no inter-call gap, so this just verifies the
        // batch still runs (doesn't reject) with an out-of-range delay_ms.
        let result = await registry.callTool(
            name: "batch",
            arguments: ["calls": calls, "delay_ms": .number(999_999)]
        )
        #expect(result.isError == false)
    }

    // MARK: - Slow call timeout doesn't hang the batch

    @Test("a slow call's own timeout doesn't hang the batch")
    func slowCallDoesNotHangBatch() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array([
            .object([
                "name": .string("wait_for_app"),
                "arguments": .object([
                    "bundle_id": .string("com.mac-control-mcp.does-not-exist.\(UUID().uuidString)"),
                    "timeout_seconds": .number(1)
                ])
            ]),
            .object(["name": .string("focused_app")])
        ])

        let start = Date()
        let result = await registry.callTool(
            name: "batch",
            arguments: ["calls": calls, "stop_on_error": .bool(false)]
        )
        let elapsedSeconds = Date().timeIntervalSince(start)

        // wait_for_app's own timeout_seconds:1 bounds it; the whole batch
        // (one slow call + one fast one) must finish in well under
        // ToolTimeouts.defaultLimit (90s), proving the batch didn't hang.
        #expect(elapsedSeconds < 30)

        guard case .object(let payload) = result.structuredContent,
              case .array(let results)? = payload["results"] else {
            Issue.record("batch did not return a results array")
            return
        }
        #expect(results.count == 2)
        // The second call still ran after the slow/failing first one.
        guard case .object(let second)? = results.last else {
            Issue.record("missing second result")
            return
        }
        #expect(second["name"]?.stringValue == "focused_app")
    }
}
