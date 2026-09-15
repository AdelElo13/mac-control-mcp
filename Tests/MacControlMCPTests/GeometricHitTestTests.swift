import Testing
import CoreGraphics
@testable import MacControlMCP

/// v0.10 C2: a fake tree reproduces window-sized SwiftUI hits without IPC.
@Suite("Geometric hit test")
struct GeometricHitTestTests {
    @Test func smallestInteractiveDescendantWins() {
        let rect = CGRect(x: 0, y: 0, width: 800, height: 600)
        let tree: [Int: GeometricHitTest.Node<Int>] = [
            0: .init(role: "AXGroup", frame: rect, children: [1, 2, 3]),
            1: .init(role: "AXButton", frame: rect.insetBy(dx: 50, dy: 50), children: []),
            2: .init(role: "AXButton", frame: CGRect(x: 90, y: 90, width: 40, height: 30), children: []),
            3: .init(role: "AXStaticText", frame: CGRect(x: 100, y: 100, width: 2, height: 2), children: [])]
        #expect(GeometricHitTest.search(root: 0, point: CGPoint(x: 101, y: 101), read: { tree[$0]! }) == 2)
        #expect(GeometricHitTest.needsSearch(role: "AXScrollArea", frame: nil, window: rect))
        #expect(GeometricHitTest.needsSearch(role: "AXUnknown", frame: rect, window: rect))
        #expect(!GeometricHitTest.needsSearch(role: "AXButton", frame: rect.insetBy(dx: 300, dy: 250), window: rect))
    }

    @Test func refinementStaysInHitSubtreeAndReportsQuality() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let tree: [Int: GeometricHitTest.Node<Int>] = [
            0: .init(role: "AXWindow", frame: frame, children: [1, 2]),
            1: .init(role: "AXGroup", frame: frame, children: [3]),
            2: .init(role: "AXButton", frame: CGRect(x: 99, y: 99, width: 4, height: 4), children: []),
            3: .init(role: "AXButton", frame: CGRect(x: 90, y: 90, width: 30, height: 30), children: [])]
        let hit = GeometricHitTest.refine(hit: 1, window: 0, point: CGPoint(x: 100, y: 100), read: { tree[$0]! })
        #expect(hit.element == 3)
        #expect(hit.quality == "geometric")
        let direct = GeometricHitTest.refine(hit: 3, window: 0, point: CGPoint(x: 100, y: 100), read: { tree[$0]! })
        #expect(direct.element == 3)
        #expect(direct.quality == "direct")
        let empty = GeometricHitTest.refine(hit: 1, window: 0, point: CGPoint(x: 500, y: 500), read: { tree[$0]! })
        #expect(empty.element == 1)
        #expect(empty.quality == "container")
    }

    @Test func boundsDepthCyclesAndBudget() {
        var reads = 0
        let result = GeometricHitTest.search(root: 0, point: .zero, nodeCap: 4) { id in
            reads += 1
            return .init(role: id == 5 ? "AXButton" : "AXGroup",
                         frame: CGRect(x: -1, y: -1, width: 4, height: 4), children: [id, id + 1])
        }
        #expect(result == nil)
        #expect(reads == 4)
        var deepest = 0
        let deep = GeometricHitTest.search(root: 0, point: .zero) { id in
            deepest = max(deepest, id)
            return .init(role: id == 25 ? "AXButton" : "AXGroup",
                         frame: CGRect(x: -1, y: -1, width: 4, height: 4), children: [id + 1])
        }
        #expect(deep == nil)
        #expect(deepest == 24)
    }
}
