import Foundation
import CoreGraphics

/// v0.9 workstream A (C-2 / C-3 / C-14) — window identity.
///
/// A pid alone does not name a window: two Bambu Studio windows or two
/// untitled 500×500 windows of one app are indistinguishable by
/// `pid + title_contains`, and an AX `index` is only meaningful inside a
/// single `list_windows` response. `CGWindowID` is the system's own
/// stable handle for a window and is what ScreenCaptureKit, the window
/// server and every other macOS automation surface speak.
///
/// Everything in here is **pure** over a `CGWindowListCopyWindowInfo`
/// snapshot (an array of dictionaries) plus a display list, so it is
/// unit-testable without any windows, displays or TCC grants.
enum WindowIdentity {

    /// One window-server entry, normalized.
    struct Entry: Sendable, Equatable {
        let windowID: CGWindowID
        let pid: pid_t
        /// Never nil — the window server omits `kCGWindowName` entirely
        /// for untitled windows (and for every window when the caller
        /// lacks Screen Recording), which made `title` disappear from
        /// `list_windows` output rather than come back empty.
        let title: String
        let bounds: CGRect
        let isOnscreen: Bool
        let layer: Int
        /// Front-to-back index among the **layer-0** (normal application)
        /// windows of the snapshot: 0 is the frontmost window on screen.
        /// nil for overlays/menubar/dock entries, which have no
        /// meaningful place in the app-window stack.
        let zOrder: Int?
    }

    /// Positions and sizes coming from AX and from the window server are
    /// both global points and agree exactly in practice (verified B-1,
    /// 3/3 windows), but a window mid-animation can report a sub-point
    /// difference. 2 pt is tight enough not to confuse two real windows
    /// and loose enough to survive rounding.
    static let frameTolerance: Double = 2.0

    // MARK: - Parsing a window-server snapshot

    /// Normalize a `CGWindowListCopyWindowInfo` array. Order is preserved
    /// — the window server returns windows front-to-back — and entries
    /// without a usable id/pid/bounds are dropped.
    static func entries(from info: [[String: Any]]) -> [Entry] {
        var out: [Entry] = []
        var z = 0
        for dict in info {
            guard
                let idNum = dict[kCGWindowNumber as String] as? NSNumber,
                let pidNum = dict[kCGWindowOwnerPID as String] as? NSNumber,
                let boundsDict = dict[kCGWindowBounds as String] as? [String: Any]
            else { continue }
            let x = (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0
            let w = (boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0
            let h = (boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0
            let layer = (dict[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            let zOrder: Int?
            if layer == 0 {
                zOrder = z
                z += 1
            } else {
                zOrder = nil
            }
            out.append(Entry(
                windowID: CGWindowID(idNum.uint32Value),
                pid: pidNum.int32Value,
                title: (dict[kCGWindowName as String] as? String) ?? "",
                bounds: CGRect(x: x, y: y, width: w, height: h),
                isOnscreen: (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false,
                layer: layer,
                zOrder: zOrder
            ))
        }
        return out
    }

    /// Live snapshot of every window the window server draws.
    static func copyEntries() -> [Entry] {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        let info = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
        return entries(from: info)
    }

    static func entry(id: CGWindowID, in entries: [Entry]) -> Entry? {
        entries.first { $0.windowID == id }
    }

    // MARK: - Frame matching (CG entry ↔ AX window)

    static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: Double = frameTolerance) -> Bool {
        abs(Double(a.origin.x - b.origin.x)) <= tolerance &&
        abs(Double(a.origin.y - b.origin.y)) <= tolerance &&
        abs(Double(a.width - b.width)) <= tolerance &&
        abs(Double(a.height - b.height)) <= tolerance
    }

    /// Index of the first frame in `frames` that equals `bounds`. `frames`
    /// is index-aligned with an app's AX window list (nil where AX gave no
    /// geometry), so the result is exactly the `index` argument the
    /// existing window tools take. First match wins, so two windows with
    /// identical frames resolve deterministically to the earlier one.
    static func matchIndex(bounds: CGRect, in frames: [CGRect?], tolerance: Double = frameTolerance) -> Int? {
        for (index, frame) in frames.enumerated() {
            guard let frame else { continue }
            if framesMatch(bounds, frame, tolerance: tolerance) { return index }
        }
        return nil
    }

    // MARK: - Displays (C-14)

    static func rect(of display: DisplayController.DisplayInfo) -> CGRect {
        CGRect(x: display.x, y: display.y, width: display.width, height: display.height)
    }

    static func displayIndex(containing point: CGPoint, displays: [DisplayController.DisplayInfo]) -> Int? {
        displays.first { rect(of: $0).contains(point) }?.index
    }

    /// Which display a window is "on", decided by its CENTER — a window
    /// straddling the seam belongs to the display showing most of it.
    static func displayIndex(containing windowRect: CGRect, displays: [DisplayController.DisplayInfo]) -> Int? {
        displayIndex(
            containing: CGPoint(x: windowRect.midX, y: windowRect.midY),
            displays: displays
        )
    }

    /// Bounding box of every attached display. This — not
    /// `CGDisplayBounds(CGMainDisplayID())` — is the correct universe for
    /// deciding whether an AX element is on screen at all (C-14): a
    /// control on a secondary display sits outside the main display's
    /// bounds and was previously dropped as "off-screen".
    static func unionBounds(of displays: [DisplayController.DisplayInfo]) -> CGRect? {
        guard let first = displays.first else { return nil }
        return displays.dropFirst().reduce(rect(of: first)) { $0.union(rect(of: $1)) }
    }

    /// Is `inner` contained in `outer` (edges inclusive, `tolerance` of
    /// slack)? Used to scope AX candidates to one window's frame when a
    /// caller targets a `window_id`.
    static func rect(_ inner: CGRect, isWithin outer: CGRect, tolerance: Double = frameTolerance) -> Bool {
        Double(inner.minX) >= Double(outer.minX) - tolerance &&
        Double(inner.minY) >= Double(outer.minY) - tolerance &&
        Double(inner.maxX) <= Double(outer.maxX) + tolerance &&
        Double(inner.maxY) <= Double(outer.maxY) + tolerance
    }
}
