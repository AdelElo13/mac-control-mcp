import Testing
import Foundation
@testable import MacControlMCP

@Suite("audit_log fixes — ordering, metadata, tolerant since", .serialized)
struct AuditLogFixesTests {

    private func text(_ r: ToolCallResult, _ key: String) -> String? {
        guard case .object(let o) = r.structuredContent else { return nil }
        if case .string(let s) = o[key] ?? .null { return s }
        return nil
    }

    @Test("read returns newest-first, preserves metadata, and honors a no-fraction since")
    func auditRoundTrip() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let tag = "evt-\(UUID().uuidString.prefix(8))"

        // Append two entries in order; the second is newer.
        _ = await registry.callTool(name: "audit_log_append",
            arguments: ["event": .string(tag), "tool": .string("first")])
        _ = await registry.callTool(name: "audit_log_append",
            arguments: ["event": .string(tag), "tool": .string("second"),
                        "metadata": .object(["k": .string("v")])])

        let read = await registry.callTool(name: "audit_log_read",
            arguments: ["filter_event": .string(tag)])
        #expect(read.isError == false)
        guard case .object(let payload) = read.structuredContent,
              case .array(let entries) = payload["entries"] ?? .null else {
            Issue.record("audit_log_read returned no entries array"); return
        }
        #expect(entries.count == 2)

        // Newest-first: the second append (tool == "second") must be at [0].
        if case .object(let newest) = entries.first ?? .null,
           case .string(let tool) = newest["tool"] ?? .null {
            #expect(tool == "second")
            // metadata survived the append (was previously discarded).
            if case .object(let meta) = newest["metadata"] ?? .null,
               case .string(let v) = meta["k"] ?? .null {
                #expect(v == "v")
            } else {
                Issue.record("metadata not persisted on the appended entry")
            }
        } else {
            Issue.record("newest entry missing or malformed")
        }

        // A since filter WITHOUT fractional seconds must still parse and apply
        // (previously it silently parsed to nil and returned everything).
        let future = "2999-01-01T00:00:00Z"
        let filtered = await registry.callTool(name: "audit_log_read",
            arguments: ["filter_event": .string(tag), "since_iso": .string(future)])
        if case .object(let p2) = filtered.structuredContent,
           case .array(let e2) = p2["entries"] ?? .null {
            #expect(e2.isEmpty, "a far-future since must filter out all past entries")
        } else {
            Issue.record("second audit_log_read malformed")
        }
    }
}
