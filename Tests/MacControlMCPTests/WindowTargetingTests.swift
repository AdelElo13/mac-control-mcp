import Testing
import Foundation
import CoreGraphics
@testable import MacControlMCP

/// v0.9.0 release blocker (Codex r1 #1) — `window_id` could mutate the
/// WRONG window.
///
/// Two failure modes, both reproduced here over synthetic data (no AX, no
/// windows, no TCC grants — runs on CI and with the screen locked):
///
///   1. **Frame-tie retarget.** `WindowIdentity.matchIndex` returned the
///      FIRST AX window whose frame matched the window-server entry, so
///      two windows of one pid with identical frames both resolved to AX
///      index 0 and `focus/move/resize/set_window_state` hit whichever of
///      them AX listed first.
///   2. **Reorder retarget.** Resolution returned `(pid, index)` and the
///      action re-read the AX window array, so a reorder between resolve
///      and act silently retargeted.
///
/// The fix resolves to a concrete window HANDLE once (`WindowTargeting`),
/// disambiguating frame ties by title and then by CG z-order ↔ AX order,
/// and refuses with `ambiguous_window` rather than guessing.
@Suite("Window targeting — frame ties, z-order tie-break, no retarget")
struct WindowTargetingTests {

    // MARK: - Fixtures

    /// A window-server entry. `z` is the front-to-back rank (0 = front).
    static func entry(
        id: UInt32,
        pid: Int32 = 501,
        title: String = "",
        rect: CGRect = CGRect(x: 100, y: 100, width: 500, height: 400),
        z: Int? = 0,
        onscreen: Bool = true
    ) -> WindowIdentity.Entry {
        WindowIdentity.Entry(
            windowID: CGWindowID(id),
            pid: pid,
            title: title,
            ownerName: "Fixture",
            bounds: rect,
            isOnscreen: onscreen,
            layer: 0,
            zOrder: z
        )
    }

    /// An AX window, handle-typed as a plain `String` token so the logic
    /// is exercised without a live `AXUIElement`.
    static func ax(
        _ handle: String,
        index: Int,
        rect: CGRect = CGRect(x: 100, y: 100, width: 500, height: 400),
        title: String? = nil
    ) -> WindowTargeting.AXWindow<String> {
        WindowTargeting.AXWindow(handle: handle, index: index, frame: rect, title: title)
    }

    static func matched(_ outcome: WindowTargeting.Outcome<String>) -> (handle: String, index: Int)? {
        if case .matched(let handle, let index) = outcome { return (handle, index) }
        return nil
    }

    static func ambiguous(_ outcome: WindowTargeting.Outcome<String>) -> [WindowTargeting.Candidate]? {
        if case .ambiguous(let candidates) = outcome { return candidates }
        return nil
    }

    // MARK: - 1. Frame ties

    @Test("a single frame match resolves to that window")
    func singleFrameMatch() {
        let target = Self.entry(id: 1, title: "Doc A")
        let outcome = WindowTargeting.resolve(
            entry: target,
            siblings: [target],
            axWindows: [
                Self.ax("w0", index: 0, rect: CGRect(x: 0, y: 0, width: 300, height: 200)),
                Self.ax("w1", index: 1)
            ]
        )
        #expect(Self.matched(outcome)?.handle == "w1")
        #expect(Self.matched(outcome)?.index == 1)
    }

    @Test("identical frames, different titles → the title picks the right window")
    func identicalFramesDifferentTitles() {
        let a = Self.entry(id: 11, title: "Report.pdf", z: 0)
        let b = Self.entry(id: 12, title: "Notes.txt", z: 1)
        let axWindows = [
            Self.ax("axA", index: 0, title: "Report.pdf"),
            Self.ax("axB", index: 1, title: "Notes.txt")
        ]
        // The BEHIND window (b) must resolve to axB even though axA's
        // frame matches first — the old first-match rule returned index 0
        // for both ids.
        let outcome = WindowTargeting.resolve(entry: b, siblings: [a, b], axWindows: axWindows)
        #expect(Self.matched(outcome)?.handle == "axB")
        #expect(Self.matched(outcome)?.index == 1)

        let front = WindowTargeting.resolve(entry: a, siblings: [a, b], axWindows: axWindows)
        #expect(Self.matched(front)?.handle == "axA")
    }

    @Test("title tie-break survives AX listing the windows in the other order")
    func titleTieBreakIgnoresAXOrder() {
        let a = Self.entry(id: 11, title: "Report.pdf", z: 0)
        let b = Self.entry(id: 12, title: "Notes.txt", z: 1)
        let axWindows = [
            Self.ax("axB", index: 0, title: "Notes.txt"),
            Self.ax("axA", index: 1, title: "Report.pdf")
        ]
        #expect(Self.matched(WindowTargeting.resolve(entry: b, siblings: [a, b], axWindows: axWindows))?.handle == "axB")
        #expect(Self.matched(WindowTargeting.resolve(entry: a, siblings: [a, b], axWindows: axWindows))?.handle == "axA")
    }

    @Test("identical frames AND identical titles → ambiguous_window, never a guess")
    func identicalFramesIdenticalTitlesAmbiguousWithoutZOrder() {
        // Both windows are off-screen/minimized, so neither carries a
        // z-order: nothing left to disambiguate with.
        let a = Self.entry(id: 21, title: "Untitled", z: nil, onscreen: false)
        let b = Self.entry(id: 22, title: "Untitled", z: nil, onscreen: false)
        let outcome = WindowTargeting.resolve(
            entry: b,
            siblings: [a, b],
            axWindows: [
                Self.ax("ax0", index: 0, title: "Untitled"),
                Self.ax("ax1", index: 1, title: "Untitled")
            ]
        )
        let candidates = Self.ambiguous(outcome)
        #expect(candidates?.count == 2)
        #expect(candidates?.map(\.index) == [0, 1])
        #expect(candidates?.allSatisfy { $0.title == "Untitled" } == true)
    }

    @Test("untitled AX windows with identical frames are ambiguous when z-order cannot rank them")
    func untitledIdenticalFramesAmbiguous() {
        let a = Self.entry(id: 31, title: "", z: nil, onscreen: false)
        let b = Self.entry(id: 32, title: "", z: nil, onscreen: false)
        let outcome = WindowTargeting.resolve(
            entry: a,
            siblings: [a, b],
            axWindows: [Self.ax("ax0", index: 0), Self.ax("ax1", index: 1)]
        )
        #expect(Self.ambiguous(outcome)?.count == 2)
    }

    // MARK: - 2. z-order ↔ AX order tie-break

    @Test("identical frames and titles are disambiguated by CG z-order ↔ AX order")
    func zOrderTieBreak() {
        let front = Self.entry(id: 41, title: "Untitled", z: 0)
        let back = Self.entry(id: 42, title: "Untitled", z: 3)
        let axWindows = [
            Self.ax("axFront", index: 0, title: "Untitled"),
            Self.ax("axBack", index: 1, title: "Untitled")
        ]
        #expect(Self.matched(WindowTargeting.resolve(entry: front, siblings: [front, back], axWindows: axWindows))?.handle == "axFront")
        #expect(Self.matched(WindowTargeting.resolve(entry: back, siblings: [front, back], axWindows: axWindows))?.handle == "axBack")
    }

    @Test("z-order tie-break refuses when the tied CG windows and AX windows do not correspond 1:1")
    func zOrderTieBreakRefusesOnCountMismatch() {
        let a = Self.entry(id: 51, title: "Untitled", z: 0)
        let b = Self.entry(id: 52, title: "Untitled", z: 1)
        let c = Self.entry(id: 53, title: "Untitled", z: 2)
        // Three tied window-server entries, only two AX windows: the
        // mapping is not a bijection, so guessing a rank would be wrong.
        let outcome = WindowTargeting.resolve(
            entry: b,
            siblings: [a, b, c],
            axWindows: [
                Self.ax("ax0", index: 0, title: "Untitled"),
                Self.ax("ax1", index: 1, title: "Untitled")
            ]
        )
        #expect(Self.ambiguous(outcome) != nil)
    }

    @Test("no AX window with a matching frame → noAXWindow (Chrome/Electron, minimized)")
    func noMatchingAXWindow() {
        let target = Self.entry(id: 61, rect: CGRect(x: 0, y: 0, width: 900, height: 700))
        let outcome = WindowTargeting.resolve(
            entry: target,
            siblings: [target],
            axWindows: [Self.ax("other", index: 0)]
        )
        if case .noAXWindow = outcome {} else { Issue.record("expected .noAXWindow, got \(outcome)") }
    }

    @Test("frame matching keeps the 2 pt tolerance (mid-animation rounding)")
    func frameToleranceRetained() {
        let target = Self.entry(id: 71, title: "Doc")
        let outcome = WindowTargeting.resolve(
            entry: target,
            siblings: [target],
            axWindows: [Self.ax("ax0", index: 0, rect: CGRect(x: 101, y: 101, width: 499, height: 401))]
        )
        #expect(Self.matched(outcome)?.handle == "ax0")
    }

    // MARK: - 3. No retarget on reorder between resolve and act

    @Test("a reorder between resolve and act cannot retarget: the handle is acted on, not the index")
    func reorderBetweenResolveAndActDoesNotRetarget() {
        let a = Self.entry(id: 81, title: "Report.pdf", z: 0)
        let b = Self.entry(id: 82, title: "Notes.txt", z: 1)

        // A fake AX window-list provider whose order changes between the
        // two reads — exactly the window-reorder race the old
        // (pid, index) handoff lost to.
        var order = [
            Self.ax("axA", index: 0, title: "Report.pdf"),
            Self.ax("axB", index: 1, title: "Notes.txt")
        ]
        let resolved = WindowTargeting.resolve(entry: b, siblings: [a, b], axWindows: order)
        guard let (handle, index) = Self.matched(resolved) else {
            Issue.record("expected a match, got \(resolved)")
            return
        }
        #expect(handle == "axB")
        #expect(index == 1)

        // The user raises the other window; AX now lists them swapped.
        order = [
            Self.ax("axB", index: 0, title: "Notes.txt"),
            Self.ax("axA", index: 1, title: "Report.pdf")
        ]

        // Index-based acting (the OLD behaviour) now hits the wrong window…
        #expect(order[index].handle == "axA")
        // …while the handle carried through from resolve still names the
        // window the caller asked for.
        #expect(order.contains { $0.handle == handle })
    }

    // MARK: - 4. Post-action identity verification

    @Test("post-action verification passes when the element still describes the named window")
    func verifyIdentityOK() {
        let after = Self.entry(id: 91, title: "Doc", rect: CGRect(x: 10, y: 20, width: 800, height: 600))
        let outcome = WindowTargeting.verifyIdentity(
            entry: after,
            axFrame: CGRect(x: 10, y: 20, width: 800, height: 600),
            axTitle: "Doc"
        )
        #expect(outcome == .verified)
    }

    @Test("post-action verification reports a mismatch when the titles diverge")
    func verifyIdentityTitleMismatch() {
        let after = Self.entry(id: 92, title: "Doc")
        let outcome = WindowTargeting.verifyIdentity(
            entry: after,
            axFrame: CGRect(x: 100, y: 100, width: 500, height: 400),
            axTitle: "A Completely Different Window"
        )
        #expect(outcome == .mismatch("title"))
    }

    @Test("post-action verification reports a mismatch when an on-screen window's frames diverge")
    func verifyIdentityFrameMismatch() {
        let after = Self.entry(id: 93, title: "Doc", rect: CGRect(x: 0, y: 0, width: 400, height: 300))
        let outcome = WindowTargeting.verifyIdentity(
            entry: after,
            axFrame: CGRect(x: 900, y: 900, width: 400, height: 300),
            axTitle: "Doc"
        )
        #expect(outcome == .mismatch("frame"))
    }

    @Test("a minimized window's frame divergence is indeterminate, not a mismatch")
    func verifyIdentityMinimizedIsIndeterminate() {
        let after = Self.entry(id: 94, title: "Doc", z: nil, onscreen: false)
        let outcome = WindowTargeting.verifyIdentity(
            entry: after,
            axFrame: CGRect(x: -20_000, y: -20_000, width: 500, height: 400),
            axTitle: "Doc"
        )
        #expect(outcome == .indeterminate("offscreen_frame_divergence"))
    }

    @Test("a window that closed during the action is indeterminate, not a mismatch")
    func verifyIdentityWindowGone() {
        let outcome = WindowTargeting.verifyIdentity(
            entry: nil,
            axFrame: CGRect(x: 0, y: 0, width: 10, height: 10),
            axTitle: "Doc"
        )
        #expect(outcome == .indeterminate("window_gone"))
    }

    @Test("an AX element with no readable geometry is indeterminate")
    func verifyIdentityNoGeometry() {
        let after = Self.entry(id: 95, title: "Doc")
        let outcome = WindowTargeting.verifyIdentity(entry: after, axFrame: nil, axTitle: "Doc")
        #expect(outcome == .indeterminate("no_ax_geometry"))
    }

    @Test("an empty AX title is not evidence of a different window")
    func verifyIdentityEmptyTitleIsNotAMismatch() {
        let after = Self.entry(id: 96, title: "Doc")
        let outcome = WindowTargeting.verifyIdentity(
            entry: after,
            axFrame: CGRect(x: 100, y: 100, width: 500, height: 400),
            axTitle: ""
        )
        #expect(outcome == .verified)
    }
}
