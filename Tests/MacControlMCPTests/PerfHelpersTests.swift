import Testing
import Foundation
import CoreGraphics
@testable import MacControlMCP

/// v0.8.3 performance work: pure helpers behind the opt-in image output
/// options, the shareable-content cache freshness rule and the single
/// window-server snapshot used by list_windows.
@Suite("PerfHelpers")
struct PerfHelpersTests {

    // MARK: - ImageOutputOptions.parse

    @Test("absent params keep the backward-compatible defaults")
    func defaults() throws {
        let options = try ImageOutputOptions.parse([:]).get()
        #expect(options == .default)
        #expect(options.format == .png)
        #expect(options.maxWidth == nil)
    }

    @Test("parses format / quality / max_width, accepting string numbers and jpg alias")
    func parsesValues() throws {
        let options = try ImageOutputOptions.parse([
            "format": .string("JPG"),
            "quality": .string("0.5"),
            "max_width": .string("1280")
        ]).get()
        #expect(options.format == .jpeg)
        #expect(options.quality == 0.5)
        #expect(options.maxWidth == 1280)
        #expect(options.format.fileExtension == "jpg")
        #expect(options.format.mimeType == "image/jpeg")
    }

    @Test("rejects malformed values instead of silently ignoring them",
          arguments: [
            ["format": JSONValue.string("webp")],
            ["format": JSONValue.number(1)],
            ["quality": JSONValue.number(1.5)],
            ["quality": JSONValue.number(-0.1)],
            ["quality": JSONValue.string("high")],
            ["max_width": JSONValue.number(8)],
            ["max_width": JSONValue.number(640.5)],
            ["max_width": JSONValue.string("wide")]
          ])
    func rejectsInvalid(arguments: [String: JSONValue]) {
        if case .success = ImageOutputOptions.parse(arguments) {
            Issue.record("expected failure for \(arguments)")
        }
    }

    @Test("explicit null is treated as absent")
    func nullIsAbsent() throws {
        let options = try ImageOutputOptions.parse([
            "format": .null, "quality": .null, "max_width": .null
        ]).get()
        #expect(options == .default)
    }

    // MARK: - Downscale math

    @Test("scaledSize never upscales and preserves aspect ratio")
    func scaledSize() {
        #expect(ImageEncoder.scaledSize(width: 3600, height: 2338, maxWidth: nil) == (3600, 2338))
        #expect(ImageEncoder.scaledSize(width: 3600, height: 2338, maxWidth: 4000) == (3600, 2338))
        #expect(ImageEncoder.scaledSize(width: 3600, height: 2338, maxWidth: 3600) == (3600, 2338))
        #expect(ImageEncoder.scaledSize(width: 3600, height: 2338, maxWidth: 1280) == (1280, 831))
        #expect(ImageEncoder.scaledSize(width: 1000, height: 1, maxWidth: 16) == (16, 1))
    }

    @Test("scale and pixels_per_point map image pixels back to screen points")
    func scaleMath() {
        // Full Retina display 1800pt wide captured at 3600px, downscaled to 1280.
        #expect(ImageEncoder.scale(outputWidth: 1280, sourceWidth: 3600) == 1280.0 / 3600.0)
        #expect(ImageEncoder.scale(outputWidth: 10, sourceWidth: 0) == 1)
        let ppp = ImageEncoder.pixelsPerPoint(outputWidth: 1280, pointWidth: 1800)
        #expect(ppp == 1280.0 / 1800.0)
        // Native capture: 2 px per point.
        #expect(ImageEncoder.pixelsPerPoint(outputWidth: 3600, pointWidth: 1800) == 2)
        #expect(ImageEncoder.pixelsPerPoint(outputWidth: 3600, pointWidth: nil) == nil)
        #expect(ImageEncoder.pixelsPerPoint(outputWidth: 3600, pointWidth: 0) == nil)
    }

    @Test("encode honours max_width and format on a synthetic image")
    func encodeSynthetic() throws {
        let context = CGContext(
            data: nil, width: 400, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        let image = context.makeImage()!

        let (png, pngMeta) = try ImageEncoder.encode(image, options: .default)
        #expect(pngMeta.width == 400 && pngMeta.height == 200)
        #expect(png.starts(with: [0x89, 0x50, 0x4E, 0x47]))

        var jpegOptions = ImageOutputOptions()
        jpegOptions.format = .jpeg
        jpegOptions.maxWidth = 100
        let (jpeg, jpegMeta) = try ImageEncoder.encode(image, options: jpegOptions)
        #expect(jpegMeta.width == 100 && jpegMeta.height == 50)
        #expect(jpegMeta.sourceWidth == 400 && jpegMeta.sourceHeight == 200)
        #expect(jpeg.starts(with: [0xFF, 0xD8]))

        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf-helpers-\(UUID().uuidString).jpg").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        let written = try ImageEncoder.write(image, to: path, options: jpegOptions)
        #expect(written.width == 100)
        #expect(FileManager.default.fileExists(atPath: path))
    }

    @Test("capture_screen_v2 max_dimension maps to an equivalent max_width on the longest side")
    func maxDimensionToWidth() {
        // Landscape: longest side is width.
        #expect(ScreenController.maxWidth(fittingMaxDimension: 1000, width: 3600, height: 2338) == 1000)
        // Portrait: longest side is height → width scales down proportionally.
        #expect(ScreenController.maxWidth(fittingMaxDimension: 1000, width: 1080, height: 1920) == 562)
        // Already within the limit, or no/invalid limit → no downscale.
        #expect(ScreenController.maxWidth(fittingMaxDimension: 4000, width: 3600, height: 2338) == nil)
        #expect(ScreenController.maxWidth(fittingMaxDimension: nil, width: 3600, height: 2338) == nil)
        #expect(ScreenController.maxWidth(fittingMaxDimension: 0, width: 3600, height: 2338) == nil)
        // Result feeds scaledSize: longest output side never exceeds max_dimension.
        let portrait = ImageEncoder.scaledSize(width: 1080, height: 1920, maxWidth: 562)
        #expect(max(portrait.width, portrait.height) <= 1000)
    }

    // MARK: - Shareable-content cache freshness

    @Test("snapshot is fresh only within ttl and never after a clock rollback")
    func snapshotPolicy() {
        let policy = TimedSnapshotPolicy(ttl: 2)
        let t0 = Date(timeIntervalSince1970: 1_000)
        #expect(policy.isFresh(fetchedAt: nil, now: t0) == false)
        #expect(policy.isFresh(fetchedAt: t0, now: t0) == true)
        #expect(policy.isFresh(fetchedAt: t0, now: t0.addingTimeInterval(1.99)) == true)
        #expect(policy.isFresh(fetchedAt: t0, now: t0.addingTimeInterval(2)) == false)
        #expect(policy.isFresh(fetchedAt: t0, now: t0.addingTimeInterval(-1)) == false)
    }

    // MARK: - list_windows window-server filter

    private func cgEntry(pid: Int32, layer: Int = 0, x: Double = 0, y: Double = 100,
                         w: Double = 800, h: Double = 600, title: String? = nil,
                         onscreen: Bool = true) -> [String: Any] {
        var d: [String: Any] = [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: layer),
            kCGWindowBounds as String: ["X": NSNumber(value: x), "Y": NSNumber(value: y),
                                        "Width": NSNumber(value: w), "Height": NSNumber(value: h)],
            kCGWindowIsOnscreen as String: NSNumber(value: onscreen)
        ]
        if let title { d[kCGWindowName as String] = title }
        return d
    }

    @Test("cgWindows filters one shared snapshot per pid with the original rules")
    func cgWindowsFilter() {
        let snapshot: [[String: Any]] = [
            cgEntry(pid: 10, title: "Main"),
            cgEntry(pid: 11, title: "Other app"),
            cgEntry(pid: 10, layer: 25, title: "Overlay"),               // non-zero layer
            cgEntry(pid: 10, y: 0, w: 1800, h: 39, title: "menubar"),    // menubar stripe
            cgEntry(pid: 10, w: 1, h: 1),                                // degenerate
            cgEntry(pid: 10, title: "Hidden", onscreen: false)
        ]
        let windows = WindowController.cgWindows(from: snapshot, pid: 10, appName: "App")
        #expect(windows.map(\.title) == ["Main", "Hidden"])
        #expect(windows[0].main == true && windows[1].main == false)
        #expect(windows.map(\.index) == [0, 1])
        #expect(windows[1].minimized == true)
        #expect(WindowController.cgWindows(from: snapshot, pid: 11, appName: "B").count == 1)
        #expect(WindowController.cgWindows(from: snapshot, pid: 99, appName: "C").isEmpty)
    }
}
