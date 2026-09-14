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

    @Test("storeMany returns one distinct, resolvable ID per element in order")
    func storeManyRoundtrip() async {
        let cache = ElementCache(ttl: 60, maxEntries: 100)
        let elements = (0..<10).map { AXUIElementCreateApplication(pid_t(1000 + $0)) }
        let ids = await cache.storeMany(elements, pid: 7).compactMap { $0 }
        #expect(ids.count == 10)
        #expect(Set(ids).count == 10)
        for (id, element) in zip(ids, elements) {
            let resolved = await cache.resolve(id)
            #expect(resolved.map { CFEqual($0, element) } == true)
            #expect(await cache.pid(for: id) == 7)
        }
        #expect(await cache.storeMany([], pid: 7).isEmpty)
    }

    @Test("storeMany evicts oldest entries first and keeps the whole batch")
    func storeManyEviction() async {
        let cache = ElementCache(ttl: 60, maxEntries: 5)
        let old = await cache.storeMany((0..<4).map { _ in AXUIElementCreateSystemWide() }, pid: 1).compactMap { $0 }
        let fresh = await cache.storeMany((0..<3).map { _ in AXUIElementCreateSystemWide() }, pid: 2).compactMap { $0 }
        #expect(old.count == 4 && fresh.count == 3)
        // 4 + 3 = 7 > 5 → the 2 oldest must go, the new batch must all resolve.
        #expect(await cache.count == 5)
        for id in fresh { #expect(await cache.resolve(id) != nil) }
        var survivingOld = 0
        for id in old where await cache.resolve(id) != nil { survivingOld += 1 }
        #expect(survivingOld == 2)
    }

    @Test("storeMany larger than capacity never exceeds maxEntries and returns no dangling IDs")
    func storeManyOversizedBatch() async {
        let cache = ElementCache(ttl: 60, maxEntries: 3)
        let older = await cache.store(AXUIElementCreateSystemWide(), pid: 1)
        let ids = await cache.storeMany((0..<6).map { _ in AXUIElementCreateSystemWide() }, pid: 2)
        #expect(cache.maxEntries == 3)
        #expect(await cache.count == 3)
        #expect(ids.count == 6)
        // The head of the batch (tree root side) is kept, the tail gets nil.
        #expect(ids.prefix(3).allSatisfy { $0 != nil })
        #expect(ids.suffix(3).allSatisfy { $0 == nil })
        for id in ids.compactMap({ $0 }) { #expect(await cache.resolve(id) != nil) }
        // The pre-existing entry was evicted to make room.
        #expect(await cache.resolve(older) == nil)
    }

    @Test("storeMany drops expired entries before inserting")
    func storeManyExpiry() async throws {
        let cache = ElementCache(ttl: 0.05, maxEntries: 100)
        _ = await cache.storeMany([AXUIElementCreateSystemWide()], pid: 1)
        try await Task.sleep(nanoseconds: 120_000_000)
        _ = await cache.storeMany([AXUIElementCreateSystemWide()], pid: 2)
        #expect(await cache.count == 1)
    }
}
