import Foundation
import ApplicationServices

/// AX tree snapshot + diff.  Lets agents observe "what changed after I
/// clicked" without screenshot-diffing.  Snapshots are stored in-process
/// (no persistence) and LRU-capped at 16 to bound memory.
///
/// Implementation: each node is identified by `CFHash` of its AXUIElement
/// (same pattern as our existing `AXKey` in AccessibilityController), plus
/// its role + title + value.  Two snapshots of the same window are diffed
/// by hash-set:
///   added   = hashes in B but not A
///   removed = hashes in A but not B
///   changed = hashes in both but attrs differ
actor AXSnapshotController {

    struct NodeSnapshot: Codable, Sendable {
        let key: String          // CFHash hex
        let role: String?
        let title: String?
        let value: String?
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?
    }

    struct SnapshotTaken: Codable, Sendable {
        let snapshotID: String
        let pid: Int32
        let ts: String
        let nodeCount: Int
    }

    struct Diff: Codable, Sendable {
        let fromSnapshotID: String
        let toSnapshotID: String
        let added: [NodeSnapshot]
        let removed: [NodeSnapshot]
        let changed: [ChangedNode]
    }

    struct ChangedNode: Codable, Sendable {
        let key: String
        let role: String?
        let title: String?
        let changes: [String: String]   // attr → "old → new"
    }

    private struct Snapshot: Sendable {
        let id: String
        let pid: Int32
        let ts: Date
        let byKey: [String: NodeSnapshot]
    }

    // LRU of recent snapshots. 16 is large enough for normal agent flow,
    // small enough to be cheap.
    private var snapshots: [Snapshot] = []
    private let maxSnapshots = 16

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    /// Capture a snapshot of the AX tree rooted at `pid`.
    func capture(pid: pid_t, maxDepth: Int = 12) -> SnapshotTaken {
        let root = AXUIElementCreateApplication(pid)
        var flat: [String: NodeSnapshot] = [:]
        walk(element: root, depth: 0, maxDepth: maxDepth, into: &flat)

        let id = "snap_" + String(UUID().uuidString.prefix(12)).lowercased()
        let now = Date()
        let snap = Snapshot(id: id, pid: Int32(pid), ts: now, byKey: flat)
        snapshots.append(snap)
        if snapshots.count > maxSnapshots { snapshots.removeFirst() }
        return SnapshotTaken(
            snapshotID: id,
            pid: Int32(pid),
            ts: isoFormatter.string(from: now),
            nodeCount: flat.count
        )
    }

    /// Diff two previously-captured snapshots.  `from` / `to` are IDs from
    /// earlier `capture` calls.  Returns structured added/removed/changed.
    func diff(from: String, to: String) -> Diff? {
        guard let a = snapshots.first(where: { $0.id == from }),
              let b = snapshots.first(where: { $0.id == to }) else {
            return nil
        }
        let aKeys = Set(a.byKey.keys)
        let bKeys = Set(b.byKey.keys)

        let addedKeys = bKeys.subtracting(aKeys)
        let removedKeys = aKeys.subtracting(bKeys)
        let bothKeys = aKeys.intersection(bKeys)

        let added = addedKeys.compactMap { b.byKey[$0] }
        let removed = removedKeys.compactMap { a.byKey[$0] }
        var changed: [ChangedNode] = []
        for key in bothKeys {
            guard let oldN = a.byKey[key], let newN = b.byKey[key] else { continue }
            var diffs: [String: String] = [:]
            if oldN.role != newN.role { diffs["role"] = "\(oldN.role ?? "nil") → \(newN.role ?? "nil")" }
            if oldN.title != newN.title { diffs["title"] = "\(oldN.title ?? "nil") → \(newN.title ?? "nil")" }
            if oldN.value != newN.value { diffs["value"] = "\(oldN.value ?? "nil") → \(newN.value ?? "nil")" }
            // Position / size: only flag if they moved more than 1px (avoid
            // subpixel layout jitter noise).
            if let a1 = oldN.x, let b1 = newN.x, abs(a1 - b1) > 1.0 { diffs["x"] = "\(a1) → \(b1)" }
            if let a1 = oldN.y, let b1 = newN.y, abs(a1 - b1) > 1.0 { diffs["y"] = "\(a1) → \(b1)" }
            if let a1 = oldN.width, let b1 = newN.width, abs(a1 - b1) > 1.0 { diffs["width"] = "\(a1) → \(b1)" }
            if let a1 = oldN.height, let b1 = newN.height, abs(a1 - b1) > 1.0 { diffs["height"] = "\(a1) → \(b1)" }
            if !diffs.isEmpty {
                changed.append(.init(key: key, role: newN.role, title: newN.title, changes: diffs))
            }
        }

        return Diff(
            fromSnapshotID: from,
            toSnapshotID: to,
            added: added,
            removed: removed,
            changed: changed
        )
    }

    // MARK: - Walk helpers

    private func walk(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        into flat: inout [String: NodeSnapshot]
    ) {
        if depth > maxDepth { return }
        let key = String(CFHash(element), radix: 16)
        if flat[key] != nil { return } // already visited (cycle)

        let role = stringAttr(element, kAXRoleAttribute)
        let title = stringAttr(element, kAXTitleAttribute)
        let value = stringAttr(element, kAXValueAttribute)
        let pos = pointAttr(element, kAXPositionAttribute)
        let size = sizeAttr(element, kAXSizeAttribute)

        flat[key] = NodeSnapshot(
            key: key,
            role: role,
            title: title,
            value: value,
            x: pos?.x, y: pos?.y,
            width: size?.width, height: size?.height
        )

        var raw: CFTypeRef?
        let res = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
        if res == .success, let children = raw as? [AXUIElement] {
            for c in children {
                walk(element: c, depth: depth + 1, maxDepth: maxDepth, into: &flat)
            }
        }
    }

    private func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    private func pointAttr(_ el: AXUIElement, _ attr: String) -> (x: Double, y: Double)? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success else { return nil }
        guard let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return (Double(point.x), Double(point.y))
    }

    private func sizeAttr(_ el: AXUIElement, _ attr: String) -> (width: Double, height: Double)? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success else { return nil }
        guard let value = raw, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return (Double(size.width), Double(size.height))
    }
}
