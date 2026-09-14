import Testing
import Foundation
import CoreGraphics
import ApplicationServices
@testable import MacControlMCP

/// v0.9.0 release blocker (Codex r1 #2) — window-scoped grounding and
/// annotation were GEOMETRIC ONLY.
///
/// `ground(window_id:)` and `capture_annotated` walked the whole pid tree
/// and kept whatever fell inside a rectangle, so with two overlapping
/// windows of the same app an element of the window BEHIND was a valid
/// match — and `capture_annotated` would draw a box over window A's
/// pixels carrying window B's `element_id`.
///
/// The fix walks from the resolved `AXWindow` ELEMENT as the tree root, so
/// the other window's subtree is never visited. These tests model that
/// with a synthetic two-window tree (no AX, no screen, no permissions).
///
/// Second half: a partially visible element used to report its UNCLIPPED
/// centre as "click-ready", which can sit outside the captured image (and
/// outside the window). `center` is now clipped to the window's visible
/// rect and elements with less than `minVisibleArea` visible are dropped.
@Suite("Window-scoped tree walk + centre clipping")
struct WindowScopedTreeTests {

    // MARK: - Synthetic two-window tree

    /// A node in a fake AX tree. Mirrors the shape the real walk produces
    /// (role / frame / children) without touching Accessibility.
    struct FakeNode {
        let id: String
        let role: String
        let frame: CGRect
        var children: [FakeNode] = []
    }

    /// Walk a fake tree from `root`, exactly as the real walk does: every
    /// node reachable from the root, nothing else.
    static func walk(_ root: FakeNode) -> [FakeNode] {
        [root] + root.children.flatMap { walk($0) }
    }

    /// Two overlapping windows of ONE app. Window B (behind) is fully
    /// covered by window A (front) — same frame — so a geometric filter
    /// cannot tell their elements apart.
    static func app() -> FakeNode {
        let frame = CGRect(x: 100, y: 100, width: 400, height: 300)
        let windowA = FakeNode(
            id: "A", role: "AXWindow", frame: frame,
            children: [
                FakeNode(id: "A.ok", role: "AXButton", frame: CGRect(x: 150, y: 150, width: 80, height: 30)),
                FakeNode(id: "A.cancel", role: "AXButton", frame: CGRect(x: 250, y: 150, width: 80, height: 30))
            ]
        )
        let windowB = FakeNode(
            id: "B", role: "AXWindow", frame: frame,
            children: [
                FakeNode(id: "B.ok", role: "AXButton", frame: CGRect(x: 150, y: 150, width: 80, height: 30)),
                FakeNode(id: "B.delete", role: "AXButton", frame: CGRect(x: 250, y: 150, width: 80, height: 30))
            ]
        )
        return FakeNode(id: "app", role: "AXApplication", frame: .zero, children: [windowA, windowB])
    }

    @Test("walking from the app root sees BOTH overlapping windows' elements (the bug)")
    func appRootWalkLeaksTheOtherWindow() {
        let all = Self.walk(Self.app()).filter { $0.role == "AXButton" }
        let windowRect = CGRect(x: 100, y: 100, width: 400, height: 300)
        // The geometric filter the old code relied on keeps everything,
        // because both windows occupy the same rectangle.
        let geometric = all.filter { WindowIdentity.rect($0.frame, isWithin: windowRect) }
        #expect(geometric.count == 4)
        #expect(geometric.contains { $0.id == "B.delete" })
    }

    @Test("walking from the resolved AXWindow element sees ONLY that window's elements")
    func windowRootWalkExcludesTheOtherWindow() {
        let app = Self.app()
        guard let windowA = app.children.first(where: { $0.id == "A" }) else {
            Issue.record("fixture broken")
            return
        }
        let scoped = Self.walk(windowA).filter { $0.role == "AXButton" }
        #expect(scoped.map(\.id).sorted() == ["A.cancel", "A.ok"])
        #expect(!scoped.contains { $0.id.hasPrefix("B.") })
    }

    // MARK: - AX path prefix (element-id stability, v0.9 C-5)

    @Test("a window-rooted walk keeps the app-root AX path prefix, so element_ids do not change")
    func windowRootedPathsMatchAppRootedPaths() {
        // App-root walk: app (depth 0, empty path) → window at ordinal 1 →
        // button at ordinal 0.
        let appRootedWindowPath = AXPath.appending(
            [], role: "AXWindow", index: 1, identifier: nil, title: "Notes", subrole: nil
        )
        let appRootedButtonPath = AXPath.appending(
            appRootedWindowPath, role: "AXButton", index: 0, identifier: "ok", title: "OK", subrole: nil
        )

        // Window-rooted walk: the root is SEEDED with the window's own
        // path, so its children append onto the same prefix.
        let seeded = AccessibilityController.WalkRoot(
            element: AXUIElementCreateApplication(1), path: appRootedWindowPath
        )
        let windowRootedButtonPath = AXPath.appending(
            seeded.path, role: "AXButton", index: 0, identifier: "ok", title: "OK", subrole: nil
        )

        #expect(windowRootedButtonPath == appRootedButtonPath)
        #expect(AXPath.identifier(pid: 1234, path: windowRootedButtonPath)
                == AXPath.identifier(pid: 1234, path: appRootedButtonPath))
    }

    // MARK: - Centre clipping

    static let window = CGRect(x: 100, y: 100, width: 400, height: 300)

    @Test("a fully visible element keeps its own centre")
    func fullyVisibleCentre() {
        let frame = CGRect(x: 150, y: 150, width: 80, height: 40)
        #expect(ScreenAnnotator.visibleRect(of: frame, clippedTo: [Self.window]) == frame)
        #expect(ScreenAnnotator.clippedCenter(of: frame, clippedTo: [Self.window]) == CGPoint(x: 190, y: 170))
    }

    @Test("a half-clipped element's centre is pulled inside the window")
    func clippedCentreIsInsideTheWindow() {
        // 100 pt wide, but only its left 50 pt are inside the window.
        let frame = CGRect(x: 450, y: 150, width: 100, height: 40)
        let raw = CGPoint(x: frame.midX, y: frame.midY)
        #expect(!Self.window.contains(raw))

        let visible = ScreenAnnotator.visibleRect(of: frame, clippedTo: [Self.window])
        #expect(visible == CGRect(x: 450, y: 150, width: 50, height: 40))

        guard let centre = ScreenAnnotator.clippedCenter(of: frame, clippedTo: [Self.window]) else {
            Issue.record("expected a clipped centre")
            return
        }
        #expect(centre == CGPoint(x: 475, y: 170))
        #expect(Self.window.contains(centre))
    }

    @Test("clipping also respects the display union, not just the window")
    func clippedToDisplayUnionToo() {
        let display = CGRect(x: 0, y: 0, width: 400, height: 1000)
        let frame = CGRect(x: 300, y: 150, width: 200, height: 40)
        let visible = ScreenAnnotator.visibleRect(of: frame, clippedTo: [Self.window, display])
        #expect(visible == CGRect(x: 300, y: 150, width: 100, height: 40))
        #expect(ScreenAnnotator.clippedCenter(of: frame, clippedTo: [Self.window, display]) == CGPoint(x: 350, y: 170))
    }

    @Test("an element with less than minVisibleArea visible is dropped")
    func sliverIsDropped() {
        // 1 pt × 2 pt sliver = 2 pt² visible, below the 4 pt² floor.
        let sliver = CGRect(x: 499, y: 150, width: 60, height: 2)
        #expect(ScreenAnnotator.visibleRect(of: sliver, clippedTo: [Self.window]) == nil)
        #expect(ScreenAnnotator.clippedCenter(of: sliver, clippedTo: [Self.window]) == nil)
    }

    @Test("a completely off-window element is dropped")
    func offWindowIsDropped() {
        let outside = CGRect(x: 900, y: 900, width: 100, height: 50)
        #expect(ScreenAnnotator.visibleRect(of: outside, clippedTo: [Self.window]) == nil)
    }

    @Test("a non-finite frame is dropped rather than producing a NaN centre")
    func nonFiniteIsDropped() {
        let nan = CGRect(x: CGFloat.nan, y: 150, width: 80, height: 40)
        #expect(ScreenAnnotator.visibleRect(of: nan, clippedTo: [Self.window]) == nil)
        #expect(ScreenAnnotator.clippedCenter(of: nan, clippedTo: [Self.window]) == nil)
    }

    @Test("minVisibleArea is exactly 4 square points and the boundary is inclusive")
    func minVisibleAreaBoundary() {
        #expect(ScreenAnnotator.minVisibleArea == 4.0)
        // Exactly 2 × 2 = 4 pt² visible at the window's right edge → kept.
        let atFloor = CGRect(x: 498, y: 150, width: 60, height: 2)
        #expect(ScreenAnnotator.visibleRect(of: atFloor, clippedTo: [Self.window])
                == CGRect(x: 498, y: 150, width: 2, height: 2))
    }

    @Test("filterInteractive drops elements that are only slivers inside the capture")
    func filterInteractiveUsesVisibleArea() {
        let items = [
            ScreenAnnotator.ElementGeometry(role: "AXButton", title: "inside",
                                            frame: CGRect(x: 150, y: 150, width: 80, height: 30)),
            ScreenAnnotator.ElementGeometry(role: "AXButton", title: "sliver",
                                            frame: CGRect(x: 499, y: 150, width: 80, height: 2))
        ]
        let picked = ScreenAnnotator.filterInteractive(items, captureRect: Self.window, limit: 10)
        #expect(picked == [0])
    }
}
