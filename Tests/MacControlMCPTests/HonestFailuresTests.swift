import Testing
import Foundation
@testable import MacControlMCP

/// Regression tests for the v0.9 gap-audit fixes (A-7, A-8, A-11, A-12,
/// A-13, A-17) — each of these fails against the pre-fix code, proving
/// the fix actually changed behavior rather than just adding dead code.
@Suite("v0.9 gap-audit fixes — honest failures", .serialized)
struct HonestFailuresTests {

    // MARK: - A-8: no_such_process for a dead pid

    /// A pid this high is astronomically unlikely to be a running
    /// process on any macOS box (max pid space is far smaller), so this
    /// is a safe, deterministic "definitely dead" pid for tests.
    static let deadPID: JSONValue = .number(999_999)

    @Test("find_element reports no_such_process for a dead pid")
    func findElementDeadPID() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "find_element", arguments: ["pid": Self.deadPID])
        #expect(r.isError == true)
        #expect(r.structuredContent.objectValue?["error_code"]?.stringValue == "no_such_process")
    }

    @Test("find_elements reports no_such_process for a dead pid")
    func findElementsDeadPID() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "find_elements", arguments: ["pid": Self.deadPID])
        #expect(r.isError == true)
        #expect(r.structuredContent.objectValue?["error_code"]?.stringValue == "no_such_process")
    }

    @Test("get_ui_tree reports no_such_process for a dead pid")
    func getUITreeDeadPID() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "get_ui_tree", arguments: ["pid": Self.deadPID])
        #expect(r.isError == true)
        #expect(r.structuredContent.objectValue?["error_code"]?.stringValue == "no_such_process")
    }

    @Test("list_elements reports no_such_process for a dead pid")
    func listElementsDeadPID() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "list_elements", arguments: ["pid": Self.deadPID])
        #expect(r.isError == true)
        #expect(r.structuredContent.objectValue?["error_code"]?.stringValue == "no_such_process")
    }

    @Test("isRunningProcess is false for a dead pid and true for our own pid")
    func isRunningProcessDirect() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        #expect(registry.isRunningProcess(999_999) == false)
        #expect(registry.isRunningProcess(getpid()) == true)
    }

    // MARK: - A-11: convert_coordinates / capture_display out-of-range

    @Test("convert_coordinates: out-of-range display index is no_such_display, not a bare ok:false")
    func convertCoordinatesOutOfRange() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "convert_coordinates", arguments: [
            "x": .number(100), "y": .number(100),
            "from": .string("global"), "to": .string("display:99")
        ])
        #expect(r.isError == true)
        let obj = r.structuredContent.objectValue
        #expect(obj?["error_code"]?.stringValue == "no_such_display")
        #expect(obj?["error"]?.stringValue != nil)
        #expect(obj?["valid_display_indices"]?.stringValue != nil)
    }

    @Test("convert_coordinates: malformed space string is invalid_argument")
    func convertCoordinatesMalformed() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "convert_coordinates", arguments: [
            "x": .number(10), "y": .number(10),
            "from": .string("global"), "to": .string("nonsense")
        ])
        #expect(r.isError == true)
        #expect(r.structuredContent.objectValue?["error_code"]?.stringValue == "invalid_argument")
    }

    @Test("capture_display: out-of-range display_index is no_such_display with the valid range")
    func captureDisplayOutOfRange() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "capture_display", arguments: ["display_index": .number(99)])
        #expect(r.isError == true)
        let obj = r.structuredContent.objectValue
        #expect(obj?["error_code"]?.stringValue == "no_such_display")
        #expect(obj?["error"]?.stringValue != nil)
        #expect(obj?["valid_display_indices"]?.stringValue != nil)
    }

    // MARK: - A-13: query_elements invalid regex

    @Test("query_elements: unclosed regex sets regex_invalid + matching=substring")
    func queryElementsInvalidRegex() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "query_elements", arguments: [
            "pid": Self.deadPID, "title_regex": .string("[unclosed"), "limit": .number(2)
        ])
        // Regex classification happens before any AX walk, so this holds
        // even against a pid with no AX tree.
        let obj = r.structuredContent.objectValue
        #expect(obj?["regex_invalid"]?.boolValue == true)
        #expect(obj?["matching"]?.stringValue == "substring")
        #expect(obj?["invalid_patterns"] != nil)
    }

    @Test("query_elements: valid regex does not set regex_invalid")
    func queryElementsValidRegex() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "query_elements", arguments: [
            "pid": Self.deadPID, "title_regex": .string("^Save$"), "limit": .number(2)
        ])
        #expect(r.structuredContent.objectValue?["regex_invalid"] == nil)
    }

    // MARK: - A-17: battery parsing (pure function, no subprocess)

    @Test("battery parsing: fully charged + plugged in reports nil timeRemainingMinutes, not 0")
    func batteryChargedIsNilNotZero() {
        let out = """
        Now drawing from 'AC Power'
         -InternalBattery-0 (id=22741091)\t100%; charged; 0:00 remaining present: true
        """
        let battery = SystemInfoController.parseBatteryOutput(out)
        #expect(battery.percentage == 100)
        #expect(battery.pluggedIn == true)
        #expect(battery.timeRemainingMinutes == nil)
    }

    @Test("battery parsing: discharging with a real estimate keeps the minute count")
    func batteryDischargingKeepsEstimate() {
        let out = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1) 42%; discharging; 2:15 remaining present: true"
        let battery = SystemInfoController.parseBatteryOutput(out)
        #expect(battery.percentage == 42)
        #expect(battery.pluggedIn == false)
        #expect(battery.charging == false)
        #expect(battery.timeRemainingMinutes == 135)
    }

    @Test("battery parsing: no estimate yet reports -1, not 0 or nil")
    func batteryNoEstimate() {
        let out = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1) 55%; discharging; (no estimate) present: true"
        let battery = SystemInfoController.parseBatteryOutput(out)
        #expect(battery.timeRemainingMinutes == -1)
    }

    // MARK: - A-12: network_info redaction fields

    @Test("Network struct encodes ssids_redacted + location_status snake_case keys")
    func networkRedactionFieldsEncode() {
        let network = SystemInfoController.Network(
            wifiSSID: nil,
            wifiInterface: "en0",
            interfaces: [],
            ssidsRedacted: true,
            locationStatus: "denied"
        )
        let encoded = encodeAsJSONValue(network)
        let obj = encoded.objectValue
        #expect(obj?["wifiSSID"] == .null || obj?["wifiSSID"] == nil)
        #expect(obj?["ssids_redacted"]?.boolValue == true)
        #expect(obj?["location_status"]?.stringValue == "denied")
    }

    @Test("Network struct reports a real SSID + ssids_redacted:false when granted")
    func networkNotRedactedWhenGranted() {
        let network = SystemInfoController.Network(
            wifiSSID: "HomeWiFi",
            wifiInterface: "en0",
            interfaces: [],
            ssidsRedacted: false,
            locationStatus: "granted"
        )
        let obj = encodeAsJSONValue(network).objectValue
        #expect(obj?["wifiSSID"]?.stringValue == "HomeWiFi")
        #expect(obj?["ssids_redacted"]?.boolValue == false)
    }

    // MARK: - A-7 follow-up: AppleScript error classification is pure and app-agnostic

    @Test("AppleScriptErrorClassifier: -1743 stderr classifies as permission_missing/automation")
    func classifierAutomationDenied() {
        let c = AppleScriptErrorClassifier.classify(
            stderr: "31:117: execution error: Not authorized to send Apple events to Reminders. (-1743)",
            appName: "Reminders"
        )
        #expect(c.errorCode == "permission_missing")
        #expect(c.pane == "automation")
    }

    @Test("AppleScriptErrorClassifier: -600 stderr classifies as not_running")
    func classifierNotRunning() {
        let c = AppleScriptErrorClassifier.classify(
            stderr: "Reminders got an error: Application isn't running. (-600)",
            appName: "Reminders"
        )
        #expect(c.errorCode == "not_running")
        #expect(c.pane == nil)
    }

    @Test("AppleScriptErrorClassifier: timeout stderr classifies as timeout")
    func classifierTimeout() {
        let c = AppleScriptErrorClassifier.classify(
            stderr: "osascript exceeded the 30s timeout and was terminated.",
            appName: "Reminders"
        )
        #expect(c.errorCode == "timeout")
    }

    @Test("AppleScriptErrorClassifier: unrecognized stderr falls back to failed")
    func classifierGenericFailure() {
        let c = AppleScriptErrorClassifier.classify(stderr: "some other AppleScript error", appName: "Reminders")
        #expect(c.errorCode == "failed")
    }

    @Test("reminders_list does not pre-block on EventKit status — it always reaches the AppleScript path")
    func remindersListNeverPreBlocksOnEventKit() async {
        // Regression guard for the reviewed bug: the first version of the
        // A-7 fix pre-checked `remindersPermissionStatusString()` and
        // returned early without ever invoking AppleScript when EventKit
        // reminders access was not granted — even though Automation (the
        // TCC bucket that actually gates the AppleScript call) might be
        // fine. We can't force a specific EventKit/Automation combination
        // in CI, but we can assert the *shape* of the contract the review
        // requires: whatever the outcome, the response always carries
        // `eventkit_authorization` as informational context, and never a
        // top-level `error_code: "permission_missing"` derived purely from
        // the EventKit entitlement (that code now only comes from an
        // actual -1743 AppleScript failure, whose `pane` is "automation").
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(name: "reminders_list", arguments: ["limit": .number(3)])
        let obj = r.structuredContent.objectValue
        #expect(obj?["eventkit_authorization"] != nil)
        if let errorCode = obj?["error_code"]?.stringValue, errorCode == "permission_missing" {
            #expect(obj?["pane"]?.stringValue == "automation")
        }
    }
}
