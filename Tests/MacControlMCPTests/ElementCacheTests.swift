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

    // MARK: - Id collisions (Codex review 3)

    /// SHA-256 makes a real collision unreachable from a test, so the guard
    /// is exercised through the injectable id function: a deliberately
    /// degenerate hash forces two DIFFERENT paths onto one id.
    private static let collidingIdentify: @Sendable (pid_t, [AXPathComponent]) -> String = { _, _ in
        "el_collision"
    }

    private func component(_ role: String, _ index: Int) -> AXPathComponent {
        AXPathComponent(role: role, index: index, identifier: nil)
    }

    @Test("a colliding id never silently retargets the existing entry")
    func collisionDoesNotOverwrite() async {
        let cache = ElementCache(identify: Self.collidingIdentify)
        let first = AXUIElementCreateApplication(101)
        let second = AXUIElementCreateApplication(202)

        let idA = await cache.store(first, pid: 7, path: [component("AXWindow", 0)])
        #expect(idA == "el_collision")
        #expect(await cache.resolve(idA).map { CFEqual($0, first) } == true)

        // Same id, different path → must NOT overwrite the first entry.
        let idB = await cache.store(second, pid: 7, path: [component("AXButton", 1)])
        #expect(idB != idA, "a colliding element must not inherit the existing id")
        #expect(await cache.collisions == 1)
        // The poisoned id is evicted rather than left pointing at either
        // element: whoever holds it gets unknown_element_id and re-searches.
        #expect(await cache.resolve(idA) == nil)
        #expect(await cache.resolve(idB).map { CFEqual($0, second) } == true)
    }

    @Test("re-storing the same (pid, path) still refreshes in place")
    func samePathRefreshes() async {
        let cache = ElementCache(identify: Self.collidingIdentify)
        let element = AXUIElementCreateApplication(101)
        let path = [component("AXWindow", 0)]
        let first = await cache.store(element, pid: 7, path: path)
        let second = await cache.store(element, pid: 7, path: path)
        #expect(first == second)
        #expect(await cache.collisions == 0)
        #expect(await cache.count == 1)
    }

    @Test("a colliding id across pids is a collision too")
    func collisionAcrossPIDs() async {
        let cache = ElementCache(identify: Self.collidingIdentify)
        let path = [component("AXWindow", 0)]
        let idA = await cache.store(AXUIElementCreateApplication(101), pid: 7, path: path)
        let idB = await cache.store(AXUIElementCreateApplication(202), pid: 8, path: path)
        #expect(idA != idB)
        #expect(await cache.collisions == 1)
    }

    @Test("real paths that naively concatenate the same get distinct cache ids")
    func craftedPathsGetDistinctIDs() async {
        let cache = ElementCache()
        let forged = [AXPathComponent(role: "AXButton", index: 1, identifier: "x/AXButton[1]#y")]
        let genuine = [
            AXPathComponent(role: "AXButton", index: 1, identifier: "x"),
            AXPathComponent(role: "AXButton", index: 1, identifier: "y")
        ]
        let idA = await cache.store(AXUIElementCreateApplication(101), pid: 7, path: forged)
        let idB = await cache.store(AXUIElementCreateApplication(202), pid: 7, path: genuine)
        #expect(idA != idB)
        #expect(await cache.collisions == 0)
        #expect(await cache.count == 2)
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
