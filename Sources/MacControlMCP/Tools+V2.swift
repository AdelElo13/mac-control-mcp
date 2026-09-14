import Foundation
import ApplicationServices
import AppKit

// MARK: - Tool definitions (v0.2.0)

/// Shared tail for every tool that honours the v0.9 payload budget.
let axPayloadBudgetDoc = "Every response also reports bytes (encoded size), max_depth_used, nodes_visited and truncated."

extension ToolRegistry {
    static let definitionsV2: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "get_ui_tree",
            description: "Walk the full accessibility tree of a process and return every node (including containers and static text) with child indices and element IDs for follow-up calls. Element IDs are content-addressed (pid + AX path), so the same node keeps the same id across calls and sessions. Bounded by a 5 s budget and node_cap nodes (= element-cache capacity, 2000 by default, so every returned id stays valid); node_cap_reached=true means the tree was cut off — lower max_depth or use find_elements. "
                + "The heaviest AX tool (hundreds of KB for a browser or Finder window — 327 KB measured) — when you know what you are looking for, find_elements / query_elements are far smaller and also return ids. "
                + "To make one look affordable, use interactive_only / viewport_only / fields / max_bytes. " + axPayloadBudgetDoc,
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Target process ID.")]),
                    "max_depth": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Traversal depth limit. Default 24 (project-wide AX default), max 64.")]),
                    "fields": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Payload budget (v0.9): only emit these per-node keys. Default: all of id, role, title, value, position, size, depth, children.")
                    ]),
                    "interactive_only": .object([
                        "type": .string("boolean"),
                        "description": .string("Payload budget: keep only actionable roles (buttons, links, fields, checkboxes, …) plus the ancestors needed to keep the tree connected. Default false.")
                    ]),
                    "viewport_only": .object([
                        "type": .string("boolean"),
                        "description": .string("Payload budget: drop nodes whose frame lies outside the app's on-screen window bounds. Default false.")
                    ]),
                    "max_bytes": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Payload budget: soft cap on the encoded element/node bytes. Emission stops when the next item would exceed it and truncated=true is returned. Default: no cap.")
                    ])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "find_elements",
            description: "Find ALL matching elements (up to limit) by case-insensitive substring on role / title / value (title = AXTitle → AXDescription → AXIdentifier; unlike find_element it does not fall back to AXValue — use the value filter). "
                + "Each match carries an element id for perform_element_action / get_element_attributes / set_element_attribute. "
                + "Use find_element for a cheap first-match check, query_elements when you need regex (anchors, alternation). "
                + "IDs are content-addressed (pid + AX path): the same element keeps the same id across calls and sessions. " + axPayloadBudgetDoc,
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "role": .object(["type": .string("string")]),
                    "title": .object(["type": .string("string")]),
                    "value": .object(["type": .string("string")]),
                    "exact": .object([
                        "type": .string("boolean"),
                        "description": .string("Match role/title/value by case-insensitive EQUALITY instead of substring. Default false — beware that role \"Button\" substring-matches AXRadioButton, AXMenuButton and AXPopUpButton.")
                    ]),
                    "max_depth": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Traversal depth limit. Default 24 (project-wide AX default), max 64.")]),
                    "limit": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Max matches to return (default 100).")]),
                    "fields": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Payload budget (v0.9): only emit these per-node keys. Default: all of id, role, title, value, position, size, depth.")
                    ]),
                    "interactive_only": .object([
                        "type": .string("boolean"),
                        "description": .string("Payload budget: keep only actionable roles (buttons, links, fields, checkboxes, …). Default false.")
                    ]),
                    "viewport_only": .object([
                        "type": .string("boolean"),
                        "description": .string("Payload budget: drop nodes whose frame lies outside the app's on-screen window bounds. Default false.")
                    ]),
                    "max_bytes": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Payload budget: soft cap on the encoded element/node bytes. Emission stops when the next item would exceed it and truncated=true is returned. Default: no cap.")
                    ])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "query_elements",
            description: "Like find_elements, but role_regex / title_regex / value_regex are case-insensitive regular expressions (e.g. title_regex \"^Save$\" for an exact label, \"Save|Opslaan\" for alternatives). Invalid regex falls back to case-insensitive substring. Returns element ids. "
                + "Prefer find_elements for plain substring matches. " + axPayloadBudgetDoc,
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "role_regex": .object(["type": .string("string")]),
                    "title_regex": .object(["type": .string("string")]),
                    "value_regex": .object(["type": .string("string")]),
                    "max_depth": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Traversal depth limit. Default 24 (project-wide AX default), max 64.")]),
                    "limit": .object(["type": .array([.string("integer"), .string("string")])]),
                    "fields": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Payload budget (v0.9): only emit these per-node keys. Default: all of id, role, title, value, position, size, depth.")
                    ]),
                    "interactive_only": .object([
                        "type": .string("boolean"),
                        "description": .string("Payload budget: keep only actionable roles (buttons, links, fields, checkboxes, …). Default false.")
                    ]),
                    "viewport_only": .object([
                        "type": .string("boolean"),
                        "description": .string("Payload budget: drop nodes whose frame lies outside the app's on-screen window bounds. Default false.")
                    ]),
                    "max_bytes": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Payload budget: soft cap on the encoded element/node bytes. Emission stops when the next item would exceed it and truncated=true is returned. Default: no cap.")
                    ])
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
            description: "List all windows of all running regular apps (or one app if pid is provided). "
                + "Every entry carries `window_id` (the window server's CGWindowID) — the PREFERRED way to target a window in capture_window, focus_window, move_window, resize_window, set_window_state, move_window_to_display, ground, ax_tree_augmented and ocr_screen, because pid+index is only valid within one list_windows response and pid+title_contains cannot tell two same-titled or untitled windows apart. "
                + "Also returns `display_index` (which display shows it, by window center), `z_order` (0 = frontmost among normal app windows on screen; null when minimized or off-Space), `is_focused` (the frontmost on-screen window, i.e. the one receiving keystrokes) and `title` (always present, \"\" when the window has none).",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")]), "description": .string("Optional — restrict to this app.")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "focus_window",
            description: "Bring a window to the front by window_id, or by pid + window index (both from list_windows). "
                + ToolRegistry.windowIDPrecedenceNote,
            inputSchema: schema(
                properties: withWindowIDProperty([
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "index": .object(["type": .array([.string("integer"), .string("string")])])
                ])
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
            description: "List top-level menubar titles for an app — useful for discovery before click_menu_path. Omit pid to use the frontmost app.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])])
                ]
            )
        ),
        MCPToolDefinition(
            name: "clipboard_read",
            description: "Read the clipboard. type=text (default) returns the plain-text flattening; rtf / html return those flavours as strings; image returns {width, height, bytes} plus a PNG written to output_path or the temp dir — with inline=true and no output_path it returns base64 only and writes no file; files returns the file-URL paths; all inventories every available UTI as {uti, bytes, large} (bulk image/video/archive flavours report bytes=null, large=true instead of being copied just to be measured — ask for type=image to get those bytes). Always returns the raw `types` list.",
            inputSchema: schema(
                properties: [
                    "type": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("text"), .string("rtf"), .string("html"),
                            .string("image"), .string("files"), .string("all")
                        ]),
                        "description": .string("Which representation to read. Default \"text\".")
                    ]),
                    "inline": .object([
                        "type": .string("boolean"),
                        "description": .string("type=image only: also return the PNG as base64. Off by default — a Retina screenshot easily blows past the client's context limit.")
                    ]),
                    "output_path": .object([
                        "type": .string("string"),
                        "description": .string("type=image only: where to write the PNG. Must be under an allowed root (TMPDIR, ~/Desktop, ~/Documents, ~/Downloads, ~/Pictures). Defaults to a temp file.")
                    ])
                ]
            )
        ),
        MCPToolDefinition(
            name: "clipboard_write",
            description: "Replace the clipboard with any combination of text, html, rtf, an image file (image_path — PNG/JPEG, published as both public.png and public.tiff) and file URLs (files: absolute paths, what Finder and file-drop targets expect). Multiple representations may be given at once and land in a single transaction, so a paste target picks the richest flavour it understands. At least one is required; a bad path fails before the clipboard is touched.",
            inputSchema: schema(
                properties: [
                    "text": .object(["type": .string("string")]),
                    "html": .object(["type": .string("string")]),
                    "rtf": .object(["type": .string("string")]),
                    "image_path": .object([
                        "type": .string("string"),
                        "description": .string("Path to a PNG or JPEG file to put on the pasteboard as an image.")
                    ]),
                    "files": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")]),
                        "description": .string("Absolute paths of existing files to put on the pasteboard as file URLs.")
                    ])
                ]
            )
        ),
        MCPToolDefinition(
            name: "permissions_status",
            description: "Report every macOS privacy permission mac-control-mcp uses (accessibility, screen_recording, calendar, reminders, contacts, location, microphone) plus responsible_app: the app macOS attributes the requests to (e.g. Claude, ChatGPT, Terminal). Grants belong to THAT app, so status differs per MCP client. Also lists categories that will be refused without a prompt because an entitlement is missing.",
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
        if let dead = noSuchProcessResult(pid: pid, tool: "get_ui_tree") { return dead }
        let maxDepth = AXDepth.resolve(arguments["max_depth"]?.intValue)
        // Node cap = element-cache capacity, so every returned node gets
        // a live id. (Before v0.8.3 the walk allowed 5000 nodes but the
        // 2000-entry cache evicted the first nodes' ids while storing the
        // rest, so ids beyond 2000 nodes were already dangling.)
        let nodeCap = elementCache.maxEntries
        let nodes = await accessibility.treeWalk(pid: pid, maxDepth: maxDepth, nodeCap: nodeCap)
        let budget = PayloadOptions(arguments, known: AXPayload.treeFields)

        // v0.9 (C-9): interactive_only / viewport_only shape the tree
        // BEFORE ids are minted, so the cache isn't filled with nodes the
        // caller will never see.
        let windows = budget.viewportOnly ? await accessibility.windowFrames(pid: pid) : []
        let shape = nodes.map {
            AXPayload.ShapeNode(role: $0.role, frame: Self.frame(position: $0.position, size: $0.size), childIndices: $0.childIndices)
        }
        let kept = AXPayload.keptIndices(
            nodes: shape,
            interactiveOnly: budget.interactiveOnly,
            viewportOnly: budget.viewportOnly,
            windows: windows
        )
        // One actor hop + one eviction pass for the whole tree (see
        // ElementCache.storeMany) instead of one per node.
        let ids = await elementCache.storeMany(withPaths: kept.map { (nodes[$0].element, nodes[$0].path) }, pid: pid)

        // Encode → measure → (if the cap bit) drop the tail and RE-MAP.
        // Remapping has to happen against the surviving set, otherwise a
        // truncated tree keeps child indices pointing past the end of
        // the array it ships (review fix 3). Nodes are in preorder, so
        // dropping a suffix always keeps the root.
        func encode(_ survivors: [Int]) -> [JSONValue] {
            let children = AXPayload.remapChildren(nodes: shape, kept: survivors)
            return survivors.enumerated().map { position, original in
                encodeTreeNode(
                    node: nodes[original],
                    id: ids[position],
                    childIndices: children[position],
                    fields: budget.fields
                )
            }
        }
        var emitted = encode(kept)
        let budgeted = AXPayload.applyByteBudget(emitted, maxBytes: budget.maxBytes)
        if budgeted.truncated {
            emitted = encode(Array(kept.prefix(budgeted.items.count)))
        } else {
            emitted = budgeted.items
        }

        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "pid": .number(Double(pid)),
            "max_depth": .number(Double(maxDepth)),
            "count": .number(Double(emitted.count)),
            "node_cap": .number(Double(nodeCap)),
            "node_cap_reached": .bool(nodes.count >= nodeCap),
            "nodes": .array(emitted)
        ]
        budget.annotate(
            &payload,
            maxDepthUsed: maxDepth,
            nodesVisited: nodes.count,
            truncated: budgeted.truncated || nodes.count >= nodeCap
        )
        return successResult(
            "Walked \(nodes.count) nodes (max_depth=\(maxDepth)), returned \(emitted.count).",
            payload
        )
    }

    /// CGRect for a node's position+size, or nil when either is absent.
    static func frame(position: AccessibilityController.Point?, size: AccessibilityController.Size?) -> CGRect? {
        guard let position, let size else { return nil }
        return CGRect(x: position.x, y: position.y, width: size.width, height: size.height)
    }

    func callFindElements(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("find_elements requires a positive integer pid.")
        }
        if let dead = noSuchProcessResult(pid: pid, tool: "find_elements") { return dead }
        let role = arguments["role"]?.stringValue
        let title = arguments["title"]?.stringValue
        let value = arguments["value"]?.stringValue
        let maxDepth = AXDepth.resolve(arguments["max_depth"]?.intValue)
        let limit = max(1, min(arguments["limit"]?.intValue ?? 100, 500))
        let exact = AXPayload.flag(arguments["exact"])
        let budget = PayloadOptions(arguments, known: AXPayload.elementFields)

        let matches = await accessibility.findElements(
            pid: pid, role: role, title: title, value: value,
            exact: exact, maxDepth: maxDepth, limit: limit
        )

        let encoded = await encodeMatches(matches, pid: pid, budget: budget)
        let budgeted = AXPayload.applyByteBudget(encoded, maxBytes: budget.maxBytes)

        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "pid": .number(Double(pid)),
            "count": .number(Double(budgeted.items.count)),
            "limit_reached": .bool(matches.count >= limit),
            "elements": .array(budgeted.items)
        ]
        budget.annotate(&payload, maxDepthUsed: maxDepth, nodesVisited: matches.count, truncated: budgeted.truncated)
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
        let maxDepth = AXDepth.resolve(arguments["max_depth"]?.intValue)
        let limit = max(1, min(arguments["limit"]?.intValue ?? 200, 500))
        let budget = PayloadOptions(arguments, known: AXPayload.elementFields)

        let result = await accessibility.queryElements(
            pid: pid,
            rolePattern: rolePattern,
            titlePattern: titlePattern,
            valuePattern: valuePattern,
            maxDepth: maxDepth,
            limit: limit
        )
        let matches = result.matches

        let encoded = await encodeMatches(matches, pid: pid, budget: budget)
        let budgeted = AXPayload.applyByteBudget(encoded, maxBytes: budget.maxBytes)

        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "pid": .number(Double(pid)),
            "count": .number(Double(budgeted.items.count)),
            "elements": .array(budgeted.items)
        ]
        budget.annotate(&payload, maxDepthUsed: maxDepth, nodesVisited: matches.count, truncated: budgeted.truncated)
        // v0.9 (A-13): surface exactly which pattern(s) failed to
        // compile as regex and fell back to substring matching, so a
        // typo'd pattern isn't indistinguishable from a genuine no-match.
        if !result.invalidPatterns.isEmpty {
            payload["regex_invalid"] = .bool(true)
            payload["matching"] = .string("substring")
            payload["invalid_patterns"] = .array(result.invalidPatterns.map {
                .object([
                    "field": .string($0.field),
                    "pattern": .string($0.pattern),
                    "error": .string($0.error)
                ])
            })
        }
        if let hint = await axEmptyHint(pid: pid, whenEmpty: matches.isEmpty) {
            payload["ax_tree_hint"] = .string(hint)
        }
        return successResult("Query returned \(matches.count) elements.", payload)
    }

    func callGetElementAttributes(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let id = arguments["element_id"]?.stringValue, !id.isEmpty else {
            return invalidArgument("get_element_attributes requires element_id.")
        }
        let element: AXUIElement
        switch await elementCache.resolveLive(id) {
        case .resolved(let resolved): element = resolved
        case .unknown: return unknownElementResult(id)
        case .stale(let reason): return staleElementResult(id, reason: reason)
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
        let element: AXUIElement
        switch await elementCache.resolveLive(id) {
        case .resolved(let resolved): element = resolved
        case .unknown: return unknownElementResult(id)
        case .stale(let reason): return staleElementResult(id, reason: reason)
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
        let element: AXUIElement
        switch await elementCache.resolveLive(id) {
        case .resolved(let resolved): element = resolved
        case .unknown: return unknownElementResult(id)
        case .stale(let reason): return staleElementResult(id, reason: reason)
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
        let handle: WindowHandle
        switch await windowHandle(arguments, tool: "focus_window") {
        case .success(let resolved): handle = resolved
        case .failure(let box): return box.result
        }
        let success = await windows.focusWindow(pid: handle.pid, index: handle.index)
        var payload: [String: JSONValue] = ["ok": .bool(success)]
        payload.merge(handle.payload) { existing, _ in existing }
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
        let pid: pid_t
        let pidArg = arguments["pid"]
        if let pidArg, pidArg != .null {
            // A real value was supplied — it must be a valid positive integer.
            guard let provided = parsePID(pidArg) else {
                return invalidArgument("list_menu_titles: pid must be a positive integer.")
            }
            pid = provided
        } else {
            // Omitted OR explicit null → frontmost app, matching list_windows.
            guard let app = NSWorkspace.shared.frontmostApplication else {
                return errorResult("No frontmost application found.", ["ok": .bool(false)])
            }
            pid = app.processIdentifier
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

    /// v0.9 (C-10): `type` selects the representation. Absent/`text` keeps
    /// the pre-0.9 response shape byte-for-byte (`ok`, `text`, `types`) so
    /// existing callers are unaffected.
    func callClipboardRead(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let rawType = arguments["type"]?.stringValue
        guard let kind = ClipboardController.ReadKind.parse(rawType) else {
            return invalidArgument(
                "clipboard_read: unknown type \"\(rawType ?? "")\". Valid values: \(ClipboardController.ReadKind.allNames)."
            )
        }
        let inline = arguments["inline"]?.boolValue ?? false
        let outputPath = arguments["output_path"]?.stringValue

        do {
            let result = try await clipboard.readRich(kind: kind, inline: inline, outputPath: outputPath)
            var payload: [String: JSONValue] = [
                "ok": .bool(true),
                "kind": .string(result.kind),
                "types": .array(result.types.map(JSONValue.string))
            ]
            // `text` stays present-but-null for the default read so the
            // v0.8 response shape is unchanged.
            if kind == .text || kind == .all {
                payload["text"] = result.text.map(JSONValue.string) ?? .null
            }
            if let rtf = result.rtf { payload["rtf"] = .string(rtf) }
            if let html = result.html { payload["html"] = .string(html) }
            if let files = result.files {
                payload["files"] = .array(files.map(JSONValue.string))
                payload["file_count"] = .number(Double(files.count))
            }
            if let image = result.image {
                var imagePayload: [String: JSONValue] = [
                    "width": .number(Double(image.width)),
                    "height": .number(Double(image.height)),
                    "bytes": .number(Double(image.bytes)),
                    "format": .string("png")
                ]
                imagePayload["path"] = image.path.map(JSONValue.string) ?? .null
                if let base64 = image.base64 { imagePayload["inline_base64"] = .string(base64) }
                payload["image"] = .object(imagePayload)
            }
            if let available = result.available {
                payload["available"] = .array(available.map { info in
                    .object([
                        "uti": .string(info.uti),
                        // null == deliberately not copied to be measured
                        // (image/video/archive flavours): `large` says so.
                        "bytes": info.bytes.map { JSONValue.number(Double($0)) } ?? .null,
                        "large": .bool(info.large)
                    ])
                })
            }
            return successResult("Read clipboard (\(result.kind)).", payload)
        } catch let error as ClipboardController.ClipboardError {
            var payload: [String: JSONValue] = [
                "ok": .bool(false),
                "kind": .string(kind.rawValue),
                "error_code": .string(Self.clipboardErrorCode(error))
            ]
            if let reason = error.reason { payload["reason"] = .string(reason) }
            return errorResult(error.description, payload)
        } catch {
            return errorResult(
                "clipboard_read failed: \(error)",
                ["ok": .bool(false), "kind": .string(kind.rawValue)]
            )
        }
    }

    func callClipboardWrite(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        var request = ClipboardController.WriteRequest(
            text: arguments["text"]?.stringValue,
            html: arguments["html"]?.stringValue,
            rtf: arguments["rtf"]?.stringValue,
            imagePath: arguments["image_path"]?.stringValue
        )
        if let raw = arguments["files"], raw != .null {
            guard let array = raw.arrayValue else {
                return invalidArgument("clipboard_write: files must be an array of file paths.")
            }
            let paths = array.compactMap { $0.stringValue }
            guard paths.count == array.count else {
                return invalidArgument("clipboard_write: every entry in files must be a string path.")
            }
            request.files = paths
        }

        guard !request.isEmpty else {
            return invalidArgument(
                "clipboard_write requires at least one of: text, html, rtf, image_path, files."
            )
        }

        do {
            let result = try await clipboard.writeRich(request)
            var payload: [String: JSONValue] = [
                "ok": .bool(true),
                "wrote": .array(result.wrote.map(JSONValue.string)),
                "types": .array(result.types.map(JSONValue.string))
            ]
            if let text = request.text {
                payload["length"] = .number(Double(text.count))
            }
            return successResult("Clipboard updated (\(result.wrote.joined(separator: ", "))).", payload)
        } catch let error as ClipboardController.ClipboardError {
            var payload: [String: JSONValue] = [
                "ok": .bool(false),
                "error_code": .string(Self.clipboardErrorCode(error))
            ]
            if let reason = error.reason { payload["reason"] = .string(reason) }
            return errorResult(error.description, payload)
        } catch {
            return errorResult("clipboard_write failed: \(error)", ["ok": .bool(false)])
        }
    }

    /// Stable machine-readable codes for the clipboard failures, in the
    /// same spirit as the browser/permission error codes elsewhere.
    ///
    /// v0.9 review follow-up (HIGH, #7): `notRegularFile` and
    /// `fileTooLarge` are surfaced as `invalid_argument` with a
    /// distinguishing `reason` field (`not_regular_file` /
    /// `file_too_large`) rather than their own error codes, per the
    /// review's requested shape — the caller passed a bad argument
    /// (a path that isn't usable input), not something server-internal.
    static func clipboardErrorCode(_ error: ClipboardController.ClipboardError) -> String {
        switch error {
        case .nothingToWrite: return "invalid_argument"
        case .fileNotFound: return "file_not_found"
        case .unreadableImage: return "unreadable_image"
        case .imageEncodeFailed: return "image_encode_failed"
        case .noData: return "no_such_representation"
        case .invalidPath: return "invalid_path"
        case .pasteboardRejectedWrite: return "pasteboard_rejected"
        case .notRegularFile: return "invalid_argument"
        case .fileTooLarge: return "invalid_argument"
        }
    }

    // MARK: - JSON encoders

    /// The id was never ours (or has been evicted after 5 minutes idle).
    func unknownElementResult(_ id: String) -> ToolCallResult {
        errorResult(
            "Unknown or expired element_id.",
            [
                "ok": .bool(false),
                "element_id": .string(id),
                "error_code": .string("unknown_element_id"),
                "hint": .string("Element ids expire after 5 minutes idle. Re-run find_elements / find_element / get_ui_tree to get a current id.")
            ]
        )
    }

    /// v0.9 (C-5, review fix 1+2): the id WAS ours, but the element it
    /// named is gone and could not be re-identified with certainty —
    /// its process was replaced, or its AX path no longer matches the
    /// fingerprint recorded at capture time. We refuse rather than act
    /// on a plausible-looking neighbour.
    func staleElementResult(_ id: String, reason: String) -> ToolCallResult {
        errorResult(
            "Stale element_id: \(reason).",
            [
                "ok": .bool(false),
                "element_id": .string(id),
                "error_code": .string("stale_element"),
                "reason": .string(reason),
                "hint": .string("The UI changed under this handle. Re-run find_elements (or get_ui_tree) and use the fresh id — the server deliberately does not guess at a replacement element.")
            ]
        )
    }

    /// Store every match under a stable, content-addressed id (C-5) and
    /// encode it through the payload budget (C-9).
    func encodeMatches(
        _ matches: [AccessibilityController.Match],
        pid: pid_t,
        budget: PayloadOptions
    ) async -> [JSONValue] {
        let filtered = matches.filter { match in
            let passesRole = !budget.interactiveOnly || AXPayload.isInteractive(role: match.info.role)
            return passesRole
        }
        let windows = budget.viewportOnly ? await accessibility.windowFrames(pid: pid) : []
        let visible = budget.viewportOnly
            ? filtered.filter {
                AXPayload.isInViewport(
                    frame: Self.frame(position: $0.info.position, size: $0.info.size),
                    windows: windows
                )
            }
            : filtered
        let ids = await elementCache.storeMany(withPaths: visible.map { ($0.element, $0.path) }, pid: pid)
        return zip(visible, ids).map { match, id in
            encodeElement(info: match.info, id: id, fields: budget.fields)
        }
    }

    func encodeElement(
        info: AccessibilityController.ElementInfo,
        id: String?,
        fields: Set<String>? = nil
    ) -> JSONValue {
        var dict: [String: JSONValue] = [
            "role": info.role.map(JSONValue.string) ?? .null,
            "title": info.title.map(JSONValue.string) ?? .null,
            "value": info.value.map(JSONValue.string) ?? .null
        ]
        // list_elements has never returned ids; omit the key entirely
        // there rather than emitting a null an agent might try to use.
        if let id { dict["id"] = .string(id) }
        if let p = info.position {
            dict["position"] = .object(["x": .number(p.x), "y": .number(p.y)])
        }
        if let s = info.size {
            dict["size"] = .object(["width": .number(s.width), "height": .number(s.height)])
        }
        if let d = info.depth {
            dict["depth"] = .number(Double(d))
        }
        return .object(AXPayload.project(dict, fields: fields))
    }

    private func encodeTreeNode(
        node: AccessibilityController.TreeNode,
        id: String?,
        childIndices: [Int],
        fields: Set<String>?
    ) -> JSONValue {
        var dict: [String: JSONValue] = [
            "id": id.map(JSONValue.string) ?? .null,
            "role": node.role.map(JSONValue.string) ?? .null,
            "title": node.title.map(JSONValue.string) ?? .null,
            "value": node.value.map(JSONValue.string) ?? .null,
            "depth": .number(Double(node.depth)),
            "children": .array(childIndices.map { .number(Double($0)) })
        ]
        if let p = node.position {
            dict["position"] = .object(["x": .number(p.x), "y": .number(p.y)])
        }
        if let s = node.size {
            dict["size"] = .object(["width": .number(s.width), "height": .number(s.height)])
        }
        return .object(AXPayload.project(dict, fields: fields))
    }
}

/// Parsed `fields` / `interactive_only` / `viewport_only` / `max_bytes`
/// arguments plus the bookkeeping every budgeted response echoes
/// (v0.9 C-9 / B-11). Defaults reproduce pre-v0.9 output exactly.
struct PayloadOptions: Sendable {
    let fields: Set<String>?
    let unknownFields: [String]
    let interactiveOnly: Bool
    let viewportOnly: Bool
    let maxBytes: Int?

    init(_ arguments: [String: JSONValue], known: [String]) {
        let resolved = AXPayload.resolveFields(arguments["fields"], known: known)
        self.fields = resolved.fields
        self.unknownFields = resolved.unknown
        self.interactiveOnly = AXPayload.flag(arguments["interactive_only"])
        self.viewportOnly = AXPayload.flag(arguments["viewport_only"])
        self.maxBytes = AXPayload.resolveMaxBytes(arguments["max_bytes"])
    }

    /// Add `bytes` / `max_depth_used` / `nodes_visited` / `truncated` to
    /// a finished payload. `bytes` is the encoded size of the response
    /// payload itself (excluding the `bytes` field, which is added
    /// last) — i.e. what this call cost the caller's context.
    func annotate(
        _ payload: inout [String: JSONValue],
        maxDepthUsed: Int,
        nodesVisited: Int,
        truncated: Bool
    ) {
        payload["max_depth_used"] = .number(Double(maxDepthUsed))
        payload["nodes_visited"] = .number(Double(nodesVisited))
        payload["truncated"] = .bool(truncated)
        if !unknownFields.isEmpty {
            payload["unknown_fields"] = .array(unknownFields.map(JSONValue.string))
        }
        payload["bytes"] = .number(Double(AXPayload.encodedSize(.object(payload))))
    }
}
