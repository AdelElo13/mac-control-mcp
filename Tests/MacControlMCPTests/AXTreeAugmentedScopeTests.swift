import Testing
import Foundation
import CoreGraphics
@testable import MacControlMCP

/// Codex r2 #2, third tool — `ax_tree_augmented` with a window scope used
/// to walk the APP ROOT and keep whatever fell inside the window's frame,
/// the same defect class `ground` / `capture_annotated` had: an
/// overlapping window of the same app contributes nodes, and the OCR join
/// then labels foreign nodes with this window's text.
///
/// With a resolvable AXWindow the walk must be rooted at that window's
/// subtree; with a window requested but no AXWindow (or an ambiguous
/// match) the AX side is withheld — never app-root. The withheld path
/// returns before any AX or screen access, so it is safe on any machine.
@Suite("ax_tree_augmented window scope (Codex r2 #2)")
struct AXTreeAugmentedScopeTests {

    static func scope(ambiguous: [WindowTargeting.Candidate]? = nil) -> GroundingController.WindowScope {
        GroundingController.WindowScope(
            windowID: 4_294_967_290,
            pid: pid_t(ProcessInfo.processInfo.processIdentifier),
            ownerName: "Google Chrome",
            title: "Codex r2 #2 — no AX window",
            bounds: CGRect(x: 100, y: 100, width: 800, height: 600),
            isOnscreen: true,
            axElement: nil,
            axIndex: nil,
            ambiguousCandidates: ambiguous
        )
    }

    static func grounding() -> GroundingController {
        ToolRegistry(accessibility: AccessibilityController()).grounding
    }

    @Test("a window scope without an AXWindow withholds every node with reason no_ax_window")
    func noAXWindowWithholds() async {
        let result = await Self.grounding().axTreeAugmented(pid: 1, window: Self.scope())
        #expect(result.ok == false)
        #expect(result.nodes.isEmpty)
        #expect(result.nodeCount == 0)
        #expect(result.inferredCount == 0)
        #expect(result.axScope == "none")
        #expect(result.errorCode == "no_ax_window")
        #expect(result.axScopeReason == "no_ax_window")
        #expect(result.error?.contains("ocr_screen") == true)
    }

    @Test("an ambiguous window scope withholds with reason ambiguous_window")
    func ambiguousWithholds() async {
        let candidates: [WindowTargeting.Candidate] = [
            .init(index: 0, title: "Untitled", frame: CGRect(x: 100, y: 100, width: 800, height: 600)),
            .init(index: 1, title: "Untitled", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
        ]
        let result = await Self.grounding().axTreeAugmented(pid: 1, window: Self.scope(ambiguous: candidates))
        #expect(result.ok == false)
        #expect(result.nodes.isEmpty)
        #expect(result.axScope == "none")
        #expect(result.errorCode == "ambiguous_window")
        #expect(result.axScopeReason == "ambiguous_window")
    }

    @Test("the tool payload for a withheld scope has nodes [] and names the scope")
    func toolPayloadShape() {
        let fields = ToolRegistry.withheldAugmentedFields(
            reason: .noAXWindow, windowID: 42, ownerName: "Google Chrome", candidates: nil
        )
        #expect(fields["ax_scope"] == .string("none"))
        #expect(fields["ax_scope_reason"] == .string("no_ax_window"))
        #expect(fields["nodes"] == .array([]))
        #expect(fields["node_count"] == .number(0))
        #expect(fields["hint"]?.stringValue?.contains("element_at_point") == true)
        #expect(fields["candidates"] == nil)
    }
}
