import Testing
import Foundation
import CoreGraphics
@testable import MacControlMCP

/// Regression coverage for the window-selection bug found in production
/// (v0.8.2, macOS 26): `capture_window pid=<Chrome pid>
/// title_contains="mac-control-mcp"` picked a tiny 22px-high helper/
/// offscreen window belonging to the same pid instead of the real
/// content window, because the old selection logic was
/// `candidates.first { name contains title }` with no size/onscreen/layer
/// filtering.
///
/// These tests exercise `ScreenController.selectWindow(from:titleContains:)`
/// directly as a pure function over `CGWindowListCopyWindowInfo`-shaped
/// dictionaries, so they need no real windows, no Screen Recording
/// permission, and no running app.
@Suite("ScreenController.selectWindow")
struct WindowSelectionTests {
    /// Builds a single CGWindowListCopyWindowInfo-shaped dictionary.
    static func window(
        id: UInt32,
        name: String,
        x: Double = 0,
        y: Double = 0,
        width: Double,
        height: Double,
        onscreen: Bool = true,
        layer: Int = 0,
        alpha: Double = 1.0
    ) -> [String: Any] {
        [
            kCGWindowNumber as String: NSNumber(value: id),
            kCGWindowName as String: name,
            kCGWindowBounds as String: [
                "X": NSNumber(value: x),
                "Y": NSNumber(value: y),
                "Width": NSNumber(value: width),
                "Height": NSNumber(value: height)
            ],
            kCGWindowIsOnscreen as String: NSNumber(value: onscreen),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowAlpha as String: NSNumber(value: alpha)
        ]
    }

    static func id(of dict: [String: Any]?) -> UInt32? {
        (dict?[kCGWindowNumber as String] as? NSNumber)?.uint32Value
    }

    @Test("Tiny helper window listed before the real window is skipped")
    func tinyHelperWindowIsSkipped() {
        let helper = Self.window(id: 1, name: "mac-control-mcp — helper", width: 400, height: 22)
        let real = Self.window(id: 2, name: "mac-control-mcp — Editing script.swift", width: 1200, height: 800)

        // Helper listed FIRST — the old `.first { contains }` logic would
        // have picked it.
        let candidates = [helper, real]
        let picked = ScreenController.selectWindow(from: candidates, titleContains: "mac-control-mcp")

        #expect(Self.id(of: picked) == 2)
    }

    @Test("Onscreen medium window preferred over offscreen large window")
    func onscreenPreferredOverOffscreenLarge() {
        let offscreenLarge = Self.window(id: 1, name: "Chrome — background tab", width: 2000, height: 1400, onscreen: false)
        let onscreenMedium = Self.window(id: 2, name: "Chrome — active tab", width: 800, height: 600, onscreen: true)

        let candidates = [offscreenLarge, onscreenMedium]
        let picked = ScreenController.selectWindow(from: candidates, titleContains: "Chrome")

        #expect(Self.id(of: picked) == 2)
    }

    @Test("Falls back to a small match when only small windows match")
    func fallsBackToSmallMatchWhenNoLargeCandidate() {
        let onlySmall = Self.window(id: 1, name: "mac-control-mcp — tiny panel", width: 30, height: 22)

        let candidates = [onlySmall]
        let picked = ScreenController.selectWindow(from: candidates, titleContains: "mac-control-mcp")

        #expect(Self.id(of: picked) == 1)
    }

    @Test("No title filter picks the largest onscreen layer-0 window")
    func noTitleFilterPicksLargestOnscreenLayer0() {
        let offscreenHuge = Self.window(id: 1, name: "Ghost window", width: 3000, height: 2000, onscreen: false)
        let overlayLayer = Self.window(id: 2, name: "Overlay", width: 1000, height: 1000, onscreen: true, layer: 25)
        let realSmall = Self.window(id: 3, name: "Finder", width: 500, height: 400, onscreen: true, layer: 0)
        let realBig = Self.window(id: 4, name: "Finder", width: 900, height: 700, onscreen: true, layer: 0)

        let candidates = [offscreenHuge, overlayLayer, realSmall, realBig]
        let picked = ScreenController.selectWindow(from: candidates, titleContains: nil)

        #expect(Self.id(of: picked) == 4)
    }

    @Test("No candidate matches the title filter returns nil")
    func noMatchesReturnsNil() {
        let a = Self.window(id: 1, name: "Finder", width: 500, height: 400)
        let b = Self.window(id: 2, name: "Safari", width: 900, height: 700)

        let candidates = [a, b]
        let picked = ScreenController.selectWindow(from: candidates, titleContains: "mac-control-mcp")

        #expect(picked == nil)
    }

    @Test("Empty candidate list returns nil")
    func emptyCandidatesReturnsNil() {
        let picked = ScreenController.selectWindow(from: [], titleContains: nil)
        #expect(picked == nil)
    }

    @Test("No title filter and no candidates returns nil")
    func noTitleFilterAndNoCandidatesReturnsNil() {
        // Distinct from `emptyCandidatesReturnsNil` above: this exercises
        // the "pid has zero windows at all" case explicitly, which is the
        // scenario the capture_window error message needs to describe
        // differently from "title_contains matched nothing."
        let picked = ScreenController.selectWindow(from: [], titleContains: nil)
        #expect(picked == nil)
    }

    @Test("Equal-area candidates tie-break to the frontmost (first) one")
    func equalAreaTiesBreakToFrontmost() {
        // Two windows with IDENTICAL area, both onscreen/layer0/matching
        // title. CGWindowListCopyWindowInfo lists windows front-to-back,
        // so `front` (listed first) is the frontmost window and must win
        // the tie — see the `largest(in:)` doc comment in
        // ScreenController.selectWindow for why `Array.max(by:)` picks
        // the FIRST of equal elements.
        let front = Self.window(id: 1, name: "mac-control-mcp — Editing a.swift", width: 1000, height: 800)
        let back = Self.window(id: 2, name: "mac-control-mcp — Editing b.swift", width: 1000, height: 800)

        let candidates = [front, back]
        let picked = ScreenController.selectWindow(from: candidates, titleContains: "mac-control-mcp")

        #expect(Self.id(of: picked) == 1)
    }

    @Test("Title match is case-insensitive")
    func titleMatchIsCaseInsensitive() {
        let real = Self.window(id: 1, name: "MAC-CONTROL-MCP — Editing script.swift", width: 1200, height: 800)
        let candidates = [real]
        let picked = ScreenController.selectWindow(from: candidates, titleContains: "mac-control-mcp")

        #expect(Self.id(of: picked) == 1)
    }
}
