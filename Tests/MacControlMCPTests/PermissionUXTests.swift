import Testing
import Foundation
@testable import MacControlMCP

/// v0.8.3 permission UX regressions, from bugs measured on v0.8.2:
///   2. permissions_status claimed to report only accessibility, never said
///      WHICH app the grants belong to, and "denied" hid macOS refusing
///      without a prompt (status still not_determined).
///   3. open_permission_pane always pointed at the Claude Extensions path,
///      even for a tarball install in ~/Applications.
///   4. request_permissions blocked on a first-time folder prompt past the
///      client's timeout.
@Suite("v0.8.3 permission UX", .serialized, .timeLimit(.minutes(1)))
struct PermissionUXTests {

    static let serverExe = "/Users/x/Applications/MacControlMCP.app/Contents/MacOS/MacControlMCP"

    static func snapshot(responsibleIsSelf: Bool) -> PermissionContext.Snapshot {
        let server = PermissionContext.ProcessDescriptor(pid: 100, executablePath: serverExe)
        let claude = PermissionContext.ProcessDescriptor(pid: 50, executablePath: "/Applications/Claude.app/Contents/MacOS/Claude")
        return PermissionContext.Snapshot(
            server: server,
            responsible: responsibleIsSelf ? server : claude,
            ancestry: [claude]
        )
    }

    // MARK: - Responsible process

    @Test("bundlePath resolves the owning .app for executables and helpers")
    func bundlePathResolution() {
        #expect(PermissionContext.bundlePath(forExecutable: "/Applications/Claude.app/Contents/MacOS/Claude") == "/Applications/Claude.app")
        #expect(PermissionContext.bundlePath(forExecutable: "/Applications/Claude.app/Contents/Helpers/disclaimer") == "/Applications/Claude.app")
        #expect(PermissionContext.bundlePath(forExecutable: "/Applications/ChatGPT.app/Contents/Resources/codex") == "/Applications/ChatGPT.app")
        #expect(PermissionContext.bundlePath(forExecutable: "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator")
                == "/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app")
        #expect(PermissionContext.bundlePath(forExecutable: "/usr/local/bin/node") == nil)
        #expect(PermissionContext.bundlePath(forExecutable: nil) == nil)
    }

    @Test("live snapshot identifies this process and a responsible process")
    func liveSnapshot() {
        let s = PermissionContext.current
        #expect(s.server.pid == getpid())
        #expect(s.server.executablePath != nil)
        #expect(s.responsible != nil, "responsibility SPI lookup failed")
        #expect(!s.ancestry.isEmpty)
    }

    // MARK: - Outcome classification (bug 2)

    @Test("request outcome is classified against the status read afterwards")
    func classifyOutcome() {
        #expect(PermissionContext.classify(granted: true, statusAfter: "granted") == .granted)
        #expect(PermissionContext.classify(granted: false, statusAfter: "not_determined") == .deniedWithoutPrompt)
        #expect(PermissionContext.classify(granted: nil, statusAfter: "not_determined") == .promptTimeout)
        #expect(PermissionContext.classify(granted: false, statusAfter: "denied") == .deniedByUser)
        #expect(PermissionContext.classify(granted: false, statusAfter: "restricted") == .restricted)
    }

    @Test("refusal without prompt is not reported as a user denial")
    func deniedWithoutPromptError() {
        let e = PermissionContext.permissionError(
            service: "Calendar", pane: "calendar",
            entitlement: "com.apple.security.personal-information.calendars",
            outcome: .deniedWithoutPrompt, statusAfter: "not_determined",
            snapshot: Self.snapshot(responsibleIsSelf: true),
            entitlementLookup: { _ in false }
        )
        #expect(e.payload["error_code"] == .string("permission_policy_denied"))
        #expect(e.payload["reason"] == .string("denied_without_prompt"))
        #expect(e.payload["status"] == .string("not_determined"))
        #expect(e.payload["entitlement_present"] == .bool(false))
        #expect(e.message.contains("without showing a prompt"))
        #expect(e.message.contains("lacks the com.apple.security.personal-information.calendars entitlement"))
        #expect(!e.message.lowercased().hasPrefix("calendar access denied"))
    }

    @Test("user denial names the responsible app and the pane")
    func deniedByUserError() {
        let e = PermissionContext.permissionError(
            service: "Contacts", pane: "contacts",
            entitlement: "com.apple.security.personal-information.addressbook",
            outcome: .deniedByUser, statusAfter: "denied",
            snapshot: Self.snapshot(responsibleIsSelf: false),
            entitlementLookup: { _ in true }
        )
        #expect(e.payload["error_code"] == .string("permission_missing"))
        #expect(e.payload["pane"] == .string("contacts"))
        #expect(e.message.contains("'Claude'"))
    }

    @Test("categories refused without a prompt are flagged only when this app is responsible")
    func promptBlockedDetection() {
        let statuses = [
            ToolRegistry.PermissionStatusEntry(name: "calendar", status: "not_determined"),
            ToolRegistry.PermissionStatusEntry(name: "contacts", status: "granted"),
            ToolRegistry.PermissionStatusEntry(name: "microphone", status: "not_determined")
        ]
        let lookup: (String) -> Bool? = { $0.hasSuffix("calendars") ? false : true }
        #expect(ToolRegistry.promptBlockedByMissingEntitlement(statuses, responsibleIsSelf: true, hardenedRuntime: true, entitlementLookup: lookup) == ["calendar"])
        #expect(ToolRegistry.promptBlockedByMissingEntitlement(statuses, responsibleIsSelf: false, hardenedRuntime: true, entitlementLookup: lookup).isEmpty)
        #expect(ToolRegistry.promptBlockedByMissingEntitlement(statuses, responsibleIsSelf: true, hardenedRuntime: false, entitlementLookup: lookup).isEmpty)
    }

    @Test("permissions_status describes all categories and reports the responsible app")
    func permissionsStatusPayload() async throws {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let definition = try #require(registry.toolDefinitions.first { $0.name == "permissions_status" })
        #expect(!definition.description.hasPrefix("Report the accessibility permission state"))
        #expect(definition.description.contains("responsible_app"))

        let result = await registry.callTool(name: "permissions_status", arguments: [:])
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("expected object payload"); return
        }
        for key in ["accessibility", "screen_recording", "calendar", "contacts", "microphone",
                    "responsible_app", "server", "launched_by", "prompt_blocked_by_missing_entitlement"] {
            #expect(payload[key] != nil, "missing \(key)")
        }
    }

    // MARK: - Hints and error enrichment (bug 3)

    @Test("grant hint points at the real target bundle, never the hard-coded Claude Extensions path")
    func grantHintPaths() {
        let selfHint = PermissionContext.grantHint(paneTitle: "Calendars", snapshot: Self.snapshot(responsibleIsSelf: true))
        #expect(selfHint.contains("/Users/x/Applications/MacControlMCP.app"))
        #expect(!selfHint.contains("Claude Extensions"))

        let claudeHint = PermissionContext.grantHint(paneTitle: "Calendars", snapshot: Self.snapshot(responsibleIsSelf: false))
        #expect(claudeHint.contains("'Claude'"))
        #expect(claudeHint.contains("/Applications/Claude.app"))
    }

    @Test("permission errors from any tool gain responsible-app context; others are untouched")
    func errorEnrichment() {
        let snap = Self.snapshot(responsibleIsSelf: false)
        let permission = ToolCallResult(text: "x", structuredContent: .object([
            "ok": .bool(false), "error_code": .string("permission_missing")
        ]), isError: true).withPermissionContext(snap)
        guard case .object(let enriched) = permission.structuredContent,
              case .object(let app)? = enriched["responsible_app"] else {
            Issue.record("responsible_app not added"); return
        }
        #expect(app["name"] == .string("Claude"))

        let notFound = ToolCallResult(text: "x", structuredContent: .object([
            "ok": .bool(false), "error_code": .string("not_found")
        ]), isError: true).withPermissionContext(snap)
        guard case .object(let untouched) = notFound.structuredContent else { return }
        #expect(untouched["responsible_app"] == nil)
    }

    // MARK: - Non-blocking request_permissions (bug 4)

    @Test("request_permissions returns immediately even when the folder prompt blocks")
    func requestPermissionsDoesNotWait() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let start = Date()
        let result = await registry.requestPermissions(
            ["categories": .array([.string("folders")])],
            folderProbe: { Thread.sleep(forTimeInterval: 5) }
        )
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.0, "request_permissions waited \(elapsed)s for the folder prompt")
        #expect(!result.isError)
        guard case .object(let payload) = result.structuredContent else { return }
        #expect(payload["triggered"] == .array([.string("folders")]))
        #expect(payload["status"] != nil)
        #expect(payload["responsible_app"] != nil)
    }

    @Test("request_permissions rejects unknown categories")
    func requestPermissionsValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(name: "request_permissions",
                                             arguments: ["categories": .array([.string("camera")])])
        #expect(result.isError)
    }

    @Test("awaitCallback times out when a callback never fires and returns the value when it does")
    func awaitCallbackTimeout() async {
        let start = Date()
        let never: Int? = await PermissionContext.awaitCallback(timeout: 0.2) { _ in }
        #expect(never == nil)
        #expect(Date().timeIntervalSince(start) < 1.0)

        let value: Int? = await PermissionContext.awaitCallback(timeout: 5) { done in
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { done(42) }
        }
        #expect(value == 42)
    }
}
