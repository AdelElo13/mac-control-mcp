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

    // MARK: - Review fix: a REAL sub-call timeout always stops the batch

    @Test("a real sub-call timeout (AsyncTimeout expiry) always stops the batch, even with stop_on_error:false")
    func realSubCallTimeoutAlwaysStopsBatch() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        // wait_for_app polls for up to timeout_seconds:5 looking for a
        // bundle id that will never appear — it is still running when the
        // test-only forced per-call limit (0.05s) expires, so
        // AsyncTimeout.run genuinely discards its late result. This is
        // the real timeout path (`finished == nil` in callBatch), not
        // wait_for_app's own internal deadline returning an ordinary
        // "not found" result.
        let calls: JSONValue = .array([
            .object([
                "name": .string("wait_for_app"),
                "arguments": .object([
                    "bundle_id": .string("com.mac-control-mcp.does-not-exist.\(UUID().uuidString)"),
                    "timeout_seconds": .number(5)
                ])
            ]),
            .object(["name": .string("focused_app")])
        ])

        let result = await registry.callTool(
            name: "batch",
            arguments: [
                "calls": calls,
                // stop_on_error:false to prove the timeout halts the batch
                // unconditionally — not because an ordinary failure did.
                "stop_on_error": .bool(false),
                "__test_override_call_timeout_seconds": .number(0.05)
            ]
        )

        #expect(result.isError == true)
        guard case .object(let payload) = result.structuredContent,
              case .array(let results)? = payload["results"] else {
            Issue.record("batch did not return a results array")
            return
        }
        // The second call (focused_app) never ran.
        #expect(results.count == 1)
        #expect(payload["completed"]?.doubleValue == 1)
        #expect(payload["stopped_at"]?.doubleValue == 0)

        guard case .object(let first)? = results.first else {
            Issue.record("missing first result")
            return
        }
        #expect(first["ok"]?.boolValue == false)
        #expect(first["error_code"]?.stringValue == "timeout")
        #expect(first["aborted_reason"]?.stringValue == "sub_call_timeout_not_cancellable")
    }

    // MARK: - Review fix: hard cap on calls.count

    @Test("more than 50 calls is rejected up front with invalid_argument")
    func maxCallsEnforced() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array(
            (0..<51).map { _ in .object(["name": .string("focused_app")]) }
        )
        let result = await registry.callTool(name: "batch", arguments: ["calls": calls])
        #expect(result.isError == true)
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("batch did not return an object payload")
            return
        }
        #expect(payload["error_code"]?.stringValue == "invalid_argument")
        #expect(payload["results"] == nil)
    }

    @Test("exactly 50 calls is accepted")
    func exactlyMaxCallsAccepted() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array(
            (0..<50).map { _ in .object(["name": .string("focused_app")]) }
        )
        // 50 calls at the real 90s-default limit each would blow the 300s
        // budget cap on their own — force a tiny per-call limit via the
        // test hook so this test isolates the *count* cap (<=50) from the
        // *budget* cap (<=300s), which has its own tests below.
        let result = await registry.callTool(
            name: "batch",
            arguments: ["calls": calls, "__test_override_call_timeout_seconds": .number(1)]
        )
        #expect(result.isError == false)
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("batch did not return an object payload")
            return
        }
        #expect(payload["completed"]?.doubleValue == 50)
    }

    // MARK: - Review fix: reject rather than silently truncate an over-budget batch

    @Test("a batch whose summed per-call timeout budget exceeds 300s is rejected up front, not truncated")
    func overBudgetBatchRejected() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        // Each call's own ToolTimeouts.limit = max(90, timeout_seconds + 15).
        // Two calls at timeout_seconds:200 → 215s each → 430s summed,
        // comfortably over the 300s cap.
        let overBudgetCall: JSONValue = .object([
            "name": .string("wait_for_app"),
            "arguments": .object([
                "bundle_id": .string("com.mac-control-mcp.does-not-exist"),
                "timeout_seconds": .number(200)
            ])
        ])
        let calls: JSONValue = .array([overBudgetCall, overBudgetCall])

        let result = await registry.callTool(name: "batch", arguments: ["calls": calls])
        #expect(result.isError == true)
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("batch did not return an object payload")
            return
        }
        #expect(payload["error_code"]?.stringValue == "invalid_argument")
        // Rejected before anything ran.
        #expect(payload["results"] == nil)
    }

    @Test("delay_ms overhead counts toward the 300s budget check")
    func delayOverheadCountsTowardBudget() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        // 4 cheap calls (90s default limit each is irrelevant here since
        // we force a tiny per-call limit via the test hook) but a 5000ms
        // delay between each of the 4 calls (3 gaps) plus a forced
        // per-call limit chosen so only the delay overhead pushes the
        // total over budget.
        let calls: JSONValue = .array(
            (0..<4).map { _ in .object(["name": .string("focused_app")]) }
        )
        let result = await registry.callTool(
            name: "batch",
            arguments: [
                "calls": calls,
                "delay_ms": .number(5000),
                "__test_override_call_timeout_seconds": .number(99)
            ]
        )
        // 4 * 99s + 3 * 5s delay = 411s > 300s cap.
        #expect(result.isError == true)
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("batch did not return an object payload")
            return
        }
        #expect(payload["error_code"]?.stringValue == "invalid_argument")
    }

    // MARK: - Review fix: MEDIUM validation

    @Test("a non-object arguments field is rejected, naming the offending index")
    func nonObjectArgumentsRejected() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array([
            .object(["name": .string("focused_app")]),
            .object(["name": .string("list_apps"), "arguments": .array([.string("oops")])])
        ])
        let result = await registry.callTool(name: "batch", arguments: ["calls": calls])
        #expect(result.isError == true)
        guard case .object(let payload) = result.structuredContent,
              let message = payload["error"]?.stringValue else {
            Issue.record("batch did not return an error payload")
            return
        }
        #expect(payload["error_code"]?.stringValue == "invalid_argument")
        #expect(message.contains("calls[1]"))
        #expect(payload["results"] == nil)
    }

    @Test("an id that is not a string or integer is rejected")
    func nonStringOrIntegerIDRejected() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        for badID: JSONValue in [.bool(true), .array([]), .object([:]), .null, .number(1.5)] {
            let calls: JSONValue = .array([
                .object(["name": .string("focused_app"), "id": badID])
            ])
            let result = await registry.callTool(name: "batch", arguments: ["calls": calls])
            #expect(result.isError == true, "expected rejection for id \(badID)")
            guard case .object(let payload) = result.structuredContent else {
                Issue.record("batch did not return an object payload for id \(badID)")
                continue
            }
            #expect(payload["error_code"]?.stringValue == "invalid_argument")
        }
    }

    @Test("an integer id (whole-number JSON number) is accepted")
    func integerNumberIDAccepted() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let calls: JSONValue = .array([
            .object(["name": .string("focused_app"), "id": .number(7)])
        ])
        let result = await registry.callTool(name: "batch", arguments: ["calls": calls])
        #expect(result.isError == false)
    }

    @Test("duplicate ids (explicit, and explicit colliding with a default index) are rejected")
    func duplicateIDsRejected() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())

        let explicitDuplicate: JSONValue = .array([
            .object(["name": .string("focused_app"), "id": .string("dup")]),
            .object(["name": .string("list_apps"), "id": .string("dup")])
        ])
        let r1 = await registry.callTool(name: "batch", arguments: ["calls": explicitDuplicate])
        #expect(r1.isError == true)
        guard case .object(let payload1) = r1.structuredContent else {
            Issue.record("batch did not return an object payload")
            return
        }
        #expect(payload1["error_code"]?.stringValue == "invalid_argument")
        #expect(payload1["results"] == nil)

        // The second call's default id (index 0) collides with the
        // first call's explicit id.
        let defaultCollision: JSONValue = .array([
            .object(["name": .string("focused_app"), "id": .number(1)]),
            .object(["name": .string("list_apps")]),
            .object(["name": .string("permissions_status")])
        ])
        let r2 = await registry.callTool(name: "batch", arguments: ["calls": defaultCollision])
        #expect(r2.isError == true)
        guard case .object(let payload2) = r2.structuredContent else {
            Issue.record("batch did not return an object payload")
            return
        }
        #expect(payload2["error_code"]?.stringValue == "invalid_argument")
    }
}
