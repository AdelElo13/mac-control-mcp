import Foundation
import ApplicationServices

/// One level of an element's position in its application's accessibility
/// tree, counted from the application root.
///
/// `index` is the child's ordinal among ALL of its parent's children
/// (AXChildren followed by AXSheets — the exact order every walk in this
/// server descends in), not among same-role siblings. Same-role indexing
/// would need every sibling's `AXRole` before descending, i.e. one extra
/// IPC round trip per sibling on every walk, which would undo the
/// batched-attribute work of v0.8.3. `role` and `identifier` are carried
/// alongside the ordinal precisely so resolution can repair itself when
/// the ordinal drifts (see `AXPath.resolve`).
struct AXPathComponent: Sendable, Hashable {
    let role: String
    let index: Int
    /// `AXIdentifier` when the app publishes one. Stable across
    /// relaunches and immune to sibling reordering, so it is the
    /// strongest signal we have — and free, since `AXAttributeBatch`
    /// already fetches it.
    let identifier: String?

    init(role: String?, index: Int, identifier: String?) {
        self.role = role ?? "AXUnknown"
        self.index = index
        self.identifier = (identifier?.isEmpty == false) ? identifier : nil
    }
}

/// v0.9 (C-5 / B-10) — content-addressed element handles.
///
/// `ElementCache` used to mint 8 random bytes per stored element, so two
/// identical `find_elements` calls in the same session returned different
/// ids for the same control (B-10) while `get_ui_tree`'s description
/// claimed "stable element IDs". Agents could not dedupe, cache, or
/// correlate handles across calls, and `ax_snapshot_diff` results could
/// never be joined to actionable handles.
///
/// An id is now a deterministic hash of (pid, AX path from the app root).
/// The same element yields the same id on every call and in every
/// session for as long as the app keeps the same pid and tree shape, and
/// two different elements yield different ids. The `el_` prefix is
/// unchanged, so existing clients keep working.
enum AXPath {
    /// Canonical, human-readable identity string that gets hashed. Kept
    /// separate from the hash so it is unit-testable and so a future
    /// debug field can surface it verbatim.
    static func identity(pid: pid_t, path: [AXPathComponent]) -> String {
        var out = "pid:\(pid)"
        for component in path {
            out += "/\(component.role)[\(component.index)]"
            if let identifier = component.identifier { out += "#\(identifier)" }
        }
        return out
    }

    /// Element id for a (pid, path) pair: `el_` + 16 hex chars.
    static func identifier(pid: pid_t, path: [AXPathComponent]) -> String {
        "el_" + String(format: "%016lx", fnv1a64(identity(pid: pid, path: path)))
    }

    /// FNV-1a, 64-bit. Deterministic across processes and OS releases
    /// (unlike Swift's `Hasher`, which is seeded per process — using it
    /// here would silently break cross-session stability).
    static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    /// Extend `parentPath` with the component describing the child at
    /// `index` with the given role/identifier.
    static func appending(
        _ parentPath: [AXPathComponent],
        role: String?,
        index: Int,
        identifier: String?
    ) -> [AXPathComponent] {
        parentPath + [AXPathComponent(role: role, index: index, identifier: identifier)]
    }

    // MARK: - Resolution

    /// Walk a stored path back down from the application root. Used when
    /// a cached `AXUIElement` has gone dead (the app rebuilt that part of
    /// its tree) but the id is still meaningful.
    ///
    /// Repair strategy per level, cheapest first:
    ///   1. the recorded ordinal, when its role still matches (and its
    ///      identifier too, when the path carries one);
    ///   2. the single child whose `AXIdentifier` matches;
    ///   3. the child at the recorded ordinal *among same-role children*.
    /// Anything else fails the whole resolution — a wrong element is far
    /// worse than no element.
    static func resolve(path: [AXPathComponent], pid: pid_t) -> AXUIElement? {
        var current = AXUIElementCreateApplication(pid)
        for component in path {
            let children = childElements(of: current)
            guard let next = match(component: component, in: children) else { return nil }
            current = next
        }
        return current
    }

    static func match(component: AXPathComponent, in children: [AXUIElement]) -> AXUIElement? {
        func role(_ element: AXUIElement) -> String? {
            copyString(element, "AXRole")
        }
        func identifier(_ element: AXUIElement) -> String? {
            let value = copyString(element, "AXIdentifier")
            return (value?.isEmpty == false) ? value : nil
        }

        if component.index >= 0, component.index < children.count {
            let candidate = children[component.index]
            if role(candidate) == component.role,
               component.identifier == nil || identifier(candidate) == component.identifier {
                return candidate
            }
        }
        if let wanted = component.identifier {
            let byIdentifier = children.filter { identifier($0) == wanted && role($0) == component.role }
            if byIdentifier.count == 1 { return byIdentifier[0] }
        }
        let sameRole = children.filter { role($0) == component.role }
        if component.index >= 0, component.index < sameRole.count {
            return sameRole[component.index]
        }
        return nil
    }

    /// Is this handle still backed by a live element? A dead
    /// `AXUIElement` fails every attribute copy with
    /// `kAXErrorInvalidUIElement`.
    static func isAlive(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &value)
        return status != .invalidUIElement && status != .cannotComplete
    }

    /// AXChildren followed by AXSheets — the same order the tree walks
    /// use, so ordinals recorded during a walk mean the same thing here.
    static func childElements(of element: AXUIElement) -> [AXUIElement] {
        copyElements(element, "AXChildren") + copyElements(element, "AXSheets")
    }

    /// The element's ancestors, nearest first, bounded by `limit`.
    /// Used by `element_at_point` to show which container was hit and to
    /// reconstruct a path for a hit-tested element.
    static func ancestors(of element: AXUIElement, limit: Int = 32) -> [AXUIElement] {
        var chain: [AXUIElement] = []
        var current = element
        var seen = Set<AXKey>([AXKey(element: element)])
        while chain.count < limit {
            guard let parent = copyElement(current, "AXParent") else { break }
            guard seen.insert(AXKey(element: parent)).inserted else { break }
            chain.append(parent)
            current = parent
        }
        return chain
    }

    /// Reconstruct the path of an element we only hold a handle to (the
    /// `element_at_point` case) by walking up to the application root and
    /// recording each ordinal on the way back down.
    static func upwardPath(of element: AXUIElement, limit: Int = 32) -> [AXPathComponent]? {
        let chain = ancestors(of: element, limit: limit)
        guard let root = chain.last, copyString(root, "AXRole") == (kAXApplicationRole as String) else {
            // Without a reachable application root the ordinals would be
            // relative to an unknown anchor — refuse rather than mint an
            // id that cannot be resolved later.
            return nil
        }
        // chain is [parent, grandparent, ..., application]. Pair each
        // element with its parent, from the root downwards.
        let descending = ([element] + chain).reversed()  // [application, ..., element]
        var path: [AXPathComponent] = []
        var iterator = Array(descending).makeIterator()
        guard var parent = iterator.next() else { return nil }
        while let child = iterator.next() {
            let siblings = childElements(of: parent)
            guard let index = siblings.firstIndex(where: { CFEqual($0, child) }) else { return nil }
            path.append(
                AXPathComponent(
                    role: copyString(child, "AXRole"),
                    index: index,
                    identifier: copyString(child, "AXIdentifier")
                )
            )
            parent = child
        }
        return path
    }

    // MARK: - Small AX accessors (kept local so this file has no actor hop)

    static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        return AXAttributeBatch.string(value)
    }

    static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func copyElements(_ element: AXUIElement, _ attribute: String) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return [] }
        return AXAttributeBatch.elements(value)
    }
}
