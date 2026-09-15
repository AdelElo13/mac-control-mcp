import Testing
import CoreGraphics
@testable import MacControlMCP

/// v0.10 B5: exercise the actual pass coordinator with deterministic OCR results.
@Suite("Grounding OCR passes")
struct GroundingOCRPassTests {
    let capture = ScreenController.CaptureResult(path: "", width: 1000, height: 800,
        sourceWidth: 1000, sourceHeight: 800, format: "png", pointWidth: 500,
        pointBounds: CGRect(x: 0, y: 0, width: 500, height: 400))
    let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800)]

    func result(_ label: String, width: Double = 100, confidence: Double = 1) -> ScreenController.OCRResult {
        .init(blocks: [.init(text: label, confidence: confidence, x: 20, y: 20, width: width, height: 40)], joinedText: label)
    }

    @Test func strongFastMatchSkipsAccurate() throws {
        var passes: [ScreenController.OCRRequestOptions] = []
        _ = try ScreenController.groundingOCR(capture: capture, target: "Add User…", displays: displays) { options in
            passes.append(options)
            return result("Add User...")
        }
        #expect(passes == [.init(fast: true, languageCorrection: false)])
    }

    @Test func weakFastMatchFallsBackAndIsRetained() throws {
        var passes: [Bool] = []
        let combined = try ScreenController.groundingOCR(capture: capture, target: "account", displays: displays) { options in
            passes.append(options.fast)
            return result(options.fast ? "Internet Accounts" : "Something else")
        }
        #expect(passes == [true, false])
        #expect(combined.blocks.contains { $0.text == "Internet Accounts" })
    }

    @Test func tinyFastBoxCannotSuppressAccurate() throws {
        var passes: [Bool] = []
        let combined = try ScreenController.groundingOCR(capture: capture, target: "Recents", displays: displays) { options in
            passes.append(options.fast)
            return result("Recents", width: options.fast ? 2 : 100)
        }
        #expect(passes == [true, false])
        let candidates = try GroundingController.ocrCandidates(capture: capture, result: combined,
            target: "Recents", anchors: [], displays: displays)
        #expect(candidates.count == 1)
        #expect(candidates.first?.bounds?.width == 50)
    }
}
