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
        let nodes: [FlatNode]
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
        let flat = Self.flatten(raw, displays: Self.activeDisplayBounds())

        let id = "snap_" + String(UUID().uuidString.prefix(12)).lowercased()
        let now = Date()
        let snap = Snapshot(id: id, pid: Int32(pid), ts: now, nodes: flat)
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
        return Self.computeDiff(from: a.nodes, to: b.nodes, fromID: from, toID: to)
    }

    // MARK: - Pure identity / flattening / diff rules

    /// One flattened node plus everything the matcher needs. `key` is only
    /// a human-readable label for the response; matching never depends on
    /// it (see `computeDiff`).
    struct FlatNode: Sendable {
        let key: String
        /// Identity bucket: parent bucket path + role + identifier/title.
        /// Deliberately index-free — see `computeDiff`.
        let bucketPath: String
        /// The parent's bucket path, for the title-change rescue pass.
        let parentPath: String
        let role: String?
        let identifier: String?
        let title: String?
        let value: String?
        let x: Double?
        let y: Double?
        let width: Double?
        let height: Double?
        /// Position among siblings in the same bucket. Fallback ordering
        /// only, used when frames are unavailable.
        let index: Int

        var snapshot: NodeSnapshot {
            NodeSnapshot(key: key, role: role, title: title, value: value,
                         x: x, y: y, width: width, height: height)
        }

        var hasFrame: Bool { x != nil && y != nil && width != nil && height != nil }
    }

    /// Bounds of every active display, in the same top-left global point
    /// space as AX frames.
    ///
    /// Deliberately CoreGraphics rather than `NSScreen.screens`: NSScreen
    /// frames use AppKit's bottom-left origin, so comparing an AX y against
    /// them would be wrong on every non-main display — and NSScreen is
    /// AppKit, which this actor must not touch off the main thread.
    static func activeDisplayBounds() -> [CGRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else {
            return [CGDisplayBounds(CGMainDisplayID())]
        }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else {
            return [CGDisplayBounds(CGMainDisplayID())]
        }
        let bounds = ids.prefix(Int(count)).map { CGDisplayBounds($0) }
        return bounds.isEmpty ? [CGDisplayBounds(CGMainDisplayID())] : Array(bounds)
    }

    /// True when a node is a parked, non-interactable artefact rather than
    /// a real piece of UI: it has **zero size** AND sits outside every
    /// display — either at/below a display's bottom edge (the classic
    /// macOS hidden-menu park at `y == screen_height`) or off all display
    /// bounds entirely.
    ///
    /// Both halves are required. A zero-size node inside a visible window
    /// is a real (if collapsed) control and is kept, and a node with a real
    /// frame is kept wherever it sits — parking is not inferred from
    /// position alone. Nodes with no geometry at all are never parked:
    /// absence of a frame is not evidence.
    static func isParked(
        x: Double?, y: Double?, width: Double?, height: Double?,
        displays: [CGRect]
    ) -> Bool {
        guard let w = width, let h = height, w < 1, h < 1 else { return false }
        guard let x, let y else { return false }
        let point = CGPoint(x: x, y: y)
        // At or below the bottom edge of any display — the park signature.
        if displays.contains(where: { y >= $0.maxY - 0.5 && x >= $0.minX - 0.5 && x <= $0.maxX + 0.5 }) {
            return true
        }
        // Off every display entirely.
        return !displays.contains { $0.insetBy(dx: -0.5, dy: -0.5).contains(point) }
    }

    /// Flatten a raw tree into an ordered list of `FlatNode`s, dropping
    /// parked nodes. Children of a parked node are still traversed (and
    /// still keyed beneath it) so a temporarily zero-sized container does
    /// not shift the identity of everything below it.
    static func flatten(_ root: RawNode, displays: [CGRect]) -> [FlatNode] {
        var out: [FlatNode] = []

        func visit(_ node: RawNode, parentPath: String, siblingCounts: inout [String: Int]) {
            let segment = identitySegment(role: node.role,
                                          identifier: node.identifier,
                                          title: node.title)
            let bucketPath = "\(parentPath)/\(segment)"
            let index = siblingCounts[bucketPath, default: 0]
            siblingCounts[bucketPath] = index + 1

            if !isParked(x: node.x, y: node.y, width: node.width, height: node.height,
                         displays: displays) {
                out.append(FlatNode(
                    key: "\(bucketPath)[\(index)]",
                    bucketPath: bucketPath,
                    parentPath: parentPath,
                    role: node.role,
                    identifier: node.identifier,
                    title: node.title,
                    value: node.value,
                    x: node.x, y: node.y,
                    width: node.width, height: node.height,
                    index: index
                ))
            }

            var childCounts: [String: Int] = [:]
            // The child's parent path carries the parent's own index so
            // two same-identity parents don't merge their subtrees.
            let childParentPath = "\(bucketPath)[\(index)]"
            for child in node.children {
                visit(child, parentPath: childParentPath, siblingCounts: &childCounts)
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

    /// Diff two flattened snapshots.
    ///
    /// Matching is deliberately NOT by key. A key contains the node's
    /// sibling index, and an index is unstable: inserting one row at the
    /// top of a list of untitled rows shifts every later index, which would
    /// report the whole list as removed+added. Instead:
    ///
    ///   1. Group both sides into index-free identity buckets
    ///      (parent path + role + identifier/title).
    ///   2. Within a bucket, pair old and new nodes by NEAREST FRAME
    ///      (greedy, closest pair first) when both sides carry frames, and
    ///      only fall back to sibling index when they do not.
    ///   3. Rescue pass: a node whose *title* changed lands in a different
    ///      bucket and would otherwise read as removed+added. Any leftover
    ///      removed/added pair sharing parent path, role and frame (±1 pt)
    ///      is reported as one `changed` instead. Nodes with a stable
    ///      AXIdentifier never need this — their identity ignores the title.
    static func computeDiff(
        from a: [FlatNode],
        to b: [FlatNode],
        fromID: String,
        toID: String
    ) -> Diff {
        var unmatchedOld: [FlatNode] = []
        var unmatchedNew: [FlatNode] = []
        var pairs: [(old: FlatNode, new: FlatNode)] = []

        let oldBuckets = Dictionary(grouping: a, by: \.bucketPath)
        let newBuckets = Dictionary(grouping: b, by: \.bucketPath)

        for bucket in Set(oldBuckets.keys).union(newBuckets.keys) {
            let olds = oldBuckets[bucket] ?? []
            let news = newBuckets[bucket] ?? []
            let (matched, leftoverOld, leftoverNew) = pairWithinBucket(olds: olds, news: news)
            pairs.append(contentsOf: matched)
            unmatchedOld.append(contentsOf: leftoverOld)
            unmatchedNew.append(contentsOf: leftoverNew)
        }

        // Title-change rescue.
        var stillRemoved: [FlatNode] = []
        var claimedNew = Set<String>()
        for old in unmatchedOld {
            let hit = unmatchedNew.first { candidate in
                !claimedNew.contains(candidate.key)
                    && candidate.parentPath == old.parentPath
                    && candidate.role == old.role
                    && sameFrame(old, candidate)
            }
            if let hit {
                claimedNew.insert(hit.key)
                pairs.append((old, hit))
            } else {
                stillRemoved.append(old)
            }
        }
        let stillAdded = unmatchedNew.filter { !claimedNew.contains($0.key) }

        var changed: [ChangedNode] = []
        for pair in pairs {
            let oldN = pair.old, newN = pair.new
            var diffs: [String: String] = [:]
            if oldN.role != newN.role { diffs["role"] = "\(oldN.role ?? "nil") → \(newN.role ?? "nil")" }
            if oldN.title != newN.title { diffs["title"] = "\(oldN.title ?? "nil") → \(newN.title ?? "nil")" }
            if oldN.value != newN.value { diffs["value"] = "\(oldN.value ?? "nil") → \(newN.value ?? "nil")" }
            // Position / size: only flag if they moved more than 1pt (avoid
            // subpixel layout jitter noise).
            if let a1 = oldN.x, let b1 = newN.x, abs(a1 - b1) > 1.0 { diffs["x"] = "\(a1) → \(b1)" }
            if let a1 = oldN.y, let b1 = newN.y, abs(a1 - b1) > 1.0 { diffs["y"] = "\(a1) → \(b1)" }
            if let a1 = oldN.width, let b1 = newN.width, abs(a1 - b1) > 1.0 { diffs["width"] = "\(a1) → \(b1)" }
            if let a1 = oldN.height, let b1 = newN.height, abs(a1 - b1) > 1.0 { diffs["height"] = "\(a1) → \(b1)" }
            if !diffs.isEmpty {
                changed.append(.init(key: newN.key, role: newN.role, title: newN.title, changes: diffs))
            }
        }

        return Diff(
            fromSnapshotID: fromID,
            toSnapshotID: toID,
            added: stillAdded.map(\.snapshot),
            removed: stillRemoved.map(\.snapshot),
            changed: changed
        )
    }

    /// Pair the members of one identity bucket. Frames first (greedy
    /// closest-pair), sibling index only when a frame is missing.
    private static func pairWithinBucket(
        olds: [FlatNode], news: [FlatNode]
    ) -> (matched: [(old: FlatNode, new: FlatNode)], leftoverOld: [FlatNode], leftoverNew: [FlatNode]) {
        if olds.isEmpty || news.isEmpty { return ([], olds, news) }

        var matched: [(old: FlatNode, new: FlatNode)] = []
        var usedOld = Set<Int>()
        var usedNew = Set<Int>()

        let framesUsable = olds.allSatisfy(\.hasFrame) && news.allSatisfy(\.hasFrame)
        if framesUsable {
            var candidates: [(distance: Double, oldIndex: Int, newIndex: Int)] = []
            for (i, old) in olds.enumerated() {
                for (j, new) in news.enumerated() {
                    candidates.append((frameDistance(old, new), i, j))
                }
            }
            // Ties broken by sibling-index proximity so equal-frame nodes
            // (rare, but possible for stacked zero-area rows) stay in order.
            candidates.sort {
                $0.distance == $1.distance
                    ? abs(olds[$0.oldIndex].index - news[$0.newIndex].index)
                        < abs(olds[$1.oldIndex].index - news[$1.newIndex].index)
                    : $0.distance < $1.distance
            }
            for candidate in candidates {
                if usedOld.contains(candidate.oldIndex) || usedNew.contains(candidate.newIndex) { continue }
                usedOld.insert(candidate.oldIndex)
                usedNew.insert(candidate.newIndex)
                matched.append((olds[candidate.oldIndex], news[candidate.newIndex]))
            }
        } else {
            // No usable geometry — fall back to sibling index.
            let newByIndex = Dictionary(news.enumerated().map { ($1.index, $0) },
                                        uniquingKeysWith: { first, _ in first })
            for (i, old) in olds.enumerated() {
                guard let j = newByIndex[old.index], !usedNew.contains(j) else { continue }
                usedOld.insert(i)
                usedNew.insert(j)
                matched.append((old, news[j]))
            }
        }

        let leftoverOld = olds.enumerated().filter { !usedOld.contains($0.offset) }.map(\.element)
        let leftoverNew = news.enumerated().filter { !usedNew.contains($0.offset) }.map(\.element)
        return (matched, leftoverOld, leftoverNew)
    }

    private static func frameDistance(_ lhs: FlatNode, _ rhs: FlatNode) -> Double {
        abs((lhs.x ?? 0) - (rhs.x ?? 0)) + abs((lhs.y ?? 0) - (rhs.y ?? 0))
            + abs((lhs.width ?? 0) - (rhs.width ?? 0)) + abs((lhs.height ?? 0) - (rhs.height ?? 0))
    }

    private static func sameFrame(_ lhs: FlatNode, _ rhs: FlatNode) -> Bool {
        guard lhs.hasFrame, rhs.hasFrame else { return false }
        return frameDistance(lhs, rhs) <= 1.0
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
