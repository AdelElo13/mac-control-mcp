import Foundation
import Testing
@testable import MacControlMCP

// v0.10 A8: these trees reproduce Chromium's inconsistent AXParent/AXChildren
// relations without desktop permissions or depending on a particular page.
extension AXPathTests {
    private struct FakeWebTree {
        typealias Snapshot = AXPathTree<Int>.Snapshot
        var parents: [Int: Int] = [1: 0, 2: 1, 3: 2]
        var nodes: [Int: Snapshot] = [
            0: snapshot("AXApplication", children: [1]),
            1: snapshot("AXWindow", frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [2]),
            2: snapshot("AXWebArea", children: [3]),
            3: snapshot("AXLink", title: "Hacker News", frame: CGRect(x: 50, y: 100, width: 90, height: 20))
        ]

        static func snapshot(_ role: String, title: String? = nil, identifier: String? = nil,
                             frame: CGRect? = nil, children: [Int] = []) -> Snapshot {
            Snapshot(fingerprint: AXFingerprint(role: role, identifier: identifier,
                title: title, subrole: nil), frame: frame, children: children)
        }

        var tree: AXPathTree<Int> {
            AXPathTree(root: 0, parent: { parents[$0] }, read: { nodes[$0]! })
        }

        var canonicalPath: [AXPathComponent] {
            [nodes[1]!.component(index: 0), nodes[2]!.component(index: 0), nodes[3]!.component(index: 0)]
        }
    }

    @Test("A8 parent-chain reconstruction records equal-handle steps")
    func webParentChain() {
        let fake = FakeWebTree()
        let result = AXPath.reconstruct(element: 3, tree: fake.tree)
        #expect(result.path == fake.canonicalPath)
        #expect(result.strategy == "parent_chain")
        #expect(result.steps == ["cf_equal", "cf_equal", "cf_equal"])
    }

    @Test("A8 a relayed hit handle matches a unique sibling by fingerprint and frame")
    func webAliasedHandle() {
        var fake = FakeWebTree()
        fake.nodes[30] = fake.nodes[3]
        fake.parents[30] = 2
        let result = AXPath.reconstruct(element: 30, tree: fake.tree)
        #expect(result.path == fake.canonicalPath)
        #expect(result.steps.last == "fingerprint_frame")
    }

    @Test("A8 skipped AXParent level recovers the exact top-down path and id")
    func webSkippedParent() {
        var fake = FakeWebTree()
        fake.parents[3] = 1
        let result = AXPath.reconstruct(element: 3, tree: fake.tree)
        #expect(result.path == fake.canonicalPath)
        #expect(result.strategy == "top_down")
        #expect(result.path.map { AXPath.identifier(pid: 42, path: $0) }
            == AXPath.identifier(pid: 42, path: fake.canonicalPath))
    }

    @Test("A8 a disconnected parent chain can still recover an aliased web link")
    func webDisconnectedAlias() {
        var fake = FakeWebTree()
        fake.nodes[30] = fake.nodes[3]
        let result = AXPath.reconstruct(element: 30, tree: fake.tree)
        #expect(result.path == fake.canonicalPath)
        #expect(result.strategy == "top_down")
    }

    @Test("A8 an extra virtual parent does not enter the canonical path")
    func webExtraParent() {
        var fake = FakeWebTree()
        fake.nodes[20] = FakeWebTree.snapshot("AXGroup", children: [3])
        fake.parents[3] = 20
        fake.parents[20] = 2
        let result = AXPath.reconstruct(element: 3, tree: fake.tree)
        #expect(result.path == fake.canonicalPath)
        #expect(result.strategy == "top_down")
    }

    @Test("A8 indistinguishable sibling aliases are refused")
    func webAmbiguousAliases() {
        var fake = FakeWebTree()
        fake.nodes[30] = fake.nodes[3]
        fake.nodes[4] = fake.nodes[3]
        fake.nodes[2] = FakeWebTree.snapshot("AXWebArea", children: [3, 4])
        fake.parents[30] = 2
        let result = AXPath.reconstruct(element: 30, tree: fake.tree)
        #expect(result.path == nil)
        #expect(result.reason == "parent_chain_break_at_depth_3;top_down_ambiguous")
    }

    @Test("A8 the node budget bounds actual snapshot reads across both strategies")
    func webNodeCap() {
        let fake = FakeWebTree()
        var reads = 0
        let tree = AXPathTree(root: 0, parent: { fake.parents[$0] }, read: {
            reads += 1
            return fake.nodes[$0]!
        })
        let result = AXPath.reconstruct(element: 3, tree: tree, nodeCap: 2)
        #expect(result.path == nil)
        #expect(reads <= 2)
        #expect(result.reason?.contains("node_cap") == true)
    }

    @Test("A8 missing roots retain a specific reason when top-down cannot find the hit")
    func webMissingRoot() {
        var fake = FakeWebTree()
        fake.nodes[30] = FakeWebTree.snapshot("AXLink", title: "Other",
            frame: CGRect(x: 50, y: 100, width: 90, height: 20))
        let result = AXPath.reconstruct(element: 30, tree: fake.tree)
        #expect(result.path == nil)
        #expect(result.reason == "no_app_root;top_down_not_found")
    }
    @Test("A8 overflowing descendants cannot hide a second matching alias")
    func webOverflowAmbiguity() {
        var fake = FakeWebTree()
        fake.nodes[30] = fake.nodes[3]
        fake.nodes[4] = FakeWebTree.snapshot("AXGroup",
            frame: CGRect(x: 500, y: 500, width: 10, height: 10), children: [5])
        fake.nodes[5] = fake.nodes[3]
        fake.nodes[2] = FakeWebTree.snapshot("AXWebArea", children: [3, 4])
        let result = AXPath.reconstruct(element: 30, tree: fake.tree)
        #expect(result.path == nil)
        #expect(result.reason == "no_app_root;top_down_ambiguous")
    }

    @Test("A8 exact handles recover top-down even when the target has no frame")
    func webFramelessExactHandle() {
        var fake = FakeWebTree()
        fake.nodes[3] = FakeWebTree.snapshot("AXLink", title: "Hacker News")
        fake.parents[3] = 1
        let result = AXPath.reconstruct(element: 3, tree: fake.tree)
        #expect(result.path == fake.canonicalPath)
        #expect(result.strategy == "top_down")
        #expect(result.steps == ["cf_equal"])
    }

    @Test("A8 recovery preserves ordinals among unrelated children")
    func webCanonicalOrdinals() {
        var fake = FakeWebTree()
        fake.nodes[4] = FakeWebTree.snapshot("AXButton", title: "Toolbar")
        fake.nodes[5] = FakeWebTree.snapshot("AXStaticText", title: "News")
        fake.nodes[6] = FakeWebTree.snapshot("AXGroup")
        fake.nodes[1] = FakeWebTree.snapshot("AXWindow", children: [4, 2])
        fake.nodes[2] = FakeWebTree.snapshot("AXWebArea", children: [5, 6, 3])
        fake.parents[3] = 1
        let expected = [fake.nodes[1]!.component(index: 0),
            fake.nodes[2]!.component(index: 1), fake.nodes[3]!.component(index: 2)]
        let result = AXPath.reconstruct(element: 3, tree: fake.tree)
        #expect(result.path == expected)
        #expect(result.path.map { AXPath.identifier(pid: 42, path: $0) }
            == AXPath.identifier(pid: 42, path: expected))
    }

    @Test("A8 alias matching requires role, identifier, title and frame", arguments: ["role", "identifier", "title", "frame", "missing_frame"])
    func webAliasMismatch(field: String) {
        var fake = FakeWebTree()
        fake.nodes[30] = FakeWebTree.snapshot(field == "role" ? "AXButton" : "AXLink",
            title: field == "title" ? "new" : "Hacker News", identifier: field == "identifier" ? "other" : nil,
            frame: field == "missing_frame" ? nil : CGRect(x: field == "frame" ? 51 : 50, y: 100, width: 90, height: 20))
        fake.parents[30] = 2
        let result = AXPath.reconstruct(element: 30, tree: fake.tree)
        #expect(result.path == nil)
        #expect(result.reason?.hasPrefix("parent_chain_break_at_depth_3;") == true)
    }

    @Test("A8 a candidate found before the cap cannot establish alias uniqueness")
    func webPartialAliasSearch() {
        var fake = FakeWebTree()
        fake.nodes[30] = fake.nodes[3]
        fake.nodes[4] = FakeWebTree.snapshot("AXButton")
        fake.nodes[2] = FakeWebTree.snapshot("AXWebArea", children: [3, 4])
        let result = AXPath.reconstruct(element: 30, tree: fake.tree, nodeCap: 5)
        #expect(result.path == nil)
        #expect(result.reason == "no_app_root;top_down_node_cap")
    }

    @Test("A8 top-down depth cap refuses paths deeper than the configured limit")
    func webDepthCap() {
        var fake = FakeWebTree()
        fake.parents.removeValue(forKey: 3)
        let result = AXPath.reconstruct(element: 3, tree: fake.tree, limit: 2)
        #expect(result.path == nil)
        #expect(result.reason == "no_app_root;top_down_depth_limit")
        #expect(AXPath.reconstruct(element: 3, tree: fake.tree, limit: 3).path == fake.canonicalPath)
    }

    @Test("A8 cycles terminate in both directions with a specific diagnostic")
    func webCycles() {
        var fake = FakeWebTree()
        fake.parents = [30: 31, 31: 30]
        fake.nodes[30] = FakeWebTree.snapshot("AXLink", title: "missing",
            frame: CGRect(x: 50, y: 100, width: 90, height: 20))
        fake.nodes[31] = FakeWebTree.snapshot("AXGroup")
        fake.nodes[2] = FakeWebTree.snapshot("AXWebArea", children: [1, 3])
        let result = AXPath.reconstruct(element: 30, tree: fake.tree)
        #expect(result.path == nil)
        #expect(result.reason == "parent_chain_cycle_at_depth_2;top_down_not_found")
    }

    @Test("A8 alias descendants are checked against the canonical parent")
    func webCanonicalAliasParent() {
        var fake = FakeWebTree()
        fake.nodes[2] = FakeWebTree.snapshot("AXWebArea", frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [3])
        fake.nodes[20] = FakeWebTree.snapshot("AXWebArea", frame: CGRect(x: 0, y: 0, width: 800, height: 600), children: [30])
        fake.nodes[30] = fake.nodes[3]
        fake.parents[30] = 20
        fake.parents[20] = 1
        let result = AXPath.reconstruct(element: 30, tree: fake.tree)
        #expect(result.path == fake.canonicalPath)
        #expect(result.steps == ["cf_equal", "fingerprint_frame", "fingerprint_frame"])
    }

    @Test("A8 tool output preserves reconstruction strategy and specific failure")
    func webEncodedDiagnostics() {
        let fake = FakeWebTree()
        let identity = AXPath.reconstruct(element: 3, tree: fake.tree)
        let info = AccessibilityController.ElementInfo(role: "AXLink", title: "Hacker News",
            value: nil, position: nil, size: nil, depth: nil)
        var hit = AccessibilityController.HitTest(info: info, enabled: true, pid: 42,
            appName: "Chrome", path: identity.path, ancestors: [], identity: identity)
        let payload = ToolRegistry.encodeHit(hit, id: "el_stable", x: 50, y: 100)
        #expect(payload["stable_id_strategy"] == .string("parent_chain"))
        #expect(payload["stable_id_steps"] == .array([.string("cf_equal"), .string("cf_equal"), .string("cf_equal")]))
        hit = AccessibilityController.HitTest(info: info, enabled: true, pid: 42,
            appName: "Chrome", path: nil, ancestors: [], identity: .init(path: nil,
                strategy: nil, steps: [], reason: "parent_chain_break_at_depth_4;top_down_node_cap"))
        let failure = ToolRegistry.encodeHit(hit, id: "el_random", x: 50, y: 100)
        #expect(failure["stable_id"] == .bool(false))
        #expect(failure["stable_id_reason"] == .string("parent_chain_break_at_depth_4;top_down_node_cap"))
        #expect(failure["stable_id_strategy"] == nil)
    }

    @Test("A8 an unreadable sibling cannot prove a hit alias unique")
    func webUnreadableSibling() {
        var fake = FakeWebTree()
        fake.nodes[30] = fake.nodes[3]
        fake.nodes[4] = FakeWebTree.snapshot("AXUnknown")
        fake.nodes[2] = FakeWebTree.snapshot("AXWebArea", children: [3, 4])
        fake.parents[30] = 2
        let result = AXPath.reconstruct(element: 30, tree: fake.tree)
        #expect(result.path == nil)
        #expect(result.reason == "parent_chain_break_at_depth_3;top_down_unreadable_node")
    }

    @Test("A8 the known application root need not publish a role")
    func webRolelessApplicationRoot() {
        var fake = FakeWebTree()
        fake.nodes[0] = FakeWebTree.snapshot("AXUnknown", children: [1])
        fake.parents[3] = 1
        let result = AXPath.reconstruct(element: 3, tree: fake.tree)
        #expect(result.path == fake.canonicalPath)
        #expect(result.strategy == "top_down")
    }

    @Test("A8 shared handles use the tree walk's first DFS path")
    func webSharedHandleCanonicalPath() {
        var fake = FakeWebTree()
        fake.nodes[4] = FakeWebTree.snapshot("AXWindow", children: [3])
        fake.nodes[0] = FakeWebTree.snapshot("AXApplication", children: [4, 1])
        let expected = [fake.nodes[4]!.component(index: 0), fake.nodes[3]!.component(index: 0)]
        let result = AXPath.reconstruct(element: 3, tree: fake.tree)
        #expect(result.path == expected)
        #expect(result.strategy == "top_down")
        #expect(result.path.map { AXPath.identifier(pid: 42, path: $0) }
            == AXPath.identifier(pid: 42, path: expected))
    }

    @Test("A8 an unreadable earlier branch prevents a canonical exact-match claim")
    func webSharedHandleUnreadablePrefix() {
        var fake = FakeWebTree()
        fake.nodes[4] = FakeWebTree.snapshot("AXUnknown", children: [3])
        fake.nodes[0] = FakeWebTree.snapshot("AXApplication", children: [4, 1])
        let result = AXPath.reconstruct(element: 3, tree: fake.tree)
        #expect(result.path == nil)
        #expect(result.reason == "parent_chain_canonical_check;top_down_unreadable_node")
    }

    // v0.10 A8 R2: off-target rows must cost one read each, not a walk
    // through their rendered descendants before reaching the final link.
    @Test("A8 geometric reconstruction bounds reads on 5000/10000-node pages", arguments: [5_000, 10_000])
    func webWidePageReads(pageNodes: Int) {
        typealias Snapshot = AXPathTree<Int>.Snapshot
        var nodes: [Int: Snapshot] = [:]
        let groups = 100
        let leaves = pageNodes / groups - 1
        let target = 1_000 + (groups - 1) * leaves + leaves - 1
        nodes[0] = FakeWebTree.snapshot("AXApplication", children: [1])
        nodes[1] = FakeWebTree.snapshot("AXWebArea",
            frame: CGRect(x: 0, y: 0, width: 1000, height: 10000), children: Array(2..<(2 + groups)))
        for group in 0..<groups {
            let children = (0..<leaves).map { 1_000 + group * leaves + $0 }
            nodes[2 + group] = FakeWebTree.snapshot("AXGroup",
                frame: CGRect(x: 0, y: group * 100, width: 1000, height: 100), children: children)
            for (index, child) in children.enumerated() {
                nodes[child] = FakeWebTree.snapshot("AXStaticText", title: "Link \(child)",
                    frame: CGRect(x: index * 5, y: group * 100 + 10, width: 4, height: 10))
            }
        }
        var reads = 0
        let tree = AXPathTree(root: 0, parent: { _ in nil }, read: {
            reads += 1
            return nodes[$0]!
        })
        let result = AXPath.reconstruct(element: target, tree: tree)
        let expected = [nodes[1]!.component(index: 0), nodes[101]!.component(index: 99),
            nodes[target]!.component(index: leaves - 1)]
        print("[A8 R2 wide] page_nodes=\(pageNodes) reads=\(reads) stable=\(result.path != nil)")
        #expect(result.path == expected)
        #expect(result.steps == ["cf_equal"])
        #expect(reads <= 205)
    }

    @Test("A8 pruned search falls back for overflowing exact handles")
    func webPrunedOverflowFallback() {
        var fake = FakeWebTree()
        fake.parents.removeValue(forKey: 3)
        fake.nodes[2] = FakeWebTree.snapshot("AXWebArea",
            frame: CGRect(x: 500, y: 500, width: 10, height: 10), children: [3])
        #expect(AXPath.reconstruct(element: 3, tree: fake.tree).path == fake.canonicalPath)
    }

    @Test("A8 zero-size containers may hide the target")
    func webZeroSizeContainer() {
        var fake = FakeWebTree()
        fake.parents.removeValue(forKey: 3)
        fake.nodes[2] = FakeWebTree.snapshot("AXWebArea", frame: .zero, children: [3])
        #expect(AXPath.reconstruct(element: 3, tree: fake.tree).path == fake.canonicalPath)
    }

    @Test("A8 an exact overflow handle wins over a visible fingerprint alias")
    func webPrunedAliasCannotHideExact() {
        var fake = FakeWebTree()
        fake.parents.removeValue(forKey: 3)
        fake.nodes[4] = fake.nodes[3]
        fake.nodes[5] = FakeWebTree.snapshot("AXGroup",
            frame: CGRect(x: 500, y: 500, width: 10, height: 10), children: [3])
        fake.nodes[2] = FakeWebTree.snapshot("AXWebArea", children: [4, 5])
        let expected = [fake.nodes[1]!.component(index: 0), fake.nodes[2]!.component(index: 0),
            fake.nodes[5]!.component(index: 1), fake.nodes[3]!.component(index: 0)]
        let result = AXPath.reconstruct(element: 3, tree: fake.tree)
        #expect(result.path == expected)
        #expect(result.steps == ["cf_equal"])
    }

    @Test("A8 exhausted pruned pass can fall back through cached overflow nodes")
    func webPrunedBudgetCachedFallback() {
        let target = FakeWebTree.snapshot("AXLink", title: "Target",
            frame: CGRect(x: 10, y: 10, width: 20, height: 20))
        let nodes = [0: FakeWebTree.snapshot("AXApplication", children: [1, 2]),
            1: FakeWebTree.snapshot("AXGroup", frame: CGRect(x: 500, y: 500, width: 10, height: 10), children: [3]),
            2: FakeWebTree.snapshot("AXGroup", children: [4]), 3: target,
            4: FakeWebTree.snapshot("AXButton")]
        var reads = 0
        let tree = AXPathTree(root: 0, parent: { _ in nil }, read: {
            reads += 1
            return nodes[$0]!
        })
        let result = AXPath.reconstruct(element: 3, tree: tree, nodeCap: 4)
        #expect(result.path == [nodes[1]!.component(index: 0), target.component(index: 0)])
        #expect(reads == 4)
    }

    @Test("A8 fallback supports a 10k flat tree but enforces the documented read cap", arguments: [10_000, 12_500])
    func webFlatFallbackCap(nodes: Int) {
        var reads = 0
        let tree = AXPathTree(root: 0, parent: { _ in nil }, read: { node in
            reads += 1
            return FakeWebTree.snapshot(node == 0 ? "AXApplication" : "AXStaticText",
                title: "Node \(node)", children: node == 0 ? Array(1...nodes) : [])
        })
        let result = AXPath.reconstruct(element: nodes, tree: tree, nodeCap: 50_000)
        print("[A8 R2 flat] nodes=\(nodes) reads=\(reads) stable=\(result.path != nil)")
        if nodes == 10_000 {
            #expect(result.path == [AXPathComponent(role: "AXStaticText", index: nodes - 1,
                identifier: nil, title: "Node \(nodes)")])
            #expect(reads == nodes + 1)
        } else {
            #expect(result.path == nil)
            #expect(result.reason == "no_app_root;top_down_node_cap")
            #expect(reads == AXPath.reconstructionNodeCap)
        }
    }

}
