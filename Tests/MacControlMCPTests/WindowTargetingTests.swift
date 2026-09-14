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
/// disambiguating frame ties by title and refusing with `ambiguous_window`
/// rather than guessing.
///
/// Codex r2 #1 (v0.9.0 blocker, second round): the rc1 tie-break "Nth
/// tied CG entry (z-order) == Nth tied AX window" was itself a guess that
/// cross-mapped same-frame, same-title windows when AX order ≠ CG order,
/// and `enrich` had the same flaw when attaching `window_id` by
/// first-unused frame match. The fix carries the EXACT id an AX element
/// reports (`AXWindowID.of`) through both paths; order is never consulted.
@Suite("Window targeting — exact ids, frame/title ties, no guess, no retarget")
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
        title: String? = nil,
        id: UInt32? = nil
    ) -> WindowTargeting.AXWindow<String> {
        WindowTargeting.AXWindow(
            handle: handle, index: index, frame: rect, title: title,
            windowID: id.map { CGWindowID($0) }
        )
    }

    /// An AX-derived `list_windows` row, optionally carrying the exact id
    /// its AX element reported.
    static func row(
        pid: Int32 = 501,
        title: String,
        index: Int,
        rect: CGRect = CGRect(x: 100, y: 100, width: 500, height: 400),
        axID: UInt32? = nil
    ) -> WindowController.WindowInfo {
        WindowController.WindowInfo(
            app: "Fixture", pid: pid, title: title,
            x: rect.origin.x, y: rect.origin.y, width: rect.width, height: rect.height,
            minimized: false, main: index == 0, index: index,
            axWindowID: axID.map { CGWindowID($0) }
        )
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
        // Both windows are off-screen/minimized and carry no exact id:
        // nothing left to disambiguate with.
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

    @Test("untitled AX windows with identical frames and no exact id are ambiguous")
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

    // MARK: - 2. No order-based tie-break (Codex r2 #1)

    @Test("identical frames and titles WITH z-order are still ambiguous — z-order ↔ AX order is a guess (Codex r2 #1)")
    func zOrderNeverBreaksATie() {
        // Codex r2 #1: AX window order only APPROXIMATES the window
        // server's stacking. Two same-frame, same-title windows whose CG
        // order is A,B while AX lists B,A would be cross-mapped by an
        // "Nth tied CG entry == Nth tied AX window" rule, the action would
        // mutate the wrong window, and post-verification (same title, same
        // frame) could not notice. Without an exact id the only honest
        // answer is `ambiguous_window`.
        let front = Self.entry(id: 41, title: "Untitled", z: 0)
        let back = Self.entry(id: 42, title: "Untitled", z: 3)
        let axWindows = [
            Self.ax("axFront", index: 0, title: "Untitled"),
            Self.ax("axBack", index: 1, title: "Untitled")
        ]
        let outcome = WindowTargeting.resolve(entry: back, siblings: [front, back], axWindows: axWindows)
        #expect(Self.ambiguous(outcome)?.count == 2)
        #expect(Self.matched(outcome) == nil)
        let frontOutcome = WindowTargeting.resolve(entry: front, siblings: [front, back], axWindows: axWindows)
        #expect(Self.ambiguous(frontOutcome)?.count == 2)
    }

    @Test("a frame+title tie stays ambiguous when the tied CG windows and AX windows do not correspond 1:1")
    func tieRefusesOnCountMismatch() {
        let a = Self.entry(id: 51, title: "Untitled", z: 0)
        let b = Self.entry(id: 52, title: "Untitled", z: 1)
        let c = Self.entry(id: 53, title: "Untitled", z: 2)
        // Three tied window-server entries, only two AX windows, no ids.
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

    // MARK: - 3. Exact ids (Codex r2 #1)

    @Test("an exact AX window id wins over frame and title")
    func exactIDWinsOverFrameAndTitle() {
        // Same frame, same title, AX order the REVERSE of CG order — the
        // scenario the rc1 order-based tie-break cross-mapped. With ids the
        // answer is exact regardless of order.
        let a = Self.entry(id: 101, title: "Untitled", z: 0)
        let b = Self.entry(id: 102, title: "Untitled", z: 1)
        let axWindows = [
            Self.ax("axB", index: 0, title: "Untitled", id: 102),
            Self.ax("axA", index: 1, title: "Untitled", id: 101)
        ]
        #expect(Self.matched(WindowTargeting.resolve(entry: a, siblings: [a, b], axWindows: axWindows))?.handle == "axA")
        #expect(Self.matched(WindowTargeting.resolve(entry: b, siblings: [a, b], axWindows: axWindows))?.handle == "axB")

        // The id also beats a frame/title that would point elsewhere: an
        // AX window whose geometry is stale (mid-animation, minimized) is
        // still the right window when it says it is.
        let moved = Self.entry(id: 103, title: "Moved", rect: CGRect(x: 900, y: 900, width: 200, height: 200), z: 0)
        let stale = [
            Self.ax("decoy", index: 0, rect: CGRect(x: 900, y: 900, width: 200, height: 200), title: "Moved"),
            Self.ax("real", index: 1, rect: CGRect(x: 0, y: 0, width: 10, height: 10), title: "Other", id: 103)
        ]
        #expect(Self.matched(WindowTargeting.resolve(entry: moved, siblings: [moved], axWindows: stale))?.handle == "real")
    }

    @Test("every AX window carries an id and none is the entry's → noAXWindow, not a frame guess")
    func allIdentifiedNoneMatchIsNoAXWindow() {
        let target = Self.entry(id: 111, title: "Untitled", z: 0)
        // An AX window that KNOWS it is window 112 cannot be window 111,
        // however well its frame and title match.
        let outcome = WindowTargeting.resolve(
            entry: target,
            siblings: [target],
            axWindows: [
                Self.ax("other", index: 0, title: "Untitled", id: 112),
                Self.ax("another", index: 1, title: "Untitled", id: 113)
            ]
        )
        if case .noAXWindow = outcome {} else { Issue.record("expected .noAXWindow, got \(outcome)") }
    }

    @Test("only id-less AX windows fall back to frame/title matching")
    func onlyUnidentifiedFallBack() {
        let target = Self.entry(id: 121, title: "Untitled", z: 0)
        let outcome = WindowTargeting.resolve(
            entry: target,
            siblings: [target],
            axWindows: [
                // Identified as a different window: excluded from the pool
                // even though frame + title tie with the id-less one.
                Self.ax("identifiedOther", index: 0, title: "Untitled", id: 122),
                Self.ax("unknown", index: 1, title: "Untitled")
            ]
        )
        #expect(Self.matched(outcome)?.handle == "unknown")
    }

    // MARK: - 4. list_windows enrichment (Codex r2 #1)

    @Test("enrich: reviewer scenario — AX order B,A vs CG order A,B, same frame — maps by title when ids are absent")
    func enrichReviewerScenarioByTitle() {
        // rc1 gave row B the id of A here (first unused frame match,
        // assuming AX order == CG order).
        let cg = [
            Self.entry(id: 201, title: "A", z: 0),
            Self.entry(id: 202, title: "B", z: 1)
        ]
        let rows = [
            Self.row(title: "B", index: 0),
            Self.row(title: "A", index: 1)
        ]
        let out = WindowController.enrich(windows: rows, cgEntries: cg, displays: [])
        #expect(out.map(\.windowID) == [202, 201])
        #expect(out.map(\.zOrder) == [1, 0])
        #expect(out.map(\.isFocused) == [false, true])
    }

    @Test("enrich: reviewer scenario maps by exact id when present, even with identical titles")
    func enrichReviewerScenarioByID() {
        let cg = [
            Self.entry(id: 211, title: "Untitled", z: 0),
            Self.entry(id: 212, title: "Untitled", z: 1)
        ]
        let rows = [
            Self.row(title: "Untitled", index: 0, axID: 212),
            Self.row(title: "Untitled", index: 1, axID: 211)
        ]
        let out = WindowController.enrich(windows: rows, cgEntries: cg, displays: [])
        #expect(out.map(\.windowID) == [212, 211])
        #expect(out.map(\.zOrder) == [1, 0])
    }

    @Test("enrich: a row without an id cannot take an id another row owns exactly")
    func enrichFallbackCannotStealExactID() {
        let cg = [
            Self.entry(id: 221, title: "Untitled", z: 0),
            Self.entry(id: 222, title: "Untitled", z: 1)
        ]
        // The id-less row is listed FIRST; a naive first-unused walk
        // would hand it 221, which the second row then proves is its own.
        let rows = [
            Self.row(title: "Untitled", index: 0),
            Self.row(title: "Untitled", index: 1, axID: 221)
        ]
        let out = WindowController.enrich(windows: rows, cgEntries: cg, displays: [])
        #expect(out.map(\.windowID) == [222, 221])
    }

    @Test("enrich: an exact id must belong to the row's pid, and a stale one leaves window_id nil")
    func enrichExactIDGuards() {
        let cg = [
            Self.entry(id: 231, pid: 7, title: "X", z: 0)
        ]
        // Right id, wrong pid → no exact match, no frame match (different
        // pid) → nil. A closed window's id that is no longer in the
        // snapshot → nil, never a neighbour's.
        let rows = [
            Self.row(pid: 8, title: "X", index: 0, axID: 231),
            Self.row(pid: 7, title: "X", index: 0, rect: CGRect(x: 0, y: 0, width: 50, height: 50), axID: 999)
        ]
        let out = WindowController.enrich(windows: rows, cgEntries: cg, displays: [])
        #expect(out.map(\.windowID) == [nil, nil])
    }

    @Test("enrich: fallback prefers frame+title, then frame only; nil title equals empty title")
    func enrichFallbackOrder() {
        let cg = [
            Self.entry(id: 241, title: "  Notes ", z: 0),
            Self.entry(id: 242, title: "", z: 1)
        ]
        let rows = [
            Self.row(title: "", index: 0),
            Self.row(title: "Notes", index: 1),
            // No title agrees with anything left: frame-only last resort
            // finds nothing unused → nil.
            Self.row(title: "Third", index: 2)
        ]
        let out = WindowController.enrich(windows: rows, cgEntries: cg, displays: [])
        #expect(out.map(\.windowID) == [242, 241, nil])
    }

    @Test("axWindowID is internal: it never appears in list_windows JSON")
    func axWindowIDNotEncoded() throws {
        let info = Self.row(title: "Doc", index: 0, axID: 251)
        let json = String(data: try JSONEncoder().encode(info), encoding: .utf8) ?? ""
        #expect(!json.contains("251"))
        #expect(!json.lowercased().contains("axwindowid"))
        #expect(!json.contains("ax_window_id"))
    }

    // MARK: - 5. No retarget on reorder between resolve and act

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

    // MARK: - 6. Post-action identity verification

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
