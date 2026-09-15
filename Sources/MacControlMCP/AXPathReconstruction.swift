import Foundation

// v0.10 A8: a fake tree must be able to disagree about parents and children,
// just as Chromium's ignored nodes and hit-test aliases do.
struct AXPathTree<Node: Hashable> {
    struct Snapshot {
        let fingerprint: AXFingerprint
        let frame: CGRect?
        let children: [Node]

        func component(index: Int) -> AXPathComponent {
            AXPathComponent(role: fingerprint.role, index: index,
                identifier: fingerprint.identifier, title: fingerprint.title,
                subrole: fingerprint.subrole)
        }
    }

    let root: Node
    let parent: (Node) -> Node?
    let read: (Node) -> Snapshot
}

extension AXPath {
    // v0.10 A8 R2: leave room for a 10k-node page plus native app ancestors
    // while still bounding fallback work when geometry cannot narrow the tree.
    static let reconstructionNodeCap = 12_000
    static let reconstructionDepthLimit = 32

    struct Reconstruction: Sendable {
        let path: [AXPathComponent]?
        let strategy: String?
        let steps: [String]
        let reason: String?
    }

    static func reconstruct<Node>(element: Node, tree: AXPathTree<Node>,
                                  limit: Int = AXPath.reconstructionDepthLimit, nodeCap: Int = AXPath.reconstructionNodeCap) -> Reconstruction {
        let depthLimit = min(reconstructionDepthLimit, max(0, limit))
        let budget = min(reconstructionNodeCap, max(0, nodeCap))
        var snapshots: [Node: AXPathTree<Node>.Snapshot] = [:]
        var exhausted = false
        func snapshot(_ node: Node) -> AXPathTree<Node>.Snapshot? {
            if let cached = snapshots[node] { return cached }
            guard snapshots.count < budget else {
                exhausted = true
                return nil
            }
            let value = tree.read(node)
            snapshots[node] = value
            return value
        }
        func usable(_ frame: CGRect?) -> CGRect? {
            guard let frame, frame.origin.x.isFinite, frame.origin.y.isFinite,
                  frame.width.isFinite, frame.height.isFinite,
                  frame.width > 0, frame.height > 0 else { return nil }
            return frame
        }
        func same(_ lhs: AXPathTree<Node>.Snapshot, _ rhs: AXPathTree<Node>.Snapshot) -> Bool {
            // v0.10 A8: an alias needs all identity fields AND a real frame;
            // equal labels or two failed AX reads cannot establish identity.
            lhs.fingerprint.role != "AXUnknown" && lhs.fingerprint == rhs.fingerprint
                && usable(lhs.frame) != nil && usable(lhs.frame) == usable(rhs.frame)
        }
        func topDown(after failure: String, canonicalTarget: Node? = nil,
                     verifiedPath: [AXPathComponent]? = nil, verifiedSteps: [String] = []) -> Reconstruction {
            func failed(_ reason: String) -> Reconstruction {
                Reconstruction(path: nil, strategy: nil, steps: [], reason: "\(failure);\(reason)")
            }
            let searchElement = canonicalTarget ?? element
            guard let target = snapshot(searchElement) else { return failed("top_down_node_cap") }
            func search(pruned: Bool) -> Reconstruction {
                // v0.10 A8 R2: a previous pass may exhaust new reads, but
                // fallback can still reach an overflow target using the memo.
                exhausted = false
                var skippedGeometry = false
                var seen = Set<Node>()
                var candidate: [AXPathComponent]?
                var exact: [AXPathComponent]?
                var ambiguous = false
                var depthExceeded = false
                var unreadable = false
                func visit(_ node: Node, path: [AXPathComponent]) {
                    guard exact == nil, !exhausted, seen.insert(node).inserted,
                          let value = snapshot(node) else { return }
                    // v0.10 A8 R2: read siblings to preserve their ordinals, but
                    // avoid their descendants when the hit cannot fit their frame.
                    // Missing/zero-size frames cannot rule out hidden children.
                    if pruned, node != tree.root, let frame = usable(value.frame),
                       let targetFrame = usable(target.frame), !frame.contains(targetFrame) {
                        skippedGeometry = true
                        return
                    }
                    guard node == tree.root || value.fingerprint.role != "AXUnknown" else {
                        unreadable = true
                        return
                    }
                    if node == searchElement {
                        exact = path
                        return
                    }
                    if canonicalTarget == nil, same(value, target) {
                        if candidate != nil { ambiguous = true } else { candidate = path }
                    }
                    // v0.10 A8 R2: the fallback retains unpruned tree-walk order
                    // for overflow and globally ambiguous fingerprint aliases.
                    if path.count >= depthLimit {
                        if !value.children.isEmpty { depthExceeded = true }
                        return
                    }
                    for (index, child) in value.children.enumerated() {
                        guard exact == nil, !exhausted else { break }
                        guard !seen.contains(child), let childValue = snapshot(child) else { continue }
                        visit(child, path: path + [childValue.component(index: index)])
                    }
                }
                visit(tree.root, path: [])
                if let exact {
                    // v0.10 A8: an unreadable earlier subtree may hide the first
                    // occurrence of this handle, so its DFS ordinal is unverified.
                    if unreadable { return failed("top_down_unreadable_node") }
                    if exact == verifiedPath {
                        return Reconstruction(path: exact, strategy: "parent_chain", steps: verifiedSteps, reason: nil)
                    }
                    return Reconstruction(path: exact, strategy: "top_down", steps: ["cf_equal"], reason: nil)
                }
                // v0.10 A8 R2: a pruned alias is not proof of global uniqueness;
                // an excluded branch may also contain the exact handle.
                if pruned, skippedGeometry { return failed("top_down_pruned_incomplete") }
                // v0.10 A8: a partially searched tree cannot prove an alias unique.
                if exhausted { return failed("top_down_node_cap") }
                if depthExceeded { return failed("top_down_depth_limit") }
                if unreadable { return failed("top_down_unreadable_node") }
                if ambiguous { return failed("top_down_ambiguous") }
                if let candidate {
                    return Reconstruction(path: candidate, strategy: "top_down", steps: ["fingerprint_frame"], reason: nil)
                }
                return failed(usable(target.frame) == nil ? "top_down_no_target_frame" : "top_down_not_found")
            }
            // v0.10 A8 R2: canonical checks of known multi-parent handles
            // still need the first full-DFS occurrence. Web hits with broken
            // parent chains first try the cheap geometrically selected path.
            if canonicalTarget == nil, usable(target.frame) != nil {
                let geometric = search(pruned: true)
                if geometric.path != nil { return geometric }
            }
            return search(pruned: false)
        }
        if element == tree.root {
            return Reconstruction(path: [], strategy: "parent_chain", steps: [], reason: nil)
        }
        var ascending = [element]
        var seen: Set<Node> = [element]
        var rootFound = false
        var failure = "no_app_root"
        while ascending.count <= depthLimit {
            guard let current = ascending.last, let value = snapshot(current) else {
                failure = "parent_chain_node_cap"
                break
            }
            if value.fingerprint.role == "AXApplication" {
                rootFound = true
                break
            }
            guard let parent = tree.parent(current) else { break }
            guard seen.insert(parent).inserted else {
                failure = "parent_chain_cycle_at_depth_\(ascending.count)"
                break
            }
            ascending.append(parent)
            if parent == tree.root {
                rootFound = true
                break
            }
        }
        if !rootFound {
            if ascending.count > depthLimit { failure = "parent_chain_depth_limit_\(depthLimit)" }
            return topDown(after: failure)
        }
        // v0.10 A8: even a role-only app anchor must verify against the real
        // application children; otherwise the recorded path is not root-relative.
        var current = tree.root
        var path: [AXPathComponent] = []
        var steps: [String] = []
        for child in ascending.dropLast().reversed() {
            let broken = "parent_chain_break_at_depth_\(path.count + 1)"
            guard let parentValue = snapshot(current) else { return topDown(after: broken) }
            let index: Int
            let strategy: String
            if let equalIndex = parentValue.children.firstIndex(of: child) {
                index = equalIndex
                strategy = "cf_equal"
            } else {
                guard let wanted = snapshot(child) else { return topDown(after: broken) }
                var matches: [Int] = []
                var unreadable = false
                for (ordinal, sibling) in parentValue.children.enumerated() {
                    guard let value = snapshot(sibling) else { break }
                    if value.fingerprint.role == "AXUnknown" { unreadable = true }
                    if same(value, wanted) { matches.append(ordinal) }
                }
                // v0.10 A8: failed sibling reads leave alias uniqueness unknown.
                guard !exhausted, !unreadable, matches.count == 1, let match = matches.first else {
                    return topDown(after: broken)
                }
                index = match
                strategy = "fingerprint_frame"
            }
            current = parentValue.children[index]
            guard let value = snapshot(current), value.fingerprint.role != "AXUnknown" else {
                return topDown(after: broken)
            }
            path.append(value.component(index: index))
            steps.append(strategy)
        }
        // v0.10 A8: AXChildren is a graph in some apps. A later parent can
        // list a handle already visited under an earlier sibling. Only an
        // all-first-child chain is inherently the first DFS path; verify the
        // prefix for other chains so hit-test and tree-walk ids agree.
        if path.contains(where: { $0.index != 0 }) {
            return topDown(after: "parent_chain_canonical_check", canonicalTarget: current,
                verifiedPath: path, verifiedSteps: steps)
        }
        return Reconstruction(path: path, strategy: "parent_chain", steps: steps, reason: nil)
    }
}
