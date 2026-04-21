import Testing
import Foundation
import ApplicationServices
@testable import MacControlMCP

@Suite("Phase 6 tools — control plane + event waits", .serialized)
struct Phase6ToolsTests {

    // MARK: - Registry smoke

    @Test("all phase 6 tools are registered")
    func phase6Definitions() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let names = Set(registry.toolDefinitions.map { $0.name })
        let expected: Set<String> = [
            "request_access",
            "list_granted_applications",
            "revoke_access",
            "deny_access",
            "wait_for_ax_notification",
            "wait_for_window_state_change"
        ]
        #expect(expected.isSubset(of: names))
    }

    // MARK: - PermissionStore semantics

    @Test("grant → check → list → revoke round trip")
    func grantCheckListRevoke() async {
        await PermissionStore.shared._resetForTesting()

        // Grant 60s of click access
        let grant = await PermissionStore.shared.grant(
            bundleId: "com.test.grant",
            tier: .click,
            ttlSeconds: 60,
            reason: "unit test"
        )
        #expect(grant != nil)
        #expect(grant?.tier == .click)

        // Check: exact tier should pass, higher tier should fail
        let allowed = await PermissionStore.shared.check(
            bundleId: "com.test.grant", required: .click
        )
        #expect(allowed.allowed == true)
        #expect(allowed.reason == "ok")

        let denied = await PermissionStore.shared.check(
            bundleId: "com.test.grant", required: .full
        )
        #expect(denied.allowed == false)
        #expect(denied.reason == "insufficient_tier")

        // list includes the grant
        let grants = await PermissionStore.shared.list()
        #expect(grants.contains { $0.bundleId == "com.test.grant" })

        // revoke removes it; subsequent check returns no_grant
        await PermissionStore.shared.revoke(bundleId: "com.test.grant")
        let afterRevoke = await PermissionStore.shared.check(
            bundleId: "com.test.grant", required: .click
        )
        #expect(afterRevoke.allowed == false)
        #expect(afterRevoke.reason == "no_grant")
    }

    @Test("deny beats grant; revoke clears deny")
    func denyBeatsGrant() async {
        await PermissionStore.shared._resetForTesting()

        await PermissionStore.shared.deny(bundleId: "com.test.evil", reason: "bad actor")
        let r = await PermissionStore.shared.check(
            bundleId: "com.test.evil", required: .view
        )
        #expect(r.allowed == false)
        #expect(r.reason == "denied")

        // Grant while denied returns nil — must revoke first
        let attempted = await PermissionStore.shared.grant(
            bundleId: "com.test.evil", tier: .view, ttlSeconds: 60, reason: nil
        )
        #expect(attempted == nil)

        await PermissionStore.shared.revoke(bundleId: "com.test.evil")
        let granted = await PermissionStore.shared.grant(
            bundleId: "com.test.evil", tier: .view, ttlSeconds: 60, reason: nil
        )
        #expect(granted != nil)
    }

    @Test("expired grants are rejected")
    func expiredGrantsRejected() async {
        await PermissionStore.shared._resetForTesting()

        // Grant with a tiny TTL and wait past it.
        _ = await PermissionStore.shared.grant(
            bundleId: "com.test.expiring",
            tier: .full,
            ttlSeconds: 1,
            reason: nil
        )
        try? await Task.sleep(nanoseconds: 1_200_000_000) // 1.2s

        let r = await PermissionStore.shared.check(
            bundleId: "com.test.expiring", required: .view
        )
        #expect(r.allowed == false)
        #expect(r.reason == "expired")
    }

    @Test("PermissionTier comparison: denied < none < view < click < full")
    func tierComparison() {
        #expect(PermissionTier.denied < .none)
        #expect(PermissionTier.none < .view)
        #expect(PermissionTier.view < .click)
        #expect(PermissionTier.click < .full)
        #expect(!(PermissionTier.full < .click))
    }

    // MARK: - Tool plumbing

    @Test("request_access rejects invalid tier")
    func requestAccessRejectsInvalid() async {
        await PermissionStore.shared._resetForTesting()

        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "request_access",
            arguments: [
                "bundle_id": .string("com.test.requester"),
                "tier": .string("omnipotent")
            ]
        )
        #expect(r.isError == true)
    }

    @Test("request_access grants and list_granted_applications shows it")
    func requestAccessRoundTrip() async {
        await PermissionStore.shared._resetForTesting()

        let registry = ToolRegistry(accessibility: AccessibilityController())
        let granted = await registry.callTool(
            name: "request_access",
            arguments: [
                "bundle_id": .string("com.test.roundtrip"),
                "tier": .string("click"),
                "ttl_seconds": .number(300)
            ]
        )
        #expect(granted.isError == false)

        let listed = await registry.callTool(
            name: "list_granted_applications",
            arguments: [:]
        )
        #expect(listed.isError == false)

        // The structured payload should contain our bundle id.
        if case .object(let fields) = listed.structuredContent,
           case .array(let grants) = fields["grants"] ?? .null {
            let bundles = grants.compactMap { g -> String? in
                guard case .object(let o) = g, case .string(let b) = o["bundle_id"] ?? .null else { return nil }
                return b
            }
            #expect(bundles.contains("com.test.roundtrip"))
        } else {
            Issue.record("list_granted_applications returned unexpected shape")
        }
    }

    @Test("deny_access records a deny entry")
    func denyAccessToolRoundTrip() async {
        await PermissionStore.shared._resetForTesting()

        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "deny_access",
            arguments: ["bundle_id": .string("com.test.deny")]
        )
        #expect(r.isError == false)

        let check = await PermissionStore.shared.check(
            bundleId: "com.test.deny", required: .view
        )
        #expect(check.reason == "denied")
    }

    // MARK: - AXObserverBridge

    @Test("unsupported notifications return unsupported status immediately")
    func unsupportedNotification() async {
        let element = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let result = await AXObserverBridge.shared.waitForNotification(
            pid: ProcessInfo.processInfo.processIdentifier,
            element: element,
            notification: "AXNonExistentNotification",
            timeout: 0.2
        )
        #expect(result.status == .unsupported)
    }

    @Test("wait_for_ax_notification times out cleanly on invalid pid")
    func waitForAXTimeout() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "wait_for_ax_notification",
            arguments: [
                "pid": .number(999_999),
                "notification": .string("AXWindowCreated"),
                "timeout_seconds": .number(0.3)
            ]
        )
        // Either timedOut or setupFailed is acceptable; both are error results.
        #expect(r.isError == true)
        if case .object(let fields) = r.structuredContent {
            if case .string(let status) = fields["status"] ?? .null {
                #expect(["timed_out", "setup_failed"].contains(status))
            }
        }
    }

    @Test("wait_for_window_state_change validates change argument")
    func waitForWindowBadChange() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "wait_for_window_state_change",
            arguments: [
                "pid": .number(1),
                "change": .string("spinning")
            ]
        )
        #expect(r.isError == true)
    }

    @Test("wait_for_window_state_change times out cleanly on fake pid")
    func waitForWindowStateTimeout() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let r = await registry.callTool(
            name: "wait_for_window_state_change",
            arguments: [
                "pid": .number(999_999),
                "change": .string("created"),
                "timeout_seconds": .number(0.3)
            ]
        )
        #expect(r.isError == true)
    }
}
