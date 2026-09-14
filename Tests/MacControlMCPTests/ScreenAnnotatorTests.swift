import Testing
import Foundation
import CoreGraphics
@testable import MacControlMCP

/// v0.9 workstream F — `capture_annotated` / `ScreenAnnotator`.
///
/// Everything here runs against a SYNTHETIC CGImage and synthetic element
/// geometry: no screen capture, no AX tree, no user desktop involvement.
/// The live paths (real window capture + real AX walk) are verified by a
/// manual stdio probe, not by this suite.
@Suite("Screen annotator geometry")
struct ScreenAnnotatorGeometryTests {

    // MARK: - Helpers

    /// Solid-white RGBA image, `width` × `height` PIXELS.
    static func whiteImage(width: Int, height: Int) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()!
    }

    /// RGBA at an image pixel, TOP-LEFT origin.
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (UInt8, UInt8, UInt8, UInt8)? {
        guard let data = image.dataProvider?.data,
              let base = CFDataGetBytePtr(data) else { return nil }
        let bpr = image.bytesPerRow
        let bpp = image.bitsPerPixel / 8
        guard x >= 0, y >= 0, x < image.width, y < image.height, bpp >= 4 else { return nil }
        let offset = y * bpr + x * bpp
        guard offset + 3 < CFDataGetLength(data) else { return nil }
        return (base[offset], base[offset + 1], base[offset + 2], base[offset + 3])
    }

    static func isWhite(_ px: (UInt8, UInt8, UInt8, UInt8)?) -> Bool {
        guard let px else { return false }
        return px.0 > 240 && px.1 > 240 && px.2 > 240
    }

    // MARK: - Point → pixel mapping

    @Test("global-point rect maps to image pixels at 1x")
    func imageRectAt1x() {
        let geometry = ScreenAnnotator.Geometry(
            origin: CGPoint(x: 0, y: 0),
            pointSize: CGSize(width: 400, height: 300),
            pixelWidth: 400, pixelHeight: 300
        )
        #expect(geometry.pixelsPerPointX == 1.0)
        let r = ScreenAnnotator.imageRect(globalRect: CGRect(x: 10, y: 20, width: 100, height: 40),
                                          geometry: geometry)
        #expect(r == CGRect(x: 10, y: 20, width: 100, height: 40))
    }

    @Test("global-point rect maps to image pixels at 2x with a window origin offset")
    func imageRectRetinaWithOrigin() {
        // A window at global (100, 50), 400×300 pt, captured at 800×600 px.
        let geometry = ScreenAnnotator.Geometry(
            origin: CGPoint(x: 100, y: 50),
            pointSize: CGSize(width: 400, height: 300),
            pixelWidth: 800, pixelHeight: 600
        )
        #expect(geometry.pixelsPerPointX == 2.0)
        #expect(geometry.pixelsPerPointY == 2.0)
        // A control at global (150, 70) 200×20 pt is 50,20 pt inside the
        // window → 100,40 px in, 400×40 px big.
        let r = ScreenAnnotator.imageRect(globalRect: CGRect(x: 150, y: 70, width: 200, height: 20),
                                          geometry: geometry)
        #expect(r == CGRect(x: 100, y: 40, width: 400, height: 40))
    }

    @Test("degenerate geometry falls back to 1:1 instead of dividing by zero")
    func degenerateGeometry() {
        let geometry = ScreenAnnotator.Geometry(
            origin: .zero, pointSize: CGSize(width: 0, height: 0),
            pixelWidth: 100, pixelHeight: 100
        )
        #expect(geometry.pixelsPerPointX == 1.0)
        #expect(geometry.pixelsPerPointY == 1.0)
    }

    @Test("flipY converts a top-left pixel rect to CoreGraphics bottom-left")
    func flipYConversion() {
        let flipped = ScreenAnnotator.flipY(CGRect(x: 10, y: 20, width: 30, height: 40), imageHeight: 100)
        // top edge y=20 → bottom-left y = 100 - (20+40) = 40
        #expect(flipped == CGRect(x: 10, y: 40, width: 30, height: 40))
    }

    // MARK: - Retina-aware stroke

    @Test("stroke width is 2 POINTS — 2 px at 1x, 4 px on Retina")
    func strokeWidthScalesWithBackingFactor() {
        #expect(ScreenAnnotator.strokeWidth(pixelsPerPoint: 1.0) == 2.0)
        #expect(ScreenAnnotator.strokeWidth(pixelsPerPoint: 2.0) == 4.0)
        // Never thinner than 2 px, even for a sub-1x (downscaled) capture.
        #expect(ScreenAnnotator.strokeWidth(pixelsPerPoint: 0.25) == 2.0)
    }

    @Test("badge grows with digit count and with the backing factor")
    func badgeSizeScaling() {
        let one1x = ScreenAnnotator.badgeSize(index: 1, pixelsPerPoint: 1)
        let three1x = ScreenAnnotator.badgeSize(index: 100, pixelsPerPoint: 1)
        let one2x = ScreenAnnotator.badgeSize(index: 1, pixelsPerPoint: 2)
        #expect(three1x.width > one1x.width)
        #expect(three1x.height == one1x.height)
        #expect(one2x.width == one1x.width * 2)
        #expect(one2x.height == one1x.height * 2)
    }

    // MARK: - Badge placement

    @Test("badge sits directly above the box when there is room")
    func badgeAboveBox() {
        let box = CGRect(x: 50, y: 60, width: 200, height: 30)
        let badge = CGSize(width: 24, height: 14)
        let r = ScreenAnnotator.badgeRect(boxPixelRect: box, badge: badge, imageWidth: 400, imageHeight: 400)
        #expect(r.maxY == box.minY)
        #expect(r.minX == box.minX)
        #expect(r.size == badge)
    }

    @Test("badge falls inside the box when the box touches the top edge")
    func badgeInsideWhenNoRoomAbove() {
        let box = CGRect(x: 10, y: 0, width: 100, height: 30)
        let badge = CGSize(width: 24, height: 14)
        let r = ScreenAnnotator.badgeRect(boxPixelRect: box, badge: badge, imageWidth: 400, imageHeight: 400)
        #expect(r.minY == box.minY)
        #expect(r.minX == box.minX)
    }

    @Test("badge is clamped inside the image at the right and left edges")
    func badgeClampedHorizontally() {
        let badge = CGSize(width: 40, height: 14)
        let right = ScreenAnnotator.badgeRect(
            boxPixelRect: CGRect(x: 380, y: 100, width: 15, height: 20),
            badge: badge, imageWidth: 400, imageHeight: 400
        )
        #expect(right.maxX <= 400)
        #expect(right.minX == 360)

        let left = ScreenAnnotator.badgeRect(
            boxPixelRect: CGRect(x: -20, y: 100, width: 50, height: 20),
            badge: badge, imageWidth: 400, imageHeight: 400
        )
        #expect(left.minX == 0)
    }

    // MARK: - Element filtering

    @Test("only interactive, non-degenerate, in-frame elements are numbered")
    func filterInteractive() {
        let capture = CGRect(x: 0, y: 0, width: 400, height: 300)
        let items: [ScreenAnnotator.ElementGeometry] = [
            .init(role: "AXButton", title: "OK", frame: CGRect(x: 10, y: 10, width: 60, height: 20)),
            .init(role: "AXGroup", title: "container", frame: CGRect(x: 0, y: 0, width: 400, height: 300)),
            .init(role: "AXStaticText", title: "label", frame: CGRect(x: 5, y: 5, width: 50, height: 12)),
            .init(role: "AXButton", title: "zero size", frame: CGRect(x: 30, y: 30, width: 0, height: 0)),
            .init(role: "AXTextField", title: "offscreen", frame: CGRect(x: 900, y: 900, width: 80, height: 20)),
            .init(role: nil, title: "no role", frame: CGRect(x: 10, y: 50, width: 40, height: 20)),
            .init(role: "AXLink", title: "Docs", frame: CGRect(x: 100, y: 100, width: 40, height: 16))
        ]
        let picked = ScreenAnnotator.filterInteractive(items, captureRect: capture, limit: 200)
        #expect(picked == [0, 6])
    }

    @Test("filter keeps document order and honours the element cap")
    func filterRespectsLimit() {
        let capture = CGRect(x: 0, y: 0, width: 1000, height: 1000)
        let items = (0..<10).map { i in
            ScreenAnnotator.ElementGeometry(
                role: "AXButton", title: "b\(i)",
                frame: CGRect(x: Double(i) * 10, y: 0, width: 8, height: 8)
            )
        }
        let picked = ScreenAnnotator.filterInteractive(items, captureRect: capture, limit: 3)
        #expect(picked == [0, 1, 2])
    }

    @Test("a partially visible element is kept, a non-finite one is dropped")
    func filterEdgeCases() {
        let capture = CGRect(x: 0, y: 0, width: 400, height: 300)
        let items: [ScreenAnnotator.ElementGeometry] = [
            .init(role: "AXButton", title: "half in", frame: CGRect(x: 380, y: 10, width: 60, height: 20)),
            .init(role: "AXButton", title: "nan",
                  frame: CGRect(x: CGFloat.nan, y: 10, width: 60, height: 20)),
            .init(role: "AXButton", title: "inf size",
                  frame: CGRect(x: 10, y: 10, width: CGFloat.infinity, height: 20))
        ]
        #expect(ScreenAnnotator.filterInteractive(items, captureRect: capture, limit: 200) == [0])
    }

    // MARK: - Drawing

    @Test("annotating preserves image dimensions and paints the box outline")
    func drawPaintsBoxes() throws {
        let image = Self.whiteImage(width: 200, height: 120)
        let geometry = ScreenAnnotator.Geometry(
            origin: .zero, pointSize: CGSize(width: 200, height: 120),
            pixelWidth: 200, pixelHeight: 120
        )
        let boxes = [
            ScreenAnnotator.AnnotationBox(index: 1, globalRect: CGRect(x: 40, y: 40, width: 80, height: 30))
        ]
        let out = try #require(ScreenAnnotator.draw(boxes: boxes, on: image, geometry: geometry))
        #expect(out.width == image.width)
        #expect(out.height == image.height)

        // The box's top edge (y≈40) must no longer be white…
        #expect(!Self.isWhite(Self.pixel(out, x: 80, y: 40)))
        // …and the middle of the box must still be untouched (outline, not fill).
        #expect(Self.isWhite(Self.pixel(out, x: 80, y: 55)))
        // A corner far from the box is untouched.
        #expect(Self.isWhite(Self.pixel(out, x: 190, y: 110)))
    }

    @Test("the numbered badge is painted above the box")
    func drawPaintsBadge() throws {
        let image = Self.whiteImage(width: 200, height: 120)
        let geometry = ScreenAnnotator.Geometry(
            origin: .zero, pointSize: CGSize(width: 200, height: 120),
            pixelWidth: 200, pixelHeight: 120
        )
        let box = CGRect(x: 40, y: 60, width: 80, height: 30)
        let out = try #require(ScreenAnnotator.draw(
            boxes: [.init(index: 7, globalRect: box)], on: image, geometry: geometry
        ))
        let badge = ScreenAnnotator.badgeSize(index: 7, pixelsPerPoint: 1)
        let badgeRect = ScreenAnnotator.badgeRect(boxPixelRect: box, badge: badge,
                                                  imageWidth: 200, imageHeight: 120)
        #expect(badgeRect.maxY == box.minY)

        // The badge is a filled marker: its corners are painted…
        #expect(!Self.isWhite(Self.pixel(out, x: Int(badgeRect.minX) + 1, y: Int(badgeRect.minY) + 1)))
        #expect(!Self.isWhite(Self.pixel(out, x: Int(badgeRect.maxX) - 2, y: Int(badgeRect.maxY) - 2)))

        // …and the numeral is drawn on top in white, so somewhere inside
        // the badge there MUST be light pixels. (Sampling the badge's exact
        // centre is not a valid "is it painted" probe for that reason.)
        var lightPixelsInsideBadge = 0
        for y in Int(badgeRect.minY)..<Int(badgeRect.maxY) {
            for x in Int(badgeRect.minX)..<Int(badgeRect.maxX) where Self.isWhite(Self.pixel(out, x: x, y: y)) {
                lightPixelsInsideBadge += 1
            }
        }
        #expect(lightPixelsInsideBadge > 0, "the index digits should be rendered inside the badge")

        // Directly above the badge is untouched background.
        #expect(Self.isWhite(Self.pixel(out, x: Int(badgeRect.midX), y: Int(badgeRect.minY) - 2)))
    }

    @Test("drawing zero boxes returns an image, unchanged in size")
    func drawNoBoxes() throws {
        let image = Self.whiteImage(width: 64, height: 32)
        let geometry = ScreenAnnotator.Geometry(
            origin: .zero, pointSize: CGSize(width: 64, height: 32),
            pixelWidth: 64, pixelHeight: 32
        )
        let out = try #require(ScreenAnnotator.draw(boxes: [], on: image, geometry: geometry))
        #expect(out.width == 64 && out.height == 32)
        #expect(Self.isWhite(Self.pixel(out, x: 10, y: 10)))
    }

    @Test("Retina capture draws the box at 2x pixel coordinates")
    func drawRetina() throws {
        // 100×60 pt window captured at 200×120 px.
        let image = Self.whiteImage(width: 200, height: 120)
        let geometry = ScreenAnnotator.Geometry(
            origin: CGPoint(x: 1000, y: 500), pointSize: CGSize(width: 100, height: 60),
            pixelWidth: 200, pixelHeight: 120
        )
        // Control at global (1020, 520) 40×10 pt → pixels (40, 40) 80×20.
        let out = try #require(ScreenAnnotator.draw(
            boxes: [.init(index: 1, globalRect: CGRect(x: 1020, y: 520, width: 40, height: 10))],
            on: image, geometry: geometry
        ))
        #expect(!Self.isWhite(Self.pixel(out, x: 80, y: 40)))   // top edge in px
        #expect(Self.isWhite(Self.pixel(out, x: 80, y: 20)))    // above the box
    }
}
