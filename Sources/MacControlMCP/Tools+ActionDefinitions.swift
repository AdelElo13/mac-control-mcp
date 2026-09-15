import Foundation

// v0.10 C1/C3/C4/C8: schemas are shared so act.verify accepts the same
// conditions, targets and bounds as a standalone wait_for.
extension ToolRegistry {
    static let waitProperties: [String: JSONValue] = [
        "element_id": .object(["type": .string("string"), "description": .string("Live cached element ID; expired/unknown IDs are errors, not disappearance.")]),
        "pid": .object(["type": .array([.string("integer"), .string("string")])]),
        "role": .object(["type": .string("string")]),
        "title": .object(["type": .string("string"), "description": .string("Selector title; expected substring for title_contains.")]),
        "value": .object(["type": .string("string"), "description": .string("Selector value; expected text for value_equals/value_contains (case-sensitive).")]),
        "exact": .object(["type": .string("boolean"), "default": .bool(false)]),
        "window_id": .object(["type": .array([.string("integer"), .string("string")])]),
        "condition": .object(["type": .string("string"), "enum": .array(ConditionWait.Condition.allCases.map { .string($0.rawValue) })]),
        "timeout_seconds": .object(["type": .string("number"), "minimum": .number(0), "maximum": .number(60), "default": .number(5)]),
        "poll_interval_ms": .object(["type": .string("integer"), "minimum": .number(50), "maximum": .number(60000), "default": .number(200)])
    ]

    static let definitionsActions: [MCPToolDefinition] = [
        MCPToolDefinition(name: "wait_for", description: "Wait for an element or window condition. Supply exactly one target: element_id, window_id, or pid plus role/title/value. Conditions: appears, disappears, enabled, disabled, focused, value_equals, value_contains, title_contains. Missing attributes do not match disabled or empty values. Returns verified, matched element/window, attempts and elapsed_ms. timeout_seconds is 0...60; 0 checks once. Unknown/expired IDs and identity mismatches fail honestly. Existing wait_for_element and wait_for_window remain compatible wrappers.", inputSchema: schema(properties: waitProperties, required: ["condition"])),
        MCPToolDefinition(name: "act", description: "Resolve one target, act and verify in one round trip using the individual tools' code paths. target is an element_id or {pid,role,title,exact}; ambiguous selectors fail. action is press/click/double_click/right_click/set_value/focus/type/key, either a string with sibling value/text/key/modifiers, or {type: action, ...parameters}. press requires AXPress; click can use the visible center. verify uses wait_for conditions and bounds; by default it observes the acted-on element, or supply another wait_for target (e.g. pid+role AXSheet). Returns acted, verified (true/false/null), verification reason, before, after and element. Null means verification unavailable, never success. Secure fields are refused for editing. Owner focus guards and explicit expectations apply to all act actions.", inputSchema: schema(properties: [
            "target": .object(["oneOf": .array([
                .object(["type": .string("string")]),
                schema(properties: ["pid": waitProperties["pid"]!, "role": waitProperties["role"]!, "title": waitProperties["title"]!, "exact": waitProperties["exact"]!], required: ["pid"])
            ])]),
            "action": .object(["oneOf": .array([
                .object(["type": .string("string"), "enum": .array(["press", "click", "double_click", "right_click", "set_value", "focus", "type", "key"].map(JSONValue.string))]),
                schema(properties: ["type": .object(["type": .string("string")]), "text": .object(["type": .string("string")]), "value": .object(["type": .array([.string("string"), .string("number"), .string("boolean")])]), "key": .object(["type": .string("string")]), "modifiers": .object(["type": .string("array"), "items": .object(["type": .string("string")])])], required: ["type"])
            ])]),
            "verify": schema(properties: waitProperties, required: ["condition"]),
            "value": .object(["type": .array([.string("string"), .string("number"), .string("boolean")])]),
            "text": .object(["type": .string("string")]), "key": .object(["type": .string("string")]),
            "strategy": .object(["type": .string("string"), "enum": .array(["auto", "clipboard", "keys", "ax"].map(JSONValue.string))]),
            "modifiers": .object(["type": .string("array"), "items": .object(["type": .string("string")])]),
            "expected_app": .object(["type": .string("string")]), "expected_window": .object(["type": .string("string")])
        ], required: ["target", "action", "verify"]))
    ]
}
