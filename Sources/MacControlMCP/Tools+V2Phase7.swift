import Foundation
import CoreGraphics

// MARK: - Tool definitions (v0.4.0 Phase 7: no-gap Mac control surface)
//
// v0.4.0 pushes the tool count 70 → 95 with 25 tools that close the gap
// between "MCP can do AX / click / menu / capture / clipboard" (v0.3.0)
// and "MCP can do everything a human does on a Mac":
//
//   • System telemetry        (battery, cpu, memory, network, bluetooth, disk)
//   • Mission Control + Spaces
//   • Hardware toggles        (wifi, bluetooth, brightness, night shift)
//   • Apple Shortcuts         (list_shortcuts, run_shortcut, open_url_scheme)
//   • Finder actions          (reveal_in_finder, quick_look, trash_file)
//   • Notification + Control Center
//   • Right-click + double-click ergonomic wrappers
//
// Implementation philosophy: prefer Apple-shipped binaries
// (pmset, networksetup, shortcuts, system_profiler) over third-party
// dependencies. When a third-party CLI (blueutil, brightness, nightlight)
// is needed we return a structured hint with brew-install instructions
// rather than silently failing.

extension ToolRegistry {
    static let definitionsV2Phase7: [MCPToolDefinition] = [

        // MARK: System info

        MCPToolDefinition(
            name: "battery_status",
            description: "Return battery percentage, charging state, plugged-in state, and time-remaining estimate (desktop Macs report nil fields).",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "system_load",
            description: "Snapshot CPU user/sys/idle %, 1/5/15-minute load average, and physical memory used/free in MB.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "network_info",
            description: "Active Wi-Fi SSID + interface + every network interface's IP/MAC address.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "bluetooth_devices",
            description: "List paired Bluetooth devices — name, address, connected state. Slow (~1-2s) because it goes through system_profiler.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "disk_usage",
            description: "Per-volume disk usage — mount point, total/used/available GB, used %.",
            inputSchema: schema(properties: [:])
        ),

        // MARK: Mission Control + Spaces

        MCPToolDefinition(
            name: "mission_control",
            description: "Toggle Mission Control (all windows across Spaces). Equivalent of F3 / Ctrl+Up.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "app_expose",
            description: "Show every window of the frontmost app (App Exposé). Equivalent of Ctrl+Down.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "launchpad",
            description: "Open Launchpad. Equivalent of F4.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "show_desktop",
            description: "Reveal the desktop (F11 / Fn+F11).",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "switch_to_space",
            description: "Switch to macOS Space by index 1-9 via Ctrl+<N>. The Ctrl+N shortcut must be enabled in System Settings → Keyboard → Shortcuts → Mission Control; the tool returns hint='shortcut_disabled' if macOS swallows the event.",
            inputSchema: schema(
                properties: [
                    "index": .object([
                        "type": .array([.string("integer"), .string("string")]),
                        "description": .string("Space index 1-9.")
                    ])
                ],
                required: ["index"]
            )
        ),

        // MARK: Hardware toggles

        MCPToolDefinition(
            name: "wifi_set",
            description: "Turn Wi-Fi on, off, or toggle. Uses networksetup so no third-party CLI needed.",
            inputSchema: schema(
                properties: [
                    "state": .object([
                        "type": .string("string"),
                        "description": .string("on | off | toggle")
                    ])
                ],
                required: ["state"]
            )
        ),
        MCPToolDefinition(
            name: "bluetooth_set",
            description: "Turn Bluetooth on/off/toggle. Requires 'blueutil' (brew install blueutil) — returns a hint with install instructions when missing.",
            inputSchema: schema(
                properties: [
                    "state": .object([
                        "type": .string("string"),
                        "description": .string("on | off | toggle")
                    ])
                ],
                required: ["state"]
            )
        ),
        MCPToolDefinition(
            name: "set_brightness",
            description: "Set display brightness. Pass 'level' (0.0-1.0) for absolute control (requires 'brightness' CLI) OR 'direction' (up|down) for relative 4-step nudges via F14/F15.",
            inputSchema: schema(
                properties: [
                    "level": .object([
                        "type": .string("number"),
                        "description": .string("Absolute brightness 0.0-1.0. Requires brew install brightness.")
                    ]),
                    "direction": .object([
                        "type": .string("string"),
                        "description": .string("'up' or 'down' — nudges brightness without an extra CLI dependency.")
                    ])
                ]
            )
        ),
        MCPToolDefinition(
            name: "night_shift_set",
            description: "Turn Night Shift on/off/toggle. Requires 'nightlight' (brew install smudge/smudge/nightlight) — returns a hint when missing.",
            inputSchema: schema(
                properties: [
                    "state": .object([
                        "type": .string("string"),
                        "description": .string("on | off | toggle")
                    ])
                ],
                required: ["state"]
            )
        ),
        MCPToolDefinition(
            name: "open_airplay_preferences",
            description: "Open the Displays preference pane so the user can start/stop AirPlay mirroring. macOS has no sanctioned AirPlay CLI.",
            inputSchema: schema(properties: [:])
        ),

        // MARK: Apple Shortcuts + URL schemes

        MCPToolDefinition(
            name: "list_shortcuts",
            description: "Enumerate every shortcut defined in Shortcuts.app. Returns names that can be passed to run_shortcut.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "run_shortcut",
            description: "Invoke a Shortcut by its exact name. Optional 'input' is piped as the shortcut's 'Shortcut Input' magic variable.",
            inputSchema: schema(
                properties: [
                    "name": .object(["type": .string("string")]),
                    "input": .object(["type": .string("string")])
                ],
                required: ["name"]
            )
        ),
        MCPToolDefinition(
            name: "open_url_scheme",
            description: "Open any macOS URL scheme (x-apple.systempreferences://, shortcuts://, obsidian://, mailto:, ...). Wraps /usr/bin/open.",
            inputSchema: schema(
                properties: [
                    "url": .object(["type": .string("string")])
                ],
                required: ["url"]
            )
        ),

        // MARK: Finder actions

        MCPToolDefinition(
            name: "reveal_in_finder",
            description: "Open Finder and select the file at the given path (reveal ≠ open).",
            inputSchema: schema(
                properties: [
                    "path": .object(["type": .string("string")])
                ],
                required: ["path"]
            )
        ),
        MCPToolDefinition(
            name: "quick_look",
            description: "Open a QuickLook preview window for the given file. 'timeout_seconds' (default 10, max 120) keeps the preview on screen; after that it auto-closes.",
            inputSchema: schema(
                properties: [
                    "path": .object(["type": .string("string")]),
                    "timeout_seconds": .object(["type": .string("number")])
                ],
                required: ["path"]
            )
        ),
        MCPToolDefinition(
            name: "trash_file",
            description: "Move a file to the Trash (reversible). Restricted to paths under the user's home dir — refuses to trash system files.",
            inputSchema: schema(
                properties: [
                    "path": .object(["type": .string("string")])
                ],
                required: ["path"]
            )
        ),

        // MARK: Notification + Control Center

        MCPToolDefinition(
            name: "notification_center_toggle",
            description: "Open/close Notification Center (right-edge panel). Uses Fn+F12 via System Events.",
            inputSchema: schema(properties: [:])
        ),
        MCPToolDefinition(
            name: "control_center_toggle",
            description: "Open/close Control Center (the top-right icon popover). Clicks the menu-bar item directly.",
            inputSchema: schema(properties: [:])
        ),

        // MARK: Input ergonomic wrappers

        MCPToolDefinition(
            name: "right_click",
            description: "Right-click (secondary button) at coordinates. Ergonomic wrapper around mouse_event.",
            inputSchema: schema(
                properties: [
                    "x": .object(["type": .string("number")]),
                    "y": .object(["type": .string("number")])
                ],
                required: ["x", "y"]
            )
        ),
        MCPToolDefinition(
            name: "double_click",
            description: "Double-click at coordinates. Ergonomic wrapper around mouse_event with action='double_click'.",
            inputSchema: schema(
                properties: [
                    "x": .object(["type": .string("number")]),
                    "y": .object(["type": .string("number")]),
                    "button": .object(["type": .string("string")])
                ],
                required: ["x", "y"]
            )
        )
    ]

    // MARK: - Handlers

    // MARK: System info

    // Each system-info handler surfaces the new `Result<T>` envelope. When
    // the underlying subprocess fails we return `ok:false` with the stderr
    // tail, so agents can distinguish "battery is empty" from "pmset is
    // broken". v0.4.0's silent-success bug is closed here (Codex P0 #1).

    func callBatteryStatus() async -> ToolCallResult {
        let r = await systemInfo.battery()
        if r.ok, let data = r.data {
            return successResult("battery snapshot", [
                "ok": .bool(true),
                "battery": encodeAsJSONValue(data)
            ])
        }
        return errorResult("battery_status: \(r.error ?? "unknown error")", [
            "ok": .bool(false),
            "error": .string(r.error ?? ""),
            "exit_code": .number(Double(r.exitCode ?? -1))
        ])
    }

    func callSystemLoad() async -> ToolCallResult {
        let r = await systemInfo.load()
        if r.ok, let data = r.data {
            return successResult("cpu/mem load", [
                "ok": .bool(true),
                "load": encodeAsJSONValue(data)
            ])
        }
        return errorResult("system_load: \(r.error ?? "unknown error")", [
            "ok": .bool(false),
            "error": .string(r.error ?? ""),
            "exit_code": .number(Double(r.exitCode ?? -1))
        ])
    }

    func callNetworkInfo() async -> ToolCallResult {
        let r = await systemInfo.network()
        if r.ok, let data = r.data {
            return successResult("network snapshot", [
                "ok": .bool(true),
                "network": encodeAsJSONValue(data)
            ])
        }
        return errorResult("network_info: \(r.error ?? "unknown error")", [
            "ok": .bool(false),
            "error": .string(r.error ?? ""),
            "exit_code": .number(Double(r.exitCode ?? -1))
        ])
    }

    func callBluetoothDevices() async -> ToolCallResult {
        let r = await systemInfo.bluetoothSummary()
        if r.ok, let data = r.data {
            return successResult(
                "bluetooth: \(data.devices.count) device(s)",
                [
                    "ok": .bool(true),
                    "summary": encodeAsJSONValue(data)
                ]
            )
        }
        return errorResult("bluetooth_devices: \(r.error ?? "unknown error")", [
            "ok": .bool(false),
            "error": .string(r.error ?? ""),
            "exit_code": .number(Double(r.exitCode ?? -1))
        ])
    }

    func callDiskUsage() async -> ToolCallResult {
        let r = await systemInfo.diskUsage()
        if r.ok, let data = r.data {
            return successResult(
                "disk usage: \(data.volumes.count) volume(s)",
                [
                    "ok": .bool(true),
                    "usage": encodeAsJSONValue(data)
                ]
            )
        }
        return errorResult("disk_usage: \(r.error ?? "unknown error")", [
            "ok": .bool(false),
            "error": .string(r.error ?? ""),
            "exit_code": .number(Double(r.exitCode ?? -1))
        ])
    }

    // MARK: Mission Control

    func callMissionControl() async -> ToolCallResult {
        let r = await missionControl.trigger(.missionControl)
        return r.ok
            ? successResult("mission_control triggered", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult("mission_control failed", ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callAppExpose() async -> ToolCallResult {
        let r = await missionControl.trigger(.appExpose)
        return r.ok
            ? successResult("app_expose triggered", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult("app_expose failed", ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callLaunchpad() async -> ToolCallResult {
        let r = await missionControl.trigger(.launchpad)
        return r.ok
            ? successResult("launchpad triggered", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult("launchpad failed", ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callShowDesktop() async -> ToolCallResult {
        let r = await missionControl.trigger(.showDesktop)
        return r.ok
            ? successResult("show_desktop triggered", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult("show_desktop failed", ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callSwitchToSpace(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let idx = arguments["index"]?.intValue else {
            return invalidArgument("switch_to_space requires integer 'index' 1-9.")
        }
        let r = await missionControl.switchToSpace(index: idx)
        return r.ok
            ? successResult("switched to space \(idx)", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult("space switch failed", ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    // MARK: Hardware

    func callWifiSet(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let state = arguments["state"]?.stringValue else {
            return invalidArgument("wifi_set requires 'state' (on|off|toggle).")
        }
        // Codex v0.5.0 hardening (P1): wire tiered perms. Wi-Fi toggle is a
        // system-wide side-effect — requires `full` tier when enforcement
        // is on. Bundle ID "system:wifi" is a pseudo-bundle so the user
        // can grant/deny this specific capability separately from apps.
        if let gate = await enforceIfEnabled(bundleId: "system:wifi", required: .full) {
            return gate
        }
        let r = await hardware.wifiSet(state: state)
        return r.ok
            ? successResult("wifi → \(r.newState ?? "unknown")", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.hint ?? "wifi_set failed", ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callBluetoothSet(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let state = arguments["state"]?.stringValue else {
            return invalidArgument("bluetooth_set requires 'state' (on|off|toggle).")
        }
        if let gate = await enforceIfEnabled(bundleId: "system:bluetooth", required: .full) {
            return gate
        }
        let r = await hardware.bluetoothSet(state: state)
        return r.ok
            ? successResult("bluetooth → \(r.newState ?? "unknown")", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.hint ?? "bluetooth_set failed", ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callSetBrightness(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        let level = arguments["level"]?.doubleValue
        let dir = arguments["direction"]?.stringValue
        let r = await hardware.brightnessSet(level: level, direction: dir)
        return r.ok
            ? successResult("brightness set", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.hint ?? "set_brightness failed", ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callNightShiftSet(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let state = arguments["state"]?.stringValue else {
            return invalidArgument("night_shift_set requires 'state' (on|off|toggle).")
        }
        let r = await hardware.nightShiftSet(state: state)
        return r.ok
            ? successResult("night_shift → \(r.newState ?? "unknown")", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.hint ?? "night_shift_set failed", ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callOpenAirPlayPreferences() async -> ToolCallResult {
        let r = await hardware.airplayOpenPreferences()
        return r.ok
            ? successResult("displays preferences opened", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.hint ?? "open_airplay_preferences failed", ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    // MARK: Shortcuts

    func callListShortcuts() async -> ToolCallResult {
        let r = await shortcuts.list()
        if !r.ok {
            return errorResult(r.error ?? "list_shortcuts failed",
                               ["ok": .bool(false), "error": .string(r.error ?? "")])
        }
        return successResult(
            "found \(r.count) shortcut(s)",
            [
                "ok": .bool(true),
                "count": .number(Double(r.count)),
                "names": .array(r.names.map(JSONValue.string))
            ]
        )
    }

    func callRunShortcut(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
            return invalidArgument("run_shortcut requires 'name'.")
        }
        // Shortcuts are arbitrary user automations — treat as `full`.
        if let gate = await enforceIfEnabled(bundleId: "system:shortcuts", required: .full) {
            return gate
        }
        let input = arguments["input"]?.stringValue
        let r = await shortcuts.run(name: name, input: input)
        return r.ok
            ? successResult("shortcut '\(name)' completed",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult("shortcut '\(name)' failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callOpenURLScheme(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let url = arguments["url"]?.stringValue, !url.isEmpty else {
            return invalidArgument("open_url_scheme requires 'url'.")
        }
        if let gate = await enforceIfEnabled(bundleId: "system:url-scheme", required: .click) {
            return gate
        }
        let r = await shortcuts.openURL(url)
        if r.ok {
            return successResult("opened \(url)", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
        }
        // Distinguish "scheme blocked by policy" (security reject) from
        // "open failed for other reasons" (runtime error) in the response
        // text — both are isError but carry different hints.
        let msg = r.blocked
            ? "open_url_scheme blocked: \(r.blockReason ?? "policy")"
            : "open_url_scheme failed"
        return errorResult(msg, [
            "ok": .bool(false),
            "blocked": .bool(r.blocked),
            "result": encodeAsJSONValue(r)
        ])
    }

    // MARK: Finder

    func callRevealInFinder(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            return invalidArgument("reveal_in_finder requires 'path'.")
        }
        let r = await finder.reveal(path: path)
        return r.ok
            ? successResult("revealed \(path)", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "reveal_in_finder failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callQuickLook(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            return invalidArgument("quick_look requires 'path'.")
        }
        let t = arguments["timeout_seconds"]?.doubleValue ?? 10.0
        let r = await finder.quickLook(path: path, timeoutSeconds: t)
        return r.ok
            ? successResult("previewing \(path)", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "quick_look failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callTrashFile(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let path = arguments["path"]?.stringValue, !path.isEmpty else {
            return invalidArgument("trash_file requires 'path'.")
        }
        if let gate = await enforceIfEnabled(bundleId: "system:filesystem", required: .full) {
            return gate
        }
        let r = await finder.trash(path: path)
        return r.ok
            ? successResult("trashed \(path)", ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.error ?? "trash_file failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    // MARK: Notification + Control Center

    func callNotificationCenterToggle() async -> ToolCallResult {
        let r = await notificationCenter.toggle(.notificationCenter)
        return r.ok
            ? successResult("notification_center toggled",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.hint ?? "notification_center_toggle failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    func callControlCenterToggle() async -> ToolCallResult {
        let r = await notificationCenter.toggle(.controlCenter)
        return r.ok
            ? successResult("control_center toggled",
                            ["ok": .bool(true), "result": encodeAsJSONValue(r)])
            : errorResult(r.hint ?? "control_center_toggle failed",
                          ["ok": .bool(false), "result": encodeAsJSONValue(r)])
    }

    // MARK: Ergonomic click wrappers

    func callRightClick(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue else {
            return invalidArgument("right_click requires numeric x and y.")
        }
        let ok = await mouse.click(at: CGPoint(x: x, y: y), button: .right)
        return ok
            ? successResult("right click at (\(Int(x)),\(Int(y)))",
                            ["ok": .bool(true), "x": .number(x), "y": .number(y)])
            : errorResult("right_click failed", ["ok": .bool(false)])
    }

    func callDoubleClick(_ arguments: [String: JSONValue]) async -> ToolCallResult {
        guard let x = arguments["x"]?.doubleValue, let y = arguments["y"]?.doubleValue else {
            return invalidArgument("double_click requires numeric x and y.")
        }
        let btnRaw = arguments["button"]?.stringValue?.lowercased() ?? "left"
        let button: MouseController.Button
        switch btnRaw {
        case "right":  button = .right
        case "center": button = .center
        default:       button = .left
        }
        let ok = await mouse.doubleClick(at: CGPoint(x: x, y: y), button: button)
        return ok
            ? successResult("double-click at (\(Int(x)),\(Int(y)))",
                            ["ok": .bool(true), "x": .number(x), "y": .number(y), "button": .string(btnRaw)])
            : errorResult("double_click failed", ["ok": .bool(false)])
    }
}
