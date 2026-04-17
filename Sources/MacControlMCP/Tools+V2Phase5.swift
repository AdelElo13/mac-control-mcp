import Foundation
import CoreGraphics
import AppKit
import ApplicationServices

// MARK: - Tool definitions (v0.2.0 Phase 5: SHOULD tier)

extension ToolRegistry {
    static let definitionsV2Phase5: [MCPToolDefinition] = [
        MCPToolDefinition(
            name: "browser_new_tab",
            description: "Open a new tab in Safari or Chrome's front window, optionally navigating to a URL.",
            inputSchema: schema(
                properties: [
                    "browser": .object(["type": .string("string")]),
                    "url": .object(["type": .string("string")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "browser_close_tab",
            description: "Close a tab by window/tab index, or the current tab when omitted.",
            inputSchema: schema(
                properties: [
                    "browser": .object(["type": .string("string")]),
                    "window_index": .object(["type": .string("integer")]),
                    "tab_index": .object(["type": .string("integer")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "capture_window",
            description: "Screenshot a specific window of an app by PID (and optional title filter).",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .string("integer")]),
                    "title_contains": .object(["type": .string("string")]),
                    "output_path": .object(["type": .string("string")])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "capture_display",
            description: "Screenshot a specific display by its index from list_displays.",
            inputSchema: schema(
                properties: [
                    "display_index": .object(["type": .string("integer")]),
                    "output_path": .object(["type": .string("string")])
                ],
                required: ["display_index"]
            )
        ),
        MCPToolDefinition(
            name: "list_menu_paths",
            description: "Enumerate every menu path in an app's menubar, up to max_depth.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .string("integer")]),
                    "max_depth": .object(["type": .string("integer")])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "spotlight_search",
            description: "Open Spotlight (Cmd+Space) and type a query, leaving the popover ready for follow-up.",
            inputSchema: schema(
                properties: [
                    "query": .object(["type": .string("string")])
                ],
                required: ["query"]
            )
        ),
        MCPToolDefinition(
            name: "spotlight_open_result",
            description: "Confirm an active Spotlight query; pass index to pick the nth result.",
            inputSchema: schema(
                properties: [
                    "index": .object([
                        "type": .string("integer"),
                        "description": .string("1-based index. Default 1.")
                    ])
                ]
            )
        ),
        MCPToolDefinition(
            name: "set_volume",
            description: "Set system output volume 0-100. Optional 'muted' toggles the output mute flag.",
            inputSchema: schema(
                properties: [
                    "volume": .object(["type": .string("integer")]),
                    "muted": .object(["type": .string("boolean")])
                ],
                required: ["volume"]
            )
        ),
        MCPToolDefinition(
            name: "set_dark_mode",
            description: "Enable or disable macOS Dark Mode (System Events automation permission required).",
            inputSchema: schema(
                properties: [
                    "enabled": .object(["type": .string("boolean")])
                ],
                required: ["enabled"]
            )
        ),
        MCPToolDefinition(
            name: "key_down",
            description: "Post a key-down event without releasing. Pair with key_up.",
            inputSchema: schema(
                properties: [
                    "key": .object(["type": .string("string")]),
                    "modifiers": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ])
                ],
                required: ["key"]
            )
        ),
        MCPToolDefinition(
            name: "key_up",
            description: "Post a key-up event to release a previously held key.",
            inputSchema: schema(
                properties: [
                    "key": .object(["type": .string("string")]),
                    "modifiers": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ])
                ],
                required: ["key"]
            )
        ),
        MCPToolDefinition(
            name: "press_key_sequence",
            description: "Press multiple keys in order. Each step is {key, modifiers?}.",
            inputSchema: schema(
                properties: [
                    "steps": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("object"),
                            "properties": .object([
                                "key": .object(["type": .string("string")]),
                                "modifiers": .object([
                                    "type": .string("array"),
                                    "items": .object(["type": .string("string")])
                                ])
                            ]),
                            "required": .array([.string("key")])
                        ])
                    ]),
                    "delay_ms": .object(["type": .string("integer")])
                ],
                required: ["steps"]
            )
        ),
        MCPToolDefinition(
            name: "wait_for_window",
            description: "Poll until a window (matching optional title_contains) exists for an app, or timeout.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .string("integer")]),
                    "title_contains": .object(["type": .string("string")]),
                    "timeout_seconds": .object(["type": .string("number")]),
                    "poll_interval_ms": .object(["type": .string("integer")])
                ],
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "wait_for_app",
            description: "Poll until an app matching bundle_id or name is running, or timeout.",
            inputSchema: schema(
                properties: [
                    "bundle_id": .object(["type": .string("string")]),
                    "name": .object(["type": .string("string")]),
                    "timeout_seconds": .object(["type": .string("number")]),
                    "poll_interval_ms": .object(["type": .string("integer")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "wait_for_file_dialog",
            description: "Poll until an Open/Save dialog is visible in the focused app, or timeout.",
            inputSchema: schema(
                properties: [
                    "timeout_seconds": .object(["type": .string("number")]),
                    "poll_interval_ms": .object(["type": .string("integer")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "move_window_to_display",
            description: "Move a window to the specified display (by display_index), preserving its size.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .string("integer")]),
                    "index": .object(["type": .string("integer")]),
                    "display_index": .object(["type": .string("integer")])
                ],
                required: ["pid", "index", "display_index"]
            )
        ),
        MCPToolDefinition(
            name: "request_permissions",
            description: "Prompt the user for Accessibility permission (shows system dialog).",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "force_quit_app",
            description: "Force-terminate an app by PID or bundle ID. Equivalent to quit_app with force=true.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .string("integer")]),
                    "bundle_id": .object(["type": .string("string")])
                ]
            )
        ),
        MCPToolDefinition(
            name: "file_dialog_cancel",
            description: "Dismiss the frontmost Open/Save dialog via Escape. Equivalent to file_dialog_confirm with cancel=true.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "clipboard_clear",
            description: "Clear the clipboard.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "scroll_to_element",
            description: "Scroll until an AX element matching role/title is visible. Returns its element_id.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .string("integer")]),
                    "role": .object(["type": .string("string")]),
                    "title": .object(["type": .string("string")]),
                    "max_scrolls": .object(["type": .string("integer")])
                ],
                required: ["pid"]
            )
        )
    ]
}

// MARK: - Tool implementations (Phase 5)

extension ToolRegistry {
    func callBrowserNewTab(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let kind = BrowserController.Browser.detect(arguments["browser"]?.stringValue)
        let url = arguments["url"]?.stringValue
        let ok = await browser.newTab(browser: kind, url: url)
        let err = await browser.lastError
        let payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "browser": .string(kind.rawValue),
            "url": url.map(JSONValue.string) ?? .null,
            "error": err.map(JSONValue.string) ?? .null
        ]
        return ok
            ? successResult("New tab opened.", payload)
            : errorResult("Failed to open tab: \(err ?? "is the browser running?")", payload)
    }

    func callBrowserCloseTab(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let kind = BrowserController.Browser.detect(arguments["browser"]?.stringValue)
        let windowIndex = arguments["window_index"]?.intValue ?? 1
        let tabIndex = arguments["tab_index"]?.intValue
        let ok = await browser.closeTab(browser: kind, windowIndex: windowIndex, tabIndex: tabIndex)
        let err = await browser.lastError
        let payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "browser": .string(kind.rawValue),
            "window_index": .number(Double(windowIndex)),
            "tab_index": tabIndex.map { .number(Double($0)) } ?? .null,
            "error": err.map(JSONValue.string) ?? .null
        ]
        return ok
            ? successResult("Tab closed.", payload)
            : errorResult("Failed to close tab: \(err ?? "unknown error")", payload)
    }

    func callCaptureWindow(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("capture_window requires a positive integer pid.")
        }
        let title = arguments["title_contains"]?.stringValue
        let rawPath = arguments["output_path"]?.stringValue
        let outputPath: String?
        do {
            outputPath = try rawPath.map(PathValidator.validate)
        } catch {
            return invalidArgument(String(describing: error))
        }
        do {
            let capture = try await screen.captureWindow(ownerPID: pid, titleContains: title, outputPath: outputPath)
            return successResult(
                "Captured window to \(capture.path).",
                [
                    "ok": .bool(true),
                    "path": .string(capture.path),
                    "width": .number(Double(capture.width)),
                    "height": .number(Double(capture.height))
                ]
            )
        } catch {
            return errorResult(
                "Window capture failed: \(error).",
                ["ok": .bool(false), "pid": .number(Double(pid))]
            )
        }
    }

    func callCaptureDisplay(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let idx = arguments["display_index"]?.intValue, idx >= 0 else {
            return invalidArgument("capture_display requires a non-negative display_index.")
        }
        let list = await displays.list()
        guard idx < list.count else {
            return errorResult("display_index out of range — found \(list.count) display(s).", ["ok": .bool(false)])
        }
        let rawPath = arguments["output_path"]?.stringValue
        let outputPath: String?
        do {
            outputPath = try rawPath.map(PathValidator.validate)
        } catch {
            return invalidArgument(String(describing: error))
        }
        do {
            let capture = try await screen.captureDisplayByID(CGDirectDisplayID(list[idx].id), outputPath: outputPath)
            return successResult(
                "Captured display \(idx) to \(capture.path).",
                [
                    "ok": .bool(true),
                    "path": .string(capture.path),
                    "width": .number(Double(capture.width)),
                    "height": .number(Double(capture.height)),
                    "display_index": .number(Double(idx))
                ]
            )
        } catch {
            return errorResult(
                "Display capture failed: \(error).",
                ["ok": .bool(false), "display_index": .number(Double(idx))]
            )
        }
    }

    func callListMenuPaths(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("list_menu_paths requires a positive integer pid.")
        }
        let maxDepth = max(1, min(arguments["max_depth"]?.intValue ?? 4, 8))
        let paths = await menus.listPaths(pid: pid, maxDepth: maxDepth)
        return successResult(
            "Enumerated \(paths.count) menu path(s).",
            [
                "ok": .bool(true),
                "count": .number(Double(paths.count)),
                "paths": .array(paths.map { .array($0.map(JSONValue.string)) })
            ]
        )
    }

    func callSpotlightSearch(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            return invalidArgument("spotlight_search requires query.")
        }
        let ok = await spotlight.search(query)
        return ok
            ? successResult("Spotlight opened.", ["ok": .bool(true), "query": .string(query)])
            : errorResult("Spotlight open failed.", ["ok": .bool(false)])
    }

    func callSpotlightOpenResult(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let index = max(1, arguments["index"]?.intValue ?? 1)
        let ok = await spotlight.openResult(index: index)
        return ok
            ? successResult("Result \(index) opened.", ["ok": .bool(true), "index": .number(Double(index))])
            : errorResult("Failed to open result.", ["ok": .bool(false)])
    }

    func callSetVolume(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let volume = arguments["volume"]?.intValue else {
            return invalidArgument("set_volume requires volume (0-100).")
        }
        let muted: Bool? = {
            if case .bool(let b) = arguments["muted"] ?? .null { return b }
            return nil
        }()
        let ok = await system.setVolume(volume, muted: muted)
        let err = await system.lastError
        return ok
            ? successResult("Volume set to \(max(0, min(100, volume))).", [
                "ok": .bool(true),
                "volume": .number(Double(max(0, min(100, volume)))),
                "muted": muted.map(JSONValue.bool) ?? .null
              ])
            : errorResult("Volume change failed: \(err ?? "unknown error")",
                          ["ok": .bool(false), "error": err.map(JSONValue.string) ?? .null])
    }

    func callSetDarkMode(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard case .bool(let enabled) = arguments["enabled"] ?? .null else {
            return invalidArgument("set_dark_mode requires enabled (boolean).")
        }
        let ok = await system.setDarkMode(enabled: enabled)
        let err = await system.lastError
        return ok
            ? successResult(enabled ? "Dark mode enabled." : "Light mode enabled.",
                            ["ok": .bool(true), "enabled": .bool(enabled)])
            : errorResult("Dark mode toggle failed: \(err ?? "check Automation permissions")",
                          ["ok": .bool(false), "error": err.map(JSONValue.string) ?? .null])
    }

    func callKeyDown(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        await keyEvent(arguments: arguments, down: true, label: "key_down")
    }

    func callKeyUp(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        await keyEvent(arguments: arguments, down: false, label: "key_up")
    }

    private func keyEvent(arguments: [String: JSONValue], down: Bool, label: String) async -> ToolCallResult {
        guard let key = arguments["key"]?.stringValue, !key.isEmpty else {
            return invalidArgument("\(label) requires key.")
        }
        guard let code = KeyCodeMap.keyCode(for: key) else {
            return invalidArgument("Unsupported key '\(key)'.")
        }

        let modStrings = arguments["modifiers"]?.arrayValue?.compactMap { $0.stringValue } ?? []
        var modifiers: [CGEventFlags] = []
        for s in modStrings {
            guard let flag = ModifierMap.flag(for: s) else {
                return invalidArgument("Unknown modifier '\(s)'.")
            }
            modifiers.append(flag)
        }

        let ok = down
            ? await accessibility.keyDown(keyCode: code, modifiers: modifiers)
            : await accessibility.keyUp(keyCode: code, modifiers: modifiers)
        let payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "key": .string(key),
            "modifiers": .array(modStrings.map(JSONValue.string))
        ]
        return ok
            ? successResult("\(label) posted.", payload)
            : errorResult("\(label) failed.", payload)
    }

    func callPressKeySequence(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let stepsRaw = arguments["steps"]?.arrayValue, !stepsRaw.isEmpty else {
            return invalidArgument("press_key_sequence requires non-empty steps array.")
        }
        var parsed: [(CGKeyCode, [CGEventFlags])] = []
        for entry in stepsRaw {
            guard case .object(let obj) = entry,
                  let key = obj["key"]?.stringValue,
                  let code = KeyCodeMap.keyCode(for: key)
            else {
                return invalidArgument("Each step requires a known key.")
            }
            var flags: [CGEventFlags] = []
            for mod in obj["modifiers"]?.arrayValue?.compactMap({ $0.stringValue }) ?? [] {
                guard let f = ModifierMap.flag(for: mod) else {
                    return invalidArgument("Unknown modifier '\(mod)'.")
                }
                flags.append(f)
            }
            parsed.append((code, flags))
        }

        let delayMs = max(0, arguments["delay_ms"]?.intValue ?? 30)
        let ok = await accessibility.pressKeySequence(parsed, delay: TimeInterval(delayMs) / 1000.0)
        return ok
            ? successResult("Pressed \(parsed.count) step(s).", [
                "ok": .bool(true),
                "steps": .number(Double(parsed.count))
              ])
            : errorResult("Sequence failed partway.", ["ok": .bool(false)])
    }

    func callWaitForWindow(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("wait_for_window requires a positive integer pid.")
        }
        let titleFilter = arguments["title_contains"]?.stringValue?.lowercased()
        let timeout = min(max(arguments["timeout_seconds"]?.doubleValue ?? 5.0, 0.1), 60.0)
        let intervalMs = max(arguments["poll_interval_ms"]?.intValue ?? 250, 50)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            let list = await windows.listAppWindows(pid: pid)
            if let match = list.first(where: { w in
                guard let filter = titleFilter, !filter.isEmpty else { return true }
                return (w.title ?? "").lowercased().contains(filter)
            }) {
                return successResult(
                    "Window appeared.",
                    [
                        "ok": .bool(true),
                        "pid": .number(Double(pid)),
                        "window": encodeAsJSONValue(match)
                    ]
                )
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
            } catch {
                return errorResult(
                    "Cancelled during poll.",
                    ["ok": .bool(false), "cancelled": .bool(true)]
                )
            }
        }
        return errorResult(
            "Timed out after \(timeout)s.",
            ["ok": .bool(false), "timed_out": .bool(true)]
        )
    }

    func callWaitForApp(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let bundleID = arguments["bundle_id"]?.stringValue
        let name = arguments["name"]?.stringValue?.lowercased()
        if (bundleID == nil || bundleID?.isEmpty == true) && (name == nil || name?.isEmpty == true) {
            return invalidArgument("wait_for_app requires bundle_id or name.")
        }
        let timeout = min(max(arguments["timeout_seconds"]?.doubleValue ?? 5.0, 0.1), 60.0)
        let intervalMs = max(arguments["poll_interval_ms"]?.intValue ?? 250, 50)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            // NSWorkspace is driven through the main actor — looping through
            // runningApplications off-main was flagged by Codex v2. We grab
            // a snapshot (pid/name/bundle id triples) on the main thread and
            // search it here instead.
            struct Snapshot: Sendable {
                let pid: pid_t
                let name: String?
                let bundleID: String?
            }
            let snapshot = await MainActor.run {
                NSWorkspace.shared.runningApplications.map {
                    Snapshot(pid: $0.processIdentifier, name: $0.localizedName, bundleID: $0.bundleIdentifier)
                }
            }
            for app in snapshot {
                let matchesBundle = bundleID.map { app.bundleID == $0 } ?? false
                let matchesName = name.map { (app.name ?? "").lowercased() == $0 } ?? false
                if matchesBundle || matchesName {
                    return successResult(
                        "App appeared.",
                        [
                            "ok": .bool(true),
                            "pid": .number(Double(app.pid)),
                            "name": app.name.map(JSONValue.string) ?? .null,
                            "bundle_id": app.bundleID.map(JSONValue.string) ?? .null
                        ]
                    )
                }
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
            } catch {
                return errorResult(
                    "Cancelled during poll.",
                    ["ok": .bool(false), "cancelled": .bool(true)]
                )
            }
        }
        return errorResult(
            "Timed out after \(timeout)s.",
            ["ok": .bool(false), "timed_out": .bool(true)]
        )
    }

    func callWaitForFileDialog(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let timeout = min(max(arguments["timeout_seconds"]?.doubleValue ?? 5.0, 0.1), 60.0)
        let intervalMs = max(arguments["poll_interval_ms"]?.intValue ?? 250, 50)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            if let front = NSWorkspace.shared.frontmostApplication {
                let pid = front.processIdentifier
                // An Open/Save dialog appears as an AXSheet with role AXSheet
                // under the focused window, containing an AXPopUpButton for the
                // sidebar + AXTextField for path. We detect by searching for
                // any AXSheet.
                let sheets = await accessibility.findElements(
                    pid: pid, role: "AXSheet", title: nil, value: nil,
                    maxDepth: 8, limit: 1
                )
                if !sheets.isEmpty {
                    return successResult(
                        "File dialog visible.",
                        [
                            "ok": .bool(true),
                            "pid": .number(Double(pid)),
                            "app": front.localizedName.map(JSONValue.string) ?? .null
                        ]
                    )
                }
            }
            do {
                try await Task.sleep(nanoseconds: UInt64(intervalMs) * 1_000_000)
            } catch {
                return errorResult(
                    "Cancelled during poll.",
                    ["ok": .bool(false), "cancelled": .bool(true)]
                )
            }
        }
        return errorResult(
            "Timed out after \(timeout)s.",
            ["ok": .bool(false), "timed_out": .bool(true)]
        )
    }

    func callMoveWindowToDisplay(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("move_window_to_display requires a positive integer pid.")
        }
        guard let index = arguments["index"]?.intValue, index >= 0 else {
            return invalidArgument("move_window_to_display requires a non-negative index.")
        }
        guard let displayIdx = arguments["display_index"]?.intValue, displayIdx >= 0 else {
            return invalidArgument("move_window_to_display requires display_index.")
        }
        let list = await displays.list()
        guard displayIdx < list.count else {
            return errorResult("display_index out of range — found \(list.count) display(s).",
                               ["ok": .bool(false)])
        }
        let target = list[displayIdx]
        let ok = await windows.moveWindow(pid: pid, index: index, to: CGPoint(x: target.x, y: target.y))
        let payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "pid": .number(Double(pid)),
            "index": .number(Double(index)),
            "display_index": .number(Double(displayIdx)),
            "x": .number(target.x),
            "y": .number(target.y)
        ]
        return ok
            ? successResult("Window moved to display \(displayIdx).", payload)
            : errorResult("Window move failed.", payload)
    }

    func callRequestPermissions() async -> ToolCallResult {
        let granted = await accessibility.requestPermission()
        return successResult(
            granted ? "Permission already granted." : "Permission dialog shown (user action required).",
            ["ok": .bool(true), "accessibility": .bool(granted)]
        )
    }

    func callScrollToElement(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("scroll_to_element requires a positive integer pid.")
        }
        let role = arguments["role"]?.stringValue
        let title = arguments["title"]?.stringValue
        let maxScrolls = max(1, min(arguments["max_scrolls"]?.intValue ?? 30, 200))

        for attempt in 0..<maxScrolls {
            if let element = await accessibility.findElement(pid: pid, role: role, title: title) {
                let info = await accessibility.getElementInfo(element: element)
                let id = await elementCache.store(element, pid: pid)
                return successResult(
                    "Element visible after \(attempt) scroll(s).",
                    [
                        "ok": .bool(true),
                        "attempts": .number(Double(attempt)),
                        "element_id": .string(id),
                        "role": info.role.map(JSONValue.string) ?? .null,
                        "title": info.title.map(JSONValue.string) ?? .null
                    ]
                )
            }
            _ = await mouse.scroll(deltaX: 0, deltaY: -40)
            do {
                try await Task.sleep(nanoseconds: 80_000_000)
            } catch {
                return errorResult(
                    "Cancelled during scroll.",
                    ["ok": .bool(false), "cancelled": .bool(true)]
                )
            }
        }
        return errorResult(
            "Element not found after \(maxScrolls) scroll attempts.",
            ["ok": .bool(false)]
        )
    }
}

// MARK: - Modifier helper

enum ModifierMap {
    static func flag(for value: String) -> CGEventFlags? {
        switch value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "command", "cmd": return .maskCommand
        case "shift": return .maskShift
        case "option", "alt": return .maskAlternate
        case "control", "ctrl": return .maskControl
        case "fn", "function": return .maskSecondaryFn
        default: return nil
        }
    }
}
