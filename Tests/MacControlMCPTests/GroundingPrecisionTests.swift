import Testing
import Foundation
import CoreGraphics
@testable import MacControlMCP

/// v0.10 A5/B5: synthetic AX labels isolate ranking from desktop state.
@Suite("Grounding precision")
struct GroundingPrecisionTests {
    typealias Node = GroundingPolicy.Node
    let displays = [CGRect(x: 0, y: 0, width: 1000, height: 800),
                    CGRect(x: 2000, y: 0, width: 1000, height: 800)]

    func node(_ role: String = "AXStaticText", title: String? = nil,
              value: String? = nil, description: String? = nil,
              x: Double = 30, width: Double = 80, height: Double = 20) -> Node {
        Node(role: role, title: title, value: value, description: description,
             bounds: CGRect(x: x, y: 152, width: width, height: height))
    }

    @Test func containersAndHiddenLinksCannotBeTargets() {
        for role in ["AXWindow", "AXSheet", "AXApplication", "AXScrollArea"] {
            #expect(GroundingPolicy.match(node(role, title: "Untitled"), target: "Untitled", displays: displays) == nil)
        }
        #expect(GroundingPolicy.match(node("AXLink", title: "Skip to content", width: 1, height: 1), target: "Skip to content", displays: displays) == nil)
        #expect(GroundingPolicy.match(node(title: "Gap", x: 1500), target: "Gap", displays: displays) == nil)
        #expect(GroundingPolicy.match(node(value: "Recents", x: 2100), target: "Recents", displays: displays) != nil)
    }

    @Test func valueAndDescriptionBeatPartialImageTitle() {
        let tree = [node("AXWindow", title: "Shared"),
                    node("AXImage", title: "Shared Folder"), node(value: "Shared"),
                    node(description: "Recents")]
        let matches = tree.compactMap { GroundingPolicy.match($0, target: "Shared", displays: displays) }
        #expect(matches.count == 2)
        #expect(matches.last?.field == "value")
        #expect(matches.first!.confidence <= 0.6)
        #expect(matches.last!.confidence == 1)
        #expect(GroundingPolicy.match(tree[3], target: "Recents", displays: displays)?.field == "description")
    }

    @Test func unicodeAndEllipsisAreEquivalent() {
        #expect(GroundingPolicy.normalize("ＡＤＤ User…") == GroundingPolicy.normalize("add user..."))
        #expect(GroundingPolicy.normalize("Straße") == GroundingPolicy.normalize("STRASSE"))
        #expect(GroundingPolicy.match(node(value: "Add User..."), target: "Add User…", displays: displays)?.confidence == 1)
    }

    @Test func exactTiesPreferSmallestArea() {
        let large = GroundingController.Candidate(role: "AXButton", title: "OK", x: 50, y: 50,
            bounds: .init(x: 0, y: 0, width: 100, height: 100), elementId: "large", source: "ax", confidence: 1)
        let small = GroundingController.Candidate(role: "AXStaticText", title: "OK", x: 50, y: 50,
            bounds: .init(x: 40, y: 40, width: 20, height: 20), elementId: "small", source: "ax", confidence: 1)
        #expect(GroundingPolicy.ranked([large, small]).first?.elementId == "small")
    }

    @Test func repeatedOCRPassesDoNotInventAlternatives() {
        let first = GroundingController.Candidate(role: nil, title: "Add User…", x: 50, y: 50,
            bounds: .init(x: 10, y: 40, width: 80, height: 20), elementId: nil, source: "ocr", confidence: 0.9)
        let duplicate = GroundingController.Candidate(role: nil, title: "Add User...", x: 51, y: 50,
            bounds: .init(x: 11, y: 40, width: 80, height: 20), elementId: nil, source: "ocr", confidence: 0.8)
        #expect(GroundingPolicy.ranked([first, duplicate]).count == 1)
    }

    @Test(arguments: [([Double](), false), ([1.0, 1.0], true), ([1.0, 0.6], true),
                      ([0.6, 0.4], true), ([0.6, 0.6], false), ([0.6], true)])
    func autoUsesRankedAXWinner(scores: [Double], expected: Bool) {
        let candidates = scores.map { score in
            GroundingController.Candidate(role: "AXStaticText", title: "Downloads", x: 50, y: 50,
                bounds: nil, elementId: nil, source: "ax", confidence: score)
        }
        #expect(GroundingPolicy.prefersAX(candidates) == expected)
    }

    @Test func distantOCRIsWeakerAndFastFallbackPreservesRecall() {
        #expect(GroundingPolicy.ocrConfidence(text: "Internet Accounts", target: "account", recognition: 1, distance: 302) < 0.6)
        #expect(GroundingPolicy.ocrConfidence(text: "Account", target: "account", recognition: 0.4, distance: nil) <= 0.4)
        #expect(ScreenController.OCRRequestOptions(fast: true).languageCorrection == false)
        #expect(ScreenController.OCRRequestOptions(fast: false).languageCorrection == true)
    }
}
