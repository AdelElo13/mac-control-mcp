import Foundation
import ApplicationServices

// v0.9 workstream E — text editing primitives (gap-audit C-7), built on the
// typed AX layer from TextEditingController (gap-audit B-15).
//
// Six tools, all addressing one AX text element either by `element_id` (an
// id handed out by find_elements/query_elements/get_ui_tree) or by `pid`
// (the app's currently focused element — no focus stealing, we only read
// which element that app already considers focused):
//
//   text_get_selection   — selected text + typed range + counts + visible range
//   text_get_caret       — caret index, line, and on-screen bounds
//   text_set_selection   — move/extend the selection
//   text_insert_at_caret — insert without disturbing the rest of the text
//   text_replace_range   — replace an exact character range
//   text_get_value       — the whole value, with an explicit truncation flag
//
// Writes go through AXSelectedText on the element handle: no synthetic
// keystrokes, no clipboard, no select-all-and-retype.

/// A step that either produced a value or already has the error result the
/// tool should return. `Result` can't be used here: ToolCallResult is not an
/// `Error` (it is a successful MCP response that happens to carry isError).
enum TextStep<Value> {
    case ok(Value)
    case failed(ToolCallResult)
}

extension ToolRegistry {

    static let definitionsTextEditing: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "text_get_selection",
            description: "Read the selection state of an AX text element: selected text, the selected range as TYPED {location,length} (not the stringified \"range(2115,0)\" get_element_attributes returns), total character count, visible character range and the insertion-point line. "
                + "Target it with element_id, or with pid to use that app's currently focused element. Read-only; does not change focus.",
            inputSchema: schema(
                properties: [
                    "element_id": .object([
                        "type": .string("string"),
                        "description": .string("Element id from find_elements / query_elements / get_ui_tree.")
                    ]),
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Use the focused element of this app instead of an element_id.")
                    ])
                ]
            )
        ),
        MCPToolDefinition(
            name: "text_get_caret",
            description: "Caret position of an AX text element: character index, line number, and on-screen bounds via the AXBoundsForRange parameterized attribute (useful to scroll to or click at the caret). "
                + "Target it with element_id or pid (focused element). Read-only.",
            inputSchema: schema(
                properties: [
                    "element_id": .object([
                        "type": .string("string"),
                        "description": .string("Element id from find_elements / query_elements / get_ui_tree.")
                    ]),
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Use the focused element of this app instead of an element_id.")
                    ])
                ]
            )
        ),
        MCPToolDefinition(
            name: "text_set_selection",
            description: "Set the selection (or collapsed caret, length=0) of an AX text element via AXSelectedTextRange. Validated against AXNumberOfCharacters before writing. "
                + "Does not type anything and does not steal focus.",
            inputSchema: schema(
                properties: [
                    "element_id": .object([
                        "type": .string("string"),
                        "description": .string("Element id from find_elements / query_elements / get_ui_tree.")
                    ]),
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Use the focused element of this app instead of an element_id.")
                    ]),
                    "location": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("0-based character index where the selection starts.")
                    ]),
                    "length": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Number of characters selected; 0 for a plain caret.")
                    ])
                ],
                required: ["location", "length"]
            )
        ),
        MCPToolDefinition(
            name: "text_insert_at_caret",
            description: "Insert text at the caret of an AX text element by writing AXSelectedText — surrounding text is untouched and no synthetic keystrokes are posted. "
                + "A non-empty selection is collapsed to its end first (use text_replace_range to overwrite a selection). "
                + "Elements that expose AXSelectedText read-only return error_code=not_supported with a pointer at type_text.",
            inputSchema: schema(
                properties: [
                    "element_id": .object([
                        "type": .string("string"),
                        "description": .string("Element id from find_elements / query_elements / get_ui_tree.")
                    ]),
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Use the focused element of this app instead of an element_id.")
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Text to insert at the caret.")
                    ])
                ],
                required: ["text"]
            )
        ),
        MCPToolDefinition(
            name: "text_replace_range",
            description: "Replace an exact character range of an AX text element: sets AXSelectedTextRange to {location,length}, then writes AXSelectedText. "
                + "Pass an empty string to delete the range. Elements that reject the write return error_code=not_supported.",
            inputSchema: schema(
                properties: [
                    "element_id": .object([
                        "type": .string("string"),
                        "description": .string("Element id from find_elements / query_elements / get_ui_tree.")
                    ]),
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Use the focused element of this app instead of an element_id.")
                    ]),
                    "location": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("0-based character index where the replaced range starts.")
                    ]),
                    "length": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Number of characters to replace; 0 inserts at that index.")
                    ]),
                    "text": .object([
                        "type": .string("string"),
                        "description": .string("Replacement text; empty string deletes the range.")
                    ])
                ],
                required: ["location", "length", "text"]
            )
        ),
        MCPToolDefinition(
            name: "text_get_value",
            description: "Read the full AXValue of a text element with number_of_characters and an explicit `truncated` flag when max_chars cuts it short. "
                + "Use it to verify an edit instead of re-reading the whole UI tree.",
            inputSchema: schema(
                properties: [
                    "element_id": .object([
                        "type": .string("string"),
                        "description": .string("Element id from find_elements / query_elements / get_ui_tree.")
                    ]),
                    "pid": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Use the focused element of this app instead of an element_id.")
                    ]),
                    "max_chars": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Cap the returned text at this many characters (must be > 0). Omit for the whole value.")
                    ])
                ]
            )
        )
    ]

    // MARK: - Target resolution

    /// How a tool call addressed its element — echoed back so an agent can
    /// see which element it actually edited.
    private struct TextTarget {
        let element: AXUIElement
        let source: String       // "element_id" | "focused_element"
        let identity: [String: JSONValue]
    }

    private func resolveTextTarget(
        _ arguments: [String: JSONValue], tool: String
    ) async -> TextStep<TextTarget> {
        if let raw = arguments["element_id"], raw != .null {
            guard let id = raw.stringValue, !id.isEmpty else {
                return .failed(textArgumentError(tool, "element_id must be a non-empty string."))
            }
            guard let element = await elementCache.resolve(id) else {
                return .failed(textFailureResult(
                    tool,
                    .notFound,
                    extra: ["element_id": .string(id)]
                ))
            }
            return .ok(TextTarget(
                element: element, source: "element_id", identity: ["element_id": .string(id)]
            ))
        }

        guard let rawPID = arguments["pid"], rawPID != .null else {
            return .failed(textArgumentError(tool, "\(tool) requires element_id or pid."))
        }
        guard let pid = parsePID(rawPID) else {
            return .failed(textArgumentError(tool, "pid must be a positive integer."))
        }
        guard isRunningProcess(pid) else {
            return .failed(textFailureResult(
                tool, .notFound, extra: ["pid": .number(Double(pid))]
            ))
        }
        do {
            let element = try await textEditing.focusedElement(pid: pid)
            return .ok(TextTarget(
                element: element, source: "focused_element", identity: ["pid": .number(Double(pid))]
            ))
        } catch {
            return .failed(textFailureResult(tool, error, extra: ["pid": .number(Double(pid))]))
        }
    }

    private func textArgumentError(_ tool: String, _ message: String) -> ToolCallResult {
        errorResult(
            "\(tool): \(message)",
            [
                "ok": .bool(false),
                "error_code": .string("invalid_argument"),
                "error": .string(message)
            ]
        )
    }

    private func textFailureResult(
        _ tool: String,
        _ failure: TextEditingController.Failure,
        extra: [String: JSONValue] = [:]
    ) -> ToolCallResult {
        var payload: [String: JSONValue] = [
            "ok": .bool(false),
            "error_code": .string(failure.code),
            "error": .string(failure.message)
        ]
        if let hint = failure.hint { payload["hint"] = .string(hint) }
        payload.merge(extra) { current, _ in current }
        return errorResult("\(tool): \(failure.message)", payload)
    }

    private static func rangePayload(_ range: TextEditingController.TextRange) -> JSONValue {
        .object([
            "location": .number(Double(range.location)),
            "length": .number(Double(range.length))
        ])
    }

    /// Parse a required integer argument that may arrive as a number or a
    /// numeric string (Claude Desktop stringifies numbers in some clients).
    private func requiredInt(
        _ arguments: [String: JSONValue], _ key: String, tool: String
    ) -> TextStep<Int> {
        guard let raw = arguments[key], raw != .null else {
            return .failed(textArgumentError(tool, "\(tool) requires \(key)."))
        }
        if let intValue = raw.intValue { return .ok(intValue) }
        if let string = raw.stringValue, let parsed = Int(string) { return .ok(parsed) }
        return .failed(textArgumentError(tool, "\(key) must be an integer."))
    }

    // MARK: - text_get_selection

    func callTextGetSelection(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let tool = "text_get_selection"
        let target: TextTarget
        switch await resolveTextTarget(arguments, tool: tool) {
        case .failed(let error): return error
        case .ok(let value): target = value
        }
        do {
            let selection = try await textEditing.selection(of: target.element)
            var payload: [String: JSONValue] = [
                "ok": .bool(true),
                "source": .string(target.source),
                "text": selection.text.map(JSONValue.string) ?? .null,
                "range": selection.range.map(Self.rangePayload) ?? .null,
                "number_of_characters": selection.numberOfCharacters.map { .number(Double($0)) } ?? .null,
                "visible_range": selection.visibleRange.map(Self.rangePayload) ?? .null,
                "insertion_point_line": selection.insertionPointLine.map { .number(Double($0)) } ?? .null
            ]
            payload.merge(target.identity) { current, _ in current }
            let described = selection.range.map { "\($0.location)+\($0.length)" } ?? "unknown"
            return successResult("Selection range \(described).", payload)
        } catch {
            return textFailureResult(tool, error, extra: target.identity)
        }
    }

    // MARK: - text_get_caret

    func callTextGetCaret(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let tool = "text_get_caret"
        let target: TextTarget
        switch await resolveTextTarget(arguments, tool: tool) {
        case .failed(let error): return error
        case .ok(let value): target = value
        }
        do {
            let caret = try await textEditing.caret(of: target.element)
            var payload: [String: JSONValue] = [
                "ok": .bool(true),
                "source": .string(target.source),
                "caret": .number(Double(caret.index)),
                "line": caret.line.map { .number(Double($0)) } ?? .null,
                "selection_length": .number(Double(caret.selectionLength)),
                "bounds_range_length": .number(Double(caret.boundsRangeLength)),
                "bounds": caret.bounds.map { bounds in
                    .object([
                        "x": .number(bounds.x),
                        "y": .number(bounds.y),
                        "width": .number(bounds.width),
                        "height": .number(bounds.height)
                    ])
                } ?? .null
            ]
            payload.merge(target.identity) { current, _ in current }
            return successResult("Caret at character \(caret.index).", payload)
        } catch {
            return textFailureResult(tool, error, extra: target.identity)
        }
    }

    // MARK: - text_set_selection

    func callTextSetSelection(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let tool = "text_set_selection"
        let location: Int
        switch requiredInt(arguments, "location", tool: tool) {
        case .failed(let error): return error
        case .ok(let value): location = value
        }
        let length: Int
        switch requiredInt(arguments, "length", tool: tool) {
        case .failed(let error): return error
        case .ok(let value): length = value
        }
        // Sign errors are argument errors regardless of the element — check
        // them before we touch AX so a bad call fails the same way every time.
        if let reason = TextEditingController.validateRange(
            location: location, length: length, numberOfCharacters: nil
        ) {
            return textArgumentError(tool, reason)
        }

        let target: TextTarget
        switch await resolveTextTarget(arguments, tool: tool) {
        case .failed(let error): return error
        case .ok(let value): target = value
        }
        do {
            let range = try await textEditing.setSelection(
                of: target.element, location: location, length: length
            )
            var payload: [String: JSONValue] = [
                "ok": .bool(true),
                "source": .string(target.source),
                "range": Self.rangePayload(range)
            ]
            payload.merge(target.identity) { current, _ in current }
            return successResult("Selection set to \(location)+\(length).", payload)
        } catch {
            return textFailureResult(tool, error, extra: target.identity)
        }
    }

    // MARK: - text_insert_at_caret

    func callTextInsertAtCaret(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let tool = "text_insert_at_caret"
        guard let raw = arguments["text"], raw != .null, let text = raw.stringValue else {
            return textArgumentError(tool, "\(tool) requires text (a string).")
        }
        let target: TextTarget
        switch await resolveTextTarget(arguments, tool: tool) {
        case .failed(let error): return error
        case .ok(let value): target = value
        }
        do {
            let outcome = try await textEditing.insertAtCaret(of: target.element, text: text)
            var payload = Self.writePayload(outcome, source: target.source)
            payload.merge(target.identity) { current, _ in current }
            return successResult(
                "Inserted \(outcome.insertedCharacters) character(s) at \(outcome.range.location).",
                payload
            )
        } catch {
            return textFailureResult(tool, error, extra: target.identity)
        }
    }

    // MARK: - text_replace_range

    func callTextReplaceRange(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let tool = "text_replace_range"
        guard let rawText = arguments["text"], rawText != .null, let text = rawText.stringValue else {
            return textArgumentError(tool, "\(tool) requires text (a string; empty deletes the range).")
        }
        let location: Int
        switch requiredInt(arguments, "location", tool: tool) {
        case .failed(let error): return error
        case .ok(let value): location = value
        }
        let length: Int
        switch requiredInt(arguments, "length", tool: tool) {
        case .failed(let error): return error
        case .ok(let value): length = value
        }
        if let reason = TextEditingController.validateRange(
            location: location, length: length, numberOfCharacters: nil
        ) {
            return textArgumentError(tool, reason)
        }

        let target: TextTarget
        switch await resolveTextTarget(arguments, tool: tool) {
        case .failed(let error): return error
        case .ok(let value): target = value
        }
        do {
            let outcome = try await textEditing.replaceRange(
                of: target.element, location: location, length: length, text: text
            )
            var payload = Self.writePayload(outcome, source: target.source)
            payload.merge(target.identity) { current, _ in current }
            return successResult(
                "Replaced \(length) character(s) at \(location) with \(outcome.insertedCharacters).",
                payload
            )
        } catch {
            return textFailureResult(tool, error, extra: target.identity)
        }
    }

    private static func writePayload(
        _ outcome: TextEditingController.WriteOutcome, source: String
    ) -> [String: JSONValue] {
        [
            "ok": .bool(true),
            "source": .string(source),
            "range": rangePayload(outcome.range),
            "inserted_characters": .number(Double(outcome.insertedCharacters)),
            "collapsed_selection": .bool(outcome.collapsedSelection),
            "selection_after": outcome.selectionAfter.map(rangePayload) ?? .null
        ]
    }

    // MARK: - text_get_value

    func callTextGetValue(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let tool = "text_get_value"
        var maxChars: Int?
        if let raw = arguments["max_chars"], raw != .null {
            guard let parsed = raw.intValue ?? raw.stringValue.flatMap(Int.init) else {
                return textArgumentError(tool, "max_chars must be an integer.")
            }
            guard parsed > 0 else {
                return textArgumentError(tool, "max_chars must be > 0 (got \(parsed)).")
            }
            maxChars = parsed
        }

        let target: TextTarget
        switch await resolveTextTarget(arguments, tool: tool) {
        case .failed(let error): return error
        case .ok(let value): target = value
        }
        do {
            let value = try await textEditing.value(of: target.element, maxChars: maxChars)
            var payload: [String: JSONValue] = [
                "ok": .bool(true),
                "source": .string(target.source),
                "value": .string(value.text),
                "number_of_characters": value.numberOfCharacters.map { .number(Double($0)) } ?? .null,
                "truncated": .bool(value.truncated)
            ]
            payload.merge(target.identity) { current, _ in current }
            return successResult(
                "Read \(value.text.count) character(s)\(value.truncated ? " (truncated)" : "").",
                payload
            )
        } catch {
            return textFailureResult(tool, error, extra: target.identity)
        }
    }
}
