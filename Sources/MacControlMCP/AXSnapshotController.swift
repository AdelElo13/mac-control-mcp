import Foundation
import ApplicationServices
import CoreGraphics

/// AX tree snapshot + diff.  Lets agents observe "what changed after I
/// clicked" without screenshot-diffing.  Snapshots are stored in-process
/// (no persistence) and LRU-capped at 16 to bound memory.
///
/// ## Node identity (v0.8.4 — A-4)
///
/// Nodes used to be keyed by `CFHash(AXUIElement)`. That is an *ephemeral
/// reference* identity: the accessibility server is free to hand out a
/// different AXUIElement — and therefore a different hash — for the same
/// logical control on the next walk. Two captures of a completely idle
/// app 118 ms apart therefore diffed as `added: 4 / changed: 2`, and
/// `nodeCount` drifted 1112 → 1115 → 1116.
///
/// Identity is now **structural**: parent path + role + the node's own
/// identifier (`AXIdentifier`, falling back to `AXTitle`) + its index
/// among siblings that share that same role+identifier. A control keeps
/// its key across captures, siblings that merely swap positions are not
/// reported as added+removed, and genuinely new controls still are.
///
/// Diff:
///   added   = keys in B but not A
///   removed = keys in A but not B
///   changed = keys in both where role/title/value/frame differ
///
/// Parked nodes (macOS keeps hidden menu items at `(0, screen_height)`
/// with size `0×0`, blinking in and out of the tree on their own) are
/// excluded entirely — the same signature `GroundingController.ground`
/// already filters.
actor AXSnapshotController {

    struct NodeSnapshot: Codable, Sendable {
        /// Structural identity path — stable across captures.
        let key: String
        let role: String?
        let title: String?
        let value: String?
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?
    }

    /// A plain, AX-free tree node. The AX walk builds one of these; the
    /// flattening / identity rules are pure functions over it, which is
    /// what makes them unit-testable without a live UI.
    struct RawNode: Sendable {
        let role: String?
        let identifier: String?
        let title: String?
        let value: String?
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?
        let children: [RawNode]

        init(
            role: String?,
            identifier: String? = nil,
            title: String? = nil,
            value: String? = nil,
            x: Double? = nil,
            y: Double? = nil,
            width: Double? = nil,
            height: Double? = nil,
            children: [RawNode] = []
        ) {
            self.role = role
            self.identifier = identifier
            self.title = title
            self.value = value
            self.x = x
            self.y = y
            self.width = width
            self.height = height
            self.children = children
        }
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
        var budget = WalkBudget(deadline: Date().addingTimeInterval(5.0), remaining: 5000)
        var visited = Set<AXKey>()
        let raw = buildRaw(element: root, depth: 0, maxDepth: maxDepth,
                           budget: &budget, visited: &visited)
        let flat = Self.flatten(raw, screenHeight: Double(CGDisplayBounds(CGMainDisplayID()).height))

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
        return Self.computeDiff(from: a.byKey, to: b.byKey, fromID: from, toID: to)
    }

    // MARK: - Pure identity / flattening / diff rules

    /// True when a node is a parked, non-interactable artefact rather than
    /// a real piece of UI:
    ///   * zero size (nothing can be clicked or seen), or
    ///   * the classic macOS hidden-menu park at `x ≈ 0, y ≈ screen_height`.
    /// Nodes with no geometry at all are NOT treated as parked — absence of
    /// a frame is not evidence of parking.
    static func isParked(
        x: Double?, y: Double?, width: Double?, height: Double?,
        screenHeight: Double
    ) -> Bool {
        if let w = width, let h = height, w < 1, h < 1 { return true }
        if let x, let y, abs(x) < 1, abs(y - screenHeight) < 1 { return true }
        return false
    }

    /// Flatten a raw tree into `identity path → NodeSnapshot`, dropping
    /// parked nodes. Children of a parked node are still traversed (and
    /// still keyed beneath it) so that a temporarily zero-sized container
    /// does not shift the identity of everything below it.
    static func flatten(_ root: RawNode, screenHeight: Double) -> [String: NodeSnapshot] {
        var out: [String: NodeSnapshot] = [:]

        func visit(_ node: RawNode, parentPath: String, siblingCounts: inout [String: Int]) {
            let segmentBase = identitySegment(role: node.role,
                                              identifier: node.identifier,
                                              title: node.title)
            let index = siblingCounts[segmentBase, default: 0]
            siblingCounts[segmentBase] = index + 1
            let path = "\(parentPath)/\(segmentBase)[\(index)]"

            if !isParked(x: node.x, y: node.y, width: node.width, height: node.height,
                         screenHeight: screenHeight) {
                out[path] = NodeSnapshot(
                    key: path,
                    role: node.role,
                    title: node.title,
                    value: node.value,
                    x: node.x, y: node.y,
                    width: node.width, height: node.height
                )
            }

            var childCounts: [String: Int] = [:]
            for child in node.children {
                visit(child, parentPath: path, siblingCounts: &childCounts)
            }
        }

        var rootCounts: [String: Int] = [:]
        visit(root, parentPath: "", siblingCounts: &rootCounts)
        return out
    }

    /// `role#identity` — identity is the AX identifier when the app sets
    /// one (the most stable thing available) and otherwise the title.
    /// Empty strings count as absent.
    static func identitySegment(role: String?, identifier: String?, title: String?) -> String {
        let roleName = role ?? "AXUnknown"
        let identity = [identifier, title]
            .compactMap { $0 }
            .first { !$0.isEmpty }
        guard let identity else { return roleName }
        return "\(roleName)#\(identity)"
    }

    static func computeDiff(
        from a: [String: NodeSnapshot],
        to b: [String: NodeSnapshot],
        fromID: String,
        toID: String
    ) -> Diff {
        let aKeys = Set(a.keys)
        let bKeys = Set(b.keys)

        let added = bKeys.subtracting(aKeys).compactMap { b[$0] }
        let removed = aKeys.subtracting(bKeys).compactMap { a[$0] }

        var changed: [ChangedNode] = []
        for key in aKeys.intersection(bKeys) {
            guard let oldN = a[key], let newN = b[key] else { continue }
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
            fromSnapshotID: fromID,
            toSnapshotID: toID,
            added: added,
            removed: removed,
            changed: changed
        )
    }

    // MARK: - Walk helpers

    /// Wall-clock + node-count budget: without it, ax_snapshot_capture on
    /// a large app blocks the server for tens of seconds (each attribute
    /// read is an IPC round trip). Matches the AX walkers' 5 s / 5000 cap.
    private struct WalkBudget {
        let deadline: Date
        var remaining: Int

        var exhausted: Bool { remaining <= 0 || Date() >= deadline }
    }

    private func buildRaw(
        element: AXUIElement,
        depth: Int,
        maxDepth: Int,
        budget: inout WalkBudget,
        visited: inout Set<AXKey>
    ) -> RawNode {
        budget.remaining -= 1
        let role = stringAttr(element, kAXRoleAttribute)
        let identifier = stringAttr(element, kAXIdentifierAttribute)
        let title = stringAttr(element, kAXTitleAttribute)
        // Use a value-aware getter: checkboxes/sliders/steppers/radios expose
        // kAXValue as a number/bool, which `stringAttr` dropped as nil — so
        // toggling a checkbox produced no diff. Stringify numbers too.
        let value = valueString(element, kAXValueAttribute)
        let pos = pointAttr(element, kAXPositionAttribute)
        let size = sizeAttr(element, kAXSizeAttribute)

        var children: [RawNode] = []
        if depth < maxDepth, !budget.exhausted {
            var raw: CFTypeRef?
            let res = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
            if res == .success, let kids = raw as? [AXUIElement] {
                for c in kids {
                    if budget.exhausted { break }
                    // AXKey wraps CFHash + CFEqual — cycle guard only.
                    guard visited.insert(AXKey(element: c)).inserted else { continue }
                    children.append(buildRaw(element: c, depth: depth + 1, maxDepth: maxDepth,
                                             budget: &budget, visited: &visited))
                }
            }
        }

        return RawNode(
            role: role, identifier: identifier, title: title, value: value,
            x: pos?.x, y: pos?.y, width: size?.width, height: size?.height,
            children: children
        )
    }

    private func stringAttr(_ el: AXUIElement, _ attr: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success else { return nil }
        return raw as? String
    }

    /// Like `stringAttr` but also captures numeric/boolean AX values
    /// (checkbox 0/1, slider positions, stepper counts) that come back as
    /// CFNumber/CFBoolean rather than CFString.
    private func valueString(_ el: AXUIElement, _ attr: String) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &raw) == .success,
              let v = raw else { return nil }
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        if CFGetTypeID(v) == AXValueGetTypeID() { return String(describing: v) }
        return nil
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
