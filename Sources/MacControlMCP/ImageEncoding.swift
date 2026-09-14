import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Opt-in output shaping for the screenshot tools (capture_screen,
/// capture_window, capture_display, capture_screen_v2).
///
/// PERF (v0.8.3): a full Retina screenshot (3600×2338) costs ~67 ms to
/// PNG-encode and ~2.4 MB on disk. Measured on the same frame:
///   png full              67 ms  2.42 MB
///   jpeg q0.8 full        15 ms  1.27 MB
///   max_width 1280 + png  22 ms  0.54 MB
///   max_width 1280 + jpeg  3.5 ms 0.28 MB
/// Defaults (png, native resolution) keep the pre-0.8.3 output
/// byte-for-byte in shape; agents opt in per call.
struct ImageOutputOptions: Sendable, Equatable {
    enum Format: String, Sendable {
        case png
        case jpeg

        var utType: UTType { self == .png ? .png : .jpeg }
        var fileExtension: String { self == .png ? "png" : "jpg" }
        var mimeType: String { self == .png ? "image/png" : "image/jpeg" }
    }

    static let defaultJPEGQuality = 0.8
    /// Below this a screenshot stops being useful to read and the
    /// request is almost certainly a units mistake.
    static let minimumMaxWidth = 16

    var format: Format = .png
    /// Lossy quality 0…1. Only used for `.jpeg`.
    var quality: Double = defaultJPEGQuality
    /// Downscale (aspect-preserving, never upscale) when the captured
    /// image is wider than this many pixels.
    var maxWidth: Int?

    static let `default` = ImageOutputOptions()

    /// Parse `format`, `quality`, `max_width` tool arguments. Absent keys
    /// keep the defaults; malformed values are rejected rather than
    /// silently ignored.
    static func parse(_ arguments: [String: JSONValue]) -> Result<ImageOutputOptions, ImageOptionsError> {
        var options = ImageOutputOptions()

        if let raw = arguments["format"], raw != .null {
            guard let s = raw.stringValue?.lowercased() else {
                return .failure(.invalid("format must be a string: \"png\" or \"jpeg\"."))
            }
            switch s {
            case "png": options.format = .png
            case "jpeg", "jpg": options.format = .jpeg
            default: return .failure(.invalid("format must be \"png\" or \"jpeg\" (got \"\(s)\")."))
            }
        }

        if let raw = arguments["quality"], raw != .null {
            let q: Double?
            switch raw {
            case .number(let n): q = n
            case .string(let s): q = Double(s)
            default: q = nil
            }
            guard let q, q.isFinite, q >= 0, q <= 1 else {
                return .failure(.invalid("quality must be a number between 0 and 1."))
            }
            options.quality = q
        }

        if let raw = arguments["max_width"], raw != .null {
            guard let w = raw.intValue, w >= minimumMaxWidth else {
                return .failure(.invalid("max_width must be an integer >= \(minimumMaxWidth)."))
            }
            options.maxWidth = w
        }

        return .success(options)
    }
}

enum ImageOptionsError: Error, CustomStringConvertible, Equatable {
    case invalid(String)
    var description: String {
        switch self { case .invalid(let s): return s }
    }
}

/// The encoded result of one capture.
struct EncodedImage: Sendable {
    let width: Int
    let height: Int
    let sourceWidth: Int
    let sourceHeight: Int
    let format: ImageOutputOptions.Format
}

enum ImageEncoder {
    /// Aspect-preserving target size. Never upscales; height is rounded
    /// and clamped to >= 1 so an extreme aspect ratio can't produce a
    /// zero-height image.
    static func scaledSize(width: Int, height: Int, maxWidth: Int?) -> (width: Int, height: Int) {
        guard let maxWidth, maxWidth > 0, width > maxWidth, width > 0 else {
            return (width, height)
        }
        let scaledHeight = (Double(height) * Double(maxWidth) / Double(width)).rounded()
        return (maxWidth, max(1, Int(scaledHeight)))
    }

    /// Output pixels per source pixel (1.0 when not downscaled).
    static func scale(outputWidth: Int, sourceWidth: Int) -> Double {
        guard sourceWidth > 0 else { return 1 }
        return Double(outputWidth) / Double(sourceWidth)
    }

    /// Output pixels per screen point for a capture covering `pointWidth`
    /// points horizontally — the factor to divide an image-pixel
    /// coordinate by to get a screen-point offset from the capture
    /// origin. nil when the point width is unknown or degenerate.
    static func pixelsPerPoint(outputWidth: Int, pointWidth: Double?) -> Double? {
        guard let pointWidth, pointWidth > 0, pointWidth.isFinite else { return nil }
        return Double(outputWidth) / pointWidth
    }

    static func downscale(_ image: CGImage, maxWidth: Int?) -> CGImage {
        let target = scaledSize(width: image.width, height: image.height, maxWidth: maxWidth)
        guard target.width != image.width || target.height != image.height else { return image }
        let colorSpace = (image.colorSpace?.model == .rgb ? image.colorSpace : nil)
            ?? CGColorSpace(name: CGColorSpace.sRGB)
            ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: target.width,
            height: target.height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return image }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: target.width, height: target.height))
        return context.makeImage() ?? image
    }

    private static func properties(_ options: ImageOutputOptions) -> CFDictionary? {
        guard options.format == .jpeg else { return nil }
        return [kCGImageDestinationLossyCompressionQuality: options.quality] as CFDictionary
    }

    /// Downscale (if requested) and write to `path`.
    static func write(
        _ image: CGImage,
        to path: String,
        options: ImageOutputOptions
    ) throws -> EncodedImage {
        let output = downscale(image, maxWidth: options.maxWidth)
        let url = URL(fileURLWithPath: path) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, options.format.utType.identifier as CFString, 1, nil) else {
            throw ScreenController.ScreenError.encodingFailed
        }
        CGImageDestinationAddImage(dest, output, properties(options))
        guard CGImageDestinationFinalize(dest) else {
            throw ScreenController.ScreenError.writeFailed
        }
        return EncodedImage(
            width: output.width, height: output.height,
            sourceWidth: image.width, sourceHeight: image.height,
            format: options.format
        )
    }

    /// Downscale (if requested) and encode in memory.
    static func encode(_ image: CGImage, options: ImageOutputOptions) throws -> (Data, EncodedImage) {
        let output = downscale(image, maxWidth: options.maxWidth)
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, options.format.utType.identifier as CFString, 1, nil) else {
            throw ScreenController.ScreenError.encodingFailed
        }
        CGImageDestinationAddImage(dest, output, properties(options))
        guard CGImageDestinationFinalize(dest) else {
            throw ScreenController.ScreenError.encodingFailed
        }
        return (data as Data, EncodedImage(
            width: output.width, height: output.height,
            sourceWidth: image.width, sourceHeight: image.height,
            format: options.format
        ))
    }
}
