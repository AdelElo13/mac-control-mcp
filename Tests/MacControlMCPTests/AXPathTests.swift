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

    @Test("identity string is canonical, length-prefixed, and includes pid, role, ordinal, identifier")
    func identityString() {
        let p = path([("AXWindow", 0, nil), ("AXButton", 3, "save-btn")])
        // v2 canonical form (Codex review 3): every variable-length field is
        // prefixed with its UTF-8 byte count, and the component count is
        // pinned up front, so no crafted AXIdentifier can produce another
        // path's string.
        #expect(
            AXPath.identity(pid: 742, path: p)
                == "axpath2:742:2:8:AXWindow:0:-:8:AXButton:3:8:save-btn"
        )
        // The application root itself is the empty path.
        #expect(AXPath.identity(pid: 742, path: []) == "axpath2:742:0")
    }

    @Test("same (pid, path) always yields the same id")
    func deterministic() {
        let p = path([("AXWindow", 0, nil), ("AXButton", 3, nil)])
        let first = AXPath.identifier(pid: 742, path: p)
        let second = AXPath.identifier(pid: 742, path: path([("AXWindow", 0, nil), ("AXButton", 3, nil)]))
        #expect(first == second)
        #expect(first.hasPrefix("el_"))
        // SHA-256 truncated to 128 bits → 32 hex chars (Codex review 3).
        #expect(first.count == 3 + 32)
        #expect(first.dropFirst(3).allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    /// Codex review 3 (BLOCKER): the old canonical form concatenated role,
    /// ordinal and identifier without escaping or length prefixes, so an app
    /// that publishes an AXIdentifier containing "/AXButton[1]#…" could mint
    /// the exact canonical string of a *different* path — and with it the
    /// same element id. Both halves of the fix are asserted here: the naive
    /// concatenation really does collide, and the shipped identity/id do not.
    @Test("a crafted AXIdentifier cannot forge another path's identity")
    func craftedIdentifierCannotCollide() {
        // One component whose identifier embeds a second component…
        let forged = path([("AXButton", 1, "x/AXButton[1]#y")])
        // …versus two genuine components spelling the same thing.
        let genuine = path([("AXButton", 1, "x"), ("AXButton", 1, "y")])

        // The old (naive) concatenation these two produce is identical.
        func naive(_ components: [AXPathComponent]) -> String {
            var out = "pid:742"
            for component in components {
                out += "/\(component.role)[\(component.index)]"
                if let identifier = component.identifier { out += "#\(identifier)" }
            }
            return out
        }
        #expect(naive(forged) == naive(genuine), "the collision this test defends against is real")

        #expect(AXPath.identity(pid: 742, path: forged) != AXPath.identity(pid: 742, path: genuine))
        #expect(AXPath.identifier(pid: 742, path: forged) != AXPath.identifier(pid: 742, path: genuine))
    }

    /// Ordinals are unbounded integers; without a separator that cannot occur
    /// inside a field, "[1]" + "2" and "[12]" would be the same bytes.
    @Test("adjacent numeric fields cannot be run together")
    func numericFieldsAreDelimited() {
        let a = path([("AXRow", 1, nil), ("AXCell", 2, nil)])
        let b = path([("AXRow", 12, nil), ("AXCell", 2, nil)])
        #expect(AXPath.identity(pid: 742, path: a) != AXPath.identity(pid: 742, path: b))
        // A pid boundary too: pid 74 + first role "2…" must not equal pid 742.
        #expect(AXPath.identity(pid: 74, path: a) != AXPath.identity(pid: 742, path: a))
    }

    /// A nil identifier is encoded as a marker that no real identifier can
    /// spell, so "no identifier" and the literal identifier "-" differ.
    @Test("absent identifier is distinguishable from a literal dash")
    func absentIdentifierIsNotADash() {
        let absent = path([("AXButton", 0, nil)])
        let dash = path([("AXButton", 0, "-")])
        #expect(AXPath.identity(pid: 1, path: absent) != AXPath.identity(pid: 1, path: dash))
        #expect(AXPath.identifier(pid: 1, path: absent) != AXPath.identifier(pid: 1, path: dash))
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
        // Hard-coded SHA-256 reference vectors, truncated to 128 bits: if
        // these ever change, ids minted by an older build stop matching a
        // newer one. (Full SHA-256("") =
        // e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855.)
        #expect(AXPath.digest128("") == "e3b0c44298fc1c149afbf4c8996fb924")
        #expect(AXPath.digest128("abc") == "ba7816bf8f01cfea414140de5dae2223")
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
