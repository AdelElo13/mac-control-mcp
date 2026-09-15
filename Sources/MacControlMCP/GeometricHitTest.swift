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
        if ["AXGroup", "AXScrollArea", "AXWindow", "AXSplitGroup"].contains(role) { return true }
        guard !AXPayload.isInteractive(role: role), let frame, let window,
              window.width > 0, window.height > 0 else { return false }
        return frame.width * frame.height >= 0.5 * window.width * window.height
    }

    static func search<ID: Hashable>(root: ID, point: CGPoint, nodeCap: Int = 2000,
                                    read: (ID) -> Node<ID>) -> ID? {
        var visited: Set<ID> = []
        var best: ID?
        var bestArea = Double.infinity
        let deadline = Date().addingTimeInterval(1)
        func walk(_ id: ID, depth: Int) {
            guard depth <= 24, visited.count < nodeCap, Date() < deadline,
                  visited.insert(id).inserted else { return }
            let node = read(id)
            if AXPayload.isInteractive(role: node.role), let frame = node.frame,
               frame.width >= 2, frame.height >= 2, frame.contains(point) {
                let area = frame.width * frame.height
                if area < bestArea {
                    bestArea = area
                    best = id
                }
            }
            // v0.10 C2: missing or coarse parent geometry must not hide a
            // valid child. Identity, depth, time and node caps bound the walk.
            for child in node.children {
                guard visited.count < nodeCap, Date() < deadline else { break }
                walk(child, depth: depth + 1)
            }
        }
        walk(root, depth: 0)
        return best
    }
}
