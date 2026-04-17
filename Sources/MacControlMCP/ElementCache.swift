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
        var lastAccess: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval
    private let maxEntries: Int

    init(ttl: TimeInterval = 300, maxEntries: Int = 2_000) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    /// Store `element` and return a new opaque ID. If the random ID happens
    /// to collide with an existing entry we retry up to 8 times before
    /// giving up — with an 8-byte ID (64 bits) collisions are astronomically
    /// rare, but we retry anyway to avoid silently overwriting live state.
    func store(_ element: AXUIElement, pid: pid_t) -> String {
        evictExpired()
        evictIfOverCapacity()

        for _ in 0..<8 {
            let id = Self.makeID()
            if entries[id] == nil {
                entries[id] = Entry(element: element, pid: pid, lastAccess: Date())
                return id
            }
        }
        // Extremely unlikely path. Fall back to a UUID-based ID so we
        // never silently overwrite an existing entry.
        let fallback = "el_\(UUID().uuidString.prefix(16).lowercased().replacingOccurrences(of: "-", with: ""))"
        entries[fallback] = Entry(element: element, pid: pid, lastAccess: Date())
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
        // LRU: evict the least-recently-touched entries first.
        let sorted = entries.sorted { $0.value.lastAccess < $1.value.lastAccess }
        let excess = entries.count - (maxEntries - 1)
        for (key, _) in sorted.prefix(excess) {
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
