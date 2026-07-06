import Testing
import CoreGraphics
@testable import MacControlMCP

/// Regression tests for the Retina coordinate bug in GroundingController.
///
/// `ScreenController.ocr` returns block coordinates in image PIXELS. On a
/// 2× Retina display a full-screen capture is twice the point size, so an
/// OCR center used as a click target (`ground`) or compared against AX
/// frames (`axTreeAugmented`, which are in points) is 2× off unless it is
/// first divided by the backing scale. `ocrPixelCenterToPoints` is the
/// pure conversion; these tests pin its math without needing a display.
@Suite("Grounding OCR pixel→point conversion")
struct GroundingCoordinateTests {

    @Test("2× Retina capture halves the OCR center into points")
    func retinaHalves() {
        // 1512×982 pt display captured at 3024×1964 px (scale 2.0).
        // Block origin (600,400) size (40,20) → pixel center (620,410)
        // → point (310,205).
        let p = GroundingController.ocrPixelCenterToPoints(
            blockX: 600, blockY: 400, blockW: 40, blockH: 20,
            imagePixelWidth: 3024, imagePixelHeight: 1964,
            displayPointWidth: 1512, displayPointHeight: 982
        )
        #expect(abs(p.x - 310) < 0.0001)
        #expect(abs(p.y - 205) < 0.0001)
    }

    @Test("1× display is identity (points == pixels)")
    func nonRetinaIdentity() {
        // 1440×900 pt display captured at 1440×900 px (scale 1.0).
        // Block origin (100,50) size (40,20) → center (120,60).
        let p = GroundingController.ocrPixelCenterToPoints(
            blockX: 100, blockY: 50, blockW: 40, blockH: 20,
            imagePixelWidth: 1440, imagePixelHeight: 900,
            displayPointWidth: 1440, displayPointHeight: 900
        )
        #expect(abs(p.x - 120) < 0.0001)
        #expect(abs(p.y - 60) < 0.0001)
    }

    @Test("fractional scaled mode converts exactly")
    func fractionalScale() {
        // A "looks like 1710×1112" scaled mode on a 3456×2234 px panel.
        // scaleX = 1710/3456, scaleY = 1112/2234.
        let p = GroundingController.ocrPixelCenterToPoints(
            blockX: 3456, blockY: 2234, blockW: 0, blockH: 0,
            imagePixelWidth: 3456, imagePixelHeight: 2234,
            displayPointWidth: 1710, displayPointHeight: 1112
        )
        #expect(abs(p.x - 1710) < 0.0001)
        #expect(abs(p.y - 1112) < 0.0001)
    }

    @Test("zero image dimensions fall back to identity, no divide-by-zero")
    func zeroDimsSafe() {
        let p = GroundingController.ocrPixelCenterToPoints(
            blockX: 10, blockY: 10, blockW: 0, blockH: 0,
            imagePixelWidth: 0, imagePixelHeight: 0,
            displayPointWidth: 100, displayPointHeight: 100
        )
        #expect(p.x == 10)
        #expect(p.y == 10)
    }

    /// This is the AX-tree join bug made concrete: an AX button frame lives
    /// in points; its label's raw OCR pixel-center falls OUTSIDE that frame
    /// on Retina, so the pre-fix `rect.contains(pixelCenter)` join misses
    /// it. After conversion the point-center lands inside and the join
    /// succeeds.
    @Test("AX-frame geometric join matches only after pixel→point conversion")
    func axJoinMatchesAfterConversion() {
        // AX frame for a small button, in points.
        let axRect = CGRect(x: 100, y: 100, width: 100, height: 40)

        // OCR reports the button's label centered at pixel (300, 240),
        // which is point (150, 120) on a 2× capture — inside axRect.
        let rawPixelCenter = CGPoint(x: 300, y: 240)
        #expect(!axRect.contains(rawPixelCenter))   // pre-fix: join misses

        let pointCenter = GroundingController.ocrPixelCenterToPoints(
            blockX: 300, blockY: 240, blockW: 0, blockH: 0,
            imagePixelWidth: 3024, imagePixelHeight: 1964,
            displayPointWidth: 1512, displayPointHeight: 982
        )
        #expect(axRect.contains(pointCenter))       // post-fix: join hits
    }
}
