import Testing
import Foundation
import CoreGraphics
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
///      added+removed. Identity must be structural.
///
/// Review follow-ups pinned here too: identity must survive an INSERT
/// among untitled same-role siblings (a sibling index shifts, a frame does
/// not), and a title change must read as `changed`, not removed+added.
@Suite("AX snapshot stable identity + parked-node filtering")
struct AXSnapshotIdentityTests {

    private let screenHeight: Double = 1169
    private var displays: [CGRect] { [CGRect(x: 0, y: 0, width: 1800, height: 1169)] }

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

    private func flat(_ tree: AXSnapshotController.RawNode) -> [AXSnapshotController.FlatNode] {
        AXSnapshotController.flatten(tree, displays: displays)
    }

    private func diff(
        _ a: AXSnapshotController.RawNode, _ b: AXSnapshotController.RawNode
    ) -> AXSnapshotController.Diff {
        AXSnapshotController.computeDiff(from: flat(a), to: flat(b),
                                         fromID: "snap_a", toID: "snap_b")
    }

    /// Safari-like tree: a window with a toolbar + two buttons.
    private func baseTree(saveTitle: String = "Save", value: String? = nil) -> AXSnapshotController.RawNode {
        node("AXApplication", title: "Safari", children: [
            node("AXWindow", title: "Start Page", children: [
                node("AXToolbar", children: [
                    node("AXButton", title: saveTitle, value: value, x: 20, y: 60, w: 80, h: 24),
                    node("AXButton", title: "Cancel", x: 120, y: 60, w: 80, h: 24)
                ])
            ])
        ])
    }

    /// The parked menu nodes macOS keeps flickering in and out.
    private func parkedMenus() -> [AXSnapshotController.RawNode] {
        [
            node("AXMenu", x: 0, y: screenHeight, w: 0, h: 0, children: [
                node("AXMenuItem", title: "Print…", x: 0, y: screenHeight, w: 0, h: 0),
                node("AXMenuItem", title: "Google Chrome…", x: 0, y: screenHeight, w: 0, h: 0)
            ])
        ]
    }

    /// A list of untitled rows — the shape that broke sibling-index identity.
    private func rows(_ count: Int, firstY: Double = 100, step: Double = 24) -> [AXSnapshotController.RawNode] {
        (0..<count).map { i in
            node("AXRow", x: 0, y: firstY + Double(i) * step, w: 300, h: 20)
        }
    }

    // MARK: - Parked-node filtering

    @Test("parked zero-size menu nodes are excluded from a snapshot")
    func parkedNodesFiltered() {
        let withMenus = node("AXApplication", title: "Safari",
                             children: [node("AXWindow", title: "Start Page")] + parkedMenus())
        let nodes = flat(withMenus)
        #expect(nodes.count == 2)   // AXApplication + AXWindow only
        #expect(!nodes.contains { $0.role == "AXMenu" })
        #expect(!nodes.contains { $0.title == "Print…" })
    }

    @Test("parking requires zero size AND being outside every display")
    func parkedSignature() {
        // The classic park: zero size at a display's bottom edge.
        #expect(AXSnapshotController.isParked(x: 0, y: screenHeight, width: 0, height: 0,
                                              displays: displays))
        // Zero size but INSIDE a visible window — a collapsed control, keep it.
        #expect(!AXSnapshotController.isParked(x: 300, y: 400, width: 0, height: 0,
                                               displays: displays))
        // Real size at the park position — still a real node, keep it.
        #expect(!AXSnapshotController.isParked(x: 0, y: screenHeight, width: 200, height: 20,
                                               displays: displays))
        // Zero size miles off every display.
        #expect(AXSnapshotController.isParked(x: 9000, y: 400, width: 0, height: 0,
                                              displays: displays))
        // Missing geometry is not evidence of parking — keep the node.
        #expect(!AXSnapshotController.isParked(x: nil, y: nil, width: nil, height: nil,
                                               displays: displays))
    }

    @Test("a second display's own space is not treated as off-screen")
    func parkedRespectsSecondaryDisplays() {
        // Main 1800×1169 at the origin, secondary 1920×1080 to its right.
        let two = [CGRect(x: 0, y: 0, width: 1800, height: 1169),
                   CGRect(x: 1800, y: 0, width: 1920, height: 1080)]
        // Zero-size node inside the SECOND display: main-display-only logic
        // called this off-screen and dropped it.
        #expect(!AXSnapshotController.isParked(x: 2400, y: 300, width: 0, height: 0, displays: two))
        // Parked at the second display's own bottom edge.
        #expect(AXSnapshotController.isParked(x: 1800, y: 1080, width: 0, height: 0, displays: two))
        // Below the main display's bottom but inside the second one's height —
        // real space on display 2, not a park.
        #expect(!AXSnapshotController.isParked(x: 2400, y: 1000, width: 0, height: 0, displays: two))
    }

    // MARK: - Stability

    @Test("two identical trees diff to empty — even with parked menus flickering")
    func identicalTreesDiffEmpty() {
        let a = baseTree()
        let b = node("AXApplication", title: "Safari",
                     children: baseTree().children + parkedMenus())
        let d = diff(a, b)
        #expect(d.added.isEmpty)
        #expect(d.removed.isEmpty)
        #expect(d.changed.isEmpty)
    }

    @Test("reordered siblings with distinct titles produce no diff")
    func reorderedSiblingsAreStable() {
        let a = node("AXApplication", title: "Safari", children: [
            node("AXWindow", title: "Start Page", children: [
                node("AXToolbar", children: [
                    node("AXButton", title: "Save", x: 20, y: 60, w: 80, h: 24),
                    node("AXButton", title: "Cancel", x: 120, y: 60, w: 80, h: 24)
                ])
            ])
        ])
        let b = node("AXApplication", title: "Safari", children: [
            node("AXWindow", title: "Start Page", children: [
                node("AXToolbar", children: [
                    node("AXButton", title: "Cancel", x: 120, y: 60, w: 80, h: 24),
                    node("AXButton", title: "Save", x: 20, y: 60, w: 80, h: 24)
                ])
            ])
        ])
        let d = diff(a, b)
        #expect(d.added.isEmpty)
        #expect(d.removed.isEmpty)
        #expect(d.changed.isEmpty)
    }

    /// Review item 1. Sibling INDEX is not identity: inserting a row at
    /// position 1 shifts the index of every later row, so index-keyed
    /// identity reported 5 removed + 6 added for a one-row insert.
    @Test("inserting one untitled row among five reports exactly one addition")
    func insertAmongUntitledSiblingsIsOneAddition() {
        let before = node("AXTable", children: rows(5))
        var after = rows(5)
        after.insert(node("AXRow", x: 0, y: 1000, w: 300, h: 20), at: 1)
        let d = diff(before, node("AXTable", children: after))
        #expect(d.added.count == 1)
        #expect(d.removed.isEmpty)
        #expect(d.changed.isEmpty)
        #expect(d.added.first?.y == 1000)
    }

    /// The counter-example that motivates frame-based matching: if nodes
    /// are paired by their KEY (which embeds the sibling index, as the
    /// first cut of this fix did), the same one-row insert is reported as
    /// a storm of changes. Pinned here so nobody reintroduces key matching.
    @Test("key-based matching would mis-report the same insert")
    func legacyKeyMatchingWouldMisreport() {
        let before = flat(node("AXTable", children: rows(5)))
        var afterRows = rows(5)
        afterRows.insert(node("AXRow", x: 0, y: 1000, w: 300, h: 20), at: 1)
        let after = flat(node("AXTable", children: afterRows))

        let beforeByKey = Dictionary(before.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let afterByKey = Dictionary(after.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let legacyAdded = Set(afterByKey.keys).subtracting(beforeByKey.keys).count
        let legacyMoved = Set(beforeByKey.keys).intersection(afterByKey.keys).filter { key in
            (beforeByKey[key]?.y ?? 0) != (afterByKey[key]?.y ?? 0)
        }.count

        #expect(legacyAdded == 1)
        #expect(legacyMoved == 4)   // every row at/after the insertion point

        // The shipped matcher sees the insert for what it is.
        let real = AXSnapshotController.computeDiff(from: before, to: after,
                                                    fromID: "a", toID: "b")
        #expect(real.added.count == 1)
        #expect(real.changed.isEmpty)
    }

    @Test("deleting an untitled row reports exactly one removal")
    func deleteAmongUntitledSiblingsIsOneRemoval() {
        var after = rows(5)
        let dropped = after.remove(at: 2)
        let d = diff(node("AXTable", children: rows(5)), node("AXTable", children: after))
        #expect(d.removed.count == 1)
        #expect(d.added.isEmpty)
        #expect(d.changed.isEmpty)
        #expect(d.removed.first?.y == dropped.y)
    }

    // MARK: - Real changes

    @Test("a real value change is reported as exactly one changed node")
    func realValueChangeDetected() {
        let d = diff(baseTree(value: "0"), baseTree(value: "1"))
        #expect(d.added.isEmpty)
        #expect(d.removed.isEmpty)
        #expect(d.changed.count == 1)
        #expect(d.changed.first?.title == "Save")
        #expect(d.changed.first?.changes["value"] == "0 → 1")
    }

    /// Review item 2. A title change moves the node into a different
    /// identity bucket; without the rescue pass it read as removed+added.
    @Test("a title change on an untitled-identifier node is one changed node")
    func titleChangeIsChangedNotAddedRemoved() {
        let d = diff(baseTree(saveTitle: "Save"), baseTree(saveTitle: "Saved…"))
        #expect(d.added.isEmpty)
        #expect(d.removed.isEmpty)
        #expect(d.changed.count == 1)
        #expect(d.changed.first?.changes["title"] == "Save → Saved…")
    }

    @Test("a title change on a node with a stable AXIdentifier never leaves its bucket")
    func titleChangeWithIdentifierStaysInBucket() {
        func tree(_ title: String) -> AXSnapshotController.RawNode {
            node("AXWindow", title: "W", children: [
                node("AXButton", identifier: "save-button", title: title, x: 20, y: 60, w: 80, h: 24)
            ])
        }
        let d = diff(tree("Save"), tree("Saved…"))
        #expect(d.added.isEmpty)
        #expect(d.removed.isEmpty)
        #expect(d.changed.count == 1)
        #expect(d.changed.first?.changes["title"] == "Save → Saved…")
    }

    @Test("a genuinely new control is reported as added")
    func genuineAdditionDetected() {
        let b = node("AXApplication", title: "Safari", children: [
            node("AXWindow", title: "Start Page", children: [
                node("AXToolbar", children: [
                    node("AXButton", title: "Save", x: 20, y: 60, w: 80, h: 24),
                    node("AXButton", title: "Cancel", x: 120, y: 60, w: 80, h: 24),
                    node("AXButton", title: "Share", x: 220, y: 60, w: 80, h: 24)
                ])
            ])
        ])
        let d = diff(baseTree(), b)
        #expect(d.added.count == 1)
        #expect(d.added.first?.title == "Share")
        #expect(d.removed.isEmpty)
    }

    @Test("identical untitled siblings stay distinguishable in the snapshot")
    func untitledSiblingsKeepDistinctKeys() {
        let tree = node("AXApplication", title: "App", children: [
            node("AXGroup", children: [
                node("AXStaticText", value: "one", x: 0, y: 10, w: 50, h: 12),
                node("AXStaticText", value: "two", x: 0, y: 30, w: 50, h: 12)
            ])
        ])
        let nodes = flat(tree)
        #expect(nodes.count == 4)   // app + group + 2 texts
        #expect(Set(nodes.map(\.key)).count == 4)
    }

    @Test("same-identity parents do not merge their subtrees")
    func sameIdentityParentsKeepSeparateSubtrees() {
        let tree = node("AXApplication", title: "App", children: [
            node("AXGroup", x: 0, y: 0, w: 100, h: 100, children: [
                node("AXButton", title: "OK", x: 10, y: 10, w: 40, h: 20)
            ]),
            node("AXGroup", x: 200, y: 0, w: 100, h: 100, children: [
                node("AXButton", title: "OK", x: 210, y: 10, w: 40, h: 20)
            ])
        ])
        let nodes = flat(tree)
        #expect(nodes.count == 5)
        #expect(Set(nodes.map(\.key)).count == 5)
    }
}
