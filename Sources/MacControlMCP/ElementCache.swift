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
        let createdAt: Date
    }

    private var entries: [String: Entry] = [:]
    private let ttl: TimeInterval
    private let maxEntries: Int

    init(ttl: TimeInterval = 300, maxEntries: Int = 2_000) {
        self.ttl = ttl
        self.maxEntries = maxEntries
    }

    /// Store `element` and return a new opaque ID.
    func store(_ element: AXUIElement, pid: pid_t) -> String {
        evictExpired()
        evictIfOverCapacity()

        let id = Self.makeID()
        entries[id] = Entry(element: element, pid: pid, createdAt: Date())
        return id
    }

    /// Resolve an ID to its element. Returns nil if unknown or expired.
    func resolve(_ id: String) -> AXUIElement? {
        guard let entry = entries[id] else { return nil }
        if Date().timeIntervalSince(entry.createdAt) > ttl {
            entries.removeValue(forKey: id)
            return nil
        }
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
        entries = entries.filter { $0.value.createdAt > cutoff }
    }

    private func evictIfOverCapacity() {
        guard entries.count >= maxEntries else { return }
        let sorted = entries.sorted { $0.value.createdAt < $1.value.createdAt }
        let excess = entries.count - (maxEntries - 1)
        for (key, _) in sorted.prefix(excess) {
            entries.removeValue(forKey: key)
        }
    }

    private static func makeID() -> String {
        var bytes = [UInt8](repeating: 0, count: 4)
        for i in 0..<bytes.count {
            bytes[i] = UInt8.random(in: 0...255)
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        return "el_\(hex)"
    }
}
