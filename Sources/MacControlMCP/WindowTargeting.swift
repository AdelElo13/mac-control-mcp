import Foundation
import CoreGraphics

/// v0.9.0 release blocker (Codex r1 #1) — resolving a `window_id` to the
/// AX window that will actually be mutated.
///
/// The previous rule was `WindowIdentity.matchIndex`: "the FIRST AX window
/// whose frame matches this window-server entry". Two windows of one pid
/// with identical frames — two untitled documents, two 500×500 panels,
/// a duplicated Bambu Studio window — therefore both resolved to AX index
/// 0, and `focus_window` / `move_window` / `resize_window` /
/// `set_window_state` mutated whichever one AX happened to list first.
///
/// This type replaces that with:
///   0. exact id — the AX window whose `_AXUIElementGetWindow` id
///      (`AXWindowID.of`) IS the entry's `CGWindowID`. When every AX window
///      carries an id and none is the entry's, there is no AX window for
///      it (`.noAXWindow`); only id-less AX windows fall through to the
///      heuristics below (Codex r2 #1);
///   1. frame match (unchanged, 2 pt tolerance);
///   2. tie → window title (`kCGWindowName` vs `AXTitle`);
///   3. still ambiguous → refuse (`.ambiguous`), so the tool layer can
///      return `error_code: ambiguous_window` with the candidates instead
///      of silently acting on the wrong window.
///
/// There is deliberately NO order-based tie-break. v0.9.0-rc1 broke a
/// frame+title tie by "Nth of the tied CG entries (z-order) == Nth of the
/// tied AX windows", but AX order only approximates the window server's
/// stacking (Codex r2 #1): same-frame windows A/B listed B,A by AX and A,B
/// by CG were cross-mapped, the action mutated the wrong window, and
/// `verifyIdentity` — same title, same frame — could not notice. A guess
/// that verification cannot catch is worse than a refusal.
///
/// It also owns the POST-action check (`verifyIdentity`): after acting on
/// a concrete AX element, does that element still describe the window the
/// caller named?
///
/// Everything here is **pure** and generic over the AX handle type, so the
/// whole decision table is unit-testable with plain `String` tokens — no
/// AX, no windows, no TCC grants, no unlocked screen.
enum WindowTargeting {

    /// One of an app's AX windows, reduced to what disambiguation needs.
    struct AXWindow<Handle: Sendable>: Sendable {
        /// The thing actions are performed ON. Carried through from
        /// resolution to the action so an AX-array reorder in between
        /// cannot retarget.
        let handle: Handle
        /// Position in `kAXWindowsAttribute` at resolve time. Reported for
        /// diagnostics and for the legacy `pid` + `index` API only —
        /// nothing acts on it.
        let index: Int
        let frame: CGRect?
        let title: String?
        /// The window-server id this AX element maps to EXACTLY
        /// (`AXWindowID.of`, Codex r2 #1). nil when the private symbol is
        /// unavailable or the element is not a window — then, and only
        /// then, frame/title matching is used for it.
        let windowID: CGWindowID?

        init(handle: Handle, index: Int, frame: CGRect?, title: String?, windowID: CGWindowID? = nil) {
            self.handle = handle
            self.index = index
            self.frame = frame
            self.title = title
            self.windowID = windowID
        }
    }

    /// One of several indistinguishable AX windows, as reported back to
    /// the caller in an `ambiguous_window` error.
    struct Candidate: Sendable, Equatable {
        let index: Int
        let title: String
        let frame: CGRect?

        var payload: [String: JSONValue] {
            var out: [String: JSONValue] = [
                "ax_index": .number(Double(index)),
                "title": .string(title)
            ]
            if let frame {
                out["x"] = .number(Double(frame.origin.x))
                out["y"] = .number(Double(frame.origin.y))
                out["width"] = .number(Double(frame.width))
                out["height"] = .number(Double(frame.height))
            }
            return out
        }
    }

    enum Outcome<Handle: Sendable>: Sendable {
        /// Exactly one AX window is the window named by the id.
        case matched(handle: Handle, index: Int)
        /// The app publishes no AX window with this frame — Chrome's
        /// browser windows, parts of Electron, and minimized windows
        /// (whose AX frame no longer tracks their window-server bounds).
        case noAXWindow
        /// Several AX windows are indistinguishable. Refusing beats
        /// guessing: the caller gets the candidates and can pick with
        /// `pid` + `index`, or raise the window it means first.
        case ambiguous([Candidate])
    }

    // MARK: - Resolution

    /// Which AX window is the window-server entry `entry`?
    ///
    /// - Parameters:
    ///   - entry: the window-server entry the `window_id` resolved to.
    ///   - siblings: every window-server entry of the SAME pid, in
    ///     snapshot order (the window server returns front-to-back).
    ///     Must include `entry` itself. Kept in the signature for the
    ///     tool layer's diagnostics; no longer consulted for a tie-break
    ///     (Codex r2 #1 — order is not identity).
    ///   - axWindows: the app's AX windows, in `kAXWindowsAttribute`
    ///     order, each carrying its exact `windowID` when known.
    static func resolve<Handle: Sendable>(
        entry: WindowIdentity.Entry,
        siblings: [WindowIdentity.Entry],
        axWindows: [AXWindow<Handle>],
        tolerance: Double = WindowIdentity.frameTolerance
    ) -> Outcome<Handle> {
        // 0. Exact id (Codex r2 #1). An AX window that KNOWS it is this
        //    window-server entry wins outright — no frame, no title, no
        //    order involved. Conversely an AX window that knows it is a
        //    DIFFERENT entry can never be the answer, so it is dropped
        //    before the heuristics run; only id-less windows (private
        //    symbol missing, element not a window) stay eligible.
        if let exact = axWindows.first(where: { $0.windowID == entry.windowID }) {
            return .matched(handle: exact.handle, index: exact.index)
        }
        let unidentified = axWindows.filter { $0.windowID == nil }
        guard !unidentified.isEmpty else { return .noAXWindow }

        // 1. Frame.
        let frameMatches = unidentified.filter { candidate in
            guard let frame = candidate.frame else { return false }
            return WindowIdentity.framesMatch(entry.bounds, frame, tolerance: tolerance)
        }
        guard !frameMatches.isEmpty else { return .noAXWindow }
        if frameMatches.count == 1 {
            return .matched(handle: frameMatches[0].handle, index: frameMatches[0].index)
        }

        // 2. Title. Only useful when at least one AX window actually
        //    carries the window-server title: an app that publishes no AX
        //    titles must not narrow the pool to nothing.
        let titleMatches = frameMatches.filter { normalized($0.title) == normalized(entry.title) }
        let pool = titleMatches.isEmpty ? frameMatches : titleMatches
        if pool.count == 1 {
            return .matched(handle: pool[0].handle, index: pool[0].index)
        }

        // 3. Refuse. Same frame, same title, no exact id: nothing that
        //    remains can tell these windows apart, and an order-based
        //    guess is exactly the cross-mapping Codex r2 #1 caught.
        return .ambiguous(pool.map {
            Candidate(index: $0.index, title: $0.title ?? "", frame: $0.frame)
        })
    }

    /// Titles compare after trimming: AX and the window server disagree
    /// about trailing whitespace on some apps, and a nil AX title is the
    /// same "no title" an empty `kCGWindowName` means.
    private static func normalized(_ title: String?) -> String {
        (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Post-action verification

    enum Verification: Sendable, Equatable {
        case verified
        /// The element acted on is demonstrably NOT the named window.
        case mismatch(String)
        /// Cannot be decided — reported as `identity_verified: false` with
        /// this reason, never as a mismatch. Minimizing a window, for
        /// instance, legitimately decouples its AX frame from its
        /// window-server bounds.
        case indeterminate(String)
    }

    /// After acting on a concrete AX element, does it still describe the
    /// window named by the caller's `window_id`?
    ///
    /// - Parameters:
    ///   - entry: the window-server entry for that id, re-read AFTER the
    ///     action (nil when the window is gone).
    ///   - axFrame: the element's `AXPosition` + `AXSize`, re-read after
    ///     the action.
    ///   - axTitle: the element's `AXTitle`, re-read after the action.
    ///
    /// Comparing against the POST-action window-server entry is what makes
    /// this work for `move_window` / `resize_window`: both the entry and
    /// the element moved together, so they still agree.
    static func verifyIdentity(
        entry: WindowIdentity.Entry?,
        axFrame: CGRect?,
        axTitle: String?,
        tolerance: Double = WindowIdentity.frameTolerance
    ) -> Verification {
        guard let entry else { return .indeterminate("window_gone") }
        guard let axFrame, axFrame.origin.x.isFinite, axFrame.origin.y.isFinite,
              axFrame.width.isFinite, axFrame.height.isFinite
        else { return .indeterminate("no_ax_geometry") }

        let entryTitle = normalized(entry.title)
        let elementTitle = normalized(axTitle)
        if !entryTitle.isEmpty, !elementTitle.isEmpty, entryTitle != elementTitle {
            return .mismatch("title")
        }
        if !WindowIdentity.framesMatch(entry.bounds, axFrame, tolerance: tolerance) {
            // A minimized / off-Space window parks its AX frame far away
            // from its window-server bounds. That is expected, not a
            // retarget.
            return entry.isOnscreen
                ? .mismatch("frame")
                : .indeterminate("offscreen_frame_divergence")
        }
        return .verified
    }
}
