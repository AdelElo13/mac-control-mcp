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

    static func search<ID: Hashable>(root: ID, point: CGPoint, nodeCap: Int = 2000, inCollection: Bool = false,
                                    read: (ID) -> Node<ID>) -> ID? {
        var visited: Set<ID> = []
        var candidates: [(id: ID, area: Double, depth: Int)] = []
        let deadline = Date().addingTimeInterval(1)
        func walk(_ id: ID, depth: Int, inCollection: Bool) {
            guard depth <= 24, visited.count < nodeCap, Date() < deadline,
                  visited.insert(id).inserted else { return }
            let node = read(id)
            let collection = inCollection || node.role == "AXOutline" || node.role == "AXTable"
            // v0.10 C2 review: table/outline rows and cells are selectable
            // controls even when the generic AX action whitelist excludes them.
            let selectable = AXPayload.isInteractive(role: node.role)
                || (collection && (node.role == "AXRow" || node.role == "AXCell"))
            if selectable, let frame = node.frame,
               frame.width >= 2, frame.height >= 2, frame.contains(point) {
                let area = frame.width * frame.height
                candidates.append((id, area, depth))
            }
            // v0.10 C2: missing or coarse parent geometry must not hide a
            // valid child. Identity, depth, time and node caps bound the walk.
            for child in node.children {
                guard visited.count < nodeCap, Date() < deadline else { break }
                walk(child, depth: depth + 1, inCollection: collection)
            }
        }
        walk(root, depth: 0, inCollection: inCollection)
        guard let smallestArea = candidates.map(\.area).min() else { return nil }
        // v0.10 C2 review: near-identical SwiftUI frames favour the deeper
        // leaf. Anchor the 10% band to the actual minimum to prevent drift.
        return candidates.filter { $0.area <= smallestArea * 1.1 }.sorted {
            if $0.depth != $1.depth { return $0.depth > $1.depth }
            return $0.area < $1.area
        }.first?.id
    }
}
