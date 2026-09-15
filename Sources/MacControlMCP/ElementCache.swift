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
        let capturedAt: Date
        var lastAccess: Date
    }

    /// Outcome of resolving an element id. Distinguishing "never heard
    /// of it" from "the element it named is gone" is the whole point:
    /// the first is a caller bug, the second means re-run a search.
    enum Resolution: Sendable {
        case resolved(AXUIElement)
        /// Unknown or expired id, including capacity removals beyond the bounded diagnostic history.
        case unknown
        /// v0.10 A2: a known id was removed to enforce the capacity bound.
        case evicted(String)
        /// The id was ours, but the element behind it no longer exists
        /// (or its process was replaced). Never a guess at a
        /// replacement.
        case stale(String)
    }

    private var entries: [String: Entry] = [:]
    nonisolated let ttl: TimeInterval
    /// Hard cap on retained handles; tree walks have a separate node cap.
    nonisolated let maxEntries: Int
    /// How an element id is derived from (pid, path). Injectable so the
    /// collision guard below can be tested with a degenerate hash —
    /// SHA-256 collisions are not reachable from a test.
    private let identify: @Sendable (pid_t, [AXPathComponent]) -> String
    // v0.10 A1: isolate AX reads so relabel and repair behavior can be
    // reproduced without trusting or modifying a desktop application.
    private let fingerprint: @Sendable (AXUIElement) -> AXFingerprint
    private let isAlive: @Sendable (AXUIElement) -> Bool
    private let resolvePath: @Sendable ([AXPathComponent], pid_t) -> AXUIElement?
    /// Number of id collisions seen since construction (Codex review 3).
    /// Should always be 0 in production; a non-zero value means two
    /// different paths hashed to the same id and both handles were
    /// quarantined. Exposed for tests and diagnostics.
    private(set) var collisions = 0

    // v0.10 A2: cache retention and walk size are independent budgets.
    static let defaultTTL: TimeInterval = 300
    static let defaultMaxEntries = 20_000
    static let treeNodeCap = 2_000
    private var evictedIDs: [String: Date] = [:]

    nonisolated var retentionHint: String {
        "Ids expire after \(ttl) seconds idle; the cache holds at most \(maxEntries) entries. Capacity eviction prefers older trees from the same pid. Re-run find_elements / find_element / get_ui_tree for a current id."
    }

    init(
        ttl: TimeInterval = ElementCache.defaultTTL,
        maxEntries: Int = ElementCache.defaultMaxEntries,
        identify: @escaping @Sendable (pid_t, [AXPathComponent]) -> String = AXPath.identifier,
        fingerprint: @escaping @Sendable (AXUIElement) -> AXFingerprint = AXPath.fingerprint,
        isAlive: @escaping @Sendable (AXUIElement) -> Bool = AXPath.isAlive,
        resolvePath: @escaping @Sendable ([AXPathComponent], pid_t) -> AXUIElement? = AXPath.resolve
    ) {
        self.ttl = ttl
        self.maxEntries = max(1, maxEntries)
        self.identify = identify
        self.fingerprint = fingerprint
        self.isAlive = isAlive
        self.resolvePath = resolvePath
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
        let incoming = path.map { identify(pid, $0) }
        reserve(newCount: incoming.flatMap { entries[$0] } == nil ? 1 : 0,
                pid: pid, protecting: Set(incoming.map { [$0] } ?? []))
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
    /// `treeNodeCap` nodes.
    func storeMany(_ elements: [AXUIElement], pid: pid_t) -> [String?] {
        storeMany(withPaths: elements.map { ($0, nil) }, pid: pid)
    }

    /// Path-carrying variant — `get_ui_tree` and the search tools use it
    /// so every returned id is content-addressed (C-5).
    func storeMany(withPaths elements: [(AXUIElement, [AXPathComponent]?)], pid: pid_t) -> [String?] {
        guard !elements.isEmpty else { return [] }
        evictExpired()
        let storable = min(elements.count, maxEntries)
        // v0.10 A2: refreshing an existing tree needs no new cache slots.
        let incoming = elements.prefix(storable).compactMap { item in
            item.1.map { identify(pid, $0) }
        }
        let protected = Set(incoming)
        // v0.10 A2: simulate the hash-slot changes made by insert. Each
        // collision replaces its hash slot with a random slot; a later
        // repeat can therefore allocate again despite naming the same path.
        var projected: [String: String] = [:]
        for id in protected {
            if let entry = entries[id] {
                projected[id] = entry.path.map { AXPath.identity(pid: entry.pid, path: $0) }
                    ?? "<pathless>"
            }
        }
        var newCount = 0
        for (_, path) in elements.prefix(storable) {
            guard let path else { newCount += 1; continue }
            let id = identify(pid, path)
            let identity = AXPath.identity(pid: pid, path: path)
            if let existing = projected[id] {
                if existing != identity { projected.removeValue(forKey: id) }
            } else {
                projected[id] = identity
                newCount += 1
            }
        }
        reserve(newCount: newCount, pid: pid, protecting: protected)
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
            let id = identify(pid, path)
            if let existing = entries[id], !Self.sameIdentity(existing, pid: pid, path: path) {
                // Codex review 3: an id whose (pid, path) does not match the
                // one already filed under it is a hash collision. Silently
                // overwriting would retarget every handle the caller is
                // holding onto a different control — the exact failure this
                // review flagged. Quarantine BOTH: drop the existing entry
                // (its holder now gets unknown_element_id and re-searches)
                // and file the newcomer under a fresh random id rather than
                // letting it inherit a poisoned one. Determinism is worth
                // less than never acting on the wrong element.
                //
                // Codex r2 (new): "same identity" is judged on exactly the
                // fields the id is hashed from (pid, role, ordinal,
                // identifier — `AXPath.identity`). Fingerprint fields
                // (title, subrole) are deliberately NOT part of the id so a
                // relabelled control keeps its handle; comparing whole
                // components here treated "Start" → "Stop" as a collision,
                // evicted the stable id and handed out a random one. Now a
                // relabel simply refreshes the stored fingerprint below.
                entries.removeValue(forKey: id)
                collisions += 1
                FileHandle.standardError.write(Data(
                    """
                    [mac-control-mcp] element id collision on \(id): \
                    pid \(existing.pid) path \(existing.path.map { AXPath.identity(pid: existing.pid, path: $0) } ?? "<none>") \
                    vs pid \(pid) path \(AXPath.identity(pid: pid, path: path)). \
                    Both handles quarantined; no element was retargeted.\n
                    """.utf8
                ))
                return insertRandom(element, pid: pid, path: path, identity: identity, now: now)
            }
            evictedIDs.removeValue(forKey: id)
            entries[id] = Entry(element: element, pid: pid, path: path, identity: identity, capturedAt: now, lastAccess: now)
            return id
        }
        return insertRandom(element, pid: pid, path: nil, identity: identity, now: now)
    }

    /// Does `entry` describe the same (pid, hashed path) as `path`? Compares
    /// the canonical identity string — the exact input of the id hash — so
    /// only a genuine collision (two different hashed paths, one id) is
    /// reported, never a fingerprint refresh (Codex r2).
    private static func sameIdentity(_ entry: Entry, pid: pid_t, path: [AXPathComponent]) -> Bool {
        guard entry.pid == pid, let existingPath = entry.path else { return false }
        return AXPath.identity(pid: entry.pid, path: existingPath) == AXPath.identity(pid: pid, path: path)
    }

    /// Random-id insert: for producers with no path (the system-wide
    /// focused element) and for the collision quarantine above.
    private func insertRandom(
        _ element: AXUIElement,
        pid: pid_t,
        path: [AXPathComponent]?,
        identity: ProcessIdentity,
        now: Date
    ) -> String {
        for _ in 0..<8 {
            let id = Self.makeID()
            if entries[id] == nil {
                entries[id] = Entry(element: element, pid: pid, path: path, identity: identity, capturedAt: now, lastAccess: now)
                return id
            }
        }
        // Extremely unlikely path. Fall back to a UUID-based ID so we
        // never silently overwrite an existing entry.
        let fallback = "el_\(UUID().uuidString.prefix(16).lowercased().replacingOccurrences(of: "-", with: ""))"
        entries[fallback] = Entry(element: element, pid: pid, path: path, identity: identity, capturedAt: now, lastAccess: now)
        return fallback
    }

    /// Resolve an ID to its element. On success, refreshes lastAccess so the
    /// entry remains within its idle TTL. Capacity uses tree capture age
    /// (v0.10 A2), independently of these reads. Returns nil if
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
    /// v0.10 A1: this variant verifies the live leaf fingerprint, then
    /// re-walks the recorded path if the handle changed or died. Only a
    /// verified replacement is cached under the same id.
    /// Repair is strictly verified (review fixes 1 + 2):
    ///   * the owning process must still be the same process — a
    ///     recycled pid is `stale`, never a silent retarget;
    ///   * every level of the re-walked path must match the fingerprint
    ///     captured at store time, so inserting a sibling can never
    ///     shift a handle onto a neighbouring control;
    ///   * a repaired element is written back ONLY after that full
    ///     verification; otherwise the entry is dropped.
    func resolveLive(_ id: String) -> Resolution {
        guard let element = resolve(id) else {
            if let removed = evictedIDs[id], Date().timeIntervalSince(removed) <= ttl {
                return .evicted(retentionHint)
            }
            return .unknown
        }
        guard let entry = entries[id] else { return .unknown }

        let identityNow = ProcessIdentity.current(pid: entry.pid)
        guard entry.identity.matches(identityNow) else {
            entries.removeValue(forKey: id)
            return .stale(
                "pid \(entry.pid) is no longer the process this element came from (the pid was reused or the app restarted)"
            )
        }

        // v0.10 A1: AppKit can reuse a live positional handle for another
        // menu item. Verify the leaf in one batch before trusting that handle.
        if let leaf = entry.path?.last {
            if fingerprint(element).matches(leaf) { return .resolved(element) }
        } else if isAlive(element) {
            return .resolved(element)
        }

        guard let path = entry.path else {
            entries.removeValue(forKey: id)
            return .stale("the element is gone and no AX path was recorded for it")
        }
        guard let repaired = resolvePath(path, entry.pid) else {
            entries.removeValue(forKey: id)
            return .stale("the element changed or is gone and its AX path no longer matches any element in the app")
        }
        entries[id] = Entry(
            element: repaired, pid: entry.pid, path: path,
            identity: entry.identity, capturedAt: entry.capturedAt, lastAccess: Date()
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
        evictedIDs.removeAll(keepingCapacity: false)
    }

    var count: Int { entries.count }

    private func evictExpired() {
        let cutoff = Date().addingTimeInterval(-ttl)
        entries = entries.filter { $0.value.lastAccess > cutoff }
        evictedIDs = evictedIDs.filter { $0.value > cutoff }
    }

    /// v0.10 A2: exhaust older trees from the incoming pid before taking
    /// another application's ids. Protect paths refreshed by this batch.
    private func reserve(newCount: Int, pid: pid_t, protecting: Set<String>) {
        let overflow = entries.count + newCount - maxEntries
        guard overflow > 0 else { return }
        let sorted = entries.filter { !protecting.contains($0.key) }.sorted {
            if ($0.value.pid == pid) != ($1.value.pid == pid) { return $0.value.pid == pid }
            return $0.value.capturedAt < $1.value.capturedAt
        }
        let now = Date()
        for (key, _) in sorted.prefix(overflow) {
            entries.removeValue(forKey: key)
            evictedIDs[key] = now
        }
        // v0.10 A2: diagnostics must not become an unbounded second cache.
        let excess = evictedIDs.count - maxEntries
        if excess > 0 {
            for (key, _) in evictedIDs.sorted(by: { $0.value < $1.value }).prefix(excess) {
                evictedIDs.removeValue(forKey: key)
            }
        }
    }

    /// 8 random bytes (64 bits) → 16 hex chars. Only used for pathless
    /// producers and the collision quarantine; path-derived ids are 32 hex
    /// chars (SHA-256/128 via `AXPath.identifier`). Collision probability
    /// at 2000 entries is ~10^-14, and we retry on top of that.
    private static func makeID() -> String {
        var bytes = [UInt8](repeating: 0, count: 8)
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "el_\(hex)"
    }
}
