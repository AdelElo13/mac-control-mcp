import Foundation
import ApplicationServices
import CoreGraphics

/// v0.9.0 release blocker (Codex r2 #1) — the EXACT bridge from an AX
/// window element to its window-server id.
///
/// Every other AX ↔ CG correlation in this codebase is a heuristic over
/// frame and title. Two windows of one pid with the same frame and the
/// same title (two "Untitled" documents, a duplicated panel) are
/// indistinguishable to those heuristics, and any order-based tie-break
/// (AX order ↔ CG z-order) is a guess that can cross-map them — the action
/// then mutates the wrong window and post-verification cannot tell.
///
/// HIServices carries `_AXUIElementGetWindow(AXUIElementRef, CGWindowID *)
/// -> AXError`, which answers the question exactly. It is private but has
/// been stable across every macOS release since 10.x and is what yabai,
/// Hammerspoon and alt-tab rely on. Looked up with `dlsym` at runtime —
/// the same pattern as `PermissionContext.responsiblePID(for:)` — so a
/// future OS that drops it degrades to "unknown" (nil) and the frame/title
/// path takes over, instead of failing to launch. Notarization does not
/// reject a dynamically resolved private symbol; the App Store would, and
/// this binary is not App Store distributed.
enum AXWindowID {
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>) -> AXError

    /// Resolved once per process. nil when the symbol is absent.
    private static let getWindow: GetWindowFn? = {
        let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)
        guard let symbol = dlsym(rtldDefault, "_AXUIElementGetWindow") else { return nil }
        return unsafeBitCast(symbol, to: GetWindowFn.self)
    }()

    /// The `CGWindowID` of an AX window element, or nil when the symbol is
    /// missing, the call fails, or the element is not a window (the call
    /// then reports 0, which is never a real window-server id).
    static func of(_ element: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(element, &id) == .success, id != 0 else { return nil }
        return id
    }
}
