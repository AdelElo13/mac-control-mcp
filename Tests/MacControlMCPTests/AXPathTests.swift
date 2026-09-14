import Testing
import Foundation
import AppKit
import ApplicationServices
@testable import MacControlMCP

/// C-5 / B-10 — element handles must be content-addressed: the same
/// element has to yield the same id on every call and in every session,
/// and two different elements must never share one.
@Suite("AX path identity (C-5)")
struct AXPathTests {

    private func path(_ parts: [(String, Int, String?)]) -> [AXPathComponent] {
        parts.map { AXPathComponent(role: $0.0, index: $0.1, identifier: $0.2) }
    }

    @Test("identity string is canonical and includes pid, role, ordinal, identifier")
    func identityString() {
        let p = path([("AXWindow", 0, nil), ("AXButton", 3, "save-btn")])
        #expect(AXPath.identity(pid: 742, path: p) == "pid:742/AXWindow[0]/AXButton[3]#save-btn")
        // The application root itself is the empty path.
        #expect(AXPath.identity(pid: 742, path: []) == "pid:742")
    }

    @Test("same (pid, path) always yields the same id")
    func deterministic() {
        let p = path([("AXWindow", 0, nil), ("AXButton", 3, nil)])
        let first = AXPath.identifier(pid: 742, path: p)
        let second = AXPath.identifier(pid: 742, path: path([("AXWindow", 0, nil), ("AXButton", 3, nil)]))
        #expect(first == second)
        #expect(first.hasPrefix("el_"))
        #expect(first.count == 3 + 16)
    }

    @Test("different elements yield different ids")
    func distinct() {
        let base = path([("AXWindow", 0, nil), ("AXButton", 3, nil)])
        let differentOrdinal = path([("AXWindow", 0, nil), ("AXButton", 4, nil)])
        let differentRole = path([("AXWindow", 0, nil), ("AXCheckBox", 3, nil)])
        let differentIdentifier = path([("AXWindow", 0, nil), ("AXButton", 3, "save")])
        let deeper = path([("AXWindow", 0, nil), ("AXButton", 3, nil), ("AXStaticText", 0, nil)])
        let ids = Set([base, differentOrdinal, differentRole, differentIdentifier, deeper].map {
            AXPath.identifier(pid: 742, path: $0)
        })
        #expect(ids.count == 5)
        // …and a different app is a different element too.
        #expect(AXPath.identifier(pid: 742, path: base) != AXPath.identifier(pid: 743, path: base))
    }

    @Test("hash is process-independent (not Swift's seeded Hasher)")
    func stableAcrossSessions() {
        // Hard-coded FNV-1a 64 reference vectors: if these ever change,
        // ids minted by an older build stop matching a newer one.
        #expect(AXPath.fnv1a64("") == 0xcbf2_9ce4_8422_2325)
        #expect(AXPath.fnv1a64("a") == 0xaf63_dc4c_8601_ec8c)
    }

    @Test("empty identifiers are normalised away")
    func emptyIdentifier() {
        let withEmpty = AXPathComponent(role: "AXButton", index: 1, identifier: "")
        let withNil = AXPathComponent(role: "AXButton", index: 1, identifier: nil)
        #expect(withEmpty == withNil)
        #expect(AXPathComponent(role: nil, index: 0, identifier: nil).role == "AXUnknown")
    }

    @Test("appending builds the path a walk would record")
    func appending() {
        var p: [AXPathComponent] = []
        p = AXPath.appending(p, role: "AXWindow", index: 0, identifier: nil)
        p = AXPath.appending(p, role: "AXButton", index: 2, identifier: "ok")
        #expect(p.count == 2)
        #expect(p[1].index == 2)
        #expect(p[1].identifier == "ok")
    }

    @Test("the same query twice returns identical element ids, and the cache survives a clear")
    func stableIDsAcrossCalls() async throws {
        // A live app that reliably exposes an AX tree on any Mac: the
        // test process itself has none, so use Finder.
        guard let finder = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.finder" })?.processIdentifier,
              AXIsProcessTrusted()
        else { return }  // no Finder / no AX trust (CI) — nothing to assert

        let registry = ToolRegistry(accessibility: AccessibilityController())
        let args: [String: JSONValue] = ["pid": .number(Double(finder)), "limit": .number(5)]
        let first = await registry.callTool(name: "find_elements", arguments: args)
        let second = await registry.callTool(name: "find_elements", arguments: args)

        func ids(_ result: ToolCallResult) -> [String] {
            (result.structuredContent.objectValue?["elements"]?.arrayValue ?? [])
                .compactMap { $0.objectValue?["id"]?.stringValue }
        }
        let firstIDs = ids(first)
        try #require(!firstIDs.isEmpty)
        #expect(firstIDs == ids(second))

        // Same ids again after the cache is emptied — they are derived
        // from the element's position in the tree, not from cache state.
        await registry.elementCache.clear()
        let third = await registry.callTool(name: "find_elements", arguments: args)
        #expect(firstIDs == ids(third))
    }
}
