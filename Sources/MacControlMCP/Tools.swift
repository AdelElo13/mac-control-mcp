import Foundation
import CoreGraphics

struct ToolCallResult: Sendable {
    let text: String
    let structuredContent: JSONValue
    let isError: Bool

    func asMCPResult() -> JSONValue {
        var result: [String: JSONValue] = [
            "content": .array([
                .object([
                    "type": .string("text"),
                    "text": .string(text)
                ])
            ]),
            "structuredContent": structuredContent
        ]

        if isError {
            result["isError"] = .bool(true)
        }

        return .object(result)
    }
}

final class ToolRegistry {
    let accessibility: AccessibilityController

    init(accessibility: AccessibilityController) {
        self.accessibility = accessibility
    }

    var toolDefinitions: [MCPToolDefinition] {
        Self.definitions
    }

    func callTool(name: String, arguments: [String: JSONValue]) async -> ToolCallResult {
        switch name {
        case "list_elements":
            return await callListElements(arguments)
        case "find_element":
            return await callFindElement(arguments)
        case "click":
            return await callClick(arguments)
        case "type_text":
            return await callTypeText(arguments)
        case "read_value":
            return await callReadValue(arguments)
        case "press_key":
            return await callPressKey(arguments)
        case "focused_app":
            return await callFocusedApp()
        case "list_apps":
            return await callListApps()
        default:
            return errorResult("Unknown tool '\(name)'.")
        }
    }

    private func callListElements(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("list_elements requires a positive integer pid.")
        }

        let maxDepth = max(1, min(arguments["max_depth"]?.intValue ?? 8, 32))
        let elements = await accessibility.listElements(pid: pid, maxDepth: maxDepth)

        return successResult(
            "Found \(elements.count) actionable elements.",
            [
                "ok": .bool(true),
                "pid": .number(Double(pid)),
                "max_depth": .number(Double(maxDepth)),
                "count": .number(Double(elements.count)),
                "elements": encodeAsJSONValue(elements)
            ]
        )
    }

    private func callFindElement(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("find_element requires a positive integer pid.")
        }

        let role = arguments["role"]?.stringValue
        let title = arguments["title"]?.stringValue

        guard let element = await accessibility.findElement(pid: pid, role: role, title: title) else {
            return errorResult(
                "No matching element found.",
                [
                    "ok": .bool(false),
                    "pid": .number(Double(pid)),
                    "role": role.map(JSONValue.string) ?? .null,
                    "title": title.map(JSONValue.string) ?? .null
                ]
            )
        }

        let info = await accessibility.getElementInfo(element: element)
        return successResult(
            "Element found.",
            [
                "ok": .bool(true),
                "pid": .number(Double(pid)),
                "element": encodeAsJSONValue(info)
            ]
        )
    }

    private func callClick(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("click requires a positive integer pid.")
        }

        if let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue {
            let success = await accessibility.click(at: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            if success {
                return successResult(
                    "Clicked at (\(x), \(y)).",
                    [
                        "ok": .bool(true),
                        "pid": .number(Double(pid)),
                        "x": .number(x),
                        "y": .number(y)
                    ]
                )
            }

            return errorResult(
                "Failed to click at (\(x), \(y)).",
                [
                    "ok": .bool(false),
                    "pid": .number(Double(pid)),
                    "x": .number(x),
                    "y": .number(y)
                ]
            )
        }

        guard arguments["x"] == nil, arguments["y"] == nil else {
            return invalidArgument("click requires both x and y when using coordinates.")
        }

        let role = arguments["role"]?.stringValue
        let title = arguments["title"]?.stringValue

        guard role != nil || title != nil else {
            return invalidArgument("click requires role/title or x/y.")
        }

        guard let element = await accessibility.findElement(pid: pid, role: role, title: title) else {
            return errorResult(
                "No matching element to click.",
                [
                    "ok": .bool(false),
                    "pid": .number(Double(pid)),
                    "role": role.map(JSONValue.string) ?? .null,
                    "title": title.map(JSONValue.string) ?? .null
                ]
            )
        }

        let success = await accessibility.clickElement(element: element)
        if success {
            return successResult(
                "Element clicked.",
                [
                    "ok": .bool(true),
                    "pid": .number(Double(pid)),
                    "role": role.map(JSONValue.string) ?? .null,
                    "title": title.map(JSONValue.string) ?? .null
                ]
            )
        }

        return errorResult(
            "Failed to click matching element.",
            [
                "ok": .bool(false),
                "pid": .number(Double(pid)),
                "role": role.map(JSONValue.string) ?? .null,
                "title": title.map(JSONValue.string) ?? .null
            ]
        )
    }

    private func callTypeText(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let text = arguments["text"]?.stringValue else {
            return invalidArgument("type_text requires text.")
        }

        let result = await accessibility.typeText(text: text)
        if result.success {
            return successResult(
                "Text typed using \(result.strategy).",
                [
                    "ok": .bool(true),
                    "strategy": .string(result.strategy),
                    "text_length": .number(Double(text.count))
                ]
            )
        }

        return errorResult(
            "Failed to type text.",
            [
                "ok": .bool(false),
                "strategy": .string(result.strategy),
                "text_length": .number(Double(text.count))
            ]
        )
    }

    private func callReadValue(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("read_value requires a positive integer pid.")
        }

        guard let role = arguments["role"]?.stringValue, !role.isEmpty else {
            return invalidArgument("read_value requires role.")
        }

        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            return invalidArgument("read_value requires title.")
        }

        guard let element = await accessibility.findElement(pid: pid, role: role, title: title) else {
            return errorResult(
                "No matching element found.",
                [
                    "ok": .bool(false),
                    "pid": .number(Double(pid)),
                    "role": .string(role),
                    "title": .string(title)
                ]
            )
        }

        guard let value = await accessibility.readValue(element: element) else {
            return errorResult(
                "Element has no readable value.",
                [
                    "ok": .bool(false),
                    "pid": .number(Double(pid)),
                    "role": .string(role),
                    "title": .string(title)
                ]
            )
        }

        return successResult(
            "Read element value.",
            [
                "ok": .bool(true),
                "pid": .number(Double(pid)),
                "role": .string(role),
                "title": .string(title),
                "value": .string(value)
            ]
        )
    }

    private func callPressKey(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let key = arguments["key"]?.stringValue, !key.isEmpty else {
            return invalidArgument("press_key requires key.")
        }

        guard let keyCode = KeyCodeMap.keyCode(for: key) else {
            return invalidArgument("Unsupported key '\(key)'.")
        }

        let modifierParse = parseModifiers(arguments["modifiers"])
        switch modifierParse {
        case .failure(let error):
            return invalidArgument(error.description)
        case .success(let modifiers):
            let pressed = await accessibility.pressKey(keyCode: keyCode, modifiers: modifiers)
            if pressed {
                return successResult(
                    "Key press sent.",
                    [
                        "ok": .bool(true),
                        "key": .string(key),
                        "key_code": .number(Double(keyCode)),
                        "modifiers": .array((arguments["modifiers"]?.arrayValue ?? []).compactMap { value in
                            value.stringValue.map(JSONValue.string)
                        })
                    ]
                )
            }

            return errorResult(
                "Failed to send key press.",
                [
                    "ok": .bool(false),
                    "key": .string(key),
                    "key_code": .number(Double(keyCode))
                ]
            )
        }
    }

    private func callFocusedApp() async -> ToolCallResult {
        guard let app = await accessibility.getFocusedApp() else {
            return errorResult("No focused app detected.", ["ok": .bool(false)])
        }

        return successResult(
            "Focused app retrieved.",
            [
                "ok": .bool(true),
                "app": encodeAsJSONValue(app)
            ]
        )
    }

    private func callListApps() async -> ToolCallResult {
        let apps = await accessibility.listApps()
        return successResult(
            "Listed \(apps.count) running apps.",
            [
                "ok": .bool(true),
                "count": .number(Double(apps.count)),
                "apps": encodeAsJSONValue(apps)
            ]
        )
    }

    private func parsePID(_ value: JSONValue?) -> pid_t? {
        guard let integer = value?.intValue, integer > 0, integer <= Int(Int32.max) else {
            return nil
        }
        return pid_t(integer)
    }

    struct ToolInputError: Error, CustomStringConvertible {
        let description: String
    }

    private func parseModifiers(_ rawValue: JSONValue?) -> Result<[CGEventFlags], ToolInputError> {
        guard let rawValue else { return .success([]) }
        guard let values = rawValue.arrayValue else {
            return .failure(ToolInputError(description: "modifiers must be an array of strings."))
        }

        var flags: [CGEventFlags] = []
        var unknown: [String] = []

        for value in values {
            guard let modifier = value.stringValue else {
                return .failure(ToolInputError(description: "modifiers must be an array of strings."))
            }

            if let flag = modifierFlag(for: modifier) {
                flags.append(flag)
            } else {
                unknown.append(modifier)
            }
        }

        if !unknown.isEmpty {
            return .failure(ToolInputError(description: "Unknown modifiers: \(unknown.joined(separator: ", "))."))
        }

        return .success(flags)
    }

    private func modifierFlag(for value: String) -> CGEventFlags? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "cmd":
            return .maskCommand
        case "shift":
            return .maskShift
        case "option", "alt":
            return .maskAlternate
        case "control", "ctrl":
            return .maskControl
        case "fn", "function":
            return .maskSecondaryFn
        default:
            return nil
        }
    }

    private func invalidArgument(_ message: String) -> ToolCallResult {
        errorResult(message, ["ok": .bool(false), "error": .string(message)])
    }

    private func errorResult(_ message: String, _ payload: [String: JSONValue] = [:]) -> ToolCallResult {
        ToolCallResult(text: message, structuredContent: .object(payload), isError: true)
    }

    private func successResult(_ message: String, _ payload: [String: JSONValue]) -> ToolCallResult {
        ToolCallResult(text: message, structuredContent: .object(payload), isError: false)
    }

    private static func schema(properties: [String: JSONValue], required: [String] = []) -> JSONValue {
        var schema: [String: JSONValue] = [
            "type": .string("object"),
            "properties": .object(properties),
            "additionalProperties": .bool(false)
        ]

        if !required.isEmpty {
            schema["required"] = .array(required.map { .string($0) })
        }

        return .object(schema)
    }

    private static let definitions: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "list_elements",
            description: "List actionable accessibility elements for a process ID.",
            inputSchema: schema(
                properties: [
                    "pid": .object([
                        "type": .string("integer"),
                        "description": .string("Target process ID.")
                    ]),
                    "max_depth": .object([
                        "type": .string("integer"),
                        "description": .string("Traversal depth limit (default 8).")
                    ])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "find_element",
            description: "Find a matching accessibility element by role/title.",
            inputSchema: schema(
                properties: [
                    "pid": .object([
                        "type": .string("integer"),
                        "description": .string("Target process ID.")
                    ]),
                    "role": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive role filter.")
                    ]),
                    "title": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive title filter.")
                    ])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "click",
            description: "Click an element by role/title or click absolute coordinates.",
            inputSchema: schema(
                properties: [
                    "pid": .object([
                        "type": .string("integer"),
                        "description": .string("Target process ID when clicking by selector.")
                    ]),
                    "role": .object([
                        "type": .string("string")
                    ]),
                    "title": .object([
                        "type": .string("string")
                    ]),
                    "x": .object([
                        "type": .string("number")
                    ]),
                    "y": .object([
                        "type": .string("number")
                    ])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "type_text",
            description: "Type text into the currently focused field.",
            inputSchema: schema(
                properties: [
                    "text": .object([
                        "type": .string("string")
                    ])
                ],
                required: ["text"]
            )
        ),
        MCPToolDefinition(
            name: "read_value",
            description: "Read kAXValueAttribute from a matching element.",
            inputSchema: schema(
                properties: [
                    "pid": .object([
                        "type": .string("integer")
                    ]),
                    "role": .object([
                        "type": .string("string")
                    ]),
                    "title": .object([
                        "type": .string("string")
                    ])
                ],
                required: ["pid", "role", "title"]
            )
        ),
        MCPToolDefinition(
            name: "press_key",
            description: "Send a keyboard key with optional modifiers.",
            inputSchema: schema(
                properties: [
                    "key": .object([
                        "type": .string("string")
                    ]),
                    "modifiers": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string")
                        ])
                    ])
                ],
                required: ["key"]
            )
        ),
        MCPToolDefinition(
            name: "focused_app",
            description: "Get metadata for NSWorkspace.shared.frontmostApplication.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "list_apps",
            description: "List running regular applications.",
            inputSchema: schema(properties: [:])
        )
    ]
}

private enum KeyCodeMap {
    static let values: [String: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11,
        "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
        "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27,
        "8": 28, "0": 29, "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35,
        "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44, "n": 45, "m": 46, ".": 47,
        "`": 50,
        "return": 36, "enter": 76, "tab": 48, "space": 49, "delete": 51, "backspace": 51,
        "escape": 53, "esc": 53, "forward_delete": 117,
        "home": 115, "end": 119, "page_up": 116, "page_down": 121,
        "left": 123, "left_arrow": 123, "right": 124, "right_arrow": 124,
        "down": 125, "down_arrow": 125, "up": 126, "up_arrow": 126,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97,
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111
    ]

    static func keyCode(for key: String) -> CGKeyCode? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return values[normalized]
    }
}
