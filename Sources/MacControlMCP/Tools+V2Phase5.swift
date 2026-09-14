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
                    "window_index": .object(["type": .array([.string("integer"), .string("string")])]),
                    "tab_index": .object(["type": .array([.string("integer"), .string("string")])])
                ]
            )
        ),
        MCPToolDefinition(
            name: "capture_window",
            description: "Screenshot ONE window of an app by pid (optional title_contains). Picks the largest onscreen, layer-0 window matching the filter and captures just that window via ScreenCaptureKit — it works when the window is occluded or on another Space (legacy CG fallbacks otherwise). "
                + "Use this instead of capture_screen + cropping when you want a specific app window; use capture_screen for the whole main display or an arbitrary region. "
                + "Returns path/width/height plus format, scale, source size, pixels_per_point (image pixels per window point, from the window's top-left) and window_bounds. "
                + "pixels_per_point and window_bounds derive from the window bounds read from the window server immediately BEFORE the capture (geometry_source=window_bounds_before_capture); if the window moves or resizes in between, re-capture before mapping image coordinates to clicks. Supports max_width / format / quality.",
            inputSchema: schema(
                properties: withImageOutputProperties([
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "title_contains": .object(["type": .string("string")]),
                    "output_path": .object(["type": .string("string")])
                ]),
                required: ["pid"]
            )
        ),
        MCPToolDefinition(
            name: "capture_display",
            description: "Screenshot a whole display by its index from list_displays — the way to capture a secondary display (capture_screen and capture_screen_v2 only cover the main display). Supports max_width / format / quality; returns scale and pixels_per_point.",
            inputSchema: schema(
                properties: withImageOutputProperties([
                    "display_index": .object(["type": .array([.string("integer"), .string("string")])]),
                    "output_path": .object(["type": .string("string")])
                ]),
                required: ["display_index"]
            )
        ),
        MCPToolDefinition(
            name: "list_menu_paths",
            description: "Enumerate every menu path in an app's menubar, up to max_depth.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "max_depth": .object(["type": .array([.string("integer"), .string("string")])])
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
                        "type": .array([.string("integer"), .string("string")]),
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
                    "volume": .object(["type": .array([.string("integer"), .string("string")])]),
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
            description: "Post a key-down event without releasing. Pair with key_up. "
                + "Always lands on the frontmost app — pass expected_app/expected_window to "
                + "abort instead of posting to the wrong window if focus changed.",
            inputSchema: schema(
                properties: [
                    "key": .object(["type": .string("string")]),
                    "modifiers": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ]),
                    "expected_app": .object([
                        "type": .string("string"),
                        "description": .string("Bundle id or localized app name expected to be frontmost. On mismatch, nothing is posted.")
                    ]),
                    "expected_window": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive substring expected in the focused window title. On mismatch, nothing is posted.")
                    ])
                ],
                required: ["key"]
            )
        ),
        MCPToolDefinition(
            name: "key_up",
            description: "Post a key-up event to release a previously held key. "
                + "Always lands on the frontmost app — pass expected_app/expected_window to "
                + "abort instead of posting to the wrong window if focus changed.",
            inputSchema: schema(
                properties: [
                    "key": .object(["type": .string("string")]),
                    "modifiers": .object([
                        "type": .string("array"),
                        "items": .object(["type": .string("string")])
                    ]),
                    "expected_app": .object([
                        "type": .string("string"),
                        "description": .string("Bundle id or localized app name expected to be frontmost. On mismatch, nothing is posted.")
                    ]),
                    "expected_window": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive substring expected in the focused window title. On mismatch, nothing is posted.")
                    ])
                ],
                required: ["key"]
            )
        ),
        MCPToolDefinition(
            name: "press_key_sequence",
            description: "Press multiple keys in order. Each step is {key, modifiers?}. "
                + "Always lands on the frontmost app — pass expected_app/expected_window to "
                + "abort the whole sequence instead of sending it to the wrong window if focus "
                + "changed (checked once immediately before the first key).",
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
                    "delay_ms": .object(["type": .array([.string("integer"), .string("string")])]),
                    "expected_app": .object([
                        "type": .string("string"),
                        "description": .string("Bundle id or localized app name expected to be frontmost. On mismatch, nothing is sent.")
                    ]),
                    "expected_window": .object([
                        "type": .string("string"),
                        "description": .string("Case-insensitive substring expected in the focused window title. On mismatch, nothing is sent.")
                    ])
                ],
                required: ["steps"]
            )
        ),
        MCPToolDefinition(
            name: "wait_for_window",
            description: "Poll until a window (matching optional title_contains) exists for an app, or timeout.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "title_contains": .object(["type": .string("string")]),
                    "timeout_seconds": .object(["type": .string("number")]),
                    "poll_interval_ms": .object(["type": .array([.string("integer"), .string("string")])])
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
                    "poll_interval_ms": .object(["type": .array([.string("integer"), .string("string")])])
                ]
            )
        ),
        MCPToolDefinition(
            name: "wait_for_file_dialog",
            description: "Poll until an Open/Save dialog is visible in the focused app, or timeout.",
            inputSchema: schema(
                properties: [
                    "timeout_seconds": .object(["type": .string("number")]),
                    "poll_interval_ms": .object(["type": .array([.string("integer"), .string("string")])])
                ]
            )
        ),
        MCPToolDefinition(
            name: "move_window_to_display",
            description: "Move a window to the specified display (by display_index), preserving its size.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "index": .object(["type": .array([.string("integer"), .string("string")])]),
                    "display_index": .object(["type": .array([.string("integer"), .string("string")])])
                ],
                required: ["pid", "index", "display_index"]
            )
        ),
        MCPToolDefinition(
            name: "request_permissions",
            description: "Trigger macOS permission prompts WITHOUT waiting for the user's answer; returns the current status immediately. Default categories: accessibility + folders (Desktop/Documents/Downloads). Call permissions_status after the user has responded.",
            inputSchema: schema(
                properties: [
                    "categories": .object([
                        "type": .string("array"),
                        "items": .object([
                            "type": .string("string"),
                            "enum": .array(ToolRegistry.requestablePermissionCategories.map(JSONValue.string))
                        ]),
                        "description": .string("Which prompts to trigger. Already-decided categories are skipped.")
                    ])
                ]
            )
        ),
        MCPToolDefinition(
            name: "force_quit_app",
            description: "Force-terminate an app by PID or bundle ID. Equivalent to quit_app with force=true.",
            inputSchema: schema(
                properties: [
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
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
                    "pid": .object(["type": .array([.string("integer"), .string("string")])]),
                    "role": .object(["type": .string("string")]),
                    "title": .object(["type": .string("string")]),
                    "max_scrolls": .object(["type": .array([.string("integer"), .string("string")])])
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
        // Single actor call returns ok + classification together — see
        // BrowserController.classifiedError for why a separate follow-up
        // read would race under concurrent tool calls.
        let outcome = await browser.newTab(browser: kind, url: url)
        let ok = outcome.ok
        let classification = outcome.classification
        var payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "browser": .string(kind.rawValue),
            "url": url.map(JSONValue.string) ?? .null,
            "error": classification.map { JSONValue.string($0.error) } ?? .null
        ]
        if let c = classification {
            payload["error_code"] = .string(c.errorCode)
            if let hint = c.hint { payload["hint"] = .string(hint) }
            if let pane = c.pane { payload["pane"] = .string(pane) }
        }
        return ok
            ? successResult("New tab opened.", payload)
            : errorResult("Failed to open tab: \(classification?.error ?? "is the browser running?")", payload)
    }

    func callBrowserCloseTab(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let kind = BrowserController.Browser.detect(arguments["browser"]?.stringValue)
        let windowIndex = arguments["window_index"]?.intValue ?? 1
        let tabIndex = arguments["tab_index"]?.intValue
        let outcome = await browser.closeTab(browser: kind, windowIndex: windowIndex, tabIndex: tabIndex)
        let ok = outcome.ok
        let classification = outcome.classification
        var payload: [String: JSONValue] = [
            "ok": .bool(ok),
            "browser": .string(kind.rawValue),
            "window_index": .number(Double(windowIndex)),
            "tab_index": tabIndex.map { .number(Double($0)) } ?? .null,
            "error": classification.map { JSONValue.string($0.error) } ?? .null
        ]
        if let c = classification {
            payload["error_code"] = .string(c.errorCode)
            if let hint = c.hint { payload["hint"] = .string(hint) }
            if let pane = c.pane { payload["pane"] = .string(pane) }
        }
        return ok
            ? successResult("Tab closed.", payload)
            : errorResult("Failed to close tab: \(classification?.error ?? "unknown error")", payload)
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
        let options: ImageOutputOptions
        switch parseImageOutputOptions(arguments, tool: "capture_window") {
        case .success(let parsed): options = parsed
        case .failure(let box): return box.result
        }
        do {
            let capture = try await screen.captureWindow(
                ownerPID: pid, titleContains: title, outputPath: outputPath, options: options
            )
            var payload: [String: JSONValue] = [
                "ok": .bool(true),
                "path": .string(capture.path),
                "width": .number(Double(capture.width)),
                "height": .number(Double(capture.height))
            ]
            payload.merge(Self.captureMetadata(capture)) { existing, _ in existing }
            return successResult("Captured window to \(capture.path).", payload)
        } catch {
            var payload: [String: JSONValue] = [
                "ok": .bool(false),
                "pid": .number(Double(pid))
            ]
            var errorCode = "failed"
            var hint = "If this is a permission issue, add mac-control-mcp to System Settings → Privacy & Security → Screen Recording and restart. If the window is on another Space, focus it first via focus_window."

            if let screenError = error as? ScreenController.ScreenError {
                switch screenError {
                case .noMatchingWindow:
                    errorCode = "not_found"
                    if let title, !title.isEmpty {
                        hint = "No window belonging to this pid matched title_contains=\"\(title)\". Call list_windows to see available titles for this pid."
                    } else {
                        hint = "No capturable window was found for this pid. Call list_windows to confirm the app has an open window."
                    }
                case .permissionDenied(_, let window):
                    errorCode = "permission_missing"
                    payload["pane"] = .string("screen_recording")
                    if let window {
                        payload["window"] = Self.windowPayload(window)
                    }
                case .windowNotOnCurrentSpace(let window):
                    errorCode = "failed"
                    payload["window"] = Self.windowPayload(window)
                    hint = "The chosen window is on a different macOS Space. Bring it to the foreground (or switch Spaces) before capturing."
                case .windowCaptureFailed(let window, _):
                    errorCode = "failed"
                    payload["window"] = Self.windowPayload(window)
                default:
                    errorCode = "failed"
                }
            }

            payload["error_code"] = .string(errorCode)
            payload["error"] = .string(String(describing: error))
            payload["hint"] = .string(hint)

            return errorResult("Window capture failed: \(error)", payload)
        }
    }

    /// Serializes `ScreenController.SelectedWindowInfo` into the JSON
    /// shape surfaced on capture_window failures, so the caller can see
    /// exactly which window was chosen (id, title, bounds, onscreen) and
    /// diagnose a wrong pick (e.g. a tiny helper window) instead of just
    /// getting "Screen capture failed."
    private static func windowPayload(_ window: ScreenController.SelectedWindowInfo) -> JSONValue {
        .object([
            "id": .number(Double(window.windowID)),
            "title": .string(window.title),
            "bounds": .object([
                "x": .number(window.bounds.origin.x),
                "y": .number(window.bounds.origin.y),
                "width": .number(window.bounds.width),
                "height": .number(window.bounds.height)
            ]),
            "onscreen": .bool(window.isOnscreen)
        ])
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
        let options: ImageOutputOptions
        switch parseImageOutputOptions(arguments, tool: "capture_display") {
        case .success(let parsed): options = parsed
        case .failure(let box): return box.result
        }
        do {
            let capture = try await screen.captureDisplayByID(
                CGDirectDisplayID(list[idx].id), outputPath: outputPath, options: options
            )
            var payload: [String: JSONValue] = [
                "ok": .bool(true),
                "path": .string(capture.path),
                "width": .number(Double(capture.width)),
                "height": .number(Double(capture.height)),
                "display_index": .number(Double(idx))
            ]
            payload.merge(Self.captureMetadata(capture)) { existing, _ in existing }
            return successResult("Captured display \(idx) to \(capture.path).", payload)
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
        let outcome = await spotlight.search(query)
        // Distinguish each failure mode so callers can react — a
        // metadatad outage is very different from "query ran, zero hits".
        switch outcome {
        case .emptyQuery:
            return invalidArgument("spotlight_search requires a non-empty query.")
        case .backendUnavailable:
            return errorResult(
                "Spotlight index backend refused to start (metadatad may be down or the search scope is unavailable).",
                ["ok": .bool(false), "reason": .string("backend_unavailable")]
            )
        case .timedOut:
            return errorResult(
                "Spotlight query timed out after 2s — index may be rebuilding or unresponsive.",
                ["ok": .bool(false), "reason": .string("timed_out")]
            )
        case .ok(let results):
            let previewJSON: [JSONValue] = results.map { p in
                .object([
                    "index": .number(Double(p.index)),
                    "title": .string(p.title),
                    "path": .string(p.path)
                ])
            }
            return successResult(
                "\(results.count) result(s) from Spotlight index.",
                [
                    "ok": .bool(true),
                    "query": .string(query),
                    "results": .array(previewJSON)
                ]
            )
        }
    }

    func callSpotlightOpenResult(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let index = max(1, arguments["index"]?.intValue ?? 1)
        // Results were cached by the last `spotlight_search` call.
        // Open via NSWorkspace with the recorded filesystem path —
        // deterministic, no keystrokes.
        let results = await spotlight.currentResults(limit: 10)
        if results.isEmpty {
            return errorResult(
                "No Spotlight results cached. Call spotlight_search first.",
                ["ok": .bool(false)]
            )
        }
        if index > results.count {
            return errorResult(
                "index \(index) out of range (cached \(results.count) result(s)).",
                ["ok": .bool(false), "cached": .number(Double(results.count))]
            )
        }
        let ok = await spotlight.openResult(index: index)
        return ok
            ? successResult("Result \(index) opened.", ["ok": .bool(true), "index": .number(Double(index)), "path": .string(results[index - 1].path)])
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

        if let mismatch = await checkFocusGuard(arguments) {
            return mismatch
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

        // Checked once immediately before injecting the whole sequence —
        // re-checking between every step would be the more thorough guard
        // but the sequence typically fires within milliseconds, so a
        // single check right before the first key covers the realistic
        // race (another app stealing focus between the caller's check
        // and this call).
        if let mismatch = await checkFocusGuard(arguments) {
            return mismatch
        }

        // Clamp the upper bound: delay_ms drives a Thread.sleep inside the
        // AccessibilityController actor, so a huge value would pin a
        // cooperative-pool thread for the whole duration.
        let delayMs = min(max(0, arguments["delay_ms"]?.intValue ?? 30), 5_000)
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
        let intervalMs = min(max(arguments["poll_interval_ms"]?.intValue ?? 250, 50), 60_000)
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
        let intervalMs = min(max(arguments["poll_interval_ms"]?.intValue ?? 250, 50), 60_000)
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
        let intervalMs = min(max(arguments["poll_interval_ms"]?.intValue ?? 250, 50), 60_000)
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            // Snapshot frontmost app state on MainActor (NSWorkspace is
            // main-actor-affine in strict concurrency mode).
            struct Front: Sendable { let pid: pid_t; let name: String? }
            let front = await MainActor.run { () -> Front? in
                guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
                return Front(pid: app.processIdentifier, name: app.localizedName)
            }
            if let front {
                let pid = front.pid
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
                            "app": front.name.map(JSONValue.string) ?? .null
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

    func callScrollToElement(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let pid = parsePID(arguments["pid"]) else {
            return invalidArgument("scroll_to_element requires a positive integer pid.")
        }
        let role = arguments["role"]?.stringValue
        let title = arguments["title"]?.stringValue
        // Require a real target. With both omitted, findElement matches the
        // first element (the app root) on attempt 0, so the tool reported
        // "visible after 0 scroll(s)" without scrolling or finding anything.
        guard (role?.isEmpty == false) || (title?.isEmpty == false) else {
            return invalidArgument("scroll_to_element requires at least one of 'role' or 'title'.")
        }
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
