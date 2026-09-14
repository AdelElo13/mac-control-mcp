import Testing
import Foundation
@testable import MacControlMCP

/// A-4 regression: `ax_snapshot_diff` of two captures of an IDLE app
/// 118 ms apart reported `added: 4` (AXMenu / AXMenuItem nodes parked at
/// x:0, y:screen_height with size 0×0) and `changed: 2`, and `nodeCount`
/// drifted 1112 → 1115 → 1116 across identical captures.
///
/// Two root causes:
///   1. macOS parks hidden menu items off-screen at zero size; they blink
///      in and out of the AX tree on their own. `ground` already filters
///      that signature — snapshots did not.
///   2. Nodes were keyed by `CFHash(AXUIElement)`, which is an ephemeral
///      per-reference identity: the same logical control can hand out a
///      different hash on the next walk, so a stable tree diffs as
///      added+removed. Identity must be structural: role + identifier or
///      title + parent path + sibling index among same-identity siblings.
@Suite("AX snapshot stable identity + parked-node filtering")
struct AXSnapshotIdentityTests {

    private func node(
        _ role: String,
        identifier: String? = nil,
        title: String? = nil,
        value: String? = nil,
        x: Double = 10, y: Double = 10, w: Double = 100, h: Double = 20,
        children: [AXSnapshotController.RawNode] = []
    ) -> AXSnapshotController.RawNode {
        .init(role: role, identifier: identifier, title: title, value: value,
              x: x, y: y, width: w, height: h, children: children)
    }

    private let screenHeight: Double = 1169

    /// Safari-like tree: a window with a toolbar + two buttons, plus the
    /// parked menu nodes macOS keeps flickering in and out.
    private func baseTree(saveTitle: String = "Save", value: String? = nil) -> AXSnapshotController.RawNode {
        node("AXApplication", title: "Safari", children: [
            node("AXWindow", title: "Start Page", children: [
                node("AXToolbar", children: [
                    node("AXButton", title: saveTitle, value: value),
                    node("AXButton", title: "Cancel")
                ])
            ])
        ])
    }

    private func parkedMenus() -> [AXSnapshotController.RawNode] {
        [
            node("AXMenu", x: 0, y: screenHeight, w: 0, h: 0, children: [
                node("AXMenuItem", title: "Print…", x: 0, y: screenHeight, w: 0, h: 0),
                node("AXMenuItem", title: "Google Chrome…", x: 0, y: screenHeight, w: 0, h: 0)
            ])
        ]
    }

    @Test("parked zero-size menu nodes are excluded from a snapshot")
    func parkedNodesFiltered() {
        let withMenus = node("AXApplication", title: "Safari",
                             children: [node("AXWindow", title: "Start Page")] + parkedMenus())
        let flat = AXSnapshotController.flatten(withMenus, screenHeight: screenHeight)
        #expect(flat.count == 2)   // AXApplication + AXWindow only
        #expect(!flat.values.contains { $0.role == "AXMenu" })
        #expect(!flat.values.contains { $0.title == "Print…" })
    }

    @Test("parked-node signature recognises both zero size and the y=screen_height park")
    func parkedSignature() {
        #expect(AXSnapshotController.isParked(x: 0, y: screenHeight, width: 0, height: 0,
                                              screenHeight: screenHeight))
        #expect(AXSnapshotController.isParked(x: 300, y: 400, width: 0, height: 0,
                                              screenHeight: screenHeight))
        #expect(AXSnapshotController.isParked(x: 0, y: screenHeight, width: 200, height: 20,
                                              screenHeight: screenHeight))
        #expect(!AXSnapshotController.isParked(x: 10, y: 10, width: 100, height: 20,
                                               screenHeight: screenHeight))
        // Missing geometry is not evidence of parking — keep the node.
        #expect(!AXSnapshotController.isParked(x: nil, y: nil, width: nil, height: nil,
                                               screenHeight: screenHeight))
    }

    @Test("two identical trees diff to empty — even with parked menus flickering")
    func identicalTreesDiffEmpty() {
        let a = node("AXApplication", title: "Safari",
                     children: baseTree().children)
        let b = node("AXApplication", title: "Safari",
                     children: baseTree().children + parkedMenus())

        let diff = AXSnapshotController.computeDiff(
            from: AXSnapshotController.flatten(a, screenHeight: screenHeight),
            to: AXSnapshotController.flatten(b, screenHeight: screenHeight),
            fromID: "snap_a", toID: "snap_b"
        )
        #expect(diff.added.isEmpty)
        #expect(diff.removed.isEmpty)
        #expect(diff.changed.isEmpty)
    }

    @Test("reordered siblings with distinct titles produce no diff")
    func reorderedSiblingsAreStable() {
        let a = node("AXApplication", title: "Safari", children: [
            node("AXWindow", title: "Start Page", children: [
                node("AXToolbar", children: [
                    node("AXButton", title: "Save"),
                    node("AXButton", title: "Cancel")
                ])
            ])
        ])
        let b = node("AXApplication", title: "Safari", children: [
            node("AXWindow", title: "Start Page", children: [
                node("AXToolbar", children: [
                    node("AXButton", title: "Cancel"),
                    node("AXButton", title: "Save")
                ])
            ])
        ])
        let diff = AXSnapshotController.computeDiff(
            from: AXSnapshotController.flatten(a, screenHeight: screenHeight),
            to: AXSnapshotController.flatten(b, screenHeight: screenHeight),
            fromID: "snap_a", toID: "snap_b"
        )
        #expect(diff.added.isEmpty)
        #expect(diff.removed.isEmpty)
        #expect(diff.changed.isEmpty)
    }

    @Test("a real value change is reported as exactly one changed node")
    func realValueChangeDetected() {
        let a = baseTree(value: "0")
        let b = baseTree(value: "1")
        let diff = AXSnapshotController.computeDiff(
            from: AXSnapshotController.flatten(a, screenHeight: screenHeight),
            to: AXSnapshotController.flatten(b, screenHeight: screenHeight),
            fromID: "snap_a", toID: "snap_b"
        )
        #expect(diff.added.isEmpty)
        #expect(diff.removed.isEmpty)
        #expect(diff.changed.count == 1)
        #expect(diff.changed.first?.title == "Save")
        #expect(diff.changed.first?.changes["value"] == "0 → 1")
    }

    @Test("a genuinely new control is reported as added")
    func genuineAdditionDetected() {
        let a = baseTree()
        let b = node("AXApplication", title: "Safari", children: [
            node("AXWindow", title: "Start Page", children: [
                node("AXToolbar", children: [
                    node("AXButton", title: "Save"),
                    node("AXButton", title: "Cancel"),
                    node("AXButton", title: "Share")
                ])
            ])
        ])
        let diff = AXSnapshotController.computeDiff(
            from: AXSnapshotController.flatten(a, screenHeight: screenHeight),
            to: AXSnapshotController.flatten(b, screenHeight: screenHeight),
            fromID: "snap_a", toID: "snap_b"
        )
        #expect(diff.added.count == 1)
        #expect(diff.added.first?.title == "Share")
        #expect(diff.removed.isEmpty)
    }

    @Test("identical untitled siblings stay distinguishable by their index")
    func untitledSiblingsKeepIndexIdentity() {
        let tree = node("AXApplication", title: "App", children: [
            node("AXGroup", children: [
                node("AXStaticText", value: "one"),
                node("AXStaticText", value: "two")
            ])
        ])
        let flat = AXSnapshotController.flatten(tree, screenHeight: screenHeight)
        // app + group + 2 texts, all distinct keys
        #expect(flat.count == 4)
        #expect(Set(flat.keys).count == 4)
    }
}
