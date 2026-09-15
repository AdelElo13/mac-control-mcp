import Foundation
import CoreGraphics

/// v0.9 (C-9 / B-11) — payload budget controls for the AX read tools.
///
/// Measured before this: one `get_ui_tree` of Finder at max_depth 12 was
/// 327 KB / 1681 nodes ≈ 80k tokens — paid on every agent turn that
/// wants to "look at the app". The knobs that existed (`max_depth`,
/// `node_cap`) traded *correctness* for size: they cut the tree off
/// rather than making it less verbose. These four trade verbosity for
/// size instead:
///
///   * `fields`            — which per-node keys to emit at all;
///   * `interactive_only`  — keep actionable controls (plus the
///                           ancestors needed to keep the tree connected);
///   * `viewport_only`     — drop nodes whose frame lies outside the
///                           app's on-screen window bounds;
///   * `max_bytes`         — soft cap; emission stops and `truncated`
///                           flips to true.
///
/// Every response also reports `bytes`, `max_depth_used`,
/// `nodes_visited` and `truncated`, so a caller can see what a cheaper
/// call would cost and whether it got the whole picture. All defaults
/// are the pre-v0.9 behaviour: no filtering, no cap.
enum AXPayload {

    // MARK: - fields

    /// Per-node keys `get_ui_tree` emits.
    static let treeFields: [String] = ["id", "role", "title", "value", "position", "size", "depth", "children"]

    /// Per-element keys the search tools emit.
    static let elementFields: [String] = ["id", "role", "title", "value", "position", "size", "depth"]

    /// Resolve a `fields` argument. `nil` means "every field" (the
    /// default). Names the caller got wrong come back in `unknown` so a
    /// typo isn't silently an empty node.
    static func resolveFields(_ raw: JSONValue?, known: [String]) -> (fields: Set<String>?, unknown: [String]) {
        guard let raw, raw != .null else { return (nil, []) }
        guard let array = raw.arrayValue else { return (nil, []) }
        let requested = array.compactMap { $0.stringValue }
        guard !requested.isEmpty else { return (nil, []) }
        let knownSet = Set(known)
        let unknown = requested.filter { !knownSet.contains($0) }
        return (Set(requested).intersection(knownSet), unknown)
    }

    /// Drop every key the caller didn't ask for. `nil` fields → unchanged.
    static func project(_ object: [String: JSONValue], fields: Set<String>?) -> [String: JSONValue] {
        guard let fields else { return object }
        return object.filter { fields.contains($0.key) }
    }

    // MARK: - interactive filter

    /// Roles an agent can actually act on. Same whitelist
    /// `list_elements` has always used (single source of truth now).
    static let interactiveRoles: Set<String> = [
        "AXButton",
        "AXCheckBox",
        "AXComboBox",
        "AXDecrementor",
        "AXDisclosureTriangle",
        "AXIncrementor",
        "AXLevelIndicator",
        "AXLink",
        "AXMenuButton",
        "AXPopUpButton",
        "AXRadioButton",
        "AXSecureTextField",
        "AXSlider",
        "AXStepper",
        "AXSwitch",
        "AXTextArea",
        "AXTextField"
    ]

    static func isInteractive(role: String?) -> Bool {
        interactiveRoles.contains(role ?? "AXUnknown")
    }

    // MARK: - viewport filter

    /// Is this frame on screen, i.e. does it intersect any of the app's
    /// window rects? Nodes with no geometry are KEPT — absent geometry is
    /// not evidence of being off-screen, and dropping them would silently
    /// hide controls that simply don't publish AXPosition.
    ///
    /// Zero-sized frames are treated as points (macOS parks hidden menu
    /// items at `(0, screen_height)` with size `0×0`; those fall outside
    /// every window rect and are correctly dropped).
    static func isInViewport(frame: CGRect?, windows: [CGRect]) -> Bool {
        guard let frame else { return true }
        guard !windows.isEmpty else { return true }
        for window in windows {
            if window.intersects(frame) { return true }
            if frame.width == 0 || frame.height == 0, window.contains(frame.origin) { return true }
        }
        return false
    }

    /// v0.10 B1/B2: only a finite, nonempty frame proves a subtree lies
    /// outside every clip. Unknown geometry must not hide descendants.
    static func shouldPrune(frame: CGRect?, clips: [CGRect]) -> Bool {
        guard let frame, !frame.isEmpty, !frame.isNull, !frame.isInfinite,
              frame.origin.x.isFinite, frame.origin.y.isFinite,
              frame.width.isFinite, frame.height.isFinite, !clips.isEmpty else { return false }
        return !clips.contains { $0.intersects(frame) }
    }

    // MARK: - tree shaping

    /// The minimum a shaper needs to know about a node.
    struct ShapeNode: Sendable {
        let role: String?
        let frame: CGRect?
        let childIndices: [Int]

        init(role: String?, frame: CGRect?, childIndices: [Int]) {
            self.role = role
            self.frame = frame
            self.childIndices = childIndices
        }
    }

    /// Which original indices survive `interactive_only` / `viewport_only`,
    /// in preorder.
    ///
    /// A node is kept when it passes the filters OR when it is an
    /// ancestor of a node that does — otherwise the surviving controls
    /// would be orphaned and the `children` indices meaningless. Because
    /// ancestors are always kept, every kept node's parent is kept too,
    /// so `remap` can rewrite child indices without further repair.
    static func keptIndices(
        nodes: [ShapeNode],
        interactiveOnly: Bool,
        viewportOnly: Bool,
        windows: [CGRect]
    ) -> [Int] {
        guard interactiveOnly || viewportOnly else { return Array(nodes.indices) }

        var parent = [Int](repeating: -1, count: nodes.count)
        for (index, node) in nodes.enumerated() {
            for child in node.childIndices where child >= 0 && child < nodes.count {
                parent[child] = index
            }
        }

        var keep = [Bool](repeating: false, count: nodes.count)
        for (index, node) in nodes.enumerated() {
            let passesRole = !interactiveOnly || isInteractive(role: node.role)
            let passesViewport = !viewportOnly || isInViewport(frame: node.frame, windows: windows)
            guard passesRole && passesViewport else { continue }
            keep[index] = true
            var ancestor = parent[index]
            while ancestor >= 0, !keep[ancestor] {
                keep[ancestor] = true
                ancestor = parent[ancestor]
            }
        }
        // The root stays whenever anything at all survives, so the result
        // is still a single connected tree.
        if !nodes.isEmpty, keep.contains(true) { keep[0] = true }
        return nodes.indices.filter { keep[$0] }
    }

    /// Rewrite each kept node's child indices into the compacted array.
    static func remapChildren(nodes: [ShapeNode], kept: [Int]) -> [[Int]] {
        var newIndex = [Int: Int]()
        for (position, original) in kept.enumerated() { newIndex[original] = position }
        return kept.map { original in
            nodes[original].childIndices.compactMap { newIndex[$0] }
        }
    }

    // MARK: - byte budget

    /// Encoded JSON size in bytes. Uses the same encoder the transport
    /// uses, so the number an agent sees is the number it paid.
    static func encodedSize(_ value: JSONValue) -> Int {
        (try? JSONEncoder().encode(value))?.count ?? 0
    }

    /// Append encoded items while they fit in `maxBytes`.
    ///
    /// `nil` maxBytes → everything is emitted (the default; unchanged
    /// behaviour). Returns the items that fit plus whether anything was
    /// dropped. The cap is soft and counts item bytes only — the
    /// surrounding envelope is small and constant, and a hard cap would
    /// risk emitting zero nodes for a legitimate call.
    static func applyByteBudget(_ items: [JSONValue], maxBytes: Int?) -> (items: [JSONValue], truncated: Bool) {
        guard let maxBytes, maxBytes > 0 else { return (items, false) }
        var total = 0
        var kept: [JSONValue] = []
        kept.reserveCapacity(items.count)
        for item in items {
            let size = encodedSize(item) + 1  // + the separating comma
            if total + size > maxBytes { return (kept, true) }
            total += size
            kept.append(item)
        }
        return (kept, false)
    }

    /// Parse `max_bytes`. Values <= 0 are treated as "no cap" rather than
    /// as "emit nothing".
    static func resolveMaxBytes(_ raw: JSONValue?) -> Int? {
        guard let value = raw?.intValue, value > 0 else { return nil }
        return value
    }

    /// Parse a boolean flag that defaults to false, tolerating the
    /// string forms MCP clients sometimes send.
    static func flag(_ raw: JSONValue?) -> Bool {
        if let bool = raw?.boolValue { return bool }
        guard let string = raw?.stringValue?.lowercased() else { return false }
        return string == "true" || string == "1" || string == "yes"
    }
}
