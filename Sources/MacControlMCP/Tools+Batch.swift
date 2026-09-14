import Foundation

// MARK: - Tool definitions (v0.9 workstream C — C-1: batch / composite call)
//
// Gap audit (docs/gap-audit-v0.9.md, C-1, priority P0): 143 tools, zero
// batching. Every find → click → verify loop costs 3 model↔server round
// trips. This adds one `batch` tool that executes N tool calls
// sequentially through the *same* dispatcher (`ToolRegistry.callTool`) a
// standalone `tools/call` uses, so behaviour (including per-call
// ToolTimeouts and permission-context enrichment) is identical to calling
// each tool individually — just without the round trips.
//
// v0.9 review follow-up (same day):
//   - CRITICAL: a batch whose summed sub-limits exceeded `batchCap` used
//     to be silently truncated by the *outer* tools/call timeout in
//     main.swift while `callBatch` kept running side-effecting sub-calls
//     underneath it (AsyncTimeout.run's "late result discarded"
//     semantics don't cancel the work). Now rejected up front, before
//     anything executes, with `invalid_argument`. A hard `maxCalls` cap
//     closes the same hole from the "many cheap calls" direction.
//   - HIGH: a sub-call that times out is not cancelled by AsyncTimeout
//     (blocking framework calls can't be) and can still complete in the
//     background after the batch has moved on — e.g. a stale `click`
//     landing after a later call changed focus. The batch now always
//     stops on a sub-call timeout, regardless of `stop_on_error`.
extension ToolRegistry {
    static let definitionsBatch: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "batch",
            description: """
                Execute a sequence of tool calls in order, through the \
                same dispatcher as tools/call (each call gets its own \
                ToolTimeouts budget and permission-context enrichment, \
                exactly as if called standalone). Nesting a "batch" call \
                inside calls is rejected, as is more than 50 calls, and a \
                batch whose calls' combined timeout budget would exceed \
                300s (rejected up front with invalid_argument — never \
                silently truncated). stop_on_error (default true) halts \
                after the first failing call; set false to run every \
                call regardless of earlier failures. A sub-call TIMEOUT \
                always halts the batch, regardless of stop_on_error: the \
                underlying framework call cannot be cancelled and may \
                still complete in the background after the batch moves \
                on (e.g. a stale click landing after a later call \
                changed focus), so nothing further is executed once one \
                is seen — check for error_code "timeout" /  \
                aborted_reason "sub_call_timeout_not_cancellable" on the \
                last result. delay_ms (default 0, max 5000) waits \
                between calls (never after the last one). Returns {ok, \
                results: [{id, name, ok, ms, result, error_code?, \
                aborted_reason?}], completed, stopped_at, total_ms}. Use \
                this instead of N separate tools/call round trips for an \
                act-and-verify sequence, e.g. focused_app + list_windows \
                + permissions_status.
                """,
            inputSchema: schema(
                properties: [
                    "calls": .object([
                        "type": .string("array"),
                        "description": .string(
                            "Tool calls to run in order (max 50). Each item: {name (tool name, "
                                + "required), arguments (object, optional, default {}), id (string or "
                                + "integer, optional and unique — echoed back on the matching result "
                                + "to correlate it; defaults to the call's index)}."
                        ),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "name": .object([
                                    "type": .string("string"),
                                    "description": .string("Tool name, exactly as tools/list reports it. \"batch\" is rejected.")
                                ]),
                                "arguments": .object([
                                    "type": .string("object"),
                                    "description": .string("Arguments for this call, same shape as tools/call's arguments.")
                                ]),
                                "id": .object([
                                    "type": .array([.string("string"), .string("integer")]),
                                    "description": .string("Caller-chosen unique correlation id, echoed back on this call's result.")
                                ])
                            ]),
                            "required": .array([.string("name")]),
                            "additionalProperties": .bool(false)
                        ]),
                        "minItems": .number(1),
                        "maxItems": .number(50)
                    ]),
                    "stop_on_error": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Stop after the first failing call (default true) and leave the rest "
                                + "unexecuted. When false, every call runs regardless of earlier failures "
                                + "— except a sub-call timeout, which always stops the batch."
                        ),
                        "default": .bool(true)
                    ]),
                    "delay_ms": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string(
                            "Milliseconds to wait between calls (default 0, max 5000, clamped). "
                                + "No delay is added after the final call."
                        ),
                        "default": .number(0)
                    ])
                ],
                required: ["calls"]
            )
        )
    ]

    /// Hard cap on `calls.count`. Paired with `ToolTimeouts.batchCap`
    /// (300s) to bound both dimensions a batch could otherwise blow up
    /// on: many calls, or a few very slow ones.
    private static let maxBatchCalls = 50

    /// Parsed, validated form of one `calls[]` entry. Validation happens
    /// for the whole array up front — nothing has executed yet, so a
    /// malformed entry (nested "batch", a non-object `arguments`, a
    /// non-string/integer or duplicate `id`) rejects the entire request
    /// with `invalid_argument` rather than surfacing as a per-call error
    /// buried partway through `results`.
    private struct BatchCall {
        let id: JSONValue
        let name: String
        let arguments: [String: JSONValue]
    }

    private func batchInvalidArgument(_ message: String) -> ToolCallResult {
        errorResult(
            message,
            [
                "ok": .bool(false),
                "error": .string(message),
                "error_code": .string("invalid_argument")
            ]
        )
    }

    /// Stable string key for duplicate-id detection. `id` is restricted
    /// to string or integral-number JSONValue by `parseCalls` before this
    /// is ever called, so the switch's default case is unreachable.
    private static func idKey(_ id: JSONValue) -> String {
        switch id {
        case .string(let value): return "s:\(value)"
        case .number(let value): return "n:\(Int(value))"
        default: return "?:\(id)"
        }
    }

    private enum ParseOutcome {
        case calls([BatchCall])
        case rejected(ToolCallResult)
    }

    private func parseCalls(_ rawCalls: [JSONValue]) -> ParseOutcome {
        var parsed: [BatchCall] = []
        var seenIDs: [String: Int] = [:]

        for (index, raw) in rawCalls.enumerated() {
            guard let object = raw.objectValue else {
                return .rejected(batchInvalidArgument("batch.calls[\(index)] must be an object with at least a name."))
            }
            guard let name = object["name"]?.stringValue, !name.isEmpty else {
                return .rejected(batchInvalidArgument("batch.calls[\(index)] requires a non-empty string name."))
            }
            // `batch` dispatches through the same `callTool` a standalone
            // tools/call uses, not through itself — nesting would let a
            // batch call another batch that calls another, with no depth
            // limit and no way to reason about the combined timeout.
            guard name != "batch" else {
                return .rejected(batchInvalidArgument("batch.calls[\(index)]: nested \"batch\" calls are not allowed."))
            }

            let callArguments: [String: JSONValue]
            if let argumentsValue = object["arguments"] {
                guard let object = argumentsValue.objectValue else {
                    return .rejected(batchInvalidArgument("batch.calls[\(index)].arguments must be an object."))
                }
                callArguments = object
            } else {
                callArguments = [:]
            }

            let id = object["id"] ?? .number(Double(index))
            switch id {
            case .string:
                break
            case .number(let value):
                guard value.rounded() == value else {
                    return .rejected(batchInvalidArgument("batch.calls[\(index)].id must be a string or integer (got a non-integer number)."))
                }
            default:
                return .rejected(batchInvalidArgument("batch.calls[\(index)].id must be a string or integer."))
            }

            let key = Self.idKey(id)
            if let firstIndex = seenIDs[key] {
                return .rejected(batchInvalidArgument(
                    "batch.calls[\(index)].id duplicates batch.calls[\(firstIndex)].id; ids must be unique."
                ))
            }
            seenIDs[key] = index

            parsed.append(BatchCall(id: id, name: name, arguments: callArguments))
        }

        return .calls(parsed)
    }

    func callBatch(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let rawCalls = arguments["calls"]?.arrayValue, !rawCalls.isEmpty else {
            return batchInvalidArgument("batch requires a non-empty calls array of {name, arguments?, id?}.")
        }
        guard rawCalls.count <= Self.maxBatchCalls else {
            return batchInvalidArgument(
                "batch supports at most \(Self.maxBatchCalls) calls per request (got \(rawCalls.count)); split it into smaller batches."
            )
        }

        let parsedCalls: [BatchCall]
        switch parseCalls(rawCalls) {
        case .rejected(let rejection): return rejection
        case .calls(let calls): parsedCalls = calls
        }

        let stopOnError = arguments["stop_on_error"]?.boolValue ?? true
        let rawDelay = arguments["delay_ms"]?.doubleValue ?? 0
        let delayMs = rawDelay.isFinite ? min(max(rawDelay, 0), 5000) : 0
        let delayNanoseconds = UInt64(delayMs * 1_000_000)

        // Test-only hook (see BatchToolTests): forces every sub-call's
        // timeout budget to a tiny fixed value so a test can exercise the
        // *real* AsyncTimeout expiry path deterministically, without
        // mutating the process-wide MAC_CONTROL_MCP_TOOL_TIMEOUT env var
        // (which would race other tests running in parallel). Only ever
        // honored inside the test host — see StoreLocation.isRunningUnderTests.
        let testTimeoutOverride: TimeInterval? = StoreLocation.isRunningUnderTests
            ? arguments["__test_override_call_timeout_seconds"]?.doubleValue
            : nil

        // Same per-call budgets a standalone tools/call would get for
        // each of these (main.swift computes this identically for a
        // top-level call) — computed once, up front, so the pre-flight
        // budget check below and the actual per-call AsyncTimeout below
        // can never disagree.
        let callLimits: [TimeInterval] = parsedCalls.map { call in
            testTimeoutOverride ?? ToolTimeouts.limit(for: call.name, arguments: call.arguments)
        }

        // CRITICAL fix (review): a batch whose summed sub-limits exceed
        // ToolTimeouts.batchCap used to be silently truncated by the
        // *outer* tools/call timeout in main.swift (which computes the
        // same sum, capped at batchCap, via ToolTimeouts.limit(for:
        // "batch", ...)) while this handler kept running side-effecting
        // sub-calls underneath it. Reject up front instead — never let
        // that truncation happen silently.
        let delayOverheadSeconds = (delayMs / 1000) * Double(max(0, parsedCalls.count - 1))
        let totalBudget = callLimits.reduce(0, +) + delayOverheadSeconds
        guard totalBudget <= ToolTimeouts.batchCap else {
            return batchInvalidArgument(
                "batch budget \(Int(totalBudget.rounded()))s (sum of each call's timeout, plus delay_ms "
                    + "overhead) exceeds the \(Int(ToolTimeouts.batchCap))s cap; split it into smaller batches "
                    + "or reduce delay_ms."
            )
        }

        let batchStart = Date()
        var results: [JSONValue] = []
        var stoppedAt: Int?

        for (index, call) in parsedCalls.enumerated() {
            let callLimit = callLimits[index]
            let callStart = Date()
            let finished = await AsyncTimeout.run(timeout: callLimit) { [self] in
                await self.callTool(name: call.name, arguments: call.arguments)
            }
            let elapsedMs = Date().timeIntervalSince(callStart) * 1000
            let timedOut = finished == nil

            // Same permission-context enrichment a standalone tools/call
            // gets in main.swift, applied per sub-result here since batch
            // results never individually pass back through that code path.
            let result = (finished ?? ToolTimeouts.timeoutResult(name: call.name, limit: callLimit))
                .withPermissionContext()

            var entry: [String: JSONValue] = [
                "id": call.id,
                "name": .string(call.name),
                "ok": .bool(!result.isError),
                "ms": .number(elapsedMs.rounded()),
                "result": result.structuredContent
            ]
            if case .object(let dict) = result.structuredContent, let code = dict["error_code"]?.stringValue {
                entry["error_code"] = .string(code)
            }
            if timedOut {
                // HIGH fix (review): AsyncTimeout.run cannot cancel the
                // underlying blocking framework call — it may still fire
                // later, after the batch has moved on to a different
                // target (e.g. a stale click landing post-focus-change).
                // Stop unconditionally; stop_on_error only governs
                // *ordinary* failures, not an uncancellable in-flight call.
                entry["aborted_reason"] = .string("sub_call_timeout_not_cancellable")
            }
            results.append(.object(entry))

            if timedOut {
                stoppedAt = index
                break
            }

            if result.isError && stopOnError {
                stoppedAt = index
                break
            }

            let isLastCall = index == parsedCalls.count - 1
            if !isLastCall && delayMs > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
        }

        let totalMs = Date().timeIntervalSince(batchStart) * 1000
        let completed = results.count
        // isError only when the batch actually stopped short — either an
        // ordinary failure under stop_on_error, or (always) a timeout — not
        // when it ran every call to completion (even with individual
        // failures, under stop_on_error:false).
        let batchFailed = stoppedAt != nil

        let payload: [String: JSONValue] = [
            "ok": .bool(!batchFailed),
            "results": .array(results),
            "completed": .number(Double(completed)),
            "stopped_at": stoppedAt.map { JSONValue.number(Double($0)) } ?? .null,
            "total_ms": .number(totalMs.rounded())
        ]

        let summary = stoppedAt != nil
            ? "Batch stopped after \(completed)/\(parsedCalls.count) call(s) at index \(stoppedAt!)."
            : "Batch completed \(completed)/\(parsedCalls.count) call(s)."
        return ToolCallResult(text: summary, structuredContent: .object(payload), isError: batchFailed)
    }
}
