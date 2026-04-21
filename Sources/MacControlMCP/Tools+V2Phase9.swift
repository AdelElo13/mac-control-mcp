import Foundation
import CoreGraphics

// MARK: - Tool definitions (v0.6.0 Phase 9: reliability + observability substrate)
//
// 8 new tools across the A/B/F themes of the v0.6.0 masterplan. Closes
// the Codex-flagged gaps: telemetry silent-success (solved already in
// v0.5.1), observability without context reads, undo/rollback, PII
// redaction, hierarchical permission scopes.
//
//   A3 → server card served via resources (no new tool)
//   A4 → tested via AllToolsReturnStructuredContent
//   A6 → permission scope hidden plumbing (grants get allowSubDelegation)
//   B1 → ground
//   B2 → ax_tree_augmented
//   B3 → ax_snapshot_capture + ax_snapshot_diff
//   F1 → audit_log_append + audit_log_read
//   F3 → agent_memory_store + agent_memory_recall
//   F4 → redact_pii_text
//   F5 → redact_image_regions

extension ToolRegistry {
    static let definitionsV2Phase9: [MCPToolDefinition] = [

        // MARK: B — grounding + AX augmentation

        MCPToolDefinition(
            name: "ground",
            description: """
                Mixture-of-grounding: find screen coordinates for a target text.
                Strategy: 'ax' (fastest, structured), 'ocr' (works on any app \
                including Electron/Canvas), 'auto' (AX first, OCR fallback). \
                Returns (x,y) with confidence 0..1 + candidate list.
                """,
            inputSchema: schema(
                properties: [
                    "target": .object(["type": .string("string")]),
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "strategy": .object([
                        "type": .string("string"),
                        "description": .string("ax | ocr | auto (default auto)")
                    ])
                ],
                required: ["target", "pid"]
            )
        ),
        MCPToolDefinition(
            name: "ax_tree_augmented",
            description: """
                AX tree walk augmented with OCR-derived labels for unlabeled \
                elements. ONE OCR pass + geometric join (not per-node OCR). \
                Useful for Electron/Chromium/Canvas apps where native AX is sparse.
                """,
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "max_depth": .object(["type": .array([.string("integer"), .string("string")])])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "ax_snapshot_capture",
            description: """
                Capture the current AX tree of a process into a named snapshot \
                for later diffing. Returns snapshot_id. LRU queue of 16.
                """,
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "max_depth": .object(["type": .array([.string("integer"), .string("string")])])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "ax_snapshot_diff",
            description: """
                Diff two previously-captured AX snapshots. Returns added / \
                removed / changed node lists. Lets agents observe UI change \
                after an action without re-screenshoting.
                """,
            inputSchema: schema(
                properties: [
                    "from": .object(["type": .string("string")]),
                    "to": .object(["type": .string("string")])
                ],
                required: ["from", "to"]
            )
        ),

        // MARK: F — audit, memory, redaction

        MCPToolDefinition(
            name: "audit_log_append",
            description: """
                Append a structured entry to the audit log at \
                ~/.mac-control-mcp/audit.jsonl. Use for recording \
                tool calls, grants, revocations, or custom events.
                """,
            inputSchema: schema(
                properties: [
                    "event": .object(["type": .string("string")]),
                    "tool": .object(["type": .string("string")]),
                    "bundle_id": .object(["type": .string("string")]),
                    "result": .object(["type": .string("string")]),
                    "metadata": .object([:])
                ],
                required: ["event"]
            )
        ),
        MCPToolDefinition(
            name: "audit_log_read",
            description: """
                Read entries from the audit log with optional since/filter. \
                Returns newest-first up to limit (default 500, max capped).
                """,
            inputSchema: schema(
                properties: [
                    "since_iso": .object(["type": .string("string")]),
                    "filter_tool": .object(["type": .string("string")]),
                    "filter_event": .object(["type": .string("string")]),
                    "limit": .object(["type": .array([.string("integer"), .string("string")])])
                ]
            )
        ),
        MCPToolDefinition(
            name: "agent_memory_store",
            description: """
                Store a key/value memory entry with optional tags (A-Mem pattern). \
                Persisted to ~/.mac-control-mcp/memory.jsonl. Multiple entries \
                with same key coexist; recall returns freshest first.
                """,
            inputSchema: schema(
                properties: [
                    "key": .object(["type": .string("string")]),
                    "value": .object(["type": .string("string")]),
                    "tags": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ])
                ],
                required: ["key", "value"]
            )
        ),
        MCPToolDefinition(
            name: "agent_memory_recall",
            description: """
                Recall memory entries by substring + optional tag. Case-insensitive. \
                Returns freshest first.
                """,
            inputSchema: schema(
                properties: [
                    "query": .object(["type": .string("string")]),
                    "tag": .object(["type": .string("string")]),
                    "limit": .object(["type": .array([.string("integer"), .string("string")])])
                ],
                required: ["query"]
            )
        ),
        MCPToolDefinition(
            name: "redact_pii_text",
            description: """
                Replace PII patterns with [REDACTED:<category>]. Categories: \
                email, phone, ssn, creditCard (Luhn-validated), apiKey (AWS/Stripe/\
                GitHub/Anthropic/OpenAI/JWT).
                """,
            inputSchema: schema(
                properties: [
                    "text": .object(["type": .string("string")]),
                    "categories": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ])
                ],
                required: ["text"]
            )
        ),
        MCPToolDefinition(
            name: "redact_image_regions",
            description: """
                Blur or black-out rectangular regions in an image. \
                regions: list of {x, y, width, height} in CG coordinates (top-left). \
                mode: 'blur' (pixelate) or 'black' (solid fill). \
                Output written to source-redacted.png next to source, or explicit output_path.
                """,
            inputSchema: schema(
                properties: [
                    "path": .object(["type": .string("string")]),
                    "regions": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "x": .object(["type": .string("number")]),
                                "y": .object(["type": .string("number")]),
                                "width": .object(["type": .string("number")]),
                                "height": .object(["type": .string("number")])
                            ])
                        ])
                    ]),
                    "mode": .object(["type": .string("string")]),
                    "output_path": .object(["type": .string("string")])
                ],
                required: ["path", "regions"]
            )
        )
    ]

    // MARK: - Handlers

    // MARK: B1/B2/B3

    func callGround(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let target = arguments["target"]?.stringValue, !target.isEmpty else {
            return invalidArgument("ground requires 'target'.")
        }
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("ground requires a positive integer 'pid'.")
        }
        let stratRaw = arguments["strategy"]?.stringValue?.lowercased() ?? "auto"
        let strategy: GroundingController.Strategy
        switch stratRaw {
        case "ax":   strategy = .ax
        case "ocr":  strategy = .ocr
        default:     strategy = .auto
        }
        let r = await grounding.ground(target: target, pid: pid, strategy: strategy)
        return r.ok
            ? successResult("grounded at (\(Int(r.x ?? 0)),\(Int(r.y ?? 0))) via \(r.strategyUsed)",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "ground failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callAXTreeAugmented(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("ax_tree_augmented requires a positive integer 'pid'.")
        }
        let maxDepth = max(1, min(arguments["max_depth"]?.intValue ?? 12, 32))
        let r = await grounding.axTreeAugmented(pid: pid, maxDepth: maxDepth)
        return r.ok
            ? successResult("augmented tree: \(r.nodeCount) nodes, \(r.inferredCount) inferred in \(r.elapsedMs)ms",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "ax_tree_augmented failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callAXSnapshotCapture(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("ax_snapshot_capture requires a positive integer 'pid'.")
        }
        let maxDepth = max(1, min(arguments["max_depth"]?.intValue ?? 12, 32))
        let r = await axSnapshot.capture(pid: pid, maxDepth: maxDepth)
        return successResult("snapshot \(r.snapshotID) captured, \(r.nodeCount) nodes",
                             ["ok": .bool(true), "result": encodeAsJSONValue(r)])
    }

    func callAXSnapshotDiff(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let from = arguments["from"]?.stringValue, !from.isEmpty,
              let to = arguments["to"]?.stringValue, !to.isEmpty else {
            return invalidArgument("ax_snapshot_diff requires 'from' and 'to' snapshot ids.")
        }
        guard let diff = await axSnapshot.diff(from: from, to: to) else {
            return errorResult("one or both snapshot ids not found",
                               ["ok": .bool(false), "from": .string(from), "to": .string(to)])
        }
        return successResult(
            "diff: +\(diff.added.count) -\(diff.removed.count) ~\(diff.changed.count)",
            ["ok": .bool(true), "diff": encodeAsJSONValue(diff)]
        )
    }

    // MARK: F1

    func callAuditLogAppend(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let event = arguments["event"]?.stringValue, !event.isEmpty else {
            return invalidArgument("audit_log_append requires 'event'.")
        }
        await audit.append(
            event: event,
            tool: arguments["tool"]?.stringValue,
            bundleId: arguments["bundle_id"]?.stringValue,
            tier: nil,
            result: arguments["result"]?.stringValue,
            metadata: nil // v0.6.0: simple string payloads; extend later
        )
        return successResult("audit entry appended",
                             ["ok": .bool(true), "event": .string(event)])
    }

    func callAuditLogRead(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let since = arguments["since_iso"]?.stringValue.flatMap { formatter.date(from: $0) }
        let filterTool = arguments["filter_tool"]?.stringValue
        let filterEvent = arguments["filter_event"]?.stringValue
        let limit = arguments["limit"]?.intValue ?? 500
        let entries = await audit.read(
            since: since,
            filterTool: filterTool,
            filterEvent: filterEvent,
            limit: max(1, min(limit, 5000))
        )
        return successResult(
            "found \(entries.count) audit entries",
            ["ok": .bool(true), "count": .number(Double(entries.count)),
             "entries": encodeAsJSONValue(entries)]
        )
    }

    // MARK: F3

    func callAgentMemoryStore(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let key = arguments["key"]?.stringValue, !key.isEmpty,
              let value = arguments["value"]?.stringValue else {
            return invalidArgument("agent_memory_store requires 'key' and 'value'.")
        }
        var tags: [String] = []
        if case .array(let tagArr) = arguments["tags"] ?? .null {
            tags = tagArr.compactMap {
                if case .string(let s) = $0 { return s }
                return nil
            }
        }
        let r = await memory.store(key: key, value: value, tags: tags)
        return r.ok
            ? successResult("memory stored: \(key)",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.reason ?? "memory store failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callAgentMemoryRecall(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let query = arguments["query"]?.stringValue else {
            return invalidArgument("agent_memory_recall requires 'query'.")
        }
        let tag = arguments["tag"]?.stringValue
        let limit = arguments["limit"]?.intValue ?? 20
        let r = await memory.recall(query: query, tag: tag, limit: limit)
        return successResult(
            "recalled \(r.count) entries",
            ["ok": .bool(true), "result": encodeAsJSONValue(r)]
        )
    }

    // MARK: F4

    func callRedactPIIText(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let text = arguments["text"]?.stringValue else {
            return invalidArgument("redact_pii_text requires 'text'.")
        }
        var categories: Set<RedactionController.TextCategory>? = nil
        if case .array(let catArr) = arguments["categories"] ?? .null {
            let parsed = catArr.compactMap { v -> RedactionController.TextCategory? in
                guard case .string(let s) = v else { return nil }
                return RedactionController.TextCategory(rawValue: s)
            }
            if !parsed.isEmpty { categories = Set(parsed) }
        }
        let r = await redaction.redactText(text, categories: categories)
        return successResult(
            "redacted \(r.redactions.reduce(0) { $0 + $1.count }) PII match(es)",
            ["ok": .bool(true), "result": encodeAsJSONValue(r)]
        )
    }

    // MARK: F5

    func callRedactImageRegions(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            return invalidArgument("redact_image_regions requires 'path'.")
        }
        guard case .array(let regArr) = arguments["regions"] ?? .null else {
            return invalidArgument("redact_image_regions requires 'regions' array.")
        }
        var regions: [RedactionController.ImageRegion] = []
        for v in regArr {
            guard case .object(let obj) = v,
                  case .number(let x) = obj["x"] ?? .null,
                  case .number(let y) = obj["y"] ?? .null,
                  case .number(let w) = obj["width"] ?? .null,
                  case .number(let h) = obj["height"] ?? .null else { continue }
            regions.append(.init(x: Int(x), y: Int(y), width: Int(w), height: Int(h)))
        }
        guard !regions.isEmpty else {
            return invalidArgument("regions array had no valid entries (need x/y/width/height)")
        }
        let modeRaw = arguments["mode"]?.stringValue?.lowercased() ?? "blur"
        let mode: RedactionController.ImageMode = modeRaw == "black" ? .black : .blur
        let output = arguments["output_path"]?.stringValue
        let r = await redaction.redactImage(
            at: path, regions: regions, mode: mode, outputPath: output
        )
        return r.ok
            ? successResult("redacted \(r.redactedRegions) region(s) → \(r.outputPath ?? "?")",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "redact_image_regions failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }
}
