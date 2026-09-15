import Testing
import Foundation
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
    // v0.10 A1: a live positional handle must not bypass its recorded identity.
    @Test("live handle with a different fingerprint is stale")
    func liveFingerprintMismatch() async {
        let cache = ElementCache()
        let id = await cache.store(
            AXUIElementCreateSystemWide(), pid: getpid(),
            path: [AXPathComponent(role: "AXMenuItem", index: 0, identifier: nil,
                                   title: "Close All Windows", subrole: nil)]
        )
        guard case .stale = await cache.resolveLive(id) else {
            Issue.record("v0.10 A1: live handle silently resolved a different control")
            return
        }
    }

    // v0.10 A2: repeated full trees must not consume another app's working set.
    @Test("capacity eviction prefers older entries from the incoming pid")
    func evictionIsPIDLocal() async {
        let cache = ElementCache(maxEntries: 3)
        let other = await cache.store(AXUIElementCreateSystemWide(), pid: 2)
        let old = await cache.store(AXUIElementCreateSystemWide(), pid: 1)
        _ = await cache.store(AXUIElementCreateSystemWide(), pid: 1)
        _ = await cache.store(AXUIElementCreateSystemWide(), pid: 1)
        #expect(await cache.resolve(other) != nil)
        #expect(await cache.resolve(old) == nil)
        #expect(String(describing: await cache.resolveLive(old)).contains("evicted"))
    }

    @Test("refreshing stable paths at capacity does not evict other ids")
    func refreshDoesNotEvict() async {
        let cache = ElementCache(maxEntries: 2)
        let other = await cache.store(AXUIElementCreateSystemWide(), pid: 2)
        let path = [component("AXButton", 0)]
        let element = AXUIElementCreateSystemWide()
        _ = await cache.store(element, pid: 1, path: path)
        _ = await cache.storeMany(withPaths: [(element, path)], pid: 1)
        #expect(await cache.resolve(other) != nil)
        _ = await cache.store(element, pid: 1, path: path)
        #expect(await cache.resolve(other) != nil)
    }

    @Test("six 2000-node trees fit in the default cache")
    func repeatedTreesFit() async {
        let cache = ElementCache()
        let element = AXUIElementCreateSystemWide()
        let first = await cache.store(element, pid: 2)
        for _ in 0..<6 {
            _ = await cache.storeMany(Array(repeating: element, count: 2000), pid: 1)
        }
        #expect(await cache.resolve(first) != nil)
        #expect(await cache.count == 12001)
    }

    // v0.10 A2: resolving one old node must not protect its whole old tree.
    @Test("capacity removes the oldest tree even when its ids were recently read")
    func evictionUsesTreeAge() async throws {
        let cache = ElementCache(maxEntries: 2)
        let old = try #require(await cache.storeMany([AXUIElementCreateSystemWide()], pid: 1).first!)
        try await Task.sleep(for: .milliseconds(2))
        let newer = await cache.store(AXUIElementCreateSystemWide(), pid: 1)
        #expect(await cache.resolve(old) != nil)
        _ = await cache.store(AXUIElementCreateSystemWide(), pid: 1)
        #expect(await cache.resolve(old) == nil)
        #expect(await cache.resolve(newer) != nil)
    }

    @Test("colliding paths in one batch cannot exceed capacity")
    func collidingBatchCapacity() async {
        let cache = ElementCache(maxEntries: 3, identify: Self.collidingIdentify)
        _ = await cache.store(AXUIElementCreateSystemWide(), pid: 2)
        _ = await cache.store(AXUIElementCreateSystemWide(), pid: 2)
        let element = AXUIElementCreateSystemWide()
        _ = await cache.storeMany(withPaths: [
            (element, [component("AXButton", 0)]),
            (element, [component("AXButton", 1)]),
            (element, [component("AXButton", 2)])
        ], pid: 1)
        #expect(await cache.count <= 3)
    }

    @Test("element and text tools distinguish eviction with configured retention hints", arguments: [
        "get_element_attributes", "perform_element_action", "set_element_attribute", "text_get_value", "wait_for_ax_notification"
    ])
    func evictionToolContract(tool: String) async {
        let cache = ElementCache(ttl: 17, maxEntries: 1)
        let registry = ToolRegistry(accessibility: AccessibilityController(), elementCache: cache)
        let id = await cache.store(AXUIElementCreateSystemWide(), pid: getpid())
        _ = await cache.store(AXUIElementCreateSystemWide(), pid: getpid())
        let result = await registry.callTool(name: tool, arguments: [
            "element_id": .string(id), "action": .string("AXPress"), "value": .string("unused"),
            "name": .string("AXValue"), "notification": .string("AXValueChanged")
        ])
        let payload = result.structuredContent.objectValue
        #expect(payload?["error_code"]?.stringValue == "evicted_element_id")
        #expect(payload?["hint"]?.stringValue?.contains("17.0 seconds") == true)
        #expect(payload?["hint"]?.stringValue?.contains("1 entries") == true)
    }

    // v0.10 A1: an unreadable fingerprint is not evidence of identity.
    @Test("failed fingerprint batch cannot validate an AXUnknown leaf")
    func unreadableFingerprintIsStale() async {
        let cache = ElementCache()
        let id = await cache.store(AXUIElementCreateApplication(-1), pid: getpid(),
                                   path: [component("AXUnknown", 0)])
        guard case .stale = await cache.resolveLive(id) else {
            Issue.record("failed AX read was accepted as an AXUnknown fingerprint")
            return
        }
    }

    // v0.10 A2: quarantine allocates a new random id for every collision,
    // including repeated paths, so distinct-path counting can under-reserve.
    @Test("repeated colliding paths cannot overflow the batch capacity")
    func repeatedCollidingBatchCapacity() async {
        let cache = ElementCache(maxEntries: 5, identify: Self.collidingIdentify)
        _ = await cache.storeMany(Array(repeating: AXUIElementCreateSystemWide(), count: 3), pid: 2)
        let element = AXUIElementCreateSystemWide()
        let a = [component("AXButton", 0)]
        let b = [component("AXButton", 1)]
        _ = await cache.storeMany(withPaths: [a, b, a, b, a].map { (element, $0) }, pid: 1)
        #expect(await cache.count <= 5)
    }

    // v0.10 A1: every fake read stays under the lock because cache calls
    // execute on its actor while the test changes the published label.
    private final class FakeAX: @unchecked Sendable {
        private let lock = NSLock()
        private var title = "Close All Windows"
        private var reads = 0
        private var aliveChecks = 0
        private var repairs = 0
        private var repairPath: [AXPathComponent]?
        private var repairPID: pid_t?
        let replacement: AXUIElement?

        init(replacement: AXUIElement? = nil) { self.replacement = replacement }

        func relabel() { lock.withLock { title = "Close Window" } }

        func fingerprint(_ element: AXUIElement) -> AXFingerprint {
            lock.withLock {
                reads += 1
                let isReplacement = replacement.map { CFEqual($0, element) } ?? false
                return AXFingerprint(role: "AXMenuItem", identifier: nil,
                    title: isReplacement ? "Close All Windows" : title, subrole: nil)
            }
        }

        func isAlive(_ element: AXUIElement) -> Bool {
            lock.withLock { aliveChecks += 1 }
            return true
        }

        func resolve(_ path: [AXPathComponent], _ pid: pid_t) -> AXUIElement? {
            lock.withLock {
                repairs += 1
                repairPath = path
                repairPID = pid
            }
            return replacement
        }

        func snapshot() -> (reads: Int, alive: Int, repairs: Int, path: [AXPathComponent]?, pid: pid_t?) {
            lock.withLock { (reads, aliveChecks, repairs, repairPath, repairPID) }
        }
    }

    @Test("fake live menu relabel cannot silently retarget its cached id")
    func fakeLiveMenuRelabel() async {
        let fake = FakeAX()
        let cache = ElementCache(fingerprint: fake.fingerprint, isAlive: fake.isAlive, resolvePath: fake.resolve)
        let path = [AXPathComponent(role: "AXMenuItem", index: 0, identifier: nil,
                                    title: "Close All Windows", subrole: nil)]
        let id = await cache.store(AXUIElementCreateSystemWide(), pid: getpid(), path: path)
        guard case .resolved = await cache.resolveLive(id) else {
            Issue.record("intact fake handle must resolve")
            return
        }
        #expect(fake.snapshot().reads == 1)
        #expect(fake.snapshot().alive == 0)
        #expect(fake.snapshot().repairs == 0)
        fake.relabel()
        guard case .stale = await cache.resolveLive(id) else {
            Issue.record("v0.10 A1: Close All Windows silently became Close Window")
            return
        }
        #expect(fake.snapshot().reads == 2)
        #expect(fake.snapshot().repairs == 1)
        #expect(fake.snapshot().path == path)
        #expect(fake.snapshot().pid == getpid())
    }

    @Test("fake mismatched handle repairs and caches the verified replacement")
    func fakeLiveMenuRepair() async {
        let replacement = AXUIElementCreateApplication(getpid())
        let fake = FakeAX(replacement: replacement)
        fake.relabel()
        let cache = ElementCache(fingerprint: fake.fingerprint, isAlive: fake.isAlive, resolvePath: fake.resolve)
        let path = [AXPathComponent(role: "AXMenuItem", index: 0, identifier: nil,
                                    title: "Close All Windows", subrole: nil)]
        let id = await cache.store(AXUIElementCreateSystemWide(), pid: getpid(), path: path)
        guard case .resolved(let repaired) = await cache.resolveLive(id) else {
            Issue.record("verified path replacement must resolve")
            return
        }
        #expect(CFEqual(repaired, replacement))
        #expect(await cache.path(for: id) == path)
        guard case .resolved(let cached) = await cache.resolveLive(id) else {
            Issue.record("repaired handle must remain usable")
            return
        }
        #expect(CFEqual(cached, replacement))
        #expect(fake.snapshot().reads == 2)
        #expect(fake.snapshot().repairs == 1)
        #expect(fake.snapshot().alive == 0)
    }

    @Test("fake pathless ids keep the liveness-only contract")
    func fakePathlessResolution() async {
        let fake = FakeAX()
        let cache = ElementCache(fingerprint: fake.fingerprint, isAlive: fake.isAlive, resolvePath: fake.resolve)
        let id = await cache.store(AXUIElementCreateSystemWide(), pid: getpid())
        guard case .resolved = await cache.resolveLive(id) else {
            Issue.record("pathless live handle must resolve")
            return
        }
        #expect(fake.snapshot().alive == 1)
        #expect(fake.snapshot().reads == 0)
        #expect(fake.snapshot().repairs == 0)
    }

}
