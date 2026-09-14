import Foundation
import CoreGraphics
import CoreText

/// v0.9 workstream F (gap C-13) — annotated screenshots.
///
/// `capture_*` returns pixels and `find_elements` returns geometry; joining
/// the two is currently the agent's job and costs an extra round trip plus
/// coordinate arithmetic on every grounding attempt. This type does the join
/// server-side: it takes a captured CGImage plus the interactive AX elements
/// of the same app and paints a numbered box over each one, so the model can
/// say "click [3]" instead of guessing a coordinate.
///
/// Everything here is pure geometry + Core Graphics drawing — no AX calls, no
/// screen capture, no actor state — which is what makes it unit-testable
/// against a synthetic CGImage (see ScreenAnnotatorTests).
///
/// Coordinate systems (three of them, kept explicit on purpose):
///   * GLOBAL POINTS — what AX reports and what `click` consumes. Top-left
///     origin, whole-desktop space.
///   * CAPTURE-LOCAL PIXELS, TOP-LEFT origin — what the image is indexed by,
///     and what `imageRect` produces. On a Retina window capture this is 2×
///     the point size.
///   * CORE GRAPHICS pixels, BOTTOM-LEFT origin — what `CGContext` draws in.
///     `flipY` is the only place that conversion happens.
enum ScreenAnnotator {

    // MARK: - Element selection

    /// Roles worth numbering on an annotated screenshot.
    ///
    /// Deliberately the same whitelist `list_elements` uses (see
    /// `AccessibilityController.actionableRoles`): controls an agent can
    /// actually act on, no containers, no `AXRow` (floods table-heavy apps
    /// like Finder list view / Mail), no `AXStaticText` (every label in the
    /// window would get a box and the image becomes unreadable).
    ///
    /// Kept as its own set rather than shared with the controller so that
    /// tuning what gets *drawn* can never silently change what
    /// `list_elements` *returns*.
    static let interactiveRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXComboBox",
        "AXDecrementor",
        "AXDisclosureTriangle",
        "AXIncrementor",
        "AXLevelIndicator",
        "AXLink",
        "AXMenuButton",
        "AXPopUpButton",
        "AXRadioButton",
        "AXSecureTextField",
        "AXSlider",
        "AXStepper",
        "AXSwitch",
        "AXTextArea",
        "AXTextField"
    ]

    /// One candidate element, reduced to what the annotator needs. `frame`
    /// is in GLOBAL POINTS (AXPosition + AXSize).
    struct ElementGeometry: Sendable, Equatable {
        let role: String?
        let title: String?
        let frame: CGRect

        init(role: String?, title: String?, frame: CGRect) {
            self.role = role
            self.title = title
            self.frame = frame
        }
    }

    /// One box to paint. `index` is 1-based — it is what the model sees on
    /// the image and what the `elements` array keys off.
    struct AnnotationBox: Sendable, Equatable {
        let index: Int
        let globalRect: CGRect
    }

    /// Indices (into `items`, in document order) of the elements worth
    /// drawing, capped at `limit`.
    ///
    /// Drops, in this order:
    ///   * roles outside `interactiveRoles` (containers, static text, rows);
    ///   * non-finite frames — a stale/foreign AX element can report NaN;
    ///   * zero-area frames — A-10 found untitled `0×0` AXButtons in System
    ///     Settings; a box around nothing is worse than no box;
    ///   * elements that do not intersect the captured region at all, so a
    ///     window capture never numbers a control that isn't in the picture.
    static func filterInteractive(
        _ items: [ElementGeometry],
        captureRect: CGRect,
        limit: Int
    ) -> [Int] {
        guard limit > 0 else { return [] }
        var picked: [Int] = []
        for (index, item) in items.enumerated() {
            guard picked.count < limit else { break }
            guard let role = item.role, interactiveRoles.contains(role) else { continue }
            let frame = item.frame
            guard frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.size.width.isFinite, frame.size.height.isFinite else { continue }
            guard frame.width > 0, frame.height > 0 else { continue }
            guard frame.intersects(captureRect) else { continue }
            picked.append(index)
        }
        return picked
    }

    // MARK: - Geometry

    /// Maps global screen points onto the captured image's pixel grid.
    ///
    /// `origin`/`pointSize` describe what the capture covers in global
    /// points (a window's frame, or the main display's bounds);
    /// `pixelWidth`/`pixelHeight` are the captured image's real pixel
    /// dimensions. The ratio between them is the backing factor — derived,
    /// never assumed to be 2.0, so a 1× display, a fractional scaled mode
    /// and a downscaled capture all work out.
    struct Geometry: Sendable, Equatable {
        let origin: CGPoint
        let pointSize: CGSize
        let pixelWidth: Int
        let pixelHeight: Int

        init(origin: CGPoint, pointSize: CGSize, pixelWidth: Int, pixelHeight: Int) {
            self.origin = origin
            self.pointSize = pointSize
            self.pixelWidth = pixelWidth
            self.pixelHeight = pixelHeight
        }

        /// Output pixels per screen point. Falls back to 1 rather than
        /// dividing by zero when the point extent is unknown/degenerate.
        var pixelsPerPointX: Double {
            guard pointSize.width > 0, pointSize.width.isFinite, pixelWidth > 0 else { return 1 }
            return Double(pixelWidth) / Double(pointSize.width)
        }

        var pixelsPerPointY: Double {
            guard pointSize.height > 0, pointSize.height.isFinite, pixelHeight > 0 else { return 1 }
            return Double(pixelHeight) / Double(pointSize.height)
        }

        /// The captured region in global points — what `filterInteractive`
        /// clips against.
        var captureRect: CGRect {
            CGRect(origin: origin, size: pointSize)
        }
    }

    /// Global-point rect → capture-local pixel rect (top-left origin).
    static func imageRect(globalRect: CGRect, geometry: Geometry) -> CGRect {
        let sx = geometry.pixelsPerPointX
        let sy = geometry.pixelsPerPointY
        return CGRect(
            x: (globalRect.origin.x - Double(geometry.origin.x)) * sx,
            y: (globalRect.origin.y - Double(geometry.origin.y)) * sy,
            width: Double(globalRect.width) * sx,
            height: Double(globalRect.height) * sy
        )
    }

    /// Top-left-origin pixel rect → Core Graphics bottom-left-origin rect.
    static func flipY(_ rect: CGRect, imageHeight: Int) -> CGRect {
        CGRect(x: rect.origin.x,
               y: Double(imageHeight) - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }

    /// Outline thickness in PIXELS. 2 points thick, so the box looks the
    /// same physical weight on a 1× and a Retina capture (2 px vs 4 px),
    /// and never thinner than 2 px on a downscaled one.
    static func strokeWidth(pixelsPerPoint: Double) -> Double {
        guard pixelsPerPoint.isFinite, pixelsPerPoint > 0 else { return 2 }
        return max(2.0, 2.0 * pixelsPerPoint)
    }

    /// Badge size in PIXELS for a given index, scaled by the backing factor
    /// so the number stays legible on Retina captures.
    static func badgeSize(index: Int, pixelsPerPoint: Double) -> CGSize {
        let unit = (pixelsPerPoint.isFinite && pixelsPerPoint > 0) ? pixelsPerPoint : 1
        let digits = max(1, String(max(index, 1)).count)
        return CGSize(width: (8.0 + 7.0 * Double(digits)) * unit,
                      height: 14.0 * unit)
    }

    /// Where the numbered badge goes, in capture-local pixels.
    ///
    /// Directly above the box's top-left corner when there is room, tucked
    /// inside the box's top-left corner when the box is against the top
    /// edge (otherwise the number would be cropped away), and always
    /// clamped horizontally so it stays inside the image.
    static func badgeRect(
        boxPixelRect: CGRect,
        badge: CGSize,
        imageWidth: Int,
        imageHeight: Int
    ) -> CGRect {
        let y: Double = (boxPixelRect.minY - badge.height >= 0)
            ? Double(boxPixelRect.minY - badge.height)
            : Double(boxPixelRect.minY)
        let maxX = max(0.0, Double(imageWidth) - Double(badge.width))
        let x = min(max(0.0, Double(boxPixelRect.minX)), maxX)
        let clampedY = min(max(0.0, y), max(0.0, Double(imageHeight) - Double(badge.height)))
        return CGRect(x: x, y: clampedY, width: badge.width, height: badge.height)
    }

    // MARK: - Drawing

    /// Box outline + badge fill. High-contrast red reads on both light and
    /// dark UI; the number itself is drawn white on that red.
    private static let markColor = CGColor(red: 0.92, green: 0.15, blue: 0.13, alpha: 1.0)
    private static let labelColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)

    /// Draw numbered boxes onto a copy of `image`. Returns nil only when a
    /// bitmap context cannot be created (out of memory / unsupported
    /// colour space); callers fall back to the un-annotated capture.
    ///
    /// Drawing happens at the CAPTURED resolution, before any `max_width`
    /// downscale, so the outlines downscale with the content instead of
    /// being drawn at the wrong scale afterwards.
    static func draw(boxes: [AnnotationBox], on image: CGImage, geometry: Geometry) -> CGImage? {
        let width = image.width
        let height = image.height
        let colorSpace = (image.colorSpace?.model == .rgb ? image.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        // The source image is drawn in the normal (unflipped) orientation;
        // every overlay rect is converted with `flipY` instead. Flipping the
        // whole context would render the screenshot upside down, and text
        // drawn by Core Text would come out mirrored.
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let ppp = max(geometry.pixelsPerPointX, geometry.pixelsPerPointY)
        let lineWidth = strokeWidth(pixelsPerPoint: ppp)
        context.setStrokeColor(markColor)
        context.setLineWidth(lineWidth)

        for box in boxes {
            let pixelRect = imageRect(globalRect: box.globalRect, geometry: geometry)
            guard pixelRect.width.isFinite, pixelRect.height.isFinite else { continue }

            // Inset by half the line width so the stroke lands ON the
            // element's edge rather than straddling outside it.
            let stroked = flipY(pixelRect, imageHeight: height).insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
            context.stroke(stroked)

            let badge = badgeSize(index: box.index, pixelsPerPoint: ppp)
            let badgePixelRect = badgeRect(boxPixelRect: pixelRect, badge: badge,
                                           imageWidth: width, imageHeight: height)
            let badgeDrawRect = flipY(badgePixelRect, imageHeight: height)
            context.setFillColor(markColor)
            context.fill(badgeDrawRect)
            drawNumber(box.index, in: badgeDrawRect, context: context, unit: ppp)
        }

        return context.makeImage()
    }

    /// Centre the index inside its badge using Core Text. Falls back to
    /// leaving the badge a plain filled marker if the font is unavailable —
    /// a solid box is still a usable pointer, and `elements[]` carries the
    /// authoritative index either way.
    private static func drawNumber(_ index: Int, in rect: CGRect, context: CGContext, unit: Double) {
        let scale = (unit.isFinite && unit > 0) ? unit : 1
        let fontSize = 10.0 * scale
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
        let attributes: [CFString: Any] = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: labelColor
        ]
        let attributed = CFAttributedStringCreate(
            nil, String(index) as CFString, attributes as CFDictionary
        )
        guard let attributed else { return }
        let line = CTLineCreateWithAttributedString(attributed)
        let bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
        let x = rect.midX - bounds.width / 2
        let y = rect.midY - bounds.height / 2 - bounds.origin.y
        context.textPosition = CGPoint(x: x, y: y)
        CTLineDraw(line, context)
    }
}
