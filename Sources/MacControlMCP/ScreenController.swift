import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision
import AppKit

/// Screen capture + OCR. Screenshots are written to disk (PNG) and the path
/// is returned to the caller — a base64 payload would blow past MCP frame
/// limits on a Retina display (~8 MB+ per full-screen image).
actor ScreenController {
    struct CaptureResult: Codable, Sendable {
        let path: String
        let width: Int
        let height: Int
    }

    struct OCRBlock: Codable, Sendable {
        let text: String
        let confidence: Double
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    struct OCRResult: Codable, Sendable {
        let blocks: [OCRBlock]
        let joinedText: String
    }

    enum ScreenError: Error {
        case noDisplay
        case captureFailed
        case encodingFailed
        case writeFailed
    }

    /// Capture the main display (or a specific `displayID`) and write a PNG
    /// to `outputPath`. If `outputPath` is nil, a temp file is created.
    func captureDisplay(displayID: CGDirectDisplayID? = nil, outputPath: String? = nil) throws -> CaptureResult {
        let id = displayID ?? CGMainDisplayID()
        guard let image = CGDisplayCreateImage(id) else {
            throw ScreenError.captureFailed
        }

        let path = outputPath ?? Self.defaultTempPath()
        try writePNG(image: image, to: path)

        return CaptureResult(path: path, width: image.width, height: image.height)
    }

    /// Capture a rectangular region of the main display. Coordinates are in
    /// the global Quartz space (origin top-left). Use list_displays output
    /// to map to other displays — this helper operates on the main display
    /// for simplicity.
    func captureRegion(x: Int, y: Int, width: Int, height: Int, outputPath: String? = nil) throws -> CaptureResult {
        let rect = CGRect(x: x, y: y, width: width, height: height)
        guard let image = CGWindowListCreateImage(
            rect,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            throw ScreenError.captureFailed
        }

        let path = outputPath ?? Self.defaultTempPath()
        try writePNG(image: image, to: path)
        return CaptureResult(path: path, width: image.width, height: image.height)
    }

    /// Capture a specific display by its CGDirectDisplayID.
    func captureDisplayByID(_ displayID: CGDirectDisplayID, outputPath: String? = nil) throws -> CaptureResult {
        guard let image = CGDisplayCreateImage(displayID) else {
            throw ScreenError.captureFailed
        }
        let path = outputPath ?? Self.defaultTempPath()
        try writePNG(image: image, to: path)
        return CaptureResult(path: path, width: image.width, height: image.height)
    }

    /// Capture a specific on-screen window. `windowID` comes from
    /// CGWindowListCopyWindowInfo; for app windows we look it up by the
    /// window's owner PID + title via CGWindowListCopyWindowInfo.
    func captureWindow(ownerPID: pid_t, titleContains: String? = nil, outputPath: String? = nil) throws -> CaptureResult {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw ScreenError.captureFailed
        }

        let match = info.first { dict in
            guard (dict[kCGWindowOwnerPID as String] as? pid_t) == ownerPID else { return false }
            guard let title = titleContains, !title.isEmpty else { return true }
            let candidate = (dict[kCGWindowName as String] as? String) ?? ""
            return candidate.localizedCaseInsensitiveContains(title)
        }

        guard let match, let windowID = match[kCGWindowNumber as String] as? CGWindowID else {
            throw ScreenError.captureFailed
        }

        guard let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) else {
            throw ScreenError.captureFailed
        }

        let path = outputPath ?? Self.defaultTempPath()
        try writePNG(image: image, to: path)
        return CaptureResult(path: path, width: image.width, height: image.height)
    }

    /// Run OCR on the given image file. Uses the Vision framework's
    /// accurate recognition level and the system default language list.
    func ocr(imagePath: String, languages: [String] = []) throws -> OCRResult {
        guard let image = NSImage(contentsOfFile: imagePath),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            throw ScreenError.captureFailed
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        if !languages.isEmpty {
            request.recognitionLanguages = languages
        }

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try handler.perform([request])

        let observations = (request.results ?? []) as [VNRecognizedTextObservation]
        let imageWidth = Double(cgImage.width)
        let imageHeight = Double(cgImage.height)

        let blocks: [OCRBlock] = observations.compactMap { obs in
            guard let candidate = obs.topCandidates(1).first else { return nil }
            let box = obs.boundingBox
            // Vision returns normalized bottom-left-origin rects; flip to
            // top-left and convert to pixel coordinates.
            let x = box.origin.x * imageWidth
            let y = (1.0 - box.origin.y - box.size.height) * imageHeight
            let w = box.size.width * imageWidth
            let h = box.size.height * imageHeight
            return OCRBlock(
                text: candidate.string,
                confidence: Double(candidate.confidence),
                x: x,
                y: y,
                width: w,
                height: h
            )
        }

        let joined = blocks.map { $0.text }.joined(separator: "\n")
        return OCRResult(blocks: blocks, joinedText: joined)
    }

    /// Capture screen + OCR in one pass. The temp image is deleted unless
    /// `keepImage` is true.
    func captureAndOCR(keepImage: Bool = false, languages: [String] = []) throws -> (CaptureResult, OCRResult) {
        let capture = try captureDisplay()
        defer {
            if !keepImage {
                try? FileManager.default.removeItem(atPath: capture.path)
            }
        }
        let ocrResult = try ocr(imagePath: capture.path, languages: languages)
        return (capture, ocrResult)
    }

    // MARK: - Helpers

    private func writePNG(image: CGImage, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            throw ScreenError.encodingFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw ScreenError.writeFailed
        }
    }

    private static func defaultTempPath() -> String {
        let dir = FileManager.default.temporaryDirectory
        let name = "mcp-capture-\(UUID().uuidString).png"
        return dir.appendingPathComponent(name).path
    }
}
