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

// ToolRegistry holds actor references and a few stateless JSON helpers.
// All mutable state lives inside the referenced actors, so the registry
// itself is effectively a Sendable dispatch table. @unchecked Sendable
// is used here because the Swift 6 compiler cannot yet see through this
// "bag of actors" pattern automatically.
final class ToolRegistry: @unchecked Sendable {
    let accessibility: AccessibilityController
    let elementCache: ElementCache
    let windows: WindowController
    let menus: MenuController
    let clipboard: ClipboardController
    let browser: BrowserController
    let screen: ScreenController
    let mouse: MouseController
    let appLifecycle: AppLifecycleController
    let displays: DisplayController
    let fileDialog: FileDialogController
    let system: SystemController
    let spotlight: SpotlightController

    init(
        accessibility: AccessibilityController,
        elementCache: ElementCache = ElementCache(),
        windows: WindowController = WindowController(),
        menus: MenuController = MenuController(),
        clipboard: ClipboardController = ClipboardController(),
        browser: BrowserController = BrowserController(),
        screen: ScreenController = ScreenController(),
        mouse: MouseController = MouseController(),
        appLifecycle: AppLifecycleController = AppLifecycleController(),
        displays: DisplayController = DisplayController(),
        fileDialog: FileDialogController = FileDialogController(),
        system: SystemController = SystemController(),
        spotlight: SpotlightController = SpotlightController()
    ) {
        self.accessibility = accessibility
        self.elementCache = elementCache
        self.windows = windows
        self.menus = menus
        self.clipboard = clipboard
        self.browser = browser
        self.screen = screen
        self.mouse = mouse
        self.appLifecycle = appLifecycle
        self.displays = displays
        self.fileDialog = fileDialog
        self.system = system
        self.spotlight = spotlight
    }

    var toolDefinitions: [MCPToolDefinition] {
        Self.definitions + Self.definitionsV2 + Self.definitionsV2Phase2 +
            Self.definitionsV2Phase3 + Self.definitionsV2Phase4 + Self.definitionsV2Phase5
    }

    // MARK: - Tool dispatch
    //
    // MAINTAINABILITY NOTE (Codex v1 LOW):
    // This single switch statement now dispatches 63 tools. Splitting it
    // into a `[String: @Sendable (Arguments) -> ToolCallResult]` table per
    // phase file would reduce surface area and make tool registration
    // self-contained. The split is intentionally deferred until we add
    // more tools OR the switch exceeds ~100 cases — doing it now would
    // churn 63 case arms for little immediate benefit and complicate the
    // actor-hop story for tools that need async access to specific
    // controllers.
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
        case "get_ui_tree":
            return await callGetUITree(arguments)
        case "find_elements":
            return await callFindElements(arguments)
        case "query_elements":
            return await callQueryElements(arguments)
        case "get_element_attributes":
            return await callGetElementAttributes(arguments)
        case "set_element_attribute":
            return await callSetElementAttribute(arguments)
        case "perform_element_action":
            return await callPerformElementAction(arguments)
        case "list_windows":
            return await callListWindows(arguments)
        case "focus_window":
            return await callFocusWindow(arguments)
        case "click_menu_path":
            return await callClickMenuPath(arguments)
        case "list_menu_titles":
            return await callListMenuTitles(arguments)
        case "clipboard_read":
            return await callClipboardRead()
        case "clipboard_write":
            return await callClipboardWrite(arguments)
        case "permissions_status":
            return await callPermissionsStatus()
        case "probe_ax_tree":
            return await callProbeAXTree(arguments)
        case "browser_list_tabs":
            return await callBrowserListTabs(arguments)
        case "browser_get_active_tab":
            return await callBrowserActiveTab(arguments)
        case "browser_navigate":
            return await callBrowserNavigate(arguments)
        case "browser_eval_js":
            return await callBrowserEvalJS(arguments)
        case "capture_screen":
            return await callCaptureScreen(arguments)
        case "ocr_screen":
            return await callOCRScreen(arguments)
        case "mouse_event":
            return await callMouseEvent(arguments)
        case "drag_and_drop":
            return await callDragAndDrop(arguments)
        case "scroll":
            return await callScroll(arguments)
        case "launch_app":
            return await callLaunchApp(arguments)
        case "activate_app":
            return await callActivateApp(arguments)
        case "quit_app":
            return await callQuitApp(arguments)
        case "wait_for_element":
            return await callWaitForElement(arguments)
        case "list_displays":
            return await callListDisplays()
        case "convert_coordinates":
            return await callConvertCoordinates(arguments)
        case "move_window":
            return await callMoveWindow(arguments)
        case "resize_window":
            return await callResizeWindow(arguments)
        case "set_window_state":
            return await callSetWindowState(arguments)
        case "file_dialog_set_path":
            return await callFileDialogSetPath(arguments)
        case "file_dialog_select_item":
            return await callFileDialogSelectItem(arguments)
        case "file_dialog_confirm":
            return await callFileDialogConfirm(arguments)
        case "browser_new_tab":
            return await callBrowserNewTab(arguments)
        case "browser_close_tab":
            return await callBrowserCloseTab(arguments)
        case "capture_window":
            return await callCaptureWindow(arguments)
        case "capture_display":
            return await callCaptureDisplay(arguments)
        case "list_menu_paths":
            return await callListMenuPaths(arguments)
        case "spotlight_search":
            return await callSpotlightSearch(arguments)
        case "spotlight_open_result":
            return await callSpotlightOpenResult(arguments)
        case "set_volume":
            return await callSetVolume(arguments)
        case "set_dark_mode":
            return await callSetDarkMode(arguments)
        case "key_down":
            return await callKeyDown(arguments)
        case "key_up":
            return await callKeyUp(arguments)
        case "press_key_sequence":
            return await callPressKeySequence(arguments)
        case "wait_for_window":
            return await callWaitForWindow(arguments)
        case "wait_for_app":
            return await callWaitForApp(arguments)
        case "wait_for_file_dialog":
            return await callWaitForFileDialog(arguments)
        case "move_window_to_display":
            return await callMoveWindowToDisplay(arguments)
        case "request_permissions":
            return await callRequestPermissions()
        case "scroll_to_element":
            return await callScrollToElement(arguments)
        case "force_quit_app":
            // Alias: force_quit_app → quit_app with force=true
            var forced = arguments
            forced["force"] = .bool(true)
            return await callQuitApp(forced)
        case "file_dialog_cancel":
            // Alias: file_dialog_cancel → file_dialog_confirm with cancel=true
            return await callFileDialogConfirm(["cancel": .bool(true)])
        case "clipboard_clear":
            await clipboard.clear()
            return successResult("Clipboard cleared.", ["ok": .bool(true)])
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

        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "pid": .number(Double(pid)),
            "max_depth": .number(Double(maxDepth)),
            "count": .number(Double(elements.count)),
            "elements": encodeAsJSONValue(elements)
        ]
        if let hint = await axEmptyHint(pid: pid, whenEmpty: elements.isEmpty) {
            payload["ax_tree_hint"] = .string(hint)
        }
        return successResult("Found \(elements.count) actionable elements.", payload)
    }

    private func callFindElement(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("find_element requires a positive integer pid.")
        }

        let role = arguments["role"]?.stringValue
        let title = arguments["title"]?.stringValue

        guard let element = await accessibility.findElement(pid: pid, role: role, title: title) else {
            var payload: [String: JSONValue] = [
                "ok": .bool(false),
                "pid": .number(Double(pid)),
                "role": role.map(JSONValue.string) ?? .null,
                "title": title.map(JSONValue.string) ?? .null
            ]
            if let hint = await axEmptyHint(pid: pid, whenEmpty: true) {
                payload["ax_tree_hint"] = .string(hint)
            }
            return errorResult("No matching element found.", payload)
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

    /// BUG-FIX v0.2.6 #8: when a find/query/list returned empty we used
    /// to leave the caller guessing whether their filter was wrong or
    /// the app itself is AX-headless. We now probe the root of the app
    /// and surface a specific hint for Telegram-like apps (empty AX
    /// tree entirely) so agents stop spinning on queries that cannot
    /// succeed for the target bundle. Package-visible so `Tools+V2`
    /// can reuse it for findElements / queryElements.
    func axEmptyHint(pid: pid_t, whenEmpty: Bool) async -> String? {
        guard whenEmpty else { return nil }
        let health = await accessibility.probeAXTree(pid: pid)
        guard !health.hasAXTree else { return nil }
        return health.hint
    }

    /// Standalone probe tool — callers that want to check AX health
    /// *before* firing queries can call `probe_ax_tree` to know up front
    /// whether the app even has an accessibility surface.
    private func callProbeAXTree(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("probe_ax_tree requires a positive integer pid.")
        }
        let health = await accessibility.probeAXTree(pid: pid)
        var payload: [String: JSONValue] = [
            "ok": .bool(true),
            "pid": .number(Double(pid)),
            "has_ax_tree": .bool(health.hasAXTree),
            "child_count": .number(Double(health.childCount)),
            "window_count": .number(Double(health.windowCount))
        ]
        if let hint = health.hint { payload["hint"] = .string(hint) }
        let msg = health.hasAXTree
            ? "AX tree present (\(health.childCount) children, \(health.windowCount) windows)."
            : "App exposes no AX tree — see hint."
        return successResult(msg, payload)
    }

    private func callClick(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let pid = parsePID(arguments["pid"])

        if let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue {
            let success = await accessibility.click(at: CGPoint(x: CGFloat(x), y: CGFloat(y)))
            var payload: [String: JSONValue] = [
                "x": .number(x),
                "y": .number(y)
            ]
            if let pid {
                payload["pid"] = .number(Double(pid))
            }
            if success {
                return successResult(
                    "Clicked at (\(x), \(y)).",
                    payload.merging(["ok": .bool(true)]) { _, new in new }
                )
            }

            return errorResult(
                "Failed to click at (\(x), \(y)).",
                payload.merging(["ok": .bool(false)]) { _, new in new }
            )
        }

        guard arguments["x"] == nil, arguments["y"] == nil else {
            return invalidArgument("click requires both x and y when using coordinates.")
        }

        guard let pid else {
            return invalidArgument("click requires a positive integer pid when clicking by role/title.")
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

        // BUG-FIX v0.2.6 #6: let callers pick the typing strategy.
        // `auto` (default) now tries clipboard → keys → ax for event
        // fidelity on React/Angular SPAs. See TypeStrategy docs in
        // AccessibilityController.swift.
        let strategyArg = arguments["strategy"]?.stringValue?.lowercased() ?? "auto"
        guard let strategy = AccessibilityController.TypeStrategy(rawValue: strategyArg) else {
            return invalidArgument(
                "type_text strategy must be one of: auto, clipboard, keys, ax (got '\(strategyArg)')."
            )
        }

        let result = await accessibility.typeText(text: text, strategy: strategy)
        if result.success {
            return successResult(
                "Text typed using \(result.strategy).",
                [
                    "ok": .bool(true),
                    "strategy": .string(result.strategy),
                    "requested_strategy": .string(strategy.rawValue),
                    "text_length": .number(Double(text.count))
                ]
            )
        }

        return errorResult(
            "Failed to type text (requested strategy=\(strategy.rawValue)).",
            [
                "ok": .bool(false),
                "strategy": .string(result.strategy),
                "requested_strategy": .string(strategy.rawValue),
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

    func parsePID(_ value: JSONValue?) -> pid_t? {
        guard let integer = value?.intValue, integer > 0, integer <= Int(Int32.max) else {
            return nil
        }
        return pid_t(integer)
    }

    struct ToolInputError: Error, CustomStringConvertible {
        let description: String
    }

    /// Parse a JSON modifiers array. Delegates name→flag mapping to the
    /// shared `ModifierMap` (see Tools+V2Phase5.swift) so key_down/key_up/
    /// press_key_sequence and press_key all use the exact same parsing.
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

            if let flag = ModifierMap.flag(for: modifier) {
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

    func invalidArgument(_ message: String) -> ToolCallResult {
        errorResult(message, ["ok": .bool(false), "error": .string(message)])
    }

    func errorResult(_ message: String, _ payload: [String: JSONValue] = [:]) -> ToolCallResult {
        ToolCallResult(text: message, structuredContent: .object(payload), isError: true)
    }

    func successResult(_ message: String, _ payload: [String: JSONValue]) -> ToolCallResult {
        ToolCallResult(text: message, structuredContent: .object(payload), isError: false)
    }

    static func schema(properties: [String: JSONValue], required: [String] = []) -> JSONValue {
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
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Target process ID.")
                    ]),
                    "max_depth": .object([
                        "type": .array([.string("integer"), .string("string")]),
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
                        "type": .array([.string("integer"), .string("string")]),
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
                        "type": .array([.string("integer"), .string("string")]),
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
                ]
            )
        ),
        MCPToolDefinition(
            name: "type_text",
            description: "Type text into the currently focused field. "
                + "Strategies: auto (clipboard → keys → ax, default; best for React/Angular SPAs), "
                + "clipboard (paste events), keys (CGEvent unicode), ax (AX set_value last-resort).",
            inputSchema: schema(
                properties: [
                    "text": .object([
                        "type": .string("string")
                    ]),
                    "strategy": .object([
                        "type": .string("string"),
                        "enum": .array([
                            .string("auto"),
                            .string("clipboard"),
                            .string("keys"),
                            .string("ax")
                        ]),
                        "default": .string("auto")
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
                        "type": .array([.string("integer"), .string("string")])
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

enum KeyCodeMap {
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
        "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        // Physical modifier keys — for key_down/key_up to hold/release
        // shift/control/etc. Separate from ModifierMap (which maps names
        // to CGEventFlags for combining with other keys).
        "shift": 56, "left_shift": 56, "right_shift": 60,
        "control": 59, "left_control": 59, "right_control": 62, "ctrl": 59,
        "option": 58, "left_option": 58, "right_option": 61, "alt": 58,
        "command": 55, "left_command": 55, "right_command": 54, "cmd": 55,
        "fn": 63, "function": 63,
        "caps_lock": 57, "caps": 57
    ]

    static func keyCode(for key: String) -> CGKeyCode? {
        let normalized = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return values[normalized]
    }
}
