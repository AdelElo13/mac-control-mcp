import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

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

    enum ScreenError: Error, CustomStringConvertible {
        case noDisplay
        case captureFailed
        case encodingFailed
        case writeFailed
        /// SCK returned -3801; user has not granted Screen Recording
        /// permission to the mac-control-mcp binary.
        case permissionDenied(String)
        /// The window exists in AX but is not rendered on the current
        /// Space. Capturing the region would return the desktop wallpaper
        /// rather than the window's content.
        case windowNotOnCurrentSpace

        var description: String {
            switch self {
            case .noDisplay: return "No main display."
            case .captureFailed: return "Screen capture failed."
            case .encodingFailed: return "PNG encoding failed."
            case .writeFailed: return "PNG write failed."
            case .permissionDenied(let detail):
                return "Screen Recording permission not granted to mac-control-mcp. Open System Settings → Privacy & Security → Screen Recording and enable the MCP binary, then restart it. (Underlying error: \(detail))"
            case .windowNotOnCurrentSpace:
                return "Window exists but is on a different macOS Space. Bring it to the foreground (or switch Spaces) before capturing."
            }
        }
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
    /// window's owner PID + optional title filter.
    ///
    /// CGWindowListCopyWindowInfo bridges numeric CF values into NSNumber
    /// when handed to Swift, so we must extract Int32/UInt32 via
    /// NSNumber.int32Value / uint32Value. A previous version used direct
    /// `as? pid_t` / `as? CGWindowID` casts, which silently returned nil
    /// and made every capture_window call fail — caught by testing
    /// against the ControlZoo harness.
    ///
    /// Also uses `[.optionAll]` so we still find the window when it lives
    /// on a different macOS Space (the capture itself may fail if the
    /// window isn't actually rendered, but the lookup no longer does).
    /// Capture a specific on-screen window.
    ///
    /// Three-strategy fallback chain (documented failure modes):
    ///   1. ScreenCaptureKit — primary path on macOS 14+. Required for
    ///      per-window capture on macOS 15+ where the legacy CG APIs
    ///      silently return nil. Requires Screen Recording permission
    ///      granted explicitly to the mac-control-mcp binary. If the
    ///      user has NOT granted this permission, SCK throws
    ///      "user declined TCCs" (-3801) and we surface that as a
    ///      clear ScreenError.permissionDenied with guidance.
    ///   2. Legacy CGWindowListCreateImage by windowID — preserved for
    ///      macOS 14.0-14.3 where it still works. Off-Space windows
    ///      return nil here; we fall through.
    ///   3. Region crop at the window's global bounds — only useful
    ///      when the window is actually rendered on the current Space.
    ///      Gated by `kCGWindowIsOnscreen` to avoid capturing the
    ///      desktop wallpaper behind a phantom off-Space window.
    ///
    /// Lookup hygiene:
    ///   - `.optionAll` instead of `.optionOnScreenOnly` so we find the
    ///     window even when off-Space.
    ///   - NSNumber.int32Value / uint32Value for pid/windowID extraction
    ///     (casting CFNumberRef directly to pid_t returns nil).
    ///   - Prefer onscreen + layer-0 windows when a PID has multiple.
    func captureWindow(ownerPID: pid_t, titleContains: String? = nil, outputPath: String? = nil) async throws -> CaptureResult {
        let options: CGWindowListOption = [.optionAll, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            throw ScreenError.captureFailed
        }

        let candidates = info.filter { dict in
            let pidNum = dict[kCGWindowOwnerPID as String] as? NSNumber
            return pidNum?.int32Value == ownerPID
        }

        // Match selection:
        //   - If title filter provided, require substring match.
        //   - Otherwise prefer onscreen + layer 0 + non-empty name.
        let match: [String: Any]?
        if let title = titleContains, !title.isEmpty {
            match = candidates.first { dict in
                let candidate = (dict[kCGWindowName as String] as? String) ?? ""
                return candidate.localizedCaseInsensitiveContains(title)
            }
        } else {
            func isOnScreen(_ d: [String: Any]) -> Bool {
                (d[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue == true
            }
            func isLayer0(_ d: [String: Any]) -> Bool {
                (d[kCGWindowLayer as String] as? NSNumber)?.intValue == 0
            }
            match = candidates.first(where: { isOnScreen($0) && isLayer0($0) })
                ?? candidates.first(where: { isLayer0($0) })
                ?? candidates.first
        }

        guard let match,
              let wnum = match[kCGWindowNumber as String] as? NSNumber else {
            throw ScreenError.captureFailed
        }
        let windowID = CGWindowID(wnum.uint32Value)

        // Strategy 1: ScreenCaptureKit.
        do {
            let image = try await ScreenCaptureKitBridge.captureWindow(windowID: windowID)
            let path = outputPath ?? Self.defaultTempPath()
            try writePNG(image: image, to: path)
            return CaptureResult(path: path, width: image.width, height: image.height)
        } catch {
            if let bridgeError = error as? ScreenCaptureKitBridge.BridgeError,
               case .permissionDenied = bridgeError {
                throw ScreenError.permissionDenied("CGRequestScreenCaptureAccess returned denied.")
            }
            let detail = String(describing: error)
            if detail.contains("-3801") || detail.contains("TCC") || detail.contains("declined") {
                // Surface the permission issue clearly instead of falling
                // back to a misleading desktop-wallpaper screenshot.
                throw ScreenError.permissionDenied(detail)
            }
            FileHandle.standardError.write("[captureWindow] SCK non-permission failure, trying legacy: \(detail)\n".data(using: .utf8)!)
        }

        // Strategy 2 (legacy fallback): CGWindowListCreateImage by windowID.
        // When this works it gives us the window even if occluded. Returns
        // nil on macOS 15+ in many cases — that's why SCK is Strategy 1.
        if let image = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            windowID,
            [.bestResolution, .boundsIgnoreFraming]
        ) {
            let path = outputPath ?? Self.defaultTempPath()
            try writePNG(image: image, to: path)
            return CaptureResult(path: path, width: image.width, height: image.height)
        }

        // Strategy 3 (last resort): crop the window's bounds from the
        // current-Space screen. Only useful when the window IS on the
        // current Space; otherwise we'd return the desktop wallpaper.
        // Abort if we detect we'd be capturing desktop only.
        guard let boundsDict = match[kCGWindowBounds as String] as? [String: Any] else {
            throw ScreenError.captureFailed
        }
        let x = (boundsDict["X"] as? NSNumber)?.doubleValue ?? 0
        let y = (boundsDict["Y"] as? NSNumber)?.doubleValue ?? 0
        let w = (boundsDict["Width"] as? NSNumber)?.doubleValue ?? 0
        let h = (boundsDict["Height"] as? NSNumber)?.doubleValue ?? 0
        let bounds = CGRect(x: x, y: y, width: w, height: h)

        // If the window is marked as off-screen by the window server,
        // region capture will return desktop only — refuse instead of
        // returning a misleading screenshot.
        let onScreen = (match[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        guard onScreen else {
            throw ScreenError.windowNotOnCurrentSpace
        }

        guard let image = CGWindowListCreateImage(
            bounds,
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

    /// Run OCR on the given image file. Uses the Vision framework's
    /// accurate recognition level and the system default language list.
    ///
    /// We deliberately use CGImageSource rather than NSImage here. NSImage
    /// is part of AppKit and is documented as not thread-safe; calling it
    /// from a non-main actor was flagged by review. CGImageSource is an
    /// ImageIO primitive that is safe to use off the main thread.
    func ocr(imagePath: String, languages: [String] = []) throws -> OCRResult {
        let url = URL(fileURLWithPath: imagePath) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let cgImage = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
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
