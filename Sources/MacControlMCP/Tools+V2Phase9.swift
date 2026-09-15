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
                Strategy: 'ax' (fastest, structured), 'ocr' (OCRs the target \
                app's own window — works on Electron/Canvas and on windows that \
                are covered by other windows), 'auto' (AX first, OCR fallback). \
                Returns (x,y) plus the match's bounds, element_id and \
                max_depth_used, matched_field (title/value/description/ocr), alternatives (up to 3 runners-up), with confidence 0..1 + candidate list.
                OCR tries fast recognition without language correction first, then accurate only if no visible target match is found. Low recognition confidence lowers the reported score without triggering another pass. Auto returns an exact AX winner (including ranked ties) or a strictly leading AX candidate without OCR.
                Pass window_id (from list_windows) to scope BOTH strategies \
                to one window: the AX search is rooted at that window's \
                Accessibility window and the OCR pass captures exactly that \
                window. window_id takes precedence — pid is then ignored. \
                With a window_id the response carries `ax_scope`: \
                "window_subtree" when AX ran inside that window, or "none" \
                when the window has NO attributable Accessibility window \
                (Chrome browser windows, parts of Electron, minimized \
                windows, or several indistinguishable AX windows) — then \
                the AX strategy is SKIPPED, `ax_skipped_reason` says why \
                ("no_ax_window" / "ambiguous_window"), and only OCR runs; \
                AX elements are never taken from an app-wide walk, because \
                they could belong to an overlapping window of the same \
                app. strategy="ax" on such a window fails with that reason \
                as error_code (plus `candidates` when ambiguous).
                """,
            inputSchema: schema(
                properties: withWindowIDProperty([
                    "target": .object(["type": .string("string")]),
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "strategy": .object([
                        "type": .string("string"),
                        "description": .string("ax | ocr | auto (default auto)")
                    ]),
                    "max_depth": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("AX search depth. Default 32 (same as find_elements), clamped 1-64.")
                    ])
                ]),
                required: ["target"]
            )
        ),
        MCPToolDefinition(
            name: "ax_tree_augmented",
            description: """
                AX tree walk augmented with OCR-derived labels for unlabeled \
                elements. ONE OCR pass over THAT APP'S OWN WINDOW + geometric \
                join (not per-node OCR, never a display-wide grab, so text from \
                an overlapping window can't be attributed to this app). \
                Useful for Electron/Chromium/Canvas apps where native AX is sparse. \
                Trimmed to max_nodes (default 300, range 50-1000) with labelled \
                elements preferred over unlabelled when truncating.
                Pass window_id (from list_windows) to scope the tree AND the OCR \
                pass to ONE window — required to get sane labels from an app \
                with several windows. window_id takes precedence over pid. \
                The response carries `ax_scope`: "window_subtree" when the \
                walk was rooted at that window's Accessibility window, \
                "app_root" when no window was requested (plain pid), or \
                "none" when the window has NO attributable Accessibility \
                window (Chrome browser windows, parts of Electron, minimized \
                windows, or several indistinguishable AX windows) — then \
                `nodes` is EMPTY, `ax_scope_reason` is "no_ax_window" or \
                "ambiguous_window" (with `candidates`) and `hint` names the \
                alternatives; nodes are never taken from an app-wide walk \
                for a targeted window.
                """,
            inputSchema: schema(
                properties: withWindowIDProperty([
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "max_depth": .object(["type": .array([.string("integer"), .string("string")])]),
                    "max_nodes": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Output cap. Default 300, clamped 50-1000.")
                    ])
                ])
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
        let scope: GroundingController.WindowScope?
        switch await windowScope(arguments, tool: "ground") {
        case .success(let resolved): scope = resolved
        case .failure(let box): return box.result
        }
        let pid: pid_t
        if let scope {
            pid = scope.pid
        } else if let parsed = parsePID(arguments["pid"]) {
            pid = parsed
        } else {
            return invalidArgument("ground requires a positive integer 'pid', or a window_id from list_windows.")
        }
        let stratRaw = arguments["strategy"]?.stringValue?.lowercased() ?? "auto"
        let strategy: GroundingController.Strategy
        switch stratRaw {
        case "ax":   strategy = .ax
        case "ocr":  strategy = .ocr
        default:     strategy = .auto
        }
        let r = await grounding.ground(target: target, pid: pid, strategy: strategy,
                                       maxDepth: arguments["max_depth"]?.intValue,
                                       window: scope)
        var payload: [String: JSONValue] = [
            "ok": .bool(r.ok),
            "result": encodeAsJSONValue(r),
            "pid": .number(Double(pid)),
            // Snake-case echoes alongside the nested camelCase result, so a
            // caller does not have to know both spellings (A-2 / A-14 / D-4).
            "max_depth_used": .number(Double(r.maxDepthUsed))
        ]
        if let scope {
            payload.merge(scope.payload) { existing, _ in existing }
            // Codex r2 #2: say whether AX really ran inside this window
            // ("window_subtree") or was withheld ("none") because the
            // window has no attributable AXWindow — and why. An agent
            // that sees "none" knows the OCR hit is all it will get and
            // should not retry with strategy="ax".
            payload["ax_scope"] = .string(scope.axScope)
            if let reason = r.axSkippedReason {
                payload["ax_skipped_reason"] = .string(reason)
            }
            if let candidates = scope.ambiguousCandidates {
                payload["candidate_count"] = .number(Double(candidates.count))
                payload["candidates"] = .array(candidates.map { .object($0.payload) })
            }
        }
        // v0.10 A5: expose the winning label's provenance and up to three runners-up.
        payload["matched_field"] = r.candidates.first?.matchedField.map(JSONValue.string) ?? .null
        payload["alternatives"] = .array(r.candidates.dropFirst().prefix(3).map { encodeAsJSONValue($0) })
        if let id = r.elementId { payload["element_id"] = .string(id) }
        if let b = r.bounds { payload["bounds"] = encodeAsJSONValue(b) }
        if let c = r.errorCode { payload["error_code"] = .string(c) }
        return r.ok
            ? successResult("grounded at (\(Int(r.x ?? 0)),\(Int(r.y ?? 0))) via \(r.strategyUsed) (max_depth_used \(r.maxDepthUsed))",
                            payload)
            : errorResult(r.error ?? "ground failed", payload)
    }

    func callAXTreeAugmented(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let scope: GroundingController.WindowScope?
        switch await windowScope(arguments, tool: "ax_tree_augmented") {
        case .success(let resolved): scope = resolved
        case .failure(let box): return box.result
        }
        let pid: pid_t
        if let scope {
            pid = scope.pid
        } else if let parsed = parsePID(arguments["pid"]) {
            pid = parsed
        } else {
            return invalidArgument(
                "ax_tree_augmented requires a positive integer 'pid', or a window_id from list_windows."
            )
        }
        let maxDepth = max(1, min(arguments["max_depth"]?.intValue ?? 12, 32))
        // v0.7.1: expose the maxNodes cap to callers; clamp 50..1000.
        let maxNodes = max(50, min(arguments["max_nodes"]?.intValue ?? 300, 1000))
        let r = await grounding.axTreeAugmented(pid: pid, maxDepth: maxDepth, maxNodes: maxNodes, window: scope)
        var payload: [String: JSONValue] = [
            "ok": .bool(r.ok),
            "result": encodeAsJSONValue(r),
            "max_depth_used": .number(Double(r.maxDepthUsed)),
            // Codex r2 #2: which AX tree the nodes come from (see
            // `withheldAugmentedFields` for the withheld shape).
            "ax_scope": .string(r.axScope)
        ]
        if let scope { payload.merge(scope.payload) { existing, _ in existing } }
        if let scope, let reasonRaw = r.axScopeReason,
           let reason = AXScopePolicy.WithheldReason(rawValue: reasonRaw) {
            payload.merge(Self.withheldAugmentedFields(
                reason: reason, windowID: scope.windowID, ownerName: scope.ownerName,
                candidates: scope.ambiguousCandidates
            )) { _, new in new }
        }
        if let c = r.errorCode { payload["error_code"] = .string(c) }
        return r.ok
            ? successResult("augmented tree: \(r.nodeCount) nodes, \(r.inferredCount) inferred in \(r.elapsedMs)ms",
                            payload)
            : errorResult(r.error ?? "ax_tree_augmented failed", payload)
    }

    /// Codex r2 #2: the top-level fields `ax_tree_augmented` reports when
    /// a targeted window has no attributable AXWindow. Pure, so the shape
    /// is unit-tested without a live window.
    static func withheldAugmentedFields(
        reason: AXScopePolicy.WithheldReason,
        windowID: CGWindowID?,
        ownerName: String,
        candidates: [WindowTargeting.Candidate]?
    ) -> [String: JSONValue] {
        var fields: [String: JSONValue] = [
            "nodes": .array([]),
            "node_count": .number(0),
            "ax_scope": .string(AXScopePolicy.Decision.withheld(reason).axScope),
            "ax_scope_reason": .string(reason.rawValue),
            "hint": .string(AXScopePolicy.withheldHint(
                tool: "ax_tree_augmented", reason: reason, windowID: windowID, ownerName: ownerName
            ))
        ]
        if let candidates {
            fields["candidate_count"] = .number(Double(candidates.count))
            fields["candidates"] = .array(candidates.map { .object($0.payload) })
        }
        return fields
    }

    func callAXSnapshotCapture(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("ax_snapshot_capture requires a positive integer 'pid'.")
        }
        let maxDepth = max(1, min(arguments["max_depth"]?.intValue ?? 12, 32))
        let r = await axSnapshot.capture(pid: pid, maxDepth: maxDepth)
        // 0 nodes means the AX root itself was unreadable (missing
        // Accessibility permission or a dead/UI-less pid) — every app has at
        // least a root + window. Reporting success here produced garbage
        // snapshots and false "no changes" diffs.
        guard r.nodeCount > 0 else {
            return errorResult(
                "ax_snapshot_capture read 0 nodes for pid \(pid); the AX tree is unreadable (grant Accessibility permission, or the process has no UI).",
                ["ok": .bool(false), "pid": .number(Double(pid)), "node_count": .number(0)]
            )
        }
        // A-14: echo the id in snake_case at the top level too. The nested
        // `result.snapshotID` is camelCase while docs/TOOLS.md and every
        // other tool argument are snake_case, which made scripted chaining
        // into ax_snapshot_diff pass null.
        return successResult("snapshot \(r.snapshotID) captured, \(r.nodeCount) nodes",
                             ["ok": .bool(true),
                              "snapshot_id": .string(r.snapshotID),
                              "node_count": .number(Double(r.nodeCount)),
                              "result": encodeAsJSONValue(r)])
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
            metadata: arguments["metadata"]?.objectValue
        )
        return successResult("audit entry appended",
                             ["ok": .bool(true), "event": .string(event)])
    }

    func callAuditLogRead(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        // Parse since_iso tolerantly: standard ISO-8601 without fractional
        // seconds (e.g. "2026-07-06T10:00:00Z") must still work. The old
        // formatter required fractional seconds, so those inputs silently
        // parsed to nil and the since filter was dropped entirely.
        func parseISO(_ s: String) -> Date? {
            let withFrac = ISO8601DateFormatter()
            withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = withFrac.date(from: s) { return d }
            let plain = ISO8601DateFormatter()
            plain.formatOptions = [.withInternetDateTime]
            return plain.date(from: s)
        }
        let since = arguments["since_iso"]?.stringValue.flatMap(parseISO)
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
                  case .number(let h) = obj["height"] ?? .null,
                  // Reject out-of-Int-range coordinates (Int(Double) traps on
                  // e.g. 1e300); skip the malformed region rather than crash.
                  let ix = Int(exactly: x.rounded()), let iy = Int(exactly: y.rounded()),
                  let iw = Int(exactly: w.rounded()), let ih = Int(exactly: h.rounded())
            else { continue }
            regions.append(.init(x: ix, y: iy, width: iw, height: ih))
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
