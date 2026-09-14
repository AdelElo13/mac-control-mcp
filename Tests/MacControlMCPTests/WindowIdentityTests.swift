import Testing
import Foundation
import CoreGraphics
@testable import MacControlMCP

/// v0.9 workstream A (C-2 / C-3 / C-14): pure helpers behind window
/// identity — parsing a `CGWindowListCopyWindowInfo` snapshot into
/// addressable entries, matching a CG entry's frame against an AX window
/// frame, and deciding which display a window/point lives on.
///
/// Everything here is exercised over synthetic CGWindowList-shaped
/// dictionaries so it runs with no windows, no permissions and no
/// displays attached (CI).
@Suite("Window identity helpers")
struct WindowIdentityTests {

    // MARK: - Fixtures

    static func cgEntry(
        id: UInt32,
        pid: Int32,
        title: String? = nil,
        x: Double = 0, y: Double = 100, w: Double = 500, h: Double = 400,
        onscreen: Bool = true,
        layer: Int = 0
    ) -> [String: Any] {
        var dict: [String: Any] = [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowBounds as String: [
                "X": NSNumber(value: x), "Y": NSNumber(value: y),
                "Width": NSNumber(value: w), "Height": NSNumber(value: h)
            ],
            kCGWindowIsOnscreen as String: NSNumber(value: onscreen)
        ]
        if let title { dict[kCGWindowName as String] = title }
        return dict
    }

    static func display(index: Int, x: Double, y: Double, w: Double, h: Double, main: Bool = false)
        -> DisplayController.DisplayInfo {
        DisplayController.DisplayInfo(
            id: UInt32(1000 + index), index: index,
            x: x, y: y, width: w, height: h, scale: 2.0, main: main
        )
    }

    // MARK: - Parsing

    @Test("entries() preserves front-to-back order, fills missing titles, keeps ids")
    func parseEntries() {
        let info = [
            Self.cgEntry(id: 11, pid: 1, title: "front"),
            Self.cgEntry(id: 22, pid: 2),                        // no kCGWindowName
            Self.cgEntry(id: 33, pid: 2, title: "back")
        ]
        let entries = WindowIdentity.entries(from: info)
        #expect(entries.map(\.windowID) == [11, 22, 33])
        #expect(entries.map(\.title) == ["front", "", "back"])
        #expect(entries.map(\.zOrder) == [0, 1, 2])
        #expect(entries[0].pid == 1)
        #expect(entries[1].bounds == CGRect(x: 0, y: 100, width: 500, height: 400))
    }

    @Test("z_order ranks only on-screen layer-0 windows; overlays and minimized get none")
    func zOrderSkipsOverlays() {
        let info = [
            Self.cgEntry(id: 1, pid: 1, layer: 25),              // menubar overlay
            Self.cgEntry(id: 2, pid: 1),
            Self.cgEntry(id: 4, pid: 1, onscreen: false),        // minimized / off-Space
            Self.cgEntry(id: 3, pid: 1)
        ]
        let entries = WindowIdentity.entries(from: info)
        #expect(entries.map(\.zOrder) == [nil, 0, nil, 1])
        #expect(entries.map(\.layer) == [25, 0, 0, 0])
    }

    @Test("entry(id:) finds a window and reports nil for an unknown id")
    func lookupByID() {
        let entries = WindowIdentity.entries(from: [
            Self.cgEntry(id: 7, pid: 1), Self.cgEntry(id: 9, pid: 2)
        ])
        #expect(WindowIdentity.entry(id: 9, in: entries)?.pid == 2)
        #expect(WindowIdentity.entry(id: 12345, in: entries) == nil)
    }

    // MARK: - Frame matching (CG entry → AX window)

    @Test("framesMatch tolerates sub-pixel drift but not a real difference")
    func frameTolerance() {
        let cg = CGRect(x: 0, y: 39, width: 1800, height: 1056)
        #expect(WindowIdentity.framesMatch(cg, cg))
        #expect(WindowIdentity.framesMatch(cg, CGRect(x: 0.4, y: 39.5, width: 1800, height: 1055.6)))
        #expect(!WindowIdentity.framesMatch(cg, CGRect(x: 0, y: 39, width: 1800, height: 1000)))
        #expect(!WindowIdentity.framesMatch(cg, CGRect(x: 40, y: 39, width: 1800, height: 1056)))
    }

    @Test("matchIndex picks the AX window whose frame equals the CG bounds")
    func matchIndexResolvesAXWindow() {
        let frames: [CGRect?] = [
            CGRect(x: 0, y: 39, width: 1800, height: 1056),
            nil,                                                    // AX gave no frame
            CGRect(x: 410, y: 158, width: 980, height: 600)
        ]
        #expect(WindowIdentity.matchIndex(bounds: CGRect(x: 410, y: 158, width: 980, height: 600), in: frames) == 2)
        #expect(WindowIdentity.matchIndex(bounds: CGRect(x: 0, y: 39, width: 1800, height: 1056), in: frames) == 0)
        // Two identical 500x500 untitled windows: first match wins, deterministically.
        let dupes: [CGRect?] = [CGRect(x: 0, y: 0, width: 500, height: 500),
                                CGRect(x: 0, y: 0, width: 500, height: 500)]
        #expect(WindowIdentity.matchIndex(bounds: CGRect(x: 0, y: 0, width: 500, height: 500), in: dupes) == 0)
        #expect(WindowIdentity.matchIndex(bounds: CGRect(x: 5, y: 5, width: 100, height: 100), in: frames) == nil)
    }

    // MARK: - Multi-display containment (C-14)

    @Test("displayIndex maps a point to the display that contains it")
    func pointContainment() {
        let displays = [
            Self.display(index: 0, x: 0, y: 0, w: 1800, h: 1169, main: true),
            Self.display(index: 1, x: 1800, y: 0, w: 2560, h: 1440)
        ]
        #expect(WindowIdentity.displayIndex(containing: CGPoint(x: 100, y: 100), displays: displays) == 0)
        #expect(WindowIdentity.displayIndex(containing: CGPoint(x: 2000, y: 100), displays: displays) == 1)
        #expect(WindowIdentity.displayIndex(containing: CGPoint(x: -50, y: 100), displays: displays) == nil)
        #expect(WindowIdentity.displayIndex(containing: CGPoint(x: 100, y: 100), displays: []) == nil)
    }

    @Test("displayIndex maps a window rect by its center, so a straddling window resolves")
    func rectContainment() {
        let displays = [
            Self.display(index: 0, x: 0, y: 0, w: 1800, h: 1169, main: true),
            Self.display(index: 1, x: 1800, y: 0, w: 2560, h: 1440)
        ]
        // Mostly on display 1, overlapping the seam.
        let straddling = CGRect(x: 1700, y: 100, width: 800, height: 600)
        #expect(WindowIdentity.displayIndex(containing: straddling, displays: displays) == 1)
        #expect(WindowIdentity.displayIndex(containing: CGRect(x: 0, y: 39, width: 1800, height: 1056),
                                            displays: displays) == 0)
    }

    @Test("unionBounds spans every display, not just the main one (C-14)")
    func union() {
        let displays = [
            Self.display(index: 0, x: 0, y: 0, w: 1800, h: 1169, main: true),
            Self.display(index: 1, x: 1800, y: -200, w: 2560, h: 1440)
        ]
        let union = WindowIdentity.unionBounds(of: displays)
        #expect(union == CGRect(x: 0, y: -200, width: 4360, height: 1440))
        #expect(WindowIdentity.unionBounds(of: []) == nil)
        // An AX candidate on the secondary display is inside the union but
        // outside the main display's bounds — the old filter dropped it.
        #expect(union!.contains(CGPoint(x: 3000, y: 300)))
    }

    @Test("rect(_:isWithin:) scopes AX candidates to one window's frame")
    func withinWindow() {
        let window = CGRect(x: 100, y: 100, width: 800, height: 600)
        #expect(WindowIdentity.rect(CGRect(x: 120, y: 120, width: 100, height: 30), isWithin: window))
        // Exactly on the edge still counts (a control flush with the frame).
        #expect(WindowIdentity.rect(CGRect(x: 100, y: 100, width: 800, height: 600), isWithin: window))
        #expect(!WindowIdentity.rect(CGRect(x: 1200, y: 120, width: 100, height: 30), isWithin: window))
        // A control that hangs out of the window (menu / popover) is not scoped in.
        #expect(!WindowIdentity.rect(CGRect(x: 850, y: 120, width: 200, height: 30), isWithin: window))
    }

    // MARK: - list_windows enrichment

    @Test("enrich attaches window_id / z_order / display_index / is_focused by frame match")
    func enrichWindows() {
        let safari = WindowController.WindowInfo(
            app: "Safari", pid: 681, title: "Apple", x: 0, y: 39, width: 1800, height: 1056,
            minimized: false, main: true, index: 0
        )
        let music = WindowController.WindowInfo(
            app: "Music", pid: 900, title: "", x: 410, y: 158, width: 980, height: 600,
            minimized: false, main: true, index: 0
        )
        let cg = WindowIdentity.entries(from: [
            Self.cgEntry(id: 42, pid: 681, title: "Apple", x: 0, y: 39, w: 1800, h: 1056),
            Self.cgEntry(id: 77, pid: 900, title: "Music", x: 410, y: 158, w: 980, h: 600)
        ])
        let displays = [Self.display(index: 0, x: 0, y: 0, w: 1800, h: 1169, main: true)]

        let out = WindowController.enrich(
            windows: [safari, music], cgEntries: cg, displays: displays, frontmostPID: 681
        )
        #expect(out.map(\.windowID) == [42, 77])
        #expect(out.map(\.zOrder) == [0, 1])
        #expect(out.map(\.displayIndex) == [0, 0])
        #expect(out.map(\.isFocused) == [true, false])
    }

    @Test("enrich leaves window_id nil when no CG entry matches, and never reuses one")
    func enrichUnmatched() {
        let ghost = WindowController.WindowInfo(
            app: "Ghost", pid: 5, title: "", x: 10, y: 10, width: 20, height: 20,
            minimized: true, main: false, index: 0
        )
        let a = WindowController.WindowInfo(
            app: "Dup", pid: 6, title: "", x: 0, y: 0, width: 500, height: 500,
            minimized: false, main: true, index: 0
        )
        let b = WindowController.WindowInfo(
            app: "Dup", pid: 6, title: "", x: 0, y: 0, width: 500, height: 500,
            minimized: false, main: false, index: 1
        )
        let cg = WindowIdentity.entries(from: [
            Self.cgEntry(id: 1, pid: 6, x: 0, y: 0, w: 500, h: 500),
            Self.cgEntry(id: 2, pid: 6, x: 0, y: 0, w: 500, h: 500)
        ])
        let out = WindowController.enrich(windows: [ghost, a, b], cgEntries: cg, displays: [], frontmostPID: nil)
        #expect(out[0].windowID == nil)
        #expect(out[0].displayIndex == nil)
        // Two identical windows of one pid must get DIFFERENT ids.
        #expect(out[1].windowID == 1)
        #expect(out[2].windowID == 2)
        #expect(out.allSatisfy { $0.isFocused == false })
    }

    // MARK: - convert_coordinates containment (C-14 / A-11)

    @Test("convert_coordinates reports which display contains the point")
    func convertReportsDisplayIndex() async {
        let registry = ToolRegistry(accessibility: AccessibilityController())
        let result = await registry.callTool(
            name: "convert_coordinates",
            arguments: ["x": .number(10), "y": .number(10), "from": .string("global"), "to": .string("global")]
        )
        #expect(result.isError == false)
        guard case .object(let payload) = result.structuredContent else {
            Issue.record("convert_coordinates returned no object payload")
            return
        }
        // Present on every success, even with zero displays (then null +
        // in_display_bounds:false) — a caller must never have to guess
        // whether a converted point is on a screen at all.
        #expect(payload["display_index"] != nil)
        #expect(payload["in_display_bounds"] != nil)
        #expect(payload["global_x"] != nil)
        #expect(payload["global_y"] != nil)
    }

    @Test("WindowInfo JSON always carries title and the new identity keys")
    func encoding() throws {
        let info = WindowController.WindowInfo(
            app: "A", pid: 1, title: "", x: 0, y: 0, width: 10, height: 10,
            minimized: false, main: true, index: 0,
            windowID: 42, displayIndex: 1, isFocused: true, zOrder: 3
        )
        let json = String(data: try JSONEncoder().encode(info), encoding: .utf8) ?? ""
        #expect(json.contains("\"title\":\"\""))
        #expect(json.contains("\"window_id\":42"))
        #expect(json.contains("\"display_index\":1"))
        #expect(json.contains("\"is_focused\":true"))
        #expect(json.contains("\"z_order\":3"))
    }
}
