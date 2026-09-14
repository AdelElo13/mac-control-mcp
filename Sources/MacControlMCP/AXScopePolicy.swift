import Foundation
import CoreGraphics

/// Codex r2 #2 — which AX tree a window-scoped call may walk.
///
/// `ground` and `capture_annotated` promise that, with a `window_id` (or a
/// pid + title selection that picked ONE window), every element they hand
/// back belongs to THAT window. Rooting the walk at the window's
/// `AXWindow` element is what makes the promise true. When the window
/// server entry cannot be matched to an `AXWindow` — Chrome browser
/// windows and parts of Electron publish none, and two same-framed
/// same-titled windows are indistinguishable — the old code walked the
/// whole app from its root with only a geometric filter, so a box drawn
/// over window A's pixels could carry the element_id of an overlapping
/// window B of the same app, and the agent clicked B.
///
/// The rule is pure so it can be pinned in a unit test without a live
/// window: a window was requested and has no resolvable AXWindow →
/// WITHHOLD the AX result and say why. An app-root walk is only ever
/// legitimate when no window was requested (plain pid / display target),
/// where "app_root" is an honest description, not a broken promise.
enum AXScopePolicy {

    /// Why AX elements were withheld. The raw value is the `error_code` /
    /// `ax_scope_reason` / `ax_skipped_reason` string on the wire, kept
    /// identical to the codes `resolveWindowTarget` already emits for the
    /// mutating window tools so an agent learns one vocabulary.
    enum WithheldReason: String, Sendable, Equatable {
        case noAXWindow = "no_ax_window"
        case ambiguousWindow = "ambiguous_window"
    }

    enum Decision: Sendable, Equatable {
        /// Walk rooted at the resolved AXWindow — the only scope under
        /// which a window-scoped result is trustworthy.
        case windowSubtree
        /// No window was requested: walk the app root with the geometric
        /// filter and report `ax_scope: "app_root"`.
        case appRoot
        /// A window was requested but cannot be attributed an AX subtree:
        /// no AX walk at all, `ax_scope: "none"`, reason attached.
        case withheld(WithheldReason)

        /// The `ax_scope` string reported on the wire.
        var axScope: String {
            switch self {
            case .windowSubtree: return "window_subtree"
            case .appRoot: return "app_root"
            case .withheld: return "none"
            }
        }

        var reason: WithheldReason? {
            if case .withheld(let reason) = self { return reason }
            return nil
        }
    }

    /// - windowRequested: the caller named a window (`window_id`, or
    ///   `target: "window"` whose pid/title selection picked one).
    /// - hasAXWindow: the resolver produced a concrete AXWindow element.
    /// - ambiguous: the resolver returned indistinguishable candidates.
    static func decide(windowRequested: Bool, hasAXWindow: Bool, ambiguous: Bool) -> Decision {
        guard windowRequested else { return .appRoot }
        // A concrete element is the stronger fact; the resolver never
        // yields both, but if it did we would rather walk the element it
        // handed us than refuse.
        if hasAXWindow { return .windowSubtree }
        return .withheld(ambiguous ? .ambiguousWindow : .noAXWindow)
    }

    /// One human-readable explanation, shared by `capture_annotated`
    /// (`hint`) and `ground` (`error` / `hint`), so both tools tell the
    /// agent the same escape routes.
    static func withheldHint(
        tool: String,
        reason: WithheldReason,
        windowID: CGWindowID?,
        ownerName: String
    ) -> String {
        let window = windowID.map { "window_id \($0)" } ?? "the selected window"
        let why: String
        switch reason {
        case .noAXWindow:
            why = "\(ownerName) publishes no Accessibility window matching \(window) — Chrome browser "
                + "windows, parts of Electron, and MINIMIZED windows (whose AX frame no longer tracks "
                + "their window-server bounds) all do this."
        case .ambiguousWindow:
            why = "several Accessibility windows of \(ownerName) are indistinguishable from \(window) "
                + "(same frame, same title, none frontmost), so no subtree can be attributed to it."
        }
        return "\(tool) withheld AX elements: \(why) An app-wide walk could return elements of an "
            + "overlapping window of the same app, so none are returned. Use ocr_screen with the same "
            + "window_id for text positions, or element_at_point for the control under a known point."
    }
}
