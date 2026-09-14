import Testing
import Foundation
import CoreGraphics
@testable import MacControlMCP

/// Codex r2 #2 — a window-scoped call must never hand back AX elements it
/// cannot attribute to THAT window.
///
/// `ground` and `capture_annotated` claimed to be window-scoped via
/// `window_id`, but when the CGWindowID could not be resolved to a concrete
/// AXWindow (Chrome / Electron windows that publish no AX window, or an
/// ambiguous match) both silently fell back to walking the whole app tree
/// from the app root with only a geometric filter. A box drawn over the
/// pixels of window A could then carry the element_id of window B, and an
/// agent would click B.
///
/// The decision is a pure function (`AXScopePolicy.decide`) so it can be
/// pinned here without a live window; the controller-level tests below
/// drive `GroundingController.ground` with a `WindowScope` that has no AX
/// element, which returns BEFORE any AX or screen access — safe on any
/// machine.
@Suite("AX scope policy (Codex r2 #2)")
struct AXScopePolicyTests {

    // MARK: - Pure decision

    @Test("no window requested → app-root walk is legitimate and says so")
    func plainPIDKeepsAppRoot() {
        let decision = AXScopePolicy.decide(windowRequested: false, hasAXWindow: false, ambiguous: false)
        #expect(decision == .appRoot)
        #expect(decision.axScope == "app_root")
        #expect(decision.reason == nil)
    }

    @Test("window requested and resolved to an AXWindow → subtree walk")
    func resolvedWindowWalksSubtree() {
        let decision = AXScopePolicy.decide(windowRequested: true, hasAXWindow: true, ambiguous: false)
        #expect(decision == .windowSubtree)
        #expect(decision.axScope == "window_subtree")
        #expect(decision.reason == nil)
    }

    @Test("window requested but no AXWindow → AX is withheld, never app-root")
    func noAXWindowWithholds() {
        let decision = AXScopePolicy.decide(windowRequested: true, hasAXWindow: false, ambiguous: false)
        #expect(decision == .withheld(.noAXWindow))
        #expect(decision.axScope == "none")
        #expect(decision.reason == .noAXWindow)
        #expect(decision.reason?.rawValue == "no_ax_window")
    }

    @Test("window requested but several indistinguishable AXWindows → withheld as ambiguous")
    func ambiguousWindowWithholds() {
        let decision = AXScopePolicy.decide(windowRequested: true, hasAXWindow: false, ambiguous: true)
        #expect(decision == .withheld(.ambiguousWindow))
        #expect(decision.axScope == "none")
        #expect(decision.reason?.rawValue == "ambiguous_window")
    }

    @Test("an AX element wins over a stale ambiguity flag")
    func elementBeatsAmbiguity() {
        // Defensive: the resolver never produces both, but if it did the
        // concrete element is the stronger fact.
        let decision = AXScopePolicy.decide(windowRequested: true, hasAXWindow: true, ambiguous: true)
        #expect(decision == .windowSubtree)
    }

    // MARK: - WindowScope carries the decision

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

    static let twoCandidates: [WindowTargeting.Candidate] = [
        .init(index: 0, title: "Untitled", frame: CGRect(x: 100, y: 100, width: 800, height: 600)),
        .init(index: 1, title: "Untitled", frame: CGRect(x: 100, y: 100, width: 800, height: 600))
    ]

    @Test("a WindowScope without an AX element reports ax_scope none, not frame_only")
    func scopeWithoutElementIsNone() {
        let scope = Self.scope()
        #expect(scope.axScope == "none")
        #expect(scope.axSkippedReason == "no_ax_window")
    }

    @Test("a WindowScope with ambiguous candidates reports ambiguous_window")
    func scopeWithCandidatesIsAmbiguous() {
        let scope = Self.scope(ambiguous: Self.twoCandidates)
        #expect(scope.axScope == "none")
        #expect(scope.axSkippedReason == "ambiguous_window")
    }

    // MARK: - ground: explicit strategy "ax" fails honestly

    static func grounding() -> GroundingController {
        ToolRegistry(accessibility: AccessibilityController()).grounding
    }

    @Test("ground strategy=ax with a window that has no AXWindow → ok false, error_code no_ax_window")
    func groundAXOnlyNoAXWindow() async {
        let result = await Self.grounding().ground(
            target: "anything", pid: 1, strategy: .ax, window: Self.scope()
        )
        #expect(result.ok == false)
        #expect(result.errorCode == "no_ax_window")
        #expect(result.axSkippedReason == "no_ax_window")
        #expect(result.strategyUsed == "none")
        #expect(result.candidates.isEmpty)
        #expect(result.elementId == nil)
    }

    @Test("ground strategy=ax with an ambiguous window → ok false, error_code ambiguous_window")
    func groundAXOnlyAmbiguousWindow() async {
        let result = await Self.grounding().ground(
            target: "anything", pid: 1, strategy: .ax, window: Self.scope(ambiguous: Self.twoCandidates)
        )
        #expect(result.ok == false)
        #expect(result.errorCode == "ambiguous_window")
        #expect(result.axSkippedReason == "ambiguous_window")
        #expect(result.candidates.isEmpty)
    }

    // MARK: - capture_annotated: withheld payload shape

    @Test("the withheld capture_annotated payload has no elements and names the reason")
    func withheldAnnotatePayloadShape() {
        let fields = ToolRegistry.withheldAnnotateFields(
            reason: .noAXWindow, windowID: 42, ownerName: "Google Chrome", candidates: nil
        )
        #expect(fields["elements"] == .array([]))
        #expect(fields["count"] == .number(0))
        #expect(fields["annotated"] == .bool(false))
        #expect(fields["ax_scope"] == .string("none"))
        #expect(fields["ax_scope_reason"] == .string("no_ax_window"))
        #expect(fields["nodes_walked"] == .number(0))
        #expect(fields["element_cap_reached"] == .bool(false))
        #expect(fields["candidates"] == nil)
        let hint = fields["hint"]?.stringValue ?? ""
        #expect(hint.contains("ocr_screen"))
        #expect(hint.contains("element_at_point"))
        #expect(hint.contains("42"))
    }

    @Test("the ambiguous withheld payload carries the candidates")
    func withheldAnnotatePayloadCandidates() {
        let fields = ToolRegistry.withheldAnnotateFields(
            reason: .ambiguousWindow, windowID: 42, ownerName: "Finder", candidates: Self.twoCandidates
        )
        #expect(fields["ax_scope"] == .string("none"))
        #expect(fields["ax_scope_reason"] == .string("ambiguous_window"))
        #expect(fields["candidate_count"] == .number(2))
        #expect(fields["candidates"]?.arrayValue?.count == 2)
        #expect(fields["elements"] == .array([]))
    }
}
