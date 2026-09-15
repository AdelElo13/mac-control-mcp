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

    @Test(arguments: [0.0, 0.4, 0.72])
    func lowConfidenceFastExactMatchSkipsAccurate(confidence: Double) throws {
        var passes: [Bool] = []
        let recognized = try ScreenController.groundingOCR(capture: capture, target: "ＡＤＤ User…", displays: displays) { options in
            passes.append(options.fast)
            return result("Add User...", confidence: confidence)
        }
        #expect(passes == [true])
        let candidates = try GroundingController.ocrCandidates(capture: capture, result: recognized,
            target: "Add User…", anchors: [], displays: displays)
        #expect(candidates.first?.confidence == confidence)
    }

    @Test func fastSubstringIsAHitWithoutInflatingConfidence() throws {
        var passes: [Bool] = []
        let recognized = try ScreenController.groundingOCR(capture: capture, target: "account", displays: displays) { options in
            passes.append(options.fast)
            return result("Internet Accounts", confidence: 0.72)
        }
        #expect(passes == [true])
        let candidates = try GroundingController.ocrCandidates(capture: capture, result: recognized,
            target: "account", anchors: [], displays: displays)
        #expect(candidates.first?.confidence == 0.6)
    }

    @Test func missingFastTargetFallsBackToAccurate() throws {
        var passes: [ScreenController.OCRRequestOptions] = []
        let recognized = try ScreenController.groundingOCR(capture: capture, target: "Downloads", displays: displays) { options in
            passes.append(options)
            return result(options.fast ? "Documents" : "Downloads")
        }
        #expect(passes == [.init(fast: true, languageCorrection: false), .init(fast: false)])
        let candidates = try GroundingController.ocrCandidates(capture: capture, result: recognized,
            target: "Downloads", anchors: [], displays: displays)
        #expect(candidates.first?.title == "Downloads")
    }

    @Test func weakAXCannotDisableOCRDistancePenalty() throws {
        let weak = GroundingController.Candidate(role: "AXImage", title: "Account icon", x: 50, y: 30,
            bounds: nil, elementId: "weak", source: "ax", confidence: 0.6)
        let blocks: [ScreenController.OCRBlock] = [
            .init(text: "account", confidence: 1, x: 10, y: 10, width: 80, height: 20),
            .init(text: "Internet Accounts", confidence: 1, x: 614, y: 10, width: 80, height: 20)]
        let candidates = try GroundingController.ocrCandidates(capture: capture,
            result: .init(blocks: blocks, joinedText: ""), target: "account", anchors: [weak], displays: displays)
        #expect(candidates.count == 2)
        #expect(candidates.last?.confidence ?? 1 < 0.6)
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
