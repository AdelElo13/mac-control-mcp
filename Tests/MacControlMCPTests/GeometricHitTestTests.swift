import Testing
import Foundation
import CoreGraphics
@testable import MacControlMCP

/// v0.10 C2: a fake tree reproduces window-sized SwiftUI hits without IPC.
@Suite("Geometric hit test")
struct GeometricHitTestTests {
    @Test func interactiveOutOfFrameHitSearchesWindowForContainingHeader() {
        let tree: [Int: GeometricHitTest.Node<Int>] = [
            0: .init(role: "AXWindow", frame: CGRect(x: 200, y: 30, width: 1600, height: 900), children: [1, 2]),
            1: .init(role: "AXButton", frame: CGRect(x: 1333, y: 39, width: 41, height: 52), children: []),
            2: .init(role: "AXButton", frame: CGRect(x: 213, y: 96, width: 1193, height: 28), children: [])]
        let hit = GeometricHitTest.refine(hit: 1, window: 0, point: CGPoint(x: 809.5, y: 105), read: { tree[$0]! })
        #expect(hit.element == 2)
        #expect(hit.quality == "geometric")
    }

    @Test func outOfFrameHitWithoutReplacementIsLabelledHonestly() {
        let hit = GeometricHitTest.refine(hit: 1, window: nil, point: CGPoint(x: 809.5, y: 105)) { _ in
            .init(role: "AXButton", frame: CGRect(x: 1333, y: 39, width: 41, height: 52), children: [])
        }
        #expect(hit.element == 1)
        #expect(hit.quality == "direct_out_of_frame")
    }

    @Test func directHitFrameToleranceIsOnePointAndRequiresUsableGeometry() {
        let frame = CGRect(x: 10, y: 10, width: 20, height: 20)
        for point in [CGPoint(x: 9, y: 20), CGPoint(x: 31, y: 20),
                      CGPoint(x: 20, y: 9), CGPoint(x: 20, y: 31)] {
            let hit = GeometricHitTest.refine(hit: 1, window: nil, point: point) { _ in
                .init(role: "AXButton", frame: frame, children: [])
            }
            #expect(hit.quality == "direct")
        }
        let beyond = GeometricHitTest.refine(hit: 1, window: nil, point: CGPoint(x: 31.01, y: 20)) { _ in
            .init(role: "AXButton", frame: frame, children: [])
        }
        #expect(beyond.quality == "direct_out_of_frame")
        for missing in [CGRect?.none, .zero] {
            let hit = GeometricHitTest.refine(hit: 1, window: nil, point: CGPoint(x: 200, y: 200)) { _ in
                .init(role: "AXButton", frame: missing, children: [])
            }
            #expect(hit.quality == "direct")
        }
    }

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

    @Test func outlineLeafCellWinsAndPlainCellsStayExcluded() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        let tree: [Int: GeometricHitTest.Node<Int>] = [
            0: .init(role: "AXOutline", frame: frame, children: [1]),
            1: .init(role: "AXRow", frame: frame, children: [2]),
            2: .init(role: "AXCell", frame: frame, children: [])]
        let hit = GeometricHitTest.refine(hit: 0, window: nil, point: CGPoint(x: 10, y: 10), read: { tree[$0]! })
        #expect(hit.element == 2)
        #expect(hit.quality == "geometric")
        #expect(GeometricHitTest.search(root: 2, point: CGPoint(x: 10, y: 10), read: { tree[$0]! }) == nil)
    }

    @Test func coarseCellHitDescendsToItsButton() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 40)
        let tree: [Int: GeometricHitTest.Node<Int>] = [
            0: .init(role: "AXCell", frame: frame, children: [1]),
            1: .init(role: "AXButton", frame: frame, children: [])]
        #expect(GeometricHitTest.refine(hit: 0, window: nil, point: CGPoint(x: 10, y: 10), read: { tree[$0]! }).element == 1)
    }

    @Test func collectionHitCanResolveSiblingScrollbarWithinItsScrollArea() {
        let tree: [Int: GeometricHitTest.Node<Int>] = [
            0: .init(role: "AXScrollArea", frame: CGRect(x: 447, y: 359, width: 215, height: 519), children: [1, 3]),
            1: .init(role: "AXOutline", frame: CGRect(x: 447, y: 359, width: 215, height: 519), children: [2]),
            2: .init(role: "AXCell", frame: CGRect(x: 457, y: 836, width: 195, height: 32), children: []),
            3: .init(role: "AXButton", frame: CGRect(x: 653, y: 840, width: 6, height: 30), children: [])]
        for hit in [1, 2] {
            let refined = GeometricHitTest.refine(hit: hit, window: nil, point: CGPoint(x: 656, y: 859),
                inCollection: true, scrollContainer: 0, read: { tree[$0]! })
            #expect(refined.element == 3)
            #expect(refined.quality == "geometric")
        }
        // v0.10 C2: unrelated grouped overlays still keep their own subtree.
        let overlay: [Int: GeometricHitTest.Node<Int>] = [
            0: .init(role: "AXScrollArea", frame: CGRect(x: 0, y: 0, width: 100, height: 100), children: [1, 2]),
            1: .init(role: "AXGroup", frame: nil, children: []),
            2: .init(role: "AXButton", frame: CGRect(x: 0, y: 0, width: 20, height: 20), children: [])]
        #expect(GeometricHitTest.refine(hit: 1, window: nil, point: CGPoint(x: 10, y: 10),
            inCollection: true, scrollContainer: 0, read: { overlay[$0]! }).element == 1)
    }

    @Test func deeperControlWinsWithinTenPercentOfSmallestArea() {
        for (width, expected) in [(109.0, 2), (111.0, 1)] {
            let tree: [Int: GeometricHitTest.Node<Int>] = [
                0: .init(role: "AXGroup", frame: nil, children: [1]),
                1: .init(role: "AXButton", frame: CGRect(x: 0, y: 0, width: 100, height: 20), children: [2]),
                2: .init(role: "AXButton", frame: CGRect(x: 0, y: 0, width: width, height: 20), children: [])]
            #expect(GeometricHitTest.search(root: 0, point: CGPoint(x: 10, y: 10), read: { tree[$0]! }) == expected)
        }
    }

    @Test func floatingHeaderWinsOverSmallerDeeperRowCell() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 30)
        let tree: [Int: GeometricHitTest.Node<Int>] = [
            0: .init(role: "AXOutline", frame: frame, children: [1, 3]),
            1: .init(role: "AXRow", frame: frame, children: [2]),
            2: .init(role: "AXCell", frame: CGRect(x: 5, y: 5, width: 10, height: 10), children: []),
            3: .init(role: "AXGroup", frame: frame, children: [4]),
            4: .init(role: "AXButton", frame: frame, children: [])]
        #expect(GeometricHitTest.search(root: 0, point: CGPoint(x: 10, y: 10), read: { tree[$0]! }) == 4)
    }

    @Test func cappedOutlineNeverReturnsRowInsteadOfLaterHeader() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 30)
        let rows = Array(1...100)
        var reads = 0
        let result = GeometricHitTest.search(root: 0, point: CGPoint(x: 10, y: 10), nodeCap: 12) { id in
            reads += 1
            if id == 0 { return .init(role: "AXOutline", frame: frame, children: rows + [101]) }
            if id == 101 { return .init(role: "AXGroup", frame: frame, children: [102]) }
            return .init(role: id == 102 ? "AXButton" : "AXCell", frame: frame, children: [])
        }
        #expect(result == nil || result == 102)
        #expect(reads <= 12)
    }

    @Test func deadlineCannotPromoteAnIncompleteCellMatch() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 30)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var elapsed = 0.0
        let result = GeometricHitTest.search(root: 0, point: CGPoint(x: 10, y: 10),
            now: { start.addingTimeInterval(elapsed) }) { id in
            if id == 0 { return .init(role: "AXOutline", frame: frame, children: [1, 2]) }
            elapsed = 2
            return .init(role: "AXCell", frame: frame, children: [])
        }
        #expect(result == nil)
    }

    @Test func laterSlowSiblingCannotDiscardAnAlreadyFoundHeader() {
        let frame = CGRect(x: 0, y: 0, width: 200, height: 30)
        let start = Date(timeIntervalSinceReferenceDate: 0)
        var elapsed = 0.0
        let result = GeometricHitTest.search(root: 0, point: CGPoint(x: 10, y: 10),
            now: { start.addingTimeInterval(elapsed) }) { id in
            if id == 0 { return .init(role: "AXOutline", frame: frame, children: [1, 2]) }
            if id == 1 { return .init(role: "AXButton", frame: frame, children: []) }
            elapsed = 2
            return .init(role: "AXCell", frame: frame, children: [])
        }
        #expect(result == 1)
    }

    @Test func containingChildrenAreVisitedFirstWithoutDuplicateReads() {
        let inside = CGRect(x: 0, y: 0, width: 30, height: 30)
        let outside = CGRect(x: 100, y: 100, width: 30, height: 30)
        let tree: [Int: GeometricHitTest.Node<Int>] = [
            0: .init(role: "AXGroup", frame: nil, children: [1, 2, 5]),
            1: .init(role: "AXGroup", frame: outside, children: [3]),
            2: .init(role: "AXGroup", frame: inside, children: [4]),
            3: .init(role: "AXButton", frame: outside, children: []),
            4: .init(role: "AXButton", frame: inside, children: []),
            5: .init(role: "AXGroup", frame: inside, children: [6]),
            6: .init(role: "AXButton", frame: inside, children: [])]
        var reads: [Int] = []
        _ = GeometricHitTest.search(root: 0, point: CGPoint(x: 10, y: 10)) { id in
            reads.append(id)
            return tree[id]!
        }
        #expect(reads.firstIndex(of: 4)! < reads.firstIndex(of: 6)!)
        #expect(reads.firstIndex(of: 6)! < reads.firstIndex(of: 3)!)
        #expect(Set(reads).count == reads.count)
    }

    @Test func offPointRowsArePrunedButCoarseFramesKeepDescendants() {
        for role in ["AXRow", "AXCell"] {
            for frame in [CGRect?.none, CGRect.zero, CGRect(x: 100, y: 100, width: 30, height: 30)] {
                var readLeaf = false
                let result = GeometricHitTest.search(root: 0, point: CGPoint(x: 10, y: 10), inCollection: true) { id in
                    if id == 0 { return .init(role: role, frame: frame, children: [1]) }
                    readLeaf = true
                    return .init(role: "AXButton", frame: CGRect(x: 0, y: 0, width: 30, height: 30), children: [])
                }
                let usable = frame.map { $0.width >= 2 && $0.height >= 2 } ?? false
                #expect(readLeaf == !usable)
                #expect(result == (usable ? nil : 1))
            }
        }
    }

    @Test func outOfFrameRecoveryStaysInsideOverlay() {
        let windowFrame = CGRect(x: 0, y: 0, width: 500, height: 500)
        let controlFrame = CGRect(x: 100, y: 100, width: 80, height: 30)
        for role in ["AXSheet", "AXPopover", "AXDialog"] {
            let tree: [Int: GeometricHitTest.Node<Int>] = [
                0: .init(role: "AXWindow", frame: windowFrame, children: [1, 2]),
                1: .init(role: "AXButton", frame: CGRect(x: 110, y: 110, width: 10, height: 10), children: []),
                2: .init(role: role, frame: windowFrame, children: [3, 4]),
                3: .init(role: "AXButton", frame: CGRect(x: 300, y: 300, width: 30, height: 30), children: []),
                4: .init(role: "AXButton", frame: controlFrame, children: [])]
            let result = GeometricHitTest.refine(hit: 3, window: 0, point: CGPoint(x: 115, y: 115),
                recoveryRoot: 2, read: { tree[$0]! })
            #expect(result.element == 4)
            #expect(result.quality == "geometric")
        }
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
