import Foundation
import CoreGraphics

/// v0.10 C2: bounded geometric fallback for coarse AX hits.
enum GeometricHitTest {
    struct Node<ID> {
        let role: String?
        let frame: CGRect?
        let children: [ID]
    }

    static func needsSearch(role: String?, frame: CGRect?, window: CGRect?) -> Bool {
        if ["AXGroup", "AXScrollArea", "AXWindow", "AXSplitGroup", "AXOutline", "AXTable", "AXRow", "AXCell"].contains(role) { return true }
        guard !AXPayload.isInteractive(role: role), let frame, let window,
              window.width > 0, window.height > 0 else { return false }
        return frame.width * frame.height >= 0.5 * window.width * window.height
    }

    static func refine<ID: Hashable>(hit: ID, window: ID?, point: CGPoint, inCollection: Bool = false, scrollContainer: ID? = nil,
                                     read: (ID) -> Node<ID>) -> (element: ID, quality: String) {
        let node = read(hit)
        let windowFrame = window.flatMap { read($0).frame }
        guard needsSearch(role: node.role, frame: node.frame, window: windowFrame) else { return (hit, "direct") }
        // v0.10 C2 review: AX can name the sidebar cell/outline when the
        // point lies on its sibling scrollbar. Only collection hits may use
        // their nearest containing scroll area; overlays keep their own subtree.
        var root = hit
        let collection = inCollection || node.role == "AXOutline" || node.role == "AXTable"
        if collection, ["AXOutline", "AXTable", "AXRow", "AXCell"].contains(node.role),
           let scrollContainer {
            let scroll = read(scrollContainer)
            if scroll.role == "AXScrollArea", scroll.frame?.contains(point) == true { root = scrollContainer }
        }
        let best = search(root: root, point: point, inCollection: inCollection, read: read)
        return best.map { ($0, "geometric") } ?? (hit, "container")
    }

    static func search<ID: Hashable>(root: ID, point: CGPoint, nodeCap: Int = 2000, inCollection: Bool = false, now: () -> Date = { Date() },
                                    read: (ID) -> Node<ID>) -> ID? {
        var visited: Set<ID> = []
        var cache: [ID: Node<ID>] = [:]
        var candidates: [(id: ID, area: Double, depth: Int, rowOrCell: Bool)] = []
        var truncated = false
        let deadline = now().addingTimeInterval(1)

        func node(_ id: ID) -> Node<ID>? {
            guard now() < deadline else { truncated = true; return nil }
            if let cached = cache[id] { return cached }
            // v0.10 C2 round 2: prioritising child geometry must not bypass
            // the IPC budget or read the same node again during descent.
            guard cache.count < nodeCap else { truncated = true; return nil }
            let value = read(id)
            cache[id] = value
            if now() >= deadline { truncated = true }
            return value
        }

        func walk(_ id: ID, depth: Int, inCollection: Bool) {
            guard !visited.contains(id) else { return }
            guard depth <= 24 else { truncated = true; return }
            guard let current = node(id) else { return }
            visited.insert(id)
            let collection = inCollection || current.role == "AXOutline" || current.role == "AXTable"
            let rowOrCell = current.role == "AXRow" || current.role == "AXCell"
            let usableFrame = current.frame.flatMap { frame -> CGRect? in
                frame.width >= 2 && frame.height >= 2 ? frame : nil
            }
            // v0.10 C2 round 2: scrolled-out rows cannot own this point.
            // Nil/degenerate geometry still permits valid descendants.
            if rowOrCell, let frame = usableFrame, !frame.contains(point) { return }
            let selectable = AXPayload.isInteractive(role: current.role) || (collection && rowOrCell)
            if selectable, let frame = usableFrame, frame.contains(point) {
                candidates.append((id, frame.width * frame.height, depth, rowOrCell))
            }
            guard depth < 24 else {
                if current.children.contains(where: { !visited.contains($0) }) { truncated = true }
                return
            }

            // v0.10 C2 round 2: visit containing children in stable order,
            // then deferred siblings. Descend immediately so later metadata
            // reads cannot exhaust the deadline before a known header is scored.
            var remaining: [ID] = []
            for child in current.children where !visited.contains(child) {
                guard let childNode = node(child) else { break }
                if childNode.frame?.contains(point) == true {
                    walk(child, depth: depth + 1, inCollection: collection)
                } else {
                    remaining.append(child)
                }
            }
            for child in remaining {
                guard now() < deadline else { truncated = true; break }
                walk(child, depth: depth + 1, inCollection: collection)
            }
        }
        walk(root, depth: 0, inCollection: inCollection)

        // v0.10 C2 round 2: explicit controls (including floating header
        // buttons) outrank overlapping collection cells. An incomplete walk
        // with only row/cell candidates cannot claim a precise hit.
        let controls = candidates.filter { !$0.rowOrCell }
        let eligible = controls.isEmpty ? (truncated ? [] : candidates) : controls
        guard let smallestArea = eligible.map(\.area).min() else { return nil }
        // v0.10 C2 review: near-identical SwiftUI frames favour the deeper
        // leaf. Anchor the 10% band to the actual minimum to prevent drift.
        return eligible.filter { $0.area <= smallestArea * 1.1 }.sorted {
            if $0.depth != $1.depth { return $0.depth > $1.depth }
            return $0.area < $1.area
        }.first?.id
    }
}
