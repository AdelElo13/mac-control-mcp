import Foundation
import ApplicationServices
import AppKit
import CryptoKit

/// What an element looked like when its path was recorded. Used to
/// verify — not merely guess — that a re-resolved element is the same
/// control (v0.9 C-5, review fix 1).
///
/// Every field here is already fetched by `AXAttributeBatch` in the one
/// batched round trip a walk makes per node, so capturing a fingerprint
/// costs nothing extra. `AXValue` is deliberately NOT part of it: a text
/// field's value changes constantly and would turn every edit into a
/// stale handle.
struct AXFingerprint: Sendable, Hashable {
    let role: String
    let identifier: String?
    let title: String?
    let subrole: String?

    init(role: String?, identifier: String?, title: String?, subrole: String?) {
        self.role = role ?? "AXUnknown"
        self.identifier = (identifier?.isEmpty == false) ? identifier : nil
        self.title = (title?.isEmpty == false) ? title : nil
        self.subrole = (subrole?.isEmpty == false) ? subrole : nil
    }

    /// Does this candidate satisfy the identity recorded in `component`?
    ///
    /// Role must always match. Beyond that, `AXIdentifier` wins when the
    /// recorded path has one (apps publish it precisely so it is stable);
    /// otherwise title AND subrole must both match, including "both
    /// absent". An ordinal on its own is never enough — that was the
    /// review's HIGH finding: inserting a sibling silently shifted a
    /// stale id onto a different control.
    func matches(_ component: AXPathComponent) -> Bool {
        guard role == component.role else { return false }
        if let wanted = component.identifier {
            return identifier == wanted
        }
        // A candidate that has an identifier where the recorded path had
        // none is a different element (the app started publishing ids, or
        // this is simply another control).
        guard identifier == nil else { return false }
        return title == component.title && subrole == component.subrole
    }
}

/// One level of an element's position in its application's accessibility
/// tree, counted from the application root.
///
/// `index` is the child's ordinal among ALL of its parent's children
/// (AXChildren followed by AXSheets — the exact order every walk in this
/// server descends in), not among same-role siblings. Same-role indexing
/// would need every sibling's `AXRole` before descending, i.e. one extra
/// IPC round trip per sibling on every walk, which would undo the
/// batched-attribute work of v0.8.3.
///
/// The ordinal is only ever a *hint* for where to look: resolution
/// always verifies the fingerprint (role + identifier, else title +
/// subrole) and falls back to searching siblings by fingerprint when the
/// ordinal has drifted.
struct AXPathComponent: Sendable, Hashable {
    let role: String
    let index: Int
    /// `AXIdentifier` when the app publishes one. Stable across
    /// relaunches and immune to sibling reordering, so it is the
    /// strongest signal we have — and free, since `AXAttributeBatch`
    /// already fetches it.
    let identifier: String?
    /// Fingerprint fields. Deliberately NOT part of the id hash: a
    /// button whose label changes is still the same button, and an id
    /// that changed with its title would not be stable at all.
    let title: String?
    let subrole: String?

    init(role: String?, index: Int, identifier: String?, title: String? = nil, subrole: String? = nil) {
        self.role = role ?? "AXUnknown"
        self.index = index
        self.identifier = (identifier?.isEmpty == false) ? identifier : nil
        self.title = (title?.isEmpty == false) ? title : nil
        self.subrole = (subrole?.isEmpty == false) ? subrole : nil
    }

    var fingerprint: AXFingerprint {
        AXFingerprint(role: role, identifier: identifier, title: title, subrole: subrole)
    }
}

/// Identity of the process an element handle belongs to (v0.9 C-5,
/// review fix 2).
///
/// pids are recycled. Without this, a cached id minted against Finder
/// pid 742 would keep resolving after 742 died and some unrelated
/// process inherited the number — quietly acting on a different app.
/// The boot-relative process start time makes a recycled pid a
/// different identity; the bundle id is a cheap secondary check.
struct ProcessIdentity: Sendable, Equatable {
    /// `kinfo_proc.kp_proc.p_starttime`, seconds since the epoch.
    let startTime: TimeInterval?
    let bundleID: String?

    static func current(pid: pid_t) -> ProcessIdentity {
        ProcessIdentity(
            startTime: startTime(of: pid),
            bundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        )
    }

    /// Same sysctl path `PermissionContext` uses for process ancestry.
    static func startTime(of pid: pid_t) -> TimeInterval? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, u_int(mib.count), &info, &size, nil, 0) == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        guard started.tv_sec > 0 else { return nil }
        return TimeInterval(started.tv_sec) + TimeInterval(started.tv_usec) / 1_000_000
    }

    /// Is `other` the same running process this identity was captured
    /// from? Unknown-vs-unknown start times fall back to the bundle id;
    /// a start time that is known on one side and absent on the other
    /// means the process is gone — not the same.
    func matches(_ other: ProcessIdentity) -> Bool {
        if let mine = startTime, let theirs = other.startTime {
            // Same-second granularity is not enough to identify a
            // process; compare the full microsecond timestamp.
            guard mine == theirs else { return false }
        } else if startTime != nil || other.startTime != nil {
            return false
        }
        guard let mineBundle = bundleID, let theirsBundle = other.bundleID else { return true }
        return mineBundle == theirsBundle
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
    /// Canonical identity string that gets hashed. Kept separate from the
    /// hash so it is unit-testable and so a future debug field can surface
    /// it verbatim.
    ///
    /// Only role / ordinal / identifier take part: fingerprint fields
    /// (title, subrole) must NOT change the id, or a relabelled button
    /// would look like a new element.
    ///
    /// ENCODING (v2 — Codex review 3, BLOCKER). The v1 form was a plain
    /// concatenation, `pid:742/AXWindow[0]/AXButton[3]#save-btn`. An app
    /// controls its own `AXIdentifier` strings, so one component with the
    /// identifier `x/AXButton[1]#y` produced byte-for-byte the same string
    /// as two components `#x` then `#y` — a structural collision an app
    /// could mint on purpose, handing one element id to two controls.
    ///
    /// v2 is netstring-style: the component count is pinned up front and
    /// every variable-length field is prefixed with its UTF-8 byte count,
    /// so the string parses back to exactly one path and no crafted
    /// identifier can forge another. Fixed-width fields (pid, ordinals) are
    /// `:`-delimited; an absent identifier is the sentinel `-`, which no
    /// length-prefixed field can ever spell (a literal "-" identifier
    /// encodes as `1:-`).
    ///
    ///     axpath2:742:2:8:AXWindow:0:-:8:AXButton:3:8:save-btn
    static func identity(pid: pid_t, path: [AXPathComponent]) -> String {
        var out = "axpath2:\(pid):\(path.count)"
        for component in path {
            out += ":" + lengthPrefixed(component.role)
            out += ":\(component.index)"
            out += ":" + (component.identifier.map(lengthPrefixed) ?? "-")
        }
        return out
    }

    /// `<utf8 byte count>:<field>` — the netstring framing that makes the
    /// canonical form unforgeable.
    static func lengthPrefixed(_ field: String) -> String {
        "\(field.utf8.count):\(field)"
    }

    /// Element id for a (pid, path) pair: `el_` + 32 lowercase hex chars.
    ///
    /// SHA-256 truncated to 128 bits (Codex review 3). The previous
    /// FNV-1a-64 is a non-cryptographic hash: even with a collision-proof
    /// canonical string, an app could brute-force a second path colliding
    /// into the same 64-bit id in seconds. 128 bits of a cryptographic
    /// digest makes that infeasible, and is still short enough to read.
    static func identifier(pid: pid_t, path: [AXPathComponent]) -> String {
        "el_" + digest128(identity(pid: pid, path: path))
    }

    /// SHA-256 of `string`'s UTF-8, truncated to its first 128 bits and
    /// rendered as 32 lowercase hex chars. Deterministic across processes,
    /// machines and OS releases (unlike Swift's `Hasher`, which is seeded
    /// per process — using it here would silently break cross-session
    /// stability).
    static func digest128(_ string: String) -> String {
        let digest = SHA256.hash(data: Data(string.utf8))
        return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    /// Extend `parentPath` with the component describing the child at
    /// `index`, capturing its fingerprint at the same time.
    static func appending(
        _ parentPath: [AXPathComponent],
        role: String?,
        index: Int,
        identifier: String?,
        title: String? = nil,
        subrole: String? = nil
    ) -> [AXPathComponent] {
        parentPath + [
            AXPathComponent(role: role, index: index, identifier: identifier, title: title, subrole: subrole)
        ]
    }

    // MARK: - Resolution

    /// Which sibling is the element `component` describes?
    ///
    /// Pure, so the drift cases are unit-testable without a live AX tree.
    ///   1. the recorded ordinal, IF its fingerprint still matches;
    ///   2. otherwise the single sibling whose fingerprint matches.
    /// Several equally-matching siblings, or none, → `nil`. Refusing is
    /// the whole point: acting on the wrong control is far worse than
    /// telling the caller its handle went stale.
    static func resolveIndex(component: AXPathComponent, among siblings: [AXFingerprint]) -> Int? {
        if component.index >= 0, component.index < siblings.count,
           siblings[component.index].matches(component) {
            return component.index
        }
        let matching = siblings.indices.filter { siblings[$0].matches(component) }
        return matching.count == 1 ? matching[0] : nil
    }

    /// Walk a stored path back down from the application root, verifying
    /// the fingerprint at EVERY level. Used when a cached `AXUIElement`
    /// has gone dead (the app rebuilt that part of its tree) but the id
    /// is still meaningful. Returns nil — never a best guess — when any
    /// level fails to match.
    static func resolve(path: [AXPathComponent], pid: pid_t) -> AXUIElement? {
        var current = AXUIElementCreateApplication(pid)
        for component in path {
            let children = childElements(of: current)
            let fingerprints = children.map { fingerprint(of: $0) }
            guard let index = resolveIndex(component: component, among: fingerprints) else { return nil }
            current = children[index]
        }
        return current
    }

    /// One batched round trip per element (role, title, identifier and
    /// subrole all come back together).
    static func fingerprint(of element: AXUIElement) -> AXFingerprint {
        let attrs = AXAttributeBatch.fetch(element, includeChildren: false)
        return AXFingerprint(
            role: attrs.role,
            identifier: attrs.identifier,
            title: attrs.title,
            subrole: attrs.subrole
        )
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
    /// recording each ordinal — and fingerprint — on the way back down.
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
            let attrs = AXAttributeBatch.fetch(child, includeChildren: false)
            path.append(
                AXPathComponent(
                    role: attrs.role,
                    index: index,
                    identifier: attrs.identifier,
                    title: attrs.title,
                    subrole: attrs.subrole
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
