import Foundation
import CoreGraphics

// MARK: - Tool definitions (v0.2.0 Phase 4: MUST completion)

extension ToolRegistry {
    static let definitionsV2Phase4: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "move_window",
            description: "Move a window to an absolute (x,y) position in global coordinates.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "index": .object(["type": .array([.string("integer"), .string("string")])]),
                    "x": .object(["type": .string("number")]),
                    "y": .object(["type": .string("number")])
                ],
                required: ["pid", "index", "x", "y"]
            )
        ),
        MCPToolDefinition(
            name: "resize_window",
            description: "Resize a window to the given width and height.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "index": .object(["type": .array([.string("integer"), .string("string")])]),
                    "width": .object(["type": .string("number")]),
                    "height": .object(["type": .string("number")])
                ],
                required: ["pid", "index", "width", "height"]
            )
        ),
        MCPToolDefinition(
            name: "set_window_state",
            description: "Apply a window state: minimize, unminimize, fullscreen, exit_fullscreen, or main.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "index": .object(["type": .array([.string("integer"), .string("string")])]),
                    "state": .object([
                        "type": .string("string"),
                        "description": .string("minimize | unminimize/restore | normal/default/show (unminimize + raise + main) | main/raise | fullscreen | exit_fullscreen/windowed")
                    ])
                ],
                required: ["pid", "index", "state"]
            )
        ),
        MCPToolDefinition(
            name: "file_dialog_set_path",
            description: "Type a path into the frontmost Open/Save dialog via the 'Go to folder' shortcut (Cmd+Shift+G).",
            inputSchema: schema(
                properties: [
                    "path": .object(["type": .string("string")])
                ],
                required: ["path"]
            )
        ),
        MCPToolDefinition(
            name: "file_dialog_select_item",
            description: "Select a file or folder by title in the frontmost Open/Save dialog.",
            inputSchema: schema(
                properties: [
                    "title": .object(["type": .string("string")])
                ],
                required: ["title"]
            )
        ),
        MCPToolDefinition(
            name: "file_dialog_confirm",
            description: "Commit the frontmost Open/Save dialog (Return). Pass cancel=true to dismiss via Escape instead.",
            inputSchema: schema(
                properties: [
                    "cancel": .object(["type": .string("boolean")])
                ]
            )
        )
    ]
}

// MARK: - Tool implementations (Phase 4)

extension ToolRegistry {
    func callMoveWindow(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("move_window requires a positive integer pid.")
        }
        guard let index = arguments["index"]?.intValue, index >= 0 else {
            return invalidArgument("move_window requires a non-negative index.")
        }
        guard let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue else {
            return invalidArgument("move_window requires x and y.")
        }

        let ok = await windows.moveWindow(pid: pid, index: index, to: CGPoint(x: x, y: y))
        let payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "pid": .number(Double(pid)),
            "index": .number(Double(index)),
            "x": .number(x),
            "y": .number(y)
        ]
        return ok
            ? successResult("Window moved.", payload)
            : errorResult("Failed to move window.", payload)
    }

    func callResizeWindow(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("resize_window requires a positive integer pid.")
        }
        guard let index = arguments["index"]?.intValue, index >= 0 else {
            return invalidArgument("resize_window requires a non-negative index.")
        }
        guard let w = arguments["width"]?.doubleValue,
              let h = arguments["height"]?.doubleValue,
              w > 0, h > 0
        else {
            return invalidArgument("resize_window requires positive width and height.")
        }

        let ok = await windows.resizeWindow(pid: pid, index: index, to: CGSize(width: w, height: h))
        let payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "pid": .number(Double(pid)),
            "index": .number(Double(index)),
            "width": .number(w),
            "height": .number(h)
        ]
        return ok
            ? successResult("Window resized.", payload)
            : errorResult("Failed to resize window.", payload)
    }

    func callSetWindowState(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("set_window_state requires a positive integer pid.")
        }
        guard let index = arguments["index"]?.intValue, index >= 0 else {
            return invalidArgument("set_window_state requires a non-negative index.")
        }
        guard let state = arguments["state"]?.stringValue, !state.isEmpty else {
            return invalidArgument("set_window_state requires state.")
        }

        let ok = await windows.setState(pid: pid, index: index, state: state)
        var payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "pid": .number(Double(pid)),
            "index": .number(Double(index)),
            "state": .string(state)
        ]
        if ok {
            return successResult("Window state applied.", payload)
        }
        let supported = WindowController.supportedStates
        let isKnown = supported.contains { $0.caseInsensitiveCompare(state) == .orderedSame }
        payload["supported_states"] = .array(supported.map { .string($0) })
        let message = isKnown
            ? "State '\(state)' is valid but the AX call failed — window may be unreachable (wrong pid/index) or the system denied the attribute write."
            : "Unknown state '\(state)'. Accepted: \(supported.joined(separator: ", "))."
        return errorResult(message, payload)
    }

    func callFileDialogSetPath(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            return invalidArgument("file_dialog_set_path requires path.")
        }
        let result = await fileDialog.setPath(path)
        let payload: [String: JSONValue] = [
            "ok": .bool(result.success),
            "path": .string(path),
            "detail": .string(result.detail)
        ]
        return result.success
            ? successResult(result.detail, payload)
            : errorResult(result.detail, payload)
    }

    func callFileDialogSelectItem(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            return invalidArgument("file_dialog_select_item requires title.")
        }
        let result = await fileDialog.selectItem(named: title)
        let payload: [String: JSONValue] = [
            "ok": .bool(result.success),
            "title": .string(title),
            "detail": .string(result.detail)
        ]
        return result.success
            ? successResult(result.detail, payload)
            : errorResult(result.detail, payload)
    }

    func callFileDialogConfirm(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let cancel: Bool = {
            if case .bool(let b) = arguments["cancel"] ?? .null { return b }
            return false
        }()
        let result = cancel ? await fileDialog.cancel() : await fileDialog.confirm()
        return successResult(
            result.detail,
            ["ok": .bool(result.success), "cancelled": .bool(cancel)]
        )
    }
}
