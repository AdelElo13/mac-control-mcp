import Testing
import Foundation
import AppKit
import ApplicationServices
@testable import MacControlMCP

/// v0.9 C-5 review fixes: a stable id must never resolve to the WRONG
/// element. Two ways that could happen before these fixes:
///   1. a sibling is inserted, the recorded ordinal now points at a
///      different control, and nothing checked what was there;
///   2. the pid is recycled and the id silently retargets another app.
/// Both must end as `stale_element`, never as a plausible-looking hit.
@Suite("AX handle safety (C-5 review)")
struct AXHandleSafetyTests {

    private func component(
        _ role: String, _ index: Int,
        identifier: String? = nil, title: String? = nil, subrole: String? = nil
    ) -> AXPathComponent {
        AXPathComponent(role: role, index: index, identifier: identifier, title: title, subrole: subrole)
    }

    private func fingerprint(
        _ role: String, identifier: String? = nil, title: String? = nil, subrole: String? = nil
    ) -> AXFingerprint {
        AXFingerprint(role: role, identifier: identifier, title: title, subrole: subrole)
    }

    // MARK: - fingerprint matching

    @Test("identifier wins when the recorded path has one")
    func identifierMatch() {
        let want = component("AXButton", 2, identifier: "save")
        #expect(fingerprint("AXButton", identifier: "save", title: "Bewaren").matches(want))
        #expect(!fingerprint("AXButton", identifier: "cancel", title: "Save").matches(want))
        #expect(!fingerprint("AXCheckBox", identifier: "save").matches(want))
    }

    @Test("without an identifier, title AND subrole must both match")
    func titleSubroleMatch() {
        let want = component("AXButton", 0, title: "Save", subrole: "AXToolbarButton")
        #expect(fingerprint("AXButton", title: "Save", subrole: "AXToolbarButton").matches(want))
        #expect(!fingerprint("AXButton", title: "Save", subrole: "AXCloseButton").matches(want))
        #expect(!fingerprint("AXButton", title: "Cancel", subrole: "AXToolbarButton").matches(want))
        // A candidate that now publishes an identifier is a different
        // element from the untitled one we recorded.
        #expect(!fingerprint("AXButton", identifier: "x", title: "Save", subrole: "AXToolbarButton").matches(want))
    }

    @Test("a titleless, identifierless control still matches its exact twin shape")
    func anonymousMatch() {
        let want = component("AXButton", 1)
        #expect(fingerprint("AXButton").matches(want))
        #expect(!fingerprint("AXButton", title: "Now labelled").matches(want))
    }

    // MARK: - sibling drift (review fix 1, HIGH)

    @Test("inserting a sibling does NOT hand the ordinal's new occupant back")
    func siblingInsertionIsRefused() {
        // Recorded: index 1 was the untitled AXButton subrole AXCloseButton.
        let want = component("AXButton", 1, subrole: "AXCloseButton")
        let before = [fingerprint("AXStaticText"), fingerprint("AXButton", subrole: "AXCloseButton")]
        #expect(AXPath.resolveIndex(component: want, among: before) == 1)

        // A new control is inserted ahead of it: index 1 is now a
        // DIFFERENT button. The old code returned it; we must follow the
        // fingerprint to index 2 instead.
        let after = [
            fingerprint("AXStaticText"),
            fingerprint("AXButton", subrole: "AXToolbarButton"),
            fingerprint("AXButton", subrole: "AXCloseButton")
        ]
        #expect(AXPath.resolveIndex(component: want, among: after) == 2)
    }

    @Test("ordinal alone is never enough — a same-role neighbour is refused")
    func ordinalAloneRefused() {
        let want = component("AXButton", 0, title: "Save")
        // The only candidate at the recorded ordinal is a different
        // button, and nothing else matches → no answer at all.
        #expect(AXPath.resolveIndex(component: want, among: [fingerprint("AXButton", title: "Delete")]) == nil)
        #expect(AXPath.resolveIndex(component: want, among: []) == nil)
    }

    @Test("an ambiguous fingerprint is refused rather than guessed")
    func ambiguityRefused() {
        let want = component("AXButton", 7, subrole: "AXCloseButton")
        let siblings = [
            fingerprint("AXButton", subrole: "AXCloseButton"),
            fingerprint("AXButton", subrole: "AXCloseButton")
        ]
        // Ordinal 7 is out of range and two siblings match equally.
        #expect(AXPath.resolveIndex(component: want, among: siblings) == nil)
    }

    @Test("fingerprint repair succeeds when the identifier is present and the ordinal drifted")
    func identifierRepair() {
        let want = component("AXButton", 0, identifier: "save-btn")
        let siblings = [
            fingerprint("AXButton", identifier: "new-btn"),
            fingerprint("AXGroup"),
            fingerprint("AXButton", identifier: "save-btn")
        ]
        #expect(AXPath.resolveIndex(component: want, among: siblings) == 2)
    }

    @Test("fingerprint fields do not change the element id")
    func fingerprintDoesNotAffectID() {
        // A relabelled button is still the same button: title/subrole
        // must stay out of the hash, or every rename would look like a
        // brand-new element.
        let plain = [component("AXWindow", 0), component("AXButton", 3, identifier: "save")]
        let labelled = [
            component("AXWindow", 0, title: "Downloads"),
            component("AXButton", 3, identifier: "save", title: "Save", subrole: "AXToolbarButton")
        ]
        #expect(AXPath.identifier(pid: 742, path: plain) == AXPath.identifier(pid: 742, path: labelled))
    }

    // MARK: - pid reuse (review fix 2, HIGH)

    @Test("process identity distinguishes a recycled pid")
    func processIdentity() {
        let original = ProcessIdentity(startTime: 1_000.5, bundleID: "com.apple.finder")
        #expect(original.matches(ProcessIdentity(startTime: 1_000.5, bundleID: "com.apple.finder")))
        // Same pid, later start time → the number was reused.
        #expect(!original.matches(ProcessIdentity(startTime: 2_000.0, bundleID: "com.apple.finder")))
        #expect(!original.matches(ProcessIdentity(startTime: 1_000.5, bundleID: "com.apple.Safari")))
        // The process is gone entirely (no start time readable).
        #expect(!original.matches(ProcessIdentity(startTime: nil, bundleID: nil)))
    }

    @Test("a live process reports a stable, non-nil identity")
    func liveIdentity() throws {
        let mine = ProcessIdentity.current(pid: getpid())
        #expect(mine.startTime != nil)
        #expect(mine.matches(ProcessIdentity.current(pid: getpid())))
        // pid 1 (launchd) started before us.
        let launchd = try #require(ProcessIdentity.startTime(of: 1))
        #expect(launchd < (mine.startTime ?? 0))
    }

    @Test("resolveLive refuses an entry whose process identity changed")
    func staleOnPIDReuse() async {
        let cache = ElementCache()
        let element = AXUIElementCreateApplication(getpid())
        // Store with an identity that cannot match the live process.
        let id = await cache.store(
            element,
            pid: getpid(),
            path: [AXPathComponent(role: "AXWindow", index: 0, identifier: nil)],
            identity: ProcessIdentity(startTime: 1.0, bundleID: "com.example.gone")
        )
        guard case .stale(let reason) = await cache.resolveLive(id) else {
            Issue.record("expected .stale for a recycled pid")
            return
        }
        #expect(reason.contains("no longer the process"))
        // The poisoned entry is dropped, not left to be hit again.
        #expect(await cache.resolve(id) == nil)
    }

    @Test("resolveLive still returns a live element for an intact entry")
    func liveEntryResolves() async {
        let cache = ElementCache()
        let id = await cache.store(AXUIElementCreateSystemWide(), pid: getpid())
        guard case .resolved = await cache.resolveLive(id) else {
            Issue.record("expected .resolved for an intact entry")
            return
        }
    }

    @Test("an unknown id is 'unknown', not 'stale'")
    func unknownIsNotStale() async {
        let cache = ElementCache()
        guard case .unknown = await cache.resolveLive("el_0000000000000000") else {
            Issue.record("expected .unknown")
            return
        }
    }

    @Test("tools report stale_element and unknown_element_id distinctly")
    func toolSurfaces() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let unknown = await registry.callTool(
            name: "get_element_attributes",
            arguments: ["element_id": .string("el_0000000000000000"), "names": .array([.string("AXRole")])]
        )
        #expect(unknown.isError)
        #expect(unknown.structuredContent.objectValue?["error_code"]?.stringValue == "unknown_element_id")

        let id = await registry.elementCache.store(
            AXUIElementCreateApplication(getpid()),
            pid: getpid(),
            path: [AXPathComponent(role: "AXWindow", index: 0, identifier: nil)],
            identity: ProcessIdentity(startTime: 1.0, bundleID: "com.example.gone")
        )
        let stale = await registry.callTool(
            name: "get_element_attributes",
            arguments: ["element_id": .string(id), "names": .array([.string("AXRole")])]
        )
        #expect(stale.isError)
        let payload = stale.structuredContent.objectValue ?? [:]
        #expect(payload["error_code"]?.stringValue == "stale_element")
        #expect(payload["hint"]?.stringValue?.contains("find_elements") == true)
    }

    // MARK: - truncated trees stay walkable (review fix 3)

    @Test("a max_bytes-truncated tree has no child index past the end")
    func truncatedTreeIsOrphanFree() async throws {
        guard let finder = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == "com.apple.finder" })?.processIdentifier,
              AXIsProcessTrusted()
        else { return }

        let registry = ToolRegistry(accessibility: AccessibilityController())
        for cap in [800, 4_000, 20_000] {
            let result = await registry.callTool(
                name: "get_ui_tree",
                arguments: ["pid": .number(Double(finder)), "max_bytes": .number(Double(cap))]
            )
            let payload = result.structuredContent.objectValue ?? [:]
            let nodes = payload["nodes"]?.arrayValue ?? []
            try #require(!nodes.isEmpty)
            #expect(payload["truncated"]?.boolValue == true)
            for node in nodes {
                for child in node.objectValue?["children"]?.arrayValue ?? [] {
                    let index = try #require(child.intValue)
                    #expect(index >= 0 && index < nodes.count,
                            "child index \(index) out of range for \(nodes.count) nodes at cap \(cap)")
                }
            }
        }
    }
}
