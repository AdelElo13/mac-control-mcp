import Foundation
import CoreGraphics

// MARK: - Tool definitions (Phase 3: input + lifecycle + displays)

extension ToolRegistry {
    static let definitionsV2Phase3: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "mouse_event",
            description: "Low-level mouse event: move, click, double_click. Use for precise positional input when AX element-based click is not possible.",
            inputSchema: schema(
                properties: [
                    "action": .object([
                        "type": .string("string"),
                        "description": .string("'move', 'click', 'double_click'.")
                    ]),
                    "x": .object(["type": .string("number")]),
                    "y": .object(["type": .string("number")]),
                    "button": .object([
                        "type": .string("string"),
                        "description": .string("'left', 'right', or 'center'. Default left.")
                    ])
                ],
                required: ["action", "x", "y"]
            )
        ),
        MCPToolDefinition(
            name: "drag_and_drop",
            description: "Click-and-drag from (x1,y1) to (x2,y2). Supports left/right/center button and step count for smoothness.",
            inputSchema: schema(
                properties: [
                    "x1": .object(["type": .string("number")]),
                    "y1": .object(["type": .string("number")]),
                    "x2": .object(["type": .string("number")]),
                    "y2": .object(["type": .string("number")]),
                    "button": .object(["type": .string("string")]),
                    "steps": .object(["type": .array([.string("integer"), .string("string")])])
                ],
                required: ["x1", "y1", "x2", "y2"]
            )
        ),
        MCPToolDefinition(
            name: "scroll",
            description: "Scroll wheel event. Positive delta_y scrolls up, negative scrolls down. Optional x/y targets the cursor position.",
            inputSchema: schema(
                properties: [
                    "delta_x": .object(["type": .array([.string("integer"), .string("string")])]),
                    "delta_y": .object(["type": .array([.string("integer"), .string("string")])]),
                    "x": .object(["type": .string("number")]),
                    "y": .object(["type": .string("number")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "launch_app",
            description: "Launch an application by bundle ID, absolute path, or app name. Accepts `identifier` (canonical) or `bundle_id` (alias — same meaning, aligns with activate_app/quit_app/wait_for_app).",
            inputSchema: schema(
                properties: [
                    "identifier": .object([
                        "type": .string("string"),
                        "description": .string("Bundle ID (com.apple.Safari), path (/Applications/Safari.app), or name ('Safari').")
                    ]),
                    "bundle_id": .object([
                        "type": .string("string"),
                        "description": .string("Alias for `identifier` — accepted for consistency with activate_app/quit_app/wait_for_app.")
                    ])
                ]
            )
        ),
        MCPToolDefinition(
            name: "activate_app",
            description: "Bring a running app to the front by PID or bundle ID.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "bundle_id": .object(["type": .string("string")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "quit_app",
            description: "Quit an app by PID or bundle ID. Pass force=true for forceTerminate.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "bundle_id": .object(["type": .string("string")]),
                    "force": .object(["type": .string("boolean")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "wait_for_element",
            description: "Poll for an AX element matching role/title to appear (or disappear). Returns the element ID once found.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "role": .object(["type": .string("string")]),
                    "title": .object(["type": .string("string")]),
                    "timeout_seconds": .object(["type": .string("number"), "description": .string("Default 5.0, max 60.")]),
                    "poll_interval_ms": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Default 200ms.")]),
                    "expect_disappear": .object(["type": .string("boolean")])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "list_displays",
            description: "List all connected displays with bounds, scale factor, and main-display flag.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "convert_coordinates",
            description: "Convert coordinates between coordinate spaces: 'global' (default) or 'display:<index>'.",
            inputSchema: schema(
                properties: [
                    "x": .object(["type": .string("number")]),
                    "y": .object(["type": .string("number")]),
                    "from": .object(["type": .string("string")]),
                    "to": .object(["type": .string("string")])
                ],
                required: ["x", "y", "from", "to"]
            )
        )
    ]
}

// MARK: - Tool implementations (Phase 3)

extension ToolRegistry {
    func callMouseEvent(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let action = arguments["action"]?.stringValue else {
            return invalidArgument("mouse_event requires action.")
        }
        guard let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue else {
            return invalidArgument("mouse_event requires x and y.")
        }
        let point = CGPoint(x: x, y: y)
        let button = parseButton(arguments["button"]?.stringValue)

        let ok: Bool
        switch action.lowercased() {
        case "move":
            ok = await mouse.move(to: point)
        case "click":
            ok = await mouse.click(at: point, button: button)
        case "double_click", "doubleclick":
            ok = await mouse.doubleClick(at: point, button: button)
        default:
            return invalidArgument("Unknown action '\(action)'. Use move, click, or double_click.")
        }

        let payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "action": .string(action),
            "button": .string(button.rawValue),
            "x": .number(x),
            "y": .number(y)
        ]
        return ok
            ? successResult("Mouse event posted.", payload)
            : errorResult("Failed to post mouse event.", payload)
    }

    func callDragAndDrop(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let x1 = arguments["x1"]?.doubleValue,
              let y1 = arguments["y1"]?.doubleValue,
              let x2 = arguments["x2"]?.doubleValue,
              let y2 = arguments["y2"]?.doubleValue
        else {
            return invalidArgument("drag_and_drop requires x1, y1, x2, y2.")
        }
        let button = parseButton(arguments["button"]?.stringValue)
        let steps = max(1, min(arguments["steps"]?.intValue ?? 20, 200))

        let ok = await mouse.drag(
            from: CGPoint(x: x1, y: y1),
            to: CGPoint(x: x2, y: y2),
            button: button,
            steps: steps
        )
        let payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "from": .object(["x": .number(x1), "y": .number(y1)]),
            "to": .object(["x": .number(x2), "y": .number(y2)]),
            "button": .string(button.rawValue),
            "steps": .number(Double(steps))
        ]
        return ok
            ? successResult("Drag posted.", payload)
            : errorResult("Failed to post drag.", payload)
    }

    func callScroll(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let dx = arguments["delta_x"]?.intValue ?? 0
        let dy = arguments["delta_y"]?.intValue ?? 0
        if dx == 0 && dy == 0 {
            return invalidArgument("scroll requires non-zero delta_x or delta_y.")
        }
        let point: CGPoint? = {
            guard let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue else { return nil }
            return CGPoint(x: x, y: y)
        }()

        let ok = await mouse.scroll(deltaX: dx, deltaY: dy, at: point)
        let payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "delta_x": .number(Double(dx)),
            "delta_y": .number(Double(dy))
        ]
        return ok
            ? successResult("Scroll posted.", payload)
            : errorResult("Failed to post scroll.", payload)
    }

    func callLaunchApp(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        // Accept `identifier` (canonical) OR `bundle_id` (the name used
        // by sibling tools activate_app / quit_app / wait_for_app). Pick
        // the first NON-EMPTY value across both keys — not just the
        // first non-nil. A previous version used `??`, which only falls
        // through on nil; a caller sending `{"identifier": "",
        // "bundle_id": "com.apple.Safari"}` (common with form-default
        // empty strings) would take the empty `identifier` and error
        // out despite a valid bundle_id being present. (Codex v11
        // MEDIUM.)
        let candidates = [arguments["identifier"], arguments["bundle_id"]]
        let identifier = candidates
            .compactMap { $0?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard let identifier, !identifier.isEmpty else {
            return invalidArgument("launch_app requires identifier (bundle ID, path, or app name).")
        }
        let result = await appLifecycle.launch(identifier: identifier)
        let ok = (result.pid != nil)
        let payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "identifier": .string(identifier),
            "pid": result.pid.map { .number(Double($0)) } ?? .null,
            "name": result.name.map(JSONValue.string) ?? .null,
            "bundle_id": result.bundleIdentifier.map(JSONValue.string) ?? .null
        ]
        return ok
            ? successResult("App launched.", payload)
            : errorResult("Could not launch app '\(identifier)'.", payload)
    }

    func callActivateApp(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let pid = parsePID(arguments["pid"])
        let bundleID = arguments["bundle_id"]?.stringValue
        if pid == nil && (bundleID == nil || bundleID?.isEmpty == true) {
            return invalidArgument("activate_app requires pid or bundle_id.")
        }
        let ok = await appLifecycle.activate(pid: pid, bundleIdentifier: bundleID)
        let payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "pid": pid.map { .number(Double($0)) } ?? .null,
            "bundle_id": bundleID.map(JSONValue.string) ?? .null
        ]
        return ok
            ? successResult("App activated.", payload)
            : errorResult("Could not activate app.", payload)
    }

    func callQuitApp(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let pid = parsePID(arguments["pid"])
        let bundleID = arguments["bundle_id"]?.stringValue
        if pid == nil && (bundleID == nil || bundleID?.isEmpty == true) {
            return invalidArgument("quit_app requires pid or bundle_id.")
        }
        let force: Bool = {
            if case .bool(let b) = arguments["force"] ?? .null { return b }
            return false
        }()
        let ok = await appLifecycle.quit(pid: pid, bundleIdentifier: bundleID, force: force)
        let payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "pid": pid.map { .number(Double($0)) } ?? .null,
            "bundle_id": bundleID.map(JSONValue.string) ?? .null,
            "force": .bool(force)
        ]
        return ok
            ? successResult("App quit.", payload)
            : errorResult("Could not quit app.", payload)
    }

    func callWaitForElement(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("wait_for_element requires a positive integer pid.")
        }
        let role = arguments["role"]?.stringValue
        let title = arguments["title"]?.stringValue
        let timeout = min(max(arguments["timeout_seconds"]?.doubleValue ?? 5.0, 0.1), 60.0)
        let intervalMs = max(arguments["poll_interval_ms"]?.intValue ?? 200, 50)
        let expectDisappear: Bool = {
            if case .bool(let b) = arguments["expect_disappear"] ?? .null { return b }
            return false
        }()

        let deadline = Date().addingTimeInterval(timeout)
        var attempts = 0

        while Date() < deadline {
            attempts += 1
            let element = await accessibility.findElement(pid: pid, role: role, title: title)

            if expectDisappear {
                if element == nil {
                    return successResult(
                        "Element disappeared after \(attempts) attempt(s).",
                        ["ok": .bool(true), "attempts": .number(Double(attempts)), "disappeared": .bool(true)]
                    )
                }
            } else if let element {
                let info = await accessibility.getElementInfo(element: element)
                let id = await elementCache.store(element, pid: pid)
                return successResult(
                    "Element appeared after \(attempts) attempt(s).",
                    [
                        "ok": .bool(true),
                        "attempts": .number(Double(attempts)),
                        "element_id": .string(id),
                        "role": info.role.map(JSONValue.string) ?? .null,
                        "title": info.title.map(JSONValue.string) ?? .null
                    ]
                )
            }

            do {
                try await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
            } catch {
                return errorResult(
                    "Cancelled after \(attempts) attempt(s).",
                    ["ok": .bool(false), "attempts": .number(Double(attempts)), "cancelled": .bool(true)]
                )
            }
        }

        return errorResult(
            "Timed out after \(timeout)s (\(attempts) attempts).",
            [
                "ok": .bool(false),
                "attempts": .number(Double(attempts)),
                "timed_out": .bool(true)
            ]
        )
    }

    func callListDisplays() async -> ToolCallResult {
        let list = await displays.list()
        return successResult(
            "Listed \(list.count) display(s).",
            [
                "ok": .bool(true),
                "count": .number(Double(list.count)),
                "displays": encodeAsJSONValue(list)
            ]
        )
    }

    func callConvertCoordinates(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let x = arguments["x"]?.doubleValue,
              let y = arguments["y"]?.doubleValue,
              let from = arguments["from"]?.stringValue,
              let to = arguments["to"]?.stringValue
        else {
            return invalidArgument("convert_coordinates requires x, y, from, to.")
        }
        guard let point = await displays.convert(x: x, y: y, from: from, to: to) else {
            return errorResult(
                "Unknown coordinate space. Use 'global' or 'display:<index>'.",
                ["ok": .bool(false), "from": .string(from), "to": .string(to)]
            )
        }
        return successResult(
            "Coordinates converted.",
            [
                "ok": .bool(true),
                "x": .number(Double(point.x)),
                "y": .number(Double(point.y)),
                "from": .string(from),
                "to": .string(to)
            ]
        )
    }

    // MARK: - Helpers

    private func parseButton(_ raw: String?) -> MouseController.Button {
        switch raw?.lowercased() {
        case "right": return .right
        case "center", "middle": return .center
        default: return .left
        }
    }
}
