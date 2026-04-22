import Foundation
import ApplicationServices

// MARK: - Tool definitions (v0.2.0)

extension ToolRegistry {
    static let definitionsV2: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "get_ui_tree",
            description: "Walk the full accessibility tree of a process and return every node (including containers) with stable element IDs for follow-up calls.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Target process ID.")]),
                    "max_depth": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Traversal depth limit (default 12, max 64).")])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "find_elements",
            description: "Find all matching accessibility elements (not just the first) by role/title/value.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "role": .object(["type": .string("string")]),
                    "title": .object(["type": .string("string")]),
                    "value": .object(["type": .string("string")]),
                    "max_depth": .object(["type": .array([.string("integer"), .string("string")])]),
                    "limit": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Max matches to return (default 100).")])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "query_elements",
            description: "Regex search over role/title/value. Invalid regex falls back to case-insensitive substring.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "role_regex": .object(["type": .string("string")]),
                    "title_regex": .object(["type": .string("string")]),
                    "value_regex": .object(["type": .string("string")]),
                    "max_depth": .object(["type": .array([.string("integer"), .string("string")])]),
                    "limit": .object(["type": .array([.string("integer"), .string("string")])])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "get_element_attributes",
            description: "Read one or more AX attributes for a cached element ID. Pass names=[] to list available attribute names.",
            inputSchema: schema(
                properties: [
                    "element_id": .object(["type": .string("string")]),
                    "names": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ])
                ],
                required: ["element_id"]
            )
        ),
        MCPToolDefinition(
            name: "set_element_attribute",
            description: "Write an AX attribute on a cached element ID. Accepts string, number, or boolean.",
            inputSchema: schema(
                properties: [
                    "element_id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "value": .object([:])
                ],
                required: ["element_id", "name", "value"]
            )
        ),
        MCPToolDefinition(
            name: "perform_element_action",
            description: "Invoke an AX action on a cached element ID (AXPress, AXShowMenu, AXIncrement, AXDecrement, AXCancel, AXRaise, etc). Omit action to list available actions.",
            inputSchema: schema(
                properties: [
                    "element_id": .object(["type": .string("string")]),
                    "action": .object(["type": .string("string")])
                ],
                required: ["element_id"]
            )
        ),
        MCPToolDefinition(
            name: "list_windows",
            description: "List all windows of all running regular apps (or one app if pid is provided).",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Optional — restrict to this app.")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "focus_window",
            description: "Bring a window to the front by pid + window index (from list_windows).",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "index": .object(["type": .array([.string("integer"), .string("string")])])
                ],
                required: ["pid", "index"]
            )
        ),
        MCPToolDefinition(
            name: "click_menu_path",
            description: "Click a menu item by title path, e.g. path=[\"File\",\"Export\",\"PDF...\"].",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "path": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ])
                ],
                required: ["pid", "path"]
            )
        ),
        MCPToolDefinition(
            name: "list_menu_titles",
            description: "List top-level menubar titles for an app — useful for discovery before click_menu_path.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "clipboard_read",
            description: "Read the current clipboard as text and list all available pasteboard types.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "clipboard_write",
            description: "Replace the clipboard with plain text.",
            inputSchema: schema(
                properties: [
                    "text": .object(["type": .string("string")])
                ],
                required: ["text"]
            )
        ),
        MCPToolDefinition(
            name: "permissions_status",
            description: "Report the accessibility permission state for this process.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "probe_ax_tree",
            description: "Check whether an app exposes an AX tree. "
                + "Returns has_ax_tree=false + an actionable hint for apps that don't implement NSAccessibility "
                + "(e.g. native Telegram) so callers can skip fruitless find/query loops.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])])
                ],
                required: ["pid"]
            )
        )
    ]
}

// MARK: - Tool implementations (v0.2.0)

extension ToolRegistry {
    func callGetUITree(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("get_ui_tree requires a positive integer pid.")
        }
        let maxDepth = max(1, min(arguments["max_depth"]?.intValue ?? 12, 64))
        let nodes = await accessibility.treeWalk(pid: pid, maxDepth: maxDepth)

        var encoded: [JSONValue] = []
        encoded.reserveCapacity(nodes.count)
        for node in nodes {
            let id = await elementCache.store(node.element, pid: pid)
            encoded.append(encodeTreeNode(node: node, id: id))
        }

        return successResult(
            "Walked \(nodes.count) nodes (max_depth=\(maxDepth)).",
            [
                "ok": .bool(true),
                "pid": .number(Double(pid)),
                "max_depth": .number(Double(maxDepth)),
                "count": .number(Double(nodes.count)),
                "nodes": .array(encoded)
            ]
        )
    }

    func callFindElements(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("find_elements requires a positive integer pid.")
        }
        let role = arguments["role"]?.stringValue
        let title = arguments["title"]?.stringValue
        let value = arguments["value"]?.stringValue
        let maxDepth = max(1, min(arguments["max_depth"]?.intValue ?? 32, 64))
        let limit = max(1, min(arguments["limit"]?.intValue ?? 100, 500))

        let matches = await accessibility.findElements(
            pid: pid, role: role, title: title, value: value,
            maxDepth: maxDepth, limit: limit
        )

        var encoded: [JSONValue] = []
        for (element, info) in matches {
            let id = await elementCache.store(element, pid: pid)
            encoded.append(encodeElement(info: info, id: id))
        }

        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "pid": .number(Double(pid)),
            "count": .number(Double(matches.count)),
            "limit_reached": .bool(matches.count >= limit),
            "elements": .array(encoded)
        ]
        if let hint = await axEmptyHint(pid: pid, whenEmpty: matches.isEmpty) {
            payload["ax_tree_hint"] = .string(hint)
        }
        return successResult("Found \(matches.count) matching elements.", payload)
    }

    func callQueryElements(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("query_elements requires a positive integer pid.")
        }
        let rolePattern = arguments["role_regex"]?.stringValue
        let titlePattern = arguments["title_regex"]?.stringValue
        let valuePattern = arguments["value_regex"]?.stringValue
        let maxDepth = max(1, min(arguments["max_depth"]?.intValue ?? 32, 64))
        let limit = max(1, min(arguments["limit"]?.intValue ?? 200, 500))

        let matches = await accessibility.queryElements(
            pid: pid,
            rolePattern: rolePattern,
            titlePattern: titlePattern,
            valuePattern: valuePattern,
            maxDepth: maxDepth,
            limit: limit
        )

        var encoded: [JSONValue] = []
        for (element, info) in matches {
            let id = await elementCache.store(element, pid: pid)
            encoded.append(encodeElement(info: info, id: id))
        }

        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "pid": .number(Double(pid)),
            "count": .number(Double(matches.count)),
            "elements": .array(encoded)
        ]
        if let hint = await axEmptyHint(pid: pid, whenEmpty: matches.isEmpty) {
            payload["ax_tree_hint"] = .string(hint)
        }
        return successResult("Query returned \(matches.count) elements.", payload)
    }

    func callGetElementAttributes(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let id = arguments["element_id"]?.stringValue, !id.isEmpty else {
            return invalidArgument("get_element_attributes requires element_id.")
        }
        guard let element = await elementCache.resolve(id) else {
            return errorResult("Unknown or expired element_id.", ["ok": .bool(false), "element_id": .string(id)])
        }

        // Codex v8 #10 — strict type check on `names`. If the key is
        // PRESENT but not an array, reject rather than silently treating
        // as "empty names" (which opens the unintended list-attributes
        // path). Omit the key entirely if you want that behaviour.
        if let raw = arguments["names"], case .array(_) = raw { } else if arguments["names"] != nil,
                                                                         !(arguments["names"] == .null) {
            return invalidArgument("get_element_attributes: names must be an array of strings (or omitted to list names).")
        }
        let requestedNames = arguments["names"]?.arrayValue?.compactMap { $0.stringValue } ?? []

        // Empty names (or omitted) → list available attribute names instead of reading values.
        if requestedNames.isEmpty {
            let names = await accessibility.attributeNames(element: element)
            let actions = await accessibility.actionNames(element: element)
            return successResult(
                "Listed \(names.count) attributes and \(actions.count) actions.",
                [
                    "ok": .bool(true),
                    "element_id": .string(id),
                    "attribute_names": .array(names.map(JSONValue.string)),
                    "action_names": .array(actions.map(JSONValue.string))
                ]
            )
        }

        let result = await accessibility.getAttributes(element: element, names: requestedNames)
        let valueMap: [String: JSONValue] = result.values.mapValues { .string($0) }
        return successResult(
            "Read \(result.values.count) attribute(s).",
            [
                "ok": .bool(true),
                "element_id": .string(id),
                "values": .object(valueMap),
                "unavailable": .array(result.unavailable.map(JSONValue.string))
            ]
        )
    }

    func callSetElementAttribute(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let id = arguments["element_id"]?.stringValue, !id.isEmpty else {
            return invalidArgument("set_element_attribute requires element_id.")
        }
        guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
            return invalidArgument("set_element_attribute requires name.")
        }
        guard let value = arguments["value"] else {
            return invalidArgument("set_element_attribute requires value.")
        }
        guard let element = await elementCache.resolve(id) else {
            return errorResult("Unknown or expired element_id.", ["ok": .bool(false), "element_id": .string(id)])
        }

        let status = await accessibility.setAttribute(element: element, name: name, value: value)
        let success = (status == 0)
        let payload: [String: JSONValue] = [
            "ok": .bool(success),
            "element_id": .string(id),
            "name": .string(name),
            "ax_status": .number(Double(status))
        ]
        return success
            ? successResult("Attribute set.", payload)
            : errorResult("AXUIElementSetAttributeValue failed (AXError=\(status)).", payload)
    }

    func callPerformElementAction(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let id = arguments["element_id"]?.stringValue, !id.isEmpty else {
            return invalidArgument("perform_element_action requires element_id.")
        }
        guard let element = await elementCache.resolve(id) else {
            return errorResult("Unknown or expired element_id.", ["ok": .bool(false), "element_id": .string(id)])
        }

        // Codex v8 #10 — strict type check on `action`. If the key is
        // PRESENT but not a string, reject with invalidArgument rather
        // than silently treating it as "no action" and listing actions.
        if let raw = arguments["action"], case .string(_) = raw { } else if arguments["action"] != nil,
                                                                            !(arguments["action"] == .null) {
            return invalidArgument("perform_element_action: action must be a string (or omitted to list actions).")
        }

        // No action specified → list available actions.
        guard let action = arguments["action"]?.stringValue, !action.isEmpty else {
            let actions = await accessibility.actionNames(element: element)
            return successResult(
                "Listed \(actions.count) available action(s).",
                [
                    "ok": .bool(true),
                    "element_id": .string(id),
                    "action_names": .array(actions.map(JSONValue.string))
                ]
            )
        }

        let outcome = await accessibility.performAction(element: element, action: action)
        var payload: [String: JSONValue] = [
            "ok": .bool(outcome.ok),
            "element_id": .string(id),
            "action": .string(action),
            "ax_status": .number(Double(outcome.axStatus)),
            "strategy": .string(outcome.strategy)
        ]
        if let reason = outcome.reason { payload["reason"] = .string(reason) }
        if let hint = outcome.hint { payload["hint"] = .string(hint) }
        if outcome.ok {
            let message = outcome.strategy == "coord_fallback"
                ? "Action performed via coord-click fallback (AXPress unsupported)."
                : "Action performed."
            return successResult(message, payload)
        }
        let errorMessage: String
        switch outcome.strategy {
        case "rejected_disabled":
            errorMessage = "Refused to perform action — target is AXDisabled."
        case "rejected_unsupported":
            errorMessage = "AXPress unsupported and no geometry for coord-fallback."
        default:
            errorMessage = "AXUIElementPerformAction failed (AXError=\(outcome.axStatus), reason=\(outcome.reason ?? "unknown"))."
        }
        return errorResult(errorMessage, payload)
    }

    func callListWindows(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        // Only fall through to "all apps" if the pid key is absent. If it's
        // present but malformed, reject with an explicit error instead of
        // silently returning the wrong thing.
        if let pidValue = arguments["pid"], case .null = pidValue { } else if arguments["pid"] != nil {
            guard let pid = parsePID(arguments["pid"]) else {
                return invalidArgument("list_windows pid must be a positive integer.")
            }
            let windows = await windows.listAppWindows(pid: pid)
            return successResult(
                "Listed \(windows.count) window(s) for pid \(pid).",
                [
                    "ok": .bool(true),
                    "pid": .number(Double(pid)),
                    "count": .number(Double(windows.count)),
                    "windows": encodeAsJSONValue(windows)
                ]
            )
        }

        let windows = await self.windows.listWindows()
        return successResult(
            "Listed \(windows.count) window(s) across all apps.",
            [
                "ok": .bool(true),
                "count": .number(Double(windows.count)),
                "windows": encodeAsJSONValue(windows)
            ]
        )
    }

    func callFocusWindow(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("focus_window requires a positive integer pid.")
        }
        guard let index = arguments["index"]?.intValue, index >= 0 else {
            return invalidArgument("focus_window requires a non-negative index.")
        }
        let success = await windows.focusWindow(pid: pid, index: index)
        let payload: [String: JSONValue] = [
            "ok": .bool(success),
            "pid": .number(Double(pid)),
            "index": .number(Double(index))
        ]
        return success
            ? successResult("Window focused.", payload)
            : errorResult("Failed to focus window (invalid pid or index).", payload)
    }

    func callClickMenuPath(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("click_menu_path requires a positive integer pid.")
        }
        guard
            let pathArr = arguments["path"]?.arrayValue,
            !pathArr.isEmpty
        else {
            return invalidArgument("click_menu_path requires a non-empty path array.")
        }
        let path = pathArr.compactMap { $0.stringValue }
        if path.count != pathArr.count {
            return invalidArgument("click_menu_path path entries must all be strings.")
        }

        let result = await menus.clickPath(pid: pid, path: path)
        let payload: [String: JSONValue] = [
            "ok": .bool(result.success),
            "pid": .number(Double(pid)),
            "requested_path": .array(path.map(JSONValue.string)),
            "clicked_path": .array(result.clickedPath.map(JSONValue.string)),
            "missing_segment": result.missingSegment.map(JSONValue.string) ?? .null
        ]
        return result.success
            ? successResult("Menu path clicked.", payload)
            : errorResult("Menu path not fully reachable; missing '\(result.missingSegment ?? "?")'.", payload)
    }

    func callListMenuTitles(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("list_menu_titles requires a positive integer pid.")
        }
        let titles = await menus.topLevelTitles(pid: pid)
        return successResult(
            "Listed \(titles.count) top-level menu title(s).",
            [
                "ok": .bool(true),
                "pid": .number(Double(pid)),
                "titles": .array(titles.map(JSONValue.string))
            ]
        )
    }

    func callClipboardRead() async -> ToolCallResult {
        let result = await clipboard.read()
        return successResult(
            "Read clipboard.",
            [
                "ok": .bool(true),
                "text": result.text.map(JSONValue.string) ?? .null,
                "types": .array(result.types.map(JSONValue.string))
            ]
        )
    }

    func callClipboardWrite(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let text = arguments["text"]?.stringValue else {
            return invalidArgument("clipboard_write requires text.")
        }
        let ok = await clipboard.write(text: text)
        return ok
            ? successResult("Clipboard updated.", ["ok": .bool(true), "length": .number(Double(text.count))])
            : errorResult("Pasteboard rejected the write.", ["ok": .bool(false)])
    }

    func callPermissionsStatus() async -> ToolCallResult {
        // v0.8.0: report all TCC categories mac-control-mcp touches, not
        // just Accessibility. Agent now gets an actionable picture of what's
        // missing instead of a single boolean.
        let ax = await accessibility.checkPermission()
        let screen = Self.screenPermissionStatusString()
        let calendar = Self.calendarPermissionStatusString()
        let reminders = Self.remindersPermissionStatusString()
        let contacts = Self.contactsPermissionStatusString()
        let location = Self.locationPermissionStatusString()
        let microphone = Self.microphonePermissionStatusString()

        let axStr = ax ? "granted" : "not_granted"
        let missing: [String] = [
            ("accessibility", axStr),
            ("screen_recording", screen),
            ("calendar", calendar),
            ("reminders", reminders),
            ("contacts", contacts),
            ("location", location),
            ("microphone", microphone)
        ]
        .filter { !["granted", "granted_when_in_use", "granted_always", "granted_legacy", "write_only", "authorized_legacy", "limited"].contains($0.1) }
        .map { $0.0 }

        let summary = missing.isEmpty
            ? "All 7 monitored permissions granted."
            : "Missing: \(missing.joined(separator: ", ")). Use open_permission_pane to jump to the right System Settings page."

        return successResult(
            summary,
            [
                "ok": .bool(true),
                "accessibility": .string(axStr),
                "screen_recording": .string(screen),
                "calendar": .string(calendar),
                "reminders": .string(reminders),
                "contacts": .string(contacts),
                "location": .string(location),
                "microphone": .string(microphone),
                "missing": .array(missing.map { .string($0) }),
                "hint": .string(missing.isEmpty
                    ? "All monitored categories are ready to use."
                    : "For each item in 'missing', call `open_permission_pane` with pane=<that item>. Toggle mac-control-mcp ON in the System Settings list, then restart the MCP server for the grant to take effect.")
            ]
        )
    }

    // MARK: - JSON encoders

    private func encodeElement(info: AccessibilityController.ElementInfo, id: String) -> JSONValue {
        var dict: [String: JSONValue] = [
            "id": .string(id),
            "role": info.role.map(JSONValue.string) ?? .null,
            "title": info.title.map(JSONValue.string) ?? .null,
            "value": info.value.map(JSONValue.string) ?? .null
        ]
        if let p = info.position {
            dict["position"] = .object(["x": .number(p.x), "y": .number(p.y)])
        }
        if let s = info.size {
            dict["size"] = .object(["width": .number(s.width), "height": .number(s.height)])
        }
        if let d = info.depth {
            dict["depth"] = .number(Double(d))
        }
        return .object(dict)
    }

    private func encodeTreeNode(node: AccessibilityController.TreeNode, id: String) -> JSONValue {
        var dict: [String: JSONValue] = [
            "id": .string(id),
            "role": node.role.map(JSONValue.string) ?? .null,
            "title": node.title.map(JSONValue.string) ?? .null,
            "value": node.value.map(JSONValue.string) ?? .null,
            "depth": .number(Double(node.depth)),
            "children": .array(node.childIndices.map { .number(Double($0)) })
        ]
        if let p = node.position {
            dict["position"] = .object(["x": .number(p.x), "y": .number(p.y)])
        }
        if let s = node.size {
            dict["size"] = .object(["width": .number(s.width), "height": .number(s.height)])
        }
        return .object(dict)
    }
}
