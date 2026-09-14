import Foundation

/// Runs BLOCKING work (synchronous AX IPC) off Swift's cooperative
/// executor, with bounded concurrency and a per-item deadline.
///
/// Why not a TaskGroup: Swift's cooperative pool is process-global and
/// sized to ~#cores. Synchronous AX calls block their thread for as long
/// as the target app takes to answer (up to the AX messaging timeout,
/// 6 s by default). One Task per running app would let a handful of
/// beach-balling apps occupy every cooperative thread and stall every
/// other in-flight tool call of the server.
///
/// Here the work runs on a dedicated GCD queue. At most `maxConcurrent`
/// items run at once; an item that has not finished `perItemTimeout`
/// seconds after it started is reported as `.timedOut` and its slot is
/// released so the remaining items still get to run. The abandoned
/// work keeps its GCD thread until the blocking call returns, so callers
/// should ALSO bound the call itself (for AX: `AXUIElementSetMessagingTimeout`)
/// — otherwise abandoned threads can accumulate beyond `maxConcurrent`.
///
/// Results are returned index-aligned with the input, so output ordering
/// is deterministic regardless of completion order.
enum BlockingWorkPool {
    enum Outcome<T: Sendable>: Sendable {
        case value(T)
        case timedOut

        var value: T? {
            if case .value(let v) = self { return v }
            return nil
        }
    }

    static let sharedQueue = DispatchQueue(
        label: "mac-control-mcp.blocking-work",
        qos: .userInitiated,
        attributes: .concurrent
    )

    static func map<T: Sendable>(
        count: Int,
        maxConcurrent: Int,
        perItemTimeout: TimeInterval,
        queue: DispatchQueue = BlockingWorkPool.sharedQueue,
        work: @escaping @Sendable (Int) -> T
    ) async -> [Outcome<T>] {
        guard count > 0 else { return [] }
        return await withCheckedContinuation { continuation in
            State(
                count: count,
                maxConcurrent: max(1, maxConcurrent),
                timeout: max(0, perItemTimeout),
                queue: queue,
                work: work,
                continuation: continuation
            ).start()
        }
    }

    private final class State<T: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private let count: Int
        private let maxConcurrent: Int
        private let timeout: TimeInterval
        private let queue: DispatchQueue
        private let work: @Sendable (Int) -> T
        // Guarded by `lock`.
        private var results: [Outcome<T>?]
        private var next = 0
        private var active = 0
        private var remaining: Int
        private var continuation: CheckedContinuation<[Outcome<T>], Never>?

        init(
            count: Int, maxConcurrent: Int, timeout: TimeInterval, queue: DispatchQueue,
            work: @escaping @Sendable (Int) -> T,
            continuation: CheckedContinuation<[Outcome<T>], Never>
        ) {
            self.count = count
            self.maxConcurrent = maxConcurrent
            self.timeout = timeout
            self.queue = queue
            self.work = work
            self.results = Array(repeating: nil, count: count)
            self.remaining = count
            self.continuation = continuation
        }

        func start() {
            lock.lock()
            let toLaunch = claimLocked()
            lock.unlock()
            toLaunch.forEach(launch)
        }

        private func claimLocked() -> [Int] {
            var out: [Int] = []
            while active < maxConcurrent && next < count {
                out.append(next)
                next += 1
                active += 1
            }
            return out
        }

        private func launch(_ index: Int) {
            queue.async {
                let value = self.work(index)
                self.settle(index, .value(value))
            }
            queue.asyncAfter(deadline: .now() + timeout) {
                self.settle(index, .timedOut)
            }
        }

        /// First outcome for an index wins (value vs. deadline race).
        private func settle(_ index: Int, _ outcome: Outcome<T>) {
            lock.lock()
            guard results[index] == nil else {
                lock.unlock()
                return
            }
            results[index] = outcome
            active -= 1
            remaining -= 1
            let toLaunch = claimLocked()
            var finished: CheckedContinuation<[Outcome<T>], Never>?
            var final: [Outcome<T>] = []
            if remaining == 0, let c = continuation {
                continuation = nil
                finished = c
                final = results.map { $0! }
            }
            lock.unlock()
            toLaunch.forEach(launch)
            finished?.resume(returning: final)
        }
    }
}
