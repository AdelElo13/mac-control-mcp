import Testing
import ApplicationServices
@testable import MacControlMCP

@Suite("ElementCache")
struct ElementCacheTests {
    @Test("store returns distinct IDs")
    func distinctIDs() async {
        let cache = ElementCache()
        let a = AXUIElementCreateSystemWide()
        let b = AXUIElementCreateSystemWide()
        let id1 = await cache.store(a, pid: 1)
        let id2 = await cache.store(b, pid: 2)
        #expect(id1 != id2)
        #expect(id1.hasPrefix("el_"))
        #expect(id2.hasPrefix("el_"))
    }

    @Test("resolve returns the stored element")
    func resolveRoundtrip() async {
        let cache = ElementCache()
        let element = AXUIElementCreateSystemWide()
        let id = await cache.store(element, pid: 42)
        let resolved = await cache.resolve(id)
        #expect(resolved != nil)
        #expect(await cache.pid(for: id) == 42)
    }

    @Test("resolve returns nil for unknown IDs")
    func unknownID() async {
        let cache = ElementCache()
        let resolved = await cache.resolve("el_deadbeef")
        #expect(resolved == nil)
    }

    @Test("ttl expiry drops entries on resolve")
    func ttlExpiry() async throws {
        let cache = ElementCache(ttl: 0.05)
        let id = await cache.store(AXUIElementCreateSystemWide(), pid: 1)
        try await Task.sleep(nanoseconds: 120_000_000)
        let resolved = await cache.resolve(id)
        #expect(resolved == nil)
    }

    @Test("maxEntries triggers oldest-first eviction")
    func evictionByCapacity() async {
        let cache = ElementCache(ttl: 60, maxEntries: 3)
        let id1 = await cache.store(AXUIElementCreateSystemWide(), pid: 1)
        _ = await cache.store(AXUIElementCreateSystemWide(), pid: 2)
        _ = await cache.store(AXUIElementCreateSystemWide(), pid: 3)
        _ = await cache.store(AXUIElementCreateSystemWide(), pid: 4)
        // With maxEntries=3, inserting the 4th triggers eviction of the oldest.
        #expect(await cache.count <= 3)
        #expect(await cache.resolve(id1) == nil)
    }
}
