import Testing
import Foundation
import CoreGraphics
@testable import MacControlMCP

/// Bounded, deadline-guarded execution of blocking work (list_windows'
/// per-app AX queries) off Swift's cooperative pool.
@Suite("BlockingWorkPool")
struct BlockingWorkPoolTests {
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var current = 0
        private(set) var maxSeen = 0
        func enter() { lock.lock(); current += 1; maxSeen = max(maxSeen, current); lock.unlock() }
        func leave() { lock.lock(); current -= 1; lock.unlock() }
        var peak: Int { lock.lock(); defer { lock.unlock() }; return maxSeen }
    }

    @Test("empty input returns immediately")
    func empty() async {
        let out = await BlockingWorkPool.map(count: 0, maxConcurrent: 4, perItemTimeout: 1) { $0 }
        #expect(out.isEmpty)
    }

    @Test("results are index-aligned and concurrency never exceeds the bound")
    func orderingAndBound() async {
        let counter = Counter()
        let out = await BlockingWorkPool.map(count: 12, maxConcurrent: 3, perItemTimeout: 5) { i in
            counter.enter()
            // Later indices finish first, so completion order != input order.
            Thread.sleep(forTimeInterval: 0.01 * Double(12 - i))
            counter.leave()
            return i * 10
        }
        #expect(out.map(\.value) == (0..<12).map { Optional($0 * 10) })
        #expect(counter.peak <= 3)
        #expect(counter.peak >= 2)
    }

    @Test("a hung item times out without blocking the others or the caller")
    func slowReaderIsBounded() async {
        let start = Date()
        let out = await BlockingWorkPool.map(count: 6, maxConcurrent: 2, perItemTimeout: 0.3) { i in
            if i == 1 || i == 4 {
                Thread.sleep(forTimeInterval: 3)   // simulated beach-balling app
            }
            return i
        }
        let elapsed = Date().timeIntervalSince(start)
        #expect(elapsed < 1.5, "took \(elapsed)s — slow items must not hold the call")
        for i in [0, 2, 3, 5] { #expect(out[i].value == i) }
        for i in [1, 4] {
            if case .timedOut = out[i] {} else { Issue.record("index \(i) should have timed out") }
        }
    }

    @Test("does not occupy Swift's cooperative pool: many hung items leave other tasks runnable")
    func cooperativePoolStaysFree() async {
        let cores = ProcessInfo.processInfo.activeProcessorCount
        async let pooled = BlockingWorkPool.map(count: cores * 2, maxConcurrent: cores * 2, perItemTimeout: 0.5) { _ in
            Thread.sleep(forTimeInterval: 2)
            return 0
        }
        // While every item blocks, plain tasks must still get scheduled.
        try? await Task.sleep(nanoseconds: 100_000_000)
        let start = Date()
        let values = await withTaskGroup(of: Int.self) { group in
            for i in 0..<(cores * 2) { group.addTask { i } }
            return await group.reduce(0, +)
        }
        #expect(Date().timeIntervalSince(start) < 0.3)
        #expect(values == (0..<(cores * 2)).reduce(0, +))
        _ = await pooled
    }

    // MARK: - list_windows merge

    private func cgEntry(pid: Int32, title: String) -> [String: Any] {
        [
            kCGWindowOwnerPID as String: NSNumber(value: pid),
            kCGWindowLayer as String: NSNumber(value: 0),
            kCGWindowBounds as String: ["X": NSNumber(value: 0), "Y": NSNumber(value: 100),
                                        "Width": NSNumber(value: 500), "Height": NSNumber(value: 400)],
            kCGWindowIsOnscreen as String: NSNumber(value: true),
            kCGWindowName as String: title
        ]
    }

    @Test("assemble keeps app order, falls back to CG, flags ax_timeout, fetches CG once")
    func assemble() throws {
        let axWindow = WindowController.WindowInfo(
            app: "A", pid: 1, title: "ax", x: 0, y: 0, width: 10, height: 10,
            minimized: false, main: true, index: 0
        )
        var fetches = 0
        let result = WindowController.assemble(
            apps: [(pid: 1, name: "A"), (pid: 2, name: "B"), (pid: 3, name: "C")],
            outcomes: [.value([axWindow]), .timedOut, .value([])],
            windowServerList: {
                fetches += 1
                return [self.cgEntry(pid: 3, title: "c-cg"), self.cgEntry(pid: 2, title: "b-cg")]
            }
        )
        #expect(result.map(\.title) == ["ax", "b-cg", "c-cg"])
        #expect(result.map(\.axTimeout) == [nil, true, nil])
        #expect(fetches == 1)

        let json = String(data: try JSONEncoder().encode(result[1]), encoding: .utf8) ?? ""
        #expect(json.contains("\"ax_timeout\":true"))
        let plain = String(data: try JSONEncoder().encode(result[0]), encoding: .utf8) ?? ""
        #expect(!plain.contains("ax_timeout"))

        var noFetch = 0
        _ = WindowController.assemble(apps: [(pid: 1, name: "A")], outcomes: [.value([axWindow])],
                                      windowServerList: { noFetch += 1; return [] })
        #expect(noFetch == 0)
    }
}
