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

extension ToolRegistry {
    static let definitionsBatch: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "batch",
            description: """
                Execute a sequence of tool calls in order, through the \
                same dispatcher as tools/call (each call gets its own \
                ToolTimeouts budget and permission-context enrichment, \
                exactly as if called standalone). Nesting a "batch" call \
                inside calls is rejected. stop_on_error (default true) \
                halts after the first failing call; set false to run \
                every call regardless of earlier failures. delay_ms \
                (default 0, max 5000) waits between calls (never after \
                the last one). Returns {ok, results: \
                [{id, name, ok, ms, result, error_code?}], completed, \
                stopped_at, total_ms}. Use this instead of N separate \
                tools/call round trips for an act-and-verify sequence, \
                e.g. focused_app + list_windows + permissions_status.
                """,
            inputSchema: schema(
                properties: [
                    "calls": .object([
                        "type": .string("array"),
                        "description": .string(
                            "Tool calls to run in order. Each item: {name (tool name, required), "
                                + "arguments (object, optional, default {}), id (string or integer, "
                                + "optional — echoed back on the matching result to correlate it; "
                                + "defaults to the call's index)}."
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
                                    "description": .string("Caller-chosen correlation id, echoed back on this call's result.")
                                ])
                            ]),
                            "required": .array([.string("name")]),
                            "additionalProperties": .bool(false)
                        ]),
                        "minItems": .number(1)
                    ]),
                    "stop_on_error": .object([
                        "type": .string("boolean"),
                        "description": .string(
                            "Stop after the first failing call (default true) and leave the rest "
                                + "unexecuted. When false, every call runs regardless of earlier failures."
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

    /// Parsed, validated form of one `calls[]` entry. Validation happens
    /// for the whole array up front — nothing has executed yet, so a
    /// malformed entry (or a nested "batch") rejects the entire request
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

    func callBatch(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let rawCalls = arguments["calls"]?.arrayValue, !rawCalls.isEmpty else {
            return batchInvalidArgument("batch requires a non-empty calls array of {name, arguments?, id?}.")
        }

        var parsedCalls: [BatchCall] = []
        for (index, raw) in rawCalls.enumerated() {
            guard let object = raw.objectValue else {
                return batchInvalidArgument("batch.calls[\(index)] must be an object with at least a name.")
            }
            guard let name = object["name"]?.stringValue, !name.isEmpty else {
                return batchInvalidArgument("batch.calls[\(index)] requires a non-empty string name.")
            }
            // `batch` dispatches through the same `callTool` a standalone
            // tools/call uses, not through itself — nesting would let a
            // batch call another batch that calls another, with no depth
            // limit and no way to reason about the combined timeout.
            guard name != "batch" else {
                return batchInvalidArgument("batch.calls[\(index)]: nested \"batch\" calls are not allowed.")
            }
            let callArguments = object["arguments"]?.objectValue ?? [:]
            let id = object["id"] ?? .number(Double(index))
            parsedCalls.append(BatchCall(id: id, name: name, arguments: callArguments))
        }

        let stopOnError = arguments["stop_on_error"]?.boolValue ?? true
        let rawDelay = arguments["delay_ms"]?.doubleValue ?? 0
        let delayMs = rawDelay.isFinite ? min(max(rawDelay, 0), 5000) : 0
        let delayNanoseconds = UInt64(delayMs * 1_000_000)

        let batchStart = Date()
        var results: [JSONValue] = []
        var stoppedAt: Int?

        for (index, call) in parsedCalls.enumerated() {
            // Same per-call budget a standalone tools/call would get
            // (main.swift computes this identically for a top-level call).
            let callLimit = ToolTimeouts.limit(for: call.name, arguments: call.arguments)
            let callStart = Date()
            let finished = await AsyncTimeout.run(timeout: callLimit) { [self] in
                await self.callTool(name: call.name, arguments: call.arguments)
            }
            let elapsedMs = Date().timeIntervalSince(callStart) * 1000

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
            results.append(.object(entry))

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
        // isError only when stop_on_error actually cut the batch short —
        // a batch that ran every call to completion (even with individual
        // failures, under stop_on_error:false) is not itself an error.
        let batchFailed = stopOnError && stoppedAt != nil

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
