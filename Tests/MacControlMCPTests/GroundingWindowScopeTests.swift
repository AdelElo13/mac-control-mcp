import Testing
import CoreGraphics
@testable import MacControlMCP

/// A-2 + A-3 regressions.
///
/// A-2: `ground(strategy:"ax")` hard-coded `maxDepth: 16` while
/// `find_elements` defaults to 32, so elements at depth 17 (normal in
/// Electron apps) were invisible to `ground` but found by `find_elements`.
///
/// A-3: `ground(strategy:"ocr")` and `ax_tree_augmented` OCR'd the MAIN
/// DISPLAY and ignored `pid`, so an occluded window could never be
/// grounded and — worse (A-1) — OCR text belonging to the window ON TOP
/// was joined onto the covered app's AX nodes as `inferredLabel` at
/// confidence 0.8. The fix OCRs the target window via the per-window
/// ScreenCaptureKit capture, which means block coordinates are in
/// WINDOW-image pixels and must be mapped back to GLOBAL points through
/// the window's bounds.
@Suite("Grounding depth + window-scoped OCR mapping")
struct GroundingWindowScopeTests {

    // MARK: - A-2 depth

    @Test("ground's default AX depth matches find_elements (32), not 16")
    func defaultDepthMatchesFindElements() {
        #expect(GroundingController.defaultMaxDepth == 32)
        #expect(GroundingController.resolveMaxDepth(nil) == 32)
    }

    @Test("caller-supplied max_depth is honoured and clamped to a sane range")
    func depthClamping() {
        #expect(GroundingController.resolveMaxDepth(17) == 17)
        #expect(GroundingController.resolveMaxDepth(0) == 1)
        #expect(GroundingController.resolveMaxDepth(-5) == 1)
        #expect(GroundingController.resolveMaxDepth(9_999) == GroundingController.maxAllowedDepth)
    }

    // MARK: - A-3 window-pixel → global-point mapping

    @Test("window-image pixel center maps to a global screen point")
    func windowPixelToGlobalPoint() {
        // Window at global (900, 200), 600×400 pt, captured at 2× → 1200×800 px.
        // A block centered at pixel (600, 400) is at window point (300, 200)
        // → global point (1200, 400).
        let p = GroundingController.ocrPixelCenterToGlobalPoints(
            blockX: 580, blockY: 390, blockW: 40, blockH: 20,
            imagePixelWidth: 1200, imagePixelHeight: 800,
            windowBounds: CGRect(x: 900, y: 200, width: 600, height: 400)
        )
        #expect(abs(p.x - 1200) < 0.0001)
        #expect(abs(p.y - 400) < 0.0001)
    }

    @Test("a window at the origin on a 1× display is identity plus offset")
    func windowPixelIdentity() {
        let p = GroundingController.ocrPixelCenterToGlobalPoints(
            blockX: 10, blockY: 20, blockW: 0, blockH: 0,
            imagePixelWidth: 300, imagePixelHeight: 300,
            windowBounds: CGRect(x: 0, y: 0, width: 300, height: 300)
        )
        #expect(abs(p.x - 10) < 0.0001)
        #expect(abs(p.y - 20) < 0.0001)
    }

    @Test("zero-size window bounds cannot divide by zero")
    func degenerateBoundsSafe() {
        let p = GroundingController.ocrPixelCenterToGlobalPoints(
            blockX: 5, blockY: 5, blockW: 0, blockH: 0,
            imagePixelWidth: 0, imagePixelHeight: 0,
            windowBounds: CGRect(x: 40, y: 50, width: 0, height: 0)
        )
        #expect(p.x.isFinite && p.y.isFinite)
        #expect(p.x == 45)
        #expect(p.y == 55)
    }

    // MARK: - A-3 failure classification

    @Test("window capture failures map to explicit error codes, never a display fallback")
    func captureFailureErrorCodes() {
        #expect(GroundingController.errorCode(
            for: ScreenController.ScreenError.permissionDenied("denied", window: nil)
        ) == "permission_missing")
        #expect(GroundingController.errorCode(
            for: ScreenController.ScreenError.noMatchingWindow(titleContains: nil)
        ) == "not_found")
        #expect(GroundingController.errorCode(
            for: ScreenCaptureKitBridge.BridgeError.permissionDenied
        ) == "permission_missing")
        #expect(GroundingController.errorCode(
            for: ScreenCaptureKitBridge.BridgeError.windowNotFound(42)
        ) == "not_found")
    }
}
