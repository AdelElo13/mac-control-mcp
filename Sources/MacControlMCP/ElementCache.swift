import Foundation
import ApplicationServices

/// Stable identifiers for AXUIElement references across MCP tool calls.
///
/// The MCP server process is persistent for the lifetime of the client
/// connection, so we can hand out short opaque IDs (e.g. "el_3f2a") when a
/// tree/query tool returns elements, and resolve them in later calls without
/// re-walking the accessibility tree.
///
/// Entries expire after `ttl` seconds. Callers are responsible for refreshing
/// their IDs if they hold them across long delays.
actor ElementCache {
    struct Entry {
        let element: AXUIElement
        let pid: pid_t
        /// AX path from the application root, when the producer knew it
        /// (every tree walk / search does). Two jobs:
        ///   1. it makes the id content-addressed (same element → same
        ///      id across calls and sessions — v0.9 C-5 / B-10);
        ///   2. it lets `resolveLive` re-walk the path when the cached
        ///      handle has gone dead.
        let path: [AXPathComponent]?
        /// Identity of the owning process at capture time. pids are
        /// recycled; without this a stale id could resolve against a
        /// completely unrelated process that inherited the number
        /// (v0.9 C-5, review fix 2).
        let identity: ProcessIdentity
        var lastAccess: Date
    }

    /// Outcome of resolving an element id. Distinguishing "never heard
    /// of it" from "the element it named is gone" is the whole point:
    /// the first is a caller bug, the second means re-run a search.
    enum Resolution: Sendable {
        case resolved(AXUIElement)
        /// Unknown id, or evicted/expired from the cache.
        case unknown
        /// The id was ours, but the element behind it no longer exists
        /// (or its process was replaced). Never a guess at a
        /// replacement.
        case stale(String)
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval
    /// Hard cap on live entries (also get_ui_tree's node cap).
    nonisolated let maxEntries: Int

    init(ttl: TimeInterval = 300, maxEntries: Int = 2_000) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    /// Store `element` and return a new opaque ID. If the random ID happens
    /// to collide with an existing entry we retry up to 8 times before
    /// giving up — with an 8-byte ID (64 bits) collisions are astronomically
    /// rare, but we retry anyway to avoid silently overwriting live state.
    /// v0.9 (C-5 / B-10): when `path` is supplied the id is a
    /// deterministic hash of (pid, path) — the same element gets the same
    /// id on every call and in every session, so agents can dedupe,
    /// cache, and correlate handles. Re-storing an element under an id it
    /// already has simply refreshes the entry. Producers that genuinely
    /// have no path (e.g. the system-wide focused element) still get a
    /// random id, exactly as before.
    func store(
        _ element: AXUIElement,
        pid: pid_t,
        path: [AXPathComponent]? = nil,
        identity: ProcessIdentity? = nil
    ) -> String {
        evictExpired()
        evictIfOverCapacity()
        return insert(
            element,
            pid: pid,
            path: path,
            identity: identity ?? ProcessIdentity.current(pid: pid),
            now: Date()
        )
    }

    /// Store a batch of elements (e.g. every node of a `get_ui_tree` walk)
    /// in ONE actor hop, running expiry/capacity eviction once for the
    /// whole batch instead of once per element.
    ///
    /// PERF (v0.8.3): `get_ui_tree` used to call `store` per node — one
    /// actor hop plus an O(entries) `evictExpired` filter per node, and
    /// once the cache was full an O(n log n) LRU sort per node. For a
    /// 422-node Chrome tree against a warm (full) cache that was the
    /// dominant cost of the tool, far above the AX walk itself.
    ///
    /// Invariants:
    ///   - the cache never holds more than `maxEntries` entries afterwards;
    ///   - the result is index-aligned with `elements`;
    ///   - every non-nil ID resolves immediately afterwards (a batch never
    ///     evicts its own entries — older entries go first);
    ///   - when the batch alone exceeds `maxEntries`, only the FIRST
    ///     `maxEntries` elements are stored and the rest get `nil`. First,
    ///     not newest: callers pass tree walks in preorder, so the head of
    ///     the batch is the root / windows — the ids worth keeping. A nil
    ///     is returned instead of an id that would already be dangling.
    ///
    /// get_ui_tree avoids the nil case entirely by capping its walk at
    /// `maxEntries` nodes.
    func storeMany(_ elements: [AXUIElement], pid: pid_t) -> [String?] {
        storeMany(withPaths: elements.map { ($0, nil) }, pid: pid)
    }

    /// Path-carrying variant — `get_ui_tree` and the search tools use it
    /// so every returned id is content-addressed (C-5).
    func storeMany(withPaths elements: [(AXUIElement, [AXPathComponent]?)], pid: pid_t) -> [String?] {
        guard !elements.isEmpty else { return [] }
        evictExpired()
        let storable = min(elements.count, maxEntries)
        let overflow = entries.count + storable - maxEntries
        if overflow > 0 {
            evictOldest(count: min(overflow, entries.count))
        }
        let now = Date()
        // One identity lookup for the whole batch — they all share a pid.
        let identity = ProcessIdentity.current(pid: pid)
        return elements.enumerated().map { index, entry in
            index < storable
                ? insert(entry.0, pid: pid, path: entry.1, identity: identity, now: now)
                : nil
        }
    }

    private func insert(
        _ element: AXUIElement,
        pid: pid_t,
        path: [AXPathComponent]?,
        identity: ProcessIdentity,
        now: Date
    ) -> String {
        if let path {
            // Content-addressed: deterministic, so re-storing the same
            // element refreshes its entry instead of minting a twin.
            let id = AXPath.identifier(pid: pid, path: path)
            entries[id] = Entry(element: element, pid: pid, path: path, identity: identity, lastAccess: now)
            return id
        }
        for _ in 0..<8 {
            let id = Self.makeID()
            if entries[id] == nil {
                entries[id] = Entry(element: element, pid: pid, path: nil, identity: identity, lastAccess: now)
                return id
            }
        }
        // Extremely unlikely path. Fall back to a UUID-based ID so we
        // never silently overwrite an existing entry.
        let fallback = "el_\(UUID().uuidString.prefix(16).lowercased().replacingOccurrences(of: "-", with: ""))"
        entries[fallback] = Entry(element: element, pid: pid, path: nil, identity: identity, lastAccess: now)
        return fallback
    }

    /// Resolve an ID to its element. On success, refreshes lastAccess so the
    /// entry is treated as hot by the LRU eviction policy. Returns nil if
    /// unknown or expired.
    func resolve(_ id: String) -> AXUIElement? {
        guard var entry = entries[id] else { return nil }
        if Date().timeIntervalSince(entry.lastAccess) > ttl {
            entries.removeValue(forKey: id)
            return nil
        }
        entry.lastAccess = Date()
        entries[id] = entry
        return entry.element
    }

    /// Resolve an ID to a LIVE element (v0.9 C-5).
    ///
    /// `resolve` hands back whatever handle was stored, even if the app
    /// has since rebuilt that part of its tree and the handle is dead —
    /// every subsequent AX call then fails with
    /// `kAXErrorInvalidUIElement` and the agent is told "unknown
    /// element", which is wrong: the id is fine, the handle is stale.
    /// This variant checks liveness and, when the handle is dead and we
    /// recorded a path, re-walks that path from the application root and
    /// caches the repaired handle under the same id.
    /// Repair is strictly verified (review fixes 1 + 2):
    ///   * the owning process must still be the same process — a
    ///     recycled pid is `stale`, never a silent retarget;
    ///   * every level of the re-walked path must match the fingerprint
    ///     captured at store time, so inserting a sibling can never
    ///     shift a handle onto a neighbouring control;
    ///   * a repaired element is written back ONLY after that full
    ///     verification; otherwise the entry is dropped.
    func resolveLive(_ id: String) -> Resolution {
        guard let element = resolve(id) else { return .unknown }
        guard let entry = entries[id] else { return .unknown }

        let identityNow = ProcessIdentity.current(pid: entry.pid)
        guard entry.identity.matches(identityNow) else {
            entries.removeValue(forKey: id)
            return .stale(
                "pid \(entry.pid) is no longer the process this element came from (the pid was reused or the app restarted)"
            )
        }

        if AXPath.isAlive(element) { return .resolved(element) }

        guard let path = entry.path else {
            entries.removeValue(forKey: id)
            return .stale("the element is gone and no AX path was recorded for it")
        }
        guard let repaired = AXPath.resolve(path: path, pid: entry.pid) else {
            entries.removeValue(forKey: id)
            return .stale("the element is gone and its AX path no longer matches any element in the app")
        }
        entries[id] = Entry(
            element: repaired, pid: entry.pid, path: path,
            identity: entry.identity, lastAccess: Date()
        )
        return .resolved(repaired)
    }

    /// The AX path recorded for an id, if any. Exposed for diagnostics
    /// and for tools that want to re-resolve an element themselves.
    func path(for id: String) -> [AXPathComponent]? {
        entries[id]?.path
    }

    /// Resolve multiple IDs, dropping any that are unknown or expired.
    func resolveMany(_ ids: [String]) -> [(String, AXUIElement)] {
        ids.compactMap { id in
            guard let element = resolve(id) else { return nil }
            return (id, element)
        }
    }

    func pid(for id: String) -> pid_t? {
        entries[id]?.pid
    }

    func clear() {
        entries.removeAll(keepingCapacity: false)
    }

    var count: Int { entries.count }

    private func evictExpired() {
        let cutoff = Date().addingTimeInterval(-ttl)
        entries = entries.filter { $0.value.lastAccess > cutoff }
    }

    private func evictIfOverCapacity() {
        guard entries.count >= maxEntries else { return }
        evictOldest(count: entries.count - (maxEntries - 1))
    }

    /// LRU: evict the `count` least-recently-touched entries.
    private func evictOldest(count: Int) {
        guard count > 0 else { return }
        let sorted = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        for (key, _) in sorted.prefix(count) {
            entries.removeValue(forKey: key)
        }
    }

    /// 8 random bytes (64 bits) → 16 hex chars. Collision probability at
    /// 2000 entries is ~10^-14, and we retry on top of that.
    private static func makeID() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "el_\(hex)"
    }
}
