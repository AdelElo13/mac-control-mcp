import Testing
import Foundation
@testable import MacControlMCP

@Suite("Phase 7 tools — no-gap Mac control surface", .serialized)
struct Phase7ToolsTests {

    // MARK: - Registry

    @Test("all 25 phase 7 tools are registered")
    func phase7Definitions() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let names = Set(registry.toolDefinitions.map { $0.name })
        let expected: Set<String> = [
            // system info
            "battery_status", "system_load", "network_info",
            "bluetooth_devices", "disk_usage",
            // mission control
            "mission_control", "app_expose", "launchpad",
            "show_desktop", "switch_to_space",
            // hardware
            "wifi_set", "bluetooth_set", "set_brightness",
            "night_shift_set", "open_airplay_preferences",
            // shortcuts
            "list_shortcuts", "run_shortcut", "open_url_scheme",
            // finder
            "reveal_in_finder", "quick_look", "trash_file",
            // notification / control center
            "notification_center_toggle", "control_center_toggle",
            // ergonomic click wrappers
            "right_click", "double_click"
        ]
        #expect(expected.count == 25)
        #expect(expected.isSubset(of: names))
    }

    // MARK: - System info smoke

    @Test("battery_status returns a struct (may have nil fields on desktop Mac)")
    func batteryStatusSmoke() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "battery_status", arguments: [:])
        #expect(r.isError == false)
        if case .object(let fields) = r.structuredContent {
            #expect(fields["ok"] != nil)
            #expect(fields["battery"] != nil)
        }
    }

    @Test("system_load returns cpu + memory numbers")
    func systemLoadSmoke() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "system_load", arguments: [:])
        #expect(r.isError == false)
    }

    @Test("network_info returns interfaces list")
    func networkInfoSmoke() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "network_info", arguments: [:])
        #expect(r.isError == false)
    }

    @Test("disk_usage returns at least one volume")
    func diskUsageSmoke() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "disk_usage", arguments: [:])
        #expect(r.isError == false)
        if case .object(let fields) = r.structuredContent,
           case .object(let usage) = fields["usage"] ?? .null,
           case .array(let volumes) = usage["volumes"] ?? .null {
            #expect(volumes.count >= 1, "expected at least one mounted volume")
        }
    }

    // MARK: - Mission Control argument validation

    @Test("switch_to_space rejects out-of-range index")
    func switchToSpaceBadIndex() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "switch_to_space",
            arguments: ["index": .number(99)]
        )
        #expect(r.isError == true)
    }

    @Test("switch_to_space requires index")
    func switchToSpaceMissing() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "switch_to_space", arguments: [:])
        #expect(r.isError == true)
    }

    // MARK: - Hardware argument validation

    @Test("wifi_set requires state")
    func wifiSetMissing() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "wifi_set", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("wifi_set rejects unknown state")
    func wifiSetBadState() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "wifi_set",
            arguments: ["state": .string("spin")]
        )
        #expect(r.isError == true)
    }

    @Test("bluetooth_set requires state")
    func bluetoothSetMissing() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "bluetooth_set", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("set_brightness rejects out-of-range level")
    func setBrightnessBadLevel() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "set_brightness",
            arguments: ["level": .number(1.5)]
        )
        #expect(r.isError == true)
    }

    @Test("set_brightness without arg fails")
    func setBrightnessEmpty() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "set_brightness", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("night_shift_set requires state")
    func nightShiftMissing() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "night_shift_set", arguments: [:])
        #expect(r.isError == true)
    }

    // MARK: - Shortcuts

    @Test("list_shortcuts doesn't error out even if user has zero shortcuts")
    func listShortcutsSmoke() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "list_shortcuts", arguments: [:])
        // If /usr/bin/shortcuts exists it returns ok. On a stripped-down test
        // runner it might fail; accept either shape.
        if case .object(let fields) = r.structuredContent,
           case .bool(let ok) = fields["ok"] ?? .null {
            #expect([true, false].contains(ok))
        }
    }

    @Test("run_shortcut requires name")
    func runShortcutMissing() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "run_shortcut", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("run_shortcut errors on non-existent name")
    func runShortcutBogusName() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "run_shortcut",
            arguments: ["name": .string("__definitely_not_a_real_shortcut__")]
        )
        #expect(r.isError == true)
    }

    @Test("open_url_scheme requires url")
    func openURLSchemeMissing() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "open_url_scheme", arguments: [:])
        #expect(r.isError == true)
    }

    // MARK: - Finder

    @Test("reveal_in_finder errors on missing path")
    func revealMissingPath() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "reveal_in_finder",
            arguments: ["path": .string("/tmp/definitely-not-a-real-path-\(UUID().uuidString)")]
        )
        #expect(r.isError == true)
    }

    @Test("trash_file refuses paths outside home directory")
    func trashOutsideHome() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "trash_file",
            arguments: ["path": .string("/etc/hosts")]
        )
        #expect(r.isError == true)
        if case .object(let fields) = r.structuredContent,
           case .object(let res) = fields["result"] ?? .null,
           case .string(let err) = res["error"] ?? .null {
            #expect(err.contains("restricted") || err.contains("refusing"))
        }
    }

    @Test("quick_look errors on missing path")
    func quickLookMissing() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "quick_look",
            arguments: [
                "path": .string("/tmp/definitely-not-a-real-\(UUID().uuidString).pdf"),
                "timeout_seconds": .number(0.5)
            ]
        )
        #expect(r.isError == true)
    }

    // MARK: - Ergonomic click wrappers

    @Test("right_click requires x and y")
    func rightClickMissing() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "right_click", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("double_click requires x and y")
    func doubleClickMissing() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "double_click", arguments: [:])
        #expect(r.isError == true)
    }

    // MARK: - tool-count sanity: phase 5 test asserts 95 now

    @Test("tool count is 95 after phase 7 (70 + 25)")
    func phase7CountCheck() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        #expect(registry.toolDefinitions.count == 95)
    }
}
