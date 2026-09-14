import Testing
import Foundation
@testable import MacControlMCP

/// v0.8.4: `HardwareController.wifiScan()` mapped CoreWLAN's nil SSID
/// straight to "(hidden)" without ever checking Location authorization —
/// since macOS 14 CoreWLAN returns ssid=nil for every network unless
/// Location Services is granted to the responsible process, every scan
/// looked like "all networks hidden", indistinguishable from genuinely
/// hidden ones. These tests cover the pure decision logic and the
/// crash-safety guards; they intentionally do NOT run in an environment
/// that has NSLocationWhenInUseUsageDescription in its Info.plist (the
/// XCTest/swift-test bundle has none), so they exercise the
/// `info_plist_missing` short-circuit paths rather than real CoreLocation
/// authorization flows.
@Suite("v0.8.4 wifi_scan Location gating", .serialized, .timeLimit(.minutes(1)))
struct LocationWifiScanTests {

    // MARK: - Pure SSID/redaction/hidden decision

    @Test("granted + real SSID passes it through, not hidden")
    func grantedWithSSID() {
        let (ssid, hidden) = HardwareController.classifyNetworkSSID(granted: true, rawSSID: "CafeWiFi")
        #expect(ssid == "CafeWiFi")
        #expect(hidden == false)
    }

    @Test("granted + nil SSID is a genuinely hidden network")
    func grantedWithoutSSID() {
        let (ssid, hidden) = HardwareController.classifyNetworkSSID(granted: true, rawSSID: nil)
        #expect(ssid == nil)
        #expect(hidden == true)
    }

    @Test("not granted redacts even when CoreWLAN happened to return a name")
    func notGrantedWithSSID() {
        // Shouldn't happen in practice (CoreWLAN nils SSIDs without Location),
        // but redaction must be driven by the permission, not by whether a
        // name is present — never leak a name macOS wasn't supposed to give us.
        let (ssid, hidden) = HardwareController.classifyNetworkSSID(granted: false, rawSSID: "Leaked")
        #expect(ssid == nil)
        #expect(hidden == false)
    }

    @Test("not granted + nil SSID redacts, and is NOT reported as hidden")
    func notGrantedWithoutSSID() {
        let (ssid, hidden) = HardwareController.classifyNetworkSSID(granted: false, rawSSID: nil)
        #expect(ssid == nil)
        #expect(hidden == false, "redaction must not be conflated with a genuinely hidden network")
    }

    // MARK: - WifiScanResult.Network encodes ssid:null, not an omitted key

    @Test("redacted network serializes ssid as JSON null, key present")
    func redactedNetworkEncodesNull() throws {
        let network = HardwareController.WifiScanResult.Network(
            ssid: nil, rssi: -50, channel: 6, security: "WPA2", hidden: false
        )
        let json = encodeAsJSONValue(network)
        guard case .object(let dict) = json else {
            Issue.record("expected object"); return
        }
        #expect(dict["ssid"] == .null, "ssid key must be present with null, not omitted")
        #expect(dict["hidden"] == .bool(false))
    }

    // MARK: - Status helper crash-safety (mirrors calendar/contacts pattern)

    @Test("locationPermissionStatusString never crashes without Info.plist usage key")
    func locationStatusInTestBundle() {
        // The swift-test binary's Info.plist has no
        // NSLocationWhenInUseUsageDescription, so this must short-circuit
        // to info_plist_missing rather than constructing CLLocationManager()
        // (which SIGABRTs without that key) — same guard shape as
        // calendarPermissionStatusString / contactsPermissionStatusString.
        let status = ToolRegistry.locationPermissionStatusString()
        #expect(status == "info_plist_missing")
    }

    @Test("info_plist_missing is never reported as granted")
    func infoPlistMissingIsNotGranted() {
        #expect(!ToolRegistry.isGrantedPermissionStatus("info_plist_missing"))
        #expect(ToolRegistry.isGrantedPermissionStatus("granted"))
    }

    // MARK: - request_permissions accepts "location" without crashing

    @Test("request_permissions accepts the location category and skips with info_plist_missing")
    func requestPermissionsLocationSkipsInTestBundle() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(
            name: "request_permissions",
            arguments: ["categories": .array([.string("location")])]
        )
        #expect(!result.isError)
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("expected object payload"); return
        }
        #expect(payload["triggered"] == .array([]))
        guard case .object(let skipped)? = payload["skipped"] else {
            Issue.record("expected 'skipped' object"); return
        }
        #expect(skipped["location"] == .string("info_plist_missing"))
    }

    @Test("permissions_status reports a location entry using the new status vocabulary")
    func permissionsStatusReportsLocation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "permissions_status", arguments: [:])
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("expected object payload"); return
        }
        #expect(payload["location"] == .string("info_plist_missing"))
    }

    // MARK: - wifi_scan tool is still registered with the new fields wired

    @Test("wifi_scan tool definition exists")
    func wifiScanRegistered() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        #expect(registry.toolDefinitions.contains { $0.name == "wifi_scan" })
    }
}
