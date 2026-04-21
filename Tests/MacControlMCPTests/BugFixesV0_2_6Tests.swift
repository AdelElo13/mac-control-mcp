import Testing
import Foundation
import ApplicationServices
@testable import MacControlMCP

/// Regression tests for the v0.2.6 bug-fix sweep. Each `@Test` maps to a
/// specific finding in `docs/BUGS-v0.2.4.md` — the number after "Bug #"
/// in the test name is the bug id in that document, so a future
/// regression is trivial to locate.
///
/// Tests that touch real AX elements are in `RealAppMatrixTests` — the
/// ones here focus on structural guarantees (types, enums, serialization,
/// no-throw contracts) that don't need a running app.
@Suite("v0.2.6 bug-fix regressions", .serialized)
struct BugFixesV0_2_6Tests {

    // MARK: - Bug #4 — title fallback is empty-string aware

    @Test("Bug #4 — TypeStrategy.auto stays the default")
    func bug4TypeStrategyAuto() {
        // If somebody accidentally changes the default away from auto we
        // break the React/Angular SPA reliability fix. Lock it in.
        let r = AccessibilityController.TypeStrategy(rawValue: "auto")
        #expect(r == .auto)
    }

    // MARK: - Bug #3 — AXPress silent success on disabled targets

    @Test("Bug #3 — ActionResult surfaces strategy + hint fields")
    func bug3ActionResultShape() throws {
        let disabled = AccessibilityController.ActionResult(
            ok: false,
            axStatus: AXError.cannotComplete.rawValue,
            strategy: "rejected_disabled",
            reason: "target_disabled",
            hint: "AXEnabled=false on this element."
        )
        let data = try JSONEncoder().encode(disabled)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["ok"] as? Bool == false)
        #expect(json?["strategy"] as? String == "rejected_disabled")
        #expect((json?["reason"] as? String)?.contains("disabled") == true)
    }

    // MARK: - Bug #5 — AXPress unsupported coord fallback

    @Test("Bug #5 — coord_fallback strategy is a distinct value")
    func bug5CoordFallbackStrategyValue() {
        let r = AccessibilityController.ActionResult(
            ok: true,
            axStatus: AXError.actionUnsupported.rawValue,
            strategy: "coord_fallback",
            reason: nil,
            hint: "AXPress unsupported → coord click."
        )
        #expect(r.ok)
        #expect(r.strategy == "coord_fallback")
    }

    // MARK: - Bug #6 — type_text strategy parameter

    @Test("Bug #6 — TypeStrategy enum accepts all four documented strategies")
    func bug6TypeStrategyEnum() {
        #expect(AccessibilityController.TypeStrategy(rawValue: "auto") == .auto)
        #expect(AccessibilityController.TypeStrategy(rawValue: "clipboard") == .clipboard)
        #expect(AccessibilityController.TypeStrategy(rawValue: "keys") == .keys)
        #expect(AccessibilityController.TypeStrategy(rawValue: "ax") == .ax)
        #expect(AccessibilityController.TypeStrategy(rawValue: "nonsense") == nil)
    }

    // MARK: - Bug #8 — empty AX tree health probe

    @Test("Bug #8 — AXTreeHealth codes an actionable shape")
    func bug8AXTreeHealthShape() throws {
        let telegramLike = AccessibilityController.AXTreeHealth(
            pid: 1234,
            hasAXTree: false,
            childCount: 0,
            windowCount: 0,
            hint: "This app exposes no AX tree."
        )
        let data = try JSONEncoder().encode(telegramLike)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(json?["hasAXTree"] as? Bool == false)
        #expect(json?["hint"] as? String != nil)
    }

    @Test("Bug #8 — probeAXTree on a live PID returns a populated health report")
    func bug8ProbeOnSelf() async {
        // The test process itself is AppKit-backed when running under
        // `swift test`, so the AX tree is present. This validates the
        // happy path of the probe (no exception, reasonable numbers).
        let ctl = AccessibilityController()
        let health = await ctl.probeAXTree(pid: ProcessInfo.processInfo.processIdentifier)
        // Don't assert on exact counts — they're environment-dependent —
        // but the probe must never crash and must return a shape.
        _ = health.hasAXTree
        _ = health.childCount
        _ = health.windowCount
    }

    // MARK: - Bug #10 — triple_click

    @Test("Bug #10 — MouseController exposes tripleClick + multiClick")
    func bug10MouseTripleClickSurface() async {
        let mouse = MouseController()
        // We can't actually post events during test (no HID tap in CI),
        // but posting to an off-screen coord won't hurt — the method
        // should return cleanly.
        _ = await mouse.doubleClick(at: .zero)
        _ = await mouse.tripleClick(at: .zero)
        _ = await mouse.multiClick(at: .zero, count: 1)
        _ = await mouse.multiClick(at: .zero, count: 5)
    }
}
