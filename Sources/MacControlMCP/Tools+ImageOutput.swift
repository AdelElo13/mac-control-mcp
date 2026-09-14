import Foundation

// MARK: - Shared image-output params/payload for the capture tools (v0.8.3)

extension ToolRegistry {
    /// `format` / `quality` / `max_width` schema properties, merged into
    /// capture_screen, capture_window, capture_display and
    /// capture_screen_v2.
    static let imageOutputSchemaProperties: [String: JSONValue] = [
        "format": .object([
            "type": .string("string"),
            "enum": .array([.string("png"), .string("jpeg")]),
            "description": .string("Output encoding. png (default, lossless, ~67 ms / ~2.4 MB for a full Retina screen) or jpeg (~15 ms / ~1.3 MB at quality 0.8; no transparency — window corners render black).")
        ]),
        "quality": .object([
            "type": .array([.string("number"), .string("string")]),
            "description": .string("JPEG quality 0–1 (default 0.8). Ignored for png.")
        ]),
        "max_width": .object([
            "type": .array([.string("integer"), .string("string")]),
            "description": .string("Downscale (aspect-preserving, never upscale) to at most this many pixels wide. Cuts latency, bytes and vision tokens. The response reports `scale` and `pixels_per_point` so image coordinates can still be mapped to screen points.")
        ])
    ]

    static func withImageOutputProperties(_ properties: [String: JSONValue]) -> [String: JSONValue] {
        properties.merging(imageOutputSchemaProperties) { existing, _ in existing }
    }

    /// Parse the image-output options or return an `invalid_argument`
    /// tool result.
    func parseImageOutputOptions(
        _ arguments: [String: JSONValue],
        tool: String
    ) -> Result<ImageOutputOptions, ToolCallResultBox> {
        switch ImageOutputOptions.parse(arguments) {
        case .success(let options):
            return .success(options)
        case .failure(let error):
            return .failure(ToolCallResultBox(result: invalidArgument("\(tool): \(error.description)")))
        }
    }

    /// Geometry/encoding metadata added to every capture response.
    /// Existing fields (`path`, `width`, `height`) keep their meaning:
    /// `width`/`height` are the pixel dimensions of the written image.
    ///
    ///   scale             output pixels per captured pixel (1 unless max_width downscaled)
    ///   source_width/_height  captured pixel dimensions before downscale
    ///   pixels_per_point  output pixels per screen point — divide an image
    ///                     x/y by this and add the capture origin to get a
    ///                     global screen point (omitted when unknown)
    static func captureMetadata(_ capture: ScreenController.CaptureResult) -> [String: JSONValue] {
        let sourceWidth = capture.sourceWidth ?? capture.width
        let sourceHeight = capture.sourceHeight ?? capture.height
        var payload: [String: JSONValue] = [
            "format": .string(capture.format),
            "source_width": .number(Double(sourceWidth)),
            "source_height": .number(Double(sourceHeight)),
            "scale": .number(ImageEncoder.scale(outputWidth: capture.width, sourceWidth: sourceWidth))
        ]
        if let ppp = ImageEncoder.pixelsPerPoint(outputWidth: capture.width, pointWidth: capture.pointWidth) {
            payload["pixels_per_point"] = .number(ppp)
        }
        return payload
    }
}

extension ToolRegistry {
    /// Direct JSONValue construction for OCR blocks — same keys and
    /// values as the synthesized Codable encoding
    /// (`encodeAsJSONValue`), without its JSONEncoder → Data →
    /// JSONDecoder round trip over a few hundred blocks.
    static func encodeOCRBlocks(_ blocks: [ScreenController.OCRBlock]) -> JSONValue {
        .array(blocks.map { block in
            .object([
                "text": .string(block.text),
                "confidence": .number(block.confidence),
                "x": .number(block.x),
                "y": .number(block.y),
                "width": .number(block.width),
                "height": .number(block.height)
            ])
        })
    }
}

/// `ToolCallResult` is not an `Error`; this box lets option parsing use
/// `Result` without widening that type.
struct ToolCallResultBox: Error {
    let result: ToolCallResult
}
