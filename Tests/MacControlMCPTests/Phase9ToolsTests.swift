import Testing
import Foundation
@testable import MacControlMCP

@Suite("Phase 9 tools — reliability + observability substrate", .serialized)
struct Phase9ToolsTests {

    // MARK: - Registry

    @Test("all 10 phase 9 tools are registered")
    func phase9Definitions() {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let names = Set(registry.toolDefinitions.map { $0.name })
        let expected: Set<String> = [
            "ground",
            "ax_tree_augmented",
            "ax_snapshot_capture",
            "ax_snapshot_diff",
            "audit_log_append",
            "audit_log_read",
            "agent_memory_store",
            "agent_memory_recall",
            "redact_pii_text",
            "redact_image_regions"
        ]
        #expect(expected.count == 10)
        #expect(expected.isSubset(of: names))
    }

    // MARK: - B1 ground

    @Test("ground requires target and pid")
    func groundValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let missingTarget = await registry.callTool(
            name: "ground", arguments: ["pid": .number(1)]
        )
        #expect(missingTarget.isError == true)
        let missingPid = await registry.callTool(
            name: "ground", arguments: ["target": .string("Save")]
        )
        #expect(missingPid.isError == true)
    }

    // MARK: - B2 ax_tree_augmented

    @Test("ax_tree_augmented requires pid")
    func axTreeAugmentedValidation() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "ax_tree_augmented", arguments: [:])
        #expect(r.isError == true)
    }

    // MARK: - B3 snapshots

    @Test("ax_snapshot_capture requires pid")
    func axSnapshotCaptureValidation() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "ax_snapshot_capture", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("ax_snapshot_diff requires from + to ids")
    func axSnapshotDiffValidation() async {
        let r1 = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "ax_snapshot_diff", arguments: ["from": .string("x")])
        #expect(r1.isError == true)
        let r2 = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(
                name: "ax_snapshot_diff",
                arguments: ["from": .string("bogus1"), "to": .string("bogus2")]
            )
        #expect(r2.isError == true)
    }

    // MARK: - F1 audit log

    @Test("audit_log_append requires event")
    func auditLogAppendValidation() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "audit_log_append", arguments: [:])
        #expect(r.isError == true)
    }

    @Test("audit_log_append + audit_log_read round-trip")
    func auditRoundTrip() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let marker = "phase9-smoke-\(UUID().uuidString.prefix(8))"
        let appended = await registry.callTool(
            name: "audit_log_append",
            arguments: [
                "event": .string(marker),
                "tool": .string("test"),
                "result": .string("ok")
            ]
        )
        #expect(appended.isError == false)

        let read = await registry.callTool(
            name: "audit_log_read",
            arguments: ["filter_event": .string(marker)]
        )
        #expect(read.isError == false)
        if case .object(let fields) = read.structuredContent,
           case .number(let count) = fields["count"] ?? .null {
            #expect(count >= 1, "appended entry should be retrievable")
        }
    }

    // MARK: - F3 agent memory

    @Test("agent_memory_store requires key + value")
    func memoryStoreValidation() async {
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(name: "agent_memory_store", arguments: ["key": .string("x")])
        #expect(r.isError == true)
    }

    @Test("agent_memory store + recall round-trip")
    func memoryRoundTrip() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let key = "test-\(UUID().uuidString.prefix(8))"
        let stored = await registry.callTool(
            name: "agent_memory_store",
            arguments: [
                "key": .string(key),
                "value": .string("marker-value"),
                "tags": .array([.string("phase9-test")])
            ]
        )
        #expect(stored.isError == false)

        let recalled = await registry.callTool(
            name: "agent_memory_recall",
            arguments: ["query": .string(key), "limit": .number(5)]
        )
        #expect(recalled.isError == false)
    }

    // MARK: - F4 redact_pii_text

    @Test("redact_pii_text blurs email + api key")
    func redactTextBasic() async {
        let sample = "contact a@b.com sk-ant-abcdefghijklmnopqrstuvwxyz0123456789abcd"
        let r = await ToolRegistry(accessibility: AccessibilityController())
            .callTool(
                name: "redact_pii_text",
                arguments: ["text": .string(sample)]
            )
        #expect(r.isError == false)
        if case .object(let fields) = r.structuredContent,
           case .object(let result) = fields["result"] ?? .null,
           case .string(let redacted) = result["redactedText"] ?? .null {
            #expect(redacted.contains("[REDACTED:email]"))
            #expect(redacted.contains("[REDACTED:apiKey]"))
            #expect(!redacted.contains("a@b.com"))
            #expect(!redacted.contains("sk-ant-abcdefg"))
        }
    }

    @Test("redact_pii_text Luhn-validates credit cards")
    func redactLuhnCheck() async {
        // 4111111111111111 is a test PAN with a valid Luhn digit
        let valid = "card 4111111111111111 here"
        // 1234567890123456 fails Luhn
        let invalid = "card 1234567890123456 here"
        let registry = ToolRegistry(accessibility: AccessibilityController())

        let r1 = await registry.callTool(
            name: "redact_pii_text",
            arguments: ["text": .string(valid), "categories": .array([.string("creditCard")])]
        )
        if case .object(let fields) = r1.structuredContent,
           case .object(let result) = fields["result"] ?? .null,
           case .string(let out) = result["redactedText"] ?? .null {
            #expect(out.contains("[REDACTED:creditCard]"))
        }

        let r2 = await registry.callTool(
            name: "redact_pii_text",
            arguments: ["text": .string(invalid), "categories": .array([.string("creditCard")])]
        )
        if case .object(let fields) = r2.structuredContent,
           case .object(let result) = fields["result"] ?? .null,
           case .string(let out) = result["redactedText"] ?? .null {
            #expect(!out.contains("[REDACTED:creditCard]"),
                    "Luhn-invalid number must not be redacted")
        }
    }

    // MARK: - F5 redact_image_regions

    @Test("redact_image_regions requires path + regions")
    func redactImageValidation() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let missingPath = await registry.callTool(
            name: "redact_image_regions",
            arguments: ["regions": .array([])]
        )
        #expect(missingPath.isError == true)
        let missingRegions = await registry.callTool(
            name: "redact_image_regions",
            arguments: ["path": .string("/tmp/x.png")]
        )
        #expect(missingRegions.isError == true)
    }

    // MARK: - A6 hierarchical scopes

    @Test("PermissionGrant has allowSubDelegation with default true")
    func permissionGrantSubDelegation() async {
        // v0.7.1 fix: removed _resetForTesting() call here. It was
        // wiping Phase 6 Suite's grants mid-test when the two suites
        // ran in parallel on CI (Phase 6's `expired grants are
        // rejected` sleeps 1.2s which is plenty of time for a cross-
        // suite reset to land). This test uses UNIQUE bundle IDs so
        // reset isn't needed — we only care about the allowSubDelegation
        // field of the grants we create here.
        let uniq = UUID().uuidString.prefix(8)
        let g = await PermissionStore.shared.grant(
            bundleId: "com.test.sub-delegate-\(uniq)",
            tier: .click, ttlSeconds: 60, reason: nil
        )
        #expect(g?.allowSubDelegation == true, "default must be true for v0.5.x back-compat")

        let g2 = await PermissionStore.shared.grant(
            bundleId: "com.test.no-sub-\(uniq)",
            tier: .click, ttlSeconds: 60,
            reason: nil, allowSubDelegation: false
        )
        #expect(g2?.allowSubDelegation == false)

        // Clean up our own entries; don't touch other suites' state.
        await PermissionStore.shared.revoke(bundleId: "com.test.sub-delegate-\(uniq)")
        await PermissionStore.shared.revoke(bundleId: "com.test.no-sub-\(uniq)")
    }

    // MARK: - tool count sanity

    @Test("tool count >= 127 after phase 9 (Phase 5 tests own the exact count)")
    func phase9CountCheck() {
        // Phase 5 owns the exact-number assertion; Phase 9 just guarantees
        // we haven't dropped below the v0.6.0 floor.
        let registry = ToolRegistry(accessibility: AccessibilityController())
        #expect(registry.toolDefinitions.count >= 127)
    }
}
