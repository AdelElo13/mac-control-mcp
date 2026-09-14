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
        /// `kCGWindowOwnerName` — the owning application's name, straight
        /// from the window-server entry. Taken here rather than from
        /// NSRunningApplication so nothing in this path needs AppKit or a
        /// MainActor hop.
        let ownerName: String
        let bounds: CGRect
        let isOnscreen: Bool
        let layer: Int
        /// Front-to-back index among the layer-0 windows that are
        /// currently ON SCREEN: 0 is the frontmost window. nil for
        /// overlays/menubar/dock entries (non-zero layer) and for
        /// minimized / off-Space windows, which are not in the visible
        /// stack at all — a number there would be meaningless.
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
            let onscreen = (dict[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let zOrder: Int?
            if layer == 0 && onscreen {
                zOrder = z
                z += 1
            } else {
                zOrder = nil
            }
            out.append(Entry(
                windowID: CGWindowID(idNum.uint32Value),
                pid: pidNum.int32Value,
                title: (dict[kCGWindowName as String] as? String) ?? "",
                ownerName: (dict[kCGWindowOwnerName as String] as? String) ?? "",
                bounds: CGRect(x: x, y: y, width: w, height: h),
                isOnscreen: onscreen,
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

    /// The frontmost on-screen normal window — the one that receives
    /// keystrokes.
    ///
    /// The window server already knows this (the first layer-0 on-screen
    /// entry of a snapshot IS the front window), so `list_windows` needs
    /// no `NSWorkspace.frontmostApplication`, which is MainActor affine
    /// and cost a hop off the AX work queue on every call.
    static func frontmostWindow(in entries: [Entry]) -> Entry? {
        entries.first { $0.zOrder == 0 }
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

    /// One display's index + bounds in global points. Deliberately NOT
    /// `DisplayController.DisplayInfo`: this is read straight from
    /// CoreGraphics on the calling thread (`CGGetActiveDisplayList` +
    /// `CGDisplayBounds`, both cheap and thread-safe), so the hot
    /// `list_windows` path needs neither an actor hop nor AppKit.
    struct DisplayBounds: Sendable, Equatable {
        let index: Int
        let rect: CGRect
    }

    /// Live display geometry, without going through `DisplayController`.
    static func displayBounds() -> [DisplayBounds] {
        var count: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &count)
        guard count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        var actual: UInt32 = 0
        CGGetActiveDisplayList(count, &ids, &actual)
        return ids.prefix(Int(actual)).enumerated().map {
            DisplayBounds(index: $0.offset, rect: CGDisplayBounds($0.element))
        }
    }

    /// Adapter for callers that already hold a `DisplayController` list
    /// (convert_coordinates), so display geometry is never read twice.
    static func displayBounds(of displays: [DisplayController.DisplayInfo]) -> [DisplayBounds] {
        displays.map {
            DisplayBounds(
                index: $0.index,
                rect: CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height)
            )
        }
    }

    static func displayIndex(containing point: CGPoint, displays: [DisplayBounds]) -> Int? {
        displays.first { $0.rect.contains(point) }?.index
    }

    /// Which display a window is "on", decided by its CENTER — a window
    /// straddling the seam belongs to the display showing most of it.
    static func displayIndex(containing windowRect: CGRect, displays: [DisplayBounds]) -> Int? {
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
    static func unionBounds(of displays: [DisplayBounds]) -> CGRect? {
        guard let first = displays.first else { return nil }
        return displays.dropFirst().reduce(first.rect) { $0.union($1.rect) }
    }

    /// Bottom edge of every display, for the "parked off-screen menu
    /// item" signature (x≈0, y≈bottom of some display).
    static func bottomEdges(of displays: [DisplayBounds]) -> [Double] {
        displays.map { Double($0.rect.maxY) }
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
